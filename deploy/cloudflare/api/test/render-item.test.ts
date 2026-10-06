// `item` on POST /studio/<sid>/render (APP-API-CONTRACT.md 18.13, lane S1): a webp of the second video of a gallery reads
// THAT item (its bytes, its length, its size), not the session's lead; a photo is 409 not_video; the rest of the table.
import { describe, expect, it } from "vitest";
import { KEY_ID, asBody, auth, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { itemRows, saveGallery } from "./gallery-world";
import type { GalleryItemSpec } from "./studio-fakes";

// photo, video (the lead: the first video), gif, video of another length and size
const specs = (): GalleryItemSpec[] => [
    { type: "photo" },
    { type: "video", duration: 4, width: 640, height: 360 },
    { type: "gif", duration: 2, width: 200, height: 200 },
    { type: "video", duration: 9, width: 480, height: 560 },
];
const render = (L: LW, sid: string, body: Record<string, unknown>) => L.studio.render(sid, json({ start: 0, length: 2, ...body }));
async function gallery(L: LW, s = specs(), b: Record<string, unknown> = {}) {
    const g = await saveGallery(L as any, s, b);
    expect(g.done.status).toBe("ready");
    return g;
}
const bytesOf = (L: LW, sid: string, index: number) => L.originals.objects.get(itemRows(L as any, sid)[index]!.r2_key)!.bytes.length;
const webpRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND source = 'studio' AND content_type = 'image/webp' AND deleted_at IS NULL", sid);

describe("a render of one item", () => {
    it("reads that item's bytes from R2, not the lead's: the second video is what is uploaded into the helper", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect(bytesOf(L, sid, 3)).not.toBe(bytesOf(L, sid, 1));
        const r = await render(L, sid, { item: 3 });
        expect(r.status).toBe(202);
        expect(L.helper.uploadedBytes).toEqual([bytesOf(L, sid, 3)]);
        await L.studio.renderStatus(sid, asBody(r).job, 0); // the helper is free again
        // no item = the lead (today)
        await render(L, sid, { start: 1 });
        expect(L.helper.uploadedBytes).toEqual([bytesOf(L, sid, 3), bytesOf(L, sid, 1)]);
    });

    it("a gif item is a source too", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect((await render(L, sid, { item: 2, length: 1 })).status).toBe(202);
        expect(L.helper.uploadedBytes).toEqual([bytesOf(L, sid, 2)]);
    });

    it("the clip is judged against that item's length (9 s), not the lead's (4 s)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect((await render(L, sid, { item: 3, start: 6, length: 3 })).status).toBe(202); // 6 + 3 = 9
        const past = await render(L, sid, { item: 3, start: 6.5, length: 3 });
        expect(past.status).toBe(400);
        expect(asBody(past).error.code).toBe("error.webp.invalid_params");
        // the same clip on the lead (4 s) is too long for it
        expect((await render(L, sid, { start: 6, length: 3 })).status).toBe(400);
    });

    it("the webp is listed with made_from = that item's id (v=3); a render with no item has none", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const items = itemRows(L as any, sid);
        const job = asBody(await render(L, sid, { item: 3 })).job as string;
        expect(JSON.parse(L.rows("SELECT plan FROM studio_renders WHERE id = ?", job)[0].plan)).toEqual({ item: 3, item_id: items[3]!.id });
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).status).toBe("success");
        const row = webpRows(L, sid)[0]!;
        expect(JSON.parse(row.made_from)).toEqual([items[3]!.id]);
        expect(row.bucket).toBe("media"); // stored as today, in the public bucket

        const plain = asBody(await render(L, sid, {})).job as string;
        await L.studio.renderStatus(sid, plain, 0);
        const rows = webpRows(L, sid);
        expect(rows).toHaveLength(2);
        expect(rows.find((r) => r.id !== row.id)!.made_from).toBeNull();

        const lib = (await (await L.call("/library?v=3", { headers: auth })).json()) as any;
        const webps = lib.posts[0].files.filter((f: any) => f.content_type === "image/webp");
        expect(webps.map((f: any) => f.made_from).sort()).toEqual([[], [items[3]!.id]]);
        // and it is still a plain webp: deletable by name, not a role
        expect(webps.every((f: any) => f.role === null && f.deletable === true)).toBe(true);
    });

    it("the GET /studio/<sid> answer lists both webps; an item render does not touch the session's lead", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const lead = L.rows("SELECT r2_key FROM studio_sessions WHERE id = ?", sid)[0].r2_key;
        const job = asBody(await render(L, sid, { item: 3 })).job as string;
        await L.studio.renderStatus(sid, job, 0);
        expect(L.rows("SELECT r2_key FROM studio_sessions WHERE id = ?", sid)[0].r2_key).toBe(lead);
        expect(asBody(await L.studio.advance(sid, 0)).renders).toHaveLength(1);
    });
});

describe("the item's own errors", () => {
    it("a photo item: 409 error.studio.not_video, nothing started", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const r = await render(L, sid, { item: 0 });
        expect(r.status).toBe(409);
        expect(asBody(r).error.code).toBe("error.studio.not_video");
        expect(L.helper.uploadedBytes).toEqual([]);
        expect(L.rows("SELECT * FROM studio_renders")).toEqual([]);
    });

    it("an unknown index, and a deleted item: 404 error.studio.not_found", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect((await render(L, sid, { item: 9 })).status).toBe(404);
        const rows = itemRows(L as any, sid);
        L.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(rows[3]!.id);
        const gone = await render(L, sid, { item: 3 });
        expect(gone.status).toBe(404);
        expect(asBody(gone).error.code).toBe("error.studio.not_found");
    });

    it("on a session with no items (a single video): 400 error.webp.invalid_params", async () => {
        const L = await lineWorld();
        const sid = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await L.settle(sid);
        const r = await render(L, sid, { item: 0 });
        expect(r.status).toBe(400);
        expect(asBody(r).error.code).toBe("error.webp.invalid_params");
        expect((await render(L, sid, {})).status).toBe(202); // no item: as today
    });

    it.each([["a string", "1"], ["negative", -1], ["a fraction", 1.5], ["too big", 99], ["an object", {}]])("item %s: 400", async (_n, item) => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const r = await render(L, sid, { item });
        expect(r.status).toBe(400);
        expect(L.rows("SELECT * FROM studio_renders")).toEqual([]);
    });

    it("null is the same as absent", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect((await render(L, sid, { item: null })).status).toBe(202);
        expect(L.helper.uploadedBytes).toEqual([bytesOf(L, sid, 1)]);
    });
});

describe("a render of one item in the line", () => {
    it("waits like any render and, when its turn comes, uploads THAT item (the entry carries it)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.fetchPolls = 1e9;
        await L.studio.create(KEY_ID, json({ url: "https://x.com/run/status/1" }));
        L.helper.uploadedBytes.length = 0;
        const q = asBody(await render(L, sid, { item: 3, queue: true }));
        expect(q).toMatchObject({ status: "pending", queued: true });
        expect(L.entries()[0].render).toMatchObject({ itemId: itemRows(L as any, sid)[3]!.id, r2Key: itemRows(L as any, sid)[3]!.r2_key });
        L.helper.fetchPolls = 0;
        await L.sweeps(4);
        expect(L.helper.uploadedBytes).toEqual([bytesOf(L, sid, 3)]);
        await L.sweeps(3);
        expect(asBody(await L.studio.renderStatus(sid, q.job, 0)).status).toBe("success");
        expect(JSON.parse(webpRows(L, sid)[0]!.made_from)).toEqual([itemRows(L as any, sid)[3]!.id]);
    });
});
