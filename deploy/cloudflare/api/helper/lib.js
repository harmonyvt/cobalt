// Pure(ish) pieces of the animated-WebP helper, split from supervisor.js so
// they can be unit-tested with a stubbed fetch. Plain Node ESM, no dependencies.

import { createHash, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { lookup as dnsLookup } from "node:dns";
import { createWriteStream } from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { mkdir, open, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fromWire } from "./crop.js";

export const COBALT_ORIGIN = "http://127.0.0.1:9000";
export const MAX_DOWNLOAD_BYTES = 300 * 1024 * 1024;
// cobalt studio: the source video saved into R2 (POST /fetch) and streamed back
// for a render (POST /jobs/upload) is at most this large.
export const MAX_FETCH_BYTES = 200 * 1024 * 1024;
// Output cap (WEBP_MAX_BYTES overrides) and the longest clip that will be
// encoded (WEBP_MAX_SECONDS overrides). Read once at import.
export const MAX_OUTPUT_BYTES = Number(process.env.WEBP_MAX_BYTES) || 25 * 1024 * 1024;
export const MAX_CLIP_SECONDS = Number(process.env.WEBP_MAX_SECONDS) || 60;
// A "60 s" video often reports 60.03 s; allow this much over the limit.
export const TOO_LONG_SLACK = 0.5;
// img2webp `-lossy -q` per quality name (measured on a real 9.6 s clip: q75 is
// clean with forced keyframes at about 1.3 MB).
export const QUALITY = { low: 65, med: 75, high: 85 };
// img2webp keyframe interval. A keyframe every 3 to 5 frames stops
// WebPAnimEncoder from carrying stale sub-rectangles from earlier scenes
// ("ghosting"); kmax 15 brought the blocks back.
export const KMIN = 3;
export const KMAX = 5;
export const ID_RE = /^[A-Za-z0-9]{16,32}$/;
// downloadToFile reports progress at most once per this many bytes or ms.
export const PROGRESS_BYTES = 256 * 1024;
export const PROGRESS_MS = 250;
/** The first bytes `downloadToFile`'s `acceptHead` judges: enough for every signature `sniffType` / `sniffVideo` read. */
export const HEAD_BYTES = 64;

// An error that carries the public error code the DO passes on to the client.
export class JobError extends Error {
    /** @param {string} code */
    constructor(code) {
        super(code);
        this.code = code;
    }
}

// --- auth -------------------------------------------------------------------

const sha256 = (s) => createHash("sha256").update(s).digest();

/**
 * Constant-time check of the x-internal-key header. An empty expected key
 * (COBALT_INTERNAL_KEY unset) matches nothing, so a misconfigured container
 * answers 403 to everything instead of being open.
 * @param {string | undefined} header
 * @param {string | undefined} expected
 */
export function keyMatches(header, expected) {
    if (!expected || typeof header !== "string") return false;
    return timingSafeEqual(sha256(header), sha256(expected));
}

/**
 * Second-level label of the link's host, e.g. https://www.twitter.com/x -> "twitter".
 * @param {string} raw
 */
export function serviceFromUrl(raw) {
    try {
        const labels = new URL(raw).hostname.split(".");
        return (labels.length >= 2 ? labels[labels.length - 2] : labels[0]) || "unknown";
    } catch {
        return "unknown";
    }
}

// --- job input --------------------------------------------------------------

/**
 * Re-validates a POST /jobs body (the DO already did; the helper does not
 * trust it). Returns a normalised job or null.
 * @param {any} b
 */
export function validateJobInput(b) {
    if (typeof b !== "object" || b === null) return null;
    if (typeof b.id !== "string" || !ID_RE.test(b.id)) return null;
    if (!isHttpUrl(b.url)) return null;
    const enc = validateEncodeFields(b, { minLength: 1 });
    if (!enc) return null;
    return { id: b.id, url: b.url, ...enc };
}

/** @param {unknown} u */
function isHttpUrl(u) {
    if (typeof u !== "string" || u.length === 0 || u.length > 2048) return false;
    try {
        const p = new URL(u);
        return p.protocol === "http:" || p.protocol === "https:";
    } catch {
        return false;
    }
}

/**
 * The encode fields shared by POST /jobs and POST /jobs/upload: start, optional
 * length, width, fps, quality. Values may be numbers or numeric strings (the
 * upload passes them in the query string). Returns the normalised fields
 * (`length` present only when given) or null.
 * @param {any} b
 * @param {{minLength: number}} o smallest accepted length in seconds
 */
export function validateEncodeFields(b, o) {
    const start = Number(b.start);
    // length is optional: absent (or null) = to the end of the video
    const hasLength = b.length !== undefined && b.length !== null;
    const length = hasLength ? Number(b.length) : undefined;
    const width = Number(b.width);
    const fps = Number(b.fps);
    if (!(start >= 0 && start <= 3600)) return null;
    if (hasLength && !(length >= o.minLength && length <= 600)) return null;
    if (![320, 480, 640].includes(width)) return null;
    if (!(Number.isInteger(fps) && fps >= 10 && fps <= 25)) return null;
    if (typeof b.quality !== "string" || !Object.hasOwn(QUALITY, b.quality)) return null;
    // optional spatial crop (normalized; section 10): a JSON object, or "x,y,w,h" from the
    // upload's query string. Converted to pixels at encode time, from the probed size.
    const crop = b.crop === undefined || b.crop === null || b.crop === "" ? { ok: true, crop: null } : fromWire(b.crop);
    if (!crop.ok) return null;
    const out = { start, width, fps, quality: b.quality };
    if (hasLength) out.length = length;
    if (crop.crop) out.crop = crop.crop;
    return out;
}

/**
 * Re-validates a POST /fetch body {id, url}: the link cobalt studio saves.
 * @param {any} b
 */
export function validateFetchInput(b) {
    if (typeof b !== "object" || b === null) return null;
    if (typeof b.id !== "string" || !ID_RE.test(b.id)) return null;
    if (!isHttpUrl(b.url)) return null;
    return { id: b.id, url: b.url };
}

/** Most items one gallery fetch saves (APP-API-CONTRACT 18.2). */
export const MAX_GALLERY_ITEMS = 20;
/** All of one fetch job's items together (each is also capped at MAX_FETCH_BYTES). */
export const MAX_JOB_BYTES = 500 * 1024 * 1024;

/**
 * The gallery fields of a POST /fetch body (APP-API-CONTRACT 18.2 / 18.7): `items` is "all",
 * "first-video" or 1-20 unique ascending non-negative integers; `item_count` an integer 1-50.
 * Both optional. A bad value is `{ok: false}` (the caller answers error.studio.invalid_params).
 * @param {any} b the (already id/url-validated) body
 * @returns {{ok: true, items?: "all" | "first-video" | number[], item_count?: number} | {ok: false}}
 */
export function parseFetchSelection(b) {
    /** @type {{ok: true, items?: "all" | "first-video" | number[], item_count?: number}} */
    const out = { ok: true };
    if (b.items !== undefined) {
        if (b.items === "all" || b.items === "first-video") out.items = b.items;
        else if (
            Array.isArray(b.items) &&
            b.items.length >= 1 &&
            b.items.length <= MAX_GALLERY_ITEMS &&
            b.items.every((n, k) => Number.isInteger(n) && n >= 0 && n < 100 && (k === 0 || n > b.items[k - 1]))
        ) {
            out.items = [...b.items];
        } else return { ok: false };
    }
    if (b.item_count !== undefined) {
        if (!Number.isInteger(b.item_count) || b.item_count < 1 || b.item_count > 50) return { ok: false };
        out.item_count = b.item_count;
    }
    return out;
}

/**
 * The `items` a fetch really runs with (APP-API-CONTRACT 18.9). A client that sent `items` gets it unchanged
 * (an explicit "first-video" on a photo-only post keeps failing: that is what it asked for). A client that sent
 * none (the 1.13 share sheet, a batch paste, a Shortcut) gets "all" exactly when cobalt answered a picker of 2+
 * entries none of which is a video or a gif, so a photo-only gallery is saved whole instead of failing
 * error.webp.no_video; every other case stays undefined (a 1-item picker, a mixed post's first video, a plain link).
 * @param {{type: string | null}[]} entries
 * @param {undefined | "all" | "first-video" | number[]} items
 * @returns {undefined | "all" | "first-video" | number[]}
 */
export function effectiveItems(entries, items) {
    if (items !== undefined) return items;
    if (entries.length >= 2 && entries.every((e) => e?.type !== "video" && e?.type !== "gif")) return "all";
    return undefined;
}

/**
 * Which picker entries a fetch saves. `entries` is `[{type, url}]` in cobalt's order; `type` is
 * null for a plain (non-picker) answer, which counts as a one-item picker of unknown type.
 *  - no `items`: a picker of exactly one saves that item whatever its type; 2+ keep the old rule
 *    (first video, else first gif, else error.webp.no_video);
 *  - "first-video": the old rule as is;
 *  - "all": every entry, at most MAX_GALLERY_ITEMS;
 *  - [indices]: those; one past the end means the post changed (error.studio.gallery_changed).
 * @param {{type: string | null}[]} entries
 * @param {undefined | "all" | "first-video" | number[]} items
 * @returns {{ok: true, indices: number[]} | {ok: false, code: string}}
 */
export function selectPickerItems(entries, items) {
    const firstVideo = () => {
        if (entries.length === 1 && entries[0].type === null) return { ok: true, indices: [0] };
        let i = entries.findIndex((e) => e?.type === "video");
        if (i < 0) i = entries.findIndex((e) => e?.type === "gif");
        return i < 0 ? { ok: false, code: "error.webp.no_video" } : { ok: true, indices: [i] };
    };
    if (items === undefined) {
        if (entries.length === 1) return { ok: true, indices: [0] };
        return /** @type {any} */ (firstVideo());
    }
    if (items === "first-video") return /** @type {any} */ (firstVideo());
    if (items === "all") {
        if (entries.length === 0) return { ok: false, code: "error.webp.no_video" };
        return { ok: true, indices: entries.slice(0, MAX_GALLERY_ITEMS).map((_, i) => i) };
    }
    if (items.some((i) => i >= entries.length)) return { ok: false, code: "error.studio.gallery_changed" };
    return { ok: true, indices: [...items] };
}

// --- what a saved video is ----------------------------------------------------

/**
 * Width, height (rotation applied) and duration of the first real video stream
 * from `ffmpeg -hide_banner -i <file>` stderr. Fields are null when absent.
 * A cover-art stream ("attached pic") is not a video.
 * @param {string} stderr
 * @returns {{duration: number | null, width: number | null, height: number | null}}
 */
export function parseVideoInfo(stderr) {
    const duration = parseDuration(stderr);
    const lines = stderr.split("\n");
    let width = null;
    let height = null;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (!/Stream #\d+:\d+.*Video:/.test(line) || /attached pic/.test(line)) continue;
        const after = line.slice(line.indexOf("Video:"));
        const m = /,\s*(\d{2,5})x(\d{2,5})\b/.exec(after);
        if (!m) continue;
        width = Number(m[1]);
        height = Number(m[2]);
        // side data of this stream sits on the following indented lines
        for (let j = i + 1; j < lines.length && !/Stream #\d+:\d+/.test(lines[j]); j++) {
            const r = /rotation of (-?\d+(?:\.\d+)?) degrees/.exec(lines[j]);
            if (r && Math.abs(Math.round(Number(r[1]))) % 180 === 90) {
                [width, height] = [height, width];
                break;
            }
        }
        break;
    }
    return { duration, width, height };
}

// Extensions a saved video may have (they end up in the R2 key), with the
// content type stored for each.
export const VIDEO_TYPES = {
    mp4: "video/mp4",
    webm: "video/webm",
    mov: "video/quicktime",
    mkv: "video/x-matroska",
    m4v: "video/x-m4v",
};
const TYPE_EXT = {
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-matroska": "mkv",
    "video/x-m4v": "m4v",
};

/**
 * File extension for a saved video: the download's content type first, then the
 * extension of cobalt's filename, else mp4 (cobalt serves mp4 nearly always).
 * @param {{contentType?: string | null, filename?: string | null}} o
 * @returns {keyof typeof VIDEO_TYPES}
 */
export function videoExt(o) {
    const ct = (o.contentType || "").split(";")[0].trim().toLowerCase();
    if (Object.hasOwn(TYPE_EXT, ct)) return /** @type {any} */ (TYPE_EXT[ct]);
    const m = /\.([a-z0-9]{2,4})$/i.exec(o.filename || "");
    const ext = m ? m[1].toLowerCase() : "";
    if (Object.hasOwn(VIDEO_TYPES, ext)) return /** @type {any} */ (ext);
    return "mp4";
}

/**
 * Whether a file's first bytes are a GIF (`GIF87a` / `GIF89a`). A "gif" from a
 * service that makes real GIFs (Reddit, Bluesky, Pinterest) arrives as one under
 * whatever name cobalt gave it, so the type is read from the bytes, never the name.
 * @param {Uint8Array | Buffer} head at least the first 6 bytes
 */
export function isGifHead(head) {
    if (head.length < 6) return false;
    const sig = String.fromCharCode(...head.subarray(0, 6));
    return sig === "GIF87a" || sig === "GIF89a";
}

const HEIF_BRANDS = new Set(["heic", "heix", "hevc", "mif1", "msf1"]);

/**
 * The type of a downloaded file from its first bytes (never from a name or a content type: cobalt
 * serves a jpeg under whatever name the service gave it, and ffmpeg calls a jpeg a 0.04 s video).
 * JPEG `FF D8 FF`, PNG, WebP `RIFF????WEBP`, HEIC/HEIF (`????ftyp` + heic heix hevc mif1 msf1) are
 * stills; GIF is the animated image the studio already takes as `image/gif`. Anything else (a
 * video, garbage, a head under 3 bytes) is null: the caller keeps the video path.
 * @param {Uint8Array | Buffer} head at least the first 12 bytes where there are that many
 * @returns {{type: "image" | "gif", contentType: string, ext: string} | null}
 */
export function sniffType(head) {
    const n = head.length;
    const ascii = (a, b) => String.fromCharCode(...head.subarray(a, b));
    if (n >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
        return { type: "image", contentType: "image/jpeg", ext: "jpg" };
    }
    if (
        n >= 8 &&
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => head[i] === v)
    ) {
        return { type: "image", contentType: "image/png", ext: "png" };
    }
    if (n >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") {
        return { type: "image", contentType: "image/webp", ext: "webp" };
    }
    if (n >= 12 && ascii(4, 8) === "ftyp" && HEIF_BRANDS.has(ascii(8, 12))) {
        return { type: "image", contentType: "image/heic", ext: "heic" };
    }
    if (isGifHead(head)) return { type: "gif", contentType: "image/gif", ext: "gif" };
    return null;
}

// ftyp brands of an ISO-BMFF file that carries video (the ones that name a still image or audio-only file are
// deliberately absent: heic/avif stills, M4A/M4B audio)
const MP4_BRANDS = new Set([
    "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "mp71", "avc1", "dash", "MSNV", "mmp4",
    "3gp4", "3gp5", "3gp6", "3gp7", "3ge6", "3ge7", "3gg6", "3g2a", "3g2b", "3g2c", "XAVC", "f4v ", "cmfc",
]);

/**
 * The container of a video file from its first bytes, only the five the studio stores (VIDEO_TYPES): an
 * ISO-BMFF `ftyp` with a video brand (mp4, mov `qt  `, m4v), or EBML (webm / matroska, told apart by the
 * DocType). Null for everything else (audio, a still, html, json, garbage, an unknown container). Used by
 * the direct-link path, which has no service to vouch for the file, so the bytes must.
 * @param {Uint8Array | Buffer} head up to the first 64 bytes
 * @returns {{ext: keyof typeof VIDEO_TYPES, contentType: string} | null}
 */
export function sniffVideo(head) {
    const n = head.length;
    const ascii = (a, b) => String.fromCharCode(...head.subarray(a, Math.min(b, n)));
    if (n >= 12 && ascii(4, 8) === "ftyp") {
        const brand = ascii(8, 12);
        let ext = null;
        if (brand === "qt  ") ext = "mov";
        else if (brand === "M4V " || brand === "M4VH" || brand === "M4VP") ext = "m4v";
        else if (MP4_BRANDS.has(brand)) ext = "mp4";
        return ext ? { ext: /** @type {any} */ (ext), contentType: VIDEO_TYPES[ext] } : null;
    }
    if (n >= 4 && head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3) {
        const ext = /webm/.test(ascii(4, 64)) ? "webm" : "mkv";
        return { ext, contentType: VIDEO_TYPES[ext] };
    }
    return null;
}

/** An ISO-BMFF `ftyp` box a real HEIC/HEIF file has: a plausible size (16-128 bytes, the brand list included) and a HEIF brand. */
export function plausibleHeicHead(head) {
    if (head.length < 16) return false;
    const size = Buffer.from(head.buffer, head.byteOffset, head.length).readUInt32BE(0);
    return size >= 16 && size <= 128 && String.fromCharCode(...head.subarray(4, 8)) === "ftyp" && HEIF_BRANDS.has(String.fromCharCode(...head.subarray(8, 12)));
}

/**
 * Whether the first bytes of a direct link's body can be an accepted file at all: a still / gif by `sniffType` (a HEIC
 * must also have a plausible `ftyp` box, not just 12 magic bytes) or a video container by `sniffVideo`. The download
 * stops at the first bytes that cannot be (a 200 MB html page is never fetched).
 * @param {Buffer} head
 */
export function directHeadOk(head) {
    const s = sniffType(head);
    if (s) return s.ext !== "heic" || plausibleHeicHead(head);
    return sniffVideo(head) !== null;
}

/**
 * Pixel size of a still or GIF read from its header bytes, with no decoder (a decoder is what a "pixel bomb" abuses: a
 * 797 KB PNG of 16000x16000 costs ~950 MB to thumbnail). JPEG: the first SOF marker; PNG: IHDR; GIF: the logical
 * screen; WebP: VP8 / VP8L / VP8X; HEIC/HEIF: the largest `ispe` box in `meta > iprp > ipco`. Null when the bytes
 * do not say (truncated, malformed, or a HEIC whose `meta` is past what was given).
 * @param {Uint8Array | Buffer} bytes the start of the file (a few hundred KB cover a JPEG with a large EXIF/ICC)
 * @returns {{width: number, height: number} | null}
 */
export function imageDimensions(bytes) {
    const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length);
    const kind = sniffType(b);
    if (!kind) return null;
    const dims = (w, h) => (w > 0 && h > 0 ? { width: w, height: h } : null);
    try {
        if (kind.ext === "png") {
            if (b.length < 24 || b.toString("latin1", 12, 16) !== "IHDR") return null;
            return dims(b.readUInt32BE(16), b.readUInt32BE(20));
        }
        if (kind.type === "gif") {
            return b.length < 10 ? null : dims(b.readUInt16LE(6), b.readUInt16LE(8));
        }
        if (kind.ext === "jpg") {
            let pos = 2;
            while (pos + 4 <= b.length) {
                if (b[pos] !== 0xff) return null;
                const marker = b[pos + 1];
                if (marker === 0xff) {
                    pos++; // fill byte
                    continue;
                }
                if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
                    pos += 2; // standalone markers carry no length
                    continue;
                }
                if (marker === 0xda || marker === 0xd9) return null; // scan data / end: no frame header was found
                const len = b.readUInt16BE(pos + 2);
                if (len < 2) return null;
                if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
                    if (pos + 9 > b.length) return null;
                    return dims(b.readUInt16BE(pos + 7), b.readUInt16BE(pos + 5));
                }
                pos += 2 + len;
            }
            return null;
        }
        if (kind.ext === "webp") {
            const chunk = b.toString("latin1", 12, 16);
            if (chunk === "VP8 " && b.length >= 30 && b[23] === 0x9d && b[24] === 0x01 && b[25] === 0x2a) {
                return dims(b.readUInt16LE(26) & 0x3fff, b.readUInt16LE(28) & 0x3fff);
            }
            if (chunk === "VP8L" && b.length >= 25 && b[20] === 0x2f) {
                const v = b.readUInt32LE(21);
                return dims((v & 0x3fff) + 1, ((v >>> 14) & 0x3fff) + 1);
            }
            if (chunk === "VP8X" && b.length >= 30) return dims(b.readUIntLE(24, 3) + 1, b.readUIntLE(27, 3) + 1);
            return null;
        }
        if (kind.ext === "heic") {
            if (!plausibleHeicHead(b)) return null;
            let best = null;
            /** @param {number} from @param {number} to @param {(type: string, start: number, end: number) => void} visit */
            const boxes = (from, to, visit) => {
                let p = from;
                while (p + 8 <= to) {
                    let size = b.readUInt32BE(p);
                    const type = b.toString("latin1", p + 4, p + 8);
                    let header = 8;
                    if (size === 1) {
                        if (p + 16 > to) return;
                        size = Number(b.readBigUInt64BE(p + 8));
                        header = 16;
                    } else if (size === 0) size = to - p;
                    if (size < header) return;
                    visit(type, p + header, Math.min(p + size, to));
                    p += size;
                }
            };
            boxes(0, b.length, (type, start, end) => {
                if (type !== "meta") return;
                boxes(start + 4, end, (t1, s1, e1) => {
                    if (t1 !== "iprp") return;
                    boxes(s1, e1, (t2, s2, e2) => {
                        if (t2 !== "ipco") return;
                        boxes(s2, e2, (t3, s3, e3) => {
                            if (t3 !== "ispe" || e3 - s3 < 12) return;
                            const w = b.readUInt32BE(s3 + 4);
                            const h = b.readUInt32BE(s3 + 8);
                            if (!best || w * h > best.width * best.height) best = { width: w, height: h };
                        });
                    });
                });
            });
            return best;
        }
    } catch {
        return null;
    }
    return null;
}

/**
 * A title from cobalt's filename (no extension), or null when it gave none.
 * @param {string | null | undefined} filename
 */
export function titleFromFilename(filename) {
    const base = (filename || "").replace(/\.[^.]*$/, "").trim();
    return base ? base.slice(0, 200) : null;
}

/** Cobalt error code -> what the studio reports (only the size code differs). */
export function studioCode(code) {
    return code === "error.webp.too_large" ? "error.studio.too_large" : code;
}

// --- clip planning ------------------------------------------------------------

/**
 * Reads the container duration (seconds) from `ffmpeg -hide_banner -i <file>`
 * stderr ("  Duration: 00:00:06.02, start: ..."). Null for "N/A" or no line.
 * @param {string} stderr
 * @returns {number | null}
 */
export function parseDuration(stderr) {
    const m = /Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)/.exec(stderr);
    if (!m) return null;
    const secs = Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
    return Number.isFinite(secs) && secs > 0 ? secs : null;
}

/**
 * Works out how many seconds to encode.
 *  - known duration: clip = min(length ?? Infinity, duration - start); start at
 *    or past the end is invalid_params; a clip over maxSeconds (+ slack) is
 *    too_long and is NOT encoded;
 *  - unknown duration (`null`): length if given (too_long when over the max),
 *    otherwise maxSeconds as a hard stop (`truncated: true`: a longer video is
 *    cut short rather than refused, because nothing says it is longer).
 * @param {{start: number, length?: number, duration: number | null,
 *          maxSeconds?: number}} o
 * @returns {{ok: true, seconds: number, truncated: boolean} | {ok: false, code: string}}
 */
export function planClip(o) {
    const max = o.maxSeconds ?? MAX_CLIP_SECONDS;
    const { start, length, duration } = o;
    if (duration === null || duration === undefined) {
        if (length === undefined) return { ok: true, seconds: max, truncated: true };
        if (length > max + TOO_LONG_SLACK) return { ok: false, code: "error.webp.too_long" };
        return { ok: true, seconds: Math.min(length, max), truncated: false };
    }
    const remaining = duration - start;
    if (!(remaining > 0)) return { ok: false, code: "error.webp.invalid_params" };
    const clip = Math.min(length ?? Infinity, remaining);
    if (clip > max + TOO_LONG_SLACK) return { ok: false, code: "error.webp.too_long" };
    return { ok: true, seconds: Math.min(clip, max), truncated: false };
}

// Plain decimal, at most 3 places: never "1e-7", which ffmpeg would misread.
const dec = (n) => String(+Number(n).toFixed(3));

/**
 * ffmpeg argv that decodes the clip window to numbered PNG frames. `length` is
 * the effective clip length from planClip (always passed explicitly).
 * `-ss`/`-t` come before `-i` (input options), the protocol whitelist keeps
 * ffmpeg on local files. Never upscales: the width is min(width, source width).
 * The output pattern is relative to `framesDir` (the caller runs ffmpeg with
 * that as cwd, but the absolute path is used here so cwd does not matter).
 * `crop` (whole even pixels, in the DISPLAY orientation: ffmpeg applies the rotation
 * metadata before the filter graph by default) is applied after `fps` and BEFORE the
 * scale, so the output width is min(width, cropped width) and the height keeps the
 * crop's aspect. Without it the filter is exactly what it always was.
 * @param {{input: string, framesDir: string, start: number, length?: number,
 *          width: number, fps: number, crop?: {x: number, y: number, w: number, h: number} | null}} j
 */
export function buildFrameArgs(j) {
    return [
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        "-ss", dec(j.start),
        // omitted only when no length is given (the supervisor always passes one)
        ...(j.length === undefined ? [] : ["-t", dec(j.length)]),
        "-i", j.input,
        "-vf",
        `fps=${j.fps},${j.crop ? `crop=${j.crop.w}:${j.crop.h}:${j.crop.x}:${j.crop.y},` : ""}scale='min(${j.width},iw)':-2:flags=lanczos`,
        "-an", "-sn", "-dn",
        "-f", "image2",
        "-y",
        path.join(j.framesDir, "f%05d.png"),
    ];
}

// --- poster frames --------------------------------------------------------------

/** Longest side of a poster JPEG in pixels (never upscaled). */
export const POSTER_MAX_SIDE = 720;
/** ffmpeg `-q:v` for the poster JPEG (2 = best, 31 = worst; 4 is visually clean at about 15-40 KB). */
export const POSTER_QUALITY = 4;
/** The frame is taken at 10 % of the duration, at most this many seconds in. */
export const POSTER_FRACTION = 0.1;
export const POSTER_MAX_AT_SECONDS = 3;
/** A poster larger than this is refused (a 720 px JPEG is tens of KB). */
export const MAX_POSTER_BYTES = 2 * 1024 * 1024;

/**
 * Where in the video the poster frame is taken: 10 % of the duration (a title card or a
 * black first frame is not representative), at most POSTER_MAX_AT_SECONDS in, and 0 when
 * the duration is not known.
 * @param {number | null | undefined} duration seconds
 * @returns {number}
 */
export function posterTime(duration) {
    if (typeof duration !== "number" || !Number.isFinite(duration) || duration <= 0) return 0;
    return +Math.min(duration * POSTER_FRACTION, POSTER_MAX_AT_SECONDS).toFixed(3);
}

/** Longer side of the thumb the helper makes for a saved photo (APP-API-CONTRACT 18.7). */
export const THUMB_MAX_SIDE = 480;

/**
 * ffmpeg argv that writes ONE JPEG frame at `at` seconds: scaled so the longer side is at
 * most POSTER_MAX_SIDE (never upscaled; the rotation metadata is applied first, so a phone
 * clip comes out upright), square pixels, 4:2:0 full-range (what every JPEG decoder takes).
 * `-ss` before `-i` seeks the input (fast on a local file), the protocol whitelist keeps
 * ffmpeg on local files. An image has only frame 0: pass no `at` (null or undefined) and there
 * is no `-ss` (a 0.004 s seek past the one frame writes nothing). `side` defaults to POSTER_MAX_SIDE.
 * @param {{input: string, output: string, at?: number | null, side?: number}} j
 */
export function buildPosterArgs(j) {
    const side = j.side ?? POSTER_MAX_SIDE;
    return [
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        ...(j.at === undefined || j.at === null ? [] : ["-ss", dec(j.at)]),
        "-i", j.input,
        "-frames:v", "1",
        "-an", "-sn", "-dn",
        "-vf",
        `scale='if(gte(iw,ih),min(${side},iw),-1)':'if(gte(iw,ih),-1,min(${side},ih))':flags=lanczos,setsar=1,format=yuvj420p`,
        "-q:v", String(POSTER_QUALITY),
        "-f", "image2",
        "-update", "1",
        "-y",
        j.output,
    ];
}

/** Frame file names ffmpeg writes: f00001.png ... */
export const FRAME_RE = /^f\d{5}\.png$/;

/**
 * img2webp argv. Frames are passed as the given names in order; pass names
 * relative to the frames dir and run with that as cwd, so 1500 frames
 * (60 s x 25 fps) stay around 16 KB of argv instead of ~90 KB of absolute paths.
 * Options come before the frames because -d/-lossy/-q/-m apply to the frames
 * that follow them. The per-frame duration is round(1000 / fps) ms.
 * @param {{frames: string[], output: string, fps: number,
 *          quality: "low"|"med"|"high"}} j
 */
export function buildImg2webpArgs(j) {
    return [
        "-loop", "0",
        "-d", String(Math.round(1000 / j.fps)),
        "-lossy",
        "-q", String(QUALITY[j.quality]),
        "-m", "4",
        "-kmin", String(KMIN),
        "-kmax", String(KMAX),
        ...j.frames,
        "-o", j.output,
    ];
}

// --- running the encoder --------------------------------------------------------

/**
 * Runs one child process to completion. Rejects with a JobError:
 * `error.webp.timeout` when `timeoutMs` elapses (the child is SIGKILLed),
 * `error.webp.encode_failed` for a spawn error or a non-zero exit.
 * `onStdout` (optional) receives the child's stdout chunks (ffmpeg's `-progress pipe:1`).
 * @param {{spawnImpl?: typeof spawn, bin: string, args: string[], cwd?: string,
 *          timeoutMs: number, label: string,
 *          onStdout?: (chunk: Buffer | string) => void,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void}} o
 * @returns {Promise<void>}
 */
export function runProcess(o) {
    const spawnImpl = o.spawnImpl ?? spawn;
    return new Promise((resolve, reject) => {
        if (!(o.timeoutMs > 0)) return reject(new JobError("error.webp.timeout"));
        let child;
        try {
            child = spawnImpl(o.bin, o.args, {
                cwd: o.cwd,
                stdio: ["ignore", o.onStdout ? "pipe" : "ignore", "pipe"],
            });
        } catch {
            return reject(new JobError("error.webp.encode_failed"));
        }
        o.onChild?.(child);
        if (o.onStdout) child.stdout?.on("data", o.onStdout);
        let tail = "";
        let timedOut = false;
        child.stderr?.on("data", (d) => {
            tail = (tail + d).slice(-2000);
        });
        const timer = setTimeout(() => {
            timedOut = true;
            child.kill("SIGKILL");
        }, o.timeoutMs);
        child.on("error", () => {
            clearTimeout(timer);
            o.onChild?.(undefined);
            reject(new JobError("error.webp.encode_failed"));
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            o.onChild?.(undefined);
            if (timedOut) return reject(new JobError("error.webp.timeout"));
            if (code !== 0) {
                console.error(`[webp-helper] ${o.label} exit ${code}: ${tail.trim()}`);
                return reject(new JobError("error.webp.encode_failed"));
            }
            resolve();
        });
    });
}

/**
 * The whole encode: ffmpeg decodes the clip window to PNG frames in
 * `framesDir`, then img2webp (with forced keyframes) turns them into
 * `output`. The frames dir is deleted afterwards, on success and on failure.
 * The two steps share one budget: `timeoutMs` counts from the call.
 * Returns how many frames were made and how many bytes they took on disk (the
 * peak use of the frames dir, since it only shrinks after this).
 * @param {{ffmpegBin: string, img2webpBin: string, input: string,
 *          output: string, framesDir: string, start: number, length?: number,
 *          width: number, fps: number, quality: "low"|"med"|"high",
 *          crop?: {x: number, y: number, w: number, h: number} | null, timeoutMs: number, spawnImpl?: typeof spawn,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void,
 *          onPhase?: (phase: "decode" | "pack", info: {total?: number | null, frames?: number}) => void}} o
 *   `onPhase("decode", {total})` fires before ffmpeg starts (`total` = the
 *   frame count expected, max(1, round(length * fps)), or null without a
 *   length); `onPhase("pack", {frames})` fires after the frames are listed,
 *   before img2webp, with the real count.
 * @returns {Promise<{frames: number, frameBytes: number}>}
 */
export async function encodeAnimatedWebp(o) {
    const deadline = Date.now() + o.timeoutMs;
    const left = () => deadline - Date.now();
    try {
        await rm(o.framesDir, { recursive: true, force: true });
        await mkdir(o.framesDir, { recursive: true });

        o.onPhase?.("decode", {
            total: o.length === undefined ? null : Math.max(1, Math.round(o.length * o.fps)),
        });
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.ffmpegBin,
            args: buildFrameArgs(o),
            cwd: o.framesDir,
            timeoutMs: left(),
            label: "ffmpeg",
            onChild: o.onChild,
        });

        const frames = (await readdir(o.framesDir)).filter((n) => FRAME_RE.test(n)).sort();
        if (frames.length === 0) throw new JobError("error.webp.encode_failed");
        let frameBytes = 0;
        for (const f of frames) frameBytes += (await stat(path.join(o.framesDir, f))).size;

        o.onPhase?.("pack", { frames: frames.length });
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.img2webpBin,
            args: buildImg2webpArgs({ frames, output: o.output, fps: o.fps, quality: o.quality }),
            cwd: o.framesDir,
            timeoutMs: left(),
            label: "img2webp",
            onChild: o.onChild,
        });
        return { frames: frames.length, frameBytes };
    } finally {
        await rm(o.framesDir, { recursive: true, force: true }).catch(() => {});
    }
}

// --- resolving the source through cobalt ------------------------------------

// URL.hostname keeps brackets on IPv6 literals; IPv4 literals are matched whole
// so a name like "10.example.com" is not mistaken for one.
const PRIVATE_HOST = new RegExp(
    "^(" +
        [
            "localhost",
            ".*\\.localhost",
            ".*\\.internal",
            ".*\\.local",
            "0\\.0\\.0\\.0",
            "127(\\.\\d+){3}",
            "10(\\.\\d+){3}",
            "192\\.168(\\.\\d+){2}",
            "169\\.254(\\.\\d+){2}",
            "172\\.(1[6-9]|2\\d|3[01])(\\.\\d+){2}",
            "\\[[0-9a-f:.]*\\]", // any IPv6 literal (loopback, ULA, mapped v4, ...)
        ].join("|") +
        ")$",
    "i",
);

/**
 * Turns a media URL from cobalt into one the helper may fetch.
 *  - a /tunnel URL on cobalt's own origin (API_URL, i.e. the PUBLIC api host in
 *    production, or the local one) is rewritten to http://127.0.0.1:9000, so the
 *    download never leaves the container;
 *  - anything else must be a public http(s) URL (a redirect/picker item);
 *  - a /tunnel path on any other host, or a private/loopback host, is refused.
 * Returns null when refused.
 * @param {string} raw
 * @param {{origin?: string, apiOrigin?: string, tunnelOnly?: boolean}} [o]
 */
export function rewriteMediaUrl(raw, o = {}) {
    const origin = o.origin ?? COBALT_ORIGIN;
    let u;
    try {
        u = new URL(raw);
    } catch {
        return null;
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    if (u.username || u.password) return null;

    if (u.pathname === "/tunnel") {
        const ours = u.origin === origin || (o.apiOrigin && u.origin === o.apiOrigin);
        return ours ? `${origin}/tunnel${u.search}` : null;
    }
    if (o.tunnelOnly) return null;
    if (PRIVATE_HOST.test(u.hostname)) return null;
    return u.toString();
}

// --- public URLs: the one rule for anything fetched from a link the owner pasted -----------------------
//
// A direct media link (APP-API-CONTRACT.md section 19) and every non-tunnel picker/redirect item are fetched
// from a host this code does not control, from inside the container. So the destination is checked, in
// the order that matters: the URL (scheme, credentials, port, a private-looking name or address), then the
// ADDRESS THE CONNECTION USES (the name is resolved by the connection's own `lookup`, so the address checked is the
// address connected to: a name that resolves to a private address, or flips between lookups, never gets
// a socket), then every redirect hop again, at most MAX_REDIRECTS of them.

/** Only the web's own ports: a link to `host:6379` or `:9000` is never a media file. */
export const PUBLIC_PORTS = [80, 443];
export const MAX_REDIRECTS = 3;
/** A socket idle for this long (connecting, waiting for headers, or between body chunks) is dropped. */
export const FETCH_IDLE_MS = 30_000;

/** @param {string} ip dotted quad @returns {number[] | null} */
function v4Parts(ip) {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
    if (!m) return null;
    const p = m.slice(1).map(Number);
    return p.every((n) => n <= 255) ? p : null;
}

/** @param {number[]} p */
function publicV4([a, b, c]) {
    if (a === 0 || a === 10 || a === 127) return false; // "this" network, private, loopback
    if (a === 100 && b >= 64 && b <= 127) return false; // carrier-grade NAT
    if (a === 169 && b === 254) return false; // link-local, incl. the 169.254.169.254 metadata address
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 0 && c === 0) return false; // IETF protocol assignments
    if (a === 192 && b === 0 && c === 2) return false; // documentation
    if (a === 192 && b === 88 && c === 99) return false; // 6to4 relay anycast
    if (a === 192 && b === 168) return false;
    if (a === 198 && (b === 18 || b === 19)) return false; // benchmarking
    if (a === 198 && b === 51 && c === 100) return false; // documentation
    if (a === 203 && b === 0 && c === 113) return false; // documentation
    if (a >= 224) return false; // multicast, reserved, broadcast
    return true;
}

/**
 * The eight 16-bit groups of an IPv6 address (the dotted-quad tail form included), or null.
 * @param {string} ip
 * @returns {number[] | null}
 */
function v6Groups(ip) {
    let s = ip;
    const tail = /(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
    if (tail) {
        const q = v4Parts(tail[1]);
        if (!q) return null;
        s = s.slice(0, s.length - tail[1].length) + ((q[0] << 8) | q[1]).toString(16) + ":" + ((q[2] << 8) | q[3]).toString(16);
    }
    const halves = s.split("::");
    if (halves.length > 2) return null;
    const head = halves[0] ? halves[0].split(":") : [];
    const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
    const missing = 8 - head.length - rest.length;
    if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
    const all = [...head, ...(halves.length === 2 ? Array(missing).fill("0") : []), ...rest];
    if (all.length !== 8) return null;
    const g = all.map((h) => (/^[0-9a-f]{1,4}$/.test(h) ? parseInt(h, 16) : NaN));
    return g.some(Number.isNaN) ? null : g;
}

/** @param {number} hi @param {number} lo */
const quad = (hi, lo) => [hi >> 8, hi & 255, lo >> 8, lo & 255];

/**
 * Whether an IP literal (v4 or v6) is a public, globally routable unicast address. A WHITELIST for IPv6
 * (only 2000::/3 and the embedded-IPv4 forms, never ::, ::1, fc00::/7, fe80::/10, ff00::/8, ...), and every
 * way of writing a v4 address inside a v6 one (IPv4-mapped `::ffff:a.b.c.d` in either spelling, the
 * deprecated IPv4-compatible `::a.b.c.d`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) is judged by the v4 address inside.
 * Anything that is not an IP literal is false.
 * @param {string} ip
 */
export function isPublicIp(ip) {
    let s = String(ip).trim().toLowerCase();
    if (s.startsWith("[") && s.endsWith("]")) s = s.slice(1, -1);
    s = s.replace(/%.*$/, ""); // a zone id
    const kind = net.isIP(s);
    if (kind === 4) {
        const p = v4Parts(s);
        return p !== null && publicV4(p);
    }
    if (kind !== 6) return false;
    const g = v6Groups(s);
    if (!g) return false;
    const [g0, g1, g2, g3, g4, g5, g6, g7] = g;
    // ::ffff:0:0/96 (IPv4-mapped) and ::/96 (IPv4-compatible; :: and ::1 fall out as v4 0.x.x.x)
    if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && (g5 === 0xffff || g5 === 0)) {
        return publicV4(quad(g6, g7));
    }
    // 64:ff9b::/96 (NAT64, what a DNS64 resolver makes of a v4-only host)
    if (g0 === 0x64 && g1 === 0xff9b && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0) return publicV4(quad(g6, g7));
    // 2002::/16 (6to4) carries a v4 address in groups 1-2
    if (g0 === 0x2002) return publicV4(quad(g1, g2));
    if ((g0 & 0xe000) !== 0x2000) return false; // not global unicast: ULA, link-local, multicast, loopback, ...
    if (g0 === 0x2001 && g1 === 0) return false; // Teredo
    if (g0 === 0x2001 && g1 === 0xdb8) return false; // documentation
    if (g0 === 0x2001 && (g1 & 0xfff0) === 0x10) return false; // ORCHID
    if (g0 === 0x3fff && g1 <= 0x0fff) return false; // documentation
    return true;
}

/**
 * The URL as a `URL` when it is one this code may fetch, else null: http(s) only, no credentials, port 80 or
 * 443 only (`o.ports`, null = any: tests), a host that is a public IP literal, or a name with a dot that is not
 * one of the private-looking spellings (localhost, *.local, *.internal, ...). Names are only half the check:
 * `makeSafeFetch` also checks what they resolve to.
 * @param {unknown} raw
 * @param {{ports?: number[] | null, isPublicIp?: (ip: string) => boolean}} [o]
 * @returns {URL | null}
 */
export function checkPublicUrl(raw, o = {}) {
    if (typeof raw !== "string" || raw.length === 0 || raw.length > 2048) return null;
    let u;
    try {
        u = new URL(raw);
    } catch {
        return null;
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    if (u.username || u.password) return null;
    const ports = o.ports === undefined ? PUBLIC_PORTS : o.ports;
    const port = u.port ? Number(u.port) : u.protocol === "https:" ? 443 : 80;
    if (ports && !ports.includes(port)) return null;
    const host = u.hostname.replace(/\.$/, "");
    if (!host) return null;
    const bare = host.startsWith("[") ? host.slice(1, -1) : host;
    if (net.isIP(bare)) return (o.isPublicIp ?? isPublicIp)(bare) ? u : null;
    if (!host.includes(".") || PRIVATE_HOST.test(host)) return null;
    return u;
}

/** Host and path only: a signed link's query is a credential and never reaches a log. */
export function logUrl(raw) {
    try {
        const u = new URL(raw);
        return `${u.host}${u.pathname}`.slice(0, 160);
    } catch {
        return "(unparseable url)";
    }
}

/** The last path segment of a URL, decoded and cleaned, or null (`/attachments/1/2/LiaPoor.png` is `LiaPoor.png`). */
export function filenameFromUrl(u) {
    const last = u.pathname.split("/").filter(Boolean).pop();
    if (!last) return null;
    let name = last;
    try {
        name = decodeURIComponent(last);
    } catch {
        // keep it as it is
    }
    // eslint-disable-next-line no-control-regex
    // controls (C0 and C1), path separators, zero-width and bidi override/isolate characters (they flip how a title reads)
    name = name
        .replace(/[\u0000-\u001f\u007f-\u009f/\\\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]/g, "")
        .trim()
        .slice(0, 200);
    return name || null;
}

/**
 * A `lookup` for `http.request` that refuses to connect when ANY address the name resolves to is not public.
 * It is the connection's own resolution, so the address checked is the address used (no second lookup to
 * rebind), and it runs again on every redirect hop's new connection.
 * @param {(host: string, o: object, cb: Function) => void} lookupImpl
 * @param {(ip: string) => boolean} isPublic
 * @param {{refused: boolean}} flag
 */
function guardedLookup(lookupImpl, isPublic, flag) {
    return (hostname, options, cb) => {
        if (typeof options === "function") {
            cb = options;
            options = {};
        }
        lookupImpl(hostname, { ...options, all: true }, (err, addrs) => {
            if (err) return cb(err);
            const list = Array.isArray(addrs) ? addrs : [{ address: addrs, family: net.isIP(addrs) }];
            if (list.length === 0 || list.some((a) => !isPublic(a.address))) {
                flag.refused = true;
                return cb(new JobError("error.webp.bad_source"));
            }
            if (options.all) return cb(null, list);
            return cb(null, list[0].address, list[0].family);
        });
    };
}

const REDIRECTS = new Set([301, 302, 303, 307, 308]);

/**
 * A `fetch` that only talks to public hosts (see the section comment). Same shape as `fetch(url, {signal})`, so
 * it drops into `downloadToFile({fetchImpl})`. Redirects are followed by hand: each hop's URL goes through
 * `checkPublicUrl` and its connection through the guarded lookup, at most `maxRedirects` hops, never
 * https -> http. Sends no credentials of any kind (no cookie, no authorization, no referer: the request
 * carries a user agent and `accept` and nothing from the client), asks for an unencoded body (the byte caps count
 * what is on the wire), and drops a socket idle for `idleMs`. A refusal is `JobError("error.webp.bad_source")`.
 * `policy` exists for tests (a local origin, a fake resolver); the helper never passes one.
 * @param {{ports?: number[] | null, maxRedirects?: number, idleMs?: number,
 *          isPublicIp?: (ip: string) => boolean,
 *          lookup?: (host: string, o: object, cb: Function) => void}} [policy]
 * @returns {typeof fetch}
 */
export function makeSafeFetch(policy = {}) {
    const ports = policy.ports === undefined ? PUBLIC_PORTS : policy.ports;
    const maxRedirects = policy.maxRedirects ?? MAX_REDIRECTS;
    const idleMs = policy.idleMs ?? FETCH_IDLE_MS;
    const isPublic = policy.isPublicIp ?? isPublicIp;
    const lookupImpl = policy.lookup ?? ((h, o, cb) => dnsLookup(h, o, cb));
    const refuse = () => new JobError("error.webp.bad_source");

    /** @param {URL} u @param {AbortSignal | undefined} signal */
    const once = (u, signal) =>
        new Promise((resolve, reject) => {
            const flag = { refused: false };
            /** @type {http.IncomingMessage | null} */
            let incoming = null;
            // one way to end the exchange, before or after the answer began: the socket is destroyed and whoever
            // reads the body sees the same error (a bare destroy would surface as "aborted", losing the cause)
            const end = (/** @type {Error} */ e) => {
                incoming?.destroy(e);
                req.destroy(e);
            };
            const onAbort = () =>
                end(Object.assign(new Error("aborted"), { name: signal?.reason?.name === "TimeoutError" ? "TimeoutError" : "AbortError" }));
            const host = u.hostname.startsWith("[") ? u.hostname.slice(1, -1) : u.hostname;
            const req = (u.protocol === "https:" ? https : http).request(
                {
                    hostname: host,
                    port: u.port || (u.protocol === "https:" ? 443 : 80),
                    path: `${u.pathname}${u.search}`,
                    method: "GET",
                    agent: false,
                    lookup: guardedLookup(lookupImpl, isPublic, flag),
                    headers: {
                        "user-agent": "Mozilla/5.0 (compatible; cobalt-studio)",
                        accept: "*/*",
                        "accept-encoding": "identity",
                        connection: "close",
                    },
                },
                (res) => {
                    incoming = res;
                    resolve(res);
                },
            );
            req.on("timeout", () => end(Object.assign(new Error("idle"), { name: "TimeoutError" })));
            req.setTimeout(idleMs);
            req.on("error", (e) => reject(flag.refused ? refuse() : e));
            // a `101 Switching Protocols` (or anything that closes the socket before a response) never emits "response"
            // or "error", only "close": without these two the promise would never settle and the job would hang
            req.on("upgrade", (_res, socket) => {
                socket.destroy();
                reject(Object.assign(new Error("upgrade refused"), { code: "ECONNRESET" }));
            });
            req.on("close", () => {
                signal?.removeEventListener("abort", onAbort);
                reject(Object.assign(new Error("closed without a response"), { code: "ECONNRESET" })); // a no-op once settled
            });
            if (signal?.aborted) onAbort();
            else signal?.addEventListener("abort", onAbort, { once: true });
            req.end();
        });

    return /** @type {typeof fetch} */ (
        async function safeFetch(input, init) {
            let current = checkPublicUrl(typeof input === "string" ? input : String(input), { ports, isPublicIp: isPublic });
            if (!current) throw refuse();
            for (let followed = 0; ; followed++) {
                const res = /** @type {http.IncomingMessage} */ (await once(current, init?.signal ?? undefined));
                const status = res.statusCode ?? 0;
                if (REDIRECTS.has(status) && res.headers.location) {
                    res.destroy();
                    if (followed >= maxRedirects) throw refuse();
                    let next = null;
                    try {
                        next = checkPublicUrl(new URL(res.headers.location, current).toString(), { ports, isPublicIp: isPublic });
                    } catch {
                        // an unparseable Location is a refusal
                    }
                    if (!next || (current.protocol === "https:" && next.protocol === "http:")) throw refuse();
                    current = next;
                    continue;
                }
                const headers = new Headers();
                for (const [k, v] of Object.entries(res.headers)) {
                    if (k !== "set-cookie" && v !== undefined) headers.set(k, Array.isArray(v) ? v.join(", ") : v);
                }
                // a status `Response` cannot represent (100-199 never arrive here, 600-999 can) is a bad gateway
                const valid = status >= 200 && status <= 599;
                const bodyless = !valid || status === 204 || status === 205 || status === 304;
                if (bodyless) res.destroy();
                return new Response(bodyless ? null : /** @type {any} */ (Readable.toWeb(res)), { status: valid ? status : 502, headers });
            }
        }
    );
}

/**
 * POSTs the link to the local cobalt (with the internal key) and works out
 * which file to download. Throws JobError with the code to report.
 * With `picker: true` (the studio's fetch) a picker answer is returned whole as
 * `{url: null, filename: null, picker: [{i, type, url}]}` (`type` photo|video|gif, `url`
 * rewritten, null when refused: that one item then fails alone) and the caller chooses; without
 * it (WebP jobs) a picker still gives its first video, else gif, else error.webp.no_video.
 * @param {{url: string, internalKey: string, fetchImpl?: typeof fetch,
 *          origin?: string, apiOrigin?: string, signal?: AbortSignal, picker?: boolean}} o
 * @returns {Promise<{url: string | null, filename: string | null,
 *          picker?: {i: number, type: "photo" | "video" | "gif", url: string | null}[]}>}
 */
export async function resolveSource(o) {
    const fetchImpl = o.fetchImpl ?? fetch;
    const origin = o.origin ?? COBALT_ORIGIN;
    const rw = (u, tunnelOnly = false) =>
        typeof u === "string"
            ? rewriteMediaUrl(u, { origin, apiOrigin: o.apiOrigin, tunnelOnly })
            : null;

    let body;
    try {
        const res = await fetchImpl(`${origin}/`, {
            method: "POST",
            headers: {
                authorization: `Api-Key ${o.internalKey}`,
                accept: "application/json",
                "content-type": "application/json",
            },
            body: JSON.stringify({
                url: o.url,
                alwaysProxy: true,
                videoQuality: "720",
                // cobalt turns an X/Twitter "gif" (really an mp4) into a real .gif by
                // default. Every consumer here (the studio's player, the posters, the
                // webp encoder) wants the mp4: a GIF stored under a video type is a file
                // AVFoundation cannot open.
                convertGif: false,
            }),
            signal: o.signal,
        });
        body = await res.json();
    } catch {
        throw new JobError("error.webp.upstream");
    }

    switch (body?.status) {
        case "tunnel": {
            const url = rw(body.url, true);
            if (!url) throw new JobError("error.webp.bad_source");
            return { url, filename: body.filename ?? null };
        }
        case "redirect": {
            const url = rw(body.url);
            if (!url) throw new JobError("error.webp.bad_source");
            return { url, filename: body.filename ?? null };
        }
        case "picker": {
            const items = Array.isArray(body.picker) ? body.picker : [];
            if (o.picker) {
                return {
                    url: null,
                    filename: null,
                    picker: items.map((it, i) => ({
                        i,
                        type: it?.type === "photo" || it?.type === "gif" ? it.type : "video",
                        url: rw(it?.url),
                    })),
                };
            }
            // a video item first; a "gif" (e.g. an X/Twitter GIF, which is an
            // mp4) is the next best thing for an animated WebP
            const item =
                items.find((i) => i?.type === "video") ??
                items.find((i) => i?.type === "gif");
            if (!item) throw new JobError("error.webp.no_video");
            const url = rw(item.url);
            if (!url) throw new JobError("error.webp.bad_source");
            return { url, filename: null };
        }
        case "error": {
            const code = body.error?.code;
            throw new JobError(
                typeof code === "string" ? code : "error.webp.upstream",
            );
        }
        case "local-processing":
            throw new JobError("error.webp.unsupported");
        default:
            throw new JobError("error.webp.upstream");
    }
}

// --- download ----------------------------------------------------------------

/**
 * Streams `url` to `dest`, refusing anything over `maxBytes`.
 * `onResponse` sees the response (headers) before the body is read.
 * `onProgress(bytes, total)` reports how much has been written so far, throttled
 * to once per PROGRESS_BYTES or PROGRESS_MS, and once more at the end; `total`
 * is the response's content-length when it sent one, else null.
 * @param {{url: string, dest: string, maxBytes?: number,
 *          fetchImpl?: typeof fetch, signal?: AbortSignal,
 *          onResponse?: (res: Response) => void,
 *          onProgress?: (bytes: number, total: number | null) => void,
 *          acceptHead?: (head: Buffer) => boolean}} o `acceptHead` sees the first HEAD_BYTES of the body (or all of a
 *          shorter one) as soon as they arrive; false ends the download there with `error.webp.bad_source`
 * @returns {Promise<number>} bytes written
 */
export async function downloadToFile(o) {
    const fetchImpl = o.fetchImpl ?? fetch;
    const maxBytes = o.maxBytes ?? MAX_DOWNLOAD_BYTES;

    let res;
    try {
        // -seekable 0 is an ffmpeg concern; here a plain GET works because the
        // whole file lands on disk before ffmpeg reads it.
        res = await fetchImpl(o.url, { signal: o.signal });
    } catch (e) {
        if (e instanceof JobError) throw e; // a refusal by the fetch (makeSafeFetch)
        if (isAbort(e)) throw new JobError("error.webp.timeout");
        throw new JobError("error.webp.download_failed");
    }
    if (!res.ok || !res.body) throw new JobError("error.webp.download_failed");
    o.onResponse?.(res);

    const declared = Number(res.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > maxBytes) {
        await res.body.cancel().catch(() => {});
        throw new JobError("error.webp.too_large");
    }

    const total = Number.isFinite(declared) && declared > 0 ? declared : null;
    let n = 0;
    let reportedBytes = 0;
    let reportedAt = Date.now();
    const report = (force) => {
        if (!o.onProgress) return;
        const now = Date.now();
        if (force || n - reportedBytes >= PROGRESS_BYTES || now - reportedAt >= PROGRESS_MS) {
            reportedBytes = n;
            reportedAt = now;
            try {
                o.onProgress(n, total);
            } catch {
                // a progress callback must never fail the download
            }
        }
    };
    let head = Buffer.alloc(0);
    let headChecked = !o.acceptHead;
    const counter = new Transform({
        transform(chunk, _enc, cb) {
            n += chunk.length;
            if (n > maxBytes) return cb(new JobError("error.webp.too_large"));
            if (!headChecked) {
                head = Buffer.concat([head, chunk.subarray(0, HEAD_BYTES - head.length)]);
                if (head.length >= HEAD_BYTES) {
                    headChecked = true;
                    if (!o.acceptHead?.(head)) return cb(new JobError("error.webp.bad_source"));
                }
            }
            report(false);
            cb(null, chunk);
        },
        flush(cb) {
            // a body shorter than HEAD_BYTES is judged whole
            if (!headChecked && !o.acceptHead?.(head)) return cb(new JobError("error.webp.bad_source"));
            cb();
        },
    });

    try {
        await pipeline(
            Readable.fromWeb(/** @type {any} */ (res.body)),
            counter,
            createWriteStream(o.dest),
        );
    } catch (e) {
        if (e instanceof JobError) throw e;
        if (isAbort(e)) throw new JobError("error.webp.timeout");
        throw new JobError("error.webp.download_failed");
    }
    report(true);
    return n;
}

function isAbort(e) {
    return e?.name === "AbortError" || e?.name === "TimeoutError";
}

// --- WebP inspection ----------------------------------------------------------

/**
 * Reads canvas size, frame count and total duration straight from the RIFF
 * container (no ffprobe in the image). Returns null when it is not a WebP.
 * A still WebP without a VP8X chunk reports width/height 0.
 * @param {Buffer} buf
 */
export function parseWebp(buf) {
    if (
        buf.length < 12 ||
        buf.toString("latin1", 0, 4) !== "RIFF" ||
        buf.toString("latin1", 8, 12) !== "WEBP"
    ) {
        return null;
    }
    let width = 0;
    let height = 0;
    let animated = false;
    let frames = 0;
    let durationMs = 0;

    let pos = 12;
    while (pos + 8 <= buf.length) {
        const fourcc = buf.toString("latin1", pos, pos + 4);
        const size = buf.readUInt32LE(pos + 4);
        const data = pos + 8;
        if (fourcc === "VP8X" && data + 10 <= buf.length) {
            animated = animated || (buf[data] & 0x02) !== 0;
            width = 1 + buf.readUIntLE(data + 4, 3);
            height = 1 + buf.readUIntLE(data + 7, 3);
        } else if (fourcc === "ANIM") {
            animated = true;
        } else if (fourcc === "ANMF" && data + 15 <= buf.length) {
            frames++;
            durationMs += buf.readUIntLE(data + 12, 3);
        }
        pos = data + size + (size & 1);
    }
    return { width, height, animated, frames, durationMs };
}

// --- slideshow (APP-API-CONTRACT 18.5 / 18.7, apple/CONTRACT-GALLERY.md section 6) --------------

export const SLIDESHOW_FPS = 30;
/** The crossfade between two slides; every slide but the last runs this much longer to make room. */
export const FADE_SECONDS = 0.3;
export const MAX_SLIDESHOW_SECONDS = 180;
/** The videos and gifs of one slideshow together (the stills are not counted here): they cost per second of decode, scale and blur. */
export const MAX_SLIDESHOW_MOTION_SECONDS = 60;
export const MAX_SLIDESHOW_INPUTS = 20;
/** `n` of `PUT /slideshow/:id/inputs/:n`: 0-19. */
export const SLIDESHOW_N_RE = /^(?:[0-9]|1[0-9])$/;
export const MAX_STILL_SECONDS = 15;
/** The shortest a photo is shown (owner interview 2026-10-07; was 1 s). */
export const MIN_STILL_SECONDS = 0.5;
/** A slideshow WEBP stops here (the mp4 goes to MAX_SLIDESHOW_SECONDS): CONTRACT-GALLERY R6 / 6.2. */
export const MAX_WEBP_SLIDESHOW_SECONDS = 60;

/**
 * Re-validates the body of `POST /slideshow/:id/start`: `{width, height, fade, sound, slides: [{n, seconds|null}]}` and,
 * for the webp (APP-API-CONTRACT 18.10), `format: "webp"` with `quality` (default med) and `fps` (default 15). `format`
 * absent = "mp4", which takes neither `quality` nor `fps`. width/height even, 16-1920 (a webp's width 320 or 480);
 * `slides` 1-20 entries with unique n 0-19; `seconds` 0.5-15 for a still, null for a video or gif (own length); the
 * stills together at most 180 s for the mp4 and 60 s for the webp (a video's length is added once it is probed); a webp
 * has no sound. Returns the normalised body (an mp4's has no `format`, exactly as it came) or null.
 * @param {any} b
 * @returns {{width: number, height: number, fade: boolean, sound: "none" | "own",
 *            slides: {n: number, seconds: number | null}[],
 *            format?: "webp", quality?: "low" | "med" | "high", fps?: number} | null}
 */
export function validateSlideshowStart(b) {
    if (typeof b !== "object" || b === null) return null;
    const { width, height } = b;
    for (const d of [width, height]) {
        if (!Number.isInteger(d) || d < 16 || d > 1920 || d % 2 !== 0) return null;
    }
    if (typeof b.fade !== "boolean") return null;
    if (b.sound !== "none" && b.sound !== "own") return null;
    if (b.format !== undefined && b.format !== "mp4" && b.format !== "webp") return null;
    const webp = b.format === "webp";
    /** @type {{quality?: "low" | "med" | "high", fps?: number}} */
    let enc = {};
    if (webp) {
        if (b.sound !== "none" || ![320, 480].includes(width)) return null;
        const quality = b.quality === undefined ? "med" : b.quality;
        if (typeof quality !== "string" || !Object.hasOwn(QUALITY, quality)) return null;
        const fps = b.fps === undefined ? 15 : b.fps;
        if (!Number.isInteger(fps) || fps < 10 || fps > 25) return null;
        enc = { quality, fps };
    } else if (b.quality !== undefined || b.fps !== undefined) {
        return null;
    }
    if (!Array.isArray(b.slides) || b.slides.length < 1 || b.slides.length > MAX_SLIDESHOW_INPUTS) return null;
    const seen = new Set();
    let total = 0;
    const slides = [];
    for (const sl of b.slides) {
        if (typeof sl !== "object" || sl === null) return null;
        if (!Number.isInteger(sl.n) || sl.n < 0 || sl.n >= MAX_SLIDESHOW_INPUTS || seen.has(sl.n)) return null;
        seen.add(sl.n);
        if (sl.seconds === null) {
            slides.push({ n: sl.n, seconds: null });
            continue;
        }
        if (typeof sl.seconds !== "number" || !Number.isFinite(sl.seconds)) return null;
        if (sl.seconds < MIN_STILL_SECONDS || sl.seconds > MAX_STILL_SECONDS) return null;
        total += sl.seconds;
        slides.push({ n: sl.n, seconds: sl.seconds });
    }
    if (total > (webp ? MAX_WEBP_SLIDESHOW_SECONDS : MAX_SLIDESHOW_SECONDS) + 1e-6) return null;
    return { width, height, fade: b.fade, sound: b.sound, slides, ...(webp ? { format: "webp", ...enc } : {}) };
}

/** Whether `ffmpeg -i` stderr lists an audio stream. */
export function parseHasAudio(stderr) {
    return /Stream #\d+:\d+.*Audio:/.test(stderr);
}

/**
 * Whether a source of `srcW`x`srcH` needs the blurred fill in a `width`x`height` frame: not when
 * its aspect already matches (within 0.4 %), then it is simply scaled. Unknown size: yes.
 * @param {number | null} srcW @param {number | null} srcH @param {number} width @param {number} height
 */
export function needsBlur(srcW, srcH, width, height) {
    if (!srcW || !srcH) return true;
    return Math.abs(srcW / srcH - width / height) / (width / height) >= 0.004;
}

/** The blurred fill is made on a copy this many times smaller than the frame, then scaled back up (measured: far less CPU and memory for a blur nobody can tell apart). */
export const BLUR_DOWNSCALE = 8;

/** The downscaled fill's size: the frame / BLUR_DOWNSCALE, even, at least 16 (so the box blur's chroma limit holds). */
export function blurSize(width, height) {
    const d = (n) => Math.max(16, Math.round(n / BLUR_DOWNSCALE / 2) * 2);
    return { w: d(width), h: d(height) };
}

/** boxblur's radius on the downscaled copy (24 at 1080 px is 3 at 1/8), never over a quarter of its shorter side. */
export function blurRadius(width, height) {
    const { w, h } = blurSize(width, height);
    return Math.max(1, Math.min(Math.round(24 / BLUR_DOWNSCALE), Math.floor(Math.min(w, h) / 4)));
}

/**
 * One filter-graph fragment that fits `[inL]` into `width`x`height` and names the result `[outL]`:
 * a straight scale when the aspect matches, else the item centred on a blurred, darkened copy of
 * itself (CONTRACT-GALLERY 6.1). The blurred fill is cut and blurred on a copy 1/8 the frame's size and
 * scaled back up, which costs a small fraction of blurring the full frame. `pre` keeps the labels of
 * several fragments apart.
 * @param {{inL: string, outL: string, pre: string, width: number, height: number, blur: boolean}} o
 */
export function fillGraph(o) {
    const { inL, outL, pre, width: w, height: h } = o;
    if (!o.blur) return `[${inL}]scale=${w}:${h}:flags=lanczos,setsar=1[${outL}]`;
    const r = blurRadius(w, h);
    const { w: sw, h: sh } = blurSize(w, h);
    return (
        `[${inL}]split=2[${pre}b][${pre}f];` +
        `[${pre}b]scale=${sw}:${sh}:force_original_aspect_ratio=increase:flags=bilinear,crop=${sw}:${sh},boxblur=${r}:2,eq=brightness=-0.08,scale=${w}:${h}:flags=bilinear[${pre}bg];` +
        `[${pre}f]scale=${w}:${h}:force_original_aspect_ratio=decrease[${pre}fg];` +
        `[${pre}bg][${pre}fg]overlay=(W-w)/2:(H-h)/2,setsar=1[${outL}]`
    );
}

/**
 * ffmpeg argv that composes one still ONCE into a frame-sized JPEG (`-q:v 2`, 4:2:0 full range).
 * @param {{input: string, output: string, width: number, height: number, blur: boolean}} j
 */
export function buildComposeArgs(j) {
    return [
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        "-i", j.input,
        "-filter_complex", `${fillGraph({ inL: "0:v", outL: "fit", pre: "c", width: j.width, height: j.height, blur: j.blur })};[fit]format=yuvj420p[out]`,
        "-map", "[out]",
        "-frames:v", "1",
        "-q:v", "2",
        "-f", "image2",
        "-update", "1",
        "-y",
        j.output,
    ];
}

/**
 * @typedef {{kind: "still", file: string, seconds: number}
 *         | {kind: "motion", file: string, seconds: number, hasAudio: boolean, blur: boolean}} SlideshowSegment
 *   a still is already composed at the frame size; a motion item (video or gif) is its own length
 *   (`seconds` = the probed duration) and is fitted inside the graph.
 */

/**
 * ffmpeg argv that sequences the segments, crossfades (`xfade` 0.3 s, offset = the sum of the
 * previous slides) or cuts (`concat`), drops duplicate frames (`mpdecimate=…:max=15`, `-fps_mode vfr`)
 * and encodes (libx264 veryfast stillimage crf 20, yuv420p, faststart). Every slide but the last
 * runs 0.3 s longer when fading, so the output is the sum of the slides. Audio (`sound: "own"` and
 * at least one motion item with a track): each item's own, `anullsrc` under the others, joined
 * with `acrossfade` / `concat`; otherwise no audio at all.
 * @param {{segments: SlideshowSegment[], width: number, height: number, fade: boolean,
 *          sound: "none" | "own", output: string, fps?: number}} j
 */
export function buildSlideshowArgs(j) {
    const fps = j.fps ?? SLIDESHOW_FPS;
    const n = j.segments.length;
    const fade = j.fade && n > 1;
    const withAudio = j.sound === "own" && j.segments.some((s) => s.kind === "motion" && s.hasAudio);
    // (an input option applies to the NEXT -i only, so the whitelist goes in front of every one)
    const args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats"];
    const parts = [];
    /** the length each slide's stream really runs: fading makes every slide but the last 0.3 s longer */
    const lens = j.segments.map((s, i) => s.seconds + (fade && i < n - 1 ? FADE_SECONDS : 0));
    j.segments.forEach((s, i) => {
        if (s.kind === "still") {
            args.push("-protocol_whitelist", "file,pipe", "-loop", "1", "-framerate", String(fps), "-t", dec(lens[i]), "-i", s.file);
            parts.push(`[${i}:v]fps=${fps},format=yuv420p,setsar=1,setpts=PTS-STARTPTS[v${i}]`);
        } else {
            args.push("-protocol_whitelist", "file,pipe", "-i", s.file);
            parts.push(`[${i}:v]fps=${fps}[r${i}]`);
            parts.push(fillGraph({ inL: `r${i}`, outL: `f${i}`, pre: `m${i}`, width: j.width, height: j.height, blur: s.blur }));
            // padded generously with the last frame, then cut to exactly this slide's length
            parts.push(
                `[f${i}]format=yuv420p,tpad=stop_mode=clone:stop_duration=3,trim=duration=${dec(lens[i])},setpts=PTS-STARTPTS[v${i}]`,
            );
        }
    });
    let cur = "v0";
    if (n > 1) {
        if (fade) {
            let at = 0;
            for (let i = 1; i < n; i++) {
                at += j.segments[i - 1].seconds;
                parts.push(`[${cur}][v${i}]xfade=transition=fade:duration=${FADE_SECONDS}:offset=${dec(at)}[x${i}]`);
                cur = `x${i}`;
            }
        } else {
            parts.push(`${j.segments.map((_, i) => `[v${i}]`).join("")}concat=n=${n}:v=1:a=0[xc]`);
            cur = "xc";
        }
    }
    // mpdecimate (max=15) drops runs of identical frames, so a still's tail is dropped: the last
    // kept frame can be up to 0.5 s before the end and the file comes out that much short of the plan
    // (measured: 4.6 s for a planned 5.0 s, 8.7 for 9.2). The last two frames therefore carry a
    // 16x8 px mark in the top-left corner (a black-blend block beside a white-blend one, so any
    // pixels change), which makes mpdecimate keep the first of them; the file then ends within one
    // frame of the plan. Not visible at 30 fps for 0.07 s.
    const total = j.segments.reduce((t, s) => t + s.seconds, 0);
    const markAt = dec(Math.max(0, total - 0.085));
    parts.push(
        `[${cur}]drawbox=x=0:y=0:w=8:h=8:color=black@0.5:t=fill:enable='gte(t,${markAt})',` +
            `drawbox=x=8:y=0:w=8:h=8:color=white@0.5:t=fill:enable='gte(t,${markAt})',` +
            `mpdecimate=hi=64:lo=32:frac=0.33:max=15[vout]`,
    );

    if (withAudio) {
        j.segments.forEach((s, i) => {
            const len = dec(lens[i]);
            if (s.kind === "motion" && s.hasAudio) {
                // the track is read from the same input as the picture (an `a` of this input)
                parts.push(
                    `[${i}:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=${len},asetpts=PTS-STARTPTS[a${i}]`,
                );
            } else {
                parts.push(`anullsrc=r=44100:cl=stereo,atrim=duration=${len},asetpts=PTS-STARTPTS[a${i}]`);
            }
        });
        let a = "a0";
        if (n > 1) {
            if (fade) {
                for (let i = 1; i < n; i++) {
                    parts.push(`[${a}][a${i}]acrossfade=d=${FADE_SECONDS}[ax${i}]`);
                    a = `ax${i}`;
                }
            } else {
                parts.push(`${j.segments.map((_, i) => `[a${i}]`).join("")}concat=n=${n}:v=0:a=1[axc]`);
                a = "axc";
            }
        }
        parts.push(`[${a}]anull[aout]`);
    }

    args.push("-filter_complex", parts.join(";"), "-map", "[vout]");
    if (withAudio) args.push("-map", "[aout]", "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2");
    else args.push("-an");
    args.push(
        "-fps_mode", "vfr",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "stillimage",
        // no B-frames: with frames kept up to 0.5 s apart (mpdecimate) the B-frame reordering delay
        // is counted in KEPT frames, so the mp4's duration (from the decode timestamps) came out
        // up to 1.6 s short of the last picture
        "-bf", "0",
        "-crf", "20",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-threads", "2",
        "-progress", "pipe:1",
        "-y",
        j.output,
    );
    return args;
}

/**
 * Seconds encoded so far from a chunk of ffmpeg `-progress` output (the last `out_time_us=` /
 * `out_time_ms=` line; both are microseconds), or null when the chunk has none (or "N/A").
 * @param {string} text
 * @returns {number | null}
 */
export function parseProgressSeconds(text) {
    let last = null;
    for (const m of text.matchAll(/out_time_(?:us|ms)=(-?\d+)/g)) last = Number(m[1]) / 1e6;
    return last === null || !Number.isFinite(last) ? null : Math.max(0, last);
}

/**
 * The whole slideshow render: probes the inputs, composes each still once at the frame size, then
 * one ffmpeg run sequences, crossfades and encodes. The caller owns the files in `dir` (inputs as
 * `input-<n>`); this writes `s-<k>.jpg` next to them and the result to `output`. One shared
 * budget (`timeoutMs`). Throws JobError: error.webp.invalid_params (a still without seconds, a
 * video with), error.webp.bad_source (an input that is no picture, or no length), error.webp.too_long
 * (over 180 s with the videos counted), error.webp.timeout, error.webp.encode_failed,
 * error.webp.too_large (over `maxOutputBytes`).
 * @param {{ffmpegBin: string, dir: string, output: string,
 *          files: Map<number, string>,
 *          plan: {width: number, height: number, fade: boolean, sound: "none" | "own",
 *                 slides: {n: number, seconds: number | null}[]},
 *          probeAV: (file: string) => Promise<{duration: number | null, width: number | null, height: number | null, hasAudio: boolean}>,
 *          timeoutMs: number, maxOutputBytes?: number, spawnImpl?: typeof spawn,
 *          onChild?: (c: import("node:child_process").ChildProcess | undefined) => void,
 *          onPhase?: (phase: "composing" | "encoding", p: {done: number, total: number}) => void}} o
 * @returns {Promise<{bytes: number, duration: number | null, width: number | null, height: number | null}>}
 */
export async function renderSlideshow(o) {
    const deadline = Date.now() + o.timeoutMs;
    const left = () => deadline - Date.now();
    const { width, height } = o.plan;

    /** @type {{n: number, file: string, still: boolean, seconds: number | null, info: Awaited<ReturnType<typeof o.probeAV>>}[]} */
    const slides = [];
    for (const sl of o.plan.slides) {
        const file = o.files.get(sl.n);
        if (!file) throw new JobError("error.webp.invalid_params");
        const head = await readFileHead(file, 12);
        const sniffed = sniffType(head);
        const still = sniffed?.type === "image";
        if (still !== (sl.seconds !== null)) throw new JobError("error.webp.invalid_params");
        const info = await o.probeAV(file);
        if (info.width === null || info.height === null) throw new JobError("error.webp.bad_source");
        if (!still && !(info.duration && info.duration > 0)) throw new JobError("error.webp.bad_source");
        slides.push({ n: sl.n, file, still, seconds: sl.seconds, info });
    }
    const total = slides.reduce((t, s) => t + (s.still ? /** @type {number} */ (s.seconds) : /** @type {number} */ (s.info.duration)), 0);
    if (total > MAX_SLIDESHOW_SECONDS + TOO_LONG_SLACK) throw new JobError("error.webp.too_long");
    // the videos inside a slideshow are decoded, scaled and blurred frame by frame: a cap of their own
    // (the stills are composed once and cost nothing per second)
    const motion = slides.filter((s) => !s.still).reduce((t, s) => t + /** @type {number} */ (s.info.duration), 0);
    if (motion > MAX_SLIDESHOW_MOTION_SECONDS + TOO_LONG_SLACK) throw new JobError("error.webp.too_long");

    const stills = slides.filter((s) => s.still);
    o.onPhase?.("composing", { done: 0, total: stills.length });
    /** @type {SlideshowSegment[]} */
    const segments = [];
    let composed = 0;
    for (const s of slides) {
        if (!s.still) {
            segments.push({
                kind: "motion",
                file: s.file,
                seconds: /** @type {number} */ (s.info.duration),
                hasAudio: s.info.hasAudio,
                blur: needsBlur(s.info.width, s.info.height, width, height),
            });
            continue;
        }
        const out = path.join(o.dir, `s-${composed}.jpg`);
        await runProcess({
            spawnImpl: o.spawnImpl,
            bin: o.ffmpegBin,
            args: buildComposeArgs({ input: s.file, output: out, width, height, blur: needsBlur(s.info.width, s.info.height, width, height) }),
            timeoutMs: left(),
            label: "slideshow compose",
            onChild: o.onChild,
        });
        if (!((await stat(out).catch(() => null))?.size > 0)) throw new JobError("error.webp.encode_failed");
        segments.push({ kind: "still", file: out, seconds: /** @type {number} */ (s.seconds) });
        o.onPhase?.("composing", { done: ++composed, total: stills.length });
    }

    o.onPhase?.("encoding", { done: 0, total });
    let pending = "";
    await runProcess({
        spawnImpl: o.spawnImpl,
        bin: o.ffmpegBin,
        args: buildSlideshowArgs({ segments, width, height, fade: o.plan.fade, sound: o.plan.sound, output: o.output }),
        timeoutMs: left(),
        label: "slideshow encode",
        onChild: o.onChild,
        onStdout: (chunk) => {
            // a chunk may end mid-line: only whole lines are read
            pending += chunk;
            const cut = pending.lastIndexOf("\n");
            if (cut < 0) return;
            const secs = parseProgressSeconds(pending.slice(0, cut));
            pending = pending.slice(cut + 1);
            if (secs !== null) o.onPhase?.("encoding", { done: Math.min(+secs.toFixed(1), total), total });
        },
    });
    const size = (await stat(o.output).catch(() => null))?.size ?? 0;
    if (!(size > 0)) throw new JobError("error.webp.encode_failed");
    if (size > (o.maxOutputBytes ?? MAX_FETCH_BYTES)) throw new JobError("error.webp.too_large");
    const info = await o.probeAV(o.output);
    o.onPhase?.("encoding", { done: total, total });
    return { bytes: size, duration: info.duration, width: info.width, height: info.height };
}

/** The first `n` bytes of a file (fewer when it is shorter). */
export async function readFileHead(file, n) {
    const fh = await open(file, "r");
    try {
        const buf = Buffer.alloc(n);
        const { bytesRead } = await fh.read(buf, 0, n, 0);
        return buf.subarray(0, bytesRead);
    } finally {
        await fh.close();
    }
}
