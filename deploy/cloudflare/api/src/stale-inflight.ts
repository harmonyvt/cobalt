// A backstop for container sleep (cost: the cobalt container stayed awake 4-22 h a day in November 2026).
//
// The Containers library (@cloudflare/containers 0.3.x) counts every containerFetch as "in flight" until its response
// body has been read to the end or cancelled, and while the count is above zero `isActivityExpired()` renews the sleep
// timer instead of letting the container sleep. One response whose body nobody reads (a call that lost a race against
// our own timeout, a status check that never touched the body) therefore keeps the container, and the Durable Object
// waiting on it in its alarm loop, awake until the object is evicted: on 2026-11-19 that was 17 hours.
//
// raceCeiling() now cancels late bodies, but any other dropped body would bring the bill back. So this patch on the
// library's prototype stops trusting the count once nothing has really happened for `staleMs`: no new containerFetch,
// no WebSocket message, no renew from our own long jobs (they all call renewActivityTimeout(); the long uploads and
// streams renew every 20 s). Then the count is reset and the normal sleepAfter applies. A request that really was
// still running and ends later only decrements a count already at zero (the library clamps it).
//
// Free of Cloudflare imports so the tests run it under node with a fake class.

/** Longer than any single container call we make without renewing (the bulk helper calls stop at 300 s). */
export const STALE_INFLIGHT_MS = 10 * 60 * 1000;

type Patchable = {
    prototype: {
        renewActivityTimeout(): void;
    };
};

type Instance = {
    inflightRequests?: number;
    renewActivityTimeout(): void;
    __lastRealActivity?: number;
    __checkingExpiry?: boolean;
    __staleLogged?: number;
};

const PATCHED = Symbol.for("cobalt.staleInflightPatched");

/**
 * Patches the Containers library's Container class once (every subclass shares it). Returns false when the library's
 * shape is not what this expects (a newer version renamed things), and then changes nothing.
 */
export function capStaleInflight(cls: Patchable, staleMs: number = STALE_INFLIGHT_MS, now: () => number = Date.now): boolean {
    const proto = cls.prototype as unknown as Record<string | symbol, unknown>;
    if (proto[PATCHED]) return true;
    const renew = proto.renewActivityTimeout;
    const expired = proto.isActivityExpired;
    if (typeof renew !== "function" || typeof expired !== "function") {
        console.error("[containers] stale in-flight guard not installed: library shape changed");
        return false;
    }
    proto.renewActivityTimeout = function (this: Instance) {
        // the library renews from inside isActivityExpired while anything is in flight: that is not activity
        if (!this.__checkingExpiry) this.__lastRealActivity = now();
        return (renew as () => void).call(this);
    };
    proto.isActivityExpired = function (this: Instance) {
        const inflight = this.inflightRequests ?? 0;
        if (inflight > 0) {
            const last = this.__lastRealActivity;
            if (last === undefined) {
                // a fresh object (the alarm after an eviction): start the clock now
                this.__lastRealActivity = now();
            } else if (now() - last > staleMs) {
                if (this.__staleLogged !== last) {
                    this.__staleLogged = last;
                    console.warn(
                        "[containers] in-flight count stuck",
                        JSON.stringify({ inflight, idle_s: Math.round((now() - last) / 1000) }),
                    );
                }
                this.inflightRequests = 0;
            }
        }
        this.__checkingExpiry = true;
        try {
            return (expired as () => boolean).call(this);
        } finally {
            this.__checkingExpiry = false;
        }
    };
    proto[PATCHED] = true;
    return true;
}
