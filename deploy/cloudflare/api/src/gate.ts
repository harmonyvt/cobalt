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
    // (D1 / R2, no container). `sid` is already format-checked. (The render
    // routes are ops in the registry: src/registry/ops/make.ts.)
    | { action: "studio"; op: StudioOp; sid?: string }
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
    | "library_adopt"
    | "library_file"
    | "library_visibility_migrate"
    | "library_posters_backfill"
    | "library_search_index"
    | "library_search_post"
    // chat (APP-API-CONTRACT.md section 27)
    | "chat_list"
    | "chat_create"
    | "chat_get"
    | "chat_rename"
    | "chat_delete"
    | "chat_send"
    | "chat_collage"
    | "live_start_token"
    | "live_run"
    | "live_state"
    | "live_selftest"
    | "live_edit"
    | "live_chat"
    | "studio_notify"
    | "studio_line_notify"
    // photos and galleries (APP-API-CONTRACT.md section 18)
    | "telemetry_ingest";

export type StudioOp = "preflight" | "status" | "source";

// /webp/:id ids are 16-32 alphanumerics (the DO mints 20); media names are 10
// alphanumerics + ".webp". Validated here so nothing else reaches a handler.
export const WEBP_ID_REGEX = /^[A-Za-z0-9]{16,32}$/;
export const MEDIA_NAME_REGEX = /^[A-Za-z0-9]{10}\.webp$/;

// Studio session id: 22 base62 chars (>= 128 bits); render job id: 20.
export const STUDIO_SID_REGEX = /^[A-Za-z0-9]{22}$/;
export const STUDIO_JOB_REGEX = /^[A-Za-z0-9]{20}$/;

// Library item id: 16 base62 chars (mintItemId, the web's base62(16)).
export const ITEM_ID_REGEX = /^[A-Za-z0-9]{16}$/;
const COLLECTION_ID_REGEX = /^[A-Za-z0-9]{16}$/;

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
// "lookup" decision for the Worker. Exported for the op registry (src/registry/http.ts),
// which checks keys the same way.
export function parseAuthorization(
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

    // GET /queue, GET /library, GET /library/search and GET /library/map are ops in the registry
    // (src/registry/ops/library.ts, APP-API-CONTRACT.md section 33), which answers them before the gate. So are the
    // gallery links, collections and sets (/share/sets, /share/collections, /share/groups), the stage owner routes
    // (/stage*) and /emotes (src/registry/ops/share.ts and stage.ts, section 33.9). Every other method on those paths
    // falls through to the 404 at the end.

    // Editor (APP-API-CONTRACT.md section 31.12): ops in the registry (src/registry/ops/make.ts, section 33.8). Every
    // other method or path under /edits falls through to the 404 at the end.

    // Chat (APP-API-CONTRACT.md section 27): keyed only.
    if (req.pathname === "/chat/threads" || req.pathname.startsWith("/chat/threads/")) {
        if (req.service) return reject(404);
        if (req.pathname === "/chat/threads") {
            if (req.method === "GET") return lookupThen(req, "chat_list");
            if (req.method === "POST") return lookupThen(req, "chat_create");
            return reject(404);
        }
        const rest = req.pathname.slice("/chat/threads/".length);
        const [id, sub, ...more] = rest.split("/");
        if (!COLLECTION_ID_REGEX.test(id ?? "")) return reject(404);
        // GET /chat/threads/<id>/messages/<mid>/collage (section 27.5)
        if (sub === "messages" && more.length === 2 && more[1] === "collage" && /^\d{1,12}$/.test(more[0]!)) {
            return req.method === "GET" ? lookupThen(req, "chat_collage", { id: id!, message: more[0]! }) : reject(404);
        }
        if (more.length > 0) return reject(404);
        if (sub === "messages") return req.method === "POST" ? lookupThen(req, "chat_send", { id: id! }) : reject(404);
        if (sub !== undefined) return reject(404);
        if (req.method === "GET") return lookupThen(req, "chat_get", { id: id! });
        if (req.method === "PATCH") return lookupThen(req, "chat_rename", { id: id! });
        if (req.method === "DELETE") return lookupThen(req, "chat_delete", { id: id! });
        return reject(404);
    }

    // Library adoption is for the web Worker's service credential only; an
    // Api-Key client never reaches it.
    if (req.pathname === "/library/adopt") {
        if (req.method !== "POST") return reject(404);
        return req.service
            ? { action: "service", then: "library_adopt" }
            : reject(401, "error.api.auth.key.invalid");
    }

    // The app's library (keyed): per item /library/items/<id>/<sub>.
    // One post's index status (section 21): keyed or service.
    if (req.pathname === "/library/search/post") {
        return req.method === "GET" ? lookupThen(req, "library_search_post") : reject(404);
    }
    if (req.pathname === "/library/search/index") {
        return req.method === "POST" ? lookupThen(req, "library_search_index") : reject(404);
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
        // DELETE of the bare item path, PUT .../made, POST .../publish, PATCH .../visibility and PATCH|DELETE .../post
        // are ops (src/registry/ops/library-writes.ts); every other method on them is a 404 here.
        if (sub === "file") {
            return req.method === "GET" || req.method === "HEAD"
                ? lookupThen(req, "library_file", { id: id! })
                : reject(404);
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

// Editor ids (section 31.12), used by the registry's edit routes: a project is 16 base62, a render 20 (`renders`, 7
// characters, is never a project id).
export const EDIT_PROJECT_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const EDIT_RENDER_ID_REGEX = /^[A-Za-z0-9]{20}$/;

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
    } else if (req.pathname === "/live/chat-start-token") {
        // a device's push-to-start token for chat reply activities (section 27.9)
        if (m === "PUT" || m === "DELETE") then = "live_chat";
    } else if (req.pathname.startsWith("/live/chats/")) {
        // a push-started chat activity's token; /live/chats/<thread>/state is the Worker's own, never the internet's
        const [thread, ...rest] = req.pathname.slice("/live/chats/".length).split("/");
        if (COLLECTION_ID_REGEX.test(thread ?? "") && rest.length === 0 && m === "PUT") then = "live_chat";
    } else if (req.pathname.startsWith("/live/edits/")) {
        // an editor render's activity token (section 32); /live/edits/<rid>/push is the EditRenderer's, never the internet's
        const [rid, ...rest] = req.pathname.slice("/live/edits/".length).split("/");
        if (/^[A-Za-z0-9]{20}$/.test(rid ?? "") && rest.length === 0 && (m === "PUT" || m === "DELETE")) then = "live_edit";
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
    // POST /studio, PUT /studio/upload, GET /studio/recent, GET /studio/line, POST /studio/<sid>/publish,
    // DELETE /studio/<sid>/line, DELETE /studio/<sid>/render/<job> and POST /studio/<sid>/items/retry are ops
    // (src/registry/ops/library-writes.ts, APP-API-CONTRACT.md 33.7), answered before the gate. Every other method on
    // those paths is a 404 here. The internal /studio/upload/adopt (Worker -> Durable Object) is not public: it fails
    // the session id check below.
    if (req.pathname === "/studio" || req.pathname === "/studio/upload" || req.pathname === "/studio/recent" || req.pathname === "/studio/line") {
        return reject(404);
    }
    // PUT|DELETE /studio/line/notify (APP-API-CONTRACT.md section 17). Keyed; the library-service credential and every
    // other method are 404.
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
    return reject(404);
}
