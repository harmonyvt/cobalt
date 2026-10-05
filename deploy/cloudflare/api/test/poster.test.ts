// Server-made posters (APP-API-CONTRACT.md section 13): the queue, the sweep, the recording in
// D1 (original row, session mirror, public copies), the retries, the lazy kick and the
// poster_url every response carries. The Worker, the Durable Object's services and the real SQL
// (node:sqlite over every migration) run together; the helper (its /poster endpoint) and both
// R2 buckets are fakes. The real ffmpeg is in poster-helper.test.ts.
import { beforeEach, describe, expect, it } from "vitest";
import { POSTER_BATCH, POSTER_COOLDOWN_MS, POSTER_MAX_ATTEMPTS, POSTER_PREFIX } from "../src/poster";
import { SERVICE_KEY_ID } from "../src/library";
import { SESSION_TTL_MS, sessionBody, getSession, type SessionRow } from "../src/studio";
import { LINK, KEY_ID, MEDIA_BASE, POSTER_URL, asBody, auth, json, svc, world, type World } from "./poster-world";

const ITEM = "Ab3dE6gH9jK2mN5p";
const ADOPT = { r2_key: `uploads/${ITEM}.mp4`, name: "holiday.mp4", content_type: "video/mp4", bytes: 4096, item_id: ITEM };

const tick = () => new Promise((r) => setTimeout(r, 0));
const until = async (f: () => boolean) => {
    for (let i = 0; i < 200 && !f(); i++) await tick();
    if (!f()) throw new Error("condition never became true");
};
const records = (w: World) => [...w.kv.m.keys()].filter((k) => k.startsWith(POSTER_PREFIX));
const posterCalls = (w: World) => w.helper.calls.filter((c) => c === "POST /poster");

let w: World;
beforeEach(() => {
    w = world();
});

describe("a saved link", () => {
    const save = async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: LINK }))).id as string;
        await w.settle(sid);
        return sid;
    };

    it("is ready without waiting for a poster: only a record is written, ffmpeg is not asked, and the sweep is armed", async () => {
        const sid = await save();
        expect(w.session(sid).status).toBe("ready");
        expect(posterCalls(w)).toEqual([]);
        const itemId = w.items()[0].id;
        expect(w.items()[0]).toMatchObject({ bucket: "originals", source: "saved", poster: null, poster_at: null });
        expect(records(w)).toEqual([`${POSTER_PREFIX}${itemId}`]);
        expect(await w.kv.get(`${POSTER_PREFIX}${itemId}`)).toMatchObject({ attempts: 0 });
        expect(w.sweepsArmed()).toBeGreaterThan(0);
        expect(asBody(await w.studio.advance(sid, 0)).poster_url).toBeNull();
    });

    it("a poster call that never answers cannot delay ready (the poster is never called inside the save)", async () => {
        w.helper.posterGate = new Promise(() => {});
        const sid = await save();
        expect(w.session(sid).status).toBe("ready");
        expect(posterCalls(w)).toEqual([]);
    });

    it("the sweep makes it: the video is streamed to the helper, the JPEG lands in the PUBLIC bucket under an unguessable name, and D1 records it on the original, the session and poster_url", async () => {
        const sid = await save();
        const itemId = w.items()[0].id;
        const pending = await w.studio.sweep();
        expect(pending).toEqual({ pending: 0 });

        expect(w.helper.posterIds).toEqual([itemId]);
        expect(w.helper.posterBytes).toEqual([w.helper.videoBytes.length]); // the stored original, whole
        expect(w.posters()).toHaveLength(1);
        const name = w.posters()[0]!;
        expect(name).toMatch(/^[A-Za-z0-9]{10}\.jpg$/);
        expect(w.media.objects.get(name)).toMatchObject({
            contentType: "image/jpeg",
            cacheControl: "public, max-age=31536000, immutable",
            viaStream: false,
            meta: { poster: "1", itemId },
        });
        expect(w.media.objects.get(name)!.data).toEqual(w.helper.posterJpeg);

        const url = `${MEDIA_BASE}${name}`;
        expect(url).toMatch(POSTER_URL);
        expect(w.items()[0]).toMatchObject({ poster: url, poster_at: w.clock.t });
        expect(w.session(sid).poster).toBe(url);
        expect(records(w)).toEqual([]);
        expect(asBody(await w.studio.advance(sid, 0)).poster_url).toBe(url);
        // nothing else changed about the original
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ kind: "private", source: "saved", deleted_at: null });
    });

    it("a second sweep has nothing to do and never calls the helper again", async () => {
        await save();
        await w.studio.sweep();
        w.helper.calls.length = 0;
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.helper.calls).toEqual([]);
        expect(w.posters()).toHaveLength(1);
    });

    it("the public copy hosted from the original shares its poster (publish copies it; a later poster reaches an earlier copy)", async () => {
        const sid = await save();
        // hosted BEFORE the poster exists: the copy has none yet ...
        await w.addKey();
        const pub = await w.call(`/studio/${sid}/publish`, { method: "POST", headers: auth });
        expect(pub.status).toBe(201);
        const host = () => w.items().find((i) => i.source === "host")!;
        expect(host().poster).toBeNull();
        // ... and gets the original's when it is made
        await w.studio.sweep();
        const url = w.items().find((i) => i.source === "saved")!.poster;
        expect(url).toMatch(POSTER_URL);
        expect(host().poster).toBe(url);
        expect(w.posters()).toHaveLength(1); // one object for both rows
        // hosted AFTER: copied at once
        const again = await w.call(`/studio/${sid}/publish`, { method: "POST", headers: auth });
        expect(again.status).toBe(201);
        const hosts = w.items().filter((i) => i.source === "host");
        expect(hosts).toHaveLength(2);
        expect(hosts.map((h) => h.poster)).toEqual([url, url]);
    });
});

describe("an uploaded video (adopt)", () => {
    const upload = () => {
        w.originals.objects.set(ADOPT.r2_key, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at) VALUES (?, 'private', 'upload', 'originals', ?, 'holiday.mp4', 'video/mp4', 4096, ?, ?)",
            )
            .run(ITEM, ADOPT.r2_key, KEY_ID, w.clock.t);
    };

    it("when the probe makes it ready the upload's row is queued; the sweep fills the row and the adopted session", async () => {
        upload();
        const sid = asBody(await w.studio.adopt(KEY_ID, json(ADOPT))).id as string;
        expect(records(w)).toEqual([]); // not ready yet
        await w.settle(sid);
        expect(records(w)).toEqual([`${POSTER_PREFIX}${ITEM}`]);
        await w.studio.sweep();
        const url = w.item(ITEM).poster;
        expect(url).toMatch(POSTER_URL);
        expect(w.session(sid).poster).toBe(url);
        expect(w.helper.posterIds).toEqual([ITEM]);
        expect(w.helper.posterBytes).toEqual([4096]);
    });

    it("reopening a saved original that already has a poster hands it to the new session at once", async () => {
        const { sid, itemId, r2 } = w.seed();
        w.db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = ?").run(`${MEDIA_BASE}Pstr000001.jpg`, itemId);
        const r = await w.studio.adopt(SERVICE_KEY_ID, json({ ...ADOPT, r2_key: r2, item_id: sid }));
        const reopened = asBody(r).id as string;
        expect(w.session(reopened).poster).toBe(`${MEDIA_BASE}Pstr000001.jpg`);
        await w.settle(reopened);
        expect(records(w)).toEqual([]); // nothing to make
        expect(asBody(await w.studio.advance(reopened, 0)).poster_url).toBe(`${MEDIA_BASE}Pstr000001.jpg`);
    });

    it("a gif gets a poster too", async () => {
        const gif = { ...ADOPT, r2_key: `uploads/${ITEM}.gif`, content_type: "image/gif", name: "loop.gif" };
        w.originals.objects.set(gif.r2_key, { bytes: new Uint8Array(4096).fill(5), contentType: "image/gif", meta: {} });
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at) VALUES (?, 'private', 'upload', 'originals', ?, 'loop.gif', 'image/gif', 4096, ?, ?)",
            )
            .run(ITEM, gif.r2_key, KEY_ID, w.clock.t);
        const sid = asBody(await w.studio.adopt(KEY_ID, json(gif))).id as string;
        await w.settle(sid);
        await w.studio.sweep();
        expect(w.item(ITEM).poster).toMatch(POSTER_URL);
    });
});

describe("the sweep: one job at a time, retries, give-ups", () => {
    let itemId: string;
    beforeEach(() => {
        w.seed();
        itemId = w.items()[0].id;
    });
    const queue = async () => (await w.studio.kickPosters()).body as { queued: number; eligible: number };

    it("makes ONE poster per pass, oldest first, and reports what is still queued", async () => {
        w.seed();
        w.seed();
        expect(await queue()).toMatchObject({ queued: 3, eligible: 3 });
        expect(await w.studio.sweep()).toEqual({ pending: 2 });
        expect(w.posters()).toHaveLength(1);
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.posters()).toHaveLength(3);
        expect(w.items().every((i) => POSTER_URL.test(i.poster))).toBe(true);
        expect(new Set(w.items().map((i) => i.poster)).size).toBe(3);
    });

    it("leaves the helper alone while a save is running, and counts the job as pending", async () => {
        await queue();
        w.kv.m.set("save:other", { phase: "fetching", startedAt: w.clock.t, attempts: 1, lastAdvance: w.clock.t });
        const r = await w.studio.sweep();
        expect(r.pending).toBeGreaterThanOrEqual(1);
        expect(posterCalls(w)).toEqual([]);
        expect(records(w)).toHaveLength(1);
    });

    it("a busy helper (429) is not an attempt: the job stays, and runs when the helper is free", async () => {
        await queue();
        w.helper.posterBusy = 2;
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.kv.get(`${POSTER_PREFIX}${itemId}`)).toMatchObject({ attempts: 0, busy: 2 });
        expect(w.items()[0].poster).toBeNull();
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.items()[0].poster).toMatch(POSTER_URL);
    });

    it("a failing helper (500) is retried, and succeeds on the next pass", async () => {
        await queue();
        w.helper.posterFailures = 2;
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.kv.get(`${POSTER_PREFIX}${itemId}`)).toMatchObject({ attempts: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.items()[0].poster).toMatch(POSTER_URL);
    });

    it(`gives up after ${POSTER_MAX_ATTEMPTS} failed attempts: no poster, poster_at set, the record gone, nothing leaked into the bucket`, async () => {
        await queue();
        w.helper.posterFailures = 99;
        for (let i = 0; i < POSTER_MAX_ATTEMPTS - 1; i++) expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.items()[0]).toMatchObject({ poster: null, poster_at: w.clock.t });
        expect(records(w)).toEqual([]);
        expect(w.posters()).toEqual([]);
        expect(posterCalls(w)).toHaveLength(POSTER_MAX_ATTEMPTS);
    });

    it("a refusal for good (the helper says it is no video: 4xx) gives up at once; the row is not retried for a day, then it is", async () => {
        await queue();
        w.helper.posterError = { status: 400, code: "error.studio.not_video" };
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(posterCalls(w)).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ poster: null, poster_at: w.clock.t });
        // the lazy kick skips it inside the cooldown ...
        expect(await queue()).toEqual({ status: "success", queued: 0, eligible: 0 });
        w.clock.t += POSTER_COOLDOWN_MS - 1;
        expect(await queue()).toMatchObject({ queued: 0, eligible: 0 });
        // ... and tries again after it
        w.clock.t += 2;
        w.helper.posterError = null;
        expect(await queue()).toMatchObject({ queued: 1, eligible: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.items()[0].poster).toMatch(POSTER_URL);
    });

    it("an answer that is not a JPEG is refused for good", async () => {
        await queue();
        w.helper.posterJpeg = Uint8Array.from([1, 2, 3, 4]);
        await w.studio.sweep();
        expect(w.items()[0]).toMatchObject({ poster: null, poster_at: w.clock.t });
        expect(w.posters()).toEqual([]);
    });

    it("a stored video that is gone gives up without calling the helper", async () => {
        await queue();
        w.originals.objects.clear();
        await w.studio.sweep();
        expect(posterCalls(w)).toEqual([]);
        expect(w.items()[0]).toMatchObject({ poster: null, poster_at: w.clock.t });
    });

    it("an unreachable container is retried like any failure", async () => {
        await queue();
        const down = w.make({
            ensureRunning: async () => {
                throw new Error("container down");
            },
        });
        expect(await down.sweep()).toEqual({ pending: 1 });
        expect(await w.kv.get(`${POSTER_PREFIX}${itemId}`)).toMatchObject({ attempts: 1 });
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.items()[0].poster).toMatch(POSTER_URL);
    });

    it("a public bucket that refuses the write is retried, and the failed object is not left behind", async () => {
        await queue();
        w.media.failPut = true;
        expect(await w.studio.sweep()).toEqual({ pending: 1 });
        expect(w.items()[0].poster).toBeNull();
        w.media.failPut = false;
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(w.posters()).toHaveLength(1);
    });

    it("an original deleted while its poster was being made: the new object is removed again and nothing is recorded", async () => {
        await queue();
        let release!: () => void;
        w.helper.posterGate = new Promise<void>((r) => (release = r));
        const running = w.studio.sweep();
        await until(() => w.helper.posterIds.length === 1);
        w.db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(w.clock.t, itemId);
        release();
        await running;
        expect(w.posters()).toEqual([]);
        expect(w.items()[0].poster).toBeNull();
        expect(records(w)).toEqual([]);
    });

    it("rows that are deleted, already postered or not videos are dropped from the queue without a helper call", async () => {
        await queue();
        w.db.raw.prepare("UPDATE media_items SET content_type = 'image/png' WHERE id = ?").run(itemId);
        expect(await w.studio.sweep()).toEqual({ pending: 0 });
        expect(posterCalls(w)).toEqual([]);
        expect(records(w)).toEqual([]);
    });
});

describe("a render, save or upload arriving while a poster is being made waits for it", () => {
    it("render: the poster call finishes first, then the encode starts (the helper never sees both)", async () => {
        const { sid } = w.seed();
        w.seed(); // a second ready session, so a poster job is queued
        await w.studio.kickPosters();
        let release!: () => void;
        w.helper.posterGate = new Promise<void>((r) => (release = r));
        const running = w.studio.sweep();
        await until(() => w.helper.posterIds.length === 1);

        const rendering = w.studio.render(sid, json({ start: 0, length: 2 }));
        await tick();
        await tick();
        expect(w.helper.calls.filter((c) => c === "POST /jobs/upload")).toEqual([]); // still waiting
        release();
        await running;
        const r = await rendering;
        expect(r.status).toBe(202);
        const order = w.helper.calls.filter((c) => c === "POST /poster" || c === "POST /jobs/upload");
        expect(order).toEqual(["POST /poster", "POST /jobs/upload"]);
    });

    it("POST /studio: the same, then the fetch starts", async () => {
        w.seed();
        await w.studio.kickPosters();
        let release!: () => void;
        w.helper.posterGate = new Promise<void>((r) => (release = r));
        const running = w.studio.sweep();
        await until(() => w.helper.posterIds.length === 1);
        const creating = w.studio.create(KEY_ID, json({ url: LINK }));
        await tick();
        await tick();
        expect(w.helper.calls).not.toContain("POST /fetch");
        release();
        await running;
        expect((await creating).status).toBe(201);
        expect(w.helper.calls.filter((c) => c === "POST /poster" || c === "POST /fetch")).toEqual(["POST /poster", "POST /fetch"]);
    });

    it("a poster that never ends does not hold them for ever (posterIdleMs)", async () => {
        const impatient = w.make({ posterIdleMs: 30 });
        w.seed();
        await impatient.kickPosters();
        w.helper.posterGate = new Promise(() => {});
        void impatient.sweep();
        await until(() => w.helper.posterIds.length === 1);
        const t0 = Date.now();
        const created = await impatient.create(KEY_ID, json({ url: LINK }));
        expect(created.status).toBe(201);
        expect(Date.now() - t0).toBeLessThan(15_000); // not the 20 s default, let alone for ever
    });
});

describe("the lazy kick (what backfills the library that existed before posters)", () => {
    it("queues the originals that are videos or gifs and have no poster; skips everything else", async () => {
        w.seed(); // 1 video
        w.seed({ content_type: "image/gif", r2_key: `originals/${"g".repeat(22)}.gif`, id: "g".repeat(22) }); // 2 gif
        const png = w.seed({}, { object: false });
        w.db.raw.prepare("UPDATE media_items SET content_type = 'image/png' WHERE id = ?").run(png.itemId);
        const del = w.seed();
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(del.itemId);
        const have = w.seed();
        w.db.raw.prepare("UPDATE media_items SET poster = 'https://media.capybaraharmony.com/Pstr000001.jpg' WHERE id = ?").run(have.itemId);
        // a public webp and a public hosted mp4 are not originals
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, created_at) VALUES ('WebpItem00000001','public','studio','media','Abcdefghij.webp','u','a.webp','image/webp',1)")
            .run();
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, created_at) VALUES ('HostItem00000001','public','host','media','Hostmp4001.mp4','u','a.mp4','video/mp4',1)")
            .run();

        const r = await w.studio.kickPosters();
        expect(r).toEqual({ status: 200, body: { status: "success", queued: 2, eligible: 2 } });
        expect(records(w)).toHaveLength(2);
        expect(w.sweepsArmed()).toBeGreaterThan(0);
        // again: already queued
        expect(asBody(await w.studio.kickPosters())).toMatchObject({ queued: 0, eligible: 2 });
        // the container is not touched by queueing
        expect(w.helper.calls).toEqual([]);
    });

    it("limit: at most that many are queued (newest first), the rest are counted; the default is the batch size", async () => {
        for (let i = 0; i < 5; i++) {
            w.clock.t += 1000;
            w.seed();
        }
        const newest = w.items()[4]!.id;
        expect(asBody(await w.studio.kickPosters(2))).toMatchObject({ queued: 2, eligible: 5 });
        expect(records(w)).toContain(`${POSTER_PREFIX}${newest}`);
        expect(asBody(await w.studio.kickPosters(100))).toMatchObject({ queued: 3, eligible: 5 });
        expect(POSTER_BATCH).toBe(25);
    });

    it("without the public bucket wired there is nothing to do: 503, no records, and a ready save queues nothing", async () => {
        const bare = world({ media: false });
        bare.seed();
        expect((await bare.studio.kickPosters()).status).toBe(503);
        const sid = asBody(await bare.studio.create(KEY_ID, json({ url: LINK }))).id;
        await bare.settle(sid);
        expect([...bare.kv.m.keys()].filter((k) => k.startsWith(POSTER_PREFIX))).toEqual([]);
        expect(await bare.studio.sweep()).toEqual({ pending: 0 });
    });

    describe("through the Worker", () => {
        beforeEach(async () => {
            await w.addKey();
        });

        it("a library read that shows an original without a poster queues it (one internal call, answered at once); once it has one, no call", async () => {
            const { sid, itemId } = w.seed();
            const read = async () => asBody({ body: await (await w.call("/library", { headers: auth })).json() });
            const b1 = await read();
            expect(b1.posts[0].poster_url).toBeNull();
            expect(w.seen.map((r) => new URL(r.url).pathname)).toEqual(["/posters/kick"]);
            expect(w.seen[0]!.method).toBe("POST");
            expect(records(w)).toEqual([`${POSTER_PREFIX}${itemId}`]);

            await w.studio.sweep();
            w.seen.length = 0;
            const b2 = await read();
            const url = w.item(itemId).poster;
            expect(url).toMatch(POSTER_URL);
            expect(b2.posts[0]).toMatchObject({ id: sid, poster_url: url });
            expect(b2.posts[0].files[0]).toMatchObject({ id: itemId, poster_url: url });
            expect(w.seen).toEqual([]);
        });

        it("a failed attempt inside the cooldown does not make every read kick again", async () => {
            const { itemId } = w.seed();
            w.db.raw.prepare("UPDATE media_items SET poster_at = ? WHERE id = ?").run(w.clock.t, itemId);
            await w.call("/library", { headers: auth });
            expect(w.seen).toEqual([]);
            w.clock.t += POSTER_COOLDOWN_MS + 1;
            await w.call("/library", { headers: auth });
            expect(w.seen).toHaveLength(1);
        });

        it("a Durable Object that fails or hangs never fails (or noticeably delays) the library read", { timeout: 30_000 }, async () => {
            w.seed();
            const { handleRequest } = await import("../src/worker");
            const read = (container: { fetch(r: Request): Promise<Response> }) =>
                handleRequest(new Request("https://api.capybaraharmony.com/library", { headers: auth }), w.env, container, {
                    now: w.clock.now,
                    sleep: w.clock.sleep,
                });
            const failing = await read({ fetch: async () => { throw new Error("DO down"); } });
            expect(failing.status).toBe(200);
            const t0 = Date.now();
            const hanging = await read({ fetch: () => new Promise<Response>(() => {}) });
            expect(hanging.status).toBe(200);
            expect(Date.now() - t0).toBeLessThan(25_000); // bounded at 1.5 s (generous: the machine may be loaded)
        });

        it("POST /library/posters/backfill (keyed, or the service header): queues, answers counts; GET and no key are refused", async () => {
            w.seed();
            w.seed();
            w.seed();
            const post = (path: string, headers: Record<string, string> = auth, method = "POST") => w.call(path, { method, headers });
            const r1 = await post("/library/posters/backfill?limit=2");
            expect(r1.status).toBe(200);
            expect(r1.headers.get("cache-control")).toBe("no-store");
            expect(await r1.json()).toEqual({ status: "success", queued: 2, eligible: 3 });
            const r2 = await post("/library/posters/backfill", svc);
            expect(await r2.json()).toEqual({ status: "success", queued: 1, eligible: 3 });
            expect((await post("/library/posters/backfill", {})).status).toBe(401);
            expect((await post("/library/posters/backfill", auth, "GET")).status).toBe(404);
            expect((await post("/library/posters/backfill", { authorization: "Api-Key nope" })).status).toBe(401);
            // a junk limit falls back to the default instead of failing
            const r3 = await post("/library/posters/backfill?limit=abc");
            expect(r3.status).toBe(200);
            // the DO answers the same kick only from the Worker: no key id header = 403
            const direct = await w.container.fetch(new Request("https://do.internal/posters/kick", { method: "POST" }));
            expect(direct.status).toBe(403);
        });

        it("the public gate answers 404 for the internal path", async () => {
            const res = await w.call("/posters/kick", { method: "POST", headers: auth });
            expect(res.status).toBe(404);
        });
    });
});

describe("poster_url in responses", () => {
    it("GET /studio/<sid> (ready, from D1) and the Durable Object's own reply carry it; saving and error sessions carry null", async () => {
        const { sid, r2 } = w.seed();
        const url = `${MEDIA_BASE}Pstr000001.jpg`;
        w.db.raw.prepare("UPDATE studio_sessions SET poster = ? WHERE id = ?").run(url, sid);
        const res = await w.call(`/studio/${sid}`);
        expect(res.status).toBe(200);
        expect(await res.json()).toMatchObject({ status: "ready", id: sid, poster_url: url, public_state: null, public_url: null });
        expect(asBody(await w.studio.advance(sid, 0)).poster_url).toBe(url);
        expect(r2).toBeTruthy();

        const row = (await getSession(w.db, sid)) as SessionRow;
        expect(sessionBody({ ...row, status: "saving", poster: null }, []).poster_url).toBeNull();
        expect(sessionBody({ ...row, status: "error", poster: null }, []).poster_url).toBeNull();
        // a row from before the migration (no such keys at all) reads as null
        const old = { ...row } as Partial<SessionRow>;
        delete old.poster;
        delete old.public_state;
        delete old.public_url;
        expect(sessionBody(old as SessionRow, [])).toMatchObject({ poster_url: null, public_state: null, public_url: null });
    });

    it("the library's posts and files carry it: the post's is the original's; a webp has none", async () => {
        await w.addKey();
        const { sid, itemId } = w.seed();
        const url = `${MEDIA_BASE}Pstr000001.jpg`;
        w.db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = ?").run(url, itemId);
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, link, session_id, created_at) VALUES ('RenderItem000001','public','studio','media','Abcdefghij.webp',?,'a.webp','image/webp',?,?,?)",
            )
            .run(`${MEDIA_BASE}Abcdefghij.webp`, LINK, sid, w.clock.t + 1);
        const b = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(b.posts).toHaveLength(1);
        expect(b.posts[0].poster_url).toBe(url);
        expect(b.posts[0].files.map((f: any) => [f.id, f.poster_url])).toEqual([
            ["RenderItem000001", null],
            [itemId, url],
        ]);
    });

    it("a post whose original has no poster but whose public copy does shows the copy's", async () => {
        await w.addKey();
        const { sid } = w.seed();
        const url = `${MEDIA_BASE}Pstr000002.jpg`;
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, link, session_id, created_at, poster) VALUES ('HostItem00000001','public','host','media','Hostmp4001.mp4',?,'a.mp4','video/mp4',?,?,?,?)",
            )
            .run(`${MEDIA_BASE}Hostmp4001.mp4`, LINK, sid, w.clock.t + 1, url);
        const b = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(b.posts[0].poster_url).toBe(url);
        expect(b.posts[0].public_url).toBe(`${MEDIA_BASE}Hostmp4001.mp4`);
    });

    it("the upload's item shape has poster_url (null)", async () => {
        await w.addKey();
        const res = await w.call("/studio/upload?name=a.png", {
            method: "PUT",
            headers: { ...auth, "content-type": "image/png", "content-length": "3" },
            body: new Uint8Array(3),
        });
        expect(((await res.json()) as any).item.poster_url).toBeNull();
    });
});

describe("sessions seeded the old way (no new columns set) keep working", () => {
    it("a ready session with a SESSION_TTL left answers 200 and the new fields are null", async () => {
        const { sid } = w.seed();
        const res = await w.call(`/studio/${sid}`);
        const b = (await res.json()) as any;
        expect(b.expires_at - b.created_at).toBe(SESSION_TTL_MS);
        expect(b).toMatchObject({ poster_url: null, public_state: null, public_url: null });
    });
});
