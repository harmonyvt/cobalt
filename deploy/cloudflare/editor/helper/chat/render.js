// Renders a chat snapshot into an MP4 (APP-API-CONTRACT.md section 45): plan.js times it, page.html draws each frame in
// headless Chromium (cdp.js), ffmpeg encodes the frames and mixes the shown videos' sound in at the moments they play.
//
//   node helper/chat/render.js <snapshot.json> <media-dir> <out.mp4> [--shape portrait|landscape|square --theme dark|light --speed 1]
//
// <media-dir> holds every file the snapshot names (posts' `poster` and files' `url`), by those relative names.
import { spawn } from "node:child_process";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, open, readFile, readdir, rm } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.js";
import { SHAPES, plan } from "./plan.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2" };
export const FPS = 30;
const SCALE = 2;

/** The content type of a media file from its first bytes (the inputs have no extensions). @param {string} file */
async function sniff(file) {
    const fh = await open(file, "r");
    const b = Buffer.alloc(12);
    await fh.read(b, 0, 12, 0).finally(() => fh.close());
    if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
    if (b.toString("latin1", 1, 4) === "PNG") return "image/png";
    if (b.toString("latin1", 0, 3) === "GIF") return "image/gif";
    if (b.toString("latin1", 0, 4) === "RIFF" && b.toString("latin1", 8, 12) === "WEBP") return "image/webp";
    return "application/octet-stream";
}

/** A loopback file server for the page (Chromium will not load module scripts from file://). / page, /m/ media, /w/ work. */
function serve(/** @type {Record<string, string>} */ roots) {
    const srv = createServer(async (req, res) => {
        try {
            const u = decodeURIComponent(new URL(req.url ?? "/", "http://x").pathname);
            const [, first, ...rest] = u.split("/");
            const inRoot = first in roots && first !== "";
            const base = path.resolve(inRoot ? roots[first] : roots[""]);
            const file = path.resolve(base, inRoot ? rest.join("/") : u.slice(1));
            if (!file.startsWith(base + path.sep) || !existsSync(file)) return res.writeHead(404).end();
            const type = TYPES[/** @type {keyof typeof TYPES} */ (path.extname(file).toLowerCase())] ?? (await sniff(file));
            res.writeHead(200, { "content-type": type, "cache-control": "no-store" });
            createReadStream(file).pipe(res);
        } catch {
            res.writeHead(500).end();
        }
    });
    srv.keepAliveTimeout = 60_000;
    return new Promise((r) => srv.listen(0, "127.0.0.1", () => r({ srv, origin: `http://127.0.0.1:${/** @type {any} */ (srv.address()).port}` })));
}

/** @param {string} bin @param {string[]} args @param {{stdin?: boolean, onChild?: (c: any) => void}} [o] */
function run(bin, args, o = {}) {
    const p = spawn(bin, args, { stdio: [o.stdin ? "pipe" : "ignore", "ignore", "pipe"] });
    o.onChild?.(p);
    let err = "";
    p.stderr?.on("data", (d) => (err = (err + d).slice(-4000)));
    const done = new Promise((res, rej) => {
        p.on("error", rej);
        p.on("close", (code) => (code === 0 ? res(undefined) : rej(new Error(`${path.basename(bin)} exited ${code}: ${err.trim().slice(-600)}`))));
    });
    return { p, done };
}

/**
 * @param {{snap: any, mediaDir: string, out: string, work: string, shape?: string, theme?: string, speed?: number,
 *          from?: string | null, to?: string | null, ffmpeg?: string, chromium?: string,
 *          onProgress?: (secondsDone: number, secondsTotal: number) => void, onChild?: (c: any) => void, gone?: () => boolean}} o
 */
export async function renderChat(o) {
    const shape = SHAPES[/** @type {keyof typeof SHAPES} */ (o.shape ?? "portrait")] ?? SHAPES.portrait;
    const W = shape.w, H = shape.h, F = FPS;
    const FF = o.ffmpeg ?? "ffmpeg";
    const script = plan(o.snap, { speed: o.speed, from: o.from, to: o.to });
    await rm(o.work, { recursive: true, force: true });
    await mkdir(o.work, { recursive: true });
    const { srv, origin } = await serve({ "": HERE, m: o.mediaDir, w: o.work });
    const url = (/** @type {string} */ rel) => `${origin}/m/${String(rel).split("/").map(encodeURIComponent).join("/")}`;
    const gone = () => o.gone?.() === true;
    let browser = null;
    try {
        // posters, and every played video as numbered JPEG frames sized for its box
        /** @type {Record<string, any>} */
        const media = {};
        for (const [id, p] of Object.entries(o.snap.posts ?? {})) {
            if (p.poster && existsSync(path.join(o.mediaDir, p.poster))) media[id] = { poster: url(p.poster) };
        }
        for (const b of script.beats) {
            if (!b.play) continue;
            const dir = path.join(o.work, "f-" + b.el.replace(/\W/g, "_"));
            await mkdir(dir);
            const x = run(FF, ["-nostdin", "-v", "error", "-t", String(b.play.length), "-i", path.join(o.mediaDir, b.play.url),
                "-vf", `fps=${F},scale='min(${Math.round(Math.min(W, H) * 0.9)},iw)':-2:flags=bicubic`, "-q:v", "3", path.join(dir, "%05d.jpg")], { onChild: o.onChild });
            await x.done;
            if (gone()) return null;
            const count = (await readdir(dir)).length;
            if (count > 0) media[b.post] = { ...(media[b.post] ?? {}), frames: { pattern: `${origin}/w/${path.basename(dir)}/%05d.jpg`, count, fps: F } };
        }

        browser = await launch({ bin: o.chromium });
        const page = await browser.newPage(W / SCALE, H / SCALE, SCALE);
        await page.goto(`${origin}/page.html`);
        for (let i = 0; i < 200 && !(await page.evaluate("window.cvReady === true").catch(() => false)); i++) await new Promise((r) => setTimeout(r, 50));
        const cfg = { snap: o.snap, script, media, theme: o.theme === "light" ? "light" : "dark", w: W / SCALE, h: H / SCALE };
        await page.evaluate(`window.cv.init(${JSON.stringify(cfg)})`);

        const frames = Math.ceil(script.seconds * F);
        const video = path.join(o.work, "video.mp4");
        const enc = run(FF, ["-nostdin", "-v", "error", "-y", "-f", "image2pipe", "-framerate", String(F), "-c:v", "mjpeg", "-i", "-",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-r", String(F), "-movflags", "+faststart", video], { stdin: true, onChild: o.onChild });
        const stdin = /** @type {import("node:stream").Writable} */ (enc.p.stdin);
        enc.done.catch(() => {});
        for (let k = 0; k < frames; k++) {
            if (gone()) {
                enc.p.kill("SIGKILL");
                return null;
            }
            await page.evaluate(`window.cv.seek(${k / F})`);
            const jpg = await page.jpeg(90);
            if (!stdin.write(jpg)) await new Promise((r) => stdin.once("drain", r));
            if (k % F === 0) o.onProgress?.(k / F, script.seconds);
        }
        stdin.end();
        await enc.done;
        await browser.close();
        browser = null;

        // sound: each played video's audio at its moment, faded at its end; silence when nothing plays
        const args = ["-nostdin", "-v", "error", "-y", "-i", video];
        /** @type {string[]} */
        const parts = [];
        script.sounds.forEach((s, i) => {
            args.push("-t", String(s.length), "-i", path.join(o.mediaDir, s.file.url));
            const ms = Math.round(s.at * 1000);
            parts.push(`[${i + 1}:a]aresample=48000,aformat=channel_layouts=stereo,afade=t=out:st=${Math.max(0, s.length - 0.4).toFixed(2)}:d=0.4,adelay=${ms}|${ms}[a${i}]`);
        });
        const silent = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"];
        if (parts.length) {
            // a played file without sound fails the filter: probe once and drop those
            const withSound = [];
            for (const [i, s] of script.sounds.entries()) if (await hasAudio(FF, path.join(o.mediaDir, s.file.url))) withSound.push(i);
            if (withSound.length) {
                const used = withSound.map((i) => parts[i]);
                const mix = `${used.join(";")};${withSound.map((i) => `[a${i}]`).join("")}amix=inputs=${withSound.length}:normalize=0,apad[aout]`;
                args.push("-filter_complex", mix, "-map", "0:v", "-map", "[aout]");
            } else {
                args.splice(5);
                args.push(...silent, "-map", "0:v", "-map", `1:a`);
            }
        } else {
            args.push(...silent, "-map", "0:v", "-map", "1:a");
        }
        args.push("-shortest", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", o.out);
        await run(FF, args, { onChild: o.onChild }).done;
        o.onProgress?.(script.seconds, script.seconds);
        return { seconds: script.seconds, frames, width: W, height: H };
    } finally {
        srv.close();
        await browser?.close().catch(() => {});
    }
}

/** @param {string} ff @param {string} file */
async function hasAudio(ff, file) {
    const probe = ff.replace(/ffmpeg$/, "ffprobe");
    return await new Promise((resolve) => {
        const p = spawn(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", file], { stdio: ["ignore", "pipe", "ignore"] });
        let out = "";
        p.stdout.on("data", (d) => (out += d));
        p.on("error", () => resolve(false));
        p.on("close", () => resolve(out.trim().length > 0));
    });
}

// CLI, for trying a snapshot by hand
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const [snapPath, mediaDir, out, ...rest] = process.argv.slice(2);
    /** @type {Record<string, string>} */
    const opt = {};
    for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];
    const snap = JSON.parse(await readFile(snapPath, "utf8"));
    const t0 = Date.now();
    const r = await renderChat({
        snap, mediaDir, out, work: path.join(path.dirname(path.resolve(out)), ".chat-work"),
        shape: opt.shape, theme: opt.theme, speed: opt.speed ? +opt.speed : undefined,
        onProgress: (d, t) => process.stderr.write(`\r${Math.round((d / t) * 100)}%`),
    });
    console.error(`\n${JSON.stringify(r)} in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
