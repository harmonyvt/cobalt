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
