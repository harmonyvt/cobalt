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
/** The colour of a proposed box (`look` with `box`, section 44.8): cyan, so it never reads as the grid. */
export const BOX_RGB: [number, number, number] = [0, 230, 255];

// 3 x 5 digits for the grid's labels: tenths 1..9 (row strings, "#" = on).
const DIGITS: Record<string, string[]> = {
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "2": ["##.", "..#", ".#.", "#..", "###"],
    "3": ["##.", "..#", ".#.", "..#", "##."],
    "4": ["#.#", "#.#", "###", "..#", "..#"],
    "5": ["###", "#..", "##.", "..#", "##."],
    "6": [".##", "#..", "###", "#.#", "###"],
    "7": ["###", "..#", ".#.", ".#.", ".#."],
    "8": ["###", "#.#", "###", "#.#", "###"],
    "9": ["###", "#.#", "###", "..#", "##."],
};

/** Flattens alpha onto black (a copy): marks must show on a see-through picture. */
function opaque(img: Rgba): Rgba {
    const out = new Uint8Array(img.data);
    for (let p = 0; p < img.width * img.height; p++) {
        const a = out[p * 4 + 3]! / 255;
        for (let k = 0; k < 3; k++) out[p * 4 + k] = Math.round(out[p * 4 + k]! * a);
        out[p * 4 + 3] = 255;
    }
    return { width: img.width, height: img.height, data: out };
}

function blendPx(img: Rgba, x: number, y: number, rgb: readonly number[], a: number) {
    if (x < 0 || y < 0 || x >= img.width || y >= img.height) return;
    const p = (y * img.width + x) * 4;
    for (let k = 0; k < 3; k++) img.data[p + k] = Math.round(img.data[p + k]! * (1 - a) + rgb[k]! * a);
}

/** A digit with its top-left at (x, y), `s` px per dot, white on a dark backing. */
function drawDigit(img: Rgba, d: string, x: number, y: number, s: number) {
    const rows = DIGITS[d];
    if (!rows) return;
    for (let yy = -s; yy < 6 * s; yy++) for (let xx = -s; xx < 4 * s; xx++) blendPx(img, x + xx, y + yy, [0, 0, 0], 0.65);
    for (let r = 0; r < 5; r++)
        for (let c = 0; c < 3; c++)
            if (rows[r]![c] === "#") for (let yy = 0; yy < s; yy++) for (let xx = 0; xx < s; xx++) blendPx(img, x + c * s + xx, y + r * s + yy, [255, 255, 255], 1);
}

/**
 * Lines every tenth of the width and height, thicker at the half, labelled with their tenth (1..9) along the top and
 * left edges, blended over the picture (made opaque, so a see-through picture shows on black). A copy.
 */
export function drawGrid(img: Rgba): Rgba {
    const out = opaque(img);
    const { width: w, height: h } = out;
    const base = Math.max(1, Math.round(Math.min(w, h) / 600));
    for (let i = 1; i < 10; i++) {
        const t = i === 5 ? base * 2 + 1 : base;
        const cx = Math.round((i * w) / 10), cy = Math.round((i * h) / 10);
        const x0 = Math.max(0, cx - (t >> 1)), y0 = Math.max(0, cy - (t >> 1));
        for (let x = x0; x < Math.min(w, x0 + t); x++) for (let y = 0; y < h; y++) blendPx(out, x, y, GRID_RGB, GRID_ALPHA);
        for (let y = y0; y < Math.min(h, y0 + t); y++) for (let x = 0; x < w; x++) blendPx(out, x, y, GRID_RGB, GRID_ALPHA);
    }
    // digit size: 4 px a dot on a ~700 px wide picture
    const s = Math.max(1, Math.round(Math.min(w, h) / 160));
    if (Math.min(w, h) >= 60) {
        for (let i = 1; i < 10; i++) {
            const cx = Math.round((i * w) / 10), cy = Math.round((i * h) / 10);
            drawDigit(out, String(i), cx + base + s, s, s); // along the top, right of its line
            drawDigit(out, String(i), s, cy + base + s, s); // down the left, under its line
        }
    }
    return out;
}

/**
 * A proposed crop drawn on the picture (a copy): outside it darkened, its edge in cyan. `look` shows it so the model can
 * check a box before it makes anything (section 44.8).
 */
export function drawBox(img: Rgba, b: CropBox): Rgba {
    const out = opaque(img);
    const { width: w, height: h } = out;
    const x0 = Math.round(b.x * w), y0 = Math.round(b.y * h);
    const x1 = Math.round(Math.min(1, b.x + b.w) * w), y1 = Math.round(Math.min(1, b.y + b.h) * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (x < x0 || x >= x1 || y < y0 || y >= y1) blendPx(out, x, y, [0, 0, 0], 0.55);
    const t = Math.max(2, Math.round(Math.min(w, h) / 300));
    for (let k = 0; k < t; k++) {
        for (let x = x0 - t; x < x1 + t; x++) {
            blendPx(out, x, y0 - 1 - k, BOX_RGB, 1);
            blendPx(out, x, y1 + k, BOX_RGB, 1);
        }
        for (let y = y0 - t; y < y1 + t; y++) {
            blendPx(out, x0 - 1 - k, y, BOX_RGB, 1);
            blendPx(out, x1 + k, y, BOX_RGB, 1);
        }
    }
    return out;
}
