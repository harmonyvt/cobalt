// The Worker's request handling, separated from index.ts (which imports the
// Containers library and so cannot load under plain node) so the whole flow,
// op registry -> D1 lookup -> handler / Durable Object / container, is testable with fakes.
//
// Every API route is an op (src/registry/, APP-API-CONTRACT.md 33): this file only picks the host, checks the internal
// key, strips the internal headers, hands the request to the registry, and answers what no op takes (gate.ts).
import { shareHost, stageDepsFrom, type ContainerStub, type StageEdge } from "./deps";
import { decide, isStudioPath } from "./gate";
import { SERVICE_HEADER, stripInternalHeaders } from "./headers";
import type { PublishBucket } from "./publish";
import { serviceAuthorized } from "./service-auth";
import { countryOf } from "./keys";
import { handleOp, opBase, REGISTRY, type Registry } from "./registry/index";
import type { RouteHost } from "./registry/op";
import type { OriginalsBucket } from "./studio";
import { preflight, withStudioCors, type EdgeDeps } from "./studio-edge";

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
    // Cloudflare Images (section 39.5): cutouts decode pictures and lift subjects (`segment: "foreground"`) through it.
    // Absent: only colour cutouts of PNGs and the app's own cutouts work, and `features.cutout_auto` is false.
    IMAGES?: unknown;
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
    // "1" turns the Hark bridge on; anything else (the config's "0") keeps it off.
    HARK_NOTIFY?: string;
    // Edge-cache purge for the public bucket (section 16): the zone id (a plain var) and a Cache Purge
    // token (a secret). Absent or empty: no purge, `cache_cleared: null`.
    MEDIA_ZONE_ID?: string;
    MEDIA_PURGE_TOKEN?: string;
    // Old Discord attachment links (section 19.6): a Discord bot token, a secret. Handed to the container's helper
    // only; absent or empty means Discord links save exactly as before and `features.discord_refresh` is false.
    DISCORD_BOT_TOKEN?: string;
    // Library search (section 21): the private Hugging Face Space's URL (a plain var), the Hugging Face
    // token that may call it and the Space's own EMBED_KEY (secrets). No URL or token: search is off.
    EMBED_URL?: string;
    // The Space's Hub id (owner/name, a plain var): a sleeping Space that refuses a wake-up is restarted.
    EMBED_SPACE?: string;
    EMBED_TOKEN?: string;
    EMBED_KEY?: string;
    // Rich link pages (section 22): https://<share host>/ (a plain var). The Worker answers that host
    // itself, before the gate. Absent or empty: no pages, `share_base_url: null`.
    SHARE_BASE_URL?: string;
    // Gallery links' moving previews (section 29.1): "1" shows each video in Discord's gallery as a 4 s
    // silent WebP that plays by itself; anything else (the default) shows the real video.
    GALLERY_LOOPS?: string;
    // Roast captions (section 25): the Anthropic key and optional AI Gateway URL (secrets), the model.
    ANTHROPIC_API_KEY?: string;
    ROAST_BASE_URL?: string;
    ROAST_MODEL?: string;
    // Chat (section 27): the model (a plain var; the key is ANTHROPIC_API_KEY) and the Worker Loader
    // binding the model's code runs in. The runner itself comes in through EdgeDeps (index.ts).
    CHAT_MODEL?: string;
    LOADER?: unknown;
    // "What it's about" (section 34): the description model (a plain var; the key is ANTHROPIC_API_KEY) and Workers AI,
    // which transcribes the sound with Whisper (about-writer.ts). Without AI the words are written without the sound.
    ABOUT_MODEL?: string;
    AI?: { run(model: string, inputs: Record<string, unknown>): Promise<unknown> };
    // Stage (section 30): https://<stage host>/ (a plain var; the Worker answers that host itself, before the gate) and
    // the three Twitch secrets. Absent or not https: no stage. Missing secrets: canvas and store only.
    STAGE_BASE_URL?: string;
    TWITCH_CLIENT_ID?: string;
    TWITCH_CLIENT_SECRET?: string;
    TWITCH_EVENTSUB_SECRET?: string;
    // Editor (section 31): the EditRenderer Durable Object namespace (two instances, "r0" and "r1"). Absent: no editor,
    // every /edits route answers 404 error.edit.off and `features.editor` is false. With it, the flag also needs migration 0021.
    EDIT_RENDERER?: DurableObjectNamespace;
    // Chat saves (section 33.7): how many links one chat thread may save in any 24 hours (a plain var, default 20; "0"
    // turns the chat's saves off).
    CHAT_DAILY_SAVES?: string;
    // The chat AI's daily cap on files it starts making per thread (section 33.8, a plain var; default 10).
    CHAT_DAILY_RENDERS?: string;
    // The chat's workbench box (section 33.11): the Workbench Durable Object namespace (one object, "main") and its daily
    // cap of awake minutes (default 60, "0" turns it off). Absent: the chat AI is never offered cobalt.box.*.
    WORKBENCH?: DurableObjectNamespace;
    WORKBENCH_DAILY_MINUTES?: string;
    // The chat's job hooks (section 33.14): the ChatJobs Durable Object namespace (one object per chat thread). Absent:
    // cobalt.jobs.onDone only looks at the job, it never continues the chat.
    CHAT_JOBS?: DurableObjectNamespace;
}


// The op registry the Worker routes through (section 33); tests pass their own.
export type RegistryEdge = { registry?: Registry };

export { embedFrom, type ContainerStub, type StageEdge } from "./deps";
export { bodyLink, describeBody, extractFirstUrl, logRequest, normalizeUrlField, type BodyInfo } from "./request-log";

// Lowercase only: the API rejects a key file with any other spelling.
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function handleRequest(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    deps: Partial<EdgeDeps> & StageEdge & RegistryEdge = {},
): Promise<Response> {
    const edge: EdgeDeps = {
        now: deps.now ?? (() => Date.now()),
        sleep: deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
        fixedLength: deps.fixedLength,
        captioner: deps.captioner,
        chatModel: deps.chatModel,
        codeRunner: deps.codeRunner,
        waitUntil: deps.waitUntil,
        // the Anthropic relay (src/model-fetch.ts): without it, chat and captions call from the local colo
        modelFetch: deps.modelFetch,
    };
    const registry = deps.registry ?? REGISTRY;
    // The share, stage and other studio.* hosts are ops of their own (src/registry/ops/hosts.ts): their pages need no
    // key, never reach the API's routes, and see the request as it came.
    const host = hostOf(env, edge, deps, new URL(incoming.url).hostname);
    if (host !== "api") {
        const url = new URL(incoming.url);
        const res = await handleOp(registry, opBase(env, container, edge, registry, deps), { request: incoming, url, service: false, host });
        return res ?? new Response(null, { status: 404 });
    }
    const res = await handleInner(incoming, env, container, edge, deps);
    // Every /studio* response, rejections included, carries the studio page's
    // origin (STUDIO-CONTRACT.md); the page is the only intended caller.
    return isStudioPath(new URL(incoming.url).pathname) ? withStudioCors(res, env.CORS_URL) : res;
}

// Which of the Worker's hosts a request came to. The stage host counts only while the stage is on; any other studio.*
// host is routed here too and must not reach the API.
function hostOf(env: WorkerEnv, edge: EdgeDeps, se: StageEdge, hostname: string): RouteHost {
    const share = shareHost(env);
    if (share && hostname === share) return "share";
    const stage = stageDepsFrom(env, edge, se);
    if (stage && hostname === new URL(stage.stageBaseUrl).hostname) return "stage";
    if (hostname.startsWith("studio.")) return "studio";
    return "api";
}

async function handleInner(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    edge: EdgeDeps,
    stageEdge: StageEdge & RegistryEdge = {},
): Promise<Response> {
    // Misconfiguration must not wake (and crash-loop) the container: the
    // API refuses to load a key file that has a non-UUID key.
    if (!env.COBALT_API_KEY || !UUID_REGEX.test(env.COBALT_API_KEY)) {
        return new Response(JSON.stringify({ status: "error", error: { code: "error.api.generic" } }), {
            status: 503,
            headers: { "content-type": "application/json" },
        });
    }

    // The library service credential is read before the headers are stripped;
    // a wrong or empty value is simply "not the service".
    const isService = await serviceAuthorized(incoming.headers.get(SERVICE_HEADER), env.COBALT_API_KEY);

    // Security: drop headers only this Worker may set, from EVERY request,
    // before anything can forward it (see headers.ts).
    const request = new Request(incoming, { headers: stripInternalHeaders(incoming.headers) });

    const url = new URL(request.url);
    const origin = request.headers.get("Origin");
    const allowOrigin = origin === env.CORS_URL ? origin : undefined;

    // Every route is an op (section 33.12).
    const registry = stageEdge.registry ?? REGISTRY;
    const byOp = await handleOp(registry, opBase(env, container, edge, registry, stageEdge), { request, url, service: isService, allowOrigin, country: countryOf(incoming) });
    if (byOp) return byOp;

    // What no op takes: preflights, and a bodyless 404 for everything else.
    const decision = decide(
        {
            method: request.method,
            pathname: url.pathname,
            searchParams: url.searchParams,
            origin,
            authorization: request.headers.get("Authorization"),
            service: isService,
        },
        { corsUrl: env.CORS_URL, now: edge.now() },
    );
    // Studio preflights are answered by the Worker (204), never forwarded.
    if (decision.action === "preflight") return preflight(env.CORS_URL);
    // One named instance for everything: upstream cobalt answers its own preflights.
    if (decision.action === "forward") return container.fetch(request);
    return new Response(null, { status: decision.status });
}
