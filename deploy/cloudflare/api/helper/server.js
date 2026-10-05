// The helper's HTTP API on port 9100, split from supervisor.js (which also
// starts cobalt as a child process) so it can be exercised in tests with
// stubbed cobalt / download / ffmpeg pieces. Plain Node ESM, no dependencies.
//
// Every request needs x-internal-key (the Worker's COBALT_API_KEY); without it
// 403. Only the Durable Object can reach the port. ONE job runs at a time: a
// pending WebP job, upload or fetch makes every new one answer 429.
//
//   POST   /jobs {id,url,start,length?,width,fps,quality}  -> 202 | 429 busy
//                      (no length = to the end of the video; WEBP_MAX_SECONDS gates it)
//   POST   /jobs/upload?id=&start=&length=&width=&fps=15&quality=
//                      body = the video bytes (streamed to disk, at most 200 MB);
//                      the same encode as /jobs, skipping cobalt and the download
//                      -> 202 | 400 | 413 | 429 busy
//   GET    /jobs/:id          -> {status:"pending", phase, frames_done, frames_total} |
//                      {status:"done",...} | {status:"error",error:{code}}
//                      phase: "fetching" (link jobs: cobalt + download) | "decode" (ffmpeg
//                      writing PNG frames, frames_done counts the files on disk) | "pack"
//                      (img2webp, frames_done = frames_total) | null (not known yet)
//   GET    /jobs/:id/file     -> image/webp bytes (once done)
//   DELETE /jobs/:id          -> removes the job and its files
//
// cobalt studio (saving a source video for later renders):
//   POST   /fetch {id,url}    -> 202 | 429 busy   (resolve via cobalt, download at
//                      most 200 MB to /tmp/fetch/<id>/in, probe duration/size)
//   GET    /fetch/:id         -> {status:"pending", stage:"downloading"|"probing", bytes, total} |
//                      {status:"done", bytes, contentType,
//                      ext, duration, width, height, title, service} | {status:"error",error:{code}}
//   GET    /fetch/:id/file    -> the video bytes with content-length (once done)
//   DELETE /fetch/:id         -> removes it and its file
//
// Live Activity push fallback (APP-API-CONTRACT.md section 8.4, text binding
// APNS_VIA="helper"): a dumb HTTP/2 relay to Apple. The Durable Object signs the
// JWT and builds the request; this only forwards bytes, so no APNs secret ever
// enters the container.
//   POST   /apns {host,path,headers,body}  -> 200 {status, reason, apns_id} (Apple's
//                      answer; reason from its JSON body) | 400 (any host but
//                      api.push.apple.com / api.sandbox.push.apple.com, a path that
//                      is not /3/device/<token>, a bad body) | 502 transport failure
//                      One node:http2 session per host, reconnected on goaway or
//                      error, 2 s budget for the whole relay (both tries). The helper never logs headers or bodies.
//
// cobalt library (measuring a file that is already stored, see the Worker's
// POST /library/adopt):
//   POST   /probe?id=         body = the video bytes (streamed to /tmp/probe/<id>,
//                      at most 200 MB), probed with ffmpeg, deleted again; answers
//                      at the end of the request -> 200 {duration,width,height}
//                      (duration may be null) | 400 error.studio.not_video (no
//                      video stream, or empty) | 413 | 429 busy
//
// Poster frames (APP-API-CONTRACT.md section 13): a thumbnail for a stored video.
//   POST   /poster?id=        body = the video bytes (streamed to /tmp/poster/<id>, at most
//                      200 MB); ffmpeg writes ONE JPEG (frame at 10 % of the duration, at most
//                      3 s in; longer side at most 720 px, never upscaled; rotation applied),
//                      the file is deleted, and the answer IS the JPEG: 200 image/jpeg with
//                      content-length | 400 error.studio.not_video | 413 error.studio.too_large
//                      | 422 error.poster.failed (ffmpeg made no frame) | 429 busy (one job at
//                      a time, like /probe) | 502 error.studio.upload_failed

import { spawn } from "node:child_process";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, open, readFile, readdir, rm, stat } from "node:fs/promises";
import http from "node:http";
import http2 from "node:http2";
import { createRequire } from "node:module";
import path from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { cropToPixels } from "./crop.js";
import {
    COBALT_ORIGIN,
    FRAME_RE,
    ID_RE,
    JobError,
    MAX_FETCH_BYTES,
    MAX_OUTPUT_BYTES,
    MAX_POSTER_BYTES,
    VIDEO_TYPES,
    downloadToFile,
    encodeAnimatedWebp,
    isGifHead,
    keyMatches,
    parseVideoInfo,
    buildPosterArgs,
    parseWebp,
    planClip,
    posterTime,
    runProcess,
    resolveSource,
    serviceFromUrl,
    studioCode,
    titleFromFilename,
    validateEncodeFields,
    validateFetchInput,
    validateJobInput,
    videoExt,
} from "./lib.js";

/** The first `n` bytes of a file (fewer when it is shorter). */
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

// The relay's whole budget for one push (see APNS_TIMEOUT_MS inside createHelper).
export const APNS_DEFAULT_TIMEOUT_MS = 2000;

/**
 * @typedef {{id: string, status: "pending"|"done"|"error", createdAt: number,
 *   dir: string, error?: {code: string}, result?: any,
 *   proc?: import("node:child_process").ChildProcess,
 *   progress?: {phase: "fetching"|"decode"|"pack", total: number|null, frames?: number, framesDir?: string},
 *   fetchProgress?: {stage: "downloading"|"probing", bytes: number, total: number|null}}} Job
 */

/**
 * @param {{
 *   appDir?: string, internalKey?: string, workDir?: string, fetchDir?: string, probeDir?: string,
 *   posterDir?: string, posterTimeoutMs?: number,
 *   cobaltOrigin?: string, apiOrigin?: string,
 *   ffmpegTimeoutMs?: number, downloadTimeoutMs?: number, fetchTimeoutMs?: number,
 *   maxFetchBytes?: number, keepJobs?: number, jobTtlMs?: number,
 *   ffmpegPath?: () => string, img2webpPath?: () => string,
 *   probe?: (input: string) => Promise<{duration: number|null, width: number|null, height: number|null}>,
 *   waitForCobalt?: () => Promise<void>,
 *   resolveSource?: typeof resolveSource,
 *   downloadToFile?: typeof downloadToFile,
 *   encodeAnimatedWebp?: typeof encodeAnimatedWebp,
 *   apnsOrigin?: (host: string) => string,
 *   apnsTimeoutMs?: number,
 * }} [opts] everything but the paths and the key defaults to the real thing;
 *   tests replace the pieces that need cobalt, the network or ffmpeg.
 */
export function createHelper(opts = {}) {
    const APP_DIR = opts.appDir ?? "/app";
    const INTERNAL_KEY = opts.internalKey ?? "";
    const WORK_DIR = opts.workDir ?? "/tmp/webp";
    const FETCH_DIR = opts.fetchDir ?? "/tmp/fetch";
    const PROBE_DIR = opts.probeDir ?? "/tmp/probe";
    const POSTER_DIR = opts.posterDir ?? "/tmp/poster";
    // one frame out of a local file: a second or two; the budget only stops a hung ffmpeg
    const POSTER_TIMEOUT_MS = opts.posterTimeoutMs ?? 30_000;
    const COBALT = opts.cobaltOrigin ?? COBALT_ORIGIN;
    const FFMPEG_TIMEOUT_MS = opts.ffmpegTimeoutMs ?? 240_000;
    const DOWNLOAD_TIMEOUT_MS = opts.downloadTimeoutMs ?? 120_000;
    // 200 MB over the container's network takes longer than a 720p clip
    const FETCH_TIMEOUT_MS = opts.fetchTimeoutMs ?? 240_000;
    const MAX_FETCH = opts.maxFetchBytes ?? MAX_FETCH_BYTES;
    const KEEP_JOBS = opts.keepJobs ?? 20;
    const JOB_TTL_MS = opts.jobTtlMs ?? 30 * 60_000;
    const apiOrigin = opts.apiOrigin;

    const doResolve = opts.resolveSource ?? resolveSource;
    const doDownload = opts.downloadToFile ?? downloadToFile;
    const doEncode = opts.encodeAnimatedWebp ?? encodeAnimatedWebp;
    // where the APNs hosts are reached (tests point this at a local h2c server)
    const apnsOrigin = opts.apnsOrigin ?? ((host) => `https://${host}`);
    // ONE budget for the whole relay (both tries on a stale session): at most 2 s, so the
    // helper always answers before the Durable Object gives up on it (APNS_CALL_MS = 2500
    // in src/apns.ts). A relay that outlived the DO's ceiling could still deliver a push
    // the DO had already written off, and its retry would then duplicate it.
    const APNS_TIMEOUT_MS = Math.min(opts.apnsTimeoutMs ?? APNS_DEFAULT_TIMEOUT_MS, APNS_DEFAULT_TIMEOUT_MS);

    /** @type {Map<string, Job>} insertion order = age */
    const jobs = new Map();
    /** @type {Map<string, Job>} */
    const fetches = new Map();

    /** probes and poster frames in flight (POST /probe, POST /poster): they hold the helper like a job does */
    const probing = new Set();

    const busy = () =>
        probing.size > 0 ||
        [...jobs.values(), ...fetches.values()].some((j) => j.status === "pending");

    /** @param {Map<string, Job>} map @param {Job} job */
    async function drop(map, job) {
        map.delete(job.id);
        job.proc?.kill("SIGKILL");
        await rm(job.dir, { recursive: true, force: true }).catch(() => {});
    }

    function evictOld() {
        const now = Date.now();
        for (const map of [jobs, fetches]) {
            for (const job of [...map.values()]) {
                if (job.status !== "pending" && now - job.createdAt > JOB_TTL_MS) {
                    void drop(map, job);
                }
            }
            for (const job of [...map.values()]) {
                if (map.size <= KEEP_JOBS) break;
                if (job.status !== "pending") void drop(map, job);
            }
        }
    }
    const evictTimer = setInterval(evictOld, 60_000);
    evictTimer.unref();

    const waitForCobalt =
        opts.waitForCobalt ??
        (async () => {
            for (let i = 0; i < 120; i++) {
                try {
                    await fetch(`${COBALT}/`, { signal: AbortSignal.timeout(2000) });
                    return;
                } catch {
                    await new Promise((r) => setTimeout(r, 500));
                }
            }
            throw new JobError("error.webp.upstream");
        });

    const ffmpegPath =
        opts.ffmpegPath ??
        (() => {
            if (process.env.FFMPEG_PATH) return process.env.FFMPEG_PATH;
            const req = createRequire(path.join(APP_DIR, "package.json"));
            return req("ffmpeg-static");
        });
    const img2webpPath = opts.img2webpPath ?? (() => process.env.IMG2WEBP_PATH || "img2webp");

    /**
     * Duration, width and height of a video, or nulls when ffmpeg cannot say.
     * `ffmpeg -i file` with no output prints the stream info to stderr and
     * exits 1; that is expected.
     * @param {string} input
     */
    const probe =
        opts.probe ??
        ((input) =>
            new Promise((resolve) => {
                const ff = spawn(
                    ffmpegPath(),
                    ["-nostdin", "-hide_banner", "-protocol_whitelist", "file,pipe", "-i", input],
                    { stdio: ["ignore", "ignore", "pipe"] },
                );
                let err = "";
                // The stream info sits in the first lines; keep the head.
                ff.stderr.on("data", (d) => {
                    if (err.length < 65536) err += d;
                });
                const timer = setTimeout(() => ff.kill("SIGKILL"), 15_000);
                const empty = { duration: null, width: null, height: null };
                ff.on("error", () => {
                    clearTimeout(timer);
                    resolve(empty);
                });
                ff.on("close", () => {
                    clearTimeout(timer);
                    resolve(parseVideoInfo(err));
                });
            }));

    // --- WebP jobs ---------------------------------------------------------------

    // The encode half shared by POST /jobs (after cobalt + download) and
    // POST /jobs/upload (after the body landed on disk).
    /** @param {Job} job @param {any} p @param {string} input @param {string | null} srcFilename @param {string} service */
    async function encodeJob(job, p, input, srcFilename, service) {
        const output = path.join(job.dir, "out.webp");
        const framesDir = path.join(job.dir, "frames");
        // the probe is part of "decode": the count is not known until it ends
        job.progress = { phase: "decode", total: null, framesDir };
        const info = await probe(input);
        const plan = planClip({ start: p.start, length: p.length, duration: info.duration });
        if (!plan.ok) throw new JobError(plan.code);
        // The crop (normalized, display orientation) becomes whole even pixels of the size
        // probed here (rotation applied: what ffmpeg's filter graph sees). Too small, or a
        // source whose size ffmpeg could not read, is no render.
        /** @type {import("./crop.js").CropPx | null} */
        let cropPx = null;
        if (p.crop) {
            if (info.width === null || info.height === null) throw new JobError("error.webp.encode_failed");
            cropPx = cropToPixels(p.crop, info.width, info.height);
            if (!cropPx) throw new JobError("error.webp.invalid_params");
        }
        job.progress = { phase: "decode", total: Math.max(1, Math.round(plan.seconds * p.fps)), framesDir };
        if (plan.truncated) {
            console.error(
                `[webp-helper] duration unknown for ${p.id}: encoding at most ${plan.seconds}s`,
            );
        }

        // ffmpeg -> PNG frames -> img2webp with forced keyframes (frames dir is
        // removed by encodeAnimatedWebp, success or failure); one 240 s budget.
        const enc = await doEncode({
            ffmpegBin: ffmpegPath(),
            img2webpBin: img2webpPath(),
            input,
            output,
            framesDir,
            start: p.start,
            length: plan.seconds,
            width: p.width,
            fps: p.fps,
            quality: p.quality,
            crop: cropPx,
            timeoutMs: FFMPEG_TIMEOUT_MS,
            onChild: (c) => {
                job.proc = c;
            },
            onPhase: (phase, info) => {
                if (phase === "decode") {
                    job.progress = { phase: "decode", total: info.total ?? job.progress?.total ?? null, framesDir };
                } else {
                    job.progress = { phase: "pack", total: info.frames ?? null, frames: info.frames, framesDir };
                }
            },
        });
        console.error(
            `[webp-helper] ${p.id}: ${enc.frames} frames, ${enc.frameBytes} bytes of PNG on disk at peak`,
        );
        await rm(input, { force: true });

        const { size } = await stat(output);
        if (size > MAX_OUTPUT_BYTES) throw new JobError("error.webp.too_large");

        const webp = parseWebp(await readFile(output));
        if (!webp) throw new JobError("error.webp.encode_failed");
        const base = (srcFilename || "").replace(/\.[^.]*$/, "");
        job.result = {
            bytes: size,
            width: webp.width || p.width,
            height: webp.height || 0,
            seconds: webp.frames ? Math.round(webp.durationMs / 100) / 10 : plan.seconds,
            filename: `${base || "cobalt"}.webp`,
            service,
        };
        job.status = "done";
    }

    /** @param {Job} job @param {Error} e */
    async function failJob(job, e) {
        if (!(e instanceof JobError)) console.error("[webp-helper] job failed:", e);
        // files first, then the status: a poller that sees "error" can rely on
        // the directory being gone (the job stays pending, i.e. busy, meanwhile)
        await rm(job.dir, { recursive: true, force: true }).catch(() => {});
        job.error = {
            code: e instanceof JobError ? e.code : "error.webp.encode_failed",
        };
        job.status = "error";
    }

    /** @param {Job} job @param {any} p */
    async function runJob(job, p) {
        const input = path.join(job.dir, "in");
        job.progress = { phase: "fetching", total: null };
        try {
            await mkdir(job.dir, { recursive: true });
            await waitForCobalt();

            const src = await doResolve({
                url: p.url,
                internalKey: INTERNAL_KEY,
                origin: COBALT,
                apiOrigin,
                signal: AbortSignal.timeout(60_000),
            });

            await doDownload({
                url: src.url,
                dest: input,
                signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS),
            });

            await encodeJob(job, p, input, src.filename, serviceFromUrl(p.url));
        } catch (e) {
            await failJob(job, /** @type {Error} */ (e));
        }
    }

    // --- studio fetches -----------------------------------------------------------

    /** @param {Job} job @param {{id: string, url: string}} p */
    async function runFetch(job, p) {
        const input = path.join(job.dir, "in");
        job.fetchProgress = { stage: "downloading", bytes: 0, total: null };
        try {
            await mkdir(job.dir, { recursive: true });
            await waitForCobalt();

            const src = await doResolve({
                url: p.url,
                internalKey: INTERNAL_KEY,
                origin: COBALT,
                apiOrigin,
                signal: AbortSignal.timeout(60_000),
            });

            /** @type {string | null} */
            let contentType = null;
            const bytes = await doDownload({
                url: src.url,
                dest: input,
                maxBytes: MAX_FETCH,
                signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
                onResponse: (res) => {
                    contentType = res.headers.get("content-type");
                },
                onProgress: (done, total) => {
                    job.fetchProgress = { stage: "downloading", bytes: done, total };
                },
            });

            job.fetchProgress = { stage: "probing", bytes, total: null };
            const info = await probe(input);
            // no video stream: an image, audio or a broken file is no use here
            if (info.width === null || info.height === null) {
                throw new JobError("error.webp.bad_source");
            }
            // a real GIF is labelled as one (the studio already takes `image/gif` from uploads),
            // not as an mp4 that no video player can open
            const gif = isGifHead(await readHead(input, 6));
            const ext = gif ? "gif" : videoExt({ contentType, filename: src.filename });
            job.result = {
                bytes,
                contentType: gif ? "image/gif" : VIDEO_TYPES[ext],
                ext,
                duration: info.duration,
                width: info.width,
                height: info.height,
                title: titleFromFilename(src.filename),
                service: serviceFromUrl(p.url),
            };
            job.status = "done";
        } catch (e) {
            const code = e instanceof JobError ? studioCode(e.code) : "error.webp.download_failed";
            if (!(e instanceof JobError)) console.error("[webp-helper] fetch failed:", e);
            await rm(job.dir, { recursive: true, force: true }).catch(() => {});
            job.error = { code };
            job.status = "error";
        }
    }

    // --- HTTP ---------------------------------------------------------------------

    /** @param {http.ServerResponse} res @param {number} code @param {unknown} obj */
    const send = (res, code, obj) => {
        const body = JSON.stringify(obj);
        res.writeHead(code, {
            "content-type": "application/json",
            "content-length": Buffer.byteLength(body),
        });
        res.end(body);
    };
    /** @param {http.ServerResponse} res @param {number} code @param {string} errCode */
    const fail = (res, code, errCode) =>
        send(res, code, { status: "error", error: { code: errCode } });

    // Answer without reading the request body (busy, too large, bad params): the
    // response goes out with `connection: close`, then the socket is torn down
    // so an in-flight upload stops instead of being drained.
    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res @param {number} code @param {string} errCode */
    function failAndClose(req, res, code, errCode) {
        const body = JSON.stringify({ status: "error", error: { code: errCode } });
        res.writeHead(code, {
            "content-type": "application/json",
            "content-length": Buffer.byteLength(body),
            connection: "close",
        });
        res.end(body, () => req.destroy());
    }

    /** @param {http.IncomingMessage} req */
    function readBody(req, limit = 8192) {
        return new Promise((resolve, reject) => {
            let n = 0;
            const chunks = [];
            req.on("data", (c) => {
                n += c.length;
                if (n > limit) {
                    reject(new Error("too large"));
                    req.destroy();
                } else chunks.push(c);
            });
            req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
            req.on("error", reject);
        });
    }

    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res @param {URL} url */
    async function handleUpload(req, res, url) {
        if (req.method !== "POST") return fail(res, 405, "error.webp.bad_request");
        const q = url.searchParams;
        const id = q.get("id") ?? "";
        const enc = validateEncodeFields(
            {
                start: q.get("start") ?? 0,
                length: q.get("length"),
                width: q.get("width"),
                fps: q.get("fps") ?? 15,
                quality: q.get("quality"),
                crop: q.get("crop"),
            },
            // the DO limits studio clips itself (0.5 s to 10 s)
            { minLength: 0.5 },
        );
        if (!ID_RE.test(id) || !enc) return failAndClose(req, res, 400, "error.webp.invalid_params");
        if (busy() || jobs.has(id)) return failAndClose(req, res, 429, "error.webp.busy");

        const declared = Number(req.headers["content-length"]);
        if (Number.isFinite(declared) && declared > MAX_FETCH) {
            return failAndClose(req, res, 413, "error.webp.too_large");
        }

        /** @type {Job} */
        const job = {
            id,
            status: "pending",
            createdAt: Date.now(),
            dir: path.join(WORK_DIR, id),
        };
        jobs.set(id, job);
        evictOld();
        const p = { id, ...enc };
        const input = path.join(job.dir, "in");

        // The request body goes straight to disk (a local file: moov-at-end
        // mp4s need seeking), refusing anything over the cap.
        let n = 0;
        const counter = new Transform({
            transform(chunk, _e, cb) {
                n += chunk.length;
                if (n > MAX_FETCH) cb(new JobError("error.webp.too_large"));
                else cb(null, chunk);
            },
        });
        try {
            await mkdir(job.dir, { recursive: true });
            await pipeline(req, counter, createWriteStream(input));
            if (n === 0) throw new JobError("error.webp.bad_source");
        } catch (e) {
            const code = e instanceof JobError ? e.code : "error.webp.download_failed";
            await drop(jobs, job);
            if (!res.headersSent && !res.destroyed) {
                return failAndClose(req, res, code === "error.webp.too_large" ? 413 : 400, code);
            }
            return;
        }

        send(res, 202, { status: "pending", id });
        void encodeJob(job, p, input, null, "studio").catch((e) => failJob(job, e));
    }

    // POST /probe?id=: the body goes to disk, ffmpeg reads the stream info, the
    // file is deleted. One request, one answer (the caller awaits it; a probe of
    // a stored upload is a few seconds at most).
    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res @param {URL} url */
    async function handleProbe(req, res, url) {
        if (req.method !== "POST") return fail(res, 405, "error.webp.bad_request");
        const id = url.searchParams.get("id") ?? "";
        if (!ID_RE.test(id)) return failAndClose(req, res, 400, "error.webp.invalid_params");
        if (busy()) return failAndClose(req, res, 429, "error.webp.busy");

        const declared = Number(req.headers["content-length"]);
        if (Number.isFinite(declared) && declared > MAX_FETCH) {
            return failAndClose(req, res, 413, "error.studio.too_large");
        }

        probing.add(id);
        const dir = path.join(PROBE_DIR, id);
        const input = path.join(dir, "in");
        let n = 0;
        const counter = new Transform({
            transform(chunk, _e, cb) {
                n += chunk.length;
                if (n > MAX_FETCH) cb(new JobError("error.studio.too_large"));
                else cb(null, chunk);
            },
        });
        /** @type {{duration: number|null, width: number|null, height: number|null} | null} */
        let info = null;
        let code = "";
        try {
            await mkdir(dir, { recursive: true });
            await pipeline(req, counter, createWriteStream(input));
            if (n === 0) throw new JobError("error.studio.not_video");
            info = await probe(input);
            // no video stream: audio, a document or a broken file is no use here
            if (info.width === null || info.height === null) {
                info = null;
                throw new JobError("error.studio.not_video");
            }
        } catch (e) {
            code = e instanceof JobError ? e.code : "error.studio.upload_failed";
            if (!(e instanceof JobError)) console.error("[webp-helper] probe failed:", e);
        }
        // files first, then the answer (and the helper stays busy until both):
        // whoever sees the answer can rely on the directory being gone
        await rm(dir, { recursive: true, force: true }).catch(() => {});
        probing.delete(id);
        if (res.headersSent || res.destroyed) return;
        if (info) return send(res, 200, info);
        return failAndClose(
            req,
            res,
            code === "error.studio.too_large" ? 413 : code === "error.studio.not_video" ? 400 : 502,
            code,
        );
    }

    // POST /poster?id=: the body goes to disk, ffmpeg writes one JPEG frame, the file is
    // deleted, and the JPEG is the answer (a few tens of KB). One request, one answer; the
    // helper is busy until the directory is gone (like /probe). A frame past the end of a
    // clip that reports a longer duration than it has is retried at the very start.
    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res @param {URL} url */
    async function handlePoster(req, res, url) {
        if (req.method !== "POST") return fail(res, 405, "error.webp.bad_request");
        const id = url.searchParams.get("id") ?? "";
        if (!ID_RE.test(id)) return failAndClose(req, res, 400, "error.webp.invalid_params");
        if (busy()) return failAndClose(req, res, 429, "error.webp.busy");

        const declared = Number(req.headers["content-length"]);
        if (Number.isFinite(declared) && declared > MAX_FETCH) {
            return failAndClose(req, res, 413, "error.studio.too_large");
        }

        probing.add(id);
        const dir = path.join(POSTER_DIR, id);
        const input = path.join(dir, "in");
        const output = path.join(dir, "poster.jpg");
        let n = 0;
        const counter = new Transform({
            transform(chunk, _e, cb) {
                n += chunk.length;
                if (n > MAX_FETCH) cb(new JobError("error.studio.too_large"));
                else cb(null, chunk);
            },
        });
        /** @param {number} at */
        const frame = async (at) => {
            await rm(output, { force: true });
            try {
                await runProcess({
                    bin: ffmpegPath(),
                    args: buildPosterArgs({ input, output, at }),
                    timeoutMs: POSTER_TIMEOUT_MS,
                    label: `poster ${id}`,
                });
            } catch (e) {
                // a timeout is final; any other failure may just be a seek past the end
                if (e instanceof JobError && e.code === "error.webp.timeout") throw e;
                return false;
            }
            return (await stat(output).catch(() => null))?.size > 0;
        };
        /** @type {Buffer | null} */
        let jpeg = null;
        let code = "";
        try {
            await mkdir(dir, { recursive: true });
            await pipeline(req, counter, createWriteStream(input));
            if (n === 0) throw new JobError("error.studio.not_video");
            const info = await probe(input);
            // no video stream: audio, a document or a broken file has no frame to show
            if (info.width === null || info.height === null) throw new JobError("error.studio.not_video");
            const at = posterTime(info.duration);
            let made = await frame(at);
            if (!made && at > 0) made = await frame(0);
            if (!made) throw new JobError("error.poster.failed");
            const { size } = await stat(output);
            if (size > MAX_POSTER_BYTES) throw new JobError("error.poster.failed");
            jpeg = await readFile(output);
        } catch (e) {
            code = e instanceof JobError ? e.code : "error.studio.upload_failed";
            if (code === "error.webp.timeout") code = "error.poster.failed";
            if (!(e instanceof JobError)) console.error("[webp-helper] poster failed:", e);
        }
        // files first, then the answer (and the helper stays busy until both)
        await rm(dir, { recursive: true, force: true }).catch(() => {});
        probing.delete(id);
        if (res.headersSent || res.destroyed) return;
        if (jpeg) {
            res.writeHead(200, { "content-type": "image/jpeg", "content-length": jpeg.length });
            return void res.end(jpeg);
        }
        return failAndClose(
            req,
            res,
            code === "error.studio.too_large"
                ? 413
                : code === "error.studio.not_video"
                  ? 400
                  : code === "error.poster.failed"
                    ? 422
                    : 502,
            code,
        );
    }

    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res @param {string} pathname */
    async function handleFetchRoute(req, res, pathname) {
        const m = pathname.match(/^\/fetch(?:\/([A-Za-z0-9]+)(\/file)?)?$/);
        if (!m) return fail(res, 404, "error.webp.not_found");
        const [, id, file] = m;

        if (!id) {
            if (req.method !== "POST") return fail(res, 405, "error.webp.bad_request");
            let body;
            try {
                body = JSON.parse(await readBody(req));
            } catch {
                return fail(res, 400, "error.webp.invalid_params");
            }
            const p = validateFetchInput(body);
            if (!p) return fail(res, 400, "error.webp.invalid_params");
            if (busy() || fetches.has(p.id)) return fail(res, 429, "error.webp.busy");

            /** @type {Job} */
            const job = {
                id: p.id,
                status: "pending",
                createdAt: Date.now(),
                dir: path.join(FETCH_DIR, p.id),
            };
            fetches.set(p.id, job);
            evictOld();
            void runFetch(job, p);
            return send(res, 202, { status: "pending", id: p.id });
        }

        if (!ID_RE.test(id)) return fail(res, 404, "error.webp.not_found");
        const job = fetches.get(id);
        if (!job) return fail(res, 404, "error.webp.not_found");

        if (req.method === "DELETE" && !file) {
            await drop(fetches, job);
            return send(res, 200, { status: "success" });
        }
        if (req.method !== "GET") return fail(res, 405, "error.webp.bad_request");

        if (file) {
            if (job.status !== "done") return fail(res, 409, "error.webp.not_ready");
            const src = path.join(job.dir, "in");
            const { size } = await stat(src);
            res.writeHead(200, {
                "content-type": job.result.contentType,
                "content-length": size,
            });
            return void pipeline(createReadStream(src), res).catch(() => res.destroy());
        }

        if (job.status === "pending") {
            return send(res, 200, {
                status: "pending",
                stage: job.fetchProgress?.stage ?? "downloading",
                bytes: job.fetchProgress?.bytes ?? 0,
                total: job.fetchProgress?.total ?? null,
            });
        }
        if (job.status === "error") return send(res, 200, { status: "error", error: job.error });
        return send(res, 200, { status: "done", ...job.result });
    }

    /**
     * The progress fields of a pending WebP job. Honest by construction:
     * during "decode" the count is the PNG frames on disk now, less one (the
     * newest file may still be being written), capped at the expected total;
     * during "pack" there is no count, so done = total = the frames made.
     * @param {Job} job
     */
    async function jobProgress(job) {
        const pr = job.progress;
        if (!pr) return { phase: null, frames_done: null, frames_total: null };
        if (pr.phase === "fetching") return { phase: "fetching", frames_done: null, frames_total: null };
        if (pr.phase === "pack") {
            const n = pr.frames ?? pr.total ?? null;
            return { phase: "pack", frames_done: n, frames_total: n };
        }
        let done = 0;
        try {
            const names = await readdir(pr.framesDir ?? path.join(job.dir, "frames"));
            done = Math.max(0, names.filter((n) => FRAME_RE.test(n)).length - 1);
        } catch {
            // the frames dir does not exist yet (probe, or ffmpeg not started)
        }
        if (pr.total !== null) done = Math.min(done, pr.total);
        return { phase: "decode", frames_done: done, frames_total: pr.total };
    }

    // ---- POST /apns: the Live Activity push relay ---------------------------------

    const APNS_HOSTS = new Set(["api.push.apple.com", "api.sandbox.push.apple.com"]);
    const APNS_PATH = /^\/3\/device\/[0-9A-Za-z]{1,200}$/;
    // only the headers a push needs are forwarded, whatever the caller sends
    const APNS_HEADERS = new Set([
        "authorization",
        "apns-topic",
        "apns-push-type",
        "apns-priority",
        "apns-expiration",
        "apns-id",
        "apns-collapse-id",
        "content-type",
    ]);
    /** @type {Map<string, import("node:http2").ClientHttp2Session>} one session per host */
    const apnsSessions = new Map();

    /** @param {string} host */
    function apnsSession(host) {
        const have = apnsSessions.get(host);
        if (have && !have.closed && !have.destroyed) return have;
        const session = http2.connect(apnsOrigin(host));
        const forget = () => {
            if (apnsSessions.get(host) === session) apnsSessions.delete(host);
        };
        session.on("error", forget);
        session.on("close", forget);
        session.on("goaway", () => {
            forget();
            session.close();
        });
        // an idle session is closed; the next push opens a fresh one
        session.setTimeout(5 * 60_000, () => session.close());
        apnsSessions.set(host, session);
        return session;
    }

    /**
     * One relay attempt on the host's session. Rejects with {sessionError: true} when
     * the session failed before any answer (a stale session: the caller retries once
     * on a fresh one).
     * @param {{host: string, path: string, headers: Record<string,string>, body: string}} p
     * @returns {Promise<{status: number, reason: string|null, apns_id: string|null}>}
     */
    function apnsOnce(p, timeoutMs) {
        return new Promise((resolve, reject) => {
            let settled = false;
            const done = (fn, v) => {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                session?.off("error", onSessionError);
                fn(v);
            };
            const onSessionError = (e) => {
                done(reject, Object.assign(new Error(String(e?.message ?? e)), { sessionError: !answered }));
            };
            let answered = false;
            let session;
            try {
                session = apnsSession(p.host);
            } catch (e) {
                return reject(Object.assign(new Error(String(e?.message ?? e)), { sessionError: true }));
            }
            const timer = setTimeout(() => {
                try {
                    req.close(http2.constants.NGHTTP2_CANCEL);
                } catch {}
                done(reject, new Error(`apns ${p.host} timed out after ${timeoutMs} ms`));
            }, timeoutMs);
            /** @type {import("node:http2").ClientHttp2Stream} */
            let req;
            try {
                req = session.request({
                    ":method": "POST",
                    ":path": p.path,
                    ...p.headers,
                });
            } catch (e) {
                return done(reject, Object.assign(new Error(String(e?.message ?? e)), { sessionError: true }));
            }
            let status = 0;
            let apnsId = null;
            const chunks = [];
            req.on("response", (h) => {
                answered = true;
                status = Number(h[":status"]) || 0;
                const id = h["apns-id"];
                apnsId = typeof id === "string" ? id : null;
            });
            req.on("data", (c) => {
                if (chunks.length < 64) chunks.push(c);
            });
            req.on("end", () => {
                // a stream that ended with no response headers is a dead session, not an
                // answer of status 0 (the caller would read that as "Apple said nothing")
                if (!answered) {
                    return done(reject, Object.assign(new Error("apns stream ended without a response"), { sessionError: true }));
                }
                let reason = null;
                try {
                    const j = JSON.parse(Buffer.concat(chunks).toString("utf8"));
                    if (typeof j?.reason === "string") reason = j.reason;
                } catch {}
                done(resolve, { status, reason, apns_id: apnsId });
            });
            req.on("error", (e) => {
                done(reject, Object.assign(new Error(String(e?.message ?? e)), { sessionError: !answered }));
            });
            req.on("close", () => {
                // closed without an end (a reset): an error unless already settled
                done(reject, Object.assign(new Error("apns stream closed"), { sessionError: !answered }));
            });
            session.on("error", onSessionError);
            req.end(p.body);
        });
    }

    /** @param {http.IncomingMessage} req @param {http.ServerResponse} res */
    async function handleApns(req, res) {
        if (req.method !== "POST") return fail(res, 405, "error.apns.bad_request");
        // a declared size over the limit is answered without reading the body
        if (Number(req.headers["content-length"]) > 16_384) return failAndClose(req, res, 400, "error.apns.bad_request");
        let body;
        try {
            body = JSON.parse(await readBody(req, 16_384));
        } catch {
            return fail(res, 400, "error.apns.bad_request");
        }
        const host = body?.host;
        const pathValue = body?.path;
        const rawHeaders = body?.headers;
        const payload = body?.body;
        if (typeof host !== "string" || !APNS_HOSTS.has(host)) return fail(res, 400, "error.apns.bad_host");
        if (typeof pathValue !== "string" || !APNS_PATH.test(pathValue)) return fail(res, 400, "error.apns.bad_request");
        if (typeof payload !== "string" || payload.length > 8192) return fail(res, 400, "error.apns.bad_request");
        if (!rawHeaders || typeof rawHeaders !== "object" || Array.isArray(rawHeaders)) {
            return fail(res, 400, "error.apns.bad_request");
        }
        /** @type {Record<string,string>} */
        const headers = {};
        for (const [k, v] of Object.entries(rawHeaders)) {
            const name = k.toLowerCase();
            if (APNS_HEADERS.has(name) && typeof v === "string") headers[name] = v;
        }
        const job = { host, path: pathValue, headers, body: payload };
        try {
            const deadline = Date.now() + APNS_TIMEOUT_MS;
            let out;
            try {
                out = await apnsOnce(job, APNS_TIMEOUT_MS);
            } catch (e) {
                if (!e?.sessionError) throw e;
                // a stale session (Apple closed it): once more on a fresh one, inside
                // what is left of the one budget
                apnsSessions.get(host)?.destroy();
                apnsSessions.delete(host);
                const left = deadline - Date.now();
                if (left < 50) throw e;
                out = await apnsOnce(job, left);
            }
            return send(res, 200, out);
        } catch (e) {
            // the message can name the host but never carries the request
            console.error("[webp-helper] apns relay failed:", String(e?.message ?? e).slice(0, 200));
            return send(res, 502, { status: "error", error: { code: "error.apns.transport", message: String(e?.message ?? e).slice(0, 200) } });
        }
    }

    const server = http.createServer(async (req, res) => {
        try {
            if (!keyMatches(req.headers["x-internal-key"], INTERNAL_KEY)) {
                return fail(res, 403, "error.webp.forbidden");
            }
            const url = new URL(req.url || "/", "http://helper");
            const { pathname } = url;

            if (pathname === "/apns") return await handleApns(req, res);
            if (pathname === "/jobs/upload") return await handleUpload(req, res, url);
            if (pathname === "/probe") return await handleProbe(req, res, url);
            if (pathname === "/poster") return await handlePoster(req, res, url);
            if (pathname === "/fetch" || pathname.startsWith("/fetch/")) {
                return await handleFetchRoute(req, res, pathname);
            }

            const m = pathname.match(/^\/jobs(?:\/([A-Za-z0-9]+)(\/file)?)?$/);
            if (!m) return fail(res, 404, "error.webp.not_found");
            const [, id, file] = m;

            if (!id) {
                if (req.method !== "POST") return fail(res, 405, "error.webp.bad_request");
                let body;
                try {
                    body = JSON.parse(await readBody(req));
                } catch {
                    return fail(res, 400, "error.webp.invalid_params");
                }
                const p = validateJobInput(body);
                if (!p) return fail(res, 400, "error.webp.invalid_params");
                if (busy() || jobs.has(p.id)) return fail(res, 429, "error.webp.busy");

                /** @type {Job} */
                const job = {
                    id: p.id,
                    status: "pending",
                    createdAt: Date.now(),
                    dir: path.join(WORK_DIR, p.id),
                };
                jobs.set(p.id, job);
                evictOld();
                void runJob(job, p);
                return send(res, 202, { status: "pending", id: p.id });
            }

            if (!ID_RE.test(id)) return fail(res, 404, "error.webp.not_found");
            const job = jobs.get(id);
            if (!job) return fail(res, 404, "error.webp.not_found");

            if (req.method === "DELETE" && !file) {
                await drop(jobs, job);
                return send(res, 200, { status: "success" });
            }
            if (req.method !== "GET") return fail(res, 405, "error.webp.bad_request");

            if (file) {
                if (job.status !== "done") return fail(res, 409, "error.webp.not_ready");
                const out = path.join(job.dir, "out.webp");
                const { size } = await stat(out);
                res.writeHead(200, {
                    "content-type": "image/webp",
                    "content-length": size,
                });
                return void createReadStream(out).pipe(res);
            }

            if (job.status === "pending") {
                return send(res, 200, { status: "pending", ...(await jobProgress(job)) });
            }
            if (job.status === "error") {
                return send(res, 200, { status: "error", error: job.error });
            }
            return send(res, 200, { status: "done", ...job.result });
        } catch (e) {
            console.error("[webp-helper] request failed:", e);
            if (!res.headersSent) fail(res, 500, "error.webp.encode_failed");
            else res.destroy();
        }
    });

    return {
        server,
        jobs,
        fetches,
        /** SIGKILL every running child (cobalt died: nothing can finish). */
        killAll() {
            for (const job of [...jobs.values(), ...fetches.values()]) job.proc?.kill("SIGKILL");
        },
        close() {
            clearInterval(evictTimer);
            for (const session of apnsSessions.values()) session.destroy();
            apnsSessions.clear();
            server.close();
        },
    };
}
