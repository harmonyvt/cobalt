// The helper's make routes over HTTP (APP-API-CONTRACT.md 18.10, 18.11, lane S1): /gallery/* and the webp on /slideshow/*,
// served by the real createHelper with the real ffmpeg (and img2webp for the webp). Skipped, with a logged reason, when a
// tool is absent. What is pinned: the wire, holding the helper across both families, idle reap, timeouts, cleaning up.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper } from "../helper/server.js";
import { parseWebp } from "../helper/lib.js";

vi.setConfig({ testTimeout: 90_000 });
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const IMG2WEBP = process.env.IMG2WEBP_PATH || "img2webp";
const KEY = "internal-key";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const hasImg2webp = spawnSync(IMG2WEBP, ["-version"]).status === 0;
if (!hasFfmpeg || !hasImg2webp) process.stderr.write(`[helper-make tests] ffmpeg ${hasFfmpeg ? "found" : "MISSING"}, img2webp ${hasImg2webp ? "found" : "MISSING"}: the real-tool groups are skipped\n`);
const real = hasFfmpeg ? describe : describe.skip;
const realWebp = hasFfmpeg && hasImg2webp ? describe : describe.skip;

const root = mkdtempSync(path.join(tmpdir(), "helpermake-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const fx: Record<string, string> = {};
const ff = (args: string[]) => {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
};
beforeAll(() => {
    if (!hasFfmpeg) return;
    const mk = (n: string, a: string[]) => {
        fx[n] = path.join(root, n);
        ff([...a, fx[n]!]);
    };
    mk("a.jpg", ["-f", "lavfi", "-i", "testsrc2=s=800x1000:r=1", "-frames:v", "1", "-q:v", "4"]);
    mk("b.jpg", ["-f", "lavfi", "-i", "mandelbrot=s=800x1000", "-frames:v", "1", "-q:v", "4"]);
    mk("sq.jpg", ["-f", "lavfi", "-i", "testsrc2=s=800x800:r=1", "-frames:v", "1", "-q:v", "4"]);
    mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p"]);
});

let helper: ReturnType<typeof createHelper>;
let base = "";
let dirs: { slideshow: string; gallery: string };
async function startHelper(over: Record<string, unknown> = {}) {
    const id = Math.random().toString(36).slice(2);
    dirs = { slideshow: path.join(root, id, "slideshow"), gallery: path.join(root, id, "gallery") };
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "w"),
        fetchDir: path.join(root, id, "f"),
        probeDir: path.join(root, id, "p"),
        posterDir: path.join(root, id, "po"),
        slideshowDir: dirs.slideshow,
        galleryDir: dirs.gallery,
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        img2webpPath: () => IMG2WEBP,
        ...over,
    } as any);
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
}
beforeEach(() => startHelper());
afterEach(() => helper.close());

const call = (p: string, init: RequestInit & { duplex?: string } = {}, key: string | null = KEY) =>
    fetch(`${base}${p}`, { ...init, headers: { ...(key === null ? {} : { "x-internal-key": key }), ...(init.headers as any) } });
const json = async (r: Response) => (await r.json()) as any;
const post = (p: string, b: unknown) => call(p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) });
const rid = () => Array.from({ length: 20 }, () => "abcdefghijklmnopqrstuvwxyz0123456789"[Math.floor(Math.random() * 36)]).join("");
const until = async (p: string) => {
    for (let i = 0; i < 1500; i++) {
        const b = await json(await call(p));
        if (b.status !== "pending") return b;
        await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("timed out waiting for " + p);
};
const put = (kind: "slideshow" | "gallery", id: string, n: number | string, body: Buffer | string) =>
    call(`/${kind}/${id}/inputs/${n}`, { method: "PUT", body, headers: { "content-type": "application/octet-stream" }, duplex: "half" } as any);
const putFile = (kind: "slideshow" | "gallery", id: string, n: number, name: string) => put(kind, id, n, readFileSync(fx[name]!));
const tiny = Buffer.alloc(1500, 1);
const u16 = (b: Uint8Array, i: number) => (b[i]! << 8) | b[i + 1]!;
const jpegSize = (buf: Buffer) => {
    let i = 2;
    while (i + 9 < buf.length) {
        if (buf[i] !== 0xff) {
            i++;
            continue;
        }
        const m = buf[i + 1]!;
        if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { h: u16(buf, i + 5), w: u16(buf, i + 7) };
        i += 2 + u16(buf, i + 2);
    }
    return null;
};

describe("what this helper says it can do", () => {
    it("gallery=1,make=1 on a 200, a 404 and a 403", async () => {
        for (const [p, key] of [["/gallery/" + rid(), KEY], ["/nope", KEY], ["/gallery/" + rid(), "wrong"]] as const) {
            expect((await call(p, {}, key)).headers.get("x-cobalt-helper"), p).toBe("gallery=1,make=1");
        }
    });
    it("403 without the key on every gallery route", async () => {
        const id = rid();
        for (const [m, p] of [["PUT", `/gallery/${id}/inputs/0`], ["POST", `/gallery/${id}/start`], ["GET", `/gallery/${id}`], ["GET", `/gallery/${id}/file`], ["DELETE", `/gallery/${id}`], ["GET", `/slideshow/${id}/poster`]] as const) {
            expect((await call(p, { method: m }, null)).status, p).toBe(403);
            expect((await call(p, { method: m }, "wrong")).status, p).toBe(403);
        }
    });
});

describe("the gallery routes: shape, holding the helper, limits", () => {
    const plan = { layout: "strip", slides: [{ n: 0 }, { n: 1 }] };

    it("bad n, bad id, wrong methods; a refused request never holds the helper", async () => {
        const id = rid();
        for (const n of ["20", "-1", "x", "01", "1.5", ""]) expect((await put("gallery", id, n, tiny)).status, n).toBe(400);
        expect((await call(`/gallery/short/inputs/0`, { method: "PUT", body: tiny, duplex: "half" } as any)).status).toBe(400);
        expect((await call(`/gallery/${id}/inputs/0`, { method: "POST", body: tiny })).status).toBe(405);
        expect(helper.galleries.size).toBe(0);
        expect((await call(`/gallery/${id}`)).status).toBe(404);
        expect((await call(`/gallery/${id}/file`)).status).toBe(404);
        expect((await call(`/gallery/${id}/poster`)).status).toBe(404);
        expect((await call(`/gallery/short`)).status).toBe(404);
        expect((await call(`/gallery/${id}/nope`)).status).toBe(404);
        expect((await put("gallery", id, 0, Buffer.alloc(0))).status).toBe(400);
        expect(helper.galleries.size).toBe(0);
    });

    it("the first input holds the helper for everything, both families included, until DELETE", async () => {
        const id = rid();
        expect((await put("gallery", id, 0, tiny)).status).toBe(204);
        expect(helper.galleries.size).toBe(1);
        expect((await post("/fetch", { id: rid(), url: "https://x.com/a" })).status).toBe(429);
        expect((await put("slideshow", rid(), 0, tiny)).status).toBe(429);
        expect((await put("gallery", rid(), 0, tiny)).status).toBe(429);
        expect((await put("gallery", id, 1, tiny)).status).toBe(204); // the holder keeps adding
        expect((await call(`/gallery/${id}`, { method: "DELETE" })).status).toBe(204);
        expect((await call(`/gallery/${id}`, { method: "DELETE" })).status).toBe(204); // idempotent
        expect(helper.galleries.size).toBe(0);
        expect((await put("slideshow", rid(), 0, tiny)).status).toBe(204); // free again
    });

    it("and a slideshow holds it against a gallery image", async () => {
        const s = rid();
        expect((await put("slideshow", s, 0, tiny)).status).toBe(204);
        expect((await put("gallery", rid(), 0, tiny)).status).toBe(429);
    });

    it("start: a body that is not one is 400, an input missing 409 not_ready, a second start 409, a job that is not there 404", async () => {
        const id = rid();
        expect((await put("gallery", id, 0, tiny)).status).toBe(204);
        expect((await call(`/gallery/${id}/start`, { method: "POST", body: "nope" })).status).toBe(400);
        expect((await call(`/gallery/${id}/start`)).status).toBe(405);
        for (const bad of [{ layout: "mosaic", slides: plan.slides }, { layout: "strip", slides: [{ n: 0 }] }, { layout: "strip", slides: [{ n: 0 }, { n: 0 }] }, { layout: "strip" }]) {
            expect((await post(`/gallery/${id}/start`, bad)).status, JSON.stringify(bad)).toBe(400);
        }
        const missing = await post(`/gallery/${id}/start`, plan);
        expect(missing.status).toBe(409);
        expect((await json(missing)).error.code).toBe("error.webp.not_ready");
        expect((await call(`/gallery/${id}/file`)).status).toBe(409);
        expect((await post(`/gallery/${rid()}/start`, plan)).status).toBe(404);
    });

    it("a size over the cap is 413 before the body is read, and the job a refused first input would have made is gone", async () => {
        const big = await call(`/gallery/${rid()}/inputs/0`, { method: "PUT", headers: { "content-length": String(300 * 1024 * 1024) }, body: tiny, duplex: "half" } as any).catch(() => null);
        expect(big === null || big.status === 413).toBe(true);
        expect(helper.galleries.size).toBe(0);
    });

    it("an idle gallery job is reaped and frees the helper", async () => {
        helper.close();
        await startHelper({ slideshowIdleMs: 250 });
        const id = rid();
        expect((await put("gallery", id, 0, tiny)).status).toBe(204);
        expect(existsSync(path.join(dirs.gallery, id, "input-0"))).toBe(true);
        await new Promise((r) => setTimeout(r, 700));
        expect((await call(`/gallery/${id}`)).status).toBe(404);
        expect(helper.galleries.size).toBe(0);
        expect(existsSync(path.join(dirs.gallery, id))).toBe(false);
    });
});

real("the gallery image over HTTP, with the real ffmpeg", () => {
    async function run(layout: string, files: string[]) {
        const id = rid();
        for (const [n, f] of files.entries()) expect((await putFile("gallery", id, n, f)).status).toBe(204);
        const res = await post(`/gallery/${id}/start`, { layout, slides: files.map((_, n) => ({ n })) });
        expect(res.status).toBe(202);
        expect(await json(res)).toEqual({ status: "pending", id });
        return { id, done: await until(`/gallery/${id}`) };
    }

    it("a 3-photo strip: done {bytes, width, height, cropped, upscaled}, the file is image/jpeg of that size, DELETE cleans up", async () => {
        const { id, done } = await run("strip", ["a.jpg", "b.jpg", "a.jpg"]);
        expect(done).toEqual({ status: "done", bytes: expect.any(Number), width: 800, height: 3000, cropped: [], upscaled: [] });
        const f = await call(`/gallery/${id}/file`);
        expect(f.status).toBe(200);
        expect(f.headers.get("content-type")).toBe("image/jpeg");
        const buf = Buffer.from(await f.arrayBuffer());
        expect(Number(f.headers.get("content-length"))).toBe(buf.length);
        expect(done.bytes).toBe(buf.length);
        expect(jpegSize(buf)).toEqual({ w: 800, h: 3000 });
        expect(existsSync(path.join(dirs.gallery, id, "input-0"))).toBe(false); // the inputs are gone, the result stays
        expect(existsSync(path.join(dirs.gallery, id, "out.jpg"))).toBe(true);
        expect((await call(`/gallery/${id}`, { method: "DELETE" })).status).toBe(204);
        expect(existsSync(path.join(dirs.gallery, id))).toBe(false);
        expect((await call(`/gallery/${id}`)).status).toBe(404);
        expect(helper.galleries.size).toBe(0);
    });

    it("grid3 with a square among 4:5s: the square is cropped and named by slot", async () => {
        const { done } = await run("grid3", ["a.jpg", "a.jpg", "sq.jpg"]);
        expect(done).toMatchObject({ status: "done", width: 2160, height: 900, cropped: [2], upscaled: [2] });
    });

    it("the status while it runs is composing with its count; a finished job still answers its result on every poll", async () => {
        const id = rid();
        for (const n of [0, 1]) await putFile("gallery", id, n, "a.jpg");
        await post(`/gallery/${id}/start`, { layout: "row", slides: [{ n: 0 }, { n: 1 }] });
        const first = await json(await call(`/gallery/${id}`));
        if (first.status === "pending") expect(first).toMatchObject({ phase: "composing", total: 2 });
        const done = await until(`/gallery/${id}`);
        expect(await json(await call(`/gallery/${id}`))).toEqual(done);
    });

    it("a video as an input ends error.webp.invalid_params and cleans up; the helper is free again", async () => {
        const id = rid();
        await putFile("gallery", id, 0, "a.jpg");
        await putFile("gallery", id, 1, "v.mp4");
        await post(`/gallery/${id}/start`, { layout: "strip", slides: [{ n: 0 }, { n: 1 }] });
        expect(await until(`/gallery/${id}`)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(existsSync(path.join(dirs.gallery, id))).toBe(false);
        expect((await put("gallery", rid(), 0, tiny)).status).toBe(204); // a finished (failed) job no longer holds the helper
    });

    it("the job's whole budget: a timeout ends error.webp.timeout", async () => {
        helper.close();
        await startHelper({ slideshowTimeoutMs: 1 });
        const id = rid();
        await putFile("gallery", id, 0, "a.jpg");
        await putFile("gallery", id, 1, "b.jpg");
        await post(`/gallery/${id}/start`, { layout: "strip", slides: [{ n: 0 }, { n: 1 }] });
        expect(await until(`/gallery/${id}`)).toEqual({ status: "error", error: { code: "error.webp.timeout" } });
    });
});

realWebp("the slideshow webp over HTTP, with ffmpeg and img2webp", () => {
    const plan = (over: Record<string, unknown> = {}) => ({ width: 480, height: 600, fade: true, sound: "none", format: "webp", slides: [{ n: 0, seconds: 2 }, { n: 1, seconds: 1 }], ...over });
    async function run(files: string[], p: Record<string, unknown>) {
        const id = rid();
        for (const [n, f] of files.entries()) expect((await putFile("slideshow", id, n, f)).status).toBe(204);
        const res = await post(`/slideshow/${id}/start`, p);
        expect(res.status).toBe(202);
        return { id, done: await until(`/slideshow/${id}`) };
    }

    it("done {bytes, duration, width, height, format: webp}; /file is image/webp, /poster is the first frame as a JPEG", async () => {
        const { id, done } = await run(["a.jpg", "b.jpg"], plan());
        expect(done).toMatchObject({ status: "done", width: 480, height: 600, format: "webp", duration: 3 });
        const f = await call(`/slideshow/${id}/file`);
        expect(f.headers.get("content-type")).toBe("image/webp");
        const buf = Buffer.from(await f.arrayBuffer());
        expect(done.bytes).toBe(buf.length);
        expect(parseWebp(buf)).toMatchObject({ width: 480, height: 600, animated: true, durationMs: 3000 });
        const p = await call(`/slideshow/${id}/poster`);
        expect(p.status).toBe(200);
        expect(p.headers.get("content-type")).toBe("image/jpeg");
        expect(jpegSize(Buffer.from(await p.arrayBuffer()))).toEqual({ w: 480, h: 600 });
        expect(existsSync(path.join(dirs.slideshow, id, "frames"))).toBe(false);
        expect((await call(`/slideshow/${id}`, { method: "DELETE" })).status).toBe(204);
        expect((await call(`/slideshow/${id}/poster`)).status).toBe(404);
    });

    it("the poster of a job that is not done is 409", async () => {
        const id = rid();
        await putFile("slideshow", id, 0, "a.jpg");
        expect((await call(`/slideshow/${id}/poster`)).status).toBe(409);
    });

    it("an mp4 slideshow says format mp4, and has a first-frame poster too", async () => {
        const { id, done } = await run(["a.jpg", "b.jpg"], { width: 1080, height: 1350, fade: false, sound: "none", slides: [{ n: 0, seconds: 1 }, { n: 1, seconds: 1 }] });
        expect(done).toMatchObject({ status: "done", format: "mp4" });
        expect((await call(`/slideshow/${id}/file`)).headers.get("content-type")).toBe("video/mp4");
        // no poster run was spent when the video finished (the API makes its own); it is cut when asked for
        expect(existsSync(path.join(dirs.slideshow, id, "poster.jpg"))).toBe(false);
        const p = await call(`/slideshow/${id}/poster`);
        expect(p.headers.get("content-type")).toBe("image/jpeg");
        expect(jpegSize(Buffer.from(await p.arrayBuffer()))).toEqual({ w: 576, h: 720 }); // the poster cap: 720 on the long side
        expect(existsSync(path.join(dirs.slideshow, id, "poster.jpg"))).toBe(true);
    });

    it("start bodies the webp refuses: sound own, a width of 640, quality with the mp4; a video that is no length", async () => {
        const id = rid();
        await putFile("slideshow", id, 0, "a.jpg");
        await putFile("slideshow", id, 1, "b.jpg");
        for (const bad of [plan({ sound: "own" }), plan({ width: 640 }), plan({ quality: "ultra" }), plan({ format: undefined, quality: "med" }), plan({ slides: [{ n: 0, seconds: 61 }, { n: 1, seconds: 1 }] })]) {
            expect((await post(`/slideshow/${id}/start`, bad)).status, JSON.stringify(bad)).toBe(400);
        }
    });

    it("over 60 s with the video counted (15 + 15 + 15 + 15 s of photos and a 2 s video): error.webp.too_long once probed, nothing encoded", async () => {
        const { id, done } = await run(["a.jpg", "v.mp4", "b.jpg", "a.jpg", "b.jpg"], plan({ slides: [{ n: 0, seconds: 15 }, { n: 1, seconds: null }, { n: 2, seconds: 15 }, { n: 3, seconds: 15 }, { n: 4, seconds: 15 }] }));
        expect(done).toEqual({ status: "error", error: { code: "error.webp.too_long" } });
        expect(existsSync(path.join(dirs.slideshow, id, "out.webp"))).toBe(false);
    });

    it("the timeout: error.webp.timeout, and the frames are gone", async () => {
        helper.close();
        await startHelper({ slideshowTimeoutMs: 1 });
        const { id, done } = await run(["a.jpg", "b.jpg"], plan());
        expect(done).toEqual({ status: "error", error: { code: "error.webp.timeout" } });
        expect(existsSync(path.join(dirs.slideshow, id, "frames"))).toBe(false);
    });
});
