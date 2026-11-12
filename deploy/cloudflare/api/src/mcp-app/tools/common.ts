// What the app tools share (MCP-APP-CONTRACT.md section 4): defensive readers for op answers (they are `unknown`), the
// one batched read that gives posts their picture and status, and the plain-text lines every answer starts with.
// Free of Cloudflare imports: the tests run it under node.
import { postsFrom } from "../../chat-tools";
import { POST_KEY_SQL } from "../../post-key";
import type { OpContext } from "../../registry/op";
import { effectiveVisibility } from "../../visibility";
import type { PostSummary } from "../shapes";
import type { AppToolCtx } from "../types";

export type Rec = Record<string, unknown>;

export const rec = (v: unknown): Rec => (v && typeof v === "object" && !Array.isArray(v) ? (v as Rec) : {});
export const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
export const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
export const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
export const int = (v: unknown, or = 0): number => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : or);
export const strings = (v: unknown): string[] => arr(v).filter((x): x is string => typeof x === "string");
export const round = (n: number, places = 3): number => Math.round(n * 10 ** places) / 10 ** places;

// ---- text ---------------------------------------------------------------------------------------------------------------

export const TEXT_ROWS = 10;

export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
export const cut = (s: string, max: number) => (s.length > max ? `${s.slice(0, max - 1)}…` : s);
// 83.4 -> "1:23"
export const clock = (s: number) => {
    const t = Math.max(0, Math.round(s));
    return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
};
export const seconds = (s: number) => `${round(s, 1)} s`;

// A count line, then up to 10 numbered rows (and how many more there are). A caller that asked for more rows passes
// `maxRows`: every row it asked for is then listed (the whole text is still cut at MCP_RESULT_MAX).
export function listText(count: string, rows: string[], total = rows.length, maxRows = TEXT_ROWS): string {
    const shown = rows.slice(0, Math.max(TEXT_ROWS, maxRows));
    const lines = [count, ...shown.map((r, i) => `${i + 1}. ${r}`)];
    if (total > shown.length) lines.push(`…and ${total - shown.length} more`);
    return lines.join("\n");
}

// ---- posts: pictures and status -------------------------------------------------------------------------------------

export type PostFacts = {
    thumb_url: string | null;
    status: "public" | "private" | "off";
    kind: "video" | "image" | "gallery";
    files: number;
    duration: number | null;
    // the lead file's size
    bytes: number | null;
    // the share page of a single file's post (never a media URL); null for a gallery or a post that is not public
    share_url: string | null;
    // The lead file and what a signed preview of this post's picture would be: its poster, the file itself (a picture),
    // or nothing. Used by `signThumbs` for a post that is not public.
    lead_id: string;
    thumb_source: "poster" | "file" | null;
};
// One file of a post that is here (by file id): what a widget needs to play it.
export type FileFacts = {
    id: string;
    post: string;
    kind: "video" | "image";
    // the public file URL; null when the file is not public
    url: string | null;
    // true when the file is not public and plays through a signed preview
    private: boolean;
    // the poster is in the media bucket
    has_poster: boolean;
    width: number | null;
    height: number | null;
};
export type PostsRead = {
    // by post key; a hidden or deleted post is not here
    posts: Map<string, PostFacts>;
    // file id -> its post key (only for posts that are here)
    postOfFile: Map<string, string>;
    // file id -> its playing facts (only for posts that are here)
    files: Map<string, FileFacts>;
    // gallery link id -> how many files it holds
    setFiles: Map<string, number>;
};

// D1 allows 100 bound parameters a statement; every list here is one JSON parameter read with json_each instead, so
// there is nothing to chunk, and the whole read is ONE batch (one round trip).
const FILES_SQL = `SELECT m.id, m.name, m.link, m.poster, m.url, m.content_type, m.bucket, m.r2_key, m.source, m.role, m.item_index,
        m.duration, m.width, m.height, m.bytes, m.visibility, m.created_at, ${POST_KEY_SQL} AS post_key
    FROM media_items m WHERE m.deleted_at IS NULL`;
const IN_LIST = (n: number) => `(SELECT value FROM json_each(?${n}))`;

// the posts that ?1 (post keys) and ?2 (file ids) name: a file id brings its whole post
const NAMED = `(post_key IN ${IN_LIST(1)} OR post_key IN (SELECT post_key FROM (${FILES_SQL}) WHERE id IN ${IN_LIST(2)}))`;

const MAX_IDS = 1000;
const uniq = (ids: string[]) => [...new Set(ids.filter((i) => typeof i === "string" && i.length > 0 && i.length <= 2048))].slice(0, MAX_IDS);

type Statement = D1PreparedStatement;
const asRows = (r: unknown): Rec[] => arr(rec(r).results).map(rec);

// Posts (by post key) and files (by file id; their posts come along) for the pictures and status of a list, plus the file
// counts of gallery links. Hidden posts (section 37) and private links (section 36) are read in the same batch; a database
// without those tables (migrations 0024, 0025 not applied) just reads without them.
export async function readPosts(op: Pick<OpContext, "db" | "mediaBaseUrl" | "shareBaseUrl">, want: { posts?: string[]; files?: string[]; sets?: string[] }): Promise<PostsRead> {
    const posts = uniq(want.posts ?? []);
    const files = uniq(want.files ?? []);
    const sets = uniq(want.sets ?? []);
    const out: PostsRead = { posts: new Map(), postOfFile: new Map(), files: new Map(), setFiles: new Map() };
    if (posts.length === 0 && files.length === 0 && sets.length === 0) return out;
    const db = op.db;
    const pj = JSON.stringify(posts);
    const fj = JSON.stringify(files);
    const core: Statement[] = [
        db
            .prepare(`SELECT * FROM (${FILES_SQL}) WHERE ${NAMED} ORDER BY created_at DESC, id DESC`)
            .bind(pj, fj),
        db.prepare(`SELECT id, items FROM share_sets WHERE revoked_at IS NULL AND id IN ${IN_LIST(1)}`).bind(JSON.stringify(sets)),
    ];
    const hiddenSql = `SELECT DISTINCT post_key FROM media_hidden WHERE state = 'hidden' AND post_key IN (SELECT post_key FROM (${FILES_SQL}) WHERE ${NAMED})`;
    const privateSql = `SELECT DISTINCT f.post_key AS post_key FROM private_links l
        JOIN (${FILES_SQL}) f ON f.id = l.target_id
        WHERE l.kind = 'item' AND l.revoked_at IS NULL AND f.post_key IN (SELECT post_key FROM (${FILES_SQL}) WHERE ${NAMED})`;
    const extra: Statement[] = [db.prepare(hiddenSql).bind(pj, fj), db.prepare(privateSql).bind(pj, fj)];

    let answers: unknown[];
    if (typeof (db as { batch?: unknown }).batch === "function") {
        try {
            answers = await db.batch([...core, ...extra]);
        } catch {
            // one failing statement fails the batch (a table of a migration not applied yet): the core alone, then each extra alone
            answers = [...(await db.batch(core)), ...(await Promise.all(extra.map((s) => s.all().catch(() => ({ results: [] })))))];
        }
    } else {
        answers = [];
        for (const s of core) answers.push(await s.all());
        for (const s of extra) answers.push(await s.all().catch(() => ({ results: [] })));
    }

    const fileRows = asRows(answers[0]);
    for (const r of asRows(answers[1])) {
        let n = 0;
        try {
            n = arr(JSON.parse(String(r.items))).length;
        } catch {
            /* a bad row counts no files */
        }
        out.setFiles.set(String(r.id), n);
    }
    const hidden = new Set(asRows(answers[2]).map((r) => String(r.post_key)));
    const privately = new Set(asRows(answers[3]).map((r) => String(r.post_key)));

    const mediaPrefix = op.mediaBaseUrl.endsWith("/") ? op.mediaBaseUrl : `${op.mediaBaseUrl}/`;
    const hasPoster = (f: { poster: string | null }) => !!f.poster && f.poster.startsWith(mediaPrefix);
    const kindOfType = (ct: string | null): "video" | "image" => (ct && ct.toLowerCase().startsWith("video/") ? "video" : "image");
    const built = postsFrom(fileRows as never, [], [], op.mediaBaseUrl);
    const share = op.shareBaseUrl ? (op.shareBaseUrl.endsWith("/") ? op.shareBaseUrl : `${op.shareBaseUrl}/`) : null;
    for (const p of built) {
        const id = p.record.id;
        if (hidden.has(id)) continue;
        const status: PostFacts["status"] = p.record.public ? "public" : privately.has(id) ? "private" : "off";
        const lead = p.lead;
        const leadPublic = effectiveVisibility(lead) === "public" && !!lead.url;
        const name = leadPublic ? (/\/([A-Za-z0-9]{6,40})\.[A-Za-z0-9]{1,8}$/.exec(lead.url!)?.[1] ?? null) : null;
        out.posts.set(id, {
            // a picture a browser can load: only for a post that has a public link
            thumb_url: status === "public" ? p.picture : null,
            status,
            kind: p.record.kind,
            files: p.record.files,
            duration: p.record.duration,
            bytes: num(lead.bytes),
            share_url: share && name && p.record.kind !== "gallery" ? `${share}${name}` : null,
            lead_id: lead.id,
            thumb_source: hasPoster(lead) ? "poster" : kindOfType(lead.content_type) === "image" ? "file" : null,
        });
        for (const f of p.rows) {
            out.postOfFile.set(f.id, id);
            const isPublic = effectiveVisibility(f) === "public" && !!f.url;
            out.files.set(f.id, {
                id: f.id,
                post: id,
                kind: kindOfType(f.content_type),
                url: isPublic ? f.url : null,
                private: !isPublic,
                has_poster: hasPoster(f),
                width: num(f.width),
                height: num(f.height),
            });
        }
    }
    return out;
}

const KINDS = ["video", "image", "gallery"] as const;
const kindOf = (v: unknown): PostSummary["kind"] | null => (KINDS as readonly unknown[]).includes(v) ? (v as PostSummary["kind"]) : null;

// A PostSummary from an op's post record (library.list / library.search / library.post) and what readPosts found. Null
// when the post is not in `read` (hidden, or gone).
export function summaryOf(record: unknown, read: PostsRead): PostSummary | null {
    const r = rec(record);
    const id = str(r.id);
    if (!id) return null;
    const facts = read.posts.get(id);
    if (!facts) return null;
    return {
        id,
        title: str(r.title) || "Untitled",
        kind: kindOf(r.kind) ?? facts.kind,
        thumb_url: facts.thumb_url,
        duration_s: num(r.duration) ?? facts.duration,
        saved_at: str(r.saved_at) ?? new Date(0).toISOString(),
        source_host: str(r.source),
        status: facts.status,
        files: int(r.files, facts.files),
        bytes: facts.bytes,
    };
}

// "Title · video · id · share link" (the share link where there is one)
export function postLine(p: PostSummary, share: string | null): string {
    return [cut(p.title, 80), p.kind, p.id, share].filter(Boolean).join(" · ");
}

// A post that is not public has no picture a browser can load; its poster (or, for a picture, the file) is given as a signed
// preview link instead (MCP-APP-CONTRACT.md section 9), filed under the post's id in the result's `_meta` (`thumb`), never in
// structuredContent. A post that is hidden is not in `read`, so it never gets one.
export async function signThumbs(ctx: Pick<AppToolCtx, "preview">, read: PostsRead, summaries: PostSummary[]): Promise<void> {
    await Promise.all(
        summaries.map(async (p) => {
            const f = read.posts.get(p.id);
            if (!f || p.status === "public" || p.thumb_url || !f.thumb_source) return;
            await ctx.preview(p.id, f.lead_id, "thumb", f.thumb_source === "poster");
        }),
    );
}
