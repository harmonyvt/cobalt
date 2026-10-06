// One file per rendition, public or private (apple/CONTRACT-VISIBILITY.md, APP-API-CONTRACT.md
// section 16). A library row IS the media file: the canonical bytes stay where they were first
// stored (an original in R2 `cobalt-originals`), "public" is a mirror object in `cobalt-media` at
// the row's stable `public_key`, owned by the same row. This module holds everything that decides
// or changes that: the toggle (on / off / reconcile), the lazy and the bulk merge of the old
// "private original + public host copy" pairs, undo, the file shapes both list formats use, and the
// edge-cache purge. Free of Cloudflare imports so it runs under plain node in the tests.
//
// Order is privacy-first everywhere: OFF deletes the public object before the row says private (a
// failed delete leaves a truthful "public"); ON copies before the row says public (never a public
// row with no file). Every toggle ends with one reconcile pass so racing on/off calls converge.
//
// Webps (owner, 2026-10-05) are switchable too. A webp's bytes live only in the public bucket, so
// the first OFF moves its canonical copy: it is copied to `cobalt-originals/webps/<name>` (verified
// with head), the row becomes a bucket 'originals' row whose `public_key` is its old public name,
// and from there it is toggled like any original. ON copies back to the SAME name (old links come
// back); the private copy is KEPT (later toggles cost one copy, and a delete removes both).

import { MEDIA_NAME_REGEX } from "./gate";
import { randomBase62 } from "./ids";
import { SERVICE_KEY_ID, mintItemId, pageLink } from "./library";
import type { PublishBucket } from "./publish";
import type { OriginalsBucket, StudioReply } from "./studio";
import { MEDIA_NAME_LENGTH } from "./webp";

// ---- deps ---------------------------------------------------------------------------------------

// Purges edge-cached copies of these URLs. true = cleared, false = the API call failed.
// Absent (not configured) is reported as null by the callers.
export type PurgeFn = (urls: string[]) => Promise<boolean | null>;

export type VisDeps = {
    db: D1Database;
    originals: OriginalsBucket;
    media: PublishBucket;
    // https://media.../ (with or without the slash)
    mediaBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    purge?: PurgeFn;
};

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });

// ---- rows ---------------------------------------------------------------------------------------

export type MediaRow = {
    id: string;
    kind: string;
    source: string;
    bucket: string;
    r2_key: string;
    url: string | null;
    name: string;
    content_type: string | null;
    bytes: number | null;
    width: number | null;
    height: number | null;
    duration: number | null;
    link: string | null;
    session_id: string | null;
    key_id: string | null;
    created_at: number;
    deleted_at: number | null;
    // migration 0006 (section 13)
    poster: string | null;
    poster_at: number | null;
    // migration 0008 (section 16)
    visibility: string | null;
    public_key: string | null;
    public_id: string | null;
    merged_into: string | null;
    // migration 0009 (section 18): a gallery item or a made file has a role; a row with one is never a webp rendition
    role?: string | null;
};

export const ITEM_COLUMNS =
    "id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, poster_at, visibility, public_key, public_id, merged_into, role";

// The SQL form of effectiveVisibility(), for a table alias (`m.`) or none.
export const visSql = (alias = "") =>
    `COALESCE(${alias}visibility, CASE ${alias}bucket WHEN 'media' THEN 'public' ELSE 'private' END)`;

// A row not migrated yet (visibility NULL) reads as: bucket 'media' -> public, else private.
export const effectiveVisibility = (r: Pick<MediaRow, "visibility" | "bucket">): "public" | "private" =>
    r.visibility === "public" || r.visibility === "private" ? r.visibility : r.bucket === "media" ? "public" : "private";

export const isWebpSource = (source: string) => source === "webp" || source === "studio";
// A saved link or an upload: the rows old clients know as "private file" + "public copy".
export const isOriginalSource = (source: string) => source === "saved" || source === "upload";

// May the owner flip this row? Originals (including a webp already switched private once), and a
// webp still living in the public bucket. Never a legacy host copy, never a poster.
export const toggleable = (r: Pick<MediaRow, "bucket" | "source" | "r2_key">): boolean =>
    r.bucket === "originals" || (r.bucket === "media" && isWebpSource(r.source) && MEDIA_NAME_REGEX.test(r.r2_key));

export const extOf = (key: string): string => /\.([0-9A-Za-z]{1,8})$/.exec(key)?.[1]?.toLowerCase() ?? "bin";

// Private-bucket key of a webp switched private: webps/<its public name>.
export const privateWebpKey = (name: string) => `webps/${name}`;

// The public name a webp row is known by (DELETE /media/<name>.webp), whichever bucket holds its bytes.
// A row with a role (a slideshow webp's mirror name looks like one) is a made file with its own delete route: never a webp.
export const webpName = (r: Pick<MediaRow, "bucket" | "source" | "r2_key" | "public_key"> & { role?: string | null }): string | null => {
    if (!isWebpSource(r.source) || r.role) return null;
    const n = r.bucket === "media" ? r.r2_key : r.public_key;
    return n && MEDIA_NAME_REGEX.test(n) ? n : null;
};

// One file as every client sees it (the web Worker's itemShape, plus section 16's keys).
// `url` is the public URL while public, else null.
export const itemShape = (r: MediaRow) => {
    const wn = webpName(r);
    return {
        id: r.id,
        kind: r.kind,
        source: r.source,
        name: r.name,
        url: r.url,
        content_type: r.content_type,
        bytes: r.bytes,
        width: r.width,
        height: r.height,
        duration: r.duration,
        link: r.link,
        session_id: r.session_id,
        created_at: r.created_at,
        // the server-made thumbnail (null until the container has cut it)
        poster_url: r.poster ?? null,
        visibility: effectiveVisibility(r),
        visibility_toggle: toggleable(r),
        media_name: wn ?? (r.bucket === "media" ? r.r2_key : null),
        deletable: wn !== null,
    };
};

export async function getRow(db: D1Database, id: string): Promise<MediaRow | null> {
    return (
        (await db
            .prepare(
                `SELECT ${ITEM_COLUMNS} FROM media_items WHERE (id = ?1 OR public_id = ?1) AND deleted_at IS NULL ORDER BY (id = ?1) DESC LIMIT 1`,
            )
            .bind(id)
            .first<MediaRow>()) ?? null
    );
}

// The live original row of a stored object (a session's r2_key).
export async function getOriginalByKey(db: D1Database, r2Key: string): Promise<MediaRow | null> {
    return (
        (await db
            .prepare(
                `SELECT ${ITEM_COLUMNS} FROM media_items WHERE bucket = 'originals' AND r2_key = ?1 AND deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1`,
            )
            .bind(r2Key)
            .first<MediaRow>()) ?? null
    );
}

// What a studio session reports of its original (section 16): `item_id` and `visibility`.
export async function sessionItem(
    db: D1Database,
    r2Key: string | null | undefined,
): Promise<{ item_id: string; visibility: "public" | "private" } | null> {
    if (!r2Key) return null;
    try {
        const r = await getOriginalByKey(db, r2Key);
        return r ? { item_id: r.id, visibility: effectiveVisibility(r) } : null;
    } catch {
        return null;
    }
}

// ---- edge cache purge ---------------------------------------------------------------------------

export const PURGE_TIMEOUT_MS = 3000;
export const PURGE_BATCH = 30; // Cloudflare's per-call URL limit

// POST /zones/<MEDIA_ZONE_ID>/purge_cache {"files":[url]} with MEDIA_PURGE_TOKEN. Undefined when
// either is absent or empty (the toggle still works and reports `cache_cleared: null`).
export function purgeFrom(
    env: { MEDIA_PURGE_TOKEN?: string; MEDIA_ZONE_ID?: string },
    fetchImpl: typeof fetch = (...a) => fetch(...a),
): PurgeFn | undefined {
    const token = env.MEDIA_PURGE_TOKEN?.trim();
    const zone = env.MEDIA_ZONE_ID?.trim();
    if (!token || !zone || !/^[0-9a-f]{32}$/i.test(zone)) return undefined;
    return async (urls) => {
        if (urls.length === 0) return null;
        let all = true;
        for (let i = 0; i < urls.length; i += PURGE_BATCH) {
            const chunk = urls.slice(i, i + PURGE_BATCH);
            let timer: ReturnType<typeof setTimeout> | undefined;
            try {
                const call = (async () => {
                    const res = await fetchImpl(`https://api.cloudflare.com/client/v4/zones/${zone}/purge_cache`, {
                        method: "POST",
                        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
                        body: JSON.stringify({ files: chunk }),
                    });
                    const body = (await res.json().catch(() => null)) as { success?: unknown } | null;
                    return res.ok && body?.success === true;
                })();
                const timeout = new Promise<boolean>((resolve) => {
                    timer = setTimeout(() => resolve(false), PURGE_TIMEOUT_MS);
                });
                if (!(await Promise.race([call, timeout]))) all = false;
            } catch {
                all = false;
            } finally {
                if (timer !== undefined) clearTimeout(timer);
            }
        }
        return all;
    };
}

// Best effort, never throws: null = not configured / nothing to purge, false = the call failed.
export async function purgeUrls(d: Pick<VisDeps, "purge">, urls: string[]): Promise<boolean | null> {
    const list = [...new Set(urls.filter(Boolean))];
    if (!d.purge || list.length === 0) return null;
    try {
        return await d.purge(list);
    } catch {
        return false;
    }
}

// ---- the toggle ---------------------------------------------------------------------------------

const publicUrlOf = (d: Pick<VisDeps, "mediaBaseUrl">, key: string) => withSlash(d.mediaBaseUrl) + key;

type Step<T = MediaRow> = { ok: true; row: T } | { ok: false; reply: StudioReply };
const fail = (status: number, code: string): { ok: false; reply: StudioReply } => ({ ok: false, reply: err(status, code) });

// Copies an object's own body into the other bucket (no buffering, no FixedLengthStream: the R2 object
// body has a known length, and ReadableStream.pipeTo() between streams is not implemented in the
// Workers runtime, so the body is handed to put() as it is, like publish has since 2026-10-01).
async function mirrorOut(d: VisDeps, row: MediaRow, key: string, keyId: string): Promise<Step<string>> {
    let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
    try {
        obj = await d.originals.get(row.r2_key);
    } catch (e) {
        console.error("[visibility] original get failed", row.id, String(e));
        return fail(502, "error.library.storage");
    }
    if (!obj) return fail(404, "error.library.missing");
    const contentType = row.content_type ?? obj.httpMetadata?.contentType ?? "application/octet-stream";
    let stored: { size: number } | null;
    try {
        stored = await d.media.put(key, obj.body, {
            httpMetadata: { contentType, cacheControl: "public, max-age=3600" },
            customMetadata: {
                mirror: "1",
                published: "1",
                itemId: row.id,
                ...(row.session_id ? { sessionId: row.session_id } : {}),
                keyId,
                createdAt: String(d.now()),
                source: (pageLink(row.link) ?? "").slice(0, 1000),
            },
        });
    } catch (e) {
        console.error("[visibility] mirror copy failed", row.id, String(e));
        await obj.body.cancel().catch(() => {});
        return fail(502, "error.library.storage");
    }
    // the copy must be as long as the object it came from, or it is not a copy
    if (stored && stored.size !== obj.size) {
        console.error("[visibility] mirror copy has the wrong length", row.id, stored.size, obj.size);
        await d.media.delete(key).catch(() => {});
        return fail(502, "error.library.storage");
    }
    return { ok: true, row: contentType };
}

// A webp's first OFF: its canonical bytes move to the private bucket. Verified with head before the
// row changes; until the row changes nothing visible has changed (a failed or interrupted run leaves
// an unreferenced private object that the retry overwrites).
async function convertWebp(d: VisDeps, row: MediaRow, keyId: string): Promise<Step> {
    const name = row.r2_key;
    const privKey = privateWebpKey(name);
    let src: Awaited<ReturnType<PublishBucket["get"]>>;
    try {
        src = await d.media.get(name);
    } catch (e) {
        console.error("[visibility] webp read failed", row.id, String(e));
        return fail(502, "error.library.storage");
    }
    if (!src) return fail(404, "error.library.missing");
    try {
        await d.originals.put(privKey, src.body, {
            httpMetadata: { contentType: row.content_type ?? src.httpMetadata?.contentType ?? "image/webp" },
            customMetadata: { keyId, source: "webp-private", itemId: row.id, createdAt: String(d.now()) },
        });
    } catch (e) {
        console.error("[visibility] webp private copy failed", row.id, String(e));
        await src.body.cancel().catch(() => {});
        return fail(502, "error.library.storage");
    }
    try {
        const head = await d.originals.head(privKey);
        if (!head || head.size !== src.size) {
            await d.originals.delete(privKey).catch(() => {});
            return fail(502, "error.library.storage");
        }
    } catch (e) {
        console.error("[visibility] webp private copy check failed", row.id, String(e));
        return fail(502, "error.library.storage");
    }
    try {
        // public_key = the old name; visibility stays public until the OFF below deletes the public object
        const res = await d.db
            .prepare(
                "UPDATE media_items SET bucket = 'originals', r2_key = ?1, public_key = ?2, visibility = 'public' WHERE id = ?3 AND bucket = 'media' AND deleted_at IS NULL",
            )
            .bind(privKey, name, row.id)
            .run();
        if (Number(res.meta?.changes ?? 0) === 0) {
            await d.originals.delete(privKey).catch(() => {});
            return fail(404, "error.library.not_found");
        }
        return { ok: true, row: { ...row, bucket: "originals", r2_key: privKey, public_key: name, visibility: "public" } };
    } catch (e) {
        console.error("[visibility] webp convert row failed", row.id, String(e));
        return fail(503, "error.api.generic");
    }
}

async function syncSessions(d: VisDeps, row: Pick<MediaRow, "source" | "r2_key">, url: string | null): Promise<void> {
    if (!isOriginalSource(row.source)) return;
    try {
        await d.db
            .prepare("UPDATE studio_sessions SET public_state = ?1, public_url = ?2 WHERE r2_key = ?3")
            .bind(url ? "ready" : null, url, row.r2_key)
            .run();
    } catch (e) {
        console.error("[visibility] session sync failed", row.r2_key, String(e));
    }
}

// ON: the mirror exists at public_key (the same name every time) before the row says public.
export async function makePublic(d: VisDeps, row: MediaRow, keyId: string = SERVICE_KEY_ID): Promise<Step> {
    // a webp that never left the public bucket is already public
    if (row.bucket === "media") return { ok: true, row };

    const fresh = !row.public_key;
    const key = row.public_key ?? `${randomBase62(MEDIA_NAME_LENGTH, d.randomBytes)}.${extOf(row.r2_key)}`;
    const pid = isOriginalSource(row.source) ? (row.public_id ?? mintItemId(d.randomBytes)) : null;
    const url = publicUrlOf(d, key);

    let have: { size: number } | null;
    try {
        have = await d.media.head(key);
    } catch (e) {
        console.error("[visibility] mirror head failed", row.id, String(e));
        return fail(502, "error.library.storage");
    }
    let learnedType: string | null = null;
    if (!have || (typeof row.bytes === "number" && have.size !== row.bytes)) {
        const copied = await mirrorOut(d, row, key, keyId);
        if (!copied.ok) return copied;
        if (!row.content_type) learnedType = copied.row;
    }

    try {
        const res = await d.db
            .prepare(
                "UPDATE media_items SET visibility = 'public', public_key = ?1, public_id = COALESCE(public_id, ?2), url = ?3, content_type = COALESCE(content_type, ?5) WHERE id = ?4 AND deleted_at IS NULL",
            )
            .bind(key, pid, url, row.id, learnedType)
            .run();
        if (Number(res.meta?.changes ?? 0) === 0) {
            // deleted while we copied: do not leave a public object nothing points at
            await d.media.delete(key).catch(() => {});
            return fail(404, "error.library.not_found");
        }
    } catch (e) {
        console.error("[visibility] publish row failed", row.id, String(e));
        if (fresh) await d.media.delete(key).catch(() => {});
        return fail(503, "error.api.generic");
    }
    await syncSessions(d, row, url);
    await purgeUrls(d, [url]); // clears a cached 404 from an earlier OFF
    return {
        ok: true,
        row: { ...row, visibility: "public", public_key: key, public_id: row.public_id ?? pid, url, content_type: row.content_type ?? learnedType },
    };
}

// OFF: the public object is deleted before the row says private (a failed delete leaves a truthful
// "public"); the edge copy is purged afterwards. `cleared` is the purge's answer.
export async function makePrivate(d: VisDeps, row: MediaRow, keyId: string = SERVICE_KEY_ID): Promise<Step<MediaRow> & { cleared?: boolean | null }> {
    let r = row;
    if (r.bucket === "media") {
        // a webp's first OFF: the canonical copy moves to the private bucket first
        const moved = await convertWebp(d, r, keyId);
        if (!moved.ok) return moved;
        r = moved.row;
    }
    if (!r.public_key || effectiveVisibility(r) === "private") {
        // private already (never public, or off earlier): no delete, no purge. A stray object is the
        // closing reconcile pass's to remove.
        return { ok: true, row: r, cleared: null };
    }
    const oldUrl = r.url ?? publicUrlOf(d, r.public_key);
    try {
        await d.media.delete(r.public_key);
    } catch (e) {
        console.error("[visibility] mirror delete failed", r.id, String(e));
        return fail(502, "error.library.storage");
    }
    try {
        await d.db
            .prepare("UPDATE media_items SET visibility = 'private', url = NULL WHERE id = ?1 AND deleted_at IS NULL")
            .bind(r.id)
            .run();
    } catch (e) {
        console.error("[visibility] private row failed", r.id, String(e));
        return fail(503, "error.api.generic");
    }
    await syncSessions(d, r, null);
    const cleared = await purgeUrls(d, [oldUrl]);
    return { ok: true, row: { ...r, visibility: "private", url: null }, cleared };
}

// One pass after a toggle: the object must match the row (public with no object -> copy once more;
// private with an object -> delete once more), so racing on/off calls converge on the row.
async function reconcile(d: VisDeps, id: string, keyId: string): Promise<void> {
    try {
        const r = await getRow(d.db, id);
        if (!r || r.bucket !== "originals" || !r.public_key) return;
        const have = await d.media.head(r.public_key);
        if (effectiveVisibility(r) === "public") {
            if (!have) await makePublic(d, r, keyId);
        } else if (have) {
            const url = r.url ?? publicUrlOf(d, r.public_key);
            await d.media.delete(r.public_key);
            await purgeUrls(d, [url]);
        }
    } catch (e) {
        console.error("[visibility] reconcile failed", id, String(e));
    }
}

// PATCH /library/items/<id>/visibility
export async function setVisibility(
    d: VisDeps,
    id: string,
    wantPublic: boolean,
    keyId: string = SERVICE_KEY_ID,
): Promise<StudioReply> {
    let row: MediaRow | null;
    try {
        row = await getRow(d.db, id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return err(404, "error.library.not_found");
    if (!toggleable(row)) return err(409, "error.library.not_toggleable");

    try {
        row = await lazyMerge(d, row);
    } catch (e) {
        console.error("[visibility] lazy merge failed", row.id, String(e));
        return err(503, "error.api.generic");
    }

    let cacheCleared: boolean | null = null;
    if (wantPublic) {
        const r = await makePublic(d, row, keyId);
        if (!r.ok) return r.reply;
    } else {
        const r = await makePrivate(d, row, keyId);
        if (!r.ok) return r.reply;
        cacheCleared = r.cleared ?? null;
    }
    await reconcile(d, row.id, keyId);

    let fresh: MediaRow | null;
    try {
        fresh = await getRow(d.db, row.id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!fresh) return err(404, "error.library.not_found");
    return { status: 200, body: { status: "success", item: itemShape(fresh), cache_cleared: cacheCleared } };
}

// The legacy "make public" answer (POST /library/items/<id>/publish, POST /studio/<sid>/publish, and
// `public: true` at save): the same 201 shape as before, the same link on a repeat.
export async function publishOriginal(d: VisDeps, row: MediaRow, keyId: string = SERVICE_KEY_ID): Promise<StudioReply> {
    let r = row;
    try {
        r = await lazyMerge(d, r);
    } catch (e) {
        console.error("[visibility] lazy merge failed", r.id, String(e));
        return err(503, "error.api.generic");
    }
    const on = await makePublic(d, r, keyId);
    if (!on.ok) return on.reply;
    await reconcile(d, r.id, keyId);
    let fresh: MediaRow | null = null;
    try {
        fresh = await getRow(d.db, r.id);
    } catch {
        // answer from what we know
    }
    const out = fresh ?? on.row;
    if (!out.url) return err(503, "error.api.generic");
    return {
        status: 201,
        body: {
            status: "success",
            url: out.url,
            bytes: out.bytes ?? 0,
            content_type: out.content_type ?? "application/octet-stream",
            item_id: out.public_id ?? out.id,
        },
    };
}

// DELETE /media/<name>.webp for a webp that was switched private once (its bytes are in the private
// bucket now): both copies go, the row is marked deleted, the URL is purged. null = not such a row
// (the caller forwards to the webp service as before).
export async function deleteSwitchedWebp(d: VisDeps, name: string): Promise<StudioReply | null> {
    let row: MediaRow | null;
    try {
        row = await d.db
            .prepare(
                `SELECT ${ITEM_COLUMNS} FROM media_items WHERE bucket = 'originals' AND public_key = ?1 AND source IN ('webp', 'studio') AND role IS NULL AND deleted_at IS NULL LIMIT 1`,
            )
            .bind(name)
            .first<MediaRow>();
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return null;
    try {
        await d.media.delete(name);
        await d.originals.delete(row.r2_key);
        await d.db
            .prepare("UPDATE media_items SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL")
            .bind(d.now(), row.id)
            .run();
    } catch (e) {
        console.error("[visibility] switched webp delete failed", row.id, String(e));
        return err(502, "error.webp.storage");
    }
    await purgeUrls(d, [row.url ?? publicUrlOf(d, name)]);
    return { status: 200, body: { status: "success" } };
}

// ---- merge: the old pairs become one row ---------------------------------------------------------

export type Candidate = {
    host_id: string;
    host_key: string;
    host_url: string | null;
    host_bytes: number | null;
    host_poster: string | null;
    orig_id: string | null;
    orig_key: string | null;
    orig_bytes: number | null;
    orig_source: string | null;
    orig_public_key: string | null;
};

// Section 4.3: the same query drives the dry run, the apply and the toggle's lazy merge.
export const CANDIDATES_SQL = `SELECT h.id AS host_id, h.r2_key AS host_key, h.url AS host_url, h.bytes AS host_bytes, h.poster AS host_poster,
       o.id AS orig_id, o.r2_key AS orig_key, o.bytes AS orig_bytes, o.source AS orig_source, o.public_key AS orig_public_key
  FROM media_items h
  LEFT JOIN studio_sessions s ON s.id = h.session_id
  LEFT JOIN media_items o ON o.deleted_at IS NULL AND o.bucket = 'originals' AND o.r2_key = s.r2_key
 WHERE h.source = 'host' AND h.bucket = 'media' AND h.deleted_at IS NULL
 ORDER BY h.created_at, h.id`;

export type SkipReason =
    | "no_original"
    | "several_originals"
    | "several_hosts"
    | "object_missing"
    | "size_mismatch"
    | "storage_error";
export type PlanAction = "merge" | "already_merged" | `skip:${SkipReason}`;
export type Planned = { cand: Candidate; action: PlanAction };

// Decides one candidate: counts of how many originals the host reached and how many hosts the
// original has come from the whole candidate list. Reads R2 head only.
export async function planCandidate(
    d: Pick<VisDeps, "originals" | "media">,
    cand: Candidate,
    originalsOfHost: number,
    hostsOfOriginal: number,
): Promise<Planned> {
    const skip = (r: SkipReason): Planned => ({ cand, action: `skip:${r}` });
    if (!cand.orig_id || originalsOfHost === 0) return skip("no_original");
    if (originalsOfHost > 1) return skip("several_originals");
    if (cand.orig_public_key === cand.host_key) return { cand, action: "already_merged" };
    if (hostsOfOriginal > 1) return skip("several_hosts");
    let host: { size: number } | null;
    let orig: { size: number } | null;
    try {
        host = await d.media.head(cand.host_key);
        orig = await d.originals.head(cand.orig_key!);
    } catch {
        return skip("storage_error");
    }
    if (!host || !orig) return skip("object_missing");
    const sizes = [host.size, orig.size, cand.host_bytes, cand.orig_bytes].filter((n): n is number => typeof n === "number");
    if (new Set(sizes).size > 1) return skip("size_mismatch");
    return { cand, action: "merge" };
}

// Plans every candidate of a query result (rows are one per host x matching original).
export async function planAll(d: Pick<VisDeps, "originals" | "media">, rows: Candidate[]): Promise<Planned[]> {
    const byHost = new Map<string, Candidate[]>();
    const hostsOfOrig = new Map<string, Set<string>>();
    for (const r of rows) {
        const list = byHost.get(r.host_id);
        if (list) list.push(r);
        else byHost.set(r.host_id, [r]);
        if (r.orig_id) {
            const hosts = hostsOfOrig.get(r.orig_id);
            if (hosts) hosts.add(r.host_id);
            else hostsOfOrig.set(r.orig_id, new Set([r.host_id]));
        }
    }
    const out: Planned[] = [];
    for (const list of byHost.values()) {
        const first = list[0]!;
        const origs = new Set(list.filter((r) => r.orig_id).map((r) => r.orig_id));
        out.push(await planCandidate(d, first, origs.size, hostsOfOrig.get(first.orig_id ?? "")?.size ?? 0));
    }
    return out;
}

// One D1 batch per pair, so a pair is all-or-nothing (section 4.3). Returns whether anything changed.
export async function applyMerge(db: D1Database, cand: Candidate, now: number): Promise<boolean> {
    const o = cand.orig_id!;
    const results = await db.batch([
        db
            .prepare(
                "UPDATE media_items SET visibility = 'public', public_key = ?2, public_id = ?3, url = ?4, poster = COALESCE(poster, ?5) WHERE id = ?1 AND deleted_at IS NULL AND bucket = 'originals' AND (public_key IS NULL OR public_key = ?2)",
            )
            .bind(o, cand.host_key, cand.host_id, cand.host_url, cand.host_poster),
        db
            .prepare(
                "UPDATE media_items SET deleted_at = ?6, merged_into = ?1 WHERE id = ?3 AND deleted_at IS NULL AND source = 'host' AND EXISTS (SELECT 1 FROM media_items WHERE id = ?1 AND public_key = ?2)",
            )
            .bind(o, cand.host_key, cand.host_id, cand.host_url, cand.host_poster, now),
        db
            .prepare(
                "UPDATE studio_sessions SET public_state = 'ready', public_url = ?4 WHERE r2_key = (SELECT r2_key FROM media_items WHERE id = ?1 AND public_key = ?2)",
            )
            .bind(o, cand.host_key, cand.host_id, cand.host_url),
    ]);
    return results.some((r) => Number(r.meta?.changes ?? 0) > 0);
}

// The toggle's lazy merge: the window between deploy and the data step must not mint a second
// mirror for an original whose pair is still unmerged.
export async function lazyMerge(d: VisDeps, row: MediaRow): Promise<MediaRow> {
    if (row.bucket !== "originals" || row.public_key || !isOriginalSource(row.source)) return row;
    const { results } = await d.db
        .prepare(
            `SELECT h.id AS host_id, h.r2_key AS host_key, h.url AS host_url, h.bytes AS host_bytes, h.poster AS host_poster,
                    o.id AS orig_id, o.r2_key AS orig_key, o.bytes AS orig_bytes, o.source AS orig_source, o.public_key AS orig_public_key
               FROM media_items h
               JOIN studio_sessions s ON s.id = h.session_id
               JOIN media_items o ON o.deleted_at IS NULL AND o.bucket = 'originals' AND o.r2_key = s.r2_key
              WHERE h.source = 'host' AND h.bucket = 'media' AND h.deleted_at IS NULL AND o.id = ?1
              ORDER BY h.created_at, h.id`,
        )
        .bind(row.id)
        .all<Candidate>();
    if (results.length === 0) return row;
    const planned = await planAll(d, results);
    if (planned.length !== 1 || planned[0]!.action !== "merge") return row;
    await applyMerge(d.db, planned[0]!.cand, d.now());
    return (await getRow(d.db, row.id)) ?? row;
}

// ---- POST /library/visibility/migrate -------------------------------------------------------------

export const DEFAULT_MIGRATE_LIMIT = 25;
export const MAX_MIGRATE_LIMIT = 100;

type Counts = { n: number };
const count = async (db: D1Database, where: string): Promise<number> =>
    (await db.prepare(`SELECT COUNT(*) AS n FROM media_items WHERE ${where}`).first<Counts>())?.n ?? 0;

export type MigrateOptions = { dryRun: boolean; limit: number; undo: boolean };

export async function migrateVisibility(d: VisDeps, o: MigrateOptions): Promise<StudioReply> {
    try {
        return o.undo ? await undoMerge(d, o) : await migrateMerge(d, o);
    } catch (e) {
        console.error("[visibility] migrate failed", String(e));
        return err(503, "error.api.generic");
    }
}

async function baseReport(db: D1Database) {
    return {
        rows_live: await count(db, "deleted_at IS NULL"),
        originals: await count(db, "deleted_at IS NULL AND bucket = 'originals' AND source IN ('saved', 'upload')"),
        hosts_live: await count(db, "deleted_at IS NULL AND bucket = 'media' AND source = 'host'"),
        // (a slideshow row is source 'studio' too, section 18.5, but it has a role: it is not a webp)
        webps: await count(db, "deleted_at IS NULL AND role IS NULL AND source IN ('webp', 'studio')"),
    };
}

async function migrateMerge(d: VisDeps, o: MigrateOptions): Promise<StudioReply> {
    const db = d.db;
    const base = await baseReport(db);
    const { results: rows } = await db.prepare(CANDIDATES_SQL).all<Candidate>();
    const planned = await planAll(d, rows);

    const mergeable = planned.filter((p) => p.action === "merge" || p.action === "already_merged");
    const skipped: Record<SkipReason, number> = {
        no_original: 0,
        several_originals: 0,
        several_hosts: 0,
        object_missing: 0,
        size_mismatch: 0,
        storage_error: 0,
    };
    for (const p of planned) if (p.action.startsWith("skip:")) skipped[p.action.slice(5) as SkipReason]++;

    const saved = mergeable.filter((p) => p.cand.orig_source === "saved").length;
    const upload = mergeable.filter((p) => p.cand.orig_source === "upload").length;
    const tombstones = await count(db, "merged_into IS NOT NULL");
    const alreadyMerged = tombstones; // retired host rows from earlier runs

    const page = mergeable.slice(0, o.limit);
    const items: Record<string, unknown>[] = [];
    for (const p of page) {
        items.push({
            host: p.cand.host_id,
            original: p.cand.orig_id,
            url: p.cand.host_url,
            action: p.action,
        });
    }
    for (const p of planned) {
        if (p.action.startsWith("skip:") && items.length < MAX_MIGRATE_LIMIT) {
            items.push({ host: p.cand.host_id, original: p.cand.orig_id, url: p.cand.host_url, action: p.action });
        }
    }
    if (tombstones > 0 && page.length === 0) {
        const { results: done } = await db
            .prepare(
                "SELECT t.id AS host, t.merged_into AS original, o.url AS url FROM media_items t LEFT JOIN media_items o ON o.id = t.merged_into WHERE t.merged_into IS NOT NULL ORDER BY t.created_at, t.id LIMIT ?1",
            )
            .bind(MAX_MIGRATE_LIMIT)
            .all<{ host: string; original: string; url: string | null }>();
        for (const t of done) items.push({ ...t, action: "already_merged" });
    }

    let processed = 0;
    let backfilled = 0;
    const unsetBefore = await count(db, "deleted_at IS NULL AND visibility IS NULL");
    if (!o.dryRun) {
        for (const p of page) {
            await applyMerge(db, p.cand, d.now());
            processed++;
        }
        if (mergeable.length - page.length <= 0) {
            // step 4, once after the last page
            const res = await db
                .prepare(
                    "UPDATE media_items SET visibility = CASE WHEN bucket = 'media' THEN 'public' ELSE 'private' END WHERE visibility IS NULL AND deleted_at IS NULL",
                )
                .run();
            backfilled = Number(res.meta?.changes ?? 0);
        }
    }

    // the projection if every pair merged: hosts retire, originals become public, nothing else moves
    const publicNow = await count(db, `deleted_at IS NULL AND ${visSql()} = 'public'`);
    const hostsMerging = mergeable.filter((p) => p.action === "merge").length;
    const rowsAfter = base.rows_live - hostsMerging;
    const posters = await count(
        db,
        "deleted_at IS NULL AND bucket = 'originals' AND poster IS NULL AND (content_type LIKE 'video/%' OR content_type = 'image/gif')",
    );

    return {
        status: 200,
        body: {
            status: "success",
            dry_run: o.dryRun,
            undo: false,
            report: {
                ...base,
                merge: { pairs: hostsMerging, saved, upload, already_merged: alreadyMerged },
                skipped,
                after: {
                    rows_live: rowsAfter,
                    public: publicNow,
                    private: rowsAfter - publicNow,
                    tombstones: tombstones + hostsMerging,
                },
                visibility_unset: unsetBefore,
                posters_missing: posters,
                r2_writes: 0,
                r2_deletes: 0,
                ...(o.dryRun ? {} : { processed, backfilled }),
            },
            items,
            remaining: Math.max(0, mergeable.length - (o.dryRun ? page.length : processed)),
        },
    };
}

// ---- undo (4.4): back to the pre-merge rows the old code expects ----------------------------------

const displayNameWithExt = (name: string, key: string) => {
    const ext = extOf(key);
    return name.toLowerCase().endsWith(`.${ext}`) ? name : `${name}.${ext}`;
};

async function undoMerge(d: VisDeps, o: MigrateOptions): Promise<StudioReply> {
    const db = d.db;
    const { results: tombs } = await db
        .prepare(
            "SELECT t.id AS tomb, t.merged_into AS orig FROM media_items t WHERE t.merged_into IS NOT NULL AND t.deleted_at IS NOT NULL ORDER BY t.created_at, t.id",
        )
        .all<{ tomb: string; orig: string }>();
    // originals made public by new code: public, with a mirror, and no tombstone behind them
    const { results: fresh } = await db
        .prepare(
            `SELECT ${ITEM_COLUMNS} FROM media_items o
              WHERE o.deleted_at IS NULL AND o.bucket = 'originals' AND o.source IN ('saved', 'upload')
                AND o.public_key IS NOT NULL AND o.public_id IS NOT NULL AND o.visibility = 'public'
                AND NOT EXISTS (SELECT 1 FROM media_items t WHERE t.id = o.public_id AND t.merged_into = o.id)
              ORDER BY o.created_at, o.id`,
        )
        .all<MediaRow>();
    const webpsSwitched = await count(db, "deleted_at IS NULL AND bucket = 'originals' AND role IS NULL AND source IN ('webp', 'studio')");

    const todo = [
        ...tombs.map((t) => ({ kind: "tombstone" as const, id: t.tomb, orig: t.orig })),
        ...fresh.map((r) => ({ kind: "fresh" as const, id: r.public_id!, orig: r.id, row: r })),
    ];
    const page = todo.slice(0, o.limit);
    const items = page.map((t) => ({ host: t.id, original: t.orig, action: t.kind === "tombstone" ? "restore" : "insert_host" }));

    let processed = 0;
    if (!o.dryRun) {
        for (const t of page) {
            if (t.kind === "tombstone") {
                await db.batch([
                    db.prepare("UPDATE media_items SET deleted_at = NULL, merged_into = NULL WHERE id = ?1 AND merged_into = ?2").bind(t.id, t.orig),
                    db
                        .prepare(
                            "UPDATE media_items SET url = NULL, public_key = NULL, public_id = NULL, visibility = NULL WHERE id = ?1 AND public_id = ?2",
                        )
                        .bind(t.orig, t.id),
                ]);
            } else {
                const r = t.row!;
                await db.batch([
                    db
                        .prepare(
                            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster)
                             SELECT o.public_id, 'public', 'host', 'media', o.public_key, o.url, ?2, o.content_type, o.bytes, o.width, o.height, o.duration, o.link,
                                    COALESCE(o.session_id, (SELECT s.id FROM studio_sessions s WHERE s.r2_key = o.r2_key ORDER BY s.created_at DESC LIMIT 1)),
                                    o.key_id, ?3, o.poster
                               FROM media_items o
                              WHERE o.id = ?1 AND NOT EXISTS (SELECT 1 FROM media_items WHERE bucket = 'media' AND r2_key = o.public_key)`,
                        )
                        .bind(r.id, displayNameWithExt(r.name, r.public_key!), d.now()),
                    db
                        .prepare("UPDATE media_items SET url = NULL, public_key = NULL, public_id = NULL, visibility = NULL WHERE id = ?1")
                        .bind(r.id),
                ]);
            }
            processed++;
        }
    }
    const remaining = Math.max(0, todo.length - (o.dryRun ? page.length : processed));
    let cleared = 0;
    if (!o.dryRun && remaining === 0) {
        // back to "not migrated": every reader derives visibility from the bucket again (a webp that was
        // switched private lives in the private bucket now and keeps its explicit value)
        const res = await db
            .prepare(
                // (a switched webp keeps its explicit value; so do the rows made after 0009, which have no pre-0008 shape)
                "UPDATE media_items SET visibility = NULL WHERE visibility IS NOT NULL AND NOT (bucket = 'originals' AND (role IS NOT NULL OR source IN ('webp', 'studio', 'made')))",
            )
            .run();
        cleared = Number(res.meta?.changes ?? 0);
    }
    return {
        status: 200,
        body: {
            status: "success",
            dry_run: o.dryRun,
            undo: true,
            report: {
                tombstones: tombs.length,
                new_code_publics: fresh.length,
                // not undone: a switched webp has no pre-0008 shape. Make them public again before a code
                // rollback (old code lists a private one as a public file with no url).
                webps_switched: webpsSwitched,
                r2_writes: 0,
                r2_deletes: 0,
                ...(o.dryRun ? {} : { processed, visibility_cleared: cleared }),
            },
            items,
            remaining,
        },
    };
}
