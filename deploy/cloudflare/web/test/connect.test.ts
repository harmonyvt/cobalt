// /connect/extension (APP-API-CONTRACT.md section 55): the approve page. GET shows a form; POST approves.
import { createHash } from "node:crypto";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import config from "../cloudflare.config";
import { chromiumAppRedirect, handleConnect } from "../src/connect";
import worker from "../src/index";
import { hashKey, type Env } from "../src/keys";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const VERIFIER = "dBjftJeZ4CVP-mJ92K9q-r6SmQ8z3-e0UhMcbuqJw0k";
const CHALLENGE = createHash("sha256").update(VERIFIER).digest("base64url");
const STATE = "state-0123456789abcdef";
const EXT_ID = "a".repeat(32);
const REDIRECT = `https://${EXT_ID}.chromiumapp.org/`;
const CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const USER_CODE = "u".repeat(43);

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let db: FakeD1;
let env: Env;
beforeEach(() => {
    db = createFakeD1();
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

const deps = () => ({ jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => NOW });
const handoffs = () => db.raw.prepare("SELECT * FROM auth_handoffs").all() as Record<string, unknown>[];
const pairings = () => db.raw.prepare("SELECT * FROM extension_pairings").all() as Record<string, unknown>[];

type Opts = { token?: string | null; method?: string; body?: string; origin?: string | null; ua?: string; site?: string };
const call = (path: string, o: Opts = {}) => {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && o.method === "POST") headers.set("Origin", o.origin ?? WEB_ORIGIN);
    if (o.ua) headers.set("User-Agent", o.ua);
    if (o.site) headers.set("Sec-Fetch-Site", o.site);
    if (o.body !== undefined) headers.set("content-type", "application/x-www-form-urlencoded");
    return handleConnect(new Request(`https://cobalt.capybaraharmony.com${path}`, { method: o.method ?? "GET", headers, body: o.body, redirect: "manual" }), env, deps());
};

const chromeQuery = `challenge=${CHALLENGE}&state=${STATE}&redirect_uri=${encodeURIComponent(REDIRECT)}`;

describe("chromiumAppRedirect", () => {
    it("accepts a chromiumapp.org host and nothing that could wander", () => {
        expect(chromiumAppRedirect(REDIRECT)?.toString()).toBe(REDIRECT);
        expect(chromiumAppRedirect(`https://${EXT_ID}.chromiumapp.org/capystore`)?.pathname).toBe("/capystore");
        for (const bad of [
            "http://evil.example/",
            "https://evil.example/",
            "https://evil.example.chromiumapp.org/",
            `https://${"q".repeat(32)}.chromiumapp.org/`,
            `https://${"a".repeat(31)}.chromiumapp.org/`,
            `https://user:pass@${EXT_ID}.chromiumapp.org/`,
            `https://${EXT_ID}.chromiumapp.org:443/`,
            `https://${EXT_ID}.chromiumapp.org/#x`,
            `https://${EXT_ID}.chromiumapp.org/?next=https://evil.example`,
            `https://${EXT_ID}.chromiumapp.org/a/b`,
            "javascript:alert(1)",
            "https://chromiumapp.org/",
        ]) {
            expect(chromiumAppRedirect(bad), bad).toBeNull();
        }
    });
});

describe("GET /connect/extension", () => {
    it("without a valid Access JWT: 401 page, D1 untouched", async () => {
        db.breakIt();
        const r = await call(`/connect/extension?${chromeQuery}`, { token: null, ua: CHROME_MAC });
        expect(r.status).toBe(401);
        expect(r.headers.get("content-type")).toContain("text/html");
        expect(r.headers.get("location")).toBeNull();
    });
    it("a bad or missing query is a 400 page that stores nothing and echoes nothing", async () => {
        const bad = [
            "/connect/extension",
            `/connect/extension?challenge=${CHALLENGE}&state=${STATE}&redirect_uri=${encodeURIComponent("https://evil.example/")}`,
            `/connect/extension?challenge=short&state=${STATE}&redirect_uri=${encodeURIComponent(REDIRECT)}`,
            `/connect/extension?user_code=${USER_CODE}&challenge=${CHALLENGE}&state=${STATE}&redirect_uri=${encodeURIComponent(REDIRECT)}`,
        ];
        for (const path of bad) {
            const r = await call(path, { ua: CHROME_MAC });
            expect(r.status, path).toBe(400);
            const text = await r.text();
            expect(text).not.toContain("evil.example");
            expect(text).not.toContain(CHALLENGE);
        }
        expect(handoffs()).toEqual([]);
    });
    it("shows the consent form and does not approve yet", async () => {
        const r = await call(`/connect/extension?${chromeQuery}`, { ua: CHROME_MAC });
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(r.headers.get("x-frame-options")).toBe("DENY");
        expect(r.headers.get("content-security-policy")).toContain("default-src 'none'");
        const text = await r.text();
        expect(text).toContain("Browser extension – Chrome on Mac");
        expect(text).toContain("Approve");
        expect(text).toContain(`value="${CHALLENGE}"`);
        expect(text).toContain(`value="${STATE}"`);
        expect(text).toContain(`value="${REDIRECT}"`);
        expect(handoffs()).toEqual([]);
    });
});

describe("POST /connect/extension", () => {
    const body = `challenge=${CHALLENGE}&state=${encodeURIComponent(STATE)}&redirect_uri=${encodeURIComponent(REDIRECT)}`;
    it("refuses a post that is not from the page itself", async () => {
        for (const o of [{ origin: null }, { origin: "https://evil.example" }, { site: "cross-site" }] as Opts[]) {
            const r = await call("/connect/extension", { method: "POST", body, ua: CHROME_MAC, ...o });
            expect(r.status).toBe(403);
        }
        expect(handoffs()).toEqual([]);
    });
    it("stores a one-time code and redirects only to the extension", async () => {
        const r = await call("/connect/extension", { method: "POST", body, ua: CHROME_MAC });
        expect(r.status).toBe(302);
        expect(r.headers.get("referrer-policy")).toBe("no-referrer");
        const loc = new URL(r.headers.get("location")!);
        expect(loc.origin + loc.pathname).toBe(REDIRECT.slice(0, -1) === loc.origin ? REDIRECT : REDIRECT);
        expect(loc.hostname).toBe(`${EXT_ID}.chromiumapp.org`);
        expect(loc.searchParams.get("state")).toBe(STATE);
        const code = loc.searchParams.get("code")!;
        expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(handoffs()).toEqual([
            {
                code_hash: createHash("sha256").update(code).digest("hex"),
                challenge: CHALLENGE,
                device: "Browser extension – Chrome on Mac",
                platform: "extension",
                email: OWNER,
                created_at: NOW,
                expires_at: NOW + 120_000,
                used_at: null,
            },
        ]);
        expect(JSON.stringify(handoffs())).not.toContain(code);
    });
    it("a tampered redirect is a 400 and stores nothing", async () => {
        const evil = `challenge=${CHALLENGE}&state=${STATE}&redirect_uri=${encodeURIComponent("https://evil.example/steal")}`;
        const r = await call("/connect/extension", { method: "POST", body: evil, ua: CHROME_MAC });
        expect(r.status).toBe(400);
        expect(handoffs()).toEqual([]);
    });
    it("approves a Safari pairing and does not mint a token on the page", async () => {
        const hash = await hashKey(USER_CODE);
        db.raw
            .prepare("INSERT INTO extension_pairings (device_hash, user_hash, challenge, state, device, email, created_at, expires_at) VALUES (?, ?, ?, ?, 'Browser extension', NULL, ?, ?)")
            .run("d".repeat(64), hash, CHALLENGE, STATE, NOW, NOW + 300_000);
        const get = await call(`/connect/extension?user_code=${USER_CODE}`, { ua: CHROME_MAC });
        expect(get.status).toBe(200);
        expect(await get.text()).toContain(`value="${USER_CODE}"`);
        const post = await call("/connect/extension", { method: "POST", body: `user_code=${USER_CODE}`, ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15" });
        expect(post.status).toBe(200);
        const text = await post.text();
        expect(text).toContain("Browser extension – Safari on Mac");
        expect(text).not.toContain(USER_CODE);
        const row = pairings()[0]!;
        expect(row).toMatchObject({ approved_at: NOW, email: OWNER, device: "Browser extension – Safari on Mac", used_at: null });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE kind = 'session'").get()).toEqual({ n: 0 });
        const again = await call("/connect/extension", { method: "POST", body: `user_code=${USER_CODE}` });
        expect(again.status).toBe(200);
        expect(await again.text()).toContain("already approved");
    });
});

describe("routing", () => {
    it("runs the Worker first for /connect and /connect/*", () => {
        expect((config as { worker: { assets: { runWorkerFirst: string[] } } }).worker.assets.runWorkerFirst).toEqual(
            expect.arrayContaining(["/connect", "/connect/*"]),
        );
    });
    it("the entrypoint sends /connect/extension to the handler and leaves other paths to assets", async () => {
        const anon = (path: string) => worker.fetch(new Request(`https://cobalt.capybaraharmony.com${path}`), env);
        expect((await anon("/connect/extension")).status).toBe(401);
        expect(await (await anon("/connectx")).text()).toBe("asset");
    });
});
