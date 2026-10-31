// Section 39: overlay layers (`track`) and webp sources (still and animated). The parse/order tests always run; the
// render tests use the real ffmpeg (skipped when it is missing).

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { compile } from "../compile.js";
import { probeSource, sniffKind } from "../probe.js";
import { EDIT_OVERLAY_TRACKS, canonicalJSON, checkSources, overlayDrawOrder, parseTimeline, sourceKind } from "../timeline.js";
import { drawFrame, encodePng, parseWebp, stillOfFrame } from "../webp.js";
import { FFMPEG, boxColors, ff, ffmpegAvailable, makeMedia } from "./media.js";

const have = ffmpegAvailable() && spawnSync("ffprobe", ["-version"]).status === 0;
const skip = have ? false : "ffmpeg/ffprobe not available";

const mc = (/** @type {any} */ o = {}) => ({ id: "m0", item: "AAAAAAAAAAAAAAAA", in: 0, out: 4, speed: 1, fit: "fill", volume: 1, muted: false, ...o });
const oc = (/** @type {any} */ o = {}) => ({ id: "o", item: "GGGGGGGGGGGGGGGG", at: 1, in: 0, out: 2, frame: { x: 0.25, y: 0.25, w: 0.5 }, opacity: 1, volume: 1, muted: true, ...o });
const tl = (/** @type {any[]} */ overlay) => ({ version: 1, canvas: { w: 720, h: 720, fps: 30 }, main: [mc()], overlay: overlay.map((o, i) => ({ ...o, id: `o${i}` })) });

// ---- the timeline ------------------------------------------------------------------------------------------------

test("track: absent and 0 are the same timeline, byte for byte; 1..7 is kept", () => {
    const a = parseTimeline(tl([oc()]));
    const b = parseTimeline(tl([oc({ track: 0 })]));
    assert.ok(a.ok && b.ok);
    assert.equal(canonicalJSON(a.timeline), canonicalJSON(b.timeline));
    assert.ok(!canonicalJSON(a.timeline).includes("track"));
    const c = parseTimeline(tl([oc({ track: 7 })]));
    assert.ok(c.ok);
    assert.match(canonicalJSON(c.timeline), /"opacity":1,"out":2,"track":7,"volume":1/);
    assert.equal(EDIT_OVERLAY_TRACKS, 8);
});

test("track: a non-integer is bad_request, out of 0..7 is range", () => {
    assert.deepEqual(parseTimeline(tl([oc({ track: 1.5 })])), { ok: false, code: "error.edit.bad_request", path: "overlay[0].track" });
    assert.deepEqual(parseTimeline(tl([oc({ track: "1" })])), { ok: false, code: "error.edit.bad_request", path: "overlay[0].track" });
    assert.deepEqual(parseTimeline(tl([oc({ track: 8 })])), { ok: false, code: "error.edit.range", path: "overlay[0].track" });
    assert.deepEqual(parseTimeline(tl([oc({ track: -1 })])), { ok: false, code: "error.edit.range", path: "overlay[0].track" });
});

test("overlap: refused on one layer, allowed across layers; still sorted by at", () => {
    assert.deepEqual(parseTimeline(tl([oc({ at: 1 }), oc({ at: 2 })])), { ok: false, code: "error.edit.overlay_overlap", path: "overlay[1]" });
    assert.ok(parseTimeline(tl([oc({ at: 1 }), oc({ at: 2, track: 1 })])).ok);
    assert.ok(parseTimeline(tl([oc({ at: 1, track: 2 }), oc({ at: 1, track: 1 }), oc({ at: 1.5 })])).ok);
    // a third on layer 1 that meets the second's end: fine; one inside it: refused
    assert.ok(parseTimeline(tl([oc({ at: 0, out: 1, track: 1 }), oc({ at: 1, out: 1, track: 1 })])).ok);
    assert.deepEqual(parseTimeline(tl([oc({ at: 0, track: 1 }), oc({ at: 0.5 }), oc({ at: 1, track: 1 })])), { ok: false, code: "error.edit.overlay_overlap", path: "overlay[2]" });
    assert.deepEqual(parseTimeline(tl([oc({ at: 2, track: 1 }), oc({ at: 1, track: 2 })])), { ok: false, code: "error.edit.overlay_overlap", path: "overlay[1]" });
});

test("drawing order: bottom layer first, then by at", () => {
    const p = parseTimeline(tl([oc({ at: 0, out: 1, track: 2 }), oc({ at: 0.5, out: 1 }), oc({ at: 1, out: 1, track: 1 }), oc({ at: 2, out: 1 })]));
    assert.ok(p.ok);
    assert.deepEqual(overlayDrawOrder(p.timeline), [1, 3, 2, 0]);
});

test("webp is an editor source (a picture: in 0, out = how long it stays up)", () => {
    assert.equal(sourceKind("image/webp"), "photo");
    const p = parseTimeline(tl([oc({ item: "WWWWWWWWWWWWWWWW", out: 3 })]));
    assert.ok(p.ok);
    const rows = [
        { id: "AAAAAAAAAAAAAAAA", content_type: "video/mp4", width: 320, height: 180, duration: 10, bytes: 1 },
        { id: "WWWWWWWWWWWWWWWW", content_type: "image/webp", width: 64, height: 64, duration: null, bytes: 1 },
    ];
    assert.ok(checkSources(p.timeline, rows).ok);
    assert.deepEqual(checkSources(parseTimeline(tl([oc({ item: "WWWWWWWWWWWWWWWW", in: 1, out: 3 })])).timeline, rows), { ok: false, code: "error.edit.range", path: "overlay[0].in" });
    assert.equal(sniffKind(Buffer.from("RIFF\x10\x00\x00\x00WEBPVP8L", "latin1")), "webp");
});

test("webp frames: blend over and replace, a lossy frame with alpha gets a VP8X header", () => {
    const c = new Uint8Array(2 * 1 * 4);
    c.set([0, 0, 255, 255, 0, 0, 255, 255]);
    drawFrame(c, 2, /** @type {any} */ ({ x: 0, y: 0, w: 2, h: 1, blend: true }), new Uint8Array([255, 0, 0, 128, 255, 0, 0, 0]));
    assert.deepEqual([...c], [128, 0, 127, 255, 0, 0, 255, 255]);
    drawFrame(c, 2, /** @type {any} */ ({ x: 1, y: 0, w: 1, h: 1, blend: false }), new Uint8Array([9, 9, 9, 0]));
    assert.deepEqual([...c.subarray(4)], [9, 9, 9, 0]);
    const still = stillOfFrame(/** @type {any} */ ({ w: 3, h: 2, chunks: Buffer.from("ALPH\x00\x00\x00\x00VP8 \x00\x00\x00\x00", "latin1") }));
    assert.equal(still.toString("latin1", 12, 16), "VP8X");
    assert.equal(still.readUInt32LE(4), still.length - 8);
    const png = encodePng(1, 1, new Uint8Array([1, 2, 3, 4]));
    assert.equal(png.toString("latin1", 1, 4), "PNG");
});

// ---- real renders ------------------------------------------------------------------------------------------------

const ID = { idx: "AAAAAAAAAAAAAAAA", gif: "GGGGGGGGGGGGGGGG", png: "HHHHHHHHHHHHHHHH", anim: "WWWWWWWWWWWWWWWW", lossy: "XXXXXXXXXXXXXXXX", still: "YYYYYYYYYYYYYYYY" };
/** @type {Record<string, any>} */
const src = {};
let work = "";

before(async () => {
    if (!have) return;
    work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-layers-"));
    const media = makeMedia(path.join(work, "media"));
    const p = (/** @type {string} */ n) => path.join(work, n);
    const cycle = "color=c=black:s=64x64:r=10:d=0.4,format=rgb24,geq=r='255*(eq(mod(N,4),0)+eq(mod(N,4),3))':g='255*(eq(mod(N,4),1)+eq(mod(N,4),3))':b='255*(eq(mod(N,4),2)+eq(mod(N,4),3))',format=rgba";
    ff(["-f", "lavfi", "-i", cycle, "-c:v", "libwebp_anim", "-lossless", "1", "-loop", "0", p("anim.webp")]);
    // lossy with alpha (ALPH + VP8 in every frame): red at 50 % alpha, then blue at 50 %
    ff(["-f", "lavfi", "-i", "color=c=red@0.5:s=64x64:r=5:d=0.4,format=rgba,geq=r='255*lt(N,1)':g=0:b='255*gte(N,1)':a=128", "-c:v", "libwebp_anim", "-quality", "90", "-loop", "0", p("lossy.webp")]);
    ff(["-f", "lavfi", "-i", "color=c=red@0.5:s=100x100,format=rgba", "-frames:v", "1", "-c:v", "libwebp", "-lossless", "1", p("still.webp")]);
    const list = [["idx", media.files.idx, "video"], ["gif", media.files.gif, "gif"], ["png", media.files.png, "photo"], ["anim", p("anim.webp"), "photo"], ["lossy", p("lossy.webp"), "photo"], ["still", p("still.webp"), "photo"]];
    for (const [k, file, kind] of list) {
        const r = await probeSource({ ffmpeg: FFMPEG, file, kind, item: /** @type {any} */ (ID)[k], bytes: 1000 });
        assert.ok(r.ok, `probe ${k}`);
        src[/** @type {any} */ (ID)[k]] = r.source;
    }
});
after(() => {
    if (work) rmSync(work, { recursive: true, force: true });
});

const rowsOf = () => Object.values(src).map((s) => ({ id: s.item, content_type: s.contentType, width: s.width, height: s.height, duration: s.duration, bytes: s.bytes, deleted: false }));

/** @param {any[]} overlay @param {string} name */
function render(overlay, name) {
    const p = parseTimeline(tl(overlay));
    assert.ok(p.ok, JSON.stringify(p));
    const ck = checkSources(p.timeline, rowsOf());
    assert.ok(ck.ok, JSON.stringify(ck));
    const out = path.join(work, `${name}.mp4`);
    const c = compile(ck.timeline, src, { output: out });
    assert.ok(c.ok, JSON.stringify(c));
    const r = spawnSync(FFMPEG, c.args, { encoding: "utf8", maxBuffer: 1 << 28 });
    assert.equal(r.status, 0, `${r.stderr}\n${c.args.join(" ")}`);
    return { out, c };
}

/** @param {number[]} c */
const hue = (c) => {
    const [r, g, b] = c;
    if (r > 200 && g > 200 && b > 200) return "white";
    if (r > 150 && g < 90 && b < 90) return "red";
    if (g > 150 && r < 90 && b < 90) return "green";
    if (b > 150 && r < 90 && g < 90) return "blue";
    return "other";
};

test("probe: an animated webp loops like a gif, a still webp is a photo", { skip }, () => {
    assert.equal(src[ID.anim].kind, "gif");
    assert.equal(src[ID.anim].contentType, "image/webp");
    assert.match(src[ID.anim].frames, /anim\.png$/);
    assert.deepEqual([src[ID.anim].width, src[ID.anim].height], [64, 64]);
    assert.equal(src[ID.still].kind, "photo");
    assert.equal(src[ID.still].contentType, "image/webp");
    assert.ok(readFileSync(src[ID.anim].frames).includes(Buffer.from("acTL")));
});

test("an animated webp overlay loops on its own timing, like a gif", { skip }, () => {
    const { out } = render([oc({ item: ID.anim, at: 1, out: 2 })], "anim");
    const seq = boxColors(out, { x: 350, y: 350, w: 10, h: 10 }).map(hue);
    const cyc = ["red", "green", "blue", "white"];
    for (let k = 0; k < 60; k++) assert.equal(seq[30 + k], cyc[Math.floor(k / 3) % 4], `overlay frame ${k}`);
    assert.notEqual(seq[10], "red");
});

test("a lossy webp with alpha decodes with its alpha; a still webp keeps its alpha", { skip }, () => {
    const lossy = boxColors(render([oc({ item: ID.lossy, at: 1, out: 2 })], "lossy").out, { x: 350, y: 350, w: 10, h: 10 });
    const base = lossy[5];
    assert.ok(lossy[32][0] - base[0] > 60 && lossy[32][0] < 245, `half red: ${lossy[32]}`);
    assert.ok(lossy[38][2] - base[2] > 60 && lossy[38][2] < 245, `half blue: ${lossy[38]}`);
    const still = boxColors(render([oc({ item: ID.still, at: 1, out: 1 })], "still").out, { x: 350, y: 350, w: 10, h: 10 });
    const red = still[40][0] - still[5][0] - (still[40][1] - still[5][1]);
    assert.ok(red > 80 && red < 140, `half-transparent red: ${red}`);
});

test("layers: two overlays at once, the higher layer drawn on top", { skip }, () => {
    // the gif (opaque, cycling) on layer 0 under the half-transparent red png on layer 1, both in the same place
    const { out, c } = render([oc({ item: ID.gif, at: 1, out: 2 }), oc({ item: ID.png, at: 1, out: 2, track: 1 })], "stack");
    const seq = boxColors(out, { x: 350, y: 350, w: 10, h: 10 });
    // gif green under 50 % red: both channels show
    const g = seq[33];
    assert.ok(g[0] > 90 && g[1] > 90 && g[2] < 60, `red over green: ${g}`);
    // swap the layers: the opaque gif covers the png entirely
    const top = boxColors(render([oc({ item: ID.png, at: 1, out: 2 }), oc({ item: ID.gif, at: 1, out: 2, track: 1 })], "stack2").out, { x: 350, y: 350, w: 10, h: 10 });
    assert.equal(hue(top[33]), "green");
    assert.equal(c.filter.match(/overlay=/g)?.length, 2);
});

test("layers: two video overlays at once, both sounds mixed", { skip }, () => {
    const v = (/** @type {any} */ o) => oc({ item: ID.idx, in: 0, out: 1, muted: false, frame: { x: 0, y: 0, w: 0.3 }, ...o });
    const { c } = render([v({ at: 1 }), v({ at: 1.5, track: 3, frame: { x: 0.6, y: 0.6, w: 0.3 } })], "twovideos");
    assert.match(c.filter, /amix=inputs=3:/);
});
