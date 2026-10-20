// Writes the shared fixtures (APP-API-CONTRACT.md 31.2, 31.4, 31.6) from the reference implementation in ../timeline.js:
//   node helper/test/gen-fixtures.js
// The Swift suite (EditTimeline / EditTiming / EditGeometry) runs the same files and must reproduce every number.

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { compile } from "../compile.js";
import { EDIT_CANVASES, canonicalJSON, mainPlacement, overlayPlacement, parseTimeline, timing } from "../timeline.js";
import { fakeSources } from "./fakes.js";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const must = (/** @type {any} */ r) => {
    if (!r.ok) throw new Error(`${r.code} ${r.path}`);
    return r.timeline;
};
const write = (/** @type {string} */ name, /** @type {string} */ text) => writeFileSync(path.join(dir, name), text);

// ---- timeline-beach.json: the example of 31.2, canonical bytes (no trailing newline: parity tests compare bytes)
const beach = {
    version: 1,
    canvas: { w: 1080, h: 1920, fps: 30 },
    main: [
        { id: "cA1b2C3d4", item: "Ab3dEf6hIj9kLm2n", in: 2, out: 9.5, speed: 1.5, crop: { aspect: "9:16", x: 0.3, y: 0, w: 0.3164, h: 1 }, fit: "fill", volume: 1, muted: false },
        { id: "cE5f6G7h8", item: "Qr5tUv8xYz1bCd4f", in: 0, out: 4, speed: 1, fit: "fill", volume: 0.7, muted: false },
    ],
    overlay: [{ id: "cI9j0K1l2", item: "Gh7jKl0nOp3rSt6v", at: 3, in: 0, out: 3, frame: { x: 0.6, y: 0.05, w: 0.35 }, opacity: 1, volume: 1, muted: true }],
};
write("timeline-beach.json", canonicalJSON(must(parseTimeline(beach))));

// ---- timing.json: 12 timelines and what timing() says
const A = "AAAAAAAAAAAAAAAA", B = "BBBBBBBBBBBBBBBB", C = "CCCCCCCCCCCCCCCC";
/** @param {string} id @param {number} i @param {number} o @param {number} [speed] */
const m = (id, i, o, speed = 1) => ({ id, item: A, in: i, out: o, speed, fit: "fill", volume: 1, muted: false });
/** @param {string} id @param {number} at @param {number} i @param {number} o */
const ov = (id, at, i, o) => ({ id, item: B, at, in: i, out: o, frame: { x: 0.6, y: 0.05, w: 0.35 }, opacity: 1, volume: 1, muted: true });
const cv = (/** @type {number} */ w, /** @type {number} */ h, /** @type {number} */ fps) => ({ w, h, fps });
const cases = [
    ["one clip, whole", cv(1080, 1920, 30), [m("a", 0, 10)], []],
    ["two clips, trimmed", cv(1080, 1080, 30), [m("a", 1.25, 4.5), m("b", 0, 2.333)], []],
    ["half a frame rounds up (0.35 s = 10.5 frames)", cv(720, 1280, 30), [m("a", 0, 0.35), m("b", 1, 1.45)], []],
    ["speed 0.25", cv(1280, 720, 30), [m("a", 0, 2, 0.25)], []],
    ["speed 4", cv(1280, 720, 30), [m("a", 0, 10, 4)], []],
    ["speed 1.35 (a multiple of 0.05) and 60 fps", cv(1920, 1080, 60), [m("a", 2, 7, 1.35), m("b", 0.1, 0.5, 4)], []],
    ["shortest clip: 0.1 s at speed 4 is 0.4 s of source", cv(720, 720, 30), [m("a", 0, 0.4, 4)], []],
    ["a clip that is 30.016 s (rounds to 901 frames) and a speed of 1.05", cv(1080, 1920, 30), [m("a", 0, 30.016), m("b", 5.5, 8.5, 1.05)], []],
    ["one overlay", cv(1080, 1920, 30), [m("a", 0, 10)], [ov("o", 3, 0, 3)]],
    ["overlay start 0.35 s = 10.5 frames rounds up; length 0.1667 s = 5 frames", cv(1080, 1920, 30), [m("a", 0, 10)], [ov("o", 0.35, 0, 0.1667)]],
    ["two overlays back to back, 60 fps", cv(1920, 1080, 60), [m("a", 0, 5), m("b", 0, 5)], [ov("o", 1, 0, 2.5), ov("p", 3.5, 0.5, 6.5)]],
    ["overlay ending exactly at the end", cv(1080, 1080, 30), [m("a", 0, 6, 2)], [ov("o", 2, 0, 1)]],
];
const timingOut = cases.map(([name, canvas, main, overlay]) => {
    const timeline = must(parseTimeline({ version: 1, canvas, main, overlay }));
    return { name, timeline, expect: timing(timeline) };
});
write("timing.json", `${JSON.stringify(timingOut, null, 1)}\n`);

// ---- geometry.json: sizes x canvases x crops x fit/fill, and overlay boxes
const sizes = [
    ["1920x1080", 1920, 1080],
    ["1080x1920", 1080, 1920],
    ["1440x1080 rotated 90 (displays 1080x1440)", 1080, 1440],
    ["480x270", 480, 270],
    ["1:1 gif 500x500", 500, 500],
    ["3024x4032 photo", 3024, 4032],
];
const round4 = (/** @type {number} */ v) => Math.round(v * 1e4) / 1e4;
/** The biggest centred rectangle of aspect a:b inside a w*h frame, normalised. */
const centred = (/** @type {number} */ w, /** @type {number} */ h, /** @type {number} */ a, /** @type {number} */ b) => {
    let cw = 1, ch = 1;
    if (w / h > a / b) cw = ((a / b) * h) / w;
    else ch = ((b / a) * w) / h;
    return { x: round4((1 - cw) / 2), y: round4((1 - ch) / 2), w: round4(cw), h: round4(ch) };
};
const main = [];
for (const [sname, sw, sh] of sizes) {
    const crops = [
        ["none", null],
        ["free", { x: 0.1, y: 0.2, w: 0.55, h: 0.4 }],
        ["9:16", centred(sw, sh, 9, 16)],
        ["1:1", centred(sw, sh, 1, 1)],
        ["4:5", centred(sw, sh, 4, 5)],
        ["16:9", centred(sw, sh, 16, 9)],
    ];
    for (const [w, h] of EDIT_CANVASES) {
        for (const [cname, crop] of crops) {
            for (const fit of ["fit", "fill"]) {
                const canvas = { w, h };
                main.push({ source: sname, display: { w: sw, h: sh }, crop, cropName: cname, fit, canvas, expect: mainPlacement({ w: sw, h: sh }, crop, /** @type {any} */ (fit), canvas) });
            }
        }
    }
}
const frames = [
    { x: 0.6, y: 0.05, w: 0.35 },
    { x: 0, y: 0, w: 1 },
    { x: 0.05, y: 0.8, w: 0.05 },
    { x: 0.7, y: 0.9, w: 0.35 }, // outside the canvas on purpose: placement clamps it inside
];
const overlay = [];
for (const [sname, sw, sh] of sizes) {
    for (const [w, h] of EDIT_CANVASES) {
        for (const frame of frames) {
            const canvas = { w, h };
            overlay.push({ source: sname, display: { w: sw, h: sh }, frame, canvas, expect: overlayPlacement({ w: sw, h: sh }, frame, canvas) });
        }
    }
}
write("geometry.json", `${JSON.stringify({ main, overlay })}\n`);
// ---- argv.json: the compiler's argv for each fixture timeline, against deterministic fake sources (fakes.js)
const argvCases = [{ name: "timeline-beach", timeline: must(parseTimeline(beach)) }, ...timingOut.map((c) => ({ name: c.name, timeline: c.timeline }))];
argvCases.push({
    name: "everything: a trimmed far clip, a speed, crop, fit, an HDR clip, mono, no audio, a square-pixel clip, three overlays",
    timeline: must(parseTimeline({
        version: 1,
        canvas: { w: 720, h: 1280, fps: 60 },
        main: [
            { id: "a", item: "AAAAAAAAAAAAAAAA", in: 40.5, out: 44.25, speed: 0.75, crop: { aspect: "16:9", x: 0, y: 0.2, w: 1, h: 0.5625 }, fit: "fit", volume: 0.8, muted: false },
            { id: "b", item: "BBBBBBBBBBBBBBBB", in: 1, out: 5, speed: 4, fit: "fill", volume: 1, muted: false },
            { id: "c", item: "CCCCCCCCCCCCCCCC", in: 0, out: 2, speed: 0.25, fit: "fill", volume: 1, muted: false },
            { id: "d", item: "DDDDDDDDDDDDDDDD", in: 3, out: 5, speed: 1, fit: "fit", volume: 1, muted: true },
        ],
        overlay: [
            { id: "e", item: "AAAAAAAAAAAAAAAA", at: 0.5, in: 10, out: 12, frame: { x: 0.05, y: 0.05, w: 0.4 }, opacity: 0.6, volume: 0.5, muted: false },
            { id: "f", item: "EEEEEEEEEEEEEEEE", at: 2.5, in: 0, out: 1.5, frame: { x: 0.5, y: 0.5, w: 0.4 }, opacity: 1, volume: 1, muted: true },
            { id: "g", item: "FFFFFFFFFFFFFFFF", at: 5, in: 0, out: 3, frame: { x: 0.3, y: 0.1, w: 0.3 }, opacity: 0.9, volume: 1, muted: true },
        ],
    })),
});
const argv = argvCases.map(({ name, timeline }) => {
    const c = compile(timeline, fakeSources(timeline), { output: "/tmp/edit/R/out.mp4" });
    if (!c.ok) throw new Error(`${name}: ${c.code} ${c.path}`);
    return { name, args: c.args };
});
write("argv.json", `${JSON.stringify(argv, null, 1)}\n`);
console.log(`timeline-beach.json, timing.json (${timingOut.length}), geometry.json (${main.length} main, ${overlay.length} overlay), argv.json (${argv.length})`);
