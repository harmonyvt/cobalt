// What the private link routes and the chat's link calls do (APP-API-CONTRACT.md section 36.3, 36.5): turn a file's or
// a gallery link's private link on or off, rotate one or all, list them, and a collection's links all at once. Each
// answers a StudioReply (status + body) so the HTTP routes return it as is and the chat unwraps it.
//
// Until migration 0024 is applied every call here answers 503 error.api.generic and changes nothing (requireTables runs
// before anything else, so a file is never made private for a link that cannot be stored).
// Free of Cloudflare imports (the tests run it under node).
import {
    allLiveLinks,
    ensureLink,
    isMissingTable,
    linkShape,
    liveLink,
    liveLinksFor,
    newLinksSetting,
    revokeLink,
    rotateAllLinks,
    rotateLink,
    setNewLinks,
    type NewLinks,
    type PrivateKind,
    type PrivateLinkRow,
} from "./private-links";
import { liveSetRow } from "./share-sets";
import type { StudioReply } from "./studio";
import { getRow, setVisibility, toggleable, type VisDeps } from "./visibility";

export type PrivateDeps = {
    db: D1Database;
    // the file toggle's deps (section 16): turning a file's link on makes the file not public first
    vis: VisDeps;
    shareBaseUrl: string;
    now: () => number;
    keyId: string;
    keyBytes?: (n: number) => Uint8Array;
};

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});
const generic = () => err(503, "error.api.generic");
const success = (body: Record<string, unknown> = {}): StudioReply => ({ status: 200, body: { status: "success", ...body } });

// Throws (a 503 for the caller) while migration 0024 is not applied.
async function requireTables(db: D1Database): Promise<void> {
    await db.prepare("SELECT 1 FROM private_links LIMIT 1").all();
    await db.prepare("SELECT 1 FROM share_settings LIMIT 1").all();
}

// Any failure (the tables missing, D1 down) is a 503; a refusal is answered by `run` itself.
async function guarded(db: D1Database, run: () => Promise<StudioReply>): Promise<StudioReply> {
    try {
        await requireTables(db);
        return await run();
    } catch (e) {
        if (!isMissingTable(e)) console.error("[private] call failed", String(e));
        return generic();
    }
}

const shape = (d: PrivateDeps, r: PrivateLinkRow) => linkShape(r, d.shareBaseUrl);

// GET /share/private: every live link, newest first, and the new_links setting. Before 0024: none, "public".
export async function listPrivate(d: PrivateDeps): Promise<StudioReply> {
    try {
        const links = await allLiveLinks(d.db);
        return success({ links: links.map((l) => shape(d, l)), new_links: await newLinksSetting(d.db) });
    } catch (e) {
        if (isMissingTable(e)) return success({ links: [], new_links: "public" });
        console.error("[private] list failed", String(e));
        return generic();
    }
}

// PUT /share/private/items/<id>: the file's private link, on. A public file is made not public first (section 16 OFF:
// its public copy is deleted, the media URL and its share page are 404s). Already on: the same link.
export function itemOn(d: PrivateDeps, id: string): Promise<StudioReply> {
    return guarded(d.db, async () => {
        // the file's own id, or the public id old apps know
        const row = await getRow(d.db, id);
        if (!row) return err(404, "error.private.not_found");
        if (!toggleable(row)) return err(409, "error.private.not_toggleable");
        const off = await setVisibility(d.vis, row.id, false, d.keyId);
        if (off.status !== 200) {
            const code = (off.body as { error?: { code?: string } }).error?.code ?? "error.api.generic";
            if (off.status === 404) return err(404, "error.private.not_found");
            if (off.status === 409) return err(409, "error.private.not_toggleable");
            return err(off.status, code);
        }
        const link = await ensureLink(d.db, "item", row.id, d.now(), d.keyBytes);
        return success({ link: shape(d, link) });
    });
}

// PUT /share/private/sets/<id>: a live gallery link's private link, on (its /g/<id> is a 404 from now on).
export function setOn(d: PrivateDeps, id: string): Promise<StudioReply> {
    return guarded(d.db, async () => {
        if (!(await liveSetRow(d.db, id))) return err(404, "error.private.not_found");
        const link = await ensureLink(d.db, "set", id, d.now(), d.keyBytes);
        return success({ link: shape(d, link) });
    });
}

// The target id a route names: a file's own id (a public id resolves to it), a gallery link's id as is.
async function targetOf(d: PrivateDeps, kind: PrivateKind, id: string): Promise<string> {
    if (kind === "set") return id;
    const row = await getRow(d.db, id);
    return row?.id ?? id;
}

// DELETE /share/private/items|sets/<id>: revoked. A file stays not public; a gallery link is public again. None: 200.
export function linkOff(d: PrivateDeps, kind: PrivateKind, id: string): Promise<StudioReply> {
    return guarded(d.db, async () => {
        await revokeLink(d.db, kind, await targetOf(d, kind, id), d.now());
        return success();
    });
}

// POST /share/private/items|sets/<id>/rotate: a new key, the old one a 404 at once.
export function linkRotate(d: PrivateDeps, kind: PrivateKind, id: string): Promise<StudioReply> {
    return guarded(d.db, async () => {
        const link = await rotateLink(d.db, kind, await targetOf(d, kind, id), d.now(), d.keyBytes);
        return link ? success({ link: shape(d, link) }) : err(404, "error.private.not_found");
    });
}

// POST /share/private/rotate-all: every live key rotated in one batch.
export function rotateEvery(d: PrivateDeps): Promise<StudioReply> {
    return guarded(d.db, async () => {
        const links = await rotateAllLinks(d.db, d.now(), d.keyBytes);
        return success({ links: links.map((l) => shape(d, l)), rotated: links.length });
    });
}

// PATCH /share/private/settings
export function setNewLinksSetting(d: PrivateDeps, value: NewLinks): Promise<StudioReply> {
    return guarded(d.db, async () => {
        await setNewLinks(d.db, value, d.now());
        return success({ new_links: value });
    });
}

export type CollectionPrivacy = { private: boolean } | { rotate: true };

// POST /share/collections/<id>/privacy: every live gallery link in the collection made private, public again, or
// rotated. Answers the collection's live private links afterwards, in the collection's order.
export function collectionPrivacy(d: PrivateDeps, collectionId: string, what: CollectionPrivacy): Promise<StudioReply> {
    return guarded(d.db, async () => {
        const c = await d.db.prepare("SELECT id FROM share_collections WHERE id = ?1").bind(collectionId).first<{ id: string }>();
        if (!c) return err(404, "error.collection.not_found");
        const { results } = await d.db
            .prepare(
                `SELECT i.set_id FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id
                  WHERE i.collection_id = ?1 AND s.revoked_at IS NULL ORDER BY i.added_at DESC, i.set_id DESC`,
            )
            .bind(collectionId)
            .all<{ set_id: string }>();
        const ids = results.map((r) => r.set_id);
        const now = d.now();
        for (const id of ids) {
            if ("rotate" in what) await rotateLink(d.db, "set", id, now, d.keyBytes);
            else if (what.private) await ensureLink(d.db, "set", id, now, d.keyBytes);
            else await revokeLink(d.db, "set", id, now);
        }
        const live = await liveLinksFor(d.db, "set", ids);
        return success({ links: ids.filter((id) => live.has(id)).map((id) => shape(d, live.get(id)!)) });
    });
}

// The live link of one target (the chat's answers), or null.
export async function currentLink(d: PrivateDeps, kind: PrivateKind, id: string): Promise<ReturnType<typeof linkShape> | null> {
    try {
        const r = await liveLink(d.db, kind, await targetOf(d, kind, id));
        return r ? shape(d, r) : null;
    } catch (e) {
        if (isMissingTable(e)) return null;
        throw e;
    }
}
