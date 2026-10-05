// Live Activity push (APP-API-CONTRACT.md section 8, apple/CONTRACT-LIVE.md): the
// token and run store (Durable Object storage), the content-state builder and its
// merge / coalesce rule, the payloads, and the /live routes inside the Durable
// Object. Free of Cloudflare imports so it runs under plain node in the tests; the
// APNs wire work is apns.ts.
//
// Storage keys (all in the one `main` Durable Object, next to job:/save:/sweep:at):
//   live:start:<key id>   {token, env, updatedAt}   one per API key (one key per device)
//   live:run:<run>        the run record (RunRecord)
//   live:sid:<sid>        run ids registered for a studio session
//   live:health:<key id>  {badAt, reason}           the last non-token APNs failure
//   live:idx:<key id>:<run>  RunIndexEntry          small index of every run: the caps, the
//                         cleanup, hasActiveRuns and the end retries read this, never
//                         the run records
//   live:startat:<key id> unix ms of the last push-to-start (one per key per 10 s)
//   live:jwt              the APNs provider token (apns.ts), kept across DO evictions
//
// Nothing here runs after a response: the studio hooks are awaited by the poll or
// the sweep that caused them (a trailing flush would not survive the response), and
// the latest counter value is re-sent by the next poll or sweep.

import type { ApnsClient, ApnsPush, Delivery, Environment } from "./apns";
import { STUDIO_SID_REGEX } from "./gate";
import { KEY_ID_HEADER } from "./headers";
import type { SaveProgress } from "./studio";
import type { KV } from "./webp";

// ---- constants --------------------------------------------------------------------

export const LIVE_PUSH_MS = 3000;
export const LIVE_SWEEP_DELAY_S = 2;
export const LIVE_RUN_TTL_MS = 8 * 60 * 60 * 1000;
export const LIVE_ENDED_TTL_MS = 60 * 60 * 1000;
export const LIVE_START_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000;
export const LIVE_HEALTH_MS = 10 * 60 * 1000;
export const LIVE_COALESCE_MS = 1000;
export const LIVE_MAX_BODY_BYTES = 4096;
// Caps (error.live.too_many_runs, 429): runs a key may hold that have not ended, runs a
// key may hold at all (ended ones stay for LIVE_ENDED_TTL_MS), runs per studio session.
export const LIVE_MAX_OPEN_RUNS_PER_KEY = 16;
export const LIVE_MAX_RUNS_PER_KEY = 64;
export const LIVE_MAX_RUNS_PER_SID = 16;
// At most one push-to-start per key in this window.
export const LIVE_START_MIN_GAP_MS = 10_000;
// A failed `end` push is retried by the sweep after each of these (after the first failure,
// then after each further one): 3 retries over about a minute, then only a poll retries.
export const LIVE_END_RETRY_DELAYS_MS: readonly number[] = [5_000, 15_000, 40_000];
const START_WINDOW_PREFIX = "live:startat:";

export const STALE_S = 120;
export const STALE_READY_S = 30 * 60;
export const DISMISS_DONE_S = 900;
export const DISMISS_FAILED_S = 300;
export const EXPIRE_COUNTER_S = 60;
export const EXPIRE_STAGE_S = 3600;

export const RUN_ID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const TOKEN_REGEX = /^[0-9a-f]{64,200}$/;

// ---- the content state ------------------------------------------------------------

export const STAGES = ["fetching", "uploading", "saving", "reading", "ready", "rendering", "done", "failed"] as const;
export type Stage = (typeof STAGES)[number];

// The stages the device performs and may relay (CONTRACT-LIVE.md 2.1).
export const DEVICE_STAGES: readonly Stage[] = ["uploading", "reading", "ready", "failed"];
// The stages a run is waiting on the server in.
const SERVER_WAIT_STAGES: readonly Stage[] = ["fetching", "saving", "rendering"];

// LiveContentState (Swift property names, camelCase: ActivityKit decodes the pushed
// content-state by property name). Absent optionals are omitted, never null.
export type LiveState = {
    stage: Stage;
    rail: number;
    since: number;
    waking: boolean;
    packing: boolean;
    bytes?: number;
    total?: number;
    framesDone?: number;
    framesTotal?: number;
    title?: string;
    duration?: number;
    resultURL?: string;
    resultBytes?: number;
    resultWidth?: number;
    resultHeight?: number;
    resultSeconds?: number;
    failure?: string;
    code?: string;
};

const INT_KEYS = ["bytes", "total", "framesDone", "framesTotal", "resultBytes", "resultWidth", "resultHeight"] as const;
const NUM_KEYS = ["duration", "resultSeconds"] as const;
const STR_KEYS = ["title", "resultURL", "failure", "code"] as const;
const MAX_STR = 300;

// Canonical key order (the order of the parity fixture), so two equal states
// serialise to the same bytes.
const KEY_ORDER = [
    "stage", "rail", "since", "waking", "packing", "bytes", "total", "framesDone", "framesTotal",
    "title", "duration", "resultURL", "resultBytes", "resultWidth", "resultHeight", "resultSeconds",
    "failure", "code",
] as const;

export function canonical(s: LiveState): LiveState {
    const out: Record<string, unknown> = {};
    const src = s as Record<string, unknown>;
    for (const k of KEY_ORDER) {
        const v = src[k];
        if (v !== undefined && v !== null) out[k] = v;
    }
    return out as LiveState;
}

export const sameState = (a: LiveState | null, b: LiveState | null): boolean =>
    a !== null && b !== null && JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

const isRecord = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

// The device's state, reduced to the allow-listed keys with their types (null when
// anything is off). Int fields must be integers: Swift decodes a fractional number
// into an Int as an error and would drop the whole update.
export function sanitizeState(raw: unknown): LiveState | null {
    if (!isRecord(raw)) return null;
    if (typeof raw.stage !== "string" || !(STAGES as readonly string[]).includes(raw.stage)) return null;
    const rail = raw.rail;
    if (typeof rail !== "number" || !Number.isInteger(rail) || rail < 0 || rail > 3) return null;
    if (typeof raw.since !== "number" || !Number.isFinite(raw.since)) return null;
    if (typeof raw.waking !== "boolean" || typeof raw.packing !== "boolean") return null;
    const out: Record<string, unknown> = {
        stage: raw.stage,
        rail,
        since: raw.since,
        waking: raw.waking,
        packing: raw.packing,
    };
    for (const k of INT_KEYS) {
        const v = raw[k];
        if (v === undefined || v === null) continue;
        if (typeof v !== "number" || !Number.isSafeInteger(v)) return null;
        out[k] = v;
    }
    for (const k of NUM_KEYS) {
        const v = raw[k];
        if (v === undefined || v === null) continue;
        if (typeof v !== "number" || !Number.isFinite(v)) return null;
        out[k] = v;
    }
    for (const k of STR_KEYS) {
        const v = raw[k];
        if (v === undefined || v === null) continue;
        if (typeof v !== "string" || v.length > MAX_STR) return null;
        out[k] = v;
    }
    return canonical(out as LiveState);
}

// ---- the server's events and the merge --------------------------------------------

export type LiveSaveEvent =
    | { kind: "progress"; progress: SaveProgress; title?: string | null; duration?: number | null }
    | { kind: "failed"; code: string };
export type LiveRenderEvent =
    | { kind: "accepted"; title?: string | null; duration?: number | null }
    | { kind: "pending"; phase: "fetching" | "decode" | "pack" | null; framesDone: number | null; framesTotal: number | null }
    | { kind: "success"; url: string; bytes: number | null; width: number | null; height: number | null; seconds: number | null }
    | { kind: "failed"; code: string };
export type LiveHooks = {
    onSave(sid: string, e: LiveSaveEvent): Promise<void>;
    onRender(sid: string, job: string, e: LiveRenderEvent): Promise<void>;
    // any run with an update token waiting on a server step (the sweep's 2 s cadence)
    hasActiveRuns(): Promise<boolean>;
};

// What the merge consumes: the events reduced to the state they describe.
export type StateEvent =
    | { t: "fetching"; waking: boolean }
    | { t: "saving"; bytes: number | null; total: number | null; title?: string | null; duration?: number | null }
    | { t: "rendering"; framesDone: number | null; framesTotal: number | null; packing: boolean; title?: string | null; duration?: number | null }
    | { t: "done"; url: string; bytes: number | null; width: number | null; height: number | null; seconds: number | null }
    | { t: "failed"; code: string; phase: "saving" | "rendering" };

export function stateEventOfSave(e: LiveSaveEvent): StateEvent {
    if (e.kind === "failed") return { t: "failed", code: e.code, phase: "saving" };
    const p = e.progress;
    if (p.step === "fetching") return { t: "fetching", waking: p.waking };
    return { t: "saving", bytes: p.bytes, total: p.total, title: e.title, duration: e.duration };
}

export function stateEventOfRender(e: LiveRenderEvent): StateEvent {
    switch (e.kind) {
        case "accepted":
            return { t: "rendering", framesDone: null, framesTotal: null, packing: false, title: e.title, duration: e.duration };
        case "pending":
            if (e.phase === "decode") {
                return { t: "rendering", framesDone: e.framesDone, framesTotal: e.framesTotal, packing: false };
            }
            if (e.phase === "pack") {
                // img2webp has no count: done = total = the frames made
                const n = e.framesTotal ?? e.framesDone;
                return { t: "rendering", framesDone: n, framesTotal: n, packing: true };
            }
            return { t: "rendering", framesDone: null, framesTotal: null, packing: false };
        case "success":
            return { t: "done", url: e.url, bytes: e.bytes, width: e.width, height: e.height, seconds: e.seconds };
        case "failed":
            return { t: "failed", code: e.code, phase: "rendering" };
    }
}

const stageOf: Record<StateEvent["t"], Stage> = {
    fetching: "fetching",
    saving: "saving",
    rendering: "rendering",
    done: "done",
    failed: "failed",
};

const RAIL: Record<string, number> = { fetching: 0, saving: 1, rendering: 3, done: 3 };

const setNum = (o: LiveState, k: "bytes" | "total" | "framesDone" | "framesTotal" | "resultBytes" | "resultWidth" | "resultHeight", v: number | null | undefined) => {
    if (typeof v === "number" && Number.isSafeInteger(v)) o[k] = v;
};

// The merge rule (CONTRACT-LIVE.md 2.3, same as the app's builder): when the stage
// changes, bytes / total / framesDone / framesTotal / packing reset and `since`
// becomes now (a `fetching` state keeps the registered one); title and duration
// carry over and update when known. `now` is ms; `since` is unix seconds.
export function nextState(prev: LiveState | null, ev: StateEvent, now: number): LiveState {
    const nowS = Math.floor(now / 1000);
    const stage = stageOf[ev.t];
    const same = prev?.stage === stage;
    const out: LiveState = {
        stage,
        rail: stage === "failed" ? (prev?.rail ?? (ev.t === "failed" && ev.phase === "rendering" ? 3 : 1)) : RAIL[stage]!,
        since: stage === "fetching" ? (prev?.since ?? nowS) : same ? prev!.since : nowS,
        waking: false,
        packing: false,
    };
    const title = (ev as { title?: string | null }).title;
    const duration = (ev as { duration?: number | null }).duration;
    const carriedTitle = typeof title === "string" && title !== "" ? title : prev?.title;
    const carriedDuration = typeof duration === "number" && Number.isFinite(duration) ? duration : prev?.duration;

    switch (ev.t) {
        case "fetching":
            out.waking = ev.waking;
            break;
        case "saving":
            setNum(out, "bytes", ev.bytes);
            setNum(out, "total", ev.total);
            break;
        case "rendering":
            out.packing = ev.packing;
            setNum(out, "framesDone", ev.framesDone);
            setNum(out, "framesTotal", ev.framesTotal);
            break;
        case "done":
            out.resultURL = ev.url.slice(0, MAX_STR);
            setNum(out, "resultBytes", ev.bytes);
            setNum(out, "resultWidth", ev.width);
            setNum(out, "resultHeight", ev.height);
            if (typeof ev.seconds === "number" && Number.isFinite(ev.seconds)) out.resultSeconds = ev.seconds;
            break;
        case "failed":
            out.failure = failureKey(ev.code, ev.phase);
            out.code = ev.code.slice(0, MAX_STR);
            break;
    }
    if (carriedTitle !== undefined) out.title = carriedTitle.slice(0, MAX_STR);
    if (carriedDuration !== undefined) out.duration = carriedDuration;
    return canonical(out);
}

// A port of apple/CobaltKit/Sources/CobaltKit/API/ErrorMap.swift `mapFailure`,
// returning the PipelineFailure case name. A code it cannot place is `server`.
export function failureKey(code: string, phase: "saving" | "rendering"): string {
    if (code.startsWith("error.api.fetch.") || code.startsWith("error.api.content.") || code.startsWith("error.api.link.")) {
        return "fetchFailed";
    }
    switch (code) {
        case "error.webp.no_video":
        case "error.webp.bad_source":
        case "error.webp.download_failed":
            return "fetchFailed";
        case "error.api.auth.key.missing":
            return "keyMissing";
        case "error.api.auth.key.invalid":
        case "error.api.auth.key.not_api_key":
        case "error.api.auth.key.not_found":
            return "keyInvalid";
        case "error.studio.busy":
            return "serverBusy";
        case "error.webp.busy":
            return "renderBusy";
        case "error.webp.job_lost":
        case "error.studio.save_lost":
            return phase === "rendering" ? "renderLost" : "server";
        case "error.studio.expired":
            return "expired";
        case "error.library.too_large":
        case "error.studio.too_large":
        case "error.webp.too_large":
            return "tooLarge";
        case "error.webp.unsupported":
        case "error.library.unsupported":
        case "error.studio.not_video":
            return "unsupported";
        default:
            return "server";
    }
}

// ---- copy and payloads (all lowercase, no sound) ----------------------------------

// The app's Format.bytes: "841 KB", "4.5 MB", "1.2 GB".
export function formatBytes(n: number): string {
    if (n >= 1_000_000_000) return `${(n / 1e9).toFixed(1)} GB`;
    if (n >= 1_000_000) return `${(n / 1e6).toFixed(1)} MB`;
    return `${Math.max(1, Math.round(n / 1e3))} KB`;
}

export type RunAttributes = { run: string; input: "link" | "file"; service: string; ref: string; origin: "app" | "share" };

export const isTerminal = (s: LiveState) => s.stage === "done" || s.stage === "failed";

const secs = (ms: number) => Math.floor(ms / 1000);
const staleDate = (s: LiveState, now: number) => secs(now) + (s.stage === "ready" ? STALE_READY_S : STALE_S);

export function updatePayload(state: LiveState, now: number) {
    return {
        aps: {
            timestamp: secs(now),
            event: "update",
            "content-state": canonical(state),
            "stale-date": staleDate(state, now),
        },
    };
}

export function startPayload(a: RunAttributes, state: LiveState, now: number) {
    return {
        aps: {
            timestamp: secs(now),
            event: "start",
            "attributes-type": "CobaltActivityAttributes",
            attributes: { run: a.run, input: a.input, service: a.service, ref: a.ref, origin: a.origin },
            "content-state": canonical(state),
            "stale-date": staleDate(state, now),
            "input-push-token": 1,
            alert: { title: "cobalt", body: a.input === "file" ? `uploading ${a.ref}` : `fetching from ${a.service}` },
        },
    };
}

// `end`: a finished run dismisses after 15 minutes (done) or 5 (failed) with a short
// alert; an `immediate` end (DELETE) dismisses now, with no alert.
export function endPayload(a: RunAttributes, state: LiveState, now: number, immediate = false) {
    const aps: Record<string, unknown> = {
        timestamp: secs(now),
        event: "end",
        "content-state": canonical(state),
    };
    if (immediate) {
        aps["dismissal-date"] = secs(now);
    } else if (state.stage === "done") {
        aps["dismissal-date"] = secs(now) + DISMISS_DONE_S;
        aps.alert = {
            title: "webp ready",
            body: typeof state.resultBytes === "number" ? `${a.service} · ${formatBytes(state.resultBytes)}` : a.service,
        };
    } else {
        aps["dismissal-date"] = secs(now) + DISMISS_FAILED_S;
        aps.alert = { title: "cobalt couldn't finish", body: "open cobalt to see what happened." };
    }
    return { aps };
}

// ---- records ----------------------------------------------------------------------

export type StartToken = { token: string; env: Environment; updatedAt: number };
export type RunRecord = {
    run: string;
    keyId: string;
    sid: string | null;
    job: string | null;
    env: Environment;
    updateToken: string | null;
    attributes: RunAttributes;
    state: LiveState;
    // the last content state APNs accepted
    sent: LiveState | null;
    lastPushAt: number;
    startedAt: number | null;
    endedAt: number | null;
    createdAt: number;
    // A push-to-start is recorded here BEFORE it leaves, and kept when its outcome is
    // unknown (sent, no answer seen: Apple may have started the activity). A run whose
    // start was attempted is never sent a second one, so a retry cannot make two
    // activities; a start that provably never reached Apple clears it again.
    startAttemptedAt?: number | null;
    // Failed `end` pushes: how many, and when the sweep tries again (null: gave up, only
    // a client poll retries from then on).
    endTries?: number;
    endRetryAt?: number | null;
};
// The small per-run index (`live:idx:<key id>:<run>`): everything the caps, the
// cleanup, hasActiveRuns and the end retries need without reading run records.
export type RunIndexEntry = {
    run: string;
    keyId: string;
    sid: string | null;
    createdAt: number;
    endedAt: number | null;
    // an update token and a server step to wait on (the sweep's 2 s cadence)
    active: boolean;
    // when the sweep retries a failed end push
    retryAt: number | null;
};
type Health = { badAt: number; reason: string };

const IDX_PREFIX = "live:idx:";
const idxKey = (keyId: string, run: string) => `${IDX_PREFIX}${keyId}:${run}`;

export type LiveReply = { status: number; body: unknown };
const err = (status: number, code: string): LiveReply => ({ status, body: { status: "error", error: { code } } });
const badRequest = () => err(400, "error.live.bad_request");
const notFound = () => err(404, "error.live.not_found");
const tooManyRuns = () => err(429, "error.live.too_many_runs");
const noContent = (): LiveReply => ({ status: 204, body: null });

export type LiveDeps = {
    storage: KV;
    db: D1Database;
    now: () => number;
    // null: the APNs secrets are not configured (capability false, nothing is sent)
    apns: ApnsClient | null;
    // arms the job sweep (index.ts: scheduleSweepSoon); called when an end push failed,
    // so the sweep retries it with nobody polling
    scheduleSweep?: () => Promise<void>;
};

const ENVS: readonly string[] = ["sandbox", "production"];
const isEnv = (v: unknown): v is Environment => typeof v === "string" && ENVS.includes(v);

const parseJson = (raw: string): Record<string, unknown> | null => {
    try {
        if (new TextEncoder().encode(raw).length > LIVE_MAX_BODY_BYTES) return null;
        const v = JSON.parse(raw);
        return isRecord(v) ? v : null;
    } catch {
        return null;
    }
};

type Registration = {
    env: Environment;
    updateToken: string | null;
    session: string | null;
    start: boolean;
    attributes: RunAttributes;
    state: LiveState;
};

function parseRegistration(run: string, b: Record<string, unknown>): Registration | null {
    if (!isEnv(b.environment)) return null;
    const token = b.update_token;
    if (token !== undefined && token !== null && (typeof token !== "string" || !TOKEN_REGEX.test(token))) return null;
    const session = b.session;
    if (session !== undefined && session !== null && (typeof session !== "string" || !STUDIO_SID_REGEX.test(session))) return null;
    const start = b.start;
    if (start !== undefined && start !== null && typeof start !== "boolean") return null;
    const a = b.attributes;
    if (!isRecord(a) || a.run !== run) return null;
    if (a.input !== "link" && a.input !== "file") return null;
    if (a.origin !== "app" && a.origin !== "share") return null;
    if (typeof a.service !== "string" || a.service.length > 120) return null;
    if (typeof a.ref !== "string" || a.ref.length > 120) return null;
    const state = sanitizeState(b.state);
    if (!state) return null;
    return {
        env: b.environment,
        updateToken: (token as string | null | undefined) ?? null,
        session: (session as string | null | undefined) ?? null,
        start: start === true,
        attributes: { run, input: a.input, service: a.service, ref: a.ref, origin: a.origin },
        state,
    };
}

// ---- the service ------------------------------------------------------------------

export class LiveService implements LiveHooks {
    // run id -> the operation running on it (events, polls and the sweep may race)
    private chains = new Map<string, Promise<unknown>>();
    // one at a time: the run caps and the per-key start window are check-then-write
    private gate: Promise<unknown> = Promise.resolve();
    // run id -> the index entry last written (so an unchanged one is not written again)
    private idxSeen = new Map<string, string>();
    // key id -> the health record (null: none). One DO instance owns every write, so this
    // is coherent; it spares a storage read per dispatch and a write per success.
    private health = new Map<string, Health | null>();

    constructor(private d: LiveDeps) {}

    configured(): boolean {
        return this.d.apns !== null;
    }

    private withRun<T>(run: string, fn: () => Promise<T>): Promise<T> {
        const prev = this.chains.get(run) ?? Promise.resolve();
        const p = prev.catch(() => {}).then(fn);
        this.chains.set(run, p);
        const clear = () => {
            if (this.chains.get(run) === p) this.chains.delete(run);
        };
        p.then(clear, clear);
        return p;
    }

    private serial<T>(fn: () => Promise<T>): Promise<T> {
        const p = this.gate.catch(() => {}).then(fn);
        this.gate = p;
        return p;
    }

    // ---- storage ----

    private getRun = (run: string) => this.d.storage.get<RunRecord>(`live:run:${run}`);

    private entryOf(r: RunRecord): RunIndexEntry {
        return {
            run: r.run,
            keyId: r.keyId,
            sid: r.sid,
            createdAt: r.createdAt,
            endedAt: r.endedAt,
            active: !!r.updateToken && !r.endedAt && SERVER_WAIT_STAGES.includes(r.state.stage),
            retryAt: r.updateToken && !r.endedAt && isTerminal(r.state) ? (r.endRetryAt ?? null) : null,
        };
    }

    // The index entry first, then the record: a crash between them leaves an entry
    // without a record (the cleanup removes it), never a record nobody can clean up.
    private async saveRun(r: RunRecord) {
        const e = this.entryOf(r);
        const j = JSON.stringify(e);
        if (this.idxSeen.get(r.run) !== j) {
            await this.d.storage.put(idxKey(r.keyId, r.run), e);
            this.idxSeen.set(r.run, j);
        }
        await this.d.storage.put(`live:run:${r.run}`, r);
    }

    private async removeRun(run: string, keyId: string, sid: string | null) {
        await this.d.storage.delete(`live:run:${run}`);
        await this.d.storage.delete(idxKey(keyId, run));
        this.idxSeen.delete(run);
        if (sid) await this.indexRemove(sid, run);
    }

    private indexOfKey(keyId: string) {
        return this.d.storage.list<RunIndexEntry>({ prefix: `${IDX_PREFIX}${keyId}:` });
    }

    private async indexAdd(sid: string, run: string) {
        const ids = (await this.d.storage.get<string[]>(`live:sid:${sid}`)) ?? [];
        if (!ids.includes(run)) await this.d.storage.put(`live:sid:${sid}`, [...ids, run]);
    }
    private async indexRemove(sid: string, run: string) {
        const ids = (await this.d.storage.get<string[]>(`live:sid:${sid}`)) ?? [];
        const left = ids.filter((id) => id !== run);
        if (left.length === 0) await this.d.storage.delete(`live:sid:${sid}`);
        else if (left.length !== ids.length) await this.d.storage.put(`live:sid:${sid}`, left);
    }

    private async healthOf(keyId: string): Promise<Health | null> {
        if (!this.health.has(keyId)) {
            this.health.set(keyId, (await this.d.storage.get<Health>(`live:health:${keyId}`)) ?? null);
        }
        return this.health.get(keyId) ?? null;
    }
    private async markBad(keyId: string, reason: string) {
        const h: Health = { badAt: this.d.now(), reason: reason.slice(0, 120) };
        await this.d.storage.put(`live:health:${keyId}`, h);
        this.health.set(keyId, h);
    }
    // Every success calls this; it writes only when there is a record to remove.
    private async markOk(keyId: string) {
        if (await this.healthOf(keyId)) {
            await this.d.storage.delete(`live:health:${keyId}`);
            this.health.set(keyId, null);
        }
    }
    private async healthy(keyId: string): Promise<boolean> {
        const h = await this.healthOf(keyId);
        return !h || this.d.now() - h.badAt >= LIVE_HEALTH_MS;
    }

    // ---- sending ----

    // A failed end push: the sweep retries it (bounded, with backoff) so the result is
    // not left on the lock screen as "still working" just because nobody polls.
    private async noteEndFailure(r: RunRecord) {
        const tries = (r.endTries ?? 0) + 1;
        r.endTries = tries;
        const delay = LIVE_END_RETRY_DELAYS_MS[tries - 1];
        r.endRetryAt = delay === undefined ? null : this.d.now() + delay;
        if (r.endRetryAt !== null) {
            try {
                await this.d.scheduleSweep?.();
            } catch (e) {
                console.error("[live] arming the sweep for an end retry failed:", String(e));
            }
        }
    }

    // Applies what APNs said about a run's update token to the record.
    private async settleRun(r: RunRecord, pushed: LiveState, dlv: Delivery, terminal: boolean) {
        switch (dlv.kind) {
            case "sent":
                r.sent = pushed;
                r.lastPushAt = this.d.now();
                r.env = dlv.env;
                if (terminal) {
                    r.endedAt = this.d.now();
                    delete r.endTries;
                    delete r.endRetryAt;
                }
                await this.markOk(r.keyId);
                break;
            case "drop":
                r.updateToken = null;
                if (terminal) {
                    r.endedAt = this.d.now();
                    delete r.endTries;
                    delete r.endRetryAt;
                }
                break;
            case "unhealthy":
                await this.markBad(r.keyId, `${dlv.status} ${dlv.reason}`);
                if (terminal) await this.noteEndFailure(r);
                break;
            case "quiet":
                if (terminal) await this.noteEndFailure(r);
                break;
        }
    }

    // Decides and sends the push for a run whose `state` was just set and applies the
    // answer to the record (the caller saves it). `catchup`: the update token just arrived (or a push-started activity is
    // behind), so push now whatever the coalescing says.
    //
    // Nothing is ever pushed to a run that has ended. A counter (priority 5) is also
    // skipped while the key is unhealthy (an outage must not make every poll and every 2 s
    // sweep wait out a failing push) and, with the helper transport, outside the server
    // stages (a relay would go through containerFetch and renew the container's
    // sleepAfter, keeping it awake through the device-only phases). Stage changes, the end
    // and a catch-up always go.
    private async dispatch(r: RunRecord, catchup = false): Promise<void> {
        const apns = this.d.apns;
        if (!apns || !r.updateToken || r.endedAt) return;
        const s = r.state;
        if (sameState(s, r.sent)) return;
        const terminal = isTerminal(s);
        const now = this.d.now();
        // an end that failed waits for its backoff (the sweep, or a later poll, retries it)
        if (terminal && !catchup && r.endRetryAt && now < r.endRetryAt) return;
        const stageChanged = r.sent === null || r.sent.stage !== s.stage;
        const counter = !catchup && !stageChanged && !terminal;
        if (counter) {
            if (now - r.lastPushAt < LIVE_COALESCE_MS) return;
            if (apns.via === "helper" && !SERVER_WAIT_STAGES.includes(s.stage)) return;
            if (!(await this.healthy(r.keyId))) return;
        }
        const push: ApnsPush = {
            event: terminal ? "end" : "update",
            priority: counter ? 5 : 10,
            expiration: secs(now) + (counter ? EXPIRE_COUNTER_S : EXPIRE_STAGE_S),
            payload: terminal ? endPayload(r.attributes, s, now) : updatePayload(s, now),
        };
        const dlv = await apns.deliver(r.updateToken, r.env, push, r.run);
        await this.settleRun(r, s, dlv, terminal);
    }

    // ---- hooks from the studio (awaited by the poll or the sweep that caused them) ----

    private async runsOf(sid: string): Promise<string[]> {
        return (await this.d.storage.get<string[]>(`live:sid:${sid}`)) ?? [];
    }

    private async applyEvent(runId: string, ev: StateEvent, job?: { id: string; accepts: boolean }): Promise<void> {
        await this.withRun(runId, async () => {
            const r = await this.getRun(runId);
            if (!r || r.endedAt) return;
            if (job) {
                if (job.accepts) r.job = job.id;
                else if (r.job === null) r.job = job.id;
                else if (r.job !== job.id) return;
            }
            // a finished state is only repeated, never revived
            if (isTerminal(r.state) && ev.t !== "done" && ev.t !== "failed") return;
            const before = JSON.stringify(r);
            r.state = nextState(r.state, ev, this.d.now());
            await this.dispatch(r);
            // a poll that changes nothing writes nothing
            if (JSON.stringify(r) !== before) await this.saveRun(r);
        });
    }

    async onSave(sid: string, e: LiveSaveEvent): Promise<void> {
        if (!this.d.apns) return;
        const ev = stateEventOfSave(e);
        await Promise.all((await this.runsOf(sid)).map((run) => this.applyEvent(run, ev)));
    }

    async onRender(sid: string, job: string, e: LiveRenderEvent): Promise<void> {
        if (!this.d.apns) return;
        const ev = stateEventOfRender(e);
        const info = { id: job, accepts: e.kind === "accepted" };
        await Promise.all((await this.runsOf(sid)).map((run) => this.applyEvent(run, ev, info)));
    }

    // From the index (small entries, bounded by the run caps), not by reading run records.
    async hasActiveRuns(): Promise<boolean> {
        if (!this.d.apns) return false;
        const idx = await this.d.storage.list<RunIndexEntry>({ prefix: IDX_PREFIX });
        for (const e of idx.values()) if (e.active) return true;
        return false;
    }

    // The sweep's retry of end pushes that failed after the result was collected (the
    // render row is not looked at again then, so nothing else would re-send them).
    // Bounded: LIVE_END_RETRY_DELAYS_MS. Worker transport: DO-only work, the container is
    // not touched. Helper transport: an `end` wakes the container, as it always does.
    // Returns when the next retry is due (null: none pending), for the sweep to re-arm.
    async retryEnds(now: number = this.d.now()): Promise<{ nextInMs: number | null }> {
        if (!this.d.apns) return { nextInMs: null };
        const due: RunIndexEntry[] = [];
        for (const e of (await this.d.storage.list<RunIndexEntry>({ prefix: IDX_PREFIX })).values()) {
            if (e.retryAt !== null && e.endedAt === null && e.retryAt <= now) due.push(e);
        }
        await Promise.all(
            due.map((e) =>
                this.withRun(e.run, async () => {
                    const r = await this.getRun(e.run);
                    if (!r) {
                        await this.d.storage.delete(idxKey(e.keyId, e.run));
                        this.idxSeen.delete(e.run);
                        return;
                    }
                    const before = JSON.stringify(r);
                    await this.dispatch(r);
                    if (JSON.stringify(r) !== before) await this.saveRun(r);
                }).catch((x) => console.error("[live] end retry failed:", e.run.slice(0, 8), String(x))),
            ),
        );
        let next: number | null = null;
        for (const e of (await this.d.storage.list<RunIndexEntry>({ prefix: IDX_PREFIX })).values()) {
            if (e.retryAt !== null && e.endedAt === null) {
                const inMs = Math.max(0, e.retryAt - now);
                next = next === null ? inMs : Math.min(next, inMs);
            }
        }
        return { nextInMs: next };
    }

    // Runs older than 8 h or ended more than an hour ago, index entries without runs,
    // start tokens not refreshed for 60 days, stale health marks and start windows.
    // Index-driven: it never reads a run record.
    async cleanup(now: number = this.d.now()): Promise<void> {
        const idx = await this.d.storage.list<RunIndexEntry>({ prefix: IDX_PREFIX });
        const live = new Set<string>();
        for (const [key, e] of idx) {
            if (now - e.createdAt > LIVE_RUN_TTL_MS || (e.endedAt !== null && now - e.endedAt > LIVE_ENDED_TTL_MS)) {
                await this.d.storage.delete(`live:run:${e.run}`);
                await this.d.storage.delete(key);
                this.idxSeen.delete(e.run);
                if (e.sid) await this.indexRemove(e.sid, e.run);
            } else {
                live.add(e.run);
            }
        }
        const index = await this.d.storage.list<string[]>({ prefix: "live:sid:" });
        for (const [key, ids] of index) {
            const left = ids.filter((id) => live.has(id));
            if (left.length === 0) await this.d.storage.delete(key);
            else if (left.length !== ids.length) await this.d.storage.put(key, left);
        }
        const starts = await this.d.storage.list<StartToken>({ prefix: "live:start:" });
        for (const [key, t] of starts) {
            if (now - t.updatedAt > LIVE_START_TOKEN_TTL_MS) await this.d.storage.delete(key);
        }
        const health = await this.d.storage.list<Health>({ prefix: "live:health:" });
        for (const [key, h] of health) {
            if (now - h.badAt >= LIVE_HEALTH_MS) {
                await this.d.storage.delete(key);
                this.health.set(key.slice("live:health:".length), null);
            }
        }
        const windows = await this.d.storage.list<number>({ prefix: START_WINDOW_PREFIX });
        for (const [key, at] of windows) {
            if (now - at >= LIVE_START_MIN_GAP_MS) await this.d.storage.delete(key);
        }
    }

    // ---- routes ----

    async putStartToken(keyId: string, raw: string): Promise<LiveReply> {
        const b = parseJson(raw);
        if (!b || typeof b.token !== "string" || !TOKEN_REGEX.test(b.token) || !isEnv(b.environment)) return badRequest();
        await this.d.storage.put(`live:start:${keyId}`, { token: b.token, env: b.environment, updatedAt: this.d.now() } satisfies StartToken);
        return noContent();
    }

    async deleteStartToken(keyId: string): Promise<LiveReply> {
        await this.d.storage.delete(`live:start:${keyId}`);
        return noContent();
    }

    private async sessionOwnedBy(sid: string, keyId: string): Promise<boolean | "error"> {
        try {
            const row = await this.d.db
                .prepare("SELECT key_id FROM studio_sessions WHERE id = ?1")
                .bind(sid)
                .first<{ key_id: string | null }>();
            return !!row && row.key_id === keyId;
        } catch {
            return "error";
        }
    }

    // At most one start push per key per LIVE_START_MIN_GAP_MS, counted when the push is
    // about to go (a failed one uses the window too).
    private reserveStart(keyId: string, now: number): Promise<boolean> {
        return this.serial(async () => {
            const key = `${START_WINDOW_PREFIX}${keyId}`;
            const last = await this.d.storage.get<number>(key);
            if (last !== undefined && now - last < LIVE_START_MIN_GAP_MS) return false;
            await this.d.storage.put(key, now);
            return true;
        });
    }

    async putRun(keyId: string, run: string, raw: string): Promise<LiveReply> {
        const b = parseJson(raw);
        const reg = b && parseRegistration(run, b);
        if (!reg) return badRequest();
        if (reg.session) {
            const owned = await this.sessionOwnedBy(reg.session, keyId);
            if (owned === "error") return err(503, "error.api.generic");
            if (!owned) return notFound();
        }
        try {
            await this.cleanup();
        } catch (e) {
            console.error("[live] cleanup failed", String(e));
        }
        if (!this.d.apns) {
            return { status: 200, body: { status: "success", pushing: false, started: false, reason: "not_configured" } };
        }

        return this.withRun(run, async () => {
            const now = this.d.now();
            const found = await this.getRun(run);
            if (found && found.keyId !== keyId) return notFound();

            const previousSid = found?.sid ?? null;
            const previousToken = found?.updateToken ?? null;
            const targetSid = reg.session ?? previousSid;
            let created: RunRecord | null = null;

            // Caps, checked and committed together (one at a time) before anything else is
            // written: a key may hold at most LIVE_MAX_OPEN_RUNS_PER_KEY runs that have not
            // ended (LIVE_MAX_RUNS_PER_KEY counting the ended ones kept for an hour), and a
            // session at most LIVE_MAX_RUNS_PER_SID runs. Each run is an alert-bearing push
            // with caller-supplied text, so unbounded runs would be unbounded pushes and
            // unbounded work in the one Durable Object.
            const rejected = await this.serial(async (): Promise<LiveReply | null> => {
                if (!found) {
                    const mine = await this.indexOfKey(keyId);
                    let open = 0;
                    for (const e of mine.values()) if (e.endedAt === null) open++;
                    if (open >= LIVE_MAX_OPEN_RUNS_PER_KEY || mine.size >= LIVE_MAX_RUNS_PER_KEY) return tooManyRuns();
                }
                if (targetSid && targetSid !== previousSid) {
                    const ids = await this.runsOf(targetSid);
                    if (ids.length >= LIVE_MAX_RUNS_PER_SID && !ids.includes(run)) return tooManyRuns();
                    await this.indexAdd(targetSid, run);
                    if (previousSid) await this.indexRemove(previousSid, run);
                }
                if (!found) {
                    created = {
                        run,
                        keyId,
                        sid: reg.session,
                        job: null,
                        env: reg.env,
                        updateToken: reg.updateToken,
                        attributes: reg.attributes,
                        state: reg.state,
                        sent: null,
                        lastPushAt: 0,
                        startedAt: null,
                        endedAt: null,
                        createdAt: now,
                    };
                    // visible to the next caller's count at once
                    await this.saveRun(created);
                }
                return null;
            });
            if (rejected) return rejected;

            const r: RunRecord = (found ?? created)!;
            let replaced = false;
            if (found) {
                r.env = reg.env;
                if (reg.updateToken) r.updateToken = reg.updateToken;
                if (reg.session) r.sid = reg.session;
                // the stored state is replaced only by a device-owned stage
                if (DEVICE_STAGES.includes(reg.state.stage) && !sameState(r.state, reg.state) && !r.endedAt) {
                    r.state = reg.state;
                    replaced = true;
                }
            }

            let started = false;
            let reason: "no_start_token" | "start_unconfirmed" | "start_rate_limited" | undefined;
            if (reg.start && !r.updateToken && r.startedAt === null && !r.endedAt) {
                if (r.startAttemptedAt) {
                    // An earlier start left the building and its outcome is unknown: Apple may
                    // already have started the activity. Sending another could make two, so it
                    // is NOT re-sent (the conservative choice: at worst this run's activity
                    // never appears, and the app's own local activity or the update token it
                    // reports settles the question).
                    reason = "start_unconfirmed";
                } else {
                    const start = await this.d.storage.get<StartToken>(`live:start:${keyId}`);
                    if (!start) {
                        reason = "no_start_token";
                    } else if (!(await this.reserveStart(keyId, now))) {
                        reason = "start_rate_limited";
                    } else {
                        // recorded before any byte leaves
                        r.startAttemptedAt = now;
                        await this.saveRun(r);
                        const push: ApnsPush = {
                            event: "start",
                            priority: 10,
                            expiration: secs(now) + EXPIRE_STAGE_S,
                            payload: startPayload(r.attributes, r.state, now),
                        };
                        const dlv = await this.d.apns!.deliver(start.token, start.env, push, run);
                        if (dlv.kind === "sent") {
                            started = true;
                            r.startedAt = this.d.now();
                            r.sent = r.state;
                            r.lastPushAt = this.d.now();
                            await this.markOk(keyId);
                            if (dlv.env !== start.env) {
                                await this.d.storage.put(`live:start:${keyId}`, { ...start, env: dlv.env } satisfies StartToken);
                            }
                        } else if (dlv.kind === "drop") {
                            r.startAttemptedAt = null;
                            await this.d.storage.delete(`live:start:${keyId}`);
                            reason = "no_start_token";
                        } else if (dlv.kind === "unhealthy") {
                            await this.markBad(keyId, `${dlv.status} ${dlv.reason}`);
                            if (dlv.maybeDelivered) reason = "start_unconfirmed";
                            else r.startAttemptedAt = null; // provably not sent (a refusal, a wake or jwt failure): a retry is safe
                        } else {
                            r.startAttemptedAt = null; // 429 or skipped: nothing was accepted
                        }
                    }
                }
            }

            const tokenArrived = !!r.updateToken && r.updateToken !== previousToken;
            if (tokenArrived && !sameState(r.state, r.sent)) await this.dispatch(r, true);
            else if (replaced) await this.dispatch(r);
            await this.saveRun(r);

            const pushing = await this.healthy(keyId);
            return {
                status: 200,
                body: { status: "success", pushing, started, ...(reason ? { reason } : {}) },
            };
        });
    }

    async relayState(keyId: string, run: string, raw: string): Promise<LiveReply> {
        const b = parseJson(raw);
        const state = b && sanitizeState(b.state);
        if (!state) return badRequest();
        const found = await this.getRun(run);
        if (!found || found.keyId !== keyId) return notFound();
        if (!DEVICE_STAGES.includes(state.stage)) return err(409, "error.live.server_stage");
        await this.withRun(run, async () => {
            const r = await this.getRun(run);
            if (!r || r.endedAt) return;
            r.state = state;
            await this.dispatch(r);
            await this.saveRun(r);
        });
        return { status: 202, body: { status: "success" } };
    }

    async deleteRun(keyId: string, run: string): Promise<LiveReply> {
        await this.withRun(run, async () => {
            const r = await this.getRun(run);
            if (!r || r.keyId !== keyId) return;
            if (this.d.apns && r.updateToken && !r.endedAt) {
                const now = this.d.now();
                const dlv = await this.d.apns.deliver(
                    r.updateToken,
                    r.env,
                    {
                        event: "end",
                        priority: 10,
                        expiration: secs(now) + EXPIRE_STAGE_S,
                        payload: endPayload(r.attributes, r.state, now, true),
                    },
                    run,
                );
                if (dlv.kind === "unhealthy") await this.markBad(keyId, `${dlv.status} ${dlv.reason}`);
                if (dlv.kind === "sent") await this.markOk(keyId);
            }
            await this.removeRun(run, r.keyId, r.sid);
        });
        return noContent();
    }

    // GET /live/selftest (8.6): never returns the JWT or the key.
    async selftest(): Promise<LiveReply> {
        const apns = this.d.apns;
        if (!apns) return { status: 200, body: { status: "success", configured: false } };
        const now = this.d.now();
        const state: LiveState = { stage: "fetching", rail: 0, since: secs(now), waking: false, packing: false };
        const r = await apns.selftest(updatePayload(state, now), secs(now) + EXPIRE_COUNTER_S);
        return { status: 200, body: { status: "success", configured: true, ...r } };
    }
}

// ---- routing (inside the Durable Object) ------------------------------------------

export const isLiveRoute = (pathname: string) => pathname === "/live" || pathname.startsWith("/live/");

const toResponse = (r: LiveReply) =>
    r.body === null
        ? new Response(null, { status: r.status })
        : new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });

// Never calls super.fetch and never wakes the container. The Worker sets the key id
// after its D1 lookup; a request without it is refused.
export async function handleLiveRoute(service: LiveService, request: Request): Promise<Response> {
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });

    const p = new URL(request.url).pathname;
    const m = request.method;
    const reply = async (): Promise<LiveReply> => {
        const body = async (): Promise<string | null> => {
            const declared = Number(request.headers.get("content-length"));
            if (Number.isFinite(declared) && declared > LIVE_MAX_BODY_BYTES) return null;
            const text = await request.text();
            return new TextEncoder().encode(text).length > LIVE_MAX_BODY_BYTES ? null : text;
        };
        if (p === "/live/start-token") {
            if (m === "PUT") {
                const text = await body();
                return text === null ? badRequest() : service.putStartToken(keyId, text);
            }
            if (m === "DELETE") return service.deleteStartToken(keyId);
        }
        if (p === "/live/selftest" && m === "GET") return service.selftest();
        const parts = p.split("/"); // "", "live", "runs", <run>, "state"?
        if (parts[1] === "live" && parts[2] === "runs" && RUN_ID_REGEX.test(parts[3] ?? "")) {
            const run = parts[3]!;
            if (parts.length === 4) {
                if (m === "PUT") {
                    const text = await body();
                    return text === null ? badRequest() : service.putRun(keyId, run, text);
                }
                if (m === "DELETE") return service.deleteRun(keyId, run);
            }
            if (parts.length === 5 && parts[4] === "state" && m === "POST") {
                const text = await body();
                return text === null ? badRequest() : service.relayState(keyId, run, text);
            }
        }
        return { status: 404, body: null };
    };
    return toResponse(await reply());
}
