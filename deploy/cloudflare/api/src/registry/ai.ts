// The registry's chat side (APP-API-CONTRACT.md 33.3, 33.5): the `cobalt` object the model's sandboxed code calls, built
// from the ops the chat may see. Calls are namespaced (cobalt.library.search(...)); the older flat names stay as aliases
// so saved threads replay. Each call's arguments are checked with the op's zod schema. An `ask` op does not run: it is
// stored as a confirm card and the run stops.
import type { z } from "zod";
import type { JobsPort } from "../chat-jobs";
import type { ChatCollect, ChatTools } from "../chat-tools";
import { mintCollectionId } from "../share-collections";
import { forCall, type OpBase } from "./context";
import { OpError, type AiFlags, type Op, type OpContext } from "./op";
import { CONFIRM_TTL_MS, type PendingConfirm, type PendingPort } from "./pending";
import type { Registry } from "./registry";
import { argsToInput } from "./typescript";

export const chatKeyId = (threadId: string) => `chat:${threadId}`;

// A zod failure as one line the model can act on.
export function zodMessage(call: string, e: z.ZodError): string {
    const parts = e.issues.slice(0, 4).map((i) => `${i.path.length ? i.path.join(".") : "input"}: ${i.message}`);
    return `cobalt.${call}: ${parts.join("; ")}`;
}

// Fill a route's `:params` from the input (a DO op called by the AI).
const fillPath = (path: string, input: Record<string, unknown>) =>
    path.replace(/:([A-Za-z_]+)/g, (_, k: string) => encodeURIComponent(String(input[k] ?? "")));

// Run an op for a non-HTTP caller (the chat AI, a confirmed card). Returns what the model gets; a refusal throws OpError.
export async function runOp(op: Op, ctx: OpContext, input: unknown): Promise<unknown> {
    let status: number;
    let body: unknown;
    if (op.handler) {
        const out = await op.handler(ctx, input);
        if (out instanceof Response) {
            // a raw op answers with its own Response; the AI gets its JSON
            status = out.status;
            body = await out.json().catch(() => null);
        } else {
            status = out.status;
            body = out.body;
        }
    } else {
        const route = op.route!;
        const hasBody = route.method === "POST" || route.method === "PUT" || route.method === "PATCH";
        const res = await ctx.durableObject(fillPath(route.path, (input ?? {}) as Record<string, unknown>), {
            method: route.method,
            ...(hasBody ? { body: JSON.stringify(input ?? {}), headers: { "content-type": "application/json" } } : {}),
        });
        status = res.status;
        body = await res.json().catch(() => null);
    }
    if (status < 200 || status > 299) {
        const code = (body as { error?: { code?: unknown } } | null)?.error?.code;
        throw new OpError(status, typeof code === "string" ? code : "error.api.generic");
    }
    return op.ai.result ? op.ai.result(body) : body;
}

export type ChatToolboxOpts = {
    threadId: string;
    // the assistant message the reply writes (the card is shown on it)
    messageId: string | null;
    collect: ChatCollect;
    // the read tools of chat-tools.ts for this run
    legacy: ChatTools;
    flags: AiFlags;
    pending: PendingPort | null;
    // the chat's job watcher (section 33.14); null: cobalt.jobs.onDone only looks
    jobs?: JobsPort | null;
    randomBytes?: (n: number) => Uint8Array;
};

export type ChatToolbox = {
    tools: ChatTools;
    // the confirm card this run stopped on, if any
    paused(): PendingConfirm | null;
    // the jobs this run handed to the server with cobalt.jobs.onDone
    waiting(): { job: string; note: string | null }[];
};

export function chatToolbox(registry: Registry, base: OpBase, o: ChatToolboxOpts): ChatToolbox {
    let paused: PendingConfirm | null = null;
    const waiting: { job: string; note: string | null }[] = [];
    const jobs = o.jobs ?? null;
    const watchJob = jobs
        ? async (job: string, note: string | null) => {
              await jobs.watch(o.threadId, { job, message_id: o.messageId, note });
              waiting.push({ job, note });
          }
        : undefined;
    const ctx = forCall(base, {
        keyId: chatKeyId(o.threadId),
        caller: "chat",
        chat: { threadId: o.threadId, collect: o.collect, tools: o.legacy, ...(watchJob ? { watchJob } : {}) },
    });
    const tools: ChatTools = {};
    for (const op of registry.toolsFor("chat", o.flags)) {
        const fn = async (...args: unknown[]) => {
            if (paused) throw new Error("waiting for Harmony to answer the confirm card: end this run now and say in one line what you asked");
            const parsed = op.input.safeParse(argsToInput(op, args));
            if (!parsed.success) throw new Error(zodMessage(op.callName, parsed.error));
            const input = parsed.data;
            if (op.ai.tier === "ask" && (op.ai.asks ? op.ai.asks(input) : true)) {
                if (!o.pending) throw new Error(`cobalt.${op.callName} needs Harmony's ok, and confirm cards are off on this server`);
                const card = op.ai.preview ? await op.ai.preview(ctx, input) : { summary: op.ai.summary.split("\n")[0]!, effect: {} };
                const now = base.now();
                const rec: PendingConfirm = {
                    id: mintCollectionId(o.randomBytes),
                    op: op.name,
                    input,
                    summary: card.summary,
                    effect: card.effect,
                    message_id: o.messageId,
                    created_at: now,
                    expires_at: now + CONFIRM_TTL_MS,
                };
                await o.pending.put(o.threadId, rec);
                paused = rec;
                return { pending_confirm: { id: rec.id, summary: rec.summary, effect: rec.effect } };
            }
            try {
                return await runOp(op, ctx, input);
            } catch (e) {
                if (e instanceof OpError) throw new Error(e.message === e.code ? `cobalt.${op.callName} failed: ${e.code}` : e.message);
                throw e;
            }
        };
        for (const name of [op.callName, ...(op.ai.aliases ?? [])]) tools[name] = fn;
    }
    return { tools, paused: () => paused, waiting: () => [...waiting] };
}

// The op behind a stored card, run with the input it was checked with when the model asked (a confirmed "yes").
export async function runConfirmed(registry: Registry, base: OpBase, threadId: string, rec: PendingConfirm, legacy: ChatTools, collect: ChatCollect) {
    const op = registry.op(rec.op);
    if (!op) return { error: `cobalt op ${rec.op} no longer exists` };
    const ctx = forCall(base, { keyId: chatKeyId(threadId), caller: "chat", chat: { threadId, collect, tools: legacy } });
    try {
        return { result: (await runOp(op, ctx, rec.input)) ?? null };
    } catch (e) {
        return { error: e instanceof OpError ? e.code : e instanceof Error ? e.message : String(e) };
    }
}
