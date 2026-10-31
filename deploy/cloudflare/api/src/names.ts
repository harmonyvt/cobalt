// Search names (APP-API-CONTRACT.md section 48): words the owner teaches library search ("Lia" = "pink-haired cat girl").
// A name is a word, its aliases, a meaning and example (`yes`) and not (`no`) posts. Its point (48.2) mixes into the query
// vector of a search that says it, and posts close to the point carry the name.
//
// - storage: list, create, update, delete, the preview and the names of one post (each answers a StudioReply, like
//   hidden.ts, so the routes return it as is and the chat unwraps it). Until migration 0031 every one answers 503.
// - applyNames(): the search hook (embed.ts searchPosts), one D1 read; a no-op before 0031 or with no name said.
// - refreshNames(): the 15-minute cron's step before the search indexer.
//
// Never use embed.ts's exports at the top level here: embed.ts imports this module too.
import { assemblePosts, libraryHide, type AppDeps } from "./app-routes";
import {
    decodeVector,
    dot,
    EMBED_DIMS,
    EMBED_MODEL,
    encodeVector,
    normalize,
    QUERY_CALL_MS,
    queryVector,
    queryWords,
    TEXT_MATCH_BONUS,
    type EmbedClient,
} from "./embed";
import { hiddenPostKeys } from "./hidden-store";
import { randomBase62 } from "./ids";
import { POST_KEY_SQL } from "./post-key";
import type { StudioReply } from "./studio";

export const NAMES_MAX = 100;
export const NAME_MARKS_MAX = 200;
export const NAME_ALIASES_MAX = 8;
export const NAME_WORD_MAX = 40;
export const NAME_MEANING_MAX = 300;
export const NAME_MARK_PATCH_MAX = 50;
export const NAME_POST_KEY_MAX = 2048;
export const NAME_NO_WEIGHT = 0.25;
export const NAME_DEFAULT_STRENGTH = 0.5;
export const NAME_DEFAULT_CUTOFF = 0.5;
export const NAMES_TEXT_MAX = 600;
export const NAMES_CRON_EMBED_MAX = 20;
export const NAME_PREVIEW_LIMIT = 60;
export const NAME_PREVIEW_MAX = 100;
export const NAME_ID_REGEX = /^[A-Za-z0-9]{16}$/;

export type MarkKind = "yes" | "no";

export type NameRow = {
    id: string;
    name: string;
    name_key: string;
    aliases: string;
    meaning: string;
    strength: number;
    cutoff: number;
    enabled: number;
    model: string | null;
    dims: number | null;
    vector: string | null;
    meaning_hash: string | null;
    point: string | null;
    created_at: number;
    updated_at: number;
};
type MarkRow = { name_id: string; post_key: string; kind: MarkKind; created_at: number };

export type NamesDeps = { db: D1Database; embed: EmbedClient | null; now: () => number; randomBytes?: (n: number) => Uint8Array };

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});
const bad = () => err(400, "error.names.bad");
const notFound = () => err(404, "error.names.not_found");
const generic = () => err(503, "error.api.generic");

// ---- is 0031 applied? (like hidden-store.ts for 0025) ----------------------------------------------------------------

const RECHECK_MS = 60_000;
const known = new WeakMap<object, { ok: boolean; at: number }>();

export async function namesReady(db: D1Database): Promise<boolean> {
    const k = known.get(db);
    if (k && (k.ok || Date.now() - k.at < RECHECK_MS)) return k.ok;
    try {
        const r = await db
            .prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name IN ('search_names', 'search_name_posts')")
            .first<{ n: number }>();
        const ok = Number(r?.n ?? 0) === 2;
        known.set(db, { ok, at: Date.now() });
        return ok;
    } catch {
        return false;
    }
}

async function guarded(db: D1Database, what: string, run: () => Promise<StudioReply>): Promise<StudioReply> {
    try {
        if (!(await namesReady(db))) return generic();
        return await run();
    } catch (e) {
        console.error(`[names] ${what} failed`, String(e));
        return generic();
    }
}

// ---- small helpers -------------------------------------------------------------------------------------------------------

// lower case, trimmed, inner whitespace one space
export const normalizeWord = (s: string): string => s.trim().replace(/\s+/g, " ").toLowerCase();

export async function meaningHash(meaning: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(meaning));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const parseAliases = (s: string): string[] => {
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};
const vec = (s: string | null): Float32Array | null => {
    const v = s ? decodeVector(s) : null;
    return v && v.length === EMBED_DIMS ? v : null;
};
const round4 = (x: number) => Math.round(x * 10000) / 10000;

async function writeAll(db: D1Database, stmts: D1PreparedStatement[]): Promise<void> {
    if (stmts.length === 0) return;
    if (typeof (db as { batch?: unknown }).batch === "function") await db.batch(stmts);
    else for (const s of stmts) await s.run();
}

// The meaning's vector (query mode), cached by exact text for the isolate's life, so a preview slider costs no Space
// call. null when the Space cannot answer.

export async function meaningVector(client: EmbedClient | null, text: string): Promise<number[] | null> {
    if (!client) return null;
    try {
        // the search's remembered query vectors (exact text), so dragging a slider costs no Space call
        const v = await queryVector(client, text);
        return v.length === EMBED_DIMS ? v : null;
    } catch {
        return null;
    }
}

// The meaning's stored vector when it is for this model and this meaning.
async function storedMeaning(row: NameRow): Promise<Float32Array | null> {
    if (row.model !== EMBED_MODEL || row.dims !== EMBED_DIMS || !row.meaning_hash) return null;
    if (row.meaning_hash !== (await meaningHash(row.meaning))) return null;
    return vec(row.vector);
}

// ---- the point (48.2) ------------------------------------------------------------------------------------------------

function average(vs: ArrayLike<number>[]): number[] | null {
    if (vs.length === 0) return null;
    const out = new Array<number>(EMBED_DIMS).fill(0);
    for (const v of vs) for (let i = 0; i < EMBED_DIMS; i++) out[i]! += v[i] ?? 0;
    return normalize(out);
}

// m: the meaning's vector; yes/no: the marked posts' vectors (indexed ones only).
export function namePoint(m: ArrayLike<number> | null, yes: ArrayLike<number>[], no: ArrayLike<number>[], strength: number): number[] | null {
    const y = average(yes);
    let c: number[] | null = null;
    if (y) {
        const n = average(no);
        c = n ? normalize(y.map((x, i) => x - NAME_NO_WEIGHT * n[i]!)) : y;
    }
    const mv = m ? Array.from(m) : null;
    if (mv && c) return normalize(mv.map((x, i) => (1 - strength) * x + strength * c![i]!));
    return mv ? normalize(mv) : c;
}

// Whether a post carries a name: marked yes, or not marked no, has a vector and is close enough to the point.
export function carries(mark: MarkKind | null, v: ArrayLike<number> | null, point: ArrayLike<number> | null, cutoff: number): boolean {
    if (mark === "yes") return true;
    if (mark === "no" || !v || !point) return false;
    return dot(v, point) >= cutoff;
}

// The vectors of these posts (current model), in one read.
async function vectorsOf(db: D1Database, keys: string[]): Promise<Map<string, Float32Array>> {
    const out = new Map<string, Float32Array>();
    const list = [...new Set(keys)];
    if (list.length === 0) return out;
    const { results } = await db
        .prepare("SELECT post_key, vector FROM media_embeddings WHERE model = ?1 AND dims = ?2 AND vector IS NOT NULL AND post_key IN (SELECT value FROM json_each(?3))")
        .bind(EMBED_MODEL, EMBED_DIMS, JSON.stringify(list))
        .all<{ post_key: string; vector: string }>();
    for (const r of results) {
        const v = vec(r.vector);
        if (v) out.set(r.post_key, v);
    }
    return out;
}

const pointOf = (m: ArrayLike<number> | null, marks: { post_key: string; kind: MarkKind }[], vs: Map<string, Float32Array>, strength: number) =>
    namePoint(
        m,
        marks.flatMap((k) => (k.kind === "yes" && vs.has(k.post_key) ? [vs.get(k.post_key)!] : [])),
        marks.flatMap((k) => (k.kind === "no" && vs.has(k.post_key) ? [vs.get(k.post_key)!] : [])),
        strength,
    );

// Every live post that is not hidden, with its vector when indexed, newest first.
type Universe = { keys: { post_key: string; latest: number }[]; vectors: Map<string, Float32Array> };
async function universe(db: D1Database): Promise<Universe> {
    const { results: live } = await db
        .prepare(
            `SELECT post_key, MAX(created_at) AS latest FROM (SELECT ${POST_KEY_SQL} AS post_key, m.created_at FROM media_items m WHERE m.deleted_at IS NULL)
              GROUP BY post_key ORDER BY latest DESC`,
        )
        .all<{ post_key: string; latest: number }>();
    const hidden = await hiddenPostKeys(db);
    const keys = live.filter((k) => !hidden.has(k.post_key));
    const { results: rows } = await db
        .prepare("SELECT post_key, vector FROM media_embeddings WHERE model = ?1 AND dims = ?2 AND vector IS NOT NULL")
        .bind(EMBED_MODEL, EMBED_DIMS)
        .all<{ post_key: string; vector: string }>();
    const vectors = new Map<string, Float32Array>();
    const ok = new Set(keys.map((k) => k.post_key));
    for (const r of rows) {
        const v = ok.has(r.post_key) ? vec(r.vector) : null;
        if (v) vectors.set(r.post_key, v);
    }
    return { keys, vectors };
}

const countCarried = (u: Universe, marks: Map<string, MarkKind>, point: ArrayLike<number> | null, cutoff: number): number =>
    u.keys.filter((k) => carries(marks.get(k.post_key) ?? null, u.vectors.get(k.post_key) ?? null, point, cutoff)).length;

// ---- reading -----------------------------------------------------------------------------------------------------------

async function marksOf(db: D1Database, ids?: string[]): Promise<Map<string, MarkRow[]>> {
    const stmt = ids
        ? db.prepare("SELECT * FROM search_name_posts WHERE name_id IN (SELECT value FROM json_each(?1)) ORDER BY created_at DESC, post_key").bind(JSON.stringify(ids))
        : db.prepare("SELECT * FROM search_name_posts ORDER BY created_at DESC, post_key");
    const out = new Map<string, MarkRow[]>();
    for (const r of (await stmt.all<MarkRow>()).results) {
        const l = out.get(r.name_id);
        if (l) l.push(r);
        else out.set(r.name_id, [r]);
    }
    return out;
}

export type NameShape = {
    id: string;
    name: string;
    aliases: string[];
    meaning: string;
    strength: number;
    cutoff: number;
    enabled: boolean;
    yes: string[];
    no: string[];
    posts: number;
    embedded: boolean;
    created_at: number;
    updated_at: number;
};

async function shapeOf(row: NameRow, marks: MarkRow[], u: Universe): Promise<NameShape> {
    const kinds = new Map(marks.map((m) => [m.post_key, m.kind]));
    return {
        id: row.id,
        name: row.name,
        aliases: parseAliases(row.aliases),
        meaning: row.meaning,
        strength: row.strength,
        cutoff: row.cutoff,
        enabled: !!row.enabled,
        yes: marks.filter((m) => m.kind === "yes").map((m) => m.post_key),
        no: marks.filter((m) => m.kind === "no").map((m) => m.post_key),
        posts: countCarried(u, kinds, vec(row.point), row.cutoff),
        embedded: (await storedMeaning(row)) !== null,
        created_at: row.created_at,
        updated_at: row.updated_at,
    };
}

// GET /library/names: oldest first.
export function listNames(d: Pick<NamesDeps, "db">): Promise<StudioReply> {
    return guarded(d.db, "list", async () => {
        const { results } = await d.db.prepare("SELECT * FROM search_names ORDER BY created_at, id").all<NameRow>();
        const marks = await marksOf(d.db);
        const u = await universe(d.db);
        const names = await Promise.all(results.map((r) => shapeOf(r, marks.get(r.id) ?? [], u)));
        return { status: 200, body: { status: "success", names } };
    });
}

// ---- writing -----------------------------------------------------------------------------------------------------------

export type NameInput = {
    name?: string;
    meaning?: string;
    aliases?: string[];
    strength?: number;
    cutoff?: number;
    enabled?: boolean;
    yes?: string[];
    no?: string[];
    mark?: { post_key: string; kind: MarkKind | null }[];
};

const unit = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= 1;
const postKeyOk = (k: unknown): k is string => typeof k === "string" && k.length >= 1 && k.length <= NAME_POST_KEY_MAX;
const keyList = (l: unknown): l is string[] => Array.isArray(l) && l.length <= NAME_MARKS_MAX && l.every(postKeyOk);

// The name's text fields checked and normalized; null when they do not fit 48.1.
function cleanText(input: NameInput, base: { name: string; meaning: string; aliases: string[] } | null) {
    const name = input.name !== undefined ? (typeof input.name === "string" ? input.name.trim().replace(/\s+/g, " ") : null) : (base?.name ?? null);
    if (!name || [...name].length > NAME_WORD_MAX) return null;
    const meaning = input.meaning !== undefined ? (typeof input.meaning === "string" ? input.meaning.trim() : null) : (base?.meaning ?? null);
    if (!meaning || [...meaning].length > NAME_MEANING_MAX) return null;
    const key = normalizeWord(name);
    const raw = input.aliases !== undefined ? input.aliases : (base?.aliases ?? []);
    if (!Array.isArray(raw) || raw.length > NAME_ALIASES_MAX) return null;
    const aliases: string[] = [];
    for (const a of raw) {
        if (typeof a !== "string") return null;
        const w = normalizeWord(a);
        if (w.length === 0 || [...w].length > NAME_WORD_MAX) return null;
        if (w !== key && !aliases.includes(w)) aliases.push(w);
    }
    return { name, meaning, key, aliases };
}

// The marks after the input: yes/no lists replace them, then `mark` changes single posts. null: does not fit.
function nextMarks(input: NameInput, before: { post_key: string; kind: MarkKind; created_at: number }[], now: number) {
    if (input.yes !== undefined && !keyList(input.yes)) return null;
    if (input.no !== undefined && !keyList(input.no)) return null;
    if (input.mark !== undefined) {
        if (!Array.isArray(input.mark) || input.mark.length > NAME_MARK_PATCH_MAX) return null;
        if (!input.mark.every((m) => m && postKeyOk(m.post_key) && (m.kind === "yes" || m.kind === "no" || m.kind === null))) return null;
    }
    const yes = input.yes ? [...new Set(input.yes)] : null;
    const no = input.no ? [...new Set(input.no)] : null;
    if (yes && no && yes.some((k) => no.includes(k))) return null;
    const out = new Map(before.map((m) => [m.post_key, m]));
    const keep = (k: string, kind: MarkKind) => {
        const was = out.get(k);
        out.set(k, was && was.kind === kind ? was : { post_key: k, kind, created_at: now });
    };
    if (yes) {
        for (const [k, m] of out) if (m.kind === "yes" && !yes.includes(k)) out.delete(k);
        for (const k of yes) keep(k, "yes");
    }
    if (no) {
        for (const [k, m] of out) if (m.kind === "no" && !no.includes(k)) out.delete(k);
        for (const k of no) {
            if (yes?.includes(k)) return null;
            keep(k, "no");
        }
    }
    for (const m of input.mark ?? []) {
        if (m.kind === null) out.delete(m.post_key);
        else keep(m.post_key, m.kind);
    }
    if (out.size > NAME_MARKS_MAX) return null;
    return [...out.values()].sort((a, b) => b.created_at - a.created_at || (a.post_key < b.post_key ? -1 : 1));
}

// The first word of `words` another name already uses.
async function clash(db: D1Database, words: string[], selfId: string | null): Promise<string | null> {
    const { results } = await db.prepare("SELECT id, name_key, aliases FROM search_names").all<{ id: string; name_key: string; aliases: string }>();
    const taken = new Set<string>();
    for (const r of results) {
        if (r.id === selfId) continue;
        taken.add(r.name_key);
        for (const a of parseAliases(r.aliases)) taken.add(a);
    }
    return words.find((w) => taken.has(w)) ?? null;
}

async function loadName(db: D1Database, id: string): Promise<NameRow | null> {
    if (!NAME_ID_REGEX.test(id)) return null;
    return (await db.prepare("SELECT * FROM search_names WHERE id = ?1").bind(id).first<NameRow>()) ?? null;
}

async function answerOne(db: D1Database, id: string, status = 200): Promise<StudioReply> {
    const row = (await loadName(db, id))!;
    const marks = (await marksOf(db, [id])).get(id) ?? [];
    return { status, body: { status: "success", name: await shapeOf(row, marks, await universe(db)) } };
}

// POST /library/names (no id) and PATCH /library/names/<id>.
export function saveName(d: NamesDeps, id: string | null, input: NameInput): Promise<StudioReply> {
    return guarded(d.db, id ? "update" : "create", async () => {
        const now = d.now();
        const row = id ? await loadName(d.db, id) : null;
        if (id && !row) return notFound();
        if (!id && (input.name === undefined || input.meaning === undefined)) return bad();
        if (!id && input.mark !== undefined) return bad();
        const text = cleanText(input, row ? { name: row.name, meaning: row.meaning, aliases: parseAliases(row.aliases) } : null);
        if (!text) return bad();
        if (input.strength !== undefined && !unit(input.strength)) return bad();
        if (input.cutoff !== undefined && !unit(input.cutoff)) return bad();
        if (input.enabled !== undefined && typeof input.enabled !== "boolean") return bad();
        const before = row ? ((await marksOf(d.db, [row.id])).get(row.id) ?? []) : [];
        const marks = nextMarks(input, before, now);
        if (!marks) return bad();
        if (!row) {
            const n = await d.db.prepare("SELECT COUNT(*) AS n FROM search_names").first<{ n: number }>();
            if (Number(n?.n ?? 0) >= NAMES_MAX) return err(409, "error.names.too_many");
        }
        const taken = await clash(d.db, [text.key, ...text.aliases], row?.id ?? null);
        if (taken) return err(409, "error.names.taken", { word: taken });

        const strength = input.strength ?? row?.strength ?? NAME_DEFAULT_STRENGTH;
        const cutoff = input.cutoff ?? row?.cutoff ?? NAME_DEFAULT_CUTOFF;
        const enabled = input.enabled ?? (row ? !!row.enabled : true);
        // the meaning: kept when it is current, else embedded now (one Space call); NULL when the Space cannot answer
        let m: ArrayLike<number> | null = row && row.meaning === text.meaning ? await storedMeaning(row) : null;
        if (!m) m = await meaningVector(d.embed, text.meaning);
        const point = pointOf(m, marks, await vectorsOf(d.db, marks.map((k) => k.post_key)), strength);
        const nameId = row?.id ?? randomBase62(16, d.randomBytes);
        const cols = [
            text.name,
            text.key,
            JSON.stringify(text.aliases),
            text.meaning,
            strength,
            cutoff,
            enabled ? 1 : 0,
            m ? EMBED_MODEL : null,
            m ? EMBED_DIMS : null,
            m ? encodeVector(Array.from(m)) : null,
            m ? await meaningHash(text.meaning) : null,
            point ? encodeVector(point) : null,
        ];
        const stmts: D1PreparedStatement[] = [
            row
                ? d.db
                      .prepare(
                          `UPDATE search_names SET name = ?2, name_key = ?3, aliases = ?4, meaning = ?5, strength = ?6, cutoff = ?7, enabled = ?8,
                                  model = ?9, dims = ?10, vector = ?11, meaning_hash = ?12, point = ?13, updated_at = ?14 WHERE id = ?1`,
                      )
                      .bind(nameId, ...cols, now)
                : d.db
                      .prepare(
                          `INSERT INTO search_names (id, name, name_key, aliases, meaning, strength, cutoff, enabled, model, dims, vector, meaning_hash, point, created_at, updated_at)
                           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14)`,
                      )
                      .bind(nameId, ...cols, now),
        ];
        const changed = marks.length !== before.length || marks.some((k) => !before.some((b) => b.post_key === k.post_key && b.kind === k.kind));
        if (row && changed) stmts.push(d.db.prepare("DELETE FROM search_name_posts WHERE name_id = ?1").bind(nameId));
        if (!row || changed) {
            for (const k of marks) {
                stmts.push(
                    d.db.prepare("INSERT INTO search_name_posts (name_id, post_key, kind, created_at) VALUES (?1, ?2, ?3, ?4)").bind(nameId, k.post_key, k.kind, k.created_at),
                );
            }
        }
        await writeAll(d.db, stmts);
        return answerOne(d.db, nameId, row ? 200 : 201);
    });
}

// DELETE /library/names/<id>: the name and its marks.
export function deleteName(d: Pick<NamesDeps, "db">, id: string): Promise<StudioReply> {
    return guarded(d.db, "delete", async () => {
        if (!(await loadName(d.db, id))) return notFound();
        await writeAll(d.db, [
            d.db.prepare("DELETE FROM search_name_posts WHERE name_id = ?1").bind(id),
            d.db.prepare("DELETE FROM search_names WHERE id = ?1").bind(id),
        ]);
        return { status: 200, body: { status: "success" } };
    });
}

// ---- POST /library/names/preview --------------------------------------------------------------------------------------

export type PreviewInput = {
    id?: string;
    name?: string;
    meaning?: string;
    strength?: number;
    cutoff?: number;
    yes?: string[];
    no?: string[];
    limit?: number;
};
export type PreviewPost = { post_key: string; score: number; mark: MarkKind | null; carries: boolean };

// The name as it would be with these values, saving nothing. `posts` has no `post` here: the route adds it.
export function previewName(d: NamesDeps, input: PreviewInput, defaultLimit = NAME_PREVIEW_LIMIT): Promise<StudioReply> {
    return guarded(d.db, "preview", async () => {
        const limit = input.limit ?? defaultLimit;
        if (!Number.isInteger(limit) || limit < 1 || limit > NAME_PREVIEW_MAX) return bad();
        let row: NameRow | null = null;
        if (input.id !== undefined) {
            row = typeof input.id === "string" ? await loadName(d.db, input.id) : null;
            if (!row) return notFound();
        }
        if (!row && input.meaning === undefined) return bad();
        const text = cleanText({ name: input.name ?? row?.name ?? "name", meaning: input.meaning }, row ? { name: row.name, meaning: row.meaning, aliases: [] } : null);
        if (!text) return bad();
        if (input.strength !== undefined && !unit(input.strength)) return bad();
        if (input.cutoff !== undefined && !unit(input.cutoff)) return bad();
        const before = row ? ((await marksOf(d.db, [row.id])).get(row.id) ?? []) : [];
        const marks = nextMarks({ yes: input.yes, no: input.no }, before, d.now());
        if (!marks) return bad();
        const strength = input.strength ?? row?.strength ?? NAME_DEFAULT_STRENGTH;
        const cutoff = input.cutoff ?? row?.cutoff ?? NAME_DEFAULT_CUTOFF;
        let m: ArrayLike<number> | null = row && row.meaning === text.meaning ? await storedMeaning(row) : null;
        if (!m) m = await meaningVector(d.embed, text.meaning);
        const u = await universe(d.db);
        const point = pointOf(m, marks, await vectorsOf(d.db, marks.map((k) => k.post_key)), strength);
        const kinds = new Map(marks.map((k) => [k.post_key, k.kind]));
        const order = new Map(marks.map((k, i) => [k.post_key, i]));
        const posts: PreviewPost[] = [];
        let carried = 0;
        for (const k of u.keys) {
            const v = u.vectors.get(k.post_key) ?? null;
            const mark = kinds.get(k.post_key) ?? null;
            const c = carries(mark, v, point, cutoff);
            if (c) carried++;
            if (!v && !mark) continue;
            const score = v && point ? round4(dot(v, point)) : mark === "yes" ? 1 : 0;
            posts.push({ post_key: k.post_key, score, mark, carries: c });
        }
        const rank = (p: PreviewPost) => (p.mark === "yes" ? 0 : p.mark === "no" ? 1 : 2);
        posts.sort(
            (a, b) =>
                rank(a) - rank(b) ||
                (a.mark ? order.get(a.post_key)! - order.get(b.post_key)! : b.score - a.score) ||
                (a.post_key < b.post_key ? -1 : 1),
        );
        return {
            status: 200,
            body: { status: "success", embedded: m !== null, carries: carried, indexed: u.vectors.size, posts: posts.slice(0, limit) },
        };
    });
}

// The route's preview: each entry also gets its post in the GET /library?v=3 shape (null when it is gone).
export async function previewWithPosts(d: NamesDeps & { app: AppDeps }, input: PreviewInput): Promise<StudioReply> {
    const r = await previewName(d, input);
    if (r.status !== 200) return r;
    const body = r.body as { posts: PreviewPost[] };
    const keys = body.posts.map((p) => p.post_key);
    const latest = new Map<string, number>();
    if (keys.length > 0) {
        const { results } = await d.db
            .prepare(
                `SELECT post_key, MAX(created_at) AS latest FROM (SELECT ${POST_KEY_SQL} AS post_key, m.created_at FROM media_items m WHERE m.deleted_at IS NULL)
                  WHERE post_key IN (SELECT value FROM json_each(?1)) GROUP BY post_key`,
            )
            .bind(JSON.stringify(keys))
            .all<{ post_key: string; latest: number }>();
        for (const x of results) latest.set(x.post_key, x.latest);
    }
    const page = keys.filter((k) => latest.has(k)).map((k) => ({ post_key: k, latest: latest.get(k)! }));
    const { posts } = await assemblePosts(d.app, page, { v2: true, v3: true, hide: libraryHide(true, true), now: d.now() });
    const byId = new Map(posts.map((p: { id: string }) => [p.id, p]));
    return { status: 200, body: { ...body, posts: body.posts.map((p) => ({ ...p, post: byId.get(p.post_key) ?? null })) } };
}

// ---- GET /library/names/post?key= -------------------------------------------------------------------------------------

export function namesForPost(d: Pick<NamesDeps, "db">, key: unknown): Promise<StudioReply> {
    return guarded(d.db, "post", async () => {
        if (!postKeyOk(key)) return bad();
        const { results } = await d.db.prepare("SELECT * FROM search_names WHERE enabled = 1 ORDER BY created_at, id").all<NameRow>();
        const { results: marks } = await d.db.prepare("SELECT name_id, kind FROM search_name_posts WHERE post_key = ?1").bind(key).all<{ name_id: string; kind: MarkKind }>();
        const kinds = new Map(marks.map((m) => [m.name_id, m.kind]));
        const hidden = (await hiddenPostKeys(d.db)).has(key);
        const v = (await vectorsOf(d.db, [key])).get(key) ?? null;
        const names = results.flatMap((r) => {
            const point = vec(r.point);
            const mark = kinds.get(r.id) ?? null;
            const c = !hidden && carries(mark, v, point, r.cutoff);
            if (!c && !mark) return [];
            return [{ id: r.id, name: r.name, score: v && point ? round4(dot(v, point)) : null, mark, carries: c }];
        });
        names.sort((a, b) => Number(b.carries) - Number(a.carries) || (b.score ?? -Infinity) - (a.score ?? -Infinity));
        return { status: 200, body: { status: "success", names } };
    });
}

// ---- search (48.3) -----------------------------------------------------------------------------------------------------

export type NamesApplied = {
    // what the Space embeds: the query, then the said names' meanings
    text: string;
    // the names the query says (enabled ones), in the order found
    said: { id: string; name: string }[];
    // the query vector with the said names' points mixed in
    mix(qv: number[]): number[];
    // the extra text-match bonus of a post that carries a said name (0 otherwise)
    bonus(postKey: string, v: ArrayLike<number> | null): number;
    // the name-match fallback: whether the post holds this query word through a said name it carries
    holds(postKey: string, v: ArrayLike<number> | null, word: string): boolean;
    // the said names this post carries (after bonus or holds saw it)
    carried(postKey: string): string[];
};

export const NO_NAMES: NamesApplied = {
    text: "",
    said: [],
    mix: (qv) => qv,
    bonus: () => 0,
    holds: () => false,
    carried: () => [],
};

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

type Said = { id: string; name: string; meaning: string; cutoff: number; point: Float32Array | null; marks: Map<string, MarkKind>; words: Set<string> };

// The names a query says: whole words, longest first, one span of the query for one name.
export function saidNames<T extends { id: string; name_key: string; aliases: string }>(query: string, names: T[]): { row: T; word: string }[] {
    const q = normalizeWord(query);
    const words = names.flatMap((r) => [r.name_key, ...parseAliases(r.aliases)].map((w) => ({ w, r }))).sort((a, b) => b.w.length - a.w.length);
    const used: [number, number][] = [];
    const out: { row: T; word: string; at: number }[] = [];
    for (const { w, r } of words) {
        if (!w || out.some((o) => o.row.id === r.id)) continue;
        const re = new RegExp(`(?<![\\p{L}\\p{N}])${escapeRe(w)}(?![\\p{L}\\p{N}])`, "gu");
        for (const m of q.matchAll(re)) {
            const s = m.index!;
            const e = s + m[0].length;
            if (used.some(([a, b]) => s < b && a < e)) continue;
            used.push([s, e]);
            out.push({ row: r, word: w, at: s });
            break;
        }
    }
    return out.sort((a, b) => a.at - b.at).map(({ row, word }) => ({ row, word }));
}

// The search hook: one D1 read. `query` is the trimmed query as typed. A no-op before 0031, with names off, or when
// the query says no name.
export async function applyNames(db: D1Database, query: string, on = true): Promise<NamesApplied> {
    const none = { ...NO_NAMES, text: query };
    if (!on) return none;
    try {
        if (!(await namesReady(db))) return none;
        const { results } = await db
            .prepare(
                `SELECT n.id, n.name, n.name_key, n.aliases, n.meaning, n.cutoff, n.point,
                        (SELECT json_group_array(json_array(p.post_key, p.kind)) FROM search_name_posts p WHERE p.name_id = n.id) AS marks
                   FROM search_names n WHERE n.enabled = 1`,
            )
            .all<Pick<NameRow, "id" | "name" | "name_key" | "aliases" | "meaning" | "cutoff" | "point"> & { marks: string | null }>();
        const found = saidNames(query, results);
        if (found.length === 0) return none;
        const qWords = queryWords(normalizeWord(query));
        const said: Said[] = found.map(({ row, word }) => {
            let marks: [string, MarkKind][] = [];
            try {
                marks = JSON.parse(row.marks ?? "[]");
            } catch {
                // no marks
            }
            return { id: row.id, name: row.name, meaning: row.meaning, cutoff: row.cutoff, point: vec(row.point), marks: new Map(marks), words: new Set(queryWords(word)) };
        });
        const memo = new Map<string, Said[]>();
        const carriedBy = (k: string, v: ArrayLike<number> | null): Said[] => {
            let c = memo.get(k);
            if (!c) memo.set(k, (c = said.filter((s) => carries(s.marks.get(k) ?? null, v, s.point, s.cutoff))));
            return c;
        };
        const text = `${query} (${said.map((s) => `${s.name}: ${s.meaning}`).join("; ")})`.slice(0, NAMES_TEXT_MAX);
        return {
            text,
            said: said.map((s) => ({ id: s.id, name: s.name })),
            mix(qv) {
                const out = [...qv];
                for (const s of said) if (s.point) for (let i = 0; i < out.length; i++) out[i]! += s.point[i] ?? 0;
                return normalize(out);
            },
            bonus(k, v) {
                const c = carriedBy(k, v);
                if (c.length === 0 || qWords.length === 0) return 0;
                const share = qWords.filter((w) => c.some((s) => s.words.has(w))).length / qWords.length;
                return TEXT_MATCH_BONUS * share;
            },
            holds: (k, v, w) => carriedBy(k, v).some((s) => s.words.has(w)),
            carried: (k) => (memo.get(k) ?? []).map((s) => s.name),
        };
    } catch (e) {
        console.error("[names] search hook failed", String(e));
        return none;
    }
}

// ---- the cron (48.2) ---------------------------------------------------------------------------------------------------

export type NamesRefresh = { embedded: number; points: number; unavailable: boolean };

// Meanings without a current vector get one (one batch call, at most NAMES_CRON_EMBED_MAX), then every enabled name's
// point is rewritten (its marked posts may have been indexed since).
export async function refreshNames(d: { db: D1Database; client: EmbedClient | null; now: () => number }): Promise<NamesRefresh> {
    const out: NamesRefresh = { embedded: 0, points: 0, unavailable: false };
    if (!(await namesReady(d.db))) return out;
    const { results: rows } = await d.db.prepare("SELECT * FROM search_names ORDER BY created_at, id").all<NameRow>();
    if (rows.length === 0) return out;
    const meanings = new Map<string, ArrayLike<number>>();
    const stale: NameRow[] = [];
    for (const r of rows) {
        const m = await storedMeaning(r);
        if (m) meanings.set(r.id, m);
        else stale.push(r);
    }
    const stmts: D1PreparedStatement[] = [];
    const todo = stale.slice(0, NAMES_CRON_EMBED_MAX);
    if (todo.length > 0 && d.client) {
        try {
            const r = await d.client.embed("query", todo.map((x) => ({ title: null, text: x.meaning, image_url: null })), QUERY_CALL_MS);
            for (let i = 0; i < todo.length; i++) {
                const v = r.vectors[i];
                if (!v || v.length !== EMBED_DIMS) continue;
                const row = todo[i]!;
                meanings.set(row.id, v);
                row.model = EMBED_MODEL;
                row.dims = EMBED_DIMS;
                row.vector = encodeVector(v);
                row.meaning_hash = await meaningHash(row.meaning);
                stmts.push(
                    d.db
                        .prepare("UPDATE search_names SET model = ?2, dims = ?3, vector = ?4, meaning_hash = ?5 WHERE id = ?1")
                        .bind(row.id, row.model, row.dims, row.vector, row.meaning_hash),
                );
                out.embedded++;
            }
        } catch {
            out.unavailable = true;
        }
    }
    const enabled = rows.filter((r) => r.enabled);
    const marks = await marksOf(d.db, enabled.map((r) => r.id));
    const vs = await vectorsOf(d.db, [...marks.values()].flat().map((m) => m.post_key));
    for (const r of enabled) {
        const p = pointOf(meanings.get(r.id) ?? null, marks.get(r.id) ?? [], vs, r.strength);
        const enc = p ? encodeVector(p) : null;
        if (enc === r.point) continue;
        stmts.push(d.db.prepare("UPDATE search_names SET point = ?2 WHERE id = ?1").bind(r.id, enc));
        out.points++;
    }
    await writeAll(d.db, stmts);
    return out;
}
