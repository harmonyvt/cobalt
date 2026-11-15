// The swarm Live Activity (APP-API-CONTRACT.md 61.5, apple/CONTRACT-SWARMS.md 4): a `swarm` job island on Harmony's newest
// device, push-started when a plan is stored, with approve / decline / stop / check / apply buttons that the app's intents
// answer. Lives in the one `main` Durable Object next to live.ts, edit-live.ts and chat-live.ts, so every APNs push comes
// from one place with one provider token. Free of Cloudflare imports so it runs under plain node in the tests.
//
// The words are job-live.ts `jobOfSwarm`; this file reads the swarm from D1, decides what goes out and when, and keeps the
// one record per swarm:
//   live:swarm:<id>   SwarmLiveRecord
//
// Routes (inside the Durable Object):
//   PUT    /live/swarms/<id>        keyed: {"token": "<hex>", "environment": "sandbox"|"production"} the started activity's token
//   DELETE /live/swarms/<id>        keyed: the app ended the activity itself
//   POST   /live/swarms/<id>/start  x-internal-key: a plan was stored (or retried): push-start the island
//   POST   /live/swarms/<id>/push   x-internal-key: the swarm moved: push when it changed enough
// The sweep's quiet pass calls `watch`: plans that expire, keep-alive refreshes, throttled counters.

import type { ApnsClient, ApnsPush, Environment } from "./apns";
import { KEY_ID_HEADER } from "./headers";
import { JOB_ATTRIBUTES_TYPE, JOB_STALE_S, asJobPayload, canonicalJob, isJobTerminal, jobOfSwarm, swarmEndsAtOnce, type Job, type JobState, type SwarmLiveInput } from "./job-live";
import { JOB_START_PREFIX, LIVE_AGENT_MAX_DEVICES, LIVE_START_TOKEN_TTL_MS, TOKEN_REGEX, type StartToken } from "./live";
import type { KV } from "./webp";

export const SWARM_LIVE_PREFIX = "live:swarm:";
export const SWARM_LIVE_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const SWARM_LIVE_MAX_BODY = 1024;
// A counter (an agent done, a change applied) goes at most this often; a phase, step or button change goes at once.
export const SWARM_LIVE_MIN_GAP_MS = 10_000;
// Nothing pushed for this long while the island is open: the same state again with a fresh stale-date (JOB_STALE_S is 180 s).
export const SWARM_LIVE_REFRESH_MS = 120_000;
// A record is dropped after this long, whatever it shows.
export const SWARM_LIVE_TTL_MS = 8 * 60 * 60 * 1000;
export const SWARM_LIVE_DISMISS_DONE_S = 60;
export const SWARM_LIVE_DISMISS_FAILED_S = 300;

export type SwarmLiveRecord = {
    swarm: string;
    keyId: string;
    env: Environment;
    // the activity's update token, once the app reported it
    token: string | null;
    sent: JobState | null;
    sentAt: number;
    createdAt: number;
    startedAt: number | null;
    // when `watch` should look again (a throttled counter, a refresh, the plan's hour)
    checkAt: number | null;
    // the end went out (or nothing can be sent any more): the record waits for the cleanup
    endedAt: number | null;
};

const secs = (ms: number) => Math.floor(ms / 1000);
const same = (a: JobState | null, b: JobState) => a !== null && JSON.stringify(canonicalJob(a)) === JSON.stringify(canonicalJob(b));

// ---- D1 --------------------------------------------------------------------------------------------------------------

// The swarm as the island draws it, or null when it is gone (or the tables are not there).
export async function swarmLiveInput(db: D1Database, id: string): Promise<SwarmLiveInput | null> {
    let row: (Omit<SwarmLiveInput, "planner" | "cells" | "changes" | "reduce"> & { key_id: string; reduce_result: string | null; name_key: string | null }) | null;
    try {
        row = await db
            .prepare(
                `SELECT s.id, s.name, s.mode, s.status, s.apply_status, s.spec_hash, s.est_low, s.est_high, s.spent_usd, s.cap_usd, s.error, s.reduce_result,
                        s.created_at, s.approved_at, s.finished_at, s.expires_at, s.key_id, k.name AS name_key
                   FROM swarms s LEFT JOIN api_keys k ON k.id = s.key_id WHERE s.id = ?1`,
            )
            .bind(id)
            .first();
    } catch {
        return null;
    }
    if (!row) return null;
    const [cells, changes] = await Promise.all([
        db.prepare("SELECT status FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx").bind(id).all<{ status: string }>(),
        row.mode === "propose"
            ? db
                  .prepare(
                      `SELECT COUNT(*) AS total, COALESCE(SUM(keep), 0) AS kept,
                              COALESCE(SUM(CASE WHEN keep = 1 AND status <> 'done' THEN 1 ELSE 0 END), 0) AS open,
                              COALESCE(SUM(CASE WHEN keep = 1 AND status <> 'done' AND clash IS NOT NULL THEN 1 ELSE 0 END), 0) AS clashes,
                              COALESCE(SUM(CASE WHEN keep = 1 AND status = 'done' THEN 1 ELSE 0 END), 0) AS done,
                              COALESCE(SUM(CASE WHEN keep = 1 AND status = 'failed' THEN 1 ELSE 0 END), 0) AS failed
                         FROM swarm_changes WHERE swarm = ?1`,
                  )
                  .bind(id)
                  .first<SwarmLiveInput["changes"]>()
            : Promise.resolve(null),
    ]);
    const letter: Record<string, string> = { queued: "q", running: "r", waiting: "w", done: "d", failed: "f", skipped: "s" };
    const keyId = row.key_id;
    const planner = keyId.startsWith("chat:") ? "chat" : row.name_key?.trim() ? row.name_key.trim().slice(0, 40) : "mcp";
    return {
        id: row.id,
        name: row.name,
        mode: row.mode,
        status: row.status,
        apply_status: row.apply_status,
        spec_hash: row.spec_hash,
        planner,
        est_low: row.est_low,
        est_high: row.est_high,
        spent_usd: row.spent_usd,
        cap_usd: row.cap_usd,
        error: row.error,
        reduce: row.reduce_result,
        created_at: row.created_at,
        approved_at: row.approved_at,
        finished_at: row.finished_at,
        expires_at: row.expires_at,
        cells: cells.results.map((c) => letter[c.status] ?? "q").join(""),
        changes: {
            total: changes?.total ?? 0,
            kept: changes?.kept ?? 0,
            open: changes?.open ?? 0,
            clashes: changes?.clashes ?? 0,
            done: changes?.done ?? 0,
            failed: changes?.failed ?? 0,
        },
    };
}

// ---- payloads ----------------------------------------------------------------------------------------------------------

export function swarmStartPayload(job: Job, planner: string, now: number) {
    return asJobPayload(
        {
            aps: {
                timestamp: secs(now),
                event: "start",
                "attributes-type": JOB_ATTRIBUTES_TYPE,
                "input-push-token": 1,
                alert: { title: "capystore", body: `${planner} asks to run a swarm` },
            },
        },
        job,
        now,
    );
}

// An update, or the end: done stays 60 s, failed 300 s, a declined or expired plan goes at once (8.12, 61.5).
export function swarmPushPayload(job: Job, input: Pick<SwarmLiveInput, "status" | "expires_at">, now: number) {
    const terminal = isJobTerminal(job.state);
    const aps: Record<string, unknown> = { timestamp: secs(now), event: terminal ? "end" : "update" };
    if (terminal) {
        if (swarmEndsAtOnce(input, now)) aps["dismissal-date"] = secs(now);
        else if (job.state.phase === "done") {
            aps["dismissal-date"] = secs(now) + SWARM_LIVE_DISMISS_DONE_S;
            aps.alert = { title: "swarm done", body: job.state.headline };
        } else {
            aps["dismissal-date"] = secs(now) + SWARM_LIVE_DISMISS_FAILED_S;
            aps.alert = { title: "swarm stopped", body: job.state.headline };
        }
    }
    return asJobPayload({ aps }, job, now);
}

// What a push of `next` after `rec.sent` would be, or null when nothing should go now. `catchup`: the token just arrived.
export function decideSwarmPush(rec: Pick<SwarmLiveRecord, "sent" | "sentAt">, job: Job, input: Pick<SwarmLiveInput, "status" | "expires_at">, now: number, catchup = false): ApnsPush | null {
    const next = job.state;
    const terminal = isJobTerminal(next);
    const unchanged = same(rec.sent, next);
    const refresh = !terminal && now - rec.sentAt >= SWARM_LIVE_REFRESH_MS;
    if (unchanged && !refresh && !catchup) return null;
    const major =
        rec.sent === null ||
        rec.sent.phase !== next.phase ||
        rec.sent.step !== next.step ||
        JSON.stringify(rec.sent.actions ?? []) !== JSON.stringify(next.actions ?? []) ||
        rec.sent.hash !== next.hash;
    const counter = !terminal && !major && !catchup;
    if (counter && !unchanged && now - rec.sentAt < SWARM_LIVE_MIN_GAP_MS) return null;
    return {
        event: terminal ? "end" : "update",
        priority: counter ? 5 : 10,
        expiration: secs(now) + (counter ? 60 : 3600),
        payload: swarmPushPayload(job, input, now),
    };
}

// ---- the service -------------------------------------------------------------------------------------------------------

export type SwarmLiveDeps = {
    storage: KV;
    db: D1Database;
    now: () => number;
    // null: APNs is not configured; nothing is stored or sent
    apns: ApnsClient | null;
    // arms the sweep, whose quiet pass runs `watch`
    scheduleSweep?: () => Promise<void>;
};

type Reply = { status: number; body: unknown };
const bad = (): Reply => ({ status: 400, body: { status: "error", error: { code: "error.live.bad_request" } } });
const notFound = (): Reply => ({ status: 404, body: { status: "error", error: { code: "error.live.not_found" } } });

export class SwarmLiveService {
    // one at a time per swarm (a push from the runner and the app's token can race)
    private chains = new Map<string, Promise<unknown>>();

    constructor(private d: SwarmLiveDeps) {}

    private key = (id: string) => `${SWARM_LIVE_PREFIX}${id}`;

    private withSwarm<T>(id: string, fn: () => Promise<T>): Promise<T> {
        const p = (this.chains.get(id) ?? Promise.resolve()).catch(() => {}).then(fn);
        this.chains.set(id, p);
        const clear = () => {
            if (this.chains.get(id) === p) this.chains.delete(id);
        };
        p.then(clear, clear);
        return p;
    }

    private async arm() {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[swarm-live] arming the sweep failed", String(e));
        }
    }

    // The device: the job start token refreshed most recently in 60 days, never a chat key (as agent jobs, 8.11). Only the
    // job type can draw a swarm, so the old type's tokens are not used.
    private async device(now: number): Promise<{ keyId: string; t: StartToken } | null> {
        const list = [...(await this.d.storage.list<StartToken>({ prefix: JOB_START_PREFIX })).entries()]
            .map(([k, t]) => ({ keyId: k.slice(JOB_START_PREFIX.length), t }))
            .filter(({ keyId, t }) => !keyId.startsWith("chat:") && now - t.updatedAt < LIVE_START_TOKEN_TTL_MS)
            .sort((a, b) => b.t.updatedAt - a.t.updatedAt)
            .slice(0, LIVE_AGENT_MAX_DEVICES);
        return list[0] ?? null;
    }

    // A plan was stored (or a finished swarm planned again): push-start its island. Nothing when one is already open.
    async start(id: string): Promise<{ started: boolean; reason?: string }> {
        if (!this.d.apns) return { started: false, reason: "not_configured" };
        return this.withSwarm(id, async () => {
            const now = this.d.now();
            const prev = await this.d.storage.get<SwarmLiveRecord>(this.key(id));
            if (prev && prev.endedAt === null && now - prev.createdAt < SWARM_LIVE_TTL_MS) return { started: false, reason: "open" };
            const input = await swarmLiveInput(this.d.db, id);
            if (!input || input.status !== "awaiting_approval") return { started: false, reason: "not_waiting" };
            const dev = await this.device(now);
            if (!dev) return { started: false, reason: "no_start_token" };
            const job = jobOfSwarm(input, now);
            const rec: SwarmLiveRecord = { swarm: id, keyId: dev.keyId, env: dev.t.env, token: null, sent: null, sentAt: 0, createdAt: now, startedAt: null, checkAt: now + SWARM_LIVE_REFRESH_MS, endedAt: null };
            // stored before the push leaves: a start is never sent twice for one plan
            await this.d.storage.put(this.key(id), rec);
            const dlv = await this.d.apns!.deliver(dev.t.token, dev.t.env, { event: "start", priority: 10, expiration: secs(now) + 3600, payload: swarmStartPayload(job, input.planner, now) }, `swarm:${id}`);
            if (dlv.kind === "sent") {
                rec.startedAt = now;
                rec.sent = job.state;
                rec.sentAt = now;
                rec.env = dlv.env;
            } else if (dlv.kind === "drop") {
                await this.d.storage.delete(`${JOB_START_PREFIX}${dev.keyId}`);
                rec.endedAt = now;
            }
            await this.d.storage.put(this.key(id), rec);
            await this.arm();
            console.log(`[swarm-live] start swarm=${id} key=${dev.keyId.slice(0, 6)} ${dlv.kind}`);
            return { started: dlv.kind === "sent" };
        });
    }

    // The app reports the started activity's update token (any key but a chat key; the record moves to it).
    async putToken(keyId: string, id: string, raw: string): Promise<Reply> {
        let b: { token?: unknown; update_token?: unknown; environment?: unknown; env?: unknown } | null = null;
        try {
            b = JSON.parse(raw);
        } catch {
            return bad();
        }
        const env = b?.environment ?? b?.env;
        // the run form (PUT /live/runs/swarm:<id>) names it update_token, as a save's run does
        if (b && b.token === undefined && b.update_token !== undefined) b.token = b.update_token;
        if (typeof b?.token !== "string" || !TOKEN_REGEX.test(b.token) || (env !== "sandbox" && env !== "production")) return bad();
        if (keyId.startsWith("chat:")) return notFound();
        if (!this.d.apns) return { status: 200, body: { status: "success", pushing: false, reason: "not_configured" } };
        return this.withSwarm(id, async () => {
            const now = this.d.now();
            const input = await swarmLiveInput(this.d.db, id);
            if (!input) return notFound();
            const prev = await this.d.storage.get<SwarmLiveRecord>(this.key(id));
            const sameToken = prev?.token === b!.token;
            const rec: SwarmLiveRecord = {
                swarm: id,
                keyId,
                env: env as Environment,
                token: b!.token as string,
                // a new token is a new activity: what the start showed is what it has
                sent: prev ? prev.sent : null,
                sentAt: prev && sameToken ? prev.sentAt : (prev?.startedAt ?? 0),
                createdAt: prev?.createdAt ?? now,
                startedAt: prev?.startedAt ?? null,
                checkAt: prev?.checkAt ?? now + SWARM_LIVE_REFRESH_MS,
                endedAt: null,
            };
            await this.d.storage.put(this.key(id), rec);
            await this.pushRecord(rec, input, !sameToken);
            await this.arm();
            return { status: 200, body: { status: "success", pushing: true } };
        });
    }

    async deleteToken(id: string): Promise<Reply> {
        await this.d.storage.delete(this.key(id));
        return { status: 200, body: { status: "success" } };
    }

    // The swarm moved (from an op or the runner). Cheap when it has no island (one storage read).
    async push(id: string): Promise<{ pushed: boolean }> {
        if (!this.d.apns) return { pushed: false };
        return this.withSwarm(id, async () => {
            const rec = await this.d.storage.get<SwarmLiveRecord>(this.key(id));
            if (!rec || rec.endedAt !== null) return { pushed: false };
            const input = await swarmLiveInput(this.d.db, id);
            if (!input) {
                await this.d.storage.delete(this.key(id));
                return { pushed: false };
            }
            const pushed = await this.pushRecord(rec, input, false);
            return { pushed };
        });
    }

    // The sweep's pass: expired plans end, quiet islands get a fresh stale-date, throttled counters go out. Answers when
    // the next record wants looking at (null: none open).
    async watch(now: number = this.d.now()): Promise<{ nextInMs: number | null }> {
        if (!this.d.apns) return { nextInMs: null };
        let next: number | null = null;
        const note = (at: number | null) => {
            if (at === null) return;
            const inMs = Math.max(0, at - now);
            next = next === null ? inMs : Math.min(next, inMs);
        };
        for (const [k, rec] of await this.d.storage.list<SwarmLiveRecord>({ prefix: SWARM_LIVE_PREFIX })) {
            if (rec.endedAt !== null || now - rec.createdAt > SWARM_LIVE_TTL_MS) {
                if (rec.endedAt === null || now - rec.endedAt > 60 * 60 * 1000 || now - rec.createdAt > SWARM_LIVE_TTL_MS) await this.d.storage.delete(k);
                continue;
            }
            if (rec.checkAt !== null && rec.checkAt > now) {
                note(rec.checkAt);
                continue;
            }
            await this.withSwarm(rec.swarm, async () => {
                const cur = await this.d.storage.get<SwarmLiveRecord>(k);
                if (!cur || cur.endedAt !== null) return;
                const input = await swarmLiveInput(this.d.db, cur.swarm);
                if (!input) {
                    await this.d.storage.delete(k);
                    return;
                }
                await this.pushRecord(cur, input, false);
                const after = await this.d.storage.get<SwarmLiveRecord>(k);
                if (after && after.endedAt === null) note(after.checkAt);
            }).catch((e) => console.error("[swarm-live] watch failed", rec.swarm, String(e)));
        }
        return { nextInMs: next };
    }

    // Decides and sends the push for a record, and saves what came of it. Before the token arrives nothing can be sent:
    // the record only remembers to look again.
    private async pushRecord(rec: SwarmLiveRecord, input: SwarmLiveInput, catchup: boolean): Promise<boolean> {
        const now = this.d.now();
        const job = jobOfSwarm(input, now);
        const terminal = isJobTerminal(job.state);
        // when watch should look again: a plan's hour, the keep-alive, a throttled counter
        const recheck = () => {
            const at = [now + SWARM_LIVE_REFRESH_MS];
            if (input.status === "awaiting_approval" && input.expires_at !== null) at.push(input.expires_at);
            if (!same(rec.sent, job.state)) at.push(rec.sentAt + SWARM_LIVE_MIN_GAP_MS);
            return Math.max(now, Math.min(...at));
        };
        if (!rec.token) {
            rec.checkAt = terminal ? now + SWARM_LIVE_REFRESH_MS : recheck();
            await this.d.storage.put(this.key(rec.swarm), rec);
            return false;
        }
        const push = decideSwarmPush(rec, job, input, now, catchup);
        if (!push) {
            rec.checkAt = recheck();
            await this.d.storage.put(this.key(rec.swarm), rec);
            return false;
        }
        const dlv = await this.d.apns!.deliver(rec.token, rec.env, push, `swarm:${rec.swarm}`);
        if (dlv.kind === "sent") {
            rec.sent = job.state;
            rec.sentAt = now;
            rec.env = dlv.env;
            if (terminal) rec.endedAt = now;
        } else if (dlv.kind === "drop") {
            rec.token = null;
            if (terminal) rec.endedAt = now;
        }
        rec.checkAt = rec.endedAt !== null ? null : recheck();
        await this.d.storage.put(this.key(rec.swarm), rec);
        return dlv.kind === "sent";
    }
}

// ---- routing (inside the Durable Object) ----------------------------------------------------------------------------

// `/live/runs/swarm:<id>` is the same token route as `/live/swarms/<id>`: the app registers every activity's update token
// under /live/runs, and a swarm island's run is `swarm:<id>`.
const SWARM_RUN_PREFIX = "/live/runs/swarm:";
const swarmPath = (pathname: string) => (pathname.startsWith(SWARM_RUN_PREFIX) ? "/live/swarms/" + pathname.slice(SWARM_RUN_PREFIX.length) : pathname);
export const isSwarmLiveRoute = (pathname: string) => swarmPath(pathname).startsWith("/live/swarms/");

const toResponse = (r: Reply) => new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });

export async function handleSwarmLiveRoute(service: SwarmLiveService, request: Request, internalKey: string): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const [id, sub, ...rest] = swarmPath(pathname).slice("/live/swarms/".length).split("/");
    if (!SWARM_LIVE_ID_REGEX.test(id ?? "") || rest.length > 0) return new Response(null, { status: 404 });
    // the internal start/push routes are only ever /live/swarms/<id>/…
    if (sub !== undefined && pathname.startsWith(SWARM_RUN_PREFIX)) return new Response(null, { status: 404 });
    const m = request.method;
    if (sub === "start" || sub === "push") {
        if (m !== "POST" || !internalKey || request.headers.get("x-internal-key") !== internalKey) return new Response(null, { status: 403 });
        const out = sub === "start" ? await service.start(id!) : await service.push(id!);
        return toResponse({ status: 200, body: { status: "success", ...out } });
    }
    if (sub !== undefined) return new Response(null, { status: 404 });
    // the Worker sets the key id after its D1 lookup; a request without it is refused
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });
    if (m === "PUT") {
        const declared = Number(request.headers.get("content-length"));
        if (Number.isFinite(declared) && declared > SWARM_LIVE_MAX_BODY) return toResponse(bad());
        const text = await request.text();
        if (new TextEncoder().encode(text).length > SWARM_LIVE_MAX_BODY) return toResponse(bad());
        return toResponse(await service.putToken(keyId, id!, text));
    }
    if (m === "DELETE") return toResponse(await service.deleteToken(id!));
    return new Response(null, { status: 404 });
}
