// Chat videos (APP-API-CONTRACT.md section 45): the route POST /chat/threads/<id>/video and the chat AI's (and MCP's)
// cobalt.chat.video. Both queue a render of kind 'chat' for the editor's render containers.
import * as z from "zod";
import { getThread } from "../../chat";
import { CHAT_VIDEO_SHAPES, CHAT_VIDEO_SPEED, CHAT_VIDEO_THEMES, parseChatVideoOptions, queueChatVideo } from "../../chat-video";
import { THREAD_ID_REGEX } from "../../gate";
import { defineOp, ok, OpError, capThreadOf, type OpContext, type OpReply } from "../op";
import { chatDepsFrom } from "./chat";
import { editsDeps, JobSchema, refundRender, takeRender } from "./make";

const BODY_MAX = 4096;
const reply = (status: number, code: string, extra: Record<string, unknown> = {}): OpReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
    headers: { "cache-control": "no-store" },
});

export const chatVideoRouteOp = defineOp({
    name: "chat.video.route",
    route: { method: "POST", path: "/chat/threads/:id/video", params: { id: THREAD_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "Make a video of a chat thread (45.1)." },
    handler: async (ctx): Promise<OpReply> => {
        const chat = chatDepsFrom(ctx);
        if (!chat) return reply(404, "error.chat.off");
        const e = editsDeps(ctx);
        if (!e) return reply(404, "error.edit.off");
        const text = await ctx.request!.text().catch(() => null);
        if (text === null || text.length > BODY_MAX) return reply(400, "error.chat.bad_request", { path: "" });
        let body: unknown = {};
        if (text.trim() !== "") {
            try {
                body = JSON.parse(text);
            } catch {
                return reply(400, "error.chat.bad_request", { path: "" });
            }
        }
        const p = parseChatVideoOptions(body);
        if (!p.ok) return reply(400, "error.chat.bad_request", { path: p.path });
        const r = await queueChatVideo(e, await getThread(chat, ctx.params.id!), p.options);
        return { status: r.status, body: r.body, headers: { "cache-control": "no-store" } };
    },
});

export const chatVideoOp = defineOp({
    name: "chat.video",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        thread: z.string().regex(THREAD_ID_REGEX, "a chat thread id").optional().describe("default: this chat (MCP: required)"),
        shape: z.enum(CHAT_VIDEO_SHAPES as [string, ...string[]]).optional().describe("portrait (default, 1080x1920), landscape, square"),
        theme: z.enum(CHAT_VIDEO_THEMES).optional().describe("dark (default) or light"),
        speed: z.number().min(CHAT_VIDEO_SPEED.min).max(CHAT_VIDEO_SPEED.max).optional().describe("pacing, default 1"),
        from: z.string().regex(/^\d{1,12}$/).optional().describe("first message id"),
        to: z.string().regex(/^\d{1,12}$/).optional().describe("last message id"),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary:
            "Make an mp4 that replays a chat like a screen recording: messages type in, tool cards pop in, replies stream, shown videos play with sound (at most 180 s; costs real money: only when Harmony wants it). Lands in the library as a private post. Returns a job.",
        params: ["thread", "shape", "theme", "speed", "from", "to"],
    },
    handler: async (ctx: OpContext, input) => {
        const call = "chat.video";
        if (!ctx.chat) throw new OpError(404, "error.chat.off", `cobalt.${call}: only the chat can call this`);
        const chat = chatDepsFrom(ctx);
        const e = editsDeps(ctx);
        if (!chat || !e) throw new OpError(404, "error.edit.off", `cobalt.${call}: videos can't be made right now (the render machine is off)`);
        if (!input.thread && ctx.chat.mcp) throw new OpError(400, "error.chat.bad_request", `cobalt.${call}: name the chat thread (thread: its id)`);
        const thread = input.thread ?? capThreadOf(ctx.chat);
        const p = parseChatVideoOptions({ shape: input.shape, theme: input.theme, speed: input.speed, from: input.from, to: input.to });
        if (!p.ok) throw new OpError(400, "error.chat.bad_request", `cobalt.${call}: bad ${p.path}`);
        await takeRender(ctx, call);
        let r;
        try {
            r = await queueChatVideo(e, await getThread(chat, thread), p.options, thread === ctx.chat.threadId || thread === capThreadOf(ctx.chat));
        } catch (err) {
            await refundRender(ctx, call);
            throw err;
        }
        if (r.status !== 202) {
            await refundRender(ctx, call);
            const code = (r.body as { error?: { code?: string } }).error?.code ?? "error.api.generic";
            const path = (r.body as { path?: string }).path;
            throw new OpError(r.status, code, `cobalt.${call}: ${code}${path ? ` at ${path}` : ""}`);
        }
        const render = (r.body as { render: { id: string; queue_ahead: number | null } }).render;
        return ok({ job: `edit:${render.id}`, status: "queued", queue_ahead: render.queue_ahead ?? null });
    },
});

export const CHAT_VIDEO_OPS = [chatVideoRouteOp, chatVideoOp];
