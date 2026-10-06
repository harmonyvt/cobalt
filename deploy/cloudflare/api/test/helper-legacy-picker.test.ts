// Lane S0 (APP-API-CONTRACT.md 18.9): a client that sends no `items` and a photo-only picker of 2+ entries gets the
// post saved whole (as `items: "all"`), instead of error.webp.no_video. Two halves:
//  - the pure rule, `effectiveItems` and its composition with `selectPickerItems` (a table);
//  - POST /fetch with NO `items` through the real helper server, a stubbed cobalt, a real local HTTP origin, the
//    real downloadToFile and the REAL ffmpeg (skipped when no ffmpeg is found: FFMPEG_PATH or `ffmpeg` on PATH).
// Fixtures are generated at test time; nothing binary is committed.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper } from "../helper/server.js";
import { downloadToFile, effectiveItems, resolveSource, selectPickerItems } from "../helper/lib.js";

vi.setConfig({ testTimeout: 90_000 });

const KEY = "internal-key";
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const real = hasFfmpeg ? describe : describe.skip;

const photo = { type: "photo" };
const video = { type: "video" };
const gif = { type: "gif" };
const photos = (n: number) => Array.from({ length: n }, () => photo);

// what the fetch job runs with: effectiveItems, then selectPickerItems (server.js)
const plan = (entries: { type: string | null }[], items: any) => {
    const eff = effectiveItems(entries, items);
    return { eff, sel: selectPickerItems(entries, eff) };
};

describe("effectiveItems (18.9): the `items` a fetch really runs with", () => {
    it("`items` given is returned unchanged, whatever the post", () => {
        expect(effectiveItems(photos(4), "first-video")).toBe("first-video");
        expect(effectiveItems(photos(4), "all")).toBe("all");
        const idx = [0, 2];
        expect(effectiveItems(photos(4), idx)).toBe(idx);
        expect(effectiveItems([photo, video], "all")).toBe("all");
        expect(effectiveItems([{ type: null }], "all")).toBe("all");
    });
    it("no `items`, a picker of 2+ with no video and no gif: \"all\"", () => {
        expect(effectiveItems(photos(2), undefined)).toBe("all");
        expect(effectiveItems(photos(4), undefined)).toBe("all");
        expect(effectiveItems(photos(10), undefined)).toBe("all");
        expect(effectiveItems(photos(25), undefined)).toBe("all");
    });
    it("no `items`, anything else stays undefined (today)", () => {
        expect(effectiveItems([photo], undefined)).toBeUndefined(); // one-item picker
        expect(effectiveItems([{ type: null }], undefined)).toBeUndefined(); // a plain answer
        expect(effectiveItems([], undefined)).toBeUndefined();
        expect(effectiveItems([photo, video], undefined)).toBeUndefined(); // a video in the post
        expect(effectiveItems([video, video], undefined)).toBeUndefined();
        expect(effectiveItems([photo, gif], undefined)).toBeUndefined(); // a gif in the post
        expect(effectiveItems([photo, photo, gif], undefined)).toBeUndefined();
        expect(effectiveItems([gif, gif], undefined)).toBeUndefined();
    });
});

describe("what a fetch with no `items` saves, by post (effectiveItems then selectPickerItems)", () => {
    it("10 photos: all 10", () => {
        const { eff, sel } = plan(photos(10), undefined);
        expect(eff).toBe("all");
        expect(sel).toEqual({ ok: true, indices: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] });
    });
    it("25 photos: the first 20 (indices 0-19)", () => {
        const sel: any = plan(photos(25), undefined).sel;
        expect(sel.ok).toBe(true);
        expect(sel.indices).toEqual(Array.from({ length: 20 }, (_, i) => i));
    });
    it("photo + video: the video only ([1]); photo + gif: the gif only ([1])", () => {
        expect(plan([photo, video], undefined)).toEqual({ eff: undefined, sel: { ok: true, indices: [1] } });
        expect(plan([photo, gif], undefined)).toEqual({ eff: undefined, sel: { ok: true, indices: [1] } });
        expect(plan([photo, gif, video], undefined).sel).toEqual({ ok: true, indices: [2] });
    });
    it("one photo: the single path (no `items` list), index 0", () => {
        expect(plan([photo], undefined)).toEqual({ eff: undefined, sel: { ok: true, indices: [0] } });
    });
    it("a plain answer (type null): the single path", () => {
        expect(plan([{ type: null }], undefined)).toEqual({ eff: undefined, sel: { ok: true, indices: [0] } });
    });
    it('"first-video" on 4 photos still fails: that is what the client asked for', () => {
        expect(plan(photos(4), "first-video").sel).toEqual({ ok: false, code: "error.webp.no_video" });
    });
    it('"all" and an index list are unchanged', () => {
        expect(plan(photos(4), "all").sel).toEqual({ ok: true, indices: [0, 1, 2, 3] });
        expect(plan(photos(4), [0, 2]).sel).toEqual({ ok: true, indices: [0, 2] });
        expect(plan(photos(2), [0, 2]).sel).toEqual({ ok: false, code: "error.studio.gallery_changed" });
    });
    it("selectPickerItems alone is untouched: no `items` on photos still reads no_video (the helper never gets there now)", () => {
        expect(selectPickerItems(photos(4), undefined)).toEqual({ ok: false, code: "error.webp.no_video" });
    });
});

// =================================================================================================
// POST /fetch through the helper server
// =================================================================================================

const root = mkdtempSync(path.join(tmpdir(), "legacy-picker-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const rid = (n = 22) => Array.from({ length: n }, () => ALNUM[Math.floor(Math.random() * ALNUM.length)]).join("");

function ff(args: string[]) {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(`ffmpeg ${args.join(" ")} failed: ${r.stderr}`);
}
const fx: Record<string, string> = {};
beforeAll(() => {
    if (!hasFfmpeg) return;
    const mk = (name: string, args: string[]) => {
        fx[name] = path.join(root, name);
        ff([...args, fx[name]!]);
    };
    mk("a.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1080x1350:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("b.jpg", ["-f", "lavfi", "-i", "testsrc2=s=1200x1200:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("c.jpg", ["-f", "lavfi", "-i", "testsrc2=s=800x600:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("d.jpg", ["-f", "lavfi", "-i", "testsrc2=s=600x800:r=1", "-frames:v", "1", "-q:v", "3"]);
    mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=1:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an"]);
});

type Served = { file: string; type: string; status?: number };
let origin: http.Server;
let originUrl: string;
let served: Record<string, Served>;
let hits: string[];
let helper: ReturnType<typeof createHelper>;
let base: string;
let resolveBody: (url: string) => Promise<any>;

beforeAll(async () => {
    origin = http.createServer((req, res) => {
        const key = (req.url ?? "").split("?")[0]!;
        hits.push(key);
        const s = served[key];
        if (!s) {
            res.writeHead(404);
            return void res.end();
        }
        if (s.status && s.status !== 200) {
            res.writeHead(s.status);
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
    hits = [];
    served = {};
    resolveBody = async () => ({ status: "error", error: { code: "error.api.fetch.fail" } });
    const id = Math.random().toString(36).slice(2);
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "webp"),
        fetchDir: path.join(root, id, "fetch"),
        probeDir: path.join(root, id, "probe"),
        posterDir: path.join(root, id, "poster"),
        slideshowDir: path.join(root, id, "slideshow"),
        waitForCobalt: async () => {},
        ffmpegPath: () => FFMPEG,
        img2webpPath: () => "img2webp",
        resolveSource: (o: any) =>
            resolveSource({
                ...o,
                fetchImpl: (async () => new Response(JSON.stringify(await resolveBody(o.url)))) as unknown as typeof fetch,
            }),
        downloadToFile: (o: any) => downloadToFile({ ...o, url: o.url.replace("https://cdn.example", originUrl) }),
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
});
afterEach(() => helper.close());

const call = (p: string, init: RequestInit = {}) => fetch(`${base}${p}`, { ...init, headers: { "x-internal-key": KEY, ...(init.headers as any) } });
const json = async (r: Response) => (await r.json()) as any;
const post = (p: string, b: unknown) => call(p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) });
const until = async (p: string) => {
    for (let i = 0; i < 600; i++) {
        const b = await json(await call(p));
        if (b.status !== "pending") return b;
        await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("timed out waiting for " + p);
};
const LINK = "https://x.com/ilokineedsleep/status/2106850389551374806";
const cdn = (name: string) => `https://cdn.example/${name}`;
const pickerOf = (...items: [string, string][]) => ({ status: "picker", picker: items.map(([type, name]) => ({ type, url: cdn(name) })) });
const serve = (name: string, fixture: string, type = "image/jpeg", extra: Partial<Served> = {}) => {
    served[`/${name}`] = { file: fx[fixture]!, type, ...extra };
};
const jpegBytes = async (r: Response) => Buffer.from(await r.arrayBuffer());

real("POST /fetch without `items` (an old client): a photo-only picker is saved whole (18.9)", () => {
    const four = () => {
        serve("1.jpg", "a.jpg");
        serve("2.jpg", "b.jpg");
        serve("3.jpg", "c.jpg");
        serve("4.jpg", "d.jpg");
        resolveBody = async () => pickerOf(["photo", "1.jpg"], ["photo", "2.jpg"], ["photo", "3.jpg"], ["photo", "4.jpg"]);
    };

    it("an X 4-photo post: done with `items` of 4, picker_count 4, the lead is item 0 (image/jpeg), a thumb per item", async () => {
        four();
        const id = rid();
        expect((await post("/fetch", { id, url: LINK })).status).toBe(202);
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", picker_count: 4, contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350 });
        expect(done.items).toHaveLength(4);
        expect(done.items.map((i: any) => [i.i, i.status, i.contentType, i.thumb])).toEqual([
            [0, "done", "image/jpeg", true],
            [1, "done", "image/jpeg", true],
            [2, "done", "image/jpeg", true],
            [3, "done", "image/jpeg", true],
        ]);
        expect(done.items.map((i: any) => [i.width, i.height])).toEqual([[1080, 1350], [1200, 1200], [800, 600], [600, 800]]);
        expect([...hits].sort()).toEqual(["/1.jpg", "/2.jpg", "/3.jpg", "/4.jpg"]);
        // the lead (no `i`) is item 0's bytes; every item has its file and a JPEG thumb
        expect((await jpegBytes(await call(`/fetch/${id}/file`))).equals(readFileSync(fx["a.jpg"]!))).toBe(true);
        for (const [i, f] of [[0, "a.jpg"], [1, "b.jpg"], [2, "c.jpg"], [3, "d.jpg"]] as const) {
            const file = await call(`/fetch/${id}/file?i=${i}`);
            expect(file.headers.get("content-type")).toBe("image/jpeg");
            expect((await jpegBytes(file)).equals(readFileSync(fx[f]!))).toBe(true);
            const thumb = await call(`/fetch/${id}/thumb?i=${i}`);
            expect(thumb.status).toBe(200);
            expect(thumb.headers.get("content-type")).toBe("image/jpeg");
        }
    });

    it("the same post asked with items \"all\" answers identically (the old and the new client save the same thing)", async () => {
        four();
        const a = rid();
        const b = rid();
        // one fetch holds the helper at a time: the second starts when the first is done
        expect((await post("/fetch", { id: a, url: LINK })).status).toBe(202);
        const da = await until(`/fetch/${a}`);
        expect((await post("/fetch", { id: b, url: LINK, items: "all", item_count: 4 })).status).toBe(202);
        const db = await until(`/fetch/${b}`);
        expect(da).toEqual(db);
    });

    it("one item answering 403: 3 done + 1 error, the job still done", async () => {
        four();
        served["/3.jpg"] = { file: fx["c.jpg"]!, type: "image/jpeg", status: 403 };
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", picker_count: 4, contentType: "image/jpeg" });
        expect(done.items.map((i: any) => i.status)).toEqual(["done", "done", "error", "done"]);
        expect(done.items[2]).toEqual({ i: 2, status: "error", code: "error.webp.download_failed" });
        expect((await call(`/fetch/${id}/file?i=2`)).status).toBe(404);
    });

    it("every item failing is still an error (the first item's code)", async () => {
        four();
        for (const n of ["1", "2", "3", "4"]) served[`/${n}.jpg`] = { file: fx["a.jpg"]!, type: "image/jpeg", status: 403 };
        const id = rid();
        await post("/fetch", { id, url: LINK });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.webp.download_failed" } });
    });

    it("25 photos: the first 20 are saved (indices 0-19), picker_count 25", async () => {
        serve("p.jpg", "c.jpg");
        resolveBody = async () => pickerOf(...Array.from({ length: 25 }, () => ["photo", "p.jpg"] as [string, string]));
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", picker_count: 25 });
        expect(done.items.map((i: any) => i.i)).toEqual(Array.from({ length: 20 }, (_, i) => i));
        expect(hits).toHaveLength(20);
    });

    it("`item_count` is still checked when the client sent it, and is not needed when it did not", async () => {
        four();
        const id = rid();
        await post("/fetch", { id, url: LINK, item_count: 3 });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.studio.gallery_changed" } });
        const id2 = rid();
        await post("/fetch", { id: id2, url: LINK, item_count: 4 });
        expect((await until(`/fetch/${id2}`)).items).toHaveLength(4);
    });
});

real("POST /fetch without `items`: everything else is byte-identical to before (18.9)", () => {
    it('"first-video" on photos still fails no_video', async () => {
        serve("1.jpg", "a.jpg");
        serve("2.jpg", "b.jpg");
        resolveBody = async () => pickerOf(["photo", "1.jpg"], ["photo", "2.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK, items: "first-video" });
        expect(await until(`/fetch/${id}`)).toEqual({ status: "error", error: { code: "error.webp.no_video" } });
        expect(hits).toEqual([]);
    });

    it("a picker with a video saves the first video only (no `items` list), the photos are not fetched", async () => {
        serve("1.jpg", "a.jpg");
        serve("v.mp4", "v.mp4", "video/mp4");
        serve("2.jpg", "b.jpg");
        resolveBody = async () => pickerOf(["photo", "1.jpg"], ["video", "v.mp4"], ["photo", "2.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", picker_count: 3 });
        expect(done.items).toBeUndefined();
        expect(hits).toEqual(["/v.mp4"]);
    });

    it("a one-photo picker saves that photo (no `items` list), picker_count 1", async () => {
        serve("1.jpg", "a.jpg");
        resolveBody = async () => pickerOf(["photo", "1.jpg"]);
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "image/jpeg", picker_count: 1 });
        expect(done.items).toBeUndefined();
    });

    it("a plain link (redirect answer): one file, picker_count null, no `items` list", async () => {
        serve("v.mp4", "v.mp4", "video/mp4");
        resolveBody = async () => ({ status: "redirect", url: cdn("v.mp4"), filename: "x_1.mp4" });
        const id = rid();
        await post("/fetch", { id, url: LINK });
        const done = await until(`/fetch/${id}`);
        expect(done).toMatchObject({ status: "done", contentType: "video/mp4", picker_count: null });
        expect(done.items).toBeUndefined();
    });
});
