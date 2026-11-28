// Audio loudness measurement & non-destructive leveling (Cobalt v10.1).
// Pure business logic + D1 store + Durable Object job runner (`AudioLevelService`).
// Free of Cloudflare runtime imports so it runs under plain node/Vitest.

import { raceCeiling } from "./ceiling";
import { mintItemId } from "./library";
import { isMissingTable } from "./private-links";
import type { PublishBucket } from "./publish";
import type { OriginalsBucket } from "./studio";
import {
    ITEM_COLUMNS,
    effectiveVisibility,
    getRow,
    makePublic,
    purgeUrls,
    type MediaRow,
    type PurgeFn,
    type VisDeps,
} from "./visibility";
import type { KV } from "./webp";

// ---- constants & types -----------------------------------------------------------------------

export type AudioMode = "off" | "measure" | "auto";
export type AudioTargetLufs = -14 | -16;
export type AudioDefaultLink = "orig" | "normal";
export type AudioZone = "pending" | "balanced" | "loud" | "quiet" | "silent";
export type AudioState = "pending" | "measured" | "rendering" | "ready" | "skipped" | "failed";

export const AUDIO_MODES: readonly AudioMode[] = ["off", "measure", "auto"];
export const AUDIO_LEVEL_TARGETS: readonly AudioTargetLufs[] = [-14, -16];
export const AUDIO_DEFAULT_LINKS: readonly AudioDefaultLink[] = ["orig", "normal"];

export const AUDIO_SPEC_KIND = "audio_level";
export const AUDIO_QUERY_KEY = "audio";
export const AUDIO_QUERY_VALUE = "normal";
export const AUDIO_SILENCE_LUFS = -60;
export const AUDIO_LOUD_LUFS = -10.5;
export const AUDIO_CLIP_LUFS = -12;
export const AUDIO_CLIP_TP_DBTP = -0.3;
export const AUDIO_QUIET_LUFS = -22;
export const AUDIO_TRUE_PEAK_CEILING = -1.5;

export const AUDIO_MAX_ATTEMPTS = 3;
export const AUDIO_RETRY_MS = 24 * 60 * 60 * 1000;
export const AUDIO_KICK_MAX = 25;
export const AUDIO_MEASURE_CALL_MS = 120_000;
export const AUDIO_LEVEL_CALL_MS = 240_000;
export const AUDIO_BUSY_LIMIT = 120;
export const AUDIO_MEASURE_PREFIX = "audio-m:";
export const AUDIO_LEVEL_PREFIX = "audio-l:";

export type LoudnessMeasurement = {
    integrated_lufs: number;
    true_peak_dbtp: number;
    lra_lu: number;
    threshold_lufs: number;
    offset_db: number;
};

export type AudioSettings = {
    mode: AudioMode;
    target_lufs: AudioTargetLufs;
    default_link: AudioDefaultLink;
    updated_at: number;
};

export const DEFAULT_AUDIO_SETTINGS: AudioSettings = {
    mode: "auto",
    target_lufs: -14,
    default_link: "orig",
    updated_at: 0,
};

export type AudioRow = {
    item_id: string;
    integrated_lufs: number | null;
    true_peak_dbtp: number | null;
    lra_lu: number | null;
    threshold_lufs: number | null;
    offset_db: number | null;
    zone: AudioZone;
    state: AudioState;
    target_lufs: number | null;
    output_lufs: number | null;
    output_true_peak: number | null;
    alt_item_id: string | null;
    attempts: number;
    error: string | null;
    measured_at: number | null;
    leveled_at: number | null;
    updated_at: number;
};

export type AudioSummary = {
    integrated_lufs: number | null;
    true_peak_dbtp: number | null;
    lra_lu: number | null;
    zone: AudioZone;
    state: AudioState;
    target_lufs: number | null;
    output_lufs: number | null;
    output_true_peak: number | null;
    alt_id: string | null;
    alt_url: string | null;
    error: string | null;
    measured_at: number | null;
    leveled_at: number | null;
};

export type AudioClassification = {
    zone: Exclude<AudioZone, "pending">;
    rule: string;
    autoLevel: boolean;
};

// ---- pure classification & URL/spec helpers ---------------------------------------------------

/**
 * Classifies an EBU R128 loudness + true peak reading into the v10.1 decision zones:
 *  - `lufs <= -60`                          -> `silent`   (skip)
 *  - `lufs > -10.5`                         -> `loud`     (auto-level)
 *  - `lufs > -12 && truePeakDbtp > -0.3`    -> `loud`     (clipping, auto-level)
 *  - `lufs < -22`                           -> `quiet`    (auto-level)
 *  - otherwise                              -> `balanced` (skip auto, manual ok)
 */
export function classifyLoudness(lufs: number, truePeakDbtp: number): AudioClassification {
    if (!Number.isFinite(lufs) || lufs <= AUDIO_SILENCE_LUFS) {
        return { zone: "silent", rule: "silent (≤ −60 LUFS)", autoLevel: false };
    }
    if (lufs > AUDIO_LOUD_LUFS) {
        return { zone: "loud", rule: "loud (> −10.5 LUFS)", autoLevel: true };
    }
    if (lufs > AUDIO_CLIP_LUFS && Number.isFinite(truePeakDbtp) && truePeakDbtp > AUDIO_CLIP_TP_DBTP) {
        return { zone: "loud", rule: "loud + clipping (> −12 LUFS & TP > −0.3 dBTP)", autoLevel: true };
    }
    if (lufs < AUDIO_QUIET_LUFS) {
        return { zone: "quiet", rule: "quiet (< −22 LUFS)", autoLevel: true };
    }
    return { zone: "balanced", rule: "balanced (−22 to −10.5 LUFS)", autoLevel: false };
}

export function isAudioMode(v: unknown): v is AudioMode {
    return v === "off" || v === "measure" || v === "auto";
}

export function isAudioTarget(v: unknown): v is AudioTargetLufs {
    return v === -14 || v === -16;
}

export function isAudioDefaultLink(v: unknown): v is AudioDefaultLink {
    return v === "orig" || v === "normal";
}

export function parseAudioTarget(v: unknown): AudioTargetLufs | null {
    if (v === undefined || v === null || v === "") return -14;
    const n = Number(v);
    return n === -14 || n === -16 ? n : null;
}

export function parseAudioLevelSpec(raw: string | null | undefined): Record<string, unknown> | null {
    if (!raw) return null;
    try {
        const parsed: unknown = JSON.parse(raw);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
        const rec = parsed as Record<string, unknown>;
        return rec.kind === AUDIO_SPEC_KIND ? rec : null;
    } catch {
        return null;
    }
}

export function isAudioLevelSpec(raw: string | null | undefined): boolean {
    return parseAudioLevelSpec(raw) !== null;
}

export function audioAltParentId(rawMadeFrom: string | null | undefined): string | null {
    if (!rawMadeFrom) return null;
    try {
        const parsed: unknown = JSON.parse(rawMadeFrom);
        if (Array.isArray(parsed) && typeof parsed[0] === "string" && parsed[0].length > 0) return parsed[0];
        return null;
    } catch {
        return null;
    }
}

export function parseLoudnessPayload(raw: unknown): LoudnessMeasurement | null {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    const o = raw as Record<string, unknown>;
    const lufs = Number(o.integrated_lufs);
    const tp = Number(o.true_peak_dbtp);
    const lra = Number(o.lra_lu);
    const thresh = Number(o.threshold_lufs);
    const offset = Number(o.offset_db);
    if (![lufs, tp, lra, thresh, offset].every(Number.isFinite)) return null;
    return {
        integrated_lufs: +lufs.toFixed(2),
        true_peak_dbtp: +tp.toFixed(2),
        lra_lu: +Math.max(0, lra).toFixed(2),
        threshold_lufs: +thresh.toFixed(2),
        offset_db: +offset.toFixed(2),
    };
}

export function wantsNormalAudio(url: URL): boolean {
    return (url.searchParams.get(AUDIO_QUERY_KEY) ?? "").trim().toLowerCase() === AUDIO_QUERY_VALUE;
}

export function withNormalAudioQuery(rawUrl: string): string {
    try {
        const u = new URL(rawUrl);
        u.searchParams.set(AUDIO_QUERY_KEY, AUDIO_QUERY_VALUE);
        return u.toString();
    } catch {
        return rawUrl.includes("?") ? `${rawUrl}&${AUDIO_QUERY_KEY}=${AUDIO_QUERY_VALUE}` : `${rawUrl}?${AUDIO_QUERY_KEY}=${AUDIO_QUERY_VALUE}`;
    }
}

export function withoutAudioQuery(rawUrl: string): string {
    try {
        const u = new URL(rawUrl);
        u.searchParams.delete(AUDIO_QUERY_KEY);
        return u.toString();
    } catch {
        return rawUrl.replace(/[?&]audio=[^&]+/g, "").replace(/\?$/, "");
    }
}

export const isVideoContentType = (ct: string | null | undefined): boolean =>
    typeof ct === "string" && ct.trim().toLowerCase().startsWith("video/");

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const PUBLIC_NAME = /^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/;

function publicAltUrl(r: Pick<MediaRow, "deleted_at" | "visibility" | "bucket" | "r2_key" | "public_key">, mediaBaseUrl: string): string | null {
    if (r.deleted_at || effectiveVisibility(r) !== "public") return null;
    const key = r.bucket === "media" ? r.r2_key : r.public_key;
    return key && PUBLIC_NAME.test(key) ? `${withSlash(mediaBaseUrl)}${key}` : null;
}

// ---- D1 store ---------------------------------------------------------------------------------

export async function audioTablesReady(db: D1Database): Promise<boolean> {
    try {
        await db.prepare("SELECT 1 FROM audio_settings WHERE id = 1").first();
        return true;
    } catch (e) {
        if (isMissingTable(e)) return false;
        return false;
    }
}

export async function readAudioSettings(db: D1Database): Promise<AudioSettings> {
    try {
        const row = await db
            .prepare("SELECT mode, target_lufs, default_link, updated_at FROM audio_settings WHERE id = 1")
            .first<{ mode: string; target_lufs: number; default_link: string; updated_at: number }>();
        if (!row) return { ...DEFAULT_AUDIO_SETTINGS };
        return {
            mode: isAudioMode(row.mode) ? row.mode : DEFAULT_AUDIO_SETTINGS.mode,
            target_lufs: row.target_lufs === -16 ? -16 : -14,
            default_link: isAudioDefaultLink(row.default_link) ? row.default_link : DEFAULT_AUDIO_SETTINGS.default_link,
            updated_at: Number(row.updated_at) || 0,
        };
    } catch (e) {
        if (isMissingTable(e)) return { ...DEFAULT_AUDIO_SETTINGS };
        throw e;
    }
}

export async function writeAudioSettings(
    db: D1Database,
    patch: Partial<Pick<AudioSettings, "mode" | "target_lufs" | "default_link">>,
    now: number,
): Promise<AudioSettings> {
    const cur = await readAudioSettings(db);
    const next: AudioSettings = {
        mode: patch.mode ?? cur.mode,
        target_lufs: patch.target_lufs ?? cur.target_lufs,
        default_link: patch.default_link ?? cur.default_link,
        updated_at: now,
    };
    await db
        .prepare(
            `INSERT INTO audio_settings (id, mode, target_lufs, default_link, updated_at)
             VALUES (1, ?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET mode = excluded.mode, target_lufs = excluded.target_lufs,
                 default_link = excluded.default_link, updated_at = excluded.updated_at`,
        )
        .bind(next.mode, next.target_lufs, next.default_link, next.updated_at)
        .run();
    return next;
}

export async function readAudioRows(db: D1Database, itemIds: string[]): Promise<Map<string, AudioRow>> {
    const out = new Map<string, AudioRow>();
    if (itemIds.length === 0) return out;
    try {
        for (let i = 0; i < itemIds.length; i += 90) {
            const slice = itemIds.slice(i, i + 90);
            const marks = slice.map((_, idx) => `?${idx + 1}`).join(", ");
            const { results } = await db
                .prepare(`SELECT * FROM media_audio WHERE item_id IN (${marks})`)
                .bind(...slice)
                .all<AudioRow>();
            for (const r of results) out.set(r.item_id, r);
        }
    } catch (e) {
        if (isMissingTable(e)) return out;
        console.error("[audio] readAudioRows failed", String(e));
    }
    return out;
}

export type AudioJoinedRow = AudioRow & {
    alt_live_id?: string | null;
    alt_url?: string | null;
    alt_visibility?: string | null;
    alt_bucket?: string | null;
    alt_r2_key?: string | null;
    alt_public_key?: string | null;
    alt_deleted_at?: number | null;
};

export const AUDIO_JOIN_COLUMNS =
    "a.item_id, a.integrated_lufs, a.true_peak_dbtp, a.lra_lu, a.threshold_lufs, a.offset_db, " +
    "a.zone, a.state, a.target_lufs, a.output_lufs, a.output_true_peak, a.alt_item_id, " +
    "a.attempts, a.error, a.measured_at, a.leveled_at, a.updated_at, " +
    "alt.id AS alt_live_id, alt.url AS alt_url, alt.visibility AS alt_visibility, " +
    "alt.bucket AS alt_bucket, alt.r2_key AS alt_r2_key, alt.public_key AS alt_public_key, alt.deleted_at AS alt_deleted_at";

/**
 * Shapes joined `media_audio` + `media_items` (alt) rows returned inside a D1 batch into the
 * compact `AudioSummary` map keyed by parent `item_id` with zero extra round trips.
 */
export function buildAudioSummaries(rows: AudioJoinedRow[], mediaBaseUrl?: string): Map<string, AudioSummary> {
    const out = new Map<string, AudioSummary>();
    for (const r of rows) {
        let altId = r.alt_item_id;
        let altUrl: string | null = null;
        if (altId) {
            if (!r.alt_live_id || r.alt_deleted_at) {
                altId = null;
            } else if (r.alt_url) {
                altUrl = r.alt_url;
            } else if (mediaBaseUrl && r.alt_bucket && r.alt_r2_key) {
                altUrl = publicAltUrl(
                    {
                        deleted_at: r.alt_deleted_at ?? null,
                        visibility: (r.alt_visibility as MediaRow["visibility"]) ?? null,
                        bucket: r.alt_bucket as MediaRow["bucket"],
                        r2_key: r.alt_r2_key,
                        public_key: r.alt_public_key ?? null,
                    },
                    mediaBaseUrl,
                );
            }
        }
        const effectiveState: AudioState = r.state === "ready" && !altId ? "measured" : r.state;
        out.set(r.item_id, {
            integrated_lufs: r.integrated_lufs,
            true_peak_dbtp: r.true_peak_dbtp,
            lra_lu: r.lra_lu,
            zone: r.zone,
            state: effectiveState,
            target_lufs: r.target_lufs,
            output_lufs: r.output_lufs,
            output_true_peak: r.output_true_peak,
            alt_id: altId,
            alt_url: altUrl,
            error: r.error,
            measured_at: r.measured_at,
            leveled_at: r.leveled_at,
        });
    }
    return out;
}

/**
 * Builds the compact `audio` summary map keyed by parent `item_id` for GET /library and GET /sync.
 * Never throws (graceful pre-0047 fallback).
 */
export async function audioSummariesForFiles(
    db: D1Database,
    files: {
        id: string;
        role?: string | null;
        url?: string | null;
        visibility?: string | null;
        bucket?: string;
        public_key?: string | null;
        r2_key?: string;
        made_spec?: string | null;
        made_from?: string | null;
    }[],
    mediaBaseUrl?: string,
): Promise<Map<string, AudioSummary>> {
    const out = new Map<string, AudioSummary>();
    if (files.length === 0) return out;
    const rows = await readAudioRows(
        db,
        files.map((f) => f.id),
    );
    if (rows.size === 0) return out;

    const byId = new Map(files.map((f) => [f.id, f]));
    const missingAltIds: string[] = [];
    for (const r of rows.values()) {
        if (r.alt_item_id && !byId.has(r.alt_item_id)) missingAltIds.push(r.alt_item_id);
    }
    const extraAlts = new Map<string, MediaRow>();
    if (missingAltIds.length > 0) {
        try {
            const marks = missingAltIds.map((_, i) => `?${i + 1}`).join(", ");
            const { results } = await db
                .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id IN (${marks}) AND deleted_at IS NULL`)
                .bind(...missingAltIds)
                .all<MediaRow>();
            for (const a of results) extraAlts.set(a.id, a);
        } catch {
            // best effort
        }
    }

    for (const [itemId, r] of rows) {
        let altId = r.alt_item_id;
        let altUrl: string | null = null;
        if (altId) {
            const inPage = byId.get(altId);
            if (inPage) {
                altUrl = inPage.url ?? (mediaBaseUrl && inPage.public_key && inPage.visibility === "public" ? `${withSlash(mediaBaseUrl)}${inPage.public_key}` : null);
            } else {
                const extra = extraAlts.get(altId);
                if (!extra) {
                    // Alt row was deleted outside audio cleanup; treat as not ready.
                    altId = null;
                } else if (mediaBaseUrl) {
                    altUrl = publicAltUrl(extra, mediaBaseUrl);
                } else {
                    altUrl = extra.url ?? null;
                }
            }
        }
        const effectiveState: AudioState = r.state === "ready" && !altId ? "measured" : r.state;
        out.set(itemId, {
            integrated_lufs: r.integrated_lufs,
            true_peak_dbtp: r.true_peak_dbtp,
            lra_lu: r.lra_lu,
            zone: r.zone,
            state: effectiveState,
            target_lufs: r.target_lufs,
            output_lufs: r.output_lufs,
            output_true_peak: r.output_true_peak,
            alt_id: altId,
            alt_url: altUrl,
            error: r.error,
            measured_at: r.measured_at,
            leveled_at: r.leveled_at,
        });
    }
    return out;
}

/**
 * Records a Pass 1 measurement into `media_audio`, preserving any existing live leveled alt.
 */
export async function recordMeasurement(
    db: D1Database,
    itemId: string,
    m: LoudnessMeasurement,
    now: number,
): Promise<{ classification: AudioClassification; existingAltId: string | null; existingTarget: number | null }> {
    const classification = classifyLoudness(m.integrated_lufs, m.true_peak_dbtp);
    const existing = await db
        .prepare("SELECT state, alt_item_id, target_lufs FROM media_audio WHERE item_id = ?1")
        .bind(itemId)
        .first<{ state: AudioState; alt_item_id: string | null; target_lufs: number | null }>();
    const hasAlt = Boolean(existing?.alt_item_id && existing.state === "ready");
    const nextState: AudioState = hasAlt
        ? "ready"
        : classification.zone === "silent"
          ? "skipped"
          : "measured";
    await db
        .prepare(
            `INSERT INTO media_audio (item_id, integrated_lufs, true_peak_dbtp, lra_lu, threshold_lufs, offset_db, zone, state, measured_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
             ON CONFLICT(item_id) DO UPDATE SET
                 integrated_lufs = excluded.integrated_lufs,
                 true_peak_dbtp = excluded.true_peak_dbtp,
                 lra_lu = excluded.lra_lu,
                 threshold_lufs = excluded.threshold_lufs,
                 offset_db = excluded.offset_db,
                 zone = excluded.zone,
                 state = CASE WHEN media_audio.state = 'ready' AND media_audio.alt_item_id IS NOT NULL THEN 'ready' ELSE excluded.state END,
                 error = NULL,
                 measured_at = excluded.measured_at,
                 updated_at = excluded.updated_at`,
        )
        .bind(
            itemId,
            m.integrated_lufs,
            m.true_peak_dbtp,
            m.lra_lu,
            m.threshold_lufs,
            m.offset_db,
            classification.zone,
            nextState,
            now,
        )
        .run();
    return {
        classification,
        existingAltId: existing?.alt_item_id ?? null,
        existingTarget: existing?.target_lufs ?? null,
    };
}

/**
 * Finds the live `audio_level` alt `media_items` row for a parent item (public or private).
 * Checks `media_audio.alt_item_id` first, falling back to scanning `role = 'alt'` rows by `made_from`.
 */
export async function findAudioAlt(db: D1Database, parentItemId: string): Promise<MediaRow | null> {
    try {
        const audio = await db
            .prepare("SELECT alt_item_id FROM media_audio WHERE item_id = ?1 AND alt_item_id IS NOT NULL")
            .bind(parentItemId)
            .first<{ alt_item_id: string }>();
        if (audio?.alt_item_id) {
            const alt = await db
                .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id = ?1 AND deleted_at IS NULL AND role = 'alt' LIMIT 1`)
                .bind(audio.alt_item_id)
                .first<MediaRow>();
            if (alt) return alt;
        }
    } catch (e) {
        if (!isMissingTable(e)) console.error("[audio] findAudioAlt lookup failed", String(e));
    }
    try {
        const { results } = await db
            .prepare(
                `SELECT ${ITEM_COLUMNS}, made_from, made_spec FROM media_items
                  WHERE deleted_at IS NULL AND role = 'alt' AND made_from LIKE ?1
                  ORDER BY created_at DESC, id DESC LIMIT 10`,
            )
            .bind(`%"${parentItemId}"%`)
            .all<MediaRow & { made_from?: string | null; made_spec?: string | null }>();
        for (const r of results) {
            if (isAudioLevelSpec(r.made_spec) && audioAltParentId(r.made_from) === parentItemId) return r;
        }
    } catch {
        // older schema without made_from/made_spec
    }
    return null;
}

/**
 * Batch lookup of live `audio_level` alt rows keyed by parent item ID (used for `/g/<id>?audio=normal`
 * and `/p/<key>?audio=normal` gallery links).
 */
export async function findAudioAltsFor(db: D1Database, parentIds: string[]): Promise<Map<string, MediaRow>> {
    const out = new Map<string, MediaRow>();
    if (parentIds.length === 0) return out;
    try {
        const marks = parentIds.map((_, i) => `?${i + 1}`).join(", ");
        const cols = ITEM_COLUMNS.split(", ")
            .map((c) => `m.${c}`)
            .join(", ");
        const { results } = await db
            .prepare(
                `SELECT a.item_id AS parent_id, ${cols}
                   FROM media_audio a
                   JOIN media_items m ON m.id = a.alt_item_id
                  WHERE a.item_id IN (${marks}) AND m.deleted_at IS NULL AND m.role = 'alt'`,
            )
            .bind(...parentIds)
            .all<MediaRow & { parent_id: string }>();
        for (const r of results) {
            const { parent_id, ...row } = r;
            out.set(parent_id, row);
        }
    } catch (e) {
        if (!isMissingTable(e)) console.error("[audio] findAudioAltsFor failed", String(e));
    }
    return out;
}

/**
 * Cleans up `media_audio` references when an item (either a parent or an alt) is deleted.
 */
export async function deleteAudioStateForItem(db: D1Database, itemId: string, now: number): Promise<void> {
    try {
        await db.prepare("DELETE FROM media_audio WHERE item_id = ?1").bind(itemId).run();
        await db
            .prepare(
                `UPDATE media_audio
                    SET alt_item_id = NULL,
                        state = CASE WHEN integrated_lufs IS NOT NULL AND zone != 'silent' THEN 'measured'
                                     WHEN zone = 'silent' THEN 'skipped'
                                     ELSE 'pending' END,
                        target_lufs = NULL,
                        output_lufs = NULL,
                        output_true_peak = NULL,
                        leveled_at = NULL,
                        updated_at = ?2
                  WHERE alt_item_id = ?1`,
            )
            .bind(itemId, now)
            .run();
    } catch (e) {
        if (!isMissingTable(e)) console.error("[audio] deleteAudioStateForItem failed", itemId, String(e));
    }
}

/**
 * Removes the leveled alt of a parent video (R2 objects + soft-delete row + reset `media_audio`).
 * Safe to call repeatedly (idempotent when no alt exists).
 */
export async function removeAudioAlt(
    d: Pick<VisDeps, "db" | "originals" | "media" | "mediaBaseUrl" | "now" | "purge">,
    parentItemId: string,
    prefetchedAlt?: MediaRow | null,
): Promise<{ removed: boolean; altId: string | null; bytes: number }> {
    const alt = prefetchedAlt !== undefined ? prefetchedAlt : await findAudioAlt(d.db, parentItemId);
    const now = d.now();
    if (!alt) {
        try {
            await d.db
                .prepare(
                    `UPDATE media_audio
                        SET alt_item_id = NULL,
                            state = CASE WHEN integrated_lufs IS NOT NULL AND zone != 'silent' THEN 'measured'
                                         WHEN zone = 'silent' THEN 'skipped'
                                         ELSE 'pending' END,
                            target_lufs = NULL,
                            output_lufs = NULL,
                            output_true_peak = NULL,
                            leveled_at = NULL,
                            error = NULL,
                            updated_at = ?2
                      WHERE item_id = ?1`,
                )
                .bind(parentItemId, now)
                .run();
        } catch (e) {
            if (!isMissingTable(e)) throw e;
        }
        return { removed: false, altId: null, bytes: 0 };
    }
    const purgeList: string[] = [];
    if (alt.bucket === "originals" && alt.public_key) {
        await d.media.delete(alt.public_key).catch(() => {});
        purgeList.push(`${withSlash(d.mediaBaseUrl)}${alt.public_key}`);
    }
    if (alt.bucket === "media") {
        await d.media.delete(alt.r2_key).catch(() => {});
        purgeList.push(`${withSlash(d.mediaBaseUrl)}${alt.r2_key}`);
    } else {
        await d.originals.delete(alt.r2_key).catch(() => {});
    }
    if (purgeList.length > 0) await purgeUrls(d, purgeList);
    await d.db
        .prepare("UPDATE media_items SET deleted_at = ?2, url = NULL, visibility = 'private' WHERE id = ?1 AND deleted_at IS NULL")
        .bind(alt.id, now)
        .run();
    try {
        await d.db
            .prepare(
                `UPDATE media_audio
                    SET alt_item_id = NULL,
                        state = CASE WHEN integrated_lufs IS NOT NULL AND zone != 'silent' THEN 'measured'
                                     WHEN zone = 'silent' THEN 'skipped'
                                     ELSE 'pending' END,
                        target_lufs = NULL,
                        output_lufs = NULL,
                        output_true_peak = NULL,
                        leveled_at = NULL,
                        error = NULL,
                        updated_at = ?2
                  WHERE item_id = ?1 OR alt_item_id = ?3`,
            )
            .bind(parentItemId, now, alt.id)
            .run();
    } catch (e) {
        if (!isMissingTable(e)) throw e;
    }
    return { removed: true, altId: alt.id, bytes: alt.bytes ?? 0 };
}

// ---- Durable Object job service ---------------------------------------------------------------

export type AudioLevelDeps = {
    db: D1Database;
    storage: KV;
    originals: OriginalsBucket;
    media: PublishBucket;
    mediaBaseUrl: string;
    now: () => number;
    ensureRunning: () => Promise<void>;
    callHelper: (path: string, init?: RequestInit, timeoutMs?: number) => Promise<Response>;
    helperBusy: () => Promise<boolean>;
    scheduleSweep?: () => void | Promise<void>;
    renew?: () => void;
    purge?: PurgeFn;
    randomBytes?: (n: number) => Uint8Array;
};

type AudioMeasureJob = { at: number; busy?: number };
type AudioLevelJob = { at: number; target: AudioTargetLufs; manual?: boolean; busy?: number };

type ParentVideoRow = MediaRow & { post_key: string | null };

export class AudioLevelService {
    private running: Promise<void> | null = null;

    constructor(private d: AudioLevelDeps) {}

    isBusy(): boolean {
        return this.running !== null;
    }

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[audio] scheduling sweep failed", String(e));
        }
    }

    /**
     * Called when `AboutProbeService` receives a piggybacked EBU R128 measurement from `POST /about`.
     * Records the measurement and, when settings mode is `auto` and the clip is out of range (`loud` or `quiet`),
     * queues Pass 2 leveling automatically.
     */
    async onAboutLoudness(itemId: string, m: LoudnessMeasurement): Promise<void> {
        try {
            const settings = await readAudioSettings(this.d.db);
            if (settings.mode === "off") return;
            const { classification, existingAltId, existingTarget } = await recordMeasurement(this.d.db, itemId, m, this.d.now());
            if (
                settings.mode === "auto" &&
                classification.autoLevel &&
                (!existingAltId || existingTarget !== settings.target_lufs)
            ) {
                await this.enqueueLevelInternal(itemId, settings.target_lufs, false);
            }
        } catch (e) {
            if (!isMissingTable(e)) console.error("[audio] onAboutLoudness failed", itemId, String(e));
        }
    }

    /**
     * Manual trigger from Studio Deck (`POST /library/items/:id/audio/level`).
     * Immediately marks the row `rendering` and queues a high-priority level job.
     */
    async requestLevel(
        itemId: string,
        opts: { target?: AudioTargetLufs } = {},
    ): Promise<{ ok: true; state: AudioState; target_lufs: AudioTargetLufs; queued: boolean } | { ok: false; status: number; code: string }> {
        const row = await this.loadParent(itemId);
        if (!row) return { ok: false, status: 404, code: "error.library.not_found" };
        if (!isVideoContentType(row.content_type) || row.role === "alt") {
            return { ok: false, status: 409, code: "error.audio.not_video" };
        }
        const settings = await readAudioSettings(this.d.db);
        const target: AudioTargetLufs = opts.target ?? settings.target_lufs;
        const now = this.d.now();
        await this.d.db
            .prepare(
                `INSERT INTO media_audio (item_id, zone, state, target_lufs, error, updated_at)
                 VALUES (?1, 'pending', 'rendering', ?2, NULL, ?3)
                 ON CONFLICT(item_id) DO UPDATE SET
                     state = 'rendering',
                     target_lufs = excluded.target_lufs,
                     error = NULL,
                     attempts = 0,
                     updated_at = excluded.updated_at`,
            )
            .bind(row.id, target, now)
            .run();
        await this.d.storage.put(AUDIO_LEVEL_PREFIX + row.id, { at: now, target, manual: true } satisfies AudioLevelJob);
        await this.scheduleSweep();
        return { ok: true, state: "rendering", target_lufs: target, queued: true };
    }

    private async enqueueLevelInternal(itemId: string, target: AudioTargetLufs, manual: boolean): Promise<boolean> {
        const key = AUDIO_LEVEL_PREFIX + itemId;
        const existing = await this.d.storage.get<AudioLevelJob>(key);
        if (existing && existing.target === target && (!manual || existing.manual)) return false;
        const now = this.d.now();
        await this.d.db
            .prepare("UPDATE media_audio SET state = 'rendering', target_lufs = ?2, error = NULL, updated_at = ?3 WHERE item_id = ?1")
            .bind(itemId, target, now)
            .run();
        await this.d.storage.put(key, { at: now, target, manual } satisfies AudioLevelJob);
        await this.scheduleSweep();
        return true;
    }

    /**
     * Queues measurement and (in `auto` mode) leveling work.
     * - Without `backfill`: inspects recent saves (`newSince`, default 48 h) not yet measured, plus any measured
     *   out-of-range videos waiting for auto-leveling.
     * - With `backfill: true`: walks the whole video library newest-first (up to `limit` per sweep) without blocking live saves.
     */
    async kick(
        limit: number = AUDIO_KICK_MAX,
        opts: { backfill?: boolean; newSince?: number } = {},
    ): Promise<{ queued_measure: number; queued_level: number; eligible: number; mode: AudioMode; target_lufs: AudioTargetLufs }> {
        const settings = await readAudioSettings(this.d.db);
        if (settings.mode === "off") {
            return { queued_measure: 0, queued_level: 0, eligible: 0, mode: "off", target_lufs: settings.target_lufs };
        }
        const n = Math.max(1, Math.min(AUDIO_KICK_MAX, Math.floor(limit) || AUDIO_KICK_MAX));
        const now = this.d.now();
        const backfill = opts.backfill ? 1 : 0;
        const since = opts.newSince ?? now - 48 * 60 * 60 * 1000;
        const retrySince = now - AUDIO_RETRY_MS;

        let queuedMeasure = 0;
        let queuedLevel = 0;

        // 1. Videos that need Pass 1 measurement.
        const measureWhere = `m.deleted_at IS NULL
            AND lower(coalesce(m.content_type, '')) LIKE 'video/%'
            AND (m.role IS NULL OR m.role != 'alt')
            AND (?1 = 1 OR m.created_at >= ?2)
            AND (a.item_id IS NULL OR a.state = 'pending' OR (a.state = 'failed' AND a.integrated_lufs IS NULL AND a.updated_at < ?3 AND a.attempts < ?4))`;
        const { results: toMeasure } = await this.d.db
            .prepare(
                `SELECT m.id FROM media_items m LEFT JOIN media_audio a ON a.item_id = m.id
                  WHERE ${measureWhere}
                  ORDER BY m.created_at DESC, m.id DESC LIMIT ?5`,
            )
            .bind(backfill, since, retrySince, AUDIO_MAX_ATTEMPTS, n)
            .all<{ id: string }>();

        for (const r of toMeasure) {
            const key = AUDIO_MEASURE_PREFIX + r.id;
            if (await this.d.storage.get(key)) continue;
            await this.d.storage.put(key, { at: now } satisfies AudioMeasureJob);
            queuedMeasure++;
        }

        // 2. Measured out-of-range videos that need Pass 2 leveling when mode is `auto`.
        if (settings.mode === "auto") {
            const levelWhere = `m.deleted_at IS NULL
                AND lower(coalesce(m.content_type, '')) LIKE 'video/%'
                AND (m.role IS NULL OR m.role != 'alt')
                AND a.zone IN ('loud', 'quiet')
                AND (
                    (a.state = 'measured' AND a.alt_item_id IS NULL)
                    OR (a.state = 'failed' AND a.integrated_lufs IS NOT NULL AND a.updated_at < ?1 AND a.attempts < ?2)
                )`;
            const { results: toLevel } = await this.d.db
                .prepare(
                    `SELECT m.id FROM media_audio a JOIN media_items m ON m.id = a.item_id
                      WHERE ${levelWhere}
                      ORDER BY m.created_at DESC, m.id DESC LIMIT ?3`,
                )
                .bind(retrySince, AUDIO_MAX_ATTEMPTS, n)
                .all<{ id: string }>();
            for (const r of toLevel) {
                if (await this.enqueueLevelInternal(r.id, settings.target_lufs, false)) queuedLevel++;
            }
        }

        const total = await this.d.db
            .prepare(
                `SELECT COUNT(*) AS n FROM media_items m LEFT JOIN media_audio a ON a.item_id = m.id
                  WHERE ${measureWhere}`,
            )
            .bind(backfill, since, retrySince, AUDIO_MAX_ATTEMPTS)
            .first<{ n: number }>();

        if (queuedMeasure > 0 || queuedLevel > 0) await this.scheduleSweep();
        return {
            queued_measure: queuedMeasure,
            queued_level: queuedLevel,
            eligible: Number(total?.n ?? 0),
            mode: settings.mode,
            target_lufs: settings.target_lufs,
        };
    }

    async idle(maxMs = 20_000): Promise<void> {
        const p = this.running;
        if (!p) return;
        try {
            await raceCeiling(p, maxMs, "audio loudness job");
        } catch {
            // still running: helper answers busy
        }
    }

    /**
     * Runs one queued audio job per pass while the helper is free.
     * Priority: manual level requests -> auto level jobs -> measure jobs.
     */
    async sweep(): Promise<number> {
        let levels: Map<string, AudioLevelJob>;
        let measures: Map<string, AudioMeasureJob>;
        try {
            levels = await this.d.storage.list<AudioLevelJob>({ prefix: AUDIO_LEVEL_PREFIX });
            measures = await this.d.storage.list<AudioMeasureJob>({ prefix: AUDIO_MEASURE_PREFIX });
        } catch (e) {
            console.error("[audio] listing jobs failed", String(e));
            return 0;
        }
        const waiting = levels.size + measures.size;
        if (waiting === 0) return 0;
        if (this.running) return waiting;
        try {
            if (await this.d.helperBusy()) return waiting;
        } catch {
            return waiting;
        }

        let pickLevel: [string, AudioLevelJob] | null = null;
        for (const e of levels) {
            if (!pickLevel) {
                pickLevel = e;
                continue;
            }
            const aManual = e[1]?.manual ? 1 : 0;
            const bManual = pickLevel[1]?.manual ? 1 : 0;
            if (aManual > bManual || (aManual === bManual && (e[1]?.at ?? 0) < (pickLevel[1]?.at ?? 0))) {
                pickLevel = e;
            }
        }
        let pickMeasure: [string, AudioMeasureJob] | null = null;
        if (!pickLevel) {
            for (const e of measures) {
                if (!pickMeasure || (e[1]?.at ?? 0) < (pickMeasure[1]?.at ?? 0)) pickMeasure = e;
            }
        }
        if (!pickLevel && !pickMeasure) return 0;

        const run = pickLevel
            ? this.runLevelJob(pickLevel[0].slice(AUDIO_LEVEL_PREFIX.length), pickLevel[1] ?? { at: 0, target: -14 })
            : this.runMeasureJob(pickMeasure![0].slice(AUDIO_MEASURE_PREFIX.length), pickMeasure![1] ?? { at: 0 });
        const p: Promise<void> = run.finally(() => {
            if (this.running === p) this.running = null;
        });
        this.running = p;
        await p;
        try {
            const leftL = await this.d.storage.list<AudioLevelJob>({ prefix: AUDIO_LEVEL_PREFIX });
            const leftM = await this.d.storage.list<AudioMeasureJob>({ prefix: AUDIO_MEASURE_PREFIX });
            return leftL.size + leftM.size;
        } catch {
            return 1;
        }
    }

    // ---- single job runners --------------------------------------------------------------------

    private async loadParent(itemId: string): Promise<ParentVideoRow | null> {
        return (
            (await this.d.db
                .prepare(`SELECT ${ITEM_COLUMNS}, post_key FROM media_items WHERE id = ?1 AND deleted_at IS NULL LIMIT 1`)
                .bind(itemId)
                .first<ParentVideoRow>()) ?? null
        );
    }

    private async openSource(row: MediaRow): Promise<{ body: ReadableStream; size: number } | null> {
        if (row.bucket === "media") {
            const m = this.d.media as unknown as { get?: (key: string) => Promise<{ body: ReadableStream; size: number } | null> };
            if (typeof m.get === "function") return m.get(row.r2_key);
            return null;
        }
        return this.d.originals.get(row.r2_key);
    }

    private async markFailed(itemId: string, why: string, attempts: number): Promise<void> {
        const msg = why.slice(0, 200);
        console.error("[audio] job failed", itemId, msg);
        try {
            await this.d.db
                .prepare(
                    `INSERT INTO media_audio (item_id, zone, state, attempts, error, updated_at)
                     VALUES (?1, 'pending', 'failed', ?2, ?3, ?4)
                     ON CONFLICT(item_id) DO UPDATE SET
                         state = 'failed',
                         attempts = excluded.attempts,
                         error = excluded.error,
                         updated_at = excluded.updated_at`,
                )
                .bind(itemId, attempts, msg, this.d.now())
                .run();
        } catch (e) {
            console.error("[audio] markFailed DB write error", itemId, String(e));
        }
    }

    private async runMeasureJob(itemId: string, rec: AudioMeasureJob): Promise<void> {
        const drop = async (): Promise<void> => {
            await this.d.storage.delete(AUDIO_MEASURE_PREFIX + itemId).catch(() => {});
        };
        try {
            const row = await this.loadParent(itemId);
            if (!row || !isVideoContentType(row.content_type) || row.role === "alt") return await drop();
            const existing = await this.d.db
                .prepare("SELECT integrated_lufs, attempts FROM media_audio WHERE item_id = ?1")
                .bind(itemId)
                .first<{ integrated_lufs: number | null; attempts: number }>();
            if (existing?.integrated_lufs !== null && existing?.integrated_lufs !== undefined) return await drop();
            const attempts = (existing?.attempts ?? 0) + 1;

            try {
                await this.d.ensureRunning();
            } catch {
                await this.markFailed(itemId, "container not reachable", attempts);
                return await drop();
            }
            const obj = await this.openSource(row).catch(() => null);
            if (!obj) {
                await this.markFailed(itemId, "source file missing", attempts);
                return await drop();
            }
            const settings = await readAudioSettings(this.d.db);
            let res: Response;
            const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
            try {
                this.d.renew?.();
                res = await this.d.callHelper(
                    `/audio/measure?id=${itemId}&target=${settings.target_lufs}`,
                    { method: "POST", headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) }, body: obj.body },
                    AUDIO_MEASURE_CALL_MS,
                );
            } catch (e) {
                await obj.body.cancel().catch(() => {});
                await this.markFailed(itemId, `helper: ${String(e)}`, attempts);
                return await drop();
            } finally {
                if (keepAwake !== undefined) clearInterval(keepAwake);
            }
            if (res.status === 429) {
                await obj.body.cancel().catch(() => {});
                const busy = (rec.busy ?? 0) + 1;
                if (busy >= AUDIO_BUSY_LIMIT) {
                    await this.markFailed(itemId, "helper stayed busy", attempts);
                    return await drop();
                }
                await this.d.storage.put(AUDIO_MEASURE_PREFIX + itemId, { at: this.d.now(), busy } satisfies AudioMeasureJob);
                return;
            }
            if (!res.ok) {
                await obj.body.cancel().catch(() => {});
                const body = (await res.json().catch(() => null)) as { error?: { code?: string; detail?: string } } | null;
                const why = [body?.error?.code, body?.error?.detail].filter(Boolean).join(": ") || `helper ${res.status}`;
                await this.markFailed(itemId, why, attempts);
                return await drop();
            }
            const raw = (await res.json().catch(() => null)) as { loudness?: unknown } | null;
            const measured = parseLoudnessPayload(raw?.loudness);
            if (!measured) {
                await this.markFailed(itemId, "invalid loudness response", attempts);
                return await drop();
            }
            const { classification } = await recordMeasurement(this.d.db, itemId, measured, this.d.now());
            await drop();
            if (settings.mode === "auto" && classification.autoLevel) {
                await this.enqueueLevelInternal(itemId, settings.target_lufs, false);
            }
        } catch (e) {
            await this.markFailed(itemId, String(e), 1);
            await drop();
        }
    }

    private async runLevelJob(itemId: string, rec: AudioLevelJob): Promise<void> {
        const drop = async (): Promise<void> => {
            await this.d.storage.delete(AUDIO_LEVEL_PREFIX + itemId).catch(() => {});
        };
        try {
            const row = await this.loadParent(itemId);
            if (!row || !isVideoContentType(row.content_type) || row.role === "alt") return await drop();
            const existing = await this.d.db.prepare("SELECT * FROM media_audio WHERE item_id = ?1").bind(itemId).first<AudioRow>();
            const attempts = (existing?.attempts ?? 0) + 1;
            const target: AudioTargetLufs = rec.target === -16 ? -16 : -14;

            try {
                await this.d.ensureRunning();
            } catch {
                await this.markFailed(itemId, "container not reachable", attempts);
                return await drop();
            }
            const obj = await this.openSource(row).catch(() => null);
            if (!obj) {
                await this.markFailed(itemId, "source file missing", attempts);
                return await drop();
            }

            const q = new URLSearchParams({ id: itemId, target: String(target) });
            if (
                existing &&
                existing.integrated_lufs !== null &&
                existing.true_peak_dbtp !== null &&
                existing.lra_lu !== null &&
                existing.threshold_lufs !== null &&
                existing.offset_db !== null &&
                existing.integrated_lufs > AUDIO_SILENCE_LUFS
            ) {
                q.set("mi", String(existing.integrated_lufs));
                q.set("mtp", String(existing.true_peak_dbtp));
                q.set("mlra", String(existing.lra_lu));
                q.set("mthresh", String(existing.threshold_lufs));
                q.set("offset", String(existing.offset_db));
            }

            let res: Response;
            const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
            try {
                this.d.renew?.();
                res = await this.d.callHelper(
                    `/audio/level?${q}`,
                    { method: "POST", headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) }, body: obj.body },
                    AUDIO_LEVEL_CALL_MS,
                );
            } catch (e) {
                await obj.body.cancel().catch(() => {});
                await this.markFailed(itemId, `helper: ${String(e)}`, attempts);
                return await drop();
            } finally {
                if (keepAwake !== undefined) clearInterval(keepAwake);
            }
            if (res.status === 429) {
                await obj.body.cancel().catch(() => {});
                const busy = (rec.busy ?? 0) + 1;
                if (busy >= AUDIO_BUSY_LIMIT) {
                    await this.markFailed(itemId, "helper stayed busy", attempts);
                    return await drop();
                }
                await this.d.storage.put(AUDIO_LEVEL_PREFIX + itemId, { ...rec, at: this.d.now(), busy } satisfies AudioLevelJob);
                return;
            }
            if (!res.ok) {
                await obj.body.cancel().catch(() => {});
                const body = (await res.json().catch(() => null)) as { error?: { code?: string; detail?: string } } | null;
                const code = body?.error?.code ?? "";
                if (code === "error.audio.silent" || code === "error.audio.no_audio") {
                    const now = this.d.now();
                    await this.d.db
                        .prepare(
                            `INSERT INTO media_audio (item_id, integrated_lufs, true_peak_dbtp, lra_lu, zone, state, error, measured_at, updated_at)
                             VALUES (?1, -99, -99, 0, 'silent', 'skipped', NULL, ?2, ?2)
                             ON CONFLICT(item_id) DO UPDATE SET zone = 'silent', state = 'skipped', error = NULL, updated_at = excluded.updated_at`,
                        )
                        .bind(itemId, now)
                        .run();
                    return await drop();
                }
                const why = [code, body?.error?.detail].filter(Boolean).join(": ") || `helper ${res.status}`;
                await this.markFailed(itemId, why, attempts);
                return await drop();
            }

            const hdrNum = (name: string): number | null => {
                const raw = res.headers.get(name);
                if (raw === null || raw === "") return null;
                const n = Number(raw);
                return Number.isFinite(n) ? n : null;
            };
            const inLufs = hdrNum("x-audio-input-lufs") ?? existing?.integrated_lufs ?? null;
            const inTp = hdrNum("x-audio-input-tp") ?? existing?.true_peak_dbtp ?? null;
            const inLra = hdrNum("x-audio-input-lra") ?? existing?.lra_lu ?? null;
            const inThresh = hdrNum("x-audio-input-thresh") ?? existing?.threshold_lufs ?? null;
            const inOffset = hdrNum("x-audio-offset") ?? existing?.offset_db ?? null;
            const outLufs = hdrNum("x-audio-output-lufs") ?? target;
            const outTp = hdrNum("x-audio-output-tp") ?? AUDIO_TRUE_PEAK_CEILING;
            const normType = res.headers.get("x-audio-norm-type") ?? "linear";
            const outWidth = hdrNum("x-audio-width") ?? row.width;
            const outHeight = hdrNum("x-audio-height") ?? row.height;
            const outDuration = hdrNum("x-audio-duration") ?? row.duration;

            const bytes = new Uint8Array(await res.arrayBuffer());
            if (bytes.byteLength <= 32) {
                await this.markFailed(itemId, "empty leveled output", attempts);
                return await drop();
            }

            const now = this.d.now();
            const altId = mintItemId(this.d.randomBytes);
            const altKey = `made/${altId}.mp4`;
            await this.d.originals.put(altKey, bytes, {
                httpMetadata: { contentType: "video/mp4" },
                customMetadata: { source: "made", role: "alt", kind: AUDIO_SPEC_KIND, parentId: row.id, createdAt: String(now) },
            });

            const spec = {
                kind: AUDIO_SPEC_KIND,
                target_lufs: target,
                input_lufs: inLufs,
                input_tp: inTp,
                output_lufs: outLufs,
                output_tp: outTp,
                norm_type: normType,
            };
            const postKey = row.post_key ?? row.session_id ?? row.link ?? row.id;
            try {
                await this.d.db
                    .prepare(
                        `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, visibility, role, made_from, made_spec, post_key)
                         VALUES (?1, 'private', 'made', 'originals', ?2, NULL, ?3, 'video/mp4', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'private', 'alt', ?12, ?13, ?14)`,
                    )
                    .bind(
                        altId,
                        altKey,
                        row.name,
                        bytes.byteLength,
                        outWidth,
                        outHeight,
                        outDuration,
                        row.link,
                        row.session_id,
                        row.key_id,
                        now,
                        JSON.stringify([row.id]),
                        JSON.stringify(spec),
                        postKey,
                    )
                    .run();
            } catch (e) {
                await this.d.originals.delete(altKey).catch(() => {});
                await this.markFailed(itemId, `insert alt failed: ${String(e)}`, attempts);
                return await drop();
            }

            // Mirror to public bucket if the parent video is public right now.
            if (effectiveVisibility(row) === "public") {
                try {
                    const fresh = await getRow(this.d.db, altId);
                    if (fresh) {
                        const visDeps: VisDeps = {
                            db: this.d.db,
                            originals: this.d.originals,
                            media: this.d.media,
                            mediaBaseUrl: this.d.mediaBaseUrl,
                            now: this.d.now,
                            randomBytes: this.d.randomBytes,
                            purge: this.d.purge,
                        };
                        await makePublic(visDeps, fresh, row.key_id ?? "system:audio");
                    }
                } catch (e) {
                    console.error("[audio] mirroring alt public failed", altId, String(e));
                }
            }

            // Replace any earlier audio_level alt for this parent.
            const prevAltId = existing?.alt_item_id;
            if (prevAltId && prevAltId !== altId) {
                try {
                    const prev = await getRow(this.d.db, prevAltId);
                    if (prev) {
                        if (prev.public_key) {
                            await this.d.media.delete(prev.public_key).catch(() => {});
                            await purgeUrls(this.d, [`${withSlash(this.d.mediaBaseUrl)}${prev.public_key}`]);
                        }
                        await this.d.originals.delete(prev.r2_key).catch(() => {});
                        await this.d.db
                            .prepare("UPDATE media_items SET deleted_at = ?2, url = NULL, visibility = 'private' WHERE id = ?1 AND deleted_at IS NULL")
                            .bind(prev.id, now)
                            .run();
                    }
                } catch (e) {
                    console.error("[audio] cleaning up previous alt failed", prevAltId, String(e));
                }
            }

            const zone: AudioZone =
                inLufs !== null && inTp !== null ? classifyLoudness(inLufs, inTp).zone : existing?.zone ?? "balanced";
            await this.d.db
                .prepare(
                    `INSERT INTO media_audio (
                         item_id, integrated_lufs, true_peak_dbtp, lra_lu, threshold_lufs, offset_db,
                         zone, state, target_lufs, output_lufs, output_true_peak, alt_item_id,
                         attempts, error, measured_at, leveled_at, updated_at
                     )
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'ready', ?8, ?9, ?10, ?11, 0, NULL, ?12, ?13, ?13)
                     ON CONFLICT(item_id) DO UPDATE SET
                         integrated_lufs = COALESCE(excluded.integrated_lufs, media_audio.integrated_lufs),
                         true_peak_dbtp = COALESCE(excluded.true_peak_dbtp, media_audio.true_peak_dbtp),
                         lra_lu = COALESCE(excluded.lra_lu, media_audio.lra_lu),
                         threshold_lufs = COALESCE(excluded.threshold_lufs, media_audio.threshold_lufs),
                         offset_db = COALESCE(excluded.offset_db, media_audio.offset_db),
                         zone = excluded.zone,
                         state = 'ready',
                         target_lufs = excluded.target_lufs,
                         output_lufs = excluded.output_lufs,
                         output_true_peak = excluded.output_true_peak,
                         alt_item_id = excluded.alt_item_id,
                         attempts = 0,
                         error = NULL,
                         measured_at = COALESCE(media_audio.measured_at, excluded.measured_at),
                         leveled_at = excluded.leveled_at,
                         updated_at = excluded.updated_at`,
                )
                .bind(
                    itemId,
                    inLufs,
                    inTp,
                    inLra,
                    inThresh,
                    inOffset,
                    zone,
                    target,
                    outLufs,
                    outTp,
                    altId,
                    existing?.measured_at ?? now,
                    now,
                )
                .run();
            await drop();
        } catch (e) {
            await this.markFailed(itemId, String(e), 1);
            await drop();
        }
    }
}

export const AUDIO_QUEUE_RECENT_MS = 30 * 60 * 1000;
export const AUDIO_QUEUE_LIST_MAX = 25;

export type AudioQueueEntry = {
    item_id: string;
    title: string;
    state: "rendering" | "ready" | "failed";
    target_lufs: number | null;
    output_lufs: number | null;
    error: string | null;
    updated_at: number;
    leveled_at: number | null;
};

/**
 * Reads active (`rendering`) and recently settled (`ready` / `failed` within 30 minutes) audio leveling
 * jobs from D1 for `GET /queue` without ever waking the helper container.
 */
export async function queueAudioLevels(db: D1Database, now: number): Promise<AudioQueueEntry[]> {
    const cutoff = now - AUDIO_QUEUE_RECENT_MS;
    try {
        const res = await db
            .prepare(
                `SELECT a.item_id, m.name, a.state, a.target_lufs, a.output_lufs, a.error, a.updated_at, a.leveled_at
                 FROM media_audio a
                 JOIN media_items m ON m.id = a.item_id
                 WHERE m.deleted_at IS NULL
                   AND (
                       a.state = 'rendering'
                       OR (a.state = 'ready' AND a.leveled_at IS NOT NULL AND a.leveled_at >= ?1)
                       OR (a.state = 'failed' AND a.updated_at >= ?1)
                   )
                 ORDER BY CASE a.state WHEN 'rendering' THEN 0 ELSE 1 END, a.updated_at DESC
                 LIMIT ?2`,
            )
            .bind(cutoff, AUDIO_QUEUE_LIST_MAX)
            .all<{
                item_id: string;
                name: string | null;
                state: string;
                target_lufs: number | null;
                output_lufs: number | null;
                error: string | null;
                updated_at: number;
                leveled_at: number | null;
            }>();
        return (res.results ?? [])
            .filter((r) => r.state === "rendering" || r.state === "ready" || r.state === "failed")
            .map((r) => ({
                item_id: r.item_id,
                title: (r.name ?? "").trim() || r.item_id,
                state: r.state as "rendering" | "ready" | "failed",
                target_lufs: r.target_lufs,
                output_lufs: r.output_lufs,
                error: r.error,
                updated_at: r.updated_at,
                leveled_at: r.leveled_at,
            }));
    } catch (e) {
        if (isMissingTable(e)) return [];
        throw e;
    }
}

