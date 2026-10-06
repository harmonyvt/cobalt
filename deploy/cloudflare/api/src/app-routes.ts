// The routes the native app needs (APP-API-CONTRACT.md): capability discovery,
// upload with an API key, and the library with an API key. All of them are
// answered by the Worker from D1 and R2 (the container is never woken); the
// only Durable Object call is the internal adopt path a video upload continues
// into. Free of Cloudflare imports (like studio-edge.ts and publish.ts), so it
// runs under plain node in the tests.
//
//   GET  /capabilities                       what this server can do + the key's state
//   PUT  /studio/upload?name=[&queue=1][&title=]  a file into R2 + library (+ a studio session; `queue=1`
//                                            joins the server's line when the helper is busy, section 17)
//   GET  /library                            the library grouped into posts
//   GET|HEAD /library/items/<id>/file        a private file's bytes (Range aware)
//   POST /library/items/<id>/publish         make a file public (legacy spelling of the toggle)
//   PATCH /library/items/<id>/visibility     the public/private toggle (section 16)
//   POST /library/visibility/migrate         the one-row-per-file data step (section 16)
//   POST /library/items/<id>/studio[?queue=1] open a studio session for a private video
//   DELETE /library/items/<id>/post          delete a whole post: every file and its sessions (section 12)
//   DELETE /library/items/<id>                delete one item or made file of a post (section 18.4)
//   PUT  /library/items/<id>/made             a crop or an export made on the device (section 18.6)

// Read at bundle time from upstream's package.json (reading is fine, editing is
// not); the fork's Worker bundles this one field.
import { version as apiVersion } from "../../../../api/package.json";

import { LINE_MAX, LINE_WAIT_MS, parseQueryFlag } from "./line";
import { lookupKey } from "./keys";
import { SERVICE_KEY_ID, mintItemId, readCapped, releasePoster } from "./library";
import { POSTER_COOLDOWN_MS, posterEligible } from "./poster";
import type { PublishBucket } from "./publish";
import {
    DEFAULT_MIGRATE_LIMIT,
    ITEM_COLUMNS,
    MAX_MIGRATE_LIMIT,
    effectiveVisibility,
    getRow,
    isOriginalSource,
    itemShape,
    makePublic,
    migrateVisibility,
    publishOriginal,
    purgeUrls,
    setVisibility,
    toggleable,
    visSql,
    webpName,
    extOf,
    type MediaRow,
    type PurgeFn,
} from "./visibility";
import {
    MAX_RENDER_SECONDS,
    MAX_SOURCE_BYTES,
    MAX_TITLE_CODE_POINTS as TITLE_MAX_CODE_POINTS,
    MIN_RENDER_SECONDS,
    RENDER_FPS,
    RENDER_QUALITIES,
    RENDER_WIDTHS,
    SESSION_TTL_MS,
    cleanTitle,
    getSession,
    parseRange,
    repointLead,
    studioErr,
    upsertTitle,
    type OriginalsBucket,
    type StudioReply,
} from "./studio";
import { serviceFromUrl } from "./webp";

export const MAX_UPLOAD_BYTES = 100_000_000;
export const MAX_NAME_CHARS = 120;
export const DEFAULT_LIBRARY_LIMIT = 20;
export const MAX_LIBRARY_LIMIT = 50;

// Allowed uploads: content type -> stored extension. The same table as the web
// Worker's (web/src/library.ts UPLOAD_TYPES); copied, not imported across Workers.
export const UPLOAD_TYPES: Record<string, string> = {
    "image/gif": "gif",
    "image/webp": "webp",
    "image/png": "png",
    "image/jpeg": "jpg",
    "video/mp4": "mp4",
    "video/quicktime": "mov",
    "image/heic": "heic",
};

const err = (status: number, code: string): StudioReply => ({
    status,
    body: { status: "error", error: { code } },
});

export type AppDeps = {
    db: D1Database;
    originals: OriginalsBucket;
    media: PublishBucket;
    // https://media.../ (public bucket) and the API's own origin (API_URL), and
    // the web origin the studio page lives on (CORS_URL).
    mediaBaseUrl: string;
    apiUrl: string;
    webUrl: string;
    now: () => number;
    // Workers' FixedLengthStream; injectable because Node has none.
    fixedLength: (n: number) => { readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array> };
    // Hands a stored upload to the Durable Object's internal adopt path
    // (POST /studio/upload/adopt with the caller's key id).
    adopt: (keyId: string, body: Record<string, unknown>) => Promise<StudioReply>;
    // Asks the Durable Object to queue the posters still missing (section 13). Absent in
    // tests that do not care; never awaited for long (see bounded()).
    kickPosters?: (limit?: number) => Promise<StudioReply>;
    randomBytes?: (n: number) => Uint8Array;
    // Edge-cache purge for the public bucket's URLs (section 16); absent = not configured.
    purge?: PurgeFn;
};

// Re-exported for the callers that used to import it from here.
export { itemShape };

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const noSlash = (u: string) => u.replace(/\/+$/, "");

// ---- media_items rows ---------------------------------------------------------

const getItem = (db: D1Database, id: string) => getRow(db, id);

// ---- 1. GET /capabilities ----------------------------------------------------------

export type KeyState = "missing" | "invalid" | "valid" | "unknown";

// The key's state for Settings. Never throws: a D1 failure is "unknown".
export async function resolveKeyState(
    db: D1Database,
    auth: "service" | "missing" | "invalid" | "key",
    key: string | undefined,
    now: number,
): Promise<{ key: KeyState; key_name: string | null }> {
    if (auth === "service") return { key: "valid", key_name: "service" };
    if (auth === "missing") return { key: "missing", key_name: null };
    if (auth === "invalid" || !key) return { key: "invalid", key_name: null };
    let keyId: string | null;
    try {
        keyId = await lookupKey(db, key, now);
    } catch {
        return { key: "unknown", key_name: null };
    }
    if (keyId === null) return { key: "invalid", key_name: null };
    let name: string | null = null;
    try {
        const row = await db
            .prepare("SELECT name FROM api_keys WHERE id = ?1")
            .bind(keyId)
            .first<{ name: string }>();
        name = row?.name ?? null;
    } catch {
        // valid, just unnamed
    }
    return { key: "valid", key_name: name };
}

export async function capabilities(
    d: Pick<AppDeps, "db" | "mediaBaseUrl" | "now">,
    auth: "service" | "missing" | "invalid" | "key",
    key: string | undefined,
    // the three APNs secrets are configured (Live Activity push, section 8)
    livePush = false,
    // the Hark webhook is configured (notification bridge, section 9)
    notifyBridge = false,
    // the container's helper has said it has the slideshow routes (section 18.8): a Worker deployed ahead of the
    // container rollout must not advertise what an older helper image cannot do
    helperGallery = false,
): Promise<StudioReply> {
    const state = await resolveKeyState(d.db, auth, key, d.now());
    const version: unknown = apiVersion;
    return {
        status: 200,
        body: {
            status: "success",
            server: "cobalt-cloudflare",
            cobalt: typeof version === "string" ? { version } : null,
            features: {
                studio: true,
                upload: true,
                library: true,
                save_progress: true,
                render_progress: true,
                finishes_unpolled: true,
                live_activity_push: livePush === true,
                notify_bridge: notifyBridge === true,
                crop: true,
                source_wait: true,
                delete_post: true,
                telemetry: true,
                // server-made posters and `public: true` on POST /studio and PUT /studio/upload
                // (APP-API-CONTRACT.md section 13)
                poster: true,
                public_default: true,
                // `notify` and `origin: "share"` on POST /studio, and GET /studio/recent
                // (APP-API-CONTRACT.md section 14)
                create_notify: true,
                // PATCH /library/items/<id>/post and `custom_title` in GET /library
                // (APP-API-CONTRACT.md section 15)
                titles: true,
                // one file per rendition: PATCH /library/items/<id>/visibility, `v=2` on GET /library
                // (APP-API-CONTRACT.md section 16)
                visibility: true,
                // the server's line: `queue` on POST /studio, POST .../render, PUT /studio/upload and
                // POST /library/items/<id>/studio, GET /studio/line, the cancel routes and
                // PUT|DELETE /studio/line/notify (APP-API-CONTRACT.md section 17)
                line: true,
                // photos and galleries: `items` / `slideshow` on POST /studio, POST /studio/<sid>/items/retry and
                // /slideshow, `v=3` on GET /library, DELETE /library/items/<id>, PUT .../made, `scope: "post"` on
                // the visibility toggle (APP-API-CONTRACT.md section 18; needs `line`, and a helper that said it has
                // the slideshow routes: the Durable Object learns that from the helper's own answers)
                gallery: helperGallery === true,
            },
            limits: {
                max_webp_seconds: MAX_RENDER_SECONDS,
                min_webp_seconds: MIN_RENDER_SECONDS,
                webp_widths: [...RENDER_WIDTHS],
                webp_qualities: [...RENDER_QUALITIES],
                render_fps: RENDER_FPS,
                max_upload_bytes: MAX_UPLOAD_BYTES,
                max_source_bytes: MAX_SOURCE_BYTES,
                session_ttl_ms: SESSION_TTL_MS,
                line_max: LINE_MAX,
                line_wait_ms: LINE_WAIT_MS,
            },
            media_base_url: withSlash(d.mediaBaseUrl),
            key: state.key,
            key_name: state.key_name,
        },
    };
}

// ---- 3. PUT /studio/upload ------------------------------------------------------------

// Same cleaning as the web's cleanName: no control characters, no path, at most
// 120 characters, `upload.<ext>` when nothing usable is left.
export function cleanName(raw: string | null, ext: string): string {
    let name = raw ?? "";
    // eslint-disable-next-line no-control-regex
    name = name.replace(/[\u0000-\u001f\u007f]/g, "");
    name = name.split(/[\\/]/).pop() ?? "";
    name = Array.from(name.trim()).slice(0, MAX_NAME_CHARS).join("").trim();
    return name && name !== "." && name !== ".." ? name : `upload.${ext}`;
}

// What the request log keeps of an upload: sizes and type only. The body is
// never read for it.
export function uploadLogInfo(request: Request) {
    const declared = request.headers.get("content-length");
    return {
        contentType: request.headers.get("content-type"),
        bytes: declared !== null && /^\d{1,15}$/.test(declared) ? Number(declared) : 0,
        keys: "",
        urlType: "upload",
        urlLen: null,
        urlPrefix: null,
    };
}

export async function studioUpload(
    d: AppDeps,
    request: Request,
    keyId: string,
    q: URLSearchParams,
): Promise<StudioReply> {
    // Everything that can refuse does so before the body is read, and cancels it.
    const reject = (status: number, code: string) => {
        void request.body?.cancel().catch(() => {});
        return err(status, code);
    };
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    const ext = UPLOAD_TYPES[type];
    if (!ext) return reject(415, "error.library.unsupported");
    // `?public=1|true` (section 13): host the original publicly once it is ready. Absent or
    // empty = today's behaviour; anything but 1/true/0/false is refused before the body is read.
    const rawPublic = q.get("public");
    let wantsPublic = false;
    if (rawPublic !== null && rawPublic !== "") {
        if (rawPublic === "1" || rawPublic === "true") wantsPublic = true;
        else if (rawPublic !== "0" && rawPublic !== "false") return reject(400, "error.library.bad_request");
    }
    // `?queue=1` (section 17.3): when the helper is not free the adopted session joins the server's
    // line instead of the studio_error. Anything but 1/true/0/false is refused before the body is read.
    const wantsQueue = parseQueryFlag(q.get("queue"));
    if (wantsQueue === null) return reject(400, "error.library.bad_request");
    // `?title=<url-encoded>` (section 17.3): the post's custom title, the rules of section 15.2
    let title: string | null = null;
    if (q.has("title")) {
        const t = cleanTitle(q.get("title"));
        if (!t.ok) return reject(400, "error.library.bad_title");
        title = t.title;
    }

    const declared = request.headers.get("content-length");
    if (declared === null || !/^\d{1,15}$/.test(declared)) return reject(411, "error.library.length_required");
    const size = Number(declared);
    if (size > MAX_UPLOAD_BYTES) return reject(413, "error.library.too_large");
    if (size === 0 || !request.body) return reject(400, "error.library.empty");

    const id = mintItemId(d.randomBytes);
    const key = `uploads/${id}.${ext}`;
    const name = cleanName(q.get("name"), ext);
    const now = d.now();

    // Straight from the request to R2: the body has a known length, nothing is buffered.
    let obj: { size: number } | null;
    try {
        obj = await d.originals.put(key, request.body, {
            httpMetadata: { contentType: type },
            customMetadata: { keyId, source: "upload", createdAt: String(now) },
        });
    } catch (e) {
        console.error("[upload] R2 put failed", String(e));
        await d.originals.delete(key).catch(() => {});
        return err(502, "error.library.storage");
    }
    if (!obj || obj.size !== size) {
        await d.originals.delete(key).catch(() => {});
        return err(400, "error.library.incomplete");
    }

    let row: MediaRow | null = null;
    let inserted = false;
    try {
        await d.db
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, key_id, created_at, visibility)
                 VALUES (?1, 'private', 'upload', 'originals', ?2, NULL, ?3, ?4, ?5, ?6, ?7, 'private')`,
            )
            .bind(id, key, name, type, size, keyId, now)
            .run();
        inserted = true;
        row = await getItem(d.db, id);
    } catch (e) {
        console.error("[upload] media_items insert failed", String(e));
        // Only a failed INSERT leaves the object orphaned. If the row is there
        // and merely reading it back failed, deleting the object would leave a
        // library row with no file: keep both and carry on (the response then
        // has no `item`; the next GET /library lists it).
        if (!inserted) {
            await d.originals.delete(key).catch(() => {});
            return err(503, "error.api.generic");
        }
    }

    // the post's custom title, for the upload's own item id (its post key); best effort
    if (title !== null) {
        try {
            await upsertTitle(d.db, id, title, keyId, now);
        } catch (e) {
            console.error("[upload] could not store the title", String(e));
        }
    }

    // A video (or gif) continues into a studio session through the same adopt
    // path as a pasted link's session. Images stop here (the app offers to host
    // them as they are, route 5c).
    let sid: string | null = null;
    let url: string | null = null;
    let studioError: { code: string } | null = null;
    let lineState: { queued: boolean; queue_ahead: number | null } | null = null;
    if (type.startsWith("video/") || type === "image/gif") {
        try {
            const a = await d.adopt(keyId, {
                r2_key: key,
                name,
                content_type: type,
                bytes: size,
                item_id: id,
                // the Durable Object hosts the original when the session is ready
                ...(wantsPublic ? { public: true } : {}),
                ...(wantsQueue ? { queue: true } : {}),
            });
            const b = a.body as {
                status?: string;
                id?: unknown;
                url?: unknown;
                queued?: unknown;
                queue_ahead?: unknown;
                error?: { code?: unknown };
            };
            if (a.status === 201 && b.status === "success" && typeof b.id === "string") {
                sid = b.id;
                url = typeof b.url === "string" ? b.url : `${noSlash(d.webUrl)}/studio/${b.id}`;
                if (wantsQueue) {
                    lineState = {
                        queued: b.queued === true,
                        queue_ahead: typeof b.queue_ahead === "number" ? b.queue_ahead : null,
                    };
                }
            } else {
                // refused (busy, not a video, too large...): the file IS stored
                studioError = { code: typeof b.error?.code === "string" ? b.error.code : "error.api.generic" };
            }
        } catch (e) {
            console.error("[upload] adopt failed", String(e));
            studioError = { code: "error.api.generic" };
        }
    }

    // Public hosting (section 13). A video that got a session is hosted by the Durable Object
    // when the session is ready ("pending" now). Everything else (an image, a video whose
    // session was refused) is hosted right here, by the same code as POST
    // /library/items/<id>/publish, since nothing else will do it.
    let publicState: "pending" | "ready" | "failed" | null = null;
    let publicUrl: string | null = null;
    if (wantsPublic) {
        if (sid) {
            publicState = "pending";
        } else if (row) {
            const hosted = await libraryPublish(d, id, keyId);
            const hb = hosted.body as { url?: unknown };
            if (hosted.status === 201 && typeof hb.url === "string") {
                publicState = "ready";
                publicUrl = hb.url;
                // one row: the answer shows it public (an image is one post with one file)
                try {
                    row = (await getItem(d.db, id)) ?? row;
                } catch {
                    // the row read before is still a truthful item
                }
            } else {
                publicState = "failed";
            }
        } else {
            publicState = "failed";
        }
    }

    return {
        status: 201,
        body: {
            status: "success",
            id: sid,
            url,
            item: row ? itemShape(row) : null,
            studio_error: studioError,
            public_state: publicState,
            public_url: publicUrl,
            // only for a caller that asked for the line (`?queue=1`): today's shape for the rest
            ...(wantsQueue ? { queued: lineState?.queued ?? false, queue_ahead: lineState?.queue_ahead ?? null } : {}),
        },
    };
}

// ---- 5a. GET /library -----------------------------------------------------------------------

// One card per post: the owner's COALESCE(session_id, link, id), refined so an
// upload and the renders made from it (whose session's link is "upload:<item id>")
// land in one card. Since migration 0009 (section 18.1) a row that names its post (`post_key`: a
// gallery item, a slideshow, a crop or an export) says so first; rows older than that have NULL.
export const POST_KEY_SQL = `COALESCE(
    m.post_key,
    (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
    m.session_id, m.link, m.id)`;

// The lead item of a gallery (section 18.1): its first video, else its first item. Rows only (no session).
const LEAD_ITEM_SQL = `COALESCE(
    (SELECT i.id FROM media_items i WHERE i.session_id = m.session_id AND i.role = 'item' AND i.deleted_at IS NULL AND i.content_type LIKE 'video/%' ORDER BY i.item_index, i.id LIMIT 1),
    (SELECT i.id FROM media_items i WHERE i.session_id = m.session_id AND i.role = 'item' AND i.deleted_at IS NULL ORDER BY i.item_index, i.id LIMIT 1))`;
// GET /library without v=3 (section 18.3): made rows and the items after the lead are left out
const LEGACY_GALLERY_HIDE = ` AND COALESCE(m.role, '') NOT IN ('slideshow', 'crop', 'export') AND (COALESCE(m.role, '') <> 'item' OR m.id = ${LEAD_ITEM_SQL})`;

const b64urlEncode = (s: string): string => {
    const bytes = new TextEncoder().encode(s);
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64urlDecode = (s: string): string | null => {
    if (!/^[A-Za-z0-9_-]+$/.test(s)) return null;
    try {
        const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
        return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
    } catch {
        return null;
    }
};

// "<ms>.<post key>", base64url. The key may itself contain dots (a link), so
// only the first dot separates.
export const encodeCursor = (ms: number, postKey: string) => b64urlEncode(`${ms}.${postKey}`);
export function decodeCursor(raw: string): { ms: number; key: string } | null {
    const text = b64urlDecode(raw);
    const m = text === null ? null : /^(\d{1,16})\.([\s\S]+)$/.exec(text);
    return m ? { ms: Number(m[1]), key: m[2]! } : null;
}

// migration 0009's columns (section 18.1)
type GalleryCols = { role: string | null; item_index: number | null; made_from: string | null; made_spec: string | null };
type FileRow = MediaRow & GalleryCols & { post_key: string };
type SessionRowLite = {
    id: string;
    status: string;
    service: string | null;
    expires_at: number;
    created_at: number;
    items: string | null;
    post_key: string;
};
const GALLERY_COLUMNS = "role, item_index, made_from, made_spec";

// A JSON column as a value, null when it is not valid JSON (never throws)
const parseJson = (raw: string | null | undefined): unknown => {
    if (raw === null || raw === undefined) return null;
    try {
        return JSON.parse(raw);
    } catch {
        return null;
    }
};
const isStill = (type: string | null) => !!type && type.startsWith("image/") && type !== "image/gif";

// v=3 file order (section 18.3): the items by item_index (a single original with them), then slideshows,
// crops, exports, webps; each group but the items newest first
const v3Rank = (f: FileRow) =>
    f.role === "slideshow" ? 1 : f.role === "crop" ? 2 : f.role === "export" ? 3 : f.role === "item" || (f.bucket === "originals" && isOriginalSource(f.source)) ? 0 : 4;
function sortV3(fs: FileRow[]): FileRow[] {
    return [...fs].sort((a, b) => {
        const ra = v3Rank(a);
        const rb = v3Rank(b);
        if (ra !== rb) return ra - rb;
        if (ra === 0) {
            const ia = a.item_index ?? Number.MAX_SAFE_INTEGER;
            const ib = b.item_index ?? Number.MAX_SAFE_INTEGER;
            if (ia !== ib) return ia - ib;
            return a.created_at - b.created_at || (a.id < b.id ? -1 : 1);
        }
        return b.created_at - a.created_at || (a.id < b.id ? 1 : -1);
    });
}

// The post's lead file: its lead item (first video, else the first item), else its one original.
function leadOf(fs: FileRow[]): FileRow | undefined {
    const items = fs.filter((f) => f.role === "item").sort((a, b) => (a.item_index ?? 0) - (b.item_index ?? 0));
    return items.find((f) => (f.content_type ?? "").startsWith("video/")) ?? items[0] ?? fs.find((f) => f.bucket === "originals" && isOriginalSource(f.source));
}

const placeholders = (n: number, from = 1) => Array.from({ length: n }, (_, i) => `?${i + from}`).join(", ");
const isVideoish = (r: MediaRow) => {
    const t = r.content_type ?? "";
    return t.startsWith("video/") || t === "image/gif" || t === "image/webp";
};

// v=3 (section 18.3), on every post: its kind, how many live items it has and which items the session
// could not save (the indices its `items` record calls an error and no live item row has).
function postGalleryFields(fs: FileRow[], ss: SessionRowLite[], lead: FileRow | undefined) {
    const items = fs.filter((f) => f.role === "item");
    const kind: "video" | "photo" | "gallery" | "webp" =
        items.length >= 2 ? "gallery" : lead ? (isStill(lead.content_type) ? "photo" : "video") : "webp";
    const live = new Set(items.map((f) => f.item_index));
    const failed = new Set<number>();
    for (const s of ss) {
        const rec = parseJson(s.items);
        if (!Array.isArray(rec)) continue;
        for (const e of rec as { i?: unknown; status?: unknown }[]) {
            if (e && e.status === "error" && typeof e.i === "number" && !live.has(e.i)) failed.add(e.i);
        }
    }
    return { kind, item_count: items.length > 0 ? items.length : lead ? 1 : 0, items_failed: [...failed].sort((a, b) => a - b) };
}

// A call that must not hold the response up: it answers null after `ms`.
async function bounded<T>(p: Promise<T>, ms: number): Promise<T | null> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
        return await Promise.race([
            p,
            new Promise<null>((resolve) => {
                timer = setTimeout(() => resolve(null), ms);
            }),
        ]);
    } finally {
        if (timer !== undefined) clearTimeout(timer);
    }
}

// The files of one post as a list entry. v2: one entry per row. Legacy: an original shows `url: null`
// (as before) and each public original is followed by the synthesized host file old apps expect: its
// retired host row's id (`public_id`), the host's time when the pair was merged (so the order within
// the post is the one they always saw), kind 'public', source 'host'.
// What the retired host row of a merged pair recorded (it is the rollback record, and the only place the old
// file's own name, size and time survive).
type Tomb = Pick<MediaRow, "id" | "name" | "content_type" | "bytes" | "width" | "height" | "duration" | "created_at" | "poster">;

export function fileShape(f: FileRow, v2: boolean, v3 = false) {
    const wn = webpName(f);
    const isOrig = f.bucket === "originals" && isOriginalSource(f.source);
    return {
        id: f.id,
        kind: f.kind,
        source: f.source,
        name: f.name,
        url: !v2 && isOrig ? null : f.url,
        content_type: f.content_type,
        bytes: f.bytes,
        width: f.width,
        height: f.height,
        duration: f.duration,
        created_at: f.created_at,
        media_name: wn ?? (f.bucket === "media" ? f.r2_key : null),
        deletable: wn !== null,
        poster_url: f.poster ?? null,
        visibility: effectiveVisibility(f),
        visibility_toggle: toggleable(f),
        // v3 (section 18.3): what the file is in its post
        ...(v3
            ? {
                  role: f.role ?? null,
                  item_index: f.item_index ?? null,
                  made_from: Array.isArray(parseJson(f.made_from)) ? (parseJson(f.made_from) as unknown[]) : [],
                  made_spec: ((v) => (v && typeof v === "object" && !Array.isArray(v) ? v : null))(parseJson(f.made_spec)),
              }
            : {}),
    };
}

function listFiles(fs: FileRow[], v2: boolean, tombs: Map<string, Tomb>, v3 = false) {
    const one = (f: FileRow) => fileShape(f, v2, v3);
    const out: ReturnType<typeof one>[] = fs.map(one);
    if (v2) return out;
    const synth = (o: FileRow): ReturnType<typeof one> => {
        const ext = extOf(o.public_key!);
        const t = tombs.get(o.public_id!);
        return {
            id: o.public_id!,
            kind: "public",
            source: "host",
            // a merged pair lists the host exactly as the old row was; one made by the new code is named after its original
            name: t ? t.name : o.name.toLowerCase().endsWith(`.${ext}`) ? o.name : `${o.name}.${ext}`,
            url: o.url,
            content_type: t ? t.content_type : o.content_type,
            bytes: t ? t.bytes : o.bytes,
            width: t ? t.width : o.width,
            height: t ? t.height : o.height,
            duration: t ? t.duration : o.duration,
            created_at: t ? t.created_at : o.created_at,
            media_name: o.public_key,
            deletable: false,
            poster_url: (t ? t.poster : null) ?? o.poster ?? null,
            visibility: "public",
            visibility_toggle: false,
        };
    };
    const publicOriginals = fs.filter(
        (f) => f.bucket === "originals" && isOriginalSource(f.source) && effectiveVisibility(f) === "public" && f.url && f.public_key && f.public_id,
    );
    // merged pairs go where the host row used to sort (newest first, ties by id descending)
    for (const o of publicOriginals.filter((f) => tombs.has(f.public_id!))) {
        const s = synth(o);
        const at = out.findIndex((e) => e.created_at < s.created_at || (e.created_at === s.created_at && e.id < s.id));
        out.splice(at === -1 ? out.length : at, 0, s);
    }
    // a pair made by the new code has no host row to place: right after its original
    for (const o of publicOriginals.filter((f) => !tombs.has(f.public_id!))) {
        const at = out.findIndex((e) => e.id === o.id);
        out.splice(at + 1, 0, synth(o));
    }
    return out;
}

export async function libraryList(d: AppDeps, q: URLSearchParams): Promise<StudioReply> {
    const bad = () => err(400, "error.library.bad_request");
    let limit = DEFAULT_LIBRARY_LIMIT;
    if (q.has("limit")) {
        const raw = q.get("limit") ?? "";
        if (!/^\d{1,3}$/.test(raw)) return bad();
        limit = Number(raw);
        if (limit < 1 || limit > MAX_LIBRARY_LIMIT) return bad();
    }
    let curMs = Number.MAX_SAFE_INTEGER;
    let curKey = "";
    if (q.has("cursor")) {
        const c = decodeCursor(q.get("cursor") ?? "");
        if (!c) return bad();
        curMs = c.ms;
        curKey = c.key;
    }
    const now = d.now();
    const db = d.db;
    // `v=2` (section 16): one entry per file with its visibility. Without it (old apps, 1.0-1.6) the
    // answer is the legacy shape: a public original is listed as its private file plus a synthesized
    // host file, exactly the pair those builds expect, and a private webp (which they have no word
    // for) is left out.
    // `v=3` (section 18.3, sent by builds with `features.gallery`) is v=2 plus the gallery fields and every file
    // of a gallery post; without it a gallery is its lead item and its webps, nothing made.
    const v3 = q.get("v") === "3";
    const v2 = v3 || q.get("v") === "2";
    const hide =
        (v2 ? "" : ` AND NOT (m.source IN ('webp', 'studio') AND ${visSql("m.")} = 'private')`) + (v3 ? "" : LEGACY_GALLERY_HIDE);

    try {
        // 1. the page of posts: newest file first, ties broken by the post key
        const { results: keys } = await db
            .prepare(
                `WITH f AS (SELECT m.created_at AS created_at, ${POST_KEY_SQL} AS post_key
                            FROM media_items m WHERE m.deleted_at IS NULL${hide})
                 SELECT post_key, MAX(created_at) AS latest FROM f GROUP BY post_key
                 HAVING MAX(created_at) < ?1 OR (MAX(created_at) = ?1 AND post_key < ?2)
                 ORDER BY latest DESC, post_key DESC LIMIT ?3`,
            )
            .bind(curMs, curKey, limit + 1)
            .all<{ post_key: string; latest: number }>();
        const more = keys.length > limit;
        const page = keys.slice(0, limit);

        let files: FileRow[] = [];
        let sessions: SessionRowLite[] = [];
        const titles = new Map<string, string>();
        if (page.length > 0) {
            const marks = placeholders(page.length);
            const binds = page.map((k) => k.post_key);
            // 2. every live file of those posts, and their sessions
            files = (
                await db
                    .prepare(
                        `SELECT * FROM (SELECT ${ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ")}, ${GALLERY_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ")}, ${POST_KEY_SQL} AS post_key
                                        FROM media_items m WHERE m.deleted_at IS NULL${hide})
                         WHERE post_key IN (${marks}) ORDER BY created_at DESC, id DESC`,
                    )
                    .bind(...binds)
                    .all<FileRow>()
            ).results;
            sessions = (
                await db
                    .prepare(
                        `SELECT * FROM (SELECT s.id, s.status, s.service, s.expires_at, s.created_at, s.items,
                                                CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE s.id END AS post_key
                                         FROM studio_sessions s)
                         WHERE post_key IN (${marks}) ORDER BY created_at DESC, id DESC`,
                    )
                    .bind(...binds)
                    .all<SessionRowLite>()
            ).results;
            // 3. the posts' custom titles (section 15); a post with no row has none
            const { results: custom } = await db
                .prepare(`SELECT post_key, title FROM media_titles WHERE post_key IN (${marks})`)
                .bind(...binds)
                .all<{ post_key: string; title: string }>();
            for (const t of custom) titles.set(t.post_key, t.title);
        }

        const filesByPost = new Map<string, FileRow[]>();
        for (const f of files) {
            const list = filesByPost.get(f.post_key) ?? [];
            list.push(f);
            filesByPost.set(f.post_key, list);
        }
        const sessionsByPost = new Map<string, SessionRowLite[]>();
        for (const s of sessions) {
            const list = sessionsByPost.get(s.post_key) ?? [];
            list.push(s);
            sessionsByPost.set(s.post_key, list);
        }

        // legacy only: the retired host row of a merged pair keeps the old file's id and time
        const tombs = new Map<string, Tomb>();
        if (!v2) {
            const pids = files.filter((f) => f.bucket === "originals" && f.visibility === "public" && f.public_id).map((f) => f.public_id!);
            if (pids.length > 0) {
                const { results } = await db
                    .prepare(
                        `SELECT id, name, content_type, bytes, width, height, duration, created_at, poster FROM media_items WHERE id IN (${placeholders(pids.length)}) AND merged_into IS NOT NULL`,
                    )
                    .bind(...pids)
                    .all<Tomb>();
                for (const t of results) tombs.set(t.id, t);
            }
        }

        const api = noSlash(d.apiUrl);
        const posts = page.map((k) => {
            const raw = filesByPost.get(k.post_key) ?? []; // newest first
            const fs = v3 ? sortV3(raw) : raw;
            const ss = sessionsByPost.get(k.post_key) ?? []; // newest first
            const original = leadOf(fs);
            const meta = original ?? fs.find(isVideoish) ?? null;
            const link = original?.link ?? fs.find((f) => f.link)?.link ?? null;
            const open = ss.find((s) => s.expires_at > now && (s.status === "saving" || s.status === "ready")) ?? null;
            const service = ss[0]?.service ?? (link ? serviceFromUrl(link) : null);
            // the post's public link: its original's (section 16), else the newest unmerged host copy's
            const hosted = fs.find((f) => f.kind === "public" && f.source === "host" && f.url);
            return {
                id: k.post_key,
                service,
                link,
                title: meta?.name ?? null,
                // the owner's own title for the post (PATCH .../post), null = none (section 15)
                custom_title: titles.get(k.post_key) ?? null,
                duration: meta?.duration ?? null,
                width: meta?.width ?? null,
                height: meta?.height ?? null,
                // the post's thumbnail: the original's, else any file's (null until made)
                poster_url: original?.poster ?? fs.find((f) => f.poster)?.poster ?? null,
                public_url: original?.url ?? hosted?.url ?? null,
                created_at: k.latest,
                session: open
                    ? {
                          id: open.id,
                          status: open.status,
                          expires_at: open.expires_at,
                          source_url: `${api}/studio/${open.id}/source`,
                      }
                    : null,
                files: listFiles(fs, v2, tombs, v3),
                ...(v2
                    ? {
                          visibility: original
                              ? effectiveVisibility(original)
                              : fs.some((f) => effectiveVisibility(f) === "public")
                                ? "public"
                                : "private",
                      }
                    : {}),
                ...(v3 ? postGalleryFields(fs, ss, original) : {}),
            };
        });

        // A page showing originals that still have no poster (and were not tried in the last
        // day) asks the Durable Object to queue them (section 13); it only writes records, the
        // container wakes in its own sweep. Best effort: the answer never waits for it.
        if (
            d.kickPosters &&
            files.some(
                (f) =>
                    f.bucket === "originals" &&
                    !f.poster &&
                    posterEligible(f) &&
                    (f.poster_at === null || f.poster_at < now - POSTER_COOLDOWN_MS),
            )
        ) {
            await bounded(d.kickPosters().catch(() => null), 1500);
        }

        // totals over the whole library, not the page (a public original is stored twice, so it counts
        // in both byte totals; a file is one row)
        const nFiles = await db
            .prepare(`SELECT COUNT(*) AS n FROM media_items m WHERE m.deleted_at IS NULL${hide}`)
            .first<{ n: number }>();
        const nPosts = await db
            .prepare(
                `SELECT COUNT(DISTINCT ${POST_KEY_SQL}) AS n FROM media_items m WHERE m.deleted_at IS NULL${hide}`,
            )
            .first<{ n: number }>();
        const sums = await db
            .prepare(
                `SELECT COALESCE(SUM(CASE WHEN ${visSql()} = 'public' THEN bytes END), 0) AS pub,
                        COALESCE(SUM(CASE WHEN bucket = 'originals' THEN bytes END), 0) AS priv
                   FROM media_items WHERE deleted_at IS NULL`,
            )
            .first<{ pub: number; priv: number }>();
        const usage = { public_bytes: sums?.pub ?? 0, private_bytes: sums?.priv ?? 0 };

        const last = page[page.length - 1];
        return {
            status: 200,
            body: {
                status: "success",
                posts,
                counts: { posts: nPosts?.n ?? 0, files: nFiles?.n ?? 0 },
                usage,
                next: more && last ? encodeCursor(last.latest, last.post_key) : null,
            },
        };
    } catch (e) {
        console.error("[library] list failed", String(e));
        return err(503, "error.api.generic");
    }
}

// ---- 5b. GET|HEAD /library/items/<id>/file ------------------------------------------------

const jsonResponse = (r: StudioReply, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(r.body), {
        status: r.status,
        headers: { "content-type": "application/json", ...extra },
    });

// A private file's bytes, Range aware like studioSource (studio-edge.ts). Not
// limited by a session's 7 days.
export async function libraryFile(d: AppDeps, id: string, request: Request): Promise<Response> {
    let row: MediaRow | null;
    try {
        row = await getItem(d.db, id);
    } catch {
        return jsonResponse(err(503, "error.api.generic"));
    }
    if (!row) return jsonResponse(err(404, "error.library.not_found"));
    // a public row is served from its own URL
    if (row.bucket !== "originals") return jsonResponse(err(409, "error.library.public"));

    // The size comes from the object, never from the row: a row's `bytes` can be
    // missing (an old backfilled row) or stale, and a HEAD for an object that is
    // gone must not say 200 (nor a Content-Range quote a size the object no
    // longer has).
    let known: Awaited<ReturnType<OriginalsBucket["head"]>>;
    try {
        known = await d.originals.head(row.r2_key);
    } catch {
        return jsonResponse(err(502, "error.library.storage"));
    }
    if (!known) return jsonResponse(err(404, "error.library.missing"));
    const total = known.size;

    // If-Range that no longer matches the object: the whole file, not a stale slice
    const ifRange = request.headers.get("if-range");
    const lastModified = known.uploaded ? known.uploaded.toUTCString() : null;
    const stale = ifRange !== null && ifRange !== known.httpEtag && ifRange !== lastModified;
    const range = parseRange(stale ? null : request.headers.get("range"), total);
    if (range.kind === "unsatisfiable") {
        return jsonResponse(err(416, "error.studio.bad_range"), {
            "content-range": `bytes */${total}`,
            "accept-ranges": "bytes",
        });
    }
    const partial = range.kind === "partial";
    const length = partial ? range.length : total;
    const headers = new Headers({
        "content-type": row.content_type || known.httpMetadata?.contentType || "application/octet-stream",
        "accept-ranges": "bytes",
        "cache-control": "private, max-age=3600",
        "content-length": String(length),
    });
    if (known.httpEtag) headers.set("etag", known.httpEtag);
    if (lastModified) headers.set("last-modified", lastModified);
    if (partial) {
        headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${total}`);
    }
    const status = partial ? 206 : 200;

    if (request.method === "HEAD") return new Response(null, { status, headers });

    let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
    try {
        obj = await d.originals.get(
            row.r2_key,
            partial ? { range: { offset: range.offset, length: range.length } } : undefined,
        );
    } catch {
        return jsonResponse(err(502, "error.library.storage"));
    }
    if (!obj) return jsonResponse(err(404, "error.library.missing"));
    // replaced between the head and the get: a whole file is as long as it is now
    if (!partial && obj.size !== total) headers.set("content-length", String(obj.size));
    return new Response(obj.body, { status, headers });
}

// ---- 5c. POST /library/items/<id>/publish (section 16: the legacy spelling of "make public") -------------

// Makes the file public: the same row, a mirror at its stable public name, so a repeat answers with the
// same link (and nothing is copied twice). `id` may be a public_id (the id old apps know the public
// file by). A webp still in the public bucket, or a legacy host copy, is already public.
export async function libraryPublish(d: AppDeps, id: string, keyId: string = SERVICE_KEY_ID): Promise<StudioReply> {
    let row: MediaRow | null;
    try {
        row = await getItem(d.db, id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return err(404, "error.library.not_found");
    if (row.bucket !== "originals") return err(409, "error.library.already_public");
    return publishOriginal(d, row, keyId);
}

// ---- 16. PATCH /library/items/<id>/visibility ----------------------------------------------------

const MAX_VISIBILITY_BODY_BYTES = 256;

export async function libraryVisibility(
    d: AppDeps,
    id: string,
    request: Request,
    keyId: string = SERVICE_KEY_ID,
): Promise<StudioReply> {
    let text: string | null;
    try {
        text = await readCapped(request, MAX_VISIBILITY_BODY_BYTES);
    } catch {
        text = null;
    }
    let want: boolean | null = null;
    // `scope` (section 18.4): absent / null / "row" = this file; "post" = every file of its post
    let scope: "row" | "post" | null = "row";
    if (text !== null) {
        try {
            const body: unknown = JSON.parse(text);
            if (body && typeof body === "object" && !Array.isArray(body) && typeof (body as { public?: unknown }).public === "boolean") {
                want = (body as { public: boolean }).public;
                const sc = (body as { scope?: unknown }).scope;
                if (sc === "post") scope = "post";
                else if (sc !== undefined && sc !== null && sc !== "row") scope = null;
            }
        } catch {
            // not JSON: bad request below
        }
    }
    if (want === null || scope === null) return err(400, "error.library.bad_request");
    if (scope === "post") return setPostVisibility(d, id, want, keyId);
    return setVisibility(d, id, want, keyId);
}

// ---- 18.4 PATCH /library/items/<id>/visibility with "scope": "post" -------------------------------------

// The file with the gallery columns and its post key (any live row; `id` may be a public_id).
const FILE_COLUMNS = `${ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ")}, ${GALLERY_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ")}, ${POST_KEY_SQL} AS post_key`;
async function getFile(db: D1Database, id: string): Promise<FileRow | null> {
    return (
        (await db
            .prepare(
                `SELECT ${FILE_COLUMNS} FROM media_items m WHERE (m.id = ?1 OR m.public_id = ?1) AND m.deleted_at IS NULL ORDER BY (m.id = ?1) DESC LIMIT 1`,
            )
            .bind(id)
            .first<FileRow>()) ?? null
    );
}
// Every live file of a post (optionally only those of one bucket), in item_index then creation order.
async function postFiles(db: D1Database, postKey: string, bucket?: "originals"): Promise<FileRow[]> {
    return (
        await db
            .prepare(
                `SELECT * FROM (SELECT ${FILE_COLUMNS} FROM media_items m WHERE m.deleted_at IS NULL${bucket ? ` AND m.bucket = '${bucket}'` : ""})
                 WHERE post_key = ?1 ORDER BY COALESCE(item_index, 1000000), created_at, id`,
            )
            .bind(postKey)
            .all<FileRow>()
    ).results;
}

// Applies on/off to every live private-bucket row of the post that is not a switched webp (those keep their own
// switch, section 16), one row at a time as the single toggle does. A row that fails is listed in `remaining`
// with 502 `error.library.partial`; the call is idempotent, so a retry finishes the rest.
async function setPostVisibility(d: AppDeps, id: string, want: boolean, keyId: string): Promise<StudioReply> {
    let anchor: FileRow | null;
    let rows: FileRow[];
    try {
        anchor = await getFile(d.db, id);
        if (!anchor) return err(404, "error.library.not_found");
        rows = (await postFiles(d.db, anchor.post_key, "originals")).filter((r) => webpName(r) === null);
    } catch {
        return err(503, "error.api.generic");
    }
    const remaining: string[] = [];
    let cleared: boolean | null = null;
    for (const r of rows) {
        const res = await setVisibility(d, r.id, want, keyId);
        if (res.status !== 200) {
            remaining.push(r.id);
            continue;
        }
        const c = (res.body as { cache_cleared?: boolean | null }).cache_cleared;
        if (c === false) cleared = false;
        else if (c === true && cleared === null) cleared = true;
    }
    let items: ReturnType<typeof fileShape>[];
    try {
        items = (await postFiles(d.db, anchor.post_key, "originals")).filter((r) => webpName(r) === null).map((r) => fileShape(r, true, true));
    } catch {
        return err(503, "error.api.generic");
    }
    if (remaining.length > 0) {
        return { status: 502, body: { status: "error", error: { code: "error.library.partial" }, items, remaining, cache_cleared: cleared } };
    }
    return { status: 200, body: { status: "success", items, cache_cleared: cleared } };
}

// ---- 16. POST /library/visibility/migrate --------------------------------------------------------

// The data step. Dry run unless dry_run=0; `limit` pairs per call; D1 writes only (R2 is only read).
export async function libraryVisibilityMigrate(d: AppDeps, q: URLSearchParams): Promise<StudioReply> {
    const bad = () => err(400, "error.library.bad_request");
    let dryRun = true;
    if (q.has("dry_run")) {
        const raw = q.get("dry_run");
        if (raw === "0" || raw === "false") dryRun = false;
        else if (raw !== "1" && raw !== "true") return bad();
    }
    let undo = false;
    if (q.has("undo")) {
        const raw = q.get("undo");
        if (raw === "1" || raw === "true") undo = true;
        else if (raw !== "0" && raw !== "false") return bad();
    }
    let limit = DEFAULT_MIGRATE_LIMIT;
    if (q.has("limit")) {
        const raw = q.get("limit") ?? "";
        if (!/^\d{1,3}$/.test(raw)) return bad();
        limit = Number(raw);
        if (limit < 1 || limit > MAX_MIGRATE_LIMIT) return bad();
    }
    return migrateVisibility(d, { dryRun, limit, undo });
}

// ---- 5d. POST /library/items/<id>/studio --------------------------------------------------

// `queue` (`?queue=1`, section 17.3): the adopted session joins the server's line when the helper is
// not free; the answer then also says `queued` and `queue_ahead`.
export async function libraryStudio(d: AppDeps, id: string, keyId: string, queue = false): Promise<StudioReply> {
    let row: MediaRow | null;
    try {
        row = await getItem(d.db, id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return err(404, "error.library.not_found");
    if (row.bucket !== "originals" || row.kind !== "private") return err(409, "error.library.not_private");
    const type = row.content_type ?? "";
    if (!(type.startsWith("video/") || type === "image/gif")) return err(400, "error.studio.not_video");

    // A saved original whose own studio is still open: reopen that studio (its
    // webps stay listed) instead of minting a new one.
    if (row.session_id) {
        try {
            const open = await getSession(d.db, row.session_id);
            if (open && open.status === "ready" && open.expires_at > d.now() && open.r2_key === row.r2_key) {
                return {
                    status: 200,
                    body: {
                        status: "success",
                        id: open.id,
                        url: `${noSlash(d.webUrl)}/studio/${open.id}`,
                        ...(queue ? { queued: false, queue_ahead: null } : {}),
                    },
                };
            }
        } catch {
            return err(503, "error.api.generic");
        }
    }

    // A row with no recorded size (an old backfilled row): the object knows it.
    // (adopt refuses a size of 0 or less.)
    let bytes = row.bytes;
    if (!(typeof bytes === "number" && bytes > 0)) {
        try {
            const head = await d.originals.head(row.r2_key);
            if (!head) return err(404, "error.library.missing");
            bytes = head.size;
        } catch {
            return err(502, "error.library.storage");
        }
    }

    try {
        const a = await d.adopt(keyId, {
            r2_key: row.r2_key,
            name: row.name,
            content_type: type,
            bytes,
            // The id the new session's link carries (`upload:<id>`), which is the
            // post key its renders group under (POST_KEY_SQL). A saved original
            // sits in its post under its own session id, so the reopened studio
            // names that id: its renders then land in the same card instead of
            // splitting the post in two. Anything else is its own post: its item id.
            item_id: row.source === "saved" && row.session_id && /^[A-Za-z0-9]{1,64}$/.test(row.session_id) ? row.session_id : row.id,
            ...(queue ? { queue: true } : {}),
        });
        const b = a.body as {
            status?: string;
            id?: unknown;
            url?: unknown;
            queued?: unknown;
            queue_ahead?: unknown;
            error?: { code?: unknown };
        };
        if (a.status === 201 && b.status === "success" && typeof b.id === "string") {
            return {
                status: 201,
                body: {
                    status: "success",
                    id: b.id,
                    url: typeof b.url === "string" ? b.url : `${noSlash(d.webUrl)}/studio/${b.id}`,
                    ...(queue ? { queued: b.queued === true, queue_ahead: typeof b.queue_ahead === "number" ? b.queue_ahead : null } : {}),
                },
            };
        }
        return err(a.status >= 400 ? a.status : 502, typeof b.error?.code === "string" ? b.error.code : "error.api.generic");
    } catch (e) {
        console.error("[library] adopt failed", String(e));
        return err(503, "error.api.generic");
    }
}

// ---- 5e. DELETE /library/items/<id>/post -------------------------------------------------

// A save or render started this recently and still running blocks the delete; an older
// "pending" row is a lost job and does not.
export const POST_DELETE_BUSY_MS = 15 * 60 * 1000;

// A session's list key: the same grouping GET /library applies to its sessions.
const SESSION_POST_KEY_SQL = "CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE s.id END";

type PostSession = { id: string; status: string; r2_key: string | null; created_at: number };
type PostFile = Pick<MediaRow, "id" | "bucket" | "r2_key" | "bytes" | "poster" | "url" | "public_key">;

// Deletes everything of the post the anchor file belongs to: the anchor is read including
// soft-deleted rows, so the call is idempotent and any file id of the post works. Order
// (each step safe to repeat): expire the post's sessions, delete each live file's R2 object
// and soft-delete its row, then delete the sessions' stored originals.
export async function libraryPostDelete(d: AppDeps, id: string): Promise<StudioReply> {
    const now = d.now();
    let post: string;
    let sessions: PostSession[];
    let files: PostFile[];
    try {
        const anchor = await d.db
            .prepare(`SELECT ${POST_KEY_SQL} AS post_key FROM media_items m WHERE m.id = ?1 OR m.public_id = ?1 ORDER BY (m.id = ?1) DESC LIMIT 1`)
            .bind(id)
            .first<{ post_key: string }>();
        if (!anchor) return err(404, "error.library.not_found");
        post = anchor.post_key;

        sessions = (
            await d.db
                .prepare(
                    `SELECT * FROM (SELECT s.id, s.status, s.r2_key, s.created_at, ${SESSION_POST_KEY_SQL} AS post_key
                                    FROM studio_sessions s)
                     WHERE post_key = ?1 ORDER BY created_at ASC, id ASC`,
                )
                .bind(post)
                .all<PostSession>()
        ).results;

        const since = now - POST_DELETE_BUSY_MS;
        if (sessions.some((s) => s.status === "saving" && s.created_at > since)) {
            return err(409, "error.library.busy");
        }
        const pending = await d.db
            .prepare(
                `SELECT COUNT(*) AS n FROM studio_renders
                 WHERE status = 'pending' AND created_at > ?1 AND session_id IN (
                     SELECT s.id FROM studio_sessions s WHERE ${SESSION_POST_KEY_SQL} = ?2)`,
            )
            .bind(since, post)
            .first<{ n: number }>();
        if ((pending?.n ?? 0) > 0) return err(409, "error.library.busy");

        // 1. no new render or source read can start from here on (they answer 410)
        await d.db
            .prepare(
                `UPDATE studio_sessions SET expires_at = ?1
                 WHERE expires_at > ?1 AND id IN (SELECT s.id FROM studio_sessions s WHERE ${SESSION_POST_KEY_SQL} = ?2)`,
            )
            .bind(now, post)
            .run();

        files = (
            await d.db
                .prepare(
                    `SELECT id, bucket, r2_key, bytes, poster, url, public_key FROM (SELECT m.id, m.bucket, m.r2_key, m.bytes, m.poster, m.url, m.public_key, m.created_at, m.deleted_at,
                                                                   ${POST_KEY_SQL} AS post_key FROM media_items m)
                     WHERE post_key = ?1 AND deleted_at IS NULL ORDER BY created_at ASC, id ASC`,
                )
                .bind(post)
                .all<PostFile>()
        ).results;
    } catch (e) {
        console.error("[library] post delete lookup failed", id, String(e));
        return err(503, "error.api.generic");
    }

    // 2. every live file: the object first, then the row (a row whose object could not be
    // deleted stays live and is reported, so a retry finishes it)
    const deleted = { files: 0, bytes: 0 };
    const remaining: string[] = [];
    const posters = new Set<string>();
    const purged: string[] = [];
    for (const f of files) {
        try {
            await (f.bucket === "media" ? d.media : d.originals).delete(f.r2_key);
            // the public mirror of a private file (section 16) goes with it, the edge copy is purged below
            if (f.public_key) {
                await d.media.delete(f.public_key);
            }
            if (f.url) purged.push(f.url);
            await d.db
                .prepare("UPDATE media_items SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL")
                .bind(now, f.id)
                .run();
            deleted.files += 1;
            deleted.bytes += typeof f.bytes === "number" ? f.bytes : 0;
            if (f.poster) posters.add(f.poster);
        } catch (e) {
            console.error("[library] post delete file failed", f.id, f.bucket, String(e));
            remaining.push(f.id);
        }
    }

    // 2b. the posters of the rows just deleted (section 13): each object goes unless a live row
    // still names it (an original and its public copy share one; a row that stayed live in
    // `remaining` keeps the poster until the retry). A failed delete is logged, not reported.
    for (const url of posters) await releasePoster(d.db, d.media, url);

    // 2c. the public URLs of what was deleted, out of the edge cache (best effort: never changes the answer)
    await purgeUrls(d, purged);

    // 3. a session's stored original that has no row of its own (its session is already
    // expired, so nothing can read it through any route: a failure is logged, not reported)
    for (const s of sessions) {
        if (!s.r2_key) continue;
        try {
            await d.originals.delete(s.r2_key);
        } catch (e) {
            console.error("[library] post delete session original failed", s.id, String(e));
        }
    }

    // 4. the post's custom title (section 15). Only once every file is gone: a post that is
    // still partly live keeps its title until the retry finishes the delete. A failure is
    // logged, not reported (the title row of a post with no live file is invisible).
    if (remaining.length === 0) {
        try {
            await d.db.prepare("DELETE FROM media_titles WHERE post_key = ?1").bind(post).run();
        } catch (e) {
            console.error("[library] post delete title failed", post, String(e));
        }
    }

    if (remaining.length > 0) {
        return {
            status: 502,
            body: { status: "error", error: { code: "error.library.partial" }, post, deleted, remaining },
        };
    }
    return { status: 200, body: { status: "success", post, deleted, remaining } };
}


// ---- 15. PATCH /library/items/<id>/post ------------------------------------------------------

// The rules live in studio.ts (cleanTitle), shared with POST /studio and the upload's `?title=`.
export const MAX_TITLE_CODE_POINTS = TITLE_MAX_CODE_POINTS;
const MAX_TITLE_BODY_BYTES = 1024;

// "valid" carries the cleaned title, null = clear.
export function parseTitle(text: string | null): { ok: true; title: string | null } | { ok: false } {
    if (text === null) return { ok: false };
    let body: unknown;
    try {
        body = JSON.parse(text);
    } catch {
        return { ok: false };
    }
    if (typeof body !== "object" || body === null || Array.isArray(body) || !Object.hasOwn(body, "title")) {
        return { ok: false };
    }
    return cleanTitle((body as { title: unknown }).title);
}

// Sets (or, with null / empty, clears) the custom title of the post the anchor file belongs
// to. The anchor must be a live row; the post key is the one GET /library groups by.
// Idempotent. D1 only: no container, no Durable Object.
export async function libraryPostTitle(
    d: AppDeps,
    id: string,
    request: Request,
    keyId: string = SERVICE_KEY_ID,
): Promise<StudioReply> {
    let text: string | null;
    try {
        text = await readCapped(request, MAX_TITLE_BODY_BYTES);
    } catch {
        text = null; // not UTF-8, or the body broke off
    }
    const parsed = parseTitle(text);
    if (!parsed.ok) return err(400, "error.library.bad_title");
    try {
        const anchor = await d.db
            .prepare(`SELECT ${POST_KEY_SQL} AS post_key FROM media_items m WHERE (m.id = ?1 OR m.public_id = ?1) AND m.deleted_at IS NULL ORDER BY (m.id = ?1) DESC LIMIT 1`)
            .bind(id)
            .first<{ post_key: string }>();
        if (!anchor) return err(404, "error.library.not_found");
        if (parsed.title === null) {
            await d.db.prepare("DELETE FROM media_titles WHERE post_key = ?1").bind(anchor.post_key).run();
        } else {
            await d.db
                .prepare(
                    `INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(post_key) DO UPDATE SET title = excluded.title, key_id = excluded.key_id, updated_at = excluded.updated_at`,
                )
                .bind(anchor.post_key, parsed.title, keyId, d.now())
                .run();
        }
        return { status: 200, body: { status: "success", post: anchor.post_key, title: parsed.title } };
    } catch (e) {
        console.error("[library] set title failed", id, String(e));
        return err(503, "error.api.generic");
    }
}

// ---- 13. POST /library/posters/backfill ------------------------------------------------------

// Queues up to `limit` (default 25, at most 100) saved videos that have no poster yet and were
// not tried in the last day. Only records are written; the container is woken by the sweep.
export async function libraryPostersBackfill(d: AppDeps, limit?: number): Promise<StudioReply> {
    if (!d.kickPosters) return err(503, "error.api.generic");
    try {
        return await d.kickPosters(limit);
    } catch (e) {
        console.error("[library] poster backfill failed", String(e));
        return err(503, "error.api.generic");
    }
}

// ---- 18.4 DELETE /library/items/<id> --------------------------------------------------------------------

// Everything of one live row: its stored object (and the public mirror), the row, an unshared poster, the edge
// copy. The object goes first and the row after it, so a row whose object could not be deleted stays live (the
// caller answers 502 and a retry finishes it). Throws on a storage or D1 failure.
async function removeFile(d: AppDeps, f: FileRow): Promise<{ bytes: number }> {
    await (f.bucket === "media" ? d.media : d.originals).delete(f.r2_key);
    if (f.public_key) await d.media.delete(f.public_key);
    await d.db.prepare("UPDATE media_items SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL").bind(d.now(), f.id).run();
    if (f.poster) await releasePoster(d.db, d.media, f.poster);
    if (f.url) await purgeUrls(d, [f.url]);
    return { bytes: typeof f.bytes === "number" ? f.bytes : 0 };
}

// One item or made file (a slideshow, a crop, an export) of a post. The last live item of a post is not
// deletable here (section 12 deletes the post); a webp or any row without a role keeps its own route.
export async function libraryItemDelete(d: AppDeps, id: string): Promise<StudioReply> {
    let row: FileRow | null;
    try {
        row = await getFile(d.db, id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return err(404, "error.library.not_found");
    if (row.role !== "item" && row.role !== "slideshow" && row.role !== "crop" && row.role !== "export") {
        return err(409, "error.library.not_deletable");
    }
    if (row.role === "item") {
        let others: { n: number } | null;
        try {
            others = await d.db
                .prepare(
                    `SELECT COUNT(*) AS n FROM media_items m WHERE m.deleted_at IS NULL AND m.role = 'item' AND m.id <> ?1 AND ${POST_KEY_SQL} = ?2`,
                )
                .bind(row.id, row.post_key)
                .first<{ n: number }>();
        } catch {
            return err(503, "error.api.generic");
        }
        if ((others?.n ?? 0) === 0) return err(409, "error.library.last_item");
    }
    let deleted: { bytes: number };
    try {
        deleted = await removeFile(d, row);
    } catch (e) {
        console.error("[library] item delete failed", row.id, String(e));
        return err(502, "error.library.storage");
    }
    // the session's original is its lead item: a deleted lead hands that over to the next one
    if (row.role === "item" && row.session_id) {
        try {
            await repointLead(d.db, row.session_id);
        } catch (e) {
            console.error("[library] item delete: moving the lead failed", row.session_id, String(e));
        }
    }
    return { status: 200, body: { status: "success", deleted: { files: 1, bytes: deleted.bytes } } };
}

// ---- 18.6 PUT /library/items/<id>/made -------------------------------------------------------------------

export const MAX_MADE_BYTES = 50 * 1024 * 1024;
export const MAX_MADE_SPEC_BYTES = 512;
const HEAD_BYTES = 128 * 1024;

// The pixel size from a JPEG's start-of-frame marker (null when it is not one).
export function jpegSize(b: Uint8Array): { width: number; height: number } | null {
    if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
    let i = 2;
    while (i + 9 < b.length) {
        if (b[i] !== 0xff) {
            i++;
            continue;
        }
        const m = b[i + 1]!;
        if (m === 0xff) {
            i++;
            continue;
        }
        if (m === 0xd8 || m === 0x01 || m === 0x00 || (m >= 0xd0 && m <= 0xd7)) {
            i += 2;
            continue;
        }
        if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
            return { height: (b[i + 5]! << 8) | b[i + 6]!, width: (b[i + 7]! << 8) | b[i + 8]! };
        }
        i += 2 + ((b[i + 2]! << 8) | b[i + 3]!);
    }
    return null;
}

// A crop or an export (the long image, the PDF) made on the device. Everything that can refuse does so before
// the body is read (and cancels it); the body then goes straight to R2.
export async function libraryMade(
    d: AppDeps,
    id: string,
    request: Request,
    keyId: string,
    q: URLSearchParams,
): Promise<StudioReply> {
    const reject = (status: number, code: string) => {
        void request.body?.cancel().catch(() => {});
        return err(status, code);
    };
    const role = q.get("role");
    if (role !== "crop" && role !== "export") return reject(400, "error.library.bad_request");
    // spec: a URL-encoded JSON object, at most 512 bytes
    const rawSpec = q.get("spec");
    if (rawSpec === null || new TextEncoder().encode(rawSpec).length > MAX_MADE_SPEC_BYTES) return reject(400, "error.library.bad_request");
    let spec: Record<string, unknown>;
    try {
        const parsed: unknown = JSON.parse(rawSpec);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return reject(400, "error.library.bad_request");
        spec = parsed as Record<string, unknown>;
    } catch {
        return reject(400, "error.library.bad_request");
    }
    // the type the body must have: a crop and the long image are JPEGs, the PDF is a PDF
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    let ext: "jpg" | "pdf";
    if (role === "crop") {
        if (type !== "image/jpeg") return reject(400, "error.library.bad_request");
        ext = "jpg";
    } else if (spec.kind === "long" && type === "image/jpeg") {
        ext = "jpg";
    } else if (spec.kind === "pdf" && type === "application/pdf") {
        ext = "pdf";
    } else {
        return reject(400, "error.library.bad_request");
    }
    const declared = request.headers.get("content-length");
    if (declared === null || !/^\d{1,15}$/.test(declared)) return reject(400, "error.library.bad_request");
    const size = Number(declared);
    if (size > MAX_MADE_BYTES) return reject(413, "error.studio.too_large");
    if (size === 0 || !request.body) return reject(400, "error.library.bad_request");
    const rawName = q.get("name");
    const name = rawName !== null ? cleanName(rawName, ext) : `${role}.${ext}`;

    let anchor: FileRow | null;
    try {
        anchor = await getFile(d.db, id);
    } catch {
        return reject(503, "error.api.generic");
    }
    if (!anchor) return reject(404, "error.library.not_found");
    if (role === "crop") {
        const photo = anchor.role === "item" || (anchor.role === null && isOriginalSource(anchor.source));
        if (!photo || !isStill(anchor.content_type)) return reject(409, "error.library.not_photo");
    }

    const newId = mintItemId(d.randomBytes);
    const key = `made/${newId}.${ext}`;
    const now = d.now();
    // straight from the request to R2: the body has a known length, nothing is buffered
    let obj: { size: number } | null;
    try {
        obj = await d.originals.put(key, request.body, {
            httpMetadata: { contentType: type },
            customMetadata: { keyId, source: "made", role, createdAt: String(now) },
        });
    } catch (e) {
        console.error("[made] R2 put failed", String(e));
        await d.originals.delete(key).catch(() => {});
        return err(503, "error.api.generic");
    }
    if (!obj || obj.size !== size) {
        await d.originals.delete(key).catch(() => {});
        return err(400, "error.library.bad_request");
    }

    // the head of what was stored: it must be what the headers said, and a JPEG tells its size
    let width: number | null = null;
    let height: number | null = null;
    try {
        const stored = await d.originals.get(key, { range: { offset: 0, length: HEAD_BYTES } });
        if (stored) {
            const head = new Uint8Array(await new Response(stored.body).arrayBuffer());
            if (ext === "jpg") {
                if (head[0] !== 0xff || head[1] !== 0xd8) {
                    await d.originals.delete(key).catch(() => {});
                    return err(400, "error.library.bad_request");
                }
                const dim = jpegSize(head);
                width = dim?.width ?? null;
                height = dim?.height ?? null;
            } else if (new TextDecoder().decode(head.subarray(0, 5)) !== "%PDF-") {
                await d.originals.delete(key).catch(() => {});
                return err(400, "error.library.bad_request");
            }
        }
    } catch (e) {
        // the size is a nicety: the row is written without it
        console.error("[made] reading the head failed", String(e));
    }

    // an export lists the photos of the post at this moment; a crop, the photo it was cut from
    let madeFrom: string[] = [anchor.id];
    let postRows: FileRow[] = [];
    try {
        postRows = await postFiles(d.db, anchor.post_key);
        if (role === "export") {
            madeFrom = postRows
                .filter((f) => (f.role === "item" || (f.role === null && isOriginalSource(f.source))) && isStill(f.content_type))
                .map((f) => f.id);
        }
    } catch (e) {
        console.error("[made] reading the post failed", String(e));
        await d.originals.delete(key).catch(() => {});
        return err(503, "error.api.generic");
    }
    try {
        await d.db
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, visibility, role, made_from, made_spec, post_key)
                 VALUES (?1, 'private', 'made', 'originals', ?2, NULL, ?3, ?4, ?5, ?6, ?7, NULL, ?8, ?9, ?10, ?11, 'private', ?12, ?13, ?14, ?15)`,
            )
            .bind(newId, key, name, type, size, width, height, anchor.link, anchor.session_id, keyId, now, role, JSON.stringify(madeFrom), JSON.stringify(spec), anchor.post_key)
            .run();
    } catch (e) {
        console.error("[made] media_items insert failed", String(e));
        await d.originals.delete(key).catch(() => {});
        return err(503, "error.api.generic");
    }

    // the post's visibility is its lead item's: a new file of a public post is public too (best effort: a failure
    // leaves it private, which the owner's switch can still fix)
    try {
        const lead = leadOf(postRows);
        if (lead && effectiveVisibility(lead) === "public") {
            const fresh = await getRow(d.db, newId);
            if (fresh) await makePublic(d, fresh, keyId);
        }
    } catch (e) {
        console.error("[made] making the new file public failed", newId, String(e));
    }

    // one export of a kind per post: the earlier one goes once the new one is stored
    const replaced: string[] = [];
    if (role === "export") {
        try {
            const old = postRows.filter((f) => f.role === "export" && f.id !== newId && (parseJson(f.made_spec) as { kind?: unknown } | null)?.kind === spec.kind);
            for (const f of old) {
                try {
                    await removeFile(d, f);
                    replaced.push(f.id);
                } catch (e) {
                    console.error("[made] replacing the earlier export failed", f.id, String(e));
                }
            }
        } catch (e) {
            console.error("[made] replacing the earlier export failed", String(e));
        }
    }

    // a JPEG gets a poster (queued in the Durable Object; the answer never waits for it)
    if (ext === "jpg" && d.kickPosters) await bounded(d.kickPosters().catch(() => null), 1500);

    let item: ReturnType<typeof fileShape> | null = null;
    try {
        const fresh = await getFile(d.db, newId);
        item = fresh ? fileShape(fresh, true, true) : null;
    } catch {
        // the row is stored: the answer below still carries its id
    }
    return { status: 201, body: { status: "success", item, replaced } };
}
