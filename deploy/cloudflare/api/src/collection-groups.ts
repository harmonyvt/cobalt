// Collection sets (APP-API-CONTRACT.md section 28): named groups of share link collections (section 26),
// called "sets" in the app. Internally "CollectionGroup", because a "share set" is already a gallery link.
// Keyed routes only, D1 only. Deleting a group never deletes its collections; a deleted collection drops
// out of every group.

import { COLLECTION_ID_REGEX, COLLECTION_NAME_MAX, mintCollectionId } from "./share-collections";
import { readTogether, rowsOf, tryBatch } from "./share-reads";
import type { StudioReply } from "./studio";

export const GROUP_NAME_MAX = COLLECTION_NAME_MAX;
export const GROUP_MAX = 100; // groups in all
export const GROUP_COLLECTIONS_MAX = 100; // collections in one group (there are at most 100 collections)
export const GROUP_ID_REGEX = COLLECTION_ID_REGEX;
export const mintGroupId = mintCollectionId;

export type GroupDeps = {
    db: D1Database;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
};

type Row = { id: string; name: string; created_at: number; updated_at: number };

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});

// Trimmed, no control characters, 1..60 code points; null = invalid. Same rules as a collection name.
function cleanName(v: unknown): string | null {
    if (typeof v !== "string") return null;
    // eslint-disable-next-line no-control-regex
    const t = v.replace(/[\u0000-\u001f\u007f]/g, "").trim();
    if (t === "" || Array.from(t).length > GROUP_NAME_MAX) return null;
    return t;
}

// A list of distinct collection ids (absent = []), or null when malformed.
function collectionIds(v: unknown): string[] | null {
    if (v === undefined) return [];
    if (!Array.isArray(v) || !v.every((x) => typeof x === "string" && COLLECTION_ID_REGEX.test(x))) return null;
    const ids = [...new Set(v as string[])];
    return ids.length > GROUP_COLLECTIONS_MAX ? null : ids;
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
    try {
        const b = await request.json();
        return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

// The statements below are built apart from being run, so a route can send several of them as one batch: one round
// trip to D1 where each used to be its own.
type Member = { group_id: string; collection_id: string };

// The existing collections among `ids`; the rest are answered as not found.
const existingStmt = (db: D1Database, ids: string[]) =>
    db.prepare("SELECT id FROM share_collections WHERE id IN (SELECT value FROM json_each(?1))").bind(JSON.stringify(ids));

// The existing collections of the groups named by `ids` (SQL: a list of group ids), newest added first.
const membersSql = (ids: string) =>
    `SELECT i.group_id, i.collection_id FROM collection_group_items i JOIN share_collections c ON c.id = i.collection_id
      WHERE i.group_id IN (${ids})
      ORDER BY i.added_at DESC, i.collection_id DESC`;
const membersStmt = (db: D1Database, id: string) => db.prepare(membersSql("?1")).bind(id);

// Each group with its existing collections, in the order `members` came.
function shaped(rows: Row[], members: Member[]) {
    const by = new Map<string, string[]>();
    for (const r of members) by.set(r.group_id, [...(by.get(r.group_id) ?? []), r.collection_id]);
    return rows.map((r) => ({
        id: r.id,
        name: r.name,
        created_at: r.created_at,
        updated_at: r.updated_at,
        collection_ids: by.get(r.id) ?? [],
    }));
}

const oneStmt = (db: D1Database, id: string) => db.prepare("SELECT id, name, created_at, updated_at FROM collection_groups WHERE id = ?1").bind(id);

const LIST_SQL = `SELECT id, name, created_at, updated_at FROM collection_groups ORDER BY updated_at DESC, id DESC LIMIT ${GROUP_MAX}`;

export async function listGroups(d: GroupDeps): Promise<StudioReply> {
    try {
        // the groups and their collections in one round trip: the second statement names the same groups by repeating
        // the list
        const res = await readTogether(d.db, [d.db.prepare(LIST_SQL), d.db.prepare(membersSql(`SELECT g.id FROM (${LIST_SQL}) g`))]);
        return { status: 200, body: { status: "success", groups: shaped(rowsOf<Row>(res, 0), rowsOf<Member>(res, 1)) } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function createGroup(d: GroupDeps, request: Request, keyId: string): Promise<StudioReply> {
    const b = await readBody(request);
    const name = cleanName(b?.name);
    const ids = collectionIds(b?.collection_ids);
    if (!b || name === null || ids === null) return err(400, "error.group.bad_request");
    try {
        // two round trips: what is checked, then the writes with the answer read back behind them
        const checks = await readTogether(d.db, [d.db.prepare("SELECT COUNT(*) AS n FROM collection_groups"), existingStmt(d.db, ids)]);
        if ((rowsOf<{ n: number }>(checks, 0)[0]?.n ?? 0) >= GROUP_MAX) return err(409, "error.group.too_many");
        const have = new Set(rowsOf<{ id: string }>(checks, 1).map((r) => r.id));
        const missing = ids.filter((i) => !have.has(i));
        if (missing.length > 0) return err(409, "error.group.collection_not_found", { collection_ids: missing });
        const now = d.now();
        const row: Row = { id: mintGroupId(d.randomBytes), name, created_at: now, updated_at: now };
        const done = await d.db.batch([
            d.db
                .prepare("INSERT INTO collection_groups (id, name, key_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)")
                .bind(row.id, row.name, keyId, now),
            ...ids.map((c, i) =>
                // the first listed collection is the newest added: it shows first
                d.db
                    .prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES (?1, ?2, ?3)")
                    .bind(row.id, c, now + ids.length - i),
            ),
            membersStmt(d.db, row.id),
        ]);
        const [shape] = shaped([row], rowsOf<Member>(done, done.length - 1));
        return { status: 201, body: { status: "success", group: shape } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// PATCH: { name?, add?: [collection ids], remove?: [collection ids] }, at least one of them.
export async function updateGroup(d: GroupDeps, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request);
    if (!b) return err(400, "error.group.bad_request");
    const name = b.name === undefined ? undefined : cleanName(b.name);
    const add = collectionIds(b.add);
    const remove = collectionIds(b.remove);
    if (name === null || add === null || remove === null || (name === undefined && add.length === 0 && remove.length === 0)) {
        return err(400, "error.group.bad_request");
    }
    try {
        // two round trips: what is checked, then the writes with the answer read back behind them
        const checks = await readTogether(d.db, [
            oneStmt(d.db, id),
            existingStmt(d.db, add),
            d.db.prepare("SELECT COUNT(*) AS n FROM collection_group_items WHERE group_id = ?1").bind(id),
        ]);
        if (rowsOf<Row>(checks, 0).length === 0) return err(404, "error.group.not_found");
        const have = new Set(rowsOf<{ id: string }>(checks, 1).map((r) => r.id));
        const missing = add.filter((i) => !have.has(i));
        if (missing.length > 0) return err(409, "error.group.collection_not_found", { collection_ids: missing });
        if ((rowsOf<{ n: number }>(checks, 2)[0]?.n ?? 0) + add.length - remove.length > GROUP_COLLECTIONS_MAX) return err(409, "error.group.full");
        const now = d.now();
        const done = await d.db.batch([
            d.db.prepare("UPDATE collection_groups SET name = COALESCE(?2, name), updated_at = ?3 WHERE id = ?1").bind(id, name ?? null, now),
            ...remove.map((c) => d.db.prepare("DELETE FROM collection_group_items WHERE group_id = ?1 AND collection_id = ?2").bind(id, c)),
            ...add.map((c, i) =>
                d.db
                    .prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING")
                    .bind(id, c, now + add.length - i),
            ),
            oneStmt(d.db, id),
            membersStmt(d.db, id),
        ]);
        const [shape] = shaped([rowsOf<Row>(done, done.length - 2)[0]!], rowsOf<Member>(done, done.length - 1));
        return { status: 200, body: { status: "success", group: shape } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// Deletes the group only; its collections stay. Unknown id: 404 (already gone).
export async function deleteGroup(d: GroupDeps, id: string): Promise<StudioReply> {
    try {
        // one round trip: is there such a group, and the deletes, which change nothing for an unknown id
        const deletes = [
            d.db.prepare("DELETE FROM collection_group_items WHERE group_id = ?1").bind(id),
            d.db.prepare("DELETE FROM collection_groups WHERE id = ?1").bind(id),
        ];
        const done = await tryBatch(d.db, [oneStmt(d.db, id), ...deletes]);
        if (done) return rowsOf<Row>(done, 0).length > 0 ? { status: 200, body: { status: "success" } } : err(404, "error.group.not_found");
        // the batch failed, and nothing of it was applied: the read, then the deletes, as before
        if (!(await oneStmt(d.db, id).first<Row>())) return err(404, "error.group.not_found");
        await d.db.batch(deletes);
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}
