// /api/keys: the owner's API key management, served by the web Worker.
// Authentication happens before anything else touches D1: a valid Cloudflare
// Access JWT for the owner's email. Only SHA-256 hashes are stored; the
// plaintext key is returned once, by POST.
import { verifyAccessJwt, JwksCache, type AccessConfig } from "./access";

export interface Env {
    ASSETS: Fetcher;
    DB: D1Database;
    ACCESS_TEAM_DOMAIN: string;
    ACCESS_AUD: string;
    OWNER_EMAIL: string;
    // Exact Origin allowed to POST/DELETE, e.g. https://cobalt.capybaraharmony.com
    WEB_ORIGIN: string;
    // Library (src/library.ts): R2 buckets, the API Worker and its internal key.
    MEDIA: R2Bucket; // public files, served at MEDIA_BASE_URL
    ORIGINALS: R2Bucket; // private files: originals/<sid>.<ext>, uploads/<id>.<ext>
    MEDIA_BASE_URL: string;
    API: Fetcher; // service binding to the cobalt-api Worker
    COBALT_API_KEY: string; // internal; sent as x-cobalt-service, never to the browser
}

export const MAX_KEYS = 50;
export const MAX_NAME_LENGTH = 40;
const MAX_BODY_BYTES = 2048;
const ID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const hex = (buf: ArrayBuffer) =>
    [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Lowercase hex SHA-256, identical to deploy/cloudflare/api/src/keys.ts.
export async function hashKey(key: string): Promise<string> {
    return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)));
}

export type ErrorCode =
    | "unauthorized"
    | "forbidden"
    | "bad_request"
    | "not_found"
    | "too_many_keys"
    | "server_error";

const baseHeaders = {
    "content-type": "application/json",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
};

const jsonResponse = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { ...baseHeaders, ...extra } });

const error = (status: number, code: ErrorCode, extra?: Record<string, string>) =>
    jsonResponse(status, { error: code }, extra);

type KeyRow = {
    id: string;
    name: string;
    prefix: string;
    created_at: number;
    last_used_at: number | null;
};

export type Deps = {
    jwks: JwksCache;
    now?: () => number;
};

// Module-scope cache: survives across requests within an isolate.
let defaultJwks: { team: string; cache: JwksCache } | undefined;
export const jwksFor = (team: string): JwksCache => {
    if (!defaultJwks || defaultJwks.team !== team) {
        defaultJwks = { team, cache: new JwksCache(team) };
    }
    return defaultJwks.cache;
};

export async function handleKeys(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = {
        teamDomain: env.ACCESS_TEAM_DOMAIN,
        aud: env.ACCESS_AUD,
        ownerEmail: env.OWNER_EMAIL,
    };

    // 1. Authenticate. Fails closed on any problem, including JWKS outages.
    const auth = await verifyAccessJwt(
        request.headers.get("Cf-Access-Jwt-Assertion"),
        access,
        jwks,
        now(),
    );
    if (!auth.ok) return error(401, "unauthorized");

    const { pathname } = new URL(request.url);
    const method = request.method;

    // Route shape (method allowed for the path) before the CSRF check, so a
    // wrong-method request never reaches state-changing code.
    const isCollection = pathname === "/api/keys";
    const idMatch = /^\/api\/keys\/([^/]+)$/.exec(pathname);
    if (!isCollection && !idMatch) return error(404, "not_found");
    const allowed = isCollection ? ["GET", "POST"] : ["DELETE"];
    if (!allowed.includes(method)) {
        return error(405, "bad_request", { allow: allowed.join(", ") });
    }

    // 2. CSRF: state-changing calls must come from the web app itself.
    if (method !== "GET" && request.headers.get("Origin") !== env.WEB_ORIGIN) {
        return error(403, "forbidden");
    }

    try {
        if (method === "GET") return await list(env);
        if (method === "POST") return await create(request, env, now());
        return await revoke(env, idMatch![1]!, now());
    } catch {
        return error(500, "server_error");
    }
}

async function list(env: Env): Promise<Response> {
    const { results } = await env.DB.prepare(
        "SELECT id, name, prefix, created_at, last_used_at FROM api_keys WHERE revoked_at IS NULL ORDER BY created_at DESC, id DESC",
    ).all<KeyRow>();
    return jsonResponse(200, { keys: results });
}

const isJson = (request: Request) =>
    (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() === "application/json";

async function readName(request: Request): Promise<string | null> {
    const declared = Number(request.headers.get("content-length") ?? 0);
    if (declared > MAX_BODY_BYTES) return null;
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return null;
    let body: unknown;
    try {
        body = JSON.parse(text);
    } catch {
        return null;
    }
    if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
    const name = (body as Record<string, unknown>).name;
    if (typeof name !== "string") return null;
    const trimmed = name.trim();
    const length = Array.from(trimmed).length;
    return length >= 1 && length <= MAX_NAME_LENGTH ? trimmed : null;
}

async function create(request: Request, env: Env, now: number): Promise<Response> {
    if (!isJson(request)) return error(415, "bad_request");
    const name = await readName(request);
    if (name === null) return error(400, "bad_request");

    const key = crypto.randomUUID();
    const id = crypto.randomUUID();
    const prefix = key.slice(0, 8);

    // The cap is enforced inside the INSERT so concurrent creates cannot
    // overshoot it: no row inserted means the cap was already reached.
    const res = await env.DB.prepare(
        `INSERT INTO api_keys (id, name, key_hash, prefix, created_at)
         SELECT ?1, ?2, ?3, ?4, ?5
         WHERE (SELECT COUNT(*) FROM api_keys WHERE revoked_at IS NULL) < ?6
         RETURNING id`,
    )
        .bind(id, name, await hashKey(key), prefix, now, MAX_KEYS)
        .all<{ id: string }>();
    if (res.results.length === 0) return error(409, "too_many_keys");

    return jsonResponse(201, {
        id,
        name,
        prefix,
        created_at: now,
        last_used_at: null,
        key,
    });
}

async function revoke(env: Env, id: string, now: number): Promise<Response> {
    if (!ID_REGEX.test(id)) return error(404, "not_found");
    const res = await env.DB.prepare(
        "UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL RETURNING id",
    )
        .bind(now, id)
        .all<{ id: string }>();
    if (res.results.length === 0) return error(404, "not_found");
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}
