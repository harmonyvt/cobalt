// The Durable Object against the REAL helper (createHelper, over HTTP) with real ffmpeg and img2webp, for the makes of
// APP-API-CONTRACT.md 18.10-18.12: a slideshow webp, a gallery image, and the share sheet's save-then-make in one request.
// A stubbed cobalt and a local CDN serve ffmpeg-made fixtures. The proof of the wire (18.7) kept as a test; measurements are
// written to stderr. Skipped, with a logged reason, when ffmpeg or img2webp is missing.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper } from "../helper/server.js";
import { downloadToFile, parseWebp, resolveSource } from "../helper/lib.js";
import { KEY_ID, MEDIA_BASE, asBody, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";

vi.setConfig({ testTimeout: 180_000 });
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const IMG2WEBP = process.env.IMG2WEBP_PATH || "img2webp";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const hasImg2webp = spawnSync(IMG2WEBP, ["-version"]).status === 0;
if (!hasFfmpeg || !hasImg2webp) process.stderr.write(`[make-real-helper tests] skipped: ffmpeg ${hasFfmpeg ? "found" : "MISSING"}, img2webp ${hasImg2webp ? "found" : "MISSING"}\n`);
const real = hasFfmpeg && hasImg2webp ? describe : describe.skip;
const KEY = "internal-key";
const root = mkdtempSync(path.join(tmpdir(), "makereal-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const fx: Record<string, string> = {};
function ff(args: string[]) {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
}
let origin: http.Server;
let originUrl = "";
const served = new Set<string>();
let helper: ReturnType<typeof createHelper>;
let base = "";
let resolveBody: (url: string) => Promise<any> = async () => ({});

beforeAll(async () => {
    if (!hasFfmpeg) return;
    const mk = (n: string, a: string[]) => {
        fx[n] = path.join(root, n);
        ff([...a, fx[n]!]);
    };
    for (let i = 0; i < 6; i++) {
        mk(`p${i}.jpg`, ["-f", "lavfi", "-i", `gradients=s=1080x1350:n=4:seed=${i + 1}:speed=0.02`, "-vf", "noise=alls=14:allf=t+u", "-frames:v", "1", "-q:v", "3"]);
    }
    mk("sq.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1080:r=1", "-frames:v", "1", "-q:v", "4"]);
    mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]);
    origin = http.createServer((req, res) => {
        const name = (req.url ?? "").split("?")[0]!.slice(1);
        if (!served.has(name) || !fx[name]) {
            res.writeHead(404);
            return void res.end();
        }
        const body = readFileSync(fx[name]!);
        res.writeHead(200, { "content-type": name.endsWith(".mp4") ? "video/mp4" : "image/jpeg", "content-length": body.length });
        res.end(body);
    });
    await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
    originUrl = `http://127.0.0.1:${(origin.address() as any).port}`;
});
afterAll(() => origin?.close());

beforeEach(async () => {
    if (!hasFfmpeg) return;
    served.clear();
    const id = Math.random().toString(36).slice(2);
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "w"),
        fetchDir: path.join(root, id, "f"),
        probeDir: path.join(root, id, "p"),
        posterDir: path.join(root, id, "po"),
        slideshowDir: path.join(root, id, "s"),
        galleryDir: path.join(root, id, "g"),
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        img2webpPath: () => IMG2WEBP,
        resolveSource: (o: any) => resolveSource({ ...o, fetchImpl: (async () => new Response(JSON.stringify(await resolveBody(o.url)))) as any }),
        downloadToFile: (o: any) => downloadToFile({ ...o, url: o.url.replace("https://cdn.example", originUrl) }),
    } as any);
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
});
afterEach(() => helper?.close());

const realHelper = async (p: string, init: RequestInit = {}) => {
    const headers = new Headers(init.headers);
    headers.set("x-internal-key", KEY);
    return fetch(`${base}${p}`, { ...init, headers, ...(init.body ? { duplex: "half" } : {}) } as any);
};
const cdn = (n: string) => `https://cdn.example/${n}`;
const post = (names: string[]) => {
    for (const n of names) served.add(n);
    resolveBody = async () => ({ status: "picker", picker: names.map((n) => ({ type: n.endsWith(".mp4") ? "video" : "photo", url: cdn(n) })) });
};
const LINK = "https://x.com/ilokineedsleep/status/2106850389551374806";
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function settle(L: LW, sid: string) {
    for (let i = 0; i < 400; i++) {
        const r = await L.studio.advance(sid, 0);
        if ((r.body as any).status !== "saving") return r.body as any;
        await wait(25);
    }
    throw new Error("never settled");
}
async function saved(L: LW, names: string[], body: Record<string, unknown> = {}) {
    post(names);
    const res = asBody(await L.studio.create(KEY_ID, json({ url: LINK, items: "all", item_count: names.length, ...body })));
    expect(res.status).toBe("success");
    const done = await settle(L, res.id);
    expect(done.status).toBe("ready");
    return res as { id: string; make?: { job: string; kind: string } };
}
async function collect(L: LW, sid: string, job: string) {
    for (let i = 0; i < 1200; i++) {
        const b = (await L.studio.renderStatus(sid, job, 0)).body as any;
        if (b.status !== "pending") return b;
        await wait(50);
    }
    throw new Error("the make never finished");
}
const rows = (L: LW, sid: string, role: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = ? AND deleted_at IS NULL ORDER BY created_at, id", sid, role);

real("the Durable Object against the real helper: the makes", () => {
    it("a slideshow webp over 3 photos and a 2 s video: stored as image/webp of the plan's length, the helper's frame as its poster, the helper free", async () => {
        const L = await lineWorld({ helperFn: realHelper });
        const { id: sid } = await saved(L, ["p0.jpg", "v.mp4", "p1.jpg", "p2.jpg"]);
        const t0 = Date.now();
        const r = await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1, 2, 3], seconds: [2, null, 2, 1.5], fade: true, frame: "keep", format: "webp", quality: "med", width: 480, queue: true }));
        expect(r.status).toBe(202);
        const done = await collect(L, sid, asBody(r).job);
        expect(done).toMatchObject({ status: "success", format: "webp", width: 480, height: 600, replaced: [] });
        const row = rows(L, sid, "slideshow")[0]!;
        const bytes = L.originals.objects.get(row.r2_key)!.bytes;
        const webp = parseWebp(Buffer.from(bytes))!;
        expect(row.content_type).toBe("image/webp");
        expect(webp).toMatchObject({ width: 480, height: 600, animated: true });
        expect(Math.abs(webp.durationMs - 7500)).toBeLessThanOrEqual(70);
        expect(done.bytes).toBe(bytes.length);
        expect(Math.abs(done.seconds - 7.5)).toBeLessThanOrEqual(0.07);
        expect(row.poster).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.jpg$/);
        const poster = L.media.objects.get(row.poster.split("/").pop())!;
        expect([...poster.data.slice(0, 3)]).toEqual([0xff, 0xd8, 0xff]);
        expect(helper.slideshows.size).toBe(0);
        process.stderr.write(`[make-real-helper] webp 3 photos + 2 s video, fade: ${bytes.length} bytes, ${webp.frames} frames, ${Date.now() - t0} ms end to end\n`);
    });

    it("a gallery image 3 across over 5 photos (one square): the answer names the cropped photo by item_index; the next one replaces it", async () => {
        const L = await lineWorld({ helperFn: realHelper });
        const { id: sid } = await saved(L, ["p0.jpg", "p1.jpg", "sq.jpg", "p2.jpg", "p3.jpg"]);
        const r = await L.studio.galleryImage(KEY_ID, sid, json({ items: [0, 1, 2, 3, 4], layout: "grid3", queue: true }));
        expect(r.status).toBe(202);
        const done = await collect(L, sid, asBody(r).job);
        // 5 in 3 across = 3 + 2; cells of 720x900 then 1080x1350 (each photo is its own 1080 wide): the square is cut to its cell
        expect(done).toMatchObject({ status: "success", width: 2160, replaced: [] });
        expect(done.cropped).toEqual([2]);
        expect(done.upscaled).toEqual([]);
        const row = rows(L, sid, "export")[0]!;
        const jpeg = Buffer.from(L.originals.objects.get(row.r2_key)!.bytes);
        expect(jpeg.subarray(0, 3)).toEqual(Buffer.from([0xff, 0xd8, 0xff]));
        expect(row).toMatchObject({ content_type: "image/jpeg", width: 2160, height: done.height });
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "gallery", layout: "grid3", items: [0, 1, 2, 3, 4] });
        expect(helper.galleries.size).toBe(0);
        const again = await L.studio.galleryImage(KEY_ID, sid, json({ items: [4, 3, 2, 1, 0], layout: "grid3", queue: true }));
        const second = await collect(L, sid, asBody(again).job);
        expect(second.replaced).toEqual([row.id]);
        expect(rows(L, sid, "export")).toHaveLength(1);
    });

    it("the share sheet's one request: save everything, then make the webp, ONE message (the public link)", async () => {
        const L = await lineWorld({ helperFn: realHelper });
        const label = "x · @ilokineedsleep";
        const r = await saved(L, ["p0.jpg", "p1.jpg", "p2.jpg"], {
            public: true,
            origin: "share",
            queue: true,
            notify: { on: ["rendered", "failed"], label },
            slideshow: { items: [0, 1, 2], seconds: [2, 2, 2], fade: true, frame: "keep", sound: "none", format: "webp", quality: "med", width: 480 },
        });
        expect(r.make).toMatchObject({ kind: "slideshow" });
        const done = await collect(L, r.id, r.make!.job);
        expect(done.status).toBe("success");
        await L.sweeps(3);
        const row = rows(L, r.id, "slideshow")[0]!;
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toMatch(new RegExp(`^${label} · slideshow webp ready · 480×600 · [0-9.]+ [KM]B\\n${MEDIA_BASE}${row.public_key}$`));
        const webp = parseWebp(Buffer.from(L.originals.objects.get(row.r2_key)!.bytes))!;
        expect(Math.abs(webp.durationMs - 6000)).toBeLessThanOrEqual(70);
    });

    it("the share sheet's one request, gallery image: save, then make over the photos that saved (one failed to download)", async () => {
        const L = await lineWorld({ helperFn: realHelper });
        // p5.jpg is never served: item 1 fails to download
        post(["p0.jpg", "p5.jpg", "p1.jpg", "p2.jpg"]);
        served.delete("p5.jpg");
        const res = asBody(
            await L.studio.create(KEY_ID, json({ url: LINK, items: "all", item_count: 4, public: false, origin: "share", queue: true, notify: { on: ["rendered", "failed"], label: "x" }, gallery_image: { items: [0, 1, 2, 3], layout: "strip" } })),
        );
        await settle(L, res.id);
        const done = await collect(L, res.id, res.make.job);
        expect(done).toMatchObject({ status: "success", width: 1080, height: 4050 });
        expect(rows(L, res.id, "item")).toHaveLength(3);
        await L.sweeps(3);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toMatch(/^x · gallery image ready · 1080×4050 · /);
    });

    it("a webp over 60 s is refused before anything runs, and a 0.5 s photo slideshow is made", async () => {
        const L = await lineWorld({ helperFn: realHelper });
        const { id: sid } = await saved(L, ["p0.jpg", "p1.jpg", "p2.jpg"]);
        const over = await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1, 2], seconds: [15, 15, 15], format: "webp", queue: true }));
        expect(over.status).toBe(202); // 45 s: fine
        await collect(L, sid, asBody(over).job);
        const short = await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1, 2], seconds: [0.5, 0.5, 0.5], fade: true, format: "webp", queue: true }));
        const done = await collect(L, sid, asBody(short).job);
        expect(done).toMatchObject({ status: "success", seconds: 1.5 });
        const row = rows(L, sid, "slideshow").find((x) => x.id === done.item_id)!;
        const webp = parseWebp(Buffer.from(L.originals.objects.get(row.r2_key)!.bytes))!;
        expect(webp.durationMs).toBe(1500);
        expect(webp.frames).toBe(3 + 4 * 2);
    });
});
