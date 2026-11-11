// convert_to_webp: an animated webp of up to 10 seconds of a video (MCP-APP-CONTRACT.md section 4). Without a range the
// answer is "pick" and nothing runs, unless the whole video is short enough to be the range.
import * as z from "zod";
import { OpError } from "../../registry/op";
import { WebpOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, clock, cut, num, readPosts, rec, round, str, summaryOf } from "./common";
import { madePost, phaseOf } from "./jobs";
import { notFound } from "./post";

const Input = z.object({
    id: z.string().min(1).max(2048),
    start: z.number().min(0).optional(),
    end: z.number().gt(0).optional(),
    width: z.union([z.literal(320), z.literal(480)]).default(480),
    quality: z.enum(["low", "med", "high"]).default("med"),
});

export const WEBP_MIN_S = 0.5;
export const WEBP_MAX_S = 10;
// how long the call waits for a quick encode before it hands the job to the widget
export const WEBP_WAIT_S = 6;

type Out = z.infer<typeof WebpOut>;

export const convertToWebp: AppTool<z.infer<typeof Input>> = {
    name: "convert_to_webp",
    title: "Convert to animated webp",
    description:
        "Make a silent, looping animated webp (0.5 to 10 seconds, 320 or 480 px wide) from part of a video in the capystore library. Give start and end in seconds; without them the tool shows a range picker (a video of 10 seconds or less converts whole).",
    input: Input,
    output: WebpOut,
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: false },
    view: "webp",
    async run(ctx, input) {
        // the id is a post's, or one file's (a gallery's own video): one read finds the post either way
        const read = await readPosts(ctx.op, { posts: [input.id], files: [input.id] });
        const postId = read.postOfFile.get(input.id) ?? input.id;
        const post = rec(await ctx.call("library.post", { id: postId }));
        if (post.hidden === true) throw notFound(input.id);
        const summary = summaryOf(post, read);
        if (!summary) throw notFound(input.id);
        const files = arr(post.files).map(rec);
        // the file that is converted: the one named, else the post's first video or gif
        const isMotion = (f: Record<string, unknown>) => (str(f.content_type) ?? "").startsWith("video/") || str(f.content_type) === "image/gif";
        const named = files.find((f) => str(f.id) === input.id);
        const target = named ?? files.find(isMotion);
        if (!target || !isMotion(target)) {
            throw new OpError(
                400,
                "error.webp.not_video",
                `“${cut(summary.title, 60)}” is a picture, not a video or gif, so there is no part of it to pick. To make a picture into an animated webp, use make_still.`,
            );
        }
        // the public video a widget can play to pick the range
        const playable = target.public === true && str(target.url) ? target : files.find((f) => isMotion(f) && f.public === true && str(f.url));
        const duration = num(target.duration) ?? summary.duration_s;
        const source = { id: input.id, title: summary.title, duration_s: duration, poster_url: summary.thumb_url, url: playable ? str(playable.url) : null };
        const base = { view: "webp" as const, width: input.width, quality: input.quality, source };

        // the pick rule: both ends given runs; a short video runs whole; anything else asks
        const whole = duration !== null && duration <= WEBP_MAX_S && duration >= WEBP_MIN_S;
        const given = input.start !== undefined && input.end !== undefined;
        if (!given && !whole) {
            const length = duration !== null ? ` (${clock(duration)} long)` : "";
            const text = `Pick the part of “${cut(summary.title, 80)}”${length} to convert: a start and an end, ${WEBP_MIN_S} to ${WEBP_MAX_S} seconds apart. Then call convert_to_webp again with start and end (seconds). Nothing has been converted yet.`;
            const structured: Out = { ...base, state: "pick", job: null, progress: null, error: null, range: null, post: null, share_url: null };
            return { text, structured };
        }
        const start = input.start ?? 0;
        let end = input.end ?? duration ?? 0;
        // an end past the video is the end of the video
        if (duration !== null && end > duration) end = duration;
        const length = round(end - start);
        if (!(length >= WEBP_MIN_S && length <= WEBP_MAX_S)) {
            throw new OpError(400, "error.webp.range", `a webp is ${WEBP_MIN_S} to ${WEBP_MAX_S} seconds long (end minus start); ${start} to ${end} is ${length}`);
        }
        const range = { start: round(start), end: round(end) };
        const started = rec(await ctx.call("make.webp", { id: input.id, start: range.start, end: range.end, width: input.width, quality: input.quality }));
        let job = str(started.job);
        let phase = phaseOf(started);
        let latest: Record<string, unknown> = started;
        // a quick encode comes back finished in this one call
        if (job && phase.state === "running") {
            latest = rec(await ctx.call("jobs.wait", { job, seconds: WEBP_WAIT_S }));
            job = str(latest.job) ?? job;
            phase = phaseOf(latest);
        }
        const what = `${round(length, 1)} s of “${cut(summary.title, 60)}” at ${input.width} px`;
        if (phase.state === "done") {
            const made = await madePost(ctx, str(latest.post_id), str(latest.share_url));
            const text = made.post
                ? [`Made an animated webp (${what}), post ${made.post.id}.`, made.share_url ? `Share link: ${made.share_url}` : "It is not public, so it has no share link yet."].join("\n")
                : `Made an animated webp (${what}).`;
            return { text, structured: { ...base, state: "done", job, progress: 1, error: null, range, post: made.post, share_url: made.share_url } };
        }
        if (phase.state === "error") {
            return { text: `The webp could not be made (${phase.error}).`, structured: { ...base, state: "error", job, progress: phase.progress, error: phase.error, range, post: null, share_url: null } };
        }
        const pct = phase.progress !== null ? ` (${Math.round(phase.progress * 100)}%)` : "";
        const text = `Converting ${what} into an animated webp${pct}. It is still running. Call job_status with job ${job} to check; when it is done it will be a new post in the library, with a share link if it is public.`;
        return { text, structured: { ...base, state: "running", job, progress: phase.progress, error: null, range, post: null, share_url: null } };
    },
};
