// Moving previews for gallery links (APP-API-CONTRACT.md section 29): a short, silent animated WebP of
// each video in a live gallery link, so Discord's media gallery moves without a tap (Discord plays
// animated images by itself; a video always waits for a tap). Free of Cloudflare imports so it runs
// under plain node in the tests.
//
// The encode is an ordinary helper webp job (WebpService.createFromUpload, owner label "loop:<item id>"),
// so the line sees it as a running job (studio held()) and the job sweep collects it into the PUBLIC
// bucket exactly like a /webp job; the WebpService records no library row for this owner. This service
// only decides what to make and records the result in D1 `media_loops`:
//
//   loop:<item id>   {attempts, at, job?, startedAt?, busy?}   one per video waiting or being made
//
// Like posters: a kick writes records and arms the sweep; the sweep starts one job at a time and only
// while the helper is free; nothing runs after a response. A row that failed is tried again after a day.

import { randomBase62 } from "./ids";
import { publicUrlOf } from "./share-sets";
import { ITEM_COLUMNS, type MediaRow } from "./visibility";
import type { KV, Reply, WebpParams } from "./webp";

export const LOOP_PREFIX = "loop:";
export const LOOP_OWNER_PREFIX = "loop:";
// What a preview is: the first seconds, small and light (a gallery of ten is fetched by Discord within
// its 10 s budget, every file included).
export const LOOP_SECONDS = 4;
export const LOOP_MIN_SECONDS = 0.5;
export const LOOP_FPS = 12;
export const LOOP_QUALITY = "low" as const;
export const LOOP_WIDTH = 480;
export const LOOP_SMALL_WIDTH = 320;
// Helper attempts per video (counted when one starts) and busy answers in a row that count as one.
export const LOOP_MAX_ATTEMPTS = 3;
export const LOOP_BUSY_LIMIT = 120;
// A started job not done after this long is given up (the helper drops it on its own).
export const LOOP_JOB_MS = 10 * 60 * 1000;
// A video that failed waits this long before a kick offers it again.
export const LOOP_COOLDOWN_MS = 24 * 60 * 60 * 1000;
// Videos one kick queues, and previews one cleanup checks.
export const LOOP_KICK_MAX = 50;
export const LOOP_CLEAN_MAX = 200;
// Live gallery links a kick reads (newest first).
export const LOOP_SETS_MAX = 500;

export type LoopJob = {
    attempts: number;
    at: number;
    // the helper job, once started
    job?: string;
    startedAt?: number;
    busy?: number;
};

// The bits of a bucket a preview needs: read a stored video, delete a preview.
export interface ReadBucket {
    get(key: string): Promise<{ body: ReadableStream; size: number } | null>;
}

export type LoopDeps = {
    db: D1Database;
    storage: KV;
    // where a public video's bytes are: its private original, or the public copy
    originals: ReadBucket;
    mediaRead?: ReadBucket;
    // deletes a preview object from the public bucket
    mediaDelete?: (key: string) => Promise<void>;
    mediaBaseUrl: string;
    webp: {
        createFromUpload(
            keyId: string,
            params: WebpParams,
            getUpload: () => Promise<{ body: ReadableStream; size: number } | null>,
            opts?: { id?: string },
        ): Promise<Reply>;
        status(keyId: string, id: string, waitSeconds: number): Promise<Reply>;
    };
    now: () => number;
    // Is anything else using the helper (a save, a render, a poster, the line)?
    helperBusy: () => Promise<boolean>;
    scheduleSweep?: () => void | Promise<void>;
    randomBytes?: (n: number) => Uint8Array;
};

const isVideo = (t: string | null | undefined) => !!t && t.startsWith("video/");
const ownerOf = (itemId: string) => LOOP_OWNER_PREFIX + itemId;
const parseIds = (s: string): string[] => {
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

// The webp URLs of the videos that have one: item id -> URL. A missing table (migration 0018 not
// applied yet) or any D1 error is "none", so a link page never breaks over a preview.
export async function loopUrls(db: D1Database, itemIds: string[]): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    if (itemIds.length === 0) return out;
    try {
        const marks = itemIds.map((_, i) => `?${i + 1}`).join(", ");
        const { results } = await db
            .prepare(`SELECT item_id, url FROM media_loops WHERE item_id IN (${marks}) AND url IS NOT NULL`)
            .bind(...itemIds)
            .all<{ item_id: string; url: string }>();
        for (const r of results) out.set(r.item_id, r.url);
    } catch {
        // no table, or D1 hiccup: no previews
    }
    return out;
}

export class LoopService {
    constructor(private d: LoopDeps) {}

    private base(): string {
        return this.d.mediaBaseUrl.endsWith("/") ? this.d.mediaBaseUrl : `${this.d.mediaBaseUrl}/`;
    }

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[loops] scheduling the job sweep failed", String(e));
        }
    }

    // ---- queueing --------------------------------------------------------------------------

    // Queues every public video of a live gallery link that has no preview and did not fail in the last
    // day (at most `limit`). With `clean`, also deletes previews whose video was deleted or is no longer
    // public. Called after a link is made and by the daily cron.
    async kick(limit: number = LOOP_KICK_MAX, opts: { clean?: boolean } = {}): Promise<{ queued: number; removed: number }> {
        const n = Math.max(1, Math.min(LOOP_KICK_MAX, Math.floor(limit) || LOOP_KICK_MAX));
        const { results: sets } = await this.d.db
            .prepare(`SELECT items FROM share_sets WHERE revoked_at IS NULL ORDER BY created_at DESC LIMIT ${LOOP_SETS_MAX}`)
            .all<{ items: string }>();
        const ids = [...new Set(sets.flatMap((s) => parseIds(s.items)))];
        const rows = await this.rows(ids);
        const done = new Map<string, { url: string | null; tried_at: number | null }>();
        for (let i = 0; i < ids.length; i += 90) {
            const part = ids.slice(i, i + 90);
            const marks = part.map((_, j) => `?${j + 1}`).join(", ");
            const { results } = await this.d.db
                .prepare(`SELECT item_id, url, tried_at FROM media_loops WHERE item_id IN (${marks})`)
                .bind(...part)
                .all<{ item_id: string; url: string | null; tried_at: number | null }>();
            for (const r of results) done.set(r.item_id, r);
        }
        const since = this.d.now() - LOOP_COOLDOWN_MS;
        let queued = 0;
        for (const id of ids) {
            if (queued >= n) break;
            const r = rows.get(id);
            if (!r || !isVideo(r.content_type) || !publicUrlOf(r, this.d.mediaBaseUrl)) continue;
            const prev = done.get(id);
            if (prev?.url || (prev?.tried_at && prev.tried_at > since)) continue;
            const key = LOOP_PREFIX + id;
            if (await this.d.storage.get(key)) continue;
            await this.d.storage.put(key, { attempts: 0, at: this.d.now() } satisfies LoopJob);
            queued++;
        }
        const removed = opts.clean ? await this.clean() : 0;
        if (queued > 0) await this.scheduleSweep();
        return { queued, removed };
    }

    // Previews of videos that are gone or private: the object and the row go.
    private async clean(): Promise<number> {
        const { results } = await this.d.db
            .prepare(`SELECT item_id, r2_key FROM media_loops WHERE r2_key IS NOT NULL ORDER BY made_at LIMIT ${LOOP_CLEAN_MAX}`)
            .all<{ item_id: string; r2_key: string }>();
        const rows = await this.rows(results.map((r) => r.item_id));
        let removed = 0;
        for (const l of results) {
            const r = rows.get(l.item_id);
            if (r && publicUrlOf(r, this.d.mediaBaseUrl)) continue;
            try {
                await this.d.mediaDelete?.(l.r2_key);
                await this.d.db.prepare("DELETE FROM media_loops WHERE item_id = ?1").bind(l.item_id).run();
                removed++;
            } catch (e) {
                console.error("[loops] removing a preview failed", l.item_id, String(e));
            }
        }
        return removed;
    }

    private async rows(ids: string[]): Promise<Map<string, MediaRow>> {
        const out = new Map<string, MediaRow>();
        for (let i = 0; i < ids.length; i += 90) {
            const part = ids.slice(i, i + 90);
            if (part.length === 0) continue;
            const marks = part.map((_, j) => `?${j + 1}`).join(", ");
            const { results } = await this.d.db
                .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id IN (${marks})`)
                .bind(...part)
                .all<MediaRow>();
            for (const r of results) out.set(r.id, r);
        }
        return out;
    }

    // How many previews are waiting or being made.
    async pending(): Promise<number> {
        return (await this.d.storage.list<LoopJob>({ prefix: LOOP_PREFIX })).size;
    }

    // ---- the sweep ---------------------------------------------------------------------------

    // Collects a started job, else starts the oldest waiting one while the helper is free. Returns how
    // many are still queued (the job sweep re-arms itself while that is above zero). Never rejects.
    async sweep(): Promise<number> {
        let records: Map<string, LoopJob>;
        try {
            records = await this.d.storage.list<LoopJob>({ prefix: LOOP_PREFIX });
        } catch (e) {
            console.error("[loops] listing jobs failed", String(e));
            return 0;
        }
        if (records.size === 0) return 0;
        try {
            for (const [key, rec] of records) {
                if (rec?.job) await this.collect(key.slice(LOOP_PREFIX.length), rec);
            }
            const left = await this.d.storage.list<LoopJob>({ prefix: LOOP_PREFIX });
            // one at a time: a job still running holds the rest
            if ([...left.values()].some((r) => r?.job)) return left.size;
            if (left.size === 0 || (await this.d.helperBusy())) return left.size;
            let pick: [string, LoopJob] | null = null;
            for (const e of left) if (!pick || (e[1]?.at ?? 0) < (pick[1]?.at ?? 0)) pick = e;
            if (pick) await this.start(pick[0].slice(LOOP_PREFIX.length), pick[1] ?? { attempts: 0, at: 0 });
            return (await this.d.storage.list<LoopJob>({ prefix: LOOP_PREFIX })).size;
        } catch (e) {
            console.error("[loops] sweep failed", String(e));
            return records.size;
        }
    }

    // ---- one video ---------------------------------------------------------------------------

    private async drop(itemId: string): Promise<void> {
        await this.d.storage.delete(LOOP_PREFIX + itemId).catch(() => {});
    }

    private async giveUp(itemId: string, why: string): Promise<void> {
        console.error("[loops] giving up on", itemId, why);
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO media_loops (item_id, tried_at) VALUES (?1, ?2) ON CONFLICT(item_id) DO UPDATE SET tried_at = excluded.tried_at",
                )
                .bind(itemId, this.d.now())
                .run();
        } catch (e) {
            console.error("[loops] could not record the failure", itemId, String(e));
        }
        await this.drop(itemId);
    }

    private async retryOrGiveUp(itemId: string, attempts: number, why: string): Promise<void> {
        if (attempts >= LOOP_MAX_ATTEMPTS) return this.giveUp(itemId, why);
        console.error("[loops] will retry", itemId, why);
        await this.d.storage.put(LOOP_PREFIX + itemId, { attempts, at: this.d.now() } satisfies LoopJob).catch(() => {});
    }

    private async start(itemId: string, rec: LoopJob): Promise<void> {
        const row = await this.d.db
            .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE id = ?1`)
            .bind(itemId)
            .first<MediaRow>();
        const url = row ? publicUrlOf(row, this.d.mediaBaseUrl) : null;
        // gone, private now, or not a video: nothing to make
        if (!row || !url || !isVideo(row.content_type)) return this.drop(itemId);
        if (row.duration !== null && row.duration < LOOP_MIN_SECONDS) return this.giveUp(itemId, "too short");
        const source = row.bucket === "originals" ? this.d.originals : row.bucket === "media" ? this.d.mediaRead : undefined;
        if (!source) return this.giveUp(itemId, `no bucket for ${row.bucket}`);

        const attempts = rec.attempts + 1;
        // counted now: a job that takes the Durable Object down still ends after MAX attempts
        await this.d.storage.put(LOOP_PREFIX + itemId, { ...rec, attempts, at: this.d.now() } satisfies LoopJob);
        const params: WebpParams = {
            url,
            start: 0,
            length: row.duration !== null ? Math.max(LOOP_MIN_SECONDS, Math.min(LOOP_SECONDS, row.duration)) : LOOP_SECONDS,
            width: row.width !== null && row.width < LOOP_WIDTH ? LOOP_SMALL_WIDTH : LOOP_WIDTH,
            fps: LOOP_FPS,
            quality: LOOP_QUALITY,
        };
        const id = randomBase62(20, this.d.randomBytes);
        let r: Reply;
        try {
            r = await this.d.webp.createFromUpload(ownerOf(itemId), params, () => source.get(row.r2_key), { id });
        } catch (e) {
            return this.retryOrGiveUp(itemId, attempts, String(e));
        }
        if (r.status === 202) {
            await this.d.storage.put(LOOP_PREFIX + itemId, {
                attempts,
                at: this.d.now(),
                job: id,
                startedAt: this.d.now(),
            } satisfies LoopJob);
            return;
        }
        const code = (r.body as { error?: { code?: string } }).error?.code ?? `status ${r.status}`;
        if (r.status === 429) {
            // someone else holds the helper: not an attempt
            const busy = (rec.busy ?? 0) + 1;
            if (busy >= LOOP_BUSY_LIMIT) return this.giveUp(itemId, "the helper stayed busy");
            await this.d.storage.put(LOOP_PREFIX + itemId, { attempts: rec.attempts, busy, at: this.d.now() } satisfies LoopJob);
            return;
        }
        return this.retryOrGiveUp(itemId, attempts, code);
    }

    private async collect(itemId: string, rec: LoopJob): Promise<void> {
        const job = rec.job!;
        let r: Reply;
        try {
            r = await this.d.webp.status(ownerOf(itemId), job, 0);
        } catch (e) {
            if (this.d.now() - (rec.startedAt ?? 0) > LOOP_JOB_MS) return this.retryOrGiveUp(itemId, rec.attempts, "job timed out");
            return;
        }
        const body = r.body as { status?: string; url?: string; bytes?: number; error?: { code?: string } };
        if (r.status === 200 && body.status === "pending") {
            if (this.d.now() - (rec.startedAt ?? 0) > LOOP_JOB_MS) return this.retryOrGiveUp(itemId, rec.attempts, "job timed out");
            return;
        }
        if (r.status === 200 && body.status === "success" && typeof body.url === "string") {
            const name = body.url.startsWith(this.base()) ? body.url.slice(this.base().length) : null;
            try {
                await this.d.db
                    .prepare(
                        `INSERT INTO media_loops (item_id, url, r2_key, bytes, made_at) VALUES (?1, ?2, ?3, ?4, ?5)
                         ON CONFLICT(item_id) DO UPDATE SET url = excluded.url, r2_key = excluded.r2_key, bytes = excluded.bytes, made_at = excluded.made_at, tried_at = NULL`,
                    )
                    .bind(itemId, body.url, name, body.bytes ?? null, this.d.now())
                    .run();
            } catch (e) {
                // not recorded: the object has no owner, and the video is tried again
                if (name) await this.d.mediaDelete?.(name).catch(() => {});
                return this.retryOrGiveUp(itemId, rec.attempts, `D1: ${String(e)}`);
            }
            return this.drop(itemId);
        }
        if (r.status === 200 && body.status === "error") {
            const code = body.error?.code ?? "error";
            // the helper refused the file itself: another try will not help
            if (code === "error.webp.bad_source" || code === "error.webp.too_large" || code === "error.webp.too_long") {
                return this.giveUp(itemId, code);
            }
            return this.retryOrGiveUp(itemId, rec.attempts, code);
        }
        // 404 (the record aged out) or anything else: try again
        return this.retryOrGiveUp(itemId, rec.attempts, `status ${r.status}`);
    }
}
