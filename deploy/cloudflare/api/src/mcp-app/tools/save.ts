// save_link: save a web link into the library (MCP-APP-CONTRACT.md section 4). The save is followed by `job_status`.
import * as z from "zod";
import { SaveOut } from "../shapes";
import type { AppTool } from "../types";
import { cut, num, plural, rec, str } from "./common";
import { madePost } from "./jobs";

const Input = z.object({
    url: z
        .string()
        .min(1)
        .max(4096)
        .refine((u) => /^https?:\/\/\S+$/i.test(u.trim()), "must be one http(s) link"),
    engine: z.enum(["auto", "cobalt", "ytdlp"]).default("auto"),
    // a gallery: "all", "first-video", or picker indices (default: its first video). Not with engine ytdlp
    items: z.union([z.literal("all"), z.literal("first-video"), z.array(z.number().int().min(0)).min(1).max(20)]).optional(),
    // also give it a public link (default: private)
    public: z.boolean().optional(),
    title: z.string().max(80).optional().describe("a custom title"),
    // seconds to wait for the save before answering that it is still going (default 8, at most 60)
    wait: z.number().min(0).max(60).optional(),
});

// a short wait: the widget follows a slow save with job_status
export const SAVE_WAIT_S = 8;

export const saveLink: AppTool<z.infer<typeof Input>> = {
    name: "save_link",
    title: "Save a link",
    description:
        "Save a video, picture or gallery from a web link (TikTok, X, YouTube, Instagram, a direct file...) into the capystore library. engine auto tries cobalt first and yt-dlp when that fails. items picks files of a gallery, public also gives it a public link, title sets a custom title, wait is how many seconds to wait (up to 60).",
    input: Input,
    output: SaveOut,
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: true },
    view: "save",
    async run(ctx, input) {
        const url = input.url.trim();
        const r = rec(
            await ctx.call("library.save", {
                url,
                wait: input.wait ?? SAVE_WAIT_S,
                ...(input.items !== undefined ? { items: input.items } : {}),
                ...(input.public !== undefined ? { public: input.public } : {}),
                ...(input.title !== undefined ? { title: input.title } : {}),
                // auto: the op's own default (cobalt, then yt-dlp)
                ...(input.engine === "auto" ? {} : { engine: input.engine }),
            }),
        );
        const sid = str(r.save_id);
        const job = sid ? `save:${sid}` : null;
        const status = str(r.status);
        const left = num(r.saves_left_today);
        const extra = { save_id: sid, saves_left_today: left };
        const tail = left !== null ? ` (${plural(left, "save")} left today)` : "";
        if (status === "ready") {
            const postId = str(r.post_id) ?? sid;
            const made = await madePost(ctx, postId);
            const title = made.post?.title ?? str(r.title) ?? "the link";
            const where = made.post ? `${made.post.kind}, post ${made.post.id}` : postId ? `post ${postId}${made.hidden ? ", hidden" : ""}` : null;
            const text = [
                `Saved “${cut(title, 80)}” to the library${where ? ` (${where})` : ""}.`,
                made.share_url ? `Share link: ${made.share_url}` : made.hidden ? "It is hidden (library_status unhides it)." : made.post?.status === "public" ? null : made.post ? "It is private; make a share link to send it." : null,
            ]
                .filter(Boolean)
                .join("\n");
            return { text: `${text}${tail}`, structured: { view: "save", state: "done", job, url, engine: input.engine, error: null, post: made.post, share_url: made.share_url, ...extra } };
        }
        if (status === "error") {
            const error = str(r.error) ?? "error.api.generic";
            return { text: `Could not save ${cut(url, 100)} (${error}).${tail}`, structured: { view: "save", state: "error", job, url, engine: input.engine, error, post: null, share_url: null, ...extra } };
        }
        const text = `Saving ${cut(url, 100)} (${status === "queued" ? "waiting in line" : "downloading"}). It is still going. Call job_status with job ${job} to check; when it is done it will be a new post in the library.${tail}`;
        return { text, structured: { view: "save", state: "running", job, url, engine: input.engine, error: null, post: null, share_url: null, ...extra } };
    },
};
