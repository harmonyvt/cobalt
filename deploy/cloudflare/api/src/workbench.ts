// The Workbench Durable Object (APP-API-CONTRACT.md section 33.7): the chat AI's Linux box (deploy/cloudflare/workbench:
// yt-dlp, curl, ffmpeg, python3) for sites the normal tools cannot read. A Container subclass on its own container app
// (basic, one instance), one object named "main". The decisions live in src/workbench-core.ts and the outbound rule in
// src/workbench-rules.ts (no Cloudflare imports, so the tests run them under node); this file wires them to the
// Containers library. Imported only by src/index.ts, which re-exports it and ContainerProxy.
//
// The box gets no secrets (no envVars) and no internet of its own (enableInternet false): every HTTP and HTTPS request it
// makes comes to `workbenchOutbound` below through the platform's interception, which applies the public-URL rule and
// refuses our own hosts. Other ports and raw TCP have no way out.

import { Container } from "@cloudflare/containers";
import { WorkbenchCore, type BoxError, type BoxRun, type BoxStat } from "./workbench-core";
import { dailyMinutes, forwardOutbound, SLEEP_MS } from "./workbench-rules";

export interface WorkbenchEnv {
    WORKBENCH_DAILY_MINUTES?: string;
}

// The one object every chat thread shares.
export const WORKBENCH_NAME = "main";

export class Workbench extends Container<WorkbenchEnv> {
    sleepAfter = `${SLEEP_MS / 1000}s`;
    enableInternet = false;
    interceptHttps = true;

    private core: WorkbenchCore;

    constructor(ctx: DurableObjectState<{}>, env: WorkbenchEnv) {
        super(ctx, env);
        // no secrets, no env at all: the box knows nothing about the server
        this.envVars = {};
        const container = ctx.container!;
        this.core = new WorkbenchCore({
            storage: ctx.storage,
            now: () => Date.now(),
            running: () => container.running,
            start: () => this.start(),
            wipe: () => this.destroy(),
            exec: (argv, o) => container.exec(argv, o) as any,
            renew: () => this.renewActivityTimeout(),
            capMinutes: dailyMinutes(env),
        });
    }

    override async onStop(): Promise<void> {
        await this.core.stopped();
    }

    // Workers RPC from the box ops (src/registry/ops/box.ts). Refusals come back as { error }.
    async run(thread: string, cmd: string, timeoutS?: number): Promise<BoxRun | BoxError> {
        return this.core.run(thread, cmd, timeoutS);
    }

    async stat(thread: string, path: string): Promise<BoxStat | BoxError> {
        return this.core.stat(thread, path);
    }

    async read(thread: string, path: string): Promise<ReadableStream<Uint8Array> | BoxError> {
        return this.core.read(thread, path);
    }

    async usage() {
        return this.core.usage();
    }

    // Nothing reaches the box over HTTP from outside.
    override async fetch(): Promise<Response> {
        return new Response("not found", { status: 404 });
    }
}

// Every request the box makes (the library's catch-all outbound handler; set by assignment so the library's static
// setter registers it).
Workbench.outbound = (req: Request) => forwardOutbound(req, (r) => fetch(r));
