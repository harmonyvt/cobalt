// Animated WebP for the editor (APP-API-CONTRACT.md section 39): 7TV emotes are saved as (often animated) webps, and the
// ffmpeg in the render image (Alpine's, 6.x) reads still webps but not animated ones. So an animated webp is taken apart
// here: each ANMF frame's bitstream is wrapped as a still webp, ffmpeg decodes it to RGBA, the frames are composed on the
// canvas the way the WebP container spec says (offsets, alpha blending, dispose to transparent), and the composed frames
// are written as ONE animated PNG (APNG: full alpha, each frame's own delay), which ffmpeg 6 reads natively. compile.js
// loops it like a GIF. (An ffconcat list of PNGs was tried first: the concat demuxer rounds image timestamps to its 25 fps
// default and gives every frame the same duration.) Plain Node ESM, no dependencies (node:zlib for the PNG).

import { spawn } from "node:child_process";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { crc32, deflateSync } from "node:zlib";

/** The most frames and pixels an animated webp may have (a decompression bomb is refused, not rendered). */
export const WEBP_MAX_FRAMES = 2000;
export const WEBP_MAX_CANVAS = 4096;
export const WEBP_MAX_TOTAL_PIXELS = 400e6;

/**
 * @typedef {{x: number, y: number, w: number, h: number, duration: number, blend: boolean, dispose: boolean,
 *            chunks: Buffer}} WebpFrame  `chunks`: the frame's ALPH/VP8/VP8L chunks as they sit in the file
 * @typedef {{animated: false, width: number, height: number} | {animated: true, width: number, height: number,
 *            frames: WebpFrame[]}} WebpInfo
 */

/** True for RIFF....WEBP. @param {Uint8Array} b */
export function isWebp(b) {
    return b.length >= 12 && String.fromCharCode(...b.subarray(0, 4)) === "RIFF" && String.fromCharCode(...b.subarray(8, 12)) === "WEBP";
}

const u24 = (/** @type {Buffer} */ b, /** @type {number} */ o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

/**
 * Reads the container: still or animated, the canvas size and, when animated, every frame. null when it is not a webp
 * this can read (then it is unsupported).
 * @param {Buffer} buf @returns {WebpInfo | null}
 */
export function parseWebp(buf) {
    if (!isWebp(buf)) return null;
    const end = Math.min(buf.length, 8 + buf.readUInt32LE(4));
    let pos = 12;
    let width = 0, height = 0, animated = false;
    /** @type {WebpFrame[]} */
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
 * One frame as a still webp file ffmpeg can decode: a lossless frame (VP8L) stands alone; a lossy one with alpha
 * (ALPH + VP8) needs a VP8X header with the alpha flag. @param {WebpFrame} f @returns {Buffer}
 */
export function stillOfFrame(f) {
    const hasAlpha = f.chunks.length >= 4 && f.chunks.toString("latin1", 0, 4) === "ALPH";
    /** @type {Buffer[]} */
    const parts = [];
    if (hasAlpha) {
        const x = Buffer.alloc(18);
        x.write("VP8X", 0, "latin1");
        x.writeUInt32LE(10, 4);
        x[8] = 0x10; // alpha
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

/** One PNG chunk: length, type, data, CRC. @param {string} type @param {Buffer} data */
function pngChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
}
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** zlib stream of RGBA rows, each with filter byte 0. @param {number} w @param {number} h @param {Uint8Array} rgba */
function pngData(w, h, rgba) {
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
    return deflateSync(raw, { level: 3 });
}

/** @param {number} w @param {number} h */
function ihdr(w, h) {
    const b = Buffer.alloc(13);
    b.writeUInt32BE(w, 0);
    b.writeUInt32BE(h, 4);
    b[8] = 8; // bit depth
    b[9] = 6; // RGBA
    return pngChunk("IHDR", b);
}

/** RGBA PNG (8-bit, no filter) of a w x h buffer. @param {number} w @param {number} h @param {Uint8Array} rgba @returns {Buffer} */
export function encodePng(w, h, rgba) {
    return Buffer.concat([PNG_SIG, ihdr(w, h), pngChunk("IDAT", pngData(w, h, rgba)), pngChunk("IEND", Buffer.alloc(0))]);
}

/**
 * Builds an APNG from full-canvas frames, each with its delay in ms (no disposal, no blending: every frame is the whole
 * composed picture). Returns the file's parts so they can be streamed to disk. @param {number} w @param {number} h
 * @param {number} count
 */
export function apngWriter(w, h, count) {
    let seq = 0;
    const actl = Buffer.alloc(8);
    actl.writeUInt32BE(count, 0);
    actl.writeUInt32BE(0, 4); // loop forever
    return {
        head: Buffer.concat([PNG_SIG, ihdr(w, h), pngChunk("acTL", actl)]),
        /** @param {Uint8Array} rgba @param {number} ms @param {boolean} first */
        frame(rgba, ms, first) {
            const fc = Buffer.alloc(26);
            fc.writeUInt32BE(seq++, 0);
            fc.writeUInt32BE(w, 4);
            fc.writeUInt32BE(h, 8);
            fc.writeUInt32BE(0, 12);
            fc.writeUInt32BE(0, 16);
            fc.writeUInt16BE(ms, 20);
            fc.writeUInt16BE(1000, 22);
            fc[24] = 0; // dispose none
            fc[25] = 0; // blend source
            const data = pngData(w, h, rgba);
            if (first) return Buffer.concat([pngChunk("fcTL", fc), pngChunk("IDAT", data)]);
            const sn = Buffer.alloc(4);
            sn.writeUInt32BE(seq++);
            return Buffer.concat([pngChunk("fcTL", fc), pngChunk("fdAT", Buffer.concat([sn, data]))]);
        },
        tail: pngChunk("IEND", Buffer.alloc(0)),
    };
}

/** ffmpeg decodes one still webp file to w x h RGBA. @param {string} ffmpeg @param {string} file @param {number} w @param {number} h @returns {Promise<Buffer | null>} */
function decodeRgba(ffmpeg, file, w, h) {
    return new Promise((resolve) => {
        /** @type {Buffer[]} */
        const out = [];
        let n = 0;
        let child;
        try {
            child = spawn(ffmpeg, ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", file, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], { stdio: ["ignore", "pipe", "ignore"] });
        } catch {
            return resolve(null);
        }
        child.stdout.on("data", (d) => {
            n += d.length;
            if (n <= w * h * 4) out.push(d);
        });
        const timer = setTimeout(() => child.kill("SIGKILL"), 30000);
        child.on("error", () => {
            clearTimeout(timer);
            resolve(null);
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            resolve(code === 0 && n === w * h * 4 ? Buffer.concat(out) : null);
        });
    });
}

/**
 * Composes an animated webp's frames into `anim.png` (APNG) in `dir`. Returns its path, the canvas size and the loop's length
 * in seconds, or null when a frame will not decode or the file is over the limits. A frame duration under 11 ms counts as
 * 100 ms (what browsers do for tiny durations); delays are capped at 65 s (the APNG field is 16 bits).
 * @param {{ffmpeg: string, info: Extract<WebpInfo, {animated: true}>, dir: string}} o
 * @returns {Promise<{file: string, width: number, height: number, seconds: number} | null>}
 */
export async function explodeWebp(o) {
    const { info, dir } = o;
    const W = info.width, H = info.height;
    if (W > WEBP_MAX_CANVAS || H > WEBP_MAX_CANVAS) return null;
    if (info.frames.length > WEBP_MAX_FRAMES || info.frames.length * W * H > WEBP_MAX_TOTAL_PIXELS) return null;
    await mkdir(dir, { recursive: true });
    const file = path.join(dir, "anim.png");
    const apng = apngWriter(W, H, info.frames.length);
    const fh = await open(file, "w");
    try {
        await fh.write(apng.head);
        const canvas = new Uint8Array(W * H * 4); // transparent
        let seconds = 0;
        /** @type {WebpFrame | null} */
        let prev = null;
        for (let i = 0; i < info.frames.length; i++) {
            const f = info.frames[i];
            if (f.x + f.w > W || f.y + f.h > H) return null;
            if (prev && prev.dispose) clearRect(canvas, W, prev);
            const still = path.join(dir, "frame.webp");
            await writeFile(still, stillOfFrame(f));
            const px = await decodeRgba(o.ffmpeg, still, f.w, f.h);
            if (!px) return null;
            drawFrame(canvas, W, f, px);
            const ms = Math.min(65000, f.duration > 10 ? f.duration : 100);
            await fh.write(apng.frame(canvas, ms, i === 0));
            seconds += ms / 1000;
            prev = f;
        }
        await fh.write(apng.tail);
        return { file, height: H, seconds, width: W };
    } finally {
        await fh.close();
    }
}

/** @param {Uint8Array} c @param {number} W @param {{x: number, y: number, w: number, h: number}} r */
function clearRect(c, W, r) {
    for (let y = r.y; y < r.y + r.h; y++) c.fill(0, (y * W + r.x) * 4, (y * W + r.x + r.w) * 4);
}

/** Draws a frame's RGBA at its offset: alpha-blended ("over") or replacing, as the frame says. @param {Uint8Array} c @param {number} W @param {WebpFrame} f @param {Uint8Array} px */
export function drawFrame(c, W, f, px) {
    for (let y = 0; y < f.h; y++) {
        for (let x = 0; x < f.w; x++) {
            const s = (y * f.w + x) * 4, d = ((f.y + y) * W + f.x + x) * 4;
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

/** Reads a file's webp container (null when it is not one). @param {string} file @returns {Promise<WebpInfo | null>} */
export async function readWebp(file) {
    try {
        return parseWebp(await readFile(file));
    } catch {
        return null;
    }
}
