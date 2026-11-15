// Swarm approval and review (../APP-API-CONTRACT.md section 59, Haiku agent swarms). The page (GET /swarms and
// GET /swarms/<id>) and its JSON (/api/swarms*) are served by the web Worker behind Cloudflare Access. The JSON is the
// API Worker's own swarm routes reached through the service binding with x-cobalt-service, so the owner's approve,
// decline, apply and decide calls never need a client key.
//
//   GET  /api/swarms                              recent swarms
//   GET  /api/swarms/<id>                         one swarm
//   GET  /api/swarms/<id>/changes?offset&limit    proposed changes (limit <= 200)
//   GET  /api/swarms/<id>/results?offset&limit    task results (limit <= 100)
//   GET  /api/swarms/<id>/board?q&agent&status&group&sort&offset&limit   the results board (section 62.4, limit <= 200)
//   POST /api/swarms/<id>/approve|apply           { spec_hash }
//   POST /api/swarms/<id>/decline|stop            no body
//   POST /api/swarms/<id>/changes                 { changes: [{ n, keep?, after? }] }  (<= 500)
import { verifyAccessJwt, type AccessConfig } from "./access";
import { jwksFor, type Deps, type Env } from "./keys";
import { API_BASE } from "./library";
import { SWARMS_HTML } from "./swarms/page.generated";

export const MAX_BODY_BYTES = 256 * 1024;
export const MAX_DECISIONS = 500;
export const MAX_AFTER_CHARS = 1000;

export const SWARMS_CSP =
    "default-src 'self'; base-uri 'none'; connect-src 'self'; " +
    "img-src 'self' data: https://cdn.7tv.app https://media.capybaraharmony.com; " +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

export const swarmsHeaders = (): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": SWARMS_CSP,
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
});

const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra },
    });
const err = (status: number, code: string, extra?: Record<string, string>) =>
    json(status, { status: "error", error: { code } }, extra);

type Route =
    | { name: "page" }
    | { name: "list" }
    | { name: "get"; id: string }
    | { name: "changes"; id: string }
    | { name: "results"; id: string }
    | { name: "board"; id: string }
    | { name: "action"; id: string; action: "approve" | "decline" | "stop" | "apply" };

const ID = "[A-Za-z0-9]{16}";
export function matchRoute(pathname: string): Route | null {
    if (pathname === "/swarms" || new RegExp(`^/swarms/${ID}$`).test(pathname)) return { name: "page" };
    if (pathname === "/api/swarms") return { name: "list" };
    const m = new RegExp(`^/api/swarms/(${ID})(?:/(changes|results|board|approve|decline|stop|apply))?$`).exec(pathname);
    if (!m) return null;
    const id = m[1]!;
    switch (m[2]) {
        case undefined:
            return { name: "get", id };
        case "changes":
            return { name: "changes", id };
        case "results":
            return { name: "results", id };
        case "board":
            return { name: "board", id };
        default:
            return { name: "action", id, action: m[2] as "approve" | "decline" | "stop" | "apply" };
    }
}

const allowedMethods = (r: Route): string[] =>
    r.name === "page" ? ["GET", "HEAD"] : r.name === "changes" ? ["GET", "POST"] : r.name === "action" ? ["POST"] : ["GET"];

const digits = (v: string | null, max: number, maxLen: number): string | null | "bad" => {
    if (v === null || v === "") return null;
    if (!new RegExp(`^\\d{1,${maxLen}}$`).test(v)) return "bad";
    return Number(v) <= max ? v : "bad";
};

async function readJson(request: Request): Promise<{ ok: true; value: unknown } | { ok: false; status: number }> {
    if ((request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() !== "application/json") {
        return { ok: false, status: 415 };
    }
    if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return { ok: false, status: 413 };
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return { ok: false, status: 413 };
    try {
        return { ok: true, value: JSON.parse(text) };
    } catch {
        return { ok: false, status: 400 };
    }
}

const BAD = "error.swarm.bad_request";
const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

// Rebuild the body from known fields only, so nothing else reaches the API.
function cleanDecisions(v: unknown): string | null {
    if (!isObj(v) || !Array.isArray(v.changes) || v.changes.length < 1 || v.changes.length > MAX_DECISIONS) return null;
    const out: Record<string, unknown>[] = [];
    for (const c of v.changes) {
        if (!isObj(c) || !Number.isInteger(c.n) || (c.n as number) < 0) return null;
        const d: Record<string, unknown> = { n: c.n };
        if (c.keep !== undefined) {
            if (typeof c.keep !== "boolean") return null;
            d.keep = c.keep;
        }
        if (c.after !== undefined) {
            if (typeof c.after !== "string" || c.after.length > MAX_AFTER_CHARS) return null;
            d.after = c.after;
        }
        out.push(d);
    }
    return JSON.stringify({ changes: out });
}

export async function handleSwarms(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = { teamDomain: env.ACCESS_TEAM_DOMAIN, aud: env.ACCESS_AUD, ownerEmail: env.OWNER_EMAIL };
    const auth = await verifyAccessJwt(request.headers.get("Cf-Access-Jwt-Assertion"), access, jwks, now());
    if (!auth.ok) return err(401, "unauthorized");

    const url = new URL(request.url);
    const route = matchRoute(url.pathname);
    if (!route) return err(404, "error.swarm.not_found");
    const allowed = allowedMethods(route);
    if (!allowed.includes(request.method)) return err(405, "error.swarm.method", { allow: allowed.join(", ") });
    if (route.name === "page") {
        return new Response(request.method === "HEAD" ? null : SWARMS_HTML, { status: 200, headers: swarmsHeaders() });
    }
    if (request.method === "POST" && request.headers.get("Origin") !== env.WEB_ORIGIN) return err(403, "forbidden");

    // Build the API call.
    let path: string;
    let body: string | undefined;
    switch (route.name) {
        case "list":
            path = "/swarms";
            break;
        case "get":
            path = `/swarms/${route.id}`;
            break;
        case "changes":
        case "results": {
            const max = route.name === "changes" ? 200 : 100;
            const offset = digits(url.searchParams.get("offset"), 1_000_000, 7);
            const limit = digits(url.searchParams.get("limit"), max, 3);
            if (offset === "bad" || limit === "bad" || limit === "0") return err(400, BAD);
            const q = new URLSearchParams();
            if (offset !== null) q.set("offset", offset);
            if (limit !== null) q.set("limit", limit);
            path = `/swarms/${route.id}/${route.name}${q.size ? `?${q}` : ""}`;
            if (route.name === "changes" && request.method === "POST") {
                const b = await readJson(request);
                if (!b.ok) return err(b.status, BAD);
                const clean = cleanDecisions(b.value);
                if (clean === null) return err(400, BAD);
                body = clean;
                path = `/swarms/${route.id}/changes`;
            }
            break;
        }
        case "board": {
            // known params only, each checked (section 62.4)
            const p = url.searchParams;
            const q = new URLSearchParams();
            const offset = digits(p.get("offset"), 1_000_000, 7);
            const limit = digits(p.get("limit"), 200, 3);
            const agent = digits(p.get("agent"), 5000, 4);
            if (offset === "bad" || limit === "bad" || limit === "0" || agent === "bad" || agent === "0") return err(400, BAD);
            if (offset !== null) q.set("offset", offset);
            if (limit !== null) q.set("limit", limit);
            if (agent !== null) q.set("agent", agent);
            for (const [k, max] of [["q", 200], ["group", 200]] as const) {
                const v = p.get(k);
                if (v === null || v === "") continue;
                if (v.length > max) return err(400, BAD);
                q.set(k, v);
            }
            const status = p.get("status");
            if (status) {
                if (!["queued", "running", "waiting", "done", "failed", "skipped"].includes(status)) return err(400, BAD);
                q.set("status", status);
            }
            const sort = p.get("sort");
            if (sort) {
                if (!["agent", "score", "title"].includes(sort)) return err(400, BAD);
                q.set("sort", sort);
            }
            path = `/swarms/${route.id}/board${q.size ? `?${q}` : ""}`;
            break;
        }
        case "action": {
            path = `/swarms/${route.id}/${route.action}`;
            if (route.action === "approve" || route.action === "apply") {
                const b = await readJson(request);
                if (!b.ok) return err(b.status, BAD);
                const hash = isObj(b.value) ? b.value.spec_hash : undefined;
                if (typeof hash !== "string" || !/^[A-Za-z0-9:_-]{8,128}$/.test(hash)) return err(400, BAD);
                body = JSON.stringify({ spec_hash: hash });
            }
            break;
        }
    }

    if (!env.COBALT_API_KEY) return err(502, "upstream");
    const headers = new Headers({ "x-cobalt-service": env.COBALT_API_KEY, accept: "application/json" });
    if (body !== undefined) headers.set("content-type", "application/json");
    let res: Response;
    try {
        res = await env.API.fetch(new Request(API_BASE + path, { method: request.method, headers, body }));
    } catch {
        return err(502, "upstream");
    }
    // 401/403 from the API mean the service key is wrong: never an expired login to the page.
    if (res.status === 401 || res.status === 403 || res.status >= 500) return err(502, "upstream");
    let answer: unknown;
    try {
        answer = await res.json();
    } catch {
        return err(502, "upstream");
    }
    if (!res.ok) {
        if (res.status === 404) return err(404, "error.swarm.not_found");
        // pass the API's own code through for the page to show (hash_mismatch, not_awaiting, expired, busy, ...)
        const e = isObj(answer) && isObj(answer.error) ? answer.error.code : isObj(answer) ? answer.error : undefined;
        const code = typeof e === "string" && /^[A-Za-z0-9._-]{1,80}$/.test(e) ? e : "upstream";
        return err(res.status === 400 || res.status === 409 || res.status === 410 || res.status === 429 ? res.status : 502, code);
    }
    return json(200, answer);
}
