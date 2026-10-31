// Chat videos (APP-API-CONTRACT.md section 45): a chat thread frozen into a spec and queued as a render of kind 'chat' for
// the editor's render containers, which draw it frame by frame (editor/helper/chat/). No Cloudflare imports.
import { LIMITS, SHAPES, plan } from "../../editor/helper/chat/plan.js";
import { cardPostIds, type ToolCall } from "./chat-cards";
import type { ChatSpec, InputRef } from "./edit-render-core";
import { EDIT_MAX_OUTPUT_BYTES, EDIT_QUEUE_MAX, getRender, renderShape, type EditsDeps } from "./edits";
import { randomBase62 } from "./ids";
import type { StudioReply } from "./studio";

export const CHAT_VIDEO_SHAPES = Object.keys(SHAPES) as ("portrait" | "landscape" | "square")[];
export const CHAT_VIDEO_THEMES = ["dark", "light"] as const;
export const CHAT_VIDEO_SPEED = { min: 0.5, max: 2 };
// the inputs of one render (31's caps): at most 50 files, 6 GiB
export const CHAT_VIDEO_MAX_INPUTS = 50;
export const CHAT_VIDEO_MAX_BYTES = 6 * 1024 ** 3;
// a picture without a poster is drawn from itself only when it is small
const PICTURE_AS_POSTER_MAX = 25 * 1024 * 1024;
export { EDIT_MAX_OUTPUT_BYTES };

export type ChatVideoOptions = {
    shape: (typeof CHAT_VIDEO_SHAPES)[number];
    theme: (typeof CHAT_VIDEO_THEMES)[number];
    speed: number;
    from: string | null;
    to: string | null;
    notify: boolean;
};

const BODY_KEYS = new Set(["shape", "theme", "speed", "from", "to", "notify"]);

/** The route's body (45.1), checked. Unknown keys and bad values name their key. */
export function parseChatVideoOptions(b: unknown): { ok: true; options: ChatVideoOptions } | { ok: false; path: string } {
    if (b === undefined || b === null) b = {};
    if (typeof b !== "object" || Array.isArray(b)) return { ok: false, path: "" };
    const o = b as Record<string, unknown>;
    for (const k of Object.keys(o)) if (!BODY_KEYS.has(k)) return { ok: false, path: k };
    const shape = o.shape ?? "portrait";
    if (typeof shape !== "string" || !(CHAT_VIDEO_SHAPES as string[]).includes(shape)) return { ok: false, path: "shape" };
    const theme = o.theme ?? "dark";
    if (typeof theme !== "string" || !(CHAT_VIDEO_THEMES as readonly string[]).includes(theme)) return { ok: false, path: "theme" };
    const speed = o.speed ?? 1;
    if (typeof speed !== "number" || !Number.isFinite(speed) || speed < CHAT_VIDEO_SPEED.min || speed > CHAT_VIDEO_SPEED.max) return { ok: false, path: "speed" };
    for (const k of ["from", "to"] as const) {
        const v = o[k];
        if (v !== undefined && v !== null && (typeof v !== "string" || !/^\d{1,12}$/.test(v))) return { ok: false, path: k };
    }
    if (o.notify !== undefined && typeof o.notify !== "boolean") return { ok: false, path: "notify" };
    return {
        ok: true,
        options: {
            shape: shape as ChatVideoOptions["shape"],
            theme: theme as ChatVideoOptions["theme"],
            speed: Math.round(speed * 100) / 100,
            from: (o.from as string | undefined) ?? null,
            to: (o.to as string | undefined) ?? null,
            notify: o.notify === true,
        },
    };
}

// What the thread read (GET /chat/threads/<id>, section 27) gives us; only these fields are read.
type ReadMessage = {
    id: string;
    role: string;
    text: string;
    status: string;
    post_ids: string[];
    steps: { id: string; kind: string; status: string; duration_ms: number | null; calls?: ToolCall[] }[];
};
type ReadFile = { id: string; role?: string | null; content_type: string | null; width: number | null; height: number | null; duration: number | null };
type ReadPost = { id: string; title: string | null; custom_title?: string | null; kind?: string; poster_url: string | null; files: ReadFile[] };
export type ThreadRead = { thread: { id: string; title: string }; messages: ReadMessage[]; posts: Record<string, ReadPost> };

/** A library row of a file the video uses (bucket and key to stream it into the container). */
export type FileRow = { id: string; bucket: string; r2_key: string; bytes: number | null; content_type: string | null; deleted_at: number | null };

const isVideo = (ct: string | null | undefined) => typeof ct === "string" && ct.startsWith("video/");
const isPicture = (ct: string | null | undefined) => typeof ct === "string" && ct.startsWith("image/");

/** The file a post is shown by: its first item (or original) that is a video or picture. */
export function displayFile(p: ReadPost): ReadFile | null {
    const ok = (f: ReadFile) => isVideo(f.content_type) || isPicture(f.content_type);
    return p.files.find((f) => ok(f) && (f.role == null || f.role === "item")) ?? p.files.find(ok) ?? null;
}

/** The messages a video shows: user and assistant ones from `from` to `to` (both included), at most LIMITS.messages. */
export function pickMessages(messages: ReadMessage[], from: string | null, to: string | null): ReadMessage[] | null {
    let ms = messages.filter((m) => m.role === "user" || m.role === "assistant");
    if (from !== null) {
        const i = ms.findIndex((m) => m.id === from);
        if (i < 0) return null;
        ms = ms.slice(i);
    }
    if (to !== null) {
        const i = ms.findIndex((m) => m.id === to);
        if (i < 0) return null;
        ms = ms.slice(0, i + 1);
    }
    return ms.slice(0, LIMITS.messages);
}

/** The post ids a message draws: its shown or attached posts (up to LIMITS.media) and its cards' thumbnails. */
function postIdsDrawn(m: ReadMessage): { shown: string[]; thumbs: string[] } {
    return { shown: m.post_ids.slice(0, LIMITS.media), thumbs: cardPostIds(m.steps) };
}

/** Every file id the spec may need a row for (display files of the posts drawn). */
export function filesNeeded(read: ThreadRead, messages: ReadMessage[]): string[] {
    const ids = new Set<string>();
    for (const m of messages) {
        const { shown, thumbs } = postIdsDrawn(m);
        for (const pid of [...shown, ...thumbs]) {
            const p = read.posts[pid];
            const f = p ? displayFile(p) : null;
            if (f) ids.add(f.id);
        }
    }
    return [...ids];
}

/**
 * The frozen spec (45.4): the snapshot with every file named by its input number, and the inputs. Pure.
 * Posters are public objects in `cobalt-media` (their URL's last segment is the key); a shown video that plays is
 * streamed from its own row; a picture without a poster is drawn from itself.
 */
export function buildChatSpec(
    read: ThreadRead,
    messages: ReadMessage[],
    rows: Map<string, FileRow>,
    options: ChatVideoOptions,
    mediaBaseUrl: string,
): { spec: ChatSpec; seconds: number; inputBytes: number } {
    const base = mediaBaseUrl.endsWith("/") ? mediaBaseUrl : `${mediaBaseUrl}/`;
    const inputs: InputRef[] = [];
    let bytes = 0;
    const byKey = new Map<string, number>();
    // one input per object; null once the caps are reached
    const add = (item: string, bucket: "media" | "originals", key: string, size: number, kind: InputRef["kind"]): string | null => {
        const k = `${bucket}/${key}`;
        const had = byKey.get(k);
        if (had !== undefined) return String(had);
        if (inputs.length >= CHAT_VIDEO_MAX_INPUTS || bytes + size > CHAT_VIDEO_MAX_BYTES) return null;
        const n = inputs.length;
        inputs.push({ n, item, bucket, key, bytes: size, kind });
        bytes += size;
        byKey.set(k, n);
        return String(n);
    };
    const live = (id: string) => {
        const r = rows.get(id);
        return r && r.deleted_at === null && (r.bucket === "media" || r.bucket === "originals") ? r : null;
    };

    // shown videos first (they matter most), in message order; then posters
    const shownVideo = new Set<string>();
    for (const m of messages) if (m.role === "assistant") for (const pid of postIdsDrawn(m).shown) shownVideo.add(pid);

    const posts: Record<string, any> = {};
    const postOf = (pid: string) => {
        if (posts[pid] !== undefined) return posts[pid];
        const p = read.posts[pid];
        if (!p) return (posts[pid] = null);
        const f = displayFile(p);
        posts[pid] = {
            id: pid,
            title: p.custom_title ?? p.title ?? null,
            kind: p.kind ?? null,
            poster: null as string | null,
            files: f ? [{ kind: isVideo(f.content_type) ? "video" : "image", url: null as string | null, width: f.width, height: f.height, duration: f.duration, id: f.id }] : [],
        };
        return posts[pid];
    };
    const ordered = [...new Set(messages.flatMap((m) => [...postIdsDrawn(m).shown, ...postIdsDrawn(m).thumbs]))];
    for (const pid of ordered) postOf(pid);
    // the videos the reply showed: their own bytes (each plays with its sound)
    for (const pid of ordered) {
        const sp = posts[pid];
        const f = sp?.files[0];
        if (!sp || !f || f.kind !== "video" || !shownVideo.has(pid)) continue;
        const r = live(f.id);
        if (r) f.url = add(f.id, r.bucket as "media" | "originals", r.r2_key, r.bytes ?? 0, "video");
    }
    // posters: the post's public poster; a picture without one, itself
    for (const pid of ordered) {
        const sp = posts[pid];
        if (!sp) continue;
        const p = read.posts[pid];
        const f = sp.files[0];
        if (p.poster_url && p.poster_url.startsWith(base)) {
            const key = p.poster_url.slice(base.length);
            if (/^[A-Za-z0-9._-]{1,200}$/.test(key)) sp.poster = add(f?.id ?? pid, "media", key, 0, "photo");
        }
        if (sp.poster === null && f && f.kind === "image") {
            const r = live(f.id);
            if (r && (r.bytes ?? 0) <= PICTURE_AS_POSTER_MAX) sp.poster = add(f.id, r.bucket as "media" | "originals", r.r2_key, r.bytes ?? 0, "photo");
        }
        if (f && f.kind === "image") f.url = sp.poster;
    }

    const snapshot = {
        version: 1,
        thread: { id: read.thread.id, title: read.thread.title },
        messages: messages.map((m) => ({
            id: m.id,
            role: m.role,
            text: m.text,
            status: m.status,
            post_ids: m.post_ids.filter((id) => posts[id]),
            steps: m.steps.map((s) => ({
                id: s.id,
                kind: s.kind,
                status: s.status,
                duration_ms: s.duration_ms,
                calls: (s.calls ?? []).map((c) => ({ op: c.op, ms: c.ms, status: c.status, ...(c.card ? { card: c.card } : {}) })),
            })),
        })),
        posts: Object.fromEntries(Object.entries(posts).filter(([, v]) => v)),
    };
    const script = plan(snapshot, { speed: options.speed });
    // a shown video the plan does not reach (past the length cap) is not sent
    const played = new Set(script.sounds.map((s: { file: { url: string } }) => s.file.url));
    const keep = new Set<number>();
    for (const p of Object.values(snapshot.posts) as any[]) {
        for (const f of p.files) {
            if (f.kind === "video" && f.url !== null && !played.has(f.url)) f.url = null;
            if (f.url !== null) keep.add(Number(f.url));
            delete f.id;
        }
        if (p.poster !== null) keep.add(Number(p.poster));
    }
    const used = inputs.filter((i) => keep.has(i.n));
    const spec: ChatSpec = {
        kind: "chat",
        thread_id: read.thread.id,
        options: { shape: options.shape, theme: options.theme, speed: options.speed },
        snapshot: snapshot as ChatSpec["snapshot"],
        inputs: used,
    };
    return { spec, seconds: Math.round(script.seconds * 1000) / 1000, inputBytes: used.reduce((a, i) => a + i.bytes, 0) };
}

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({ status, body: { status: "error", error: { code }, ...extra } });

/** Reads the files' rows (id -> row). */
async function fileRows(db: D1Database, ids: string[]): Promise<Map<string, FileRow>> {
    const out = new Map<string, FileRow>();
    for (let i = 0; i < ids.length; i += 90) {
        const part = ids.slice(i, i + 90);
        const { results } = await db
            .prepare(`SELECT id, bucket, r2_key, bytes, content_type, deleted_at FROM media_items WHERE id IN (${part.map((_, j) => `?${j + 1}`).join(", ")})`)
            .bind(...part)
            .all<FileRow>();
        for (const r of results) out.set(r.id, r);
    }
    return out;
}

/**
 * POST /chat/threads/<id>/video (45.1) after the body is parsed: `read` is the thread read's answer. Queues the render
 * and kicks the renderers. `own`: the chat AI asked for its own thread (45.5).
 */
export async function queueChatVideo(d: EditsDeps, read: StudioReply, options: ChatVideoOptions, own = false): Promise<StudioReply> {
    if (read.status !== 200) return read;
    const body = read.body as unknown as ThreadRead;
    // the chat asking for a video of its own thread: the reply it is writing now is left out
    if (own) body.messages = body.messages.filter((m) => m.status !== "running");
    const last = body.messages[body.messages.length - 1];
    if (last && last.status === "running") return err(409, "error.chat.busy");
    const messages = pickMessages(body.messages, options.from, options.to);
    if (messages === null) return err(400, "error.chat.bad_request", { path: options.from !== null && !body.messages.some((m) => m.id === options.from) ? "from" : "to" });
    if (messages.length === 0) return err(409, "error.chat.video.empty");
    const rows = await fileRows(d.db, filesNeeded(body, messages));
    const { spec, seconds, inputBytes } = buildChatSpec(body, messages, rows, options, d.mediaBaseUrl);

    const busy = await d.db.prepare("SELECT COUNT(*) AS n FROM edit_renders WHERE status IN ('queued', 'preparing', 'rendering', 'finishing')").first<{ n: number }>();
    if ((busy?.n ?? 0) >= EDIT_QUEUE_MAX) return err(429, "error.edit.queue_full");

    const rid = randomBase62(20, d.randomBytes);
    const now = d.now();
    await d.db
        .prepare(
            `INSERT INTO edit_renders (id, kind, thread_id, project_id, revision, title, timeline, status, cancel_requested, attempts, input_bytes, seconds_total, notify, key_id, created_at, updated_at)
             VALUES (?1, 'chat', ?2, ?3, 0, ?4, ?5, 'queued', 0, 0, ?6, ?7, ?8, ?9, ?10, ?10)`,
        )
        .bind(rid, body.thread.id, `chat:${body.thread.id}`, body.thread.title, JSON.stringify(spec), inputBytes, seconds, options.notify ? 1 : 0, d.keyId, now)
        .run();
    await d.kick().catch(() => {});
    const made = await getRender(d.db, rid);
    return made ? { status: 202, body: { status: "success", render: renderShape(made) } } : err(503, "error.api.generic");
}

/** features.chat_video's migration check: migration 0028 is applied. */
export async function chatVideoReady(db: D1Database): Promise<boolean> {
    try {
        await db.prepare("SELECT kind, thread_id FROM edit_renders LIMIT 0").all();
        return true;
    } catch {
        return false;
    }
}
