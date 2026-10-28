// The ChatJobs Durable Object (APP-API-CONTRACT.md section 33.14): one per chat thread. It keeps the jobs the chat AI
// handed over with cobalt.jobs.onDone, looks at them on its alarm, and continues the chat when one ends. The rules are in
// chat-jobs.ts (tested under node); this file only wires them to the runtime. Imported only by the Worker entry
// (index.ts): `cloudflare:workers` does not exist under node.
//
// The continuation runs inside the alarm (work after a Durable Object's response does not survive), with the same deps
// the Worker's chat route builds: the model through the ModelRelay, the code in the Worker Loader sandbox, the main
// Durable Object for studio jobs and Live Activities.
import { getContainer } from "@cloudflare/containers";
import { DurableObject } from "cloudflare:workers";
import { resumeAfterJobs } from "./chat";
import { ChatJobsCore, handleChatJobsRoute } from "./chat-jobs";
import { loaderRunner } from "./chat-loader";
import { relayFetch } from "./model-fetch";
import { chatKeyId } from "./registry/ai";
import { forCall, opBase } from "./registry/context";
import { REGISTRY } from "./registry/index";
import { chatDepsFrom, chatLiveFor, SERVER_SENDER } from "./registry/ops/chat";
import { waitJob } from "./registry/ops/make";
import type { EdgeDeps } from "./studio-edge";
import type { ContainerStub, WorkerEnv } from "./worker";

type Env = WorkerEnv & { COBALT: DurableObjectNamespace<any>; LOADER?: unknown; MODEL_RELAY?: unknown };

export class ChatJobs extends DurableObject<Env> {
    private core: ChatJobsCore;

    constructor(ctx: DurableObjectState, env: Env) {
        super(ctx, env);
        const storage = ctx.storage;
        this.core = new ChatJobsCore({
            storage: {
                get: (k) => storage.get(k),
                put: (k, v) => storage.put(k, v),
                delete: (k) => storage.delete(k),
                list: (o) => storage.list(o),
            },
            now: () => Date.now(),
            setAlarm: async (inMs) => {
                const at = Date.now() + inMs;
                const cur = await storage.getAlarm();
                if (cur === null || cur > at) await storage.setAlarm(at);
            },
            check: (thread, job) => {
                const base = this.base();
                const ctx = forCall(base, { keyId: chatKeyId(thread), caller: "chat", chat: { threadId: thread, collect: { look: [], show: [], collage: null }, tools: {} } });
                return waitJob(ctx, job, 0);
            },
            resume: (thread, ended) => {
                const base = this.base();
                const d = chatDepsFrom(base);
                if (!d) return Promise.resolve("gone" as const);
                return resumeAfterJobs({ ...d, liveFor: chatLiveFor(base.env, base.container, base.now, SERVER_SENDER) }, thread, ended);
            },
        });
    }

    private base() {
        const env = this.env;
        const edge: EdgeDeps = {
            now: () => Date.now(),
            sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
            codeRunner: env.LOADER ? loaderRunner(env.LOADER as WorkerLoader) : undefined,
            modelFetch: env.MODEL_RELAY ? relayFetch(env.MODEL_RELAY as any) : undefined,
        };
        const main = getContainer(env.COBALT as any, "main") as unknown as ContainerStub;
        return opBase(env, main, edge, REGISTRY);
    }

    override async fetch(request: Request): Promise<Response> {
        return handleChatJobsRoute(this.core, request, this.env.COBALT_API_KEY);
    }

    override async alarm(): Promise<void> {
        try {
            await this.core.tick();
        } catch (e) {
            // never let the runtime retry a whole tick (it would run a continuation twice): arm the next one instead
            console.error("[chat-jobs] tick failed", String(e));
            await this.ctx.storage.setAlarm(Date.now() + 10_000);
        }
    }
}
