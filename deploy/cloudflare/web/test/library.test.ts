// /library page and /api/library*. Runs the real SQL (migrations 0001-0004) on
// node:sqlite; R2 and the API Worker are in-memory fakes. Schema used: the real
// d1/migrations/0004_library.sql (it was present when these tests were written).
import { readFileSync } from "node:fs";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import {
    API_BASE, DEFAULT_PAGE, LIBRARY_CSP, MAX_UPLOAD_BYTES, UPLOAD_TYPES, handleLibrary, matchRoute,
} from "../src/library";
import { LIBRARY_HTML } from "../src/library/page.generated";
import config from "../cloudflare.config";
import type { Env } from "../src/keys";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import {
    AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer,
} from "./support";

const SERVICE_KEY = "7a1d1b0e-3f0c-4a53-8f55-2f1b8a9d0c11";
const SID = "q3Zk9vT1mW8aLm2xPq8Rt4";
const SID2 = "Zz9kRt1mW8aLm2xPq8Rt4A";
const JOB = "Ab12Cd34Ef56Gh78Ij90";
const MEDIA = "https://media.capybaraharmony.com/";

// The exact header set pinned in LIBRARY-CONTRACT.md (studio CSP plus 'self' API calls and media).
const CONTRACT_CSP =
    "default-src 'self'; base-uri 'none'; connect-src 'self' https://api.capybaraharmony.com; media-src 'self' https://media.capybaraharmony.com blob:; img-src 'self' data: blob: https://media.capybaraharmony.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

// ---------- fakes ----------

type StoredObject = { bytes: Uint8Array | null; size: number; contentType?: string };

class FakeR2 {
    objects = new Map<string, StoredObject>();
    puts: { key: string; valueKind: string; contentType?: string }[] = [];
    failPut = false;
    failDelete = false;
    deletes: string[] = [];

    async put(key: string, value: unknown, opts?: { httpMetadata?: { contentType?: string } }) {
        if (this.failPut) throw new Error("R2 put failed");
        const valueKind = value instanceof ReadableStream ? "stream" : typeof value;
        let size = 0;
        const kept: Uint8Array[] = [];
        if (value instanceof ReadableStream) {
            const reader = (value as ReadableStream<Uint8Array>).getReader();
            for (;;) {
                const { done, value: chunk } = await reader.read();
                if (done) break;
                size += chunk.byteLength;
                if (size <= 4_000_000) kept.push(chunk);
            }
        } else {
            const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value as ArrayBuffer);
            size = bytes.byteLength;
            kept.push(bytes);
        }
        let bytes: Uint8Array | null = null;
        if (size <= 4_000_000) {
            bytes = new Uint8Array(size);
            let o = 0;
            for (const c of kept) (bytes.set(c, o), (o += c.byteLength));
        }
        this.puts.push({ key, valueKind, contentType: opts?.httpMetadata?.contentType });
        this.objects.set(key, { bytes, size, contentType: opts?.httpMetadata?.contentType });
        return { key, size };
    }

    async get(key: string) {
        const o = this.objects.get(key);
        if (!o || !o.bytes) return null;
        const bytes = o.bytes;
        const body = new ReadableStream<Uint8Array>({
            start(c) {
                // two chunks, so the copy loop really loops
                const mid = Math.floor(bytes.byteLength / 2);
                c.enqueue(bytes.slice(0, mid));
                c.enqueue(bytes.slice(mid));
                c.close();
            },
        });
        // pipeTo between streams is not implemented in the Workers runtime: make it fail loudly here.
        const boom = () => {
            throw new Error("pipeTo is not implemented");
        };
        (body as any).pipeTo = boom;
        (body as any).pipeThrough = boom;
        return { key, size: o.size, body, httpMetadata: { contentType: o.contentType } };
    }

    async delete(key: string) {
        if (this.failDelete) throw new Error("R2 delete failed");
        this.deletes.push(key);
        this.objects.delete(key);
    }
}

type ApiCall = { url: string; method: string; headers: Record<string, string>; body: unknown };

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let db: FakeD1;
let clock: number;
let originals: FakeR2;
let media: FakeR2;
let apiCalls: ApiCall[];
let apiReply: (c: ApiCall) => Response | Promise<Response>;
let apiThrows: boolean;
let env: Env;
let idCounter: number;

const jsonRes = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

beforeEach(() => {
    db = createFakeD1();
    clock = NOW;
    originals = new FakeR2();
    media = new FakeR2();
    apiCalls = [];
    apiThrows = false;
    apiReply = () => jsonRes(200, { status: "success" });
    idCounter = 0;
    env = {
        DB: db,
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        MEDIA: media as unknown as R2Bucket,
        ORIGINALS: originals as unknown as R2Bucket,
        MEDIA_BASE_URL: MEDIA,
        API: {
            fetch: async (req: Request) => {
                if (apiThrows) throw new Error("service binding down");
                const headers: Record<string, string> = {};
                req.headers.forEach((v, k) => (headers[k] = v));
                const text = await req.text();
                const call: ApiCall = { url: req.url, method: req.method, headers, body: text ? JSON.parse(text) : undefined };
                apiCalls.push(call);
                return apiReply(call);
            },
        } as unknown as Fetcher,
        COBALT_API_KEY: SERVICE_KEY,
    };
});

const deps = () => ({
    jwks: newCache(makeJwksFetch(() => [signer]).fetchFn),
    now: () => clock,
    fixedLength: () => new TransformStream<Uint8Array, Uint8Array>(),
    // 16 chars for items, 10 for public names: distinct, deterministic, base62
    randomId: (n: number) => `${++idCounter}`.padStart(n, "0").slice(-n).replace(/^0/, "a"),
});

type Opts = {
    token?: string | null;
    origin?: string | null;
    body?: unknown;
    raw?: BodyInit | null;
    headers?: Record<string, string>;
    contentType?: string | null;
};
function call(method: string, path: string, o: Opts = {}) {
    const headers = new Headers(o.headers);
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && method !== "GET") headers.set("Origin", o.origin ?? WEB_ORIGIN);
    let body: BodyInit | undefined;
    if (method === "GET" || method === "HEAD") body = undefined;
    else if (o.raw !== undefined && o.raw !== null) body = o.raw;
    else if (o.body !== undefined) {
        body = JSON.stringify(o.body);
        if (o.contentType !== null) headers.set("content-type", o.contentType ?? "application/json");
    }
    const init: RequestInit & { duplex?: string } = { method, headers, body };
    if (body instanceof ReadableStream) init.duplex = "half";
    return handleLibrary(new Request(`https://cobalt.capybaraharmony.com${path}`, init), env, deps());
}
const json = async (r: Response) => JSON.parse(await r.text());
const errorCode = async (r: Response) => (await json(r)).error.code;

// ---------- seed helpers ----------

type Seed = Partial<{
    id: string; kind: string; source: string; bucket: string; r2_key: string; url: string | null; name: string;
    content_type: string | null; bytes: number | null; width: number | null; height: number | null;
    duration: number | null; link: string | null; session_id: string | null; created_at: number; deleted_at: number | null;
}>;
let seedN = 0;
function seedItem(o: Seed = {}) {
    seedN++;
    const id = o.id ?? `item${String(seedN).padStart(12, "0")}`;
    const kind = o.kind ?? "public";
    const row = {
        id, kind, source: "webp", bucket: kind === "public" ? "media" : "originals",
        r2_key: kind === "public" ? `pub${seedN}.webp` : `uploads/${id}.mp4`,
        url: kind === "public" ? `${MEDIA}pub${seedN}.webp` : null, name: `name${seedN}`,
        content_type: kind === "public" ? "image/webp" : "video/mp4", bytes: 1000, width: 480, height: 270,
        duration: null, link: null, session_id: null, created_at: NOW - seedN * 1000, deleted_at: null, ...o,
    };
    db.raw.prepare(
        `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?)`,
    ).run(row.id, row.kind, row.source, row.bucket, row.r2_key, row.url, row.name, row.content_type, row.bytes, row.width, row.height, row.duration, row.link, row.session_id, row.created_at, row.deleted_at);
    return row;
}
function seedStudio(o: Partial<{ id: string; status: string; r2_key: string | null; created_at: number; expires_at: number; link: string | null; title: string | null; duration: number | null }> = {}) {
    const id = o.id ?? SID;
    const created = o.created_at ?? NOW - 5000;
    db.raw.prepare(
        `INSERT INTO studio_sessions (id, link, title, status, r2_key, content_type, bytes, duration, created_at, expires_at)
         VALUES (?,?,?,?,?,?,?,?,?,?)`,
    ).run(id, o.link === undefined ? "https://x.com/a/status/1" : o.link, o.title === undefined ? "maria_rcks" : o.title, o.status ?? "ready", o.r2_key === undefined ? `originals/${id}.mp4` : o.r2_key, "video/mp4", 5000, o.duration === undefined ? 9.6 : o.duration, created, o.expires_at ?? created + 7 * 86400_000);
    return id;
}
const addRender = (sid: string, status: string, id = `r${Math.random().toString(36).slice(2, 12).padEnd(19, "0")}`) =>
    db.raw.prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES (?,?,?,?)").run(id, sid, status, NOW);
const rowOf = (id: string) => db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(id) as any;
const sessionOf = (id: string) => db.raw.prepare("SELECT * FROM studio_sessions WHERE id = ?").get(id) as any;
const bytesOf = (n: number, fill = 7) => new Uint8Array(n).fill(fill);

const ROUTES: [string, string][] = [
    ["GET", "/library"],
    ["GET", "/api/library"],
    ["POST", "/api/library/link"],
    ["PUT", "/api/library/upload?name=a.gif"],
    ["GET", `/api/library/webp/${JOB}`],
    ["GET", `/api/library/studio/${SID}`],
    ["POST", `/api/library/studio/${SID}/publish`],
    ["POST", "/api/library/items/aaaaaaaaaaaaaaaa/publish"],
    ["POST", "/api/library/items/aaaaaaaaaaaaaaaa/studio"],
    ["DELETE", "/api/library/items/aaaaaaaaaaaaaaaa"],
    ["DELETE", `/api/library/studios/${SID}`],
];

// ---------- routing config ----------

describe("routing config", () => {
    it("runs the Worker first for the library page and API, and keeps the rest", () => {
        const rwf = (config as any).worker.assets.runWorkerFirst as string[];
        expect(rwf).toEqual(expect.arrayContaining(["/library", "/library/*", "/api/library", "/api/library/*", "/api/keys", "/api/keys/*", "/studio", "/studio/*"]));
        expect(rwf).toHaveLength(11); // keys 2, studio 2, library 4, logs 3 (logs.test.ts)
    });
    it("binds the buckets, the API service and the internal key", () => {
        const e = (config as any).worker.env;
        expect(e.MEDIA).toMatchObject({ type: "r2", name: "cobalt-media" });
        expect(e.ORIGINALS).toMatchObject({ type: "r2", name: "cobalt-originals" });
        expect(e.API).toMatchObject({ type: "worker", worker: "cobalt-api" });
        expect(e.COBALT_API_KEY).toMatchObject({ type: "secret" });
        expect(e.DB).toBeDefined();
    });
    it("the Worker entry dispatches /library and /api/library to the library, never to ASSETS", async () => {
        const seen: string[] = [];
        (env as any).ASSETS = { fetch: async (r: Request) => (seen.push(new URL(r.url).pathname), new Response("asset")) };
        for (const p of ["/library", "/library/x", "/api/library", "/api/library/link"]) {
            const res = await worker.fetch(new Request(WEB_ORIGIN + p), env); // no JWT
            expect(res.status).toBe(401);
        }
        expect(seen).toEqual([]);
        const other = await worker.fetch(new Request(WEB_ORIGIN + "/libraryx"), env);
        expect(await other.text()).toBe("asset");
    });
});

// ---------- auth, origin, shape ----------

describe("authentication", () => {
    it.each(ROUTES)("%s %s without a JWT is 401, error shape, and touches nothing", async (method, path) => {
        db.breakIt();
        originals.failPut = media.failPut = true;
        const r = await call(method, path, { token: null, body: {} });
        expect(r.status).toBe(401);
        expect(await json(r)).toEqual({ status: "error", error: { code: "unauthorized" } });
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(apiCalls).toEqual([]);
        expect(originals.puts).toEqual([]);
    });
    it("a JWT for another email is 401", async () => {
        const bad = await signer.sign(goodClaims({ email: "someone@else.com" }));
        expect((await call("GET", "/api/library", { token: bad })).status).toBe(401);
    });
    it("a JWT for another audience is 401", async () => {
        const bad = await signer.sign(goodClaims({ aud: ["nope"] }));
        expect((await call("GET", "/library", { token: bad })).status).toBe(401);
    });
    it("an expired JWT is 401", async () => {
        const old = await signer.sign(goodClaims({ exp: NOW / 1000 - 3600 }));
        expect((await call("GET", "/api/library", { token: old })).status).toBe(401);
    });
    it("auth comes before Origin: unauthenticated + bad origin is 401, not 403", async () => {
        const r = await call("DELETE", "/api/library/items/aaaaaaaaaaaaaaaa", { token: null, origin: "https://evil.example" });
        expect(r.status).toBe(401);
    });
});

describe("origin check (CSRF)", () => {
    const mutating = ROUTES.filter(([m]) => m !== "GET");
    it.each(mutating)("%s %s needs Origin = the web origin", async (method, path) => {
        for (const origin of [null, "https://evil.example", "https://cobalt.capybaraharmony.com.evil.example", "http://cobalt.capybaraharmony.com"]) {
            const r = await call(method, path, { origin, body: { url: "https://x.com/a", action: "webp" } });
            expect(r.status).toBe(403);
            expect(await json(r)).toEqual({ status: "error", error: { code: "forbidden" } });
        }
        expect(apiCalls).toEqual([]);
        expect(originals.puts).toEqual([]);
        expect(media.puts).toEqual([]);
    });
    it("GET needs no Origin", async () => {
        expect((await call("GET", "/api/library")).status).toBe(200);
    });
});

describe("route shape", () => {
    it.each([
        ["GET", "/api/library/nope"],
        ["GET", "/api/library/"],
        ["GET", "/library/"],
        ["GET", "/library/x"],
        ["GET", "/api/library/webp/short"],
        ["GET", `/api/library/webp/${"a".repeat(33)}`],
        ["GET", `/api/library/studio/${SID.slice(1)}`],
        ["GET", `/api/library/studio/${SID}x`],
        ["POST", "/api/library/items/short/publish"],
        ["POST", "/api/library/items/aaaaaaaaaaaaaaaa/other"],
        ["DELETE", "/api/library/items/aaaaaaaaaaaaaaaaa"],
        ["DELETE", "/api/library/studios/short"],
    ])("%s %s is a 404", async (method, path) => {
        const r = await call(method, path, { body: {} });
        expect(r.status).toBe(404);
        expect(await errorCode(r)).toBe("error.library.not_found");
    });
    it.each([
        ["POST", "/api/library", "GET"],
        ["GET", "/api/library/link", "POST"],
        ["POST", "/api/library/upload", "PUT"],
        ["DELETE", `/api/library/webp/${JOB}`, "GET"],
        ["DELETE", `/api/library/studio/${SID}`, "GET"],
        ["GET", `/api/library/studio/${SID}/publish`, "POST"],
        ["GET", "/api/library/items/aaaaaaaaaaaaaaaa", "DELETE"],
        ["POST", `/api/library/studios/${SID}`, "DELETE"],
        ["POST", "/library", "GET, HEAD"],
    ])("%s %s is 405 with allow: %s", async (method, path, allow) => {
        const r = await call(method, path, { body: {} });
        expect(r.status).toBe(405);
        expect(r.headers.get("allow")).toBe(allow);
    });
    it("matchRoute only accepts the pinned id shapes", () => {
        expect(matchRoute("/api/library/items/AAAAAAAAAAAAAAAA/publish")).toEqual({ name: "itemPublish", id: "AAAAAAAAAAAAAAAA" });
        expect(matchRoute(`/api/library/studios/${SID}`)).toEqual({ name: "studioDelete", id: SID });
        expect(matchRoute("/api/library/items/aaaa-aaaaaaaaaaaa")).toBeNull();
    });
});

// ---------- the page ----------

describe("GET /library", () => {
    it("serves the page with exactly the contract headers and never touches ASSETS or D1", async () => {
        db.breakIt();
        const res = await call("GET", "/library");
        expect(res.status).toBe(200);
        expect(res.headers.get("content-security-policy")).toBe(CONTRACT_CSP);
        expect(LIBRARY_CSP).toBe(CONTRACT_CSP);
        expect(res.headers.get("referrer-policy")).toBe("no-referrer");
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("x-content-type-options")).toBe("nosniff");
        expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
        expect(res.headers.get("cross-origin-embedder-policy")).toBeNull();
        expect(await res.text()).toBe(LIBRARY_HTML);
    });
    it("answers HEAD with the headers and no body", async () => {
        const res = await call("HEAD", "/library");
        expect(res.status).toBe(200);
        expect(await res.text()).toBe("");
        expect(res.headers.get("content-security-policy")).toBe(CONTRACT_CSP);
    });
});

describe("embedded page", () => {
    it("page.generated.ts is in sync with page.html (run npm run library:build)", () => {
        const html = readFileSync(new URL("../src/library/page.html", import.meta.url), "utf8");
        expect(LIBRARY_HTML).toBe(html);
    });
    it("is self-contained and CSP-clean", () => {
        expect(LIBRARY_HTML).toContain('name="viewport"');
        expect(LIBRARY_HTML).not.toMatch(/<script[^>]*\bsrc=/i);
        const hosts = new Set([...LIBRARY_HTML.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)].map((m) => m[1]));
        for (const h of hosts) {
            expect(["api.capybaraharmony.com", "fonts.googleapis.com", "fonts.gstatic.com", "media.capybaraharmony.com"]).toContain(h);
        }
    });
    it("has a valid inline script", () => {
        const m = /<script>([\s\S]*)<\/script>/.exec(LIBRARY_HTML);
        expect(m).toBeTruthy();
        expect(() => new Function(m![1]!)).not.toThrow();
    });
    it("only honours ?api= on localhost", () => {
        expect(LIBRARY_HTML).toMatch(/\^\(localhost\|127\\\.0\\\.0\\\.1\|\\\[::1\\\]\)\$/);
    });
    it("fetches with redirect: manual (expired login) and holds the same upload limit and types as the server", () => {
        expect(LIBRARY_HTML).toContain('redirect: "manual"');
        expect(LIBRARY_HTML).toContain(`MAX_BYTES = ${MAX_UPLOAD_BYTES}`);
        for (const [type, ext] of Object.entries(UPLOAD_TYPES)) expect(LIBRARY_HTML).toContain(`"${type}": "${ext}"`);
        expect(LIBRARY_HTML).toContain("your login expired, reload to sign in");
    });
});

// ---------- GET /api/library ----------

describe("GET /api/library", () => {
    it("returns the contract shape: items, studios, usage, next_before", async () => {
        const pub = seedItem({ kind: "public", source: "webp", name: "a.webp", bytes: 600, link: "https://x.com/a", session_id: SID, duration: 3.5 });
        seedStudio({ id: SID });
        addRender(SID, "success");
        addRender(SID, "success");
        addRender(SID, "error");
        addRender(SID, "pending");
        const r = await call("GET", "/api/library");
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const b = await json(r);
        expect(Object.keys(b).sort()).toEqual(["items", "next_before", "studios", "usage"]);
        expect(b.items).toEqual([
            {
                id: pub.id, kind: "public", source: "webp", name: "a.webp", url: pub.url, content_type: "image/webp",
                bytes: 600, width: 480, height: 270, duration: 3.5, link: "https://x.com/a", session_id: SID, created_at: pub.created_at,
            },
        ]);
        expect(Object.keys(b.items[0]).sort()).toEqual(
            ["id", "kind", "source", "name", "url", "content_type", "bytes", "width", "height", "duration", "link", "session_id", "created_at"].sort(),
        );
        expect(b.studios).toEqual([
            {
                id: SID, url: `${WEB_ORIGIN}/studio/${SID}`, status: "ready", link: "https://x.com/a/status/1", title: "maria_rcks",
                duration: 9.6, renders: 2, created_at: NOW - 5000, expires_at: NOW - 5000 + 7 * 86400_000,
            },
        ]);
        expect(b.next_before).toBeNull();
        // never leaks storage internals
        expect(JSON.stringify(b)).not.toMatch(/r2_key|bucket|key_id|deleted_at/);
    });

    it("excludes deleted items, and expired or failed studios", async () => {
        seedItem({ name: "keep" });
        seedItem({ name: "gone", deleted_at: NOW - 1 });
        seedStudio({ id: SID });
        seedStudio({ id: SID2, expires_at: NOW - 1 });
        seedStudio({ id: "Er5mJ2xG9bL0uT4vKd7QoP", status: "error" });
        seedStudio({ id: "Sv3hW6yU0jD5gF2rNc9KbM", status: "saving" });
        const b = await json(await call("GET", "/api/library"));
        expect(b.items.map((i: any) => i.name)).toEqual(["keep"]);
        expect(b.studios.map((s: any) => s.id).sort()).toEqual([SID, "Sv3hW6yU0jD5gF2rNc9KbM"].sort());
    });

    it("filters: all, public, private, studio", async () => {
        const pub = seedItem({ kind: "public" });
        const priv = seedItem({ kind: "private", source: "upload" });
        seedStudio({ id: SID });
        const get = async (f: string) => json(await call("GET", `/api/library?filter=${f}`));
        const all = await get("all");
        expect(all.items.map((i: any) => i.id).sort()).toEqual([pub.id, priv.id].sort());
        expect(all.studios).toHaveLength(1);
        const p = await get("public");
        expect(p.items.map((i: any) => i.id)).toEqual([pub.id]);
        expect(p.studios).toEqual([]);
        const v = await get("private");
        expect(v.items.map((i: any) => i.id)).toEqual([priv.id]);
        expect(v.studios).toEqual([]);
        const s = await get("studio");
        expect(s.items).toEqual([]);
        expect(s.studios.map((x: any) => x.id)).toEqual([SID]);
    });

    it("usage counts public and private bytes of live items only, whatever the filter", async () => {
        seedItem({ kind: "public", bytes: 100 });
        seedItem({ kind: "public", bytes: 50 });
        seedItem({ kind: "private", bytes: 7000 });
        seedItem({ kind: "private", bytes: 999, deleted_at: NOW });
        seedItem({ kind: "public", bytes: null });
        for (const f of ["all", "public", "private", "studio"]) {
            expect((await json(await call("GET", `/api/library?filter=${f}`))).usage).toEqual({ public_bytes: 150, private_bytes: 7000 });
        }
        const empty = createFakeD1();
        (env as any).DB = empty;
        expect((await json(await call("GET", "/api/library"))).usage).toEqual({ public_bytes: 0, private_bytes: 0 });
    });

    it("paginates newest first across items and studios with next_before", async () => {
        const ids: string[] = [];
        for (let i = 0; i < 5; i++) ids.push(seedItem({ created_at: NOW - 10_000 + i * 1000 }).id); // oldest ... newest
        seedStudio({ id: SID, created_at: NOW - 8500 }); // between item 1 (NOW-9000) and item 2 (NOW-8000)
        const seen: string[] = [];
        let before: number | null = null;
        let pages = 0;
        do {
            const b: any = await json(await call("GET", `/api/library?limit=2${before ? `&before=${before}` : ""}`));
            const merged = [...b.items, ...b.studios].sort((x: any, y: any) => y.created_at - x.created_at);
            expect(merged.length).toBeLessThanOrEqual(2);
            seen.push(...merged.map((e: any) => e.id));
            before = b.next_before;
            pages++;
        } while (before && pages < 10);
        expect(pages).toBe(3);
        expect(seen).toEqual([ids[4], ids[3], ids[2], SID, ids[1], ids[0]]);
        expect(new Set(seen).size).toBe(6);
    });

    it("next_before is null on the last page and after exactly `limit` rows", async () => {
        seedItem(); seedItem();
        expect((await json(await call("GET", "/api/library?limit=2"))).next_before).toBeNull();
        expect((await json(await call("GET", "/api/library?limit=1"))).next_before).not.toBeNull();
    });

    it("defaults to a page of 48 and caps limit at 100", async () => {
        for (let i = 0; i < 60; i++) seedItem({ created_at: NOW - i });
        expect((await json(await call("GET", "/api/library"))).items).toHaveLength(DEFAULT_PAGE);
        expect((await json(await call("GET", "/api/library?limit=100"))).items).toHaveLength(60);
        expect((await call("GET", "/api/library?limit=101")).status).toBe(400);
    });

    it.each([["filter=bogus"], ["limit=0"], ["limit=-1"], ["limit=abc"], ["limit=1.5"], ["before=abc"], ["before=0"], ["before=-5"]])(
        "rejects ?%s with 400",
        async (qs) => {
            const r = await call("GET", `/api/library?${qs}`);
            expect(r.status).toBe(400);
            expect(await errorCode(r)).toBe("error.library.bad_request");
        },
    );

    it("a D1 outage is a 500 error, not a leak", async () => {
        db.breakIt();
        const r = await call("GET", "/api/library");
        expect(r.status).toBe(500);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.library.server" } });
    });
});

// ---------- the API Worker (service binding) ----------

describe("service calls", () => {
    it("every call carries x-cobalt-service and nothing from the browser", async () => {
        apiReply = () => jsonRes(202, { status: "pending", id: JOB });
        await call("POST", "/api/library/link", {
            body: { url: "https://x.com/a/status/1", action: "webp" },
            headers: { cookie: "CF_Authorization=secret", authorization: "Api-Key leak" },
        });
        expect(apiCalls).toHaveLength(1);
        const c = apiCalls[0]!;
        expect(c.url).toBe(`${API_BASE}/webp`);
        expect(c.headers["x-cobalt-service"]).toBe(SERVICE_KEY);
        for (const h of ["authorization", "cookie", "cf-access-jwt-assertion", "origin"]) expect(c.headers[h]).toBeUndefined();
    });
    it("the internal key never reaches the browser", async () => {
        apiReply = () => jsonRes(200, { status: "pending", id: JOB });
        const r = await call("GET", `/api/library/webp/${JOB}`);
        const text = await r.text();
        expect(text).not.toContain(SERVICE_KEY);
        expect([...r.headers.values()].join("\n")).not.toContain(SERVICE_KEY);
    });
    it("a missing internal key is a 502 and nothing is sent", async () => {
        (env as any).COBALT_API_KEY = "";
        const r = await call("POST", "/api/library/link", { body: { url: "https://x.com/a", action: "webp" } });
        expect(r.status).toBe(502);
        expect(apiCalls).toEqual([]);
    });
    it("a downed API Worker is a 502 with a code", async () => {
        apiThrows = true;
        const r = await call("GET", `/api/library/studio/${SID}`);
        expect(r.status).toBe(502);
        expect(await errorCode(r)).toBe("error.library.upstream");
    });
    it("an upstream 401/403 (wrong service key) is 502, never 401 (the page would say 'login expired')", async () => {
        for (const status of [401, 403]) {
            apiReply = () => jsonRes(status, { status: "error", error: { code: "error.api.auth.key.invalid" } });
            const r = await call("GET", `/api/library/studio/${SID}`);
            expect(r.status).toBe(502);
            expect(await errorCode(r)).toBe("error.library.upstream");
        }
    });
    it("garbage from upstream is a 502", async () => {
        apiReply = () => new Response("<html>oops</html>", { status: 200 });
        expect((await call("GET", `/api/library/studio/${SID}`)).status).toBe(502);
    });
});

describe("POST /api/library/link", () => {
    const post = (body: unknown, o: Opts = {}) => call("POST", "/api/library/link", { body, ...o });

    it("webp: POST /webp, answers 202 {status:'pending', job}", async () => {
        apiReply = () => jsonRes(202, { status: "pending", id: JOB });
        const r = await post({ url: "https://x.com/a/status/1", action: "webp" });
        expect(r.status).toBe(202);
        expect(await json(r)).toEqual({ status: "pending", job: JOB });
        expect(apiCalls[0]).toMatchObject({ method: "POST", body: { url: "https://x.com/a/status/1" } });
    });
    it.each(["studio", "host", "keep"])("%s: POST /studio, answers {status:'success', studio, url}", async (action) => {
        apiReply = () => jsonRes(201, { status: "success", id: SID, url: `${WEB_ORIGIN}/studio/${SID}` });
        const r = await post({ url: "https://x.com/a/status/1", action });
        expect(r.status).toBe(201);
        expect(await json(r)).toEqual({ status: "success", studio: SID, url: `${WEB_ORIGIN}/studio/${SID}` });
        expect(apiCalls[0]).toMatchObject({ url: `${API_BASE}/studio`, method: "POST", body: { url: "https://x.com/a/status/1" } });
    });
    it("passes share text through for the API to extract the link from", async () => {
        apiReply = () => jsonRes(202, { status: "pending", id: JOB });
        await post({ url: "look at this https://x.com/a/status/1 wow", action: "webp" });
        expect((apiCalls[0]!.body as any).url).toBe("look at this https://x.com/a/status/1 wow");
    });
    it("passes the API's error codes and statuses through", async () => {
        apiReply = () => jsonRes(400, { status: "error", error: { code: "error.webp.invalid_params" } });
        let r = await post({ url: "https://x.com/a", action: "webp" });
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.webp.invalid_params");
        apiReply = () => jsonRes(429, { status: "error", error: { code: "error.studio.busy" } });
        r = await post({ url: "https://x.com/a", action: "keep" });
        expect(r.status).toBe(429);
        expect(await errorCode(r)).toBe("error.studio.busy");
    });
    it.each([
        ["not json", { raw: "nope", headers: { "content-type": "application/json" } }],
        ["wrong content type", { body: { url: "https://x.com/a", action: "webp" }, contentType: "text/plain" }],
        ["array body", { body: [] }],
        ["no action", { body: { url: "https://x.com/a" } }],
        ["bad action", { body: { url: "https://x.com/a", action: "delete" } }],
        ["no url", { body: { action: "webp" } }],
        ["url not a string", { body: { url: 5, action: "webp" } }],
        ["empty url", { body: { url: "   ", action: "webp" } }],
        ["url too long", { body: { url: "https://x.com/" + "a".repeat(2100), action: "webp" } }],
        ["oversized body", { raw: JSON.stringify({ url: "https://x.com/" + "a".repeat(9000), action: "webp" }), headers: { "content-type": "application/json" } }],
    ] as [string, Opts][])("rejects %s with 400 and never calls the API", async (_n, o) => {
        const r = await call("POST", "/api/library/link", o);
        expect(r.status).toBe(400);
        expect(apiCalls).toEqual([]);
    });
    it("a body with no link in it is error.library.invalid_url", async () => {
        const r = await post({ url: "hello", action: "webp" });
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.library.invalid_url");
        expect(apiCalls).toEqual([]);
    });
});

describe("GET /api/library/webp/<job> and /studio/<sid>", () => {
    it("proxies the poll with wait, and adds job to the webp body", async () => {
        apiReply = () => jsonRes(200, { status: "success", id: JOB, url: `${MEDIA}abc.webp`, bytes: 76000, width: 480, height: 270, seconds: 3.8 });
        const r = await call("GET", `/api/library/webp/${JOB}?wait=20`);
        expect(r.status).toBe(200);
        expect(await json(r)).toMatchObject({ status: "success", job: JOB, url: `${MEDIA}abc.webp`, bytes: 76000, seconds: 3.8 });
        expect(apiCalls[0]).toMatchObject({ method: "GET", url: `${API_BASE}/webp/${JOB}?wait=20` });
    });
    it("clamps wait to 25 and omits it when absent", async () => {
        apiReply = () => jsonRes(200, { status: "pending", id: JOB });
        await call("GET", `/api/library/webp/${JOB}?wait=99`);
        await call("GET", `/api/library/webp/${JOB}`);
        expect(apiCalls.map((c) => c.url)).toEqual([`${API_BASE}/webp/${JOB}?wait=25`, `${API_BASE}/webp/${JOB}`]);
        expect((await call("GET", `/api/library/webp/${JOB}?wait=x`)).status).toBe(400);
    });
    it("a finished-but-failed job keeps its 200 and the error body", async () => {
        apiReply = () => jsonRes(200, { status: "error", error: { code: "error.webp.too_long" } });
        const r = await call("GET", `/api/library/webp/${JOB}`);
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.webp.too_long" } });
    });
    it("proxies the studio session and its 404/410", async () => {
        apiReply = () => jsonRes(200, { status: "ready", id: SID, duration: 9.6, renders: [] });
        const r = await call("GET", `/api/library/studio/${SID}?wait=10`);
        expect(await json(r)).toMatchObject({ status: "ready", duration: 9.6 });
        expect(apiCalls[0]!.url).toBe(`${API_BASE}/studio/${SID}?wait=10`);
        apiReply = () => jsonRes(410, { status: "error", error: { code: "error.studio.expired" } });
        const gone = await call("GET", `/api/library/studio/${SID}`);
        expect(gone.status).toBe(410);
        expect(await errorCode(gone)).toBe("error.studio.expired");
    });
});

describe("POST /api/library/studio/<sid>/publish", () => {
    it("proxies the publish and returns the API's success body", async () => {
        apiReply = () => jsonRes(201, { status: "success", url: `${MEDIA}x.mp4`, bytes: 5000, content_type: "video/mp4", item_id: "i1" });
        const r = await call("POST", `/api/library/studio/${SID}/publish`);
        expect(r.status).toBe(201);
        expect(await json(r)).toMatchObject({ status: "success", url: `${MEDIA}x.mp4`, bytes: 5000, content_type: "video/mp4" });
        expect(apiCalls[0]).toMatchObject({ method: "POST", url: `${API_BASE}/studio/${SID}/publish` });
    });
    it("passes not_ready 409 and storage 502", async () => {
        apiReply = () => jsonRes(409, { status: "error", error: { code: "error.studio.not_ready" } });
        const r = await call("POST", `/api/library/studio/${SID}/publish`);
        expect(r.status).toBe(409);
        expect(await errorCode(r)).toBe("error.studio.not_ready");
        apiReply = () => jsonRes(502, { status: "error", error: { code: "error.studio.storage" } });
        expect((await call("POST", `/api/library/studio/${SID}/publish`)).status).toBe(502);
    });
});

// ---------- upload ----------

describe("PUT /api/library/upload", () => {
    const put = (bytes: Uint8Array, type: string | null, name = "reaction.gif", o: { length?: string | null; origin?: string | null } = {}) => {
        const headers: Record<string, string> = {};
        if (type) headers["content-type"] = type;
        if (o.length !== null) headers["content-length"] = o.length ?? String(bytes.byteLength);
        return call("PUT", `/api/library/upload?name=${encodeURIComponent(name)}`, { raw: bytes as unknown as BodyInit, headers, origin: o.origin });
    };
    const streamOf = (total: number, chunk = 1_000_000) => {
        const buf = new Uint8Array(chunk).fill(1);
        let sent = 0;
        return new ReadableStream<Uint8Array>({
            pull(c) {
                const n = Math.min(chunk, total - sent);
                if (n <= 0) return c.close();
                c.enqueue(n === chunk ? buf : buf.slice(0, n));
                sent += n;
            },
        });
    };

    it("stores the bytes in ORIGINALS uploads/<id>.<ext> as a stream and records a private upload item", async () => {
        const data = bytesOf(2048, 9);
        const r = await put(data, "image/gif", "reaction.gif");
        expect(r.status).toBe(201);
        const b = await json(r);
        expect(b.status).toBe("success");
        const it = b.item;
        expect(it).toMatchObject({ kind: "private", source: "upload", name: "reaction.gif", url: null, content_type: "image/gif", bytes: 2048, session_id: null, link: null });
        expect(it.id).toMatch(/^[0-9A-Za-z]{16}$/);
        expect(Object.keys(it)).not.toContain("r2_key");
        const key = `uploads/${it.id}.gif`;
        expect(originals.puts).toEqual([{ key, valueKind: "stream", contentType: "image/gif" }]); // streamed, not buffered
        expect([...originals.objects.get(key)!.bytes!]).toEqual([...data]);
        expect(media.puts).toEqual([]);
        expect(rowOf(it.id)).toMatchObject({ bucket: "originals", r2_key: key, kind: "private", source: "upload", url: null, created_at: NOW, deleted_at: null });
    });

    it.each(Object.entries(UPLOAD_TYPES))("accepts %s as .%s", async (type, ext) => {
        const r = await put(bytesOf(10), `${type}; charset=binary`, `f.${ext}`);
        expect(r.status).toBe(201);
        const id = (await json(r)).item.id;
        expect(rowOf(id).r2_key).toBe(`uploads/${id}.${ext}`);
        expect(rowOf(id).content_type).toBe(type);
    });

    it.each(["image/svg+xml", "application/pdf", "text/html", "application/octet-stream", "video/webm", "image/avif", "IMAGE/GIF2"])(
        "rejects %s with 415 and stores nothing",
        async (type) => {
            const r = await put(bytesOf(10), type);
            expect(r.status).toBe(415);
            expect(await errorCode(r)).toBe("error.library.unsupported");
            expect(originals.puts).toEqual([]);
            expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 0 });
        },
    );
    it("rejects a missing content type with 415", async () => {
        expect((await put(bytesOf(10), null)).status).toBe(415);
    });
    it("matches the content type case-insensitively", async () => {
        expect((await put(bytesOf(10), "Video/MP4", "a.mp4")).status).toBe(201);
    });

    it("rejects 100_000_001 bytes with 413 and drops the body", async () => {
        let cancelled = false;
        const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
        const r = await call("PUT", "/api/library/upload?name=big.mp4", {
            raw: body, headers: { "content-type": "video/mp4", "content-length": String(MAX_UPLOAD_BYTES + 1) },
        });
        expect(r.status).toBe(413);
        expect(await errorCode(r)).toBe("error.library.too_large");
        expect(originals.puts).toEqual([]);
        expect(cancelled).toBe(true); // refused up front: the body is dropped, not consumed
    });
    it("accepts exactly 100_000_000 bytes (streamed through, never buffered by the Worker)", async () => {
        const r = await call("PUT", "/api/library/upload?name=max.mp4", {
            raw: streamOf(MAX_UPLOAD_BYTES), headers: { "content-type": "video/mp4", "content-length": String(MAX_UPLOAD_BYTES) },
        });
        expect(r.status).toBe(201);
        const it = (await json(r)).item;
        expect(it.bytes).toBe(MAX_UPLOAD_BYTES);
        expect(originals.puts[0]!.valueKind).toBe("stream");
        expect(originals.objects.get(`uploads/${it.id}.mp4`)!.size).toBe(MAX_UPLOAD_BYTES);
    }, 30_000);
    it("requires a content-length (411)", async () => {
        const r = await call("PUT", "/api/library/upload?name=a.gif", { raw: streamOf(10, 10), headers: { "content-type": "image/gif" } });
        expect(r.status).toBe(411);
        expect(await errorCode(r)).toBe("error.library.length_required");
        expect(originals.puts).toEqual([]);
    });
    it.each([["abc"], ["-5"], ["1e6"], ["10.5"]])("rejects content-length %s", async (len) => {
        expect((await put(bytesOf(10), "image/gif", "a.gif", { length: len })).status).toBe(411);
    });
    it("rejects an empty file with 400", async () => {
        const r = await put(new Uint8Array(0), "image/gif", "a.gif", { length: "0" });
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.library.empty");
    });
    it("a body shorter than its content-length is 400 and the object is removed", async () => {
        const r = await put(bytesOf(5), "image/gif", "a.gif", { length: "10" });
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.library.incomplete");
        expect(originals.objects.size).toBe(0);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 0 });
    });
    it("a D1 failure after the put removes the stored object (no orphan)", async () => {
        const failing = createFakeD1();
        const real = failing.prepare.bind(failing);
        (failing as any).prepare = (sql: string) => {
            if (sql.includes("INSERT INTO media_items")) throw new Error("D1_ERROR");
            return real(sql);
        };
        (env as any).DB = failing;
        const r = await put(bytesOf(10), "image/gif");
        expect(r.status).toBe(500);
        expect(originals.objects.size).toBe(0);
    });
    it("an R2 failure is a 500 and writes no row", async () => {
        originals.failPut = true;
        expect((await put(bytesOf(10), "image/gif")).status).toBe(500);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 0 });
    });
    it.each([
        ["../../etc/passwd.gif", "passwd.gif"],
        ["C:\\Users\\me\\clip.gif", "clip.gif"],
        ["  spaced name.gif  ", "spaced name.gif"],
        ["bad\u0000\u0007name.gif", "badname.gif"],
        ["", "upload.gif"],
        ["..", "upload.gif"],
        ["a/", "upload.gif"],
        ["é".repeat(200) + ".gif", "é".repeat(120)],
    ])("cleans the display name %j -> %j", async (given, want) => {
        const r = await put(bytesOf(10), "image/gif", given);
        expect((await json(r)).item.name).toBe(want);
    });
    it("defaults the name when none is given", async () => {
        const r = await call("PUT", "/api/library/upload", { raw: bytesOf(10) as unknown as BodyInit, headers: { "content-type": "image/png", "content-length": "10" } });
        expect((await json(r)).item.name).toBe("upload.png");
    });
});

// ---------- publish (private -> public) ----------

describe("POST /api/library/items/<id>/publish", () => {
    async function seedUpload(bytes = bytesOf(1000, 5), over: Seed = {}) {
        const row = seedItem({ kind: "private", source: "upload", content_type: "video/mp4", name: "clip.mp4", bytes: bytes.byteLength, width: 640, height: 360, duration: 7.5, link: "https://x.com/a", session_id: SID, ...over });
        originals.objects.set(row.r2_key, { bytes, size: bytes.byteLength, contentType: row.content_type ?? undefined });
        return row;
    }

    it("copies ORIGINALS -> MEDIA with a chunk loop (pipeTo throws in the fake) and inserts a public host item", async () => {
        const data = Uint8Array.from({ length: 1000 }, (_, i) => i % 251);
        const src = await seedUpload(data);
        const r = await call("POST", `/api/library/items/${src.id}/publish`);
        expect(r.status).toBe(201);
        const b = await json(r);
        expect(b.status).toBe("success");
        expect(b.item).toMatchObject({ kind: "public", source: "host", name: "clip.mp4", content_type: "video/mp4", bytes: 1000, width: 640, height: 360, duration: 7.5, link: "https://x.com/a", session_id: SID });
        expect(b.item.id).toMatch(/^[0-9A-Za-z]{16}$/);
        expect(b.item.id).not.toBe(src.id);
        expect(b.item.url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[0-9A-Za-z]{10}\.mp4$/);
        const name = b.item.url.slice(MEDIA.length);
        expect(media.puts).toEqual([{ key: name, valueKind: "stream", contentType: "video/mp4" }]);
        expect([...media.objects.get(name)!.bytes!]).toEqual([...data]);
        // the private original is untouched
        expect(originals.objects.has(src.r2_key)).toBe(true);
        expect(rowOf(src.id)).toMatchObject({ kind: "private", deleted_at: null });
        expect(rowOf(b.item.id)).toMatchObject({ bucket: "media", r2_key: name, url: b.item.url, created_at: NOW });
    });

    it("publishes a studio-saved original the same way (any private item)", async () => {
        const src = await seedUpload(bytesOf(100), { source: "saved", r2_key: `originals/${SID}.mp4` });
        expect((await call("POST", `/api/library/items/${src.id}/publish`)).status).toBe(201);
    });
    it("uses the stored extension for the public name", async () => {
        const src = await seedUpload(bytesOf(100), { content_type: "image/heic", name: "IMG_1.HEIC", r2_key: "uploads/zzzzzzzzzzzzzzzz.heic" });
        const b = await json(await call("POST", `/api/library/items/${src.id}/publish`));
        expect(b.item.url).toMatch(/\.heic$/);
        expect(b.item.content_type).toBe("image/heic");
    });
    it("an already-public item is 409", async () => {
        const pub = seedItem({ kind: "public" });
        const r = await call("POST", `/api/library/items/${pub.id}/publish`);
        expect(r.status).toBe(409);
        expect(await errorCode(r)).toBe("error.library.already_public");
        expect(media.puts).toEqual([]);
    });
    it("unknown and deleted items are 404", async () => {
        expect((await call("POST", "/api/library/items/aaaaaaaaaaaaaaaa/publish")).status).toBe(404);
        const src = await seedUpload(bytesOf(10), { deleted_at: NOW - 1 });
        expect((await call("POST", `/api/library/items/${src.id}/publish`)).status).toBe(404);
    });
    it("a missing stored object is 404 error.library.missing and nothing is written", async () => {
        const src = seedItem({ kind: "private" });
        const r = await call("POST", `/api/library/items/${src.id}/publish`);
        expect(r.status).toBe(404);
        expect(await errorCode(r)).toBe("error.library.missing");
        expect(media.puts).toEqual([]);
    });
    it("an R2 write failure is 502, leaves no public row and no object", async () => {
        const src = await seedUpload();
        media.failPut = true;
        const r = await call("POST", `/api/library/items/${src.id}/publish`);
        expect(r.status).toBe(502);
        expect(await errorCode(r)).toBe("error.library.storage");
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items WHERE kind = 'public'").get()).toEqual({ n: 0 });
        expect(media.objects.size).toBe(0);
    });
    it("a D1 failure after the copy removes the public object", async () => {
        const src = await seedUpload();
        const failing = (env as any).DB as FakeD1;
        const real = failing.prepare.bind(failing);
        (failing as any).prepare = (sql: string) => {
            if (sql.includes("INSERT INTO media_items")) throw new Error("D1_ERROR");
            return real(sql);
        };
        const r = await call("POST", `/api/library/items/${src.id}/publish`);
        expect(r.status).toBe(500);
        expect(media.objects.size).toBe(0);
    });
});

// ---------- adopt into studio ----------

describe("POST /api/library/items/<id>/studio", () => {
    it("calls /library/adopt with the stored object and answers {studio, url}", async () => {
        const src = seedItem({ kind: "private", source: "upload", content_type: "video/quicktime", name: "screen.mov", bytes: 4242 });
        apiReply = () => jsonRes(201, { status: "success", id: SID, url: `${WEB_ORIGIN}/studio/${SID}` });
        const r = await call("POST", `/api/library/items/${src.id}/studio`);
        expect(r.status).toBe(201);
        expect(await json(r)).toEqual({ status: "success", studio: SID, url: `${WEB_ORIGIN}/studio/${SID}` });
        expect(apiCalls[0]).toMatchObject({
            method: "POST", url: `${API_BASE}/library/adopt`,
            body: { r2_key: src.r2_key, name: "screen.mov", content_type: "video/quicktime", bytes: 4242, item_id: src.id },
        });
        expect(apiCalls[0]!.headers["x-cobalt-service"]).toBe(SERVICE_KEY);
    });
    it.each(["image/gif", "video/mp4", "video/quicktime"])("allows %s", async (type) => {
        const src = seedItem({ kind: "private", content_type: type });
        apiReply = () => jsonRes(201, { status: "success", id: SID, url: "u" });
        expect((await call("POST", `/api/library/items/${src.id}/studio`)).status).toBe(201);
    });
    it.each(["image/png", "image/jpeg", "image/webp", "image/heic", null])("rejects %s with 400 not_video without calling the API", async (type) => {
        const src = seedItem({ kind: "private", content_type: type });
        const r = await call("POST", `/api/library/items/${src.id}/studio`);
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.studio.not_video");
        expect(apiCalls).toEqual([]);
    });
    it("a public item, an unknown item and a deleted item are refused", async () => {
        const pub = seedItem({ kind: "public", content_type: "video/mp4" });
        expect((await call("POST", `/api/library/items/${pub.id}/studio`)).status).toBe(409);
        expect((await call("POST", "/api/library/items/aaaaaaaaaaaaaaaa/studio")).status).toBe(404);
        const gone = seedItem({ kind: "private", deleted_at: NOW });
        expect((await call("POST", `/api/library/items/${gone.id}/studio`)).status).toBe(404);
        expect(apiCalls).toEqual([]);
    });
    it("passes the API's refusal through", async () => {
        const src = seedItem({ kind: "private", content_type: "video/mp4" });
        apiReply = () => jsonRes(400, { status: "error", error: { code: "error.studio.not_video" } });
        const r = await call("POST", `/api/library/items/${src.id}/studio`);
        expect(r.status).toBe(400);
        expect(await errorCode(r)).toBe("error.studio.not_video");
    });
});

// ---------- delete ----------

describe("DELETE /api/library/items/<id>", () => {
    it("a public item: removes the MEDIA object, soft-deletes the row, drops out of list and usage", async () => {
        const pub = seedItem({ kind: "public", bytes: 500 });
        media.objects.set(pub.r2_key, { bytes: bytesOf(5), size: 5 });
        const r = await call("DELETE", `/api/library/items/${pub.id}`);
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ status: "success" });
        expect(media.deletes).toEqual([pub.r2_key]);
        expect(originals.deletes).toEqual([]);
        expect(media.objects.has(pub.r2_key)).toBe(false);
        expect(rowOf(pub.id).deleted_at).toBe(NOW);
        const list = await json(await call("GET", "/api/library"));
        expect(list.items).toEqual([]);
        expect(list.usage.public_bytes).toBe(0);
    });

    it("a private original: removes the ORIGINALS object and expires exactly the studios that read it", async () => {
        const sidA = "Aa1aaaaaaaaaaaaaaaaaaa", sidB = "Bb2bbbbbbbbbbbbbbbbbbb", sidC = "Cc3cccccccccccccccccc", sidD = "Dd4dddddddddddddddddd";
        const key = "uploads/up0000000000000a.mp4";
        const up = seedItem({ kind: "private", source: "upload", r2_key: key, bytes: 800 });
        originals.objects.set(key, { bytes: bytesOf(8), size: 8 });
        seedStudio({ id: sidA, r2_key: key }); // adopted from this upload
        seedStudio({ id: sidB, r2_key: key }); // a second adoption
        seedStudio({ id: sidC, r2_key: "originals/other.mp4" }); // someone else's original
        const longAgo = NOW - 1000;
        seedStudio({ id: sidD, r2_key: key, created_at: NOW - 9e8, expires_at: longAgo }); // already expired: left alone
        const r = await call("DELETE", `/api/library/items/${up.id}`);
        expect(r.status).toBe(200);
        expect(originals.deletes).toEqual([key]);
        expect(rowOf(up.id).deleted_at).toBe(NOW);
        expect(sessionOf(sidA).expires_at).toBe(NOW);
        expect(sessionOf(sidB).expires_at).toBe(NOW);
        expect(sessionOf(sidC).expires_at).toBeGreaterThan(NOW);
        expect(sessionOf(sidD).expires_at).toBe(longAgo);
        // expired studios vanish from the list; the unrelated one stays
        const list = await json(await call("GET", "/api/library"));
        expect(list.studios.map((s: any) => s.id)).toEqual([sidC]);
    });

    it("a studio-saved original ('saved') expires its studio the same way", async () => {
        const sid = seedStudio({ id: SID }); // r2_key originals/<sid>.mp4
        const saved = seedItem({ kind: "private", source: "saved", r2_key: `originals/${sid}.mp4`, session_id: sid });
        await call("DELETE", `/api/library/items/${saved.id}`);
        expect(sessionOf(sid).expires_at).toBe(NOW);
    });

    it("deleting a public webp does not touch studios", async () => {
        seedStudio({ id: SID });
        const before = sessionOf(SID).expires_at;
        const pub = seedItem({ kind: "public", session_id: SID });
        await call("DELETE", `/api/library/items/${pub.id}`);
        expect(sessionOf(SID).expires_at).toBe(before);
    });

    it("unknown, already-deleted and malformed ids are 404", async () => {
        expect((await call("DELETE", "/api/library/items/aaaaaaaaaaaaaaaa")).status).toBe(404);
        const pub = seedItem({ kind: "public" });
        expect((await call("DELETE", `/api/library/items/${pub.id}`)).status).toBe(200);
        const again = await call("DELETE", `/api/library/items/${pub.id}`);
        expect(again.status).toBe(404);
        expect(await errorCode(again)).toBe("error.library.not_found");
    });
    it("a missing R2 object still deletes the row (deleting a missing object succeeds)", async () => {
        const pub = seedItem({ kind: "public" });
        expect((await call("DELETE", `/api/library/items/${pub.id}`)).status).toBe(200);
    });
    it("an R2 failure is a 502 and the row is NOT marked deleted", async () => {
        const pub = seedItem({ kind: "public" });
        media.failDelete = true;
        const r = await call("DELETE", `/api/library/items/${pub.id}`);
        expect(r.status).toBe(502);
        expect(rowOf(pub.id).deleted_at).toBeNull();
    });
});

describe("DELETE /api/library/studios/<sid>", () => {
    it("expires the studio now; it leaves the list; its webps and original stay", async () => {
        seedStudio({ id: SID });
        const webp = seedItem({ kind: "public", source: "studio", session_id: SID });
        const saved = seedItem({ kind: "private", source: "saved", session_id: SID, r2_key: `originals/${SID}.mp4` });
        const r = await call("DELETE", `/api/library/studios/${SID}`);
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ status: "success" });
        expect(sessionOf(SID).expires_at).toBe(NOW);
        const list = await json(await call("GET", "/api/library"));
        expect(list.studios).toEqual([]);
        expect(list.items.map((i: any) => i.id).sort()).toEqual([webp.id, saved.id].sort());
        expect(media.deletes).toEqual([]);
        expect(originals.deletes).toEqual([]);
    });
    it("unknown and already-expired studios are 404", async () => {
        expect((await call("DELETE", `/api/library/studios/${SID}`)).status).toBe(404);
        seedStudio({ id: SID2, expires_at: NOW - 1 });
        expect((await call("DELETE", `/api/library/studios/${SID2}`)).status).toBe(404);
        expect(sessionOf(SID2).expires_at).toBe(NOW - 1);
    });
    it("a D1 outage is a 500", async () => {
        db.breakIt();
        expect((await call("DELETE", `/api/library/studios/${SID}`)).status).toBe(500);
    });
});
