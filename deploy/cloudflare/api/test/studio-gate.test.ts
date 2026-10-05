import { describe, expect, it } from "vitest";
import { decide, isStudioPath, type GateRequest } from "../src/gate";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const ORIGIN = "https://cobalt.capybaraharmony.com";
const cfg = { corsUrl: ORIGIN, now: 1_800_000_000_000 };
const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
const JOB = "aB3dE6gH9jK2mN5pQ8sT";

const req = (o: Partial<GateRequest>): GateRequest => ({
    method: "GET",
    pathname: "/",
    searchParams: new URLSearchParams(),
    origin: null,
    authorization: null,
    ...o,
});
const d = (o: Partial<GateRequest>) => decide(req(o), cfg);
const notFound = { action: "reject", status: 404 };

describe("isStudioPath", () => {
    it("matches /studio and /studio/..., nothing that merely starts with the word", () => {
        expect(isStudioPath("/studio")).toBe(true);
        expect(isStudioPath(`/studio/${SID}`)).toBe(true);
        expect(isStudioPath("/studios")).toBe(false);
        expect(isStudioPath("/studio-x/a")).toBe(false);
        expect(isStudioPath("/webp/x")).toBe(false);
    });
});

describe("POST /studio (needs a key)", () => {
    it("looks the key up, then creates", () => {
        expect(d({ method: "POST", pathname: "/studio", authorization: `Api-Key ${KEY}` })).toEqual({
            action: "lookup",
            key: KEY,
            then: "studio_create",
        });
    });
    it("401s like POST / without a well-formed key", () => {
        const post = (authorization: string | null) => d({ method: "POST", pathname: "/studio", authorization });
        expect(post(null)).toMatchObject({ status: 401, errorCode: "error.api.auth.key.missing" });
        expect(post("Bearer x")).toMatchObject({ status: 401, errorCode: "error.api.auth.key.not_api_key" });
        expect(post("Api-Key nope")).toMatchObject({ status: 401, errorCode: "error.api.auth.key.invalid" });
    });
    it("an Origin does not substitute for a key", () => {
        expect(d({ method: "POST", pathname: "/studio", origin: ORIGIN })).toMatchObject({ status: 401 });
    });
    it("only POST: GET, PUT, DELETE /studio are 404", () => {
        for (const method of ["GET", "PUT", "DELETE", "HEAD"]) {
            expect(d({ method, pathname: "/studio", authorization: `Api-Key ${KEY}` })).toMatchObject(notFound);
        }
    });
});

describe("routes that need no key (the id is the credential)", () => {
    it("GET /studio/<sid> is the status route", () => {
        expect(d({ pathname: `/studio/${SID}` })).toEqual({ action: "studio", op: "status", sid: SID });
    });
    it("GET and HEAD /studio/<sid>/source", () => {
        expect(d({ pathname: `/studio/${SID}/source` })).toEqual({ action: "studio", op: "source", sid: SID });
        expect(d({ method: "HEAD", pathname: `/studio/${SID}/source` })).toEqual({ action: "studio", op: "source", sid: SID });
    });
    it("POST /studio/<sid>/render", () => {
        expect(d({ method: "POST", pathname: `/studio/${SID}/render` })).toEqual({ action: "studio", op: "render_create", sid: SID });
    });
    it("GET /studio/<sid>/render/<job>", () => {
        expect(d({ pathname: `/studio/${SID}/render/${JOB}` })).toEqual({ action: "studio", op: "render_status", sid: SID, job: JOB });
    });
    it("the query (wait) is not part of the decision", () => {
        expect(d({ pathname: `/studio/${SID}`, searchParams: new URLSearchParams("wait=20") })).toMatchObject({ op: "status" });
    });
    it("an Authorization header is neither needed nor used", () => {
        expect(d({ pathname: `/studio/${SID}`, authorization: "Api-Key junk" })).toMatchObject({ action: "studio" });
    });
});

describe("ids are validated before anything is looked up", () => {
    it.each([
        "/studio/",
        "/studio/short",
        `/studio/${"a".repeat(21)}`,
        `/studio/${"a".repeat(23)}`,
        `/studio/${SID.slice(0, 21)}-`,
        `/studio/..%2f${SID}`,
        `/studio/${SID}/`,
        `/studio/${SID}/source/`,
        `/studio/${SID}/source/x`,
        `/studio/${SID}/render/`,
        `/studio/${SID}/render/short`,
        `/studio/${SID}/render/${"a".repeat(21)}`,
        `/studio/${SID}/render/${JOB}/x`,
        `/studio/${SID}/other`,
        // the DO's internal save-advance route is never public
        `/studio/${SID}/advance`,
        `/studio/${SID}/advance/x`,
        `/studio/${SID}/render/${JOB}.json`,
    ])("404 %s", (p) => {
        expect(d({ pathname: p })).toMatchObject(notFound);
        expect(d({ method: "POST", pathname: p })).toMatchObject(notFound);
    });
});

describe("methods", () => {
    it.each([
        ["POST", `/studio/${SID}`],
        ["DELETE", `/studio/${SID}`],
        ["POST", `/studio/${SID}/source`],
        ["GET", `/studio/${SID}/render`],
        ["PUT", `/studio/${SID}/render`],
        ["POST", `/studio/${SID}/render/${JOB}`],
        ["DELETE", `/studio/${SID}/render/${JOB}`],
        ["HEAD", `/studio/${SID}`],
    ])("%s %s is a 404", (method, pathname) => {
        expect(d({ method, pathname })).toMatchObject(notFound);
    });
});

describe("OPTIONS preflight", () => {
    it("studio paths from the web origin are answered by the Worker, not forwarded", () => {
        for (const pathname of ["/studio", `/studio/${SID}`, `/studio/${SID}/source`, `/studio/${SID}/render`, `/studio/${SID}/render/${JOB}`]) {
            expect(d({ method: "OPTIONS", pathname, origin: ORIGIN })).toEqual({ action: "studio", op: "preflight" });
        }
    });
    it("other origins and no origin are 403", () => {
        expect(d({ method: "OPTIONS", pathname: `/studio/${SID}`, origin: "https://evil.example" })).toMatchObject({ action: "reject", status: 403 });
        expect(d({ method: "OPTIONS", pathname: "/studio" })).toMatchObject({ action: "reject", status: 403 });
    });
    it("non-studio OPTIONS is still forwarded from the web origin", () => {
        expect(d({ method: "OPTIONS", pathname: "/", origin: ORIGIN })).toEqual({ action: "forward" });
        expect(d({ method: "OPTIONS", pathname: "/webp", origin: ORIGIN })).toEqual({ action: "forward" });
    });
});

describe("PUT /studio/upload (keyed) and the internal adopt path", () => {
    const put = (o: Partial<GateRequest> = {}) =>
        d({ method: "PUT", pathname: "/studio/upload", authorization: `Api-Key ${KEY}`, ...o });

    it("PUT looks the key up, then uploads: checked before the session id format", () => {
        expect(put()).toEqual({ action: "lookup", key: KEY, then: "studio_upload" });
        expect(put({ service: true, authorization: null })).toEqual({ action: "service", then: "studio_upload" });
    });
    it("401s like the other keyed routes without a well-formed key", () => {
        expect(put({ authorization: null })).toMatchObject({ status: 401, errorCode: "error.api.auth.key.missing" });
        expect(put({ authorization: "Bearer x" })).toMatchObject({ status: 401, errorCode: "error.api.auth.key.not_api_key" });
        expect(put({ authorization: "Api-Key nope" })).toMatchObject({ status: 401, errorCode: "error.api.auth.key.invalid" });
        expect(put({ authorization: null, origin: ORIGIN })).toMatchObject({ status: 401 });
    });
    it("any other method is 404 (GET, POST, DELETE, HEAD)", () => {
        for (const method of ["GET", "POST", "DELETE", "HEAD"]) {
            expect(put({ method })).toMatchObject(notFound);
        }
    });
    it("/studio/upload/adopt is internal: 404 for every method and credential from outside", () => {
        for (const method of ["GET", "POST", "PUT", "DELETE"]) {
            for (const o of [{}, { authorization: `Api-Key ${KEY}` }, { service: true }, { origin: ORIGIN }]) {
                expect(d({ method, pathname: "/studio/upload/adopt", ...o })).toMatchObject(notFound);
            }
        }
    });
    it("other shapes under /studio/upload stay 404", () => {
        expect(put({ pathname: "/studio/upload/" })).toMatchObject(notFound);
        expect(put({ pathname: "/studio/upload/x" })).toMatchObject(notFound);
        expect(put({ pathname: "/studio/uploads" })).toMatchObject(notFound);
    });
    it("an upload does not open the session routes: a 22-char sid still works exactly as before", () => {
        expect(d({ pathname: `/studio/${SID}` })).toEqual({ action: "studio", op: "status", sid: SID });
        expect(d({ method: "PUT", pathname: `/studio/${SID}`, authorization: `Api-Key ${KEY}` })).toMatchObject(notFound);
    });
    it("OPTIONS /studio/upload is a studio preflight (harmless: the Worker answers it)", () => {
        expect(d({ method: "OPTIONS", pathname: "/studio/upload", origin: ORIGIN })).toEqual({ action: "studio", op: "preflight" });
        expect(d({ method: "OPTIONS", pathname: "/studio/upload" })).toMatchObject({ status: 403 });
    });
});

// ---- Hark notification opt-in (APP-API-CONTRACT.md section 9) ------------------------------

describe("PUT|DELETE /studio/<sid>/notify (keyed, owner checked by the Durable Object)", () => {
    const keyed = { authorization: `Api-Key ${KEY}` };
    const pathname = `/studio/${SID}/notify`;

    it.each(["PUT", "DELETE"])("%s with a key is a lookup for studio_notify carrying the sid", (method) => {
        expect(d({ method, pathname, ...keyed })).toEqual({ action: "lookup", key: KEY, then: "studio_notify", params: { sid: SID } });
    });
    it.each(["PUT", "DELETE"])("%s without a key, or a malformed one, is a 401", (method) => {
        expect(d({ method, pathname })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
        expect(d({ method, pathname, authorization: "Api-Key nope" })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.invalid" });
    });
    it.each(["PUT", "DELETE"])("%s from the library service credential is a 404 (the owner's key only)", (method) => {
        expect(d({ method, pathname, service: true })).toMatchObject(notFound);
        expect(d({ method, pathname, service: true, ...keyed })).toMatchObject(notFound);
    });
    it("other methods, extra segments and bad session ids are 404s", () => {
        for (const method of ["GET", "POST", "PATCH", "HEAD"]) {
            expect(d({ method, pathname, ...keyed }), method).toMatchObject(notFound);
        }
        expect(d({ method: "PUT", pathname: `${pathname}/x`, ...keyed })).toMatchObject(notFound);
        expect(d({ method: "PUT", pathname: `${pathname}/${JOB}`, ...keyed })).toMatchObject(notFound);
        expect(d({ method: "PUT", pathname: "/studio/short/notify", ...keyed })).toMatchObject(notFound);
        expect(d({ method: "PUT", pathname: `/studio/${SID}x/notify`, ...keyed })).toMatchObject(notFound);
    });
    it("the render route is untouched: still the capability URL, no key", () => {
        expect(d({ method: "POST", pathname: `/studio/${SID}/render` })).toEqual({ action: "studio", op: "render_create", sid: SID });
    });
});
