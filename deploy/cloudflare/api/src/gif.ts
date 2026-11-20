// A GIF decoder for the Worker (APP-API-CONTRACT.md section 63): an animated GIF as composed RGBA frames with their
// delays, honouring each frame's disposal and transparency. 7TV publishes every animated emote as a GIF too, which is
// how the canvases and look's emote frames see an animation without the container. Free of Cloudflare imports.

import type { Rgba } from "./cutout-core";

export type GifFrame = { image: Rgba; delay: number };
export type GifInfo = { width: number; height: number; frames: number };

export class GifError extends Error {}

const sig = (b: Uint8Array) => b.length >= 13 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46;
export const isGif = sig;

type RawFrame = {
    x: number;
    y: number;
    w: number;
    h: number;
    interlaced: boolean;
    palette: Uint8Array | null;
    minCode: number;
    data: Uint8Array[];
    delay: number;
    transparent: number;
    disposal: number;
};

/** The frames' layout, without decoding any pixels. Throws GifError when the file is not a GIF it can read. */
function parse(b: Uint8Array): { width: number; height: number; global: Uint8Array | null; bg: number; frames: RawFrame[] } {
    if (!sig(b)) throw new GifError("not a gif");
    const width = b[6]! | (b[7]! << 8);
    const height = b[8]! | (b[9]! << 8);
    const flags = b[10]!;
    const bg = b[11]!;
    let p = 13;
    let global: Uint8Array | null = null;
    if (flags & 0x80) {
        const n = 3 * (1 << ((flags & 7) + 1));
        global = b.subarray(p, p + n);
        p += n;
    }
    const frames: RawFrame[] = [];
    let gce = { delay: 0, transparent: -1, disposal: 0 };
    const subBlocks = (): Uint8Array[] => {
        const out: Uint8Array[] = [];
        for (;;) {
            if (p >= b.length) throw new GifError("cut short");
            const n = b[p++]!;
            if (n === 0) return out;
            out.push(b.subarray(p, p + n));
            p += n;
        }
    };
    while (p < b.length) {
        const k = b[p++]!;
        if (k === 0x3b) break;
        if (k === 0x21) {
            const label = b[p++]!;
            const blocks = subBlocks();
            if (label === 0xf9 && blocks[0] && blocks[0].length >= 4) {
                const g = blocks[0];
                gce = { disposal: (g[0]! >> 2) & 7, delay: (g[1]! | (g[2]! << 8)) * 10, transparent: g[0]! & 1 ? g[3]! : -1 };
            }
            continue;
        }
        if (k !== 0x2c) {
            // stray bytes after the last frame: what was read stands
            if (frames.length > 0) break;
            throw new GifError("bad block");
        }
        const x = b[p]! | (b[p + 1]! << 8);
        const y = b[p + 2]! | (b[p + 3]! << 8);
        const w = b[p + 4]! | (b[p + 5]! << 8);
        const h = b[p + 6]! | (b[p + 7]! << 8);
        const f = b[p + 8]!;
        p += 9;
        let palette: Uint8Array | null = null;
        if (f & 0x80) {
            const n = 3 * (1 << ((f & 7) + 1));
            palette = b.subarray(p, p + n);
            p += n;
        }
        const minCode = b[p++]!;
        const data = subBlocks();
        frames.push({ x, y, w, h, interlaced: (f & 0x40) !== 0, palette, minCode, data, ...gce });
        gce = { delay: 0, transparent: -1, disposal: 0 };
    }
    if (frames.length === 0 || width === 0 || height === 0) throw new GifError("no frames");
    return { width, height, global, bg, frames };
}

export function gifInfo(b: Uint8Array): GifInfo {
    const g = parse(b);
    return { width: g.width, height: g.height, frames: g.frames.length };
}

/** LZW: a frame's palette indexes, w * h of them (short data is padded with 0). */
function lzw(minCode: number, blocks: Uint8Array[], count: number): Uint8Array {
    const out = new Uint8Array(count);
    if (minCode < 2 || minCode > 11) throw new GifError("bad code size");
    const clear = 1 << minCode;
    const eoi = clear + 1;
    const prefix = new Int16Array(4096);
    const suffix = new Uint8Array(4096);
    const firstOf = new Uint8Array(4096);
    const lenOf = new Uint16Array(4096);
    for (let i = 0; i < clear; i++) {
        prefix[i] = -1;
        suffix[i] = i;
        firstOf[i] = i;
        lenOf[i] = 1;
    }
    let size = minCode + 1;
    let next = eoi + 1;
    let prev = -1;
    let o = 0;
    let bits = 0;
    let acc = 0;
    outer: for (const blk of blocks) {
        for (let i = 0; i < blk.length; i++) {
            acc |= blk[i]! << bits;
            bits += 8;
            while (bits >= size) {
                const code = acc & ((1 << size) - 1);
                acc >>>= size;
                bits -= size;
                if (code === clear) {
                    size = minCode + 1;
                    next = eoi + 1;
                    prev = -1;
                    continue;
                }
                if (code === eoi) break outer;
                let cur = code;
                if (code > next) throw new GifError("bad code");
                if (prev !== -1 && next < 4096) {
                    const known = code < next;
                    prefix[next] = prev;
                    suffix[next] = known ? firstOf[code]! : firstOf[prev]!;
                    firstOf[next] = firstOf[prev]!;
                    lenOf[next] = lenOf[prev]! + 1;
                    if (!known) cur = next;
                    next++;
                    if (next === 1 << size && size < 12) size++;
                } else if (code >= next) {
                    throw new GifError("bad code");
                }
                // write the string of `cur` backwards into its place
                const n = lenOf[cur]!;
                let at = o + n - 1;
                let c = cur;
                while (c !== -1 && at >= o) {
                    if (at < count) out[at] = suffix[c]!;
                    c = prefix[c]!;
                    at--;
                }
                o += n;
                prev = code;
                if (o >= count) break outer;
            }
        }
    }
    return out;
}

const INTERLACE = [
    [0, 8],
    [4, 8],
    [2, 4],
    [1, 2],
] as const;

/**
 * Composed frames of a GIF. `want` (frame indexes) keeps only those (the rest are still composed, never stored).
 * `maxPixels` bounds the work: canvas pixels times the frames that must be composed. Throws GifError.
 */
export function decodeGif(b: Uint8Array, o: { want?: number[]; maxPixels?: number } = {}): { width: number; height: number; frames: GifFrame[]; count: number } {
    const g = parse(b);
    const W = g.width;
    const H = g.height;
    const want = o.want ? new Set(o.want) : null;
    const last = want ? Math.min(g.frames.length - 1, Math.max(...want)) : g.frames.length - 1;
    if ((o.maxPixels ?? Infinity) < W * H * (last + 1)) throw new GifError("too large");
    const canvas = new Uint8Array(W * H * 4);
    const frames: GifFrame[] = [];
    let restore: Uint8Array | null = null;
    for (let i = 0; i <= last; i++) {
        const f = g.frames[i]!;
        const pal = f.palette ?? g.global;
        if (!pal) throw new GifError("no palette");
        if (f.disposal === 3) restore = canvas.slice();
        const idx = lzw(f.minCode, f.data, f.w * f.h);
        let row = 0;
        const rows: number[] = [];
        if (f.interlaced) for (const [start, step] of INTERLACE) for (let r = start; r < f.h; r += step) rows.push(r);
        for (let r = 0; r < f.h; r++) {
            const y = f.interlaced ? rows[r]! : r;
            const cy = f.y + y;
            if (cy >= H) {
                row++;
                continue;
            }
            for (let x = 0; x < f.w; x++) {
                const cx = f.x + x;
                if (cx >= W) continue;
                const k = idx[row * f.w + x]!;
                if (k === f.transparent) continue;
                const d = (cy * W + cx) * 4;
                canvas[d] = pal[k * 3] ?? 0;
                canvas[d + 1] = pal[k * 3 + 1] ?? 0;
                canvas[d + 2] = pal[k * 3 + 2] ?? 0;
                canvas[d + 3] = 255;
            }
            row++;
        }
        if (!want || want.has(i)) frames.push({ image: { width: W, height: H, data: canvas.slice() }, delay: f.delay });
        if (f.disposal === 2) {
            for (let y = f.y; y < Math.min(H, f.y + f.h); y++) canvas.fill(0, (y * W + f.x) * 4, (y * W + Math.min(W, f.x + f.w)) * 4);
        } else if (f.disposal === 3 && restore) {
            canvas.set(restore);
        }
    }
    return { width: W, height: H, frames, count: g.frames.length };
}

/** `n` frame indexes spread across `count` frames, the first always in: 0, count/n, 2count/n... (3 of 30: 0, 10, 20). */
export function spreadFrames(count: number, n: number): number[] {
    if (count <= 0) return [];
    const k = Math.min(count, Math.max(1, n));
    return [...new Set(Array.from({ length: k }, (_, i) => Math.floor((i * count) / k)))];
}
