// The swarm Live Activity (APP-API-CONTRACT.md 61.5): the push-start when a plan is stored, the app's update token, the
// throttle on counters, the end (at once for a declined or expired plan), the sweep's watch, and the routes inside the
// Durable Object. Apple is a script; the swarm is real rows in D1 on node:sqlite.
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import { KEY_ID_HEADER } from "../src/headers";
import { JOB_START_PREFIX } from "../src/live";
import { SWARM_LIVE_MIN_GAP_MS, SWARM_LIVE_PREFIX, SWARM_LIVE_REFRESH_MS, SwarmLiveService, decideSwarmPush, handleSwarmLiveRoute, isSwarmLiveRoute, swarmLiveInput, type SwarmLiveRecord } from "../src/swarm-live";
import { LIVE_RUN_REGEX } from "../src/registry/ops/live";
import { jobOfSwarm } from "../src/job-live";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Apple, bad, makePem } from "./apns-fakes";
import { MemoryKV } from "./studio-fakes";

const T0 = 1_800_000_000_000;
const ID = "Sw4rmIdSw4rmId01";
const START = "aa".repeat(40);
const UPDATE = "bb".repeat(40);
const INTERNAL = "internal-key";

let pem: string;
beforeAll(async () => {
    pem = await makePem();
});

let db: FakeD1;
beforeEach(() => {
    db = createFakeD1();
    // device sessions (Harmony's apps) may hold an island token; "key-other" is a client key that did not plan the swarm
    for (const [id, kind] of [["key-phone", "session"], ["key-mac", "session"], ["k", "session"], ["key-other", "key"]] as const) {
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at, kind) VALUES (?, ?, ?, 'x', 0, ?)").run(id, id, `hash-${id}`, kind);
    }
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-claude", "claude code", "h1", "abcd1234", 1);
});

function addSwarm(over: Record<string, unknown> = {}, tasks = ["queued", "queued", "queued"]) {
    const r = { id: ID, key_id: "key-claude", name: "clean emote names", mode: "propose", status: "awaiting_approval", expires_at: T0 + 3_600_000, ...over };
    db.raw
        .prepare(
            `INSERT INTO swarms (id, key_id, name, mode, spec, spec_hash, status, item_count, task_count, est_low, est_high, cap_usd, created_at, updated_at, expires_at)
             VALUES (?, ?, ?, ?, '{}', 'a1b2c3d4e5f60718', ?, 9, ?, 0.12, 0.4, 2, ?, ?, ?)`,
        )
        .run(r.id, r.key_id, r.name, r.mode, r.status, tasks.length, T0, T0, r.expires_at);
    tasks.forEach((s, i) => db.raw.prepare("INSERT INTO swarm_tasks (swarm, idx, items, status) VALUES (?, ?, '[]', ?)").run(ID, i, s));
}
const set = (sql: string, ...args: unknown[]) => db.raw.prepare(sql).run(...(args as never[]));

function world(opts: { configured?: boolean; startToken?: boolean } = {}) {
    let t = T0;
    const apple = new Apple();
    const storage = new MemoryKV();
    const apns =
        opts.configured === false
            ? null
            : new ApnsClient({ keyP8: pem, keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "com.capybaraharmony.cobalt", via: "worker", transport: apple.transport, now: () => t, log: () => {} });
    let sweeps = 0;
    const service = new SwarmLiveService({ storage, db: db as never, now: () => t, apns, scheduleSweep: async () => void sweeps++ });
    const route = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
        handleSwarmLiveRoute(service, new Request(`https://do.internal${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }), INTERNAL);
    const internal = { "x-internal-key": INTERNAL };
    const keyed = (k: string) => ({ [KEY_ID_HEADER]: k });
    const rec = () => storage.get<SwarmLiveRecord>(`${SWARM_LIVE_PREFIX}${ID}`);
    return { apple, storage, service, route, internal, keyed, rec, tick: (ms: number) => (t += ms), now: () => t, sweeps: () => sweeps };
}

async function withStartToken(w: ReturnType<typeof world>, key = "key-phone", updatedAt = T0) {
    await w.storage.put(`${JOB_START_PREFIX}${key}`, { token: START, env: "production", updatedAt });
}

describe("the swarm as the island reads it", () => {
    it("reads the row, the planner's name, the grid letters and the change counts", async () => {
        addSwarm({ status: "running" }, ["done", "running", "waiting", "failed", "skipped", "queued"]);
        set(
            `INSERT INTO swarm_changes (swarm, n, task, op, args, keep, status, clash) VALUES
               (?1, 1, 0, 'x', '{}', 1, 'proposed', NULL), (?1, 2, 0, 'x', '{}', 1, 'proposed', 'dup'), (?1, 3, 0, 'x', '{}', 0, 'proposed', NULL),
               (?1, 4, 1, 'x', '{}', 1, 'done', NULL), (?1, 5, 1, 'x', '{}', 1, 'failed', NULL)`,
            ID,
        );
        const s = (await swarmLiveInput(db as never, ID))!;
        expect(s).toMatchObject({ planner: "claude code", cells: "drwfsq", changes: { total: 5, kept: 4, open: 3, clashes: 1, done: 1, failed: 1 } });
        expect(await swarmLiveInput(db as never, "NoSuchSwarm00000")).toBeNull();
        set("UPDATE swarms SET key_id = 'chat:thread01' WHERE id = ?", ID);
        expect((await swarmLiveInput(db as never, ID))!.planner).toBe("chat");
    });
});

describe("the service", () => {
    it("push-starts on the newest non-chat device when a plan is stored, once", async () => {
        addSwarm();
        const w = world();
        await withStartToken(w, "key-old", T0 - 60_000);
        await withStartToken(w, "key-phone", T0 - 1000);
        await w.storage.put(`${JOB_START_PREFIX}chat:thread01`, { token: "cc".repeat(40), env: "production", updatedAt: T0 });
        expect(await w.service.start(ID)).toEqual({ started: true });
        expect(w.apple.pushes).toHaveLength(1);
        const p = w.apple.pushes[0]!;
        expect(p.token).toBe(START);
        expect(p.payload.aps).toMatchObject({
            event: "start",
            "attributes-type": "CobaltJobActivityAttributes",
            attributes: { id: `swarm:${ID}`, kind: "swarm", agent: true, open: `cobalt-apple://swarm/${ID}` },
            "content-state": { phase: "waiting", actions: ["approve", "decline"], hash: "a1b2c3d4e5f60718", cells: "qqq" },
            alert: { body: "claude code asks to run a swarm" },
        });
        expect(await w.rec()).toMatchObject({ keyId: "key-phone", token: null, startedAt: T0 });
        expect(w.sweeps()).toBe(1);
        // a second start for the same open plan sends nothing
        expect(await w.service.start(ID)).toEqual({ started: false, reason: "open" });
        expect(w.apple.pushes).toHaveLength(1);
    });

    it("starts nothing without APNs, without a start token, or for a swarm that is not waiting", async () => {
        addSwarm();
        expect(await world({ configured: false }).service.start(ID)).toEqual({ started: false, reason: "not_configured" });
        const w = world();
        expect(await w.service.start(ID)).toEqual({ started: false, reason: "no_start_token" });
        set("UPDATE swarms SET status = 'running' WHERE id = ?", ID);
        await withStartToken(w);
        expect(await w.service.start(ID)).toEqual({ started: false, reason: "not_waiting" });
        expect(w.apple.calls).toHaveLength(0);
    });

    it("a refused start token is dropped", async () => {
        addSwarm();
        const w = world();
        await withStartToken(w);
        w.apple.script = [bad(410, "Unregistered")];
        expect(await w.service.start(ID)).toEqual({ started: false });
        expect(await w.storage.get(`${JOB_START_PREFIX}key-phone`)).toBeUndefined();
        expect((await w.rec())!.endedAt).toBe(T0);
    });

    it("the update token: a catch-up push, then majors at once and counters at most every 10 s", async () => {
        addSwarm();
        const w = world();
        await withStartToken(w);
        await w.service.start(ID);
        w.tick(1000);
        // approved before the app reported the token: the catch-up shows the running swarm
        set("UPDATE swarms SET status = 'running', approved_at = ? WHERE id = ?", T0 + 500, ID);
        set("UPDATE swarm_tasks SET status = 'running' WHERE swarm = ? AND idx = 0", ID);
        const put = await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("key-phone"));
        expect(await put.json()).toEqual({ status: "success", pushing: true });
        expect(w.apple.pushes).toHaveLength(2);
        expect(w.apple.pushes[1]).toMatchObject({ token: UPDATE, priority: 10 });
        expect(w.apple.pushes[1]!.payload.aps).toMatchObject({ event: "update", "content-state": { phase: "working", step: 1, actions: ["stop"], cells: "rqq" } });
        // an agent done 2 s later: a counter, held back
        w.tick(2000);
        set("UPDATE swarm_tasks SET status = 'done' WHERE swarm = ? AND idx = 0", ID);
        expect(await w.service.push(ID)).toEqual({ pushed: false });
        expect((await w.rec())!.checkAt).toBe(T0 + 1000 + SWARM_LIVE_MIN_GAP_MS);
        // the sweep's watch sends it once the gap passed, at the low priority
        w.tick(SWARM_LIVE_MIN_GAP_MS);
        expect((await w.service.watch()).nextInMs).toBe(SWARM_LIVE_REFRESH_MS);
        expect(w.apple.pushes).toHaveLength(3);
        expect(w.apple.pushes[2]).toMatchObject({ priority: 5 });
        expect(w.apple.pushes[2]!.payload.aps["content-state"]).toMatchObject({ headline: "1 of 3 agents done", cells: "dqq" });
        // nothing changed for 2 minutes: the same state again with a fresh stale-date
        w.tick(SWARM_LIVE_REFRESH_MS);
        await w.service.watch();
        expect(w.apple.pushes).toHaveLength(4);
        expect(w.apple.pushes[3]!.payload.aps["stale-date"]).toBe(Math.floor(w.now() / 1000) + 180);
        // a phase change (stop pressed) goes at once
        w.tick(1000);
        set("UPDATE swarms SET status = 'stopping' WHERE id = ?", ID);
        expect(await w.service.push(ID)).toEqual({ pushed: true });
        expect(w.apple.pushes[4]!.payload.aps["content-state"]).toMatchObject({ headline: "stopping" });
        expect(w.apple.pushes[4]!.payload.aps["content-state"].actions).toBeUndefined();
    });

    it("the end: a finished swarm stays 60 s with an alert; the record is done and the watch forgets it", async () => {
        addSwarm({ status: "running", mode: "read" }, ["done", "done"]);
        const w = world();
        await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, env: "sandbox" }, w.keyed("key-mac"));
        w.tick(30_000);
        set("UPDATE swarms SET status = 'done', finished_at = ?, reduce_result = 'all clean' WHERE id = ?", w.now(), ID);
        expect(await w.service.push(ID)).toEqual({ pushed: true });
        const end = w.apple.pushes.at(-1)!;
        expect(end.payload.aps).toMatchObject({ event: "end", "dismissal-date": Math.floor(w.now() / 1000) + 60, alert: { title: "swarm done" }, "content-state": { phase: "done", detail: "all clean" } });
        expect((await w.rec())!.endedAt).toBe(w.now());
        expect(await w.service.push(ID)).toEqual({ pushed: false });
        w.tick(2 * 60 * 60 * 1000);
        expect((await w.service.watch()).nextInMs).toBeNull();
        expect(await w.rec()).toBeUndefined();
    });

    it("a plan nobody approved ends at once when its hour runs out, and a declined one at once too", async () => {
        addSwarm();
        const w = world();
        await withStartToken(w);
        await w.service.start(ID);
        await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("key-phone"));
        const before = w.apple.pushes.length;
        // the watch comes back at the plan's hour (or the keep-alive, whichever is first)
        expect((await w.service.watch()).nextInMs).toBe(SWARM_LIVE_REFRESH_MS);
        w.tick(3_600_000);
        await w.service.watch();
        const end = w.apple.pushes.at(-1)!;
        expect(w.apple.pushes.length).toBeGreaterThan(before);
        expect(end.payload.aps).toMatchObject({ event: "end", "dismissal-date": Math.floor(w.now() / 1000), "content-state": { headline: "expired" } });
        expect(end.payload.aps.alert).toBeUndefined();

        // declined
        const w2 = world();
        set("UPDATE swarms SET status = 'declined', finished_at = ? WHERE id = ?", T0 + 5000, ID);
        await w2.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w2.keyed("key-phone"));
        expect(w2.apple.pushes[0]!.payload.aps).toMatchObject({ event: "end", "dismissal-date": Math.floor(T0 / 1000), "content-state": { headline: "declined" } });
    });

    it("decides: nothing when unchanged, a catch-up always", () => {
        addSwarm();
        const input = { status: "running" as const, expires_at: null };
        const s = {
            id: ID, name: "x", mode: "read" as const, status: "running" as const, apply_status: "none" as const, spec_hash: "h", planner: "p", est_low: 0, est_high: 0, spent_usd: 0, cap_usd: 1, error: null, reduce: null,
            created_at: T0, approved_at: T0, finished_at: null, expires_at: null, cells: "rq", changes: { total: 0, kept: 0, open: 0, clashes: 0, done: 0, failed: 0 },
        };
        const job = jobOfSwarm(s, T0);
        expect(decideSwarmPush({ sent: job.state, sentAt: T0 }, job, input, T0 + 1000)).toBeNull();
        expect(decideSwarmPush({ sent: job.state, sentAt: T0 }, job, input, T0 + 1000, true)).toMatchObject({ event: "update", priority: 10 });
    });
});

describe("the routes", () => {
    it("start and push need the internal key; the token needs a key id, a good body, and never a chat key", async () => {
        addSwarm();
        const w = world();
        expect((await w.route("POST", `/live/swarms/${ID}/start`)).status).toBe(403);
        expect((await w.route("POST", `/live/swarms/${ID}/push`, undefined, { "x-internal-key": "nope" })).status).toBe(403);
        expect(await (await w.route("POST", `/live/swarms/${ID}/push`, undefined, w.internal)).json()).toEqual({ status: "success", pushed: false });
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" })).status).toBe(403);
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: "nothex", environment: "production" }, w.keyed("k"))).status).toBe(400);
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "staging" }, w.keyed("k"))).status).toBe(400);
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("chat:thread01"))).status).toBe(404);
        // another client key may not take (or drop) the island; the key that planned the swarm may
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("key-other"))).status).toBe(404);
        expect((await w.route("DELETE", `/live/swarms/${ID}`, undefined, w.keyed("key-other"))).status).toBe(404);
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("key-claude"))).status).toBe(200);
        expect((await w.route("DELETE", `/live/swarms/${ID}`, undefined, w.keyed("key-claude"))).status).toBe(200);
        expect((await w.route("PUT", `/live/swarms/NoSuchSwarm00000`, { token: UPDATE, environment: "production" }, w.keyed("k"))).status).toBe(404);
        expect((await w.route("GET", `/live/swarms/${ID}`, undefined, w.keyed("k"))).status).toBe(404);
        expect((await w.route("PUT", `/live/swarms/bad`, { token: UPDATE, environment: "production" }, w.keyed("k"))).status).toBe(404);
        expect((await w.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, w.keyed("k"))).status).toBe(200);
        expect(await (await w.route("DELETE", `/live/swarms/${ID}`, undefined, w.keyed("k"))).json()).toEqual({ status: "success" });
        expect(await w.rec()).toBeUndefined();
        // without APNs the token is taken and nothing is sent
        const off = world({ configured: false });
        expect(await (await off.route("PUT", `/live/swarms/${ID}`, { token: UPDATE, environment: "production" }, off.keyed("k"))).json()).toEqual({ status: "success", pushing: false, reason: "not_configured" });
    });

    it("the app's run form: PUT/DELETE /live/runs/swarm:<id> is the same token route (update_token or token)", async () => {
        addSwarm();
        const w = world();
        expect(LIVE_RUN_REGEX.test(`swarm:${ID}`) && LIVE_RUN_REGEX.test("0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11")).toBe(true);
        expect(LIVE_RUN_REGEX.test("swarm:short") || LIVE_RUN_REGEX.test(`swarm:${ID}x`)).toBe(false);
        expect(isSwarmLiveRoute(`/live/runs/swarm:${ID}`) && !isSwarmLiveRoute("/live/runs/0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11")).toBe(true);
        const put = await w.route("PUT", `/live/runs/swarm:${ID}`, { update_token: UPDATE, environment: "production", attributes: {}, state: {} }, w.keyed("key-phone"));
        expect(await put.json()).toEqual({ status: "success", pushing: true });
        expect((await w.rec())!.token).toBe(UPDATE);
        // the internal routes and a state relay are never reached through the run form
        expect((await w.route("POST", `/live/runs/swarm:${ID}/push`, undefined, w.internal)).status).toBe(404);
        expect((await w.route("POST", `/live/runs/swarm:${ID}/state`, {}, w.keyed("key-phone"))).status).toBe(404);
        expect(await (await w.route("DELETE", `/live/runs/swarm:${ID}`, undefined, w.keyed("key-phone"))).json()).toEqual({ status: "success" });
        expect(await w.rec()).toBeUndefined();
    });
});
