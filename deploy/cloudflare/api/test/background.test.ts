// background() (src/background.ts) and the request log written through it (src/request-log.ts): the answer is not held
// by the INSERT when there is a waitUntil, and nothing changes where there is none.
import { afterEach, describe, expect, it, vi } from "vitest";
import { background } from "../src/background";
import { hashKey } from "../src/keys";
import { logRequest, type BodyInfo } from "../src/request-log";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

// A promise the test settles by hand.
const gate = <T = void>() => {
    let open!: (v: T) => void;
    let fail!: (e: unknown) => void;
    const promise = new Promise<T>((res, rej) => {
        open = res;
        fail = rej;
    });
    return { promise, open, fail };
};
const settled = async (p: Promise<unknown>) => {
    let done = false;
    void p.then(
        () => (done = true),
        () => (done = true),
    );
    for (let i = 0; i < 5; i++) await Promise.resolve();
    return done;
};

afterEach(() => vi.restoreAllMocks());

describe("background()", () => {
    it("starts the work before it returns, with or without a waitUntil", () => {
        const order: string[] = [];
        void background(undefined, async () => void order.push("work"));
        order.push("after");
        void background(
            () => {},
            async () => void order.push("work"),
        );
        order.push("after");
        expect(order).toEqual(["work", "after", "work", "after"]);
    });
    it("with a waitUntil: resolves at once and hands the work over", async () => {
        const g = gate();
        const kept: Promise<unknown>[] = [];
        let finished = false;
        const p = background(
            (w) => kept.push(w),
            async () => {
                await g.promise;
                finished = true;
            },
        );
        expect(await settled(p)).toBe(true);
        expect(finished).toBe(false);
        expect(kept).toHaveLength(1);
        g.open();
        await kept[0];
        expect(finished).toBe(true);
    });
    it("with a waitUntil: a failure never rejects, neither for the caller nor for the waitUntil; it goes to the console", async () => {
        const logged = vi.spyOn(console, "error").mockImplementation(() => {});
        const kept: Promise<unknown>[] = [];
        await expect(background((w) => kept.push(w), () => Promise.reject(new TypeError("boom")))).resolves.toBeUndefined();
        await expect(kept[0]).resolves.toBeUndefined();
        expect(logged).toHaveBeenCalledTimes(1);
        expect(logged.mock.calls[0]).toEqual(["[background] work failed", "TypeError: boom"]);
        // a throw before the first await is the same failure
        await expect(
            background((w) => kept.push(w), () => {
                throw new Error("sync");
            }),
        ).resolves.toBeUndefined();
        await kept[1];
        expect(logged).toHaveBeenCalledTimes(2);
    });
    it("without a waitUntil: waits for the work, as an inline await would", async () => {
        const g = gate();
        let finished = false;
        const p = background(undefined, async () => {
            await g.promise;
            finished = true;
        });
        expect(await settled(p)).toBe(false);
        g.open();
        await expect(p).resolves.toBeUndefined();
        expect(finished).toBe(true);
    });
    it("without a waitUntil: a failure rejects, as an inline await would (a call site that swallowed it keeps its own catch)", async () => {
        const logged = vi.spyOn(console, "error").mockImplementation(() => {});
        await expect(background(undefined, () => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
        await expect(
            background(undefined, () => {
                throw new Error("sync");
            }),
        ).rejects.toThrow("sync");
        await expect(background(undefined, async () => "a value")).resolves.toBeUndefined();
        expect(logged).not.toHaveBeenCalled();
    });
    it("a waitUntil that refuses the work: it is waited for here instead of dropped", async () => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const g = gate();
        let finished = false;
        const p = background(
            () => {
                throw new Error("the request is over");
            },
            async () => {
                await g.promise;
                finished = true;
            },
        );
        expect(await settled(p)).toBe(false);
        g.open();
        await p;
        expect(finished).toBe(true);
    });
});

const INFO: BodyInfo = { contentType: "application/json", bytes: 2, keys: "url", urlType: "string", urlLen: 20, urlPrefix: "https://example.com/" };
const rows = (db: FakeD1) => db.raw.prepare("SELECT route, key_id, user_agent, status, result, error_code FROM request_log ORDER BY ts, rowid").all() as Record<string, unknown>[];
const jsonRes = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("logRequest: what it needs is taken before its first await", () => {
    const request = new Request("https://api.example/", { method: "POST", headers: { "user-agent": "Shortcuts/1" }, body: "{}" });

    it("the response's body can be used up by the client right after the call; the row still has result and error code", async () => {
        const db = createFakeD1();
        const res = jsonRes({ status: "error", error: { code: "error.api.link.invalid" } }, 400);
        const written = logRequest(db, "POST /", "k-1", request, INFO, res);
        // what the runtime does with a returned response: its body is read to the end, and no clone is possible after
        expect(await res.text()).toBe('{"status":"error","error":{"code":"error.api.link.invalid"}}');
        expect(() => res.clone()).toThrow();
        await written;
        expect(rows(db)).toEqual([{ route: "POST /", key_id: "k-1", user_agent: "Shortcuts/1", status: 400, result: "error", error_code: "error.api.link.invalid" }]);
    });
    it("a response that can no longer be cloned still gets its row, without result and error code", async () => {
        const db = createFakeD1();
        const res = jsonRes({ status: "tunnel" });
        await res.text();
        await logRequest(db, "POST /", "k-1", request, INFO, res);
        expect(rows(db)).toEqual([{ route: "POST /", key_id: "k-1", user_agent: "Shortcuts/1", status: 200, result: null, error_code: null }]);
    });
    it("a body that is not JSON is not read; a D1 failure is swallowed", async () => {
        const db = createFakeD1();
        const res = new Response("plain", { status: 502, headers: { "content-type": "text/plain" } });
        await logRequest(db, "POST /webp", "k-1", request, INFO, res);
        expect(await res.text()).toBe("plain");
        expect(rows(db)).toEqual([{ route: "POST /webp", key_id: "k-1", user_agent: "Shortcuts/1", status: 502, result: null, error_code: null }]);
        db.breakIt();
        await expect(logRequest(db, "POST /", "k-1", request, INFO, jsonRes({ status: "tunnel" }))).resolves.toBeUndefined();
    });
});

describe("the logged routes do not wait for the row when there is a waitUntil", () => {
    const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
    const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const ORIGIN = "https://cobalt.capybaraharmony.com";

    // A database whose request_log INSERT hangs until the test lets it through; every other statement runs at once.
    const world = async () => {
        const fake = createFakeD1();
        fake.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-row-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
        const hold = gate();
        let inserts = 0;
        const slow = (statement: any, sql: string): any =>
            new Proxy(statement, {
                get(target, prop) {
                    if (prop === "bind") return (...v: unknown[]) => slow(target.bind(...v), sql);
                    if (prop === "run" && /INSERT INTO request_log/.test(sql)) {
                        return async () => {
                            inserts++;
                            await hold.promise;
                            return target.run();
                        };
                    }
                    return target[prop];
                },
            });
        const db = new Proxy(fake, { get: (target, prop) => (prop === "prepare" ? (sql: string) => slow(target.prepare(sql), sql) : (target as any)[prop]) });
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: ORIGIN,
            COBALT_API_KEY: INTERNAL,
            DB: db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        };
        const container = { fetch: async () => jsonRes({ status: "tunnel", url: "https://api.capybaraharmony.com/tunnel?id=1" }) };
        const kept: Promise<unknown>[] = [];
        const post = (path: string, withWaitUntil: boolean, headers: Record<string, string> = {}) =>
            handleRequest(
                new Request(`https://api.capybaraharmony.com${path}`, {
                    method: "POST",
                    headers: { authorization: `Api-Key ${CLIENT}`, "content-type": "application/json", "user-agent": "test/1", ...headers },
                    body: JSON.stringify({ url: "https://example.com/v/1" }),
                }),
                env,
                container,
                withWaitUntil ? { waitUntil: (p) => void kept.push(p) } : {},
            );
        return { fake, hold, kept, post, inserts: () => inserts };
    };

    for (const [path, route, headers] of [
        ["/", "POST /", {}],
        // the web origin: the reply is rebuilt with the CORS header, so its body is taken over before the row is written
        ["/webp", "POST /webp", { origin: ORIGIN }],
    ] as const) {
        it(`${route}: answered while the INSERT is still waiting; the row arrives through waitUntil with the reply's result`, async () => {
            const w = await world();
            const res = await w.post(path, true, headers);
            expect(res.status).toBe(200);
            expect(await res.json()).toEqual({ status: "tunnel", url: "https://api.capybaraharmony.com/tunnel?id=1" });
            expect(w.inserts()).toBe(1);
            expect(rows(w.fake)).toEqual([]);
            expect(w.kept).toHaveLength(1);
            w.hold.open();
            await Promise.all(w.kept);
            expect(rows(w.fake)).toEqual([{ route, key_id: "key-row-1", user_agent: "test/1", status: 200, result: "tunnel", error_code: null }]);
        });
    }
    it("POST / without a waitUntil: the answer waits for the row, as before", async () => {
        const w = await world();
        const pending = w.post("/", false);
        expect(await settled(pending)).toBe(false);
        // the lookup and the forward have happened; only the INSERT is outstanding
        await vi.waitFor(() => expect(w.inserts()).toBe(1));
        expect(await settled(pending)).toBe(false);
        w.hold.open();
        const res = await pending;
        expect(await res.json()).toEqual({ status: "tunnel", url: "https://api.capybaraharmony.com/tunnel?id=1" });
        expect(rows(w.fake)).toHaveLength(1);
    });
});
