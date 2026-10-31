// The render container's HTTP API on port 9200 (APP-API-CONTRACT.md 31.9). One process, ONE render at a time, plain Node ESM,
// no dependencies. Every request needs x-internal-key (= EDIT_INTERNAL_KEY, the Worker's COBALT_API_KEY); without it 403.
//
//   GET    /health                       -> 200 {"status":"ok","render":<rid>|null,"version":"<EDIT_DEPLOY_VERSION>"}
//   PUT    /renders/<rid>/inputs/<n>     body = the source bytes (content-length required, n 0..49)
//                                        -> 204 | 409 error.edit.busy | 413 error.edit.too_large | 400 | 411
//   POST   /renders/<rid>/start          {"timeline": <canonical>, "inputs": [{"n","item","kind"}]}
//                                        -> 202 | 409 error.edit.input_missing | 400 {error:{code},path[,items]} (parseTimeline,
//                                        the probe, checkSources, the crop size) | 409 error.edit.busy
//   GET    /renders/<rid>                -> {"status":"receiving"|"probing"|"encoding"|"poster"|"done"|"error","seconds_done",
//                                        "seconds_total","speed","bytes","width","height","duration","error":{"code"}|null} | 404
//   GET    /renders/<rid>/file           -> 200 video/mp4 with content-length (once done)
//   GET    /renders/<rid>/poster         -> 200 image/jpeg (once done, when the poster could be made) | 404
//   DELETE /renders/<rid>                -> 204 (kills ffmpeg, removes the render's directory); idempotent
//
// The first PUT of a rid takes the container; any other rid gets 409 error.edit.busy until DELETE. A render nobody has touched
// for 10 minutes is killed and deleted (the DO touches it every 5 s while it waits).

import { spawn } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readdir, rename, rm, stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pipeline } from "node:stream/promises";
import { Transform } from "node:stream";
import { renderChat } from "./chat/render.js";
import { compile } from "./compile.js";
import { ffmpegInfo, parseInfo, probeSource } from "./probe.js";
import { EDIT_MAX_CLIPS, EDIT_MAX_INPUT_BYTES, EDIT_MAX_OUTPUT_BYTES, checkSources, parseTimeline, sourceKind } from "./timeline.js";

export const PORT = 9200;
/** A render no call has touched for this long is dropped (31.9). */
export const IDLE_MS = 10 * 60 * 1000;
const RID_RE = /^[A-Za-z0-9]{8,32}$/;
const ITEM_RE = /^[A-Za-z0-9]{16}$/;
const KINDS = ["video", "gif", "photo"];

const sha256 = (/** @type {string} */ s) => createHash("sha256").update(s).digest();
/** Constant-time x-internal-key check; an empty expected key matches nothing, so a misconfigured container answers 403 to everything. @param {unknown} header @param {string | undefined} expected */
export function keyMatches(header, expected) {
    if (!expected || typeof header !== "string") return false;
    return timingSafeEqual(sha256(header), sha256(expected));
}

/** Where the poster frame is: 10 % of the duration, at most 3 s in (13.3). @param {number | null} duration */
export function posterTime(duration) {
    if (typeof duration !== "number" || !Number.isFinite(duration) || duration <= 0) return 0;
    return +Math.min(duration * 0.1, 3).toFixed(3);
}
/** 13.3's recipe: one JPEG, longer side at most 720 px (never upscaled), square pixels, `-q:v 4`. @param {{input: string, output: string, at: number}} j */
export function posterArgs(j) {
    return [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe",
        ...(j.at > 0 ? ["-ss", String(j.at)] : []),
        "-i", j.input, "-frames:v", "1", "-an", "-sn", "-dn",
        "-vf", "scale='if(gte(iw,ih),min(720,iw),-1)':'if(gte(iw,ih),-1,min(720,ih))':flags=lanczos,setsar=1,format=yuvj420p",
        "-q:v", "4", "-f", "image2", "-update", "1", "-y", j.output,
    ];
}

/** @param {string} bin @param {string[]} args @param {{onStdout?: (chunk: string) => void, onChild?: (c: import("node:child_process").ChildProcess) => void, timeoutMs: number}} o
 * @returns {Promise<{code: number | null, stderr: string, timedOut: boolean}>} */
function run(bin, args, o) {
    return new Promise((resolve) => {
        let child;
        try {
            child = spawn(bin, args, { stdio: ["ignore", o.onStdout ? "pipe" : "ignore", "pipe"] });
        } catch {
            return resolve({ code: -1, stderr: "spawn failed", timedOut: false });
        }
        o.onChild?.(child);
        let tail = "", timedOut = false;
        if (o.onStdout) child.stdout?.setEncoding("utf8").on("data", o.onStdout);
        child.stderr?.on("data", (d) => {
            tail = (tail + d).slice(-4000);
        });
        const timer = setTimeout(() => {
            timedOut = true;
            child.kill("SIGKILL");
        }, o.timeoutMs);
        child.on("error", () => {
            clearTimeout(timer);
            resolve({ code: -1, stderr: tail, timedOut });
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            resolve({ code, stderr: tail, timedOut });
        });
    });
}

/**
 * @typedef {{rid: string, dir: string, status: "receiving" | "probing" | "encoding" | "poster" | "done" | "error", touched: number,
 *   inputs: Map<number, {path: string, bytes: number}>, secondsTotal: number, secondsDone: number | null, speed: number | null,
 *   bytes: number | null, width: number | null, height: number | null, duration: number | null, error: string | null,
 *   hasPoster: boolean, child?: import("node:child_process").ChildProcess, gone: boolean}} Render
 */

/**
 * @param {{internalKey?: string, workDir?: string, ffmpeg?: string, version?: string, idleMs?: number, maxInputBytes?: number,
 *          maxOutputBytes?: number, ffmpegTimeoutMs?: number, log?: (msg: string) => void}} [opts]
 */
export function createEditServer(opts = {}) {
    const key = opts.internalKey ?? "";
    const WORK = opts.workDir ?? "/tmp/edit";
    const FFMPEG = opts.ffmpeg ?? "ffmpeg";
    const VERSION = opts.version ?? "unknown";
    const IDLE = opts.idleMs ?? IDLE_MS;
    const MAX_IN = opts.maxInputBytes ?? EDIT_MAX_INPUT_BYTES;
    const MAX_OUT = opts.maxOutputBytes ?? EDIT_MAX_OUTPUT_BYTES;
    const TIMEOUT = opts.ffmpegTimeoutMs ?? 50 * 60 * 1000;
    const log = opts.log ?? ((m) => console.error(`[edit-helper] ${m}`));
    /** @type {Render | null} */
    let cur = null;

    /** @param {http.ServerResponse} res @param {number} status @param {unknown} body */
    function json(res, status, body) {
        const text = JSON.stringify(body);
        res.writeHead(status, { "cache-control": "no-store", "content-length": Buffer.byteLength(text), "content-type": "application/json" });
        res.end(text);
    }
    const err = (/** @type {http.ServerResponse} */ res, /** @type {number} */ status, /** @type {string} */ code, /** @type {object} */ extra = {}) =>
        json(res, status, { status: "error", error: { code }, ...extra });

    /** Takes the container for `rid` (create) or finds it. Answers and returns null when it cannot. @param {http.ServerResponse} res @param {string} rid @param {boolean} create */
    function hold(res, rid, create) {
        if (cur && cur.rid !== rid) {
            err(res, 409, "error.edit.busy");
            return null;
        }
        if (!cur) {
            if (!create) {
                err(res, 404, "error.edit.not_found");
                return null;
            }
            cur = { rid, dir: path.join(WORK, rid), status: "receiving", touched: Date.now(), inputs: new Map(), secondsTotal: 0, secondsDone: null, speed: null, bytes: null,
                width: null, height: null, duration: null, error: null, hasPoster: false, gone: false };
        }
        cur.touched = Date.now();
        return cur;
    }

    /** Kills ffmpeg, removes the directory, frees the container. @param {string} rid */
    async function drop(rid) {
        if (cur && cur.rid === rid) {
            const r = cur;
            cur = null;
            r.gone = true;
            r.child?.kill("SIGKILL");
            await rm(r.dir, { recursive: true, force: true }).catch(() => {});
        } else if (RID_RE.test(rid)) {
            await rm(path.join(WORK, rid), { recursive: true, force: true }).catch(() => {});
        }
    }

    /** @param {http.IncomingMessage} req @param {number} cap @returns {Promise<any>} */
    function readJson(req, cap) {
        return new Promise((resolve, reject) => {
            /** @type {Buffer[]} */
            const chunks = [];
            let n = 0;
            req.on("data", (c) => {
                n += c.length;
                if (n > cap) {
                    reject(new Error("too large"));
                    req.destroy();
                } else chunks.push(c);
            });
            req.on("end", () => {
                try {
                    resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
                } catch (e) {
                    reject(e);
                }
            });
            req.on("error", reject);
        });
    }

    // ---- PUT /renders/<rid>/inputs/<n>
    async function putInput(/** @type {http.IncomingMessage} */ req, /** @type {http.ServerResponse} */ res, /** @type {string} */ rid, /** @type {string} */ nRaw) {
        const n = /^\d{1,2}$/.test(nRaw) ? Number(nRaw) : -1;
        if (n < 0 || n >= EDIT_MAX_CLIPS) return err(res, 400, "error.edit.bad_request", { path: "n" });
        const cl = req.headers["content-length"];
        if (typeof cl !== "string" || !/^\d+$/.test(cl)) return err(res, 411, "error.edit.bad_request", { path: "content-length" });
        const len = Number(cl);
        const r = hold(res, rid, true);
        if (!r) return;
        const refuse = (/** @type {number} */ status, /** @type {string} */ code) => {
            res.on("finish", () => req.socket.destroy());
            err(res, status, code);
        };
        if (r.status !== "receiving") return refuse(409, "error.edit.busy");
        let total = len;
        for (const [k, v] of r.inputs) if (k !== n) total += v.bytes;
        if (total > MAX_IN) return refuse(413, "error.edit.too_large");
        await mkdir(path.join(r.dir, "in"), { recursive: true });
        const final = path.join(r.dir, "in", String(n));
        const tmp = `${final}.part`;
        let got = 0;
        const count = new Transform({
            transform(chunk, _enc, cb) {
                got += chunk.length;
                r.touched = Date.now();
                cb(null, chunk);
            },
        });
        try {
            await pipeline(req, count, createWriteStream(tmp));
        } catch {
            await rm(tmp, { force: true });
            if (!res.headersSent) err(res, 400, "error.edit.bad_request", { path: "body" });
            return;
        }
        if (got !== len || r.gone) {
            await rm(tmp, { force: true });
            return err(res, 400, "error.edit.bad_request", { path: "body" });
        }
        await rename(tmp, final);
        r.inputs.set(n, { path: final, bytes: len });
        res.writeHead(204, { "cache-control": "no-store" });
        res.end();
    }

    // ---- POST /renders/<rid>/start
    async function start(/** @type {http.IncomingMessage} */ req, /** @type {http.ServerResponse} */ res, /** @type {string} */ rid) {
        const r = hold(res, rid, false);
        if (!r) return;
        if (r.status !== "receiving") return err(res, 409, "error.edit.busy");
        let body;
        try {
            body = await readJson(req, 1 << 20);
        } catch {
            return err(res, 400, "error.edit.bad_request", { path: "" });
        }
        if (typeof body !== "object" || body === null || !Array.isArray(body.inputs)) return err(res, 400, "error.edit.bad_request", { path: "inputs" });
        if (body.chat !== undefined) return startChat(r, res, body);
        const parsed = parseTimeline(body.timeline);
        if (!parsed.ok) return err(res, 400, parsed.code, { path: parsed.path });
        const timeline = parsed.timeline;

        /** @type {Map<string, {n: number, kind: "video" | "gif" | "photo"}>} */
        const byItem = new Map();
        for (let i = 0; i < body.inputs.length; i++) {
            const x = body.inputs[i];
            if (typeof x !== "object" || x === null || !Number.isInteger(x.n) || x.n < 0 || x.n >= EDIT_MAX_CLIPS || typeof x.item !== "string" || !ITEM_RE.test(x.item) || !KINDS.includes(x.kind)) {
                return err(res, 400, "error.edit.bad_request", { path: `inputs[${i}]` });
            }
            if (!byItem.has(x.item)) byItem.set(x.item, { n: x.n, kind: x.kind });
        }
        const refs = [...timeline.main.map((c, i) => ({ item: c.item, path: `main[${i}].item` })), ...timeline.overlay.map((o, i) => ({ item: o.item, path: `overlay[${i}].item` }))];
        const missing = refs.filter((x) => !byItem.has(x.item) || !r.inputs.has(/** @type {any} */ (byItem.get(x.item)).n));
        if (missing.length) return err(res, 409, "error.edit.input_missing", { path: missing[0].path, items: [...new Set(missing.map((m) => m.item))] });

        r.status = "probing";
        const fail = (/** @type {{code: string, path?: string, items?: string[]}} */ f) => {
            r.status = "error";
            r.error = f.code;
            err(res, 400, f.code, { ...(f.path !== undefined ? { path: f.path } : {}), ...(f.items ? { items: f.items } : {}) });
        };
        // probe, four at a time
        /** @type {Record<string, import("./probe.js").Source>} */
        const sources = {};
        const items = [...new Set(refs.map((x) => x.item))];
        /** @type {{code: string, path: string, items: string[]} | null} */
        let bad = null;
        let next = 0;
        await Promise.all(Array.from({ length: Math.min(4, items.length) }, async () => {
            while (next < items.length && !bad) {
                const item = /** @type {string} */ (items[next++]);
                const { n, kind } = /** @type {{n: number, kind: "video" | "gif" | "photo"}} */ (byItem.get(item));
                const inp = /** @type {{path: string, bytes: number}} */ (r.inputs.get(n));
                const p = await probeSource({ ffmpeg: FFMPEG, file: inp.path, kind, item, bytes: inp.bytes });
                if (!p.ok) bad = bad ?? { code: p.code, path: /** @type {{path: string}} */ (refs.find((x) => x.item === item)).path, items: [item] };
                else sources[item] = p.source;
            }
        }));
        if (r.gone) return err(res, 404, "error.edit.not_found");
        if (bad) return fail(bad);
        const rows = Object.values(sources).map((s) => ({ id: s.item, content_type: s.contentType, width: s.width, height: s.height, duration: s.duration, bytes: s.bytes, deleted: false }));
        for (const row of rows) if (sourceKind(row.content_type) === null) return fail({ code: "error.edit.unsupported_source", path: "main", items: [row.id] });
        const ck = checkSources(timeline, rows);
        if (!ck.ok) return fail(ck);

        const output = path.join(r.dir, "out.mp4");
        const c = compile(ck.timeline, sources, { output });
        if (!c.ok) return fail(c);
        r.secondsTotal = c.timing.seconds;
        r.secondsDone = 0;
        r.width = ck.timeline.canvas.w;
        r.height = ck.timeline.canvas.h;
        r.status = "encoding";
        res.writeHead(202, { "cache-control": "no-store", "content-length": 2, "content-type": "application/json" });
        res.end("{}");
        encode(r, c.args, output).catch((e) => {
            log(`render ${r.rid}: ${e?.message ?? e}`);
            if (!r.gone) {
                r.status = "error";
                r.error = "error.edit.render_failed";
            }
        });
    }

    /** Runs ffmpeg, then the poster, then reads the finished file. @param {Render} r @param {string[]} args @param {string} output */
    async function encode(r, args, output) {
        let buf = "";
        const done = await run(FFMPEG, args, {
            timeoutMs: TIMEOUT,
            onChild: (c) => {
                r.child = c;
            },
            onStdout: (chunk) => {
                buf += chunk;
                let i;
                while ((i = buf.indexOf("\n")) >= 0) {
                    const line = buf.slice(0, i);
                    buf = buf.slice(i + 1);
                    const eq = line.indexOf("=");
                    if (eq < 0) continue;
                    const k = line.slice(0, eq), v = line.slice(eq + 1).trim();
                    if (k === "out_time_us" || k === "out_time_ms") {
                        const us = Number(v);
                        if (Number.isFinite(us) && us >= 0) r.secondsDone = Math.min(r.secondsTotal, us / 1e6);
                    } else if (k === "speed") {
                        const sp = parseFloat(v);
                        r.speed = Number.isFinite(sp) ? sp : r.speed;
                    } else if (k === "total_size") {
                        const b = Number(v);
                        if (Number.isFinite(b)) r.bytes = b;
                    }
                }
            },
        });
        r.child = undefined;
        if (r.gone) return;
        if (done.code !== 0) {
            log(`render ${r.rid}: ffmpeg exit ${done.code}${done.timedOut ? " (timeout)" : ""}: ${done.stderr.trim()}`);
            r.status = "error";
            r.error = "error.edit.render_failed";
            return;
        }
        await finish(r, output);
    }

    /** The finished file: its size, duration and poster, then done. @param {Render} r @param {string} output */
    async function finish(r, output) {
        const size = (await stat(output).catch(() => null))?.size ?? 0;
        if (size <= 0) {
            r.status = "error";
            r.error = "error.edit.render_failed";
            return;
        }
        if (size > MAX_OUT) {
            await rm(output, { force: true });
            r.status = "error";
            r.error = "error.edit.too_large";
            return;
        }
        r.bytes = size;
        r.secondsDone = r.secondsTotal;
        const info = parseInfo(await ffmpegInfo(FFMPEG, output));
        r.duration = info.duration !== null ? +info.duration.toFixed(3) : r.secondsTotal;
        r.status = "poster";
        const poster = path.join(r.dir, "poster.jpg");
        const pr = await run(FFMPEG, posterArgs({ input: output, output: poster, at: posterTime(r.duration) }), { timeoutMs: 60000, onChild: (c) => (r.child = c) });
        r.child = undefined;
        if (r.gone) return;
        r.hasPoster = pr.code === 0 && ((await stat(poster).catch(() => null))?.size ?? 0) > 0;
        if (!r.hasPoster) log(`render ${r.rid}: no poster (${pr.stderr.trim().slice(-200)})`);
        r.status = "done";
    }

    // ---- POST /renders/<rid>/start with {"chat": {snapshot, options}, "inputs"} (section 45.4)
    /** @param {Render} r @param {http.ServerResponse} res @param {any} body */
    function startChat(r, res, body) {
        const chat = body.chat;
        if (typeof chat !== "object" || chat === null || typeof chat.snapshot !== "object" || chat.snapshot === null || !Array.isArray(chat.snapshot.messages)) {
            return err(res, 400, "error.edit.bad_request", { path: "chat" });
        }
        const o = typeof chat.options === "object" && chat.options !== null ? chat.options : {};
        // the snapshot names its files by input number; one that never arrived is drawn without its picture
        const have = (/** @type {unknown} */ n) => (typeof n === "string" && /^\d{1,2}$/.test(n) && r.inputs.has(Number(n)) ? n : null);
        const snap = structuredClone(chat.snapshot);
        for (const p of Object.values(snap.posts ?? {})) {
            const post = /** @type {any} */ (p);
            post.poster = have(post.poster);
            for (const f of post.files ?? []) f.url = have(f.url);
        }
        const output = path.join(r.dir, "out.mp4");
        r.status = "encoding";
        r.secondsDone = 0;
        res.writeHead(202, { "cache-control": "no-store", "content-length": 2, "content-type": "application/json" });
        res.end("{}");
        renderChat({
            snap,
            mediaDir: path.join(r.dir, "in"),
            out: output,
            work: path.join(r.dir, "chat"),
            shape: o.shape,
            theme: o.theme,
            speed: typeof o.speed === "number" ? o.speed : undefined,
            ffmpeg: FFMPEG,
            chromium: opts.chromium,
            gone: () => r.gone,
            onChild: (c) => {
                r.child = c;
            },
            onProgress: (done, total) => {
                r.secondsTotal = total;
                r.secondsDone = Math.min(total, done);
                r.touched = Date.now();
            },
        })
            .then(async (made) => {
                r.child = undefined;
                if (r.gone || !made) return;
                r.width = made.width;
                r.height = made.height;
                await rm(path.join(r.dir, "chat"), { recursive: true, force: true }).catch(() => {});
                await finish(r, output);
            })
            .catch((e) => {
                log(`chat render ${r.rid}: ${e?.message ?? e}`);
                if (!r.gone) {
                    r.status = "error";
                    r.error = "error.edit.render_failed";
                }
            });
    }

    /** @param {Render} r */
    function snapshot(r) {
        return {
            bytes: r.bytes,
            duration: r.duration,
            error: r.error ? { code: r.error } : null,
            height: r.height,
            seconds_done: r.secondsDone,
            seconds_total: r.secondsTotal,
            speed: r.speed,
            status: r.status,
            width: r.width,
        };
    }

    /** @param {http.ServerResponse} res @param {string} file @param {string} type */
    async function sendFile(res, file, type) {
        const st = await stat(file).catch(() => null);
        if (!st) return err(res, 404, "error.edit.not_found");
        res.writeHead(200, { "cache-control": "no-store", "content-length": st.size, "content-type": type });
        await pipeline(createReadStream(file), res).catch(() => {});
    }

    const server = http.createServer(async (req, res) => {
        try {
            if (!keyMatches(req.headers["x-internal-key"], key)) {
                res.on("finish", () => req.socket.destroy());
                return err(res, 403, "error.edit.forbidden");
            }
            const url = new URL(req.url ?? "/", "http://edit.internal");
            const parts = url.pathname.split("/").filter(Boolean);
            const method = req.method ?? "GET";
            if (parts.length === 1 && parts[0] === "health" && method === "GET") {
                return json(res, 200, { render: cur?.rid ?? null, status: "ok", version: VERSION });
            }
            if (parts[0] !== "renders" || parts.length < 2 || !RID_RE.test(parts[1])) return err(res, 404, "error.edit.not_found");
            const rid = parts[1];
            if (parts.length === 4 && parts[2] === "inputs" && method === "PUT") return await putInput(req, res, rid, parts[3]);
            if (parts.length === 3 && parts[2] === "start" && method === "POST") return await start(req, res, rid);
            if (parts.length === 2 && method === "DELETE") {
                await drop(rid);
                res.writeHead(204, { "cache-control": "no-store" });
                return res.end();
            }
            if (parts.length === 2 && method === "GET") {
                const r = hold(res, rid, false);
                return r ? json(res, 200, snapshot(r)) : undefined;
            }
            if (parts.length === 3 && (parts[2] === "file" || parts[2] === "poster") && method === "GET") {
                const r = hold(res, rid, false);
                if (!r) return;
                if (r.status !== "done") return err(res, 409, "error.edit.not_ready");
                if (parts[2] === "file") return await sendFile(res, path.join(r.dir, "out.mp4"), "video/mp4");
                return r.hasPoster ? await sendFile(res, path.join(r.dir, "poster.jpg"), "image/jpeg") : err(res, 404, "error.edit.not_found");
            }
            return err(res, 404, "error.edit.not_found");
        } catch (e) {
            log(`request failed: ${/** @type {any} */ (e)?.message ?? e}`);
            if (!res.headersSent) err(res, 500, "error.edit.render_failed");
            else res.destroy();
        }
    });
    // a source upload can take many minutes: no request timeout
    server.requestTimeout = 0;
    server.headersTimeout = 60_000;
    server.keepAliveTimeout = 65_000;

    const reaper = setInterval(() => {
        if (cur && Date.now() - cur.touched > IDLE) {
            log(`render ${cur.rid}: untouched for ${IDLE / 1000} s, dropped`);
            void drop(cur.rid);
        }
    }, Math.max(50, Math.min(30_000, IDLE / 2)));
    reaper.unref();

    return {
        server,
        /** The held render, for tests. */
        current: () => cur,
        reap: () => clearInterval(reaper),
        /** Wipes the work directory (a fresh container has none; a restarted local process might). */
        async clean() {
            await mkdir(WORK, { recursive: true });
            for (const d of await readdir(WORK).catch(() => [])) await rm(path.join(WORK, d), { recursive: true, force: true });
        },
        async killAll() {
            clearInterval(reaper);
            if (cur) await drop(cur.rid);
        },
    };
}

// ---- entrypoint: `node /app/helper/server.js` -------------------------------------------------------------------------
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const key = process.env.EDIT_INTERNAL_KEY || "";
    if (!key) console.error("[edit-helper] EDIT_INTERNAL_KEY is not set: every request will be refused");
    const h = createEditServer({
        ffmpeg: process.env.EDIT_FFMPEG || "ffmpeg",
        internalKey: key,
        version: process.env.EDIT_DEPLOY_VERSION || "unknown",
        workDir: process.env.EDIT_WORK_DIR || "/tmp/edit",
    });
    await h.clean();
    for (const sig of ["SIGTERM", "SIGINT"]) {
        process.on(sig, () => {
            void h.killAll().finally(() => process.exit(0));
        });
    }
    const port = Number(process.env.EDIT_PORT || PORT);
    let host = "::";
    h.server.on("error", (e) => {
        // a host without IPv6 (some local docker setups) cannot bind "::"; Cloudflare Containers can, and need it
        if (host === "::" && /** @type {any} */ (e)?.code && ["EAFNOSUPPORT", "EADDRNOTAVAIL"].includes(/** @type {any} */ (e).code)) {
            host = "0.0.0.0";
            h.server.listen(port, host);
            return;
        }
        console.error("[edit-helper] cannot listen:", e);
        process.exit(1);
    });
    // "::" is dual-stack (IPv4 + IPv6): Cloudflare Containers have no IPv4-only route (supervisor.js learned this)
    h.server.on("listening", () => console.error(`[edit-helper] listening on ${host === "::" ? "[::]" : host}:${port}`));
    h.server.listen(port, host);
}
