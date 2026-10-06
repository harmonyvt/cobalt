// The server's line (APP-API-CONTRACT.md section 17): queued saves and renders, the order they run in,
// the two guards that would silently jump the line or lose a job, the pump, the ceilings, cancel,
// `GET /studio/line`, the validation of `queue` / `title` / `priority`, and the gate. The Hark
// summary has its own file (line-notify.test.ts).
import { describe, expect, it, vi } from "vitest";
import { decide, type GateRequest } from "../src/gate";
import { KEY_ID_HEADER, SERVICE_HEADER } from "../src/headers";
import {
    LINE_BUSY_WAIT_MS,
    LINE_MAX,
    LINE_START_STALE_MS,
    LINE_WAIT_MS,
    LineStore,
    classOf,
    lineKey,
    parseFlag,
    parseQueryFlag,
    type LineEntry,
} from "../src/line";
import { SESSION_TTL_MS, handleStudioRoute } from "../src/studio";
import { CLIENT, INTERNAL, KEY_ID, LINK, auth, asBody, json, svc } from "./poster-world";
import { CLIENT2, KEY2_ID, auth2, lineWorld, type LW } from "./line-world";
import { MemoryKV } from "./studio-fakes";

const link = (n: number | string) => `${LINK}?n=${n}`;
const create = (L: LW, body: Record<string, unknown>, keyId = KEY_ID) => L.studio.create(keyId, json({ url: LINK, ...body }));
const startsOf = (L: LW) => L.helper.calls.filter((c) => c === "POST /fetch" || c === "POST /jobs/upload");
const fetchIds = (L: LW) => L.helper.fetchBodies.map((b) => b.id as string);

// A save that keeps the helper: R is running and every poll of it is "still downloading" until
// `release()`.
async function running(L: LW, extra: Record<string, unknown> = {}) {
    L.helper.fetchPolls = 1e9;
    const r = asBody(await create(L, { url: link("run"), ...extra }));
    expect(r.id).toMatch(/^[A-Za-z0-9]{22}$/);
    return { sid: r.id as string, release: () => (L.helper.fetchPolls = 0), body: r };
}

describe("LineStore (the order is the DO's key order)", () => {
    const entry = (sid: string, over: Partial<LineEntry> = {}): Omit<LineEntry, "starting" | "attempts"> => ({
        kind: "save", sid, job: null, keyId: "k", at: 1, origin: null, adopt: false, render: null, ...over,
    });
    it("keys are line:<class>:<12-digit seq>; class 0 (focused) sorts before class 1", () => {
        expect(lineKey("1", 7)).toBe("line:1:000000000007");
        expect(classOf(true)).toBe("0");
        expect(classOf(false)).toBe("1");
        expect(["line:1:000000000001", "line:0:000000000009", "line:1:000000000002"].sort()).toEqual([
            "line:0:000000000009", "line:1:000000000001", "line:1:000000000002",
        ]);
    });
    it("list() is first in first out within a class, focused first, even when the map lists in insertion order", async () => {
        const kv = new MemoryKV();
        const store = new LineStore(kv, () => 0);
        await store.enqueue(entry("a"), false);
        await store.enqueue(entry("b"), false);
        await store.enqueue(entry("f1", { kind: "render", job: "j1" }), true);
        await store.enqueue(entry("c"), false);
        await store.enqueue(entry("f2", { kind: "render", job: "j2" }), true);
        expect((await store.list()).map((e) => e.entry.sid)).toEqual(["f1", "f2", "a", "b", "c"]);
        // the counter is not under the line: prefix, and never reused
        expect(kv.m.get("lineseq")).toBe(5);
        await store.remove((await store.list())[0]!.key);
        await store.enqueue(entry("d"), false);
        expect((await store.list()).map((e) => e.entry.sid)).toEqual(["f2", "a", "b", "c", "d"]);
    });
    it("find() answers the save of a session or one render job, with its index", async () => {
        const store = new LineStore(new MemoryKV(), () => 0);
        await store.enqueue(entry("a"), false);
        await store.enqueue(entry("a", { kind: "render", job: "j1" }), false);
        expect((await store.find("a"))!.entry.kind).toBe("save");
        expect((await store.find("a", "j1"))).toMatchObject({ index: 1, entry: { kind: "render", job: "j1" } });
        expect(await store.find("a", "nope")).toBeNull();
        expect(await store.find("zz")).toBeNull();
    });
    it("is full at LINE_MAX entries (all keys) and then writes nothing", async () => {
        const kv = new MemoryKV();
        const store = new LineStore(kv, () => 0);
        for (let i = 0; i < LINE_MAX; i++) expect(await store.enqueue(entry(`s${i}`), i % 2 === 0)).toHaveProperty("key");
        const before = kv.m.size;
        expect(await store.enqueue(entry("over"), false)).toEqual({ full: true });
        expect(kv.m.size).toBe(before);
    });
    it("concurrent enqueues never share a sequence number", async () => {
        const store = new LineStore(new MemoryKV(), () => 0);
        const keys = await Promise.all(Array.from({ length: 10 }, (_, i) => store.enqueue(entry(`s${i}`), false)));
        expect(new Set(keys.map((k) => (k as { key: string }).key)).size).toBe(10);
        expect((await store.list()).map((e) => e.entry.sid)).toEqual(Array.from({ length: 10 }, (_, i) => `s${i}`));
    });
    it("the flags: absent, null and false are no; only booleans (body) and 1/true/0/false (query) are valid", () => {
        expect([parseFlag(undefined), parseFlag(null), parseFlag(false), parseFlag(true)]).toEqual([false, false, false, true]);
        for (const bad of ["yes", 1, 0, [], {}, "true"]) expect(parseFlag(bad)).toBeNull();
        expect([parseQueryFlag(null), parseQueryFlag(""), parseQueryFlag("1"), parseQueryFlag("true"), parseQueryFlag("0"), parseQueryFlag("false")]).toEqual([
            false, false, true, true, false, false,
        ]);
        expect(parseQueryFlag("maybe")).toBeNull();
    });
    it("the constants are the contract's", () => {
        expect(LINE_MAX).toBe(50);
        expect(LINE_WAIT_MS).toBe(30 * 60 * 1000);
        expect(LINE_BUSY_WAIT_MS).toBe(10 * 60 * 1000);
        expect(LINE_START_STALE_MS).toBe(6 * 60 * 1000);
    });
});

describe("order", () => {
    it("three queued saves run in the order they joined, one start per sweep pass, with nobody polling", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const ids: string[] = [];
        for (let i = 1; i <= 3; i++) {
            const r = asBody(await create(L, { url: link(i), queue: true }));
            expect(r).toMatchObject({ status: "success", queued: true, queue_ahead: i });
            ids.push(r.id);
        }
        // the running save is never interrupted and nothing else starts while it runs
        await L.sweeps(3);
        expect(fetchIds(L)).toEqual([R.sid]);
        expect(L.keys("save:")).toEqual([`save:${R.sid}`]);
        expect(L.entries().map((e) => e.sid)).toEqual(ids);

        R.release();
        // each pass ends the running save and starts exactly the next one
        await L.studio.sweep();
        expect(fetchIds(L)).toEqual([R.sid, ids[0]]);
        expect(L.rows("SELECT status FROM studio_sessions WHERE id = ?", R.sid)).toEqual([{ status: "ready" }]);
        await L.studio.sweep();
        expect(fetchIds(L)).toEqual([R.sid, ids[0], ids[1]]);
        await L.studio.sweep();
        expect(fetchIds(L)).toEqual([R.sid, ids[0], ids[1], ids[2]]);
        await L.studio.sweep();
        for (const sid of [R.sid, ...ids]) expect(L.session(sid).status).toBe("ready");
        expect(L.entries()).toEqual([]);
        expect(L.keys("save:")).toEqual([]);
    });

    it("a focused render queued after them runs before the 2nd, two focused renders keep their order, nothing running is interrupted", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        const f1 = asBody(await L.render(S.sid, { queue: true, priority: "focused" }));
        const f2 = asBody(await L.render(S.sid, { start: 1, queue: true, priority: "focused" }));
        expect(f1).toMatchObject({ status: "pending", queued: true, queue_ahead: 1 });
        expect(f2).toMatchObject({ status: "pending", queued: true, queue_ahead: 2 });
        // a and b are behind both renders now: the running save, f1, f2, then a
        expect(asBody(await L.studio.advance(a.id, 0))).toMatchObject({ step: "queued", queue_ahead: 3 });
        expect(asBody(await L.studio.advance(b.id, 0))).toMatchObject({ step: "queued", queue_ahead: 4 });

        // the running save keeps the helper: not interrupted, no render started
        await L.sweeps(2);
        expect(L.helper.calls).not.toContain("POST /jobs/upload");
        expect(L.keys("save:")).toEqual([`save:${R.sid}`]);

        L.helper.jobPolls = 1e9; // a render keeps the helper until its result is collected
        R.release();
        await L.studio.sweep();
        expect(startsOf(L)).toEqual(["POST /fetch", "POST /jobs/upload"]); // R, then f1 (not a)
        expect(L.helper.uploadQueries[0]!.get("id")).toBe(f1.job);
        await L.studio.sweep(); // f1 still encoding: f2 waits
        expect(startsOf(L)).toHaveLength(2);
        L.helper.jobPolls = 0;
        await L.studio.sweep(); // f1 collected, f2 starts
        expect(L.helper.uploadQueries.map((q) => q.get("id"))).toEqual([f1.job, f2.job]);
        await L.sweeps(3);
        expect(startsOf(L)).toEqual(["POST /fetch", "POST /jobs/upload", "POST /jobs/upload", "POST /fetch", "POST /fetch"]);
        expect(fetchIds(L)).toEqual([R.sid, a.id, b.id]);
        for (const job of [f1.job, f2.job]) {
            expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", job)).toEqual([{ status: "success" }]);
        }
        expect(L.entries()).toEqual([]);
    });

    it("a render that is not focused waits its turn behind the saves that joined before it", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const r = asBody(await L.render(S.sid, { queue: true }));
        expect(r.queue_ahead).toBe(2);
        R.release();
        await L.sweeps(3);
        expect(startsOf(L)).toEqual(["POST /fetch", "POST /fetch", "POST /jobs/upload"]);
        expect(fetchIds(L)).toEqual([R.sid, a.id]);
    });
});

describe("the free path is today's", () => {
    it("an empty line and a free helper: POST /studio answers {status, id, url} to a client that did not queue", async () => {
        const L = await lineWorld();
        const r = await create(L, {});
        expect(r.status).toBe(201);
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
        // and the save really started at once (the 4 s kick), with a `save:` record
        expect(L.keys("save:")).toHaveLength(1);
        expect(L.helper.calls).toContain("POST /fetch");
    });
    it("a client that queued sees queued: false, queue_ahead: null, and the same immediate start", async () => {
        const L = await lineWorld();
        const r = await create(L, { queue: true });
        expect(asBody(r)).toMatchObject({ queued: false, queue_ahead: null });
        expect(L.keys("save:")).toHaveLength(1);
        expect(L.entries()).toEqual([]);
    });
    it("a render on a free helper: 202 {status, job}; with queue: false/queued fields; nothing enters the line", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const plain = await L.render(S.sid, {});
        expect(plain.status).toBe(202);
        expect(Object.keys(plain.body as object).sort()).toEqual(["job", "status"]);
        await L.studio.renderStatus(S.sid, asBody(plain).job, 0);
        const lined = await L.render(S.sid, { queue: true, priority: "focused" });
        expect(asBody(lined)).toMatchObject({ status: "pending", queued: false, queue_ahead: null });
        expect(L.entries()).toEqual([]);
    });
    it("a queue-asking render whose free-path start meets the helper's 429 (a /webp job `held()` did not see) waits in the line instead", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.uploadBusy = true;
        const r = asBody(await L.render(S.sid, { queue: true }));
        expect(r).toMatchObject({ status: "pending", queued: true, queue_ahead: 0 });
        expect(L.entries()).toHaveLength(1);
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "pending" }]);
        // a client that did not ask to queue sees the 429
        const plain = await L.render(S.sid, {});
        expect(plain).toEqual({ status: 429, body: { status: "error", error: { code: "error.webp.busy" } } });
    });
    it("the app's adopt (upload, library item) on a free helper is today's answer", async () => {
        const L = await lineWorld();
        const adopt = (extra: Record<string, unknown> = {}) =>
            L.studio.adopt(
                KEY_ID,
                json({ r2_key: "uploads/ItemItem00000001.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "ItemItem00000001", ...extra }),
            );
        const plain = await adopt();
        expect(Object.keys(plain.body as object).sort()).toEqual(["id", "status", "url"]);
        expect(L.keys("save:")).toHaveLength(1);
    });
});

describe("fairness: nobody jumps the line", () => {
    it("an old client's POST /studio gets 429 busy while the helper is free but the line is not empty; so does the web page's path and a plain render", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        // the running save ends by a poll: the helper is free for a moment, `a` still waits
        R.release();
        await L.studio.advance(R.sid, 0);
        expect(L.keys("save:")).toEqual([]);
        expect(L.entries()).toHaveLength(1);

        expect(await create(L, { url: link("late") })).toEqual({ status: 429, body: { status: "error", error: { code: "error.studio.busy" } } });
        const web = await L.call("/studio", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: json({ url: link("web") }),
        });
        expect(web.status).toBe(429);
        expect(((await web.json()) as any).error.code).toBe("error.studio.busy");
        const render = await L.call(`/studio/${S.sid}/render`, { method: "POST", body: json({ start: 0, length: 2 }) });
        expect(render.status).toBe(429);
        expect(((await render.json()) as any).error.code).toBe("error.webp.busy");
        // nothing was created for the refused
        expect(L.rows("SELECT id FROM studio_sessions WHERE link LIKE '%late%' OR link LIKE '%web%'")).toEqual([]);

        // a client that asks to queue goes behind `a`
        expect(asBody(await create(L, { url: link("b"), queue: true }))).toMatchObject({ queued: true, queue_ahead: 1 });
        // and `a` starts first
        await L.studio.sweep();
        expect(fetchIds(L)).toEqual([R.sid, a.id]);
    });

    it("a focused render may take the free helper while only saves wait (it goes ahead of every save), but not ahead of an earlier focused one", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0); // helper free, `a` waits
        const f = asBody(await L.render(S.sid, { queue: true, priority: "focused" }));
        expect(f).toMatchObject({ queued: false, queue_ahead: null }); // took the free helper at once
        expect(L.helper.calls).toContain("POST /jobs/upload");
        expect(L.entries().map((e) => e.sid)).toEqual([a.id]);
    });
});

describe("share (origin: share) joins the line", () => {
    it("while busy it is queued: no `save:` record, no busy retry, listed by /studio/recent as queued, announced when it finishes through its opt-in", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const share = asBody(
            await create(L, {
                url: link("share"), public: true, origin: "share", notify: { on: ["saved", "failed"], label: "x · share" },
            }),
        );
        expect(share).toMatchObject({ status: "success", queued: true, queue_ahead: 1, notify: { bridge: true } });
        expect(L.kv.m.has(`save:${share.id}`)).toBe(false);
        expect(L.kv.m.has(`share:${share.id}`)).toBe(true);
        expect(L.entries()).toMatchObject([{ sid: share.id, origin: "share", kind: "save", keyId: KEY_ID }]);

        const recent = await L.keyed("/studio/recent");
        const list = ((await recent.json()) as any).sessions;
        expect(list).toHaveLength(1);
        expect(list[0]).toMatchObject({ id: share.id, status: "saving", step: "queued", queue_ahead: 1 });

        // the old 2 s retry loop is gone: sweeps while R runs never touch it
        await L.sweeps(3);
        expect(L.kv.m.has(`save:${share.id}`)).toBe(false);
        expect(L.hark.calls).toEqual([]);

        R.release();
        await L.sweeps(3);
        expect(L.session(share.id).status).toBe("ready");
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toContain("x · share is saved");
        expect(L.hark.calls[0]!.url).toBe(`cobalt-apple://session/${share.id}`);
    });
    it("a share that finds the helper free takes today's path: a `save:` record and the answer carries queued: false", async () => {
        const L = await lineWorld();
        const share = asBody(await create(L, { origin: "share" }));
        expect(share).toMatchObject({ queued: false, queue_ahead: null });
        expect(L.kv.m.has(`save:${share.id}`)).toBe(true);
    });
    it("a share waits up to 30 minutes, not 2: past the ceiling it ends with error.studio.busy, announced", async () => {
        const L = await lineWorld();
        await running(L);
        const share = asBody(await create(L, { origin: "share", url: link("s"), notify: { on: ["failed"] } }));
        L.clock.t += 3 * 60_000; // far past the old BUSY_WAIT_MS
        await L.sweeps(2);
        expect(L.session(share.id).status).toBe("saving");
        expect(L.entries()).toHaveLength(1);
        L.clock.t += LINE_WAIT_MS;
        await L.studio.sweep();
        expect(L.session(share.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toMatchObject({ title: "cobalt couldn't finish" });
        expect(L.hark.calls[0]!.body).toContain("the server was busy");
    });
    it("a share with the line full is refused 429 error.studio.line_full and creates nothing", async () => {
        const L = await lineWorld();
        await running(L);
        for (let i = 0; i < LINE_MAX; i++) expect((await create(L, { url: link(i), queue: true })).status).toBe(201);
        const before = L.rows("SELECT id FROM studio_sessions").length;
        const r = await create(L, { origin: "share", url: link("over") });
        expect(r).toEqual({ status: 429, body: { status: "error", error: { code: "error.studio.line_full" } } });
        expect(L.rows("SELECT id FROM studio_sessions")).toHaveLength(before);
        expect([...L.kv.m.keys()].filter((k) => k.startsWith("share:"))).toEqual([]);
    });
});

describe("polls never start a queued job (the two guards)", () => {
    it("GET /studio/<sid> of a queued save answers queued, with no `save:` record, no helper start, whoever polls and however long", async () => {
        const L = await lineWorld();
        await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const direct = asBody(await L.studio.advance(a.id, 0));
        expect(direct).toMatchObject({
            status: "saving", id: a.id, step: "queued", step_bytes: null, step_total: null, waking: false, queue_ahead: 1,
        });
        // through the Worker and the Durable Object, like the app does
        const viaWorker = (await (await L.call(`/studio/${a.id}`)).json()) as any;
        expect(viaWorker).toMatchObject({ status: "saving", step: "queued", queue_ahead: 1 });
        // a long poll holds, then answers the same, and still starts nothing
        const t0 = L.clock.t;
        const held = asBody(await L.studio.advance(a.id, 3));
        expect(held).toMatchObject({ step: "queued", queue_ahead: 1 });
        expect(L.clock.t - t0).toBeGreaterThanOrEqual(3000);
        expect(L.kv.m.has(`save:${a.id}`)).toBe(false);
        expect(fetchIds(L)).toHaveLength(1);
        expect(L.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(1);
        // the sweep's own save loop never visits it either
        await L.studio.sweep();
        expect(L.kv.m.has(`save:${a.id}`)).toBe(false);
    });
    it("the long poll returns by itself as soon as the sweep has started it", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0); // R is ready; a waits for the sweep
        await L.studio.pumpLine();
        expect(L.kv.m.has(`save:${a.id}`)).toBe(true);
        const r = asBody(await L.studio.advance(a.id, 0));
        expect(r.step).not.toBe("queued");
        expect(r.queue_ahead).toBeNull();
    });
    it("a queued render answers phase: queued, never job_lost, and never asks the webp service (which would 404 it)", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        const r = asBody(await L.render(S.sid, { queue: true }));
        const spy = vi.spyOn(L.webp, "status");
        for (let i = 0; i < 3; i++) {
            expect(await L.studio.renderStatus(S.sid, r.job, 0)).toEqual({
                status: 200,
                body: { status: "pending", job: r.job, phase: "queued", frames_done: null, frames_total: null, queue_ahead: 1 },
            });
        }
        expect(spy).not.toHaveBeenCalled();
        // through the Worker, unkeyed like every render poll
        const viaWorker = (await (await L.call(`/studio/${S.sid}/render/${r.job}`)).json()) as any;
        expect(viaWorker).toMatchObject({ status: "pending", phase: "queued", queue_ahead: 1 });
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "pending", error_code: null }]);
        // a queued render is not rendering: the live run is not told so
        expect(L.live.events.filter((e) => e.job === r.job)).toEqual([]);
        // an ordinary pending render still carries queue_ahead: null
        spy.mockRestore();
    });
    it("an old pending answer (a render that is running) says queue_ahead: null", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.jobPolls = 1e9;
        const r = asBody(await L.render(S.sid, {}));
        expect(asBody(await L.studio.renderStatus(S.sid, r.job, 0))).toMatchObject({ status: "pending", phase: null, queue_ahead: null });
    });
});

describe("the pump", () => {
    it("starts the head when the running save ends, by the sweep alone, with no client polling", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        await L.studio.sweep();
        expect(L.keys("save:")).toEqual([`save:${a.id}`]);
        expect(L.kv.m.get(`save:${a.id}`)).toMatchObject({ lined: true, queuedAt: expect.any(Number), phase: "fetching" });
        await L.studio.sweep();
        expect(L.session(a.id).status).toBe("ready");
    });
    it("at most one start per call: two waiting saves, a free helper, one pumpLine() starts only the first", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0);
        await L.studio.pumpLine();
        expect(fetchIds(L)).toEqual([R.sid, a.id]);
        await L.studio.pumpLine(); // `a` holds the helper now
        expect(fetchIds(L)).toEqual([R.sid, a.id]);
        expect(L.entries().map((e) => e.sid)).toEqual([b.id]);
    });
    it("a render start that meets a 429 stays at the head (attempts counted), and is retried by the next pass", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const r = asBody(await L.render(S.sid, { queue: true }));
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        L.helper.uploadBusy = true;
        await L.studio.sweep();
        expect(L.helper.calls.filter((c) => c === "POST /jobs/upload")).toHaveLength(1);
        expect(L.entries().map((e) => e.sid)).toEqual([S.sid, a.id]);
        expect(L.entries()[0]).toMatchObject({ job: r.job, attempts: 1, starting: null });
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "pending" }]);
        expect(fetchIds(L)).toEqual([R.sid]); // the save behind it did not jump it
        L.helper.uploadBusy = false;
        await L.studio.sweep();
        expect(L.entries().map((e) => e.sid)).toEqual([a.id]);
        expect(L.helper.uploadQueries.map((q) => q.get("id"))).toContain(r.job);
    });
    it("a render start that fails for good ends that render and starts the next entry in the same pass", async () => {
        const L = await lineWorld();
        const S1 = L.seed();
        const S2 = L.seed();
        const R = await running(L);
        const r1 = asBody(await L.render(S1.sid, { queue: true }));
        const r2 = asBody(await L.render(S2.sid, { queue: true }));
        L.originals.objects.delete(S1.r2); // its original is gone: the upload cannot be made
        R.release();
        await L.studio.sweep();
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r1.job)).toEqual([
            { status: "error", error_code: "error.webp.storage" },
        ]);
        expect(L.helper.uploadQueries.map((q) => q.get("id"))).toEqual([r2.job]);
        expect(L.entries()).toEqual([]);
        // the failure reached the live run, and the client's next poll just reads the row
        expect(L.live.events).toContainEqual({ sid: S1.sid, job: r1.job, e: { kind: "failed", code: "error.webp.storage" } });
        expect(await L.studio.renderStatus(S1.sid, r1.job, 0)).toEqual({
            status: 200,
            body: { status: "error", error: { code: "error.webp.storage" } },
        });
    });
    it("a render entry whose upload began, in a Durable Object that was evicted, is started again after LINE_START_STALE_MS (not before)", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const r = asBody(await L.render(S.sid, { queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0);
        // the upload began and the object died: `starting` set, no in-memory mark in the new one
        const [e] = L.entries();
        L.kv.m.set(e.key, { ...e, key: undefined, starting: L.clock.t });
        const reborn = L.make({ notify: L.notify });
        L.clock.t += LINE_START_STALE_MS - 1000;
        await reborn.sweep();
        expect(L.helper.calls).not.toContain("POST /jobs/upload");
        expect(L.entries()).toHaveLength(1);
        // while the upload is presumed running the queue behind it counts it as running
        expect(await reborn.renderStatus(S.sid, r.job, 0)).toMatchObject({ body: { phase: "queued", queue_ahead: 0 } });
        L.clock.t += 2000;
        await reborn.sweep();
        expect(L.helper.uploadQueries.map((q) => q.get("id"))).toEqual([r.job]);
        expect(L.entries()).toEqual([]);
    });
    it("entries that cannot run any more are dropped silently: a save whose session was cancelled elsewhere, a render whose row is no longer pending", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        const r = asBody(await L.render(S.sid, { queue: true, priority: "focused" }));
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'x' WHERE id = ?").run(a.id);
        L.db.raw.prepare("UPDATE studio_renders SET status = 'error', error_code = 'x' WHERE id = ?").run(r.job);
        R.release();
        await L.studio.sweep();
        // neither dead entry started anything: the first live one did
        expect(fetchIds(L)).toEqual([R.sid, b.id]);
        expect(L.helper.calls).not.toContain("POST /jobs/upload");
        expect(L.entries()).toEqual([]);
    });
    it("a lined save that meets a foreign 429 keeps trying for LINE_BUSY_WAIT_MS (10 min), a save that never waited gives up at BUSY_WAIT_MS", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0);
        L.helper.busyFetchStarts = 1e9; // a /webp job or a poster holds the helper
        await L.studio.pumpLine();
        const rec = L.kv.m.get(`save:${a.id}`) as any;
        expect(rec).toMatchObject({ lined: true, phase: "starting" });
        expect(rec.busySince).toBeDefined();
        L.clock.t += 3 * 60_000; // past BUSY_WAIT_MS
        await L.studio.advance(a.id, 0);
        expect(L.session(a.id).status).toBe("saving");
        L.clock.t += 8 * 60_000; // past LINE_BUSY_WAIT_MS since busySince
        await L.studio.advance(a.id, 0);
        expect(L.session(a.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
    });
    it("posters never cut the line: while entries wait (even with the helper free), no poster is made; when the line is empty it is", async () => {
        const L = await lineWorld();
        L.seed(); // an original with no poster
        await L.studio.kickPosters();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        R.release();
        await L.studio.advance(R.sid, 0); // the helper is free, `a` waits
        // the pass that would start `a` is held back: only the poster rule is under test
        const pump = vi.spyOn(L.studio, "pumpLine").mockResolvedValue(undefined);
        await L.studio.sweep();
        expect(L.helper.posterIds).toEqual([]);
        pump.mockRestore();
        await L.studio.sweep(); // `a` starts and holds the helper
        expect(L.helper.posterIds).toEqual([]);
        await L.studio.sweep(); // `a` ready: the line is empty and the helper free
        expect(L.helper.posterIds.length).toBeGreaterThan(0);
        expect(L.entries()).toEqual([]);
        expect(L.session(a.id).status).toBe("ready");
    });
    it("a poster in flight holds the helper: a queue-asking client waits in the line, the rest get 429; the poster is not cut", async () => {
        const L = await lineWorld();
        L.seed();
        await L.studio.kickPosters();
        L.helper.posterGate = new Promise(() => {});
        // (one Durable Object: the poster, the sweep and the creates are the same instance)
        const one = L.make({ posterIdleMs: 10, notify: L.notify });
        await one.kickPosters();
        void one.sweep();
        await vi.waitFor(() => expect(L.helper.posterIds).toHaveLength(1));
        expect((await one.create(KEY_ID, json({ url: LINK }))).status).toBe(429);
        const lined = asBody(await one.create(KEY_ID, json({ url: LINK, queue: true })));
        expect(lined).toMatchObject({ queued: true, queue_ahead: 1 });
    });
});

describe("queue_ahead and GET /studio/line", () => {
    it("positions count the running job as 1st; mine / sid / job / link only for the caller's own work; key_name from api_keys; focused renders go first", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const S = L.seed(); // key 1's original
        // key 2's share is the running job
        L.helper.fetchPolls = 1e9;
        const run = asBody(await create(L, { url: link("run"), origin: "share" }, KEY2_ID));
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }, KEY2_ID));
        const c = asBody(await L.render(S.sid, { queue: true }));
        const f = asBody(await L.render(S.sid, { start: 1, queue: true, priority: "focused" }));

        const res = await L.keyed("/studio/line");
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        const body = (await res.json()) as any;
        expect(body).toEqual({
            status: "success",
            now: L.clock.t,
            running: { kind: "save", mine: false, sid: null, job: null, origin: "share", key_name: "phone" },
            entries: [
                { position: 2, kind: "render", mine: true, sid: S.sid, job: f.job, at: L.clock.t, origin: null, priority: "focused", key_name: "test", link: LINK },
                { position: 3, kind: "save", mine: true, sid: a.id, job: null, at: L.clock.t, origin: null, priority: null, key_name: "test", link: link("a") },
                { position: 4, kind: "save", mine: false, sid: null, job: null, at: L.clock.t, origin: null, priority: null, key_name: "phone", link: null },
                { position: 5, kind: "render", mine: true, sid: S.sid, job: c.job, at: L.clock.t, origin: null, priority: null, key_name: "test", link: LINK },
            ],
            max: 50,
            wait_ms: 1_800_000,
        });
        // each job's own poll agrees (running = 1, then the entries in order)
        expect(asBody(await L.studio.advance(a.id, 0)).queue_ahead).toBe(2);
        expect(asBody(await L.studio.advance(b.id, 0)).queue_ahead).toBe(3);
        expect((asBody(await L.studio.renderStatus(S.sid, f.job, 0)) as any).queue_ahead).toBe(1);

        // the other key sees its own work as mine, and key 1's links never
        const other = (await (await L.keyed("/studio/line", "GET", auth2)).json()) as any;
        expect(other.running).toMatchObject({ mine: true, sid: run.id, job: null, origin: "share", key_name: "phone" });
        expect(other.entries.map((e: any) => [e.position, e.mine, e.sid, e.link, e.key_name])).toEqual([
            [2, false, null, null, "test"],
            [3, false, null, null, "test"],
            [4, true, b.id, link("b"), "phone"],
            [5, false, null, null, "test"],
        ]);
        expect(JSON.stringify(other)).not.toContain(link("a"));
    });
    it("an empty line and a free helper: running null, no entries; the call never wakes the container", async () => {
        const L = await lineWorld();
        const ensure = vi.fn(async () => {});
        const quiet = L.make({ ensureRunning: ensure });
        const res = await handleStudioRoute(
            quiet,
            new Request("https://do.internal/studio/line", { headers: { [KEY_ID_HEADER]: KEY_ID } }),
        );
        expect(await res.json()).toMatchObject({ status: "success", running: null, entries: [], max: 50, wait_ms: 1_800_000 });
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(ensure).not.toHaveBeenCalled();
    });
    it("running reports what holds the helper: a render, a /webp job, a poster", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.jobPolls = 1e9;
        const job = asBody(await L.render(S.sid, {})).job;
        expect(((await (await L.keyed("/studio/line")).json()) as any).running).toMatchObject({
            kind: "render", mine: true, sid: S.sid, job, key_name: "test",
        });
        // a /webp job of the same key (the render is collected first)
        L.helper.jobPolls = 0;
        await L.studio.renderStatus(S.sid, job, 0);
        L.kv.m.delete(`job:${job}`);
        L.kv.m.set("job:WebpJob0000000000001", { keyId: KEY_ID, createdAt: L.clock.t, params: {} });
        expect(((await (await L.keyed("/studio/line")).json()) as any).running).toMatchObject({
            kind: "webp", mine: true, sid: null, job: "WebpJob0000000000001",
        });
        L.kv.m.delete("job:WebpJob0000000000001");
        // a poster in flight belongs to nobody
        L.seed();
        L.helper.posterGate = new Promise(() => {});
        const one = L.make({ notify: L.notify });
        await one.kickPosters();
        void one.sweep();
        await vi.waitFor(() => expect(L.helper.posterIds).toHaveLength(1));
        const viaOne = await handleStudioRoute(one, new Request("https://do.internal/studio/line", { headers: { [KEY_ID_HEADER]: KEY_ID } }));
        expect(((await viaOne.json()) as any).running).toEqual({
            kind: "poster", mine: false, sid: null, job: null, origin: null, key_name: null,
        });
    });
    it("a D1 failure on the key names still answers, with key_name: null", async () => {
        const L = await lineWorld();
        await running(L);
        await create(L, { url: link("a"), queue: true });
        const real = L.db.prepare.bind(L.db);
        const spy = vi.spyOn(L.db, "prepare").mockImplementation(((sql: string) => {
            if (sql.includes("FROM api_keys WHERE id IN")) throw new Error("d1 down");
            return real(sql);
        }) as typeof L.db.prepare);
        const body = (await (await L.keyed("/studio/line")).json()) as any;
        spy.mockRestore();
        expect(body.status).toBe("success");
        expect(body.running.key_name).toBeNull();
        expect(body.entries[0]).toMatchObject({ mine: true, key_name: null });
    });
    it("the library-service credential, other methods and no key do not reach it", async () => {
        const L = await lineWorld();
        expect((await L.call("/studio/line", { headers: svc })).status).toBe(404);
        expect((await L.call("/studio/line", { method: "POST", headers: auth })).status).toBe(404);
        expect((await L.call("/studio/line")).status).toBe(401);
        // the Durable Object refuses a request without the Worker's key id, and the service key id
        expect((await handleStudioRoute(L.studio, new Request("https://do.internal/studio/line"))).status).toBe(403);
        expect(
            (await handleStudioRoute(L.studio, new Request("https://do.internal/studio/line", { headers: { [KEY_ID_HEADER]: "service:library" } })))
                .status,
        ).toBe(404);
    });
});

describe("ceilings", () => {
    it("50 entries in all: the 51st (save, upload adopt or render) is 429 error.studio.line_full and creates nothing", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        for (let i = 0; i < LINE_MAX; i++) {
            const r = await create(L, { url: link(i), queue: true });
            expect(r.status).toBe(201);
        }
        expect(L.entries()).toHaveLength(LINE_MAX);
        const sessions = L.rows("SELECT id FROM studio_sessions").length;
        const renders = L.rows("SELECT id FROM studio_renders").length;
        const full = { status: 429, body: { status: "error", error: { code: "error.studio.line_full" } } };
        expect(await create(L, { url: link("over"), queue: true })).toEqual(full);
        expect(
            await L.studio.adopt(
                KEY_ID,
                json({ r2_key: "uploads/ItemItem00000001.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "ItemItem00000001", queue: true }),
            ),
        ).toEqual(full);
        expect(await L.render(S.sid, { queue: true })).toEqual(full);
        expect(L.rows("SELECT id FROM studio_sessions")).toHaveLength(sessions);
        expect(L.rows("SELECT id FROM studio_renders")).toHaveLength(renders);
        expect(L.entries()).toHaveLength(LINE_MAX);
        // a client that did not ask to queue still gets the usual busy
        expect(await create(L, { url: link("plain") })).toEqual({ status: 429, body: { status: "error", error: { code: "error.studio.busy" } } });
    });
    it("a save past 30 minutes ends with error.studio.busy, its title row is gone, and the failed hooks fire (per-session opt-in, live)", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true, title: "the good part", notify: { on: ["failed"] } }));
        expect(L.rows("SELECT post_key, title FROM media_titles")).toEqual([{ post_key: a.id, title: "the good part" }]);
        // (the running save is kept alive: this test is about the entry's own wait)
        const keepAlive = () => L.kv.m.set(`save:${R.sid}`, { ...(L.kv.m.get(`save:${R.sid}`) as object), startedAt: L.clock.t, lastAdvance: L.clock.t });
        L.clock.t += LINE_WAIT_MS; // exactly at the ceiling: still waiting
        keepAlive();
        await L.studio.sweep();
        expect(L.session(a.id).status).toBe("saving");
        L.clock.t += 1;
        keepAlive();
        await L.studio.sweep();
        expect(L.session(a.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
        expect(L.entries()).toEqual([]);
        expect(L.rows("SELECT * FROM media_titles")).toEqual([]);
        expect(L.hark.calls).toEqual([
            { title: "cobalt couldn't finish", body: expect.stringContaining("the server was busy"), url: `cobalt-apple://session/${a.id}` },
        ]);
        expect(L.live.events).toContainEqual({ sid: a.id, e: { kind: "failed", code: "error.studio.busy" } });
        // the poll tells the same
        expect(asBody(await L.studio.advance(a.id, 0))).toMatchObject({ status: "error", error: { code: "error.studio.busy" }, queue_ahead: null });
    });
    it("a render past 30 minutes ends with error.webp.busy and its failed hooks", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        const r = asBody(await L.render(S.sid, { queue: true, notify: true }));
        L.clock.t += LINE_WAIT_MS + 1;
        await L.studio.sweep();
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r.job)).toEqual([
            { status: "error", error_code: "error.webp.busy" },
        ]);
        expect(L.hark.calls).toEqual([
            { title: "cobalt couldn't finish", body: "couldn't make the webp — the server was busy", url: `cobalt-apple://session/${S.sid}` },
        ]);
        expect(L.live.events).toContainEqual({ sid: S.sid, job: r.job, e: { kind: "failed", code: "error.webp.busy" } });
        expect(await L.studio.renderStatus(S.sid, r.job, 0)).toEqual({
            status: 200,
            body: { status: "error", error: { code: "error.webp.busy" } },
        });
    });
    it("a non-empty line counts as pending, so the sweep re-arms while anything waits; an empty one does not", async () => {
        const L = await lineWorld();
        const R = await running(L);
        await create(L, { url: link("a"), queue: true });
        R.release();
        expect((await L.studio.sweep()).pending).toBeGreaterThan(0);
        expect((await L.studio.sweep()).pending).toBeGreaterThan(0); // `a` is still being saved
        expect(await L.studio.sweep()).toEqual({ pending: 0 });
    });
    it("a save that holds the helper for good is reaped by the sweep so the line drains (nobody has to create anything)", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        // R's record is orphaned: past the budget the sweep stops advancing it
        L.clock.t += 11 * 60_000;
        L.kv.m.set(`save:${R.sid}`, { ...(L.kv.m.get(`save:${R.sid}`) as object), startedAt: 0, lastAdvance: 0 });
        L.helper.fetchPolls = 0;
        await L.studio.sweep();
        expect(L.session(R.sid)).toMatchObject({ status: "error", error_code: "error.studio.save_lost" });
        expect(L.keys("save:")).toEqual([`save:${a.id}`]);
    });
});

describe("cancel what has not started", () => {
    it("DELETE /studio/<sid>/line removes a queued save: error.studio.cancelled, no Hark, live failed, the others move up; a repeat is the same 200", async () => {
        const L = await lineWorld();
        await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true, title: "mine", notify: { on: ["saved", "failed"] } }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        expect(asBody(await L.studio.advance(b.id, 0)).queue_ahead).toBe(2);

        const res = await L.keyed(`/studio/${a.id}/line`, "DELETE");
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", cancelled: true });
        expect(L.session(a.id)).toMatchObject({ status: "error", error_code: "error.studio.cancelled" });
        expect(L.entries().map((e) => e.sid)).toEqual([b.id]);
        expect(L.rows("SELECT * FROM media_titles")).toEqual([]);
        expect(asBody(await L.studio.advance(b.id, 0)).queue_ahead).toBe(1);
        expect(L.live.events).toContainEqual({ sid: a.id, e: { kind: "failed", code: "error.studio.cancelled" } });
        // the owner did it: no Hark message, whatever the sweep and the polls do afterwards
        await L.sweeps(2);
        await L.studio.advance(a.id, 0);
        expect(L.hark.calls).toEqual([]);
        // idempotent
        const again = await L.keyed(`/studio/${a.id}/line`, "DELETE");
        expect(again.status).toBe(200);
        expect(await again.json()).toEqual({ status: "success", cancelled: true });
    });
    it("DELETE /studio/<sid>/render/<job> removes a queued render: error.webp.cancelled, no Hark even with notify: true, idempotent", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        const r = asBody(await L.render(S.sid, { queue: true, notify: true }));
        const res = await L.keyed(`/studio/${S.sid}/render/${r.job}`, "DELETE");
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", cancelled: true });
        expect(L.entries()).toEqual([]);
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r.job)).toEqual([
            { status: "error", error_code: "error.webp.cancelled" },
        ]);
        expect(L.live.events).toContainEqual({ sid: S.sid, job: r.job, e: { kind: "failed", code: "error.webp.cancelled" } });
        // polls of the cancelled render answer the error and never reach Hark
        expect(await L.studio.renderStatus(S.sid, r.job, 0)).toEqual({
            status: 200,
            body: { status: "error", error: { code: "error.webp.cancelled" } },
        });
        await L.sweeps(2);
        expect(L.hark.calls).toEqual([]);
        expect((await L.keyed(`/studio/${S.sid}/render/${r.job}`, "DELETE")).status).toBe(200);
    });
    it("a save or render that has started cannot be stopped: 409 error.studio.started", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const res = await L.keyed(`/studio/${R.sid}/line`, "DELETE");
        expect(res.status).toBe(409);
        expect(((await res.json()) as any).error.code).toBe("error.studio.started");
        expect(L.session(R.sid).status).toBe("saving");
        // a finished save and a render that is running or done
        R.release();
        await L.studio.advance(R.sid, 0);
        expect((await L.keyed(`/studio/${R.sid}/line`, "DELETE")).status).toBe(409);
        L.helper.jobPolls = 1e9;
        const job = asBody(await L.render(S.sid, {})).job;
        expect((await L.keyed(`/studio/${S.sid}/render/${job}`, "DELETE")).status).toBe(409);
        L.helper.jobPolls = 0;
        await L.studio.renderStatus(S.sid, job, 0);
        const done = await L.keyed(`/studio/${S.sid}/render/${job}`, "DELETE");
        expect(done.status).toBe(409);
        expect(((await done.json()) as any).error.code).toBe("error.studio.started");
        // a queued render whose upload has begun is started too
        L.helper.jobPolls = 1e9;
        await L.render(S.sid, {}); // holds the helper
        const queued = asBody(await L.render(S.sid, { start: 1, queue: true }));
        const [entry] = L.entries();
        L.kv.m.set(entry.key, { ...entry, key: undefined, starting: L.clock.t });
        expect((await L.keyed(`/studio/${S.sid}/render/${queued.job}`, "DELETE")).status).toBe(409);
    });
    it("only the key that made the session may cancel: another key, an unknown session or job, the service credential, no key", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const S = L.seed();
        await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const r = asBody(await L.render(S.sid, { queue: true }));
        const nope = "Z".repeat(22);
        const jobNope = "Z".repeat(20);
        for (const [url, headers, status] of [
            [`/studio/${a.id}/line`, auth2, 404],
            [`/studio/${S.sid}/render/${r.job}`, auth2, 404],
            [`/studio/${nope}/line`, auth, 404],
            [`/studio/${S.sid}/render/${jobNope}`, auth, 404],
            [`/studio/${a.id}/line`, svc, 404],
            [`/studio/${S.sid}/render/${r.job}`, svc, 404],
            [`/studio/${a.id}/line`, {}, 401],
        ] as const) {
            const res = await L.call(url, { method: "DELETE", headers: headers as Record<string, string> });
            expect([url, res.status]).toEqual([url, status]);
        }
        // nothing was cancelled by any of them
        expect(L.session(a.id).status).toBe("saving");
        expect(L.entries()).toHaveLength(2);
        // the Durable Object itself refuses a missing key id and the service key id
        expect((await handleStudioRoute(L.studio, new Request(`https://do.internal/studio/${a.id}/line`, { method: "DELETE" }))).status).toBe(403);
        expect(
            (
                await handleStudioRoute(
                    L.studio,
                    new Request(`https://do.internal/studio/${a.id}/line`, { method: "DELETE", headers: { [KEY_ID_HEADER]: "service:library" } }),
                )
            ).status,
        ).toBe(404);
    });
    it("a cancelled save's session is a plain error: the line summary and the other entries are not disturbed, a later save starts normally", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        await L.studio.cancelSave(KEY_ID, a.id);
        R.release();
        await L.sweeps(3);
        expect(fetchIds(L)).toEqual([R.sid, b.id]);
        expect(L.session(b.id).status).toBe("ready");
        expect(L.session(a.id).status).toBe("error");
    });
});

describe("validation of queue, title and priority", () => {
    it.each([["yes"], [1], [0], [[]], [{}]])("POST /studio: queue %j is 400 error.studio.invalid_params and creates nothing", async (queue) => {
        const L = await lineWorld();
        const r = await create(L, { queue });
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.studio.invalid_params" } } });
        expect(L.rows("SELECT id FROM studio_sessions")).toEqual([]);
        expect(L.helper.calls).toEqual([]);
        expect(L.kv.m.size).toBe(0);
    });
    it.each([[null], [false], [undefined]])("POST /studio: queue %j is 'not queued'", async (queue) => {
        const L = await lineWorld();
        const r = await create(L, { queue });
        expect(r.status).toBe(201);
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
    });
    it.each([
        ["a number", 7],
        ["an object", {}],
        ["an array", ["x"]],
        ["a control character", "a\u0007b"],
        ["a line break", "a\nb"],
        ["81 code points", "x".repeat(81)],
        ["an unpaired surrogate", "a\ud800"],
    ])("POST /studio: a title that is %s is 400 error.library.bad_title and creates nothing", async (_n, title) => {
        const L = await lineWorld();
        const r = await create(L, { title });
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.library.bad_title" } } });
        expect(L.rows("SELECT id FROM studio_sessions")).toEqual([]);
        expect(L.rows("SELECT * FROM media_titles")).toEqual([]);
        expect(L.helper.calls).toEqual([]);
    });
    it("POST /studio: the title is trimmed and stored for the new session's post key; empty, whitespace and null mean none; 80 code points is fine", async () => {
        const L = await lineWorld();
        const a = asBody(await create(L, { title: "  the good part \n" }));
        expect(L.rows("SELECT post_key, title, key_id FROM media_titles")).toEqual([{ post_key: a.id, title: "the good part", key_id: KEY_ID }]);
        await L.settle(a.id);
        for (const title of ["", "   ", null]) {
            const b = asBody(await create(L, { title }));
            await L.settle(b.id);
        }
        expect(L.rows("SELECT post_key FROM media_titles")).toEqual([{ post_key: a.id }]);
        const long = asBody(await create(L, { title: "😀".repeat(80) }));
        expect(L.rows("SELECT title FROM media_titles WHERE post_key = ?", long.id)).toHaveLength(1);
        // it shows as the post's custom title once the save is in the library
        await L.settle(long.id);
        const lib = (await (await L.keyed("/library")).json()) as any;
        expect(lib.posts.find((p: any) => p.id === a.id)).toMatchObject({ custom_title: "the good part" });
    });
    it("the title row of a save that fails is deleted (free path and queued path alike)", async () => {
        const L = await lineWorld();
        L.helper.fetchError = "error.fetch.fail";
        const a = asBody(await create(L, { title: "gone soon" }));
        expect(L.rows("SELECT * FROM media_titles")).toHaveLength(1);
        await L.settle(a.id);
        expect(L.session(a.id).status).toBe("error");
        expect(L.rows("SELECT * FROM media_titles")).toEqual([]);
    });
    it.each([["maybe"], [1], ["yes"], [{}]])("POST .../render: queue %j is 400 error.webp.invalid_params", async (queue) => {
        const L = await lineWorld();
        const S = L.seed();
        expect(await L.render(S.sid, { queue })).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        expect(L.rows("SELECT id FROM studio_renders")).toEqual([]);
        expect(L.helper.calls).toEqual([]);
    });
    it.each([
        ["an unknown priority", { queue: true, priority: "urgent" }],
        ["a non-string priority", { queue: true, priority: 1 }],
        ["priority without queue", { priority: "focused" }],
        ["priority with queue false", { queue: false, priority: "focused" }],
    ])("POST .../render: %s is 400 error.webp.invalid_params and creates nothing", async (_n, extra) => {
        const L = await lineWorld();
        const S = L.seed();
        expect(await L.render(S.sid, extra)).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        expect(L.rows("SELECT id FROM studio_renders")).toEqual([]);
        expect(L.entries()).toEqual([]);
        expect(L.helper.calls).toEqual([]);
    });
    it("POST .../render: priority null / absent is an ordinary render; the existing validation (crop included) comes first and queues nothing", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        const ok = await L.render(S.sid, { queue: true, priority: null });
        expect(ok.status).toBe(202);
        const bad = await L.render(S.sid, { queue: true, length: 11 });
        expect(bad).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.too_long" } } });
        const crop = await L.render(S.sid, { queue: true, crop: { x: 0, y: 0, w: 0.001, h: 0.001 } });
        expect(crop.status).toBe(400);
        expect(L.entries()).toHaveLength(1);
        expect(L.rows("SELECT id FROM studio_renders")).toHaveLength(1);
    });
    it("a queued render keeps the validated params: crop, width and quality reach the helper when it starts", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const r = asBody(await L.render(S.sid, { queue: true, width: 320, quality: "high", crop: { x: 0.1, y: 0.1, w: 0.8, h: 0.8 } }));
        expect(L.rows("SELECT width, quality FROM studio_renders WHERE id = ?", r.job)).toEqual([{ width: 320, quality: "high" }]);
        R.release();
        await L.studio.sweep();
        const q = L.helper.uploadQueries[0]!;
        expect(q.get("id")).toBe(r.job);
        expect(q.get("width")).toBe("320");
        expect(q.get("quality")).toBe("high");
        expect(q.get("crop")).toBeTruthy();
    });
});

describe("uploads and the library's studio route", () => {
    const put = (L: LW, query: string, headers: Record<string, string> = auth, type = "video/mp4") =>
        L.call(`/studio/upload${query}`, {
            method: "PUT",
            headers: { ...headers, "content-type": type, "content-length": "300" },
            body: new Uint8Array(300).fill(1) as unknown as BodyInit,
        });
    it("PUT /studio/upload?queue=1 while the helper is busy: 201 with id = the adopted session, studio_error null, queued, queue_ahead; it is probed when its turn comes", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const res = await put(L, "?name=clip.mp4&queue=1");
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b).toMatchObject({ status: "success", studio_error: null, queued: true, queue_ahead: 1, item: { name: "clip.mp4" } });
        expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
        expect(L.session(b.id)).toMatchObject({ status: "saving", service: "upload", link: `upload:${b.item.id}` });
        expect(L.entries()).toMatchObject([{ sid: b.id, adopt: true, kind: "save" }]);
        expect(L.kv.m.has(`save:${b.id}`)).toBe(false);
        expect(asBody(await L.studio.advance(b.id, 0))).toMatchObject({ step: "queued", queue_ahead: 1 });
        R.release();
        await L.studio.sweep();
        expect(L.kv.m.get(`save:${b.id}`)).toMatchObject({ phase: "probing", lined: true });
        await L.sweeps(2);
        expect(L.session(b.id)).toMatchObject({ status: "ready", width: 640, height: 360 });
        expect(L.helper.probedBytes).toEqual([300]);
    });
    it("without queue=1 a busy helper is today's answer (id null, studio_error busy, no queued fields); queue=1 on a free helper says queued: false", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const busy = (await (await put(L, "?name=a.mp4")).json()) as any;
        expect(busy).toMatchObject({ id: null, url: null, studio_error: { code: "error.studio.busy" } });
        expect(busy).not.toHaveProperty("queued");
        expect(busy).not.toHaveProperty("queue_ahead");
        R.release();
        await L.studio.advance(R.sid, 0);
        const free = (await (await put(L, "?name=b.mp4&queue=1")).json()) as any;
        expect(free).toMatchObject({ studio_error: null, queued: false, queue_ahead: null });
        expect(free.id).toMatch(/^[A-Za-z0-9]{22}$/);
        const plain = (await (await put(L, "?name=c.mp4")).json()) as any;
        expect(plain.studio_error?.code).toBe("error.studio.busy"); // `b` holds the helper
        expect(Object.keys(plain).sort()).toEqual(["id", "item", "public_state", "public_url", "status", "studio_error", "url"]);
    });
    it("a refused queue value or title is judged before the body is read and stores nothing", async () => {
        const L = await lineWorld();
        for (const [query, code] of [
            ["?name=a.mp4&queue=maybe", "error.library.bad_request"],
            ["?name=a.mp4&title=" + encodeURIComponent("x".repeat(81)), "error.library.bad_title"],
            ["?name=a.mp4&title=" + encodeURIComponent("a\nb"), "error.library.bad_title"],
        ] as const) {
            const res = await put(L, query);
            expect(res.status).toBe(400);
            expect(((await res.json()) as any).error.code).toBe(code);
        }
        expect(L.items()).toEqual([]);
        expect(L.originals.objects.size).toBe(0);
        expect(L.rows("SELECT * FROM media_titles")).toEqual([]);
    });
    it("?title= is stored for the upload's item id (its post key), trimmed; empty means none", async () => {
        const L = await lineWorld();
        const a = (await (await put(L, "?name=a.mp4&title=" + encodeURIComponent("  holiday  "))).json()) as any;
        expect(L.rows("SELECT post_key, title FROM media_titles")).toEqual([{ post_key: a.item.id, title: "holiday" }]);
        await L.settle(a.id);
        const lib = (await (await L.keyed("/library")).json()) as any;
        expect(lib.posts.find((p: any) => p.id === a.item.id)).toMatchObject({ custom_title: "holiday" });
        const b = (await (await put(L, "?name=b.mp4&title=")).json()) as any;
        expect(L.rows("SELECT * FROM media_titles WHERE post_key = ?", b.item.id)).toEqual([]);
        // an image has no session but still takes a title
        const img = (await (await put(L, "?name=p.png&title=pic", auth, "image/png")).json()) as any;
        expect(L.rows("SELECT title FROM media_titles WHERE post_key = ?", img.item.id)).toEqual([{ title: "pic" }]);
    });
    it("POST /library/items/<id>/studio?queue=1: the adopted session joins the line (201 with queued, queue_ahead); without it, today's 429", async () => {
        const L = await lineWorld();
        const ID = "PrivVideo0000001";
        L.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, session_id, created_at) VALUES (?, 'private', 'upload', 'originals', ?, 'holiday.mp4', 'video/mp4', 4096, NULL, 1)",
            )
            .run(ID, `uploads/${ID}.mp4`);
        L.originals.objects.set(`uploads/${ID}.mp4`, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        const R = await running(L);
        const refused = await L.call(`/library/items/${ID}/studio`, { method: "POST", headers: auth });
        expect(refused.status).toBe(429);
        const res = await L.call(`/library/items/${ID}/studio?queue=1`, { method: "POST", headers: auth });
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b).toMatchObject({ status: "success", queued: true, queue_ahead: 1 });
        expect(L.entries()).toMatchObject([{ sid: b.id, adopt: true }]);
        const bad = await L.call(`/library/items/${ID}/studio?queue=nope`, { method: "POST", headers: auth });
        expect(bad.status).toBe(400);
        R.release();
        await L.sweeps(3);
        expect(L.session(b.id).status).toBe("ready");
    });
    it("/library/adopt (the web Worker's service call) never queues, whatever the body says", async () => {
        const L = await lineWorld();
        await running(L);
        const res = await L.call("/library/adopt", {
            method: "POST",
            headers: { ...svc, "content-type": "application/json" },
            body: json({ r2_key: "uploads/ItemItem00000001.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "ItemItem00000001", queue: true }),
        });
        expect(res.status).toBe(429);
        expect(L.entries()).toEqual([]);
    });
    it("the internal adopt path is still a 404 for any public caller", async () => {
        const L = await lineWorld();
        const res = await L.call("/studio/upload/adopt", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: "{}" });
        expect(res.status).toBe(404);
    });
});

describe("the capability", () => {
    it("features.line and the two limits come from line.ts", async () => {
        const L = await lineWorld();
        const b = (await (await L.call("/capabilities")).json()) as any;
        expect(b.features.line).toBe(true);
        expect(b.limits.line_max).toBe(LINE_MAX);
        expect(b.limits.line_wait_ms).toBe(LINE_WAIT_MS);
    });
});

describe("the gate", () => {
    const cfg = { corsUrl: "https://cobalt.capybaraharmony.com", now: 1_800_000_000_000 };
    const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
    const JOB = "aB3dE6gH9jK2mN5pQ8sT";
    const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const d = (o: Partial<GateRequest>) =>
        decide({ method: "GET", pathname: "/", searchParams: new URLSearchParams(), origin: null, authorization: null, ...o }, cfg);
    const keyed = { authorization: `Api-Key ${KEY}` };
    const notFound = { action: "reject", status: 404 };

    it("GET /studio/line is keyed (studio_line); other methods and the service credential are 404; no key is 401", () => {
        expect(d({ pathname: "/studio/line", ...keyed })).toEqual({ action: "lookup", key: KEY, then: "studio_line" });
        expect(d({ pathname: "/studio/line" })).toMatchObject({ status: 401 });
        for (const method of ["POST", "PUT", "DELETE", "PATCH", "HEAD"]) expect(d({ method, pathname: "/studio/line", ...keyed })).toMatchObject(notFound);
        expect(d({ pathname: "/studio/line", service: true })).toMatchObject(notFound);
        expect(d({ pathname: "/studio/line", ...keyed, service: true })).toMatchObject(notFound);
    });
    it("PUT|DELETE /studio/line/notify are keyed (studio_line_notify); GET/POST, the service credential: 404", () => {
        for (const method of ["PUT", "DELETE"]) {
            expect(d({ method, pathname: "/studio/line/notify", ...keyed })).toEqual({ action: "lookup", key: KEY, then: "studio_line_notify" });
            expect(d({ method, pathname: "/studio/line/notify" })).toMatchObject({ status: 401 });
            expect(d({ method, pathname: "/studio/line/notify", service: true })).toMatchObject(notFound);
        }
        for (const method of ["GET", "POST", "PATCH", "HEAD"]) expect(d({ method, pathname: "/studio/line/notify", ...keyed })).toMatchObject(notFound);
    });
    it("DELETE /studio/<sid>/line and DELETE /studio/<sid>/render/<job> are keyed (studio_cancel); the render's GET stays unkeyed", () => {
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/line`, ...keyed })).toEqual({
            action: "lookup", key: KEY, then: "studio_cancel", params: { sid: SID },
        });
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/render/${JOB}`, ...keyed })).toEqual({
            action: "lookup", key: KEY, then: "studio_cancel", params: { sid: SID, job: JOB },
        });
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/line` })).toMatchObject({ status: 401 });
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/render/${JOB}` })).toMatchObject({ status: 401 });
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/line`, service: true })).toMatchObject(notFound);
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/render/${JOB}`, service: true })).toMatchObject(notFound);
        expect(d({ method: "GET", pathname: `/studio/${SID}/render/${JOB}` })).toEqual({ action: "studio", op: "render_status", sid: SID, job: JOB });
        for (const method of ["GET", "POST", "PUT", "PATCH"]) expect(d({ method, pathname: `/studio/${SID}/line`, ...keyed })).toMatchObject(notFound);
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/render/short`, ...keyed })).toMatchObject(notFound);
        expect(d({ method: "DELETE", pathname: `/studio/${SID}/line/extra`, ...keyed })).toMatchObject(notFound);
        expect(d({ method: "DELETE", pathname: `/studio/short/line`, ...keyed })).toMatchObject(notFound);
    });
    it("a session literally named like the new paths is not reachable: /studio/line is the line, not a session", () => {
        expect(d({ pathname: "/studio/line" })).not.toMatchObject({ action: "studio" });
    });
});

describe("the Worker forwards the new routes like studio_recent", () => {
    it("the key id is set, the client's key is dropped, no request_log row is written, a forged key id header is ignored", async () => {
        const L = await lineWorld();
        const seen: Request[] = [];
        const inner = L.container.fetch;
        const spyContainer = { fetch: async (r: Request) => (seen.push(r), inner(r)) };
        const { handleRequest } = await import("../src/worker");
        const go = (url: string, init: RequestInit) =>
            handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), L.env, spyContainer, { now: L.clock.now, sleep: L.clock.sleep });
        const a = asBody(await create(L, { url: LINK }));
        await go("/studio/line", { headers: { ...auth, [KEY_ID_HEADER]: "service:library" } });
        await go("/studio/line/notify", { method: "PUT", headers: auth });
        await go(`/studio/${a.id}/line`, { method: "DELETE", headers: auth });
        expect(seen).toHaveLength(3);
        for (const r of seen) {
            expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
            expect(r.headers.get("authorization")).toBeNull();
        }
        expect(L.rows("SELECT * FROM request_log")).toEqual([]);
    });
});

describe("session bodies", () => {
    it("every session body carries queue_ahead (null unless the save waits); step is queued only then", async () => {
        const L = await lineWorld();
        const a = asBody(await create(L, {}));
        const body = asBody(await L.studio.advance(a.id, 0));
        expect(body).toHaveProperty("queue_ahead", null);
        const done = asBody(await L.studio.advance(a.id, 0));
        expect(done).toMatchObject({ status: "ready", step: null, queue_ahead: null });
        const edge = (await (await L.call(`/studio/${a.id}`)).json()) as any;
        expect(edge).toMatchObject({ status: "ready", queue_ahead: null });
    });
    it("a session that is not saving never says queued, even if a stale entry is still in the line", async () => {
        const L = await lineWorld();
        await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'x' WHERE id = ?").run(a.id);
        expect(asBody(await L.studio.advance(a.id, 0))).toMatchObject({ status: "error", step: null, queue_ahead: null });
    });
});

describe("misc", () => {
    it("the session TTL is far longer than the line's ceiling, so nothing else expires an entry", () => {
        expect(SESSION_TTL_MS).toBeGreaterThan(LINE_WAIT_MS * 100);
    });
    it("the keys and secrets used here are not accidentally the same", () => {
        expect(new Set([CLIENT, CLIENT2, INTERNAL]).size).toBe(3);
        expect(KEY_ID).not.toBe(KEY2_ID);
        void SERVICE_HEADER;
    });
});
