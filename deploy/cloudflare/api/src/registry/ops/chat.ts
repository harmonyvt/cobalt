// Chat ops: the thread routes (section 27.2, moved in T7, 33.12) and the confirm card's answer (33.5). All keyed (the
// library service gets 404), with the web origin's CORS and no-store, and all 404 error.chat.off while chat is off.
import * as z from "zod";
import { livePushConfigured } from "../../apns";
import {
    answerConfirm,
    chatModelFrom,
    createThread,
    deleteThread,
    getCollage,
    getThread,
    listThreads,
    renameThread,
    sendMessage,
    type ChatDeps,
} from "../../chat";
import { agentsOn, agentsPort, type AgentsNamespace } from "../../chat-agents";
import { jobsPort, type JobsNamespace } from "../../chat-jobs";
import { ChatLivePusher } from "../../chat-live";
// the thread id pattern comes from gate.ts, not chat.ts: through chat.ts's import of the registry it would be undefined here
import { THREAD_ID_REGEX as CHAT_ID_REGEX } from "../../gate";
import type { OpBase } from "../context";
import { defineOp, type HttpMethod, type OpContext, type OpReply } from "../op";
import { CONFIRM_ID_REGEX, pendingPort } from "../pending";

// The chat's deps for this call, or null while chat is off (no model or no code runner): every /chat route is then
// 404 error.chat.off.
export function chatDepsFrom(base: OpBase): ChatDeps | null {
    const { env, edge } = base;
    const model = edge.chatModel === undefined ? chatModelFrom(env, edge.modelFetch) : edge.chatModel;
    const runner = edge.codeRunner ?? null;
    if (!model || !runner) return null;
    return {
        db: base.db,
        app: base.app(),
        mediaBaseUrl: base.mediaBaseUrl,
        shareBaseUrl: base.shareBaseUrl,
        embed: base.embed(),
        model,
        runner,
        now: base.now,
        waitUntil: edge.waitUntil,
        registry: base.registry,
        base,
        pending: pendingPort(base.container),
        jobs: env.CHAT_JOBS ? jobsPort(env.CHAT_JOBS as unknown as JobsNamespace, env.COBALT_API_KEY) : null,
        agents: agentsOn(env) ? agentsPort(env.CHAT_AGENTS as unknown as AgentsNamespace, env.COBALT_API_KEY) : null,
    };
}

const off = () => ({ status: 404, body: { status: "error", error: { code: "error.chat.off" } } });

// POST /chat/threads/<id>/confirm/<cid> {"answer": "yes"|"no"}: runs or drops the card's call, then the reply goes on
// as server-sent events (section 33.5). The body is read by answerConfirm, like the other chat routes.
export const chatConfirmOp = defineOp({
    name: "chat.confirm",
    route: { method: "POST", path: "/chat/threads/:id/confirm/:cid", params: { id: CHAT_ID_REGEX, cid: CONFIRM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    raw: true,
    input: z.object({ id: z.string(), cid: z.string() }),
    http: (ctx: OpContext) => ctx.params,
    ai: { tier: "hidden", summary: "Harmony's answer to a confirm card." },
    handler: async (ctx, input) => {
        const d = chatDepsFrom(ctx);
        if (!d) return off();
        return answerConfirm(d, ctx.request!, input.id, input.cid);
    },
});

// The thread routes' deps: chatDepsFrom plus the reply's Live Activity on the owner's other iPhones (section 27.9),
// pushed through the Durable Object.
function threadDeps(ctx: OpContext): ChatDeps | null {
    const base = chatDepsFrom(ctx);
    if (!base) return null;
    return { ...base, liveFor: chatLiveFor(ctx.env, ctx.container, ctx.now, ctx.keyId!) };
}

// The sender of a reply the server started itself: no device's key id, so every device is shown it.
export const SERVER_SENDER = "server:chat-jobs";

// A reply's Live Activity pusher (section 27.9), or undefined while push is off. `keyId` is the sender (its own device
// draws the activity itself); SERVER_SENDER (a reply the server started, section 33.14) shows it on every device.
export function chatLiveFor(env: OpBase["env"], container: OpBase["container"], now: () => number, keyId: string): ChatDeps["liveFor"] {
    if (!livePushConfigured(env)) return undefined;
    return (thread: string, prompt: string) =>
        new ChatLivePusher({
            thread,
            keyId,
            prompt,
            now,
            post: async (body) => {
                const res = await container.fetch(
                    new Request(`https://do.internal/live/chats/${thread}/state`, {
                        method: "POST",
                        headers: { "content-type": "application/json", "x-internal-key": env.COBALT_API_KEY },
                        body: JSON.stringify(body),
                    }),
                );
                if (!res.ok) {
                    await res.body?.cancel();
                    return null;
                }
                const j = (await res.json()) as { targets?: number };
                return typeof j.targets === "number" ? { targets: j.targets } : null;
            },
        });
}

const MESSAGE_ID_REGEX = /^\d{1,12}$/;

const threadRoute = (
    name: string,
    method: HttpMethod,
    path: string,
    summary: string,
    run: (d: ChatDeps, ctx: OpContext) => Promise<{ status: number; body: unknown } | Response>,
    o: { raw?: boolean; params?: Record<string, RegExp> } = {},
) =>
    defineOp({
        name,
        route: { method, path, ...(o.params ? { params: o.params } : {}) },
        auth: "key",
        runs: "worker",
        cors: true,
        // the stream keeps its own headers; every JSON answer is no-store
        noStore: !o.raw,
        ...(o.raw ? { raw: true } : {}),
        input: z.object({}),
        http: () => ({}),
        ai: { tier: "hidden", summary },
        handler: async (ctx): Promise<OpReply | Response> => {
            const d = threadDeps(ctx);
            const r = d ? await run(d, ctx) : off();
            if (r instanceof Response) return r;
            return { status: r.status, body: r.body, headers: { "cache-control": "no-store" } };
        },
    });

const ID = { id: CHAT_ID_REGEX };

export const CHAT_OPS = [
    threadRoute("chat.threads.list", "GET", "/chat/threads", "The chat threads.", (d) => listThreads(d)),
    threadRoute("chat.threads.create", "POST", "/chat/threads", "Start a chat thread.", (d, ctx) => createThread(d, ctx.request!, ctx.keyId!)),
    threadRoute("chat.threads.get", "GET", "/chat/threads/:id", "One thread with its messages.", (d, ctx) => getThread(d, ctx.params.id!), { params: ID }),
    threadRoute("chat.threads.rename", "PATCH", "/chat/threads/:id", "Rename a thread.", (d, ctx) => renameThread(d, ctx.request!, ctx.params.id!), {
        params: ID,
    }),
    threadRoute("chat.threads.delete", "DELETE", "/chat/threads/:id", "Delete a thread.", (d, ctx) => deleteThread(d, ctx.params.id!), { params: ID }),
    // the reply streams as server-sent events (27.2)
    threadRoute("chat.send", "POST", "/chat/threads/:id/messages", "Send a message; the reply streams.", (d, ctx) => sendMessage(d, ctx.request!, ctx.params.id!), {
        params: ID,
        raw: true,
    }),
    threadRoute(
        "chat.collage",
        "GET",
        "/chat/threads/:id/messages/:message/collage",
        "A reply's collage, paged (27.5).",
        (d, ctx) => getCollage(d, ctx.params.id!, ctx.params.message!, ctx.query),
        { params: { id: CHAT_ID_REGEX, message: MESSAGE_ID_REGEX } },
    ),
    chatConfirmOp,
];
