// Spatial crop of a render (APP-API-CONTRACT.md section 10): the validation of the
// normalized rectangle and its conversion to pixels. Pure and dependency-free (no node
// imports), because TWO places run it: the Durable Object (src/webp.ts, src/studio.ts:
// the early 400, from the size probed when the video was saved) and the helper
// (lib.js / server.js: the real conversion, from the size it probes at encode time,
// which is what ffmpeg then crops). It lives in helper/ because only that directory is
// copied into the container image.

/** Smallest cropped width and height in pixels. */
export const MIN_CROP_PX = 64;
/** Slack on x + w <= 1 and y + h <= 1 (a client's float rounding), clamped away later. */
export const CROP_EPS = 1e-3;

/**
 * @typedef {{x: number, y: number, w: number, h: number}} Crop normalized, 0..1, in the
 *   source's DISPLAY orientation (after rotation metadata)
 * @typedef {{x: number, y: number, w: number, h: number}} CropPx whole even pixels
 */

/**
 * Reads a crop from a request. `undefined` / `null` = no crop. Otherwise an object
 * {x, y, w, h} of finite numbers (numeric strings are accepted by `fromWire` only, for
 * the helper's query string) with x >= 0, y >= 0, w > 0, h > 0, x + w <= 1 + eps,
 * y + h <= 1 + eps.
 * @param {unknown} raw
 * @returns {{ok: true, crop: Crop | null} | {ok: false}}
 */
export function parseCrop(raw) {
    if (raw === undefined || raw === null) return { ok: true, crop: null };
    if (typeof raw !== "object" || Array.isArray(raw)) return { ok: false };
    const r = /** @type {Record<string, unknown>} */ (raw);
    const { x, y, w, h } = r;
    for (const v of [x, y, w, h]) {
        if (typeof v !== "number" || !Number.isFinite(v)) return { ok: false };
    }
    const c = { x: /** @type {number} */ (x), y: /** @type {number} */ (y), w: /** @type {number} */ (w), h: /** @type {number} */ (h) };
    if (c.x < 0 || c.y < 0 || c.x > 1 || c.y > 1) return { ok: false };
    if (!(c.w > 0) || !(c.h > 0)) return { ok: false };
    if (c.x + c.w > 1 + CROP_EPS || c.y + c.h > 1 + CROP_EPS) return { ok: false };
    return { ok: true, crop: c };
}

/**
 * The same, for the DO -> helper wire: a JSON object, or the "x,y,w,h" string the upload
 * route carries in its query. Never throws.
 * @param {unknown} raw
 * @returns {{ok: true, crop: Crop | null} | {ok: false}}
 */
export function fromWire(raw) {
    if (typeof raw === "string") {
        const parts = raw.split(",");
        if (parts.length !== 4 || parts.some((p) => p.trim() === "")) return { ok: false };
        const [x, y, w, h] = parts.map(Number);
        return parseCrop({ x, y, w, h });
    }
    return parseCrop(raw);
}

/** The query-string form of a crop ("x,y,w,h"). @param {Crop} c */
export const cropToWire = (c) => `${c.x},${c.y},${c.w},${c.h}`;

const evenNearest = (/** @type {number} */ v) => Math.round(v / 2) * 2;
const evenFloor = (/** @type {number} */ v) => Math.floor(v / 2) * 2;

/**
 * Pixels from the normalized rectangle and the source's displayed size: each of x, y, w, h
 * rounded to the nearest even number, the size clamped to the (even) frame, the position
 * clamped so the rectangle stays inside it. null when the result is under MIN_CROP_PX
 * wide or high, or when the source size is not usable.
 * @param {Crop} c
 * @param {number} srcW displayed width (rotation applied)
 * @param {number} srcH displayed height (rotation applied)
 * @returns {CropPx | null}
 */
export function cropToPixels(c, srcW, srcH) {
    if (!Number.isInteger(srcW) || !Number.isInteger(srcH) || srcW < 2 || srcH < 2) return null;
    const maxW = evenFloor(srcW);
    const maxH = evenFloor(srcH);
    const w = Math.min(evenNearest(c.w * srcW), maxW);
    const h = Math.min(evenNearest(c.h * srcH), maxH);
    if (w < MIN_CROP_PX || h < MIN_CROP_PX) return null;
    const x = Math.max(0, Math.min(evenNearest(c.x * srcW), evenFloor(srcW - w)));
    const y = Math.max(0, Math.min(evenNearest(c.y * srcH), evenFloor(srcH - h)));
    return { x, y, w, h };
}
