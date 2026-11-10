// The per-isolate key cache (src/keys.ts): a key checked in the last minute is answered without D1. Real SQL on
// node:sqlite, round trips counted by src/d1-timing.ts.
import { describe, expect, it } from "vitest";
import { timedDb } from "../src/d1-timing";
import { hashKey, KEY_CACHE_MAX, KEY_CACHE_TTL_MS, KeyCache, lookupKey, SESSION_TTL_MS } from "../src/keys";
import { resolveKeyState } from "../src/app-routes";
import { challengeOf } from "../src/registry/ops/auth";
import { MAX_SESSIONS } from "../src/sessions";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, MIGRATION_SQL, type FakeD1 } from "../../test-support/d1-sqlite";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const SESSION = "5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7";
const T0 = 1_800_000_000_000;

const seed = async (db: FakeD1, o: { id?: string; token?: string; kind?: string; expires_at?: number | null } = {}) =>
    db.raw
        .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at, kind, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
        .run(o.id ?? "k-1", "laptop", await hashKey(o.token ?? KEY), "0b5f2c3e", 1, o.kind ?? "key", o.expires_at ?? null);
const row = (db: FakeD1, id = "k-1") =>
    db.raw.prepare("SELECT last_used_at, expires_at, last_country, revoked_at FROM api_keys WHERE id = ?").get(id) as {
        last_used_at: number | null;
        expires_at: number | null;
        last_country: string | null;
        revoked_at: number | null;
    };
const revoke = (db: FakeD1, id = "k-1") => db.raw.prepare("UPDATE api_keys SET revoked_at = 1 WHERE id = ?").run(id);

describe("KeyCache", () => {
    it("the constants: 60 s, 500 entries", () => {
        expect(KEY_CACHE_TTL_MS).toBe(60_000);
        expect(KEY_CACHE_MAX).toBe(500);
        const c = new KeyCache();
        expect([c.ttlMs, c.max, c.size]).toEqual([60_000, 500, 0]);
    });
    it("an entry counts until its TTL is over, then it is gone", () => {
        const c = new KeyCache();
        c.set("h", "id", T0);
        expect(c.get("h", T0)).toBe("id");
        expect(c.get("h", T0 + KEY_CACHE_TTL_MS - 1)).toBe("id");
        expect(c.get("h", T0 + KEY_CACHE_TTL_MS)).toBeNull();
        expect(c.size).toBe(0);
    });
    it("never counts past the row's own expires_at, and a row already expired is not kept", () => {
        const c = new KeyCache();
        c.set("h", "id", T0, T0 + 5_000);
        expect(c.get("h", T0 + 4_999)).toBe("id");
        expect(c.get("h", T0 + 5_000)).toBeNull();
        c.set("gone", "id", T0, T0);
        expect(c.size).toBe(0);
        // null and undefined mean "no expiry": the TTL alone
        c.set("a", "id", T0, null);
        c.set("b", "id", T0, undefined);
        expect([c.get("a", T0 + 59_999), c.get("b", T0 + 59_999)]).toEqual(["id", "id"]);
    });
    it("holds at most `max` entries and drops the oldest first; setting a key again makes it the newest", () => {
        const c = new KeyCache(60_000, 3);
        c.set("a", "1", T0);
        c.set("b", "2", T0);
        c.set("c", "3", T0);
        c.set("a", "1", T0 + 1); // refreshed: b is now the oldest
        c.set("d", "4", T0 + 2);
        expect(c.size).toBe(3);
        expect(c.get("b", T0 + 3)).toBeNull();
        expect([c.get("a", T0 + 3), c.get("c", T0 + 3), c.get("d", T0 + 3)]).toEqual(["1", "3", "4"]);
        const big = new KeyCache();
        for (let i = 0; i < KEY_CACHE_MAX + 50; i++) big.set(`h${i}`, `id${i}`, T0);
        expect(big.size).toBe(KEY_CACHE_MAX);
        expect(big.get("h49", T0)).toBeNull();
        expect(big.get("h50", T0)).toBe("id50");
    });
    it("dropId forgets every entry of that id; clear forgets all", () => {
        const c = new KeyCache();
        c.set("a", "1", T0);
        c.set("b", "2", T0);
        c.dropId("1");
        expect([c.get("a", T0), c.get("b", T0)]).toEqual([null, "2"]);
        c.dropId("nobody");
        expect(c.size).toBe(1);
        c.clear();
        expect(c.size).toBe(0);
    });
});

describe("lookupKey with a cache", () => {
    it("a hit makes no D1 call at all; the miss before it made one", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, "SG", cache)).toBe("k-1");
        expect(stats.n).toBe(1);
        expect(row(fake)).toMatchObject({ last_used_at: T0, last_country: "SG" });
        for (let i = 1; i <= 5; i++) expect(await lookupKey(db, KEY, T0 + i * 1000, "JP", cache)).toBe("k-1");
        expect(stats.n).toBe(1);
        // the price of the hit: the use and its country are not written again until the next miss
        expect(row(fake)).toMatchObject({ last_used_at: T0, last_country: "SG" });
    });
    it("is keyed by the key's SHA-256 hash, never the key", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const cache = new KeyCache();
        await lookupKey(fake, KEY, T0, null, cache);
        expect(cache.get(await hashKey(KEY), T0)).toBe("k-1");
        expect(cache.get(KEY, T0)).toBeNull();
        expect(JSON.stringify([...(cache as any).entries])).not.toContain(KEY);
    });
    it("after the TTL the next call asks D1 again and stamps the use", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        await lookupKey(db, KEY, T0, null, cache);
        await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS - 1, null, cache);
        expect(stats.n).toBe(1);
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS, null, cache)).toBe("k-1");
        expect(stats.n).toBe(2);
        expect(row(fake).last_used_at).toBe(T0 + KEY_CACHE_TTL_MS);
    });
    it("a revoked key is still answered from the cache until the TTL, then it is refused (the stated trade-off)", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, null, cache)).toBe("k-1");
        revoke(fake);
        expect(await lookupKey(db, KEY, T0 + 30_000, null, cache)).toBe("k-1");
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS - 1, null, cache)).toBe("k-1");
        expect(stats.n).toBe(1);
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS, null, cache)).toBeNull();
        expect(stats.n).toBe(2);
        // and it stays refused: the refusal asked D1, nothing was cached
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS + 1, null, cache)).toBeNull();
        expect(stats.n).toBe(3);
    });
    it("dropId in the isolate that revoked closes the gap at once", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const cache = new KeyCache();
        expect(await lookupKey(fake, KEY, T0, null, cache)).toBe("k-1");
        revoke(fake);
        cache.dropId("k-1");
        expect(await lookupKey(fake, KEY, T0 + 1, null, cache)).toBeNull();
    });
    it("negative results are never cached: unknown, revoked and expired keys ask D1 every time", async () => {
        const fake = createFakeD1();
        await seed(fake, { id: "s-old", token: SESSION, kind: "session", expires_at: T0 - 1 });
        await seed(fake, { id: "k-gone", token: "22222222-2222-4222-8222-222222222222" });
        revoke(fake, "k-gone");
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        for (let i = 0; i < 3; i++) {
            expect(await lookupKey(db, "11111111-1111-4111-8111-111111111111", T0 + i, null, cache)).toBeNull();
            expect(await lookupKey(db, "22222222-2222-4222-8222-222222222222", T0 + i, null, cache)).toBeNull();
            expect(await lookupKey(db, SESSION, T0 + i, null, cache)).toBeNull();
        }
        expect(stats.n).toBe(9);
        expect(cache.size).toBe(0);
        // so a key that did not exist a moment ago works on its first request after it is created
        expect(await lookupKey(db, KEY, T0, null, cache)).toBeNull();
        await seed(fake);
        expect(await lookupKey(db, KEY, T0, null, cache)).toBe("k-1");
    });
    it("a session slides once on the miss (now + 90 days) and is cached for the TTL", async () => {
        const fake = createFakeD1();
        await seed(fake, { id: "s-1", token: SESSION, kind: "session", expires_at: T0 + 10_000 });
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, SESSION, T0, null, cache)).toBe("s-1");
        expect(row(fake, "s-1").expires_at).toBe(T0 + SESSION_TTL_MS);
        // past the expiry it had before the slide, still inside the TTL: a hit
        expect(await lookupKey(db, SESSION, T0 + 20_000, null, cache)).toBe("s-1");
        expect(stats.n).toBe(1);
        expect(row(fake, "s-1").expires_at).toBe(T0 + SESSION_TTL_MS);
    });
    it("a row with an expires_at sooner than the TTL is cached only until then (a key that expires, which the lookup does not slide)", async () => {
        const fake = createFakeD1();
        await seed(fake, { expires_at: T0 + 5_000 });
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, null, cache)).toBe("k-1");
        expect(await lookupKey(db, KEY, T0 + 4_999, null, cache)).toBe("k-1");
        expect(stats.n).toBe(1);
        expect(await lookupKey(db, KEY, T0 + 5_000, null, cache)).toBeNull();
        expect(stats.n).toBe(2);
    });
    it("a database from before migration 0026 (no kind, no expires_at) still checks and caches", async () => {
        const fake = createFakeD1(MIGRATION_SQL);
        fake.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("k-old", "old", await hashKey(KEY), "0b5f2c3e", 1);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, "SG", cache)).toBe("k-old");
        // the statement that failed on the missing column, then the old one
        expect(stats.n).toBe(2);
        expect(await lookupKey(db, KEY, T0 + 1, "SG", cache)).toBe("k-old");
        expect(stats.n).toBe(2);
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS, "SG", cache)).toBe("k-old");
        expect(stats.n).toBe(4);
    });
    it("a D1 failure still throws on a miss, and is not seen at all on a hit", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const cache = new KeyCache();
        expect(await lookupKey(fake, KEY, T0, null, cache)).toBe("k-1");
        fake.breakIt();
        expect(await lookupKey(fake, KEY, T0 + 1, null, cache)).toBe("k-1");
        await expect(lookupKey(fake, KEY, T0 + KEY_CACHE_TTL_MS, null, cache)).rejects.toThrow();
        await expect(lookupKey(fake, "11111111-1111-4111-8111-111111111111", T0 + 1, null, cache)).rejects.toThrow();
    });
    it("fresh: D1 is asked whatever the cache holds, and an accepted key is remembered anew", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, "SG", cache)).toBe("k-1");
        expect(await lookupKey(db, KEY, T0 + 40_000, "JP", cache, true)).toBe("k-1");
        expect(stats.n).toBe(2);
        expect(row(fake)).toMatchObject({ last_used_at: T0 + 40_000, last_country: "JP" });
        // the entry now runs from the fresh check: still a hit a minute after the first one
        expect(await lookupKey(db, KEY, T0 + KEY_CACHE_TTL_MS + 1, null, cache)).toBe("k-1");
        expect(stats.n).toBe(2);
    });
    it("fresh: a key revoked behind the cache is refused at once, and the cache forgets it", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await lookupKey(db, KEY, T0, null, cache)).toBe("k-1");
        revoke(fake);
        expect(await lookupKey(db, KEY, T0 + 1, null, cache)).toBe("k-1");
        expect(await lookupKey(db, KEY, T0 + 2, null, cache, true)).toBeNull();
        expect(cache.size).toBe(0);
        expect(await lookupKey(db, KEY, T0 + 3, null, cache)).toBeNull();
        expect(stats.n).toBe(3);
        // without a cache `fresh` changes nothing
        expect(await lookupKey(db, KEY, T0 + 4, null, undefined, true)).toBeNull();
    });
    it("no cache passed: every call is the statement, as before", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        for (let i = 0; i < 3; i++) expect(await lookupKey(db, KEY, T0 + i, "SG")).toBe("k-1");
        expect(stats.n).toBe(3);
        expect(row(fake).last_used_at).toBe(T0 + 2);
        revoke(fake);
        expect(await lookupKey(db, KEY, T0 + 3)).toBeNull();
    });
});

describe("the Worker with the isolate's cache", () => {
    const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
    const container = { fetch: async () => new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } }) };
    const world = async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        };
        let now = T0;
        const keyCache = new KeyCache();
        const call = (path: string, key = KEY, cached = true) =>
            handleRequest(new Request(`https://api.capybaraharmony.com${path}`, { headers: { authorization: `Api-Key ${key}` } }), env, container, {
                now: () => now,
                ...(cached ? { keyCache } : {}),
            });
        return { fake, stats, call, keyCache, tick: (ms: number) => (now += ms) };
    };
    // GET /webp/<id> is a keyed route the Durable Object answers: the key check is the only D1 statement it makes.
    const ROUTE = "/webp/aB3dE6gH9jK2mN5pQ8sT";

    it("a keyed route: the first request checks the key in D1, the next ones inside the minute do not", async () => {
        const w = await world();
        expect((await w.call(ROUTE)).status).toBe(200);
        expect(w.stats.n).toBe(1);
        w.tick(1_000);
        expect((await w.call(ROUTE)).status).toBe(200);
        w.tick(1_000);
        expect((await w.call(ROUTE)).status).toBe(200);
        expect(w.stats.n).toBe(1);
        w.tick(KEY_CACHE_TTL_MS);
        expect((await w.call(ROUTE)).status).toBe(200);
        expect(w.stats.n).toBe(2);
    });
    it("without the cache (tests, Durable Objects) every request checks the key", async () => {
        const w = await world();
        for (let i = 0; i < 3; i++) expect((await w.call(ROUTE, KEY, false)).status).toBe(200);
        expect(w.stats.n).toBe(3);
    });
    it("a revoked key answers 200 from the cache until the minute is over, then 401; an unknown key is always a 401 from D1", async () => {
        const w = await world();
        expect((await w.call(ROUTE)).status).toBe(200);
        revoke(w.fake);
        w.tick(KEY_CACHE_TTL_MS - 1);
        expect((await w.call(ROUTE)).status).toBe(200);
        w.tick(1);
        const refused = await w.call(ROUTE);
        expect(refused.status).toBe(401);
        expect(await refused.json()).toEqual({ status: "error", error: { code: "error.api.auth.key.invalid" } });
        const before = w.stats.n;
        expect((await w.call(ROUTE, "11111111-1111-4111-8111-111111111111")).status).toBe(401);
        expect((await w.call(ROUTE, "11111111-1111-4111-8111-111111111111")).status).toBe(401);
        expect(w.stats.n).toBe(before + 2);
    });
    it("GET /capabilities checks its key through the same cache: one statement fewer than without it", async () => {
        const w = await world();
        const read = async (cached: boolean) => {
            const before = w.stats.n;
            const body = (await (await w.call("/capabilities", KEY, cached)).json()) as { key: string; key_name: string };
            expect([body.key, body.key_name]).toEqual(["valid", "laptop"]);
            return w.stats.n - before;
        };
        // the first request fills the cache (and whatever else the route remembers per isolate)
        await read(true);
        const without = await read(false);
        const withCache = await read(true);
        expect(without - withCache).toBe(1);
    });
    it("resolveKeyState: with a cache the check is a hit, without one it is the statement", async () => {
        const fake = createFakeD1();
        await seed(fake);
        const { db, stats } = timedDb(fake);
        const cache = new KeyCache();
        expect(await resolveKeyState(db, "key", KEY, T0, cache)).toEqual({ key: "valid", key_name: "laptop" });
        expect(stats.n).toBe(2);
        expect(await resolveKeyState(db, "key", KEY, T0 + 1, cache)).toEqual({ key: "valid", key_name: "laptop" });
        expect(stats.n).toBe(3);
        expect(await resolveKeyState(db, "key", KEY, T0 + 2)).toEqual({ key: "valid", key_name: "laptop" });
        expect(stats.n).toBe(5);
    });
});

// A cached key must not outlive its revocation where this Worker did the revoking, and a revoked session must never
// reach the routes that make keys. Through handleRequest with one KeyCache, as index.ts runs it.
describe("the account routes and the isolate's cache", () => {
    const API = "https://api.capybaraharmony.com";
    const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
    const MAC = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const PHONE = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const MAC_ID = "11111111-1111-4111-8111-111111111111";
    const PHONE_ID = "22222222-2222-4222-8222-222222222222";
    const TOOL_ID = "33333333-3333-4333-8333-333333333333";
    const ROUTE = "/webp/aB3dE6gH9jK2mN5pQ8sT";
    const INVALID = { status: "error", error: { code: "error.api.auth.key.invalid" } };
    const container = { fetch: async () => new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } }) };

    // Two signed-in devices and one key for tools.
    const world = async () => {
        const fake = createFakeD1();
        await seed(fake, { id: MAC_ID, token: MAC, kind: "session", expires_at: T0 + SESSION_TTL_MS });
        await seed(fake, { id: PHONE_ID, token: PHONE, kind: "session", expires_at: T0 + SESSION_TTL_MS });
        await seed(fake, { id: TOOL_ID });
        const { db, stats } = timedDb(fake);
        const env: WorkerEnv = {
            API_URL: `${API}/`,
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        };
        let now = T0;
        const keyCache = new KeyCache();
        const call = (method: string, path: string, key: string | null, body?: unknown) =>
            handleRequest(
                new Request(`${API}${path}`, {
                    method,
                    headers: { ...(key ? { authorization: `Api-Key ${key}` } : {}), ...(body === undefined ? {} : { "content-type": "application/json" }) },
                    body: body === undefined ? undefined : JSON.stringify(body),
                }),
                env,
                container,
                { now: () => now, keyCache },
            );
        // every credential has passed a check and sits in the cache
        for (const key of [MAC, PHONE, KEY]) expect((await call("GET", ROUTE, key)).status).toBe(200);
        expect(keyCache.size).toBe(3);
        return { fake, stats, call, keyCache, tick: (ms: number) => (now += ms), now: () => now };
    };
    const refused = async (r: Response) => {
        expect(r.status).toBe(401);
        expect(await r.json()).toEqual(INVALID);
    };

    it("POST /auth/signout: the session is refused on its very next request", async () => {
        const w = await world();
        w.tick(5_000);
        const out = await w.call("POST", "/auth/signout", PHONE);
        expect([out.status, await out.json()]).toEqual([200, { signed_out: true }]);
        w.tick(1_000);
        await refused(await w.call("GET", ROUTE, PHONE));
        await refused(await w.call("GET", "/auth/sessions", PHONE));
        // the device that stayed is not touched
        expect((await w.call("GET", ROUTE, MAC)).status).toBe(200);
    });
    it("DELETE /auth/sessions/<id>: the device signed out by another is refused at once, and cannot make itself a key", async () => {
        const w = await world();
        w.tick(5_000);
        expect((await w.call("DELETE", `/auth/sessions/${PHONE_ID}`, MAC)).status).toBe(200);
        w.tick(1_000);
        await refused(await w.call("GET", "/auth/me", PHONE));
        await refused(await w.call("POST", "/auth/keys", PHONE, { name: "spare" }));
        await refused(await w.call("GET", ROUTE, PHONE));
        expect(w.fake.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE name = 'spare'").get()).toEqual({ n: 0 });
    });
    it("DELETE /auth/keys/<id>: the revoked key is refused on its very next request", async () => {
        const w = await world();
        w.tick(5_000);
        expect((await w.call("DELETE", `/auth/keys/${TOOL_ID}`, MAC)).status).toBe(200);
        w.tick(1_000);
        await refused(await w.call("GET", ROUTE, KEY));
    });
    it("POST /auth/signout-others: every other device is refused at once, the caller goes on", async () => {
        const w = await world();
        w.tick(5_000);
        const out = await w.call("POST", "/auth/signout-others", MAC);
        expect(await out.json()).toEqual({ count: 1 });
        w.tick(1_000);
        await refused(await w.call("GET", ROUTE, PHONE));
        expect((await w.call("GET", ROUTE, MAC)).status).toBe(200);
        expect((await w.call("GET", ROUTE, KEY)).status).toBe(200);
    });
    it("a sign-in over the session cap: the session it pushed out is refused at once", async () => {
        const w = await world();
        // the cap's worth of sessions used after the phone, which makes the phone and the mac the two least recently used
        const insert = w.fake.raw.prepare(
            "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, last_used_at, kind, expires_at) VALUES (?, 'd', ?, 'p', ?, ?, 'session', ?)",
        );
        for (let i = 0; i < MAX_SESSIONS - 1; i++) insert.run(`filler-${i}`, `hash-${i}`, T0, T0 + 10, T0 + SESSION_TTL_MS);
        w.fake.raw.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?").run(T0 + 5, MAC_ID);
        w.fake.raw.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?").run(T0 + 1, PHONE_ID);
        w.tick(5_000);
        const code = "c".repeat(43);
        const verifier = "v".repeat(43);
        w.fake.raw
            .prepare("INSERT INTO auth_handoffs (code_hash, challenge, device, platform, email, created_at, expires_at, used_at) VALUES (?, ?, 'ipad', 'ipados', 'o@example.com', ?, ?, NULL)")
            .run(await hashKey(code), await challengeOf(verifier), w.now(), w.now() + 120_000);
        const made = await w.call("POST", "/auth/exchange", null, { code, verifier });
        expect(made.status).toBe(200);
        // 49 fillers + mac + phone + the new one = 52: the two least recently used are out
        expect(row(w.fake, PHONE_ID).revoked_at).toBe(w.now());
        w.tick(1_000);
        await refused(await w.call("GET", ROUTE, PHONE));
    });
    it("revoked somewhere else (the web Worker, another isolate): cached here for its last minute, but never on the routes that hand out credentials", async () => {
        const w = await world();
        revoke(w.fake, PHONE_ID);
        w.tick(10_000);
        // the accepted trade-off, on an ordinary route
        expect((await w.call("GET", ROUTE, PHONE)).status).toBe(200);
        // the account routes and the MCP link's settings ask D1
        await refused(await w.call("POST", "/auth/keys", PHONE, { name: "spare" }));
        expect(w.fake.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE name = 'spare'").get()).toEqual({ n: 0 });
        // ... and what D1 said is remembered: the ordinary route refuses it now too
        await refused(await w.call("GET", ROUTE, PHONE));

        revoke(w.fake, TOOL_ID);
        expect((await w.call("GET", ROUTE, KEY)).status).toBe(200);
        await refused(await w.call("POST", "/mcp/settings/rotate", KEY));
        await refused(await w.call("POST", "/mcp/settings", KEY, { mode: "private" }));
        await refused(await w.call("GET", "/mcp/settings", KEY));
        expect(w.fake.raw.prepare("SELECT COUNT(*) AS n FROM mcp_links").get()).toEqual({ n: 0 });
    });
    it("GET /auth/sessions: the caller's own row is stamped by this request, cached or not (first in the list, used now)", async () => {
        const w = await world();
        // both devices checked in D1 at T0 + 30 s (stamped then) and cached from then on
        w.tick(30_000);
        w.keyCache.clear();
        expect((await w.call("GET", ROUTE, PHONE)).status).toBe(200);
        expect((await w.call("GET", ROUTE, MAC)).status).toBe(200);
        w.tick(5_000);
        expect((await w.call("GET", ROUTE, PHONE)).status).toBe(200);
        w.tick(5_000);
        // the mac asks at T0 + 40 s with its key still cached: the list must not show it as last used at T0 + 30 s,
        // behind the phone. (The phone's own use at T0 + 35 s was a cache hit and is not stamped: up to a minute behind.)
        const list = (await (await w.call("GET", "/auth/sessions", MAC)).json()) as { sessions: { id: string; current: boolean; last_used_at: number; expires_at: number }[] };
        expect(list.sessions.map((s) => [s.id, s.current, s.last_used_at, s.expires_at])).toEqual([
            [MAC_ID, true, T0 + 40_000, T0 + 40_000 + SESSION_TTL_MS],
            [PHONE_ID, false, T0 + 30_000, T0 + 30_000 + SESSION_TTL_MS],
        ]);
    });
    it("an account read costs the key check even for a cached key; a write empties the cache, a read does not", async () => {
        const w = await world();
        const before = w.stats.n;
        expect((await w.call("GET", "/auth/keys", MAC)).status).toBe(200);
        // the key check and the list
        expect(w.stats.n - before).toBe(2);
        expect(w.keyCache.size).toBe(3);
        expect((await w.call("PATCH", `/auth/keys/${TOOL_ID}`, MAC, { name: "renamed" })).status).toBe(200);
        // every entry, the caller's too
        expect(w.keyCache.size).toBe(0);
        expect((await w.call("GET", ROUTE, KEY)).status).toBe(200);
        expect(w.keyCache.size).toBe(1);
    });
});

