// Server-made posters (APP-API-CONTRACT.md section 13): a small JPEG cut out of a stored
// video by the container's ffmpeg (helper POST /poster), kept in the PUBLIC bucket next to
// the media under an unguessable name (<10 base62>.jpg) and recorded as the URL in
// `media_items.poster` (+ mirrored on the original's studio sessions, so GET /studio/<sid>
// needs no join). Free of Cloudflare imports so it runs under plain node in the tests.
//
// Why a queue and not "right after ready": the save's `ready` must never wait for ffmpeg, and
// work started after a Durable Object response does not survive (README: runtime lessons). So
// a ready save (or a library read, or the daily cron) only writes `poster:<item id>` records
// into DO storage and arms the job sweep; the sweep (StudioService.sweep) makes one poster per
// pass, only while the helper is free (ONE ffmpeg job at a time, as everywhere), and a render,
// save or upload that arrives meanwhile waits for it (idle()) instead of seeing the helper busy.
//
// What gets a poster: the private ORIGINAL of a video or gif (a saved link, an upload). The
// public copy hosted from it shares the same poster object; a webp is its own picture (ffmpeg
// here cannot decode animated WebP, so there is nothing to cut), and images need none.

import { raceCeiling } from "./ceiling";
import { randomBase62 } from "./ids";
import { MEDIA_NAME_LENGTH, type KV, type MediaBucket } from "./webp";
import type { PublishBucket } from "./publish";
import type { OriginalsBucket } from "./studio";

// The public bucket as the poster code needs it: bytes in (the JPEG), keys out.
export type MediaStore = MediaBucket & PublishBucket;

export const POSTER_PREFIX = "poster:";
// A row whose poster could not be made is not tried again for this long (poster_at).
export const POSTER_COOLDOWN_MS = 24 * 60 * 60 * 1000;
// Helper attempts per job (counted when one starts, so a job that kills the Durable
// Object cannot run for ever), and how many busy answers in a row count as one.
export const POSTER_MAX_ATTEMPTS = 3;
export const POSTER_BUSY_LIMIT = 120;
// Rows one kick queues (the library read and the cron's own default / maximum).
export const POSTER_BATCH = 25;
export const POSTER_MAX_BATCH = 100;
// The helper call carries the whole video in and one JPEG out (inside LOCK_STALE_MS-style
// bounds; the video is at most 200 MB).
export const POSTER_CALL_MS = 60_000;
// A save, upload or render that arrives while a poster is being made waits at most this long.
export const POSTER_IDLE_WAIT_MS = 20_000;
export const MAX_POSTER_BYTES = 2 * 1024 * 1024;

// Videos and gifs have a frame to show; everything else is its own picture (or none).
export const isPosterType = (contentType: string | null | undefined): boolean =>
    !!contentType && (contentType.startsWith("video/") || contentType === "image/gif");

export type PosterJob = {
    // helper attempts started
    attempts: number;
    // consecutive "helper busy" answers (not attempts)
    busy?: number;
    at: number;
};

export type PosterDeps = {
    db: D1Database;
    storage: KV;
    originals: OriginalsBucket;
    media: MediaStore;
    // https://media.../ (with or without the slash)
    mediaBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    ensureRunning: () => Promise<void>;
    // The StudioService's helper call (it enforces our own ceiling on the call).
    callHelper: (path: string, init?: RequestInit, timeoutMs?: number) => Promise<Response>;
    // Is a save or an encode using the helper right now? (A 429 from the helper says the
    // same; this just avoids sending a whole video to learn it.)
    helperBusy: () => Promise<boolean>;
    // Arms the job sweep (the Durable Object's scheduleSweepSoon).
    scheduleSweep?: () => void | Promise<void>;
    // Renews the container's sleepAfter timer while a long upload runs.
    renew?: () => void;
};

type ItemRow = {
    id: string;
    bucket: string;
    r2_key: string;
    content_type: string | null;
    poster: string | null;
    deleted_at: number | null;
};

export class PosterService {
    // the job running right now (in memory only: the Durable Object is the helper's only client)
    private running: Promise<void> | null = null;

    constructor(private d: PosterDeps) {}

    private base(): string {
        return this.d.mediaBaseUrl.endsWith("/") ? this.d.mediaBaseUrl : `${this.d.mediaBaseUrl}/`;
    }

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[poster] scheduling the job sweep failed", String(e));
        }
    }

    // ---- queueing ----------------------------------------------------------------

    // Queues a job for a library row unless it already has one. Returns whether it queued.
    private async enqueue(itemId: string): Promise<boolean> {
        const key = POSTER_PREFIX + itemId;
        if (await this.d.storage.get(key)) return false;
        await this.d.storage.put(key, { attempts: 0, at: this.d.now() } satisfies PosterJob);
        return true;
    }

    // A save just became ready: queue the poster of its stored original. Never throws.
    async onReady(r2Key: string): Promise<void> {
        try {
            const row = await this.d.db
                .prepare(
                    "SELECT id, content_type, poster FROM media_items WHERE bucket = 'originals' AND r2_key = ?1 AND deleted_at IS NULL LIMIT 1",
                )
                .bind(r2Key)
                .first<{ id: string; content_type: string | null; poster: string | null }>();
            if (!row || row.poster || !isPosterType(row.content_type)) return;
            if (await this.enqueue(row.id)) await this.scheduleSweep();
        } catch (e) {
            console.error("[poster] queueing after ready failed", String(e));
        }
    }

    // Queues up to `limit` originals that have no poster and were not tried in the last day
    // (the library read, the daily cron and POST /library/posters/backfill all come here).
    // `eligible` counts every such row, queued now or earlier.
    async kick(limit: number = POSTER_BATCH): Promise<{ queued: number; eligible: number }> {
        const n = Math.max(1, Math.min(POSTER_MAX_BATCH, Math.floor(limit) || POSTER_BATCH));
        const since = this.d.now() - POSTER_COOLDOWN_MS;
        const where =
            "deleted_at IS NULL AND bucket = 'originals' AND poster IS NULL AND (poster_at IS NULL OR poster_at < ?1) AND (content_type LIKE 'video/%' OR content_type = 'image/gif')";
        const { results } = await this.d.db
            .prepare(`SELECT id FROM media_items WHERE ${where} ORDER BY created_at DESC, id DESC LIMIT ?2`)
            .bind(since, n)
            .all<{ id: string }>();
        let queued = 0;
        for (const r of results) if (await this.enqueue(r.id)) queued++;
        const total = await this.d.db
            .prepare(`SELECT COUNT(*) AS n FROM media_items WHERE ${where}`)
            .bind(since)
            .first<{ n: number }>();
        if (queued > 0) await this.scheduleSweep();
        return { queued, eligible: total?.n ?? 0 };
    }

    // How many jobs are queued.
    async pending(): Promise<number> {
        return (await this.d.storage.list<PosterJob>({ prefix: POSTER_PREFIX })).size;
    }

    // ---- the sweep ----------------------------------------------------------------

    // Waits (bounded) for the poster being made right now, so a render, save or upload that
    // arrives meanwhile does not find the helper busy. Never rejects.
    async idle(maxMs: number = POSTER_IDLE_WAIT_MS): Promise<void> {
        const p = this.running;
        if (!p) return;
        try {
            await raceCeiling(p, maxMs, "poster job");
        } catch {
            // still running: the helper answers busy, which every caller already handles
        }
    }

    // One job per pass, only while the helper is free. Returns how many are still queued
    // (the sweep re-arms itself while that is above zero). Never rejects.
    async sweep(): Promise<number> {
        let records: Map<string, PosterJob>;
        try {
            records = await this.d.storage.list<PosterJob>({ prefix: POSTER_PREFIX });
        } catch (e) {
            console.error("[poster] listing jobs failed", String(e));
            return 0;
        }
        if (records.size === 0) return 0;
        if (this.running) return records.size;
        try {
            if (await this.d.helperBusy()) return records.size;
        } catch {
            return records.size;
        }
        // the oldest first
        let pick: [string, PosterJob] | null = null;
        for (const e of records) if (!pick || (e[1]?.at ?? 0) < (pick[1]?.at ?? 0)) pick = e;
        if (!pick) return 0;
        const itemId = pick[0].slice(POSTER_PREFIX.length);
        const p: Promise<void> = this.runJob(itemId, pick[1] ?? { attempts: 0, at: 0 }).finally(() => {
            if (this.running === p) this.running = null;
        });
        this.running = p;
        await p;
        try {
            return (await this.d.storage.list<PosterJob>({ prefix: POSTER_PREFIX })).size;
        } catch {
            return 1;
        }
    }

    // ---- one job -------------------------------------------------------------------

    private async drop(itemId: string): Promise<void> {
        await this.d.storage.delete(POSTER_PREFIX + itemId).catch(() => {});
    }

    // Gives the row up for a day (the lazy kick skips it until then) and ends the job.
    private async giveUp(itemId: string, why: string): Promise<void> {
        console.error("[poster] giving up on", itemId, why);
        try {
            await this.d.db
                .prepare("UPDATE media_items SET poster_at = ?1 WHERE id = ?2 AND poster IS NULL")
                .bind(this.d.now(), itemId)
                .run();
        } catch (e) {
            console.error("[poster] could not record the failure", itemId, String(e));
        }
        await this.drop(itemId);
    }

    // A failure worth another try: the attempt was counted when the job started.
    private async retryOrGiveUp(itemId: string, attempts: number, why: string): Promise<void> {
        if (attempts >= POSTER_MAX_ATTEMPTS) return this.giveUp(itemId, why);
        console.error("[poster] will retry", itemId, why);
        await this.d.storage.put(POSTER_PREFIX + itemId, { attempts, at: this.d.now() } satisfies PosterJob).catch(() => {});
    }

    private async runJob(itemId: string, rec: PosterJob): Promise<void> {
        const attempts = rec.attempts + 1;
        try {
            const row = await this.d.db
                .prepare("SELECT id, bucket, r2_key, content_type, poster, deleted_at FROM media_items WHERE id = ?1")
                .bind(itemId)
                .first<ItemRow>();
            // deleted, done meanwhile, or not something with a frame: nothing to do
            if (!row || row.deleted_at !== null || row.poster || row.bucket !== "originals" || !isPosterType(row.content_type)) {
                return await this.drop(itemId);
            }
            // counted now: a job that takes the Durable Object down still ends after MAX attempts
            await this.d.storage.put(POSTER_PREFIX + itemId, { ...rec, attempts, at: this.d.now() } satisfies PosterJob);

            try {
                await this.d.ensureRunning();
            } catch {
                return await this.retryOrGiveUp(itemId, attempts, "container not reachable");
            }

            let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
            try {
                obj = await this.d.originals.get(row.r2_key);
            } catch (e) {
                return await this.retryOrGiveUp(itemId, attempts, `R2 get: ${String(e)}`);
            }
            if (!obj) return await this.giveUp(itemId, "the stored video is gone");

            let res: Response;
            const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
            try {
                this.d.renew?.();
                res = await this.d.callHelper(
                    `/poster?id=${row.id}`,
                    {
                        method: "POST",
                        headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) },
                        body: obj.body,
                    },
                    POSTER_CALL_MS,
                );
            } catch (e) {
                await obj.body.cancel().catch(() => {});
                await this.d.ensureRunning().catch(() => {});
                return await this.retryOrGiveUp(itemId, attempts, `helper: ${String(e)}`);
            } finally {
                if (keepAwake !== undefined) clearInterval(keepAwake);
            }

            if (res.status === 429) {
                // another job holds the helper: not an attempt, try again next pass
                await obj.body.cancel().catch(() => {});
                const busy = (rec.busy ?? 0) + 1;
                if (busy >= POSTER_BUSY_LIMIT) return await this.giveUp(itemId, "the helper stayed busy");
                await this.d.storage.put(POSTER_PREFIX + itemId, { attempts: rec.attempts, busy, at: this.d.now() } satisfies PosterJob);
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
                // the helper refused this file for good (not a video, no frame, too large)
                if (res.status < 500) return await this.giveUp(itemId, code || `helper ${res.status}`);
                return await this.retryOrGiveUp(itemId, attempts, code || `helper ${res.status}`);
            }

            const jpeg = await res.arrayBuffer();
            const head = new Uint8Array(jpeg, 0, Math.min(2, jpeg.byteLength));
            if (jpeg.byteLength === 0 || jpeg.byteLength > MAX_POSTER_BYTES || head[0] !== 0xff || head[1] !== 0xd8) {
                return await this.giveUp(itemId, "the helper's answer is not a JPEG");
            }

            const name = `${randomBase62(MEDIA_NAME_LENGTH, this.d.randomBytes)}.jpg`;
            const url = this.base() + name;
            try {
                await this.d.media.put(name, jpeg, {
                    httpMetadata: { contentType: "image/jpeg", cacheControl: "public, max-age=31536000, immutable" },
                    customMetadata: { poster: "1", itemId: row.id, createdAt: String(this.d.now()) },
                });
            } catch (e) {
                await this.d.media.delete(name).catch(() => {});
                return await this.retryOrGiveUp(itemId, attempts, `R2 put: ${String(e)}`);
            }

            // Record it. Only a row that is still live and still without one takes it; if the
            // owner deleted the original meanwhile, the object just written has no owner.
            const upd = await this.d.db
                .prepare(
                    "UPDATE media_items SET poster = ?1, poster_at = ?2 WHERE id = ?3 AND deleted_at IS NULL AND poster IS NULL",
                )
                .bind(url, this.d.now(), row.id)
                .run();
            if (Number(upd.meta?.changes ?? 0) === 0) {
                await this.d.media.delete(name).catch(() => {});
                return await this.drop(itemId);
            }
            // The sessions of this original, and the public copies hosted from them, show it too.
            await this.d.db
                .prepare("UPDATE studio_sessions SET poster = ?1 WHERE r2_key = ?2 AND poster IS NULL")
                .bind(url, row.r2_key)
                .run();
            await this.d.db
                .prepare(
                    `UPDATE media_items SET poster = ?1
                     WHERE poster IS NULL AND deleted_at IS NULL AND bucket = 'media' AND source = 'host'
                       AND session_id IN (SELECT id FROM studio_sessions WHERE r2_key = ?2)`,
                )
                .bind(url, row.r2_key)
                .run();
            await this.drop(itemId);
        } catch (e) {
            console.error("[poster] job failed", itemId, String(e));
            await this.retryOrGiveUp(itemId, attempts, String(e));
        }
    }
}
