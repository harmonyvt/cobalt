// Cropping, turning and flipping pictures (APP-API-CONTRACT.md section 44) on decoded RGBA, plus the grid `look` draws
// (44.3). Pure functions, no Cloudflare imports: the tests run them under node.

import type { Rgba } from "./cutout-core";

export type CropBox = { x: number; y: number; w: number; h: number };
export type Rotate = 0 | 90 | 180 | 270;
export type Flip = "none" | "h" | "v";

/** The smallest crop, in pixels a side. */
export const CROP_MIN_PX = 2;

/**
 * A crop in fractions of a `width` x `height` picture as whole pixels: rounded outward, clamped to the picture.
 * null when it is smaller than CROP_MIN_PX a side.
 */
export function pixelBox(c: CropBox, width: number, height: number): CropBox | null {
    const x0 = Math.max(0, Math.floor(c.x * width + 1e-6));
    const y0 = Math.max(0, Math.floor(c.y * height + 1e-6));
    const x1 = Math.min(width, Math.ceil(Math.min(1, c.x + c.w) * width - 1e-6));
    const y1 = Math.min(height, Math.ceil(Math.min(1, c.y + c.h) * height - 1e-6));
    if (x1 - x0 < CROP_MIN_PX || y1 - y0 < CROP_MIN_PX) return null;
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** A quarter-turn rotation, clockwise. */
export function rotate(img: Rgba, deg: Rotate): Rgba {
    if (deg === 0) return img;
    const { width: w, height: h, data } = img;
    const ow = deg === 180 ? w : h, oh = deg === 180 ? h : w;
    const out = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
            // where source (x, y) lands
            const nx = deg === 90 ? h - 1 - y : deg === 180 ? w - 1 - x : y;
            const ny = deg === 90 ? x : deg === 180 ? h - 1 - y : w - 1 - x;
            const s = (y * w + x) * 4, d = (ny * ow + nx) * 4;
            out[d] = data[s]!;
            out[d + 1] = data[s + 1]!;
            out[d + 2] = data[s + 2]!;
            out[d + 3] = data[s + 3]!;
        }
    }
    return { width: ow, height: oh, data: out };
}

/** A mirror: "h" left to right, "v" top to bottom. */
export function flip(img: Rgba, f: Flip): Rgba {
    if (f === "none") return img;
    const { width: w, height: h, data } = img;
    const out = new Uint8Array(data.length);
    const row = w * 4;
    for (let y = 0; y < h; y++) {
        const sy = f === "v" ? h - 1 - y : y;
        if (f === "v") {
            out.set(data.subarray(sy * row, sy * row + row), y * row);
            continue;
        }
        for (let x = 0; x < w; x++) {
            const s = (sy * w + (w - 1 - x)) * 4, d = (y * w + x) * 4;
            out[d] = data[s]!;
            out[d + 1] = data[s + 1]!;
            out[d + 2] = data[s + 2]!;
            out[d + 3] = data[s + 3]!;
        }
    }
    return { width: w, height: h, data: out };
}

/** The colour of `look`'s grid (a magenta that reads on most pictures), at this opacity. */
export const GRID_RGB: [number, number, number] = [255, 0, 170];
export const GRID_ALPHA = 0.7;

/**
 * Lines every tenth of the width and height, thicker at the half, blended over the picture (made opaque, so a
 * see-through picture shows on black). A copy; the input is not changed.
 */
export function drawGrid(img: Rgba): Rgba {
    const { width: w, height: h } = img;
    const out = new Uint8Array(img.data);
    const base = Math.max(1, Math.round(Math.min(w, h) / 600));
    const blend = (x: number, y: number) => {
        const p = (y * w + x) * 4;
        for (let k = 0; k < 3; k++) out[p + k] = Math.round(out[p + k]! * (1 - GRID_ALPHA) + GRID_RGB[k]! * GRID_ALPHA);
    };
    // flatten alpha first: lines must show
    for (let p = 0; p < w * h; p++) {
        const a = out[p * 4 + 3]! / 255;
        for (let k = 0; k < 3; k++) out[p * 4 + k] = Math.round(out[p * 4 + k]! * a);
        out[p * 4 + 3] = 255;
    }
    for (let i = 1; i < 10; i++) {
        const t = i === 5 ? base * 2 + 1 : base;
        const cx = Math.round((i * w) / 10), cy = Math.round((i * h) / 10);
        const x0 = Math.max(0, cx - (t >> 1)), y0 = Math.max(0, cy - (t >> 1));
        for (let x = x0; x < Math.min(w, x0 + t); x++) for (let y = 0; y < h; y++) blend(x, y);
        for (let y = y0; y < Math.min(h, y0 + t); y++) for (let x = 0; x < w; x++) blend(x, y);
    }
    return { width: w, height: h, data: out };
}
