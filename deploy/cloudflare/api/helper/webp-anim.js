// Animated WebP for the safety clip (APP-API-CONTRACT.md section 51.2).
//
// The container's ffmpeg (ffmpeg-static b6.1.1, ffmpeg 7.0.2) decodes a still WebP and skips an
// animated one's ANIM and ANMF chunks ("image data not found"). POST /safety used to hand that
// file to the same decoder, so prep failed. The editor already takes an animated WebP apart
// (editor/helper/webp.js): each frame's bitstream is a still WebP ffmpeg can decode, the frames
// are composed the way the container spec says, and Clef gets JPEGs of that canvas. A file that
// still will not decode fails closed (error.safety.failed). No new dependency.

import { spawn } from "node:child_process";
import { open, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { crc32, deflateSync } from "node:zlib";
import { ABOUT_FRAME_SIDE, JobError, MAX_POSTER_BYTES, buildPosterArgs } from "./lib.js";

/** How many composed frames one Clef request can hold (about-store SAFETY_MAX_STILLS). */
export const SAFETY_WEBP_STILLS = 4;
/** Bytes of an animated WebP this path will read. Larger than that, and animated, fails closed. */
export const WEBP_MAX_BYTES = 32 * 1024 * 1024;
export const WEBP_MAX_FRAMES = 2000;
export const WEBP_MAX_CANVAS = 2048;
export const WEBP_MAX_TOTAL_PIXELS = 500e6;

/**
 * @typedef {{x: number, y: number, w: number, h: number, duration: number, blend: boolean, dispose: boolean,
 *            chunks: Buffer}} WebpAnimFrame
 * @typedef {{animated: false, width: number, height: number}
 *         | {animated: true, width: number, height: number, frames: WebpAnimFrame[]}} WebpAnimInfo
 */

/** @param {Uint8Array} b */
export function isWebp(b) {
    return b.length >= 12 && String.fromCharCode(...b.subarray(0, 4)) === "RIFF" && String.fromCharCode(...b.subarray(8, 12)) === "WEBP";
}

const u24 = (/** @type {Buffer} */ b, /** @type {number} */ o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

/**
 * Still or animated, the canvas, and every frame when animated. null when it is not a WebP this can read.
 * @param {Buffer} buf @returns {WebpAnimInfo | null}
 */
export function parseWebpAnim(buf) {
    if (!isWebp(buf)) return null;
    const end = Math.min(buf.length, 8 + buf.readUInt32LE(4));
    let pos = 12;
    let width = 0;
    let height = 0;
    let animated = false;
    /** @type {WebpAnimFrame[]} */
    const frames = [];
    while (pos + 8 <= end) {
        const id = buf.toString("latin1", pos, pos + 4);
        const size = buf.readUInt32LE(pos + 4);
        const body = pos + 8;
        if (body + size > end) return null;
        if (id === "VP8X" && size >= 10) {
            animated = (buf[body] & 0x02) !== 0;
            width = u24(buf, body + 4) + 1;
            height = u24(buf, body + 7) + 1;
        } else if (id === "ANMF" && size >= 16) {
            frames.push({
                x: 2 * u24(buf, body),
                y: 2 * u24(buf, body + 3),
                w: u24(buf, body + 6) + 1,
                h: u24(buf, body + 9) + 1,
                duration: u24(buf, body + 12),
                blend: (buf[body + 15] & 0x02) === 0,
                dispose: (buf[body + 15] & 0x01) !== 0,
                chunks: buf.subarray(body + 16, body + size),
            });
        } else if (id === "VP8 " && !width && size >= 10) {
            width = buf.readUInt16LE(body + 6) & 0x3fff;
            height = buf.readUInt16LE(body + 8) & 0x3fff;
        } else if (id === "VP8L" && !width && size >= 5) {
            const bits = buf.readUInt32LE(body + 1);
            width = (bits & 0x3fff) + 1;
            height = ((bits >> 14) & 0x3fff) + 1;
        }
        pos = body + size + (size & 1);
    }
    if (!width || !height) return null;
    if (!animated) return { animated: false, height, width };
    if (frames.length === 0) return null;
    return { animated: true, frames, height, width };
}

/**
 * Indexes of the frames Clef should see: every frame when there are few, otherwise spread across the
 * loop (first and last included). A duration under 11 ms counts as 100 ms, the same as a browser.
 * @param {{duration: number}[]} frames @param {number} max
 * @returns {number[]}
 */
export function sampleStillIndexes(frames, max) {
    const n = frames.length;
    if (n === 0 || max <= 0) return [];
    if (n === 1 || max === 1) return [0];
    if (n <= max) return frames.map((_, i) => i);
    const dur = frames.map((f) => (f.duration > 10 ? f.duration : 100));
    /** @type {number[]} */
    const start = [];
    let total = 0;
    for (const d of dur) {
        start.push(total);
        total += d;
    }
    /** @type {number[]} */
    const picked = [];
    for (let i = 0; i < max; i++) {
        const at = (total * i) / (max - 1);
        let idx = 0;
        for (let k = 0; k < n; k++) if (start[k] <= at) idx = k;
        if (picked[picked.length - 1] !== idx) picked.push(idx);
    }
    return picked;
}

/**
 * One frame as a still WebP ffmpeg can decode. A lossless frame stands alone; a lossy one with alpha
 * needs a VP8X header. @param {WebpAnimFrame} f @returns {Buffer}
 */
export function stillOfFrame(f) {
    const hasAlpha = f.chunks.length >= 4 && f.chunks.toString("latin1", 0, 4) === "ALPH";
    /** @type {Buffer[]} */
    const parts = [];
    if (hasAlpha) {
        const x = Buffer.alloc(18);
        x.write("VP8X", 0, "latin1");
        x.writeUInt32LE(10, 4);
        x[8] = 0x10;
        x.writeUIntLE(f.w - 1, 12, 3);
        x.writeUIntLE(f.h - 1, 15, 3);
        parts.push(x);
    }
    parts.push(f.chunks);
    const payload = Buffer.concat(parts);
    const head = Buffer.alloc(12);
    head.write("RIFF", 0, "latin1");
    head.writeUInt32LE(4 + payload.length, 4);
    head.write("WEBP", 8, "latin1");
    return Buffer.concat([head, payload]);
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

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** RGB PNG (alpha already flattened). @param {number} w @param {number} h @param {Buffer} rgb */
function encodePngRgb(w, h, rgb) {
    const raw = Buffer.alloc((w * 3 + 1) * h);
    for (let y = 0; y < h; y++) rgb.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3);
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0);
    ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    const data = deflateSync(raw, { level: 1 });
    return Buffer.concat([PNG_SIG, pngChunk("IHDR", ihdr), pngChunk("IDAT", data), pngChunk("IEND", Buffer.alloc(0))]);
}

/** @param {Uint8Array} c @param {number} W @param {{x: number, y: number, w: number, h: number}} r */
function clearRect(c, W, r) {
    for (let y = r.y; y < r.y + r.h; y++) c.fill(0, (y * W + r.x) * 4, (y * W + r.x + r.w) * 4);
}

/** Alpha-blended ("over") or replacing, as the frame says. @param {Uint8Array} c @param {number} W @param {WebpAnimFrame} f @param {Uint8Array} px */
export function drawFrame(c, W, f, px) {
    for (let y = 0; y < f.h; y++) {
        for (let x = 0; x < f.w; x++) {
            const s = (y * f.w + x) * 4;
            const d = ((f.y + y) * W + f.x + x) * 4;
            const sa = px[s + 3];
            if (!f.blend || sa === 255) {
                c[d] = px[s];
                c[d + 1] = px[s + 1];
                c[d + 2] = px[s + 2];
                c[d + 3] = sa;
                continue;
            }
            if (sa === 0) continue;
            const da = c[d + 3];
            const oa = sa + (da * (255 - sa)) / 255;
            for (let k = 0; k < 3; k++) c[d + k] = Math.round((px[s + k] * sa + (c[d + k] * da * (255 - sa)) / 255) / oa);
            c[d + 3] = Math.round(oa);
        }
    }
}

/** Opaque RGB on black, which is what a JPEG can hold. @param {Uint8Array} rgba @param {number} w @param {number} h */
function flattenBlack(rgba, w, h) {
    const rgb = Buffer.alloc(w * h * 3);
    for (let i = 0, p = 0; i < w * h; i++) {
        const a = rgba[i * 4 + 3] / 255;
        rgb[p++] = Math.round(rgba[i * 4] * a);
        rgb[p++] = Math.round(rgba[i * 4 + 1] * a);
        rgb[p++] = Math.round(rgba[i * 4 + 2] * a);
    }
    return rgb;
}

/**
 * ffmpeg decodes one still WebP to w x h RGBA. @param {string} ffmpeg @param {string} file
 * @param {number} w @param {number} h @param {number} timeoutMs
 * @returns {Promise<Buffer | null>}
 */
function decodeRgba(ffmpeg, file, w, h, timeoutMs) {
    return new Promise((resolve) => {
        if (!(timeoutMs > 0) || w <= 0 || h <= 0) return resolve(null);
        const need = w * h * 4;
        /** @type {Buffer[]} */
        const out = [];
        let n = 0;
        let child;
        try {
            child = spawn(
                ffmpeg,
                ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", file, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
                { stdio: ["ignore", "pipe", "ignore"] },
            );
        } catch {
            return resolve(null);
        }
        child.stdout.on("data", (d) => {
            if (n < need) {
                out.push(d);
                n += d.length;
            }
        });
        const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
        const done = (/** @type {Buffer | null} */ buf) => {
            clearTimeout(timer);
            resolve(buf);
        };
        child.on("error", () => done(null));
        child.on("close", (code) => {
            if (code !== 0 || n < need) return done(null);
            const buf = Buffer.concat(out);
            done(buf.length >= need ? buf.subarray(0, need) : null);
        });
    });
}

/** @param {string} ffmpeg @param {string[]} args @param {number} timeoutMs */
function runFfmpeg(ffmpeg, args, timeoutMs) {
    return new Promise((resolve) => {
        if (!(timeoutMs > 0)) return resolve(false);
        let child;
        try {
            child = spawn(ffmpeg, args, { stdio: "ignore" });
        } catch {
            return resolve(false);
        }
        const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
        child.on("error", () => {
            clearTimeout(timer);
            resolve(false);
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            resolve(code === 0);
        });
    });
}

/**
 * Composed JPEG stills of an animated WebP, or null when `input` is not one. Throws error.safety.failed
 * when it is animated and a frame will not decode, the file is over the limits, or the deadline passes.
 * A still WebP returns null so the caller can use the ordinary poster path.
 * @param {{ffmpeg: string, input: string, dir: string, deadline: number, side?: number, maxStills?: number}} o
 * @returns {Promise<Buffer[] | null>}
 */
export async function safetyStillsFromAnimatedWebp(o) {
    const size = (await stat(o.input).catch(() => null))?.size ?? 0;
    if (size < 12) return null;
    const fh = await open(o.input, "r");
    /** @type {Buffer} */
    let buf;
    try {
        const head = Buffer.alloc(12);
        await fh.read(head, 0, 12, 0);
        if (!isWebp(head)) return null;
        if (size > WEBP_MAX_BYTES) {
            const peek = Buffer.alloc(Math.min(size, 64 * 1024));
            await fh.read(peek, 0, peek.length, 0);
            // The animation flag sits in the VP8X chunk at the start. A still WebP this large
            // stays on the poster path; an animated one is not composed from a prefix.
            if (peekIncludesAnimFlag(peek)) throw new JobError("error.safety.failed");
            return null;
        }
        buf = Buffer.alloc(size);
        await fh.read(buf, 0, size, 0);
    } finally {
        await fh.close();
    }
    const info = parseWebpAnim(buf);
    if (!info?.animated) return null;
    if (info.width > WEBP_MAX_CANVAS || info.height > WEBP_MAX_CANVAS) throw new JobError("error.safety.failed");
    if (info.frames.length > WEBP_MAX_FRAMES || info.frames.length * info.width * info.height > WEBP_MAX_TOTAL_PIXELS) {
        throw new JobError("error.safety.failed");
    }
    const want = new Set(sampleStillIndexes(info.frames, o.maxStills ?? SAFETY_WEBP_STILLS));
    const W = info.width;
    const H = info.height;
    const canvas = new Uint8Array(W * H * 4);
    /** @type {Map<number, Buffer>} */
    const shots = new Map();
    /** @type {WebpAnimFrame | null} */
    let prev = null;
    const stillPath = path.join(o.dir, "frame.webp");
    for (let i = 0; i < info.frames.length; i++) {
        const f = info.frames[i];
        if (f.w <= 0 || f.h <= 0 || f.x < 0 || f.y < 0 || f.x + f.w > W || f.y + f.h > H) throw new JobError("error.safety.failed");
        if (prev && prev.dispose) clearRect(canvas, W, prev);
        await writeFile(stillPath, stillOfFrame(f));
        const left = o.deadline - Date.now();
        const px = await decodeRgba(o.ffmpeg, stillPath, f.w, f.h, left);
        if (!px) throw new JobError("error.safety.failed");
        drawFrame(canvas, W, f, px);
        if (want.has(i)) shots.set(i, Buffer.from(canvas));
        prev = f;
    }
    /** @type {Buffer[]} */
    const jpegs = [];
    const side = o.side ?? ABOUT_FRAME_SIDE;
    for (const i of [...want].sort((a, b) => a - b)) {
        const rgba = shots.get(i);
        if (!rgba) throw new JobError("error.safety.failed");
        const png = path.join(o.dir, `comp-${i}.png`);
        const jpg = path.join(o.dir, `comp-${i}.jpg`);
        await writeFile(png, encodePngRgb(W, H, flattenBlack(rgba, W, H)));
        const ok = await runFfmpeg(o.ffmpeg, buildPosterArgs({ input: png, output: jpg, side }), o.deadline - Date.now());
        const bytes = ok ? await readFile(jpg).catch(() => null) : null;
        if (!bytes || bytes.length < 3 || bytes.length > MAX_POSTER_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
            throw new JobError("error.safety.failed");
        }
        jpegs.push(bytes);
    }
    if (jpegs.length === 0) throw new JobError("error.safety.failed");
    return jpegs;
}

/** VP8X animation flag in a prefix, so a huge animated file is not sent to the still decoder. @param {Buffer} buf */
function peekIncludesAnimFlag(buf) {
    if (!isWebp(buf)) return false;
    const end = Math.min(buf.length, 8 + buf.readUInt32LE(4));
    let pos = 12;
    while (pos + 8 <= end) {
        const id = buf.toString("latin1", pos, pos + 4);
        const size = buf.readUInt32LE(pos + 4);
        const body = pos + 8;
        if (body > buf.length) return false;
        if (id === "VP8X" && body + 1 <= buf.length && (buf[body] & 0x02) !== 0) return true;
        if (id === "ANIM" || id === "ANMF") return true;
        if (body + size > buf.length) return false;
        pos = body + size + (size & 1);
    }
    return false;
}
