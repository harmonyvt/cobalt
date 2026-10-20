// What the render helper learns about a source before compiling (APP-API-CONTRACT.md 31.9, "Probe at start"): the kind
// checked by the BYTES, then `ffmpeg -hide_banner -i` (as api/helper/lib.js's parseVideoInfo does) for the display size,
// duration, audio and colour transfer. Plain Node ESM, no dependencies.

import { spawn } from "node:child_process";
import { open } from "node:fs/promises";

/** The kind of a file from its first bytes, never from a name: "gif", "jpeg", "png", "mp4" (ISO-BMFF with a video brand), else null.
 * @param {Uint8Array | Buffer} head at least 12 bytes where there are that many
 * @returns {"gif" | "jpeg" | "png" | "mp4" | null} */
export function sniffKind(head) {
    const n = head.length;
    const ascii = (/** @type {number} */ a, /** @type {number} */ b) => String.fromCharCode(...head.subarray(a, Math.min(b, n)));
    if (n >= 6 && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a")) return "gif";
    if (n >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return "jpeg";
    if (n >= 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => head[i] === v)) return "png";
    // QuickTime files from older apps have no ftyp: they open with wide / mdat / moov / free / skip / pnot
    if (n >= 8 && ascii(4, 8) !== "ftyp" && /^(wide|mdat|moov|free|skip|pnot)$/.test(ascii(4, 8))) {
        const size = Buffer.from(head.buffer, head.byteOffset, head.length).readUInt32BE(0);
        if (size === 0 || size === 1 || size >= 8) return "mp4";
    }
    if (n >= 12 && ascii(4, 8) === "ftyp") {
        const brand = ascii(8, 12);
        // stills (heic, avif) and audio-only (M4A) brands are not video
        if (/^(heic|heix|hevc|hevx|mif1|msf1|avif|avis|M4A |M4B |M4P |crx )/.test(brand)) return null;
        return "mp4";
    }
    return null;
}

/** EXIF orientation (1..8) of a JPEG from its first bytes (an APP1 "Exif" segment); 1 when absent or unreadable.
 * @param {Uint8Array | Buffer} bytes @returns {number} */
export function exifOrientation(bytes) {
    const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length);
    try {
        if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return 1;
        let pos = 2;
        while (pos + 4 <= b.length) {
            if (b[pos] !== 0xff) return 1;
            const marker = b[pos + 1];
            if (marker === 0xff) {
                pos++;
                continue;
            }
            if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
                pos += 2;
                continue;
            }
            if (marker === 0xda || marker === 0xd9) return 1;
            const len = b.readUInt16BE(pos + 2);
            if (len < 2) return 1;
            if (marker === 0xe1 && b.toString("latin1", pos + 4, pos + 10) === "Exif\0\0") {
                const t = pos + 10; // TIFF header
                const le = b.toString("latin1", t, t + 2) === "II";
                const u16 = (/** @type {number} */ o) => (le ? b.readUInt16LE(o) : b.readUInt16BE(o));
                const u32 = (/** @type {number} */ o) => (le ? b.readUInt32LE(o) : b.readUInt32BE(o));
                if (u16(t + 2) !== 42) return 1;
                const ifd = t + u32(t + 4);
                const count = u16(ifd);
                for (let i = 0; i < count; i++) {
                    const e = ifd + 2 + i * 12;
                    if (u16(e) === 0x0112) {
                        const v = u16(e + 8);
                        return v >= 1 && v <= 8 ? v : 1;
                    }
                }
                return 1;
            }
            pos += 2 + len;
        }
    } catch {
        return 1;
    }
    return 1;
}

/** ffmpeg's `transpose` / flip filters that undo an EXIF orientation (empty for 1). @param {number} o @returns {string[]} */
export function orientationFilters(o) {
    switch (o) {
        case 2: return ["hflip"];
        case 3: return ["hflip", "vflip"];
        case 4: return ["vflip"];
        case 5: return ["transpose=0"];
        case 6: return ["transpose=1"];
        case 7: return ["transpose=3"];
        case 8: return ["transpose=2"];
        default: return [];
    }
}

/**
 * Reads what `ffmpeg -hide_banner -i <file>` prints. Width and height are the first real video stream's, rotation applied
 * (but NOT the pixel aspect: see `sar`). Null fields where absent.
 * @param {string} stderr
 * @returns {{duration: number | null, startTime: number | null, hasVideo: boolean, width: number | null, height: number | null,
 *            rotation: number, sar: [number, number], hasAudio: boolean, channels: number | null, transfer: string | null,
 *            hdr: boolean, videoCodec: string | null}}
 */
export function parseInfo(stderr) {
    const dm = /Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)/.exec(stderr);
    const duration = dm ? Number(dm[1]) * 3600 + Number(dm[2]) * 60 + Number(dm[3]) : null;
    const sm = /start:\s*(-?\d+(?:\.\d+)?)/.exec(stderr);
    const lines = stderr.split("\n");
    let width = null, height = null, rotation = 0, transfer = null, videoCodec = null, hasVideo = false;
    /** @type {[number, number]} */
    let sar = [1, 1];
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (!/Stream #\d+:\d+.*Video:/.test(line) || /attached pic/.test(line)) continue;
        const after = line.slice(line.indexOf("Video:"));
        const m = /,\s*(\d{2,5})x(\d{2,5})\b/.exec(after);
        if (!m) continue;
        hasVideo = true;
        width = Number(m[1]);
        height = Number(m[2]);
        videoCodec = /Video:\s*([A-Za-z0-9_]+)/.exec(after)?.[1] ?? null;
        const sr = /\[SAR (\d+):(\d+)/.exec(after);
        if (sr && Number(sr[1]) > 0 && Number(sr[2]) > 0) sar = [Number(sr[1]), Number(sr[2])];
        // yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67, progressive)
        const paren = /\(([^()]*\/[^()]*)\)/.exec(after);
        if (paren) transfer = paren[1].split(",").map((x) => x.trim()).find((x) => x.includes("/"))?.split("/")[2] ?? null;
        if (!transfer) transfer = /(arib-std-b67|smpte2084)/.exec(after)?.[1] ?? null;
        for (let j = i + 1; j < lines.length && !/Stream #\d+:\d+/.test(lines[j]); j++) {
            const r = /rotation of (-?\d+(?:\.\d+)?) degrees/.exec(lines[j]);
            if (r) {
                rotation = ((Math.round(Number(r[1])) % 360) + 360) % 360;
                break;
            }
        }
        break;
    }
    if (width !== null && height !== null && (rotation === 90 || rotation === 270)) {
        [width, height] = [height, width];
        sar = [sar[1], sar[0]]; // the pixel's shape turns with the picture
    }
    const au = lines.find((l) => /Stream #\d+:\d+.*Audio:/.test(l));
    let channels = null;
    if (au) {
        const a = au.slice(au.indexOf("Audio:"));
        if (/\bmono\b/.test(a)) channels = 1;
        else if (/\bstereo\b/.test(a)) channels = 2;
        else {
            const c = /(\d+)\.(\d)(?:\([a-z]+\))?(?:,|\s|$)/.exec(a.split(",").slice(2, 3).join(","));
            const n = /,\s*(\d+) channels/.exec(a);
            channels = n ? Number(n[1]) : c ? Number(c[1]) + Number(c[2]) : null;
        }
    }
    return {
        channels,
        duration: duration !== null && Number.isFinite(duration) && duration > 0 ? duration : null,
        hasAudio: !!au,
        hasVideo,
        hdr: transfer === "arib-std-b67" || transfer === "smpte2084",
        height,
        rotation,
        sar,
        startTime: sm ? Number(sm[1]) : null,
        transfer,
        videoCodec,
        width,
    };
}

/**
 * Display size with square pixels: a non-square source is scaled to square pixels keeping its (rotated) width and
 * changing the height (31.5 step 1). `squareFrom` is the decoded size to scale from when that is needed, else null.
 * @param {number} w rotated width @param {number} h rotated height @param {[number, number]} sar
 * @returns {{width: number, height: number, squareFrom: {w: number, h: number} | null}}
 */
export function displaySize(w, h, sar) {
    if (sar[0] === sar[1]) return { height: h, squareFrom: null, width: w };
    const dh = Math.max(2, Math.round((h * sar[1]) / sar[0]));
    return { height: dh, squareFrom: { h, w }, width: w };
}

/**
 * `ffmpeg -hide_banner -i <file>` stderr (ffmpeg exits 1 for the missing output; that is ignored).
 * @param {string} ffmpeg @param {string} file @param {number} [timeoutMs]
 * @returns {Promise<string>}
 */
export function ffmpegInfo(ffmpeg, file, timeoutMs = 30000) {
    return new Promise((resolve) => {
        let out = "";
        let child;
        try {
            child = spawn(ffmpeg, ["-hide_banner", "-protocol_whitelist", "file,pipe", "-i", file], { stdio: ["ignore", "ignore", "pipe"] });
        } catch {
            return resolve("");
        }
        child.stderr?.on("data", (d) => {
            if (out.length < 200000) out += d;
        });
        const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
        child.on("error", () => {
            clearTimeout(timer);
            resolve(out);
        });
        child.on("close", () => {
            clearTimeout(timer);
            resolve(out);
        });
    });
}

/** Decodes the first frame (a photo or GIF that will not decode is unsupported). @param {string} ffmpeg @param {string} file @returns {Promise<boolean>} */
export function decodesOneFrame(ffmpeg, file) {
    return new Promise((resolve) => {
        let child;
        try {
            child = spawn(ffmpeg, ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", file, "-frames:v", "1", "-f", "null", "-"], { stdio: "ignore" });
        } catch {
            return resolve(false);
        }
        const timer = setTimeout(() => child.kill("SIGKILL"), 30000);
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

/** @param {string} file @param {number} n @returns {Promise<Buffer>} */
async function readHead(file, n) {
    const fh = await open(file, "r");
    try {
        const buf = Buffer.alloc(n);
        const { bytesRead } = await fh.read(buf, 0, n, 0);
        return buf.subarray(0, bytesRead);
    } finally {
        await fh.close();
    }
}

/** A picture over this many pixels is refused before any decoder sees it (a "pixel bomb"). */
export const MAX_PIXELS = 120_000_000;

/**
 * Probes one input file for `kind` ("video" | "gif" | "photo", what the DO says it is). The kind is checked by the bytes.
 * Resolves `{ok: true, source}` with everything compile.js needs (display size with square pixels, duration, audio, colour),
 * or `{ok: false, code: "error.edit.unsupported_source"}`.
 * @param {{ffmpeg: string, file: string, kind: "video" | "gif" | "photo", item: string, bytes: number}} o
 * @returns {Promise<{ok: true, source: Source} | {ok: false, code: string}>}
 *
 * @typedef {{item: string, path: string, kind: "video" | "gif" | "photo", contentType: string, bytes: number, width: number,
 *            height: number, squareFrom: {w: number, h: number} | null, duration: number | null, hasAudio: boolean,
 *            channels: number | null, hdr: boolean, transfer: string | null, orientation: number}} Source
 */
export async function probeSource(o) {
    const unsupported = { code: "error.edit.unsupported_source", ok: /** @type {const} */ (false) };
    let head;
    try {
        head = await readHead(o.file, 131072);
    } catch {
        return unsupported;
    }
    const sniffed = sniffKind(head);
    const want = { gif: "gif", photo: null, video: "mp4" }[o.kind];
    if (o.kind === "photo" ? sniffed !== "jpeg" && sniffed !== "png" : sniffed !== want) return unsupported;
    const info = parseInfo(await ffmpegInfo(o.ffmpeg, o.file));
    if (!info.hasVideo || !info.width || !info.height) return unsupported;
    if (info.width * info.height > MAX_PIXELS) return unsupported;
    if (o.kind !== "video" && !(await decodesOneFrame(o.ffmpeg, o.file))) return unsupported;
    let w = info.width, h = info.height;
    let orientation = 1;
    if (o.kind === "photo" && sniffed === "jpeg") {
        orientation = exifOrientation(head);
        if (orientation >= 5) [w, h] = [h, w];
    }
    const sz = o.kind === "video" ? displaySize(w, h, info.sar) : { height: h, squareFrom: null, width: w };
    return {
        ok: true,
        source: {
            bytes: o.bytes,
            channels: o.kind === "video" ? info.channels : null,
            contentType: o.kind === "video" ? "video/mp4" : o.kind === "gif" ? "image/gif" : sniffed === "png" ? "image/png" : "image/jpeg",
            duration: o.kind === "video" ? info.duration : null,
            hasAudio: o.kind === "video" && info.hasAudio,
            hdr: o.kind === "video" && info.hdr,
            height: sz.height,
            item: o.item,
            kind: o.kind,
            orientation,
            path: o.file,
            squareFrom: sz.squareFrom,
            transfer: o.kind === "video" ? info.transfer : null,
            width: sz.width,
        },
    };
}
