// Chat ops (APP-API-CONTRACT.md 33.5): the confirm card's answer. The other chat routes (section 27.2) still go through
// the old chain until T7 moves them.
import * as z from "zod";
import { answerConfirm, CHAT_ID_REGEX, chatModelFrom, type ChatDeps } from "../../chat";
import type { OpBase } from "../context";
import { defineOp, type OpContext } from "../op";
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

export const CHAT_OPS = [chatConfirmOp];
