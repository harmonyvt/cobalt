// Chat (APP-API-CONTRACT.md section 27): threads with Claude about the library, the model's code run
// against the `cobalt` tools, the reply streamed as server-sent events and saved in D1. A scripted model
// stands in for Claude Haiku and a plain async-function runner for the Dynamic Worker; the real SQL
// runs on node:sqlite.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { withBatch } from "./d1-batch";
import { MAX_CODE_RUNS, STALE_MS, systemPrompt, trimDangling, type ChatModel, type CodeRunner, type ModelTurn } from "../src/chat";
import { sandboxModule } from "../src/chat-loader-module";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const API = "https://api.capybaraharmony.com";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
let KEY_HASH = "";
let db: FakeD1;
let env: WorkerEnv;
let clock = 1_000_000;

const container = { fetch: async () => new Response("{}", { headers: { "content-type": "application/json" } }) };

// ---- fakes --------------------------------------------------------------------------------------

// Runs the code as an async function body with `cobalt` bound to the tools (what the sandbox does).
const runner: CodeRunner = async (code, tools) => {
    const logs: string[] = [];
    let calls = 0;
    const cobalt = new Proxy({}, { get: (_, name: string) => async (...args: unknown[]) => { calls++; const fn = tools[name]; if (!fn) throw new Error(`cobalt.${name} does not exist`); return JSON.parse(JSON.stringify((await fn(...args)) ?? null)); } });
    const fakeConsole = { log: (...a: unknown[]) => logs.push(a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")) };
    try {
        // eslint-disable-next-line @typescript-eslint/no-implied-eval
        const fn = new Function("cobalt", "console", `return (async () => {\n${code}\n})();`);
        const result = await fn(cobalt, fakeConsole);
        return { result: result === undefined ? null : JSON.parse(JSON.stringify(result)), logs, calls };
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e), logs, calls };
    }
};

type Seen = { system: string; messages: any[] };
let seen: Seen[];
let script: ((seen: Seen) => ModelTurn | Error)[];
let titled: string | null;

const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
const code = (id: string, src: string, text = ""): ModelTurn => ({
    content: [...(text ? [{ type: "text", text }] : []), { type: "tool_use", id, name: "run_code", input: { code: src } }],
    stop_reason: "tool_use",
});

const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, onText }) {
        const s = { system, messages: JSON.parse(JSON.stringify(messages)) };
        seen.push(s);
        const next = script.shift();
        if (!next) throw new Error("script ran out");
        const r = next(s);
        if (r instanceof Error) throw r;
        for (const b of r.content) if (b.type === "text") for (const part of b.text.match(/.{1,5}/gs) ?? []) onText(part);
        return r;
    },
    async title() {
        return titled;
    },
};

let n = 0;
const item = (over: Record<string, unknown>) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: `clip ${n}.mp4`,
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
        duration: 9.6,
        link: "https://x.com/someone/status/1",
        session_id: null,
        key_id: "k",
        created_at: 1_000 + n,
        deleted_at: null,
        poster: null,
        visibility: null,
        public_key: null,
        public_id: null,
        post_key: null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key)`,
        )
        .run(r as any);
    return r;
};

const call = (path: string, init: RequestInit = {}, deps: Record<string, unknown> = { chatModel: model, codeRunner: runner }) =>
    handleRequest(new Request(`${API}${path}`, init), env, container, { now: () => clock, ...deps } as any);

const send = (path: string, method: string, body?: unknown, deps?: Record<string, unknown>) =>
    call(path, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }, deps);

const jsonOf = async (r: Response) => {
    const t = await r.text();
    return t ? JSON.parse(t) : null;
};

const events = async (r: Response) => {
    const text = await r.text();
    return text
        .split("\n\n")
        .filter((b) => b.startsWith("event: "))
        .map((b) => {
            const [e, d] = b.split("\n");
            return { event: e!.slice(7), data: JSON.parse(d!.slice(6)) };
        });
};

const newThread = async () => (await jsonOf(await send("/chat/threads", "POST", {}))).thread;

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = withBatch(createFakeD1());
    seen = [];
    script = [];
    titled = "tiktok cat hunt";
    clock = 1_000_000;
    env = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
});

// ---- tests --------------------------------------------------------------------------------------

describe("chat: on and off", () => {
    it("advertises features.chat only with a model and a runner", async () => {
        const on = await jsonOf(await call("/capabilities", { headers: AUTH }));
        expect(on.features.chat).toBe(true);
        const off = await jsonOf(await call("/capabilities", { headers: AUTH }, { chatModel: model }));
        expect(off.features.chat).toBe(false);
        const noKey = await jsonOf(await call("/capabilities", { headers: AUTH }, { chatModel: null, codeRunner: runner }));
        expect(noKey.features.chat).toBe(false);
    });

    it("answers 404 error.chat.off without a runner, and refuses a missing key", async () => {
        const r = await call("/chat/threads", { headers: AUTH }, { chatModel: model });
        expect(r.status).toBe(404);
        expect((await jsonOf(r)).error.code).toBe("error.chat.off");
        expect((await call("/chat/threads")).status).toBe(401);
    });
});

describe("chat: threads", () => {
    it("creates, lists, renames and deletes", async () => {
        const created = await send("/chat/threads", "POST", {});
        expect(created.status).toBe(201);
        const t = (await jsonOf(created)).thread;
        expect(t).toMatchObject({ title: "new chat", message_count: 0, preview: "" });
        expect(t.id).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(created.headers.get("cache-control")).toBe("no-store");

        clock += 10;
        const renamed = await jsonOf(await send(`/chat/threads/${t.id}`, "PATCH", { title: "  memes  " }));
        expect(renamed.thread).toMatchObject({ id: t.id, title: "memes", updated_at: clock });

        const list = await jsonOf(await send("/chat/threads", "GET"));
        expect(list.threads.map((x: any) => x.id)).toEqual([t.id]);

        expect((await send(`/chat/threads/${t.id}`, "PATCH", { title: "x".repeat(61) })).status).toBe(400);
        expect((await send(`/chat/threads/${t.id}`, "PATCH", { title: "" })).status).toBe(400);
        expect((await send(`/chat/threads/${t.id}`, "DELETE")).status).toBe(200);
        const gone = await send(`/chat/threads/${t.id}`, "GET");
        expect(gone.status).toBe(404);
        expect((await jsonOf(gone)).error.code).toBe("error.chat.not_found");
        expect((await send("/chat/threads/short", "GET")).status).toBe(404);
    });
});

describe("chat: a reply", () => {
    it("streams text and a code step, shows files, saves everything and names the thread", async () => {
        const cat = item({ name: "cat falls off couch.mp4", link: "https://www.tiktok.com/@a/video/1", created_at: 5_000 });
        item({ name: "dog.mp4", link: "https://x.com/b/status/2", created_at: 6_000 });
        const t = await newThread();
        script = [
            () => code("tu_1", `const p = await cobalt.library({ source: "tiktok.com" });\nconsole.log(p.length);\nawait cobalt.show(p.map((x) => x.id));\nreturn p.map((x) => x.title);`, "Digging."),
            (s) => {
                const last = s.messages[s.messages.length - 1];
                expect(last.role).toBe("user");
                expect(last.content[0]).toMatchObject({ type: "tool_result", tool_use_id: "tu_1" });
                expect(JSON.parse(last.content[0].content[0].text)).toEqual({ result: ["cat falls off couch.mp4"], logs: ["1"] });
                return say("Found the cat 🐈");
            },
        ];
        const r = await send(`/chat/threads/${t.id}/messages`, "POST", { text: "find my tiktok cat" });
        expect(r.status).toBe(200);
        expect(r.headers.get("content-type")).toMatch(/^text\/event-stream/);
        const ev = await events(r);
        const names = ev.map((e) => e.event);
        expect(names[0]).toBe("user");
        expect(names[1]).toBe("assistant");
        expect(names.filter((x) => x === "step")).toHaveLength(2);
        expect(names.slice(-2)).toEqual(["title", "done"]);
        const text = ev.filter((e) => e.event === "text").map((e) => e.data.delta).join("");
        expect(text).toBe("Digging.\n\nFound the cat 🐈");
        const steps = ev.filter((e) => e.event === "step").map((e) => e.data.step);
        expect(steps[0]).toMatchObject({ id: "tu_1", status: "running", kind: "code" });
        expect(steps[1]).toMatchObject({ id: "tu_1", status: "done", logs: ["1"], result: '["cat falls off couch.mp4"]' });
        const posts = ev.find((e) => e.event === "posts")!.data;
        expect(posts.post_ids).toEqual([cat.link]); // a saved link's post id is its link
        expect(Object.keys(posts.posts)).toEqual([cat.link]);
        const done = ev[ev.length - 1]!.data;
        expect(done.message).toMatchObject({ role: "assistant", status: "done", text, post_ids: [cat.link] });
        expect(done.thread).toMatchObject({ title: "tiktok cat hunt", message_count: 2 });
        expect(seen[0]!.system).toContain("declare const cobalt");
        // this test server has no search Space: the model is told to match names and never shown search()
        expect(seen[0]!.system).toContain("search by meaning is off");
        expect(seen[0]!.system).not.toContain("search(query: string");

        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages.map((m: any) => [m.role, m.status])).toEqual([["user", "done"], ["assistant", "done"]]);
        expect(read.messages[1].steps).toHaveLength(1);
        expect(read.posts[cat.link].id).toBe(cat.link);
        expect(read.thread.title).toBe("tiktok cat hunt");
    });

    it("sends the real model's requests through the relay fetch from the Worker entry", async () => {
        const urls: string[] = [];
        const relay = async (input: any, init?: any) => {
            urls.push(new Request(input, init).url);
            return Response.json({ error: { type: "forbidden", message: "Request not allowed" } }, { status: 403 });
        };
        const t = await newThread();
        const r = await call(
            `/chat/threads/${t.id}/messages`,
            { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: JSON.stringify({ text: "hi" }) },
            { codeRunner: runner, modelFetch: relay },
        );
        // no chatModel injected: the Worker builds the real one from ANTHROPIC_API_KEY, with the relay
        env.ANTHROPIC_API_KEY = "sk-ant-test";
        const r2 = await call(
            `/chat/threads/${t.id}/messages`,
            { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: JSON.stringify({ text: "hi" }) },
            { codeRunner: runner, modelFetch: relay },
        );
        expect(r.status).toBe(404); // no key yet: chat is off
        const ev = await events(r2);
        expect(ev[ev.length - 1]!.event).toBe("error");
        expect(urls[0]).toBe("https://api.anthropic.com/v1/messages");
    });

    it("attaches a big result set as a collage and pages it", async () => {
        const cats = Array.from({ length: 70 }, (_, i) => item({ name: `cat ${i}.mp4`, link: `https://x.com/c/status/${i + 1}`, created_at: 10_000 + i }));
        item({ name: "dog.mp4", link: "https://x.com/d/status/999", created_at: 20_000 });
        const t = await newThread();
        script = [
            () => code("tu_1", `const p = await cobalt.library({ query: "cat" });\nreturn await cobalt.collage([...p.map((x) => x.id), "nope"], { title: "every cat", query: "cats" });`),
            (s) => {
                const last = s.messages[s.messages.length - 1];
                expect(JSON.parse(last.content[0].content[0].text).result).toBe(70);
                return say("70 cats nya~");
            },
        ];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "show me all my cats" }));
        expect(ev.find((e) => e.event === "collage")!.data).toEqual({ collage: { title: "every cat", query: "cats", total: 70 } });
        const done = ev[ev.length - 1]!.data.message;
        expect(done.collage).toEqual({ title: "every cat", query: "cats", total: 70 });
        expect(done.post_ids).toEqual([]);

        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages[0].collage).toBeNull();
        expect(read.messages[1].collage).toMatchObject({ total: 70 });

        const base = `/chat/threads/${t.id}/messages/${done.id}/collage`;
        const p1 = await jsonOf(await send(base, "GET"));
        expect(p1).toMatchObject({ status: "success", title: "every cat", query: "cats", total: 70, offset: 0, next: 30 });
        const newestFirst = [...cats].reverse().map((c) => c.link);
        expect(p1.post_ids).toEqual(newestFirst.slice(0, 30));
        expect(Object.keys(p1.posts)).toHaveLength(30);
        const p3 = await jsonOf(await send(`${base}?offset=60&limit=60`, "GET"));
        expect(p3).toMatchObject({ offset: 60, next: null });
        expect(p3.post_ids).toEqual(newestFirst.slice(60));

        expect((await send(`${base}?limit=61`, "GET")).status).toBe(400);
        expect((await send(`/chat/threads/${t.id}/messages/${read.messages[0].id}/collage`, "GET")).status).toBe(404);
        expect((await send(base, "POST")).status).toBe(404);
    });

    it("replays the earlier turn, tool calls included, on the next message", async () => {
        item({ name: "a.mp4" });
        const t = await newThread();
        script = [() => code("tu_1", "return 1"), () => say("one")];
        await (await send(`/chat/threads/${t.id}/messages`, "POST", { text: "count" })).text();
        script = [() => say("again")];
        await (await send(`/chat/threads/${t.id}/messages`, "POST", { text: "and now?" })).text();
        const msgs = seen[2]!.messages;
        expect(msgs.map((m: any) => m.role)).toEqual(["user", "assistant", "user", "assistant", "user"]);
        expect(msgs[1].content[0]).toMatchObject({ type: "tool_use", id: "tu_1" });
        expect(msgs[2].content[0]).toMatchObject({ type: "tool_result", tool_use_id: "tu_1" });
        expect(msgs[4].content[msgs[4].content.length - 1].text).toBe("and now?");
    });

    it("hands the model the pictures it asked to look at, and attached files with their pictures", async () => {
        const a = item({ name: "sunset.mp4", link: "https://x.com/a/status/10", poster: `${MEDIA}posters/abc.jpg` }).link;
        const b = item({ name: "no poster.mp4", link: "https://x.com/b/status/11" }).link;
        const t = await newThread();
        script = [() => code("tu_1", `return await cobalt.look([${JSON.stringify(a)}, ${JSON.stringify(b)}])`), () => say("pretty")];
        await (await send(`/chat/threads/${t.id}/messages`, "POST", { text: "what is this", post_ids: [a, "nope"] })).text();
        const first = seen[0]!.messages[0];
        expect(first.content[0]).toEqual({ type: "image", source: { type: "url", url: `${MEDIA}posters/abc.jpg` } });
        expect(first.content[1].text).toContain("sunset.mp4");
        const result = seen[1]!.messages[seen[1]!.messages.length - 1].content[0];
        expect(result.content.find((c: any) => c.type === "image")).toEqual({ type: "image", source: { type: "url", url: `${MEDIA}posters/abc.jpg` } });
        expect(result.content.some((c: any) => c.type === "text" && c.text.includes("has no picture"))).toBe(true);
        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages[0].post_ids).toEqual([a]); // the unknown id is dropped

        // later turns see a note instead of the pixels
        script = [() => say("still pretty")];
        await (await send(`/chat/threads/${t.id}/messages`, "POST", { text: "and?" })).text();
        const replay = JSON.stringify(seen[2]!.messages.slice(0, -1));
        expect(replay).not.toContain('"type":"image"');
        expect(replay).toContain("a picture you looked at earlier");
    });

    it("reports a failing run as an error step and an error tool result", async () => {
        const t = await newThread();
        script = [() => code("tu_1", "return await cobalt.nope()"), (s) => {
            const r = s.messages[s.messages.length - 1].content[0];
            expect(r.is_error).toBe(true);
            return say("oops");
        }];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "x" }));
        const step = ev.filter((e) => e.event === "step")[1]!.data.step;
        expect(step).toMatchObject({ status: "error", error: "cobalt.nope does not exist", result: null });
    });

    it("stops code after the limit and still answers", async () => {
        const t = await newThread();
        script = [...Array.from({ length: MAX_CODE_RUNS + 1 }, (_, i) => () => code(`tu_${i}`, "return 1")), () => say("done")];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "loop" }));
        expect(ev.filter((e) => e.event === "step" && e.data.step.status === "done")).toHaveLength(MAX_CODE_RUNS);
        expect(ev[ev.length - 1]!.event).toBe("done");
    });

    it("saves a model failure as an error message", async () => {
        const t = await newThread();
        const { ModelError } = await import("../src/chat");
        script = [() => new ModelError("overloaded")];
        const ev = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "hi" }));
        expect(ev[ev.length - 1]).toMatchObject({ event: "error", data: { code: "error.chat.model" } });
        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages[1]).toMatchObject({ status: "error", error: "error.chat.model" });
        // the thread keeps working
        script = [() => say("back")];
        const again = await events(await send(`/chat/threads/${t.id}/messages`, "POST", { text: "hi again" }));
        expect(again[again.length - 1]!.event).toBe("done");
        expect(seen[1]!.messages.map((m: any) => m.role)).toEqual(["user"]); // two user turns merged
    });

    it("refuses a second reply while one runs, and closes a stale one as interrupted", async () => {
        const t = await newThread();
        db.raw.prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES (?, 'assistant', '', 'running', ?, ?)").run(t.id, clock, clock);
        const busy = await send(`/chat/threads/${t.id}/messages`, "POST", { text: "hi" });
        expect(busy.status).toBe(409);
        expect((await jsonOf(busy)).error.code).toBe("error.chat.busy");
        clock += STALE_MS + 1;
        const read = await jsonOf(await send(`/chat/threads/${t.id}`, "GET"));
        expect(read.messages[0]).toMatchObject({ status: "error", error: "error.chat.interrupted" });
        script = [() => say("ok")];
        expect((await send(`/chat/threads/${t.id}/messages`, "POST", { text: "hi" })).status).toBe(200);
    });

    it("validates the message", async () => {
        const t = await newThread();
        for (const body of [{}, { text: "" }, { text: "x".repeat(4001) }, { text: "a", post_ids: "x" }, { text: "a", post_ids: Array(21).fill("p") }]) {
            expect((await send(`/chat/threads/${t.id}/messages`, "POST", body)).status).toBe(400);
        }
        expect((await send("/chat/threads/AAAAAAAAAAAAAAAA/messages", "POST", { text: "a" })).status).toBe(404);
    });
});

describe("chat: replay safety", () => {
    it("drops unanswered tool calls from a saved turn", () => {
        const api: any[] = [
            { role: "assistant", content: [{ type: "tool_use", id: "a" }] },
            { role: "user", content: [{ type: "tool_result", tool_use_id: "a" }] },
            { role: "assistant", content: [{ type: "text", text: "partial" }, { type: "tool_use", id: "b" }] },
            { role: "user", content: [{ type: "tool_result", tool_use_id: "b" }] },
        ];
        trimDangling(api);
        expect(api).toHaveLength(3);
        expect(api[2].content).toEqual([{ type: "text", text: "partial" }]);
        const bare: any[] = [{ role: "assistant", content: [{ type: "tool_use", id: "a" }] }];
        trimDangling(bare);
        expect(bare).toEqual([]);
    });
});

describe("chat: the sandbox module", () => {
    // The module chat-loader.ts hands the Worker Loader, evaluated here with a stand-in WorkerEntrypoint.
    const evaluate = async (src: string, tools: Record<string, (...a: any[]) => any>) => {
        const mod = sandboxModule(src).replace(/^import .*$/m, "").replace("export default class Run", "return class Run");
        // eslint-disable-next-line @typescript-eslint/no-implied-eval
        const Run = new Function("WorkerEntrypoint", mod)(class {});
        const d = {
            call: async (name: string, args: string) => {
                const fn = tools[name];
                if (!fn) return JSON.stringify({ error: `cobalt.${name} does not exist` });
                return JSON.stringify({ result: await fn(...JSON.parse(args)) });
            },
        };
        return new Run().evaluate(d);
    };

    it("runs the body, reaches the tools and captures logs", async () => {
        const r = await evaluate(`const xs = await cobalt.library({ limit: 2 });\nconsole.log("got", xs.length, { a: 1 });\nreturn xs;`, { library: async () => [1, 2] });
        expect(r).toEqual({ result: "[1,2]", logs: ['got 2 {"a":1}'] });
    });

    it("returns tool errors and thrown errors as error", async () => {
        expect(await evaluate("return await cobalt.nope()", {})).toEqual({ error: "cobalt.nope does not exist", logs: [] });
        expect(await evaluate("throw new Error('boom')", {})).toEqual({ error: "boom", logs: [] });
        expect(await evaluate("console.log('x')", {})).toEqual({ result: "null", logs: ["x"] });
    });
});

describe("the system prompt", () => {
    it("sends the model to the meaning search first when search is on", () => {
        const p = systemPrompt(Date.UTC(2026, 9, 18), true);
        expect(p).toContain("call cobalt.search(query) first");
        expect(p).toContain("search(query: string, limit?: number)");
        expect(p).toContain("fall back to library({ query })");
        expect(p).toContain("Today is 2026-10-18");
    });
    it("leaves search out entirely when it is off", () => {
        const p = systemPrompt(Date.UTC(2026, 9, 18), false);
        expect(p).toContain("search by meaning is off");
        expect(p).not.toContain("cobalt.search");
        expect(p).not.toContain("search(query");
        expect(p).toContain("library(opts?:");
    });
});
