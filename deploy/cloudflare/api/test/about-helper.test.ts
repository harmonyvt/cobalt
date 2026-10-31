// The helper's POST /about (APP-API-CONTRACT.md section 34.2): three frames and the sound of a video the Durable Object
// streams in, with the REAL ffmpeg (skipped when none is found: set FFMPEG_PATH or have `ffmpeg` on the PATH; the image
// uses ffmpeg-static). Clips with a tone, with digital silence and with no audio stream are made here with lavfi; the
// fixtures in test/fixtures have no sound.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createHelper } from "../helper/server.js";
import { ABOUT_AUDIO_SECONDS, ABOUT_FRAME_SIDE, aboutTimes, buildAboutAudioArgs, parseMeanVolume } from "../helper/lib.js";

const KEY = "internal-key";
const ID = "aB3dE6gH9jK2mN5pQ8sTuV";
const FIX = fileURLToPath(new URL("./fixtures/", import.meta.url));
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const hasMp3 = hasFfmpeg && /libmp3lame/.test(spawnSync(FFMPEG, ["-hide_banner", "-encoders"]).stdout?.toString() ?? "");

const root = mkdtempSync(path.join(tmpdir(), "about-helper-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function jpegSize(buf: Buffer): { w: number; h: number } {
    expect(buf[0]).toBe(0xff);
    expect(buf[1]).toBe(0xd8);
    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    let i = 2;
    while (i < buf.length) {
        const marker = buf[i + 1]!;
        const len = view.getUint16(i + 2);
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) return { h: view.getUint16(i + 5), w: view.getUint16(i + 7) };
        i += 2 + len;
    }
    throw new Error("no SOF marker");
}

// lavfi clips: 6 s of test picture with a 440 Hz tone, with digital silence, and a portrait one with speech-level noise
const clips: Record<string, string> = {};
function make(name: string, args: string[]) {
    const out = path.join(root, name);
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", ...args, "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-y", out]);
    if (r.status !== 0) throw new Error(`could not make ${name}: ${r.stderr}`);
    clips[name] = out;
}
beforeAll(() => {
    if (!hasFfmpeg) return;
    make("tone.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=6", "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-shortest"]);
    make("silent.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=6", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "6"]);
});

let helper: ReturnType<typeof createHelper>;
let base: string;
let aboutDir: string;
async function start(over: Record<string, unknown> = {}) {
    const id = Math.random().toString(36).slice(2);
    aboutDir = path.join(root, id, "about");
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "webp"),
        fetchDir: path.join(root, id, "fetch"),
        probeDir: path.join(root, id, "probe"),
        posterDir: path.join(root, id, "poster"),
        aboutDir,
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        ...over,
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
}
afterEach(() => helper?.close());

const about = (body: BodyInit, id = ID, key: string | null = KEY) =>
    fetch(`${base}/about?id=${id}`, {
        method: "POST",
        body,
        headers: { "content-type": "application/octet-stream", ...(key === null ? {} : { "x-internal-key": key }) },
        duplex: "half",
    } as RequestInit);
const left = () => (existsSync(aboutDir) ? readdirSync(aboutDir) : []);

describe("the about frames and sound (pure)", () => {
    it("15 %, 50 % and 85 %; the middle of a clip under 2 s; the start when the duration is unknown", () => {
        expect(aboutTimes(10)).toEqual([1.5, 5, 8.5]);
        expect(aboutTimes(2)).toEqual([0.3, 1, 1.7]);
        expect(aboutTimes(1.5)).toEqual([0.75]);
        for (const bad of [null, undefined, 0, -1, NaN, Infinity]) expect(aboutTimes(bad as any)).toEqual([0]);
    });
    it("the sound: the first 600 s (section 47), first audio stream, mono 16 kHz MP3 at 32 kbit/s, loudness measured, local files only", () => {
        const a = buildAboutAudioArgs({ input: "/in", output: "/out.mp3" });
        expect(a[a.indexOf("-t") + 1]).toBe(String(ABOUT_AUDIO_SECONDS));
        expect(ABOUT_AUDIO_SECONDS).toBe(600);
        expect(a[a.indexOf("-map") + 1]).toBe("0:a:0");
        expect(a[a.indexOf("-ac") + 1]).toBe("1");
        expect(a[a.indexOf("-ar") + 1]).toBe("16000");
        expect(a[a.indexOf("-b:a") + 1]).toBe("32k");
        expect(a[a.indexOf("-c:a") + 1]).toBe("libmp3lame");
        expect(a[a.indexOf("-af") + 1]).toBe("volumedetect");
        expect(a[a.indexOf("-protocol_whitelist") + 1]).toBe("file,pipe");
        expect(a.at(-1)).toBe("/out.mp3");
    });
    it("reads volumedetect's mean volume", () => {
        expect(parseMeanVolume("[Parsed_volumedetect_0 @ 0x1] mean_volume: -20.5 dB\n[..] max_volume: -3.0 dB")).toBe(-20.5);
        expect(parseMeanVolume("mean_volume: -91.0 dB")).toBe(-91);
        expect(parseMeanVolume("mean_volume: -inf dB")).toBe(-Infinity);
        expect(parseMeanVolume("nothing")).toBeNull();
    });
});

describe.skipIf(!hasFfmpeg)("POST /about with the real ffmpeg", { timeout: 90_000 }, () => {
    beforeEach(() => start());

    it.skipIf(!hasMp3)("a clip with sound: three upright JPEG frames and an MP3, the duration, and nothing left on disk", async () => {
        const res = await about(readFileSync(clips["tone.mp4"]!));
        expect(res.status).toBe(200);
        const b = (await res.json()) as any;
        expect(b.frames).toHaveLength(3);
        for (const f of b.frames) expect(jpegSize(Buffer.from(f, "base64"))).toEqual({ w: 640, h: 360 });
        // three different moments of the clip
        expect(new Set(b.frames).size).toBe(3);
        const mp3 = Buffer.from(b.audio, "base64");
        expect(mp3.length).toBeGreaterThan(1000);
        expect(mp3.length).toBeLessThan(6 * 4000 + 2000); // 32 kbit/s
        expect((mp3[0] === 0x49 && mp3[1] === 0x44 && mp3[2] === 0x33) || (mp3[0] === 0xff && (mp3[1]! & 0xe0) === 0xe0)).toBe(true);
        const probe = spawnSync(FFMPEG, ["-hide_banner", "-f", "mp3", "-i", "pipe:0"], { input: mp3 }).stderr.toString();
        expect(probe).toMatch(/Audio: mp3.*16000 Hz, mono/);
        expect(b.duration).toBeCloseTo(6, 0);
        expect(left()).toEqual([]);
    });

    it("digital silence and no audio stream both answer audio: null", async () => {
        const silent = (await (await about(readFileSync(clips["silent.mp4"]!))).json()) as any;
        expect(silent.frames).toHaveLength(3);
        expect(silent.audio).toBeNull();
        const none = (await (await about(readFileSync(FIX + "clip-landscape.mp4"))).json()) as any;
        expect(none.frames).toHaveLength(3);
        expect(none.audio).toBeNull();
    });

    it("a long side over 768 is scaled down; a short gif gives one frame", async () => {
        const big = (await (await about(readFileSync(FIX + "clip-1080p.mp4"))).json()) as any;
        for (const f of big.frames) expect(jpegSize(Buffer.from(f, "base64"))).toEqual({ w: ABOUT_FRAME_SIDE, h: 432 });
        const rotated = (await (await about(readFileSync(FIX + "clip-rotated.mp4"))).json()) as any;
        expect(jpegSize(Buffer.from(rotated.frames[0], "base64"))).toEqual({ w: 360, h: 640 });
        const gif = (await (await about(readFileSync(FIX + "clip.gif"))).json()) as any;
        expect(gif.frames).toHaveLength(1);
        expect(gif.audio).toBeNull();
    });

    it("refuses what is not a video (400), an empty body, a bad id, a wrong key; one job at a time", async () => {
        const text = await about("just some text, not a video at all");
        expect(text.status).toBe(400);
        expect(((await text.json()) as any).error.code).toBe("error.studio.not_video");
        expect((await about("")).status).toBe(400);
        expect((await about("x", "bad id!")).status).toBe(400);
        expect((await about("x", ID, "nope")).status).toBe(403);
        expect((await fetch(`${base}/about?id=${ID}`, { headers: { "x-internal-key": KEY } })).status).toBe(405);
        // while one runs, another is refused
        const slow = new ReadableStream({
            async start(c) {
                c.enqueue(new Uint8Array(10));
                await new Promise((r) => setTimeout(r, 300));
                c.close();
            },
        });
        const first = about(slow as any);
        await new Promise((r) => setTimeout(r, 100));
        const second = await about("y", `${ID}2`);
        expect(second.status).toBe(429);
        expect((await first).status).toBe(400);
        expect(left()).toEqual([]);
    });

    it("a hung ffmpeg is cut at the wall time and answers 422", async () => {
        const sleeper = path.join(root, "sleepy-ffmpeg.sh");
        const { writeFileSync, chmodSync } = await import("node:fs");
        // stands in for ffmpeg: the probe (no output file) answers like ffmpeg does, a frame cut hangs
        writeFileSync(sleeper, `#!/bin/sh\ncase "$*" in *-frames:v*) exec sleep 30;; *) echo "Stream #0:0: Video: h264, yuv420p, 640x360" >&2; echo "Duration: 00:00:06.00" >&2; exit 1;; esac\n`);
        chmodSync(sleeper, 0o755);
        helper.close();
        await start({ ffmpegPath: () => sleeper, aboutTimeoutMs: 500 });
        const t0 = Date.now();
        const res = await about(readFileSync(FIX + "clip-landscape.mp4"));
        expect(res.status).toBe(422);
        expect(((await res.json()) as any).error.code).toBe("error.about.failed");
        expect(Date.now() - t0).toBeLessThan(5_000);
        expect(left()).toEqual([]);
    });
});
