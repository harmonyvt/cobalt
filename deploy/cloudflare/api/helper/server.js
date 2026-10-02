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
//   GET    /jobs/:id          -> {status:"pending"} | {status:"done",...} | {status:"error",error:{code}}
//   GET    /jobs/:id/file     -> image/webp bytes (once done)
//   DELETE /jobs/:id          -> removes the job and its files
//
// cobalt studio (saving a source video for later renders):
//   POST   /fetch {id,url}    -> 202 | 429 busy   (resolve via cobalt, download at
//                      most 200 MB to /tmp/fetch/<id>/in, probe duration/size)
//   GET    /fetch/:id         -> {status:"pending"} | {status:"done", bytes, contentType,
//                      ext, duration, width, height, title, service} | {status:"error",error:{code}}
//   GET    /fetch/:id/file    -> the video bytes with content-length (once done)
//   DELETE /fetch/:id         -> removes it and its file
//
// cobalt library (measuring a file that is already stored, see the Worker's
// POST /library/adopt):
//   POST   /probe?id=         body = the video bytes (streamed to /tmp/probe/<id>,
//                      at most 200 MB), probed with ffmpeg, deleted again; answers
//                      at the end of the request -> 200 {duration,width,height}
//                      (duration may be null) | 400 error.studio.not_video (no
//                      video stream, or empty) | 413 | 429 busy

import { spawn } from "node:child_process";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rm, stat } from "node:fs/promises";
import http from "node:http";
import { createRequire } from "node:module";
import path from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import {
    COBALT_ORIGIN,
    ID_RE,
    JobError,
    MAX_FETCH_BYTES,
    MAX_OUTPUT_BYTES,
    VIDEO_TYPES,
    downloadToFile,
    encodeAnimatedWebp,
    keyMatches,
    parseVideoInfo,
    parseWebp,
    planClip,
    resolveSource,
    serviceFromUrl,
    studioCode,
    titleFromFilename,
    validateEncodeFields,
    validateFetchInput,
    validateJobInput,
    videoExt,
} from "./lib.js";

/**
 * @typedef {{id: string, status: "pending"|"done"|"error", createdAt: number,
 *   dir: string, error?: {code: string}, result?: any,
 *   proc?: import("node:child_process").ChildProcess}} Job
 */

/**
 * @param {{
 *   appDir?: string, internalKey?: string, workDir?: string, fetchDir?: string, probeDir?: string,
 *   cobaltOrigin?: string, apiOrigin?: string,
 *   ffmpegTimeoutMs?: number, downloadTimeoutMs?: number, fetchTimeoutMs?: number,
 *   maxFetchBytes?: number, keepJobs?: number, jobTtlMs?: number,
 *   ffmpegPath?: () => string, img2webpPath?: () => string,
 *   probe?: (input: string) => Promise<{duration: number|null, width: number|null, height: number|null}>,
 *   waitForCobalt?: () => Promise<void>,
 *   resolveSource?: typeof resolveSource,
 *   downloadToFile?: typeof downloadToFile,
 *   encodeAnimatedWebp?: typeof encodeAnimatedWebp,
 * }} [opts] everything but the paths and the key defaults to the real thing;
 *   tests replace the pieces that need cobalt, the network or ffmpeg.
 */
export function createHelper(opts = {}) {
    const APP_DIR = opts.appDir ?? "/app";
    const INTERNAL_KEY = opts.internalKey ?? "";
    const WORK_DIR = opts.workDir ?? "/tmp/webp";
    const FETCH_DIR = opts.fetchDir ?? "/tmp/fetch";
    const PROBE_DIR = opts.probeDir ?? "/tmp/probe";
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

    /** @type {Map<string, Job>} insertion order = age */
    const jobs = new Map();
    /** @type {Map<string, Job>} */
    const fetches = new Map();

    /** probes in flight (POST /probe): they hold the helper like a job does */
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
        const info = await probe(input);
        const plan = planClip({ start: p.start, length: p.length, duration: info.duration });
        if (!plan.ok) throw new JobError(plan.code);
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
            framesDir: path.join(job.dir, "frames"),
            start: p.start,
            length: plan.seconds,
            width: p.width,
            fps: p.fps,
            quality: p.quality,
            timeoutMs: FFMPEG_TIMEOUT_MS,
            onChild: (c) => {
                job.proc = c;
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
            });

            const info = await probe(input);
            // no video stream: an image, audio or a broken file is no use here
            if (info.width === null || info.height === null) {
                throw new JobError("error.webp.bad_source");
            }
            const ext = videoExt({ contentType, filename: src.filename });
            job.result = {
                bytes,
                contentType: VIDEO_TYPES[ext],
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

        if (job.status === "pending") return send(res, 200, { status: "pending" });
        if (job.status === "error") return send(res, 200, { status: "error", error: job.error });
        return send(res, 200, { status: "done", ...job.result });
    }

    const server = http.createServer(async (req, res) => {
        try {
            if (!keyMatches(req.headers["x-internal-key"], INTERNAL_KEY)) {
                return fail(res, 403, "error.webp.forbidden");
            }
            const url = new URL(req.url || "/", "http://helper");
            const { pathname } = url;

            if (pathname === "/jobs/upload") return await handleUpload(req, res, url);
            if (pathname === "/probe") return await handleProbe(req, res, url);
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

            if (job.status === "pending") return send(res, 200, { status: "pending" });
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
            server.close();
        },
    };
}
