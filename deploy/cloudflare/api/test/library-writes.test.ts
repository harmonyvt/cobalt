// The chat's library writes (APP-API-CONTRACT.md 33.7, plan thread T3): cobalt.library.save (the save as the chat, its
// wait and the per-thread daily cap), title, visibility (public runs, private asks first), delete and deleteFile (always
// ask first: nothing runs until Harmony taps yes), and cobalt.queue. The Worker, the registry, the real handlers and the
// real SQL on node:sqlite run together; the Durable Object is a fake that keeps the confirm store for real.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import type { ChatModel, CodeRunner, ModelTurn } from "../src/chat";
import { sandboxModule } from "../src/chat-loader-module";
import { hashKey } from "../src/keys";
import { REGISTRY } from "../src/registry/index";
import { dailySaves } from "../src/registry/ops/library-writes";
import { handleChatPendingRoute } from "../src/registry/pending";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const DAY = 24 * 60 * 60 * 1000;

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let clock = 1_800_000_000_000;
let storage: Map<string, unknown>;
let doCalls: { path: string; key: string | null; body: string }[];
// what the fake Durable Object's advance answers for a save: "ready" stores the file, anything else stays saving
let saveOutcome: "ready" | "queued" | "error";

// ---- the fake Durable Object: POST /studio makes a session row, the advance finishes it ------------------------------

let sids = 0;
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
        const body = await req.text();
        doCalls.push({ path: `${req.method} ${u.pathname}`, key: req.headers.get("x-cobalt-key-id"), body });
        if (req.method === "POST" && u.pathname === "/studio") {
            const sid = `Save${String(++sids).padStart(18, "0")}`;
            const b = JSON.parse(body);
            db.raw
                .prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?, ?, ?, 'x', 'saving', ?, ?)")
                .run(sid, req.headers.get("x-cobalt-key-id"), b.url, clock, clock + 7 * DAY);
            return Response.json({ status: "saving", id: sid, url: `${API}/studio/${sid}`, queued: saveOutcome === "queued", queue_ahead: saveOutcome === "queued" ? 2 : null }, { status: 201 });
        }
        const adv = /^\/studio\/([A-Za-z0-9]{22})\/advance$/.exec(u.pathname);
        if (adv) {
            const sid = adv[1]!;
            if (saveOutcome === "ready") {
                db.raw.prepare("UPDATE studio_sessions SET status = 'ready', r2_key = ?, title = 'big reveal', content_type = 'video/mp4', bytes = 2048 WHERE id = ?").run(`originals/${sid}.mp4`, sid);
                db.raw
                    .prepare(
                        `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, key_id, session_id, visibility, created_at)
                         VALUES (?, 'private', 'saved', 'originals', ?, NULL, 'big reveal.mp4', 'video/mp4', 2048, ?, 'k', ?, 'private', ?)`,
                    )
                    .run(`F${sid.slice(-15)}`, `originals/${sid}.mp4`, "https://x.com/a/status/1", sid, clock);
                return Response.json({ status: "ready", id: sid, step: null });
            }
            if (saveOutcome === "error") {
                db.raw.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'error.studio.fetch_failed' WHERE id = ?").run(sid);
                return Response.json({ status: "error", id: sid, error: { code: "error.studio.fetch_failed" } });
            }
            return Response.json({ status: "saving", id: sid, step: "queued", queue_ahead: 2 });
        }
        if (u.pathname === "/studio/line") return Response.json({ status: "success", now: clock, running: null, entries: [], max: 50, wait_ms: 0 });
        return Response.json({ status: "error", error: { code: "error.api.generic" } }, { status: 500 });
    },
};

// ---- the sandbox and a scripted model (as in registry.test.ts) ---------------------------------------------------------

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
let script: ((seen: Seen) => ModelTurn)[];
const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
const code = (src: string): ModelTurn => ({ content: [{ type: "tool_use", id: `tu_${script.length}`, name: "run_code", input: { code: src } }], stop_reason: "tool_use" });
// the run's result (or error) as the model got it
const lastRun = (s: Seen) => JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);
const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, onText }) {
        const s = { system, messages: JSON.parse(JSON.stringify(messages)) };
        const next = script.shift();
        if (!next) throw new Error("script ran out");
        const r = next(s);
        for (const b of r.content) if (b.type === "text") onText(b.text);
        return r;
    },
    async title() {
        return null;
    },
};

const call = (path: string, init: RequestInit = {}) =>
    handleRequest(new Request(`${API}${path}`, init), env, container, { now: () => clock, chatModel: model, codeRunner: runner, fixedLength: undefined } as any);
const send = (path: string, method: string, body?: unknown) =>
    call(path, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
const events = async (r: Response) =>
    (await r.text())
        .split("\n\n")
        .filter((b) => b.startsWith("event: "))
        .map((b) => {
            const [e, d] = b.split("\n");
            return { event: e!.slice(7), data: JSON.parse(d!.slice(6)) };
        });

// One message whose single code run is `src`; returns the run as the model saw it and the reply's events.
async function ask(thread: string, src: string, reply = "ok") {
    let run: any = null;
    script = [() => code(src), (s) => ((run = lastRun(s)), say(reply))];
    const ev = await events(await send(`/chat/threads/${thread}/messages`, "POST", { text: "do it" }));
    expect(script).toHaveLength(0);
    return { run, ev };
}
const newThread = async () => ((await (await send("/chat/threads", "POST", {})).json()) as any).thread.id as string;

// A saved post: one original (private unless `pub`), its session id as the post id.
let n = 0;
function savedPost(o: { title?: string; pub?: boolean; files?: number } = {}) {
    n++;
    const sid = `Post${String(n).padStart(18, "0")}`;
    db.raw.prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?, 'key-1', ?, 'x', 'ready', ?, ?)").run(sid, `https://x.com/a/status/${n}`, clock - 1000, clock + 7 * DAY);
    const ids: string[] = [];
    const count = o.files ?? 1;
    for (let i = 0; i < count; i++) {
        const id = `I${String(n).padStart(4, "0")}${String(i).padStart(11, "0")}`;
        const key = count > 1 ? `originals/${sid}-${String(i).padStart(2, "0")}.mp4` : `originals/${sid}.mp4`;
        const pub = o.pub === true;
        const publicKey = `Pk${String(n).padStart(4, "0")}${i}abc.mp4`;
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, key_id, session_id, post_key, role, item_index, visibility, public_key, created_at)
                 VALUES (?, 'private', 'saved', 'originals', ?, ?, ?, 'video/mp4', 1000, ?, 'k', ?, ?, ?, ?, ?, ?, ?)`,
            )
            .run(id, key, pub ? `${MEDIA}${publicKey}` : null, `clip ${n}-${i}.mp4`, `https://x.com/a/status/${n}`, sid, sid, count > 1 ? "item" : null, count > 1 ? i : null, pub ? "public" : "private", pub ? publicKey : null, clock - 1000 + i);
        void originals.put(key, new Blob([new Uint8Array(1000)]).stream(), { httpMetadata: { contentType: "video/mp4" }, customMetadata: {} });
        ids.push(id);
    }
    if (o.title) db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, 'key-1', ?)").run(sid, o.title, clock);
    return { sid, ids };
}
const live = (id: string) => (db.raw.prepare("SELECT deleted_at FROM media_items WHERE id = ?").get(id) as { deleted_at: number | null }).deleted_at === null;

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    env = {
        API_URL: `${API}/`,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
    };
    clock = 1_800_000_000_000;
    storage = new Map();
    doCalls = [];
    saveOutcome = "ready";
    n = 0;
});

// ---- tests ----------------------------------------------------------------------------------------------------------

describe("cobalt.library.save", () => {
    it("saves as the chat (queued, never refused as busy), waits for it, and returns the new post", async () => {
        const t = await newThread();
        const { run } = await ask(t, `return await cobalt.library.save("https://x.com/a/status/1 ", { public: false, title: "the reveal" });`);
        expect(run.result).toMatchObject({ status: "ready", post_id: expect.stringMatching(/^Save/), kind: "video", files: 1, public: false, error: null, saves_left_today: 19 });
        // the post id is the library's own: the read tools find it
        expect(run.result.post_id).toBe(run.result.save_id);
        const create = doCalls.find((c) => c.path === "POST /studio")!;
        expect(create.key).toBe(`chat:${t}`);
        expect(JSON.parse(create.body)).toEqual({ url: "https://x.com/a/status/1", queue: true, public: false, title: "the reveal" });
        // one long-poll was enough
        expect(doCalls.filter((c) => c.path.endsWith("/advance"))).toHaveLength(1);
    });

    it("answers a save still in the line after the wait as queued, and a failed one with its code", async () => {
        const t = await newThread();
        saveOutcome = "queued";
        const q = await ask(t, `return await cobalt.library.save("https://x.com/a/status/2");`);
        expect(q.run.result).toMatchObject({ status: "queued", post_id: null, error: null });
        // 60 s of waiting = three long-polls of 20 s
        expect(doCalls.filter((c) => c.path.endsWith("/advance"))).toHaveLength(3);
        saveOutcome = "error";
        const e = await ask(t, `return await cobalt.library.save("https://x.com/a/status/3", { wait: 5 });`);
        expect(e.run.result).toMatchObject({ status: "error", error: "error.studio.fetch_failed", saves_left_today: 18 });
    });

    it("checks the link before anything is created", async () => {
        const t = await newThread();
        const { run } = await ask(t, `try { await cobalt.library.save("not a link"); } catch (e) { return e.message; }`);
        expect(run.result).toMatch(/^cobalt\.library\.save: url: must be one http\(s\) link/);
        expect(doCalls.filter((c) => c.path === "POST /studio")).toHaveLength(0);
    });

    it("stops at the thread's daily cap: 20 saves in any 24 hours, per thread", async () => {
        const t = await newThread();
        const other = await newThread();
        const row = db.raw.prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?, ?, 'https://x.com/', 'x', 'ready', ?, ?)");
        for (let i = 0; i < 20; i++) row.run(`Cap${String(i).padStart(19, "0")}`, `chat:${t}`, clock - DAY + 60_000 + i, clock + DAY);
        // a day-old save no longer counts, and other keys never do
        row.run(`Old${"0".repeat(19)}`, `chat:${t}`, clock - DAY - 1, clock + DAY);
        row.run(`App${"0".repeat(19)}`, "key-1", clock, clock + DAY);
        const capped = await ask(t, `try { await cobalt.library.save("https://x.com/a/status/9"); return "saved"; } catch (e) { return e.message; }`);
        expect(capped.run.result).toMatch(/already saved 20 links today \(the cap is 20\)/);
        expect(doCalls.filter((c) => c.path === "POST /studio")).toHaveLength(0);
        // another thread has its own cap
        const free = await ask(other, `return (await cobalt.library.save("https://x.com/a/status/9")).saves_left_today;`);
        expect(free.run.result).toBe(19);
        // a minute later the oldest of the 20 is a day old
        clock += 60_000 + 1;
        const next = await ask(t, `return (await cobalt.library.save("https://x.com/a/status/10")).status;`);
        expect(next.run.result).toBe("ready");
    });

    it("reads CHAT_DAILY_SAVES: a number, 0 turns chat saves off, junk is the default", () => {
        expect(dailySaves({})).toBe(20);
        expect(dailySaves({ CHAT_DAILY_SAVES: "5" })).toBe(5);
        expect(dailySaves({ CHAT_DAILY_SAVES: "0" })).toBe(0);
        expect(dailySaves({ CHAT_DAILY_SAVES: "lots" })).toBe(20);
        expect(dailySaves({ CHAT_DAILY_SAVES: "-1" })).toBe(20);
    });

    it("is the chat's only: no route, and the app's POST /studio is unchanged", async () => {
        expect(REGISTRY.op("library.save")?.route).toBeUndefined();
        const r = await send("/studio", "POST", { url: "see https://x.com/a/status/5 !" });
        expect(r.status).toBe(201);
        expect(doCalls[0]).toMatchObject({ path: "POST /studio", key: "key-1" });
        expect(JSON.parse(doCalls[0]!.body)).toEqual({ url: "https://x.com/a/status/5" });
        const log = db.raw.prepare("SELECT route, key_id, url_prefix, status FROM request_log").all();
        expect(log).toEqual([{ route: "POST /studio", key_id: "key-1", url_prefix: "https://x.com/a/status/5", status: 201 }]);
    });
});

describe("cobalt.library.title and visibility", () => {
    it("titles a post by its post id, and null clears it", async () => {
        const t = await newThread();
        const p = savedPost();
        const { run } = await ask(t, `const a = await cobalt.library.title(${JSON.stringify(p.sid)}, "  cat jumps  "); const b = (await cobalt.library.post(${JSON.stringify(p.sid)})).title; return { a, b };`);
        expect(run.result).toEqual({ a: { post_id: p.sid, title: "cat jumps" }, b: "cat jumps" });
        const cleared = await ask(t, `return await cobalt.library.title(${JSON.stringify(p.sid)}, null);`);
        expect(cleared.run.result).toEqual({ post_id: p.sid, title: null });
        const unknown = await ask(t, `try { await cobalt.library.title("nope", "x"); } catch (e) { return e.message; }`);
        expect(unknown.run.result).toMatch(/no post "nope"/);
    });

    it("making a post public just runs and returns its links", async () => {
        const t = await newThread();
        const p = savedPost();
        const { run } = await ask(t, `return await cobalt.library.visibility(${JSON.stringify(p.sid)}, true);`);
        expect(run.result).toMatchObject({ public: true, changed: 1, posts: [{ id: p.sid, links: [expect.stringMatching(/^https:\/\/media\.capybaraharmony\.com\//)] }] });
        expect(storage.size).toBe(0);
    });

    it("making posts private asks first, with the links it breaks, and runs on yes", async () => {
        const t = await newThread();
        const a = savedPost({ pub: true, title: "cat jumps" });
        const b = savedPost({ pub: true, files: 2 });
        db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at) VALUES ('1234567890123456789', ?, NULL, 'key-1', ?)").run(JSON.stringify([a.ids[0], b.ids[1]]), clock);
        const { run, ev } = await ask(t, `return await cobalt.library.visibility([${JSON.stringify(a.sid)}, ${JSON.stringify(b.sid)}], false);`, "asked (=^･ω･^=)");
        expect(run.result.pending_confirm).toMatchObject({ summary: "make 2 posts private", effect: { posts: 2, files: 3, public_links: 3, share_links: 1, titles: ["cat jumps", "clip 2-0.mp4"] } });
        const card = ev.find((e) => e.event === "confirm")!.data.confirm;
        expect(card).toMatchObject({ op: "library.visibility", status: "waiting" });
        // nothing changed yet
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items WHERE visibility = 'public'").get()).toEqual({ n: 3 });
        script = [() => say("done ฅ^•ﻌ•^ฅ")];
        await events(await send(`/chat/threads/${t}/confirm/${card.id}`, "POST", { answer: "yes" }));
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items WHERE visibility = 'public'").get()).toEqual({ n: 0 });
    });

    it("does not ask about a post that is already private", async () => {
        const t = await newThread();
        const p = savedPost();
        const { run } = await ask(t, `try { await cobalt.library.visibility(${JSON.stringify(p.sid)}, false); } catch (e) { return e.message; }`);
        expect(run.result).toMatch(/already private: nothing to ask/);
        expect(storage.size).toBe(0);
    });
});

describe("cobalt.library.delete and deleteFile", () => {
    it("pauses for a confirm card with what goes: nothing is deleted until yes", async () => {
        const t = await newThread();
        const p = savedPost({ title: "cat jumps", files: 3, pub: true });
        const { run, ev } = await ask(t, `const r = await cobalt.library.delete(${JSON.stringify(p.sid)}); let after = "ran"; try { await cobalt.library.list(); } catch (e) { after = e.message; } return { r, after };`);
        expect(run.result.r.pending_confirm).toMatchObject({
            summary: "delete “cat jumps” (3 files)",
            effect: { posts: 1, files: 3, bytes: 3000, public_links: 3, share_links: 0, titles: ["cat jumps"] },
        });
        expect(run.result.after).toMatch(/^waiting for Harmony/);
        expect(p.ids.every(live)).toBe(true);
        const card = ev.find((e) => e.event === "confirm")!.data.confirm;
        expect(card).toMatchObject({ op: "library.delete", summary: "delete “cat jumps” (3 files)", status: "waiting" });

        // no: still nothing deleted
        script = [() => say("kept it")];
        const no = await events(await send(`/chat/threads/${t}/confirm/${card.id}`, "POST", { answer: "no" }));
        expect(no[0]!.data.confirm.status).toBe("no");
        expect(p.ids.every(live)).toBe(true);
    });

    it("yes deletes every post on the card, as the chat", async () => {
        const t = await newThread();
        const a = savedPost();
        const b = savedPost({ files: 2 });
        const keep = savedPost();
        const { ev } = await ask(t, `return await cobalt.library.delete([${JSON.stringify(a.sid)}, ${JSON.stringify(b.sid)}]);`);
        const card = ev.find((e) => e.event === "confirm")!.data.confirm;
        expect(card.summary).toBe("delete 2 posts");
        let note = "";
        script = [
            (s) => {
                note = JSON.stringify(s.messages[s.messages.length - 1]);
                return say("gone (≧▽≦)");
            },
        ];
        await events(await send(`/chat/threads/${t}/confirm/${card.id}`, "POST", { answer: "yes" }));
        expect([...a.ids, ...b.ids].some(live)).toBe(false);
        expect(keep.ids.every(live)).toBe(true);
        expect(note).toContain('\\"deleted\\":[\\"' + a.sid);
        expect(note).toContain('\\"files\\":3');
    });

    it("refuses unknown posts before asking", async () => {
        const t = await newThread();
        const p = savedPost();
        const { run } = await ask(t, `try { await cobalt.library.delete([${JSON.stringify(p.sid)}, "nope"]); } catch (e) { return e.message; }`);
        expect(run.result).toMatch(/no post "nope"/);
        expect(storage.size).toBe(0);
    });

    it("deleteFile asks for one gallery item, and points at delete for an original", async () => {
        const t = await newThread();
        const g = savedPost({ files: 3, title: "three cats" });
        const { run, ev } = await ask(t, `return await cobalt.library.deleteFile(${JSON.stringify(g.ids[1])});`);
        expect(run.result.pending_confirm).toMatchObject({ summary: "delete “clip 1-1.mp4” from “three cats”", effect: { files: 1, bytes: 1000, public_links: 0 } });
        const card = ev.find((e) => e.event === "confirm")!.data.confirm;
        script = [() => say("done")];
        await events(await send(`/chat/threads/${t}/confirm/${card.id}`, "POST", { answer: "yes" }));
        expect(g.ids.map(live)).toEqual([true, false, true]);

        const single = savedPost();
        const t2 = await newThread();
        const r = await ask(t2, `try { await cobalt.library.deleteFile(${JSON.stringify(single.ids[0])}); } catch (e) { return e.message; }`);
        expect(r.run.result).toMatch(/delete the whole post with cobalt\.library\.delete/);
    });
});

describe("cobalt.queue", () => {
    it("reads the queue as the chat: the line is asked with the chat's key id", async () => {
        const t = await newThread();
        const { run } = await ask(t, `const q = await cobalt.queue(); return Object.keys(q);`);
        expect(run.result).toEqual(expect.arrayContaining(["line", "search", "posters"]));
        expect(doCalls.find((c) => c.path === "GET /studio/line")?.key).toBe(`chat:${t}`);
    });
});

describe("the system prompt", () => {
    it("tells the model it may change the library only when asked, and lists the writes", async () => {
        const t = await newThread();
        let system = "";
        script = [
            (s) => {
                system = s.system;
                return say("hi");
            },
        ];
        await events(await send(`/chat/threads/${t}/messages`, "POST", { text: "hi" }));
        expect(system).toContain("save(url: string, opts?: {");
        expect(system).toContain("Asks Harmony first");
        expect(system).toMatch(/only when Harmony asks/);
    });
});

