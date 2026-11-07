// The D1 side of per-file safety ratings (APP-API-CONTRACT.md section 51): one media_safety row per live visual
// file, the stage's allow-list, and the post's rolled-up level. Free of Cloudflare imports.

import { POST_KEY_SQL } from "./post-key";
import {
    contentLevel,
    effectiveSafety,
    rollupLevels,
    SAFETY_PREP_REV,
    sanitizePrepError,
    safetyConfigFrom,
    safetyKind,
    stageAllows,
    type EffectiveSafety,
    type SafetyConfig,
    type SafetyLevel,
    type SafetySnapshot,
} from "./safety";

export type { SafetySnapshot };

const CHUNK = 80;

type Stmt = ReturnType<D1Database["prepare"]>;

async function runAll(db: D1Database, stmts: Stmt[]): Promise<void> {
    for (let i = 0; i < stmts.length; i += 50) {
        const part = stmts.slice(i, i + 50);
        if (typeof (db as { batch?: unknown }).batch === "function") await db.batch(part);
        else for (const s of part) await s.run();
    }
}

const VISUAL_SQL = `(
    lower(coalesce(m.content_type, '')) LIKE 'video/%'
    OR lower(coalesce(m.content_type, '')) LIKE 'image/%'
) AND lower(coalesce(m.content_type, '')) NOT IN ('image/heic', 'image/heif')`;

// A pending row for every live visual file that lacks one, and the rows of files that are gone. Throws before
// migration 0032. Does not queue anything: the kick decides which of these are prepared.
export async function syncSafetyRows(db: D1Database, now: number): Promise<{ created: number; removed: string[] }> {
    const inserted = await db
        .prepare(
            `INSERT OR IGNORE INTO media_safety (item_id, level, prep, updated_at)
             SELECT m.id, 'pending', 'pending', ?1 FROM media_items m
              WHERE m.deleted_at IS NULL AND ${VISUAL_SQL}`,
        )
        .bind(now)
        .run();
    const { results } = await db
        .prepare(
            `SELECT s.item_id FROM media_safety s
              WHERE s.item_id NOT IN (SELECT id FROM media_items WHERE deleted_at IS NULL)`,
        )
        .all<{ item_id: string }>();
    const removed = results.map((r) => r.item_id);
    if (removed.length > 0) {
        await db
            .prepare(`DELETE FROM media_safety WHERE item_id IN (SELECT value FROM json_each(?1))`)
            .bind(JSON.stringify(removed))
            .run();
    }
    return { created: inserted.meta?.changes ?? 0, removed };
}

export type ReadyUpdate = { itemId: string; clips: number; stills: number; hasAudio: boolean; now: number };

// The clip landed. A previous model level is cleared (the bytes changed) ; Harmony's override is kept.
export async function markSafetyReady(db: D1Database, u: ReadyUpdate): Promise<void> {
    await db
        .prepare(
            `INSERT INTO media_safety (item_id, level, prep, clips, stills, has_audio, prep_at, prep_attempts, prep_rev, input_hash, probs, rated_at, updated_at)
             VALUES (?1, 'pending', 'ready', ?2, ?3, ?4, ?5, 0, ?6, NULL, NULL, NULL, ?5)
             ON CONFLICT(item_id) DO UPDATE SET
                prep = 'ready', clips = ?2, stills = ?3, has_audio = ?4, prep_at = ?5, prep_attempts = 0, prep_rev = ?6,
                prep_error = NULL, input_hash = NULL, probs = NULL, rated_at = NULL,
                level = CASE WHEN media_safety.user_level IS NULL THEN 'pending' ELSE media_safety.level END,
                updated_at = ?5`,
        )
        .bind(u.itemId, u.clips, u.stills, u.hasAudio ? 1 : 0, u.now, SAFETY_PREP_REV)
        .run();
}

export async function markSafetyPrepFailed(db: D1Database, itemId: string, now: number, reason?: string | null): Promise<void> {
    const prepError = reason ? sanitizePrepError(reason) : null;
    await db
        .prepare(
            `INSERT INTO media_safety (item_id, prep, prep_at, prep_attempts, prep_rev, prep_error, updated_at)
             VALUES (?1, 'failed', ?2, 1, ?3, ?4, ?2)
             ON CONFLICT(item_id) DO UPDATE SET prep = 'failed', prep_at = ?2, prep_attempts = media_safety.prep_attempts + 1, prep_rev = ?3, prep_error = ?4, updated_at = ?2`,
        )
        .bind(itemId, now, SAFETY_PREP_REV, prepError)
        .run();
}

const sourceIds = (raw: string | null): string[] => {
    if (!raw) return [];
    try {
        const v = JSON.parse(raw);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x.length > 0) : [];
    } catch {
        return [];
    }
};

type ItemSrc = { id: string; made_from: string | null };

async function loadSources(db: D1Database, ids: string[]): Promise<Map<string, string[]>> {
    const out = new Map<string, string[]>();
    let pending = [...new Set(ids)];
    for (let depth = 0; depth < 4 && pending.length > 0; depth++) {
        const found = new Map<string, string[]>();
        for (let i = 0; i < pending.length; i += CHUNK) {
            const part = pending.slice(i, i + CHUNK);
            const { results } = await db
                .prepare(`SELECT id, made_from FROM media_items WHERE deleted_at IS NULL AND id IN (SELECT value FROM json_each(?1))`)
                .bind(JSON.stringify(part))
                .all<ItemSrc>();
            for (const r of results) found.set(r.id, sourceIds(r.made_from));
        }
        const next: string[] = [];
        for (const id of pending) {
            const src = found.get(id) ?? [];
            out.set(id, src);
            for (const s of src) if (!out.has(s)) next.push(s);
        }
        pending = [...new Set(next)];
    }
    return out;
}

async function loadRows(db: D1Database, ids: string[]): Promise<Map<string, SafetySnapshot>> {
    const out = new Map<string, SafetySnapshot>();
    const all = [...ids];
    for (let i = 0; i < all.length; i += CHUNK) {
        const part = all.slice(i, i + CHUNK);
        const { results } = await db
            .prepare(
                `SELECT item_id, level, user_level, probs, gore, drawn, minor_sexual FROM media_safety
                  WHERE item_id IN (SELECT value FROM json_each(?1))`,
            )
            .bind(JSON.stringify(part))
            .all<SafetySnapshot & { item_id: string }>();
        for (const r of results) out.set(r.item_id, r);
    }
    return out;
}

// Ids that may reach the stage. Missing table, or any read error: none of them (fail closed).
export async function stageSafeIds(db: D1Database, ids: string[], cfg: SafetyConfig = safetyConfigFrom({})): Promise<Set<string>> {
    const unique = [...new Set(ids)];
    if (unique.length === 0) return new Set();
    try {
        const sources = await loadSources(db, unique);
        const needed = new Set<string>(unique);
        for (const src of sources.values()) for (const s of src) needed.add(s);
        const rows = await loadRows(db, [...needed]);
        const ok = new Set<string>();
        for (const id of unique) {
            if (stageAllows(effectiveSafety(id, rows, sources, cfg), cfg)) ok.add(id);
        }
        return ok;
    } catch (e) {
        console.error("[safety] stage read failed", String(e).slice(0, 200));
        return new Set();
    }
}

export async function effectiveOf(db: D1Database, id: string, cfg: SafetyConfig = safetyConfigFrom({})): Promise<EffectiveSafety> {
    const sources = await loadSources(db, [id]);
    const needed = new Set<string>([id]);
    for (const src of sources.values()) for (const s of src) needed.add(s);
    const rows = await loadRows(db, [...needed]);
    return effectiveSafety(id, rows, sources, cfg);
}

// The post's rolled-up level (strictest item, or pending when any item is unrated).
export async function postSafetyLevel(db: D1Database, postKey: string, cfg: SafetyConfig = safetyConfigFrom({})): Promise<SafetyLevel> {
    const { results } = await db
        .prepare(
            `SELECT id FROM (SELECT m.id AS id, ${POST_KEY_SQL} AS post_key FROM media_items m WHERE m.deleted_at IS NULL)
              WHERE post_key = ?1`,
        )
        .bind(postKey)
        .all<{ id: string }>();
    if (results.length === 0) return "pending";
    const levels: SafetyLevel[] = [];
    for (const r of results) {
        const e = await effectiveOf(db, r.id, cfg);
        levels.push(e.rated ? e.level : "pending");
    }
    return rollupLevels(levels);
}

export const isVisual = (contentType: string | null): boolean => safetyKind(contentType) !== null;

export { contentLevel };
