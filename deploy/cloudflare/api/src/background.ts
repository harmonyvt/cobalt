// Work that must not hold a response: the request log's INSERT, a caption, a poster kick. Free of Cloudflare imports.
//
// The contract, one for every caller:
//  - `work` is STARTED here, synchronously, before this function returns. Whatever it does before its first await has
//    happened by then (logRequest clones the response there, while its body can still be cloned).
//  - With a `waitUntil` (the Worker's fetch handler, `ctx.edge.waitUntil` in an op) the work is handed to it and the
//    returned promise resolves at once. The response is gone by the time the work can fail, so a failure is caught here
//    and written to the console; it never rejects.
//  - Without one (tests, Durable Objects, the cron) nothing would keep the work alive after the response, so it is
//    awaited, exactly as an inline `await work()` would: the returned promise resolves when the work has finished and
//    REJECTS if the work does. A call site whose old code swallowed the failure keeps its own try/catch inside `work`;
//    one whose old code let it fail the request still does.
//
// Always `await background(...)`: with a waitUntil that costs nothing, without one it is what keeps the old order.
export function background(waitUntil: ((p: Promise<unknown>) => void) | undefined, work: () => Promise<unknown>): Promise<void> {
    let running: Promise<unknown>;
    try {
        running = Promise.resolve(work());
    } catch (e) {
        running = Promise.reject(e);
    }
    const done = running.then(() => undefined);
    if (!waitUntil) return done;
    const safe = done.catch((e) => console.error("[background] work failed", e instanceof Error ? `${e.name}: ${e.message}` : String(e)));
    try {
        waitUntil(safe);
    } catch {
        // a waitUntil that refuses (its request is already over): wait for the work here instead of dropping it
        return safe;
    }
    return Promise.resolve();
}
