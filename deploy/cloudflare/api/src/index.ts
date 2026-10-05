import { Container, getContainer } from "@cloudflare/containers";
import { PORT_HEADER, stripInternalHeaders, KEY_ID_HEADER, SERVICE_HEADER } from "./headers";
import { handleWebpRoute, isWebpRoute, WebpService, type WebpDeps } from "./webp";
import { ApnsClient, apnsConfigFrom, fetchTransport, helperTransport } from "./apns";
import { handleLiveRoute, isLiveRoute, LiveService } from "./live";
import { handleNotifyRoute, harkConfigFrom, isNotifyRoute, NotifyService } from "./notify";
import { handleStudioRoute, isStudioRoute, StudioService } from "./studio";
import { runSweep, scheduleSweepSoon, type SweepScheduler } from "./sweep";
import { runTelemetryRetention } from "./telemetry";
import { handleRequest, type WorkerEnv } from "./worker";

export interface Env extends WorkerEnv {
    COBALT: DurableObjectNamespace<CobaltContainer>;
    // R2 bucket `cobalt-media` (animated WebP files) and the public base URL it
    // is served from (custom domain on the bucket), with a trailing slash.
    MEDIA: R2Bucket;
    MEDIA_BASE_URL: string;
    // The private bucket `cobalt-originals`; the structural type the studio
    // code needs (OriginalsBucket) is checked against the real R2Bucket here.
    ORIGINALS: R2Bucket;
    // Worker version metadata. Its id changes on every deploy and is part of
    // the container env below, so the env fingerprint changes and the running
    // container is restarted onto the new image/helper code on the next request.
    VERSION?: { id: string; tag?: string; timestamp?: string };
}

// cobalt's API port and the webp helper's port (helper/supervisor.js).
const COBALT_PORT = 9000;
const HELPER_PORT = 9100;

export class CobaltContainer extends Container<Env> {
    defaultPort = COBALT_PORT;
    // 45 s idle (was 2 min): memory is billed on the provisioned 1 GiB for every
    // second awake, and it was the only charge on the bill (2026-10-02). Running
    // jobs keep it awake through their own polls / renewActivityTimeout.
    sleepAfter = "45s";

    private webp: WebpService;
    private studio: StudioService;
    private live: LiveService;
    private notify: NotifyService;

    constructor(ctx: DurableObjectState<{}>, env: Env) {
        super(ctx, env);
        // Worker secrets are not visible inside the container, so they are
        // handed over through envVars, which the library passes on start.
        this.envVars = {
            API_URL: env.API_URL,
            API_PORT: "9000",
            // A container rollout does not restart a running instance, and the
            // env fingerprint only covered env, so after the whole-video deploy
            // (2026-09-30) the old helper kept answering and rejected jobs
            // without `length`. The deploy id forces one restart per deploy.
            COBALT_DEPLOY_VERSION: env.VERSION?.id ?? "unknown",
            API_KEY_URL: "file:///tmp/keys.json",
            API_AUTH_REQUIRED: "1",
            CORS_WILDCARD: "0",
            CORS_URL: env.CORS_URL,
            // written to /tmp/keys.json by the image's CMD
            COBALT_KEYS_JSON: JSON.stringify({
                [env.COBALT_API_KEY]: { limit: 60 },
            }),
            // The webp helper (port 9100) only answers requests that carry this.
            COBALT_INTERNAL_KEY: env.COBALT_API_KEY,
            // Longest clip turned into a WebP (error.webp.too_long beyond it).
            // 10 s per the owner (2026-09-30: "webp animate are short anyway");
            // the clean img2webp encoder took
            // 51 s for a 9.6 s clip on the basic instance, so 10 s stays well inside
            // the 240 s encode budget without a bigger instance.
            WEBP_MAX_SECONDS: "10",
        };

        const webpDeps: WebpDeps = {
            storage: this.ctx.storage,
            bucket: this.env.MEDIA,
            mediaBaseUrl: env.MEDIA_BASE_URL,
            db: env.DB,
            now: () => Date.now(),
            sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
            ensureRunning: () =>
                this.startAndWaitForPorts([COBALT_PORT, HELPER_PORT]),
            // containerFetch renews the sleepAfter timer on every call, so each
            // poll of a running job counts as activity.
            scheduleSweep: () => this.scheduleSweepSoon(),
            helper: (path, init) => {
                const headers = new Headers(init?.headers);
                headers.set("x-internal-key", this.env.COBALT_API_KEY);
                // Job calls are async and return at once. The calls that move
                // a video (up to 200 MB) get a long budget: the result
                // download (/file) and the studio upload into the helper.
                const bulk =
                    path.startsWith("/jobs/upload") ||
                    path.startsWith("/probe") ||
                    path.startsWith("/poster") ||
                    (path.startsWith("/fetch/") && path.endsWith("/file"));
                const timeout = bulk ? 300_000 : path.endsWith("/file") ? 60_000 : 15_000;
                return this.containerFetch(
                    new Request(`http://helper${path}`, {
                        ...init,
                        headers,
                        // a streamed body needs half-duplex in some runtimes
                        ...(init?.body instanceof ReadableStream ? { duplex: "half" } : {}),
                        signal: AbortSignal.timeout(timeout),
                    } as RequestInit),
                    HELPER_PORT,
                );
            },
        };
        this.webp = new WebpService(webpDeps);

        // Live Activity push (APP-API-CONTRACT.md section 8). The APNs secrets are read
        // here and by the Worker (the capability flag); none of them goes into
        // envVars above, so the container never sees them and the env fingerprint
        // does not change. Without all three the service stores nothing and sends
        // nothing (capability false). The DO signs and builds every request; with
        // APNS_VIA=helper the helper only relays the bytes (POST /apns).
        const apnsConfig = apnsConfigFrom(env);
        this.live = new LiveService({
            storage: this.ctx.storage,
            db: env.DB,
            now: webpDeps.now,
            // a failed `end` push is retried by the sweep: arm it
            scheduleSweep: () => this.scheduleSweepSoon(),
            apns: apnsConfig
                ? new ApnsClient({
                      ...apnsConfig,
                      now: webpDeps.now,
                      // the provider token survives DO evictions (Apple: one per 20 minutes)
                      storage: this.ctx.storage,
                      transport:
                          apnsConfig.via === "helper"
                              ? helperTransport({
                                    helper: webpDeps.helper,
                                    isRunning: () => this.ctx.container?.running ?? false,
                                    ensureRunning: webpDeps.ensureRunning,
                                })
                              : fetchTransport((url, init) => fetch(url, init)),
                  })
                : null,
        });

        // Hark notification bridge (APP-API-CONTRACT.md section 9). HARK_WEBHOOK_URL is a
        // secret read only here (the Worker reads it for the capability flag); it never goes
        // into envVars, so the container never sees it. Missing or empty: the bridge is off.
        this.notify = new NotifyService({
            storage: this.ctx.storage,
            db: env.DB,
            now: webpDeps.now,
            webhookUrl: harkConfigFrom(env),
            fetch: (url, init) => fetch(url, init),
            // a failed send is retried by the sweep: arm it
            scheduleSweep: () => this.scheduleSweepSoon(),
        });

        // cobalt studio: saves a link into the private R2 bucket (advanced by
        // the studio page's polls, which reach this DO through the Worker) and
        // renders WebPs from the stored copy. The video moves helper -> R2 and
        // R2 -> helper as streams; only metadata is held here.
        this.studio = new StudioService({
            db: env.DB,
            storage: this.ctx.storage,
            originals: env.ORIGINALS,
            webp: this.webp,
            webBaseUrl: env.CORS_URL,
            now: webpDeps.now,
            sleep: webpDeps.sleep,
            ensureRunning: webpDeps.ensureRunning,
            helper: webpDeps.helper,
            scheduleSweep: webpDeps.scheduleSweep,
            isRunning: () => this.ctx.container?.running ?? false,
            // R2 needs a known length for a stream body.
            fixedLength: (stream, length, onChunk) => {
                const fls = new FixedLengthStream(length);
                // Copy chunk by chunk. `stream.pipeTo(fls.writable)` threw
                // "Inter-TransformStream ReadableStream.pipeTo() is not
                // implemented" on the containerFetch body, the error was
                // swallowed, and the R2 put waited forever until the DO was
                // killed (Workers Logs, 2026-10-01). Errors abort the writable,
                // which fails the R2 put instead of hanging it.
                void (async () => {
                    const reader = stream.getReader();
                    const writer = fls.writable.getWriter();
                    try {
                        for (;;) {
                            const { done, value } = await reader.read();
                            if (done) break;
                            await writer.write(value);
                            onChunk?.(value.byteLength);
                        }
                        await writer.close();
                    } catch (e) {
                        console.error("[studio] copy to R2 failed", String(e));
                        await writer.abort(e).catch(() => {});
                        await reader.cancel(e).catch(() => {});
                    }
                })();
                return fls.readable;
            },
            renew: () => this.renewActivityTimeout(),
            live: this.live,
            notify: this.notify,
            // server-made posters and `public: true` hosting (APP-API-CONTRACT.md section 13)
            media: env.MEDIA,
            mediaBaseUrl: env.MEDIA_BASE_URL,
        });
    }

    // ---- the job sweep (APP-API-CONTRACT.md section 6) ------------------------------
    // A render's result is collected into R2 only when somebody polls, and the
    // container sleeps 45 s after its last activity, so a client that went away
    // mid-render lost its WebP. Instead the Containers library's own scheduler
    // (schedule(), which runs inside the library's alarm loop; overriding
    // alarm() would fight it) calls sweepJobs() every few seconds for as long as
    // something is pending. Each pass makes helper calls, which renew the
    // container's activity timer, so it stays awake exactly while a job or a
    // save is pending (bounded by the budgets in StudioService.sweep()), and the
    // 45 s sleep applies as usual when nothing is.
    //
    // The pass itself and its de-duplication (storage key `sweep:at`) live in
    // sweep.ts, testable under plain node; these only wire them to the library.
    private sweepScheduler(): SweepScheduler {
        return {
            storage: this.ctx.storage,
            now: () => Date.now(),
            schedule: (seconds) => this.schedule(seconds, "sweepJobs"),
        };
    }

    async scheduleSweepSoon(): Promise<void> {
        await scheduleSweepSoon(this.sweepScheduler());
    }

    // The schedule's callback (public: the library looks the method up by name).
    async sweepJobs(): Promise<void> {
        await runSweep(this.sweepScheduler(), () => this.studio.sweep(), undefined, this.live, this.notify);
    }

    // A container rollout restarts the running instance with the env it was
    // last started with, so a rotated internal key never reaches it and every
    // request fails with auth.key.not_found. Remember which env the container
    // was started with and restart it when that no longer matches.
    private async envFingerprint(): Promise<string> {
        const digest = await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(JSON.stringify(this.envVars)),
        );
        return [...new Uint8Array(digest)]
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("");
    }

    override async onStart(): Promise<void> {
        await this.ctx.storage.put("envFingerprint", await this.envFingerprint());
    }

    override async fetch(request: Request): Promise<Response> {
        // Never let an exception escape as Cloudflare's opaque "Error 1101:
        // Worker threw exception" (seen on a /webp poll right after a deploy,
        // 2026-09-30): answer cobalt-style JSON carrying the message instead.
        try {
            return await this.handle(request);
        } catch (e) {
            const detail = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
            console.error("[cobalt-do] unhandled", detail);
            return new Response(
                JSON.stringify({ status: "error", error: { code: "error.api.generic", detail } }),
                { status: 500, headers: { "content-type": "application/json" } },
            );
        }
    }

    private async handle(request: Request): Promise<Response> {
        // Live Activity routes (token and run store, APNs) never touch the
        // container: answered first, before the env-fingerprint restart below, and
        // never through super.fetch. The key id header is the Worker's word.
        if (isLiveRoute(new URL(request.url).pathname)) {
            return handleLiveRoute(this.live, request);
        }

        // The Hark opt-in (PUT|DELETE /studio/<sid>/notify) is DO storage and D1 only, like
        // the live routes: never wakes or restarts the container.
        if (isNotifyRoute(new URL(request.url).pathname)) {
            return handleNotifyRoute(this.notify, request);
        }

        if (this.ctx.container?.running) {
            const started = await this.ctx.storage.get<string>("envFingerprint");
            if (started !== (await this.envFingerprint())) {
                try {
                    await this.destroy();
                } catch (e) {
                    console.error("[cobalt-do] destroy for env change failed", String(e));
                }
                for (let i = 0; i < 50 && this.ctx.container?.running; i++) {
                    await new Promise((r) => setTimeout(r, 200));
                }
            }
        }

        const { pathname } = new URL(request.url);
        if (isStudioRoute(pathname)) {
            // POST /studio carries the key id the Worker set after its D1
            // lookup; the render routes are capability URLs (no key).
            return handleStudioRoute(this.studio, request);
        }
        if (isWebpRoute(pathname)) {
            // The key id header is the Worker's word (set after its D1 lookup).
            return handleWebpRoute(this.webp, request);
        }

        // Defence in depth: the Worker already strips these, and the library's
        // Container.fetch would honour a client-chosen port (see headers.ts).
        if (
            request.headers.has(PORT_HEADER) ||
            request.headers.has(KEY_ID_HEADER) ||
            request.headers.has(SERVICE_HEADER)
        ) {
            request = new Request(request, {
                headers: stripInternalHeaders(request.headers),
            });
        }
        return super.fetch(request);
    }
}

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        return handleRequest(request, env, getContainer(env.COBALT, "main"));
    },
    // Daily cron (cloudflare.config.ts triggers): telemetry retention, 30 days (D1 and R2
    // only, the container and the Durable Object are not touched), and the poster backfill:
    // a kick that queues up to 100 saved videos still without a server-made poster (the
    // Durable Object only writes records and arms its sweep; the container wakes only if
    // there is something to do, and a row that failed is not tried again for a day).
    async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
        ctx.waitUntil(
            runTelemetryRetention({ db: env.DB, originals: env.ORIGINALS, now: () => Date.now() }).then(
                (r) => console.log("[telemetry] retention", JSON.stringify(r)),
                (e) => console.error("[telemetry] retention failed", e instanceof Error ? e.name : "error"),
            ),
        );
        ctx.waitUntil(
            getContainer(env.COBALT, "main")
                .fetch(
                    new Request("https://do.internal/posters/kick?limit=100", {
                        method: "POST",
                        headers: { [KEY_ID_HEADER]: "cron:posters" },
                    }),
                )
                .then(
                    async (res) => console.log("[posters] daily kick", res.status, await res.text().catch(() => "")),
                    (e) => console.error("[posters] daily kick failed", e instanceof Error ? e.name : "error"),
                ),
        );
    },
} satisfies ExportedHandler<Env>;
