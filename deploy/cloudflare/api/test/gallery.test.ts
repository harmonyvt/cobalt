// Photos and galleries (APP-API-CONTRACT.md section 18, lane GS2): saving several items of a post, a photo saved
// as a photo (the 0.04 s mp4 fix), the retry of the items that failed, GET /library?v=3 and the legacy collapse,
// DELETE of one item, the post-scope visibility, and the migration. The Worker, the Durable Object's services and
// the real SQL (node:sqlite over every migration) run together; the helper and both R2 buckets are the fakes of
// studio-fakes.ts (the helper speaks exactly 18.7).
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_PUBLIC_ATTEMPTS, parseItemsField, parseItemCountField, parseSlideshowPlan, slideshowFrame } from "../src/studio";
import { KEY_ID, MEDIA_BASE, POSTER_URL, asBody, auth, json, world, type World } from "./poster-world";
import { fakeJpeg, type GalleryItemSpec } from "./studio-fakes";
import { listAll, patchVisibility } from "./visibility-fixture";
import { POST, itemRows, photos, saveGallery } from "./gallery-world";


let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
});

describe("POST /studio: the items field (a table of every bad shape: 400, nothing created)", () => {
    const bad: [string, unknown][] = [
        ["a number", 3],
        ["a bare string", "everything"],
        ["an empty array", []],
        ["21 indices", Array.from({ length: 21 }, (_, i) => i)],
        ["a repeated index", [1, 1]],
        ["a descending pair", [3, 1]],
        ["a negative index", [-1, 2]],
        ["a fraction", [0, 1.5]],
        ["a string index", ["0", "1"]],
        ["an index of 50 or more", [0, 50]],
        ["an object", { 0: true }],
        ["true", true],
    ];
    for (const [name, items] of bad) {
        it(`items: ${name}`, async () => {
            const r = await w.studio.create(KEY_ID, json({ url: POST, items }));
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.studio.invalid_params" } } });
            expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
            expect(w.helper.calls).toEqual([]);
        });
    }
    const badCount: unknown[] = [0, 51, 2.5, "10", true, -1];
    for (const item_count of badCount) {
        it(`item_count: ${JSON.stringify(item_count)}`, async () => {
            const r = await w.studio.create(KEY_ID, json({ url: POST, items: "all", item_count }));
            expect(r.status).toBe(400);
            expect(asBody(r).error.code).toBe("error.studio.invalid_params");
            expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        });
    }
    it("an index at or past item_count contradicts it", async () => {
        const r = await w.studio.create(KEY_ID, json({ url: POST, items: [0, 4], item_count: 4 }));
        expect(r.status).toBe(400);
    });
    it("every good shape is accepted", async () => {
        for (const items of ["all", "first-video", [0], [0, 3, 19], null, undefined]) {
            const r = await w.studio.create(KEY_ID, json({ url: POST, ...(items === undefined ? {} : { items }) }));
            expect(r.status, JSON.stringify(items)).toBe(201);
            await w.settle(asBody(r).id).catch(() => {});
        }
    });
    it("the parsers", () => {
        expect(parseItemsField(undefined)).toEqual({ ok: true, items: undefined });
        expect(parseItemsField(null)).toEqual({ ok: true, items: undefined });
        expect(parseItemsField([0, 2])).toEqual({ ok: true, items: [0, 2] });
        expect(parseItemsField([2, 0])).toEqual({ ok: false });
        expect(parseItemCountField(10)).toEqual({ ok: true, count: 10 });
        expect(parseItemCountField(51)).toEqual({ ok: false });
    });
});

describe("a gallery of ten photos is saved as ten items of one session", () => {
    it("10 rows, keys -00..-09, post_key, the thumbs as posters, the lead item names the session; nothing public unless asked", async () => {
        const { sid, done, created } = await saveGallery(w, photos(10));
        expect(Object.keys(created).sort()).toEqual(["id", "status", "url"]); // today's shape for a caller that sent no slideshow
        const rows = itemRows(w, sid);
        expect(rows).toHaveLength(10);
        rows.forEach((r, i) => {
            const nn = String(i).padStart(2, "0");
            expect(r).toMatchObject({
                kind: "private",
                source: "saved",
                bucket: "originals",
                r2_key: `originals/${sid}-${nn}.jpg`,
                content_type: "image/jpeg",
                role: "item",
                item_index: i,
                post_key: sid,
                session_id: sid,
                duration: null,
                visibility: "private",
                url: null,
            });
            expect(r.poster, `thumb of ${i}`).toMatch(POSTER_URL);
            expect(w.originals.objects.get(r.r2_key)?.contentType).toBe("image/jpeg");
            // the thumb is a public JPEG object under an unguessable name
            const thumb = w.media.objects.get(r.poster.slice(MEDIA_BASE.length));
            expect(thumb?.contentType).toBe("image/jpeg");
        });
        // the session names the lead: no video, so item 0
        expect(w.session(sid)).toMatchObject({
            status: "ready",
            r2_key: `originals/${sid}-00.jpg`,
            content_type: "image/jpeg",
            item_count: 10,
            width: 1080,
            height: 1350,
            duration: null,
        });
        expect(JSON.parse(w.session(sid).items)).toEqual(Array.from({ length: 10 }, (_, i) => ({ i, type: "photo", status: "ready", code: null })));
        // GET /studio/<sid> gains item_count and items; the old fields describe the lead
        expect(done).toMatchObject({ status: "ready", item_count: 10, width: 1080, height: 1350, duration: null });
        expect(done.items).toHaveLength(10);
        expect(done.items[3]).toEqual({ i: 3, type: "photo", status: "ready", code: null });
        // the helper was asked once, for everything; the file of each came by its index; one thumb each
        expect(w.helper.fetchBodies).toEqual([{ id: sid, url: POST, items: "all", item_count: 10 }]);
        expect(w.helper.fileQueries).toEqual(Array.from({ length: 10 }, (_, i) => String(i)));
        expect(w.helper.thumbQueries).toEqual(Array.from({ length: 10 }, (_, i) => String(i)));
        expect(w.helper.calls).toContain(`DELETE /fetch/${sid}`);
        expect(w.kv.m.has(`save:${sid}`)).toBe(false);
        // nothing is hosted: no `public` was asked for
        expect(w.items().filter((r) => r.url !== null)).toEqual([]);
        expect(done.public_state).toBeNull();
    });

    it("`public: true` makes one mirror per item (the lead's, then the others'), and the session says ready only when every one is", async () => {
        const { sid, done } = await saveGallery(w, photos(4), { public: true });
        expect(done).toMatchObject({ status: "ready", public_state: "ready" });
        const rows = itemRows(w, sid);
        expect(rows).toHaveLength(4);
        const keys = new Set<string>();
        for (const r of rows) {
            expect(r.visibility, `item ${r.item_index}`).toBe("public");
            expect(r.url).toBe(`${MEDIA_BASE}${r.public_key}`);
            expect(r.public_key).toMatch(/^[A-Za-z0-9]{10}\.jpg$/);
            expect(w.media.objects.has(r.public_key)).toBe(true);
            keys.add(r.public_key);
        }
        expect(keys.size).toBe(4);
        expect(done.public_url).toBe(rows[0].url);
    });

    it("one mirror that fails is finished by the sweep: the record stays until every item is public", async () => {
        // the public bucket refuses the second copy once
        let n = 0;
        const put = w.media.put.bind(w.media);
        w.media.put = async (key: string, value: any, o: any) => {
            if (String(key).endsWith(".jpg") && o.customMetadata.mirror === "1" && ++n === 2) throw new Error("R2 down");
            return put(key, value, o);
        };
        const { sid, done } = await saveGallery(w, photos(3), { public: true });
        expect(done.status).toBe("ready");
        // the session's state follows its lead item (section 16, I5): the lead is public, so it says ready ...
        expect(done.public_state).toBe("ready");
        expect(itemRows(w, sid).map((r) => r.visibility)).toEqual(["public", "private", "public"]);
        // ... but the post is not finished: the record the sweep works from stays
        expect([...w.kv.m.keys()]).toContain(`public:${sid}`);
        await w.studio.sweep();
        expect(itemRows(w, sid).map((r) => r.visibility)).toEqual(["public", "public", "public"]);
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("public:"))).toEqual([]);
        expect(asBody(await w.studio.advance(sid, 0)).public_state).toBe("ready");
    });

    it("an item that never gets its mirror: the attempts run out and the record is dropped (the owner's switch can still do it)", async () => {
        const put = w.media.put.bind(w.media);
        let leadDone = false;
        w.media.put = async (key: string, value: any, o: any) => {
            if (String(key).endsWith(".jpg") && o.customMetadata.mirror === "1") {
                if (!leadDone) leadDone = true; // the lead's copy goes through
                else throw new Error("R2 down");
            }
            return put(key, value, o);
        };
        const { sid } = await saveGallery(w, photos(2), { public: true });
        expect(itemRows(w, sid).map((r) => r.visibility)).toEqual(["public", "private"]);
        for (let i = 0; i < MAX_PUBLIC_ATTEMPTS + 2; i++) await w.studio.sweep();
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("public:"))).toEqual([]);
        expect(itemRows(w, sid).map((r) => r.visibility)).toEqual(["public", "private"]);
    });

    it("a post with a video: the lead (the session's original) is the first video, wherever it sits", async () => {
        const { sid, done } = await saveGallery(w, [{ type: "photo" }, { type: "photo" }, { type: "video", duration: 6.5, width: 720, height: 1280 }, { type: "gif" }]);
        const rows = itemRows(w, sid);
        expect(rows.map((r) => [r.item_index, r.content_type, r.r2_key.split(".").pop()])).toEqual([
            [0, "image/jpeg", "jpg"],
            [1, "image/jpeg", "jpg"],
            [2, "video/mp4", "mp4"],
            [3, "image/gif", "gif"],
        ]);
        expect(w.session(sid)).toMatchObject({ r2_key: `originals/${sid}-02.mp4`, content_type: "video/mp4", duration: 6.5, width: 720, height: 1280 });
        expect(done.item_count).toBe(4);
        expect(done.items.map((e: any) => e.type)).toEqual(["photo", "photo", "video", "gif"]);
        // a video item gets no thumb from the helper: the poster job makes it
        expect(rows[2].poster).toBeNull();
        expect(rows[3].poster).toBeNull();
        expect(w.helper.thumbQueries).toEqual(["0", "1"]);
        // the lead's row is the session's original
        const lead = rows[2];
        expect(lead.name).toBe("ig_Ddy0-gpGg5U");
        expect(rows[0].name).toBe("ig_Ddy0-gpGg5U-00.jpg");
        // posters queued for the video and the gif (images got their thumbs)
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("poster:")).sort()).toEqual([`poster:${rows[2].id}`, `poster:${rows[3].id}`].sort());
    });

    it("items: [0, 3] saves only those, with their own indices; the others are not recorded", async () => {
        const { sid, done } = await saveGallery(w, photos(5), { items: [0, 3] });
        expect(itemRows(w, sid).map((r) => r.item_index)).toEqual([0, 3]);
        expect(itemRows(w, sid).map((r) => r.r2_key)).toEqual([`originals/${sid}-00.jpg`, `originals/${sid}-03.jpg`]);
        expect(w.helper.fetchBodies[0]).toEqual({ id: sid, url: POST, items: [0, 3], item_count: 5 });
        expect(w.helper.fileQueries).toEqual(["0", "3"]);
        expect(done.item_count).toBe(5);
        expect(done.items.map((e: any) => e.i)).toEqual([0, 3]);
    });

    it("a request with no `items` sends the helper exactly today's body", async () => {
        const res = await w.studio.create(KEY_ID, json({ url: POST }));
        await w.settle(asBody(res).id);
        expect(w.helper.fetchBodies).toEqual([{ id: asBody(res).id, url: POST }]);
    });
});

describe("a gallery where an item fails", () => {
    const specs = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo" }];

    it("keeps the rest: 2 rows, the failure recorded in `items`, items_failed [1] in GET /library?v=3", async () => {
        const { sid, done } = await saveGallery(w, specs());
        expect(done.status).toBe("ready");
        expect(itemRows(w, sid).map((r) => r.item_index)).toEqual([0, 2]);
        expect(done.item_count).toBe(3);
        expect(done.items).toEqual([
            { i: 0, type: "photo", status: "ready", code: null },
            { i: 1, type: null, status: "error", code: "error.studio.fetch_failed" },
            { i: 2, type: "photo", status: "ready", code: null },
        ]);
        const l = await listAll(w, "v=3");
        expect(l.posts).toHaveLength(1);
        expect(l.posts[0]).toMatchObject({ kind: "gallery", item_count: 2, items_failed: [1] });
        expect(l.posts[0].files.map((f: any) => f.item_index)).toEqual([0, 2]);
    });

    it("the save fails only when every item failed, with the first one's code", async () => {
        const { done } = await saveGallery(w, [{ type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.other" }]);
        expect(done).toMatchObject({ status: "error", error: { code: "error.studio.fetch_failed" } });
        expect(w.items()).toEqual([]);
    });

    it("a post whose count changed since the client saw it: error.studio.gallery_changed, nothing stored", async () => {
        w.helper.gallery = photos(10);
        const { done } = await saveGallery(w, null, { item_count: 9 });
        expect(done).toMatchObject({ status: "error", error: { code: "error.studio.gallery_changed" } });
        expect(w.items()).toEqual([]);
        expect([...w.originals.objects.keys()]).toEqual([]);
    });

    it("a storage failure on one item records it and keeps the others", async () => {
        const put = w.originals.put.bind(w.originals);
        w.originals.put = async (key: string, v: any, o: any) => {
            if (key.endsWith("-01.jpg")) throw new Error("R2 down");
            return put(key, v, o);
        };
        const { sid, done } = await saveGallery(w, photos(3));
        expect(itemRows(w, sid).map((r) => r.item_index)).toEqual([0, 2]);
        expect(done.items[1]).toMatchObject({ i: 1, status: "error", code: "error.studio.storage" });
    });
});

describe("POST /studio/<sid>/items/retry", () => {
    const retry = (sid: string, body: unknown, headers: Record<string, string> = auth) =>
        w.call(`/studio/${sid}/items/retry`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: typeof body === "string" ? body : json(body) });

    it("fetches only the missing indices, adds their rows and brings the session back to ready with every item", async () => {
        const specs = photos(3);
        specs[1] = { type: "photo", fail: "error.studio.fetch_failed" };
        const { sid } = await saveGallery(w, specs);
        expect(itemRows(w, sid)).toHaveLength(2);
        specs[1] = { type: "photo" }; // the link works now
        w.helper.fetchBodies.length = 0;
        w.helper.fileQueries.length = 0;
        w.helper.thumbQueries.length = 0;

        const res = await retry(sid, { items: [0, 1], queue: true });
        expect(res.status).toBe(202);
        expect(await res.json()).toEqual({ status: "pending", id: sid, queued: false, queue_ahead: null });
        const done = asBody(await w.settle(sid));
        expect(done.status).toBe("ready");
        // only index 1 was asked for (0 is saved already) and only its file and thumb were fetched
        expect(w.helper.fetchBodies).toEqual([{ id: sid, url: POST, items: [1], item_count: 3 }]);
        expect(w.helper.fileQueries).toEqual(["1"]);
        expect(w.helper.thumbQueries).toEqual(["1"]);
        expect(itemRows(w, sid).map((r) => [r.item_index, r.r2_key])).toEqual([
            [0, `originals/${sid}-00.jpg`],
            [1, `originals/${sid}-01.jpg`],
            [2, `originals/${sid}-02.jpg`],
        ]);
        expect(done.items.map((e: any) => [e.i, e.status])).toEqual([[0, "ready"], [1, "ready"], [2, "ready"]]);
        expect(done.item_count).toBe(3);
        const l = await listAll(w, "v=3");
        expect(l.posts[0]).toMatchObject({ item_count: 3, items_failed: [] });
        expect(w.kv.m.has(`save:${sid}`)).toBe(false);
    });

    it("asking only for what is saved is a no-op: 200, no helper call, the session untouched", async () => {
        const { sid } = await saveGallery(w, photos(2));
        w.helper.calls.length = 0;
        const res = await retry(sid, { items: [0, 1] });
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", id: sid, queued: false, queue_ahead: null });
        expect(w.helper.calls).toEqual([]);
        expect(w.session(sid).status).toBe("ready");
    });

    it("a failure again leaves the session ready, with the new code on the item (never an error session)", async () => {
        const specs = photos(2);
        specs[1] = { type: "photo", fail: "error.studio.fetch_failed" };
        const { sid } = await saveGallery(w, specs);
        specs[1] = { type: "photo", fail: "error.studio.still_expired" };
        const res = await retry(sid, { items: [1] });
        expect(res.status).toBe(202);
        const done = asBody(await w.settle(sid));
        expect(done.status).toBe("ready");
        expect(done.items[1]).toMatchObject({ i: 1, status: "error", code: "error.studio.still_expired" });
        expect(itemRows(w, sid)).toHaveLength(1);
        expect(w.kv.m.has(`save:${sid}`)).toBe(false);
        // and the same retry can be tried again later
        specs[1] = { type: "photo" };
        expect((await retry(sid, { items: [1] })).status).toBe(202);
        expect(asBody(await w.settle(sid)).items[1].status).toBe("ready");
    });

    it("a post that changed since: 409 error.studio.gallery_changed (the warm helper says so at once), the session stays ready", async () => {
        const specs = photos(3);
        specs[1] = { type: "photo", fail: "error.studio.fetch_failed" };
        const { sid } = await saveGallery(w, specs);
        w.helper.gallery = photos(5); // the post grew
        const res = await retry(sid, { items: [1] });
        expect(res.status).toBe(409);
        expect(((await res.json()) as any).error.code).toBe("error.studio.gallery_changed");
        const s = asBody(await w.studio.advance(sid, 0));
        expect(s.status).toBe("ready");
        expect(s.items[1]).toMatchObject({ status: "error", code: "error.studio.gallery_changed" });
    });

    it("validation: bad bodies 400, an index past the count 400, a single save 409 not_gallery, a stranger or an unknown id 404", async () => {
        const { sid } = await saveGallery(w, photos(3));
        for (const body of ["not json", "[]", json({}), json({ items: "all" }), json({ items: [] }), json({ items: [1, 1] }), json({ items: [3] }), json({ items: [0], queue: "yes" })]) {
            const r = await retry(sid, body);
            expect(r.status, body).toBe(400);
            expect(((await r.json()) as any).error.code).toBe("error.studio.invalid_params");
        }
        expect((await retry("X".repeat(22), { items: [0] })).status).toBe(404);
        const single = await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }));
        await w.settle(asBody(single).id);
        const r = await retry(asBody(single).id, { items: [0] });
        expect(r.status).toBe(409);
        expect(((await r.json()) as any).error.code).toBe("error.studio.not_gallery");
        // the route is keyed, and the library service credential never reaches it
        expect((await w.call(`/studio/${sid}/items/retry`, { method: "POST", body: json({ items: [0] }) })).status).toBe(401);
        expect((await retry(sid, { items: [0] }, { "x-cobalt-service": "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e" })).status).toBe(404);
        expect((await w.call(`/studio/${sid}/items/retry`, { method: "GET", headers: auth })).status).toBe(404);
        expect((await w.call(`/studio/${sid}/items/other`, { method: "POST", headers: auth, body: "{}" })).status).toBe(404);
    });

    it("someone else's session looks unknown", async () => {
        const { sid } = await saveGallery(w, photos(2));
        w.db.raw.prepare("UPDATE studio_sessions SET key_id = 'someone-else' WHERE id = ?").run(sid);
        const r = await retry(sid, { items: [0] });
        expect(r.status).toBe(404);
    });

    it("the helper busy: 429 without queue, and with queue the retry waits in the line and the session stays ready until it starts", async () => {
        const specs = photos(3);
        specs[1] = { type: "photo", fail: "error.studio.fetch_failed" };
        const { sid } = await saveGallery(w, specs);
        // another save holds the helper
        const other = await w.studio.create(KEY_ID, json({ url: "https://x.com/b/status/2" }));
        expect(other.status).toBe(201);
        const refused = await retry(sid, { items: [1] });
        expect(refused.status).toBe(429);
        expect(w.session(sid).status).toBe("ready"); // a refusal changes nothing
        const queued = await retry(sid, { items: [1], queue: true });
        expect(queued.status).toBe(202);
        expect(await queued.json()).toMatchObject({ status: "pending", id: sid, queued: true, queue_ahead: 1 });
        // while it waits the session stays ready (a studio, a render, the library keep working on it)
        expect(w.session(sid).status).toBe("ready");
        specs[1] = { type: "photo" };
        await w.settle(asBody(other).id);
        // its turn: the sweep starts it, and only now does the session read saving
        await w.studio.sweep();
        expect(w.session(sid).status).toBe("saving");
        for (let i = 0; i < 6 && itemRows(w, sid).length < 3; i++) await w.studio.sweep();
        expect(w.session(sid).status).toBe("ready");
        expect(itemRows(w, sid)).toHaveLength(3);
    });

    it("cancelling a queued retry leaves the session ready (it never turns into an error)", async () => {
        const specs = photos(3);
        specs[1] = { type: "photo", fail: "error.studio.fetch_failed" };
        const { sid } = await saveGallery(w, specs);
        await w.studio.create(KEY_ID, json({ url: "https://x.com/b/status/2" }));
        await retry(sid, { items: [1], queue: true });
        const c = await w.call(`/studio/${sid}/line`, { method: "DELETE", headers: auth });
        expect(c.status).toBe(200);
        expect(w.session(sid)).toMatchObject({ status: "ready", error_code: null });
    });
});

describe("a single photo is saved as a photo (the 0.04 s mp4 fix)", () => {
    const jpeg = fakeJpeg(900);
    const photoDone = { contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350 };

    it("image/jpeg, originals/<sid>.jpg, duration NULL, role NULL, a poster from the thumb", async () => {
        w.helper.videoBytes = jpeg;
        w.helper.fetchDone = photoDone;
        w.helper.singleThumb = fakeJpeg(60, 9);
        const r = await w.studio.create(KEY_ID, json({ url: "https://x.com/maria_rcks/status/2105237035271258436" }));
        const sid = asBody(r).id as string;
        const done = asBody(await w.settle(sid));
        expect(done).toMatchObject({ status: "ready", width: 1080, height: 1350, duration: null });
        expect(done).not.toHaveProperty("item_count"); // a single file reads as it always did
        expect(done).not.toHaveProperty("items");
        const row = w.items()[0];
        expect(row).toMatchObject({ source: "saved", bucket: "originals", r2_key: `originals/${sid}.jpg`, content_type: "image/jpeg", duration: null, role: null, item_index: null, post_key: null, width: 1080, height: 1350 });
        expect(row.poster).toMatch(POSTER_URL);
        expect(w.session(sid)).toMatchObject({ r2_key: `originals/${sid}.jpg`, content_type: "image/jpeg", duration: null, poster: row.poster });
        const obj = w.originals.objects.get(`originals/${sid}.jpg`)!;
        expect(obj.contentType).toBe("image/jpeg");
        expect(obj.bytes).toEqual(jpeg);
        expect(w.helper.thumbQueries).toEqual(["null"]);
        // no poster job: the thumb is the poster
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("poster:"))).toEqual([]);
    });

    for (const [type, ext] of [["image/png", "png"], ["image/webp", "webp"], ["image/heic", "heic"]] as const) {
        it(`${type} keeps its type and extension`, async () => {
            w.helper.fetchDone = { ...photoDone, contentType: type, ext };
            const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
            await w.settle(sid);
            expect(w.items()[0]).toMatchObject({ content_type: type, r2_key: `originals/${sid}.${ext}`, duration: null });
        });
    }

    it("no thumb (an old helper, or none made): the poster job makes it, since an image has a frame now", async () => {
        w.helper.fetchDone = photoDone; // singleThumb stays null: the helper answers 404
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await w.settle(sid);
        const row = w.items()[0];
        expect(row.poster).toBeNull();
        expect([...w.kv.m.keys()]).toContain(`poster:${row.id}`);
    });

    it("anything that is not a video, a gif or one of those images is coerced to video/mp4 as ever", async () => {
        w.helper.fetchDone = { contentType: "text/html", ext: "../../x", title: "   " };
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await w.settle(sid);
        expect(w.items()[0]).toMatchObject({ content_type: "video/mp4", r2_key: `originals/${sid}.mp4` });
        w.helper.thumbQueries.length = 0;
        expect(w.helper.thumbQueries).toEqual([]);
    });

    it("a video is untouched: no thumb is asked for, the poster is queued as before", async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await w.settle(sid);
        expect(w.helper.thumbQueries).toEqual([]);
        expect(w.items()[0]).toMatchObject({ content_type: "video/mp4", role: null, post_key: null });
        expect([...w.kv.m.keys()]).toContain(`poster:${w.items()[0].id}`);
    });
});

describe("a save that is one file: the session reads as a single file", () => {
    it("items: 'first-video' on a post: today's save (no items list from the helper): originals/<sid>.mp4, no role", async () => {
        w.helper.gallery = [{ type: "photo" }, { type: "video" }, { type: "photo" }];
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: POST, items: "first-video", item_count: 3 }))).id as string;
        await w.settle(sid);
        expect(w.helper.fetchBodies[0]).toEqual({ id: sid, url: POST, items: "first-video", item_count: 3 });
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ role: null, item_index: null, post_key: null, r2_key: `originals/${sid}.mp4` });
        expect(w.session(sid).item_count).toBeNull();
    });

    it("items: 'all' on a link that is not a post of several items (the helper answers a plain done body): byte for byte today's save", async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1", items: "all" }))).id as string;
        const done = asBody(await w.settle(sid));
        expect(w.helper.fetchBodies[0]).toEqual({ id: sid, url: "https://x.com/a/status/1", items: "all" });
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ role: null, item_index: null, post_key: null, r2_key: `originals/${sid}.mp4`, source: "saved" });
        expect(done).not.toHaveProperty("item_count");
        expect(done).not.toHaveProperty("items");
    });
});
