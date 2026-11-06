// The probe of "what it's about" (APP-API-CONTRACT.md section 34.2): three frames and the sound of a post's lead video,
// cut by the container's ffmpeg (helper POST /about) and kept PRIVATE in R2 `cobalt-originals` under about/<item id>/,
// for the writer (about-writer.ts) to describe. Run exactly like a poster (poster.ts): a kick (the 15-minute cron's
// POST /about/kick) writes `about:<item id>` records into DO storage and arms the job sweep; the sweep runs one job per
// pass, only while the helper is free, and a save, upload or render arriving meanwhile waits for it (idle()). Free of
// Cloudflare imports so it runs under plain node in the tests.

import {
    ABOUT_MAX_ATTEMPTS,
    ABOUT_MAX_FRAMES,
    ABOUT_RETRY_MS,
    SAFETY_MAX_CLIPS,
    SAFETY_MAX_STILLS,
    audioKey,
    deleteAboutObjects,
    frameKey,
    probeable,
    safetyAudioKey,
    safetyClipKey,
    safetyStillKey,
    syncAboutRows,
} from "./about-store";
import { raceCeiling } from "./ceiling";
import { SAFETY_MAX_ATTEMPTS, SAFETY_RETRY_MS, safetyKind } from "./safety";
import { markSafetyPrepFailed, markSafetyReady, syncSafetyRows } from "./safety-store";
import { readPilotLabels } from "./safety-pilot";
import type { KV } from "./webp";

export const ABOUT_JOB_PREFIX = "about:";
export const SAFETY_JOB_PREFIX = "safety:";
export const SAFETY_KICK_MAX = 25;
// Rows one kick queues (the contract's cap), and the kick's default.
export const ABOUT_KICK_MAX = 25;
// The helper call carries the whole video in and the frames, sound and safety clip out (the helper gives itself 150 s).
export const ABOUT_CALL_MS = 180_000;
export const MAX_SAFETY_CLIP_BYTES = 8 * 1024 * 1024;
export const MAX_SAFETY_AUDIO_BYTES = 2 * 1024 * 1024;
export const ABOUT_BUSY_LIMIT = 120;
// What the helper may answer: three JPEGs, and 600 s of 32 kbit/s MP3 (2.4 MB, section 47) fit under this.
export const MAX_ABOUT_FRAME_BYTES = 2 * 1024 * 1024;
export const MAX_ABOUT_AUDIO_BYTES = 3 * 1024 * 1024;

// Where the probe reads the file (a private original, or a public-only copy) and writes its objects.
export type AboutBucket = {
    get(key: string): Promise<{ body: ReadableStream; size: number } | null>;
    put(key: string, value: Uint8Array, options: { httpMetadata: { contentType: string }; customMetadata: Record<string, string> }): Promise<unknown>;
    delete(key: string): Promise<unknown>;
};

export type AboutProbeDeps = {
    db: D1Database;
    storage: KV;
    originals: AboutBucket;
    // the public bucket, for a lead file that lives only there
    mediaRead?: { get(key: string): Promise<{ body: ReadableStream; size: number } | null> };
    now: () => number;
    ensureRunning: () => Promise<void>;
    callHelper: (path: string, init?: RequestInit, timeoutMs?: number) => Promise<Response>;
    helperBusy: () => Promise<boolean>;
    scheduleSweep?: () => void | Promise<void>;
    renew?: () => void;
};

type AboutJob = { busy?: number; at: number; kind?: "clip" | "still" };

export type SafetyPayload = { clips: Uint8Array[]; audio: Uint8Array | null; stills: Uint8Array[] };

const mp4Ok = (b: Uint8Array) => b.length > 8 && b.length <= MAX_SAFETY_CLIP_BYTES && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70;

// `undefined`: the helper did not send a safety clip (an older helper). `null`: it sent one and it is not a clip.
// A bare `{ clips, stills, audio }` (POST /safety) is accepted too.
export function parseSafetyPayload(body: unknown): SafetyPayload | null | undefined {
    if (!body || typeof body !== "object") return undefined;
    const o = body as Record<string, unknown>;
    const bag = "safety" in o ? o.safety : "clips" in o || "stills" in o ? o : undefined;
    if (bag === undefined) return undefined;
    if (!bag || typeof bag !== "object") return null;
    const b = bag as { clips?: unknown; audio?: unknown; stills?: unknown };
    if (b.clips !== undefined && !Array.isArray(b.clips)) return null;
    if (b.stills !== undefined && !Array.isArray(b.stills)) return null;
    const clips: Uint8Array[] = [];
    for (const c of Array.isArray(b.clips) ? b.clips : []) {
        const bytes = fromBase64(c);
        if (!bytes || !mp4Ok(bytes)) return null;
        clips.push(bytes);
    }
    if (clips.length > SAFETY_MAX_CLIPS) return null;
    const stills: Uint8Array[] = [];
    for (const s of Array.isArray(b.stills) ? b.stills : []) {
        const bytes = fromBase64(s);
        if (!bytes || bytes.length < 3 || bytes.length > MAX_ABOUT_FRAME_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
        stills.push(bytes);
    }
    if (stills.length > SAFETY_MAX_STILLS) return null;
    if (clips.length === 0 && stills.length === 0) return null;
    let audio: Uint8Array | null = null;
    if (b.audio !== null && b.audio !== undefined) {
        audio = fromBase64(b.audio);
        const mp3 = !!audio && audio.length >= 3 && ((audio[0] === 0x49 && audio[1] === 0x44 && audio[2] === 0x33) || (audio[0] === 0xff && (audio[1]! & 0xe0) === 0xe0));
        if (!audio || !mp3 || audio.length > MAX_SAFETY_AUDIO_BYTES) return null;
    }
    return { clips, audio, stills };
}

type JobRow = { post_key: string; item_id: string; probe_state: string; probe_attempts: number; bucket: string | null; r2_key: string | null; content_type: string | null; deleted_at: number | null };

export type ProbeAnswer = { frames: Uint8Array[]; audio: Uint8Array | null; duration: number | null };

function fromBase64(s: unknown): Uint8Array | null {
    if (typeof s !== "string" || s.length === 0) return null;
    try {
        const bin = atob(s);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    } catch {
        return null;
    }
}

// The helper's JSON, checked: 1..3 JPEGs, an MP3 (ID3 or a frame sync) or null. null when it is not that.
export function parseProbeAnswer(body: unknown): ProbeAnswer | null {
    if (!body || typeof body !== "object") return null;
    const b = body as { frames?: unknown; audio?: unknown; duration?: unknown };
    if (!Array.isArray(b.frames) || b.frames.length === 0 || b.frames.length > ABOUT_MAX_FRAMES) return null;
    const frames: Uint8Array[] = [];
    for (const f of b.frames) {
        const bytes = fromBase64(f);
        if (!bytes || bytes.length < 3 || bytes.length > MAX_ABOUT_FRAME_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
        frames.push(bytes);
    }
    let audio: Uint8Array | null = null;
    if (b.audio !== null && b.audio !== undefined) {
        audio = fromBase64(b.audio);
        const mp3 = !!audio && audio.length >= 3 && ((audio[0] === 0x49 && audio[1] === 0x44 && audio[2] === 0x33) || (audio[0] === 0xff && (audio[1]! & 0xe0) === 0xe0));
        if (!audio || !mp3 || audio.length > MAX_ABOUT_AUDIO_BYTES) return null;
    }
    const duration = typeof b.duration === "number" && Number.isFinite(b.duration) && b.duration >= 0 ? b.duration : null;
    return { frames, audio, duration };
}

export class AboutProbeService {
    private running: Promise<void> | null = null;

    constructor(private d: AboutProbeDeps) {}

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[about] scheduling the job sweep failed", String(e));
        }
    }

    // ---- queueing ----------------------------------------------------------------

    // Brings the rows up to date (one per live post) and queues up to `limit` probes: posts whose probe is pending, or
    // failed more than a day ago with fewer than ABOUT_MAX_ATTEMPTS attempts, newest first. `eligible` counts them all.
    async kick(limit: number = ABOUT_KICK_MAX): Promise<{ queued: number; eligible: number }> {
        const n = Math.max(1, Math.min(ABOUT_KICK_MAX, Math.floor(limit) || ABOUT_KICK_MAX));
        await syncAboutRows(this.d.db, this.d.now(), this.d.originals);
        const where = `(a.probe_state = 'pending' OR (a.probe_state = 'failed' AND (a.probe_at IS NULL OR a.probe_at < ?1) AND a.probe_attempts < ?2))`;
        const since = this.d.now() - ABOUT_RETRY_MS;
        const { results } = await this.d.db
            .prepare(
                `SELECT a.item_id FROM media_about a JOIN media_items m ON m.id = a.item_id
                  WHERE ${where} AND m.deleted_at IS NULL ORDER BY m.created_at DESC, a.item_id DESC LIMIT ?3`,
            )
            .bind(since, ABOUT_MAX_ATTEMPTS, n)
            .all<{ item_id: string }>();
        let queued = 0;
        for (const r of results) {
            const key = ABOUT_JOB_PREFIX + r.item_id;
            if (await this.d.storage.get(key)) continue;
            await this.d.storage.put(key, { at: this.d.now() } satisfies AboutJob);
            queued++;
        }
        const total = await this.d.db
            .prepare(`SELECT COUNT(*) AS n FROM media_about a WHERE ${where}`)
            .bind(since, ABOUT_MAX_ATTEMPTS)
            .first<{ n: number }>();
        if (queued > 0) await this.scheduleSweep();
        return { queued, eligible: total?.n ?? 0 };
    }

    // Queues safety clips (section 51.2). A new save whose about probe is still to come, or already finished, is left
    // to that probe: it stores the clip. A labelled pilot id is queued even when that probe is already done, and so
    // is every visual file when `backfill` is set. Those probes ran before the safety clip existed, so the about job
    // will not run again. Newest first. The ordinary library is not walked unless `backfill` is set.
    async kickSafety(limit: number = SAFETY_KICK_MAX, opts: { backfill?: boolean; newSince?: number } = {}): Promise<{ queued: number; eligible: number }> {
        const n = Math.max(1, Math.min(SAFETY_KICK_MAX, Math.floor(limit) || SAFETY_KICK_MAX));
        const now = this.d.now();
        const sync = await syncSafetyRows(this.d.db, now);
        for (const id of sync.removed) await deleteAboutObjects(this.d.originals, id);
        const labels = await readPilotLabels(this.d.originals).catch(() => null);
        const pilot = JSON.stringify((labels ?? []).map((l) => l.id));
        const since = opts.newSince ?? now - 48 * 60 * 60 * 1000;
        const backfill = opts.backfill ? 1 : 0;
        const prepSince = now - SAFETY_RETRY_MS;
        // Pilot ids and a backfill skip the "probe is not none" exclusion. Everyone else still does: a new lead's
        // about job is what cuts its clip, and an old lead stays untouched until Harmony turns backfill on.
        const where = `m.deleted_at IS NULL
            AND (lower(coalesce(m.content_type, '')) LIKE 'video/%' OR lower(coalesce(m.content_type, '')) LIKE 'image/%')
            AND lower(coalesce(m.content_type, '')) NOT IN ('image/heic', 'image/heif')
            AND (?3 = 1 OR m.id IN (SELECT value FROM json_each(?5)) OR NOT EXISTS (SELECT 1 FROM media_about a WHERE a.item_id = m.id AND a.probe_state != 'none'))
            AND (s.item_id IS NULL OR s.prep = 'pending' OR (s.prep = 'failed' AND (s.prep_at IS NULL OR s.prep_at < ?1) AND s.prep_attempts < ?2))
            AND (?3 = 1 OR m.created_at >= ?4 OR m.id IN (SELECT value FROM json_each(?5)))`;
        const { results } = await this.d.db
            .prepare(
                `SELECT m.id, m.content_type FROM media_items m LEFT JOIN media_safety s ON s.item_id = m.id
                  WHERE ${where} ORDER BY m.created_at DESC, m.id DESC LIMIT ?6`,
            )
            .bind(prepSince, SAFETY_MAX_ATTEMPTS, backfill, since, pilot, n)
            .all<{ id: string; content_type: string | null }>();
        let queued = 0;
        for (const r of results) {
            const kind = safetyKind(r.content_type);
            if (!kind) continue;
            const key = SAFETY_JOB_PREFIX + r.id;
            if (await this.d.storage.get(key)) continue;
            await this.d.storage.put(key, { at: now, kind } satisfies AboutJob);
            queued++;
        }
        const total = await this.d.db
            .prepare(`SELECT COUNT(*) AS n FROM media_items m LEFT JOIN media_safety s ON s.item_id = m.id WHERE ${where}`)
            .bind(prepSince, SAFETY_MAX_ATTEMPTS, backfill, since, pilot)
            .first<{ n: number }>();
        if (queued > 0) await this.scheduleSweep();
        return { queued, eligible: total?.n ?? 0 };
    }

    async pending(): Promise<number> {
        return (await this.d.storage.list<AboutJob>({ prefix: ABOUT_JOB_PREFIX })).size;
    }

    // ---- the sweep ----------------------------------------------------------------

    // Waits (bounded) for the probe running right now. Never rejects.
    async idle(maxMs = 20_000): Promise<void> {
        const p = this.running;
        if (!p) return;
        try {
            await raceCeiling(p, maxMs, "about probe");
        } catch {
            // still running: the helper answers busy, which every caller handles
        }
    }

    // One job per pass, only while the helper is free; returns how many are still queued. An about probe goes before
    // a safety clip, so a lead's frames are not delayed by a still. Never rejects.
    async sweep(): Promise<number> {
        let about: Map<string, AboutJob>;
        let safety: Map<string, AboutJob>;
        try {
            about = await this.d.storage.list<AboutJob>({ prefix: ABOUT_JOB_PREFIX });
            safety = await this.d.storage.list<AboutJob>({ prefix: SAFETY_JOB_PREFIX });
        } catch (e) {
            console.error("[about] listing jobs failed", String(e));
            return 0;
        }
        const waiting = about.size + safety.size;
        if (waiting === 0) return 0;
        if (this.running) return waiting;
        try {
            if (await this.d.helperBusy()) return waiting;
        } catch {
            return waiting;
        }
        const records = about.size > 0 ? about : safety;
        const prefix = about.size > 0 ? ABOUT_JOB_PREFIX : SAFETY_JOB_PREFIX;
        let pick: [string, AboutJob] | null = null;
        for (const e of records) if (!pick || (e[1]?.at ?? 0) < (pick[1]?.at ?? 0)) pick = e;
        if (!pick) return 0;
        const itemId = pick[0].slice(prefix.length);
        const run = prefix === ABOUT_JOB_PREFIX ? this.runJob(itemId, pick[1] ?? { at: 0 }) : this.runSafetyJob(itemId, pick[1] ?? { at: 0 });
        const p: Promise<void> = run.finally(() => {
            if (this.running === p) this.running = null;
        });
        this.running = p;
        await p;
        try {
            const left = await this.d.storage.list<AboutJob>({ prefix: ABOUT_JOB_PREFIX });
            const more = await this.d.storage.list<AboutJob>({ prefix: SAFETY_JOB_PREFIX });
            return left.size + more.size;
        } catch {
            return 1;
        }
    }

    // ---- one job -------------------------------------------------------------------

    private async drop(itemId: string): Promise<void> {
        await this.d.storage.delete(ABOUT_JOB_PREFIX + itemId).catch(() => {});
    }

    private async mark(itemId: string, state: "failed" | "none", why: string): Promise<void> {
        console.error("[about] probe", state, itemId, why);
        try {
            await this.d.db
                .prepare("UPDATE media_about SET probe_state = ?2, updated_at = ?3 WHERE item_id = ?1")
                .bind(itemId, state, this.d.now())
                .run();
        } catch (e) {
            console.error("[about] could not record the probe", itemId, String(e));
        }
        await this.drop(itemId);
    }

    private async runJob(itemId: string, rec: AboutJob): Promise<void> {
        try {
            const row = await this.d.db
                .prepare(
                    `SELECT a.post_key, a.item_id, a.probe_state, a.probe_attempts, m.bucket, m.r2_key, m.content_type, m.deleted_at
                       FROM media_about a LEFT JOIN media_items m ON m.id = a.item_id WHERE a.item_id = ?1 LIMIT 1`,
                )
                .bind(itemId)
                .first<JobRow>();
            // gone, done meanwhile, or nothing to cut
            if (!row || row.deleted_at !== null || !row.r2_key || row.probe_state === "done" || row.probe_state === "none") return await this.drop(itemId);
            if (!probeable(row.content_type)) return await this.mark(itemId, "none", "not a video");
            // counted now: a job that takes the Durable Object down still ends after ABOUT_MAX_ATTEMPTS
            const attempts = row.probe_attempts + 1;
            await this.d.db
                .prepare("UPDATE media_about SET probe_attempts = ?2, probe_at = ?3, updated_at = ?3 WHERE item_id = ?1")
                .bind(itemId, attempts, this.d.now())
                .run();
            const fail = (why: string) => this.mark(itemId, "failed", `${why} (attempt ${attempts})`);

            try {
                await this.d.ensureRunning();
            } catch {
                return await fail("container not reachable");
            }
            const bucket = row.bucket === "media" ? this.d.mediaRead : this.d.originals;
            if (!bucket) return await this.mark(itemId, "none", "no bucket for the file");
            let obj: Awaited<ReturnType<AboutBucket["get"]>>;
            try {
                obj = await bucket.get(row.r2_key);
            } catch (e) {
                return await fail(`R2 get: ${String(e)}`);
            }
            if (!obj) return await this.mark(itemId, "none", "the stored file is gone");

            let res: Response;
            const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
            try {
                this.d.renew?.();
                res = await this.d.callHelper(
                    `/about?id=${itemId}`,
                    { method: "POST", headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) }, body: obj.body },
                    ABOUT_CALL_MS,
                );
            } catch (e) {
                await obj.body.cancel().catch(() => {});
                await this.d.ensureRunning().catch(() => {});
                return await fail(`helper: ${String(e)}`);
            } finally {
                if (keepAwake !== undefined) clearInterval(keepAwake);
            }
            if (res.status === 429) {
                // another job holds the helper: not an attempt, try again next pass
                await obj.body.cancel().catch(() => {});
                await this.d.db.prepare("UPDATE media_about SET probe_attempts = ?2 WHERE item_id = ?1").bind(itemId, row.probe_attempts).run();
                const busy = (rec.busy ?? 0) + 1;
                if (busy >= ABOUT_BUSY_LIMIT) return await fail("the helper stayed busy");
                await this.d.storage.put(ABOUT_JOB_PREFIX + itemId, { busy, at: this.d.now() } satisfies AboutJob);
                return;
            }
            if (!res.ok) {
                await obj.body.cancel().catch(() => {});
                let code = "";
                try {
                    code = String(((await res.json()) as { error?: { code?: unknown } })?.error?.code ?? "");
                } catch {
                    // not JSON
                }
                // no video stream in it: nothing to cut, ever
                if (res.status === 400 && code === "error.studio.not_video") return await this.mark(itemId, "none", code);
                return await fail(code || `helper ${res.status}`);
            }
            const raw = await res.json().catch(() => null);
            const answer = parseProbeAnswer(raw);
            if (!answer) return await fail("the helper's answer is not frames and sound");
            const safety = parseSafetyPayload(raw);
            if (safety === null) return await fail("the safety clip is not a clip");

            const meta = { itemId, createdAt: String(this.d.now()) };
            try {
                for (let i = 0; i < ABOUT_MAX_FRAMES; i++) {
                    const key = frameKey(itemId, i + 1);
                    const f = answer.frames[i];
                    if (f) await this.d.originals.put(key, f, { httpMetadata: { contentType: "image/jpeg" }, customMetadata: { ...meta, about: "frame" } });
                    else await this.d.originals.delete(key);
                }
                if (answer.audio) {
                    await this.d.originals.put(audioKey(itemId), answer.audio, { httpMetadata: { contentType: "audio/mpeg" }, customMetadata: { ...meta, about: "audio" } });
                } else await this.d.originals.delete(audioKey(itemId));
                if (safety) await this.storeSafety(itemId, safety, meta);
            } catch (e) {
                return await fail(`R2 put: ${String(e)}`);
            }
            if (safety) {
                try {
                    await markSafetyReady(this.d.db, { itemId, clips: safety.clips.length, stills: safety.stills.length, hasAudio: !!safety.audio, now: this.d.now() });
                } catch (e) {
                    console.error("[safety] could not record the clip", itemId, String(e));
                }
            }
            await this.d.db
                .prepare(
                    `UPDATE media_about SET probe_state = 'done', frames = ?2, has_audio = ?3, probe_at = ?4, updated_at = ?4
                      WHERE item_id = ?1`,
                )
                .bind(itemId, answer.frames.length, answer.audio ? 1 : 0, this.d.now())
                .run();
            await this.drop(itemId);
        } catch (e) {
            console.error("[about] probe failed", itemId, String(e));
            await this.mark(itemId, "failed", String(e));
        }
    }

    private async storeSafety(itemId: string, safety: SafetyPayload, meta: { itemId: string; createdAt: string }): Promise<void> {
        for (let i = 0; i < SAFETY_MAX_CLIPS; i++) {
            const key = safetyClipKey(itemId, i + 1);
            const clip = safety.clips[i];
            if (clip) await this.d.originals.put(key, clip, { httpMetadata: { contentType: "video/mp4" }, customMetadata: { ...meta, about: "safety" } });
            else await this.d.originals.delete(key);
        }
        if (safety.audio) {
            await this.d.originals.put(safetyAudioKey(itemId), safety.audio, { httpMetadata: { contentType: "audio/mpeg" }, customMetadata: { ...meta, about: "safety-audio" } });
        } else await this.d.originals.delete(safetyAudioKey(itemId));
        for (let i = 0; i < SAFETY_MAX_STILLS; i++) {
            const key = safetyStillKey(itemId, i + 1);
            const still = safety.stills[i];
            if (still) await this.d.originals.put(key, still, { httpMetadata: { contentType: "image/jpeg" }, customMetadata: { ...meta, about: "safety-still" } });
            else await this.d.originals.delete(key);
        }
    }

    private async dropSafety(itemId: string): Promise<void> {
        await this.d.storage.delete(SAFETY_JOB_PREFIX + itemId).catch(() => {});
    }

    // A file the about probe does not cut: POST /safety, then the same private objects.
    private async runSafetyJob(itemId: string, rec: AboutJob): Promise<void> {
        try {
            const row = await this.d.db
                .prepare(`SELECT id, bucket, r2_key, content_type, deleted_at FROM media_items WHERE id = ?1`)
                .bind(itemId)
                .first<{ id: string; bucket: string | null; r2_key: string | null; content_type: string | null; deleted_at: number | null }>();
            const kind = safetyKind(row?.content_type ?? null);
            if (!row || row.deleted_at !== null || !row.r2_key || !kind) return await this.dropSafety(itemId);
            // The about probe may have stored the clip while this job waited (a pilot id whose probe was still
            // pending). Cutting it again would clear a rating that had already landed.
            const prep = await this.d.db.prepare(`SELECT prep FROM media_safety WHERE item_id = ?1`).bind(itemId).first<{ prep: string }>();
            if (prep?.prep === "ready") return await this.dropSafety(itemId);
            const fail = async (why: string) => {
                console.error("[safety] clip", itemId, why);
                try {
                    await markSafetyPrepFailed(this.d.db, itemId, this.d.now());
                } catch (e) {
                    console.error("[safety] could not record the clip", itemId, String(e));
                }
                await this.dropSafety(itemId);
            };
            try {
                await this.d.ensureRunning();
            } catch {
                return await fail("container not reachable");
            }
            const bucket = row.bucket === "media" ? this.d.mediaRead : this.d.originals;
            if (!bucket) return await fail("no bucket for the file");
            let obj: Awaited<ReturnType<AboutBucket["get"]>>;
            try {
                obj = await bucket.get(row.r2_key);
            } catch (e) {
                return await fail(`R2 get: ${String(e)}`);
            }
            if (!obj) return await fail("the stored file is gone");
            let res: Response;
            const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
            try {
                this.d.renew?.();
                res = await this.d.callHelper(
                    `/safety?id=${itemId}&kind=${kind}`,
                    { method: "POST", headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) }, body: obj.body },
                    ABOUT_CALL_MS,
                );
            } catch (e) {
                await obj.body.cancel().catch(() => {});
                await this.d.ensureRunning().catch(() => {});
                return await fail(`helper: ${String(e)}`);
            } finally {
                if (keepAwake !== undefined) clearInterval(keepAwake);
            }
            if (res.status === 429) {
                await obj.body.cancel().catch(() => {});
                const busy = (rec.busy ?? 0) + 1;
                if (busy >= ABOUT_BUSY_LIMIT) return await fail("the helper stayed busy");
                await this.d.storage.put(SAFETY_JOB_PREFIX + itemId, { busy, at: this.d.now(), kind } satisfies AboutJob);
                return;
            }
            if (!res.ok) {
                await obj.body.cancel().catch(() => {});
                return await fail(`helper ${res.status}`);
            }
            const safety = parseSafetyPayload(await res.json().catch(() => null));
            if (!safety) return await fail("the helper's answer is not a safety clip");
            const meta = { itemId, createdAt: String(this.d.now()) };
            try {
                await this.storeSafety(itemId, safety, meta);
                await markSafetyReady(this.d.db, { itemId, clips: safety.clips.length, stills: safety.stills.length, hasAudio: !!safety.audio, now: this.d.now() });
            } catch (e) {
                return await fail(`store: ${String(e)}`);
            }
            await this.dropSafety(itemId);
        } catch (e) {
            console.error("[safety] clip failed", itemId, String(e));
            await this.dropSafety(itemId);
        }
    }
}
