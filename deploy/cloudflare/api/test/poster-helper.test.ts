// The helper's POST /poster (APP-API-CONTRACT.md section 13): one JPEG frame out of a video the
// Durable Object streams in. Two halves:
//  - the REAL ffmpeg over the fixture videos in test/fixtures (skipped when no ffmpeg is found:
//    set FFMPEG_PATH, or have `ffmpeg` on the PATH; the container image uses ffmpeg-static):
//      clip-landscape.mp4  640x360, 3 s        clip-1080p.mp4   1920x1080, 2 s (scaled down to 720)
//      clip-portrait.mp4   360x640, 2 s        clip-rotated.mp4 640x360 + a 90 degree display
//                                                               matrix, so it shows as 360x640
//      clip.gif            200x120, 1 s        clip-colors.mp4  64x64, 20 s: red for second 0, green
//                                                               for 1, blue for 2 ... (the frame time)
//    made with `ffmpeg -f lavfi -i testsrc2=...` / `-display_rotation 90 -c copy` / `geq` (see git log);
//  - a scripted ffmpeg stand-in, for the failure paths (nothing at the seek point, a hung process,
//    an oversized file) and the helper's rules (one job at a time, cleanup, size cap, auth).
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, beforeEach, describe, expect, it } from "vitest";
import { createHelper } from "../helper/server.js";
import {
    MAX_POSTER_BYTES,
    POSTER_MAX_AT_SECONDS,
    POSTER_MAX_SIDE,
    buildPosterArgs,
    posterTime,
} from "../helper/lib.js";

const KEY = "internal-key";
const PID = "aB3dE6gH9jK2mN5pQ8sTuV";
const FIX = fileURLToPath(new URL("./fixtures/", import.meta.url));
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;

const root = mkdtempSync(path.join(tmpdir(), "poster-helper-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// width x height from the JPEG's start-of-frame marker
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

// the average colour of a JPEG, through ffmpeg itself (1x1 scale)
function averageRgb(jpeg: Buffer): [number, number, number] {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], {
        input: jpeg,
    });
    expect(r.status).toBe(0);
    return [r.stdout[0]!, r.stdout[1]!, r.stdout[2]!];
}

let helper: ReturnType<typeof createHelper>;
let base: string;
let dirs: { work: string; fetch: string; probe: string; poster: string };

async function start(over: Record<string, unknown> = {}) {
    const id = Math.random().toString(36).slice(2);
    dirs = {
        work: path.join(root, id, "webp"),
        fetch: path.join(root, id, "fetch"),
        probe: path.join(root, id, "probe"),
        poster: path.join(root, id, "poster"),
    };
    helper = createHelper({
        internalKey: KEY,
        workDir: dirs.work,
        fetchDir: dirs.fetch,
        probeDir: dirs.probe,
        posterDir: dirs.poster,
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        ...over,
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
}
afterEach(() => helper?.close());

const poster = (body: BodyInit, id = PID, headers: Record<string, string> = {}, key: string | null = KEY) =>
    fetch(`${base}/poster?id=${id}`, {
        method: "POST",
        body,
        headers: { "content-type": "application/octet-stream", ...(key === null ? {} : { "x-internal-key": key }), ...headers },
        duplex: "half",
    } as RequestInit);
const fixture = (name: string) => readFileSync(FIX + name);

describe("posterTime and the ffmpeg arguments (pure)", () => {
    it("10 % of the duration, at most 3 s in, 0 when the duration is not known", () => {
        expect(POSTER_MAX_AT_SECONDS).toBe(3);
        expect(posterTime(20)).toBe(2);
        expect(posterTime(2)).toBe(0.2);
        expect(posterTime(5)).toBe(0.5);
        expect(posterTime(30)).toBe(3);
        expect(posterTime(3600)).toBe(3);
        for (const bad of [null, undefined, 0, -4, NaN, Infinity, "9" as any]) expect(posterTime(bad)).toBe(0);
    });
    it("one frame, seeked on the input, local files only, longer side at most 720 and never upscaled, upright, square pixels, 4:2:0 JPEG at q 4", () => {
        const a = buildPosterArgs({ input: "/in", output: "/out.jpg", at: 1.5 });
        expect(a.slice(a.indexOf("-ss"), a.indexOf("-ss") + 4)).toEqual(["-ss", "1.5", "-i", "/in"]);
        expect(a).toContain("-frames:v");
        expect(a[a.indexOf("-frames:v") + 1]).toBe("1");
        expect(a[a.indexOf("-protocol_whitelist") + 1]).toBe("file,pipe");
        expect(a[a.indexOf("-q:v") + 1]).toBe("4");
        expect(a[a.indexOf("-vf") + 1]).toBe(
            `scale='if(gte(iw,ih),min(${POSTER_MAX_SIDE},iw),-1)':'if(gte(iw,ih),-1,min(${POSTER_MAX_SIDE},ih))':flags=lanczos,setsar=1,format=yuvj420p`,
        );
        expect(a.at(-1)).toBe("/out.jpg");
        expect(POSTER_MAX_SIDE).toBe(720);
        expect(a.slice(0, 2)).toEqual(["-nostdin", "-hide_banner"]);
    });
    it("a plain decimal even for tiny times (never 1e-7, which ffmpeg would misread)", () => {
        const a = buildPosterArgs({ input: "/in", output: "/o.jpg", at: 0.0000001 });
        expect(a[a.indexOf("-ss") + 1]).toBe("0");
    });
});

describe.skipIf(!hasFfmpeg)("POST /poster with the real ffmpeg", { timeout: 60_000 }, () => {
    beforeEach(() => start());

    it.each([
        ["clip-landscape.mp4", 640, 360, "small: not upscaled"],
        ["clip-1080p.mp4", 720, 405, "scaled down to 720 on the long side, aspect kept, square pixels"],
        ["clip-portrait.mp4", 360, 640, "portrait: the HEIGHT is the long side"],
        ["clip-rotated.mp4", 360, 640, "rotation metadata applied: it shows upright"],
        ["clip.gif", 200, 120, "a gif's first frame"],
    ])("%s -> %ix%i (%s): a real JPEG, and the helper is clean afterwards", async (file, w, h) => {
        const res = await poster(fixture(file));
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("image/jpeg");
        const jpeg = Buffer.from(await res.arrayBuffer());
        expect(Number(res.headers.get("content-length"))).toBe(jpeg.length);
        expect(jpegSize(jpeg)).toEqual({ w, h });
        expect(jpeg.at(-2)).toBe(0xff);
        expect(jpeg.at(-1)).toBe(0xd9);
        expect(jpeg.length).toBeGreaterThan(500);
        expect(jpeg.length).toBeLessThan(MAX_POSTER_BYTES);
        expect(existsSync(path.join(dirs.poster, PID))).toBe(false); // the directory is gone before the answer
    });

    it("the frame is taken at 10 % of the duration: the 20 s clip's second 2 is blue (second 0 would be red)", async () => {
        const res = await poster(fixture("clip-colors.mp4"));
        expect(res.status).toBe(200);
        const [r, g, b] = averageRgb(Buffer.from(await res.arrayBuffer()));
        expect(b).toBeGreaterThan(200);
        expect(r).toBeLessThan(60);
        expect(g).toBeLessThan(60);
    });

    it("a clip whose reported duration is longer than the video is retried at the very start instead of failing", async () => {
        helper.close();
        // the duration says 100 s (so the frame is asked for at 3 s) but the 2 s clip ends before
        await start({ probe: async () => ({ duration: 100, width: 360, height: 640 }) });
        const res = await poster(fixture("clip-portrait.mp4"));
        expect(res.status).toBe(200);
        expect(jpegSize(Buffer.from(await res.arrayBuffer()))).toEqual({ w: 360, h: 640 });
    });

    it("something that is not a video is 400 error.studio.not_video, with nothing left on disk", async () => {
        const res = await poster(Buffer.from("this is not a video at all, just text ".repeat(50)));
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_video" } });
        expect(existsSync(path.join(dirs.poster, PID))).toBe(false);
    });

    it("an empty body is not_video too", async () => {
        const res = await poster(Buffer.alloc(0));
        expect(res.status).toBe(400);
        expect(((await res.json()) as any).error.code).toBe("error.studio.not_video");
    });

    it("the helper serves one after another (the answer comes back only after cleanup)", async () => {
        for (const f of ["clip-landscape.mp4", "clip-portrait.mp4", "clip-landscape.mp4"]) {
            expect((await poster(fixture(f))).status).toBe(200);
        }
    });
});

// ---- a scripted ffmpeg ---------------------------------------------------------------------
// Node script standing in for ffmpeg. Behaviour is chosen per call from a plan file:
//   {"mode": "ok" | "nothing-at-seek" | "fail" | "hang" | "huge"} and it logs every argv.
const stub = path.join(root, "fake-ffmpeg.mjs");
const planFile = path.join(root, "plan.json");
const logFile = path.join(root, "calls.log");
writeFileSync(
    stub,
    `#!/usr/bin/env node
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2);
appendFileSync(${JSON.stringify(logFile)}, JSON.stringify(args) + "\\n");
const plan = JSON.parse(readFileSync(${JSON.stringify(planFile)}, "utf8"));
const out = args[args.length - 1];
const at = Number(args[args.indexOf("-ss") + 1]);
const jpeg = Buffer.from([0xff, 0xd8, ...new Array(200).fill(1), 0xff, 0xd9]);
if (plan.mode === "hang") setInterval(() => {}, 1000);
else if (plan.mode === "fail") { console.error("boom"); process.exit(1); }
else if (plan.mode === "nothing-at-seek" && at > 0) { console.error("Nothing was written into output file"); process.exit(234); }
else if (plan.mode === "huge") { writeFileSync(out, Buffer.alloc(${MAX_POSTER_BYTES + 10}, 1)); }
else if (plan.mode === "empty") { writeFileSync(out, Buffer.alloc(0)); }
else writeFileSync(out, jpeg);
`,
);
chmodSync(stub, 0o755);
const plan = (mode: string) => writeFileSync(planFile, JSON.stringify({ mode }));
const calls = () =>
    existsSync(logFile)
        ? readFileSync(logFile, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as string[])
        : [];

describe("POST /poster with a scripted ffmpeg", { timeout: 60_000 }, () => {
    const probeOk = async () => ({ duration: 20, width: 640, height: 360 });
    beforeEach(async () => {
        rmSync(logFile, { force: true });
        plan("ok");
        await start({ ffmpegPath: () => stub, probe: probeOk, posterTimeoutMs: 10_000 });
    });
    const at = (c: string[]) => Number(c[c.indexOf("-ss") + 1]);

    it("asks for the frame at 10 % (2 s of 20) and answers the JPEG ffmpeg wrote", async () => {
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(200);
        expect(Buffer.from(await res.arrayBuffer()).length).toBe(204);
        expect(calls().map(at)).toEqual([2]);
        const c = calls()[0]!;
        expect(c[c.indexOf("-i") + 1]).toBe(path.join(dirs.poster, PID, "in"));
        expect(c.at(-1)).toBe(path.join(dirs.poster, PID, "poster.jpg"));
    });

    it("nothing at the seek point: one more try at 0, then the answer", async () => {
        plan("nothing-at-seek");
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(200);
        expect(calls().map(at)).toEqual([2, 0]);
    });

    it("an unknown duration asks for the first frame, once", async () => {
        helper.close();
        await start({ ffmpegPath: () => stub, probe: async () => ({ duration: null, width: 640, height: 360 }) });
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(200);
        expect(calls().map(at)).toEqual([0]);
    });

    it("ffmpeg failing both times is 422 error.poster.failed", async () => {
        plan("fail");
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(422);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.poster.failed" } });
        expect(calls()).toHaveLength(2);
        expect(existsSync(path.join(dirs.poster, PID))).toBe(false);
    });

    it("a hung ffmpeg is killed at the budget: 422, not a hung helper, and not retried", async () => {
        helper.close();
        await start({ ffmpegPath: () => stub, probe: probeOk, posterTimeoutMs: 600 });
        plan("hang");
        const t0 = Date.now();
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(422);
        expect(Date.now() - t0).toBeLessThan(30_000);
        expect(calls()).toHaveLength(1);
        // free again (a longer budget: starting a node process can be slow on a busy machine)
        helper.close();
        await start({ ffmpegPath: () => stub, probe: probeOk, posterTimeoutMs: 20_000 });
        plan("ok");
        expect((await poster(Buffer.alloc(3000, 4))).status).toBe(200);
    });

    it("a poster over the cap, or an empty file, is 422", async () => {
        plan("huge");
        expect((await poster(Buffer.alloc(3000, 4))).status).toBe(422);
        plan("empty");
        expect((await poster(Buffer.alloc(3000, 4))).status).toBe(422);
    });

    it("no video stream (the probe says so) is 400 not_video and ffmpeg is never run", async () => {
        helper.close();
        await start({ ffmpegPath: () => stub, probe: async () => ({ duration: 3, width: null, height: null }) });
        const res = await poster(Buffer.alloc(3000, 4));
        expect(res.status).toBe(400);
        expect(calls()).toEqual([]);
    });

    it("the video is capped at 200 MB: a declared size over it is 413 error.studio.too_large and the body is not read", async () => {
        const res = await poster(Buffer.alloc(10), PID, { "content-length": String(200 * 1024 * 1024 + 1) }).catch((e) => e);
        // the helper answers and closes the socket without draining a body that cannot be sent in full
        if (res instanceof Response) {
            expect(res.status).toBe(413);
            expect(((await res.json()) as any).error.code).toBe("error.studio.too_large");
        }
        expect(calls()).toEqual([]);
    });

    it("bad ids are 400, a wrong or missing key is 403, other methods are 405", async () => {
        expect((await poster(Buffer.alloc(10), "short")).status).toBe(400);
        expect((await poster(Buffer.alloc(10), "../../etc/passwd/aaaaaaaaaaaaaaaaaaaaa")).status).toBe(400);
        expect((await poster(Buffer.alloc(10), PID, {}, null)).status).toBe(403);
        expect((await poster(Buffer.alloc(10), PID, {}, "wrong")).status).toBe(403);
        const get = await fetch(`${base}/poster?id=${PID}`, { headers: { "x-internal-key": KEY } });
        expect(get.status).toBe(405);
        expect(calls()).toEqual([]);
    });

    it("one job at a time: a poster while a probe holds the helper is 429 busy, and a probe while a poster runs is too", async () => {
        // hold the helper with a slow probe
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        helper.close();
        await start({ ffmpegPath: () => stub, probe: async () => (await gate, probeOk()) });
        const first = poster(Buffer.alloc(3000, 4));
        // wait until it is inside the probe
        for (let i = 0; i < 2000 && !existsSync(path.join(dirs.poster, PID, "in")); i++) await new Promise((r) => setTimeout(r, 10));
        const second = await poster(Buffer.alloc(10), "bBdE6gH9jK2mN5pQ8sTuVw");
        expect(second.status).toBe(429);
        expect(((await second.json()) as any).error.code).toBe("error.webp.busy");
        const probe = await fetch(`${base}/probe?id=${PID}2222`, { method: "POST", headers: { "x-internal-key": KEY }, body: Buffer.alloc(10), duplex: "half" } as RequestInit);
        expect(probe.status).toBe(429);
        release();
        expect((await first).status).toBe(200);
        // and free again afterwards
        expect((await poster(Buffer.alloc(3000, 4), "cBdE6gH9jK2mN5pQ8sTuVw")).status).toBe(200);
    });

    it("the file never reaches the disk outside the poster directory, and the directory is removed", async () => {
        await poster(Buffer.alloc(3000, 4));
        expect(existsSync(path.join(dirs.poster, PID))).toBe(false);
        expect(existsSync(dirs.work)).toBe(false);
        expect(existsSync(dirs.fetch)).toBe(false);
    });
});
