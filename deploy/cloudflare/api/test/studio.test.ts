import { afterEach, describe, expect, it, vi } from "vitest";
import { KEY_ID_HEADER } from "../src/headers";
import { LIVE_PUSH_MS, type LiveHooks } from "../src/live";
import {
    BUSY_RETRY_MS,
    BUSY_WAIT_MS,
    LOCK_STALE_MS,
    SAVE_BUDGET_MS,
    SWEEP_ITEM_MS,
    SWEEP_RENDER_MS,
    SWEEP_SAVE_SLACK_MS,
    SAVING_STUCK_MS,
    SESSION_TTL_MS,
    UNAVAILABLE_AFTER_MS,
    StudioService,
    handleStudioRoute,
    linkFrom,
    listSuccessfulRenders,
    mintSid,
    parseStudioWait,
    sessionBody,
    getSession,
    validateRender,
    type SessionRow,
} from "../src/studio";
import { WebpService } from "../src/webp";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";

const LINK = "https://x.com/maria_rcks/status/2105237035271258436";
const KEY_ID = "key-row-1";
const SID = "aB3dE6gH9jK2mN5pQ8sTuV"; // 22
const MEDIA = "https://media.capybaraharmony.com/";

function setup(scheduleSweep?: () => void | Promise<void>) {
    const db: FakeD1 = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: MEDIA,
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        scheduleSweep,
    });
    const make = (over: Partial<ConstructorParameters<typeof StudioService>[0]> = {}) =>
        new StudioService({
            db,
            storage: kv,
            originals,
            webp,
            webBaseUrl: "https://cobalt.capybaraharmony.com",
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: helper.helper,
            fixedLength,
            scheduleSweep,
            ...over,
        });
    const studio = make();
    const row = (sid: string) => db.raw.prepare("SELECT * FROM studio_sessions WHERE id = ?").get(sid) as any;
    const seed = (over: Partial<SessionRow> = {}, withObject = true) => {
        const r = {
            id: SID,
            key_id: KEY_ID,
            link: LINK,
            service: "x",
            title: "x_2105237035271258436",
            status: "ready",
            error_code: null,
            r2_key: `originals/${SID}.mp4`,
            content_type: "video/mp4",
            bytes: 4096,
            duration: 9.6,
            width: 480,
            height: 560,
            created_at: clock.t,
            expires_at: clock.t + SESSION_TTL_MS,
            ...over,
        };
        db.raw
            .prepare(
                "INSERT INTO studio_sessions (id, key_id, link, service, title, status, error_code, r2_key, content_type, bytes, duration, width, height, created_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            )
            .run(r.id, r.key_id, r.link, r.service, r.title, r.status, r.error_code, r.r2_key, r.content_type, r.bytes, r.duration, r.width, r.height, r.created_at, r.expires_at);
        if (withObject && r.r2_key) {
            originals.objects.set(r.r2_key, { bytes: new Uint8Array(r.bytes ?? 0).fill(7), contentType: "video/mp4", meta: {} });
        }
        return r;
    };
    return { db, clock, kv, originals, media, helper, webp, studio, make, row, seed };
}

const body = (o: unknown) => JSON.stringify(o);
const create = (s: ReturnType<typeof setup>, url: unknown = LINK) => s.studio.create(KEY_ID, body({ url }));

describe("helpers", () => {
    it("mintSid is 22 base62 chars", () => {
        expect(mintSid()).toMatch(/^[A-Za-z0-9]{22}$/);
        expect(mintSid()).not.toBe(mintSid());
    });
    it("linkFrom accepts one clean http(s) link only", () => {
        expect(linkFrom(LINK)).toBe(LINK);
        expect(linkFrom(`  ${LINK}  `)).toBe(LINK);
        for (const bad of ["", "nope", "ftp://a.test/x", "https://a.test/a b", "https://" + "a".repeat(2050), 5, null, undefined, "javascript:alert(1)"]) {
            expect(linkFrom(bad)).toBeNull();
        }
    });
    it("parseStudioWait: absent or junk = 0, clamped to 25", () => {
        expect(parseStudioWait(null)).toBe(0);
        expect(parseStudioWait("")).toBe(0);
        expect(parseStudioWait("abc")).toBe(0);
        expect(parseStudioWait("10")).toBe(10);
        expect(parseStudioWait("99")).toBe(25);
        expect(parseStudioWait("-3")).toBe(0);
    });
});

type Setup = ReturnType<typeof setup>;
const SAVING_NULLS = { r2_key: null, content_type: null, bytes: null, duration: null, width: null, height: null, title: null };
const asBody = (r: { body: unknown }) => r.body as any;

// A helper whose /fetch/<id>/file answer is held until release() (the upload
// window of a save), for the concurrency tests.
function gatedFile(s: Setup) {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    let reached!: () => void;
    const atFile = new Promise<void>((r) => (reached = r));
    const helper = async (path: string, init?: RequestInit) => {
        if (/^\/fetch\/[A-Za-z0-9]+\/file$/.test(path)) {
            reached();
            await gate;
        }
        return s.helper.helper(path, init);
    };
    return { helper, release, atFile };
}

describe("POST /studio (create)", () => {
    it("answers 201 with the studio URL and a saving row; the helper has accepted the fetch", async () => {
        const s = setup();
        const res = await create(s);
        expect(res.status).toBe(201);
        const b = res.body as { status: string; id: string; url: string };
        expect(b.status).toBe("success");
        expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
        expect(b.url).toBe(`https://cobalt.capybaraharmony.com/studio/${b.id}`);
        expect(s.row(b.id)).toMatchObject({ status: "saving", key_id: KEY_ID, link: LINK, service: "x" });
        expect(s.row(b.id).expires_at - s.row(b.id).created_at).toBe(SESSION_TTL_MS);
        expect(await s.kv.get(`save:${b.id}`)).toMatchObject({ phase: "fetching", attempts: 1, startedAt: s.clock.t, lastAdvance: s.clock.t });
        expect(s.helper.calls).toEqual(["POST /fetch"]);
        expect(s.helper.fetchBodies).toEqual([{ id: b.id, url: LINK }]);
    });

    it("nothing runs after the response: without a poll the save does not move", async () => {
        const s = setup();
        const { id } = asBody(await create(s));
        await new Promise((r) => setTimeout(r, 20));
        s.clock.t += 60_000;
        expect(s.helper.calls).toEqual(["POST /fetch"]);
        expect(s.row(id).status).toBe("saving");
        expect(s.originals.objects.size).toBe(0);
    });

    it("does not hold the 201 for a helper that will not answer (KICK_MS)", async () => {
        const s = setup();
        const st = s.make({
            kickMs: 15,
            helperTimeoutMs: 30,
            helper: (path, init) => (path === "/fetch" ? new Promise<Response>(() => {}) : s.helper.helper(path, init)),
        });
        const res = await st.create(KEY_ID, body({ url: LINK }));
        expect(res.status).toBe(201);
        const { id } = asBody(res);
        expect(s.row(id).status).toBe("saving");
        // The hung kick holds no lock and a hung helper call times out: a poll
        // answers promptly (it used to wait on the kick forever, live 2026-10-01).
        const t0 = Date.now();
        expect(asBody(await st.advance(id, 0)).status).toBe("saving");
        expect(Date.now() - t0).toBeLessThan(2000);
    });

    it("an unreachable container at creation still answers 201", async () => {
        const s = setup();
        s.helper.unreachable = true;
        const res = await create(s);
        expect(res.status).toBe(201);
        expect(s.row(asBody(res).id).status).toBe("saving");
    });

    it.each([
        ["no url", {}],
        ["empty", { url: "" }],
        ["free text", { url: "look at this" }],
        ["ftp", { url: "ftp://a.test/x" }],
        ["number", { url: 5 }],
    ])("400 error.studio.no_link for %s, and no row", async (_n, b) => {
        const s = setup();
        const res = await s.studio.create(KEY_ID, body(b));
        expect(res).toEqual({ status: 400, body: { status: "error", error: { code: "error.studio.no_link" } } });
        expect(s.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        expect(s.helper.calls).toEqual([]);
    });
    it("400 no_link for a body that is not JSON or is too large", async () => {
        const s = setup();
        expect((await s.studio.create(KEY_ID, "not json")).status).toBe(400);
        expect((await s.studio.create(KEY_ID, body({ url: LINK, pad: "x".repeat(9000) }))).status).toBe(400);
    });

    it("429 error.studio.busy while another save is in flight, fine once it is done", async () => {
        const s = setup();
        const { id } = asBody(await create(s));
        const second = await create(s);
        expect(second).toEqual({ status: 429, body: { status: "error", error: { code: "error.studio.busy" } } });
        expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready");
        expect((await create(s)).status).toBe(201);
    });
    it("a save nobody has polled for 10 minutes no longer blocks: it is failed (save_lost) first", async () => {
        const s = setup();
        const { id } = asBody(await create(s));
        s.clock.t += SAVING_STUCK_MS - 1;
        expect((await create(s)).status).toBe(429);
        s.clock.t += 2;
        expect((await create(s)).status).toBe(201);
        expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.studio.save_lost" });
        expect(s.helper.calls).toContain(`DELETE /fetch/${id}`);
        expect(await s.kv.get(`save:${id}`)).toBeUndefined();
    });
    it("429 busy while an encode this DO started is still assumed running", async () => {
        const s = setup();
        s.seed();
        s.helper.jobPolls = 1e9;
        expect((await s.studio.render(SID, body({ start: 0, length: 2 }))).status).toBe(202);
        expect((await create(s)).status).toBe(429);
        // ...but not forever: a client that never polled does not block saves
        s.clock.t += 6 * 60_000;
        expect((await create(s)).status).toBe(201);
    });
});

describe("GET /studio/<sid>/advance (the poll-driven save)", () => {
    it("moves the save forward across polls and ends ready with the video in R2, stored as a stream", async () => {
        const s = setup();
        s.helper.fetchPolls = 2;
        const { id } = asBody(await create(s));

        // poll 1 and 2: the helper is still downloading
        for (let i = 0; i < 2; i++) {
            const r = await s.studio.advance(id, 0);
            expect(r.status).toBe(200);
            expect(asBody(r)).toMatchObject({ status: "saving", id, title: null, bytes: null, renders: [] });
            expect(s.originals.objects.size).toBe(0);
        }
        // poll 3: the helper has it, it is copied into R2 during this very request
        const done = await s.studio.advance(id, 0);
        expect(asBody(done)).toMatchObject({ status: "ready", id, bytes: 4096, duration: 9.6, width: 480, height: 560, title: "x_2105237035271258436", error: null });
        expect(s.row(id)).toMatchObject({
            status: "ready",
            error_code: null,
            r2_key: `originals/${id}.mp4`,
            content_type: "video/mp4",
            bytes: 4096,
        });
        const obj = s.originals.objects.get(`originals/${id}.mp4`)!;
        expect(obj.bytes).toEqual(s.helper.videoBytes);
        expect(obj.meta).toMatchObject({ keyId: KEY_ID, source: LINK, sessionId: id });
        expect(s.originals.putValueTypes).toEqual(["ReadableStream"]); // never a buffer
        expect(s.helper.calls).toEqual([
            "POST /fetch",
            `GET /fetch/${id}`,
            `GET /fetch/${id}`,
            `GET /fetch/${id}`,
            `GET /fetch/${id}/file`,
            `DELETE /fetch/${id}`,
        ]);
        expect(await s.kv.list({ prefix: "save:" })).toEqual(new Map());
        // later polls answer from D1 and never touch the helper
        const n = s.helper.calls.length;
        expect(asBody(await s.studio.advance(id, 5)).status).toBe("ready");
        expect(s.helper.calls.length).toBe(n);
    });

    it("the record moves starting -> fetching, refreshes lastAdvance on every poll, and is dropped when done", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        s.helper.busyFetchStarts = 1; // the kick-off is refused: still "starting"
        const { id } = asBody(await create(s));
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "starting", attempts: 0, busySince: s.clock.t });
        s.clock.t += 3000;
        await s.studio.advance(id, 0); // accepted now
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "fetching", attempts: 1, lastAdvance: s.clock.t });
        s.clock.t += 3000;
        await s.studio.advance(id, 0); // still pending
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "fetching", lastAdvance: s.clock.t });
        await s.studio.advance(id, 0); // done
        expect(await s.kv.get(`save:${id}`)).toBeUndefined();
    });

    it("waits (long-polls) through pending polls within one request", async () => {
        const s = setup();
        s.helper.fetchPolls = 4;
        const { id } = asBody(await create(s));
        const t0 = s.clock.t;
        expect(asBody(await s.studio.advance(id, 20)).status).toBe("ready");
        expect(s.clock.t - t0).toBeGreaterThanOrEqual(4000);
        expect(s.clock.t - t0).toBeLessThan(20_000);
    });
    it("a wait that runs out answers saving; without wait it answers at once", async () => {
        const s = setup();
        s.helper.fetchPolls = 1e9;
        const { id } = asBody(await create(s));
        const t0 = s.clock.t;
        expect(asBody(await s.studio.advance(id, 3)).status).toBe("saving");
        expect(s.clock.t - t0).toBe(3000);
        const t1 = s.clock.t;
        expect(asBody(await s.studio.advance(id, 0)).status).toBe("saving");
        expect(s.clock.t).toBe(t1);
    });

    it("uses the extension and content type the helper reports; anything odd falls back to mp4", async () => {
        const s = setup();
        s.helper.fetchDone = { ext: "webm", contentType: "video/webm" };
        const { id } = asBody(await create(s));
        await s.studio.advance(id, 30);
        expect(s.row(id)).toMatchObject({ r2_key: `originals/${id}.webm`, content_type: "video/webm" });
        const t = setup();
        t.helper.fetchDone = { ext: "../../x", contentType: "text/html", title: "   " };
        const { id: id2 } = asBody(await create(t));
        await t.studio.advance(id2, 30);
        expect(t.row(id2)).toMatchObject({ r2_key: `originals/${id2}.mp4`, content_type: "video/mp4", title: null });
    });

    it("a GIF the helper labels image/gif is stored as one (originals/<sid>.gif), not forced to video/mp4", async () => {
        const s = setup();
        s.helper.fetchDone = { ext: "gif", contentType: "image/gif" };
        const { id } = asBody(await create(s));
        await s.studio.advance(id, 30);
        expect(s.row(id)).toMatchObject({ r2_key: `originals/${id}.gif`, content_type: "image/gif" });
    });

    it("404 unknown, 410 expired; ready and errored sessions are answered from D1", async () => {
        const s = setup();
        expect(await s.studio.advance(SID, 0)).toEqual({ status: 404, body: { status: "error", error: { code: "error.studio.not_found" } } });
        s.seed();
        expect(asBody(await s.studio.advance(SID, 0))).toMatchObject({ status: "ready", id: SID, renders: [] });
        s.db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.api.fetch.fail'").run();
        expect(asBody(await s.studio.advance(SID, 0))).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
        s.clock.t += SESSION_TTL_MS + 1;
        expect((await s.studio.advance(SID, 0)).status).toBe(410);
        expect(s.helper.calls).toEqual([]);
    });

    describe("a container restart loses the helper's fetch", () => {
        it("is started again, and the save finishes", async () => {
            const s = setup();
            s.helper.fetchLosses = 1;
            const { id } = asBody(await create(s));
            expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready");
            expect(s.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(2);
            expect(s.originals.objects.get(`originals/${id}.mp4`)!.bytes).toEqual(s.helper.videoBytes);
        });
        it("two restarts are survived too (3 attempts in all)", async () => {
            const s = setup();
            s.helper.fetchLosses = 2;
            const { id } = asBody(await create(s));
            expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready");
            expect(s.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(3);
        });
        it("a third loss is error.studio.save_lost", async () => {
            const s = setup();
            s.helper.fetchLosses = 3;
            const { id } = asBody(await create(s));
            const r = await s.studio.advance(id, 30);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.studio.save_lost" } });
            expect(s.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(3);
            expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.studio.save_lost" });
            expect(await s.kv.get(`save:${id}`)).toBeUndefined();
        });
        it("a helper that keeps forgetting is save_lost as well", async () => {
            const s = setup();
            s.helper.fetchGone = true;
            const { id } = asBody(await create(s));
            expect(asBody(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.studio.save_lost" } });
        });
    });

    describe("failures set the row to error and are answered as such", () => {
        const failing = async (tweak: (s: Setup) => void, code: string, wait = 60) => {
            const s = setup();
            tweak(s);
            const { id } = asBody(await create(s));
            const r = await s.studio.advance(id, wait);
            expect(asBody(r)).toMatchObject({ status: "error", id, error: { code } });
            expect(s.row(id)).toMatchObject({ status: "error", error_code: code, r2_key: null });
            expect(await s.kv.list({ prefix: "save:" })).toEqual(new Map());
            // and it stays that way
            expect(asBody(await s.studio.advance(id, 0)).status).toBe("error");
            return s;
        };
        it("passes cobalt's code through and drops the helper copy", async () => {
            const s = await failing((x) => (x.helper.fetchError = "error.api.fetch.fail"), "error.api.fetch.fail");
            expect(s.helper.calls.some((c) => c.startsWith("DELETE /fetch/"))).toBe(true);
        });
        it("too_large from the helper", async () => {
            await failing((x) => (x.helper.fetchError = "error.studio.too_large"), "error.studio.too_large");
        });
        it("a helper file over 200 MB is too_large even if it slipped through", async () => {
            await failing((x) => (x.helper.fetchDone = { bytes: 201 * 1024 * 1024 }), "error.studio.too_large");
        });
        it("R2 refusing the write is error.studio.storage", async () => {
            await failing((x) => (x.originals.failPut = true), "error.studio.storage");
        });
        it("a file whose length differs from what the helper reported is error.studio.storage", async () => {
            const s = await failing((x) => (x.helper.fetchFileLength = 10), "error.studio.storage");
            expect(s.originals.objects.size).toBe(0);
        });
        it("a container that stops answering is error.studio.unavailable after 30 s of trying", async () => {
            const s = setup();
            const { id } = asBody(await create(s));
            s.helper.unreachable = true;
            const t0 = s.clock.t;
            expect(asBody(await s.studio.advance(id, 10)).status).toBe("saving"); // not yet
            const r = await s.studio.advance(id, 60);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.studio.unavailable" } });
            expect(s.clock.t - t0).toBeGreaterThanOrEqual(UNAVAILABLE_AFTER_MS);
            expect(s.clock.t - t0).toBeLessThan(UNAVAILABLE_AFTER_MS + 5000);
        });
        it("a container that will not start is error.studio.unavailable", async () => {
            const s = setup();
            const st = s.make({
                ensureRunning: async () => {
                    throw new Error("no start");
                },
            });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            expect(asBody(await st.advance(id, 60))).toMatchObject({ status: "error", error: { code: "error.studio.unavailable" } });
        });
        it("a container that comes back within 30 s costs nothing", async () => {
            const s = setup();
            const { id } = asBody(await create(s));
            s.helper.unreachable = true;
            expect(asBody(await s.studio.advance(id, 5)).status).toBe("saving");
            s.helper.unreachable = false;
            s.helper.fetchLosses = 1; // it came back without the fetch
            expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready");
        });
        it("a helper download that never finishes times out (error.webp.timeout)", async () => {
            await failing((x) => (x.helper.fetchPolls = 1e9), "error.webp.timeout", 900);
        });
    });

    describe("the helper does one job at a time", () => {
        it("a busy helper keeps the session saving and is retried on the next advance", async () => {
            const s = setup();
            s.helper.busyFetchStarts = 3;
            const { id } = asBody(await create(s)); // kick-off refused
            expect(s.row(id).status).toBe("saving");
            expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "starting", attempts: 0 });
            s.clock.t += 2000;
            expect(asBody(await s.studio.advance(id, 0)).status).toBe("saving"); // refused again
            s.clock.t += 2000;
            expect(asBody(await s.studio.advance(id, 0)).status).toBe("saving"); // and again
            s.clock.t += 2000;
            expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready"); // accepted
            expect(s.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(4);
        });
        it("a long wait retries every 2 s inside one request", async () => {
            const s = setup();
            s.helper.busyFetchStarts = 5;
            const { id } = asBody(await create(s));
            const t0 = s.clock.t;
            expect(asBody(await s.studio.advance(id, 25)).status).toBe("ready");
            expect(s.clock.t - t0).toBeGreaterThanOrEqual(4 * BUSY_RETRY_MS);
        });
        it("still busy after two minutes is error.studio.busy", async () => {
            const s = setup();
            s.helper.busyFetchStarts = 1e9;
            const { id } = asBody(await create(s));
            const t0 = s.clock.t;
            expect(asBody(await s.studio.advance(id, 119)).status).toBe("saving");
            const r = await s.studio.advance(id, 30);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.studio.busy" } });
            expect(s.clock.t - t0).toBeGreaterThanOrEqual(BUSY_WAIT_MS);
            expect(s.clock.t - t0).toBeLessThan(BUSY_WAIT_MS + 5000);
        });
        it("a 429 for a fetch the helper already has (a lost accept) is not busy", async () => {
            const s = setup();
            s.helper.busyFetchStarts = 1;
            const { id } = asBody(await create(s));
            s.helper.fetchStarted.add(id); // the helper did accept it after all
            s.helper.busyFetchStarts = 1; // a duplicate POST is answered 429
            await s.studio.advance(id, 0);
            expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "fetching", attempts: 1 });
            expect(asBody(await s.studio.advance(id, 30)).status).toBe("ready");
        });
    });

    describe("two polls of the same session", () => {
        it("never advance it at once: the second waits for the first and reads D1", async () => {
            const s = setup();
            const g = gatedFile(s);
            const st = s.make({ helper: g.helper });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            const first = st.advance(id, 0); // gets to the file copy and holds there
            await g.atFile;
            const before = s.helper.calls.length;
            // a second poll, with and without a wait: no helper call, answers saving
            expect(asBody(await st.advance(id, 0)).status).toBe("saving");
            expect(asBody(await st.advance(id, 4)).status).toBe("saving");
            expect(s.helper.calls.length).toBe(before);
            g.release();
            expect(asBody(await first).status).toBe("ready");
            expect(s.helper.calls.filter((c) => c === `GET /fetch/${id}/file`)).toHaveLength(1);
            expect(s.originals.objects.size).toBe(1);
            expect(s.helper.calls.filter((c) => c === `GET /fetch/${id}`)).toHaveLength(1);
        });
        it("a second poll with a wait returns the finished session once the first is done", async () => {
            const s = setup();
            const g = gatedFile(s);
            let slices = 0;
            const st = s.make({
                helper: g.helper,
                sleep: async (ms) => {
                    await s.clock.sleep(ms);
                    if (++slices === 3) g.release(); // the copy finishes while the second poll waits
                    await new Promise((r) => setTimeout(r, 5));
                },
            });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            const first = st.advance(id, 0);
            await g.atFile;
            const second = await st.advance(id, 25);
            expect(asBody(second).status).toBe("ready");
            expect(asBody(await first).status).toBe("ready");
            expect(s.helper.calls.filter((c) => c === `GET /fetch/${id}/file`)).toHaveLength(1);
            expect(slices).toBeGreaterThanOrEqual(3);
        });
        it("a late finish after the row was failed does not resurrect it and drops the object", async () => {
            const s = setup();
            const g = gatedFile(s);
            const st = s.make({ helper: g.helper });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            const first = st.advance(id, 0);
            await g.atFile;
            s.db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.studio.save_lost' WHERE id=?").run(id);
            g.release();
            expect(asBody(await first)).toMatchObject({ status: "error", error: { code: "error.studio.save_lost" } });
            expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.studio.save_lost", r2_key: null });
            expect(s.originals.objects.size).toBe(0);
        });
    });

    describe("nobody polling: measured from the last advance attempt, not from creation", () => {
        const record = (s: Setup, lastAdvance: number, over: Record<string, unknown> = {}) =>
            s.kv.put(`save:${SID}`, { phase: "starting", startedAt: lastAdvance, attempts: 0, lastAdvance, ...over });

        it("a save last advanced 9 minutes ago survives even though the session is much older", async () => {
            const s = setup();
            s.seed({ status: "saving", created_at: s.clock.t - 30 * 60_000, expires_at: s.clock.t + SESSION_TTL_MS, ...SAVING_NULLS }, false);
            await record(s, s.clock.t - 9 * 60_000);
            expect(asBody(await s.studio.advance(SID, 30)).status).toBe("ready");
        });
        it("a save last advanced more than 10 minutes ago is save_lost, and the helper copy is dropped", async () => {
            const s = setup();
            s.seed({ status: "saving", ...SAVING_NULLS }, false);
            await record(s, s.clock.t - SAVING_STUCK_MS - 1);
            const r = await s.studio.advance(SID, 5);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.studio.save_lost" } });
            expect(s.row(SID)).toMatchObject({ status: "error", error_code: "error.studio.save_lost" });
            expect(s.helper.calls).toEqual([`DELETE /fetch/${SID}`]);
            expect(await s.kv.get(`save:${SID}`)).toBeUndefined();
        });
        it("exactly 10 minutes is still alive", async () => {
            const s = setup();
            s.seed({ status: "saving", ...SAVING_NULLS }, false);
            await record(s, s.clock.t - SAVING_STUCK_MS);
            expect(asBody(await s.studio.advance(SID, 30)).status).toBe("ready");
        });
        it("no record (DO storage lost, or a session from before this scheme): the row's age decides", async () => {
            const s = setup();
            s.seed({ status: "saving", created_at: s.clock.t - 60_000, ...SAVING_NULLS }, false);
            expect(asBody(await s.studio.advance(SID, 30)).status).toBe("ready"); // started from the row
            const t = setup();
            t.seed({ status: "saving", created_at: t.clock.t - SAVING_STUCK_MS - 1, ...SAVING_NULLS }, false);
            expect(asBody(await t.studio.advance(SID, 30))).toMatchObject({ status: "error", error: { code: "error.studio.save_lost" } });
        });
        it("an old-format record ({createdAt} only) is read as starting", async () => {
            const s = setup();
            s.seed({ status: "saving", ...SAVING_NULLS }, false);
            await s.kv.put(`save:${SID}`, { createdAt: s.clock.t });
            expect(asBody(await s.studio.advance(SID, 30)).status).toBe("ready");
        });
        it("reapOrphans fails what nobody advanced for 10 minutes, leaves fresh saves alone", async () => {
            const s = setup();
            s.seed({ status: "saving", ...SAVING_NULLS }, false);
            await record(s, s.clock.t - SAVING_STUCK_MS - 1);
            const fresh = await create(s); // 429 busy? no: reaping ran first
            expect(fresh.status).toBe(201);
            expect(s.row(SID)).toMatchObject({ status: "error", error_code: "error.studio.save_lost" });
            const { id } = asBody(fresh);
            await s.studio.reapOrphans();
            expect(s.row(id).status).toBe("saving");
            expect(await s.kv.get(`save:${id}`)).toBeDefined();
        });
    });
});

describe("validateRender", () => {
    const src: { duration: number | null; width: number | null } = { duration: 9.6, width: 480 };
    const ok = (b: unknown, source = src) => {
        const r = validateRender(b, source);
        if (!r.ok) throw new Error(`rejected: ${r.code}`);
        return r.params;
    };
    const code = (b: unknown, source = src) => {
        const r = validateRender(b, source);
        return r.ok ? "ok" : r.code;
    };

    it("fills the defaults: width 480, quality med", () => {
        expect(ok({ start: 2, length: 5 })).toEqual({ start: 2, length: 5, width: 480, quality: "med", effectiveWidth: 480 });
    });
    it("accepts numeric strings and every option", () => {
        expect(ok({ start: "1.5", length: "3", width: "320", quality: "high" })).toMatchObject({ start: 1.5, length: 3, width: 320, quality: "high", effectiveWidth: 320 });
        expect(ok({ start: 0, length: 0.5, width: null, quality: "" })).toMatchObject({ width: 480, quality: "med" });
    });
    it("length: 0.5 to 10 seconds; over is too_long, under or junk is invalid_params", () => {
        expect(code({ start: 0, length: 0.5 })).toBe("ok");
        expect(code({ start: 0, length: 0.49 })).toBe("error.webp.invalid_params");
        expect(code({ start: 0, length: 0 })).toBe("error.webp.invalid_params");
        expect(code({ start: 0, length: -1 })).toBe("error.webp.invalid_params");
        expect(code({ start: 0, length: 10 }, { duration: 60, width: 480 })).toBe("ok");
        expect(code({ start: 0, length: 10.01 }, { duration: 60, width: 480 })).toBe("error.webp.too_long");
        expect(code({ start: 0, length: 300 })).toBe("error.webp.too_long");
        expect(code({ start: 0, length: "abc" })).toBe("error.webp.invalid_params");
        expect(code({ start: 0, length: Infinity })).toBe("error.webp.invalid_params");
    });
    it("start: required, >= 0", () => {
        expect(code({ length: 2 })).toBe("error.webp.invalid_params");
        expect(code({ start: null, length: 2 })).toBe("error.webp.invalid_params");
        expect(code({ start: -0.1, length: 2 })).toBe("error.webp.invalid_params");
        expect(code({ start: "x", length: 2 })).toBe("error.webp.invalid_params");
        expect(code({ start: 0, length: 2 })).toBe("ok");
    });
    it("start + length must fit the duration plus 0.05 s", () => {
        expect(code({ start: 4.6, length: 5 })).toBe("ok"); // ends at 9.6
        expect(code({ start: 4.65, length: 5 })).toBe("ok"); // 9.65 = duration + 0.05
        expect(code({ start: 4.66, length: 5 })).toBe("error.webp.invalid_params");
        expect(code({ start: 20, length: 1 })).toBe("error.webp.invalid_params");
    });
    it("an unknown duration is not checked", () => {
        expect(code({ start: 100, length: 5 }, { duration: null, width: 480 })).toBe("ok");
    });
    it("width is 320 or 480 only", () => {
        for (const w of [640, 100, 500, "big", 0, true]) expect(code({ start: 0, length: 2, width: w })).toBe("error.webp.invalid_params");
    });
    it("recorded width is never above the source's", () => {
        expect(ok({ start: 0, length: 2, width: 480 }, { duration: 9, width: 300 }).effectiveWidth).toBe(300);
        expect(ok({ start: 0, length: 2, width: 320 }, { duration: 9, width: 300 }).effectiveWidth).toBe(300);
        expect(ok({ start: 0, length: 2, width: 320 }, { duration: 9, width: 1080 }).effectiveWidth).toBe(320);
        expect(ok({ start: 0, length: 2 }, { duration: 9, width: null }).effectiveWidth).toBe(480);
    });
    it("quality is low, med or high", () => {
        for (const q of ["ultra", 70, "HIGH", true]) expect(code({ start: 0, length: 2, quality: q })).toBe("error.webp.invalid_params");
    });
    it.each([[null], ["x"], [[]], [5]])("a non-object body %j is invalid", (b) => {
        expect(code(b)).toBe("error.webp.invalid_params");
    });
});

describe("POST /studio/<sid>/render", () => {
    it("streams the stored original into the helper and answers 202", async () => {
        const s = setup();
        s.seed();
        const res = await s.studio.render(SID, body({ start: 2, length: 5, width: 320, quality: "high" }));
        expect(res.status).toBe(202);
        const job = (res.body as { status: string; job: string }).job;
        expect((res.body as { status: string }).status).toBe("pending");
        expect(job).toMatch(/^[A-Za-z0-9]{20}$/);
        // the whole original went into the helper, once, as a stream
        expect(s.helper.uploadedBytes).toEqual([4096]);
        const q = s.helper.uploadQueries[0];
        expect(Object.fromEntries(q)).toEqual({ id: job, start: "2", length: "5", width: "320", fps: "15", quality: "high" });
        expect(s.db.raw.prepare("SELECT * FROM studio_renders WHERE id = ?").get(job)).toMatchObject({
            session_id: SID,
            status: "pending",
            start: 2,
            length: 5,
            width: 320,
            quality: "high",
            created_at: s.clock.t,
        });
        expect(s.helper.calls).toEqual(["POST /jobs/upload"]);
    });

    it("records the width capped at the source width but asks the helper for the requested one", async () => {
        const s = setup();
        s.seed({ width: 300 });
        const res = await s.studio.render(SID, body({ start: 0, length: 2 }));
        const job = (res.body as { job: string }).job;
        expect(s.helper.uploadQueries[0].get("width")).toBe("480");
        expect(s.db.raw.prepare("SELECT width FROM studio_renders WHERE id = ?").get(job)).toEqual({ width: 300 });
    });

    it("state checks come first: 404, 410, 409", async () => {
        const s = setup();
        const ask = () => s.studio.render(SID, body({ start: 0, length: 2 }));
        expect(await ask()).toEqual({ status: 404, body: { status: "error", error: { code: "error.studio.not_found" } } });
        s.seed({ status: "saving", r2_key: null });
        expect(await ask()).toEqual({ status: 409, body: { status: "error", error: { code: "error.studio.not_ready" } } });
        s.db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.api.fetch.fail'").run();
        expect((await ask()).status).toBe(409);
        s.db.raw.prepare("UPDATE studio_sessions SET status='ready', r2_key=?").run(`originals/${SID}.mp4`);
        s.clock.t += SESSION_TTL_MS + 1;
        expect(await ask()).toEqual({ status: 410, body: { status: "error", error: { code: "error.studio.expired" } } });
        expect(s.helper.calls).toEqual([]); // never woke the helper
    });

    it("expiry is strict: at expires_at exactly it still works", async () => {
        const s = setup();
        s.seed();
        s.clock.t += SESSION_TTL_MS;
        expect((await s.studio.render(SID, body({ start: 0, length: 2 }))).status).toBe(202);
    });

    it.each([
        ["not json", "{"],
        ["too big", body({ start: 0, length: 2, pad: "x".repeat(9000) })],
        ["no start", body({ length: 2 })],
        ["length 0.4", body({ start: 0, length: 0.4 })],
        ["past the end", body({ start: 9, length: 2 })],
        ["width 640", body({ start: 0, length: 2, width: 640 })],
        ["quality max", body({ start: 0, length: 2, quality: "max" })],
    ])("400 error.webp.invalid_params: %s, nothing is started", async (_n, raw) => {
        const s = setup();
        s.seed();
        const res = await s.studio.render(SID, raw);
        expect(res).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        expect(s.helper.calls).toEqual([]);
        expect(s.db.raw.prepare("SELECT count(*) AS n FROM studio_renders").get()).toEqual({ n: 0 });
    });
    it("400 error.webp.too_long over 10 s", async () => {
        const s = setup();
        s.seed({ duration: 60 });
        expect(await s.studio.render(SID, body({ start: 0, length: 12 }))).toEqual({
            status: 400,
            body: { status: "error", error: { code: "error.webp.too_long" } },
        });
    });

    it("429 error.webp.busy when the helper is encoding, and no row", async () => {
        const s = setup();
        s.seed();
        s.helper.uploadBusy = true;
        expect(await s.studio.render(SID, body({ start: 0, length: 2 }))).toEqual({
            status: 429,
            body: { status: "error", error: { code: "error.webp.busy" } },
        });
        expect(s.db.raw.prepare("SELECT count(*) AS n FROM studio_renders").get()).toEqual({ n: 0 });
    });
    it("429 error.webp.busy while a save is in flight, fine once it is done", async () => {
        const s = setup();
        s.seed();
        s.helper.fetchPolls = 5;
        const created = (await s.studio.create(KEY_ID, body({ url: LINK }))).body as { id: string };
        expect((await s.studio.render(SID, body({ start: 0, length: 2 }))).status).toBe(429);
        expect(asBody(await s.studio.advance(created.id, 30)).status).toBe("ready");
        expect((await s.studio.render(SID, body({ start: 0, length: 2 }))).status).toBe(202);
    });
    it("502 error.webp.storage when the original is gone from R2", async () => {
        const s = setup();
        s.seed({}, false);
        expect(await s.studio.render(SID, body({ start: 0, length: 2 }))).toEqual({
            status: 502,
            body: { status: "error", error: { code: "error.webp.storage" } },
        });
        expect(s.helper.calls).toEqual([]);
    });
});

describe("GET /studio/<sid>/render/<job> (render lifecycle)", () => {
    const start = async (s: ReturnType<typeof setup>, over: Record<string, unknown> = {}) => {
        s.seed();
        const res = await s.studio.render(SID, body({ start: 2, length: 5, ...over }));
        return (res.body as { job: string }).job;
    };

    it("pending, then success with the public URL; the row and the session list follow", async () => {
        const s = setup();
        const job = await start(s);
        s.helper.jobPolls = 1;
        expect(await s.studio.renderStatus(SID, job, 0)).toEqual({
            status: 200,
            body: { status: "pending", job, phase: null, frames_done: null, frames_total: null, queue_ahead: null },
        });
        s.clock.t += 5000;
        const done = await s.studio.renderStatus(SID, job, 0);
        expect(done.status).toBe(200);
        const b = done.body as any;
        expect(b).toMatchObject({ status: "success", job, bytes: 1500, width: 480, height: 560, seconds: 5 });
        expect(b.url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.webp$/);
        expect([...s.media.objects.keys()]).toEqual([b.url.slice(MEDIA.length)]);
        expect(s.db.raw.prepare("SELECT * FROM studio_renders WHERE id = ?").get(job)).toMatchObject({
            status: "success",
            url: b.url,
            bytes: 1500,
            out_width: 480,
            out_height: 560,
            seconds: 5,
        });
        // answered from D1 from now on
        const callsBefore = s.helper.calls.length;
        expect(await s.studio.renderStatus(SID, job, 0)).toEqual(done);
        expect(s.helper.calls.length).toBe(callsBefore);

        const renders = await listSuccessfulRenders(s.db, SID);
        const sessionRow = (await getSession(s.db, SID))!;
        expect(sessionBody(sessionRow, renders).renders).toEqual([
            { id: job, url: b.url, start: 2, length: 5, width: 480, quality: "med", bytes: 1500, created_at: expect.any(Number) },
        ]);
    });

    it("long-polls with wait", async () => {
        const s = setup();
        const job = await start(s);
        s.helper.jobPolls = 3;
        const t0 = s.clock.t;
        const res = await s.studio.renderStatus(SID, job, 20);
        expect((res.body as { status: string }).status).toBe("success");
        expect(s.clock.t - t0).toBeGreaterThanOrEqual(3000);
        expect(s.clock.t - t0).toBeLessThan(20_000);
    });

    it("a wait that runs out stays pending", async () => {
        const s = setup();
        const job = await start(s);
        s.helper.jobPolls = 1e9;
        expect(await s.studio.renderStatus(SID, job, 3)).toEqual({
            status: 200,
            body: { status: "pending", job, phase: null, frames_done: null, frames_total: null, queue_ahead: null },
        });
    });

    it("an encode error is recorded, answered 200 and stable", async () => {
        const s = setup();
        const job = await start(s);
        s.helper.jobError = "error.webp.encode_failed";
        const r = await s.studio.renderStatus(SID, job, 0);
        expect(r).toEqual({ status: 200, body: { status: "error", error: { code: "error.webp.encode_failed" } } });
        expect(s.db.raw.prepare("SELECT status, error_code FROM studio_renders WHERE id = ?").get(job)).toEqual({
            status: "error",
            error_code: "error.webp.encode_failed",
        });
        expect(await s.studio.renderStatus(SID, job, 0)).toEqual(r);
        // failed renders are not listed on the session
        expect(await listSuccessfulRenders(s.db, SID)).toEqual([]);
    });

    it("a job record lost from DO storage is job_lost", async () => {
        const s = setup();
        const job = await start(s);
        s.kv.m.delete(`job:${job}`);
        expect(await s.studio.renderStatus(SID, job, 0)).toEqual({
            status: 200,
            body: { status: "error", error: { code: "error.webp.job_lost" } },
        });
        expect(s.db.raw.prepare("SELECT error_code FROM studio_renders WHERE id = ?").get(job)).toEqual({ error_code: "error.webp.job_lost" });
    });

    it("a transient storage failure is passed on but not recorded", async () => {
        const s = setup();
        const job = await start(s);
        s.media.put = async () => {
            throw new Error("R2 down");
        };
        const r = await s.studio.renderStatus(SID, job, 0);
        expect(r).toEqual({ status: 502, body: { status: "error", error: { code: "error.webp.storage" } } });
        expect(s.db.raw.prepare("SELECT status FROM studio_renders WHERE id = ?").get(job)).toEqual({ status: "pending" });
    });

    it("unknown job or another session's job is 404, expired session is 410", async () => {
        const s = setup();
        const job = await start(s);
        const other = "Zy9Xw8Vu7Ts6Rq5Po4NmXX";
        expect((await s.studio.renderStatus(SID, "A".repeat(20), 0)).status).toBe(404);
        expect((await s.studio.renderStatus(other, job, 0)).status).toBe(404);
        s.clock.t += SESSION_TTL_MS + 1;
        expect((await s.studio.renderStatus(SID, job, 0)).status).toBe(410);
    });

    it("renders are newest first on the session", async () => {
        const s = setup();
        const a = await start(s);
        await s.studio.renderStatus(SID, a, 0);
        s.clock.t += 60_000;
        const second = await s.studio.render(SID, body({ start: 0, length: 1 }));
        const b = (second.body as { job: string }).job;
        await s.studio.renderStatus(SID, b, 0);
        const list = sessionBody((await getSession(s.db, SID))!, await listSuccessfulRenders(s.db, SID)).renders;
        expect(list.map((r) => r.id)).toEqual([b, a]);
    });
});

describe("handleStudioRoute (inside the Durable Object)", () => {
    const req = (method: string, path: string, headers: Record<string, string> = {}, b?: unknown) =>
        new Request(`https://do${path}`, { method, headers, body: b === undefined ? undefined : JSON.stringify(b) });

    it("POST /studio needs the key id header the Worker sets", async () => {
        const s = setup();
        expect((await handleStudioRoute(s.studio, req("POST", "/studio", {}, { url: LINK }))).status).toBe(403);
        const ok = await handleStudioRoute(s.studio, req("POST", "/studio", { [KEY_ID_HEADER]: KEY_ID }, { url: LINK }));
        expect(ok.status).toBe(201);
    });
    it("GET /studio/<sid>/advance?wait=N advances a saving session and answers like the status route", async () => {
        const s = setup();
        s.helper.fetchPolls = 2;
        const created = await handleStudioRoute(s.studio, req("POST", "/studio", { [KEY_ID_HEADER]: KEY_ID }, { url: LINK }));
        const { id } = (await created.json()) as { id: string };
        const res = await handleStudioRoute(s.studio, req("GET", `/studio/${id}/advance?wait=10`));
        expect(res.status).toBe(200);
        expect(await res.json()).toMatchObject({ status: "ready", id, link: LINK, error: null });
        expect(s.row(id).status).toBe("ready");
    });
    it("advance: unknown session 404, malformed id 404, other methods 404", async () => {
        const s = setup();
        const unknown = await handleStudioRoute(s.studio, req("GET", `/studio/${SID}/advance`));
        expect(unknown.status).toBe(404);
        expect(await unknown.json()).toEqual({ status: "error", error: { code: "error.studio.not_found" } });
        expect((await handleStudioRoute(s.studio, req("GET", "/studio/short/advance"))).status).toBe(404);
        expect((await handleStudioRoute(s.studio, req("POST", `/studio/${SID}/advance`))).status).toBe(404);
        expect(s.helper.calls).toEqual([]);
    });
    it("render routes take no key", async () => {
        const s = setup();
        s.seed();
        const res = await handleStudioRoute(s.studio, req("POST", `/studio/${SID}/render`, {}, { start: 0, length: 2 }));
        expect(res.status).toBe(202);
        const { job } = (await res.json()) as { job: string };
        const st = await handleStudioRoute(s.studio, req("GET", `/studio/${SID}/render/${job}?wait=2`));
        expect(st.status).toBe(200);
        expect(((await st.json()) as { status: string }).status).toBe("success");
    });
    it("malformed ids and other shapes are 404 without touching anything", async () => {
        const s = setup();
        for (const [m, p] of [
            ["POST", "/studio/short/render"],
            ["GET", `/studio/${SID}/render/short`],
            ["GET", `/studio/${SID}/render`],
            ["POST", `/studio/${SID}/render/${"a".repeat(20)}`],
            ["GET", `/studio/${SID}`],
            ["DELETE", "/studio"],
        ]) {
            expect((await handleStudioRoute(s.studio, req(m, p))).status).toBe(404);
        }
        expect(s.helper.calls).toEqual([]);
    });
});

// ---------------------------------------------------------------------------------
// APP-API-CONTRACT.md section 2: step / step_bytes / step_total / waking
describe("save progress on the session body", () => {
    const gated = () => {
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        return { gate, release };
    };
    const FIELDS = ["step", "step_bytes", "step_total", "waking"];
    const progressOf = (r: { body: unknown }) => {
        const b = asBody(r);
        return { step: b.step, step_bytes: b.step_bytes, step_total: b.step_total, waking: b.waking };
    };
    const NONE = { step: null, step_bytes: null, step_total: null, waking: false };

    it("sessionBody always carries the four fields: null / false unless the session is saving and progress is known", () => {
        const row = {
            id: SID, key_id: null, link: LINK, service: "x", title: null, status: "ready", error_code: null, r2_key: null,
            content_type: null, bytes: null, duration: null, width: null, height: null, created_at: 1, expires_at: 2,
        } as SessionRow;
        const p = { step: "fetching" as const, bytes: 10, total: 20, waking: true };
        for (const f of FIELDS) expect(sessionBody(row, [])).toHaveProperty(f);
        expect(sessionBody({ ...row, status: "saving" }, [])).toMatchObject(NONE);
        expect(sessionBody({ ...row, status: "saving" }, [], p)).toMatchObject({ step: "fetching", step_bytes: 10, step_total: 20, waking: true });
        // a ready or failed session never shows stale progress
        expect(sessionBody(row, [], p)).toMatchObject(NONE);
        expect(sessionBody({ ...row, status: "error" }, [], p)).toMatchObject(NONE);
    });

    it("a link save: fetching (the helper's bytes and the content-length) -> reading (the probe) -> ready", async () => {
        const s = setup();
        s.helper.fetchPolls = 2;
        const { id } = asBody(await create(s));

        s.helper.fetchPendingFields = { stage: "downloading", bytes: 5000, total: 20000 };
        expect(progressOf(await s.studio.advance(id, 0))).toEqual({ step: "fetching", step_bytes: 5000, step_total: 20000, waking: false });

        // the helper is now probing: the bytes are what was downloaded, there is no total
        s.helper.fetchPendingFields = { stage: "probing", bytes: 20000, total: null };
        expect(progressOf(await s.studio.advance(id, 0))).toEqual({ step: "reading", step_bytes: 20000, step_total: null, waking: false });

        const done = await s.studio.advance(id, 0);
        expect(asBody(done).status).toBe("ready");
        expect(progressOf(done)).toEqual(NONE);
    });

    it("the helper's bytes with no content-length: total stays null", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        s.helper.fetchPendingFields = { stage: "downloading", bytes: 123, total: null };
        const { id } = asBody(await create(s));
        expect(progressOf(await s.studio.advance(id, 0))).toEqual({ step: "fetching", step_bytes: 123, step_total: null, waking: false });
    });

    it("an old helper (no stage, bytes or total): step fetching, the numbers stay null", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        s.helper.fetchPendingFields = {};
        const { id } = asBody(await create(s));
        expect(progressOf(await s.studio.advance(id, 0))).toEqual({ step: "fetching", step_bytes: null, step_total: null, waking: false });
    });

    it("junk numbers from the helper are null, never passed through", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        s.helper.fetchPendingFields = { stage: "downloading", bytes: "lots", total: null };
        const { id } = asBody(await create(s));
        expect(progressOf(await s.studio.advance(id, 0))).toEqual({ step: "fetching", step_bytes: null, step_total: null, waking: false });
    });

    it("storing: bytes copied into R2 so far out of the helper's file size, counted chunk by chunk", async () => {
        const s = setup();
        const hold = gated();
        const total = 4096;
        // the helper's file arrives in three chunks, the last one after the test has looked
        const st = s.make({
            helper: async (path, init) => {
                if (path.endsWith("/file")) {
                    let sent = 0;
                    return new Response(
                        new ReadableStream<Uint8Array>(
                            {
                                async pull(c) {
                                    if (sent === 2) await hold.gate;
                                    const n = sent < 2 ? 1000 : total - 2000;
                                    c.enqueue(new Uint8Array(n).fill(7));
                                    sent++;
                                    if (sent === 3) c.close();
                                },
                            },
                            { highWaterMark: 0 },
                        ),
                        { headers: { "content-length": String(total) } },
                    );
                }
                return s.helper.helper(path, init);
            },
        });
        s.helper.videoBytes = new Uint8Array(total).fill(7);
        const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
        const finishing = st.advance(id, 0); // takes the lock and copies into R2
        await new Promise((r) => setTimeout(r, 30));
        // a second poll does not wait for the copy: it answers with what the first has done
        const mid = progressOf(await st.advance(id, 0));
        expect(mid.step).toBe("storing");
        expect(mid.step_total).toBe(total);
        expect(mid.step_bytes).toBe(2000);
        expect(mid.waking).toBe(false);
        hold.release();
        const done = await finishing;
        expect(asBody(done)).toMatchObject({ status: "ready", bytes: total });
        expect(progressOf(done)).toEqual(NONE);
        expect(s.originals.objects.get(`originals/${id}.mp4`)!.bytes.length).toBe(total);
    });

    it("the onChunk contract the production copy loop follows: every chunk's size is reported, in order", async () => {
        const seen: number[] = [];
        const stream = new ReadableStream<Uint8Array>({
            start(c) {
                for (const n of [3, 5, 7]) c.enqueue(new Uint8Array(n));
                c.close();
            },
        });
        await new Response(fixedLength(stream, 15, (n) => seen.push(n))).arrayBuffer();
        expect(seen).toEqual([3, 5, 7]);
    });

    it("waking is true while the save waits for the container to start, false once it is up", async () => {
        const s = setup();
        const hold = gated();
        let running = false;
        const st = s.make({
            kickMs: 5,
            isRunning: () => running,
            ensureRunning: async () => {
                await hold.gate;
                running = true;
            },
        });
        const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
        // the kick-off is stuck waking the container: a poll sees it
        const poll = st.advance(id, 0);
        await new Promise((r) => setTimeout(r, 20));
        expect(progressOf(await st.advance(id, 0))).toEqual({ step: "fetching", step_bytes: null, step_total: null, waking: true });
        hold.release();
        await poll;
        s.helper.fetchPolls = 1;
        s.helper.fetchPendingFields = { stage: "downloading", bytes: 1, total: 2 };
        // up now: the next step reports the helper, not waking
        expect(progressOf(await st.advance(id, 0))).toMatchObject({ step: "fetching", waking: false });
    });

    it("waking is false when the container is already running", async () => {
        const s = setup();
        const hold = gated();
        const st = s.make({ kickMs: 5, isRunning: () => true, ensureRunning: () => hold.gate });
        const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
        const poll = st.advance(id, 0);
        await new Promise((r) => setTimeout(r, 20));
        expect(progressOf(await st.advance(id, 0))).toMatchObject({ step: "fetching", waking: false });
        hold.release();
        await poll;
    });

    it("an unreachable container ends the wait: waking goes back to false", async () => {
        const s = setup();
        const st = s.make({
            isRunning: () => false,
            ensureRunning: async () => {
                throw new Error("no instance");
            },
        });
        const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
        expect(progressOf(await st.advance(id, 0))).toMatchObject({ step: "fetching", waking: false });
    });

    it("an adopted upload: reading while the helper probes, then ready with no progress", async () => {
        const s = setup();
        const hold = gated();
        const st = s.make({
            helper: async (path, init) => {
                if (path.startsWith("/probe")) await hold.gate;
                return s.helper.helper(path, init);
            },
        });
        s.originals.objects.set("uploads/Ab3dE6gH9jK2mN5p.mp4", { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        const created = await st.adopt(
            "svc",
            body({ r2_key: "uploads/Ab3dE6gH9jK2mN5p.mp4", name: "holiday.mp4", content_type: "video/mp4", bytes: 4096, item_id: "Ab3dE6gH9jK2mN5p" }),
        );
        const id = asBody(created).id;
        const probing = st.advance(id, 0);
        await new Promise((r) => setTimeout(r, 20));
        expect(progressOf(await st.advance(id, 0))).toEqual({ step: "reading", step_bytes: null, step_total: null, waking: false });
        hold.release();
        const done = await probing;
        expect(asBody(done).status).toBe("ready");
        expect(progressOf(done)).toEqual(NONE);
    });

    it("a failed save has no progress left", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        const { id } = asBody(await create(s));
        const r = await s.studio.advance(id, 0);
        expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
        expect(progressOf(r)).toEqual(NONE);
    });

    it("progress is in memory only: a fresh Durable Object (after an eviction) starts from its next step", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        s.helper.fetchPendingFields = { stage: "downloading", bytes: 9, total: 90 };
        const { id } = asBody(await create(s));
        expect(progressOf(await s.studio.advance(id, 0)).step_bytes).toBe(9);
        const reborn = s.make();
        s.helper.fetchPendingFields = { stage: "downloading", bytes: 40, total: 90 };
        s.helper.fetchPolls = 1;
        expect(progressOf(await reborn.advance(id, 0))).toEqual({ step: "fetching", step_bytes: 40, step_total: 90, waking: false });
    });
});

// ---------------------------------------------------------------------------------
// APP-API-CONTRACT.md section 6: jobs finish with nobody polling
describe("the job sweep", () => {
    const renderRow = (s: Setup, job: string) =>
        s.db.raw.prepare("SELECT status FROM studio_renders WHERE id = ?").get(job) as { status: string };
    const mediaRows = (s: Setup) => s.db.raw.prepare("SELECT * FROM media_items").all() as any[];
    const tick = () => new Promise((r) => setTimeout(r, 5));
    const startRender = async (s: Setup, over: Record<string, unknown> = {}) => {
        const res = await s.studio.render(SID, body({ start: 2, length: 5, ...over }));
        expect(res.status).toBe(202);
        return asBody(res).job as string;
    };

    describe("scheduleSweep is asked for when something starts", () => {
        it("a link save, an adopt and a render each ask once", async () => {
            let n = 0;
            const s = setup(() => void n++);
            await create(s);
            expect(n).toBe(1);

            const t = setup(() => void n++);
            t.originals.objects.set("uploads/Ab3dE6gH9jK2mN5p.mp4", { bytes: new Uint8Array(10), contentType: "video/mp4", meta: {} });
            await t.studio.adopt("svc", body({ r2_key: "uploads/Ab3dE6gH9jK2mN5p.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "Ab3dE6gH9jK2mN5p" }));
            expect(n).toBe(2);

            const u = setup(() => void n++);
            u.seed();
            await startRender(u);
            expect(n).toBe(3);
        });
        it("the record the sweep will look for exists by the time it is asked", async () => {
            let seenSave = false;
            let s!: Setup;
            s = setup(() => {
                seenSave = [...s.kv.m.keys()].some((k) => k.startsWith("save:"));
            });
            await create(s);
            expect(seenSave).toBe(true);
        });
        it("a refused create / adopt / render asks for nothing", async () => {
            let n = 0;
            const s = setup(() => void n++);
            await s.studio.create(KEY_ID, body({ url: "nope" }));
            await s.studio.adopt("svc", "nope");
            s.seed();
            await s.studio.render(SID, body({ start: 99, length: 2 }));
            s.helper.uploadBusy = true;
            await s.studio.render(SID, body({ start: 0, length: 2 }));
            expect(n).toBe(0);
        });
        it("a failing scheduler never fails the request that asked", async () => {
            const s = setup(() => {
                throw new Error("scheduler down");
            });
            expect((await create(s)).status).toBe(201);
            s.helper.fetchPolls = 1e9;
            const t = setup(() => {
                throw new Error("scheduler down");
            });
            t.seed();
            expect((await t.studio.render(SID, body({ start: 0, length: 2 }))).status).toBe(202);
        });
    });

    describe("renders", () => {
        it("collects a render nobody polled: D1 success, the media_items row and the R2 object", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            expect(renderRow(s, job).status).toBe("pending");
            expect(s.media.objects.size).toBe(0);

            s.clock.t += 5000;
            expect(await s.studio.sweep()).toEqual({ pending: 0 });

            expect(renderRow(s, job).status).toBe("success");
            expect(s.media.objects.size).toBe(1);
            const rows = mediaRows(s);
            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({ source: "studio", kind: "public", bucket: "media", session_id: SID, link: LINK });
            expect(rows[0].r2_key).toBe([...s.media.objects.keys()][0]);
            // and the client's next poll just reads it
            const polled = await s.studio.renderStatus(SID, job, 0);
            expect(asBody(polled)).toMatchObject({ status: "success", job });
            expect(mediaRows(s)).toHaveLength(1);
        });
        it("a render still encoding is counted pending and left alone", async () => {
            const s = setup();
            s.seed();
            s.helper.jobPolls = 1e9;
            s.helper.jobPendingFields = { phase: "decode", frames_done: 3, frames_total: 75 };
            const job = await startRender(s);
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(renderRow(s, job).status).toBe("pending");
            // the sweep's polls feed the progress a later client poll reports
            expect(asBody(await s.studio.renderStatus(SID, job, 0))).toMatchObject({ status: "pending", phase: "decode", frames_done: 3, frames_total: 75 });
        });
        it("an encode error is recorded too, once", async () => {
            const s = setup();
            s.seed();
            s.helper.jobError = "error.webp.timeout";
            const job = await startRender(s);
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.db.raw.prepare("SELECT status, error_code FROM studio_renders WHERE id = ?").get(job)).toEqual({
                status: "error",
                error_code: "error.webp.timeout",
            });
            const n = s.helper.calls.length;
            await s.studio.sweep();
            expect(s.helper.calls.length).toBe(n); // a finished job is not polled again
        });
        it("a lost job (the container restarted) becomes job_lost", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            s.helper.jobsGone = true;
            await s.studio.sweep();
            expect(s.db.raw.prepare("SELECT status, error_code FROM studio_renders WHERE id = ?").get(job)).toEqual({
                status: "error",
                error_code: "error.webp.job_lost",
            });
        });
        it("a render that finished is not collected twice: a client poll after the sweep adds no second item", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            await s.studio.sweep();
            await s.studio.renderStatus(SID, job, 0);
            await s.studio.sweep();
            expect(mediaRows(s)).toHaveLength(1);
            expect(s.media.puts).toHaveLength(1);
        });
        it("stops at SWEEP_RENDER_MS: an older job is no longer polled", async () => {
            const s = setup();
            s.seed();
            s.helper.jobPolls = 1e9;
            const job = await startRender(s);
            s.clock.t += SWEEP_RENDER_MS;
            expect(await s.studio.sweep()).toEqual({ pending: 1 }); // still inside the budget
            s.clock.t += 1;
            const n = s.helper.calls.length;
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.helper.calls.length).toBe(n);
            expect(renderRow(s, job).status).toBe("pending");
        });
        it("an unreachable helper keeps it pending (the container comes back, or the budget ends it)", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            s.helper.unreachable = true;
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(renderRow(s, job).status).toBe("pending");
        });
    });

    describe("saves", () => {
        it("advances a save nobody polled to ready, with the video in R2 and the library item", async () => {
            const s = setup();
            const { id } = asBody(await create(s));
            expect(s.row(id).status).toBe("saving");
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.row(id)).toMatchObject({ status: "ready", r2_key: `originals/${id}.mp4` });
            expect(s.originals.objects.has(`originals/${id}.mp4`)).toBe(true);
            expect(mediaRows(s)).toHaveLength(1);
            expect(mediaRows(s)[0]).toMatchObject({ source: "saved", session_id: id, key_id: KEY_ID });
            expect(await s.kv.list({ prefix: "save:" })).toEqual(new Map());
        });
        it("one step per pass: a download in progress is pending until the helper has it", async () => {
            const s = setup();
            s.helper.fetchPolls = 2;
            const { id } = asBody(await create(s));
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(s.row(id).status).toBe("saving");
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.row(id).status).toBe("ready");
        });
        it("wakes the container for a save that never got going (phase starting)", async () => {
            const s = setup();
            s.helper.busyFetchStarts = 1;
            const { id } = asBody(await create(s)); // refused at the kick-off: still starting
            expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "starting" });
            s.clock.t += 3000;
            expect(await s.studio.sweep()).toEqual({ pending: 1 }); // accepted now
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.row(id).status).toBe("ready");
        });
        it("an adopted upload is probed by the sweep", async () => {
            const s = setup();
            s.originals.objects.set("uploads/Ab3dE6gH9jK2mN5p.mp4", { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
            const created = await s.studio.adopt("svc", body({ r2_key: "uploads/Ab3dE6gH9jK2mN5p.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 4096, item_id: "Ab3dE6gH9jK2mN5p" }));
            const sid = asBody(created).id;
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.row(sid)).toMatchObject({ status: "ready", width: 640, height: 360 });
        });
        it("a save a client poll is advancing right now is not advanced twice (counted pending, helper not called)", async () => {
            const s = setup();
            let release!: () => void;
            const hold = new Promise<void>((r) => (release = r));
            s.helper.fetchPolls = 1e9;
            const st = s.make({
                helper: async (path, init) => {
                    if (path.startsWith("/fetch/") && !path.endsWith("/file") && init?.method !== "DELETE") await hold;
                    return s.helper.helper(path, init);
                },
            });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            const poll = st.advance(id, 0); // holds the lock inside the helper call
            await new Promise((r) => setTimeout(r, 20));
            const n = s.helper.calls.length;
            expect(await st.sweep()).toEqual({ pending: 1 });
            expect(s.helper.calls.length).toBe(n);
            release();
            await poll;
        });
        it("stops advancing a save whose helper fetch is older than SAVE_BUDGET_MS + 60 s (the sweep refreshes lastAdvance itself, so the budget hangs on startedAt)", async () => {
            const s = setup();
            const { id } = asBody(await create(s));
            const record = (startedAt: number) =>
                s.kv.put(`save:${id}`, { phase: "starting", startedAt, attempts: 0, lastAdvance: s.clock.t });
            // exactly at the edge: still advanced (the helper accepts the fetch, so it stays pending)
            await record(s.clock.t - SAVE_BUDGET_MS - SWEEP_SAVE_SLACK_MS);
            s.helper.fetchPolls = 1e9;
            expect(await s.studio.sweep()).toEqual({ pending: 1 });
            expect(await s.kv.get(`save:${id}`)).toMatchObject({ phase: "fetching" });
            // one ms over: skipped, the helper is not called, and it no longer counts as pending
            await record(s.clock.t - SAVE_BUDGET_MS - SWEEP_SAVE_SLACK_MS - 1);
            const n = s.helper.calls.length;
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.helper.calls.length).toBe(n);
            expect(s.row(id).status).toBe("saving");
        });
        it("a save that errors is finished and not pending", async () => {
            const s = setup();
            s.helper.fetchError = "error.api.fetch.fail";
            const { id } = asBody(await create(s));
            expect(await s.studio.sweep()).toEqual({ pending: 0 });
            expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.api.fetch.fail" });
        });
    });

    describe("a client long-poll racing the sweep on one render (finding 1)", () => {
        // a Studio + WebP pair whose sleeps are held until woken
        const gatedStudio = (s: Setup) => {
            const waiting: Array<() => void> = [];
            const sleep = (ms: number) =>
                new Promise<void>((r) => {
                    s.clock.t += ms;
                    waiting.push(r);
                });
            const webp = new WebpService({
                storage: s.kv,
                bucket: s.media,
                mediaBaseUrl: MEDIA,
                now: s.clock.now,
                sleep,
                ensureRunning: async () => {},
                helper: s.helper.helper,
                db: s.db,
            });
            const st = s.make({ webp, sleep });
            return { st, waiting, wake: () => waiting.splice(0).forEach((r) => r()) };
        };

        it("the app's poll after the sweep collected the render gets the success, not one job_lost reply; D1 and the library stay success, once", async () => {
            const s = setup();
            s.seed();
            s.helper.dropJobsOnDelete = true; // like the real helper: collecting deletes its job
            const g = gatedStudio(s);
            const made = await g.st.render(SID, body({ start: 2, length: 5 }));
            const job = asBody(made).job as string;
            s.helper.jobPolls = 1; // the first helper poll is still pending

            const client = g.st.renderStatus(SID, job, 20); // long-poll: pending, then sleeps
            await tick();
            expect(g.waiting).toHaveLength(1);

            expect(await g.st.sweep()).toEqual({ pending: 0 }); // the sweep collects it and drops the helper job
            expect(renderRow(s, job).status).toBe("success");

            g.wake();
            const got = await client;
            expect(got.status).toBe(200);
            expect(asBody(got)).toMatchObject({ status: "success", job });
            expect(renderRow(s, job).status).toBe("success");
            expect(mediaRows(s)).toHaveLength(1);
            expect(s.media.puts).toHaveLength(1);
            // and a later poll still says success
            expect(asBody(await g.st.renderStatus(SID, job, 0))).toMatchObject({ status: "success", job });
        });
        it("a lost-job answer for a row that was settled meanwhile is replaced by what is recorded (success stays success)", async () => {
            const s = setup();
            s.seed();
            const real = await s.studio.render(SID, body({ start: 2, length: 5 }));
            const job = asBody(real).job as string;
            // a webp whose answer arrives after the sweep recorded the success in D1
            const webp = {
                status: async () => {
                    s.db.raw
                        .prepare("UPDATE studio_renders SET status = 'success', url = ?, bytes = 1500, out_width = 480, out_height = 560, seconds = 5 WHERE id = ?")
                        .run(`${MEDIA}Done123456.webp`, job);
                    return { status: 404, body: { status: "error", error: { code: "error.webp.not_found" } } };
                },
            } as unknown as WebpService;
            const st = s.make({ webp });
            const r = await st.renderStatus(SID, job, 0);
            expect(r.status).toBe(200);
            expect(asBody(r)).toMatchObject({ status: "success", job, url: `${MEDIA}Done123456.webp` });
            expect(renderRow(s, job).status).toBe("success");
        });
        it("a genuinely lost job is still recorded and answered as job_lost", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            s.helper.jobsGone = true;
            const r = await s.studio.renderStatus(SID, job, 0);
            expect(asBody(r)).toEqual({ status: "error", error: { code: "error.webp.job_lost" } });
            expect(renderRow(s, job).status).toBe("error");
        });
    });

    describe("a hung item cannot keep the sweep (and so the container) awake (finding 2)", () => {
        const never = () => new Promise<Response>(() => {});
        const timed = async <T>(p: Promise<T>) => {
            const t0 = Date.now();
            const v = await p;
            return { v, ms: Date.now() - t0 };
        };

        it("the default item ceiling is 30 s", () => {
            expect(SWEEP_ITEM_MS).toBe(30_000);
        });
        it("a render whose helper poll hangs: the item is cut at the ceiling, counted pending, the pass returns", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            const webp = new WebpService({
                storage: s.kv,
                bucket: s.media,
                mediaBaseUrl: MEDIA,
                now: s.clock.now,
                sleep: s.clock.sleep,
                ensureRunning: async () => {},
                helperTimeoutMs: 60_000, // the webp's own ceiling is out of the picture: this is the sweep's
                helper: (path, init) => (path === `/jobs/${job}` ? never() : s.helper.helper(path, init)),
                db: s.db,
            });
            const st = s.make({ webp, sweepItemMs: 30 });
            const { v, ms } = await timed(st.sweep());
            expect(v).toEqual({ pending: 1 });
            expect(ms).toBeLessThan(2000);
            expect(renderRow(s, job).status).toBe("pending");
        });
        it("the same render with the webp's own ceiling: the poll is a miss, the pass still returns promptly", async () => {
            const s = setup();
            s.seed();
            const job = await startRender(s);
            const webp = new WebpService({
                storage: s.kv,
                bucket: s.media,
                mediaBaseUrl: MEDIA,
                now: s.clock.now,
                sleep: s.clock.sleep,
                ensureRunning: async () => {},
                helperTimeoutMs: 30,
                helper: (path, init) => (path === `/jobs/${job}` ? never() : s.helper.helper(path, init)),
                db: s.db,
            });
            const st = s.make({ webp });
            const { v, ms } = await timed(st.sweep());
            expect(v).toEqual({ pending: 1 });
            expect(ms).toBeLessThan(2000);
        });
        it("a save whose step hangs: cut at the ceiling, counted pending", async () => {
            const s = setup();
            s.helper.fetchPolls = 1e9;
            const st = s.make({
                sweepItemMs: 30,
                helperTimeoutMs: 60_000, // the helper-call ceiling is out of the picture: this is the sweep's
                helper: (path, init) =>
                    path.startsWith("/fetch/") && !path.endsWith("/file") && init?.method !== "DELETE" ? never() : s.helper.helper(path, init),
            });
            await s.kv.put("save:aB3dE6gH9jK2mN5pQ8sTuV", { phase: "fetching", startedAt: s.clock.t, attempts: 1, lastAdvance: s.clock.t });
            s.db.raw
                .prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?, ?, ?, 'x', 'saving', ?, ?)")
                .run("aB3dE6gH9jK2mN5pQ8sTuV", KEY_ID, LINK, s.clock.t, s.clock.t + SESSION_TTL_MS);
            const { v, ms } = await timed(st.sweep());
            expect(v).toEqual({ pending: 1 });
            expect(ms).toBeLessThan(2000);
        });
    });

    describe("a save whose lock is held (finding 3)", () => {
        // helper whose FIRST poll of the fetch hangs until released (a hung finalize / poll)
        const hungFirstPoll = (s: Setup) => {
            let release!: () => void;
            const hold = new Promise<void>((r) => (release = r));
            let hung = false;
            const st = s.make({
                helperTimeoutMs: 1e9,
                helper: async (path, init) => {
                    if (!hung && path.startsWith("/fetch/") && !path.endsWith("/file") && init?.method !== "DELETE") {
                        hung = true;
                        await hold;
                    }
                    return s.helper.helper(path, init);
                },
            });
            return { st, release };
        };

        it("past its budget a save is neither advanced nor pending, even with a hung step still holding its lock (the sweep used to re-arm every 5 s for ever)", async () => {
            const s = setup();
            s.helper.fetchPolls = 1e9;
            const h = hungFirstPoll(s);
            const { id } = asBody(await h.st.create(KEY_ID, body({ url: LINK })));
            const hung = h.st.advance(id, 0); // takes the lock and hangs inside the helper poll
            await tick();
            const rec = (await s.kv.get<Record<string, unknown>>(`save:${id}`))!;
            await s.kv.put(`save:${id}`, { ...rec, startedAt: s.clock.t - SAVE_BUDGET_MS - SWEEP_SAVE_SLACK_MS - 1 });
            const n = s.helper.calls.length;
            expect(await h.st.sweep()).toEqual({ pending: 0 });
            expect(s.helper.calls.length).toBe(n);
            h.release();
            await hung;
        });
        it("inside its budget a save a poll is advancing (fresh lock) is left alone and counted pending", async () => {
            const s = setup();
            s.helper.fetchPolls = 1e9;
            const h = hungFirstPoll(s);
            const { id } = asBody(await h.st.create(KEY_ID, body({ url: LINK })));
            const hung = h.st.advance(id, 0);
            await tick();
            s.clock.t += LOCK_STALE_MS; // exactly the limit: still fresh
            const n = s.helper.calls.length;
            expect(await h.st.sweep()).toEqual({ pending: 1 });
            expect(s.helper.calls.length).toBe(n);
            h.release();
            await hung;
        });
        it("a lock older than LOCK_STALE_MS is stale: the sweep drops it and advances the save", async () => {
            const s = setup();
            s.helper.fetchPolls = 1e9;
            const h = hungFirstPoll(s);
            const { id } = asBody(await h.st.create(KEY_ID, body({ url: LINK })));
            const hung = h.st.advance(id, 0);
            await tick();
            s.clock.t += LOCK_STALE_MS + 1;
            s.helper.fetchPolls = 0; // the next poll finds the file
            expect(await h.st.sweep()).toEqual({ pending: 0 });
            expect(s.row(id)).toMatchObject({ status: "ready", r2_key: `originals/${id}.mp4` });
            h.release();
            await hung;
        });
    });

    it("does nothing when there is nothing; counts a render while one is encoding", async () => {
        const s = setup();
        expect(await s.studio.sweep()).toEqual({ pending: 0 });
        expect(s.helper.calls).toEqual([]);

        s.seed();
        s.helper.jobPolls = 1e9;
        await startRender(s);
        expect(await s.studio.sweep()).toEqual({ pending: 1 });
    });
    it("never throws: storage that fails to list counts as nothing pending", async () => {
        const s = setup();
        s.kv.list = async () => {
            throw new Error("storage down");
        };
        expect(await s.studio.sweep()).toEqual({ pending: 0 });
    });
});

// ---- Live Activity hooks (APP-API-CONTRACT.md section 8.3) -----------------------------------------

describe("live hooks (what the studio tells the live service)", () => {
    type Seen = { at: "save"; sid: string; e: any } | { at: "render"; sid: string; job: string; e: any };
    const fakeLive = (over: Partial<LiveHooks> = {}) => {
        const seen: Seen[] = [];
        const live: LiveHooks = {
            onSave: async (sid, e) => void seen.push({ at: "save", sid, e }),
            onRender: async (sid, job, e) => void seen.push({ at: "render", sid, job, e }),
            hasActiveRuns: async () => false,
            ...over,
        };
        return { live, seen };
    };
    const saves = (seen: Seen[]) => seen.filter((x) => x.at === "save").map((x) => (x as any).e);
    const renders = (seen: Seen[]) => seen.filter((x) => x.at === "render").map((x) => (x as any).e);
    const kinds = (seen: Seen[]) => seen.map((x) => `${x.at}:${(x as any).e.kind}${(x as any).e.progress ? `:${(x as any).e.progress.step}` : ""}`);

    describe("saves", () => {
        it("starting -> fetching -> storing -> ready: fetching, saving (bytes of the copy, the clip's title and length), then nothing for `ready`", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            s.helper.fetchPolls = 2;
            s.helper.fetchPendingFields = { stage: "downloading", bytes: 5000, total: 20000 };
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            // create's kick: startFetch sets the progress twice (before and after the container is up)
            expect(kinds(seen)).toEqual(["save:progress:fetching", "save:progress:fetching"]);
            expect(seen.every((x) => x.at === "save" && x.sid === id)).toBe(true);

            seen.length = 0;
            await st.advance(id, 0); // pollFetch: downloading
            expect(kinds(seen)).toEqual(["save:progress:fetching"]);
            expect(saves(seen)[0].progress).toEqual({ step: "fetching", bytes: 5000, total: 20000, waking: false });

            seen.length = 0;
            s.helper.fetchPendingFields = { stage: "probing", bytes: 20000, total: null };
            await st.advance(id, 0); // pollFetch: probing is `reading` on the wire
            expect(saves(seen)[0].progress).toEqual({ step: "reading", bytes: 20000, total: null, waking: false });

            seen.length = 0;
            expect(asBody(await st.advance(id, 0)).status).toBe("ready"); // finalize
            expect(kinds(seen)).toEqual(["save:progress:storing"]);
            expect(saves(seen)[0]).toMatchObject({
                kind: "progress",
                progress: { step: "storing", total: 4096, waking: false },
                title: "x_2105237035271258436",
                duration: 9.6,
            });

            // the session is ready: nothing more is said (the device reads the video)
            seen.length = 0;
            await st.advance(id, 0);
            await st.sweep();
            expect(seen).toEqual([]);
        });

        it("`waking` follows the container: true while it starts, false after", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live, isRunning: () => false });
            await st.create(KEY_ID, body({ url: LINK }));
            expect(saves(seen).map((e) => e.progress.waking)).toEqual([true, false]);
        });

        it("the byte count of the copy into R2 is reported while it runs, at most once a second, without waiting on the hook", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const total = 5000;
            // 5 chunks of 1000 bytes, the clock 1.5 s later at each one
            const st = s.make({
                live,
                helper: async (path, init) => {
                    if (path.endsWith("/file")) {
                        let sent = 0;
                        return new Response(
                            new ReadableStream<Uint8Array>(
                                {
                                    pull(c) {
                                        s.clock.t += 1500;
                                        c.enqueue(new Uint8Array(1000).fill(7));
                                        if (++sent === 5) c.close();
                                    },
                                },
                                { highWaterMark: 0 },
                            ),
                            { headers: { "content-length": String(total) } },
                        );
                    }
                    return s.helper.helper(path, init);
                },
            });
            s.helper.videoBytes = new Uint8Array(total).fill(7);
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            expect(asBody(await st.advance(id, 0)).status).toBe("ready");
            await new Promise((r) => setTimeout(r, 10)); // the un-awaited ones settle
            const bytes = saves(seen).filter((e) => e.progress.step === "storing").map((e) => e.progress.bytes);
            expect(bytes.length).toBeGreaterThanOrEqual(4); // 0 at the start, then one per 1.5 s chunk
            expect(bytes).toEqual([...bytes].sort((a, b) => a - b));
            expect(bytes.at(-1)).toBeGreaterThan(0);
        });

        it("a save that fails: `failed` with the code (from fail(), whoever called it)", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            s.helper.fetchPolls = 1;
            s.helper.fetchError = "error.api.fetch.empty";
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            seen.length = 0;
            await st.advance(id, 0);
            await st.advance(id, 0);
            expect(asBody(await st.advance(id, 0)).error).toEqual({ code: "error.api.fetch.empty" });
            expect(saves(seen).at(-1)).toEqual({ kind: "failed", code: "error.api.fetch.empty" });
            expect(saves(seen).filter((e) => e.kind === "failed")).toHaveLength(1);
        });

        it("an orphaned save reaped later fails through the same hook", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            seen.length = 0;
            s.clock.t += SAVING_STUCK_MS + 1000;
            await st.reapOrphans();
            expect(saves(seen)).toEqual([{ kind: "failed", code: "error.studio.save_lost" }]);
            expect(seen[0]).toMatchObject({ sid: id });
        });

        it("an adopted upload says nothing while the server measures it (the device is reading frames then); its failure does", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            s.originals.objects.set("uploads/Ab3dE6gH9jK2mN5p.mp4", { bytes: new Uint8Array(10), contentType: "video/mp4", meta: {} });
            const adopted = await st.adopt("svc", body({ r2_key: "uploads/Ab3dE6gH9jK2mN5p.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "Ab3dE6gH9jK2mN5p" }));
            const { id } = asBody(adopted);
            expect(asBody(await st.advance(id, 0)).status).toBe("ready");
            expect(seen).toEqual([]);

            // a probe the helper refuses for good
            s.originals.objects.set("uploads/Zz3dE6gH9jK2mN5p.mp4", { bytes: new Uint8Array(10), contentType: "video/mp4", meta: {} });
            s.helper.probeError = { status: 400, code: "error.studio.not_video" };
            const bad = await st.adopt("svc", body({ r2_key: "uploads/Zz3dE6gH9jK2mN5p.mp4", name: "b.mp4", content_type: "video/mp4", bytes: 10, item_id: "Zz3dE6gH9jK2mN5p" }));
            await st.advance(asBody(bad).id, 0);
            expect(saves(seen)).toEqual([{ kind: "failed", code: "error.studio.not_video" }]);
        });

        it("the sweep's own advance of a save fires the same hooks", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            s.helper.fetchPolls = 1;
            s.helper.fetchPendingFields = { stage: "downloading", bytes: 1, total: 2 };
            await st.create(KEY_ID, body({ url: LINK }));
            seen.length = 0;
            expect(await st.sweep()).toEqual({ pending: 1 });
            expect(kinds(seen)).toEqual(["save:progress:fetching"]);
            seen.length = 0;
            expect(await st.sweep()).toEqual({ pending: 0 });
            expect(kinds(seen)).toEqual(["save:progress:storing"]);
        });
    });

    describe("renders", () => {
        const start = async (st: StudioService, s: Setup, over: Record<string, unknown> = {}) => {
            s.seed();
            const res = await st.render(SID, body({ start: 2, length: 5, ...over }));
            expect(res.status).toBe(202);
            return asBody(res).job as string;
        };

        it("accepted carries the session's title and length; the job id is the one the client gets", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const job = await start(st, s);
            expect(seen).toEqual([{ at: "render", sid: SID, job, e: { kind: "accepted", title: "x_2105237035271258436", duration: 9.6 } }]);
        });

        it("a refused render (busy, not ready, bad params) says nothing", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            s.seed();
            await st.render(SID, body({ start: 99, length: 2 }));
            s.helper.uploadBusy = true;
            await st.render(SID, body({ start: 0, length: 2 }));
            expect(seen).toEqual([]);
        });

        it("pending decode, pending pack, then success (and success again on a repeated poll)", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const job = await start(st, s);
            seen.length = 0;

            s.helper.jobPolls = 3;
            s.helper.jobPendingFields = { phase: "decode", frames_done: 42, frames_total: 150 };
            await st.renderStatus(SID, job, 0);
            s.helper.jobPendingFields = { phase: "pack", frames_done: 150, frames_total: 150 };
            await st.renderStatus(SID, job, 0);
            s.helper.jobPendingFields = {};
            await st.renderStatus(SID, job, 0);
            expect(renders(seen)).toEqual([
                { kind: "pending", phase: "decode", framesDone: 42, framesTotal: 150 },
                { kind: "pending", phase: "pack", framesDone: 150, framesTotal: 150 },
                { kind: "pending", phase: null, framesDone: null, framesTotal: null },
            ]);
            expect(seen.every((x) => x.at === "render" && x.sid === SID && x.job === job)).toBe(true);

            seen.length = 0;
            const done = asBody(await st.renderStatus(SID, job, 0));
            expect(done.status).toBe("success");
            const success = { kind: "success", url: done.url, bytes: 1500, width: 480, height: 560, seconds: 5 };
            expect(renders(seen)).toEqual([success]);
            // answered from D1 now, and still told to the live service (an equal state is never re-sent there; a lost push is)
            await st.renderStatus(SID, job, 0);
            expect(renders(seen)).toEqual([success, success]);
        });

        it("a recorded error, and a lost job, are `failed` with their codes (also when repeated from D1)", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const a = await start(st, s);
            s.helper.jobError = "error.webp.encode_failed";
            seen.length = 0;
            await st.renderStatus(SID, a, 0);
            await st.renderStatus(SID, a, 0); // from D1
            expect(renders(seen)).toEqual([
                { kind: "failed", code: "error.webp.encode_failed" },
                { kind: "failed", code: "error.webp.encode_failed" },
            ]);

            s.helper.jobError = null;
            s.helper.jobsGone = true;
            const b = asBody(await st.render(SID, body({ start: 2, length: 5 }))).job as string;
            seen.length = 0;
            await st.renderStatus(SID, b, 0);
            expect(renders(seen)).toEqual([{ kind: "failed", code: "error.webp.job_lost" }]);
        });

        it("transient answers (a 502 from storage, an expired or unknown session) say nothing", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const job = await start(st, s);
            seen.length = 0;
            expect((await st.renderStatus("aB3dE6gH9jK2mN5pQ8sTzz", job, 0)).status).toBe(404);
            s.clock.t += SESSION_TTL_MS + 1000;
            expect((await st.renderStatus(SID, job, 0)).status).toBe(410);
            expect(seen).toEqual([]);
        });

        it("the sweep's collection of a render nobody polled fires them too", async () => {
            const s = setup();
            const { live, seen } = fakeLive();
            const st = s.make({ live });
            const job = await start(st, s);
            seen.length = 0;
            s.helper.jobPolls = 1;
            s.helper.jobPendingFields = { phase: "decode", frames_done: 3, frames_total: 75 };
            expect(await st.sweep()).toEqual({ pending: 1 });
            expect(renders(seen)).toEqual([{ kind: "pending", phase: "decode", framesDone: 3, framesTotal: 75 }]);
            seen.length = 0;
            s.clock.t += 5000;
            expect(await st.sweep()).toEqual({ pending: 0 });
            expect(renders(seen)).toEqual([expect.objectContaining({ kind: "success" })]);
            expect(seen[0]).toMatchObject({ job });
        });
    });

    describe("a hook can never fail or stall the poll", () => {
        let errors: unknown[][];
        const quiet = () => {
            errors = [];
            return vi.spyOn(console, "error").mockImplementation((...a) => void errors.push(a));
        };
        afterEach(() => vi.restoreAllMocks());

        it("a hook that throws: the save and the render go on, and the error is logged", async () => {
            quiet();
            const s = setup();
            const boom = async () => {
                throw new Error("live exploded");
            };
            const st = s.make({ live: { onSave: boom, onRender: boom, hasActiveRuns: async () => false } });
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            expect(asBody(await st.advance(id, 0)).status).toBe("ready");
            s.seed({ id: "xY3dE6gH9jK2mN5pQ8sTuV" });
            const res = await st.render("xY3dE6gH9jK2mN5pQ8sTuV", body({ start: 2, length: 5 }));
            expect(res.status).toBe(202);
            const job = asBody(res).job;
            expect(asBody(await st.renderStatus("xY3dE6gH9jK2mN5pQ8sTuV", job, 0)).status).toBe("success");
            expect(errors.some((a) => String(a.join(" ")).includes("live exploded"))).toBe(true);
        });

        it("a hook that hangs: the poll comes back after the ceiling (LIVE_PUSH_MS, 30 ms here) with its normal answer", async () => {
            quiet();
            const s = setup();
            const hang = () => new Promise<void>(() => {});
            const st = s.make({ live: { onSave: hang, onRender: hang, hasActiveRuns: async () => false }, livePushMs: 30 });
            const t0 = Date.now();
            const { id } = asBody(await st.create(KEY_ID, body({ url: LINK })));
            expect(asBody(await st.advance(id, 0)).status).toBe("ready");
            const job = await (async () => {
                s.seed({ id: "xY3dE6gH9jK2mN5pQ8sTuV" });
                return asBody(await st.render("xY3dE6gH9jK2mN5pQ8sTuV", body({ start: 2, length: 5 }))).job as string;
            })();
            expect(asBody(await st.renderStatus("xY3dE6gH9jK2mN5pQ8sTuV", job, 0)).status).toBe("success");
            expect(Date.now() - t0).toBeLessThan(5000);
            expect(errors.some((a) => String(a.join(" ")).includes("timed out"))).toBe(true);
        });

        it("the ceiling defaults to LIVE_PUSH_MS (3000 ms)", () => {
            expect(LIVE_PUSH_MS).toBe(3000);
        });

        it("without a live service nothing changes (no hooks, no errors)", async () => {
            const s = setup();
            const { id } = asBody(await create(s));
            expect(asBody(await s.studio.advance(id, 0)).status).toBe("ready");
        });
    });
});
