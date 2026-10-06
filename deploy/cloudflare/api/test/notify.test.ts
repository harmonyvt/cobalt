// The Hark notification bridge (src/notify.ts, APP-API-CONTRACT.md section 9): the opt-in
// routes, the events fired by the real StudioService (client polls and the sweep), the
// exactly-once record, the bounded retries and what may reach a log.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KEY_ID_HEADER } from "../src/headers";
import {
    HARK_MAX_BODY,
    HARK_MAX_TITLE,
    NOTIFY_HTTP_MS,
    NOTIFY_MAX_TRIES,
    NOTIFY_PASS_MAX,
    NOTIFY_RETRY_DELAYS_MS,
    NOTIFY_TTL_MS,
    NotifyService,
    describeJob,
    failedMessage,
    handleNotifyRoute,
    harkConfigFrom,
    isNotifyRoute,
    parseOptIn,
    plainReason,
    renderedMessage,
    savedMessage,
    sessionUrl,
    type NotifyDeps,
} from "../src/notify";
import { StudioService } from "../src/studio";
import { runSweep, type SweepScheduler } from "../src/sweep";
import { WebpService } from "../src/webp";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";

const LINK = "https://www.instagram.com/p/Dd7P496wolG/";
const KEY_ID = "key-row-1";
const OTHER_KEY = "key-row-2";
// The webhook URL is a secret: tests look for these strings in every log line.
const SECRET_PATH = "T0pS3cretHookToken";
const HOOK = `https://hark.example/api/webhook/${SECRET_PATH}`;
const INTERNAL_KEY = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

type Call = { url: string; init: RequestInit; json: { title: string; body: string; url?: string } };

// A scriptable webhook: answers in order from `script` (then 200), recording every call.
class FakeHark {
    calls: Call[] = [];
    script: (number | "throw" | "hang")[] = [];
    fetch = async (url: string, init: RequestInit): Promise<Response> => {
        this.calls.push({ url, init, json: JSON.parse(String(init.body)) });
        const next = this.script.shift() ?? 200;
        if (next === "throw") throw new Error(`fetch failed for ${url}`);
        if (next === "hang") return new Promise<Response>(() => {});
        return new Response(next >= 200 && next < 300 ? '{"ok":true}' : '{"error":"x"}', { status: next });
    };
}

function wire(opts: { webhookUrl?: string | null; httpMs?: number; notifyMs?: number } = {}) {
    const db = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const helper = new FakeHelper();
    const hark = new FakeHark();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const armed: number[] = [];
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: "https://media.capybaraharmony.com/",
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        db,
    });
    const notify = new NotifyService({
        storage: kv,
        db,
        now: clock.now,
        webhookUrl: opts.webhookUrl === undefined ? HOOK : opts.webhookUrl,
        fetch: hark.fetch,
        scheduleSweep: () => {
            armed.push(clock.t);
        },
        httpMs: opts.httpMs,
    });
    const studio = new StudioService({
        db,
        storage: kv,
        originals,
        webp,
        webBaseUrl: "https://cobalt.capybaraharmony.com",
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        fixedLength,
        notify,
        notifyMs: opts.notifyMs,
    });
    const scheduled: number[] = [];
    const scheduler: SweepScheduler = {
        storage: kv,
        now: clock.now,
        schedule: async (s) => {
            scheduled.push(s);
        },
    };
    const sweep = () => runSweep(scheduler, () => studio.sweep(), undefined, undefined, notify);
    return { db, clock, kv, helper, hark, notify, studio, armed, scheduled, scheduler, sweep };
}
type W = ReturnType<typeof wire>;

const optIn = (w: W, sid: string, body: unknown = { on: ["saved", "rendered", "failed"] }, keyId = KEY_ID) =>
    w.notify.put(keyId, sid, JSON.stringify(body));

async function newSession(w: W): Promise<string> {
    return ((await w.studio.create(KEY_ID, JSON.stringify({ url: LINK }))).body as { id: string }).id;
}

// A session whose save is done (the poll that finishes it fires "saved" when opted in).
async function savedSession(w: W, optBody?: unknown): Promise<string> {
    const sid = await newSession(w);
    if (optBody !== null) await optIn(w, sid, optBody);
    w.clock.t += 2000;
    const r = (await w.studio.advance(sid, 0)).body as { status: string };
    expect(r.status).toBe("ready");
    return sid;
}

const startRender = async (w: W, sid: string, extra: Record<string, unknown> = {}) =>
    ((await w.studio.render(sid, JSON.stringify({ start: 2, length: 5, ...extra }))).body as { job: string }).job;

const noteKeys = (w: W) => [...w.kv.m.keys()].filter((k) => k.startsWith("notify:"));

let logs: string[];
beforeEach(() => {
    logs = [];
    for (const m of ["log", "info", "warn", "error", "debug"] as const) {
        vi.spyOn(console, m).mockImplementation((...a: unknown[]) => {
            logs.push(a.map(String).join(" "));
        });
    }
});
afterEach(() => vi.restoreAllMocks());

// ---- configuration ---------------------------------------------------------------------

describe("the bridge is off unless HARK_WEBHOOK_URL is a usable https URL", () => {
    it.each([
        [undefined, null],
        [null, null],
        ["", null],
        ["   ", null],
        ["not a url", null],
        ["http://hark.example/x", null],
        [42, null],
        [HOOK, HOOK],
        [`  ${HOOK}  `, HOOK],
    ])("%j -> %j", (v, want) => {
        expect(harkConfigFrom({ HARK_WEBHOOK_URL: v })).toBe(want);
    });
    it("nothing is stored or sent with the bridge off, whatever happens", async () => {
        for (const off of [null, ""]) {
            const w = wire({ webhookUrl: off });
            const sid = await newSession(w);
            const put = await optIn(w, sid);
            expect(put.body).toMatchObject({ status: "success", bridge: false, expires_at: null });
            w.clock.t += 2000;
            await w.studio.advance(sid, 0);
            const job = await startRender(w, sid, { notify: true });
            await w.studio.renderStatus(sid, job, 0);
            await w.sweep();
            expect(w.hark.calls).toHaveLength(0);
            expect(noteKeys(w)).toEqual([]);
            expect(w.notify.enabled()).toBe(false);
        }
    });
});

// ---- the opt-in routes -----------------------------------------------------------------

describe("PUT /studio/<sid>/notify", () => {
    it("stores the opt-in for 24 h and answers its shape", async () => {
        const w = wire();
        const sid = await newSession(w);
        const r = await optIn(w, sid, { on: ["saved", "failed"], label: "  x · 2105435404002562056  " });
        expect(r).toEqual({
            status: 200,
            body: { status: "success", bridge: true, on: ["saved", "failed"], label: "x · 2105435404002562056", expires_at: w.clock.t + NOTIFY_TTL_MS },
        });
        expect(NOTIFY_TTL_MS).toBe(24 * 60 * 60 * 1000);
        expect(w.kv.m.get(`notify:optin:${sid}`)).toMatchObject({ keyId: KEY_ID, on: ["saved", "failed"], label: "x · 2105435404002562056" });
    });
    it("is idempotent: a repeat replaces the opt-in, restarts the 24 h and sends nothing by itself", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid, { on: ["saved"] });
        w.clock.t += 3_600_000;
        const again = await optIn(w, sid, { on: ["saved", "saved", "rendered"] });
        expect(again.body).toMatchObject({ on: ["saved", "rendered"], label: null, expires_at: w.clock.t + NOTIFY_TTL_MS });
        expect(noteKeys(w)).toEqual([`notify:optin:${sid}`]);
        expect(w.hark.calls).toHaveLength(0);
    });
    it.each([
        ["not json", "nope"],
        ["an array", []],
        ["no `on`", {}],
        ["empty `on`", { on: [] }],
        ["`on` not an array", { on: "saved" }],
        ["an unknown event", { on: ["saved", "deleted"] }],
        ["a non-string event", { on: [1] }],
        ["too many events", { on: Array(9).fill("saved") }],
        ["a non-string label", { on: ["saved"], label: 7 }],
        ["a 61-character label", { on: ["saved"], label: "a".repeat(61) }],
        ["a label with a control character", { on: ["saved"], label: "a\nb" }],
    ])("400 error.notify.invalid for %s", async (_n, body) => {
        const w = wire();
        const sid = await newSession(w);
        const r = await w.notify.put(KEY_ID, sid, typeof body === "string" ? body : JSON.stringify(body));
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.notify.invalid" } } });
        expect(noteKeys(w)).toEqual([]);
    });
    it("accepts a 60-character label (counted in characters, not bytes), an empty one is none", async () => {
        const w = wire();
        const sid = await newSession(w);
        expect((await optIn(w, sid, { on: ["saved"], label: "é".repeat(60) })).status).toBe(200);
        expect((await optIn(w, sid, { on: ["saved"], label: "   " })).body).toMatchObject({ label: null });
        expect((await optIn(w, sid, { on: ["saved"], label: null })).body).toMatchObject({ label: null });
    });
    it("only the session's owner: another key and an unknown session are the same 404", async () => {
        const w = wire();
        const sid = await newSession(w);
        const other = await optIn(w, sid, undefined, OTHER_KEY);
        const unknown = await optIn(w, "Z".repeat(22));
        expect(other).toEqual({ status: 404, body: { status: "error", error: { code: "error.studio.not_found" } } });
        expect(unknown).toEqual(other);
        expect(noteKeys(w)).toEqual([]);
    });
    it("D1 down: 503, nothing stored", async () => {
        const w = wire();
        const sid = await newSession(w);
        w.db.breakIt();
        expect((await optIn(w, sid)).status).toBe(503);
        expect(noteKeys(w)).toEqual([]);
    });
    it("validates before it looks at D1 (a bad body never costs a query)", async () => {
        const w = wire();
        const sid = await newSession(w);
        w.db.breakIt();
        expect((await w.notify.put(KEY_ID, sid, "{}")).status).toBe(400);
    });
});

describe("DELETE /studio/<sid>/notify", () => {
    it("removes the opt-in and the render-only ones; idempotent", async () => {
        const w = wire();
        const sid = await savedSession(w);
        const job = await startRender(w, sid, { notify: true });
        expect(noteKeys(w).some((k) => k.startsWith(`notify:job:${sid}:`))).toBe(true);
        expect(await w.notify.remove(KEY_ID, sid)).toEqual({ status: 204, body: null });
        expect(await w.notify.remove(KEY_ID, sid)).toEqual({ status: 204, body: null });
        expect(noteKeys(w).filter((k) => k.startsWith("notify:optin:") || k.startsWith("notify:job:"))).toEqual([]);
        // the render then finishes: nobody is told
        w.hark.calls.length = 0;
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(0);
    });
    it("only the owner: another key gets a 404 and the opt-in stays", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        expect((await w.notify.remove(OTHER_KEY, sid)).status).toBe(404);
        expect(w.kv.m.has(`notify:optin:${sid}`)).toBe(true);
        expect((await w.notify.remove(KEY_ID, "Z".repeat(22))).status).toBe(404);
    });
    it("cancels an event waiting for a retry, and its marker keeps it from ever being sent", async () => {
        const w = wire();
        w.hark.script = [503];
        await savedSession(w); // "saved" fails once: pending retry
        const sid = [...w.kv.m.keys()].find((k) => k.startsWith("notify:optin:"))!.slice("notify:optin:".length);
        expect(w.hark.calls).toHaveLength(1);
        await w.notify.remove(KEY_ID, sid);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "cancelled" });
        w.clock.t += 60_000;
        await w.sweep();
        await optIn(w, sid); // opting in again does not revive it
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
    });
});

describe("the route inside the Durable Object", () => {
    const sidOf = (w: W) => newSession(w);
    const req = (sid: string, method: string, body?: string, headers: Record<string, string> = { [KEY_ID_HEADER]: KEY_ID }) =>
        new Request(`https://do.internal/studio/${sid}/notify`, { method, headers, body });

    it("isNotifyRoute matches only /studio/<22 base62>/notify", () => {
        const sid = "a".repeat(22);
        expect(isNotifyRoute(`/studio/${sid}/notify`)).toBe(true);
        for (const p of [`/studio/${sid}`, `/studio/${sid}/notify/x`, `/studio/${sid}/render`, `/studio/short/notify`, `/studio/${sid}/notify/`, "/studio/notify"]) {
            expect(isNotifyRoute(p), p).toBe(false);
        }
    });
    it("without the key id header: 403 (the Worker is the only caller)", async () => {
        const w = wire();
        const sid = await sidOf(w);
        expect((await handleNotifyRoute(w.notify, req(sid, "PUT", '{"on":["saved"]}', {}))).status).toBe(403);
        expect((await handleNotifyRoute(w.notify, req(sid, "DELETE", undefined, {}))).status).toBe(403);
    });
    it("PUT answers 200 JSON, DELETE 204 with no body, other methods 404", async () => {
        const w = wire();
        const sid = await sidOf(w);
        const put = await handleNotifyRoute(w.notify, req(sid, "PUT", '{"on":["saved"],"label":"x"}'));
        expect(put.status).toBe(200);
        expect(put.headers.get("content-type")).toBe("application/json");
        expect(await put.json()).toMatchObject({ status: "success", bridge: true, on: ["saved"], label: "x" });
        const del = await handleNotifyRoute(w.notify, req(sid, "DELETE"));
        expect(del.status).toBe(204);
        expect(await del.text()).toBe("");
        expect((await handleNotifyRoute(w.notify, req(sid, "POST", "{}"))).status).toBe(404);
        expect((await handleNotifyRoute(w.notify, req(sid, "PATCH", "{}"))).status).toBe(404);
    });
    it("a body over 1 KB is a 400, declared or not", async () => {
        const w = wire();
        const sid = await sidOf(w);
        const big = JSON.stringify({ on: ["saved"], label: "x", pad: "p".repeat(1100) });
        const r = await handleNotifyRoute(w.notify, req(sid, "PUT", big));
        expect(r.status).toBe(400);
        expect(((await r.json()) as any).error.code).toBe("error.notify.invalid");
        const declared = new Request(`https://do.internal/studio/${sid}/notify`, {
            method: "PUT",
            headers: { [KEY_ID_HEADER]: KEY_ID, "content-length": "5000" },
            body: "{}",
        });
        expect((await handleNotifyRoute(w.notify, declared)).status).toBe(400);
    });
});

describe("parseOptIn", () => {
    it("keeps the events in order without repeats", () => {
        expect(parseOptIn('{"on":["failed","saved","failed"]}')).toEqual({ on: ["failed", "saved"], label: null });
    });
});

// ---- the events ------------------------------------------------------------------------

describe("saved", () => {
    it("fires once when the save becomes ready, with the pinned copy", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["saved"], label: "x · 2105435404002562056" });
        expect(w.hark.calls).toHaveLength(1);
        const c = w.hark.calls[0]!;
        expect(c.url).toBe(HOOK);
        expect(c.init.method).toBe("POST");
        expect((c.init.headers as Record<string, string>)["content-type"]).toBe("application/json");
        expect(c.json).toEqual({
            title: "cobalt",
            body: "x · 2105435404002562056 is saved · 9.6 s — open cobalt to make a webp",
            url: `cobalt-apple://session/${sid}`,
        });
        expect(c.init.redirect).toBe("manual");
    });
    it("without a label it names the job by service and ref", async () => {
        const w = wire();
        await savedSession(w);
        expect(w.hark.calls[0]!.json.body).toBe("instagram · Dd7P496wolG is saved · 9.6 s — open cobalt to make a webp");
    });
    it("a client poll and the sweep racing for the same session send one message", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        w.clock.t += 2000;
        await Promise.all([w.studio.advance(sid, 0), w.studio.advance(sid, 0), w.sweep(), w.studio.advance(sid, 0)]);
        expect(w.hark.calls.filter((c) => c.json.body.includes("is saved"))).toHaveLength(1);
        // and later polls / sweeps stay quiet
        await w.studio.advance(sid, 0);
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
    });
    it("the event itself is exactly-once even when callers reach it at the same moment (first send in flight)", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid, { on: ["saved"] });
        await Promise.all([w.notify.onSaved(sid), w.notify.onSaved(sid), w.notify.onSaved(sid), w.notify.retryDue(w.clock.t)]);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "sent", tries: 1 });
        await Promise.all([w.notify.onSaved(sid), w.notify.onSaved(sid)]);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("a render's success reached by two callers at once, before any record exists, is one message", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["rendered"] });
        w.hark.calls.length = 0;
        const e = { kind: "success" as const, url: "https://media.capybaraharmony.com/aaaaaaaaaa.webp", bytes: 1500, width: 480, height: 560 };
        await Promise.all([w.notify.onRender(sid, "J".repeat(20), e), w.notify.onRender(sid, "J".repeat(20), e)]);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("the sweep alone finishes the save and tells the owner (nobody polling)", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        w.clock.t += 2000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toContain("is saved");
        expect(sid).toBeTruthy();
    });
    it("no opt-in, no message", async () => {
        const w = wire();
        await savedSession(w, null);
        expect(w.hark.calls).toHaveLength(0);
        expect(noteKeys(w)).toEqual([]);
    });
    it("an opt-in that does not list the event stays quiet for it", async () => {
        const w = wire();
        await savedSession(w, { on: ["rendered", "failed"] });
        expect(w.hark.calls).toHaveLength(0);
    });
    it("an expired opt-in (24 h) stays quiet; a fresh PUT revives it", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        w.clock.t += NOTIFY_TTL_MS + 1;
        // the helper's fetch outlives the poll budget in a fake clock: the session is still saving
        await w.notify.onSaved(sid);
        expect(w.hark.calls).toHaveLength(0);
        await optIn(w, sid);
        await w.notify.onSaved(sid);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("the TTL is exactly 24 h: just inside still fires", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        w.clock.t += NOTIFY_TTL_MS - 1;
        await w.notify.onSaved(sid);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("a stored opt-in is dropped by the sweep once expired", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid);
        w.clock.t += NOTIFY_TTL_MS + 1;
        await w.notify.retryDue(w.clock.t);
        expect(w.kv.m.has(`notify:optin:${sid}`)).toBe(false);
    });
    it("a duration of 5 reads '5 s', a missing one is left out", () => {
        expect(savedMessage("x", 5).body).toBe("x is saved · 5 s — open cobalt to make a webp");
        expect(savedMessage("x", null).body).toBe("x is saved — open cobalt to make a webp");
        expect(savedMessage("x", 0).body).toBe("x is saved — open cobalt to make a webp");
        expect(savedMessage("x", 12.34).body).toBe("x is saved · 12.3 s — open cobalt to make a webp");
    });
});

describe("rendered", () => {
    it("fires once with size, dimensions and the webp URL; polls and the sweep racing send one message", async () => {
        const w = wire();
        const sid = await savedSession(w);
        w.hark.calls.length = 0;
        const job = await startRender(w, sid);
        w.clock.t += 2000;
        const [a, b] = await Promise.all([w.studio.renderStatus(sid, job, 0), w.studio.renderStatus(sid, job, 0)]);
        await w.sweep();
        const done = a.body as { status: string; url: string };
        expect(done.status).toBe("success");
        expect(b.body).toMatchObject({ status: "success", url: done.url });
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json).toEqual({
            title: "cobalt",
            body: `webp ready · 480×560 · 2 KB\n${done.url}`,
            url: `cobalt-apple://session/${sid}`,
        });
        // a later poll of the finished job is quiet too
        await w.studio.renderStatus(sid, job, 0);
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
    });
    it("the sweep alone collects a render and tells the owner", async () => {
        const w = wire();
        const sid = await savedSession(w);
        w.hark.calls.length = 0;
        await startRender(w, sid);
        w.clock.t += 2000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toMatch(/^webp ready · 480×560 · 2 KB\nhttps:\/\/media\.capybaraharmony\.com\/\w{10}\.webp$/);
    });
    it("every render job is its own event", async () => {
        const w = wire();
        const sid = await savedSession(w);
        w.hark.calls.length = 0;
        // one at a time (the helper is held until a render's result is collected, section 17.2)
        const j1 = await startRender(w, sid);
        await w.studio.renderStatus(sid, j1, 0);
        const j2 = await startRender(w, sid, { start: 1 });
        await w.studio.renderStatus(sid, j2, 0);
        expect(w.hark.calls).toHaveLength(2);
    });
    it("an opt-in without 'rendered' stays quiet", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["saved"] });
        w.hark.calls.length = 0;
        const job = await startRender(w, sid);
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(0);
    });
    it("no opt-in at all: nothing, and nothing stored", async () => {
        const w = wire();
        const sid = await savedSession(w, null);
        const job = await startRender(w, sid);
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(0);
        expect(noteKeys(w)).toEqual([]);
    });
});

describe('"notify": true on POST /studio/<sid>/render (render-only opt-in)', () => {
    it("notifies for that render only, with no session opt-in, and not for the save", async () => {
        const w = wire();
        const sid = await savedSession(w, null);
        expect(w.hark.calls).toHaveLength(0);
        const withNotify = await startRender(w, sid, { notify: true });
        const without = await startRender(w, sid, { start: 1 });
        await w.studio.renderStatus(sid, without, 0);
        expect(w.hark.calls).toHaveLength(0);
        await w.studio.renderStatus(sid, withNotify, 0);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toContain("webp ready");
    });
    it("also tells about that render's failure", async () => {
        const w = wire();
        const sid = await savedSession(w, null);
        w.helper.jobError = "error.webp.encode_failed";
        const job = await startRender(w, sid, { notify: true });
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json).toEqual({
            title: "cobalt couldn't finish",
            body: "couldn't make the webp — something went wrong on the server",
            url: `cobalt-apple://session/${sid}`,
        });
    });
    it("covers a render the session opt-in does not (on: saved only)", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["saved"] });
        w.hark.calls.length = 0;
        const job = await startRender(w, sid, { notify: true });
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("`notify: false` is no opt-in; a non-boolean is a 400 and starts nothing", async () => {
        const w = wire();
        const sid = await savedSession(w, null);
        const job = await startRender(w, sid, { notify: false });
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(0);
        const posts = w.helper.calls.length;
        for (const bad of ["yes", 1, null, {}]) {
            const r = await w.studio.render(sid, JSON.stringify({ start: 2, length: 5, notify: bad }));
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        }
        expect(w.helper.calls.length).toBe(posts);
    });
    it("an expired render-only opt-in stays quiet", async () => {
        const w = wire();
        const sid = await savedSession(w, null);
        const job = await startRender(w, sid, { notify: true });
        w.clock.t += NOTIFY_TTL_MS + 1;
        await w.notify.onRender(sid, job, { kind: "success", url: "https://m/x.webp", bytes: 1, width: 1, height: 1 });
        expect(w.hark.calls).toHaveLength(0);
    });
});

describe("failed", () => {
    it("a save that fails fires once, with a short plain reason", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid, { on: ["failed"] });
        w.helper.fetchError = "error.api.fetch.empty";
        w.clock.t += 2000;
        const r = (await w.studio.advance(sid, 0)).body as { status: string };
        expect(r.status).toBe("error");
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json).toEqual({
            title: "cobalt couldn't finish",
            body: "couldn't save instagram · Dd7P496wolG — the link could not be fetched",
            url: `cobalt-apple://session/${sid}`,
        });
        await w.studio.advance(sid, 0);
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
    });
    it("a lost save (nobody polled for 10 minutes) is reported by the next look", async () => {
        const w = wire();
        const sid = await newSession(w);
        await optIn(w, sid, { on: ["failed"], label: "my clip" });
        w.helper.fetchGone = true;
        w.clock.t += 2000;
        for (let i = 0; i < 12 && w.hark.calls.length === 0; i++) {
            w.clock.t += 5000;
            await w.studio.advance(sid, 0);
        }
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toMatch(/^couldn't save my clip — /);
    });
    it("a render that fails fires once, not for 'rendered'-only opt-ins", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["failed"] });
        w.helper.jobError = "error.webp.encode_failed";
        const job = await startRender(w, sid);
        await Promise.all([w.studio.renderStatus(sid, job, 0), w.studio.renderStatus(sid, job, 0)]);
        await w.sweep();
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toBe("couldn't make the webp — something went wrong on the server");

        const w2 = wire();
        const sid2 = await savedSession(w2, { on: ["saved", "rendered"] });
        w2.helper.jobError = "error.webp.encode_failed";
        w2.hark.calls.length = 0;
        const job2 = await startRender(w2, sid2);
        await w2.studio.renderStatus(sid2, job2, 0);
        expect(w2.hark.calls).toHaveLength(0);
    });
    it("a lost render job (the helper forgot it) is a failure too", async () => {
        const w = wire();
        const sid = await savedSession(w, { on: ["failed"] });
        w.helper.jobsGone = true;
        const job = await startRender(w, sid);
        await w.studio.renderStatus(sid, job, 0);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0]!.json.body).toBe("couldn't make the webp — the server lost track of the job");
    });
    it("plainReason covers the codes the app knows, and falls back to a generic line", () => {
        expect(plainReason("error.api.fetch.fail")).toBe("the link could not be fetched");
        expect(plainReason("error.api.content.video.unavailable")).toBe("the link could not be fetched");
        expect(plainReason("error.webp.busy")).toBe("the server was busy");
        expect(plainReason("error.studio.too_large")).toBe("the video is too large");
        expect(plainReason("error.studio.not_video")).toBe("that kind of video is not supported");
        expect(plainReason("error.something.new")).toBe("something went wrong on the server");
        for (const c of ["error.studio.storage", "error.studio.unavailable", "error.studio.expired", "error.webp.too_long"]) {
            expect(plainReason(c).length).toBeGreaterThan(5);
        }
    });
});

// ---- the webhook call: retries, timeouts, limits ------------------------------------------

describe("retries (5xx, network, timeout) go through the sweep, at most twice; a 4xx never", () => {
    const failing = async (script: (number | "throw" | "hang")[], opts: Parameters<typeof wire>[0] = {}) => {
        const w = wire(opts);
        w.hark.script = [...script];
        const sid = await savedSession(w, { on: ["saved"] });
        return { w, sid };
    };

    it("503 then 503 then 200: three sends in all, 5 s and 20 s apart, then done", async () => {
        const { w, sid } = await failing([503, 503, 200]);
        expect(NOTIFY_RETRY_DELAYS_MS).toEqual([5_000, 20_000]);
        expect(NOTIFY_MAX_TRIES).toBe(3);
        const t0 = w.clock.t;
        expect(w.hark.calls).toHaveLength(1);
        expect(w.armed.length).toBeGreaterThan(0); // the failure armed the sweep
        // a poll inside the backoff does not re-send; nor does a sweep
        w.clock.t = t0 + 4_999;
        await w.notify.onSaved(sid);
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
        // due: the sweep sends the first retry
        w.clock.t = t0 + 5_000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(2);
        w.clock.t = t0 + 5_000 + 19_999;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(2);
        w.clock.t = t0 + 5_000 + 20_000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(3);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "sent", tries: 3 });
        // the same message each time
        expect(new Set(w.hark.calls.map((c) => JSON.stringify(c.json))).size).toBe(1);
        w.clock.t += 600_000;
        await w.sweep();
        await w.notify.onSaved(sid);
        expect(w.hark.calls).toHaveLength(3);
    });
    it("503 forever: exactly three sends, then it gives up for good", async () => {
        const { w, sid } = await failing([503, 503, 503, 503, 503]);
        for (let i = 0; i < 20; i++) {
            w.clock.t += 6_000;
            await w.sweep();
            await w.notify.onSaved(sid);
        }
        expect(w.hark.calls).toHaveLength(3);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "gave_up", tries: 3 });
        // nothing pending: the sweep is not re-armed for it
        w.scheduled.length = 0;
        await w.sweep();
        expect(w.scheduled).toEqual([]);
    });
    it("a network error and a timeout count as failures to retry", async () => {
        const { w } = await failing(["throw", "hang", 200], { httpMs: 25 });
        expect(w.hark.calls).toHaveLength(1);
        w.clock.t += 5_000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(2); // the hang was cut off by our own ceiling
        w.clock.t += 20_000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(3);
        expect(logs.some((l) => /hark failed network sid=/.test(l))).toBe(true);
        expect(logs.some((l) => /hark failed timeout sid=/.test(l))).toBe(true);
        expect(logs.some((l) => /hark sent 200 sid=/.test(l))).toBe(true);
    });
    it.each([400, 401, 403, 404, 410, 422, 429])("a %i is final: one send, no retry", async (status) => {
        const { w, sid } = await failing([status, 200, 200]);
        for (let i = 0; i < 5; i++) {
            w.clock.t += 30_000;
            await w.sweep();
            await w.notify.onSaved(sid);
        }
        expect(w.hark.calls).toHaveLength(1);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "rejected" });
        expect(logs.some((l) => l.includes(`hark failed ${status} sid=`))).toBe(true);
    });
    it("a redirect is not followed and not retried", async () => {
        const { w } = await failing([302, 200]);
        w.clock.t += 30_000;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(1);
    });
    it("the call is cut off after our own 3 s ceiling and the poll is not held longer", async () => {
        expect(NOTIFY_HTTP_MS).toBe(3000);
        const w = wire({ httpMs: 30 });
        w.hark.script = ["hang"];
        const sid = await newSession(w);
        await optIn(w, sid);
        const t = Date.now();
        await w.notify.onSaved(sid);
        expect(Date.now() - t).toBeLessThan(1000);
        expect(w.hark.calls).toHaveLength(1);
    });
    it("a hook that hangs or throws never fails or stalls the studio poll", async () => {
        const w = wire({ notifyMs: 30 });
        const sid = await newSession(w);
        w.clock.t += 2000;
        const studio = new StudioService({
            db: w.db,
            storage: w.kv,
            originals: new MemoryOriginals(),
            webp: new WebpService({
                storage: w.kv,
                bucket: new MemoryMedia(),
                mediaBaseUrl: "https://media.capybaraharmony.com/",
                now: w.clock.now,
                sleep: w.clock.sleep,
                ensureRunning: async () => {},
                helper: w.helper.helper,
                db: w.db,
            }),
            webBaseUrl: "https://cobalt.capybaraharmony.com",
            now: w.clock.now,
            sleep: w.clock.sleep,
            ensureRunning: async () => {},
            helper: w.helper.helper,
            fixedLength,
            notifyMs: 30,
            notify: {
                onSaved: () => new Promise<void>(() => {}),
                onSaveFailed: async () => {
                    throw new Error(`boom ${HOOK}`);
                },
                onRender: async () => {
                    throw new Error("boom");
                },
                optInJob: () => new Promise<void>(() => {}),
                onLineSettle: async () => {},
            },
        });
        const t = Date.now();
        const r = (await studio.advance(sid, 0)).body as { status: string };
        expect(r.status).toBe("ready");
        expect(Date.now() - t).toBeLessThan(1000);
        const job = ((await studio.render(sid, JSON.stringify({ start: 2, length: 5, notify: true }))).body as { job: string }).job;
        expect(await studio.renderStatus(sid, job, 0)).toMatchObject({ status: 200 });
        // a hook's own error text never reaches a log
        expect(logs.join("\n")).not.toContain(SECRET_PATH);
    });
    it("a crashed final send (record written, never finished) is closed, not sent a fourth time", async () => {
        const w = wire();
        const sid = await newSession(w);
        w.kv.m.set(`notify:ev:${sid}:saved`, { sid, title: "cobalt", body: "x", tries: 3, retryAt: null, done: false, expiresAt: w.clock.t + 1e9 });
        w.clock.t += 1000;
        const r = await w.notify.retryDue(w.clock.t);
        expect(r).toEqual({ nextInMs: null });
        expect(w.hark.calls).toHaveLength(0);
        expect(w.kv.m.get(`notify:ev:${sid}:saved`)).toMatchObject({ done: true, outcome: "gave_up" });
    });
    it("a sweep pass sends at most NOTIFY_PASS_MAX due retries and says the rest are due now", async () => {
        const w = wire();
        const sids: string[] = [];
        for (let i = 0; i < NOTIFY_PASS_MAX + 2; i++) {
            const sid = `${"Q".repeat(21)}${i}`;
            sids.push(sid);
            w.kv.m.set(`notify:ev:${sid}:saved`, { sid, title: "cobalt", body: "x", tries: 1, retryAt: w.clock.t - 1, done: false, expiresAt: w.clock.t + 1e9 });
        }
        const r = await w.notify.retryDue(w.clock.t);
        expect(w.hark.calls).toHaveLength(NOTIFY_PASS_MAX);
        expect(r.nextInMs).not.toBeNull();
        expect(r.nextInMs!).toBeLessThanOrEqual(5_000); // the rest, due now, or the next backoff
    });
});

describe("the sweep re-arms for a pending notification retry", () => {
    it("with nothing else pending, the failed send's retry is what keeps the sweep going", async () => {
        const w = wire();
        w.hark.script = [503, 200];
        await savedSession(w, { on: ["saved"] });
        w.scheduled.length = 0;
        w.clock.t += 1_000;
        await w.sweep();
        // nothing due yet (retry in 5 s): the next pass is scheduled, 4 s -> within the 5 s cadence
        expect(w.scheduled).toHaveLength(1);
        expect(w.scheduled[0]).toBeLessThanOrEqual(5);
        expect(w.scheduled[0]).toBeGreaterThanOrEqual(1);
        w.clock.t += 5_000;
        w.scheduled.length = 0;
        await w.sweep();
        expect(w.hark.calls).toHaveLength(2);
        expect(w.scheduled).toEqual([]); // sent: nothing left, the sweep goes quiet
    });
});

// ---- payload limits ----------------------------------------------------------------------

describe("payload shape and limits", () => {
    it("every message has a non-empty title of at most 80 characters and a body of at most 2000", () => {
        const long = "x".repeat(5000);
        const msgs = [
            savedMessage(long, 3),
            renderedMessage({ url: `https://m.example/${long}`, bytes: 10, width: 1, height: 1 }),
            failedMessage("saving", long, "error.x"),
            failedMessage("rendering", long, "error.x"),
        ];
        for (const m of msgs) {
            expect(m.title.length).toBeGreaterThan(0);
            expect(m.title.length).toBeLessThanOrEqual(HARK_MAX_TITLE);
            expect([...m.body].length).toBeLessThanOrEqual(HARK_MAX_BODY);
        }
        expect([...msgs[0]!.body].length).toBe(HARK_MAX_BODY);
        expect(msgs[0]!.body.endsWith("…")).toBe(true);
    });
    it("clips by characters, never through a surrogate pair", () => {
        const m = savedMessage("🎬".repeat(3000), null);
        expect([...m.body].length).toBe(HARK_MAX_BODY);
        expect(m.body).not.toMatch(/[\ud800-\udbff](?![\udc00-\udfff])/);
    });
    it("what is sent is exactly {title, body, url} as JSON, nothing else", async () => {
        const w = wire();
        const sid = await savedSession(w);
        const sent = JSON.parse(String(w.hark.calls[0]!.init.body));
        expect(Object.keys(sent).sort()).toEqual(["body", "title", "url"]);
        expect(sent.url).toBe(`cobalt-apple://session/${sid}`);
        expect(Object.keys(w.hark.calls[0]!.init.headers as object)).toEqual(["content-type"]);
    });
    it("every message that has a session carries the app link: saved, save failed, rendered, render failed, and a retried send", async () => {
        const link = (sid: string) => `cobalt-apple://session/${sid}`;
        // saved + rendered
        const a = wire();
        const sidA = await savedSession(a);
        const jobA = await startRender(a, sidA);
        await a.studio.renderStatus(sidA, jobA, 0);
        expect(a.hark.calls.map((c) => c.json.url)).toEqual([link(sidA), link(sidA)]);
        // save failed
        const b = wire();
        const sidB = await newSession(b);
        await optIn(b, sidB, { on: ["failed"] });
        b.helper.fetchError = "error.api.fetch.empty";
        b.clock.t += 2000;
        await b.studio.advance(sidB, 0);
        expect(b.hark.calls.map((c) => c.json.url)).toEqual([link(sidB)]);
        // render failed
        const c = wire();
        const sidC = await savedSession(c, null);
        c.helper.jobError = "error.webp.encode_failed";
        const jobC = await startRender(c, sidC, { notify: true });
        await c.studio.renderStatus(sidC, jobC, 0);
        expect(c.hark.calls.map((x) => x.json.url)).toEqual([link(sidC)]);
        // a send retried by the sweep keeps the link
        const d = wire();
        d.hark.script = [503];
        const sidD = await savedSession(d, { on: ["saved"] });
        d.clock.t += 6000;
        await d.sweep();
        expect(d.hark.calls).toHaveLength(2);
        expect(d.hark.calls.map((x) => x.json.url)).toEqual([link(sidD), link(sidD)]);
    });
    it("the link is only the session id: never the webhook URL, a key, or the key id", async () => {
        const w = wire();
        const sid = await savedSession(w);
        const url = w.hark.calls[0]!.json.url!;
        expect(url).toMatch(/^cobalt-apple:\/\/session\/[A-Za-z0-9]+$/);
        for (const secret of [SECRET_PATH, "hark.example", HOOK, INTERNAL_KEY, KEY_ID]) {
            expect(url, secret).not.toContain(secret);
        }
        expect(url).toBe(sessionUrl(sid));
    });
    it("describeJob: label first, then service · ref, then the title", () => {
        expect(describeJob("mine", null)).toBe("mine");
        expect(describeJob(null, { service: "x", link: "https://x.com/u/status/2105435404002562056", title: "t" })).toBe("x · 2105435404002562056");
        expect(describeJob(null, { service: null, link: LINK, title: null })).toBe("instagram · Dd7P496wolG");
        expect(describeJob(null, { service: "unknown", link: null, title: "a title" })).toBe("a title");
        expect(describeJob(null, null)).toBe("your video");
        expect(describeJob(null, { service: "x", link: "upload:abc", title: null })).toBe("x");
    });
    it("renderedMessage leaves out what it does not know", () => {
        expect(renderedMessage({ url: "https://m/a.webp", bytes: null, width: null, height: null }).body).toBe("webp ready\nhttps://m/a.webp");
        expect(renderedMessage({ url: "https://m/a.webp", bytes: 841_000, width: 480, height: 270 }).body).toBe("webp ready · 480×270 · 841 KB\nhttps://m/a.webp");
    });
});

// ---- logs ----------------------------------------------------------------------------------

describe("nothing secret reaches a log", () => {
    it("neither the webhook URL, nor the API keys, nor a message, across sends, failures, throws and timeouts", async () => {
        const w = wire({ httpMs: 25 });
        w.hark.script = [503, "throw", 200, 400, "hang", 200];
        const sid = await savedSession(w, { on: ["saved", "rendered", "failed"], label: "private label" });
        for (let i = 0; i < 4; i++) {
            w.clock.t += 21_000;
            await w.sweep();
        }
        const job = await startRender(w, sid);
        await w.studio.renderStatus(sid, job, 0);
        await w.notify.remove(KEY_ID, sid);
        const all = logs.join("\n");
        expect(logs.length).toBeGreaterThan(0);
        for (const secret of [SECRET_PATH, "hark.example", HOOK, INTERNAL_KEY, KEY_ID, "private label", "is saved", "webp ready", "instagram"]) {
            expect(all, secret).not.toContain(secret);
        }
        // only these lines, with a session id prefix
        const harkLines = logs.filter((l) => l.includes("hark"));
        expect(harkLines.length).toBeGreaterThan(0);
        for (const l of harkLines) {
            expect(l).toMatch(/^\[notify\] hark (sent|failed) (\d{3}|network|timeout) sid=[A-Za-z0-9]{8}$/);
        }
        void sid;
    });
});
