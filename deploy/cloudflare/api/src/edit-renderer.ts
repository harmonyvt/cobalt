// The EditRenderer Durable Object (APP-API-CONTRACT.md section 31.8): a Container subclass for the editor's render image
// (deploy/cloudflare/editor, port 9200). Two instances exist, named "r0" and "r1" (src/edits.ts kickRenderers); each runs
// at most one render at a time. The decisions live in src/edit-render-core.ts (no Cloudflare imports, so the tests run
// them under plain node); this file only wires them to the Containers library. Imported only by src/index.ts, which
// re-exports it (`cloudflare:workers` and the library do not exist under node), like ModelRelay.

import { Container } from "@cloudflare/containers";
import { EditRenderCore } from "./edit-render-core";
import { harkConfigFrom } from "./notify";

// The binding names this class reads (a subset of src/index.ts's Env; declared here so this file does not import index.ts).
export interface EditRendererEnv {
    DB: D1Database;
    // `cobalt-originals`: the sources, the result mp4
    ORIGINALS: R2Bucket;
    // `cobalt-media`: public sources, the poster
    MEDIA: R2Bucket;
    MEDIA_BASE_URL: string;
    // the internal key (a UUID): the render image's EDIT_INTERNAL_KEY
    COBALT_API_KEY: string;
    VERSION?: { id: string; tag?: string; timestamp?: string };
    HARK_WEBHOOK_URL?: string;
    // the main CobaltContainer namespace: an editor render's Live Activity is pushed from there (section 32)
    COBALT?: DurableObjectNamespace;
}

// the render helper's port (editor/helper/server.js)
export const EDIT_PORT = 9200;
// the header the Worker's kick carries: which of r0 / r1 this is (also read from the object's own name)
export const EDIT_INSTANCE_HEADER = "x-edit-instance";
const INSTANCE_KEY = "instance";

export class EditRenderer extends Container<EditRendererEnv> {
    defaultPort = EDIT_PORT;
    // an idle render container goes to sleep 90 s after its last call; a render in flight keeps it awake with its own polls
    sleepAfter = "90s";

    private core: EditRenderCore;
    private name: string | undefined;

    constructor(ctx: DurableObjectState<{}>, env: EditRendererEnv) {
        super(ctx, env);
        // Worker secrets are not visible inside the container, so they are handed over through envVars. The deploy id forces
        // one restart per deploy (a rollout keeps a running instance on its old image and env).
        this.envVars = {
            EDIT_INTERNAL_KEY: env.COBALT_API_KEY,
            EDIT_DEPLOY_VERSION: env.VERSION?.id ?? "unknown",
        };
        this.name = ctx.id.name;
        void ctx.blockConcurrencyWhile(async () => {
            this.name ??= await ctx.storage.get<string>(INSTANCE_KEY);
        });

        const self = this;
        this.core = new EditRenderCore({
            get instance() {
                return self.name ?? "r?";
            },
            db: env.DB,
            storage: ctx.storage,
            originals: env.ORIGINALS,
            media: env.MEDIA,
            mediaBaseUrl: env.MEDIA_BASE_URL,
            now: () => Date.now(),
            fixedLength: copyToFixedLength,
            ensureRunning: () => this.startAndWaitForPorts(EDIT_PORT),
            isRunning: () => ctx.container?.running ?? false,
            container: (path, init) => {
                const headers = new Headers(init?.headers);
                headers.set("x-internal-key", env.COBALT_API_KEY);
                return this.containerFetch(
                    new Request(`http://edit${path}`, {
                        ...init,
                        headers,
                        // a streamed body needs half-duplex in some runtimes
                        ...(init?.body instanceof ReadableStream ? { duplex: "half" } : {}),
                    } as RequestInit),
                    EDIT_PORT,
                );
            },
            renew: () => this.renewActivityTimeout(),
            schedule: (seconds) => this.schedule(seconds, "tick"),
            beforeClaim: () => this.restartOnEnvChange(),
            hark: harkConfigFrom(env),
            liveEdit: env.COBALT
                ? async (rid) => {
                      const ns = env.COBALT!;
                      const res = await ns.get(ns.idFromName("main")).fetch(`https://do.internal/live/edits/${rid}/push`, {
                          method: "POST",
                          headers: { "x-internal-key": env.COBALT_API_KEY },
                      });
                      await res.body?.cancel();
                  }
                : undefined,
        });
    }

    // A container rollout restarts the running instance with the env it was last started with, so a rotated internal key
    // never reaches it (CobaltContainer's lesson). Remember which env the container was started with and restart it when
    // that no longer matches; only while this instance holds no render (core.claimNext calls this then), since a restart
    // loses the render's work.
    private async envFingerprint(): Promise<string> {
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(this.envVars)));
        return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    }

    override async onStart(): Promise<void> {
        await this.ctx.storage.put("envFingerprint", await this.envFingerprint());
    }

    private async restartOnEnvChange(): Promise<void> {
        if (!this.ctx.container?.running) return;
        const started = await this.ctx.storage.get<string>("envFingerprint");
        if (started === (await this.envFingerprint())) return;
        try {
            await this.destroy();
        } catch (e) {
            console.error("[edit-renderer] destroy for env change failed", String(e));
        }
        for (let i = 0; i < 50 && this.ctx.container?.running; i++) {
            await new Promise((r) => setTimeout(r, 200));
        }
    }

    // POST /kick (from the Worker's binding, never the internet): arm the tick and answer 202 at once. Nothing else is
    // served and nothing is forwarded to the container.
    override async fetch(request: Request): Promise<Response> {
        try {
            const url = new URL(request.url);
            if (request.method === "POST" && url.pathname === "/kick") {
                const named = request.headers.get(EDIT_INSTANCE_HEADER);
                if (named && /^r[0-9]$/.test(named) && named !== this.name) {
                    this.name = named;
                    await this.ctx.storage.put(INSTANCE_KEY, named);
                }
                await this.core.kick();
                return new Response(null, { status: 202 });
            }
            return new Response("not found\n", { status: 404 });
        } catch (e) {
            console.error("[edit-renderer] kick failed", e instanceof Error ? `${e.name}: ${e.message}` : String(e));
            return new Response(null, { status: 500 });
        }
    }

    // The schedule's callback (public: the Containers library looks the method up by name).
    async tick(): Promise<void> {
        await this.core.tick();
    }
}

// Wraps a stream so R2 (and a fetch body) accept it: a FixedLengthStream fed by a reader/writer loop. `stream.pipeTo(fls.writable)`
// is not implemented between these streams in the Workers runtime (it threw, the error was swallowed and the consumer waited for
// ever: Workers Logs, 2026-10-01). Errors abort the writable, which fails the consumer instead of hanging it.
function copyToFixedLength(stream: ReadableStream, length: number, onChunk?: (n: number) => void): ReadableStream {
    const fls = new FixedLengthStream(length);
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
            console.error("[edit-renderer] stream copy failed", String(e));
            await writer.abort(e).catch(() => {});
            await reader.cancel(e).catch(() => {});
        }
    })();
    return fls.readable;
}
