// Background removal (APP-API-CONTRACT.md section 67): a keyed library route and the studio page's capability
// route. Both hand a prepared job to the Durable Object, which calls Bria and stores the ProRes alternate.
import * as z from "zod";
import { ITEM_ID_REGEX, STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "../../gate";
import { PREVIEW_TOKEN_REGEX } from "../../mcp-preview";
import { estimateUsd, quoteFor, RMBG_MAX_SECONDS, sourceUrlFor } from "../../rmbg";
import { getSession, itemTypeOf } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";

const NoInput = z.object({});
const none = () => ({});

type FileRow = {
    id: string;
    content_type: string | null;
    duration: number | null;
    width: number | null;
    height: number | null;
    url: string | null;
    bucket: string;
    name: string | null;
    session_id: string | null;
    post_key: string | null;
    visibility: string | null;
};

const FILE_SQL =
    "SELECT id, content_type, duration, width, height, url, bucket, name, session_id, post_key, visibility FROM media_items WHERE deleted_at IS NULL";

async function hidden(ctx: OpContext, postKey: string | null): Promise<boolean> {
    if (!postKey) return false;
    const row = await ctx.db.prepare("SELECT state FROM media_hidden WHERE post_key = ?1").bind(postKey).first<{ state: string }>();
    return row?.state === "hidden";
}

async function loadItem(ctx: OpContext, id: string): Promise<FileRow | null> {
    return (await ctx.db.prepare(`${FILE_SQL} AND id = ?1`).bind(id).first<FileRow>()) ?? null;
}

function usable(row: FileRow): boolean {
    const kind = itemTypeOf(row.content_type);
    return kind === "video" || row.content_type === "image/gif";
}

async function signedSource(ctx: OpContext, row: FileRow, keyId: string): Promise<string> {
    const pub = row.bucket === "media" && row.visibility !== "private" ? row.url : null;
    return sourceUrlFor({
        secret: ctx.env.COBALT_API_KEY,
        origin: ctx.env.API_URL,
        keyId,
        itemId: row.id,
        publicUrl: pub,
        now: ctx.now(),
    });
}

function spillOf(raw: unknown): number {
    if (raw === undefined || raw === null || raw === "") return 0;
    const n = typeof raw === "number" ? raw : Number(raw);
    if (!Number.isFinite(n) || n < 0 || n > 1) throw new OpError(400, "error.rmbg.bad_request", "spill is 0 to 1");
    return Math.round(n * 1000) / 1000;
}

async function forward(ctx: OpContext, path: string, init?: RequestInit): Promise<OpReply> {
    const res = await ctx.durableObject(path, init);
    let body: unknown = null;
    try {
        body = await res.json();
    } catch {
        body = { status: "error", error: { code: "error.rmbg.failed" } };
    }
    return { status: res.status, body };
}

async function begin(ctx: OpContext, row: FileRow, owner: string, spill: number): Promise<OpReply> {
    if (await hidden(ctx, row.post_key)) throw new OpError(404, "error.rmbg.not_found");
    if (!usable(row)) throw new OpError(409, "error.rmbg.not_video", "background removal takes a video");
    if (row.duration === null || !(row.duration > 0)) throw new OpError(400, "error.rmbg.unknown_duration", "this clip has no duration");
    if (row.duration > RMBG_MAX_SECONDS) {
        throw new OpError(400, "error.rmbg.too_long", `background removal takes a clip of at most ${RMBG_MAX_SECONDS} seconds`);
    }
    if (!ctx.env.AI) throw new OpError(503, "error.rmbg.off", "background removal is off");
    const videoUrl = await signedSource(ctx, row, owner);
    return forward(ctx, "/rmbg", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            keyId: owner,
            itemId: row.id,
            seconds: row.duration,
            spill,
            videoUrl,
            sessionId: row.session_id,
            postKey: row.post_key,
            width: row.width,
            height: row.height,
            title: row.name,
        }),
    });
}

const spillInput = z.object({
    id: z.string().regex(ITEM_ID_REGEX),
    spill: z.number().min(0).max(1).optional(),
});

export const libraryRmbgQuote = defineOp({
    name: "library.rmbg.quote",
    route: { method: "GET", path: "/library/items/:id/rmbg", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: false,
    noStore: true,
    input: z.object({ id: z.string().regex(ITEM_ID_REGEX) }),
    ai: { tier: "hidden", summary: "What removing a video's background would cost." },
    handler: async (ctx, input) => {
        const row = await loadItem(ctx, input.id);
        if (!row || (await hidden(ctx, row.post_key))) throw new OpError(404, "error.rmbg.not_found");
        const quote = quoteFor(row.duration);
        if (!quote) throw new OpError(400, "error.rmbg.unknown_duration");
        return ok({ status: "success", ...quote, usd_per_second: 0.0225 });
    },
});

export const libraryRmbgStart = defineOp({
    name: "library.removeBackground",
    route: { method: "POST", path: "/library/items/:id/rmbg", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: false,
    noStore: true,
    badRequest: "error.rmbg.bad_request",
    input: spillInput,
    ai: {
        tier: "ask",
        refs: { id: "file" },
        summary: `Remove the background of a video up to ${RMBG_MAX_SECONDS}s with Bria ($${0.0225}/s). Returns a job; the result is a private ProRes alternate (role alt) you can overlay. spill (0..1) is greenscreen fringe removal.`,
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => begin(ctx, (await loadItem(ctx, input.id)) ?? failMissing(), ctx.keyId ?? "", spillOf(input.spill)),
});

export const libraryRmbgStatus = defineOp({
    name: "library.rmbg.status",
    route: { method: "GET", path: "/library/items/:id/rmbg/:job", params: { id: ITEM_ID_REGEX, job: STUDIO_JOB_REGEX } },
    auth: "key",
    runs: "worker",
    cors: false,
    noStore: true,
    input: z.object({ id: z.string(), job: z.string(), wait: z.string().optional() }),
    ai: { tier: "hidden", summary: "A background-removal job." },
    handler: async (ctx, input) => {
        const wait = Number(input.wait ?? ctx.query.get("wait") ?? "0");
        return forward(ctx, `/rmbg/${input.job}?owner=${encodeURIComponent(ctx.keyId ?? "")}&wait=${Number.isFinite(wait) ? wait : 0}`);
    },
});

const failMissing = (): never => {
    throw new OpError(404, "error.rmbg.not_found");
};

export const studioRmbgQuote = defineOp({
    name: "studio.rmbg.quote",
    route: { method: "GET", path: "/studio/:sid/rmbg", params: { sid: STUDIO_SID_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "What removing this studio clip's background would cost." },
    handler: async (ctx) => {
        const session = await getSession(ctx.db, ctx.params.sid ?? "");
        if (!session || session.expires_at <= ctx.now()) throw new OpError(404, "error.rmbg.not_found");
        const quote = quoteFor(session.duration);
        if (!quote) throw new OpError(400, "error.rmbg.unknown_duration");
        return ok({ status: "success", ...quote, usd_per_second: 0.0225 });
    },
});

export const studioRmbgStart = defineOp({
    name: "studio.rmbg",
    route: { method: "POST", path: "/studio/:sid/rmbg", params: { sid: STUDIO_SID_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    noStore: true,
    badRequest: "error.rmbg.bad_request",
    input: z.object({ sid: z.string(), spill: z.number().min(0).max(1).optional() }),
    ai: { tier: "hidden", summary: "Remove the background of the video open in a studio." },
    handler: async (ctx, input) => {
        const sid = ctx.params.sid ?? input.sid;
        const session = await getSession(ctx.db, sid);
        if (!session || session.status !== "ready" || session.expires_at <= ctx.now()) throw new OpError(404, "error.rmbg.not_found");
        const row = await ctx.db.prepare(`${FILE_SQL} AND session_id = ?1 ORDER BY item_index, id LIMIT 1`).bind(sid).first<FileRow>();
        if (!row) throw new OpError(404, "error.rmbg.not_found");
        return begin(ctx, row, `studio:${sid}`, spillOf(input.spill));
    },
});

export const studioRmbgStatus = defineOp({
    name: "studio.rmbg.status",
    route: { method: "GET", path: "/studio/:sid/rmbg/:job", params: { sid: STUDIO_SID_REGEX, job: STUDIO_JOB_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "A studio background-removal job." },
    handler: async (ctx) => {
        const wait = Number(ctx.query.get("wait") ?? "0");
        const owner = `studio:${ctx.params.sid ?? ""}`;
        return forward(ctx, `/rmbg/${ctx.params.job}?owner=${encodeURIComponent(owner)}&wait=${Number.isFinite(wait) ? wait : 0}`);
    },
});

// The signed original Bria fetches. Not an MCP preview: it does not care which MCP mode the library is in.
export const rmbgMedia = defineOp({
    name: "rmbg.media",
    route: { method: "GET", path: "/rmbg/media/:token", params: { token: PREVIEW_TOKEN_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    noStore: true,
    raw: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "A short-lived signed original for background removal." },
    handler: async (ctx) => {
        const { serveRmbgMedia } = await import("../../rmbg");
        const env = ctx.env as { ORIGINALS?: unknown; MEDIA?: unknown };
        return serveRmbgMedia(
            { db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, media: env.MEDIA as never, originals: env.ORIGINALS as never, secret: ctx.env.COBALT_API_KEY, now: ctx.now() },
            ctx.request!,
            ctx.params.token!,
        );
    },
});

export const RMBG_OPS = [libraryRmbgQuote, libraryRmbgStart, libraryRmbgStatus, studioRmbgQuote, studioRmbgStart, studioRmbgStatus, rmbgMedia];

export { estimateUsd };
