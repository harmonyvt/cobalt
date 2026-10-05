// cobalt logs: the owner's read side of the app's crash and log telemetry
// (../../TELEMETRY-CONTRACT.md). The page (GET /logs) and its JSON API
// (/api/logs*) are served by the web Worker, which reads the SAME D1 database the
// API Worker writes (telemetry_events, telemetry_crashes) and the private R2
// bucket cobalt-originals for a crash's payload. Read-only: nothing here writes,
// so there is no Origin check, but every route needs the owner's Cloudflare Access
// JWT, verified by the same code as /api/keys and /api/library.
//
//   GET /logs                                   the page
//   GET /api/logs?level=&cat=&before=&limit=    events, newest first
//   GET /api/logs/crashes?kind=&before=&limit=  crashes, newest first
//   GET /api/logs/crashes/<id>                  one crash: row + R2 payload + its events
import { verifyAccessJwt, type AccessConfig } from "./access";
import { jwksFor, type Deps, type Env } from "./keys";
import { LOGS_HTML } from "./logs/page.generated";

export const LEVELS = ["debug", "info", "warn", "error"] as const;
export const CATS = ["app", "pipeline", "upload", "share", "photos", "sync", "net", "store", "ui", "live"] as const;
export const KINDS = ["crash", "hang", "cpu", "disk", "launch", "unclean_exit"] as const;

export const DEFAULT_EVENT_LIMIT = 100;
export const MAX_EVENT_LIMIT = 200;
export const DEFAULT_CRASH_LIMIT = 50;
export const MAX_CRASH_LIMIT = 100;
// A crash's R2 document is bounded by the 256 KB ingest limit; refuse anything
// bigger than this (it would not be one of ours).
const MAX_CRASH_DOC_BYTES = 1_000_000;

// Same shape as the library page's CSP, minus the API and the media bucket: the
// page only talks to its own origin.
export const LOGS_CSP =
    "default-src 'self'; base-uri 'none'; connect-src 'self'; " +
    "img-src 'self' data:; " +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

export const logsHeaders = (): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": LOGS_CSP,
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
});

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" },
    });

const err = (status: number, code: string, extra?: Record<string, string>) => {
    const res = json(status, { status: "error", error: { code } });
    for (const [k, v] of Object.entries(extra ?? {})) res.headers.set(k, v);
    return res;
};

type Route = { name: "page" } | { name: "events" } | { name: "crashes" } | { name: "crash"; id: string };

export function matchRoute(pathname: string): Route | null {
    if (pathname === "/logs") return { name: "page" };
    if (pathname === "/api/logs") return { name: "events" };
    if (pathname === "/api/logs/crashes") return { name: "crashes" };
    const m = /^\/api\/logs\/crashes\/([0-9A-Za-z_-]{8,64})$/.exec(pathname);
    return m ? { name: "crash", id: m[1]! } : null;
}

const ALLOWED: Record<Route["name"], string[]> = {
    page: ["GET", "HEAD"],
    events: ["GET"],
    crashes: ["GET"],
    crash: ["GET"],
};

export async function handleLogs(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
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

    // 2. Route shape and method.
    const { pathname, searchParams } = new URL(request.url);
    const route = matchRoute(pathname);
    if (!route) return err(404, "error.logs.not_found");
    const allowed = ALLOWED[route.name];
    if (!allowed.includes(request.method)) return err(405, "error.logs.method", { allow: allowed.join(", ") });

    try {
        switch (route.name) {
            case "page":
                return new Response(request.method === "HEAD" ? null : LOGS_HTML, { status: 200, headers: logsHeaders() });
            case "events":
                return await listEvents(env, searchParams);
            case "crashes":
                return await listCrashes(env, searchParams);
            case "crash":
                return await crashDetail(env, route.id);
        }
    } catch (e) {
        console.error("[logs] failed", e instanceof Error ? e.name : "error");
        return err(500, "error.logs.server");
    }
}

// ---- query parsing -------------------------------------------------------------------

type Cursor = { ts: number; id: string | null };
const bad = () => err(400, "error.logs.bad_request");

// `before` is a ts alone ("1800000000000") or "<ts>_<id>" (what next_before returns,
// so rows that share a millisecond are not skipped between pages).
function parseCursor(v: string | null): Cursor | null | "bad" {
    if (v === null || v === "") return null;
    const m = /^(\d{1,16})(?:_([0-9A-Za-z_-]{1,64}))?$/.exec(v);
    return m ? { ts: Number(m[1]), id: m[2] ?? null } : "bad";
}

function parseLimit(v: string | null, def: number, max: number): number | "bad" {
    if (v === null || v === "") return def;
    if (!/^\d{1,4}$/.test(v)) return "bad";
    const n = Number(v);
    return n >= 1 && n <= max ? n : "bad";
}

// "warn,error" -> ["warn","error"]; any unknown value is a 400.
function parseList<T extends string>(v: string | null, allowed: readonly T[]): T[] | null | "bad" {
    if (v === null || v === "") return null;
    const parts = [...new Set(v.split(",").map((s) => s.trim()))];
    return parts.every((p) => (allowed as readonly string[]).includes(p)) ? (parts as T[]) : "bad";
}

const cursorString = (ts: number, id: string) => `${ts}_${id}`;

function where(
    filters: { col: string; values: string[] | null }[],
    cursor: Cursor | null,
): { sql: string; params: (string | number)[] } {
    const clauses: string[] = [];
    const params: (string | number)[] = [];
    for (const f of filters) {
        if (!f.values) continue;
        clauses.push(`${f.col} IN (${f.values.map(() => "?").join(", ")})`);
        params.push(...f.values);
    }
    if (cursor) {
        if (cursor.id === null) {
            clauses.push("ts < ?");
            params.push(cursor.ts);
        } else {
            clauses.push("(ts < ? OR (ts = ? AND id < ?))");
            params.push(cursor.ts, cursor.ts, cursor.id);
        }
    }
    return { sql: clauses.length ? `WHERE ${clauses.join(" AND ")}` : "", params };
}

const parseData = (s: string | null): Record<string, string | number | boolean> | null => {
    if (!s) return null;
    try {
        const v = JSON.parse(s);
        return v && typeof v === "object" && !Array.isArray(v) ? v : null;
    } catch {
        return null;
    }
};

// ---- GET /api/logs -------------------------------------------------------------------

type EventRow = {
    id: string;
    install: string | null;
    ts: number;
    level: string;
    cat: string;
    msg: string;
    data: string | null;
    version: string | null;
    build: string | null;
    platform: string | null;
    device: string | null;
    process: string | null;
    received_at: number;
};

async function listEvents(env: Env, q: URLSearchParams): Promise<Response> {
    const level = parseList(q.get("level"), LEVELS);
    const cat = parseList(q.get("cat"), CATS);
    const cursor = parseCursor(q.get("before"));
    const limit = parseLimit(q.get("limit"), DEFAULT_EVENT_LIMIT, MAX_EVENT_LIMIT);
    if (level === "bad" || cat === "bad" || cursor === "bad" || limit === "bad") return bad();

    const w = where(
        [
            { col: "level", values: level },
            { col: "cat", values: cat },
        ],
        cursor,
    );
    const { results } = await env.DB.prepare(
        `SELECT id, install, ts, level, cat, msg, data, version, build, platform, device, process, received_at
         FROM telemetry_events ${w.sql} ORDER BY ts DESC, id DESC LIMIT ?`,
    )
        .bind(...w.params, limit + 1)
        .all<EventRow>();
    const more = results.length > limit;
    const page = results.slice(0, limit);
    return json(200, {
        status: "success",
        events: page.map((r) => ({ ...r, data: parseData(r.data) })),
        next_before: more && page.length ? cursorString(page[page.length - 1]!.ts, page[page.length - 1]!.id) : null,
    });
}

// ---- GET /api/logs/crashes -----------------------------------------------------------

type CrashRow = {
    id: string;
    install: string | null;
    ts: number;
    kind: string;
    summary: string;
    r2_key: string;
    version: string | null;
    build: string | null;
    platform: string | null;
    device: string | null;
    process: string | null;
    received_at: number;
};

// r2_key is internal; key_id is never selected.
const crashShape = ({ r2_key: _r2, ...r }: CrashRow) => r;

async function listCrashes(env: Env, q: URLSearchParams): Promise<Response> {
    const kind = parseList(q.get("kind"), KINDS);
    const cursor = parseCursor(q.get("before"));
    const limit = parseLimit(q.get("limit"), DEFAULT_CRASH_LIMIT, MAX_CRASH_LIMIT);
    if (kind === "bad" || cursor === "bad" || limit === "bad") return bad();

    const w = where([{ col: "kind", values: kind }], cursor);
    const { results } = await env.DB.prepare(
        `SELECT id, install, ts, kind, summary, r2_key, version, build, platform, device, process, received_at
         FROM telemetry_crashes ${w.sql} ORDER BY ts DESC, id DESC LIMIT ?`,
    )
        .bind(...w.params, limit + 1)
        .all<CrashRow>();
    const more = results.length > limit;
    const page = results.slice(0, limit);
    return json(200, {
        status: "success",
        crashes: page.map(crashShape),
        next_before: more && page.length ? cursorString(page[page.length - 1]!.ts, page[page.length - 1]!.id) : null,
    });
}

// ---- GET /api/logs/crashes/<id> ------------------------------------------------------

async function crashDetail(env: Env, id: string): Promise<Response> {
    const row = await env.DB.prepare(
        `SELECT id, install, ts, kind, summary, r2_key, version, build, platform, device, process, received_at
         FROM telemetry_crashes WHERE id = ?1`,
    )
        .bind(id)
        .first<CrashRow>();
    if (!row) return err(404, "error.logs.not_found");

    // The object key comes from the row, never from the URL.
    type CrashDoc = { app?: unknown; payload?: unknown; events?: unknown };
    let doc = null as CrashDoc | null;
    const obj = await env.ORIGINALS.get(row.r2_key);
    if (obj && obj.size <= MAX_CRASH_DOC_BYTES) {
        try {
            const parsed: unknown = await obj.json();
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) doc = parsed as CrashDoc;
        } catch {
            doc = null;
        }
    }
    return json(200, {
        status: "success",
        crash: {
            ...crashShape(row),
            app: doc?.app ?? null,
            payload: doc?.payload ?? null,
            events: Array.isArray(doc?.events) ? doc.events : [],
            // the row exists but its object is gone or unreadable
            payload_missing: doc === null,
        },
    });
}
