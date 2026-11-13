import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { JOB_ATTRIBUTES_TYPE, JOB_STALE_S, asJobPayload, canonicalJob, isJobTerminal, jobOfSave } from "../src/job-live";
import { jobCases } from "./job-live-cases";

const FIX = JSON.parse(readFileSync(new URL("./fixtures/job-live-states.json", import.meta.url), "utf8"));

describe("job island states (CONTRACT-JOBLIVE 3)", () => {
    it("every case matches the fixture the app decodes, byte for byte", () => {
        expect(JSON.parse(JSON.stringify(jobCases()))).toEqual(FIX);
    });

    it("steps are only the real ones: a save is download then store, growing read and make only when it gets there", () => {
        const c = jobCases();
        expect(c.save_downloading!.state.steps).toEqual(["download", "store"]);
        expect(c.upload_uploading!.state.steps).toEqual(["upload", "store"]);
        expect(c.app_reading!.state.steps).toEqual(["upload", "store", "read"]);
        expect(c.app_webp!.state.steps).toEqual(["download", "store", "make"]);
        expect(c.make_working!.state.steps).toEqual(["make"]);
        expect(c.edit_rendering!.state).toMatchObject({ steps: ["prepare", "render", "save"], step: 1, compact: "63%" });
        expect(c.chat_tools!.state).toMatchObject({ steps: ["think", "tools", "write"], step: 1 });
    });

    it("done is past the last step; failed and lost keep the step they stopped on", () => {
        const c = jobCases();
        expect(c.save_done!.state).toMatchObject({ phase: "done", step: 2, headline: "saved", result: "1280×720 · 30 s · 8.9 MB" });
        expect(c.make_done!.state).toMatchObject({ phase: "done", step: 1, headline: "webp ready", link: "https://media.capybaraharmony.com/PrEvIeW001.webp" });
        expect(c.save_failed!.state).toMatchObject({ phase: "failed", step: 0, headline: "couldn't save", detail: "the link could not be fetched." });
        expect(c.save_lost!.state).toMatchObject({ phase: "lost", headline: "lost track of this save" });
        for (const k of ["save_done", "save_failed", "save_lost", "edit_done", "edit_failed", "chat_done"]) expect(isJobTerminal(jobCases()[k]!.state), k).toBe(true);
    });

    it("the agent flag and the kinds", () => {
        const c = jobCases();
        expect(c.save_downloading!.attributes).toEqual({ id: c.save_downloading!.attributes.id, kind: "save", title: "twitch · KindStupidClip", agent: true });
        expect(c.save_waking!.attributes.agent).toBe(false);
        expect(c.upload_uploading!.attributes).toMatchObject({ kind: "upload", title: "IMG_0412.mov" });
        expect(c.make_working!.attributes.kind).toBe("make");
    });

    it("caps the strings and the fraction; drops what is absent", () => {
        const s = canonicalJob({ phase: "working", steps: ["a"], step: 0, headline: "x".repeat(99), fraction: 1.7, since: 1, detail: undefined });
        expect(s.headline).toHaveLength(60);
        expect(s.headline.endsWith("…")).toBe(true);
        expect(s.fraction).toBe(1);
        expect("detail" in s).toBe(false);
    });

    it("asJobPayload re-dresses a payload: job content, the job type on a start, a stale date unless it ends", () => {
        const job = jobCases().save_downloading!;
        const start = asJobPayload({ aps: { event: "start", timestamp: 5, "attributes-type": "CobaltActivityAttributes", attributes: { run: "x" }, alert: { title: "t", body: "b" } } }, job, 5000);
        expect(start.aps).toMatchObject({ event: "start", "attributes-type": JOB_ATTRIBUTES_TYPE, attributes: job.attributes, "content-state": job.state, alert: { title: "t", body: "b" }, "stale-date": 5 + JOB_STALE_S });
        const end = asJobPayload({ aps: { event: "end", "dismissal-date": 9 } }, jobOfSave(job.attributes as never, { stage: "done", rail: 1, since: 1, waking: false, packing: false }), 5000);
        expect(end.aps["stale-date"]).toBeUndefined();
        expect(end.aps["dismissal-date"]).toBe(9);
    });
});
