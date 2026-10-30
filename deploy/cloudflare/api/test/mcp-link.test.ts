// The MCP's private link (APP-API-CONTRACT.md section 35.5): the mode switch, POST /mcp/k/<secret>, rotation, the
// settings routes and what upload links do when the mode changes. The Worker, the registry, the real handlers and the
// real SQL on node:sqlite run together; the Durable Object is a fake.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { mcpThreadId } from "../src/mcp";
import { MCP_LINK_SECRET_REGEX, MCP_LINK_THREAD_KEY, newLinkSecret } from "../src/mcp-link";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-1";

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let clock: number;

const container = {
    async fetch(req: Request): Promise<Response> {
        await req.body?.cancel().catch(() => {});
        if (new URL(req.url).pathname === "/studio/line") return Response.json({ status: "success", entries: [] });
        return Response.json({ status: "error", error: { code: "error.api.generic" } }, { status: 503 });
    },
};

beforeEach(async () => {
    clock = Date.UTC(2026, 9, 30, 3, 0, 0);
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(KEY_ID, "agent", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    };
});

const send = (req: Request) => handleRequest(req, env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });
const keyHeaders = { authorization: `Api-Key ${CLIENT}` };
const serviceHeaders = { "x-cobalt-service": INTERNAL };

const settings = async (headers: Record<string, string> = keyHeaders) => {
    const res = await send(new Request(`${API}/mcp/settings`, { headers }));
    expect(res.status).toBe(200);
    return (await res.json()) as any;
};
const setMode = async (mode: string, headers: Record<string, string> = keyHeaders) =>
    send(new Request(`${API}/mcp/settings`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ mode }) }));
const rotate = (headers: Record<string, string> = keyHeaders) => send(new Request(`${API}/mcp/settings/rotate`, { method: "POST", headers }));

const ping = { jsonrpc: "2.0", id: 1, method: "ping" };
const post = (url: string, body: unknown = ping, headers: Record<string, string> = {}) =>
    send(new Request(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) }));
const publicPing = () => post(`${API}/mcp`, ping, { authorization: `Bearer ${CLIENT}` });

async function turnOnPrivate(): Promise<string> {
    const res = await setMode("private");
    expect(res.status).toBe(200);
    const b = (await res.json()) as any;
    expect(b.link_url).toMatch(new RegExp(`^${API}/mcp/k/[A-Za-z0-9]{32}$`));
    return b.link_url;
}

describe("the mode", () => {
    it("starts public: /mcp with a key answers, as before; settings show no link", async () => {
        expect((await publicPing()).status).toBe(200);
        expect(await settings()).toEqual({ mode: "public", public_url: `${API}/mcp`, link: null });
    });
    it("is public when migration 0023 is not applied yet", async () => {
        db.raw.exec("DROP TABLE mcp_settings; DROP TABLE mcp_links;");
        expect((await publicPing()).status).toBe(200);
        expect((await settings()).mode).toBe("public");
    });
    it("private: the link answers, /mcp is a 404 even with a good key; off: both are 404", async () => {
        const link = await turnOnPrivate();
        expect((await post(link)).status).toBe(200);
        const pub = await publicPing();
        expect(pub.status).toBe(404);
        expect(((await pub.json()) as any).error.code).toBe("error.mcp.not_found");

        expect((await setMode("off")).status).toBe(200);
        expect((await post(link)).status).toBe(404);
        expect((await publicPing()).status).toBe(404);
        expect((await settings()).link).toBeNull();
    });
    it("leaving private revokes the link for good; turning it on again makes a new one", async () => {
        const first = await turnOnPrivate();
        expect((await (await setMode("public")).json()) as any).not.toHaveProperty("link_url");
        expect((await publicPing()).status).toBe(200);
        const second = await turnOnPrivate();
        expect(second).not.toBe(first);
        expect((await post(first)).status).toBe(404);
        expect((await post(second)).status).toBe(200);
    });
    it("the same mode again changes nothing and shows no link", async () => {
        const link = await turnOnPrivate();
        const again = (await (await setMode("private")).json()) as any;
        expect(again.link_url).toBeUndefined();
        expect((await post(link)).status).toBe(200);
    });
    it("a bad mode is a 400", async () => {
        const res = await setMode("everyone");
        expect(res.status).toBe(400);
        expect(((await res.json()) as any).error.code).toBe("error.mcp.mode");
    });
});

describe("the private link", () => {
    it("works with no header at all, runs as one stable MCP thread, and tools/call reaches the library", async () => {
        const link = await turnOnPrivate();
        const init = await post(link, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "claude-ai", version: "1" } } });
        expect(((await init.json()) as any).result.serverInfo.name).toBe("capystore");
        const list = await post(link, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "upload_begin", arguments: {} } });
        const up = JSON.parse(((await list.json()) as any).result.content[0].text);
        expect(up.upload_url).toMatch(`${API}/mcp/upload/`);
        const payload = JSON.parse(Buffer.from(new URL(up.upload_url).pathname.split("/").pop()!.split(".")[0]!, "base64url").toString());
        expect(payload.t).toBe(await mcpThreadId(MCP_LINK_THREAD_KEY));
        expect(payload.k).toMatch(/^link:/);
    });
    it("a wrong, malformed or old secret is the same 404 as off; a browser from elsewhere is refused", async () => {
        const link = await turnOnPrivate();
        expect((await post(`${API}/mcp/k/${newLinkSecret()}`)).status).toBe(404);
        expect((await post(`${API}/mcp/k/short`)).status).toBe(404);
        expect((await post(link, ping, { origin: "https://evil.example" })).status).toBe(403);
        expect((await post(link, ping, { origin: WEB })).status).toBe(200);
    });
    it("GET and DELETE on the link are 405", async () => {
        const link = await turnOnPrivate();
        for (const method of ["GET", "DELETE"]) expect((await send(new Request(link, { method }))).status).toBe(405);
    });
    it("rotating stops the old link at once and answers the new one; the thread stays the same", async () => {
        const first = await turnOnPrivate();
        const res = await rotate();
        expect(res.status).toBe(200);
        const b = (await res.json()) as any;
        expect(b.link_url).not.toBe(first);
        expect((await post(first)).status).toBe(404);
        expect((await post(b.link_url)).status).toBe(200);
        expect(b.settings.link.tail).toBe(b.link_url.slice(-4));
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM mcp_links WHERE revoked_at IS NULL").get()).toEqual({ n: 1 });
    });
    it("rotating outside private is a 409", async () => {
        const res = await rotate();
        expect(res.status).toBe(409);
        expect(((await res.json()) as any).error.code).toBe("error.mcp.not_private");
    });
    it("settings show the use without the secret: hint, last use, client name, today's count", async () => {
        const link = await turnOnPrivate();
        const secret = link.split("/").pop()!;
        let s = await settings();
        expect(s.link).toMatchObject({ tail: secret.slice(-4), made_at: clock, last_used_at: null, used_by: null, calls_today: 0 });
        expect(s.link.hint).toBe(`${API}/mcp/k/…${secret.slice(-4)}`);
        expect(JSON.stringify(s)).not.toContain(secret);
        await post(link, { jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "claude-ai\u0007" } } });
        clock += 1000;
        await post(link);
        s = await settings();
        expect(s.link).toMatchObject({ last_used_at: clock, used_by: "claude-ai", calls_today: 2 });
        // a new UTC day starts the count again
        clock += 24 * 3600 * 1000;
        expect((await settings()).link.calls_today).toBe(0);
        await post(link);
        expect((await settings()).link.calls_today).toBe(1);
        // only the hash is stored
        const row = db.raw.prepare("SELECT link_hash FROM mcp_links").get() as any;
        expect(row.link_hash).toBe(await hashKey(secret));
    });
    it("makes 32 base62 characters", () => {
        for (let i = 0; i < 50; i++) expect(newLinkSecret()).toMatch(MCP_LINK_SECRET_REGEX);
    });
});

describe("who may change it", () => {
    it("a client key and the web Worker's service may; no key may not", async () => {
        expect((await settings(serviceHeaders)).mode).toBe("public");
        expect((await setMode("off", serviceHeaders)).status).toBe(200);
        expect((await send(new Request(`${API}/mcp/settings`))).status).toBe(401);
        expect((await setMode("public", {})).status).toBe(401);
    });
    it("the MCP's agent never sees the settings ops", async () => {
        const res = await post(`${API}/mcp`, { jsonrpc: "2.0", id: 1, method: "tools/list" }, { authorization: `Bearer ${CLIENT}` });
        const names = ((await res.json()) as any).result.tools.map((t: any) => t.name);
        expect(names.filter((n: string) => n.startsWith("mcp"))).toEqual([]);
    });
});

describe("upload links follow the mode", () => {
    const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8]);
    const put = (url: string) =>
        send(new Request(url, { method: "PUT", headers: { "content-type": "image/png", "content-length": String(PNG.byteLength) }, body: PNG as unknown as BodyInit }));
    const begin = async (url: string, headers: Record<string, string> = {}) => {
        const res = await post(url, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "upload_begin", arguments: {} } }, headers);
        return JSON.parse(((await res.json()) as any).result.content[0].text).upload_url as string;
    };
    it("a link's upload works while it is live, and stops when it is rotated", async () => {
        const link = await turnOnPrivate();
        const up = await begin(link);
        expect((await put(up)).status).toBe(201);
        await rotate();
        expect((await put(up)).status).toBe(401);
    });
    it("a key's upload stops when the private link goes on", async () => {
        const up = await begin(`${API}/mcp`, { authorization: `Bearer ${CLIENT}` });
        await turnOnPrivate();
        expect((await put(up)).status).toBe(404);
        expect(originals.objects.size).toBe(0);
    });
});
