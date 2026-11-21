// Frames of 7TV emotes in the Worker (APP-API-CONTRACT.md section 63): one batched 7TV read for the emotes' names, flags
// and pictures, then each emote's GIF (7TV publishes every animated emote as a GIF as well as a WebP) is fetched from
// cdn.7tv.app and decoded here, so canvases and look's emote frames need neither the box nor the container.
// A still emote is its PNG. Free of Cloudflare imports: the tests run it under node with fakes.

import type { Rgba } from "./cutout-core";
import { decodePng, isPng } from "./cutout-core";
import { decodeGif, isGif, spreadFrames } from "./gif";
import { publicGql } from "./emotes";
import type { SevenTvGate } from "./seventv-gate";
import { blank, clip, drawText, pasteFit, TEXT_H } from "./canvas-draw";

const CDN = "cdn.7tv.app";
export const EMOTE_FETCH_MAX = 8 * 1024 * 1024;
export const EMOTE_FETCH_MS = 15_000;
/** Canvas pixels times composed frames one emote may cost (a 4x emote of 384 x 128 with 1000 frames is ~49M). */
export const EMOTE_DECODE_MAX_PIXELS = 60_000_000;
/** Emotes read from 7TV in one request (aliased). */
export const EMOTE_INFO_BATCH = 40;

export type EmoteImage = { url: string; mime: string; size: number; scale: number; width: number; height: number; frameCount: number };
export type EmoteInfo = {
    id: string;
    name: string;
    animated: boolean;
    /** the frame count 7TV reports for its WebP (the GIF may hold fewer) */
    frames: number;
    width: number;
    height: number;
    images: EmoteImage[];
};
export type EmoteFrameDeps = { fetch?: typeof fetch; gate?: SevenTvGate | null; now: () => number };

const FIELDS = "id defaultName deleted flags { animated } images { url mime size scale width height frameCount }";

const onCdn = (u: string) => {
    try {
        const x = new URL(u);
        return x.protocol === "https:" && x.host === CDN;
    } catch {
        return false;
    }
};

function readInfo(raw: unknown): EmoteInfo | null {
    if (!raw || typeof raw !== "object") return null;
    const o = raw as { id?: unknown; defaultName?: unknown; deleted?: unknown; flags?: { animated?: unknown }; images?: unknown };
    if (typeof o.id !== "string" || o.deleted === true) return null;
    const images = (Array.isArray(o.images) ? o.images : []).filter(
        (i): i is EmoteImage =>
            !!i && typeof i === "object" && typeof (i as EmoteImage).url === "string" && onCdn((i as EmoteImage).url) && typeof (i as EmoteImage).mime === "string",
    );
    const animated = o.flags?.animated === true;
    const webp = images.filter((i) => i.mime === "image/webp" && !i.url.includes("_static")).sort((a, b) => b.scale - a.scale)[0];
    const any = webp ?? images.sort((a, b) => b.scale - a.scale)[0];
    return {
        id: o.id,
        name: typeof o.defaultName === "string" ? o.defaultName : o.id,
        animated,
        frames: Math.max(1, Number(webp?.frameCount ?? any?.frameCount ?? 1) || 1),
        width: Number(any?.width ?? 0) || 0,
        height: Number(any?.height ?? 0) || 0,
        images,
    };
}

/** The emotes' names, flags and pictures, in batches of EMOTE_INFO_BATCH aliased reads. A missing or deleted emote is absent. */
export async function emoteInfos(d: EmoteFrameDeps, ids: string[]): Promise<Map<string, EmoteInfo>> {
    const out = new Map<string, EmoteInfo>();
    const list = [...new Set(ids)];
    for (let i = 0; i < list.length; i += EMOTE_INFO_BATCH) {
        const part = list.slice(i, i + EMOTE_INFO_BATCH);
        const defs = part.map((_, k) => `$i${k}: Id!`).join(", ");
        const body = part.map((_, k) => `e${k}: emote(id: $i${k}) { ${FIELDS} }`).join(" ");
        const vars = Object.fromEntries(part.map((id, k) => [`i${k}`, id]));
        const data = (await publicGql(d.fetch ?? fetch, `query(${defs}) { emotes { ${body} } }`, vars, d.gate, d.now)) as { emotes?: Record<string, unknown> };
        part.forEach((id, k) => {
            const e = readInfo(data?.emotes?.[`e${k}`]);
            if (e) out.set(id, e);
        });
    }
    return out;
}

/** The picture to decode: the animated GIF at the largest scale up to `maxScale` (a still: its PNG), under the byte cap. */
export function decodable(e: EmoteInfo, maxScale = 4): EmoteImage | null {
    const pick = (mime: string, animated: boolean) =>
        e.images
            .filter((i) => i.mime === mime && i.scale <= maxScale && i.size <= EMOTE_FETCH_MAX && (animated ? i.frameCount > 1 || !i.url.includes("_static") : true))
            .sort((a, b) => b.scale - a.scale)[0] ?? null;
    if (e.animated) return pick("image/gif", true) ?? pick("image/png", false);
    return pick("image/png", false) ?? pick("image/gif", false);
}

async function fetchBytes(d: EmoteFrameDeps, url: string): Promise<Uint8Array | null> {
    const f = d.fetch ?? fetch;
    const deadline = Date.now() + EMOTE_FETCH_MS;
    try {
        const res = await f(url, { headers: { accept: "image/*" }, redirect: "manual", signal: AbortSignal.timeout(EMOTE_FETCH_MS) });
        if (res.status !== 200 || !res.body) {
            await res.body?.cancel().catch(() => {});
            return null;
        }
        const reader = res.body.getReader();
        const parts: Uint8Array[] = [];
        let n = 0;
        for (;;) {
            if (Date.now() > deadline) {
                await reader.cancel().catch(() => {});
                return null;
            }
            const { done, value } = await reader.read();
            if (done) break;
            n += value.byteLength;
            if (n > EMOTE_FETCH_MAX) {
                await reader.cancel().catch(() => {});
                return null;
            }
            parts.push(value);
        }
        const out = new Uint8Array(n);
        let at = 0;
        for (const p of parts) {
            out.set(p, at);
            at += p.byteLength;
        }
        return out;
    } catch {
        return null;
    }
}

export type EmoteFrames = { frames: Rgba[]; at: number[]; count: number; source: "gif" | "png" | "none"; note?: string };

/** `n` frames spread across the emote's animation (0, count/n, 2count/n...), or its one picture when it is still. */
export async function emoteFrames(d: EmoteFrameDeps, e: EmoteInfo, n: number, maxScale = 4): Promise<EmoteFrames> {
    const img = decodable(e, maxScale);
    if (!img) return { frames: [], at: [], count: e.frames, source: "none", note: "7TV has no GIF or PNG of it" };
    const bytes = await fetchBytes(d, img.url);
    if (!bytes) return { frames: [], at: [], count: e.frames, source: "none", note: "7TV's CDN did not answer" };
    try {
        if (isGif(bytes)) {
            // the GIF's own count decides the spread (7TV may drop frames making it)
            const g0 = decodeGif(bytes, { want: [0], maxPixels: EMOTE_DECODE_MAX_PIXELS });
            const at = spreadFrames(g0.count, n);
            const g = at.length === 1 ? g0 : decodeGif(bytes, { want: at, maxPixels: EMOTE_DECODE_MAX_PIXELS });
            return { frames: g.frames.map((f) => f.image), at, count: g.count, source: "gif" };
        }
        if (isPng(bytes)) return { frames: [await decodePng(bytes, 2048 * 2048)], at: [0], count: 1, source: "png" };
    } catch {
        return { frames: [], at: [], count: e.frames, source: "none", note: "its picture would not decode here" };
    }
    return { frames: [], at: [], count: e.frames, source: "none", note: "an unknown picture type" };
}

const BG: [number, number, number] = [72, 72, 72];
const WHITE: [number, number, number] = [255, 255, 255];
const DIM: [number, number, number] = [190, 190, 190];

/** look's emote frames: one strip of the frames side by side, each labelled "frame k of n". */
export function frameStrip(f: EmoteFrames, tile = 160): Rgba {
    const pad = 6;
    const k = Math.max(1, f.frames.length);
    const c = blank(pad + k * (tile + pad), tile + TEXT_H + pad * 3, BG);
    f.frames.forEach((im, i) => {
        const x = pad + i * (tile + pad);
        pasteFit(c, im, x, pad, tile, tile, 2);
        drawText(c, clip(`frame ${f.at[i]! + 1}/${f.count}`, Math.floor(tile / 8)), x, tile + pad * 2, DIM);
    });
    return c;
}

export const CANVAS_TILE = 112;
export const CANVAS_LABEL_W = 190;
export const CANVAS_GAP = 60;
const ROW_H = CANVAS_TILE + 26;
const HEAD = 30;

export type CanvasCell = { frames: Rgba[]; count: number; error?: string };
export type CanvasRow = { n: number; label: string; left: CanvasCell; right: CanvasCell };

/** The canvas width for `perSide` frames a side (3: 958 px, so look sends it at full size). */
export const canvasWidth = (perSide: number) => CANVAS_LABEL_W + 2 * perSide * (CANVAS_TILE + 6) + CANVAS_GAP;

/**
 * A compare canvas (section 63.1): a header, then one row per pair: "n. label", the original's frames, a gap, the
 * variant's frames, each side with its frame count (or why it is missing).
 */
export function compareCanvas(rows: CanvasRow[], perSide: number, heads: [string, string] = ["ORIGINAL", "VARIANT"]): Rgba {
    const W = canvasWidth(perSide);
    const c = blank(W, HEAD + ROW_H * rows.length, BG);
    const rightX = CANVAS_LABEL_W + perSide * (CANVAS_TILE + 6) + CANVAS_GAP;
    drawText(c, clip(heads[0], Math.floor((rightX - CANVAS_LABEL_W) / 8)), CANVAS_LABEL_W, 6, WHITE);
    drawText(c, clip(heads[1], Math.floor((W - rightX) / 8)), rightX, 6, [255, 210, 120]);
    rows.forEach((r, i) => {
        const y = HEAD + i * ROW_H;
        drawText(c, clip(`${r.n}. ${r.label}`, Math.floor((CANVAS_LABEL_W - 12) / 8)), 8, y + CANVAS_TILE / 2 - TEXT_H / 2, WHITE);
        for (const [cell, x0] of [
            [r.left, CANVAS_LABEL_W],
            [r.right, rightX],
        ] as const) {
            if (cell.error) {
                drawText(c, clip(`ERR ${cell.error}`, Math.floor((perSide * (CANVAS_TILE + 6)) / 8)), x0, y + CANVAS_TILE / 2 - TEXT_H / 2, [255, 90, 90]);
                continue;
            }
            cell.frames.slice(0, perSide).forEach((f, k) => pasteFit(c, f, x0 + k * (CANVAS_TILE + 6), y, CANVAS_TILE, CANVAS_TILE, 2));
            drawText(c, `${cell.count} frame${cell.count === 1 ? "" : "s"}`, x0, y + CANVAS_TILE + 4, DIM);
        }
    });
    return c;
}
