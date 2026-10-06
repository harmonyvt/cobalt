// The Hark summary of the server's line (APP-API-CONTRACT.md section 17.8): `PUT|DELETE
// /studio/line/notify`, the settle hook, and the copy. One message when everything a key left
// behind is done; one member says exactly what that event says on its own.
import { describe, expect, it } from "vitest";
import { JOBS_URL, lineSummaryMessage, NOTIFY_RETRY_DELAYS_MS, renderedMessage, savedMessage, sessionUrl } from "../src/notify";
import { CLIENT, KEY_ID, LINK, asBody, json } from "./poster-world";
import { auth2, lineWorld, type LW } from "./line-world";

const link = (n: number | string) => `${LINK}?n=${n}`;
const create = (L: LW, body: Record<string, unknown>, keyId = KEY_ID) => L.studio.create(keyId, json({ url: LINK, ...body }));
const putLine = (L: LW, body?: string, headers?: Record<string, string>) => L.keyed("/studio/line/notify", "PUT", headers, body);
const lineRecord = (L: LW, keyId = KEY_ID) => L.kv.m.get(`notify:line:${keyId}`) as any;
async function running(L: LW) {
    L.helper.fetchPolls = 1e9;
    const r = asBody(await create(L, { url: link("run") }));
    return { sid: r.id as string, release: () => (L.helper.fetchPolls = 0) };
}

describe("PUT /studio/line/notify: the snapshot", () => {
    it("watches the caller's work in flight: its line entries, its running save and its unfinished render jobs", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const S = L.seed();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const other = asBody(await create(L, { url: link("other"), queue: true }, "key-row-2"));
        const q = asBody(await L.render(S.sid, { queue: true }));
        const res = await putLine(L);
        expect(res.status).toBe(200);
        const b = (await res.json()) as any;
        expect(b).toEqual({ status: "success", bridge: true, watching: 3, expires_at: L.clock.t + 24 * 60 * 60 * 1000 });
        const rec = lineRecord(L);
        expect(rec.members).toEqual({ [R.sid]: "pending", [a.id]: "pending", [`${S.sid}:${q.job}`]: "pending" });
        expect(rec.members).not.toHaveProperty(other.id);
        expect(rec.at).toBe(L.clock.t);
        expect(rec.expires_at).toBe(L.clock.t + 24 * 60 * 60 * 1000);
        // the other key has nothing stored
        expect(L.kv.m.has("notify:line:key-row-2")).toBe(false);
    });
    it("an unfinished render job (running, not queued) is a member too", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.jobPolls = 1e9;
        const job = asBody(await L.render(S.sid, {})).job;
        await putLine(L);
        expect(lineRecord(L).members).toEqual({ [`${S.sid}:${job}`]: "pending" });
    });
    it("leaves out any session or job with its own opt-in: those announce themselves", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const own = asBody(await create(L, { url: link("own"), queue: true, notify: { on: ["saved"] } }));
        const plain = asBody(await create(L, { url: link("plain"), queue: true }));
        const jobOwn = asBody(await L.render(S.sid, { queue: true, notify: true }));
        const jobPlain = asBody(await L.render(S.sid, { start: 1, queue: true }));
        // the session with its own opt-in covers its renders too
        await L.notify.put(KEY_ID, S.sid, json({ on: ["rendered"] }));
        const noRenders = (await (await putLine(L)).json()) as any;
        expect(Object.keys(lineRecord(L).members).sort()).toEqual([R.sid, plain.id].sort());
        expect(noRenders.watching).toBe(2);
        void own;
        void jobOwn;
        void jobPlain;
    });
    it("a render-only opt-in ('notify': true) leaves just that job out", async () => {
        const L = await lineWorld();
        const S = L.seed();
        await running(L);
        const jobOwn = asBody(await L.render(S.sid, { queue: true, notify: true }));
        const jobPlain = asBody(await L.render(S.sid, { start: 1, queue: true }));
        await putLine(L);
        expect(Object.keys(lineRecord(L).members).filter((k) => k.includes(":"))).toEqual([`${S.sid}:${jobPlain.job}`]);
        void jobOwn;
    });
    it("nothing in flight: watching 0, nothing stored, expires_at null", async () => {
        const L = await lineWorld();
        const res = await putLine(L);
        expect(await res.json()).toEqual({ status: "success", bridge: true, watching: 0, expires_at: null });
        expect(L.keys("notify:line:")).toEqual([]);
        // everything in flight announces itself: the same
        await create(L, { notify: { on: ["saved"] } });
        expect((await (await putLine(L)).json()) as any).toMatchObject({ watching: 0, expires_at: null });
        expect(L.keys("notify:line:")).toEqual([]);
    });
    it("bridge off: bridge false, nothing stored, nothing sent", async () => {
        const L = await lineWorld({ hook: null });
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const res = await putLine(L, "{}");
        expect(await res.json()).toEqual({ status: "success", bridge: false, watching: 0, expires_at: null });
        expect(L.keys("notify:line:")).toEqual([]);
        R.release();
        await L.sweeps(3);
        expect(L.session(a.id).status).toBe("ready");
        expect(L.hark.calls).toEqual([]);
    });
    it("the body is empty or {}; anything else is 400 error.notify.invalid (and stores nothing)", async () => {
        const L = await lineWorld();
        await running(L);
        for (const body of [undefined, "", "  ", "{}", " {} "]) {
            const res = await putLine(L, body);
            expect([body, res.status]).toEqual([body, 200]);
        }
        for (const body of ['{"on":["saved"]}', "[]", "null", "nope", '"x"', "1"]) {
            const res = await putLine(L, body);
            expect([body, res.status]).toEqual([body, 400]);
            expect(((await res.json()) as any).error.code).toBe("error.notify.invalid");
        }
        const big = await putLine(L, `{"pad":"${"x".repeat(1100)}"}`);
        expect(big.status).toBe(400);
    });
    it("a repeat adds the work in flight now to the members still pending and keeps the outcomes already in", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        const at = lineRecord(L).at;
        expect(Object.keys(lineRecord(L).members).sort()).toEqual([R.sid, a.id].sort());
        // R finishes: its outcome is in
        R.release();
        await L.studio.advance(R.sid, 0);
        expect(lineRecord(L).members[R.sid]).toBe("saved");
        L.helper.fetchPolls = 1e9;
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        L.clock.t += 1000;
        const res = (await (await putLine(L)).json()) as any;
        expect(lineRecord(L).members).toEqual({ [R.sid]: "saved", [a.id]: "pending", [b.id]: "pending" });
        expect(lineRecord(L).at).toBe(at);
        expect(res.watching).toBe(3);
        expect(res.expires_at).toBe(L.clock.t + 24 * 60 * 60 * 1000);
        expect(L.hark.calls).toEqual([]);
    });
});

describe("the one message", () => {
    it("is sent once, when the last member settles, never before: three saves, 'done · 3 saved', the jobs list", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        await putLine(L);
        R.release();
        await L.studio.sweep(); // R done, a starts
        await L.studio.sweep(); // a done, b starts
        expect(L.hark.calls).toEqual([]);
        expect(lineRecord(L).members).toEqual({ [R.sid]: "saved", [a.id]: "saved", [b.id]: "pending" });
        await L.studio.sweep(); // b done
        expect(L.hark.calls).toEqual([{ title: "cobalt", body: "done · 3 saved", url: JOBS_URL }]);
        expect(L.kv.m.has(`notify:line:${KEY_ID}`)).toBe(false);
        expect([...L.kv.m.keys()].filter((k) => k.startsWith(`notify:ev:line:${KEY_ID}:`))).toHaveLength(1);
        await L.sweeps(3);
        expect(L.hark.calls).toHaveLength(1);
    });
    it("one member: exactly the message of a per-session opt-in (9.4), tapped to that session", async () => {
        const one = await lineWorld();
        await one.addKey2();
        const sid = asBody(await create(one, {})).id as string;
        await putLine(one);
        await one.settle(sid);
        const ref = await lineWorld();
        const sid2 = asBody(await create(ref, {})).id as string;
        await ref.notify.put(KEY_ID, sid2, json({ on: ["saved", "failed"] }));
        await ref.settle(sid2);
        expect(one.hark.calls).toHaveLength(1);
        expect(ref.hark.calls).toHaveLength(1);
        expect(one.hark.calls[0]).toEqual({ ...ref.hark.calls[0]!, url: sessionUrl(sid) });
        expect(one.hark.calls[0]!.body).toBe(savedMessage("x · 2105237035271258436", 9.6).body);
        expect(one.hark.calls[0]!.url).toBe(`cobalt-apple://session/${sid}`);
    });
    it("one failed member: the single-job failure wording, tapped to that session", async () => {
        const L = await lineWorld();
        const sid = asBody(await create(L, {})).id as string;
        await putLine(L);
        L.helper.fetchError = "error.api.fetch.fail";
        await L.settle(sid);
        expect(L.hark.calls).toEqual([
            { title: "cobalt couldn't finish", body: "couldn't save x · 2105237035271258436 — the link could not be fetched", url: `cobalt-apple://session/${sid}` },
        ]);
    });
    it("one webp: the single-job webp message with its url", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.jobPolls = 1e9;
        const job = asBody(await L.render(S.sid, {})).job;
        await putLine(L);
        L.helper.jobPolls = 0;
        const done = asBody(await L.studio.renderStatus(S.sid, job, 0));
        expect(L.hark.calls).toEqual([
            {
                ...renderedMessage({ url: done.url, bytes: done.bytes, width: done.width, height: done.height }),
                url: `cobalt-apple://session/${S.sid}`,
            },
        ]);
        expect(L.hark.calls[0]!.body).toMatch(/^webp ready · 480×560 · .+\nhttps:\/\/media\./);
    });
    it("several: counts, up to three failure lines in 9.4's wording, and the webp's url on the last line when exactly one was made", async () => {
        const L = await lineWorld();
        const S = L.seed();
        const R = await running(L);
        const saves: string[] = [];
        for (let i = 0; i < 5; i++) saves.push(asBody(await create(L, { url: link(i), queue: true })).id);
        const r = asBody(await L.render(S.sid, { queue: true, priority: "focused" }));
        await putLine(L);
        // the running save and the render succeed, then the next four fail, the last one succeeds
        R.release();
        await L.studio.sweep(); // R done, the focused render starts
        await L.studio.sweep(); // render done, save 0 starts
        L.helper.fetchError = "error.api.fetch.fail";
        await L.studio.sweep(); // save 0 fails, save 1 starts
        await L.studio.sweep();
        await L.studio.sweep();
        await L.studio.sweep(); // saves 1..3 fail
        L.helper.fetchError = null;
        await L.sweeps(3); // save 4 saves
        expect(L.helper.fetchBodies).toHaveLength(6); // the running save and five queued
        expect(L.hark.calls).toHaveLength(1);
        const m = L.hark.calls[0]!;
        expect(m.title).toBe("cobalt");
        expect(m.url).toBe(JOBS_URL);
        const done = asBody(await L.studio.renderStatus(S.sid, r.job, 0));
        expect(m.body.split("\n")).toEqual([
            "done · 2 saved · 1 webp ready · 4 couldn't finish",
            "couldn't save x · 2105237035271258436 — the link could not be fetched",
            "couldn't save x · 2105237035271258436 — the link could not be fetched",
            "couldn't save x · 2105237035271258436 — the link could not be fetched",
            done.url,
        ]);
    });
    it("two webps: 'webps' in the plural and no url line", () => {
        const members = { a: "saved", "b:j1": "rendered", "c:j2": "rendered" };
        const webps = {
            "b:j1": { url: "https://m/1.webp", bytes: 1, width: 1, height: 1 },
            "c:j2": { url: "https://m/2.webp", bytes: 1, width: 1, height: 1 },
        };
        const msg = lineSummaryMessage({ members, webps }, new Map());
        expect(msg).toMatchObject({ title: "cobalt", body: "done · 1 saved · 2 webps ready", url: JOBS_URL });
    });
    it("a failed render in a mixed round reads like the single-job wording, a failed save names its link", () => {
        const members = { a: "failed:error.webp.busy", "b:j1": "failed:error.webp.encode_failed", c: "saved" };
        const rows = new Map([["a", { service: "instagram", link: "https://www.instagram.com/reel/Dd7P496wolG/", title: null, duration: null }]]);
        const msg = lineSummaryMessage({ members, webps: {} }, rows);
        expect(msg.body.split("\n")).toEqual([
            "done · 1 saved · 2 couldn't finish",
            "couldn't save instagram · Dd7P496wolG — the server was busy",
            "couldn't make the webp — something went wrong on the server",
        ]);
    });
    it("is lowercase and within Hark's caps (title 80, body 2000)", async () => {
        const L = await lineWorld();
        const R = await running(L);
        for (let i = 0; i < 4; i++) await create(L, { url: link(i), queue: true });
        await putLine(L);
        R.release();
        await L.sweeps(8);
        const m = L.hark.calls[0]!;
        expect(m.title).toBe(m.title.toLowerCase());
        expect(m.title.length).toBeLessThanOrEqual(80);
        expect(m.body.length).toBeLessThanOrEqual(2000);
        expect(m.body.split("\n")[0]).toBe(m.body.split("\n")[0]!.toLowerCase());
    });
    it("a cancelled member is dropped: with one left the single-job message, with none nothing is sent and the record is gone", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        expect((await L.keyed(`/studio/${a.id}/line`, "DELETE")).status).toBe(200);
        expect(lineRecord(L).members).toEqual({ [R.sid]: "pending" });
        R.release();
        await L.settle(R.sid);
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]!.url).toBe(`cobalt-apple://session/${R.sid}`);

    });
    it("all members cancelled: nothing sent, record deleted", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        const b = asBody(await create(L, { url: link("b"), queue: true }));
        await putLine(L);
        // the running one is also dropped from the watch by its own opt-in being added later? no: it stays,
        // so cancel what can be cancelled and check the round is still open for the running save
        await L.keyed(`/studio/${a.id}/line`, "DELETE");
        await L.keyed(`/studio/${b.id}/line`, "DELETE");
        expect(lineRecord(L).members).toEqual({ [R.sid]: "pending" });
        expect(L.hark.calls).toEqual([]);
        // a record whose every member is cancelled is deleted without a message
        await L.notify.onLineSettle(R.sid, null, { kind: "cancelled" });
        expect(L.kv.m.has(`notify:line:${KEY_ID}`)).toBe(false);
        expect(L.hark.calls).toEqual([]);
    });
    it("a member that ends in the line (the 30 minute ceiling) counts as failed: 'done · 1 saved · 1 couldn't finish', with its failure line", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        // the running save is kept alive past the ceiling; `a` never got its turn
        L.clock.t += 30 * 60_000 + 1;
        L.kv.m.set(`save:${R.sid}`, { ...(L.kv.m.get(`save:${R.sid}`) as object), startedAt: L.clock.t, lastAdvance: L.clock.t });
        await L.studio.sweep();
        expect(L.session(a.id)).toMatchObject({ status: "error", error_code: "error.studio.busy" });
        expect(L.hark.calls).toEqual([]); // R is still pending
        R.release();
        await L.settle(R.sid);
        expect(L.hark.calls).toEqual([
            {
                title: "cobalt",
                body: "done · 1 saved · 1 couldn't finish\ncouldn't save x · 2105237035271258436 — the server was busy",
                url: JOBS_URL,
            },
        ]);
    });
});

describe("exactly once", () => {
    it("a poll and the sweep settling the last member at the same time send one message", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        R.release();
        await L.studio.sweep(); // R ready, a started
        expect(L.hark.calls).toEqual([]);
        await Promise.all([L.studio.advance(a.id, 0), L.studio.sweep(), L.studio.advance(a.id, 0)]);
        expect(L.session(a.id).status).toBe("ready");
        expect(L.hark.calls).toHaveLength(1);
        expect(L.hark.calls[0]).toMatchObject({ body: "done · 2 saved", url: JOBS_URL });
    });
    it("two settle calls for the same last member send one message", async () => {
        const L = await lineWorld();
        const sid = asBody(await create(L, {})).id as string;
        await L.addKey2();
        await putLine(L);
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'ready' WHERE id = ?").run(sid);
        await Promise.all([
            L.notify.onLineSettle(sid, null, { kind: "saved" }),
            L.notify.onLineSettle(sid, null, { kind: "saved" }),
            L.notify.onLineSettle(sid, null, { kind: "saved" }),
        ]);
        expect(L.hark.calls).toHaveLength(1);
    });
    it("a repeated render poll after the summary was sent sends nothing more", async () => {
        const L = await lineWorld();
        const S = L.seed();
        L.helper.jobPolls = 1e9;
        const job = asBody(await L.render(S.sid, {})).job;
        await putLine(L);
        L.helper.jobPolls = 0;
        for (let i = 0; i < 4; i++) await L.studio.renderStatus(S.sid, job, 0);
        expect(L.hark.calls).toHaveLength(1);
    });
    it("a new round after a finished one sends its own message (the first one's marker does not swallow it)", async () => {
        const L = await lineWorld();
        const a = asBody(await create(L, {})).id as string;
        await putLine(L);
        await L.settle(a);
        expect(L.hark.calls).toHaveLength(1);
        const b = asBody(await create(L, { url: link("b") })).id as string;
        await putLine(L); // same fake instant
        await L.settle(b);
        expect(L.hark.calls).toHaveLength(2);
        expect(L.hark.calls[1]!.url).toBe(`cobalt-apple://session/${b}`);
    });
});

describe("DELETE /studio/line/notify", () => {
    it("204, removes the record, and the round never sends; idempotent", async () => {
        const L = await lineWorld();
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        const del = await L.keyed("/studio/line/notify", "DELETE");
        expect(del.status).toBe(204);
        expect(await del.text()).toBe("");
        expect(L.keys("notify:line:")).toEqual([]);
        R.release();
        await L.sweeps(4);
        expect(L.session(a.id).status).toBe("ready");
        expect(L.hark.calls).toEqual([]);
        expect((await L.keyed("/studio/line/notify", "DELETE")).status).toBe(204);
    });
    it("cancels the summary's pending retries (its marker stays: nothing is ever sent twice)", async () => {
        const L = await lineWorld();
        L.hark.status = 500;
        const sid = asBody(await create(L, {})).id as string;
        await putLine(L);
        await L.settle(sid);
        expect(L.hark.calls).toHaveLength(1);
        const evKey = L.keys(`notify:ev:line:${KEY_ID}:`)[0]!;
        expect(L.kv.m.get(evKey)).toMatchObject({ done: false, tries: 1, url: `cobalt-apple://session/${sid}` });
        expect((await L.keyed("/studio/line/notify", "DELETE")).status).toBe(204);
        expect(L.kv.m.get(evKey)).toMatchObject({ done: true, outcome: "cancelled" });
        L.clock.t += NOTIFY_RETRY_DELAYS_MS[0]! + 1;
        L.hark.status = 200;
        await L.notify.retryDue(L.clock.t);
        expect(L.hark.calls).toHaveLength(1);
    });
    it("a failed send is retried by the sweep with the same url (the jobs list for a summary)", async () => {
        const L = await lineWorld();
        L.hark.status = 500;
        const R = await running(L);
        const a = asBody(await create(L, { url: link("a"), queue: true }));
        await putLine(L);
        R.release();
        await L.sweeps(3);
        expect(L.session(a.id).status).toBe("ready");
        expect(L.hark.calls).toHaveLength(1);
        L.hark.status = 200;
        L.clock.t += NOTIFY_RETRY_DELAYS_MS[0]! + 1;
        await L.notify.retryDue(L.clock.t);
        expect(L.hark.calls).toHaveLength(2);
        expect(L.hark.calls[1]).toEqual({ title: "cobalt", body: "done · 2 saved", url: JOBS_URL });
    });
    it("works with the bridge off (nothing to remove) and for a key that never put anything", async () => {
        const off = await lineWorld({ hook: null });
        expect((await off.keyed("/studio/line/notify", "DELETE")).status).toBe(204);
        const L = await lineWorld();
        expect((await L.keyed("/studio/line/notify", "DELETE")).status).toBe(204);
    });
    it("is the caller's own: another key's record is untouched", async () => {
        const L = await lineWorld();
        await L.addKey2();
        await running(L);
        await putLine(L);
        expect((await L.keyed("/studio/line/notify", "DELETE", auth2)).status).toBe(204);
        expect(L.kv.m.has(`notify:line:${KEY_ID}`)).toBe(true);
    });
});

describe("housekeeping", () => {
    it("a summary record expires after 24 hours and is dropped by the sweep's notify pass", async () => {
        const L = await lineWorld();
        await running(L);
        await putLine(L);
        L.clock.t += 24 * 60 * 60 * 1000 + 1;
        await L.notify.retryDue(L.clock.t);
        expect(L.keys("notify:line:")).toEqual([]);
        void CLIENT;
    });
});
