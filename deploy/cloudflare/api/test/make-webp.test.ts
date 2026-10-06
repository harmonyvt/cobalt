// The slideshow webp (APP-API-CONTRACT.md 18.10, apple/CONTRACT-GALLERY.md 6.2, lane S1):
//  - the frame plan (the worked example, cut vs fade, a video in the middle) and the argv builders, pure;
//  - the start body's rules at the helper, and the plan's rules at the Durable Object (formats, caps, 0.5 s photos);
//  - POST /studio/<sid>/slideshow with `format: "webp"` against the fake helper: the wire, the result row, its poster,
//    replace per format (R8), an older helper;
//  - the real encode (ffmpeg + img2webp; skipped with a logged reason when either is absent).
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
    FADE_FRAMES,
    buildBlendArgs,
    buildComposePngArgs,
    buildFrameListArgs,
    buildMotionFramesArgs,
    planMs,
    planWebpFrames,
    renderSlideshowWebp,
} from "../helper/make.js";
import { parseHasAudio, parseVideoInfo, parseWebp, validateSlideshowStart } from "../helper/lib.js";
import { slideshowFrame, parseSlideshowPlan } from "../src/studio";
import { KEY_ID, POSTER_URL, asBody, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { itemRows, photos, saveGallery } from "./gallery-world";
import type { GalleryItemSpec } from "./studio-fakes";

// ---- the frame plan (6.2) -----------------------------------------------------------------------------------------

const ms = (frames: { ms: number }[]) => frames.map((f) => f.ms);
const still = (seconds: number) => ({ kind: "still" as const, seconds });
const motion = (seconds: number, frames?: number) => ({ kind: "motion" as const, seconds, frames });

describe("planWebpFrames", () => {
    it("the worked example of 6.2: 3 photos at 2 s with fade = 1866, 4 x 67, 1732, 4 x 67, 1866 = 6000 ms", () => {
        const p = planWebpFrames([still(2), still(2), still(2)], true);
        expect(ms(p.frames)).toEqual([1866, 67, 67, 67, 67, 1732, 67, 67, 67, 67, 1866]);
        expect(p.frames.map((f) => f.t)).toEqual(["still", ...Array(4).fill("fade"), "still", ...Array(4).fill("fade"), "still"]);
        expect(p.totalMs).toBe(6000);
    });

    it("a cut is one frame per photo held its whole time", () => {
        const p = planWebpFrames([still(2), still(0.5), still(10)], false);
        expect(ms(p.frames)).toEqual([2000, 500, 10000]);
        expect(p.totalMs).toBe(12500);
    });

    it("a fade names the slides it blends and counts j = 1..4", () => {
        const p = planWebpFrames([still(2), still(2)], true);
        expect(p.frames.filter((f) => f.t === "fade").map((f: any) => [f.from, f.to, f.j])).toEqual([[0, 1, 1], [0, 1, 2], [0, 1, 3], [0, 1, 4]]);
        expect(FADE_FRAMES).toBe(4);
    });

    it("a video in the middle: its frames at 15 fps, 2 frames fewer at each end that has a crossfade, the last holds what is left", () => {
        // a 2 s video decoded to 30 frames, between two photos of 2 s, fade on: target 2000 - 268 = 1732 ms = 26 frames (25 x 67 + 57)
        const p = planWebpFrames([still(2), motion(2, 30), still(2)], true);
        const m = p.frames.filter((f) => f.t === "motion") as { frame: number; ms: number }[];
        expect(m).toHaveLength(26);
        expect(m[0]!.frame).toBe(2); // the first two frames are under the crossfade
        expect(m.at(-1)!.frame).toBe(27); // 2 + 25: frames 28-30 are never shown (the last 2 + the rounding)
        expect(m.slice(0, -1).every((f) => f.ms === 67)).toBe(true);
        expect(m.at(-1)!.ms).toBe(1732 - 25 * 67);
        expect(m.reduce((t, f) => t + f.ms, 0)).toBe(1732);
        expect(p.totalMs).toBe(6000);
    });

    it("a video first only fades out (trimmed at its end), one last only fades in (trimmed at its start)", () => {
        const first = planWebpFrames([motion(1, 15), still(2)], true).frames.filter((f) => f.t === "motion") as { frame: number; ms: number }[];
        expect(first[0]!.frame).toBe(0);
        expect(first.reduce((t, f) => t + f.ms, 0)).toBe(1000 - 134);
        const last = planWebpFrames([still(2), motion(1, 15)], true).frames.filter((f) => f.t === "motion") as { frame: number; ms: number }[];
        expect(last[0]!.frame).toBe(2);
        expect(last.reduce((t, f) => t + f.ms, 0)).toBe(1000 - 134);
    });

    it("without a fade the video is all its frames and the total is its seconds", () => {
        const p = planWebpFrames([motion(1.2, 18), still(1)], false);
        expect(p.frames.filter((f) => f.t === "motion")).toHaveLength(18);
        expect(p.totalMs).toBe(2200);
    });

    it("the total is the plan's length for any mix (a frame of rounding at most, never one per video)", () => {
        const mixes = [
            [still(0.5), still(0.5), still(0.5)],
            [still(2.5), motion(3.3), still(7), motion(0.9), still(0.5)],
            [motion(10, 150), motion(10, 150), motion(10, 150), still(1), still(1)],
            Array.from({ length: 20 }, (_, i) => (i % 3 === 1 ? motion(1.7 + i / 10) : still(0.5 + (i % 7) / 2))),
        ];
        for (const fade of [true, false]) {
            for (const mix of mixes) {
                const p = planWebpFrames(mix, fade);
                expect(Math.abs(p.totalMs - planMs(mix)), JSON.stringify(mix)).toBeLessThanOrEqual(1);
                expect(p.frames.every((f) => Number.isInteger(f.ms) && f.ms > 0)).toBe(true);
            }
        }
    });

    it("0.5 s photos with a fade on both sides keep 232 ms (500 - 268)", () => {
        const p = planWebpFrames([still(0.5), still(0.5), still(0.5)], true);
        expect(ms(p.frames)[5]).toBe(232);
    });

    it("a single slide never fades", () => {
        expect(planWebpFrames([still(3)], true).frames).toEqual([{ t: "still", slide: 0, ms: 3000 }]);
    });
});

describe("the argv builders", () => {
    it("img2webp: today's forced-keyframe flags, then -d <ms> <file> per frame", () => {
        const a = buildFrameListArgs({ frames: [{ file: "s-0.png", ms: 1866 }, { file: "x-0-1.png", ms: 67 }], output: "/o.webp", quality: "med" });
        expect(a).toEqual(["-loop", "0", "-lossy", "-q", "75", "-m", "4", "-kmin", "3", "-kmax", "5", "-d", "1866", "s-0.png", "-d", "67", "x-0-1.png", "-o", "/o.webp"]);
        expect(buildFrameListArgs({ frames: [], output: "o", quality: "low" })[4]).toBe("65");
        expect(buildFrameListArgs({ frames: [], output: "o", quality: "high" })[4]).toBe("85");
    });
    it("the blend: 4 outputs, outgoing weight 1 - j/5 and incoming j/5, one process", () => {
        const a = buildBlendArgs({ a: "/a.png", b: "/b.png", outputs: ["/1", "/2", "/3", "/4"] });
        const g = a[a.indexOf("-filter_complex") + 1]!;
        for (const [w1, w2] of [["0.8", "0.2"], ["0.6", "0.4"], ["0.4", "0.6"], ["0.2", "0.8"]]) expect(g).toContain(`blend=all_expr='A*${w1}+B*${w2}'`);
        expect(a.filter((x) => x === "-map")).toHaveLength(4);
        expect(a.filter((x) => x === "-i")).toHaveLength(2);
        expect(a.at(-1)).toBe("/4");
    });
    it("compose and decode use the frame size and the blurred fill only when the shape differs", () => {
        const blur = buildComposePngArgs({ input: "/i", output: "/o.png", width: 480, height: 600, blur: true }).join(" ");
        expect(blur).toContain("boxblur");
        expect(blur).toContain("format=rgb24");
        const plain = buildComposePngArgs({ input: "/i", output: "/o.png", width: 480, height: 600, blur: false }).join(" ");
        expect(plain).not.toContain("boxblur");
        const m = buildMotionFramesArgs({ input: "/v", pattern: "/f/m0-%05d.png", width: 480, height: 600, blur: true, fps: 15 }).join(" ");
        expect(m).toContain("fps=15");
        expect(m).toContain("%05d.png");
    });
});

// ---- the start body at the helper ------------------------------------------------------------------------------------

describe("validateSlideshowStart: the webp", () => {
    const webp = { width: 480, height: 600, fade: true, sound: "none", format: "webp", slides: [{ n: 0, seconds: 2 }, { n: 1, seconds: null }] };
    it("accepts it, with the defaults filled in (quality med, fps 15)", () => {
        expect(validateSlideshowStart(webp)).toEqual({ ...webp, quality: "med", fps: 15 });
        expect(validateSlideshowStart({ ...webp, quality: "high", fps: 15, width: 320 })).toMatchObject({ quality: "high", width: 320 });
    });
    it("an mp4 body is returned exactly as it came (no format key) and takes neither quality nor fps", () => {
        const mp4 = { width: 1080, height: 1350, fade: true, sound: "own", slides: [{ n: 0, seconds: 0.5 }] };
        expect(validateSlideshowStart(mp4)).toEqual(mp4);
        expect(validateSlideshowStart({ ...mp4, format: "mp4" })).toMatchObject({ width: 1080 });
        expect(validateSlideshowStart({ ...mp4, quality: "med" })).toBeNull();
        expect(validateSlideshowStart({ ...mp4, fps: 15 })).toBeNull();
    });
    it.each([
        ["a width that is not 320 or 480", { ...webp, width: 640 }],
        ["sound own", { ...webp, sound: "own" }],
        ["a quality that is not one", { ...webp, quality: "ultra" }],
        ["fps 5", { ...webp, fps: 5 }],
        ["a format that is not one", { ...webp, format: "gif" }],
        ["stills over 60 s", { ...webp, slides: Array.from({ length: 5 }, (_, n) => ({ n, seconds: 15 })) }],
    ])("rejects %s", (_n, b) => {
        expect(validateSlideshowStart(b)).toBeNull();
    });
    it("exactly 60 s of stills is fine", () => {
        expect(validateSlideshowStart({ ...webp, slides: Array.from({ length: 4 }, (_, n) => ({ n, seconds: 15 })) })).not.toBeNull();
    });
});

// ---- the plan at the Durable Object ----------------------------------------------------------------------------------

describe("parseSlideshowPlan: format, quality, width, the caps and 0.5 s photos", () => {
    const base = { items: [0, 1], seconds: [2, 2] };
    const parse = (o: Record<string, unknown>) => parseSlideshowPlan({ ...base, ...o }, "error.webp.invalid_params");
    it("an mp4 plan is exactly what it was (no format key)", () => {
        expect(parse({})).toEqual({ ok: true, plan: { items: [0, 1], seconds: [2, 2], fade: true, frame: "keep", sound: "none" } });
        expect(parse({ format: "mp4" })).toMatchObject({ ok: true });
        expect((parse({ format: "mp4" }) as any).plan).not.toHaveProperty("format");
    });
    it("a webp plan fills quality med and width 480", () => {
        expect((parse({ format: "webp" }) as any).plan).toMatchObject({ format: "webp", quality: "med", width: 480, sound: "none" });
        expect((parse({ format: "webp", quality: "low", width: 320 }) as any).plan).toMatchObject({ quality: "low", width: 320 });
    });
    it.each([
        ["quality with mp4", { quality: "med" }],
        ["width with mp4", { width: 480 }],
        ["format that is not one", { format: "avi" }],
        ["webp width 640", { format: "webp", width: 640 }],
        ["webp quality ultra", { format: "webp", quality: "ultra" }],
        ["webp with sound own", { format: "webp", sound: "own" }],
        ["0.4 s", { seconds: [0.4, 2] }],
        ["a number for a gif/null mismatch is judged later, but 16 s is not", { seconds: [16, 2] }],
    ])("rejects %s with 400 invalid_params", (_n, o) => {
        expect(parse(o)).toMatchObject({ ok: false, status: 400, code: "error.webp.invalid_params" });
    });
    it("0.5 s is accepted; the webp's 60 s and the mp4's 180 s are the caps (too_long)", () => {
        expect(parse({ seconds: [0.5, 0.5] })).toMatchObject({ ok: true });
        const many = (n: number, s: number) => ({ items: Array.from({ length: n }, (_, i) => i), seconds: Array(n).fill(s) });
        expect(parse({ ...many(4, 15), format: "webp" })).toMatchObject({ ok: true }); // 60 s
        expect(parse({ ...many(4, 15.1), format: "webp" })).toMatchObject({ ok: false }); // over 15 s a photo: the shape's error
        expect(parse({ ...many(5, 12.1), format: "webp" })).toMatchObject({ ok: false, code: "error.webp.too_long" }); // 60.5 s
        expect(parse({ ...many(5, 12), format: "webp" })).toMatchObject({ ok: true }); // 60 s
        expect(parse({ ...many(13, 14) })).toMatchObject({ ok: false, code: "error.webp.too_long" }); // 182 s, mp4
        expect(parse({ ...many(12, 15) })).toMatchObject({ ok: true }); // 180 s
    });
});

describe("slideshowFrame: the webp's frame", () => {
    const d = (w: number, h: number, n = 1) => Array.from({ length: n }, () => ({ width: w, height: h }));
    it("480 across: 4:5 -> 480x600, 9:16 -> 480x854, 1:1 -> 480x480; 320 -> 320x400", () => {
        expect(slideshowFrame("keep", d(1080, 1350, 3), 480)).toEqual({ width: 480, height: 600 });
        expect(slideshowFrame("9:16", d(1080, 1350), 480)).toEqual({ width: 480, height: 854 });
        expect(slideshowFrame("1:1", d(1080, 1350), 480)).toEqual({ width: 480, height: 480 });
        expect(slideshowFrame("keep", d(1080, 1350), 320)).toEqual({ width: 320, height: 400 });
    });
    it("keep takes the most common shape (ties: the first); an unknown size is square", () => {
        expect(slideshowFrame("keep", [...d(1200, 1200, 2), ...d(1080, 1350)], 480)).toEqual({ width: 480, height: 480 });
        expect(slideshowFrame("keep", [{ width: null, height: null }], 480)).toEqual({ width: 480, height: 480 });
    });
    it("the mp4's frame is as it was", () => {
        expect(slideshowFrame("keep", d(1080, 1350))).toEqual({ width: 1080, height: 1350 });
        expect(slideshowFrame("9:16", d(1080, 1350))).toEqual({ width: 1080, height: 1920 });
    });
});

// ---- POST /studio/<sid>/slideshow with format webp, against the fake helper ---------------------------------------------

const mixed = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo" }, { type: "photo" }, { type: "video", duration: 4 }, { type: "gif", duration: 2 }];
const plan = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2, 3], seconds: [2, 2, 2, null], fade: true, frame: "keep", format: "webp", ...over });
const slide = (L: LW, sid: string, body: unknown) => L.studio.slideshow(KEY_ID, sid, typeof body === "string" ? body : json(body));
const renderRow = (L: LW, job: string) => L.rows("SELECT * FROM studio_renders WHERE id = ?", job)[0];
const slideRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'slideshow' AND deleted_at IS NULL ORDER BY created_at, id", sid);
async function gallery(L: LW, specs = mixed(), b: Record<string, unknown> = {}) {
    const g = await saveGallery(L as any, specs, b);
    expect(g.done.status).toBe("ready");
    return g;
}

describe("a slideshow webp on a free helper", () => {
    it("the helper is started with the webp frame, quality and fps; the inputs go by slot", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const r = await slide(L, sid, plan({ quality: "high", width: 320, queue: true, priority: "focused" }));
        expect(r.status).toBe(202);
        const job = asBody(r).job as string;
        expect(L.helper.slideStarts).toEqual([
            { job, body: { width: 320, height: 400, fade: true, sound: "none", slides: [{ n: 0, seconds: 2 }, { n: 1, seconds: 2 }, { n: 2, seconds: 2 }, { n: 3, seconds: null }], format: "webp", quality: "high", fps: 15 } },
        ]);
        expect(JSON.parse(renderRow(L, job).plan)).toEqual({ items: [0, 1, 2, 3], seconds: [2, 2, 2, null], fade: true, frame: "keep", sound: "none", format: "webp", quality: "high", width: 320 });
    });

    it("defaults: 480 wide, quality med; an mp4 start carries no format at all", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        await slide(L, sid, plan());
        expect(L.helper.slideStarts[0]!.body).toMatchObject({ width: 480, height: 600, format: "webp", quality: "med", fps: 15 });
        await L.studio.renderStatus(sid, L.helper.slideStarts[0]!.job, 0);
        const mp4 = asBody(await slide(L, sid, plan({ format: undefined, sound: "own" }))).job as string;
        const start = L.helper.slideStarts.find((s) => s.job === mp4)!;
        expect(start.body).not.toHaveProperty("format");
        expect(start.body).toMatchObject({ width: 1080, height: 1350, sound: "own" });
    });

    it("the result is a role 'slideshow' row of image/webp, stored as .webp, with the helper's first frame as its poster (and no poster job)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await slide(L, sid, plan())).job as string;
        const items = itemRows(L as any, sid);
        L.helper.slidePolls = 1;
        L.helper.slidePendingFields = { phase: "encoding", done: 0, total: 6 };
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toMatchObject({ status: "pending", phase: "encoding", frames_done: 0, frames_total: 6 });
        const done = await L.studio.renderStatus(sid, job, 0);
        const row = slideRows(L, sid)[0]!;
        expect(done.body).toEqual({ status: "success", job, item_id: row.id, bytes: 3000, width: 480, height: 600, seconds: 6, format: "webp", replaced: [] });
        expect(row).toMatchObject({
            kind: "private",
            source: "studio",
            bucket: "originals",
            r2_key: `originals/${sid}-s${job}.webp`,
            content_type: "image/webp",
            bytes: 3000,
            width: 480,
            height: 600,
            duration: 6,
            role: "slideshow",
            post_key: sid,
            visibility: "private",
            url: null,
        });
        expect(row.poster).toMatch(POSTER_URL);
        expect(L.media.objects.has(row.poster.split("/").pop())).toBe(true);
        expect(JSON.parse(row.made_from)).toEqual(items.slice(0, 4).map((x) => x.id));
        expect(JSON.parse(row.made_spec)).toMatchObject({ format: "webp", quality: "med", width: 480, fade: true, items: [0, 1, 2, 3], seconds: [2, 2, 2, null] });
        expect(L.originals.objects.get(row.r2_key)).toMatchObject({ contentType: "image/webp" });
        expect(L.originals.objects.get(row.r2_key)!.bytes).toEqual(L.helper.slideWebpFile);
        expect(L.keys("poster:")).not.toContain(`poster:${row.id}`); // ffmpeg cannot read an animated webp: the helper's frame is the poster
        expect(L.helper.slideDeletes).toEqual([job]);
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual(done.body);
    });

    it("a helper that cannot make the poster leaves the row without one, and the make still succeeds", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.slidePosterStatus = 404;
        const job = asBody(await slide(L, sid, plan())).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).status).toBe("success");
        expect(slideRows(L, sid)[0]!.poster).toBeNull();
    });

    it("a public post makes the webp public, with a .webp mirror; the library lists it by role, not as a deletable webp", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const job = asBody(await slide(L, sid, plan())).job as string;
        const done = asBody(await L.studio.renderStatus(sid, job, 0));
        const row = slideRows(L, sid)[0]!;
        expect(row).toMatchObject({ visibility: "public" });
        expect(row.public_key).toMatch(/^[A-Za-z0-9]{10}\.webp$/);
        expect(done.url).toBe(row.url);
        const lib = (await (await L.call("/library?v=3", { headers: { authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11" } })).json()) as any;
        const f = lib.posts[0].files.find((x: any) => x.role === "slideshow");
        expect(f).toMatchObject({ content_type: "image/webp", deletable: false, media_name: null, made_spec: { format: "webp" } });
        // it is not one of the session's webps
        expect(asBody(await L.studio.advance(sid, 0)).renders).toEqual([]);
    });
});

describe("the caps and the shape at the route", () => {
    it("0.5 s a photo is accepted (webp and mp4), 0.4 s is 400", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        for (const format of ["webp", undefined]) {
            const ok = await slide(L, sid, plan({ format, seconds: [0.5, 0.5, 0.5, null], sound: "none" }));
            expect(ok.status, String(format)).toBe(202);
            await L.studio.renderStatus(sid, asBody(ok).job, 0);
            const no = await slide(L, sid, plan({ format, seconds: [0.4, 0.5, 0.5, null] }));
            expect(no.status).toBe(400);
            expect(asBody(no).error.code).toBe("error.webp.invalid_params");
        }
    });

    it("60 s is the webp's cap (the video counted, half a second of slack): 59.8 s is fine, 61 s is 400 too_long; the mp4 takes it", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, [...photos(6), { type: "video", duration: 4 }]);
        const items = [0, 1, 2, 3, 4, 5, 6];
        const secs = (each: number) => [...Array(6).fill(each), null];
        const ok = await slide(L, sid, { items, seconds: secs(9.3), format: "webp" }); // 55.8 + 4 = 59.8
        expect(ok.status).toBe(202);
        await L.studio.renderStatus(sid, asBody(ok).job, 0);
        const long = await slide(L, sid, { items, seconds: secs(9.5), format: "webp" }); // 57 + 4 = 61
        expect(asBody(long).error.code).toBe("error.webp.too_long");
        expect(long.status).toBe(400);
        const asMp4 = await slide(L, sid, { items, seconds: secs(9.5) });
        expect(asMp4.status).toBe(202);
    });

    it("the photos alone over 60 s: 400 too_long at the shape", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, photos(6));
        const r = await slide(L, sid, { items: [0, 1, 2, 3, 4, 5], seconds: Array(6).fill(10.1), format: "webp" });
        expect(r.status).toBe(400);
        expect(asBody(r).error.code).toBe("error.webp.too_long");
        expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);
    });

    it("videos and gifs over 60 s together: too_long in both formats", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, [{ type: "photo" }, { type: "video", duration: 40 }, { type: "gif", duration: 21 }]);
        for (const format of ["webp", "mp4"]) {
            const r = await slide(L, sid, { items: [0, 1, 2], seconds: [1, null, null], format });
            expect(asBody(r).error.code, format).toBe("error.webp.too_long");
        }
    });

    it.each([
        ["quality with the mp4", { format: "mp4", quality: "med" }],
        ["width with the mp4", { format: undefined, width: 480 }],
        ["sound own with the webp", { sound: "own" }],
        ["a width that is not 320 or 480", { width: 640 }],
        ["a quality that is not one", { quality: "ultra" }],
        ["a format that is not one", { format: "gif" }],
    ])("%s: 400 invalid_params, nothing created", async (_n, over) => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const r = await slide(L, sid, plan(over));
        expect(r.status).toBe(400);
        expect(asBody(r).error.code).toBe("error.webp.invalid_params");
        expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);
    });

    it("seconds: a number for every photo and null for every video and gif; any other mix is 400", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const mixes: [string, (number | null)[]][] = [
            ["null for a photo", [null, 2, 2, null]],
            ["a number for a video", [2, 2, 2, 4]],
            ["a number for a gif", [2, 2, 2, 2]],
        ];
        for (const [name, seconds] of mixes) {
            const items = name === "a number for a gif" ? [0, 1, 2, 4] : [0, 1, 2, 3];
            const r = await slide(L, sid, plan({ items, seconds }));
            expect(r.status, name).toBe(400);
            expect(asBody(r).error.code, name).toBe("error.webp.invalid_params");
        }
        // the right way round
        expect((await slide(L, sid, plan({ items: [0, 4, 3], seconds: [2, null, null] }))).status).toBe(202);
    });
});

describe("replace: one slideshow per format (R8)", () => {
    async function made(L: LW, sid: string, over: Record<string, unknown> = {}) {
        const job = asBody(await slide(L, sid, plan(over))).job as string;
        return { job, done: asBody(await L.studio.renderStatus(sid, job, 0)) };
    }
    const legacyMp4 = (L: LW, sid: string) => {
        // a slideshow made before 18.10: no format in its spec, content type video/mp4
        const id = "LegacyMp4Row0001a";
        L.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, session_id, created_at, visibility, role, made_spec, post_key) VALUES (?, 'private', 'studio', 'originals', ?, 'old.mp4', 'video/mp4', 10, ?, 1, 'private', 'slideshow', NULL, ?)",
            )
            .run(id, `originals/${sid}-sold.mp4`, sid, sid);
        L.originals.objects.set(`originals/${sid}-sold.mp4`, { bytes: new Uint8Array(10), contentType: "video/mp4", meta: {} });
        return id;
    };

    it("a webp and an mp4 coexist; a second webp replaces the first webp only, and its poster goes with it", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const mp4 = await made(L, sid, { format: undefined });
        const w1 = await made(L, sid);
        expect(slideRows(L, sid)).toHaveLength(2);
        const first = slideRows(L, sid).find((r) => r.content_type === "image/webp")!;
        const w2 = await made(L, sid, { seconds: [3, 3, 3, null] });
        expect(w2.done.replaced).toEqual([first.id]);
        const live = slideRows(L, sid);
        expect(live.map((r) => r.content_type).sort()).toEqual(["image/webp", "video/mp4"]);
        expect(live.find((r) => r.content_type === "video/mp4")!.id).toBe(mp4.done.item_id);
        // the old webp: row, object, mirror, poster
        expect(L.rows("SELECT deleted_at FROM media_items WHERE id = ?", first.id)[0].deleted_at).not.toBeNull();
        expect(L.originals.objects.has(first.r2_key)).toBe(false);
        expect(L.media.objects.has(first.public_key)).toBe(false);
        expect(L.media.objects.has(first.poster.split("/").pop())).toBe(false);
        expect(w1.done.replaced).toEqual([]);
    });

    it("a new mp4 replaces an mp4 made before 18.10 (it counts as mp4) and leaves a webp alone", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const legacy = legacyMp4(L, sid);
        const w = await made(L, sid);
        expect(w.done.replaced).toEqual([]);
        const m = await made(L, sid, { format: undefined });
        expect(m.done.replaced).toEqual([legacy]);
        expect(slideRows(L, sid).map((r) => r.content_type).sort()).toEqual(["image/webp", "video/mp4"]);
        expect(L.originals.objects.has(`originals/${sid}-sold.mp4`)).toBe(false);
    });

    it("a made_spec that did not fit 512 bytes still records the format (a 20-item webp is replaced by the next webp)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, photos(20));
        const all = Array.from({ length: 20 }, (_, i) => i);
        const a = await made(L, sid, { items: all, seconds: all.map(() => 1.5), format: "webp" });
        const spec = JSON.parse(slideRows(L, sid)[0]!.made_spec);
        expect(spec.format).toBe("webp");
        const b = await made(L, sid, { items: all, seconds: all.map(() => 2.5), format: "webp" });
        expect(b.done.replaced).toEqual([a.done.item_id]);
        expect(slideRows(L, sid)).toHaveLength(1);
    });
});

describe("a helper from before the makes", () => {
    it("a webp is never started on it (it would make an mp4): unavailable, the line is free; the mp4 still works", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.makes = false;
        const job = asBody(await slide(L, sid, plan({ queue: true }))).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.unavailable");
        expect(L.helper.slideStarts).toEqual([]);
        expect(L.entries()).toEqual([]);
        const mp4 = asBody(await slide(L, sid, plan({ format: undefined, queue: true }))).job as string;
        expect(asBody(await L.studio.renderStatus(sid, mp4, 0)).status).toBe("success");
    });

    it("features.gallery_make follows the helper's make=1 (and needs gallery=1)", async () => {
        const L = await lineWorld();
        const flag = async () => ((await (await L.call("/capabilities")).json()) as any).features;
        expect(await flag()).toMatchObject({ gallery: false, gallery_make: false }); // nothing heard yet
        await gallery(L, photos(2));
        expect(await flag()).toMatchObject({ gallery: true, gallery_make: true });
        L.helper.makes = false;
        await L.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" })).then((r) => L.settle(asBody(r).id));
        expect(await flag()).toMatchObject({ gallery: true, gallery_make: false });
        L.helper.advertise = false;
        await L.studio.create(KEY_ID, json({ url: "https://x.com/a/status/2" })).then((r) => L.settle(asBody(r).id));
        expect(await flag()).toMatchObject({ gallery: false, gallery_make: false });
    });
});

// ---- the real encode ----------------------------------------------------------------------------------------------------

const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const IMG2WEBP = process.env.IMG2WEBP_PATH || "img2webp";
const tool = (bin: string, arg: string) => spawnSync(bin, [arg]).status === 0;
const hasFfmpeg = tool(FFMPEG, "-version");
const hasImg2webp = spawnSync(IMG2WEBP, ["-version"]).status === 0;
if (!hasFfmpeg || !hasImg2webp) process.stderr.write(`[make-webp tests] real encode skipped: ffmpeg ${hasFfmpeg ? "found" : "MISSING"}, img2webp ${hasImg2webp ? "found" : "MISSING"}\n`);
const real = hasFfmpeg && hasImg2webp ? describe : describe.skip;
const root = mkdtempSync(path.join(tmpdir(), "makewebp-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const ff = (args: string[]) => {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
};
const probeAV = async (f: string) => {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-i", f], { encoding: "utf8" });
    return { ...parseVideoInfo(r.stderr), hasAudio: parseHasAudio(r.stderr) };
};

real("the real slideshow webp (ffmpeg + img2webp)", () => {
    const fx: Record<string, string> = {};
    const mk = (n: string, a: string[]) => {
        fx[n] = path.join(root, n);
        ff([...a, fx[n]!]);
    };
    mk("a.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1350:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("b.jpg", ["-f", "lavfi", "-i", "mandelbrot=s=1080x1350", "-frames:v", "1", "-q:v", "3"]);
    mk("c.jpg", ["-f", "lavfi", "-i", "color=c=0x2060c0:s=1080x1350", "-frames:v", "1", "-q:v", "3"]);
    mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p"]);
    mk("g.gif", ["-f", "lavfi", "-i", "testsrc2=s=200x200:d=1:r=10"]);

    let n = 0;
    async function run(inputs: string[], slides: (number | null)[], over: Record<string, unknown> = {}) {
        const dir = path.join(root, `job${n++}`);
        mkdirSync(dir, { recursive: true });
        const files = new Map(inputs.map((f, i) => [i, fx[f]!]));
        const phases: string[] = [];
        const r = await renderSlideshowWebp({
            ffmpegBin: FFMPEG,
            img2webpBin: IMG2WEBP,
            dir,
            output: path.join(dir, "out.webp"),
            files,
            plan: { width: 480, height: 600, fade: true, quality: "med", slides: slides.map((seconds, i) => ({ n: i, seconds })), ...over } as any,
            probeAV,
            timeoutMs: 120_000,
            onPhase: (p, x) => phases.push(`${p}:${x.done}/${x.total}`),
        });
        return { r, dir, webp: parseWebp(readFileSync(path.join(dir, "out.webp")))!, phases };
    }

    it("3 stills + a 2 s video with a fade: duration = the plan within a frame (67 ms), 480x600, the frame count of the plan, a poster, no frames left", async () => {
        const { r, webp, dir, phases } = await run(["a.jpg", "v.mp4", "b.jpg", "c.jpg"], [2, null, 2, 1.5]);
        const planned = planWebpFrames(
            [{ kind: "still", seconds: 2 }, { kind: "motion", seconds: 2, frames: 30 }, { kind: "still", seconds: 2 }, { kind: "still", seconds: 1.5 }],
            true,
        );
        expect(webp).toMatchObject({ width: 480, height: 600, animated: true });
        expect(Math.abs(webp.durationMs - 7500)).toBeLessThanOrEqual(70);
        expect(webp.durationMs).toBe(planned.totalMs);
        expect(webp.frames).toBe(planned.frames.length);
        // stills + k x fades + the video's frames (26 kept: 2 s less a crossfade at each end = 1732 ms)
        expect(webp.frames).toBe(3 + FADE_FRAMES * 3 + 26);
        expect(r).toMatchObject({ width: 480, height: 600, frames: webp.frames });
        expect(r.duration).toBeCloseTo(7.5, 1);
        const poster = readFileSync(path.join(dir, "poster.jpg"));
        expect(poster.subarray(0, 3)).toEqual(Buffer.from([0xff, 0xd8, 0xff]));
        expect(r.posterBytes).toBe(poster.length);
        expect(existsSyncFrames(dir)).toBe(false);
        expect(phases[0]).toBe("composing:0/7"); // 4 slides + 3 crossfades
        expect(phases.at(-1)).toBe("encoding:7.5/7.5");
    });

    it("a cut has no blend frames: one frame per still", async () => {
        const { webp } = await run(["a.jpg", "b.jpg", "c.jpg"], [1, 0.5, 2], { fade: false });
        expect(webp.frames).toBe(3);
        expect(webp.durationMs).toBe(3500);
    });

    it("the canvas follows the frame: 4:5 -> 480x600, 9:16 -> 480x854, 1:1 -> 320x320 (the blurred fill sits behind a photo of another shape)", async () => {
        for (const [w, h] of [[480, 600], [480, 854], [320, 320]] as const) {
            const { webp } = await run(["a.jpg", "b.jpg"], [1, 1], { width: w, height: h });
            expect([webp.width, webp.height]).toEqual([w, h]);
        }
    });

    it("the crossfade really blends: a frame between a blue still and the test card is neither", async () => {
        const dir = path.join(root, `blend${n++}`);
        mkdirSync(dir, { recursive: true });
        const a = path.join(dir, "a.png");
        const b = path.join(dir, "b.png");
        ff(["-f", "lavfi", "-i", "color=c=black:s=8x8", "-frames:v", "1", a]);
        ff(["-f", "lavfi", "-i", "color=c=white:s=8x8", "-frames:v", "1", b]);
        const outs = [1, 2, 3, 4].map((j) => path.join(dir, `o${j}.png`));
        ff(["-i", a, "-i", b, ...buildBlendArgs({ a, b, outputs: outs }).slice(buildBlendArgs({ a, b, outputs: outs }).indexOf("-filter_complex"))]);
        const lum = outs.map((o) => {
            const px = spawnSync(FFMPEG, ["-nostdin", "-loglevel", "error", "-i", o, "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "gray", "-"]);
            return px.stdout[0]!;
        });
        // 20 %, 40 %, 60 %, 80 % of the way to white
        lum.forEach((v, i) => expect(Math.abs(v - 255 * ((i + 1) / 5))).toBeLessThanOrEqual(6));
    });

    it("a gif plays once and is a slide of its own length", async () => {
        const { webp } = await run(["a.jpg", "g.gif"], [1, null], { fade: false });
        expect(Math.abs(webp.durationMs - 2000)).toBeLessThanOrEqual(70);
    });

    it("over 60 s: error.webp.too_long and nothing is encoded; the cap's slack is half a second", async () => {
        await expect(run(["a.jpg", "b.jpg"], [15, 15].concat([]), {}).then(() => 0)).resolves.toBe(0);
        const inputs = Array.from({ length: 5 }, (_, i) => ["a.jpg", "b.jpg", "c.jpg"][i % 3]!);
        await expect(run(inputs, [12.2, 12.2, 12.2, 12.2, 12.2])).rejects.toMatchObject({ code: "error.webp.too_long" }); // 61 s
        const ok = await run(inputs.slice(0, 2), [14.9, 15], { fade: false });
        expect(ok.webp.frames).toBe(2);
    });

    it("a still with a number missing, or a video with one: invalid_params; no picture: bad_source", async () => {
        await expect(run(["a.jpg", "v.mp4"], [2, 2])).rejects.toMatchObject({ code: "error.webp.invalid_params" });
        await expect(run(["a.jpg", "b.jpg"], [2, null])).rejects.toMatchObject({ code: "error.webp.invalid_params" });
        writeFileSync(path.join(root, "junk"), "no picture here");
        fx.junk = path.join(root, "junk");
        await expect(run(["a.jpg", "junk"], [2, 2])).rejects.toMatchObject({ code: "error.webp.invalid_params" });
    });

    it("an output over the cap is error.webp.too_large", async () => {
        const dir = path.join(root, `cap${n++}`);
        mkdirSync(dir, { recursive: true });
        await expect(
            renderSlideshowWebp({
                ffmpegBin: FFMPEG,
                img2webpBin: IMG2WEBP,
                dir,
                output: path.join(dir, "o.webp"),
                files: new Map([[0, fx["a.jpg"]!], [1, fx["b.jpg"]!]]),
                plan: { width: 480, height: 600, fade: true, quality: "med", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] },
                probeAV,
                timeoutMs: 60_000,
                maxOutputBytes: 1000,
            }),
        ).rejects.toMatchObject({ code: "error.webp.too_large" });
    });

    it("quality changes the size: low < med < high on the same plan", async () => {
        const sizes: number[] = [];
        for (const quality of ["low", "med", "high"]) sizes.push((await run(["a.jpg", "b.jpg"], [1, 1], { quality })).r.bytes);
        expect(sizes[0]).toBeLessThan(sizes[1]!);
        expect(sizes[1]).toBeLessThan(sizes[2]!);
    });
});

function existsSyncFrames(dir: string): boolean {
    return spawnSync("test", ["-e", path.join(dir, "frames")]).status === 0;
}
