// /api/auth/app and /api/auth/web (APP-API-CONTRACT.md 42.3, 42.4) against the real SQL on node:sqlite.
import { createHash } from "node:crypto";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { lookupKey } from "../../api/src/keys";
import config from "../cloudflare.config";
import { APP_CALLBACK, HANDOFF_TTL_MS, handleAuth } from "../src/auth";
import worker from "../src/index";
import { hashKey, type Env } from "../src/keys";
import { MAX_SESSIONS, SESSION_TTL_MS } from "../src/sessions";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const VERIFIER = "dBjftJeZ4CVP-mJ92K9q-r6SmQ8z3-e0UhMcbuqJw0k";
const CHALLENGE = createHash("sha256").update(VERIFIER).digest("base64url");
const SAFARI_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15";

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let db: FakeD1;
let clock: number;
let env: Env;
beforeEach(() => {
    db = createFakeD1();
    clock = NOW;
    env = {
        DB: db,
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
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

type Opts = { token?: string | null; origin?: string | null; body?: string; ua?: string; country?: string };
const call = (method: string, path: string, o: Opts = {}) => {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && method !== "GET") headers.set("Origin", o.origin ?? WEB_ORIGIN);
    if (o.body !== undefined) headers.set("content-type", "application/json");
    if (o.ua) headers.set("User-Agent", o.ua);
    const req = new Request(`https://cobalt.capybaraharmony.com${path}`, { method, headers, body: o.body, redirect: "manual" });
    if (o.country) Object.defineProperty(req, "cf", { value: { country: o.country } });
    return handleAuth(req, env, deps());
};
const appUrl = (q: Record<string, string>) => `/api/auth/app?${new URLSearchParams(q)}`;
const goodQuery = { platform: "ios", device: "harmony's iphone", challenge: CHALLENGE };
const handoffs = () => db.raw.prepare("SELECT * FROM auth_handoffs").all() as Record<string, any>[];
const sessions = () => db.raw.prepare("SELECT * FROM api_keys WHERE kind = 'session'").all() as Record<string, any>[];

describe("GET /api/auth/app (42.3)", () => {
    it("without a valid Access JWT: 401 page, D1 untouched", async () => {
        db.breakIt();
        for (const t of [null, await signer.sign(goodClaims({ email: "someone@else.com" }))]) {
            const r = await call("GET", appUrl(goodQuery), { token: t });
            expect(r.status).toBe(401);
            expect(r.headers.get("location")).toBeNull();
            expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
        }
    });
    it("stores a one-time code (hash only, 2 minutes) and answers 302 to the fixed app callback", async () => {
        const r = await call("GET", appUrl(goodQuery));
        expect(r.status).toBe(302);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const loc = r.headers.get("location")!;
        expect(loc.startsWith(`${APP_CALLBACK}?code=`)).toBe(true);
        expect(APP_CALLBACK).toBe("cobalt-apple://signed-in");
        const code = new URL(loc).searchParams.get("code")!;
        expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(loc).toBe(`cobalt-apple://signed-in?code=${code}`);
        expect(handoffs()).toEqual([
            {
                code_hash: createHash("sha256").update(code).digest("hex"),
                challenge: CHALLENGE,
                device: "harmony's iphone",
                platform: "ios",
                email: OWNER,
                created_at: NOW,
                expires_at: NOW + HANDOFF_TTL_MS,
                used_at: null,
            },
        ]);
        expect(HANDOFF_TTL_MS).toBe(120_000);
        expect(JSON.stringify(handoffs())).not.toContain(code);
    });
    it("every code is fresh", async () => {
        const a = (await call("GET", appUrl(goodQuery))).headers.get("location");
        const b = (await call("GET", appUrl(goodQuery))).headers.get("location");
        expect(a).not.toBe(b);
        expect(handoffs()).toHaveLength(2);
    });
    it("the redirect target never comes from the request", async () => {
        const r = await call("GET", appUrl({ ...goodQuery, redirect_uri: "https://evil.example/", callback: "evil://x", scheme: "evil" }));
        expect(r.status).toBe(302);
        expect(r.headers.get("location")!.startsWith("cobalt-apple://signed-in?code=")).toBe(true);
    });
    it("accepts ios, ipados and mac; trims the device name", async () => {
        for (const platform of ["ios", "ipados", "mac"]) expect((await call("GET", appUrl({ ...goodQuery, platform, device: `  ${platform} one ` }))).status).toBe(302);
        expect(handoffs().map((h) => [h.platform, h.device])).toEqual([
            ["ios", "ios one"],
            ["ipados", "ipados one"],
            ["mac", "mac one"],
        ]);
    });
    it("a bad query is a plain 400 page that echoes nothing and stores nothing", async () => {
        const bad: Record<string, string>[] = [
            {},
            { ...goodQuery, platform: "web" },
            { ...goodQuery, platform: "android" },
            { ...goodQuery, platform: "" },
            { ...goodQuery, device: "" },
            { ...goodQuery, device: "   " },
            { ...goodQuery, device: "x".repeat(41) },
            { ...goodQuery, device: "<script>alert(1)</script>\nx" },
            { ...goodQuery, challenge: CHALLENGE.slice(1) },
            { ...goodQuery, challenge: CHALLENGE + "A" },
            { ...goodQuery, challenge: CHALLENGE.slice(1) + "=" },
            { platform: "ios", device: "x" },
        ];
        for (const q of bad) {
            const r = await call("GET", appUrl(q));
            expect(r.status, JSON.stringify(q)).toBe(400);
            expect(r.headers.get("location")).toBeNull();
            expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
            const text = await r.text();
            expect(text).not.toContain("<script>alert");
            expect(text).not.toContain(CHALLENGE);
        }
        expect(handoffs()).toEqual([]);
    });
    it("only GET", async () => {
        const r = await call("POST", appUrl(goodQuery));
        expect(r.status).toBe(405);
        expect(handoffs()).toEqual([]);
    });
    it("drops handoffs that expired more than 2 minutes ago", async () => {
        await call("GET", appUrl(goodQuery));
        clock += 2 * HANDOFF_TTL_MS + 1;
        await call("GET", appUrl(goodQuery));
        expect(handoffs().map((h) => h.created_at)).toEqual([clock]);
    });
    it("a D1 failure is a 500 page, never a redirect", async () => {
        const broken = { ...env, DB: { prepare: () => ({ bind: () => ({ run: async () => { throw new Error("down"); } }) }) } as unknown as D1Database };
        const r = await handleAuth(new Request(`https://cobalt.capybaraharmony.com${appUrl(goodQuery)}`, { headers: { "Cf-Access-Jwt-Assertion": token } }), broken, deps());
        expect(r.status).toBe(500);
        expect(r.headers.get("location")).toBeNull();
    });
});

describe("POST /api/auth/web (42.4)", () => {
    it("without a valid Access JWT: 401, D1 untouched", async () => {
        db.breakIt();
        const r = await call("POST", "/api/auth/web", { token: null });
        expect(r.status).toBe(401);
        expect(await r.json()).toEqual({ error: "unauthorized" });
    });
    it("Origin must be exactly the web origin", async () => {
        for (const origin of ["https://evil.example", null, WEB_ORIGIN + "/"]) {
            const r = await call("POST", "/api/auth/web", { origin });
            expect(r.status).toBe(403);
        }
        expect(sessions()).toEqual([]);
    });
    it("mints a web session: device from the User-Agent, only the hash stored, the token passes the API's lookup", async () => {
        const r = await call("POST", "/api/auth/web", { ua: SAFARI_MAC, country: "SE" });
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect([...r.headers.keys()].filter((h) => h.startsWith("access-control-"))).toEqual([]);
        const b = (await r.json()) as any;
        expect(Object.keys(b).sort()).toEqual(["key", "session"]);
        expect(b.key).toMatch(UUID_V4);
        expect(b.session).toEqual({
            id: expect.stringMatching(UUID_V4),
            device: "safari on mac",
            platform: "web",
            created_at: NOW,
            last_used_at: NOW,
            expires_at: NOW + SESSION_TTL_MS,
            country: "SE",
            current: true,
        });
        const [row] = sessions();
        expect(row).toMatchObject({ id: b.session.id, name: "safari on mac", key_hash: await hashKey(b.key), prefix: b.key.slice(0, 8), email: OWNER, platform: "web" });
        expect(JSON.stringify(sessions())).not.toContain(b.key);
        expect(await lookupKey(db, b.key, NOW + 1)).toBe(b.session.id);
    });
    it("an empty body is fine; a bad body is 400", async () => {
        expect((await call("POST", "/api/auth/web", { body: "" })).status).toBe(200);
        expect((await call("POST", "/api/auth/web", { body: "{}" })).status).toBe(200);
        for (const body of ["{nope", "[]", '"x"', '{"replace":5}', JSON.stringify({ replace: "x".repeat(2000) })]) {
            expect((await call("POST", "/api/auth/web", { body })).status, body).toBe(400);
        }
    });
    it("replace: the browser's old session is revoked", async () => {
        const old = (await (await call("POST", "/api/auth/web")).json()) as any;
        const r = await call("POST", "/api/auth/web", { body: JSON.stringify({ replace: old.key }) });
        expect(r.status).toBe(200);
        const fresh = (await r.json()) as any;
        expect(await lookupKey(db, old.key, NOW + 1)).toBeNull();
        expect(await lookupKey(db, fresh.key, NOW + 1)).toBe(fresh.session.id);
    });
    it("replace never revokes a key", async () => {
        const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "tool", await hashKey(KEY), KEY.slice(0, 8), 1);
        expect((await call("POST", "/api/auth/web", { body: JSON.stringify({ replace: KEY }) })).status).toBe(200);
        expect(await lookupKey(db, KEY, NOW + 1)).toBe("key-1");
    });
    it(`at most ${MAX_SESSIONS} active sessions: the least recently used goes`, async () => {
        const keys: string[] = [];
        for (let i = 0; i < MAX_SESSIONS + 1; i++) {
            clock += 10;
            keys.push(((await (await call("POST", "/api/auth/web")).json()) as any).key);
        }
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE kind = 'session' AND revoked_at IS NULL").get()).toEqual({ n: MAX_SESSIONS });
        expect(await lookupKey(db, keys[0]!, clock)).toBeNull();
        expect(await lookupKey(db, keys[1]!, clock)).not.toBeNull();
    });
    it("only POST", async () => {
        expect((await call("GET", "/api/auth/web")).status).toBe(405);
    });
});

describe("routing", () => {
    it("unknown /api/auth paths are 404 after auth", async () => {
        expect((await call("GET", "/api/auth")).status).toBe(404);
        expect((await call("GET", "/api/auth/other")).status).toBe(404);
        expect((await call("GET", "/api/auth/other", { token: null })).status).toBe(401);
    });
    it("runs the Worker first for /api/auth and /api/auth/*", () => {
        expect((config as any).worker.assets.runWorkerFirst).toEqual(expect.arrayContaining(["/api/auth", "/api/auth/*"]));
    });
    it("the entrypoint sends /api/auth* to the handler and /api/authx to ASSETS", async () => {
        const anon = (path: string) => worker.fetch(new Request(`https://cobalt.capybaraharmony.com${path}`), env);
        expect((await anon("/api/auth/app")).status).toBe(401);
        expect((await anon("/api/auth/web")).status).toBe(401);
        expect(await (await anon("/api/authx")).text()).toBe("asset");
    });
});
