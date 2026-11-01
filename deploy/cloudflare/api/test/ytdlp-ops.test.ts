// The capystore MCP server (APP-API-CONTRACT.md section 35): POST /mcp speaks JSON-RPC with the chat's own tools, and
// upload_begin + PUT /mcp/upload/<token> put a local file into the library. The Worker, the registry, the real handlers
// and the real SQL on node:sqlite run together; the Durable Object is a fake.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { REGISTRY } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
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
let studioBodies: any[];
let boxCalls: { path: string; body: any }[];
let boxInfo: { status: number; body: unknown };

const container = {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);
        doCalls.push({ path: `${req.method} ${u.pathname}`, key: req.headers.get("x-cobalt-key-id") });
        if (req.method === "POST" && u.pathname === "/studio") {
            studioBodies.push(await req.json());
            return Response.json({ status: "error", error: { code: "error.studio.busy" } }, { status: 429 });
        }
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
    studioBodies = [];
    boxCalls = [];
    boxInfo = { status: 200, body: { status: "success", title: "Me at the zoo", duration: 19, playlist: null, formats: [] } };
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        YTDLP: ytdlpNamespace() as unknown as DurableObjectNamespace,
    };
});

function ytdlpNamespace() {
    const stub = {
        async fetch(input: string | Request, init?: RequestInit) {
            const req = typeof input === "string" ? new Request(input, init) : input;
            const u = new URL(req.url);
            const text = req.method === "POST" ? await req.text() : "";
            boxCalls.push({ path: `${req.method} ${u.pathname}`, body: text ? JSON.parse(text) : null });
            if (u.pathname === "/__start") return new Response(null, { status: 204 });
            if (u.pathname === "/info") return Response.json(boxInfo.body, { status: boxInfo.status });
            return new Response(null, { status: 404 });
        },
    };
    return { idFromName: (n: string) => n, get: () => stub };
}

const send = (req: Request) => handleRequest(req, env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });

const mcp = (body: unknown, headers: Record<string, string> = { authorization: `Bearer ${CLIENT}` }) =>
    send(new Request(`${API}/mcp`, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...headers }, body: JSON.stringify(body) }));

let nextId = 1;
async function rpc(method: string, params?: unknown): Promise<any> {
    const res = await mcp({ jsonrpc: "2.0", id: nextId++, method, ...(params === undefined ? {} : { params }) });
    expect(res.status).toBe(200);
    return res.json();
}
const call = async (name: string, args: Record<string, unknown> = {}) => (await rpc("tools/call", { name, arguments: args })).result;
const textOf = (result: any) => JSON.parse(result.content[0].text);

describe("yt-dlp tools (section 49.6)", () => {
    it("are offered while the box is deployed, and only then", async () => {
        let names = ((await rpc("tools/list")).result.tools as any[]).map((t) => t.name);
        expect(names).toEqual(expect.arrayContaining(["ytdlp_save", "ytdlp_info"]));
        delete env.YTDLP;
        names = ((await rpc("tools/list")).result.tools as any[]).map((t) => t.name);
        expect(names).not.toContain("ytdlp_save");
        expect(names).not.toContain("ytdlp_info");
        expect(REGISTRY.toolsFor("chat", { search: false, ytdlp: true }).map((o) => o.callName)).toEqual(expect.arrayContaining(["ytdlp.save", "ytdlp.info"]));
        expect(REGISTRY.toolsFor("chat", { search: false }).map((o) => o.callName)).not.toContain("ytdlp.save");
    });

    it("ytdlp_info starts the box, asks it, and answers what it said", async () => {
        const r = await call("ytdlp_info", { url: "https://www.youtube.com/watch?v=jNQXAC9IVRw" });
        expect(r.isError).toBeFalsy();
        expect(textOf(r)).toEqual({ title: "Me at the zoo", duration: 19, playlist: null, formats: [] });
        expect(boxCalls).toEqual([
            { path: "POST /__start", body: null },
            { path: "POST /info", body: { url: "https://www.youtube.com/watch?v=jNQXAC9IVRw" } },
        ]);
    });

    it("ytdlp_info passes the box's code on", async () => {
        boxInfo = { status: 422, body: { status: "error", error: { code: "error.api.link.unsupported" } } };
        const r = await call("ytdlp_info", { url: "https://a.test/x" });
        expect(r.isError).toBe(true);
        expect(r.content[0].text).toMatch(/error.api.link.unsupported/);
        const bad = await call("ytdlp_info", { url: "ftp://a.test/x" });
        expect(bad.isError).toBe(true);
    });

    it("ytdlp_save is a save with engine ytdlp; library_save takes engine too", async () => {
        await call("ytdlp_save", { url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", title: "zoo" });
        await call("library_save", { url: "https://a.test/v", engine: "ytdlp" });
        expect(studioBodies).toEqual([
            { url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", queue: true, title: "zoo", engine: "ytdlp" },
            { url: "https://a.test/v", queue: true, engine: "ytdlp" },
        ]);
    });
});
