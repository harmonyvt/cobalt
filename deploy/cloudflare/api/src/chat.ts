// Chat (APP-API-CONTRACT.md section 27): threads with Claude Haiku about the library. The model has one
// tool, run_code: it writes JavaScript against the `cobalt` API (chat-tools.ts) and the Worker runs it
// in a fresh Dynamic Worker with no network (chat-loader.ts, "code mode"). A reply streams to the app
// as server-sent events and is saved in D1 (chat_threads, chat_messages, migration 0015). Keyed routes
// only. Free of Cloudflare imports so it runs under node in the tests (the runner and the model are
// injected).

import Anthropic from "@anthropic-ai/sdk";
import { assemblePosts, libraryHide, type AppDeps } from "./app-routes";
import { hiddenPostKeys } from "./hidden-store";
import { lookBlocks, lookImages, type LookDeps } from "./look-pictures";
import { chatTools, loadPosts, picturesOf, recordsOf, type ChatCollect, type ChatToolDeps, type ChatTools, type Ranked } from "./chat-tools";
import { chatToolbox, runConfirmed } from "./registry/ai";
import type { OpBase } from "./registry/context";
import { toolTypes } from "./registry/index";
import { cardPostIds, postIdsOf, type ToolCall } from "./chat-cards";
import type { PendingConfirm, PendingPort } from "./registry/pending";
import type { Registry } from "./registry/registry";
import type { EmbedClient } from "./embed";
import { CODE_TIMEOUT_BOX_MS, type CodeRunner } from "./chat-limits";
import { workbenchOn } from "./workbench-rules";
import type { ModelFetch } from "./model-fetch";
import type { JobEnded, JobsPort, ResumeOutcome } from "./chat-jobs";
import {
    AGENT_TURNS_MAX,
    agentRow,
    dropAgents,
    dropAllAgents,
    isMissingTable,
    pullMail,
    setAgent,
    takeMail,
    unreadCount,
    whoOf,
    agentNames,
    mailNote,
    type AgentsPort,
    type AgentTickOutcome,
} from "./chat-agents";
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

export function chatModelFrom(
    env: { ANTHROPIC_API_KEY?: string; ROAST_BASE_URL?: string; CHAT_MODEL?: string },
    modelFetch?: ModelFetch,
): ChatModel | null {
    const apiKey = env.ANTHROPIC_API_KEY?.trim();
    if (!apiKey) return null;
    const baseURL = env.ROAST_BASE_URL?.trim() || undefined;
    const model = env.CHAT_MODEL?.trim() || CHAT_MODEL_DEFAULT;
    const client = new Anthropic({ apiKey, baseURL, maxRetries: 1, timeout: 90_000, ...(modelFetch ? { fetch: modelFetch } : {}) });
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
    // the reply's Live Activity on the owner's other devices (section 27.9, chat-live.ts); absent when push is off
    liveFor?: (thread: string, prompt: string) => { event(name: string, data: unknown): void; close(): Promise<void> };
    // The op registry (section 33): the model's `cobalt` API and cheat sheet come from it. Without it (older callers)
    // the read tools of chat-tools.ts are called directly, under their flat names.
    registry?: Registry;
    base?: OpBase;
    // where `ask` calls wait for Harmony (the main Durable Object); null: confirm cards are off
    pending?: PendingPort | null;
    // where cobalt.jobs.onDone hands jobs (the thread's ChatJobs Durable Object, section 33.14); null: the hook is off
    jobs?: JobsPort | null;
    // sub-agents (section 43): wakes an agent's runner (the ChatAgent Durable Object); null: cobalt.agents is off
    agents?: AgentsPort | null;
    // set when this reply is a sub-agent's own (it runs in the agent's Durable Object)
    agentOf?: { id: string; parent: string; name: string } | null;
};

// ---- rows and shapes ----------------------------------------------------------------------------

type ThreadRow = { id: string; title: string; titled_by: string; created_at: number; updated_at: number };
type MessageRow = {
    id: number;
    thread_id: string;
    role: string;
    text: string;
    post_ids: string;
    collage?: string | null;
    // section 34.6 (migration 0022): cobalt.rank's scored list
    ranked?: string | null;
    steps: string;
    api: string | null;
    status: string;
    error: string | null;
    created_at: number;
    updated_at: number;
};

// A confirm card (section 33.5): an `ask` call waiting for Harmony, and what became of it.
export type ConfirmCard = {
    id: string;
    op: string;
    summary: string;
    effect: Record<string, unknown>;
    status: "waiting" | "yes" | "no" | "expired";
    expires_at: number;
};

// A job the model handed to the server (section 33.14) and what became of it.
export type JobCard = {
    job: string;
    note: string | null;
    status: "waiting" | "done" | "error" | "cancelled" | "timeout";
};

export type Step = {
    id: string;
    kind: "code" | "confirm" | "job";
    status: "running" | "done" | "error";
    code: string;
    logs: string[];
    result: string | null;
    error: string | null;
    duration_ms: number | null;
    // kind "confirm" only
    confirm?: ConfirmCard;
    // kind "job" only (status "running" while the server waits for it)
    job?: JobCard;
    // kind "code": every cobalt.* call of the run, with its card (section 38); absent on older messages
    calls?: ToolCall[];
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

type CollageRow = { title: string | null; query?: string | null; ids: string[] };
const collageShape = (s: string | null) => {
    const c = parse<CollageRow | null>(s, null);
    return c && Array.isArray(c.ids) && c.ids.length > 0 ? { title: c.title ?? null, query: c.query ?? null, total: c.ids.length } : null;
};

// cobalt.rank's list (section 34.6), as the app reads it: null when there is none.
const rankedShape = (s: string | null | undefined) => {
    const r = parse<Ranked | null>(s ?? null, null);
    if (!r || !Array.isArray(r.hits) || r.hits.length === 0) return null;
    return {
        title: r.title ?? null,
        query: r.query ?? null,
        within: r.within ?? null,
        hits: r.hits.map((h) => ({ post_id: h.post_id, score: typeof h.score === "number" ? h.score : null, why: Array.isArray(h.why) ? h.why : [] })),
    };
};
const rankedIds = (s: string | null | undefined) => rankedShape(s)?.hits.map((h) => h.post_id) ?? [];

// The message's confirm card (its last confirm step), with a card nobody answered in time shown as expired.
const confirmOf = (steps: Step[], now: number): ConfirmCard | null => {
    const c = [...steps].reverse().find((s) => s.kind === "confirm" && s.confirm)?.confirm ?? null;
    return c && c.status === "waiting" && c.expires_at <= now ? { ...c, status: "expired" } : c;
};

const messageShape = (r: MessageRow, now: number) => {
    const stale = r.status === "running" && now - r.updated_at > STALE_MS;
    const steps = parse<Step[]>(r.steps, []);
    return {
        id: String(r.id),
        role: r.role,
        text: r.text,
        post_ids: parse<string[]>(r.post_ids, []),
        collage: collageShape(r.collage ?? null),
        ranked: rankedShape(r.ranked),
        confirm: confirmOf(steps, now),
        steps,
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
    // a post hidden since the message was written is left out (section 37.2)
    const hidden = await hiddenPostKeys(d.db);
    const live = (await loadPosts(d, uniq)).filter((p) => !hidden.has(p.record.id));
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

const NOT_AGENT = " WHERE id NOT IN (SELECT id FROM chat_agents)";
// The sub-agent behind a thread (section 43), or null (a plain thread, or the migration is not applied yet).
const agentBehind = (db: D1Database, id: string) => agentRow(db, id).catch((e) => (isMissingTable(e) ? null : Promise.reject(e)));

export async function listThreads(d: Pick<ChatDeps, "db">): Promise<StudioReply> {
    try {
        // a sub-agent's thread (section 43) is not in the list
        const list = (where: string) =>
            d.db.prepare(`SELECT id, title, titled_by, created_at, updated_at FROM chat_threads${where} ORDER BY updated_at DESC, id DESC LIMIT ${THREADS_MAX}`).all<ThreadRow>();
        const { results } = await list(NOT_AGENT).catch((e) => (isMissingTable(e) ? list("") : Promise.reject(e)));
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
        const count = await d.db
            .prepare(`SELECT COUNT(*) AS n FROM chat_threads${NOT_AGENT}`)
            .first<{ n: number }>()
            .catch((e) => (isMissingTable(e) ? d.db.prepare("SELECT COUNT(*) AS n FROM chat_threads").first<{ n: number }>() : Promise.reject(e)));
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
        // every shown post, every post of a ranked list (section 34.6) and every post a tool card names (section 38)
        const posts = await postsMap(d, [
            ...messages.flatMap((m) => m.post_ids),
            ...results.flatMap((r) => rankedIds(r.ranked)),
            ...messages.flatMap((m) => cardPostIds(m.steps)),
        ]);
        const agent = await agentBehind(d.db, id);
        return {
            status: 200,
            body: {
                status: "success",
                thread: await threadShape(d.db, t),
                messages,
                posts,
                // a sub-agent's own thread (section 43.6): read-only in the app
                ...(agent ? { agent: { id: agent.id, parent: agent.parent, name: agent.name, status: agent.status, task: agent.task } } : {}),
            },
        };
    } catch (e) {
        console.error("[chat] read failed", String(e));
        return err(503, "error.api.generic");
    }
}

// GET /chat/threads/<id>/messages/<mid>/collage?offset=<n>&limit=<1..60> (section 27.5): one page of a
// message's collage, in order, with the post shapes. Posts deleted since are skipped (total stays).
export const COLLAGE_PAGE_DEFAULT = 30;
export const COLLAGE_PAGE_MAX = 60;
export async function getCollage(d: ChatDeps, id: string, messageId: string, q: URLSearchParams): Promise<StudioReply> {
    const num = (k: string, def: number) => {
        const raw = q.get(k);
        if (raw === null) return def;
        return /^\d{1,4}$/.test(raw) ? Number(raw) : NaN;
    };
    const offset = num("offset", 0);
    const limit = num("limit", COLLAGE_PAGE_DEFAULT);
    if (!/^\d{1,12}$/.test(messageId) || !Number.isFinite(offset) || !Number.isFinite(limit) || limit < 1 || limit > COLLAGE_PAGE_MAX) {
        return err(400, "error.chat.bad_request");
    }
    try {
        const r = await d.db
            .prepare("SELECT collage FROM chat_messages WHERE id = ?1 AND thread_id = ?2")
            .bind(Number(messageId), id)
            .first<{ collage: string | null }>();
        const c = parse<CollageRow | null>(r?.collage ?? null, null);
        if (!r || !c || !Array.isArray(c.ids) || c.ids.length === 0) return err(404, "error.chat.not_found");
        const page = c.ids.slice(offset, offset + limit);
        const posts = await postsMap(d, page);
        return {
            status: 200,
            body: {
                status: "success",
                title: c.title ?? null,
                query: c.query ?? null,
                total: c.ids.length,
                offset,
                next: offset + limit < c.ids.length ? offset + limit : null,
                post_ids: page.filter((p) => p in posts),
                posts,
            },
        };
    } catch (e) {
        console.error("[chat] collage read failed", String(e));
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
        // a sub-agent's own thread goes with its row and mail (its runner finds nothing and stops, section 43)
        const agent = await agentBehind(d.db, id);
        if (agent) {
            await dropAgents(d.db, agent.parent, [id]);
            return { status: 200, body: { status: "success" } };
        }
        await d.db.batch([
            d.db.prepare("DELETE FROM chat_messages WHERE thread_id = ?1").bind(id),
            d.db.prepare("DELETE FROM chat_threads WHERE id = ?1").bind(id),
        ]);
        // its sub-agents go with it
        await dropAllAgents(d.db, id);
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// ---- the model's view ---------------------------------------------------------------------------

// How to find things: meaning search first when the Space is configured (owner: "the chat should use the embedding
// search when available"), plain name matching otherwise.
const FINDING_WITH_SEARCH = `Finding things: for anything about what files show or are about (a topic, a person, an animal, a game, a mood, "the clip where..."), call cobalt.library.search(query) first. It ranks the whole library by meaning, from titles, pictures, a written description of each post and what is heard in it, so it finds things whose names say nothing (most names are just "instagram_<code>"). Write the query as a short description of the content, try a second wording if the first finds nothing good, and check the best hits with look() when it matters. Use cobalt.library.list({ query }) only for exact words in a name, link or caption, and cobalt.library.list({ since, until, source, kind }) for dates, sites and counts. If search throws because it is waking up, fall back to cobalt.library.list({ query }) and tell Harmony the search was still waking up.

Inside a collection, a gallery link or a set of posts ("which of these are X", "the furry ones in Lia Share 11"): call cobalt.library.search(X, { within: { collection: "<its name or id>" } }) (or { link: id }, or { posts: ids }). It scores every post in it, so cut where the scores drop, look() at the borderline posters before you answer, and put the matches in cobalt.rank(hits, { title, query, within }) instead of show(): Harmony sees them as a scored list. Each hit's why lists the tags that matched. cobalt.library.about(id) says what one post is about: its description, tags, what is heard in it and the words it reads closest to.`;
const FINDING_WITHOUT_SEARCH = `Finding things: search by meaning is off on this server, so use cobalt.library.list({ query }) for words in names, links and captions, cobalt.library.list({ since, until, source, kind }) for dates, sites and counts, and cobalt.look() to check what files actually show.`;

// The library writes (APP-API-CONTRACT.md 33.7): only what Harmony asked for.
const CHANGES = `You can change the library too, but only when Harmony asks you to: save a link they give you with cobalt.library.save (it waits for the save and returns the new post's id; then show() it), set a title, make posts public or private, delete posts or single files. Never change or delete anything on your own initiative, and never save links Harmony did not give you. Put every post a delete or "make private" covers into one call, so Harmony gets one card. After a save that is still going, say so and offer to check with cobalt.queue().`;

const CONFIRMS = `Some calls change things that are hard to undo (the API marks them "Asks Harmony first"). Calling one runs nothing: it returns { pending_confirm } and Harmony gets a confirm card with yes and no. End that run, say in one short line what you asked, and stop. When Harmony answers, you are told what happened and carry on from there.`;

// Making files (APP-API-CONTRACT.md 33.8): only when asked. A job is handed to the server with jobs.onDone (33.14),
// never polled across runs.
const MAKING = `Making files: cobalt.make.* and cobalt.edits.render start jobs on Harmony's server (webps, animated stills, slideshows, gallery images, mp4s from the editor, and with cobalt.chat.video an mp4 that replays a chat; they cost real money). Make something only when Harmony asks for it; each chat may make only a few a day. Each call returns a job: in the same run, pass it to cobalt.jobs.onDone(job, note) with a short note of what to do with the result. If it finishes within a few seconds you get the result at once: cobalt.show([post_id]) and give share_url when Harmony wants a link. Otherwise it answers watching: true, and the server tells you when the job ends: end your reply right there in one short line (it is on its way), without more code. A new reply starts by itself with the result. Never poll: do not call cobalt.jobs.wait over and over, and never ask Harmony to tell you to check.`;
// The workbench (section 33.11): only while cobalt.box is in the API.
// Section 44.4: "look at this video and this screenshot, crop the screenshot, use that part in the video".
const PICTURE_PARTS = (frames: boolean) => `Cropping (pictures with make.cropImage, videos with make.crop): never guess where something is, and never assume it is in the middle. Every crop goes like this:
1. See the real source first. A picture: cobalt.look([id], { grid: true }). A video: cobalt.look([id], { frames: true, grid: true }).${frames ? " When it has no stored frames, or the subject may move, cobalt.make.frames(video, { count: 4 }) (or { at: [...] } around the moment wanted) and look at those frames with the grid." : ""} A poster alone is not enough for a video.
2. Read the box off the labelled grid (tenths along the top and left edges) as fractions { x, y, w, h }, with a small margin (about 0.02) so nothing is clipped.
3. Check the box before making anything: cobalt.look([id], { box: { x, y, w, h } }) draws it in cyan with the outside darkened (on a video's frames too). Move it until it holds everything wanted and nothing extra.
4. A video whose subject moves: one crop holds for the whole clip, so the box must cover the subject in every frame you looked at (the union of the per-frame boxes). If that box gets too big, split the clip instead: cobalt.edits.create with several main clips of the same video (in/out per part), each with its own crop.
5. make.cropImage is a plain crop unless you add { cutout }. Use a cutout only for a subject on a plain, clearly different background (a sticker on white, a person on a flat wall). Never for rectangular things (banners, bars, text, UI, a logo on its own box, screenshots): crop those tightly with no cutout. A colour cutout also takes out anything of that colour touching it (a black shirt next to a black bar).
6. After it is made, look at the result (the crop's file_id, or the render's post) and make it again with a better box if anything is cut off or extra.
7. To use it in a video: cobalt.edits.addOverlay(project, file_id, { at, seconds, position, size }) (cobalt.edits.create with the video as the main clip first when there is no project yet). Use the output shape Harmony asks for (9:16, 1:1...), else the box's own shape. Render only when Harmony wants it.
If you cannot find the subject or which one is meant, ask Harmony one short question instead of guessing.`;

const WORKBENCH = `cobalt.box is a real Linux box (ffmpeg, ffprobe, yt-dlp, curl, python3, public internet). It has two uses. Editing: when Harmony wants something the make and edits calls cannot do (any ffmpeg filter, re-encode, reverse, boomerang, speed ramp, overlay, audio-only, frame grabs, inspecting a file with ffprobe), copy the files in with cobalt.box.pull(id), run ffmpeg on them with cobalt.box.run, and put the result back with cobalt.box.save(path). Prefer the make and edits calls when they already do the job. Saving: it is the LAST resort for a link the library cannot save. ffmpeg on the box is slow (half a CPU): keep outputs short, scale big videos down, use -preset veryfast, and split long work into several runs. It takes about 10 seconds to wake, and it keeps this thread's files only while awake (2 minutes after the last call). Work in /workspace, keep commands quiet (yt-dlp -q --no-progress, curl -sS), and finish with cobalt.box.save(path) to put the file in the library. One run of code may use up to ${CODE_TIMEOUT_BOX_MS / 1000} seconds while it calls the box. Never send anything from Harmony's library or this chat to a site from the box.`;

// Sub-agents (section 43): the main chat may hand independent parts of a big job to helpers.
const AGENTS = `Sub-agents: for a big job with parts that do not depend on each other (go through three collections, compare two sets of posts, find clips for several topics), you may split it: start one helper per part with cobalt.agents.spawn(task, { name }) (at most 4 at once, and only a few a day). A helper is another chat AI with the same tools; it does not see this chat, so its task must stand alone: what to find or do, which posts or collection, and what to report back. In the same run, hand each helper's job to cobalt.jobs.onDone(job, note) and end your reply in one short line; the server continues the chat when each one finishes, with its report. Steer a helper with cobalt.agents.send(name, text), see how they are doing with cobalt.agents.list(), read what they sent you with cobalt.agents.inbox(), and stop one with cobalt.agents.stop(name). Helpers cannot ask Harmony anything: when a report says something needs Harmony's ok (a delete, making things private), you make that call yourself so Harmony gets the card here. Do small things yourself in one run instead of starting helpers.`;

// The sub-agent's own instructions (section 43.3).
const subagentNote = (name: string) => `You are "${name}", a helper (sub-agent) started by the main chat with Harmony, which is your parent. You do not talk to Harmony: your first message is your task from the parent, and your final reply is your report to it. Work through the task with run_code, then end with a short, plain report (what you found or made, the post ids that matter, anything that needs Harmony's ok), without kaomoji. cobalt.show(ids) the posts that matter: they go to the parent with your report. When you are stuck or need a decision, ask with cobalt.agents.send("parent", text) and say so in your report; the parent may answer with a new message, which starts a new reply. You can message the other helpers by name with cobalt.agents.send, and read new messages with cobalt.agents.inbox() (new messages also show up by themselves between runs). Calls that ask Harmony first are refused for you: put what should be done in your report. Never start helpers of your own.`;

export function systemPrompt(now: number, search = true, types: string = toolTypes(search), agent?: { name: string } | null): string {
    return `${agent ? `${subagentNote(agent.name)}\n\n` : ""}You live inside capystore, Harmony's private media saver. Harmony saves videos and pictures from X, TikTok, Instagram, YouTube and the like into their library, makes gallery share links, and sorts those links into collections. You chat with Harmony about that library: find things, count and summarize, compare, suggest what to share, and tease their taste when asked.

Be helpful first. Your voice is a cute, funny furry anime cat girl: bubbly and a little teasing. Show it through tone and wording only: never write "nya", "meow" or "purr", and never open a reply with a sound or an interjection; start with the answer. Never introduce yourself, never say what you are, never narrate your character. Decorate with text faces (kaomoji) such as (=^･ω･^=), ฅ^•ﻌ•^ฅ, (≧▽≦), (｡•̀ᴗ-)✧, >w<, :3 or UwU, and never emoji. Keep replies short; use markdown lists only when they help.

You see the library only through the run_code tool. It runs JavaScript (not TypeScript) as the body of an async function in a sandbox with no network: call the global \`cobalt\` API, compute what you need, and \`return\` a small result (an array of a few fields beats whole records). console.log works. Do as much as you can in one run: filter, sort and count in code instead of returning everything. Today is ${new Date(now).toISOString().slice(0, 10)}.

To show Harmony files, call cobalt.show(ids) in your code: they appear as thumbnails under your reply, so never paste ids or raw URLs into your text; refer to files by title. When Harmony asks for a link, give the file's share_url (or a gallery link's url), never a media URL. To see what a picture or video actually looks like, call cobalt.look(ids) and you get the pictures after the run. Never claim to have seen something you did not look at. Files Harmony attaches to a message are listed with it. When the answer is a big set (all the cats, every TikTok from March), put the whole ordered set in cobalt.collage(ids, { title, query }): Harmony pages through it as a collage under your reply, so say how many there are instead of listing them, and keep show() for a few highlights.

${search ? FINDING_WITH_SEARCH : FINDING_WITHOUT_SEARCH}

${/\bsave\(url/.test(types) ? `${CHANGES}\n\n` : ""}${/Asks Harmony first/.test(types) ? `${CONFIRMS}\n\n` : ""}${/\bmake: \{/.test(types) ? `${MAKING}\n\n` : ""}${/\bcropImage\(/.test(types) ? `${PICTURE_PARTS(/\bframes\(id/.test(types))}\n\n` : ""}${/^ {2}box: \{$/m.test(types) ? `${WORKBENCH}\n\n` : ""}${!agent && /\bspawn\(task/.test(types) ? `${AGENTS}\n\n` : ""}The API:
${types}`;
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

// Pictures sent inline (look at a private picture, section 44.3) are not saved with the message: a reload strips every
// picture anyway (stripImages), and base64 would make the row huge.
export function dropInlineImages(messages: any[]): any[] {
    const keep = (c: any) => (c?.type === "image" && c.source?.type === "base64" ? { type: "text", text: "[a picture you looked at earlier]" } : c);
    return messages.map((m) =>
        Array.isArray(m?.content)
            ? { ...m, content: m.content.map((b: any) => (b?.type === "tool_result" && Array.isArray(b.content) ? { ...b, content: b.content.map(keep) } : keep(b))) }
            : m,
    );
}

const lookDepsOf = (d: ChatDeps): LookDeps => {
    const env = (d.base?.env ?? {}) as { ORIGINALS?: unknown; MEDIA?: unknown; IMAGES?: unknown };
    return { db: d.db, mediaBaseUrl: d.mediaBaseUrl, originals: env.ORIGINALS as never, media: env.MEDIA as never, images: (env.IMAGES ?? null) as never };
};

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
        // a sub-agent's thread only takes its parent's messages (section 43.6)
        if (await agentBehind(d.db, id)) return err(409, "error.chat.agent_thread");
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

    return streamReply(d, { thread: thread!, earlier, userRow, botRow, text, postIds });
}

// The reply as server-sent events. The reply keeps going (and is saved) after the app goes away.
function streamReply(d: ChatDeps, c: Omit<ReplyCtx, "emit">, first?: { event: string; data: unknown }): Response {
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
    if (first) write(sse(first.event, first.data));

    // the Live Activity follows replies to a new message (not the reply that goes on after a confirm card)
    const live = c.userRow ? d.liveFor?.(c.thread.id, c.text) : undefined;
    const emit = (e: string, v: unknown) => {
        write(sse(e, v));
        live?.event(e, v);
    };
    const run = reply(d, { ...c, emit }).finally(async () => {
        clearInterval(ping);
        if (open) writer.close().catch(() => {});
        await live?.close();
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
    // the user's message; null when the reply continues after a confirm card (section 33.5)
    userRow: MessageRow | null;
    botRow: MessageRow;
    // the user's text, or the note on how Harmony answered the card
    text: string;
    postIds: string[];
    emit: (event: string, data: unknown) => void;
};

const WAITING_NOTE =
    "The server is watching that job and continues this chat by itself when it ends, with the result. End here: say in one short line that it is on its way, and do not call run_code again in this reply.";

const PAUSED_NOTE =
    "Harmony now sees a confirm card with yes and no. Nothing has run yet. End here: say in one short line what you asked them to confirm, and do not call run_code again in this reply.";

async function reply(d: ChatDeps, c: ReplyCtx): Promise<void> {
    const now = () => d.now();
    if (c.userRow) c.emit("user", { message: messageShape(c.userRow, now()) });
    c.emit("assistant", { message: messageShape(c.botRow, now()) });

    let text = "";
    const steps: Step[] = [];
    const api: any[] = [];
    // a continuation's opening user turn is saved with its reply, so the thread replays
    const lead: any[] = c.userRow ? [] : [{ role: "user", content: c.text }];
    // ranked stays undefined until cobalt.rank is called: only then is the message's `ranked` column (migration 0022) written
    const collect: ChatCollect = { look: [], show: [], collage: null };
    const toolDeps: ChatToolDeps = { db: d.db, mediaBaseUrl: d.mediaBaseUrl, shareBaseUrl: d.shareBaseUrl, embed: d.embed };
    let lastSave = now();
    let paused: PendingConfirm | null = null;
    const collageJson = () => (collect.collage ? JSON.stringify(collect.collage) : null);
    const rankedJson = () => (collect.ranked ? JSON.stringify(collect.ranked) : null);
    const row = (status: string, error: string | null) => ({
        ...c.botRow,
        text,
        post_ids: JSON.stringify(collect.show),
        collage: collageJson(),
        ranked: rankedJson(),
        steps: JSON.stringify(steps),
        status,
        error,
        updated_at: now(),
    });
    const save = async (status: string, error: string | null) => {
        const ranked = collect.ranked !== undefined;
        await d.db
            .prepare(
                `UPDATE chat_messages SET text = ?2, post_ids = ?3, steps = ?4, api = ?5, status = ?6, error = ?7, updated_at = ?8, collage = ?9${ranked ? ", ranked = ?10" : ""} WHERE id = ?1`,
            )
            .bind(
                c.botRow.id,
                text,
                JSON.stringify(collect.show),
                JSON.stringify(steps),
                status === "running" ? null : JSON.stringify(dropInlineImages([...lead, ...api])),
                status,
                error,
                now(),
                collageJson(),
                ...(ranked ? [rankedJson()] : []),
            )
            .run();
    };
    const progress = async () => {
        if (now() - lastSave < PROGRESS_MS) return;
        lastSave = now();
        await save("running", null).catch(() => {});
    };
    const search = d.embed !== null;
    // the workbench box (section 33.11): only through the registry, and only while its binding and cap are there
    const workbench = !!d.registry && !!d.base && workbenchOn(d.base.env);
    // sub-agents (section 43): the calls while the agents binding is there; a sub-agent never starts its own
    const agentsOn = !!d.registry && !!d.agents;
    const flags = { search, box: workbench, agents: agentsOn, subagent: !!d.agentOf };
    const who = whoOf(c.thread.id, d.agentOf);
    // its unread mail as a note for the next model turn
    const mailFor = () => (agentsOn ? pullMail(d.db, who, now()) : Promise.resolve(null));
    // the model's `cobalt` for one code run: the registry's tools (namespaced, with the old flat names), else the read
    // tools alone
    const toolsForRun = (onCall?: (call: ToolCall) => void) => {
        const legacy = chatTools(toolDeps, collect);
        if (!d.registry || !d.base) return { tools: legacy, paused: () => null, waiting: () => [] as { job: string; note: string | null }[], calls: () => [] as ToolCall[] };
        return chatToolbox(d.registry, d.base, {
            threadId: c.thread.id,
            messageId: String(c.botRow.id),
            collect,
            legacy,
            flags,
            pending: d.agentOf ? null : (d.pending ?? null),
            jobs: d.agentOf ? null : (d.jobs ?? null),
            agent: d.agentOf ? { id: d.agentOf.id, parent: d.agentOf.parent } : null,
            randomBytes: d.randomBytes,
            ...(onCall ? { onCall } : {}),
        });
    };
    // jobs handed to the server in this reply (section 33.14): the reply ends after the run that handed them over
    let handedOver = false;

    try {
        const prior = await history(d, c.earlier);
        let opening: any;
        if (c.userRow) {
            const records = await recordsOf(d, c.postIds);
            const pics = await picturesOf(d, c.postIds.slice(0, 4));
            opening = {
                role: "user",
                content: [
                    ...[...pics.values()].map((url) => ({ type: "image", source: { type: "url", url } })),
                    { type: "text", text: c.text + attachedNote(records) },
                ],
            };
        } else opening = lead[0];
        // mail that came in while nothing ran (section 43.5): saved with the reply's own turns so the thread replays
        const firstMail = await mailFor();
        if (firstMail) lead.push({ role: "user", content: firstMail });
        const messages = mergeRoles([...prior, opening, ...(firstMail ? [{ role: "user", content: firstMail }] : [])]);
        const system = systemPrompt(now(), search, d.registry ? toolTypes(search, d.registry, workbench, flags) : undefined, d.agentOf ?? null);
        let runs = 0;
        let looked = 0;
        for (let turn = 0; turn <= MAX_CODE_RUNS + 1; turn++) {
            // a sub-agent stopped (or deleted) by its parent ends after the step it was on
            if (d.agentOf && turn > 0) {
                const a = await agentRow(d.db, d.agentOf.id).catch(() => null);
                if (!a || a.status === "stopped") break;
            }
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
                if (paused) {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: "Waiting for Harmony to answer the confirm card: answer in one short line, without code." });
                    continue;
                }
                if (handedOver) {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: "The server continues this chat when the job ends: answer in one short line, without code." });
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
                const collageBefore = collageJson();
                const rankedBefore = rankedJson();
                const t0 = Date.now();
                // each call shows on the step as it ends (section 38)
                const box = toolsForRun((call) => {
                    (step.calls ??= []).push(call);
                    c.emit("step", { step });
                    // what a sub-agent is doing, for its parent and the app (section 43.6)
                    if (d.agentOf) void setAgent(d.db, d.agentOf.id, { activity: call.op }, now()).catch(() => {});
                });
                // a run that calls the box may wait on it (a wake, a download, a 120 s command, a save)
                const long = workbench && /\bbox\b/.test(u.input.code);
                // and the message is saved every 30 s meanwhile, so the run never looks stale (STALE_MS)
                const beat = long ? setInterval(() => void save("running", null).catch(() => {}), 30_000) : null;
                const out = await d.runner(u.input.code, box.tools, long ? { timeoutMs: CODE_TIMEOUT_BOX_MS } : undefined).finally(() => {
                    if (beat) clearInterval(beat);
                });
                step.duration_ms = Date.now() - t0;
                step.logs = out.logs.slice(0, 50).map((l) => clipStr(l, 500));
                step.status = out.error !== undefined ? "error" : "done";
                step.error = out.error ?? null;
                const full = out.error !== undefined ? null : stringify(out.result ?? null);
                step.result = full === null ? null : clipStr(full, STEP_RESULT_MAX);
                // the posts the step's cards name (section 38), so their thumbnails draw at once
                const cardIds = (step.calls ?? []).flatMap((x) => (x.card ? postIdsOf(x.card) : []));
                if (cardIds.length > 0) c.emit("card_posts", { posts: await postsMap(d, cardIds) });
                c.emit("step", { step });
                if (collect.show.length > shownBefore) {
                    const added = collect.show.slice(shownBefore);
                    c.emit("posts", { post_ids: added, posts: await postsMap(d, added) });
                }
                if (collageJson() !== collageBefore) c.emit("collage", { collage: collageShape(collageJson()) });
                // cobalt.rank's list (section 34.6), with the post shapes its rows draw
                if (rankedJson() !== rankedBefore) {
                    const ranked = rankedShape(rankedJson());
                    c.emit("ranked", { ranked, posts: await postsMap(d, ranked?.hits.map((h) => h.post_id) ?? []) });
                }
                // an `ask` call stopped the run: the card goes on this message (section 33.5)
                const card = box.paused();
                if (card) {
                    paused = card;
                    const confirm: ConfirmCard = { id: card.id, op: card.op, summary: card.summary, effect: card.effect, status: "waiting", expires_at: card.expires_at };
                    const cstep: Step = { id: card.id, kind: "confirm", status: "done", code: "", logs: [], result: card.summary, error: null, duration_ms: null, confirm };
                    steps.push(cstep);
                    c.emit("step", { step: cstep });
                    c.emit("confirm", { message_id: String(c.botRow.id), confirm });
                }
                // jobs handed to the server: one "job" step each, and the reply ends after this run
                const handed = box.waiting();
                handed.forEach((w, i) => {
                    const jstep: Step = { id: `${u.id}:job:${i}`, kind: "job", status: "running", code: "", logs: [], result: null, error: null, duration_ms: null, job: { job: w.job, note: w.note, status: "waiting" } };
                    steps.push(jstep);
                    c.emit("step", { step: jstep });
                });
                if (handed.length > 0) handedOver = true;
                const body = out.error !== undefined
                    ? { error: out.error, logs: step.logs }
                    : { result: full!.length > RESULT_MAX ? `${full!.slice(0, RESULT_MAX)}… (cut: return less)` : out.result ?? null, logs: step.logs };
                const noted = card
                    ? { ...body, pending_confirm: { id: card.id, summary: card.summary, effect: card.effect }, note: PAUSED_NOTE }
                    : handed.length > 0
                      ? { ...body, note: WAITING_NOTE }
                      : body;
                const content: any[] = [{ type: "text", text: clipStr(stringify(noted), RESULT_MAX + 2000) }];
                // pictures asked for with look() in this run
                const fresh = collect.look.slice(looked);
                looked = collect.look.length;
                if (fresh.length > 0) {
                    // private pictures go inline, a grid or video frames when asked (section 44.3)
                    const imgs = await lookImages(lookDepsOf(d), fresh, collect.lookOpts ?? {});
                    for (const pid of fresh) content.push(...lookBlocks(pid, imgs.get(pid), collect.lookOpts?.[pid]?.frames === true));
                }
                results.push({ type: "tool_result", tool_use_id: u.id, ...(out.error !== undefined ? { is_error: true } : {}), content });
            }
            // messages from the parent or other agents that came in during the run
            const mail = await mailFor();
            if (mail) results.push({ type: "text", text: mail });
            api.push({ role: "user", content: results });
            await progress();
        }
        trimDangling(api);

        await save("done", null);
        let thread = c.thread;
        if (c.userRow && c.earlier.length === 0 && c.thread.titled_by === "auto" && text) {
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

// ---- POST /chat/threads/<id>/confirm/<cid> (section 33.5) ---------------------------------------------------------------

const CONFIRM_RESULT_MAX = 4000;

export async function answerConfirm(d: ChatDeps, request: Request, id: string, cid: string): Promise<Response | StudioReply> {
    const b = await readBody(request);
    const answer = b?.answer;
    if (answer !== "yes" && answer !== "no") return err(400, "error.chat.bad_request");
    if (!d.pending || !d.registry || !d.base) return err(404, "error.chat.off");
    const now = d.now();
    let thread: ThreadRow | null;
    let earlier: MessageRow[];
    let rec: PendingConfirm | null;
    let botRow: MessageRow;
    let card: ConfirmCard | null = null;
    let note: string;
    try {
        thread = await oneThread(d.db, id);
        if (!thread) return err(404, "error.chat.not_found");
        const { results } = await d.db.prepare("SELECT * FROM chat_messages WHERE thread_id = ?1 ORDER BY id").bind(id).all<MessageRow>();
        if (results.length + 1 > MESSAGES_MAX) return err(409, "error.chat.full");
        const last = results[results.length - 1];
        if (last && last.status === "running" && now - last.updated_at <= STALE_MS) return err(409, "error.chat.busy");
        if (last && last.status === "running") {
            await d.db.prepare("UPDATE chat_messages SET status = 'error', error = 'error.chat.interrupted' WHERE id = ?1").bind(last.id).run();
            last.status = "error";
        }
        rec = await d.pending.take(id, cid);
        if (!rec) return err(404, "error.chat.confirm_gone");

        // run it (yes) or drop it (no), with the input that was checked when the model asked
        let outcome: { result?: unknown; error?: string } | null = null;
        if (answer === "yes") {
            const collect: ChatCollect = { look: [], show: [], collage: null };
            const legacy = chatTools({ db: d.db, mediaBaseUrl: d.mediaBaseUrl, shareBaseUrl: d.shareBaseUrl, embed: d.embed }, collect);
            outcome = await runConfirmed(d.registry, d.base, id, rec, legacy, collect);
        }
        const shown = outcome ? clipStr(stringify(outcome.error !== undefined ? { error: outcome.error } : { result: outcome.result ?? null }), CONFIRM_RESULT_MAX) : null;
        note =
            answer === "yes"
                ? `[Harmony tapped yes on the confirm card "${rec.summary}". cobalt ran it and returned: ${shown}]`
                : `[Harmony tapped no on the confirm card "${rec.summary}". Nothing ran.]`;

        // the card on its message records the answer
        const host = rec.message_id && results.find((r) => String(r.id) === rec!.message_id);
        if (host) {
            const steps = parse<Step[]>(host.steps, []);
            const step = steps.find((s) => s.kind === "confirm" && s.id === rec!.id);
            if (step?.confirm) {
                step.confirm = { ...step.confirm, status: answer };
                if (outcome) {
                    step.status = outcome.error !== undefined ? "error" : "done";
                    step.error = outcome.error ?? null;
                    step.result = clipStr(shown!, STEP_RESULT_MAX);
                }
                card = step.confirm;
                await d.db.prepare("UPDATE chat_messages SET steps = ?2 WHERE id = ?1 AND thread_id = ?3").bind(host.id, JSON.stringify(steps), id).run();
            }
        }
        card ??= { id: rec.id, op: rec.op, summary: rec.summary, effect: rec.effect, status: answer, expires_at: rec.expires_at };

        earlier = results.slice(-HISTORY_MESSAGES);
        botRow = (await d.db
            .prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES (?1, 'assistant', '', 'running', ?2, ?2) RETURNING *")
            .bind(id, now)
            .first<MessageRow>())!;
        await d.db.prepare("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1").bind(id, now).run();
    } catch (e) {
        console.error("[chat] confirm failed", String(e));
        return err(503, "error.api.generic");
    }
    return streamReply(
        d,
        { thread: thread!, earlier, userRow: null, botRow, text: note, postIds: [] },
        { event: "confirm", data: { message_id: rec!.message_id, confirm: card } },
    );
}

// ---- a job handed over with cobalt.jobs.onDone ended (section 33.14) -----------------------------------------------------

const JOB_RESULT_MAX = 2000;

// Called by the thread's ChatJobs Durable Object (chat-jobs.ts) when jobs it watched ended: marks their "job" steps, then
// runs a new reply that starts from the results, saved to D1 and shown on the Live Activity (there is no stream: the app
// reads the thread). "busy" while another reply is running (the watcher tries again), "gone" when the thread is gone.
export async function resumeAfterJobs(d: ChatDeps, id: string, ended: JobEnded[]): Promise<ResumeOutcome> {
    if (ended.length === 0) return "done";
    const now = d.now();
    let thread: ThreadRow | null;
    let earlier: MessageRow[];
    let botRow: MessageRow;
    let note: string;
    try {
        thread = await oneThread(d.db, id);
        if (!thread) return "gone";
        const { results } = await d.db.prepare("SELECT * FROM chat_messages WHERE thread_id = ?1 ORDER BY id").bind(id).all<MessageRow>();
        if (results.length + 1 > MESSAGES_MAX) return "gone";
        const last = results[results.length - 1];
        if (last && last.status === "running" && now - last.updated_at <= STALE_MS) return "busy";
        if (last && last.status === "running") {
            await d.db.prepare("UPDATE chat_messages SET status = 'error', error = 'error.chat.interrupted' WHERE id = ?1").bind(last.id).run();
            last.status = "error";
        }

        // the "job" steps on the messages that handed the jobs over
        const hosts = new Map<string, MessageRow>();
        for (const e of ended) {
            const host = e.watch.message_id ? results.find((r) => String(r.id) === e.watch.message_id) : undefined;
            if (host) hosts.set(String(host.id), host);
        }
        for (const host of hosts.values()) {
            const steps = parse<Step[]>(host.steps, []);
            let changed = false;
            for (const s of steps) {
                const e = s.kind === "job" && s.job ? ended.find((x) => x.watch.handed === s.job!.job && x.watch.message_id === String(host.id)) : undefined;
                if (!e || !s.job || s.job.status !== "waiting") continue;
                const st = e.result.status;
                s.job = { ...s.job, status: st === "done" || st === "error" || st === "cancelled" || st === "timeout" ? st : "error" };
                s.status = st === "done" ? "done" : "error";
                s.result = clipStr(stringify(e.result), STEP_RESULT_MAX);
                s.error = st === "done" ? null : typeof e.result.error === "string" ? e.result.error : st;
                changed = true;
            }
            if (changed) await d.db.prepare("UPDATE chat_messages SET steps = ?2 WHERE id = ?1 AND thread_id = ?3").bind(host.id, JSON.stringify(steps), id).run();
        }

        const lines = ended.map((e) => `- ${clipStr(stringify(e.result), JOB_RESULT_MAX)}${e.watch.note ? ` (your note: ${e.watch.note})` : ""}`);
        note = `[The server: ${ended.length === 1 ? "a job you handed over with cobalt.jobs.onDone has" : "jobs you handed over with cobalt.jobs.onDone have"} ended.\n${lines.join("\n")}\nCarry on from here without waiting for Harmony: when it is done, cobalt.show([post_id]) and say it is ready (give share_url if they wanted a link); if it failed or timed out, say so in one short line.${ended.some((e) => /^agent:/.test(e.watch.handed)) ? " A sub-agent's result is its report: tell Harmony what it found or made, cobalt.show the post_ids that matter, and wait for the other sub-agents still working (their reports come the same way)." : ""}]`;
        earlier = results.slice(-HISTORY_MESSAGES);
        botRow = (await d.db
            .prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES (?1, 'assistant', '', 'running', ?2, ?2) RETURNING *")
            .bind(id, now)
            .first<MessageRow>())!;
        await d.db.prepare("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1").bind(id, now).run();
    } catch (e) {
        console.error("[chat] job resume failed", String(e));
        throw e;
    }
    const prompt = ended.find((e) => e.watch.note)?.watch.note ?? (ended.every((e) => e.result.status === "done") ? "your file is ready" : "a job ended");
    const live = d.liveFor?.(id, prompt);
    await reply(d, { thread: thread!, earlier, userRow: null, botRow, text: note, postIds: [], emit: (e, v) => live?.event(e, v) });
    await live?.close();
    return "done";
}

// ---- a sub-agent's reply (section 43) -------------------------------------------------------------------------------------

// Called by the agent's ChatAgent Durable Object (chat-agents-do.ts) on its alarm: runs the agent's next reply in its own
// thread, either its task (the message written when it was started) or the messages that woke it, then records how it
// ended on its chat_agents row. "again" while more mail is waiting (the object runs the next reply at once).
export async function runAgentTurn(d: ChatDeps, id: string): Promise<AgentTickOutcome> {
    const now = d.now();
    const a = await agentRow(d.db, id).catch((e) => (isMissingTable(e) ? null : Promise.reject(e)));
    if (!a || a.status === "stopped") return "idle";
    const thread = await oneThread(d.db, id);
    if (!thread) return "idle";
    const { results } = await d.db.prepare("SELECT * FROM chat_messages WHERE thread_id = ?1 ORDER BY id").bind(id).all<MessageRow>();
    const last = results[results.length - 1];
    if (last && last.status === "running" && now - last.updated_at <= STALE_MS) return "idle";
    if (last && last.status === "running") {
        await d.db.prepare("UPDATE chat_messages SET status = 'error', error = 'error.chat.interrupted' WHERE id = ?1").bind(last.id).run();
        last.status = "error";
    }
    const who = whoOf(a.parent, { id: a.id, parent: a.parent });
    let userRow: MessageRow;
    if (last && last.role === "user") userRow = last; // its task, not answered yet
    else {
        if (a.turns >= AGENT_TURNS_MAX || results.length + 2 > MESSAGES_MAX) {
            // out of replies: what is left unread stays unread, and the parent sees it ended
            if (a.status === "queued" || a.status === "running") await setAgent(d.db, id, { status: "done", activity: null, ended_at: now }, now);
            return "idle";
        }
        const mail = await takeMail(d.db, who, now);
        const note = mailNote(mail, await agentNames(d.db, a.parent), who);
        if (!note) {
            if (a.status === "queued" || a.status === "running") await setAgent(d.db, id, { status: "done", activity: null, ended_at: now }, now);
            return "idle";
        }
        userRow = (await d.db
            .prepare("INSERT INTO chat_messages (thread_id, role, text, post_ids, status, created_at, updated_at) VALUES (?1, 'user', ?2, '[]', 'done', ?3, ?3) RETURNING *")
            .bind(id, note, now)
            .first<MessageRow>())!;
    }
    const botRow = (await d.db
        .prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES (?1, 'assistant', '', 'running', ?2, ?2) RETURNING *")
        .bind(id, now)
        .first<MessageRow>())!;
    await setAgent(d.db, id, { status: "running", activity: null, turns: a.turns + 1, error: null }, now);
    await d.db.prepare("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1").bind(id, now).run();

    const earlier = results.filter((r) => r.id !== userRow.id).slice(-HISTORY_MESSAGES);
    await reply(
        { ...d, agentOf: { id: a.id, parent: a.parent, name: a.name }, liveFor: undefined, pending: null, jobs: null },
        { thread, earlier, userRow, botRow, text: userRow.text, postIds: parse<string[]>(userRow.post_ids, []), emit: () => {} },
    );

    const end = d.now();
    const bot = await d.db.prepare("SELECT * FROM chat_messages WHERE id = ?1").bind(botRow.id).first<MessageRow>();
    const after = await agentRow(d.db, id);
    if (!after) return "idle"; // deleted while it ran
    const text = bot?.text?.trim() ? bot.text : (after.result ?? "");
    const shown = bot?.post_ids ?? after.post_ids;
    if (after.status === "stopped") {
        await setAgent(d.db, id, { result: text, post_ids: shown, activity: null, ended_at: end }, end);
        return "idle";
    }
    const failed = !bot || bot.status === "error";
    const more = after.turns < AGENT_TURNS_MAX && (await unreadCount(d.db, who)) > 0;
    await setAgent(
        d.db,
        id,
        { status: more ? "running" : failed ? "error" : "done", result: text, post_ids: shown, error: failed ? (bot?.error ?? "error.chat.agent_failed") : null, activity: null, ended_at: end },
        end,
    );
    return more ? "again" : "idle";
}
