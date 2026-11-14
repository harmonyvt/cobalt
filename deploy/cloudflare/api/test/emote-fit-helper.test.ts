// The 7TV emote fit (APP-API-CONTRACT.md 57.10): the pure planning pieces, then the real ffmpeg + img2webp run, both
// through fitEmote and through the helper's POST /emote-fit. The real part is skipped when either tool is missing.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { encodePngRgba, fitEmote, gifDelays, planFit, thinFrames } from "../helper/emote-fit.js";
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
            const bad = await fetch(`${base}/emote-fit?size=5&max_bytes=100000`, { method: "POST", headers: { "x-internal-key": KEY }, body });
            expect(bad.status).toBe(400);
        } finally {
            await helper.close();
        }
    }, 60_000);
});
