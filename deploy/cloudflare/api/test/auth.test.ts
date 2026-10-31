// Accounts (APP-API-CONTRACT.md section 42): POST /auth/exchange and the /auth/* routes, through the real Worker entry
// (handleRequest) and the real SQL on node:sqlite with every migration applied.
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey, SESSION_TTL_MS } from "../src/keys";
import { challengeOf } from "../src/registry/ops/auth";
import { MAX_SESSIONS, cleanDevice, mintSession, SESSION_CAP_SQL, SESSION_INSERT_SQL } from "../src/sessions";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-1";
const T0 = 1_800_000_000_000;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const CODE = "c".repeat(16) + "ODE_abc-0123456789ABCDEFGHI"; // 43 base64url characters
const VERIFIER = "v".repeat(11) + "erifier_0123456789-abcdefghijklm"; // 43
const OWNER = "maskeowl@icloud.com";

let db: FakeD1;
let clock: number;
let env: WorkerEnv;

beforeEach(async () => {
    db = createFakeD1();
    clock = T0;
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(KEY_ID, "shortcut", await hashKey(KEY), KEY.slice(0, 8), 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    } as WorkerEnv;
});

const container = {
    async fetch(): Promise<Response> {
        throw new Error("the auth routes never reach the container");
    },
};

type Opts = { token?: string | null; origin?: string; body?: unknown; country?: string };
async function call(method: string, path: string, o: Opts = {}): Promise<Response> {
    const headers: Record<string, string> = {};
    const token = o.token === undefined ? KEY : o.token;
    if (token) headers.authorization = `Api-Key ${token}`;
    if (o.origin) headers.origin = o.origin;
    if (o.body !== undefined) headers["content-type"] = "application/json";
    const req = new Request(`${API}${path}`, { method, headers, body: o.body === undefined ? undefined : typeof o.body === "string" ? o.body : JSON.stringify(o.body) });
    if (o.country) Object.defineProperty(req, "cf", { value: { country: o.country } });
    return handleRequest(req, env, container, { now: () => clock, sleep: async () => {} });
}
const json = async (r: Response) => (await r.json()) as any;

async function seedHandoff(o: { code?: string; verifier?: string; device?: string; platform?: string; created?: number; used?: number | null } = {}) {
    const created = o.created ?? clock;
    db.raw
        .prepare("INSERT INTO auth_handoffs (code_hash, challenge, device, platform, email, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        .run(await hashKey(o.code ?? CODE), await challengeOf(o.verifier ?? VERIFIER), o.device ?? "harmony's iphone", o.platform ?? "ios", OWNER, created, created + 120_000, o.used ?? null);
}
const exchange = (body: unknown, o: Opts = {}) => call("POST", "/auth/exchange", { token: null, body, ...o });
// A signed-in session (through the real exchange); returns its token and id.
async function signIn(device = "harmony's iphone", platform = "ios"): Promise<{ key: string; id: string }> {
    const code = (await hashKey(device + clock)).slice(0, 43).replace(/[^A-Za-z0-9_-]/g, "a");
    await seedHandoff({ code, device, platform });
    const r = await exchange({ code, verifier: VERIFIER });
    expect(r.status).toBe(200);
    const b = await json(r);
    return { key: b.key, id: b.session.id };
}
const row = (id: string) => db.raw.prepare("SELECT * FROM api_keys WHERE id = ?").get(id) as Record<string, any>;

const INVALID = { status: "error", error: { code: "error.api.auth.code.invalid" } };

describe("PKCE S256", () => {
    it("challengeOf is base64url(SHA-256(verifier)), no padding (checked against node:crypto)", async () => {
        for (const v of [VERIFIER, "dBjftJeZ4CVP-mJ92K9q-r6SmQ8z3-e0UhMcbuqJw0k", "~._-" + "a".repeat(124)]) {
            const want = createHash("sha256").update(v).digest("base64url");
            expect(await challengeOf(v)).toBe(want);
            expect(want).toHaveLength(43);
        }
    });
});

describe("POST /auth/exchange (42.3)", () => {
    it("trades a good code for a session: a UUIDv4 token, the session shape, only the hash stored", async () => {
        await seedHandoff();
        const r = await exchange({ code: CODE, verifier: VERIFIER }, { country: "NZ" });
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const b = await json(r);
        expect(Object.keys(b).sort()).toEqual(["key", "session", "status"]);
        expect(b.status).toBe("success");
        expect(b.key).toMatch(UUID_V4);
        expect(b.session).toEqual({
            id: expect.stringMatching(UUID_V4),
            device: "harmony's iphone",
            platform: "ios",
            created_at: T0,
            last_used_at: T0,
            expires_at: T0 + SESSION_TTL_MS,
            country: "NZ",
            current: true,
        });
        const stored = row(b.session.id);
        expect(stored).toMatchObject({
            kind: "session",
            name: "harmony's iphone",
            device: "harmony's iphone",
            platform: "ios",
            email: OWNER,
            prefix: b.key.slice(0, 8),
            key_hash: await hashKey(b.key),
            expires_at: T0 + SESSION_TTL_MS,
            revoked_at: null,
        });
        expect(JSON.stringify(db.raw.prepare("SELECT * FROM api_keys").all())).not.toContain(b.key);
        // the token works like a client key
        const me = await json(await call("GET", "/auth/me", { token: b.key }));
        expect(me.caller).toEqual({ kind: "session", id: b.session.id, device: "harmony's iphone", platform: "ios", email: OWNER, expires_at: T0 + SESSION_TTL_MS });
    });
    it("never answers CORS, even to the web origin", async () => {
        await seedHandoff();
        const r = await exchange({ code: CODE, verifier: VERIFIER }, { origin: WEB });
        expect(r.status).toBe(200);
        expect(r.headers.get("access-control-allow-origin")).toBeNull();
        const bad = await exchange({ code: CODE, verifier: VERIFIER }, { origin: WEB });
        expect(bad.headers.get("access-control-allow-origin")).toBeNull();
    });
    it("a code works once: the second exchange is the same 400", async () => {
        await seedHandoff();
        expect((await exchange({ code: CODE, verifier: VERIFIER })).status).toBe(200);
        const again = await exchange({ code: CODE, verifier: VERIFIER });
        expect(again.status).toBe(400);
        expect(await json(again)).toEqual(INVALID);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE kind = 'session'").get()).toEqual({ n: 1 });
    });
    it("two racing exchanges of one code mint one session", async () => {
        await seedHandoff();
        const rs = await Promise.all([exchange({ code: CODE, verifier: VERIFIER }), exchange({ code: CODE, verifier: VERIFIER })]);
        expect(rs.map((r) => r.status).sort()).toEqual([200, 400]);
    });
    it("an expired code (2 minutes) is the same 400", async () => {
        await seedHandoff({ created: T0 - 120_000 });
        const r = await exchange({ code: CODE, verifier: VERIFIER });
        expect(r.status).toBe(400);
        expect(await json(r)).toEqual(INVALID);
    });
    it("a wrong verifier, an unknown code and a malformed body all answer the identical 400", async () => {
        await seedHandoff();
        const answers = [
            await exchange({ code: CODE, verifier: "w".repeat(43) }),
            await exchange({ code: "u".repeat(43), verifier: VERIFIER }),
            await exchange({ code: CODE }),
            await exchange({ code: "short", verifier: VERIFIER }),
            await exchange({ code: CODE, verifier: "x".repeat(42) }),
            await exchange("not json"),
            await exchange({ code: 5, verifier: VERIFIER }),
        ];
        for (const r of answers) {
            expect(r.status).toBe(400);
            expect(await r.text()).toBe(JSON.stringify(INVALID));
        }
        // a wrong verifier does not burn the code for the app that holds the right one
        expect((await exchange({ code: CODE, verifier: VERIFIER })).status).toBe(200);
    });
    it("old_key: a valid pasted key gets replaced_by = the new session and keeps working", async () => {
        await seedHandoff();
        const b = await json(await exchange({ code: CODE, verifier: VERIFIER, old_key: KEY }));
        expect(row(KEY_ID).replaced_by).toBe(b.session.id);
        expect((await call("GET", "/auth/me")).status).toBe(200);
        const keys = await json(await call("GET", "/auth/keys"));
        expect(keys.keys[0]).toMatchObject({ id: KEY_ID, old_paste: true });
    });
    it("old_key: an unknown, malformed or session token marks nothing and does not fail the exchange", async () => {
        const s = await signIn("old phone");
        for (const old_key of ["11111111-2222-4333-8444-555555555555", "garbage", s.key, null]) {
            clock += 1;
            const code = (await hashKey(String(old_key) + clock)).slice(0, 43);
            await seedHandoff({ code });
            expect((await exchange({ code, verifier: VERIFIER, old_key })).status).toBe(200);
        }
        expect(row(KEY_ID).replaced_by).toBeNull();
        expect(row(s.id).replaced_by).toBeNull();
    });
    it("never logs the code, the verifier or the token", async () => {
        const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
        try {
            await seedHandoff();
            const b = await json(await exchange({ code: CODE, verifier: VERIFIER }));
            await exchange({ code: CODE, verifier: VERIFIER });
            await call("GET", "/auth/me", { token: b.key });
            const logged = spies.flatMap((s) => s.mock.calls.map((c) => JSON.stringify(c))).join("\n");
            for (const secret of [CODE, VERIFIER, b.key]) expect(logged).not.toContain(secret);
        } finally {
            for (const s of spies) s.mockRestore();
        }
    });
});

describe("expiry through the routes (42.2)", () => {
    it("a session unused for 90 days answers 401 error.api.auth.key.invalid; a used one slides", async () => {
        const s = await signIn();
        clock += SESSION_TTL_MS - 1;
        expect((await call("GET", "/auth/me", { token: s.key })).status).toBe(200);
        expect(row(s.id).expires_at).toBe(clock + SESSION_TTL_MS);
        clock += SESSION_TTL_MS;
        const r = await call("GET", "/auth/me", { token: s.key, origin: WEB });
        expect(r.status).toBe(401);
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.api.auth.key.invalid" } });
    });
    it("records the country of each use", async () => {
        const s = await signIn();
        await call("GET", "/auth/me", { token: s.key, country: "FR" });
        expect(row(s.id).last_country).toBe("FR");
        await call("GET", "/auth/me", { country: "CA" });
        expect(row(KEY_ID).last_country).toBe("CA");
    });
});

describe("GET /auth/me", () => {
    it("a key caller: kind key and its id; counts of active sessions and keys", async () => {
        await signIn("a");
        const b = await signIn("b");
        await call("DELETE", `/auth/sessions/${b.id}`);
        const r = await call("GET", "/auth/me", { origin: WEB });
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(await json(r)).toEqual({ caller: { kind: "key", id: KEY_ID }, sessions: 1, keys: 1 });
    });
});

describe("GET /auth/sessions", () => {
    it("active sessions only, most recently used first, current marks the caller", async () => {
        const a = await signIn("phone", "ios");
        clock += 1000;
        const b = await signIn("mac", "mac");
        clock += 1000;
        const c = await signIn("ipad", "ipados");
        clock += 1000;
        await call("GET", "/auth/me", { token: a.key }); // a is now the most recent
        await call("DELETE", `/auth/sessions/${c.id}`);
        const r = await call("GET", "/auth/sessions", { token: b.key, origin: WEB });
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        const body = await json(r);
        expect(body.sessions.map((s: any) => [s.id, s.current])).toEqual([
            [b.id, true], // the list call itself was b's latest use
            [a.id, false],
        ]);
        expect(Object.keys(body.sessions[0]).sort()).toEqual(["country", "created_at", "current", "device", "expires_at", "id", "last_used_at", "platform"]);
        expect(body.sessions[1]).toMatchObject({ device: "phone", platform: "ios", last_used_at: T0 + 3000 });
        // keys are never sessions; a key caller sees current: false everywhere
        const asKey = await json(await call("GET", "/auth/sessions"));
        expect(asKey.sessions.every((s: any) => s.current === false)).toBe(true);
        expect(asKey.sessions.map((s: any) => s.id)).not.toContain(KEY_ID);
    });
    it("leaves out expired sessions", async () => {
        const old = await signIn("old");
        clock += SESSION_TTL_MS + 1;
        const fresh = await signIn("new");
        expect((await json(await call("GET", "/auth/sessions"))).sessions.map((s: any) => s.id)).toEqual([fresh.id]);
        expect(old.id).not.toBe(fresh.id);
    });
});

describe("DELETE /auth/sessions/<id>", () => {
    it("revokes another device", async () => {
        const a = await signIn("a");
        const b = await signIn("b");
        const r = await call("DELETE", `/auth/sessions/${b.id}`, { token: a.key });
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ status: "success" });
        expect(row(b.id).revoked_at).toBe(clock);
        expect((await call("GET", "/auth/me", { token: b.key })).status).toBe(401);
        expect((await call("GET", "/auth/me", { token: a.key })).status).toBe(200);
    });
    it("revokes your own (sign out)", async () => {
        const a = await signIn();
        expect((await call("DELETE", `/auth/sessions/${a.id}`, { token: a.key })).status).toBe(200);
        expect((await call("GET", "/auth/me", { token: a.key })).status).toBe(401);
    });
    it("unknown, already revoked, malformed, or a key's id: 404 error.api.auth.session.not_found", async () => {
        const a = await signIn();
        await call("DELETE", `/auth/sessions/${a.id}`);
        for (const id of [a.id, "11111111-2222-4333-8444-555555555555", "bad", KEY_ID]) {
            const r = await call("DELETE", `/auth/sessions/${id}`);
            expect(r.status).toBe(404);
            expect(await json(r)).toEqual({ status: "error", error: { code: "error.api.auth.session.not_found" } });
        }
        expect(row(KEY_ID).revoked_at).toBeNull();
    });
});

describe("POST /auth/signout", () => {
    it("a session signs itself out", async () => {
        const a = await signIn();
        const b = await signIn("other");
        const r = await call("POST", "/auth/signout", { token: a.key });
        expect(await json(r)).toEqual({ signed_out: true });
        expect((await call("GET", "/auth/me", { token: a.key })).status).toBe(401);
        expect((await call("GET", "/auth/me", { token: b.key })).status).toBe(200);
    });
    it("a key is never revoked here", async () => {
        const r = await call("POST", "/auth/signout", { origin: WEB });
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        expect(await json(r)).toEqual({ signed_out: false });
        expect(row(KEY_ID).revoked_at).toBeNull();
        expect((await call("GET", "/auth/me")).status).toBe(200);
    });
});

describe("POST /auth/signout-others", () => {
    it("revokes every other active session, keeps the caller and the keys", async () => {
        const a = await signIn("a");
        const b = await signIn("b");
        const c = await signIn("c");
        await call("DELETE", `/auth/sessions/${c.id}`);
        expect(await json(await call("POST", "/auth/signout-others", { token: a.key }))).toEqual({ count: 1 });
        expect((await call("GET", "/auth/me", { token: a.key })).status).toBe(200);
        expect((await call("GET", "/auth/me", { token: b.key })).status).toBe(401);
        expect((await call("GET", "/auth/me")).status).toBe(200);
    });
    it("from a key: every session is another", async () => {
        await signIn("a");
        await signIn("b");
        expect(await json(await call("POST", "/auth/signout-others"))).toEqual({ count: 2 });
        expect((await json(await call("GET", "/auth/sessions"))).sessions).toEqual([]);
    });
});

describe("GET /auth/keys and DELETE /auth/keys/<id>", () => {
    it("lists active kind = 'key' rows newest first, never sessions", async () => {
        await signIn();
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-2", "mac shortcut", "h2", "abcd1234", 5);
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?)").run("key-3", "gone", "h3", "abcd1235", 6, 7);
        const r = await call("GET", "/auth/keys", { origin: WEB });
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(await json(r)).toEqual({
            keys: [
                { id: "key-2", name: "mac shortcut", prefix: "abcd1234", created_at: 5, last_used_at: null, old_paste: false },
                { id: KEY_ID, name: "shortcut", prefix: KEY.slice(0, 8), created_at: 1, last_used_at: T0, old_paste: false },
            ],
        });
    });
    it("revokes a key; refuses a session id with 404 and leaves the session alone", async () => {
        const s = await signIn();
        const id = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a99";
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(id, "spare", "h2", "abcd1234", 5);
        const refused = await call("DELETE", `/auth/keys/${s.id}`);
        expect(refused.status).toBe(404);
        expect(await json(refused)).toEqual({ status: "error", error: { code: "error.api.auth.key.not_found" } });
        expect(row(s.id).revoked_at).toBeNull();
        const r = await call("DELETE", `/auth/keys/${id}`);
        expect(r.status).toBe(200);
        expect(await json(r)).toEqual({ status: "success" });
        expect(row(id).revoked_at).toBe(clock);
        expect((await call("DELETE", `/auth/keys/${id}`)).status).toBe(404);
        expect((await call("DELETE", "/auth/keys/bad")).status).toBe(404);
    });
});

describe("the session cap (42.2)", () => {
    it(`minting session ${MAX_SESSIONS + 1} revokes the least recently used`, async () => {
        const made: { key: string; id: string }[] = [];
        for (let i = 0; i < MAX_SESSIONS; i++) {
            clock += 10;
            made.push(await signIn(`device ${i}`));
        }
        // device 0 is used again, so device 1 is now the least recently used
        clock += 10;
        await call("GET", "/auth/me", { token: made[0]!.key });
        clock += 10;
        const extra = await signIn("one too many");
        const active = (await json(await call("GET", "/auth/sessions"))).sessions.map((s: any) => s.id);
        expect(active).toHaveLength(MAX_SESSIONS);
        expect(active).toContain(extra.id);
        expect(active).toContain(made[0]!.id);
        expect(active).not.toContain(made[1]!.id);
        expect(row(made[1]!.id).revoked_at).toBe(clock);
        expect((await call("GET", "/auth/me", { token: made[1]!.key })).status).toBe(401);
        // keys do not count against it
        expect(row(KEY_ID).revoked_at).toBeNull();
    });
    it("expired sessions do not count", async () => {
        for (let i = 0; i < MAX_SESSIONS; i++) await mintSession(db, { device: `d${i}`, platform: "web", email: OWNER }, clock);
        clock += SESSION_TTL_MS + 1;
        const fresh = await signIn();
        expect((await json(await call("GET", "/auth/sessions"))).sessions.map((s: any) => s.id)).toEqual([fresh.id]);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE revoked_at IS NOT NULL").get()).toEqual({ n: 0 });
    });
});

describe("sessions.ts", () => {
    it("cleanDevice: 1..40 printable characters, trimmed", () => {
        expect(cleanDevice("  harmony’s iphone ")).toBe("harmony’s iphone");
        expect(cleanDevice("x".repeat(40))).toBe("x".repeat(40));
        expect(cleanDevice("x".repeat(41))).toBeNull();
        expect(cleanDevice("   ")).toBeNull();
        expect(cleanDevice("a\nb")).toBeNull();
        expect(cleanDevice("a\u0000b")).toBeNull();
        expect(cleanDevice(5)).toBeNull();
    });
    it("the minting SQL the web Worker duplicates (deploy/cloudflare/web/test/sessions.test.ts pins the same strings)", () => {
        expect(SESSION_INSERT_SQL).toBe(
            "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, last_used_at, kind, device, platform, email, expires_at, last_country) VALUES (?1, ?2, ?3, ?4, ?5, ?5, 'session', ?2, ?6, ?7, ?8, ?9)",
        );
        expect(SESSION_CAP_SQL).toBe(
            "UPDATE api_keys SET revoked_at = ?1 WHERE id IN (SELECT id FROM api_keys WHERE kind = 'session' AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?1) ORDER BY last_used_at DESC, created_at DESC, id DESC LIMIT -1 OFFSET ?2)",
        );
    });
});

afterEach(() => vi.restoreAllMocks());

// End to end across both Workers: the web Worker's real GET /api/auth/app stores the code, the API's real POST
// /auth/exchange trades it, on one database.
describe("end to end: /api/auth/app on the web Worker, then POST /auth/exchange here", () => {
    it("the code from the 302 and the app's verifier give a working session, once", async () => {
        const { handleAuth } = await import("../../web/src/auth");
        const support = await import("../../web/test/support");
        const signer = await support.makeSigner();
        const jwt = await signer.sign(support.goodClaims({ exp: Math.floor(clock / 1000) + 3600, iat: Math.floor(clock / 1000), nbf: Math.floor(clock / 1000) }));
        const webEnv = {
            DB: db,
            ACCESS_TEAM_DOMAIN: support.TEAM,
            ACCESS_AUD: support.AUD,
            OWNER_EMAIL: support.OWNER,
            WEB_ORIGIN: WEB,
        } as unknown as Parameters<typeof handleAuth>[1];
        const verifier = "Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0Z2FycGx5";
        const challenge = createHash("sha256").update(verifier).digest("base64url");
        const res = await handleAuth(
            new Request(`${WEB}/api/auth/app?platform=mac&device=harmony%27s%20mac&challenge=${challenge}`, { headers: { "Cf-Access-Jwt-Assertion": jwt } }),
            webEnv,
            { jwks: support.newCache(support.makeJwksFetch(() => [signer]).fetchFn), now: () => clock },
        );
        expect(res.status).toBe(302);
        const code = new URL(res.headers.get("location")!).searchParams.get("code")!;
        clock += 60_000;
        const r = await exchange({ code, verifier, old_key: KEY });
        expect(r.status).toBe(200);
        const b = await json(r);
        expect(b.session).toMatchObject({ device: "harmony's mac", platform: "mac", current: true });
        expect((await json(await call("GET", "/auth/me", { token: b.key }))).caller).toMatchObject({ kind: "session", email: OWNER, platform: "mac" });
        expect(row(KEY_ID).replaced_by).toBe(b.session.id);
        expect((await exchange({ code, verifier })).status).toBe(400);
    });
});
