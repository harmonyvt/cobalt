// "What it's about" (APP-API-CONTRACT.md section 34): the post's detail read (GET /library/about), the owner's tags
// (PATCH /library/about), the "why" words of a search hit, and the word list's vectors ("reads closest to", 34.5).
// The probe lives in about-probe.ts (the Durable Object), the writer in about-writer.ts (the cron). Free of Cloudflare
// imports so it runs under node in the tests.

import { STARTER_TERMS } from "./about-terms";
import { aboutRowOf, cleanTag, effectiveTags, parseList, postLeads, probeable, runAll, USER_TAGS_MAX, type AboutRow } from "./about-store";
import { assemblePosts, libraryHide, type AppDeps } from "./app-routes";
import { hiddenPostKeys } from "./hidden-store";
import {
    EMBED_CALL_MS,
    EMBED_DIMS,
    EMBED_MODEL,
    EmbedError,
    decodeVector,
    dot,
    encodeVector,
    librarySearchPost,
    MAX_POST_KEY_CHARS,
    type EmbedClient,
} from "./embed";
import type { StudioReply } from "./studio";

export const NEAREST_WORDS = 8;
export const NEIGHBOURS = 4;
export const WHY_MAX = 3;
export const TERMS_PER_CALL = 32;

const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });
const round2 = (x: number) => Math.round(x * 100) / 100;

// ---- vectors of the word list ---------------------------------------------------------------------------------------

export type TermVector = { term: string; v: Float32Array; mean: number | null };

// Every embedded term of the current model (empty before migration 0022).
export async function termVectors(db: D1Database, only?: string[]): Promise<TermVector[]> {
    try {
        let rows: { term: string; vector: string; mean: number | null }[] = [];
        if (only) {
            const want = [...new Set(only)];
            for (let i = 0; i < want.length; i += 90) {
                const part = want.slice(i, i + 90);
                const { results } = await db
                    .prepare(
                        `SELECT term, vector, mean FROM embed_terms WHERE vector IS NOT NULL AND model = ?1 AND dims = ?2
                           AND term IN (${part.map((_, j) => `?${j + 3}`).join(", ")})`,
                    )
                    .bind(EMBED_MODEL, EMBED_DIMS, ...part)
                    .all<{ term: string; vector: string; mean: number | null }>();
                rows.push(...results);
            }
        } else {
            rows = (
                await db
                    .prepare("SELECT term, vector, mean FROM embed_terms WHERE vector IS NOT NULL AND model = ?1 AND dims = ?2")
                    .bind(EMBED_MODEL, EMBED_DIMS)
                    .all<{ term: string; vector: string; mean: number | null }>()
            ).results;
        }
        const out: TermVector[] = [];
        for (const r of rows) {
            const v = decodeVector(r.vector);
            if (v && v.length === EMBED_DIMS) out.push({ term: r.term, v, mean: r.mean });
        }
        return out;
    } catch {
        return [];
    }
}

// A post's nearest words (34.5): for each term, cosine(post, term) minus the term's average over the library (so a word
// close to everything, like "video", does not win everywhere), best first, rounded to 2 places.
export function nearestWords(post: ArrayLike<number>, terms: TermVector[], n = NEAREST_WORDS): { word: string; score: number }[] {
    return terms
        .map((t) => ({ word: t.term, raw: dot(post, t.v) - (t.mean ?? 0) }))
        .sort((a, b) => b.raw - a.raw || (a.word < b.word ? -1 : 1))
        .slice(0, n)
        .map((x) => ({ word: x.word, score: round2(x.raw) }));
}

// The "why" of search hits (34.6): up to WHY_MAX of each post's tags and sound tags, closest to the query first (by the
// tag's own vector; a tag without one ranks by whether the query names it). Empty for a post with no words yet.
export async function whyFor(db: D1Database, queryVector: number[] | null, query: string, postKeys: string[]): Promise<Map<string, string[]>> {
    const out = new Map<string, string[]>();
    if (postKeys.length === 0) return out;
    const words = new Map<string, string[]>();
    try {
        const keys = [...new Set(postKeys)];
        for (let i = 0; i < keys.length; i += 90) {
            const part = keys.slice(i, i + 90);
            const { results } = await db
                .prepare(`SELECT post_key, tags, user_tags, sound_tags FROM media_about WHERE post_key IN (${part.map((_, j) => `?${j + 1}`).join(", ")})`)
                .bind(...part)
                .all<Pick<AboutRow, "post_key" | "tags" | "user_tags" | "sound_tags">>();
            for (const r of results) words.set(r.post_key, [...new Set([...effectiveTags(r), ...parseList(r.sound_tags)])]);
        }
    } catch {
        return out; // before migration 0022
    }
    const all = [...new Set([...words.values()].flat())];
    const vecs = new Map((queryVector ? await termVectors(db, all) : []).map((t) => [t.term, t.v]));
    const q = query.toLowerCase();
    const scoreOf = (tag: string): number => {
        const named = q.includes(tag) || tag.split(" ").some((w) => w.length >= 3 && q.includes(w)) ? 1 : 0;
        const v = vecs.get(tag);
        return queryVector && v ? dot(queryVector, v) + named : named - 1;
    };
    for (const key of postKeys) {
        const tags = words.get(key) ?? [];
        out.set(
            key,
            tags
                .map((t, i) => ({ t, s: scoreOf(t), i }))
                .sort((a, b) => b.s - a.s || a.i - b.i)
                .slice(0, WHY_MAX)
                .map((x) => x.t),
        );
    }
    return out;
}

// ---- GET /library/about ---------------------------------------------------------------------------------------------

export type AboutDeps = { db: D1Database; mediaBaseUrl: string; searchEnabled: boolean; app: AppDeps; now: () => number };

const aboutShape = (r: AboutRow | null) =>
    r && (r.written_at !== null || r.user_tags !== null)
        ? {
              sentence: r.sentence,
              tags: effectiveTags(r),
              edited: r.user_tags !== null,
              sound_tags: parseList(r.sound_tags),
              transcript: r.transcript,
              language: r.language,
              frames: r.frames,
              has_audio: !!r.has_audio,
              model: r.model,
              written_at: r.written_at,
          }
        : null;

// Live post keys and when each was last added to (for the post shapes of the neighbours).
async function livePostTimes(db: D1Database): Promise<Map<string, number>> {
    const leads = await postLeads(db);
    return new Map([...leads].map(([k, v]) => [k, v.latest]));
}

export async function libraryAbout(d: AboutDeps, key: string): Promise<StudioReply> {
    if (key.length === 0 || key.length > MAX_POST_KEY_CHARS) return err(400, "error.library.bad_request");
    try {
        const index = await librarySearchPost({ db: d.db, mediaBaseUrl: d.mediaBaseUrl, searchEnabled: d.searchEnabled }, new URLSearchParams({ key }));
        if (index.status !== 200) return index;
        const { status: _, ...indexBody } = index.body as Record<string, unknown>;
        const row = await aboutRowOf(d.db, key);

        let words: { word: string; score: number }[] = [];
        let neighbours: { post_id: string; score: number }[] = [];
        let posts: Record<string, unknown> = {};
        if (d.searchEnabled) {
            const { results } = await d.db
                .prepare("SELECT post_key, vector FROM media_embeddings WHERE model = ?1 AND dims = ?2 AND vector IS NOT NULL")
                .bind(EMBED_MODEL, EMBED_DIMS)
                .all<{ post_key: string; vector: string }>();
            const mine = results.find((r) => r.post_key === key);
            const v = mine ? decodeVector(mine.vector) : null;
            if (v && v.length === EMBED_DIMS) {
                words = nearestWords(v, await termVectors(d.db));
                const live = await livePostTimes(d.db);
                // a hidden post is nobody's neighbour (section 37.2)
                for (const k of await hiddenPostKeys(d.db)) live.delete(k);
                const near: { post_id: string; raw: number }[] = [];
                for (const r of results) {
                    if (r.post_key === key || !live.has(r.post_key)) continue;
                    const o = decodeVector(r.vector);
                    if (o && o.length === EMBED_DIMS) near.push({ post_id: r.post_key, raw: dot(v, o) });
                }
                near.sort((a, b) => b.raw - a.raw || (a.post_id < b.post_id ? -1 : 1));
                const top = near.slice(0, NEIGHBOURS);
                const { posts: shaped } = await assemblePosts(
                    d.app,
                    top.map((n) => ({ post_key: n.post_id, latest: live.get(n.post_id)! })),
                    { v2: true, v3: true, hide: libraryHide(true, true), now: d.now() },
                );
                for (const p of shaped) if (Array.isArray(p.files) && p.files.length > 0) posts[p.id] = p;
                neighbours = top.filter((n) => n.post_id in posts).map((n) => ({ post_id: n.post_id, score: round2(n.raw) }));
                posts = Object.fromEntries(neighbours.map((n) => [n.post_id, posts[n.post_id]]));
            }
        }
        return {
            status: 200,
            body: {
                status: "success",
                post_key: key,
                probe: row?.probe_state ?? "pending",
                about: aboutShape(row),
                words,
                neighbours,
                posts,
                index: indexBody,
            },
        };
    } catch (e) {
        console.error("[about] read failed", String(e));
        return err(503, "error.api.generic");
    }
}

// ---- PATCH /library/about -------------------------------------------------------------------------------------------

// The owner's tags: null (back to Haiku's), or 0..USER_TAGS_MAX tags, each trimmed, lowercased, 1..30 code points;
// duplicates dropped. Anything else: null (a bad request).
export function parseUserTags(v: unknown): { ok: true; tags: string[] | null } | { ok: false } {
    if (v === null) return { ok: true, tags: null };
    if (!Array.isArray(v) || v.length > USER_TAGS_MAX) return { ok: false };
    const out: string[] = [];
    for (const x of v) {
        const t = cleanTag(x);
        if (t === null) return { ok: false };
        if (!out.includes(t)) out.push(t);
    }
    return { ok: true, tags: out };
}

export async function libraryAboutSet(d: AboutDeps, key: unknown, tags: unknown): Promise<StudioReply> {
    const parsed = parseUserTags(tags);
    if (typeof key !== "string" || key.length === 0 || key.length > MAX_POST_KEY_CHARS || !parsed.ok) return err(400, "error.library.bad_request");
    try {
        const leads = await postLeads(d.db, key);
        const post = leads.get(key);
        if (!post) return err(404, "error.library.not_found");
        const now = d.now();
        await d.db
            .prepare(
                `INSERT INTO media_about (post_key, item_id, probe_state, user_tags, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (post_key) DO UPDATE SET user_tags = excluded.user_tags, updated_at = excluded.updated_at`,
            )
            .bind(key, post.lead.id, probeable(post.lead.content_type) ? "pending" : "none", parsed.tags === null ? null : JSON.stringify(parsed.tags), now)
            .run();
    } catch (e) {
        console.error("[about] tags failed", String(e));
        return err(503, "error.api.generic");
    }
    return libraryAbout(d, key);
}

// ---- the word list: rows, vectors, averages (the 15-minute cron, 34.5) ----------------------------------------------

export type TermsResult = { added: number; embedded: number; refreshed: number; unavailable: boolean };

// Adds the starter words and every tag and sound tag a post has; embeds the terms without a vector (query mode, like a
// search, TERMS_PER_CALL per Space call) while the budget lasts; and refreshes every term's average cosine over the
// indexed posts when anything changed (the average of cosines is the cosine with the posts' mean vector).
export async function indexTerms(d: {
    db: D1Database;
    client: EmbedClient;
    now: () => number;
    budgetMs: number;
    // the indexer embedded posts this run: the averages move
    refreshMeans?: boolean;
}): Promise<TermsResult> {
    const start = d.now();
    const out: TermsResult = { added: 0, embedded: 0, refreshed: 0, unavailable: false };
    const have = new Set((await d.db.prepare("SELECT term FROM embed_terms").all<{ term: string }>()).results.map((r) => r.term));
    const { results: about } = await d.db.prepare("SELECT tags, user_tags, sound_tags FROM media_about").all<Pick<AboutRow, "tags" | "user_tags" | "sound_tags">>();
    const add: { term: string; source: string }[] = [];
    const seen = new Set<string>();
    const push = (term: string, source: string) => {
        if (have.has(term) || seen.has(term)) return;
        seen.add(term);
        add.push({ term, source });
    };
    for (const t of STARTER_TERMS) push(t, "starter");
    for (const r of about) for (const t of [...parseList(r.tags), ...parseList(r.user_tags), ...parseList(r.sound_tags)]) {
        const c = cleanTag(t);
        if (c) push(c, "tag");
    }
    const now = d.now();
    await runAll(
        d.db,
        add.map((a) => d.db.prepare("INSERT OR IGNORE INTO embed_terms (term, source, created_at) VALUES (?1, ?2, ?3)").bind(a.term, a.source, now)),
    );
    out.added = add.length;

    const { results: todo } = await d.db
        .prepare("SELECT term FROM embed_terms WHERE vector IS NULL OR model IS NOT ?1 OR dims IS NOT ?2 ORDER BY created_at, term")
        .bind(EMBED_MODEL, EMBED_DIMS)
        .all<{ term: string }>();
    const save = async (terms: string[], vectors: number[][], model: string) => {
        await runAll(
            d.db,
            terms.map((t, i) =>
                d.db.prepare("UPDATE embed_terms SET model = ?2, dims = ?3, vector = ?4, mean = NULL WHERE term = ?1").bind(t, model, EMBED_DIMS, encodeVector(vectors[i]!)),
            ),
        );
        out.embedded += terms.length;
    };
    for (let i = 0; i < todo.length; i += TERMS_PER_CALL) {
        const left = d.budgetMs - (d.now() - start);
        if (left < 2_000) break;
        const terms = todo.slice(i, i + TERMS_PER_CALL).map((r) => r.term);
        const input = (t: string) => ({ title: null, text: t, image_url: null });
        try {
            const r = await d.client.embed("query", terms.map(input), Math.min(EMBED_CALL_MS, left));
            await save(terms, r.vectors, r.model);
        } catch (e) {
            if (!(e instanceof EmbedError) || e.kind === "unavailable") {
                out.unavailable = true;
                break;
            }
            // one term spoiled the batch: each alone, and a word the Space refuses is dropped from the list
            for (const t of terms) {
                try {
                    const r = await d.client.embed("query", [input(t)], Math.min(EMBED_CALL_MS, Math.max(1_000, d.budgetMs - (d.now() - start))));
                    await save([t], r.vectors, r.model);
                } catch (e2) {
                    if (!(e2 instanceof EmbedError) || e2.kind === "unavailable") {
                        out.unavailable = true;
                        break;
                    }
                    await d.db.prepare("DELETE FROM embed_terms WHERE term = ?1").bind(t).run();
                }
            }
            if (out.unavailable) break;
        }
    }

    const stale = await d.db
        .prepare("SELECT COUNT(*) AS n FROM embed_terms WHERE vector IS NOT NULL AND mean IS NULL")
        .first<{ n: number }>();
    if (d.refreshMeans || out.embedded > 0 || (stale?.n ?? 0) > 0) out.refreshed = await refreshTermMeans(d.db);
    return out;
}

// Every embedded term's average cosine over the indexed posts. Returns how many terms were updated.
export async function refreshTermMeans(db: D1Database): Promise<number> {
    const { results } = await db
        .prepare("SELECT vector FROM media_embeddings WHERE model = ?1 AND dims = ?2 AND vector IS NOT NULL")
        .bind(EMBED_MODEL, EMBED_DIMS)
        .all<{ vector: string }>();
    const centroid = new Float64Array(EMBED_DIMS);
    let n = 0;
    for (const r of results) {
        const v = decodeVector(r.vector);
        if (!v || v.length !== EMBED_DIMS) continue;
        for (let i = 0; i < EMBED_DIMS; i++) centroid[i]! += v[i]!;
        n++;
    }
    if (n > 0) for (let i = 0; i < EMBED_DIMS; i++) centroid[i]! /= n;
    const terms = await termVectors(db);
    await runAll(
        db,
        terms.map((t) => db.prepare("UPDATE embed_terms SET mean = ?2 WHERE term = ?1").bind(t.term, n > 0 ? dot(t.v, centroid) : 0)),
    );
    return terms.length;
}
