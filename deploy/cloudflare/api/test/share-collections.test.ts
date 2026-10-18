// Share link collections (APP-API-CONTRACT.md section 26): named folders of gallery links, created,
// listed, renamed, filled and deleted with a client key. The Worker and the real SQL run together.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { withBatch } from "./d1-batch";
import { mintCollectionId } from "../src/share-collections";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
let KEY_HASH = "";
let db: FakeD1;
let containerCalls: string[];
let env: WorkerEnv;

const container = {
    async fetch(r: Request) {
        containerCalls.push(new URL(r.url).pathname);
        return new Response("{}", { headers: { "content-type": "application/json" } });
    },
};

let n = 0;
const row = (over: Record<string, unknown>) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: "x_2105237035271258436.mp4",
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
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
};

const get = (url: string, init: RequestInit = {}, e: WorkerEnv = env) =>
    handleRequest(new Request(url, init), e, container, { now: () => 5_000 });

const meta = (html: string, key: string): string | null => {
    const m = new RegExp(`<meta (?:property|name)="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(html);
    return m ? m[1] : null;
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = withBatch(createFakeD1());
    containerCalls = [];
    env = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
});


const API = "https://api.capybaraharmony.com";
const create = async (body: unknown) => {
    const r = await get(`${API}/share/sets`, { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: JSON.stringify(body) });
    return { status: r.status, body: (await r.json()) as any };
};
const list = async () => (await (await get(`${API}/share/sets`, { headers: AUTH })).json()) as any;

let video: any, webp: any, photo: any, privateOne: any, fifth: any;
beforeEach(() => {
    video = row({ visibility: "public", public_key: "ViDeO00001.mp4", poster: `${MEDIA}PoStEr0001.jpg`, width: 3840, height: 2160 });
    webp = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", content_type: "image/webp", width: 480, height: 270 });
    photo = row({ visibility: "public", public_key: "PhOtO00001.jpg", content_type: "image/jpeg", width: 1080, height: 1350, duration: null });
    privateOne = row({ r2_key: "originals/private.mp4" });
    fifth = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp02.webp", content_type: "image/webp" });
});


let t = 10_000;
const call = async (method: string, path: string, body?: unknown, headers: Record<string, string> = AUTH) => {
    t += 1000;
    const r = await handleRequest(
        new Request(`${API}${path}`, { method, headers: { ...headers, "content-type": "application/json" }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) }),
        env,
        container,
        { now: () => t },
    );
    const text = await r.text();
    return { status: r.status, body: (text ? JSON.parse(text) : null) as any, cache: r.headers.get("cache-control") };
};

let a: string, b: string, c: string;
beforeEach(async () => {
    a = (await create({ items: [video.id, webp.id] })).body.set.id;
    b = (await create({ items: [photo.id, webp.id] })).body.set.id;
    c = (await create({ items: [video.id, photo.id] })).body.set.id;
});

describe("collections", () => {
    it("are created with a name and links, listed newest first, and need a key", async () => {
        const r = await call("POST", "/share/collections", { name: "  memes  ", set_ids: [a, b] });
        expect(r.status).toBe(201);
        expect(r.cache).toBe("no-store");
        expect(r.body.collection).toMatchObject({ name: "memes", set_ids: [a, b] });
        expect(r.body.collection.id).toMatch(/^[A-Za-z0-9]{16}$/);
        const empty = await call("POST", "/share/collections", { name: "later" });
        expect(empty.body.collection.set_ids).toEqual([]);
        const l = await call("GET", "/share/collections");
        expect(l.body.collections.map((x: any) => x.name)).toEqual(["later", "memes"]);
        expect((await call("GET", "/share/collections", undefined, {})).status).toBe(401);
        expect(containerCalls).toEqual([]);
    });

    it("reject a bad name, a malformed or unknown link", async () => {
        for (const body of [{}, { name: "" }, { name: "x".repeat(61) }, { name: 3 }, { name: "a", set_ids: ["1"] }, { name: "a", set_ids: "x" }]) {
            expect((await call("POST", "/share/collections", body)).status, JSON.stringify(body)).toBe(400);
        }
        const r = await call("POST", "/share/collections", { name: "a", set_ids: [a, "1234567890123456789"] });
        expect(r.status).toBe(409);
        expect(r.body).toMatchObject({ error: { code: "error.collection.link_not_found" }, set_ids: ["1234567890123456789"] });
    });

    it("are renamed and filled with PATCH; adding twice is harmless", async () => {
        const id = (await call("POST", "/share/collections", { name: "memes", set_ids: [a] })).body.collection.id;
        let r = await call("PATCH", `/share/collections/${id}`, { name: "best memes", add: [b, c, a], remove: [] });
        expect(r.status).toBe(200);
        expect(r.body.collection.name).toBe("best memes");
        expect(r.body.collection.set_ids).toEqual([b, c, a]);
        r = await call("PATCH", `/share/collections/${id}`, { remove: [c] });
        expect(r.body.collection.set_ids).toEqual([b, a]);
        expect((await call("PATCH", `/share/collections/${id}`, {})).status).toBe(400);
        expect((await call("PATCH", `/share/collections/${id}`, { name: "" })).status).toBe(400);
        expect((await call("PATCH", "/share/collections/AAAAAAAAAAAAAAAA", { name: "x" })).status).toBe(404);
        expect((await call("PUT", `/share/collections/${id}`, { name: "x" })).status).toBe(404);
    });

    it("a revoked link drops out; deleting a collection keeps its links live", async () => {
        const id = (await call("POST", "/share/collections", { name: "memes", set_ids: [a, b] })).body.collection.id;
        expect((await call("DELETE", `/share/sets/${a}`)).status).toBe(200);
        expect((await call("GET", "/share/collections")).body.collections[0].set_ids).toEqual([b]);
        expect((await call("PATCH", `/share/collections/${id}`, { add: [a] })).status).toBe(409);
        const d = await call("DELETE", `/share/collections/${id}`);
        expect(d.status).toBe(200);
        expect((await call("DELETE", `/share/collections/${id}`)).status).toBe(404);
        expect((await call("GET", "/share/collections")).body.collections).toEqual([]);
        expect((await list()).sets.map((s: any) => s.id)).toContain(b);
        expect((await get(`${SHARE}g/${b}`)).status).toBe(200);
    });

    it("a link can sit in several collections", async () => {
        await call("POST", "/share/collections", { name: "one", set_ids: [a] });
        await call("POST", "/share/collections", { name: "two", set_ids: [a, c] });
        const l = (await call("GET", "/share/collections")).body.collections;
        expect(l.map((x: any) => [x.name, x.set_ids])).toEqual([["two", [a, c]], ["one", [a]]]);
    });

    it("are off without the share host", async () => {
        const r = await handleRequest(new Request(`${API}/share/collections`, { headers: AUTH }), { ...env, SHARE_BASE_URL: "" }, container, { now: () => 1 });
        expect(r.status).toBe(404);
    });

    it("ids are 16 letters and digits", () => {
        expect(mintCollectionId()).toMatch(/^[A-Za-z0-9]{16}$/);
    });
});
