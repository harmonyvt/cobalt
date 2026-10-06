// The gate's rules for the routes of section 18 (APP-API-CONTRACT.md): what each path and method decides, the
// library service credential's reach, and that nothing new opens under a path the gate answered 404 before.
import { describe, expect, it } from "vitest";
import { decide, type GateRequest } from "../src/gate";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
const ITEM = "Abcdefghij012345";
const cfg = { corsUrl: "https://cobalt.capybaraharmony.com", now: 1_800_000_000_000 };
const req = (method: string, pathname: string, o: Partial<GateRequest> = {}): GateRequest => ({
    method,
    pathname,
    searchParams: new URLSearchParams(),
    origin: null,
    authorization: `Api-Key ${KEY}`,
    ...o,
});
const d = (method: string, pathname: string, o: Partial<GateRequest> = {}) => decide(req(method, pathname, o), cfg);
const rejected = (x: unknown) => expect(x).toEqual({ action: "reject", status: 404, errorCode: undefined });

describe("DELETE /library/items/<id> (one item or made file)", () => {
    it("keyed, or the service; the bare path only", () => {
        expect(d("DELETE", `/library/items/${ITEM}`)).toEqual({ action: "lookup", key: KEY, then: "library_item_delete", params: { id: ITEM } });
        expect(d("DELETE", `/library/items/${ITEM}`, { service: true, authorization: null })).toEqual({ action: "service", then: "library_item_delete", params: { id: ITEM } });
        expect(d("DELETE", `/library/items/${ITEM}`, { authorization: null })).toMatchObject({ action: "reject", status: 401 });
    });
    it("the other methods on the bare path, a bad id and a longer path stay 404", () => {
        for (const m of ["GET", "HEAD", "POST", "PUT", "PATCH"]) rejected(d(m, `/library/items/${ITEM}`));
        rejected(d("DELETE", "/library/items/short"));
        rejected(d("DELETE", `/library/items/${ITEM}/other`));
        rejected(d("DELETE", `/library/items/${ITEM}/file`));
        rejected(d("DELETE", `/library/items/${ITEM}/made`));
    });
    it("DELETE .../post is still the post delete", () => {
        expect(d("DELETE", `/library/items/${ITEM}/post`)).toMatchObject({ then: "library_post_delete" });
    });
});

describe("PUT /library/items/<id>/made", () => {
    it("PUT only, keyed or the service", () => {
        expect(d("PUT", `/library/items/${ITEM}/made`)).toEqual({ action: "lookup", key: KEY, then: "library_made", params: { id: ITEM } });
        expect(d("PUT", `/library/items/${ITEM}/made`, { service: true, authorization: null })).toMatchObject({ action: "service", then: "library_made" });
        expect(d("PUT", `/library/items/${ITEM}/made`, { authorization: null })).toMatchObject({ status: 401 });
        for (const m of ["GET", "HEAD", "POST", "PATCH", "DELETE"]) rejected(d(m, `/library/items/${ITEM}/made`));
        rejected(d("PUT", `/library/items/${ITEM}/made/x`));
        rejected(d("PUT", `/library/items/short/made`));
    });
});

describe("POST /studio/<sid>/slideshow and /items/retry", () => {
    it("keyed POST; the library service never reaches them; ids are checked", () => {
        expect(d("POST", `/studio/${SID}/slideshow`)).toEqual({ action: "lookup", key: KEY, then: "studio_slideshow", params: { sid: SID } });
        expect(d("POST", `/studio/${SID}/items/retry`)).toEqual({ action: "lookup", key: KEY, then: "studio_items_retry", params: { sid: SID } });
        for (const p of [`/studio/${SID}/slideshow`, `/studio/${SID}/items/retry`]) {
            rejected(d("POST", p, { service: true, authorization: null }));
            expect(d("POST", p, { authorization: null })).toMatchObject({ status: 401 });
            for (const m of ["GET", "PUT", "PATCH", "DELETE"]) rejected(d(m, p));
        }
        rejected(d("POST", `/studio/short/slideshow`));
        rejected(d("POST", `/studio/${SID}/items`));
        rejected(d("POST", `/studio/${SID}/items/other`));
        rejected(d("POST", `/studio/${SID}/items/retry/x`));
        rejected(d("POST", `/studio/${SID}/slideshow/x`));
    });
});
