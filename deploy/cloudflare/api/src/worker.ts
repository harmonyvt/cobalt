// The Worker's request handling, separated from index.ts (which imports the
// Containers library and so cannot load under plain node) so the whole flow,
// gate -> D1 lookup -> Durable Object / container, is testable with fakes.
import {
    capabilities,
    libraryFile,
    libraryItemDelete,
    libraryList,
    libraryMade,
    libraryPostDelete,
    libraryPostTitle,
    libraryPostersBackfill,
    libraryPublish,
    libraryStudio,
    libraryVisibility,
    libraryVisibilityMigrate,
    studioUpload,
    uploadLogInfo,
    type AppDeps,
} from "./app-routes";
import { livePushConfigured } from "./apns";
import { harkConfigured } from "./notify";
import { decide, isStudioPath } from "./gate";
import { KEY_ID_HEADER, SERVICE_HEADER, stripInternalHeaders } from "./headers";
import { lookupKey } from "./keys";
import { SERVICE_KEY_ID } from "./library";
import { publishStudio, type PublishBucket } from "./publish";
import { serviceAuthorized } from "./service-auth";
import { deleteSwitchedWebp, purgeFrom } from "./visibility";
import { ingestTelemetry } from "./telemetry";
import {
    linkFrom,
    parseSourceWait,
    parseStudioWait,
    studioErr,
    type OriginalsBucket,
} from "./studio";
import {
    preflight,
    studioSource,
    studioStatus,
    withStudioCors,
    type EdgeDeps,
} from "./studio-edge";

export interface WorkerEnv {
    API_URL: string;
    CORS_URL: string;
    // Secret UUIDv4 used ONLY between this Worker and the container.
    COBALT_API_KEY: string;
    // D1 database `cobalt-keys`, table api_keys (d1/migrations/0001_api_keys.sql)
    DB: D1Database;
    // R2 bucket `cobalt-originals` (private): stored source videos of cobalt
    // studio sessions, read only by this Worker and the Durable Object.
    ORIGINALS: OriginalsBucket;
    // R2 bucket `cobalt-media` (public) and its base URL: studio publish copies
    // an original here from the Worker itself.
    MEDIA: PublishBucket;
    MEDIA_BASE_URL: string;
    // Live Activity push (section 8). Secrets: absent or empty means no pushes and
    // `features.live_activity_push` false. The bundle id and transport have defaults.
    APNS_KEY_P8?: string;
    APNS_KEY_ID?: string;
    APNS_TEAM_ID?: string;
    APNS_BUNDLE_ID?: string;
    APNS_VIA?: string;
    // Hark notification bridge (section 9): the webhook URL, a secret. Absent, empty or not
    // an https URL means the bridge is off and `features.notify_bridge` false.
    HARK_WEBHOOK_URL?: string;
    // Edge-cache purge for the public bucket (section 16): the zone id (a plain var) and a Cache Purge
    // token (a secret). Absent or empty: no purge, `cache_cleared: null`.
    MEDIA_ZONE_ID?: string;
    MEDIA_PURGE_TOKEN?: string;
}

// The single "main" Container Durable Object (a stub in production).
export interface ContainerStub {
    fetch(request: Request): Promise<Response>;
}

// Lowercase only: the API rejects a key file with any other spelling.
const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Rejections from the Worker carry the same CORS header cobalt would send, so
// the web app can read the error code instead of seeing a network failure.
const json = (status: number, body: unknown, allowOrigin?: string) =>
    new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json",
            ...(allowOrigin ? { "access-control-allow-origin": allowOrigin } : {}),
        },
    });

function withCors(res: Response, allowOrigin?: string): Response {
    if (!allowOrigin) return res;
    const out = new Response(res.body, res);
    out.headers.set("access-control-allow-origin", allowOrigin);
    return out;
}

export async function handleRequest(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    deps: Partial<EdgeDeps> = {},
): Promise<Response> {
    const res = await handleInner(incoming, env, container, {
        now: deps.now ?? (() => Date.now()),
        sleep: deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
        fixedLength: deps.fixedLength,
    });
    // Every /studio* response, rejections included, carries the studio page's
    // origin (STUDIO-CONTRACT.md); the page is the only intended caller.
    return isStudioPath(new URL(incoming.url).pathname)
        ? withStudioCors(res, env.CORS_URL)
        : res;
}

async function handleInner(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    edge: EdgeDeps,
): Promise<Response> {
    // Misconfiguration must not wake (and crash-loop) the container: the
    // API refuses to load a key file that has a non-UUID key.
    if (!env.COBALT_API_KEY || !UUID_REGEX.test(env.COBALT_API_KEY)) {
        return json(503, {
            status: "error",
            error: { code: "error.api.generic" },
        });
    }

    // The library service credential is read before the headers are stripped;
    // a wrong or empty value is simply "not the service".
    const isService = await serviceAuthorized(
        incoming.headers.get(SERVICE_HEADER),
        env.COBALT_API_KEY,
    );

    // Security: drop headers only this Worker may set, from EVERY request,
    // before anything can forward it (see headers.ts).
    let request = new Request(incoming, {
        headers: stripInternalHeaders(incoming.headers),
    });

    const url = new URL(request.url);
    const decision = decide(
        {
            method: request.method,
            pathname: url.pathname,
            searchParams: url.searchParams,
            origin: request.headers.get("Origin"),
            authorization: request.headers.get("Authorization"),
            service: isService,
        },
        {
            corsUrl: env.CORS_URL,
            now: edge.now(),
        },
    );

    const origin = request.headers.get("Origin");
    const allowOrigin = origin === env.CORS_URL ? origin : undefined;

    if (decision.action === "reject") {
        if (decision.errorCode) {
            return json(
                decision.status,
                { status: "error", error: { code: decision.errorCode } },
                allowOrigin,
            );
        }
        return new Response(null, { status: decision.status });
    }

    if (decision.action === "studio") {
        const { sid } = decision;
        switch (decision.op) {
            case "preflight":
                return preflight(env.CORS_URL);
            case "status":
                return studioStatus(
                    env.DB,
                    container,
                    sid!,
                    parseStudioWait(url.searchParams.get("wait")),
                    edge,
                );
            case "source":
                return studioSource(env.DB, env.ORIGINALS, sid!, request, edge, {
                    container,
                    seconds: parseSourceWait(url.searchParams.get("wait")),
                });
            default:
                // render_create / render_status: the Durable Object owns the
                // helper and the job records. The session id in the path is
                // the credential, so there is no key and no key id here.
                return container.fetch(request);
        }
    }

    // GET /capabilities: the key's state is reported, never refused.
    if (decision.action === "capabilities") {
        const r = await capabilities(
            appDeps(env, container, edge),
            decision.auth,
            decision.key,
            livePushConfigured(env),
            harkConfigured(env),
            ...(await helperHas(container)),
        );
        return new Response(JSON.stringify(r.body), {
            status: r.status,
            headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
    }

    if (decision.action === "lookup" || decision.action === "service") {
        let keyId: string | null;
        if (decision.action === "service") {
            // Already authenticated by the gate (constant-time header check).
            keyId = SERVICE_KEY_ID;
        } else {
            try {
                keyId = await lookupKey(env.DB, decision.key, Date.now());
            } catch {
                // Fail closed: never forward when D1 cannot vouch for the key.
                return json(
                    503,
                    { status: "error", error: { code: "error.api.generic" } },
                    allowOrigin,
                );
            }
            if (keyId === null) {
                return json(
                    401,
                    {
                        status: "error",
                        error: { code: "error.api.auth.key.invalid" },
                    },
                    allowOrigin,
                );
            }
        }

        // POST /studio/<sid>/publish: D1 + R2 only, answered right here.
        if (decision.then === "studio_publish") {
            const r = await publishStudio(
                {
                    db: env.DB,
                    originals: env.ORIGINALS,
                    media: env.MEDIA,
                    mediaBaseUrl: env.MEDIA_BASE_URL,
                    now: edge.now,
                    purge: purgeFrom(env),
                },
                decision.params!.sid,
                keyId,
            );
            return json(r.status, r.body, allowOrigin);
        }

        // POST /telemetry: D1 + R2 only, no CORS. Dispatched here, before anything that
        // reads a body or writes the request log: a batch never reaches `request_log`.
        if (decision.then === "telemetry_ingest") {
            const r = await ingestTelemetry({ db: env.DB, originals: env.ORIGINALS, now: edge.now }, request, keyId);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store", ...r.headers },
            });
        }

        // The app's routes: D1 + R2 only (the one Durable Object call is the
        // internal adopt path). Handled before anything below, which reads
        // request bodies: an upload body is never read, only streamed to R2, and
        // never reaches the request log.
        if (decision.then === "studio_upload") {
            const r = await studioUpload(appDeps(env, container, edge), request, keyId, url.searchParams);
            const res = json(r.status, r.body, allowOrigin);
            await logRequest(env.DB, "PUT /studio/upload", keyId, request, uploadLogInfo(request), res);
            return res;
        }
        if (decision.then === "library_list") {
            const r = await libraryList(appDeps(env, container, edge), url.searchParams);
            return json(r.status, r.body, allowOrigin);
        }
        if (decision.then === "library_file") {
            return libraryFile(appDeps(env, container, edge), decision.params!.id, request);
        }
        if (decision.then === "library_publish") {
            const r = await libraryPublish(appDeps(env, container, edge), decision.params!.id, keyId);
            return json(r.status, r.body, allowOrigin);
        }
        // PATCH /library/items/<id>/visibility and POST /library/visibility/migrate (section 16):
        // D1 + R2 only, no CORS (the web Worker calls them through the service binding).
        if (decision.then === "library_visibility" || decision.then === "library_visibility_migrate") {
            const deps = appDeps(env, container, edge);
            const r =
                decision.then === "library_visibility"
                    ? await libraryVisibility(deps, decision.params!.id, request, keyId)
                    : await libraryVisibilityMigrate(deps, url.searchParams);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }
        // DELETE /media/<name>.webp of a webp that was switched private once: its bytes live in the
        // private bucket now, so both copies go here; any other name is the webp service's as before.
        if (decision.then === "media_delete") {
            const r = await deleteSwitchedWebp(appDeps(env, container, edge), decision.params!.name);
            if (r) return json(r.status, r.body, allowOrigin);
        }
        if (decision.then === "library_studio") {
            // `?queue=1`: the adopted session joins the server's line (section 17.3)
            const queue = url.searchParams.get("queue");
            if (queue !== null && queue !== "" && !["1", "true", "0", "false"].includes(queue)) {
                return json(400, { status: "error", error: { code: "error.library.bad_request" } }, allowOrigin);
            }
            const r = await libraryStudio(appDeps(env, container, edge), decision.params!.id, keyId, queue === "1" || queue === "true");
            return json(r.status, r.body, allowOrigin);
        }
        // DELETE /library/items/<id>/post: D1 + R2 only, no CORS (the web page does not call it).
        if (decision.then === "library_post_delete") {
            const r = await libraryPostDelete(appDeps(env, container, edge), decision.params!.id);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }

        // DELETE /library/items/<id> (one item or made file, section 18.4) and PUT /library/items/<id>/made (a crop or an
        // export made on the device, 18.6): D1 + R2 only, no CORS. The made body is streamed to R2, never read here.
        if (decision.then === "library_item_delete") {
            const r = await libraryItemDelete(appDeps(env, container, edge), decision.params!.id);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }
        if (decision.then === "library_made") {
            const r = await libraryMade(appDeps(env, container, edge), decision.params!.id, request, keyId, url.searchParams);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }

        // PATCH /library/items/<id>/post: a post's custom title (section 15). D1 only, no CORS.
        if (decision.then === "library_post_title") {
            const r = await libraryPostTitle(appDeps(env, container, edge), decision.params!.id, request, keyId);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }

        // POST /library/posters/backfill: queues the posters still missing (section 13). The
        // Durable Object only writes records; no CORS (the page does not call it).
        if (decision.then === "library_posters_backfill") {
            const raw = url.searchParams.get("limit");
            const limit = raw !== null && /^\d{1,4}$/.test(raw) ? Number(raw) : undefined;
            const r = await libraryPostersBackfill(appDeps(env, container, edge), limit);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }

        // Live Activity push: handled by the Durable Object (token and run store, APNs),
        // which never wakes the container. Dispatched here, before anything that
        // reads a body or writes the request log: a relay arrives about once a
        // second and must never reach `request_log`. The caller's key is not
        // passed on; only its id, which the Worker just verified.
        if (
            decision.then === "live_start_token" ||
            decision.then === "live_run" ||
            decision.then === "live_state" ||
            decision.then === "live_selftest" ||
            // the Hark opt-in (also DO-only: D1 ownership check and DO storage)
            decision.then === "studio_notify" ||
            // the share sheet's recent saves (DO storage for the list, D1 for the rows)
            decision.then === "studio_recent" ||
            // the server's line (section 17): the line, its Hark summary and the cancel routes. DO
            // storage and D1; never wake the container
            decision.then === "studio_line" ||
            decision.then === "studio_line_notify" ||
            decision.then === "studio_cancel" ||
            // a slideshow made from a gallery's items and the retry of the items that failed to save (section 18):
            // the Durable Object owns the line and the helper
            decision.then === "studio_slideshow" ||
            decision.then === "studio_gallery_image" ||
            decision.then === "studio_items_retry"
        ) {
            const headers = new Headers(request.headers);
            headers.delete("Authorization");
            headers.set(KEY_ID_HEADER, keyId);
            return container.fetch(new Request(request, { headers }));
        }

        // Clients (the macOS Shortcut) may send free text as `url`; take the
        // first http(s) link from it. The Shortcut's own "Get URLs from Input"
        // step produced an empty string on macOS 27 (2026-09-30), so link
        // extraction lives here instead.
        // Log AFTER extraction: the Shortcut sends its share input plus the
        // whole clipboard as `url`, and clipboard text must never be stored.
        // (Logging before extraction captured clipboard snippets; scrubbed
        // 2026-09-30.) When no link is found, only the length is kept.
        if (request.method === "POST") request = await normalizeUrlField(request);
        const logEntry =
            request.method === "POST" ? await describeBody(request) : null;
        if (logEntry && logEntry.urlPrefix !== null && !/^https?:\/\//i.test(logEntry.urlPrefix)) {
            logEntry.urlPrefix = null;
        }

        // POST /studio: a body with no http(s) link is refused here, before the
        // container is involved (the log row still records the attempt).
        if (decision.then === "studio_create") {
            const link = await bodyLink(request);
            if (link === null) {
                const res = json(400, studioErr(400, "error.studio.no_link").body);
                if (logEntry) await logRequest(env.DB, "POST /studio", keyId, request, logEntry, res);
                return res;
            }
        }

        const headers = new Headers(request.headers);
        if (decision.then) {
            // /webp and /media: same Durable Object, with the caller's key id
            // (trusted only because it was set here, after the D1 lookup). The
            // client's own key is not passed on.
            headers.delete("Authorization");
            headers.set(KEY_ID_HEADER, keyId);
            const res = await container.fetch(new Request(request, { headers }));
            if (logEntry) await logRequest(env.DB, `POST ${url.pathname}`, keyId, request, logEntry, res);
            return withCors(res, allowOrigin);
        }
        // The container only knows the internal key.
        headers.set("Authorization", `Api-Key ${env.COBALT_API_KEY}`);
        const res = await container.fetch(new Request(request, { headers }));
        if (logEntry) await logRequest(env.DB, "POST /", keyId, request, logEntry, res);
        return res;
    }

    // One named instance for everything: tunnels created by POST / live in
    // that process's memory and must be served by the same one.
    return container.fetch(request);
}

// What the container's helper has said it can do (the Durable Object keeps what it last answered; it never wakes the
// container for this): the slideshow routes (`gallery`), and the webp slideshow, the gallery image and `item` renders
// (`make`). Any failure is "not yet": the capability is simply not offered.
async function helperHas(container: ContainerStub): Promise<[boolean, boolean]> {
    try {
        const res = await container.fetch(new Request("https://do.internal/helper/caps", { headers: { [KEY_ID_HEADER]: "worker:capabilities" } }));
        if (res.status !== 200) return [false, false];
        const body = (await res.json()) as { gallery?: unknown; make?: unknown };
        return [body?.gallery === true, body?.make === true];
    } catch {
        return [false, false];
    }
}

// What the app's routes need, wired to this request's bindings. The one call
// into the Durable Object is the internal adopt path a stored video continues
// into; the caller's key id (set here, after the D1 lookup) travels in the
// header the Worker strips from every client request.
function appDeps(env: WorkerEnv, container: ContainerStub, edge: EdgeDeps): AppDeps {
    return {
        db: env.DB,
        originals: env.ORIGINALS,
        media: env.MEDIA,
        mediaBaseUrl: env.MEDIA_BASE_URL,
        apiUrl: env.API_URL,
        webUrl: env.CORS_URL,
        now: edge.now,
        purge: purgeFrom(env),
        fixedLength: edge.fixedLength ?? ((n) => new FixedLengthStream(n)),
        // Queues the missing posters in the Durable Object (records only; it answers at once).
        kickPosters: async (limit) => {
            const res = await container.fetch(
                new Request(`https://do.internal/posters/kick${limit ? `?limit=${limit}` : ""}`, {
                    method: "POST",
                    headers: { [KEY_ID_HEADER]: "worker:posters" },
                }),
            );
            let parsed: unknown = null;
            try {
                parsed = await res.json();
            } catch {
                // not JSON: reported as a generic failure below
            }
            return { status: res.status, body: parsed ?? { status: "error", error: { code: "error.api.generic" } } };
        },
        adopt: async (keyId, body) => {
            const res = await container.fetch(
                new Request("https://do.internal/studio/upload/adopt", {
                    method: "POST",
                    headers: { "content-type": "application/json", [KEY_ID_HEADER]: keyId },
                    body: JSON.stringify(body),
                }),
            );
            let parsed: unknown = null;
            try {
                parsed = await res.json();
            } catch {
                // not JSON: reported as a generic failure below
            }
            return { status: res.status, body: parsed ?? { status: "error", error: { code: "error.api.generic" } } };
        },
    };
}

// The normalised `url` of a JSON body, if it is one clean http(s) link.
async function bodyLink(request: Request): Promise<string | null> {
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
                    ? u.slice(0, 80)
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
