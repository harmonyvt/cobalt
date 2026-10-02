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
    | { action: "reject"; status: number; errorCode?: string };

export type LookupThen =
    | "webp_create"
    | "webp_status"
    | "media_delete"
    | "studio_create"
    | "studio_publish"
    | "library_adopt";

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

export const isStudioPath = (pathname: string) =>
    pathname === "/studio" || pathname.startsWith("/studio/");

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
    const originOk = req.origin !== null && req.origin === cfg.corsUrl;

    if (req.method === "OPTIONS") {
        if (!originOk) return reject(403);
        // Studio preflights are answered by the Worker (204), never forwarded.
        return isStudioPath(req.pathname)
            ? { action: "studio", op: "preflight" }
            : { action: "forward" };
    }

    if (isStudioPath(req.pathname)) return decideStudio(req);

    // Library adoption is for the web Worker's service credential only; an
    // Api-Key client never reaches it.
    if (req.pathname === "/library/adopt") {
        if (req.method !== "POST") return reject(404);
        return req.service
            ? { action: "service", then: "library_adopt" }
            : reject(401, "error.api.auth.key.invalid");
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

// /studio, /studio/<sid>, /studio/<sid>/source, /studio/<sid>/render and
// /studio/<sid>/render/<job>. Ids are validated before anything is looked up;
// every other path or method is a 404.
function decideStudio(req: GateRequest): GateDecision {
    if (req.pathname === "/studio") {
        return req.method === "POST"
            ? lookupThen(req, "studio_create")
            : reject(404);
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
    if (sub === "render" && job !== undefined && STUDIO_JOB_REGEX.test(job)) {
        return req.method === "GET"
            ? { action: "studio", op: "render_status", sid, job }
            : reject(404);
    }
    return reject(404);
}
