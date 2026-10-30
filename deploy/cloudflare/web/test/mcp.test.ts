// /api/mcp and /api/mcp/rotate (APP-API-CONTRACT.md section 35.5): Access first, the web origin for POSTs, then the API
// through the service binding with the internal key; the API's answer is passed on as is.
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleMcp } from "../src/mcp";
import type { Env } from "../src/keys";
import config from "../cloudflare.config";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const INTERNAL = "00000000-0000-4000-8000-000000000000";
let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let apiCalls: { method: string; url: string; service: string | null; body: string }[];
let apiAnswer: () => Response;
let env: Env;
beforeEach(() => {
    apiCalls = [];
    apiAnswer = () => Response.json({ mode: "public", public_url: "https://api.capybaraharmony.com/mcp", link: null });
    env = {
        DB: {} as D1Database,
        ASSETS: {} as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        MEDIA: {} as R2Bucket,
        ORIGINALS: {} as R2Bucket,
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        API: {
            fetch: async (r: Request) => {
                apiCalls.push({ method: r.method, url: r.url, service: r.headers.get("x-cobalt-service"), body: r.method === "GET" ? "" : await r.text() });
                return apiAnswer();
            },
        } as unknown as Fetcher,
        COBALT_API_KEY: INTERNAL,
    };
});

const deps = () => ({ jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => NOW });
const call = (method: string, path: string, o: { token?: string | null; origin?: string | null; body?: string; type?: string } = {}) => {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (method !== "GET" && o.origin !== null) headers.set("Origin", o.origin ?? WEB_ORIGIN);
    if (o.body !== undefined) headers.set("content-type", o.type ?? "application/json");
    return handleMcp(new Request(`https://cobalt.capybaraharmony.com${path}`, { method, headers, body: o.body }), env, deps());
};

describe("/api/mcp", () => {
    it("GET forwards to the API's settings with the service key", async () => {
        const res = await call("GET", "/api/mcp");
        expect(res.status).toBe(200);
        expect(((await res.json()) as any).mode).toBe("public");
        expect(apiCalls).toEqual([{ method: "GET", url: "https://api.capybaraharmony.com/mcp/settings", service: INTERNAL, body: "" }]);
    });
    it("POST sends only a known mode; the link in the answer is passed on", async () => {
        apiAnswer = () => Response.json({ settings: { mode: "private" }, link_url: "https://api.capybaraharmony.com/mcp/k/x" });
        const res = await call("POST", "/api/mcp", { body: JSON.stringify({ mode: "private", extra: 1 }) });
        expect(((await res.json()) as any).link_url).toMatch(/\/mcp\/k\//);
        expect(apiCalls[0]).toMatchObject({ method: "POST", url: "https://api.capybaraharmony.com/mcp/settings", body: '{"mode":"private"}' });
        expect((await call("POST", "/api/mcp", { body: JSON.stringify({ mode: "all" }) })).status).toBe(400);
        expect((await call("POST", "/api/mcp", { body: "nope" })).status).toBe(400);
        expect((await call("POST", "/api/mcp", { body: "{}", type: "text/plain" })).status).toBe(415);
        expect(apiCalls).toHaveLength(1);
    });
    it("rotate forwards; the API's 409 stays a 409", async () => {
        apiAnswer = () => Response.json({ status: "error", error: { code: "error.mcp.not_private" } }, { status: 409 });
        const res = await call("POST", "/api/mcp/rotate");
        expect(res.status).toBe(409);
        expect(apiCalls[0]!.url).toBe("https://api.capybaraharmony.com/mcp/settings/rotate");
    });
    it("no Access login, another origin, a wrong method or path never reach the API", async () => {
        expect((await call("GET", "/api/mcp", { token: null })).status).toBe(401);
        expect((await call("POST", "/api/mcp/rotate", { origin: "https://evil.example" })).status).toBe(403);
        expect((await call("POST", "/api/mcp/rotate", { origin: null })).status).toBe(403);
        expect((await call("GET", "/api/mcp/rotate")).status).toBe(405);
        expect((await call("DELETE", "/api/mcp")).status).toBe(405);
        expect((await call("GET", "/api/mcp/other")).status).toBe(404);
        expect(apiCalls).toHaveLength(0);
    });
    it("an API 401 (wrong service key) is a 502, never a login problem", async () => {
        apiAnswer = () => new Response(null, { status: 401 });
        expect((await call("GET", "/api/mcp")).status).toBe(502);
    });
    it("runs the Worker first for /api/mcp", () => {
        expect((config as any).worker.assets.runWorkerFirst).toEqual(expect.arrayContaining(["/api/mcp", "/api/mcp/*"]));
    });
});
