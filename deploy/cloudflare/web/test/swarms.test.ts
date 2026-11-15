// /swarms page and /api/swarms*: Access JWT, Origin on POST, a clean body to the API through the service binding,
// and the API's errors mapped for the page.
import { readFileSync } from "node:fs";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import config from "../cloudflare.config";
import worker from "../src/index";
import { SWARMS_CSP, handleSwarms, matchRoute } from "../src/swarms";
import { SWARMS_HTML } from "../src/swarms/page.generated";
import type { Env } from "../src/keys";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const SECRET_KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const ID = "AbCdEf0123456789";
const HASH = "sha256:0123456789abcdef";

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

type Seen = { url: string; method: string; headers: Headers; body: string };
let seen: Seen[];
let reply: { status: number; body: unknown };
let env: Env;
beforeEach(() => {
    seen = [];
    reply = { status: 200, body: { swarm: ID, status: "running" } };
    env = {
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        API: {
            fetch: async (req: Request) => {
                seen.push({ url: req.url, method: req.method, headers: req.headers, body: await req.text() });
                return new Response(JSON.stringify(reply.body), { status: reply.status });
            },
        } as unknown as Fetcher,
        COBALT_API_KEY: SECRET_KEY,
    } as unknown as Env;
});

const deps = () => ({ jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => NOW });
function call(path: string, o: { method?: string; token?: string | null; origin?: string | null; body?: unknown; ct?: string } = {}) {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    const method = o.method ?? "GET";
    const origin = o.origin === undefined ? (method === "POST" ? WEB_ORIGIN : null) : o.origin;
    if (origin) headers.set("Origin", origin);
    let body: string | undefined;
    if (o.body !== undefined) {
        body = typeof o.body === "string" ? o.body : JSON.stringify(o.body);
        headers.set("content-type", o.ct ?? "application/json");
    }
    return handleSwarms(new Request(`${WEB_ORIGIN}${path}`, { method, headers, body }), env, deps());
}
const code = async (r: Response) => ((await r.json()) as any).error?.code;

describe("routing", () => {
    it("matches pages and API routes", () => {
        expect(matchRoute("/swarms")).toEqual({ name: "page" });
        expect(matchRoute(`/swarms/${ID}`)).toEqual({ name: "page" });
        expect(matchRoute("/swarms/short")).toBeNull();
        expect(matchRoute("/api/swarms")).toEqual({ name: "list" });
        expect(matchRoute(`/api/swarms/${ID}/apply`)).toEqual({ name: "action", id: ID, action: "apply" });
        expect(matchRoute(`/api/swarms/${ID}/decide`)).toBeNull();
        expect(matchRoute(`/api/swarms/${ID}/../x`)).toBeNull();
    });
    it("runs the Worker first for the swarm paths and the index routes them", async () => {
        const w = (config as any).worker;
        expect(w.assets.runWorkerFirst).toEqual(expect.arrayContaining(["/swarms", "/swarms/*", "/api/swarms", "/api/swarms/*"]));
        const r = await worker.fetch(new Request(`${WEB_ORIGIN}/api/swarms`), env);
        expect(r.status).toBe(401);
    });
});

describe("auth", () => {
    it.each(["/swarms", `/swarms/${ID}`, "/api/swarms", `/api/swarms/${ID}`])("%s needs the owner JWT", async (p) => {
        expect((await call(p, { token: null })).status).toBe(401);
        expect((await call(p, { token: "junk" })).status).toBe(401);
        expect(seen).toHaveLength(0);
    });
    it("POSTs need the web origin", async () => {
        for (const origin of [null, "https://evil.example"]) {
            const r = await call(`/api/swarms/${ID}/stop`, { method: "POST", origin });
            expect(r.status).toBe(403);
        }
        expect(seen).toHaveLength(0);
    });
});

describe("page", () => {
    it("serves the page with the CSP", async () => {
        const r = await call(`/swarms/${ID}`);
        expect(r.status).toBe(200);
        expect(r.headers.get("content-security-policy")).toBe(SWARMS_CSP);
        expect(SWARMS_CSP).toContain("img-src 'self' data: https://cdn.7tv.app https://media.capybaraharmony.com");
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(await r.text()).toBe(SWARMS_HTML);
        expect((await call("/swarms", { method: "HEAD" })).status).toBe(200);
        expect((await call("/swarms", { method: "POST" })).status).toBe(405);
    });
    it("page.generated.ts is in sync with page.html (run npm run swarms:build)", () => {
        expect(SWARMS_HTML).toBe(readFileSync(new URL("../src/swarms/page.html", import.meta.url), "utf8"));
    });
    it("is self-contained with a valid inline script and no secrets", () => {
        expect(SWARMS_HTML).not.toMatch(/<script[^>]*\bsrc=/i);
        const hosts = new Set([...SWARMS_HTML.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)].map((m) => m[1]));
        for (const h of hosts) expect(["fonts.googleapis.com", "fonts.gstatic.com"]).toContain(h);
        expect(SWARMS_HTML).not.toContain("COBALT_API_KEY");
        const m = /<script>([\s\S]*)<\/script>/.exec(SWARMS_HTML);
        expect(() => new Function(m![1]!)).not.toThrow();
        expect(SWARMS_HTML).toMatch(/prefers-color-scheme|light-dark\(/);
    });
});

describe("proxy", () => {
    it("forwards GETs with the service key and validated paging", async () => {
        const r = await call(`/api/swarms/${ID}/changes?offset=200&limit=200&evil=1`);
        expect(r.status).toBe(200);
        expect(seen[0]!.url).toBe(`https://api.capybaraharmony.com/swarms/${ID}/changes?offset=200&limit=200`);
        expect(seen[0]!.headers.get("x-cobalt-service")).toBe(SECRET_KEY);
        expect(seen[0]!.headers.get("cf-access-jwt-assertion")).toBeNull();
        expect(seen[0]!.method).toBe("GET");
    });
    it("rejects bad paging", async () => {
        expect((await call(`/api/swarms/${ID}/changes?limit=201`)).status).toBe(400);
        expect((await call(`/api/swarms/${ID}/results?limit=101`)).status).toBe(400);
        expect((await call(`/api/swarms/${ID}/results?offset=-1`)).status).toBe(400);
        expect(seen).toHaveLength(0);
    });
    it("the board (section 62.4): known params only, each checked", async () => {
        const r = await call(`/api/swarms/${ID}/board?q=cat%20ears&agent=3&status=done&group=x&sort=score&offset=100&limit=200&evil=1`);
        expect(r.status).toBe(200);
        expect(seen[0]!.url).toBe(`https://api.capybaraharmony.com/swarms/${ID}/board?offset=100&limit=200&agent=3&q=cat+ears&group=x&status=done&sort=score`);
        expect(seen[0]!.method).toBe("GET");
        for (const bad of ["limit=201", "agent=0", "agent=x", "sort=best", "status=nope", `q=${"x".repeat(201)}`]) expect((await call(`/api/swarms/${ID}/board?${bad}`)).status, bad).toBe(400);
        expect((await call(`/api/swarms/${ID}/board`, { method: "POST", body: {} })).status).toBe(405);
        expect(seen).toHaveLength(1);
    });
    it("approve and apply send only spec_hash", async () => {
        for (const a of ["approve", "apply"]) {
            const r = await call(`/api/swarms/${ID}/${a}`, { method: "POST", body: { spec_hash: HASH, extra: "x" } });
            expect(r.status).toBe(200);
        }
        expect(seen.map((s) => s.url.split("/").pop())).toEqual(["approve", "apply"]);
        for (const s of seen) expect(JSON.parse(s.body)).toEqual({ spec_hash: HASH });
        expect((await call(`/api/swarms/${ID}/approve`, { method: "POST", body: {} })).status).toBe(400);
        expect((await call(`/api/swarms/${ID}/approve`, { method: "POST", body: { spec_hash: "x y" } })).status).toBe(400);
        expect((await call(`/api/swarms/${ID}/approve`, { method: "POST", body: "{}", ct: "text/plain" })).status).toBe(415);
    });
    it("decline and stop send no body", async () => {
        await call(`/api/swarms/${ID}/decline`, { method: "POST" });
        await call(`/api/swarms/${ID}/stop`, { method: "POST" });
        expect(seen.map((s) => [s.method, s.body])).toEqual([["POST", ""], ["POST", ""]]);
    });
    it("decisions are rebuilt from known fields and capped", async () => {
        const r = await call(`/api/swarms/${ID}/changes`, { method: "POST", body: { changes: [{ n: 1, keep: false, junk: 1 }, { n: 2, after: "New" }] } });
        expect(r.status).toBe(200);
        expect(JSON.parse(seen[0]!.body)).toEqual({ changes: [{ n: 1, keep: false }, { n: 2, after: "New" }] });
        const bad = [
            { changes: [] },
            { changes: [{ n: "1" }] },
            { changes: [{ n: 1, keep: "yes" }] },
            { changes: [{ n: 1, after: 5 }] },
            { changes: Array.from({ length: 501 }, (_, n) => ({ n })) },
            [],
        ];
        for (const b of bad) expect((await call(`/api/swarms/${ID}/changes`, { method: "POST", body: b })).status).toBe(400);
        expect(seen).toHaveLength(1);
    });
    it("caps the body size", async () => {
        const big = { spec_hash: HASH, pad: "x".repeat(300_000) };
        expect((await call(`/api/swarms/${ID}/apply`, { method: "POST", body: big })).status).toBe(413);
    });
});

describe("API errors", () => {
    const apiErr = (status: number, c: string) => (reply = { status, body: { status: "error", error: { code: c } } });
    it("404 is not_found", async () => {
        apiErr(404, "error.swarm.not_found");
        const r = await call(`/api/swarms/${ID}`);
        expect(r.status).toBe(404);
        expect(await code(r)).toBe("error.swarm.not_found");
    });
    it("409 and 400 pass the API code through", async () => {
        apiErr(409, "error.swarm.hash_mismatch");
        let r = await call(`/api/swarms/${ID}/apply`, { method: "POST", body: { spec_hash: HASH } });
        expect([r.status, await code(r)]).toEqual([409, "error.swarm.hash_mismatch"]);
        apiErr(400, "error.swarm.bad_spec");
        r = await call(`/api/swarms/${ID}/approve`, { method: "POST", body: { spec_hash: HASH } });
        expect([r.status, await code(r)]).toEqual([400, "error.swarm.bad_spec"]);
    });
    it("401, 403 and 5xx from the API are a 502 upstream", async () => {
        for (const s of [401, 403, 500, 503]) {
            apiErr(s, "error.swarm.owner_only");
            const r = await call(`/api/swarms/${ID}`);
            expect([r.status, await code(r)]).toEqual([502, "upstream"]);
        }
    });
    it("a throwing binding or a missing key is a 502", async () => {
        (env.API as any).fetch = async () => {
            throw new Error("down");
        };
        expect((await call("/api/swarms")).status).toBe(502);
        env.COBALT_API_KEY = "";
        expect((await call("/api/swarms")).status).toBe(502);
    });
});
