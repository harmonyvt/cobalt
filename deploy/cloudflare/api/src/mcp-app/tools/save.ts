// save_link: save a web link into the library (MCP-APP-CONTRACT.md section 4). The save is followed by `job_status`.
import * as z from "zod";
import { SaveOut } from "../shapes";
import type { AppTool } from "../types";
import { cut, rec, str } from "./common";
import { madePost } from "./jobs";

const Input = z.object({
    url: z
        .string()
        .min(1)
        .max(4096)
        .refine((u) => /^https?:\/\/\S+$/i.test(u.trim()), "must be one http(s) link"),
    engine: z.enum(["auto", "cobalt", "ytdlp"]).default("auto"),
});

// a short wait: the widget follows a slow save with job_status
export const SAVE_WAIT_S = 8;

export const saveLink: AppTool<z.infer<typeof Input>> = {
    name: "save_link",
    title: "Save a link",
    description:
        "Save a video, picture or gallery from a web link (TikTok, X, YouTube, Instagram, a direct file...) into the capystore library. engine auto tries cobalt first and yt-dlp when that fails.",
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
                wait: SAVE_WAIT_S,
                // auto: the op's own default (cobalt, then yt-dlp)
                ...(input.engine === "auto" ? {} : { engine: input.engine }),
            }),
        );
        const sid = str(r.save_id);
        const job = sid ? `save:${sid}` : null;
        const status = str(r.status);
        if (status === "ready") {
            const made = await madePost(ctx, str(r.post_id) ?? sid);
            const title = made.post?.title ?? str(r.title) ?? "the link";
            const text = [`Saved “${cut(title, 80)}” to the library${made.post ? ` (${made.post.kind}, post ${made.post.id})` : ""}.`, made.share_url ? `Share link: ${made.share_url}` : made.post?.status === "public" ? null : "It is private; make a share link to send it."]
                .filter(Boolean)
                .join("\n");
            return { text, structured: { view: "save", state: "done", job, url, engine: input.engine, error: null, post: made.post, share_url: made.share_url } };
        }
        if (status === "error") {
            const error = str(r.error) ?? "error.api.generic";
            return { text: `Could not save ${cut(url, 100)} (${error}).`, structured: { view: "save", state: "error", job, url, engine: input.engine, error, post: null, share_url: null } };
        }
        const text = `Saving ${cut(url, 100)} (${status === "queued" ? "waiting in line" : "downloading"}). It is still going. Call job_status with job ${job} to check; when it is done it will be a new post in the library.`;
        return { text, structured: { view: "save", state: "running", job, url, engine: input.engine, error: null, post: null, share_url: null } };
    },
};
