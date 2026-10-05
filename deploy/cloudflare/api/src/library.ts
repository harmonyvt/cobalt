// The library's D1 side (migration 0004_library.sql, LIBRARY-CONTRACT.md): the
// media_items rows the API Worker and Durable Object write. Free of Cloudflare
// imports, so it runs under plain node in the tests.
//
// Writing a row is bookkeeping: it must never fail the operation that made the
// file, so every call here swallows (and logs) its errors.

import { randomBase62 } from "./ids";

export const ITEM_ID_LENGTH = 16;

// Key id the web Worker's service-authenticated calls run as (index of the
// contract's "Internal service auth").
export const SERVICE_KEY_ID = "service:library";

export type MediaSource = "webp" | "studio" | "host" | "upload" | "saved";

export type MediaItemInput = {
    kind: "public" | "private";
    source: MediaSource;
    bucket: "media" | "originals";
    r2_key: string;
    url?: string | null;
    name: string;
    content_type?: string | null;
    bytes?: number | null;
    width?: number | null;
    height?: number | null;
    duration?: number | null;
    link?: string | null;
    session_id?: string | null;
    key_id?: string | null;
    // public URL of the row's poster JPEG (section 13), when it already has one
    poster?: string | null;
    created_at: number;
};

export const mintItemId = (rb?: (n: number) => Uint8Array) =>
    randomBase62(ITEM_ID_LENGTH, rb);

const orNull = <T>(v: T | null | undefined): T | null => (v === undefined ? null : v);

// Inserts a row unless one for the same bucket + key already exists (a poll
// that repeats, or the backfill having run first). Returns the new row's id,
// or null when nothing was inserted (already there, no database, or D1 failed).
export async function insertMediaItem(
    db: D1Database | undefined,
    item: MediaItemInput,
    randomBytes?: (n: number) => Uint8Array,
): Promise<string | null> {
    if (!db) return null;
    const id = mintItemId(randomBytes);
    try {
        const res = await db
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster, visibility) " +
                    "SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18 " +
                    "WHERE NOT EXISTS (SELECT 1 FROM media_items WHERE bucket = ?4 AND r2_key = ?5)",
            )
            .bind(
                id,
                item.kind,
                item.source,
                item.bucket,
                item.r2_key,
                orNull(item.url),
                item.name.slice(0, 300),
                orNull(item.content_type),
                orNull(item.bytes),
                orNull(item.width),
                orNull(item.height),
                orNull(item.duration),
                orNull(item.link),
                orNull(item.session_id),
                orNull(item.key_id),
                item.created_at,
                orNull(item.poster),
                // one row per file (section 16): an original is private until toggled, a public-bucket file is public
                item.bucket === "media" ? "public" : "private",
            )
            .run();
        return Number(res.meta?.changes ?? 0) > 0 ? id : null;
    } catch (e) {
        console.error("[library] media_items insert failed", item.source, item.r2_key, String(e));
        return null;
    }
}

// Marks the live row for a stored object as deleted.
export async function markMediaDeleted(
    db: D1Database | undefined,
    bucket: "media" | "originals",
    r2Key: string,
    now: number,
): Promise<void> {
    if (!db) return;
    try {
        await db
            .prepare(
                "UPDATE media_items SET deleted_at = ?1 WHERE bucket = ?2 AND r2_key = ?3 AND deleted_at IS NULL",
            )
            .bind(now, bucket, r2Key)
            .run();
    } catch (e) {
        console.error("[library] media_items delete mark failed", bucket, r2Key, String(e));
    }
}

// The file name part of a public media URL (https://media.../<name>), or null.
export function mediaNameFromUrl(url: string | null | undefined): string | null {
    if (!url) return null;
    try {
        const last = new URL(url).pathname.split("/").pop();
        return last ? decodeURIComponent(last) : null;
    } catch {
        return null;
    }
}

// A session's `link` for display: uploads carry "upload:<item id>" instead of a page.
export const pageLink = (link: string | null | undefined): string | null =>
    link && /^https?:\/\//i.test(link) ? link : null;

// ---- posters (APP-API-CONTRACT.md section 13) -------------------------------------------------

// A poster object in the public bucket: <10 base62>.jpg (never matches MEDIA_NAME_REGEX,
// so DELETE /media/<name> cannot reach it).
export const POSTER_NAME_REGEX = /^[A-Za-z0-9]{10}\.jpg$/;

// Deletes the poster object behind `url` unless a live row still names it (an original and
// the public copy hosted from it share one object). Call it AFTER the row that held the
// poster was soft-deleted. Never throws: a failed delete is logged (the object is then an
// orphan nothing lists, which costs a few tens of KB). Returns whether it deleted.
export async function releasePoster(
    db: D1Database | undefined,
    media: { delete(key: string): Promise<void> } | undefined,
    url: string | null | undefined,
): Promise<boolean> {
    if (!db || !media || !url) return false;
    const name = mediaNameFromUrl(url);
    if (!name || !POSTER_NAME_REGEX.test(name)) return false;
    try {
        const live = await db
            .prepare("SELECT COUNT(*) AS n FROM media_items WHERE poster = ?1 AND deleted_at IS NULL")
            .bind(url)
            .first<{ n: number }>();
        if ((live?.n ?? 0) > 0) return false;
        await media.delete(name);
        return true;
    } catch (e) {
        console.error("[library] poster delete failed", name, String(e));
        return false;
    }
}

// ---- request bodies -----------------------------------------------------------------------------

// The body as text, never reading past the cap (a client that sends more is answered, not
// buffered). null = too large. Throws on a body that is not UTF-8 or breaks off.
export async function readCapped(request: Request, cap: number): Promise<string | null> {
    const declared = request.headers.get("content-length");
    if (declared !== null && /^\d+$/.test(declared) && Number(declared) > cap) {
        await request.body?.cancel().catch(() => {});
        return null;
    }
    if (!request.body) return "";
    const reader = request.body.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > cap) {
            reader.cancel().catch(() => {});
            return null;
        }
        chunks.push(value);
    }
    const all = new Uint8Array(total);
    let at = 0;
    for (const c of chunks) {
        all.set(c, at);
        at += c.byteLength;
    }
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(all);
}
