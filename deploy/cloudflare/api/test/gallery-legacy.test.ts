// Lane S0 (APP-API-CONTRACT.md 18.9), the API half: a save from a client that sends NO `items` (the 1.13 share sheet,
// a batch paste, a Shortcut) of a photo-only post. The helper (fake, speaking 18.7) answers what the S0 helper answers
// for that request: a done body with an `items` list and `picker_count`. The Worker, the Durable Object's services
// (the real StudioService and NotifyService) and the real SQL run together. What is proved here: the Durable Object
// already stores N rows whenever the helper's answer has an `items` list, with no change outside the helper.
import { beforeEach, describe, expect, it } from "vitest";
import { NotifyService } from "../src/notify";
import { KEY_ID, LINK, MEDIA_BASE, POSTER_URL, asBody, json, world, type World } from "./poster-world";
import { itemRows, photos } from "./gallery-world";
import { listAll } from "./visibility-fixture";

const HOOK = "https://hark.example/api/webhook/T0pS3cretHookToken";
const X_POST = "https://x.com/ilokineedsleep/status/2106850389551374806";

class FakeHark {
    calls: { title: string; body: string; url?: string }[] = [];
    fetch = async (_url: string, init: RequestInit): Promise<Response> => {
        this.calls.push(JSON.parse(String(init.body)));
        return new Response('{"ok":true}', { status: 200 });
    };
}

let w: World;
let hark: FakeHark;
let studio: ReturnType<World["make"]>;

beforeEach(async () => {
    w = world();
    await w.addKey();
    hark = new FakeHark();
    const notify = new NotifyService({ storage: w.kv, db: w.db, now: w.clock.now, webhookUrl: HOOK, fetch: hark.fetch });
    studio = w.make({ notify });
});

// A save with no `items`, the way an old client asks, and the answer an S0 helper gives it.
async function saveLegacy(specs: ReturnType<typeof photos>, body: Record<string, unknown> = {}) {
    w.helper.gallery = specs;
    w.helper.fetchDone = w.helper.galleryDone("all");
    const r = await studio.create(KEY_ID, json({ url: X_POST, origin: "share", notify: { on: ["saved", "failed"], label: "x · 2106850389551374806" }, ...body }));
    expect(r.status).toBe(201);
    const sid = asBody(r).id as string;
    let done: any;
    for (let i = 0; i < 20; i++) {
        const a = await studio.advance(sid, 0);
        done = asBody(a);
        if (done.status !== "saving") break;
    }
    return { sid, done, created: asBody(r) };
}

describe("a 4-photo post saved with no `items` (the 1.13 share sheet on an X gallery)", () => {
    it("is stored as a gallery: 4 item rows, item_count 4, the lead is the first photo", async () => {
        const { sid, done } = await saveLegacy(photos(4));
        // the request carried no items and no item_count: this is what an old client sends
        expect(w.helper.fetchBodies).toEqual([{ id: sid, url: X_POST }]);
        expect(done).toMatchObject({ status: "ready", item_count: 4, duration: null });
        const rows = itemRows(w, sid);
        expect(rows).toHaveLength(4);
        rows.forEach((r, i) => {
            expect(r).toMatchObject({
                kind: "private",
                source: "saved",
                r2_key: `originals/${sid}-0${i}.jpg`,
                content_type: "image/jpeg",
                role: "item",
                item_index: i,
                post_key: sid,
                session_id: sid,
                duration: null,
            });
            expect(r.poster).toMatch(POSTER_URL);
        });
        expect(w.session(sid)).toMatchObject({ status: "ready", r2_key: `originals/${sid}-00.jpg`, content_type: "image/jpeg", item_count: 4 });
        expect(JSON.parse(w.session(sid).items)).toEqual([0, 1, 2, 3].map((i) => ({ i, type: "photo", status: "ready", code: null })));
        // every file came by its own index, one thumb each
        expect(w.helper.fileQueries).toEqual(["0", "1", "2", "3"]);
        expect(w.helper.thumbQueries).toEqual(["0", "1", "2", "3"]);
        for (let i = 0; i < 4; i++) expect(w.originals.objects.get(`originals/${sid}-0${i}.jpg`)?.contentType).toBe("image/jpeg");
    });

    it("GET /library (no `v`, an old client) lists ONE file, the first photo; v=3 lists the 4 as a gallery", async () => {
        const { sid } = await saveLegacy(photos(4));
        const old = await listAll(w);
        expect(old.posts).toHaveLength(1);
        expect(old.files).toHaveLength(1);
        expect(old.files[0]).toMatchObject({ content_type: "image/jpeg" });
        expect(old.files[0].id).toBe(itemRows(w, sid)[0].id);
        const v3 = await listAll(w, "v=3");
        expect(v3.posts).toHaveLength(1);
        expect(v3.posts[0]).toMatchObject({ kind: "gallery", item_count: 4, items_failed: [] });
        expect(v3.posts[0].files.map((f: any) => f.item_index)).toEqual([0, 1, 2, 3]);
        expect(v3.files).toHaveLength(4);
    });

    it("fires exactly one `saved` notification, with the session's url", async () => {
        const { sid } = await saveLegacy(photos(4));
        expect(hark.calls).toHaveLength(1);
        expect(hark.calls[0].body).toContain("x · 2106850389551374806 is saved");
        expect(hark.calls[0].url).toBe(`cobalt-apple://session/${sid}`);
        // polling a finished session again does not announce it again
        await studio.advance(sid, 0);
        expect(hark.calls).toHaveLength(1);
    });

    it("an item that fails is recorded and the rest are kept; the save is still `ready`", async () => {
        const { sid, done } = await saveLegacy([{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo" }, { type: "photo" }]);
        expect(done.status).toBe("ready");
        expect(done.item_count).toBe(4);
        expect(itemRows(w, sid).map((r) => r.item_index)).toEqual([0, 2, 3]);
        const v3 = await listAll(w, "v=3");
        expect(v3.posts[0]).toMatchObject({ kind: "gallery", item_count: 3, items_failed: [1] });
        expect(hark.calls).toHaveLength(1);
    });
});

describe("everything else from a client that sends no `items` is unchanged", () => {
    it("a plain video (the helper's single-file answer): one row, no role, originals/<sid>.mp4", async () => {
        const r = await studio.create(KEY_ID, json({ url: LINK }));
        const sid = asBody(r).id as string;
        for (let i = 0; i < 20; i++) if (asBody(await studio.advance(sid, 0)).status !== "saving") break;
        expect(w.helper.fetchBodies).toEqual([{ id: sid, url: LINK }]);
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ role: null, item_index: null, post_key: null, r2_key: `originals/${sid}.mp4`, content_type: "video/mp4" });
        expect(w.session(sid).item_count).toBeNull();
        const old = await listAll(w);
        expect(old.files).toHaveLength(1);
    });

    it("a lone photo (the helper's single-file answer, image/jpeg): one row, no role, originals/<sid>.jpg", async () => {
        w.helper.fetchDone = { contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350, picker_count: 1 };
        w.helper.singleThumb = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9]);
        const r = await studio.create(KEY_ID, json({ url: X_POST }));
        const sid = asBody(r).id as string;
        for (let i = 0; i < 20; i++) if (asBody(await studio.advance(sid, 0)).status !== "saving") break;
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ role: null, item_index: null, post_key: null, r2_key: `originals/${sid}.jpg`, content_type: "image/jpeg", duration: null });
        expect(w.items()[0].poster.startsWith(MEDIA_BASE)).toBe(true);
    });
});
