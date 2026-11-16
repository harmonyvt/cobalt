// Section 63: the Worker's GIF decoder and canvas drawing, checked against Pillow's own decoding of the same files.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { decodeGif, gifInfo, GifError, spreadFrames } from "../src/gif";
import { blank, drawText, fitSize, paste, pasteFit, resize, textWidth } from "../src/canvas-draw";
import { decodePng, encodePng } from "../src/cutout-core";

const fixture = (n: string) => new Uint8Array(readFileSync(new URL(`./fixtures/${n}`, import.meta.url)));

describe("decodeGif", () => {
    it("composes every frame like Pillow does", () => {
        const want = JSON.parse(readFileSync(new URL("./fixtures/anim-gif-expected.json", import.meta.url), "utf8")) as { pts: [number, number][]; frames: number[][][] };
        const g = decodeGif(fixture("anim.gif"));
        expect(g.count).toBe(4);
        expect(g.frames.map((f) => f.delay)).toEqual([50, 60, 70, 80]);
        g.frames.forEach((f, i) => {
            want.pts.forEach(([x, y], k) => {
                const p = (y * f.image.width + x) * 4;
                const got = [...f.image.data.subarray(p, p + 4)];
                const exp = want.frames[i]![k]!;
                if (exp[3] === 0) expect(got[3]).toBe(0);
                else expect(got).toEqual(exp);
            });
        });
    });
    it("keeps only the frames asked for", () => {
        const g = decodeGif(fixture("anim.gif"), { want: [0, 2] });
        expect(g.frames).toHaveLength(2);
        expect([...g.frames[1]!.image.data.subarray((5 * 40 + 15) * 4, (5 * 40 + 15) * 4 + 3)]).toEqual([0, 0, 255]);
    });
    it("reads an interlaced still and refuses junk or too much work", () => {
        const s = decodeGif(fixture("still.gif"));
        expect(s.count).toBe(1);
        expect([...s.frames[0]!.image.data.subarray((16 * 33 + 32) * 4, (16 * 33 + 32) * 4 + 4)]).toEqual([10, 20, 30, 255]);
        expect(gifInfo(fixture("anim.gif"))).toEqual({ width: 40, height: 30, frames: 4 });
        expect(() => decodeGif(new Uint8Array([1, 2, 3]))).toThrow(GifError);
        expect(() => decodeGif(fixture("anim.gif"), { maxPixels: 100 })).toThrow(GifError);
    });
    it("decodes the repo's real clip.gif", () => {
        const g = decodeGif(fixture("clip.gif"), { want: [0] });
        expect(g.frames[0]!.image.width).toBeGreaterThan(0);
        expect(g.count).toBeGreaterThan(1);
    });
});

describe("spreadFrames", () => {
    it("starts at 0 and spreads", () => {
        expect(spreadFrames(30, 3)).toEqual([0, 10, 20]);
        expect(spreadFrames(2, 3)).toEqual([0, 1]);
        expect(spreadFrames(1, 3)).toEqual([0]);
        expect(spreadFrames(0, 3)).toEqual([]);
    });
});

describe("canvas drawing", () => {
    it("scales, pastes and writes text into a PNG that decodes back", async () => {
        const c = blank(200, 60, [72, 72, 72]);
        const red = blank(100, 50, [255, 0, 0]);
        expect(fitSize(100, 50, 40, 40)).toEqual({ width: 40, height: 20 });
        expect(resize(red, 10, 5).data.subarray(0, 4)).toEqual(new Uint8Array([255, 0, 0, 255]));
        pasteFit(c, red, 0, 0, 40, 40);
        paste(c, blank(5, 5, [0, 0, 255]), 195, 55);
        drawText(c, "LaPeace 12", 50, 10, [255, 255, 255]);
        expect(textWidth("ab")).toBe(16);
        const back = await decodePng(await encodePng(c));
        const px = (x: number, y: number) => [...back.data.subarray((y * 200 + x) * 4, (y * 200 + x) * 4 + 3)];
        expect(px(20, 15)).toEqual([255, 0, 0]);
        expect(px(197, 57)).toEqual([0, 0, 255]);
        // some text pixels turned light
        let light = 0;
        for (let y = 10; y < 27; y++) for (let x = 50; x < 130; x++) if (px(x, y)[0]! > 200) light++;
        expect(light).toBeGreaterThan(40);
    });
});

describe("drawing at fractional places", () => {
    it("rounds to whole pixels instead of shifting by part of a row", () => {
        const c = blank(100, 40, [0, 0, 0]);
        drawText(c, "I", 10, 10.5, [255, 255, 255]);
        let minX = Infinity;
        for (let i = 0; i < 100 * 40; i++) if (c.data[i * 4]! > 0) minX = Math.min(minX, i % 100);
        expect(minX).toBeGreaterThanOrEqual(10);
        expect(minX).toBeLessThan(18);
    });
});

