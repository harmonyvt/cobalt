// The yt-dlp box (APP-API-CONTRACT.md section 49): saves one link with yt-dlp, for the studio save when cobalt cannot (or
// when the save asks for yt-dlp). It answers the same single-file /fetch routes as the main container's helper
// (deploy/cloudflare/api/helper/server.js), so the studio Durable Object streams the result into R2 exactly as it does
// a cobalt save. Plain Node ESM, no dependencies. Port 9300.
//
// Every request needs x-internal-key (YTDLP_INTERNAL_KEY, the Worker's COBALT_API_KEY); without it 403. Only the YtDlpBox
// Durable Object can reach the port. ONE fetch runs at a time: a second id answers 429 while one is pending.
//
//   POST   /fetch {id,url}  -> 202 (also for the id already running or done) | 400 | 429 busy
//   GET    /fetch/:id       -> {status:"pending", stage:"downloading"|"probing", bytes, total} |
//                              {status:"done", bytes, contentType, ext, duration, width, height, title, service,
//                               picker_count:null} | {status:"error", error:{code}} | 404 unknown
//   GET    /fetch/:id/file  -> the bytes, with content-length (once done)
//   GET    /fetch/:id/thumb -> 404 (videos only: the studio's poster job makes the poster)
//   DELETE /fetch/:id       -> kills a running download and removes its files
//   GET    /health          -> 200 (no key: the platform's port check)

import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";

export const PORT = 9300;
// the main helper's own caps (helper/server.js MAX_FETCH_BYTES): one file, at most 200 MB
export const MAX_BYTES = 200 * 1024 * 1024;
// inside the studio's SAVE_BUDGET_MS (8 min), which runs from the accept
export const FETCH_TIMEOUT_MS = 6 * 60 * 1000;
// a finished fetch the studio never collected is removed after this
export const JOB_TTL_MS = 30 * 60 * 1000;

const ID_RE = /^[A-Za-z0-9]{1,64}$/;
const MAX_BODY = 8 * 1024;

// what the studio stores each extension as; anything else is refused (yt-dlp is asked for mp4 first)
const TYPES = {
    mp4: "video/mp4",
    m4v: "video/mp4",
    mov: "video/quicktime",
    webm: "video/webm",
    mkv: "video/x-matroska",
    gif: "image/gif",
    m4a: "audio/mp4",
    mp3: "audio/mpeg",
};

// ≤ 720p like cobalt's `videoQuality: "720"` (helper/lib.js resolveSource), H.264 + AAC in mp4 first: the files the app
// and the studio's ffmpeg read everywhere. A post with no video (a SoundCloud track) still saves its audio.
export function ytdlpArgs(url, dir, o = {}) {
    return [
        "--no-playlist",
        "--no-mtime",
        "--no-color",
        "--newline",
        "--progress",
        "--progress-template",
        "download:@@P %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
        "-O",
        "after_move:@@D %(.{title,duration,width,height,extractor_key,ext,filepath})j",
        "-f",
        "bv*+ba/b",
        "-S",
        "res:720,vcodec:h264,acodec:aac,ext:mp4:m4a",
        "--merge-output-format",
        "mp4",
        "--max-filesize",
        String(o.maxBytes ?? MAX_BYTES),
        "--socket-timeout",
        "20",
        "--retries",
        "3",
        // YouTube's signatures need a JavaScript runtime: node is in the image (yt-dlp only enables deno by default)
        ...(o.jsRuntime ? ["--js-runtimes", o.jsRuntime] : []),
        "--cache-dir",
        o.cacheDir ?? "/tmp/ytdlp-cache",
        "-o",
        join(dir, "media.%(ext)s"),
        "--",
        url,
    ];
}

// yt-dlp's words -> the codes cobalt already answers with, so the app shows its usual text
export function codeFor(text) {
    const t = String(text);
    if (/larger than max-filesize|File is larger than/i.test(t)) return "error.studio.too_large";
    if (/Unsupported URL/i.test(t)) return "error.api.link.unsupported";
    if (/confirm your age|age[- ]restricted|inappropriate for some users/i.test(t)) return "error.api.content.video.age";
    if (/Sign in to confirm you.?re not a bot|confirm you are not a bot/i.test(t)) return "error.api.youtube.login";
    if (/private video|video is private|This video is private|account is private/i.test(t)) return "error.api.content.video.private";
    if (/live event will begin|is not live|Premieres in/i.test(t)) return "error.api.content.video.live";
    if (/No video formats found|Requested format is not available|There is no video in this/i.test(t)) return "error.webp.no_video";
    if (/Video unavailable|not available|has been removed|does not exist|404: Not Found|HTTP Error 404/i.test(t)) {
        return "error.api.content.video.unavailable";
    }
    return "error.api.fetch.fail";
}

const finite = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/**
 * @param {{ internalKey: string, dir?: string, bin?: string, ffprobe?: string, jsRuntime?: string|null, maxBytes?: number,
 *           timeoutMs?: number, ttlMs?: number, now?: () => number, log?: (...a: unknown[]) => void }} opts
 */
export function makeHandler(opts) {
    const KEY = String(opts.internalKey ?? "");
    const ROOT = opts.dir ?? "/tmp/ytdlp";
    const BIN = opts.bin ?? "yt-dlp";
    const PROBE = opts.ffprobe ?? "ffprobe";
    const MAX = opts.maxBytes ?? MAX_BYTES;
    const TIMEOUT = opts.timeoutMs ?? FETCH_TIMEOUT_MS;
    const TTL = opts.ttlMs ?? JOB_TTL_MS;
    const now = opts.now ?? Date.now;
    const log = opts.log ?? ((...a) => console.log("[ytdlp]", ...a));

    /** @type {Map<string, any>} */
    const jobs = new Map();

    const send = (res, status, body, headers = {}) => {
        const text = JSON.stringify(body);
        res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(text), ...headers });
        res.end(text);
    };
    const err = (res, status, code) => send(res, status, { status: "error", error: { code } });

    async function reap() {
        for (const [id, j] of jobs) {
            if (j.status !== "pending" && now() - j.endedAt > TTL) await drop(id);
        }
    }

    async function drop(id) {
        const j = jobs.get(id);
        if (!j) return;
        jobs.delete(id);
        try {
            j.proc?.kill("SIGKILL");
        } catch {}
        await rm(j.dir, { recursive: true, force: true }).catch(() => {});
    }

    function finish(j, patch) {
        if (j.status !== "pending") return;
        Object.assign(j, patch, { endedAt: now(), proc: null });
        clearTimeout(j.timer);
        if (j.status === "error") {
            // the URL is never logged (a pasted link may carry a token): only the id and the code
            log("fetch failed", j.id, j.error, j.lastLine ? `(${j.lastLine.slice(0, 200)})` : "");
            void rm(j.dir, { recursive: true, force: true }).catch(() => {});
        } else {
            log("fetch done", j.id, j.bytes, j.contentType);
        }
    }

    async function start(id, url) {
        const dir = join(ROOT, id);
        await rm(dir, { recursive: true, force: true }).catch(() => {});
        await mkdir(dir, { recursive: true });
        const j = { id, dir, status: "pending", stage: "downloading", bytes: null, total: null, startedAt: now(), stderr: "", lastLine: "", info: null };
        jobs.set(id, j);
        const proc = spawn(BIN, ytdlpArgs(url, dir, { maxBytes: MAX, jsRuntime: opts.jsRuntime }), {
            stdio: ["ignore", "pipe", "pipe"],
            // a pipe makes Python buffer its stdout: the progress lines would only arrive at the end
            env: { ...process.env, PYTHONUNBUFFERED: "1" },
        });
        j.proc = proc;
        j.timer = setTimeout(() => {
            finish(j, { status: "error", error: "error.webp.timeout" });
            try {
                proc.kill("SIGKILL");
            } catch {}
        }, TIMEOUT);

        let out = "";
        const onLine = (line) => {
            if (line.startsWith("@@P ")) {
                const [a, b, c] = line.slice(4).split(" ").map((x) => Number(x));
                j.stage = "downloading";
                j.bytes = Number.isFinite(a) ? a : j.bytes;
                j.total = Number.isFinite(b) ? b : Number.isFinite(c) ? Math.round(c) : null;
            } else if (line.startsWith("@@D ")) {
                try {
                    j.info = JSON.parse(line.slice(4));
                } catch {}
            } else if (line.includes("[Merger]") || line.includes("[FixupM")) {
                j.stage = "probing";
            }
        };
        proc.stdout.setEncoding("utf8");
        proc.stdout.on("data", (d) => {
            out += d;
            let i;
            while ((i = out.indexOf("\n")) >= 0) {
                onLine(out.slice(0, i).trim());
                out = out.slice(i + 1);
            }
        });
        proc.stderr.setEncoding("utf8");
        proc.stderr.on("data", (d) => {
            j.stderr = (j.stderr + d).slice(-8000);
            const lines = String(d).trim().split("\n");
            const last = lines[lines.length - 1];
            if (last) j.lastLine = last;
        });
        proc.on("error", () => finish(j, { status: "error", error: "error.api.fetch.fail" }));
        proc.on("close", async (exit) => {
            if (out.trim()) onLine(out.trim());
            if (j.status !== "pending") return;
            j.stage = "probing";
            try {
                const done = await collect(j, exit);
                finish(j, done);
            } catch (e) {
                finish(j, { status: "error", error: typeof e?.code === "string" && e.code.startsWith("error.") ? e.code : "error.api.fetch.fail" });
            }
        });
    }

    // The file yt-dlp left (its own report first, else the one media.* in the job's directory)
    async function collect(j, exit) {
        const text = `${j.stderr}\n${j.lastLine}`;
        if (/larger than max-filesize/i.test(text)) throw Object.assign(new Error("too large"), { code: "error.studio.too_large" });
        if (exit !== 0) throw Object.assign(new Error("yt-dlp failed"), { code: codeFor(text) });
        const names = (await readdir(j.dir).catch(() => [])).filter((n) => n.startsWith("media.") && !/\.(part|ytdl|temp)$/.test(n) && !/\.f\d+\./.test(n));
        const name = typeof j.info?.filepath === "string" ? j.info.filepath.split("/").pop() : names[0];
        // `-O` makes yt-dlp quiet: a file over --max-filesize is skipped without a word, exit 0 and nothing written
        if (!name && !j.info) throw Object.assign(new Error("skipped"), { code: "error.studio.too_large" });
        if (!name || !names.includes(name)) throw Object.assign(new Error("no file"), { code: codeFor(text) });
        const ext = name.slice(name.lastIndexOf(".") + 1).toLowerCase();
        const contentType = TYPES[ext];
        if (!contentType) throw Object.assign(new Error("odd file"), { code: "error.webp.no_video" });
        const path = join(j.dir, name);
        const size = (await stat(path)).size;
        if (size <= 0) throw Object.assign(new Error("empty"), { code: "error.api.fetch.empty" });
        if (size > MAX) throw Object.assign(new Error("too large"), { code: "error.studio.too_large" });
        const info = j.info ?? {};
        // yt-dlp does not always know (a generic file link): ffprobe the file itself
        const probed = await probe(path);
        const title = typeof info.title === "string" && info.title.trim() ? info.title.trim().slice(0, 200) : null;
        return {
            status: "done",
            path,
            bytes: size,
            contentType,
            ext: ext === "m4v" ? "mp4" : ext,
            duration: probed.duration ?? finite(info.duration),
            width: probed.width ?? finite(info.width),
            height: probed.height ?? finite(info.height),
            title,
            service: typeof info.extractor_key === "string" ? info.extractor_key.toLowerCase().slice(0, 40) : null,
        };
    }

    // duration, width and height of the file; nulls when ffprobe is missing or cannot read it. Never throws.
    function probe(path) {
        return new Promise((resolve) => {
            const none = { duration: null, width: null, height: null };
            let out = "";
            let p;
            try {
                p = spawn(PROBE, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path], { stdio: ["ignore", "pipe", "ignore"] });
            } catch {
                return resolve(none);
            }
            const timer = setTimeout(() => p.kill("SIGKILL"), 20_000);
            p.stdout.setEncoding("utf8");
            p.stdout.on("data", (d) => (out += d));
            p.on("error", () => {
                clearTimeout(timer);
                resolve(none);
            });
            p.on("close", () => {
                clearTimeout(timer);
                try {
                    const b = JSON.parse(out);
                    const v = (b.streams ?? []).find((s) => s.codec_type === "video");
                    const d = Number(b.format?.duration);
                    resolve({
                        duration: Number.isFinite(d) && d > 0 ? Math.round(d * 1000) / 1000 : null,
                        width: finite(v?.width),
                        height: finite(v?.height),
                    });
                } catch {
                    resolve(none);
                }
            });
        });
    }

    async function readBody(req) {
        let size = 0;
        const parts = [];
        for await (const c of req) {
            size += c.length;
            if (size > MAX_BODY) return null;
            parts.push(c);
        }
        return Buffer.concat(parts).toString("utf8");
    }

    function view(j) {
        if (j.status === "pending") return { status: "pending", stage: j.stage, bytes: j.bytes, total: j.total };
        if (j.status === "error") return { status: "error", error: { code: j.error } };
        return {
            status: "done",
            bytes: j.bytes,
            contentType: j.contentType,
            ext: j.ext,
            duration: j.duration,
            width: j.width,
            height: j.height,
            title: j.title,
            service: j.service,
            picker_count: null,
            engine: "ytdlp",
        };
    }

    return async function handle(req, res) {
        const url = new URL(req.url ?? "/", "http://ytdlp");
        const p = url.pathname;
        const method = req.method ?? "GET";
        try {
            if (p === "/health") return send(res, 200, { status: "ok" });
            if (!KEY || req.headers["x-internal-key"] !== KEY) return err(res, 403, "error.api.auth.key.invalid");
            await reap();

            if (method === "POST" && p === "/fetch") {
                const raw = await readBody(req);
                let b = null;
                try {
                    b = raw === null ? null : JSON.parse(raw);
                } catch {}
                const id = b?.id;
                const link = b?.url;
                if (typeof id !== "string" || !ID_RE.test(id)) return err(res, 400, "error.studio.invalid_params");
                if (typeof link !== "string" || link.length > 2048 || !/^https?:\/\/[^\s]+$/i.test(link)) {
                    return err(res, 400, "error.studio.no_link");
                }
                // the same id again (an accept whose answer was lost): the same job
                if (jobs.has(id)) return send(res, 202, { status: "pending", id });
                if ([...jobs.values()].some((j) => j.status === "pending")) return err(res, 429, "error.webp.busy");
                await start(id, link);
                return send(res, 202, { status: "pending", id });
            }

            const m = /^\/fetch\/([A-Za-z0-9]{1,64})(\/file|\/thumb)?$/.exec(p);
            if (!m) return err(res, 404, "error.api.generic");
            const id = m[1];
            const j = jobs.get(id);
            if (method === "DELETE" && !m[2]) {
                await drop(id);
                return send(res, 200, { status: "success" });
            }
            if (method !== "GET") return err(res, 405, "error.api.generic");
            if (!j) return err(res, 404, "error.webp.not_found");
            if (!m[2]) return send(res, 200, view(j));
            if (m[2] === "/thumb") return err(res, 404, "error.webp.not_found");
            if (j.status !== "done") return err(res, 409, "error.webp.not_ready");
            res.writeHead(200, { "content-type": j.contentType, "content-length": String(j.bytes), "x-file-bytes": String(j.bytes) });
            const s = createReadStream(j.path);
            s.on("error", () => res.destroy());
            s.pipe(res);
        } catch (e) {
            log("request failed", method, p, e instanceof Error ? e.name : "error");
            if (!res.headersSent) err(res, 500, "error.api.generic");
            else res.destroy();
        }
    };
}

// started directly (the image's CMD): listen
if (import.meta.url === `file://${process.argv[1]}`) {
    const handle = makeHandler({
        internalKey: process.env.YTDLP_INTERNAL_KEY ?? "",
        bin: process.env.YTDLP_BIN ?? "yt-dlp",
        jsRuntime: process.env.YTDLP_JS_RUNTIME ?? "node",
    });
    createServer((req, res) => void handle(req, res)).listen(PORT, "0.0.0.0", () => {
        console.log(`[ytdlp] listening on ${PORT} (deploy ${process.env.YTDLP_DEPLOY_VERSION ?? "unknown"})`);
    });
}
