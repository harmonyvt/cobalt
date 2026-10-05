// The scheduling of the job sweep (src/sweep.ts): what CobaltContainer wires to
// the Containers library's schedule(). The pass itself is tested in studio.test.ts.
import { describe, expect, it } from "vitest";
import {
    LIVE_SWEEP_DELAY_S,
    SWEEP_DEDUPE_MS,
    SWEEP_DELAY_S,
    SWEEP_KEY,
    SWEEP_PASS_MS,
    runSweep,
    scheduleSweepSoon,
    type SweepLive,
    type SweepScheduler,
} from "../src/sweep";
import { Clock, MemoryKV } from "./studio-fakes";

function fixture() {
    const clock = new Clock();
    const storage = new MemoryKV();
    const scheduled: number[] = [];
    const d: SweepScheduler = {
        storage,
        now: clock.now,
        schedule: async (s) => {
            scheduled.push(s);
        },
    };
    return { clock, storage, scheduled, d };
}

describe("scheduleSweepSoon", () => {
    it("schedules a sweep in 5 s and remembers when it is due", async () => {
        const f = fixture();
        expect(await scheduleSweepSoon(f.d)).toBe(true);
        expect(f.scheduled).toEqual([SWEEP_DELAY_S]);
        expect(SWEEP_DELAY_S).toBe(5);
        expect(await f.storage.get(SWEEP_KEY)).toBe(f.clock.t + 5000);
    });
    it("does nothing while a sweep is already due within 10 s (many jobs ask, one schedule)", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        for (let i = 0; i < 5; i++) {
            f.clock.t += 1000;
            expect(await scheduleSweepSoon(f.d)).toBe(false);
        }
        expect(f.scheduled).toEqual([5]);
    });
    it("schedules again once the remembered time has passed without the sweep running (stale key)", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        f.clock.t += 5001; // the due time is now in the past: the alarm never fired
        expect(await scheduleSweepSoon(f.d)).toBe(true);
        expect(f.scheduled).toEqual([5, 5]);
        expect(await f.storage.get(SWEEP_KEY)).toBe(f.clock.t + 5000);
    });
    it("a due time further than 10 s away does not count as 'due within 10 s'", async () => {
        const f = fixture();
        await f.storage.put(SWEEP_KEY, f.clock.t + SWEEP_DEDUPE_MS + 1);
        expect(await scheduleSweepSoon(f.d)).toBe(true);
    });
    it("a scheduler that throws surfaces to the caller (the services swallow it)", async () => {
        const f = fixture();
        f.d.schedule = async () => {
            throw new Error("no alarms");
        };
        await expect(scheduleSweepSoon(f.d)).rejects.toThrow("no alarms");
    });
});

describe("runSweep", () => {
    it("forgets the due time, runs the pass and does not re-arm when nothing is pending", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        f.scheduled.length = 0;
        f.clock.t += 5000;
        expect(await runSweep(f.d, async () => ({ pending: 0 }))).toBe(0);
        expect(await f.storage.get(SWEEP_KEY)).toBeUndefined();
        expect(f.scheduled).toEqual([]);
    });
    it("re-arms itself in 5 s while anything is pending, and stops when the last thing finishes", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        const passes = [2, 1, 0];
        const log: number[] = [];
        // the library's alarm loop: run a due sweep, which may schedule the next
        for (let i = 0; i < passes.length; i++) {
            f.clock.t += 5000;
            log.push(await runSweep(f.d, async () => ({ pending: passes[i]! })));
        }
        expect(log).toEqual([2, 1, 0]);
        expect(f.scheduled).toEqual([5, 5, 5]); // the first ask + a re-arm after each pending pass
        expect(await f.storage.get(SWEEP_KEY)).toBeUndefined();
    });
    it("the re-arm is not swallowed by the de-duplication of its own run", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        f.clock.t += 5000;
        await runSweep(f.d, async () => ({ pending: 1 }));
        expect(f.scheduled).toEqual([5, 5]);
        expect(await f.storage.get(SWEEP_KEY)).toBe(f.clock.t + 5000);
    });
    it("a pass that throws counts as nothing pending and never throws out of the alarm", async () => {
        const f = fixture();
        await scheduleSweepSoon(f.d);
        f.scheduled.length = 0;
        expect(
            await runSweep(f.d, async () => {
                throw new Error("boom");
            }),
        ).toBe(0);
        expect(f.scheduled).toEqual([]);
        // the next job that starts schedules a fresh one
        expect(await scheduleSweepSoon(f.d)).toBe(true);
    });
    describe("the whole pass is capped, so alarm() always returns (finding 2)", () => {
        it("the default cap is 60 s", () => {
            expect(SWEEP_PASS_MS).toBe(60_000);
        });
        it("a pass that never finishes is abandoned at the cap: counted as one pending thing (re-armed), never thrown", async () => {
            const f = fixture();
            await scheduleSweepSoon(f.d);
            f.scheduled.length = 0;
            const t0 = Date.now();
            const pending = await runSweep(f.d, () => new Promise(() => {}), 30);
            expect(Date.now() - t0).toBeLessThan(2000);
            expect(pending).toBe(1);
            expect(f.scheduled).toEqual([5]); // looked at again; the budgets inside sweep() end it
        });
        it("a pass that finishes inside the cap is unaffected", async () => {
            const f = fixture();
            f.clock.t += 5000;
            expect(await runSweep(f.d, async () => ({ pending: 0 }), 30)).toBe(0);
            expect(f.scheduled).toEqual([]);
        });
    });
});

// The cadence while a run with an update token waits on a server step
// (APP-API-CONTRACT.md 8.3): every 2 s instead of 5.
describe("the live cadence", () => {
    const liveFake = (active: boolean | (() => Promise<boolean>)) => {
        const calls: string[] = [];
        const live: SweepLive = {
            hasActiveRuns: async () => {
                calls.push("active");
                return typeof active === "function" ? active() : active;
            },
            cleanup: async (now) => {
                calls.push(`cleanup@${now}`);
            },
        };
        return { live, calls };
    };

    it("the constants: 5 s as before, 2 s for live runs", () => {
        expect(SWEEP_DELAY_S).toBe(5);
        expect(LIVE_SWEEP_DELAY_S).toBe(2);
    });
    it("scheduleSweepSoon takes the delay: it is scheduled and remembered as that many seconds away", async () => {
        const f = fixture();
        expect(await scheduleSweepSoon(f.d, 2)).toBe(true);
        expect(f.scheduled).toEqual([2]);
        expect(await f.storage.get(SWEEP_KEY)).toBe(f.clock.t + 2000);
    });
    it("re-arms in 2 s while something is pending and a live run is active", async () => {
        const f = fixture();
        const { live } = liveFake(true);
        f.clock.t += 5000;
        expect(await runSweep(f.d, async () => ({ pending: 1 }), undefined, live)).toBe(1);
        expect(f.scheduled).toEqual([2]);
        expect(await f.storage.get(SWEEP_KEY)).toBe(f.clock.t + 2000);
    });
    it("re-arms in 5 s while something is pending and no live run is active", async () => {
        const f = fixture();
        const { live } = liveFake(false);
        await runSweep(f.d, async () => ({ pending: 2 }), undefined, live);
        expect(f.scheduled).toEqual([5]);
    });
    it("without a live service (or its question failing) the cadence is the old 5 s", async () => {
        const f = fixture();
        await runSweep(f.d, async () => ({ pending: 1 }));
        expect(f.scheduled).toEqual([5]);
        const g = fixture();
        const { live } = liveFake(async () => {
            throw new Error("storage blip");
        });
        await runSweep(g.d, async () => ({ pending: 1 }), undefined, live);
        expect(g.scheduled).toEqual([5]);
    });
    it("nothing pending: no re-arm at all, however many live runs there are (a finished run needs no sweep)", async () => {
        const f = fixture();
        const { live, calls } = liveFake(true);
        expect(await runSweep(f.d, async () => ({ pending: 0 }), undefined, live)).toBe(0);
        expect(f.scheduled).toEqual([]);
        expect(calls).not.toContain("active"); // not even asked
    });
    it("runs the live cleanup in the same pass, with the pass's time, and a failing cleanup changes nothing", async () => {
        const f = fixture();
        const { live, calls } = liveFake(true);
        f.clock.t += 5000;
        await runSweep(f.d, async () => ({ pending: 1 }), undefined, live);
        expect(calls[0]).toBe(`cleanup@${f.clock.t}`);
        const g = fixture();
        const bad: SweepLive = {
            hasActiveRuns: async () => true,
            cleanup: async () => {
                throw new Error("boom");
            },
        };
        await runSweep(g.d, async () => ({ pending: 1 }), undefined, bad);
        expect(g.scheduled).toEqual([2]);
    });
    it("a hung live question cannot hold the alarm: it is abandoned and the old cadence used", async () => {
        const f = fixture();
        const hang: SweepLive = { hasActiveRuns: () => new Promise(() => {}), cleanup: async () => {} };
        const t0 = Date.now();
        // LIVE_PUSH_MS (3 s) is the ceiling; this test only needs the pass to come back, so it is
        // bounded by that and nothing else
        const p = await runSweep(f.d, async () => ({ pending: 1 }), undefined, hang);
        expect(Date.now() - t0).toBeLessThan(5000);
        expect(p).toBe(1);
        expect(f.scheduled).toEqual([5]);
    }, 10_000);
    it("the re-armed 2 s sweep is not swallowed by the de-duplication of its own run", async () => {
        const f = fixture();
        const { live } = liveFake(true);
        await scheduleSweepSoon(f.d); // due in 5 s
        f.clock.t += 5000;
        await runSweep(f.d, async () => ({ pending: 1 }), undefined, live);
        expect(f.scheduled).toEqual([5, 2]);
        // a poll that asks for a sweep while the 2 s one is due is a no-op
        expect(await scheduleSweepSoon(f.d)).toBe(false);
    });
});

// Failed `end` pushes (review fixes, 2026-10-02): the sweep retries them and re-arms for
// the retry even when no job or save is pending.
describe("the live end retries", () => {
    const withRetry = (nextInMs: number | null | (() => Promise<never>)) => {
        const calls: string[] = [];
        const live: SweepLive = {
            hasActiveRuns: async () => {
                calls.push("active");
                return false;
            },
            cleanup: async () => {
                calls.push("cleanup");
            },
            retryEnds: async (now) => {
                calls.push(`retry@${now}`);
                if (typeof nextInMs === "function") return nextInMs();
                return { nextInMs };
            },
        };
        return { live, calls };
    };

    it("runs retryEnds in the pass, with the pass's time", async () => {
        const f = fixture();
        const { live, calls } = withRetry(null);
        f.clock.t += 5000;
        await runSweep(f.d, async () => ({ pending: 0 }), undefined, live);
        expect(calls).toContain(`retry@${f.clock.t}`);
    });
    it("nothing pending in the studio but a retry due in 5 s: re-arms in 5 s (and still reports 0 pending)", async () => {
        const f = fixture();
        const { live } = withRetry(5000);
        expect(await runSweep(f.d, async () => ({ pending: 0 }), undefined, live)).toBe(0);
        expect(f.scheduled).toEqual([5]);
    });
    it("a retry due sooner re-arms sooner (at least 1 s, rounded up); a farther one waits at most the usual 5 s", async () => {
        for (const [ms, want] of [
            [0, 1],
            [400, 1],
            [1200, 2],
            [4999, 5],
            [40_000, 5],
        ] as const) {
            const f = fixture();
            await runSweep(f.d, async () => ({ pending: 0 }), undefined, withRetry(ms).live);
            expect(f.scheduled, `${ms} ms`).toEqual([want]);
        }
    });
    it("no retry pending and nothing else pending: no re-arm", async () => {
        const f = fixture();
        await runSweep(f.d, async () => ({ pending: 0 }), undefined, withRetry(null).live);
        expect(f.scheduled).toEqual([]);
    });
    it("a pending retry never slows the 2 s live cadence, and a pending job never delays a retry", async () => {
        const f = fixture();
        const live: SweepLive = { hasActiveRuns: async () => true, cleanup: async () => {}, retryEnds: async () => ({ nextInMs: 4000 }) };
        await runSweep(f.d, async () => ({ pending: 1 }), undefined, live);
        expect(f.scheduled).toEqual([2]);
        const g = fixture();
        await runSweep(g.d, async () => ({ pending: 1 }), undefined, { ...live, hasActiveRuns: async () => false, retryEnds: async () => ({ nextInMs: 1500 }) });
        expect(g.scheduled).toEqual([2]);
    });
    it("a failing or hung retry changes nothing about the pass (it comes back, the old cadence applies)", async () => {
        const f = fixture();
        const boom = withRetry(async () => {
            throw new Error("storage blip");
        });
        await runSweep(f.d, async () => ({ pending: 1 }), undefined, boom.live);
        expect(f.scheduled).toEqual([5]);
        const g = fixture();
        const hang: SweepLive = { hasActiveRuns: async () => false, cleanup: async () => {}, retryEnds: () => new Promise(() => {}) };
        const t0 = Date.now();
        expect(await runSweep(g.d, async () => ({ pending: 0 }), undefined, hang)).toBe(0);
        expect(Date.now() - t0).toBeLessThan(5000);
        expect(g.scheduled).toEqual([]);
    }, 10_000);
    it("a live service without retryEnds (the old shape) is unaffected", async () => {
        const f = fixture();
        const old: SweepLive = { hasActiveRuns: async () => false, cleanup: async () => {} };
        await runSweep(f.d, async () => ({ pending: 0 }), undefined, old);
        expect(f.scheduled).toEqual([]);
    });
});

// ---- Hark notification retries (APP-API-CONTRACT.md section 9) ------------------------------

describe("runSweep: notification retries", () => {
    const notify = (nextInMs: number | null) => ({ retryDue: async () => ({ nextInMs }) });

    it("a pending retry re-arms the sweep with nothing else pending, at most the usual cadence", async () => {
        const f = fixture();
        expect(await runSweep(f.d, async () => ({ pending: 0 }), undefined, undefined, notify(3000))).toBe(0);
        expect(f.scheduled).toEqual([3]);
        const g = fixture();
        await runSweep(g.d, async () => ({ pending: 0 }), undefined, undefined, notify(20_000));
        expect(g.scheduled).toEqual([SWEEP_DELAY_S]);
        const h = fixture();
        await runSweep(h.d, async () => ({ pending: 0 }), undefined, undefined, notify(0));
        expect(h.scheduled).toEqual([1]); // never faster than one second
    });
    it("nothing pending: the sweep goes quiet", async () => {
        const f = fixture();
        await runSweep(f.d, async () => ({ pending: 0 }), undefined, undefined, notify(null));
        expect(f.scheduled).toEqual([]);
    });
    it("it never slows the 2 s live cadence, and pending jobs keep their own", async () => {
        const f = fixture();
        const live: SweepLive = { hasActiveRuns: async () => true, cleanup: async () => {} };
        await runSweep(f.d, async () => ({ pending: 1 }), undefined, live, notify(4000));
        expect(f.scheduled).toEqual([2]);
        const g = fixture();
        await runSweep(g.d, async () => ({ pending: 1 }), undefined, undefined, notify(null));
        expect(g.scheduled).toEqual([SWEEP_DELAY_S]);
    });
    it("a throwing retry pass changes nothing: it comes back, and does not re-arm itself for ever", async () => {
        const f = fixture();
        await runSweep(f.d, async () => ({ pending: 0 }), undefined, undefined, {
            retryDue: async () => {
                throw new Error("storage blip");
            },
        });
        expect(f.scheduled).toEqual([]);
    });
});
