// Post frames (APP-API-CONTRACT.md section 52): the post's details (read, avatar, edit) and the framed copy, as routes for
// the apps, and cobalt.make.postFrame for the chat AI (and MCP).
import * as z from "zod";
import { ITEM_ID_REGEX } from "../../gate";
import {
    detailsShape,
    ensureDetails,
    parsePatch,
    patchDetails,
    POST_SITES,
    readDetails,
    type LookupDeps,
    type YtInfo,
} from "../../post-details";
import { parsePostFrameOptions, POST_CANVASES, POST_THEMES, queuePostFrame, type PostFrameOptions, type PostItemRow } from "../../post-frame";
import { YTDLP_START_PATH } from "../../ytdlp-path";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { editsDeps, JobSchema, refundRender, refuseHiddenPost, takeRender } from "./make";

const BODY_MAX = 16 * 1024;
const reply = (status: number, code: string, extra: Record<string, unknown> = {}): OpReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
    headers: { "cache-control": "no-store" },
});
const success = (status: number, body: Record<string, unknown>): OpReply => ({ status, body: { status: "success", ...body }, headers: { "cache-control": "no-store" } });

const ITEM_SELECT = `SELECT m.id, m.bucket, m.r2_key, m.bytes, m.content_type, m.width, m.height, m.duration, m.link, m.name, m.deleted_at
    FROM media_items m WHERE m.id = ?1`;

/** yt-dlp's /info through the YtDlpBox (49.6); null when the box is off or failed. */
export function ytdlpInfoFrom(ns: DurableObjectNamespace | undefined): ((url: string) => Promise<YtInfo | null>) | null {
    if (!ns) return null;
    return async (url) => {
        try {
            const box = ns.get(ns.idFromName("main"));
            const started = await box.fetch(`http://ytdlp${YTDLP_START_PATH}`, { method: "POST" });
            await started.body?.cancel().catch(() => {});
            const res = await box.fetch("http://ytdlp/info", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ url }) });
            const body = (await res.json().catch(() => null)) as ({ status?: string } & YtInfo) | null;
            return res.ok && body?.status === "success" ? body : null;
        } catch {
            return null;
        }
    };
}

/** The lookups' ports from a Worker env. */
export function lookupDepsFrom(env: OpContext["env"], db: D1Database, now: () => number): LookupDeps {
    const id = (env.TWITCH_CLIENT_ID ?? "").trim(), secret = (env.TWITCH_CLIENT_SECRET ?? "").trim();
    return {
        db,
        originals: env.ORIGINALS,
        fetch: (input, init) => fetch(input, init),
        ytdlpInfo: ytdlpInfoFrom(env.YTDLP),
        twitch: id && secret ? { clientId: id, clientSecret: secret } : null,
        now,
    };
}

async function itemOf(ctx: OpContext, id: string): Promise<PostItemRow | null> {
    const row = await ctx.db.prepare(ITEM_SELECT).bind(id).first<PostItemRow>();
    return row && row.deleted_at === null ? row : null;
}

const avatarUrlOf = (ctx: OpContext, id: string) => (ctx.url ? `${ctx.url.origin}/library/items/${id}/post-details/avatar` : null);

async function readJson(ctx: OpContext): Promise<{ ok: true; body: unknown } | { ok: false }> {
    const text = await ctx.request!.text().catch(() => null);
    if (text === null || text.length > BODY_MAX) return { ok: false };
    if (text.trim() === "") return { ok: true, body: {} };
    try {
        return { ok: true, body: JSON.parse(text) };
    } catch {
        return { ok: false };
    }
}

// GET /library/items/<id>/post-details[?refresh=1] (52.2)
export const postDetailsRoute = defineOp({
    name: "library.postDetails",
    route: { method: "GET", path: "/library/items/:id/post-details", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "Who posted a saved video, when, what they wrote (52.2)." },
    handler: async (ctx): Promise<OpReply> => {
        const id = ctx.params.id!;
        const item = await itemOf(ctx, id);
        if (!item) return reply(404, "error.library.not_found");
        if (!item.link) return reply(409, "error.post.no_link");
        try {
            const row = await ensureDetails(lookupDepsFrom(ctx.env, ctx.db, ctx.now), item.link, ctx.query.get("refresh") === "1");
            return success(200, { details: detailsShape(row, avatarUrlOf(ctx, id)) });
        } catch {
            return reply(503, "error.post.off");
        }
    },
});

// GET /library/items/<id>/post-details/avatar (52.2)
export const postAvatarRoute = defineOp({
    name: "library.postAvatar",
    route: { method: "GET", path: "/library/items/:id/post-details/avatar", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    raw: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "The stored avatar of a saved post (52.2)." },
    handler: async (ctx) => {
        const none = () => new Response(JSON.stringify({ status: "error", error: { code: "error.library.not_found" } }), { status: 404, headers: { "content-type": "application/json", "cache-control": "no-store" } });
        const item = await itemOf(ctx, ctx.params.id!);
        if (!item?.link) return none();
        const row = await readDetails(ctx.db, item.link).catch(() => null);
        if (!row?.avatar_key) return none();
        const obj = await ctx.env.ORIGINALS.get(row.avatar_key);
        if (!obj) return none();
        return new Response(obj.body, {
            status: 200,
            headers: { "content-type": obj.httpMetadata?.contentType ?? "image/jpeg", "content-length": String(obj.size), "cache-control": "private, max-age=86400" },
        });
    },
});

// PATCH /library/items/<id>/post-details (52.2, 52.3)
export const setPostDetailsRoute = defineOp({
    name: "library.setPostDetails",
    route: { method: "PATCH", path: "/library/items/:id/post-details", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "Fix a saved post's details for its post frames (52.3)." },
    handler: async (ctx): Promise<OpReply> => {
        const id = ctx.params.id!;
        const item = await itemOf(ctx, id);
        if (!item) return reply(404, "error.library.not_found");
        if (!item.link) return reply(409, "error.post.no_link");
        const b = await readJson(ctx);
        if (!b.ok) return reply(400, "error.post.bad_request", { path: "" });
        const p = parsePatch(b.body);
        if (!p.ok) return reply(400, "error.post.bad_request", { path: p.path });
        const d = lookupDepsFrom(ctx.env, ctx.db, ctx.now);
        // a row must exist to be edited: an item never looked up is looked up first
        await ensureDetails(d, item.link).catch(() => null);
        if (!(await readDetails(ctx.db, item.link))) return reply(503, "error.post.off");
        await patchDetails(ctx.db, item.link, p.patch, ctx.now());
        const row = await readDetails(ctx.db, item.link);
        return success(200, { details: detailsShape(row!, avatarUrlOf(ctx, id)) });
    },
});

// Reads the details (looked up when missing) and queues the render.
async function frame(ctx: OpContext, item: PostItemRow, options: PostFrameOptions) {
    const e = editsDeps(ctx);
    if (!e) return { status: 404, body: { status: "error", error: { code: "error.edit.off" } } };
    const row = item.link ? await ensureDetails(lookupDepsFrom(ctx.env, ctx.db, ctx.now), item.link).catch(() => null) : null;
    const t = await ctx.db
        .prepare("SELECT t.title FROM media_titles t JOIN media_items m ON t.post_key = COALESCE(m.post_key, m.id) WHERE m.id = ?1")
        .bind(item.id)
        .first<{ title: string }>()
        .catch(() => null);
    const title = t?.title ?? (item.name ?? "video").replace(/\.[A-Za-z0-9]{1,5}$/, "");
    return await queuePostFrame(e, item, row, options, title);
}

// POST /library/items/<id>/post-frame (52.2)
export const postFrameRoute = defineOp({
    name: "library.postFrame",
    route: { method: "POST", path: "/library/items/:id/post-frame", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "Make a framed copy of a saved video inside its post (52.2); the chat uses make.postFrame." },
    handler: async (ctx): Promise<OpReply> => {
        const item = await itemOf(ctx, ctx.params.id!);
        if (!item) return reply(404, "error.library.not_found");
        const b = await readJson(ctx);
        if (!b.ok) return reply(400, "error.post.bad_request", { path: "" });
        const p = parsePostFrameOptions(b.body);
        if (!p.ok) return reply(400, "error.post.bad_request", { path: p.path });
        if (!item.link && !p.options.style && Object.keys(p.options.details).length === 0) return reply(409, "error.post.no_link");
        const r = await frame(ctx, item, p.options);
        return { status: r.status, body: r.body, headers: { "cache-control": "no-store" } };
    },
});

export const makePostFrameOp = defineOp({
    name: "make.postFrame",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: z.string().regex(ITEM_ID_REGEX, "a video's file id").describe("a saved video's file id"),
        style: z.enum(POST_SITES).optional().describe("x, instagram, twitch, youtube or generic; default: from the link"),
        theme: z.enum(POST_THEMES).optional().describe("dark (default) or light"),
        canvas: z.enum(POST_CANVASES).optional().describe("fit (default, the card's own size), portrait (1080x1920) or square"),
        from: z.number().min(0).optional().describe("seconds into the video to start"),
        to: z.number().min(0).optional().describe("seconds into the video to stop"),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary:
            "Make a framed copy of a saved video: the video playing inside a drawn card like the post it came from (avatar, name, handle, date, text, likes), for X, Instagram, Twitch, YouTube and a generic card for other sites. Lands in the library as a new private video; the original stays. Returns a job.",
        params: ["id", "style", "theme", "canvas", "from", "to"],
    },
    handler: async (ctx: OpContext, input) => {
        const call = "make.postFrame";
        const item = await itemOf(ctx, input.id);
        if (!item) throw new OpError(404, "error.library.not_found", `cobalt.${call}: no file ${input.id}`);
        const pk = await ctx.db.prepare("SELECT COALESCE(post_key, id) AS k FROM media_items WHERE id = ?1").bind(item.id).first<{ k: string }>();
        await refuseHiddenPost(ctx, call, pk?.k);
        if (!item.link && !input.style) throw new OpError(409, "error.post.no_link", `cobalt.${call}: ${input.id} was not saved from a link; name a style to frame it anyway`);
        const p = parsePostFrameOptions({ style: input.style, theme: input.theme, canvas: input.canvas, from: input.from, to: input.to });
        if (!p.ok) throw new OpError(400, "error.post.bad_request", `cobalt.${call}: bad ${p.path}`);
        if (ctx.chat) await takeRender(ctx, call);
        let r;
        try {
            r = await frame(ctx, item, p.options);
        } catch (err) {
            if (ctx.chat) await refundRender(ctx, call);
            throw err;
        }
        if (r.status !== 202) {
            if (ctx.chat) await refundRender(ctx, call);
            const code = (r.body as { error?: { code?: string } }).error?.code ?? "error.api.generic";
            throw new OpError(r.status, code, `cobalt.${call}: ${code}`);
        }
        const render = (r.body as { render: { id: string; queue_ahead: number | null } }).render;
        return ok({ job: `edit:${render.id}`, status: "queued" as const, queue_ahead: render.queue_ahead ?? null });
    },
});

export const POST_FRAME_OPS = [postDetailsRoute, postAvatarRoute, setPostDetailsRoute, postFrameRoute, makePostFrameOp];
