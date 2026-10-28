// The /edits routes (APP-API-CONTRACT.md sections 31.13, 33.8): ops in the registry (src/registry/ops/make.ts), keyed, no
// CORS, no-store. The registry matches whole segments and checks ids; anything it does not match falls through to the
// gate, which answers 404 for every /edits path. The answers per caller (401 codes, the service's 404) are pinned by the
// route snapshot (test/route-snapshot.test.ts).
import { describe, expect, it } from "vitest";
import { decide, type GateRequest } from "../src/gate";
import { REGISTRY } from "../src/registry/index";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const ORIGIN = "https://cobalt.capybaraharmony.com";
const cfg = { corsUrl: ORIGIN, now: 1_800_000_000_000 };
const PID = "Ab3dEf6hIj9kLm2n"; // 16
const RID = "Rq7sTu0vWx3yZa6bCd9e"; // 20
const auth = `Api-Key ${KEY}`;

const g = (method: string, pathname: string, o: Partial<GateRequest> = {}) =>
    decide({ method, pathname, searchParams: new URLSearchParams(), origin: null, authorization: auth, ...o }, cfg);
const notFound = { action: "reject", status: 404, errorCode: undefined };
const m = (method: string, path: string) => REGISTRY.match(method, path);

describe("the /edits routes", () => {
    it("maps every route and method to its op", () => {
        const want: [string, string, string, Record<string, string>][] = [
            ["GET", "/edits", "edits.route.list", {}],
            ["POST", "/edits", "edits.route.create", {}],
            ["GET", `/edits/${PID}`, "edits.route.get", { id: PID }],
            ["PUT", `/edits/${PID}`, "edits.route.update", { id: PID }],
            ["PATCH", `/edits/${PID}`, "edits.route.rename", { id: PID }],
            ["DELETE", `/edits/${PID}`, "edits.route.delete", { id: PID }],
            ["POST", `/edits/${PID}/render`, "edits.route.render", { id: PID }],
            ["GET", "/edits/renders", "edits.route.renders", {}],
            ["GET", `/edits/renders/${RID}`, "edits.route.render_get", { rid: RID }],
            ["DELETE", `/edits/renders/${RID}`, "edits.route.render_cancel", { rid: RID }],
        ];
        for (const [method, path, name, params] of want) {
            const hit = m(method, path);
            expect(hit?.op, `${method} ${path}`).toMatchObject({ name, auth: "key", cors: false, noStore: true });
            expect(hit?.params).toEqual(params);
            expect(hit?.op.ai.tier).toBe("hidden");
            // the gate no longer knows them: what the registry does not match is its 404
            expect(g(method, path)).toEqual(notFound);
        }
    });

    it("any other method is no match, so the gate's 404", () => {
        for (const [method, p] of [
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
            expect(m(method, p), `${method} ${p}`).toBeNull();
            expect(g(method, p), `${method} ${p}`).toEqual(notFound);
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
            for (const method of ["GET", "DELETE", "POST"]) {
                expect(m(method, p), `${method} ${p}`).toBeNull();
                expect(g(method, p), p).toEqual(notFound);
            }
        }
    });

    it("a preflight is still the gate's: a wrong origin is a 403", () => {
        expect(g("OPTIONS", "/edits", { origin: "https://evil.example" })).toEqual({ action: "reject", status: 403, errorCode: undefined });
    });
});
