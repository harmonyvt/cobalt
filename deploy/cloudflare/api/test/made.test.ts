// PUT /library/items/<id>/made (APP-API-CONTRACT.md section 18.6, lane GS2): a crop or an export (the long image,
// the PDF) made on the device and stored as a new file of the post. The Worker streams the body to R2; everything
// that can refuse does so before it is read.
import { beforeEach, describe, expect, it } from "vitest";
import { jpegSize } from "../src/app-routes";
import { KEY_ID, MEDIA_BASE, POSTER_URL, asBody, auth, json, svc, world, type World } from "./poster-world";
import { POST, itemRows, photos, saveGallery } from "./gallery-world";
import { listAll } from "./visibility-fixture";

// A JPEG with a real start-of-frame, so the server can read its size: SOI, APP0, SOF0 (h, w), padding, EOI.
export function jpeg(width: number, height: number, padding = 64): Uint8Array {
    const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
    const app0 = [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00];
    return Uint8Array.from([0xff, 0xd8, ...app0, ...sof, ...new Array(padding).fill(7), 0xff, 0xd9]);
}
const pdf = (n = 200) => Uint8Array.from([...new TextEncoder().encode("%PDF-1.4\n"), ...new Array(n).fill(0x20), ...new TextEncoder().encode("\n%%EOF")]);
const spec = (o: Record<string, unknown> = { aspect: "9:16", fill: "blur", rect: [0, 0.1, 1, 0.8] }) => encodeURIComponent(JSON.stringify(o));

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
});

type Put = { role?: string; name?: string; spec?: string; type?: string; body?: Uint8Array; headers?: Record<string, string | null> };
const put = (id: string, o: Put = {}) => {
    const body = o.body ?? jpeg(1080, 1920);
    const q = new URLSearchParams();
    if (o.role !== undefined) q.set("role", o.role);
    if (o.name !== undefined) q.set("name", o.name);
    if (o.spec !== undefined) q.set("spec", decodeURIComponent(o.spec));
    const headers: Record<string, string> = { ...auth, "content-type": o.type ?? "image/jpeg", "content-length": String(body.length) };
    for (const [k, v] of Object.entries(o.headers ?? {})) {
        if (v === null) delete headers[k];
        else headers[k] = v;
    }
    return w.call(`/library/items/${id}/made?${q}`, { method: "PUT", headers, body });
};
const crop = (id: string, o: Put = {}) => put(id, { role: "crop", name: "crop 9:16.jpg", spec: spec(), ...o });
const madeRows = (sid: string) => w.db.raw.prepare("SELECT * FROM media_items WHERE session_id = ? AND source = 'made' ORDER BY created_at, id").all(sid) as any[];

describe("a crop", () => {
    it("201: a row of the post (source made, role crop, made_from the photo, post_key, the JPEG's size), the body streamed to R2, a poster queued", async () => {
        const { sid } = await saveGallery(w, photos(3));
        const photo = itemRows(w, sid)[2]!;
        const body = jpeg(1080, 1920, 5000);
        const putsBefore = w.originals.putValueTypes.length;
        const res = await crop(photo.id, { body, name: "crop 9:16.jpg" });
        expect(res.status).toBe(201);
        const out = (await res.json()) as any;
        const row = madeRows(sid)[0]!;
        expect(row).toMatchObject({
            id: out.item.id,
            kind: "private",
            source: "made",
            bucket: "originals",
            r2_key: `made/${out.item.id}.jpg`,
            name: "crop 9:16.jpg",
            content_type: "image/jpeg",
            bytes: body.length,
            width: 1080,
            height: 1920,
            duration: null,
            role: "crop",
            post_key: sid,
            session_id: sid,
            link: POST,
            key_id: KEY_ID,
            visibility: "private",
            url: null,
        });
        expect(JSON.parse(row.made_from)).toEqual([photo.id]);
        expect(JSON.parse(row.made_spec)).toEqual({ aspect: "9:16", fill: "blur", rect: [0, 0.1, 1, 0.8] });
        // streamed (never buffered by the Worker), stored under the made/ prefix with its type
        expect(w.originals.putValueTypes.slice(putsBefore)).toEqual(["ReadableStream"]);
        expect(w.originals.objects.get(row.r2_key)).toMatchObject({ contentType: "image/jpeg" });
        expect(w.originals.objects.get(row.r2_key)!.bytes).toEqual(body);
        // the answer is the v3 file, no replacement
        expect(out).toMatchObject({ status: "success", replaced: [], item: { role: "crop", item_index: null, made_from: [photo.id], made_spec: { aspect: "9:16" }, content_type: "image/jpeg", visibility: "private", width: 1080, height: 1920 } });
        // its poster is queued (the sweep makes it); a made file is a post's file of that post
        expect([...w.kv.m.keys()]).toContain(`poster:${row.id}`);
        const l = await listAll(w, "v=3");
        expect(l.posts).toHaveLength(1);
        expect(l.posts[0].files.map((f: any) => f.role)).toEqual(["item", "item", "item", "crop"]);
    });

    it("crops accumulate, and each is deletable alone", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        const a = ((await (await crop(photo.id)).json()) as any).item.id;
        const b = ((await (await crop(photo.id, { spec: spec({ aspect: "1:1" }) })).json()) as any).item.id;
        expect(a).not.toBe(b);
        expect(madeRows(sid)).toHaveLength(2);
        const del = await w.call(`/library/items/${a}`, { method: "DELETE", headers: auth });
        expect(del.status).toBe(200);
        expect(madeRows(sid).filter((r) => r.deleted_at === null).map((r) => r.id)).toEqual([b]);
    });

    it("a single photo (no role) can be cropped; a crop of an image upload with no session joins that upload's post", async () => {
        w.helper.fetchDone = { contentType: "image/jpeg", ext: "jpg", duration: null, width: 800, height: 600 };
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await w.settle(sid);
        const single = w.items()[0]!;
        expect(single.role).toBeNull();
        const r1 = await crop(single.id);
        expect(r1.status).toBe(201);
        expect(madeRows(sid)[0]).toMatchObject({ post_key: sid, session_id: sid, role: "crop" });
        // an uploaded image: its post key is its own id
        w.originals.objects.set("uploads/UploadedPhoto001.jpg", { bytes: jpeg(10, 10), contentType: "image/jpeg", meta: {} });
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at, visibility) VALUES ('UploadedPhoto001','private','upload','originals','uploads/UploadedPhoto001.jpg','p.jpg','image/jpeg',5,?,1000,'private')")
            .run(KEY_ID);
        const r2 = await crop("UploadedPhoto001");
        expect(r2.status).toBe(201);
        const made = ((await r2.json()) as any).item;
        expect(w.item(made.id)).toMatchObject({ post_key: "UploadedPhoto001", session_id: null, link: null });
        const l = await listAll(w, "v=3");
        const up = l.posts.find((p) => p.id === "UploadedPhoto001");
        expect(up.files.map((f: any) => f.id).sort()).toEqual([made.id, "UploadedPhoto001"].sort());
        expect(up.kind).toBe("photo");
    });

    it("a public post makes the crop public too, with the answer carrying its link", async () => {
        const { sid } = await saveGallery(w, photos(2), { public: true });
        const photo = itemRows(w, sid)[1]!;
        const out = (await (await crop(photo.id)).json()) as any;
        expect(out.item.visibility).toBe("public");
        expect(out.item.url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.jpg$/);
        const row = w.item(out.item.id);
        expect(row).toMatchObject({ visibility: "public", url: out.item.url });
        expect(w.media.objects.has(row.public_key)).toBe(true);
        expect(w.media.objects.get(row.public_key)!.data).toEqual(w.originals.objects.get(row.r2_key)!.bytes);
    });

    it("the anchor must be a photo: a video, a gif, a webp and a made file are 409 not_photo", async () => {
        const { sid } = await saveGallery(w, [{ type: "photo" }, { type: "video" }, { type: "gif" }]);
        const rows = itemRows(w, sid);
        const before = w.originals.objects.size;
        for (const r of [rows[1]!, rows[2]!]) {
            const res = await crop(r.id);
            expect(res.status, r.content_type).toBe(409);
            expect(((await res.json()) as any).error.code).toBe("error.library.not_photo");
        }
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, session_id, key_id, created_at, visibility) VALUES ('WebpRowCropTest01','public','studio','media','Abcdefghij.webp','https://m/x','a.webp','image/webp',5,?,?,1,'public')")
            .run(sid, KEY_ID);
        expect((await crop("WebpRowCropTest01")).status).toBe(404); // not a 16-character id
        w.db.raw.prepare("UPDATE media_items SET id = 'WebpRowCropTest1' WHERE id = 'WebpRowCropTest01'").run();
        expect((await crop("WebpRowCropTest1")).status).toBe(409);
        const first = ((await (await crop(rows[0]!.id)).json()) as any).item.id;
        expect((await crop(first)).status).toBe(409); // a crop of a crop is not a photo of the post
        expect(w.originals.objects.size).toBe(before + 1); // only the one that worked stored anything
    });

    it("a crop keeps working when the photo it was made from is deleted", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const rows = itemRows(w, sid);
        const c = ((await (await crop(rows[0]!.id)).json()) as any).item.id;
        expect((await w.call(`/library/items/${rows[0]!.id}`, { method: "DELETE", headers: auth })).status).toBe(200);
        const l = await listAll(w, "v=3");
        expect(l.files.find((f) => f.id === c)).toMatchObject({ role: "crop", made_from: [rows[0]!.id] });
        expect(w.originals.objects.has(w.item(c).r2_key)).toBe(true);
    });
});

describe("an export", () => {
    it("the long image: a JPEG of the post, made_from = the ids of its photos now (a video is left out), the kind in the spec", async () => {
        const { sid } = await saveGallery(w, [{ type: "photo" }, { type: "video" }, { type: "photo" }, { type: "photo" }]);
        const rows = itemRows(w, sid);
        const res = await put(rows[0]!.id, { role: "export", name: "long image.jpg", spec: spec({ kind: "long", layout: "one" }), body: jpeg(1080, 13500) });
        expect(res.status).toBe(201);
        const out = (await res.json()) as any;
        expect(out).toMatchObject({ status: "success", replaced: [], item: { role: "export", made_spec: { kind: "long", layout: "one" }, width: 1080, height: 13500 } });
        expect(out.item.made_from).toEqual([rows[0]!.id, rows[2]!.id, rows[3]!.id]);
        const row = w.item(out.item.id);
        expect(row).toMatchObject({ source: "made", role: "export", r2_key: `made/${row.id}.jpg`, content_type: "image/jpeg", post_key: sid, name: "long image.jpg" });
        // a long image is a picture: it gets a poster; the anchor may be any file of the post (here a photo)
        expect([...w.kv.m.keys()]).toContain(`poster:${row.id}`);
    });

    it("the PDF: application/pdf, no size, no poster, the .pdf key", async () => {
        const { sid } = await saveGallery(w, photos(3));
        const photo = itemRows(w, sid)[0]!;
        const body = pdf();
        const res = await put(photo.id, { role: "export", name: "ig_Ddy0.pdf", type: "application/pdf", spec: spec({ kind: "pdf", layout: "six" }), body });
        expect(res.status).toBe(201);
        const out = ((await res.json()) as any).item;
        const row = w.item(out.id);
        expect(row).toMatchObject({ r2_key: `made/${row.id}.pdf`, content_type: "application/pdf", width: null, height: null, bytes: body.length, role: "export" });
        expect(w.originals.objects.get(row.r2_key)).toMatchObject({ contentType: "application/pdf" });
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("poster:")).every((k) => k !== `poster:${row.id}`)).toBe(true);
    });

    it("one of each kind per post: making the long image again replaces the first (deleted after the new one is stored); the PDF beside it stays; crops stay", async () => {
        const { sid } = await saveGallery(w, photos(2), { public: true });
        const photo = itemRows(w, sid)[0]!;
        const exportOf = (kind: string, type: string, body: Uint8Array) => put(photo.id, { role: "export", spec: spec({ kind }), type, body });
        const long1 = ((await (await exportOf("long", "image/jpeg", jpeg(10, 20))).json()) as any).item;
        const pdf1 = ((await (await exportOf("pdf", "application/pdf", pdf())).json()) as any).item;
        const crop1 = ((await (await crop(photo.id)).json()) as any).item;
        const k1 = w.item(long1.id);
        expect(w.media.objects.has(k1.public_key)).toBe(true);
        const again = await exportOf("long", "image/jpeg", jpeg(10, 30));
        expect(again.status).toBe(201);
        const out = (await again.json()) as any;
        expect(out.replaced).toEqual([long1.id]);
        // the first is gone: object, mirror, row
        expect(w.item(long1.id).deleted_at).not.toBeNull();
        expect(w.originals.objects.has(k1.r2_key)).toBe(false);
        expect(w.media.objects.has(k1.public_key)).toBe(false);
        // the new one, the PDF and the crop are live
        const live = madeRows(sid).filter((r) => r.deleted_at === null).map((r) => r.id).sort();
        expect(live).toEqual([out.item.id, pdf1.id, crop1.id].sort());
        // and a second PDF replaces only the PDF
        const pdf2 = ((await (await exportOf("pdf", "application/pdf", pdf(300))).json()) as any);
        expect(pdf2.replaced).toEqual([pdf1.id]);
    });

    it("an export may be anchored on any live file of the post, a made one included; an unknown or deleted anchor is 404", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const rows = itemRows(w, sid);
        const c = ((await (await crop(rows[0]!.id)).json()) as any).item.id;
        expect((await put(c, { role: "export", spec: spec({ kind: "long" }) })).status).toBe(201);
        expect((await put("NoSuchItem000001", { role: "export", spec: spec({ kind: "long" }) })).status).toBe(404);
        await w.call(`/library/items/${rows[1]!.id}`, { method: "DELETE", headers: auth });
        expect((await put(rows[1]!.id, { role: "export", spec: spec({ kind: "long" }) })).status).toBe(404);
    });
});

describe("refused before the body is read (nothing stored, nothing written)", () => {
    const table: [string, Put, number, string][] = [
        ["no role", { role: undefined as any, spec: spec() }, 400, "error.library.bad_request"],
        ["a role that is not one", { role: "avatar" }, 400, "error.library.bad_request"],
        ["no spec", { spec: undefined }, 400, "error.library.bad_request"],
        ["a spec that is not JSON", { spec: "nope" }, 400, "error.library.bad_request"],
        ["a spec that is not an object (array)", { spec: spec([1] as any) }, 400, "error.library.bad_request"],
        ["a spec that is not an object (string)", { spec: spec("x" as any) }, 400, "error.library.bad_request"],
        ["a spec over 512 bytes", { spec: spec({ pad: "x".repeat(520) }) }, 400, "error.library.bad_request"],
        ["a crop that is not a JPEG", { type: "image/png" }, 400, "error.library.bad_request"],
        ["a crop sent as a PDF", { type: "application/pdf" }, 400, "error.library.bad_request"],
        ["no content type", { headers: { "content-type": null } }, 400, "error.library.bad_request"],
        ["an export without a kind", { role: "export", spec: spec({}) }, 400, "error.library.bad_request"],
        ["an export with another kind", { role: "export", spec: spec({ kind: "zip" }) }, 400, "error.library.bad_request"],
        ["a long image as a PDF", { role: "export", spec: spec({ kind: "long" }), type: "application/pdf" }, 400, "error.library.bad_request"],
        ["a pdf as a JPEG", { role: "export", spec: spec({ kind: "pdf" }), type: "image/jpeg" }, 400, "error.library.bad_request"],
        ["no content-length", { headers: { "content-length": null } }, 400, "error.library.bad_request"],
        ["a content-length that is not a number", { headers: { "content-length": "ten" } }, 400, "error.library.bad_request"],
        ["a content-length of 0", { headers: { "content-length": "0" } }, 400, "error.library.bad_request"],
        ["over 50 MB", { headers: { "content-length": String(50 * 1024 * 1024 + 1) } }, 413, "error.studio.too_large"],
    ];
    for (const [name, o, status, code] of table) {
        it(name, async () => {
            const { sid } = await saveGallery(w, photos(2));
            const photo = itemRows(w, sid)[0]!;
            const objects = w.originals.objects.size;
            const puts = w.originals.putValueTypes.length;
            const rows = w.items().length;
            const res = await crop(photo.id, o);
            expect(res.status).toBe(status);
            expect(((await res.json()) as any).error.code).toBe(code);
            expect(w.originals.objects.size).toBe(objects);
            expect(w.originals.putValueTypes).toHaveLength(puts);
            expect(w.items()).toHaveLength(rows);
        });
    }

    it("exactly 50 MB is accepted by the header check (the limit is inclusive)", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        // the header says 50 MB but the body is short: that is the later size check's 400, not the 413
        const res = await crop(photo.id, { headers: { "content-length": String(50 * 1024 * 1024) } });
        expect(res.status).toBe(400);
        expect(w.originals.objects.size).toBe(2); // the two items, nothing made
    });

    it("an unknown anchor is 404 and short ids never match", async () => {
        expect((await crop("NoSuchItem000001")).status).toBe(404);
        expect((await crop("short")).status).toBe(404);
    });
});

describe("what was stored must be what the headers said", () => {
    it("a body that is not a JPEG: 400, the object is deleted, no row", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        const res = await crop(photo.id, { body: Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) });
        expect(res.status).toBe(400);
        expect(madeRows(sid)).toEqual([]);
        expect([...w.originals.objects.keys()].filter((k) => k.startsWith("made/"))).toEqual([]);
    });
    it("a PDF that is not one", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const res = await put(itemRows(w, sid)[0]!.id, { role: "export", spec: spec({ kind: "pdf" }), type: "application/pdf", body: Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) });
        expect(res.status).toBe(400);
        expect([...w.originals.objects.keys()].filter((k) => k.startsWith("made/"))).toEqual([]);
    });
    it("a body shorter than its content-length: 400, nothing kept", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        const res = await crop(photo.id, { headers: { "content-length": "99999" } });
        expect(res.status).toBe(400);
        expect(madeRows(sid)).toEqual([]);
        expect([...w.originals.objects.keys()].filter((k) => k.startsWith("made/"))).toEqual([]);
    });
    it("R2 down: 503 error.api.generic, nothing left behind; the D1 insert failing deletes the object", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        w.originals.failPut = true;
        const res = await crop(photo.id);
        expect(res.status).toBe(503);
        expect(((await res.json()) as any).error.code).toBe("error.api.generic");
        w.originals.failPut = false;
        expect(madeRows(sid)).toEqual([]);
        w.db.raw.exec("CREATE TRIGGER no_made BEFORE INSERT ON media_items WHEN NEW.source = 'made' BEGIN SELECT RAISE(ABORT, 'no'); END");
        const res2 = await crop(photo.id);
        expect(res2.status).toBe(503);
        expect([...w.originals.objects.keys()].filter((k) => k.startsWith("made/"))).toEqual([]);
    });
    it("the name goes through cleanName: no path, no control characters, at most 120 characters; none given: <role>.<ext>", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        const long = await put(photo.id, { role: "crop", spec: spec(), name: `../etc/${"x".repeat(200)}\u0007.jpg` });
        expect(w.item(((await long.json()) as any).item.id).name.length).toBe(120);
        const none = await put(photo.id, { role: "crop", spec: spec() });
        expect(w.item(((await none.json()) as any).item.id).name).toBe("crop.jpg");
    });
});

describe("the gate", () => {
    it("PUT only, keyed (the library service too); every other method and a longer path are 404", async () => {
        const { sid } = await saveGallery(w, photos(2));
        const photo = itemRows(w, sid)[0]!;
        const url = `/library/items/${photo.id}/made?role=crop&spec=${spec()}`;
        const body = jpeg(10, 10);
        expect((await w.call(url, { method: "PUT", headers: { "content-type": "image/jpeg", "content-length": String(body.length) }, body })).status).toBe(401);
        for (const method of ["GET", "POST", "PATCH", "DELETE", "HEAD"]) {
            expect((await w.call(url, { method, headers: auth })).status, method).toBe(404);
        }
        expect((await w.call(`/library/items/${photo.id}/made/extra?role=crop&spec=${spec()}`, { method: "PUT", headers: { ...auth, "content-type": "image/jpeg", "content-length": String(body.length) }, body })).status).toBe(404);
        const viaService = await w.call(url, { method: "PUT", headers: { ...svc, "content-type": "image/jpeg", "content-length": String(body.length) }, body });
        expect(viaService.status).toBe(201);
        expect(w.item(((await viaService.json()) as any).item.id).key_id).toBe("service:library");
    });
});

describe("jpegSize", () => {
    it("reads the start-of-frame, skips other segments, and says null for anything else", () => {
        expect(jpegSize(jpeg(1080, 1920))).toEqual({ width: 1080, height: 1920 });
        expect(jpegSize(jpeg(7, 65535))).toEqual({ width: 7, height: 65535 });
        expect(jpegSize(Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]))).toBeNull();
        expect(jpegSize(new Uint8Array(0))).toBeNull();
        expect(jpegSize(Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))).toBeNull();
        expect(POSTER_URL.test(`${MEDIA_BASE}Abcdefghij.jpg`)).toBe(true);
    });
});
