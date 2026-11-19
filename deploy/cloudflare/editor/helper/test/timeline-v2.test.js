// Timeline v2 (APP-API-CONTRACT.md section 69): parse, canonical JSON, v1↔v2 conversion, and the shared
// fixtures in helper/test/fixtures/timeline-v2. The Swift app loads the same files for its parity tests.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { compile } from "../compile.js";
import { probeSource } from "../probe.js";
import {
    EDIT_TIMELINE_VERSION,
    canonicalJSON,
    checkSources,
    clipCount,
    clipDrawOrder,
    coverItem,
    parseTimeline,
    timelineV1ToV2,
    timelineV2ToV1,
    timing,
} from "../timeline.js";
import { FFMPEG, boxColors, decodeAudio, ff, ffmpegAvailable, rms } from "./media.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixDir = path.join(here, "fixtures", "timeline-v2");
const cases = readdirSync(fixDir)
    .filter((n) => n.endsWith(".json") && n !== "index.json")
    .sort();

test("the fixture index names every case, at the path the Swift app reads", () => {
    const index = JSON.parse(readFileSync(path.join(fixDir, "index.json"), "utf8"));
    assert.equal(index.path, "deploy/cloudflare/editor/helper/test/fixtures/timeline-v2");
    assert.deepEqual([...index.cases].sort(), cases.map((n) => n.replace(/\.json$/, "")).sort());
    assert.equal(EDIT_TIMELINE_VERSION, 2);
});

test("every shared fixture: parse, canonical JSON, conversion, frames, clip count and cover", () => {
    assert.ok(cases.length >= 8);
    for (const name of cases) {
        const fx = JSON.parse(readFileSync(path.join(fixDir, name), "utf8"));
        const parsed = parseTimeline(fx.input);
        if (fx.parse.ok) {
            assert.equal(parsed.ok, true, name);
            assert.equal(canonicalJSON(parsed.timeline), fx.parse.canonical, name);
            const again = parseTimeline(fx.parse.canonical);
            assert.equal(again.ok && canonicalJSON(again.timeline), fx.parse.canonical, `${name} stable`);
            assert.equal(clipCount(parsed.timeline), fx.clip_count, name);
            assert.equal(coverItem(parsed.timeline), fx.cover_item, name);
            assert.equal(timing(parsed.timeline).frames, fx.timing_frames, name);
        } else {
            assert.equal(parsed.ok, false, name);
            assert.equal(parsed.code, fx.parse.code, name);
            assert.equal(parsed.path, fx.parse.path, name);
        }
        if (fx.to_v2) {
            assert.equal(parsed.ok, true, name);
            const v2 = timelineV1ToV2(parsed.timeline);
            assert.equal(v2.ok, fx.to_v2.ok, name);
            if (fx.to_v2.ok) assert.equal(canonicalJSON(v2.timeline), fx.to_v2.canonical, name);
            else {
                assert.equal(v2.code, fx.to_v2.code, name);
                assert.equal(v2.path, fx.to_v2.path, name);
            }
        }
        if (fx.to_v1) {
            const source = fx.to_v2?.ok ? timelineV1ToV2(parsed.timeline).timeline : parsed.timeline;
            const v1 = timelineV2ToV1(source, fx.kinds ?? null);
            assert.equal(v1.ok, fx.to_v1.ok, `${name} ${JSON.stringify(v1)}`);
            if (fx.to_v1.ok) {
                assert.equal(canonicalJSON(v1.timeline), fx.to_v1.canonical, name);
                if (fx.input.version === 1) assert.equal(fx.to_v1.canonical, fx.parse.canonical, `${name} round trip`);
            } else {
                assert.equal(v1.code, fx.to_v1.code, name);
                assert.equal(v1.path, fx.to_v1.path, name);
            }
        }
    }
});

test("v2 validation: empty, unknown key, picture rules, a gap's length, lane order", () => {
    const canvas = { w: 1080, h: 1920, fps: 30 };
    const A = "AAAAAAAAAAAAAAAA";
    const clip = (over = {}) => ({ id: "a", item: A, lane: 0, at: 0, in: 0, out: 1, ...over });
    const bad = (input, code, path) => {
        const r = parseTimeline(input);
        assert.equal(r.ok, false, JSON.stringify(r));
        assert.deepEqual([r.code, r.path], [code, path]);
    };
    bad({ version: 2, canvas, clips: [] }, "error.edit.empty", "clips");
    bad({ version: 2, canvas, clips: [clip({ track: 1 })] }, "error.edit.bad_request", "clips[0].track");
    bad({ version: 2, canvas, clips: [clip(), clip({ id: "a" })] }, "error.edit.bad_request", "clips[1].id");
    bad({ version: 2, canvas, clips: [clip({ speed: 9 })] }, "error.edit.range", "clips[0].speed");
    bad({ version: 2, canvas, clips: [clip({ out: 0.05, speed: 1 })] }, "error.edit.range", "clips[0].out");
    const held = parseTimeline({ version: 2, canvas, clips: [clip({ speed: 1, fit: "fill", opacity: 1, volume: 1, muted: false })] });
    assert.equal(held.ok, true);
    assert.equal(canonicalJSON(held.timeline).includes("speed"), false);
    assert.equal(canonicalJSON(held.timeline).includes("muted"), false);

    const rows = (kind, over = {}) => [{ id: A, content_type: kind, width: 1920, height: 1080, duration: 10, bytes: 100, deleted: false, ...over }];
    const photo = parseTimeline({ version: 2, canvas, clips: [clip({ in: 0, out: 2 })] });
    assert.equal(checkSources(photo.timeline, rows("image/png", { duration: null })).ok, true);
    const gifIn = parseTimeline({ version: 2, canvas, clips: [clip({ in: 1, out: 2 })] });
    const gif = checkSources(gifIn.timeline, rows("image/gif", { duration: null }));
    assert.deepEqual([gif.ok, gif.code, gif.path], [false, "error.edit.range", "clips[0].in"]);
    // a picture is not rejected as not_video
    assert.notEqual(checkSources(photo.timeline, rows("image/jpeg", { duration: null })).code, "error.edit.not_video");

    const gap = parseTimeline({
        version: 2,
        canvas,
        clips: [clip({ id: "a", at: 0, out: 1 }), clip({ id: "b", at: 3, out: 1 })],
    });
    assert.equal(timing(gap.timeline).frames, 120);
    assert.deepEqual(clipDrawOrder(gap.timeline), [0, 1]);
    const stacked = parseTimeline({
        version: 2,
        canvas,
        clips: [clip({ id: "top", lane: 3, at: 0 }), clip({ id: "bot", lane: 0, at: 1, out: 1 })],
    });
    assert.deepEqual(clipDrawOrder(stacked.timeline), [1, 0]);
});

const A = "AAAAAAAAAAAAAAAA";
const B = "BBBBBBBBBBBBBBBB";
const srcOf = (item, over) => ({
    item,
    path: `/in/${item.slice(0, 1)}`,
    kind: "video",
    contentType: "video/mp4",
    bytes: 1000,
    width: 1920,
    height: 1080,
    squareFrom: null,
    duration: 100,
    hasAudio: true,
    channels: 2,
    hdr: false,
    transfer: null,
    orientation: 1,
    ...over,
});

test("v2 compiles to a black base and one layer per visible clip; a v1 timeline does not", () => {
    const beach = parseTimeline(JSON.parse(readFileSync(path.join(here, "fixtures", "timeline-beach.json"), "utf8")));
    const sources = {
        Ab3dEf6hIj9kLm2n: srcOf("Ab3dEf6hIj9kLm2n"),
        Qr5tUv8xYz1bCd4f: srcOf("Qr5tUv8xYz1bCd4f"),
        Gh7jKl0nOp3rSt6v: srcOf("Gh7jKl0nOp3rSt6v", { kind: "gif", contentType: "image/gif", hasAudio: false, channels: null, duration: null }),
    };
    const v1 = compile(beach.timeline, sources, { output: "/o.mp4" });
    assert.equal(v1.ok, true);
    assert.equal(v1.filter.includes("color=c=black"), false);
    assert.equal(v1.filter.includes("concat="), true);
    const v2 = timelineV1ToV2(beach.timeline);
    const c = compile(v2.timeline, sources, { output: "/o.mp4" });
    assert.equal(c.ok, true, JSON.stringify(c));
    assert.match(c.filter, /^color=c=black:s=1080x1920:r=30:d=/);
    assert.equal(c.filter.includes("concat="), false);
    assert.equal(c.timing.frames, v1.timing.frames);
    // lane 0 (two clips) under lane 1
    assert.ok(c.filter.indexOf("[vo0]") < c.filter.indexOf("[ov2]") || c.filter.includes("[base][ov0]"));
    assert.equal(c.filter.includes("hidden"), false);
});

test("a hidden clip is not an input, speed and opacity are in the graph, draw order is bottom lane first", () => {
    const t = parseTimeline({
        version: 2,
        canvas: { w: 1080, h: 1920, fps: 30 },
        clips: [
            { id: "top", item: B, lane: 2, at: 0, in: 0, out: 1, frame: { x: 0.1, y: 0.1, w: 0.3 }, opacity: 0.5 },
            { id: "hide", item: A, lane: 1, at: 0, in: 0, out: 1, hidden: true },
            { id: "bot", item: A, lane: 0, at: 1, in: 0, out: 2, speed: 2, volume: 0.5 },
        ],
    });
    assert.equal(t.ok, true);
    const c = compile(t.timeline, { [A]: srcOf(A), [B]: srcOf(B, { kind: "photo", contentType: "image/png", hasAudio: false, channels: null, duration: null, width: 800, height: 600 }) }, { output: "/o.mp4" });
    assert.equal(c.ok, true, JSON.stringify(c));
    assert.equal(c.inputArgs.filter((x) => x === "-i").length, 2);
    assert.match(c.filter, /setpts=\(PTS-0\/TB\)\/2/);
    assert.match(c.filter, /colorchannelmixer=aa=0\.5/);
    assert.ok(c.filter.indexOf("[base][ov2]") < c.filter.indexOf("[ov0]"), c.filter);
    assert.match(c.filter, /amix=inputs=2:/);
    assert.match(c.filter, /adelay=48000S/);
});

const have = ffmpegAvailable();

test("a rendered v2 edit: the gap is black, a picture on lane 0 holds, a higher lane sits on top, sound waits for the clip", { skip: have ? false : "ffmpeg not available" }, async () => {
    const work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-v2-"));
    try {
        const video = path.join(work, "red.mp4");
        const png = path.join(work, "green.png");
        ff(["-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", video]);
        ff(["-f", "lavfi", "-i", "color=c=lime:s=64x64", "-frames:v", "1", png]);
        const rv = await probeSource({ ffmpeg: FFMPEG, file: video, kind: "video", item: A, bytes: 1000 });
        const rp = await probeSource({ ffmpeg: FFMPEG, file: png, kind: "photo", item: B, bytes: 1000 });
        assert.equal(rv.ok && rp.ok, true, JSON.stringify([rv, rp]));
        const canvas = { w: 1280, h: 720, fps: 30 };
        // Lane 0: a still for half a second, then a one-second gap, then the red video. Lane 1: the still again, in the corner, over the video.
        const gap = parseTimeline({
            version: 2,
            canvas,
            clips: [
                { id: "pic", item: B, lane: 0, at: 0, in: 0, out: 0.5 },
                { id: "vid", item: A, lane: 0, at: 1, in: 0, out: 1, muted: false },
                { id: "sticker", item: B, lane: 1, at: 1, in: 0, out: 1, frame: { x: 0, y: 0, w: 0.25 } },
            ],
        });
        assert.equal(gap.ok, true, JSON.stringify(gap));
        const rows = [
            { id: B, content_type: "image/png", width: rp.source.width, height: rp.source.height, duration: null, bytes: 1000, deleted: false },
            { id: A, content_type: "video/mp4", width: rv.source.width, height: rv.source.height, duration: rv.source.duration, bytes: 1000, deleted: false },
        ];
        const checked = checkSources(gap.timeline, rows);
        assert.equal(checked.ok, true, JSON.stringify(checked));
        const out = path.join(work, "out.mp4");
        const c = compile(checked.timeline, { [A]: rv.source, [B]: rp.source }, { output: out, progress: false });
        assert.equal(c.ok, true, JSON.stringify(c));
        assert.equal(c.timing.frames, 60);
        const run = spawnSync(FFMPEG, c.args, { encoding: "utf8" });
        assert.equal(run.status, 0, run.stderr);
        const center = boxColors(out, { x: 600, y: 340, w: 20, h: 20 });
        const corner = boxColors(out, { x: 8, y: 8, w: 20, h: 20 });
        assert.equal(center.length, 60);
        const green = (rgb) => rgb[1] > 150 && rgb[0] < 80;
        const red = (rgb) => rgb[0] > 150 && rgb[1] < 80;
        const black = (rgb) => rgb[0] < 20 && rgb[1] < 20 && rgb[2] < 20;
        assert.ok(green(center[0]), `frame 0 center ${center[0]}`);
        assert.ok(black(center[20]), `gap center ${center[20]}`);
        assert.ok(red(center[45]), `video center ${center[45]}`);
        assert.ok(green(corner[45]), `sticker over the video ${corner[45]}`);
        assert.ok(red(center[45]) && green(corner[45]));
        const pcm = decodeAudio(out);
        assert.ok(rms(pcm, 0, 16000) < 0.01, "the gap is silent");
        assert.ok(rms(pcm, 48000, 64000) > 0.02, "the clip's sound starts with the picture");
    } finally {
        rmSync(work, { recursive: true, force: true });
    }
});
