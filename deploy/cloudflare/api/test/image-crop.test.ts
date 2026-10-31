// Section 44: cropping pictures (image-crop-core's pixel rules, POST /library/items/<id>/crop both ways, the chat's
// cobalt.make.cropImage) and what `look` shows (private pictures inline, a grid, video frames). Real SQL on node:sqlite;
// the Images binding is a fake that "decodes" by handing back a PNG the test made.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { dropInlineImages } from "../src/chat";
import { chatTools, type ChatCollect } from "../src/chat-tools";
import { decodePng, encodePng, type Rgba } from "../src/cutout-core";
import { parseCropSpec } from "../src/image-crop";
import { frameTimes } from "../src/registry/ops/frames";
import { drawGrid, flip, GRID_RGB, pixelBox, rotate } from "../src/image-crop-core";
import { hashKey } from "../src/keys";
import { lookBlocks, lookImages } from "../src/look-pictures";
import { handleChatBudgetRoute } from "../src/registry/budget";
import { chatToolbox, opBase, REGISTRY } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const THREAD = "ThReAd0123456789";

// ---- the pure part ------------------------------------------------------------------------------------------------

/** A w x h picture where pixel (x, y) is (x, y, 7, 255): easy to tell where each one went. */
function coords(w: number, h: number): Rgba {
    const d = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) d.set([x, y, 7, 255], (y * w + x) * 4);
    return { width: w, height: h, data: d };
}
const at = (img: Rgba, x: number, y: number) => [...img.data.subarray((y * img.width + x) * 4, (y * img.width + x) * 4 + 4)];

/** A w x h white picture with a 4x4 orange square at (3, 3) (alpha 255): a sticker on white. */
function sticker(w = 10, h = 10): Rgba {
    const d = new Uint8Array(w * h * 4).fill(255);
    for (let y = 3; y < 7; y++) for (let x = 3; x < 7; x++) d.set([230, 130, 50, 255], (y * w + x) * 4);
    return { width: w, height: h, data: d };
}

describe("image-crop-core", () => {
    it("a crop in fractions becomes whole pixels, rounded outward and clamped; too small is null", () => {
        expect(pixelBox({ x: 0.25, y: 0.5, w: 0.5, h: 0.25 }, 100, 40)).toEqual({ x: 25, y: 20, w: 50, h: 10 });
        expect(pixelBox({ x: 0.333, y: 0, w: 0.333, h: 1 }, 10, 10)).toEqual({ x: 3, y: 0, w: 4, h: 10 });
        expect(pixelBox({ x: 0.9, y: 0.9, w: 0.1, h: 0.1 }, 10, 10)).toBeNull(); // 1 x 1 px
        expect(pixelBox({ x: 0.8, y: 0.8, w: 0.2009, h: 0.2 }, 10, 10)).toEqual({ x: 8, y: 8, w: 2, h: 2 });
        expect(pixelBox({ x: 0.5, y: 0.5, w: 0.01, h: 0.01 }, 10, 10)).toBeNull();
    });

    it("turns clockwise and flips", () => {
        const s = coords(3, 2); // (0,0) (1,0) (2,0) / (0,1) (1,1) (2,1)
        const r90 = rotate(s, 90);
        expect([r90.width, r90.height]).toEqual([2, 3]);
        expect(at(r90, 1, 0)).toEqual([0, 0, 7, 255]); // top-left went top-right
        expect(at(r90, 0, 0)).toEqual([0, 1, 7, 255]); // bottom-left went top-left
        const r180 = rotate(s, 180);
        expect(at(r180, 0, 0)).toEqual([2, 1, 7, 255]);
        const r270 = rotate(s, 270);
        expect([r270.width, r270.height]).toEqual([2, 3]);
        expect(at(r270, 0, 0)).toEqual([2, 0, 7, 255]); // top-right went top-left
        expect(at(r270, 0, 2)).toEqual([0, 0, 7, 255]); // top-left went bottom-left
        expect(at(flip(s, "h"), 0, 0)).toEqual([2, 0, 7, 255]);
        expect(at(flip(s, "v"), 0, 0)).toEqual([0, 1, 7, 255]);
        expect(rotate(s, 0)).toBe(s);
        expect(flip(s, "none")).toBe(s);
    });

    it("the grid: lines every tenth, the rest untouched, see-through made opaque", () => {
        const img: Rgba = { width: 100, height: 50, data: new Uint8Array(100 * 50 * 4) }; // all transparent black
        const g = drawGrid(img);
        const line = at(g, 10, 3);
        expect(line[3]).toBe(255);
        expect(line[0]).toBeGreaterThan(150); // magenta-ish
        expect(line[1]).toBe(0);
        expect(at(g, 3, 3)).toEqual([0, 0, 0, 255]);
        expect(at(g, 3, 25)[0]).toBeGreaterThan(150); // the half, across
        expect(GRID_RGB).toEqual([255, 0, 170]);
        expect(img.data[0 + 3]).toBe(0); // the input is not changed
    });

    it("the JSON body: defaults, cutout shorthand, and a refusal names the field", () => {
        expect(parseCropSpec({ crop: { x: 0, y: 0, w: 0.5, h: 0.5 } })).toEqual({
            ok: true,
            spec: { crop: { x: 0, y: 0, w: 0.5, h: 0.5 }, rotate: 0, flip: "none", cutout: null, title: null },
        });
        const c = parseCropSpec({ rotate: 90, cutout: true });
        expect(c.ok && c.spec.cutout).toMatchObject({ mode: "auto", trim: true });
        expect(parseCropSpec({})).toEqual({ ok: false, path: "crop" });
        expect(parseCropSpec({ crop: { x: 0.6, y: 0, w: 0.5, h: 0.5 } })).toEqual({ ok: false, path: "crop.w" });
        expect(parseCropSpec({ crop: { x: 1, y: 0, w: 0.5, h: 0.5 } })).toEqual({ ok: false, path: "crop.x" });
        expect(parseCropSpec({ crop: { x: 0, y: 0, w: 0.5, h: 0.5, z: 1 } })).toEqual({ ok: false, path: "crop.z" });
        expect(parseCropSpec({ rotate: 45 })).toEqual({ ok: false, path: "rotate" });
        expect(parseCropSpec({ flip: "x" })).toEqual({ ok: false, path: "flip" });
        expect(parseCropSpec({ cutout: { mode: "color" } })).toEqual({ ok: false, path: "cutout.color" });
        expect(parseCropSpec({ cutout: { title: "x" } })).toEqual({ ok: false, path: "cutout.title" });
        expect(parseCropSpec({ flip: "h", what: 1 })).toEqual({ ok: false, path: "what" });
    });
});

// ---- routes and the chat ------------------------------------------------------------------------------------------

let db: FakeD1;
let env: WorkerEnv;
let clock = 0;
let storage: Map<string, unknown>;
let imagesCalls: Record<string, unknown>[];
let imagesAnswers: Uint8Array[];
let imagesDefault: Uint8Array;

const st = {
    get: async <T,>(k: string) => storage.get(k) as T | undefined,
    put: async (k: string, v: unknown) => void storage.set(k, structuredClone(v)),
    delete: async (k: string) => storage.delete(k),
};
const container = {
    async fetch(req: Request): Promise<Response> {
        const p = new URL(req.url).pathname;
        if (p.startsWith("/chat/budget/")) return handleChatBudgetRoute(st, req, clock);
        return Response.json({ status: "error", error: { code: "error.test.unexpected" } }, { status: 500 });
    },
};
const edge = { now: () => clock, sleep: async (ms: number) => void (clock += ms) };
const images = {
    input(s: ReadableStream<Uint8Array>) {
        void s.cancel().catch(() => {});
        return {
            transform(t: Record<string, unknown>) {
                imagesCalls.push(t);
                const answer = imagesAnswers.shift() ?? imagesDefault;
                return { output: async (o: { format: string }) => ({ response: () => new Response(answer, { headers: { "content-type": o.format } }) }) };
            },
        };
    },
};

function cobalt(name: string, ...args: unknown[]) {
    const collect = { look: [], show: [] };
    const legacy = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: undefined, embed: null }, collect);
    const tools = chatToolbox(REGISTRY, opBase(env, container, edge, REGISTRY), {
        threadId: THREAD,
        messageId: "1",
        collect,
        legacy,
        flags: { search: false, box: true },
        pending: { put: async () => {}, take: async () => null, drop: async () => {} },
    }).tools;
    return tools[name]!(...args) as Promise<any>;
}
const thrown = async (p: Promise<unknown>) => {
    try {
        await p;
    } catch (e) {
        return (e as Error).message;
    }
    throw new Error("did not throw");
};

const file = (id: string, over: Record<string, unknown> = {}) => {
    const r = { content_type: "video/mp4", r2_key: `originals/${id}.mp4`, bucket: "originals", source: "saved", duration: 9.6 as number | null, width: 1080, height: 1920, name: `${id}.mp4`, ...over };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, key_id, created_at)
             VALUES (?, 'private', ?, ?, ?, NULL, ?, ?, 4096, ?, ?, ?, 'key-1', ?)`,
        )
        .run(id, r.source, r.bucket, r.r2_key, r.name, r.content_type, r.width, r.height, r.duration, clock);
};
const putObject = (bucket: unknown, key: string, bytes: Uint8Array, type: string) =>
    (bucket as MemoryOriginals).put(key, new Response(bytes).body!, { httpMetadata: { contentType: type }, customMetadata: {} });

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        IMAGES: images,
    };
    clock = 1_800_000_000_000;
    storage = new Map();
    imagesCalls = [];
    imagesAnswers = [];
    imagesDefault = await encodePng(sticker());
    file("VideoFile0000001");
    file("PhotoFile0000001", { content_type: "image/jpeg", r2_key: "uploads/PhotoFile0000001.jpg", duration: null, width: 1000, height: 1000, name: "shot.jpg", source: "upload" });
    file("PngFile000000001", { content_type: "image/png", r2_key: "uploads/PngFile000000001.png", duration: null, width: 10, height: 10, name: "small.png", source: "upload" });
    await putObject(env.ORIGINALS, "uploads/PhotoFile0000001.jpg", new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3]), "image/jpeg");
    await putObject(env.ORIGINALS, "uploads/PngFile000000001.png", await encodePng(coords(10, 10)), "image/png");
});

const post = (path: string, body: BodyInit, headers: Record<string, string>) =>
    handleRequest(new Request(`${API}${path}`, { method: "POST", headers: { ...AUTH, ...headers }, body }), env, container, edge);
const json = (b: unknown) => JSON.stringify(b);
const stored = async (id: string) => {
    const row = db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(id) as any;
    const obj = await env.ORIGINALS.get(row.r2_key);
    return { row, png: await decodePng(new Uint8Array(await new Response(obj!.body).arrayBuffer())) };
};

describe("POST /library/items/<id>/crop", () => {
    it("crops, turns and flips through Images (3072 max), stores a private png linked to the original", async () => {
        imagesDefault = await encodePng(coords(10, 10));
        const res = await post("/library/items/PhotoFile0000001/crop", json({ crop: { x: 0.2, y: 0.5, w: 0.3, h: 0.2 }, rotate: 90 }), { "content-type": "application/json" });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.crop).toEqual({ width: 2, height: 3 }); // 3 x 2 turned
        expect(b.title).toBe("shot crop");
        expect(imagesCalls).toEqual([{ width: 3072, height: 3072, fit: "scale-down" }]);
        const { row, png } = await stored(b.item.id);
        expect(row).toMatchObject({ kind: "private", source: "studio", bucket: "originals", content_type: "image/png", width: 2, height: 3, visibility: "private" });
        expect(row.r2_key).toMatch(/^crops\/[A-Za-z0-9]+\.png$/);
        expect(JSON.parse(row.made_from)).toEqual(["PhotoFile0000001"]);
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "crop", from: "PhotoFile0000001", crop: { x: 0.2, y: 0.5, w: 0.3, h: 0.2 }, rotate: 90, flip: "none" });
        // the crop was x 2..4, y 5..6; turned clockwise its bottom-left (2, 6) is now the top-left
        expect(at(png, 0, 0)).toEqual([2, 6, 7, 255]);
        expect(at(png, 1, 0)).toEqual([2, 5, 7, 255]);
        expect((db.raw.prepare("SELECT title FROM media_titles WHERE post_key = ?").get(b.item.id) as any).title).toBe("shot crop");
    });

    it("crop + cutout: white is taken out in the Worker and trimmed to the sticker; auto goes through Images twice", async () => {
        const res = await post("/library/items/PhotoFile0000001/crop", json({ crop: { x: 0.1, y: 0.1, w: 0.8, h: 0.8 }, cutout: { mode: "white", soften: 0 }, title: "cat" }), {
            "content-type": "application/json",
        });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.crop).toEqual({ width: 4, height: 4 });
        expect(b.title).toBe("cat");
        const { row } = await stored(b.item.id);
        expect(JSON.parse(row.made_spec).cutout).toEqual({ mode: "white", tolerance: 20, edges_only: true, soften: 0, trim: true });

        imagesCalls = [];
        const a = await post("/library/items/PhotoFile0000001/crop", json({ crop: { x: 0, y: 0, w: 1, h: 1 }, cutout: true }), { "content-type": "application/json" });
        expect(a.status).toBe(201);
        expect(imagesCalls).toEqual([{ width: 3072, height: 3072, fit: "scale-down" }, { segment: "foreground" }]);
    });

    it("the app's own png is stored as is and what it did is recorded; bad bodies and non-pictures are refused", async () => {
        const png = await encodePng(coords(6, 4));
        const res = await post("/library/items/PhotoFile0000001/crop?title=mine&x=0.1&y=0.2&w=0.5&h=0.5&rotate=270&flip=h&cutout=auto", png, { "content-type": "image/png" });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.crop).toEqual({ width: 6, height: 4 });
        expect(b.title).toBe("mine");
        expect(imagesCalls).toEqual([]);
        const { row } = await stored(b.item.id);
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "crop", from: "PhotoFile0000001", crop: { x: 0.1, y: 0.2, w: 0.5, h: 0.5 }, rotate: 270, flip: "h", cutout: { mode: "auto" }, device: true });
        expect((await post("/library/items/PhotoFile0000001/crop", new Uint8Array([1, 2, 3]), { "content-type": "image/png" })).status).toBe(400);
        expect((await post("/library/items/VideoFile0000001/crop", json({ flip: "h" }), { "content-type": "application/json" })).status).toBe(409);
        expect((await post("/library/items/Nothing000000001/crop", json({ flip: "h" }), { "content-type": "application/json" })).status).toBe(404);
        const bad = await post("/library/items/PhotoFile0000001/crop", json({ rotate: 45 }), { "content-type": "application/json" });
        expect(bad.status).toBe(400);
        expect(await bad.json()).toMatchObject({ error: { code: "error.crop.bad_request" }, path: "rotate" });
        const tiny = await post("/library/items/PhotoFile0000001/crop", json({ crop: { x: 0.5, y: 0.5, w: 0.01, h: 0.01 } }), { "content-type": "application/json" });
        expect(await tiny.json()).toMatchObject({ error: { code: "error.crop.bad_request" }, path: "crop" });
    });

    it("nothing left: 422; without Images a PNG is still cropped, a jpeg or an auto cutout is off", async () => {
        imagesDefault = await encodePng({ width: 4, height: 4, data: new Uint8Array(64).fill(255) });
        expect((await post("/library/items/PhotoFile0000001/crop", json({ cutout: { mode: "white" } }), { "content-type": "application/json" })).status).toBe(422);
        delete (env as any).IMAGES;
        const ok = await post("/library/items/PngFile000000001/crop", json({ crop: { x: 0.5, y: 0, w: 0.5, h: 0.3 }, flip: "v" }), { "content-type": "application/json" });
        expect(ok.status).toBe(201);
        const { png } = await stored(((await ok.json()) as any).item.id);
        expect([png.width, png.height]).toEqual([5, 3]);
        expect(at(png, 0, 0)).toEqual([5, 2, 7, 255]);
        const off = await post("/library/items/PhotoFile0000001/crop", json({ flip: "h" }), { "content-type": "application/json" });
        expect(off.status).toBe(503);
        expect(((await off.json()) as any).error.code).toBe("error.crop.off");
        expect((await post("/library/items/PngFile000000001/crop", json({ cutout: true }), { "content-type": "application/json" })).status).toBe(503);
    });

    it("capabilities say so", async () => {
        const r = await handleRequest(new Request(`${API}/capabilities`), env, container, edge);
        expect(((await r.json()) as any).features.image_crop).toBe(true);
    });
});

describe("cobalt.make.cropImage", () => {
    it("is done at once, costs one unit of the day's cap, and refuses a video", async () => {
        const j = await cobalt("make.cropImage", "PhotoFile0000001", { x: 0.3, y: 0.3, w: 0.4, h: 0.4 }, { cutout: { mode: "white", soften: 0 } });
        expect(j).toMatchObject({ status: "done", kind: "image", width: 4, height: 4, public: false, share_url: null });
        expect(j.job).toBe(`crop:${j.file_id}`);
        expect((storage.get(`chat:budget:${THREAD}:renders`) as { n: number }).n).toBe(1);
        expect(await thrown(cobalt("make.cropImage", "VideoFile0000001", { x: 0, y: 0, w: 1, h: 1 }))).toMatch(/has no picture/);
        expect(await thrown(cobalt("make.cropImage", "PhotoFile0000001"))).toMatch(/give crop/);
        expect(await thrown(cobalt("make.cropImage", "PhotoFile0000001", { x: 0.8, y: 0, w: 0.5, h: 0.5 }))).toMatch(/past the picture's edge/);
    });

    it("a failed crop gives the unit back and says why", async () => {
        imagesDefault = await encodePng({ width: 4, height: 4, data: new Uint8Array(64).fill(255) });
        expect(await thrown(cobalt("make.cropImage", "PhotoFile0000001", undefined, { cutout: { mode: "white" } }))).toMatch(/error\.crop\.empty/);
        expect((storage.get(`chat:budget:${THREAD}:renders`) as { n: number }).n).toBe(0);
    });

    it("make.crop (videos) points a picture to make.cropImage", async () => {
        expect(await thrown(cobalt("make.crop", "PhotoFile0000001", { x: 0, y: 0, w: 0.5, h: 0.5 }))).toMatch(/make\.cropImage/);
    });
});

describe("look (44.3)", () => {
    it("look(ids, { grid, frames }) remembers what was asked per post", async () => {
        const collect: ChatCollect = { look: [], show: [] };
        const t = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: undefined, embed: null }, collect);
        await t.look!(["PhotoFile0000001"], { grid: true });
        await t.look!(["PhotoFile0000001", "VideoFile0000001"], { frames: true });
        expect(collect.look).toEqual(["PhotoFile0000001", "VideoFile0000001"]);
        expect(collect.lookOpts).toEqual({ PhotoFile0000001: { grid: true, frames: true }, VideoFile0000001: { frames: true } });
    });

    const deps = () => ({ db: db as unknown as D1Database, mediaBaseUrl: MEDIA, originals: env.ORIGINALS as never, media: env.MEDIA as never, images: null });

    it("a private picture is read from R2 and sent inline; with a grid the lines are drawn", async () => {
        const m = await lookImages(deps(), ["PngFile000000001"]);
        const [img] = m.get("PngFile000000001")!;
        expect(img).toMatchObject({ label: "Picture of post PngFile000000001:", mediaType: "image/png" });
        const plain = await decodePng(Uint8Array.from(atob(img!.data!), (c) => c.charCodeAt(0)));
        expect(at(plain, 1, 1)).toEqual([1, 1, 7, 255]);
        const g = (await lookImages(deps(), ["PngFile000000001"], { PngFile000000001: { grid: true } })).get("PngFile000000001")![0]!;
        expect(g.label).toMatch(/grid lines every 0\.1/);
        const grid = await decodePng(Uint8Array.from(atob(g.data!), (c) => c.charCodeAt(0)));
        expect(at(grid, 1, 0)[0]).toBeGreaterThan(150); // the line at a tenth of the width
        // a small jpeg without Images goes as is; with a grid it can't be drawn without Images
        expect((await lookImages(deps(), ["PhotoFile0000001"])).get("PhotoFile0000001")![0]).toMatchObject({ mediaType: "image/jpeg" });
        expect((await lookImages(deps(), ["PhotoFile0000001"], { PhotoFile0000001: { grid: true } })).get("PhotoFile0000001")).toEqual([]);
    });

    it("frames: the stored frames of a video, after its poster; none says so", async () => {
        const jpg = new Uint8Array([0xff, 0xd8, 0xff, 9]);
        for (const n of [1, 2]) await putObject(env.ORIGINALS, `about/VideoFile0000001/frame-${n}.jpg`, jpg, "image/jpeg");
        const list = (await lookImages(deps(), ["VideoFile0000001"], { VideoFile0000001: { frames: true } })).get("VideoFile0000001")!;
        expect(list.map((i) => i.label)).toEqual(["Picture of post VideoFile0000001:", "Frame 1 across video post VideoFile0000001:", "Frame 2 across video post VideoFile0000001:"]);
        const blocks = lookBlocks("VideoFile0000001", list, true);
        expect(blocks[1]).toMatchObject({ type: "image", source: { type: "base64", media_type: "image/jpeg" } });
        expect(lookBlocks("PngFile000000001", [], false)).toEqual([{ type: "text", text: "Post PngFile000000001 has no picture to look at." }]);
        const nf = lookBlocks("PngFile000000001", [{ label: "Picture of post PngFile000000001:", url: "https://x/y.png" }], true);
        expect(nf.at(-1)).toEqual({ type: "text", text: "Post PngFile000000001 has no stored frames (not a video, or not described yet)." });
    });

    it("pictures sent inline are not saved with the message", () => {
        const api = [{ role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } }, { type: "image", source: { type: "url", url: "u" } }] }] }];
        expect(dropInlineImages(api)[0].content[0].content).toEqual([{ type: "text", text: "[a picture you looked at earlier]" }, { type: "image", source: { type: "url", url: "u" } }]);
    });
});

// ---- make.frames (44.7) -------------------------------------------------------------------------------------------

describe("cobalt.make.frames", () => {
    let runs: string[];
    let files: Map<string, Uint8Array>;
    let runAnswer: { code: number; stdout: string; stderr: string; timed_out: boolean; ms: number };
    const port = {
        async write(_t: string, name: string, body: ReadableStream<Uint8Array>) {
            const b = new Uint8Array(await new Response(body).arrayBuffer());
            files.set(name, b);
            return { size: b.length };
        },
        async run(_t: string, cmd: string) {
            runs.push(cmd);
            // "ffmpeg" writes a frame for every line that asks for one inside the 9.6 s video
            for (const m of cmd.matchAll(/-ss ([0-9.]+) .* (frames-out\/f\d+\.png)/g)) if (Number(m[1]) <= 9.6) files.set(m[2]!, await encodePng(coords(12, 8)));
            return runAnswer;
        },
        async stat() {
            return { error: "unused" };
        },
        async read(_t: string, path: string) {
            const b = files.get(path);
            return b ? new Response(b).body! : { error: `no such file: ${path}` };
        },
    };

    beforeEach(async () => {
        runs = [];
        files = new Map();
        runAnswer = { code: 0, stdout: "", stderr: "", timed_out: false, ms: 5 };
        (env as any).WORKBENCH = { idFromName: () => "main", get: () => port };
        await putObject(env.ORIGINALS, "originals/VideoFile0000001.mp4", new Uint8Array([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]), "video/mp4");
    });

    it("where the frames go", () => {
        expect(frameTimes(10, undefined, undefined)).toEqual([5]);
        expect(frameTimes(10, undefined, 4)).toEqual([1.25, 3.75, 6.25, 8.75]);
        expect(frameTimes(10, [3, 1, 3], undefined)).toEqual([1, 3]);
        expect(frameTimes(10, [11], undefined)).toBe("the video is 10 s long");
        expect(frameTimes(null, undefined, 2)).toMatch(/length is unknown/);
    });

    it("cuts frames in the box and saves each as a private png linked to the video", async () => {
        const r = await cobalt("make.frames", "VideoFile0000001", { at: [1.5, 3] });
        expect(r.frames.map((f: any) => [f.at, f.width, f.height])).toEqual([[1.5, 12, 8], [3, 12, 8]]);
        expect(files.has("frames-src-VideoFile0000001.mp4")).toBe(true);
        expect(runs[0]).toContain("-ss 1.5 -i frames-src-VideoFile0000001.mp4 -frames:v 1");
        expect(runs[0]).toContain("min(iw,3072)");
        const row = db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(r.frames[0].file_id) as any;
        expect(row).toMatchObject({ kind: "private", source: "studio", content_type: "image/png", width: 12, height: 8 });
        expect(row.r2_key).toMatch(/^frames\//);
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "frame", from: "VideoFile0000001", at: 1.5 });
        expect((db.raw.prepare("SELECT title FROM media_titles WHERE post_key = ?").get(r.frames[1].file_id) as any).title).toBe("VideoFile0000001 frame 0:03.0");
        expect((storage.get(`chat:budget:${THREAD}:renders`) as { n: number }).n).toBe(1);
        // the frame is a picture like any other: crop it
        const c = await cobalt("make.cropImage", r.frames[0].file_id, { x: 0, y: 0, w: 0.5, h: 0.5 });
        expect(c).toMatchObject({ status: "done", kind: "image" });
    });

    it("refuses a picture and too many frames; ffmpeg failing gives the unit back", async () => {
        expect(await thrown(cobalt("make.frames", "PhotoFile0000001"))).toMatch(/has no video/);
        expect(await thrown(cobalt("make.frames", "VideoFile0000001", { at: [20] }))).toMatch(/9\.6 s long/);
        runAnswer = { code: 1, stdout: "", stderr: "boom", timed_out: false, ms: 5 };
        expect(await thrown(cobalt("make.frames", "VideoFile0000001"))).toMatch(/ffmpeg failed: boom/);
        expect((storage.get(`chat:budget:${THREAD}:renders`) as { n: number } | undefined)?.n ?? 0).toBe(0);
    });
});
