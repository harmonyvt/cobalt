// Editing a gallery link's files (APP-API-CONTRACT.md section 41): PATCH /share/sets/<id> adds, takes out and moves files
// and changes the title in one write, with `expect` against a second device, through the Worker, the registry and the
// real SQL (node:sqlite). Also the chat AI's links.update.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const DISCORD = { "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" };
const KEY = /^https:\/\/share\.capybaraharmony\.com\/p\/([A-Za-z0-9]{22})$/;

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let media: MemoryMedia;
let clock: number;
let containerCalls: string[];

const container = {
    async fetch(r: Request) {
        containerCalls.push(new URL(r.url).pathname);
        await r.body?.cancel().catch(() => {});
        return Response.json({ status: "success" });
    },
};

const send = (url: string, init: RequestInit = {}) =>
    handleRequest(new Request(url, init), env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });
const api = async (method: string, path: string, body?: unknown, headers: Record<string, string> = AUTH) => {
    const r = await send(`${API}${path}`, {
        method,
        headers: { ...headers, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, headers: r.headers, body: text ? (JSON.parse(text) as any) : null };
};
const share = (path: string, init: RequestInit = {}) => send(`${SHARE.replace(/\/$/, "")}${path}`, init);
const keyOf = (url: string) => KEY.exec(url)![1]!;

const bytes = (n: number, seed = 1) => Uint8Array.from({ length: n }, (_, i) => (i * 7 + seed) % 251);

let n = 0;
function row(over: Record<string, unknown>) {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: `clip${n}.mp4`,
        content_type: "video/mp4",
        bytes: 1000,
        width: 480,
        height: 640,
        duration: 9.6,
        link: "https://x.com/someone/status/1",
        session_id: null,
        key_id: "k",
        created_at: 1_000 + n,
        deleted_at: null,
        poster: null,
        visibility: null,
        public_key: null,
        public_id: null,
        post_key: null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key)`,
        )
        .run(r as any);
    return r;
}
const putOriginal = (key: string, data: Uint8Array, contentType = "video/mp4") => originals.objects.set(key, { bytes: data, contentType, meta: {} });
const putMedia = (key: string, data: Uint8Array, contentType = "video/mp4") =>
    media.objects.set(key, { bytes: data.length, meta: {}, contentType, data, viaStream: false });
const one = (sql: string, ...p: unknown[]) => db.raw.prepare(sql).get(...(p as any[])) as any;

// A public original video (with its public copy and a poster), a private original image, and a webp still in the public bucket.
let pubVideo: any, privImage: any, webp: any, pubVideo2: any, pubImage: any;
const VIDEO = bytes(1000, 3);
const IMAGE = bytes(300, 5);
const WEBP = bytes(200, 9);
const POSTER = bytes(50, 11);

beforeEach(async () => {
    clock = 1_800_000_000_000;
    containerCalls = [];
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    media = new MemoryMedia();
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    pubVideo = row({ visibility: "public", public_key: "PuBlIcViD01.mp4", url: `${MEDIA}PuBlIcViD01.mp4`, poster: `${MEDIA}PoStEr0001.jpg`, bytes: VIDEO.length });
    putOriginal(pubVideo.r2_key, VIDEO);
    putMedia("PuBlIcViD01.mp4", VIDEO);
    putMedia("PoStEr0001.jpg", POSTER, "image/jpeg");
    privImage = row({ r2_key: "originals/photo1.jpg", name: "photo.jpg", content_type: "image/jpeg", duration: null, bytes: IMAGE.length, source: "upload" });
    putOriginal(privImage.r2_key, IMAGE, "image/jpeg");
    webp = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", url: `${MEDIA}WeBpWeBp01.webp`, content_type: "image/webp", duration: null, bytes: WEBP.length });
    putMedia("WeBpWeBp01.webp", WEBP, "image/webp");
});

const SVC = { "x-cobalt-service": INTERNAL };
const makeSet = async (items: string[], extra: Record<string, unknown> = {}) => {
    const r = await api("POST", "/share/sets", { items, ...extra });
    expect(r.status).toBe(201);
    return r.body.set;
};
const ids = (set: any) => set.items.map((i: any) => i.id);

beforeEach(() => {
    pubVideo2 = row({ visibility: "public", public_key: "PuBlIcViD02.mp4", url: `${MEDIA}PuBlIcViD02.mp4`, bytes: VIDEO.length });
    putMedia("PuBlIcViD02.mp4", VIDEO);
    pubImage = row({ kind: "public", source: "webp", bucket: "media", r2_key: "PuBlIcImG1.jpg", url: `${MEDIA}PuBlIcImG1.jpg`, content_type: "image/jpeg", duration: null });
    putMedia("PuBlIcImG1.jpg", IMAGE, "image/jpeg");
});

describe("PATCH /share/sets/<id>", () => {
    it("moves, adds and takes out files in one write; the page follows the new order", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        const r = await api("PATCH", `/share/sets/${set.id}`, { items: [webp.id, pubVideo2.id, pubVideo.id], expect: [pubVideo.id, webp.id] });
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(ids(r.body.set)).toEqual([webp.id, pubVideo2.id, pubVideo.id]);
        expect(r.body.set).toMatchObject({ id: set.id, url: `${SHARE}g/${set.id}`, private: false });
        expect(ids((await api("GET", "/share/sets")).body.sets[0])).toEqual([webp.id, pubVideo2.id, pubVideo.id]);
        const html = await (await share(`/g/${set.id}`, { headers: DISCORD })).text();
        const order = [`${MEDIA}WeBpWeBp01.webp`, `${MEDIA}PuBlIcViD02.mp4`, `${MEDIA}PuBlIcViD01.mp4`].map((u) => html.indexOf(`"url":"${u}"`));
        expect(order.every((i) => i > 0)).toBe(true);
        expect([...order].sort((a, b) => a - b)).toEqual(order);

        const out = await api("PATCH", `/share/sets/${set.id}`, { items: [pubVideo2.id, pubVideo.id] });
        expect(ids(out.body.set)).toEqual([pubVideo2.id, pubVideo.id]);
    });

    it("title: a string sets it, null clears it, absent keeps it", async () => {
        const set = await makeSet([pubVideo.id, webp.id], { title: "old" });
        expect((await api("PATCH", `/share/sets/${set.id}`, { title: "  friday chaos " })).body.set.title).toBe("friday chaos");
        expect((await api("PATCH", `/share/sets/${set.id}`, { items: [webp.id, pubVideo.id] })).body.set.title).toBe("friday chaos");
        expect((await api("PATCH", `/share/sets/${set.id}`, { title: null })).body.set.title).toBeNull();
        expect((await api("PATCH", `/share/sets/${set.id}`, { title: "x".repeat(81) })).status).toBe(400);
    });

    it("refuses fewer than 2, more than 10, duplicates, bad ids and an empty body", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        for (const body of [{ items: [pubVideo.id] }, { items: [pubVideo.id, pubVideo.id] }, { items: [pubVideo.id, "bad"] }, {}, { expect: [pubVideo.id] }]) {
            const r = await api("PATCH", `/share/sets/${set.id}`, body);
            expect(r.status).toBe(400);
            expect(r.body.error.code).toBe("error.share.bad_request");
        }
        const many = Array.from({ length: 11 }, (_, i) => `Item${String(900 + i).padStart(12, "0")}`);
        expect((await api("PATCH", `/share/sets/${set.id}`, { items: many })).status).toBe(400);
    });

    it("a public link only takes added files that are public; a file already in it may stay whatever its state", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        const r = await api("PATCH", `/share/sets/${set.id}`, { items: [pubVideo.id, webp.id, privImage.id, "Missing000000001"] });
        expect(r.status).toBe(409);
        expect(r.body).toMatchObject({ error: { code: "error.share.not_public" }, items: [privImage.id, "Missing000000001"] });
        // the video goes private after the link was made: the link can still be edited around it
        db.raw.prepare("UPDATE media_items SET visibility = 'private', url = NULL WHERE id = ?").run(pubVideo.id);
        const kept = await api("PATCH", `/share/sets/${set.id}`, { items: [webp.id, pubVideo.id, pubImage.id] });
        expect(kept.status).toBe(200);
        expect(kept.body.set.items.map((i: any) => i.url === null)).toEqual([false, true, false]);
    });

    it("a private link takes any live file; its file addresses follow the new order", async () => {
        const set = await makeSet([pubVideo.id, webp.id], { private: true });
        const key = keyOf(set.url);
        const r = await api("PATCH", `/share/sets/${set.id}`, { items: [privImage.id, webp.id] });
        expect(r.status).toBe(200);
        expect(r.body.set.private).toBe(true);
        expect(r.body.set.items[0].url).toBe(`${SHARE}p/${key}/1.jpg`);
        const file = await share(`/p/${key}/1.jpg`);
        expect(file.status).toBe(200);
        expect(new Uint8Array(await file.arrayBuffer())).toEqual(IMAGE);
    });

    it("expect: another device's change since is a 409 with the current set, and nothing is written", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        await api("PATCH", `/share/sets/${set.id}`, { items: [webp.id, pubVideo.id] });
        const r = await api("PATCH", `/share/sets/${set.id}`, { items: [pubVideo.id, webp.id, pubVideo2.id], expect: [pubVideo.id, webp.id] });
        expect(r.status).toBe(409);
        expect(r.body.error.code).toBe("error.share.changed");
        expect(ids(r.body.set)).toEqual([webp.id, pubVideo.id]);
        expect(ids((await api("GET", "/share/sets")).body.sets[0])).toEqual([webp.id, pubVideo.id]);
    });

    it("a revoked or unknown link is a 404", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        await api("DELETE", `/share/sets/${set.id}`);
        expect((await api("PATCH", `/share/sets/${set.id}`, { title: "x" })).status).toBe(404);
        expect((await api("PATCH", "/share/sets/1234567890123456789", { title: "x" })).status).toBe(404);
    });

    it("the web Worker's service credential may; no key may not", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        const r = await api("PATCH", `/share/sets/${set.id}`, { items: [webp.id, pubVideo.id] }, SVC);
        expect(r.status).toBe(200);
        expect((await api("PATCH", `/share/sets/${set.id}`, { items: [pubVideo.id, webp.id] }, {})).status).toBe(401);
    });
});
