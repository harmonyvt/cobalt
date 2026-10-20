import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { SEEK_MARGIN, atempoChain, compile, dec, maxrateFor } from "../compile.js";
import { parseTimeline } from "../timeline.js";
import { fakeSources } from "./fakes.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fx = (/** @type {string} */ n) => JSON.parse(readFileSync(path.join(here, "fixtures", n), "utf8"));
const A = "AAAAAAAAAAAAAAAA", B = "BBBBBBBBBBBBBBBB", C = "CCCCCCCCCCCCCCCC";
const mc = (/** @type {any} */ o = {}) => ({ id: "m", item: A, in: 0, out: 4, speed: 1, fit: "fill", volume: 1, muted: false, ...o });
const oc = (/** @type {any} */ o = {}) => ({ id: "o", item: B, at: 1, in: 0, out: 2, frame: { x: 0.6, y: 0.05, w: 0.35 }, opacity: 1, volume: 1, muted: true, ...o });
const edit = (/** @type {any[]} */ main, /** @type {any[]} */ overlay = [], canvas = { w: 1080, h: 1920, fps: 30 }) => {
    main.forEach((m, i) => (m.id = `m${i}`));
    overlay.forEach((o, i) => (o.id = `o${i}`));
    const p = parseTimeline({ version: 1, canvas, main, overlay });
    assert.ok(p.ok, JSON.stringify(p));
    return p.timeline;
};
/** An explicit probed source. */
const V = (/** @type {string} */ item, /** @type {number} */ w, /** @type {number} */ h, /** @type {any} */ o = {}) => ({
    item, path: `/in/${item.slice(0, 1)}`, kind: "video", contentType: "video/mp4", bytes: 1000, width: w, height: h, squareFrom: null, duration: 100, hasAudio: true,
    channels: 2, hdr: false, transfer: null, orientation: 1, ...o,
});
const std = () => ({ [A]: V(A, 1920, 1080), [B]: V(B, 1080, 1920, { channels: 1 }), [C]: V(C, 3840, 2160, { hdr: true, transfer: "arib-std-b67" }) });
const build = (/** @type {any} */ t, /** @type {any} */ extra = {}) => {
    const c = compile(t, { ...std(), ...extra }, { output: "/o/out.mp4" });
    assert.ok(c.ok, JSON.stringify(c));
    return c;
};

test("the atempo chain: factors within [0.5, 2] (31.5 step 8)", () => {
    assert.deepEqual(atempoChain(1), []);
    assert.deepEqual(atempoChain(1.5), [1.5]);
    assert.deepEqual(atempoChain(0.25), [0.5, 0.5]);
    assert.deepEqual(atempoChain(3), [2, 1.5]);
    assert.deepEqual(atempoChain(4), [2, 2]);
    assert.deepEqual(atempoChain(2), [2]);
    assert.deepEqual(atempoChain(0.5), [0.5]);
    assert.deepEqual(atempoChain(0.3), [0.5, 0.6]);
    assert.deepEqual(atempoChain(1 + 1e-7), []);
    for (const s of [0.25, 0.3, 0.45, 0.7, 1.35, 2.2, 3.85, 4]) {
        const f = atempoChain(s);
        assert.ok(f.every((x) => x >= 0.5 && x <= 2));
        assert.ok(Math.abs(f.reduce((a, b) => a * b, 1) - s) < 1e-9, `${s}`);
    }
});

test("dec never writes an exponent and drops trailing zeros", () => {
    assert.equal(dec(1e-7), "0");
    assert.equal(dec(2), "2");
    assert.equal(dec(2.5), "2.5");
    assert.equal(dec(0.123456, 6), "0.123456");
    assert.equal(dec(-0.0000001, 6), "0");
    assert.equal(dec(1 / 3, 9), "0.333333333");
    assert.equal(dec(123456789.5, 3), "123456789.5");
});

test("maxrate: 12M (1080p30), 16M (1080p60), 6M (720p30), 9M (720p60)", () => {
    assert.equal(maxrateFor({ w: 1080, h: 1920, fps: 30 }), 12);
    assert.equal(maxrateFor({ w: 1920, h: 1080, fps: 60 }), 16);
    assert.equal(maxrateFor({ w: 1080, h: 1080, fps: 30 }), 12);
    assert.equal(maxrateFor({ w: 720, h: 1280, fps: 30 }), 6);
    assert.equal(maxrateFor({ w: 1280, h: 720, fps: 60 }), 9);
    assert.equal(maxrateFor({ w: 720, h: 720, fps: 60 }), 9);
});

test("the output options are those of 31.5", () => {
    const c = build(edit([mc()]));
    const a = c.args;
    const out = a.slice(a.indexOf("-map") + 4);
    assert.equal(out.at(-1), "/o/out.mp4");
    assert.equal(out.join(" "), "-c:v libx264 -profile:v high -preset veryfast -crf 20 -maxrate 12M -bufsize 24M -g 60 -pix_fmt yuv420p -color_primaries bt709 " +
        "-color_trc bt709 -colorspace bt709 -color_range tv -fps_mode cfr -r 30 -c:a aac -b:a 160k -ar 48000 -ac 2 -movflags +faststart -progress pipe:1 -nostats /o/out.mp4");
    const c60 = build(edit([mc()], [], { w: 1280, h: 720, fps: 60 }));
    assert.match(c60.args.join(" "), /-maxrate 9M -bufsize 18M -g 120 .* -r 60 /);
    assert.ok(build(edit([mc()])).args.includes("-y"));
});

test("argv for each fixture timeline is the golden one (fixtures/argv.json)", () => {
    const golden = fx("argv.json");
    assert.equal(golden.length, 14);
    const beach = JSON.parse(readFileSync(path.join(here, "fixtures", "timeline-beach.json"), "utf8"));
    const cases = [{ name: "timeline-beach", timeline: parseTimeline(beach).timeline }, ...fx("timing.json").map((c) => ({ name: c.name, timeline: c.timeline }))];
    for (const [i, c] of cases.entries()) {
        const got = compile(c.timeline, fakeSources(c.timeline), { output: "/tmp/edit/R/out.mp4" });
        assert.ok(got.ok);
        assert.equal(golden[i].name, c.name);
        assert.deepEqual(got.args, golden[i].args, c.name);
    }
    // the last golden case needs fixtures only gen-fixtures knows; it must still be well formed
    const last = golden.at(-1).args;
    assert.ok(last.includes("-filter_complex") && last.at(-1) === "/tmp/edit/R/out.mp4");
});

test("nothing odd in any fixture graph: no exponent, NaN or undefined; every chain is labelled and used", () => {
    for (const g of fx("argv.json")) {
        const f = g.args[g.args.indexOf("-filter_complex") + 1];
        assert.doesNotMatch(f, /NaN|undefined|Infinity|e[+-]\d|\bnull\b/, g.name);
        const made = [...f.matchAll(/\[([a-z]+\d*)\](?=[;]|$)/g)].map((m) => m[1]);
        const used = [...f.matchAll(/(?:^|;)((?:\[[a-z]+\d+\])+)[a-z]/g)].flatMap((m) => [...m[1].matchAll(/\[([a-z]+\d+)\]/g)].map((x) => x[1]));
        for (const u of used) assert.ok(made.includes(u), `${g.name}: ${u} used but never made`);
        assert.ok(f.length < 100_000, "one argument stays under the 128 KiB limit");
    }
});

test("the graph of one main clip follows 31.5 in order", () => {
    // 1920x1080 source, crop 9:16 x 0.3 w 0.3164: 608x1080 at (576, 0), already the canvas height at k = 1920/1080... scaled to 1080x1920
    const t = edit([mc({ in: 2, out: 9.5, speed: 1.5, crop: { aspect: "9:16", x: 0.3, y: 0, w: 0.3164, h: 1 }, volume: 0.7 })]);
    const f = build(t).filter;
    const v = f.split(";")[0];
    assert.equal(v, "[0:v:0]trim=end=9.5,setpts=(PTS-2/TB)/1.5,fps=30:round=up:start_time=0,tpad=stop_mode=clone:stop_duration=6,trim=end_frame=150," +
        "crop=608:1080:576:0,scale=1080:1920:flags=bicubic:out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1[v0]");
    const a = f.split(";")[1];
    assert.equal(a, "[0:a:0]atrim=start=2:end=9.5,asetpts=PTS-STARTPTS,atempo=1.5,volume=0.7,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo," +
        "apad,atrim=end_sample=240000,asetpts=PTS-STARTPTS[a0]");
    assert.match(f, /\[v0\]\[a0\]concat=n=1:v=1:a=1\[vm\]\[am\]$/);
    // a 960x540 crop of 1920x1080 on 1080x1920, fill: scaled to 3414x1920, then the centre 1080 cut out
    const t2 = edit([mc({ crop: { aspect: "free", x: 0, y: 0, w: 0.5, h: 0.5 } })]);
    assert.match(build(t2).filter.split(";")[0], /crop=960:540:0:0,scale=3414:1920:.*,setsar=1,crop=1080:1920:1167:0\[v0\]$/);
});

test("a clip far into its source is opened with -ss and -t and its filter times are relative to the seek", () => {
    const c = build(edit([mc({ in: 40.5, out: 44.25 })]));
    const i = c.inputArgs.indexOf("-ss");
    assert.equal(c.inputArgs[i + 1], String(40.5 - SEEK_MARGIN));
    assert.equal(c.inputArgs[c.inputArgs.indexOf("-t") + 1], "7.75");
    assert.match(c.filter, /trim=end=6\.75,setpts=\(PTS-3\/TB\)\/0\.99/);
    assert.match(c.filter, /atrim=start=3:end=6\.75/);
    // near the start: no seek
    assert.ok(!build(edit([mc({ in: 2.5, out: 4 })])).inputArgs.includes("-ss"));
    assert.ok(build(edit([mc({ in: 3.5, out: 4 })])).inputArgs.includes("-ss"));
});

test("fit pads, fill crops, neither when the size already matches; an odd source is cropped even", () => {
    assert.match(build(edit([mc({ fit: "fit" })])).filter, /scale=1080:608:.*pad=1080:1920:0:656:black\[v0\]/);
    assert.match(build(edit([mc({ fit: "fill" })])).filter, /scale=3414:1920:.*crop=1080:1920:1167:0\[v0\]/);
    assert.doesNotMatch(build(edit([mc({ fit: "fit" })], [], { w: 1920, h: 1080, fps: 30 })).filter.split(";")[0], /,pad=|,crop=/);
    const odd = { [A]: V(A, 1921, 1081) };
    assert.match(build(edit([mc({ fit: "fit" })], [], { w: 1920, h: 1080, fps: 30 }), odd).filter.split(";")[0], /crop=1920:1080:0:0,scale=1920:1080/);
});

test("HDR, square-pixel, mono, photo orientation and GIF sources take their special steps", () => {
    const E = "EEEEEEEEEEEEEEEE", F = "FFFFFFFFFFFFFFFF";
    const t = edit([mc({ item: A }), mc({ item: B }), mc({ item: C })], [oc({ item: E, at: 1, out: 1 }), oc({ item: F, at: 3, out: 1 })]);
    const extra = {
        [E]: V(E, 500, 500, { kind: "gif", contentType: "image/gif", duration: null, hasAudio: false, channels: null }),
        [F]: V(F, 3024, 4032, { kind: "photo", contentType: "image/jpeg", duration: null, hasAudio: false, channels: null, orientation: 6 }),
    };
    const c = build(t, extra);
    const f = c.filter;
    assert.match(f, /\[2:v:0\]zscale=tin=arib-std-b67:pin=bt2020:min=bt2020nc:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,trim=/);
    assert.match(f, /\[1:a:0\].*pan=stereo\|c0=c0\|c1=c0,aresample=48000/);
    assert.doesNotMatch(f.split(";").find((x) => x.startsWith("[0:a:0]")) ?? "", /pan=/);
    assert.match(f, /\[3:v:0\]loop=loop=-1:size=32767,trim=duration=1,setpts=PTS-STARTPTS,fps=30/);
    assert.match(f, /\[4:v:0\]transpose=1,fps=30/);
    assert.ok(c.inputArgs.join(" ").includes("-noautorotate -loop 1 -framerate 30 -t 2 -i /in/F"));
    // square pixels first, when the source needs it
    const sq = { [A]: V(A, 720, 540, { squareFrom: { w: 720, h: 480 } }) };
    assert.match(build(edit([mc()]), sq).filter, /^\[0:v:0\]scale=720:540:flags=bicubic,setsar=1,trim=/);
});

test("overlays: shift, opacity, placement, audio delay and the mix", () => {
    const t = edit([mc({ out: 10 })], [oc({ item: B, at: 2.5, in: 1, out: 3, opacity: 0.5, muted: false, volume: 0.8, frame: { x: 0.1, y: 0.2, w: 0.3 } })]);
    const c = build(t);
    const parts = c.filter.split(";");
    const ov = parts.find((x) => x.endsWith("[ov0]"));
    assert.equal(ov, "[1:v:0]trim=end=3,setpts=PTS-1/TB,fps=30:round=up:start_time=0,tpad=stop_mode=clone:stop_duration=3,trim=end_frame=60," +
        "scale=324:576:flags=bicubic:out_color_matrix=bt709:out_range=tv,format=yuva420p,colorchannelmixer=aa=0.5,setpts=PTS-STARTPTS+75/(30*TB)[ov0]");
    assert.ok(parts.includes("[vm][ov0]overlay=108:384:eof_action=pass:format=auto[vo0]"));
    assert.ok(parts.includes("[1:a:0]atrim=start=1:end=3,asetpts=PTS-STARTPTS,volume=0.8,pan=stereo|c0=c0|c1=c0,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo," +
        "atrim=end_sample=96000,asetpts=PTS-STARTPTS,adelay=120000S:all=1,apad,atrim=end_sample=480000[oa0]"));
    assert.ok(parts.includes("[am][oa0]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]"));
    assert.equal(c.videoLabel, "[vo0]");
    assert.equal(c.audioLabel, "[aout]");
    // muted overlay (or one without sound): no audio chain, no amix
    const m = build(edit([mc({ out: 10 })], [oc({ item: B, muted: true })]));
    assert.doesNotMatch(m.filter, /amix|oa0/);
    assert.equal(m.audioLabel, "[am]");
    // opacity 1: no colorchannelmixer. Two overlays chain in order
    const two = build(edit([mc({ out: 10 })], [oc({ at: 1, out: 1 }), oc({ at: 4, out: 1 })]));
    assert.doesNotMatch(two.filter, /colorchannelmixer/);
    assert.ok(two.filter.indexOf("[vm][ov0]overlay") < two.filter.indexOf("[vo0][ov1]overlay"));
    assert.equal(two.videoLabel, "[vo1]");
});

test("a muted clip, or one whose source has no audio, is anullsrc of exactly its samples", () => {
    const D = "DDDDDDDDDDDDDDDD";
    const t = edit([mc({ muted: true, out: 2 }), mc({ item: D, out: 3 })]);
    const f = build(t, { [D]: V(D, 1280, 720, { hasAudio: false, channels: null }) }).filter;
    assert.ok(f.includes("anullsrc=r=48000:cl=stereo,atrim=end_sample=96000,asetpts=PTS-STARTPTS[a0]"));
    assert.ok(f.includes("anullsrc=r=48000:cl=stereo,atrim=end_sample=144000,asetpts=PTS-STARTPTS[a1]"));
});

test("errors: a missing source, a crop under 64 px of the real picture", () => {
    const t = edit([mc()]);
    const noSource = compile(t, {}, { output: "x" });
    assert.deepEqual([noSource.ok, noSource.code, noSource.path], [false, "error.edit.input_missing", "main[0].item"]);
    const tiny = edit([mc({ crop: { aspect: "free", x: 0, y: 0, w: 0.2, h: 1 } })]);
    const r = compile(tiny, { [A]: V(A, 300, 300) }, { output: "x" });
    assert.deepEqual([r.ok, r.code, r.path], [false, "error.edit.range", "main[0].crop"]);
    const ov = compile(edit([mc()], [oc()]), { [A]: V(A, 1920, 1080) }, { output: "x" });
    assert.deepEqual([ov.ok, ov.code, ov.path], [false, "error.edit.input_missing", "overlay[0].item"]);
});

test("the compiler is pure: the same input gives the same argv, and nothing is mutated", () => {
    const t = edit([mc({ in: 5, out: 12, speed: 1.35 })], [oc()]);
    const before = JSON.stringify(t);
    const s = { ...std() };
    const sb = JSON.stringify(s);
    assert.deepEqual(compile(t, s, { output: "a" }).args, compile(t, s, { output: "a" }).args);
    assert.equal(JSON.stringify(t), before);
    assert.equal(JSON.stringify(s), sb);
    assert.ok(compile(t, new Map(Object.entries(s)), { output: "a" }).ok, "a Map of sources works too");
});
