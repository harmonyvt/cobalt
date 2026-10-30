// "What it's about" (APP-API-CONTRACT.md section 34): the D1 side shared by the probe (about-probe.ts, in the Durable
// Object), the writer (about-writer.ts, the cron), the search inputs (embed.ts) and the routes (about.ts). One
// `media_about` row per post (migration 0022), keyed by the GET /library post key, pointing at the post's lead file.
// Free of Cloudflare imports so it runs under node in the tests.

import { POST_KEY_SQL } from "./app-routes";

export const ABOUT_MODEL_DEFAULT = "claude-haiku-5-5";
// The frames and sound of a probe live in R2 `cobalt-originals` under about/<item id>/ (private; deleted with the item).
export const ABOUT_PREFIX = "about/";
export const ABOUT_MAX_FRAMES = 3;
export const TRANSCRIPT_MAX = 4000;
export const SENTENCE_MAX = 160;
export const TAG_MAX_CHARS = 30;
export const TAGS_MAX = 12;
export const SOUND_TAGS_MAX = 6;
export const USER_TAGS_MAX = 16;
// A failed probe or description is tried again this long after, at most this many times (until its input changes).
export const ABOUT_RETRY_MS = 24 * 60 * 60 * 1000;
export const ABOUT_MAX_ATTEMPTS = 3;

export type ProbeState = "pending" | "done" | "none" | "failed";

export type AboutRow = {
    post_key: string;
    item_id: string;
    probe_state: ProbeState;
    probe_at: number | null;
    probe_attempts: number;
    frames: number;
    has_audio: number;
    transcript: string | null;
    language: string | null;
    sentence: string | null;
    tags: string | null;
    sound_tags: string | null;
    user_tags: string | null;
    model: string | null;
    input_hash: string | null;
    written_at: number | null;
    failed_at: number | null;
    attempts: number;
    updated_at: number;
};

export const frameKey = (itemId: string, n: number) => `${ABOUT_PREFIX}${itemId}/frame-${n}.jpg`;
export const audioKey = (itemId: string) => `${ABOUT_PREFIX}${itemId}/audio.mp3`;
export const aboutObjectKeys = (itemId: string): string[] => [
    ...Array.from({ length: ABOUT_MAX_FRAMES }, (_, i) => frameKey(itemId, i + 1)),
    audioKey(itemId),
];

// The probe's objects of one file go (best effort: a failure is logged, never thrown).
export async function deleteAboutObjects(bucket: { delete(key: string): Promise<unknown> } | undefined, itemId: string): Promise<void> {
    if (!bucket) return;
    for (const key of aboutObjectKeys(itemId)) {
        try {
            await bucket.delete(key);
        } catch (e) {
            console.error("[about] deleting a probe object failed", key, String(e));
        }
    }
}

export function parseList(s: string | null | undefined): string[] {
    if (!s) return [];
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
}

// The tags a post shows and is searched by: the owner's when set, else Haiku's.
export const effectiveTags = (r: Pick<AboutRow, "tags" | "user_tags">): string[] =>
    r.user_tags !== null && r.user_tags !== undefined ? parseList(r.user_tags) : parseList(r.tags);

const codePoints = (s: string) => Array.from(s).length;

// One tag as stored: trimmed, lowercased, inner whitespace collapsed, no control characters; null when empty or longer
// than TAG_MAX_CHARS code points.
export function cleanTag(v: unknown): string | null {
    if (typeof v !== "string") return null;
    // eslint-disable-next-line no-control-regex
    const t = v.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().toLowerCase();
    if (t === "" || codePoints(t) > TAG_MAX_CHARS) return null;
    return t;
}

// The model's list, leniently: bad entries dropped, duplicates dropped, at most `max`.
export function cleanTagList(v: unknown, max: number): string[] {
    if (!Array.isArray(v)) return [];
    const out: string[] = [];
    for (const x of v) {
        const t = cleanTag(x);
        if (t && !out.includes(t)) out.push(t);
        if (out.length >= max) break;
    }
    return out;
}

// ---- the post's lead file -------------------------------------------------------------------------------------------

export type LeadFields = { role: string | null; item_index: number | null; content_type: string | null; bucket: string; source: string };

// The post's lead file, as GET /library picks it (app-routes.ts leadOf): a gallery's first video, else its first item;
// else the original. Undefined when there is none of those (a webp-only post).
export function pickLead<T extends LeadFields>(fs: T[]): T | undefined {
    const items = fs.filter((f) => f.role === "item").sort((a, b) => (a.item_index ?? 0) - (b.item_index ?? 0));
    return (
        items.find((f) => (f.content_type ?? "").startsWith("video/")) ??
        items[0] ??
        fs.find((f) => f.bucket === "originals" && (f.source === "saved" || f.source === "upload"))
    );
}

// A file the probe can cut frames (and maybe sound) from. Stills skip it (probe 'none'): the writer looks at the
// picture itself. An animated webp is a still here (the container's ffmpeg cannot decode it).
export const probeable = (contentType: string | null): boolean => {
    const t = (contentType ?? "").toLowerCase();
    return t.startsWith("video/") || t === "image/gif";
};

export type LeadRow = LeadFields & {
    id: string;
    r2_key: string;
    poster: string | null;
    url: string | null;
    name: string | null;
    link: string | null;
    bytes: number | null;
    created_at: number;
    post_key: string;
};

// Every live post's lead file (newest post first), or only `onlyPostKey`'s.
export async function postLeads(db: D1Database, onlyPostKey?: string): Promise<Map<string, { lead: LeadRow; files: LeadRow[]; latest: number }>> {
    const one = onlyPostKey !== undefined;
    const stmt = db.prepare(
        `SELECT * FROM (SELECT m.id, m.bucket, m.r2_key, m.content_type, m.source, m.role, m.item_index, m.poster, m.url, m.name, m.link,
                               m.bytes, m.created_at, ${POST_KEY_SQL} AS post_key
                        FROM media_items m WHERE m.deleted_at IS NULL)${one ? " WHERE post_key = ?1" : ""}
         ORDER BY created_at DESC, id DESC`,
    );
    const { results } = await (one ? stmt.bind(onlyPostKey) : stmt).all<LeadRow>();
    const byPost = new Map<string, LeadRow[]>();
    for (const r of results) {
        const list = byPost.get(r.post_key);
        if (list) list.push(r);
        else byPost.set(r.post_key, [r]);
    }
    const out = new Map<string, { lead: LeadRow; files: LeadRow[]; latest: number }>();
    for (const [key, files] of byPost) out.set(key, { lead: pickLead(files) ?? files[0]!, files, latest: files[0]!.created_at });
    return out;
}

// ---- keeping one row per live post ----------------------------------------------------------------------------------

type Stmt = ReturnType<D1Database["prepare"]>;
const CHUNK = 50;

export async function runAll(db: D1Database, stmts: Stmt[]): Promise<void> {
    for (let i = 0; i < stmts.length; i += CHUNK) {
        const part = stmts.slice(i, i + CHUNK);
        if (typeof (db as { batch?: unknown }).batch === "function") await db.batch(part);
        else for (const s of part) await s.run();
    }
}

export type SyncResult = { posts: number; created: number; moved: number; removed: number };

// Every live post gets its row (probe 'pending' for a video or gif, 'none' for a still); a post whose lead file changed
// (the lead item was deleted) starts over; the rows of posts that are gone go, with their R2 objects. Throws before
// migration 0022 (no table).
export async function syncAboutRows(
    db: D1Database,
    now: number,
    bucket?: { delete(key: string): Promise<unknown> },
): Promise<SyncResult> {
    const leads = await postLeads(db);
    const { results: rows } = await db.prepare("SELECT post_key, item_id FROM media_about").all<{ post_key: string; item_id: string }>();
    const have = new Map(rows.map((r) => [r.post_key, r.item_id]));
    const stmts: Stmt[] = [];
    const stale: string[] = [];
    const out: SyncResult = { posts: leads.size, created: 0, moved: 0, removed: 0 };
    for (const [key, { lead }] of leads) {
        const state = probeable(lead.content_type) ? "pending" : "none";
        const had = have.get(key);
        if (had === undefined) {
            stmts.push(
                db
                    .prepare("INSERT OR IGNORE INTO media_about (post_key, item_id, probe_state, updated_at) VALUES (?1, ?2, ?3, ?4)")
                    .bind(key, lead.id, state, now),
            );
            out.created++;
        } else if (had !== lead.id) {
            stmts.push(
                db
                    .prepare(
                        `UPDATE media_about SET item_id = ?2, probe_state = ?3, probe_at = NULL, probe_attempts = 0, frames = 0, has_audio = 0,
                                transcript = NULL, language = NULL, updated_at = ?4 WHERE post_key = ?1`,
                    )
                    .bind(key, lead.id, state, now),
            );
            stale.push(had);
            out.moved++;
        }
    }
    for (const r of rows) {
        if (leads.has(r.post_key)) continue;
        stmts.push(db.prepare("DELETE FROM media_about WHERE post_key = ?1").bind(r.post_key));
        stale.push(r.item_id);
        out.removed++;
    }
    await runAll(db, stmts);
    for (const id of stale) await deleteAboutObjects(bucket, id);
    return out;
}

// ---- the words, for the search inputs -------------------------------------------------------------------------------

export type AboutWords = { sentence: string | null; tags: string[]; sound_tags: string[]; transcript: string | null };

// Each post's words (all posts, or only these). Empty before migration 0022.
export async function aboutWordsOf(db: D1Database, onlyPostKey?: string): Promise<Map<string, AboutWords>> {
    try {
        const stmt = db.prepare(
            `SELECT post_key, sentence, tags, sound_tags, user_tags, transcript FROM media_about${onlyPostKey !== undefined ? " WHERE post_key = ?1" : ""}`,
        );
        const { results } = await (onlyPostKey !== undefined ? stmt.bind(onlyPostKey) : stmt).all<
            Pick<AboutRow, "post_key" | "sentence" | "tags" | "sound_tags" | "user_tags" | "transcript">
        >();
        return new Map(
            results.map((r) => [
                r.post_key,
                { sentence: r.sentence, tags: effectiveTags(r), sound_tags: parseList(r.sound_tags), transcript: r.transcript },
            ]),
        );
    } catch {
        return new Map();
    }
}

export async function aboutRowOf(db: D1Database, postKey: string): Promise<AboutRow | null> {
    try {
        return (await db.prepare("SELECT * FROM media_about WHERE post_key = ?1").bind(postKey).first<AboutRow>()) ?? null;
    } catch {
        return null; // before migration 0022
    }
}
