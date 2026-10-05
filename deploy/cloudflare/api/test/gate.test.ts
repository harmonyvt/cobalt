import { describe, expect, it } from "vitest";
import { decide, type GateRequest } from "../src/gate";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const ORIGIN = "https://cobalt.capybaraharmony.com";
const NOW = 1_800_000_000_000;
const cfg = { corsUrl: ORIGIN, now: NOW };

const req = (o: Partial<GateRequest> & { query?: string }): GateRequest => ({
    method: "GET",
    pathname: "/",
    searchParams: new URLSearchParams(o.query ?? ""),
    origin: null,
    authorization: null,
    ...o,
});

const tunnelQuery = (over: Record<string, string | null> = {}) => {
    const p: Record<string, string | null> = {
        id: "a".repeat(21),
        exp: String(NOW + 60_000),
        sig: "s".repeat(43),
        sec: "c".repeat(43),
        iv: "i".repeat(22),
        ...over,
    };
    return Object.entries(p)
        .filter(([, v]) => v !== null)
        .map(([k, v]) => `${k}=${v}`)
        .join("&");
};

describe("POST /", () => {
    const post = (authorization: string | null) =>
        decide(req({ method: "POST", authorization }), cfg);
    const invalid = { action: "reject", status: 401, errorCode: "error.api.auth.key.invalid" };

    it("returns a lookup for a well-formed key", () => {
        expect(post(`Api-Key ${KEY}`)).toEqual({ action: "lookup", key: KEY });
    });
    it("accepts the scheme case-insensitively, like the API", () => {
        expect(post(`api-key ${KEY}`)).toEqual({ action: "lookup", key: KEY });
        expect(post(`API-KEY ${KEY}`)).toEqual({ action: "lookup", key: KEY });
    });
    it("401 missing without header", () => {
        expect(post(null)).toEqual({
            action: "reject",
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
    });
    it("401 not_api_key for a Bearer header or an empty one", () => {
        expect(post("Bearer abc")).toMatchObject({
            status: 401,
            errorCode: "error.api.auth.key.not_api_key",
        });
        expect(post(`Bearer ${KEY}`)).toMatchObject({
            errorCode: "error.api.auth.key.not_api_key",
        });
        expect(post("")).toMatchObject({ errorCode: "error.api.auth.key.not_api_key" });
    });
    it("401 invalid for anything that is not a lowercase UUID", () => {
        expect(post("Api-Key nope")).toEqual(invalid);
        expect(post("Api-Key")).toEqual(invalid);
        expect(post("Api-Key ")).toEqual(invalid);
        expect(post(`Api-Key ${KEY} `)).toEqual(invalid);
        expect(post(`Api-Key  ${KEY}`)).toEqual(invalid);
        expect(post(`Api-Key ${KEY.toUpperCase()}`)).toEqual(invalid);
        expect(post(`Api-Key ${KEY}\tx`)).toEqual(invalid);
        expect(post(`Api-Key ${KEY.slice(1)}`)).toEqual(invalid);
        expect(post(`Api-Key ${KEY}${KEY}`)).toEqual(invalid);
    });
    it("a valid Origin does not substitute for a key", () => {
        expect(
            decide(req({ method: "POST", origin: ORIGIN, authorization: "Api-Key x" }), cfg),
        ).toMatchObject({ status: 401 });
        expect(decide(req({ method: "POST", origin: ORIGIN }), cfg)).toMatchObject({
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
    });
});

const ID = "aB3dE6gH9jK2mN5pQ8sT"; // 20 alphanumerics, what the DO mints
const NAME = "Xy7Zk9Lm2Q.webp";

describe("POST /webp", () => {
    const post = (authorization: string | null) =>
        decide(req({ method: "POST", pathname: "/webp", authorization }), cfg);
    it("looks the key up, then creates", () => {
        expect(post(`Api-Key ${KEY}`)).toEqual({
            action: "lookup",
            key: KEY,
            then: "webp_create",
        });
    });
    it("401s like POST / without a well-formed key", () => {
        expect(post(null)).toMatchObject({ status: 401, errorCode: "error.api.auth.key.missing" });
        expect(post("Bearer x")).toMatchObject({ errorCode: "error.api.auth.key.not_api_key" });
        expect(post("Api-Key nope")).toMatchObject({ errorCode: "error.api.auth.key.invalid" });
    });
    it("an Origin does not substitute for a key", () => {
        expect(
            decide(req({ method: "POST", pathname: "/webp", origin: ORIGIN }), cfg),
        ).toMatchObject({ status: 401 });
    });
    it("only POST is routed: GET /webp and PUT /webp are 404", () => {
        expect(decide(req({ pathname: "/webp", authorization: `Api-Key ${KEY}` }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ method: "PUT", pathname: "/webp", authorization: `Api-Key ${KEY}` }), cfg)).toMatchObject({ status: 404 });
    });
});

describe("GET /webp/:id", () => {
    const get = (pathname: string, authorization: string | null = `Api-Key ${KEY}`) =>
        decide(req({ pathname, authorization }), cfg);
    it("looks the key up with the id as a param", () => {
        expect(get(`/webp/${ID}`)).toEqual({
            action: "lookup",
            key: KEY,
            then: "webp_status",
            params: { id: ID },
        });
    });
    it("keeps the query (wait) out of the decision", () => {
        expect(
            decide(req({ pathname: `/webp/${ID}`, query: "wait=20", authorization: `Api-Key ${KEY}` }), cfg),
        ).toMatchObject({ then: "webp_status", params: { id: ID } });
    });
    it("401 without a key", () => {
        expect(get(`/webp/${ID}`, null)).toMatchObject({ status: 401, errorCode: "error.api.auth.key.missing" });
    });
    it.each([
        "/webp/",
        "/webp/short",
        `/webp/${"a".repeat(15)}`,
        `/webp/${"a".repeat(33)}`,
        `/webp/${ID}/`,
        `/webp/${ID}/file`,
        `/webp/${ID.slice(0, 19)}-`,
        `/webp/..%2f${ID}`,
        `/webp/${ID}.webp`,
    ])("404 for a malformed id %s", (p) => {
        expect(get(p)).toMatchObject({ action: "reject", status: 404 });
    });
    it("accepts 16 and 32 character ids", () => {
        expect(get(`/webp/${"a".repeat(16)}`)).toMatchObject({ action: "lookup" });
        expect(get(`/webp/${"Z9".repeat(16)}`)).toMatchObject({ action: "lookup" });
    });
});

describe("DELETE /media/:name", () => {
    const del = (pathname: string, authorization: string | null = `Api-Key ${KEY}`) =>
        decide(req({ method: "DELETE", pathname, authorization }), cfg);
    it("looks the key up with the name as a param", () => {
        expect(del(`/media/${NAME}`)).toEqual({
            action: "lookup",
            key: KEY,
            then: "media_delete",
            params: { name: NAME },
        });
    });
    it("401 without a key", () => {
        expect(del(`/media/${NAME}`, null)).toMatchObject({ status: 401 });
    });
    it.each([
        "/media/",
        "/media/Xy7Zk9Lm2Q",
        "/media/Xy7Zk9Lm2Q.png",
        "/media/Xy7Zk9Lm2.webp",
        "/media/Xy7Zk9Lm2QQ.webp",
        "/media/Xy7Zk9Lm2Q.webp/x",
        "/media/../Xy7Zk9Lm2Q.webp",
        "/media/Xy7Zk9Lm-Q.webp",
    ])("404 for a malformed name %s", (p) => {
        expect(del(p)).toMatchObject({ action: "reject", status: 404 });
    });
    it("GET /media/:name is not routed (the bucket is public, not the Worker)", () => {
        expect(
            decide(req({ pathname: `/media/${NAME}`, authorization: `Api-Key ${KEY}` }), cfg),
        ).toMatchObject({ status: 404 });
    });
});

describe("OPTIONS", () => {
    it("forwards for the web origin", () => {
        expect(decide(req({ method: "OPTIONS", origin: ORIGIN }), cfg)).toEqual({ action: "forward" });
    });
    it("403 for other or missing origin", () => {
        expect(decide(req({ method: "OPTIONS", origin: "https://evil.example" }), cfg)).toMatchObject({ status: 403 });
        expect(decide(req({ method: "OPTIONS" }), cfg)).toMatchObject({ status: 403 });
        expect(decide(req({ method: "OPTIONS", origin: ORIGIN + "/" }), cfg)).toMatchObject({ status: 403 });
    });
});

describe("GET /", () => {
    it("forwards for the web origin", () => {
        expect(decide(req({ origin: ORIGIN }), cfg)).toEqual({ action: "forward" });
    });
    it("404 otherwise", () => {
        expect(decide(req({}), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ origin: "https://evil.example" }), cfg)).toMatchObject({ status: 404 });
    });
});

describe("GET /tunnel", () => {
    const t = (query: string) => decide(req({ pathname: "/tunnel", query }), cfg);
    it("forwards with all params and a future exp (no Origin needed)", () => {
        expect(t(tunnelQuery())).toEqual({ action: "forward" });
        expect(t(tunnelQuery() + "&p=1")).toEqual({ action: "forward" });
    });
    it.each(["id", "exp", "sig", "sec", "iv"])("404 when %s is missing", (k) => {
        expect(t(tunnelQuery({ [k]: null }))).toMatchObject({ status: 404 });
    });
    it("404 when expired, at expiry, or non-numeric", () => {
        expect(t(tunnelQuery({ exp: String(NOW - 1) }))).toMatchObject({ status: 404 });
        expect(t(tunnelQuery({ exp: String(NOW) }))).toMatchObject({ status: 404 });
        expect(t(tunnelQuery({ exp: "soon" }))).toMatchObject({ status: 404 });
    });
});

describe("everything else", () => {
    it("404s", () => {
        const cases = [
            ["GET", "/favicon.ico"],
            ["GET", "/anything"],
            ["POST", "/tunnel"],
            ["POST", "/x"],
            ["PUT", "/"],
            ["DELETE", "/"],
            ["HEAD", "/"],
        ];
        for (const [method, pathname] of cases) {
            expect(
                decide(req({ method, pathname, origin: ORIGIN, authorization: `Api-Key ${KEY}` }), cfg),
            ).toMatchObject({ action: "reject", status: 404 });
        }
    });
});

// ---- the app's routes (APP-API-CONTRACT.md) ----------------------------------------------
describe("GET /capabilities (never a 401: the key's state is the answer)", () => {
    const c = (o: Partial<GateRequest>) => decide(req({ pathname: "/capabilities", ...o }), cfg);

    it("open to everyone, the Authorization header only changes what the Worker reports", () => {
        expect(c({})).toEqual({ action: "capabilities", auth: "missing" });
        expect(c({ authorization: `Api-Key ${KEY}` })).toEqual({ action: "capabilities", auth: "key", key: KEY });
        expect(c({ authorization: `api-key ${KEY}` })).toEqual({ action: "capabilities", auth: "key", key: KEY });
    });
    it("a malformed or non-key header is 'invalid', not a rejection", () => {
        for (const authorization of ["", "Bearer abc", `Bearer ${KEY}`, "Api-Key nope", `Api-Key ${KEY.toUpperCase()}`, `Api-Key  ${KEY}`, `Api-Key ${KEY} x`]) {
            expect(c({ authorization })).toEqual({ action: "capabilities", auth: "invalid" });
        }
    });
    it("the library service credential is reported as the service", () => {
        expect(c({ service: true })).toEqual({ action: "capabilities", auth: "service" });
    });
    it("an Origin changes nothing; only GET is allowed", () => {
        expect(c({ origin: ORIGIN })).toEqual({ action: "capabilities", auth: "missing" });
        for (const method of ["POST", "PUT", "DELETE", "HEAD"]) {
            expect(c({ method, authorization: `Api-Key ${KEY}` })).toMatchObject({ action: "reject", status: 404 });
        }
        expect(decide(req({ pathname: "/capabilities/x" }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ pathname: "/capabilitiesx" }), cfg)).toMatchObject({ status: 404 });
    });
});

describe("the app's library routes (keyed)", () => {
    const ID = "Ab3dE6gH9jK2mN5p"; // 16
    const keyed = { authorization: `Api-Key ${KEY}` };
    const lookup = (then: string, params?: Record<string, string>) => ({
        action: "lookup",
        key: KEY,
        then,
        ...(params ? { params } : {}),
    });
    const g = (method: string, pathname: string, o: Partial<GateRequest> = keyed) => decide(req({ method, pathname, ...o }), cfg);

    it("GET /library, GET|HEAD /library/items/<id>/file, POST publish and studio look the key up", () => {
        expect(g("GET", "/library")).toEqual(lookup("library_list"));
        expect(g("GET", `/library/items/${ID}/file`)).toEqual(lookup("library_file", { id: ID }));
        expect(g("HEAD", `/library/items/${ID}/file`)).toEqual(lookup("library_file", { id: ID }));
        expect(g("POST", `/library/items/${ID}/publish`)).toEqual(lookup("library_publish", { id: ID }));
        expect(g("POST", `/library/items/${ID}/studio`)).toEqual(lookup("library_studio", { id: ID }));
    });
    it("POST /library/posters/backfill (section 13) looks the key up; the service credential passes; everything else is 404 or 401", () => {
        expect(g("POST", "/library/posters/backfill")).toEqual(lookup("library_posters_backfill"));
        expect(g("POST", "/library/posters/backfill", { service: true })).toEqual({ action: "service", then: "library_posters_backfill" });
        for (const method of ["GET", "HEAD", "PUT", "DELETE", "PATCH"]) {
            expect(g(method, "/library/posters/backfill")).toMatchObject({ action: "reject", status: 404 });
        }
        for (const path of ["/library/posters", "/library/posters/", "/library/posters/backfill/", "/library/posters/backfill/x", "/posters/kick", "/library/posters/other"]) {
            expect(g("POST", path)).toMatchObject({ action: "reject", status: 404 });
        }
        expect(g("POST", "/library/posters/backfill", {})).toMatchObject({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
        // an Origin is no substitute for a key
        expect(g("POST", "/library/posters/backfill", { origin: ORIGIN })).toMatchObject({ status: 401 });
    });
    it("DELETE /library/items/<id>/post looks the key up; the service credential passes; other methods are 404", () => {
        expect(g("DELETE", `/library/items/${ID}/post`)).toEqual(lookup("library_post_delete", { id: ID }));
        expect(g("DELETE", `/library/items/${ID}/post`, { service: true })).toEqual({
            action: "service",
            then: "library_post_delete",
            params: { id: ID },
        });
        for (const method of ["GET", "HEAD", "POST", "PUT"]) {
            expect(g(method, `/library/items/${ID}/post`)).toMatchObject({ action: "reject", status: 404 });
        }
        // an Origin is no substitute for a key, and gets no CORS preflight answer
        expect(g("DELETE", `/library/items/${ID}/post`, { origin: ORIGIN })).toMatchObject({ status: 401 });
        expect(g("DELETE", `/library/items/${ID}/post`, {})).toMatchObject({
            action: "reject",
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
        expect(g("DELETE", `/library/items/${ID}/post`, { authorization: "Api-Key nope" })).toMatchObject({
            status: 401,
            errorCode: "error.api.auth.key.invalid",
        });
        expect(g("DELETE", `/library/items/${ID}/post/x`)).toMatchObject({ status: 404 });
    });
    it("PATCH /library/items/<id>/post (section 15) looks the key up; the service credential passes; ids are checked; no key is 401", () => {
        expect(g("PATCH", `/library/items/${ID}/post`)).toEqual(lookup("library_post_title", { id: ID }));
        expect(g("PATCH", `/library/items/${ID}/post`, { service: true })).toEqual({
            action: "service",
            then: "library_post_title",
            params: { id: ID },
        });
        for (const id of [ID.slice(0, 15), ID + "x", "", "Ab3dE6gH9jK2mN5-", "../../studio/aaaaa"]) {
            expect(g("PATCH", `/library/items/${id}/post`)).toMatchObject({ action: "reject", status: 404 });
        }
        expect(g("PATCH", `/library/items/${ID}/post/x`)).toMatchObject({ status: 404 });
        expect(g("PATCH", `/library/items/${ID}/file`)).toMatchObject({ status: 404 });
        expect(g("PATCH", `/library/items/${ID}/post`, { origin: ORIGIN })).toMatchObject({ status: 401 });
        expect(g("PATCH", `/library/items/${ID}/post`, {})).toMatchObject({
            action: "reject",
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
        expect(g("PATCH", `/library/items/${ID}/post`, { authorization: "Api-Key nope" })).toMatchObject({
            status: 401,
            errorCode: "error.api.auth.key.invalid",
        });
        // the other methods are still 404, DELETE is still the post delete
        for (const method of ["GET", "HEAD", "POST", "PUT"]) {
            expect(g(method, `/library/items/${ID}/post`)).toMatchObject({ action: "reject", status: 404 });
        }
        expect(g("DELETE", `/library/items/${ID}/post`)).toEqual(lookup("library_post_delete", { id: ID }));
    });
    it("DELETE .../post: ids of 15 or 17 characters (or odd ones) are 404 before any lookup", () => {
        for (const id of [ID.slice(0, 15), ID + "x", "", "Ab3dE6gH9jK2mN5-", "../../studio/aaaaa"]) {
            expect(g("DELETE", `/library/items/${id}/post`)).toMatchObject({ action: "reject", status: 404 });
        }
    });
    it("without a key: 401 with the API's own codes; an Origin is no substitute", () => {
        for (const [method, p] of [
            ["GET", "/library"],
            ["GET", `/library/items/${ID}/file`],
            ["POST", `/library/items/${ID}/publish`],
            ["POST", `/library/items/${ID}/studio`],
        ] as const) {
            expect(g(method, p, {})).toMatchObject({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
            expect(g(method, p, { origin: ORIGIN })).toMatchObject({ status: 401 });
            expect(g(method, p, { authorization: "Bearer x" })).toMatchObject({ status: 401, errorCode: "error.api.auth.key.not_api_key" });
            expect(g(method, p, { authorization: "Api-Key nope" })).toMatchObject({ status: 401, errorCode: "error.api.auth.key.invalid" });
        }
    });
    it("the library service credential passes without a key", () => {
        expect(g("GET", "/library", { service: true })).toEqual({ action: "service", then: "library_list" });
        expect(g("POST", `/library/items/${ID}/publish`, { service: true })).toEqual({
            action: "service",
            then: "library_publish",
            params: { id: ID },
        });
    });
    it("item ids are exactly 16 base62 characters: 15, 17, empty or odd characters are 404 before any lookup", () => {
        for (const id of [ID.slice(0, 15), ID + "x", "", "Ab3dE6gH9jK2mN5-", "Ab3dE6gH9jK2mN5.", "../../studio/aaaaa"]) {
            for (const [method, sub] of [["GET", "file"], ["POST", "publish"], ["POST", "studio"]] as const) {
                expect(g(method, `/library/items/${id}/${sub}`)).toMatchObject({ action: "reject", status: 404 });
            }
        }
    });
    it("wrong methods and unknown sub-paths are 404, even with a key", () => {
        expect(g("POST", "/library")).toMatchObject({ status: 404 });
        expect(g("DELETE", "/library")).toMatchObject({ status: 404 });
        expect(g("GET", "/library/")).toMatchObject({ status: 404 });
        expect(g("POST", `/library/items/${ID}/file`)).toMatchObject({ status: 404 });
        expect(g("GET", `/library/items/${ID}/publish`)).toMatchObject({ status: 404 });
        expect(g("GET", `/library/items/${ID}/studio`)).toMatchObject({ status: 404 });
        expect(g("DELETE", `/library/items/${ID}/file`)).toMatchObject({ status: 404 });
        expect(g("GET", `/library/items/${ID}`)).toMatchObject({ status: 404 });
        expect(g("GET", `/library/items/${ID}/other`)).toMatchObject({ status: 404 });
        expect(g("GET", `/library/items/${ID}/file/x`)).toMatchObject({ status: 404 });
        expect(g("GET", "/library/items")).toMatchObject({ status: 404 });
        expect(g("GET", "/library/nope")).toMatchObject({ status: 404 });
    });
    it("/library/adopt stays service only, whatever else /library opened", () => {
        expect(g("POST", "/library/adopt", { service: true })).toEqual({ action: "service", then: "library_adopt" });
        expect(g("POST", "/library/adopt")).toMatchObject({ status: 401 });
        expect(g("POST", "/library/adopt", { authorization: `Api-Key ${KEY}`, origin: ORIGIN })).toMatchObject({ status: 401 });
        expect(g("GET", "/library/adopt")).toMatchObject({ status: 404 });
    });
});

// ---- Live Activity push (APP-API-CONTRACT.md section 8.2) ------------------------------------

describe("/live routes: keyed, and nothing else", () => {
    const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const keyed: Partial<GateRequest> = { authorization: `Api-Key ${KEY}` };
    const g = (method: string, pathname: string, o: Partial<GateRequest> = keyed) => decide(req({ method, pathname, ...o }), cfg);
    const routes: [string, string, string][] = [
        ["PUT", "/live/start-token", "live_start_token"],
        ["DELETE", "/live/start-token", "live_start_token"],
        ["PUT", `/live/runs/${RUN}`, "live_run"],
        ["DELETE", `/live/runs/${RUN}`, "live_run"],
        ["POST", `/live/runs/${RUN}/state`, "live_state"],
        ["GET", "/live/selftest", "live_selftest"],
    ];

    it.each(routes)("%s %s with a key is a lookup for %s", (method, pathname, then) => {
        expect(g(method, pathname)).toEqual({ action: "lookup", key: KEY, then });
    });
    it.each(routes)("%s %s without a key, or with a malformed or wrong-type one, is a 401", (method, pathname) => {
        expect(g(method, pathname, {})).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
        expect(g(method, pathname, { authorization: "Api-Key nope" })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.invalid" });
        expect(g(method, pathname, { authorization: `Bearer ${KEY}` })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.not_api_key" });
    });
    it.each(routes)("%s %s from the library service is a 404 (one key per device)", (method, pathname) => {
        expect(g(method, pathname, { service: true })).toEqual({ action: "reject", status: 404, errorCode: undefined });
        expect(g(method, pathname, { service: true, authorization: `Api-Key ${KEY}` })).toMatchObject({ status: 404 });
    });
    it("a web origin changes nothing: no CORS, no preflight (OPTIONS is a 404 even from the web origin)", () => {
        expect(g("PUT", "/live/start-token", { ...keyed, origin: ORIGIN })).toMatchObject({ action: "lookup" });
        for (const p of ["/live/start-token", `/live/runs/${RUN}`, "/live/selftest"]) {
            expect(g("OPTIONS", p, { origin: ORIGIN })).toMatchObject({ action: "reject", status: 404 });
            expect(g("OPTIONS", p, { origin: "https://evil.example" })).toMatchObject({ action: "reject", status: 404 });
        }
    });
    it("wrong methods are a 404, with or without a key", () => {
        for (const [method, pathname] of [
            ["GET", "/live/start-token"], ["POST", "/live/start-token"], ["PATCH", "/live/start-token"],
            ["GET", `/live/runs/${RUN}`], ["POST", `/live/runs/${RUN}`], ["PATCH", `/live/runs/${RUN}`],
            ["PUT", `/live/runs/${RUN}/state`], ["GET", `/live/runs/${RUN}/state`], ["DELETE", `/live/runs/${RUN}/state`],
            ["POST", "/live/selftest"], ["PUT", "/live/selftest"], ["DELETE", "/live/selftest"], ["HEAD", "/live/selftest"],
        ]) {
            expect(g(method!, pathname!), `${method} ${pathname}`).toMatchObject({ action: "reject", status: 404 });
            expect(g(method!, pathname!, {}), `${method} ${pathname} (no key)`).toMatchObject({ action: "reject", status: 404 });
        }
    });
    it("bad run ids are a 404 before any lookup: not a uuid, uppercase, extra segments", () => {
        for (const id of ["", "x", "not-a-uuid", RUN.toUpperCase(), RUN + "0", RUN.slice(1), `${RUN}/`, "..%2Fstudio", RUN.replace(/-/g, "")]) {
            expect(g("PUT", `/live/runs/${id}`), id).toMatchObject({ action: "reject", status: 404 });
            expect(g("POST", `/live/runs/${id}/state`), id).toMatchObject({ action: "reject", status: 404 });
        }
        expect(g("PUT", `/live/runs/${RUN}/state/x`)).toMatchObject({ status: 404 });
        expect(g("POST", `/live/runs/${RUN}/other`)).toMatchObject({ status: 404 });
    });
    it("everything else under /live is a 404, keyed or not", () => {
        for (const p of ["/live", "/live/", "/live/runs", "/live/runs/", "/live/start-token/", "/live/selftest/", "/live/other", "/livex", "/live2/selftest"]) {
            expect(g("GET", p), p).toMatchObject({ action: "reject", status: 404 });
            expect(g("PUT", p), p).toMatchObject({ action: "reject", status: 404 });
        }
    });
});
