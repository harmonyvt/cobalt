// cobalt library: the page (GET /library) and its JSON API (/api/library*),
// served by the web Worker. See ../../LIBRARY-CONTRACT.md (pinned).
//
// Every route needs the owner's Cloudflare Access JWT, verified by the same
// code as /api/keys; POST/PUT/DELETE also need Origin = WEB_ORIGIN. The browser
// never holds an API key: this Worker calls the API Worker over a service
// binding with the internal key in `x-cobalt-service`.
//
// Uploads hand request.body (known content-length) straight to R2. Public/private is the
// API Worker's job (PATCH /library/items/<id>/visibility, apple/CONTRACT-VISIBILITY.md
// decision 12): this Worker relays the toggle and never copies public files itself.
import { verifyAccessJwt, type AccessConfig } from "./access";
import { jwksFor, type Deps, type Env } from "./keys";
import { LIBRARY_HTML } from "./library/page.generated";

export const API_BASE = "https://api.capybaraharmony.com";
export const MAX_UPLOAD_BYTES = 100_000_000;
export const MAX_PAGE = 100;
export const DEFAULT_PAGE = 48;
export const MAX_WAIT = 25;
const MAX_LINK_CHARS = 2048;
const MAX_NAME_CHARS = 120;
const MAX_BODY_BYTES = 8192;

// Pinned by LIBRARY-CONTRACT.md: like the studio page, plus same-origin API
// calls and media/images from the public bucket.
export const LIBRARY_CSP =
    "default-src 'self'; base-uri 'none'; " +
    "connect-src 'self' https://api.capybaraharmony.com; " +
    "media-src 'self' https://media.capybaraharmony.com blob:; " +
    "img-src 'self' data: blob: https://media.capybaraharmony.com; " +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

export const libraryHeaders = (): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": LIBRARY_CSP,
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
});

// Allowed uploads: content type -> stored extension.
export const UPLOAD_TYPES: Record<string, string> = {
    "image/gif": "gif",
    "image/webp": "webp",
    "image/png": "png",
    "image/jpeg": "jpg",
    "video/mp4": "mp4",
    "video/quicktime": "mov",
    "image/heic": "heic",
};

export type LibraryDeps = Deps & {
    randomId?: (n: number) => string;
};

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
    // migration 0006 (APP-API-CONTRACT.md section 13): the server-made thumbnail's public URL
    poster: string | null;
    poster_at: number | null;
    // migration 0008 (apple/CONTRACT-VISIBILITY.md section 2): NULL = not migrated yet, read through
    // VISIBILITY_SQL. public_key = the originals row's public mirror in cobalt-media (kept while private).
    visibility: string | null;
    public_key: string | null;
};

const ITEM_COLUMNS =
    "id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, poster_at, visibility, public_key";

// The one visibility rule every reader uses: an explicit value, else where the bytes live
// (media bucket = public, originals = private).
const VISIBILITY_SQL = "COALESCE(visibility, CASE bucket WHEN 'media' THEN 'public' ELSE 'private' END)";

// A row whose poster could not be made is not tried again for this long (API side: src/poster.ts).
export const POSTER_COOLDOWN_MS = 24 * 60 * 60 * 1000;
const POSTER_NAME = /^[A-Za-z0-9]{10}\.jpg$/;
// Videos and gifs have a frame to show; everything else is its own picture (or none).
const hasPosterFrame = (t: string | null) => !!t && (t.startsWith("video/") || t === "image/gif");

// One card per post, as GET /library on the API groups them (api/src/app-routes.ts POST_KEY_SQL):
// an upload and the renders of its adopted session share a key. Custom titles (migration 0007,
// APP-API-CONTRACT.md section 15) are keyed by it. Since migration 0009 (section 18.1) a row that names
// its post (`post_key`: a gallery item, a slideshow, a crop, an export) says so first.
const POST_KEY_SQL = `COALESCE(
    m.post_key,
    (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
    m.session_id, m.link, m.id)`;

export const visibilityOf = (r: Pick<MediaRow, "visibility" | "bucket">): "public" | "private" =>
    (r.visibility ?? (r.bucket === "media" ? "public" : "private")) === "public" ? "public" : "private";

// Who gets the public/private switch (same rule as the API's toggleable(), api/src/visibility.ts):
// every row whose canonical bytes are private (originals, and a webp that was switched private), and
// a webp made by this app in the public bucket (<10 base62>.webp). Never a legacy `host` row.
const MEDIA_WEBP_NAME = /^[A-Za-z0-9]{10}\.webp$/;
export const toggleable = (r: Pick<MediaRow, "bucket" | "source" | "r2_key">): boolean =>
    r.bucket === "originals" ||
    (r.bucket === "media" && (r.source === "webp" || r.source === "studio") && MEDIA_WEBP_NAME.test(r.r2_key));

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
    poster_url: r.poster ?? null,
    // one tile per file; the switch is on originals and webps (not legacy host rows)
    visibility: visibilityOf(r),
    visibility_toggle: toggleable(r),
});

const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json",
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
            ...extra,
        },
    });

const err = (status: number, code: string, extra?: Record<string, string>) =>
    json(status, { status: "error", error: { code } }, extra);

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export function base62(n: number): string {
    let out = "";
    const buf = new Uint8Array(n * 2);
    while (out.length < n) {
        crypto.getRandomValues(buf);
        for (const b of buf) {
            if (b < 248 && out.length < n) out += BASE62[b % 62]; // 248 = 62 * 4: no modulo bias
        }
    }
    return out;
}

type Route =
    | { name: "page" }
    | { name: "list" }
    | { name: "link" }
    | { name: "upload" }
    | { name: "webp"; id: string }
    | { name: "studio"; id: string }
    | { name: "studioPublish"; id: string }
    | { name: "itemPublish"; id: string }
    | { name: "itemPrivate"; id: string }
    | { name: "itemStudio"; id: string }
    | { name: "itemDelete"; id: string }
    | { name: "studioDelete"; id: string };

const ALLOWED: Record<Route["name"], string[]> = {
    page: ["GET", "HEAD"],
    list: ["GET"],
    link: ["POST"],
    upload: ["PUT"],
    webp: ["GET"],
    studio: ["GET"],
    studioPublish: ["POST"],
    itemPublish: ["POST"],
    itemPrivate: ["POST"],
    itemStudio: ["POST"],
    itemDelete: ["DELETE"],
    studioDelete: ["DELETE"],
};

export function matchRoute(pathname: string): Route | null {
    if (pathname === "/library") return { name: "page" };
    if (pathname === "/api/library") return { name: "list" };
    if (pathname === "/api/library/link") return { name: "link" };
    if (pathname === "/api/library/upload") return { name: "upload" };
    let m: RegExpExecArray | null;
    if ((m = /^\/api\/library\/webp\/([0-9A-Za-z]{16,32})$/.exec(pathname))) return { name: "webp", id: m[1]! };
    if ((m = /^\/api\/library\/studio\/([0-9A-Za-z]{22})$/.exec(pathname))) return { name: "studio", id: m[1]! };
    if ((m = /^\/api\/library\/studio\/([0-9A-Za-z]{22})\/publish$/.exec(pathname))) return { name: "studioPublish", id: m[1]! };
    if ((m = /^\/api\/library\/items\/([0-9A-Za-z]{16})\/publish$/.exec(pathname))) return { name: "itemPublish", id: m[1]! };
    if ((m = /^\/api\/library\/items\/([0-9A-Za-z]{16})\/private$/.exec(pathname))) return { name: "itemPrivate", id: m[1]! };
    if ((m = /^\/api\/library\/items\/([0-9A-Za-z]{16})\/studio$/.exec(pathname))) return { name: "itemStudio", id: m[1]! };
    if ((m = /^\/api\/library\/items\/([0-9A-Za-z]{16})$/.exec(pathname))) return { name: "itemDelete", id: m[1]! };
    if ((m = /^\/api\/library\/studios\/([0-9A-Za-z]{22})$/.exec(pathname))) return { name: "studioDelete", id: m[1]! };
    return null;
}

export async function handleLibrary(request: Request, env: Env, deps?: Partial<LibraryDeps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = {
        teamDomain: env.ACCESS_TEAM_DOMAIN,
        aud: env.ACCESS_AUD,
        ownerEmail: env.OWNER_EMAIL,
    };

    // 1. Authenticate, failing closed on any problem (JWKS outage included).
    const auth = await verifyAccessJwt(request.headers.get("Cf-Access-Jwt-Assertion"), access, jwks, now());
    if (!auth.ok) return err(401, "unauthorized");

    // 2. Route shape and method before the CSRF check.
    const { pathname, searchParams } = new URL(request.url);
    const route = matchRoute(pathname);
    if (!route) return err(404, "error.library.not_found");
    const allowed = ALLOWED[route.name];
    if (!allowed.includes(request.method)) {
        return err(405, "error.library.method", { allow: allowed.join(", ") });
    }

    // 3. CSRF: state-changing calls must come from the web app itself.
    if (request.method !== "GET" && request.method !== "HEAD" && request.headers.get("Origin") !== env.WEB_ORIGIN) {
        return err(403, "forbidden");
    }

    const ctx: Ctx = { env, deps: { ...deps, now, jwks }, now: now() };
    try {
        switch (route.name) {
            case "page":
                return new Response(request.method === "HEAD" ? null : LIBRARY_HTML, { status: 200, headers: libraryHeaders() });
            case "list":
                return await list(ctx, searchParams);
            case "link":
                return await link(ctx, request);
            case "upload":
                return await upload(ctx, request, searchParams);
            case "webp":
                return await relayGet(ctx, `/webp/${route.id}`, searchParams, true);
            case "studio":
                return await relayGet(ctx, `/studio/${route.id}`, searchParams, false);
            case "studioPublish":
                return await relayPost(ctx, `/studio/${route.id}/publish`, undefined, (b) => b);
            case "itemPublish":
                return await setVisibility(ctx, route.id, true);
            case "itemPrivate":
                return await setVisibility(ctx, route.id, false);
            case "itemStudio":
                return await itemStudio(ctx, route.id);
            case "itemDelete":
                return await itemDelete(ctx, route.id);
            case "studioDelete":
                return await studioDelete(ctx, route.id);
        }
    } catch {
        return err(500, "error.library.server");
    }
}

type Ctx = { env: Env; deps: Partial<LibraryDeps>; now: number };

const isObject = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

const isJson = (request: Request) =>
    (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() === "application/json";

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
    if (!isJson(request)) return null;
    const declared = Number(request.headers.get("content-length") ?? 0);
    if (declared > MAX_BODY_BYTES) return null;
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return null;
    try {
        const body = JSON.parse(text);
        return isObject(body) ? body : null;
    } catch {
        return null;
    }
}

const intParam = (v: string | null): number | null =>
    v !== null && /^\d{1,16}$/.test(v) ? Number(v) : null;

// ---------- GET /api/library ----------

type StudioRow = {
    id: string;
    status: string;
    link: string | null;
    title: string | null;
    duration: number | null;
    poster: string | null;
    renders: number;
    created_at: number;
    expires_at: number;
};

const FILTERS = ["all", "public", "private", "studio"];

async function list(ctx: Ctx, q: URLSearchParams): Promise<Response> {
    const filter = q.get("filter") ?? "all";
    if (!FILTERS.includes(filter)) return err(400, "error.library.bad_request");
    let limit = DEFAULT_PAGE;
    if (q.has("limit")) {
        const n = intParam(q.get("limit"));
        if (n === null || n < 1 || n > MAX_PAGE) return err(400, "error.library.bad_request");
        limit = n;
    }
    let before = Number.MAX_SAFE_INTEGER;
    if (q.has("before")) {
        const n = intParam(q.get("before"));
        if (n === null || n < 1) return err(400, "error.library.bad_request");
        before = n;
    }
    const { DB } = ctx.env;

    type Entry =
        | { t: "item"; created_at: number; id: string; row: MediaRow }
        | { t: "studio"; created_at: number; id: string; row: StudioRow };
    const entries: Entry[] = [];

    if (filter !== "studio") {
        // public/private filter on the file's visibility (the toggle), not on kind
        const vis = filter === "all" ? null : filter;
        const { results } = await DB.prepare(
            `SELECT ${ITEM_COLUMNS} FROM media_items
             WHERE deleted_at IS NULL AND created_at < ?1 AND (?2 IS NULL OR ${VISIBILITY_SQL} = ?2)
             ORDER BY created_at DESC, id DESC LIMIT ?3`,
        )
            .bind(before, vis, limit + 1)
            .all<MediaRow>();
        for (const row of results) entries.push({ t: "item", created_at: row.created_at, id: row.id, row });
    }
    if (filter === "all" || filter === "studio") {
        const { results } = await DB.prepare(
            `SELECT s.id, s.status, s.link, s.title, s.duration, s.poster, s.created_at, s.expires_at,
                    (SELECT COUNT(*) FROM studio_renders r WHERE r.session_id = s.id AND r.status = 'success') AS renders
             FROM studio_sessions s
             WHERE s.expires_at > ?1 AND s.status IN ('saving', 'ready') AND s.created_at < ?2
             ORDER BY s.created_at DESC, s.id DESC LIMIT ?3`,
        )
            .bind(ctx.now, before, limit + 1)
            .all<StudioRow>();
        for (const row of results) entries.push({ t: "studio", created_at: row.created_at, id: row.id, row });
    }

    entries.sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
    const more = entries.length > limit;
    const page = entries.slice(0, limit);

    // public = every live public file; private = every live original (a public original is stored
    // in both buckets, so it counts in both).
    const sums = await DB.prepare(
        `SELECT COALESCE(SUM(CASE WHEN ${VISIBILITY_SQL} = 'public' THEN bytes END), 0) AS public_bytes,
                COALESCE(SUM(CASE WHEN bucket = 'originals' THEN bytes END), 0) AS private_bytes
         FROM media_items WHERE deleted_at IS NULL`,
    ).first<{ public_bytes: number; private_bytes: number }>();
    const usage = { public_bytes: sums?.public_bytes ?? 0, private_bytes: sums?.private_bytes ?? 0 };

    // A page that shows originals without a poster (and not tried in the last day) asks the API to
    // queue them (section 13: only records are written, the container wakes in its own sweep).
    // Best effort and bounded: the page never waits for it.
    const missing = page.some((e) => {
        if (e.t !== "item") return false;
        const r = e.row;
        return r.bucket === "originals" && !r.poster && hasPosterFrame(r.content_type) && (r.poster_at === null || r.poster_at < ctx.now - POSTER_COOLDOWN_MS);
    });
    if (missing) {
        let timer: ReturnType<typeof setTimeout> | undefined;
        await Promise.race([
            callApi(ctx, "/library/posters/backfill", { method: "POST" }).catch(() => null),
            new Promise((resolve) => {
                timer = setTimeout(resolve, 1500);
            }),
        ]);
        if (timer !== undefined) clearTimeout(timer);
    }

    // The owner's own title for each item's post, if any (the app sets it, section 15). Best
    // effort: without the table (0007 not applied yet) or on a D1 error the page shows file names.
    const titles = new Map<string, string>();
    const ids = page.filter((e) => e.t === "item").map((e) => e.id);
    if (ids.length > 0) {
        try {
            const { results } = await DB.prepare(
                `SELECT m.id AS id, t.title AS title FROM media_items m
                 JOIN media_titles t ON t.post_key = ${POST_KEY_SQL}
                 WHERE m.id IN (${ids.map((_, i) => `?${i + 1}`).join(", ")})`,
            )
                .bind(...ids)
                .all<{ id: string; title: string }>();
            for (const r of results) titles.set(r.id, r.title);
        } catch (e) {
            console.error("[library] titles lookup failed", String(e));
        }
    }

    const webOrigin = ctx.env.WEB_ORIGIN.replace(/\/+$/, "");
    return json(200, {
        items: page
            .filter((e) => e.t === "item")
            .map((e) => {
                const row = (e as Extract<Entry, { t: "item" }>).row;
                return { ...itemShape(row), custom_title: titles.get(row.id) ?? null };
            }),
        studios: page
            .filter((e) => e.t === "studio")
            .map((e) => {
                const s = (e as Extract<Entry, { t: "studio" }>).row;
                return {
                    id: s.id,
                    url: `${webOrigin}/studio/${s.id}`,
                    status: s.status,
                    link: s.link,
                    title: s.title,
                    duration: s.duration,
                    poster_url: s.poster ?? null,
                    renders: s.renders,
                    created_at: s.created_at,
                    expires_at: s.expires_at,
                };
            }),
        usage,
        next_before: more && page.length ? page[page.length - 1]!.created_at : null,
    });
}

// ---------- calls into the API Worker ----------

async function callApi(ctx: Ctx, path: string, init: { method: string; body?: unknown }): Promise<Response | null> {
    const key = ctx.env.COBALT_API_KEY;
    if (!key) return null;
    const headers = new Headers({ "x-cobalt-service": key, accept: "application/json" });
    let body: string | undefined;
    if (init.body !== undefined) {
        headers.set("content-type", "application/json");
        body = JSON.stringify(init.body);
    }
    try {
        return await ctx.env.API.fetch(new Request(API_BASE + path, { method: init.method, headers, body }));
    } catch {
        return null;
    }
}

// Turns an API answer into ours. Upstream 401/403 mean the service key is
// wrong, which must never look like an expired login to the page (it reloads
// on 401), so they become 502.
async function relayResponse(res: Response | null, map: (b: Record<string, unknown>) => Record<string, unknown>): Promise<Response> {
    if (!res) return err(502, "error.library.upstream");
    if (res.status === 401 || res.status === 403) return err(502, "error.library.upstream");
    let body: unknown;
    try {
        body = JSON.parse(await res.text());
    } catch {
        return err(502, "error.library.upstream");
    }
    if (!isObject(body)) return err(502, "error.library.upstream");
    if (body.status === "error" || res.status >= 400) {
        const e = body.error;
        const code = isObject(e) && typeof e.code === "string" ? e.code : "error.library.upstream";
        // A finished-but-failed job is a 200 upstream; keep the status, the body carries the error.
        return err(res.status, code);
    }
    return json(res.status, map(body));
}

const jobAlias = (b: Record<string, unknown>) => {
    if (typeof b.id === "string" && b.job === undefined) return { ...b, job: b.id };
    return b;
};

async function relayGet(ctx: Ctx, path: string, q: URLSearchParams, job: boolean): Promise<Response> {
    let wait = 0;
    if (q.has("wait")) {
        const n = intParam(q.get("wait"));
        if (n === null) return err(400, "error.library.bad_request");
        wait = Math.min(n, MAX_WAIT);
    }
    const res = await callApi(ctx, wait ? `${path}?wait=${wait}` : path, { method: "GET" });
    return relayResponse(res, job ? jobAlias : (b) => b);
}

async function relayPost(ctx: Ctx, path: string, body: unknown, map: (b: Record<string, unknown>) => Record<string, unknown>): Promise<Response> {
    const res = await callApi(ctx, path, { method: "POST", body });
    return relayResponse(res, map);
}

// ---------- POST /api/library/link ----------

const LINK_ACTIONS = ["webp", "studio", "host", "keep"];

async function link(ctx: Ctx, request: Request): Promise<Response> {
    const body = await readJson(request);
    if (!body) return err(400, "error.library.bad_request");
    const { url, action } = body;
    if (typeof action !== "string" || !LINK_ACTIONS.includes(action)) return err(400, "error.library.bad_request");
    if (typeof url !== "string") return err(400, "error.library.bad_request");
    const text = url.trim();
    if (!text || text.length > MAX_LINK_CHARS) return err(400, "error.library.bad_request");
    // Free text is fine (the API pulls out the first link), but there must be one.
    if (!/https?:\/\/\S/i.test(text)) return err(400, "error.library.invalid_url");

    if (action === "webp") {
        return relayPost(ctx, "/webp", { url: text }, (b) => {
            const out = jobAlias(b);
            return { status: out.status, job: out.job };
        });
    }
    return relayPost(ctx, "/studio", { url: text }, (b) => ({ status: "success", studio: b.id, url: b.url }));
}

// ---------- PUT /api/library/upload ----------

const cleanName = (raw: string | null, ext: string): string => {
    let name = raw ?? "";
    // eslint-disable-next-line no-control-regex
    name = name.replace(/[\u0000-\u001f\u007f]/g, "");
    name = name.split(/[\\/]/).pop() ?? "";
    name = Array.from(name.trim()).slice(0, MAX_NAME_CHARS).join("").trim();
    return name && name !== "." && name !== ".." ? name : `upload.${ext}`;
};

async function upload(ctx: Ctx, request: Request, q: URLSearchParams): Promise<Response> {
    const reject = (status: number, code: string) => {
        void request.body?.cancel().catch(() => {});
        return err(status, code);
    };
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    const ext = UPLOAD_TYPES[type];
    if (!ext) return reject(415, "error.library.unsupported");

    const declared = request.headers.get("content-length");
    if (declared === null || !/^\d{1,15}$/.test(declared)) return reject(411, "error.library.length_required");
    const size = Number(declared);
    if (size > MAX_UPLOAD_BYTES) return reject(413, "error.library.too_large");
    if (size === 0 || !request.body) return reject(400, "error.library.empty");

    const id = (ctx.deps.randomId ?? base62)(16);
    const key = `uploads/${id}.${ext}`;
    const name = cleanName(q.get("name"), ext);

    // Straight from the request to R2: the body has a known length, nothing is buffered.
    const obj = await ctx.env.ORIGINALS.put(key, request.body, { httpMetadata: { contentType: type } });
    if (!obj || obj.size !== size) {
        await ctx.env.ORIGINALS.delete(key).catch(() => {});
        return err(400, "error.library.incomplete");
    }
    try {
        await ctx.env.DB.prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, created_at)
             VALUES (?1, 'private', 'upload', 'originals', ?2, NULL, ?3, ?4, ?5, ?6)`,
        )
            .bind(id, key, name, type, size, ctx.now)
            .run();
    } catch (e) {
        await ctx.env.ORIGINALS.delete(key).catch(() => {});
        throw e;
    }
    const row = await getItem(ctx, id);
    return json(201, { status: "success", item: itemShape(row!) });
}

async function getItem(ctx: Ctx, id: string): Promise<MediaRow | null> {
    return (
        (await ctx.env.DB.prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id = ?1 AND deleted_at IS NULL`)
            .bind(id)
            .first<MediaRow>()) ?? null
    );
}

// ---------- POST /api/library/items/<id>/publish and /private ----------

// The toggle lives in the API Worker (copy or delete of the public mirror, cache purge,
// reconcile): PATCH /library/items/<id>/visibility {"public": bool}. Its 200 body is
// {status, item: <file>, cache_cleared}; its error codes (404 not_found/missing,
// 409 not_toggleable, 502 storage, 503) and statuses pass straight through.
async function setVisibility(ctx: Ctx, id: string, isPublic: boolean): Promise<Response> {
    const res = await callApi(ctx, `/library/items/${id}/visibility`, { method: "PATCH", body: { public: isPublic } });
    return relayResponse(res, (b) => ({ status: "success", item: b.item, cache_cleared: b.cache_cleared ?? null }));
}

// ---------- POST /api/library/items/<id>/studio ----------

async function itemStudio(ctx: Ctx, id: string): Promise<Response> {
    const row = await getItem(ctx, id);
    if (!row) return err(404, "error.library.not_found");
    if (row.bucket !== "originals" || row.kind !== "private") return err(409, "error.library.not_private");
    const type = row.content_type ?? "";
    if (!(type.startsWith("video/") || type === "image/gif")) return err(400, "error.studio.not_video");
    // A saved original whose own studio is still open: reopen that studio (its
    // webps stay listed) instead of minting a new one.
    if (row.session_id) {
        const open = await ctx.env.DB.prepare(
            "SELECT id FROM studio_sessions WHERE id = ?1 AND status = 'ready' AND expires_at > ?2 AND r2_key = ?3",
        )
            .bind(row.session_id, ctx.now, row.r2_key)
            .first<{ id: string }>();
        if (open) {
            const base = ctx.env.WEB_ORIGIN.replace(/\/+$/, "");
            return json(200, { status: "success", studio: open.id, url: `${base}/studio/${open.id}` });
        }
    }
    return relayPost(
        ctx,
        "/library/adopt",
        { r2_key: row.r2_key, name: row.name, content_type: type, bytes: row.bytes ?? 0, item_id: row.id },
        (b) => ({ status: "success", studio: b.id, url: b.url }),
    );
}

// ---------- DELETE ----------

async function itemDelete(ctx: Ctx, id: string): Promise<Response> {
    const row = await getItem(ctx, id);
    if (!row) return err(404, "error.library.not_found");
    // An item of a gallery (migration 0009, APP-API-CONTRACT.md section 18): its post lives on in its other items.
    // The last one is refused (the post's own delete is the way to remove everything), and the studio session, which
    // names the gallery's lead item, moves to the next item instead of closing. Without the column (0009 not applied)
    // the lookup fails and the row is a plain file, as before.
    const gal = await ctx.env.DB.prepare("SELECT role, session_id FROM media_items WHERE id = ?1")
        .bind(id)
        .first<{ role: string | null; session_id: string | null }>()
        .catch(() => null);
    const galleryItem = gal?.role === "item" && gal.session_id ? gal.session_id : null;
    if (galleryItem) {
        const others = await ctx.env.DB.prepare(
            "SELECT COUNT(*) AS n FROM media_items WHERE session_id = ?1 AND role = 'item' AND deleted_at IS NULL AND id <> ?2",
        )
            .bind(galleryItem, id)
            .first<{ n: number }>();
        if ((others?.n ?? 0) === 0) return err(409, "error.library.last_item");
    }
    // A public original (or a webp switched private and back, which lives in cobalt-originals too)
    // has a public mirror: switch it off through the API first (it deletes the mirror and purges the
    // edge). Failing closed: if that does not succeed, nothing is deleted, so a "private" delete can
    // never leave a public file behind. A webp still in the public bucket deletes as before.
    if (row.bucket === "originals" && (visibilityOf(row) === "public" || row.public_key)) {
        const off = await setVisibility(ctx, id, false);
        const done = off.status === 200 && ((await off.clone().json()) as { status?: string }).status === "success";
        if (!done) return off.status >= 400 ? off : err(502, "error.library.upstream");
    }
    const bucket = row.bucket === "media" ? ctx.env.MEDIA : ctx.env.ORIGINALS;
    try {
        await bucket.delete(row.r2_key); // deleting a missing object succeeds
    } catch {
        return err(502, "error.library.storage");
    }
    await ctx.env.DB.prepare("UPDATE media_items SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL")
        .bind(ctx.now, id)
        .run();
    if (galleryItem) {
        await moveGalleryLead(ctx, galleryItem);
    } else if (row.bucket === "originals") {
        // The studios that read this original can no longer render from it.
        await ctx.env.DB.prepare("UPDATE studio_sessions SET expires_at = ?1 WHERE r2_key = ?2 AND expires_at > ?1")
            .bind(ctx.now, row.r2_key)
            .run();
    }
    // The poster goes with its row, unless a live row (the public copy of an original, or the
    // original of a public copy) still shows it. Never fails the delete.
    await releasePoster(ctx, row.poster);
    return json(200, { status: "success" });
}

// The session of a gallery names its lead item (the first video, else the first item) as its original: after one of
// its items is deleted the session points at the lead that is left (the API's repointLead, src/studio.ts).
async function moveGalleryLead(ctx: Ctx, sid: string): Promise<void> {
    try {
        const { results } = await ctx.env.DB.prepare(
            "SELECT r2_key, content_type, bytes, duration, width, height, poster, visibility, url FROM media_items WHERE session_id = ?1 AND role = 'item' AND deleted_at IS NULL ORDER BY item_index, id",
        )
            .bind(sid)
            .all<{ r2_key: string; content_type: string | null; bytes: number | null; duration: number | null; width: number | null; height: number | null; poster: string | null; visibility: string | null; url: string | null }>();
        const lead = results.find((r) => (r.content_type ?? "").startsWith("video/")) ?? results[0];
        if (!lead) return;
        const publicUrl = lead.visibility === "public" && lead.url ? lead.url : null;
        await ctx.env.DB.prepare(
            `UPDATE studio_sessions SET r2_key = ?1, content_type = ?2, bytes = ?3, duration = ?4, width = ?5, height = ?6, poster = ?7,
                    public_state = CASE WHEN ?8 IS NOT NULL THEN 'ready' WHEN public_state = 'pending' THEN public_state ELSE NULL END,
                    public_url = ?8
              WHERE id = ?9 AND (r2_key IS NULL OR r2_key <> ?1)`,
        )
            .bind(lead.r2_key, lead.content_type, lead.bytes, lead.duration, lead.width, lead.height, lead.poster, publicUrl, sid)
            .run();
    } catch (e) {
        console.error("[library] moving the gallery's lead failed", sid, String(e));
    }
}

async function releasePoster(ctx: Ctx, url: string | null): Promise<void> {
    if (!url) return;
    let name: string | null = null;
    try {
        name = decodeURIComponent(new URL(url).pathname.split("/").pop() ?? "");
    } catch {
        return;
    }
    if (!POSTER_NAME.test(name)) return;
    try {
        const live = await ctx.env.DB.prepare("SELECT COUNT(*) AS n FROM media_items WHERE poster = ?1 AND deleted_at IS NULL")
            .bind(url)
            .first<{ n: number }>();
        if ((live?.n ?? 0) > 0) return;
        await ctx.env.MEDIA.delete(name);
    } catch (e) {
        console.error("[library] poster delete failed", name, String(e));
    }
}

async function studioDelete(ctx: Ctx, sid: string): Promise<Response> {
    const res = await ctx.env.DB.prepare(
        "UPDATE studio_sessions SET expires_at = ?1 WHERE id = ?2 AND expires_at > ?1 RETURNING id",
    )
        .bind(ctx.now, sid)
        .all<{ id: string }>();
    if (res.results.length === 0) return err(404, "error.library.not_found");
    return json(200, { status: "success" });
}
