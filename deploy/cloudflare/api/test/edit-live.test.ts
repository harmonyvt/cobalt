// Live Activities for editor renders (APP-API-CONTRACT.md section 32): the content state built from the render row, the
// coalescing, the payloads, the routes inside the Durable Object, the gate, and a whole render driven by the real
// EditRenderCore with the real EditLiveService behind its hook (Apple is a script, D1 is node:sqlite).
import { beforeAll, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import {
    decideEditPush,
    EDIT_LIVE_MIN_GAP_MS,
    editLivePayload,
    editLiveState,
    EditLiveService,
    handleEditLiveRoute,
    type EditLiveRecord,
} from "../src/edit-live";
import type { RenderRow } from "../src/edits";
import { decide } from "../src/gate";
import { KEY_ID_HEADER } from "../src/headers";
import { Apple, bad, makePem } from "./apns-fakes";
import { coreWorld, INTERNAL, KEY_ID } from "./edits-world";
import { MemoryKV } from "./studio-fakes";

const RID = "Rq7sTu0vWx3yZa6bCd9e";
const TOKEN = "ab".repeat(40);
const T0 = 1_800_000_000_000;

let pem: string;
beforeAll(async () => {
    pem = await makePem();
});

const row = (over: Partial<RenderRow> = {}): RenderRow => ({
    id: RID,
    project_id: "ProjectAAAAAAAAA",
    revision: 1,
    title: "beach day",
    status: "queued",
    cancel_requested: 0,
    sent_bytes: null,
    input_bytes: 1000,
    seconds_done: null,
    seconds_total: 20,
    error_code: null,
    item_id: null,
    bytes: null,
    width: null,
    height: null,
    duration: null,
    created_at: T0,
    started_at: null,
    finished_at: null,
    queue_ahead: 2,
    poster: null,
    ...over,
});

describe("the content state", () => {
    it("maps each status of the row", () => {
        expect(editLiveState(row())).toEqual({ status: "queued", since: T0 / 1000, title: "beach day", queueAhead: 2 });
        expect(editLiveState(row({ status: "preparing", started_at: T0 + 5000, sent_bytes: 500 }))).toEqual({
            status: "preparing", since: T0 / 1000 + 5, title: "beach day", progress: 0.05,
        });
        expect(editLiveState(row({ status: "rendering", started_at: T0, seconds_done: 10 })).progress).toBe(0.525);
        expect(editLiveState(row({ status: "finishing", started_at: T0 })).progress).toBe(0.95);
        expect(editLiveState(row({ status: "done", finished_at: T0 + 60_000, duration: 20.0333, width: 1080, height: 1920, bytes: 9_000_000 }))).toEqual({
            status: "done", since: T0 / 1000 + 60, title: "beach day", progress: 1,
            resultSeconds: 20.033, resultWidth: 1080, resultHeight: 1920, resultBytes: 9_000_000,
        });
        expect(editLiveState(row({ status: "error", error_code: "error.edit.timeout", finished_at: T0 + 1000 }))).toEqual({
            status: "failed", since: T0 / 1000 + 1, title: "beach day", code: "error.edit.timeout",
        });
        expect(editLiveState(row({ status: "cancelled", error_code: "error.edit.cancelled" })).status).toBe("cancelled");
        expect(editLiveState(row({ status: "error", error_code: "error.edit.cancelled" })).status).toBe("cancelled");
        expect(editLiveState(row({ title: "" })).title).toBe("untitled edit");
    });

    it("every Int field is an integer (Swift drops a whole update over a fractional Int)", () => {
        const s = editLiveState(row({ status: "done", finished_at: T0, duration: 3.5, width: 1080, height: 1920, bytes: 12345 }));
        for (const k of ["since", "resultWidth", "resultHeight", "resultBytes"] as const) expect(Number.isInteger(s[k])).toBe(true);
    });
});

describe("coalescing and payloads", () => {
    const rendering = (p: number) => ({ status: "rendering" as const, since: 1, title: "t", progress: p });
    const rec = (sent: EditLiveRecord["sent"], sentAt = T0) => ({ sent, sentAt });

    it("a status change goes at once with priority 10; the same state never goes twice", () => {
        expect(decideEditPush(rec(null), rendering(0.1), T0)?.priority).toBe(10);
        expect(decideEditPush(rec({ status: "preparing", since: 1, title: "t", progress: 0.1 }), rendering(0.1), T0 + 1)?.priority).toBe(10);
        expect(decideEditPush(rec(rendering(0.3)), rendering(0.3), T0 + 60_000)).toBeNull();
    });

    it("progress goes at most every 10 s and only when the bar moved 4 points; then priority 5", () => {
        expect(decideEditPush(rec(rendering(0.1)), rendering(0.5), T0 + EDIT_LIVE_MIN_GAP_MS - 1)).toBeNull();
        expect(decideEditPush(rec(rendering(0.1)), rendering(0.12), T0 + 60_000)).toBeNull();
        const p = decideEditPush(rec(rendering(0.1)), rendering(0.2), T0 + EDIT_LIVE_MIN_GAP_MS)!;
        expect(p.priority).toBe(5);
        expect(p.event).toBe("update");
    });

    it("the queue moving up is a status change", () => {
        const q = (n: number) => ({ status: "queued" as const, since: 1, title: "t", queueAhead: n });
        expect(decideEditPush(rec(q(2)), q(1), T0 + 1)?.priority).toBe(10);
    });

    it("the end ignores the coalescing; done and failed alert and dismiss later, cancelled dismisses now", () => {
        const done = { status: "done" as const, since: 1, title: "beach day", progress: 1 };
        const p = decideEditPush(rec(rendering(0.9)), done, T0 + 1)!;
        expect(p.event).toBe("end");
        expect(p.priority).toBe(10);
        expect((p.payload as any).aps).toMatchObject({
            event: "end",
            "dismissal-date": T0 / 1000 + 900,
            alert: { title: "video ready", body: "beach day" },
            "content-state": done,
        });
        const failed = editLivePayload({ status: "failed", since: 1, title: "beach day", code: "error.edit.timeout" }, T0).aps as any;
        expect(failed.alert).toEqual({ title: "couldn't render", body: "beach day — it took too long" });
        expect(failed["dismissal-date"]).toBe(T0 / 1000 + 300);
        const cancelled = editLivePayload({ status: "cancelled", since: 1, title: "x" }, T0).aps as any;
        expect(cancelled["dismissal-date"]).toBe(T0 / 1000);
        expect(cancelled.alert).toBeUndefined();
        const update = editLivePayload(rendering(0.5), T0).aps as any;
        expect(update["stale-date"]).toBe(T0 / 1000 + 180);
        expect(update.event).toBe("update");
    });
});

describe("the gate", () => {
    const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const g = (method: string, pathname: string) =>
        decide({ method, pathname, searchParams: new URLSearchParams(), origin: null, authorization: `Api-Key ${KEY}` }, { corsUrl: "https://x", now: T0 });
    it("PUT and DELETE /live/edits/<rid> are keyed; the renderer's push route and anything else is a 404", () => {
        expect(g("PUT", `/live/edits/${RID}`)).toEqual({ action: "lookup", key: KEY, then: "live_edit" });
        expect(g("DELETE", `/live/edits/${RID}`)).toEqual({ action: "lookup", key: KEY, then: "live_edit" });
        for (const [m, p] of [["POST", `/live/edits/${RID}/push`], ["GET", `/live/edits/${RID}`], ["PUT", "/live/edits/short"], ["PUT", `/live/edits/${RID}/x`]]) {
            expect(g(m!, p!)).toMatchObject({ action: "reject", status: 404 });
        }
    });
});

// ---- the service, through its routes, over a whole render ------------------------------------------------------------

async function liveWorldReady(opts: { configured?: boolean } = {}) {
    const w = liveWorld(opts);
    await w.addKey();
    w.seedLibrary();
    w.clock.t += 1000;
    return w;
}

function liveWorld(opts: { configured?: boolean } = {}) {
    const cw = coreWorld();
    const apple = new Apple();
    const storage = new MemoryKV();
    const apns =
        opts.configured === false
            ? null
            : new ApnsClient({
                  keyP8: pem,
                  keyId: "ABC123DEFG",
                  teamId: "TEAM123456",
                  bundleId: "com.capybaraharmony.cobalt",
                  via: "worker",
                  transport: apple.transport,
                  now: cw.clock.now,
                  log: () => {},
              });
    const service = new EditLiveService({ storage, db: cw.db as unknown as D1Database, now: cw.clock.now, apns });
    const route = (method: string, path: string, body?: unknown, headers: Record<string, string> = { [KEY_ID_HEADER]: KEY_ID }) =>
        handleEditLiveRoute(
            service,
            new Request(`https://do.internal${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }),
            INTERNAL,
        );
    const core = cw.makeCore("r0", {
        liveEdit: async (rid) => {
            const res = await route("POST", `/live/edits/${rid}/push`, undefined, { "x-internal-key": INTERNAL });
            if (res.status !== 200) throw new Error(`push route ${res.status}`);
        },
    });
    return { ...cw, apple, storage, service, route, core };
}

describe("a render with an activity", () => {
    it("pushes the claim, a bounded number of progress updates, and one end with the result; then forgets the token", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender({ title: "beach day" });
        w.container.encodingPolls = 8;
        w.container.secondsDone = (poll) => Math.min(9, poll * 1.2);
        const put = await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" });
        expect(put.status).toBe(200);
        expect(await put.json()).toEqual({ status: "success", pushing: true });
        // the token arrived while queued, as the app had shown it: nothing to catch up besides the first state
        expect(w.apple.pushes.map((p) => p.payload.aps["content-state"].status)).toEqual(["queued"]);

        await w.run(w.core);
        expect(w.row(rid).status).toBe("done");
        const pushes = w.apple.pushes;
        const statuses = pushes.map((p) => p.payload.aps["content-state"].status);
        expect(statuses[0]).toBe("queued");
        expect(statuses).toContain("preparing");
        expect(statuses).toContain("rendering");
        expect(statuses.at(-1)).toBe("done");
        // a render of ~45 s of 5 s polls: progress updates at most every 10 s
        expect(pushes.length).toBeLessThan(12);
        const end = pushes.at(-1)!;
        expect(end.token).toBe(TOKEN);
        expect(end.priority).toBe(10);
        expect(end.payload.aps).toMatchObject({ event: "end", alert: { title: "video ready", body: "beach day" } });
        expect(end.payload.aps["content-state"]).toMatchObject({ resultWidth: 1080, resultHeight: 1920, resultBytes: 4096, progress: 1 });
        // progress only ever rises
        const progress = pushes.map((p) => p.payload.aps["content-state"].progress).filter((p) => p !== undefined);
        expect([...progress].sort((a, b) => a - b)).toEqual(progress);
        expect(await w.storage.get(`live:edit:${rid}`)).toBeUndefined();
    });

    it("a render nobody watches pushes nothing and finishes as before", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        await w.run(w.core);
        expect(w.row(rid).status).toBe("done");
        expect(w.apple.calls).toHaveLength(0);
    });

    it("a failing push never holds up or fails the render", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        const core = w.makeCore("r1", {
            liveEdit: async () => {
                throw new Error("main DO down");
            },
        });
        await w.run(core);
        expect(w.row(rid).status).toBe("done");
    });

    it("a render that fails ends the activity with the reason", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender({ title: "beach day" });
        w.container.helperError = "error.edit.render_failed";
        await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "sandbox" });
        await w.run(w.core);
        const end = w.apple.pushes.at(-1)!;
        expect(end.host).toBe("api.sandbox.push.apple.com");
        expect(end.payload.aps).toMatchObject({
            event: "end",
            "content-state": { status: "failed", code: "error.edit.render_failed" },
            alert: { title: "couldn't render", body: "beach day — the video couldn't be made" },
        });
    });

    it("a dead token is forgotten and never tried again", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        w.apple.script = [bad(410, "Unregistered")];
        await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" });
        expect(await w.storage.get(`live:edit:${rid}`)).toBeUndefined();
        const n = w.apple.calls.length;
        await w.run(w.core);
        expect(w.apple.calls.length).toBe(n);
    });

    it("a token for a render that already ended gets its end at once", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        await w.run(w.core);
        await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" });
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["end"]);
    });
});

describe("the routes", () => {
    it("refuse bad bodies, unknown renders, a missing key id, and the push route without the internal key", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        expect((await w.route("PUT", `/live/edits/${rid}`, { token: "nothex", env: "production" })).status).toBe(400);
        expect((await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "moon" })).status).toBe(400);
        expect((await w.route("PUT", `/live/edits/${rid}`, "x".repeat(2000))).status).toBe(400);
        expect((await w.route("PUT", `/live/edits/${RID}`, { token: TOKEN, env: "production" })).status).toBe(404);
        expect((await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" }, {})).status).toBe(403);
        expect((await w.route("POST", `/live/edits/${rid}/push`, undefined, { "x-internal-key": "wrong" })).status).toBe(403);
        expect((await w.route("POST", `/live/edits/${rid}/push`, undefined, {})).status).toBe(403);
        expect((await w.route("GET", `/live/edits/${rid}`)).status).toBe(404);
    });

    it("without APNs a token is not stored and the answer says so", async () => {
        const w = await liveWorldReady({ configured: false });
        const rid = w.queueRender();
        const res = await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" });
        expect(await res.json()).toEqual({ status: "success", pushing: false, reason: "not_configured" });
        expect(await w.storage.get(`live:edit:${rid}`)).toBeUndefined();
    });

    it("DELETE forgets the token", async () => {
        const w = await liveWorldReady();
        const rid = w.queueRender();
        await w.route("PUT", `/live/edits/${rid}`, { token: TOKEN, env: "production" });
        expect((await w.route("DELETE", `/live/edits/${rid}`)).status).toBe(200);
        expect(await w.storage.get(`live:edit:${rid}`)).toBeUndefined();
    });
});
