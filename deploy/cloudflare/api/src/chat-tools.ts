// Chat (APP-API-CONTRACT.md section 27.3): the library tools the model's sandboxed code calls, as
// plain async functions over D1. Read-only: `look` and `show` only collect ids for the reply. Free of
// Cloudflare imports so the tests run them under node.

import { whyFor } from "./about";
import { POST_KEY_SQL } from "./app-routes";
import { searchPosts, type EmbedClient } from "./embed";
import { effectiveVisibility } from "./visibility";
import { collectionPostIds, resolveWithin, WithinError, WITHIN_POSTS_MAX, type WithinSpec } from "./within";

export const LIBRARY_DEFAULT_LIMIT = 100;
export const LIBRARY_MAX_LIMIT = 1000;
export const SEARCH_MAX = 500;
export const COLLAGE_MAX = 500;
export const LOOK_MAX = 4;
export const SHOW_MAX = 12;
// cobalt.rank (section 34.6)
export const RANK_MAX = 50;
export const RANK_WHY_MAX = 4;
export const RANK_WHY_CHARS = 30;

export type ChatToolDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    shareBaseUrl?: string;
    embed: EmbedClient | null;
};

type FileRow = {
    id: string;
    name: string | null;
    link: string | null;
    poster: string | null;
    url: string | null;
    content_type: string | null;
    bucket: string;
    source: string;
    role: string | null;
    item_index: number | null;
    duration: number | null;
    width: number | null;
    height: number | null;
    bytes: number | null;
    visibility: string | null;
    created_at: number;
    post_key: string;
};

export type PostRecord = {
    id: string;
    title: string | null;
    saved_at: string;
    source: string | null;
    link: string | null;
    kind: "video" | "image" | "gallery";
    files: number;
    duration: number | null;
    public: boolean;
    caption: string | null;
};

type Post = { record: PostRecord; rows: FileRow[]; lead: FileRow; latest: number; picture: string | null };

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

const hostOf = (link: string | null): string | null => {
    if (!link || !/^https?:\/\//i.test(link)) return null;
    try {
        return new URL(link).hostname.replace(/^www\./, "").toLowerCase();
    } catch {
        return null;
    }
};

const isPublic = (r: FileRow) => effectiveVisibility(r) === "public" && !!r.url;
const kindOf = (ct: string | null): "video" | "image" => ((ct ?? "").startsWith("video/") ? "video" : "image");

// The post's lead file, as GET /library picks it: a gallery's first video, else its first item;
// else the original; else the newest row.
function leadOf(fs: FileRow[]): FileRow {
    const items = fs.filter((f) => f.role === "item").sort((a, b) => (a.item_index ?? 0) - (b.item_index ?? 0));
    return (
        items.find((f) => kindOf(f.content_type) === "video") ??
        items[0] ??
        fs.find((f) => f.bucket === "originals" && (f.source === "saved" || f.source === "upload")) ??
        fs[0]!
    );
}

// Every live post, newest first, with what the tools report and what `look` may show.
export async function loadPosts(d: Pick<ChatToolDeps, "db" | "mediaBaseUrl">, onlyIds?: string[]): Promise<Post[]> {
    if (onlyIds && onlyIds.length === 0) return [];
    const where = onlyIds ? ` WHERE post_key IN (${onlyIds.map((_, i) => `?${i + 1}`).join(", ")})` : "";
    const stmt = d.db.prepare(
        `SELECT * FROM (SELECT m.id, m.name, m.link, m.poster, m.url, m.content_type, m.bucket, m.source, m.role, m.item_index,
                               m.duration, m.width, m.height, m.bytes, m.visibility, m.created_at, ${POST_KEY_SQL} AS post_key
                        FROM media_items m WHERE m.deleted_at IS NULL)${where}
         ORDER BY created_at DESC, id DESC`,
    );
    const { results: rows } = await (onlyIds ? stmt.bind(...onlyIds) : stmt).all<FileRow>();
    if (rows.length === 0) return [];
    const keys = [...new Set(rows.map((r) => r.post_key))];
    const titles = new Map<string, string>();
    const captions = new Map<string, string>();
    // titles and captions for these posts (all of them when listing the library)
    const tStmt = d.db.prepare(`SELECT post_key, title FROM media_titles${onlyIds ? where : ""}`);
    for (const t of (await (onlyIds ? tStmt.bind(...onlyIds) : tStmt).all<{ post_key: string; title: string }>()).results) titles.set(t.post_key, t.title);
    const { results: caps } = await d.db
        .prepare("SELECT subject, title FROM media_captions WHERE title IS NOT NULL AND subject LIKE 'item:%'")
        .all<{ subject: string; title: string }>();
    for (const c of caps) captions.set(c.subject.slice(5), c.title);

    const byPost = new Map<string, FileRow[]>();
    for (const r of rows) {
        const list = byPost.get(r.post_key);
        if (list) list.push(r);
        else byPost.set(r.post_key, [r]);
    }
    const base = withSlash(d.mediaBaseUrl);
    const out: Post[] = [];
    for (const key of keys) {
        const fs = byPost.get(key)!;
        const lead = leadOf(fs);
        const items = fs.filter((f) => f.role === "item");
        const link = lead.link ?? fs.find((f) => f.link)?.link ?? null;
        const caption = fs.map((f) => captions.get(f.id)).find(Boolean) ?? null;
        const pictureOf = (f: FileRow) =>
            f.poster && f.poster.startsWith(base)
                ? f.poster
                : kindOf(f.content_type) === "image" && isPublic(f) && /\.(jpe?g|png|gif|webp)$/i.test(f.url!)
                  ? f.url
                  : null;
        out.push({
            lead,
            rows: fs,
            latest: fs[0]!.created_at,
            picture: pictureOf(lead) ?? fs.map(pictureOf).find(Boolean) ?? null,
            record: {
                id: key,
                title: titles.get(key) ?? lead.name ?? null,
                saved_at: new Date(fs[fs.length - 1]!.created_at).toISOString(),
                source: hostOf(link),
                link,
                kind: items.length > 1 ? "gallery" : kindOf(lead.content_type),
                files: Math.max(1, items.length),
                duration: lead.duration ?? null,
                public: fs.some(isPublic),
                caption,
            },
        });
    }
    out.sort((a, b) => b.latest - a.latest || (a.record.id < b.record.id ? 1 : -1));
    return out;
}

const toMs = (v: unknown, name: string): number | null => {
    if (v === undefined || v === null) return null;
    const ms = typeof v === "number" ? v : typeof v === "string" ? Date.parse(v) : NaN;
    if (!Number.isFinite(ms)) throw new Error(`${name} must be an ISO date or milliseconds`);
    return ms;
};

const clampLimit = (v: unknown, def: number, max: number): number => {
    if (v === undefined || v === null) return def;
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1) throw new Error(`limit must be a whole number from 1 to ${max}`);
    return Math.min(n, max);
};

const idList = (v: unknown): string[] => {
    const arr = Array.isArray(v) ? v : [v];
    return [...new Set(arr.filter((x): x is string => typeof x === "string" && x.length > 0 && x.length <= 2048))];
};

// What one reply's tool calls collected: pictures to look at, files to show.
// collage: one big result set for the reply (section 27.5); a later call replaces it.
// ranked: one scored list for the reply (section 34.6, cobalt.rank); a later call replaces it. undefined: never set in
// this reply (the message's column is left alone).
export type RankedHit = { post_id: string; score: number | null; why: string[] };
export type Ranked = { title: string | null; query: string | null; within: string | null; hits: RankedHit[] };
export type ChatCollect = {
    look: string[];
    show: string[];
    collage?: { title: string | null; query: string | null; ids: string[] } | null;
    ranked?: Ranked | null;
};

// search(query, limit) or search(query, { within, limit }); a string `within` is a collection id or name.
function searchArgs(second: unknown): { limit: unknown; within: WithinSpec | null } {
    if (second === undefined || second === null || typeof second === "number" || typeof second === "string") return { limit: second, within: null };
    if (typeof second !== "object" || Array.isArray(second)) throw new Error("search(query, opts): opts must be { within?, limit? }");
    const o = second as { limit?: unknown; within?: unknown };
    const w = o.within;
    if (w === undefined || w === null) return { limit: o.limit, within: null };
    if (typeof w === "string") return { limit: o.limit, within: { collection: w } };
    if (typeof w === "object" && !Array.isArray(w)) {
        const x = w as Record<string, unknown>;
        const keys = ["collection", "link", "posts"].filter((k) => x[k] !== undefined);
        if (keys.length === 1) {
            if (typeof x.collection === "string" && x.collection) return { limit: o.limit, within: { collection: x.collection } };
            if (typeof x.link === "string" && x.link) return { limit: o.limit, within: { link: x.link } };
            if (Array.isArray(x.posts) && x.posts.length <= WITHIN_POSTS_MAX && x.posts.every((p) => typeof p === "string" && p.length > 0 && p.length <= 2048)) {
                return { limit: o.limit, within: { posts: x.posts as string[] } };
            }
        }
    }
    throw new Error(`within must be { collection: id or name } or { link: id } or { posts: [ids] } (at most ${WITHIN_POSTS_MAX})`);
}

export type ChatTools = Record<string, (...args: any[]) => Promise<unknown>>;

export function chatTools(d: ChatToolDeps, collect: ChatCollect): ChatTools {
    let cache: Promise<Post[]> | null = null;
    const all = () => (cache ??= loadPosts(d));
    const known = async (ids: string[]) => {
        const set = new Set((await all()).map((p) => p.record.id));
        return ids.filter((i) => set.has(i));
    };
    return {
        async library(opts: Record<string, unknown> = {}) {
            const o = opts && typeof opts === "object" ? opts : {};
            const since = toMs(o.since, "since");
            const until = toMs(o.until, "until");
            const limit = clampLimit(o.limit, LIBRARY_DEFAULT_LIMIT, LIBRARY_MAX_LIMIT);
            const source = typeof o.source === "string" ? o.source.toLowerCase().replace(/^www\./, "") : null;
            const kind = typeof o.kind === "string" ? o.kind : null;
            const q = typeof o.query === "string" ? o.query.toLowerCase() : null;
            return (await all())
                .filter((p) => {
                    const r = p.record;
                    const t = Date.parse(r.saved_at);
                    if (since !== null && t < since) return false;
                    if (until !== null && t >= until) return false;
                    if (source && !(r.source === source || r.source?.endsWith(`.${source}`))) return false;
                    if (kind && r.kind !== kind) return false;
                    if (q) {
                        const hay = `${r.title ?? ""} ${p.rows.map((f) => f.name ?? "").join(" ")} ${r.link ?? ""} ${r.caption ?? ""}`.toLowerCase();
                        if (!hay.includes(q)) return false;
                    }
                    return true;
                })
                .slice(0, limit)
                .map((p) => p.record);
        },
        async search(query: unknown, second?: unknown) {
            if (typeof query !== "string") throw new Error("search(query) needs a string");
            const { limit, within: spec } = searchArgs(second);
            // within a set every post is scored: the default is all of them (section 34.6)
            const n = clampLimit(limit, spec ? SEARCH_MAX : 10, SEARCH_MAX);
            let within: Set<string> | undefined;
            if (spec) {
                try {
                    within = (await resolveWithin(d.db, spec)).postKeys;
                } catch (e) {
                    if (e instanceof WithinError) {
                        throw new Error(
                            e.code === "error.collection.not_found"
                                ? `no collection ${JSON.stringify((spec as { collection: string }).collection)} (see collections())`
                                : `no live gallery link ${JSON.stringify((spec as { link: string }).link)} (see links())`,
                        );
                    }
                    throw e;
                }
            }
            const r = await searchPosts({ db: d.db, client: d.embed, mediaBaseUrl: d.mediaBaseUrl }, query, n, within ? { within } : {});
            if (!r.ok) {
                throw new Error(
                    r.code === "error.search.waking" ? "search is waking up, try again in a minute or use library({ query })" :
                    r.code === "error.search.off" ? "search is not configured; use library({ query })" :
                    r.code === "error.library.bad_request" ? "query must be 1 to 200 characters" : "search failed",
                );
            }
            const posts = new Map((await all()).map((p) => [p.record.id, p.record]));
            const why = await whyFor(d.db, r.queryVector, query.trim(), r.hits.map((h) => h.post_key));
            return r.hits.flatMap((h) => {
                const rec = posts.get(h.post_key);
                return rec
                    ? [{ ...rec, score: Math.round(h.score * 1000) / 1000, why: why.get(h.post_key) ?? [], ...(h.indexed ? {} : { indexed: false }) }]
                    : [];
            });
        },
        async post(id: unknown) {
            if (typeof id !== "string") throw new Error("post(id) needs a post id string");
            const p = (await all()).find((x) => x.record.id === id);
            if (!p) throw new Error(`no post with id ${id}`);
            const share = d.shareBaseUrl ? withSlash(d.shareBaseUrl) : null;
            return {
                ...p.record,
                files: p.rows.map((f) => {
                    const pub = isPublic(f);
                    const name = pub ? (/\/([A-Za-z0-9]{6,40})\.[A-Za-z0-9]{1,8}$/.exec(f.url!)?.[1] ?? null) : null;
                    return {
                        id: f.id,
                        name: f.name,
                        role: f.role ?? (f.bucket === "originals" ? "original" : f.source),
                        kind: kindOf(f.content_type),
                        content_type: f.content_type,
                        duration: f.duration,
                        width: f.width,
                        height: f.height,
                        bytes: f.bytes,
                        public: pub,
                        url: pub ? f.url : null,
                        share_url: share && name ? `${share}${name}` : null,
                    };
                }),
            };
        },
        async look(ids: unknown) {
            const ok = await known(idList(ids));
            for (const i of ok) if (!collect.look.includes(i) && collect.look.length < LOOK_MAX) collect.look.push(i);
            return collect.look.length;
        },
        async show(ids: unknown) {
            const ok = await known(idList(ids));
            const added: string[] = [];
            for (const i of ok) {
                if (collect.show.includes(i) || collect.show.length >= SHOW_MAX) continue;
                collect.show.push(i);
                added.push(i);
            }
            return added;
        },
        async collage(ids: unknown, opts?: unknown) {
            const ok = (await known(idList(ids))).slice(0, COLLAGE_MAX);
            const o = typeof opts === "string" ? { title: opts } : opts && typeof opts === "object" ? (opts as Record<string, unknown>) : {};
            const line = (v: unknown, max: number) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "") || null;
            collect.collage = ok.length > 0 ? { title: line(o.title, 80), query: line(o.query, 200), ids: ok } : null;
            return ok.length;
        },
        // cobalt.rank(hits, { title, query, within }) (section 34.6): a scored list under the reply; a later call replaces it.
        async rank(hits: unknown, opts?: unknown) {
            const list = Array.isArray(hits) ? hits : [];
            const seen = new Set<string>();
            const wanted: { id: string; score: number | null; why: string[] }[] = [];
            const line = (v: unknown, max: number) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "") || null;
            for (const h of list) {
                const id = typeof h === "string" ? h : h && typeof h === "object" ? (h as { id?: unknown }).id : undefined;
                if (typeof id !== "string" || id.length === 0 || id.length > 2048 || seen.has(id)) continue;
                seen.add(id);
                const raw = h && typeof h === "object" ? (h as { score?: unknown; why?: unknown }) : {};
                const score = typeof raw.score === "number" && Number.isFinite(raw.score) ? Math.round(raw.score * 1000) / 1000 : null;
                const why = (Array.isArray(raw.why) ? raw.why : [])
                    .map((w) => line(w, RANK_WHY_CHARS))
                    .filter((w): w is string => !!w)
                    .slice(0, RANK_WHY_MAX);
                wanted.push({ id, score, why });
            }
            const live = new Set(await known(wanted.map((w) => w.id)));
            const kept = wanted.filter((w) => live.has(w.id)).slice(0, RANK_MAX);
            const o = opts && typeof opts === "object" ? (opts as Record<string, unknown>) : {};
            collect.ranked =
                kept.length > 0
                    ? {
                          title: line(o.title, 80),
                          query: line(o.query, 200),
                          within: line(o.within, 80),
                          hits: kept.map((k) => ({ post_id: k.id, score: k.score, why: k.why })),
                      }
                    : null;
            return kept.length;
        },
        async links() {
            const { results } = await d.db
                .prepare("SELECT id, items, title, created_at FROM share_sets WHERE revoked_at IS NULL ORDER BY created_at DESC LIMIT 200")
                .all<{ id: string; items: string; title: string | null; created_at: number }>();
            if (results.length === 0) return [];
            const postOf = new Map<string, string>();
            for (const p of await all()) for (const f of p.rows) postOf.set(f.id, p.record.id);
            const share = d.shareBaseUrl ? withSlash(d.shareBaseUrl) : null;
            return results.map((s) => {
                let items: string[] = [];
                try {
                    items = JSON.parse(s.items);
                } catch {
                    /* a bad row lists no posts */
                }
                return {
                    id: s.id,
                    url: share ? `${share}g/${s.id}` : null,
                    title: s.title,
                    created_at: new Date(s.created_at).toISOString(),
                    post_ids: [...new Set(items.map((i) => postOf.get(i)).filter((x): x is string => !!x))],
                };
            });
        },
        async collections() {
            const { results: cols } = await d.db
                .prepare("SELECT id, name FROM share_collections ORDER BY updated_at DESC, id DESC LIMIT 100")
                .all<{ id: string; name: string }>();
            if (cols.length === 0) return [];
            const { results: items } = await d.db
                .prepare(
                    `SELECT i.collection_id, i.set_id FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id
                      WHERE s.revoked_at IS NULL ORDER BY i.added_at DESC`,
                )
                .all<{ collection_id: string; set_id: string }>();
            const out = [];
            for (const c of cols) {
                // the posts of its live links' files (section 34.6), the ids search(q, { within }) and post() take
                out.push({
                    id: c.id,
                    name: c.name,
                    link_ids: items.filter((i) => i.collection_id === c.id).map((i) => i.set_id),
                    post_ids: [...(await collectionPostIds(d.db, c.id))],
                });
            }
            return out;
        },
    };
}

// The pictures for `look`: post id -> a public image URL, for the posts that have one.
export async function picturesOf(d: Pick<ChatToolDeps, "db" | "mediaBaseUrl">, ids: string[]): Promise<Map<string, string>> {
    const posts = await loadPosts(d, ids);
    return new Map(posts.filter((p) => p.picture).map((p) => [p.record.id, p.picture!]));
}

// The records for posts the user attached to a message.
export async function recordsOf(d: Pick<ChatToolDeps, "db" | "mediaBaseUrl">, ids: string[]): Promise<PostRecord[]> {
    const posts = new Map((await loadPosts(d, ids)).map((p) => [p.record.id, p.record]));
    return ids.flatMap((i) => (posts.has(i) ? [posts.get(i)!] : []));
}

// The TypeScript the model is shown for these tools (TOOL_TYPES) is generated from the op registry: src/registry/index.ts,
// whose ops (src/registry/ops/library.ts) call the functions above.
