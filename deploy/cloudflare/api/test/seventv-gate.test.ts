// The 7TV gate (APP-API-CONTRACT.md section 62.5): the pacing rules, the Durable Object's routes, and a port that never
// fails a call (no binding, an unreachable or broken object: the call goes ahead).
import { describe, expect, it } from "vitest";
import { GATE_SLOW_MS, GATE_WAIT_MAX_MS, GateCore, gateOf, handleGateRoute, retryAfterSeconds } from "../src/seventv-gate";

describe("GateCore", () => {
    it("hands out reads 200 ms apart and writes 1 s apart, each kind on its own", () => {
        let now = 1000;
        const g = new GateCore(() => now);
        expect([g.slot("read"), g.slot("read"), g.slot("read")]).toEqual([0, 200, 400]);
        expect([g.slot("write"), g.slot("write")]).toEqual([0, 1000]);
        now += 5000;
        expect(g.slot("read")).toBe(0);
    });

    it("half speed for a minute after a 429, and never a wait past the cap", () => {
        let now = 0;
        const g = new GateCore(() => now);
        g.slow();
        expect(g.slowed()).toBe(true);
        expect([g.slot("read"), g.slot("read")]).toEqual([0, 400]);
        now = GATE_SLOW_MS + 10_000;
        expect(g.slowed()).toBe(false);
        expect([g.slot("read"), g.slot("read")]).toEqual([0, 200]);
        for (let i = 0; i < 200; i++) g.slot("write");
        expect(g.slot("write")).toBe(GATE_WAIT_MAX_MS);
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
