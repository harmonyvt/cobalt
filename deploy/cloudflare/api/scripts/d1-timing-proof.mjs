// Proves the pieces of the D1 speed-up against the real runtime, not the node:sqlite fake: workerd with its own D1
// binding, started by Miniflare (both come with the Wrangler devDependency). No network, no secrets, no deploy.
//
//   node scripts/d1-timing-proof.mjs        (from deploy/cloudflare/api; exits 1 if any check fails)
//
// What it checks, in a module Worker bundled from the real sources (src/d1-timing.ts, src/keys.ts, src/background.ts,
// src/request-log.ts):
//   1. timedDb: every call (exec, all, run, first, raw, batch, a session, failures) gives the same answer through the
//      wrapper as on the plain binding, and the count goes up by exactly one per round trip.
//   2. withD1Timing: the env with DB swapped in still works, the one JSON line has the documented fields, requests
//      served at once are counted apart (AsyncLocalStorage from node:async_hooks, loaded at this compatibility date
//      without a flag), and every request sees the isolate's one wrapped DB.
//   3. lookupKey with the key cache: `RETURNING id, expires_at` on real D1, and a hit that makes no D1 call.
//   4. The request log through background(): the response is answered before the row exists, its body arrives whole,
//      and the row is written afterwards (waitUntil) with the reply's result.
// Not part of `npm test` (it starts a workerd process); run it after touching any of those four files.
import { build } from "esbuild";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as miniflare from "miniflare";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../src");
const migrations = resolve(here, "../../d1/migrations");

// The Worker under test. `./x` resolves in src/.
const WORKER = `
import { timedDb, withD1Timing } from "./d1-timing";
import { background } from "./background";
import { hashKey, KeyCache, lookupKey, SESSION_TTL_MS } from "./keys";
import { logRequest } from "./request-log";

const lines = [];
const late = [];
const timedDbs = [];
const cache = new KeyCache();

// One call's outcome in a form that can be compared: its value, or its error's message.
const outcome = async (run) => {
    try {
        return { ok: clean(await run()) };
    } catch (e) {
        return { error: String(e && e.message ? e.message : e) };
    }
};
// D1's meta carries timings and sizes that differ from call to call; what the statement did is kept.
const clean = (v) => {
    if (Array.isArray(v)) return v.map(clean);
    if (v && typeof v === "object" && "meta" in v && "success" in v) {
        return { success: v.success, results: v.results, changes: v.meta.changes, last_row_id: v.meta.last_row_id, rows_written: v.meta.rows_written };
    }
    if (v && typeof v === "object" && "count" in v && "duration" in v) return { count: v.count };
    return v;
};

// The same calls on any database, on its own table. Each step: [label, round trips it should cost, the call].
const steps = (db, t) => {
    const insert = () => db.prepare("INSERT INTO " + t + " (v, n) VALUES (?1, ?2) RETURNING id, v");
    const pick = db.prepare("SELECT id, v, n FROM " + t + " WHERE n >= ?1 ORDER BY id");
    return [
        ["exec", 1, () => db.exec("CREATE TABLE " + t + " (id INTEGER PRIMARY KEY, v TEXT, n INTEGER)")],
        ["prepare alone", 0, async () => typeof db.prepare("SELECT 1").bind],
        ["bind().all() with RETURNING", 1, () => insert().bind("a", 1).all()],
        ["bind().run()", 1, () => insert().bind("b", 2).run()],
        ["batch of three", 1, () => db.batch([insert().bind("c", 3), insert().bind("d", 4), db.prepare("UPDATE " + t + " SET n = n + 10 WHERE v = ?1").bind("a")])],
        ["all()", 1, () => pick.bind(2).all()],
        ["first()", 1, () => pick.bind(3).first()],
        ["first(column)", 1, () => pick.bind(3).first("v")],
        ["first() without a row", 1, () => pick.bind(999).first()],
        ["one statement, bound twice", 2, async () => [await pick.bind(4).first("id"), await pick.bind(11).first("id")]],
        ["bind off a bound statement", 1, () => pick.bind(1).bind(11).all()],
        ["raw()", 1, () => pick.bind(2).raw()],
        ["raw({ columnNames })", 1, () => pick.bind(2).raw({ columnNames: true })],
        ["a failing statement", 1, () => db.prepare("SELECT nope FROM " + t).all()],
        ["a failing batch", 1, () => db.batch([db.prepare("DELETE FROM " + t), db.prepare("SELECT nope FROM " + t)])],
        ["... which changed nothing", 1, () => db.prepare("SELECT count(*) AS c FROM " + t).first("c")],
        ["bind() of a value D1 refuses", 0, async () => db.prepare("SELECT ?1 AS x").bind(undefined)],
        ["a session: prepare().first()", 1, () => db.withSession("first-primary").prepare("SELECT count(*) AS c FROM " + t).first("c")],
        ["a session: batch()", 1, () => { const s = db.withSession(); return s.batch([s.prepare("SELECT 1 AS one")]); }],
        ["a session: getBookmark()", 0, async () => typeof db.withSession().getBookmark()],
        ["two at once", 2, () => Promise.all([pick.bind(3).first("v"), pick.bind(4).first("v")])],
    ];
};

async function compare(env) {
    const { db, stats } = timedDb(env.DB);
    const plain = steps(env.DB, "plain_t");
    const timed = steps(db, "timed_t");
    const out = [];
    for (let i = 0; i < plain.length; i++) {
        const before = stats.n;
        const viaWrapper = await outcome(timed[i][2]);
        const cost = stats.n - before;
        out.push({ label: plain[i][0], expectedCost: plain[i][1], cost, plain: await outcome(plain[i][2]), timed: viaWrapper });
    }
    return { steps: out, stats, wrapped: db !== env.DB };
}

async function keys(env) {
    const now = Date.now();
    const insert = "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, kind, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";
    await env.DB.batch([
        env.DB.prepare(insert).bind("k-1", "laptop", await hashKey("0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11"), "0b5f2c3e", 1, "key", null),
        env.DB.prepare(insert).bind("s-1", "phone", await hashKey("5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7"), "5a1e2b3c", 1, "session", now + 5000),
    ]);
    const { db, stats } = timedDb(env.DB);
    const first = [await lookupKey(db, "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11", now, "SG", cache), await lookupKey(db, "5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7", now, "SG", cache)];
    const afterMisses = stats.n;
    const again = [await lookupKey(db, "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11", now + 1000, "JP", cache), await lookupKey(db, "5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7", now + 20000, "JP", cache)];
    const afterHits = stats.n;
    const unknown = [await lookupKey(db, "11111111-1111-4111-8111-111111111111", now, null, cache), await lookupKey(db, "11111111-1111-4111-8111-111111111111", now, null, cache)];
    const session = await env.DB.prepare("SELECT expires_at, last_used_at, last_country FROM api_keys WHERE id = 's-1'").first();
    return { first, again, unknown, afterMisses, afterHits, afterUnknown: stats.n, slid: session.expires_at === now + SESSION_TTL_MS, session_last: [session.last_used_at === now, session.last_country], cached: cache.size };
}

// A database whose request_log INSERT takes half a second: long enough to see that the answer does not wait for it.
const slowLog = (db) => new Proxy(db, {
    get(target, prop) {
        if (prop !== "prepare") { const v = Reflect.get(target, prop, target); return typeof v === "function" ? v.bind(target) : v; }
        return (sql) => {
            const real = target.prepare(sql);
            if (!/INSERT INTO request_log/.test(sql)) return real;
            const slow = (s) => new Proxy(s, { get(st, p) {
                if (p === "bind") return (...a) => slow(st.bind(...a));
                if (p === "run") return async () => { await scheduler.wait(500); return st.run(); };
                const v = Reflect.get(st, p, st); return typeof v === "function" ? v.bind(st) : v;
            } });
            return slow(real);
        };
    },
});

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        try {
            if (url.pathname === "/compare") return Response.json(await compare(env));
            if (url.pathname === "/keys") return Response.json(await keys(env));
            if (url.pathname === "/timed") {
                // the fetch handler's own shape (src/index.ts): the env with DB swapped, one line per request
                return await withD1Timing(request, env, async (e) => {
                    const a = await e.DB.prepare("SELECT count(*) AS c FROM api_keys").first("c");
                    const b = await e.DB.batch([e.DB.prepare("SELECT 1 AS one"), e.DB.prepare("SELECT 2 AS two")]);
                    return Response.json({ a, b: b.map((r) => r.results), sameEnv: e === env, otherBinding: e.OTHER, wrapped: e.DB !== env.DB }, { status: 203 });
                }, (line) => lines.push(line));
            }
            if (url.pathname.startsWith("/many/")) {
                // several of these are served at once: each must be counted apart, on the isolate's one wrapper
                const n = Number(url.searchParams.get("n"));
                return await withD1Timing(request, env, async (e) => {
                    timedDbs.push(e.DB);
                    for (let i = 0; i < n; i++) {
                        await e.DB.prepare("SELECT ?1 AS x").bind(i).first();
                        await scheduler.wait(15);
                    }
                    return Response.json({ n });
                }, (line) => lines.push(line));
            }
            if (url.pathname === "/untimed") {
                return await withD1Timing(request, { ...env, D1_TIMING: "0" }, async (e) => Response.json({ plainDb: e.DB === env.DB }), (line) => lines.push(line));
            }
            if (url.pathname === "/console") {
                // the default log: console.log, as deployed
                return await withD1Timing(request, env, async (e) => Response.json({ c: await e.DB.prepare("SELECT 1 AS c").first("c") }));
            }
            if (url.pathname === "/log") {
                // a logged op as src/registry/ops/system.ts writes it, then the reply rebuilt as http.ts withHeaders does
                const res = Response.json({ status: "tunnel", url: "https://example.com/tunnel" });
                const info = { contentType: "application/json", bytes: 2, keys: "url", urlType: "string", urlLen: 20, urlPrefix: "https://example.com/" };
                await background((p) => ctx.waitUntil(p), () => logRequest(slowLog(env.DB), "POST /", "k-1", request, info, res));
                const out = new Response(res.body, res);
                out.headers.set("access-control-allow-origin", "https://cobalt.capybaraharmony.com");
                return out;
            }
            if (url.pathname === "/late-clone") {
                // why logRequest clones before its first await: what a clone attempted after the answer left does here
                const res = Response.json({ status: "tunnel" });
                ctx.waitUntil((async () => {
                    await scheduler.wait(50);
                    try { late.push("clone ok: " + JSON.stringify(await res.clone().json())); } catch (e) { late.push("clone threw: " + (e && e.message)); }
                })());
                return new Response(res.body, res);
            }
            if (url.pathname === "/rows") {
                const rows = await env.DB.prepare("SELECT route, key_id, user_agent, status, result, error_code FROM request_log ORDER BY id").all();
                return Response.json({ rows: rows.results, lines, late, oneWrapper: timedDbs.length > 1 && timedDbs.every((d) => d === timedDbs[0]) && timedDbs[0] !== env.DB });
            }
            return new Response("?", { status: 404 });
        } catch (e) {
            return Response.json({ crashed: String(e && e.stack ? e.stack : e) }, { status: 500 });
        }
    },
};
`;

let failed = 0;
const check = (name, ok, detail = "") => {
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  ${detail}` : ""}`);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const bundled = await build({
    stdin: { contents: WORKER, resolveDir: src, sourcefile: "proof-worker.ts", loader: "ts" },
    bundle: true,
    format: "esm",
    target: "es2022",
    platform: "neutral",
    // node:async_hooks (AsyncLocalStorage) is the runtime's own module
    external: ["node:*"],
    // request-log.ts imports one helper (linkFrom, for bodyLink) from the studio module, which pulls in the whole
    // Worker and its dependencies. logRequest does not use it, so the proof bundles a stand-in for that one import.
    plugins: [
        {
            name: "studio-stub",
            setup(b) {
                b.onResolve({ filter: /^\.\/studio$/ }, () => ({ path: "studio-stub", namespace: "stub" }));
                b.onLoad({ filter: /.*/, namespace: "stub" }, () => ({ contents: "export const linkFrom = () => null;", loader: "js" }));
            },
        },
    ],
    write: false,
    logLevel: "silent",
});
const script = bundled.outputFiles[0].text;

const options = {
    modules: true,
    script,
    compatibilityDate: "2026-09-01",
    d1Databases: ["DB"],
    bindings: { D1_TIMING: "1", OTHER: "kept" },
    // a fixed request.cf: no lookup on the network
    cf: { colo: "SIN", country: "SG" },
};
// Miniflare 5 takes its options in a new shape and ships the converter for the old one.
const mf = new miniflare.Miniflare(typeof miniflare.convertV4MiniflareOptions === "function" ? miniflare.convertV4MiniflareOptions(options) : options);

try {
    // The real schema of the two tables the checks touch: migrations 0001, 0002 and 0026, statement by statement.
    const d1 = await mf.getD1Database("DB");
    for (const file of ["0001_api_keys.sql", "0002_request_log.sql", "0026_sessions.sql"]) {
        const sql = readFileSync(resolve(migrations, file), "utf8").replace(/--.*$/gm, "");
        for (const statement of sql.split(";").map((s) => s.trim()).filter(Boolean)) await d1.prepare(statement).run();
    }
    const get = async (path, init) => {
        const res = await mf.dispatchFetch(`http://proof.local${path}`, init);
        return { res, body: await res.json() };
    };

    // 1. the wrapper against the plain binding
    const { body: cmp } = await get("/compare");
    if (cmp.crashed) throw new Error(cmp.crashed);
    check("the binding was wrapped (not failed open)", cmp.wrapped === true);
    let expectedTotal = 0;
    for (const s of cmp.steps) {
        expectedTotal += s.expectedCost;
        const equal = same(s.plain, s.timed);
        check(`${s.label}: same answer, ${s.expectedCost} round trip${s.expectedCost === 1 ? "" : "s"}`, equal && s.cost === s.expectedCost, equal ? (s.cost === s.expectedCost ? "" : `counted ${s.cost}`) : `plain ${JSON.stringify(s.plain)} != timed ${JSON.stringify(s.timed)}`);
    }
    check(`total round trips counted: ${expectedTotal}`, cmp.stats.n === expectedTotal, `stats ${JSON.stringify(cmp.stats)}`);
    check("stats.ms is a number of milliseconds", typeof cmp.stats.ms === "number" && cmp.stats.ms >= 0);
    const failing = cmp.steps.find((s) => s.label === "a failing statement");
    check("a failure is the binding's own error", typeof failing.plain.error === "string" && failing.plain.error === failing.timed.error, failing.timed.error);
    const untouched = cmp.steps.find((s) => s.label === "... which changed nothing");
    check("a failing batch rolled back on both", untouched.plain.ok === 4 && untouched.timed.ok === 4);

    // 2. the fetch handler's wrapper and its line
    const timed = await get("/timed?token=secret", { headers: { authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11" } });
    check("withD1Timing: the handler ran on a swapped env that kept its other bindings", timed.res.status === 203 && timed.body.sameEnv === false && timed.body.wrapped === true && timed.body.otherBinding === "kept", JSON.stringify(timed.body));
    const untimed = await get("/untimed");
    check("withD1Timing off: the plain binding", untimed.body.plainDb === true);
    const consoleLine = await get("/console");
    check("withD1Timing with the default console.log: the answer still goes out", consoleLine.res.status === 200 && consoleLine.body.c === 1);

    const counts = { a: 1, b: 4, c: 0, d: 2 };
    await Promise.all(Object.entries(counts).map(([name, n]) => get(`/many/${name}?n=${n}`)));

    // 3. the key check
    const { body: k } = await get("/keys");
    if (k.crashed) throw new Error(k.crashed);
    check("lookupKey on real D1: both rows accepted by RETURNING id, expires_at", same(k.first, ["k-1", "s-1"]) && k.afterMisses === 2, JSON.stringify(k));
    check("lookupKey: the session's expiry slid and its use was recorded", k.slid === true && same(k.session_last, [true, "SG"]));
    check("lookupKey: hits make no D1 call (the session past its old expiry too)", same(k.again, ["k-1", "s-1"]) && k.afterHits === 2 && k.cached === 2);
    check("lookupKey: an unknown key asks D1 every time", same(k.unknown, [null, null]) && k.afterUnknown === 4);

    // 4. the request log behind the answer
    const asked = performance.now();
    const logged = await mf.dispatchFetch("http://proof.local/log", { method: "POST", headers: { "user-agent": "proof/1", "content-type": "application/json" }, body: "{}" });
    const loggedBody = await logged.json();
    const waited = Math.round(performance.now() - asked);
    const rightAfter = (await get("/rows")).body;
    check("the answer, body included, did not wait for the 500 ms INSERT", waited < 400, `back after ${waited} ms`);
    check("the answer's body arrived whole", same(loggedBody, { status: "tunnel", url: "https://example.com/tunnel" }));
    check("no row yet when the answer is back", rightAfter.rows.length === 0, JSON.stringify(rightAfter.rows));
    let rows = [];
    for (let i = 0; i < 50 && rows.length === 0; i++) {
        await new Promise((r) => setTimeout(r, 100));
        rows = (await get("/rows")).body.rows;
    }
    check("the row was written after the answer, with the reply's result", same(rows, [{ route: "POST /", key_id: "k-1", user_agent: "proof/1", status: 200, result: "tunnel", error_code: null }]), JSON.stringify(rows));

    await get("/late-clone");
    await new Promise((r) => setTimeout(r, 300));
    const end = (await get("/rows")).body;
    console.log(`INFO  a clone attempted after the answer left: ${end.late[0] ?? "(nothing recorded)"}`);

    const parsed = end.lines.map((l) => JSON.parse(l));
    const many = Object.fromEntries(parsed.filter((l) => l.path.startsWith("/many/")).map((l) => [l.path.slice(6), l.d1.n]));
    check("four requests served at once: each line has its own count", same(many, counts) || same(Object.entries(many).sort(), Object.entries(counts).sort()), JSON.stringify(many));
    check("every request got the isolate's one wrapper (what modules remember per database stays remembered)", end.oneWrapper === true);
    const single = parsed.filter((l) => !l.path.startsWith("/many/"));
    const line = single.length === 1 ? single[0] : null;
    const lineText = end.lines.find((l) => l.includes('"/timed"')) ?? "";
    check("exactly one line for the one timed request, none for the untimed one", single.length === 1, JSON.stringify(single));
    if (line) {
        check("the line's fields", same(Object.keys(line), ["evt", "method", "path", "status", "ms", "d1", "colo"]) && line.evt === "req" && line.method === "GET" && line.path === "/timed" && line.status === 203, lineText);
        check("the line counts the two round trips", line.d1.n === 2 && typeof line.d1.ms === "number" && typeof line.ms === "number");
        check("the line has the colo and no query string or header", line.colo === "SIN" && lineText !== "" && !/secret|token|Api-Key|0b5f2c3e/.test(lineText));
    }
} catch (e) {
    failed++;
    console.log(`FAIL  the proof could not run: ${e && e.stack ? e.stack : e}`);
} finally {
    await mf.dispose();
}
console.log(failed === 0 ? "\nall checks passed" : `\n${failed} check(s) FAILED`);
process.exit(failed === 0 ? 0 : 1);
