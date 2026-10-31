// The ChatAgent Durable Object (APP-API-CONTRACT.md section 43): one per sub-agent. The Worker wakes it when the agent
// is started or gets a message; its alarm runs the agent's next reply (chat.ts runAgentTurn) with the same deps as the
// chat's own replies: the model through the ModelRelay, the code in the Worker Loader sandbox, the main Durable Object for
// studio jobs. The reply runs inside the alarm because work after a Durable Object's response does not survive. The
// rules are in chat-agents.ts (tested under node); this file only wires them to the runtime. Imported only by the Worker
// entry (index.ts): `cloudflare:workers` does not exist under node.
import { getContainer } from "@cloudflare/containers";
import { DurableObject } from "cloudflare:workers";
import { runAgentTurn } from "./chat";
import { AgentRunnerCore, handleAgentRoute } from "./chat-agents";
import { loaderRunner } from "./chat-loader";
import { relayFetch } from "./model-fetch";
import { opBase } from "./registry/context";
import { REGISTRY } from "./registry/index";
import { chatDepsFrom } from "./registry/ops/chat";
import type { EdgeDeps } from "./studio-edge";
import type { ContainerStub, WorkerEnv } from "./worker";

type Env = WorkerEnv & { COBALT: DurableObjectNamespace<any>; LOADER?: unknown; MODEL_RELAY?: unknown };

export class ChatAgent extends DurableObject<Env> {
    private core: AgentRunnerCore;

    constructor(ctx: DurableObjectState, env: Env) {
        super(ctx, env);
        const storage = ctx.storage;
        this.core = new AgentRunnerCore({
            storage: { get: (k) => storage.get(k), put: (k, v) => storage.put(k, v) },
            setAlarm: async (inMs) => {
                const at = Date.now() + inMs;
                const cur = await storage.getAlarm();
                if (cur === null || cur > at) await storage.setAlarm(at);
            },
            turn: async (id) => {
                const d = chatDepsFrom(this.base());
                if (!d) return "idle";
                return runAgentTurn(d, id);
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
        return handleAgentRoute(this.core, request, this.env.COBALT_API_KEY);
    }

    override async alarm(): Promise<void> {
        try {
            await this.core.tick();
        } catch (e) {
            // never let the runtime retry a whole reply: look again a little later instead
            console.error("[chat-agents] tick failed", String(e));
            await this.ctx.storage.setAlarm(Date.now() + 15_000);
        }
    }
}
