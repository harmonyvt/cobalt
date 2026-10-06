// The API's Durable Object against the REAL helper server (createHelper) over HTTP, with a stubbed cobalt and a local
// CDN serving real ffmpeg-made fixtures: the reviewer's proof of the wire (APP-API-CONTRACT.md 18.7) kept as a test.
// Skipped when no ffmpeg is found (set FFMPEG_PATH, or have `ffmpeg` on the PATH).
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper } from "../helper/server.js";
import { downloadToFile, resolveSource } from "../helper/lib.js";
import { auth, json, world, KEY_ID } from "./poster-world";

vi.setConfig({ testTimeout: 120_000 });
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const real = hasFfmpeg ? describe : describe.skip;
const KEY = "internal-key";
const root = mkdtempSync(path.join(tmpdir(), "realwire-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const fx: Record<string, string> = {};
function ff(args: string[]) {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
}
let origin: http.Server;
let originUrl = "";
let served: Record<string, { file: string; type: string; status?: number }> = {};
let resolveBody: (url: string) => Promise<any> = async () => ({});
let helper: ReturnType<typeof createHelper>;
let base = "";

beforeAll(async () => {
    if (!hasFfmpeg) return;
    const mk = (n: string, a: string[]) => {
        fx[n] = path.join(root, n);
        ff([...a, fx[n]!]);
    };
    mk("a.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1350:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("b.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1350:r=1", "-frames:v", "1", "-q:v", "5"]);
    mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=2:r=30", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]);
    origin = http.createServer((req, res) => {
        const s = served[(req.url ?? "").split("?")[0]!];
        if (!s || s.status) {
            res.writeHead(s?.status ?? 404);
            return void res.end();
        }
        const body = readFileSync(s.file);
        res.writeHead(200, { "content-type": s.type, "content-length": body.length });
        res.end(body);
    });
    await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
    originUrl = `http://127.0.0.1:${(origin.address() as any).port}`;
});
afterAll(() => origin?.close());

beforeEach(async () => {
    if (!hasFfmpeg) return;
    served = {};
    const id = Math.random().toString(36).slice(2);
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "w"),
        fetchDir: path.join(root, id, "f"),
        probeDir: path.join(root, id, "p"),
        posterDir: path.join(root, id, "po"),
        slideshowDir: path.join(root, id, "s"),
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
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
const serve = (n: string, type: string) => (served[`/${n}`] = { file: fx[n]!, type });
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function mkWorld(fn: (p: string, init?: RequestInit) => Promise<Response> = realHelper) {
    const w = world({ helperFn: fn });
    await w.addKey();
    return w;
}
async function settle(w: any, sid: string) {
    for (let i = 0; i < 400; i++) {
        const r = await w.studio.advance(sid, 0);
        if ((r.body as any).status !== "saving") return r.body as any;
        await wait(25);
    }
    throw new Error("never settled");
}
async function save(w: any, body: Record<string, unknown>) {
    const res = await w.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json(body) });
    const created = (await res.json()) as any;
    expect(res.status, JSON.stringify(created)).toBe(201);
    return { sid: created.id as string, created, done: await settle(w, created.id) };
}
const LINK = "https://www.instagram.com/p/Ddy0-gpGg5U/";
const picker3 = () => ({ status: "picker", picker: [{ type: "photo", url: cdn("a.jpg") }, { type: "video", url: cdn("v.mp4") }, { type: "photo", url: cdn("b.jpg") }] });
const rowsOf = (w: any, sid: string, cols: string) => w.db.raw.prepare(`SELECT ${cols} FROM media_items WHERE session_id = ? AND deleted_at IS NULL ORDER BY item_index`).all(sid) as any[];

real("the Durable Object against the real helper", () => {
    it("a gallery save, items: all (photo, video, photo)", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        serve("v.mp4", "video/mp4");
        serve("b.jpg", "image/jpeg");
        resolveBody = async () => picker3();
        const { sid, done } = await save(w, { url: LINK, items: "all", item_count: 3 });
        expect(done.status).toBe("ready");
        const rows = rowsOf(w, sid, "r2_key, content_type, role, item_index, poster, post_key, duration, width, height");
        expect(rows.map((r) => [r.item_index, r.role, r.post_key, r.content_type])).toEqual([
            [0, "item", sid, "image/jpeg"],
            [1, "item", sid, "video/mp4"],
            [2, "item", sid, "image/jpeg"],
        ]);
        expect(rows[0].poster).toBeTruthy(); // the helper's own 480 px thumb
        expect(rows[0].duration).toBeNull();
        expect(w.session(sid).r2_key).toMatch(/-01\.mp4$/);
        expect(done.item_count).toBe(3);
        expect(helper.fetches.size).toBe(0); // the helper's copy was dropped
    });

    it("a plain video (the share sheet, no items) is today's file", async () => {
        const w = await mkWorld();
        serve("v.mp4", "video/mp4");
        resolveBody = async () => ({ status: "redirect", url: cdn("v.mp4"), filename: "x_123.mp4" });
        const { sid, done } = await save(w, { url: "https://x.com/a/status/1", origin: "share" });
        const rows = rowsOf(w, sid, "r2_key, role");
        expect(done.status).toBe("ready");
        expect(rows).toEqual([{ r2_key: `originals/${sid}.mp4`, role: null }]);
    });

    it("a single photo link, no items: a photo, not a 0.04 s mp4", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        resolveBody = async () => ({ status: "redirect", url: cdn("a.jpg"), filename: "ig_1.jpg" });
        const { sid, done } = await save(w, { url: LINK });
        const rows = rowsOf(w, sid, "r2_key, content_type, role, poster, duration");
        expect(done.status).toBe("ready");
        expect(rows[0]).toMatchObject({ content_type: "image/jpeg", r2_key: `originals/${sid}.jpg`, role: null, duration: null });
        expect(rows[0].poster).toBeTruthy();
    });

    it("items first-video on a post, and items all on a plain link: both are today's single file (no role, no items list)", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        serve("v.mp4", "video/mp4");
        serve("b.jpg", "image/jpeg");
        resolveBody = async () => picker3();
        const a = await save(w, { url: LINK, items: "first-video" });
        expect(rowsOf(w, a.sid, "r2_key, role, item_index, post_key")).toEqual([{ r2_key: `originals/${a.sid}.mp4`, role: null, item_index: null, post_key: null }]);
        expect(a.done).not.toHaveProperty("items");
        resolveBody = async () => ({ status: "redirect", url: cdn("v.mp4"), filename: "x.mp4" });
        const b = await save(w, { url: "https://x.com/a/status/2", items: "all" });
        expect(rowsOf(w, b.sid, "r2_key, role, item_index, post_key")).toEqual([{ r2_key: `originals/${b.sid}.mp4`, role: null, item_index: null, post_key: null }]);
        expect(w.session(b.sid).item_count).toBeNull();
    });

    it("a slideshow end to end, and the helper is free afterwards", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        serve("v.mp4", "video/mp4");
        serve("b.jpg", "image/jpeg");
        resolveBody = async () => picker3();
        const { sid } = await save(w, { url: LINK, items: "all", item_count: 3 });
        const r = await w.studio.slideshow(KEY_ID, sid, JSON.stringify({ items: [0, 1, 2], seconds: [2, null, 2], fade: true, frame: "keep", sound: "own", queue: true }));
        expect(r.status).toBe(202);
        const job = (r.body as any).job;
        let last: any;
        for (let i = 0; i < 600; i++) {
            last = (await w.studio.renderStatus(sid, job, 0)).body;
            if (last.status !== "pending") break;
            await wait(100);
        }
        expect(last.status).toBe("success");
        const row = w.db.raw.prepare("SELECT role, width, height, duration FROM media_items WHERE role = 'slideshow'").get() as any;
        expect(row).toMatchObject({ role: "slideshow", width: 1080, height: 1350 });
        expect(row.duration).toBeGreaterThan(5);
        expect(helper.slideshows.size).toBe(0);
    });

    it("the retry of a failed item", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        serve("v.mp4", "video/mp4");
        resolveBody = async () => picker3();
        const { sid, done } = await save(w, { url: LINK, items: "all", item_count: 3 }); // b.jpg is not served: item 2 fails
        expect(done.items.map((e: any) => e.status)).toEqual(["ready", "ready", "error"]);
        serve("b.jpg", "image/jpeg");
        const r = await w.studio.retryItems(KEY_ID, sid, JSON.stringify({ items: [2], queue: true }));
        expect(r.status).toBe(202);
        const after = await settle(w, sid);
        expect(after.items.map((e: any) => e.status)).toEqual(["ready", "ready", "ready"]);
        expect(rowsOf(w, sid, "r2_key")).toHaveLength(3);
    });

    it("the helper's own answers carry the capability header the API's features.gallery follows", async () => {
        const w = await mkWorld();
        serve("a.jpg", "image/jpeg");
        resolveBody = async () => ({ status: "redirect", url: cdn("a.jpg"), filename: "ig_1.jpg" });
        expect(((await (await w.call("/capabilities")).json()) as any).features.gallery).toBe(false);
        await save(w, { url: LINK });
        expect(((await (await w.call("/capabilities")).json()) as any).features.gallery).toBe(true);
    });

    it("an old helper image (no /slideshow route, as in the container before the rollout): the slideshow fails at once, the line is free", async () => {
        const old = (p: string, init?: RequestInit) =>
            p.startsWith("/slideshow")
                ? Promise.resolve(new Response(JSON.stringify({ status: "error", error: { code: "error.webp.not_found" } }), { status: 404 }))
                : realHelper(p, init);
        const w = await mkWorld(old);
        serve("a.jpg", "image/jpeg");
        serve("b.jpg", "image/jpeg");
        resolveBody = async () => ({ status: "picker", picker: [{ type: "photo", url: cdn("a.jpg") }, { type: "photo", url: cdn("b.jpg") }] });
        const { sid } = await save(w, { url: LINK, items: "all", item_count: 2 });
        const r = await w.studio.slideshow(KEY_ID, sid, JSON.stringify({ items: [0, 1], seconds: [2, 2], queue: true }));
        const job = (r.body as any).job;
        expect(((await w.studio.renderStatus(sid, job, 0)).body as any).error.code).toBe("error.webp.unavailable");
        expect([...w.kv.m.keys()].filter((k: string) => k.startsWith("line:"))).toEqual([]);
    });
});
