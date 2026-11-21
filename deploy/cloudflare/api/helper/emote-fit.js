// Fitting a library picture for 7TV (APP-API-CONTRACT.md section 57.10): POST /emote-fit.
//
// 7TV takes at most 7 MiB, 1000 x 1000 px, 1000 frames, and a width/height ratio between 1/32 and 3. Its processing
// throws away a file over any of those without a word, so the Worker sends anything that does not fit here first:
//
//   1. frames: an animated WebP is taken apart and composed here (the container's ffmpeg skips ANIM/ANMF, see
//      webp-anim.js), every other picture (gif, png, jpeg, still webp) is decoded by ffmpeg, all to RGBA PNGs with
//      each frame's own duration (a gif's from its Graphic Control Extensions);
//   2. over 1000 frames, frames are dropped evenly and their time goes to the frame before;
//   3. one ffmpeg pass crops (an optional box, fractions of the picture) and scales so the longest side is at most
//      `size` (default 512, never larger than the source);
//   4. img2webp packs the frames at falling quality, then at a smaller scale, until the file is under `max_bytes`.
//
// The output is an animated-or-still lossy WebP with alpha unless the caller asks otherwise. Section 71.3 adds, all
// optional: `stretch` (squash after the crop), `format` webp|gif|png, a fixed `quality` (one encode, over_cap reported
// instead of failing), `fps` (frames thinned, the loop keeps its length), a video source (`video`, `start`, `end`
// sampled at `fps`), `bounce` (forward then back) and `frame` (the still for png). Without them: exactly as before.
// Plain Node ESM, no dependencies.

import { spawn } from "node:child_process";
import { copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { crc32, deflateSync } from "node:zlib";
import { JobError } from "./lib.js";
import { WEBP_MAX_CANVAS, WEBP_MAX_FRAMES, WEBP_MAX_TOTAL_PIXELS, drawFrame, parseWebpAnim, stillOfFrame } from "./webp-anim.js";

/** 7TV's limits (its image processor). */
export const EMOTE_MAX_SIDE = 1000;
export const EMOTE_MAX_FRAMES = 1000;
export const EMOTE_MIN_RATIO = 1 / 32;
export const EMOTE_MAX_RATIO = 3;
/** The longest side when the caller names none: 4x of a 128 px emote, a fraction of the bytes of 1000 px. */
export const EMOTE_DEFAULT_SIDE = 512;
export const EMOTE_MIN_SIDE = 32;
/** Bytes this route reads (an emote source is a picture, not a video). */
export const EMOTE_FIT_MAX_INPUT = 64 * 1024 * 1024;
/** The whole fit, decode to last pack. */
export const EMOTE_FIT_TIMEOUT_MS = 150_000;
/** quality, then scale: tried in order until the file fits. */
export const FIT_STEPS = [
    { scale: 1, q: 82 },
    { scale: 1, q: 65 },
    { scale: 1, q: 45 },
    { scale: 0.75, q: 60 },
    { scale: 0.75, q: 40 },
    { scale: 0.5, q: 50 },
    { scale: 0.5, q: 30 },
];

/**
 * Where to cut and how big the result is. Throws error.seventv.fit_shape (400) when the box, or the whole picture,
 * is outside 7TV's ratio.
 * `stretch` (each way 0.25 to 4) squashes or stretches the crop; the ratio check and `size` then see the stretched shape.
 * @param {{width: number, height: number, crop?: {x: number, y: number, w: number, h: number} | null, size?: number | null,
 *   stretch?: {w: number, h: number} | null}} o
 * @returns {{crop: {x: number, y: number, w: number, h: number}, width: number, height: number}}
 */
export function planFit(o) {
    const W = o.width;
    const H = o.height;
    let crop = { x: 0, y: 0, w: W, h: H };
    if (o.crop) {
        const c = o.crop;
        const x = Math.max(0, Math.round(c.x * W));
        const y = Math.max(0, Math.round(c.y * H));
        const w = Math.min(W - x, Math.round(c.w * W));
        const h = Math.min(H - y, Math.round(c.h * H));
        if (!(w >= 1 && h >= 1)) throw new JobError("error.seventv.fit_shape", "the crop box is outside the picture");
        crop = { x, y, w, h };
    }
    const cw = crop.w * (o.stretch?.w ?? 1);
    const ch = crop.h * (o.stretch?.h ?? 1);
    const ratio = cw / ch;
    if (ratio < EMOTE_MIN_RATIO || ratio > EMOTE_MAX_RATIO) {
        throw new JobError(
            "error.seventv.fit_shape",
            `${Math.round(cw)}x${Math.round(ch)} is ${ratio > 1 ? "wider" : "taller"} than 7TV allows (width/height between 1/32 and 3): pick a crop box`,
        );
    }
    const target = Math.min(EMOTE_MAX_SIDE, Math.max(EMOTE_MIN_SIDE, Math.round(o.size ?? EMOTE_DEFAULT_SIDE)));
    const scale = Math.min(1, target / Math.max(cw, ch));
    return { crop, width: Math.max(1, Math.round(cw * scale)), height: Math.max(1, Math.round(ch * scale)) };
}

/**
 * At most `max` frames, spread evenly; a dropped frame's time is added to the kept frame before it, so the loop
 * keeps its length. @param {number[]} durations @param {number} max @returns {{index: number, duration: number}[]}
 */
export function thinFrames(durations, max = EMOTE_MAX_FRAMES) {
    const n = durations.length;
    if (n <= max) return durations.map((duration, index) => ({ index, duration }));
    /** @type {{index: number, duration: number}[]} */
    const out = [];
    for (let i = 0; i < n; i++) {
        const slot = Math.floor((i * max) / n);
        if (out.length === slot) out.push({ index: i, duration: durations[i] });
        else out[out.length - 1].duration += durations[i];
    }
    return out;
}

/**
 * Frames thinned to at most `fps` a second: a frame is kept when it starts in a new 1000/fps ms slot, and takes the time
 * of the frames dropped after it, so the loop keeps its length. A source slower than `fps` keeps every frame.
 * @param {number[]} durations @param {number} fps @returns {{index: number, duration: number}[]}
 */
export function thinToRate(durations, fps) {
    const slot = 1000 / fps;
    /** @type {{index: number, duration: number}[]} */
    const out = [];
    let t = 0;
    let last = -1;
    durations.forEach((d, index) => {
        const s = Math.floor((t + 0.5) / slot);
        if (out.length === 0 || s !== last) {
            out.push({ index, duration: d });
            last = s;
        } else out[out.length - 1].duration += d;
        t += d;
    });
    return out;
}

/** A browser's reading of a frame's delay: under 11 ms counts as 100 ms. @param {number} ms */
const frameMs = (ms) => (ms < 11 ? 100 : Math.round(ms));

/**
 * Each image's delay in a GIF, in ms, from its Graphic Control Extension (none: 100 ms). null when it is not a
 * GIF this can walk. @param {Buffer} b @returns {number[] | null}
 */
export function gifDelays(b) {
    if (b.length < 13 || b.toString("latin1", 0, 3) !== "GIF") return null;
    let p = 13;
    if (b[10] & 0x80) p += 3 * (1 << ((b[10] & 0x07) + 1));
    /** @type {number[]} */
    const out = [];
    let pending = 0;
    const skipSub = () => {
        while (p < b.length) {
            const n = b[p++];
            if (n === 0) return true;
            p += n;
        }
        return false;
    };
    while (p < b.length) {
        const t = b[p++];
        if (t === 0x3b) break;
        if (t === 0x21) {
            const label = b[p++];
            if (label === 0xf9 && b[p] >= 4) pending = (b[p + 2] | (b[p + 3] << 8)) * 10;
            if (!skipSub()) return null;
        } else if (t === 0x2c) {
            if (p + 9 > b.length) return null;
            const flags = b[p + 8];
            p += 9;
            if (flags & 0x80) p += 3 * (1 << ((flags & 0x07) + 1));
            p++; // LZW minimum code size
            if (!skipSub()) return null;
            out.push(frameMs(pending));
            pending = 0;
        } else return null;
    }
    return out.length ? out : null;
}

/** @param {string} type @param {Buffer} data */
function pngChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
}

/** RGBA PNG. @param {number} w @param {number} h @param {Uint8Array} rgba */
export function encodePngRgba(w, h, rgba) {
    const row = w * 4 + 1;
    const raw = Buffer.alloc(row * h);
    for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * row + 1);
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0);
    ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8;
    ihdr[9] = 6;
    const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    return Buffer.concat([sig, pngChunk("IHDR", ihdr), pngChunk("IDAT", deflateSync(raw, { level: 1 })), pngChunk("IEND", Buffer.alloc(0))]);
}

/**
 * One child to completion; stdout kept when asked. Rejects error.seventv.fit_failed (timeout, exit, spawn).
 * @param {string} bin @param {string[]} args @param {{cwd?: string, timeoutMs: number, stdout?: boolean, label: string,
 *   onChild?: (c: import("node:child_process").ChildProcess | undefined) => void}} o
 * @returns {Promise<Buffer>}
 */
function run(bin, args, o) {
    return new Promise((resolve, reject) => {
        if (!(o.timeoutMs > 0)) return reject(new JobError("error.seventv.fit_failed", `${o.label} ran out of time`));
        let child;
        try {
            child = spawn(bin, args, { cwd: o.cwd, stdio: ["ignore", o.stdout ? "pipe" : "ignore", "pipe"] });
        } catch {
            return reject(new JobError("error.seventv.fit_failed", `${o.label} did not start`));
        }
        o.onChild?.(child);
        /** @type {Buffer[]} */
        const out = [];
        let tail = "";
        child.stdout?.on("data", (d) => out.push(d));
        child.stderr?.on("data", (d) => (tail = (tail + d).slice(-1000)));
        let timedOut = false;
        const timer = setTimeout(() => {
            timedOut = true;
            child.kill("SIGKILL");
        }, o.timeoutMs);
        child.on("error", () => {
            clearTimeout(timer);
            o.onChild?.(undefined);
            reject(new JobError("error.seventv.fit_failed", `${o.label} did not start`));
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            o.onChild?.(undefined);
            if (timedOut) return reject(new JobError("error.seventv.fit_failed", `${o.label} ran out of time`));
            if (code !== 0) {
                console.error(`[webp-helper] emote-fit ${o.label} exit ${code}: ${tail.trim()}`);
                return reject(new JobError("error.seventv.fit_failed", `${o.label} could not read the picture`));
            }
            resolve(Buffer.concat(out));
        });
    });
}

const PNG_RE = /^f\d{5}\.png$/;
const name = (/** @type {number} */ i) => `f${String(i + 1).padStart(5, "0")}.png`;

/**
 * The source as RGBA PNG frames f00001.png... in `framesDir`, thinned to EMOTE_MAX_FRAMES, with their durations.
 * @param {{ffmpeg: string, input: string, framesDir: string, deadline: number, onChild?: any}} o
 * @returns {Promise<{width: number, height: number, durations: number[]}>}
 */
async function sourceFrames(o) {
    const buf = await readFile(o.input);
    const anim = parseWebpAnim(buf);
    if (anim?.animated) {
        const W = anim.width;
        const H = anim.height;
        if (W > WEBP_MAX_CANVAS || H > WEBP_MAX_CANVAS || anim.frames.length > WEBP_MAX_FRAMES || anim.frames.length * W * H > WEBP_MAX_TOTAL_PIXELS) {
            throw new JobError("error.seventv.fit_failed", "this animated webp is too large to fit here");
        }
        const keep = thinFrames(anim.frames.map((f) => frameMs(f.duration)));
        const wanted = new Map(keep.map((k, n) => [k.index, n]));
        const canvas = new Uint8Array(W * H * 4);
        const still = path.join(o.framesDir, "frame.webp");
        /** @type {import("./webp-anim.js").WebpAnimFrame | null} */
        let prev = null;
        for (let i = 0; i < anim.frames.length; i++) {
            const f = anim.frames[i];
            if (f.w <= 0 || f.h <= 0 || f.x + f.w > W || f.y + f.h > H) throw new JobError("error.seventv.fit_failed", "a frame lies outside the canvas");
            if (prev?.dispose) {
                for (let y = prev.y; y < prev.y + prev.h; y++) canvas.fill(0, (y * W + prev.x) * 4, (y * W + prev.x + prev.w) * 4);
            }
            await writeFile(still, stillOfFrame(f));
            const px = await run(
                o.ffmpeg,
                ["-nostdin", "-v", "error", "-i", still, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
                { timeoutMs: o.deadline - Date.now(), stdout: true, label: "ffmpeg", onChild: o.onChild },
            );
            if (px.length < f.w * f.h * 4) throw new JobError("error.seventv.fit_failed", "a frame would not decode");
            drawFrame(canvas, W, f, px);
            const n = wanted.get(i);
            if (n !== undefined) await writeFile(path.join(o.framesDir, name(n)), encodePngRgba(W, H, canvas));
            prev = f;
        }
        await rm(still, { force: true });
        return { width: W, height: H, durations: keep.map((k) => k.duration) };
    }

    // gif, png, jpeg, still webp: ffmpeg composes; every decoded frame becomes one PNG
    await run(
        o.ffmpeg,
        ["-nostdin", "-v", "error", "-i", path.resolve(o.input), "-fps_mode", "passthrough", "-pix_fmt", "rgba", "-f", "image2", "f%05d.png"],
        { cwd: o.framesDir, timeoutMs: o.deadline - Date.now(), label: "ffmpeg", onChild: o.onChild },
    );
    const files = (await readdir(o.framesDir)).filter((f) => PNG_RE.test(f)).sort();
    if (files.length === 0) throw new JobError("error.seventv.fit_failed", "no picture in the file");
    const head = await readFile(path.join(o.framesDir, files[0]));
    const width = head.readUInt32BE(16);
    const height = head.readUInt32BE(20);
    let durations = files.length === 1 ? [100] : (gifDelays(buf) ?? []);
    if (durations.length !== files.length) durations = files.map(() => 100);
    const keep = thinFrames(durations);
    if (keep.length < files.length) {
        const kept = new Set(keep.map((k) => k.index));
        for (let i = 0; i < files.length; i++) if (!kept.has(i)) await rm(path.join(o.framesDir, files[i]));
        for (let n = 0; n < keep.length; n++) {
            const from = path.join(o.framesDir, files[keep[n].index]);
            const to = path.join(o.framesDir, name(n));
            if (from !== to) await rename(from, to);
        }
    }
    return { width, height, durations: keep.map((k) => k.duration) };
}

/** A video's frames are decoded at most this many px a side (a 4K clip would fill the disk with RGBA PNGs). */
const VIDEO_MAX_SIDE = 2048;
export const VIDEO_MIN_SECONDS = 0.2;
export const VIDEO_MAX_SECONDS = 10;
export const VIDEO_DEFAULT_FPS = 20;

/**
 * A moment of a video as RGBA PNG frames f00001.png... sampled at `fps`, each lasting 1000/fps ms (rounded so the sum is
 * exact). @param {{ffmpeg: string, input: string, framesDir: string, deadline: number, onChild?: any, start: number,
 *   seconds: number, fps: number, one?: boolean}} o
 * @returns {Promise<{width: number, height: number, durations: number[]}>}
 */
async function videoFrames(o) {
    const vf = `fps=${o.fps},scale=w='min(${VIDEO_MAX_SIDE},iw)':h='min(${VIDEO_MAX_SIDE},ih)':force_original_aspect_ratio=decrease:flags=lanczos`;
    await run(
        o.ffmpeg,
        ["-nostdin", "-v", "error", "-ss", String(o.start), "-i", path.resolve(o.input), "-t", String(o.seconds), "-an", "-sn",
         "-vf", vf, "-frames:v", String(o.one ? 1 : EMOTE_MAX_FRAMES), "-pix_fmt", "rgba", "-fps_mode", "passthrough", "-f", "image2", "f%05d.png"],
        { cwd: o.framesDir, timeoutMs: o.deadline - Date.now(), label: "ffmpeg", onChild: o.onChild },
    );
    const files = (await readdir(o.framesDir)).filter((f) => PNG_RE.test(f)).sort();
    if (files.length === 0) throw new JobError("error.seventv.fit_failed", "no picture at that moment of the video");
    const head = await readFile(path.join(o.framesDir, files[0]));
    const durations = files.map((_, i) => Math.round(((i + 1) * 1000) / o.fps) - Math.round((i * 1000) / o.fps));
    return { width: head.readUInt32BE(16), height: head.readUInt32BE(20), durations };
}

/** Keeps only `keep`'s frames of f00001... in `dir`, renumbered from f00001 (indices ascending). @param {string} dir @param {number} count @param {{index: number}[]} keep */
async function keepOnly(dir, count, keep) {
    const kept = new Set(keep.map((k) => k.index));
    for (let i = 0; i < count; i++) if (!kept.has(i)) await rm(path.join(dir, name(i)));
    for (let n = 0; n < keep.length; n++) {
        const from = path.join(dir, name(keep[n].index));
        const to = path.join(dir, name(n));
        if (from !== to) await rename(from, to);
    }
}

/** GIF palette sizes, then smaller pictures, for the automatic fit. */
export const GIF_STEPS = [
    { scale: 1, colors: 256 },
    { scale: 1, colors: 128 },
    { scale: 1, colors: 64 },
    { scale: 0.75, colors: 64 },
    { scale: 0.5, colors: 64 },
];
const PNG_STEPS = [{ scale: 1 }, { scale: 0.75 }, { scale: 0.5 }];

/**
 * The whole fit. Returns the file's bytes and what they hold. Throws a JobError: error.seventv.fit_shape (400, the
 * ratio), error.seventv.fit_failed (422, will not decode or ran out of time), error.seventv.fit_too_big (422, over
 * `maxBytes` even at the last step; with a fixed `quality` there is one encode and `overCap` is set instead).
 * @param {{ffmpeg: string, img2webp: string, input: string, dir: string, crop?: {x: number, y: number, w: number, h: number} | null,
 *   size?: number | null, maxBytes: number, timeoutMs?: number, onChild?: any,
 *   stretch?: {w: number, h: number} | null, format?: "webp" | "gif" | "png", quality?: number | null, fps?: number | null,
 *   video?: boolean, start?: number | null, end?: number | null, bounce?: boolean, frame?: number | null}} o
 * @returns {Promise<{bytes: Buffer, width: number, height: number, frames: number, quality: number, format: "webp" | "gif" | "png",
 *   durationMs: number, overCap: boolean}>}
 */
export async function fitEmote(o) {
    const deadline = Date.now() + (o.timeoutMs ?? EMOTE_FIT_TIMEOUT_MS);
    const format = o.format ?? "webp";
    const fixed = typeof o.quality === "number" ? o.quality : null;
    const src = path.join(o.dir, "src");
    await rm(src, { recursive: true, force: true });
    await mkdir(src, { recursive: true });
    /** @type {{width: number, height: number, durations: number[]}} */
    let source;
    if (o.video) {
        const start = o.start ?? 0;
        const end = o.end ?? start + 3;
        const fps = o.fps ?? VIDEO_DEFAULT_FPS;
        source =
            format === "png"
                ? await videoFrames({ ffmpeg: o.ffmpeg, input: o.input, framesDir: src, deadline, onChild: o.onChild, start: o.frame ?? start, seconds: 1 / fps, fps, one: true })
                : await videoFrames({ ffmpeg: o.ffmpeg, input: o.input, framesDir: src, deadline, onChild: o.onChild, start, seconds: end - start, fps });
    } else {
        source = await sourceFrames({ ffmpeg: o.ffmpeg, input: o.input, framesDir: src, deadline, onChild: o.onChild });
    }
    const { width, height } = source;
    let durations = source.durations;
    const plan = planFit({ width, height, crop: o.crop, size: o.size, stretch: o.stretch });

    /** the order the frames play in: indices into f00001.png... of the scaled directory */
    let seq;
    if (format === "png") {
        let idx = 0;
        if (!o.video && o.frame != null) {
            const t = o.frame * 1000;
            let end = 0;
            idx = durations.length - 1;
            for (let i = 0; i < durations.length; i++) {
                end += durations[i];
                if (end > t) {
                    idx = i;
                    break;
                }
            }
        }
        seq = [{ index: idx, duration: durations[idx] ?? 100 }];
    } else {
        if (o.fps && !o.video && durations.length > 1) {
            const keep = thinToRate(durations, o.fps);
            if (keep.length < durations.length) {
                await keepOnly(src, durations.length, keep);
                durations = keep.map((k) => k.duration);
            }
        }
        if (o.bounce && durations.length > 2) {
            const room = Math.floor((EMOTE_MAX_FRAMES + 2) / 2);
            if (durations.length > room) {
                const keep = thinFrames(durations, room);
                await keepOnly(src, durations.length, keep);
                durations = keep.map((k) => k.duration);
            }
        }
        seq = durations.map((duration, index) => ({ index, duration }));
        if (o.bounce) for (let i = durations.length - 2; i >= 1; i--) seq.push({ index: i, duration: durations[i] });
    }
    const durationMs = seq.reduce((t, f) => t + f.duration, 0);

    /** @type {{scale: number, q: number, colors?: number}[]} */
    let steps;
    if (format === "webp") steps = fixed !== null ? [{ scale: 1, q: fixed }] : FIT_STEPS;
    else if (format === "gif") {
        const colors = (/** @type {number} */ c) => ({ colors: c, q: Math.round(c / 2.56) });
        steps = fixed !== null ? [{ scale: 1, ...colors(Math.max(4, Math.min(256, Math.round((256 * fixed) / 100)))) }] : GIF_STEPS.map((g) => ({ scale: g.scale, ...colors(g.colors) }));
    } else steps = fixed !== null ? [{ scale: 1, q: fixed }] : PNG_STEPS.map((p) => ({ ...p, q: 100 }));

    /** @type {Map<number, {dir: string, width: number, height: number}>} */
    const scaled = new Map();
    const ext = format;
    for (const step of steps) {
        let s = scaled.get(step.scale);
        if (!s) {
            const w = Math.max(1, Math.round(plan.width * step.scale));
            const h = Math.max(1, Math.round(plan.height * step.scale));
            const dir = path.join(o.dir, `s${step.scale}`);
            await mkdir(dir, { recursive: true });
            const c = plan.crop;
            const vf = `crop=${c.w}:${c.h}:${c.x}:${c.y},scale=${w}:${h}:flags=lanczos`;
            const args =
                format === "png"
                    ? ["-nostdin", "-v", "error", "-i", path.join(src, name(seq[0].index)), "-vf", vf, "-frames:v", "1", "-pix_fmt", "rgba", "-f", "image2", "f00001.png"]
                    : ["-nostdin", "-v", "error", "-framerate", "25", "-i", path.join(src, "f%05d.png"), "-vf", vf, "-fps_mode", "passthrough", "-pix_fmt", "rgba", "-f", "image2", "f%05d.png"];
            await run(o.ffmpeg, args, { cwd: dir, timeoutMs: deadline - Date.now(), label: "ffmpeg scale", onChild: o.onChild });
            s = { dir, width: w, height: h };
            scaled.set(step.scale, s);
        }
        const out = path.join(o.dir, `out.${ext}`);
        if (format === "webp") {
            const args = ["-loop", "0", "-lossy", "-q", String(step.q), "-m", "4"];
            seq.forEach((f) => args.push("-d", String(f.duration), name(f.index)));
            args.push("-o", out);
            await run(o.img2webp, args, { cwd: s.dir, timeoutMs: deadline - Date.now(), label: "img2webp", onChild: o.onChild });
        } else if (format === "gif") {
            const list = path.join(s.dir, "gif.txt");
            // image2 inside concat counts in 1/25 s unless told a finer rate; the muxer takes the last delay from final_delay
            const lines = ["ffconcat version 1.0", ...seq.map((f) => `file '${name(f.index)}'\noption framerate 1000\nduration ${(f.duration / 1000).toFixed(3)}`)];
            await writeFile(list, lines.join("\n") + "\n");
            await run(
                o.ffmpeg,
                ["-nostdin", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list,
                 "-filter_complex", `[0:v]split[a][b];[a]palettegen=max_colors=${step.colors}:reserve_transparent=1[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:alpha_threshold=128`,
                 "-fps_mode", "vfr", "-final_delay", String(Math.max(1, Math.round(seq[seq.length - 1].duration / 10))), "-loop", "0", "-f", "gif", out],
                { timeoutMs: deadline - Date.now(), label: "ffmpeg gif", onChild: o.onChild },
            );
        } else {
            await copyFile(path.join(s.dir, "f00001.png"), out);
        }
        const size = (await stat(out)).size;
        if (size <= o.maxBytes || fixed !== null) {
            return {
                bytes: await readFile(out),
                width: s.width,
                height: s.height,
                frames: format === "png" ? 1 : seq.length,
                quality: step.q,
                format,
                durationMs,
                overCap: size > o.maxBytes,
            };
        }
    }
    throw new JobError("error.seventv.fit_too_big", `still over ${Math.floor(o.maxBytes / 1024)} KiB at half size: pick a smaller size or a shorter crop`);
}
