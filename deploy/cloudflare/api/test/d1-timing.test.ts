// src/d1-timing.ts on the node:sqlite fake: what counts as a round trip, that the wrapped database answers exactly like
// the one it wraps, and the one line a timed request logs. scripts/d1-timing-proof.mjs runs the same wrapper against
// workerd's own D1 binding.
import { describe, expect, it } from "vitest";
import { maskPath, timedDb, withD1Timing } from "../src/d1-timing";
import { REGISTRY } from "../src/registry/index";
import { hiddenReady } from "../src/hidden-store";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";

const SCHEMA = "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, n INTEGER)";
const seeded = () => {
    const db = createBatchD1(SCHEMA);
    db.raw.exec("INSERT INTO t (v, n) VALUES ('a', 1), ('b', 2), ('c', 3)");
    return db;
};
// a clock that moves 7 ms every time it is read: each round trip reads it twice
const stepClock = () => {
    let t = 0;
    return () => (t += 7);
};

describe("timedDb: what counts", () => {
    it("prepare and bind count nothing; each awaited first/all/run is one", async () => {
        const { db, stats } = timedDb(seeded());
        const s = db.prepare("SELECT v FROM t WHERE n >= ?1 ORDER BY n");
        const bound = s.bind(2);
        expect(stats).toEqual({ n: 0, ms: 0 });
        await bound.all();
        expect(stats.n).toBe(1);
        await bound.first();
        expect(stats.n).toBe(2);
        await db.prepare("UPDATE t SET v = 'z' WHERE n = ?1").bind(1).run();
        expect(stats.n).toBe(3);
        // the same statement run again is another round trip; a bind chain off a bound statement too
        await bound.all();
        await s.bind(1).bind(3).first();
        expect(stats.n).toBe(5);
    });
    it("a batch is one round trip, whatever it holds, and the binding gets its own statements", async () => {
        const real = seeded();
        const handed: unknown[][] = [];
        const realBatch = (real as any).batch;
        (real as any).batch = (statements: unknown[]) => {
            handed.push(statements);
            return realBatch(statements);
        };
        const { db, stats } = timedDb(real);
        const insert = db.prepare("INSERT INTO t (v, n) VALUES (?1, ?2)");
        const statements = [insert.bind("d", 4), insert.bind("e", 5), db.prepare("UPDATE t SET n = n + 10")];
        const out = await db.batch(statements);
        expect(stats.n).toBe(1);
        expect(out.map((r) => r.meta.changes)).toEqual([1, 1, 5]);
        expect(real.raw.prepare("SELECT count(*) AS c, min(n) AS lo FROM t").get()).toEqual({ c: 5, lo: 11 });
        // none of the wrappers reached the binding
        expect(handed[0]).toHaveLength(3);
        for (let i = 0; i < 3; i++) expect(handed[0]![i]).not.toBe(statements[i]);
        for (const s of handed[0]!) expect(typeof (s as any).run).toBe("function");
    });
    it("a statement the wrapper never made goes into a batch as it is", async () => {
        const real = seeded();
        const { db, stats } = timedDb(real);
        const plain = real.prepare("UPDATE t SET v = 'p' WHERE n = 1");
        await db.batch([plain, db.prepare("UPDATE t SET v = 'q' WHERE n = 2")]);
        expect(stats.n).toBe(1);
        expect(real.raw.prepare("SELECT v FROM t ORDER BY n").all().map((r) => r.v)).toEqual(["p", "q", "c"]);
    });
    it("a failing batch counts once, changes nothing and rejects with the binding's own error", async () => {
        const real = seeded();
        const { db, stats } = timedDb(real);
        await expect(db.batch([db.prepare("UPDATE t SET v = 'x'"), db.prepare("UPDATE nope SET v = 1")])).rejects.toThrow(/no such table/);
        expect(stats.n).toBe(1);
        expect(real.raw.prepare("SELECT v FROM t ORDER BY n").all().map((r) => r.v)).toEqual(["a", "b", "c"]);
    });
    it("exec and raw are one each, where the binding has them", async () => {
        const calls: string[] = [];
        const binding = {
            prepare: (sql: string) => ({
                bind: () => binding.prepare(sql),
                raw: async (o?: unknown) => (calls.push(`raw ${JSON.stringify(o)}`), [["a", 1]]),
                first: async () => null,
                all: async () => ({ results: [] }),
                run: async () => ({}),
            }),
            exec: async (sql: string) => (calls.push(`exec ${sql}`), { count: 2, duration: 0 }),
        } as unknown as D1Database;
        const { db, stats } = timedDb(binding);
        expect(await db.exec("A; B")).toEqual({ count: 2, duration: 0 });
        expect(await db.prepare("SELECT 1").bind(1).raw({ columnNames: true } as any)).toEqual([["a", 1]]);
        expect(stats.n).toBe(2);
        expect(calls).toEqual(["exec A; B", 'raw {"columnNames":true}']);
    });
    it("statements running at once are each counted, and each adds its own wait", async () => {
        const { db, stats } = timedDb(seeded(), stepClock());
        await Promise.all([db.prepare("SELECT 1 AS x").first(), db.prepare("SELECT 2 AS x").first(), db.prepare("SELECT 3 AS x").all()]);
        expect(stats.n).toBe(3);
        expect(stats.ms).toBeGreaterThan(0);
    });
    it("ms adds up the wall time of each round trip, failures included", async () => {
        const { db, stats } = timedDb(seeded(), stepClock());
        await db.prepare("SELECT 1 AS x").first();
        expect(stats).toEqual({ n: 1, ms: 7 });
        await expect(db.prepare("SELECT * FROM nope").all()).rejects.toThrow(/no such table/);
        expect(stats).toEqual({ n: 2, ms: 14 });
    });
});

describe("timedDb: the same answers as the database it wraps", () => {
    it("first, first(column), all and run give what the binding gives", async () => {
        const plain = seeded();
        const { db } = timedDb(seeded());
        for (const d of [plain, db]) await d.prepare("UPDATE t SET v = ?1 WHERE n = ?2").bind("B", 2).run();
        const each = async (d: D1Database) => [
            await d.prepare("SELECT * FROM t WHERE n = ?1").bind(2).first(),
            await d.prepare("SELECT v FROM t WHERE n = ?1").bind(3).first("v"),
            await d.prepare("SELECT * FROM t WHERE n = 99").first(),
            await d.prepare("SELECT * FROM t ORDER BY n DESC").all(),
            await d.prepare("UPDATE t SET n = n WHERE n > ?1").bind(1).run(),
            await d.prepare("INSERT INTO t (v, n) VALUES ('d', 4) RETURNING id, v").all(),
        ];
        expect(await each(db)).toEqual(await each(plain));
        expect((await db.prepare("SELECT v FROM t WHERE n = 2").first<{ v: string }>())?.v).toBe("B");
    });
    it("a statement's failure is the binding's failure: same message, thrown at the same call", async () => {
        const { db } = timedDb(seeded());
        const bad = db.prepare("SELECT nope FROM t");
        await expect(bad.first()).rejects.toThrow(/no such column/);
        await expect(db.prepare("INSERT INTO t (id, v) VALUES (1, 'dup')").run()).rejects.toThrow(/UNIQUE|constraint/i);
        const down = createFakeD1(SCHEMA);
        const t = timedDb(down);
        down.breakIt();
        await expect(t.db.prepare("SELECT 1").first()).rejects.toThrow("D1_ERROR: simulated outage");
        expect(t.stats.n).toBe(1);
    });
    it("everything else on the database is the binding's own (the fake's raw handle and its switch)", async () => {
        const real = seeded();
        const { db } = timedDb(real);
        expect(db.raw).toBe(real.raw);
        db.breakIt();
        await expect(real.prepare("SELECT 1").first()).rejects.toThrow("simulated outage");
    });
    it("methods are called on the binding itself, never on the wrapper", async () => {
        // a binding as strict as the runtime's: every method checks what it was called on
        class Statement {
            #sql: string;
            #params: unknown[];
            constructor(sql: string, params: unknown[] = []) {
                this.#sql = sql;
                this.#params = params;
            }
            bind(...p: unknown[]) {
                return new Statement(this.#sql, p);
            }
            async first() {
                return { sql: this.#sql, params: this.#params };
            }
            async all() {
                return { results: [{ sql: this.#sql, params: this.#params }] };
            }
            async run() {
                return { meta: { changes: this.#params.length } };
            }
            async raw() {
                return [[this.#sql]];
            }
            describe() {
                return `${this.#sql} ${JSON.stringify(this.#params)}`;
            }
        }
        class Session {
            #db: Database;
            constructor(db: Database) {
                this.#db = db;
            }
            prepare(sql: string) {
                return this.#db.prepare(`/* session */ ${sql}`);
            }
            async batch(s: Statement[]) {
                return this.#db.batch(s);
            }
            getBookmark() {
                return this.#db.name();
            }
        }
        class Database {
            #name = "strict";
            prepare(sql: string) {
                return new Statement(`${this.#name}: ${sql}`);
            }
            async batch(statements: Statement[]) {
                // a private read on each: throws unless they are real Statements
                return statements.map((s) => s.describe());
            }
            async exec(sql: string) {
                return { count: sql.split(";").length, duration: 0, name: this.#name };
            }
            withSession() {
                return new Session(this);
            }
            async dump() {
                return new TextEncoder().encode(this.#name).buffer;
            }
            name() {
                return this.#name;
            }
        }
        const { db, stats } = timedDb(new Database() as unknown as D1Database);
        expect(await db.prepare("A").bind(1, 2).first()).toEqual({ sql: "strict: A", params: [1, 2] });
        expect(await db.prepare("A").bind(1).all()).toEqual({ results: [{ sql: "strict: A", params: [1] }] });
        expect(await db.prepare("A").bind(1, 2, 3).run()).toEqual({ meta: { changes: 3 } });
        expect(await db.prepare("A").raw()).toEqual([["strict: A"]]);
        expect(await db.batch([db.prepare("B").bind(9), db.prepare("C")])).toEqual(['strict: B [9]', "strict: C []"]);
        expect(await db.exec("X; Y")).toEqual({ count: 2, duration: 0, name: "strict" });
        expect(stats.n).toBe(6);
        // a session counts on the same stats; its bookmark and the dump pass through uncounted
        const session = db.withSession("first-primary");
        expect(await session.prepare("S").bind(1).first()).toEqual({ sql: "strict: /* session */ S", params: [1] });
        expect(await session.batch([session.prepare("T")])).toEqual(["strict: /* session */ T []"]);
        expect(stats.n).toBe(8);
        expect(session.getBookmark()).toBe("strict");
        expect(new TextDecoder().decode(await db.dump())).toBe("strict");
        expect(stats.n).toBe(8);
    });
    it("fails open: a database that cannot be wrapped is handed back as it came", () => {
        const notAnObject = "not a binding" as unknown as D1Database;
        const t = timedDb(notAnObject);
        expect(t.db).toBe(notAnObject);
        expect(t.stats).toEqual({ n: 0, ms: 0 });
    });
});

describe("withD1Timing: the request's one line", () => {
    const request = (url: string, init: RequestInit = {}, colo?: string) => {
        const r = new Request(url, init);
        if (colo) Object.defineProperty(r, "cf", { value: { colo, country: "SG" } });
        return r;
    };

    it("D1_TIMING \"1\": the handler gets a counted DB, and one JSON line follows the response", async () => {
        const real = seeded();
        const lines: string[] = [];
        const env = { DB: real as D1Database, D1_TIMING: "1", OTHER: "kept" };
        const res = await withD1Timing(
            request("https://api.capybaraharmony.com/library/items/01ABC?secret=tok&sig=abc", { headers: { authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11" } }, "SIN"),
            env,
            async (e) => {
                expect(e).not.toBe(env);
                expect(e.DB).not.toBe(real);
                expect(e.OTHER).toBe("kept");
                await e.DB.prepare("SELECT 1 AS x").first();
                await e.DB.batch([e.DB.prepare("UPDATE t SET n = n"), e.DB.prepare("UPDATE t SET v = v")]);
                expect(lines).toEqual([]);
                return new Response("{}", { status: 207 });
            },
            (l) => lines.push(l),
            stepClock(),
        );
        expect(res.status).toBe(207);
        expect(lines).toHaveLength(1);
        expect(JSON.parse(lines[0]!)).toEqual({ evt: "req", method: "GET", path: "/library/items/*", status: 207, ms: 35, d1: { n: 2, ms: 14 }, colo: "SIN" });
        // the pathname's route words and nothing else of the URL; no header
        expect(lines[0]).not.toMatch(/secret|tok|sig|01ABC|Api-Key|0b5f2c3e|authorization|SG/);
        expect(env.DB).toBe(real);
    });
    it("the line has exactly these fields, in this order; no colo when the runtime gave none", async () => {
        const lines: string[] = [];
        await withD1Timing(request("https://api.capybaraharmony.com/", { method: "POST" }), { DB: seeded() as D1Database, D1_TIMING: "1" }, async () => new Response(null, { status: 404 }), (l) => lines.push(l), () => 5);
        expect(lines).toEqual(['{"evt":"req","method":"POST","path":"/","status":404,"ms":0,"d1":{"n":0,"ms":0}}']);
    });
    it("a credential in the path never reaches the line: the MCP link, an upload link, the canvas, a studio session, a private link", async () => {
        const secrets = {
            mcp: "AbCdEfGhIjKlMnOpQrStUvWxYz012345",
            upload: `${"eyJ0IjoiYWJjIiwiayI6ImRlZiJ9".padEnd(40, "x")}.${"s".repeat(43)}`,
            live: "Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0Pp",
            sid: "aB3dE6gH9jK2mN5pQ8sT1u",
            link: "abcdefghijklmnopqrstuv",
        };
        const cases: [string, string, string][] = [
            ["POST", `https://api.capybaraharmony.com/mcp/k/${secrets.mcp}`, "/mcp/k/*"],
            ["PUT", `https://api.capybaraharmony.com/mcp/upload/${secrets.upload}`, "/mcp/upload/*"],
            ["GET", `https://studio.capybaraharmony.com/live/${secrets.live}`, "/live/*"],
            ["GET", `https://studio.capybaraharmony.com/live/${secrets.live}/ws`, "/live/*/ws"],
            ["POST", `https://api.capybaraharmony.com/studio/${secrets.sid}/render/aB3dE6gH9jK2mN5pQ8sT`, "/studio/*/render/*"],
            ["GET", `https://share.capybaraharmony.com/p/${secrets.link}`, "/p/*"],
            ["GET", `https://share.capybaraharmony.com/c/${secrets.link}/files/a.png`, "/c/*/files/*"],
        ];
        for (const [method, url, path] of cases) {
            const lines: string[] = [];
            await withD1Timing(request(url, { method }), { DB: seeded() as D1Database, D1_TIMING: "1" }, async () => new Response(null), (l) => lines.push(l), () => 5);
            expect(JSON.parse(lines[0]!).path).toBe(path);
            for (const secret of Object.values(secrets)) expect(lines[0]).not.toContain(secret);
        }
    });
    it("anything but \"1\": the handler gets the env itself and nothing is logged", async () => {
        for (const value of [undefined, "0", "", "true", "on"]) {
            const real = seeded();
            const lines: string[] = [];
            const env = { DB: real as D1Database, D1_TIMING: value };
            const res = await withD1Timing(
                request("https://api.capybaraharmony.com/library"),
                env,
                async (e) => {
                    expect(e).toBe(env);
                    expect(e.DB).toBe(real);
                    return new Response("ok");
                },
                (l) => lines.push(l),
            );
            expect(await res.text()).toBe("ok");
            expect(lines).toEqual([]);
        }
    });
    it("a handler that throws: the same error goes on, after a line that says so", async () => {
        const lines: string[] = [];
        const boom = new Error("boom");
        await expect(
            withD1Timing(
                request("https://api.capybaraharmony.com/library"),
                { DB: seeded() as D1Database, D1_TIMING: "1" },
                async (e) => {
                    await e.DB.prepare("SELECT 1").first();
                    throw boom;
                },
                (l) => lines.push(l),
                () => 0,
            ),
        ).rejects.toBe(boom);
        expect(JSON.parse(lines[0]!)).toEqual({ evt: "req", method: "GET", path: "/library", status: 500, ms: 0, d1: { n: 1, ms: 0 }, threw: true });
    });
    it("a log that fails never costs the answer", async () => {
        const res = await withD1Timing(
            request("https://api.capybaraharmony.com/library"),
            { DB: seeded() as D1Database, D1_TIMING: "1" },
            async () => new Response("still here"),
            () => {
                throw new Error("log is down");
            },
        );
        expect(await res.text()).toBe("still here");
    });
    it("every request of the isolate gets the SAME wrapped DB, so what other modules remember per database object stays remembered", async () => {
        const real = seeded();
        real.raw.exec("CREATE TABLE media_hidden (post_key TEXT); CREATE TABLE hidden_rules (id TEXT)");
        const env = { DB: real as D1Database, D1_TIMING: "1" };
        const seen: D1Database[] = [];
        const lines: string[] = [];
        const once = () =>
            withD1Timing(
                request("https://api.capybaraharmony.com/library"),
                env,
                async (e) => {
                    seen.push(e.DB);
                    // hidden-store.ts keeps "migration 0025 is applied" per database object for the isolate's life
                    expect(await hiddenReady(e.DB)).toBe(true);
                    return new Response("ok");
                },
                (l) => lines.push(l),
            );
        await once();
        await once();
        await once();
        expect(seen[0]).not.toBe(real);
        expect(seen[1]).toBe(seen[0]);
        expect(seen[2]).toBe(seen[0]);
        // asked once, by the first request; a wrapper per request would ask every time
        expect(lines.map((l) => JSON.parse(l).d1.n)).toEqual([1, 0, 0]);
        // another binding gets a wrapper of its own
        const other: D1Database[] = [];
        await withD1Timing(request("https://api.capybaraharmony.com/"), { DB: seeded() as D1Database, D1_TIMING: "1" }, async (e) => (other.push(e.DB), new Response("ok")), () => {});
        expect(other[0]).not.toBe(seen[0]);
    });
    it("requests served at once are counted apart, each line its own", async () => {
        const env = { DB: seeded() as D1Database, D1_TIMING: "1" };
        const lines: string[] = [];
        const pause = () => new Promise((r) => setTimeout(r, 5));
        const serve = (path: string, statements: number) =>
            withD1Timing(
                request(`https://api.capybaraharmony.com${path}`),
                env,
                async (e) => {
                    for (let i = 0; i < statements; i++) {
                        await e.DB.prepare("SELECT ?1 AS x").bind(i).first();
                        await pause();
                    }
                    return new Response(path);
                },
                (l) => lines.push(l),
            );
        await Promise.all([serve("/one", 1), serve("/five", 5), serve("/none", 0), serve("/three", 3)]);
        const byPath = Object.fromEntries(lines.map((l) => [JSON.parse(l).path, JSON.parse(l).d1.n]));
        expect(byPath).toEqual({ "/one": 1, "/five": 5, "/none": 0, "/three": 3 });
    });
    it("a round trip still out when the response is ready (work left to waitUntil) is not in the line", async () => {
        const real = seeded();
        const lines: string[] = [];
        let release!: () => void;
        const held = new Promise<void>((r) => (release = r));
        // a database whose UPDATE does not come back until the test says so
        const slow = new Proxy(real, {
            get: (target, prop) =>
                prop !== "prepare"
                    ? (target as any)[prop]
                    : (sql: string) => {
                          const s = target.prepare(sql);
                          return /^UPDATE/.test(sql) ? { ...s, run: async () => (await held, s.run()) } : s;
                      },
        });
        let background: Promise<unknown> | undefined;
        await withD1Timing(
            request("https://api.capybaraharmony.com/"),
            { DB: slow as D1Database, D1_TIMING: "1" },
            async (e) => {
                await e.DB.prepare("SELECT 1 AS x").first();
                background = e.DB.prepare("UPDATE t SET n = n").run();
                return new Response("answered");
            },
            (l) => lines.push(l),
        );
        expect(JSON.parse(lines[0]!).d1.n).toBe(1);
        release();
        await background;
        expect(lines).toHaveLength(1);
    });
    it("code that runs outside any timed request counts nowhere and still gets its answers", async () => {
        const env = { DB: seeded() as D1Database, D1_TIMING: "1" };
        let wrapped!: D1Database;
        await withD1Timing(request("https://api.capybaraharmony.com/"), env, async (e) => ((wrapped = e.DB), new Response("ok")), () => {});
        expect(await wrapped.prepare("SELECT count(*) AS c FROM t").first("c")).toBe(3);
    });
    it("the response is the handler's own object (its body is not read or copied)", async () => {
        const out = new Response("body");
        const res = await withD1Timing(request("https://api.capybaraharmony.com/"), { DB: seeded() as D1Database, D1_TIMING: "1" }, async () => out, () => {});
        expect(res).toBe(out);
        expect(out.bodyUsed).toBe(false);
    });
});

describe("maskPath: the route's words and nothing else", () => {
    it("keeps fixed words, masks ids, names and tokens", () => {
        expect(maskPath("/")).toBe("/");
        expect(maskPath("")).toBe("");
        expect(maskPath("/library")).toBe("/library");
        expect(maskPath("/library/")).toBe("/library/");
        expect(maskPath("/auth/signout-others")).toBe("/auth/signout-others");
        expect(maskPath("/library/items/aB3dE6gH9jK2mN5p/post-details/avatar")).toBe("/library/items/*/post-details/avatar");
        expect(maskPath("/auth/sessions/5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7")).toBe("/auth/sessions/*");
        expect(maskPath("/hidden/rules/12")).toBe("/hidden/rules/*");
        expect(maskPath("/media/aB3dE6gH9j.webp")).toBe("/media/*");
        expect(maskPath("/robots.txt")).toBe("/*");
        expect(maskPath("/library/%2e%2e/x")).toBe("/library/*/x");
    });
    it("a token cannot pass as a word: anything over 20 characters is masked whatever it is made of", () => {
        expect(maskPath(`/mcp/k/${"a".repeat(20)}`)).toBe(`/mcp/k/${"a".repeat(20)}`);
        expect(maskPath(`/mcp/k/${"a".repeat(21)}`)).toBe("/mcp/k/*");
        expect(maskPath(`/p/${"a".repeat(22)}`)).toBe("/p/*");
        // a capital, a digit, a dot or an underscore anywhere masks a short one too
        for (const segment of ["Abcdef", "abc1", "a.b", "a_b", "-abc", "1abc"]) expect(maskPath(`/x/${segment}`)).toBe("/x/*");
    });
    it("every fixed word of every registered route survives, so the lines group by route", () => {
        const words = new Set<string>();
        for (const op of REGISTRY.ops) {
            for (const segment of (op.route?.path ?? "").split("/")) if (segment !== "" && segment !== "*" && !segment.startsWith(":")) words.add(segment);
        }
        expect(words.size).toBeGreaterThan(40);
        for (const word of words) expect(maskPath(`/${word}`)).toBe(`/${word}`);
    });
});

describe("timedDb: a method the database does not have", () => {
    it("stays missing on the wrapper, so code that asks before it calls takes the same path", async () => {
        const fake = createFakeD1(SCHEMA);
        expect(typeof (fake as any).batch).toBe("undefined");
        const { db, stats } = timedDb(fake);
        expect(typeof (db as any).batch).toBe("undefined");
        expect(typeof (db as any).exec).toBe(typeof (fake as any).exec);
        expect(typeof (db as any).withSession).toBe(typeof (fake as any).withSession);
        // the pattern of names.ts, safety-store.ts and about-store.ts
        const statements = [db.prepare("INSERT INTO t (v, n) VALUES ('a', 1)"), db.prepare("INSERT INTO t (v, n) VALUES ('b', 2)")];
        if (typeof (db as { batch?: unknown }).batch === "function") await db.batch(statements);
        else for (const s of statements) await s.run();
        expect(stats.n).toBe(2);
        expect(fake.raw.prepare("SELECT count(*) AS c FROM t").get()).toEqual({ c: 2 });
    });
    it("and is wrapped where the database has it", async () => {
        const { db, stats } = timedDb(seeded());
        expect(typeof db.batch).toBe("function");
        await db.batch([db.prepare("UPDATE t SET n = n")]);
        expect(stats.n).toBe(1);
    });
});
