// Our own time ceiling on an async call. AbortSignal.timeout() is NOT honoured
// for containerFetch inside the Durable Object (a hung helper call stalled a
// poll for 5.5 min live, 2026-10-01), so every call that must come back in
// bounded time is raced against a timer of our own instead. The losing call is
// abandoned, not cancelled: it may finish later and its result is dropped. A late
// Response's body is cancelled (discardLate): the Containers library counts a
// containerFetch as in flight until its body is read or cancelled, and while
// anything is in flight the container never sleeps (a dropped body kept the
// cobalt container awake for 17 h on 2026-11-19).

export class CeilingError extends Error {
    constructor(label: string, ms: number) {
        super(`${label} timed out after ${ms} ms`);
        this.name = "CeilingError";
    }
}

// Cancels the body of a value that arrived after its race was lost, when it is a
// Response (or anything with a cancellable body). Never throws.
export function discardLate(value: unknown): void {
    const body = (value as { body?: { cancel?: (reason?: unknown) => Promise<void> } | null } | null | undefined)?.body;
    if (body && typeof body.cancel === "function") {
        try {
            void body.cancel("abandoned after its time ran out").catch(() => {});
        } catch {
            // a locked or already-read body: nothing left to free
        }
    }
}

// `error` replaces the CeilingError when a caller's callers expect a plain Error (studio's helper calls: the sweep
// treats a CeilingError as "still pending").
export function raceCeiling<T>(p: Promise<T>, ms: number, label: string, error?: () => Error): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let lost = false;
    const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
            lost = true;
            reject(error ? error() : new CeilingError(label, ms));
        }, ms);
    });
    p.then(
        (v) => {
            if (lost) discardLate(v);
        },
        () => {},
    );
    return Promise.race([p, timeout]).finally(() => {
        if (timer !== undefined) clearTimeout(timer);
    });
}
