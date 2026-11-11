// The MCP migration to the app tools (MCP-APP-CONTRACT.md section 6.3 to 6.5): the twelve older tools are not listed but
// still answer through their replacement app tool; the app tools forward every option the old ones had; every other tool
// answers structuredContent; some write tools end on a widget view. The real server, registry and SQL on node:sqlite,
// driven over JSON-RPC; ops that need a container are recorded fakes.
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/server/validators/cf-worker";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { INSTRUCTIONS, MCP_RETIRED_CALLS, mcpToolList, mcpToolName, structuredOf, MCP_RESULT_MAX, type McpCaller } from "../src/mcp";
import { FOLLOWS } from "../src/mcp-app/follow";
import { RETIRED_TOOLS } from "../src/mcp-app/retired";
import { serveMcpRequest } from "../src/mcp-app/server";
import { APP_TOOLS } from "../src/mcp-app/tools";
import { forCall } from "../src/registry/context";
import { opBase, REGISTRY } from "../src/registry/index";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";
import { withBatch } from "./d1-batch";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const T0 = 1_760_000_000_000;
const JOB = "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt";
const SET_A = "1000000000000000001";
const SET_B = "1000000000000000002";

let db: FakeD1;
let env: any;
let log: { call: string; input: any }[];
let fakes: Record<string, (input: any) => unknown>;

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent", await hashKey("0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11"), "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        // the search Space is "on" (the fake library.search never calls it)
        EMBED_URL: "https://embed.test",
        EMBED_TOKEN: "t",
    };
    log = [];
    fakes = {};
    seed();
});

// ---- seeding -------------------------------------------------------------------------------------------------------------

let n = 0;
function seedFile(o: { id: string; name: string; type?: string; vis?: "public" | "private"; duration?: number | null }) {
    n += 1;
    const pub = (o.vis ?? "public") === "public";
    const type = o.type ?? "video/mp4";
    const ext = type === "video/mp4" ? "mp4" : "jpg";
    const key = `Nm${String(n).padStart(10, "0")}`;
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, poster, visibility, post_key)
             VALUES (?, ?, 'saved', ?, ?, ?, ?, ?, 1000, 720, 1280, ?, 'https://www.tiktok.com/@a/video/1', 'k', ?, ?, ?, ?)`,
        )
        .run(o.id, pub ? "public" : "private", pub ? "media" : "originals", pub ? `${key}.${ext}` : `originals/${o.id}.${ext}`, pub ? `${MEDIA}${key}.${ext}` : null, o.name, type, o.duration === undefined ? 9 : o.duration, T0 + n * 1000, pub && type === "video/mp4" ? `${MEDIA}Poster${n}.jpg` : null, pub ? "public" : "private", o.id);
}
function seed() {
    n = 0;
    seedFile({ id: "CatVideo00000001", name: "cat on a shelf.mp4" });
    seedFile({ id: "CatVideo00000002", name: "cat two.mp4" });
    seedFile({ id: "CatPicture000004", name: "cat.jpg", type: "image/jpeg", duration: null });
    // a file of the private bucket can have a private link of its own
    seedFile({ id: "CatSecret0000003", name: "cat secret.mp4", vis: "private" });
    db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, 'All the cats', 'k', ?, NULL)").run(SET_A, JSON.stringify(["CatVideo00000001", "CatPicture000004"]), T0 + 5);
    db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, 'More cats', 'k', ?, NULL)").run(SET_B, JSON.stringify(["CatVideo00000001", "CatVideo00000002"]), T0 + 6);
}

// ---- the server ----------------------------------------------------------------------------------------------------------

const container = { fetch: async () => Response.json({ status: "error" }, { status: 503 }) };
const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const callerFor = (): McpCaller => {
    const base = opBase(env, container, { now: () => T0 + 100_000, sleep: async () => {}, fixedLength: fixedLengthPair } as never, REGISTRY);
    return {
        ctx: forCall(base, { keyId: "key-1", caller: "key" }),
        clientKeyId: "key-1",
        origin: API,
        fetch: (async () => new Response(png, { headers: { "content-type": "image/png" } })) as typeof fetch,
    };
};

// the real registry whose worker ops record their input; `fakes` answer instead of the handler
const recording = Object.create(REGISTRY, {
    toolsFor: {
        value: (surface: "chat", flags: any) =>
            REGISTRY.toolsFor(surface, flags).map((op) =>
                op.handler
                    ? {
                          ...op,
                          handler: async (ctx: any, input: any) => {
                              log.push({ call: op.callName, input });
                              const fake = fakes[op.callName];
                              return fake ? { status: 200, body: fake(input) } : op.handler!(ctx, input);
                          },
                      }
                    : op,
            ),
    },
});

let id = 1;
async function rpc(method: string, params?: unknown): Promise<any> {
    const body = { jsonrpc: "2.0", id: id++, method, ...(params === undefined ? {} : { params }) };
    const res = await serveMcpRequest(recording, callerFor(), new Request(`${API}/mcp`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }), body);
    return res.json();
}
const call = async (name: string, args: Record<string, unknown> = {}) => (await rpc("tools/call", { name, arguments: args })).result;
const listed = async () => (await rpc("tools/list")).result.tools as any[];

const validator = new CfWorkerJsonSchemaValidator();
const valid = (schema: unknown, value: unknown) => validator.getValidator(schema as never)(value);

// ---- the retired tools -----------------------------------------------------------------------------------------------------

const RETIRED_NAMES = ["library_search", "library_list", "library_post", "edits_get", "edits_list", "collections_list", "links_list", "links_create", "make_webp", "upload_begin", "library_save", "jobs_wait"];

// Every field of the old input, an op-side expectation of what it receives, and the fake body the op answers.
type Case = { retired: string; tool: string; call: string; args: Record<string, unknown>; toolArgs?: Record<string, unknown>; input: Record<string, unknown>; body?: unknown };
const CRATE = { x: 0.1, y: 0.2, w: 0.5, h: 0.6 };
const CASES: Case[] = [
    { retired: "library_search", tool: "search_library", call: "library.search", args: { query: "cat", limit: 7, within: { collection: "Cats" } }, input: { query: "cat", limit: 7, within: { collection: "Cats" } }, body: [] },
    {
        retired: "library_list",
        tool: "search_library",
        call: "library.list",
        args: { since: "2025-01-01", until: 1_800_000_000_000, source: "tiktok.com", kind: "video", query: "cat", limit: 50 },
        // search_library itself is meaning search while it is on; library_list was the substring match
        toolArgs: { since: "2025-01-01", until: 1_800_000_000_000, source: "tiktok.com", kind: "video", query: "cat", limit: 50, match: "text" },
        input: { since: "2025-01-01", until: 1_800_000_000_000, source: "tiktok.com", kind: "video", query: "cat", limit: 50 },
        body: [],
    },
    { retired: "library_post", tool: "show_post", call: "library.post", args: { id: "CatVideo00000001" }, input: { id: "CatVideo00000001" } },
    { retired: "edits_get", tool: "show_edit", call: "edits.get", args: { id: "Proj000000000001" }, input: { id: "Proj000000000001" }, body: { id: "Proj000000000001", title: "Mine", revision: 1, duration: 2, timeline: { main: [], overlay: [] }, sources: {}, render: null } },
    { retired: "edits_list", tool: "show_edit", call: "edits.list", args: {}, input: {}, body: [] },
    { retired: "collections_list", tool: "list_collections", call: "collections.list", args: {}, input: {} },
    { retired: "links_list", tool: "list_share_links", call: "links.list", args: {}, input: {} },
    { retired: "links_create", tool: "create_share_link", call: "links.create", args: { ids: ["CatVideo00000001", "CatPicture000004"], title: "t", private: true }, input: { ids: ["CatVideo00000001", "CatPicture000004"], title: "t", private: true }, body: { id: SET_A, url: `${SHARE}p/${"k".repeat(22)}`, title: "t", files: 2, private: true } },
    {
        retired: "make_webp",
        tool: "convert_to_webp",
        call: "make.webp",
        args: { id: "CatVideo00000001", start: 1, end: 3, crop: CRATE, width: 320, quality: "high" },
        input: { id: "CatVideo00000001", start: 1, end: 3, crop: CRATE, width: 320, quality: "high" },
        body: { job: JOB, status: "running" },
    },
    { retired: "upload_begin", tool: "upload_files", call: "upload.begin", args: { name: "a.png", title: "t", public: true, queue: true }, input: { name: "a.png", title: "t", public: true, queue: true } },
    {
        retired: "library_save",
        tool: "save_link",
        call: "library.save",
        args: { url: "https://x.com/a/status/1", items: [0, 1], public: true, title: "t", wait: 30, engine: "ytdlp" },
        input: { url: "https://x.com/a/status/1", items: [0, 1], public: true, title: "t", wait: 30, engine: "ytdlp" },
        body: { save_id: "SaveSessionId000000aXY", status: "downloading" },
    },
    { retired: "jobs_wait", tool: "job_status", call: "jobs.wait", args: { job: JOB, seconds: 20 }, input: { job: JOB, seconds: 20 }, body: { job: JOB, status: "running" } },
];

describe("the twelve retired tools", () => {
    it("are not listed, and the map names a listed app tool for each", async () => {
        const names = (await listed()).map((t) => t.name);
        expect(Object.keys(RETIRED_TOOLS).sort()).toEqual([...RETIRED_NAMES].sort());
        expect([...MCP_RETIRED_CALLS].map(mcpToolName).sort()).toEqual([...RETIRED_NAMES].sort());
        for (const old of RETIRED_NAMES) {
            expect(names, old).not.toContain(old);
            expect(names, RETIRED_TOOLS[old]!.tool).toContain(RETIRED_TOOLS[old]!.tool);
        }
        expect(names.slice(0, 10)).toEqual(APP_TOOLS.map((t) => t.name));
        expect(names).toHaveLength(new Set(names).size);
    });

    it("the cases cover every field of every retired op's input", () => {
        expect(CASES.map((c) => c.retired).sort()).toEqual([...RETIRED_NAMES].sort());
        for (const c of CASES) {
            expect(RETIRED_TOOLS[c.retired]!.tool, c.retired).toBe(c.tool);
            const op = REGISTRY.byCall(c.call)!;
            const fields = Object.keys((op.input as unknown as { shape?: Record<string, unknown> }).shape ?? {});
            for (const f of fields) expect(Object.keys(c.args), `${c.call}.${f}`).toContain(f);
            // ... and the case passes nothing the op does not have
            for (const k of Object.keys(c.input)) expect(Object.keys(c.args), `${c.call}.${k}`).toContain(k);
        }
    });

    for (const c of CASES) {
        it(`${c.retired} answers as ${c.tool}, and ${c.tool} forwards every field of the old input to ${c.call}`, async () => {
            if (c.body !== undefined) fakes[c.call] = () => c.body;
            fakes["jobs.wait"] ??= () => ({ job: JOB, status: "running" });
            fakes["make.webp"] ??= () => ({ job: JOB, status: "running" });
            fakes["library.search"] ??= () => [];
            const tool = (await listed()).find((t) => t.name === c.tool);
            for (const name of [c.retired, c.tool]) {
                log = [];
                const r = await call(name, name === c.tool ? (c.toolArgs ?? c.args) : c.args);
                expect(r.isError, `${name}: ${r.content?.[0]?.text}`).toBeUndefined();
                // the old name and the new one reach the op with the same input
                expect(log.filter((l) => l.call === c.call).at(-1)?.input, name).toEqual(c.input);
                // the answer is the app tool's: text, and structuredContent that passes its advertised outputSchema
                const verdict = valid(tool.outputSchema, r.structuredContent);
                expect(verdict.valid, `${name}: ${verdict.errorMessage}`).toBe(true);
                expect(r.content[0].text.length).toBeGreaterThan(0);
            }
        });
    }

    it("map the old arguments: library_list keeps its substring match, the *_list calls ask for every row", async () => {
        expect(RETIRED_TOOLS.library_list!.map({ query: "a b" })).toEqual({ limit: 100, query: "a b", match: "text" });
        // library_list answered 100 posts when no limit was given
        expect(RETIRED_TOOLS.library_list!.map({})).toEqual({ limit: 100 });
        expect(RETIRED_TOOLS.library_list!.map({ query: "", limit: 5 })).toEqual({ limit: 5 });
        expect(RETIRED_TOOLS.collections_list!.map({})).toEqual({ limit: 500 });
        expect(RETIRED_TOOLS.links_list!.map({})).toEqual({ limit: 500 });
        expect(RETIRED_TOOLS.edits_get!.map({ id: "x", junk: 1 })).toEqual({ id: "x" });
        expect(RETIRED_TOOLS.edits_list!.map({ junk: 1 })).toEqual({});
        // library_list with a query is the title match even while meaning search is on
        fakes["library.list"] = () => [];
        await call("library_list", { query: "cat" });
        expect(log.map((l) => l.call)).toEqual(["library.list"]);
        expect((await call("library_list", { query: "cat" })).structuredContent).toMatchObject({ mode: "text" });
        // no limit: the older default of 100 reaches the op; library_search with within and no limit scores up to 500
        log.length = 0;
        await call("library_list", {});
        expect(log.find((l) => l.call === "library.list")!.input.limit).toBe(100);
        log.length = 0;
        fakes["library.search"] = () => [];
        await call("library_search", { query: "cat", within: "Cats" });
        expect(log.find((l) => l.call === "library.search")!.input.limit).toBe(500);
        delete fakes["library.search"];
        // library_list with no query is the list (newest first)
        delete fakes["library.list"];
        expect((await call("library_list", {})).structuredContent).toMatchObject({ mode: "list", total: 4 });
    });

    it("the flat upload_begin form (name, title) and a bad argument are answered by the app tool", async () => {
        const r = await call("upload_begin", { name: "x.mp4", title: "T" });
        expect(r.structuredContent.uploads[0]).toMatchObject({ name: "x.mp4" });
        expect(r.structuredContent.uploads[0].upload_url).toMatch(/\?name=x\.mp4&title=T$/);
        const bad = await call("library_save", {});
        expect(bad.isError).toBe(true);
        expect(bad.content[0].text).toMatch(/^save_link: url/);
        expect((await call("jobs_wait", {})).content[0].text).toMatch(/^job_status: job/);
    });

    it("an unknown tool is still -32602", async () => {
        expect((await rpc("tools/call", { name: "library_nope", arguments: {} })).error.code).toBe(-32602);
    });
});

// ---- structuredContent on every other tool ----------------------------------------------------------------------------------

describe("structuredContent on the other tools", () => {
    it("an object result is the JSON as it is, and the text is unchanged", async () => {
        const r = await call("library_hidden");
        expect(r.structuredContent).toEqual({ posts: [], next: null });
        expect(JSON.parse(r.content[0].text)).toEqual(r.structuredContent);
    });

    it("a list becomes { items }; a string or null gets none", async () => {
        const list = await call("sets_list");
        expect(Array.isArray(JSON.parse(list.content[0].text))).toBe(true);
        expect(list.structuredContent).toEqual({ items: JSON.parse(list.content[0].text) });
        expect(structuredOf([1, 2])).toEqual({ items: [1, 2] });
        expect(structuredOf({ a: 1, b: [2] })).toEqual({ a: 1, b: [2] });
        expect(structuredOf("hello")).toBeUndefined();
        expect(structuredOf(null)).toBeUndefined();
        expect(structuredOf(5)).toBeUndefined();
        // an answer too big for the text is left out
        expect(structuredOf({ big: "x".repeat(MCP_RESULT_MAX) })).toBeUndefined();
    });

    it("no outputSchema is advertised for them", async () => {
        const tools = await listed();
        for (const t of tools.slice(10)) expect(t.outputSchema, t.name).toBeUndefined();
    });

    it("look still returns images and no structuredContent", async () => {
        const r = await call("look", { ids: ["CatPicture000004"] });
        expect(r.isError).toBeUndefined();
        expect(r.content.some((c: any) => c.type === "image")).toBe(true);
        expect(r.structuredContent).toBeUndefined();
    });

    it("an error has no structuredContent", async () => {
        const r = await call("library_title", { id: "NoSuchPost0000001", title: "x" });
        expect(r.isError).toBe(true);
        expect(r.structuredContent).toBeUndefined();
    });
});

// ---- widgets after a write ----------------------------------------------------------------------------------------------------

describe("write tools that end on a widget view", () => {
    const viewOf = (tools: any[], name: string) => tools.find((t) => t.name === name)?._meta;
    const link = (v: string) => ({ ui: { resourceUri: `ui://capystore/${v}.html` }, "ui/resourceUri": `ui://capystore/${v}.html` });

    it("tools/list gives each its widget link, and the others none; ask-tier tools stay destructive", async () => {
        const tools = await listed();
        const want: Record<string, string> = {
            collections_create: "collections",
            collections_add: "collections",
            collections_update: "collections",
            links_update: "links",
            links_rotate: "links",
            links_private: "links",
            library_title: "post",
            library_visibility: "post",
            library_status: "post",
        };
        expect(Object.keys(FOLLOWS).map(mcpToolName).sort()).toEqual(Object.keys(want).sort());
        for (const [name, view] of Object.entries(want)) expect(viewOf(tools, name), name).toEqual(link(view));
        for (const name of ["library_delete", "links_revoke", "collections_delete", "make_crop", "names_list", "library_hidden"]) expect(viewOf(tools, name), name).toBeUndefined();
        for (const name of ["links_rotate", "links_private", "library_visibility", "library_status"]) expect(tools.find((t) => t.name === name).annotations, name).toEqual({ destructiveHint: true, readOnlyHint: false });
        for (const name of ["collections_create", "links_update", "library_title"]) expect(tools.find((t) => t.name === name).annotations, name).toBeUndefined();
    });

    const outputOf = (name: string) => APP_TOOLS.find((t) => t.name === name)!.output;

    it("collections_create / add / update: the collections view of that collection, the text still the op's JSON", async () => {
        const made = await call("collections_create", { name: "Pets", links: [SET_A] });
        expect(made.isError).toBeUndefined();
        const op = JSON.parse(made.content[0].text);
        expect(op).toMatchObject({ name: "Pets", link_ids: [SET_A] });
        expect(outputOf("list_collections").parse(made.structuredContent)).toBeTruthy();
        expect(made.structuredContent).toMatchObject({ view: "collections", total: 1 });
        expect(made.structuredContent.collections[0]).toMatchObject({ id: op.id, name: "Pets", link_ids: [SET_A], posts: 2 });
        expect(made.structuredContent.collections[0].links[0]).toMatchObject({ id: SET_A, files: 2 });

        const added = await call("collections_add", { collection: "Pets", links: [SET_B] });
        expect(added.structuredContent.collections[0]).toMatchObject({ id: op.id, link_ids: expect.arrayContaining([SET_A, SET_B]) });
        expect(JSON.parse(added.content[0].text)).toMatchObject({ created: false });
        const renamed = await call("collections_update", { collection: op.id, name: "Cats" });
        expect(renamed.structuredContent.collections[0]).toMatchObject({ id: op.id, name: "Cats" });
        // other collections are not in the view
        await call("collections_create", { name: "Other" });
        const again = await call("collections_update", { collection: op.id, name: "Cats again" });
        expect(again.structuredContent.collections).toHaveLength(1);
    });

    it("links_update: the links view of that link, created set to it", async () => {
        const r = await call("links_update", { link: SET_A, title: "Fresh title" });
        expect(r.isError, r.content?.[0]?.text).toBeUndefined();
        expect(JSON.parse(r.content[0].text)).toMatchObject({ id: SET_A, title: "Fresh title" });
        expect(outputOf("list_share_links").parse(r.structuredContent)).toBeTruthy();
        expect(r.structuredContent).toMatchObject({ view: "links", total: 1, created: SET_A });
        expect(r.structuredContent.links[0]).toMatchObject({ id: SET_A, title: "Fresh title", files: 2 });
    });

    it("links_private and links_rotate: the links view of a gallery link; a single file's private link has none", async () => {
        const p = await call("links_private", { link: SET_A, private: true });
        expect(p.isError, p.content?.[0]?.text).toBeUndefined();
        expect(p.structuredContent).toMatchObject({ view: "links", created: SET_A });
        expect(p.structuredContent.links[0]).toMatchObject({ id: SET_A, private: true });
        expect(p.structuredContent.links[0].url).toBe(JSON.parse(p.content[0].text).url);
        const rot = await call("links_rotate", { link: SET_A });
        expect(rot.isError, rot.content?.[0]?.text).toBeUndefined();
        expect(rot.structuredContent).toMatchObject({ view: "links", created: SET_A });
        expect(rot.structuredContent.links[0].url).toBe(JSON.parse(rot.content[0].text).url);
        expect(rot.structuredContent.links[0].url).not.toBe(p.structuredContent.links[0].url);
        // a lone file: the op's own JSON, no view
        const file = await call("links_private", { link: "CatSecret0000003", private: true });
        expect(file.isError, file.content?.[0]?.text).toBeUndefined();
        expect(file.structuredContent.view).toBeUndefined();
        expect(file.structuredContent).toMatchObject({ kind: "item", private: true });
    });

    it("library_title: the post view with the new title", async () => {
        const r = await call("library_title", { id: "CatVideo00000001", title: "Renamed" });
        expect(r.isError, r.content?.[0]?.text).toBeUndefined();
        expect(JSON.parse(r.content[0].text)).toEqual({ post_id: "CatVideo00000001", title: "Renamed" });
        expect(outputOf("show_post").parse(r.structuredContent)).toBeTruthy();
        expect(r.structuredContent).toMatchObject({ view: "post", post: { id: "CatVideo00000001", title: "Renamed" } });
    });

    it("library_visibility and library_status on one post: the post view; on several, or a hidden result, the op's JSON", async () => {
        fakes["library.visibility"] = () => ({ public: true, changed: 1, posts: [{ id: "CatVideo00000001", links: [] }] });
        const v = await call("library_visibility", { ids: ["CatVideo00000001"], public: true });
        expect(v.structuredContent).toMatchObject({ view: "post", post: { id: "CatVideo00000001", status: "public" } });
        // a lone id as a string is one post too
        expect((await call("library_visibility", { ids: "CatVideo00000001", public: true })).structuredContent.view).toBe("post");
        const many = await call("library_visibility", { ids: ["CatVideo00000001", "CatVideo00000002"], public: true });
        expect(many.structuredContent).toEqual({ public: true, changed: 1, posts: [{ id: "CatVideo00000001", links: [] }] });
        fakes["library.status"] = (i: any) => ({ status: i.status, posts: [{ id: "CatVideo00000001", files: 1, links: [] }], failed: [] });
        const s = await call("library_status", { ids: ["CatVideo00000001"], status: "off" });
        expect(s.structuredContent).toMatchObject({ view: "post", post: { id: "CatVideo00000001" } });
        // hide it: the post view would show a hidden post, so the plain answer stands
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES ('CatVideo00000001', 'hidden', 'you', NULL, ?)").run(T0);
        const hidden = await call("library_status", { ids: ["CatVideo00000001"], status: "hidden" });
        expect(hidden.isError).toBeUndefined();
        expect(hidden.structuredContent).toEqual({ status: "hidden", posts: [{ id: "CatVideo00000001", files: 1, links: [] }], failed: [] });
    });

    it("a failing read after the write falls back to the plain answer", async () => {
        fakes["library.post"] = () => {
            throw new Error("boom");
        };
        const r = await call("library_title", { id: "CatVideo00000001", title: "Renamed again" });
        expect(r.isError).toBeUndefined();
        expect(r.structuredContent).toEqual({ post_id: "CatVideo00000001", title: "Renamed again" });
    });
});

// ---- what the models read -------------------------------------------------------------------------------------------------------

describe("instructions and descriptions", () => {
    const flags = { search: true, box: true, mcp: true, agents: true, ytdlp: true };
    const tools = mcpToolList(REGISTRY, flags);

    it("the instructions name only tools that are listed", () => {
        const names = new Set([...APP_TOOLS.map((t) => t.name), ...tools.map((t) => t.name)]);
        const named = INSTRUCTIONS.match(/\b[a-z]+(?:_[A-Za-z]+)+\b/g) ?? [];
        // upload_url is a field of upload_files' answer
        for (const w of new Set(named)) if (w !== "upload_url") expect(names.has(w), w).toBe(true);
        for (const old of RETIRED_NAMES) expect(INSTRUCTIONS).not.toContain(old);
    });

    it("no description names a retired tool or the chat's job hook, with every switch on", () => {
        expect(tools.length).toBeGreaterThan(60);
        for (const t of tools) {
            expect(t.description, t.name).not.toMatch(/onDone|\bcobalt\.|\b[a-z]+\.[a-z]+[A-Z]?[a-z]*\(/);
            for (const old of RETIRED_NAMES) expect(t.description, `${t.name} says ${old}`).not.toMatch(new RegExp(`\\b${old}\\b`));
            // the chat's dotted call names are written as tools are named here
            expect(t.description, t.name).not.toMatch(/\b(?:library|links|collections|edits|make|jobs|upload)\.[a-z][A-Za-z]*\b(?!\.)/);
        }
        const text = (n: string) => tools.find((t) => t.name === n)!.description;
        expect(text("agents_spawn")).toMatch(/job_status/);
        expect(text("library_visibility")).toMatch(/show_post/);
        expect(text("library_status")).toMatch(/search_library/);
    });
});
