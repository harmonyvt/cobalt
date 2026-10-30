// The op registry (APP-API-CONTRACT.md section 33): defineOp, route matching, the HTTP runner (auth like the gate,
// input checks, CORS and cache headers, Durable Object ops), the model's `cobalt` API (namespaced calls, old flat
// aliases, zod checks, the generated cheat sheet), and the ask tier: a call that pauses for a confirm card and the reply
// that resumes after Harmony answers. The real SQL runs on node:sqlite; the sandbox is the real module source.
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as z from "zod";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import type { ChatModel, CodeRunner, ModelTurn } from "../src/chat";
import { sandboxModule } from "../src/chat-loader-module";
import { hashKey } from "../src/keys";
import { defineOp, ok, OpError, REGISTRY, Registry, TOOL_TYPES, toolTypes } from "../src/registry/index";
import { CONFIRM_TTL_MS, handleChatPendingRoute } from "../src/registry/pending";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };

let KEY_HASH = "";
let db: FakeD1;
let env: WorkerEnv;
let clock = 1_000_000;
let doCalls: { path: string; key: string | null; auth: string | null; body: string }[];
let storage: Map<string, unknown>;

// The main Durable Object: the confirm store for real (handleChatPendingRoute on a Map), everything else recorded.
const container = {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);
        if (u.pathname.startsWith("/chat/pending/")) {
            return handleChatPendingRoute(
                {
                    get: async <T,>(k: string) => storage.get(k) as T | undefined,
                    put: async (k: string, v: unknown) => void storage.set(k, structuredClone(v)),
                    delete: async (k: string) => storage.delete(k),
                },
                req,
                clock,
            );
        }
        doCalls.push({ path: `${req.method} ${u.pathname}`, key: req.headers.get("x-cobalt-key-id"), auth: req.headers.get("authorization"), body: await req.text() });
        return Response.json({ status: "success", from: "do" });
    },
};

// The sandbox: the real module source chat-loader.ts hands the Worker Loader, with a stand-in WorkerEntrypoint and the
// Dispatcher's lookup (own keys only).
const runner: CodeRunner = async (code, tools) => {
    const mod = sandboxModule(code).replace(/^import .*$/m, "").replace("export default class Run", "return class Run");
    // eslint-disable-next-line @typescript-eslint/no-implied-eval
    const Run = new Function("WorkerEntrypoint", mod)(class {});
    let calls = 0;
    const d = {
        call: async (name: string, args: string) => {
            calls++;
            const fn = Object.prototype.hasOwnProperty.call(tools, name) ? tools[name] : undefined;
            if (!fn) return JSON.stringify({ error: `cobalt.${name} does not exist` });
            try {
                return JSON.stringify({ result: (await fn(...JSON.parse(args))) ?? null });
            } catch (e) {
                return JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
            }
        },
    };
    const r = await new Run().evaluate(d);
    return r.error !== undefined ? { error: r.error, logs: r.logs, calls } : { result: JSON.parse(r.result), logs: r.logs, calls };
};

type Seen = { system: string; messages: any[] };
let seen: Seen[];
let script: ((seen: Seen) => ModelTurn)[];
let failures: unknown[];
const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
const code = (id: string, src: string): ModelTurn => ({ content: [{ type: "tool_use", id, name: "run_code", input: { code: src } }], stop_reason: "tool_use" });
const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, onText }) {
        const s = { system, messages: JSON.parse(JSON.stringify(messages)) };
        seen.push(s);
        const next = script.shift();
        if (!next) throw new Error("script ran out");
        let r: ModelTurn;
        try {
            r = next(s);
        } catch (e) {
            // an expect() inside a scripted turn: fail the test, not just the reply
            failures.push(e);
            throw e;
        }
        for (const b of r.content) if (b.type === "text") onText(b.text);
        return r;
    },
    async title() {
        return null;
    },
};

// ---- a test registry: the real ops plus an ask op and a few HTTP ops ----------------------------------------------

let wiped: string[];
const wipeOp = defineOp({
    name: "test.wipe",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ name: z.string().min(1), count: z.number().int().min(1).max(10).optional() }),
    output: z.object({ wiped: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Wipe a thing.",
        params: ["name"],
        options: true,
        preview: async (_ctx, input) => ({ summary: `wipe ${input.name}`, effect: { things: input.count ?? 1 } }),
    },
    handler: async (ctx, input) => {
        wiped.push(`${input.name} by ${ctx.keyId}`);
        return ok({ wiped: input.name });
    },
});
const echoOp = defineOp({
    name: "test.echo",
    route: { method: "POST", path: "/test/echo/:id", params: { id: /^[a-z]{3}$/ } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: "error.test.bad_request",
    input: z.object({ id: z.string(), n: z.number().int() }),
    ai: { tier: "free", summary: "Echo.", call: "test.echo", params: ["id", "n"] },
    handler: async (ctx, input) => {
        if (input.n === 13) throw new OpError(409, "error.test.unlucky", "13 is unlucky");
        return ok({ status: "success", id: input.id, n: input.n, key: ctx.keyId, caller: ctx.caller });
    },
});
const openOp = defineOp({
    name: "test.open",
    route: { method: "GET", path: "/test/open" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: z.object({ q: z.string().optional() }),
    ai: { tier: "hidden", summary: "Open." },
    handler: async (ctx, input) => ok({ q: input.q ?? null, key: ctx.keyId }),
});
const doOp = defineOp({
    name: "test.do",
    route: { method: "PUT", path: "/test/do/:id" },
    auth: "key_or_service",
    runs: "durable_object",
    cors: false,
    input: z.object({ id: z.string() }),
    ai: { tier: "free", summary: "A Durable Object op.", params: ["id"] },
});
const TEST_REGISTRY = new Registry([...REGISTRY.ops, wipeOp, echoOp, openOp, doOp]);

// ---- world ----------------------------------------------------------------------------------------------------------

const call = (path: string, init: RequestInit = {}, deps: Record<string, unknown> = {}) =>
    handleRequest(new Request(`${API}${path}`, init), env, container, { now: () => clock, chatModel: model, codeRunner: runner, registry: TEST_REGISTRY, ...deps } as any);
const send = (path: string, method: string, body?: unknown, headers: Record<string, string> = AUTH) =>
    call(path, { method, headers: { ...headers, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
const jsonOf = async (r: Response) => {
    const t = await r.text();
    return t ? JSON.parse(t) : null;
};
const events = async (r: Response) =>
    (await r.text())
        .split("\n\n")
        .filter((b) => b.startsWith("event: "))
        .map((b) => {
            const [e, d] = b.split("\n");
            return { event: e!.slice(7), data: JSON.parse(d!.slice(6)) };
        });

let n = 0;
const item = (over: Record<string, unknown> = {}) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        name: `clip ${n}.mp4`,
        link: `https://x.com/someone/status/${n}`,
        created_at: 1_000 + n,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at)
             VALUES (?, 'private', 'saved', 'originals', ?, NULL, ?, 'video/mp4', 4096, 480, 560, 9.6, ?, 'k', ?)`,
        )
        .run(r.id, `originals/${r.id}.mp4`, r.name, r.link, r.created_at);
    return r;
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    clock = 1_000_000;
    doCalls = [];
    storage = new Map();
    seen = [];
    script = [];
    wiped = [];
    failures = [];
});
afterEach(() => {
    expect(failures).toEqual([]);
});

// ---- tests ----------------------------------------------------------------------------------------------------------

describe("defineOp and the registry", () => {
    it("refuses ops that cannot work and names that clash", () => {
        const base = { auth: "key" as const, runs: "worker" as const, cors: false, input: z.object({}), handler: async () => ok(null) };
        expect(() => defineOp({ ...base, name: "x", ai: { tier: "free", summary: "" } })).toThrow(/a route or ai.only/);
        expect(() => defineOp({ ...base, name: "x", ai: { tier: "hidden", summary: "", only: true } })).toThrow(/cannot be hidden/);
        expect(() => defineOp({ ...base, handler: undefined, name: "x", route: { method: "GET", path: "/x" }, ai: { tier: "hidden", summary: "" } })).toThrow(/needs a handler/);
        const a = defineOp({ ...base, name: "a", route: { method: "GET", path: "/a/:id" }, ai: { tier: "free", summary: "", aliases: ["b"] } });
        const a2 = defineOp({ ...base, name: "a2", route: { method: "GET", path: "/a/:other" }, ai: { tier: "free", summary: "" } });
        const b = defineOp({ ...base, name: "b", ai: { tier: "free", summary: "", only: true } });
        expect(() => new Registry([a, a])).toThrow(/defined twice/);
        expect(() => new Registry([a, a2])).toThrow(/route GET \/a\/:other is defined twice/);
        expect(() => new Registry([a, b])).toThrow(/chat call b is taken/);
    });

    it("matches whole paths, checks param patterns, and leaves everything else to the gate", () => {
        expect(TEST_REGISTRY.match("POST", "/test/echo/abc")).toMatchObject({ op: { name: "test.echo" }, params: { id: "abc" } });
        expect(TEST_REGISTRY.match("POST", "/test/echo/abcd")).toBeNull();
        expect(TEST_REGISTRY.match("POST", "/test/echo/abc/")).toBeNull();
        expect(TEST_REGISTRY.match("POST", "/test/echo")).toBeNull();
        expect(TEST_REGISTRY.match("GET", "/test/echo/abc")).toBeNull();
        expect(REGISTRY.match("GET", "/library")?.op.name).toBe("library.index");
        expect(REGISTRY.match("HEAD", "/library")).toBeNull();
        expect(REGISTRY.match("GET", "/library/")).toBeNull();
        expect(REGISTRY.match("POST", `/chat/threads/AbCdEfGh12345678/confirm/ZyXwVuTs98765432`)?.params).toEqual({ id: "AbCdEfGh12345678", cid: "ZyXwVuTs98765432" });
        expect(REGISTRY.match("POST", `/chat/threads/short/confirm/ZyXwVuTs98765432`)).toBeNull();
    });

    it("lists the chat's tools: free and ask, never hidden, search only while it is on", () => {
        const names = (search: boolean) => TEST_REGISTRY.toolsFor("chat", { search }).map((o) => o.callName);
        expect(names(true)).toEqual([
            "library.list",
            "library.search",
            "library.post",
            "look",
            "show",
            "collage",
            // section 34.6
            "rank",
            "links.list",
            "collections.list",
            "library.about",
            "library.about.set",
            "queue",
            "library.save",
            "library.title",
            "library.visibility",
            "library.delete",
            "library.deleteFile",
            // the make ops (registry/ops/make.ts, section 33.8)
            "make.webp",
            "make.still",
            "make.trim",
            "make.crop",
            "make.slideshow",
            "make.galleryImage",
            "edits.list",
            "edits.get",
            "edits.create",
            "edits.update",
            "edits.render",
            "edits.delete",
            "jobs.wait",
            "jobs.onDone",
            // T5 (33.9, 33.10)
            "links.create", "links.revoke", "collections.create", "collections.add", "collections.update", "collections.reroll",
            "collections.delete", "sets.list", "sets.create", "sets.add", "sets.update", "sets.delete",
            // section 36.5
            "links.private", "links.rotate",
            "stage.get", "stage.set", "stage.store", "stage.pool", "stage.items", "stage.action", "emotes.find", "emotes.save",
            "test.wipe",
            "test.echo",
            "test.do",
        ]);
        expect(names(false)).not.toContain("library.search");
        expect(TEST_REGISTRY.byCall("search")?.name).toBe("library.search");
        expect(TEST_REGISTRY.byCall("library")?.name).toBe("library.list");
        expect(TEST_REGISTRY.byCall("library.index")).toBeUndefined();
    });
});

describe("the registry over HTTP", () => {
    it("runs a keyed op: path params, JSON body, the key id, CORS and no-store", async () => {
        const r = await call("/test/echo/abc", { method: "POST", headers: { ...AUTH, origin: WEB, "content-type": "application/json" }, body: JSON.stringify({ n: 7, id: "ignored" }) });
        expect(r.status).toBe(200);
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(await r.json() as any).toEqual({ status: "success", id: "abc", n: 7, key: "key-1", caller: "key" });
    });

    it("refuses callers the way the gate does", async () => {
        const post = (headers: Record<string, string>) => call("/test/echo/abc", { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: '{"n":1}' });
        const missing = await post({ origin: WEB });
        expect(missing.status).toBe(401);
        expect(missing.headers.get("access-control-allow-origin")).toBe(WEB);
        expect((await missing.json() as any).error.code).toBe("error.api.auth.key.missing");
        expect((await (await post({ authorization: "Bearer x" })).json() as any).error.code).toBe("error.api.auth.key.not_api_key");
        expect((await (await post({ authorization: "Api-Key 11111111-2222-4333-8444-555555555555" })).json() as any).error.code).toBe("error.api.auth.key.invalid");
        // a "key" op is a 404 for the library service, with no body
        const service = await post({ "x-cobalt-service": INTERNAL });
        expect(service.status).toBe(404);
        expect(await service.text()).toBe("");
        // D1 down: fail closed
        db.breakIt();
        expect((await post(AUTH)).status).toBe(503);
    });

    it("answers a bad input with the op's code, and a handler's refusal with its status", async () => {
        const bad = await send("/test/echo/abc", "POST", { n: "seven" });
        expect(bad.status).toBe(400);
        expect(await bad.json() as any).toEqual({ status: "error", error: { code: "error.test.bad_request" } });
        const notJson = await call("/test/echo/abc", { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: "{" });
        expect(notJson.status).toBe(400);
        const unlucky = await send("/test/echo/abc", "POST", { n: 13 });
        expect(unlucky.status).toBe(409);
        expect((await unlucky.json() as any).error.code).toBe("error.test.unlucky");
        // the method and paths it does not have go to the gate (404)
        expect((await send("/test/echo/abc", "PUT", { n: 1 })).status).toBe(404);
        expect((await send("/test/echo/toolong", "POST", { n: 1 })).status).toBe(404);
    });

    it("runs an open op with no key, and forwards a Durable Object op with the key id but never the client's key", async () => {
        expect(await (await call("/test/open?q=hi")).json() as any).toEqual({ q: "hi", key: null });
        const r = await send("/test/do/x1", "PUT", { a: 1 });
        expect(r.status).toBe(200);
        expect(doCalls).toEqual([{ path: "PUT /test/do/x1", key: "key-1", auth: null, body: '{"a":1}' }]);
        doCalls = [];
        await send("/test/do/x1", "PUT", {}, { "x-cobalt-service": INTERNAL });
        expect(doCalls[0]).toMatchObject({ key: "service:library", auth: null });
    });

    it("leaves preflights to the gate", async () => {
        const r = await call("/test/echo/abc", { method: "OPTIONS", headers: { origin: "https://evil.example" } });
        expect(r.status).toBe(403);
    });
});

describe("the model's cobalt API", () => {
    it("is generated from the ops: namespaced, with named types, and search only while it is on", () => {
        expect(TOOL_TYPES).toContain("type Post = {");
        expect(TOOL_TYPES).toContain("  library: {\n");
        // section 34.6: search(query, { limit, within }); the old search(query, limit) still parses
        expect(TOOL_TYPES).toContain("search(query: string, opts?: {\n      limit?: number;");
        expect(TOOL_TYPES).toContain("within?: string | { collection: string } | { link: string } | { posts: string[] };");
        expect(TOOL_TYPES).toContain("why: string[]; // up to 3 of its tags or sound tags, closest to the query first");
        expect(TOOL_TYPES).toContain("about(key: string): Promise<{");
        expect(TOOL_TYPES).toContain("rank(hits: (string | {");
        expect(TOOL_TYPES).toContain("post(id: string): Promise<Post & { files: PostFile[] }>;");
        expect(TOOL_TYPES).toContain("look(ids: string[]): Promise<number>;");
        expect(TOOL_TYPES).toContain("collage(ids: string[], opts?: { title?: string; query?: string }): Promise<number>;");
        expect(TOOL_TYPES).toContain("limit?: number; // default 100, max 1000");
        expect(toolTypes(false)).not.toContain("search(");
        // hidden route ops are never shown
        // (edits.create is the editor's own free call, section 33.8; studio.create stays hidden)
        expect(TOOL_TYPES).not.toMatch(/index\(|query\(|map\(|made\(|upload\(|recent\(|\bstudio: \{/);
        // the chat's own reads and writes of section 33.7
        expect(TOOL_TYPES).toContain("queue(): Promise<unknown>;");
        expect(TOOL_TYPES).toContain("save(url: string, opts?: {");
        expect(TOOL_TYPES).toContain("delete(ids: string[]): Promise<{ deleted: string[]; files: number }>;");
        // an ask op says so
        expect(toolTypes(true, TEST_REGISTRY)).toContain("// Asks Harmony first: returns { pending_confirm }");
        expect(toolTypes(true, TEST_REGISTRY)).toContain("wipe(name: string, opts?: { count?: number }): Promise<{ wiped: string }>;");
    });

    it("answers namespaced calls and the old flat names alike, through the real sandbox source", async () => {
        const a = item({ name: "cat.mp4" });
        item({ name: "dog.mp4" });
        const t = (await jsonOf(await send("/chat/threads", "POST", {}))).thread;
        script = [
            () =>
                code(
                    "tu_1",
                    `const a = await cobalt.library.list({ query: "cat" });
                     const b = await cobalt.library({ query: "cat" });
                     const p = await cobalt.library.post(a[0].id);
                     const q = await cobalt.post(a[0].id);
                     const shown = await cobalt.show(a[0].id);
                     const l = await cobalt.links.list();
                     const c = await cobalt.collections();
                     const e = await cobalt.test.echo("abc", 4);
                     const d = await cobalt.test.do("x9");
                     return { a: a.map((x) => x.id), same: JSON.stringify(a) === JSON.stringify(b) && JSON.stringify(p) === JSON.stringify(q), files: p.files.length, shown, l, c, e, d };`,
                ),
            (s) => {
                const r = JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);
                expect(r.result).toEqual({
                    a: [a.link],
                    same: true,
                    files: 1,
                    shown: [a.link],
                    l: [],
                    c: [],
                    e: { status: "success", id: "abc", n: 4, key: `chat:${t.id}`, caller: "chat" },
                    d: { status: "success", from: "do" },
                });
                return say("ok");
            },
        ];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "cats" }));
        expect(ev[ev.length - 1]!.event).toBe("done");
        // the Durable Object op got the chat's key id and the input as JSON
        expect(doCalls).toEqual([{ path: "PUT /test/do/x9", key: `chat:${t.id}`, auth: null, body: '{"id":"x9"}' }]);
        expect(seen[0]!.system).toContain("cobalt.library.list({ query })");
    });

    it("shows the model a checked call's mistake as a thrown error it can read", async () => {
        const t = (await jsonOf(await send("/chat/threads", "POST", {}))).thread;
        script = [
            () =>
                code(
                    "tu_1",
                    `const out = [];
                     for (const f of [() => cobalt.library.list({ kind: "videos" }), () => cobalt.test.echo("abc", "x"), () => cobalt.test.echo("abc", 13), () => cobalt.nope.deeper()]) {
                       try { await f(); out.push("ran"); } catch (e) { out.push(e.message); }
                     }
                     return out;`,
                ),
            (s) => {
                const r = JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text).result;
                expect(r[0]).toMatch(/^cobalt\.library\.list: kind: /);
                expect(r[1]).toMatch(/^cobalt\.test\.echo: n: /);
                expect(r[2]).toBe("13 is unlucky");
                expect(r[3]).toBe("cobalt.nope.deeper does not exist");
                return say("ok");
            },
        ];
        await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "try" }));
        expect(script).toHaveLength(0);
    });
});

describe("the ask tier: confirm cards", () => {
    // One reply that asks to wipe "old clips": the run stops, the card is stored, the model says one line.
    const askReply = async () => {
        const t = (await jsonOf(await send("/chat/threads", "POST", {}))).thread;
        script = [
            () =>
                code(
                    "tu_1",
                    `const r = await cobalt.test.wipe("old clips", { count: 3 });
                     let after = "ran";
                     try { await cobalt.library.list(); } catch (e) { after = e.message; }
                     return { r, after };`,
                ),
            (s) => {
                const tr = JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);
                expect(tr.result.r.pending_confirm).toMatchObject({ summary: "wipe old clips", effect: { things: 3 } });
                expect(tr.result.after).toMatch(/^waiting for Harmony to answer the confirm card/);
                expect(tr.pending_confirm.id).toBe(tr.result.r.pending_confirm.id);
                expect(tr.note).toMatch(/confirm card/);
                return say("asked you to ok wiping 3 old clips (=^･ω･^=)");
            },
        ];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "wipe my old clips" }));
        return { t, ev };
    };

    it("pauses: nothing runs, the card is stored for 15 minutes and shown on the message", async () => {
        const { t, ev } = await askReply();
        expect(wiped).toEqual([]);
        const confirm = ev.find((e) => e.event === "confirm")!.data;
        expect(confirm.confirm).toMatchObject({ op: "test.wipe", summary: "wipe old clips", effect: { things: 3 }, status: "waiting", expires_at: clock + CONFIRM_TTL_MS });
        expect(storage.get(`chat:pending:${t.id}`)).toMatchObject({ id: confirm.confirm.id, op: "test.wipe", input: { name: "old clips", count: 3 }, message_id: confirm.message_id });
        const done = ev[ev.length - 1]!;
        expect(done.event).toBe("done");
        expect(done.data.message.confirm).toMatchObject({ id: confirm.confirm.id, status: "waiting" });
        expect(done.data.message.steps.map((s: any) => s.kind)).toEqual(["code", "confirm"]);
        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages[1].confirm.status).toBe("waiting");
        expect(read.messages[0].confirm).toBeNull();
        // a card nobody answered in time reads as expired
        clock += CONFIRM_TTL_MS + 1;
        expect((await jsonOf(await send(`/chat/threads/${t.id}`, "GET"))).messages[1].confirm.status).toBe("expired");
        const late = await send(`/chat/threads/${t.id}/confirm/${confirm.confirm.id}`, "POST", { answer: "yes" });
        expect(late.status).toBe(404);
        expect((await late.json() as any).error.code).toBe("error.chat.confirm_gone");
        expect(wiped).toEqual([]);
    });

    it("yes: runs the stored call as the chat, records it on the card, and the reply goes on", async () => {
        const { t, ev } = await askReply();
        const cid = ev.find((e) => e.event === "confirm")!.data.confirm.id;
        script = [
            (s) => {
                const last = s.messages[s.messages.length - 1];
                expect(last.role).toBe("user");
                const note = typeof last.content === "string" ? last.content : last.content.map((b: any) => b.text).join("");
                expect(note).toContain('Harmony tapped yes on the confirm card "wipe old clips"');
                expect(note).toContain('"wiped":"old clips"');
                return say("done, wiped them ฅ^•ﻌ•^ฅ");
            },
        ];
        const r = await call(`/chat/threads/${t.id}/confirm/${cid}`, { method: "POST", headers: { ...AUTH, origin: WEB, "content-type": "application/json" }, body: '{"answer":"yes"}' });
        expect(r.status).toBe(200);
        expect(r.headers.get("content-type")).toMatch(/^text\/event-stream/);
        expect(r.headers.get("access-control-allow-origin")).toBe(WEB);
        const cev = await events(r);
        expect(cev.map((e) => e.event)).toEqual(["confirm", "assistant", "text", "done"]);
        expect(cev[0]!.data.confirm).toMatchObject({ id: cid, status: "yes" });
        expect(wiped).toEqual([`old clips by chat:${t.id}`]);
        expect(storage.has(`chat:pending:${t.id}`)).toBe(false);

        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages.map((m: any) => m.role)).toEqual(["user", "assistant", "assistant"]);
        expect(read.messages[1].confirm.status).toBe("yes");
        expect(read.messages[1].steps[1]).toMatchObject({ kind: "confirm", status: "done", result: '{"result":{"wiped":"old clips"}}' });
        expect(read.messages[2]).toMatchObject({ text: "done, wiped them ฅ^•ﻌ•^ฅ", status: "done", confirm: null });

        // a card runs once
        const again = await send(`/chat/threads/${t.id}/confirm/${cid}`, "POST", { answer: "yes" });
        expect((await again.json() as any).error.code).toBe("error.chat.confirm_gone");
        expect(wiped).toHaveLength(1);

        // the next message replays the whole exchange, the confirm note included, as alternating turns
        script = [
            (s) => {
                const roles = s.messages.map((m: any) => m.role);
                for (let i = 1; i < roles.length; i++) expect(roles[i]).not.toBe(roles[i - 1]);
                expect(JSON.stringify(s.messages)).toContain("Harmony tapped yes");
                return say("hi");
            },
        ];
        await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "thanks" }));
        expect(script).toHaveLength(0);
    });

    it("no: drops the call and the reply goes on", async () => {
        const { t, ev } = await askReply();
        const cid = ev.find((e) => e.event === "confirm")!.data.confirm.id;
        script = [
            (s) => {
                expect(JSON.stringify(s.messages[s.messages.length - 1])).toContain("Nothing ran");
                return say("ok, kept them");
            },
        ];
        const cev = await events(await send(`/chat/threads/${t.id}/confirm/${cid}`, "POST", { answer: "no" }));
        expect(cev[0]!.data.confirm.status).toBe("no");
        expect(wiped).toEqual([]);
        expect((await jsonOf(await send(`/chat/threads/${t.id}`, "GET"))).messages[1].confirm.status).toBe("no");
    });

    it("checks the answer, the thread and the card id", async () => {
        const { t, ev } = await askReply();
        const cid = ev.find((e) => e.event === "confirm")!.data.confirm.id;
        expect((await (await send(`/chat/threads/${t.id}/confirm/${cid}`, "POST", { answer: "maybe" })).json() as any).error.code).toBe("error.chat.bad_request");
        expect((await (await send(`/chat/threads/ZZZZZZZZZZZZZZZZ/confirm/${cid}`, "POST", { answer: "yes" })).json() as any).error.code).toBe("error.chat.not_found");
        expect((await (await send(`/chat/threads/${t.id}/confirm/ZZZZZZZZZZZZZZZZ`, "POST", { answer: "yes" })).json() as any).error.code).toBe("error.chat.confirm_gone");
        // the wrong card id did not consume the real one
        expect(storage.has(`chat:pending:${t.id}`)).toBe(true);
        expect((await send(`/chat/threads/${t.id}/confirm/${cid}`, "POST", { answer: "yes" }, { "x-cobalt-service": INTERNAL })).status).toBe(404);
        expect((await send(`/chat/threads/${t.id}/confirm/${cid}`, "POST", { answer: "yes" }, {})).status).toBe(401);
        // chat off
        const off = await handleRequest(new Request(`${API}/chat/threads/${t.id}/confirm/${cid}`, { method: "POST", headers: AUTH, body: '{"answer":"yes"}' }), env, container, { now: () => clock, chatModel: null, codeRunner: runner, registry: TEST_REGISTRY } as any);
        expect((await off.json() as any).error.code).toBe("error.chat.off");
        expect(wiped).toEqual([]);
    });

    it("the confirm store only answers the Worker's own key id for that thread", async () => {
        const st = { get: async () => undefined, put: async () => {}, delete: async () => true };
        const put = (key: string | null) =>
            handleChatPendingRoute(st, new Request("https://do.internal/chat/pending/AbCdEfGh12345678", { method: "PUT", headers: key ? { "x-cobalt-key-id": key } : {}, body: "{}" }), 0);
        expect((await put(null)).status).toBe(404);
        expect((await put("key-1")).status).toBe(404);
        expect((await put("chat:ZZZZZZZZZZZZZZZZ")).status).toBe(404);
        expect((await put("chat:AbCdEfGh12345678")).status).toBe(400); // right caller, bad record
        // and the internet never reaches it
        expect((await call("/chat/pending/AbCdEfGh12345678", { method: "PUT", headers: AUTH, body: "{}" })).status).toBe(404);
    });
});
