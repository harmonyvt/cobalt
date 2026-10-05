// Our own time ceiling on an async call. AbortSignal.timeout() is NOT honoured
// for containerFetch inside the Durable Object (a hung helper call stalled a
// poll for 5.5 min live, 2026-10-01), so every call that must come back in
// bounded time is raced against a timer of our own instead. The losing call is
// abandoned, not cancelled: it may finish later and its result is dropped.

export class CeilingError extends Error {
    constructor(label: string, ms: number) {
        super(`${label} timed out after ${ms} ms`);
        this.name = "CeilingError";
    }
}

export function raceCeiling<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new CeilingError(label, ms)), ms);
    });
    return Promise.race([p, timeout]).finally(() => {
        if (timer !== undefined) clearTimeout(timer);
    });
}
