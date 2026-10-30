// Hidden posts (APP-API-CONTRACT.md section 37): the D1 side every reader and the share refusals need. Whether migration
// 0025 is applied (checked once per isolate), the SQL that leaves hidden posts out, which posts and files are hidden,
// and the row writes. The actions (hide, unhide, the bulk status, rules, the held flow) are in src/hidden.ts.
//
// Free of Cloudflare imports and of visibility.ts (which calls in here), so the tests run it under node. Until 0025 is
// applied every reader here answers "nothing is hidden" and the writers are never reached (hidden.ts answers 503).
import { POST_KEY_SQL } from "./post-key";

export type HiddenState = "hidden" | "exempt" | "held";
export type HiddenBy = "you" | "rule" | "chat";
export type HiddenRow = { post_key: string; state: HiddenState; by: HiddenBy; rule_id: string | null; at: number };

export const HIDDEN_RULE_ID_REGEX = /^[A-Za-z0-9]{16}$/;

// ---- is 0025 applied? -------------------------------------------------------------------------------------------------

// One answer per database binding (env.DB is the same object for the isolate's life; each test has its own fake). Yes is
// kept for good; no is asked again after RECHECK_MS, so an isolate that outlives the migration picks it up.
const RECHECK_MS = 60_000;
const known = new WeakMap<object, { ok: boolean; at: number }>();

export async function hiddenReady(db: D1Database): Promise<boolean> {
    const k = known.get(db);
    if (k && (k.ok || Date.now() - k.at < RECHECK_MS)) return k.ok;
    try {
        const r = await db
            .prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name IN ('media_hidden', 'hidden_rules')")
            .first<{ n: number }>();
        const ok = Number(r?.n ?? 0) === 2;
        known.set(db, { ok, at: Date.now() });
        return ok;
    } catch {
        // D1 unreachable: nothing below works either; ask again next time
        return false;
    }
}

// ---- the SQL readers append --------------------------------------------------------------------------------------------

const HIDDEN_KEYS = "SELECT post_key FROM media_hidden WHERE state = 'hidden'";
// for a query over `media_items m` (POST_KEY_SQL reads `m.`)
export const NOT_HIDDEN_SQL = ` AND ${POST_KEY_SQL} NOT IN (${HIDDEN_KEYS})`;
export const ONLY_HIDDEN_SQL = ` AND ${POST_KEY_SQL} IN (${HIDDEN_KEYS})`;

// " AND <not hidden>" while 0025 is applied, else "" (no post is hidden).
export async function notHiddenClause(db: D1Database): Promise<string> {
    return (await hiddenReady(db)) ? NOT_HIDDEN_SQL : "";
}

// ---- reads -------------------------------------------------------------------------------------------------------------

// The rows of these posts (all rows when `keys` is absent). Empty before 0025.
export async function hiddenRows(db: D1Database, keys?: string[]): Promise<Map<string, HiddenRow>> {
    const out = new Map<string, HiddenRow>();
    if (keys && keys.length === 0) return out;
    if (!(await hiddenReady(db))) return out;
    const stmt = keys
        ? db.prepare("SELECT post_key, state, by, rule_id, at FROM media_hidden WHERE post_key IN (SELECT value FROM json_each(?1))").bind(JSON.stringify([...new Set(keys)]))
        : db.prepare("SELECT post_key, state, by, rule_id, at FROM media_hidden");
    for (const r of (await stmt.all<HiddenRow>()).results) out.set(r.post_key, r);
    return out;
}

// The hidden posts' keys. Empty before 0025.
export async function hiddenPostKeys(db: D1Database): Promise<Set<string>> {
    if (!(await hiddenReady(db))) return new Set();
    const { results } = await db.prepare(HIDDEN_KEYS).all<{ post_key: string }>();
    return new Set(results.map((r) => r.post_key));
}

export async function hiddenCount(db: D1Database, state: HiddenState = "hidden"): Promise<number> {
    if (!(await hiddenReady(db))) return 0;
    const r = await db.prepare("SELECT COUNT(*) AS n FROM media_hidden WHERE state = ?1").bind(state).first<{ n: number }>();
    return Number(r?.n ?? 0);
}

// The post key of each live file named here (by its id or its public copy's id, as share links store them).
export async function postKeysOfFiles(db: D1Database, ids: string[]): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    const list = [...new Set(ids)];
    if (list.length === 0) return out;
    const { results } = await db
        .prepare(
            `SELECT m.id AS id, m.public_id AS public_id, ${POST_KEY_SQL} AS post_key FROM media_items m
              WHERE m.deleted_at IS NULL AND (m.id IN (SELECT value FROM json_each(?1)) OR m.public_id IN (SELECT value FROM json_each(?1)))`,
        )
        .bind(JSON.stringify(list))
        .all<{ id: string; public_id: string | null; post_key: string }>();
    for (const r of results) {
        out.set(r.id, r.post_key);
        if (r.public_id && !out.has(r.public_id)) out.set(r.public_id, r.post_key);
    }
    return out;
}

// The ones of these file ids whose post is hidden (in the order given). Empty before 0025.
export async function hiddenFileIds(db: D1Database, ids: string[]): Promise<string[]> {
    if (ids.length === 0 || !(await hiddenReady(db))) return [];
    const keys = await postKeysOfFiles(db, ids);
    const rows = await hiddenRows(db, [...new Set(keys.values())]);
    return [...new Set(ids)].filter((id) => rows.get(keys.get(id) ?? "")?.state === "hidden");
}

// Whether one file's post is hidden. False before 0025.
export async function fileIsHidden(db: D1Database, id: string): Promise<boolean> {
    return (await hiddenFileIds(db, [id])).length > 0;
}

// The owner shared these files by hand (made one public, turned its private link on, put it in a gallery link): a post
// held for an about rule (37.3) is no longer waited on. Returns the hidden ones (the caller refuses them), and forgets
// the `held` rows of the rest. Before 0025: none hidden, nothing to forget.
export async function shareGate(db: D1Database, ids: string[]): Promise<string[]> {
    if (ids.length === 0 || !(await hiddenReady(db))) return [];
    const keys = await postKeysOfFiles(db, ids);
    const rows = await hiddenRows(db, [...new Set(keys.values())]);
    const hidden = [...new Set(ids)].filter((id) => rows.get(keys.get(id) ?? "")?.state === "hidden");
    const held = [...rows.values()].filter((r) => r.state === "held").map((r) => r.post_key);
    if (held.length > 0) {
        await db.prepare("DELETE FROM media_hidden WHERE state = 'held' AND post_key IN (SELECT value FROM json_each(?1))").bind(JSON.stringify(held)).run();
    }
    return hidden;
}

// ---- writes (0025 applied) -----------------------------------------------------------------------------------------------

export async function setHiddenRow(db: D1Database, row: HiddenRow): Promise<void> {
    await db
        .prepare(
            `INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (post_key) DO UPDATE SET state = excluded.state, by = excluded.by, rule_id = excluded.rule_id, at = excluded.at`,
        )
        .bind(row.post_key, row.state, row.by, row.rule_id, row.at)
        .run();
}

export async function deleteHiddenRow(db: D1Database, postKey: string, state?: HiddenState): Promise<void> {
    await (state
        ? db.prepare("DELETE FROM media_hidden WHERE post_key = ?1 AND state = ?2").bind(postKey, state)
        : db.prepare("DELETE FROM media_hidden WHERE post_key = ?1").bind(postKey)
    ).run();
}
