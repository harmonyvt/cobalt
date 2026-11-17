// Counts a request's D1 round trips. D1 lives in one region; a Worker that runs far from it pays a full round trip per
// statement, and a route's statements run one after another, so the count is what a slow answer is made of. Measured
// here, per request, behind the D1_TIMING var; also what the tests use to pin how many round trips a route makes.
// Free of Cloudflare imports: the tests run it on the node:sqlite fake, scripts/d1-timing-proof.mjs on workerd's D1.
//
// What counts as ONE round trip: each awaited first/all/run/raw of a statement, each batch(), each exec(). prepare()
// and bind() talk to nobody and count nothing.

export type D1Stats = {
    // round trips started so far
    n: number;
    // the wall time of those that have finished, added up, ms. Statements running at once each count their own wait,
    // so this can exceed the request's own time.
    ms: number;
};

// Where a wrapped database counts: the stats, how many round trips are still out, and the clock they are timed with.
type Meter = { stats: D1Stats; open: number; clock: () => number };

const STATEMENT_CALLS = new Set(["first", "all", "run", "raw"]);
// the database's own methods this file stands in for
const WRAPPED_CALLS = new Set(["prepare", "batch", "exec", "withSession"]);

// A database (or a session of it) that answers exactly like `real` and counts into whatever `meter()` gives at the
// moment of each call; nothing is counted while it gives none. Throws if `real` cannot be wrapped.
function wrap<D extends object>(real: D, meter: () => Meter | undefined): D {
    // wrapper -> the statement it stands for: batch() must be given the binding's own statements
    const realOf = new WeakMap<object, unknown>();

    const timed = async <R>(call: () => Promise<R>): Promise<R> => {
        const m = meter();
        if (!m) return call();
        m.stats.n += 1;
        m.open += 1;
        const start = m.clock();
        try {
            return await call();
        } finally {
            m.open -= 1;
            m.stats.ms += m.clock() - start;
        }
    };

    // Any member this file does not know is read from the real object; a method is called on the real object, never
    // on the wrapper (the binding's own classes do not accept a stand-in as `this`).
    const passThrough = (target: object, prop: string | symbol): unknown => {
        const value = Reflect.get(target, prop, target);
        return typeof value === "function" ? value.bind(target) : value;
    };

    const wrapStatement = (statement: D1PreparedStatement): D1PreparedStatement => {
        try {
            const wrapper = new Proxy(statement, {
                get(target, prop) {
                    if (prop === "bind") return (...values: unknown[]) => wrapStatement(target.bind(...values));
                    if (typeof prop === "string" && STATEMENT_CALLS.has(prop)) {
                        return (...args: unknown[]) => timed(() => (target as any)[prop](...args));
                    }
                    return passThrough(target, prop);
                },
            });
            realOf.set(wrapper, statement);
            return wrapper;
        } catch {
            return statement;
        }
    };

    const unwrap = (statements: D1PreparedStatement[]): D1PreparedStatement[] =>
        Array.isArray(statements) ? statements.map((s) => (realOf.get(s) as D1PreparedStatement | undefined) ?? s) : statements;

    // The database, and a session of it (withSession): both prepare and batch.
    const wrapDatabase = <T extends object>(database: T): T =>
        new Proxy(database, {
            get(target, prop) {
                const t = target as unknown as D1Database;
                // A method the database does not have stays missing on the wrapper: callers pick their path by asking
                // (`typeof db.batch === "function"`, names.ts and others), and the tests' fake has no batch.
                if (typeof prop === "string" && WRAPPED_CALLS.has(prop) && typeof (t as any)[prop] !== "function") {
                    return passThrough(target, prop);
                }
                if (prop === "prepare") return (query: string) => wrapStatement(t.prepare(query));
                if (prop === "batch") return (statements: D1PreparedStatement[]) => timed(() => t.batch(unwrap(statements)));
                if (prop === "exec") return (query: string) => timed(() => t.exec(query));
                if (prop === "withSession") {
                    return (...args: [string?]) => {
                        const session = t.withSession(...args);
                        try {
                            return wrapDatabase(session);
                        } catch {
                            return session;
                        }
                    };
                }
                return passThrough(target, prop);
            },
        });

    return wrapDatabase(real);
}

// `db` behaves exactly like the binding it wraps (same results, same errors, same objects handed back) and adds to
// `stats` as it goes. In a test: `const { db, stats } = timedDb(createFakeD1())`, hand `db` to the code, read `stats.n`.
// If the wrapping itself cannot be set up, `db` is the binding as it came and `stats` stays at zero.
export function timedDb<T extends D1Database>(real: T, clock: () => number = Date.now): { db: T; stats: D1Stats } {
    const meter: Meter = { stats: { n: 0, ms: 0 }, open: 0, clock };
    try {
        return { db: wrap(real, () => meter), stats: meter.stats };
    } catch {
        return { db: real, stats: meter.stats };
    }
}

// ---- per request, in the Worker ---------------------------------------------------------------------------------------
//
// The Worker cannot hand each request a wrapper of its own: several modules remember things per database object for the
// isolate's life (is a migration applied, hidden-store.ts and names.ts and edits.ts; a ready session, studio-edge.ts),
// and a new object per request would make each of them ask D1 again every time. So the isolate has ONE wrapper per
// binding, and each request's count is kept apart by AsyncLocalStorage: the wrapper counts into the store of the
// request whose code is running, however many requests the isolate serves at once.
//
// AsyncLocalStorage comes from node:async_hooks, which the runtime has at this Worker's compatibility date (Node.js
// compatibility is on by default from it, no flag). It is imported when first needed, not at the top: if it is ever
// missing, timing turns itself off and nothing else changes.

type Storage = { run<R>(store: Meter, fn: () => R): R; getStore(): Meter | undefined };
let storage: Promise<Storage | null> | undefined;
const loadStorage = (): Promise<Storage | null> =>
    (storage ??= import("node:async_hooks").then(
        (m) => new m.AsyncLocalStorage<Meter>() as Storage,
        () => null,
    ));

// binding -> its one wrapper in this isolate
const isolateDbs = new WeakMap<object, D1Database>();

// The path as the line carries it: the route's fixed words, with every other segment as "*"
// ("/library/items/*/crop"). Several routes have their credential IN the path (the MCP private link /mcp/k/<secret>,
// an upload link /mcp/upload/<token>, the stage canvas /live/<token>, a studio session /studio/<sid>, a private share
// link /p/<key>), and this line is a second copy of the URL that the platform's own log redaction never sees. The rule
// does not know the routes, so a new route with a secret in its path is covered the day it is added: a segment is kept
// only when it is at most 20 lowercase letters and hyphens. Every token this Worker mints is 22 characters or more, so
// none can pass; ids and file names go too (a 10-character public file name with no capital and no digit, about one in
// six thousand, is the one thing that can slip through as a word). The lines then group by route.
// "7tv" is the one route word that starts with a digit (APP-API-CONTRACT.md section 57)
const ROUTE_WORD = /^(?:[a-z][a-z-]{0,19}|7tv)$/;
export function maskPath(pathname: string): string {
    return pathname
        .split("/")
        .map((segment) => (segment === "" || ROUTE_WORD.test(segment) ? segment : "*"))
        .join("/");
}

// The one line a timed request logs. Never the query string and never a header: both can carry credentials. The path
// is masked (maskPath) for the same reason.
export type RequestLine = {
    evt: "req";
    method: string;
    // the pathname through maskPath
    path: string;
    status: number;
    ms: number;
    d1: D1Stats;
    colo?: string;
    // the handler threw: the runtime answered, not the Worker
    threw?: true;
};

// Runs one request with D1 counted, while `env.D1_TIMING` is "1": `handle` gets the env with DB wrapped, and when its
// response is ready ONE JSON line goes to the log (Workers Logs indexes its fields):
//   {"evt":"req","method":"GET","path":"/library","status":200,"ms":212,"d1":{"n":11,"ms":198},"colo":"SIN"}
// `path` is the pathname with everything but the route's words masked (maskPath): "/library/items/*/crop".
// `ms` is the time until the response was produced (a streamed body is still on its way). `d1` is the round trips that
// had FINISHED by then, the ones the answer can have waited for: one still out at that moment was handed to waitUntil
// (the request log's INSERT) and is not in it. `colo` is the Cloudflare location the request came in at. With
// D1_TIMING anything else, or if the counting cannot be set up, `handle` gets `env` itself and nothing is logged.
export async function withD1Timing<E extends { DB: D1Database; D1_TIMING?: string }>(
    request: Request,
    env: E,
    handle: (env: E) => Promise<Response>,
    log: (line: string) => void = (line) => console.log(line),
    clock: () => number = Date.now,
): Promise<Response> {
    if (env.D1_TIMING !== "1") return handle(env);
    let als: Storage | null = null;
    let timedEnv: E | null = null;
    try {
        als = await loadStorage();
        if (als) {
            const store = als;
            let db = isolateDbs.get(env.DB);
            if (!db) {
                db = wrap(env.DB, () => store.getStore());
                isolateDbs.set(env.DB, db);
            }
            timedEnv = { ...env, DB: db };
        }
    } catch {
        // measuring must never be why a request fails: the plain env
        timedEnv = null;
    }
    if (!als || !timedEnv) return handle(env);

    const meter: Meter = { stats: { n: 0, ms: 0 }, open: 0, clock };
    const start = clock();
    const line = (status: number, threw: boolean) => {
        try {
            const colo = (request as { cf?: { colo?: unknown } }).cf?.colo;
            const out: RequestLine = {
                evt: "req",
                method: request.method,
                path: maskPath(new URL(request.url).pathname),
                status,
                ms: clock() - start,
                d1: { n: meter.stats.n - meter.open, ms: meter.stats.ms },
                ...(typeof colo === "string" ? { colo } : {}),
                ...(threw ? { threw: true as const } : {}),
            };
            log(JSON.stringify(out));
        } catch {
            // no line, the answer still goes out
        }
    };
    const run = timedEnv;
    let res: Response;
    try {
        res = await als.run(meter, () => handle(run));
    } catch (e) {
        line(500, true);
        throw e;
    }
    line(res.status, false);
    return res;
}
