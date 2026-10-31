// The EditRenderer's decisions (APP-API-CONTRACT.md section 31.8-31.11): claim a queued render from D1, stream its
// sources from R2 into the render container, start it, wait for it, copy the MP4 and a poster back into R2, file the
// library row, tell the owner, and clean up. No Cloudflare imports, so it runs under plain node in the tests with a
// fake container and D1 on node:sqlite; src/edit-renderer.ts wires it to the real Container class.
//
// Everything is poll-driven (CLAUDE.md: work after a Durable Object response does not survive): `tick()` runs ONE bounded
// step and says when to run again; the Containers library's alarm loop calls it. The step record (storage key `render`)
// is written before `step` moves, and every step is idempotent, so a tick that dies (an eviction, a deploy) is simply run
// again. Every container call is raced against our own ceiling (raceCeiling): AbortSignal timeouts are not honoured
// on containerFetch inside a Durable Object. Streams are copied by `fixedLength` (a reader/writer loop in production),
// never pipeTo().

import { cleanName } from "./app-routes";
import { raceCeiling } from "./ceiling";
import {
    EDIT_MAX_OUTPUT_BYTES,
    checkEditSources,
    sourceKind,
    timelineItems,
    type RenderRow,
    type SourceRow,
    type Timeline,
} from "./edits";
import { randomBase62 } from "./ids";
import { insertMediaItem } from "./library";
import { formatBytes } from "./live";
import { HARK_MAX_BODY, JOBS_URL, plainReason } from "./notify";
import { MAX_POSTER_BYTES } from "./poster";
import type { PublishBucket } from "./publish";
import { upsertTitle, type OriginalsBucket } from "./studio";
import { MEDIA_NAME_LENGTH, type KV } from "./webp";

// ---- constants --------------------------------------------------------------------------------------------------

// the DO storage keys
export const RENDER_KEY = "render";
export const TICK_KEY = "tick:at";

// seconds to the next tick
export const STEP_NOW_S = 0;
export const STEP_NEXT_S = 2;
export const WAIT_S = 5;

// our own ceilings (ms)
export const START_CONTAINER_MS = 60_000;
export const CALL_MS = 15_000;
export const START_CALL_MS = 30_000;
export const FILE_HEAD_MS = 60_000;
export const POSTER_MS = 60_000;
export const HARK_MS = 3_000;
export const LIVE_EDIT_MS = 3_000;
export const R2_GET_MS = 30_000;
// the slowest copy we plan for: a stream through a tick moves at least this much per second
export const COPY_BYTES_PER_S = 4_000_000;
export const COPY_MIN_MS = 120_000;
export const copyMs = (bytes: number) => Math.max(COPY_MIN_MS, Math.ceil(bytes / COPY_BYTES_PER_S) * 1000);

// a step that fails this many times in a row (not a verdict, an exception or a transport failure) stops the render
export const STEP_TRIES = 3;
export const BUSY_TRIES = 6;
export const POLL_FAILS = 6;
export const COLLECT_TRIES = 2;
export const NOTIFY_TRIES = 3;
export const CLEAN_TRIES = 3;
export const TICK_FAILS = 8;

// deadline after the start: clamp(180 s + 4 x seconds_total, 300 s, 2700 s)
export const deadlineMs = (secondsTotal: number) => Math.min(2_700_000, Math.max(300_000, 180_000 + 4_000 * secondsTotal));

const CLAIMED = ["preparing", "rendering", "finishing"];
const FINAL_CODES = new Set([
    "error.edit.render_failed",
    "error.edit.timeout",
    "error.edit.source_missing",
    "error.edit.unsupported_source",
    "error.edit.past_source_end",
    "error.edit.range",
    "error.edit.too_large",
    "error.edit.storage",
    "error.edit.lost",
    "error.edit.cancelled",
]);
// What the helper's own refusals (31.9) mean as a render outcome. Anything else is "the video couldn't be made".
export const renderErrorCode = (code: unknown): string =>
    typeof code === "string" && FINAL_CODES.has(code) ? code : "error.edit.render_failed";

// ---- records ----------------------------------------------------------------------------------------------------

export type InputRef = { n: number; item: string; bucket: "media" | "originals"; key: string; bytes: number; kind: "video" | "gif" | "photo" };
export type StepName = "inputs" | "start" | "wait" | "collect" | "poster" | "record" | "notify" | "cleanup";
export type RenderResult = { bytes: number; width: number; height: number; duration: number };

export type StepRecord = {
    rid: string;
    step: StepName;
    // the next input to send
    n: number;
    inputs: InputRef[];
    startedAt: number;
    deadline: number;
    retried: boolean;
    // consecutive failures of the current step
    tries?: number;
    // consecutive polls that could not reach the container
    pollFails?: number;
    // consecutive "busy" answers to an input
    busy?: number;
    // consecutive ticks that threw
    fails?: number;
    // bytes sent into the container (the progress)
    sent?: number;
    // a container call has been made for this render (cleanup deletes the container's copy only then)
    container?: boolean;
    result?: RenderResult;
    // `edits/<rid>.mp4` may exist (written, or being written)
    mp4?: boolean;
    // the poster object, until the library row names it
    posterName?: string;
    posterUrl?: string | null;
    posterDone?: boolean;
    collectTries?: number;
    // how the render ended; notify and cleanup read it
    ended?: { status: "done" | "error" | "cancelled"; code: string | null };
    notifyTries?: number;
    cleanTries?: number;
    // a chat video (section 45): the inputs come from the frozen spec; one that is gone is skipped (listed here)
    chat?: boolean;
    missing?: number[];
};

// ---- chat videos (section 45) ----------------------------------------------------------------------------------------

// The frozen spec of a chat render (`edit_renders.timeline` when `kind` is 'chat'; built by src/chat-video.ts).
export type ChatSpec = {
    kind: "chat";
    thread_id: string;
    options: { shape: string; theme: string; speed: number };
    snapshot: { messages: unknown[]; posts: Record<string, unknown> } & Record<string, unknown>;
    inputs: InputRef[];
};

// The inputs of a chat spec, checked; null when the spec is not one.
export function chatSpecInputs(text: string): InputRef[] | null {
    let spec: ChatSpec;
    try {
        spec = JSON.parse(text) as ChatSpec;
    } catch {
        return null;
    }
    if (!spec || spec.kind !== "chat" || !Array.isArray(spec.inputs) || typeof spec.snapshot !== "object" || spec.snapshot === null) return null;
    const out: InputRef[] = [];
    for (const i of spec.inputs) {
        if (!i || !Number.isInteger(i.n) || i.n < 0 || i.n >= 50 || typeof i.item !== "string" || typeof i.key !== "string") return null;
        if (i.bucket !== "media" && i.bucket !== "originals") return null;
        if (i.kind !== "video" && i.kind !== "gif" && i.kind !== "photo") return null;
        out.push({ n: i.n, item: i.item, bucket: i.bucket, key: i.key, bytes: Number(i.bytes) || 0, kind: i.kind });
    }
    return out;
}

// ---- messages (31.11) -----------------------------------------------------------------------------------------------

const clip = (s: string, max: number): string => {
    const chars = [...s];
    return chars.length <= max ? s : `${chars.slice(0, max - 1).join("")}…`;
};

const mss = (seconds: number): string => {
    const s = Math.max(0, Math.round(seconds));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

// done: `<title> · video ready · <w>×<h> · <m:ss> · <size>`; private, so no link line. Taps open the queue.
export function editDoneMessage(title: string, r: RenderResult): { title: string; body: string; url: string } {
    const body = `${title} · video ready · ${r.width}×${r.height} · ${mss(r.duration)} · ${formatBytes(r.bytes)}`;
    return { title: "capystore", body: clip(body, HARK_MAX_BODY), url: JOBS_URL };
}

export function editFailedMessage(title: string, code: string): { title: string; body: string; url: string } {
    return { title: "capystore", body: clip(`couldn't render ${title} — ${plainReason(code)}`, HARK_MAX_BODY), url: JOBS_URL };
}

// Sends the failure message of an errored render that asked for one and has not had it (`notified_at` is the marker),
// once, 3 s cap, no retries. For the paths with no step record: the cron's `lost` and a restarted instance's own `lost`.
export async function notifyEndedRow(
    d: { db: D1Database; hark: string | null | undefined; harkFetch?: (url: string, init: RequestInit) => Promise<Response>; now: () => number },
    rid: string,
): Promise<void> {
    if (!d.hark) return;
    const row = await d.db
        .prepare("SELECT title, status, error_code, notify, notified_at FROM edit_renders WHERE id = ?1")
        .bind(rid)
        .first<{ title: string; status: string; error_code: string | null; notify: number; notified_at: number | null }>();
    if (!row || row.status !== "error" || row.notify !== 1 || row.notified_at !== null) return;
    const msg = editFailedMessage(row.title, row.error_code ?? "error.edit.lost");
    const ac = new AbortController();
    try {
        const res = await raceCeiling(
            (d.harkFetch ?? ((u, i) => fetch(u, i)))(d.hark, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify(msg),
                redirect: "manual",
                signal: ac.signal,
            }),
            HARK_MS,
            "hark",
        );
        await res.body?.cancel().catch(() => {});
        if (res.status >= 200 && res.status < 300) {
            await d.db.prepare("UPDATE edit_renders SET notified_at = ?1 WHERE id = ?2 AND notified_at IS NULL").bind(d.now(), rid).run();
        }
    } catch {
        ac.abort();
    }
}

// ---- dependencies -----------------------------------------------------------------------------------------------------

export type EditCoreDeps = {
    // 'r0' | 'r1'
    instance: string;
    db: D1Database;
    storage: KV;
    // `cobalt-originals` (the sources, the result) and `cobalt-media` (the poster, public sources)
    originals: OriginalsBucket;
    media: PublishBucket;
    mediaBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    // Wraps a stream so R2 accepts it (FixedLengthStream + a reader/writer copy loop in production).
    fixedLength: (stream: ReadableStream, length: number, onChunk?: (n: number) => void) => ReadableStream;
    // startAndWaitForPorts(9200)
    ensureRunning: () => Promise<void>;
    isRunning: () => boolean;
    // containerFetch to the render helper (port 9200, x-internal-key added by the caller of this dep)
    container: (path: string, init?: RequestInit) => Promise<Response>;
    renew?: () => void;
    // the library's schedule(seconds, "tick")
    schedule: (seconds: number) => Promise<unknown>;
    // Before a claim, while this instance holds no render: restart a container that runs with an old env (31.8).
    beforeClaim?: () => Promise<void>;
    // The Hark webhook URL (harkConfigFrom), or null: the bridge is off and nothing is sent.
    hark: string | null;
    harkFetch?: (url: string, init: RequestInit) => Promise<Response>;
    // After a tick that held a render: let its Live Activity catch up (section 32; the main Durable Object decides whether
    // anything is pushed). Raced against LIVE_EDIT_MS, errors swallowed: a push never holds up or fails a render.
    liveEdit?: (rid: string) => Promise<void>;
    log?: (line: string) => void;
};

type Outcome = number | null;

type ClaimRow = RenderRow & { kind?: string | null; timeline: string; key_id: string | null; notify: number; notified_at: number | null; instance: string | null; attempts: number };

const json = async (res: Response): Promise<any> => {
    try {
        return await res.json();
    } catch {
        return null;
    }
};

export class EditRenderCore {
    private running: Promise<void> | null = null;
    // a kick that arrived while a tick was running (the tick may have looked before the new row was there)
    private kicked = false;

    constructor(private d: EditCoreDeps) {}

    private log(line: string) {
        (this.d.log ?? ((l) => console.log(l)))(`[edit-render] ${this.d.instance} ${line}`);
    }

    // ---- scheduling ----------------------------------------------------------------------------------------------------

    // Arms the tick unless one is already due no later than asked (de-duplicated like sweep.ts's `sweep:at`, under
    // `tick:at`). A stored time in the past is stale (the alarm never ran) and is scheduled over.
    async arm(delayS: number): Promise<boolean> {
        const now = this.d.now();
        const at = await this.d.storage.get<number>(TICK_KEY);
        if (at !== undefined && at >= now && at <= now + delayS * 1000 + 1000) return false;
        await this.d.storage.put(TICK_KEY, now + delayS * 1000);
        await this.d.schedule(delayS);
        return true;
    }

    // POST /kick: only arms the tick (the answer is 202 at once; all work happens in tick()).
    async kick(): Promise<void> {
        if (this.running) {
            this.kicked = true;
            return;
        }
        await this.arm(STEP_NOW_S);
    }

    // The schedule's callback. Runs one step and re-arms. Never rejects.
    async tick(): Promise<void> {
        const prev = this.running;
        const p: Promise<void> = (async () => {
            if (prev) await prev.catch(() => {});
            await this.runTick();
        })().finally(() => {
            if (this.running === p) this.running = null;
        });
        this.running = p;
        await p.catch((e) => console.error("[edit-render] tick failed", String(e)));
    }

    private async runTick(): Promise<void> {
        // this schedule has fired; a kick from here on is for what this step may not have seen
        this.kicked = false;
        await this.d.storage.delete(TICK_KEY);
        const before = (await this.d.storage.get<StepRecord>(RENDER_KEY))?.rid ?? null;
        let next: Outcome;
        try {
            next = await this.step();
            await this.clearFails();
        } catch (e) {
            console.error("[edit-render] step threw", e instanceof Error ? `${e.name}: ${e.message}` : String(e));
            next = await this.afterThrow();
        }
        // the render this tick held (it may have just ended) and the one it holds now (a claim after a cleanup)
        const after = (await this.d.storage.get<StepRecord>(RENDER_KEY).catch(() => undefined))?.rid ?? null;
        for (const rid of new Set([before, after])) if (rid) await this.pushLive(rid);
        if (next === null && this.kicked) next = STEP_NOW_S;
        if (next !== null) await this.arm(next);
    }

    private async pushLive(rid: string): Promise<void> {
        const live = this.d.liveEdit;
        if (!live) return;
        try {
            await raceCeiling(live(rid), LIVE_EDIT_MS, "live edit push");
        } catch (e) {
            console.error("[edit-render] live push failed", e instanceof Error ? e.message : String(e));
        }
    }

    // A step that came back: the render's count of ticks that threw starts again.
    private async clearFails(): Promise<void> {
        const rec = await this.d.storage.get<StepRecord>(RENDER_KEY);
        if (rec?.fails) {
            rec.fails = 0;
            await this.d.storage.put(RENDER_KEY, rec);
        }
    }

    // A step that threw: a held render gets a few more ticks, then it ends (a hole in the machine must not loop for ever). If
    // even ending it fails (D1 is down), the record is dropped and ticking stops: the row goes stale and the cron re-queues it.
    private async afterThrow(): Promise<Outcome> {
        try {
            const rec = await this.d.storage.get<StepRecord>(RENDER_KEY);
            if (!rec) return null;
            rec.fails = (rec.fails ?? 0) + 1;
            if (rec.fails < TICK_FAILS) {
                await this.d.storage.put(RENDER_KEY, rec);
                return STEP_NEXT_S;
            }
            if (rec.step !== "notify" && rec.step !== "cleanup") {
                try {
                    return await this.end(rec, "error", "error.edit.render_failed");
                } catch (e) {
                    console.error("[edit-render] could not end the render", String(e));
                    await this.deleteLeftovers(rec).catch(() => {});
                    await this.d.storage.delete(RENDER_KEY);
                    return null;
                }
            }
            // notify / cleanup keep failing: give them up and release the instance
            await this.deleteLeftovers(rec).catch(() => {});
            await this.d.storage.delete(RENDER_KEY);
            return STEP_NOW_S;
        } catch {
            return null;
        }
    }

    // ---- the machine -----------------------------------------------------------------------------------------------------

    private async step(): Promise<Outcome> {
        const rec = await this.d.storage.get<StepRecord>(RENDER_KEY);
        if (!rec) return await this.claimNext();
        if (rec.step === "notify") return await this.stepNotify(rec);
        if (rec.step === "cleanup") return await this.stepCleanup(rec);

        // The row is the truth: ours, still claimed, and not asked to stop.
        const row = await this.loadRow(rec.rid);
        if (!row || row.instance !== this.d.instance || !CLAIMED.includes(row.status)) return await this.abandon(rec, row);
        if (row.cancel_requested === 1) return await this.end(rec, "cancelled", "error.edit.cancelled");

        switch (rec.step) {
            case "inputs":
                return await this.stepInputs(rec);
            case "start":
                return await this.stepStart(rec, row);
            case "wait":
                return await this.stepWait(rec);
            case "collect":
                return await this.stepCollect(rec, row);
            case "poster":
                return await this.stepPoster(rec);
            case "record":
                return await this.stepRecord(rec, row);
        }
    }

    private loadRow(rid: string): Promise<ClaimRow | null> {
        return this.d.db.prepare("SELECT * FROM edit_renders WHERE id = ?1").bind(rid).first<ClaimRow>();
    }

    // Someone else decided this render's fate (the cron re-queued or ended it, the row is gone): drop our record and
    // the container's copy. Our R2 leftovers are deleted only when the row ended for good: a re-queued render may
    // already be written again under the same key by the next claim.
    private async abandon(rec: StepRecord, row: ClaimRow | null): Promise<Outcome> {
        this.log(`abandoning ${rec.rid}: ${row ? `${row.status}/${row.instance ?? "-"}` : "row gone"}`);
        if (!row || row.status === "error" || row.status === "cancelled") await this.deleteLeftovers(rec);
        else if (rec.posterName) {
            // the poster's name is unique to this attempt: safe to delete whatever happened to the row
            try {
                await this.d.media.delete(rec.posterName);
                rec.posterName = undefined;
            } catch (e) {
                console.error("[edit-render] deleting the unrecorded poster failed", String(e));
            }
        }
        rec.ended = undefined;
        rec.step = "cleanup";
        rec.tries = 0;
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NOW_S;
    }

    // ---- 1. claim ------------------------------------------------------------------------------------------------------

    private async claimNext(): Promise<Outcome> {
        // Holding no render: a container that runs with an old env is restarted now (a rollout keeps the old env).
        try {
            await this.d.beforeClaim?.();
        } catch (e) {
            console.error("[edit-render] env check failed", String(e));
        }
        await this.requeueOwn();
        const now = this.d.now();
        const row = await this.d.db
            .prepare(
                `UPDATE edit_renders SET status = 'preparing', instance = ?1, attempts = attempts + 1, started_at = ?2, updated_at = ?2
                  WHERE id = (SELECT id FROM edit_renders WHERE status = 'queued' AND cancel_requested = 0 ORDER BY created_at, id LIMIT 1)
                    AND status = 'queued'
              RETURNING *`,
            )
            .bind(this.d.instance, now)
            .first<ClaimRow>();
        if (!row) return null;
        return await this.begin(row);
    }

    // A row marked with this instance's name while it holds no record lost its work: back into the line (or lost).
    private async requeueOwn(): Promise<void> {
        const now = this.d.now();
        const { results } = await this.d.db
            .prepare("SELECT id, attempts FROM edit_renders WHERE instance = ?1 AND status IN ('preparing', 'rendering', 'finishing')")
            .bind(this.d.instance)
            .all<{ id: string; attempts: number }>();
        for (const r of results) {
            if (r.attempts < 2) {
                await this.d.db
                    .prepare(
                        "UPDATE edit_renders SET status = 'queued', instance = NULL, started_at = NULL, sent_bytes = NULL, seconds_done = NULL, updated_at = ?1 WHERE id = ?2 AND instance = ?3 AND status IN ('preparing', 'rendering', 'finishing')",
                    )
                    .bind(now, r.id, this.d.instance)
                    .run();
            } else {
                const res = await this.d.db
                    .prepare(
                        "UPDATE edit_renders SET status = 'error', error_code = 'error.edit.lost', finished_at = ?1, updated_at = ?1 WHERE id = ?2 AND instance = ?3 AND status IN ('preparing', 'rendering', 'finishing')",
                    )
                    .bind(now, r.id, this.d.instance)
                    .run();
                if (Number(res.meta?.changes ?? 0) > 0) await this.notifyEnded(r.id).catch(() => {});
            }
        }
    }

    // The claimed render's inputs: the library rows of its items, checked again (a clip may have been deleted since it was queued).
    private async begin(row: ClaimRow): Promise<Outcome> {
        const now = this.d.now();
        const rec: StepRecord = {
            rid: row.id,
            step: "inputs",
            n: 0,
            inputs: [],
            startedAt: now,
            deadline: 0,
            retried: false,
        };
        if (row.kind === "chat") {
            const inputs = chatSpecInputs(row.timeline);
            if (!inputs) return await this.end(rec, "error", "error.edit.render_failed");
            rec.chat = true;
            rec.inputs = inputs;
            await this.d.storage.put(RENDER_KEY, rec);
            if (!(await this.ensure(rec))) {
                await this.d.storage.put(RENDER_KEY, rec);
                return await this.lose(rec, "the container would not start");
            }
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NOW_S;
        }
        let timeline: Timeline;
        try {
            timeline = JSON.parse(row.timeline) as Timeline;
        } catch {
            return await this.end(rec, "error", "error.edit.render_failed");
        }
        const items = timelineItems(timeline);
        const marks = items.map((_, i) => `?${i + 1}`).join(", ");
        const { results } = await this.d.db
            .prepare(
                `SELECT id, bucket, r2_key, bytes, content_type, source, width, height, duration, deleted_at FROM media_items WHERE id IN (${marks})`,
            )
            .bind(...items)
            .all<{
                id: string;
                bucket: string;
                r2_key: string;
                bytes: number | null;
                content_type: string | null;
                source: string | null;
                width: number | null;
                height: number | null;
                duration: number | null;
                deleted_at: number | null;
            }>();
        const byId = new Map(results.map((r) => [r.id, r]));
        const rows: SourceRow[] = results.map((r) => ({
            id: r.id,
            content_type: r.content_type,
            source: r.source,
            width: r.width,
            height: r.height,
            duration: r.duration,
            bytes: r.bytes,
            deleted: r.deleted_at !== null,
        }));
        const checked = checkEditSources(timeline, rows);
        if (!checked.ok) return await this.end(rec, "error", renderErrorCode(checked.code === "error.edit.not_video" ? "error.edit.unsupported_source" : checked.code));
        for (const [n, id] of items.entries()) {
            const r = byId.get(id)!;
            const kind = sourceKind(r.content_type);
            if (kind === "unsupported" || (r.bucket !== "media" && r.bucket !== "originals")) {
                return await this.end(rec, "error", "error.edit.unsupported_source");
            }
            rec.inputs.push({ n, item: id, bucket: r.bucket, key: r.r2_key, bytes: r.bytes ?? 0, kind });
        }
        await this.d.storage.put(RENDER_KEY, rec);
        // start the container (60 s); a container that will not start loses the render's work (31.9)
        if (!(await this.ensure(rec))) {
            await this.d.storage.put(RENDER_KEY, rec);
            return await this.lose(rec, "the container would not start");
        }
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NOW_S;
    }

    // ---- container helpers ---------------------------------------------------------------------------------------------

    private async ensure(rec: StepRecord): Promise<boolean> {
        try {
            await raceCeiling(this.d.ensureRunning(), START_CONTAINER_MS, "start edit container");
            rec.container = true;
            return true;
        } catch (e) {
            console.error("[edit-render] container did not start", String(e));
            return false;
        }
    }

    private async call(rec: StepRecord, path: string, init: RequestInit, ms: number, label: string): Promise<Response> {
        rec.container = true;
        this.d.renew?.();
        return await raceCeiling(this.d.container(path, init), ms, label);
    }

    // The container lost this render's work (a 404 for the rid, a container that will not start): once back to the
    // first input (the R2 copies are still there), then `error.edit.lost` (31.9).
    private async lose(rec: StepRecord, why: string): Promise<Outcome> {
        this.log(`${rec.rid} lost its container work: ${why}${rec.retried ? " (second time)" : ""}`);
        if (rec.retried) return await this.end(rec, "error", "error.edit.lost");
        rec.retried = true;
        // The container may still hold this render id (a busy 409 for our own rid): free it, or the retry from input 0 meets
        // the same answer. Best effort, capped; a dead or absent container has nothing to free.
        if (rec.container && this.d.isRunning()) {
            try {
                const res = await this.call(rec, `/renders/${rec.rid}`, { method: "DELETE" }, CALL_MS, "edit delete");
                await res.body?.cancel().catch(() => {});
            } catch (e) {
                this.log(`${rec.rid} freeing the container's copy failed: ${String(e)}`);
            }
        }
        rec.step = "inputs";
        rec.n = 0;
        rec.tries = 0;
        rec.busy = 0;
        rec.pollFails = 0;
        rec.sent = 0;
        rec.missing = undefined;
        rec.result = undefined;
        await this.d.db
            .prepare(
                "UPDATE edit_renders SET status = 'preparing', sent_bytes = 0, seconds_done = NULL, updated_at = ?1 WHERE id = ?2 AND instance = ?3 AND status IN ('preparing', 'rendering', 'finishing')",
            )
            .bind(this.d.now(), rec.rid, this.d.instance)
            .run();
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // A failure that deserves another tick; after STEP_TRIES in a row the container's work is taken as lost.
    private async retry(rec: StepRecord, why: string): Promise<Outcome> {
        rec.tries = (rec.tries ?? 0) + 1;
        this.log(`${rec.rid} ${rec.step} failed (${rec.tries}/${STEP_TRIES}): ${why}`);
        if (rec.tries >= STEP_TRIES) return await this.lose(rec, why);
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // ---- 2. inputs -----------------------------------------------------------------------------------------------------

    private async stepInputs(rec: StepRecord): Promise<Outcome> {
        const inp = rec.inputs[rec.n];
        if (!inp) {
            rec.step = "start";
            rec.tries = 0;
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NOW_S;
        }
        if (!(await this.ensure(rec))) return await this.retry(rec, "container will not start");

        const store = inp.bucket === "originals" ? this.d.originals : this.d.media;
        let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
        try {
            obj = await raceCeiling(store.get(inp.key), R2_GET_MS, "edit input get");
        } catch (e) {
            return await this.retry(rec, `R2 get: ${String(e)}`);
        }
        if (!obj && rec.chat) {
            // a chat video draws a file that is gone without its picture (45.4)
            rec.missing = [...(rec.missing ?? []), inp.n];
            rec.n += 1;
            if (rec.n >= rec.inputs.length) rec.step = "start";
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NOW_S;
        }
        if (!obj) return await this.end(rec, "error", "error.edit.source_missing");

        let res: Response;
        try {
            res = await this.call(
                rec,
                `/renders/${rec.rid}/inputs/${inp.n}`,
                {
                    method: "PUT",
                    headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) },
                    body: this.d.fixedLength(obj.body, obj.size, () => this.d.renew?.()),
                    // a streamed body needs half-duplex in some runtimes
                    duplex: "half",
                } as RequestInit,
                copyMs(obj.size),
                "edit input",
            );
        } catch (e) {
            await obj.body.cancel().catch(() => {});
            return await this.retry(rec, `input ${inp.n}: ${String(e)}`);
        }
        await res.body?.cancel().catch(() => {});
        if (res.status === 413) return await this.end(rec, "error", "error.edit.too_large");
        if (res.status === 400) return await this.end(rec, "error", "error.edit.render_failed");
        if (res.status === 409) {
            rec.busy = (rec.busy ?? 0) + 1;
            if (rec.busy >= BUSY_TRIES) return await this.lose(rec, "the container stayed busy");
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NEXT_S;
        }
        if (res.status === 404) return await this.lose(rec, `input ${inp.n}: 404`);
        if (res.status < 200 || res.status >= 300) return await this.retry(rec, `input ${inp.n}: ${res.status}`);

        rec.busy = 0;
        rec.tries = 0;
        rec.sent = (rec.sent ?? 0) + obj.size;
        rec.n += 1;
        if (rec.n >= rec.inputs.length) rec.step = "start";
        await this.d.storage.put(RENDER_KEY, rec);
        await this.d.db
            .prepare(
                "UPDATE edit_renders SET sent_bytes = ?1, updated_at = ?2 WHERE id = ?3 AND instance = ?4 AND status IN ('preparing', 'rendering', 'finishing')",
            )
            .bind(rec.sent, this.d.now(), rec.rid, this.d.instance)
            .run();
        return STEP_NOW_S;
    }

    // ---- 3. start ------------------------------------------------------------------------------------------------------

    private async stepStart(rec: StepRecord, row: ClaimRow): Promise<Outcome> {
        if (!(await this.ensure(rec))) return await this.retry(rec, "container will not start");
        let timeline: unknown;
        try {
            timeline = JSON.parse(row.timeline);
        } catch {
            return await this.end(rec, "error", "error.edit.render_failed");
        }
        const sent = rec.inputs.filter((i) => !(rec.missing ?? []).includes(i.n)).map((i) => ({ n: i.n, item: i.item, kind: i.kind }));
        const startBody = rec.chat
            ? { chat: { snapshot: (timeline as ChatSpec).snapshot, options: (timeline as ChatSpec).options }, inputs: sent }
            : { timeline, inputs: sent };
        let res: Response;
        try {
            res = await this.call(
                rec,
                `/renders/${rec.rid}/start`,
                {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify(startBody),
                },
                START_CALL_MS,
                "edit start",
            );
        } catch (e) {
            return await this.retry(rec, `start: ${String(e)}`);
        }
        if (res.status === 404) {
            await res.body?.cancel().catch(() => {});
            return await this.lose(rec, "start: 404");
        }
        if (res.status === 409) {
            const body = await json(res);
            if (body?.error?.code === "error.edit.input_missing") return await this.lose(rec, "an input is missing in the container");
            return await this.retry(rec, `start: 409 ${body?.error?.code ?? ""}`);
        }
        if (res.status === 400) {
            const body = await json(res);
            // parseTimeline / the probe refused it (31.9): their codes are render outcomes where they exist
            return await this.end(rec, "error", renderErrorCode(body?.error?.code));
        }
        await res.body?.cancel().catch(() => {});
        if (res.status !== 202 && res.status !== 200) return await this.retry(rec, `start: ${res.status}`);

        rec.deadline = this.d.now() + deadlineMs(row.seconds_total);
        rec.step = "wait";
        rec.tries = 0;
        rec.pollFails = 0;
        await this.d.storage.put(RENDER_KEY, rec);
        await this.d.db
            .prepare("UPDATE edit_renders SET status = 'rendering', seconds_done = 0, updated_at = ?1 WHERE id = ?2 AND instance = ?3 AND status IN ('preparing', 'rendering')")
            .bind(this.d.now(), rec.rid, this.d.instance)
            .run();
        return WAIT_S;
    }

    // ---- 4. wait -------------------------------------------------------------------------------------------------------

    private async stepWait(rec: StepRecord): Promise<Outcome> {
        if (!(await this.ensure(rec))) return await this.lose(rec, "the container would not start");
        let res: Response;
        try {
            res = await this.call(rec, `/renders/${rec.rid}`, {}, CALL_MS, "edit status");
        } catch (e) {
            rec.pollFails = (rec.pollFails ?? 0) + 1;
            this.log(`${rec.rid} poll failed (${rec.pollFails}/${POLL_FAILS}): ${String(e)}`);
            if (rec.pollFails >= POLL_FAILS) return await this.lose(rec, "the container stopped answering");
            await this.d.storage.put(RENDER_KEY, rec);
            return this.d.now() > rec.deadline ? await this.timeout(rec) : WAIT_S;
        }
        if (res.status === 404) {
            await res.body?.cancel().catch(() => {});
            return await this.lose(rec, "status: 404");
        }
        const st = res.ok ? await json(res) : null;
        if (!st) {
            rec.pollFails = (rec.pollFails ?? 0) + 1;
            if (rec.pollFails >= POLL_FAILS) return await this.lose(rec, `status: ${res.status}`);
            await this.d.storage.put(RENDER_KEY, rec);
            return this.d.now() > rec.deadline ? await this.timeout(rec) : WAIT_S;
        }
        rec.pollFails = 0;

        // the progress write also reads the cancel flag; no row back = the render is no longer ours
        const done = typeof st.seconds_done === "number" && Number.isFinite(st.seconds_done) ? Math.max(0, st.seconds_done) : null;
        const upd = await this.d.db
            .prepare(
                `UPDATE edit_renders SET seconds_done = COALESCE(?1, seconds_done), updated_at = ?2
                  WHERE id = ?3 AND instance = ?4 AND status IN ('preparing', 'rendering', 'finishing') RETURNING cancel_requested`,
            )
            .bind(done, this.d.now(), rec.rid, this.d.instance)
            .first<{ cancel_requested: number }>();
        if (!upd) return await this.abandon(rec, await this.loadRow(rec.rid));
        this.d.renew?.();
        if (upd.cancel_requested === 1) return await this.end(rec, "cancelled", "error.edit.cancelled");

        if (st.status === "error") return await this.end(rec, "error", renderErrorCode(st.error?.code));
        if (st.status === "done") {
            const r = { bytes: st.bytes, width: st.width, height: st.height, duration: st.duration };
            if (![r.bytes, r.width, r.height, r.duration].every((v) => typeof v === "number" && Number.isFinite(v) && v > 0)) {
                return await this.end(rec, "error", "error.edit.render_failed");
            }
            if (r.bytes > EDIT_MAX_OUTPUT_BYTES) return await this.end(rec, "error", "error.edit.too_large");
            rec.result = r as RenderResult;
            rec.step = "collect";
            rec.tries = 0;
            rec.collectTries = 0;
            await this.d.storage.put(RENDER_KEY, rec);
            await this.d.db
                .prepare("UPDATE edit_renders SET status = 'finishing', seconds_done = seconds_total, updated_at = ?1 WHERE id = ?2 AND instance = ?3 AND status IN ('preparing', 'rendering', 'finishing')")
                .bind(this.d.now(), rec.rid, this.d.instance)
                .run();
            return STEP_NEXT_S;
        }
        if (this.d.now() > rec.deadline) return await this.timeout(rec);
        return WAIT_S;
    }

    private async timeout(rec: StepRecord): Promise<Outcome> {
        return await this.end(rec, "error", "error.edit.timeout");
    }

    // ---- 5. collect ----------------------------------------------------------------------------------------------------

    private mp4Key = (rid: string) => `edits/${rid}.mp4`;

    private async stepCollect(rec: StepRecord, row: ClaimRow): Promise<Outcome> {
        const result = rec.result;
        if (!result) return await this.end(rec, "error", "error.edit.render_failed");
        if (!(await this.ensure(rec))) return await this.lose(rec, "the container would not start");
        let res: Response;
        try {
            res = await this.call(rec, `/renders/${rec.rid}/file`, {}, FILE_HEAD_MS, "edit file");
        } catch (e) {
            return await this.collectFailed(rec, `file: ${String(e)}`);
        }
        if (res.status === 404) {
            await res.body?.cancel().catch(() => {});
            return await this.lose(rec, "file: 404");
        }
        const length = Number(res.headers.get("content-length"));
        if (!res.ok || !res.body || !Number.isInteger(length) || length <= 0) {
            await res.body?.cancel().catch(() => {});
            return await this.collectFailed(rec, `file: ${res.status} length ${res.headers.get("content-length")}`);
        }
        if (length > EDIT_MAX_OUTPUT_BYTES) {
            await res.body.cancel().catch(() => {});
            return await this.end(rec, "error", "error.edit.too_large");
        }
        // the key may hold a partial object from here on: ending the render deletes it
        rec.mp4 = true;
        await this.d.storage.put(RENDER_KEY, rec);
        const key = this.mp4Key(rec.rid);
        try {
            const put = await raceCeiling(
                this.d.originals.put(key, this.d.fixedLength(res.body, length, () => this.d.renew?.()), {
                    httpMetadata: { contentType: "video/mp4" },
                    customMetadata: {
                        keyId: row.key_id ?? "",
                        source: "studio",
                        project: row.project_id,
                        render: rec.rid,
                        createdAt: String(this.d.now()),
                    },
                }),
                copyMs(length),
                "edit collect",
            );
            if (!put || put.size !== length) throw new Error(`stored ${put?.size ?? "nothing"} of ${length}`);
        } catch (e) {
            await res.body.cancel().catch(() => {});
            return await this.collectFailed(rec, `R2 put: ${String(e)}`);
        }
        rec.result = { ...result, bytes: length };
        rec.step = "poster";
        rec.tries = 0;
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // A put that fails is retried by the next tick (2 attempts), then `error.edit.storage`.
    private async collectFailed(rec: StepRecord, why: string): Promise<Outcome> {
        rec.collectTries = (rec.collectTries ?? 0) + 1;
        this.log(`${rec.rid} collect failed (${rec.collectTries}/${COLLECT_TRIES}): ${why}`);
        if (rec.collectTries >= COLLECT_TRIES) return await this.end(rec, "error", "error.edit.storage");
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // ---- 6. poster -----------------------------------------------------------------------------------------------------

    // A poster that cannot be made does not fail the render: the row gets none and the existing poster sweep (13.3)
    // makes one later. A 404 for the rid means the container lost the render (31.9), like at wait and collect.
    private async stepPoster(rec: StepRecord): Promise<Outcome> {
        const toRecord = async (): Promise<Outcome> => {
            rec.step = "record";
            rec.tries = 0;
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NEXT_S;
        };
        if (rec.posterDone) return await toRecord();
        if (!(await this.ensure(rec))) return await this.lose(rec, "the container would not start");
        let res: Response;
        try {
            res = await this.call(rec, `/renders/${rec.rid}/poster`, {}, POSTER_MS, "edit poster");
        } catch (e) {
            this.log(`${rec.rid} no poster: ${String(e)}`);
            rec.posterDone = true;
            return await toRecord();
        }
        if (res.status === 404) {
            await res.body?.cancel().catch(() => {});
            return await this.lose(rec, "poster: 404");
        }
        let jpeg: ArrayBuffer | null = null;
        if (res.ok) {
            try {
                jpeg = await raceCeiling(res.arrayBuffer(), POSTER_MS, "edit poster body");
            } catch {
                jpeg = null;
            }
        } else {
            await res.body?.cancel().catch(() => {});
        }
        rec.posterDone = true;
        if (jpeg) {
            const head = new Uint8Array(jpeg, 0, Math.min(2, jpeg.byteLength));
            if (jpeg.byteLength === 0 || jpeg.byteLength > MAX_POSTER_BYTES || head[0] !== 0xff || head[1] !== 0xd8) jpeg = null;
        }
        if (!jpeg) {
            this.log(`${rec.rid} no poster: the helper's answer is not a JPEG (${res.status})`);
            return await toRecord();
        }
        const name = `${randomBase62(MEDIA_NAME_LENGTH, this.d.randomBytes)}.jpg`;
        // named before the put: a tick that dies in it leaves an object the ending of this render can delete
        rec.posterName = name;
        await this.d.storage.put(RENDER_KEY, rec);
        try {
            await this.d.media.put(name, jpeg, {
                httpMetadata: { contentType: "image/jpeg", cacheControl: "public, max-age=31536000, immutable" },
                customMetadata: { poster: "1", render: rec.rid, createdAt: String(this.d.now()) },
            });
            rec.posterUrl = (this.d.mediaBaseUrl.endsWith("/") ? this.d.mediaBaseUrl : `${this.d.mediaBaseUrl}/`) + name;
        } catch (e) {
            this.log(`${rec.rid} no poster: R2 put ${String(e)}`);
            await this.d.media.delete(name).catch(() => {});
            rec.posterName = undefined;
        }
        return await toRecord();
    }

    // ---- 7. record -----------------------------------------------------------------------------------------------------

    private async stepRecord(rec: StepRecord, row: ClaimRow): Promise<Outcome> {
        const result = rec.result;
        if (!result) return await this.end(rec, "error", "error.edit.render_failed");
        const now = this.d.now();
        const key = this.mp4Key(rec.rid);
        let timeline: Timeline;
        try {
            timeline = JSON.parse(row.timeline) as Timeline;
        } catch {
            return await this.end(rec, "error", "error.edit.render_failed");
        }
        // the title cleaned like an upload name: no `/`, no control characters, at most 120 characters
        const name = cleanName(`${row.title}.mp4`, "mp4");
        const madeFrom = JSON.stringify(rec.chat ? [...new Set(rec.inputs.map((i) => i.item))] : timelineItems(timeline));
        const madeSpec = JSON.stringify(
            rec.chat
                ? { kind: "chat", thread: (timeline as unknown as ChatSpec).thread_id, render: rec.rid }
                : { kind: "edit", project: row.project_id, render: rec.rid, revision: row.revision },
        );
        // insertMediaItem inserts unless the object is already named by a row (a retried tick), and swallows D1 errors
        await insertMediaItem(
            this.d.db,
            {
                kind: "private",
                source: "studio",
                bucket: "originals",
                r2_key: key,
                name,
                content_type: "video/mp4",
                bytes: result.bytes,
                width: result.width,
                height: result.height,
                duration: result.duration,
                link: null,
                session_id: null,
                key_id: row.key_id,
                poster: rec.posterUrl ?? null,
                role: null,
                made_from: madeFrom,
                made_spec: madeSpec,
                post_key: null,
                created_at: now,
            },
            this.d.randomBytes,
        );
        const made = await this.d.db
            .prepare("SELECT id FROM media_items WHERE bucket = 'originals' AND r2_key = ?1 ORDER BY created_at DESC LIMIT 1")
            .bind(key)
            .first<{ id: string }>();
        if (!made) {
            // the row did not go in (D1 hiccup): the next tick tries again
            rec.tries = (rec.tries ?? 0) + 1;
            if (rec.tries >= STEP_TRIES) return await this.end(rec, "error", "error.edit.storage");
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NEXT_S;
        }
        // the row names the poster from here on: the render no longer owns that object
        rec.posterName = undefined;
        // the project's name is the post's title (section 15): the library, search and captions show it
        await upsertTitle(this.d.db, made.id, row.title, row.key_id ?? "", now);
        const upd = await this.d.db
            .prepare(
                `UPDATE edit_renders SET status = 'done', item_id = ?1, bytes = ?2, width = ?3, height = ?4, duration = ?5, seconds_done = seconds_total,
                        finished_at = ?6, updated_at = ?6
                  WHERE id = ?7 AND instance = ?8 AND status = 'finishing'`,
            )
            .bind(made.id, result.bytes, result.width, result.height, result.duration, now, rec.rid, this.d.instance)
            .run();
        rec.mp4 = false;
        if (Number(upd.meta?.changes ?? 0) === 0) {
            // the row was ended under us; the file is filed in the library regardless, and stays
            this.log(`${rec.rid} finished but its row was no longer ours`);
        }
        rec.ended = { status: "done", code: null };
        rec.step = "notify";
        rec.tries = 0;
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // ---- ending a render (any code) ---------------------------------------------------------------------------------------

    private async deleteLeftovers(rec: StepRecord): Promise<void> {
        // unconditional (R2 delete is idempotent): a tick that died inside the put never set the flag
        try {
            await this.d.originals.delete(this.mp4Key(rec.rid));
            rec.mp4 = false;
        } catch (e) {
            console.error("[edit-render] deleting the half-made video failed", String(e));
        }
        if (rec.posterName) {
            try {
                await this.d.media.delete(rec.posterName);
                rec.posterName = undefined;
            } catch (e) {
                console.error("[edit-render] deleting the unrecorded poster failed", String(e));
            }
        }
    }

    // UPDATE status 'error' | 'cancelled', error_code, finished_at; delete `edits/<rid>.mp4` and an unrecorded poster;
    // then the message (notify) and the container's copy (cleanup).
    private async end(rec: StepRecord, status: "error" | "cancelled", code: string): Promise<Outcome> {
        const now = this.d.now();
        this.log(`${rec.rid} ends ${status} ${code}`);
        await this.d.db
            .prepare(
                "UPDATE edit_renders SET status = ?1, error_code = ?2, finished_at = ?3, updated_at = ?3 WHERE id = ?4 AND status NOT IN ('done', 'error', 'cancelled')",
            )
            .bind(status, code, now, rec.rid)
            .run();
        await this.deleteLeftovers(rec);
        rec.ended = { status, code };
        rec.step = "notify";
        rec.tries = 0;
        await this.d.storage.put(RENDER_KEY, rec);
        return STEP_NEXT_S;
    }

    // ---- 8. notify (31.11) ------------------------------------------------------------------------------------------------

    // Exactly one Hark message when a render asked for it ends (`notified_at` is the marker): done and error; a cancel sends
    // nothing; the bridge off sends nothing. 3 s cap, retried by the next two ticks, then given up and logged.
    private async stepNotify(rec: StepRecord): Promise<Outcome> {
        const toCleanup = async (): Promise<Outcome> => {
            rec.step = "cleanup";
            rec.tries = 0;
            await this.d.storage.put(RENDER_KEY, rec);
            return STEP_NOW_S;
        };
        const ended = rec.ended;
        if (!ended || ended.status === "cancelled" || !this.d.hark) return await toCleanup();
        const row = await this.loadRow(rec.rid);
        if (!row || row.notify !== 1 || row.notified_at !== null) return await toCleanup();
        const msg =
            ended.status === "done" && rec.result
                ? editDoneMessage(row.title, rec.result)
                : editFailedMessage(row.title, ended.code ?? "error.edit.render_failed");

        rec.notifyTries = (rec.notifyTries ?? 0) + 1;
        // written BEFORE the send, so a tick that dies mid-send still counts it and the retries stay bounded
        await this.d.storage.put(RENDER_KEY, rec);
        const outcome = await this.postHark(msg);
        if (outcome === "ok") {
            await this.d.db.prepare("UPDATE edit_renders SET notified_at = ?1 WHERE id = ?2 AND notified_at IS NULL").bind(this.d.now(), rec.rid).run();
            this.log(`${rec.rid} hark sent`);
            return await toCleanup();
        }
        if (outcome === "rejected" || rec.notifyTries >= NOTIFY_TRIES) {
            this.log(`${rec.rid} hark given up (${outcome}, ${rec.notifyTries} tries)`);
            return await toCleanup();
        }
        return STEP_NEXT_S;
    }

    // A render that ended with no step record to carry it (lost on a restart): one best-effort message, same marker.
    private async notifyEnded(rid: string): Promise<void> {
        if (!this.d.hark) return;
        await notifyEndedRow({ db: this.d.db, hark: this.d.hark, harkFetch: this.d.harkFetch, now: this.d.now }, rid);
    }

    private async postHark(msg: { title: string; body: string; url: string }): Promise<"ok" | "retry" | "rejected"> {
        const hook = this.d.hark;
        if (!hook) return "rejected";
        const ac = new AbortController();
        try {
            const res = await raceCeiling(
                (this.d.harkFetch ?? ((u, i) => fetch(u, i)))(hook, {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify(msg),
                    redirect: "manual",
                    signal: ac.signal,
                }),
                HARK_MS,
                "hark",
            );
            await res.body?.cancel().catch(() => {});
            if (res.status >= 200 && res.status < 300) return "ok";
            return res.status >= 500 ? "retry" : "rejected";
        } catch {
            ac.abort();
            // the error text is never logged: a fetch error can carry the URL
            return "retry";
        }
    }

    // ---- 9. cleanup ------------------------------------------------------------------------------------------------------

    // DELETE the container's copy (best effort, idempotent; only when this render touched the container and it runs),
    // delete the record, and claim the next render in the same tick.
    private async stepCleanup(rec: StepRecord): Promise<Outcome> {
        if (rec.container && this.d.isRunning()) {
            try {
                const res = await this.call(rec, `/renders/${rec.rid}`, { method: "DELETE" }, CALL_MS, "edit delete");
                await res.body?.cancel().catch(() => {});
            } catch (e) {
                rec.cleanTries = (rec.cleanTries ?? 0) + 1;
                if (rec.cleanTries < CLEAN_TRIES) {
                    await this.d.storage.put(RENDER_KEY, rec);
                    return STEP_NEXT_S;
                }
                // the helper kills a render nobody touched for 10 minutes anyway
                this.log(`${rec.rid} container delete given up: ${String(e)}`);
            }
        }
        await this.d.storage.delete(RENDER_KEY);
        return await this.claimNext();
    }
}
