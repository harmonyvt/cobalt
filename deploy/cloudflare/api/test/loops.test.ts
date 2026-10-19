// Gallery links' moving previews (APP-API-CONTRACT.md section 29): a live link's public videos get a short
// silent animated WebP made by the helper's ordinary webp job, recorded in D1 media_loops and never as a
// library file. The Durable Object's services on the real SQL, the fake helper and the fake buckets.
import { beforeEach, describe, expect, it } from "vitest";
import { KEY_ID_HEADER } from "../src/headers";
import { LOOP_COOLDOWN_MS, LOOP_FPS, LOOP_MAX_ATTEMPTS, LOOP_PREFIX } from "../src/loops";
import { handleStudioRoute } from "../src/studio";
import { MEDIA_BASE, world, type World } from "./poster-world";

let w: World;
const loops = () => w.db.raw.prepare("SELECT * FROM media_loops ORDER BY item_id").all() as any[];
const webps = () => [...w.media.objects.keys()].filter((k) => k.endsWith(".webp"));
const records = async () => [...(await w.kv.list({ prefix: LOOP_PREFIX })).keys()];
let setN = 0;
const link = (ids: string[], revoked: number | null = null) =>
    w.db.raw
        .prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, NULL, 'k', ?, ?)")
        .run(`10000000000000000${String(++setN).padStart(2, "0")}`, JSON.stringify(ids), 1000 + setN, revoked);
// a public video: the saved original with a public mirror
const publicVideo = (over: Record<string, unknown> = {}) => {
    const s = w.seed(over);
    w.db.raw.prepare("UPDATE media_items SET visibility = 'public', public_key = ? WHERE id = ?").run(`ViDeO${s.itemId.slice(-5)}.mp4`, s.itemId);
    return s;
};
const sweepUntilIdle = async (max = 10) => {
    for (let i = 0; i < max; i++) {
        await w.studio.sweep();
        if ((await records()).length === 0) return;
    }
};

beforeEach(() => {
    w = world();
    setN = 0;
});

describe("moving previews", () => {
    it("makes a small silent webp of each public video in a live link, outside the library", async () => {
        const a = publicVideo();
        const b = publicVideo({ width: 360, duration: 2.5 });
        const photo = publicVideo({ content_type: "image/jpeg" });
        const before = w.items().length;
        link([a.itemId, b.itemId, photo.itemId]);
        const k = await w.studio.kickLoops();
        expect(k.body).toMatchObject({ status: "success", queued: 2 });
        await sweepUntilIdle();

        // the helper got each original with the preview's shape
        const qs = w.helper.uploadQueries.map((q) => Object.fromEntries(q));
        expect(qs).toHaveLength(2);
        expect(qs.map((q) => [q.start, q.length, q.width, q.fps, q.quality]).sort()).toEqual(
            [
                ["0", "2.5", "320", String(LOOP_FPS), "low"],
                ["0", "4", "480", String(LOOP_FPS), "low"],
            ].sort(),
        );
        const rows = loops();
        expect(rows.map((r) => r.item_id).sort()).toEqual([a.itemId, b.itemId].sort());
        for (const r of rows) {
            expect(r.url).toBe(`${MEDIA_BASE}${r.r2_key}`);
            expect(r.r2_key).toMatch(/^[A-Za-z0-9]{10}\.webp$/);
            expect(r.bytes).toBe(w.helper.webp.length);
        }
        expect(webps().sort()).toEqual(rows.map((r) => r.r2_key).sort());
        // no library row for a preview
        expect(w.items()).toHaveLength(before);
        // a second kick finds nothing to do
        expect((await w.studio.kickLoops()).body).toMatchObject({ queued: 0 });
    });

    it("skips private, deleted and revoked-link videos", async () => {
        const priv = w.seed();
        const gone = publicVideo();
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(gone.itemId);
        const revoked = publicVideo();
        link([priv.itemId, gone.itemId]);
        link([revoked.itemId], 5);
        expect((await w.studio.kickLoops()).body).toMatchObject({ queued: 0 });
        expect(await records()).toEqual([]);
    });

    it("waits while the helper is busy, without counting an attempt", async () => {
        const a = publicVideo();
        link([a.itemId]);
        await w.studio.kickLoops();
        w.helper.uploadBusy = true;
        await w.studio.sweep();
        await w.studio.sweep();
        expect(loops()).toEqual([]);
        const rec = (await w.kv.get(LOOP_PREFIX + a.itemId)) as any;
        expect(rec).toMatchObject({ attempts: 0, busy: 2 });
        w.helper.uploadBusy = false;
        await sweepUntilIdle();
        expect(loops()[0].url).toMatch(/\.webp$/);
    });

    it("one at a time: a running preview holds the next and the helper", async () => {
        const a = publicVideo();
        const b = publicVideo();
        link([a.itemId, b.itemId]);
        await w.studio.kickLoops();
        w.helper.jobPolls = 3;
        await w.studio.sweep();
        expect(w.helper.uploadQueries).toHaveLength(1);
        await w.studio.sweep();
        expect(w.helper.uploadQueries).toHaveLength(1);
        await sweepUntilIdle();
        expect(w.helper.uploadQueries).toHaveLength(2);
        expect(loops().filter((r) => r.url)).toHaveLength(2);
    });

    it("a file the helper refuses is given up for a day; other failures are retried, then given up", async () => {
        const a = publicVideo();
        link([a.itemId]);
        await w.studio.kickLoops();
        w.helper.jobError = "error.webp.bad_source";
        await sweepUntilIdle();
        expect(loops()).toMatchObject([{ item_id: a.itemId, url: null, tried_at: w.clock.t }]);
        expect((await w.studio.kickLoops()).body).toMatchObject({ queued: 0 });

        w.clock.t += LOOP_COOLDOWN_MS + 1;
        w.helper.jobError = "error.webp.encode_failed";
        expect((await w.studio.kickLoops()).body).toMatchObject({ queued: 1 });
        const before = w.helper.uploadQueries.length;
        await sweepUntilIdle(20);
        expect(w.helper.uploadQueries.length - before).toBe(LOOP_MAX_ATTEMPTS);
        expect(loops()[0]).toMatchObject({ url: null, tried_at: w.clock.t });

        w.clock.t += LOOP_COOLDOWN_MS + 1;
        w.helper.jobError = null;
        await w.studio.kickLoops();
        await sweepUntilIdle();
        expect(loops()[0]).toMatchObject({ tried_at: null });
        expect(loops()[0].url).toMatch(/\.webp$/);
    });

    it("the daily clean removes previews of videos deleted or made private", async () => {
        const a = publicVideo();
        const b = publicVideo();
        const c = publicVideo();
        link([a.itemId, b.itemId, c.itemId]);
        await w.studio.kickLoops();
        await sweepUntilIdle();
        expect(webps()).toHaveLength(3);
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id = ?").run(a.itemId);
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(b.itemId);
        // a plain kick does not clean
        expect((await w.studio.kickLoops()).body).toMatchObject({ removed: 0 });
        expect((await w.studio.kickLoops(50, true)).body).toMatchObject({ removed: 2 });
        expect(loops().map((r) => r.item_id)).toEqual([c.itemId]);
        expect(webps()).toEqual([loops()[0].r2_key]);
    });

    it("the Durable Object route needs the Worker's key id header", async () => {
        const a = publicVideo();
        link([a.itemId]);
        const bare = await handleStudioRoute(w.studio, new Request("https://do.internal/loops/kick", { method: "POST" }));
        expect(bare.status).toBe(403);
        const ok = await handleStudioRoute(
            w.studio,
            new Request("https://do.internal/loops/kick?limit=5&clean=1", { method: "POST", headers: { [KEY_ID_HEADER]: "cron:loops" } }),
        );
        expect(ok.status).toBe(200);
        expect(await ok.json()).toMatchObject({ status: "success", queued: 1, removed: 0 });
    });

    it("without the media_loops table (migration not applied) a kick fails cleanly", async () => {
        w.db.raw.exec("DROP TABLE media_loops");
        const a = publicVideo();
        link([a.itemId]);
        const r = await w.studio.kickLoops();
        expect(r.status).toBe(503);
        expect(await records()).toEqual([]);
    });
});

describe("the queue view", () => {
    it("a preview being made shows as background work, not someone's webp", async () => {
        const a = publicVideo();
        link([a.itemId]);
        await w.studio.kickLoops();
        w.helper.jobPolls = 5;
        await w.studio.sweep();
        expect(w.helper.uploadQueries).toHaveLength(1);
        const r = await w.studio.lineStatus("key-row-1");
        expect((r.body as any).running).toMatchObject({ kind: "poster", mine: false, job: null });
    });
});
