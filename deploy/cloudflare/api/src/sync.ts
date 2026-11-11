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
export const IDEMPOTENCY_KEY_MAX = 200;
// The multiplier of a first load's cursor (walkCursor below). Such a cursor is only read as one while it is above the
// log's head, so plain change numbers may grow past this.
export const WALK_BASE = 100_000_000;

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

// The cursor of a first load that is not finished yet.
//
// A device that asks with since = 0 holds nothing, so no trimmed delete marker can matter to it: what it reads is the
// library as it is now. But the rows it reads keep the low numbers they have had since they were last written, and
// those are below trimmed_seq as soon as one marker has been trimmed. Handed back as a plain number, such a cursor
// cannot be told from the cursor of a device that last synced before the trim, which must be refused. So while a
// first load has more pages, its cursor also carries the trimmed_seq it was read under: trimmed_seq * WALK_BASE +
// the last row's number. It is good for as long as nothing more is trimmed (then no marker it needed is missing);
// after another trim it is refused like any stale cursor and the device starts again. The last page answers a plain
// number, at least trimmed_seq. Nothing is trimmed yet (trimmed_seq 0): every cursor is the plain number, as before.
//
// Both forms are one number, so they are told apart by the head: a plain cursor is never above it (that is refused),
// and this form is only handed out when it is WALK_BASE or more above it, further than the log can grow while a load
// runs. Where that does not hold (a trimmed_seq of 1, which makes no plain cursor stale anyway, or a head that has
// outgrown trimmed_seq * WALK_BASE) the page answers the plain number.
const walkCursor = (trimmed: number, seq: number, head: number): number | null => {
    if (trimmed <= 0 || seq >= WALK_BASE || trimmed > Math.floor(Number.MAX_SAFE_INTEGER / WALK_BASE) - 1) return null;
    const cursor = trimmed * WALK_BASE + seq;
    return cursor - head >= WALK_BASE ? cursor : null;
};

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
    const read = async (from: number): Promise<{ results?: unknown[] }[] | null> => {
        const bind = (sql: string) => d.db.prepare(sql).bind(from, take);
        const statements = [
            d.db.prepare("SELECT trimmed_seq FROM sync_state WHERE id = 1"),
            bind("SELECT seq, entity, id, gone FROM changes WHERE seq > ?1 ORDER BY seq LIMIT ?2"),
            d.db.prepare("SELECT COALESCE(MAX(seq), 0) AS seq FROM changes"),
            ...postReadStatements(d.db, from, take),
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
        try {
            if (typeof d.db.batch !== "function") return null;
            return await d.db.batch(statements);
        } catch (e) {
            if (!missing(e)) console.error("[sync] page failed", e instanceof Error ? e.message : String(e));
            return null;
        }
    };
    const headOf = (rows: { results?: unknown[] }[]) => ({
        trimmed: Number((rows[0]?.results?.[0] as { trimmed_seq?: number } | undefined)?.trimmed_seq ?? 0),
        high: Number((rows[2]?.results?.[0] as { seq?: number } | undefined)?.seq ?? 0),
    });
    // A first load's cursor (walkCursor) is WALK_BASE or more and above the head: the row to go on from, and the
    // trimmed_seq it was handed out under. The head is only known from the batch, so a cursor of that size is read
    // as one first; when it turns out to be at or below the head it is a plain change number (the log has grown past
    // WALK_BASE), and the page is read again from it. Below WALK_BASE there is one batch and no other D1 call.
    let walking = since >= WALK_BASE;
    let from = walking ? since % WALK_BASE : since;
    let answers = await read(from);
    if (!answers) return unavailable();
    if (walking && since <= Math.max(headOf(answers).high, headOf(answers).trimmed)) {
        walking = false;
        from = since;
        answers = await read(from);
        if (!answers) return unavailable();
    }
    const walkTrimmed = walking ? Math.floor(since / WALK_BASE) : 0;
    const rows = answers;
    const at = (i: number) => (rows[i]?.results ?? []) as any[];
    const { trimmed, high } = headOf(rows);
    // Too old: a delete marker above this cursor is gone, so the device would keep something that was deleted. A
    // first load is exempt while nothing was trimmed since its last page. Above the head: the cursor was not handed
    // out by this log (the database was restored to an earlier point, or reset), and the numbers between the head and
    // it will be used again for changes the device would then skip. The head is the highest number ever handed out:
    // trimming can remove the newest row, so trimmed_seq counts too.
    const head = Math.max(high, trimmed);
    // (A first load's cursor is never handed out under a trimmed_seq of 1, so one that says 1 is not from this log.)
    const stale = walking ? walkTrimmed !== trimmed || walkTrimmed < 2 : from > 0 && from < trimmed;
    if (stale || from > head) return tooOld();

    const fetched = at(1) as ChangeRow[];
    const more = fetched.length > limit;
    const page = fetched.slice(0, limit);
    const last = page.length > 0 ? Number(page[page.length - 1]!.seq) : Math.max(from, high);
    // More pages of a first load: the cursor that says so. The last page of anything: nothing below trimmed_seq is
    // left to read, so the cursor moves up to it and the next pull is not taken for a stale one.
    const firstLoad = walking || from === 0;
    const seq = more ? ((firstLoad ? walkCursor(trimmed, last, head) : null) ?? last) : Math.max(last, trimmed);

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

export type WriteGate = { replay: OpReply | null; key: string | null; fingerprint: string | null; caller?: string };

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
    return sha256Hex(`${request.method} ${url.pathname}\n${body}`);
}

const sha256Hex = async (text: string): Promise<string> => {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

// Whose key it is: the Authorization header the request was let in with (a client key or a session), hashed so the
// table never holds it. Every key and every signed-in device has its own, so the same Idempotency-Key from two of
// them is two keys. The web Worker's calls carry no Authorization (its service header is removed before an op sees
// the request), so they all share one scope, apart from every key and device.
const callerOf = (request: Request): Promise<string> => sha256Hex(`idempotency\n${request.headers.get("authorization") ?? ""}`);

const withSeq = (reply: OpReply, seq: number | null): OpReply =>
    seq === null ? reply : { ...reply, headers: { ...reply.headers, [CHANGE_SEQ_HEADER]: String(seq) } };

// A repeated Idempotency-Key from the same caller returns the first answer and does not run the write. No key, or a
// database from before migration 0038: nothing is stored and the write proceeds (closeWrite still adds the change
// number when it can). A key over the limit is refused, not ignored: the caller believes its retries are safe, and
// running the write on each of them without saying so would break that.
export async function openWrite(db: D1Database, request: Request): Promise<WriteGate> {
    const key = request.headers.get(IDEMPOTENCY_HEADER)?.trim() ?? "";
    if (key === "") return { replay: null, key: null, fingerprint: null };
    if (key.length > IDEMPOTENCY_KEY_MAX) {
        const seq = await readSeq(db).catch(() => null);
        return {
            replay: withSeq({ status: 400, body: { status: "error", error: { code: "error.idempotency.bad_key" } } }, seq),
            key: null,
            fingerprint: null,
        };
    }
    let fingerprint: string;
    let caller: string;
    try {
        fingerprint = await fingerprintOf(request);
        caller = await callerOf(request);
    } catch {
        return { replay: null, key: null, fingerprint: null };
    }
    try {
        const row = await db
            .prepare("SELECT fingerprint, status, body, seq FROM idempotency_keys WHERE caller = ?1 AND key = ?2")
            .bind(caller, key)
            .first<{ fingerprint: string; status: number; body: string; seq: number }>();
        if (!row) return { replay: null, key, fingerprint, caller };
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
    if (gate.key && gate.fingerprint && gate.caller && seq !== null && reply.status >= 200 && reply.status < 300) {
        try {
            await db
                .prepare(
                    `INSERT INTO idempotency_keys (caller, key, fingerprint, status, body, seq, created_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT (caller, key) DO NOTHING`,
                )
                .bind(gate.caller, gate.key, gate.fingerprint, reply.status, JSON.stringify(reply.body), seq, Date.now())
                .run();
        } catch (e) {
            if (!missing(e)) console.error("[sync] idempotency store failed", e instanceof Error ? e.message : String(e));
        }
    }
    return withSeq(reply, seq);
}
