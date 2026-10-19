// Collection sets (APP-API-CONTRACT.md section 28): named groups of share link collections, created,
// listed, renamed, filled and deleted with a client key. The Worker and the real SQL run together.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { withBatch } from "./d1-batch";
import { mintGroupId } from "../src/collection-groups";
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

const collection = async (name: string, set_ids: string[] = []) => (await call("POST", "/share/collections", { name, set_ids })).body.collection.id as string;

let x: string, y: string, z: string;
beforeEach(async () => {
    x = await collection("memes", [a]);
    y = await collection("cats", [b]);
    z = await collection("later");
});

describe("collection groups", () => {
    it("are created with a name and collections, listed newest first, and need a key", async () => {
        const r = await call("POST", "/share/groups", { name: "  weekend  ", collection_ids: [x, y] });
        expect(r.status).toBe(201);
        expect(r.cache).toBe("no-store");
        expect(r.body.group).toMatchObject({ name: "weekend", collection_ids: [x, y] });
        expect(r.body.group.id).toMatch(/^[A-Za-z0-9]{16}$/);
        const empty = await call("POST", "/share/groups", { name: "later" });
        expect(empty.body.group.collection_ids).toEqual([]);
        const l = await call("GET", "/share/groups");
        expect(l.status).toBe(200);
        expect(l.cache).toBe("no-store");
        expect(l.body.groups.map((g: any) => g.name)).toEqual(["later", "weekend"]);
        expect((await call("GET", "/share/groups", undefined, {})).status).toBe(401);
        expect(containerCalls).toEqual([]);
    });

    it("reject a bad name, a malformed or unknown collection", async () => {
        for (const body of [{}, { name: "" }, { name: "x".repeat(61) }, { name: 3 }, { name: "a", collection_ids: ["1"] }, { name: "a", collection_ids: "x" }]) {
            expect((await call("POST", "/share/groups", body)).status, JSON.stringify(body)).toBe(400);
        }
        const r = await call("POST", "/share/groups", { name: "a", collection_ids: [x, "AAAAAAAAAAAAAAAA"] });
        expect(r.status).toBe(409);
        expect(r.body).toMatchObject({ error: { code: "error.group.collection_not_found" }, collection_ids: ["AAAAAAAAAAAAAAAA"] });
        expect((await call("GET", "/share/groups")).body.groups).toEqual([]);
    });

    it("are renamed and filled with PATCH; adding twice is harmless", async () => {
        const id = (await call("POST", "/share/groups", { name: "weekend", collection_ids: [x] })).body.group.id;
        let r = await call("PATCH", `/share/groups/${id}`, { name: "best weekend", add: [y, z, x], remove: [] });
        expect(r.status).toBe(200);
        expect(r.body.group.name).toBe("best weekend");
        expect(r.body.group.collection_ids).toEqual([y, z, x]);
        expect(r.body.group.updated_at).toBeGreaterThan(r.body.group.created_at);
        r = await call("PATCH", `/share/groups/${id}`, { remove: [z] });
        expect(r.body.group.collection_ids).toEqual([y, x]);
        expect((await call("PATCH", `/share/groups/${id}`, {})).status).toBe(400);
        expect((await call("PATCH", `/share/groups/${id}`, { name: "" })).status).toBe(400);
        const missing = await call("PATCH", `/share/groups/${id}`, { add: ["BBBBBBBBBBBBBBBB"] });
        expect(missing.status).toBe(409);
        expect(missing.body.collection_ids).toEqual(["BBBBBBBBBBBBBBBB"]);
        expect((await call("PATCH", "/share/groups/AAAAAAAAAAAAAAAA", { name: "x" })).status).toBe(404);
        expect((await call("PUT", `/share/groups/${id}`, { name: "x" })).status).toBe(404);
        expect((await call("PATCH", "/share/groups/short", { name: "x" })).status).toBe(404);
    });

    it("a deleted collection drops out of every group; deleting a group keeps its collections", async () => {
        const one = (await call("POST", "/share/groups", { name: "one", collection_ids: [x, y] })).body.group.id;
        await call("POST", "/share/groups", { name: "two", collection_ids: [y, z] });
        expect((await call("DELETE", `/share/collections/${y}`)).status).toBe(200);
        const l = (await call("GET", "/share/groups")).body.groups;
        expect(l.map((g: any) => [g.name, g.collection_ids])).toEqual([["two", [z]], ["one", [x]]]);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM collection_group_items WHERE collection_id = ?").get(y)).toEqual({ n: 0 });
        expect((await call("PATCH", `/share/groups/${one}`, { add: [y] })).status).toBe(409);
        expect((await call("DELETE", `/share/groups/${one}`)).status).toBe(200);
        expect((await call("DELETE", `/share/groups/${one}`)).status).toBe(404);
        expect((await call("GET", "/share/groups")).body.groups.map((g: any) => g.name)).toEqual(["two"]);
        const cols = (await call("GET", "/share/collections")).body.collections.map((c: any) => c.id);
        expect(cols).toContain(x);
        expect(cols).toContain(z);
    });

    it("are off without the share host, and a service credential gets 404", async () => {
        const r = await handleRequest(new Request(`${API}/share/groups`, { headers: AUTH }), { ...env, SHARE_BASE_URL: "" }, container, { now: () => 1 });
        expect(r.status).toBe(404);
        expect((await call("GET", "/share/groups", undefined, { "x-cobalt-service": INTERNAL })).status).toBe(404);
    });

    it("are advertised in /capabilities with the share host", async () => {
        const caps = (await (await get(`${API}/capabilities`)).json()) as any;
        expect(caps.features.share_groups).toBe(true);
        expect(caps.features.share_collections).toBe(true);
    });

    it("ids are 16 letters and digits", () => {
        expect(mintGroupId()).toMatch(/^[A-Za-z0-9]{16}$/);
    });
});
