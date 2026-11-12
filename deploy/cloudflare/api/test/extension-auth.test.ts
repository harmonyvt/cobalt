// Browser extension sign-in (APP-API-CONTRACT.md section 55): POST /auth/extension/begin and /poll, and the
// Chrome redirect traded at the existing POST /auth/exchange. Real Worker entry, real SQL, every migration.
import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey, SESSION_TTL_MS } from "../src/keys";
import { PAIRING_TTL_MS } from "../src/registry/ops/auth";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const T0 = 1_800_000_000_000;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const VERIFIER = "dBjftJeZ4CVP-mJ92K9q-r6SmQ8z3-e0UhMcbuqJw0k";
const CHALLENGE = createHash("sha256").update(VERIFIER).digest("base64url");
const STATE = "state-0123456789abcdef";
const EXT_ID = "abcdefghijklmnopabcdefghijklmnop";
const REDIRECT = `https://${EXT_ID}.chromiumapp.org/`;
const CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const INVALID = { status: "error", error: { code: "error.api.auth.code.invalid" } };

let db: FakeD1;
let clock: number;
let env: WorkerEnv;

beforeEach(() => {
    db = createFakeD1();
    clock = T0;
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

const container = { async fetch(): Promise<Response> { throw new Error("extension auth never reaches the container"); } };
const call = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
    const h: Record<string, string> = { ...headers };
    if (body !== undefined) h["content-type"] = "application/json";
    const req = new Request(`${API}${path}`, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
    return handleRequest(req, env, container, { now: () => clock, sleep: async () => {} });
};
const json = async (r: Response) => (await r.json()) as any;
const pairings = () => db.raw.prepare("SELECT * FROM extension_pairings").all() as Record<string, any>[];

async function begin() {
    const r = await call("POST", "/auth/extension/begin", { challenge: CHALLENGE, state: STATE });
    expect(r.status).toBe(201);
    return json(r);
}

describe("POST /auth/extension/begin", () => {
    it("returns two fresh codes and stores only their hashes", async () => {
        const b = await begin();
        expect(b).toMatchObject({ status: "pending", interval: 2, expires_at: T0 + PAIRING_TTL_MS });
        expect(b.device_code).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(b.user_code).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(b.device_code).not.toBe(b.user_code);
        const row = pairings()[0]!;
        expect(row.device_hash).toBe(createHash("sha256").update(b.device_code).digest("hex"));
        expect(row.user_hash).toBe(createHash("sha256").update(b.user_code).digest("hex"));
        expect(row.challenge).toBe(CHALLENGE);
        expect(row.state).toBe(STATE);
        expect(row.email).toBeNull();
        expect(row.approved_at).toBeNull();
        expect(JSON.stringify(row)).not.toContain(b.device_code);
        expect(JSON.stringify(row)).not.toContain(b.user_code);
        const again = await begin();
        expect(again.device_code).not.toBe(b.device_code);
    });
    it("a bad body is 400 and stores nothing; there is no CORS header", async () => {
        for (const body of [{}, { challenge: "short", state: STATE }, { challenge: CHALLENGE, state: "short" }, { challenge: CHALLENGE, state: STATE, extra: true }]) {
            const r = await call("POST", "/auth/extension/begin", body, { origin: "https://evil.example" });
            // extra is stripped by the schema, so the last one succeeds; the others are 400
            if ("extra" in body) expect(r.status).toBe(201);
            else expect(await json(r)).toEqual(INVALID);
        }
        expect(pairings()).toHaveLength(1);
        const refused = await call("POST", "/auth/extension/begin", { challenge: "nope", state: STATE }, { origin: WEB });
        expect(refused.headers.get("access-control-allow-origin")).toBeNull();
        expect(refused.headers.get("cache-control")).toBe("no-store");
    });
});

describe("POST /auth/extension/poll", () => {
    it("stays pending until the approve page says so, then mints one session", async () => {
        const started = await begin();
        const pending = await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: VERIFIER, state: STATE });
        expect(pending.status).toBe(202);
        expect(await json(pending)).toEqual({ status: "pending", interval: 2 });
        expect(pairings()[0]!.used_at).toBeNull();

        const wrong = await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: "x".repeat(43), state: STATE });
        expect(await json(wrong)).toEqual(INVALID);
        expect(pairings()[0]!.used_at).toBeNull();

        const { handleConnect } = await import("../../web/src/connect");
        const support = await import("../../web/test/support");
        const signer = await support.makeSigner();
        const jwt = await signer.sign(support.goodClaims({ exp: Math.floor(clock / 1000) + 3600, iat: Math.floor(clock / 1000), nbf: Math.floor(clock / 1000) }));
        const webEnv = { DB: db, ACCESS_TEAM_DOMAIN: support.TEAM, ACCESS_AUD: support.AUD, OWNER_EMAIL: support.OWNER, WEB_ORIGIN: WEB } as never;
        const headers = { "Cf-Access-Jwt-Assertion": jwt, Origin: WEB, "User-Agent": CHROME_MAC, "content-type": "application/x-www-form-urlencoded" };
        const approved = await handleConnect(
            new Request(`${WEB}/connect/extension`, { method: "POST", headers, body: `user_code=${started.user_code}` }),
            webEnv,
            { jwks: support.newCache(support.makeJwksFetch(() => [signer]).fetchFn), now: () => clock },
        );
        expect(approved.status).toBe(200);

        const badState = await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: VERIFIER, state: `${STATE}no` });
        expect(await json(badState)).toEqual(INVALID);

        clock += 1000;
        const done = await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: VERIFIER, state: STATE }, { "cf-nothing": "1" });
        expect(done.status).toBe(200);
        const b = await json(done);
        expect(b.key).toMatch(UUID_V4);
        expect(b.session).toMatchObject({
            device: "Browser extension – Chrome on Mac",
            platform: "extension",
            current: true,
            expires_at: clock + SESSION_TTL_MS,
        });
        expect(pairings()[0]!.used_at).toBe(clock);
        expect(JSON.stringify(pairings()[0])).not.toContain(b.key);

        const me = await call("GET", "/auth/me", undefined, { authorization: `Api-Key ${b.key}` });
        expect((await json(me)).caller).toMatchObject({ kind: "session", platform: "extension", email: support.OWNER, device: "Browser extension – Chrome on Mac" });
        const listed = await call("GET", "/auth/sessions", undefined, { authorization: `Api-Key ${b.key}` });
        expect((await json(listed)).sessions.map((s: { device: string }) => s.device)).toContain("Browser extension – Chrome on Mac");

        expect((await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: VERIFIER, state: STATE })).status).toBe(400);
        const out = await call("POST", "/auth/signout", {}, { authorization: `Api-Key ${b.key}` });
        expect(await json(out)).toEqual({ signed_out: true });
        expect((await call("GET", "/auth/me", undefined, { authorization: `Api-Key ${b.key}` })).status).toBe(401);
    });

    it("an unknown or expired pairing is the same 400", async () => {
        const started = await begin();
        clock += PAIRING_TTL_MS + 1;
        expect(await json(await call("POST", "/auth/extension/poll", { device_code: started.device_code, verifier: VERIFIER, state: STATE }))).toEqual(INVALID);
        expect(await json(await call("POST", "/auth/extension/poll", { device_code: "z".repeat(43), verifier: VERIFIER, state: STATE }))).toEqual(INVALID);
    });
});

describe("Chrome redirect, then POST /auth/exchange", () => {
    it("the approve page's code becomes an extension session", async () => {
        const { handleConnect } = await import("../../web/src/connect");
        const support = await import("../../web/test/support");
        const signer = await support.makeSigner();
        const jwt = await signer.sign(support.goodClaims({ exp: Math.floor(clock / 1000) + 3600, iat: Math.floor(clock / 1000), nbf: Math.floor(clock / 1000) }));
        const webEnv = { DB: db, ACCESS_TEAM_DOMAIN: support.TEAM, ACCESS_AUD: support.AUD, OWNER_EMAIL: support.OWNER, WEB_ORIGIN: WEB } as never;
        const deps = { jwks: support.newCache(support.makeJwksFetch(() => [signer]).fetchFn), now: () => clock };
        const res = await handleConnect(
            new Request(`${WEB}/connect/extension`, {
                method: "POST",
                headers: { "Cf-Access-Jwt-Assertion": jwt, Origin: WEB, "User-Agent": CHROME_MAC, "content-type": "application/x-www-form-urlencoded" },
                body: `challenge=${CHALLENGE}&state=${STATE}&redirect_uri=${encodeURIComponent(REDIRECT)}`,
                redirect: "manual",
            }),
            webEnv,
            deps,
        );
        expect(res.status).toBe(302);
        const loc = new URL(res.headers.get("location")!);
        expect(`${loc.origin}${loc.pathname}`).toBe(REDIRECT);
        const traded = await call("POST", "/auth/exchange", { code: loc.searchParams.get("code"), verifier: VERIFIER });
        expect(traded.status).toBe(200);
        const b = await json(traded);
        expect(b.session).toMatchObject({ platform: "extension", device: "Browser extension – Chrome on Mac" });
        expect((await call("POST", "/auth/exchange", { code: loc.searchParams.get("code"), verifier: VERIFIER })).status).toBe(400);
    });
});
