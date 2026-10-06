// Regression tests for the review of the gallery server (APP-API-CONTRACT.md section 18): each proof of the reviewer
// (zz-adv*, zz-adversarial) failed before its fix and passes after. Finding numbers are the reviewer's.
import { describe, expect, it } from "vitest";
import { MAX_SLIDESHOW_MOTION_SECONDS, repointLead } from "../src/studio";
import { KEY_ID, MEDIA_BASE, asBody, auth, json, world } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { POST, itemRows, photos, saveGallery } from "./gallery-world";
import { migrate } from "./visibility-fixture";

const aliveRows = (L: { rows: LW["rows"] }, sid: string) => L.rows("SELECT id, r2_key FROM media_items WHERE session_id = ? AND deleted_at IS NULL ORDER BY item_index", sid);
const objectsOf = (L: LW, sid: string) => [...L.originals.objects.keys()].filter((k) => k.includes(sid));

describe("1. a second finalize of the same save (the save lock goes stale during a long copy) deletes nothing the first one keeps", () => {
    async function stall(L: LW, hold: (key: string) => boolean) {
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        let entered!: () => void;
        const inPut = new Promise<void>((r) => (entered = r));
        let first = true;
        const put = L.originals.put.bind(L.originals);
        (L.originals as any).put = async (k: string, v: any, o: any) => {
            if (hold(k) && first) {
                first = false;
                entered();
                await gate;
            }
            return put(k, v, o);
        };
        return { release, inPut };
    }

    it("a gallery: the rows, the objects and the session all survive (zz-adv4)", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1;
        const g = await saveGallery(L as any, [{ type: "photo" }, { type: "video" }, { type: "photo" }], {}, false);
        const sid = g.sid;
        const { release, inPut } = await stall(L, (k) => k.endsWith("-01.mp4"));
        const a = L.studio.advance(sid, 0).then(() => L.studio.advance(sid, 0)).then(() => L.studio.advance(sid, 0));
        await inPut;
        L.clock.t += 61_000; // the copy has run past LOCK_STALE_MS
        const b = await L.studio.advance(sid, 0); // a second poll finalizes in parallel and wins
        expect((b.body as any).status).toBe("ready");
        release();
        await a;
        expect(aliveRows(L, sid).map((r) => r.r2_key)).toEqual([`originals/${sid}-00.jpg`, `originals/${sid}-01.mp4`, `originals/${sid}-02.jpg`]);
        for (const r of aliveRows(L, sid)) expect(L.originals.objects.has(r.r2_key), r.r2_key).toBe(true);
        expect(L.session(sid)).toMatchObject({ status: "ready", r2_key: `originals/${sid}-01.mp4` });
        expect(L.keys("save:")).toEqual([]);
    });

    it("a single file saved today the same way: the original is kept (zz-adv5)", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1;
        const g = await saveGallery(L as any, null, { items: undefined }, false);
        const sid = g.sid;
        const { release, inPut } = await stall(L, (k) => k.endsWith(".mp4"));
        const a = L.studio.advance(sid, 0).then(() => L.studio.advance(sid, 0)).then(() => L.studio.advance(sid, 0));
        await inPut;
        L.clock.t += 61_000;
        expect(((await L.studio.advance(sid, 0)).body as any).status).toBe("ready");
        release();
        await a;
        expect(aliveRows(L, sid)).toHaveLength(1);
        expect(L.originals.objects.has(`originals/${sid}.mp4`)).toBe(true);
        expect(L.session(sid)).toMatchObject({ status: "ready", r2_key: `originals/${sid}.mp4` });
    });

    it("a save really marked lost (or its post deleted) meanwhile still cleans up after itself", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1;
        const g = await saveGallery(L as any, photos(2), {}, false);
        const sid = g.sid;
        const { release, inPut } = await stall(L, (k) => k.endsWith("-01.jpg"));
        const a = L.studio.advance(sid, 0).then(() => L.studio.advance(sid, 0)).then(() => L.studio.advance(sid, 0));
        await inPut;
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'error.studio.save_lost' WHERE id = ?").run(sid);
        release();
        await a;
        expect(L.rows("SELECT * FROM media_items WHERE session_id = ?", sid)).toEqual([]);
        expect(objectsOf(L, sid)).toEqual([]);
    });

    it("the lock is kept fresh while items are stored: a poll after the first item took 61 s does not start a second finalize", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1;
        const g = await saveGallery(L as any, photos(3), {}, false);
        const sid = g.sid;
        const finalizes: string[] = [];
        const put = L.originals.put.bind(L.originals);
        (L.originals as any).put = async (k: string, v: any, o: any) => {
            finalizes.push(k);
            const r = await put(k, v, o);
            L.clock.t += 40_000; // each item takes 40 s: the whole save is past a minute, no single step is
            return r;
        };
        const a = L.studio.advance(sid, 0).then(() => L.studio.advance(sid, 0)).then(() => L.studio.advance(sid, 0));
        await a;
        // (the second poll found the first still running or finished: never a parallel copy of the same keys)
        expect(finalizes.filter((k) => k.endsWith("-00.jpg"))).toHaveLength(1);
    });
});

describe("2. a slideshow input the helper answers with anything but 204/413/400", () => {
    const plan = { items: [0, 1], seconds: [3, 3], fade: true, frame: "keep", sound: "none", queue: true };

    it("404 (an older helper image has no /slideshow): the slideshow fails at once and the head of the line is free (zz-adversarial T1)", async () => {
        const L = await lineWorld({ posters: false });
        const { sid } = await saveGallery(L as any, photos(2));
        L.helper.slideInputStatus = 404;
        const r = await L.studio.slideshow(KEY_ID, sid, json(plan));
        const job = asBody(r).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.unavailable");
        expect(L.entries()).toEqual([]);
        // a share-sheet save behind it starts right away
        L.helper.slideInputStatus = null;
        L.helper.calls.length = 0;
        const share = await L.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json({ url: "https://x.com/a/status/9", origin: "share" }) });
        expect(share.status).toBe(201);
        expect(L.helper.calls).toContain("POST /fetch");
    });

    for (const [status, code] of [[409, "error.studio.missing"], [500, "error.webp.unavailable"], [502, "error.webp.unavailable"], [404, "error.webp.unavailable"]] as const) {
        it(`${status} on an input is a failure, not "try later"`, async () => {
            const L = await lineWorld({ posters: false });
            const { sid } = await saveGallery(L as any, photos(2));
            L.helper.slideInputStatus = status;
            const job = asBody(await L.studio.slideshow(KEY_ID, sid, json(plan))).job as string;
            const err = asBody(await L.studio.renderStatus(sid, job, 0)).error.code;
            expect(err).toBe(status === 409 ? "error.webp.unavailable" : code);
            expect(L.entries()).toEqual([]);
        });
    }

    it("429 and 503 are what a render waits for too: the entry stays at the head", async () => {
        for (const status of [429, 503]) {
            const L = await lineWorld({ posters: false });
            const { sid } = await saveGallery(L as any, photos(2));
            L.helper.slideInputStatus = status;
            const job = asBody(await L.studio.slideshow(KEY_ID, sid, json(plan))).job as string;
            expect(L.entries()).toHaveLength(1);
            expect(L.entries()[0]!.attempts).toBe(1);
            expect(asBody(await L.studio.renderStatus(sid, job, 0)).phase).toBe("queued");
        }
    });

    it("a start answered 404/500 is a failure too (409 bad_request is a start that already happened)", async () => {
        const L = await lineWorld({ posters: false });
        const { sid } = await saveGallery(L as any, photos(2));
        L.helper.slideStartStatus = 500;
        const job = asBody(await L.studio.slideshow(KEY_ID, sid, json(plan))).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.unavailable");
        expect(L.entries()).toEqual([]);
    });
});

describe("2b. features.gallery follows the helper that really runs", () => {
    const flag = async (w: { call: (u: string, i?: RequestInit) => Promise<Response> }) => ((await (await w.call("/capabilities")).json()) as any).features.gallery;

    it("not advertised before the helper has answered, advertised after an answer that says gallery=1, off again for an older image", async () => {
        const w = world();
        await w.addKey();
        expect(await flag(w)).toBe(false); // a Worker deployed ahead of the container rollout
        await saveGallery(w, photos(2));
        expect(await flag(w)).toBe(true);
        // the container rolled back (or is the old image): its answers carry no header
        w.helper.advertise = false;
        await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" })).then((r) => w.settle(asBody(r).id));
        expect(await flag(w)).toBe(false);
    });

    it("an old helper from the start never makes it true", async () => {
        const w = world();
        await w.addKey();
        w.helper.advertise = false;
        await saveGallery(w, photos(2));
        expect(await flag(w)).toBe(false);
    });

    it("it is remembered across a Durable Object restart (read from storage), and a bad storage answer is false", async () => {
        const w = world();
        await w.addKey();
        await saveGallery(w, photos(2));
        const fresh = w.make(); // a new object over the same storage
        expect(((await fresh.helperCaps()).body as any).gallery).toBe(true);
        expect(((await w.make({ storage: { get: async () => { throw new Error("x"); }, put: async () => {}, delete: async () => {}, list: async () => new Map() } as any }).helperCaps()).body as any).gallery).toBe(false);
    });
});

describe("3. deleting a post during an item retry never brings it back", () => {
    async function setup() {
        const L = await lineWorld({ posters: false });
        const { sid } = await saveGallery(L as any, [{ type: "video" }, { type: "photo", fail: "error.webp.download_failed" }]);
        L.helper.gallery = [{ type: "video" }, { type: "photo" }];
        L.clock.t += 20 * 60_000;
        return { L, sid };
    }
    const nothingLeft = (L: LW, sid: string) => {
        expect(aliveRows(L, sid)).toEqual([]);
        expect(objectsOf(L, sid)).toEqual([]);
        expect(L.session(sid).expires_at).toBeLessThanOrEqual(L.clock.t);
    };

    it("deleted while the retry waits for the helper (zz-adv2): it is dropped, the post stays deleted, the library is empty", async () => {
        const { L, sid } = await setup();
        L.helper.fetchPolls = 3;
        expect((await L.studio.retryItems(KEY_ID, sid, json({ items: [1], queue: true }))).status).toBe(202);
        const lead = itemRows(L as any, sid)[0];
        const del = await L.call(`/library/items/${lead.id}/post`, { method: "DELETE", headers: auth });
        expect(del.status).toBe(200);
        L.clock.t += 1000;
        for (let i = 0; i < 5; i++) {
            await L.studio.sweep();
            await L.studio.advance(sid, 0);
        }
        L.clock.t += 11 * 60_000;
        for (let i = 0; i < 3; i++) {
            await L.studio.sweep();
            await L.studio.reapOrphans();
        }
        nothingLeft(L, sid);
        const lib = (await (await L.call("/library?v=3", { headers: auth })).json()) as any;
        expect(lib.posts).toEqual([]);
        expect(L.keys("save:")).toEqual([]);
    });

    it("deleted while the retry is storing its item (zz-adv3): nothing is revived, the stored object and thumb are removed", async () => {
        const { L, sid } = await setup();
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        let entered!: () => void;
        const inPut = new Promise<void>((r) => (entered = r));
        const put = L.originals.put.bind(L.originals);
        (L.originals as any).put = async (k: string, v: any, o: any) => {
            if (k.endsWith("-01.jpg")) {
                entered();
                await gate;
            }
            return put(k, v, o);
        };
        L.helper.fetchPolls = 1;
        await L.studio.retryItems(KEY_ID, sid, json({ items: [1], queue: true }));
        const stepping = L.studio.advance(sid, 0).then(() => L.studio.advance(sid, 0));
        await inPut;
        const lead = itemRows(L as any, sid)[0];
        L.clock.t += 1000;
        expect((await L.call(`/library/items/${lead.id}/post`, { method: "DELETE", headers: auth })).status).toBe(200);
        release();
        await stepping;
        L.clock.t += 1000;
        nothingLeft(L, sid);
        const lib = (await (await L.call("/library?v=3", { headers: auth })).json()) as any;
        expect(lib.posts).toEqual([]);
    });

    it("the same for a single file: a finalize that finds its session expired stores no row and keeps no object", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1;
        const g = await saveGallery(L as any, null, { items: undefined }, false);
        const sid = g.sid;
        L.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(L.clock.t - 1, sid);
        await L.studio.advance(sid, 0);
        await L.studio.advance(sid, 0);
        await L.studio.advance(sid, 0);
        expect(L.rows("SELECT * FROM media_items WHERE session_id = ?", sid)).toEqual([]);
        expect(objectsOf(L, sid)).toEqual([]);
    });
});

describe("5. a retry that waits in the line leaves the session ready until it starts", () => {
    it("the studio keeps answering, a render is accepted, 'open studio' reopens the same session (zz-adversarial T2)", async () => {
        const L = await lineWorld({ posters: false });
        const specs = [{ type: "video" as const }, { type: "photo" as const, fail: "error.webp.download_failed" }];
        const { sid } = await saveGallery(L as any, specs);
        L.helper.jobPolls = 1000; // a render holds the helper
        expect((await L.render(sid, {})).status).toBe(202);
        L.helper.gallery = [{ type: "video" }, { type: "photo" }];
        const re = await L.studio.retryItems(KEY_ID, sid, json({ items: [1], queue: true }));
        expect(asBody(re)).toMatchObject({ status: "pending", queued: true });
        expect(L.session(sid).status).toBe("ready");
        expect(((await (await L.keyed(`/studio/${sid}`)).json()) as any).status).toBe("ready");
        expect((await L.render(sid, { queue: true })).status).toBe(202); // before: 409 not_ready
        const lead = itemRows(L as any, sid)[0];
        const open = await L.call(`/library/items/${lead.id}/studio`, { method: "POST", headers: auth });
        expect(open.status).toBe(200); // the same, still open session: before, a second one was minted
        expect(((await open.json()) as any).id).toBe(sid);
        // a second ask for the same retry while one waits is that one (a single line entry)
        await L.studio.retryItems(KEY_ID, sid, json({ items: [1], queue: true }));
        expect(L.entries().filter((e) => e.sid === sid && e.kind === "save")).toHaveLength(1);
    });

    it("the post being deleted while it waits: the entry is dropped and the session is never marked saving", async () => {
        const L = await lineWorld({ posters: false });
        const specs = [{ type: "video" as const }, { type: "photo" as const, fail: "error.webp.download_failed" }];
        const { sid } = await saveGallery(L as any, specs);
        L.helper.jobPolls = 1000;
        await L.render(sid, {});
        await L.studio.retryItems(KEY_ID, sid, json({ items: [1], queue: true }));
        L.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(L.clock.t - 1, sid); // the post was deleted
        L.helper.jobPolls = 0;
        L.clock.t += 7 * 60_000; // (the render of a deleted post is nobody's to collect: it ages out of "held")
        await L.sweeps(4);
        expect(L.session(sid).status).toBe("ready"); // never marked saving
        expect(L.entries()).toEqual([]);
    });
});

describe("6. what a slideshow may cost", () => {
    it("the videos and gifs of one slideshow are capped at 60 s together; stills are not counted", async () => {
        const L = await lineWorld({ posters: false });
        const { sid } = await saveGallery(L as any, [{ type: "photo" }, { type: "video", duration: 35 }, { type: "video", duration: 30 }, { type: "gif", duration: 10 }]);
        const body = (items: number[], seconds: (number | null)[]) => json({ items, seconds, queue: true });
        expect(MAX_SLIDESHOW_MOTION_SECONDS).toBe(60);
        const over = await L.studio.slideshow(KEY_ID, sid, body([0, 1, 2], [3, null, null])); // 65 s of video
        expect(over.status).toBe(400);
        expect(asBody(over).error.code).toBe("error.webp.too_long");
        const gif = await L.studio.slideshow(KEY_ID, sid, body([1, 2, 3], [null, null, null])); // 75 s
        expect(asBody(gif).error.code).toBe("error.webp.too_long");
        expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);
        const ok = await L.studio.slideshow(KEY_ID, sid, body([0, 1, 3], [3, null, null])); // 45 s
        expect(ok.status).toBe(202);
    });

    it("a HEIC cannot be in a slideshow: a clear error (the container's ffmpeg has no HEIF still decoder)", async () => {
        const L = await lineWorld({ posters: false });
        const { sid } = await saveGallery(L as any, photos(3));
        const rows = itemRows(L as any, sid);
        L.db.raw.prepare("UPDATE media_items SET content_type = 'image/heic' WHERE id = ?").run(rows[1]!.id);
        const r = await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 1], seconds: [3, 3] }));
        expect(r.status).toBe(400);
        expect(asBody(r).error.code).toBe("error.studio.unsupported_image");
        expect((await L.studio.slideshow(KEY_ID, sid, json({ items: [0, 2], seconds: [3, 3] }))).status).toBe(202);
    });
});

describe("nits", () => {
    it("HEIC: saved without asking the helper for a thumb, no poster job is queued, a repeat of the kick never offers it", async () => {
        const w = world();
        await w.addKey();
        w.helper.fetchDone = { contentType: "image/heic", ext: "heic", duration: null, width: 10, height: 10 };
        w.helper.singleThumb = new Uint8Array([0xff, 0xd8, 1, 2]);
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await w.settle(sid);
        expect(w.helper.thumbQueries).toEqual([]);
        expect(w.items()[0]).toMatchObject({ content_type: "image/heic", poster: null });
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("poster:"))).toEqual([]);
        expect(((await w.studio.kickPosters()).body as any).eligible).toBe(0);
    });

    it("a still image the helper refuses a poster for (an animated webp upload) is given up for good, not retried every day", async () => {
        const w = world();
        await w.addKey();
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at, visibility) VALUES ('UploadAnimWebp01','private','upload','originals','uploads/UploadAnimWebp01.webp','a.webp','image/webp',5,?,1000,'private')")
            .run(KEY_ID);
        w.originals.objects.set("uploads/UploadAnimWebp01.webp", { bytes: new Uint8Array(5), contentType: "image/webp", meta: {} });
        w.helper.posterError = { status: 422, code: "error.poster.failed" };
        expect(((await w.studio.kickPosters()).body as any).queued).toBe(1);
        await w.studio.sweep();
        expect(w.items()[0]).toMatchObject({ poster: null });
        w.clock.t += 400 * 24 * 3_600_000; // a year later
        expect(((await w.studio.kickPosters()).body as any)).toMatchObject({ queued: 0, eligible: 0 });
        // a video refused the same way is still tried again after the cooldown (today's rule)
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at, visibility, poster_at) VALUES ('VideoRefused0001','private','upload','originals','uploads/VideoRefused0001.mp4','a.mp4','video/mp4',5,?,1000,'private',?)")
            .run(KEY_ID, w.clock.t - 25 * 3_600_000);
        expect(((await w.studio.kickPosters()).body as any).queued).toBe(1);
    });

    it("a slideshow row is not a webp in the visibility report (it is source 'studio' with a role)", async () => {
        const w = world();
        await w.addKey();
        const { sid } = await saveGallery(w, photos(2));
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, session_id, key_id, created_at, visibility, role, post_key) VALUES ('SlideshowRow0001','private','studio','originals','originals/x-sjob.mp4','v','video/mp4',5,?,?,1,'private','slideshow',?)")
            .run(sid, KEY_ID, sid);
        const m = await migrate(w, "dry_run=1&limit=100");
        expect(m.body.report.webps).toBe(0);
        const undo = await migrate(w, "dry_run=1&undo=1&limit=100");
        expect(undo.body.report.webps_switched).toBe(0);
    });

    it("deleting the lead item moves the session's public link and state with its poster (repointLead)", async () => {
        const w = world();
        await w.addKey();
        const { sid } = await saveGallery(w, photos(3), { public: true });
        const rows = itemRows(w, sid);
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: rows[0]!.url });
        expect((await w.call(`/library/items/${rows[0]!.id}`, { method: "DELETE", headers: auth })).status).toBe(200);
        expect(w.session(sid)).toMatchObject({ r2_key: rows[1]!.r2_key, poster: rows[1]!.poster, public_state: "ready", public_url: rows[1]!.url });
        // a private next lead: the session no longer claims a public link
        await w.call(`/library/items/${rows[1]!.id}/visibility`, { method: "PATCH", headers: { ...auth, "content-type": "application/json" }, body: json({ public: false }) });
        w.db.raw.prepare("UPDATE studio_sessions SET r2_key = ? WHERE id = ?").run(rows[0]!.r2_key, sid); // as if the lead were stale
        await repointLead(w.db, sid);
        expect(w.session(sid)).toMatchObject({ r2_key: rows[1]!.r2_key, public_state: null, public_url: null });
    });

    it("the old web delete: see web/test/library.test.ts (a gallery item moves the lead, the last one is refused)", () => {
        expect(MEDIA_BASE).toMatch(/^https:/);
        void POST;
    });
});
