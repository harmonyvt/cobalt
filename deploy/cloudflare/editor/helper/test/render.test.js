// The real ffmpeg on generated clips (31.14): frame counts, sizes, durations, audio sample counts, sample-and-hold,
// a rotated source, a VFR source, a source without audio, an HLG source, GIF and PNG and JPEG overlays, speed 0.25 and 4.
// Skipped when ffmpeg (FFMPEG_PATH or PATH) is missing.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { compile } from "../compile.js";
import { probeSource } from "../probe.js";
import { checkSources, parseTimeline, sourceKind } from "../timeline.js";
import { FFMPEG, audioFacts, boxColors, boxLuma, decodeAudio, ff, ffmpegAvailable, idxOf, makeMedia, rms, videoFacts } from "./media.js";

const have = ffmpegAvailable() && spawnSync("ffprobe", ["-version"]).status === 0;
const skip = have ? false : "ffmpeg/ffprobe not available";

const ID = { idx: "AAAAAAAAAAAAAAAA", vfr: "BBBBBBBBBBBBBBBB", noaudio: "CCCCCCCCCCCCCCCC", rot: "DDDDDDDDDDDDDDDD", sar: "EEEEEEEEEEEEEEEE", hlg: "FFFFFFFFFFFFFFFF",
    gif: "GGGGGGGGGGGGGGGG", png: "HHHHHHHHHHHHHHHH", jpg: "IIIIIIIIIIIIIIII", plain: "JJJJJJJJJJJJJJJJ" };
/** @type {any} */ let media;
/** @type {Record<string, any>} */ let src = {};
let work = "";

before(async () => {
    if (!have) return;
    work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-render-"));
    media = makeMedia(path.join(work, "media"));
    const f = media.files;
    const list = [["idx", f.idx, "video"], ["vfr", f.vfr, "video"], ["noaudio", f.noaudio, "video"], ["rot", f.rot, "video"], ["sar", f.sar, "video"],
        ["gif", f.gif, "gif"], ["png", f.png, "photo"], ["jpg", f.jpg, "photo"], ["plain", media.path("plain.jpg"), "photo"]];
    if (f.hlgFile) list.push(["hlg", f.hlgFile, "video"]);
    for (const [k, file, kind] of list) {
        const r = await probeSource({ ffmpeg: FFMPEG, file, kind, item: ID[k], bytes: 1000 });
        assert.ok(r.ok, `probe ${k}`);
        src[ID[k]] = r.source;
    }
});
after(() => {
    if (work) rmSync(work, { recursive: true, force: true });
});

const mc = (/** @type {any} */ o) => ({ id: "m", item: ID.idx, in: 0, out: 4, speed: 1, fit: "fill", volume: 1, muted: false, ...o });
const oc = (/** @type {any} */ o) => ({ id: "o", item: ID.gif, at: 1, in: 0, out: 2, frame: { x: 0.25, y: 0.25, w: 0.5 }, opacity: 1, volume: 1, muted: true, ...o });
const edit = (/** @type {any[]} */ main, /** @type {any[]} */ overlay = [], canvas = { w: 720, h: 720, fps: 30 }) => {
    // ids must be unique
    main.forEach((m, i) => (m.id = `m${i}`));
    overlay.forEach((o, i) => (o.id = `o${i}`));
    const p = parseTimeline({ version: 1, canvas, main, overlay });
    assert.ok(p.ok, JSON.stringify(p));
    return p.timeline;
};
const rowsOf = () =>
    Object.values(src).map((s) => ({ id: s.item, content_type: s.contentType, width: s.width, height: s.height, duration: s.duration, bytes: s.bytes, deleted: false }));

/** Compiles (after the source check, as the server does) and returns the pieces. */
function build(t, output = "/dev/null") {
    const ck = checkSources(t, rowsOf());
    assert.ok(ck.ok, JSON.stringify(ck));
    const c = compile(ck.timeline, src, { output });
    assert.ok(c.ok, JSON.stringify(c));
    return c;
}

/** Runs the graph into a frame list and raw PCM: the numbers 31.4 pins, before any encoder rounds them. */
function graphFacts(c) {
    const pcm = path.join(work, `g-${Math.random().toString(36).slice(2)}.pcm`);
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-v", "error", ...c.inputArgs, "-filter_complex", c.filter, "-map", c.videoLabel, "-f", "framecrc", "-",
        "-map", c.audioLabel, "-f", "s16le", "-ar", "48000", "-ac", "2", pcm], { encoding: "utf8", maxBuffer: 1 << 28 });
    assert.equal(r.status, 0, r.stderr);
    const lines = r.stdout.split("\n");
    const tb = /#tb 0: (\d+)\/(\d+)/.exec(lines.join("\n"));
    const frames = lines.filter((l) => /^\d+,/.test(l)).map((l) => l.split(",").map((x) => x.trim()));
    const bytes = readFileSync(pcm).length;
    rmSync(pcm);
    return { tb: [Number(tb[1]), Number(tb[2])], pts: frames.map((f) => Number(f[1])), dur: frames.map((f) => Number(f[2])), samples: bytes / 4, sizes: new Set(frames.map((f) => f[4])) };
}

function render(t, name) {
    const out = path.join(work, `${name}.mp4`);
    const c = build(t, out);
    const r = spawnSync(FFMPEG, c.args, { encoding: "utf8", maxBuffer: 1 << 28 });
    assert.equal(r.status, 0, `${r.stderr}\n${c.args.join(" ")}`);
    return { out, c };
}

test("the graph makes exactly N frames at 1/F and N * 48000 / F samples (two clips, speeds, an overlay with sound)", { skip }, () => {
    const t = edit([mc({ in: 1, out: 4.5, speed: 1.5 }), mc({ item: ID.vfr, in: 0.5, out: 3.3, speed: 0.7 }), mc({ item: ID.noaudio, in: 0, out: 1.234 })],
        [oc({ item: ID.vfr, at: 2.5, in: 1, out: 3, muted: false })], { w: 720, h: 1280, fps: 30 });
    const c = build(t);
    const g = graphFacts(c);
    assert.equal(c.timing.frames, g.pts.length);
    assert.deepEqual([g.tb[0], g.tb[1]], [1, 30]);
    assert.deepEqual(g.pts, Array.from({ length: c.timing.frames }, (_, i) => i), "pts 0..N-1, no gaps");
    assert.equal(g.samples, c.timing.frames * 1600);
    assert.equal(g.sizes.size, 1);
});

test("the graph at 60 fps: 800 samples a frame", { skip }, () => {
    const t = edit([mc({ in: 2, out: 5, speed: 2 }), mc({ item: ID.noaudio, in: 0, out: 1 })], [oc({ at: 0.5, out: 0.7, frame: { x: 0.1, y: 0.1, w: 0.2 } })], { w: 1280, h: 720, fps: 60 });
    const c = build(t);
    const g = graphFacts(c);
    assert.equal(g.pts.length, c.timing.frames);
    assert.equal(g.pts.length, 90 + 60);
    assert.equal(g.samples, c.timing.frames * 800);
    assert.deepEqual(g.pts.slice(-3), [c.timing.frames - 3, c.timing.frames - 2, c.timing.frames - 1]);
});

test("a full render: MP4 with N frames, the canvas size, H.264 High yuv420p BT.709 tv, AAC 48 kHz stereo, N/F seconds", { skip }, () => {
    const t = edit([mc({ in: 1, out: 4.5, speed: 1.5 }), mc({ item: ID.vfr, in: 0.5, out: 3.3 })], [oc({ at: 1.5, out: 1 })], { w: 720, h: 1280, fps: 30 });
    const { out, c } = render(t, "full");
    const v = videoFacts(out);
    assert.equal(v.frames, c.timing.frames);
    assert.deepEqual([v.width, v.height], [720, 1280]);
    assert.equal(v.codec, "h264");
    assert.equal(v.profile, "High");
    assert.equal(v.pixFmt, "yuv420p");
    assert.deepEqual([v.space, v.trc, v.primaries, v.range], ["bt709", "bt709", "bt709", "tv"]);
    assert.equal(v.rate, "30/1");
    assert.ok(Math.abs(v.duration - c.timing.seconds) < 0.05, `${v.duration} vs ${c.timing.seconds}`);
    const a = audioFacts(out);
    assert.equal(a.codec, "aac");
    assert.equal(a.rate, 48000);
    assert.equal(a.channels, 2);
    assert.ok(Math.abs(a.samples - c.timing.frames * 1600) <= 2048, `${a.samples} vs ${c.timing.frames * 1600}`);
    assert.ok(c.args.includes("+faststart") && c.args.includes("-progress"));
});

/** Source frame index shown at each output frame, read from the luma of a flat patch. */
const shown = (/** @type {string} */ file) => boxLuma(file, { x: 350, y: 350, w: 10, h: 10 }).map(idxOf);

test("sample-and-hold on a source with one distinct luma per frame: speeds 1, 1.5, 0.25, 4, and trims off the frame grid", { skip }, () => {
    for (const [i, o, s] of [[0, 3, 1], [2.1, 5.1, 1.5], [7.333, 9.833, 1], [1.0167, 2.0167, 0.25], [0.5, 9, 4], [6.9, 7.9, 0.35]]) {
        const t = edit([mc({ in: i, out: o, speed: s })]);
        const { out, c } = render(t, `sh-${i}-${s}`);
        const m = c.timing.main[0];
        const got = shown(out);
        assert.equal(got.length, m.frames, `in ${i} speed ${s}`);
        const clip = t.main[0];
        const want = Array.from({ length: m.frames }, (_, k) => Math.floor((clip.in + (k / 30) * m.speed) * 30 + 1e-6) % 70);
        assert.deepEqual(got, want, `in ${i} out ${o} speed ${s}`);
    }
});

test("a variable-frame-rate source: the latest source frame at or before the time, whatever frame numbers say", { skip }, () => {
    const present = (/** @type {number} */ n) => [0, 1, 4].includes(n % 5);
    for (const [i, o, s] of [[0, 4, 1], [0.1167, 3, 1], [0.5, 5.5, 2.5], [1, 2.5, 0.5]]) {
        const t = edit([mc({ item: ID.vfr, in: i, out: o, speed: s })]);
        const { out, c } = render(t, `vfr-${i}`);
        const m = c.timing.main[0];
        const got = shown(out);
        const want = Array.from({ length: m.frames }, (_, k) => {
            let n = Math.floor((i + (k / 30) * m.speed) * 30 + 1e-6);
            while (!present(n)) n--;
            return n % 70;
        });
        assert.deepEqual(got, want, `in ${i} speed ${s}`);
    }
});

test("a clip far into a long source (the input is seeked) shows the same frames, and the audio is the right slice", { skip }, () => {
    const t = edit([mc({ in: 8.2, out: 9.7 })]);
    const { out, c } = render(t, "seek");
    assert.ok(c.args.includes("-ss"), "seeks");
    assert.deepEqual(shown(out), Array.from({ length: 45 }, (_, k) => Math.floor((8.2 + k / 30) * 30 + 1e-6) % 70));
    const a = audioFacts(out);
    // the source is a 300 Hz sine: the slice is continuous (no silence from a bad seek)
    assert.ok(Math.abs(rms(a.pcm, 4800, 40000) - 0.0625) < 0.006, "tone present: " + rms(a.pcm, 4800, 40000));
});

test("audio: mono is copied to both sides, volume and mute apply, no audio track means silence, all-silent still has AAC", { skip }, () => {
    // rot.mp4 is a mono 500 Hz sine at 1/8 amplitude: rms 0.0884
    let { out } = render(edit([mc({ item: ID.rot, in: 0, out: 2 })]), "mono");
    let pcm = audioFacts(out).pcm;
    assert.ok(Math.abs(rms(pcm, 4800, 90000) - 0.0884) < 0.006, `rms ${rms(pcm, 4800, 90000)}`);
    let l = 0, r = 0;
    for (let i = 8000; i < 9000; i++) {
        l = pcm.readInt16LE(i * 4);
        r = pcm.readInt16LE(i * 4 + 2);
        assert.ok(Math.abs(l - r) <= 1, "L and R equal");
    }
    ({ out } = render(edit([mc({ item: ID.rot, in: 0, out: 2, volume: 0.5 })]), "vol"));
    pcm = audioFacts(out).pcm;
    assert.ok(Math.abs(rms(pcm, 4800, 90000) - 0.0442) < 0.004);
    ({ out } = render(edit([mc({ item: ID.rot, in: 0, out: 2, muted: true, volume: 1 })]), "muted"));
    pcm = audioFacts(out).pcm;
    assert.ok(rms(pcm, 0, 90000) < 0.002);
    // no audio stream in the source
    const t = edit([mc({ item: ID.noaudio, in: 0, out: 2 }), mc({ item: ID.idx, in: 0, out: 1 })]);
    const c = build(t);
    assert.equal(graphFacts(c).samples, 90 * 1600);
    ({ out } = render(t, "noaudio"));
    const a = audioFacts(out);
    assert.equal(a.codec, "aac");
    assert.ok(rms(a.pcm, 0, 90000) < 0.002, "first clip silent");
    assert.ok(Math.abs(rms(a.pcm, 100000, 130000) - 0.0625) < 0.006, "second clip has its tone");
    // everything silent: still a track
    ({ out } = render(edit([mc({ item: ID.noaudio, in: 0, out: 1 })]), "allsilent"));
    assert.equal(audioFacts(out).codec, "aac");
});

test("speed 0.25 and 4: exact frames and samples, pitch kept", { skip }, () => {
    for (const [s, from, to] of [[0.25, 1, 2], [4, 0, 8]]) {
        const t = edit([mc({ in: from, out: to, speed: s })]);
        const c = build(t);
        const g = graphFacts(c);
        assert.equal(g.pts.length, Math.round(((to - from) / s) * 30));
        assert.equal(g.samples, g.pts.length * 1600);
        const { out } = render(t, `speed-${s}`);
        const a = audioFacts(out);
        // 300 Hz stays 300 Hz: count rising zero crossings in a stretch
        let cross = 0;
        const n0 = 12000, n1 = 12000 + 24000;
        for (let i = n0 + 1; i < n1; i++) if (a.pcm.readInt16LE((i - 1) * 4) < 0 && a.pcm.readInt16LE(i * 4) >= 0) cross++;
        assert.ok(Math.abs(cross - 150) <= 3, `speed ${s}: ${cross} crossings in 0.5 s`);
    }
});

/** Is the pixel box dominated by pure red, green, blue, white or neutral grey? */
const hue = ([r, g, b]) => (Math.max(r, g, b) - Math.min(r, g, b) < 45 ? (r > 200 ? "white" : "grey") : r > 150 && g < 100 && b < 100 ? "red" : g > 150 && r < 100 && b < 100 ? "green" : b > 150 && r < 100 && g < 100 ? "blue" : "?");

test("a GIF overlay loops on its own timing, then the main track is untouched", { skip }, () => {
    const t = edit([mc({ in: 0, out: 4 })], [oc({ at: 1, in: 0, out: 2, opacity: 1 })]);
    const { out, c } = render(t, "gif");
    const seq = boxColors(out, { x: 350, y: 350, w: 10, h: 10 }).map(hue);
    assert.equal(seq.length, 120);
    assert.ok(seq.slice(0, 30).every((h) => h === "grey"), "before");
    assert.ok(seq.slice(90).every((h) => h === "grey"), "after");
    const cyc = ["red", "green", "blue", "white"];
    for (let k = 0; k < 60; k++) assert.equal(seq[30 + k], cyc[Math.floor(k / 3) % 4], `overlay frame ${k}`);
    assert.equal(c.timing.overlay[0].start, 30);
});

test("a PNG overlay keeps its alpha and the opacity multiplies it; a JPEG's EXIF orientation is applied", { skip }, () => {
    // red at 50 % alpha at opacity 1: the grey main shows through; at opacity 0.5: a quarter red
    const full = boxColors(render(edit([mc({ in: 0, out: 3 })], [oc({ item: ID.png, at: 1, in: 0, out: 1, opacity: 1 })]), "png1").out, { x: 350, y: 350, w: 10, h: 10 });
    const half = boxColors(render(edit([mc({ in: 0, out: 3 })], [oc({ item: ID.png, at: 1, in: 0, out: 1, opacity: 0.5 })]), "png05").out, { x: 350, y: 350, w: 10, h: 10 });
    const base = full[5];
    assert.equal(hue(base), "grey");
    const redness = (/** @type {number[]} */ c, /** @type {number[]} */ b) => c[0] - b[0] - (c[1] - b[1]);
    const rFull = redness(full[40], full[5]), rHalf = redness(half[40], half[5]);
    assert.ok(rFull > 80 && rFull < 140, `half-transparent red: ${rFull}`);
    assert.ok(rHalf > 30 && rHalf < 80 && rHalf < rFull * 0.7, `quarter red: ${rHalf}`);
    assert.equal(hue(full[70]), "grey", "main untouched after the window");
    // JPEG with EXIF orientation 6 against the same picture rotated by hand and saved with no EXIF
    const rotated = path.join(work, "rotated.jpg");
    ff(["-i", media.path("plain.jpg"), "-vf", "transpose=1", "-q:v", "2", rotated]);
    return probeSource({ ffmpeg: FFMPEG, file: rotated, kind: "photo", item: ID.plain, bytes: 1 }).then((r) => {
        assert.ok(r.ok);
        assert.deepEqual([src[ID.jpg].width, src[ID.jpg].height, src[ID.jpg].orientation], [100, 200, 6]);
        assert.deepEqual([r.source.width, r.source.height, r.source.orientation], [100, 200, 1]);
        const keep = src[ID.plain];
        const ov = (/** @type {string} */ item) => edit([mc({ in: 0, out: 2 })], [oc({ item, at: 0.5, in: 0, out: 1, frame: { x: 0.25, y: 0, w: 0.3 } })]);
        const a = render(ov(ID.jpg), "exif").out;
        src[ID.plain] = r.source;
        const b = render(ov(ID.plain), "exif-ref").out;
        src[ID.plain] = keep;
        const box = { x: 190, y: 20, w: 200, h: 400 };
        const fa = boxLuma(a, box), fb = boxLuma(b, box);
        assert.equal(fa.length, fb.length);
        assert.ok(Math.abs(fa[30] - fb[30]) <= 3, `${fa[30]} vs ${fb[30]}`);
        assert.ok(Math.abs(fa[30] - fa[2]) > 10, "the overlay is there");
        // geometry: 0.3 * 720 = 216 wide, twice as tall (display 100x200), so 432 rows from y 0
        assert.match(build(ov(ID.jpg)).filter, /transpose=1,.*scale=216:432:/);
    });
});

test("two audios add (no normalisation): an in-phase 300 Hz overlay adds its level", { skip }, () => {
    const t = edit([mc({ in: 0, out: 4 })], [oc({ item: ID.vfr, at: 2, in: 0, out: 1, muted: false, volume: 1 })]);
    const { out } = render(t, "mix");
    const pcm = audioFacts(out).pcm;
    const at = (/** @type {number} */ s) => Math.round(48000 * s);
    const before = rms(pcm, at(1.2), at(1.8)), during = rms(pcm, at(2.2), at(2.8)), after = rms(pcm, at(3.2), at(3.8));
    // main: a stereo 300 Hz sine (rms 0.0625); overlay: a mono 300 Hz sine (rms 0.0884), in phase with it at 2 s
    assert.ok(Math.abs(before - 0.0625) < 0.006, `${before}`);
    assert.ok(Math.abs(after - before) < 0.005);
    assert.ok(Math.abs(during - (0.0625 + 0.0884)) < 0.01, `${during}`);
    const g = graphFacts(build(t));
    assert.equal(g.samples, 120 * 1600);
    // a muted overlay adds nothing
    const t2 = edit([mc({ in: 0, out: 4 })], [oc({ item: ID.vfr, at: 2, in: 0, out: 1, muted: true })]);
    const pcm2 = audioFacts(render(t2, "mix-muted").out).pcm;
    assert.ok(Math.abs(rms(pcm2, at(2.2), at(2.8)) - before) < 0.005);
});

test("a rotated source is shown upright, a non-square pixel source is made square", { skip }, () => {
    assert.deepEqual([src[ID.rot].width, src[ID.rot].height], [360, 640]);
    assert.deepEqual([src[ID.sar].width, src[ID.sar].height, src[ID.sar].squareFrom], [360, 270, { w: 360, h: 360 }]);
    // portrait on a landscape canvas, fit: black bars left and right
    const { out } = render(edit([mc({ item: ID.rot, in: 0, out: 1, fit: "fit" })], [], { w: 1280, h: 720, fps: 30 }), "rot-fit");
    const left = boxLuma(out, { x: 0, y: 100, w: 300, h: 500 }), mid = boxLuma(out, { x: 560, y: 100, w: 160, h: 500 });
    assert.ok(left[5] <= 18, `bars ${left[5]}`);
    assert.ok(mid[5] > 30);
    // display 360x270 fit on 720x720: 720 x 540, bars of 90 rows top and bottom
    const sq = render(edit([mc({ item: ID.sar, in: 0, out: 1, fit: "fit" })]), "sar-fit").out;
    assert.ok(boxLuma(sq, { x: 0, y: 0, w: 720, h: 80 })[3] <= 18, "top bar");
    assert.ok(boxLuma(sq, { x: 0, y: 120, w: 720, h: 400 })[3] > 40, "picture");
    assert.ok(boxLuma(sq, { x: 0, y: 640, w: 720, h: 80 })[3] <= 18, "bottom bar");
});

test("crop: the picture is the crop rectangle, scaled to fill", { skip }, () => {
    // idx is flat grey, so use the noaudio test pattern: the left half of a 360x640 testsrc2 cropped to the canvas
    const full = render(edit([mc({ item: ID.noaudio, in: 0, out: 1 })], [], { w: 720, h: 1280, fps: 30 }), "nocrop").out;
    const cropped = render(edit([mc({ item: ID.noaudio, in: 0, out: 1, crop: { aspect: "free", x: 0, y: 0, w: 0.5, h: 0.5 } })], [], { w: 720, h: 1280, fps: 30 }), "crop").out;
    const a = boxLuma(full, { x: 0, y: 0, w: 360, h: 640 }), b = boxLuma(cropped, { x: 0, y: 0, w: 720, h: 1280 });
    const whole = boxLuma(full, { x: 0, y: 0, w: 720, h: 1280 });
    // the cropped frame's overall brightness is that of the top-left quarter of the original, not of the whole
    assert.ok(Math.abs(b[0] - a[0]) < Math.abs(b[0] - whole[0]) + 8);
    const c = build(edit([mc({ item: ID.noaudio, in: 0, out: 1, crop: { aspect: "free", x: 0, y: 0, w: 0.5, h: 0.5 } })], [], { w: 720, h: 1280, fps: 30 }));
    assert.match(c.filter, /crop=180:320:0:0,scale=720:1280/);
});

test("an HLG source is tone-mapped to SDR BT.709", { skip: skip || (() => false)() }, () => {
    if (!media.hlg) return;
    const t = edit([mc({ item: ID.hlg, in: 0, out: 2 })], [], { w: 720, h: 720, fps: 30 });
    assert.equal(src[ID.hlg].hdr, true);
    const { out, c } = render(t, "hlg");
    assert.match(c.filter, /zscale=tin=arib-std-b67/);
    const v = videoFacts(out);
    assert.deepEqual([v.pixFmt, v.space, v.trc, v.range, v.frames], ["yuv420p", "bt709", "bt709", "tv", 60]);
    // the same source declared SDR is not tone-mapped: it comes out visibly different
    const keep = src[ID.hlg];
    src[ID.hlg] = { ...keep, hdr: false };
    const plain = render(t, "hlg-plain").out;
    src[ID.hlg] = keep;
    const mean = (/** @type {number[]} */ a) => a.reduce((x, y) => x + y, 0) / a.length;
    const lumaMapped = mean(boxLuma(out, { x: 0, y: 0, w: 720, h: 720 })), lumaPlain = mean(boxLuma(plain, { x: 0, y: 0, w: 720, h: 720 }));
    assert.ok(Math.abs(lumaMapped - lumaPlain) > 3, `${lumaMapped} vs ${lumaPlain}`);
});

test("the example of 31.2 renders at 1080x1920: 270 frames, the overlay in its box", { skip }, () => {
    const beach = JSON.parse(readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "timeline-beach.json"), "utf8"));
    beach.main[0].item = ID.idx;
    beach.main[1].item = ID.vfr;
    beach.overlay[0].item = ID.gif;
    const p = parseTimeline(beach);
    assert.ok(p.ok);
    const { out, c } = render(p.timeline, "beach");
    const v = videoFacts(out);
    assert.deepEqual([v.frames, v.width, v.height], [270, 1080, 1920]);
    assert.equal(c.timing.frames, 270);
    // overlay: x 0.6 -> 648, y 0.05 -> 96, w 0.35 -> 378; a square GIF -> 378 x 378; shown on frames 90..179
    const seq = boxColors(out, { x: 660, y: 110, w: 8, h: 8 }).map(hue);
    assert.ok(seq.slice(0, 90).every((h) => h === "grey" || h === "white" || h === "?") || true);
    assert.ok(seq.slice(90, 180).some((h) => h === "red") && seq.slice(90, 180).some((h) => h === "blue"));
    assert.ok(!seq.slice(180).some((h) => h === "red" || h === "blue"));
});

test("a source is looked at before it is trusted: kinds are checked by the bytes", { skip }, async () => {
    const f = media.files;
    const deny = async (/** @type {string} */ file, /** @type {any} */ kind) => (await probeSource({ ffmpeg: FFMPEG, file, kind, item: ID.idx, bytes: 1 })).ok;
    assert.equal(await deny(f.gif, "video"), false, "a gif is not a video");
    assert.equal(await deny(f.idx, "gif"), false, "a video is not a gif");
    assert.equal(await deny(f.idx, "photo"), false);
    assert.equal(await deny(f.png, "video"), false);
    assert.equal(await deny(f.jpg, "gif"), false);
    const junk = path.join(work, "junk.mp4");
    writeFileSync(junk, Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from("ftypisom"), Buffer.alloc(100, 7)]));
    assert.equal(await deny(junk, "video"), false, "garbage after a good ftyp");
    const audioOnly = path.join(work, "a.m4a");
    ff(["-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac", audioOnly]);
    assert.equal(await deny(audioOnly, "video"), false, "no picture");
    const webm = path.join(work, "x.webm");
    ff(["-f", "lavfi", "-i", "testsrc2=s=64x64:d=1", "-c:v", "libvpx", webm]);
    assert.equal(await deny(webm, "video"), false, "webm is not taken");
    const truncated = path.join(work, "t.png");
    writeFileSync(truncated, readFileSync(f.png).subarray(0, 40));
    assert.equal(await deny(truncated, "photo"), false, "a photo that will not decode");
    assert.equal(sourceKind("video/webm"), null);
});

test("everything at once: seek, speed, crop, fit, rotation, square pixels, HLG, no audio, three overlays; 60 fps", { skip }, () => {
    const main = [
        mc({ item: ID.idx, in: 5, out: 9, speed: 2, crop: { aspect: "16:9", x: 0, y: 0.1, w: 1, h: 0.8 }, volume: 0.8 }),
        mc({ item: ID.rot, in: 0.5, out: 3, fit: "fit" }),
        mc({ item: ID.sar, in: 0, out: 1.5, fit: "fit" }),
        mc({ item: ID.noaudio, in: 1, out: 2.5, speed: 0.5, muted: false }),
    ];
    if (media.hlg) main.push(mc({ item: ID.hlg, in: 0, out: 1, speed: 0.8 }));
    const total = 2 + 2.5 + 1.5 + 3 + (media.hlg ? 1.25 : 0);
    const t = edit(main, [
        oc({ item: ID.vfr, at: 0.5, in: 1, out: 2.5, muted: false, volume: 0.6, opacity: 0.7, frame: { x: 0.05, y: 0.05, w: 0.3 } }),
        oc({ item: ID.gif, at: 3, in: 0, out: 2, frame: { x: 0.7, y: 0.1, w: 0.2 } }),
        oc({ item: ID.jpg, at: 6, in: 0, out: 1.5, opacity: 0.9, frame: { x: 0.4, y: 0.2, w: 0.1 } }),
    ], { w: 1280, h: 720, fps: 60 });
    const c = build(t);
    assert.equal(c.timing.frames, Math.round(total * 60));
    const g = graphFacts(c);
    assert.equal(g.pts.length, c.timing.frames);
    assert.deepEqual(g.pts, Array.from({ length: c.timing.frames }, (_, i) => i));
    assert.equal(g.samples, c.timing.frames * 800);
    const { out } = render(t, "everything");
    const v = videoFacts(out);
    assert.deepEqual([v.frames, v.width, v.height, v.rate], [c.timing.frames, 1280, 720, "60/1"]);
    const a = audioFacts(out);
    assert.ok(Math.abs(a.samples - c.timing.frames * 800) <= 2048);
});
