// Pure(ish) pieces of the animated-WebP helper, split from supervisor.js so
// they can be unit-tested with a stubbed fetch. Plain Node ESM, no dependencies.

import { createHash, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, readdir, rm, stat } from "node:fs/promises";
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

/**
 * ffmpeg argv that writes ONE JPEG frame at `at` seconds: scaled so the longer side is at
 * most POSTER_MAX_SIDE (never upscaled; the rotation metadata is applied first, so a phone
 * clip comes out upright), square pixels, 4:2:0 full-range (what every JPEG decoder takes).
 * `-ss` before `-i` seeks the input (fast on a local file), the protocol whitelist keeps
 * ffmpeg on local files.
 * @param {{input: string, output: string, at: number}} j
 */
export function buildPosterArgs(j) {
    const side = POSTER_MAX_SIDE;
    return [
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-protocol_whitelist", "file,pipe",
        "-ss", dec(j.at),
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
 * @param {{spawnImpl?: typeof spawn, bin: string, args: string[], cwd?: string,
 *          timeoutMs: number, label: string,
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
                stdio: ["ignore", "ignore", "pipe"],
            });
        } catch {
            return reject(new JobError("error.webp.encode_failed"));
        }
        o.onChild?.(child);
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

/**
 * POSTs the link to the local cobalt (with the internal key) and works out
 * which file to download. Throws JobError with the code to report.
 * @param {{url: string, internalKey: string, fetchImpl?: typeof fetch,
 *          origin?: string, apiOrigin?: string, signal?: AbortSignal}} o
 * @returns {Promise<{url: string, filename: string | null}>}
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
 *          onProgress?: (bytes: number, total: number | null) => void}} o
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
    const counter = new Transform({
        transform(chunk, _enc, cb) {
            n += chunk.length;
            if (n > maxBytes) return cb(new JobError("error.webp.too_large"));
            report(false);
            cb(null, chunk);
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
