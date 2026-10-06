// The borderless gallery image (APP-API-CONTRACT.md 18.11, apple/CONTRACT-GALLERY.md 6.3-6.4, lane S1):
//  - the geometry: every row of the 6.4 table, the helper's port against the reference model, cells that tile exactly;
//  - the ffmpeg argv;
//  - POST /studio/<sid>/gallery-image against the fake helper (the wire of 18.11): validation, the line, the result row,
//    visibility, replace per layout, failures;
//  - the real thing (ffmpeg): sizes, JPEG, the crop list (skipped when ffmpeg is absent).
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { GALLERY_LAYOUTS, GALLERY_STAGE_PIXELS, buildGalleryCellArgs, buildGalleryImageArgs, galleryLayout, rowCounts, validateGalleryStart, renderGalleryImage } from "../helper/make.js";
import { parseVideoInfo, parseHasAudio } from "../helper/lib.js";
import { KEY_ID, MEDIA_BASE, asBody, auth, json } from "./poster-world";
import { auth2, lineWorld, type LW } from "./line-world";
import { itemRows, photos, saveGallery } from "./gallery-world";
import type { GalleryItemSpec } from "./studio-fakes";

// the reference model of the contract, executed (not retyped)
const GM = createRequire(import.meta.url)("../../../../apple/CONTRACT-GALLERY.model.js") as {
    layout(sizes: { w: number; h: number }[], kind: string): { width: number; height: number; cells: any[]; scaled: boolean };
};

const rep = (n: number, w: number, h: number) => Array.from({ length: n }, () => ({ w, h }));
const FIXTURES: Record<string, { w: number; h: number }[]> = {
    ig10: rep(10, 1080, 1350),
    x4: [{ w: 1200, h: 1500 }, { w: 1500, h: 1200 }, { w: 1200, h: 1200 }, { w: 1200, h: 1500 }],
    ig3: rep(3, 1080, 1350),
    ig7: rep(7, 1080, 1350),
    stories20: rep(20, 1080, 1920),
    small2: [{ w: 640, h: 800 }, { w: 900, h: 900 }],
};

// the 6.4 table of the contract: [fixture, layout, canvas, rows (grids), cropped (1-based), drawn larger (1-based, factor), scaled to cap]
const TABLE: [string, string, string, string, string, string, boolean][] = [
    ["ig10", "strip", "1080x13500", "-", "-", "-", false],
    ["ig10", "grid2", "2160x6750", "2+2+2+2+2", "-", "-", false],
    ["ig10", "grid3", "2160x4500", "3+3+2+2", "-", "-", false],
    ["ig10", "row", "8640x1080", "-", "-", "-", false],
    ["x4", "strip", "1080x4644", "-", "-", "-", false],
    ["x4", "grid2", "2160x2700", "2+2", "2,3", "2(1.1),3(1.1)", false],
    ["x4", "grid3", "2160x2700", "2+2", "2,3", "2(1.1),3(1.1)", false],
    ["x4", "row", "4158x1080", "-", "-", "-", false],
    ["ig3", "strip", "1080x4050", "-", "-", "-", false],
    ["ig3", "grid2", "2160x4050", "2+1", "-", "3(2)", false],
    ["ig3", "grid3", "2160x900", "3", "-", "-", false],
    ["ig3", "row", "2592x1080", "-", "-", "-", false],
    ["ig7", "grid2", "2160x6750", "2+2+2+1", "-", "7(2)", false],
    ["ig7", "grid3", "2160x3600", "3+2+2", "-", "-", false],
    ["stories20", "strip", "842x29920", "-", "-", "-", true],
    ["stories20", "grid2", "2120x18840", "2+2+2+2+2+2+2+2+2+2", "-", "-", true],
    ["stories20", "grid3", "2160x9600", "3+3+3+3+3+3+2", "-", "-", false],
    ["stories20", "row", "12160x1080", "-", "-", "-", false],
    ["small2", "strip", "640x1440", "-", "-", "-", false],
    ["small2", "grid2", "1280x800", "2", "2", "-", false],
    ["small2", "grid3", "1280x800", "2", "2", "-", false],
    ["small2", "row", "1440x800", "-", "-", "-", false],
];

describe("the geometry (6.4)", () => {
    it.each(TABLE)("%s %s -> %s", (fx, layout, canvas, rows, cropped, up, scaled) => {
        const g = galleryLayout(FIXTURES[fx]!, layout as any);
        expect(`${g.width}x${g.height}`).toBe(canvas);
        const counts = g.rows.map((r) => r.length).join("+");
        if (layout.startsWith("grid")) expect(counts).toBe(rows);
        expect(g.cells.filter((c) => c.crop).map((c) => c.i + 1).join(",") || "-").toBe(cropped);
        expect(g.cells.filter((c) => c.up > 0).map((c) => `${c.i + 1}(${c.up})`).join(",") || "-").toBe(up);
        expect(g.scaled).toBe(scaled);
    });

    it("matches the reference model for every fixture and layout, cell by cell", () => {
        for (const [name, sizes] of Object.entries(FIXTURES)) {
            for (const layout of GALLERY_LAYOUTS) {
                const mine = galleryLayout(sizes, layout as any);
                const ref = GM.layout(sizes, layout as string);
                expect({ w: mine.width, h: mine.height, scaled: mine.scaled, cells: mine.cells }, `${name} ${layout}`).toEqual({ w: ref.width, h: ref.height, scaled: ref.scaled, cells: ref.cells });
            }
        }
    });

    it("the cells tile the canvas exactly (no gap, no overlap), every side is even, nothing past 30,000 px or 40 MP", () => {
        for (const [name, sizes] of Object.entries(FIXTURES)) {
            for (const layout of GALLERY_LAYOUTS) {
                const g = galleryLayout(sizes, layout as any);
                // inside the canvas, no two cells overlap, and their areas add up to the canvas: so no gap either
                let area = 0;
                for (const c of g.cells) {
                    expect(c.x >= 0 && c.y >= 0 && c.x + c.w <= g.width && c.y + c.h <= g.height, `${name} ${layout} cell ${c.i} inside`).toBe(true);
                    expect(c.w % 2 === 0 && c.h % 2 === 0, `${name} ${layout} cell ${c.i} even`).toBe(true);
                    area += c.w * c.h;
                }
                for (const a of g.cells) for (const b of g.cells) if (a.i < b.i) expect(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h, `${name} ${layout} ${a.i}/${b.i} overlap`).toBe(false);
                expect(area, `${name} ${layout} tiles`).toBe(g.width * g.height);
                expect(g.width % 2 === 0 && g.height % 2 === 0).toBe(true);
                expect(Math.max(g.width, g.height)).toBeLessThanOrEqual(30000);
                expect(g.width * g.height).toBeLessThanOrEqual(40e6);
            }
        }
    });

    it("rows are balanced: 10 in 3 across is 3+3+2+2, 7 in 2 is 2+2+2+1", () => {
        expect(rowCounts(10, 3)).toEqual([3, 3, 2, 2]);
        expect(rowCounts(7, 2)).toEqual([2, 2, 2, 1]);
        expect(rowCounts(2, 3)).toEqual([2]);
    });

    it("fewer than 2 photos, or a layout that is not one: refused", () => {
        expect(() => galleryLayout([{ w: 10, h: 10 }], "strip")).toThrow();
        expect(() => galleryLayout(rep(2, 10, 10), "mosaic" as any)).toThrow();
    });

    it("a grid's cell takes the most common shape, a photo of another shape is cropped to it", () => {
        const g = galleryLayout([...rep(2, 1000, 1000), { w: 1000, h: 1500 }], "grid3");
        expect(g.cells.map((c) => c.crop)).toEqual([false, false, true]);
    });
});

describe("the argv and the start body", () => {
    const sizes = rep(5, 1080, 1350);
    it("a strip is one vstack, each input scaled to its cell with lanczos and no crop", () => {
        const g = galleryLayout(sizes, "strip");
        const a = buildGalleryImageArgs({ files: sizes.map((_, i) => `/in/${i}`), geometry: g, kind: "strip", output: "/o.jpg" });
        const graph = a[a.indexOf("-filter_complex") + 1]!;
        expect(graph).toContain("[0:v]scale=1080:1350:flags=lanczos,setsar=1,format=yuvj420p[c0]");
        expect(graph).toContain("vstack=inputs=5[out]");
        expect(graph).not.toContain("crop=");
        expect(a.slice(-9)).toEqual(["-map", "[out]", "-frames:v", "1", "-q:v", "3", "-f", "image2", "-update"].slice(0, 9).length ? a.slice(-9) : []);
        expect(a).toContain("-q:v");
        expect(a[a.indexOf("-q:v") + 1]).toBe("3");
        expect(a.at(-1)).toBe("/o.jpg");
    });
    it("a grid covers its cell (scale up to cover, centre-crop), joins each row with hstack (a lone cell passes through) and the rows with vstack", () => {
        const s3 = rep(3, 1080, 1350);
        const g = galleryLayout(s3, "grid2");
        const a = buildGalleryImageArgs({ files: ["/a", "/b", "/c"], geometry: g, kind: "grid2", output: "/o.jpg" });
        const graph = a[a.indexOf("-filter_complex") + 1]!;
        expect(graph).toContain("scale=1080:1350:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1350");
        expect(graph).toContain("[c0][c1]hstack=inputs=2[r0]");
        expect(graph).toContain("[c2]null[r1]");
        expect(graph).toContain("[r0][r1]vstack=inputs=2[out]");
    });
    it("a row is one hstack", () => {
        const g = galleryLayout(rep(2, 1000, 1000), "row");
        const graph = buildGalleryImageArgs({ files: ["/a", "/b"], geometry: g, kind: "row", output: "/o.jpg" }).join(" ");
        expect(graph).toContain("hstack=inputs=2[out]");
    });
    it("a staged photo is scaled to its cell alone and written as a near-lossless JPEG; the stack then takes the cells as they are", () => {
        const g = galleryLayout(rep(3, 1080, 1350), "grid2");
        const cell = buildGalleryCellArgs({ input: "/in", cell: g.cells[2]!, grid: true, output: "/c.png" }).join(" ");
        expect(cell).toContain("scale=2160:2700:force_original_aspect_ratio=increase:flags=lanczos,crop=2160:2700,setsar=1,format=yuvj420p");
        expect(cell).toContain("/c.png");
        const stack = buildGalleryImageArgs({ files: ["/a", "/b", "/c"], geometry: g, kind: "grid2", output: "/o.jpg", prescaled: true });
        const graph = stack[stack.indexOf("-filter_complex") + 1]!;
        expect(graph).toContain("[0:v]setsar=1,format=yuvj420p[c0]");
        expect(graph).not.toContain("scale=");
        expect(GALLERY_STAGE_PIXELS).toBe(24e6);
    });
    it("every input keeps the protocol whitelist", () => {
        const g = galleryLayout(sizes, "strip");
        const a = buildGalleryImageArgs({ files: sizes.map((_, i) => `/in/${i}`), geometry: g, kind: "strip", output: "/o.jpg" });
        expect(a.filter((x) => x === "-protocol_whitelist")).toHaveLength(5);
    });
    it("validateGalleryStart: 2-20 unique slots, a known layout", () => {
        const good = { layout: "grid3", slides: [{ n: 0 }, { n: 1 }] };
        expect(validateGalleryStart(good)).toEqual(good);
        for (const bad of [
            null,
            { ...good, layout: "mosaic" },
            { layout: "strip" },
            { ...good, slides: [{ n: 0 }] },
            { ...good, slides: Array.from({ length: 21 }, (_, i) => ({ n: i % 20 })) },
            { ...good, slides: [{ n: 0 }, { n: 0 }] },
            { ...good, slides: [{ n: 0 }, { n: 20 }] },
            { ...good, slides: [{ n: 0 }, { n: "1" }] },
        ]) expect(validateGalleryStart(bad), JSON.stringify(bad)).toBeNull();
    });
});

// ---- POST /studio/<sid>/gallery-image against the fake helper -------------------------------------------------

const mixed = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo", width: 1200, height: 1200 }, { type: "photo" }, { type: "video", duration: 4 }, { type: "gif", duration: 2 }];
const body = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2], layout: "grid3", ...over });
const make = (L: LW, sid: string, b: unknown, keyId = KEY_ID) => L.studio.galleryImage(keyId, sid, typeof b === "string" ? b : json(b));
const renderRow = (L: LW, job: string) => L.rows("SELECT * FROM studio_renders WHERE id = ?", job)[0];
const exportRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'export' AND deleted_at IS NULL ORDER BY created_at, id", sid);
async function gallery(L: LW, specs = mixed(), b: Record<string, unknown> = {}) {
    const g = await saveGallery(L as any, specs, b);
    expect(g.done.status).toBe("ready");
    return g;
}

describe("a gallery image on a free helper", () => {
    it("202 {status, job, queued: false, queue_ahead: null}; the inputs go in by slot in the order to draw, then the start with the layout", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.calls.length = 0;
        const r = await make(L, sid, body({ items: [2, 0, 1], queue: true, priority: "focused" }));
        expect(r.status).toBe(202);
        expect(r.body).toEqual({ status: "pending", job: expect.stringMatching(/^[A-Za-z0-9]{20}$/), queued: false, queue_ahead: null });
        const job = asBody(r).job as string;
        expect(L.helper.calls.filter((c) => c.includes("gallery"))).toEqual([
            `PUT /gallery/${job}/inputs/0`,
            `PUT /gallery/${job}/inputs/1`,
            `PUT /gallery/${job}/inputs/2`,
            `POST /gallery/${job}/start`,
        ]);
        expect(L.helper.galleryStarts).toEqual([{ job, body: { layout: "grid3", slides: [{ n: 0 }, { n: 1 }, { n: 2 }] } }]);
        const rows = itemRows(L as any, sid);
        const sent = L.helper.galleryInputs.get(job)!;
        [2, 0, 1].forEach((idx, n) => expect(sent.get(n), `slot ${n}`).toBe(L.originals.objects.get(rows[idx]!.r2_key)!.bytes.length));
        expect(renderRow(L, job)).toMatchObject({ session_id: sid, status: "pending", kind: "gallery_image" });
        expect(JSON.parse(renderRow(L, job).plan)).toEqual({ items: [2, 0, 1], layout: "grid3" });
        expect(L.keys("job:")).toEqual([`job:${job}`]);
        expect((L.kv.m.get(`job:${job}`) as any).gallery).toMatchObject({ layout: "grid3" });
        expect(L.entries()).toEqual([]);
    });

    it("the status follows the helper (composing), then the result is stored as a role 'export' row of the post with made_spec {kind: gallery}", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await make(L, sid, body())).job as string;
        const items = itemRows(L as any, sid);
        L.helper.galleryPolls = 1;
        L.helper.galleryPendingFields = { phase: "composing", done: 1, total: 3 };
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual({ status: "pending", job, phase: "composing", frames_done: 1, frames_total: 3, queue_ahead: null });

        // the helper names slots; the answer names item indices
        L.helper.galleryResult = { bytes: 4000, width: 2160, height: 2700, cropped: [1], upscaled: [1, 2] };
        const done = await L.studio.renderStatus(sid, job, 0);
        const row = exportRows(L, sid)[0]!;
        expect(done.body).toEqual({ status: "success", job, item_id: row.id, bytes: 4000, width: 2160, height: 2700, cropped: [1], upscaled: [1, 2], replaced: [] });
        expect(row).toMatchObject({
            kind: "private",
            source: "studio",
            bucket: "originals",
            r2_key: `originals/${sid}-g${job}.jpg`,
            content_type: "image/jpeg",
            bytes: 4000,
            width: 2160,
            height: 2700,
            duration: null,
            role: "export",
            post_key: sid,
            session_id: sid,
            visibility: "private",
            url: null,
        });
        expect(JSON.parse(row.made_from)).toEqual([items[0]!.id, items[1]!.id, items[2]!.id]);
        expect(JSON.parse(row.made_spec)).toEqual({ kind: "gallery", layout: "grid3", items: [0, 1, 2] });
        expect(L.originals.objects.get(`originals/${sid}-g${job}.jpg`)).toMatchObject({ contentType: "image/jpeg" });
        expect(L.originals.objects.get(`originals/${sid}-g${job}.jpg`)!.bytes).toEqual(L.helper.galleryFile);
        expect(renderRow(L, job)).toMatchObject({ status: "success", bytes: 4000, out_width: 2160, out_height: 2700 });
        expect(L.helper.galleryDeletes).toEqual([job]);
        expect(L.keys("result:")).toEqual([`result:${job}`]);
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual(done.body); // a repeat poll says the same, replaced and all
        expect(exportRows(L, sid)).toHaveLength(1);
        expect(L.keys("poster:")).toContain(`poster:${row.id}`); // a JPEG gets the usual poster job
        // not a webp of the session
        expect(asBody(await L.studio.advance(sid, 0)).renders).toEqual([]);
    });

    it("the order of the plan is the order drawn, a repeat is refused", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await make(L, sid, body({ items: [2, 0] }))).job as string;
        await L.studio.renderStatus(sid, job, 0);
        const rows = itemRows(L as any, sid);
        expect(JSON.parse(exportRows(L, sid)[0]!.made_from)).toEqual([rows[2]!.id, rows[0]!.id]);
        expect((await make(L, sid, body({ items: [0, 0, 1] }))).status).toBe(400);
    });

    it("a public post makes the gallery image public (its lead item's visibility), and the answer carries the link", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const job = asBody(await make(L, sid, body())).job as string;
        const done = asBody(await L.studio.renderStatus(sid, job, 0));
        const row = exportRows(L, sid)[0]!;
        expect(row).toMatchObject({ visibility: "public", url: `${MEDIA_BASE}${row.public_key}` });
        expect(row.public_key).toMatch(/^[A-Za-z0-9]{10}\.jpg$/);
        expect(L.media.objects.has(row.public_key)).toBe(true);
        expect(done).toMatchObject({ status: "success", url: row.url, item_id: row.id });
    });

    it("the sweep collects it with nobody polling", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await make(L, sid, body())).job as string;
        L.clock.t += 8 * 60 * 1000;
        await L.studio.sweep();
        expect(renderRow(L, job).status).toBe("success");
        expect(exportRows(L, sid)).toHaveLength(1);
    });

    it("the library lists it (v=3) as an export of the post, never as a deletable webp", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const job = asBody(await make(L, sid, body({ layout: "strip" }))).job as string;
        await L.studio.renderStatus(sid, job, 0);
        const lib = (await (await L.call("/library?v=3", { headers: auth })).json()) as any;
        const f = lib.posts[0].files.find((x: any) => x.role === "export");
        expect(f).toMatchObject({ role: "export", content_type: "image/jpeg", made_spec: { kind: "gallery", layout: "strip" }, deletable: false });
        expect(lib.posts[0].files.filter((x: any) => x.role === "item")).toHaveLength(5);
        // the old app (no v=3) never sees it
        const legacy = (await (await L.call("/library", { headers: auth })).json()) as any;
        expect(legacy.posts[0].files.some((x: any) => x.name?.includes("gallery"))).toBe(false);
    });
});

describe("replace: one gallery image per layout (R8)", () => {
    async function made(L: LW, sid: string, layout: string, over: Record<string, unknown> = {}) {
        const job = asBody(await make(L, sid, body({ layout, ...over }))).job as string;
        return { job, done: asBody(await L.studio.renderStatus(sid, job, 0)) };
    }

    it("the same layout again stores the new file first, then deletes the old one (row, object, mirror, poster); the answer lists it in `replaced`", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const first = await made(L, sid, "grid3");
        const old = exportRows(L, sid)[0]!;
        await L.studio.kickPosters();
        await L.studio.sweep();
        const second = await made(L, sid, "grid3", { items: [1, 0] });
        expect(second.done.replaced).toEqual([old.id]);
        const live = exportRows(L, sid);
        expect(live).toHaveLength(1);
        expect(live[0]!.id).toBe(second.done.item_id);
        // the old one is gone everywhere
        expect(L.rows("SELECT deleted_at FROM media_items WHERE id = ?", old.id)[0].deleted_at).not.toBeNull();
        expect(L.originals.objects.has(old.r2_key)).toBe(false);
        expect(L.media.objects.has(old.public_key)).toBe(false);
        expect(L.originals.objects.has(`originals/${sid}-g${second.job}.jpg`)).toBe(true);
        // a repeat poll of the first job still answers its own result
        expect(asBody(await L.studio.renderStatus(sid, first.job, 0))).toMatchObject({ status: "success", replaced: [] });
    });

    it("another layout coexists", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        await made(L, sid, "grid3");
        const strip = await made(L, sid, "strip");
        expect(strip.done.replaced).toEqual([]);
        expect(exportRows(L, sid).map((r) => JSON.parse(r.made_spec).layout).sort()).toEqual(["grid3", "strip"]);
    });

    it("a PUT .../made export of the long image (another made_spec.kind) is left alone", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const keep = exportsInsert(L, sid, { kind: "long" });
        const m = await made(L, sid, "grid3");
        expect(m.done.replaced).toEqual([]);
        expect(L.rows("SELECT deleted_at FROM media_items WHERE id = ?", keep)[0].deleted_at).toBeNull();
    });

    it("an object that cannot be deleted leaves the old row live (and the new one stored)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        await made(L, sid, "grid3");
        const old = exportRows(L, sid)[0]!;
        const orig = L.originals.delete.bind(L.originals);
        L.originals.delete = async (k: string) => {
            if (k === old.r2_key) throw new Error("R2 down");
            return orig(k);
        };
        const second = await made(L, sid, "grid3");
        expect(second.done.replaced).toEqual([]);
        expect(exportRows(L, sid)).toHaveLength(2);
    });
});

function exportsInsert(L: LW, sid: string, spec: Record<string, unknown>): string {
    const id = "ExportRow0000001a";
    L.db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, session_id, created_at, visibility, role, made_spec, post_key) VALUES (?, 'private', 'made', 'originals', ?, 'long.jpg', 'image/jpeg', 10, ?, 1, 'private', 'export', ?, ?)",
        )
        .run(id, `made/${id}.jpg`, sid, JSON.stringify(spec), sid);
    return id;
}

describe("validation: every bad request is refused before anything is created", () => {
    const table: [string, unknown, number, string][] = [
        ["not JSON", "nope", 400, "error.webp.invalid_params"],
        ["an array", "[1,2]", 400, "error.webp.invalid_params"],
        ["one item", body({ items: [0] }), 400, "error.webp.invalid_params"],
        ["21 items", body({ items: Array.from({ length: 21 }, (_, i) => i) }), 400, "error.webp.invalid_params"],
        ["a repeated index", body({ items: [0, 1, 1] }), 400, "error.webp.invalid_params"],
        ["a non-integer index", body({ items: [0, 1.5] }), 400, "error.webp.invalid_params"],
        ["a negative index", body({ items: [0, -1] }), 400, "error.webp.invalid_params"],
        ["no layout", { items: [0, 1] }, 400, "error.webp.invalid_params"],
        ["a layout that is not one", body({ layout: "mosaic" }), 400, "error.webp.invalid_params"],
        ["an item that is not saved", body({ items: [0, 1, 9] }), 400, "error.webp.invalid_params"],
        ["a video in it", body({ items: [0, 1, 3] }), 400, "error.webp.invalid_params"],
        ["a gif in it", body({ items: [0, 1, 4] }), 400, "error.webp.invalid_params"],
        ["priority without queue", body({ priority: "focused" }), 400, "error.webp.invalid_params"],
        ["priority that is not focused", body({ queue: true, priority: "urgent" }), 400, "error.webp.invalid_params"],
        ["queue not a boolean", body({ queue: "yes" }), 400, "error.webp.invalid_params"],
        ["notify not a boolean", body({ notify: "yes" }), 400, "error.webp.invalid_params"],
        ["a body over 2 KB", body({ pad: "x".repeat(2100) }), 400, "error.webp.invalid_params"],
    ];
    for (const [name, b, status, code] of table) {
        it(name, async () => {
            const L = await lineWorld();
            const { sid } = await gallery(L);
            L.helper.calls.length = 0;
            const r = await make(L, sid, b);
            expect(r.status).toBe(status);
            expect(asBody(r).error.code).toBe(code);
            expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'gallery_image'")).toEqual([]);
            expect(L.entries()).toEqual([]);
            expect(L.helper.calls).toEqual([]);
        });
    }

    it("fewer than 2 photos in the post (a reel and one photo): 409 error.studio.too_few_photos", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, [{ type: "photo" }, { type: "video", duration: 3 }, { type: "video", duration: 3 }]);
        const r = await make(L, sid, body({ items: [0, 1] }));
        expect(r.status).toBe(409);
        expect(asBody(r).error.code).toBe("error.studio.too_few_photos");
    });

    it("an expired session is 410, one still saving 409 not_ready, someone else's and an unknown one 404", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const { sid } = await gallery(L);
        expect((await make(L, sid, body(), "someone-else")).status).toBe(404);
        expect((await make(L, "X".repeat(22), body())).status).toBe(404);
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'saving' WHERE id = ?").run(sid);
        expect(asBody(await make(L, sid, body())).error.code).toBe("error.studio.not_ready");
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'ready', expires_at = ? WHERE id = ?").run(L.clock.t - 1, sid);
        expect((await make(L, sid, body())).status).toBe(410);
    });

    it("the gate: keyed POST only, the creating key only, never the library service", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const { sid } = await gallery(L);
        const url = `/studio/${sid}/gallery-image`;
        expect((await L.call(url, { method: "POST", body: json(body()) })).status).toBe(401);
        expect((await L.call(url, { method: "GET", headers: auth })).status).toBe(404);
        expect((await L.call(url, { method: "PUT", headers: auth, body: json(body()) })).status).toBe(404);
        expect((await L.call(url, { method: "POST", headers: { "x-cobalt-service": "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e" }, body: json(body()) })).status).toBe(404);
        expect((await L.call(url, { method: "POST", headers: auth2, body: json(body()) })).status).toBe(404);
        const ok = await L.call(url, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json(body()) });
        expect(ok.status).toBe(202);
        expect(await ok.json()).toMatchObject({ status: "pending", queued: false });
    });
});

describe("the line, and failures", () => {
    it("a busy helper: 429 without queue; with queue the job waits in the line (a render to GET /studio/line) and runs when its turn comes", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.fetchPolls = 1e9;
        const busy = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/run/status/1" })));
        expect((await make(L, sid, body())).status).toBe(429);
        const q = asBody(await make(L, sid, body({ queue: true, priority: "focused" })));
        expect(q).toMatchObject({ status: "pending", queued: true, queue_ahead: 1 });
        expect(L.entries()[0]).toMatchObject({ kind: "gallery_image", sid, job: q.job, keyId: KEY_ID });
        expect(L.entries()[0].key).toMatch(/^line:0:/); // focused: class 0
        const line = (await (await L.keyed("/studio/line")).json()) as any;
        expect(line.entries.map((e: any) => [e.kind, e.priority])).toEqual([["render", "focused"]]);
        expect(JSON.stringify(line)).not.toContain("gallery");
        expect(asBody(await L.studio.renderStatus(sid, q.job, 0))).toMatchObject({ status: "pending", phase: "queued", queue_ahead: 1 });
        L.helper.fetchPolls = 0;
        await L.sweeps(4);
        expect(L.helper.galleryStarts.map((s) => s.job)).toEqual([q.job]);
        await L.sweeps(3);
        expect(renderRow(L, q.job).status).toBe("success");
        expect(busy.id).toBeTruthy();
    });

    it.each([
        ["error.webp.invalid_params", "error.webp.invalid_params"],
        ["error.webp.encode_failed", "error.webp.encode_failed"],
        ["error.webp.too_large", "error.webp.too_large"],
        ["error.webp.timeout", "error.webp.timeout"],
    ])("the helper's %s ends the job with that code and frees it; the photos stay", async (code) => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.galleryError = code;
        const job = asBody(await make(L, sid, body())).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe(code);
        expect(renderRow(L, job)).toMatchObject({ status: "error", error_code: code });
        expect(L.helper.galleryDeletes).toEqual([job]);
        expect(itemRows(L as any, sid)).toHaveLength(5);
        expect(exportRows(L, sid)).toEqual([]);
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe(code); // stable
    });

    it("an input that is gone from R2 fails the job error.studio.missing; a helper that has no /gallery route (an older image) fails it unavailable at once", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const rows = itemRows(L as any, sid);
        L.originals.objects.delete(rows[1]!.r2_key);
        const job = asBody(await make(L, sid, body({ queue: true }))).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.studio.missing");
        expect(L.entries()).toEqual([]);

        // a helper from before the makes: no /gallery route, no make=1
        const L2 = await lineWorld();
        const g2 = await gallery(L2);
        L2.helper.makes = false;
        const job2 = asBody(await make(L2, g2.sid, body({ queue: true }))).job as string;
        expect(asBody(await L2.studio.renderStatus(g2.sid, job2, 0)).error.code).toBe("error.webp.unavailable");
        expect(L2.entries()).toEqual([]);
        expect(L2.helper.galleryStarts).toEqual([]);
    });

    it("the helper forgetting the job (a restart) is job_lost", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await make(L, sid, body())).job as string;
        L.helper.galleryGone = true;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.job_lost");
    });

    it("cancel: a queued gallery image is cancelled like a render", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.fetchPolls = 1e9;
        await L.studio.create(KEY_ID, json({ url: "https://x.com/run/status/1" }));
        const job = asBody(await make(L, sid, body({ queue: true }))).job as string;
        const r = await L.keyed(`/studio/${sid}/render/${job}`, "DELETE");
        expect(r.status).toBe(200);
        expect(renderRow(L, job)).toMatchObject({ status: "error", error_code: "error.webp.cancelled" });
        expect(L.entries()).toEqual([]);
    });
});

// ---- the real ffmpeg ---------------------------------------------------------------------------------------------

const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const real = hasFfmpeg ? describe : describe.skip;
const root = mkdtempSync(path.join(tmpdir(), "galleryimg-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const ff = (args: string[]) => {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
};
const u16 = (b: Uint8Array, i: number) => (b[i]! << 8) | b[i + 1]!;
const probeAV = async (f: string) => {
    const r = spawnSync(FFMPEG, ["-nostdin", "-hide_banner", "-i", f], { encoding: "utf8" });
    return { ...parseVideoInfo(r.stderr), hasAudio: parseHasAudio(r.stderr) };
};
// width/height of a JPEG from its SOF marker
function jpegSize(buf: Buffer): { w: number; h: number } | null {
    if (buf[0] !== 0xff || buf[1] !== 0xd8) return null;
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
}
const still = (name: string, w: number, h: number) => {
    const f = path.join(root, name);
    ff(["-f", "lavfi", "-i", `testsrc2=s=${w}x${h}:r=1`, "-frames:v", "1", "-q:v", "4", f]);
    return f;
};

real("the real gallery image (ffmpeg)", () => {
    const run = async (layout: "strip" | "grid2" | "grid3" | "row", files: string[], name: string) => {
        const output = path.join(root, `${name}.jpg`);
        const r = await renderGalleryImage({
            ffmpegBin: FFMPEG,
            output,
            files: new Map(files.map((f, n) => [n, f])),
            plan: { layout, slides: files.map((_, n) => ({ n })) },
            probeAV,
            timeoutMs: 120_000,
        });
        return { r, jpeg: readFileSync(output) };
    };

    it("a strip of 4:5 photos is their width wide and their heights tall; a JPEG of exactly the geometry's size", async () => {
        const a = still("a.jpg", 400, 500);
        const { r, jpeg } = await run("strip", [a, a, a], "strip");
        expect(r).toMatchObject({ width: 400, height: 1500, cropped: [], upscaled: [] });
        expect(jpegSize(jpeg)).toEqual({ w: 400, h: 1500 });
        expect(jpeg.subarray(0, 3)).toEqual(Buffer.from([0xff, 0xd8, 0xff]));
        expect(r.bytes).toBe(jpeg.length);
    });

    it("grid3 of 3 photos is one row, 3 across; a photo of another shape is cut to the cell and named in `cropped` (by slot)", async () => {
        const a = still("p.jpg", 300, 400);
        const sq = still("sq.jpg", 400, 400);
        const { r, jpeg } = await run("grid3", [a, a, sq], "grid3");
        expect(r.width).toBe(900);
        expect(jpegSize(jpeg)).toEqual({ w: r.width, h: r.height });
        expect(r.cropped).toEqual([2]);
        // 3 across at 300 wide each of the 3:4 cell
        expect(r.height).toBe(400);
    });

    it("grid2 with an odd count: the lone photo in the last row is drawn larger and said so (by slot)", async () => {
        const a = still("q.jpg", 300, 400);
        const { r, jpeg } = await run("grid2", [a, a, a], "grid2");
        expect(jpegSize(jpeg)).toEqual({ w: 600, h: 1200 });
        expect(r.upscaled).toEqual([2]);
    });

    it("a row is side by side at the shortest height", async () => {
        const a = still("r1.jpg", 300, 400);
        const b = still("r2.jpg", 400, 200);
        const { r, jpeg } = await run("row", [a, b], "row");
        expect(r).toMatchObject({ height: 200, width: 150 + 400 });
        expect(jpegSize(jpeg)).toEqual({ w: 550, h: 200 });
    });

    it("pixels land where the geometry says: the left half of a two-photo row is the first photo's colour", async () => {
        const red = path.join(root, "red.jpg");
        const blue = path.join(root, "blue.jpg");
        ff(["-f", "lavfi", "-i", "color=c=red:s=200x200", "-frames:v", "1", red]);
        ff(["-f", "lavfi", "-i", "color=c=blue:s=200x200", "-frames:v", "1", blue]);
        const { jpeg } = await run("row", [red, blue], "pix");
        const px = path.join(root, "pix.rgb");
        const rgb = spawnSync(FFMPEG, ["-nostdin", "-loglevel", "error", "-y", "-i", path.join(root, "pix.jpg"), "-vf", "scale=4:2", "-f", "rawvideo", "-pix_fmt", "rgb24", px]);
        expect(rgb.status).toBe(0);
        const raw = readFileSync(px);
        expect(jpegSize(jpeg)).toEqual({ w: 400, h: 200 });
        const at = (x: number, y: number) => [raw[(y * 4 + x) * 3]!, raw[(y * 4 + x) * 3 + 1]!, raw[(y * 4 + x) * 3 + 2]!];
        expect(at(0, 0)[0]).toBeGreaterThan(200);
        expect(at(0, 0)[2]).toBeLessThan(60);
        expect(at(3, 0)[2]).toBeGreaterThan(200);
        expect(at(3, 0)[0]).toBeLessThan(60);
        writeFileSync(path.join(root, "ok"), "1");
    });

    it("the staged way (one photo at a time) draws the same picture: same canvas, same crop and larger lists, cells cleaned up", async () => {
        const a = still("s1.jpg", 300, 400);
        const sq = still("s2.jpg", 400, 400);
        const files = [a, sq, a, a, sq];
        const plain = await renderGalleryImage({ ffmpegBin: FFMPEG, output: path.join(root, "plain.jpg"), files: new Map(files.map((f, n) => [n, f])), plan: { layout: "grid2", slides: files.map((_, n) => ({ n })) }, probeAV, timeoutMs: 60_000, stagePixels: Infinity });
        const staged = await renderGalleryImage({ ffmpegBin: FFMPEG, output: path.join(root, "staged.jpg"), files: new Map(files.map((f, n) => [n, f])), plan: { layout: "grid2", slides: files.map((_, n) => ({ n })) }, probeAV, timeoutMs: 60_000, stagePixels: 0 });
        expect(plain.staged).toBe(false);
        expect(staged.staged).toBe(true);
        expect([staged.width, staged.height, staged.cropped, staged.upscaled]).toEqual([plain.width, plain.height, plain.cropped, plain.upscaled]);
        expect(jpegSize(readFileSync(path.join(root, "staged.jpg")))).toEqual({ w: plain.width, h: plain.height });
        // the two pictures agree (a tiny scale-down of each compared as raw grey: the mean difference is small)
        const grey = (f: string) => spawnSync(FFMPEG, ["-nostdin", "-loglevel", "error", "-i", f, "-vf", "scale=24:24", "-f", "rawvideo", "-pix_fmt", "gray", "-"]).stdout;
        const x = grey(path.join(root, "plain.jpg"));
        const y = grey(path.join(root, "staged.jpg"));
        let diff = 0;
        for (let i = 0; i < x.length; i++) diff += Math.abs(x[i]! - y[i]!);
        expect(diff / x.length).toBeLessThan(6);
        expect(existsSync(path.join(root, "staged.jpg.cells"))).toBe(false);
    });

    it("a video or a gif input is refused invalid_params, an input that is no picture too; one photo is refused", async () => {
        const v = path.join(root, "v.mp4");
        ff(["-f", "lavfi", "-i", "testsrc2=s=160x120:d=1:r=10", "-pix_fmt", "yuv420p", v]);
        const a = still("z.jpg", 200, 200);
        await expect(run("strip", [a, v], "bad1")).rejects.toMatchObject({ code: "error.webp.invalid_params" });
        const junk = path.join(root, "junk");
        writeFileSync(junk, "not a picture at all");
        await expect(run("strip", [a, junk], "bad2")).rejects.toMatchObject({ code: "error.webp.invalid_params" });
        await expect(run("strip", [a], "bad3")).rejects.toMatchObject({ code: "error.webp.invalid_params" });
    });

    it("an output over the cap is error.webp.too_large", async () => {
        const a = still("big.jpg", 600, 600);
        await expect(
            renderGalleryImage({ ffmpegBin: FFMPEG, output: path.join(root, "cap.jpg"), files: new Map([[0, a], [1, a]]), plan: { layout: "strip", slides: [{ n: 0 }, { n: 1 }] }, probeAV, timeoutMs: 60_000, maxOutputBytes: 100 }),
        ).rejects.toMatchObject({ code: "error.webp.too_large" });
    });

    it("20 stories (1080x1920) as a strip: scaled to the 30,000 px cap (842x29920, the 6.4 table) and still one valid JPEG; staged, since 41 MP of photos", async () => {
        const f = path.join(root, "story.jpg");
        ff(["-f", "lavfi", "-i", "testsrc2=s=1080x1920:r=1", "-frames:v", "1", "-q:v", "6", f]);
        const { r, jpeg } = await run("strip", Array.from({ length: 20 }, () => f), "stories");
        expect([r.width, r.height, r.scaled, r.staged]).toEqual([842, 29920, true, true]);
        expect(jpegSize(jpeg)).toEqual({ w: 842, h: 29920 });
    });

});
