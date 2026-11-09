// Renders a post frame (APP-API-CONTRACT.md section 52.5): page.html draws the card once in headless Chromium with the
// video's box left see-through, then ffmpeg puts the video under it (and, for 9:16 / 1:1, a blurred copy behind the card).
//
//   node helper/post/render.js <spec.json> <media-dir> <out.mp4>
//
// <media-dir> holds input "0" (the video) and, when there is one, "1" (the avatar).
import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../chat/cdp.js";
import { run, serve } from "../chat/render.js";
import { ffmpegInfo, parseInfo } from "../probe.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const STYLES = ["x", "instagram", "twitch", "youtube", "generic"];
export const CANVASES = { fit: null, portrait: { w: 1080, h: 1920 }, square: { w: 1080, h: 1080 } };
// the card's width in device pixels for `fit`
export const CARD_PX = 1080;
// the card's CSS width per style (page.css)
const CSS_W = { x: 360, instagram: 360, twitch: 420, youtube: 420, generic: 360 };
// the video's box: height / width, kept between 21:9 and 4:5 (taller videos are pillarboxed inside it)
export const ASPECT_MIN = 9 / 21;
export const ASPECT_MAX = 1.25;
export const MAX_SECONDS = 600;
const FPS = 30;

const even = (/** @type {number} */ n) => Math.max(2, Math.round(n / 2) * 2);

/** The box's aspect for a video of w×h. @param {number | null} w @param {number | null} h */
export function boxAspect(w, h) {
    if (!w || !h) return 9 / 16;
    return Math.min(ASPECT_MAX, Math.max(ASPECT_MIN, h / w));
}

/**
 * Where everything goes, in output pixels. `card`: the card PNG's size (device px) and the box inside it (device px).
 * @param {{canvas: string, card: {w: number, h: number, box: {x: number, y: number, w: number, h: number}}}} o
 */
export function placement(o) {
    const c = CANVASES[/** @type {keyof typeof CANVASES} */ (o.canvas)] ?? null;
    if (!c) {
        const W = even(o.card.w), H = even(o.card.h);
        return { W, H, scale: 1, cardX: 0, cardY: 0, cardW: W, cardH: H, ...boxIn(o.card.box, 1, 0, 0) };
    }
    const margin = 60;
    const s = Math.min((c.w - 2 * margin) / o.card.w, (c.h - 2 * margin) / o.card.h);
    const cw = even(o.card.w * s), ch = even(o.card.h * s);
    const x = Math.round((c.w - cw) / 2), y = Math.round((c.h - ch) / 2);
    return { W: c.w, H: c.h, scale: s, cardX: x, cardY: y, cardW: cw, cardH: ch, ...boxIn(o.card.box, s, x, y) };
}
/** @param {{x: number, y: number, w: number, h: number}} b @param {number} s @param {number} x @param {number} y */
function boxIn(b, s, x, y) {
    // the video is drawn one pixel bigger on every side so no seam shows under the card's anti-aliased hole
    return { boxX: Math.floor(x + b.x * s) - 1, boxY: Math.floor(y + b.y * s) - 1, boxW: even(b.w * s + 2), boxH: even(b.h * s + 2) };
}

/**
 * ffmpeg's arguments. Inputs: 0 the video (trimmed), 1 the card PNG.
 * @param {{video: string, card: string, out: string, from: number, length: number, p: ReturnType<typeof placement>,
 *          blurBg: boolean, bg: string, audio: boolean}} o
 */
export function ffmpegArgs(o) {
    const { p } = o;
    const parts = [];
    if (o.blurBg) {
        parts.push(`[0:v]scale=${p.W}:${p.H}:force_original_aspect_ratio=increase,crop=${p.W}:${p.H},boxblur=40:3,eq=brightness=-0.18,setsar=1[bg]`);
    } else {
        parts.push(`color=c=${o.bg}:s=${p.W}x${p.H}:r=${FPS}[bg]`);
    }
    parts.push(`[0:v]scale=${p.boxW}:${p.boxH}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${p.boxW}:${p.boxH}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[v]`);
    parts.push(`[1:v]scale=${p.cardW}:${p.cardH}:flags=lanczos,format=rgba[card]`);
    parts.push(`[bg][v]overlay=${p.boxX}:${p.boxY}:shortest=1[a]`);
    parts.push(`[a][card]overlay=${p.cardX}:${p.cardY}:shortest=1:format=auto,fps=${FPS},format=yuv420p[out]`);
    const args = ["-nostdin", "-v", "error", "-y"];
    if (o.from > 0) args.push("-ss", o.from.toFixed(3));
    args.push("-t", o.length.toFixed(3), "-i", o.video, "-loop", "1", "-framerate", String(FPS), "-i", o.card);
    args.push("-filter_complex", parts.join(";"), "-map", "[out]");
    if (o.audio) args.push("-map", "0:a:0", "-c:a", "aac", "-b:a", "160k", "-ac", "2");
    args.push("-t", o.length.toFixed(3), "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-movflags", "+faststart", o.out);
    return args;
}

/**
 * @param {{spec: any, mediaDir: string, out: string, work: string, ffmpeg?: string, chromium?: string,
 *          onProgress?: (secondsDone: number, secondsTotal: number) => void, onChild?: (c: any) => void, gone?: () => boolean}} o
 * @returns {Promise<{width: number, height: number, seconds: number} | null>}
 */
export async function renderPost(o) {
    const FF = o.ffmpeg ?? "ffmpeg";
    const spec = o.spec ?? {};
    const style = STYLES.includes(spec.style) ? spec.style : "generic";
    const canvas = spec.canvas in CANVASES ? spec.canvas : "fit";
    const theme = spec.theme === "light" ? "light" : "dark";
    const video = path.join(o.mediaDir, "0");
    if (!existsSync(video)) throw new Error("the video is missing");
    const info = parseInfo(await ffmpegInfo(FF, video));
    if (!info.hasVideo || !info.width || !info.height) throw new Error("the source has no video");
    const total = info.duration ?? 0;
    const from = Math.max(0, Math.min(Number(spec.from) || 0, Math.max(0, total - 0.1)));
    const to = typeof spec.to === "number" && spec.to > from ? Math.min(spec.to, total || spec.to) : total || from + MAX_SECONDS;
    const length = Math.min(MAX_SECONDS, Math.max(0.1, to - from));

    await rm(o.work, { recursive: true, force: true });
    await mkdir(o.work, { recursive: true });
    const { srv, origin } = await serve({ "": HERE, m: o.mediaDir });
    let browser = null;
    try {
        const cssW = CSS_W[/** @type {keyof typeof CSS_W} */ (style)];
        const dpr = CARD_PX / cssW;
        browser = await launch({ bin: o.chromium });
        const page = await browser.newPage(cssW, 2000, dpr, { transparent: true });
        await page.goto(`${origin}/page.html`);
        for (let i = 0; i < 200 && !(await page.evaluate("window.pfReady === true").catch(() => false)); i++) await new Promise((r) => setTimeout(r, 50));
        const hasAvatar = typeof spec.avatar === "string" && /^\d{1,2}$/.test(spec.avatar) && existsSync(path.join(o.mediaDir, spec.avatar));
        const cfg = {
            style,
            theme,
            flat: canvas === "fit",
            show: spec.show ?? {},
            d: spec.details ?? {},
            host: typeof spec.host === "string" ? spec.host : null,
            avatar: hasAvatar ? `${origin}/m/${spec.avatar}` : null,
            aspect: boxAspect(info.width, info.height),
            duration: length,
        };
        const laid = await page.evaluate(`window.pf.draw(${JSON.stringify(cfg)})`);
        if (!laid || !(laid.width > 0) || !(laid.height > 0)) throw new Error("the card did not draw");
        const png = await page.png({ x: 0, y: 0, width: laid.width, height: laid.height });
        await browser.close();
        browser = null;
        const cardFile = path.join(o.work, "card.png");
        await writeFile(cardFile, png);
        if (o.gone?.()) return null;

        const card = { w: Math.round(laid.width * dpr), h: Math.round(laid.height * dpr), box: { x: laid.box.x * dpr, y: laid.box.y * dpr, w: laid.box.w * dpr, h: laid.box.h * dpr } };
        const p = placement({ canvas, card });
        o.onProgress?.(0, length);
        const args = ffmpegArgs({ video, card: cardFile, out: o.out, from, length, p, blurBg: canvas !== "fit", bg: "black", audio: info.hasAudio });
        await run(FF, args, { onChild: o.onChild }).done;
        o.onProgress?.(length, length);
        return { width: p.W, height: p.H, seconds: length };
    } finally {
        srv.close();
        await browser?.close().catch(() => {});
    }
}

// CLI, for trying a spec by hand
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const [specPath, mediaDir, out] = process.argv.slice(2);
    const spec = JSON.parse(await readFile(specPath, "utf8"));
    const t0 = Date.now();
    const r = await renderPost({ spec, mediaDir, out, work: path.join(path.dirname(path.resolve(out)), ".post-work") });
    console.error(`${JSON.stringify(r)} in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
