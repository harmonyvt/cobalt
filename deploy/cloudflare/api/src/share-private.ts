// The share host's private links (APP-API-CONTRACT.md section 36.4): share.../p/<key> is the page of one file or one
// gallery link, built by the same page code as its public address (sections 22 and 24) with every file and poster URL
// under /p/<key>/, and share.../p/<key>/<n>.<ext> (and <n>.poster.jpg) stream the bytes from R2 with Range support.
// Anything that is not a live key opening something that is still private is the same plain 404. Nothing is cached:
// a rotate takes effect at once. Free of Cloudflare imports (the tests run it under node).
import { POST_KEY_SQL } from "./app-routes";
import { linkByKey, noteOpened, type PrivateLinkRow } from "./private-links";
import { captionOf, itemSubject } from "./roast";
import { pageHeaders, singlePageHtml, typeOf, type Found, type ShareDeps } from "./share";
import { liveSetRow, pageHtml, parseItems, privateLiveSet, rowsById } from "./share-sets";
import { notHiddenClause } from "./hidden-store";
import { parseRange } from "./studio";
import { ITEM_COLUMNS, effectiveVisibility, extOf, type MediaRow } from "./visibility";

// What streaming needs of an R2 bucket (the real binding has all of it).
export interface ByteBucket {
    head(key: string): Promise<{ size: number; httpEtag?: string; uploaded?: Date; httpMetadata?: { contentType?: string } } | null>;
    get(key: string, options?: { range?: { offset: number; length?: number } }): Promise<{ body: ReadableStream; size: number } | null>;
}

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

// A file's own extension: the one its stored object has.
export const fileExt = (r: Pick<MediaRow, "r2_key">) => extOf(r.r2_key);
// File <n> of a private link (1-based; a file link's only file is 1) and its poster.
export const privateFileUrl = (shareBaseUrl: string, key: string, n: number, r: Pick<MediaRow, "r2_key">) => `${withSlash(shareBaseUrl)}p/${key}/${n}.${fileExt(r)}`;
export const privatePosterUrl = (shareBaseUrl: string, key: string, n: number) => `${withSlash(shareBaseUrl)}p/${key}/${n}.poster.jpg`;

const PAGE_PATH = /^\/p\/([A-Za-z0-9]{22})\/?$/;
const FILE_PATH = /^\/p\/([A-Za-z0-9]{22})\/([1-9][0-9]?)\.(poster\.jpg|[A-Za-z0-9]{1,8})$/;

const NOT_FOUND = () =>
    new Response("not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
const TRY_AGAIN = () => new Response("try again\n", { status: 503, headers: { "content-type": "text/plain", "cache-control": "no-store", "retry-after": "5" } });

// The live file a link's item opens: not deleted and not public (public again = the link is dead, whatever its row).
async function privateItem(db: D1Database, id: string): Promise<Found | null> {
    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    const row = await db
        .prepare(
            `SELECT ${cols}, (SELECT t.title FROM media_titles t WHERE t.post_key = ${POST_KEY_SQL}) AS custom_title
               FROM media_items m WHERE m.id = ?1 AND m.deleted_at IS NULL${await notHiddenClause(db)}`,
        )
        .bind(id)
        .first<Found>();
    return row && effectiveVisibility(row) !== "public" ? row : null;
}

// File <n> of a live link: the row whose bytes it streams, or null.
async function fileOfLink(db: D1Database, link: PrivateLinkRow, n: number): Promise<MediaRow | null> {
    if (link.kind === "item") return n === 1 ? privateItem(db, link.target_id) : null;
    const set = await liveSetRow(db, link.target_id);
    if (!set) return null;
    const id = parseItems(set.items)[n - 1];
    if (!id) return null;
    return (await rowsById(db, [id])).get(id) ?? null;
}

// The direct file links of a live private link, in its order: share.../p/<key>/<n>.<ext>, the bytes themselves (null for a
// file that is gone). For the chat AI and MCP, which would otherwise read them off the page (section 36.5).
export async function privateFileUrls(db: D1Database, shareBaseUrl: string, link: Pick<PrivateLinkRow, "kind" | "target_id" | "key">): Promise<(string | null)[]> {
    if (link.kind === "item") {
        const row = await privateItem(db, link.target_id);
        return [row ? privateFileUrl(shareBaseUrl, link.key, 1, row) : null];
    }
    const set = await liveSetRow(db, link.target_id);
    if (!set) return [];
    const ids = parseItems(set.items);
    const rows = await rowsById(db, ids);
    return ids.map((id, i) => {
        const r = rows.get(id);
        return r ? privateFileUrl(shareBaseUrl, link.key, i + 1, r) : null;
    });
}

// GET|HEAD /p/<key> and /p/<key>/<n>.<ext> (sharePage has answered other methods with a 405).
export async function privateRoute(d: ShareDeps, request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    try {
        const page = PAGE_PATH.exec(path);
        if (page) return await privatePage(d, request, page[1]!);
        const file = FILE_PATH.exec(path);
        if (file) return await privateFile(d, request, file[1]!, Number(file[2]), file[3]!);
        return NOT_FOUND();
    } catch (e) {
        console.error("[private] share host failed", String(e));
        return TRY_AGAIN();
    }
}

async function privatePage(d: ShareDeps, request: Request, key: string): Promise<Response> {
    const link = await linkByKey(d.db, key);
    if (!link) return NOT_FOUND();
    const share = withSlash(d.shareBaseUrl);
    const media = withSlash(d.mediaBaseUrl);
    const pageUrl = `${share}p/${key}`;
    let html: string;
    if (link.kind === "item") {
        const row = await privateItem(d.db, link.target_id);
        if (!row) return NOT_FOUND();
        const fileUrl = privateFileUrl(share, key, 1, row);
        const poster = row.poster && row.poster.startsWith(media) ? privatePosterUrl(share, key, 1) : null;
        // the caption the file got while it was public, if any (a private file is never sent to the model from here)
        const caption = (row.custom_title ?? "").trim() !== "" ? null : await captionOf(d.db, itemSubject(row.id));
        html = singlePageHtml({ row, type: typeOf(row, row.r2_key), fileUrl, poster, pageUrl, caption });
    } else {
        const set = await liveSetRow(d.db, link.target_id);
        const s = set ? await privateLiveSet(d, set, key) : null;
        if (!s) return NOT_FOUND();
        html = pageHtml(d, s, /discordbot/i.test(request.headers.get("user-agent") ?? ""), pageUrl);
    }
    if (request.method === "GET") await noteOpened(d.db, key, (d.now ?? Date.now)());
    return new Response(request.method === "HEAD" ? null : html, {
        headers: pageHeaders(new URL(share).origin, "no-store", link.kind === "set" ? { vary: "user-agent" } : {}),
    });
}

async function privateFile(d: ShareDeps, request: Request, key: string, n: number, ext: string): Promise<Response> {
    const link = await linkByKey(d.db, key);
    if (!link) return NOT_FOUND();
    const row = await fileOfLink(d.db, link, n);
    if (!row) return NOT_FOUND();
    if (ext === "poster.jpg") {
        const media = withSlash(d.mediaBaseUrl);
        if (!d.media || !row.poster || !row.poster.startsWith(media)) return NOT_FOUND();
        return streamObject(d.media, row.poster.slice(media.length), request, "image/jpeg");
    }
    if (ext.toLowerCase() !== fileExt(row)) return NOT_FOUND();
    // the bytes live where the row says: a webp never switched private in the public bucket, the rest in the private one
    const bucket = row.bucket === "media" ? d.media : d.originals;
    if (!bucket) return NOT_FOUND();
    return streamObject(bucket, row.r2_key, request, typeOf(row, row.r2_key));
}

// One stored object, Range aware (a single `bytes=` range: 206; unsatisfiable: 416), never cached. The size comes from
// the object, never from the row.
export async function streamObject(bucket: ByteBucket, key: string, request: Request, contentType: string): Promise<Response> {
    const known = await bucket.head(key);
    if (!known) return NOT_FOUND();
    const total = known.size;
    const ifRange = request.headers.get("if-range");
    const lastModified = known.uploaded ? known.uploaded.toUTCString() : null;
    const stale = ifRange !== null && ifRange !== known.httpEtag && ifRange !== lastModified;
    const range = parseRange(stale ? null : request.headers.get("range"), total);
    const base: Record<string, string> = {
        "accept-ranges": "bytes",
        "cache-control": "private, no-store",
        "x-content-type-options": "nosniff",
    };
    if (range.kind === "unsatisfiable") {
        return new Response(null, { status: 416, headers: { ...base, "content-range": `bytes */${total}` } });
    }
    const partial = range.kind === "partial";
    const headers = new Headers({ ...base, "content-type": contentType, "content-length": String(partial ? range.length : total) });
    if (known.httpEtag) headers.set("etag", known.httpEtag);
    if (lastModified) headers.set("last-modified", lastModified);
    if (partial) headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${total}`);
    const status = partial ? 206 : 200;
    if (request.method === "HEAD") return new Response(null, { status, headers });
    const obj = await bucket.get(key, partial ? { range: { offset: range.offset, length: range.length } } : undefined);
    if (!obj) return NOT_FOUND();
    // replaced between the head and the get: a whole file is as long as it is now
    if (!partial && obj.size !== total) headers.set("content-length", String(obj.size));
    // the R2 body is handed over as it is (no pipeTo: not implemented in the Workers runtime)
    return new Response(obj.body, { status, headers });
}
