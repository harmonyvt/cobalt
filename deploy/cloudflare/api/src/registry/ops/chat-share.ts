// Shared chats (APP-API-CONTRACT.md section 46): the owner's routes under /chat/threads/<id>/share. Keyed (the app's
// client key or session), CORS for the web origin, no-store. They work whether or not chat itself is on (a shared page
// outlives the model being switched off); while the share host is off they answer 404 error.share.off. The work is in
// src/chat-share.ts; the share host's /c/ pages are in src/chat-share-page.ts.
import * as z from "zod";
import { deleteChatShare, getChatShare, putChatShare, rotateChatShare, type ChatShareDeps } from "../../chat-share";
// the thread id pattern comes from gate.ts (see ops/chat.ts)
import { THREAD_ID_REGEX as CHAT_ID_REGEX } from "../../gate";
import type { StudioReply } from "../../studio";
import { defineOp, OpError, type OpContext, type OpReply } from "../op";

const shareOff = () => new OpError(404, "error.share.off", "share links are off on this server");

function deps(ctx: OpContext): ChatShareDeps {
    if (!ctx.shareBaseUrl) throw shareOff();
    return { db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl, now: ctx.now };
}
const reply = (r: StudioReply): OpReply => ({ status: r.status, body: r.body, headers: { "cache-control": "no-store" } });

const ShareShape = z.object({
    url: z.string().describe("share.../c/<key>: the only way in while it is live"),
    thread_id: z.string(),
    upto_id: z.string().describe("the last message on the page"),
    upto_at: z.number().nullable().describe("ms; when that message was written"),
    messages: z.number().describe("messages on the page"),
    behind: z.number().describe("messages written after the page's last one (an update brings them in)"),
    files: z.number().describe("videos and pictures the link streams"),
    media: z.boolean().describe("the chat's videos and pictures play on the page"),
    code: z.boolean().describe("the model's code is on the page, folded"),
    created_at: z.number(),
    updated_at: z.number(),
    opened: z.number().describe("page opens (GET)"),
    last_opened_at: z.number().nullable(),
});
const Status = z.literal("success");
const ShareReply = z.object({ status: Status, share: ShareShape });
const Params = { id: CHAT_ID_REGEX };

const route = <I>(o: {
    name: string;
    method: "GET" | "PUT" | "POST" | "DELETE";
    path: string;
    input?: z.ZodType<I>;
    output?: z.ZodType;
    summary: string;
    run: (d: ChatShareDeps, id: string, input: I) => Promise<StudioReply>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path, params: Params },
        auth: "key",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? z.object({ id: z.string() })) as z.ZodType<I>,
        badRequest: "error.chat_share.bad_request",
        ...(o.output ? { output: o.output } : {}),
        ai: { tier: "hidden", summary: o.summary },
        handler: async (ctx, input) => reply(await o.run(deps(ctx), ctx.params.id!, input)),
    });

export const CHAT_SHARE_OPS = [
    route({
        name: "chat_share.get",
        method: "GET",
        path: "/chat/threads/:id/share",
        output: z.object({ status: Status, share: ShareShape.nullable() }),
        summary: "A chat's live shared page, or null (GET /chat/threads/<id>/share).",
        run: (d, id) => getChatShare(d, id),
    }),
    route({
        name: "chat_share.put",
        method: "PUT",
        path: "/chat/threads/:id/share",
        input: z.object({
            id: z.string(),
            media: z.boolean().optional().describe("the chat's videos and pictures play on the page (default on)"),
            code: z.boolean().optional().describe("show the model's code, folded (default off)"),
            upto: z.literal("latest").optional().describe("move the page up to the chat's latest message"),
        }),
        output: ShareReply,
        summary:
            "Share a chat as a web page (201, up to its latest message), or change the live share's settings; upto \"latest\" brings in the messages written since (PUT /chat/threads/<id>/share).",
        run: (d, id, input) => putChatShare(d, id, { media: input.media, code: input.code, upto: input.upto }),
    }),
    route({
        name: "chat_share.rotate",
        method: "POST",
        path: "/chat/threads/:id/share/rotate",
        output: ShareReply,
        summary: "A new key for a chat's shared page; the old link is a 404 at once.",
        run: (d, id) => rotateChatShare(d, id),
    }),
    route({
        name: "chat_share.delete",
        method: "DELETE",
        path: "/chat/threads/:id/share",
        output: z.object({ status: Status }),
        summary: "Stop sharing a chat: its link is a 404 at once.",
        run: (d, id) => deleteChatShare(d, id),
    }),
];
