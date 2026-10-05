// Scheduling of the job sweep (APP-API-CONTRACT.md section 6), kept apart from
// index.ts (which imports the Containers library and so cannot load under plain
// node) so the de-duplication and the re-arming are testable.
//
// The Durable Object calls scheduleSweepSoon() whenever a job or save is
// accepted; the Containers library's own scheduler (schedule(), run from its
// alarm loop) later calls the DO's sweepJobs(), which is runSweep(). A sweep
// that finds something still pending schedules the next one, so there is a
// pass every SWEEP_DELAY_S seconds exactly while something is pending, and
// nothing keeps the container awake otherwise.

import { CeilingError, raceCeiling } from "./ceiling";
import { LIVE_PUSH_MS, LIVE_SWEEP_DELAY_S } from "./live";
import type { SweepNotify } from "./notify";
import type { KV } from "./webp";

export { LIVE_SWEEP_DELAY_S };

// How often a sweep runs while something is pending.
export const SWEEP_DELAY_S = 5;
// A sweep already due within this long makes a new request a no-op.
export const SWEEP_DEDUPE_MS = 10_000;
// A whole pass is abandoned after this long (each item inside is capped at
// SWEEP_ITEM_MS in studio.ts; a pass with several items may legitimately take a
// few of those, but never more than this).
export const SWEEP_PASS_MS = 60_000;
// DO storage key: when the next scheduled sweep is due (ms since epoch).
export const SWEEP_KEY = "sweep:at";

export type SweepScheduler = {
    storage: KV;
    now: () => number;
    // The library's schedule(delaySeconds, "sweepJobs").
    schedule: (delaySeconds: number) => Promise<unknown>;
};

// Schedules a sweep unless one is already due within SWEEP_DEDUPE_MS. A stored
// time in the past is stale (the sweep never ran, e.g. the DO was evicted
// before the alarm) and is scheduled over. Returns whether it scheduled.
export async function scheduleSweepSoon(
    d: SweepScheduler,
    delayS: number = SWEEP_DELAY_S,
): Promise<boolean> {
    const now = d.now();
    const at = await d.storage.get<number>(SWEEP_KEY);
    if (at !== undefined && at >= now && at - now <= SWEEP_DEDUPE_MS) return false;
    await d.storage.put(SWEEP_KEY, now + delayS * 1000);
    await d.schedule(delayS);
    return true;
}

// What the sweep asks of the live service (live.ts LiveService): whether any run
// with an update token is waiting on a server step (then the next pass is 2 s away,
// so a backgrounded app or a closed share sheet still sees the counters move), and
// its housekeeping.
export type SweepLive = {
    hasActiveRuns(): Promise<boolean>;
    cleanup(now: number): Promise<void>;
    // Retries the end pushes that failed after their result was collected (the job is not
    // looked at again then). Answers when the next retry is due (null: none pending) so
    // the sweep re-arms for it even with nothing else pending. DO-only work.
    retryEnds?(now: number): Promise<{ nextInMs: number | null }>;
};

// A whole round of Hark notification retries is abandoned after this long.
export const SWEEP_NOTIFY_MS = 12_000;

// One scheduled sweep: forget the due time (this schedule has fired), run the
// pass, and re-arm while anything is still pending. A pass that throws counts
// as nothing pending (the budgets inside sweep() bound everything else; the
// next job or poll schedules a fresh one). Returns how many were pending.
//
// The Containers library awaits this inside alarm() before it checks sleepAfter,
// so the pass must always come back: it is raced against passMs (a pass that
// overruns is abandoned, not cancelled) and counts as one thing pending, so a
// slow container is looked at again; the budgets inside sweep() end that.
export async function runSweep(
    d: SweepScheduler,
    sweep: () => Promise<{ pending: number }>,
    passMs: number = SWEEP_PASS_MS,
    live?: SweepLive,
    notify?: SweepNotify,
): Promise<number> {
    await d.storage.delete(SWEEP_KEY);
    let pending = 0;
    try {
        pending = (await raceCeiling(sweep(), passMs, "sweep pass")).pending;
    } catch (e) {
        if (e instanceof CeilingError) pending = 1;
        console.error("[cobalt-do] sweep failed", String(e));
    }
    let delayS = SWEEP_DELAY_S;
    let endsInMs: number | null = null;
    if (live) {
        try {
            await raceCeiling(live.cleanup(d.now()), LIVE_PUSH_MS, "live cleanup");
        } catch (e) {
            console.error("[cobalt-do] live cleanup failed", String(e));
        }
        if (live.retryEnds) {
            try {
                endsInMs = (await raceCeiling(live.retryEnds(d.now()), LIVE_PUSH_MS, "live end retries")).nextInMs;
            } catch (e) {
                console.error("[cobalt-do] live end retries failed", String(e));
            }
        }
        if (pending > 0) {
            try {
                if (await raceCeiling(live.hasActiveRuns(), LIVE_PUSH_MS, "live active runs")) {
                    delayS = LIVE_SWEEP_DELAY_S;
                }
            } catch (e) {
                console.error("[cobalt-do] live active-run check failed", String(e));
            }
        }
    }
    // Hark notification retries (section 9): sent when due, and the next one re-arms the sweep
    // just like a pending end push.
    let notifyInMs: number | null = null;
    if (notify) {
        try {
            notifyInMs = (await raceCeiling(notify.retryDue(d.now()), SWEEP_NOTIFY_MS, "notify retries")).nextInMs;
        } catch (e) {
            // not re-armed: a pass that keeps failing must not keep the sweep (and so the
            // container) going for ever; the next job or poll arms it again
            console.error("[cobalt-do] notify retries failed", e instanceof Error ? e.name : "error");
        }
    }
    if (notifyInMs !== null) endsInMs = endsInMs === null ? notifyInMs : Math.min(endsInMs, notifyInMs);
    // A pending end retry re-arms the sweep for when it is due (at least 1 s, at most the
    // usual cadence) even when no job or save is pending.
    if (endsInMs !== null) {
        delayS = Math.min(delayS, Math.min(SWEEP_DELAY_S, Math.max(1, Math.ceil(endsInMs / 1000))));
    }
    if (pending > 0 || endsInMs !== null) await scheduleSweepSoon(d, delayS);
    return pending;
}
