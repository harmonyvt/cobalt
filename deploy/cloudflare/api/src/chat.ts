// Chat (APP-API-CONTRACT.md section 27): threads with Claude Haiku about the library. The model has one
// tool, run_code: it writes JavaScript against the `cobalt` API (chat-tools.ts) and the Worker runs it
// in a fresh Dynamic Worker with no network (chat-loader.ts, "code mode"). A reply streams to the app
// as server-sent events and is saved in D1 (chat_threads, chat_messages, migration 0015). Keyed routes
// only. Free of Cloudflare imports so it runs under node in the tests (the runner and the model are
// injected).

import Anthropic from "@anthropic-ai/sdk";
import { assemblePosts, libraryHide, type AppDeps } from "./app-routes";
import { chatTools, loadPosts, picturesOf, recordsOf, TOOL_TYPES, type ChatCollect, type ChatToolDeps, type ChatTools } from "./chat-tools";
import type { EmbedClient } from "./embed";
import type { CodeRunner } from "./chat-limits";
export { CODE_CPU_MS, CODE_TIMEOUT_MS, MAX_TOOL_CALLS, type CodeRun, type CodeRunner } from "./chat-limits";
import { mintCollectionId } from "./share-collections";
import type { StudioReply } from "./studio";

export const CHAT_MODEL_DEFAULT = "claude-haiku-5-5";
export const CHAT_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const THREADS_MAX = 200;
export const MESSAGES_MAX = 200;
export const TITLE_MAX = 60;
export const TEXT_MAX = 4000;
export const USER_POSTS_MAX = 20;
export const MAX_CODE_RUNS = 8; // per reply
export const RESULT_MAX = 20_000; // chars of a run's result the model sees
export const STALE_MS = 3 * 60 * 1000; // a reply still running after this is answered as interrupted
export const HISTORY_MESSAGES = 40; // earlier messages replayed to the model
export const PING_MS = 15_000;
export const PROGRESS_MS = 2_000;
const STEP_CODE_MAX = 8000;
const STEP_RESULT_MAX = 2000;
const NEW_TITLE = "new chat";

// ---- injected pieces ----------------------------------------------------------------------------


export type ModelTurn = { content: any[]; stop_reason: string | null };
export type ChatModel = {
    model: string;
    turn(req: { system: string; tools: any[]; messages: any[]; onText: (delta: string) => void }): Promise<ModelTurn>;
    title(firstMessage: string, reply: string): Promise<string | null>;
};

export class ModelError extends Error {}

const TITLE_SCHEMA = {
    type: "object",
    properties: { title: { type: "string", description: "A short name for the chat, 2 to 6 words, lowercase, no quotes, at most 60 characters." } },
    required: ["title"],
    additionalProperties: false,
};

export function chatModelFrom(env: { ANTHROPIC_API_KEY?: string; ROAST_BASE_URL?: string; CHAT_MODEL?: string }): ChatModel | null {
    const apiKey = env.ANTHROPIC_API_KEY?.trim();
    if (!apiKey) return null;
    const baseURL = env.ROAST_BASE_URL?.trim() || undefined;
    const model = env.CHAT_MODEL?.trim() || CHAT_MODEL_DEFAULT;
    const client = new Anthropic({ apiKey, baseURL, maxRetries: 1, timeout: 90_000 });
    return {
        model,
        async turn({ system, tools, messages, onText }) {
            try {
                const stream = client.messages.stream({
                    model,
                    max_tokens: 4096,
                    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
                    tools,
                    messages,
                });
                stream.on("text", (d) => onText(d));
                const final = await stream.finalMessage();
                return { content: final.content as any[], stop_reason: final.stop_reason };
            } catch (e) {
                throw new ModelError(e instanceof Error ? e.message : String(e));
            }
        },
        async title(firstMessage, reply) {
            try {
                const r = await client.messages.create({
                    model,
                    max_tokens: 200,
                    output_config: { effort: "low", format: { type: "json_schema", schema: TITLE_SCHEMA } },
                    messages: [
                        {
                            role: "user",
                            content: `Name this chat.\n\nHarmony asked: ${firstMessage.slice(0, 1000)}\n\nThe answer began: ${reply.slice(0, 600)}`,
                        },
                    ],
                } as any);
                const text = (r.content as any[]).find((b) => b.type === "text")?.text;
                const t = text ? (JSON.parse(text) as { title?: unknown }).title : null;
                return typeof t === "string" ? t : null;
            } catch {
                return null;
            }
        },
    };
}

export type ChatDeps = {
    db: D1Database;
    app: AppDeps; // for the post shapes (GET /library?v=3)
    mediaBaseUrl: string;
    shareBaseUrl?: string;
    embed: EmbedClient | null;
    model: ChatModel;
    runner: CodeRunner;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    // keeps a reply going after the app goes away (ctx.waitUntil); absent in tests
    waitUntil?: (p: Promise<unknown>) => void;
    pingMs?: number;
};

// ---- rows and shapes ----------------------------------------------------------------------------

type ThreadRow = { id: string; title: string; titled_by: string; created_at: number; updated_at: number };
type MessageRow = {
    id: number;
    thread_id: string;
    role: string;
    text: string;
    post_ids: string;
    steps: string;
    api: string | null;
    status: string;
    error: string | null;
    created_at: number;
    updated_at: number;
};

export type Step = {
    id: string;
    kind: "code";
    status: "running" | "done" | "error";
    code: string;
    logs: string[];
    result: string | null;
    error: string | null;
    duration_ms: number | null;
};

const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });

const parse = <T>(s: string | null, fallback: T): T => {
    if (!s) return fallback;
    try {
        return JSON.parse(s) as T;
    } catch {
        return fallback;
    }
};

const codePoints = (s: string, max: number) => Array.from(s).slice(0, max).join("");

// eslint-disable-next-line no-control-regex
const oneLine = (s: string) => s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();

function cleanTitle(v: unknown): string | null {
    if (typeof v !== "string") return null;
    const t = oneLine(v).replace(/^["'“”]+|["'“”]+$/g, "").trim();
    if (t === "" || Array.from(t).length > TITLE_MAX) return null;
    return t;
}

const messageShape = (r: MessageRow, now: number) => {
    const stale = r.status === "running" && now - r.updated_at > STALE_MS;
    return {
        id: String(r.id),
        role: r.role,
        text: r.text,
        post_ids: parse<string[]>(r.post_ids, []),
        steps: parse<Step[]>(r.steps, []),
        status: stale ? "error" : r.status,
        error: stale ? "error.chat.interrupted" : r.error,
        created_at: r.created_at,
    };
};

async function threadShape(db: D1Database, t: ThreadRow) {
    const stats = await db
        .prepare(
            `SELECT COUNT(*) AS n, (SELECT text FROM chat_messages WHERE thread_id = ?1 AND text <> '' ORDER BY id DESC LIMIT 1) AS last
               FROM chat_messages WHERE thread_id = ?1`,
        )
        .bind(t.id)
        .first<{ n: number; last: string | null }>();
    return {
        id: t.id,
        title: t.title,
        created_at: t.created_at,
        updated_at: t.updated_at,
        preview: codePoints(oneLine(stats?.last ?? ""), 120),
        message_count: stats?.n ?? 0,
    };
}

const oneThread = async (db: D1Database, id: string) =>
    (await db.prepare("SELECT id, title, titled_by, created_at, updated_at FROM chat_threads WHERE id = ?1").bind(id).first<ThreadRow>()) ?? null;

// GET /library?v=3 post shapes for these post ids (the ones that still exist).
async function postsMap(d: ChatDeps, ids: string[]): Promise<Record<string, unknown>> {
    const uniq = [...new Set(ids)];
    if (uniq.length === 0) return {};
    const live = await loadPosts(d, uniq);
    if (live.length === 0) return {};
    const { posts } = await assemblePosts(
        d.app,
        live.map((p) => ({ post_key: p.record.id, latest: p.latest })),
        { v2: true, v3: true, hide: libraryHide(true, true), now: d.now() },
    );
    const out: Record<string, unknown> = {};
    for (const p of posts) if (Array.isArray(p.files) && p.files.length > 0) out[p.id] = p;
    return out;
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
    try {
        const b = await request.json();
        return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

// ---- CRUD ---------------------------------------------------------------------------------------

export async function listThreads(d: Pick<ChatDeps, "db">): Promise<StudioReply> {
    try {
        const { results } = await d.db
            .prepare(`SELECT id, title, titled_by, created_at, updated_at FROM chat_threads ORDER BY updated_at DESC, id DESC LIMIT ${THREADS_MAX}`)
            .all<ThreadRow>();
        const threads = [];
        for (const t of results) threads.push(await threadShape(d.db, t));
        return { status: 200, body: { status: "success", threads } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function createThread(d: Pick<ChatDeps, "db" | "now" | "randomBytes">, request: Request, keyId: string): Promise<StudioReply> {
    const b = await readBody(request);
    if (!b) return err(400, "error.chat.bad_request");
    const title = b.title === undefined ? NEW_TITLE : cleanTitle(b.title);
    if (title === null) return err(400, "error.chat.bad_request");
    try {
        const count = await d.db.prepare("SELECT COUNT(*) AS n FROM chat_threads").first<{ n: number }>();
        if ((count?.n ?? 0) >= THREADS_MAX) return err(409, "error.chat.too_many");
        const now = d.now();
        const row: ThreadRow = { id: mintCollectionId(d.randomBytes), title, titled_by: b.title === undefined ? "auto" : "user", created_at: now, updated_at: now };
        await d.db
            .prepare("INSERT INTO chat_threads (id, title, titled_by, key_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)")
            .bind(row.id, row.title, row.titled_by, keyId, now)
            .run();
        return { status: 201, body: { status: "success", thread: await threadShape(d.db, row) } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function getThread(d: ChatDeps, id: string): Promise<StudioReply> {
    try {
        const t = await oneThread(d.db, id);
        if (!t) return err(404, "error.chat.not_found");
        const { results } = await d.db
            .prepare("SELECT * FROM chat_messages WHERE thread_id = ?1 ORDER BY id")
            .bind(id)
            .all<MessageRow>();
        const now = d.now();
        const messages = results.map((r) => messageShape(r, now));
        const posts = await postsMap(d, messages.flatMap((m) => m.post_ids));
        return { status: 200, body: { status: "success", thread: await threadShape(d.db, t), messages, posts } };
    } catch (e) {
        console.error("[chat] read failed", String(e));
        return err(503, "error.api.generic");
    }
}

export async function renameThread(d: Pick<ChatDeps, "db" | "now">, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request);
    const title = cleanTitle(b?.title);
    if (!b || title === null) return err(400, "error.chat.bad_request");
    try {
        const t = await oneThread(d.db, id);
        if (!t) return err(404, "error.chat.not_found");
        const now = d.now();
        await d.db.prepare("UPDATE chat_threads SET title = ?2, titled_by = 'user', updated_at = ?3 WHERE id = ?1").bind(id, title, now).run();
        return { status: 200, body: { status: "success", thread: await threadShape(d.db, { ...t, title, titled_by: "user", updated_at: now }) } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function deleteThread(d: Pick<ChatDeps, "db">, id: string): Promise<StudioReply> {
    try {
        const t = await oneThread(d.db, id);
        if (!t) return err(404, "error.chat.not_found");
        await d.db.batch([
            d.db.prepare("DELETE FROM chat_messages WHERE thread_id = ?1").bind(id),
            d.db.prepare("DELETE FROM chat_threads WHERE id = ?1").bind(id),
        ]);
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// ---- the model's view ---------------------------------------------------------------------------

export function systemPrompt(now: number): string {
    return `You are Harmony the capybara, the mascot living inside cobalt, Harmony's private media saver. Harmony (the human) saves videos and pictures from X, TikTok, Instagram, YouTube and the like into their library, makes gallery share links, and sorts those links into collections. You chat with Harmony about that library: find things, count and summarize, compare, suggest what to share, and roast their taste when asked.

Be helpful first, with a dry, cheeky capybara humour and the odd emoji. Keep replies short; use markdown lists only when they help.

You see the library only through the run_code tool. It runs JavaScript (not TypeScript) as the body of an async function in a sandbox with no network: call the global \`cobalt\` API, compute what you need, and \`return\` a small result (an array of a few fields beats whole records). console.log works. Do as much as you can in one run: filter, sort and count in code instead of returning everything. Today is ${new Date(now).toISOString().slice(0, 10)}.

To show Harmony files, call cobalt.show(ids) in your code: they appear as thumbnails under your reply, so never paste ids or raw URLs into your text; refer to files by title. To see what a picture or video actually looks like, call cobalt.look(ids) and you get the pictures after the run. Never claim to have seen something you did not look at. Files Harmony attaches to a message are listed with it.

The API:
${TOOL_TYPES}`;
}

const RUN_CODE_TOOL = {
    name: "run_code",
    description:
        "Run JavaScript against Harmony's library. The code is the body of an async function: use await and `return` the result. The global `cobalt` object is the only API (see the system prompt for its types); there is no network, no fetch, no require or import. Returns { result, logs } or { error, logs }.",
    input_schema: {
        type: "object",
        properties: { code: { type: "string", description: "JavaScript, the body of an async function. Return the result." } },
        required: ["code"],
        additionalProperties: false,
    },
    cache_control: { type: "ephemeral" },
};

const attachedNote = (records: unknown[]) =>
    records.length > 0 ? `\n\n[Harmony attached ${records.length === 1 ? "this file" : "these files"}: ${JSON.stringify(records)}]` : "";

// Earlier pictures are replaced by a note: the model keeps what it said about them, not the pixels.
function stripImages(messages: any[]): any[] {
    return messages.map((m) => {
        if (!Array.isArray(m.content)) return m;
        return {
            ...m,
            content: m.content.map((b: any) =>
                b?.type === "tool_result" && Array.isArray(b.content)
                    ? { ...b, content: b.content.map((c: any) => (c?.type === "image" ? { type: "text", text: "[a picture you looked at earlier]" } : c)) }
                    : b?.type === "image"
                      ? { type: "text", text: "[a picture shown earlier]" }
                      : b,
            ),
        };
    });
}

// Consecutive turns of one role become one (a failed reply can leave two user turns in a row).
function mergeRoles(messages: any[]): any[] {
    const out: any[] = [];
    const blocks = (c: any) => (typeof c === "string" ? [{ type: "text", text: c }] : c);
    for (const m of messages) {
        const last = out[out.length - 1];
        if (last && last.role === m.role) last.content = [...blocks(last.content), ...blocks(m.content)];
        else out.push({ role: m.role, content: m.content });
    }
    return out;
}

async function history(d: ChatDeps, rows: MessageRow[]): Promise<any[]> {
    const msgs: any[] = [];
    let records = new Map<string, unknown>();
    const attached = [...new Set(rows.filter((r) => r.role === "user").flatMap((r) => parse<string[]>(r.post_ids, [])))];
    if (attached.length > 0) records = new Map((await recordsOf(d, attached)).map((r) => [r.id, r]));
    for (const r of rows) {
        if (r.role === "user") {
            const ids = parse<string[]>(r.post_ids, []);
            msgs.push({ role: "user", content: r.text + attachedNote(ids.flatMap((i) => (records.has(i) ? [records.get(i)] : []))) });
            continue;
        }
        const api = parse<any[] | null>(r.api, null);
        if (api && api.length > 0 && api[api.length - 1].role === "assistant") msgs.push(...stripImages(api));
        else if (r.text) msgs.push({ role: "assistant", content: r.text });
    }
    return msgs;
}

const clipStr = (s: string, max: number) => (s.length > max ? `${s.slice(0, max)}…` : s);

const stringify = (v: unknown): string => {
    try {
        return JSON.stringify(v) ?? "null";
    } catch {
        return String(v);
    }
};

// The saved turn must replay: it ends on an assistant turn whose tool calls all have results. A reply
// that stopped on a tool result (every run used up) or mid-way loses its last unanswered calls.
export function trimDangling(api: any[]): void {
    if (api.length > 0 && api[api.length - 1].role === "user") api.pop();
    const last = api[api.length - 1];
    if (!last || last.role !== "assistant" || !Array.isArray(last.content)) return;
    const kept = last.content.filter((b: any) => b.type !== "tool_use");
    if (kept.length === last.content.length) return;
    if (kept.some((b: any) => b.type === "text" && b.text)) last.content = kept;
    else {
        api.pop();
        trimDangling(api);
    }
}

// ---- POST /chat/threads/<id>/messages -----------------------------------------------------------

const sse = (event: string, data: unknown) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

export async function sendMessage(d: ChatDeps, request: Request, id: string): Promise<Response | StudioReply> {
    const b = await readBody(request);
    const text = typeof b?.text === "string" ? b.text.trim() : "";
    const rawIds = b?.post_ids === undefined ? [] : b.post_ids;
    if (
        !b ||
        text === "" ||
        text.length > TEXT_MAX ||
        !Array.isArray(rawIds) ||
        rawIds.length > USER_POSTS_MAX ||
        !rawIds.every((x) => typeof x === "string" && x.length > 0 && x.length <= 2048)
    ) {
        return err(400, "error.chat.bad_request");
    }
    let thread: ThreadRow | null;
    let earlier: MessageRow[];
    let userRow: MessageRow;
    let botRow: MessageRow;
    let postIds: string[];
    const now = d.now();
    try {
        thread = await oneThread(d.db, id);
        if (!thread) return err(404, "error.chat.not_found");
        const { results } = await d.db.prepare("SELECT * FROM chat_messages WHERE thread_id = ?1 ORDER BY id").bind(id).all<MessageRow>();
        if (results.length + 2 > MESSAGES_MAX) return err(409, "error.chat.full");
        const last = results[results.length - 1];
        if (last && last.status === "running" && now - last.updated_at <= STALE_MS) return err(409, "error.chat.busy");
        // a reply that died mid-way is closed as interrupted before the next one starts
        if (last && last.status === "running") {
            await d.db.prepare("UPDATE chat_messages SET status = 'error', error = 'error.chat.interrupted' WHERE id = ?1").bind(last.id).run();
            last.status = "error";
        }
        earlier = results.slice(-HISTORY_MESSAGES);
        const live = new Set((await loadPosts(d, [...new Set(rawIds as string[])])).map((p) => p.record.id));
        postIds = [...new Set(rawIds as string[])].filter((i) => live.has(i));
        userRow = (await d.db
            .prepare("INSERT INTO chat_messages (thread_id, role, text, post_ids, status, created_at, updated_at) VALUES (?1, 'user', ?2, ?3, 'done', ?4, ?4) RETURNING *")
            .bind(id, text, JSON.stringify(postIds), now)
            .first<MessageRow>())!;
        botRow = (await d.db
            .prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES (?1, 'assistant', '', 'running', ?2, ?2) RETURNING *")
            .bind(id, now)
            .first<MessageRow>())!;
        if (results.length === 0 && thread.titled_by === "auto") {
            await d.db.prepare("UPDATE chat_threads SET title = ?2, updated_at = ?3 WHERE id = ?1").bind(id, codePoints(oneLine(text), TITLE_MAX), now).run();
        } else {
            await d.db.prepare("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1").bind(id, now).run();
        }
        if (results.length === 0 && thread.titled_by === "auto") thread = { ...thread, title: codePoints(oneLine(text), TITLE_MAX), updated_at: now };
    } catch (e) {
        console.error("[chat] send failed", String(e));
        return err(503, "error.api.generic");
    }

    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    const enc = new TextEncoder();
    let open = true;
    const write = (chunk: string) => {
        if (!open) return;
        writer.write(enc.encode(chunk)).catch(() => {
            open = false; // the app went away; the reply carries on and is saved
        });
    };
    const ping = setInterval(() => write(": ping\n\n"), d.pingMs ?? PING_MS);

    const run = reply(d, { thread: thread!, earlier, userRow, botRow, text, postIds, emit: (e, v) => write(sse(e, v)) }).finally(() => {
        clearInterval(ping);
        if (open) writer.close().catch(() => {});
    });
    d.waitUntil?.(run);
    return new Response(readable, {
        status: 200,
        headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store", "x-accel-buffering": "no" },
    });
}

type ReplyCtx = {
    thread: ThreadRow;
    earlier: MessageRow[];
    userRow: MessageRow;
    botRow: MessageRow;
    text: string;
    postIds: string[];
    emit: (event: string, data: unknown) => void;
};

async function reply(d: ChatDeps, c: ReplyCtx): Promise<void> {
    const now = () => d.now();
    c.emit("user", { message: messageShape(c.userRow, now()) });
    c.emit("assistant", { message: messageShape(c.botRow, now()) });

    let text = "";
    const steps: Step[] = [];
    const api: any[] = [];
    const collect: ChatCollect = { look: [], show: [] };
    const toolDeps: ChatToolDeps = { db: d.db, mediaBaseUrl: d.mediaBaseUrl, shareBaseUrl: d.shareBaseUrl, embed: d.embed };
    let lastSave = now();
    const row = (status: string, error: string | null) => ({ ...c.botRow, text, post_ids: JSON.stringify(collect.show), steps: JSON.stringify(steps), status, error, updated_at: now() });
    const save = async (status: string, error: string | null) => {
        await d.db
            .prepare("UPDATE chat_messages SET text = ?2, post_ids = ?3, steps = ?4, api = ?5, status = ?6, error = ?7, updated_at = ?8 WHERE id = ?1")
            .bind(c.botRow.id, text, JSON.stringify(collect.show), JSON.stringify(steps), status === "running" ? null : JSON.stringify(api), status, error, now())
            .run();
    };
    const progress = async () => {
        if (now() - lastSave < PROGRESS_MS) return;
        lastSave = now();
        await save("running", null).catch(() => {});
    };

    try {
        const prior = await history(d, c.earlier);
        const records = await recordsOf(d, c.postIds);
        const pics = await picturesOf(d, c.postIds.slice(0, 4));
        const userContent: any[] = [
            ...[...pics.values()].map((url) => ({ type: "image", source: { type: "url", url } })),
            { type: "text", text: c.text + attachedNote(records) },
        ];
        const messages = mergeRoles([...prior, { role: "user", content: userContent }]);
        const system = systemPrompt(now());
        let runs = 0;
        let looked = 0;
        for (let turn = 0; turn <= MAX_CODE_RUNS + 1; turn++) {
            let started = false;
            const res = await d.model.turn({
                system,
                tools: [RUN_CODE_TOOL],
                messages: [...messages, ...api],
                onText: (delta) => {
                    if (!started && text !== "" && !/\s$/.test(text)) {
                        text += "\n\n";
                        c.emit("text", { delta: "\n\n" });
                    }
                    started = true;
                    text += delta;
                    c.emit("text", { delta });
                    void progress();
                },
            });
            api.push({ role: "assistant", content: res.content });
            const uses = res.content.filter((b: any) => b.type === "tool_use");
            if (res.stop_reason !== "tool_use" || uses.length === 0) break;

            const results: any[] = [];
            for (const u of uses) {
                if (u.name !== "run_code" || typeof u.input?.code !== "string") {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: "Only run_code exists, with { code: string }." });
                    continue;
                }
                if (runs >= MAX_CODE_RUNS) {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: "No more code runs in this reply: answer with what you have." });
                    continue;
                }
                runs++;
                const step: Step = { id: u.id, kind: "code", status: "running", code: clipStr(u.input.code, STEP_CODE_MAX), logs: [], result: null, error: null, duration_ms: null };
                steps.push(step);
                c.emit("step", { step });
                const shownBefore = collect.show.length;
                const t0 = Date.now();
                const out = await d.runner(u.input.code, chatTools(toolDeps, collect));
                step.duration_ms = Date.now() - t0;
                step.logs = out.logs.slice(0, 50).map((l) => clipStr(l, 500));
                step.status = out.error !== undefined ? "error" : "done";
                step.error = out.error ?? null;
                const full = out.error !== undefined ? null : stringify(out.result ?? null);
                step.result = full === null ? null : clipStr(full, STEP_RESULT_MAX);
                c.emit("step", { step });
                if (collect.show.length > shownBefore) {
                    const added = collect.show.slice(shownBefore);
                    c.emit("posts", { post_ids: added, posts: await postsMap(d, added) });
                }
                const body = out.error !== undefined
                    ? { error: out.error, logs: step.logs }
                    : { result: full!.length > RESULT_MAX ? `${full!.slice(0, RESULT_MAX)}… (cut: return less)` : out.result ?? null, logs: step.logs };
                const content: any[] = [{ type: "text", text: clipStr(stringify(body), RESULT_MAX + 2000) }];
                // pictures asked for with look() in this run
                const fresh = collect.look.slice(looked);
                looked = collect.look.length;
                if (fresh.length > 0) {
                    const urls = await picturesOf(d, fresh);
                    for (const pid of fresh) {
                        const url = urls.get(pid);
                        if (url) {
                            content.push({ type: "text", text: `Picture of post ${pid}:` });
                            content.push({ type: "image", source: { type: "url", url } });
                        } else content.push({ type: "text", text: `Post ${pid} has no picture to look at.` });
                    }
                }
                results.push({ type: "tool_result", tool_use_id: u.id, ...(out.error !== undefined ? { is_error: true } : {}), content });
            }
            api.push({ role: "user", content: results });
            await progress();
        }
        trimDangling(api);

        await save("done", null);
        let thread = c.thread;
        if (c.earlier.length === 0 && c.thread.titled_by === "auto" && text) {
            const named = cleanTitle(await d.model.title(c.text, text));
            if (named) {
                const t = now();
                const r = await d.db
                    .prepare("UPDATE chat_threads SET title = ?2, titled_by = 'model', updated_at = ?3 WHERE id = ?1 AND titled_by = 'auto'")
                    .bind(c.thread.id, named, t)
                    .run();
                if ((r.meta?.changes ?? 0) > 0) {
                    thread = { ...thread, title: named, titled_by: "model", updated_at: t };
                    c.emit("title", { thread: await threadShape(d.db, thread) });
                }
            }
        }
        await d.db.prepare("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1").bind(c.thread.id, now()).run();
        c.emit("done", { message: messageShape(row("done", null), now()), thread: await threadShape(d.db, { ...thread, updated_at: now() }) });
    } catch (e) {
        const code = e instanceof ModelError ? "error.chat.model" : "error.api.generic";
        console.error("[chat] reply failed", code, String(e));
        trimDangling(api);
        await save("error", code).catch(() => {});
        c.emit("error", { code, message: messageShape(row("error", code), now()) });
    }
}
