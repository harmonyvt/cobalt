// Pure request gate for the cobalt API Worker. No Cloudflare imports, so it can
// be unit-tested under plain node. The Worker (index.ts) turns a "forward"
// decision into a call to the container, a "lookup" decision into a D1 key check
// followed by a forward, and a "reject" decision into a Response without ever
// waking the container.
//
// Rules are derived from upstream cobalt behaviour:
//  - auth error codes:  api/src/security/api-keys.js (validateAuthorization)
//  - error body shape:  api/src/processing/request.js (createResponse)
//  - tunnel params:     api/src/stream/manage.js (createStream) and
//                       api/src/core/api.js (GET /tunnel); `exp` is a Unix
//                       timestamp in MILLISECONDS.

export type GateRequest = {
    method: string;
    pathname: string;
    searchParams: URLSearchParams;
    origin: string | null;
    authorization: string | null;
    // The caller proved it is the web Worker's library service (the
    // x-cobalt-service header equals the internal key, checked by the Worker).
    // Counts as a valid API key on every keyed route.
    service?: boolean;
};

export type GateConfig = {
    corsUrl: string; // web origin, e.g. https://cobalt.capybaraharmony.com
    now: number; // Date.now(), ms
};

export type GateDecision =
    | { action: "forward" }
    // A well-formed client key: the Worker looks it up in D1 before doing
    // anything else. Without `then` (POST /) the request is forwarded to the
    // container with the internal key swapped in. With `then` it is handed to
    // the Durable Object's webp/media handlers with the key's id attached.
    | {
          action: "lookup";
          key: string;
          then?: LookupThen;
          params?: Record<string, string>;
      }
    // cobalt studio routes that need no API key (the session id is the
    // capability). The Worker answers "preflight", "status" and "source" itself
    // (D1 / R2, no container); "render_create" and "render_status" go to the
    // Durable Object. `sid` and `job` are already format-checked.
    | { action: "studio"; op: StudioOp; sid?: string; job?: string }
    // The library service: like "lookup" with a valid key, but nothing to look
    // up (the Worker's key id is "service:library").
    | {
          action: "service";
          then?: LookupThen;
          params?: Record<string, string>;
      }
    // GET /capabilities: never a 401. The Worker answers it itself (D1 at most)
    // and reports the key's state; `auth` is what the request carried.
    | { action: "capabilities"; auth: "service" | "missing" | "invalid" | "key"; key?: string }
    | { action: "reject"; status: number; errorCode?: string };

export type LookupThen =
    | "webp_create"
    | "webp_status"
    | "media_delete"
    | "studio_create"
    | "studio_publish"
    | "studio_upload"
    | "library_adopt"
    | "library_list"
    | "library_file"
    | "library_publish"
    | "library_visibility"
    | "library_visibility_migrate"
    | "library_studio"
    | "library_post_delete"
    | "library_post_title"
    | "library_posters_backfill"
    | "live_start_token"
    | "live_run"
    | "live_state"
    | "live_selftest"
    | "studio_notify"
    | "studio_recent"
    | "studio_line"
    | "studio_line_notify"
    | "studio_cancel"
    // photos and galleries (APP-API-CONTRACT.md section 18)
    | "studio_slideshow"
    | "studio_items_retry"
    | "library_item_delete"
    | "library_made"
    | "telemetry_ingest";

export type StudioOp =
    | "preflight"
    | "status"
    | "source"
    | "render_create"
    | "render_status";

// /webp/:id ids are 16-32 alphanumerics (the DO mints 20); media names are 10
// alphanumerics + ".webp". Validated here so nothing else reaches a handler.
export const WEBP_ID_REGEX = /^[A-Za-z0-9]{16,32}$/;
export const MEDIA_NAME_REGEX = /^[A-Za-z0-9]{10}\.webp$/;

// Studio session id: 22 base62 chars (>= 128 bits); render job id: 20.
export const STUDIO_SID_REGEX = /^[A-Za-z0-9]{22}$/;
export const STUDIO_JOB_REGEX = /^[A-Za-z0-9]{20}$/;

// Library item id: 16 base62 chars (mintItemId, the web's base62(16)).
export const ITEM_ID_REGEX = /^[A-Za-z0-9]{16}$/;

export const isStudioPath = (pathname: string) =>
    pathname === "/studio" || pathname.startsWith("/studio/");

export const isLivePath = (pathname: string) => pathname === "/live" || pathname.startsWith("/live/");

export const TUNNEL_PARAMS = ["id", "exp", "sig", "sec", "iv"] as const;

const reject = (status: number, errorCode?: string): GateDecision => ({
    action: "reject",
    status,
    errorCode,
});

// Same pattern as api/src/security/api-keys.js: lowercase UUIDv4-shaped only
// (the API rejects anything else as "invalid" before looking the key up).
const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Mirrors validateAuthorization() up to the key lookup. The gate cannot know
// whether a key is registered (that is D1), so a well-formed key becomes a
// "lookup" decision for the Worker.
function parseAuthorization(
    header: string | null,
): { key: string } | { errorCode: string } {
    if (header === null) return { errorCode: "error.api.auth.key.missing" };

    const [authType = "", key = ""] = header.split(" ", 2);
    if (authType.toLowerCase() !== "api-key") {
        return { errorCode: "error.api.auth.key.not_api_key" };
    }

    if (!UUID_REGEX.test(key) || `${authType} ${key}` !== header) {
        return { errorCode: "error.api.auth.key.invalid" };
    }
    return { key };
}

function lookupThen(
    req: GateRequest,
    then: LookupThen,
    params?: Record<string, string>,
): GateDecision {
    if (req.service) {
        return { action: "service", then, ...(params ? { params } : {}) };
    }
    const parsed = parseAuthorization(req.authorization);
    return "key" in parsed
        ? { action: "lookup", key: parsed.key, then, ...(params ? { params } : {}) }
        : reject(401, parsed.errorCode);
}

export function decide(req: GateRequest, cfg: GateConfig): GateDecision {
    // Live Activity push (APP-API-CONTRACT.md section 8): keyed and nothing else.
    // The app sends no Origin, so there is no preflight and no CORS; everything not
    // listed (and the library service caller) is a 404.
    if (isLivePath(req.pathname)) return decideLive(req);

    // Crash and log telemetry (TELEMETRY-CONTRACT.md): keyed POST only, answered by
    // the Worker from D1 and R2. No CORS, so an OPTIONS (or anything else) is a 404,
    // and the library service credential never reaches it (one key per device).
    if (req.pathname === "/telemetry") {
        return req.method === "POST" && !req.service ? lookupThen(req, "telemetry_ingest") : reject(404);
    }

    const originOk = req.origin !== null && req.origin === cfg.corsUrl;

    if (req.method === "OPTIONS") {
        if (!originOk) return reject(403);
        // Studio preflights are answered by the Worker (204), never forwarded.
        return isStudioPath(req.pathname)
            ? { action: "studio", op: "preflight" }
            : { action: "forward" };
    }

    if (isStudioPath(req.pathname)) return decideStudio(req);

    // App discovery: open to everyone, the key (if any) only changes the answer.
    if (req.pathname === "/capabilities") {
        if (req.method !== "GET") return reject(404);
        if (req.service) return { action: "capabilities", auth: "service" };
        if (req.authorization === null) return { action: "capabilities", auth: "missing" };
        const parsed = parseAuthorization(req.authorization);
        return "key" in parsed
            ? { action: "capabilities", auth: "key", key: parsed.key }
            : { action: "capabilities", auth: "invalid" };
    }

    // Library adoption is for the web Worker's service credential only; an
    // Api-Key client never reaches it.
    if (req.pathname === "/library/adopt") {
        if (req.method !== "POST") return reject(404);
        return req.service
            ? { action: "service", then: "library_adopt" }
            : reject(401, "error.api.auth.key.invalid");
    }

    // The app's library (keyed): GET /library, then per item /library/items/<id>/<sub>.
    if (req.pathname === "/library") {
        return req.method === "GET" ? lookupThen(req, "library_list") : reject(404);
    }
    // Queue the missing server-made posters (APP-API-CONTRACT.md section 13): keyed or service.
    if (req.pathname === "/library/posters/backfill") {
        return req.method === "POST" ? lookupThen(req, "library_posters_backfill") : reject(404);
    }
    // The one-row-per-file data step (APP-API-CONTRACT.md section 16): keyed or service.
    if (req.pathname === "/library/visibility/migrate") {
        return req.method === "POST" ? lookupThen(req, "library_visibility_migrate") : reject(404);
    }
    if (req.pathname.startsWith("/library/items/")) {
        const [id, sub, ...rest] = req.pathname.slice("/library/items/".length).split("/");
        if (!ITEM_ID_REGEX.test(id ?? "") || rest.length > 0) return reject(404);
        // Delete one item or made file of a post (section 18.4): DELETE on the bare item path only
        if (sub === undefined) {
            return req.method === "DELETE" ? lookupThen(req, "library_item_delete", { id: id! }) : reject(404);
        }
        // A crop or an export made on the device (section 18.6): PUT only
        if (sub === "made") {
            return req.method === "PUT" ? lookupThen(req, "library_made", { id: id! }) : reject(404);
        }
        if (sub === "file") {
            return req.method === "GET" || req.method === "HEAD"
                ? lookupThen(req, "library_file", { id: id! })
                : reject(404);
        }
        if (sub === "publish") {
            return req.method === "POST" ? lookupThen(req, "library_publish", { id: id! }) : reject(404);
        }
        // The public/private toggle (section 16)
        if (sub === "visibility") {
            return req.method === "PATCH" ? lookupThen(req, "library_visibility", { id: id! }) : reject(404);
        }
        if (sub === "studio") {
            return req.method === "POST" ? lookupThen(req, "library_studio", { id: id! }) : reject(404);
        }
        // Delete a whole post (APP-API-CONTRACT.md section 12) or set its custom title
        // (section 15): any file id of the post.
        if (sub === "post") {
            if (req.method === "DELETE") return lookupThen(req, "library_post_delete", { id: id! });
            if (req.method === "PATCH") return lookupThen(req, "library_post_title", { id: id! });
            return reject(404);
        }
        return reject(404);
    }

    if (req.method === "POST" && req.pathname === "/") {
        if (req.service) return { action: "service" };
        const parsed = parseAuthorization(req.authorization);
        return "key" in parsed
            ? { action: "lookup", key: parsed.key }
            : reject(401, parsed.errorCode);
    }

    if (req.method === "POST" && req.pathname === "/webp") {
        return lookupThen(req, "webp_create");
    }

    if (req.method === "GET" && req.pathname.startsWith("/webp/")) {
        const id = req.pathname.slice("/webp/".length);
        if (!WEBP_ID_REGEX.test(id)) return reject(404);
        return lookupThen(req, "webp_status", { id });
    }

    if (req.method === "DELETE" && req.pathname.startsWith("/media/")) {
        const name = req.pathname.slice("/media/".length);
        if (!MEDIA_NAME_REGEX.test(name)) return reject(404);
        return lookupThen(req, "media_delete", { name });
    }

    if (req.method === "GET" && req.pathname === "/") {
        return originOk ? { action: "forward" } : reject(404);
    }

    if (req.method === "GET" && req.pathname === "/tunnel") {
        for (const p of TUNNEL_PARAMS) {
            if (!req.searchParams.get(p)) return reject(404);
        }
        const exp = Number(req.searchParams.get("exp"));
        if (!Number.isFinite(exp) || exp <= cfg.now) return reject(404);
        return { action: "forward" };
    }

    return reject(404);
}

// PUT|DELETE /live/start-token, PUT|DELETE /live/runs/<run>, POST
// /live/runs/<run>/state, GET /live/selftest. <run> is a lowercase UUID.
const LIVE_RUN_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function decideLive(req: GateRequest): GateDecision {
    const m = req.method;
    let then: LookupThen | null = null;
    if (req.pathname === "/live/start-token") {
        if (m === "PUT" || m === "DELETE") then = "live_start_token";
    } else if (req.pathname === "/live/selftest") {
        if (m === "GET") then = "live_selftest";
    } else if (req.pathname.startsWith("/live/runs/")) {
        const [run, sub, ...rest] = req.pathname.slice("/live/runs/".length).split("/");
        if (LIVE_RUN_REGEX.test(run ?? "") && rest.length === 0) {
            if (sub === undefined && (m === "PUT" || m === "DELETE")) then = "live_run";
            else if (sub === "state" && m === "POST") then = "live_state";
        }
    }
    // the library service credential never reaches these (one key per device)
    if (then === null || req.service) return reject(404);
    return lookupThen(req, then);
}

// /studio, /studio/<sid>, /studio/<sid>/source, /studio/<sid>/render and
// /studio/<sid>/render/<job>. Ids are validated before anything is looked up;
// every other path or method is a 404.
function decideStudio(req: GateRequest): GateDecision {
    if (req.pathname === "/studio") {
        return req.method === "POST"
            ? lookupThen(req, "studio_create")
            : reject(404);
    }
    // PUT /studio/upload (keyed) is the one public path whose second segment is
    // not a session id; it must be checked before the id format. The internal
    // /studio/upload/adopt (Worker -> Durable Object) is not public: it fails
    // the session id check below and is a 404.
    if (req.pathname === "/studio/upload") {
        return req.method === "PUT" ? lookupThen(req, "studio_upload") : reject(404);
    }
    // GET /studio/recent (keyed; the library service credential gets 404): the sessions this
    // key created from a share sheet (APP-API-CONTRACT.md section 14). Like /studio/upload, the
    // only public path under /studio/ whose second segment is not a session id.
    if (req.pathname === "/studio/recent") {
        if (req.service) return reject(404);
        return req.method === "GET" ? lookupThen(req, "studio_recent") : reject(404);
    }
    // The server's line (APP-API-CONTRACT.md section 17): GET /studio/line, PUT|DELETE
    // /studio/line/notify. Keyed; the library-service credential and every other method are 404.
    // Neither path segment is a session id.
    if (req.pathname === "/studio/line") {
        if (req.service) return reject(404);
        return req.method === "GET" ? lookupThen(req, "studio_line") : reject(404);
    }
    if (req.pathname === "/studio/line/notify") {
        if (req.service) return reject(404);
        return req.method === "PUT" || req.method === "DELETE" ? lookupThen(req, "studio_line_notify") : reject(404);
    }
    const parts = req.pathname.slice("/studio/".length).split("/");
    const [sid, sub, job, ...rest] = parts;
    if (!STUDIO_SID_REGEX.test(sid ?? "") || rest.length > 0) return reject(404);

    if (sub === undefined) {
        return req.method === "GET"
            ? { action: "studio", op: "status", sid }
            : reject(404);
    }
    // Publishing makes a public copy: Api-Key or service auth (the session id
    // alone is not enough).
    if (sub === "publish" && job === undefined) {
        return req.method === "POST"
            ? lookupThen(req, "studio_publish", { sid })
            : reject(404);
    }
    // Hark notification opt-in (APP-API-CONTRACT.md section 9): keyed, the session's owner
    // only (the Durable Object checks the owner). The library service credential never
    // reaches it.
    if (sub === "notify" && job === undefined) {
        if (req.service) return reject(404);
        return req.method === "PUT" || req.method === "DELETE"
            ? lookupThen(req, "studio_notify", { sid })
            : reject(404);
    }
    if (sub === "source" && job === undefined) {
        return req.method === "GET" || req.method === "HEAD"
            ? { action: "studio", op: "source", sid }
            : reject(404);
    }
    if (sub === "render" && job === undefined) {
        return req.method === "POST"
            ? { action: "studio", op: "render_create", sid }
            : reject(404);
    }
    // Cancel what has not started (section 17.7): keyed, the creating key only (the Durable Object
    // checks the owner). The library service credential never reaches it.
    if (sub === "line" && job === undefined) {
        if (req.service) return reject(404);
        return req.method === "DELETE" ? lookupThen(req, "studio_cancel", { sid }) : reject(404);
    }
    // A slideshow made from the items of a gallery, and the retry of the items that failed to save
    // (section 18.5, 18.2): keyed POST, the session's creating key only (the Durable Object checks the
    // owner). The library service credential never reaches them.
    if (sub === "slideshow" && job === undefined) {
        if (req.service) return reject(404);
        return req.method === "POST" ? lookupThen(req, "studio_slideshow", { sid }) : reject(404);
    }
    if (sub === "items" && job === "retry") {
        if (req.service) return reject(404);
        return req.method === "POST" ? lookupThen(req, "studio_items_retry", { sid }) : reject(404);
    }
    if (sub === "render" && job !== undefined && STUDIO_JOB_REGEX.test(job)) {
        if (req.method === "DELETE") {
            return req.service ? reject(404) : lookupThen(req, "studio_cancel", { sid, job });
        }
        return req.method === "GET"
            ? { action: "studio", op: "render_status", sid, job }
            : reject(404);
    }
    return reject(404);
}
