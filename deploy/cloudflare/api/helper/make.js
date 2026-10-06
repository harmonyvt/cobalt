// What the helper MAKES from a gallery's items (APP-API-CONTRACT.md 18.10-18.11, apple/CONTRACT-GALLERY.md section 6):
//
//  - the slideshow WEBP (6.2): every composed picture is one webp frame held for its seconds, each crossfade is 4
//    blended frames, a video or gif is decoded at 15 fps; one `img2webp` run with today's forced keyframes;
//  - the borderless GALLERY IMAGE (6.3, 6.4): one ffmpeg run that stacks the photos in a layout with no gaps.
//
// The pure pieces (the geometry, the frame plan, the argv builders) are exported on their own so the tests can pin
// them without running anything; the two `render*` functions run the real tools. Plain Node ESM, no dependencies.
// (The slideshow MP4 stays in lib.js.)

import { mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import {
    JobError,
    KMAX,
    KMIN,
    MAX_OUTPUT_BYTES,
    MAX_WEBP_SLIDESHOW_SECONDS,
    QUALITY,
    TOO_LONG_SLACK,
    buildPosterArgs,
    fillGraph,
    needsBlur,
    parseWebp,
    readFileHead,
    runProcess,
    sniffType,
} from "./lib.js";

// Plain decimal, at most 3 places (never "1e-7": ffmpeg would misread it).
const dec = (n) => String(+Number(n).toFixed(3));

// --- the gallery image's geometry (6.4; the reference is apple/CONTRACT-GALLERY.model.js `layout`) --------------

export const GALLERY_LAYOUTS = ["strip", "grid2", "grid3", "row"];
export const MAX_GALLERY_PHOTOS = 20;
export const MIN_GALLERY_PHOTOS = 2;
/** The longest side of a gallery image in pixels, and its area: over either, the layout is rebuilt smaller. */
export const GALLERY_MAX_LONG = 30000;
export const GALLERY_MAX_PIXELS = 40e6;
/** A cell's aspect may differ from its photo's by less than this and still count as "not cropped" (0.4 %). */
export const GALLERY_CROP_TOL = 0.004;
/** The output's size cap (APP-API-CONTRACT 18.11): over it the make ends error.webp.too_large. */
export const MAX_GALLERY_BYTES = 50 * 1024 * 1024;
/**
 * Above this many source pixels (all the photos together) the photos are scaled to their cells ONE AT A TIME into JPEGs and the
 * final run only stacks those, because one ffmpeg that opens 20 inputs at once holds every decoded source in memory (measured:
 * 20 photos of 4096x2731 = 1.3 GB of resident memory in one run, 0.3 GB staged; the container has 1 GiB, cobalt included).
 * 24 MP is about 18 Instagram photos at 1080x1350.
 */
export const GALLERY_STAGE_PIXELS = 24e6;

/** `n` floored to an even integer, at least 2. */
export function even(n) {
    n = Math.floor(n);
    return Math.max(2, n - (n % 2));
}

/** The width/height ratio of the most common `width x height` among the photos (ties: the first to reach the count). */
export function commonAspect(sizes) {
    /** @type {Record<string, number>} */
    const seen = {};
    /** @type {{k: string, w: number, h: number} | null} */
    let best = null;
    for (const s of sizes) {
        const k = `${s.w}x${s.h}`;
        seen[k] = (seen[k] || 0) + 1;
        if (!best || seen[k] > seen[best.k]) best = { k, w: s.w, h: s.h };
    }
    return /** @type {{w: number, h: number}} */ (best).w / /** @type {{w: number, h: number}} */ (best).h;
}

/**
 * How many photos each row of a grid `N` across holds: rows are balanced (10 in 3 across = 3+3+2+2), the first rows
 * take the extra.
 * @param {number} n @param {number} N
 */
export function rowCounts(n, N) {
    const r = Math.ceil(n / N);
    const base = Math.floor(n / r);
    const extra = n - base * r;
    return Array.from({ length: r }, (_, i) => (i < extra ? base + 1 : base));
}

/**
 * The geometry of a gallery image: the canvas and every photo's cell. No gaps, no borders: the cells tile the canvas
 * exactly. `sizes` are the photos' width/height in the order they are drawn.
 *  - strip: W = even(min(1080, narrowest width)), each photo W wide at its own aspect, stacked; never crops;
 *  - row: H = even(min(1080, shortest height)), side by side; never crops;
 *  - grid2 | grid3: balanced rows, canvas width even(min(2160, fullest row x narrowest width)); a cell's aspect is the
 *    most common photo aspect, the photo covers its cell (centre crop); a cell wider than its photo is `up`
 *    (the factor, 0 = not drawn larger).
 * Over 30,000 px on a side or 40 MP the base size is multiplied down and the layout rebuilt (`scaled`).
 * @param {{w: number, h: number}[]} sizes
 * @param {"strip" | "grid2" | "grid3" | "row"} kind
 * @returns {{width: number, height: number, cells: {i: number, x: number, y: number, w: number, h: number, crop: boolean, up: number}[], scaled: boolean, rows: number[][]}}
 */
export function galleryLayout(sizes, kind) {
    if (!Array.isArray(sizes) || sizes.length < MIN_GALLERY_PHOTOS) throw new JobError("error.webp.invalid_params");
    if (!GALLERY_LAYOUTS.includes(kind)) throw new JobError("error.webp.invalid_params");
    const n = sizes.length;
    const build = (scaleTo) => {
        const cells = [];
        const rows = [];
        let W;
        let H;
        if (kind === "strip") {
            W = scaleTo;
            H = 0;
            sizes.forEach((s, i) => {
                const h = even(Math.round((W * s.h) / s.w));
                cells.push({ i, x: 0, y: H, w: W, h, crop: false, up: 0 });
                rows.push([i]);
                H += h;
            });
        } else if (kind === "row") {
            H = scaleTo;
            W = 0;
            sizes.forEach((s, i) => {
                const w = even(Math.round((H * s.w) / s.h));
                cells.push({ i, x: W, y: 0, w, h: H, crop: false, up: 0 });
                W += w;
            });
            rows.push(sizes.map((_, i) => i));
        } else {
            const N = kind === "grid3" ? 3 : 2;
            const A = commonAspect(sizes);
            let k0 = 0;
            W = scaleTo;
            H = 0;
            for (const k of rowCounts(n, N)) {
                const cw = even(W / k);
                const last = W - (k - 1) * cw;
                const rh = even(Math.round(cw / A));
                let x = 0;
                const row = [];
                for (let j = 0; j < k; j++) {
                    const w = j === k - 1 ? last : cw;
                    const s = sizes[k0 + j];
                    const ca = w / rh;
                    const a = s.w / s.h;
                    const up = Math.max(w / s.w, rh / s.h);
                    cells.push({
                        i: k0 + j,
                        x,
                        y: H,
                        w,
                        h: rh,
                        crop: Math.abs(a - ca) / ca >= GALLERY_CROP_TOL,
                        up: up > 1.01 ? Math.round(up * 10) / 10 : 0,
                    });
                    row.push(k0 + j);
                    x += w;
                }
                rows.push(row);
                H += rh;
                k0 += k;
            }
        }
        return { width: W, height: H, cells, rows };
    };
    const minW = Math.min(...sizes.map((s) => s.w));
    const minH = Math.min(...sizes.map((s) => s.h));
    const base =
        kind === "strip"
            ? even(Math.min(1080, minW))
            : kind === "row"
              ? even(Math.min(1080, minH))
              : even(Math.min(2160, rowCounts(n, kind === "grid3" ? 3 : 2)[0] * minW));
    let r = build(base);
    const long = Math.max(r.width, r.height);
    const px = r.width * r.height;
    if (long > GALLERY_MAX_LONG || px > GALLERY_MAX_PIXELS) {
        const s = Math.min(GALLERY_MAX_LONG / long, Math.sqrt(GALLERY_MAX_PIXELS / px));
        r = build(even(base * s));
        return { ...r, scaled: true };
    }
    return { ...r, scaled: false };
}

// --- the gallery image's wire and recipe (6.3, 18.7/18.11) ----------------------------------------------------

/**
 * Re-validates the body of `POST /gallery/:id/start`: `{layout, slides: [{n}]}`. `layout` one of the four; 2-20 slides
 * with unique `n` 0-19, in the order they are drawn. Returns the normalised body or null.
 * @param {any} b
 * @returns {{layout: "strip" | "grid2" | "grid3" | "row", slides: {n: number}[]} | null}
 */
export function validateGalleryStart(b) {
    if (typeof b !== "object" || b === null) return null;
    if (!GALLERY_LAYOUTS.includes(b.layout)) return null;
    if (!Array.isArray(b.slides) || b.slides.length < MIN_GALLERY_PHOTOS || b.slides.length > MAX_GALLERY_PHOTOS) return null;
    const seen = new Set();
    const slides = [];
    for (const sl of b.slides) {
        if (typeof sl !== "object" || sl === null) return null;
        if (!Number.isInteger(sl.n) || sl.n < 0 || sl.n >= MAX_GALLERY_PHOTOS || seen.has(sl.n)) return null;
        seen.add(sl.n);
        slides.push({ n: sl.n });
    }
    return { layout: b.layout, slides };
}

// One photo scaled to its cell: a strip and a row scale to it; a grid covers it (scale up to cover, then centre-crop)
const fitCell = (c, grid) =>
    grid ? `scale=${c.w}:${c.h}:force_original_aspect_ratio=increase:flags=lanczos,crop=${c.w}:${c.h}` : `scale=${c.w}:${c.h}:flags=lanczos`;

/**
 * ffmpeg argv that scales ONE photo to its cell and writes it as a near-lossless JPEG (`-q:v 1`, 4:2:0 full range: what
 * the final JPEG is made of anyway, and half the memory of a PNG when the cells are stacked: measured 209 MB against
 * 417 MB for 20 photos of 1080x1350) (the staged way, GALLERY_STAGE_PIXELS).
 * @param {{input: string, cell: {w: number, h: number}, grid: boolean, output: string}} j
 */
export function buildGalleryCellArgs(j) {
    return [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-nostats",
        "-protocol_whitelist", "file,pipe",
        "-i", j.input,
        "-vf", `${fitCell(j.cell, j.grid)},setsar=1,format=yuvj420p`,
        "-frames:v", "1",
        "-q:v", "1",
        "-f", "image2",
        "-update", "1",
        "-y",
        j.output,
    ];
}

/**
 * ffmpeg argv that draws the whole gallery image in ONE run: each input scaled to its cell (a grid cell covers: scale up
 * to cover, then centre-crop), a grid joins each row with `hstack` (a lone cell passes through) and the rows with
 * `vstack`, a strip is one `vstack`, a row one `hstack`; 4:2:0 full range, one JPEG frame at `-q:v 3`.
 * @param {{files: string[], geometry: ReturnType<typeof galleryLayout>, kind: "strip" | "grid2" | "grid3" | "row", output: string, prescaled?: boolean}} j
 *   `files[i]` is the picture of `geometry.cells[i]` (the order they are drawn)
 */
export function buildGalleryImageArgs(j) {
    const grid = j.kind === "grid2" || j.kind === "grid3";
    const args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats"];
    const parts = [];
    for (const f of j.files) args.push("-protocol_whitelist", "file,pipe", "-i", f);
    for (const c of j.geometry.cells) {
        // `prescaled`: the inputs are the cells already (see GALLERY_STAGE_PIXELS), they only need stacking
        parts.push(`[${c.i}:v]${j.prescaled ? "" : `${fitCell(c, grid)},`}setsar=1,format=yuvj420p[c${c.i}]`);
    }
    const label = (i) => `[c${i}]`;
    if (j.kind === "strip") {
        parts.push(`${j.files.map((_, i) => label(i)).join("")}vstack=inputs=${j.files.length}[out]`);
    } else if (j.kind === "row") {
        parts.push(`${j.files.map((_, i) => label(i)).join("")}hstack=inputs=${j.files.length}[out]`);
    } else {
        j.geometry.rows.forEach((row, r) => {
            parts.push(row.length === 1 ? `${label(row[0])}null[r${r}]` : `${row.map(label).join("")}hstack=inputs=${row.length}[r${r}]`);
        });
        const rows = j.geometry.rows;
        parts.push(rows.length === 1 ? `[r0]null[out]` : `${rows.map((_, r) => `[r${r}]`).join("")}vstack=inputs=${rows.length}[out]`);
    }
    args.push(
        "-filter_complex", parts.join(";"),
        "-map", "[out]",
        "-frames:v", "1",
        "-q:v", "3",
        "-f", "image2",
        "-update", "1",
        "-y",
        j.output,
    );
    return args;
}

/**
 * The whole gallery image: checks every input is a still, probes the sizes, works out the geometry, one ffmpeg run.
 * The caller owns the files in `dir` (inputs as `input-<n>`); this writes `output`. `cropped` / `upscaled` name the
 * input slots (`n`) whose photo is cut to its cell / drawn larger than its own pixels. Throws JobError:
 * error.webp.invalid_params (an input that is no still, or fewer than 2), error.webp.bad_source (no size),
 * error.webp.timeout, error.webp.encode_failed, error.webp.too_large (over `maxOutputBytes`).
 * @param {{ffmpegBin: string, output: string, files: Map<number, string>,
 *          plan: {layout: "strip" | "grid2" | "grid3" | "row", slides: {n: number}[]},
 *          probeAV: (file: string) => Promise<{duration: number | null, width: number | null, height: number | null, hasAudio: boolean}>,
 *          timeoutMs: number, maxOutputBytes?: number, stagePixels?: number, spawnImpl?: typeof import("node:child_process").spawn,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void,
 *          onPhase?: (phase: "composing", p: {done: number, total: number}) => void}} o
 * @returns {Promise<{bytes: number, width: number, height: number, cropped: number[], upscaled: number[], scaled: boolean, staged: boolean}>}
 */
export async function renderGalleryImage(o) {
    const deadline = Date.now() + o.timeoutMs;
    const total = o.plan.slides.length;
    o.onPhase?.("composing", { done: 0, total });
    const files = [];
    const sizes = [];
    for (const sl of o.plan.slides) {
        const file = o.files.get(sl.n);
        if (!file) throw new JobError("error.webp.invalid_params");
        // a photo only: a video or a gif is no still (APP-API-CONTRACT 18.11), whatever its name
        const sniffed = sniffType(await readFileHead(file, 12));
        if (sniffed?.type !== "image") throw new JobError("error.webp.invalid_params");
        const info = await o.probeAV(file);
        if (!info.width || !info.height) throw new JobError("error.webp.bad_source");
        files.push(file);
        sizes.push({ w: info.width, h: info.height });
    }
    const geometry = galleryLayout(sizes, o.plan.layout);
    const staged = sizes.reduce((t, s) => t + s.w * s.h, 0) > (o.stagePixels ?? GALLERY_STAGE_PIXELS);
    const cellDir = `${o.output}.cells`;
    try {
        let stack = files;
        if (staged) {
            // one photo at a time (each decoded alone), then only the cells are stacked
            await mkdir(cellDir, { recursive: true });
            stack = [];
            const grid = o.plan.layout === "grid2" || o.plan.layout === "grid3";
            for (const [k, c] of geometry.cells.entries()) {
                const out = path.join(cellDir, `cell-${c.i}.jpg`);
                await runProcess({
                    spawnImpl: o.spawnImpl,
                    bin: o.ffmpegBin,
                    args: buildGalleryCellArgs({ input: files[c.i], cell: c, grid, output: out }),
                    timeoutMs: deadline - Date.now(),
                    label: "gallery cell",
                    onChild: o.onChild,
                });
                stack[c.i] = out;
                o.onPhase?.("composing", { done: k + 1, total });
            }
        }
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.ffmpegBin,
            args: buildGalleryImageArgs({ files: stack, geometry, kind: o.plan.layout, output: o.output, prescaled: staged }),
            timeoutMs: deadline - Date.now(),
            label: "gallery image",
            onChild: o.onChild,
        });
    } finally {
        if (staged) await rm(cellDir, { recursive: true, force: true }).catch(() => {});
    }
    const size = (await stat(o.output).catch(() => null))?.size ?? 0;
    if (!(size > 0)) throw new JobError("error.webp.encode_failed");
    if (size > (o.maxOutputBytes ?? MAX_GALLERY_BYTES)) throw new JobError("error.webp.too_large");
    o.onPhase?.("composing", { done: total, total });
    const slot = (cell) => o.plan.slides[cell.i].n;
    return {
        bytes: size,
        width: geometry.width,
        height: geometry.height,
        cropped: geometry.cells.filter((c) => c.crop).map(slot),
        upscaled: geometry.cells.filter((c) => c.up > 0).map(slot),
        scaled: geometry.scaled,
        staged,
    };
}

// --- the slideshow webp: the frame plan (6.2) -----------------------------------------------------------------------

export const WEBP_FPS = 15;
/** Frames in one crossfade (6.2). */
export const FADE_FRAMES = 4;
/** The slideshow webp's length cap (the mp4's is 180); over it the make ends error.webp.too_long (+ the usual slack). */
export const WEBP_MAX_SECONDS = MAX_WEBP_SLIDESHOW_SECONDS;

/** One frame's time in ms at `fps` (67 ms at 15 fps). */
export const frameMs = (fps = WEBP_FPS) => Math.round(1000 / fps);

/**
 * The frames of a slideshow webp, in play order, each with the ms it is held (6.2):
 *  - a still: ONE frame held `round(seconds x 1000)` less half a crossfade (`FADE_FRAMES x fd / 2`) at each end that has one;
 *  - between two slides with `fade`: FADE_FRAMES frames of one frame time, blend `j/(FADE_FRAMES+1)` of the outgoing
 *    and the incoming picture (`t: "fade"`, j = 1..FADE_FRAMES);
 *  - a video or gif: its frames decoded at `fps` (`frames` = how many were decoded, default round(seconds x fps)), each
 *    held one frame time, FADE_FRAMES/2 frames fewer at each end that has a crossfade; the last kept frame holds what
 *    is left, so the total is the slide's seconds and not up to half a frame off.
 * The total is the plan's length (sum of the slides' seconds). Worked example, 3 photos at 2 s with a fade: 1866, 4 x 67,
 * 1732, 4 x 67, 1866 ms = 6000 ms.
 * @param {{kind: "still" | "motion", seconds: number, frames?: number}[]} slides
 * @param {boolean} fade
 * @param {number} [fps]
 * @returns {{frames: ({t: "still", slide: number, ms: number} | {t: "motion", slide: number, frame: number, ms: number} | {t: "fade", from: number, to: number, j: number, ms: number})[], totalMs: number}}
 */
export function planWebpFrames(slides, fade, fps = WEBP_FPS) {
    const fd = frameMs(fps);
    const half = (FADE_FRAMES * fd) / 2;
    const n = slides.length;
    const fading = fade && n > 1;
    const out = [];
    let totalMs = 0;
    const add = (f) => {
        out.push(f);
        totalMs += f.ms;
    };
    slides.forEach((s, i) => {
        const fadeIn = fading && i > 0;
        const fadeOut = fading && i < n - 1;
        const target = Math.max(fd, Math.round(s.seconds * 1000) - (fadeIn ? half : 0) - (fadeOut ? half : 0));
        if (s.kind === "still") {
            add({ t: "still", slide: i, ms: target });
        } else {
            const decoded = Math.max(1, s.frames ?? Math.round(s.seconds * fps));
            const count = Math.max(1, Math.round(target / fd));
            const head = fadeIn ? FADE_FRAMES / 2 : 0;
            for (let j = 0; j < count; j++) {
                add({ t: "motion", slide: i, frame: Math.min(decoded - 1, head + j), ms: j === count - 1 ? target - (count - 1) * fd : fd });
            }
        }
        if (fadeOut) for (let j = 1; j <= FADE_FRAMES; j++) add({ t: "fade", from: i, to: i + 1, j, ms: fd });
    });
    return { frames: out, totalMs };
}

/** How long (ms) the webp should run: the plan's seconds, the same number `planWebpFrames` adds up to. */
export const planMs = (slides) => slides.reduce((t, s) => t + Math.round(s.seconds * 1000), 0);

/**
 * img2webp argv for a frame list: today's flags (`-loop 0 -lossy -q <65|75|85> -m 4 -kmin 3 -kmax 5`, forced keyframes,
 * README "ghosting"), then `-d <ms> <file>` per frame (frame names relative to the cwd, so 900 frames stay a few KB of argv).
 * @param {{frames: {file: string, ms: number}[], output: string, quality: "low" | "med" | "high"}} j
 */
export function buildFrameListArgs(j) {
    return [
        "-loop", "0",
        "-lossy",
        "-q", String(QUALITY[j.quality]),
        "-m", "4",
        "-kmin", String(KMIN),
        "-kmax", String(KMAX),
        ...j.frames.flatMap((f) => ["-d", String(f.ms), f.file]),
        "-o", j.output,
    ];
}

/**
 * ffmpeg argv that composes one still ONCE into a frame-sized PNG (the blurred fill unless the aspect matches).
 * @param {{input: string, output: string, width: number, height: number, blur: boolean}} j
 */
export function buildComposePngArgs(j) {
    return [
        "-nostdin", "-hide_banner", "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        "-i", j.input,
        "-filter_complex", `${fillGraph({ inL: "0:v", outL: "fit", pre: "c", width: j.width, height: j.height, blur: j.blur })};[fit]format=rgb24[out]`,
        "-map", "[out]",
        "-frames:v", "1",
        "-compression_level", "1",
        "-f", "image2",
        "-update", "1",
        "-y",
        j.output,
    ];
}

/**
 * ffmpeg argv that decodes a video or gif at `fps` into numbered frame-sized PNGs (`pattern` has one `%05d`, counting from 1).
 * @param {{input: string, pattern: string, width: number, height: number, blur: boolean, fps: number}} j
 */
export function buildMotionFramesArgs(j) {
    return [
        "-nostdin", "-hide_banner", "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        "-i", j.input,
        "-filter_complex", `[0:v]fps=${j.fps}[r];${fillGraph({ inL: "r", outL: "f", pre: "m", width: j.width, height: j.height, blur: j.blur })};[f]format=rgb24[out]`,
        "-map", "[out]",
        "-an", "-sn", "-dn",
        "-compression_level", "1",
        "-f", "image2",
        "-y",
        j.pattern,
    ];
}

/**
 * ffmpeg argv for ONE crossfade: the FADE_FRAMES blends of two equal-sized pictures, `outputs[j-1]` = (1 - t) x `a` + t x `b`
 * with t = j / (FADE_FRAMES + 1), in one process (a process per frame would cost 76 spawns for 20 photos).
 * @param {{a: string, b: string, outputs: string[]}} j
 */
export function buildBlendArgs(j) {
    const k = j.outputs.length;
    const parts = [
        `[0:v]split=${k}${j.outputs.map((_, i) => `[a${i}]`).join("")}`,
        `[1:v]split=${k}${j.outputs.map((_, i) => `[b${i}]`).join("")}`,
    ];
    j.outputs.forEach((_, i) => {
        const t = (i + 1) / (k + 1);
        parts.push(`[a${i}][b${i}]blend=all_expr='A*${dec(1 - t)}+B*${dec(t)}',format=rgb24[o${i}]`);
    });
    const args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe", "-i", j.a, "-protocol_whitelist", "file,pipe", "-i", j.b, "-filter_complex", parts.join(";")];
    j.outputs.forEach((out, i) => args.push("-map", `[o${i}]`, "-frames:v", "1", "-compression_level", "1", "-f", "image2", "-update", "1", "-y", out));
    return args;
}

/**
 * The poster of a make: ONE JPEG frame of `input` (a PNG frame, or `at` seconds into a video). Best effort for the caller.
 * `onChild` registers the process, so the job's watchdog and DELETE can kill it like any other run.
 * @param {{ffmpegBin: string, input: string, output: string, at?: number | null, timeoutMs: number, spawnImpl?: typeof import("node:child_process").spawn,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void}} o
 * @returns {Promise<boolean>} whether a JPEG was written
 */
export async function makePoster(o) {
    try {
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.ffmpegBin,
            args: buildPosterArgs({ input: o.input, output: o.output, at: o.at ?? null }),
            timeoutMs: o.timeoutMs,
            label: "make poster",
            onChild: o.onChild,
        });
    } catch {
        await rm(o.output, { force: true }).catch(() => {});
        return false;
    }
    return ((await stat(o.output).catch(() => null))?.size ?? 0) > 0;
}

// --- the slideshow webp, run (6.2) --------------------------------------------------------------------------------

/**
 * The whole slideshow webp: probes the inputs, composes each still ONCE at the frame size (PNG), decodes each video or gif
 * at `fps`, blends each crossfade (4 frames, one ffmpeg run each), then one `img2webp` run turns the frame list into
 * `output`. The caller owns the files in `dir` (inputs as `input-<n>`); this writes `frames/` (deleted again, success or
 * failure), `poster.jpg` (the first frame, best effort) and `output`. One shared budget (`timeoutMs`). Throws JobError:
 * error.webp.invalid_params (a still without seconds, a video with), error.webp.bad_source (an input that is no picture,
 * or a video with no length), error.webp.too_long (over 60 s with the videos counted, or the videos over 60 s),
 * error.webp.timeout, error.webp.encode_failed, error.webp.too_large (over `maxOutputBytes`).
 * @param {{ffmpegBin: string, img2webpBin: string, dir: string, output: string, files: Map<number, string>,
 *          plan: {width: number, height: number, fade: boolean, quality: "low" | "med" | "high", fps?: number,
 *                 slides: {n: number, seconds: number | null}[]},
 *          probeAV: (file: string) => Promise<{duration: number | null, width: number | null, height: number | null, hasAudio: boolean}>,
 *          timeoutMs: number, maxOutputBytes?: number, maxSeconds?: number, spawnImpl?: typeof import("node:child_process").spawn,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void,
 *          onPhase?: (phase: "composing" | "encoding", p: {done: number, total: number}) => void}} o
 * @returns {Promise<{bytes: number, duration: number, width: number, height: number, frames: number, posterBytes: number}>}
 */
export async function renderSlideshowWebp(o) {
    const deadline = Date.now() + o.timeoutMs;
    const left = () => deadline - Date.now();
    const { width, height, quality } = o.plan;
    const fps = o.plan.fps ?? WEBP_FPS;
    const maxSeconds = o.maxSeconds ?? WEBP_MAX_SECONDS;

    /** @type {{n: number, file: string, still: boolean, seconds: number, info: Awaited<ReturnType<typeof o.probeAV>>}[]} */
    const slides = [];
    for (const sl of o.plan.slides) {
        const file = o.files.get(sl.n);
        if (!file) throw new JobError("error.webp.invalid_params");
        const sniffed = sniffType(await readFileHead(file, 12));
        const still = sniffed?.type === "image";
        if (still !== (sl.seconds !== null)) throw new JobError("error.webp.invalid_params");
        const info = await o.probeAV(file);
        if (info.width === null || info.height === null) throw new JobError("error.webp.bad_source");
        if (!still && !(info.duration && info.duration > 0)) throw new JobError("error.webp.bad_source");
        slides.push({ n: sl.n, file, still, seconds: still ? /** @type {number} */ (sl.seconds) : /** @type {number} */ (info.duration), info });
    }
    // the cap is the slideshow's own length (the videos counted): a longer one needs the mp4
    const total = slides.reduce((t, s) => t + s.seconds, 0);
    if (total > maxSeconds + TOO_LONG_SLACK) throw new JobError("error.webp.too_long");
    const motion = slides.filter((s) => !s.still).reduce((t, s) => t + s.seconds, 0);
    if (motion > maxSeconds + TOO_LONG_SLACK) throw new JobError("error.webp.too_long");

    const framesDir = path.join(o.dir, "frames");
    const fades = o.plan.fade && slides.length > 1 ? slides.length - 1 : 0;
    const units = slides.length + fades;
    let done = 0;
    o.onPhase?.("composing", { done, total: units });
    try {
        await rm(framesDir, { recursive: true, force: true });
        await mkdir(framesDir, { recursive: true });
        const run = (label, args) =>
            runProcess({ spawnImpl: o.spawnImpl, bin: o.ffmpegBin, args, timeoutMs: left(), label, onChild: o.onChild, cwd: framesDir });

        // each still once, each video or gif decoded
        /** @type {{first: string, last: string, frames: number}[]} */
        const pictures = [];
        for (const [i, s] of slides.entries()) {
            const blur = needsBlur(s.info.width, s.info.height, width, height);
            if (s.still) {
                const file = `s-${i}.png`;
                await run("webp compose", buildComposePngArgs({ input: s.file, output: path.join(framesDir, file), width, height, blur }));
                pictures.push({ first: file, last: file, frames: 1 });
            } else {
                await run("webp decode", buildMotionFramesArgs({ input: s.file, pattern: path.join(framesDir, `m${i}-%05d.png`), width, height, blur, fps }));
                const names = (await readdir(framesDir)).filter((f) => f.startsWith(`m${i}-`) && f.endsWith(".png")).sort();
                if (names.length === 0) throw new JobError("error.webp.encode_failed");
                pictures.push({ first: names[0], last: names[names.length - 1], frames: names.length });
            }
            o.onPhase?.("composing", { done: ++done, total: units });
        }
        const plan = planWebpFrames(slides.map((s, i) => ({ kind: s.still ? "still" : "motion", seconds: s.seconds, frames: pictures[i].frames })), o.plan.fade, fps);

        // each crossfade: FADE_FRAMES blends of the outgoing and the incoming picture, one ffmpeg run
        for (let i = 0; i < slides.length - 1 && fades > 0; i++) {
            const outputs = Array.from({ length: FADE_FRAMES }, (_, j) => path.join(framesDir, `x-${i}-${j + 1}.png`));
            await run("webp blend", buildBlendArgs({ a: path.join(framesDir, pictures[i].last), b: path.join(framesDir, pictures[i + 1].first), outputs }));
            o.onPhase?.("composing", { done: ++done, total: units });
        }

        // the frame list, by file name (img2webp runs with the frames dir as its cwd)
        const names = plan.frames.map((f) => ({
            file:
                f.t === "still"
                    ? pictures[f.slide].first
                    : f.t === "fade"
                      ? `x-${f.from}-${f.j}.png`
                      : `m${f.slide}-${String(f.frame + 1).padStart(5, "0")}.png`,
            ms: f.ms,
        }));
        const poster = path.join(o.dir, "poster.jpg");
        await makePoster({ ffmpegBin: o.ffmpegBin, input: path.join(framesDir, names[0].file), output: poster, timeoutMs: Math.max(1, Math.min(30_000, left())), spawnImpl: o.spawnImpl, onChild: o.onChild });

        const seconds = Math.round(plan.totalMs / 100) / 10;
        o.onPhase?.("encoding", { done: 0, total: seconds });
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.img2webpBin,
            args: buildFrameListArgs({ frames: names, output: o.output, quality }),
            cwd: framesDir,
            timeoutMs: left(),
            label: "img2webp",
            onChild: o.onChild,
        });
        const size = (await stat(o.output).catch(() => null))?.size ?? 0;
        if (!(size > 0)) throw new JobError("error.webp.encode_failed");
        if (size > (o.maxOutputBytes ?? MAX_OUTPUT_BYTES)) throw new JobError("error.webp.too_large");
        const webp = parseWebp(await readFile(o.output));
        if (!webp || !webp.frames) throw new JobError("error.webp.encode_failed");
        o.onPhase?.("encoding", { done: seconds, total: seconds });
        return {
            bytes: size,
            duration: Math.round(webp.durationMs) / 1000,
            width: webp.width || width,
            height: webp.height || height,
            frames: webp.frames,
            posterBytes: (await stat(poster).catch(() => null))?.size ?? 0,
        };
    } finally {
        await rm(framesDir, { recursive: true, force: true }).catch(() => {});
    }
}
