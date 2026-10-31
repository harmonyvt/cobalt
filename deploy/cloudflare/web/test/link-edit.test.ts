// Editing a gallery link's files (APP-API-CONTRACT.md section 41): PATCH /api/library/links/<id> on the web
// Worker and the pure parts of the links view's editor in page.html.
import { readFileSync } from "node:fs";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { API_BASE, handleLibrary, matchRoute } from "../src/library";
import { LIBRARY_HTML } from "../src/library/page.generated";
import type { Env } from "../src/keys";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const SERVICE_KEY = "7a1d1b0e-3f0c-4a53-8f55-2f1b8a9d0c11";
const SET = "1234567890123456789";
const ROUTE = `/api/library/links/${SET}`;

type ApiCall = { url: string; method: string; headers: Record<string, string>; body: unknown };
let signer: Signer;
let token: string;
let apiCalls: ApiCall[];
let apiReply: () => Response;
let apiThrows: boolean;
let env: Env;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});
const jsonRes = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
beforeEach(() => {
    apiCalls = [];
    apiThrows = false;
    apiReply = () => jsonRes(200, { status: "success" });
    env = {
        DB: createFakeD1(),
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        API: {
            fetch: async (req: Request) => {
                if (apiThrows) throw new Error("service binding down");
                const headers: Record<string, string> = {};
                req.headers.forEach((v, k) => (headers[k] = v));
                const text = await req.text();
                apiCalls.push({ url: req.url, method: req.method, headers, body: text ? JSON.parse(text) : undefined });
                return apiReply();
            },
        } as unknown as Fetcher,
        COBALT_API_KEY: SERVICE_KEY,
    } as unknown as Env;
});
function call(method: string, path: string, o: { token?: string | null; origin?: string | null; body?: unknown; raw?: string; contentType?: string | null } = {}) {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    if (o.origin !== null && method !== "GET") headers.set("Origin", o.origin ?? WEB_ORIGIN);
    let body: string | undefined;
    if (o.raw !== undefined) body = o.raw;
    else if (o.body !== undefined) body = JSON.stringify(o.body);
    if (method === "GET") body = undefined;
    if (body !== undefined && o.contentType !== null) headers.set("content-type", o.contentType ?? "application/json");
    return handleLibrary(new Request(`https://cobalt.capybaraharmony.com${path}`, { method, headers, body }), env, {
        jwks: newCache(makeJwksFetch(() => [signer]).fetchFn),
        now: () => NOW,
    });
}
const json = async (r: Response) => JSON.parse(await r.text());

const A = "aaaaaaaaaaaaaaaa", B = "bbbbbbbbbbbbbbbb", C = "cccccccccccccccc";
const SHARE = `https://share.capybaraharmony.com/g/${SET}`;
const aSet = (items: string[], over: Record<string, unknown> = {}) => ({
    id: SET, url: SHARE, title: null, created_at: NOW, private: false, items: items.map((id) => ({ id, url: `https://media.capybaraharmony.com/${id}.webp`, content_type: "image/webp", poster_url: null, width: 1, height: 1, duration: null })), ...over,
});

describe("PATCH /api/library/links/<id>", () => {
    it("matchRoute: only a 19 digit id is the editor; the list and other shapes stay as they were", () => {
        expect(matchRoute(ROUTE)).toEqual({ name: "linkEdit", id: SET });
        expect(matchRoute("/api/library/links")).toEqual({ name: "links" });
        for (const bad of ["/api/library/links/", "/api/library/links/12345", `/api/library/links/${SET}0`, "/api/library/links/abcdefghijklmnopqrs", `${ROUTE}/x`]) {
            expect(matchRoute(bad)).toBeNull();
        }
    });
    it("other methods are 405 with allow: PATCH", async () => {
        for (const method of ["GET", "POST", "PUT", "DELETE"]) {
            const r = await call(method, ROUTE, { body: {} });
            expect(r.status).toBe(405);
            expect(r.headers.get("allow")).toBe("PATCH");
        }
        expect(apiCalls).toEqual([]);
    });
    it("needs the Access JWT (401) and the web origin (403), and calls nothing without them", async () => {
        expect((await call("PATCH", ROUTE, { token: null, body: { items: [A, B] } })).status).toBe(401);
        for (const origin of [null, "https://evil.example"]) expect((await call("PATCH", ROUTE, { origin, body: { items: [A, B] } })).status).toBe(403);
        expect(apiCalls).toEqual([]);
    });
    it("relays the body to PATCH /share/sets/<id> with the service credential only, and answers 200 with the set", async () => {
        const set = aSet([B, A, C], { title: "memes" });
        apiReply = () => jsonRes(200, { status: "success", set });
        const body = { items: [B, A, C], title: "memes", expect: [A, B] };
        const r = await call("PATCH", ROUTE, { body });
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(await json(r)).toEqual({ status: "success", set });
        expect(apiCalls).toHaveLength(1);
        expect(apiCalls[0]).toMatchObject({ method: "PATCH", url: `${API_BASE}/share/sets/${SET}`, body });
        expect(apiCalls[0]!.headers["x-cobalt-service"]).toBe(SERVICE_KEY);
        for (const h of ["authorization", "cookie", "cf-access-jwt-assertion", "origin"]) expect(apiCalls[0]!.headers[h]).toBeUndefined();
    });
    it("a title-only body and a cleared title (\"\") go through unchanged", async () => {
        apiReply = () => jsonRes(200, { status: "success", set: aSet([A, B]) });
        await call("PATCH", ROUTE, { body: { title: "" } });
        await call("PATCH", ROUTE, { body: { title: null, expect: [A, B] } });
        expect(apiCalls.map((c) => c.body)).toEqual([{ title: "" }, { title: null, expect: [A, B] }]);
    });
    it("409 error.share.changed keeps its status and the current set", async () => {
        const set = aSet([C, A]);
        apiReply = () => jsonRes(409, { status: "error", error: { code: "error.share.changed" }, set });
        const r = await call("PATCH", ROUTE, { body: { items: [A, B], expect: [A, B] } });
        expect(r.status).toBe(409);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.share.changed" }, set });
    });
    it("passes the API's other refusals through with their extra fields (not_public items, hidden ids, bad_request, not_found)", async () => {
        for (const [status, body] of [
            [409, { status: "error", error: { code: "error.share.not_public" }, items: [C] }],
            [409, { status: "error", error: { code: "error.hidden" }, ids: [C] }],
            [400, { status: "error", error: { code: "error.share.bad_request" } }],
            [404, { status: "error", error: { code: "error.share.not_found" } }],
            [404, { status: "error", error: { code: "error.share.off" } }],
        ] as const) {
            apiReply = () => jsonRes(status, body);
            const r = await call("PATCH", ROUTE, { body: { items: [A, B, C] } });
            expect(r.status).toBe(status);
            expect(await json(r)).toEqual(body);
        }
    });
    it("an upstream 401/403 (wrong service key), a downed API and a missing key are 502 and never look like an expired login", async () => {
        apiReply = () => jsonRes(403, { status: "error", error: { code: "error.api.unauthorized" } });
        expect((await call("PATCH", ROUTE, { body: { title: "x" } })).status).toBe(502);
        apiReply = () => jsonRes(401, { status: "error", error: { code: "error.api.unauthorized" } });
        expect((await call("PATCH", ROUTE, { body: { title: "x" } })).status).toBe(502);
        apiReply = () => new Response("<html>", { status: 200 });
        expect((await call("PATCH", ROUTE, { body: { title: "x" } })).status).toBe(502);
        apiThrows = true;
        expect((await call("PATCH", ROUTE, { body: { title: "x" } })).status).toBe(502);
        apiThrows = false;
        (env as any).COBALT_API_KEY = "";
        apiCalls = [];
        expect((await call("PATCH", ROUTE, { body: { title: "x" } })).status).toBe(502);
        expect(apiCalls).toEqual([]);
    });
    it("a body that is not a JSON object (wrong type, array, invalid, too big) is 400 and calls nothing", async () => {
        const bad = [
            await call("PATCH", ROUTE, { raw: "{}", contentType: "text/plain" }),
            await call("PATCH", ROUTE, { raw: "[1,2]" }),
            await call("PATCH", ROUTE, { raw: "{nope" }),
            await call("PATCH", ROUTE, { body: { title: "x".repeat(9000) } }),
            await call("PATCH", ROUTE, { contentType: null }),
        ];
        for (const r of bad) {
            expect(r.status).toBe(400);
            expect((await json(r)).error.code).toBe("error.library.bad_request");
        }
        expect(apiCalls).toEqual([]);
    });
});

// ---------- the page ----------

describe("embedded page: link editor", () => {
    const html = readFileSync(new URL("../src/library/page.html", import.meta.url), "utf8");
    const src = html.slice(html.indexOf("var LINK_MAX"), html.indexOf("function leToast"));
    const isPubSrc = html.slice(html.indexOf("function isPub(it) {"), html.indexOf("function confirmText("));
    const fn = new Function("isVideoType", "fmtElapsed", `${isPubSrc}\n${src}\nreturn { linkDiff, diffText, moveFile, fileNotShown, fileKind, pickCandidates, sameIds, LINK_ERRORS };`) as any;
    const f = fn((t: string) => !!t && t.startsWith("video/"), (ms: number) => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}`);
    const files = (...ids: string[]) => ids.map((id) => ({ id }));

    it("ships the editor: dialogs, the PATCH relay path, drag and keyboard moves, the discard dialog", () => {
        for (const t of ['id="linkDlg"', 'id="pickDlg"', 'id="discardDlg"', "discard changes?", '"/api/library/links/" + id', 'method: "PATCH"', "no title: the ai caption is used", "a link needs 2 files. revoke it instead", "private: only in private links", '"dragstart"', "ev.altKey"]) {
            expect(LIBRARY_HTML).toContain(t);
        }
        expect(LIBRARY_HTML).not.toContain("window.confirm");
    });
    it("linkDiff counts added, out, order and title; diffText reads like the mockup", () => {
        expect(f.linkDiff(files("a", "b"), files("a", "b"), null, "").dirty).toBe(false);
        const d = f.linkDiff(files("a", "b", "c"), files("c", "a", "x", "y"), "old", "new");
        expect(d).toMatchObject({ added: 2, out: 1, reordered: true, retitled: true, files: true, dirty: true });
        expect(f.diffText(d)).toBe("2 added · 1 out · new order · new title");
        expect(f.diffText(f.linkDiff(files("a", "b"), files("a", "b"), "t", "t"))).toBe("no changes");
        // taking one out does not count as a new order; a swap does
        expect(f.linkDiff(files("a", "b", "c"), files("a", "c"), null, "")).toMatchObject({ out: 1, reordered: false });
        expect(f.linkDiff(files("a", "b"), files("b", "a"), null, "")).toMatchObject({ reordered: true, added: 0, out: 0 });
        // a title with only spaces is no title; a title change alone is dirty without the files
        expect(f.linkDiff(files("a", "b"), files("a", "b"), null, "   ").retitled).toBe(false);
        expect(f.linkDiff(files("a", "b"), files("a", "b"), "x", "").retitled).toBe(true);
        expect(f.linkDiff(files("a", "b"), files("a", "b"), "x", "y")).toMatchObject({ files: false, dirty: true });
    });
    it("moveFile moves one tile and never mutates the list; out of range is a no-op", () => {
        const l = files("a", "b", "c", "d");
        expect(f.moveFile(l, 0, 2).map((x: any) => x.id)).toEqual(["b", "c", "a", "d"]);
        expect(f.moveFile(l, 3, 0).map((x: any) => x.id)).toEqual(["d", "a", "b", "c"]);
        expect(f.moveFile(l, 1, 9).map((x: any) => x.id)).toEqual(["a", "b", "c", "d"]);
        expect(l.map((x) => x.id)).toEqual(["a", "b", "c", "d"]);
    });
    it("fileNotShown: hidden, then (public link) no url; a private link shows files without a public url", () => {
        expect(f.fileNotShown({ hidden: true, url: "u" }, false)).toBe("hidden");
        expect(f.fileNotShown({ url: null }, false)).toBe("private or deleted");
        expect(f.fileNotShown({ url: "u" }, false)).toBe("");
        expect(f.fileNotShown({ url: null }, true)).toBe("");
        expect(f.fileNotShown({ hidden: true, url: null }, true)).toBe("hidden");
    });
    it("fileKind names the kind and the length", () => {
        expect(f.fileKind({ content_type: "video/mp4", duration: 12 })).toBe("video · 0:12");
        expect(f.fileKind({ content_type: "image/gif" })).toBe("gif");
        expect(f.fileKind({ content_type: "image/webp" })).toBe("image");
    });
    it("pickCandidates: one tile per post, the file that fits the link; in-link locked; hidden posts skipped", () => {
        const items = [
            { id: "p1orig", post_key: "P1", visibility: "private", url: null },
            { id: "p1pub", post_key: "P1", visibility: "public", url: "https://m/x.webp" },
            { id: "p2", post_key: "P2", visibility: "private", url: null },
            { id: "p3", post_key: "P3", visibility: "public", url: "https://m/y.webp", hidden: true },
            { id: "p4", post_key: "P4", visibility: "public", url: "https://m/z.webp" },
            { id: "solo", visibility: "private", url: null },
        ];
        const pub = f.pickCandidates(items, { p4: 1 }, false);
        expect(pub.map((c: any) => [c.key, c.file.id, c.linked, c.blocked])).toEqual([
            ["P1", "p1pub", false, false], ["P2", "p2", false, true], ["P4", "p4", true, false], ["solo", "solo", false, true],
        ]);
        const priv = f.pickCandidates(items, {}, true);
        expect(priv.map((c: any) => [c.key, c.file.id, c.blocked])).toEqual([["P1", "p1orig", false], ["P2", "p2", false], ["P4", "p4", false], ["solo", "solo", false]]);
        // a post whose private file is already in the link stays locked on that file
        expect(f.pickCandidates(items, { p1orig: 1 }, true)[0]).toMatchObject({ linked: true, file: { id: "p1orig" } });
    });
    it("names the refusals the way the brief says", () => {
        expect(f.LINK_ERRORS["error.share.not_public"]).toBe("some of those files aren't public. a public link takes public files only.");
        expect(f.LINK_ERRORS["error.hidden"]).toBe("a hidden post can't go in a link.");
        expect(f.LINK_ERRORS["error.share.bad_request"]).toBe("a link holds 2 to 10 files.");
        expect(f.LINK_ERRORS["error.share.changed"]).toBe("this link changed somewhere else. reloaded.");
    });
});
