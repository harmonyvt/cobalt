// Collection sets (APP-API-CONTRACT.md section 28): named groups of share link collections (section 26),
// called "sets" in the app. Internally "CollectionGroup", because a "share set" is already a gallery link.
// Keyed routes only, D1 only. Deleting a group never deletes its collections; a deleted collection drops
// out of every group.

import { COLLECTION_ID_REGEX, COLLECTION_NAME_MAX, mintCollectionId } from "./share-collections";
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

// The existing collections among `ids`; the rest are answered as not found.
async function existing(db: D1Database, ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set();
    const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(`SELECT id FROM share_collections WHERE id IN (${marks})`)
        .bind(...ids)
        .all<{ id: string }>();
    return new Set(results.map((r) => r.id));
}

// Each group with its existing collections, newest added first.
async function shapes(db: D1Database, rows: Row[]) {
    if (rows.length === 0) return [];
    const marks = rows.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(
            `SELECT i.group_id, i.collection_id FROM collection_group_items i JOIN share_collections c ON c.id = i.collection_id
              WHERE i.group_id IN (${marks})
              ORDER BY i.added_at DESC, i.collection_id DESC`,
        )
        .bind(...rows.map((r) => r.id))
        .all<{ group_id: string; collection_id: string }>();
    const by = new Map<string, string[]>();
    for (const r of results) by.set(r.group_id, [...(by.get(r.group_id) ?? []), r.collection_id]);
    return rows.map((r) => ({
        id: r.id,
        name: r.name,
        created_at: r.created_at,
        updated_at: r.updated_at,
        collection_ids: by.get(r.id) ?? [],
    }));
}

async function one(db: D1Database, id: string): Promise<Row | null> {
    return (
        (await db.prepare("SELECT id, name, created_at, updated_at FROM collection_groups WHERE id = ?1").bind(id).first<Row>()) ?? null
    );
}

export async function listGroups(d: GroupDeps): Promise<StudioReply> {
    try {
        const { results } = await d.db
            .prepare(`SELECT id, name, created_at, updated_at FROM collection_groups ORDER BY updated_at DESC, id DESC LIMIT ${GROUP_MAX}`)
            .all<Row>();
        return { status: 200, body: { status: "success", groups: await shapes(d.db, results) } };
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
        const count = await d.db.prepare("SELECT COUNT(*) AS n FROM collection_groups").first<{ n: number }>();
        if ((count?.n ?? 0) >= GROUP_MAX) return err(409, "error.group.too_many");
        const have = await existing(d.db, ids);
        const missing = ids.filter((i) => !have.has(i));
        if (missing.length > 0) return err(409, "error.group.collection_not_found", { collection_ids: missing });
        const now = d.now();
        const row: Row = { id: mintGroupId(d.randomBytes), name, created_at: now, updated_at: now };
        await d.db.batch([
            d.db
                .prepare("INSERT INTO collection_groups (id, name, key_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)")
                .bind(row.id, row.name, keyId, now),
            ...ids.map((c, i) =>
                // the first listed collection is the newest added: it shows first
                d.db
                    .prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES (?1, ?2, ?3)")
                    .bind(row.id, c, now + ids.length - i),
            ),
        ]);
        const [shape] = await shapes(d.db, [row]);
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
        const row = await one(d.db, id);
        if (!row) return err(404, "error.group.not_found");
        const have = await existing(d.db, add);
        const missing = add.filter((i) => !have.has(i));
        if (missing.length > 0) return err(409, "error.group.collection_not_found", { collection_ids: missing });
        const count = await d.db
            .prepare("SELECT COUNT(*) AS n FROM collection_group_items WHERE group_id = ?1")
            .bind(id)
            .first<{ n: number }>();
        if ((count?.n ?? 0) + add.length - remove.length > GROUP_COLLECTIONS_MAX) return err(409, "error.group.full");
        const now = d.now();
        await d.db.batch([
            d.db.prepare("UPDATE collection_groups SET name = COALESCE(?2, name), updated_at = ?3 WHERE id = ?1").bind(id, name ?? null, now),
            ...remove.map((c) => d.db.prepare("DELETE FROM collection_group_items WHERE group_id = ?1 AND collection_id = ?2").bind(id, c)),
            ...add.map((c, i) =>
                d.db
                    .prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING")
                    .bind(id, c, now + add.length - i),
            ),
        ]);
        const [shape] = await shapes(d.db, [(await one(d.db, id))!]);
        return { status: 200, body: { status: "success", group: shape } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// Deletes the group only; its collections stay. Unknown id: 404 (already gone).
export async function deleteGroup(d: GroupDeps, id: string): Promise<StudioReply> {
    try {
        const row = await one(d.db, id);
        if (!row) return err(404, "error.group.not_found");
        await d.db.batch([
            d.db.prepare("DELETE FROM collection_group_items WHERE group_id = ?1").bind(id),
            d.db.prepare("DELETE FROM collection_groups WHERE id = ?1").bind(id),
        ]);
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}
