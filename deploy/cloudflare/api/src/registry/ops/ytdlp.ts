// yt-dlp ops (APP-API-CONTRACT.md 49.6): the chat AI's and the MCP's direct line to the yt-dlp box. AI only (no route),
// tier free, offered only while the box is deployed (the YTDLP binding).
//   ytdlp.save: save a link with yt-dlp only (no cobalt), exactly like library.save with engine "ytdlp".
//   ytdlp.info: what yt-dlp knows about a link (title, length, uploader, formats, a playlist's entries), nothing saved.
import * as z from "zod";
import { YTDLP_START_PATH } from "../../ytdlp-path";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { chatSave, SaveResult } from "./library-writes";

const Url = z
    .string()
    .min(1)
    .max(2048)
    .refine((u) => /^https?:\/\/\S+$/i.test(u.trim()), "must be one http(s) link");

const chatOnly = (ctx: OpContext) => {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", "only the chat can call this");
};

export const ytdlpSaveOp = defineOp({
    name: "ytdlp.save",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        url: Url.describe("the link (any site yt-dlp supports)"),
        public: z.boolean().optional().describe("also give it a public link (default: private)"),
        title: z.string().max(80).optional().describe("a custom title"),
        wait: z.number().min(0).max(120).optional().describe("seconds to wait for it, default and max 120"),
    }),
    output: SaveResult,
    ai: {
        tier: "free",
        only: true,
        summary:
            "Save a link into the library with yt-dlp only (no cobalt): for a site cobalt can't save, or when Harmony asks for yt-dlp. One video, at most 720p and 200 MB; no photo posts. Same answer and daily cap as library.save.",
        params: ["url"],
        options: true,
        when: (f) => f.ytdlp === true,
    },
    handler: (ctx, input) => chatSave(ctx, { ...input, engine: "ytdlp" }),
});

const Info = z.object({
    title: z.string().nullable(),
    duration: z.number().nullable().describe("seconds"),
    uploader: z.string().nullable(),
    channel: z.string().nullable(),
    extractor: z.string().nullable().describe("the yt-dlp extractor (the site)"),
    webpage_url: z.string().nullable(),
    thumbnail: z.string().nullable(),
    upload_date: z.string().nullable().describe("YYYYMMDD"),
    view_count: z.number().nullable(),
    like_count: z.number().nullable(),
    description: z.string().nullable().describe("cut to 2000 characters"),
    is_live: z.boolean(),
    playlist: z
        .object({
            title: z.string().nullable(),
            count: z.number().nullable(),
            entries: z.array(z.object({ title: z.string().nullable(), url: z.string().nullable(), duration: z.number().nullable() })).describe("the first 25"),
        })
        .nullable()
        .describe("the link is a playlist or channel: save its entries one by one"),
    formats: z
        .array(
            z.object({
                id: z.string().nullable(),
                ext: z.string().nullable(),
                width: z.number().nullable(),
                height: z.number().nullable(),
                fps: z.number().nullable(),
                vcodec: z.string().nullable(),
                acodec: z.string().nullable(),
                size: z.number().nullable().describe("bytes, often estimated"),
                note: z.string().nullable(),
            }),
        )
        .describe("what the site offers (the last 40)"),
});

export const ytdlpInfoOp = defineOp({
    name: "ytdlp.info",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ url: Url.describe("the link to look up") }),
    output: Info,
    ai: {
        tier: "free",
        only: true,
        summary:
            "What yt-dlp knows about a link without saving anything: title, length, uploader, upload date, views, description, the formats on offer, and a playlist's entries. Takes a few seconds (the box may have to wake).",
        params: ["url"],
        when: (f) => f.ytdlp === true,
    },
    handler: async (ctx, input) => {
        chatOnly(ctx);
        const ns = ctx.env.YTDLP;
        if (!ns) throw new OpError(404, "error.ytdlp.off", "yt-dlp is off on this server");
        const box = ns.get(ns.idFromName("main"));
        let res: Response;
        try {
            const started = await box.fetch(`http://ytdlp${YTDLP_START_PATH}`, { method: "POST" });
            await started.body?.cancel().catch(() => {});
            res = await box.fetch("http://ytdlp/info", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ url: input.url.trim() }),
            });
        } catch {
            throw new OpError(503, "error.studio.unavailable", "the yt-dlp box did not answer; try again in a minute");
        }
        const body = (await res.json().catch(() => null)) as ({ status?: string; error?: { code?: unknown } } & Record<string, unknown>) | null;
        if (res.status === 429) throw new OpError(429, "error.webp.busy", "yt-dlp is looking up another link; try again in a few seconds");
        if (!res.ok || body?.status !== "success") {
            const code = typeof body?.error?.code === "string" ? body.error.code : "error.api.fetch.fail";
            throw new OpError(res.status >= 400 && res.status < 600 ? res.status : 502, code, `yt-dlp could not read the link: ${code}`);
        }
        const { status: _s, ...info } = body;
        return ok(info);
    },
});

export const YTDLP_OPS = [ytdlpSaveOp, ytdlpInfoOp];
