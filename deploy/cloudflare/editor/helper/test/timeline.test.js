import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as T from "../timeline.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fx = (/** @type {string} */ n) => readFileSync(path.join(here, "fixtures", n), "utf8");

const A = "AAAAAAAAAAAAAAAA", B = "BBBBBBBBBBBBBBBB", C = "CCCCCCCCCCCCCCCC";
const main = (/** @type {any} */ o = {}) => ({ id: "m1", item: A, in: 0, out: 4, speed: 1, fit: "fill", volume: 1, muted: false, ...o });
const over = (/** @type {any} */ o = {}) => ({ id: "o1", item: B, at: 1, in: 0, out: 2, frame: { x: 0.6, y: 0.05, w: 0.35 }, opacity: 1, volume: 1, muted: true, ...o });
const tl = (/** @type {any} */ o = {}) => ({ version: 1, canvas: { w: 1080, h: 1920, fps: 30 }, main: [main()], overlay: [], ...o });

/** @param {any} raw @param {string} code @param {string} path */
function refuses(raw, code, path) {
    const r = T.parseTimeline(raw);
    assert.equal(r.ok, false, `expected ${code} at ${path}`);
    assert.deepEqual([r.code, r.path], [code, path]);
}

test("exports are the ones 31.3 pins", () => {
    for (const n of ["EDIT_MAX_SECONDS", "EDIT_MAX_CLIPS", "EDIT_MAX_JSON_BYTES", "EDIT_MAX_PROJECTS", "EDIT_QUEUE_MAX", "EDIT_MAX_INPUT_BYTES", "EDIT_MAX_OUTPUT_BYTES",
        "EDIT_CANVASES", "EDIT_SOURCE_TYPES", "parseTimeline", "checkSources", "canonicalJSON", "timing", "mainPlacement", "overlayPlacement", "roundHalfUp", "evenNearest"]) {
        assert.ok(n in T, n);
    }
    assert.equal(T.EDIT_MAX_SECONDS, 600);
    assert.equal(T.EDIT_MAX_CLIPS, 50);
    assert.equal(T.EDIT_MAX_JSON_BYTES, 65536);
    assert.equal(T.EDIT_MAX_PROJECTS, 200);
    assert.equal(T.EDIT_QUEUE_MAX, 20);
    assert.equal(T.EDIT_MAX_INPUT_BYTES, 6 * 1024 ** 3);
    assert.equal(T.EDIT_MAX_OUTPUT_BYTES, 4 * 1024 ** 3);
    assert.deepEqual(T.EDIT_CANVASES, [[1080, 1920], [720, 1280], [1080, 1080], [720, 720], [1920, 1080], [1280, 720]]);
    assert.deepEqual(T.EDIT_SOURCE_TYPES, ["video/mp4", "video/quicktime", "video/x-m4v", "image/gif", "image/jpeg", "image/png"]);
});

test("timeline.js has no imports (the Worker bundles it, the image has no monorepo)", () => {
    const src = readFileSync(path.join(here, "..", "timeline.js"), "utf8");
    assert.equal(/^\s*import\s/m.test(src), false);
    assert.equal(/\bfrom\s+["']node:/.test(src), false);
    assert.equal(/\brequire\(/.test(src), false);
});

test("roundHalfUp and evenNearest", () => {
    assert.equal(T.roundHalfUp(10.5), 11);
    assert.equal(T.roundHalfUp(0.35 * 30), 11);
    assert.equal(T.roundHalfUp(10.49999), 10);
    assert.equal(T.roundHalfUp(10.4999999999999), 11, "inside the epsilon");
    assert.equal(T.roundHalfUp(0), 0);
    assert.equal(T.evenNearest(3), 4);
    assert.equal(T.evenNearest(2.99), 2);
    assert.equal(T.evenNearest(5), 6);
    assert.equal(T.evenNearest(1079.2), 1080);
});

test("the example of 31.2 parses and its canonical bytes are the fixture, and canonicalising twice changes nothing", () => {
    const bytes = fx("timeline-beach.json");
    const r = T.parseTimeline(bytes);
    assert.ok(r.ok, JSON.stringify(r));
    assert.equal(T.canonicalJSON(r.timeline), bytes);
    const again = T.parseTimeline(T.canonicalJSON(r.timeline));
    assert.ok(again.ok);
    assert.equal(T.canonicalJSON(again.timeline), bytes);
    assert.equal(bytes.endsWith("\n"), false);
});

test("canonical JSON: sorted keys, no whitespace, shortest numbers, crop omitted when absent", () => {
    const r = T.parseTimeline({ ...tl(), main: [main({ in: 2.0004, out: 9.5, speed: 1.52, volume: 0.499, crop: undefined })] });
    assert.ok(r.ok);
    const s = T.canonicalJSON(r.timeline);
    assert.equal(s, '{"canvas":{"fps":30,"h":1920,"w":1080},"main":[{"fit":"fill","id":"m1","in":2,"item":"AAAAAAAAAAAAAAAA","muted":false,"out":9.5,"speed":1.5,"volume":0.5}],"overlay":[],"version":1}');
    assert.equal(T.canonicalJSON({ b: [1, 2.5, 0.3164], a: { z: 1, y: null } }), '{"a":{"y":null,"z":1},"b":[1,2.5,0.3164]}');
});

test("rounding: 0.001 times, 0.0001 fractions, 0.01 gains, speed to a multiple of 0.05", () => {
    const r = T.parseTimeline({
        ...tl(),
        main: [main({ in: 1.00049, out: 6.0005, speed: 0.97, volume: 0.994, crop: { aspect: "free", x: 0.12344, y: 0.00005, w: 0.5, h: 0.33335 } })],
        overlay: [over({ at: 0.9996, in: 0.0004, out: 2.0004, frame: { x: 0.12345, y: 0.6, w: 0.30004 }, opacity: 0.555, volume: 0.005 })],
    });
    assert.ok(r.ok, JSON.stringify(r));
    const c = r.timeline.main[0];
    assert.deepEqual([c.in, c.out, c.speed, c.volume], [1, 6.001, 0.95, 0.99]);
    assert.deepEqual(c.crop, { aspect: "free", h: 0.3334, w: 0.5, x: 0.1234, y: 0.0001 });
    const o = r.timeline.overlay[0];
    assert.deepEqual([o.at, o.in, o.out, o.opacity, o.volume], [1, 0, 2, 0.56, 0.01]);
    assert.deepEqual(o.frame, { w: 0.3, x: 0.1235, y: 0.6 });
    // speed edges
    assert.equal(T.parseTimeline(tl({ main: [main({ speed: 0.25 })] })).timeline.main[0].speed, 0.25);
    assert.equal(T.parseTimeline(tl({ main: [main({ speed: 4 })] })).timeline.main[0].speed, 4);
    assert.equal(T.parseTimeline(tl({ main: [main({ speed: 1.025 })] })).timeline.main[0].speed, 1.05);
    assert.equal(T.parseTimeline(tl({ main: [main({ speed: 3.33 })] })).timeline.main[0].speed, 3.35);
});

test("bad_request: shapes, types, unknown and missing keys, ids, version", () => {
    refuses(null, "error.edit.bad_request", "");
    refuses([], "error.edit.bad_request", "");
    refuses("{not json", "error.edit.bad_request", "");
    refuses({ ...tl(), version: 2 }, "error.edit.bad_request", "version");
    refuses({ ...tl(), extra: 1 }, "error.edit.bad_request", "extra");
    const { overlay, ...noOverlay } = tl();
    refuses(noOverlay, "error.edit.bad_request", "overlay");
    refuses({ ...tl(), canvas: { w: 1080, h: 1920 } }, "error.edit.bad_request", "canvas.fps");
    refuses({ ...tl(), canvas: { w: 1080, h: 1920, fps: 30.5 } }, "error.edit.bad_request", "canvas.fps");
    refuses({ ...tl(), canvas: { w: "1080", h: 1920, fps: 30 } }, "error.edit.bad_request", "canvas.w");
    refuses({ ...tl(), canvas: { w: 1080, h: 1920, fps: 30, x: 1 } }, "error.edit.bad_request", "canvas.x");
    refuses({ ...tl(), main: "x" }, "error.edit.bad_request", "main");
    refuses(tl({ main: [main({ id: "bad id" })] }), "error.edit.bad_request", "main[0].id");
    refuses(tl({ main: [main({ id: "x".repeat(25) })] }), "error.edit.bad_request", "main[0].id");
    refuses(tl({ main: [main(), main({ item: C })] }), "error.edit.bad_request", "main[1].id");
    refuses(tl({ main: [main()], overlay: [over({ id: "m1" })] }), "error.edit.bad_request", "overlay[0].id");
    refuses(tl({ main: [main({ item: "short" })] }), "error.edit.bad_request", "main[0].item");
    refuses(tl({ main: [main({ item: "AAAAAAAAAAAAAAA-" })] }), "error.edit.bad_request", "main[0].item");
    refuses(tl({ main: [main({ in: "0" })] }), "error.edit.bad_request", "main[0].in");
    refuses(tl({ main: [main({ muted: 0 })] }), "error.edit.bad_request", "main[0].muted");
    refuses(tl({ main: [main({ fit: "stretch" })] }), "error.edit.bad_request", "main[0].fit");
    refuses(tl({ main: [main({ rotate: 90 })] }), "error.edit.bad_request", "main[0].rotate");
    refuses(tl({ main: [main({ crop: { aspect: "2:1", x: 0, y: 0, w: 1, h: 1 } })] }), "error.edit.bad_request", "main[0].crop.aspect");
    refuses(tl({ main: [main({ crop: { aspect: "free", x: 0, y: 0, w: 1 } })] }), "error.edit.bad_request", "main[0].crop.h");
    refuses(tl({ main: [main({ crop: { aspect: "free", x: 0, y: 0, w: 1, h: 1, z: 0 } })] }), "error.edit.bad_request", "main[0].crop.z");
    refuses(tl({ main: [main({ speed: NaN })] }), "error.edit.bad_request", "main[0].speed");
    refuses(tl({ overlay: [over({ text: "hi" })] }), "error.edit.bad_request", "overlay[0].text");
    refuses(tl({ overlay: [over({ frame: { x: 0, y: 0, w: 0.5, h: 0.5 } })] }), "error.edit.bad_request", "overlay[0].frame.h");
    refuses(tl({ overlay: [over({ frame: null })] }), "error.edit.bad_request", "overlay[0].frame");
});

test("canvas, empty, too_many_clips, too_long", () => {
    refuses({ ...tl(), canvas: { w: 1080, h: 1920, fps: 24 } }, "error.edit.canvas", "canvas.fps");
    refuses({ ...tl(), canvas: { w: 1000, h: 1920, fps: 30 } }, "error.edit.canvas", "canvas");
    refuses({ ...tl(), canvas: { w: 3840, h: 2160, fps: 30 } }, "error.edit.canvas", "canvas");
    refuses(tl({ main: [] }), "error.edit.empty", "main");
    const many = (/** @type {number} */ n) => Array.from({ length: n }, (_, i) => main({ id: `m${i}`, out: 1 }));
    assert.ok(T.parseTimeline(tl({ main: many(50) })).ok);
    refuses(tl({ main: many(51) }), "error.edit.too_many_clips", "main");
    refuses(tl({ main: many(50), overlay: [over()] }), "error.edit.too_many_clips", "main");
    assert.ok(T.parseTimeline(tl({ main: many(49), overlay: [over({ at: 0 })] })).ok);
    assert.ok(T.parseTimeline(tl({ main: [main({ out: 600 })] })).ok);
    refuses(tl({ main: [main({ out: 600.05 })] }), "error.edit.too_long", "main");
    assert.ok(T.parseTimeline(tl({ main: [main({ out: 2400, speed: 4 })] })).ok);
    refuses(tl({ main: [main({ out: 2400.1, speed: 4 })] }), "error.edit.too_long", "main");
});

test("range: times, speed, volume, crop, overlay frame and opacity", () => {
    refuses(tl({ main: [main({ in: -1 })] }), "error.edit.range", "main[0].in");
    refuses(tl({ main: [main({ in: 4, out: 4 })] }), "error.edit.range", "main[0].out");
    refuses(tl({ main: [main({ in: 5, out: 4 })] }), "error.edit.range", "main[0].out");
    refuses(tl({ main: [main({ in: 0, out: 0.099 })] }), "error.edit.range", "main[0].out");
    assert.ok(T.parseTimeline(tl({ main: [main({ in: 0, out: 0.1 })] })).ok);
    refuses(tl({ main: [main({ in: 0, out: 0.39, speed: 4 })] }), "error.edit.range", "main[0].out");
    assert.ok(T.parseTimeline(tl({ main: [main({ in: 0, out: 0.4, speed: 4 })] })).ok);
    refuses(tl({ main: [main({ speed: 0.2 })] }), "error.edit.range", "main[0].speed");
    refuses(tl({ main: [main({ speed: 4.05 })] }), "error.edit.range", "main[0].speed");
    refuses(tl({ main: [main({ speed: 0 })] }), "error.edit.range", "main[0].speed");
    refuses(tl({ main: [main({ volume: 1.01 })] }), "error.edit.range", "main[0].volume");
    refuses(tl({ main: [main({ volume: -0.1 })] }), "error.edit.range", "main[0].volume");
    const crop = (/** @type {any} */ o) => tl({ main: [main({ crop: { aspect: "free", x: 0, y: 0, w: 1, h: 1, ...o } })] });
    refuses(crop({ x: -0.1 }), "error.edit.range", "main[0].crop.x");
    refuses(crop({ w: 0 }), "error.edit.range", "main[0].crop.w");
    refuses(crop({ h: 0.00001 }), "error.edit.range", "main[0].crop.h");
    refuses(crop({ x: 0.5, w: 0.6 }), "error.edit.range", "main[0].crop.w");
    assert.ok(T.parseTimeline(crop({ x: 0.5, w: 0.5009 })).ok, "x + w within the 1.001 slack");
    refuses(crop({ y: 0.5, h: 0.6 }), "error.edit.range", "main[0].crop.h");
    refuses(tl({ overlay: [over({ at: -1 })] }), "error.edit.range", "overlay[0].at");
    refuses(tl({ overlay: [over({ in: 2, out: 2 })] }), "error.edit.range", "overlay[0].out");
    refuses(tl({ overlay: [over({ in: 0, out: 0.09 })] }), "error.edit.range", "overlay[0].out");
    refuses(tl({ overlay: [over({ frame: { x: 0.6, y: 0.05, w: 0.04 } })] }), "error.edit.range", "overlay[0].frame.w");
    refuses(tl({ overlay: [over({ frame: { x: 0.6, y: 0.05, w: 1.1 } })] }), "error.edit.range", "overlay[0].frame.w");
    refuses(tl({ overlay: [over({ frame: { x: -0.1, y: 0.05, w: 0.3 } })] }), "error.edit.range", "overlay[0].frame.x");
    refuses(tl({ overlay: [over({ frame: { x: 0.7, y: 0.05, w: 0.35 } })] }), "error.edit.range", "overlay[0].frame.x");
    refuses(tl({ overlay: [over({ frame: { x: 0.6, y: -0.05, w: 0.35 } })] }), "error.edit.range", "overlay[0].frame.y");
    refuses(tl({ overlay: [over({ opacity: 0.09 })] }), "error.edit.range", "overlay[0].opacity");
    refuses(tl({ overlay: [over({ opacity: 1.01 })] }), "error.edit.range", "overlay[0].opacity");
    assert.ok(T.parseTimeline(tl({ overlay: [over({ opacity: 0.1, volume: 0 })] })).ok);
});

test("overlays: sorted by at, never overlapping in frames, inside the main track", () => {
    const base = { main: [main({ out: 10 })] };
    assert.ok(T.parseTimeline(tl({ ...base, overlay: [over({ id: "a", at: 0, out: 2 }), over({ id: "b", at: 2, out: 2 })] })).ok, "touching is fine");
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 0, out: 2 }), over({ id: "b", at: 1.9667, out: 2 })] }), "error.edit.overlay_overlap", "overlay[1]");
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 3, out: 2 }), over({ id: "b", at: 1, out: 1 })] }), "error.edit.overlay_overlap", "overlay[1]");
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 1, out: 2 }), over({ id: "b", at: 1, out: 2 })] }), "error.edit.overlay_overlap", "overlay[1]");
    // frames, not seconds: 0.0167 s and 0.0166 s both round to frame 0 or 1
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 0, out: 0.1 }), over({ id: "b", at: 0.0832, out: 1 })] }), "error.edit.overlay_overlap", "overlay[1]");
    assert.ok(T.parseTimeline(tl({ ...base, overlay: [over({ id: "a", at: 8, out: 2 })] })).ok, "ends exactly at the end");
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 8, out: 2.1 })] }), "error.edit.overlay_past_end", "overlay[0]");
    refuses(tl({ ...base, overlay: [over({ id: "a", at: 10, out: 0.1 })] }), "error.edit.overlay_past_end", "overlay[0]");
});

test("timing: frames are the unit (31.4)", () => {
    const t = T.parseTimeline(tl({ main: [main({ in: 0, out: 0.35 }), main({ id: "m2", in: 1, out: 6, speed: 2.5 })], overlay: [over({ at: 0.35, out: 0.5 })] })).timeline;
    const x = T.timing(t);
    assert.equal(x.fps, 30);
    assert.deepEqual(x.main.map((c) => [c.frames, c.start, c.samples]), [[11, 0, 17600], [60, 11, 96000]]);
    assert.equal(x.main[0].speed, (0.35 * 30) / 11);
    assert.equal(x.main[1].speed, 2.5);
    assert.equal(x.frames, 71);
    assert.equal(x.seconds, 71 / 30);
    assert.deepEqual(x.overlay, [{ frames: 15, id: "o1", samples: 24000, start: 11 }]);
    const x60 = T.timing({ ...t, canvas: { w: 1920, h: 1080, fps: 60 } });
    assert.equal(x60.main[0].samples, x60.main[0].frames * 800);
    // a one-frame minimum
    assert.equal(T.timing(T.parseTimeline(tl({ main: [main({ out: 0.4, speed: 4 })] })).timeline).main[0].frames, 3);
});

test("shared fixture timing.json: 12 timelines", () => {
    const cases = JSON.parse(fx("timing.json"));
    assert.equal(cases.length, 12);
    for (const c of cases) {
        const r = T.parseTimeline(c.timeline);
        assert.ok(r.ok, `${c.name}: ${JSON.stringify(r)}`);
        assert.deepEqual(JSON.parse(JSON.stringify(T.timing(r.timeline))), c.expect, c.name);
    }
});

test("shared fixture geometry.json", () => {
    const g = JSON.parse(fx("geometry.json"));
    assert.equal(g.main.length, 432);
    assert.equal(g.overlay.length, 144);
    let nulls = 0;
    for (const c of g.main) {
        const got = T.mainPlacement(c.display, c.crop, c.fit, c.canvas);
        if (got === null) nulls++;
        assert.deepEqual(JSON.parse(JSON.stringify(got)), c.expect, `${c.source} ${c.cropName} ${c.fit} ${c.canvas.w}x${c.canvas.h}`);
    }
    for (const c of g.overlay) {
        assert.deepEqual(T.overlayPlacement(c.display, c.frame, c.canvas), c.expect, `${c.source} ${JSON.stringify(c.frame)} ${c.canvas.w}x${c.canvas.h}`);
    }
    assert.ok(nulls < 40, `${nulls} cases under 64 px`);
});

test("mainPlacement: 31.6 by hand", () => {
    const P = T.mainPlacement;
    // 1920x1080 fill on 1080x1920: scale to 3414x1920 (k = 1920/1080 = 1.7778), centre crop of 1080
    assert.deepEqual(P({ w: 1920, h: 1080 }, null, "fill", { w: 1080, h: 1920 }), { crop: { x: 0, y: 0, w: 1920, h: 1080 }, scaled: { w: 3414, h: 1920 }, place: { x: -1167, y: 0 } });
    // fit: 1080x608 (608 = evenNearest(607.5)), bars above and below
    assert.deepEqual(P({ w: 1920, h: 1080 }, null, "fit", { w: 1080, h: 1920 }), { crop: { x: 0, y: 0, w: 1920, h: 1080 }, scaled: { w: 1080, h: 608 }, place: { x: 0, y: 656 } });
    // an odd source is made even
    assert.deepEqual(P({ w: 481, h: 271 }, null, "fit", { w: 720, h: 720 }).crop, { x: 0, y: 0, w: 480, h: 270 });
    // crop under 64 px: null
    assert.equal(P({ w: 1920, h: 1080 }, { x: 0, y: 0, w: 0.03, h: 0.5 }, "fill", { w: 720, h: 720 }), null);
    assert.equal(P({ w: 1, h: 1 }, null, "fill", { w: 720, h: 720 }), null);
    // fill never leaves the canvas short on either side
    for (const [w, h] of T.EDIT_CANVASES) for (const [sw, sh] of [[1921, 1081], [333, 777], [4032, 3024]]) {
        const f = P({ w: sw, h: sh }, null, "fill", { w, h });
        assert.ok(f.scaled.w >= w && f.scaled.h >= h);
        assert.ok(f.scaled.w === w || f.scaled.h === h);
        const g = P({ w: sw, h: sh }, null, "fit", { w, h });
        assert.ok(g.scaled.w <= w && g.scaled.h <= h);
        assert.ok(g.place.x >= 0 && g.place.y >= 0);
    }
});

/** @param {Record<string, any>} over */
const row = (id, over = {}) => ({ id, content_type: "video/mp4", source: "save", width: 1920, height: 1080, duration: 12, bytes: 1000, deleted: false, ...over });

test("checkSources: missing, unsupported, not a video, too large", () => {
    const t = T.parseTimeline(tl({ main: [main({ item: A }), main({ id: "m2", item: C })], overlay: [over({ item: B })] })).timeline;
    const rows = [row(A), row(B), row(C)];
    assert.ok(T.checkSources(t, rows).ok);
    assert.ok(T.checkSources(t, new Map(rows.map((r) => [r.id, r]))).ok);
    assert.ok(T.checkSources(t, Object.fromEntries(rows.map((r) => [r.id, r]))).ok);
    let r = T.checkSources(t, [row(A), row(B)]);
    assert.deepEqual([r.ok, r.code, r.path, r.items], [false, "error.edit.source_missing", "main[1].item", [C]]);
    r = T.checkSources(t, [row(A), row(B, { deleted: true }), row(C, { deleted: 1 })]);
    assert.deepEqual([r.code, r.path, r.items], ["error.edit.source_missing", "main[1].item", [C, B]]);
    r = T.checkSources(t, [row(A), row(B), row(C, { content_type: "video/webm" })]);
    assert.deepEqual([r.code, r.path, r.items], ["error.edit.unsupported_source", "main[1].item", [C]]);
    r = T.checkSources(t, [row(A), row(B), row(C, { content_type: "image/heic" })]);
    assert.equal(r.code, "error.edit.unsupported_source");
    r = T.checkSources(t, [row(A), row(B), row(C, { content_type: "image/png" })]);
    assert.deepEqual([r.code, r.path, r.items], ["error.edit.not_video", "main[1].item", [C]]);
    r = T.checkSources(t, [row(A), row(B, { content_type: "image/gif" }), row(C)]);
    assert.ok(r.ok, "an overlay may be a gif");
    r = T.checkSources(t, [row(A, { bytes: 4 * 1024 ** 3 }), row(B), row(C, { bytes: 2 * 1024 ** 3 + 1 })]);
    assert.equal(r.code, "error.edit.too_large");
    // the same item used twice counts once
    const twice = T.parseTimeline(tl({ main: [main({ item: A }), main({ id: "m2", item: A })] })).timeline;
    assert.ok(T.checkSources(twice, [row(A, { bytes: 5 * 1024 ** 3 })]).ok);
    // content type parameters and case
    assert.ok(T.checkSources(twice, [row(A, { content_type: "Video/MP4; codecs=avc1" })]).ok);
});

test("checkSources: out past the source end, within the slack it is clamped", () => {
    const t = T.parseTimeline(tl({ main: [main({ in: 1, out: 12.04 })] })).timeline;
    let r = T.checkSources(t, [row(A, { duration: 12 })]);
    assert.ok(r.ok);
    assert.equal(r.timeline.main[0].out, 12);
    assert.equal(t.main[0].out, 12.04, "the input is not mutated");
    r = T.checkSources(t, [row(A, { duration: 11.9 })]);
    assert.deepEqual([r.code, r.path], ["error.edit.past_source_end", "main[0].out"]);
    r = T.checkSources(t, [row(A, { duration: null })]);
    assert.ok(r.ok && r.timeline.main[0].out === 12.04, "no duration known: nothing to check");
    // clamped to under the minimum length
    const short = T.parseTimeline(tl({ main: [main({ in: 11.95, out: 12.05 })] })).timeline;
    r = T.checkSources(short, [row(A, { duration: 12 })]);
    assert.deepEqual([r.code, r.path], ["error.edit.range", "main[0].out"]);
    // clamping shortens the main track, so an overlay that ended exactly at its end now runs past it
    const edge = T.parseTimeline(tl({ main: [main({ in: 0, out: 10.04 })], overlay: [over({ at: 8, out: 2.04 })] })).timeline;
    r = T.checkSources(edge, [row(A, { duration: 10 }), row(B)]);
    assert.deepEqual([r.code, r.path], ["error.edit.overlay_past_end", "overlay[0]"], "10.04 s is 301 frames, 10 s is 300");
});

test("checkSources: crop under 64 px of the real source, overlay kinds, overlay height", () => {
    const small = T.parseTimeline(tl({ main: [main({ crop: { aspect: "free", x: 0, y: 0, w: 0.2, h: 1 } })] })).timeline;
    let r = T.checkSources(small, [row(A, { width: 300, height: 300 })]);
    assert.deepEqual([r.code, r.path], ["error.edit.range", "main[0].crop"]);
    assert.ok(T.checkSources(small, [row(A, { width: 1000, height: 300 })]).ok);
    assert.ok(T.checkSources(small, [row(A, { width: null, height: null })]).ok, "size unknown: checked at render");
    // gif / photo overlays: in 0, out 0.1..600
    const gif = (/** @type {any} */ o) => T.parseTimeline(tl({ main: [main({ out: 10 })], overlay: [over({ at: 0, ...o })] })).timeline;
    r = T.checkSources(gif({ in: 1, out: 3 }), [row(A), row(B, { content_type: "image/gif" })]);
    assert.deepEqual([r.code, r.path], ["error.edit.range", "overlay[0].in"]);
    r = T.checkSources(gif({ in: 0, out: 3 }), [row(A), row(B, { content_type: "image/png", duration: null })]);
    assert.ok(r.ok);
    // overlay height: h = w * canvas.w / canvas.h * srcH / srcW; a tall photo at w 0.35 on 1080x1920 is 0.35 * 0.5625 * 2 = 0.39375
    const tall = T.parseTimeline(tl({ main: [main()], overlay: [over({ frame: { x: 0.1, y: 0.7, w: 0.35 }, in: 0, out: 2 })] })).timeline;
    r = T.checkSources(tall, [row(A), row(B, { content_type: "image/jpeg", width: 1000, height: 2000 })]);
    assert.deepEqual([r.code, r.path], ["error.edit.range", "overlay[0].frame.y"]);
    assert.ok(T.checkSources(tall, [row(A), row(B, { content_type: "image/jpeg", width: 2000, height: 1000 })]).ok);
    // a video overlay past the end of its source
    const vo = T.parseTimeline(tl({ overlay: [over({ in: 0, out: 3 })] })).timeline;
    r = T.checkSources(vo, [row(A), row(B, { duration: 2.9 })]);
    assert.deepEqual([r.code, r.path], ["error.edit.past_source_end", "overlay[0].out"]);
});
