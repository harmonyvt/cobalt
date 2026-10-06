// Regression tests from the review of the makes lane (2026-10-06): each one failed before its fix.
//  R1 one Hark message when a chained make's save failed, whoever polls the make job (18.12)
//  R3 two makes of one kind collected at once never delete each other's new file (R8)
//  R4 `replaced` says the same however often a make is collected (a transient failure in between)
//  R6 a post turned private takes its slideshow webp with it (its mirror name looks like a webp's)
//  R7 a queued render of one item whose item was deleted ends error.studio.missing, not a storage fault
//  S3 the webp frame is never taller than the helper's 1920
//  and the poster runs the helper starts are killable like every other child
import { EventEmitter } from "node:events";
import { describe, expect, it } from "vitest";
import { makePoster } from "../helper/make.js";
import { slideshowFrame } from "../src/studio";
import { KEY_ID, asBody, auth, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { POST, itemRows, saveGallery } from "./gallery-world";
import { patchVisibility } from "./visibility-fixture";
import type { GalleryItemSpec } from "./studio-fakes";

const five = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo" }, { type: "photo" }, { type: "video", duration: 4 }, { type: "gif", duration: 2 }];
const create = (L: LW, body: Record<string, unknown>) =>
    L.studio.create(KEY_ID, json({ url: POST, items: "all", item_count: L.helper.gallery?.length ?? 5, public: true, origin: "share", queue: true, notify: { on: ["rendered", "failed"], label: "x · @someone" }, ...body }));
const webp = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2], seconds: [2, 2, 2], fade: true, frame: "keep", sound: "none", format: "webp", quality: "med", width: 480, ...over });
const exportRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'export' AND deleted_at IS NULL ORDER BY created_at, id", sid);
const slideRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'slideshow' AND deleted_at IS NULL ORDER BY created_at, id", sid);

describe("R1: the save failed, then the make job is polled", () => {
    it("one Hark message in all (the save's), however often the make job is polled", async () => {
        const L = await lineWorld();
        L.helper.gallery = Array.from({ length: 3 }, () => ({ type: "photo" as const, fail: "error.studio.fetch_failed" }));
        const r = asBody(await create(L, { slideshow: webp() }));
        await L.settle(r.id);
        await L.sweeps(3);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.title).toBe("cobalt couldn't finish");
        const poll = await L.studio.renderStatus(r.id, r.make.job, 0);
        expect(asBody(poll).error.code).toBe("error.studio.fetch_failed");
        await L.studio.renderStatus(r.id, r.make.job, 0);
        await L.sweeps(2);
        expect(L.hark.calls).toHaveLength(1);
    });

    it("a make that failed after a good save still says so (the suppression is only for a failed save)", async () => {
        const L = await lineWorld();
        L.helper.gallery = five();
        L.helper.galleryError = "error.webp.encode_failed";
        const r = asBody(await create(L, { gallery_image: { items: [0, 1, 2], layout: "grid3" } }));
        await L.settle(r.id);
        await L.sweeps(3);
        await L.studio.renderStatus(r.id, r.make.job, 0);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toContain("saved 5 items. the gallery image couldn't be made");
    });
});

describe("R3: two collects of the same kind at once", () => {
    it("one file survives, the one collected last, and it is stored; the other was replaced by it", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, five(), {});
        L.helper.galleryPolls = 1000;
        const a = asBody(await L.studio.galleryImage(KEY_ID, sid, json({ items: [0, 1, 2], layout: "grid3" }))).job as string;
        // A's job record ages out of held() (a make's window is 12 min) while the helper still holds A
        await L.clock.sleep(13 * 60_000);
        const rb = await L.studio.galleryImage(KEY_ID, sid, json({ items: [2, 1, 0], layout: "grid3", queue: true }));
        expect(rb.status).toBe(202);
        const b = asBody(rb).job as string;
        L.helper.galleryPolls = 0;
        const [ra, rb2] = await Promise.all([L.studio.renderStatus(sid, a, 0), L.studio.renderStatus(sid, b, 0)]);
        expect(asBody(ra).status).toBe("success");
        expect(asBody(rb2).status).toBe("success");
        const live = exportRows(L, sid);
        expect(live).toHaveLength(1);
        expect(L.originals.objects.has(live[0]!.r2_key)).toBe(true);
        // exactly one of the two answers says it replaced the other
        const other = [asBody(ra).item_id, asBody(rb2).item_id].find((id) => id !== live[0]!.id);
        const replacers = [asBody(ra), asBody(rb2)].filter((x) => x.replaced.length > 0);
        expect(replacers).toHaveLength(1);
        expect(replacers[0]!.replaced).toEqual([other]);
        expect(replacers[0]!.item_id).toBe(live[0]!.id);
    });
});

describe("R4: collected again after a transient failure", () => {
    it("`replaced` is the same on the retry, the new file is never deleted by its own retry", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, five(), { public: true });
        const first = asBody(await L.studio.galleryImage(KEY_ID, sid, json({ items: [0, 1, 2], layout: "grid3" }))).job as string;
        const firstDone = asBody(await L.studio.renderStatus(sid, first, 0));
        const j = asBody(await L.studio.galleryImage(KEY_ID, sid, json({ items: [0, 1, 2], layout: "grid3" }))).job as string;
        // the success write fails once: the collect has stored the file and replaced the old one, then throws
        const realPrepare = L.db.prepare.bind(L.db);
        let failed = false;
        (L.db as any).prepare = (sql: string) => {
            if (!failed && sql.startsWith("UPDATE studio_renders SET status = 'success'")) {
                failed = true;
                throw new Error("D1 hiccup");
            }
            return realPrepare(sql);
        };
        await L.studio.renderStatus(sid, j, 0).catch(() => null);
        expect(failed).toBe(true);
        const second = asBody(await L.studio.renderStatus(sid, j, 0));
        expect(second).toMatchObject({ status: "success", replaced: [firstDone.item_id] });
        const live = exportRows(L, sid);
        expect(live).toHaveLength(1);
        expect(live[0]!.id).toBe(second.item_id);
        expect(L.originals.objects.has(live[0]!.r2_key)).toBe(true);
        expect(asBody(await L.studio.renderStatus(sid, j, 0))).toEqual(second); // and stays so
    });
});

describe("R6: a public post turned private (scope post)", () => {
    it("takes the slideshow webp with it: row private, mirror gone, listed in the answer; the single-row answer is no webp rendition", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, five(), { public: true });
        const make = async (body: Record<string, unknown>) => asBody(await L.studio.renderStatus(sid, asBody(await L.studio.slideshow(KEY_ID, sid, json(body))).job, 0));
        await make({ items: [0, 1, 2], seconds: [2, 2, 2], fade: true, frame: "keep", format: "webp" });
        await make({ items: [0, 1, 2], seconds: [2, 2, 2], fade: true, frame: "keep" });
        const webpRow = slideRows(L, sid).find((x) => x.content_type === "image/webp")!;
        expect(webpRow.visibility).toBe("public");
        expect(L.media.objects.has(webpRow.public_key)).toBe(true);

        const lead = itemRows(L as any, sid)[0]!;
        const r = await patchVisibility(L as any, lead.id, { public: false, scope: "post" });
        expect(r.status).toBe(200);
        const after = slideRows(L, sid);
        expect(after.map((x) => x.visibility)).toEqual(["private", "private"]);
        expect(L.media.objects.has(webpRow.public_key)).toBe(false);
        expect(r.body.items.some((i: any) => i.role === "slideshow" && i.content_type === "image/webp" && i.visibility === "private")).toBe(true);
        expect(r.body.items.every((i: any) => i.visibility === "private")).toBe(true);

        // and back on
        const on = await patchVisibility(L as any, lead.id, { public: true, scope: "post" });
        expect(on.status).toBe(200);
        expect(slideRows(L, sid).map((x) => x.visibility)).toEqual(["public", "public"]);
        expect(L.media.objects.has(slideRows(L, sid).find((x) => x.content_type === "image/webp")!.public_key)).toBe(true);

        // the single-row answer for the webp reports it as the made file it is, not as a deletable webp rendition
        const one = await patchVisibility(L as any, webpRow.id, { public: false });
        expect(one.status).toBe(200);
        const shown = one.body.item ?? one.body;
        expect(shown).toMatchObject({ deletable: false, media_name: null });
    });
});

describe("R7: a queued render of one item whose item was deleted before its turn", () => {
    it("ends error.studio.missing (the source is gone), the line is free", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, [{ type: "video", duration: 4 }, { type: "video", duration: 5 }, { type: "photo" }], {});
        L.helper.slidePolls = 1000;
        const hold = asBody(await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1], seconds: [null, null], fade: false, frame: "keep" })));
        const r = await L.studio.render(sid, json({ item: 1, start: 0, length: 3, queue: true }));
        expect(r.status).toBe(202);
        expect(asBody(r).queued).toBe(true);
        const del = await L.call(`/library/items/${itemRows(L as any, sid)[1]!.id}`, { method: "DELETE", headers: auth });
        expect(del.status).toBe(200);
        L.helper.slidePolls = 0;
        await L.studio.renderStatus(sid, hold.job, 0);
        await L.sweeps(4);
        const st = await L.studio.renderStatus(sid, asBody(r).job, 0);
        expect(asBody(st).error.code).toBe("error.studio.missing");
        expect(L.entries()).toEqual([]);
    });
});

describe("S3: the webp frame", () => {
    const d = (w: number, h: number) => [{ width: w, height: h }];
    it("is never taller than 1920 (the helper refuses more), as the mp4's is not", () => {
        expect(slideshowFrame("keep", d(100, 1000), 480)).toEqual({ width: 480, height: 1920 });
        expect(slideshowFrame("keep", d(1080, 2400), 320)).toEqual({ width: 320, height: 712 });
        expect(slideshowFrame("9:16", d(1080, 1350), 480)).toEqual({ width: 480, height: 854 });
    });
    it("a very tall post is made, not refused by the helper", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, [{ type: "photo", width: 100, height: 1000 }, { type: "photo", width: 100, height: 1000 }], {});
        const r = await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1], seconds: [2, 2], format: "webp" }));
        expect(r.status).toBe(202);
        expect(L.helper.slideStarts[0]!.body).toMatchObject({ width: 480, height: 1920 });
    });
});

describe("the poster runs are registered like every other child", () => {
    it("makePoster hands its process to onChild (so the watchdog and DELETE can kill it)", async () => {
        const kids: unknown[] = [];
        const spawnImpl = ((_bin: string, _args: string[]) => {
            const c: any = new EventEmitter();
            c.stderr = new EventEmitter();
            c.kill = () => true;
            setImmediate(() => c.emit("close", 0));
            return c;
        }) as any;
        await makePoster({ ffmpegBin: "ffmpeg", input: "/in", output: "/nonexistent/out.jpg", timeoutMs: 1000, spawnImpl, onChild: (c) => kids.push(c) });
        expect(kids.length).toBeGreaterThanOrEqual(1);
        expect(kids[0]).toBeTruthy();
    });
});
