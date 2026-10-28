// What the API Worker does with a request no op takes (APP-API-CONTRACT.md 33.12). Every route is an op in the
// registry (src/registry/), which answers before this; what is left is one rule for preflights and the 404 for
// everything else. Also the shared pieces the ops use: the `Authorization` check and the id patterns. No Cloudflare
// imports, so it runs under plain node.
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
    service?: boolean;
};

export type GateConfig = {
    corsUrl: string; // web origin, e.g. https://cobalt.capybaraharmony.com
    now: number; // Date.now(), ms
};

export type GateDecision =
    // an OPTIONS from the web origin: the container answers it (upstream cobalt's CORS)
    | { action: "forward" }
    // an OPTIONS from the web origin on a /studio* path: the Worker answers 204 itself
    | { action: "preflight" }
    | { action: "reject"; status: 403 | 404 };

// /webp/:id ids are 16-32 alphanumerics (the DO mints 20); media names are 10
// alphanumerics + ".webp". Validated before anything reaches a handler.
export const WEBP_ID_REGEX = /^[A-Za-z0-9]{16,32}$/;
export const MEDIA_NAME_REGEX = /^[A-Za-z0-9]{10}\.webp$/;

// Studio session id: 22 base62 chars (>= 128 bits); render job id: 20.
export const STUDIO_SID_REGEX = /^[A-Za-z0-9]{22}$/;
export const STUDIO_JOB_REGEX = /^[A-Za-z0-9]{20}$/;

// Library item id: 16 base62 chars (mintItemId, the web's base62(16)).
export const ITEM_ID_REGEX = /^[A-Za-z0-9]{16}$/;
// A chat thread id (chat.ts's CHAT_ID_REGEX). The registry's ops take it from here: chat.ts imports the registry, so
// through that cycle chat.ts's own constant is still undefined when an op file loads.
export const THREAD_ID_REGEX = /^[A-Za-z0-9]{16}$/;

// Editor ids (section 31.12): a project is 16 base62, a render 20 (`renders`, 7 characters, is never a project id).
export const EDIT_PROJECT_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const EDIT_RENDER_ID_REGEX = /^[A-Za-z0-9]{20}$/;

export const isStudioPath = (pathname: string) => pathname === "/studio" || pathname.startsWith("/studio/");

export const isLivePath = (pathname: string) => pathname === "/live" || pathname.startsWith("/live/");

export const TUNNEL_PARAMS = ["id", "exp", "sig", "sec", "iv"] as const;

// Same pattern as api/src/security/api-keys.js: lowercase UUIDv4-shaped only
// (the API rejects anything else as "invalid" before looking the key up).
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Mirrors validateAuthorization() up to the key lookup. Only D1 knows whether a well-formed key is registered; the
// registry (src/registry/http.ts) looks it up next.
export function parseAuthorization(header: string | null): { key: string } | { errorCode: string } {
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

// A request no op took. Preflights: the Live Activity routes and /telemetry have no CORS (the app sends no Origin),
// so an OPTIONS there is a 404 like any other method; anywhere else the web origin's preflight is answered (by the
// Worker under /studio, by the container elsewhere) and any other origin's is a 403. Everything else is a bodyless 404.
export function decide(req: GateRequest, cfg: GateConfig): GateDecision {
    if (req.method !== "OPTIONS" || isLivePath(req.pathname) || req.pathname === "/telemetry") return { action: "reject", status: 404 };
    if (req.origin === null || req.origin !== cfg.corsUrl) return { action: "reject", status: 403 };
    return isStudioPath(req.pathname) ? { action: "preflight" } : { action: "forward" };
}
