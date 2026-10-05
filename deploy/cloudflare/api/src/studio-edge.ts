// The Worker's own studio routes: everything that needs only D1 and R2, so the
// container is never involved (and never woken) by them. Free of Cloudflare
// imports so the tests run it under plain node.
//   OPTIONS /studio*             preflight (the gate has checked the origin)
//   GET /studio/<sid>[?wait=N]   session status from D1; while "saving" it is
//                                 forwarded to the Durable Object, which
//                                 advances the save and long-polls (a save only
//                                 moves while polls go through the DO)
//   GET|HEAD /studio/<sid>/source[?wait=N]  the stored video, Range aware; with
//                                 wait the request is held while the save runs
// Response headers follow ../STUDIO-CONTRACT.md.

import {
    CORS_EXPOSE,
    CORS_HEADERS,
    CORS_METHODS,
    getSession,
    listSuccessfulRenders,
    parseRange,
    sessionBody,
    studioErr,
    type OriginalsBucket,
    type SessionRow,
    type StudioReply,
} from "./studio";
import { sessionItem } from "./visibility";

export type EdgeDeps = {
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    // Workers' FixedLengthStream (the library publish copy); injectable because
    // Node has none. Defaults to the real one in the Worker.
    fixedLength?: (n: number) => {
        readable: ReadableStream<Uint8Array>;
        writable: WritableStream<Uint8Array>;
    };
};

// The one "main" Container Durable Object (a stub in production).
export interface StudioContainer {
    fetch(request: Request): Promise<Response>;
}

const jsonResponse = (r: StudioReply, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(r.body), {
        status: r.status,
        headers: { "content-type": "application/json", ...extra },
    });

export function preflight(corsUrl: string): Response {
    return new Response(null, {
        status: 204,
        headers: {
            "access-control-allow-origin": corsUrl,
            "access-control-allow-methods": CORS_METHODS,
            "access-control-allow-headers": CORS_HEADERS,
            "access-control-max-age": "600",
        },
    });
}

// Adds the fixed studio CORS origin to any response of a /studio* route.
export function withStudioCors(res: Response, corsUrl: string): Response {
    const out = new Response(res.body, res);
    out.headers.set("access-control-allow-origin", corsUrl);
    return out;
}

// Looks a session up (404 unknown, 410 expired). Whether a "saving" session is
// still alive is the Durable Object's call (it knows the last advance attempt).
async function loadSession(
    db: D1Database,
    sid: string,
    now: number,
): Promise<{ row: SessionRow } | { reply: StudioReply }> {
    const row = await getSession(db, sid);
    if (!row) return { reply: studioErr(404, "error.studio.not_found") };
    if (now > row.expires_at) return { reply: studioErr(410, "error.studio.expired") };
    return { row };
}

export async function studioStatus(
    db: D1Database,
    container: StudioContainer,
    sid: string,
    waitSeconds: number,
    deps: EdgeDeps,
): Promise<Response> {
    let row: SessionRow;
    try {
        const found = await loadSession(db, sid, deps.now());
        if ("reply" in found) return jsonResponse(found.reply);
        row = found.row;
    } catch {
        return jsonResponse(studioErr(503, "error.api.generic"));
    }

    if (row.status === "saving") {
        // The DO advances the save (start the helper fetch, poll it, copy the
        // video into R2) for up to `wait` seconds and answers with the session,
        // shaped exactly like the answer below. This is the only thing that
        // makes a save progress, so it must not be answered from D1 alone.
        // Why the DO couldn't answer travels in `x-studio-advance` on the
        // fallback, so a stuck save is diagnosable from outside (a silent
        // fallback hid a stalled save on 2026-10-01).
        let why = "";
        try {
            const res = await container.fetch(
                new Request(`https://do.internal/studio/${sid}/advance?wait=${waitSeconds}`),
            );
            if (res.status < 500) return res;
            why = `do ${res.status} ${(await res.text().catch(() => "")).slice(0, 300)}`;
        } catch (e) {
            why = `throw ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300);
        }
        const fallback = jsonResponse({ status: 200, body: sessionBody(row, [], null, await sessionItem(db, row.r2_key)) });
        fallback.headers.set("x-studio-advance", why.replace(/[\r\n]+/g, " "));
        return fallback;
    }

    try {
        const renders = row.status === "ready" ? await listSuccessfulRenders(db, sid) : [];
        return jsonResponse({ status: 200, body: sessionBody(row, renders, null, await sessionItem(db, row.r2_key)) });
    } catch {
        return jsonResponse(studioErr(503, "error.api.generic"));
    }
}

// A ready session never changes again (the only writers are `WHERE status =
// 'saving'`), so a range request, which the player repeats many times a second,
// can skip the D1 round trip. Short TTL and a per-binding map, so a swept
// session or a test's fresh database never sees a stale row; expiry is still
// checked on every hit.
const READY_CACHE_MS = 60_000;
const READY_CACHE_MAX = 64;
const readyCache = new WeakMap<object, Map<string, { row: SessionRow; at: number }>>();
const servable = (row: SessionRow) =>
    row.status === "ready" && !!row.r2_key && row.bytes !== null && row.bytes > 0;

async function loadSourceSession(
    db: D1Database,
    sid: string,
    now: number,
): Promise<{ row: SessionRow } | { reply: StudioReply }> {
    let cache = readyCache.get(db);
    const hit = cache?.get(sid);
    if (hit && now >= hit.at && now - hit.at < READY_CACHE_MS) {
        if (now > hit.row.expires_at) return { reply: studioErr(410, "error.studio.expired") };
        return { row: hit.row };
    }
    const found = await loadSession(db, sid, now);
    if ("row" in found && servable(found.row)) {
        if (!cache) readyCache.set(db, (cache = new Map()));
        if (cache.size >= READY_CACHE_MAX) cache.clear();
        cache.set(sid, { row: found.row, at: now });
    }
    return found;
}

// Hold-open options for ?wait=N (APP-API-CONTRACT.md section 11).
export type SourceWait = { container: StudioContainer; seconds: number };

// A held request pauses at least this long between advances, so a Durable Object
// that answers at once (or fails) cannot turn the hold into a hot loop.
const HOLD_MIN_STEP_MS = 500;
const HOLD_MAX_POLLS = 400;

export async function studioSource(
    db: D1Database,
    bucket: OriginalsBucket,
    sid: string,
    request: Request,
    deps: EdgeDeps,
    wait?: SourceWait,
): Promise<Response> {
    // HEAD ignores wait: it is a probe, answered from the row as it is.
    const holding = !!wait && wait.seconds > 0 && request.method === "GET";
    let row: SessionRow;
    try {
        let found = await loadSourceSession(db, sid, deps.now());
        if (holding && "row" in found && found.row.status === "saving") {
            // While the save runs the DO must be polled (it is the only thing that
            // moves a save), so repeat its own long-poll until the row leaves
            // "saving" or the deadline passes.
            const deadline = deps.now() + wait.seconds * 1000;
            for (let i = 0; i < HOLD_MAX_POLLS; i++) {
                const remaining = deadline - deps.now();
                if (remaining <= 0) break;
                const started = deps.now();
                try {
                    await wait.container.fetch(
                        new Request(
                            `https://do.internal/studio/${sid}/advance?wait=${Math.min(25, Math.ceil(remaining / 1000))}`,
                        ),
                    );
                } catch {
                    // the row decides below; a DO that is down just costs the pause
                }
                if (deps.now() - started < HOLD_MIN_STEP_MS) {
                    await deps.sleep(Math.max(0, Math.min(HOLD_MIN_STEP_MS, deadline - deps.now())));
                }
                found = await loadSourceSession(db, sid, deps.now());
                if (!("row" in found) || found.row.status !== "saving") break;
            }
        }
        if ("reply" in found) return jsonResponse(found.reply);
        row = found.row;
    } catch {
        return jsonResponse(studioErr(503, "error.api.generic"));
    }
    // A held request reports a failed save as it is; without wait it stays the
    // 409 it has always been.
    if (holding && row.status === "error") {
        return jsonResponse(studioErr(422, row.error_code ?? "error.api.generic"));
    }
    const size = row.bytes;
    if (row.status !== "ready" || !row.r2_key || size === null || !(size > 0)) {
        return jsonResponse(studioErr(409, "error.studio.not_ready"));
    }

    const base: Record<string, string> = {
        "content-type": row.content_type || "video/mp4",
        "accept-ranges": "bytes",
        "cache-control": "private, max-age=3600",
        "access-control-expose-headers": CORS_EXPOSE,
    };

    const range = parseRange(request.headers.get("range"), size);
    if (range.kind === "unsatisfiable") {
        return jsonResponse(studioErr(416, "error.studio.bad_range"), {
            "content-range": `bytes */${size}`,
            "accept-ranges": "bytes",
            "access-control-expose-headers": CORS_EXPOSE,
        });
    }

    const partial = range.kind === "partial";
    const length = partial ? range.length : size;
    const headers = new Headers(base);
    headers.set("content-length", String(length));
    if (partial) {
        headers.set(
            "content-range",
            `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`,
        );
    }
    const status = partial ? 206 : 200;

    if (request.method === "HEAD") return new Response(null, { status, headers });

    let obj;
    try {
        obj = await bucket.get(
            row.r2_key,
            partial ? { range: { offset: range.offset, length: range.length } } : undefined,
        );
    } catch {
        return jsonResponse(studioErr(502, "error.studio.storage"));
    }
    if (!obj) return jsonResponse(studioErr(404, "error.studio.not_found"));
    return new Response(obj.body, { status, headers });
}
