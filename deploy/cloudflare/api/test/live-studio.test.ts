// The real StudioService wired to the real LiveService and a scripted Apple, the way
// index.ts wires them (one DO storage shared by both): a run registered for a session
// is pushed as the save and the render move, by client polls and by the sweep.
import { beforeAll, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import { LiveService } from "../src/live";
import { StudioService } from "../src/studio";
import { runSweep, scheduleSweepSoon, type SweepScheduler } from "../src/sweep";
import { WebpService } from "../src/webp";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { Apple, bad, makePem, ok } from "./apns-fakes";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";

const LINK = "https://www.instagram.com/p/Dd7P496wolG/";
const KEY_ID = "key-row-1";
const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const UPDATE = "cd".repeat(32);

let pem: string;
beforeAll(async () => {
    pem = await makePem();
});

function wire(apple = new Apple()) {
    const db = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: "https://media.capybaraharmony.com/",
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        db,
    });
    const live = new LiveService({
        storage: kv,
        db,
        now: clock.now,
        apns: new ApnsClient({
            keyP8: pem,
            keyId: "ABC123DEFG",
            teamId: "TEAM123456",
            bundleId: "com.capybaraharmony.cobalt",
            via: "worker",
            transport: apple.transport,
            now: clock.now,
            log: () => {},
        }),
    });
    const studio = new StudioService({
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
        live,
    });
    return { db, clock, kv, helper, apple, live, studio };
}

const register = (w: ReturnType<typeof wire>, sid: string, over: Record<string, unknown> = {}) =>
    w.live.putRun(
        KEY_ID,
        RUN,
        JSON.stringify({
            environment: "sandbox",
            update_token: UPDATE,
            session: sid,
            start: false,
            attributes: { run: RUN, input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "app" },
            state: { stage: "fetching", rail: 0, since: Math.floor(w.clock.t / 1000), waking: false, packing: false },
            ...over,
        }),
    );

describe("a save and a render, pushed", () => {
    it("fetch -> save -> (the device reads) -> render -> done: the island follows, and ends with the alert", async () => {
        const w = wire();
        const created = (await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string };
        const sid = created.id;
        expect((await register(w, sid)).status).toBe(200);
        w.apple.calls.length = 0;

        // the save: one poll finds the file, copies it into R2 and makes the session ready
        w.clock.t += 2000;
        w.helper.fetchPolls = 1;
        w.helper.fetchPendingFields = { stage: "downloading", bytes: 10, total: 4096 };
        await w.studio.advance(sid, 0); // pending: fetching (unchanged state: nothing to send)
        w.clock.t += 2000;
        const ready = (await w.studio.advance(sid, 0)).body as { status: string };
        expect(ready.status).toBe("ready");
        const stages = w.apple.pushes.map((p) => p.payload.aps["content-state"].stage);
        expect(stages).toEqual(["saving"]);
        expect(w.apple.pushes[0]!.payload.aps["content-state"]).toMatchObject({ rail: 1, bytes: 0, total: 4096, title: "x_2105237035271258436", duration: 9.6 });

        // the render
        w.clock.t += 5000;
        const job = ((await w.studio.render(sid, JSON.stringify({ start: 2, length: 5 }))).body as { job: string }).job;
        expect(w.apple.pushes.at(-1)!.payload.aps["content-state"]).toMatchObject({ stage: "rendering", rail: 3, title: "x_2105237035271258436", duration: 9.6 });
        expect(w.apple.pushes.at(-1)!.priority).toBe(10);

        w.helper.jobPolls = 1;
        w.helper.jobPendingFields = { phase: "decode", frames_done: 30, frames_total: 75 };
        w.clock.t += 2000;
        await w.studio.renderStatus(sid, job, 0);
        expect(w.apple.pushes.at(-1)!.payload.aps["content-state"]).toMatchObject({ stage: "rendering", framesDone: 30, framesTotal: 75, packing: false });

        w.clock.t += 2000;
        const done = (await w.studio.renderStatus(sid, job, 0)).body as { status: string; url: string };
        expect(done.status).toBe("success");
        const last = w.apple.pushes.at(-1)!;
        expect(last.payload.aps.event).toBe("end");
        expect(last.payload.aps["content-state"]).toMatchObject({ stage: "done", resultURL: done.url, resultBytes: 1500, resultWidth: 480, resultHeight: 560, resultSeconds: 5 });
        expect(last.payload.aps.alert).toEqual({ title: "webp ready", body: "instagram · 2 KB" });
        // every push went to the token the app reported, on the host it registered
        expect(new Set(w.apple.pushes.map((p) => p.token))).toEqual(new Set([UPDATE]));
        expect(new Set(w.apple.pushes.map((p) => p.host))).toEqual(new Set(["api.sandbox.push.apple.com"]));
    });

    it("a share-sheet run: push-to-start, then the token arrives, then the save fails", async () => {
        const w = wire();
        await w.live.putStartToken(KEY_ID, JSON.stringify({ token: "ef".repeat(32), environment: "sandbox" }));
        const sid = ((await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string }).id;
        const res = await register(w, sid, {
            start: true,
            update_token: null,
            attributes: { run: RUN, input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "share" },
        });
        expect(res.body).toEqual({ status: "success", pushing: true, started: true });
        expect(w.apple.pushes.at(-1)!.payload.aps.event).toBe("start");

        w.clock.t += 1500;
        w.helper.fetchError = "error.api.fetch.empty";
        w.helper.fetchPolls = 0;
        await w.studio.advance(sid, 0);
        await w.studio.advance(sid, 0);
        // no update token yet: the failure is stored, not sent
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["start"]);
        w.clock.t += 1000;
        await register(w, sid, { start: false, update_token: UPDATE, attributes: { run: RUN, input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "share" } });
        const last = w.apple.pushes.at(-1)!;
        expect(last.token).toBe(UPDATE);
        expect(last.payload.aps.event).toBe("end"); // a terminal state catches up as an end
        expect(last.payload.aps["content-state"]).toMatchObject({ stage: "failed", failure: "fetchFailed", code: "error.api.fetch.empty" });
        expect(last.payload.aps.alert).toEqual({ title: "cobalt couldn't finish", body: "open cobalt to see what happened." });
    });

    it("nobody polls: the sweep collects the render, and the pushes still go out, on a 2 s cadence", async () => {
        const w = wire();
        const sid = ((await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string }).id;
        await w.studio.advance(sid, 0);
        await w.studio.advance(sid, 0);
        await register(w, sid, { state: { stage: "ready", rail: 2, since: 1, waking: false, packing: false, duration: 9.6 } });
        w.clock.t += 5000;
        await w.studio.render(sid, JSON.stringify({ start: 2, length: 5 }));
        w.apple.calls.length = 0;

        const scheduled: number[] = [];
        const d: SweepScheduler = { storage: w.kv, now: w.clock.now, schedule: async (s) => void scheduled.push(s) };
        await scheduleSweepSoon(d);
        w.helper.jobPolls = 2;
        w.helper.jobPendingFields = { phase: "decode", frames_done: 10, frames_total: 75 };
        const passes: number[] = [];
        for (let i = 0; i < 3; i++) {
            w.clock.t += 2000;
            passes.push(await runSweep(d, () => w.studio.sweep(), undefined, w.live));
        }
        expect(passes).toEqual([1, 1, 0]);
        expect(scheduled).toEqual([5, 2, 2]); // 5 s from the start of the job, then 2 s while a live run waits
        const events = w.apple.pushes.map((p) => `${p.payload.aps.event}:${p.payload.aps["content-state"].stage}`);
        expect(events).toEqual(["update:rendering", "end:done"]);
    });
});

// finding 8 (review fixes, 2026-10-02): the sweep collects the render and records the
// result, after which it never looks at that job again. An `end` push that failed at
// that moment used to be retried only by a client poll.
describe("a failed end after the sweep collected the result", () => {
    it("is retried by the sweep itself, with nobody polling, and the sweep re-arms for it", async () => {
        const w = wire();
        const sid = ((await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string }).id;
        await w.studio.advance(sid, 0);
        await w.studio.advance(sid, 0);
        await register(w, sid, { state: { stage: "ready", rail: 2, since: 1, waking: false, packing: false, duration: 9.6 } });
        w.clock.t += 5000;
        await w.studio.render(sid, JSON.stringify({ start: 2, length: 5 }));
        w.apple.calls.length = 0;
        // the update goes, then the END fails (Apple 500), then Apple recovers
        w.apple.script = [ok(), bad(500, null), ok()];

        const scheduled: number[] = [];
        const d: SweepScheduler = { storage: w.kv, now: w.clock.now, schedule: async (s) => void scheduled.push(s) };
        await scheduleSweepSoon(d);
        w.helper.jobPolls = 2;
        w.helper.jobPendingFields = { phase: "decode", frames_done: 10, frames_total: 75 };
        const passes: number[] = [];
        for (let i = 0; i < 3; i++) {
            w.clock.t += 2000;
            passes.push(await runSweep(d, () => w.studio.sweep(), undefined, w.live));
        }
        expect(passes).toEqual([1, 1, 0]); // the third pass collected the result: nothing pending in the studio
        expect(w.apple.pushes.map((p) => `${p.payload.aps.event}:${p.payload.aps["content-state"].stage}`)).toEqual(["update:rendering", "end:done"]);
        expect(w.kv.m.get(`live:run:${RUN}`)).toMatchObject({ endedAt: null, endTries: 1 }); // the end did not get through
        // nothing is pending in the studio, yet the sweep was armed for the retry (5 s)
        expect(scheduled.at(-1)).toBe(5);
        expect(await w.kv.get("sweep:at")).toBe(w.clock.t + 5000);

        // no client polls; the next scheduled sweep retries the end and the run finishes
        w.clock.t += 5000;
        expect(await runSweep(d, () => w.studio.sweep(), undefined, w.live)).toBe(0);
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["update", "end", "end"]);
        expect(w.kv.m.get(`live:run:${RUN}`)).toMatchObject({ endedAt: w.clock.t });
        // and that is the end of it: no further arming, no further pushes
        const armed = scheduled.length;
        w.clock.t += 60_000;
        await runSweep(d, () => w.studio.sweep(), undefined, w.live);
        expect(scheduled).toHaveLength(armed);
        expect(w.apple.calls).toHaveLength(3);
    });
});
