// The chat's job watcher (APP-API-CONTRACT.md 33.14): ChatJobsCore's rules on a Map, with scripted job states and
// continuations. The whole path through a real reply is in make-ops.test.ts.
import { beforeEach, describe, expect, it } from "vitest";
import {
    CHAT_JOBS_BUSY_MS,
    CHAT_JOBS_MAX,
    CHAT_JOBS_MAX_MISSES,
    CHAT_JOBS_TICK_MS,
    CHAT_JOBS_TTL_MS,
    ChatJobsCore,
    handleChatJobsRoute,
    jobsPort,
    type JobEnded,
    type JobState,
    type ResumeOutcome,
} from "../src/chat-jobs";

const THREAD = "ThReAd0123456789";
const KEY = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

let clock: number;
let store: Map<string, unknown>;
let alarms: number[];
let states: Map<string, (JobState | Error)[]>;
let resumed: { thread: string; ended: JobEnded[] }[];
let outcome: ResumeOutcome;
let core: ChatJobsCore;

beforeEach(() => {
    clock = 1_800_000_000_000;
    store = new Map();
    alarms = [];
    states = new Map();
    resumed = [];
    outcome = "done";
    core = new ChatJobsCore({
        storage: {
            get: async <T,>(k: string) => store.get(k) as T | undefined,
            put: async (k, v) => void store.set(k, structuredClone(v)),
            delete: async (k) => store.delete(k),
            list: async <T,>(o: { prefix: string }) => new Map([...store].filter(([k]) => k.startsWith(o.prefix)) as [string, T][]),
        },
        now: () => clock,
        setAlarm: async (ms) => void alarms.push(ms),
        check: async (_t, job) => {
            const s = states.get(job)?.shift() ?? { job, status: "running" };
            if (s instanceof Error) throw s;
            return s;
        },
        resume: async (thread, ended) => {
            resumed.push({ thread, ended });
            return outcome;
        },
    });
});

const add = (job: string, over: Record<string, unknown> = {}) => core.add({ job, thread: THREAD, message_id: "7", note: null, ...over });

describe("ChatJobsCore", () => {
    it("checks what it stores", async () => {
        expect(await core.add(null)).toBe("error.chat.bad_request");
        expect(await add("")).toBe("error.chat.bad_request");
        expect(await add("j", { thread: "short" })).toBe("error.chat.bad_request");
        expect(await add("j", { message_id: "x" })).toBe("error.chat.bad_request");
        expect(await add("j", { note: "n".repeat(301) })).toBe("error.chat.bad_request");
        for (let i = 0; i < CHAT_JOBS_MAX; i++) expect(await add(`edit:${i}`)).toBeNull();
        // the same job again is not a new watch
        expect(await add("edit:0", { note: "later" })).toBeNull();
        expect(await add("edit:extra")).toBe("error.chat.jobs_full");
        expect((await core.list()).find((w) => w.job === "edit:0")?.note).toBe("later");
        expect(alarms).toEqual(Array(CHAT_JOBS_MAX).fill(CHAT_JOBS_TICK_MS));
    });

    it("keeps the newest job id while a file opens, then continues once it ends", async () => {
        await add("open:abc:plan", { note: "show it" });
        states.set("open:abc:plan", [{ job: "open:abc:plan", status: "opening" }, { job: "studio:abc:j1", status: "running" }]);
        await core.tick();
        await core.tick();
        expect((await core.list()).map((w) => [w.job, w.handed])).toEqual([["studio:abc:j1", "open:abc:plan"]]);
        states.set("studio:abc:j1", [{ job: "studio:abc:j1", status: "done", post_id: "P" }]);
        alarms = [];
        await core.tick();
        expect(resumed).toEqual([
            { thread: THREAD, ended: [expect.objectContaining({ result: { job: "studio:abc:j1", status: "done", post_id: "P" }, watch: expect.objectContaining({ handed: "open:abc:plan", note: "show it" }) })] },
        ]);
        expect(store.size).toBe(1); // only the counter
        expect(alarms).toEqual([]);
    });

    it("a busy thread is tried again on later ticks, and given up after a while", async () => {
        await add("edit:a");
        states.set("edit:a", [{ job: "edit:a", status: "error", error: "error.edit.timeout" }]);
        outcome = "busy";
        await core.tick();
        await core.tick();
        expect(resumed).toHaveLength(2);
        expect(alarms.at(-1)).toBe(CHAT_JOBS_TICK_MS);
        outcome = "done";
        await core.tick();
        expect(resumed).toHaveLength(3);
        expect([...store.keys()].filter((k) => k.startsWith("ended:"))).toEqual([]);

        await add("edit:b");
        states.set("edit:b", [{ job: "edit:b", status: "cancelled" }]);
        outcome = "busy";
        await core.tick();
        clock += CHAT_JOBS_BUSY_MS;
        await core.tick();
        expect([...store.keys()].filter((k) => k.startsWith("ended:") || k.startsWith("watch:"))).toEqual([]);
    });

    it("a job that never ends times out, and one that cannot be read ends as an error", async () => {
        await add("edit:slow");
        clock += CHAT_JOBS_TTL_MS;
        await core.tick();
        expect(resumed[0]!.ended[0]!.result).toMatchObject({ job: "edit:slow", status: "timeout" });

        await add("edit:lost");
        states.set("edit:lost", Array(CHAT_JOBS_MAX_MISSES).fill(new Error("down")));
        for (let i = 0; i < CHAT_JOBS_MAX_MISSES - 1; i++) await core.tick();
        expect(resumed).toHaveLength(1);
        await core.tick();
        expect(resumed[1]!.ended[0]!.result).toEqual({ job: "edit:lost", status: "error", error: "error.chat.job_unreadable" });
    });

    it("a thread that is gone drops its jobs; a failing continuation counts as busy", async () => {
        await add("edit:x");
        states.set("edit:x", [{ job: "edit:x", status: "done" }]);
        outcome = "gone";
        await core.tick();
        expect([...store.keys()]).toEqual(["seq"]);
    });
});

describe("the routes and the Worker's port", () => {
    it("only the Worker's internal key may add a watch", async () => {
        const put = (key: string, body: unknown) =>
            handleChatJobsRoute(core, new Request("https://chat-jobs.internal/watch", { method: "PUT", headers: { "x-internal-key": key }, body: JSON.stringify(body) }), KEY);
        expect((await put("nope", { job: "edit:a", thread: THREAD })).status).toBe(403);
        expect((await put(KEY, { job: "edit:a", thread: "bad" })).status).toBe(400);
        expect((await put(KEY, { job: "edit:a", thread: THREAD })).status).toBe(200);
        expect((await handleChatJobsRoute(core, new Request("https://chat-jobs.internal/other", { headers: { "x-internal-key": KEY } }), KEY)).status).toBe(404);

        const names: unknown[] = [];
        const port = jobsPort({ idFromName: (n) => (names.push(n), n), get: () => ({ fetch: (r) => handleChatJobsRoute(core, r, KEY) }) }, KEY);
        await port.watch(THREAD, { job: "edit:b", message_id: "9", note: "hi" });
        expect(names).toEqual([THREAD]);
        expect((await core.list()).map((w) => w.job).sort()).toEqual(["edit:a", "edit:b"]);
        await expect(port.watch("bad", { job: "edit:c", message_id: null, note: null })).rejects.toThrow("error.chat.bad_request");
    });
});

describe("a swarm agent's question (APP-API-CONTRACT 61.3)", () => {
    it("continues the thread with each new question once, and keeps watching the swarm", async () => {
        const job = "swarm:AbCdEfGh12345678";
        const ask = (id: number, agent: number) => ({ id, agent, text: `question ${id}` });
        states.set(job, [
            { job, status: "running" },
            { job, status: "running", asks: [ask(4, 2)] },
            { job, status: "running", asks: [ask(4, 2)] },
            { job, status: "running", asks: [ask(4, 2), ask(9, 3)] },
            { job, status: "done", result: "2 of 2 tasks done" },
        ]);
        expect(await add(job)).toBeNull();
        await core.tick();
        expect(resumed).toHaveLength(0);
        await core.tick();
        expect(resumed).toHaveLength(1);
        expect(resumed[0]!.ended[0]!.result).toMatchObject({ status: "message", asks: [ask(4, 2)] });
        await core.tick();
        expect(resumed).toHaveLength(1); // the same question is not handed over twice
        await core.tick();
        expect(resumed[1]!.ended[0]!.result.asks).toEqual([ask(9, 3)]);
        expect(await core.list()).toHaveLength(1);
        await core.tick();
        expect(resumed[2]!.ended[0]!.result.status).toBe("done");
        expect(await core.list()).toHaveLength(0);
    });
});
