// Review findings on the server's line (each test failed before its fix): the sweep keeps re-arming
// for the job the pump starts last, concurrent creates cannot all skip the line, an eviction between
// the helper taking a queued render and the entry's removal does not strand it, the line's busy
// wait really ends at 10 minutes, a transient start failure is not final, a refusal re-arms the
// sweep, and the notification / cancel / expiry details.
import { describe, expect, it, vi } from "vitest";
import { LINE_BUSY_WAIT_MS } from "../src/line";
import { runSweep } from "../src/sweep";
import { KEY_ID, LINK, asBody, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";

const link = (n: number | string) => `${LINK}?n=${n}`;
const create = (L: LW, body: Record<string, unknown>) => L.studio.create(KEY_ID, json({ url: LINK, ...body }));
const lineRecord = (L: LW) => L.kv.m.get(`notify:line:${KEY_ID}`) as any;
const putLine = (L: LW) => L.keyed("/studio/line/notify", "PUT");

// The real re-arm rule: runSweep schedules the next pass only while the pass reports something pending.
async function drive(L: LW, maxPasses = 30) {
    let armed = 1; // the create armed one
    let passes = 0;
    const sched = {
        storage: L.kv,
        now: L.clock.now,
        schedule: async () => {
            armed++;
        },
    };
    while (armed > 0 && passes < maxPasses) {
        armed--;
        passes++;
        await runSweep(sched as never, () => L.studio.sweep());
        L.clock.t += 5000;
    }
    return passes;
}

describe("the sweep keeps running after the pump starts the last queued job", () => {
    it("a share save queued behind a running save is finished by the re-armed sweep alone", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const B = asBody(await create(L, { url: link("b"), origin: "share", notify: { on: ["saved", "failed"] } }));
        expect(B.queued).toBe(true);
        L.helper.fetchPolls = 0;
        await drive(L);
        expect(L.session(B.id).status).toBe("ready");
        expect(L.keys("save:")).toEqual([]);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.body).toContain("is saved");
    });
    it("an adopted upload queued last is stepped (probed) by the re-armed sweep", async () => {
        const L = await lineWorld({ posters: false });
        const S = L.seed();
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const A = asBody(
            await L.studio.adopt(KEY_ID, json({ r2_key: S.r2, name: "clip.mp4", content_type: "video/mp4", bytes: 4096, item_id: "Up1", queue: true })),
        );
        expect(A.queued).toBe(true);
        L.helper.fetchPolls = 0;
        await drive(L);
        expect(L.session(A.id).status).toBe("ready");
        expect(L.keys("save:")).toEqual([]);
    });
    it("the running save FAILS, the share save behind it is started by the pump and still finished", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const B = asBody(await create(L, { url: link("b"), origin: "share", notify: { on: ["saved", "failed"] } }));
        L.helper.fetchPolls = 0;
        // R's poll fails it (its download budget ran out); B's own fetch is fine
        L.kv.m.set(`save:${R.id}`, { ...(L.kv.m.get(`save:${R.id}`) as object), startedAt: L.clock.t - 8 * 60_000 - 1000 });
        await drive(L);
        expect(L.session(R.id).status).toBe("error");
        expect(L.session(B.id).status).toBe("ready");
    });
    it("a studio render is running, the share save queued behind it finishes", async () => {
        const L = await lineWorld({ posters: false });
        const S = L.seed({}, { row: false });
        L.helper.jobPolls = 1e9;
        expect(asBody(await L.render(S.sid, {})).status).toBe("pending");
        const B = asBody(await create(L, { url: link("b"), origin: "share", notify: { on: ["saved", "failed"] } }));
        expect(B.queued).toBe(true);
        L.helper.jobPolls = 0;
        await drive(L);
        expect(L.session(B.id).status).toBe("ready");
    });
    it("a cancelled save in between: the save queued after it still finishes", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const A = asBody(await create(L, { url: link("a"), queue: true }));
        expect((await L.studio.cancelSave(KEY_ID, A.id)).status).toBe(200);
        const B = asBody(await create(L, { url: link("b"), queue: true }));
        L.helper.fetchPolls = 0;
        await drive(L);
        expect(L.session(A.id).status).toBe("error");
        expect(L.session(B.id).status).toBe("ready");
    });
    it("a render queued last (started by the pump) is collected by the re-armed sweep", async () => {
        const L = await lineWorld({ posters: false });
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const r = asBody(await L.render(S.sid, { queue: true }));
        L.helper.fetchPolls = 0;
        await drive(L);
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "success" }]);
    });
    it("the pass that starts the last queued save reports it pending (the count, not only the arm)", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        L.helper.fetchPolls = 0;
        const r = await L.studio.sweep(); // R ends, the pump starts `a` at the end of the pass
        expect(L.kv.m.has(`save:${a.id}`)).toBe(true);
        expect(r.pending).toBeGreaterThan(0);
        expect(await L.studio.sweep()).toEqual({ pending: 0 }); // `a` ended in this pass
    });
    it("a start by the pump arms the sweep itself (it does not rely on the pass's own count)", async () => {
        const L = await lineWorld({ posters: false });
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        await create(L, { url: link("a"), queue: true });
        L.helper.fetchPolls = 0;
        await L.studio.advance(R.id, 0);
        const before = L.sweepsArmed();
        await L.studio.pumpLine();
        expect(L.sweepsArmed()).toBeGreaterThan(before);
    });
});

describe("concurrent creates cannot all take the free path", () => {
    it("five queue:true creates at once on an idle server: exactly one starts, four wait", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const rs = await Promise.all([1, 2, 3, 4, 5].map((i) => L.studio.create(KEY_ID, json({ url: link(i), queue: true }))));
        const queued = rs.map((r) => asBody(r).queued);
        expect(queued.filter((q) => q === false)).toHaveLength(1);
        expect(L.keys("save:")).toHaveLength(1);
        expect(L.entries()).toHaveLength(4);
        expect(L.helper.calls.filter((c) => c === "POST /fetch")).toHaveLength(1);
        expect([...rs.map((r) => asBody(r).queue_ahead)].filter((n) => n !== null).sort()).toEqual([1, 2, 3, 4]);
    });
    it("a plain create racing a queued one: one is served, the other refused or queued, never two helpers", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const rs = await Promise.all([
            L.studio.create(KEY_ID, json({ url: link(1) })),
            L.studio.create(KEY_ID, json({ url: link(2) })),
            L.studio.create(KEY_ID, json({ url: link(3), queue: true })),
        ]);
        expect(rs.map((r) => r.status).sort()).toEqual([201, 201, 429]);
        expect(L.keys("save:")).toHaveLength(1);
    });
    it("two adopts at once: one starts, one waits", async () => {
        const L = await lineWorld();
        const adopt = (n: number) =>
            L.studio.adopt(KEY_ID, json({ r2_key: `uploads/Up${n}.mp4`, name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: `Up${n}`, queue: true }));
        const rs = await Promise.all([adopt(1), adopt(2), adopt(3)]);
        expect(rs.map((r) => asBody(r).queued).sort()).toEqual([false, true, true]);
        expect(L.keys("save:")).toHaveLength(1);
        expect(L.entries()).toHaveLength(2);
    });
    it("a cancel racing a poll of the queued save: the session ends cancelled and nothing starts it", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const B = asBody(await create(L, { url: link("b"), queue: true }));
        L.helper.fetchPolls = 0;
        await L.settle(R.id);
        const [c, p] = await Promise.all([L.studio.cancelSave(KEY_ID, B.id), L.studio.advance(B.id, 0)]);
        expect(c.status).toBe(200);
        expect(L.session(B.id)).toMatchObject({ status: "error", error_code: "error.studio.cancelled" });
        expect(asBody(p).status).not.toBe("ready");
        expect(L.helper.fetchBodies.map((b) => b.id)).not.toContain(B.id);
        expect(L.keys("save:")).toEqual([]);
    });
    it("a cancel marks the session cancelled BEFORE its entry is removed", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const B = asBody(await create(L, { url: link("b"), queue: true }));
        const del = L.kv.delete.bind(L.kv);
        const seen: string[] = [];
        (L.kv as any).delete = async (k: string) => {
            if (k.startsWith("line:")) seen.push(L.session(B.id).status);
            return del(k);
        };
        await L.studio.cancelSave(KEY_ID, B.id);
        expect(seen).toEqual(["error"]);
    });
});

describe("an eviction between the helper taking a queued render and the entry's removal", () => {
    it("the render is collected, not answered 'queued' for ever, and the line behind it moves", async () => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const q = asBody(await L.render(S.sid, { queue: true }));
        const B = asBody(await create(L, { url: link("b"), queue: true }));
        L.helper.fetchPolls = 0;
        // the object dies right after the helper took the upload: the entry's removal never happens
        const del = L.kv.delete.bind(L.kv);
        let armed = true;
        (L.kv as any).delete = async (k: string) => {
            if (armed && k.startsWith("line:") && (L.kv.m.get(k) as any)?.job === q.job) {
                armed = false;
                throw new Error("evicted");
            }
            return del(k);
        };
        await L.studio.sweep();
        expect(L.kv.m.has(`job:${q.job}`)).toBe(true);
        expect(L.entries().map((e) => e.job ?? e.sid)).toContain(q.job);
        // a poll now answers the running render, not "queued"
        const fresh = L.make({ notify: L.notify, live: L.live });
        expect(asBody(await fresh.renderStatus(S.sid, q.job, 0)).phase).not.toBe("queued");
        const uploads = () => L.helper.calls.filter((c) => c === "POST /jobs/upload").length;
        const before = uploads();
        for (let i = 0; i < 20; i++) {
            L.clock.t += 5000;
            await fresh.sweep();
        }
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", q.job)).toEqual([{ status: "success" }]);
        // the pump dropped the dead entry instead of re-uploading the same id
        expect(L.entries().map((e) => e.job ?? e.sid)).not.toContain(q.job);
        expect(uploads()).toBe(before);
        expect(L.session(B.id).status).toBe("ready");
    });
    it("a render the helper already took cannot be cancelled (409), and the cancel does not remove its entry", async () => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const q = asBody(await L.render(S.sid, { queue: true }));
        L.kv.m.set(`job:${q.job}`, { keyId: `studio:${S.sid}`, createdAt: L.clock.t, params: {} });
        const res = await L.studio.cancelRender(KEY_ID, S.sid, q.job);
        expect(res.status).toBe(409);
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", q.job)).toEqual([{ status: "pending" }]);
    });
});

describe("the line's busy wait", () => {
    it("a lined save that meets a foreign 429 is failed error.studio.busy at LINE_BUSY_WAIT_MS, not abandoned earlier by the sweep's save budget", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const B = asBody(await create(L, { url: link("b"), queue: true }));
        const C = asBody(await create(L, { url: link("c"), queue: true }));
        L.helper.fetchPolls = 0;
        await L.studio.sweep(); // R done, B started
        L.helper.busyFetchStarts = 1e9; // a foreign job holds the helper
        L.helper.fetchStarted.clear();
        const t0 = L.clock.t;
        let ended = 0;
        for (let i = 0; i < 400; i++) {
            L.clock.t += 5000;
            await L.studio.sweep();
            if (L.session(B.id).status !== "saving") {
                ended = L.clock.t - t0;
                break;
            }
        }
        expect(L.session(R.id).status).toBe("ready");
        expect(L.session(B.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
        expect(ended).toBeGreaterThanOrEqual(LINE_BUSY_WAIT_MS);
        expect(ended).toBeLessThan(LINE_BUSY_WAIT_MS + 30_000);
        expect(L.session(C.id).status).toBe("saving"); // the next one still waits its turn
    });
    it("the same for an adopted upload whose probe keeps meeting a foreign 429", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const A = asBody(
            await L.studio.adopt(KEY_ID, json({ r2_key: S.r2, name: "clip.mp4", content_type: "video/mp4", bytes: 4096, item_id: "Up1", queue: true })),
        );
        L.helper.fetchPolls = 0;
        L.helper.probeBusy = 1e9;
        await L.studio.sweep(); // R done, the adopt's record written
        const t0 = L.clock.t;
        let ended = 0;
        for (let i = 0; i < 400; i++) {
            L.clock.t += 5000;
            await L.studio.sweep();
            if (L.session(A.id).status !== "saving") {
                ended = L.clock.t - t0;
                break;
            }
        }
        expect(L.session(R.id).status).toBe("ready");
        expect(L.session(A.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
        expect(ended).toBeGreaterThanOrEqual(LINE_BUSY_WAIT_MS);
        expect(ended).toBeLessThan(LINE_BUSY_WAIT_MS + 30_000);
    });
});

describe("a queued render's transient start failure is not final", () => {
    it.each([
        [503, "error.webp.unavailable"],
        [502, "error.webp.unavailable"],
    ])("%i %s keeps it at the head (attempts counted); the next pass starts it", async (status, code) => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const r = asBody(await L.render(S.sid, { queue: true }));
        L.helper.fetchPolls = 0;
        await L.settle(R.id);
        const spy = vi
            .spyOn(L.webp, "createFromUpload")
            .mockResolvedValueOnce({ status, body: { status: "error", error: { code } } } as never);
        await L.studio.pumpLine();
        expect(L.entries()).toMatchObject([{ job: r.job, attempts: 1, starting: null }]);
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "pending" }]);
        spy.mockRestore();
        await L.studio.sweep();
        await L.studio.sweep();
        expect(L.rows("SELECT status FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "success" }]);
    });
    it("a failure that cannot improve (its original is gone) is still final", async () => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const r = asBody(await L.render(S.sid, { queue: true }));
        L.originals.objects.delete(S.r2);
        L.helper.fetchPolls = 0;
        await L.settle(R.id);
        await L.studio.pumpLine();
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r.job)).toEqual([{ status: "error", error_code: "error.webp.storage" }]);
    });
});

describe("a refusal while the line is not empty arms the sweep", () => {
    it("an old client's create, adopt and render are turned away, and each arms a sweep", async () => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        await create(L, { url: link("a"), queue: true });
        let n = L.sweepsArmed();
        expect((await create(L, { url: link("old") })).status).toBe(429);
        expect(L.sweepsArmed()).toBeGreaterThan(n);
        n = L.sweepsArmed();
        expect(
            (await L.studio.adopt(KEY_ID, json({ r2_key: "uploads/Up9.mp4", name: "a.mp4", content_type: "video/mp4", bytes: 10, item_id: "Up9" }))).status,
        ).toBe(429);
        expect(L.sweepsArmed()).toBeGreaterThan(n);
        n = L.sweepsArmed();
        expect((await L.render(S.sid, {})).status).toBe(429);
        expect(L.sweepsArmed()).toBeGreaterThan(n);
    });
    it("with an empty line a refusal arms nothing", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const n = L.sweepsArmed();
        expect((await create(L, { url: link("old") })).status).toBe(429);
        expect(L.sweepsArmed()).toBe(n);
    });
});

describe("a poster still running is not forgotten when a later pass ends", () => {
    it("the helper stays held by the first poster after the next sweep pass returns", async () => {
        const L = await lineWorld();
        L.seed();
        L.helper.posterGate = new Promise(() => {});
        const one = L.make({ notify: L.notify });
        await one.kickPosters();
        void one.sweep();
        await vi.waitFor(() => expect(L.helper.posterIds).toHaveLength(1));
        await one.sweep(); // a later pass: posters.sweep answers at once, the first poster still runs
        const res = await (await import("../src/studio")).handleStudioRoute(
            one,
            new Request("https://do.internal/studio/line", { headers: { "x-cobalt-key-id": KEY_ID } }),
        );
        expect(((await res.json()) as any).running).toMatchObject({ kind: "poster" });
    });
});

describe("the line summary", () => {
    it("the last member's state is stored before the message is sent", async () => {
        const L = await lineWorld();
        const sid = asBody(await create(L, {})).id as string;
        await putLine(L);
        const seen: unknown[] = [];
        L.hark.onCall = () => seen.push({ ...lineRecord(L).members });
        await L.settle(sid);
        expect(seen).toEqual([{ [sid]: "saved" }]);
    });
    it("a restart between the send and the record's removal neither resends nor strands the round", async () => {
        const L = await lineWorld();
        const sid = asBody(await create(L, {})).id as string;
        await putLine(L);
        const del = L.kv.delete.bind(L.kv);
        let armed = true;
        (L.kv as any).delete = async (k: string) => {
            if (armed && k === `notify:line:${KEY_ID}`) {
                armed = false;
                throw new Error("evicted");
            }
            return del(k);
        };
        await L.settle(sid).catch(() => {});
        expect(L.hark.calls).toHaveLength(1);
        expect(lineRecord(L)).toBeDefined();
        await L.notify.retryDue(L.clock.t);
        expect(L.hark.calls).toHaveLength(1);
        expect(lineRecord(L)).toBeUndefined();
    });
    it("a restart before the send leaves a settled round that the sweep's notify pass sends", async () => {
        const L = await lineWorld();
        const sid = asBody(await create(L, {})).id as string;
        await putLine(L);
        // the state was stored, the object died before sending
        L.kv.m.set(`notify:line:${KEY_ID}`, { ...lineRecord(L), members: { [sid]: "saved" } });
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'ready' WHERE id = ?").run(sid);
        expect(L.hark.calls).toEqual([]);
        await L.notify.retryDue(L.clock.t);
        expect(L.hark.calls).toHaveLength(1);
        expect(lineRecord(L)).toBeUndefined();
    });
    it("a post deleted while its save waits: the row ends, the member is dropped, and the summary is not stuck", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const A = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        expect(Object.keys(lineRecord(L).members).sort()).toEqual([R.id, A.id].sort());
        L.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(L.clock.t, A.id);
        L.clock.t += 1;
        L.helper.fetchPolls = 0;
        await L.sweeps(3);
        expect(L.session(A.id)).toMatchObject({ status: "error", error_code: "error.studio.expired" });
        // no "couldn't save" for a post the owner deleted: R alone is announced
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toMatchObject({ url: `cobalt-apple://session/${R.id}` });
        expect(L.hark.calls[0]!.title).toBe("cobalt");
        expect(lineRecord(L)).toBeUndefined();
    });
    it("a post deleted while its render waits: no \"couldn't make the webp\"", async () => {
        const L = await lineWorld();
        const S = L.seed({}, { row: false });
        L.helper.fetchPolls = 1e9;
        await create(L, { url: link("run") });
        const r = asBody(await L.render(S.sid, { queue: true, notify: true }));
        L.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(L.clock.t, S.sid);
        L.clock.t += 1;
        L.helper.fetchPolls = 0;
        await L.sweeps(3);
        expect(L.rows("SELECT status, error_code FROM studio_renders WHERE id = ?", r.job)).toEqual([
            { status: "error", error_code: "error.studio.expired" },
        ]);
        expect(L.hark.calls).toEqual([]);
    });
});

describe("the line lock is never held across a notification", () => {
    it("a slow webhook while stale entries end does not block a new create", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const R = asBody(await create(L, { url: link("run") }));
        const A = asBody(await create(L, { url: link("a"), queue: true, notify: { on: ["failed"] } }));
        L.clock.t += 31 * 60_000;
        L.kv.m.set(`save:${R.id}`, { ...(L.kv.m.get(`save:${R.id}`) as object), startedAt: L.clock.t, lastAdvance: L.clock.t });
        let release!: () => void;
        L.hark.gate = new Promise<void>((r) => (release = r));
        const sweep = L.studio.sweep();
        await vi.waitFor(() => expect(L.hark.calls).toHaveLength(1)); // A's failure is being announced, slowly
        expect(L.session(A.id).status).toBe("error");
        // while that send hangs, the line is usable
        const b = await Promise.race([
            create(L, { url: link("b"), queue: true }),
            new Promise<"blocked">((r) => setTimeout(() => r("blocked"), 1500)),
        ]);
        expect(b).not.toBe("blocked");
        expect(asBody(b as { body: unknown }).queued).toBe(true);
        release();
        await sweep;
    });
});
