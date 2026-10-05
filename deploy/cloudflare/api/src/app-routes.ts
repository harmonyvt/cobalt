// The routes the native app needs (APP-API-CONTRACT.md): capability discovery,
// upload with an API key, and the library with an API key. All of them are
// answered by the Worker from D1 and R2 (the container is never woken); the
// only Durable Object call is the internal adopt path a video upload continues
// into. Free of Cloudflare imports (like studio-edge.ts and publish.ts), so it
// runs under plain node in the tests.
//
//   GET  /capabilities                       what this server can do + the key's state
//   PUT  /studio/upload?name=                a file into R2 + library (+ a studio session)
//   GET  /library                            the library grouped into posts
//   GET|HEAD /library/items/<id>/file        a private file's bytes (Range aware)
//   POST /library/items/<id>/publish         host a private file publicly
//   POST /library/items/<id>/studio          open a studio session for a private video
//   DELETE /library/items/<id>/post          delete a whole post: every file and its sessions (section 12)

// Read at bundle time from upstream's package.json (reading is fine, editing is
// not); the fork's Worker bundles this one field.
import { version as apiVersion } from "../../../../api/package.json";

import { randomBase62 } from "./ids";
import { lookupKey } from "./keys";
import { MEDIA_NAME_REGEX } from "./gate";
import { SERVICE_KEY_ID, mintItemId, pageLink, releasePoster } from "./library";
import { POSTER_COOLDOWN_MS, isPosterType } from "./poster";
import type { PublishBucket } from "./publish";
import {
    MAX_RENDER_SECONDS,
    MAX_SOURCE_BYTES,
    MIN_RENDER_SECONDS,
    RENDER_FPS,
    RENDER_QUALITIES,
    RENDER_WIDTHS,
    SESSION_TTL_MS,
    getSession,
    parseRange,
    studioErr,
    type OriginalsBucket,
    type StudioReply,
} from "./studio";
import { MEDIA_NAME_LENGTH, serviceFromUrl } from "./webp";

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
};

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const noSlash = (u: string) => u.replace(/\/+$/, "");

// ---- media_items rows ---------------------------------------------------------

type MediaRow = {
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
};

const ITEM_COLUMNS =
    "id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, poster_at";

// The web Worker's itemShape (web/src/library.ts), so both clients see one item.
export const itemShape = (r: MediaRow) => ({
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
});

async function getItem(db: D1Database, id: string): Promise<MediaRow | null> {
    return (
        (await db
            .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id = ?1 AND deleted_at IS NULL`)
            .bind(id)
            .first<MediaRow>()) ?? null
    );
}

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
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, key_id, created_at)
                 VALUES (?1, 'private', 'upload', 'originals', ?2, NULL, ?3, ?4, ?5, ?6, ?7)`,
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

    // A video (or gif) continues into a studio session through the same adopt
    // path as a pasted link's session. Images stop here (the app offers to host
    // them as they are, route 5c).
    let sid: string | null = null;
    let url: string | null = null;
    let studioError: { code: string } | null = null;
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
            });
            const b = a.body as { status?: string; id?: unknown; url?: unknown; error?: { code?: unknown } };
            if (a.status === 201 && b.status === "success" && typeof b.id === "string") {
                sid = b.id;
                url = typeof b.url === "string" ? b.url : `${noSlash(d.webUrl)}/studio/${b.id}`;
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
        },
    };
}

// ---- 5a. GET /library -----------------------------------------------------------------------

// One card per post: the owner's COALESCE(session_id, link, id), refined so an
// upload and the renders made from it (whose session's link is "upload:<item id>")
// land in one card.
const POST_KEY_SQL = `COALESCE(
    (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
    m.session_id, m.link, m.id)`;

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

type FileRow = MediaRow & { post_key: string };
type SessionRowLite = {
    id: string;
    status: string;
    service: string | null;
    expires_at: number;
    created_at: number;
    post_key: string;
};

const placeholders = (n: number, from = 1) => Array.from({ length: n }, (_, i) => `?${i + from}`).join(", ");
const isVideoish = (r: MediaRow) => {
    const t = r.content_type ?? "";
    return t.startsWith("video/") || t === "image/gif" || t === "image/webp";
};

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

    try {
        // 1. the page of posts: newest file first, ties broken by the post key
        const { results: keys } = await db
            .prepare(
                `WITH f AS (SELECT m.created_at AS created_at, ${POST_KEY_SQL} AS post_key
                            FROM media_items m WHERE m.deleted_at IS NULL)
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
        if (page.length > 0) {
            const marks = placeholders(page.length);
            const binds = page.map((k) => k.post_key);
            // 2. every live file of those posts, and their sessions
            files = (
                await db
                    .prepare(
                        `SELECT * FROM (SELECT ${ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ")}, ${POST_KEY_SQL} AS post_key
                                        FROM media_items m WHERE m.deleted_at IS NULL)
                         WHERE post_key IN (${marks}) ORDER BY created_at DESC, id DESC`,
                    )
                    .bind(...binds)
                    .all<FileRow>()
            ).results;
            sessions = (
                await db
                    .prepare(
                        `SELECT * FROM (SELECT s.id, s.status, s.service, s.expires_at, s.created_at,
                                                CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE s.id END AS post_key
                                         FROM studio_sessions s)
                         WHERE post_key IN (${marks}) ORDER BY created_at DESC, id DESC`,
                    )
                    .bind(...binds)
                    .all<SessionRowLite>()
            ).results;
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

        const api = noSlash(d.apiUrl);
        const posts = page.map((k) => {
            const fs = filesByPost.get(k.post_key) ?? []; // newest first
            const ss = sessionsByPost.get(k.post_key) ?? []; // newest first
            const original = fs.find((f) => f.bucket === "originals" && (f.source === "saved" || f.source === "upload"));
            const meta = original ?? fs.find(isVideoish) ?? null;
            const link = original?.link ?? fs.find((f) => f.link)?.link ?? null;
            const open = ss.find((s) => s.expires_at > now && (s.status === "saving" || s.status === "ready")) ?? null;
            const service = ss[0]?.service ?? (link ? serviceFromUrl(link) : null);
            // the hosted original (section 13): the newest public copy of the post's video
            const hosted = fs.find((f) => f.kind === "public" && f.source === "host" && f.url);
            return {
                id: k.post_key,
                service,
                link,
                title: meta?.name ?? null,
                duration: meta?.duration ?? null,
                width: meta?.width ?? null,
                height: meta?.height ?? null,
                // the post's thumbnail: the original's, else any file's (null until made)
                poster_url: original?.poster ?? fs.find((f) => f.poster)?.poster ?? null,
                public_url: hosted?.url ?? null,
                created_at: k.latest,
                session: open
                    ? {
                          id: open.id,
                          status: open.status,
                          expires_at: open.expires_at,
                          source_url: `${api}/studio/${open.id}/source`,
                      }
                    : null,
                files: fs.map((f) => ({
                    id: f.id,
                    kind: f.kind,
                    source: f.source,
                    name: f.name,
                    url: f.url,
                    content_type: f.content_type,
                    bytes: f.bytes,
                    width: f.width,
                    height: f.height,
                    duration: f.duration,
                    created_at: f.created_at,
                    media_name: f.bucket === "media" ? f.r2_key : null,
                    deletable: f.bucket === "media" && MEDIA_NAME_REGEX.test(f.r2_key),
                    poster_url: f.poster ?? null,
                })),
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
                    isPosterType(f.content_type) &&
                    (f.poster_at === null || f.poster_at < now - POSTER_COOLDOWN_MS),
            )
        ) {
            await bounded(d.kickPosters().catch(() => null), 1500);
        }

        // totals over the whole library, not the page
        const nFiles = await db
            .prepare("SELECT COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL")
            .first<{ n: number }>();
        const nPosts = await db
            .prepare(
                `SELECT COUNT(DISTINCT ${POST_KEY_SQL}) AS n FROM media_items m WHERE m.deleted_at IS NULL`,
            )
            .first<{ n: number }>();
        const usage = { public_bytes: 0, private_bytes: 0 };
        const { results: sums } = await db
            .prepare(
                "SELECT kind, COALESCE(SUM(bytes), 0) AS total FROM media_items WHERE deleted_at IS NULL GROUP BY kind",
            )
            .all<{ kind: string; total: number }>();
        for (const s of sums) {
            if (s.kind === "public") usage.public_bytes = s.total;
            else if (s.kind === "private") usage.private_bytes = s.total;
        }

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

    const range = parseRange(request.headers.get("range"), total);
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

// ---- 5c. POST /library/items/<id>/publish -------------------------------------------------

// Copies an R2 object's body into the public bucket chunk by chunk. A manual
// reader/writer loop into a FixedLengthStream: ReadableStream.pipeTo() between
// streams is not implemented in the Workers runtime (it hung a put until the
// Durable Object died, 2026-10-01).
async function copyToMedia(
    d: AppDeps,
    from: { body: ReadableStream; size: number },
    to: string,
    contentType: string,
    customMetadata: Record<string, string>,
): Promise<void> {
    const { readable, writable } = d.fixedLength(from.size);
    // Start the put first so the readable side is being consumed while we write.
    const put = d.media.put(to, readable, {
        httpMetadata: { contentType, cacheControl: "public, max-age=31536000, immutable" },
        customMetadata,
    });
    // If the put fails early nothing reads the readable side and a pending
    // write would wait forever: race every write against the put failing.
    const failed = new Promise<never>((_, reject) => {
        put.then(() => {}, reject);
    });
    failed.catch(() => {});
    const writer = writable.getWriter();
    const reader = from.body.getReader();
    try {
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            const w = writer.write(value);
            w.catch(() => {});
            await Promise.race([w, failed]);
        }
        const closed = writer.close();
        closed.catch(() => {});
        await Promise.race([closed, failed]);
    } catch (e) {
        reader.cancel().catch(() => {});
        writer.abort(e).catch(() => {});
        put.catch(() => {});
        throw e;
    }
    await put;
}

export async function libraryPublish(d: AppDeps, id: string, keyId: string = SERVICE_KEY_ID): Promise<StudioReply> {
    let row: MediaRow | null;
    try {
        row = await getItem(d.db, id);
    } catch {
        return err(503, "error.api.generic");
    }
    if (!row) return err(404, "error.library.not_found");
    if (row.kind !== "private" || row.bucket !== "originals") return err(409, "error.library.already_public");

    let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
    try {
        obj = await d.originals.get(row.r2_key);
    } catch {
        return err(502, "error.library.storage");
    }
    if (!obj) return err(404, "error.library.missing");

    const ext = /\.([0-9A-Za-z]{1,8})$/.exec(row.r2_key)?.[1]?.toLowerCase() ?? "bin";
    const name = `${randomBase62(MEDIA_NAME_LENGTH, d.randomBytes)}.${ext}`;
    const contentType = row.content_type ?? obj.httpMetadata?.contentType ?? "application/octet-stream";
    const now = d.now();
    try {
        await copyToMedia(d, obj, name, contentType, {
            keyId,
            source: (pageLink(row.link) ?? "").slice(0, 1000),
            sessionId: row.session_id ?? "",
            createdAt: String(now),
            published: "1",
        });
    } catch (e) {
        console.error("[library] publish copy failed", id, String(e));
        await obj.body.cancel().catch(() => {});
        return err(502, "error.library.storage");
    }

    const itemId = mintItemId(d.randomBytes);
    const url = withSlash(d.mediaBaseUrl) + name;
    try {
        await d.db
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster)
                 VALUES (?1, 'public', 'host', 'media', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)`,
            )
            .bind(
                itemId,
                name,
                url,
                row.name,
                contentType,
                obj.size,
                row.width,
                row.height,
                row.duration,
                row.link,
                row.session_id,
                keyId,
                now,
                // the public copy shares the original's poster (section 13)
                row.poster,
            )
            .run();
    } catch (e) {
        console.error("[library] publish row failed", id, String(e));
        await d.media.delete(name).catch(() => {});
        return err(503, "error.api.generic");
    }
    return {
        status: 201,
        body: { status: "success", url, bytes: obj.size, content_type: contentType, item_id: itemId },
    };
}

// ---- 5d. POST /library/items/<id>/studio --------------------------------------------------

export async function libraryStudio(d: AppDeps, id: string, keyId: string): Promise<StudioReply> {
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
                    body: { status: "success", id: open.id, url: `${noSlash(d.webUrl)}/studio/${open.id}` },
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
        });
        const b = a.body as { status?: string; id?: unknown; url?: unknown; error?: { code?: unknown } };
        if (a.status === 201 && b.status === "success" && typeof b.id === "string") {
            return {
                status: 201,
                body: {
                    status: "success",
                    id: b.id,
                    url: typeof b.url === "string" ? b.url : `${noSlash(d.webUrl)}/studio/${b.id}`,
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
type PostFile = Pick<MediaRow, "id" | "bucket" | "r2_key" | "bytes" | "poster">;

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
            .prepare(`SELECT ${POST_KEY_SQL} AS post_key FROM media_items m WHERE m.id = ?1`)
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
                    `SELECT id, bucket, r2_key, bytes, poster FROM (SELECT m.id, m.bucket, m.r2_key, m.bytes, m.poster, m.created_at, m.deleted_at,
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
    for (const f of files) {
        try {
            await (f.bucket === "media" ? d.media : d.originals).delete(f.r2_key);
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

    if (remaining.length > 0) {
        return {
            status: 502,
            body: { status: "error", error: { code: "error.library.partial" }, post, deleted, remaining },
        };
    }
    return { status: 200, body: { status: "success", post, deleted, remaining } };
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
