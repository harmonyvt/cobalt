// Animated WebP for the safety clip. The container ffmpeg decodes a still WebP and skips ANIM/ANMF, so
// POST /safety composes the frames into JPEGs. A file that still will not decode stays error.safety.failed.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { createHelper } from "../helper/server.js";
import { SAFETY_MAX_STILLS } from "../src/about-store";
import { animateStill } from "../helper/lib.js";
import { SAFETY_WEBP_STILLS, drawFrame, sampleStillIndexes } from "../helper/webp-anim.js";

const KEY = "internal-key";
const ID = "SafetyWebpStill01";
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const hasAnim = hasFfmpeg && /libwebp_anim/.test(spawnSync(FFMPEG, ["-hide_banner", "-encoders"]).stdout?.toString() ?? "");

const root = mkdtempSync(path.join(tmpdir(), "safety-webp-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function webp(name: string, args: string[]) {
    const out = path.join(root, name);
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", ...args, out], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
    return readFileSync(out);
}

let helper: ReturnType<typeof createHelper>;
let base: string;
async function start() {
    const id = Math.random().toString(36).slice(2);
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "webp"),
        fetchDir: path.join(root, id, "fetch"),
        probeDir: path.join(root, id, "probe"),
        posterDir: path.join(root, id, "poster"),
        aboutDir: path.join(root, id, "about"),
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as { port: number }).port}`;
}
afterEach(() => helper?.close());

const safety = (body: BodyInit, kind: "still" | "clip", id = ID) =>
    fetch(`${base}/safety?id=${id}&kind=${kind}`, {
        method: "POST",
        body,
        headers: { "content-type": "application/octet-stream", "x-internal-key": KEY },
        duplex: "half",
    } as RequestInit);

function chunk(fourcc: string, payload: Buffer) {
    const head = Buffer.alloc(8);
    head.write(fourcc, 0, "latin1");
    head.writeUInt32LE(payload.length, 4);
    return Buffer.concat([head, payload, payload.length & 1 ? Buffer.alloc(1) : Buffer.alloc(0)]);
}

// VP8X animation flag and ANMF frames whose bitstreams are not WebP. ffmpeg cannot decode them.
function brokenAnimatedWebp() {
    const vp8x = Buffer.alloc(10);
    vp8x[0] = 0x02;
    vp8x.writeUIntLE(63, 4, 3);
    vp8x.writeUIntLE(63, 7, 3);
    const anim = Buffer.alloc(6);
    const anmf = Buffer.alloc(17);
    anmf.writeUIntLE(100, 12, 3);
    const body = Buffer.concat([Buffer.from("WEBP", "latin1"), chunk("VP8X", vp8x), chunk("ANIM", anim), chunk("ANMF", anmf)]);
    const riff = Buffer.alloc(8);
    riff.write("RIFF", 0, "latin1");
    riff.writeUInt32LE(body.length, 4);
    return Buffer.concat([riff, body]);
}

const mean = (jpeg: Buffer) => {
    const r = spawnSync(FFMPEG, ["-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], {
        input: jpeg,
    });
    const b = r.stdout as Buffer;
    let rSum = 0;
    let gSum = 0;
    let bSum = 0;
    const n = Math.floor(b.length / 3);
    for (let i = 0; i < n; i++) {
        rSum += b[i * 3]!;
        gSum += b[i * 3 + 1]!;
        bSum += b[i * 3 + 2]!;
    }
    return [rSum / n, gSum / n, bSum / n];
};

describe("which frames of an animated webp Clef sees", () => {
    it("keeps the still cap, and spreads a long loop from the first frame to the last", () => {
        expect(SAFETY_WEBP_STILLS).toBe(SAFETY_MAX_STILLS);
        expect(sampleStillIndexes([{ duration: 100 }], 4)).toEqual([0]);
        expect(sampleStillIndexes([{ duration: 40 }, { duration: 40 }, { duration: 40 }], 4)).toEqual([0, 1, 2]);
        const frames = Array.from({ length: 8 }, () => ({ duration: 100 }));
        const picked = sampleStillIndexes(frames, 4);
        expect(picked[0]).toBe(0);
        expect(picked[picked.length - 1]).toBe(7);
        expect(picked.length).toBeLessThanOrEqual(4);
        expect(new Set(picked).size).toBe(picked.length);
    });

    it("blends a frame over the canvas and replaces when the frame says so", () => {
        const c = new Uint8Array(2 * 1 * 4);
        c.set([0, 0, 255, 255, 0, 0, 255, 255]);
        drawFrame(c, 2, { x: 0, y: 0, w: 2, h: 1, duration: 100, blend: true, dispose: false, chunks: Buffer.alloc(0) }, new Uint8Array([255, 0, 0, 128, 255, 0, 0, 0]));
        expect([...c]).toEqual([128, 0, 127, 255, 0, 0, 255, 255]);
    });
});

describe("POST /safety and an animated webp", () => {
    it("fails closed when the frames are not decodable", async () => {
        await start();
        const res = await safety(brokenAnimatedWebp(), "still");
        expect(res.status).toBe(422);
        expect(((await res.json()) as { error: { code: string } }).error.code).toBe("error.safety.failed");
    });
});

describe.skipIf(!hasFfmpeg || !hasAnim)("POST /safety composes an animated webp", { timeout: 60_000 }, () => {
    const files: Record<string, Buffer> = {};
    const cycle = "color=c=black:s=64x64:r=10:d=0.4,format=rgb24,geq=r='255*(eq(mod(N,4),0)+eq(mod(N,4),3))':g='255*(eq(mod(N,4),1)+eq(mod(N,4),3))':b='255*(eq(mod(N,4),2)+eq(mod(N,4),3))',format=rgba";

    it("kind=still and kind=clip both return a jpeg of each color, and a still webp stays one jpeg", async () => {
        files.anim = webp("anim.webp", ["-f", "lavfi", "-i", cycle, "-c:v", "libwebp_anim", "-lossless", "1", "-loop", "0"]);
        files.lossy = webp("lossy.webp", ["-f", "lavfi", "-i", "color=c=red@0.5:s=64x64:r=5:d=0.4,format=rgba,geq=r='255*lt(N,1)':g=0:b='255*gte(N,1)':a=128", "-c:v", "libwebp_anim", "-quality", "90", "-loop", "0"]);
        files.still = webp("still.webp", ["-f", "lavfi", "-i", "color=c=red:s=64x64:d=0.04", "-frames:v", "1", "-c:v", "libwebp"]);
        files.clip = webp("clip.mp4", ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=10:duration=0.4", "-c:v", "mpeg4", "-q:v", "5", "-an"]);
        const direct = spawnSync(FFMPEG, ["-hide_banner", "-loglevel", "error", "-i", path.join(root, "anim.webp"), "-frames:v", "1", "-f", "image2", "-update", "1", path.join(root, "direct.jpg")]);
        expect(direct.status).not.toBe(0);

        await start();
        const asStill = await safety(files.anim, "still");
        expect(asStill.status).toBe(200);
        const stillBody = (await asStill.json()) as { clips: string[]; stills: string[]; audio: null };
        expect(stillBody.clips).toEqual([]);
        expect(stillBody.audio).toBeNull();
        expect(stillBody.stills.length).toBe(4);
        const colors = stillBody.stills.map((s) => mean(Buffer.from(s, "base64")));
        expect(colors[0]![0]).toBeGreaterThan(200);
        expect(colors[1]![1]).toBeGreaterThan(200);
        expect(colors[2]![2]).toBeGreaterThan(200);
        expect(colors[3]![0]).toBeGreaterThan(200);
        expect(colors[3]![1]).toBeGreaterThan(200);
        expect(new Set(stillBody.stills).size).toBe(4);

        const asClip = await safety(files.anim, "clip", `${ID}b`);
        expect(asClip.status).toBe(200);
        const clipBody = (await asClip.json()) as { clips: string[]; stills: string[] };
        expect(clipBody.clips).toEqual([]);
        expect(clipBody.stills.length).toBe(4);

        const photo = await safety(files.still, "still", `${ID}c`);
        expect(photo.status).toBe(200);
        const photoBody = (await photo.json()) as { clips: string[]; stills: string[] };
        expect(photoBody.clips).toEqual([]);
        expect(photoBody.stills).toHaveLength(1);
        expect(Buffer.from(photoBody.stills[0]!, "base64").subarray(0, 2).toString("hex")).toBe("ffd8");

        const wrapped = animateStill(files.still, 2000);
        expect(wrapped).not.toBeNull();
        const favourite = await safety(wrapped!, "still", `${ID}d`);
        expect(favourite.status).toBe(200);
        const favBody = (await favourite.json()) as { stills: string[] };
        expect(favBody.stills.length).toBeGreaterThan(0);
        expect(favBody.stills.length).toBeLessThanOrEqual(SAFETY_WEBP_STILLS);

        const lossy = await safety(files.lossy, "still", `${ID}f`);
        expect(lossy.status).toBe(200);
        const lossyBody = (await lossy.json()) as { stills: string[] };
        expect(lossyBody.stills.length).toBeGreaterThan(0);
        expect(lossyBody.stills.length).toBeLessThanOrEqual(SAFETY_WEBP_STILLS);
        const lossyRgb = lossyBody.stills.map((s) => mean(Buffer.from(s, "base64")));
        expect(lossyRgb[0]![0]).toBeGreaterThan(lossyRgb[0]![2]!);
        expect(lossyRgb[lossyRgb.length - 1]![2]).toBeGreaterThan(lossyRgb[lossyRgb.length - 1]![0]!);

        const motion = await safety(files.clip, "clip", `${ID}e`);
        expect(motion.status).toBe(200);
        const motionBody = (await motion.json()) as { clips: string[]; stills: string[] };
        expect(motionBody.stills).toEqual([]);
        expect(Buffer.from(motionBody.clips[0]!, "base64").subarray(4, 8).toString()).toBe("ftyp");
    });
});
