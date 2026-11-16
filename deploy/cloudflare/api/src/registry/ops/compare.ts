// Compare canvases (APP-API-CONTRACT.md section 63.1): a list of (original, variant) pairs, drawn as big multi-frame
// canvases in the Worker and saved as private PNGs in the library, so a model judges real animations instead of tiny
// previews. Replaces the Python renderer that ran in the box (slow, 8 KB output, 8000-character commands, timeouts).
// Emotes are read from 7TV in one batch and their GIFs decoded here (src/emote-frames.ts); any other media ref (a
// capystore post or file, an allowed image link) is its first picture (a GIF in the library: its frames).
import * as z from "zod";
import { compareCanvas, emoteFrames, emoteInfos, type CanvasCell, type CanvasRow } from "../../emote-frames";
import { decodePng, encodePng, isPng, type Rgba } from "../../cutout-core";
import { decodeGif, isGif, spreadFrames } from "../../gif";
import { insertMediaItem, mintItemId } from "../../library";
import { lookImages } from "../../look-pictures";
import { mediaHostsOf, mediaPosts, parseMediaRef } from "../../media-refs";
import { gateOf } from "../../seventv-gate";
import { upsertTitle } from "../../studio";
import { getRow, itemShape } from "../../visibility";
import type { ImagesPort } from "../../cutout";
import { budgetPort } from "../budget";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { rendersCap } from "./make";

export const COMPARE_PAIRS_MAX = 40;
export const COMPARE_ROWS_MAX = 12;
export const COMPARE_FRAMES_MAX = 5;
const PARALLEL = 6;
const call = "compare.canvas";

const Pair = z.object({
    original: z.string().trim().min(1).max(2048).describe("a media ref: a 7TV emote id or link, a capystore link or id, or an allowed image URL"),
    variant: z.string().trim().min(1).max(2048).describe("the same kinds of ref"),
    label: z.string().trim().max(60).optional().describe("the row's name, e.g. the set alias (default: the original emote's name)"),
});

const RowShape = z.object({
    n: z.number().describe("the row number drawn on the canvas"),
    label: z.string(),
    original: z.string(),
    variant: z.string(),
    original_frames: z.number().nullable().describe("frames in its animation (1: a still)"),
    variant_frames: z.number().nullable(),
    error: z.string().optional().describe("why a side shows ERR"),
});
const CanvasShape = z.object({
    file_id: z.string().describe("the canvas: look({ ids: [file_id] }) to see it, or hand it to a swarm"),
    width: z.number(),
    height: z.number(),
    rows: z.array(RowShape),
});

type Cell = CanvasCell & { name?: string };
type RefKind = { kind: "emote"; id: string } | { kind: "other" } | { kind: "bad"; error: string };

const isErrStr = (v: unknown): v is string => typeof v === "string";

async function pool<T, R>(items: T[], n: number, fn: (t: T) => Promise<R>): Promise<R[]> {
    const out: R[] = new Array(items.length);
    let next = 0;
    await Promise.all(
        Array.from({ length: Math.min(n, items.length) }, async () => {
            for (;;) {
                const i = next++;
                if (i >= items.length) return;
                out[i] = await fn(items[i]!);
            }
        }),
    );
    return out;
}

// A capystore ref or an image link: its picture's bytes made into frames (a GIF: spread frames; anything else: one).
async function otherCell(ctx: OpContext, ref: string, perSide: number): Promise<Cell> {
    const env = ctx.env as { ORIGINALS?: unknown; MEDIA?: unknown; IMAGES?: unknown };
    const images = (env.IMAGES ?? null) as ImagesPort | null;
    const bases = { mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl, hosts: mediaHostsOf(ctx.env as { MEDIA_HOSTS?: string }, ctx) };
    const parsed = parseMediaRef(ref, bases);
    let bytes: Uint8Array | null = null;
    if (parsed?.kind === "url") {
        if (parsed.media !== "image") return { frames: [], count: 0, error: "a video link: save it first" };
        bytes = await fetchCapped(parsed.url);
    } else {
        const post = (await mediaPosts(ctx.db, [ref], bases)).get(ref);
        if (!post) return { frames: [], count: 0, error: "not found" };
        const pics = (await lookImages({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, originals: env.ORIGINALS as never, media: env.MEDIA as never, images: null }, [post])).get(post) ?? [];
        const p = pics[0];
        if (p?.url) bytes = await fetchCapped(p.url);
        else if (p?.data) bytes = Uint8Array.from(atob(p.data), (c) => c.charCodeAt(0));
    }
    if (!bytes) return { frames: [], count: 0, error: "no picture" };
    try {
        if (isGif(bytes)) {
            const g0 = decodeGif(bytes, { want: [0], maxPixels: 60_000_000 });
            const at = spreadFrames(g0.count, perSide);
            const g = at.length === 1 ? g0 : decodeGif(bytes, { want: at, maxPixels: 60_000_000 });
            return { frames: g.frames.map((f) => f.image), count: g.count };
        }
        if (!isPng(bytes)) {
            if (!images) return { frames: [], count: 0, error: "can't read this type" };
            const out = await images.input(new Response(bytes).body!).transform({ width: 512, height: 512, fit: "scale-down" }).output({ format: "image/png" });
            bytes = new Uint8Array(await out.response().arrayBuffer());
        }
        return { frames: [await decodePng(bytes, 2048 * 2048)], count: 1 };
    } catch {
        return { frames: [], count: 0, error: "would not decode" };
    }
}

async function fetchCapped(url: string): Promise<Uint8Array | null> {
    try {
        const res = await fetch(url, { headers: { accept: "image/*" }, redirect: "manual", signal: AbortSignal.timeout(15_000) });
        if (res.status !== 200) {
            await res.body?.cancel().catch(() => {});
            return null;
        }
        const b = new Uint8Array(await res.arrayBuffer());
        return b.byteLength > 0 && b.byteLength <= 16 * 1024 * 1024 ? b : null;
    } catch {
        return null;
    }
}

async function storeCanvas(ctx: OpContext, png: Uint8Array, img: Rgba, title: string, spec: Record<string, unknown>): Promise<string> {
    const originals = ctx.env.ORIGINALS as unknown as R2Bucket;
    const now = ctx.now();
    const key = `canvases/${mintItemId()}.png`;
    await originals.put(key, png, { httpMetadata: { contentType: "image/png" }, customMetadata: { keyId: ctx.keyId ?? "", source: "studio", createdAt: String(now) } });
    const id = await insertMediaItem(ctx.db, {
        kind: "private",
        source: "studio",
        bucket: "originals",
        r2_key: key,
        name: `${title.replace(/[/\\\u0000-\u001F\u007F]/g, "").slice(0, 116) || "canvas"}.png`,
        content_type: "image/png",
        bytes: png.length,
        width: img.width,
        height: img.height,
        duration: null,
        link: null,
        session_id: null,
        key_id: ctx.keyId,
        poster: null,
        role: null,
        made_from: null,
        made_spec: JSON.stringify(spec),
        post_key: null,
        created_at: now,
    });
    if (!id) {
        await originals.delete(key).catch(() => {});
        throw new OpError(503, "error.api.generic", `cobalt.${call}: could not store the canvas`);
    }
    await upsertTitle(ctx.db, id, title, ctx.keyId ?? "", now).catch(() => {});
    const row = await getRow(ctx.db, id);
    return String(row ? (itemShape(row) as { id?: unknown }).id ?? id : id);
}

export const compareCanvasOp = defineOp({
    name: "compare.canvas",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        pairs: z.array(Pair).min(1).max(COMPARE_PAIRS_MAX).describe(`(original, variant) pairs, at most ${COMPARE_PAIRS_MAX} a call`),
        frames: z.number().int().min(1).max(COMPARE_FRAMES_MAX).optional().describe("frames shown a side, spread across each animation (default 3: 958 px wide)"),
        rows: z.number().int().min(1).max(COMPARE_ROWS_MAX).optional().describe("pairs per canvas (default 10)"),
        title: z.string().trim().min(1).max(80).optional().describe("the canvases' titles start with this"),
        headings: z.tuple([z.string().max(40), z.string().max(40)]).optional().describe('the two column headings (default ["ORIGINAL", "VARIANT"])'),
    }),
    output: z.object({ canvases: z.array(CanvasShape), ms: z.number() }),
    ai: {
        tier: "free",
        only: true,
        summary:
            `Draw (original, variant) pairs as compare canvases: each row is "n. label", ${3} frames spread across the original's animation, then the variant's, each with its frame count (7TV emotes are decoded from their GIFs here, no box). Saved as private PNGs in the library, 10 rows a canvas; look() at each file_id, or give them to a verdict swarm. Up to ${COMPARE_PAIRS_MAX} pairs a call, a few seconds per canvas.`,
        params: ["pairs"],
        options: true,
    },
    handler: async (ctx, input) => {
        const started = Date.now();
        const perSide = input.frames ?? 3;
        const perCanvas = input.rows ?? 10;
        const bases = { mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl, hosts: mediaHostsOf(ctx.env as { MEDIA_HOSTS?: string }, ctx) };
        const kindOf = (ref: string): RefKind => {
            const p = parseMediaRef(ref, bases);
            if (!p) return { kind: "bad", error: "not a media ref" };
            if (p.kind === "emote") return { kind: "emote", id: p.id };
            if (p.kind === "refused") return { kind: "bad", error: p.error.replace("error.media.", "").replace(/_/g, " ") };
            return { kind: "other" };
        };
        const refs = [...new Set(input.pairs.flatMap((p) => [p.original, p.variant]))];
        const kinds = new Map(refs.map((r) => [r, kindOf(r)]));
        const emoteIds = [...kinds.values()].flatMap((k) => (k.kind === "emote" ? [k.id] : []));
        const fd = { gate: gateOf(ctx.env), now: ctx.now };
        let infos;
        try {
            infos = emoteIds.length > 0 ? await emoteInfos(fd, emoteIds) : new Map();
        } catch (e) {
            const status = (e as { status?: number }).status;
            throw new OpError(status === 429 ? 429 : 502, status === 429 ? "error.emote.rate_limited" : "error.emote.unavailable", `cobalt.${call}: 7TV did not answer the emote read${status === 429 ? " (rate limited: try again in a minute)" : ""}`);
        }

        const cap = rendersCap(ctx);
        const canvasCount = Math.ceil(input.pairs.length / perCanvas);
        const budget = budgetPort(ctx.container);
        const thread = ctx.chat?.threadId;
        let taken = 0;
        if (cap !== null && thread) {
            for (; taken < canvasCount; taken++) {
                if (!(await budget.take(thread, "renders", cap))) {
                    for (let i = 0; i < taken; i++) await budget.refund(thread, "renders").catch(() => {});
                    throw new OpError(429, "error.chat.render_cap", `cobalt.${call}: this chat already made ${cap} files today, the most it may make in a day (a canvas is one).`);
                }
            }
        }
        try {
            const cells = new Map<string, Cell>();
            await pool(refs, PARALLEL, async (ref) => {
                const k = kinds.get(ref)!;
                if (k.kind === "bad") return cells.set(ref, { frames: [], count: 0, error: k.error });
                if (k.kind === "emote") {
                    const info = infos.get(k.id);
                    if (!info) return cells.set(ref, { frames: [], count: 0, error: "no such emote on 7TV" });
                    const f = await emoteFrames(fd, info, info.animated ? perSide : 1, 4);
                    return cells.set(ref, f.frames.length > 0 ? { frames: f.frames, count: f.count, name: info.name } : { frames: [], count: f.count, error: f.note ?? "no picture", name: info.name });
                }
                return cells.set(ref, await otherCell(ctx, ref, perSide));
            });

            const canvases: z.infer<typeof CanvasShape>[] = [];
            const total = canvasCount;
            for (let c = 0; c < total; c++) {
                const chunk = input.pairs.slice(c * perCanvas, (c + 1) * perCanvas);
                const rows: CanvasRow[] = chunk.map((p, i) => {
                    const l = cells.get(p.original)!;
                    const r = cells.get(p.variant)!;
                    return { n: c * perCanvas + i + 1, label: p.label ?? l.name ?? p.original.slice(-12), left: l, right: r };
                });
                const img = compareCanvas(rows, perSide, input.headings ?? ["ORIGINAL", "VARIANT"]);
                const png = await encodePng(img);
                const title = `${input.title ?? "compare canvas"} ${c + 1} of ${total}`;
                const fileId = await storeCanvas(ctx, png, img, title, { kind: "compare_canvas", frames: perSide, pairs: chunk });
                canvases.push({
                    file_id: fileId,
                    width: img.width,
                    height: img.height,
                    rows: rows.map((r, i) => {
                        const errs = [r.left.error ? `original: ${r.left.error}` : null, r.right.error ? `variant: ${r.right.error}` : null].filter(isErrStr);
                        return {
                            n: r.n,
                            label: r.label,
                            original: chunk[i]!.original,
                            variant: chunk[i]!.variant,
                            original_frames: r.left.error ? null : r.left.count,
                            variant_frames: r.right.error ? null : r.right.count,
                            ...(errs.length ? { error: errs.join("; ") } : {}),
                        };
                    }),
                });
            }
            return ok({ canvases, ms: Date.now() - started });
        } catch (e) {
            if (cap !== null && thread) for (let i = 0; i < taken; i++) await budget.refund(thread, "renders").catch(() => {});
            throw e;
        }
    },
});

export const COMPARE_OPS = [compareCanvasOp];
