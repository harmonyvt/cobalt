// The capystore MCP server (APP-API-CONTRACT.md section 35): POST /mcp speaks JSON-RPC with the chat's own tools, and
// upload_begin + PUT /mcp/upload/<token> put a local file into the library. The Worker, the registry, the real handlers
// and the real SQL on node:sqlite run together; the Durable Object is a fake.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { MCP_SKIPPED_CALLS, mcpThreadId, mcpToolName, signUploadToken, UPLOAD_TOKEN_TTL_MS } from "../src/mcp";
import { REGISTRY } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { readFileSync } from "node:fs";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const UNKNOWN = "11111111-2222-4333-8444-555555555555";
const KEY_ID = "key-1";

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let clock: number;
let doCalls: { path: string; key: string | null }[];

const container = {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);
        doCalls.push({ path: `${req.method} ${u.pathname}`, key: req.headers.get("x-cobalt-key-id") });
        await req.body?.cancel().catch(() => {});
        if (u.pathname === "/studio/line") return Response.json({ status: "success", entries: [] });
        return Response.json({ status: "error", error: { code: "error.api.generic" } }, { status: 503 });
    },
};

beforeEach(async () => {
    clock = 1_800_000_000_000;
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(KEY_ID, "agent", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    doCalls = [];
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
    };
});

const send = (req: Request) => handleRequest(req, env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });

const mcp = (body: unknown, headers: Record<string, string> = { authorization: `Bearer ${CLIENT}` }) =>
    send(new Request(`${API}/mcp`, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...headers }, body: JSON.stringify(body) }));

let nextId = 1;
async function rpc(method: string, params?: unknown): Promise<any> {
    const res = await mcp({ jsonrpc: "2.0", id: nextId++, method, ...(params === undefined ? {} : { params }) });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    return res.json();
}
const call = async (name: string, args: Record<string, unknown> = {}) => (await rpc("tools/call", { name, arguments: args })).result;
const textOf = (result: any) => JSON.parse(result.content[0].text);

describe("POST /mcp: the protocol", () => {
    it("initialize answers the asked version, the tools capability and instructions", async () => {
        const r = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
        expect(r.result.protocolVersion).toBe("2025-06-18");
        expect(r.result.capabilities).toEqual({ tools: { listChanged: false } });
        expect(r.result.serverInfo.name).toBe("capystore");
        expect(r.result.instructions).toMatch(/upload_begin/);
        // an unknown version gets the newest one
        expect((await rpc("initialize", { protocolVersion: "1999-01-01" })).result.protocolVersion).toBe("2025-11-25");
    });
    it("a notification is a bodyless 202; ping, unknown methods and bad messages", async () => {
        const res = await mcp({ jsonrpc: "2.0", method: "notifications/initialized" });
        expect(res.status).toBe(202);
        expect(await res.text()).toBe("");
        expect((await rpc("ping")).result).toEqual({});
        expect((await rpc("resources/list")).error.code).toBe(-32601);
        const bad = (await (await mcp({ id: 1, method: "ping" })).json()) as any;
        expect(bad.error.code).toBe(-32600);
        const parse = await send(new Request(`${API}/mcp`, { method: "POST", headers: { authorization: `Bearer ${CLIENT}` }, body: "{nope" }));
        expect(parse.status).toBe(400);
        expect(((await parse.json()) as any).error.code).toBe(-32700);
    });
    it("a batch answers its requests in order", async () => {
        const res = await mcp([
            { jsonrpc: "2.0", id: "a", method: "ping" },
            { jsonrpc: "2.0", method: "notifications/initialized" },
            { jsonrpc: "2.0", id: "b", method: "ping" },
        ]);
        expect(((await res.json()) as any[]).map((r) => r.id)).toEqual(["a", "b"]);
    });
    it("GET and DELETE /mcp are 405 (no stream, no sessions)", async () => {
        for (const method of ["GET", "DELETE"]) {
            const res = await send(new Request(`${API}/mcp`, { method, headers: { authorization: `Bearer ${CLIENT}` } }));
            expect(res.status).toBe(405);
            expect(res.headers.get("allow")).toBe("POST");
        }
    });
});

describe("POST /mcp: who may call", () => {
    const ping = { jsonrpc: "2.0", id: 1, method: "ping" };
    it("Bearer and Api-Key both work with a live client key", async () => {
        expect((await mcp(ping, { authorization: `Bearer ${CLIENT}` })).status).toBe(200);
        expect((await mcp(ping, { authorization: `Api-Key ${CLIENT}` })).status).toBe(200);
    });
    it("no key, a malformed key, an unknown or revoked key: 401 with cobalt's codes", async () => {
        const code = async (headers: Record<string, string>) => {
            const res = await mcp(ping, headers);
            expect(res.status).toBe(401);
            return ((await res.json()) as any).error.code;
        };
        expect(await code({})).toBe("error.api.auth.key.missing");
        expect(await code({ authorization: `Basic ${CLIENT}` })).toBe("error.api.auth.key.not_api_key");
        expect(await code({ authorization: "Bearer nope" })).toBe("error.api.auth.key.invalid");
        expect(await code({ authorization: `Bearer ${UNKNOWN}` })).toBe("error.api.auth.key.invalid");
        db.raw.prepare("UPDATE api_keys SET revoked_at = 5").run();
        expect(await code({ authorization: `Bearer ${CLIENT}` })).toBe("error.api.auth.key.invalid");
    });
    it("a browser page from another origin is refused; the web app's origin is not", async () => {
        expect((await mcp(ping, { authorization: `Bearer ${CLIENT}`, origin: "https://evil.example" })).status).toBe(403);
        expect((await mcp(ping, { authorization: `Bearer ${CLIENT}`, origin: WEB })).status).toBe(200);
    });
});

describe("tools/list: the chat's tools", () => {
    it("is the chat AI's calls (same switches) minus the chat-only ones, plus upload_begin", async () => {
        const tools = (await rpc("tools/list")).result.tools as any[];
        const chat = REGISTRY.toolsFor("chat", { search: false, box: false })
            .filter((o) => !MCP_SKIPPED_CALLS.has(o.callName))
            .map((o) => mcpToolName(o.callName));
        expect(tools.map((t) => t.name)).toEqual([...chat, "upload_begin"]);
        expect(tools.map((t) => t.name)).toContain("library_list");
        expect(tools.map((t) => t.name)).toContain("make_webp");
        expect(tools.map((t) => t.name)).not.toContain("show");
        expect(tools.map((t) => t.name)).not.toContain("collage");
        expect(tools.map((t) => t.name)).not.toContain("jobs_onDone");
        // search is off on this server (no Space), the box too
        expect(tools.map((t) => t.name)).not.toContain("library_search");
        expect(tools.map((t) => t.name)).not.toContain("box_run");
        for (const t of tools) {
            expect(t.name).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
            expect(t.inputSchema.type).toBe("object");
            expect(t.description.length).toBeGreaterThan(10);
        }
        // ask-tier ops (confirm cards in the chat) are marked destructive
        const del = tools.find((t) => t.name === "library_delete");
        expect(del.annotations).toEqual({ destructiveHint: true, readOnlyHint: false });
        expect(del.description).toMatch(/check with the user/);
        expect(tools.find((t) => t.name === "library_list").annotations).toBeUndefined();
        // the chat itself never sees upload.begin
        expect(REGISTRY.toolsFor("chat", { search: true, box: true }).map((o) => o.callName)).not.toContain("upload.begin");
    });
    it("search shows up when the search Space is configured", async () => {
        env.EMBED_URL = "https://example.hf.space";
        env.EMBED_TOKEN = "t";
        const tools = (await rpc("tools/list")).result.tools as any[];
        expect(tools.map((t) => t.name)).toContain("library_search");
    });
});

describe("tools/call", () => {
    it("runs the op with its own schema; a bad argument or unknown tool is an error the agent can read", async () => {
        expect(textOf(await call("library_list"))).toEqual([]);
        const bad = await call("library_list", { limit: "lots" });
        expect(bad.isError).toBe(true);
        expect(bad.content[0].text).toMatch(/^library_list: limit/);
        const unknown = await rpc("tools/call", { name: "nope", arguments: {} });
        expect(unknown.error.code).toBe(-32602);
        const op = await call("library_post", { id: "Ab3dE6gH9jK2mN5p" });
        expect(op.isError).toBe(true);
        expect(op.content[0].text).toMatch(/no post/);
    });
    it("a route op reaches the Durable Object as the key's MCP thread, never with the client's key", async () => {
        const r = await call("queue");
        expect(r.isError).toBeUndefined();
        const thread = await mcpThreadId(KEY_ID);
        expect(doCalls).toContainEqual({ path: "GET /studio/line", key: `chat:${thread}` });
    });
    it("each key has its own stable thread", async () => {
        const a = await mcpThreadId("key-1");
        expect(a).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(await mcpThreadId("key-1")).toBe(a);
        expect(await mcpThreadId("key-2")).not.toBe(a);
    });
});

describe("upload_begin + PUT /mcp/upload/<token>", () => {
    const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8]);
    const put = (url: string, data: Uint8Array = PNG, type: string | null = "image/png") =>
        send(new Request(url, { method: "PUT", headers: { ...(type ? { "content-type": type } : {}), "content-length": String(data.byteLength) }, body: data as unknown as BodyInit }));

    it("mints a 15 minute link on the API host; the PUT stores the file as the MCP thread, and library_list sees it", async () => {
        const link = textOf(await call("upload_begin", { name: "cat.png", title: "a cat" }));
        expect(link.method).toBe("PUT");
        expect(link.upload_url).toMatch(new RegExp(`^${API}/mcp/upload/[A-Za-z0-9_.-]+\\?name=cat.png&title=a\\+cat$`));
        expect(link.expires_at).toBe(new Date(clock + UPLOAD_TOKEN_TTL_MS).toISOString());
        expect(link.curl).toContain(link.upload_url);
        expect(link.types).toContain("video/mp4");

        const res = await put(link.upload_url);
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.item).toMatchObject({ name: "cat.png", source: "upload", content_type: "image/png", bytes: PNG.byteLength });
        const row = db.raw.prepare("SELECT key_id FROM media_items WHERE id = ?").get(b.item.id) as any;
        expect(row.key_id).toBe(`chat:${await mcpThreadId(KEY_ID)}`);
        const log = db.raw.prepare("SELECT route FROM request_log").all() as any[];
        expect(log.map((l) => l.route)).toContain("PUT /mcp/upload");

        const list = textOf(await call("library_list"));
        expect(list).toHaveLength(1);
        expect(list[0]).toMatchObject({ title: "a cat", kind: "image" });
    });
    it("an expired, forged or malformed link, or one whose key was revoked, stores nothing", async () => {
        const { upload_url } = textOf(await call("upload_begin"));
        const thread = await mcpThreadId(KEY_ID);
        // forged: signed with another secret
        const forged = await signUploadToken("00000000-0000-4000-8000-000000000000", { k: KEY_ID, t: thread, e: clock + 60_000 });
        expect((await put(`${API}/mcp/upload/${forged}`)).status).toBe(401);
        // tampered: another thread under the real signature
        const [, sig] = new URL(upload_url).pathname.split("/").pop()!.split(".");
        const other = Buffer.from(JSON.stringify({ k: KEY_ID, t: "AAAAAAAAAAAAAAAA", e: clock + 60_000 })).toString("base64url");
        expect((await put(`${API}/mcp/upload/${other}.${sig}`)).status).toBe(401);
        // malformed: not even a route
        expect((await put(`${API}/mcp/upload/nope`)).status).toBe(404);
        // revoked key
        db.raw.prepare("UPDATE api_keys SET revoked_at = 5").run();
        expect((await put(upload_url)).status).toBe(401);
        db.raw.prepare("UPDATE api_keys SET revoked_at = NULL").run();
        // expired
        clock += UPLOAD_TOKEN_TTL_MS;
        const res = await put(upload_url);
        expect(res.status).toBe(401);
        expect(((await res.json()) as any).error.code).toBe("error.mcp.upload_link");
        expect(originals.objects.size).toBe(0);
    });
    it("a video with no content type (what `curl -T` sends) is typed by its bytes and opens a studio session as the thread", async () => {
        const clip = new Uint8Array(readFileSync(new URL("./fixtures/clip-portrait.mp4", import.meta.url)));
        const { upload_url } = textOf(await call("upload_begin", { name: "clip" }));
        const res = await put(upload_url, clip, null);
        const b = (await res.json()) as any;
        expect(b.item).toMatchObject({ name: "clip.mp4", content_type: "video/mp4", bytes: clip.byteLength });
        expect(doCalls).toContainEqual({ path: "POST /studio/upload/adopt", key: `chat:${await mcpThreadId(KEY_ID)}` });
    });
    it("the upload code's own rules hold: no length, a wrong type", async () => {
        const { upload_url } = textOf(await call("upload_begin"));
        expect((await put(upload_url, PNG, "text/plain")).status).toBe(415);
        expect(originals.objects.size).toBe(0);
    });
});
