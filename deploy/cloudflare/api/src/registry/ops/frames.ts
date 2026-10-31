// Video frames as pictures (APP-API-CONTRACT.md section 44.7): cobalt.make.frames cuts frames out of a library video with
// ffmpeg in the workbench box (section 33.11) and saves each one as a new private PNG in the library, so the chat AI and
// the MCP can look at them closely (look with a grid) and edit them like any picture (make.cropImage, make.cutout, an
// overlay). AI only, no route; offered only while the box is on.
import * as z from "zod";
import { pngSize } from "../../cutout-core";
import { storeMade } from "../../cutout";
import { getRow } from "../../visibility";
import { budgetPort } from "../budget";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { workbenchPort } from "./box";
import { FILE_SELECT, isSource, refuseHiddenPost, rendersCap, type FileRow } from "./make";
import { ITEM_ID_REGEX } from "../../gate";

/** At most this many frames per call, each at most this many pixels a side (the size crops are made at). */
export const FRAMES_MAX = 8;
export const FRAME_MAX_SIDE = 3072;
/** A frame PNG bigger than this is not kept (a 4K PNG is ~25 MB; 3072 px a side stays well under). */
export const FRAME_MAX_BYTES = 30 * 1024 * 1024;

const FRAME_STORE = { prefix: "frames", word: "frame", meta: "frameOf" } as const;

const call = "make.frames";
const stop = (message: string) => new OpError(400, "error.make.refused", `cobalt.${call}: ${message}`);
const isErr = (v: unknown): v is { error: string } => !!v && typeof v === "object" && typeof (v as { error?: unknown }).error === "string";

const EXT: Record<string, string> = { "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm", "image/gif": "gif" };

/** Where the frames go: the times asked for, else `count` spread evenly (each in the middle of its share of the video). */
export function frameTimes(duration: number | null, at: number[] | undefined, count: number | undefined): number[] | string {
    if (at && at.length > 0) {
        if (at.length > FRAMES_MAX) return `at most ${FRAMES_MAX} frames a call`;
        if (duration !== null && at.some((t) => t > duration)) return `the video is ${duration} s long`;
        return [...new Set(at.map((t) => Math.round(t * 1000) / 1000))].sort((a, b) => a - b);
    }
    if (duration === null) return "this video's length is unknown: give at";
    const n = count ?? 1;
    return Array.from({ length: n }, (_, i) => Math.round(((i + 0.5) / n) * duration * 1000) / 1000);
}

const clock = (t: number) => {
    const m = Math.floor(t / 60), s = t - m * 60;
    return `${m}:${s < 10 ? "0" : ""}${s.toFixed(1)}`;
};

// A video file id, or a post id (its first video), not hidden.
async function videoOf(ctx: OpContext, id: string): Promise<FileRow> {
    const isVideo = (f: FileRow) => String(f.content_type ?? "").startsWith("video/") || f.content_type === "image/gif";
    if (ITEM_ID_REGEX.test(id)) {
        const f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
        if (f && f.post_key !== id) {
            if (!isVideo(f)) throw stop(`file ${id} is not a video or gif`);
            await refuseHiddenPost(ctx, call, f.post_key);
            return f;
        }
    }
    const { results } = await ctx.db.prepare(`${FILE_SELECT} WHERE post_key = ?1 ORDER BY item_index, created_at, id`).bind(id).all<FileRow>();
    if (results.length === 0) throw stop(`no post or file with id ${id}`);
    const f = results.filter(isSource).find(isVideo) ?? results.find(isVideo);
    if (!f) throw stop(`post ${id} has no video`);
    await refuseHiddenPost(ctx, call, f.post_key);
    return f;
}

const FrameSchema = z.object({
    file_id: z.string().describe("the frame's new picture (private png): look at it, crop it, put it in an edit"),
    at: z.number().describe("seconds into the video"),
    width: z.number(),
    height: z.number(),
});

export const makeFramesOp = defineOp({
    name: "make.frames",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: z.string().min(1).max(40).describe("a video (or gif) file id, or a post id (its first video)"),
        at: z.array(z.number().min(0)).max(FRAMES_MAX).optional().describe("seconds of the frames wanted"),
        count: z.number().int().min(1).max(FRAMES_MAX).optional().describe("without at: this many frames spread across the video (default 1, the middle)"),
        title: z.string().min(1).max(60).optional().describe("the frames' titles start with this (default the video's title)"),
    }),
    output: z.object({ frames: z.array(FrameSchema) }),
    ai: {
        tier: "free",
        only: true,
        summary: `Save frames of a video as pictures (new private pngs in the library, at most ${FRAMES_MAX}, up to ${FRAME_MAX_SIDE} px a side), cut by ffmpeg in the box (~10 s to wake). Then look() at them (grid: true to aim a crop) and edit them like any picture: make.cropImage, make.cutout, edits.addOverlay. To only glance at a video, look(ids, { frames: true }) is cheaper.`,
        params: ["id"],
        options: true,
        when: (f) => f.box === true,
    },
    handler: async (ctx, input) => {
        if (!ctx.chat) throw new OpError(404, "error.chat.off", `cobalt.${call}: only the chat can call this`);
        const thread = ctx.chat.threadId;
        const f = await videoOf(ctx, input.id);
        const times = frameTimes(f.duration ?? null, input.at, input.count);
        if (typeof times === "string") throw stop(times);
        const bucket = (f.bucket === "media" ? ctx.env.MEDIA : ctx.env.ORIGINALS) as unknown as { get(k: string): Promise<{ body: ReadableStream<Uint8Array>; size: number } | null> };
        const from = await getRow(ctx.db, f.id);
        if (!from) throw stop(`no file with id ${f.id}`);

        const cap = rendersCap(ctx);
        const budget = budgetPort(ctx.container);
        if (!(await budget.take(thread, "renders", cap))) {
            throw new OpError(429, "error.chat.render_cap", `cobalt.${call}: this chat already made ${cap} files today, the most it may make in a day. Tell Harmony it can make more tomorrow.`);
        }
        try {
            const box = workbenchPort(ctx);
            const obj = await bucket.get(f.r2_key);
            if (!obj) throw new OpError(404, "error.library.not_found", `cobalt.${call}: the bytes of file ${f.id} are missing`);
            const src = `frames-src-${f.id}.${EXT[String(f.content_type)] ?? "mp4"}`;
            const w = await box.write(thread, src, obj.body);
            if (isErr(w)) throw new OpError(503, "error.workbench", `cobalt.${call}: ${w.error}`);
            const scale = `scale='min(iw,${FRAME_MAX_SIDE})':'min(ih,${FRAME_MAX_SIDE})':force_original_aspect_ratio=decrease`;
            const cmd = [
                "set -e",
                "mkdir -p frames-out && rm -f frames-out/*",
                ...times.map((t, i) => `ffmpeg -hide_banner -loglevel error -y -ss ${t} -i ${src} -frames:v 1 -vf "${scale}" frames-out/f${i}.png`),
            ].join("\n");
            const r = await box.run(thread, cmd, 120);
            if (isErr(r)) throw new OpError(503, "error.workbench", `cobalt.${call}: ${r.error}`);
            if (r.code !== 0 || r.timed_out) throw new OpError(502, "error.make.failed", `cobalt.${call}: ffmpeg failed: ${(r.stderr || r.stdout).slice(-400)}`);

            const name = (await ctx.db.prepare("SELECT title FROM media_titles WHERE post_key = ?1").bind(f.post_key).first<{ title: string }>().catch(() => null))?.title ?? (f.name ?? "").replace(/\.[A-Za-z0-9]{1,5}$/, "");
            const base = [...(input.title ?? (name.trim() || "video"))].slice(0, 60).join("");
            const frames: z.infer<typeof FrameSchema>[] = [];
            for (let i = 0; i < times.length; i++) {
                const s = await box.read(thread, `frames-out/f${i}.png`);
                if (isErr(s)) continue; // past the end: ffmpeg writes nothing
                const bytes = new Uint8Array(await new Response(s).arrayBuffer());
                const size = pngSize(bytes);
                if (!size || bytes.length > FRAME_MAX_BYTES) continue;
                const stored = await storeMade(
                    { db: ctx.db, originals: ctx.env.ORIGINALS as never, now: ctx.now },
                    from,
                    bytes,
                    size.width,
                    size.height,
                    { kind: "frame", from: f.id, at: times[i] },
                    `${base} frame ${clock(times[i]!)}`,
                    ctx.keyId!,
                    FRAME_STORE,
                );
                if (!stored.ok) throw new OpError(stored.reply.status, "error.make.failed", `cobalt.${call}: could not store a frame`);
                frames.push({ file_id: String(stored.item.id), at: times[i]!, width: size.width, height: size.height });
            }
            if (frames.length === 0) throw stop("no frame came out (are the times inside the video?)");
            return ok({ frames });
        } catch (e) {
            await budget.refund(thread, "renders").catch(() => {});
            throw e;
        }
    },
});

export const FRAME_OPS = [makeFramesOp];
