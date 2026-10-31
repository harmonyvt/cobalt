// The editor's timeline (APP-API-CONTRACT.md section 31.2-31.6): ONE validator and canonical form for two callers, the
// API Worker (src/edits.ts imports this file, the way src/studio.ts imports ../helper/crop.js) and the render helper
// (compile.js, server.js). Plain ESM with JSDoc types and NO imports, so it bundles into a Worker and runs in node alike.
//
// Pinned names: EDIT_* constants, parseTimeline, checkSources, canonicalJSON, timing, mainPlacement, overlayPlacement,
// roundHalfUp, evenNearest. Anything else exported here (cropToPixels, MIN_CROP_PX, sourceKind, ...) is a helper of
// these and may be used, but is not part of the pinned contract.

export const EDIT_MAX_SECONDS = 600,
    EDIT_MAX_CLIPS = 50,
    EDIT_MAX_JSON_BYTES = 65536,
    EDIT_MAX_PROJECTS = 200,
    EDIT_QUEUE_MAX = 20,
    EDIT_MAX_INPUT_BYTES = 6 * 1024 ** 3,
    EDIT_MAX_OUTPUT_BYTES = 4 * 1024 ** 3;
export const EDIT_CANVASES = [
    [1080, 1920],
    [720, 1280],
    [1080, 1080],
    [720, 720],
    [1920, 1080],
    [1280, 720],
];
export const EDIT_SOURCE_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v", "image/gif", "image/jpeg", "image/png", "image/webp"];
/** Overlay layers (section 39): an overlay's optional `track` is 0..EDIT_OVERLAY_TRACKS - 1; absent means 0. */
export const EDIT_OVERLAY_TRACKS = 8;

/** Smallest cropped width and height in pixels (section 10: api/helper/crop.js, copied because the image has no monorepo). */
export const MIN_CROP_PX = 64;
/** Slack on x + w <= 1 and y + h <= 1 (a client's float rounding). */
export const EDIT_EPS = 1e-3;
/** A source may end this much before a clip's `out` (seconds); the render clamps `out` to the duration. */
export const EDIT_END_SLACK = 0.05;
export const EDIT_SAMPLE_RATE = 48000;
export const EDIT_CROP_ASPECTS = ["free", "9:16", "1:1", "4:5", "16:9"];

/**
 * @typedef {{x: number, y: number, w: number, h: number}} Rect
 * @typedef {{aspect: string, x: number, y: number, w: number, h: number}} EditCrop
 * @typedef {{id: string, item: string, in: number, out: number, speed: number, crop?: EditCrop, fit: "fill" | "fit",
 *            volume: number, muted: boolean, pitch?: number}} MainClip
 * @typedef {{id: string, item: string, at: number, in: number, out: number, frame: {x: number, y: number, w: number},
 *            opacity: number, volume: number, muted: boolean, pitch?: number, track?: number}} OverlayClip
 * @typedef {{version: 1, canvas: {w: number, h: number, fps: number}, main: MainClip[], overlay: OverlayClip[]}} Timeline
 * @typedef {{id: string, content_type: string | null, source?: string | null, width: number | null, height: number | null,
 *            duration: number | null, bytes: number | null, deleted?: boolean | number | null}} SourceRow
 * @typedef {{ok: false, code: string, path: string, items?: string[]}} Failure
 */

// --- numbers ------------------------------------------------------------------------------------------------------

/** Floor(x + 0.5) with an epsilon for float noise; x >= 0. JS Math.round and Swift .rounded() differ only at the epsilon. @param {number} x */
export function roundHalfUp(x) {
    return Math.floor(x + 0.5 + 1e-9);
}
/** The nearest even integer (halves up). @param {number} x */
export function evenNearest(x) {
    return 2 * roundHalfUp(x / 2);
}
/** @param {number} x */
const evenFloor = (x) => 2 * Math.floor(x / 2);
/** @param {number} v @param {number} lo @param {number} hi */
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
/** Round a non-negative number to `places` decimals (half up, epsilon like roundHalfUp). @param {number} x @param {number} places */
function roundTo(x, places) {
    const m = 10 ** places;
    return roundHalfUp(x * m) / m;
}
/**
 * Optional `pitch` (31.16): semitones, rounded to the nearest 0.5, then -12..12; absent when 0 so old timelines stay byte for byte.
 * @param {Record<string, unknown>} c @param {string} p @returns {{ok: true, pitch: number} | Failure}
 */
function parsePitch(c, p) {
    if (c.pitch === undefined) return { ok: true, pitch: 0 };
    if (!isNum(c.pitch)) return bad(`${p}.pitch`);
    const q = roundHalfUp(c.pitch / 0.5) * 0.5 + 0; // "+ 0" turns -0 into 0
    if (q < -12 || q > 12) return range(`${p}.pitch`);
    return { ok: true, pitch: q };
}
/** @param {unknown} v @returns {v is number} */
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
/** Biggest number any seconds field may hold (a sanity bound; the real limits are checked later). */
const SECONDS_BOUND = 1e5;

// --- parseTimeline ------------------------------------------------------------------------------------------------

const ID_RE = /^[A-Za-z0-9_-]{1,24}$/;
const ITEM_RE = /^[A-Za-z0-9]{16}$/;

/** @param {string} code @param {string} path @returns {Failure} */
const fail = (code, path) => ({ ok: false, code, path });
const bad = (/** @type {string} */ path) => fail("error.edit.bad_request", path);
const range = (/** @type {string} */ path) => fail("error.edit.range", path);

/** @param {unknown} v @returns {v is Record<string, unknown>} */
const isObj = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

/**
 * Every key of `o` is in `required` or `optional`, and every `required` one is there.
 * @param {Record<string, unknown>} o @param {string[]} required @param {string[]} optional @param {string} prefix
 * @returns {Failure | null}
 */
function keysOk(o, required, optional, prefix) {
    const dot = prefix === "" ? "" : ".";
    for (const k of Object.keys(o)) {
        if (!required.includes(k) && !optional.includes(k)) return bad(`${prefix}${dot}${k}`);
    }
    for (const k of required) if (!(k in o)) return bad(`${prefix}${dot}${k}`);
    return null;
}

/**
 * Structure, types, ranges, rounding and ordering of a timeline; no source lookups (31.3). `raw` is the parsed JSON (a JSON
 * string is accepted too). On success `timeline` is a fresh, normalised copy: numbers rounded as 31.2 says, keys sorted.
 * Check order (the app's EditValidation mirrors it): version, canvas, main/overlay are arrays, counts (empty, too_many_clips),
 * each main clip in order, each overlay clip in order, then timing (too_long, overlay order and overlap, overlay past the end).
 * @param {unknown} raw
 * @returns {{ok: true, timeline: Timeline} | Failure}
 */
export function parseTimeline(raw) {
    let t = raw;
    if (typeof raw === "string") {
        try {
            t = JSON.parse(raw);
        } catch {
            return bad("");
        }
    }
    if (!isObj(t)) return bad("");
    let f = keysOk(t, ["version", "canvas", "main", "overlay"], [], "");
    if (f) return f;
    if (t.version !== 1) return bad("version");

    // canvas
    const cv = t.canvas;
    if (!isObj(cv)) return bad("canvas");
    f = keysOk(cv, ["w", "h", "fps"], [], "canvas");
    if (f) return f;
    if (!Number.isInteger(cv.w)) return bad("canvas.w");
    if (!Number.isInteger(cv.h)) return bad("canvas.h");
    if (!Number.isInteger(cv.fps)) return bad("canvas.fps");
    if (!EDIT_CANVASES.some(([w, h]) => w === cv.w && h === cv.h)) return fail("error.edit.canvas", "canvas");
    if (cv.fps !== 30 && cv.fps !== 60) return fail("error.edit.canvas", "canvas.fps");
    const canvas = { fps: /** @type {number} */ (cv.fps), h: /** @type {number} */ (cv.h), w: /** @type {number} */ (cv.w) };

    if (!Array.isArray(t.main)) return bad("main");
    if (!Array.isArray(t.overlay)) return bad("overlay");
    if (t.main.length === 0) return fail("error.edit.empty", "main");
    if (t.main.length + t.overlay.length > EDIT_MAX_CLIPS) return fail("error.edit.too_many_clips", "main");

    const ids = new Set();
    /** @param {unknown} id @param {string} path */
    const idOk = (id, path) => {
        if (typeof id !== "string" || !ID_RE.test(id) || ids.has(id)) return bad(path);
        ids.add(id);
        return null;
    };

    /** @type {MainClip[]} */
    const main = [];
    for (let i = 0; i < t.main.length; i++) {
        const r = parseMain(t.main[i], `main[${i}]`, idOk);
        if (!r.ok) return r;
        main.push(r.clip);
    }
    /** @type {OverlayClip[]} */
    const overlay = [];
    for (let i = 0; i < t.overlay.length; i++) {
        const r = parseOverlay(t.overlay[i], `overlay[${i}]`, idOk);
        if (!r.ok) return r;
        overlay.push(r.clip);
    }
    /** @type {Timeline} */
    const timeline = { canvas, main, overlay, version: 1 };
    const tf = checkTiming(timeline);
    if (tf) return tf;
    return { ok: true, timeline };
}

/**
 * @param {unknown} c @param {string} p @param {(id: unknown, path: string) => Failure | null} idOk
 * @returns {{ok: true, clip: MainClip} | Failure}
 */
function parseMain(c, p, idOk) {
    if (!isObj(c)) return bad(p);
    let f = keysOk(c, ["id", "item", "in", "out", "speed", "fit", "volume", "muted"], ["crop", "pitch"], p);
    if (f) return f;
    f = idOk(c.id, `${p}.id`);
    if (f) return f;
    if (typeof c.item !== "string" || !ITEM_RE.test(c.item)) return bad(`${p}.item`);
    for (const k of ["in", "out", "speed", "volume"]) if (!isNum(c[k])) return bad(`${p}.${k}`);
    if (c.fit !== "fill" && c.fit !== "fit") return bad(`${p}.fit`);
    if (typeof c.muted !== "boolean") return bad(`${p}.muted`);

    const rin = /** @type {number} */ (c.in), rout = /** @type {number} */ (c.out);
    if (rin < 0 || rin > SECONDS_BOUND) return range(`${p}.in`);
    if (rout < 0 || rout > SECONDS_BOUND) return range(`${p}.out`);
    const cin = roundTo(rin, 3), cout = roundTo(rout, 3);
    // a multiple of 0.05, rounded to the nearest, then 2 decimals
    const rs = /** @type {number} */ (c.speed);
    if (rs < 0) return range(`${p}.speed`);
    const speed = roundTo(roundHalfUp(rs / 0.05) * 0.05, 2);
    if (speed < 0.25 || speed > 4) return range(`${p}.speed`);
    if (!(cin < cout)) return range(`${p}.out`);
    if ((cout - cin) / speed < 0.1 - 1e-9) return range(`${p}.out`);
    const rv = /** @type {number} */ (c.volume);
    if (rv < 0 || rv > 1) return range(`${p}.volume`);

    /** @type {MainClip} */
    const clip = { fit: c.fit, id: /** @type {string} */ (c.id), in: cin, item: c.item, muted: c.muted, out: cout, speed, volume: roundTo(rv, 2) };
    const pt = parsePitch(c, p);
    if (!pt.ok) return pt;
    if (pt.pitch !== 0) clip.pitch = pt.pitch;
    if (c.crop !== undefined) {
        const cr = parseCrop(c.crop, `${p}.crop`);
        if (!cr.ok) return cr;
        clip.crop = cr.crop;
    }
    return { ok: true, clip: sortKeys(clip) };
}

/** @param {unknown} c @param {string} p @returns {{ok: true, crop: EditCrop} | Failure} */
function parseCrop(c, p) {
    if (!isObj(c)) return bad(p);
    const f = keysOk(c, ["aspect", "x", "y", "w", "h"], [], p);
    if (f) return f;
    if (typeof c.aspect !== "string" || !EDIT_CROP_ASPECTS.includes(c.aspect)) return bad(`${p}.aspect`);
    for (const k of ["x", "y", "w", "h"]) if (!isNum(c[k])) return bad(`${p}.${k}`);
    const x = roundTo(clamp(/** @type {number} */ (c.x), -1, 2), 4);
    const y = roundTo(clamp(/** @type {number} */ (c.y), -1, 2), 4);
    const w = roundTo(clamp(/** @type {number} */ (c.w), -1, 2), 4);
    const h = roundTo(clamp(/** @type {number} */ (c.h), -1, 2), 4);
    if (/** @type {number} */ (c.x) < 0) return range(`${p}.x`);
    if (/** @type {number} */ (c.y) < 0) return range(`${p}.y`);
    if (!(w > 0)) return range(`${p}.w`);
    if (!(h > 0)) return range(`${p}.h`);
    if (x + w > 1 + EDIT_EPS) return range(`${p}.w`);
    if (y + h > 1 + EDIT_EPS) return range(`${p}.h`);
    return { ok: true, crop: { aspect: c.aspect, h, w, x, y } };
}

/**
 * @param {unknown} c @param {string} p @param {(id: unknown, path: string) => Failure | null} idOk
 * @returns {{ok: true, clip: OverlayClip} | Failure}
 */
function parseOverlay(c, p, idOk) {
    if (!isObj(c)) return bad(p);
    let f = keysOk(c, ["id", "item", "at", "in", "out", "frame", "opacity", "volume", "muted"], ["pitch", "track"], p);
    if (f) return f;
    f = idOk(c.id, `${p}.id`);
    if (f) return f;
    if (typeof c.item !== "string" || !ITEM_RE.test(c.item)) return bad(`${p}.item`);
    for (const k of ["at", "in", "out", "opacity", "volume"]) if (!isNum(c[k])) return bad(`${p}.${k}`);
    if (typeof c.muted !== "boolean") return bad(`${p}.muted`);
    if (!isObj(c.frame)) return bad(`${p}.frame`);
    f = keysOk(c.frame, ["x", "y", "w"], [], `${p}.frame`);
    if (f) return f;
    for (const k of ["x", "y", "w"]) if (!isNum(c.frame[k])) return bad(`${p}.frame.${k}`);

    const at = /** @type {number} */ (c.at), rin = /** @type {number} */ (c.in), rout = /** @type {number} */ (c.out);
    if (at < 0 || at > SECONDS_BOUND) return range(`${p}.at`);
    if (rin < 0 || rin > SECONDS_BOUND) return range(`${p}.in`);
    if (rout < 0 || rout > SECONDS_BOUND) return range(`${p}.out`);
    const cin = roundTo(rin, 3), cout = roundTo(rout, 3);
    if (!(cin < cout) || cout - cin < 0.1 - 1e-9) return range(`${p}.out`);
    const fx = /** @type {number} */ (c.frame.x), fy = /** @type {number} */ (c.frame.y), fw = /** @type {number} */ (c.frame.w);
    if (fx < 0) return range(`${p}.frame.x`);
    if (fy < 0) return range(`${p}.frame.y`);
    const frame = { w: roundTo(clamp(fw, -1, 2), 4), x: roundTo(clamp(fx, 0, 2), 4), y: roundTo(clamp(fy, 0, 2), 4) };
    if (frame.w < 0.05 || frame.w > 1) return range(`${p}.frame.w`);
    if (frame.x + frame.w > 1 + EDIT_EPS) return range(`${p}.frame.x`);
    const op = /** @type {number} */ (c.opacity), vol = /** @type {number} */ (c.volume);
    if (op < 0.1 - 1e-9 || op > 1) return range(`${p}.opacity`);
    if (vol < 0 || vol > 1) return range(`${p}.volume`);
    const pt = parsePitch(c, p);
    if (!pt.ok) return pt;
    // optional layer (section 39): an integer 0..7, present only when non-zero, so older timelines stay byte for byte
    let track = 0;
    if (c.track !== undefined) {
        if (!Number.isInteger(c.track)) return bad(`${p}.track`);
        track = /** @type {number} */ (c.track) + 0;
        if (track < 0 || track >= EDIT_OVERLAY_TRACKS) return range(`${p}.track`);
    }
    return {
        ok: true,
        clip: sortKeys({
            ...(pt.pitch !== 0 ? { pitch: pt.pitch } : {}),
            ...(track !== 0 ? { track } : {}),
            at: roundTo(at, 3),
            frame,
            id: /** @type {string} */ (c.id),
            in: cin,
            item: c.item,
            muted: c.muted,
            opacity: roundTo(op, 2),
            out: cout,
            volume: roundTo(vol, 2),
        }),
    };
}

/** @template T @param {T} o @returns {T} */
function sortKeys(o) {
    /** @type {any} */
    const out = {};
    for (const k of Object.keys(/** @type {any} */ (o)).sort(cmp)) out[k] = /** @type {any} */ (o)[k];
    return out;
}
/** Code-point order. @param {string} a @param {string} b */
function cmp(a, b) {
    const x = Array.from(a), y = Array.from(b);
    for (let i = 0; i < Math.min(x.length, y.length); i++) {
        const d = /** @type {number} */ (x[i].codePointAt(0)) - /** @type {number} */ (y[i].codePointAt(0));
        if (d !== 0) return d;
    }
    return x.length - y.length;
}

/**
 * too_long, overlay order/overlap, overlay past the end (31.4). Shared by parseTimeline and checkSources (a clamped `out`
 * can shorten the main track).
 * @param {Timeline} t @returns {Failure | null}
 */
function checkTiming(t) {
    const tm = timing(t);
    if (tm.frames > EDIT_MAX_SECONDS * tm.fps) return fail("error.edit.too_long", "main");
    // overlays are sorted by `at`; on one layer (`track`, section 39) they never share a frame, on different layers they may
    /** @type {number[]} */
    const maxEnd = new Array(EDIT_OVERLAY_TRACKS).fill(0);
    for (let i = 0; i < t.overlay.length; i++) {
        const o = tm.overlay[i];
        const k = t.overlay[i].track ?? 0;
        if (i > 0 && t.overlay[i].at < t.overlay[i - 1].at) return fail("error.edit.overlay_overlap", `overlay[${i}]`);
        if (o.start < maxEnd[k]) return fail("error.edit.overlay_overlap", `overlay[${i}]`);
        if (o.start + o.frames > tm.frames) return fail("error.edit.overlay_past_end", `overlay[${i}]`);
        maxEnd[k] = Math.max(maxEnd[k], o.start + o.frames);
    }
    return null;
}

// --- canonical JSON -----------------------------------------------------------------------------------------------

/**
 * The stored form (31.2): keys sorted by code point at every level, no whitespace, numbers in the shortest round-trip
 * decimal form (JSON.stringify's, which is what Swift's JSONEncoder with .sortedKeys writes for the same Double).
 * Feed it a `parseTimeline` result (that is where the rounding happens).
 * @param {unknown} v @returns {string}
 */
export function canonicalJSON(v) {
    if (Array.isArray(v)) return `[${v.map(canonicalJSON).join(",")}]`;
    if (isObj(v)) {
        return `{${Object.keys(v)
            .filter((k) => v[k] !== undefined)
            .sort(cmp)
            .map((k) => `${JSON.stringify(k)}:${canonicalJSON(v[k])}`)
            .join(",")}}`;
    }
    if (typeof v === "number") return JSON.stringify(Object.is(v, -0) ? 0 : v);
    return JSON.stringify(v);
}

// --- timing (31.4) ------------------------------------------------------------------------------------------------

/**
 * Frames are the unit. Main clip i: frames = max(1, roundHalfUp((out - in) / speed * F)), effective speed
 * s = (out - in) * F / frames; overlay: start = roundHalfUp(at * F), frames = max(1, roundHalfUp((out - in) * F)); audio is
 * 48 kHz, so `samples` = frames * 48000 / F (an integer for F in {30, 60}).
 * @param {Timeline} t
 * @returns {{fps: number, frames: number, seconds: number,
 *            main: {id: string, start: number, frames: number, speed: number, samples: number}[],
 *            overlay: {id: string, start: number, frames: number, samples: number}[]}}
 */
export function timing(t) {
    const F = t.canvas.fps;
    const spf = EDIT_SAMPLE_RATE / F;
    let n = 0;
    const main = t.main.map((c) => {
        const frames = Math.max(1, roundHalfUp(((c.out - c.in) / c.speed) * F));
        const row = { frames, id: c.id, samples: frames * spf, speed: ((c.out - c.in) * F) / frames, start: n };
        n += frames;
        return row;
    });
    const overlay = t.overlay.map((o) => {
        const frames = Math.max(1, roundHalfUp((o.out - o.in) * F));
        return { frames, id: o.id, samples: frames * spf, start: roundHalfUp(o.at * F) };
    });
    return { fps: F, frames: n, main, overlay, seconds: n / F };
}

// --- sources (needs the library rows) -----------------------------------------------------------------------------

const VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v"];
/**
 * The kind a content type means to the editor, or null for one it does not take. A webp (section 39) is a "photo" here:
 * the render helper finds out from its bytes whether it is animated (then it loops like a gif) or a still.
 * @param {string | null | undefined} ct @returns {"video" | "gif" | "photo" | null}
 */
export function sourceKind(ct) {
    const t = String(ct ?? "").split(";")[0].trim().toLowerCase();
    if (!EDIT_SOURCE_TYPES.includes(t)) return null;
    if (VIDEO_TYPES.includes(t)) return "video";
    return t === "image/gif" ? "gif" : "photo";
}

/**
 * The overlays in drawing order (section 39): bottom layer first, then by `at` (their order in the array). Returns indexes
 * into `t.overlay`. Without layers this is 0, 1, 2, ... (the order of 31.5).
 * @param {Timeline} t @returns {number[]}
 */
export function overlayDrawOrder(t) {
    return t.overlay.map((o, i) => ({ i, k: o.track ?? 0 })).sort((a, b) => a.k - b.k || a.i - b.i).map((x) => x.i);
}

/**
 * The checks that need the library rows (31.3): every item exists and is not deleted (source_missing), is a type the editor
 * takes (unsupported_source), main clips are videos (not_video), the inputs fit 6 GiB (too_large), `out` is not past the
 * source's end beyond the 0.05 s slack (past_source_end; inside the slack it is clamped), a crop is at least 64 px, a GIF or
 * photo overlay stays up 0.1..600 s from `in` 0, an overlay fits the canvas. Checks that need a size, a duration or a byte
 * count are skipped when the row has none. On success `timeline` is the clamped copy (use it, not the input).
 * @param {Timeline} timeline
 * @param {SourceRow[] | Map<string, SourceRow> | Record<string, SourceRow>} rows by id
 * @returns {{ok: true, timeline: Timeline} | Failure}
 */
export function checkSources(timeline, rows) {
    /** @type {Map<string, SourceRow>} */
    const byId = rows instanceof Map ? rows : Array.isArray(rows) ? new Map(rows.map((r) => [r.id, r])) : new Map(Object.entries(rows));
    /** @type {{item: string, path: string}[]} */
    const refs = [
        ...timeline.main.map((c, i) => ({ item: c.item, path: `main[${i}].item` })),
        ...timeline.overlay.map((o, i) => ({ item: o.item, path: `overlay[${i}].item` })),
    ];
    /** @param {(r: {item: string, path: string}) => boolean} bad @param {string} code @returns {Failure | null} */
    const scan = (bad, code) => {
        const hit = refs.filter(bad);
        return hit.length === 0 ? null : { ok: false, code, path: hit[0].path, items: [...new Set(hit.map((h) => h.item))] };
    };
    const row = (/** @type {string} */ id) => /** @type {SourceRow} */ (byId.get(id));
    let f = scan((r) => !byId.has(r.item) || !!row(r.item).deleted, "error.edit.source_missing");
    if (f) return f;
    f = scan((r) => sourceKind(row(r.item).content_type) === null, "error.edit.unsupported_source");
    if (f) return f;
    f = scan((r) => r.path.startsWith("main") && sourceKind(row(r.item).content_type) !== "video", "error.edit.not_video");
    if (f) return f;
    let bytes = 0;
    for (const id of new Set(refs.map((r) => r.item))) bytes += Number(row(id).bytes) || 0;
    if (bytes > EDIT_MAX_INPUT_BYTES) return fail("error.edit.too_large", "main");

    const t = /** @type {Timeline} */ (JSON.parse(JSON.stringify(timeline)));
    const { w: W, h: H } = t.canvas;
    for (let i = 0; i < t.main.length; i++) {
        const c = t.main[i], r = row(c.item), p = `main[${i}]`;
        const d = Number(r.duration);
        if (r.duration != null && d > 0) {
            if (c.out > d + EDIT_END_SLACK + 1e-9) return fail("error.edit.past_source_end", `${p}.out`);
            if (c.out > d) {
                c.out = roundTo(Math.floor(d * 1000 + 1e-9) / 1000, 3);
                if (!(c.in < c.out) || (c.out - c.in) / c.speed < 0.1 - 1e-9) return range(`${p}.out`);
            }
        }
        if (c.crop && r.width && r.height && cropToPixels(c.crop, r.width, r.height) === null) return range(`${p}.crop`);
    }
    for (let i = 0; i < t.overlay.length; i++) {
        const o = t.overlay[i], r = row(o.item), p = `overlay[${i}]`;
        const kind = /** @type {string} */ (sourceKind(r.content_type));
        if (kind === "video") {
            const d = Number(r.duration);
            if (r.duration != null && d > 0) {
                if (o.out > d + EDIT_END_SLACK + 1e-9) return fail("error.edit.past_source_end", `${p}.out`);
                if (o.out > d) {
                    o.out = roundTo(Math.floor(d * 1000 + 1e-9) / 1000, 3);
                    if (!(o.in < o.out) || o.out - o.in < 0.1 - 1e-9) return range(`${p}.out`);
                }
            }
        } else {
            if (o.in !== 0) return range(`${p}.in`);
            if (o.out < 0.1 || o.out > 600) return range(`${p}.out`);
        }
        if (r.width && r.height) {
            const h = (o.frame.w * W / H) * (r.height / r.width);
            if (o.frame.y + h > 1 + EDIT_EPS) return range(`${p}.frame.y`);
        }
    }
    const tf = checkTiming(t);
    if (tf) return tf;
    return { ok: true, timeline: t };
}

// --- geometry (31.6) ----------------------------------------------------------------------------------------------

/**
 * Section 10's crop -> whole even pixels, copied from api/helper/crop.js (the render image has no monorepo): each value to
 * the nearest even number, the size clamped to the even frame, the position clamped inside; null under MIN_CROP_PX a side.
 * @param {Rect} c normalised, display orientation @param {number} srcW @param {number} srcH
 * @returns {Rect | null}
 */
export function cropToPixels(c, srcW, srcH) {
    const near = (/** @type {number} */ v) => Math.round(v / 2) * 2;
    if (!Number.isInteger(srcW) || !Number.isInteger(srcH) || srcW < 2 || srcH < 2) return null;
    const maxW = evenFloor(srcW);
    const maxH = evenFloor(srcH);
    const w = Math.min(near(c.w * srcW), maxW);
    const h = Math.min(near(c.h * srcH), maxH);
    if (w < MIN_CROP_PX || h < MIN_CROP_PX) return null;
    const x = Math.max(0, Math.min(near(c.x * srcW), evenFloor(srcW - w)));
    const y = Math.max(0, Math.min(near(c.y * srcH), evenFloor(srcH - h)));
    return { x, y, w, h };
}

/**
 * Where a main clip's picture goes on the canvas (31.6). `display` = the source's display size (rotation applied, square
 * pixels), `crop` = the clip's crop (or null/undefined), `fit` = "fit" | "fill".
 * Returns {crop: {x, y, w, h} pixels, scaled: {w, h}, place: {x, y}} (place = top-left of the scaled picture on the canvas:
 * (px, py) for fit, (-qx, -qy) for fill), or null when the crop is under 64 px or the display size is unusable.
 * @param {{w: number, h: number}} display @param {Rect | null | undefined} crop @param {"fit" | "fill"} fit
 * @param {{w: number, h: number}} canvas
 * @returns {{crop: Rect, scaled: {w: number, h: number}, place: {x: number, y: number}} | null}
 */
export function mainPlacement(display, crop, fit, canvas) {
    const { w: sw, h: sh } = display;
    const { w: W, h: H } = canvas;
    if (!Number.isInteger(sw) || !Number.isInteger(sh) || sw < 2 || sh < 2) return null;
    const px = crop ? cropToPixels(crop, sw, sh) : { x: 0, y: 0, w: evenFloor(sw), h: evenFloor(sh) };
    if (!px) return null;
    const k = fit === "fit" ? Math.min(W / px.w, H / px.h) : Math.max(W / px.w, H / px.h);
    let dw = Math.max(2, evenNearest(px.w * k));
    let dh = Math.max(2, evenNearest(px.h * k));
    if (fit === "fit") {
        dw = Math.min(dw, W);
        dh = Math.min(dh, H);
        return { crop: px, place: { x: (W - dw) / 2 + 0, y: (H - dh) / 2 + 0 }, scaled: { h: dh, w: dw } };
    }
    dw = Math.max(dw, W);
    dh = Math.max(dh, H);
    return { crop: px, place: { x: -((dw - W) / 2) + 0, y: -((dh - H) / 2) + 0 }, scaled: { h: dh, w: dw } };
}

/**
 * An overlay's box on the canvas (31.6): {x, y, w, h} pixels.
 * @param {{w: number, h: number}} display @param {{x: number, y: number, w: number}} frame @param {{w: number, h: number}} canvas
 * @returns {{x: number, y: number, w: number, h: number}}
 */
export function overlayPlacement(display, frame, canvas) {
    const { w: W, h: H } = canvas;
    const ow = clamp(evenNearest(frame.w * W), 2, evenFloor(W));
    const oh = clamp(evenNearest((ow * display.h) / display.w), 2, evenFloor(H));
    const ox = clamp(roundHalfUp(frame.x * W), 0, W - ow);
    const oy = clamp(roundHalfUp(frame.y * H), 0, H - oh);
    return { h: oh, w: ow, x: ox, y: oy };
}
