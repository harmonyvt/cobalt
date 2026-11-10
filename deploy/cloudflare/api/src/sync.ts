// The server half of the sync engine (slice 1): GET /sync reads the change log in one D1 batch, and the four write
// routes the app retries honour Idempotency-Key and answer with the new change number. The log itself is maintained
// by the triggers in migration 0038, so a 15-minute job that writes a title pays one indexed row and nothing else.
import type { OpReply } from "./registry/op";
import { isMissingTable } from "./private-links";
import { POST_READ_COUNT, postReadStatements, shapePosts, type PostRead } from "./posts";

export const CHANGE_SEQ_HEADER = "x-change-seq";
export const IDEMPOTENCY_HEADER = "idempotency-key";
export const SYNC_LIMIT = 500;
// Delete markers older than this are dropped by the 15-minute cron. A client still behind that point gets 410.
export const GONE_KEEP_MS = 30 * 24 * 60 * 60 * 1000;
export const IDEMPOTENCY_KEEP_MS = 7 * 24 * 60 * 60 * 1000;
export const POST_KEY_BACKFILL_BATCH = 2000;

const missing = (e: unknown) => isMissingTable(e) || /no such column/i.test(e instanceof Error ? e.message : String(e));

export type SyncDeps = {
    db: D1Database;
    now: () => number;
    apiUrl: string;
    shareBaseUrl?: string;
};

type ChangeRow = { seq: number; entity: string; id: string; gone: number };

// The page of changes, shared by every statement in the batch. ?1 since, ?2 take (limit + 1).
const pageOf = (entity: string, gone = "gone = 0") =>
    `(SELECT id FROM (SELECT seq, entity, id, gone FROM changes WHERE seq > ?1 ORDER BY seq LIMIT ?2) WHERE entity = '${entity}' AND ${gone})`;

function parseSince(raw: string | null): number | null {
    if (raw === null || raw === "") return 0;
    if (!/^\d{1,16}$/.test(raw)) return null;
    const n = Number(raw);
    return Number.isSafeInteger(n) ? n : null;
}

function parseLimit(raw: string | null): number | null {
    if (raw === null || raw === "") return SYNC_LIMIT;
    if (!/^\d{1,4}$/.test(raw)) return null;
    const n = Number(raw);
    if (n < 1) return null;
    return Math.min(SYNC_LIMIT, n);
}

const bad = (): OpReply => ({ status: 400, body: { status: "error", error: { code: "error.sync.bad_request" } } });
const unavailable = (): OpReply => ({ status: 503, body: { status: "error", error: { code: "error.api.generic" } } });
const tooOld = (): OpReply => ({ status: 410, body: { error: "sync.cursor_too_old" } });

const jsonArray = (raw: unknown): string[] => {
    if (Array.isArray(raw)) return raw.filter((x): x is string => typeof x === "string");
    if (typeof raw !== "string" || raw === "") return [];
    try {
        const v = JSON.parse(raw);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

// GET /sync?since=&limit= . One db.batch and no other D1 call: the statements do not need each other's rows.
export async function syncPage(d: SyncDeps, q: URLSearchParams): Promise<OpReply> {
    const since = parseSince(q.has("since") ? q.get("since") : null);
    const limit = parseLimit(q.has("limit") ? q.get("limit") : null);
    if (since === null || limit === null) return bad();
    const take = limit + 1;
    const bind = (sql: string) => d.db.prepare(sql).bind(since, take);
    const statements = [
        d.db.prepare("SELECT trimmed_seq FROM sync_state WHERE id = 1"),
        bind("SELECT seq, entity, id, gone FROM changes WHERE seq > ?1 ORDER BY seq LIMIT ?2"),
        d.db.prepare("SELECT COALESCE(MAX(seq), 0) AS seq FROM changes"),
        ...postReadStatements(d.db, since, take),
        bind(`SELECT id, title, items, created_at FROM share_sets WHERE revoked_at IS NULL AND id IN ${pageOf("link")}`),
        bind(`SELECT id, name, created_at, updated_at FROM share_collections WHERE id IN ${pageOf("collection")}`),
        bind(
            `SELECT i.collection_id, i.set_id FROM share_collection_items i
              WHERE i.collection_id IN ${pageOf("collection")} ORDER BY i.added_at DESC, i.set_id DESC`,
        ),
        bind(`SELECT id, name, created_at, updated_at FROM collection_groups WHERE id IN ${pageOf("set")}`),
        bind(
            `SELECT i.group_id, i.collection_id FROM collection_group_items i
              WHERE i.group_id IN ${pageOf("set")} ORDER BY i.added_at DESC, i.collection_id DESC`,
        ),
        bind(
            `SELECT id, name, aliases, meaning, strength, cutoff, enabled, created_at, updated_at
               FROM search_names WHERE id IN ${pageOf("name")}`,
        ),
        bind(`SELECT name_id, post_key, kind FROM search_name_posts WHERE name_id IN ${pageOf("name")}`),
        bind(`SELECT id, kind, value, enabled, hits, created_at, updated_at FROM hidden_rules WHERE id IN ${pageOf("rule")}`),
    ];
    let answers: { results?: unknown[] }[];
    try {
        if (typeof d.db.batch !== "function") return unavailable();
        answers = await d.db.batch(statements);
    } catch (e) {
        if (missing(e)) return unavailable();
        console.error("[sync] page failed", e instanceof Error ? e.message : String(e));
        return unavailable();
    }
    const at = (i: number) => (answers[i]?.results ?? []) as any[];
    const trimmed = Number(at(0)[0]?.trimmed_seq ?? 0);
    if (since > 0 && since < trimmed) return tooOld();

    const fetched = at(1) as ChangeRow[];
    const more = fetched.length > limit;
    const page = fetched.slice(0, limit);
    const high = Number(at(2)[0]?.seq ?? 0);
    const seq = page.length > 0 ? Number(page[page.length - 1]!.seq) : Math.max(since, high);

    const keep = new Set(page.map((r) => `${r.entity}\0${r.id}`));
    const kept = (entity: string) => page.filter((r) => r.entity === entity && keep.has(`${entity}\0${r.id}`));

    const postRead: PostRead = {
        latests: at(3),
        files: at(4),
        sessions: at(5),
        titles: at(6),
        hidden: at(7),
        links: at(8),
    };
    const postKeys = kept("post").filter((r) => r.gone === 0).map((r) => r.id);
    const posts = shapePosts(d, postKeys, postRead, d.now());
    const posted = new Set(posts.map((p) => p.id as string));

    const gone = [
        ...page.filter((r) => r.gone === 1).map((r) => ({ entity: r.entity, id: r.id })),
        ...postKeys.filter((id) => !posted.has(id)).map((id) => ({ entity: "post", id })),
    ];

    const base = 3 + POST_READ_COUNT;
    const memberIds = (rows: { a: string; b: string }[]) => {
        const by = new Map<string, string[]>();
        for (const r of rows) by.set(r.a, [...(by.get(r.a) ?? []), r.b]);
        return by;
    };
    const setIds = memberIds(at(base + 2).map((r) => ({ a: r.collection_id as string, b: r.set_id as string })));
    const collectionIds = memberIds(at(base + 4).map((r) => ({ a: r.group_id as string, b: r.collection_id as string })));
    const marks = new Map<string, { yes: string[]; no: string[] }>();
    for (const r of at(base + 6) as { name_id: string; post_key: string; kind: string }[]) {
        const m = marks.get(r.name_id) ?? { yes: [], no: [] };
        if (r.kind === "no") m.no.push(r.post_key);
        else m.yes.push(r.post_key);
        marks.set(r.name_id, m);
    }
    const inPage = (entity: string, id: string) => keep.has(`${entity}\0${id}`) && page.some((r) => r.entity === entity && r.id === id && r.gone === 0);

    return {
        status: 200,
        body: {
            seq,
            more,
            posts,
            links: (at(base) as { id: string; title: string | null; items: string; created_at: number }[])
                .filter((r) => inPage("link", r.id))
                .map((r) => ({ id: r.id, title: r.title, items: jsonArray(r.items), created_at: r.created_at })),
            collections: (at(base + 1) as { id: string; name: string; created_at: number; updated_at: number }[])
                .filter((r) => inPage("collection", r.id))
                .map((r) => ({ ...r, set_ids: setIds.get(r.id) ?? [] })),
            sets: (at(base + 3) as { id: string; name: string; created_at: number; updated_at: number }[])
                .filter((r) => inPage("set", r.id))
                .map((r) => ({ ...r, collection_ids: collectionIds.get(r.id) ?? [] })),
            names: (at(base + 5) as any[]).filter((r) => inPage("name", r.id)).map((r) => ({
                id: r.id,
                name: r.name,
                aliases: jsonArray(r.aliases),
                meaning: r.meaning,
                strength: r.strength,
                cutoff: r.cutoff,
                enabled: !!r.enabled,
                yes: marks.get(r.id)?.yes ?? [],
                no: marks.get(r.id)?.no ?? [],
                created_at: r.created_at,
                updated_at: r.updated_at,
            })),
            rules: (at(base + 7) as any[]).filter((r) => inPage("rule", r.id)).map((r) => ({
                id: r.id,
                kind: r.kind,
                value: r.value,
                enabled: !!r.enabled,
                hits: r.hits,
                created_at: r.created_at,
                updated_at: r.updated_at,
            })),
            gone,
        },
    };
}

// Throw away delete markers older than `olderThanMs` and remember the highest seq removed. Returns that watermark.
export async function trimGoneMarkers(db: D1Database, olderThanMs: number): Promise<number> {
    const row = await db.prepare("SELECT COALESCE(MAX(seq), 0) AS seq FROM changes WHERE gone = 1 AND at < ?1").bind(olderThanMs).first<{ seq: number }>();
    const seq = Number(row?.seq ?? 0);
    if (seq > 0) {
        await db.prepare("UPDATE sync_state SET trimmed_seq = MAX(trimmed_seq, ?1) WHERE id = 1").bind(seq).run();
        await db.prepare("DELETE FROM changes WHERE gone = 1 AND at < ?1").bind(olderThanMs).run();
    }
    const now = await db.prepare("SELECT trimmed_seq FROM sync_state WHERE id = 1").first<{ trimmed_seq: number }>();
    return Number(now?.trimmed_seq ?? 0);
}

// The 15-minute cron. One or two statements when the library is caught up: a missing-key probe that hits an empty
// partial index, and a trim of old delete markers. A library the migration's 40 batches did not finish is filled
// 2,000 rows at a time and those posts are added to the log.
export async function syncMaintenance(db: D1Database, now: number): Promise<void> {
    const left = await db.prepare("SELECT id FROM media_items WHERE post_key IS NULL LIMIT 1").first<{ id: string }>();
    if (left) {
        await db
            .prepare(
                `UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id)
                  WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT ${POST_KEY_BACKFILL_BATCH})`,
            )
            .run();
        await db
            .prepare(
                `INSERT INTO changes (entity, id, gone, at)
                 SELECT 'post', post_key, 0, ?1 FROM media_items
                  WHERE deleted_at IS NULL AND post_key IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'post' AND c.id = media_items.post_key)
                  GROUP BY post_key LIMIT ${POST_KEY_BACKFILL_BATCH}`,
            )
            .bind(now)
            .run();
    }
    await trimGoneMarkers(db, now - GONE_KEEP_MS);
    await db.prepare("DELETE FROM idempotency_keys WHERE created_at < ?1").bind(now - IDEMPOTENCY_KEEP_MS).run();
}

// ---- idempotency and the change number on the four write routes --------------------------------

export type WriteGate = { replay: OpReply | null; key: string | null; fingerprint: string | null };

const readSeq = async (db: D1Database): Promise<number | null> => {
    try {
        const row = await db.prepare("SELECT COALESCE(MAX(seq), 0) AS seq FROM changes").first<{ seq: number }>();
        return Number(row?.seq ?? 0);
    } catch (e) {
        if (missing(e)) return null;
        throw e;
    }
};

async function fingerprintOf(request: Request): Promise<string> {
    const url = new URL(request.url);
    const body = request.method === "GET" || request.method === "HEAD" || request.method === "DELETE" ? "" : await request.clone().text();
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${request.method} ${url.pathname}\n${body}`));
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const withSeq = (reply: OpReply, seq: number | null): OpReply =>
    seq === null ? reply : { ...reply, headers: { ...reply.headers, [CHANGE_SEQ_HEADER]: String(seq) } };

// A repeated Idempotency-Key returns the first answer and does not run the write. No key, or a database from before
// migration 0038: nothing is stored and the write proceeds (closeWrite still adds the change number when it can).
export async function openWrite(db: D1Database, request: Request): Promise<WriteGate> {
    const key = request.headers.get(IDEMPOTENCY_HEADER)?.trim() ?? "";
    if (key === "" || key.length > 200) return { replay: null, key: null, fingerprint: null };
    let fingerprint: string;
    try {
        fingerprint = await fingerprintOf(request);
    } catch {
        return { replay: null, key: null, fingerprint: null };
    }
    try {
        const row = await db
            .prepare("SELECT fingerprint, status, body, seq FROM idempotency_keys WHERE key = ?1")
            .bind(key)
            .first<{ fingerprint: string; status: number; body: string; seq: number }>();
        if (!row) return { replay: null, key, fingerprint };
        if (row.fingerprint !== fingerprint) {
            const seq = await readSeq(db);
            return {
                replay: withSeq({ status: 409, body: { status: "error", error: { code: "error.idempotency.conflict" } } }, seq),
                key: null,
                fingerprint: null,
            };
        }
        return { replay: withSeq({ status: row.status, body: JSON.parse(row.body) }, row.seq), key: null, fingerprint: null };
    } catch (e) {
        if (missing(e)) return { replay: null, key: null, fingerprint: null };
        throw e;
    }
}

// Stamp the change number on the answer. A 2xx with a key is remembered so the retry replays it.
export async function closeWrite(db: D1Database, gate: WriteGate, reply: OpReply): Promise<OpReply> {
    const seq = await readSeq(db).catch((e) => {
        console.error("[sync] change number failed", e instanceof Error ? e.message : String(e));
        return null;
    });
    if (gate.key && gate.fingerprint && seq !== null && reply.status >= 200 && reply.status < 300) {
        try {
            await db
                .prepare(
                    `INSERT INTO idempotency_keys (key, fingerprint, status, body, seq, created_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (key) DO NOTHING`,
                )
                .bind(gate.key, gate.fingerprint, reply.status, JSON.stringify(reply.body), seq, Date.now())
                .run();
        } catch (e) {
            if (!missing(e)) console.error("[sync] idempotency store failed", e instanceof Error ? e.message : String(e));
        }
    }
    return withSeq(reply, seq);
}
