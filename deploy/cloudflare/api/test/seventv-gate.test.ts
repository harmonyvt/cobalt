// The 7TV gate (APP-API-CONTRACT.md section 62.5): the pacing rules, the Durable Object's routes, and a port that never
// fails a call (no binding, an unreachable or broken object: the call goes ahead).
import { describe, expect, it } from "vitest";
import { GATE_ROUNDS_MAX, GATE_SLOW_MS, GATE_WAIT_MAX_MS, GateCore, gateOf, handleGateRoute, retryAfterSeconds } from "../src/seventv-gate";

describe("GateCore", () => {
    it("hands out reads 200 ms apart and writes 1 s apart, each kind on its own", () => {
        let now = 1000;
        const g = new GateCore(() => now);
        const w = (k: "read" | "write") => g.slot(k).wait;
        expect([w("read"), w("read"), w("read")]).toEqual([0, 200, 400]);
        expect([w("write"), w("write")]).toEqual([0, 1000]);
        now += 5000;
        expect(g.slot("read")).toEqual({ wait: 0 });
    });

    it("half speed for a minute after a 429, and never a wait past the cap", () => {
        let now = 0;
        const g = new GateCore(() => now);
        g.slow();
        expect(g.slowed()).toBe(true);
        expect([g.slot("read").wait, g.slot("read").wait]).toEqual([0, 400]);
        now = GATE_SLOW_MS + 10_000;
        expect(g.slowed()).toBe(false);
        expect([g.slot("read").wait, g.slot("read").wait]).toEqual([0, 200]);
    });

    it("a burst never reserves past the longest wait: the overflow is told to come back, and the pace holds", () => {
        let now = 0;
        const g = new GateCore(() => now);
        const out = Array.from({ length: 200 }, () => g.slot("write"));
        // 31 slots fit in 30 s (0, 1 s, ... 30 s); the rest wait the most and ask again
        expect(out.filter((x) => !x.retry).map((x) => x.wait)).toEqual(Array.from({ length: 31 }, (_, i) => i * 1000));
        expect(out.filter((x) => x.retry)).toHaveLength(169);
        expect(out.at(-1)).toEqual({ wait: GATE_WAIT_MAX_MS, retry: true });
        // 30 s later the queue is not minutes ahead: the next slot is 1 s out, not 170 s
        now = GATE_WAIT_MAX_MS;
        expect(g.slot("write")).toEqual({ wait: 1000 });
    });
});

describe("the gate's routes and port", () => {
    it("POST /slot?kind answers the wait; /slow slows; anything else is refused", async () => {
        const g = new GateCore(() => 0);
        const post = (p: string, method = "POST") => handleGateRoute(g, new Request(`https://gate.internal${p}`, { method }));
        expect(await (await post("/slot?kind=read")).json()).toEqual({ wait: 0 });
        expect(await (await post("/slot?kind=read")).json()).toEqual({ wait: 200 });
        expect((await post("/slot?kind=other")).status).toBe(400);
        expect((await post("/slot?kind=read", "GET")).status).toBe(405);
        expect(await (await post("/slow")).json()).toEqual({ slowed: true });
        expect(g.slowed()).toBe(true);
        expect((await post("/nope")).status).toBe(404);
    });

    it("gateOf: null without the binding; one port per namespace; sleeps the wait; fails open", async () => {
        expect(gateOf({})).toBeNull();
        expect(gateOf({ SEVENTV_GATE: "x" })).toBeNull();
        const core = new GateCore(() => 0);
        const names: string[] = [];
        let broken = false;
        const ns = {
            idFromName: (n: string) => (names.push(n), n),
            get: () => ({
                fetch: async (r: Request) => {
                    if (broken) throw new Error("gone");
                    return handleGateRoute(core, r);
                },
            }),
        };
        const slept: number[] = [];
        const port = gateOf({ SEVENTV_GATE: ns }, async (ms) => void slept.push(ms))!;
        expect(gateOf({ SEVENTV_GATE: ns })).toBe(port);
        await port.slot("read");
        await port.slot("read");
        await port.slow();
        await port.slot("read");
        expect(slept).toEqual([200, 400]);
        expect(names.every((n) => n === "gate")).toBe(true);
        // told to come back: asks again, at most GATE_ROUNDS_MAX times, then goes ahead
        slept.length = 0;
        let asked = 0;
        const full = { idFromName: (n: string) => n, get: () => ({ fetch: async () => (asked++, Response.json({ wait: GATE_WAIT_MAX_MS, retry: true })) }) };
        await gateOf({ SEVENTV_GATE: full }, async (ms) => void slept.push(ms))!.slot("read");
        expect(asked).toBe(GATE_ROUNDS_MAX);
        expect(slept).toEqual(Array(GATE_ROUNDS_MAX).fill(GATE_WAIT_MAX_MS));
        slept.length = 0;
        slept.push(200, 400);
        broken = true;
        await expect(port.slot("write")).resolves.toBeUndefined();
        await expect(port.slow()).resolves.toBeUndefined();
        expect(slept).toEqual([200, 400]);
    });

    it("retryAfterSeconds reads seconds or an HTTP date, capped at 10 minutes", () => {
        const now = Date.parse("2026-11-15T12:00:00Z");
        expect(retryAfterSeconds("7", now)).toBe(7);
        expect(retryAfterSeconds("9999", now)).toBe(600);
        expect(retryAfterSeconds("Sun, 15 Nov 2026 12:00:30 GMT", now)).toBe(30);
        expect(retryAfterSeconds("Sun, 15 Nov 2026 11:00:00 GMT", now)).toBe(0);
        expect(retryAfterSeconds(null, now)).toBeNull();
        expect(retryAfterSeconds("soon", now)).toBeNull();
    });
});
