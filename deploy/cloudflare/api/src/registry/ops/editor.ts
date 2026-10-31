// Editor layers and cutouts (APP-API-CONTRACT.md section 39): the cutout route, and the chat AI's (and MCP's) calls
// cobalt.make.cutout and cobalt.edits.addOverlay.
import * as z from "zod";
import { CUTOUT_SOURCE_TYPES, makeCutout, type ImagesPort } from "../../cutout";
import { EDIT_OVERLAY_TRACKS, EDIT_SOURCE_TYPES, sourceKind } from "../../../../editor/helper/timeline.js";
import { EDIT_PROJECT_ID_REGEX, ITEM_ID_REGEX } from "../../gate";
import { budgetPort } from "../budget";
import { defineOp, ok, OpError, type OpContext, capThreadOf } from "../op";
import { editCall, FILE_SELECT, JobSchema, projectOf, ProjectSchema, refuseHiddenPost, rendersCap, type FileRow } from "./make";

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

const cutoutDeps = (ctx: OpContext) => ({
    db: ctx.db,
    originals: ctx.env.ORIGINALS as never,
    media: ctx.env.MEDIA as never,
    images: ((ctx.env as { IMAGES?: unknown }).IMAGES ?? null) as ImagesPort | null,
    now: ctx.now,
});

// POST /library/items/<id>/cutout (39.5): JSON = the server makes it; image/png = the app's own cutout, stored.
export const libraryCutoutRoute = defineOp({
    name: "library.cutout",
    route: { method: "POST", path: "/library/items/:id/cutout", params: { id: ITEM_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    raw: true,
    input: z.object({}),
    http: () => ({}),
    ai: { tier: "hidden", summary: "Remove a picture's background into a new png (POST /library/items/<id>/cutout); the chat uses make.cutout." },
    handler: async (ctx) => {
        const r = await makeCutout(cutoutDeps(ctx), ctx.params.id!, ctx.request!, ctx.keyId!);
        return json(r.status, r.body);
    },
});

const stop = (call: string, message: string) => new OpError(400, "error.make.refused", `cobalt.${call}: ${message}`);
const isPicture = (f: Pick<FileRow, "content_type">) => CUTOUT_SOURCE_TYPES.includes(String(f.content_type ?? "").toLowerCase());
const forEditor = (f: Pick<FileRow, "content_type">) => EDIT_SOURCE_TYPES.includes(String(f.content_type ?? "").toLowerCase());

// A file id, or a post id (its first file that `want` takes), not hidden.
async function fileOf(ctx: OpContext, call: string, id: string, want: (f: FileRow) => boolean, label: string): Promise<FileRow> {
    let f: FileRow | null = null;
    if (ITEM_ID_REGEX.test(id)) f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
    if (!f || !want(f)) {
        const { results } = await ctx.db.prepare(`${FILE_SELECT} WHERE post_key = ?1 ORDER BY item_index, created_at, id`).bind(id).all<FileRow>();
        if (!f && results.length === 0) throw stop(call, `no post or file with id ${id}`);
        f = results.find(want) ?? null;
        if (!f) throw stop(call, `${id} has no ${label}`);
    }
    await refuseHiddenPost(ctx, call, f.post_key);
    return f;
}

function threadOf(ctx: OpContext, call: string): string {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", `cobalt.${call}: only the chat can call this`);
    // a sub-agent uses its parent's caps and box (section 43.7)
    return capThreadOf(ctx.chat);
}

export const makeCutoutOp = defineOp({
    name: "make.cutout",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: z.string().min(1).max(40).describe("a picture's file id, or a post id (its first picture)"),
        mode: z.enum(["auto", "white", "color"]).optional().describe("auto (default): lift the subject off any background; white: take out white; color: take out `color`"),
        color: z.string().regex(/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/).optional().describe("#rrggbb, for mode color"),
        tolerance: z.number().min(0).max(100).optional().describe("white/color: 0..100, default 20; higher takes out more"),
        edges_only: z.boolean().optional().describe("white/color: only background touching the edges (default true: keeps white eyes)"),
        soften: z.number().int().min(0).max(3).optional().describe("white/color: softened edge in px, default 1"),
        trim: z.boolean().optional().describe("crop to the subject, default true"),
        title: z.string().min(1).max(80).optional(),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary:
            "A new see-through png of a picture with its background removed (a 'cutout', private, in the library; the original stays). Done at once: returns file_id to put in an edit (edits.addOverlay).",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "make.cutout";
        const thread = threadOf(ctx, call);
        const f = await fileOf(ctx, call, input.id, isPicture, "picture");
        if (input.mode === "color" && !input.color) throw stop(call, "mode color needs color");
        const cap = rendersCap(ctx);
        if (!(await budgetPort(ctx.container).take(thread, "renders", cap))) {
            throw new OpError(429, "error.chat.render_cap", `cobalt.${call}: this chat already made ${cap} files today, the most it may make in a day. Tell Harmony it can make more tomorrow.`);
        }
        const { id: _id, ...spec } = input;
        const req = new Request(`https://do.internal/library/items/${f.id}/cutout`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ mode: "auto", ...spec }),
        });
        const r = await makeCutout(cutoutDeps(ctx), f.id, req, ctx.keyId!);
        if (r.status !== 201) {
            await budgetPort(ctx.container).refund(thread, "renders");
            const code = (r.body as { error?: { code?: string } }).error?.code ?? "error.api.generic";
            const msg = (r.body as { message?: string }).message;
            throw new OpError(r.status, code, `cobalt.${call}: ${code}${msg ? ` (${msg})` : ""}`);
        }
        const item = (r.body as { item: { id: string } }).item;
        const c = (r.body as { cutout: { width: number; height: number } }).cutout;
        return ok({ job: `cutout:${item.id}`, status: "done", file_id: item.id, post_id: item.id, kind: "image", width: c.width, height: c.height, public: false, share_url: null });
    },
});

// ---- edits.addOverlay ---------------------------------------------------------------------------------------------

const POSITIONS = ["center", "top", "bottom", "left", "right", "top-left", "top-right", "bottom-left", "bottom-right"] as const;
const r4 = (n: number) => Math.round(n * 10000) / 10000;
const r3 = (n: number) => Math.floor(n * 1000 + 1e-9) / 1000;

/** Where an overlay of width `w` (canvas fraction) and height `h` (canvas fraction) goes for a named position. */
export function placeAt(pos: (typeof POSITIONS)[number], w: number, h: number, canvas: { w: number; h: number }): { x: number; y: number } {
    const mx = 0.04, my = (0.04 * canvas.w) / canvas.h; // the same margin in pixels on both axes
    const left = mx, right = 1 - w - mx, cx = (1 - w) / 2;
    const top = my, bottom = 1 - h - my, cy = (1 - h) / 2;
    const x = pos.includes("left") ? left : pos.includes("right") ? right : cx;
    const y = pos.startsWith("top") ? top : pos.startsWith("bottom") ? bottom : cy;
    return { x: Math.max(0, x), y: Math.max(0, y) };
}

type Ov = { id: string; at: number; in: number; out: number; track?: number };

/** The lowest track (from `from`) where [at, at + len) touches no overlay on it (frame-exact like the validator, at fps). */
export function freeTrack(overlay: Ov[], at: number, len: number, fps: number, from = 0): number | null {
    const s = Math.floor(at * fps + 0.5 + 1e-9), e = s + Math.max(1, Math.floor(len * fps + 0.5 + 1e-9));
    for (let k = from; k < EDIT_OVERLAY_TRACKS; k++) {
        const busy = overlay.some((o) => {
            if ((o.track ?? 0) !== k) return false;
            const os = Math.floor(o.at * fps + 0.5 + 1e-9), oe = os + Math.max(1, Math.floor((o.out - o.in) * fps + 0.5 + 1e-9));
            return os < e && s < oe;
        });
        if (!busy) return k;
    }
    return null;
}

export const editsAddOverlayOp = defineOp({
    name: "edits.addOverlay",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        project: z.string().regex(EDIT_PROJECT_ID_REGEX, "an edit project id"),
        file: z.string().min(1).max(40).describe("a video, gif, photo, webp/7TV emote or cutout: file id or post id"),
        at: z.number().min(0).optional().describe("output seconds where it starts, default 0"),
        seconds: z.number().gt(0).optional().describe("how long it stays, default: a picture to the end, a video its length"),
        in: z.number().min(0).optional().describe("a video: source seconds to start from, default 0"),
        track: z.number().int().min(0).max(EDIT_OVERLAY_TRACKS - 1).optional().describe("layer 0..7 (higher on top); default the lowest free one"),
        position: z.enum(POSITIONS).optional().describe("default center (ignored when x and y are given)"),
        x: z.number().min(0).max(1).optional().describe("left edge, canvas fraction"),
        y: z.number().min(0).max(1).optional().describe("top edge, canvas fraction"),
        size: z.number().min(0.05).max(1).optional().describe("width as a canvas fraction, default 0.35 (a video 0.4)"),
        opacity: z.number().min(0.1).max(1).optional(),
        muted: z.boolean().optional().describe("a video's sound, default muted"),
        volume: z.number().min(0).max(1).optional(),
    }),
    output: ProjectSchema.extend({ clip: z.string().describe("the new overlay's id"), track: z.number() }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "Put one video, gif, picture, 7TV emote or cutout over an edit project (on the lowest free layer, so several can be up at once). Sized from its shape and kept on the canvas. Returns the project.",
        params: ["project", "file"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "edits.addOverlay";
        const f = await fileOf(ctx, call, input.file, forEditor, "video or picture the editor takes");
        const kind = sourceKind(f.content_type);
        if (!kind) throw stop(call, `the editor does not take ${f.content_type ?? "this file"}`);
        const cur = await editCall(ctx, call, "get", { id: input.project });
        const t = cur.project.timeline as { canvas: { w: number; h: number; fps: number }; main: unknown[]; overlay: (Ov & Record<string, unknown>)[] };
        const total: number = cur.project.duration;
        const at = r3(input.at ?? 0);
        if (at >= total - 0.1) throw stop(call, `at must be before the end (${total} s)`);
        const rest = r3(total - at);

        let inPoint = 0, out: number;
        if (kind === "video") {
            inPoint = r3(input.in ?? 0);
            const d = f.duration ?? null;
            const avail = d === null ? (input.seconds ?? rest) : d - inPoint;
            if (avail < 0.1) throw stop(call, `in is past the video's end (${d} s)`);
            out = r3(inPoint + Math.min(input.seconds ?? avail, avail, rest));
        } else {
            out = r3(Math.min(input.seconds ?? rest, rest, 600));
        }
        const len = out - inPoint;
        if (len < 0.1) throw stop(call, "it would be shorter than 0.1 s");

        let track: number;
        if (input.track !== undefined) {
            if (freeTrack(t.overlay, at, len, t.canvas.fps, input.track) !== input.track) throw stop(call, `layer ${input.track} is busy then: leave track out to use a free layer`);
            track = input.track;
        } else {
            const k = freeTrack(t.overlay, at, len, t.canvas.fps);
            if (k === null) throw stop(call, `all ${EDIT_OVERLAY_TRACKS} layers are busy then`);
            track = k;
        }

        // size from the picture's shape, kept inside the canvas
        const aspect = f.width && f.height ? f.height / f.width : 1;
        let w = input.size ?? (kind === "video" ? 0.4 : 0.35);
        const hOf = (ww: number) => (ww * t.canvas.w * aspect) / t.canvas.h;
        if (hOf(w) > 1) w = t.canvas.h / (t.canvas.w * aspect);
        w = Math.max(0.05, Math.min(1, r4(w)));
        const h = hOf(w);
        let { x, y } = input.x !== undefined && input.y !== undefined ? { x: input.x, y: input.y } : placeAt(input.position ?? "center", w, h, t.canvas);
        x = r4(Math.min(Math.max(0, x), 1 - w));
        y = r4(Math.min(Math.max(0, y), Math.max(0, 1 - h - 0.0005)));

        const ids = new Set([...(t.main as { id: string }[]).map((c) => c.id), ...t.overlay.map((o) => o.id)]);
        let n = t.overlay.length + 1;
        while (ids.has(`ov${n}`)) n++;
        const clip: Record<string, unknown> = {
            id: `ov${n}`,
            item: f.id,
            at,
            in: inPoint,
            out,
            frame: { x, y, w },
            opacity: input.opacity ?? 1,
            volume: input.volume ?? 1,
            muted: input.muted ?? true,
            ...(track !== 0 ? { track } : {}),
        };
        // keep overlay[] sorted by at (after any that start at the same time)
        const idx = t.overlay.findIndex((o) => o.at > at);
        const overlay = [...t.overlay];
        overlay.splice(idx === -1 ? overlay.length : idx, 0, clip as Ov & Record<string, unknown>);
        const body = { timeline: { ...t, overlay }, base_revision: cur.project.revision };
        const p = (await editCall(ctx, call, "update", { id: input.project }, body)).project;
        return ok({ ...projectOf(p), clip: clip.id as string, track });
    },
});

export const EDITOR_OPS = [libraryCutoutRoute, makeCutoutOp, editsAddOverlayOp];
