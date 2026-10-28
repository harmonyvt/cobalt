// The keyed POST request log and the link clean-up in front of it (d1/migrations/0002_request_log.sql), shared by
// worker.ts and the registry's save ops (src/registry/ops/saves.ts). No Cloudflare imports.
import { linkFrom } from "./studio";

// The normalised `url` of a JSON body, if it is one clean http(s) link.
export async function bodyLink(request: Request): Promise<string | null> {
    try {
        const body = JSON.parse(await request.clone().text());
        if (!body || typeof body !== "object" || Array.isArray(body)) return null;
        return linkFrom((body as { url?: unknown }).url);
    } catch {
        return null;
    }
}

// ---- link extraction ---------------------------------------------------------

const FIRST_URL = /https?:\/\/[^\s<>"'`]+/i;

/** First http(s) URL in free text, trailing punctuation trimmed; null if none. */
export function extractFirstUrl(text: string): string | null {
    const m = FIRST_URL.exec(text);
    if (!m) return null;
    return m[0].replace(/[),.;:!?\]}]+$/, "");
}

/**
 * If a JSON POST body's `url` is a string that isn't already a bare URL,
 * replace it with the first http(s) URL found in it. Other bodies pass through.
 */
export async function normalizeUrlField(request: Request): Promise<Request> {
    if (!(request.headers.get("content-type") ?? "").includes("json")) return request;
    let body: unknown;
    try {
        body = JSON.parse(await request.clone().text());
    } catch {
        return request;
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) return request;
    const obj = body as Record<string, unknown>;
    if (typeof obj.url !== "string") return request;
    const trimmed = obj.url.trim();
    if (/^https?:\/\/\S+$/i.test(trimmed) && trimmed === obj.url) return request;
    const found = extractFirstUrl(obj.url);
    const next = { ...obj, url: found ?? trimmed };
    const headers = new Headers(request.headers);
    headers.delete("content-length");
    return new Request(request, { body: JSON.stringify(next), headers });
}

// ---- request log (d1/migrations/0002_request_log.sql) -----------------------
// Records what a keyed POST carried and what came back, never keys. Failures
// here are swallowed: logging must not break a download.

export type BodyInfo = {
    contentType: string | null;
    bytes: number;
    keys: string;
    urlType: string;
    urlLen: number | null;
    urlPrefix: string | null;
};

export async function describeBody(request: Request): Promise<BodyInfo> {
    const contentType = request.headers.get("content-type");
    try {
        const text = await request.clone().text();
        let parsed: unknown = undefined;
        try {
            parsed = JSON.parse(text);
        } catch {
            // not JSON: keys/url stay empty
        }
        const obj =
            parsed && typeof parsed === "object" && !Array.isArray(parsed)
                ? (parsed as Record<string, unknown>)
                : null;
        const u = obj?.url;
        return {
            contentType,
            bytes: text.length,
            keys: obj ? Object.keys(obj).join(",") : "",
            urlType: u === undefined ? "missing" : Array.isArray(u) ? "array" : typeof u,
            urlLen: typeof u === "string" ? u.length : null,
            urlPrefix:
                typeof u === "string"
                    ? // never the query or userinfo: a signed link's token and a `user:pass@` are credentials (APP-API-CONTRACT.md 19)
                      u.split(/[?#]/)[0].replace(/^(https?:\/\/)[^/]*@/i, "$1").slice(0, 80)
                    : u !== undefined
                      ? JSON.stringify(u).slice(0, 80)
                      : null,
        };
    } catch {
        return { contentType, bytes: -1, keys: "", urlType: "unreadable", urlLen: null, urlPrefix: null };
    }
}

export async function logRequest(
    db: D1Database,
    route: string,
    keyId: string,
    request: Request,
    info: BodyInfo,
    res: Response,
): Promise<void> {
    try {
        let result: string | null = null;
        let errorCode: string | null = null;
        if ((res.headers.get("content-type") ?? "").includes("json")) {
            const body = (await res.clone().json().catch(() => null)) as {
                status?: unknown;
                error?: { code?: unknown };
            } | null;
            if (typeof body?.status === "string") result = body.status;
            if (typeof body?.error?.code === "string") errorCode = body.error.code;
        }
        await db
            .prepare(
                "INSERT INTO request_log (ts, route, key_id, user_agent, content_type, body_bytes, body_keys, url_type, url_len, url_prefix, status, result, error_code) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            )
            .bind(
                Date.now(),
                route,
                keyId,
                (request.headers.get("user-agent") ?? "").slice(0, 200),
                info.contentType,
                info.bytes,
                info.keys,
                info.urlType,
                info.urlLen,
                info.urlPrefix,
                res.status,
                result,
                errorCode,
            )
            .run();
    } catch {
        // never let logging fail the request
    }
}
