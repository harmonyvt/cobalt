// Shared chats (APP-API-CONTRACT.md section 46): a chat thread as a web page at share.../c/<key>, shown up to the message
// it was shared at, with its tool cards and the videos and pictures it shows playable on the page (private ones stream
// through the link, like a private link's, section 36). Chats stay private until the owner shares one; the key is 22
// base62 characters and is the only way in; rotating makes a new key and the old one is a 404 at once.
//
// This file: the chat_shares store (migration 0029), the owner's routes' work, and the transcript, the one JSON shape
// the page is drawn from and that /c/<key>/chat.json serves (the chat-to-video animation reads the same shape). The page
// HTML and the share host's /c/ routes are in chat-share-page.ts. D1 only, free of Cloudflare imports.
import { cardPostIds, type ToolCall, type ToolCard } from "./chat-cards";
import { loadPosts } from "./chat-tools";
import { hiddenPostKeys } from "./hidden-store";
import { randomBase62 } from "./ids";
import { isMissingTable } from "./private-links";
import type { StudioReply } from "./studio";
import { effectiveVisibility, extOf } from "./visibility";

export const CHAT_SHARE_KEY_REGEX = /^[A-Za-z0-9]{22}$/;
export const CHAT_SHARE_KEY_LENGTH = 22;
// the most files one shared chat streams (the posts it shows, in order of first appearance)
export const SHARE_FILES_MAX = 300;
// the most messages one page shows (a thread holds at most 200, section 27)
export const SHARE_MESSAGES_MAX = 400;
// a collage (section 27.5) shows this many of its posts on the page
export const COLLAGE_ON_PAGE = 24;
// a reply still running after this is not "running" any more (chat.ts STALE_MS)
const STALE_MS = 3 * 60 * 1000;

export type ChatShareRow = {
    key: string;
    thread_id: string;
    upto_id: number;
    media: number;
    code: number;
    files: string;
    created_at: number;
    updated_at: number;
    revoked_at: number | null;
    opened: number;
    last_opened_at: number | null;
};

export type ChatShareDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    shareBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
};

const COLUMNS = "key, thread_id, upto_id, media, code, files, created_at, updated_at, revoked_at, opened, last_opened_at";
const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

export const chatShareUrl = (shareBaseUrl: string, key: string) => `${withSlash(shareBaseUrl)}c/${key}`;
export const sharedFileUrl = (shareBaseUrl: string, key: string, n: number, r2Key: string) => `${withSlash(shareBaseUrl)}c/${key}/${n}.${extOf(r2Key)}`;
export const sharedPosterUrl = (shareBaseUrl: string, key: string, n: number) => `${withSlash(shareBaseUrl)}c/${key}/${n}.poster.jpg`;

const parse = <T>(s: string | null | undefined, fallback: T): T => {
    if (!s) return fallback;
    try {
        return JSON.parse(s) as T;
    } catch {
        return fallback;
    }
};

export const fileIdsOf = (r: Pick<ChatShareRow, "files">): string[] => parse<string[]>(r.files, []).filter((x) => typeof x === "string");

// ---- store --------------------------------------------------------------------------------------------------------------

// The live share of a chat, or null. Throws when the table is missing (the routes answer 503).
export async function liveShareOf(db: D1Database, threadId: string): Promise<ChatShareRow | null> {
    return (await db.prepare(`SELECT ${COLUMNS} FROM chat_shares WHERE thread_id = ?1 AND revoked_at IS NULL`).bind(threadId).first<ChatShareRow>()) ?? null;
}

// The live share a key opens, or null (also null before migration 0029: the page is a 404).
export async function shareByKey(db: D1Database, key: string): Promise<ChatShareRow | null> {
    if (!CHAT_SHARE_KEY_REGEX.test(key)) return null;
    try {
        return (await db.prepare(`SELECT ${COLUMNS} FROM chat_shares WHERE key = ?1 AND revoked_at IS NULL`).bind(key).first<ChatShareRow>()) ?? null;
    } catch (e) {
        if (isMissingTable(e)) return null;
        throw e;
    }
}

export async function noteShareOpened(db: D1Database, key: string, now: number): Promise<void> {
    try {
        await db.prepare("UPDATE chat_shares SET opened = opened + 1, last_opened_at = ?2 WHERE key = ?1").bind(key, now).run();
    } catch (e) {
        console.error("[chat-share] open count failed", String(e));
    }
}

// ---- the transcript -----------------------------------------------------------------------------------------------------

type MessageRow = {
    id: number;
    role: string;
    text: string;
    post_ids: string;
    collage: string | null;
    ranked: string | null;
    steps: string;
    status: string;
    error: string | null;
    created_at: number;
    updated_at: number;
};

type StepRow = {
    kind?: string;
    status?: string;
    code?: string;
    duration_ms?: number | null;
    calls?: ToolCall[];
    confirm?: { summary?: string; status?: string; op?: string };
    job?: { note?: string | null; status?: string };
};

export type SharedStep = {
    kind: "code" | "confirm" | "job";
    status: string;
    duration_ms: number | null;
    // the model's code, only when the share shows code
    code: string | null;
    calls: { op: string; ms: number; status: string; card: ToolCard | null }[];
    confirm: { op: string; summary: string; status: string } | null;
    job: { note: string | null; status: string } | null;
};

export type SharedMessage = {
    id: string;
    role: "user" | "assistant";
    text: string;
    created_at: number;
    // "error": the reply stopped part way
    status: "done" | "error";
    post_ids: string[];
    ranked: { title: string | null; query: string | null; hits: { post_id: string; why: string[] }[] } | null;
    collage: { title: string | null; query: string | null; total: number; post_ids: string[] } | null;
    steps: SharedStep[];
};

export type SharedFile = {
    // 1-based place in the share's file list (the /c/<key>/<n>.<ext> address)
    n: number;
    type: "video" | "image";
    content_type: string;
    url: string;
    poster: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
};

export type SharedPost = {
    id: string;
    title: string | null;
    kind: "video" | "image" | "gallery";
    files: number;
    duration: number | null;
    // its lead file, or null when the share shows no media or the file is not in the share's list
    file: SharedFile | null;
};

export type ChatTranscript = {
    version: 1;
    thread: { id: string; title: string; created_at: number; shared_at: number; url: string };
    // the settings the page was drawn with
    media: boolean;
    code: boolean;
    messages: SharedMessage[];
    posts: Record<string, SharedPost>;
    counts: { messages: number; videos: number; pictures: number };
};

// A share link of another private thing (a private link, another shared chat) in the chat's text or a card: the page
// shows "[private link]" instead, so sharing a chat never hands out a key it happens to mention.
export function scrubber(shareBaseUrl: string): (s: string) => string {
    const base = withSlash(shareBaseUrl).replace(/^https?:\/\//, "").replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
    const re = new RegExp(`(?:https?:\\/\\/)?${base}(?:p|c)\\/[A-Za-z0-9]{22}(?:\\/[^\\s)\\]"'<>]*)?`, "g");
    return (s) => s.replace(re, "[private link]");
}

const deepScrub = <T>(v: T, scrub: (s: string) => string): T => {
    if (typeof v === "string") return scrub(v) as T;
    if (Array.isArray(v)) return v.map((x) => deepScrub(x, scrub)) as T;
    if (v && typeof v === "object") {
        const out: Record<string, unknown> = {};
        for (const [k, x] of Object.entries(v)) out[k] = deepScrub(x, scrub);
        return out as T;
    }
    return v;
};

// A card as the page shows it: a private link's address left out (its own page is the owner's to hand out).
function pageCard(card: ToolCard | undefined, scrub: (s: string) => string): ToolCard | null {
    if (!card) return null;
    const c = deepScrub(card, scrub);
    if (c.type === "link" && c.private) return { ...c, url: "" };
    return c;
}

function stepOf(s: StepRow, showCode: boolean, scrub: (s: string) => string): SharedStep | null {
    const kind = s.kind === "confirm" || s.kind === "job" ? s.kind : s.kind === "code" || s.kind === undefined ? "code" : null;
    if (!kind) return null;
    return {
        kind,
        status: typeof s.status === "string" ? s.status : "done",
        duration_ms: typeof s.duration_ms === "number" ? s.duration_ms : null,
        code: showCode && kind === "code" && typeof s.code === "string" ? scrub(s.code) : null,
        calls: (Array.isArray(s.calls) ? s.calls : []).map((c) => ({
            op: String(c.op ?? ""),
            ms: typeof c.ms === "number" ? c.ms : 0,
            status: String(c.status ?? "done"),
            card: pageCard(c.card, scrub),
        })),
        confirm:
            kind === "confirm" && s.confirm
                ? { op: String(s.confirm.op ?? ""), summary: scrub(String(s.confirm.summary ?? "")), status: String(s.confirm.status ?? "") }
                : null,
        job: kind === "job" && s.job ? { note: s.job.note ? scrub(String(s.job.note)) : null, status: String(s.job.status ?? "") } : null,
    };
}

async function messagesUpTo(db: D1Database, threadId: string, uptoId: number): Promise<MessageRow[]> {
    const { results } = await db
        .prepare(
            `SELECT id, role, text, post_ids, collage, ranked, steps, status, error, created_at, updated_at
               FROM chat_messages WHERE thread_id = ?1 AND id <= ?2 ORDER BY id LIMIT ${SHARE_MESSAGES_MAX}`,
        )
        .bind(threadId, uptoId)
        .all<MessageRow>();
    return results;
}

// Every post a message shows, in order: the posts it showed, its ranked list, its cards' posts, its collage's first ones.
function messagePostIds(m: SharedMessage): string[] {
    return [
        ...m.post_ids,
        ...(m.ranked?.hits.map((h) => h.post_id) ?? []),
        ...cardPostIds(m.steps.map((s) => ({ calls: s.calls.map((c) => ({ op: c.op, ms: c.ms, status: "done" as const, ...(c.card ? { card: c.card } : {}) })) }))),
        ...(m.collage?.post_ids ?? []),
    ];
}

function sharedMessage(r: MessageRow, showCode: boolean, now: number, scrub: (s: string) => string): SharedMessage | null {
    // a reply still being written is not on the page
    if (r.status === "running" && now - r.updated_at <= STALE_MS) return null;
    const collage = parse<{ title?: string | null; query?: string | null; ids?: string[] } | null>(r.collage, null);
    const ranked = parse<{ title?: string | null; query?: string | null; hits?: { post_id: string; why?: string[] }[] } | null>(r.ranked, null);
    const steps = parse<StepRow[]>(r.steps, [])
        .map((s) => stepOf(s, showCode, scrub))
        .filter((s): s is SharedStep => s !== null);
    return {
        id: String(r.id),
        role: r.role === "user" ? "user" : "assistant",
        text: scrub(r.text ?? ""),
        created_at: r.created_at,
        status: r.status === "done" ? "done" : "error",
        post_ids: parse<string[]>(r.post_ids, []).filter((x) => typeof x === "string"),
        ranked:
            ranked && Array.isArray(ranked.hits) && ranked.hits.length > 0
                ? {
                      title: ranked.title ?? null,
                      query: ranked.query ?? null,
                      hits: ranked.hits.map((h) => ({ post_id: h.post_id, why: Array.isArray(h.why) ? h.why.map(scrub) : [] })),
                  }
                : null,
        collage:
            collage && Array.isArray(collage.ids) && collage.ids.length > 0
                ? { title: collage.title ?? null, query: collage.query ?? null, total: collage.ids.length, post_ids: collage.ids.slice(0, COLLAGE_ON_PAGE) }
                : null,
        steps,
    };
}

// Load posts by id in chunks (D1 binds at most 100 parameters per statement).
async function postsByIds(d: Pick<ChatShareDeps, "db" | "mediaBaseUrl">, ids: string[]) {
    const out = [];
    for (let i = 0; i < ids.length; i += 90) out.push(...(await loadPosts(d, ids.slice(i, i + 90))));
    return out;
}

const typeFrom = (ct: string | null, r2Key: string): string => {
    const t = (ct ?? "").split(";")[0]!.trim().toLowerCase();
    if (t) return t;
    const ext = extOf(r2Key);
    return ["mp4", "m4v", "mov", "webm"].includes(ext) ? `video/${ext === "mov" ? "quicktime" : ext === "m4v" ? "mp4" : ext}` : `image/${ext === "jpg" ? "jpeg" : ext}`;
};

type LeadRow = { id: string; bucket: string; r2_key: string; url: string | null; poster: string | null; content_type: string | null; visibility: string | null; width: number | null; height: number | null; duration: number | null };

// The rows of these file ids (live, not deleted), by id.
async function leadRows(db: D1Database, ids: string[]): Promise<Map<string, LeadRow>> {
    const out = new Map<string, LeadRow>();
    if (ids.length === 0) return out;
    const { results } = await db
        .prepare(
            `SELECT id, bucket, r2_key, url, poster, content_type, visibility, width, height, duration FROM media_items
              WHERE deleted_at IS NULL AND id IN (SELECT value FROM json_each(?1))`,
        )
        .bind(JSON.stringify(ids))
        .all<LeadRow>();
    for (const r of results) out.set(r.id, r);
    return out;
}

// The chat as the page shows it. `files` is the share's file list (lead file ids, in order): a post whose lead is in it
// gets a playable file; a post that is not (made after the share was last updated) shows as a title.
export async function chatTranscript(
    d: Pick<ChatShareDeps, "db" | "mediaBaseUrl" | "shareBaseUrl" | "now">,
    share: Pick<ChatShareRow, "key" | "thread_id" | "upto_id" | "media" | "code" | "files" | "updated_at">,
): Promise<ChatTranscript | null> {
    const t = await d.db.prepare("SELECT id, title, created_at FROM chat_threads WHERE id = ?1").bind(share.thread_id).first<{ id: string; title: string; created_at: number }>();
    if (!t) return null;
    const scrub = scrubber(d.shareBaseUrl);
    const now = d.now();
    const showCode = share.code === 1;
    const showMedia = share.media === 1;
    const messages = (await messagesUpTo(d.db, share.thread_id, share.upto_id))
        .map((r) => sharedMessage(r, showCode, now, scrub))
        .filter((m): m is SharedMessage => m !== null);

    // the posts, minus the ones hidden since (section 37: a hidden post is never on a shared page)
    const hidden = await hiddenPostKeys(d.db);
    const order = [...new Set(messages.flatMap(messagePostIds))].filter((id) => !hidden.has(id));
    // in page order (loadPosts answers newest first)
    const byId = new Map((await postsByIds(d, order)).map((p) => [p.record.id, p]));
    const posts = order.map((id) => byId.get(id)).filter((p): p is NonNullable<typeof p> => !!p);
    const fileIds = fileIdsOf(share);
    const fileIndex = new Map(fileIds.map((id, i) => [id, i + 1]));
    const leads = showMedia ? await leadRows(d.db, posts.map((p) => p.lead.id).filter((id) => fileIndex.has(id))) : new Map<string, LeadRow>();
    const media = withSlash(d.mediaBaseUrl);
    const out: Record<string, SharedPost> = {};
    let videos = 0;
    let pictures = 0;
    for (const p of posts) {
        const lead = leads.get(p.lead.id);
        const n = fileIndex.get(p.lead.id);
        let file: SharedFile | null = null;
        if (lead && n) {
            const ct = typeFrom(lead.content_type, lead.r2_key);
            const type = ct.startsWith("video/") ? "video" : "image";
            // a public file plays from the media domain (cached); anything else streams through the link
            const isPublic = effectiveVisibility(lead) === "public" && !!lead.url && lead.url.startsWith(media);
            const posterIsOurs = !!lead.poster && lead.poster.startsWith(media);
            file = {
                n,
                type,
                content_type: ct,
                url: isPublic ? lead.url! : sharedFileUrl(d.shareBaseUrl, share.key, n, lead.r2_key),
                poster: posterIsOurs ? (isPublic ? lead.poster : sharedPosterUrl(d.shareBaseUrl, share.key, n)) : null,
                width: lead.width ?? null,
                height: lead.height ?? null,
                duration: lead.duration ?? null,
            };
            if (type === "video") videos++;
            else pictures++;
        }
        out[p.record.id] = {
            id: p.record.id,
            title: p.record.title ? scrub(p.record.title) : null,
            kind: p.record.kind,
            files: p.record.files,
            duration: p.record.duration,
            file,
        };
    }
    // a post that is gone (or hidden) is left out of the lists too
    for (const m of messages) {
        m.post_ids = m.post_ids.filter((id) => out[id]);
        if (m.ranked) m.ranked.hits = m.ranked.hits.filter((h) => out[h.post_id]);
        if (m.collage) m.collage.post_ids = m.collage.post_ids.filter((id) => out[id]);
    }
    return {
        version: 1,
        thread: { id: t.id, title: scrub(t.title), created_at: t.created_at, shared_at: share.updated_at, url: chatShareUrl(d.shareBaseUrl, share.key) },
        media: showMedia,
        code: showCode,
        messages,
        posts: out,
        counts: { messages: messages.length, videos, pictures },
    };
}

// The file list of a share at `uptoId`: the lead file of every post the chat shows, in order, hidden posts left out.
async function fileListAt(d: Pick<ChatShareDeps, "db" | "mediaBaseUrl" | "shareBaseUrl" | "now">, threadId: string, uptoId: number): Promise<string[]> {
    const scrub = (s: string) => s;
    const now = d.now();
    const messages = (await messagesUpTo(d.db, threadId, uptoId)).map((r) => sharedMessage(r, false, now, scrub)).filter((m): m is SharedMessage => m !== null);
    const hidden = await hiddenPostKeys(d.db);
    const order = [...new Set(messages.flatMap(messagePostIds))].filter((id) => !hidden.has(id));
    const byId = new Map((await postsByIds(d, order)).map((p) => [p.record.id, p.lead.id]));
    return order.map((id) => byId.get(id)).filter((x): x is string => !!x).slice(0, SHARE_FILES_MAX);
}

// The newest message a share can reach: the last one that is not a reply still being written.
async function latestMessageId(db: D1Database, threadId: string, now: number): Promise<number | null> {
    const r = await db
        .prepare("SELECT MAX(id) AS id FROM chat_messages WHERE thread_id = ?1 AND NOT (status = 'running' AND updated_at > ?2)")
        .bind(threadId, now - STALE_MS)
        .first<{ id: number | null }>();
    return r?.id ?? null;
}

// ---- the owner's routes (46.2) -----------------------------------------------------------------------------------------

export type ChatShareShape = {
    url: string;
    thread_id: string;
    upto_id: string;
    upto_at: number | null;
    // messages on the page and messages written after it
    messages: number;
    behind: number;
    files: number;
    media: boolean;
    code: boolean;
    created_at: number;
    updated_at: number;
    opened: number;
    last_opened_at: number | null;
};

const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });

async function shapeOf(d: ChatShareDeps, r: ChatShareRow): Promise<ChatShareShape> {
    const c = await d.db
        .prepare(
            `SELECT SUM(CASE WHEN id <= ?2 THEN 1 ELSE 0 END) AS shown, SUM(CASE WHEN id > ?2 THEN 1 ELSE 0 END) AS behind,
                    (SELECT created_at FROM chat_messages WHERE id = ?2) AS upto_at
               FROM chat_messages WHERE thread_id = ?1`,
        )
        .bind(r.thread_id, r.upto_id)
        .first<{ shown: number | null; behind: number | null; upto_at: number | null }>();
    return {
        url: chatShareUrl(d.shareBaseUrl, r.key),
        thread_id: r.thread_id,
        upto_id: String(r.upto_id),
        upto_at: c?.upto_at ?? null,
        messages: Number(c?.shown ?? 0),
        behind: Number(c?.behind ?? 0),
        files: fileIdsOf(r).length,
        media: r.media === 1,
        code: r.code === 1,
        created_at: r.created_at,
        updated_at: r.updated_at,
        opened: r.opened ?? 0,
        last_opened_at: r.last_opened_at ?? null,
    };
}

const threadExists = async (db: D1Database, id: string) => !!(await db.prepare("SELECT 1 AS x FROM chat_threads WHERE id = ?1").bind(id).first());

async function guarded(run: () => Promise<StudioReply>): Promise<StudioReply> {
    try {
        return await run();
    } catch (e) {
        if (!isMissingTable(e)) console.error("[chat-share] failed", String(e));
        return err(503, "error.api.generic");
    }
}

// GET /chat/threads/<id>/share
export const getChatShare = (d: ChatShareDeps, threadId: string): Promise<StudioReply> =>
    guarded(async () => {
        if (!(await threadExists(d.db, threadId))) return err(404, "error.chat.not_found");
        const r = await liveShareOf(d.db, threadId);
        return { status: 200, body: { status: "success", share: r ? await shapeOf(d, r) : null } };
    });

export type ShareInput = { media?: boolean; code?: boolean; upto?: "latest" };

// PUT /chat/threads/<id>/share {media?, code?, upto?: "latest"}: shares the chat (up to its latest message) when it is
// not shared, else changes the live share's settings; "latest" moves it up to the latest message (and its file list).
export const putChatShare = (d: ChatShareDeps, threadId: string, input: ShareInput): Promise<StudioReply> =>
    guarded(async () => {
        if (!(await threadExists(d.db, threadId))) return err(404, "error.chat.not_found");
        const now = d.now();
        const live = await liveShareOf(d.db, threadId);
        if (!live) {
            const upto = await latestMessageId(d.db, threadId, now);
            if (upto === null) return err(409, "error.chat_share.empty");
            const files = await fileListAt(d, threadId, upto);
            const key = randomBase62(CHAT_SHARE_KEY_LENGTH, d.randomBytes);
            await d.db
                .prepare(
                    `INSERT INTO chat_shares (key, thread_id, upto_id, media, code, files, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
                )
                .bind(key, threadId, upto, input.media === false ? 0 : 1, input.code === true ? 1 : 0, JSON.stringify(files), now)
                .run();
            const row = await liveShareOf(d.db, threadId);
            return { status: 201, body: { status: "success", share: await shapeOf(d, row!) } };
        }
        let upto = live.upto_id;
        let files = live.files;
        if (input.upto === "latest") {
            upto = (await latestMessageId(d.db, threadId, now)) ?? live.upto_id;
            files = JSON.stringify(await fileListAt(d, threadId, upto));
        }
        const media = input.media === undefined ? live.media : input.media ? 1 : 0;
        const code = input.code === undefined ? live.code : input.code ? 1 : 0;
        await d.db
            .prepare("UPDATE chat_shares SET upto_id = ?2, files = ?3, media = ?4, code = ?5, updated_at = ?6 WHERE key = ?1")
            .bind(live.key, upto, files, media, code, now)
            .run();
        const row = await liveShareOf(d.db, threadId);
        return { status: 200, body: { status: "success", share: await shapeOf(d, row!) } };
    });

// POST /chat/threads/<id>/share/rotate: a new key for the same share; the old link is a 404 at once.
export const rotateChatShare = (d: ChatShareDeps, threadId: string): Promise<StudioReply> =>
    guarded(async () => {
        const live = await liveShareOf(d.db, threadId);
        if (!live) return err(404, "error.chat_share.not_found");
        const now = d.now();
        const key = randomBase62(CHAT_SHARE_KEY_LENGTH, d.randomBytes);
        await d.db.batch([
            d.db.prepare("UPDATE chat_shares SET revoked_at = ?2 WHERE key = ?1").bind(live.key, now),
            d.db
                .prepare(
                    `INSERT INTO chat_shares (key, thread_id, upto_id, media, code, files, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
                )
                .bind(key, threadId, live.upto_id, live.media, live.code, live.files, now),
        ]);
        const row = await liveShareOf(d.db, threadId);
        return { status: 200, body: { status: "success", share: await shapeOf(d, row!) } };
    });

// DELETE /chat/threads/<id>/share: the link stops working; the chat is private again.
export const deleteChatShare = (d: ChatShareDeps, threadId: string): Promise<StudioReply> =>
    guarded(async () => {
        const live = await liveShareOf(d.db, threadId);
        if (!live) return err(404, "error.chat_share.not_found");
        await d.db.prepare("UPDATE chat_shares SET revoked_at = ?2 WHERE key = ?1").bind(live.key, d.now()).run();
        return { status: 200, body: { status: "success" } };
    });

// A deleted thread takes its share with it (chat.ts deleteThread calls this; a missing table is fine).
export async function revokeSharesOf(db: D1Database, threadId: string, now: number): Promise<void> {
    try {
        await db.prepare("UPDATE chat_shares SET revoked_at = ?2 WHERE thread_id = ?1 AND revoked_at IS NULL").bind(threadId, now).run();
    } catch (e) {
        if (!isMissingTable(e)) throw e;
    }
}
