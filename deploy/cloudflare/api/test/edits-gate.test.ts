// The gate's /edits block (APP-API-CONTRACT.md section 31.13): every route is keyed, the library-service credential and
// everything else is a 404, ids are checked before anything is looked up.
import { describe, expect, it } from "vitest";
import { decide, type GateRequest } from "../src/gate";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const ORIGIN = "https://cobalt.capybaraharmony.com";
const cfg = { corsUrl: ORIGIN, now: 1_800_000_000_000 };
const PID = "Ab3dEf6hIj9kLm2n"; // 16
const RID = "Rq7sTu0vWx3yZa6bCd9e"; // 20
const auth = `Api-Key ${KEY}`;

const g = (method: string, pathname: string, o: Partial<GateRequest> = {}) =>
    decide({ method, pathname, searchParams: new URLSearchParams(), origin: null, authorization: auth, ...o }, cfg);
const lookup = (then: string, params?: Record<string, string>) => ({ action: "lookup", key: KEY, then, ...(params ? { params } : {}) });
const notFound = { action: "reject", status: 404, errorCode: undefined };

describe("the /edits gate", () => {
    it("maps every route and method to its op", () => {
        expect(g("GET", "/edits")).toEqual(lookup("edits_list"));
        expect(g("POST", "/edits")).toEqual(lookup("edits_create"));
        expect(g("GET", `/edits/${PID}`)).toEqual(lookup("edits_get", { id: PID }));
        expect(g("PUT", `/edits/${PID}`)).toEqual(lookup("edits_update", { id: PID }));
        expect(g("PATCH", `/edits/${PID}`)).toEqual(lookup("edits_rename", { id: PID }));
        expect(g("DELETE", `/edits/${PID}`)).toEqual(lookup("edits_delete", { id: PID }));
        expect(g("POST", `/edits/${PID}/render`)).toEqual(lookup("edits_render", { id: PID }));
        expect(g("GET", "/edits/renders")).toEqual(lookup("edits_renders"));
        expect(g("GET", `/edits/renders/${RID}`)).toEqual(lookup("edits_render_get", { rid: RID }));
        expect(g("DELETE", `/edits/renders/${RID}`)).toEqual(lookup("edits_render_cancel", { rid: RID }));
    });

    it("any other method is a 404, not a 405 and not a lookup", () => {
        for (const [m, p] of [
            ["DELETE", "/edits"],
            ["PUT", "/edits"],
            ["PATCH", "/edits"],
            ["POST", `/edits/${PID}`],
            ["GET", `/edits/${PID}/render`],
            ["PUT", `/edits/${PID}/render`],
            ["DELETE", `/edits/${PID}/render`],
            ["POST", "/edits/renders"],
            ["DELETE", "/edits/renders"],
            ["PUT", `/edits/renders/${RID}`],
            ["POST", `/edits/renders/${RID}`],
            ["PATCH", `/edits/renders/${RID}`],
            ["HEAD", "/edits"],
        ] as const) {
            expect(g(m, p), `${m} ${p}`).toEqual(notFound);
        }
    });

    it("ids are checked before anything is looked up; `renders` is never a project id", () => {
        for (const p of [
            "/edits/short",
            `/edits/${PID}x`,
            `/edits/${PID.slice(1)}`,
            `/edits/${PID.replace("A", "_")}`,
            "/edits/render",
            "/edits/Renders",
            `/edits/renders/${RID.slice(1)}`,
            `/edits/renders/${RID}x`,
            `/edits/renders/${PID}`, // a project id is not a render id
            `/edits/${RID}`, // a render id is not a project id
            `/edits/${PID}/renders`,
            `/edits/${PID}/render/extra`,
            `/edits/${PID}/`,
            "/edits/",
            `/edits/renders/${RID}/x`,
            "/editsx",
            "/edits/%2e%2e",
        ]) {
            expect(g("GET", p), p).toEqual(notFound);
            expect(g("DELETE", p), p).toEqual(notFound);
            expect(g("POST", p), p).toEqual(notFound);
        }
    });

    it("the library-service credential gets a 404 on every route", () => {
        for (const [m, p] of [
            ["GET", "/edits"],
            ["POST", "/edits"],
            ["GET", `/edits/${PID}`],
            ["PUT", `/edits/${PID}`],
            ["PATCH", `/edits/${PID}`],
            ["DELETE", `/edits/${PID}`],
            ["POST", `/edits/${PID}/render`],
            ["GET", "/edits/renders"],
            ["GET", `/edits/renders/${RID}`],
            ["DELETE", `/edits/renders/${RID}`],
        ] as const) {
            expect(g(m, p, { service: true, authorization: null }), `${m} ${p}`).toEqual(notFound);
        }
    });

    it("a missing or malformed key is a 401 with cobalt's codes", () => {
        expect(g("GET", "/edits", { authorization: null })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
        expect(g("GET", "/edits", { authorization: "Bearer x" })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.not_api_key" });
        expect(g("GET", `/edits/${PID}`, { authorization: "Api-Key nope" })).toEqual({ action: "reject", status: 401, errorCode: "error.api.auth.key.invalid" });
    });

    it("has no CORS: a preflight from the web origin is not answered by the studio path and an Origin changes nothing", () => {
        expect(g("GET", "/edits", { origin: ORIGIN })).toEqual(lookup("edits_list"));
        expect(g("GET", "/edits", { origin: "https://evil.example" })).toEqual(lookup("edits_list"));
        expect(g("OPTIONS", "/edits", { origin: "https://evil.example" })).toEqual({ action: "reject", status: 403, errorCode: undefined });
    });
});
