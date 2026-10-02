import { describe, expect, it } from "vitest";
import { KEY_ID_HEADER } from "../src/headers";
import {
    BUSY_RETRY_MS,
    BUSY_WAIT_MS,
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

function setup() {
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
        expect(await s.studio.renderStatus(SID, job, 0)).toEqual({ status: 200, body: { status: "pending", job } });
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
        expect(await s.studio.renderStatus(SID, job, 3)).toEqual({ status: 200, body: { status: "pending", job } });
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
