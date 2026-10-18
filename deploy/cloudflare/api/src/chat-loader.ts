// Chat code mode (APP-API-CONTRACT.md section 27): runs the model's JavaScript in a fresh Dynamic Worker
// (Worker Loader binding LOADER). The sandbox has no network (globalOutbound: null) and no bindings;
// the only way out is the `cobalt` object, whose calls come back here over Workers RPC. Imported only
// by the Worker entry (index.ts): `cloudflare:workers` does not exist under node.

import { RpcTarget } from "cloudflare:workers";
import { CODE_CPU_MS, CODE_TIMEOUT_MS, MAX_TOOL_CALLS, type CodeRun, type CodeRunner } from "./chat-limits";
import type { ChatTools } from "./chat-tools";
import { sandboxModule } from "./chat-loader-module";

class Dispatcher extends RpcTarget {
    calls = 0;
    #tools: ChatTools;
    constructor(tools: ChatTools) {
        super();
        this.#tools = tools;
    }
    async call(name: string, argsJson: string): Promise<string> {
        if (++this.calls > MAX_TOOL_CALLS) return JSON.stringify({ error: `more than ${MAX_TOOL_CALLS} tool calls in one run` });
        const fn = Object.prototype.hasOwnProperty.call(this.#tools, name) ? this.#tools[name] : undefined;
        if (!fn) return JSON.stringify({ error: `cobalt.${name} does not exist` });
        try {
            const args = JSON.parse(argsJson);
            const result = await fn(...(Array.isArray(args) ? args : [args]));
            return JSON.stringify({ result: result ?? null });
        } catch (e) {
            return JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
        }
    }
}

export function loaderRunner(loader: WorkerLoader): CodeRunner {
    return async (code: string, tools: ChatTools): Promise<CodeRun> => {
        const dispatcher = new Dispatcher(tools);
        const worker = loader.load({
            compatibilityDate: "2026-09-01",
            mainModule: "run.js",
            modules: { "run.js": sandboxModule(code) },
            globalOutbound: null,
            limits: { cpuMs: CODE_CPU_MS },
        });
        const entry = worker.getEntrypoint() as unknown as {
            evaluate(d: Dispatcher): Promise<{ result?: string; error?: string; logs: string[] }>;
        };
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
            const r = await Promise.race([
                entry.evaluate(dispatcher),
                new Promise<never>((_, reject) => {
                    timer = setTimeout(() => reject(new Error(`timed out after ${CODE_TIMEOUT_MS / 1000} s`)), CODE_TIMEOUT_MS + 2000);
                }),
            ]);
            if (r.error !== undefined) return { error: r.error, logs: r.logs ?? [], calls: dispatcher.calls };
            return { result: r.result === undefined ? null : JSON.parse(r.result), logs: r.logs ?? [], calls: dispatcher.calls };
        } catch (e) {
            // a syntax error, the CPU limit, the timeout
            return { error: e instanceof Error ? e.message : String(e), logs: [], calls: dispatcher.calls };
        } finally {
            if (timer) clearTimeout(timer);
        }
    };
}
