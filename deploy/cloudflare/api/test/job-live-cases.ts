// The cases of test/fixtures/job-live-states.json: one job per kind and phase, built by the server's builders.
// The app's JobLiveState decodes every one (CobaltKit JobLiveTests), the parity pin of CONTRACT-JOBLIVE.
import { jobOfChat, jobOfEdit, jobOfSave, type Job } from "../src/job-live";
import type { RunAttributes } from "../src/live";

const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const T = 1790000000;
const link: RunAttributes = { run: RUN, input: "link", service: "twitch", ref: "KindStupidClip", origin: "share" };
const file: RunAttributes = { run: RUN, input: "file", service: "file", ref: "IMG_0412.mov", origin: "app" };
const base = { rail: 0, since: T, waking: false, packing: false };

export function jobCases(): Record<string, Job> {
    return {
        save_downloading: jobOfSave(link, { ...base, stage: "fetching", bytes: 4_200_000, total: 9_100_000 }, "save"),
        save_waking: jobOfSave(link, { ...base, stage: "fetching", waking: true }),
        save_storing: jobOfSave(link, { ...base, stage: "saving", rail: 1, bytes: 8_900_000, total: 8_900_000 }, "save"),
        save_done: jobOfSave(link, { ...base, stage: "done", rail: 1, resultWidth: 1280, resultHeight: 720, resultSeconds: 30, resultBytes: 8_900_000 }, "save"),
        save_failed: jobOfSave(link, { ...base, stage: "failed", rail: 0, code: "error.studio.fetch_failed" }),
        save_lost: jobOfSave(link, { ...base, stage: "failed", rail: 0, code: "error.live.lost" }, "save"),
        upload_uploading: jobOfSave(file, { ...base, stage: "uploading", bytes: 38_000_000, total: 96_000_000 }),
        app_reading: jobOfSave(file, { ...base, stage: "reading", rail: 2, framesDone: 40, framesTotal: 300 }),
        app_ready: jobOfSave(file, { ...base, stage: "ready", rail: 2, title: "IMG_0412.mov" }),
        app_webp: jobOfSave(link, { ...base, stage: "rendering", rail: 3, framesDone: 42, framesTotal: 150 }),
        make_working: jobOfSave(link, { ...base, stage: "rendering", rail: 3, framesDone: 42, framesTotal: 150, title: "a cat" }, "make"),
        make_done: jobOfSave(link, { ...base, stage: "done", rail: 3, resultURL: "https://media.capybaraharmony.com/PrEvIeW001.webp", resultWidth: 480, resultHeight: 854, resultSeconds: 10.1, resultBytes: 918_000 }, "make"),
        edit_queued: jobOfEdit("R3nd3rIdR3nd3rIdR3nd", { status: "queued", since: T, title: "birthday cut", queueAhead: 2 }),
        edit_rendering: jobOfEdit("R3nd3rIdR3nd3rIdR3nd", { status: "rendering", since: T, title: "birthday cut", progress: 0.63 }),
        edit_done: jobOfEdit("R3nd3rIdR3nd3rIdR3nd", { status: "done", since: T, title: "birthday cut", resultSeconds: 48, resultWidth: 1920, resultHeight: 1080, resultBytes: 96_000_000 }),
        edit_failed: jobOfEdit("R3nd3rIdR3nd3rIdR3nd", { status: "failed", since: T, title: "birthday cut", code: "error.edit.missing_clip" }),
        chat_tools: jobOfChat("thread01", "save that clip", { status: "working", since: T, steps: 3, failedSteps: 0, tool: "search, save, look", shown: 0 }),
        chat_done: jobOfChat("thread01", "save that clip", { status: "done", since: T, steps: 3, failedSteps: 0, reply: "saved it (=^･ω･^=) it's in your library now", shown: 1 }),
    };
}
