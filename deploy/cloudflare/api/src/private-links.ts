// Private share links (APP-API-CONTRACT.md section 36): share.../p/<key> opens one file (kind "item") or one gallery
// link (kind "set") while the public address of the same thing is a 404. The key is 22 base62 characters (~131 bits)
// and is stored as is (it opens one thing and nothing else, so the app can always show and copy it). At most one live
// link per target (a partial unique index); rotating revokes the row and inserts the next.
//
// D1 only, free of Cloudflare imports (the tests run it under node). Until migration 0024 is applied the tables are
// missing: the readers here answer "no link" and "public", the writers throw (the routes answer 503).
import { randomBase62 } from "./ids";

export const PRIVATE_KEY_LENGTH = 22;
export const PRIVATE_KEY_REGEX = /^[A-Za-z0-9]{22}$/;
export type PrivateKind = "item" | "set";
export type NewLinks = "public" | "private";

export type PrivateLinkRow = {
    key: string;
    kind: PrivateKind;
    target_id: string;
    created_at: number;
    revoked_at: number | null;
    opened: number;
    last_opened_at: number | null;
};

// What every route answers for a link (36.3).
export type PrivateLink = {
    kind: PrivateKind;
    target_id: string;
    url: string;
    created_at: number;
    opened: number;
    last_opened_at: number | null;
};

const COLUMNS = "key, kind, target_id, created_at, revoked_at, opened, last_opened_at";
const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

export const privateUrl = (shareBaseUrl: string, key: string) => `${withSlash(shareBaseUrl)}p/${key}`;

export const linkShape = (r: PrivateLinkRow, shareBaseUrl: string): PrivateLink => ({
    kind: r.kind,
    target_id: r.target_id,
    url: privateUrl(shareBaseUrl, r.key),
    created_at: r.created_at,
    opened: r.opened ?? 0,
    last_opened_at: r.last_opened_at ?? null,
});

// A D1 error that means "migration 0024 is not applied" (as opposed to D1 being down).
export const isMissingTable = (e: unknown) => /no such table/i.test(String(e instanceof Error ? e.message : e));

export const newPrivateKey = (rb?: (n: number) => Uint8Array) => randomBase62(PRIVATE_KEY_LENGTH, rb);

// ---- readers ----------------------------------------------------------------------------------------------------------

// The live link of one target, or null. Throws when the table is missing (the routes answer 503).
export async function liveLink(db: D1Database, kind: PrivateKind, targetId: string): Promise<PrivateLinkRow | null> {
    return (
        (await db
            .prepare(`SELECT ${COLUMNS} FROM private_links WHERE kind = ?1 AND target_id = ?2 AND revoked_at IS NULL`)
            .bind(kind, targetId)
            .first<PrivateLinkRow>()) ?? null
    );
}

// The live links of these targets, by target id. Never throws for a missing table (no links then); other D1 errors
// propagate, so a page never shows a private target as public because D1 hiccuped.
export async function liveLinksFor(db: D1Database, kind: PrivateKind, ids: string[]): Promise<Map<string, PrivateLinkRow>> {
    const out = new Map<string, PrivateLinkRow>();
    if (ids.length === 0) return out;
    try {
        const { results } = await db
            .prepare(
                `SELECT ${COLUMNS} FROM private_links WHERE kind = ?1 AND revoked_at IS NULL AND target_id IN (SELECT value FROM json_each(?2))`,
            )
            .bind(kind, JSON.stringify([...new Set(ids)]))
            .all<PrivateLinkRow>();
        for (const r of results) out.set(r.target_id, r);
    } catch (e) {
        if (!isMissingTable(e)) throw e;
    }
    return out;
}

// Whether a gallery link is private right now (its public /g/<id> routes are then 404s). A missing table: no.
export async function setIsPrivate(db: D1Database, setId: string): Promise<boolean> {
    return (await liveLinksFor(db, "set", [setId])).has(setId);
}

// The live link a key opens, or null (malformed, unknown, revoked, or the table missing).
export async function linkByKey(db: D1Database, key: string): Promise<PrivateLinkRow | null> {
    if (!PRIVATE_KEY_REGEX.test(key)) return null;
    try {
        return (
            (await db.prepare(`SELECT ${COLUMNS} FROM private_links WHERE key = ?1 AND revoked_at IS NULL`).bind(key).first<PrivateLinkRow>()) ?? null
        );
    } catch (e) {
        if (isMissingTable(e)) return null;
        throw e;
    }
}

// Every live link, newest first. Throws when the table is missing.
export async function allLiveLinks(db: D1Database): Promise<PrivateLinkRow[]> {
    const { results } = await db
        .prepare(`SELECT ${COLUMNS} FROM private_links WHERE revoked_at IS NULL ORDER BY created_at DESC, key DESC`)
        .all<PrivateLinkRow>();
    return results;
}

// A page GET counts (not HEAD, not file fetches). Best effort.
export async function noteOpened(db: D1Database, key: string, now: number): Promise<void> {
    try {
        await db.prepare("UPDATE private_links SET opened = opened + 1, last_opened_at = ?2 WHERE key = ?1 AND revoked_at IS NULL").bind(key, now).run();
    } catch (e) {
        console.error("[private] open count failed", String(e));
    }
}

// share_settings.new_links: "public" for a missing row or table.
export async function newLinksSetting(db: D1Database): Promise<NewLinks> {
    try {
        const r = await db.prepare("SELECT new_links FROM share_settings WHERE id = 1").first<{ new_links: string }>();
        return r?.new_links === "private" ? "private" : "public";
    } catch {
        return "public";
    }
}

// ---- writers (throw on a missing table) -----------------------------------------------------------------------------

export async function setNewLinks(db: D1Database, value: NewLinks, now: number): Promise<void> {
    await db
        .prepare("INSERT INTO share_settings (id, new_links, updated_at) VALUES (1, ?1, ?2) ON CONFLICT (id) DO UPDATE SET new_links = ?1, updated_at = ?2")
        .bind(value, now)
        .run();
}

const insertStmt = (db: D1Database, row: PrivateLinkRow) =>
    db
        .prepare("INSERT INTO private_links (key, kind, target_id, created_at) VALUES (?1, ?2, ?3, ?4)")
        .bind(row.key, row.kind, row.target_id, row.created_at);
export const revokeStmt = (db: D1Database, kind: PrivateKind, targetId: string, now: number) =>
    db.prepare("UPDATE private_links SET revoked_at = ?3 WHERE kind = ?1 AND target_id = ?2 AND revoked_at IS NULL").bind(kind, targetId, now);

const fresh = (kind: PrivateKind, targetId: string, now: number, rb?: (n: number) => Uint8Array): PrivateLinkRow => ({
    key: newPrivateKey(rb),
    kind,
    target_id: targetId,
    created_at: now,
    revoked_at: null,
    opened: 0,
    last_opened_at: null,
});

// The live link of a target, made when there is none. A racing call that made one first wins (the unique index).
export async function ensureLink(db: D1Database, kind: PrivateKind, targetId: string, now: number, rb?: (n: number) => Uint8Array): Promise<PrivateLinkRow> {
    const have = await liveLink(db, kind, targetId);
    if (have) return have;
    const row = fresh(kind, targetId, now, rb);
    try {
        await insertStmt(db, row).run();
        return row;
    } catch (e) {
        const won = await liveLink(db, kind, targetId);
        if (won) return won;
        throw e;
    }
}

// The insert of a new link for a target, for a caller's own batch (e.g. a gallery link made private at creation).
export function linkInsert(db: D1Database, kind: PrivateKind, targetId: string, now: number, rb?: (n: number) => Uint8Array): { row: PrivateLinkRow; stmt: D1PreparedStatement } {
    const row = fresh(kind, targetId, now, rb);
    return { row, stmt: insertStmt(db, row) };
}

// Revokes a target's live link (none: nothing happens).
export async function revokeLink(db: D1Database, kind: PrivateKind, targetId: string, now: number): Promise<void> {
    await revokeStmt(db, kind, targetId, now).run();
}

// The same, never throwing: what making a file public or revoking a gallery link does on the side. A missing table
// means there is no link to revoke.
export async function revokeLinkQuietly(db: D1Database, kind: PrivateKind, targetId: string, now: number): Promise<void> {
    try {
        await revokeLink(db, kind, targetId, now);
    } catch (e) {
        if (!isMissingTable(e)) console.error("[private] revoke failed", kind, targetId, String(e));
    }
}

// A new key for a live link; the old one is a 404 at once. Null when the target has no live link.
export async function rotateLink(db: D1Database, kind: PrivateKind, targetId: string, now: number, rb?: (n: number) => Uint8Array): Promise<PrivateLinkRow | null> {
    const have = await liveLink(db, kind, targetId);
    if (!have) return null;
    const row = fresh(kind, targetId, now, rb);
    // revoke first: the partial unique index allows one live row per target
    await db.batch([revokeStmt(db, kind, targetId, now), insertStmt(db, row)]);
    return row;
}

// Every live key rotated in one batch.
export async function rotateAllLinks(db: D1Database, now: number, rb?: (n: number) => Uint8Array): Promise<PrivateLinkRow[]> {
    const live = await allLiveLinks(db);
    if (live.length === 0) return [];
    const rows = live.map((l) => fresh(l.kind, l.target_id, now, rb));
    const stmts: D1PreparedStatement[] = [];
    for (const r of rows) stmts.push(revokeStmt(db, r.kind, r.target_id, now), insertStmt(db, r));
    await db.batch(stmts);
    return rows;
}
