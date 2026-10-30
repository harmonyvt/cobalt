// Share link collections (APP-API-CONTRACT.md section 26): named folders of gallery links, created,
// listed, renamed, filled and deleted from the app's links tab. Keyed routes only, D1 only. Deleting a
// collection never revokes its links; a revoked link drops out of every collection.

import { writeCaption, setSubject, type Captioner } from "./roast";
import { linkInsert, liveLinksFor, revokeStmt } from "./private-links";
import { mintSetId, setRoastInput } from "./share-sets";
import type { StudioReply } from "./studio";

export const COLLECTION_NAME_MAX = 60;
export const COLLECTION_MAX = 100; // collections in all
export const COLLECTION_SETS_MAX = 200; // links in one collection
export const COLLECTION_ID_REGEX = /^[A-Za-z0-9]{16}$/;
const SET_ID = /^[0-9]{19}$/;

export type CollectionDeps = {
    db: D1Database;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    // reroll (section 26.1): fresh captions for the new links, waiting at most captionWaitMs in all
    mediaBaseUrl?: string;
    shareBaseUrl?: string;
    captioner?: Captioner | null;
    captionWaitMs?: number;
    setRandomBytes?: (n: number) => Uint8Array;
};

type Row = { id: string; name: string; created_at: number; updated_at: number };

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
export function mintCollectionId(rb: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
    let out = "";
    while (out.length < 16) {
        for (const b of rb(32)) {
            if (b >= 248) continue; // 248 = 4 * 62: keep it uniform
            out += ALPHABET[b % 62];
            if (out.length === 16) break;
        }
    }
    return out;
}

// Trimmed, no control characters, 1..60 code points; null = invalid.
function cleanName(v: unknown): string | null {
    if (typeof v !== "string") return null;
    // eslint-disable-next-line no-control-regex
    const t = v.replace(/[\u0000-\u001f\u007f]/g, "").trim();
    if (t === "" || Array.from(t).length > COLLECTION_NAME_MAX) return null;
    return t;
}

// A list of distinct gallery link ids (absent = []), or null when malformed.
function setIds(v: unknown): string[] | null {
    if (v === undefined) return [];
    if (!Array.isArray(v) || !v.every((x) => typeof x === "string" && SET_ID.test(x))) return null;
    const ids = [...new Set(v as string[])];
    return ids.length > COLLECTION_SETS_MAX ? null : ids;
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
    try {
        const b = await request.json();
        return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

// The live links among `ids`; the rest are answered as not found.
async function liveSets(db: D1Database, ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set();
    const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(`SELECT id FROM share_sets WHERE id IN (${marks}) AND revoked_at IS NULL`)
        .bind(...ids)
        .all<{ id: string }>();
    return new Set(results.map((r) => r.id));
}

// Each collection with its live links, newest added first.
async function shapes(db: D1Database, rows: Row[]) {
    if (rows.length === 0) return [];
    const marks = rows.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(
            `SELECT i.collection_id, i.set_id FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id
              WHERE i.collection_id IN (${marks}) AND s.revoked_at IS NULL
              ORDER BY i.added_at DESC, i.set_id DESC`,
        )
        .bind(...rows.map((r) => r.id))
        .all<{ collection_id: string; set_id: string }>();
    const by = new Map<string, string[]>();
    for (const r of results) by.set(r.collection_id, [...(by.get(r.collection_id) ?? []), r.set_id]);
    return rows.map((r) => ({ id: r.id, name: r.name, created_at: r.created_at, updated_at: r.updated_at, set_ids: by.get(r.id) ?? [] }));
}

async function one(db: D1Database, id: string): Promise<Row | null> {
    return (
        (await db.prepare("SELECT id, name, created_at, updated_at FROM share_collections WHERE id = ?1").bind(id).first<Row>()) ?? null
    );
}

export async function listCollections(d: CollectionDeps): Promise<StudioReply> {
    try {
        const { results } = await d.db
            .prepare(`SELECT id, name, created_at, updated_at FROM share_collections ORDER BY updated_at DESC, id DESC LIMIT ${COLLECTION_MAX}`)
            .all<Row>();
        return { status: 200, body: { status: "success", collections: await shapes(d.db, results) } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function createCollection(d: CollectionDeps, request: Request, keyId: string): Promise<StudioReply> {
    const b = await readBody(request);
    const name = cleanName(b?.name);
    const ids = setIds(b?.set_ids);
    if (!b || name === null || ids === null) return err(400, "error.collection.bad_request");
    try {
        const count = await d.db.prepare("SELECT COUNT(*) AS n FROM share_collections").first<{ n: number }>();
        if ((count?.n ?? 0) >= COLLECTION_MAX) return err(409, "error.collection.too_many");
        const live = await liveSets(d.db, ids);
        const missing = ids.filter((i) => !live.has(i));
        if (missing.length > 0) return err(409, "error.collection.link_not_found", { set_ids: missing });
        const now = d.now();
        const row: Row = { id: mintCollectionId(d.randomBytes), name, created_at: now, updated_at: now };
        await d.db.batch([
            d.db
                .prepare("INSERT INTO share_collections (id, name, key_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)")
                .bind(row.id, row.name, keyId, now),
            ...ids.map((s, i) =>
                // the first listed link is the newest added: it shows first
                d.db.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?1, ?2, ?3)").bind(row.id, s, now + ids.length - i),
            ),
        ]);
        const [shape] = await shapes(d.db, [row]);
        return { status: 201, body: { status: "success", collection: shape } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// PATCH: { name?, add?: [set ids], remove?: [set ids] }, at least one of them.
export async function updateCollection(d: CollectionDeps, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request);
    if (!b) return err(400, "error.collection.bad_request");
    const name = b.name === undefined ? undefined : cleanName(b.name);
    const add = setIds(b.add);
    const remove = setIds(b.remove);
    if (name === null || add === null || remove === null || (name === undefined && add.length === 0 && remove.length === 0)) {
        return err(400, "error.collection.bad_request");
    }
    try {
        const row = await one(d.db, id);
        if (!row) return err(404, "error.collection.not_found");
        const live = await liveSets(d.db, add);
        const missing = add.filter((i) => !live.has(i));
        if (missing.length > 0) return err(409, "error.collection.link_not_found", { set_ids: missing });
        const have = await d.db
            .prepare("SELECT COUNT(*) AS n FROM share_collection_items WHERE collection_id = ?1")
            .bind(id)
            .first<{ n: number }>();
        if ((have?.n ?? 0) + add.length - remove.length > COLLECTION_SETS_MAX) return err(409, "error.collection.full");
        const now = d.now();
        await d.db.batch([
            d.db.prepare("UPDATE share_collections SET name = COALESCE(?2, name), updated_at = ?3 WHERE id = ?1").bind(id, name ?? null, now),
            ...remove.map((s) => d.db.prepare("DELETE FROM share_collection_items WHERE collection_id = ?1 AND set_id = ?2").bind(id, s)),
            ...add.map((s, i) =>
                d.db
                    .prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING")
                    .bind(id, s, now + add.length - i),
            ),
        ]);
        const [shape] = await shapes(d.db, [(await one(d.db, id))!]);
        return { status: 200, body: { status: "success", collection: shape } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// Deletes the folder only; its links stay live. Unknown id: 404 (already gone).
export async function deleteCollection(d: CollectionDeps, id: string): Promise<StudioReply> {
    try {
        const row = await one(d.db, id);
        if (!row) return err(404, "error.collection.not_found");
        await d.db.batch([
            d.db.prepare("DELETE FROM share_collection_items WHERE collection_id = ?1").bind(id),
            d.db.prepare("DELETE FROM share_collections WHERE id = ?1").bind(id),
        ]);
        // it leaves every collection set (section 28); best effort, the group listing joins on share_collections
        await d.db
            .prepare("DELETE FROM collection_group_items WHERE collection_id = ?1")
            .bind(id)
            .run()
            .catch(() => undefined);
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// POST /share/collections/<id>/reroll: every live link in the collection gets a new URL (a new share set
// with the same files and no typed title, so its title is a fresh caption), and the old URL is revoked.
// Every collection holding an old link holds the new one instead, in the same place. Captions for the new
// links are written now (bounded wait); the 15-minute cron fills any miss.
export const REROLL_CAPTION_WAIT_MS = 8000;

export async function rerollCollection(d: CollectionDeps, id: string, keyId: string): Promise<StudioReply> {
    try {
        const row = await one(d.db, id);
        if (!row) return err(404, "error.collection.not_found");
        const [shape] = await shapes(d.db, [row]);
        const old = shape!.set_ids;
        if (old.length === 0) return err(409, "error.collection.empty");
        const marks = old.map((_, i) => `?${i + 1}`).join(", ");
        const { results: sets } = await d.db
            .prepare(`SELECT id, items FROM share_sets WHERE id IN (${marks}) AND revoked_at IS NULL`)
            .bind(...old)
            .all<{ id: string; items: string }>();
        const now = d.now();
        const replaced: Record<string, string> = {};
        const stmts: D1PreparedStatement[] = [];
        // a private link stays private (section 36): its key is revoked with it and the new link gets a new one
        const priv = await liveLinksFor(d.db, "set", sets.map((s) => s.id));
        for (const s of sets) {
            const fresh = mintSetId(d.setRandomBytes);
            replaced[s.id] = fresh;
            stmts.push(
                d.db.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at) VALUES (?1, ?2, NULL, ?3, ?4)").bind(fresh, s.items, keyId, now),
                d.db.prepare("UPDATE share_sets SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL").bind(s.id, now),
                d.db.prepare("UPDATE share_collection_items SET set_id = ?2 WHERE set_id = ?1").bind(s.id, fresh),
            );
            if (priv.has(s.id)) stmts.push(revokeStmt(d.db, "set", s.id, now), linkInsert(d.db, "set", fresh, now).stmt);
        }
        stmts.push(d.db.prepare("UPDATE share_collections SET updated_at = ?2 WHERE id = ?1").bind(id, now));
        await d.db.batch(stmts);

        if (d.captioner && d.mediaBaseUrl) {
            const captioner = d.captioner;
            const media = d.mediaBaseUrl;
            const work = Promise.all(
                Object.values(replaced).map(async (sid) => {
                    const input = await setRoastInput({ db: d.db, mediaBaseUrl: media }, sid).catch(() => null);
                    if (input) await writeCaption({ db: d.db, captioner, now: d.now }, setSubject(sid), input);
                }),
            );
            await Promise.race([work, new Promise((r) => setTimeout(r, d.captionWaitMs ?? REROLL_CAPTION_WAIT_MS))]);
        }
        const [after] = await shapes(d.db, [(await one(d.db, id))!]);
        return { status: 200, body: { status: "success", collection: after, replaced } };
    } catch (e) {
        console.error("[collections] reroll failed", String(e));
        return err(503, "error.api.generic");
    }
}
