// The Swarm Durable Object (APP-API-CONTRACT.md section 59): one per swarm. The Worker wakes it when Harmony approves the
// swarm (or its apply step); its alarm runs the tasks, up to `concurrency` at once, for about 10 minutes, then sets the
// next alarm. Everything runs inside the alarm because work after a Durable Object's response does not survive, and
// everything it knows is in D1, so a deploy or an eviction picks up where it was. The rules are in swarm.ts (tested under
// node); this file only wires them to the runtime: the model through the ModelRelay (Haiku 5.5, never from the spec),
// the code in the Worker Loader sandbox. Imported only by the Worker entry (index.ts).
import { getContainer } from "@cloudflare/containers";
import { DurableObject } from "cloudflare:workers";
import { chatModelFrom, CHAT_MODEL_DEFAULT } from "./chat";
import { loaderRunner } from "./chat-loader";
import { relayFetch } from "./model-fetch";
import { opBase } from "./registry/context";
import { REGISTRY } from "./registry/index";
import type { EdgeDeps } from "./studio-edge";
import { handleSwarmRoute, swarmRunDeps, swarmTick, SwarmRunnerCore } from "./swarm";
import type { ContainerStub, WorkerEnv } from "./worker";

type Env = WorkerEnv & { COBALT: DurableObjectNamespace<any>; LOADER?: unknown; MODEL_RELAY?: unknown };

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class Swarm extends DurableObject<Env> {
    private core: SwarmRunnerCore;

    constructor(ctx: DurableObjectState, env: Env) {
        super(ctx, env);
        const storage = ctx.storage;
        this.core = new SwarmRunnerCore({
            storage: { get: (k) => storage.get(k), put: (k, v) => storage.put(k, v) },
            setAlarm: async (inMs) => {
                const at = Date.now() + inMs;
                const cur = await storage.getAlarm();
                if (cur === null || cur > at) await storage.setAlarm(at);
            },
            tick: (id) => {
                const base = this.base();
                // always Haiku 5.5, whatever CHAT_MODEL says
                const model = chatModelFrom({ ...this.env, CHAT_MODEL: CHAT_MODEL_DEFAULT }, base.edge.modelFetch);
                return swarmTick(swarmRunDeps(base, model, sleep), id);
            },
        });
    }

    private base() {
        const env = this.env;
        const edge: EdgeDeps = {
            now: () => Date.now(),
            sleep,
            codeRunner: env.LOADER ? loaderRunner(env.LOADER as WorkerLoader) : undefined,
            modelFetch: env.MODEL_RELAY ? relayFetch(env.MODEL_RELAY as any) : undefined,
        };
        const main = getContainer(env.COBALT as any, "main") as unknown as ContainerStub;
        return opBase(env, main, edge, REGISTRY);
    }

    override async fetch(request: Request): Promise<Response> {
        return handleSwarmRoute(this.core, request, this.env.COBALT_API_KEY);
    }

    override async alarm(): Promise<void> {
        try {
            await this.core.tick();
        } catch (e) {
            // never let the runtime retry a whole tick at once: look again a little later (the watchdog takes stale tasks)
            console.error("[swarm] tick failed", String(e));
            await this.ctx.storage.setAlarm(Date.now() + 30_000);
        }
    }
}
