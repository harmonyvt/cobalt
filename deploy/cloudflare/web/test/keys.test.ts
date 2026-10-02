import { createHash } from "node:crypto";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { MAX_KEYS, hashKey, handleKeys, type Env } from "../src/keys";
import worker from "../src/index";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import {
    AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer,
} from "./support";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_SHA256 = "fdf22b6208069ca909f67671aa94460362cf0f181093d0ad9f31e12e08fad7d9";
// Independent of the code under test (node:crypto, not WebCrypto).
const KEY_HASH = (key: string) => createHash("sha256").update(key).digest("hex");
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let db: FakeD1;
let clock: number;
let assetCalls: string[];
let env: Env;
beforeEach(() => {
    db = createFakeD1();
    clock = NOW;
    assetCalls = [];
    env = {
        DB: db,
        ASSETS: { fetch: async (r: Request) => (assetCalls.push(new URL(r.url).pathname), new Response("asset")) } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        MEDIA: {} as R2Bucket,
        ORIGINALS: {} as R2Bucket,
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        API: {} as Fetcher,
        COBALT_API_KEY: "00000000-0000-4000-8000-000000000000",
    };
});

const deps = () => ({ jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => clock });

type Opts = { token?: string | null; origin?: string | null; body?: unknown; contentType?: string | null; raw?: string };
const call = (method: string, path: string, o: Opts = {}) => {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && (method !== "GET" || o.origin)) headers.set("Origin", o.origin ?? WEB_ORIGIN);
    let body: string | undefined;
    if (method === "GET") body = undefined;
    else if (o.raw !== undefined) body = o.raw;
    else if (o.body !== undefined) body = JSON.stringify(o.body);
    if ((body !== undefined || o.contentType !== undefined) && o.contentType !== null) headers.set("content-type", o.contentType ?? "application/json");
    return handleKeys(new Request(`https://cobalt.capybaraharmony.com${path}`, { method, headers, body }), env, deps());
};
const create = (name: unknown = "iOS Shortcut", o: Opts = {}) =>
    call("POST", "/api/keys", { body: { name }, ...o });
const json = async (r: Response) => JSON.parse(await r.text());

describe("hashKey", () => {
    it("matches the vector pinned in the API Worker tests", async () => {
        expect(await hashKey(KEY)).toBe(KEY_SHA256);
    });
});

describe("authentication", () => {
    it.each(["GET", "POST", "DELETE"])("%s without a JWT is 401 unauthorized and never touches D1", async (method) => {
        db.breakIt(); // would 500 if reached
        const r = await call(method, method === "DELETE" ? `/api/keys/${crypto.randomUUID()}` : "/api/keys", { token: null, body: { name: "x" } });
        expect(r.status).toBe(401);
        expect(await json(r)).toEqual({ error: "unauthorized" });
    });
    it("a JWT for another email is 401", async () => {
        const bad = await signer.sign(goodClaims({ email: "someone@else.com" }));
        expect((await call("GET", "/api/keys", { token: bad })).status).toBe(401);
    });
    it("auth is checked before Origin (a bad-origin unauthenticated POST is 401, not 403)", async () => {
        const r = await create("x", { token: null, origin: "https://evil.example" });
        expect(r.status).toBe(401);
    });
});

describe("headers", () => {
    it("every response is JSON with no-store and no CORS", async () => {
        for (const r of [
            await call("GET", "/api/keys"),
            await create("a"),
            await call("GET", "/api/keys", { token: null }),
            await create("a", { origin: "https://evil.example" }),
            await create(""),
        ]) {
            expect(r.headers.get("cache-control")).toBe("no-store");
            expect(r.headers.get("content-type")).toBe("application/json");
            expect([...r.headers.keys()].filter((h) => h.startsWith("access-control-"))).toEqual([]);
        }
        const del = await call("DELETE", `/api/keys/${crypto.randomUUID()}`);
        expect(del.headers.get("cache-control")).toBe("no-store");
    });
});

describe("GET /api/keys", () => {
    it("is empty at first", async () => {
        const r = await call("GET", "/api/keys");
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ keys: [] });
    });
    it("lists non-revoked keys newest first with exactly the contract fields and no secrets", async () => {
        const a = await json(await create("first"));
        clock += 1000;
        const b = await json(await create("second"));
        clock += 1000;
        const c = await json(await create("third"));
        await call("DELETE", `/api/keys/${b.id}`);
        const r = await call("GET", "/api/keys");
        const body = await json(r);
        expect(body.keys.map((k: { name: string }) => k.name)).toEqual(["third", "first"]);
        for (const k of body.keys) {
            expect(Object.keys(k).sort()).toEqual(["created_at", "id", "last_used_at", "name", "prefix"]);
            expect(k.last_used_at).toBeNull();
        }
        expect(body.keys[0]).toMatchObject({ id: c.id, prefix: c.key.slice(0, 8), created_at: NOW + 2000 });
        expect(JSON.stringify(body)).not.toContain(a.key);
    });
    it("reflects last_used_at set by the API Worker", async () => {
        const a = await json(await create("x"));
        db.raw.prepare("UPDATE api_keys SET last_used_at = 424242 WHERE id = ?").run(a.id);
        expect((await json(await call("GET", "/api/keys"))).keys[0].last_used_at).toBe(424242);
    });
    it("needs no Origin", async () => {
        expect((await call("GET", "/api/keys", { origin: null })).status).toBe(200);
    });
});

describe("POST /api/keys", () => {
    it("creates a key: 201, contract shape, plaintext once, only the hash stored", async () => {
        const r = await create("  iOS Shortcut  ");
        expect(r.status).toBe(201);
        const b = await json(r);
        expect(Object.keys(b).sort()).toEqual(["created_at", "id", "key", "last_used_at", "name", "prefix"]);
        expect(b.name).toBe("iOS Shortcut");
        expect(b.key).toMatch(UUID_V4);
        expect(b.id).toMatch(UUID_V4);
        expect(b.id).not.toBe(b.key);
        expect(b.prefix).toBe(b.key.slice(0, 8));
        expect(b.created_at).toBe(NOW);
        expect(b.last_used_at).toBeNull();

        const row = db.raw.prepare("SELECT * FROM api_keys WHERE id = ?").get(b.id)!;
        expect(row.key_hash).toBe(await hashKey(b.key));
        expect(JSON.stringify(row)).not.toContain(b.key);
        // the list never repeats it
        expect(await (await call("GET", "/api/keys")).text()).not.toContain(b.key);
    });
    it("validates name: trimmed 1..40 chars", async () => {
        for (const name of ["", "   ", "\n\t", "x".repeat(41), "  " + "x".repeat(41) + "  ", 5, null, ["a"], {}]) {
            const r = await create(name);
            expect(r.status, "name=" + String(JSON.stringify(name))).toBe(400);
            expect(await json(r)).toEqual({ error: "bad_request" });
        }
        expect((await call("POST", "/api/keys", { body: {} })).status).toBe(400); // no name at all
        expect((await create("x".repeat(40))).status).toBe(201);
        expect((await create("x")).status).toBe(201);
        expect((await create(" " + "y".repeat(40) + " ")).status).toBe(201);
        expect((await create("😀".repeat(40))).status).toBe(201); // counted in characters
        expect((await create("😀".repeat(41))).status).toBe(400);
    });
    it("400 for a missing body, invalid JSON, a non-object body, or an oversized body", async () => {
        expect((await call("POST", "/api/keys", { contentType: "application/json" })).status).toBe(400);
        expect((await call("POST", "/api/keys", { raw: "{nope" })).status).toBe(400);
        expect((await call("POST", "/api/keys", { raw: '"name"' })).status).toBe(400);
        expect((await call("POST", "/api/keys", { raw: "[]" })).status).toBe(400);
        expect((await call("POST", "/api/keys", { body: { name: "ok", pad: "z".repeat(5000) } })).status).toBe(400);
    });
    it("requires content-type application/json", async () => {
        const wrong = await call("POST", "/api/keys", { body: { name: "x" }, contentType: "text/plain" });
        expect(wrong.status).toBe(415);
        expect(await json(wrong)).toEqual({ error: "bad_request" });
        expect((await call("POST", "/api/keys", { body: { name: "x" }, contentType: null })).status).toBe(415);
        expect((await call("POST", "/api/keys", { body: { name: "x" }, contentType: "application/json; charset=utf-8" })).status).toBe(201);
    });
    it("requires Origin to be exactly the web origin", async () => {
        for (const origin of ["https://evil.example", "https://cobalt.capybaraharmony.com.evil.example", "http://cobalt.capybaraharmony.com", WEB_ORIGIN + "/", "null"]) {
            const r = await create("x", { origin });
            expect(r.status, origin).toBe(403);
            expect(await json(r)).toEqual({ error: "forbidden" });
        }
        const none = await create("x", { origin: null });
        expect(none.status).toBe(403);
        expect((await json(await call("GET", "/api/keys"))).keys).toEqual([]); // nothing was created
    });
    it(`caps at ${MAX_KEYS} active keys with 409 too_many_keys; revoking frees a slot`, async () => {
        const ids: string[] = [];
        for (let i = 0; i < MAX_KEYS; i++) ids.push((await json(await create(`k${i}`))).id);
        const over = await create("one too many");
        expect(over.status).toBe(409);
        expect(await json(over)).toEqual({ error: "too_many_keys" });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM api_keys").get()!.n).toBe(MAX_KEYS);

        expect((await call("DELETE", `/api/keys/${ids[0]}`)).status).toBe(204);
        expect((await create("fits again")).status).toBe(201);
        expect((await create("full again")).status).toBe(409);
    });
    it("D1 failure is 500 server_error", async () => {
        db.breakIt();
        const r = await create("x");
        expect(r.status).toBe(500);
        expect(await json(r)).toEqual({ error: "server_error" });
    });
});

describe("DELETE /api/keys/:id", () => {
    it("revokes: 204 with no body, then it is gone from the list", async () => {
        const a = await json(await create("a"));
        const r = await call("DELETE", `/api/keys/${a.id}`);
        expect(r.status).toBe(204);
        expect(await r.text()).toBe("");
        expect((await json(await call("GET", "/api/keys"))).keys).toEqual([]);
        expect(db.raw.prepare("SELECT revoked_at FROM api_keys WHERE id = ?").get(a.id)!.revoked_at).toBe(NOW);
    });
    it("unknown or already revoked id is 404 not_found", async () => {
        const a = await json(await create("a"));
        for (const id of [crypto.randomUUID(), "nope", "..%2Fkeys", a.id]) {
            const first = await call("DELETE", `/api/keys/${id}`);
            if (id === a.id) {
                expect(first.status).toBe(204);
                clock += 5;
                const again = await call("DELETE", `/api/keys/${id}`);
                expect(again.status).toBe(404);
                expect(await json(again)).toEqual({ error: "not_found" });
                // the original revocation time is preserved
                expect(db.raw.prepare("SELECT revoked_at FROM api_keys WHERE id = ?").get(id)!.revoked_at).toBe(NOW);
            } else {
                expect(first.status, id).toBe(404);
                expect(await json(first)).toEqual({ error: "not_found" });
            }
        }
    });
    it("requires the web Origin (403 forbidden) and revokes nothing otherwise", async () => {
        const a = await json(await create("a"));
        for (const origin of ["https://evil.example", null] as const) {
            const r = await call("DELETE", `/api/keys/${a.id}`, { origin });
            expect(r.status).toBe(403);
            expect(await json(r)).toEqual({ error: "forbidden" });
        }
        expect((await json(await call("GET", "/api/keys"))).keys).toHaveLength(1);
    });
    it("a revoked key can no longer pass the API Worker's lookup statement", async () => {
        const a = await json(await create("a"));
        const lookup = () =>
            db
                .prepare("UPDATE api_keys SET last_used_at = ?1 WHERE key_hash = ?2 AND revoked_at IS NULL RETURNING id")
                .bind(NOW, KEY_HASH(a.key))
                .all();
        expect((await lookup()).results).toHaveLength(1);
        await call("DELETE", `/api/keys/${a.id}`);
        expect((await lookup()).results).toHaveLength(0);
    });
});

describe("routing", () => {
    it("wrong methods are 405 and unknown paths 404 (both authenticated)", async () => {
        expect((await call("PUT", "/api/keys")).status).toBe(405);
        expect((await call("DELETE", "/api/keys")).status).toBe(405);
        expect((await call("GET", `/api/keys/${crypto.randomUUID()}`)).status).toBe(405);
        expect((await call("GET", "/api/keys/")).status).toBe(404);
        expect((await call("GET", "/api/keys/a/b")).status).toBe(404);
    });
    it("the entrypoint sends only /api/keys* to the handler and everything else to ASSETS", async () => {
        const anon = (path: string) => worker.fetch(new Request(`https://cobalt.capybaraharmony.com${path}`), env);
        expect((await anon("/api/keys")).status).toBe(401);
        expect((await anon("/api/keys/x")).status).toBe(401);
        expect(assetCalls).toEqual([]);
        for (const p of ["/", "/settings/instances", "/api/keysx", "/api"]) {
            expect(await (await anon(p)).text()).toBe("asset");
        }
        expect(assetCalls).toEqual(["/", "/settings/instances", "/api/keysx", "/api"]);
    });
});
