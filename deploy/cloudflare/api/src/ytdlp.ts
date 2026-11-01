// The YtDlpBox Durable Object (APP-API-CONTRACT.md section 49): a Container subclass for the yt-dlp image
// (deploy/cloudflare/ytdlp, port 9300). One instance, "main". The studio save (src/studio.ts) reaches it from the
// CobaltContainer object through the YTDLP binding with the same single-file /fetch routes it uses with the cobalt
// helper; this object adds the internal key and starts the container. Imported only by src/index.ts, which re-exports
// it (`cloudflare:workers` and the library do not exist under node).

import { Container } from "@cloudflare/containers";

export const YTDLP_PORT = 9300;
// POST to this path: start the container (restarting it first when its env is stale) and answer 204 once the port is up
export const YTDLP_START_PATH = "/__start";

export interface YtDlpEnv {
    // the internal key (a UUID): the image's YTDLP_INTERNAL_KEY
    COBALT_API_KEY: string;
    VERSION?: { id: string; tag?: string; timestamp?: string };
}

export class YtDlpBox extends Container<YtDlpEnv> {
    defaultPort = YTDLP_PORT;
    // a save polls every couple of seconds; an idle box sleeps 2 minutes after its last call (its files go with it)
    sleepAfter = "2m";

    constructor(ctx: DurableObjectState<{}>, env: YtDlpEnv) {
        super(ctx, env);
        // Worker secrets are not visible inside the container, so they are handed over through envVars. The deploy id forces
        // one restart per deploy (a rollout keeps a running instance on its old image and env).
        this.envVars = {
            YTDLP_INTERNAL_KEY: env.COBALT_API_KEY,
            YTDLP_DEPLOY_VERSION: env.VERSION?.id ?? "unknown",
        };
    }

    private async envFingerprint(): Promise<string> {
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(this.envVars)));
        return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    }

    override async onStart(): Promise<void> {
        await this.ctx.storage.put("envFingerprint", await this.envFingerprint());
    }

    // Only called when a save starts (saves run one at a time), so a restart never loses a download in flight.
    private async startFresh(): Promise<void> {
        if (this.ctx.container?.running) {
            const started = await this.ctx.storage.get<string>("envFingerprint");
            if (started !== (await this.envFingerprint())) {
                try {
                    await this.destroy();
                } catch (e) {
                    console.error("[ytdlp] destroy for env change failed", String(e));
                }
            }
        }
        await this.startAndWaitForPorts(YTDLP_PORT);
    }

    // A failure is thrown, not answered: the studio's call then rejects and counts as a miss (retried for 30 s), never as
    // the save's own error.
    override async fetch(request: Request): Promise<Response> {
        const url = new URL(request.url);
        if (url.pathname === YTDLP_START_PATH) {
            if (request.method !== "POST") return new Response(null, { status: 405 });
            await this.startFresh();
            return new Response(null, { status: 204 });
        }
        const headers = new Headers(request.headers);
        headers.set("x-internal-key", this.env.COBALT_API_KEY);
        return await this.containerFetch(
            new Request(`http://ytdlp${url.pathname}${url.search}`, {
                method: request.method,
                headers,
                body: request.body,
                ...(request.body ? { duplex: "half" } : {}),
            } as RequestInit),
            YTDLP_PORT,
        );
    }
}
