// Search names (APP-API-CONTRACT.md section 48): the web Worker relays /api/library/names* to the API,
// passes names=0 through /api/library/search, and the page carries the names panel. The API is an in-memory fake.
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { API_BASE, handleLibrary, matchRoute } from "../src/library";
import { LIBRARY_HTML } from "../src/library/page.generated";
import type { Env } from "../src/keys";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const SERVICE_KEY = "7a1d1b0e-3f0c-4a53-8f55-2f1b8a9d0c11";
const NID = "aaaaaaaaaaaaaaaa";

type ApiCall = { url: string; method: string; headers: Record<string, string>; body: unknown };

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let apiCalls: ApiCall[];
let apiReply: (c: ApiCall) => Response;
let env: Env;

const jsonRes = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const generic503 = () => jsonRes(503, { status: "error", error: { code: "error.api.generic" } });

beforeEach(() => {
    apiCalls = [];
    apiReply = () => jsonRes(200, { status: "success" });
    env = {
        DB: createFakeD1(),
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        MEDIA: {} as unknown as R2Bucket,
        ORIGINALS: {} as unknown as R2Bucket,
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        API: {
            fetch: async (req: Request) => {
                const headers: Record<string, string> = {};
                req.headers.forEach((v, k) => (headers[k] = v));
                const text = await req.text();
                const c: ApiCall = { url: req.url, method: req.method, headers, body: text ? JSON.parse(text) : undefined };
                apiCalls.push(c);
                return apiReply(c);
            },
        } as unknown as Fetcher,
        COBALT_API_KEY: SERVICE_KEY,
    };
});

function call(method: string, path: string, o: { body?: unknown; raw?: string; origin?: string | null; token?: string | null } = {}) {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && method !== "GET") headers.set("Origin", o.origin ?? WEB_ORIGIN);
    let body: BodyInit | undefined;
    if (o.raw !== undefined) { body = o.raw; headers.set("content-type", "application/json"); }
    else if (o.body !== undefined) { body = JSON.stringify(o.body); headers.set("content-type", "application/json"); }
    const deps = { jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => NOW };
    return handleLibrary(new Request(`https://cobalt.capybaraharmony.com${path}`, { method, headers, body }), env, deps);
}
const json = async (r: Response) => JSON.parse(await r.text());
const errorCode = async (r: Response) => (await json(r)).error.code;
const sent = () => apiCalls.map((c) => [c.method, c.url.slice(API_BASE.length), c.body]);

describe("names routes", () => {
    it("matches the routes (ids are 16 base62)", () => {
        expect(matchRoute("/api/library/names")).toEqual({ name: "names" });
        expect(matchRoute("/api/library/names/preview")).toEqual({ name: "namesPreview" });
        expect(matchRoute("/api/library/names/post")).toEqual({ name: "namesPost" });
        expect(matchRoute(`/api/library/names/${NID}`)).toEqual({ name: "nameItem", id: NID });
        for (const bad of ["/api/library/names/", "/api/library/names/short", `/api/library/names/${NID}x`, `/api/library/names/${NID}/x`, "/api/library/name"]) {
            expect(matchRoute(bad)).toBeNull();
        }
    });
    it("405 with Allow for the wrong method", async () => {
        for (const [method, path, allow] of [
            ["PUT", "/api/library/names", "GET, POST"],
            ["GET", "/api/library/names/preview", "POST"],
            ["POST", "/api/library/names/post?key=a", "GET"],
            ["POST", `/api/library/names/${NID}`, "PATCH, DELETE"],
            ["GET", `/api/library/names/${NID}`, "PATCH, DELETE"],
        ] as const) {
            const r = await call(method, path);
            expect(r.status).toBe(405);
            expect(r.headers.get("allow")).toBe(allow);
        }
        expect(apiCalls).toHaveLength(0);
    });
    it("needs the login, and the web origin on writes", async () => {
        expect((await call("GET", "/api/library/names", { token: null })).status).toBe(401);
        expect((await call("POST", "/api/library/names", { body: {}, origin: "https://evil.example" })).status).toBe(403);
        expect((await call("DELETE", `/api/library/names/${NID}`, { origin: null })).status).toBe(403);
        expect(apiCalls).toHaveLength(0);
    });
    it("list, create, preview, patch, delete and the post row go to /library/names*", async () => {
        apiReply = () => jsonRes(200, { status: "success", names: [{ id: NID, name: "Lia" }] });
        expect(await json(await call("GET", "/api/library/names"))).toEqual({ status: "success", names: [{ id: NID, name: "Lia" }] });
        apiReply = () => jsonRes(201, { status: "success", name: { id: NID } });
        const created = await call("POST", "/api/library/names", { body: { name: "Lia", meaning: "pink cat girl", yes: ["k1"] } });
        expect(created.status).toBe(201);
        apiReply = () => jsonRes(200, { status: "success", embedded: true, carries: 1, indexed: 2, posts: [{ post_key: "k1", score: 1, mark: "yes", carries: true, post: { id: "k1", files: [] } }] });
        const prev = await json(await call("POST", "/api/library/names/preview", { body: { id: NID, strength: 0.6, limit: 100 } }));
        expect(prev.posts[0].post).toEqual({ id: "k1", files: [] });
        apiReply = () => jsonRes(200, { status: "success", name: { id: NID } });
        await call("PATCH", `/api/library/names/${NID}`, { body: { mark: [{ post_key: "k1", kind: null }] } });
        apiReply = () => jsonRes(200, { status: "success" });
        await call("DELETE", `/api/library/names/${NID}`);
        apiReply = () => jsonRes(200, { status: "success", names: [] });
        await call("GET", "/api/library/names/post?key=https%3A%2F%2Fx.com%2Fa%3Fb%3D1");
        expect(sent()).toEqual([
            ["GET", "/library/names", undefined],
            ["POST", "/library/names", { name: "Lia", meaning: "pink cat girl", yes: ["k1"] }],
            ["POST", "/library/names/preview", { id: NID, strength: 0.6, limit: 100 }],
            ["PATCH", `/library/names/${NID}`, { mark: [{ post_key: "k1", kind: null }] }],
            ["DELETE", `/library/names/${NID}`, undefined],
            ["GET", "/library/names/post?key=https%3A%2F%2Fx.com%2Fa%3Fb%3D1", undefined],
        ]);
        for (const c of apiCalls) {
            expect(c.headers["x-cobalt-service"]).toBe(SERVICE_KEY);
            for (const h of ["authorization", "cookie", "cf-access-jwt-assertion"]) expect(c.headers[h]).toBeUndefined();
        }
    });
    it("names/post needs a key", async () => {
        const r = await call("GET", "/api/library/names/post");
        expect(r.status).toBe(400);
        expect(apiCalls).toHaveLength(0);
    });
    it("API errors keep their status and code (503 means migration 0031 is not applied)", async () => {
        apiReply = generic503;
        const r = await call("GET", "/api/library/names");
        expect(r.status).toBe(503);
        expect(await errorCode(r)).toBe("error.api.generic");
        for (const [status, code] of [[400, "error.names.bad"], [404, "error.names.not_found"], [409, "error.names.too_many"]] as const) {
            apiReply = () => jsonRes(status, { status: "error", error: { code } });
            const e = await call("POST", "/api/library/names", { body: { name: "x" } });
            expect(e.status).toBe(status);
            expect(await errorCode(e)).toBe(code);
        }
    });
    it("error.names.taken keeps the clashing word", async () => {
        apiReply = () => jsonRes(409, { status: "error", error: { code: "error.names.taken", word: "capy" } });
        const r = await call("POST", "/api/library/names", { body: { name: "kappa", meaning: "m" } });
        expect(r.status).toBe(409);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.names.taken", word: "capy" } });
    });
    it("a body that is not a JSON object is 400 and never reaches the API", async () => {
        for (const raw of ["[]", "nope", "\"x\""]) {
            expect((await call("POST", "/api/library/names", { raw })).status).toBe(400);
            expect((await call("PATCH", `/api/library/names/${NID}`, { raw })).status).toBe(400);
            expect((await call("POST", "/api/library/names/preview", { raw })).status).toBe(400);
        }
        expect(apiCalls).toHaveLength(0);
    });
});

describe("search with names", () => {
    const answer = (extra: Record<string, unknown> = {}) => jsonRes(200, {
        status: "success", query: "lia", model: "m", index: { posts: 3, pending: 0 },
        posts: [{ id: "k1", score: 0.9, why: ["Lia"], files: [{ id: "bbbbbbbbbbbbbbbb", name: "a.webp", url: null }] }], ...extra,
    });
    it("passes names=0 through, and only that value", async () => {
        apiReply = () => answer();
        await call("GET", "/api/library/search?q=lia&names=0");
        expect(apiCalls[0]!.url).toBe(`${API_BASE}/library/search?q=lia&names=0&v=3`);
        for (const v of ["1", "", "true", "00"]) {
            const r = await call("GET", `/api/library/search?q=lia&names=${v}`);
            expect(r.status).toBe(400);
        }
        expect(apiCalls).toHaveLength(1);
    });
    it("leaves names out when the search did not ask", async () => {
        apiReply = () => answer();
        await call("GET", "/api/library/search?q=lia");
        expect(apiCalls[0]!.url).toBe(`${API_BASE}/library/search?q=lia&v=3`);
    });
    it("hands the names used and each post's why to the page", async () => {
        apiReply = () => answer({ names: [{ id: NID, name: "Lia", extra: 1 }] });
        const b = await json(await call("GET", "/api/library/search?q=lia"));
        expect(b.names).toEqual([{ id: NID, name: "Lia" }]);
        expect(b.items[0].why).toEqual(["Lia"]);
    });
});

describe("the page", () => {
    it("has the names tab, panel and actions, hidden until the API answers", () => {
        expect(LIBRARY_HTML).toContain('data-v="names" id="namesTab" aria-pressed="false" hidden');
        expect(LIBRARY_HTML).toContain('id="namesView"');
        expect(LIBRARY_HTML).toContain('"/api/library/names"');
        expect(LIBRARY_HTML).toContain('"/api/library/names/preview"');
        expect(LIBRARY_HTML).toContain('"/api/library/names/post?key="');
        expect(LIBRARY_HTML).toContain("&names=0");
        expect(LIBRARY_HTML).toContain("this is…");
        expect(LIBRARY_HTML).toContain("function namesOff()");
        expect(LIBRARY_HTML).toContain("}, now ? 0 : 300);");
    });
});
