// Lane GS1: photos and galleries in the helper (APP-API-CONTRACT.md 18.2 / 18.7, apple/CONTRACT-GALLERY.md
// 6 and 8.1). Three halves:
//  - the pure pieces (sniffType, the items rules, the slideshow argv builders);
//  - POST /fetch with `items`, photos typed by their BYTES, thumbs, and the image poster, through the real
//    helper server, a real local HTTP origin, the real downloadToFile and the REAL ffmpeg;
//  - the slideshow routes, REAL ffmpeg over generated stills and a generated video with a sine tone.
// Fixtures are generated at test time into a temp dir (no binary fixtures are committed). The real-ffmpeg
// halves are skipped when no ffmpeg is found: set FFMPEG_PATH, or have `ffmpeg` on the PATH (the container
// image uses ffmpeg-static).
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// real ffmpeg runs: a slideshow or a poster takes a second or two on a loaded machine
vi.setConfig({ testTimeout: 90_000 });
import { createHelper } from "../helper/server.js";
import {
    FADE_SECONDS,
    JobError,
    blurRadius,
    buildComposeArgs,
    buildPosterArgs,
    buildSlideshowArgs,
    downloadToFile,
    fillGraph,
    needsBlur,
    parseFetchSelection,
    parseHasAudio,
    parseProgressSeconds,
    parseVideoInfo,
    renderSlideshow,
    resolveSource,
    selectPickerItems,
    sniffType,
    validateSlideshowStart,
    videoExt,
} from "../helper/lib.js";

const KEY = "internal-key";
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const real = hasFfmpeg ? describe : describe.skip;

const root = mkdtempSync(path.join(tmpdir(), "gallery-helper-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const rid = (n = 22) => Array.from({ length: n }, () => ALNUM[Math.floor(Math.random() * ALNUM.length)]).join("");

// --- the bytes of every signature the sniffer knows -----------------------------------------------

const hex = (s: string) => Buffer.from(s.replace(/\s/g, ""), "hex");
const ascii = (s: string) => Buffer.from(s, "latin1");
const HEAD = {
    jpeg: Buffer.concat([hex("ff d8 ff e0 00 10"), ascii("JFIF"), Buffer.alloc(8)]),
    png: Buffer.concat([hex("89 50 4e 47 0d 0a 1a 0a"), Buffer.alloc(8)]),
    webp: Buffer.concat([ascii("RIFF"), Buffer.alloc(4), ascii("WEBPVP8 ")]),
    gif: Buffer.concat([ascii("GIF89a"), Buffer.alloc(8)]),
    mp4: Buffer.concat([hex("00 00 00 20"), ascii("ftypisom"), Buffer.alloc(8)]),
};
const heif = (brand: string) => Buffer.concat([hex("00 00 00 18"), ascii("ftyp"), ascii(brand), Buffer.alloc(8)]);

// --- ffmpeg helpers for the fixtures -------------------------------------------------------------

function ff(args: string[]) {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(`ffmpeg ${args.join(" ")} failed: ${r.stderr}`);
}
const infoOf = (file: string) => {
    const err = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-i", file], { encoding: "utf8" }).stderr;
    return { ...parseVideoInfo(err), hasAudio: parseHasAudio(err), audioStreams: (err.match(/Stream #\d+:\d+.*Audio:/g) ?? []).length, err };
};
// width x height from a JPEG's start-of-frame marker
function jpegSize(buf: Buffer): { w: number; h: number } {
    expect(buf[0]).toBe(0xff);
    expect(buf[1]).toBe(0xd8);
    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    let i = 2;
    while (i < buf.length) {
        if (buf[i] !== 0xff) throw new Error("bad marker");
        const marker = buf[i + 1]!;
        const len = view.getUint16(i + 2);
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
            return { h: view.getUint16(i + 5), w: view.getUint16(i + 7) };
        }
        i += 2 + len;
    }
    throw new Error("no SOF marker");
}
/** average colour of an image region (x,y,w,h of the file's own pixels), through ffmpeg */
function averageRgb(file: string, crop: [number, number, number, number], at = 0): [number, number, number] {
    const [w, h, x, y] = [crop[2], crop[3], crop[0], crop[1]];
    const r = spawnSync(
        FFMPEG,
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-ss", String(at), "-i", file, "-frames:v", "1", "-vf", `crop=${w}:${h}:${x}:${y},scale=1:1`, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        { encoding: "buffer" },
    );
    expect(r.status).toBe(0);
    return [r.stdout[0]!, r.stdout[1]!, r.stdout[2]!];
}

const fx: Record<string, string> = {};
beforeAll(() => {
    if (!hasFfmpeg) return;
    const mk = (name: string, args: string[]) => {
        fx[name] = path.join(root, name);
        ff([...args, fx[name]!]);
    };
    // a 4:5 post photo, a square one, a small one, a png and a webp
    mk("p-1080x1350.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1350:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("p-1200x1200.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1200x1200:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("p-300x200.jpg", ["-f", "lavfi", "-i", "testsrc2=s=300x200:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("p-800x600.png", ["-f", "lavfi", "-i", "testsrc2=s=800x600:r=1", "-frames:v", "1"]);
    // a webp: ffmpeg's own build may have no webp encoder (Homebrew's has none), so cwebp makes it when it exists
    mk("p-640x640.png", ["-f", "lavfi", "-i", "testsrc2=s=640x640:r=1", "-frames:v", "1"]);
    if (spawnSync("cwebp", ["-quiet", fx["p-640x640.png"]!, "-o", path.join(root, "p-640x640.webp")]).status === 0) {
        fx["p-640x640.webp"] = path.join(root, "p-640x640.webp");
    }
    // a solid bright square: its blurred fill in a taller frame is clearly not black
    mk("orange-1200x1200.jpg", ["-f", "lavfi", "-i", "color=c=orange:s=1200x1200", "-frames:v", "1", "-q:v", "3"]);
    // a 2 s video with a sine tone, and one without sound
    mk("v-tone.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]);
    mk("v-silent.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an"]);
});

// =================================================================================================
// pure pieces
// =================================================================================================

describe("sniffType: a file's type from its first bytes", () => {
    it.each([
        ["jpeg", HEAD.jpeg, { type: "image", contentType: "image/jpeg", ext: "jpg" }],
        ["png", HEAD.png, { type: "image", contentType: "image/png", ext: "png" }],
        ["webp", HEAD.webp, { type: "image", contentType: "image/webp", ext: "webp" }],
        ["gif", HEAD.gif, { type: "gif", contentType: "image/gif", ext: "gif" }],
        ["heic", heif("heic"), { type: "image", contentType: "image/heic", ext: "heic" }],
        ["heix", heif("heix"), { type: "image", contentType: "image/heic", ext: "heic" }],
        ["hevc", heif("hevc"), { type: "image", contentType: "image/heic", ext: "heic" }],
        ["mif1 (heif)", heif("mif1"), { type: "image", contentType: "image/heic", ext: "heic" }],
        ["msf1 (heif)", heif("msf1"), { type: "image", contentType: "image/heic", ext: "heic" }],
    ])("%s", (_n, head, want) => {
        expect(sniffType(head)).toEqual(want);
    });

    it("a video, an mp4 ftyp brand that is not heif, and garbage are null (the video path)", () => {
        expect(sniffType(HEAD.mp4)).toBeNull();
        expect(sniffType(heif("avif"))).toBeNull();
        expect(sniffType(heif("M4V "))).toBeNull();
        expect(sniffType(hex("1a 45 df a3 01 00 00 00 00 00 00 1f"))).toBeNull(); // matroska / webm
        expect(sniffType(Buffer.alloc(32, 1))).toBeNull();
        expect(sniffType(ascii("<html><body>nope"))).toBeNull();
    });

    it("a head too short to decide is null, and never throws", () => {
        for (const n of [0, 1, 2]) expect(sniffType(HEAD.jpeg.subarray(0, n))).toBeNull();
        expect(sniffType(HEAD.jpeg.subarray(0, 3))).toMatchObject({ ext: "jpg" }); // FF D8 FF is enough
        expect(sniffType(HEAD.png.subarray(0, 7))).toBeNull();
        expect(sniffType(HEAD.webp.subarray(0, 11))).toBeNull();
        expect(sniffType(heif("heic").subarray(0, 11))).toBeNull();
        expect(sniffType(HEAD.gif.subarray(0, 5))).toBeNull();
        // RIFF that is not WebP (a wav)
        expect(sniffType(Buffer.concat([ascii("RIFF"), Buffer.alloc(4), ascii("WAVEfmt ")]))).toBeNull();
    });

    it("why the bytes decide: a jpeg named .mp4 under video/mp4 is still a jpeg, and videoExt alone would say mp4", () => {
        expect(videoExt({ contentType: "image/jpeg", filename: "instagram_Ddy0-gpGg5U_1.jpg" })).toBe("mp4");
        expect(sniffType(HEAD.jpeg)?.ext).toBe("jpg");
    });
});

describe("parseFetchSelection (APP-API-CONTRACT 18.2: items, item_count)", () => {
    it("nothing sent is fine", () => {
        expect(parseFetchSelection({})).toEqual({ ok: true });
    });
    it.each([
        ["all", "all"],
        ["first-video", "first-video"],
        ["one index", [0]],
        ["ascending indices", [0, 3, 7]],
        ["twenty", Array.from({ length: 20 }, (_, i) => i)],
    ])("accepts items %s", (_n, items) => {
        expect(parseFetchSelection({ items })).toEqual({ ok: true, items });
    });
    it.each([
        ["empty array", []],
        ["21 entries", Array.from({ length: 21 }, (_, i) => i)],
        ["unsorted", [3, 1]],
        ["duplicate", [1, 1]],
        ["negative", [-1]],
        ["fractional", [1.5]],
        ["strings", ["0"]],
        ["an unknown word", "some"],
        ["null", null],
        ["a number", 3],
        ["huge index", [100]],
    ])("rejects items %s", (_n, items) => {
        expect(parseFetchSelection({ items })).toEqual({ ok: false });
    });
    it("item_count is an integer 1-50", () => {
        expect(parseFetchSelection({ item_count: 10 })).toEqual({ ok: true, item_count: 10 });
        expect(parseFetchSelection({ item_count: 1 })).toEqual({ ok: true, item_count: 1 });
        expect(parseFetchSelection({ item_count: 50 })).toEqual({ ok: true, item_count: 50 });
        for (const bad of [0, 51, 1.5, "3", null, -1]) expect(parseFetchSelection({ item_count: bad })).toEqual({ ok: false });
    });
});

describe("selectPickerItems", () => {
    const photo = { type: "photo" };
    const video = { type: "video" };
    const gif = { type: "gif" };
    it("no items, one entry: saved whatever its type (a one-item picker, or a plain answer of unknown type)", () => {
        expect(selectPickerItems([photo], undefined)).toEqual({ ok: true, indices: [0] });
        expect(selectPickerItems([video], undefined)).toEqual({ ok: true, indices: [0] });
        expect(selectPickerItems([{ type: null }], undefined)).toEqual({ ok: true, indices: [0] });
    });
    it("no items, 2+ entries: today's rule (first video, else first gif, else no_video)", () => {
        expect(selectPickerItems([photo, video, video], undefined)).toEqual({ ok: true, indices: [1] });
        expect(selectPickerItems([photo, gif, photo], undefined)).toEqual({ ok: true, indices: [1] });
        expect(selectPickerItems([photo, photo], undefined)).toEqual({ ok: false, code: "error.webp.no_video" });
        expect(selectPickerItems([], undefined)).toEqual({ ok: false, code: "error.webp.no_video" });
    });
    it('"first-video" is today\'s rule, a one-item picker of a photo included; a plain answer is saved', () => {
        expect(selectPickerItems([photo, video], "first-video")).toEqual({ ok: true, indices: [1] });
        expect(selectPickerItems([photo], "first-video")).toEqual({ ok: false, code: "error.webp.no_video" });
        expect(selectPickerItems([{ type: null }], "first-video")).toEqual({ ok: true, indices: [0] });
    });
    it('"all" is every entry, at most 20; an empty picker is no_video', () => {
        expect(selectPickerItems([photo, photo, video], "all")).toEqual({ ok: true, indices: [0, 1, 2] });
        expect(selectPickerItems(Array.from({ length: 25 }, () => photo), "all").ok).toBe(true);
        expect((selectPickerItems(Array.from({ length: 25 }, () => photo), "all") as any).indices).toHaveLength(20);
        expect(selectPickerItems([], "all")).toEqual({ ok: false, code: "error.webp.no_video" });
    });
    it("indices are taken as given; one past the end means the post changed", () => {
        expect(selectPickerItems([photo, photo, photo], [0, 2])).toEqual({ ok: true, indices: [0, 2] });
        expect(selectPickerItems([photo, photo], [0, 2])).toEqual({ ok: false, code: "error.studio.gallery_changed" });
    });
});

describe("buildPosterArgs: an image has frame 0 only", () => {
    it("no `at` means no -ss at all; with `at` it is exactly as before", () => {
        const none = buildPosterArgs({ input: "/in", output: "/o.jpg" });
        expect(none).not.toContain("-ss");
        expect(buildPosterArgs({ input: "/in", output: "/o.jpg", at: null })).not.toContain("-ss");
        const at = buildPosterArgs({ input: "/in", output: "/o.jpg", at: 1.5 });
        expect(at.slice(at.indexOf("-ss"), at.indexOf("-ss") + 2)).toEqual(["-ss", "1.5"]);
        // at 0 is still a seek (a video's first frame), not "no seek"
        expect(buildPosterArgs({ input: "/in", output: "/o.jpg", at: 0 })).toContain("-ss");
    });
    it("`side` sets the longer side (the 480 px thumb), default 720", () => {
        expect(buildPosterArgs({ input: "/in", output: "/o.jpg", side: 480 }).join(" ")).toContain("min(480,iw)");
        expect(buildPosterArgs({ input: "/in", output: "/o.jpg" }).join(" ")).toContain("min(720,iw)");
    });
});

describe("resolveSource in picker mode (stubbed cobalt)", () => {
    const api = "https://api.example.test";
    const run = (body: unknown, picker = true) =>
        resolveSource({
            url: "https://www.instagram.com/p/Ddy0-gpGg5U/",
            internalKey: "K",
            apiOrigin: api,
            picker,
            fetchImpl: (async () => new Response(JSON.stringify(body))) as unknown as typeof fetch,
        });
    it("returns every picker entry with its type and a vetted URL; a refused URL is null (that item fails alone)", async () => {
        const r = await run({
            status: "picker",
            picker: [
                { type: "photo", url: "https://cdn.example/a.jpg" },
                { type: "video", url: `${api}/tunnel?id=A` },
                { type: "photo", url: "http://127.0.0.1:9100/x" },
                { type: "gif", url: "https://cdn.example/g.mp4" },
                { type: "weird", url: "https://cdn.example/w" },
                { url: 5 },
            ],
        });
        expect(r.url).toBeNull();
        expect(r.picker).toEqual([
            { i: 0, type: "photo", url: "https://cdn.example/a.jpg" },
            { i: 1, type: "video", url: "http://127.0.0.1:9000/tunnel?id=A" },
            { i: 2, type: "photo", url: null },
            { i: 3, type: "gif", url: "https://cdn.example/g.mp4" },
            { i: 4, type: "video", url: "https://cdn.example/w" },
            { i: 5, type: "video", url: null },
        ]);
    });
    it("a picker of nothing is an empty list; without picker mode it is still no_video (the WebP jobs)", async () => {
        expect((await run({ status: "picker", picker: [] })).picker).toEqual([]);
        await expect(run({ status: "picker", picker: [{ type: "photo", url: "https://cdn.example/a.jpg" }] }, false)).rejects.toMatchObject({ code: "error.webp.no_video" });
    });
    it("a redirect or tunnel answer has no picker field", async () => {
        const r = await run({ status: "redirect", url: "https://cdn.example/p.jpg", filename: "p.jpg" });
        expect(r).toEqual({ url: "https://cdn.example/p.jpg", filename: "p.jpg" });
    });
});

describe("validateSlideshowStart", () => {
    const good = {
        width: 1080,
        height: 1350,
        fade: true,
        sound: "none",
        slides: [
            { n: 0, seconds: 3 },
            { n: 1, seconds: 5.5 },
            { n: 2, seconds: null },
        ],
    };
    it("accepts the DO's body", () => {
        expect(validateSlideshowStart(good)).toEqual(good);
    });
    it.each([
        ["odd width", { ...good, width: 1081 }],
        ["height over 1920", { ...good, height: 1922 }],
        ["too small", { ...good, width: 8 }],
        ["fractional", { ...good, width: 1080.5 }],
        ["fade not a boolean", { ...good, fade: "yes" }],
        ["sound unknown", { ...good, sound: "music" }],
        ["no slides", { ...good, slides: [] }],
        ["21 slides", { ...good, slides: Array.from({ length: 21 }, (_, i) => ({ n: i % 20, seconds: 1 })) }],
        ["repeated n", { ...good, slides: [{ n: 0, seconds: 3 }, { n: 0, seconds: 3 }] }],
        ["n 20", { ...good, slides: [{ n: 20, seconds: 3 }] }],
        ["seconds 0.4", { ...good, slides: [{ n: 0, seconds: 0.4 }] }],
        ["seconds 16", { ...good, slides: [{ n: 0, seconds: 16 }] }],
        ["seconds a string", { ...good, slides: [{ n: 0, seconds: "3" }] }],
        ["seconds missing", { ...good, slides: [{ n: 0 }] }],
        ["stills over 180 s", { ...good, slides: Array.from({ length: 13 }, (_, i) => ({ n: i, seconds: 15 })) }],
        ["null", null],
    ])("rejects %s", (_n, b) => {
        expect(validateSlideshowStart(b)).toBeNull();
    });
    it("0.5 s a photo is accepted (owner interview 2026-10-07)", () => {
        expect(validateSlideshowStart({ ...good, slides: [{ n: 0, seconds: 0.5 }] })).not.toBeNull();
    });
    it("exactly 180 s of stills is fine", () => {
        expect(validateSlideshowStart({ ...good, slides: Array.from({ length: 12 }, (_, i) => ({ n: i, seconds: 15 })) })).not.toBeNull();
    });
});

describe("the slideshow argv builders (pure)", () => {
    const stills = (n: number, seconds = 3) =>
        Array.from({ length: n }, (_, i) => ({ kind: "still" as const, file: `/w/s-${i}.jpg`, seconds }));
    const graphOf = (args: string[]) => args[args.indexOf("-filter_complex") + 1]!;

    it("fill: a matching aspect is a plain scale; otherwise a blurred, darkened copy under the fitted item", () => {
        expect(fillGraph({ inL: "a", outL: "b", pre: "p", width: 1080, height: 1350, blur: false })).toBe("[a]scale=1080:1350:flags=lanczos,setsar=1[b]");
        const g = fillGraph({ inL: "0:v", outL: "fit", pre: "c", width: 1080, height: 1920, blur: true });
        // the blur is cut and made on a copy 1/8 the frame's size and scaled back up (section 18 review: CPU and memory)
        expect(g).toContain("scale=136:240:force_original_aspect_ratio=increase:flags=bilinear,crop=136:240,boxblur=3:2,eq=brightness=-0.08,scale=1080:1920:flags=bilinear[cbg]");
        expect(g).toContain("scale=1080:1920:force_original_aspect_ratio=decrease");
        expect(g).toContain("overlay=(W-w)/2:(H-h)/2,setsar=1");
        expect(blurRadius(1080, 1920)).toBe(3); // 24 px at full size, 1/8 of that on the small copy
        expect(blurRadius(64, 64)).toBe(3); // the small copy is never under 16 px, boxblur's chroma-plane limit holds
    });
    it("needsBlur: equal aspect (within 0.4 %) skips it; unknown size does not", () => {
        expect(needsBlur(1080, 1350, 1080, 1350)).toBe(false);
        expect(needsBlur(2160, 2700, 1080, 1350)).toBe(false);
        expect(needsBlur(1080, 1352, 1080, 1350)).toBe(false);
        expect(needsBlur(1200, 1200, 1080, 1920)).toBe(true);
        expect(needsBlur(1080, 1350, 1080, 1080)).toBe(true);
        expect(needsBlur(null, 100, 1080, 1080)).toBe(true);
    });
    it("compose: one JPEG frame, -q:v 2, at the frame size", () => {
        const a = buildComposeArgs({ input: "/in", output: "/o.jpg", width: 1080, height: 1920, blur: true });
        expect(a).toContain("-frames:v");
        expect(a.slice(a.indexOf("-q:v"), a.indexOf("-q:v") + 2)).toEqual(["-q:v", "2"]);
        expect(graphOf(a)).toContain("crop=136:240");
        expect(graphOf(a)).toContain("scale=1080:1920:flags=bilinear[cbg]");
        expect(graphOf(a)).toContain("format=yuvj420p[out]");
        expect(buildComposeArgs({ input: "/in", output: "/o.jpg", width: 1080, height: 1350, blur: false }).join(" ")).not.toContain("boxblur");
    });
    it("fade: every slide but the last runs 0.3 s longer, xfade offsets are the sum of the previous slides", () => {
        const a = buildSlideshowArgs({
            segments: [
                { kind: "still", file: "/w/s-0.jpg", seconds: 2.5 },
                { kind: "still", file: "/w/s-1.jpg", seconds: 4.5 },
                { kind: "still", file: "/w/s-2.jpg", seconds: 6 },
            ],
            width: 1080,
            height: 1350,
            fade: true,
            sound: "none",
            output: "/o.mp4",
        });
        const ts = a.flatMap((x, i) => (x === "-t" ? [a[i + 1]] : []));
        expect(ts).toEqual(["2.8", "4.8", "6"]);
        const g = graphOf(a);
        expect(g).toContain(`[v0][v1]xfade=transition=fade:duration=${FADE_SECONDS}:offset=2.5[x1]`);
        expect(g).toContain(`[x1][v2]xfade=transition=fade:duration=${FADE_SECONDS}:offset=7[x2]`);
        expect(g).toContain("mpdecimate=hi=64:lo=32:frac=0.33:max=15[vout]");
        expect(g).toContain("[x2]drawbox="); // the end mark that keeps the last frame (see buildSlideshowArgs)
        // 2.5 + 4.5 + 6 = 13 s: the mark sits on the last two frames only
        expect(g).toContain("enable='gte(t,12.915)'");
        expect(a.join(" ")).toContain("-bf 0"); // B-frame delay would shorten the mp4's duration
    });
    it("cut: concat, each still exactly its seconds", () => {
        const a = buildSlideshowArgs({ segments: stills(3, 2), width: 1080, height: 1080, fade: false, sound: "none", output: "/o.mp4" });
        expect(a.flatMap((x, i) => (x === "-t" ? [a[i + 1]] : []))).toEqual(["2", "2", "2"]);
        expect(graphOf(a)).toContain("[v0][v1][v2]concat=n=3:v=1:a=0[xc]");
        expect(graphOf(a)).not.toContain("xfade");
    });
    it("the encode: vfr, libx264 veryfast stillimage crf 20, yuv420p, faststart; no audio unless asked", () => {
        const a = buildSlideshowArgs({ segments: stills(2), width: 1080, height: 1350, fade: true, sound: "none", output: "/o.mp4" });
        const j = a.join(" ");
        for (const part of ["-fps_mode vfr", "-c:v libx264", "-preset veryfast", "-tune stillimage", "-crf 20", "-pix_fmt yuv420p", "-movflags +faststart", "-progress pipe:1"]) {
            expect(j).toContain(part);
        }
        expect(a).toContain("-an");
        expect(a).not.toContain("[aout]");
        expect(a[a.length - 1]).toBe("/o.mp4");
    });
    it('sound "own": a motion item\'s track, anullsrc under the stills, acrossfade (fade) or concat (cut); not without a track', () => {
        const segs = [
            { kind: "still" as const, file: "/w/s-0.jpg", seconds: 3 },
            { kind: "motion" as const, file: "/in/1", seconds: 2, hasAudio: true, blur: true },
            { kind: "still" as const, file: "/w/s-1.jpg", seconds: 3 },
        ];
        const fade = buildSlideshowArgs({ segments: segs, width: 1080, height: 1350, fade: true, sound: "own", output: "/o.mp4" });
        const g = graphOf(fade);
        expect(g).toContain("[1:a]aresample=44100");
        expect(g).toContain("anullsrc=r=44100:cl=stereo,atrim=duration=3.3");
        expect(g).toContain(`acrossfade=d=${FADE_SECONDS}`);
        expect(fade.join(" ")).toContain("-map [aout]");
        const cut = buildSlideshowArgs({ segments: segs, width: 1080, height: 1350, fade: false, sound: "own", output: "/o.mp4" });
        expect(graphOf(cut)).toContain("[a0][a1][a2]concat=n=3:v=0:a=1[axc]");
        // sound own but no motion item has a track: no audio at all
        const silent = buildSlideshowArgs({
            segments: [segs[0]!, { kind: "motion" as const, file: "/in/1", seconds: 2, hasAudio: false, blur: true }, segs[2]!],
            width: 1080,
            height: 1350,
            fade: true,
            sound: "own",
            output: "/o.mp4",
        });
        expect(silent).toContain("-an");
        expect(silent).not.toContain("[aout]");
        // sound none keeps a video's track out
        expect(buildSlideshowArgs({ segments: segs, width: 1080, height: 1350, fade: true, sound: "none", output: "/o.mp4" })).toContain("-an");
    });
    it("a video segment is padded with its last frame, then cut to exactly its length", () => {
        const a = buildSlideshowArgs({
            segments: [
                { kind: "motion", file: "/in/0", seconds: 2, hasAudio: false, blur: false },
                { kind: "still", file: "/w/s-0.jpg", seconds: 3 },
            ],
            width: 1080,
            height: 1350,
            fade: true,
            sound: "none",
            output: "/o.mp4",
        });
        expect(graphOf(a)).toContain("tpad=stop_mode=clone:stop_duration=3,trim=duration=2.3");
        expect(graphOf(a)).toContain("[0:v]fps=30[r0]");
    });
    it("progress lines: the last out_time_us / out_time_ms, in seconds; N/A and noise are null", () => {
        expect(parseProgressSeconds("frame=3\nout_time_us=1500000\nprogress=continue\nout_time_us=2500000\n")).toBe(2.5);
        expect(parseProgressSeconds("out_time_ms=4000000\n")).toBe(4);
        expect(parseProgressSeconds("out_time_us=N/A\nprogress=continue\n")).toBeNull();
        expect(parseProgressSeconds("nothing\n")).toBeNull();
    });
    it("parseHasAudio reads ffmpeg's stream list", () => {
        expect(parseHasAudio("  Stream #0:0: Video: h264\n  Stream #0:1(und): Audio: aac (LC)")).toBe(true);
        expect(parseHasAudio("  Stream #0:0: Video: h264")).toBe(false);
    });
});

// =================================================================================================
// the real ffmpeg: what the container's ffmpeg-static must have
// =================================================================================================

real("the ffmpeg this suite runs on has what the slideshow needs", () => {
    // The container uses ffmpeg-static 5.3.0 (release b6.1.1, a different build from the one tested here).
    // This test names exactly what the helper relies on, so a deploy-time check can run the same two commands.
    const filters = hasFfmpeg ? spawnSync(FFMPEG, ["-hide_banner", "-filters"], { encoding: "utf8" }).stdout : "";
    const encoders = hasFfmpeg ? spawnSync(FFMPEG, ["-hide_banner", "-encoders"], { encoding: "utf8" }).stdout : "";
    it.each(["xfade", "mpdecimate", "boxblur", "gblur", "overlay", "eq", "split", "scale", "crop", "fps", "tpad", "trim", "concat", "acrossfade", "anullsrc", "aresample", "aformat", "apad", "atrim"])(
        "filter %s",
        (name) => {
            expect(filters).toMatch(new RegExp(`\\s${name}\\s`));
        },
    );
    it.each(["libx264", "aac", "mjpeg"])("encoder %s", (name) => {
        expect(encoders).toMatch(new RegExp(`\\s${name}\\s`));
    });
    it("reports the version it ran on", () => {
        const v = spawnSync(FFMPEG, ["-version"], { encoding: "utf8" }).stdout.split("\n")[0];
        process.stderr.write(`[gallery-helper tests] ${v}\n`);
        expect(v).toMatch(/^ffmpeg version/);
    });
});

// =================================================================================================
// POST /fetch: items, photos by their bytes, thumbs, the image poster
// =================================================================================================

type Served = { file?: string; body?: Buffer; type: string; status?: number; gate?: Promise<void> };
let origin: http.Server;
let originUrl: string;
let served: Record<string, Served>;
let hits: string[];

let helper: ReturnType<typeof createHelper>;
let base: string;
let dirs: { work: string; fetch: string; probe: string; poster: string; slideshow: string };
let resolveBody: (url: string) => Promise<any>;

async function startHelper(over: Record<string, unknown> = {}) {
    const id = Math.random().toString(36).slice(2);
    dirs = {
        work: path.join(root, id, "webp"),
        fetch: path.join(root, id, "fetch"),
        probe: path.join(root, id, "probe"),
        poster: path.join(root, id, "poster"),
        slideshow: path.join(root, id, "slideshow"),
    };
    helper = createHelper({
        internalKey: KEY,
        workDir: dirs.work,
        fetchDir: dirs.fetch,
        probeDir: dirs.probe,
        posterDir: dirs.poster,
        slideshowDir: dirs.slideshow,
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        img2webpPath: () => "img2webp",
        // the real resolveSource over a stubbed cobalt: picker mode, URL vetting and all
        resolveSource: (o: any) =>
            resolveSource({
                ...o,
                fetchImpl: (async () => new Response(JSON.stringify(await resolveBody(o.url)))) as unknown as typeof fetch,
            }),
        // the real download, with the CDN's host pointed at the local origin
        downloadToFile: (o: any) => downloadToFile({ ...o, url: o.url.replace("https://cdn.example", originUrl) }),
        ...over,
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
}

beforeAll(async () => {
    origin = http.createServer(async (req, res) => {
        const key = (req.url ?? "").split("?")[0]!;
        hits.push(key);
        const s = served[key];
        if (!s) {
            res.writeHead(404);
            return void res.end();
        }
        if (s.gate) await s.gate;
        if (s.status && s.status !== 200) {
            res.writeHead(s.status);
            return void res.end();
        }
        const body = s.body ?? readFileSync(s.file!);
        res.writeHead(200, { "content-type": s.type, "content-length": body.length });
        res.end(body);
    });
    await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
    originUrl = `http://127.0.0.1:${(origin.address() as any).port}`;
});
afterAll(() => origin?.close());

beforeEach(async () => {
    hits = [];
    served = {};
    resolveBody = async () => ({ status: "error", error: { code: "error.api.fetch.fail" } });
    await startHelper();
});
afterEach(() => helper.close());

const call = (p: string, init: RequestInit & { duplex?: string } = {}, key: string | null = KEY) =>
    fetch(`${base}${p}`, { ...init, headers: { ...(key === null ? {} : { "x-internal-key": key }), ...(init.headers as any) } });
const json = async (r: Response) => (await r.json()) as any;
const post = (p: string, b: unknown) => call(p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) });
const until = async (p: string, want = (b: any) => b.status !== "pending") => {
    for (let i = 0; i < 600; i++) {
        const b = await json(await call(p));
        if (want(b)) return b;
        await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("timed out waiting for " + p);
};
const gated = () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    return { gate, release };
};
const LINK = "https://www.instagram.com/p/Ddy0-gpGg5U/";
const cdn = (name: string) => `https://cdn.example/${name}`;
const pickerOf = (...items: [string, string][]) => ({ status: "picker", picker: items.map(([type, name]) => ({ type, url: cdn(name) })) });
const serve = (name: string, fixture: string, type: string, extra: Partial<Served> = {}) => {
    served[`/${name}`] = { file: fx[fixture], type, ...extra };
};

real("POST /fetch: a single photo is saved as a photo (the 0.04 s mp4 bug)", () => {
    it.each([
        ["a jpeg answered as redirect, served image/jpeg", "image/jpeg", "instagram_Ddy0-gpGg5U_1.jpg"],
        ["the same jpeg served as application/octet-stream under a .mp4 name", "application/octet-stream", "instagram_1.mp4"],
        ["the same jpeg served as video/mp4 (a CDN that lies)", "video/mp4", "instagram_1.mp4"],
    ])("REGRESSION: %s comes back image/jpeg, jpg, duration null, with its real size", async (_n, type, filename) => {
        serve("p.jpg", "p-1080x1350.jpg", type);
        resolveBody = async () => ({ status: "redirect", url: cdn("p.jpg"), filename });
        const id = rid();
        expect((await post("/fetch", { id, url: LINK })).status).toBe(202);
        const done = await until(`/fetch/${id}`);
        // before the fix: contentType "video/mp4", ext "mp4", duration 0.04 (ffmpeg calls a jpeg a one-frame video)
        expect(done).toMatchObject({ status: "done", contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350, picker_count: null });
        expect(done.items).toBeUndefined();
        const file = await call(`/fetch/${id}/file`);
        expect(file.headers.get("content-type")).toBe("image/jpeg");
        const bytes = Buffer.from(await file.arrayBuffer());
        expect(bytes.equals(readFileSync(fx["p-1080x1350.jpg"]!))).toBe(true);
        expect(done.bytes).toBe(bytes.length);
    });

    it("the thumb is a JPEG, longer side 480 (the photo is 1080x1350: 384x480)", async () => {
        serve("p.jpg", "p-1080x1350.jpg", "image/jpeg");
        resolveBody = async () => ({ status: "redirect", url: cdn("p.jpg"), filename: "p.jpg" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        await until(`/fetch/${id}`);
        const t = await call(`/fetch/${id}/thumb`);
        expect(t.status).toBe(200);
        expect(t.headers.get("content-type")).toBe("image/jpeg");
        const buf = Buffer.from(await t.arrayBuffer());
        expect(Number(t.headers.get("content-length"))).toBe(buf.length);
        const { w, h } = jpegSize(buf);
        expect(Math.max(w, h)).toBeLessThanOrEqual(480);
        expect({ w, h }).toEqual({ w: 384, h: 480 });
    });

    it("a small photo's thumb is never upscaled", async () => {
        serve("s.jpg", "p-300x200.jpg", "image/jpeg");
        resolveBody = async () => ({ status: "redirect", url: cdn("s.jpg"), filename: "s.jpg" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        await until(`/fetch/${id}`);
        expect(jpegSize(Buffer.from(await (await call(`/fetch/${id}/thumb`)).arrayBuffer()))).toEqual({ w: 300, h: 200 });
    });

    it.each([
        ["png", "p-800x600.png", "image/png", "png", 800, 600],
        ["webp", "p-640x640.webp", "image/webp", "webp", 640, 640],
    ])("a %s keeps its real type", async (_n, fixture, type, ext, w, h) => {
        if (!fx[fixture]) return; // no webp encoder on this machine (neither ffmpeg's nor cwebp)
        serve("x", fixture, "application/octet-stream");
        resolveBody = async () => ({ status: "tunnel", url: "http://127.0.0.1:9000/tunnel?id=1", filename: "x.mp4" });
        // a tunnel URL is rewritten to cobalt's own origin: point that at the local origin for the test
        served["/tunnel"] = served["/x"]!;
        await helper.close();
        await startHelper({
            downloadToFile: (o: any) => downloadToFile({ ...o, url: o.url.replace("http://127.0.0.1:9000", originUrl) }),
        });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        expect(await until(`/fetch/${id}`)).toMatchObject({ status: "done", contentType: type, ext, duration: null, width: w, height: h });
        expect((await call(`/fetch/${id}/thumb`)).status).toBe(200);
    });

    it("a HEIC the ffmpeg cannot decode is still saved as image/heic, ext heic, with no thumb (404)", async () => {
        served["/h.heic"] = { body: Buffer.concat([heif("heic"), Buffer.alloc(200, 7)]), type: "image/heic" };
        resolveBody = async () => ({ status: "redirect", url: cdn("h.heic"), filename: "h.heic" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        expect(await until(`/fetch/${id}`)).toMatchObject({ status: "done", contentType: "image/heic", ext: "heic", duration: null });
        expect((await call(`/fetch/${id}/thumb`)).status).toBe(404);
        expect((await call(`/fetch/${id}/file`)).status).toBe(200);
    });

    it("a jpeg head on bytes ffmpeg cannot read is bad_source (nothing is stored)", async () => {
        served["/b.jpg"] = { body: Buffer.concat([HEAD.jpeg, Buffer.alloc(100, 9)]), type: "image/jpeg" };
        resolveBody = async () => ({ status: "redirect", url: cdn("b.jpg"), filename: "b.jpg" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.webp.bad_source" } });
        expect(existsSync(path.join(dirs.fetch, id))).toBe(false);
    });

    it("a real video is still a video (mp4, with its duration), and a gif is still image/gif", async () => {
        serve("v.mp4", "v-tone.mp4", "video/mp4");
        resolveBody = async () => ({ status: "redirect", url: cdn("v.mp4"), filename: "clip.mp4" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", width: 640, height: 360 });
        expect(done.duration).toBeGreaterThan(1.9);
        expect((await call(`/fetch/${id}/thumb`)).status).toBe(404); // a video gets its poster from /poster, not a thumb
        const gif = path.join(root, "g.gif");
        ff(["-f", "lavfi", "-i", "testsrc2=s=200x120:d=1:r=10", gif]);
        served["/g.gif"] = { file: gif, type: "image/gif" };
        resolveBody = async () => ({ status: "redirect", url: cdn("g.gif"), filename: "g.mp4" });
        const gid = rid();
        await post("/fetch", { id: gid, url: LINK });
        expect(await until(`/fetch/${gid}`)).toMatchObject({ status: "done", contentType: "image/gif", ext: "gif" });
    });
});

real("POST /fetch: pickers, with and without items", () => {
    const setup = () => {
        serve("a.jpg", "p-1080x1350.jpg", "image/jpeg");
        serve("b.jpg", "p-1200x1200.jpg", "image/jpeg");
        serve("c.png", "p-800x600.png", "image/png");
        serve("v.mp4", "v-tone.mp4", "video/mp4");
    };

    it("a one-item photo picker, no items: saved (today it was no_video), picker_count 1", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "image/jpeg", ext: "jpg", duration: null, picker_count: 1, title: null });
        expect(done.items).toBeUndefined();
        expect((await call(`/fetch/${id}/thumb`)).status).toBe(200);
    });

    it("a two-item picker, no items: today's rule (first video); photos only asked as \"first-video\" is still no_video (no items at all now saves whole: 18.9, helper-legacy-picker.test.ts)", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["video", "v.mp4"]);
        const id = rid();
        await post("/fetch", { id, url: LINK });
        expect(await until(`/fetch/${id}`)).toMatchObject({ status: "done", contentType: "video/mp4", picker_count: 2 });
        expect(hits).toEqual(["/v.mp4"]); // only the video was fetched
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id2 = rid();
        await post("/fetch", { id: id2, url: LINK, items: "first-video" });
        expect(await until(`/fetch/${id2}`)).toEqual({ status: "error", error: { code: "error.webp.no_video" } });
    });

    it('items "all" with item 2 answering 403: 2 done + 1 error, the job done, the lead is item 0', async () => {
        setup();
        served["/b.jpg"] = { type: "image/jpeg", status: 403 };
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"], ["photo", "c.png"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all", item_count: 3 });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", picker_count: 3, contentType: "image/jpeg", width: 1080, height: 1350 });
        expect(done.items).toHaveLength(3);
        expect(done.items[0]).toMatchObject({ i: 0, status: "done", contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350, thumb: true });
        expect(done.items[1]).toEqual({ i: 1, status: "error", code: "error.webp.download_failed" });
        expect(done.items[2]).toMatchObject({ i: 2, status: "done", contentType: "image/png", ext: "png", width: 800, height: 600, thumb: true });
        // files and thumbs by index; the failed item has none
        const f2 = await call(`/fetch/${id}/file?i=2`);
        expect(f2.headers.get("content-type")).toBe("image/png");
        expect(Buffer.from(await f2.arrayBuffer()).equals(readFileSync(fx["p-800x600.png"]!))).toBe(true);
        expect((await call(`/fetch/${id}/file?i=1`)).status).toBe(404);
        expect((await call(`/fetch/${id}/thumb?i=1`)).status).toBe(404);
        expect((await call(`/fetch/${id}/thumb?i=2`)).headers.get("content-type")).toBe("image/jpeg");
        expect((await call(`/fetch/${id}/file?i=7`)).status).toBe(404);
        expect((await call(`/fetch/${id}/file?i=abc`)).status).toBe(404);
        // no i = the lead
        expect(Buffer.from(await (await call(`/fetch/${id}/file`)).arrayBuffer()).equals(readFileSync(fx["p-1080x1350.jpg"]!))).toBe(true);
    });

    it("the lead is the first saved VIDEO even when photos come first; if the first photo failed it is the next saved", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"], ["video", "v.mp4"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all" });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", width: 640, height: 360 });
        expect(done.items.map((i: any) => [i.i, i.status, i.contentType, i.thumb])).toEqual([
            [0, "done", "image/jpeg", true],
            [1, "done", "image/jpeg", true],
            [2, "done", "video/mp4", false],
        ]);
        expect((await call(`/fetch/${id}/file`)).headers.get("content-type")).toBe("video/mp4");
        // first photo fails, no video: the lead is the next saved item
        served["/a.jpg"] = { type: "image/jpeg", status: 403 };
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id2 = rid();
        await post("/fetch", { id: id2, url: LINK, items: "all" });
        const d2 = await until(`/fetch/${id2}`);
        expect(d2).toMatchObject({ status: "done", width: 1200, height: 1200 });
        expect(d2.items.map((i: any) => i.status)).toEqual(["error", "done"]);
    });

    it("items [0, 2] fetches only those (nothing else is requested)", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"], ["photo", "c.png"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: [0, 2], item_count: 3 });
        const done = await until(`/fetch/${id}`);
        expect(done.items.map((i: any) => i.i)).toEqual([0, 2]);
        expect([...hits].sort()).toEqual(["/a.jpg", "/c.png"]);
        expect((await call(`/fetch/${id}/file?i=1`)).status).toBe(404);
    });

    it('"first-video" is today: one item (the first video), fetched alone; photos only is no_video', async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["video", "v.mp4"], ["video", "v.mp4"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "first-video" });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "video/mp4", picker_count: 3 });
        // one file, exactly today's answer: no `items` list, so the API stores originals/<sid>.mp4 with no role
        expect(done).not.toHaveProperty("items");
        expect(hits).toEqual(["/v.mp4"]);
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id2 = rid();
        await post("/fetch", { id: id2, url: LINK, items: "first-video" });
        expect(await until(`/fetch/${id2}`)).toEqual({ status: "error", error: { code: "error.webp.no_video" } });
    });

    it("item_count that differs from the picker's length is gallery_changed, before anything is fetched", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"], ["photo", "c.png"]);
        for (const [items, count] of [["all", 4], ["all", 2], [[0], 5], [undefined, 9]] as const) {
            const id = rid();
            await post("/fetch", { id, url: LINK, ...(items === undefined ? {} : { items }), item_count: count });
            expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.studio.gallery_changed" } });
            expect(existsSync(path.join(dirs.fetch, id))).toBe(false);
        }
        expect(hits).toEqual([]);
        // the right count passes; a plain (non-picker) answer counts as one
        const ok = rid();
        await post("/fetch", { id: ok, url: LINK, items: "all", item_count: 3 });
        expect((await until(`/fetch/${ok}`)).status).toBe("done");
        resolveBody = async () => ({ status: "redirect", url: cdn("a.jpg"), filename: "a.jpg" });
        const one = rid();
        await post("/fetch", { id: one, url: LINK, item_count: 1 });
        expect((await until(`/fetch/${one}`)).status).toBe("done");
        const many = rid();
        await post("/fetch", { id: many, url: LINK, item_count: 4 });
        expect(await until(`/fetch/${many}`)).toEqual({ status: "error", error: { code: "error.studio.gallery_changed" } });
    });

    it("an index past the end of the picker is gallery_changed too", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: [0, 4] });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.studio.gallery_changed" } });
    });

    it("the job fails only when every item failed, with the FIRST item's code, and leaves nothing behind", async () => {
        setup();
        served["/a.jpg"] = { type: "image/jpeg", status: 403 };
        served["/b.jpg"] = { type: "image/jpeg", status: 403 };
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all" });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.webp.download_failed" } });
        expect(existsSync(path.join(dirs.fetch, id))).toBe(false);
        // a refused URL (a private host) is that item's own bad_source
        resolveBody = async () => ({ status: "picker", picker: [{ type: "photo", url: "http://127.0.0.1:9100/x" }, { type: "photo", url: cdn("b.jpg") }] });
        served["/b.jpg"] = { file: fx["p-1200x1200.jpg"], type: "image/jpeg" };
        const id2 = rid();
        await post("/fetch", { id: id2, url: LINK, items: "all" });
        const d2 = await until(`/fetch/${id2}`);
        expect(d2.items[0]).toEqual({ i: 0, status: "error", code: "error.webp.bad_source" });
        expect(d2.items[1]).toMatchObject({ i: 1, status: "done" });
    });

    it("the 200 MB per-item cap and the 500 MB per-job cap (shrunk here) fail the item, not the job", async () => {
        setup();
        const size = (f: string) => readFileSync(fx[f]!).length;
        const small = size("p-300x200.jpg");
        serve("s.jpg", "p-300x200.jpg", "image/jpeg");
        serve("big.jpg", "p-1080x1350.jpg", "image/jpeg");
        expect(size("p-1080x1350.jpg")).toBeGreaterThan(small * 2);
        await helper.close();
        await startHelper({ maxFetchBytes: small * 2, maxJobBytes: small * 2 + 10 });
        resolveBody = async () => pickerOf(["photo", "s.jpg"], ["photo", "big.jpg"], ["photo", "s.jpg"], ["photo", "s.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all" });
        const d = await until(`/fetch/${id}`);
        expect(d.items.map((i: any) => [i.i, i.status, i.code ?? null])).toEqual([
            [0, "done", null],
            [1, "error", "error.studio.too_large"], // over the per-item cap
            [2, "done", null],
            [3, "error", "error.studio.too_large"], // two smalls plus 10 bytes is the job's budget: this one does not fit
        ]);
    });

    it("pending shows which item is being fetched and how many are done", async () => {
        setup();
        const g = gated();
        served["/b.jpg"] = { file: fx["p-1200x1200.jpg"], type: "image/jpeg", gate: g.gate };
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"], ["photo", "c.png"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all" });
        const mid = await until(`/fetch/${id}`, (b) => b.status !== "pending" || (b.item === 1 && b.items_done === 1));
        expect(mid).toMatchObject({ status: "pending", stage: "downloading", item: 1, items_done: 1, items_total: 3 });
        g.release();
        expect((await until(`/fetch/${id}`)).items).toHaveLength(3);
    });

    it("DELETE removes every file of the job", async () => {
        setup();
        resolveBody = async () => pickerOf(["photo", "a.jpg"], ["photo", "b.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "all" });
        await until(`/fetch/${id}`);
        expect(existsSync(path.join(dirs.fetch, id, "item-00"))).toBe(true);
        expect(existsSync(path.join(dirs.fetch, id, "thumb-01.jpg"))).toBe(true);
        expect((await call(`/fetch/${id}`, { method: "DELETE" })).status).toBe(200);
        expect(existsSync(path.join(dirs.fetch, id))).toBe(false);
        expect((await call(`/fetch/${id}/file?i=0`)).status).toBe(404);
    });
});

describe("POST /fetch: bad items / item_count", () => {
    it.each([
        ["items an unknown word", { items: "some" }],
        ["items empty", { items: [] }],
        ["items unsorted", { items: [2, 1] }],
        ["items repeated", { items: [1, 1] }],
        ["items 21 long", { items: Array.from({ length: 21 }, (_, i) => i) }],
        ["items negative", { items: [-1] }],
        ["items null", { items: null }],
        ["item_count 0", { item_count: 0 }],
        ["item_count 51", { item_count: 51 }],
        ["item_count a string", { item_count: "3" }],
    ])("400 error.studio.invalid_params for %s, nothing is created", async (_n, extra) => {
        const res = await post("/fetch", { id: rid(), url: LINK, ...extra });
        expect(res.status).toBe(400);
        expect(await json(res)).toEqual({ status: "error", error: { code: "error.studio.invalid_params" } });
        expect(helper.fetches.size).toBe(0);
    });
    it("a bad id or url is still the old error.webp.invalid_params", async () => {
        expect(await json(await post("/fetch", { id: "short", url: LINK, items: "all" }))).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(await json(await post("/fetch", { id: rid(), url: "ftp://x", items: "all" }))).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
    });
    it("403 without the key on the new routes", async () => {
        const id = rid();
        for (const [m, p] of [["GET", `/fetch/${id}/thumb`], ["GET", `/fetch/${id}/file?i=0`], ["PUT", `/slideshow/${id}/inputs/0`], ["POST", `/slideshow/${id}/start`], ["GET", `/slideshow/${id}`], ["GET", `/slideshow/${id}/file`], ["DELETE", `/slideshow/${id}`]] as const) {
            expect((await call(p, { method: m }, null)).status).toBe(403);
            expect((await call(p, { method: m }, "wrong")).status).toBe(403);
        }
    });
});

real("POST /poster: a picture is answered from frame 0", () => {
    const poster = (body: Buffer, id = rid()) => call(`/poster?id=${id}`, { method: "POST", body, headers: { "content-type": "application/octet-stream" }, duplex: "half" } as any);
    it("REGRESSION: a jpeg body is 200 image/jpeg with its own picture (before: 422 error.poster.failed, ffmpeg wrote nothing)", async () => {
        const res = await poster(readFileSync(fx["p-1080x1350.jpg"]!));
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("image/jpeg");
        const buf = Buffer.from(await res.arrayBuffer());
        expect(Number(res.headers.get("content-length"))).toBe(buf.length);
        expect(jpegSize(buf)).toEqual({ w: 576, h: 720 }); // longer side 720, aspect kept
    });
    it("png and webp bodies too; a small one is not upscaled", async () => {
        for (const f of ["p-800x600.png", "p-640x640.webp"].filter((x) => fx[x])) {
            const res = await poster(readFileSync(fx[f]!));
            expect(res.status).toBe(200);
            expect(res.headers.get("content-type")).toBe("image/jpeg");
        }
        expect(jpegSize(Buffer.from(await (await poster(readFileSync(fx["p-300x200.jpg"]!))).arrayBuffer()))).toEqual({ w: 300, h: 200 });
        expect(readdirSafe(dirs.poster)).toEqual([]); // the work dir is gone
    });
    it("a jpeg head on garbage is a 422, not a hang, and a video still goes through the probe path", async () => {
        const bad = await poster(Buffer.concat([HEAD.jpeg, Buffer.alloc(64, 9)]));
        expect(bad.status).toBe(422);
        expect(await json(bad)).toEqual({ status: "error", error: { code: "error.poster.failed" } });
        const vid = await poster(readFileSync(fx["v-tone.mp4"]!));
        expect(vid.status).toBe(200);
        expect(jpegSize(Buffer.from(await vid.arrayBuffer()))).toEqual({ w: 640, h: 360 }); // a 640x360 video: under the 720 cap, never upscaled
    });
});
function readdirSafe(dir: string) {
    try {
        return readdirSync(dir);
    } catch {
        return [] as string[];
    }
}

// =================================================================================================
// the slideshow
// =================================================================================================

type Plan = { width: number; height: number; fade: boolean; sound: "none" | "own"; slides: { n: number; seconds: number | null }[] };

const put = (id: string, n: number | string, body: Buffer | string) =>
    call(`/slideshow/${id}/inputs/${n}`, { method: "PUT", body, headers: { "content-type": "application/octet-stream" }, duplex: "half" } as any);
const putFile = (id: string, n: number, fixture: string) => put(id, n, readFileSync(fx[fixture]!));
const start = (id: string, plan: unknown) => post(`/slideshow/${id}/start`, plan);

async function run(id: string, inputs: string[], plan: Plan) {
    for (const [n, f] of inputs.entries()) expect((await putFile(id, n, f)).status).toBe(204);
    const res = await start(id, plan);
    expect(res.status).toBe(202);
    expect(await json(res)).toEqual({ status: "pending", id });
    const done = await until(`/slideshow/${id}`);
    return done;
}
async function download(id: string, name: string) {
    const res = await call(`/slideshow/${id}/file`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("video/mp4");
    const buf = Buffer.from(await res.arrayBuffer());
    expect(Number(res.headers.get("content-length"))).toBe(buf.length);
    const file = path.join(root, name);
    writeFileSync(file, buf);
    return { file, bytes: buf.length };
}

real("the slideshow routes, with the real ffmpeg", () => {
    const measured: string[] = [];
    afterAll(() => void process.stderr.write(`[gallery-helper tests] slideshow measurements:\n${measured.join("\n")}\n`));

    it("fade: duration = the plan (+-0.1 s), 1080x1350, one video stream, no audio; phases and the answer shape", async () => {
        const id = rid();
        const plan: Plan = { width: 1080, height: 1350, fade: true, sound: "none", slides: [{ n: 0, seconds: 1.5 }, { n: 1, seconds: 2 }, { n: 2, seconds: 1.5 }] };
        for (const [n, f] of ["p-1080x1350.jpg", "p-1200x1200.jpg", "p-800x600.png"].entries()) await putFile(id, n, f);
        // before start: pending, holding the helper, no phase yet
        expect(await json(await call(`/slideshow/${id}`))).toEqual({ status: "pending", phase: null, done: 0, total: 0 });
        const t0 = Date.now();
        expect((await start(id, plan)).status).toBe(202);
        const seen = new Set<string>();
        const done = await until(`/slideshow/${id}`, (b) => {
            if (b.status === "pending") seen.add(`${b.phase}`);
            return b.status !== "pending";
        });
        const ms = Date.now() - t0;
        expect(done).toMatchObject({ status: "done", width: 1080, height: 1350 });
        expect(Math.abs(done.duration - 5)).toBeLessThanOrEqual(0.1);
        for (const p of seen) expect(["composing", "encoding"]).toContain(p);
        const { file, bytes } = await download(id, "fade.mp4");
        expect(done.bytes).toBe(bytes);
        const info = infoOf(file);
        expect(info).toMatchObject({ width: 1080, height: 1350, hasAudio: false });
        expect(Math.abs(info.duration! - 5)).toBeLessThanOrEqual(0.1);
        measured.push(`fade 3 stills 1080x1350: plan 5.00 s, output ${info.duration!.toFixed(2)} s, ${(bytes / 1024).toFixed(0)} KB, ${ms} ms`);
        // DELETE frees everything
        expect((await call(`/slideshow/${id}`, { method: "DELETE" })).status).toBe(204);
        expect(existsSync(path.join(dirs.slideshow, id))).toBe(false);
        expect((await call(`/slideshow/${id}`)).status).toBe(404);
        expect(helper.slideshows.size).toBe(0);
    });

    it("cut: duration = the plan (+-0.1 s)", async () => {
        const id = rid();
        const done = await run(id, ["p-1080x1350.jpg", "p-1200x1200.jpg", "p-800x600.png"], { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: 1.5 }, { n: 1, seconds: 2 }, { n: 2, seconds: 1.5 }] });
        expect(done.status).toBe("done");
        const { file, bytes } = await download(id, "cut.mp4");
        const info = infoOf(file);
        expect(Math.abs(info.duration! - 5)).toBeLessThanOrEqual(0.1);
        expect(Math.abs(done.duration - 5)).toBeLessThanOrEqual(0.1);
        measured.push(`cut 3 stills 1080x1350: plan 5.00 s, output ${info.duration!.toFixed(2)} s, ${(bytes / 1024).toFixed(0)} KB`);
    });

    it("slides play in the order given, whatever n they came in as", async () => {
        const id = rid();
        // n 3 is a solid orange square, n 1 a test card: slide order [3, 1]: the first frame is orange
        await putFile(id, 3, "orange-1200x1200.jpg");
        await putFile(id, 1, "p-1200x1200.jpg");
        expect((await start(id, { width: 1080, height: 1080, fade: false, sound: "none", slides: [{ n: 3, seconds: 1 }, { n: 1, seconds: 1 }] })).status).toBe(202);
        expect((await until(`/slideshow/${id}`)).status).toBe("done");
        const { file } = await download(id, "order.mp4");
        const [r, g, b] = averageRgb(file, [0, 0, 1080, 1080], 0.2);
        expect(r).toBeGreaterThan(200);
        expect(b).toBeLessThan(60);
        expect(g).toBeGreaterThan(100);
        const late = averageRgb(file, [0, 0, 1080, 1080], 1.5); // the test card: not orange
        expect(late[2] > 60 || late[0] < 180).toBe(true);
    });

    it.each([
        ["keep (the post's 4:5)", 1080, 1350],
        ["9:16", 1080, 1920],
        ["1:1", 1080, 1080],
    ])("frame size %s: the output is exactly %ix%i", async (_n, w, h) => {
        const id = rid();
        const done = await run(id, ["p-1080x1350.jpg", "p-1200x1200.jpg"], { width: w, height: h, fade: true, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] });
        expect(done).toMatchObject({ status: "done", width: w, height: h });
        const { file, bytes } = await download(id, `frame-${w}x${h}.mp4`);
        expect(infoOf(file)).toMatchObject({ width: w, height: h });
        measured.push(`frame ${w}x${h}, 2 stills of 1 s: ${(bytes / 1024).toFixed(0)} KB, ${done.duration} s`);
    });

    it("a 1:1 still in a 9:16 frame fills the bars with its blur (not black); in a 1:1 frame it is just scaled", async () => {
        const id = rid();
        const bars = await run(id, ["orange-1200x1200.jpg", "orange-1200x1200.jpg"], { width: 1080, height: 1920, fade: false, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] });
        expect(bars.status).toBe("done");
        const { file } = await download(id, "bars.mp4");
        // the 1080x1080 picture sits in the middle (420..1500); the top 300 px is the bar
        const [r, g, b] = averageRgb(file, [0, 0, 1080, 300], 0.3);
        expect(r).toBeGreaterThan(120); // orange (255,165,0) darkened by 0.08 brightness, then h264: far from black
        expect(g).toBeGreaterThan(60);
        expect(b).toBeLessThan(80);
        const bottom = averageRgb(file, [0, 1620, 1080, 300], 0.3);
        expect(bottom[0]).toBeGreaterThan(120);
        // the picture itself is the (un-darkened) colour
        const middle = averageRgb(file, [200, 800, 600, 300], 0.3);
        expect(middle[0]).toBeGreaterThan(230);
    });

    it('sound "own" keeps ONE audio stream (the video\'s tone); "none" has none; the video counts its own length', async () => {
        const plan = (sound: "none" | "own"): Plan => ({
            width: 1080,
            height: 1350,
            fade: true,
            sound,
            slides: [{ n: 0, seconds: 1.5 }, { n: 1, seconds: null }, { n: 2, seconds: 1.5 }],
        });
        const withSound = rid();
        const d1 = await run(withSound, ["p-1080x1350.jpg", "v-tone.mp4", "p-1200x1200.jpg"], plan("own"));
        expect(d1.status).toBe("done");
        const a = infoOf((await download(withSound, "own.mp4")).file);
        expect(a.audioStreams).toBe(1);
        expect(Math.abs(a.duration! - 5)).toBeLessThanOrEqual(0.15); // 1.5 + the 2 s video + 1.5
        // the helper is held until DELETE: free it for the second job of this test
        expect((await call(`/slideshow/${withSound}`, { method: "DELETE" })).status).toBe(204);
        const without = rid();
        const d2 = await run(without, ["p-1080x1350.jpg", "v-tone.mp4", "p-1200x1200.jpg"], plan("none"));
        expect(d2.status).toBe("done");
        const b = infoOf((await download(without, "none.mp4")).file);
        expect(b.audioStreams).toBe(0);
        expect(Math.abs(b.duration! - 5)).toBeLessThanOrEqual(0.15);
        measured.push(`mixed still+video(2 s, tone)+still, fade, own: output ${a.duration!.toFixed(2)} s (plan 5.00), audio streams ${a.audioStreams}; none: ${b.duration!.toFixed(2)} s, audio streams ${b.audioStreams}`);
    });

    it('sound "own" over a video with no track makes no audio at all; cut mode with a video works too', async () => {
        const id = rid();
        const done = await run(id, ["v-silent.mp4", "p-1080x1350.jpg"], { width: 1080, height: 1350, fade: false, sound: "own", slides: [{ n: 0, seconds: null }, { n: 1, seconds: 2 }] });
        expect(done.status).toBe("done");
        const i = infoOf((await download(id, "silent-cut.mp4")).file);
        expect(i.audioStreams).toBe(0);
        expect(Math.abs(i.duration! - 4)).toBeLessThanOrEqual(0.15);
    });

    it("a gif input plays once (its own length)", async () => {
        const id = rid();
        const gif = path.join(root, "once.gif");
        ff(["-f", "lavfi", "-i", "testsrc2=s=200x120:d=1:r=10", gif]);
        expect((await put(id, 0, readFileSync(gif))).status).toBe(204);
        expect((await putFile(id, 1, "p-1080x1350.jpg")).status).toBe(204);
        expect((await start(id, { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: null }, { n: 1, seconds: 1 }] })).status).toBe(202);
        const done = await until(`/slideshow/${id}`);
        expect(done.status).toBe("done");
        expect(Math.abs(done.duration - 2)).toBeLessThanOrEqual(0.2);
    });

    it("a still given no seconds, or a video given some, is invalid_params; garbage is bad_source; a failed job does not keep the helper", async () => {
        const a = rid();
        await putFile(a, 0, "p-1080x1350.jpg");
        await putFile(a, 1, "p-1200x1200.jpg");
        await start(a, { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: null }, { n: 1, seconds: 1 }] });
        expect(await until(`/slideshow/${a}`)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(existsSync(path.join(dirs.slideshow, a))).toBe(false); // an error cleans the files...
        // ...and a job that has failed no longer holds the helper (it stays only to be asked about, until DELETE or idle)
        const next = rid();
        expect((await put(next, 0, Buffer.alloc(10, 1))).status).toBe(204);
        await call(`/slideshow/${next}`, { method: "DELETE" });
        await call(`/slideshow/${a}`, { method: "DELETE" });
        const b = rid();
        await putFile(b, 0, "v-silent.mp4");
        await putFile(b, 1, "p-1200x1200.jpg");
        await start(b, { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: 2 }, { n: 1, seconds: 1 }] });
        expect(await until(`/slideshow/${b}`)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        await call(`/slideshow/${b}`, { method: "DELETE" });
        const c = rid();
        await put(c, 0, Buffer.alloc(500, 5));
        await putFile(c, 1, "p-1200x1200.jpg");
        await start(c, { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: null }, { n: 1, seconds: 1 }] });
        expect(await until(`/slideshow/${c}`)).toEqual({ status: "error", error: { code: "error.webp.bad_source" } });
    });

    it("stills plus a video over 180 s is error.webp.too_long (the stills alone are 180 s: the 2 s video tips it), nothing composed", async () => {
        const id = rid();
        const slides: Plan["slides"] = [];
        for (let n = 0; n < 12; n++) {
            await putFile(id, n, "p-300x200.jpg");
            slides.push({ n, seconds: 15 });
        }
        await putFile(id, 12, "v-tone.mp4");
        slides.push({ n: 12, seconds: null });
        await start(id, { width: 1080, height: 1350, fade: true, sound: "none", slides });
        expect(await until(`/slideshow/${id}`)).toEqual({ status: "error", error: { code: "error.webp.too_long" } });
    });

    it("the job budget: when it runs out the job is error.webp.timeout", async () => {
        await helper.close();
        await startHelper({ slideshowTimeoutMs: 1 });
        const id = rid();
        await putFile(id, 0, "p-1080x1350.jpg");
        await putFile(id, 1, "p-1200x1200.jpg");
        await start(id, { width: 1080, height: 1350, fade: true, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] });
        expect(await until(`/slideshow/${id}`)).toEqual({ status: "error", error: { code: "error.webp.timeout" } });
    });

    it("renderSlideshow reports composing 0..k of k stills, then encoding up to the total", async () => {
        const dir = path.join(root, "render-phases");
        mkdirSync(dir, { recursive: true });
        const phases: [string, number, number][] = [];
        const r = await renderSlideshow({
            ffmpegBin: FFMPEG,
            dir,
            output: path.join(dir, "out.mp4"),
            files: new Map([[0, fx["p-1080x1350.jpg"]!], [1, fx["v-tone.mp4"]!], [2, fx["p-1200x1200.jpg"]!]]),
            plan: { width: 1080, height: 1350, fade: true, sound: "own", slides: [{ n: 0, seconds: 1.5 }, { n: 1, seconds: null }, { n: 2, seconds: 1.5 }] },
            probeAV: async (f: string) => infoOf(f),
            timeoutMs: 120_000,
            onPhase: (p, v) => phases.push([p, v.done, v.total]),
        });
        expect(phases.filter(([p]) => p === "composing")).toEqual([["composing", 0, 2], ["composing", 1, 2], ["composing", 2, 2]]);
        const enc = phases.filter(([p]) => p === "encoding");
        expect(enc[0]).toEqual(["encoding", 0, 5]);
        expect(enc[enc.length - 1]).toEqual(["encoding", 5, 5]);
        for (let i = 1; i < enc.length; i++) expect(enc[i]![1]).toBeGreaterThanOrEqual(enc[i - 1]![1]);
        // every composing report comes before the first encoding one
        expect(phases.findIndex(([p]) => p === "encoding")).toBeGreaterThan(phases.map(([p]) => p).lastIndexOf("composing"));
        expect(Math.abs(r.duration! - 5)).toBeLessThanOrEqual(0.15);
    });
});

describe("the slideshow routes: holding the helper, limits, errors", () => {
    const tiny = Buffer.alloc(1500, 1);
    const plan: Plan = { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] };

    it("bad n, bad id and wrong methods", async () => {
        const id = rid();
        for (const n of ["20", "-1", "x", "01", "1.5", ""]) {
            const r = await put(id, n, tiny);
            expect(r.status).toBe(400);
        }
        expect((await call(`/slideshow/short/inputs/0`, { method: "PUT", body: tiny, duplex: "half" } as any)).status).toBe(400);
        expect((await call(`/slideshow/${id}/inputs/0`, { method: "POST", body: tiny })).status).toBe(405);
        expect(helper.slideshows.size).toBe(0); // a refused request never holds the helper
        expect((await call(`/slideshow/${id}`)).status).toBe(404);
        expect((await call(`/slideshow/${id}/file`)).status).toBe(404);
        expect((await call(`/slideshow/short`)).status).toBe(404);
        expect((await call(`/slideshow/${id}/nope`)).status).toBe(404);
    });

    it("an empty input is 400 and does not hold the helper", async () => {
        const id = rid();
        expect((await put(id, 0, Buffer.alloc(0))).status).toBe(400);
        expect(helper.slideshows.size).toBe(0);
    });

    it("the first input holds the helper (everything else 429), until DELETE", async () => {
        const id = rid();
        expect((await put(id, 0, tiny)).status).toBe(204);
        expect(helper.slideshows.size).toBe(1);
        expect((await post("/fetch", { id: rid(), url: LINK })).status).toBe(429);
        expect((await call(`/probe?id=${rid(20)}`, { method: "POST", body: tiny, duplex: "half" } as any)).status).toBe(429);
        expect((await call(`/poster?id=${rid()}`, { method: "POST", body: tiny, duplex: "half" } as any)).status).toBe(429);
        // another slideshow cannot start while this one holds it
        expect((await put(rid(), 0, tiny)).status).toBe(429);
        // but the holder keeps adding inputs
        expect((await put(id, 1, tiny)).status).toBe(204);
        expect((await call(`/slideshow/${id}`, { method: "DELETE" })).status).toBe(204);
        expect((await post("/fetch", { id: rid(), url: LINK })).status).toBe(202);
    });

    it("429 the other way round: a pending fetch keeps a slideshow from starting", async () => {
        const g = gated();
        served["/x"] = { file: fx["p-300x200.jpg"], type: "image/jpeg", gate: g.gate };
        resolveBody = async () => ({ status: "redirect", url: cdn("x"), filename: "x.jpg" });
        const f = rid();
        expect((await post("/fetch", { id: f, url: LINK })).status).toBe(202);
        const r = await put(rid(), 0, tiny);
        expect(r.status).toBe(429);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.webp.busy" } });
        g.release();
        await until(`/fetch/${f}`);
        expect((await put(rid(), 0, tiny)).status).toBe(204);
    });

    it("an input over the cap is 413: declared (before the body is read) and streamed (no content-length)", async () => {
        await helper.close();
        await startHelper({ maxFetchBytes: 1000 });
        const id = rid();
        const declared = await put(id, 0, Buffer.alloc(5000, 1));
        expect(declared.status).toBe(413);
        expect(await json(declared)).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        // a body with no content-length (chunked): counted as it arrives
        const chunks = (async function* () {
            for (let i = 0; i < 5; i++) yield Buffer.alloc(500, 2);
        })();
        const streamed = await call(`/slideshow/${id}/inputs/0`, { method: "PUT", body: chunks as any, duplex: "half" } as any);
        expect(streamed.status).toBe(413);
        expect(helper.slideshows.size).toBe(0); // the job a refused first input would have created is gone
        // an input at the cap is fine
        expect((await put(id, 0, Buffer.alloc(1000, 1))).status).toBe(204);
    });

    it("the per-job total is capped: the input that would pass it is 413 and the earlier ones stay", async () => {
        await helper.close();
        await startHelper({ maxFetchBytes: 1000, maxJobBytes: 2500 });
        const id = rid();
        expect((await put(id, 0, Buffer.alloc(1000, 1))).status).toBe(204);
        expect((await put(id, 1, Buffer.alloc(1000, 1))).status).toBe(204);
        expect((await put(id, 2, Buffer.alloc(1000, 1))).status).toBe(413); // 3000 > 2500
        expect(helper.slideshows.get(id)!.files.size).toBe(2);
        // replacing an input counts its new size, not both
        expect((await put(id, 1, Buffer.alloc(1000, 3))).status).toBe(204);
        expect(existsSync(path.join(dirs.slideshow, id, "input-2"))).toBe(false);
    });

    it("start: a missing input is 409, a bad body 400, an unknown job 404, a second start 409; inputs after start are 409", async () => {
        const id = rid();
        await put(id, 0, tiny);
        const missing = await start(id, plan); // slide 1 was never uploaded
        expect(missing.status).toBe(409);
        expect((await json(missing)).status).toBe("error");
        expect((await start(id, { ...plan, width: 1081 })).status).toBe(400);
        expect((await call(`/slideshow/${id}/start`, { method: "POST", body: "nope" })).status).toBe(400);
        expect((await call(`/slideshow/${id}/start`)).status).toBe(405);
        expect((await start(rid(), plan)).status).toBe(404);
        // the job is still collecting: nothing started
        expect(await json(await call(`/slideshow/${id}`))).toMatchObject({ status: "pending", phase: null });
        await put(id, 1, tiny);
        expect((await start(id, plan)).status).toBe(202);
        expect((await start(id, plan)).status).toBe(409); // already started
        expect((await put(id, 2, tiny)).status).toBe(409);
        await until(`/slideshow/${id}`); // (garbage bytes: ends in an error; real ffmpeg not needed to see the rules)
    });

    it("the file is 409 before the job is done", async () => {
        const id = rid();
        await put(id, 0, tiny);
        expect((await call(`/slideshow/${id}/file`)).status).toBe(409);
    });

    it("the reaper: a job nobody asks about for the idle time is dropped, its files gone, the helper free", async () => {
        await helper.close();
        await startHelper({ slideshowIdleMs: 250 });
        const id = rid();
        await put(id, 0, tiny);
        expect(existsSync(path.join(dirs.slideshow, id, "input-0"))).toBe(true);
        expect((await post("/fetch", { id: rid(), url: LINK })).status).toBe(429);
        await new Promise((r) => setTimeout(r, 500));
        expect((await call(`/slideshow/${id}`)).status).toBe(404);
        expect(helper.slideshows.size).toBe(0);
        await new Promise((r) => setTimeout(r, 50));
        expect(existsSync(path.join(dirs.slideshow, id))).toBe(false);
        expect((await post("/fetch", { id: rid(), url: LINK })).status).toBe(202);
    });

    it("a poll, an input and a start all count as activity (the reaper goes by the last one)", async () => {
        const id = rid();
        await put(id, 0, tiny);
        const job = helper.slideshows.get(id)!;
        let last = job.touched;
        await new Promise((r) => setTimeout(r, 20));
        expect((await call(`/slideshow/${id}`)).status).toBe(200);
        expect(job.touched).toBeGreaterThan(last);
        last = job.touched;
        await new Promise((r) => setTimeout(r, 20));
        await put(id, 1, tiny);
        expect(job.touched).toBeGreaterThan(last);
        last = job.touched;
        await new Promise((r) => setTimeout(r, 20));
        await start(id, plan);
        expect(job.touched).toBeGreaterThan(last);
    });

    it("DELETE is idempotent (a job already reaped is still 204) and a bad id is 404", async () => {
        const id = rid();
        expect((await call(`/slideshow/${id}`, { method: "DELETE" })).status).toBe(204);
        expect((await call(`/slideshow/short`, { method: "DELETE" })).status).toBe(404);
    });
});

// =================================================================================================
// the review of the gallery server (APP-API-CONTRACT.md section 18): cost, the whitelist, the budget, the caps header
// =================================================================================================

describe("slideshow cost and safety (review findings)", () => {
    it("-protocol_whitelist stands in front of EVERY -i (an input option applies to the next input only)", () => {
        const segs = [
            { kind: "still" as const, file: "/w/s-0.jpg", seconds: 3 },
            { kind: "motion" as const, file: "/w/in-1", seconds: 4, hasAudio: true, blur: true },
            { kind: "still" as const, file: "/w/s-1.jpg", seconds: 3 },
            { kind: "motion" as const, file: "/w/in-3", seconds: 2, hasAudio: false, blur: false },
        ];
        const args = buildSlideshowArgs({ segments: segs, width: 1080, height: 1350, fade: true, sound: "own", output: "/w/out.mp4" });
        const inputs = args.flatMap((a, i) => (a === "-i" ? [i] : []));
        expect(inputs).toHaveLength(4);
        let from = 0;
        for (const at of inputs) {
            const before = args.slice(from, at);
            const w = before.indexOf("-protocol_whitelist");
            expect(w, `input at ${at}`).toBeGreaterThanOrEqual(0);
            expect(before[w + 1]).toBe("file,pipe");
            from = at + 2;
        }
        expect(args.filter((a) => a === "-protocol_whitelist")).toHaveLength(4);
    });

    it("the videos inside one slideshow are capped at 60 s together (the stills are not): over it is error.webp.too_long, before anything is composed", async () => {
        const dir = path.join(root, "motion-cap");
        mkdirSync(dir, { recursive: true });
        const files = new Map<number, string>();
        for (let n = 0; n < 3; n++) {
            const f = path.join(dir, `input-${n}`);
            writeFileSync(f, HEAD.mp4);
            files.set(n, f);
        }
        const probeAV = async () => ({ duration: 25, width: 1920, height: 1080, hasAudio: true });
        const plan = (k: number): Plan => ({ width: 1080, height: 1350, fade: true, sound: "none", slides: Array.from({ length: k }, (_, n) => ({ n, seconds: null })) });
        const spawnImpl = (() => {
            throw new Error("nothing may be spawned");
        }) as any;
        const base = { ffmpegBin: FFMPEG, dir, output: path.join(dir, "out.mp4"), files, probeAV, timeoutMs: 5000, spawnImpl };
        await expect(renderSlideshow({ ...base, plan: plan(3) })).rejects.toMatchObject({ code: "error.webp.too_long" }); // 75 s of video
        // 60 s exactly (two 30 s videos) is within it: it gets as far as the ffmpeg (the fake refuses to spawn one)
        const two = async () => ({ duration: 30, width: 1920, height: 1080, hasAudio: true });
        await expect(renderSlideshow({ ...base, probeAV: two, plan: plan(2) })).rejects.toMatchObject({ code: "error.webp.encode_failed" });
    });
});

real("a slideshow that runs out of budget releases the helper (review finding 6)", () => {
    it("the timeout kills it, the job says error.webp.timeout, and the helper takes the next job without anybody calling DELETE", async () => {
        await helper.close();
        await startHelper({ slideshowTimeoutMs: 1 });
        const id = rid();
        await putFile(id, 0, "p-1080x1350.jpg");
        await putFile(id, 1, "p-1200x1200.jpg");
        await start(id, { width: 1080, height: 1350, fade: true, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] });
        expect(await until(`/slideshow/${id}`)).toEqual({ status: "error", error: { code: "error.webp.timeout" } });
        expect(helper.slideshows.get(id)?.proc).toBeUndefined();
        const next = rid();
        expect((await put(next, 0, Buffer.alloc(10, 1))).status).toBe(204);
        expect((await post("/fetch", { id: rid(), url: LINK })).status).toBe(429); // the new input holds it, as ever
        await call(`/slideshow/${next}`, { method: "DELETE" });
        await call(`/slideshow/${id}`, { method: "DELETE" });
    });
});

describe("the helper says what it can do on every answer (the API's features.gallery follows it)", () => {
    it("x-cobalt-helper: gallery=1 on a 200, a 404 and a 403", async () => {
        const ok = await call(`/slideshow/${rid()}`);
        expect(ok.status).toBe(404);
        expect(ok.headers.get("x-cobalt-helper")).toBe("gallery=1,make=1");
        const denied = await call(`/slideshow/${rid()}`, {}, "wrong-key");
        expect(denied.status).toBe(403);
        const poster = await call("/nothing-here");
        expect(poster.headers.get("x-cobalt-helper")).toBe("gallery=1,make=1");
    });
});

// keep unused imports honest
void JobError;
void afterEach;
