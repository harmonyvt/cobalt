import { describe, expect, it } from "vitest";
import { capStaleInflight, STALE_INFLIGHT_MS } from "../src/stale-inflight";
import { discardLate, raceCeiling, CeilingError } from "../src/ceiling";

// A stand-in with the same two methods and fields as @cloudflare/containers 0.3.7's Container.
function fakeClass() {
    return class Fake {
        sleepAfterMs = 0;
        inflightRequests = 0;
        clock = { t: 0 };
        renewActivityTimeout() {
            this.sleepAfterMs = this.clock.t + 45_000;
        }
        isActivityExpired() {
            if (this.inflightRequests > 0) {
                this.renewActivityTimeout();
                return false;
            }
            return this.sleepAfterMs <= this.clock.t;
        }
    };
}

describe("capStaleInflight", () => {
    it("lets a container sleep once a leaked in-flight request has seen no activity for the stale window", () => {
        const Fake = fakeClass();
        const clock = { t: 0 };
        expect(capStaleInflight(Fake as any, STALE_INFLIGHT_MS, () => clock.t)).toBe(true);
        const c = new Fake();
        c.clock = clock;
        // a containerFetch: counted in flight and renewed, its body never read
        c.inflightRequests = 1;
        c.renewActivityTimeout();
        // the library's alarm checks every 45 s; without the patch this stays false for ever
        for (clock.t = 45_000; clock.t <= STALE_INFLIGHT_MS; clock.t += 45_000) expect(c.isActivityExpired()).toBe(false);
        clock.t = STALE_INFLIGHT_MS + 46_000;
        // the count is reset and the last check's renew has run out: it sleeps at this check
        expect(c.isActivityExpired()).toBe(true);
        expect(c.inflightRequests).toBe(0);
    });

    it("keeps a container awake while real activity renews it, however long", () => {
        const Fake = fakeClass();
        const clock = { t: 0 };
        capStaleInflight(Fake as any, STALE_INFLIGHT_MS, () => clock.t);
        const c = new Fake();
        c.clock = clock;
        c.inflightRequests = 1;
        for (clock.t = 0; clock.t < 3 * STALE_INFLIGHT_MS; clock.t += 20_000) {
            c.renewActivityTimeout(); // a long upload's keep-awake every 20 s
            expect(c.isActivityExpired()).toBe(false);
        }
        expect(c.inflightRequests).toBe(1);
    });

    it("leaves a class without the expected methods alone", () => {
        class Other {}
        expect(capStaleInflight(Other as any)).toBe(false);
    });
});

describe("raceCeiling", () => {
    it("cancels the body of a response that arrives after the ceiling", async () => {
        let cancelled = false;
        const body = new ReadableStream({ cancel: () => void (cancelled = true) });
        const late = new Promise<Response>((r) => setTimeout(() => r(new Response(body)), 30));
        await expect(raceCeiling(late, 5, "late call")).rejects.toBeInstanceOf(CeilingError);
        await new Promise((r) => setTimeout(r, 60));
        expect(cancelled).toBe(true);
    });

    it("does not touch a response that wins the race", async () => {
        let cancelled = false;
        const body = new ReadableStream({ start: (c) => (c.enqueue(new TextEncoder().encode("ok")), c.close()), cancel: () => void (cancelled = true) });
        const res = await raceCeiling(Promise.resolve(new Response(body)), 1000, "quick call");
        expect(await res.text()).toBe("ok");
        expect(cancelled).toBe(false);
    });

    it("uses the caller's error when given", async () => {
        const never = new Promise<Response>(() => {});
        await expect(raceCeiling(never, 5, "x", () => new Error("helper /x timed out after 5 ms"))).rejects.toThrow("helper /x timed out after 5 ms");
    });

    it("discardLate ignores values without a body", () => {
        expect(() => discardLate(null)).not.toThrow();
        expect(() => discardLate(42)).not.toThrow();
        expect(() => discardLate({ body: null })).not.toThrow();
    });
});
