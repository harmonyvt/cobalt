// src/live.ts (APP-API-CONTRACT.md 8.2 and 8.3): registration, the token and run
// store, the merge and coalesce rule, the payloads, the relay, the cleanup and the
// parity with the app's fixture. Apple is a script, time is a virtual clock, D1 is
// real SQLite and DO storage a map.
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import { KEY_ID_HEADER } from "../src/headers";
import {
    DEVICE_STAGES,
    LIVE_END_RETRY_DELAYS_MS,
    LIVE_ENDED_TTL_MS,
    LIVE_MAX_OPEN_RUNS_PER_KEY,
    LIVE_MAX_RUNS_PER_KEY,
    LIVE_MAX_RUNS_PER_SID,
    LIVE_RUN_TTL_MS,
    LIVE_START_MIN_GAP_MS,
    LIVE_START_TOKEN_TTL_MS,
    LiveService,
    endPayload,
    failureKey,
    formatBytes,
    handleLiveRoute,
    nextState,
    sameState,
    sanitizeState,
    startPayload,
    stateEventOfRender,
    stateEventOfSave,
    updatePayload,
    type LiveState,
    type RunIndexEntry,
    type RunRecord,
    type StartToken,
} from "../src/live";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Apple, bad, makePem, ok, type AppleStep } from "./apns-fakes";
import { Clock, MemoryKV } from "./studio-fakes";

const FIX = JSON.parse(readFileSync(new URL("./fixtures/live-states.json", import.meta.url), "utf8")) as Record<string, LiveState>;

const KEY = "key-row-1";
const OTHER = "key-row-2";
const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const RUN2 = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
const SID_OTHER = "zY9xW8vU7tS6rQ5pO4nMlK";
const UPDATE = "cd".repeat(32);
const START = "ef".repeat(32);
const T0 = 1_790_000_000_000;
const s0 = Math.floor(T0 / 1000);

let pem: string;
beforeAll(async () => {
    pem = await makePem();
});

const ATTRS = { run: RUN, input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "app" };
const FETCHING: LiveState = { stage: "fetching", rail: 0, since: s0, waking: false, packing: false };

const reg = (over: Record<string, unknown> = {}) => ({
    environment: "sandbox",
    update_token: null,
    session: null,
    start: false,
    attributes: ATTRS,
    state: FETCHING,
    ...over,
});

async function world(opts: { apple?: Apple; configured?: boolean; via?: "worker" | "helper" } = {}) {
    const clock = new Clock();
    clock.t = T0;
    const kv = new MemoryKV();
    const db: FakeD1 = createFakeD1();
    const seed = (id: string, keyId: string) =>
        db.raw
            .prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?, ?, ?, ?, 'saving', ?, ?)")
            .run(id, keyId, "https://www.instagram.com/p/Dd7P496wolG/", "instagram", T0, T0 + 1e9);
    seed(SID, KEY);
    seed(SID_OTHER, OTHER);
    const apple = opts.apple ?? new Apple();
    const apns =
        opts.configured === false
            ? null
            : new ApnsClient({
                  keyP8: pem,
                  keyId: "ABC123DEFG",
                  teamId: "TEAM123456",
                  bundleId: "com.capybaraharmony.cobalt",
                  via: opts.via ?? "worker",
                  transport: apple.transport,
                  now: clock.now,
                  log: () => {},
              });
    const sweeps: number[] = [];
    const live = new LiveService({ storage: kv, db, now: clock.now, apns, scheduleSweep: async () => void sweeps.push(clock.t) });
    const w = {
        clock,
        kv,
        db,
        apple,
        live,
        sweeps,
        put: (over: Record<string, unknown> = {}, run = RUN, key = KEY) =>
            live.putRun(key, run, JSON.stringify(reg({ attributes: { ...ATTRS, run }, ...over }))),
        relay: (state: unknown, run = RUN, key = KEY) => live.relayState(key, run, JSON.stringify({ state })),
        run: (run = RUN) => kv.m.get(`live:run:${run}`) as RunRecord | undefined,
        startToken: (key = KEY) => kv.m.get(`live:start:${key}`) as StartToken | undefined,
        // the small per-run index entry (the cleanup, hasActiveRuns and the caps read it)
        idx: (run = RUN, key = KEY) => kv.m.get(`live:idx:${key}:${run}`) as RunIndexEntry | undefined,
        // changes a run's age in the record and in its index entry (the cleanup is index-driven)
        age: (patch: { createdAt?: number; endedAt?: number | null }, run = RUN, key = KEY) => {
            Object.assign(kv.m.get(`live:run:${run}`) as object, patch);
            Object.assign(kv.m.get(`live:idx:${key}:${run}`) as object, patch);
        },
        // a run with an update token already registered, sent = FETCHING; Apple has seen the catch-up push
        armed: async (over: Record<string, unknown> = {}) => {
            const r = await w.put({ update_token: UPDATE, session: SID, ...over });
            expect(r.status).toBe(200);
            apple.calls.length = 0;
        },
        tick: (ms: number) => {
            clock.t += ms;
        },
    };
    return w;
}
type World = Awaited<ReturnType<typeof world>>;

const saving = (bytes: number, total = 4331778) => ({ kind: "progress" as const, progress: { step: "storing" as const, bytes, total, waking: false } });

describe("registration (PUT /live/runs/<run>)", () => {
    const cases: [string, Record<string, unknown>][] = [
        ["environment missing", { environment: undefined }],
        ["environment not sandbox|production", { environment: "prod" }],
        ["update_token not hex", { update_token: "xyz" }],
        ["update_token uppercase", { update_token: "AB".repeat(32) }],
        ["update_token too short", { update_token: "ab".repeat(10) }],
        ["update_token too long", { update_token: "ab".repeat(101) }],
        ["update_token a number", { update_token: 5 }],
        ["session not a studio id", { session: "short" }],
        ["session a number", { session: 5 }],
        ["start not a boolean", { start: "yes" }],
        ["attributes missing", { attributes: undefined }],
        ["attributes.run differs from the path", { attributes: { ...ATTRS, run: RUN2 } }],
        ["attributes.input", { attributes: { ...ATTRS, input: "video" } }],
        ["attributes.origin", { attributes: { ...ATTRS, origin: "web" } }],
        ["attributes.service too long", { attributes: { ...ATTRS, service: "s".repeat(121) } }],
        ["attributes.ref too long", { attributes: { ...ATTRS, ref: "r".repeat(121) } }],
        ["attributes.service not a string", { attributes: { ...ATTRS, service: 5 } }],
        ["state missing", { state: undefined }],
        ["state not an object", { state: "fetching" }],
        ["state.stage not in the enum", { state: { ...FETCHING, stage: "nope" } }],
        ["state.rail 4", { state: { ...FETCHING, rail: 4 } }],
        ["state.rail fractional", { state: { ...FETCHING, rail: 1.5 } }],
        ["state.since not a number", { state: { ...FETCHING, since: "x" } }],
        ["state.waking missing", { state: { ...FETCHING, waking: undefined } }],
        ["state.packing not a boolean", { state: { ...FETCHING, packing: 1 } }],
        ["state.bytes fractional (Swift would drop the whole update)", { state: { ...FETCHING, bytes: 1.5 } }],
        ["state.framesDone a string", { state: { ...FETCHING, framesDone: "4" } }],
        ["state.title over 300 characters", { state: { ...FETCHING, title: "t".repeat(301) } }],
        ["state.duration not finite", { state: { ...FETCHING, duration: "1" } }],
    ];
    it.each(cases)("400 error.live.bad_request: %s", async (_n, over) => {
        const w = await world();
        const res = await w.put(over);
        expect(res).toEqual({ status: 400, body: { status: "error", error: { code: "error.live.bad_request" } } });
        expect(w.run()).toBeUndefined();
        expect(w.apple.calls).toHaveLength(0);
    });

    it("not JSON, not an object, or over 4096 bytes: 400", async () => {
        const w = await world();
        for (const raw of ["nope", "[]", "5", "null", JSON.stringify(reg({ pad: "x".repeat(4100) }))]) {
            expect((await w.live.putRun(KEY, RUN, raw)).status).toBe(400);
        }
    });

    it("a valid registration: 200 {pushing:true, started:false}; unknown state keys and nulls dropped; edge lengths accepted", async () => {
        const w = await world();
        const res = await w.put({
            attributes: { ...ATTRS, service: "s".repeat(120), ref: "r".repeat(120) },
            state: { ...FETCHING, evil: "x", bytes: null, title: "a".repeat(300) },
        });
        expect(res).toEqual({ status: 200, body: { status: "success", pushing: true, started: false } });
        const r = w.run()!;
        expect(r.state).toEqual({ ...FETCHING, title: "a".repeat(300) });
        expect(r).toMatchObject({ run: RUN, keyId: KEY, sid: null, job: null, env: "sandbox", updateToken: null, sent: null, startedAt: null, endedAt: null, createdAt: T0 });
        expect(r.attributes).toEqual({ ...ATTRS, service: "s".repeat(120), ref: "r".repeat(120) });
    });

    // The Swift client (LiveRunRegistration) sends update_token and session as explicit JSON
    // null when unknown; older callers may leave them out. Both mean "not known yet".
    it("update_token and session: explicit null, absent and null-with-everything-else are all accepted and mean the same", async () => {
        const absent = (o: Record<string, unknown>) => {
            const b = reg(o) as Record<string, unknown>;
            delete b.update_token;
            delete b.session;
            return b;
        };
        const bodies: Record<string, unknown>[] = [
            reg({ update_token: null, session: null }),
            absent({}),
            { ...absent({}), update_token: null },
            { ...absent({}), session: null },
            reg({ update_token: null, session: null, start: null }),
        ];
        for (const [i, b] of bodies.entries()) {
            const w = await world();
            const res = await w.live.putRun(KEY, RUN, JSON.stringify(b));
            expect(res, `body ${i}`).toEqual({ status: 200, body: { status: "success", pushing: true, started: false } });
            expect(w.run(), `body ${i}`).toMatchObject({ updateToken: null, sid: null, startedAt: null });
            expect(w.apple.calls, `body ${i}`).toHaveLength(0); // no token: nothing to push to
            expect(w.kv.m.has(`live:sid:${SID}`), `body ${i}`).toBe(false);
        }
    });
    it("explicit nulls over the wire (the route): a run with both null registers, then a later PUT fills the token and the session in", async () => {
        const w = await world();
        const wire = (o: Record<string, unknown>) =>
            handleLiveRoute(
                w.live,
                new Request(`https://do.internal/live/runs/${RUN}`, {
                    method: "PUT",
                    headers: { [KEY_ID_HEADER]: KEY },
                    body: JSON.stringify(reg(o)),
                }),
            );
        const text = JSON.stringify(reg({ update_token: null, session: null }));
        expect(text).toContain('"update_token":null');
        expect(text).toContain('"session":null');
        const first = await wire({ update_token: null, session: null });
        expect(first.status).toBe(200);
        expect(await first.json()).toEqual({ status: "success", pushing: true, started: false });
        expect(w.run()).toMatchObject({ updateToken: null, sid: null });
        const second = await wire({ update_token: UPDATE, session: SID });
        expect(second.status).toBe(200);
        expect(w.run()).toMatchObject({ updateToken: UPDATE, sid: SID });
        // and null again does not forget what is known
        await wire({ update_token: null, session: null });
        expect(w.run()).toMatchObject({ updateToken: UPDATE, sid: SID });
    });

    it("session: null and absent are fine; another key's or an unknown session is 404; D1 down is 503", async () => {
        const w = await world();
        expect((await w.put({ session: null })).status).toBe(200);
        expect((await w.put({ session: SID })).status).toBe(200);
        const other = await w.put({ session: SID_OTHER });
        expect(other).toEqual({ status: 404, body: { status: "error", error: { code: "error.live.not_found" } } });
        expect((await w.put({ session: "aaaaaaaaaaaaaaaaaaaaaa" })).status).toBe(404);
        expect(w.run()!.sid).toBe(SID); // the refused PUT changed nothing
        w.db.breakIt();
        expect((await w.put({ session: SID })).status).toBe(503);
    });

    it("another key's run id is 404, and a run keeps its owner", async () => {
        const w = await world();
        await w.put();
        const res = await w.put({}, RUN, OTHER);
        expect(res.status).toBe(404);
        expect(w.run()!.keyId).toBe(KEY);
    });

    it("indexes the run under its session (live:sid:<sid>), and moves it when the session changes", async () => {
        const w = await world();
        await w.put({ session: SID });
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN]);
        await w.put({ session: SID }, RUN2);
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN, RUN2]);
        w.db.raw.prepare("INSERT INTO studio_sessions (id, key_id, status, created_at, expires_at) VALUES (?, ?, 'saving', ?, ?)").run("qQ1wW2eE3rR4tT5yY6uU7i", KEY, T0, T0 + 1e9);
        await w.put({ session: "qQ1wW2eE3rR4tT5yY6uU7i" });
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN2]);
        expect(w.kv.m.get("live:sid:qQ1wW2eE3rR4tT5yY6uU7i")).toEqual([RUN]);
    });

    it("later PUTs fill in the update token and the session; the stored state is replaced only by a device-owned stage", async () => {
        const w = await world();
        await w.put();
        expect(w.run()).toMatchObject({ updateToken: null, sid: null });
        await w.put({ update_token: UPDATE, session: SID });
        expect(w.run()).toMatchObject({ updateToken: UPDATE, sid: SID });
        // the server moved on to saving; the app registers again with its (older) fetching state
        await w.live.onSave(SID, saving(100));
        expect(w.run()!.state.stage).toBe("saving");
        await w.put({ update_token: UPDATE, session: SID, state: FETCHING });
        expect(w.run()!.state.stage).toBe("saving");
        // a device stage does replace it
        await w.put({ update_token: UPDATE, session: SID, state: FIX.reading });
        expect(w.run()!.state).toEqual(FIX.reading);
        // and a later PUT without a token does not forget the one it has
        await w.put({ session: SID, state: FIX.reading });
        expect(w.run()!.updateToken).toBe(UPDATE);
    });
});

describe("not configured (no APNs secrets): degrade cleanly", () => {
    it("PUT answers pushing:false, reason not_configured, stores and sends nothing; hooks and the sweep question are inert", async () => {
        const w = await world({ configured: false });
        const res = await w.put({ update_token: UPDATE, session: SID, start: true });
        expect(res).toEqual({ status: 200, body: { status: "success", pushing: false, started: false, reason: "not_configured" } });
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("live:run:") || k.startsWith("live:sid:"))).toEqual([]);
        await w.live.onSave(SID, saving(1));
        await w.live.onRender(SID, "J", { kind: "accepted" });
        expect(await w.live.hasActiveRuns()).toBe(false);
        expect(w.apple.calls).toHaveLength(0);
        expect(w.live.configured()).toBe(false);
    });
    it("registration still validates (400 / 404 stay the same)", async () => {
        const w = await world({ configured: false });
        expect((await w.put({ environment: "x" })).status).toBe(400);
        expect((await w.put({ session: SID_OTHER })).status).toBe(404);
    });
    it("start tokens are kept (they are cheap) and the relay answers 404 (nothing was stored)", async () => {
        const w = await world({ configured: false });
        expect((await w.live.putStartToken(KEY, JSON.stringify({ token: START, environment: "sandbox" }))).status).toBe(204);
        expect(w.startToken()?.token).toBe(START);
        expect((await w.relay(FIX.reading)).status).toBe(404);
    });
    it("the self-test says configured:false", async () => {
        const w = await world({ configured: false });
        expect(await w.live.selftest()).toEqual({ status: 200, body: { status: "success", configured: false } });
    });
});

describe("start tokens", () => {
    const put = (w: World, body: unknown, key = KEY) => w.live.putStartToken(key, JSON.stringify(body));
    it("PUT stores {token, env, updatedAt} per key and answers 204; a later PUT replaces it", async () => {
        const w = await world();
        expect(await put(w, { token: START, environment: "production" })).toEqual({ status: 204, body: null });
        expect(w.startToken()).toEqual({ token: START, env: "production", updatedAt: T0 });
        w.tick(5000);
        await put(w, { token: UPDATE, environment: "sandbox" });
        expect(w.startToken()).toEqual({ token: UPDATE, env: "sandbox", updatedAt: T0 + 5000 });
        expect(w.startToken(OTHER)).toBeUndefined();
    });
    it("400 for a bad token or environment, or a body that is too big or not JSON", async () => {
        const w = await world();
        for (const body of [{ token: "zz", environment: "sandbox" }, { token: START, environment: "x" }, { token: START }, { environment: "sandbox" }, { token: "AB".repeat(32), environment: "sandbox" }]) {
            expect((await put(w, body)).status).toBe(400);
        }
        expect((await w.live.putStartToken(KEY, "nope")).status).toBe(400);
        expect(w.startToken()).toBeUndefined();
    });
    it("DELETE removes it and is idempotent", async () => {
        const w = await world();
        await put(w, { token: START, environment: "sandbox" });
        expect(await w.live.deleteStartToken(KEY)).toEqual({ status: 204, body: null });
        expect(w.startToken()).toBeUndefined();
        expect((await w.live.deleteStartToken(KEY)).status).toBe(204);
    });
});

describe("push-to-start", () => {
    const withStart = async (w: World, env: "sandbox" | "production" = "sandbox") => {
        await w.live.putStartToken(KEY, JSON.stringify({ token: START, environment: env }));
    };

    it("start:true with a start token sends one `start` push exactly as 8.4 and answers started:true", async () => {
        const w = await world();
        await withStart(w);
        const res = await w.put({ start: true, attributes: { ...ATTRS, origin: "share", service: "x", ref: "2105435404002562056" }, state: { ...FETCHING, waking: false } });
        expect(res).toEqual({ status: 200, body: { status: "success", pushing: true, started: true } });
        expect(w.apple.calls).toHaveLength(1);
        const [p] = w.apple.pushes;
        expect(p!.token).toBe(START);
        expect(p!.host).toBe("api.sandbox.push.apple.com");
        expect(p!.priority).toBe(10);
        expect(p!.expiration).toBe(s0 + 3600);
        expect(w.apple.calls[0]!.req.headers["apns-push-type"]).toBe("liveactivity");
        expect(p!.payload).toEqual({
            aps: {
                timestamp: s0,
                event: "start",
                "attributes-type": "CobaltActivityAttributes",
                attributes: { run: RUN, input: "link", service: "x", ref: "2105435404002562056", origin: "share" },
                "content-state": FETCHING,
                "stale-date": s0 + 120,
                "input-push-token": 1,
                alert: { title: "cobalt", body: "fetching from x" },
            },
        });
        expect(JSON.stringify(p!.payload)).not.toContain("sound");
        // the order of the keys is the one the contract shows
        expect(Object.keys(p!.payload.aps)).toEqual(["timestamp", "event", "attributes-type", "attributes", "content-state", "stale-date", "input-push-token", "alert"]);
        const r = w.run()!;
        expect(r.startedAt).toBe(T0);
        expect(r.sent).toEqual(FETCHING);
        expect(r.lastPushAt).toBe(T0);
    });

    it("a file run says `uploading <ref>`", async () => {
        const w = await world();
        await withStart(w);
        await w.put({ start: true, attributes: { ...ATTRS, input: "file", service: "file", ref: "IMG_0412.mov", origin: "share" }, state: FIX.uploading });
        expect(w.apple.pushes[0]!.payload.aps.alert).toEqual({ title: "cobalt", body: "uploading IMG_0412.mov" });
        expect(w.apple.pushes[0]!.payload.aps["content-state"]).toEqual(FIX.uploading);
    });

    it("is honoured once per run: a second PUT with start:true sends nothing", async () => {
        const w = await world();
        await withStart(w);
        await w.put({ start: true });
        const again = await w.put({ start: true, session: SID });
        expect(again.body).toEqual({ status: "success", pushing: true, started: false });
        expect(w.apple.calls).toHaveLength(1);
    });

    it("no start token: started:false, reason no_start_token, nothing sent", async () => {
        const w = await world();
        const res = await w.put({ start: true });
        expect(res).toEqual({ status: 200, body: { status: "success", pushing: true, started: false, reason: "no_start_token" } });
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.startedAt).toBeNull();
    });

    it("start:true is for a run without an update token (an app run that has one is already shown)", async () => {
        const w = await world();
        await withStart(w);
        const res = await w.put({ start: true, update_token: UPDATE });
        expect((res.body as { started: boolean }).started).toBe(false);
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).not.toContain("start");
    });

    it("a failed start is not 'honoured': pushing goes false, and the next PUT may try again", async () => {
        const w = await world({ apple: new Apple([bad(500, null), ok()]) });
        await withStart(w);
        const first = await w.put({ start: true });
        expect(first.body).toEqual({ status: "success", pushing: false, started: false });
        expect(w.run()!.startedAt).toBeNull();
        w.tick(LIVE_START_MIN_GAP_MS); // at most one start per key per 10 s
        const second = await w.put({ start: true });
        expect(second.body).toEqual({ status: "success", pushing: true, started: true });
        expect(w.apple.calls).toHaveLength(2);
    });

    it("BadDeviceToken retries on the other host and remembers the right environment for the start token", async () => {
        const w = await world({ apple: new Apple([bad(400, "BadDeviceToken"), ok()]) });
        await withStart(w, "sandbox");
        const res = await w.put({ start: true });
        expect((res.body as { started: boolean }).started).toBe(true);
        expect(w.apple.hosts).toEqual(["api.sandbox.push.apple.com", "api.push.apple.com"]);
        expect(w.startToken()!.env).toBe("production");
    });

    it("a dead start token (410) is dropped: started:false, no_start_token", async () => {
        const w = await world({ apple: new Apple([bad(410, "Unregistered")]) });
        await withStart(w);
        const res = await w.put({ start: true });
        expect(res.body).toEqual({ status: "success", pushing: true, started: false, reason: "no_start_token" });
        expect(w.startToken()).toBeUndefined();
    });
});

describe("the catch-up push (a new update token while the state differs from what APNs accepted)", () => {
    it("a push-started activity catches up when the app reports its token: one update, priority 10", async () => {
        const w = await world();
        await w.live.putStartToken(KEY, JSON.stringify({ token: START, environment: "sandbox" }));
        await w.put({ start: true, session: SID });
        w.apple.calls.length = 0;
        // the server moves on while the activity has no update token yet: stored, not sent
        w.tick(5000);
        await w.live.onSave(SID, saving(500));
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.state).toMatchObject({ stage: "saving", bytes: 500 });
        // the token arrives
        w.tick(1000);
        const res = await w.put({ update_token: UPDATE, session: SID });
        expect(res.body).toEqual({ status: "success", pushing: true, started: false });
        expect(w.apple.pushes).toHaveLength(1);
        const [p] = w.apple.pushes;
        expect(p!.token).toBe(UPDATE);
        expect(p!.priority).toBe(10);
        expect(p!.expiration).toBe(Math.floor(w.clock.t / 1000) + 3600);
        expect(p!.payload.aps.event).toBe("update");
        expect(p!.payload.aps["content-state"]).toMatchObject({ stage: "saving", bytes: 500, total: 4331778 });
        expect(p!.payload.aps["stale-date"]).toBe(Math.floor(w.clock.t / 1000) + 120);
        expect(w.run()!.sent).toEqual(w.run()!.state);
        // the same token again with nothing new: no second push
        await w.put({ update_token: UPDATE, session: SID });
        expect(w.apple.pushes).toHaveLength(1);
    });
    it("a new run registered with a token and a state APNs has not seen gets one update at once (the literal rule)", async () => {
        const w = await world();
        await w.put({ update_token: UPDATE, session: SID });
        expect(w.apple.pushes).toHaveLength(1);
        expect(w.apple.pushes[0]!.priority).toBe(10);
        expect(w.apple.pushes[0]!.payload.aps["content-state"]).toEqual(FETCHING);
    });
});

describe("the merge rule (nextState)", () => {
    const at = (s: number) => s * 1000;
    it("a stage change resets the counters and `since`; the same stage keeps `since`", () => {
        const a = nextState(FIX.saving_storing!, { t: "rendering", framesDone: 5, framesTotal: 150, packing: false }, at(s0 + 40));
        expect(a).toEqual({ stage: "rendering", rail: 3, since: s0 + 40, waking: false, packing: false, framesDone: 5, framesTotal: 150 });
        const b = nextState(a, { t: "rendering", framesDone: 6, framesTotal: 150, packing: false }, at(s0 + 45));
        expect(b.since).toBe(s0 + 40);
        expect(b.framesDone).toBe(6);
    });
    it("`fetching` keeps the registered since (and the registration's waking is replaced by the event's)", () => {
        const reg1: LiveState = { ...FETCHING, since: s0 - 7 };
        expect(nextState(reg1, { t: "fetching", waking: true }, at(s0))).toEqual({ ...reg1, waking: true });
        expect(nextState(null, { t: "fetching", waking: false }, at(s0)).since).toBe(s0);
    });
    it("title and duration carry over, and update when the event knows them", () => {
        const a = nextState(FIX.ready!, { t: "rendering", framesDone: null, framesTotal: null, packing: false }, at(s0));
        expect(a).toMatchObject({ title: "instagram_Dd7P496wolG", duration: 14.77 });
        const b = nextState(a, { t: "rendering", framesDone: null, framesTotal: null, packing: false, title: "new", duration: 3 }, at(s0));
        expect(b).toMatchObject({ title: "new", duration: 3 });
        const c = nextState(a, { t: "rendering", framesDone: null, framesTotal: null, packing: false, title: null, duration: null }, at(s0));
        expect(c).toMatchObject({ title: "instagram_Dd7P496wolG", duration: 14.77 });
    });
    it("`failed` keeps the rail it failed on; with no earlier state it is the rail of the phase", () => {
        expect(nextState(FIX.saving_storing!, { t: "failed", code: "error.studio.busy", phase: "saving" }, at(s0))).toMatchObject({ rail: 1, failure: "serverBusy", code: "error.studio.busy" });
        expect(nextState(null, { t: "failed", code: "error.webp.busy", phase: "rendering" }, at(s0))).toMatchObject({ rail: 3, failure: "renderBusy" });
        expect(nextState(null, { t: "failed", code: "error.studio.busy", phase: "saving" }, at(s0))).toMatchObject({ rail: 1 });
    });
    it("missing numbers are omitted, never null (the degraded save)", () => {
        const a = nextState(FETCHING, { t: "saving", bytes: null, total: null }, at(s0));
        expect(a).toEqual({ stage: "saving", rail: 1, since: s0, waking: false, packing: false });
        expect(JSON.stringify(a)).not.toContain("null");
    });
    it("render phases: decode -> frames, pack -> packing with frames = total, fetching/null -> neither", () => {
        const ev = (phase: any, d: number | null, t: number | null) => stateEventOfRender({ kind: "pending", phase, framesDone: d, framesTotal: t });
        expect(nextState(FIX.ready!, ev("decode", 42, 150), at(s0))).toMatchObject({ packing: false, framesDone: 42, framesTotal: 150 });
        expect(nextState(FIX.ready!, ev("pack", 150, 150), at(s0))).toMatchObject({ packing: true, framesDone: 150, framesTotal: 150 });
        expect(nextState(FIX.ready!, ev("pack", null, 150), at(s0))).toMatchObject({ packing: true, framesDone: 150, framesTotal: 150 });
        for (const phase of ["fetching", null]) {
            const s = nextState(FIX.ready!, ev(phase, 3, 9), at(s0));
            expect(s.framesDone).toBeUndefined();
            expect(s.framesTotal).toBeUndefined();
            expect(s.packing).toBe(false);
        }
    });
    it("save events: fetching -> fetching (waking), reading and storing -> saving", () => {
        const p = (step: any, bytes: number | null, total: number | null, waking = false) => stateEventOfSave({ kind: "progress", progress: { step, bytes, total, waking } });
        expect(p("fetching", 5, 10, true)).toEqual({ t: "fetching", waking: true });
        expect(p("reading", 5, null)).toMatchObject({ t: "saving", bytes: 5, total: null });
        expect(p("storing", 5, 10)).toMatchObject({ t: "saving", bytes: 5, total: 10 });
        expect(stateEventOfSave({ kind: "failed", code: "x" })).toEqual({ t: "failed", code: "x", phase: "saving" });
    });
});

describe("parity with the app's fixture (test/fixtures/live-states.json)", () => {
    const at = (s: number) => s * 1000;
    it("the builder produces each server-written entry from its event", () => {
        const fetching = nextState(null, stateEventOfSave({ kind: "progress", progress: { step: "fetching", bytes: null, total: null, waking: true } }), at(1790000000));
        expect(fetching).toEqual(FIX.fetching_waking);
        const savingState = nextState(fetching, stateEventOfSave(saving(2100000, 4331778)), at(1790000003));
        expect(savingState).toEqual(FIX.saving_storing);
        const decoding = nextState(FIX.ready!, stateEventOfRender({ kind: "pending", phase: "decode", framesDone: 42, framesTotal: 150 }), at(1790000020));
        expect(decoding).toEqual(FIX.decoding);
        const packing = nextState(decoding, stateEventOfRender({ kind: "pending", phase: "pack", framesDone: 150, framesTotal: 150 }), at(1790000025));
        expect(packing).toEqual(FIX.packing);
        const done = nextState(packing, stateEventOfRender({ kind: "success", url: "https://media.capybaraharmony.com/PrEvIeW001.webp", bytes: 4500000, width: 480, height: 854, seconds: 10.1 }), at(1790000043));
        expect(done).toEqual(FIX.done);
        expect(nextState(decoding, stateEventOfRender({ kind: "failed", code: "error.webp.job_lost" }), at(1790000030))).toEqual(FIX.failed_render_lost);
        expect(nextState(fetching, stateEventOfSave({ kind: "failed", code: "error.api.fetch.empty" }), at(1790000002))).toEqual(FIX.failed_fetch);
    });
    it("the device-written entries survive sanitizing unchanged, key order included", () => {
        for (const name of ["uploading", "reading", "ready", ...Object.keys(FIX)]) {
            expect(sanitizeState(FIX[name])).toEqual(FIX[name]);
            expect(JSON.stringify(sanitizeState(FIX[name]))).toBe(JSON.stringify(FIX[name]));
        }
    });
    it("the fixture covers every stage, and a state with every field serialises to the fixture's key order", () => {
        expect(new Set(Object.values(FIX).map((s) => s.stage))).toEqual(new Set(["fetching", "uploading", "saving", "reading", "ready", "rendering", "done", "failed"]));
        const keys = new Set(Object.values(FIX).flatMap((s) => Object.keys(s)));
        for (const k of ["resultURL", "resultBytes", "resultWidth", "resultHeight", "resultSeconds", "failure", "code", "title", "duration", "framesDone", "framesTotal", "bytes", "total"]) {
            expect(keys.has(k)).toBe(true);
        }
    });

    it("end to end through the service: every push's content-state is the fixture entry", async () => {
        const w = await world();
        const sec = () => Math.floor(w.clock.t / 1000);
        const goto = (s: number) => {
            w.clock.t = s * 1000;
        };
        // the app registers a run with its token (the catch-up push shows the registered state)
        await w.put({ update_token: UPDATE, session: SID, state: { ...FETCHING, since: 1790000000 } });
        w.apple.calls.length = 0;
        const last = () => w.apple.pushes.at(-1)!.payload.aps["content-state"];

        goto(1790000001);
        await w.live.onSave(SID, { kind: "progress", progress: { step: "fetching", bytes: null, total: null, waking: true } });
        expect(w.apple.pushes).toHaveLength(1);
        expect(last()).toEqual(FIX.fetching_waking);

        goto(1790000003);
        await w.live.onSave(SID, saving(2100000, 4331778));
        expect(last()).toEqual(FIX.saving_storing);

        goto(1790000005); // the share extension relays the device stages
        await w.relay(FIX.reading);
        expect(last()).toEqual(FIX.reading);
        goto(1790000007);
        await w.relay(FIX.ready);
        expect(last()).toEqual(FIX.ready);
        expect(w.apple.pushes.at(-1)!.payload.aps["stale-date"]).toBe(1790000007 + 1800);

        goto(1790000020);
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "accepted", title: "instagram_Dd7P496wolG", duration: 14.77 });
        expect(last()).toMatchObject({ stage: "rendering", since: 1790000020, title: "instagram_Dd7P496wolG", duration: 14.77 });
        expect(last().framesDone).toBeUndefined();
        goto(1790000021);
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "pending", phase: "decode", framesDone: 42, framesTotal: 150 });
        expect(last()).toEqual(FIX.decoding);
        goto(1790000025);
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "pending", phase: "pack", framesDone: 150, framesTotal: 150 });
        expect(last()).toEqual(FIX.packing);
        goto(1790000043);
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "success", url: "https://media.capybaraharmony.com/PrEvIeW001.webp", bytes: 4500000, width: 480, height: 854, seconds: 10.1 });
        expect(last()).toEqual(FIX.done);
        expect(w.apple.pushes.at(-1)!.payload.aps.event).toBe("end");
        expect(sec()).toBe(1790000043);
    });

    it("end to end: a render lost, and a failed fetch", async () => {
        const w = await world();
        await w.put({ update_token: UPDATE, session: SID, state: FIX.ready });
        w.apple.calls.length = 0;
        w.clock.t = 1790000020 * 1000;
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "accepted", title: "instagram_Dd7P496wolG", duration: 14.77 });
        w.clock.t = 1790000021 * 1000;
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "pending", phase: "decode", framesDone: 42, framesTotal: 150 });
        w.clock.t = 1790000030 * 1000;
        await w.live.onRender(SID, "J0b1d2f3h4j5l6n7p8r9", { kind: "failed", code: "error.webp.job_lost" });
        expect(w.apple.pushes.at(-1)!.payload.aps["content-state"]).toEqual(FIX.failed_render_lost);

        const w2 = await world();
        await w2.put({ update_token: UPDATE, session: SID, state: { ...FETCHING, since: 1790000000 } });
        w2.clock.t = 1790000001 * 1000;
        await w2.live.onSave(SID, { kind: "progress", progress: { step: "fetching", bytes: null, total: null, waking: true } });
        w2.clock.t = 1790000002 * 1000;
        await w2.live.onSave(SID, { kind: "failed", code: "error.api.fetch.empty" });
        expect(w2.apple.pushes.at(-1)!.payload.aps["content-state"]).toEqual(FIX.failed_fetch);
    });
});

describe("rate limiting and coalescing", () => {
    it("counters push at most once a second; the latest value goes with the next push; stage changes go at once", async () => {
        const w = await world();
        await w.armed();
        // a stage change goes at once, even right after the catch-up push
        await w.live.onSave(SID, saving(100));
        expect(w.apple.pushes).toHaveLength(1);
        expect(w.apple.pushes[0]!.priority).toBe(10);

        w.tick(400);
        await w.live.onSave(SID, saving(200));
        w.tick(400);
        await w.live.onSave(SID, saving(300));
        expect(w.apple.pushes).toHaveLength(1); // stored, not sent
        expect(w.run()!.state.bytes).toBe(300);
        expect(w.run()!.sent!.bytes).toBe(100);

        w.tick(300); // 1100 ms after the last push
        await w.live.onSave(SID, saving(400));
        expect(w.apple.pushes).toHaveLength(2);
        expect(w.apple.pushes[1]!.priority).toBe(5);
        expect(w.apple.pushes[1]!.payload.aps["content-state"]).toMatchObject({ bytes: 400 }); // the latest, not 300
        expect(w.run()!.sent!.bytes).toBe(400);

        // a stage change inside the second still goes at once
        w.tick(100);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        expect(w.apple.pushes).toHaveLength(3);
        expect(w.apple.pushes[2]!.priority).toBe(10);
    });

    it("exactly one second later is enough; 999 ms is not", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(1));
        const n = w.apple.pushes.length;
        w.tick(999);
        await w.live.onSave(SID, saving(2));
        expect(w.apple.pushes).toHaveLength(n);
        w.tick(1);
        await w.live.onSave(SID, saving(3));
        expect(w.apple.pushes).toHaveLength(n + 1);
    });

    it("an equal state is never re-sent, however often it is reported", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100));
        const n = w.apple.pushes.length;
        for (let i = 0; i < 5; i++) {
            w.tick(5000);
            await w.live.onSave(SID, saving(100));
        }
        expect(w.apple.pushes).toHaveLength(n);
    });

    it("priorities and expirations: counters 5 and now+60 s; stage changes, start, end 10 and now+3600 s", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100));
        w.tick(2000);
        await w.live.onSave(SID, saving(200));
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "pending", phase: "decode", framesDone: 1, framesTotal: 10 });
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "success", url: "https://m/x.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
        const sec = (ms: number) => Math.floor(ms / 1000);
        expect(w.apple.pushes.map((p) => [p.payload.aps.event, p.priority, p.expiration - p.payload.aps.timestamp])).toEqual([
            ["update", 10, 3600], // saving
            ["update", 5, 60], // counter
            ["update", 10, 3600], // rendering
            ["update", 5, 60], // counter
            ["end", 10, 3600], // done
        ]);
        expect(sec(w.clock.t)).toBe(w.apple.pushes.at(-1)!.payload.aps.timestamp);
    });

    it("without an update token the state is stored and nothing is sent", async () => {
        const w = await world();
        await w.put({ session: SID });
        await w.live.onSave(SID, saving(100));
        await w.live.onRender(SID, "J", { kind: "accepted" });
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.state.stage).toBe("rendering");
    });

    it("a failed push (non-token) is not recorded as sent, so the next event sends the latest; 429 likewise", async () => {
        const w = await world({ apple: new Apple([ok(), bad(500, null), bad(429, "TooManyRequests"), ok()]) });
        await w.armed();
        await w.live.onSave(SID, saving(100)); // push 2 of the script... (armed consumed #1)
        expect(w.run()!.sent).toMatchObject({ stage: "fetching" }); // 500: not sent
        w.tick(2000);
        await w.live.onSave(SID, saving(200)); // 429
        expect(w.run()!.sent).toMatchObject({ stage: "fetching" });
        w.tick(2000);
        await w.live.onSave(SID, saving(300)); // 200
        expect(w.run()!.sent).toMatchObject({ stage: "saving", bytes: 300 });
    });
});

describe("`end` pushes", () => {
    const done = { kind: "success" as const, url: "https://media.capybaraharmony.com/PrEvIeW001.webp", bytes: 4500000, width: 480, height: 854, seconds: 10.1 };

    it("done: dismissal in 15 minutes, a `webp ready` alert with service · size, no sound; the run ends", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted", title: "t", duration: 2 });
        w.apple.calls.length = 0;
        w.tick(5000);
        await w.live.onRender(SID, "J", done);
        const [p] = w.apple.pushes;
        const now = Math.floor(w.clock.t / 1000);
        expect(p!.payload.aps).toEqual({
            timestamp: now,
            event: "end",
            "content-state": expect.objectContaining({ stage: "done", resultBytes: 4500000 }),
            "dismissal-date": now + 900,
            alert: { title: "webp ready", body: "instagram · 4.5 MB" },
        });
        expect(Object.keys(p!.payload.aps)).toEqual(["timestamp", "event", "content-state", "dismissal-date", "alert"]);
        expect(JSON.stringify(p!.payload)).not.toContain("sound");
        expect(p!.payload.aps["stale-date"]).toBeUndefined();
        expect(w.run()!.endedAt).toBe(w.clock.t);
    });

    it("failed: dismissal in 5 minutes, `cobalt couldn't finish`", async () => {
        const w = await world();
        await w.armed();
        w.tick(1000);
        await w.live.onSave(SID, { kind: "failed", code: "error.studio.busy" });
        const [p] = w.apple.pushes;
        const now = Math.floor(w.clock.t / 1000);
        expect(p!.payload.aps).toMatchObject({
            event: "end",
            "dismissal-date": now + 300,
            alert: { title: "cobalt couldn't finish", body: "open cobalt to see what happened." },
            "content-state": { stage: "failed", failure: "serverBusy", code: "error.studio.busy" },
        });
        expect(p!.priority).toBe(10);
        expect(w.run()!.endedAt).not.toBeNull();
    });

    it("events for an ended run are ignored (nothing sent, state kept)", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.tick(2000);
        await w.live.onRender(SID, "J", done);
        const n = w.apple.calls.length;
        const state = w.run()!.state;
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        await w.live.onSave(SID, saving(1));
        await w.live.onRender(SID, "J", done);
        expect(w.apple.calls).toHaveLength(n);
        expect(w.run()!.state).toEqual(state);
    });

    it("a terminal whose push did not get through is not ended: the next repeat (a poll) sends it again", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.apple.script = [bad(500, null), ok()];
        w.apple.calls.length = 0;
        w.tick(2000);
        await w.live.onRender(SID, "J", done); // 500
        expect(w.run()!.endedAt).toBeNull();
        expect(w.run()!.sent!.stage).not.toBe("done");
        w.tick(LIVE_END_RETRY_DELAYS_MS[0]!); // after the backoff
        await w.live.onRender(SID, "J", done); // repeated success: re-sent
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["end", "end"]);
        expect(w.run()!.endedAt).not.toBeNull();
        expect(w.run()!.sent!.stage).toBe("done");
    });

    it("size formatting is the app's Format.bytes", () => {
        expect(formatBytes(841_000)).toBe("841 KB");
        expect(formatBytes(1)).toBe("1 KB");
        expect(formatBytes(999_499)).toBe("999 KB");
        expect(formatBytes(4_500_000)).toBe("4.5 MB");
        expect(formatBytes(999_999_999)).toBe("1000.0 MB");
        expect(formatBytes(1_200_000_000)).toBe("1.2 GB");
        const a = { run: RUN, input: "link" as const, service: "x", ref: "r", origin: "app" as const };
        expect(endPayload(a, { ...FIX.done!, resultBytes: 841_000 }, T0).aps.alert).toEqual({ title: "webp ready", body: "x · 841 KB" });
        expect(endPayload(a, { ...FIX.done!, resultBytes: undefined }, T0).aps.alert).toEqual({ title: "webp ready", body: "x" });
    });
});

describe("the device relay (POST /live/runs/<run>/state)", () => {
    it("accepts the device stages, answers 202, and pushes them", async () => {
        const w = await world();
        await w.armed();
        for (const name of ["uploading", "reading", "ready"] as const) {
            w.tick(2000);
            expect(await w.relay(FIX[name])).toEqual({ status: 202, body: { status: "success" } });
            expect(w.run()!.state).toEqual(FIX[name]);
        }
        expect(w.apple.pushes.map((p) => p.payload.aps["content-state"].stage)).toEqual(["uploading", "reading", "ready"]);
        expect(DEVICE_STAGES).toEqual(["uploading", "reading", "ready", "failed"]);
    });
    it("a relayed `ready` goes stale in 30 minutes, anything else in 2", async () => {
        const w = await world();
        await w.armed();
        await w.relay(FIX.reading);
        await w.relay(FIX.ready);
        const stale = w.apple.pushes.map((p) => p.payload.aps["stale-date"] - p.payload.aps.timestamp);
        expect(stale).toEqual([120, 1800]);
    });
    it("a relayed `failed` ends the run with the failure alert", async () => {
        const w = await world();
        await w.armed();
        const failed = { stage: "failed", rail: 0, since: s0, waking: false, packing: false, failure: "tooLarge" };
        await w.relay(failed);
        const [p] = w.apple.pushes;
        expect(p!.payload.aps.event).toBe("end");
        expect(p!.payload.aps["dismissal-date"]).toBe(s0 + 300);
        expect(w.run()!.endedAt).not.toBeNull();
    });
    it("server stages are refused: 409 error.live.server_stage", async () => {
        const w = await world();
        await w.armed();
        for (const stage of ["fetching", "saving", "rendering", "done"]) {
            const res = await w.relay({ ...FIX.reading, stage });
            expect(res).toEqual({ status: 409, body: { status: "error", error: { code: "error.live.server_stage" } } });
        }
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.state).toEqual(FETCHING);
    });
    it("404 for an unknown run or another key's, 400 for a bad body or state (checked first)", async () => {
        const w = await world();
        await w.put();
        expect((await w.relay(FIX.reading, RUN2)).status).toBe(404);
        expect((await w.relay(FIX.reading, RUN, OTHER)).status).toBe(404);
        expect(w.run()!.state).toEqual(FETCHING);
        expect((await w.relay({ stage: "reading" })).status).toBe(400);
        expect((await w.relay({ ...FIX.reading, rail: 9 })).status).toBe(400);
        expect((await w.live.relayState(KEY, RUN, "nope")).status).toBe(400);
        expect((await w.live.relayState(KEY, RUN, JSON.stringify({}))).status).toBe(400);
        expect((await w.relay({ ...FIX.reading, stage: "bogus" }, RUN2)).status).toBe(400);
    });
    it("coalesces like any other writer: counters of one stage go once a second", async () => {
        const w = await world();
        await w.armed();
        const up = (bytes: number) => ({ ...FIX.uploading, bytes });
        await w.relay(up(1));
        for (let i = 2; i <= 5; i++) {
            w.tick(200);
            await w.relay(up(i));
        }
        expect(w.apple.pushes).toHaveLength(1);
        w.tick(300);
        await w.relay(up(6));
        expect(w.apple.pushes).toHaveLength(2);
        expect(w.apple.pushes[1]!.payload.aps["content-state"].bytes).toBe(6);
    });
    it("a relay to an ended run is accepted and ignored", async () => {
        const w = await world();
        await w.armed();
        await w.relay({ ...FIX.reading, stage: "failed", failure: "tooLarge" });
        w.apple.calls.length = 0;
        expect((await w.relay(FIX.reading)).status).toBe(202);
        expect(w.apple.calls).toHaveLength(0);
    });
});

describe("DELETE /live/runs/<run>", () => {
    it("with an update token and not ended: one `end` push with the stored state, dismissal now, no alert; then the record and its index entry go", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100));
        w.apple.calls.length = 0;
        w.tick(3000);
        expect(await w.live.deleteRun(KEY, RUN)).toEqual({ status: 204, body: null });
        expect(w.apple.pushes).toHaveLength(1);
        const [p] = w.apple.pushes;
        const now = Math.floor(w.clock.t / 1000);
        expect(p!.token).toBe(UPDATE);
        expect(p!.priority).toBe(10);
        expect(p!.payload.aps).toEqual({
            timestamp: now,
            event: "end",
            "content-state": expect.objectContaining({ stage: "saving", bytes: 100 }),
            "dismissal-date": now,
        });
        expect(p!.payload.aps.alert).toBeUndefined();
        expect(w.run()).toBeUndefined();
        expect(w.kv.m.has(`live:sid:${SID}`)).toBe(false);
    });
    it("without a token, already ended, absent, or another key's: no push; 204 every time", async () => {
        const w = await world();
        await w.put({ session: SID }); // no token
        expect((await w.live.deleteRun(KEY, RUN)).status).toBe(204);
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()).toBeUndefined();

        expect((await w.live.deleteRun(KEY, RUN)).status).toBe(204); // idempotent

        await w.put({ update_token: UPDATE });
        expect((await w.live.deleteRun(OTHER, RUN)).status).toBe(204);
        expect(w.run()).toBeDefined(); // not theirs: untouched

        await w.live.onSave(SID, { kind: "failed", code: "x" }); // no session: no run for that sid... end it through the relay instead
        await w.relay({ ...FIX.reading, stage: "failed", failure: "tooLarge" });
        w.apple.calls.length = 0;
        await w.live.deleteRun(KEY, RUN);
        expect(w.apple.calls).toHaveLength(0); // already ended: no second end
        expect(w.run()).toBeUndefined();
    });
    it("keeps other runs of the same session in the index", async () => {
        const w = await world();
        await w.put({ session: SID });
        await w.put({ session: SID }, RUN2);
        await w.live.deleteRun(KEY, RUN);
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN2]);
    });
});

describe("tokens that APNs refuses", () => {
    it("410 drops the run's update token: later events are stored and not sent", async () => {
        const w = await world({ apple: new Apple([ok(), bad(410, "Unregistered")]) });
        await w.armed();
        await w.live.onSave(SID, saving(1));
        expect(w.run()!.updateToken).toBeNull();
        w.apple.calls.length = 0;
        w.tick(5000);
        await w.live.onSave(SID, saving(2));
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.state.bytes).toBe(2);
    });
    it("BadDeviceToken on the registered host succeeds on the other one: the run remembers its environment", async () => {
        const w = await world({ apple: new Apple([bad(400, "BadDeviceToken"), ok()]) });
        await w.put({ update_token: UPDATE, session: SID, environment: "sandbox" });
        expect(w.apple.hosts).toEqual(["api.sandbox.push.apple.com", "api.push.apple.com"]);
        expect(w.run()!.env).toBe("production");
        w.apple.script = [ok()];
        w.apple.calls.length = 0;
        await w.live.onSave(SID, saving(1));
        expect(w.apple.hosts).toEqual(["api.push.apple.com"]); // straight to the right host now
    });
    it("a terminal state whose token is dead still ends the run", async () => {
        const w = await world({ apple: new Apple([ok(), bad(410, null)]) });
        await w.armed();
        await w.live.onSave(SID, { kind: "failed", code: "x" });
        expect(w.run()).toMatchObject({ updateToken: null });
        expect(w.run()!.endedAt).not.toBeNull();
    });
});

describe("`pushing` (health of the last APNs attempt for this key)", () => {
    it("a non-token failure makes pushing false for 10 minutes, then true again; a success clears it at once", async () => {
        const w = await world({ apple: new Apple([bad(403, "InvalidProviderToken"), ok()]) });
        const first = await w.put({ update_token: UPDATE, session: SID });
        expect(first.body).toMatchObject({ pushing: false });
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(true);
        w.tick(9 * 60_000);
        expect((await w.put({ session: SID })).body).toMatchObject({ pushing: false });
        w.tick(60_000);
        expect((await w.put({ session: SID })).body).toMatchObject({ pushing: true });

        // the other key is not affected, and a later success clears the mark
        expect(w.kv.m.has(`live:health:${OTHER}`)).toBe(false);
        w.apple.script = [bad(500, null), ok()];
        w.apple.calls.length = 0;
        await w.live.onSave(SID, saving(1));
        expect((await w.put({ session: SID })).body).toMatchObject({ pushing: false });
        w.tick(2000);
        await w.live.onSave(SID, saving(2));
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(false);
        expect((await w.put({ session: SID })).body).toMatchObject({ pushing: true });
    });
    it("a dead token is not a health problem", async () => {
        const w = await world({ apple: new Apple([bad(410, null)]) });
        const res = await w.put({ update_token: UPDATE, session: SID });
        expect(res.body).toMatchObject({ pushing: true });
    });
});

describe("hooks pick runs by session and job", () => {
    it("events go to every live run of the session, none of another session", async () => {
        const w = await world();
        await w.put({ update_token: UPDATE, session: SID });
        await w.put({ update_token: "ab".repeat(32), session: SID }, RUN2);
        w.apple.calls.length = 0;
        await w.live.onSave(SID_OTHER, saving(5));
        await w.live.onSave("nobodyNobodyNobodyNobo", saving(5));
        expect(w.apple.calls).toHaveLength(0);
        await w.live.onSave(SID, saving(5));
        expect(w.apple.pushes.map((p) => p.token).sort()).toEqual([UPDATE, "ab".repeat(32)].sort());
    });
    it("`accepted` sets the run's job; later render events match that job only", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "JOBAAAAAAAAAAAAAAAAA", { kind: "accepted", title: "t", duration: 3 });
        expect(w.run()!.job).toBe("JOBAAAAAAAAAAAAAAAAA");
        w.apple.calls.length = 0;
        w.tick(2000);
        await w.live.onRender(SID, "JOBBBBBBBBBBBBBBBBBB", { kind: "pending", phase: "decode", framesDone: 4, framesTotal: 9 });
        await w.live.onRender(SID, "JOBBBBBBBBBBBBBBBBBB", { kind: "success", url: "https://m/x.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
        expect(w.apple.calls).toHaveLength(0);
        expect(w.run()!.state.stage).toBe("rendering");
        await w.live.onRender(SID, "JOBAAAAAAAAAAAAAAAAA", { kind: "pending", phase: "decode", framesDone: 4, framesTotal: 9 });
        expect(w.apple.calls).toHaveLength(1);
        // a second render of the session takes over the run
        w.tick(2000);
        await w.live.onRender(SID, "JOBBBBBBBBBBBBBBBBBB", { kind: "accepted" });
        expect(w.run()!.job).toBe("JOBBBBBBBBBBBBBBBBBB");
    });
    it("a render event for a run that never saw `accepted` adopts its job", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "JOBAAAAAAAAAAAAAAAAA", { kind: "pending", phase: "decode", framesDone: 1, framesTotal: 9 });
        expect(w.run()!.job).toBe("JOBAAAAAAAAAAAAAAAAA");
        expect(w.run()!.state).toMatchObject({ stage: "rendering", framesDone: 1 });
    });
    it("a finished state is only repeated, never revived by a late counter", async () => {
        const w = await world({ apple: new Apple([bad(500, null)]) });
        await w.put({ update_token: UPDATE, session: SID, state: FIX.ready });
        w.apple.script = [bad(500, null)];
        await w.live.onRender(SID, "J", { kind: "success", url: "https://m/x.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
        expect(w.run()!.state.stage).toBe("done");
        await w.live.onRender(SID, "J", { kind: "pending", phase: "decode", framesDone: 1, framesTotal: 9 });
        expect(w.run()!.state.stage).toBe("done");
    });
    it("a poll that changes nothing writes nothing", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100));
        const before = JSON.stringify(w.run());
        let puts = 0;
        const put = w.kv.put.bind(w.kv);
        w.kv.put = async (k, v) => {
            puts++;
            return put(k, v);
        };
        await w.live.onSave(SID, saving(100));
        expect(puts).toBe(0);
        expect(JSON.stringify(w.run())).toBe(before);
    });
    it("hooks never throw (a broken store is the caller's log line, not a failed poll) is the studio's guard; here a transport error is just health", async () => {
        const w = await world({ apple: new Apple([new Error("boom")]) });
        await w.put({ update_token: UPDATE, session: SID });
        await expect(w.live.onSave(SID, saving(1))).resolves.toBeUndefined();
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(true);
    });
});

describe("hasActiveRuns (the sweep's 2 s cadence)", () => {
    it("true for a run with an update token waiting on a server stage; false for device stages, finished, tokenless or ended runs", async () => {
        const w = await world();
        expect(await w.live.hasActiveRuns()).toBe(false);
        await w.put({ session: SID }); // fetching but no token
        expect(await w.live.hasActiveRuns()).toBe(false);
        await w.put({ update_token: UPDATE, session: SID });
        expect(await w.live.hasActiveRuns()).toBe(true); // fetching
        await w.live.onSave(SID, saving(1));
        expect(await w.live.hasActiveRuns()).toBe(true); // saving
        await w.relay(FIX.reading);
        expect(await w.live.hasActiveRuns()).toBe(false); // the device is reading
        await w.relay(FIX.ready);
        expect(await w.live.hasActiveRuns()).toBe(false);
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        expect(await w.live.hasActiveRuns()).toBe(true); // rendering
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "success", url: "https://m/x.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
        expect(await w.live.hasActiveRuns()).toBe(false);
    });
});

describe("cleanup", () => {
    it("drops runs older than 8 h or ended more than an hour ago, orphan index entries, old start tokens", async () => {
        const w = await world();
        await w.put({ session: SID });
        await w.put({ session: SID }, RUN2);
        const RUN3 = "11111111-2222-4333-8444-555555555555";
        await w.put({ session: SID }, RUN3);
        // RUN: just inside the ttl; RUN2: past it; RUN3: ended 61 minutes ago
        w.age({ createdAt: T0 - (LIVE_RUN_TTL_MS - 1000) }, RUN);
        w.age({ createdAt: T0 - LIVE_RUN_TTL_MS - 1 }, RUN2);
        w.age({ endedAt: T0 - LIVE_ENDED_TTL_MS - 1 }, RUN3);
        await w.live.putStartToken(KEY, JSON.stringify({ token: START, environment: "sandbox" }));
        await w.live.putStartToken(OTHER, JSON.stringify({ token: UPDATE, environment: "sandbox" }));
        w.startToken(OTHER)!.updatedAt = T0 - LIVE_START_TOKEN_TTL_MS - 1;
        w.kv.m.set("live:sid:qQ1wW2eE3rR4tT5yY6uU7i", ["gone-run"]); // an index entry without runs
        w.kv.m.set(`live:health:${OTHER}`, { badAt: T0 - 11 * 60_000, reason: "x" });
        await w.live.cleanup(T0);
        expect(w.run(RUN)).toBeDefined();
        expect(w.run(RUN2)).toBeUndefined();
        expect(w.run(RUN3)).toBeUndefined();
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN]);
        expect(w.kv.m.has("live:sid:qQ1wW2eE3rR4tT5yY6uU7i")).toBe(false);
        expect(w.startToken(KEY)).toBeDefined();
        expect(w.startToken(OTHER)).toBeUndefined();
        expect(w.kv.m.has(`live:health:${OTHER}`)).toBe(false);
        expect(LIVE_RUN_TTL_MS).toBe(8 * 3600_000);
        expect(LIVE_ENDED_TTL_MS).toBe(3600_000);
        expect(LIVE_START_TOKEN_TTL_MS).toBe(60 * 86_400_000);
    });
    it("a start token refreshed (PUT again) survives; one ended exactly an hour ago does too", async () => {
        const w = await world();
        await w.live.putStartToken(KEY, JSON.stringify({ token: START, environment: "sandbox" }));
        w.startToken()!.updatedAt = T0 - LIVE_START_TOKEN_TTL_MS;
        await w.put({ session: SID });
        w.age({ endedAt: T0 - LIVE_ENDED_TTL_MS });
        await w.live.cleanup(T0);
        expect(w.startToken()).toBeDefined();
        expect(w.run()).toBeDefined();
    });
    it("PUT /live/runs runs it too", async () => {
        const w = await world();
        await w.put({ session: SID }, RUN2);
        w.age({ createdAt: T0 - LIVE_RUN_TTL_MS - 5 }, RUN2);
        await w.put({ session: SID });
        expect(w.run(RUN2)).toBeUndefined();
        expect(w.kv.m.get(`live:sid:${SID}`)).toEqual([RUN]);
    });
});

describe("selftest (8.6)", () => {
    it("signs a JWT and sends one update to the sandbox host for the 64-zero token; answers the pinned shape", async () => {
        const w = await world({ apple: new Apple([bad(400, "BadDeviceToken")]) });
        const res = await w.live.selftest();
        expect(res.status).toBe(200);
        expect(res.body).toEqual({
            status: "success",
            configured: true,
            transport: "worker",
            host: "api.sandbox.push.apple.com",
            jwt: "ok",
            apns_status: 400,
            apns_reason: "BadDeviceToken",
        });
        expect(w.apple.hosts).toEqual(["api.sandbox.push.apple.com"]);
        expect(w.apple.pushes[0]!.token).toBe("0".repeat(64));
        expect(w.apple.calls[0]!.req.headers["apns-topic"]).toBe("com.capybaraharmony.cobalt.push-type.liveactivity");
        expect(w.apple.pushes[0]!.payload.aps.event).toBe("update");
        expect(JSON.stringify(res.body)).not.toMatch(/bearer|BEGIN|ey[A-Za-z0-9_-]{20}/);
        // it stored nothing
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("live:"))).toEqual([]);
    });
    it("a transport failure is `transport: <message>` with no status", async () => {
        const w = await world({ apple: new Apple([new Error("fetch failed")]) });
        expect((await w.live.selftest()).body).toMatchObject({ apns_status: null, apns_reason: "transport: fetch failed" });
    });
});

describe("failureKey: a port of ErrorMap.swift mapFailure", () => {
    const rows: [string, "saving" | "rendering", string][] = [
        ["error.api.fetch.empty", "saving", "fetchFailed"],
        ["error.api.fetch.fail", "rendering", "fetchFailed"],
        ["error.api.content.video.unavailable", "saving", "fetchFailed"],
        ["error.api.link.unsupported", "saving", "fetchFailed"],
        ["error.webp.no_video", "rendering", "fetchFailed"],
        ["error.webp.bad_source", "saving", "fetchFailed"],
        ["error.webp.download_failed", "rendering", "fetchFailed"],
        ["error.api.auth.key.missing", "saving", "keyMissing"],
        ["error.api.auth.key.invalid", "saving", "keyInvalid"],
        ["error.api.auth.key.not_api_key", "saving", "keyInvalid"],
        ["error.api.auth.key.not_found", "rendering", "keyInvalid"],
        ["error.studio.busy", "saving", "serverBusy"],
        ["error.studio.busy", "rendering", "serverBusy"],
        ["error.webp.busy", "rendering", "renderBusy"],
        ["error.webp.job_lost", "rendering", "renderLost"],
        ["error.webp.job_lost", "saving", "server"],
        ["error.studio.save_lost", "rendering", "renderLost"],
        ["error.studio.save_lost", "saving", "server"],
        ["error.studio.expired", "saving", "expired"],
        ["error.library.too_large", "saving", "tooLarge"],
        ["error.studio.too_large", "saving", "tooLarge"],
        ["error.webp.too_large", "rendering", "tooLarge"],
        ["error.webp.unsupported", "rendering", "unsupported"],
        ["error.library.unsupported", "saving", "unsupported"],
        ["error.studio.not_video", "saving", "unsupported"],
        ["error.studio.unavailable", "saving", "server"],
        ["error.webp.encode_failed", "rendering", "server"],
        ["error.webp.timeout", "saving", "server"],
        ["error.api.generic", "saving", "server"],
        ["error.something.new", "rendering", "server"],
        ["", "saving", "server"],
    ];
    it.each(rows)("%s while %s -> %s", (code, phase, key) => {
        expect(failureKey(code, phase)).toBe(key);
    });
    it("only produces names the app's PipelineFailure has", () => {
        const names = new Set(["noLink", "tooLarge", "fetchFailed", "unsupported", "serverBusy", "renderBusy", "renderLost", "expired", "keyMissing", "keyInvalid", "unreachable", "server"]);
        for (const [code, phase] of rows) expect(names.has(failureKey(code, phase))).toBe(true);
    });
});

describe("sanitizeState / canonical order", () => {
    it("reduces to the allow-list in a fixed order, drops unknown keys and nulls", () => {
        const s = sanitizeState({ code: "c", title: "t", packing: false, waking: true, since: 5, rail: 1, stage: "saving", extra: 1, bytes: null });
        expect(Object.keys(s!)).toEqual(["stage", "rail", "since", "waking", "packing", "title", "code"]);
    });
    it("sameState ignores key order", () => {
        expect(sameState({ stage: "fetching", rail: 0, since: 1, waking: false, packing: false }, { packing: false, waking: false, since: 1, rail: 0, stage: "fetching" })).toBe(true);
        expect(sameState(null, null)).toBe(false);
    });
    it("start and update payloads carry the state in canonical order", () => {
        const a = { run: RUN, input: "link" as const, service: "x", ref: "r", origin: "share" as const };
        const shuffled = { packing: false, since: 1, stage: "fetching", waking: false, rail: 0 } as LiveState;
        expect(Object.keys(updatePayload(shuffled, T0).aps["content-state"])).toEqual(["stage", "rail", "since", "waking", "packing"]);
        expect(Object.keys(startPayload(a, shuffled, T0).aps["content-state"])).toEqual(["stage", "rail", "since", "waking", "packing"]);
    });
});

describe("routes inside the Durable Object (handleLiveRoute)", () => {
    const call = async (w: World, method: string, path: string, body?: unknown, headers: Record<string, string> = { [KEY_ID_HEADER]: KEY }) =>
        handleLiveRoute(w.live, new Request(`https://do.internal${path}`, { method, headers, ...(body === undefined ? {} : { body: typeof body === "string" ? body : JSON.stringify(body) }) }));

    it("refuses a request without the key id header (403)", async () => {
        const w = await world();
        expect((await call(w, "PUT", `/live/runs/${RUN}`, reg(), {})).status).toBe(403);
        expect((await call(w, "GET", "/live/selftest", undefined, {})).status).toBe(403);
        expect(w.run()).toBeUndefined();
    });
    it("every route, with the key id: the statuses of 8.2", async () => {
        const w = await world();
        expect((await call(w, "PUT", "/live/start-token", { token: START, environment: "sandbox" })).status).toBe(204);
        expect((await call(w, "PUT", `/live/runs/${RUN}`, reg({ session: SID }))).status).toBe(200);
        expect((await call(w, "POST", `/live/runs/${RUN}/state`, { state: FIX.reading })).status).toBe(202);
        expect((await call(w, "POST", `/live/runs/${RUN}/state`, { state: { ...FIX.reading, stage: "saving" } })).status).toBe(409);
        expect((await call(w, "GET", "/live/selftest")).status).toBe(200);
        expect((await call(w, "DELETE", `/live/runs/${RUN}`)).status).toBe(204);
        expect((await call(w, "DELETE", "/live/start-token")).status).toBe(204);
        const noBody = await call(w, "DELETE", `/live/runs/${RUN}`);
        expect(await noBody.text()).toBe("");
    });
    it("a JSON body larger than 4096 bytes is a 400 (declared or not), not JSON is a 400", async () => {
        const w = await world();
        const big = JSON.stringify(reg({ pad: "x".repeat(5000) }));
        const res = await call(w, "PUT", `/live/runs/${RUN}`, big);
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.live.bad_request" } });
        expect((await call(w, "PUT", `/live/runs/${RUN}`, "nope")).status).toBe(400);
        expect((await call(w, "PUT", "/live/start-token", big)).status).toBe(400);
        expect((await call(w, "POST", `/live/runs/${RUN}/state`, big)).status).toBe(400);
    });
    it("anything else under /live is a 404", async () => {
        const w = await world();
        for (const [m, p] of [
            ["GET", "/live"], ["GET", "/live/"], ["GET", "/live/runs"], ["GET", `/live/runs/${RUN}`], ["PATCH", `/live/runs/${RUN}`],
            ["PUT", "/live/runs/not-a-uuid"], ["PUT", `/live/runs/${RUN.toUpperCase()}`], ["POST", `/live/runs/${RUN}`], ["PUT", `/live/runs/${RUN}/state`],
            ["POST", `/live/runs/${RUN}/other`], ["GET", "/live/start-token"], ["POST", "/live/selftest"], ["GET", "/live/other"], ["POST", `/live/runs/${RUN}/state/x`],
        ]) {
            expect((await call(w, m!, p!, m === "GET" ? undefined : {})).status, `${m} ${p}`).toBe(404);
        }
    });
});

// ---- review fixes (2026-10-02) ------------------------------------------------------------

const DONE_EVT = { kind: "success" as const, url: "https://media.capybaraharmony.com/PrEvIeW001.webp", bytes: 4500000, width: 480, height: 854, seconds: 10.1 };
const runId = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const withStartToken = (w: World, key = KEY, token = START) =>
    w.live.putStartToken(key, JSON.stringify({ token, environment: "sandbox" }));
const starts = (w: World) => w.apple.pushes.filter((p) => p.payload.aps.event === "start");

describe("finding 1: a start whose outcome is unknown is never re-sent", () => {
    it("a start that timed out (sent, no answer) is recorded before it leaves, answers start_unconfirmed, and a retried PUT sends no second start", async () => {
        let observed: unknown = "unset";
        let w!: World;
        const apple = new Apple([
            () => {
                observed = w.run()?.startAttemptedAt ?? null; // what the record says while the request is in flight
                throw new Error("timed out"); // transport failure after sending: unknown outcome
            },
        ]);
        w = await world({ apple });
        await withStartToken(w);
        const first = await w.put({ start: true });
        expect(observed).toBe(T0); // written BEFORE the request left
        expect(first.body).toEqual({ status: "success", pushing: false, started: false, reason: "start_unconfirmed" });
        expect(w.run()!.startedAt).toBeNull();
        expect(w.run()!.startAttemptedAt).toBe(T0);
        expect(starts(w)).toHaveLength(1);
        // a retry long after the 10 s window: still no second start (it could make two activities)
        w.tick(LIVE_START_MIN_GAP_MS * 6);
        const retry = await w.put({ start: true });
        expect(retry.body).toMatchObject({ started: false, reason: "start_unconfirmed" });
        expect(starts(w)).toHaveLength(1);
    });

    it("a start that provably never left (the transport could not be made ready) clears the marker: a retry is safe and goes", async () => {
        const apple = new Apple([ok()]);
        let wakes = 0;
        Object.assign(apple.transport, {
            prepare: async () => {
                if (wakes++ === 0) throw new Error("container failed to start");
            },
        });
        const w = await world({ apple });
        await withStartToken(w);
        const first = await w.put({ start: true });
        expect(first.body).toEqual({ status: "success", pushing: false, started: false });
        expect(w.apple.calls).toHaveLength(0); // nothing was sent
        expect(w.run()!.startAttemptedAt).toBeNull();
        w.tick(LIVE_START_MIN_GAP_MS);
        const second = await w.put({ start: true });
        expect(second.body).toEqual({ status: "success", pushing: true, started: true });
        expect(starts(w)).toHaveLength(1);
    });

    it("an Apple refusal (500) is not 'maybe delivered' either: the marker clears; a 429 and a 410 too", async () => {
        for (const a of [bad(500, null), bad(429, "TooManyRequests"), bad(410, "Unregistered")]) {
            const w = await world({ apple: new Apple([a]) });
            await withStartToken(w);
            await w.put({ start: true });
            expect(w.run()!.startAttemptedAt, String(a.status)).toBeNull();
        }
    });

    it("a successful start keeps its record (startedAt) and is honoured once", async () => {
        const w = await world();
        await withStartToken(w);
        expect((await w.put({ start: true })).body).toMatchObject({ started: true });
        expect(w.run()!.startedAt).toBe(T0);
        w.tick(LIVE_START_MIN_GAP_MS);
        expect((await w.put({ start: true })).body).toEqual({ status: "success", pushing: true, started: false });
        expect(starts(w)).toHaveLength(1);
    });
});

describe("finding 2: TooManyProviderTokenUpdates is a failure, not a silent loss", () => {
    it("a stage push answered 429 TooManyProviderTokenUpdates marks the key unhealthy (pushing:false) instead of vanishing", async () => {
        const w = await world();
        await w.armed();
        w.apple.script = [bad(429, "TooManyProviderTokenUpdates")];
        await w.live.onSave(SID, saving(100)); // a stage change
        expect(w.kv.m.get(`live:health:${KEY}`)).toMatchObject({ reason: "429 TooManyProviderTokenUpdates" });
        expect((await w.put({ session: SID })).body).toMatchObject({ pushing: false });
    });
});

describe("finding 3: helper mode keeps device-stage counters off the container", () => {
    const uploading = (bytes: number) => ({ ...FIX.uploading!, bytes });

    it("worker transport (control): device-stage counters are relayed, one a second", async () => {
        const w = await world();
        await w.armed({ state: uploading(1) });
        for (const b of [2, 3, 4]) {
            w.tick(1500);
            await w.relay(uploading(b));
        }
        expect(w.apple.pushes).toHaveLength(3);
    });

    it("APNS_VIA=helper: uploading / reading counters are stored but never pushed; stage changes, the end and catch-up still go", async () => {
        const w = await world({ via: "helper" });
        await w.armed({ state: uploading(1) }); // the catch-up push when the token arrives
        w.apple.calls.length = 0;
        for (const b of [2, 3, 4, 5]) {
            w.tick(1500);
            expect((await w.relay(uploading(b))).status).toBe(202);
        }
        expect(w.apple.calls).toHaveLength(0); // no containerFetch for a counter in a device stage
        expect(w.run()!.state.bytes).toBe(5); // the latest is kept for the next real push
        w.tick(1500);
        await w.relay({ ...FIX.reading!, framesDone: 1 }); // a stage change goes
        expect(w.apple.pushes).toHaveLength(1);
        expect(w.apple.pushes[0]!.priority).toBe(10);
        w.tick(1500);
        await w.relay({ ...FIX.reading!, framesDone: 2 }); // a reading counter: skipped
        expect(w.apple.pushes).toHaveLength(1);
        // the end still goes
        w.tick(1500);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.tick(1500);
        await w.live.onRender(SID, "J", DONE_EVT);
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["update", "update", "end"]);
        expect(w.run()!.endedAt).not.toBeNull();
    });

    it("APNS_VIA=helper: counters in a SERVER stage (saving, rendering) are pushed as usual", async () => {
        const w = await world({ via: "helper" });
        await w.armed();
        await w.live.onSave(SID, saving(100)); // stage change
        w.tick(1500);
        await w.live.onSave(SID, saving(200)); // counter in a server stage
        expect(w.apple.pushes.map((p) => p.priority)).toEqual([10, 5]);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.tick(1500);
        await w.live.onRender(SID, "J", { kind: "pending", phase: "decode", framesDone: 5, framesTotal: 50 });
        expect(w.apple.pushes.map((p) => p.priority)).toEqual([10, 5, 10, 5]);
    });
});

describe("finding 4: runs per key and start pushes are bounded", () => {
    it("the 17th run that has not ended is refused with 429 error.live.too_many_runs and stores nothing; another key is unaffected", async () => {
        const w = await world();
        for (let i = 1; i <= LIVE_MAX_OPEN_RUNS_PER_KEY; i++) expect((await w.put({}, runId(i))).status, `run ${i}`).toBe(200);
        const over = await w.put({}, runId(99));
        expect(over).toEqual({ status: 429, body: { status: "error", error: { code: "error.live.too_many_runs" } } });
        expect(w.run(runId(99))).toBeUndefined();
        expect(w.idx(runId(99))).toBeUndefined();
        // a run that exists is updated, not counted again
        expect((await w.put({ update_token: UPDATE }, runId(1))).status).toBe(200);
        // another key has its own allowance
        expect((await w.put({}, runId(100), OTHER)).status).toBe(200);
        // an ended run frees a slot of the open cap
        w.age({ endedAt: T0 }, runId(2));
        expect((await w.put({}, runId(99))).status).toBe(200);
    });

    it("concurrent registrations cannot overshoot the cap", async () => {
        const w = await world();
        const results = await Promise.all(Array.from({ length: 24 }, (_, i) => w.put({}, runId(i + 1))));
        expect(results.filter((r) => r.status === 200)).toHaveLength(LIVE_MAX_OPEN_RUNS_PER_KEY);
        expect(results.filter((r) => r.status === 429)).toHaveLength(24 - LIVE_MAX_OPEN_RUNS_PER_KEY);
        expect([...w.kv.m.keys()].filter((k) => k.startsWith(`live:idx:${KEY}:`))).toHaveLength(LIVE_MAX_OPEN_RUNS_PER_KEY);
    });

    it("ended runs kept for an hour count toward a total cap of 64 per key", async () => {
        const w = await world();
        let n = 0;
        for (let batch = 0; batch < LIVE_MAX_RUNS_PER_KEY / LIVE_MAX_OPEN_RUNS_PER_KEY; batch++) {
            const ids: string[] = [];
            for (let i = 0; i < LIVE_MAX_OPEN_RUNS_PER_KEY; i++) {
                const id = runId(++n);
                ids.push(id);
                expect((await w.put({}, id)).status, id).toBe(200);
            }
            for (const id of ids) w.age({ endedAt: T0 }, id);
        }
        const res = await w.put({}, runId(1000));
        expect(res.status).toBe(429);
        // an hour on, the cleanup frees them
        w.tick(LIVE_ENDED_TTL_MS + 1);
        await w.live.cleanup();
        expect((await w.put({}, runId(1000))).status).toBe(200);
    });

    it("a session's index holds at most 16 runs: the 17th registered for it is refused and indexed nowhere", async () => {
        const w = await world();
        for (let i = 1; i <= LIVE_MAX_RUNS_PER_SID; i++) {
            expect((await w.put({ session: SID }, runId(i))).status).toBe(200);
            w.age({ endedAt: T0 }, runId(i)); // ended runs stay indexed for an hour
        }
        expect((w.kv.m.get(`live:sid:${SID}`) as string[]).length).toBe(LIVE_MAX_RUNS_PER_SID);
        const over = await w.put({ session: SID }, runId(50));
        expect(over).toMatchObject({ status: 429, body: { error: { code: "error.live.too_many_runs" } } });
        expect(w.run(runId(50))).toBeUndefined();
        expect((w.kv.m.get(`live:sid:${SID}`) as string[]).length).toBe(LIVE_MAX_RUNS_PER_SID);
        // moving an existing run to a full session is refused too, and changes nothing
        await w.put({}, runId(60));
        const move = await w.put({ session: SID }, runId(60));
        expect(move.status).toBe(429);
        expect(w.run(runId(60))!.sid).toBeNull();
        // re-registering one that is already in the index is fine
        expect((await w.put({ session: SID }, runId(3))).status).toBe(200);
    });

    it("at most one push-to-start per key per 10 s: the second run gets start_rate_limited and sends nothing; later it goes", async () => {
        const w = await world();
        await withStartToken(w);
        expect((await w.put({ start: true }, runId(1))).body).toMatchObject({ started: true });
        const second = await w.put({ start: true }, runId(2));
        expect(second.body).toEqual({ status: "success", pushing: true, started: false, reason: "start_rate_limited" });
        expect(starts(w)).toHaveLength(1);
        expect(w.run(runId(2))!.startedAt).toBeNull();
        expect(w.run(runId(2))!.startAttemptedAt ?? null).toBeNull();
        w.tick(LIVE_START_MIN_GAP_MS - 1);
        expect((await w.put({ start: true }, runId(2))).body).toMatchObject({ reason: "start_rate_limited" });
        w.tick(1);
        expect((await w.put({ start: true }, runId(2))).body).toMatchObject({ started: true });
        expect(starts(w)).toHaveLength(2);
        // the window is per key
        await withStartToken(w, OTHER, UPDATE);
        expect((await w.put({ start: true }, runId(3), OTHER)).body).toMatchObject({ started: true });
    });

    it("concurrent start:true PUTs for different runs send exactly one start", async () => {
        const w = await world();
        await withStartToken(w);
        const rs = await Promise.all([1, 2, 3, 4].map((i) => w.put({ start: true }, runId(i))));
        expect(rs.filter((r) => (r.body as { started: boolean }).started)).toHaveLength(1);
        expect(starts(w)).toHaveLength(1);
    });

    it("a failed start also uses the window (a failing push is not a licence to hammer)", async () => {
        const w = await world({ apple: new Apple([bad(500, null), ok()]) });
        await withStartToken(w);
        await w.put({ start: true }, runId(1));
        expect((await w.put({ start: true }, runId(2))).body).toMatchObject({ reason: "start_rate_limited" });
        expect(w.apple.calls).toHaveLength(1);
    });

    it("hasActiveRuns and cleanup read the small index, never the run records", async () => {
        const w = await world();
        for (let i = 1; i <= 10; i++) await w.put({ update_token: UPDATE, session: SID, state: FETCHING }, runId(i));
        const reads: string[] = [];
        const get = w.kv.get.bind(w.kv);
        const list = w.kv.list.bind(w.kv);
        w.kv.get = (async (k: string) => (reads.push(`get ${k}`), get(k))) as typeof w.kv.get;
        w.kv.list = (async (o: { prefix: string }) => (reads.push(`list ${o.prefix}`), list(o))) as typeof w.kv.list;
        expect(await w.live.hasActiveRuns()).toBe(true);
        await w.live.cleanup();
        expect(reads.filter((r) => r.includes("live:run:"))).toEqual([]);
    });

    it("the index entry follows the run: active only with a token on a server step, gone with the run", async () => {
        const w = await world();
        await w.put({ session: SID }, RUN);
        expect(w.idx()).toMatchObject({ run: RUN, keyId: KEY, sid: SID, endedAt: null, active: false, retryAt: null });
        expect(await w.live.hasActiveRuns()).toBe(false);
        await w.put({ session: SID, update_token: UPDATE });
        expect(w.idx()!.active).toBe(true);
        expect(await w.live.hasActiveRuns()).toBe(true);
        await w.relay(FIX.reading);
        expect(w.idx()!.active).toBe(false); // a device step: nothing to wait on
        await w.live.deleteRun(KEY, RUN);
        expect(w.idx()).toBeUndefined();
        expect(w.run()).toBeUndefined();
    });
});

describe("finding 5: an outage does not make every poll retry a counter", () => {
    it("while unhealthy counters are skipped (no waiting on a failing push); stage changes and the end still go", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100)); // stage change, ok
        w.apple.script = [bad(500, null)];
        w.tick(2000);
        await w.live.onSave(SID, saving(200)); // counter: tried once, fails, key unhealthy
        expect(w.apple.calls).toHaveLength(2);
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(true);
        for (const b of [300, 400, 500]) {
            w.tick(2000);
            await w.live.onSave(SID, saving(b)); // skipped
        }
        expect(w.apple.calls).toHaveLength(2);
        expect(w.run()!.state.bytes).toBe(500); // still stored
        // a stage change still goes (and fails: nothing changes about the outage)
        w.tick(2000);
        await w.live.onRender(SID, "J", { kind: "accepted" });
        expect(w.apple.calls).toHaveLength(3);
        // the end goes once Apple answers again
        w.apple.script = [ok()];
        w.tick(2000);
        await w.live.onRender(SID, "J", DONE_EVT);
        expect(w.apple.pushes.at(-1)!.payload.aps.event).toBe("end");
        expect(w.run()!.endedAt).not.toBeNull();
    });

    it("counters resume once the 10 minute window has passed", async () => {
        const w = await world();
        await w.armed();
        await w.live.onSave(SID, saving(100));
        w.apple.script = [bad(503, null), ok()];
        w.tick(2000);
        await w.live.onSave(SID, saving(200)); // fails
        const n = w.apple.calls.length;
        w.tick(9 * 60_000);
        await w.live.onSave(SID, saving(300)); // still inside the window
        expect(w.apple.calls).toHaveLength(n);
        w.tick(60_000);
        await w.live.onSave(SID, saving(400)); // window over
        expect(w.apple.calls).toHaveLength(n + 1);
    });
});

describe("finding 6: a success does not write to storage unless there is a health record to remove", () => {
    function counted(w: World) {
        const ops: string[] = [];
        const put = w.kv.put.bind(w.kv);
        const del = w.kv.delete.bind(w.kv);
        w.kv.put = async (k, v) => (ops.push(`put ${k}`), put(k, v));
        w.kv.delete = async (k) => (ops.push(`delete ${k}`), del(k));
        return ops;
    }
    it("many successful pushes: no health delete at all", async () => {
        const w = await world();
        await w.armed();
        const ops = counted(w);
        for (let i = 1; i <= 6; i++) {
            w.tick(1500);
            await w.live.onSave(SID, saving(i * 100));
        }
        expect(w.apple.calls.length).toBeGreaterThanOrEqual(6);
        expect(ops.filter((o) => o.includes("live:health:"))).toEqual([]);
    });
    it("after a failure the first success deletes the record once; later successes do not touch it", async () => {
        const w = await world();
        await w.armed();
        w.apple.script = [bad(500, null), ok()];
        await w.live.onSave(SID, saving(100)); // stage change fails
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(true);
        const ops = counted(w);
        w.tick(1000);
        await w.live.onSave(SID, saving(200)); // stage still differs from sent: retried as a stage change, ok
        for (let i = 3; i <= 6; i++) {
            w.tick(1500);
            await w.live.onSave(SID, saving(i * 100));
        }
        expect(ops.filter((o) => o === `delete live:health:${KEY}`)).toHaveLength(1);
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(false);
    });
    it("a record written by an earlier instance is still found and removed by the first success", async () => {
        const w = await world();
        w.kv.m.set(`live:health:${KEY}`, { badAt: T0, reason: "x" }); // written before this instance existed
        await w.armed();
        expect(w.kv.m.has(`live:health:${KEY}`)).toBe(false); // the catch-up success removed it
    });
});

describe("finding 7: nothing is pushed to a run that has ended", () => {
    it("a PUT with a new update token on an ended run does not resend the end", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.tick(2000);
        await w.live.onRender(SID, "J", DONE_EVT);
        expect(w.run()!.endedAt).not.toBeNull();
        const n = w.apple.calls.length;
        const res = await w.put({ session: SID, update_token: "ee".repeat(32) });
        expect(res.status).toBe(200);
        expect(w.apple.calls).toHaveLength(n);
        expect(w.run()!.updateToken).toBe("ee".repeat(32));
    });
    it("an ended run whose end never got accepted (its token was dead, so it was dropped) is not sent an end by a new token", async () => {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.apple.script = [bad(410, "Unregistered")];
        w.tick(2000);
        await w.live.onRender(SID, "J", DONE_EVT); // 410: token dropped, the run ends, `sent` stays behind
        expect(w.run()).toMatchObject({ updateToken: null });
        expect(w.run()!.endedAt).not.toBeNull();
        expect(w.run()!.sent!.stage).not.toBe("done");
        const n = w.apple.calls.length;
        const res = await w.put({ session: SID, update_token: "ee".repeat(32) }); // state differs from sent, a token arrives
        expect(res.status).toBe(200);
        expect(w.apple.calls).toHaveLength(n); // ... and still nothing is pushed to an ended run
        w.tick(2000);
        await w.relay(FIX.reading);
        expect(w.apple.calls).toHaveLength(n);
    });
    it("start:true on an ended run (its token was dropped) sends no start", async () => {
        const w = await world();
        await withStartToken(w);
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.apple.script = [bad(410, "Unregistered")];
        w.tick(2000);
        await w.live.onRender(SID, "J", DONE_EVT); // the end hits a dead token: dropped, ended
        expect(w.run()).toMatchObject({ updateToken: null });
        expect(w.run()!.endedAt).not.toBeNull();
        const n = w.apple.calls.length;
        w.tick(LIVE_START_MIN_GAP_MS);
        expect((await w.put({ session: SID, start: true })).body).toEqual({ status: "success", pushing: true, started: false });
        expect(w.apple.calls).toHaveLength(n);
    });
});

describe("finding 8: a failed end is retried by the sweep, bounded, with backoff", () => {
    async function endFailed(script: AppleStep[] = [bad(500, null)]) {
        const w = await world();
        await w.armed({ state: FIX.ready });
        await w.live.onRender(SID, "J", { kind: "accepted" });
        w.apple.script = script;
        w.apple.calls.length = 0;
        w.tick(2000);
        await w.live.onRender(SID, "J", DONE_EVT); // the end fails; nobody polls again
        return w;
    }

    it("the failed end is kept pending: tries and a retry time are recorded, the index says when, and the sweep is armed", async () => {
        const w = await endFailed();
        expect(w.apple.calls).toHaveLength(1);
        expect(w.run()).toMatchObject({ endedAt: null, endTries: 1, endRetryAt: w.clock.t + LIVE_END_RETRY_DELAYS_MS[0]! });
        expect(w.idx()!.retryAt).toBe(w.clock.t + LIVE_END_RETRY_DELAYS_MS[0]!);
        expect(w.sweeps).toHaveLength(1);
    });

    it("retryEnds sends nothing before the retry is due, then sends the end and finishes the run", async () => {
        const w = await endFailed([bad(500, null), ok()]);
        const due = LIVE_END_RETRY_DELAYS_MS[0]!;
        w.tick(due - 1);
        expect(await w.live.retryEnds()).toEqual({ nextInMs: 1 });
        expect(w.apple.calls).toHaveLength(1);
        w.tick(1);
        expect(await w.live.retryEnds()).toEqual({ nextInMs: null });
        expect(w.apple.pushes.map((p) => p.payload.aps.event)).toEqual(["end", "end"]);
        expect(w.run()).toMatchObject({ endedAt: w.clock.t });
        expect(w.run()!.endRetryAt).toBeUndefined();
        expect(w.idx()!.retryAt).toBeNull();
        // done: nothing left to retry
        w.tick(60_000);
        expect(await w.live.retryEnds()).toEqual({ nextInMs: null });
        expect(w.apple.calls).toHaveLength(2);
    });

    it("bounded: with Apple down the whole time there are 3 retries over about a minute, then none", async () => {
        const w = await endFailed([bad(503, null)]);
        const t0 = w.clock.t;
        let nextInMs: number | null = LIVE_END_RETRY_DELAYS_MS[0]!;
        const attempts = [w.apple.calls.length];
        for (let guard = 0; guard < 10 && nextInMs !== null; guard++) {
            w.tick(nextInMs);
            ({ nextInMs } = await w.live.retryEnds());
            attempts.push(w.apple.calls.length);
        }
        expect(attempts).toEqual([1, 2, 3, 4]); // the first try plus three retries
        expect(w.clock.t - t0).toBe(LIVE_END_RETRY_DELAYS_MS.reduce((a, b) => a + b, 0)); // 5 + 15 + 40 s
        expect(w.clock.t - t0).toBeLessThanOrEqual(60_000); // about a minute in all
        expect(nextInMs).toBeNull();
        expect(w.run()).toMatchObject({ endedAt: null, endRetryAt: null });
        w.tick(10 * 60_000);
        expect(await w.live.retryEnds()).toEqual({ nextInMs: null });
        expect(w.apple.calls).toHaveLength(4);
    });

    it("a client poll inside the backoff does not re-send (nor burn the retries); after it, it does", async () => {
        const w = await endFailed([bad(500, null), ok()]);
        w.tick(1000);
        await w.live.onRender(SID, "J", DONE_EVT);
        expect(w.apple.calls).toHaveLength(1);
        expect(w.run()!.endTries).toBe(1);
        w.tick(LIVE_END_RETRY_DELAYS_MS[0]!);
        await w.live.onRender(SID, "J", DONE_EVT);
        expect(w.apple.calls).toHaveLength(2);
        expect(w.run()!.endedAt).not.toBeNull();
    });

    it("a 429 end (Apple throttling) is retried too; a dead token (410) ends the run and nothing is retried", async () => {
        const w = await endFailed([bad(429, "TooManyRequests"), ok()]);
        expect(w.run()).toMatchObject({ endedAt: null, endTries: 1 });
        w.tick(LIVE_END_RETRY_DELAYS_MS[0]!);
        await w.live.retryEnds();
        expect(w.run()!.endedAt).not.toBeNull();

        const dead = await endFailed([bad(410, "Unregistered")]);
        expect(dead.run()).toMatchObject({ updateToken: null });
        expect(dead.run()!.endedAt).not.toBeNull();
        expect(await dead.live.retryEnds()).toEqual({ nextInMs: null });
    });

    it("a run deleted meanwhile is not retried", async () => {
        const w = await endFailed();
        await w.live.deleteRun(KEY, RUN);
        w.tick(60_000);
        expect(await w.live.retryEnds()).toEqual({ nextInMs: null });
    });

    it("unconfigured APNs never retries anything", async () => {
        const w = await world({ configured: false });
        expect(await w.live.retryEnds()).toEqual({ nextInMs: null });
    });
});
