// Job hooks for the chat (APP-API-CONTRACT.md section 33.14): the chat AI hands a job it started (a webp, a slideshow, an
// editor render) to the server with cobalt.jobs.onDone(job) and ends its reply. The server watches the job and, when it
// ends, continues the chat on its own: a new assistant message with the result, written to D1 and shown on the Live
// Activity, without the model polling.
//
// The watcher is the ChatJobs Durable Object (chat-jobs-do.ts), one instance per chat thread. Its storage holds the
// watches; its alarm looks at each job server-side every CHAT_JOBS_TICK_MS (the same state jobs.wait reads, never the
// model) and runs the continuation in the alarm. Free of Cloudflare imports so it runs under node in the tests.
//
// Storage (per thread):
//   watch:<n>   JobWatch   a job still being watched (n: a counter, so a job id that changes while a file opens can be
//                          rewritten in place)
//   ended:<n>   JobEnded   a job that ended while a reply was still running in the thread; continued on a later tick
//   seq         number     the counter

export const CHAT_JOBS_TICK_MS = 4000;
// A watch nobody's job ended within this long ends as "timeout" (the longest editor render is well under it).
export const CHAT_JOBS_TTL_MS = 60 * 60 * 1000;
// Watches per thread at once.
export const CHAT_JOBS_MAX = 5;
// A job whose state cannot be read this many ticks in a row ends as an error.
export const CHAT_JOBS_MAX_MISSES = 15;
// A thread busy with another reply is tried again on each tick, for at most this long after the job ended.
export const CHAT_JOBS_BUSY_MS = 10 * 60 * 1000;
export const CHAT_JOBS_NOTE_MAX = 300;
export const CHAT_JOBS_JOB_MAX = 4100;
export const CHAT_JOBS_THREAD_REGEX = /^[A-Za-z0-9]{16}$/;
const INTERNAL_KEY_HEADER = "x-internal-key";

// What jobs.wait returns (make.ts JobSchema); only `job` and `status` are read here.
export type JobState = { job: string; status: string; [k: string]: unknown };
const TERMINAL = new Set(["done", "error", "cancelled"]);
export const isJobOver = (s: JobState) => TERMINAL.has(s.status);

export type JobWatch = {
    job: string;
    // the id the model handed over (the "job" step on its message carries it; `job` can change while a file opens)
    handed: string;
    thread: string;
    // the assistant message that handed the job over (its "job" step is updated when the job ends)
    message_id: string | null;
    // what the model meant to do with the result ("show it and give the share link")
    note: string | null;
    created_at: number;
    expires_at: number;
    misses: number;
    last: JobState | null;
};

export type JobEnded = { watch: JobWatch; result: JobState; ended_at: number };

// What a continuation came to: the reply ran ("done"), another reply is running ("busy", try again later), or the
// thread is gone or full ("gone", dropped).
export type ResumeOutcome = "done" | "busy" | "gone";

type Storage = {
    get<T>(key: string): Promise<T | undefined>;
    put(key: string, value: unknown): Promise<void>;
    delete(key: string): Promise<boolean>;
    list<T>(o: { prefix: string }): Promise<Map<string, T>>;
};

export type ChatJobsDeps = {
    storage: Storage;
    now: () => number;
    // arm the object's alarm this many ms from now
    setAlarm: (inMs: number) => Promise<void>;
    // the job's state right now, as the chat AI of this thread (no waiting)
    check: (thread: string, job: string) => Promise<JobState>;
    // continue the thread with these ended jobs
    resume: (thread: string, ended: JobEnded[]) => Promise<ResumeOutcome>;
};

export class ChatJobsCore {
    constructor(private d: ChatJobsDeps) {}

    // A new watch from the Worker. Answers an error code, or null when it is stored.
    async add(raw: unknown): Promise<string | null> {
        const b = raw as Partial<JobWatch> | null;
        if (
            !b ||
            typeof b.job !== "string" ||
            b.job.length === 0 ||
            b.job.length > CHAT_JOBS_JOB_MAX ||
            typeof b.thread !== "string" ||
            !CHAT_JOBS_THREAD_REGEX.test(b.thread) ||
            (b.message_id !== null && b.message_id !== undefined && (typeof b.message_id !== "string" || !/^\d{1,12}$/.test(b.message_id))) ||
            (b.note !== null && b.note !== undefined && (typeof b.note !== "string" || b.note.length > CHAT_JOBS_NOTE_MAX))
        ) {
            return "error.chat.bad_request";
        }
        const watches = await this.d.storage.list<JobWatch>({ prefix: "watch:" });
        for (const [k, w] of watches) {
            // the same job again: its newer message and note win
            if (w.job === b.job) {
                await this.d.storage.put(k, { ...w, message_id: b.message_id ?? w.message_id, note: b.note ?? w.note });
                return null;
            }
        }
        if (watches.size >= CHAT_JOBS_MAX) return "error.chat.jobs_full";
        const now = this.d.now();
        const seq = ((await this.d.storage.get<number>("seq")) ?? 0) + 1;
        await this.d.storage.put("seq", seq);
        const w: JobWatch = {
            job: b.job,
            handed: b.job,
            thread: b.thread,
            message_id: b.message_id ?? null,
            note: b.note ?? null,
            created_at: now,
            expires_at: now + CHAT_JOBS_TTL_MS,
            misses: 0,
            last: null,
        };
        await this.d.storage.put(`watch:${seq}`, w);
        await this.d.setAlarm(CHAT_JOBS_TICK_MS);
        return null;
    }

    // The watches as they stand (tests, debugging).
    async list(): Promise<JobWatch[]> {
        return [...(await this.d.storage.list<JobWatch>({ prefix: "watch:" })).values()];
    }

    // One alarm: look at every job, continue the thread with the ones that ended, re-arm while anything is left.
    async tick(): Promise<void> {
        const now = this.d.now();
        const fresh: [string, JobEnded][] = [];
        for (const [k, w] of await this.d.storage.list<JobWatch>({ prefix: "watch:" })) {
            let state: JobState | null = null;
            try {
                state = await this.d.check(w.thread, w.job);
            } catch (e) {
                console.error("[chat-jobs] check failed", w.job.slice(0, 60), String(e));
            }
            const misses = state ? 0 : w.misses + 1;
            let result: JobState | null = null;
            if (state && isJobOver(state)) result = state;
            else if (misses >= CHAT_JOBS_MAX_MISSES) result = { job: w.job, status: "error", error: "error.chat.job_unreadable" };
            else if (now >= w.expires_at) result = { ...(state ?? w.last ?? { job: w.job }), job: state?.job ?? w.job, status: "timeout" };
            if (result) {
                await this.d.storage.delete(k);
                const ended: JobEnded = { watch: { ...w, job: result.job || w.job }, result, ended_at: now };
                const ek = `ended:${k.slice("watch:".length)}`;
                await this.d.storage.put(ek, ended);
                fresh.push([ek, ended]);
            } else {
                // a file that opened started its job: keep the newest id
                await this.d.storage.put(k, { ...w, job: state?.job || w.job, misses, last: state ?? w.last });
            }
        }

        // every ended job, this tick's and earlier ones a busy thread held back, one continuation per thread
        const ended = await this.d.storage.list<JobEnded>({ prefix: "ended:" });
        const byThread = new Map<string, [string, JobEnded][]>();
        for (const [k, e] of ended) byThread.set(e.watch.thread, [...(byThread.get(e.watch.thread) ?? []), [k, e]]);
        for (const [thread, list] of byThread) {
            let outcome: ResumeOutcome;
            try {
                outcome = await this.d.resume(thread, list.map(([, e]) => e));
            } catch (e) {
                console.error("[chat-jobs] resume failed", String(e));
                outcome = "busy";
            }
            if (outcome === "busy" && list.every(([, e]) => now - e.ended_at < CHAT_JOBS_BUSY_MS)) continue;
            for (const [k] of list) await this.d.storage.delete(k);
        }

        const left = (await this.d.storage.list({ prefix: "watch:" })).size + (await this.d.storage.list({ prefix: "ended:" })).size;
        if (left > 0) await this.d.setAlarm(CHAT_JOBS_TICK_MS);
    }
}

// ---- the Durable Object's routes -----------------------------------------------------------------------------------
//   PUT /watch  <JobWatch fields>   from the Worker (x-internal-key)

export async function handleChatJobsRoute(core: ChatJobsCore, request: Request, internalKey: string): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.headers.get(INTERNAL_KEY_HEADER) !== internalKey || !internalKey) return new Response(null, { status: 403 });
    if (pathname === "/watch" && request.method === "PUT") {
        const code = await core.add(await request.json().catch(() => null));
        return code ? Response.json({ status: "error", error: { code } }, { status: code === "error.chat.jobs_full" ? 409 : 400 }) : Response.json({ status: "success" });
    }
    if (pathname === "/watch" && request.method === "GET") return Response.json({ status: "success", watches: await core.list() });
    return new Response(null, { status: 404 });
}

// ---- the Worker side ---------------------------------------------------------------------------------------------

export type JobsNamespace = {
    idFromName(name: string): unknown;
    get(id: unknown): { fetch(r: Request): Promise<Response> };
};

export type JobsPort = {
    // throws with the error code when the watch was refused
    watch(thread: string, w: { job: string; message_id: string | null; note: string | null }): Promise<void>;
};

export function jobsPort(ns: JobsNamespace, internalKey: string): JobsPort {
    return {
        async watch(thread, w) {
            const stub = ns.get(ns.idFromName(thread));
            const res = await stub.fetch(
                new Request("https://chat-jobs.internal/watch", {
                    method: "PUT",
                    headers: { "content-type": "application/json", [INTERNAL_KEY_HEADER]: internalKey },
                    body: JSON.stringify({ ...w, thread }),
                }),
            );
            const b = (await res.json().catch(() => null)) as { error?: { code?: string } } | null;
            if (!res.ok) throw new Error(b?.error?.code ?? `the job watcher answered ${res.status}`);
        },
    };
}
