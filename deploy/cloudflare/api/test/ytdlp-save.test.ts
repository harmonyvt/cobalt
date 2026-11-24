// Section 49: the studio save with the yt-dlp box next to cobalt. The box is a second FakeHelper (it answers the same
// single-file /fetch routes); these pin which engine runs, the one switch on a link failure, and the code a save that
// both engines failed ends with.
import { describe, expect, it } from "vitest";
import { fallsBack, parseSaveEngineMode, StudioService, type SaveEngineMode } from "../src/studio";
import { WebpService } from "../src/webp";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";

const LINK = "https://www.youtube.com/watch?v=jNQXAC9IVRw";
const KEY_ID = "key-row-1";

function setup(o: { box?: boolean; mode?: SaveEngineMode; boxAsleep?: boolean } = {}) {
    const db = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    const box = new FakeHelper();
    box.advertise = false; // the box says nothing about the helper's capabilities
    box.videoBytes = new Uint8Array(3000).fill(5);
    box.fetchDone = { title: "Me at the zoo", service: "youtube", duration: 19, width: 320, height: 240 };
    const starts: string[] = [];
    // the box's container: `boxAsleep` keeps it down, and its start pending, until `wakeBox()`
    let boxUp = o.boxAsleep !== true;
    const boxGates: (() => void)[] = [];
    const wakeBox = () => {
        boxUp = true;
        for (const open of boxGates.splice(0)) open();
    };
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: "https://media.capybaraharmony.com/",
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
    });
    const studio = new StudioService({
        db,
        storage: kv,
        originals,
        webp,
        webBaseUrl: "https://cobalt.capybaraharmony.com",
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {
            starts.push("cobalt");
        },
        helper: helper.helper,
        fixedLength,
        ...(o.box === false
            ? {}
            : {
                  ytdlp: {
                      helper: box.helper,
                      ensureRunning: async () => {
                          starts.push("ytdlp");
                          if (!boxUp) await new Promise<void>((open) => boxGates.push(open));
                      },
                      isRunning: async () => boxUp,
                  },
              }),
        saveEngine: o.mode ?? "fallback",
    });
    const row = (sid: string) => db.raw.prepare("SELECT * FROM studio_sessions WHERE id = ?").get(sid) as any;
    const items = () => db.raw.prepare("SELECT * FROM media_items").all() as any[];
    return { db, clock, kv, originals, helper, box, studio, starts, row, items, wakeBox };
}

const create = async (s: ReturnType<typeof setup>, extra: Record<string, unknown> = {}) => {
    const r = await s.studio.create(KEY_ID, JSON.stringify({ url: LINK, ...extra }));
    return r;
};
const idOf = (r: { body: unknown }) => (r.body as { id: string }).id;
const body = (r: { body: unknown }) => r.body as any;

describe("which failures switch engines", () => {
    it("link failures do, sizes, timeouts and lost saves do not", () => {
        for (const c of ["error.api.fetch.fail", "error.api.link.unsupported", "error.api.youtube.login", "error.webp.bad_source", "error.webp.no_video", "error.webp.upstream"]) {
            expect(fallsBack(c)).toBe(true);
        }
        for (const c of ["error.studio.too_large", "error.webp.timeout", "error.studio.save_lost", "error.studio.unavailable", "error.studio.busy", "error.studio.cancelled"]) {
            expect(fallsBack(c)).toBe(false);
        }
    });
    it("SAVE_ENGINE: only \"first\" changes the order", () => {
        expect(parseSaveEngineMode("first")).toBe("first");
        for (const v of [undefined, "", "fallback", "ytdlp", "FIRST"]) expect(parseSaveEngineMode(v)).toBe("fallback");
    });
});

describe("fallback mode (cobalt first)", () => {
    it("a link cobalt saves never touches the box", async () => {
        const s = setup();
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 0))).toMatchObject({ status: "ready" });
        expect(s.box.calls).toEqual([]);
        expect(s.starts).toEqual(["cobalt"]);
    });

    it("cobalt failing on the link hands the save to yt-dlp, which saves it into R2 like any save", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.fetchPolls = 1;
        const id = idOf(await create(s));
        let r = await s.studio.advance(id, 0);
        // cobalt's copy is dropped, the record now names the box and the code cobalt gave
        expect(s.helper.calls).toContain(`DELETE /fetch/${id}`);
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ engine: "ytdlp", fellBack: "error.api.fetch.fail", phase: "starting", attempts: 0 });
        expect(body(r).status).toBe("saving");
        r = await s.studio.advance(id, 0);
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ engine: "ytdlp", phase: "fetching", attempts: 1 });
        expect(s.box.fetchBodies).toEqual([{ id, url: LINK }]);
        r = await s.studio.advance(id, 0);
        expect(body(r).status).toBe("saving");
        r = await s.studio.advance(id, 0);
        expect(body(r)).toMatchObject({ status: "ready", bytes: 3000, duration: 19, width: 320, height: 240, title: "Me at the zoo" });
        expect(s.originals.objects.get(`originals/${id}.mp4`)!.bytes).toEqual(s.box.videoBytes);
        expect(s.box.calls).toEqual(["POST /fetch", `GET /fetch/${id}`, `GET /fetch/${id}`, `GET /fetch/${id}/file`, `DELETE /fetch/${id}`]);
        expect(s.items()).toHaveLength(1);
        expect(s.items()[0]).toMatchObject({ source: "saved", r2_key: `originals/${id}.mp4`, duration: 19 });
        expect(s.starts).toEqual(["cobalt", "ytdlp"]);
        expect(await s.kv.list({ prefix: "save:" })).toEqual(new Map());
    });

    it("both failing ends with cobalt's code (the words the app knows)", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.link.unsupported";
        s.box.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.api.link.unsupported" } });
        expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.api.link.unsupported" });
        expect(s.box.calls).toContain(`DELETE /fetch/${id}`);
    });

    it("yt-dlp's too_large wins over cobalt's code", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.fetchError = "error.studio.too_large";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.studio.too_large" } });
    });

    it("a failure that is not about the link does not switch", async () => {
        const s = setup();
        s.helper.fetchError = "error.studio.too_large";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.studio.too_large" } });
        expect(s.box.calls).toEqual([]);
    });

    it("a save of picked items stays with cobalt", async () => {
        const s = setup();
        s.helper.gallery = [{ type: "photo" }, { type: "photo" }];
        s.helper.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s, { items: [0, 1] }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
        expect(s.box.calls).toEqual([]);
    });

    it("without the box nothing changes", async () => {
        const s = setup({ box: false });
        s.helper.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
        expect(await create(s, { engine: "ytdlp" })).toMatchObject({ status: 400, body: { error: { code: "error.studio.invalid_params" } } });
    });

    it("a box that answers busy is waited for like the helper", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.busyFetchStarts = 1;
        const id = idOf(await create(s));
        await s.studio.advance(id, 0);
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ engine: "ytdlp", phase: "starting" });
        s.clock.t += 3000;
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready" });
    });

    it("a box that restarts mid-download starts the fetch again", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.fetchLosses = 1;
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready" });
        expect(s.box.calls.filter((c) => c === "POST /fetch")).toHaveLength(2);
    });

    it("a box that cannot be reached is a miss, then error.studio.unavailable", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.unreachable = true;
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 0)).status).toBe("saving"); // cobalt fails, the save switches
        expect(body(await s.studio.advance(id, 0)).status).toBe("saving"); // the box: a first miss
        s.clock.t += 31_000;
        expect(body(await s.studio.advance(id, 0))).toMatchObject({ status: "error", error: { code: "error.studio.unavailable" } });
    });
});

describe("engine on POST /studio and the \"first\" mode", () => {
    it("engine: \"ytdlp\" (the toggle) uses yt-dlp only: no cobalt, its own code when it fails", async () => {
        const s = setup();
        s.box.fetchError = "error.api.content.video.unavailable";
        const id = idOf(await create(s, { engine: "ytdlp" }));
        expect(s.box.calls[0]).toBe("POST /fetch");
        expect(await s.kv.get(`save:${id}`)).toMatchObject({ engine: "ytdlp", pinned: true });
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.api.content.video.unavailable" } });
        expect(s.helper.calls).toEqual([]);
        expect(s.starts).toEqual(["ytdlp"]);
    });

    it("engine: \"ytdlp\" saves with yt-dlp", async () => {
        const s = setup();
        const id = idOf(await create(s, { engine: "ytdlp" }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready", title: "Me at the zoo" });
        expect(s.helper.calls).toEqual([]);
    });

    it("engine: \"cobalt\" uses cobalt only", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s, { engine: "cobalt" }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
        expect(s.box.calls).toEqual([]);
    });

    it("\"first\" mode without an engine still falls back to cobalt", async () => {
        const s = setup({ mode: "first" });
        s.box.fetchError = "error.api.content.video.unavailable";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready" });
        expect(s.starts).toEqual(["ytdlp", "cobalt"]);
    });

    it("engine: \"cobalt\" in \"first\" mode keeps cobalt first", async () => {
        const s = setup({ mode: "first" });
        const id = idOf(await create(s, { engine: "cobalt" }));
        expect(body(await s.studio.advance(id, 0))).toMatchObject({ status: "ready" });
        expect(s.box.calls).toEqual([]);
    });

    it("\"first\" mode sends a plain save to the box, but never a save of picked items", async () => {
        const s = setup({ mode: "first" });
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 0))).toMatchObject({ status: "ready" });
        expect(s.helper.calls).toEqual([]);
        const s2 = setup({ mode: "first" });
        s2.helper.gallery = [{ type: "photo" }];
        idOf(await create(s2, { items: [0] }));
        expect(s2.box.calls).toEqual([]);
    });

    it("refuses an unknown engine, and yt-dlp with picked items", async () => {
        const s = setup();
        for (const engine of ["youtube-dl", 1, true, "YTDLP"]) {
            expect(await create(s, { engine })).toMatchObject({ status: 400, body: { error: { code: "error.studio.invalid_params" } } });
        }
        expect(await create(s, { engine: "ytdlp", items: [0, 1] })).toMatchObject({ status: 400 });
    });

    it("a queued save keeps its engine through the line", async () => {
        const s = setup();
        s.helper.fetchPolls = 1;
        const first = idOf(await create(s)); // holds the helper
        const queued = await create(s, { engine: "ytdlp", queue: true });
        expect(body(queued)).toMatchObject({ queued: true });
        expect(body(await s.studio.advance(first, 30)).status).toBe("ready");
        await s.studio.sweep(); // the line starts the next save
        expect(body(await s.studio.advance(idOf(queued), 30)).status).toBe("ready");
        expect(s.box.fetchBodies.map((b) => b.id)).toEqual([idOf(queued)]);
        expect(s.helper.fetchBodies.map((b) => b.id)).toEqual([first]);
    });
});

describe("link saves the app sends with items \"all\" (every app link save)", () => {
    it("cobalt failing hands the save to yt-dlp, which saves it as one file", async () => {
        const s = setup();
        s.helper.fetchError = "error.webp.bad_source";
        const id = idOf(await create(s, { items: "all", queue: true }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready", title: "Me at the zoo", bytes: 3000 });
        expect(s.box.fetchBodies.map((b) => b.id)).toEqual([id]);
        expect(s.items()).toHaveLength(1);
    });

    it("picked items stay cobalt's", async () => {
        const s = setup();
        s.helper.gallery = [{ type: "photo" }, { type: "photo" }];
        s.helper.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s, { items: [0, 1] }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "error" });
        expect(s.box.calls).toEqual([]);
        expect(await create(s, { items: [0], engine: "ytdlp" })).toMatchObject({ status: 400 });
    });

    it("the toggle (engine ytdlp) with items \"all\" saves with yt-dlp only", async () => {
        const s = setup();
        const id = idOf(await create(s, { items: "all", engine: "ytdlp" }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready" });
        expect(s.helper.calls).toEqual([]);
        const s2 = setup();
        s2.box.fetchError = "error.api.content.video.unavailable";
        const id2 = idOf(await create(s2, { items: "all", engine: "ytdlp" }));
        expect(body(await s2.studio.advance(id2, 30))).toMatchObject({ status: "error", error: { code: "error.api.content.video.unavailable" } });
        expect(s2.helper.calls).toEqual([]);
    });

    it("the toggle on a photo post (yt-dlp: no video) goes on with cobalt", async () => {
        const s = setup();
        s.box.fetchError = "error.webp.no_video";
        s.helper.gallery = [{ type: "photo" }, { type: "photo" }];
        const id = idOf(await create(s, { items: "all", engine: "ytdlp" }));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({ status: "ready" });
        expect(s.helper.fetchBodies[0]).toMatchObject({ id, items: "all" });
    });
});

describe("what GET /studio/<sid> says while a save runs (engine, waking_engine, fallback_*, error_detail)", () => {
    it("a yt-dlp save whose box is asleep says waking: true with waking_engine \"ytdlp\", then clears it once the box is up", async () => {
        const s = setup({ boxAsleep: true });
        const id = idOf(await create(s, { engine: "ytdlp" }));
        let b = body(await s.studio.advance(id, 0));
        expect(b).toMatchObject({ status: "saving", step: "fetching", waking: true, waking_engine: "ytdlp", engine: "ytdlp", fallback_from: null, fallback_code: null });
        // no fetch was sent to a box that is not up
        expect(s.box.calls).toEqual([]);
        s.wakeBox();
        b = body(await s.studio.advance(id, 0));
        expect(b).toMatchObject({ status: "saving", waking: false, waking_engine: null, engine: "ytdlp" });
        expect(s.box.calls[0]).toBe("POST /fetch");
    });

    it("a box that is already up, and a cobalt save, never say waking", async () => {
        const s = setup();
        s.box.fetchPolls = 1;
        const id = idOf(await create(s, { engine: "ytdlp" }));
        expect(body(await s.studio.advance(id, 0))).toMatchObject({ waking: false, waking_engine: null, engine: "ytdlp" });
        const c = setup();
        c.helper.fetchPolls = 1;
        const cid = idOf(await create(c));
        expect(body(await c.studio.advance(cid, 0))).toMatchObject({ waking: false, waking_engine: null, engine: "cobalt", fallback_from: null });
    });

    it("a cobalt failure that hands the save to yt-dlp is told: engine, fallback_from and fallback_code, kept through every step", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.fetchPolls = 2;
        s.box.fetchPendingFields = { stage: "downloading", bytes: 1000, total: 3000 };
        const id = idOf(await create(s));
        const switched = body(await s.studio.advance(id, 0));
        expect(switched).toMatchObject({ status: "saving", step: "fetching", waking: false, waking_engine: null, engine: "ytdlp", fallback_from: "cobalt", fallback_code: "error.api.fetch.fail" });
        expect(switched.step_bytes).toBeNull();
        await s.studio.advance(id, 0); // the fetch is accepted by the box
        const downloading = body(await s.studio.advance(id, 0));
        expect(downloading).toMatchObject({ step: "fetching", step_bytes: 1000, step_total: 3000, engine: "ytdlp", fallback_from: "cobalt", fallback_code: "error.api.fetch.fail" });
        let done = body(await s.studio.advance(id, 0));
        expect(done).toMatchObject({ status: "saving", engine: "ytdlp", fallback_from: "cobalt" });
        done = body(await s.studio.advance(id, 0));
        expect(done.status).toBe("ready");
        expect(done).not.toHaveProperty("engine"); // a finished session reads as before
    });

    it("a switch with the box asleep says so: waking for the box, with the fallback fields", async () => {
        const s = setup({ boxAsleep: true });
        s.helper.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s));
        await s.studio.advance(id, 0); // cobalt fails, the save switches
        const b = body(await s.studio.advance(id, 0)); // the box's turn: asleep
        expect(b).toMatchObject({ waking: true, waking_engine: "ytdlp", engine: "ytdlp", fallback_from: "cobalt", fallback_code: "error.api.fetch.fail" });
    });

    it("yt-dlp failing with a login ends with error.api.youtube.login, not cobalt's earlier code; error_detail carries both", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.fetch.fail";
        s.box.fetchError = "error.api.youtube.login";
        const id = idOf(await create(s));
        const b = body(await s.studio.advance(id, 30));
        expect(b).toMatchObject({
            status: "error",
            error: { code: "error.api.youtube.login" },
            error_detail: { primary_code: "error.api.youtube.login", primary_engine: "ytdlp", prior_code: "error.api.fetch.fail", prior_engine: "cobalt" },
        });
        expect(s.row(id)).toMatchObject({ status: "error", error_code: "error.api.youtube.login" });
    });

    it("the other actionable codes of yt-dlp win too (a private or age-gated post, a file too large)", async () => {
        for (const code of ["error.api.content.post.private", "error.api.content.post.age", "error.studio.too_large"]) {
            const s = setup();
            s.helper.fetchError = "error.api.fetch.fail";
            s.box.fetchError = code;
            const id = idOf(await create(s));
            expect(body(await s.studio.advance(id, 30)), code).toMatchObject({ status: "error", error: { code }, error_detail: { primary_code: code, prior_code: "error.api.fetch.fail" } });
        }
    });

    it("a generic yt-dlp failure still ends with cobalt's code (the words the app knows), the detail keeps what yt-dlp said", async () => {
        const s = setup();
        s.helper.fetchError = "error.api.link.unsupported";
        s.box.fetchError = "error.api.fetch.fail";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({
            status: "error",
            error: { code: "error.api.link.unsupported" },
            error_detail: { primary_code: "error.api.fetch.fail", primary_engine: "ytdlp", prior_code: "error.api.link.unsupported", prior_engine: "cobalt" },
        });
    });

    it("\"first\" mode: cobalt failing after yt-dlp keeps cobalt's own code, the detail names yt-dlp as the prior engine", async () => {
        const s = setup({ mode: "first" });
        s.box.fetchError = "error.api.fetch.fail";
        s.helper.fetchError = "error.api.link.unsupported";
        const id = idOf(await create(s));
        expect(body(await s.studio.advance(id, 30))).toMatchObject({
            status: "error",
            error: { code: "error.api.link.unsupported" },
            error_detail: { primary_code: "error.api.link.unsupported", primary_engine: "cobalt", prior_code: "error.api.fetch.fail", prior_engine: "ytdlp" },
        });
    });

    it("a save that failed on one engine has no error_detail and no fallback fields", async () => {
        const s = setup();
        s.helper.fetchError = "error.studio.too_large";
        const id = idOf(await create(s));
        const b = body(await s.studio.advance(id, 30));
        expect(b).toMatchObject({ status: "error", error: { code: "error.studio.too_large" } });
        expect(b).not.toHaveProperty("error_detail");
        expect(b).not.toHaveProperty("fallback_from");
    });
});
