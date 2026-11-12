// The MCP server's SDK core (MCP-APP-CONTRACT.md section 6): app tools and widgets (fakes injected), driven by the
// official client over an in-process fetch, plus the raw JSON-RPC edges and the upload link's CORS answers.
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/server/validators/cf-worker";
import * as z from "zod";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { rotateMcpLink, setMcpMode } from "../src/mcp-link";
import { claudeUiDomain, serveMcpRequest, widgetCsp } from "../src/mcp-app/server";
import { VIEWS } from "../src/mcp-app/shapes";
import type { AppTool, Widget } from "../src/mcp-app/types";
import { MCP_RESULT_MAX, type McpCaller } from "../src/mcp";
import { opBase, REGISTRY } from "../src/registry/index";
import { forCall } from "../src/registry/context";
import { OpError } from "../src/registry/op";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

let db: FakeD1;
let env: WorkerEnv;
let calls: string[];

const Out = z.looseObject({ view: z.literal("search"), count: z.number() });
const fakeTools: AppTool[] = [
    {
        name: "search_library",
        title: "Search the library",
        description: "Find posts.",
        input: z.object({ query: z.string().min(1) }),
        output: Out,
        readOnly: true,
        view: "search",
        async run(ctx, input) {
            const posts = (await ctx.call("library.list", { query: input.query })) as unknown[];
            calls.push(`has:${ctx.has("library.list")}:${ctx.has("nope.nope")}`);
            return { text: `${posts.length} posts for ${input.query}`, structured: { view: "search", count: posts.length } };
        },
    },
    {
        name: "convert_to_webp",
        title: "Make an animated WebP",
        description: "Convert.",
        input: z.object({ id: z.string() }),
        output: z.looseObject({ view: z.literal("webp") }),
        readOnly: false,
        view: "webp",
        async run(ctx) {
            await ctx.call("library.post", { id: "Ab3dE6gH9jK2mN5p" });
            return { text: "never", structured: { view: "webp" } };
        },
    },
    {
        name: "job_status",
        title: "Job status",
        description: "Poll a job.",
        input: z.object({ job: z.string() }),
        output: z.looseObject({ state: z.string() }),
        readOnly: true,
        view: null,
        appOnly: true,
        async run() {
            throw new OpError(409, "error.test.busy", "the job is busy");
        },
    },
    {
        name: "only_with_search",
        title: "Needs search",
        description: "Gated.",
        input: z.object({}),
        output: z.looseObject({}),
        readOnly: true,
        view: null,
        when: (f) => f.search === true,
        async run() {
            return { text: "ok", structured: {} };
        },
    },
    {
        name: "long_answer",
        title: "Long",
        description: "Long text.",
        input: z.object({}),
        output: z.looseObject({}),
        readOnly: true,
        view: null,
        async run() {
            return { text: "x".repeat(MCP_RESULT_MAX + 10), structured: {} };
        },
    },
];
const fakeWidgets: Widget[] = [
    { view: "search", uri: "ui://capystore/search.html", title: "Search", html: "<html>search</html>" },
    { view: "webp", uri: "ui://capystore/webp.html", title: "WebP", html: "<html>webp</html>" },
];

beforeEach(async () => {
    calls = [];
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent", await hashKey(CLIENT), "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    } as WorkerEnv;
});

const container = { fetch: async () => Response.json({ status: "error" }, { status: 503 }) };
const callerFor = (): McpCaller => {
    const base = opBase(env, container, { now: () => 1_800_000_000_000, sleep: async () => {}, fixedLength: fixedLengthPair } as never, REGISTRY);
    return { ctx: forCall(base, { keyId: "key-1", caller: "key" }), clientKeyId: "key-1", origin: API };
};

// the raw JSON-RPC edge
const raw = (body: unknown, url = `${API}/mcp`, headers: Record<string, string> = {}) =>
    serveMcpRequest(REGISTRY, callerFor(), new Request(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) }), body, { appTools: fakeTools, widgets: fakeWidgets });
let id = 1;
const rpc = async (method: string, params?: unknown, url?: string, headers?: Record<string, string>) => {
    const res = await raw({ jsonrpc: "2.0", id: id++, method, ...(params === undefined ? {} : { params }) }, url, headers);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    return (await res.json()) as any;
};

// the official client over the same server
async function connect(url = `${API}/mcp`) {
    const fetchLike = async (input: string | URL | Request, init?: RequestInit) => {
        const req = new Request(input, init);
        if (req.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
        const body = JSON.parse(await req.clone().text());
        return serveMcpRequest(REGISTRY, callerFor(), req, body, { appTools: fakeTools, widgets: fakeWidgets });
    };
    const client = new Client({ name: "test", version: "1" });
    await client.connect(new StreamableHTTPClientTransport(new URL(url), { fetch: fetchLike as never }));
    return client;
}

describe("initialize", () => {
    it("answers the version, tools + resources capabilities, server info and the app-tool lines", async () => {
        const client = await connect();
        expect(client.getServerVersion()).toMatchObject({ name: "capystore", version: "2.0.0" });
        expect(client.getServerCapabilities()).toMatchObject({ tools: {}, resources: {} });
        const text = client.getInstructions()!;
        expect(text).toMatch(/search_library, show_post, show_edit/);
        expect(text).toMatch(/upload_files/);
        await client.close();
    });
});

describe("tools/list", () => {
    it("lists the app tools first, then the existing tools unchanged", async () => {
        const client = await connect();
        const { tools } = await client.listTools();
        const names = tools.map((t) => t.name);
        // `only_with_search` is gated off (no search Space)
        expect(names.slice(0, 4)).toEqual(["search_library", "convert_to_webp", "job_status", "long_answer"]);
        // the older tools follow; the twelve retired ones are not listed
        expect(names).toContain("library_title");
        expect(names).not.toContain("library_list");
        expect(names).not.toContain("upload_begin");
        expect(names.indexOf("library_title")).toBeGreaterThan(3);
        const search = tools.find((t) => t.name === "search_library")!;
        expect(search.title).toBe("Search the library");
        expect(search.annotations?.readOnlyHint).toBe(true);
        expect(search.inputSchema).toMatchObject({ type: "object", required: ["query"] });
        expect(search.outputSchema).toMatchObject({ type: "object" });
        expect(search._meta).toEqual({ ui: { resourceUri: "ui://capystore/search.html" }, "ui/resourceUri": "ui://capystore/search.html" });
        expect(tools.find((t) => t.name === "convert_to_webp")!.annotations?.readOnlyHint).toBe(false);
        // an app-only tool is hidden from the model, and has no widget
        expect(tools.find((t) => t.name === "job_status")!._meta).toEqual({ ui: { visibility: ["app"] } });
        expect(tools.find((t) => t.name === "long_answer")!._meta).toBeUndefined();
        await client.close();
    });
    it("?tools=app lists only the app tools, and the old ones are not callable there", async () => {
        const url = `${API}/mcp?tools=app`;
        expect((await rpc("tools/list", undefined, url)).result.tools.map((t: any) => t.name)).toEqual(["search_library", "convert_to_webp", "job_status", "long_answer"]);
        const res = await rpc("tools/call", { name: "library_list", arguments: {} }, url);
        expect(res.error.code).toBe(-32602);
    });
    it("a tool gated by a flag shows up when the flag holds", async () => {
        env.EMBED_URL = "https://example.hf.space";
        env.EMBED_TOKEN = "t";
        const names = (await rpc("tools/list")).result.tools.map((t: any) => t.name);
        expect(names).toContain("only_with_search");
    });
});

describe("tools/call on an app tool", () => {
    it("returns text and structuredContent; ctx.call runs the op as the MCP thread, ctx.has answers", async () => {
        const client = await connect();
        const r = await client.callTool({ name: "search_library", arguments: { query: "cats" } });
        expect(r.isError).toBeFalsy();
        expect(r.content).toEqual([{ type: "text", text: "0 posts for cats" }]);
        expect(r.structuredContent).toEqual({ view: "search", count: 0 });
        expect(calls).toEqual(["has:true:false"]);
        await client.close();
    });
    it("a zod error is an isError text naming the field", async () => {
        const r = (await rpc("tools/call", { name: "search_library", arguments: {} })).result;
        expect(r.isError).toBe(true);
        expect(r.content[0].text).toMatch(/^search_library: query:/);
        expect(r.structuredContent).toBeUndefined();
    });
    it("a thrown OpError becomes isError text like the existing tools; a failing ctx.call too", async () => {
        const busy = (await rpc("tools/call", { name: "job_status", arguments: { job: "j" } })).result;
        expect(busy).toEqual({ content: [{ type: "text", text: "the job is busy" }], isError: true });
        const missing = (await rpc("tools/call", { name: "convert_to_webp", arguments: { id: "x" } })).result;
        expect(missing.isError).toBe(true);
        expect(missing.content[0].text).toMatch(/no post/);
    });
    it("cuts a long text at MCP_RESULT_MAX", async () => {
        const r = (await rpc("tools/call", { name: "long_answer", arguments: {} })).result;
        expect(r.content[0].text.length).toBeLessThan(MCP_RESULT_MAX + 100);
        expect(r.content[0].text).toMatch(/… \(cut/);
    });
    it("an existing tool still answers through the SDK", async () => {
        const r = (await rpc("tools/call", { name: "library_hidden", arguments: {} })).result;
        expect(JSON.parse(r.content[0].text)).toEqual({ posts: [], next: null });
        expect(r.structuredContent).toEqual({ posts: [], next: null });
    });
});

describe("resources", () => {
    it("lists the widgets and reads one with its mime type, CSP and no domain for an unknown host", async () => {
        const client = await connect();
        const list = await client.listResources();
        expect(list.resources.map((r) => r.uri)).toEqual(["ui://capystore/search.html", "ui://capystore/webp.html"]);
        expect(list.resources[0]!.mimeType).toBe("text/html;profile=mcp-app");
        const read = await client.readResource({ uri: "ui://capystore/search.html" });
        const c = read.contents[0] as any;
        expect(c.mimeType).toBe("text/html;profile=mcp-app");
        expect(c.text).toBe("<html>search</html>");
        expect(c._meta.ui.csp).toEqual({ resourceDomains: ["https://media.capybaraharmony.com", "https://share.capybaraharmony.com", API], connectDomains: [API] });
        expect(c._meta.ui.domain).toBeUndefined();
        expect((await client.listResourceTemplates()).resourceTemplates).toEqual([]);
        await expect(client.readResource({ uri: "ui://capystore/nope.html" })).rejects.toThrow();
        await client.close();
    });
    it("sets Claude's sandbox domain from the exact URL, only for a request that looks like Claude", async () => {
        const url = `${API}/mcp/k/${"a".repeat(32)}`;
        const read = (headers: Record<string, string>) => rpc("resources/read", { uri: "ui://capystore/search.html" }, url, headers);
        const claude = (await read({ "user-agent": "Claude-User/1.0" })).result.contents[0]._meta.ui;
        expect(claude.domain).toBe(await claudeUiDomain(url));
        expect(claude.domain).toMatch(/^[0-9a-f]{32}\.claudemcpcontent\.com$/);
        expect((await read({ "user-agent": "ChatGPT-User" })).result.contents[0]._meta.ui.domain).toBeUndefined();
    });
    it("claudeUiDomain matches the documented example", async () => {
        expect(await claudeUiDomain("https://example.com/mcp")).toBe("c3d80a4ed901ee05b21755a88273b4a4.claudemcpcontent.com");
        expect(widgetCsp(callerFor()).connectDomains).toEqual([API]);
    });
    it("prompts/list is empty", async () => {
        expect((await rpc("prompts/list")).result.prompts).toEqual([]);
    });
});

describe("PUT /mcp/upload/<token> from a widget", () => {
    const send = (req: Request) => handleRequest(req, env, container, { now: () => 1_800_000_000_000, sleep: async () => {}, fixedLength: fixedLengthPair });
    const token = `${"A".repeat(20)}.${"B".repeat(43)}`;
    it("answers the preflight for any origin, PUT and content-type only", async () => {
        const res = await send(new Request(`${API}/mcp/upload/${token}`, { method: "OPTIONS", headers: { origin: "https://abc.claudemcpcontent.com", "access-control-request-method": "PUT", "access-control-request-headers": "content-type" } }));
        expect(res.status).toBe(204);
        expect(res.headers.get("access-control-allow-origin")).toBe("*");
        expect(res.headers.get("access-control-allow-methods")).toBe("PUT, OPTIONS");
        expect(res.headers.get("access-control-allow-headers")).toBe("content-type");
    });
    it("an OPTIONS with no Access-Control-Request-Method stays with the gate", async () => {
        const res = await send(new Request(`${API}/mcp/upload/${token}`, { method: "OPTIONS", headers: { origin: "https://evil.example" } }));
        expect(res.status).toBe(403);
    });
    it("every PUT answer, refusals too, carries access-control-allow-origin: *", async () => {
        const res = await send(new Request(`${API}/mcp/upload/${token}`, { method: "PUT", headers: { origin: "https://abc.claudemcpcontent.com", "content-type": "image/png" }, body: new Uint8Array([1, 2, 3]) }));
        expect(res.status).toBe(401);
        expect(res.headers.get("access-control-allow-origin")).toBe("*");
    });
});

describe("the JSON-RPC edges kept from the first core (through the Worker)", () => {
    const post = (body: unknown, headers: Record<string, string> = {}) =>
        handleRequest(
            new Request(`${API}/mcp`, { method: "POST", headers: { authorization: `Bearer ${CLIENT}`, "content-type": "application/json", ...headers }, body: JSON.stringify(body) }),
            env,
            container,
            { now: () => 1_800_000_000_000, sleep: async () => {}, fixedLength: fixedLengthPair },
        );
    it("a message that is not JSON-RPC is -32600 in a 200", async () => {
        const bad = await post({ id: 1, method: "ping" });
        expect(bad.status).toBe(200);
        expect(((await bad.json()) as any).error.code).toBe(-32600);
    });
    it("a batch answers in order, skips notifications and answers a bad member in place", async () => {
        const res = await post([{ jsonrpc: "2.0", id: "a", method: "ping" }, { jsonrpc: "2.0", method: "notifications/initialized" }, { nope: 1 }, { jsonrpc: "2.0", id: "b", method: "ping" }]);
        const out = (await res.json()) as any[];
        expect(out.map((r) => r.id)).toEqual(["a", null, "b"]);
        expect(out[1].error.code).toBe(-32600);
    });
    it("an initialize with no capabilities or client info still works", async () => {
        const res = await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "1999-01-01" } });
        expect(((await res.json()) as any).result.protocolVersion).toBe("2025-11-25");
    });
    it("the real app tools and widgets list through the Worker: ten tools with their widget links, nine widgets", async () => {
        const tools = ((await (await post({ jsonrpc: "2.0", id: 1, method: "tools/list" })).json()) as any).result.tools as any[];
        const names = ["search_library", "show_post", "show_edit", "list_collections", "list_share_links", "convert_to_webp", "upload_files", "create_share_link", "save_link", "job_status"];
        expect(tools.slice(0, 10).map((t) => t.name)).toEqual(names);
        const view = (n: string) => tools.find((t) => t.name === n)._meta;
        const link = (v: string) => ({ ui: { resourceUri: `ui://capystore/${v}.html` }, "ui/resourceUri": `ui://capystore/${v}.html` });
        expect(view("search_library")).toEqual(link("search"));
        expect(view("show_post")).toEqual(link("post"));
        expect(view("show_edit")).toEqual(link("edit"));
        expect(view("list_collections")).toEqual(link("collections"));
        expect(view("list_share_links")).toEqual(link("links"));
        expect(view("create_share_link")).toEqual(link("links"));
        expect(view("convert_to_webp")).toEqual(link("webp"));
        expect(view("upload_files")).toEqual(link("upload"));
        expect(view("save_link")).toEqual(link("save"));
        // job_status is an ordinary tool for the model: no widget, not hidden
        expect(view("job_status")).toBeUndefined();
        for (const t of tools.slice(0, 10)) expect(t.outputSchema, t.name).toMatchObject({ type: "object" });
        const res = (await (await post({ jsonrpc: "2.0", id: 2, method: "resources/list" })).json()) as any;
        expect(res.result.resources.map((r: any) => r.uri)).toEqual(VIEWS.map((v) => `ui://capystore/${v}.html`));
        expect(res.result.resources).toHaveLength(9);
        expect(res.result.resources.every((r: any) => r.mimeType === "text/html;profile=mcp-app")).toBe(true);
    });

    it("the old leniency holds: no client info, a null one, no capabilities", async () => {
        for (const params of [{ protocolVersion: "2025-06-18" }, { protocolVersion: "2025-06-18", clientInfo: null, capabilities: null }, { clientInfo: "me", capabilities: [] }, null, "x"]) {
            const body = (await (await post({ jsonrpc: "2.0", id: 1, method: "initialize", params })).json()) as any;
            expect(body.error, JSON.stringify(params)).toBeUndefined();
            expect(body.result.serverInfo.name).toBe("capystore");
        }
        // a client info with only a name is fine too
        const named = (await (await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "x" } } })).json()) as any;
        expect(named.result.protocolVersion).toBe("2025-06-18");
    });
    it("tools/call: arguments missing, null, an array or a string are {}; no name is -32602 'tools/call needs a name'", async () => {
        for (const args of [undefined, null, [], [1, 2], "x", 5]) {
            const body = (await (await post({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "library_hidden", ...(args === undefined ? {} : { arguments: args }) } })).json()) as any;
            expect(body.error, JSON.stringify(args)).toBeUndefined();
            expect(JSON.parse(body.result.content[0].text)).toEqual({ posts: [], next: null });
        }
        for (const params of [{}, { name: 5 }, { name: null, arguments: {} }, null, undefined, "x"]) {
            const body = (await (await post({ jsonrpc: "2.0", id: 7, method: "tools/call", ...(params === undefined ? {} : { params }) })).json()) as any;
            expect(body.id).toBe(7);
            expect(body.error, JSON.stringify(params)).toEqual({ code: -32602, message: "tools/call needs a name" });
        }
        // a notification with no id gets no answer, as before
        expect((await post({ jsonrpc: "2.0", method: "tools/call", params: {} })).status).toBe(202);
    });
    it("an unknown or unsupported MCP-Protocol-Version header is ignored, as the first server did", async () => {
        for (const v of ["1999-01-01", "banana", "2099-12-31"]) {
            const res = await post({ jsonrpc: "2.0", id: 1, method: "tools/list" }, { "mcp-protocol-version": v });
            expect(res.status, v).toBe(200);
            expect(((await res.json()) as any).result.tools.length).toBeGreaterThan(10);
        }
        // a supported one still works
        expect((await post({ jsonrpc: "2.0", id: 1, method: "ping" }, { "mcp-protocol-version": "2025-06-18" })).status).toBe(200);
    });
    it("no schema dump reaches a client, whatever it sends wrong", async () => {
        const bodies: unknown[] = [
            { jsonrpc: "2.0", id: 1, method: "tools/list", params: 5 },
            { jsonrpc: "2.0", id: 1, method: "tools/list", params: { cursor: 5 } },
            { jsonrpc: "2.0", id: 1, method: "resources/read", params: {} },
            { jsonrpc: "2.0", id: 1, method: "resources/read", params: { uri: 5 } },
            { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "library_list", arguments: { limit: "lots" } } },
            { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search_library", arguments: { query: 5 } } },
            { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 5 } },
            { jsonrpc: "2.0", id: 1, method: "ping", params: [1] },
        ];
        for (const b of bodies) {
            const text = await (await post(b)).text();
            expect(text, JSON.stringify(b)).not.toMatch(/invalid_type|\\"code\\"|"path":\[|ZodError|"expected"/);
        }
    });
});

// ---- the real tools, end to end -------------------------------------------------------------------------------------------------
// MCP-APP-CONTRACT.md section 8: the real server with the real APP_TOOLS over a seeded database, through the official client;
// every read tool's structuredContent must satisfy the outputSchema the server advertises (checked with the SDK's own validator).

describe("the real app tools through the official client", () => {
    const T0 = 1_760_000_000_000;
    let n = 0;
    function seedFile(o: { id: string; name: string; type?: string; vis?: "public" | "private"; duration?: number | null; postKey?: string }) {
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
            .run(o.id, pub ? "public" : "private", pub ? "media" : "originals", pub ? `${key}.${ext}` : `originals/${o.id}.${ext}`, pub ? `${MEDIA}${key}.${ext}` : null, o.name, type, o.duration === undefined ? 9 : o.duration, T0 + n * 1000, pub && type === "video/mp4" ? `${MEDIA}Poster${n}.jpg` : null, pub ? "public" : "private", o.postKey ?? o.id);
    }
    beforeEach(() => {
        n = 0;
        seedFile({ id: "CatVideo0000001", name: "cat on a shelf.mp4" });
        seedFile({ id: "CatSecret000002", name: "cat secret.mp4", vis: "private" });
        seedFile({ id: "CatHidden000003", name: "cat hidden.mp4" });
        seedFile({ id: "CatPicture00004", name: "cat.jpg", type: "image/jpeg", duration: null });
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES ('CatHidden000003', 'hidden', 'you', NULL, ?)").run(T0);
        db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES ('SetCats', ?, 'All the cats', 'k', ?, NULL)").run(JSON.stringify(["CatVideo0000001", "CatPicture00004"]), T0 + 5);
        db.raw.prepare("INSERT INTO share_collections (id, name, key_id, created_at, updated_at) VALUES ('ColCats', 'Cats', 'k', ?, ?)").run(T0, T0);
        db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES ('ColCats', 'SetCats', ?)").run(T0);
    });

    async function realClient(clientKeyId = "key-1") {
        const fetchLike = async (input: string | URL | Request, init?: RequestInit) => {
            const req = new Request(input, init);
            if (req.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
            return serveMcpRequest(REGISTRY, { ...callerFor(), clientKeyId }, req, JSON.parse(await req.clone().text()));
        };
        const client = new Client({ name: "test", version: "1" });
        await client.connect(new StreamableHTTPClientTransport(new URL(`${API}/mcp`), { fetch: fetchLike as never }));
        return client;
    }

    it("each read tool answers text plus structuredContent that validates against its advertised outputSchema", async () => {
        const client = await realClient();
        const { tools } = await client.listTools();
        const validator = new CfWorkerJsonSchemaValidator();
        const check = (name: string, result: any) => {
            const schema = tools.find((t) => t.name === name)!.outputSchema as never;
            const verdict = validator.getValidator(schema)(result.structuredContent);
            expect(verdict.valid, `${name}: ${verdict.errorMessage}`).toBe(true);
        };
        const search = (await client.callTool({ name: "search_library", arguments: { query: "cat" } })) as any;
        expect(search.isError).toBeFalsy();
        check("search_library", search);
        expect(search.structuredContent).toMatchObject({ view: "search", mode: "text", total: 3 });
        // the hidden post never shows; the private one has no picture
        expect(search.structuredContent.items.map((i: any) => i.id).sort()).toEqual(["CatPicture00004", "CatSecret000002", "CatVideo0000001"]);
        expect(search.content[0].text).toMatch(/^3 posts for “cat”/);

        const post = (await client.callTool({ name: "show_post", arguments: { id: "CatVideo0000001" } })) as any;
        expect(post.isError).toBeFalsy();
        check("show_post", post);
        expect(post.structuredContent.post).toMatchObject({ id: "CatVideo0000001", status: "public", bytes: 1000 });
        expect(post.content[0].text).toContain("cat on a shelf");

        const cols = (await client.callTool({ name: "list_collections", arguments: {} })) as any;
        expect(cols.isError).toBeFalsy();
        check("list_collections", cols);
        expect(cols.structuredContent.collections[0]).toMatchObject({ id: "ColCats", name: "Cats", posts: 2 });

        const links = (await client.callTool({ name: "list_share_links", arguments: {} })) as any;
        expect(links.isError).toBeFalsy();
        check("list_share_links", links);
        expect(links.structuredContent.links[0]).toMatchObject({ id: "SetCats", collection: "Cats", files: 2 });
        expect(links.content[0].text).toContain("All the cats · 2 files · SetCats · ");

        // the editor is not wired in this test: the tool answers an error the agent can read, never an exception
        const edit = (await client.callTool({ name: "show_edit", arguments: {} })) as any;
        if (edit.isError) expect(edit.content[0].text.length).toBeGreaterThan(0);
        else check("show_edit", edit);

        // a picture is refused up front by the webp tool
        const webp = (await client.callTool({ name: "convert_to_webp", arguments: { id: "CatPicture00004" } })) as any;
        expect(webp.isError).toBe(true);
        expect(webp.content[0].text).toMatch(/make_still/);
        await client.close();
    });
    // The signed preview, end to end: show_post through the real server, then GET the link it minted (MCP-APP-CONTRACT.md section 9).
    describe("signed previews", () => {
        const NOW = 1_800_000_000_000;
        const send = (req: Request) => handleRequest(req, env, container, { now: () => NOW, sleep: async () => {}, fixedLength: fixedLengthPair });
        const BYTES = new Uint8Array(Array.from({ length: 64 }, (_, i) => i));
        beforeEach(() => {
            (env.ORIGINALS as MemoryOriginals).objects.set("originals/CatSecret000002.mp4", { bytes: BYTES, contentType: "video/mp4", meta: {} });
            (env.MEDIA as MemoryMedia).objects.set("PosterSecret.jpg", { bytes: 4, meta: {}, contentType: "image/jpeg", data: new Uint8Array([1, 2, 3, 4]), viaStream: false });
            db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = 'CatSecret000002'").run(`${MEDIA}PosterSecret.jpg`);
        });
        const shown = async (clientKeyId: string) => {
            const client = await realClient(clientKeyId);
            const r = (await client.callTool({ name: "show_post", arguments: { id: "CatSecret000002" } })) as any;
            await client.close();
            expect(r.isError).toBeFalsy();
            // the signed links are in _meta only, never in structuredContent or the text the model reads
            expect(JSON.stringify(r.structuredContent) + r.content[0].text).not.toContain("/mcp/media/");
            const previews = r._meta["capystore/preview"];
            expect(previews.CatSecret000002).toMatchObject({ expires_at: new Date(NOW + 3_600_000).toISOString() });
            return previews.CatSecret000002 as { url: string; poster: string; thumb: string };
        };
        const get = (url: string) => send(new Request(url));

        it("a public key's link plays the private file; the poster link opens the poster and never the original", async () => {
            const p = await shown("key-1");
            expect(p.url).toMatch(new RegExp(`^${API}/mcp/media/[\\w-]+\\.[\\w-]{43}$`));
            const file = await get(p.url);
            expect(file.status).toBe(200);
            expect(new Uint8Array(await file.arrayBuffer())).toEqual(BYTES);
            const poster = await get(p.poster);
            expect(poster.status).toBe(200);
            expect(poster.headers.get("content-type")).toBe("image/jpeg");
            // the poster token on the file path, and the file token on the poster path, are refused
            expect((await get(p.poster.replace(/\/poster$/, ""))).status).toBe(403);
            expect((await get(`${p.url}/poster`)).status).toBe(403);
            expect(p.thumb).toBe(p.poster);
        });

        it("a revoked key and a key that is no longer the way in (private mode) stop playing", async () => {
            const p = await shown("key-1");
            expect((await get(p.url)).status).toBe(200);
            await setMcpMode(db as unknown as D1Database, "private", API, NOW);
            expect((await get(p.url)).status).toBe(403);
            await setMcpMode(db as unknown as D1Database, "public", API, NOW);
            expect((await get(p.url)).status).toBe(200);
            db.raw.prepare("UPDATE api_keys SET revoked_at = ? WHERE id = 'key-1'").run(NOW);
            expect((await get(p.url)).status).toBe(403);
        });

        it("the private link's previews play, and a rotated link kills them", async () => {
            await setMcpMode(db as unknown as D1Database, "private", API, NOW);
            const linkId = (db.raw.prepare("SELECT id FROM mcp_links WHERE revoked_at IS NULL").get() as { id: string }).id;
            const p = await shown(`link:${linkId}`);
            const file = await get(p.url);
            expect(file.status).toBe(200);
            expect(new Uint8Array(await file.arrayBuffer())).toEqual(BYTES);
            // a key's previews do not play while the private link is the way in
            expect((await get((await signedBy("key-1")).url)).status).toBe(403);
            await rotateMcpLink(db as unknown as D1Database, API, NOW);
            expect((await get(p.url)).status).toBe(403);
            expect((await get(p.poster)).status).toBe(403);
        });
        // a link minted while the key was the way in
        async function signedBy(keyId: string) {
            const { signPreviewToken, previewUrl } = await import("../src/mcp-preview");
            const token = await signPreviewToken(INTERNAL, { k: keyId, i: "CatSecret000002", e: NOW + 3_600_000, p: 0 });
            return { url: previewUrl(API, token) };
        }

        it("a hidden post's link is a 404 whatever the token says", async () => {
            const p = await shown("key-1");
            db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES ('CatSecret000002', 'hidden', 'you', NULL, ?)").run(NOW);
            expect((await get(p.url)).status).toBe(404);
        });
    });
});
