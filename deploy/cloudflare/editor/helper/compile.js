// Timeline + probed inputs -> ONE ffmpeg argv (APP-API-CONTRACT.md 31.4 timing, 31.5 order of operations, 31.6 geometry).
// Pure: no I/O, no clock, no randomness. Plain Node ESM; imports only timeline.js.
//
// Graph shape: every main clip and every overlay clip is its own `-i` (so one file used twice is read twice; simple and
// robust), each main clip becomes [v<i>] + [a<i>] of exactly frames_i frames / frames_i * 48000 / F samples, `concat` joins
// them, one `overlay` per overlay clip in `at` order, `amix` sums the audio.
//
// Sample-and-hold (31.4): output frame k of a clip shows the latest source frame at or before in + k / F * s. The graph does
// it as: trim only the END, shift time so `in` is 0 (frames before it get negative pts), divide by the speed, then
// `fps=F:round=up:start_time=0` which keeps the latest frame at or before time 0 and drops the older ones. (Trimming at
// `in` and rebasing, the text of 31.5 step 3, would lose that frame whenever `in` falls between two source frames.)
// The input is opened with `-ss` a few seconds before `in` and `-t` after `out` so a clip of a long file does not decode
// the whole file; timestamps are relative to that seek, so the filter times are `in - seek`.

import { EDIT_SAMPLE_RATE, mainPlacement, overlayPlacement, timing } from "./timeline.js";
import { orientationFilters } from "./probe.js";

/** Seconds of decoding before `in` (a held source frame older than this is not found; a keyframe interval is usually 1-2 s). */
export const SEEK_MARGIN = 3;

/** Plain decimal, never "1e-7", which ffmpeg would misread. @param {number} n @param {number} [places] */
export const dec = (n, places = 3) => String(+Number(n).toFixed(places) + 0);

/** Max bitrate per canvas/fps (31.5 Output): 12M (1080p30), 16M (1080p60), 6M (720p30), 9M (720p60). @param {{w: number, h: number, fps: number}} canvas */
export function maxrateFor(canvas) {
    const p1080 = Math.min(canvas.w, canvas.h) >= 1080;
    return p1080 ? (canvas.fps === 60 ? 16 : 12) : canvas.fps === 60 ? 9 : 6;
}

/**
 * The `atempo` factors for effective speed `s` (31.5 step 8): each in [0.5, 2]; 0.25 -> 0.5,0.5; 3 -> 2,1.5; 4 -> 2,2; 1 -> none.
 * @param {number} s @returns {number[]}
 */
export function atempoChain(s) {
    /** @type {number[]} */
    const out = [];
    let r = s;
    while (r > 2) {
        out.push(2);
        r /= 2;
    }
    while (r < 0.5) {
        out.push(0.5);
        r /= 0.5;
    }
    if (Math.abs(r - 1) >= 1e-6) out.push(r);
    return out;
}

const HDR_CHAIN = (/** @type {string} */ tr) =>
    `zscale=tin=${tr}:pin=bt2020:min=bt2020nc:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv`;

/** The video path of a decoded source up to colour (31.5 steps 1-2). @param {import("./probe.js").Source} s @returns {string[]} */
function decodeSteps(s) {
    /** @type {string[]} */
    const f = [];
    if (s.kind === "photo") f.push(...orientationFilters(s.orientation));
    if (s.squareFrom) f.push(`scale=${s.width}:${s.height}:flags=bicubic`, "setsar=1");
    if (s.hdr && s.transfer) f.push(HDR_CHAIN(s.transfer));
    return f;
}

/** `-i` arguments of a source and the seek offset its filters must subtract. @param {import("./probe.js").Source} s @param {number} F
 * @param {{in: number, out: number, seconds: number}} w @returns {{args: string[], seek: number}} */
function inputFor(s, F, w) {
    const wl = ["-protocol_whitelist", "file,pipe"];
    if (s.kind === "photo") {
        return { args: [...wl, ...(s.contentType === "image/jpeg" ? ["-noautorotate"] : []), "-loop", "1", "-framerate", String(F), "-t", dec(w.seconds + 1), "-i", s.path], seek: 0 };
    }
    if (s.kind === "gif") return { args: [...wl, "-i", s.path], seek: 0 };
    const seek = Math.max(0, Math.floor((w.in - SEEK_MARGIN) * 1000) / 1000);
    return { args: [...wl, ...(seek > 0 ? ["-ss", dec(seek)] : []), "-t", dec(w.out - seek + 1), "-i", s.path], seek };
}

/** Audio chain head shared by main and overlay: (a) trim to in..out on the seek-relative clock. @param {number} inT @param {number} outT */
const audioTrim = (inT, outT) => `atrim=start=${dec(inT, 6)}:end=${dec(outT, 6)},asetpts=PTS-STARTPTS`;

/** Stereo 48 kHz float: mono is copied to both sides (a bare aformat would mix it in at -3 dB). @param {number | null} channels */
const toStereo = (channels) =>
    (channels === 1 ? ["pan=stereo|c0=c0|c1=c0"] : []).concat(["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=stereo"]);

/**
 * @typedef {{ok: true, args: string[], inputArgs: string[], filter: string, videoLabel: string, audioLabel: string,
 *            timing: ReturnType<typeof timing>, outputArgs: string[]}} Compiled
 */

/**
 * Builds the graph. `sources` maps an item id to its probed Source (probe.js). Returns the pieces (`inputArgs`, `filter`,
 * the two output labels) so a test can send the same graph to another muxer, plus `args`, the whole argv for the real render.
 * `{ok: false, code, path}` when a crop is under 64 px (error.edit.range) or a source is missing (error.edit.input_missing).
 * @param {import("./timeline.js").Timeline} t the parsed, source-checked (clamped) timeline
 * @param {Record<string, import("./probe.js").Source> | Map<string, import("./probe.js").Source>} sources
 * @param {{output: string, progress?: boolean, loglevel?: string}} opts
 * @returns {Compiled | {ok: false, code: string, path: string}}
 */
export function compile(t, sources, opts) {
    const src = (/** @type {string} */ item) => (sources instanceof Map ? sources.get(item) : sources[item]);
    const F = t.canvas.fps;
    const { w: W, h: H } = t.canvas;
    const tm = timing(t);
    const N = tm.frames;
    const spf = EDIT_SAMPLE_RATE / F;
    /** @type {string[]} */
    const inputArgs = [];
    /** @type {string[]} */
    const chains = [];
    let inputs = 0;

    // ---- main track
    /** @type {string[]} */
    const concatIn = [];
    for (let i = 0; i < t.main.length; i++) {
        const c = t.main[i], m = tm.main[i], s = src(c.item);
        if (!s) return { code: "error.edit.input_missing", ok: false, path: `main[${i}].item` };
        const pl = mainPlacement({ h: s.height, w: s.width }, c.crop ?? null, c.fit, t.canvas);
        if (!pl) return { code: "error.edit.range", ok: false, path: `main[${i}].crop` };
        const n = inputs++;
        const inp = inputFor(s, F, { in: c.in, out: c.out, seconds: c.out - c.in });
        inputArgs.push(...inp.args);
        const inT = c.in - inp.seek, outT = c.out - inp.seek;

        const v = [...decodeSteps(s)];
        v.push(`trim=end=${dec(outT, 6)}`, `setpts=(PTS-${dec(inT, 6)}/TB)/${dec(m.speed, 9)}`);
        v.push(`fps=${F}:round=up:start_time=0`, `tpad=stop_mode=clone:stop_duration=${dec(m.frames / F + 1)}`, `trim=end_frame=${m.frames}`);
        const cr = pl.crop;
        if (c.crop || cr.w !== s.width || cr.h !== s.height) v.push(`crop=${cr.w}:${cr.h}:${cr.x}:${cr.y}`);
        v.push(`scale=${pl.scaled.w}:${pl.scaled.h}:flags=bicubic:out_color_matrix=bt709:out_range=tv`, "format=yuv420p", "setsar=1");
        if (c.fit === "fit") {
            if (pl.scaled.w !== W || pl.scaled.h !== H) v.push(`pad=${W}:${H}:${pl.place.x}:${pl.place.y}:black`);
        } else if (pl.scaled.w !== W || pl.scaled.h !== H) v.push(`crop=${W}:${H}:${-pl.place.x}:${-pl.place.y}`);
        chains.push(`[${n}:v:0]${v.join(",")}[v${i}]`);

        if (s.hasAudio && !c.muted) {
            const a = [audioTrim(inT, outT), ...atempoChain(m.speed).map((r) => `atempo=${dec(r, 9)}`)];
            a.push(`volume=${dec(c.volume, 2)}`, ...toStereo(s.channels), "apad", `atrim=end_sample=${m.samples}`, "asetpts=PTS-STARTPTS");
            chains.push(`[${n}:a:0]${a.join(",")}[a${i}]`);
        } else {
            chains.push(`anullsrc=r=48000:cl=stereo,atrim=end_sample=${m.samples},asetpts=PTS-STARTPTS[a${i}]`);
        }
        concatIn.push(`[v${i}][a${i}]`);
    }
    chains.push(`${concatIn.join("")}concat=n=${t.main.length}:v=1:a=1[vm][am]`);

    // ---- overlay track
    let vLast = "[vm]";
    /** @type {string[]} */
    const mixIn = ["[am]"];
    for (let j = 0; j < t.overlay.length; j++) {
        const o = t.overlay[j], om = tm.overlay[j], s = src(o.item);
        if (!s) return { code: "error.edit.input_missing", ok: false, path: `overlay[${j}].item` };
        const box = overlayPlacement({ h: s.height, w: s.width }, o.frame, t.canvas);
        const n = inputs++;
        const len = o.out - o.in;
        const inp = inputFor(s, F, { in: o.in, out: o.out, seconds: om.frames / F });
        inputArgs.push(...inp.args);
        const inT = o.in - inp.seek, outT = o.out - inp.seek;

        const v = [...decodeSteps(s)];
        if (s.kind === "gif") v.push("loop=loop=-1:size=32767", `trim=duration=${dec(len, 6)}`, "setpts=PTS-STARTPTS");
        else if (s.kind === "video") v.push(`trim=end=${dec(outT, 6)}`, `setpts=PTS-${dec(inT, 6)}/TB`);
        v.push(`fps=${F}:round=up:start_time=0`, `tpad=stop_mode=clone:stop_duration=${dec(om.frames / F + 1)}`, `trim=end_frame=${om.frames}`);
        v.push(`scale=${box.w}:${box.h}:flags=bicubic:out_color_matrix=bt709:out_range=tv`, "format=yuva420p");
        if (o.opacity < 1) v.push(`colorchannelmixer=aa=${dec(o.opacity, 2)}`);
        v.push(`setpts=PTS-STARTPTS+${om.start}/(${F}*TB)`);
        chains.push(`[${n}:v:0]${v.join(",")}[ov${j}]`);
        chains.push(`${vLast}[ov${j}]overlay=${box.x}:${box.y}:eof_action=pass:format=auto[vo${j}]`);
        vLast = `[vo${j}]`;

        if (s.kind === "video" && s.hasAudio && !o.muted) {
            const a = [audioTrim(inT, outT), `volume=${dec(o.volume, 2)}`, ...toStereo(s.channels), `atrim=end_sample=${om.samples}`, "asetpts=PTS-STARTPTS"];
            a.push(`adelay=${om.start * spf}S:all=1`, "apad", `atrim=end_sample=${N * spf}`);
            chains.push(`[${n}:a:0]${a.join(",")}[oa${j}]`);
            mixIn.push(`[oa${j}]`);
        }
    }
    if (mixIn.length > 1) {
        chains.push(`${mixIn.join("")}amix=inputs=${mixIn.length}:duration=first:dropout_transition=0:normalize=0[aout]`);
    }
    const videoLabel = vLast;
    const audioLabel = mixIn.length > 1 ? "[aout]" : "[am]";
    const filter = chains.join(";");

    const M = maxrateFor(t.canvas);
    const outputArgs = [
        "-c:v", "libx264", "-profile:v", "high", "-preset", "veryfast", "-crf", "20",
        "-maxrate", `${M}M`, "-bufsize", `${2 * M}M`, "-g", String(2 * F), "-pix_fmt", "yuv420p",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        "-fps_mode", "cfr", "-r", String(F),
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart",
        ...(opts.progress === false ? [] : ["-progress", "pipe:1", "-nostats"]),
    ];
    const args = [
        "-nostdin", "-hide_banner", "-loglevel", opts.loglevel ?? "error", "-y",
        ...inputArgs,
        "-filter_complex", filter,
        "-map", videoLabel, "-map", audioLabel,
        ...outputArgs,
        opts.output,
    ];
    return { args, audioLabel, filter, inputArgs, ok: true, outputArgs, timing: tm, videoLabel };
}
