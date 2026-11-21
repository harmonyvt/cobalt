// The 7TV emote fit (APP-API-CONTRACT.md 57.10): the pure planning pieces, then the real ffmpeg + img2webp run, both
// through fitEmote and through the helper's POST /emote-fit. The real part is skipped when either tool is missing.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { encodePngRgba, fitEmote, gifDelays, planFit, thinFrames, thinToRate } from "../helper/emote-fit.js";
import { createHelper } from "../helper/server.js";
import { parseWebpAnim } from "../helper/webp-anim.js";

describe("planning", () => {
    it("shrinks to 512 by default, never enlarges, caps at 1000", () => {
        expect(planFit({ width: 1600, height: 900 })).toEqual({ crop: { x: 0, y: 0, w: 1600, h: 900 }, width: 512, height: 288 });
        expect(planFit({ width: 200, height: 100 })).toMatchObject({ width: 200, height: 100 });
        expect(planFit({ width: 3000, height: 3000, size: 5000 })).toMatchObject({ width: 1000, height: 1000 });
        expect(planFit({ width: 400, height: 400, size: 128 })).toMatchObject({ width: 128, height: 128 });
    });

    it("cuts the crop box in pixels; the shape must suit 7TV", () => {
        expect(planFit({ width: 1600, height: 900, crop: { x: 0.25, y: 0, w: 0.5, h: 1 } })).toEqual({
            crop: { x: 400, y: 0, w: 800, h: 900 },
            width: 455,
            height: 512,
        });
        expect(() => planFit({ width: 1600, height: 100 })).toThrow(expect.objectContaining({ code: "error.seventv.fit_shape" }));
        expect(() => planFit({ width: 100, height: 100, crop: { x: 1, y: 1, w: 0.5, h: 0.5 } })).toThrow(
            expect.objectContaining({ code: "error.seventv.fit_shape" }),
        );
    });

    it("thins frames evenly and keeps the loop's length", () => {
        expect(thinFrames([10, 20, 30], 5)).toEqual([
            { index: 0, duration: 10 },
            { index: 1, duration: 20 },
            { index: 2, duration: 30 },
        ]);
        const many = thinFrames(Array.from({ length: 2500 }, () => 40), 1000);
        expect(many).toHaveLength(1000);
        expect(many.reduce((t, f) => t + f.duration, 0)).toBe(2500 * 40);
    });

    it("squashes after the crop: the shape check and the size cap see the stretched box (71.3)", () => {
        expect(planFit({ width: 1000, height: 1000, stretch: { w: 2, h: 1 } })).toMatchObject({ width: 512, height: 256 });
        expect(planFit({ width: 100, height: 100, stretch: { w: 3, h: 1 } })).toMatchObject({ width: 300, height: 100 });
        expect(planFit({ width: 1000, height: 1000, crop: { x: 0, y: 0, w: 1, h: 0.5 }, stretch: { w: 1, h: 2 } })).toMatchObject({ width: 512, height: 512 });
        // a picture too wide for 7TV is mended by squashing it back
        expect(planFit({ width: 1000, height: 100, stretch: { w: 0.25, h: 1 } })).toMatchObject({ width: 250, height: 100 });
        expect(() => planFit({ width: 400, height: 100, stretch: { w: 1, h: 0.25 } })).toThrow(expect.objectContaining({ code: "error.seventv.fit_shape" }));
    });

    it("thins to a frame rate and keeps the loop's length", () => {
        const fifty = Array.from({ length: 50 }, () => 20);
        const kept = thinToRate(fifty, 20);
        expect(kept).toHaveLength(20);
        expect(kept.reduce((t, f) => t + f.duration, 0)).toBe(1000);
        expect(thinToRate([100, 100, 100], 20)).toHaveLength(3);
        expect(thinToRate([20, 20, 20, 20, 20, 20], 20).map((f) => f.index)).toEqual([0, 3, 5]);
    });

    it("reads a gif's frame delays", () => {
        // 1x1 gif, two frames with GCE delays 5 and 0 (0 reads as 100 ms)
        const frame = (delay: number) => [0x21, 0xf9, 4, 0, delay, 0, 0, 0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0];
        const gif = Buffer.from([...Buffer.from("GIF89a"), 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255, ...frame(5), ...frame(0), 0x3b]);
        expect(gifDelays(gif)).toEqual([50, 100]);
        expect(gifDelays(Buffer.from("nope"))).toBeNull();
    });
});

const has = (bin: string, arg: string) => spawnSync(bin, [arg], { stdio: "ignore" }).status !== null;
const real = has("ffmpeg", "-version") && has("img2webp", "-version") ? describe : describe.skip;

real("the real fit (ffmpeg + img2webp)", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "emote-fit-"));
    afterAll(() => rmSync(dir, { recursive: true, force: true }));
    const gif = path.join(dir, "big.gif");
    spawnSync("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1600x900:r=20:d=2", gif]);
    // an animated webp made by img2webp from two PNGs, 1200x1200, 70 ms frames, with transparency
    const png = (rgba: number[]) => encodePngRgba(1200, 1200, new Uint8Array(Array.from({ length: 1200 * 1200 }, () => rgba).flat()));
    const a = path.join(dir, "a.png"), b = path.join(dir, "b.png"), webp = path.join(dir, "anim.webp");
    writeFileSync(a, png([255, 0, 0, 255]));
    writeFileSync(b, png([0, 0, 255, 128]));
    spawnSync("img2webp", ["-loop", "0", "-lossy", "-d", "70", a, b, "-o", webp]);

    it("fits a 1600x900 gif with a crop box, keeping frames and timing", async () => {
        const r = await fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: gif, dir: path.join(dir, "w1"), crop: { x: 0.25, y: 0, w: 0.5, h: 1 }, maxBytes: 7 * 1024 * 1024 });
        expect(r).toMatchObject({ width: 455, height: 512, frames: 40 });
        const info = parseWebpAnim(r.bytes);
        expect(info).toMatchObject({ animated: true, width: 455, height: 512 });
        expect((info as any).frames[0].duration).toBe(50);
    });

    it("composes an animated webp (which ffmpeg cannot read) and shrinks it", async () => {
        const r = await fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: webp, dir: path.join(dir, "w2"), size: 256, maxBytes: 7 * 1024 * 1024 });
        expect(r).toMatchObject({ width: 256, height: 256, frames: 2 });
        const info = parseWebpAnim(r.bytes) as any;
        expect(info.frames.map((f: any) => f.duration)).toEqual([70, 70]);
    });

    it("webp: stretch, bounce, a fixed quality as one encode, fps thinning (71.3)", async () => {
        const r = await fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: gif, dir: path.join(dir, "w5"), stretch: { w: 0.5, h: 1 }, size: 200, fps: 10, bounce: true, quality: 40, maxBytes: 7 * 1024 * 1024 });
        // 1600x900 stretched to 800x900, longest side 200; 20 fps thinned to 10: 20 frames, bounced to 38
        expect(r).toMatchObject({ format: "webp", width: 178, height: 200, frames: 38, quality: 40, overCap: false });
        const info = parseWebpAnim(r.bytes) as any;
        expect(info.frames).toHaveLength(38);
        expect(info.frames[0].duration).toBe(100);
        const over = await fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: gif, dir: path.join(dir, "w6"), quality: 90, maxBytes: 2048 });
        expect(over.overCap).toBe(true);
    }, 60_000);

    it("steps the quality down to meet the byte cap, and says so when it cannot", async () => {
        const r = await fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: gif, dir: path.join(dir, "w3"), maxBytes: 150 * 1024 });
        expect(r.bytes.length).toBeLessThanOrEqual(150 * 1024);
        await expect(fitEmote({ ffmpeg: "ffmpeg", img2webp: "img2webp", input: gif, dir: path.join(dir, "w4"), maxBytes: 2048 })).rejects.toMatchObject({
            code: "error.seventv.fit_too_big",
        });
    }, 60_000);

    it("POST /emote-fit answers the webp and its size headers", async () => {
        const KEY = "k";
        const helper: any = createHelper({ internalKey: KEY, aboutDir: path.join(dir, "about"), workDir: path.join(dir, "work"), fetchDir: path.join(dir, "fetch"), probeDir: path.join(dir, "probe"), waitForCobalt: async () => {}, ffmpegPath: () => "ffmpeg", img2webpPath: () => "img2webp" });
        await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
        const base = `http://127.0.0.1:${helper.server.address().port}`;
        try {
            const body = readFileSync(gif);
            const ok = await fetch(`${base}/emote-fit?size=128&max_bytes=${7 * 1024 * 1024}`, { method: "POST", headers: { "x-internal-key": KEY }, body });
            expect(ok.status).toBe(200);
            expect(ok.headers.get("content-type")).toBe("image/webp");
            expect([ok.headers.get("x-emote-width"), ok.headers.get("x-emote-height"), ok.headers.get("x-emote-frames")]).toEqual(["128", "72", "40"]);
            expect(parseWebpAnim(Buffer.from(await ok.arrayBuffer()))).toMatchObject({ width: 128, height: 72 });
            const wide = await fetch(`${base}/emote-fit?crop=0,0,1,0.1&max_bytes=100000`, { method: "POST", headers: { "x-internal-key": KEY }, body });
            expect(wide.status).toBe(400);
            expect(((await wide.json()) as any).error.code).toBe("error.seventv.fit_shape");
            // a refusal answers before the body is read (and closes the socket), so send a small one: a 2 MB body hits EPIPE
            const bad = await fetch(`${base}/emote-fit?size=5&max_bytes=100000`, { method: "POST", headers: { "x-internal-key": KEY }, body: "x" });
            expect(bad.status).toBe(400);
        } finally {
            await helper.close();
        }
    }, 60_000);
});

// gif, png and video need ffmpeg alone
const ffmpegOnly = has("ffmpeg", "-version") ? describe : describe.skip;

ffmpegOnly("the editor's formats and video (71.3), ffmpeg alone", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "emote-make-"));
    afterAll(() => rmSync(dir, { recursive: true, force: true }));
    const src = path.join(dir, "src.gif");
    spawnSync("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=400x300:r=25:d=2", src]);
    const video = path.join(dir, "clip.mp4");
    spawnSync("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=6", "-pix_fmt", "yuv420p", video]);
    const base = { ffmpeg: "ffmpeg", img2webp: "img2webp", maxBytes: 7 * 1024 * 1024 };
    const gifInfo = (b: Buffer) => {
        const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
        return { w: v.getUint16(6, true), h: v.getUint16(8, true), delays: gifDelays(b)! };
    };

    it("makes a stretched gif that keeps its frames and timing", async () => {
        const r = await fitEmote({ ...base, input: src, dir: path.join(dir, "g1"), format: "gif", stretch: { w: 0.5, h: 1 } });
        expect(r).toMatchObject({ format: "gif", width: 200, height: 300, frames: 50, durationMs: 2000, overCap: false });
        expect(r.bytes.subarray(0, 3).toString()).toBe("GIF");
        const g = gifInfo(r.bytes);
        expect([g.w, g.h, g.delays.length]).toEqual([200, 300, 50]);
        expect(g.delays.reduce((a, b) => a + b, 0)).toBe(2000);
    });

    it("thins the frame rate without changing the loop length, and bounces without repeating the ends", async () => {
        const thin = await fitEmote({ ...base, input: src, dir: path.join(dir, "g2"), format: "gif", fps: 10, size: 100 });
        expect(thin.frames).toBe(20);
        expect(thin.durationMs).toBe(2000);
        const b = await fitEmote({ ...base, input: src, dir: path.join(dir, "g3"), format: "gif", fps: 5, size: 100, bounce: true });
        // 10 frames forward, then 8 back (the end frames once)
        expect(b.frames).toBe(18);
        expect(b.durationMs).toBe(3600);
        expect(gifInfo(b.bytes).delays).toHaveLength(18);
    });

    it("a fixed quality is one encode: over the cap it says so instead of failing; auto steps down or fails", async () => {
        const fixed = await fitEmote({ ...base, input: src, dir: path.join(dir, "g4"), format: "gif", quality: 100, maxBytes: 2048 });
        expect(fixed).toMatchObject({ overCap: true, quality: 100 });
        const small = await fitEmote({ ...base, input: src, dir: path.join(dir, "g5"), format: "gif", quality: 10, size: 64 });
        expect(small).toMatchObject({ overCap: false, quality: 10 });
        await expect(fitEmote({ ...base, input: src, dir: path.join(dir, "g6"), format: "gif", maxBytes: 2048 })).rejects.toMatchObject({ code: "error.seventv.fit_too_big" });
    }, 60_000);

    it("makes a png of the frame at the asked second", async () => {
        const a = await fitEmote({ ...base, input: src, dir: path.join(dir, "p1"), format: "png", size: 200, frame: 1.5 });
        expect(a).toMatchObject({ format: "png", frames: 1, width: 200, height: 150 });
        expect(a.bytes.subarray(1, 4).toString()).toBe("PNG");
        const first = await fitEmote({ ...base, input: src, dir: path.join(dir, "p2"), format: "png", size: 200 });
        expect(Buffer.compare(a.bytes, first.bytes)).not.toBe(0);
    });

    it("reads a video moment at a frame rate, durations summing to the moment", async () => {
        const r = await fitEmote({ ...base, input: video, dir: path.join(dir, "v1"), format: "gif", video: true, start: 1, end: 3, fps: 10, size: 120 });
        expect(r).toMatchObject({ format: "gif", frames: 20, durationMs: 2000, width: 120, height: 90 });
        const dflt = await fitEmote({ ...base, input: video, dir: path.join(dir, "v2"), format: "gif", video: true, size: 64 });
        expect(dflt).toMatchObject({ frames: 60, durationMs: 3000 }); // 0 to 3 s at 20 fps
        const still = await fitEmote({ ...base, input: video, dir: path.join(dir, "v3"), format: "png", video: true, frame: 2, size: 160 });
        expect(still).toMatchObject({ format: "png", frames: 1, width: 160, height: 120 });
        await expect(fitEmote({ ...base, input: video, dir: path.join(dir, "v4"), format: "gif", video: true, start: 50, end: 52 })).rejects.toMatchObject({ code: "error.seventv.fit_failed" });
    }, 60_000);

    it("POST /emote-fit takes the new fields and answers format, duration and over-cap headers", async () => {
        const KEY = "k";
        const helper: any = createHelper({ internalKey: KEY, aboutDir: path.join(dir, "about"), workDir: path.join(dir, "work"), fetchDir: path.join(dir, "fetch"), probeDir: path.join(dir, "probe"), waitForCobalt: async () => {}, ffmpegPath: () => "ffmpeg", img2webpPath: () => "img2webp" });
        await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
        const base = `http://127.0.0.1:${helper.server.address().port}`;
        const post = (qs: string, body: Buffer | string) => fetch(`${base}/emote-fit?${qs}`, { method: "POST", headers: { "x-internal-key": KEY }, body });
        try {
            const gif = await post(`format=gif&stretch=0.5,1&size=100&max_bytes=${7 * 1024 * 1024}&type=image/gif&bounce=1&fps=5`, readFileSync(src));
            expect(gif.status).toBe(200);
            expect(gif.headers.get("content-type")).toBe("image/gif");
            expect([gif.headers.get("x-emote-format"), gif.headers.get("x-emote-over-cap"), gif.headers.get("x-emote-frames"), gif.headers.get("x-emote-duration")]).toEqual(["gif", "0", "18", "3600"]);
            expect([gif.headers.get("x-emote-width"), gif.headers.get("x-emote-height")]).toEqual(["67", "100"]);
            const over = await post(`format=gif&quality=100&max_bytes=2048&type=image/gif`, readFileSync(src));
            expect(over.status).toBe(200);
            expect(over.headers.get("x-emote-over-cap")).toBe("1");
            const vid = await post(`format=png&type=video/mp4&frame=1&size=64&max_bytes=${7 * 1024 * 1024}`, readFileSync(video));
            expect(vid.status).toBe(200);
            expect(vid.headers.get("content-type")).toBe("image/png");
            for (const bad of ["stretch=5,1", "format=bmp", "quality=0", "fps=4", "type=video/mp4&start=1&end=1.1", "type=video/mp4&start=0&end=11", "frame=-1"]) {
                const r = await post(`${bad}&max_bytes=100000`, "x");
                expect([bad, r.status]).toEqual([bad, 400]);
            }
        } finally {
            await helper.close();
        }
    }, 60_000);
});
