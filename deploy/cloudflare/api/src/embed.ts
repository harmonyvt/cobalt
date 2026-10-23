// Library search (APP-API-CONTRACT.md section 21): one EmbeddingGemma 2 vector per library post,
// made by the private Hugging Face Space in deploy/huggingface/embed, stored in D1
// `media_embeddings` (migration 0010) and searched here by brute force (a personal library is a few
// thousand posts at most: 1 KB per vector).
//
// - runIndexer(): one pass. It reads every live post's inputs (title text and poster), embeds the
//   posts whose inputs changed, a batch per pass, and deletes the rows of posts that are gone. A
//   Space that is asleep or down ends the pass without counting against any post.
// - drainIndexer(): the cron's run (every 15 minutes, index.ts): passes until nothing is pending,
//   the Space is unavailable or SEARCH_RUN_BUDGET_MS is up, recorded in `search_index_runs`.
// - searchQueue(): the search part of GET /queue (app-routes.ts queueSnapshot).
// - searchPosts(): GET /library/search. Embeds the query, scores every vector, and adds a bonus
//   for a plain text match, so a post found by its name ranks first even before it is embedded.

import { assemblePosts, libraryHide, POST_KEY_SQL, type AppDeps } from "./app-routes";
import type { StudioReply } from "./studio";

export const EMBED_MODEL = "google/embeddinggemma-2";
export const EMBED_DIMS = 256;
// Posts embedded per cron pass (the free Space runs on 2 CPUs, about a second or two each).
export const EMBED_BATCH = 8;
// A post the Space refused is tried again this long after, and given up on after
// EMBED_MAX_ATTEMPTS refusals until its inputs change.
export const EMBED_RETRY_MS = 60 * 60 * 1000;
export const EMBED_MAX_ATTEMPTS = 3;
// Wall-clock caps on one call to the Space: a document batch (a cold Space may be loading the
// model) and a search query (someone is waiting).
export const EMBED_CALL_MS = 90_000;
export const QUERY_CALL_MS = 25_000;
// Ranking: a query found as plain text in the post's title or text adds this to its score.
export const TEXT_MATCH_BONUS = 0.3;
export const MAX_QUERY_CHARS = 200;
export const DEFAULT_SEARCH_LIMIT = 20;
export const MAX_SEARCH_LIMIT = 50;

export type EmbedInput = { title: string | null; text: string; image_url: string | null };
export type EmbedResult = { model: string; vectors: number[][]; images: boolean[] };

// "unavailable": the Space is asleep, booting, down or slow (nothing is held against the posts).
// "rejected": it answered 4xx to this input.
export class EmbedError extends Error {
    constructor(
        readonly kind: "unavailable" | "rejected",
        readonly status: number | null,
    ) {
        super(`embed ${kind}${status === null ? "" : ` ${status}`}`);
        this.name = "EmbedError";
    }
}

export type EmbedClient = {
    embed(kind: "document" | "query", inputs: EmbedInput[], timeoutMs: number): Promise<EmbedResult>;
    // GET / on the Space. A sleeping Space answers a POST at once without waking up; a GET wakes it (it
    // answers once booted, about 20 s). True when it answered its health JSON. Absent on test fakes.
    wake?(timeoutMs: number): Promise<boolean>;
};

export type EmbedConfig = { url?: string; token?: string; key?: string };

// The Space is configured when its URL is https and the Hugging Face token is set.
export const embedConfigured = (c: EmbedConfig): boolean =>
    typeof c.url === "string" && /^https:\/\/[^/\s]+/.test(c.url) && typeof c.token === "string" && c.token.length > 0;

// Below this much time left, a failed call is not worth a wake and a second try.
const WAKE_MIN_MS = 1_000;

// Runs `run` with an abort signal, rejecting with EmbedError("unavailable") after `timeoutMs` (our own
// timer: an AbortSignal timeout is not always honoured in the Workers runtime).
async function withDeadline<T>(timeoutMs: number, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const ctrl = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
            ctrl.abort();
            reject(new EmbedError("unavailable", null));
        }, timeoutMs);
    });
    try {
        return await Promise.race([run(ctrl.signal), timeout]);
    } finally {
        clearTimeout(timer);
    }
}

// The HTTP client for the Space (README there has the contract). `fetchFn` is injectable for tests.
// A call the Space could not answer (asleep, booting, 5xx) wakes it with a GET and tries once more,
// inside the same `timeoutMs`.
export function spaceClient(c: EmbedConfig, fetchFn: typeof fetch = fetch): EmbedClient | null {
    if (!embedConfigured(c)) return null;
    const base = c.url!.replace(/\/+$/, "");
    const endpoint = `${base}/embed`;
    const auth = `Bearer ${c.token}`;

    const post = (kind: "document" | "query", inputs: EmbedInput[], timeoutMs: number): Promise<EmbedResult> =>
        withDeadline(timeoutMs, async (signal) => {
            const headers: Record<string, string> = { "content-type": "application/json", authorization: auth };
            if (c.key) headers["x-embed-key"] = c.key;
            let res: Response;
            try {
                res = await fetchFn(endpoint, {
                    method: "POST",
                    headers,
                    body: JSON.stringify({ kind, dims: EMBED_DIMS, inputs }),
                    signal,
                });
            } catch {
                throw new EmbedError("unavailable", null);
            }
            if (res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429) {
                // 401/403/404 from the Hugging Face proxy is a configuration problem, not this
                // input's fault: never held against a post.
                if (res.status === 401 || res.status === 403 || res.status === 404) {
                    throw new EmbedError("unavailable", res.status);
                }
                throw new EmbedError("rejected", res.status);
            }
            if (!res.ok) throw new EmbedError("unavailable", res.status);
            let body: unknown;
            try {
                body = await res.json();
            } catch {
                // a booting Space answers with its HTML page
                throw new EmbedError("unavailable", res.status);
            }
            const parsed = parseResult(body, inputs.length);
            if (!parsed) throw new EmbedError("unavailable", res.status);
            return parsed;
        });

    const wake = async (timeoutMs: number): Promise<boolean> => {
        try {
            return await withDeadline(timeoutMs, async (signal) => {
                const res = await fetchFn(`${base}/`, { method: "GET", headers: { authorization: auth }, signal });
                if (!res.ok) return false;
                const body = (await res.json().catch(() => null)) as { status?: unknown } | null;
                return body?.status === "ok";
            });
        } catch {
            return false;
        }
    };

    return {
        wake,
        async embed(kind, inputs, timeoutMs) {
            const deadline = Date.now() + timeoutMs;
            try {
                return await post(kind, inputs, timeoutMs);
            } catch (e) {
                const left = () => deadline - Date.now();
                const configProblem = e instanceof EmbedError && (e.status === 401 || e.status === 403 || e.status === 404);
                if (!(e instanceof EmbedError) || e.kind !== "unavailable" || configProblem || left() < WAKE_MIN_MS) {
                    if (e instanceof EmbedError && e.kind === "unavailable") console.log("[search] space unavailable", e.status);
                    throw e;
                }
                const awake = await wake(left());
                if (!awake || left() < WAKE_MIN_MS) {
                    console.log("[search] space unavailable", e.status, awake ? "awake, out of time" : "did not wake");
                    throw e;
                }
                return await post(kind, inputs, left());
            }
        },
    };
}

function parseResult(body: unknown, n: number): EmbedResult | null {
    if (!body || typeof body !== "object") return null;
    const b = body as { model?: unknown; vectors?: unknown; images?: unknown };
    if (typeof b.model !== "string" || !Array.isArray(b.vectors) || b.vectors.length !== n) return null;
    const vectors: number[][] = [];
    for (const v of b.vectors) {
        if (!Array.isArray(v) || v.length !== EMBED_DIMS || !v.every((x) => typeof x === "number" && Number.isFinite(x))) {
            return null;
        }
        vectors.push(normalize(v as number[]));
    }
    const images = Array.isArray(b.images) && b.images.length === n ? b.images.map((x) => x === true) : vectors.map(() => false);
    return { model: b.model, vectors, images };
}

// ---- vectors -----------------------------------------------------------------------------------

export function normalize(v: number[]): number[] {
    let s = 0;
    for (const x of v) s += x * x;
    const n = Math.sqrt(s);
    return n > 0 ? v.map((x) => x / n) : v;
}

// base64 of little-endian float32, the column format.
export function encodeVector(v: number[]): string {
    const buf = new ArrayBuffer(v.length * 4);
    const view = new DataView(buf);
    v.forEach((x, i) => view.setFloat32(i * 4, x, true));
    let bin = "";
    const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
    return btoa(bin);
}

export function decodeVector(s: string): Float32Array | null {
    let bin: string;
    try {
        bin = atob(s);
    } catch {
        return null;
    }
    if (bin.length % 4 !== 0) return null;
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const view = new DataView(bytes.buffer);
    const out = new Float32Array(bin.length / 4);
    for (let i = 0; i < out.length; i++) out[i] = view.getFloat32(i * 4, true);
    return out;
}

export function dot(a: ArrayLike<number>, b: ArrayLike<number>): number {
    const n = Math.min(a.length, b.length);
    let s = 0;
    for (let i = 0; i < n; i++) s += a[i]! * b[i]!;
    return s;
}

async function sha256(s: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---- what a post is embedded from -------------------------------------------------------------

export type PostInput = EmbedInput & { post_key: string; latest: number };

type InputRow = {
    post_key: string;
    name: string | null;
    link: string | null;
    poster: string | null;
    content_type: string | null;
    bucket: string;
    source: string;
    role: string | null;
    item_index: number | null;
    created_at: number;
};

function linkWords(link: string | null): string {
    if (!link || !/^https?:\/\//i.test(link)) return "";
    try {
        const u = new URL(link);
        return `${u.hostname.replace(/^www\./, "")}${u.pathname === "/" ? "" : u.pathname}`;
    } catch {
        return "";
    }
}

// The post's lead file, as GET /library picks it (app-routes.ts leadOf): a gallery's first video, else
// its first item; else the original.
function lead(fs: InputRow[]): InputRow | undefined {
    const items = fs.filter((f) => f.role === "item").sort((a, b) => (a.item_index ?? 0) - (b.item_index ?? 0));
    return (
        items.find((f) => (f.content_type ?? "").startsWith("video/")) ??
        items[0] ??
        fs.find((f) => f.bucket === "originals" && (f.source === "saved" || f.source === "upload"))
    );
}

// Every live post's inputs, newest post first (or only `onlyPostKey`'s, which D1 filters: one post's
// rows and title come back, not the whole library's). Posters are used only from the public media
// domain (the Space fetches them itself and refuses any other URL).
export async function postInputs(db: D1Database, mediaBaseUrl: string, onlyPostKey?: string): Promise<PostInput[]> {
    const one = onlyPostKey !== undefined;
    const filesStmt = db.prepare(
        `SELECT * FROM (SELECT m.name, m.link, m.poster, m.content_type, m.bucket, m.source, m.role, m.item_index,
                               m.created_at, ${POST_KEY_SQL} AS post_key
                        FROM media_items m WHERE m.deleted_at IS NULL)${one ? " WHERE post_key = ?1" : ""}
         ORDER BY created_at DESC`,
    );
    const { results: files } = await (one ? filesStmt.bind(onlyPostKey) : filesStmt).all<InputRow>();
    if (one && files.length === 0) return [];
    const titlesStmt = db.prepare(`SELECT post_key, title FROM media_titles${one ? " WHERE post_key = ?1" : ""}`);
    const { results: titleRows } = await (one ? titlesStmt.bind(onlyPostKey) : titlesStmt).all<{ post_key: string; title: string }>();
    const titles = new Map(titleRows.map((t) => [t.post_key, t.title]));

    const byPost = new Map<string, InputRow[]>();
    for (const f of files) {
        const list = byPost.get(f.post_key);
        if (list) list.push(f);
        else byPost.set(f.post_key, [f]);
    }
    const base = mediaBaseUrl.endsWith("/") ? mediaBaseUrl : `${mediaBaseUrl}/`;
    const out: PostInput[] = [];
    for (const [post_key, fs] of byPost) {
        const l = lead(fs);
        const names = [...new Set(fs.map((f) => (f.name ?? "").trim()).filter(Boolean))].slice(0, 5);
        const link = l?.link ?? fs.find((f) => f.link)?.link ?? null;
        const poster = l?.poster ?? fs.find((f) => f.poster)?.poster ?? null;
        const title = titles.get(post_key) ?? l?.name ?? names[0] ?? null;
        const text = [names.join(" · "), linkWords(link)].filter(Boolean).join(" · ").slice(0, 2000);
        out.push({
            post_key,
            latest: fs[0]!.created_at,
            title: title ? title.slice(0, 400) : null,
            text,
            image_url: poster && poster.startsWith(base) ? poster : null,
        });
    }
    out.sort((a, b) => b.latest - a.latest || (a.post_key < b.post_key ? 1 : -1));
    return out;
}

export const inputHash = (p: EmbedInput): Promise<string> =>
    sha256(JSON.stringify([EMBED_MODEL, EMBED_DIMS, p.title ?? "", p.text, p.image_url ?? ""]));

// ---- the cron's pass ---------------------------------------------------------------------------

type EmbedRow = {
    post_key: string;
    input_hash: string;
    attempts: number;
    failed_at: number | null;
    has_vector: number;
};

export type IndexerDeps = {
    db: D1Database;
    client: EmbedClient;
    mediaBaseUrl: string;
    now: () => number;
    batch?: number;
};

export type IndexerResult = {
    posts: number;
    indexed: number;
    failed: number;
    removed: number;
    pending: number;
    unavailable: boolean;
};

const CHUNK = 50;

type Planned = PostInput & { hash: string; row: EmbedRow | undefined };

// Where every live post stands: `todo` needs a vector now (inputs changed, never embedded, or a
// refusal whose hour is up), newest first; `failed` was refused and waits (its hour, or for good
// after EMBED_MAX_ATTEMPTS); `done` has the vector of its current inputs.
async function planIndex(
    inputs: PostInput[],
    existing: Map<string, EmbedRow>,
    now: number,
): Promise<{ todo: Planned[]; failed: number; done: number }> {
    const todo: Planned[] = [];
    let failed = 0;
    let done = 0;
    for (const p of inputs) {
        const hash = await inputHash(p);
        const row = existing.get(p.post_key);
        if (row && row.input_hash === hash) {
            if (row.failed_at === null && row.has_vector) {
                done++;
                continue;
            }
            if (row.attempts >= EMBED_MAX_ATTEMPTS || (row.failed_at !== null && row.failed_at > now - EMBED_RETRY_MS)) {
                failed++;
                continue;
            }
        }
        todo.push({ ...p, hash, row });
    }
    return { todo, failed, done };
}

export async function runIndexer(d: IndexerDeps): Promise<IndexerResult> {
    const now = d.now();
    const inputs = await postInputs(d.db, d.mediaBaseUrl);
    const { results: rows } = await d.db
        .prepare("SELECT post_key, input_hash, attempts, failed_at, vector IS NOT NULL AS has_vector FROM media_embeddings")
        .all<EmbedRow>();
    const existing = new Map(rows.map((r) => [r.post_key, r]));

    // posts that are gone
    const live = new Set(inputs.map((p) => p.post_key));
    const gone = rows.filter((r) => !live.has(r.post_key)).map((r) => r.post_key);
    for (let i = 0; i < gone.length; i += CHUNK) {
        const part = gone.slice(i, i + CHUNK);
        await d.db
            .prepare(`DELETE FROM media_embeddings WHERE post_key IN (${part.map(() => "?").join(", ")})`)
            .bind(...part)
            .run();
    }

    const { todo } = await planIndex(inputs, existing, now);

    const size = d.batch ?? EMBED_BATCH;
    const batch = todo.slice(0, size);
    const result: IndexerResult = {
        posts: inputs.length,
        indexed: 0,
        failed: 0,
        removed: gone.length,
        pending: todo.length,
        unavailable: false,
    };
    if (batch.length === 0) return result;

    const strip = (p: PostInput): EmbedInput => ({ title: p.title, text: p.text, image_url: p.image_url });
    const save = async (p: (typeof batch)[number], vector: number[], image: boolean, model: string) => {
        await d.db
            .prepare(
                `INSERT INTO media_embeddings (post_key, model, dims, vector, input_hash, has_image, embedded_at, failed_at, attempts)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, 0)
                 ON CONFLICT (post_key) DO UPDATE SET model = ?2, dims = ?3, vector = ?4, input_hash = ?5,
                     has_image = ?6, embedded_at = ?7, failed_at = NULL, attempts = 0`,
            )
            .bind(p.post_key, model, EMBED_DIMS, encodeVector(vector), p.hash, image ? 1 : 0, now)
            .run();
        result.indexed++;
    };
    // A refusal keeps the old vector (stale, still searchable) and counts an attempt against this input.
    const refuse = async (p: (typeof batch)[number]) => {
        await d.db
            .prepare(
                `INSERT INTO media_embeddings (post_key, model, dims, vector, input_hash, has_image, embedded_at, failed_at, attempts)
                 VALUES (?1, ?2, ?3, NULL, ?4, 0, NULL, ?5, 1)
                 ON CONFLICT (post_key) DO UPDATE SET
                     attempts = CASE WHEN input_hash = ?4 THEN attempts + 1 ELSE 1 END,
                     input_hash = ?4, failed_at = ?5`,
            )
            .bind(p.post_key, EMBED_MODEL, EMBED_DIMS, p.hash, now)
            .run();
        result.failed++;
    };

    try {
        const r = await d.client.embed("document", batch.map(strip), EMBED_CALL_MS);
        for (let i = 0; i < batch.length; i++) await save(batch[i]!, r.vectors[i]!, r.images[i]!, r.model);
    } catch (e) {
        if (!(e instanceof EmbedError) || e.kind === "unavailable") {
            result.unavailable = true;
        } else {
            // One input spoiled the batch: each alone, so only the bad one is held back.
            for (const p of batch) {
                try {
                    const r = await d.client.embed("document", [strip(p)], EMBED_CALL_MS);
                    await save(p, r.vectors[0]!, r.images[0]!, r.model);
                } catch (e2) {
                    if (!(e2 instanceof EmbedError) || e2.kind === "unavailable") {
                        result.unavailable = true;
                        break;
                    }
                    await refuse(p);
                }
            }
        }
    }
    result.pending = todo.length - result.indexed - result.failed;
    return result;
}

// ---- the drain: passes until the queue is empty --------------------------------------------------

// One cron run loops passes for at most this long, so it ends well before the next */15 run (a
// scheduled handler may run 15 minutes). About 12 passes of 8 at ~50 s each: ~96 posts a run.
export const SEARCH_RUN_BUDGET_MS = 10 * 60 * 1000;
// POST /library/search/index?drain=1 loops under this (someone's request is waiting).
export const SEARCH_DRAIN_REQUEST_MS = 25_000;
// Run records older than this are deleted when a new run starts.
export const SEARCH_RUNS_KEEP_MS = 7 * 24 * 60 * 60 * 1000;

// "empty": nothing pending. "unavailable": the Space is asleep or down. "budget": the time is up
// (or the next pass would not fit). "stalled": a pass moved nothing. "passes": maxPasses reached.
// "error": a pass threw (D1).
export type DrainStop = "empty" | "unavailable" | "budget" | "stalled" | "passes" | "error";

export type DrainResult = IndexerResult & { passes: number; stop: DrainStop };

export type DrainDeps = IndexerDeps & {
    budgetMs: number;
    maxPasses?: number;
    // what started the run, kept in search_index_runs
    trigger?: "cron" | "request";
};

// Passes of runIndexer until a stop (DrainStop). The first pass always runs; another starts only
// if the last pass's length still fits in the budget. Each run is recorded in search_index_runs
// (migration 0011); a missing table only loses the record.
export async function drainIndexer(d: DrainDeps): Promise<DrainResult> {
    const start = d.now();
    const runId = await startRun(d.db, d.trigger ?? "cron", start);
    const total: DrainResult = { posts: 0, indexed: 0, failed: 0, removed: 0, pending: 0, unavailable: false, passes: 0, stop: "empty" };
    try {
        for (;;) {
            const t = d.now();
            const r = await runIndexer(d);
            const took = d.now() - t;
            total.passes++;
            total.posts = r.posts;
            total.indexed += r.indexed;
            total.failed += r.failed;
            total.removed += r.removed;
            total.pending = r.pending;
            total.unavailable = r.unavailable;
            if (r.unavailable) total.stop = "unavailable";
            else if (r.pending === 0) total.stop = "empty";
            else if (r.indexed + r.failed === 0) total.stop = "stalled";
            else if (d.maxPasses !== undefined && total.passes >= d.maxPasses) total.stop = "passes";
            else if (d.now() - start + took > d.budgetMs) total.stop = "budget";
            else {
                await recordRun(d.db, runId, total, null);
                continue;
            }
            break;
        }
    } catch (e) {
        total.stop = "error";
        throw e;
    } finally {
        await recordRun(d.db, runId, total, d.now());
    }
    return total;
}

async function startRun(db: D1Database, trigger: string, now: number): Promise<number | null> {
    try {
        await db.prepare("DELETE FROM search_index_runs WHERE started_at < ?1").bind(now - SEARCH_RUNS_KEEP_MS).run();
        const row = await db
            .prepare("INSERT INTO search_index_runs (trigger, started_at) VALUES (?1, ?2) RETURNING id")
            .bind(trigger, now)
            .first<{ id: number }>();
        return row?.id ?? null;
    } catch (e) {
        console.error("[search] run record failed", String(e));
        return null;
    }
}

// Progress after each pass (finished_at NULL), and the outcome at the end.
async function recordRun(db: D1Database, id: number | null, r: DrainResult, finishedAt: number | null): Promise<void> {
    if (id === null) return;
    try {
        await db
            .prepare(
                `UPDATE search_index_runs SET passes = ?2, indexed = ?3, failed = ?4, unavailable = ?5, stop = ?6, finished_at = ?7
                 WHERE id = ?1`,
            )
            .bind(id, r.passes, r.indexed, r.failed, r.unavailable ? 1 : 0, finishedAt === null ? null : r.stop, finishedAt)
            .run();
    } catch (e) {
        console.error("[search] run record failed", String(e));
    }
}

// ---- GET /queue: where the index stands ----------------------------------------------------------

export const QUEUE_NEXT = 5;

export type SearchQueue =
    | { enabled: false }
    | {
          enabled: true;
          posts: number;
          indexed: number;
          pending: number;
          failed: number;
          running: boolean | null;
          last_run_at: number | null;
          rate_per_hour: number | null;
          next: { post_key: string; title: string | null }[];
      };

// The index as runIndexer would see it now, plus the run records. `running`, `last_run_at` and
// `rate_per_hour` are null while migration 0011 is not applied.
export async function searchQueue(d: { db: D1Database; mediaBaseUrl: string; now: number; enabled: boolean }): Promise<SearchQueue> {
    if (!d.enabled) return { enabled: false };
    const inputs = await postInputs(d.db, d.mediaBaseUrl);
    const { results: rows } = await d.db
        .prepare("SELECT post_key, input_hash, attempts, failed_at, vector IS NOT NULL AS has_vector FROM media_embeddings")
        .all<EmbedRow>();
    const plan = await planIndex(inputs, new Map(rows.map((r) => [r.post_key, r])), d.now);
    let running: boolean | null = null;
    let lastRunAt: number | null = null;
    let rate: number | null = null;
    try {
        const last = await d.db
            .prepare("SELECT started_at, finished_at FROM search_index_runs ORDER BY started_at DESC, id DESC LIMIT 1")
            .first<{ started_at: number; finished_at: number | null }>();
        lastRunAt = last?.started_at ?? null;
        // a run whose Worker died never finishes: only a recent one counts as running
        running = !!last && last.finished_at === null && last.started_at > d.now - SEARCH_RUN_BUDGET_MS - EMBED_CALL_MS;
        const hour = await d.db
            .prepare("SELECT COUNT(*) AS runs, COALESCE(SUM(indexed), 0) AS indexed FROM search_index_runs WHERE started_at > ?1")
            .bind(d.now - 60 * 60 * 1000)
            .first<{ runs: number; indexed: number }>();
        rate = hour && hour.runs > 0 ? hour.indexed : null;
    } catch {
        // no run table yet
    }
    return {
        enabled: true,
        posts: inputs.length,
        indexed: plan.done,
        pending: plan.todo.length,
        failed: plan.failed,
        running,
        last_run_at: lastRunAt,
        rate_per_hour: rate,
        next: plan.todo.slice(0, QUEUE_NEXT).map((p) => ({ post_key: p.post_key, title: p.title })),
    };
}

// ---- GET /library/search -----------------------------------------------------------------------

export type SearchHit = { post_key: string; score: number; latest: number };

export type SearchOutcome =
    | { ok: true; hits: SearchHit[]; indexed: number; pending: number; fallback: boolean }
    | { ok: false; status: number; code: string };

// The words of a query for the name-match fallback: lowercase, at least two characters each.
const queryWords = (needle: string): string[] => [...new Set(needle.split(/[^\p{L}\p{N}]+/u).filter((w) => w.length >= 2))];

export async function searchPosts(
    d: { db: D1Database; client: EmbedClient | null; mediaBaseUrl: string },
    rawQuery: string,
    limit: number,
    opts: { textFallback?: boolean } = {},
): Promise<SearchOutcome> {
    const q = rawQuery.trim().replace(/\s+/g, " ");
    if (q.length === 0 || q.length > MAX_QUERY_CHARS) return { ok: false, status: 400, code: "error.library.bad_request" };
    if (!d.client) return { ok: false, status: 503, code: "error.search.off" };

    // null: the Space could not answer (asleep, booting, down), so the answer is name matches only
    let qv: number[] | null;
    try {
        const r = await d.client.embed("query", [{ title: null, text: q, image_url: null }], QUERY_CALL_MS);
        qv = r.vectors[0]!;
    } catch (e) {
        if (e instanceof EmbedError && e.kind === "rejected") return { ok: false, status: 502, code: "error.search.failed" };
        // callers that need meaning (stage pools) say "waking up" instead of name matches
        if (opts.textFallback === false) return { ok: false, status: 503, code: "error.search.waking" };
        console.log("[search] space unavailable, answering with name matches");
        qv = null;
    }

    const inputs = await postInputs(d.db, d.mediaBaseUrl);
    const { results: rows } = await d.db
        .prepare("SELECT post_key, vector, input_hash FROM media_embeddings WHERE model = ? AND dims = ? AND vector IS NOT NULL")
        .bind(EMBED_MODEL, EMBED_DIMS)
        .all<{ post_key: string; vector: string; input_hash: string }>();
    const vectors = new Map(rows.map((r) => [r.post_key, r]));

    const needle = q.toLowerCase();
    const words = queryWords(needle);
    const hits: SearchHit[] = [];
    let indexed = 0;
    let pending = 0;
    for (const p of inputs) {
        const row = vectors.get(p.post_key);
        const v = row ? decodeVector(row.vector) : null;
        if (v) indexed++;
        if (!row || row.input_hash !== (await inputHash(p))) pending++;
        const hay = `${p.title ?? ""} ${p.text}`.toLowerCase();
        const bonus = hay.includes(needle) ? TEXT_MATCH_BONUS : 0;
        if (qv) {
            if (!v && bonus === 0) continue;
            hits.push({ post_key: p.post_key, score: (v ? dot(qv, v) : 0) + bonus, latest: p.latest });
            continue;
        }
        // Fallback: the whole query as text first, then posts holding more of its words; newest first within a score.
        const found = words.filter((w) => hay.includes(w)).length;
        if (bonus === 0 && found === 0) continue;
        const score = bonus + (words.length > 0 ? (TEXT_MATCH_BONUS * found) / words.length : 0);
        hits.push({ post_key: p.post_key, score, latest: p.latest });
    }
    if (qv) hits.sort((a, b) => b.score - a.score || (a.post_key < b.post_key ? -1 : 1));
    else hits.sort((a, b) => b.score - a.score || b.latest - a.latest || (a.post_key < b.post_key ? -1 : 1));
    return { ok: true, hits: hits.slice(0, limit), indexed, pending, fallback: qv === null };
}

// GET /library/search?q=<words>&limit=<1..50>&v=<2|3>: the posts that best match, best first, in the
// GET /library post shape plus `score`. Keyed or service (the web Worker).
export async function librarySearch(d: AppDeps & { embed: EmbedClient | null }, q: URLSearchParams): Promise<StudioReply> {
    const fail = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });
    let limit = DEFAULT_SEARCH_LIMIT;
    if (q.has("limit")) {
        const raw = q.get("limit") ?? "";
        if (!/^\d{1,3}$/.test(raw)) return fail(400, "error.library.bad_request");
        limit = Number(raw);
        if (limit < 1 || limit > MAX_SEARCH_LIMIT) return fail(400, "error.library.bad_request");
    }
    try {
        const r = await searchPosts({ db: d.db, client: d.embed, mediaBaseUrl: d.mediaBaseUrl }, q.get("q") ?? "", limit);
        if (!r.ok) return fail(r.status, r.code);
        const v3 = q.get("v") === "3";
        const v2 = v3 || q.get("v") === "2";
        const page = r.hits.map((h) => ({ post_key: h.post_key, latest: h.latest }));
        const { posts } = await assemblePosts(d, page, { v2, v3, hide: libraryHide(v2, v3), now: d.now() });
        const scores = new Map(r.hits.map((h) => [h.post_key, h.score]));
        const out = posts
            .filter((p) => Array.isArray(p.files) && p.files.length > 0)
            .map((p) => ({ ...p, score: Math.round((scores.get(p.id) ?? 0) * 10000) / 10000 }));
        return {
            status: 200,
            body: {
                status: "success",
                query: (q.get("q") ?? "").trim(),
                model: EMBED_MODEL,
                posts: out,
                index: { posts: r.indexed, pending: r.pending },
                // the Space could not answer: these are name matches, and a search a minute later is semantic again
                ...(r.fallback ? { fallback: "text" } : {}),
            },
        };
    } catch (e) {
        console.error("[search] failed", String(e));
        return fail(503, "error.api.generic");
    }
}

// POST /library/search/index: one indexer pass now; `?drain=1` loops passes for up to
// SEARCH_DRAIN_REQUEST_MS (the cron drains for up to SEARCH_RUN_BUDGET_MS every 15 minutes). Keyed.
export async function librarySearchIndex(d: AppDeps & { embed: EmbedClient | null }, q = new URLSearchParams()): Promise<StudioReply> {
    const drain = q.get("drain");
    if (drain !== null && !["", "0", "1", "false", "true"].includes(drain)) {
        return { status: 400, body: { status: "error", error: { code: "error.library.bad_request" } } };
    }
    if (!d.embed) return { status: 503, body: { status: "error", error: { code: "error.search.off" } } };
    const loop = drain === "1" || drain === "true";
    try {
        const r = await drainIndexer({
            db: d.db,
            client: d.embed,
            mediaBaseUrl: d.mediaBaseUrl,
            now: d.now,
            trigger: "request",
            budgetMs: SEARCH_DRAIN_REQUEST_MS,
            maxPasses: loop ? undefined : 1,
        });
        const { passes, stop, ...pass } = r;
        return { status: 200, body: { status: "success", ...pass, ...(loop ? { passes, stop } : {}) } };
    } catch (e) {
        console.error("[search] index failed", String(e));
        return { status: 503, body: { status: "error", error: { code: "error.api.generic" } } };
    }
}

// GET /library/search/post?key=<post_key>: what the search index holds for one post, for the post's
// detail screen. Keyed or service (the web Worker). Answers from D1 even while the Space is not
// configured (`search_enabled: false`). Never returns the vector.
export const MAX_POST_KEY_CHARS = 2048;

export type PostIndexState = "indexed" | "stale" | "pending" | "failed" | "gave_up";

export async function librarySearchPost(
    d: { db: D1Database; mediaBaseUrl: string; searchEnabled: boolean },
    q: URLSearchParams,
): Promise<StudioReply> {
    const fail = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });
    const key = q.get("key") ?? "";
    if (key.length === 0 || key.length > MAX_POST_KEY_CHARS) return fail(400, "error.library.bad_request");
    try {
        const [p] = await postInputs(d.db, d.mediaBaseUrl, key);
        if (!p) return fail(404, "error.library.not_found");
        const row = await d.db
            .prepare(
                `SELECT model, dims, vector IS NOT NULL AS has_vector, input_hash, has_image, embedded_at, failed_at, attempts
                 FROM media_embeddings WHERE post_key = ?1`,
            )
            .bind(key)
            .first<{
                model: string;
                dims: number;
                has_vector: number;
                input_hash: string;
                has_image: number;
                embedded_at: number | null;
                failed_at: number | null;
                attempts: number;
            }>();
        const hash = await inputHash(p);
        const same = !!row && row.input_hash === hash;
        const hasVector = !!row && !!row.has_vector;
        // A refusal keeps the old vector but writes the new input's hash and failed_at (runIndexer), so
        // a vector matches the current input only when the hash matches and nothing failed since.
        const matches = same && hasVector && row!.failed_at === null;
        let state: PostIndexState;
        if (matches) state = "indexed";
        else if (same && row!.attempts >= EMBED_MAX_ATTEMPTS) state = "gave_up";
        else if (same && row!.failed_at !== null) state = "failed";
        else if (hasVector) state = "stale";
        else state = "pending";
        return {
            status: 200,
            body: {
                status: "success",
                post_key: p.post_key,
                state,
                search_enabled: d.searchEnabled,
                ...(hasVector
                    ? { model: row!.model, dims: row!.dims, embedded_at: row!.embedded_at, has_image: !!row!.has_image }
                    : {}),
                ...(row && row.failed_at !== null ? { failed_at: row.failed_at } : {}),
                ...(state === "failed" ? { retry_at: row!.failed_at! + EMBED_RETRY_MS } : {}),
                // attempts count against the current input only (a changed input starts over)
                attempts: same ? row!.attempts : 0,
                input: { title: p.title, text: p.text, image_url: p.image_url },
                embedded_matches_input: matches,
            },
        };
    } catch (e) {
        console.error("[search] post status failed", String(e));
        return fail(503, "error.api.generic");
    }
}

// ---- GET /library/map --------------------------------------------------------------------------

// GET /library/map: every indexed post with its vector, for the library's map view (the page lays the
// posts out in 2D itself, so the server only hands over vectors). Keyed or service (the web Worker).
// Vectors go out as `v8`: base64 of int8, each vector scaled so its largest component is ±127. Only
// the direction matters for similarity, so this keeps the map faithful at a quarter of float32's size.
// Answers from D1 even while the Space is not configured.
export function quantizeVector(v: ArrayLike<number>): string {
    let max = 0;
    for (let i = 0; i < v.length; i++) max = Math.max(max, Math.abs(v[i]!));
    const bytes = new Uint8Array(v.length);
    for (let i = 0; i < v.length; i++) {
        const q = max > 0 ? Math.round((v[i]! / max) * 127) : 0;
        bytes[i] = q & 0xff;
    }
    let bin = "";
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
    return btoa(bin);
}

export async function libraryMap(d: { db: D1Database; mediaBaseUrl: string; searchEnabled: boolean }): Promise<StudioReply> {
    try {
        const inputs = await postInputs(d.db, d.mediaBaseUrl);
        const { results: rows } = await d.db
            .prepare("SELECT post_key, vector FROM media_embeddings WHERE model = ? AND dims = ? AND vector IS NOT NULL")
            .bind(EMBED_MODEL, EMBED_DIMS)
            .all<{ post_key: string; vector: string }>();
        const vectors = new Map(rows.map((r) => [r.post_key, r.vector]));
        const posts: { post_key: string; title: string | null; text: string; image_url: string | null; latest: number; v8: string }[] = [];
        for (const p of inputs) {
            const raw = vectors.get(p.post_key);
            const v = raw ? decodeVector(raw) : null;
            if (!v || v.length !== EMBED_DIMS) continue;
            posts.push({ post_key: p.post_key, title: p.title, text: p.text, image_url: p.image_url, latest: p.latest, v8: quantizeVector(v) });
        }
        return {
            status: 200,
            body: {
                status: "success",
                model: EMBED_MODEL,
                dims: EMBED_DIMS,
                search_enabled: d.searchEnabled,
                posts,
                // live posts not on the map yet (never embedded)
                unmapped: inputs.length - posts.length,
            },
        };
    } catch (e) {
        console.error("[search] map failed", String(e));
        return { status: 503, body: { status: "error", error: { code: "error.api.generic" } } };
    }
}
