// The Clef-omni rating (APP-API-CONTRACT.md section 51.3). One Workers AI binding call per file, paced under the
// assumed 20 requests a minute. The probabilities are what gets stored, so a later threshold change does not re-rate.
// Haiku is not asked. Free of Cloudflare imports: the binding is the injected `ai.run`.

import { safetyAudioKey, safetyClipKey, safetyStillKey } from "./about-store";
import {
    CLEF_MODEL,
    CLEF_MODEL_ID,
    QUESTIONS_VERSION,
    SAFETY_MAX_ATTEMPTS,
    SAFETY_MIN_GAP_MS,
    SAFETY_PILOT_PER_RUN,
    SAFETY_QUESTIONS,
    SAFETY_RETRY_MS,
    SAFETY_STATE,
    prepFailedDue,
    contentLevel,
    parseClefAnswer,
    safetyConfigFrom,
    sha256,
    snapshotFlags,
    toBase64,
    type SafetyConfig,
    type SafetyContentLevel,
} from "./safety";
import { PILOT_LABELS_KEY, readPilotLabels, readPilotReport, reportPrepOpen, writePilotReport, type PilotClef, type PilotLabel, type PilotReport, type PilotRow } from "./safety-pilot";

export const CLEF_IMAGE_MAX = 4;
export const CLEF_VIDEO_MAX = 2;
// The binding's max request size is undocumented. A purpose-made clip is 1–3 MB; the test pins a 3 MB clip plus mp3.
export const CLEF_AUDIO_MAX = 4;

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream; size: number } | null> };
type WriteBucket = ReadBucket & {
    put(key: string, value: Uint8Array | string, options?: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> }): Promise<unknown>;
    delete?(key: string): Promise<unknown>;
};

export type AiRunner = { run(model: string, inputs: Record<string, unknown>): Promise<unknown> };

export type ClefMedia = { videos: Uint8Array[]; audio: Uint8Array | null; images: Uint8Array[] };

const dataUrl = (mime: string, bytes: Uint8Array) => `data:${mime};base64,${toBase64(bytes)}`;

// The binding body. Videos and images are capped at what Clef accepts in one request; extra stills are the first four.
export function buildClefRequest(media: ClefMedia): Record<string, unknown> {
    const videos = media.videos.slice(0, CLEF_VIDEO_MAX).map((b) => dataUrl("video/mp4", b));
    const images = media.images.slice(0, CLEF_IMAGE_MAX).map((b) => dataUrl("image/jpeg", b));
    const audio = media.audio ? [dataUrl("audio/mpeg", media.audio)] : [];
    return {
        model: CLEF_MODEL,
        state: SAFETY_STATE,
        questions: SAFETY_QUESTIONS,
        ...(videos.length > 0 ? { videos } : {}),
        ...(audio.length > 0 ? { audio } : {}),
        ...(images.length > 0 ? { images } : {}),
    };
}

const bytesOf = async (body: ReadableStream) => new Uint8Array(await new Response(body).arrayBuffer());

async function readBytes(bucket: ReadBucket, key: string): Promise<Uint8Array | null> {
    const o = await bucket.get(key).catch(() => null);
    if (!o) return null;
    return bytesOf(o.body);
}

export async function loadSafetyMedia(bucket: ReadBucket, itemId: string, clips: number, stills: number, hasAudio: boolean): Promise<ClefMedia | null> {
    const videos: Uint8Array[] = [];
    for (let n = 1; n <= Math.min(CLEF_VIDEO_MAX, clips); n++) {
        const b = await readBytes(bucket, safetyClipKey(itemId, n));
        if (!b) return null;
        videos.push(b);
    }
    const images: Uint8Array[] = [];
    for (let n = 1; n <= Math.min(CLEF_IMAGE_MAX, stills); n++) {
        const b = await readBytes(bucket, safetyStillKey(itemId, n));
        if (!b) return null;
        images.push(b);
    }
    if (videos.length === 0 && images.length === 0) return null;
    // A missing soundtrack is not "silent": rating without it would hide what was heard.
    if (hasAudio) {
        const audio = await readBytes(bucket, safetyAudioKey(itemId));
        if (!audio) return null;
        return { videos, audio, images };
    }
    return { videos, audio: null, images };
}

type DueRow = {
    item_id: string;
    level: string;
    attempts: number;
    clips: number;
    stills: number;
    has_audio: number;
    questions_version: string | null;
    created_at: number;
};

export type SafetyRateDeps = {
    db: D1Database;
    originals: WriteBucket;
    ai: AiRunner;
    now: () => number;
    sleep?: (ms: number) => Promise<void>;
    cfg?: SafetyConfig;
    // tests: skip the wall-clock gap
    gapMs?: number;
};

export type SafetyRateResult = { due: number; rated: number; failed: number; pilot: number };

const dueSql = (only: string[] | null) =>
    `SELECT s.item_id, s.level, s.attempts, s.clips, s.stills, s.has_audio, s.questions_version, m.created_at
       FROM media_safety s JOIN media_items m ON m.id = s.item_id
      WHERE m.deleted_at IS NULL AND s.prep = 'ready' AND s.attempts < ?1
        AND (s.level = 'pending'
             OR (s.level = 'failed' AND (s.failed_at IS NULL OR s.failed_at < ?2))
             OR s.questions_version IS NULL OR s.questions_version != ?3)
        ${only ? "AND s.item_id IN (SELECT value FROM json_each(?4))" : ""}
      ORDER BY m.created_at DESC, s.item_id DESC
      LIMIT ?${only ? 5 : 4}`;

async function dueRows(d: SafetyRateDeps, limit: number, only: string[] | null): Promise<DueRow[]> {
    if (limit <= 0) return [];
    const since = d.now() - SAFETY_RETRY_MS;
    const stmt = d.db.prepare(dueSql(only));
    const bound = only
        ? stmt.bind(SAFETY_MAX_ATTEMPTS, since, QUESTIONS_VERSION, JSON.stringify(only), limit)
        : stmt.bind(SAFETY_MAX_ATTEMPTS, since, QUESTIONS_VERSION, limit);
    const { results } = await bound.all<DueRow>();
    return results;
}

async function rateOne(d: SafetyRateDeps, row: DueRow, cfg: SafetyConfig): Promise<"rated" | "failed"> {
    const now = d.now();
    // pending for the duration of the call, so a question-change re-rate leaves the stage until it finishes
    await d.db
        .prepare(`UPDATE media_safety SET level = 'pending', attempts = attempts + 1, updated_at = ?2 WHERE item_id = ?1`)
        .bind(row.item_id, now)
        .run();
    const media = await loadSafetyMedia(d.originals, row.item_id, row.clips, row.stills, row.has_audio === 1);
    if (!media) {
        await fail(d, row.item_id, now);
        return "failed";
    }
    const request = buildClefRequest(media);
    let parsed: ReturnType<typeof parseClefAnswer> = null;
    try {
        parsed = parseClefAnswer(await d.ai.run(CLEF_MODEL_ID, request));
    } catch (e) {
        console.error("[safety] clef failed", row.item_id, e instanceof Error ? e.message.slice(0, 200) : "error");
    }
    if (!parsed) {
        await fail(d, row.item_id, d.now());
        return "failed";
    }
    const flags = snapshotFlags(parsed.probs, cfg);
    const hash = await sha256(JSON.stringify([QUESTIONS_VERSION, CLEF_MODEL_ID, row.clips, row.stills, row.has_audio, media.videos.map((b) => b.length), media.images.map((b) => b.length), media.audio?.length ?? 0]));
    const at = d.now();
    await d.db
        .prepare(
            `UPDATE media_safety SET level = ?2, probs = ?3, gore = ?4, drawn = ?5, minor_sexual = ?6, model = ?7,
                    questions_version = ?8, input_hash = ?9, rated_at = ?10, failed_at = NULL, attempts = 0, updated_at = ?10
              WHERE item_id = ?1`,
        )
        .bind(row.item_id, parsed.level, JSON.stringify(parsed.probs), flags.gore, flags.drawn, flags.minor_sexual, CLEF_MODEL_ID, QUESTIONS_VERSION, hash, at)
        .run();
    return "rated";
}

async function fail(d: SafetyRateDeps, itemId: string, now: number): Promise<void> {
    await d.db.prepare(`UPDATE media_safety SET level = 'failed', failed_at = ?2, updated_at = ?2 WHERE item_id = ?1`).bind(itemId, now).run();
}

async function pace(d: SafetyRateDeps, calls: number): Promise<void> {
    const gap = d.gapMs ?? SAFETY_MIN_GAP_MS;
    if (calls > 0 && gap > 0) await (d.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(gap);
}

type PilotState = {
    item_id: string;
    prep: string;
    prep_at: number | null;
    prep_attempts: number;
    prep_rev: number | null;
    level: string;
    probs: string | null;
    gore: number;
    drawn: number;
    minor_sexual: number;
    model: string | null;
};

async function pilotStates(d: SafetyRateDeps, ids: string[]): Promise<Map<string, PilotState>> {
    if (ids.length === 0) return new Map();
    const { results } = await d.db
        .prepare(
            `SELECT s.item_id, s.prep, s.prep_at, s.prep_attempts, s.prep_rev, s.level, s.probs, s.gore, s.drawn, s.minor_sexual, s.model
               FROM media_safety s JOIN media_items m ON m.id = s.item_id
              WHERE m.deleted_at IS NULL AND s.item_id IN (SELECT value FROM json_each(?1))`,
        )
        .bind(JSON.stringify(ids))
        .all<PilotState>();
    return new Map(results.map((r) => [r.item_id, r]));
}

// Kick will not queue this prep again: the day-long wait has not passed, or the attempts are used, and the
// failure was on the current prep path. An older prep_rev is due now (prepFailedDue).
function prepNotDue(row: Pick<PilotState, "prep" | "prep_at" | "prep_attempts" | "prep_rev">, now: number): boolean {
    if (row.prep !== "failed") return false;
    return !prepFailedDue(row, now);
}

function clefOf(row: Pick<PilotState, "level" | "probs" | "gore" | "drawn" | "minor_sexual" | "model">): PilotClef {
    return {
        level: row.level,
        probs: row.probs ? JSON.parse(row.probs) : null,
        gore: row.gore === 1,
        drawn: row.drawn === 1,
        minor_sexual: row.minor_sexual === 1,
        model: row.model,
    };
}

// A Clef answer settles an id. A recorded failure settles it only when prep will not be tried again: a prep
// failure that still has a retry keeps the labels file, so the kick can cut the clip and a later run can rate it.
function pilotSettled(labels: PilotLabel[], rows: PilotRow[], states: Map<string, PilotState>, now: number): boolean {
    const byId = new Map(rows.map((r) => [r.id, r]));
    return labels.every((l) => {
        const r = byId.get(l.id);
        if (!r || r.error === "not_ready") return false;
        if (r.clef && r.error == null) return true;
        const row = states.get(l.id);
        if (!row || row.prep === "pending") return false;
        if (row.prep === "failed" && prepFailedDue(row, now)) return false;
        return true;
    });
}

// Rates files whose clip is ready. When a pilot list is waiting, that list goes first and the ordinary queue waits
// for the next run, so one cron never bursts past the pilot cap. The cap is spent on clips that are ready to rate.
// An id whose clip is not ready stays `not_ready` and does not take a slot. A prep failure that kick will not retry
// right now is recorded as `failed`, so it does not sit on `not_ready` for the whole wait.
export async function rateSafety(d: SafetyRateDeps): Promise<SafetyRateResult> {
    const cfg = d.cfg ?? safetyConfigFrom({});
    const out: SafetyRateResult = { due: 0, rated: 0, failed: 0, pilot: 0 };
    if (!d.ai || typeof d.ai.run !== "function") return out;
    try {
        let labels = await readPilotLabels(d.originals);
        // The labels file is removed once every id is settled. A prep that failed on an older path is not
        // settled any more, but the file may already be gone. Those report rows (no Clef level) are the list.
        let preserve: PilotReport | null = null;
        if (!labels || labels.length === 0) {
            const existing = await readPilotReport(d.originals);
            const candidates = reportPrepOpen(existing);
            if (existing && candidates.length > 0) {
                const now = d.now();
                const states = await pilotStates(d, candidates.map((l) => l.id));
                const openRows = candidates.filter((l) => {
                    const row = states.get(l.id);
                    if (!row) return false;
                    if (row.prep === "ready" && row.level === "pending") return true;
                    return row.prep === "failed" && prepFailedDue(row, now);
                });
                if (openRows.length > 0) {
                    labels = openRows;
                    preserve = existing;
                }
            }
        }
        if (labels && labels.length > 0) {
            const report = preserve ?? (await readPilotReport(d.originals));
            const labelsHash = preserve ? preserve.labels_hash : await hashLabels(labels);
            const same = preserve ?? (report && report.labels_hash === labelsHash ? report : null);
            const byReport = new Map((same?.rows ?? []).map((r) => [r.id, r]));
            const open = labels.filter((l) => {
                const r = byReport.get(l.id);
                return !(r?.clef && r.error == null);
            });
            if (open.length === 0) {
                await d.originals.delete?.(PILOT_LABELS_KEY).catch(() => {});
            } else {
                const now = d.now();
                const states = await pilotStates(d, open.map((l) => l.id));
                const due = await dueRows(d, open.length, open.map((l) => l.id));
                const dueById = new Map(due.map((r) => [r.item_id, r]));
                const rateLabels: PilotLabel[] = [];
                const notes: PilotRow[] = [];
                for (const label of open) {
                    const row = states.get(label.id);
                    const prev = byReport.get(label.id);
                    // A Clef call that already failed this pilot id stays failed. A prep failure does not: its level
                    // is still pending, so once the clip lands the id is rated.
                    if (prev?.error === "failed" && row?.prep === "ready" && row.level === "failed") continue;
                    if (row && dueById.has(label.id)) {
                        rateLabels.push(label);
                        continue;
                    }
                    if (row && contentLevel(row.level)) {
                        notes.push({ id: label.id, label: label.label, clef: clefOf(row), error: null });
                        continue;
                    }
                    if (row && (prepNotDue(row, now) || row.prep === "ready")) {
                        notes.push({ id: label.id, label: label.label, clef: null, error: "failed" });
                        continue;
                    }
                    notes.push({ id: label.id, label: label.label, clef: null, error: "not_ready" });
                }
                const todo = rateLabels.slice(0, SAFETY_PILOT_PER_RUN);
                out.pilot = todo.length;
                const next: PilotReport = same ? { labels_hash: labelsHash, rows: [...same.rows] } : { labels_hash: labelsHash, rows: [] };
                const put = (row: PilotRow) => {
                    next.rows = next.rows.filter((r) => r.id !== row.id).concat([row]);
                };
                for (const note of notes) put(note);
                let calls = 0;
                for (const label of todo) {
                    const row = dueById.get(label.id);
                    if (!row) continue;
                    await pace(d, calls);
                    calls++;
                    const result = await rateOne(d, row, cfg);
                    if (result === "rated") out.rated++;
                    else out.failed++;
                    const stored = await d.db
                        .prepare(`SELECT level, probs, gore, drawn, minor_sexual, model FROM media_safety WHERE item_id = ?1`)
                        .bind(label.id)
                        .first<{ level: string; probs: string | null; gore: number; drawn: number; minor_sexual: number; model: string | null }>();
                    put({
                        id: label.id,
                        label: label.label,
                        clef: stored ? clefOf(stored) : null,
                        error: result === "rated" ? null : "failed",
                    });
                }
                if (notes.length > 0 || todo.length > 0) await writePilotReport(d.originals, next);
                if (!preserve && pilotSettled(labels, next.rows, states, now)) await d.originals.delete?.(PILOT_LABELS_KEY).catch(() => {});
                return out;
            }
        }
        if (cfg.perRun <= 0) return out;
        const rows = await dueRows(d, cfg.perRun, null);
        out.due = rows.length;
        let calls = 0;
        for (const row of rows) {
            await pace(d, calls);
            calls++;
            const result = await rateOne(d, row, cfg);
            if (result === "rated") out.rated++;
            else out.failed++;
        }
        return out;
    } catch (e) {
        console.error("[safety] rate failed", e instanceof Error ? e.message.slice(0, 200) : "error");
        return out;
    }
}

const hashLabels = (labels: PilotLabel[]) => sha256(JSON.stringify(labels.map((l) => [l.id, l.label])));

export type { SafetyContentLevel };
