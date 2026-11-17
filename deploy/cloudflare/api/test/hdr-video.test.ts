// Video uploads record width/height/duration from the mp4 header. The keyed backfill does the same for rows
// that were stored before that; nothing here runs it on a schedule.
import { readFileSync } from "node:fs";
import path from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { KEY_ID, auth, world, type World } from "./poster-world";

const hevc = () => new Uint8Array(readFileSync(path.join(import.meta.dirname, "fixtures/hdr/hevc.mp4")));

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
});

describe("video dimensions", () => {
    it("fills width, height and duration on a video upload from the ISO-BMFF header", async () => {
        const data = hevc();
        const res = await w.call("/studio/upload?name=hdr.mp4", {
            method: "PUT",
            headers: { ...auth, "content-type": "video/mp4", "content-length": String(data.length) },
            body: data,
        });
        expect(res.status).toBe(201);
        const body = (await res.json()) as any;
        expect(body.item).toMatchObject({ content_type: "video/mp4", width: 64, height: 64, duration: 0.2, bytes: data.length });
        expect(w.item(body.item.id)).toMatchObject({ width: 64, height: 64, duration: 0.2 });
    });

    it("POST /library/videos/dimensions fills video rows that lack a size, and does not touch a row that has one", async () => {
        const data = hevc();
        w.originals.objects.set("uploads/OldVideo00000001.mp4", { bytes: data, contentType: "video/mp4", meta: {} });
        w.originals.objects.set("uploads/HasSize000000001.mp4", { bytes: data, contentType: "video/mp4", meta: {} });
        w.db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at, visibility)
                 VALUES ('OldVideo00000001','private','upload','originals','uploads/OldVideo00000001.mp4','a.mp4','video/mp4',?,?,1,'private'),
                        ('HasSize000000001','private','upload','originals','uploads/HasSize000000001.mp4','b.mp4','video/mp4',?,?,2,'private')`,
            )
            .run(data.length, KEY_ID, data.length, KEY_ID);
        w.db.raw.prepare("UPDATE media_items SET width = 10, height = 20, duration = 3 WHERE id = 'HasSize000000001'").run();
        const res = await w.call("/library/videos/dimensions", { method: "POST", headers: auth });
        expect(res.status).toBe(200);
        expect(await res.json()).toMatchObject({ status: "success", scanned: 1, updated: 1, offset: 0 });
        expect(w.item("OldVideo00000001")).toMatchObject({ width: 64, height: 64, duration: 0.2 });
        expect(w.item("HasSize000000001")).toMatchObject({ width: 10, height: 20, duration: 3 });
        expect((await w.call("/library/videos/dimensions", { method: "POST" })).status).toBe(401);
    });
});
