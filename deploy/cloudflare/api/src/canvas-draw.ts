// Drawing on RGBA pictures in the Worker, for canvases the model looks at (APP-API-CONTRACT.md section 63): a blank
// canvas, a picture pasted in scaled to fit a box (area-averaged, alpha kept), and text in a baked bitmap font.
// Free of Cloudflare imports: the tests run it under node.

import type { Rgba } from "./cutout-core";
import { FONT_DATA, FONT_H, FONT_W } from "./canvas-font";

export type Rgb = [number, number, number];

export function blank(width: number, height: number, bg: Rgb): Rgba {
    const data = new Uint8Array(width * height * 4);
    for (let i = 0; i < width * height; i++) {
        data[i * 4] = bg[0];
        data[i * 4 + 1] = bg[1];
        data[i * 4 + 2] = bg[2];
        data[i * 4 + 3] = 255;
    }
    return { width, height, data };
}

/** The size `src` takes inside a w x h box, aspect kept, never enlarged past `maxScale` (default 1). */
export function fitSize(sw: number, sh: number, w: number, h: number, maxScale = 1): { width: number; height: number } {
    const s = Math.min(w / sw, h / sh, maxScale);
    return { width: Math.max(1, Math.round(sw * s)), height: Math.max(1, Math.round(sh * s)) };
}

/** A picture scaled to exactly w x h: area averaging when it shrinks (premultiplied, so clear edges stay clean), nearest when it grows. */
export function resize(src: Rgba, w: number, h: number): Rgba {
    if (w === src.width && h === src.height) return src;
    const out = new Uint8Array(w * h * 4);
    const sx = src.width / w;
    const sy = src.height / h;
    for (let y = 0; y < h; y++) {
        const y0 = y * sy;
        const y1 = Math.max(y0 + 1e-6, (y + 1) * sy);
        for (let x = 0; x < w; x++) {
            const x0 = x * sx;
            const x1 = Math.max(x0 + 1e-6, (x + 1) * sx);
            let r = 0, g = 0, b = 0, a = 0, area = 0;
            for (let yy = Math.floor(y0); yy < Math.min(src.height, Math.ceil(y1)); yy++) {
                const wy = Math.min(y1, yy + 1) - Math.max(y0, yy);
                if (wy <= 0) continue;
                for (let xx = Math.floor(x0); xx < Math.min(src.width, Math.ceil(x1)); xx++) {
                    const wx = Math.min(x1, xx + 1) - Math.max(x0, xx);
                    if (wx <= 0) continue;
                    const k = wx * wy;
                    const p = (yy * src.width + xx) * 4;
                    const pa = src.data[p + 3]! * k;
                    r += src.data[p]! * pa;
                    g += src.data[p + 1]! * pa;
                    b += src.data[p + 2]! * pa;
                    a += pa;
                    area += k;
                }
            }
            const o = (y * w + x) * 4;
            if (a > 0) {
                out[o] = Math.round(r / a);
                out[o + 1] = Math.round(g / a);
                out[o + 2] = Math.round(b / a);
            }
            out[o + 3] = area > 0 ? Math.round(a / area) : 0;
        }
    }
    return { width: w, height: h, data: out };
}

/** `src` drawn over `dst` with its top-left at (x, y), alpha blended, clipped to `dst`. */
export function paste(dst: Rgba, src: Rgba, x: number, y: number): void {
    // whole pixels only: a fractional y would shift every index by part of a row
    x = Math.round(x);
    y = Math.round(y);
    for (let j = 0; j < src.height; j++) {
        const dy = y + j;
        if (dy < 0 || dy >= dst.height) continue;
        for (let i = 0; i < src.width; i++) {
            const dx = x + i;
            if (dx < 0 || dx >= dst.width) continue;
            const s = (j * src.width + i) * 4;
            const d = (dy * dst.width + dx) * 4;
            const sa = src.data[s + 3]! / 255;
            if (sa === 0) continue;
            for (let k = 0; k < 3; k++) dst.data[d + k] = Math.round(src.data[s + k]! * sa + dst.data[d + k]! * (1 - sa));
            dst.data[d + 3] = Math.max(dst.data[d + 3]!, src.data[s + 3]!);
        }
    }
}

/** `src` scaled to fit a w x h box (never past `maxScale`), centred in it. */
export function pasteFit(dst: Rgba, src: Rgba, x: number, y: number, w: number, h: number, maxScale = 1): void {
    const size = fitSize(src.width, src.height, w, h, maxScale);
    paste(dst, resize(src, size.width, size.height), x + Math.floor((w - size.width) / 2), y + Math.floor((h - size.height) / 2));
}

export function fillRect(dst: Rgba, x: number, y: number, w: number, h: number, c: Rgb): void {
    x = Math.round(x);
    y = Math.round(y);
    for (let j = Math.max(0, y); j < Math.min(dst.height, y + h); j++) {
        for (let i = Math.max(0, x); i < Math.min(dst.width, x + w); i++) {
            const d = (j * dst.width + i) * 4;
            dst.data[d] = c[0];
            dst.data[d + 1] = c[1];
            dst.data[d + 2] = c[2];
            dst.data[d + 3] = 255;
        }
    }
}

/** A checkerboard behind clear pixels, so a transparent emote reads on the canvas. */
export function checker(dst: Rgba, x: number, y: number, w: number, h: number, a: Rgb, b: Rgb, cell = 8): void {
    for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) fillRect(dst, x + i, y + j, 1, 1, (Math.floor(i / cell) + Math.floor(j / cell)) % 2 ? a : b);
}

let glyphs: Uint8Array | null = null;
const glyphBytes = () => {
    if (!glyphs) glyphs = Uint8Array.from(atob(FONT_DATA), (c) => c.charCodeAt(0));
    return glyphs;
};
const GLYPH_BYTES = Math.ceil((FONT_W * FONT_H) / 2);

export const TEXT_H = FONT_H;
export const textWidth = (s: string, scale = 1) => [...s].length * FONT_W * scale;

/** Text with its top-left at (x, y), `scale` px per font pixel; anything outside printable ASCII draws as "?". Clipped to `maxWidth`. */
export function drawText(dst: Rgba, s: string, x: number, y: number, c: Rgb, scale = 1, maxWidth = Infinity): void {
    const g = glyphBytes();
    // whole pixels only: a fractional y (a centred line) would shift every index by part of a row
    x = Math.round(x);
    y = Math.round(y);
    let cx = x;
    for (const ch of s) {
        if (cx + FONT_W * scale > x + maxWidth) break;
        let code = ch.charCodeAt(0);
        if (code < 32 || code > 126 || ch.length > 1) code = 63;
        const base = (code - 32) * GLYPH_BYTES;
        for (let py = 0; py < FONT_H; py++) {
            for (let px = 0; px < FONT_W; px++) {
                const n = py * FONT_W + px;
                const byte = g[base + (n >> 1)]!;
                const v = n % 2 === 0 ? byte >> 4 : byte & 15;
                if (v === 0) continue;
                const a = v / 15;
                for (let sy = 0; sy < scale; sy++) {
                    for (let sx = 0; sx < scale; sx++) {
                        const X = cx + px * scale + sx, Y = y + py * scale + sy;
                        if (X < 0 || Y < 0 || X >= dst.width || Y >= dst.height) continue;
                        const d = (Y * dst.width + X) * 4;
                        for (let k = 0; k < 3; k++) dst.data[d + k] = Math.round(c[k]! * a + dst.data[d + k]! * (1 - a));
                    }
                }
            }
        }
        cx += FONT_W * scale;
    }
}

/** A string cut to `max` characters, with "…" spelled as "~" (the font is ASCII). */
export const clip = (s: string, max: number) => ([...s].length > max ? [...s].slice(0, Math.max(1, max - 1)).join("") + "~" : s);
