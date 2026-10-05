// Spatial crop of a render (APP-API-CONTRACT.md section 10): the shared validation and pixel
// conversion (helper/crop.js), the ffmpeg arguments, the helper's HTTP API, and the Durable
// Object half (studio render and plain /webp).
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CROP_EPS, MIN_CROP_PX, cropToPixels, cropToWire, fromWire, parseCrop } from "../helper/crop.js";
import { buildFrameArgs, parseVideoInfo, validateEncodeFields, validateJobInput } from "../helper/lib.js";
import { createHelper } from "../helper/server.js";
import { StudioService, validateRender } from "../src/studio";
import { WebpService, validateParams } from "../src/webp";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const LINK = "https://www.instagram.com/p/Dd7P496wolG/";
const KEY_ID = "key-row-1";
const HALF = { x: 0, y: 0, w: 0.5, h: 0.5 };

// ---- helper/crop.js ------------------------------------------------------------------

describe("parseCrop", () => {
    it("no crop is no crop", () => {
        expect(parseCrop(undefined)).toEqual({ ok: true, crop: null });
        expect(parseCrop(null)).toEqual({ ok: true, crop: null });
    });
    it("accepts a rectangle inside the frame, and the whole frame", () => {
        expect(parseCrop({ x: 0.1, y: 0.2, w: 0.5, h: 0.5 })).toEqual({ ok: true, crop: { x: 0.1, y: 0.2, w: 0.5, h: 0.5 } });
        expect(parseCrop({ x: 0, y: 0, w: 1, h: 1 }).ok).toBe(true);
    });
    it("tolerates float slop up to the epsilon, no more", () => {
        expect(parseCrop({ x: 0.5, y: 0, w: 0.5 + CROP_EPS / 2, h: 1 }).ok).toBe(true);
        expect(parseCrop({ x: 0.5, y: 0, w: 0.5 + CROP_EPS * 2, h: 1 }).ok).toBe(false);
        expect(parseCrop({ x: 0, y: 0.7, w: 1, h: 0.3 + CROP_EPS * 2 }).ok).toBe(false);
    });
    it.each([
        ["a string", "0,0,1,1"],
        ["an array", [0, 0, 1, 1]],
        ["a number", 1],
        ["a missing field", { x: 0, y: 0, w: 1 }],
        ["a string field", { x: "0", y: 0, w: 1, h: 1 }],
        ["NaN", { x: NaN, y: 0, w: 1, h: 1 }],
        ["Infinity", { x: 0, y: 0, w: Infinity, h: 1 }],
        ["null field", { x: null, y: 0, w: 1, h: 1 }],
        ["negative x", { x: -0.1, y: 0, w: 0.5, h: 0.5 }],
        ["negative y", { x: 0, y: -0.01, w: 0.5, h: 0.5 }],
        ["zero width", { x: 0, y: 0, w: 0, h: 0.5 }],
        ["negative height", { x: 0, y: 0, w: 0.5, h: -0.5 }],
        ["x past the frame", { x: 1.2, y: 0, w: 0.1, h: 0.5 }],
        ["x + w past the frame", { x: 0.6, y: 0, w: 0.6, h: 0.5 }],
        ["y + h past the frame", { x: 0, y: 0.6, w: 0.5, h: 0.6 }],
        ["w over 1", { x: 0, y: 0, w: 1.5, h: 1 }],
    ])("rejects %s", (_n, raw) => {
        expect(parseCrop(raw)).toEqual({ ok: false });
    });
});

describe("fromWire / cropToWire (the DO -> helper hop)", () => {
    it("round-trips the query-string form", () => {
        const c = { x: 0.125, y: 0.25, w: 0.5, h: 0.5 };
        expect(cropToWire(c)).toBe("0.125,0.25,0.5,0.5");
        expect(fromWire(cropToWire(c))).toEqual({ ok: true, crop: c });
        expect(fromWire(c)).toEqual({ ok: true, crop: c });
    });
    it.each(["", "1,2,3", "0,0,1,1,1", "a,b,c,d", "0,0,,1", "0,0,2,2", "-1,0,1,1"])("rejects %j", (raw) => {
        expect(fromWire(raw).ok).toBe(false);
    });
});

describe("cropToPixels", () => {
    it("scales to the displayed size and rounds every number to an even one", () => {
        expect(cropToPixels(HALF, 480, 560)).toEqual({ x: 0, y: 0, w: 240, h: 280 });
        // 0.333 * 1080 = 359.64 -> 360; 0.1 * 1920 = 192 ; 0.25 * 1080 = 270
        expect(cropToPixels({ x: 0.25, y: 0.1, w: 0.333, h: 0.5 }, 1080, 1920)).toEqual({ x: 270, y: 192, w: 360, h: 960 });
        // 0.3 * 1001 = 300.3 -> 300 (even), x 0.4 * 1001 = 400.4 -> 400
        const odd = cropToPixels({ x: 0.4, y: 0, w: 0.3, h: 1 }, 1001, 801);
        for (const v of Object.values(odd!)) expect(v % 2).toBe(0);
    });
    it("keeps the rectangle inside the frame (clamps the position, then the size)", () => {
        // x + w = 1.0005 within the epsilon: the last column is cut, never overrun
        const c = cropToPixels({ x: 0.5, y: 0, w: 0.5005, h: 1 }, 1000, 800)!;
        expect(c.x + c.w).toBeLessThanOrEqual(1000);
        expect(c.y + c.h).toBeLessThanOrEqual(800);
        // an odd frame: the largest even size is width - 1
        expect(cropToPixels({ x: 0, y: 0, w: 1, h: 1 }, 1081, 1921)).toEqual({ x: 0, y: 0, w: 1080, h: 1920 });
        // a rectangle rounding past the right edge is pulled back inside
        const edge = cropToPixels({ x: 0.9999, y: 0.9999, w: 0.0001 + 0.4, h: 0.4 }, 500, 500)!;
        expect(edge.x + edge.w).toBeLessThanOrEqual(500);
        expect(edge.y + edge.h).toBeLessThanOrEqual(500);
        expect(edge.x).toBeGreaterThanOrEqual(0);
    });
    it("refuses anything under 64 px wide or high", () => {
        expect(MIN_CROP_PX).toBe(64);
        expect(cropToPixels({ x: 0, y: 0, w: 61 / 640, h: 1 }, 640, 480)).toBeNull(); // 61 -> 62
        expect(cropToPixels({ x: 0, y: 0, w: 63 / 640, h: 1 }, 640, 480)).toMatchObject({ w: 64 }); // 63 rounds up to 64: allowed
        expect(cropToPixels({ x: 0, y: 0, w: 1, h: 0.1 }, 640, 480)).toBeNull(); // 48
        expect(cropToPixels({ x: 0, y: 0, w: 64 / 640, h: 64 / 480 }, 640, 480)).toEqual({ x: 0, y: 0, w: 64, h: 64 });
        // a source that is itself small
        expect(cropToPixels({ x: 0, y: 0, w: 1, h: 1 }, 60, 60)).toBeNull();
    });
    it("needs a usable source size", () => {
        for (const [w, h] of [[0, 100], [100, 0], [NaN, 100], [100.5, 100], [1, 1]] as const) {
            expect(cropToPixels(HALF, w, h)).toBeNull();
        }
    });
    it("rotation: the probe reports the DISPLAY size, and the crop is read against it", () => {
        // a portrait phone clip stored 1920x1080 with a rotation of -90 degrees
        const stderr = [
            "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'in':",
            "  Duration: 00:00:04.20, start: 0.000000, bitrate: 9000 kb/s",
            "  Stream #0:0[0x1](und): Video: h264 (High), yuv420p(tv, bt709), 1920x1080, 8900 kb/s, 30 fps, 30 tbr, 600 tbn (default)",
            "    Side data:",
            "      displaymatrix: rotation of -90.00 degrees",
        ].join("\n");
        const info = parseVideoInfo(stderr);
        expect(info).toMatchObject({ width: 1080, height: 1920 });
        // the bottom half of the displayed (portrait) frame
        expect(cropToPixels({ x: 0, y: 0.5, w: 1, h: 0.5 }, info.width!, info.height!)).toEqual({ x: 0, y: 960, w: 1080, h: 960 });
        // the same rectangle against the stored size would be a different picture: the
        // conversion must use what the probe says
        expect(cropToPixels({ x: 0, y: 0.5, w: 1, h: 0.5 }, 1920, 1080)).toEqual({ x: 0, y: 540, w: 1920, h: 540 });
    });
});

// ---- the ffmpeg arguments ---------------------------------------------------------------

describe("buildFrameArgs with a crop", () => {
    const base = { input: "/tmp/webp/x/in", framesDir: "/tmp/webp/x/frames", start: 0, length: 6, width: 480, fps: 15 };
    const vf = (a: string[]) => a[a.indexOf("-vf") + 1]!;

    it("crops BEFORE the scale (and the scale still never upscales past the cropped width)", () => {
        const f = vf(buildFrameArgs({ ...base, crop: { x: 100, y: 20, w: 360, h: 640 } }));
        expect(f).toBe("fps=15,crop=360:640:100:20,scale='min(480,iw)':-2:flags=lanczos");
        expect(f.indexOf("crop=")).toBeGreaterThan(-1);
        expect(f.indexOf("crop=")).toBeLessThan(f.indexOf("scale="));
    });
    it("absent, null or undefined: exactly the filter it always was", () => {
        const want = "fps=15,scale='min(480,iw)':-2:flags=lanczos";
        expect(vf(buildFrameArgs(base))).toBe(want);
        expect(vf(buildFrameArgs({ ...base, crop: null }))).toBe(want);
        expect(vf(buildFrameArgs({ ...base, crop: undefined }))).toBe(want);
    });
    it("leaves every other argument alone", () => {
        const a = buildFrameArgs(base);
        const b = buildFrameArgs({ ...base, crop: { x: 0, y: 0, w: 100, h: 100 } });
        expect(b.filter((_, i) => b[i - 1] !== "-vf")).toEqual(a.filter((_, i) => a[i - 1] !== "-vf"));
    });
});

describe("the helper's field validation", () => {
    const good = { id: "aB3dE6gH9jK2mN5pQ8sT", url: "https://cobalt.example/tunnel?x=1", start: 0, length: 5, width: 480, fps: 15, quality: "med" };
    it("keeps a valid crop, from JSON or from the query string form, and omits it otherwise", () => {
        expect(validateJobInput({ ...good, crop: HALF })).toMatchObject({ crop: HALF });
        expect(validateEncodeFields({ ...good, crop: "0,0,0.5,0.5" }, { minLength: 0.5 })).toMatchObject({ crop: HALF });
        expect("crop" in validateJobInput(good)!).toBe(false);
        expect("crop" in validateJobInput({ ...good, crop: null })!).toBe(false);
        expect("crop" in validateEncodeFields({ ...good, crop: "" }, { minLength: 0.5 })!).toBe(false);
    });
    it("rejects an invalid one", () => {
        expect(validateJobInput({ ...good, crop: { x: 0, y: 0, w: 2, h: 1 } })).toBeNull();
        expect(validateJobInput({ ...good, crop: "nope" })).toBeNull();
        expect(validateJobInput({ ...good, crop: [0, 0, 1, 1] })).toBeNull();
    });
});

// ---- the helper's HTTP API ----------------------------------------------------------------

describe("helper: POST /jobs/upload and POST /jobs with a crop", () => {
    const KEY = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
    const JID = "aB3dE6gH9jK2mN5pQ8sT";
    let root: string;
    let helper: ReturnType<typeof createHelper>;
    let base: string;
    let probed: { duration: number | null; width: number | null; height: number | null };
    let encodeCalls: any[];

    const tinyWebp = () => {
        // a 1x1 animated-less WebP header is enough for the parser the helper uses; reuse a
        // minimal valid VP8X-less lossy file
        const b = Buffer.alloc(30);
        b.write("RIFF", 0);
        b.writeUInt32LE(22, 4);
        b.write("WEBPVP8 ", 8);
        return b;
    };

    beforeEach(async () => {
        root = await mkdtemp(path.join(os.tmpdir(), "crop-helper-"));
        probed = { duration: 9.6, width: 1080, height: 1920 };
        encodeCalls = [];
        helper = createHelper({
            internalKey: KEY,
            workDir: path.join(root, "webp"),
            fetchDir: path.join(root, "fetch"),
            probeDir: path.join(root, "probe"),
            waitForCobalt: async () => {},
            ffmpegPath: () => "ffmpeg",
            img2webpPath: () => "img2webp",
            resolveSource: async () => ({ url: "http://127.0.0.1:1/v", filename: "x.mp4" }),
            downloadToFile: async (o: any) => {
                await writeFile(o.dest, Buffer.alloc(1234, 1));
                o.onResponse?.(new Response(null, { headers: { "content-type": "video/mp4" } }));
                return 1234;
            },
            probe: async () => probed,
            encodeAnimatedWebp: async (o: any) => {
                encodeCalls.push(o);
                await mkdir(o.framesDir, { recursive: true });
                await writeFile(o.output, tinyWebp());
                return { frames: 5, frameBytes: 100 };
            },
        });
        await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
        base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
    });
    afterEach(async () => {
        await helper.close();
        await rm(root, { recursive: true, force: true });
    });

    const call = (p: string, init: RequestInit & { duplex?: string } = {}) =>
        fetch(`${base}${p}`, { ...init, headers: { "x-internal-key": KEY, ...(init.headers as any) } });
    const json = async (r: Response) => (await r.json()) as any;
    const until = async (id: string) => {
        for (let i = 0; i < 200; i++) {
            const b = await json(await call(`/jobs/${id}`));
            if (b.status !== "pending") return b;
            await new Promise((r) => setTimeout(r, 10));
        }
        throw new Error("timed out");
    };
    const upload = (q: Record<string, string> = {}) => {
        const params = new URLSearchParams({ id: JID, start: "2", length: "5", width: "480", fps: "15", quality: "med", ...q });
        return call(`/jobs/upload?${params}`, { method: "POST", body: Buffer.alloc(2000, 3), headers: { "content-type": "application/octet-stream" }, duplex: "half" });
    };

    it("upload: the crop is converted with the PROBED (rotation-applied) size and handed to the encoder in pixels", async () => {
        const res = await upload({ crop: "0,0.5,1,0.5" });
        expect(res.status).toBe(202);
        const done = await until(JID);
        expect(done.status).toBe("done");
        expect(encodeCalls).toHaveLength(1);
        expect(encodeCalls[0].crop).toEqual({ x: 0, y: 960, w: 1080, h: 960 });
        // frames_total is unchanged by a crop: the same clip, the same fps
        expect(encodeCalls[0]).toMatchObject({ start: 2, length: 5, fps: 15, width: 480 });
    });
    it("upload: no crop is no crop (the encoder gets none)", async () => {
        await upload();
        await until(JID);
        expect(encodeCalls[0].crop ?? null).toBeNull();
    });
    it("POST /jobs: the same, from a JSON body", async () => {
        const res = await call("/jobs", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ id: JID, url: "https://cobalt.example/tunnel?x=1", start: 0, length: 5, width: 480, fps: 15, quality: "med", crop: { x: 0.25, y: 0.25, w: 0.5, h: 0.5 } }),
        });
        expect(res.status).toBe(202);
        await until(JID);
        expect(encodeCalls[0].crop).toEqual({ x: 270, y: 480, w: 540, h: 960 });
    });
    it("a malformed crop is a 400 and starts nothing", async () => {
        for (const crop of ["nope", "0,0,2,2", "0,0,0,1"]) {
            const res = await upload({ crop });
            expect(res.status, crop).toBe(400);
            expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        }
        expect(helper.jobs.size).toBe(0);
    });
    it("a crop that comes out under 64 px on the probed size is the job's error.webp.invalid_params, and ffmpeg is never run", async () => {
        probed = { duration: 9.6, width: 320, height: 240 };
        await upload({ crop: "0,0,0.1,1" }); // 32 px wide
        const done = await until(JID);
        expect(done).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(encodeCalls).toHaveLength(0);
    });
    it("a source whose size could not be probed cannot be cropped", async () => {
        probed = { duration: 9.6, width: null, height: null };
        await upload({ crop: "0,0,0.5,0.5" });
        const done = await until(JID);
        expect(done).toEqual({ status: "error", error: { code: "error.webp.encode_failed" } });
        expect(encodeCalls).toHaveLength(0);
    });
});

// ---- the Durable Object half ---------------------------------------------------------------

describe("validateRender with a crop", () => {
    type Src = { duration: number | null; width: number | null; height: number | null };
    const src: Src = { duration: 9.6, width: 480, height: 560 };
    const ok = (body: Record<string, unknown>, s: Src = src) => validateRender({ start: 0, length: 5, ...body }, s);

    it("no crop: the params carry no crop key at all", () => {
        const r = ok({});
        expect(r).toEqual({ ok: true, params: { start: 0, length: 5, width: 480, quality: "med", effectiveWidth: 480 } });
        expect("crop" in (r as any).params).toBe(false);
    });
    it("a crop is kept, and the recorded width is min(requested, cropped width)", () => {
        const r = ok({ crop: HALF }) as any;
        expect(r.ok).toBe(true);
        expect(r.params.crop).toEqual(HALF);
        expect(r.params.effectiveWidth).toBe(240); // 480 * 0.5
        expect((ok({ crop: HALF, width: 320 }) as any).params.effectiveWidth).toBe(240);
        expect((ok({ crop: { x: 0, y: 0, w: 0.9, h: 1 }, width: 320 }) as any).params.effectiveWidth).toBe(320);
        // never above the source's width either, with no crop
        expect((ok({ width: 480 }, { ...src, width: 320 }) as any).params.effectiveWidth).toBe(320);
    });
    it("a crop under 64 px on the saved size is a 400 error.webp.invalid_params", () => {
        expect(ok({ crop: { x: 0, y: 0, w: 0.1, h: 0.5 } })).toEqual({ ok: false, status: 400, code: "error.webp.invalid_params" });
        expect(ok({ crop: { x: 0, y: 0, w: 1, h: 0.1 } })).toMatchObject({ ok: false, status: 400 });
    });
    it("a malformed crop is a 400, whatever the source", () => {
        for (const crop of [{ x: 0, y: 0, w: 2, h: 1 }, "x", [0, 0, 1, 1], { x: "0", y: 0, w: 1, h: 1 }, { x: 0.9, y: 0, w: 0.5, h: 1 }]) {
            expect(ok({ crop }), JSON.stringify(crop)).toEqual({ ok: false, status: 400, code: "error.webp.invalid_params" });
        }
    });
    it("without a known source size the crop passes through unconverted (the helper converts it)", () => {
        const r = ok({ crop: HALF }, { duration: null, width: null, height: null }) as any;
        expect(r.ok).toBe(true);
        expect(r.params).toMatchObject({ crop: HALF, effectiveWidth: 480 });
    });
});

describe("a studio render with a crop (the real StudioService)", () => {
    const wire = () => {
        const db = createFakeD1();
        const clock = new Clock();
        const kv = new MemoryKV();
        const helper = new FakeHelper();
        const webp = new WebpService({
            storage: kv,
            bucket: new MemoryMedia(),
            mediaBaseUrl: "https://media.capybaraharmony.com/",
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: helper.helper,
            db,
        });
        const studio = new StudioService({
            db,
            storage: kv,
            originals: new MemoryOriginals(),
            webp,
            webBaseUrl: "https://cobalt.capybaraharmony.com",
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: helper.helper,
            fixedLength,
        });
        return { db, clock, kv, helper, studio };
    };
    type W = ReturnType<typeof wire>;
    const ready = async (w: W) => {
        const sid = ((await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string }).id;
        w.clock.t += 2000;
        expect(((await w.studio.advance(sid, 0)).body as any).status).toBe("ready"); // 480x560, 9.6 s
        return sid;
    };

    it("the helper is asked for the normalized crop; the record and the D1 row say what came out", async () => {
        const w = wire();
        const sid = await ready(w);
        const r = await w.studio.render(sid, JSON.stringify({ start: 2, length: 5, width: 480, crop: { x: 0.25, y: 0.125, w: 0.5, h: 0.5 } }));
        expect(r.status).toBe(202);
        const job = (r.body as any).job as string;
        expect(w.helper.uploadQueries).toHaveLength(1);
        const q = w.helper.uploadQueries[0]!;
        expect(q.get("crop")).toBe("0.25,0.125,0.5,0.5");
        expect(q.get("width")).toBe("480");
        expect(q.get("length")).toBe("5");
        expect(w.kv.m.get(`job:${job}`)).toMatchObject({ params: { crop: { x: 0.25, y: 0.125, w: 0.5, h: 0.5 } } });
        const row = (await w.db.prepare("SELECT width FROM studio_renders WHERE id = ?1").bind(job).first()) as { width: number };
        expect(row.width).toBe(240);
    });
    it("absent crop: no crop query, no crop in the record, the width as before", async () => {
        const w = wire();
        const sid = await ready(w);
        const r = await w.studio.render(sid, JSON.stringify({ start: 2, length: 5 }));
        const job = (r.body as any).job as string;
        expect(w.helper.uploadQueries[0]!.has("crop")).toBe(false);
        expect("crop" in (w.kv.m.get(`job:${job}`) as any).params).toBe(false);
        const row = (await w.db.prepare("SELECT width FROM studio_renders WHERE id = ?1").bind(job).first()) as { width: number };
        expect(row.width).toBe(480);
    });
    it("a too-small or malformed crop is a 400 before anything is uploaded", async () => {
        const w = wire();
        const sid = await ready(w);
        for (const crop of [{ x: 0, y: 0, w: 0.05, h: 1 }, { x: 0, y: 0, w: 1.5, h: 1 }, "all"]) {
            const r = await w.studio.render(sid, JSON.stringify({ start: 2, length: 5, crop }));
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        }
        expect(w.helper.uploadQueries).toHaveLength(0);
    });
    it("the finished render answers as before (the helper reports the real size)", async () => {
        const w = wire();
        const sid = await ready(w);
        const job = ((await w.studio.render(sid, JSON.stringify({ start: 2, length: 5, crop: HALF }))).body as any).job as string;
        const done = (await w.studio.renderStatus(sid, job, 0)).body as any;
        expect(done.status).toBe("success");
    });
});

describe("POST /webp with a crop (the plain route)", () => {
    const wire = () => {
        const clock = new Clock();
        const kv = new MemoryKV();
        const calls: { path: string; body: any }[] = [];
        const webp = new WebpService({
            storage: kv,
            bucket: new MemoryMedia(),
            mediaBaseUrl: "https://media.capybaraharmony.com/",
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: async (p: string, init?: RequestInit) => {
                calls.push({ path: p, body: JSON.parse(String(init?.body ?? "null")) });
                return new Response(JSON.stringify({ status: "pending" }), { status: 202, headers: { "content-type": "application/json" } });
            },
            db: createFakeD1(),
        });
        return { kv, calls, webp };
    };
    const body = { url: "https://x.com/u/status/1", start: 0, length: 5 };

    it("validateParams keeps a valid crop and rejects a bad one", () => {
        expect(validateParams({ ...body, crop: HALF })).toMatchObject({ ok: true, params: { crop: HALF } });
        expect("crop" in (validateParams(body) as any).params).toBe(false);
        expect(validateParams({ ...body, crop: { x: 0, y: 0, w: 3, h: 1 } })).toEqual({ ok: false });
        expect(validateParams({ ...body, crop: "x" })).toEqual({ ok: false });
    });
    it("a crop reaches the helper in the job body and the job record; none changes nothing", async () => {
        const w = wire();
        const r = await w.webp.create("k1", JSON.stringify({ ...body, crop: HALF }));
        expect(r.status).toBe(202);
        expect(w.calls[0]!.path).toBe("/jobs");
        expect(w.calls[0]!.body.crop).toEqual(HALF);
        const id = (r.body as any).id;
        expect(w.kv.m.get(`job:${id}`)).toMatchObject({ params: { crop: HALF } });

        const w2 = wire();
        await w2.webp.create("k1", JSON.stringify(body));
        expect("crop" in w2.calls[0]!.body).toBe(false);
    });
    it("a bad crop is a 400 and the helper is never called", async () => {
        const w = wire();
        const r = await w.webp.create("k1", JSON.stringify({ ...body, crop: { x: 0, y: 0, w: 0, h: 1 } }));
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        expect(w.calls).toHaveLength(0);
    });
});
