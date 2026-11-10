// How many times a piece of code WAITED for D1, for the tests that pin it. timedDb (src/d1-timing.ts) counts round
// trips started; statements asked at the same time are several round trips but one wait, and the wait is what a
// request far from the database pays for. So this counts the times a D1 call started while none was out: three
// statements one after another are three waits, the same three under Promise.all are one, a batch is one.
//
// It patches the fake in place (prepare and, when the fake has one, batch), so it sits under timedDb and under
// whatever the code remembers per database object. Every call is held for a few milliseconds, as a real round trip
// would be: what the code asks "at the same time" has all been asked by then.
import type { FakeD1 } from "../../test-support/d1-sqlite";

const HOLD_MS = 3;

export function countWaits(db: FakeD1): { n: number } {
    const waits = { n: 0 };
    let out = 0;
    const held = async <R>(call: () => Promise<R>): Promise<R> => {
        if (out === 0) waits.n += 1;
        out += 1;
        try {
            await new Promise((r) => setTimeout(r, HOLD_MS));
            return await call();
        } finally {
            out -= 1;
        }
    };
    // held statement -> the fake's own, which is what its batch runs (one hold for the batch, none inside it)
    const realOf = new WeakMap<object, unknown>();
    const hold = (st: any): any => {
        const h = {
            ...st,
            bind: (...p: unknown[]) => hold(st.bind(...p)),
            first: (...a: unknown[]) => held(() => st.first(...a)),
            all: () => held(() => st.all()),
            run: () => held(() => st.run()),
        };
        realOf.set(h, st);
        return h;
    };
    const prepare = db.prepare.bind(db);
    (db as any).prepare = (sql: string) => hold(prepare(sql));
    const batch = (db as any).batch as ((s: unknown[]) => Promise<unknown[]>) | undefined;
    if (typeof batch === "function") {
        (db as any).batch = (statements: object[]) => held(() => batch.call(db, statements.map((s) => realOf.get(s) ?? s)));
    }
    return waits;
}
