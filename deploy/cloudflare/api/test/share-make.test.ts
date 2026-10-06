// The share sheet's one request (APP-API-CONTRACT.md 18.12, lane S1): `slideshow.format` and `gallery_image` on POST /studio,
// chained after the save over the items that were saved, and the ONE Hark message of the story.
import { describe, expect, it } from "vitest";
import { KEY_ID, MEDIA_BASE, asBody, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { POST, itemRows } from "./gallery-world";
import type { GalleryItemSpec } from "./studio-fakes";

const LABEL = "x · @ilokineedsleep";
const five = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo" }, { type: "photo" }, { type: "video", duration: 4 }, { type: "gif", duration: 2 }];
const create = (L: LW, body: Record<string, unknown>) =>
    L.studio.create(KEY_ID, json({ url: POST, items: "all", item_count: L.helper.gallery?.length ?? 5, public: true, origin: "share", queue: true, notify: { on: ["rendered", "failed"], label: LABEL }, ...body }));
const slideshow = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2, 3, 4], seconds: [2, 2, 2, null, null], fade: true, frame: "keep", sound: "none", format: "webp", quality: "med", width: 480, ...over });
const gallery = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2], layout: "grid3", ...over });
const renderRow = (L: LW, job: string) => L.rows("SELECT * FROM studio_renders WHERE id = ?", job)[0];
async function run(L: LW, body: Record<string, unknown>) {
    const r = asBody(await create(L, body));
    expect(r.status).toBe("success");
    await L.settle(r.id);
    await L.sweeps(3);
    return r as { id: string; make: { job: string; kind: string } };
}

describe("a save with a slideshow webp: one request, one message", () => {
    it("201 {make: {job, kind}}; saved, then made over the items; the webp is the helper's frame; ONE message, with the post's name and the link", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        const r = await run(L, { slideshow: slideshow() });
        expect(r.make).toEqual({ job: expect.stringMatching(/^[A-Za-z0-9]{20}$/), kind: "slideshow" });
        expect(L.helper.slideStarts).toHaveLength(1);
        expect(L.helper.slideStarts[0]!.body).toMatchObject({ width: 480, height: 600, format: "webp", quality: "med", fps: 15 });
        expect(renderRow(L, r.make.job)).toMatchObject({ kind: "slideshow", status: "success" });
        const row = L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'slideshow'", r.id)[0];
        expect(row.content_type).toBe("image/webp");
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toEqual({
            title: "cobalt",
            body: `${LABEL} · slideshow webp ready · 480×600 · 3 KB\n${MEDIA_BASE}${row.public_key}`,
            url: `cobalt-apple://session/${r.id}`,
        });
        // a poll of the job again says nothing more
        await L.studio.renderStatus(r.id, r.make.job, 0);
        await L.sweeps(2);
        expect(L.hark.calls).toHaveLength(1);
    });

    it("a private post has no link: the message still goes, without the link line", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        await run(L, { public: false, slideshow: slideshow() });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · slideshow webp ready · 480×600 · 3 KB`);
    });

    it("the mp4 slideshow: `slideshow ready`", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        await run(L, { slideshow: slideshow({ format: undefined, quality: undefined, width: undefined }) });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toMatch(new RegExp(`^${LABEL} · slideshow ready · 1080×1350 · 5 KB`));
    });

    it("`saved` is not sent unless asked; asked, it is a second message", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        await run(L, { notify: { on: ["saved", "rendered", "failed"], label: LABEL }, slideshow: slideshow() });
        expect(L.hark.calls).toHaveLength(2);
        expect(L.hark.calls[0]!.body).toContain("is saved");
        expect(L.hark.calls[1]!.body).toContain("slideshow webp ready");
    });

    it("`failed` only: a success says nothing", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        await run(L, { notify: { on: ["failed"], label: LABEL }, slideshow: slideshow() });
        expect(L.hark.calls).toEqual([]);
    });
});

describe("a save with a gallery image", () => {
    it("saved, then made over the photos; ONE message: `<label> · gallery image ready · <w>×<h> · <size>`", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        const r = await run(L, { gallery_image: gallery() });
        expect(r.make.kind).toBe("gallery_image");
        expect(r).not.toHaveProperty("slideshow");
        expect(L.helper.galleryStarts[0]!.body).toEqual({ layout: "grid3", slides: [{ n: 0 }, { n: 1 }, { n: 2 }] });
        const row = L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'export'", r.id)[0];
        expect(row.content_type).toBe("image/jpeg");
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · gallery image ready · 2160×4500 · 4 KB\n${MEDIA_BASE}${row.public_key}`);
    });

    it("a photo that did not save is dropped from the plan; the image is made over the saved ones", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo" }, { type: "photo" }];
        const r = await run(L, { gallery_image: gallery({ items: [0, 1, 2, 3] }) });
        expect(L.helper.galleryStarts[0]!.body.slides).toHaveLength(3);
        const items = itemRows(L as any, r.id);
        expect(JSON.parse(L.rows("SELECT made_from FROM media_items WHERE role = 'export'")[0].made_from)).toEqual(items.map((x) => x.id));
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toContain("gallery image ready");
    });
});

describe("what goes wrong, in one message", () => {
    it("the save fails: the save's failure message (and no second one); the make ends with the save's code", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }];
        const r = await run(L, { slideshow: slideshow({ items: [0, 1, 2], seconds: [2, 2, 2] }) });
        expect(renderRow(L, r.make.job)).toMatchObject({ status: "error", error_code: "error.studio.fetch_failed" });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toMatchObject({ title: "cobalt couldn't finish" });
        expect(L.hark.calls[0]!.body).toContain(`couldn't save ${LABEL}`);
    });

    it("the save works and a webp would run over 60 s: `saved <n> items. the slideshow webp would be <m:ss> and webps stop at 60 s. open cobalt to make the mp4.`", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "video", duration: 70 }];
        const r = await run(L, { item_count: 2, slideshow: slideshow({ items: [0, 1], seconds: [2, null] }) });
        expect(renderRow(L, r.make.job)).toMatchObject({ status: "error", error_code: "error.webp.too_long" });
        expect(itemRows(L as any, r.id)).toHaveLength(2); // the save stays
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · saved 2 items. the slideshow webp would be 1:12 and webps stop at 60 s. open cobalt to make the mp4.`);
    });

    it("the save works and the helper cannot make it: `saved <n> items. the <what> couldn't be made — <reason>`", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        L.helper.galleryError = "error.webp.encode_failed";
        await run(L, { gallery_image: gallery() });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toMatchObject({ title: "cobalt" });
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · saved 5 items. the gallery image couldn't be made — something went wrong on the server`);
    });

    it("fewer than 2 photos saved: the gallery image ends too_few_photos, the save stays", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "video", duration: 3 }];
        const r = await run(L, { item_count: 3, gallery_image: gallery({ items: [0, 1] }) });
        expect(renderRow(L, r.make.job)).toMatchObject({ status: "error", error_code: "error.studio.too_few_photos" });
        expect(itemRows(L as any, r.id)).toHaveLength(2);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · saved 2 items. the gallery image couldn't be made — there are fewer than 2 photos to use`);
    });

    it("fewer than 2 items saved for a slideshow: not_gallery", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }];
        const r = await run(L, { slideshow: slideshow({ items: [0, 1, 2], seconds: [2, 2, 2] }) });
        expect(renderRow(L, r.make.job)).toMatchObject({ status: "error", error_code: "error.studio.not_gallery" });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toBe(`${LABEL} · saved 1 item. the slideshow webp couldn't be made — there are fewer than 2 items to use`);
    });

    it("a seconds mix that does not match the items (a number for a video) ends invalid_params once the types are known", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        const r = await run(L, { slideshow: slideshow({ seconds: [2, 2, 2, 5, null] }) });
        expect(renderRow(L, r.make.job)).toMatchObject({ status: "error", error_code: "error.webp.invalid_params" });
        expect(L.helper.slideStarts).toEqual([]);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toContain("saved 5 items. the slideshow webp couldn't be made");
    });
});

describe("what is refused before anything is created", () => {
    const refused: [string, Record<string, unknown>][] = [
        ["both a slideshow and a gallery image", { slideshow: slideshow(), gallery_image: gallery() }],
        ["a slideshow with no items", { items: undefined, slideshow: slideshow() }],
        ["a gallery image with no items", { items: undefined, gallery_image: gallery() }],
        ["a gallery image with an index outside items", { items: [0, 1], item_count: 5, gallery_image: gallery() }],
        ["a gallery image with a layout that is not one", { gallery_image: gallery({ layout: "mosaic" }) }],
        ["a gallery image with one photo", { gallery_image: gallery({ items: [0] }) }],
        ["a gallery image with a repeat", { gallery_image: gallery({ items: [0, 0, 1] }) }],
        ["a slideshow webp with quality ultra", { slideshow: slideshow({ quality: "ultra" }) }],
        ["a slideshow webp with sound own", { slideshow: slideshow({ sound: "own" }) }],
        ["a slideshow mp4 with a quality", { slideshow: slideshow({ format: "mp4" }) }],
        ["a slideshow webp over 60 s of photos", { slideshow: slideshow({ items: [0, 1, 2], seconds: [15, 15, 15.5] }) }],
        ["a slideshow with 0.4 s", { slideshow: slideshow({ seconds: [0.4, 2, 2, null, null] }) }],
    ];
    for (const [name, body] of refused) {
        it(name, async () => {
            const L = await lineWorld();
            L.helper.gallery = five();
            const r = await create(L, body);
            expect(r.status).toBe(400);
            expect(L.rows("SELECT * FROM studio_sessions")).toEqual([]);
            expect(L.rows("SELECT * FROM studio_renders")).toEqual([]);
            expect(L.entries()).toEqual([]);
        });
    }

    it("a webp over 60 s of photos says too_long, a photo over 15 s the shape's invalid_params", async () => {
        const L = await lineWorld();
        L.helper.gallery = Array.from({ length: 5 }, () => ({ type: "photo" as const }));
        const over = await create(L, { slideshow: slideshow({ items: [0, 1, 2, 3, 4], seconds: [13, 13, 13, 13, 13] }) });
        expect(over.status).toBe(400);
        expect(asBody(over).error.code).toBe("error.webp.too_long");
        const shape = await create(L, { slideshow: slideshow({ items: [0, 1, 2, 3, 4], seconds: [16, 2, 2, 2, 2] }) });
        expect(asBody(shape).error.code).toBe("error.studio.invalid_params");
        const ok = await create(L, { slideshow: slideshow({ items: [0, 1, 2, 3, 4], seconds: [12, 12, 12, 12, 12] }) });
        expect(ok.status).toBe(201);
    });
});
