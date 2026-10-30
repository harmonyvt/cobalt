// Section 39: cutouts (cutout-core's colour rules and PNG codec, POST /library/items/<id>/cutout both ways, the chat's
// cobalt.make.cutout) and cobalt.edits.addOverlay (free layer, sizing, placement, order). Real SQL on node:sqlite; the
// Images binding is a fake that "decodes" by handing back a PNG the test made.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { chatTools } from "../src/chat-tools";
import { cutout, decodePng, encodePng, parseHexColor, type Rgba } from "../src/cutout-core";
import { parseSpec } from "../src/cutout";
import { hashKey } from "../src/keys";
import { handleChatBudgetRoute } from "../src/registry/budget";
import { chatToolbox, opBase, REGISTRY } from "../src/registry/index";
import { freeTrack, placeAt } from "../src/registry/ops/editor";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const THREAD = "ThReAd0123456789";

// ---- the pure part ------------------------------------------------------------------------------------------------

/** A w x h picture: white background, a 4x4 orange square in the middle with a white 2x2 "eye" inside, alpha 255. */
function sticker(w = 10, h = 10): Rgba {
    const d = new Uint8Array(w * h * 4).fill(255);
    for (let y = 3; y < 7; y++) for (let x = 3; x < 7; x++) d.set([230, 130, 50, 255], (y * w + x) * 4);
    for (let y = 4; y < 6; y++) for (let x = 4; x < 6; x++) d.set([255, 255, 255, 255], (y * w + x) * 4);
    return { width: w, height: h, data: d };
}
const alpha = (img: Rgba, x: number, y: number) => img.data[(y * img.width + x) * 4 + 3];

describe("cutout-core", () => {
    it("white, edges only: the outside goes, the white eye stays; trim crops to the subject", () => {
        const r = cutout(sticker(), { mode: "white", tolerance: 10, edgesOnly: true, soften: 0, trim: false })!;
        expect([alpha(r, 0, 0), alpha(r, 9, 9), alpha(r, 2, 5)]).toEqual([0, 0, 0]);
        expect([alpha(r, 3, 3), alpha(r, 4, 4)]).toEqual([255, 255]);
        const t = cutout(sticker(), { mode: "white", tolerance: 10, edgesOnly: true, soften: 0, trim: true })!;
        expect([t.width, t.height]).toEqual([4, 4]);
    });

    it("white everywhere: the eye goes too", () => {
        const r = cutout(sticker(), { mode: "white", tolerance: 10, edgesOnly: false, soften: 0, trim: false })!;
        expect(alpha(r, 4, 4)).toBe(0);
        expect(alpha(r, 3, 3)).toBe(255);
    });

    it("soften lowers the subject's edge, not its middle; tolerance decides what counts as background", () => {
        const r = cutout(sticker(), { mode: "white", tolerance: 10, edgesOnly: true, soften: 1, trim: false })!;
        expect(alpha(r, 3, 3)).toBeLessThan(255);
        expect(alpha(r, 3, 3)).toBeGreaterThan(0);
        // an off-white background survives a tolerance of 0 and goes at 10
        const s = sticker();
        for (let p = 0; p < 100; p++) if (s.data[p * 4] === 255 && s.data[p * 4 + 1] === 255) s.data.set([245, 245, 245], p * 4);
        expect(alpha(cutout(s, { mode: "white", tolerance: 0, edgesOnly: true, soften: 0, trim: false })!, 0, 0)).toBe(255);
        expect(alpha(cutout(s, { mode: "white", tolerance: 10, edgesOnly: true, soften: 0, trim: false })!, 0, 0)).toBe(0);
    });

    it("a colour key; nothing left is null", () => {
        const r = cutout(sticker(), { mode: "color", color: [230, 130, 50], tolerance: 5, edgesOnly: false, soften: 0, trim: false })!;
        expect([alpha(r, 3, 3), alpha(r, 0, 0)]).toEqual([0, 255]);
        const plain: Rgba = { width: 4, height: 4, data: new Uint8Array(64).fill(255) };
        expect(cutout(plain, { mode: "white", tolerance: 10, edgesOnly: true, soften: 0, trim: true })).toBeNull();
        expect(parseHexColor("#0f8")).toEqual([0, 255, 136]);
        expect(parseHexColor("12345")).toBeNull();
    });

    it("PNG round trip", async () => {
        const s = sticker(12, 9);
        const png = await encodePng(s);
        const back = await decodePng(png);
        expect([back.width, back.height]).toEqual([12, 9]);
        expect([...back.data]).toEqual([...s.data]);
    });

    it("the JSON spec: defaults, and a refusal names the field", () => {
        expect(parseSpec({})).toEqual({ ok: true, spec: { mode: "auto", color: null, tolerance: 20, edges_only: true, soften: 1, trim: true, title: null } });
        expect(parseSpec({ mode: "color" })).toEqual({ ok: false, path: "color" });
        expect(parseSpec({ mode: "white", tolerance: 101 })).toEqual({ ok: false, path: "tolerance" });
        expect(parseSpec({ mode: "white", what: 1 })).toEqual({ ok: false, path: "what" });
    });

    it("placement and free layers", () => {
        const tr = placeAt("top-right", 0.3, 0.2, { w: 1080, h: 1920 });
        expect([tr.x, tr.y].map((v) => Math.round(v * 1e4) / 1e4)).toEqual([0.66, 0.0225]);
        expect(placeAt("center", 0.5, 0.5, { w: 1080, h: 1080 })).toEqual({ x: 0.25, y: 0.25 });
        const ov = [{ id: "a", at: 0, in: 0, out: 2 }, { id: "b", at: 1, in: 0, out: 2, track: 1 }];
        expect(freeTrack(ov, 1.5, 1, 30)).toBe(2);
        expect(freeTrack(ov, 2, 1, 30)).toBe(0);
        expect(freeTrack(ov, 1.5, 1, 30, 1)).toBe(2);
    });
});

// ---- routes and the chat ------------------------------------------------------------------------------------------

let db: FakeD1;
let env: WorkerEnv;
let clock = 0;
let storage: Map<string, unknown>;
let imagesCalls: Record<string, unknown>[];
let imagesAnswer: Uint8Array;

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
const renderers = { idFromName: (n: string) => n, get: () => ({ fetch: async () => new Response(null, { status: 202 }) }) };
const edge = { now: () => clock, sleep: async (ms: number) => void (clock += ms) };
const images = {
    input(s: ReadableStream<Uint8Array>) {
        void s.cancel().catch(() => {});
        return {
            transform(t: Record<string, unknown>) {
                imagesCalls.push(t);
                return { output: async (o: { format: string }) => ({ response: () => new Response(imagesAnswer, { headers: { "content-type": o.format } }) }) };
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
        flags: { search: false },
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
        EDIT_RENDERER: renderers as unknown as DurableObjectNamespace,
        IMAGES: images,
    };
    clock = 1_800_000_000_000;
    storage = new Map();
    imagesCalls = [];
    imagesAnswer = await encodePng(sticker());
    file("VideoFile0000001");
    file("VideoFile0000002", { duration: 2, width: 1920, height: 1080 });
    file("PhotoFile0000001", { content_type: "image/jpeg", r2_key: "uploads/PhotoFile0000001.jpg", duration: null, width: 1000, height: 1000, name: "logo.jpg", source: "upload" });
    file("EmoteFile0000001", { content_type: "image/webp", r2_key: "AbCdEfGhIj.webp", bucket: "media", duration: null, width: 128, height: 64, source: "emote", name: "catJAM.webp" });
    await (env.ORIGINALS as MemoryOriginals).put("uploads/PhotoFile0000001.jpg", new Blob([new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3])]).stream(), { httpMetadata: { contentType: "image/jpeg" }, customMetadata: {} });
});

const post = (path: string, body: BodyInit, headers: Record<string, string>) =>
    handleRequest(new Request(`${API}${path}`, { method: "POST", headers: { ...AUTH, ...headers }, body }), env, container, edge);

describe("POST /library/items/<id>/cutout", () => {
    it("white: the server decodes through Images (2048 max), takes out the white, stores a private png linked to the original", async () => {
        const res = await post("/library/items/PhotoFile0000001/cutout", JSON.stringify({ mode: "white", tolerance: 10, soften: 0 }), { "content-type": "application/json" });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.cutout).toEqual({ width: 4, height: 4, mode: "white" });
        expect(b.title).toBe("logo cutout");
        expect(imagesCalls).toEqual([{ width: 2048, height: 2048, fit: "scale-down" }]);
        const row = db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(b.item.id) as any;
        expect(row).toMatchObject({ kind: "private", source: "studio", bucket: "originals", content_type: "image/png", width: 4, height: 4, visibility: "private" });
        expect(JSON.parse(row.made_from)).toEqual(["PhotoFile0000001"]);
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "cutout", from: "PhotoFile0000001", mode: "white", tolerance: 10, edges_only: true, soften: 0, trim: true });
        const obj = await env.ORIGINALS.get(row.r2_key);
        const png = await decodePng(new Uint8Array(await new Response(obj!.body).arrayBuffer()));
        expect(png.data[(1 * 4 + 1) * 4 + 3]).toBe(255); // the eye, kept
        expect((db.raw.prepare("SELECT title FROM media_titles WHERE post_key = ?").get(b.item.id) as any).title).toBe("logo cutout");
    });

    it("auto asks Images to lift the subject", async () => {
        const res = await post("/library/items/PhotoFile0000001/cutout", "{}", { "content-type": "application/json" });
        expect(res.status).toBe(201);
        expect(imagesCalls[0]).toMatchObject({ segment: "foreground" });
    });

    it("the app's own png is stored as the cutout (no Images call); bad bodies and non-pictures are refused", async () => {
        const png = await encodePng(sticker(10, 7));
        const res = await post("/library/items/PhotoFile0000001/cutout?title=mine&mode=auto", png, { "content-type": "image/png" });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.cutout).toEqual({ width: 10, height: 7, mode: "auto" });
        expect(imagesCalls).toEqual([]);
        expect(JSON.parse((db.raw.prepare("SELECT made_spec FROM media_items WHERE id = ?").get(b.item.id) as any).made_spec)).toMatchObject({ device: true, mode: "auto" });
        expect((await post("/library/items/PhotoFile0000001/cutout", new Uint8Array([1, 2, 3]), { "content-type": "image/png" })).status).toBe(400);
        expect((await post("/library/items/VideoFile0000001/cutout", "{}", { "content-type": "application/json" })).status).toBe(409);
        expect((await post("/library/items/Nothing000000001/cutout", "{}", { "content-type": "application/json" })).status).toBe(404);
        expect((await post("/library/items/PhotoFile0000001/cutout", '{"mode":"color"}', { "content-type": "application/json" })).status).toBe(400);
    });

    it("nothing left: 422; without the Images binding a jpeg cannot be done here", async () => {
        imagesAnswer = await encodePng({ width: 4, height: 4, data: new Uint8Array(64).fill(255) });
        expect((await post("/library/items/PhotoFile0000001/cutout", '{"mode":"white"}', { "content-type": "application/json" })).status).toBe(422);
        delete (env as any).IMAGES;
        const r = await post("/library/items/PhotoFile0000001/cutout", '{"mode":"white"}', { "content-type": "application/json" });
        expect(r.status).toBe(503);
        expect(((await r.json()) as any).error.code).toBe("error.cutout.off");
    });
});

describe("cobalt.make.cutout and cobalt.edits.addOverlay", () => {
    it("make.cutout is done at once and costs one unit of the day's cap", async () => {
        const j = await cobalt("make.cutout", "PhotoFile0000001", { mode: "white" });
        expect(j).toMatchObject({ status: "done", kind: "image", width: 4, height: 4, public: false });
        expect(j.job).toBe(`cutout:${j.file_id}`);
        expect((storage.get(`chat:budget:${THREAD}:renders`) as { n: number }).n).toBe(1);
        expect(await thrown(cobalt("make.cutout", "VideoFile0000001"))).toMatch(/has no picture/);
    });

    const timeline = () => ({ version: 1, canvas: { w: 1080, h: 1920, fps: 30 }, main: [{ id: "a", item: "VideoFile0000001", in: 0, out: 8, speed: 1, fit: "fill", volume: 1, muted: false }], overlay: [] });

    it("stacks: each overlay at the same time takes the next free layer; sized from its shape; placed by name", async () => {
        const p = await cobalt("edits.create", timeline());
        const a = await cobalt("edits.addOverlay", p.id, "EmoteFile0000001", { position: "top-right", size: 0.3 });
        expect(a).toMatchObject({ revision: 2, clip: "ov1", track: 0 });
        const b = await cobalt("edits.addOverlay", p.id, "PhotoFile0000001", { position: "bottom-left", at: 1, seconds: 3 });
        expect(b.track).toBe(1);
        const c = await cobalt("edits.addOverlay", p.id, "VideoFile0000002", { at: 0.5, muted: false });
        expect(c.track).toBe(2);
        const g = await cobalt("edits.get", p.id);
        const ov = g.timeline.overlay;
        expect(ov.map((o: any) => [o.id, o.at, o.track ?? 0])).toEqual([["ov1", 0, 0], ["ov3", 0.5, 2], ["ov2", 1, 1]]);
        // the emote: 2:1, 0.3 wide, top right, shown to the end
        expect(ov[0]).toMatchObject({ item: "EmoteFile0000001", in: 0, out: 8, frame: { x: 0.66, y: 0.0225, w: 0.3 }, muted: true });
        // the video overlay: its own length (2 s), sound on
        expect(ov[1]).toMatchObject({ item: "VideoFile0000002", in: 0, out: 2, muted: false });
        expect(g.sources.EmoteFile0000001).toMatchObject({ kind: "photo", content_type: "image/webp", source: "emote" });
    });

    it("a busy layer asked for by number is refused; a hidden or unknown file too", async () => {
        const p = await cobalt("edits.create", timeline());
        await cobalt("edits.addOverlay", p.id, "PhotoFile0000001");
        expect(await thrown(cobalt("edits.addOverlay", p.id, "EmoteFile0000001", { track: 0 }))).toMatch(/layer 0 is busy/);
        expect(await thrown(cobalt("edits.addOverlay", p.id, "Nothing000000001"))).toMatch(/no post or file/);
        expect(await thrown(cobalt("edits.addOverlay", p.id, "EmoteFile0000001", { at: 8 }))).toMatch(/before the end/);
    });
});
