// Turned and off-canvas frames on timeline v2 clips (APP-API-CONTRACT.md section 69.7): parse, the v1 refusal, the
// placement maths, the graph, and a real render where a green-screen clip on top shows a turned clip through its hole.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { compile } from "../compile.js";
import { probeSource } from "../probe.js";
import { canonicalJSON, checkSources, laneBoxPlacement, parseTimeline, timelineV2ToV1 } from "../timeline.js";
import { FFMPEG, boxColors, ff, ffmpegAvailable } from "./media.js";

const A = "AAAAAAAAAAAAAAAA";
const B = "BBBBBBBBBBBBBBBB";
const canvas = { w: 1280, h: 720, fps: 30 };
const v2 = (clips) => parseTimeline({ version: 2, canvas, clips });
const base = { id: "bot", item: A, lane: 0, at: 0, in: 0, out: 2 };
const top = (frame) => ({ id: "top", item: B, lane: 1, at: 0, in: 0, out: 2, frame });

test("r is stored rounded to 0.1 and left out when 0, so older frames keep their bytes", () => {
    const a = v2([base, top({ x: 0.1, y: 0.1, w: 0.3, r: 12.345 })]);
    assert.equal(a.ok, true, JSON.stringify(a));
    assert.deepEqual(a.timeline.clips[1].frame, { r: 12.3, w: 0.3, x: 0.1, y: 0.1 });
    const b = v2([base, top({ x: 0.1, y: 0.1, w: 0.3, r: 0 })]);
    assert.equal(b.ok, true);
    assert.equal(canonicalJSON(b.timeline).includes('"r"'), false);
    const neg = v2([base, top({ x: 0.1, y: 0.1, w: 0.3, r: -0.04 })]);
    assert.equal(neg.ok, true);
    assert.equal("r" in neg.timeline.clips[1].frame, false, "-0.04 rounds to 0 and is left out");
    const left = v2([base, top({ x: 0.1, y: 0.1, w: 0.3, r: -45.25 })]);
    assert.equal(left.timeline.clips[1].frame.r, -45.3, "half away from zero, as Swift rounds");
});

test("a frame may hang past the edges and be wider than the canvas, but not leave it", () => {
    const off = v2([base, top({ x: -0.25, y: -0.4, w: 1.6 })]);
    assert.equal(off.ok, true, JSON.stringify(off));
    assert.deepEqual(off.timeline.clips[1].frame, { w: 1.6, x: -0.25, y: -0.4 });
    for (const [frame, pathEnd] of [
        [{ x: 1, y: 0, w: 0.3 }, "x"],
        [{ x: -0.3, y: 0, w: 0.3 }, "x"],
        [{ x: 0, y: 1, w: 0.3 }, "y"],
        [{ x: 0, y: 0, w: 4.5 }, "w"],
        [{ x: 0, y: 0, w: 0.01 }, "w"],
        [{ x: 0, y: 0, w: 0.3, r: 181 }, "r"],
    ]) {
        const r = v2([base, top(frame)]);
        assert.equal(r.ok, false, JSON.stringify(frame));
        assert.equal(r.code, "error.edit.range");
        assert.equal(r.path, `clips[1].frame.${pathEnd}`);
    }
    const typo = v2([base, top({ x: 0, y: 0, w: 0.3, rot: 4 })]);
    assert.equal(typo.ok, false);
    assert.equal(typo.code, "error.edit.bad_request");
});

test("a turned or off-canvas frame never converts to v1, an ordinary one still does", () => {
    const fine = v2([base, top({ x: 0.1, y: 0.1, w: 0.3 })]);
    assert.equal(timelineV2ToV1(fine.timeline).ok, true);
    for (const frame of [{ x: 0.1, y: 0.1, w: 0.3, r: 4 }, { x: -0.1, y: 0.1, w: 0.3 }, { x: 0.8, y: 0.1, w: 0.3 }, { x: 0, y: 0, w: 1.2 }]) {
        const t = v2([base, top(frame)]);
        assert.equal(t.ok, true);
        const r = timelineV2ToV1(t.timeline);
        assert.equal(r.ok, false);
        assert.equal(r.code, "error.edit.needs_timeline_v2");
        assert.equal(r.path, "clips[1].frame");
    }
});

test("laneBoxPlacement: unclamped box, a turned box keeps its centre, nothing on the canvas is null", () => {
    const d = { w: 1920, h: 1080 };
    assert.deepEqual(laneBoxPlacement(d, { x: -0.25, y: -0.25, w: 0.5 }, canvas), { h: 360, r: 0, rot: null, w: 640, x: -320, y: -180 });
    const t = laneBoxPlacement(d, { x: 0.25, y: 0.25, w: 0.5, r: 90 }, canvas);
    assert.deepEqual(t.rot, { h: 640, w: 360, x: 460, y: 40 });
    assert.equal(t.rot.x + t.rot.w / 2, t.x + t.w / 2);
    assert.equal(t.rot.y + t.rot.h / 2, t.y + t.h / 2);
    const diag = laneBoxPlacement(d, { x: 0.25, y: 0.25, w: 0.5, r: 45 }, canvas);
    assert.equal(diag.rot.w % 2, 0);
    assert.ok(diag.rot.w >= Math.ceil((640 + 360) * Math.SQRT1_2));
    assert.equal(laneBoxPlacement(d, { x: 0.99, y: 0.99, w: 0.5, r: 0 }, canvas) !== null, true);
    assert.equal(laneBoxPlacement({ w: 100, h: 100 }, { x: 0, y: -0.9, w: 0.2 }, canvas), null, "1280 x 0.2 square at -648 px ends above the top");
});

const srcOf = (item, over) => ({ item, path: `/in/${item.slice(0, 1)}`, kind: "video", contentType: "video/mp4", bytes: 1000, width: 1920, height: 1080, duration: 10, hasAudio: true, channels: 2, squareFrom: null, hdr: false, transfer: null, orientation: 1, ...over });

test("the graph turns the clip after its key and places the turned box", () => {
    const t = v2([base, { ...top({ x: -0.1, y: 0.25, w: 0.5, r: 90 }), key: { color: "#00B140", similarity: 0.2, blend: 0.05, spill: 0.4 } }]);
    assert.equal(t.ok, true, JSON.stringify(t));
    const c = compile(t.timeline, { [A]: srcOf(A), [B]: srcOf(B) }, { output: "/o.mp4" });
    assert.equal(c.ok, true, JSON.stringify(c));
    assert.match(c.filter, /\[k1\]rotate=a=1\.570796327:ow=360:oh=640:c=black@0\[r1\]/);
    assert.match(c.filter, /\[r1\]overlay=12:40:/);
});

test("a framed clip with nothing on the canvas draws nothing but keeps its sound", () => {
    const t = v2([base, top({ x: 0.2, y: -0.9, w: 0.2 })]);
    assert.equal(t.ok, true);
    const c = compile(t.timeline, { [A]: srcOf(A), [B]: srcOf(B) }, { output: "/o.mp4" });
    assert.equal(c.ok, true, JSON.stringify(c));
    assert.equal(c.filter.includes("[ov1]"), false);
    assert.match(c.filter, /\[1:a:0\]/);
});

const have = ffmpegAvailable();

test("rendered: a green-screen clip on top shows a turned clip below through its hole", { skip: have ? false : "ffmpeg not available" }, async () => {
    const work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-turn-"));
    try {
        // B (top): white with a pure-green hole in the middle. A (bottom): red, framed small and turned 90 degrees.
        const holed = path.join(work, "holed.mp4");
        const red = path.join(work, "red.mp4");
        ff(["-f", "lavfi", "-i", "color=c=white:s=320x180:r=30:d=1", "-vf", "drawbox=x=110:y=40:w=100:h=100:color=0x00B140:t=fill", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-qp", "0", holed]);
        ff(["-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", red]);
        const rh = await probeSource({ ffmpeg: FFMPEG, file: holed, kind: "video", item: B, bytes: 1000 });
        const rr = await probeSource({ ffmpeg: FFMPEG, file: red, kind: "video", item: A, bytes: 1000 });
        assert.equal(rh.ok && rr.ok, true);
        const t = parseTimeline({
            version: 2,
            canvas,
            clips: [
                { id: "under", item: A, lane: 0, at: 0, in: 0, out: 1, frame: { x: 0.4, y: 0.3, w: 0.2, r: 90 } },
                { id: "green", item: B, lane: 1, at: 0, in: 0, out: 1, key: { color: "#00B140", similarity: 0.2, blend: 0.05, spill: 0.4 } },
            ],
        });
        assert.equal(t.ok, true, JSON.stringify(t));
        const rows = [A, B].map((id) => ({ id, content_type: "video/mp4", width: 320, height: 180, duration: 1, bytes: 1000, deleted: false }));
        const checked = checkSources(t.timeline, rows);
        assert.equal(checked.ok, true, JSON.stringify(checked));
        const out = path.join(work, "out.mp4");
        const c = compile(checked.timeline, { [A]: rr.source, [B]: rh.source }, { output: out, progress: false });
        assert.equal(c.ok, true, JSON.stringify(c));
        const run = spawnSync(FFMPEG, c.args, { encoding: "utf8" });
        assert.equal(run.status, 0, run.stderr);
        const isRed = (rgb) => rgb[0] > 150 && rgb[1] < 90 && rgb[2] < 90;
        // the despill step greys pure white a little; what matters is that the top clip, not the base or the red, is there
        const isWhite = (rgb) => rgb[0] > 120 && Math.abs(rgb[0] - rgb[1]) < 30 && Math.abs(rgb[0] - rgb[2]) < 30;
        const isBlack = (rgb) => rgb[0] < 40 && rgb[1] < 40 && rgb[2] < 40;
        // the red box is 256x144 at (512,216), turned: 144 wide x 256 tall centred at (640,360). The hole is 400x400 at (440,160).
        const centre = boxColors(out, { x: 630, y: 350, w: 20, h: 20 });
        const holeTop = boxColors(out, { x: 630, y: 240, w: 20, h: 10 }); // inside the turned red (y 232..488)
        const holeSide = boxColors(out, { x: 540, y: 350, w: 10, h: 10 }); // in the hole, left of the turned red (x 568..712)
        const frameEdge = boxColors(out, { x: 100, y: 100, w: 20, h: 20 });
        assert.ok(isRed(centre[5]), `centre ${centre[5]}`);
        assert.ok(isRed(holeTop[5]), `turned red reaches up ${holeTop[5]}`);
        assert.ok(isBlack(holeSide[5]), `hole beside the turned clip shows the black base ${holeSide[5]}`);
        assert.ok(isWhite(frameEdge[5]), `outside the hole is the top clip ${frameEdge[5]}`);
    } finally {
        rmSync(work, { recursive: true, force: true });
    }
});
