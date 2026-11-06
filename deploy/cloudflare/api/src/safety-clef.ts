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
    parseClefAnswer,
    safetyConfigFrom,
    sha256,
    snapshotFlags,
    toBase64,
    type SafetyConfig,
    type SafetyContentLevel,
} from "./safety";
import { PILOT_LABELS_KEY, readPilotLabels, readPilotReport, writePilotReport, type PilotLabel, type PilotReport } from "./safety-pilot";

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

// Rates files whose clip is ready. When a pilot list is waiting, that list goes first and the ordinary queue waits
// for the next run, so one cron never bursts past the pilot cap.
export async function rateSafety(d: SafetyRateDeps): Promise<SafetyRateResult> {
    const cfg = d.cfg ?? safetyConfigFrom({});
    const out: SafetyRateResult = { due: 0, rated: 0, failed: 0, pilot: 0 };
    if (!d.ai || typeof d.ai.run !== "function") return out;
    try {
        const labels = await readPilotLabels(d.originals);
        if (labels && labels.length > 0) {
            const report = await readPilotReport(d.originals);
            const labelsHash = await hashLabels(labels);
            const done = new Set((report?.rows ?? []).filter((r) => r.clef || r.error === "failed").map((r) => r.id));
            const todo = labels.filter((l) => !done.has(l.id)).slice(0, SAFETY_PILOT_PER_RUN);
            if (todo.length === 0) {
                await d.originals.delete?.(PILOT_LABELS_KEY).catch(() => {});
            } else {
                out.pilot = todo.length;
                const rows = await dueRows(d, todo.length, todo.map((l) => l.id));
                const byId = new Map(rows.map((r) => [r.item_id, r]));
                let calls = 0;
                const next: PilotReport = report && report.labels_hash === labelsHash ? report : { labels_hash: labelsHash, rows: [] };
                for (const label of todo) {
                    const row = byId.get(label.id);
                    if (!row) {
                        next.rows = next.rows.filter((r) => r.id !== label.id).concat([{ id: label.id, label: label.label, clef: null, error: "not_ready" }]);
                        continue;
                    }
                    await pace(d, calls);
                    calls++;
                    const result = await rateOne(d, row, cfg);
                    if (result === "rated") out.rated++;
                    else out.failed++;
                    const stored = await d.db
                        .prepare(`SELECT level, probs, gore, drawn, minor_sexual, model FROM media_safety WHERE item_id = ?1`)
                        .bind(label.id)
                        .first<{ level: string; probs: string | null; gore: number; drawn: number; minor_sexual: number; model: string | null }>();
                    next.rows = next.rows.filter((r) => r.id !== label.id).concat([
                        {
                            id: label.id,
                            label: label.label,
                            clef: stored
                                ? {
                                      level: stored.level,
                                      probs: stored.probs ? JSON.parse(stored.probs) : null,
                                      gore: stored.gore === 1,
                                      drawn: stored.drawn === 1,
                                      minor_sexual: stored.minor_sexual === 1,
                                      model: stored.model,
                                  }
                                : null,
                            error: result === "rated" ? null : "failed",
                        },
                    ]);
                }
                await writePilotReport(d.originals, next);
                const settled = labels.every((l) => next.rows.some((r) => r.id === l.id && r.error !== "not_ready"));
                if (settled) await d.originals.delete?.(PILOT_LABELS_KEY).catch(() => {});
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
