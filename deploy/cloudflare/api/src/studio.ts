// cobalt studio (see ../STUDIO-CONTRACT.md): everything except HTTP glue for the
// /studio routes, free of Cloudflare imports so it runs under plain node in the
// tests. Two halves:
//
//  - the Worker half (studio-edge.ts) reads D1 and R2 directly: the source video
//    (Range/206) and the status of sessions that are not saving. A session
//    that IS saving is answered by the Durable Object (GET /studio/<sid>/advance),
//    so every client poll goes through the DO and moves the save forward;
//  - the Durable Object half (StudioService, below) saves a link into R2 (poll
//    driven, the same pattern as WebP jobs) and starts / polls renders. It
//    streams video bytes between the container helper (helper/server.js, port
//    9100) and R2 and never holds a video in memory.
//
// Why poll-driven: a background save started with ctx.waitUntil() from the POST
// stopped when the response ended (measured 2026-09-30: the row stayed
// "saving", nothing reached R2). Requests to the DO are what keep it running.
//
// Sessions live in D1 (studio_sessions / studio_renders, migration 0003). The
// session id is a capability: the routes that use it need no API key.

import { KV, Quality, WebpParams, WebpService, num, randomBase62, serviceFromUrl } from "./webp";
import { KEY_ID_HEADER } from "./headers";
import { STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "./gate";
import { SERVICE_KEY_ID, insertMediaItem, mediaNameFromUrl, pageLink } from "./library";

export const SID_LENGTH = 22;
export const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
// A session still "saving" whose last advance attempt (a client poll, or the
// kick-off at creation) is older than this lost its save (nobody polled, or the
// Durable Object was evicted): the next look at it turns it into an error.
export const SAVING_STUCK_MS = 10 * 60 * 1000;
// A save waits this long for the helper (one job at a time) before giving up.
export const BUSY_WAIT_MS = 120_000;
export const BUSY_RETRY_MS = 2000;
// Ceiling for one helper download, safely inside SAVING_STUCK_MS.
export const SAVE_BUDGET_MS = 8 * 60 * 1000;
// A container that cannot be started / reached for this long is unavailable.
export const UNAVAILABLE_AFTER_MS = 30_000;
// The helper forgets a fetch when the container restarts; the save is started
// again this many times in all before it is error.studio.save_lost.
export const MAX_FETCH_ATTEMPTS = 3;
// POST /studio waits at most this long for the helper to accept the fetch.
export const KICK_MS = 4000;
export const MAX_SOURCE_BYTES = 200 * 1024 * 1024;
export const MAX_BODY_BYTES = 8192;
export const MAX_STUDIO_WAIT_SECONDS = 25;
export const POLL_INTERVAL_MS = 1000;
// A save lock held longer than this is assumed abandoned (see advancingSince).
export const LOCK_STALE_MS = 60_000;
// An encode the DO started is assumed to be over after this (helper budget 240 s).
export const ENCODE_ASSUMED_MS = 5 * 60 * 1000;

export const MIN_RENDER_SECONDS = 0.5;
export const MAX_RENDER_SECONDS = 10;
export const DURATION_SLACK = 0.05;
export const RENDER_FPS = 15;
export const RENDER_WIDTHS = [320, 480] as const;

export const CORS_METHODS = "GET, POST, OPTIONS";
export const CORS_HEADERS = "content-type, range";
export const CORS_EXPOSE = "content-range, content-length, accept-ranges";

export type StudioReply = { status: number; body: unknown };

export const studioErr = (status: number, code: string): StudioReply => ({
    status,
    body: { status: "error", error: { code } },
});

export const mintSid = (rb?: (n: number) => Uint8Array) =>
    randomBase62(SID_LENGTH, rb);

// --- D1 rows -------------------------------------------------------------------

export type SessionRow = {
    id: string;
    key_id: string | null;
    link: string | null;
    service: string | null;
    title: string | null;
    status: "saving" | "ready" | "error";
    error_code: string | null;
    r2_key: string | null;
    content_type: string | null;
    bytes: number | null;
    duration: number | null;
    width: number | null;
    height: number | null;
    created_at: number;
    expires_at: number;
};

export type RenderRow = {
    id: string;
    session_id: string;
    status: "pending" | "success" | "error";
    error_code: string | null;
    url: string | null;
    start: number | null;
    length: number | null;
    width: number | null;
    quality: string | null;
    bytes: number | null;
    out_width: number | null;
    out_height: number | null;
    seconds: number | null;
    created_at: number;
};

export async function getSession(db: D1Database, sid: string): Promise<SessionRow | null> {
    const res = await db
        .prepare("SELECT * FROM studio_sessions WHERE id = ?1")
        .bind(sid)
        .all<SessionRow>();
    return res.results[0] ?? null;
}

export async function listSuccessfulRenders(db: D1Database, sid: string): Promise<RenderRow[]> {
    const res = await db
        .prepare(
            "SELECT * FROM studio_renders WHERE session_id = ?1 AND status = 'success' ORDER BY created_at DESC, id DESC LIMIT 100",
        )
        .bind(sid)
        .all<RenderRow>();
    return res.results;
}

export async function getRender(db: D1Database, sid: string, job: string): Promise<RenderRow | null> {
    const res = await db
        .prepare("SELECT * FROM studio_renders WHERE id = ?1 AND session_id = ?2")
        .bind(job, sid)
        .all<RenderRow>();
    return res.results[0] ?? null;
}

export function sessionBody(row: SessionRow, renders: RenderRow[]) {
    return {
        status: row.status,
        id: row.id,
        link: row.link,
        service: row.service,
        title: row.title ?? null,
        duration: row.duration ?? null,
        width: row.width ?? null,
        height: row.height ?? null,
        bytes: row.bytes ?? null,
        created_at: row.created_at,
        expires_at: row.expires_at,
        error: row.error_code ? { code: row.error_code } : null,
        renders: renders.map((r) => ({
            id: r.id,
            url: r.url,
            start: r.start,
            length: r.length,
            width: r.width,
            quality: r.quality,
            bytes: r.bytes,
            created_at: r.created_at,
        })),
    };
}

// ?wait=N for the studio long-polls: absent or junk = 0 (answer at once),
// clamped to 0..25.
export function parseStudioWait(raw: string | null): number {
    if (raw === null || raw.trim() === "") return 0;
    const n = Number(raw);
    if (!Number.isFinite(n)) return 0;
    return Math.min(MAX_STUDIO_WAIT_SECONDS, Math.max(0, n));
}

// --- Range ---------------------------------------------------------------------

export type RangeResult =
    | { kind: "full" }
    | { kind: "partial"; offset: number; length: number }
    | { kind: "unsatisfiable" };

// Single-range `bytes=` requests only. A missing header, another unit or a
// multi-range request is served in full (200, allowed by the RFC); a
// syntactically invalid or unsatisfiable single range is a 416.
//   bytes=0-      from the offset to the end     bytes=a-b   clamped to the size
//   bytes=-N      the last N bytes (N >= size = the whole file)
export function parseRange(header: string | null, size: number): RangeResult {
    if (header === null || header.trim() === "") return { kind: "full" };
    const m = /^\s*bytes\s*=\s*(.*)$/i.exec(header);
    if (!m) return { kind: "full" };
    const spec = m[1].trim();
    if (spec.includes(",")) return { kind: "full" };

    const parts = /^(\d*)-(\d*)$/.exec(spec);
    if (!parts) return { kind: "unsatisfiable" };
    const [, a, b] = parts;
    if (a === "" && b === "") return { kind: "unsatisfiable" };
    if (size <= 0) return { kind: "unsatisfiable" };

    if (a === "") {
        const n = Number(b);
        if (n === 0) return { kind: "unsatisfiable" };
        if (!Number.isSafeInteger(n) || n >= size) {
            return { kind: "partial", offset: 0, length: size };
        }
        return { kind: "partial", offset: size - n, length: n };
    }

    const start = Number(a);
    if (!Number.isSafeInteger(start) || start >= size) return { kind: "unsatisfiable" };
    let end = size - 1;
    if (b !== "") {
        const e = Number(b);
        if (Number.isSafeInteger(e)) {
            if (e < start) return { kind: "unsatisfiable" };
            end = Math.min(e, size - 1);
        }
    }
    return { kind: "partial", offset: start, length: end - start + 1 };
}

// --- render parameters --------------------------------------------------------------

export type RenderParams = {
    start: number;
    length: number;
    // what the helper is asked for (320 | 480; it never upscales)
    width: 320 | 480;
    quality: Quality;
    // what is recorded: the requested width, never above the source's
    effectiveWidth: number;
};

export type RenderCheck =
    | { ok: true; params: RenderParams }
    | { ok: false; status: 400; code: string };

const invalid = (code = "error.webp.invalid_params"): RenderCheck => ({
    ok: false,
    status: 400,
    code,
});

// Contract limits: length 0.5-10 (over is too_long), start >= 0, start + length
// <= duration + 0.05, width 320 | 480 (default 480), quality low | med | high
// (default med). Numbers may be numeric strings. `start` and `length` are required.
export function validateRender(
    body: unknown,
    source: { duration: number | null; width: number | null },
): RenderCheck {
    if (typeof body !== "object" || body === null || Array.isArray(body)) return invalid();
    const b = body as Record<string, unknown>;

    const start = num(b.start, undefined);
    const length = num(b.length, undefined);
    if (start === undefined || start === null || length === undefined || length === null) {
        return invalid();
    }
    if (start < 0 || start > 3600) return invalid();
    if (length > MAX_RENDER_SECONDS) return invalid("error.webp.too_long");
    if (length < MIN_RENDER_SECONDS) return invalid();
    if (source.duration !== null && start + length > source.duration + DURATION_SLACK) {
        return invalid();
    }

    const width = num(b.width, 480);
    if (width !== 320 && width !== 480) return invalid();

    let quality: Quality = "med";
    if (b.quality !== undefined && b.quality !== null && b.quality !== "") {
        if (b.quality !== "low" && b.quality !== "med" && b.quality !== "high") return invalid();
        quality = b.quality;
    }

    const effectiveWidth = source.width ? Math.min(width, source.width) : width;
    return { ok: true, params: { start, length, width, quality, effectiveWidth } };
}

/** First http(s) link of a normalised `url` field, or null (=> no_link). */
export function linkFrom(u: unknown): string | null {
    if (typeof u !== "string") return null;
    const t = u.trim();
    if (t.length === 0 || t.length > 2048 || !/^https?:\/\/\S+$/i.test(t)) return null;
    try {
        const parsed = new URL(t);
        return parsed.protocol === "http:" || parsed.protocol === "https:" ? t : null;
    } catch {
        return null;
    }
}

// --- the Durable Object half ------------------------------------------------------

export interface OriginalsBucket {
    put(
        key: string,
        value: ReadableStream,
        options: {
            httpMetadata: { contentType: string };
            customMetadata: Record<string, string>;
        },
    ): Promise<{ size: number } | null>;
    get(
        key: string,
        options?: { range?: { offset: number; length?: number } },
    ): Promise<{
        body: ReadableStream;
        size: number;
        httpMetadata?: { contentType?: string };
    } | null>;
    delete(key: string): Promise<void>;
}

export type StudioDeps = {
    db: D1Database;
    storage: KV;
    originals: OriginalsBucket;
    // Shares the helper, the job records and the R2 upload of finished WebPs.
    webp: WebpService;
    // Public origin of the studio page (CORS_URL), no trailing slash needed.
    webBaseUrl: string;
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    randomBytes?: (n: number) => Uint8Array;
    ensureRunning: () => Promise<void>;
    helper: (path: string, init?: RequestInit) => Promise<Response>;
    // Wraps a stream so R2 accepts it (FixedLengthStream in production).
    fixedLength: (stream: ReadableStream, length: number) => ReadableStream;
    // How long POST /studio waits for the helper to accept the fetch (KICK_MS).
    kickMs?: number;
    // Our own ceiling on a helper call. The helper's AbortSignal.timeout is not
    // honoured for containerFetch inside the DO: a hung call stalled a poll for
    // 5.5 min live (2026-10-01).
    helperTimeoutMs?: number;
    // The same for the probe of an adopted upload, whose call carries the whole
    // video into the helper (default 50 s, inside LOCK_STALE_MS).
    probeTimeoutMs?: number;
    // Renews the container's sleepAfter timer (long streams make no helper calls).
    renew?: () => void;
};

type FetchDone = {
    status: "done";
    bytes: number;
    contentType?: string;
    ext?: string;
    duration?: number | null;
    width?: number | null;
    height?: number | null;
    title?: string | null;
};

const finite = (v: unknown): number | null =>
    typeof v === "number" && Number.isFinite(v) ? v : null;

// What the DO remembers about a save in flight (`save:<sid>`).
type SaveRecord = {
    // "probing": an adopted upload (POST /library/adopt) being measured by the helper
    phase: "starting" | "fetching" | "probing";
    // when the current helper fetch was accepted (its download budget runs from here)
    startedAt: number;
    // helper fetches accepted so far (a container restart loses the fetch)
    attempts: number;
    // last advance attempt (a poll, or the kick-off at creation)
    lastAdvance: number;
    // first consecutive busy (429) answer / first consecutive unreachable answer
    busySince?: number;
    missSince?: number;
    // old records (before the poll-driven save) only had this
    createdAt?: number;
};

export class StudioService {
    // sid -> the advance step running right now (in memory only): two polls of
    // the same session never advance it at once. The second just waits for it.
    private advancing = new Map<string, Promise<number>>();
    // When each lock was taken: a lock older than LOCK_STALE_MS is treated as
    // abandoned, so one hung helper call can never block a save for good.
    private advancingSince = new Map<string, number>();

    // Every helper call goes through here: rejects if no response headers
    // arrive within helperTimeoutMs (default 20 s), so a hung call surfaces
    // as a normal miss instead of freezing the save.
    private callHelper(path: string, init?: RequestInit, timeoutMs?: number): Promise<Response> {
        const ms = timeoutMs ?? this.d.helperTimeoutMs ?? 20_000;
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(new Error(`helper ${path} timed out after ${ms} ms`)), ms);
        });
        return Promise.race([this.d.helper(path, init), timeout]).finally(() => {
            if (timer !== undefined) clearTimeout(timer);
        });
    }
    // helper job id -> when this DO started it; used only for the busy answer.
    private encodes = new Map<string, number>();

    constructor(private d: StudioDeps) {}

    private async readJson(res: Response): Promise<any | null> {
        try {
            return await res.json();
        } catch {
            return null;
        }
    }

    private encoding(): boolean {
        const now = this.d.now();
        for (const [job, at] of this.encodes) {
            if (now - at > ENCODE_ASSUMED_MS) this.encodes.delete(job);
        }
        return this.encodes.size > 0;
    }

    // ---- POST /studio ------------------------------------------------------------

    async create(keyId: string, rawBody: string): Promise<StudioReply> {
        let link: string | null = null;
        try {
            if (rawBody.length <= MAX_BODY_BYTES) {
                const parsed = JSON.parse(rawBody);
                if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
                    link = linkFrom((parsed as { url?: unknown }).url);
                }
            }
        } catch {
            // no link
        }
        if (!link) return studioErr(400, "error.studio.no_link");

        await this.reapOrphans();
        if ((await this.saveActive()) || this.encoding()) {
            return studioErr(429, "error.studio.busy");
        }

        const sid = mintSid(this.d.randomBytes);
        const now = this.d.now();
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, 'saving', ?5, ?6)",
                )
                .bind(sid, keyId, link, serviceFromUrl(link), now, now + SESSION_TTL_MS)
                .run();
        } catch {
            return studioErr(503, "error.api.generic");
        }
        try {
            const rec: SaveRecord = { phase: "starting", startedAt: now, attempts: 0, lastAdvance: now };
            await this.d.storage.put(`save:${sid}`, rec);
        } catch {
            // advance() starts the save from the D1 row when there is no record
        }

        // Nothing runs after this response: the save only moves while the
        // studio page polls GET /studio/<sid> (-> advance). Try once now to have
        // the helper accept the fetch, but never hold the 201 for long.
        await this.kick(sid);

        const base = this.d.webBaseUrl.replace(/\/+$/, "");
        return {
            status: 201,
            body: { status: "success", id: sid, url: `${base}/studio/${sid}` },
        };
    }

    // One advance step under the lock, bounded by KICK_MS. If it overruns, it
    // keeps going (still holding the lock) and the 201 is sent anyway.
    // The kick runs OUTSIDE the per-session lock: a kicked step still running
    // after the 201 (waking the container outlasts KICK_MS) hung with the lock
    // held, and every later poll just waited on it (live, 2026-10-01). Unlocked,
    // a hung kick blocks nothing; the helper treats a repeated /fetch for the
    // same id as the same job.
    private async kick(sid: string): Promise<void> {
        const p = this.step(sid).catch(() => POLL_INTERVAL_MS);
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<void>((resolve) => {
            timer = setTimeout(resolve, this.d.kickMs ?? KICK_MS);
        });
        try {
            await Promise.race([p.then(() => {}), timeout]);
        } finally {
            if (timer !== undefined) clearTimeout(timer);
        }
    }

    // Runs one step for the session and holds the per-session lock meanwhile.
    // Never rejects.
    private locked(sid: string): Promise<number> {
        const p: Promise<number> = this.step(sid)
            .catch(() => POLL_INTERVAL_MS)
            .finally(() => {
                if (this.advancing.get(sid) === p) {
                    this.advancing.delete(sid);
                    this.advancingSince.delete(sid);
                }
            });
        this.advancing.set(sid, p);
        this.advancingSince.set(sid, this.d.now());
        return p;
    }

    // Is any save in flight (the helper does one job at a time)?
    private async saveActive(): Promise<boolean> {
        const records = await this.d.storage.list<unknown>({ prefix: "save:" });
        return records.size > 0;
    }

    // Saves nobody has advanced for 10 minutes (the page always polls while
    // saving, so nobody is looking): fail them now, which also frees the helper
    // for the next save / render.
    async reapOrphans(): Promise<void> {
        const records = await this.d.storage.list<SaveRecord>({ prefix: "save:" });
        for (const [key, rec] of records) {
            const sid = key.slice("save:".length);
            if (this.advancing.has(sid)) continue;
            const last = rec?.lastAdvance ?? rec?.createdAt ?? 0;
            if (this.d.now() - last > SAVING_STUCK_MS) await this.fail(sid, "error.studio.save_lost");
        }
    }

    private async markError(sid: string, code: string): Promise<void> {
        try {
            await this.d.db
                .prepare(
                    "UPDATE studio_sessions SET status = 'error', error_code = ?1 WHERE id = ?2 AND status = 'saving'",
                )
                .bind(code, sid)
                .run();
        } catch (e) {
            console.error("[studio] could not record save error", sid, String(e));
        }
    }

    private async dropHelperCopy(sid: string): Promise<void> {
        try {
            await this.callHelper(`/fetch/${sid}`, { method: "DELETE" });
        } catch {
            // the helper expires finished fetches on its own
        }
    }

    // Ends the save with an error: the row, the helper copy and the record.
    private async fail(sid: string, code: string): Promise<number> {
        await this.markError(sid, code);
        await this.dropHelperCopy(sid);
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        return POLL_INTERVAL_MS;
    }

    // ---- GET /studio/<sid>/advance?wait=N (internal, called by the Worker) ---------------

    private async sessionReply(row: SessionRow): Promise<StudioReply> {
        try {
            const renders = row.status === "ready" ? await listSuccessfulRenders(this.d.db, row.id) : [];
            return { status: 200, body: sessionBody(row, renders) };
        } catch {
            return studioErr(503, "error.api.generic");
        }
    }

    // Moves a saving session forward for up to `waitSeconds` and answers with the
    // session exactly as GET /studio/<sid> does. Every client poll of a saving
    // session lands here (the Worker forwards it), which is what keeps the
    // Durable Object, and so the save, running.
    async advance(sid: string, waitSeconds: number): Promise<StudioReply> {
        const deadline = this.d.now() + waitSeconds * 1000;
        for (;;) {
            const found = await this.lookup(sid);
            if ("reply" in found) return found.reply;
            const row = found.row;
            if (row.status !== "saving") return this.sessionReply(row);

            let running = this.advancing.get(sid);
            if (running && this.d.now() - (this.advancingSince.get(sid) ?? 0) > LOCK_STALE_MS) {
                console.error("[studio] dropping stale save lock", sid);
                this.advancing.delete(sid);
                this.advancingSince.delete(sid);
                running = undefined;
            }
            if (running) {
                // Another poll is advancing it: wait for that, read D1 again.
                const remaining = deadline - this.d.now();
                if (remaining <= 0) return this.sessionReply(row);
                await Promise.race([running, this.d.sleep(Math.min(remaining, POLL_INTERVAL_MS))]);
                continue;
            }
            const pause = await this.locked(sid);
            if (this.d.now() >= deadline) {
                const after = await this.lookup(sid);
                return "reply" in after ? after.reply : this.sessionReply(after.row);
            }
            await this.d.sleep(Math.min(pause, Math.max(0, deadline - this.d.now())));
        }
    }

    // ---- one step of the save --------------------------------------------------------

    // Returns how long to wait before the next step. Never rejects.
    private async step(sid: string): Promise<number> {
        const now = this.d.now();
        let row: SessionRow | null;
        let rec: SaveRecord | undefined;
        try {
            row = await getSession(this.d.db, sid);
            rec = await this.d.storage.get<SaveRecord>(`save:${sid}`);
        } catch {
            return POLL_INTERVAL_MS; // D1 / storage blip: the next poll retries
        }
        if (!row || row.status !== "saving") {
            await this.d.storage.delete(`save:${sid}`).catch(() => {});
            return POLL_INTERVAL_MS;
        }

        // A save nobody advanced for 10 minutes is lost. With no record at all
        // (DO storage lost, or a session from before this scheme) the row's age
        // stands in for it.
        const last = rec?.lastAdvance ?? rec?.createdAt ?? row.created_at;
        if (now - last > SAVING_STUCK_MS) return await this.fail(sid, "error.studio.save_lost");

        const cur: SaveRecord = {
            startedAt: now,
            attempts: 0,
            ...rec,
            // an adopted upload whose record was lost still has to be probed,
            // never fetched (its link is not a page)
            phase:
                rec?.phase === "fetching" || rec?.phase === "probing"
                    ? rec.phase
                    : row.service === "upload"
                      ? "probing"
                      : "starting",
            lastAdvance: now,
        };
        try {
            await this.d.storage.put(`save:${sid}`, cur);
            if (cur.phase === "probing") return await this.probeStep(sid, row, cur);
            return cur.phase === "starting"
                ? await this.startFetch(sid, row, cur)
                : await this.pollFetch(sid, row, cur);
        } catch (e) {
            console.error("[studio] save step failed", sid, String(e));
            return await this.fail(sid, "error.api.generic");
        }
    }

    // The helper (or the container) did not answer: keep trying for 30 s.
    private async miss(sid: string, rec: SaveRecord): Promise<number> {
        const since = rec.missSince ?? this.d.now();
        if (this.d.now() - since >= UNAVAILABLE_AFTER_MS) {
            return await this.fail(sid, "error.studio.unavailable");
        }
        await this.d.storage.put(`save:${sid}`, { ...rec, missSince: since });
        return POLL_INTERVAL_MS;
    }

    private async startFetch(sid: string, row: SessionRow, rec: SaveRecord): Promise<number> {
        try {
            await this.d.ensureRunning();
        } catch {
            return await this.miss(sid, rec);
        }
        let res: Response;
        try {
            res = await this.callHelper("/fetch", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ id: sid, url: row.link }),
            });
        } catch {
            return await this.miss(sid, rec);
        }

        let accepted = res.status === 202;
        if (res.status === 429) {
            // Busy: either another job, or this very fetch (an earlier accept
            // whose answer got lost). The helper knows our id.
            try {
                accepted = (await this.callHelper(`/fetch/${sid}`)).status === 200;
            } catch {
                accepted = false;
            }
            if (!accepted) {
                const since = rec.busySince ?? this.d.now();
                if (this.d.now() - since >= BUSY_WAIT_MS) return await this.fail(sid, "error.studio.busy");
                await this.d.storage.put(`save:${sid}`, { ...rec, busySince: since, missSince: undefined });
                return BUSY_RETRY_MS;
            }
        } else if (!accepted) {
            const body = await this.readJson(res);
            const code = body?.error?.code;
            return await this.fail(sid, typeof code === "string" ? code : "error.studio.unavailable");
        }

        await this.d.storage.put(`save:${sid}`, {
            ...rec,
            phase: "fetching",
            startedAt: this.d.now(),
            attempts: rec.attempts + 1,
            busySince: undefined,
            missSince: undefined,
        } satisfies SaveRecord);
        return POLL_INTERVAL_MS;
    }

    private async pollFetch(sid: string, row: SessionRow, rec: SaveRecord): Promise<number> {
        if (this.d.now() - rec.startedAt > SAVE_BUDGET_MS) return await this.fail(sid, "error.webp.timeout");

        let res: Response | null = null;
        try {
            res = await this.callHelper(`/fetch/${sid}`);
        } catch {
            // The container may have slept or died: wake it so the next poll
            // finds out whether the fetch survived.
            await this.d.ensureRunning().catch(() => {});
            return await this.miss(sid, rec);
        }
        if (res.status === 404) {
            // The container restarted since the fetch was accepted: start it again.
            if (rec.attempts >= MAX_FETCH_ATTEMPTS) return await this.fail(sid, "error.studio.save_lost");
            await this.d.storage.put(`save:${sid}`, { ...rec, phase: "starting", missSince: undefined });
            return 0;
        }
        const body = await this.readJson(res);
        if (!body || typeof body.status !== "string") return await this.miss(sid, rec);
        if (body.status === "error") {
            const code = body.error?.code;
            return await this.fail(sid, typeof code === "string" ? code : "error.studio.unavailable");
        }
        if (body.status !== "done") {
            if (rec.missSince !== undefined) await this.d.storage.put(`save:${sid}`, { ...rec, missSince: undefined });
            return POLL_INTERVAL_MS;
        }
        return await this.finalize(sid, row, body as FetchDone);
    }

    // The helper has the file: stream it into R2 (within this request), mark the
    // row ready and drop the helper copy.
    private async finalize(sid: string, row: SessionRow, done: FetchDone): Promise<number> {
        const link = row.link ?? "";
        const keyId = row.key_id ?? "";
        const bytes = finite(done.bytes);
        if (bytes === null || bytes <= 0) return await this.fail(sid, "error.studio.unavailable");
        if (bytes > MAX_SOURCE_BYTES) return await this.fail(sid, "error.studio.too_large");
        const ext = typeof done.ext === "string" && /^[a-z0-9]{2,4}$/.test(done.ext) ? done.ext : "mp4";
        const contentType =
            typeof done.contentType === "string" && /^video\/[a-z0-9.+-]+$/i.test(done.contentType)
                ? done.contentType
                : "video/mp4";
        const key = `originals/${sid}.${ext}`;

        // helper -> R2 as a stream: nothing is buffered in the DO.
        let stored: { size: number } | null;
        const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
        try {
            this.d.renew?.();
            const file = await this.callHelper(`/fetch/${sid}/file`);
            const declared = Number(file.headers.get("content-length"));
            if (!file.ok || !file.body || declared !== bytes) {
                await file.body?.cancel().catch(() => {});
                return await this.fail(sid, "error.studio.storage");
            }
            stored = await this.d.originals.put(key, this.d.fixedLength(file.body, bytes), {
                httpMetadata: { contentType },
                customMetadata: {
                    keyId,
                    source: link.slice(0, 1000),
                    sessionId: sid,
                    createdAt: String(this.d.now()),
                },
            });
        } catch (e) {
            console.error("[studio] R2 put failed", sid, String(e));
            return await this.fail(sid, "error.studio.storage");
        } finally {
            if (keepAwake !== undefined) clearInterval(keepAwake);
        }

        const title =
            typeof done.title === "string" && done.title.trim() ? done.title.trim().slice(0, 200) : null;
        const res = await this.d.db
            .prepare(
                "UPDATE studio_sessions SET status = 'ready', error_code = NULL, r2_key = ?1, content_type = ?2, bytes = ?3, duration = ?4, width = ?5, height = ?6, title = ?7 WHERE id = ?8 AND status = 'saving'",
            )
            .bind(
                key,
                contentType,
                stored?.size ?? bytes,
                finite(done.duration),
                finite(done.width),
                finite(done.height),
                title,
                sid,
            )
            .run();
        if (Number(res.meta?.changes ?? 0) === 0) {
            // Marked lost meanwhile: do not keep an object nothing points at.
            await this.d.originals.delete(key).catch(() => {});
        } else {
            // the private original is now a library item (an adopted upload is
            // not: it already is the upload's item)
            await insertMediaItem(this.d.db, {
                kind: "private",
                source: "saved",
                bucket: "originals",
                r2_key: key,
                name: title ?? `${sid}.${ext}`,
                content_type: contentType,
                bytes: stored?.size ?? bytes,
                width: finite(done.width),
                height: finite(done.height),
                duration: finite(done.duration),
                link: pageLink(link),
                session_id: sid,
                key_id: keyId || null,
                created_at: this.d.now(),
            });
        }
        await this.dropHelperCopy(sid);
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        return POLL_INTERVAL_MS;
    }

    // ---- POST /library/adopt ----------------------------------------------------------

    // Makes a studio session out of an upload that already sits in the private
    // bucket (no cobalt fetch). The session starts "saving" in phase "probing":
    // the first poll of GET /studio/<sid> streams the object into the helper
    // (POST /probe) and the row turns ready with duration/width/height. Nothing
    // runs after this response, so there is no kick here either (a step started
    // now would die with the response, taking its upload with it).
    async adopt(keyId: string, rawBody: string): Promise<StudioReply> {
        const invalid = () => studioErr(400, "error.studio.invalid_params");
        let b: Record<string, unknown>;
        try {
            if (rawBody.length > MAX_BODY_BYTES) return invalid();
            const parsed = JSON.parse(rawBody);
            if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return invalid();
            b = parsed as Record<string, unknown>;
        } catch {
            return invalid();
        }

        const { r2_key: r2Key, name, content_type: rawType, bytes, item_id: itemId } = b;
        // Uploads AND saved studio originals: the library's "open in studio" on a
        // saved original sent originals/<sid>.<ext> and got invalid_params
        // (live, 2026-10-02).
        if (
            typeof r2Key !== "string" ||
            !/^(?:uploads\/[A-Za-z0-9]{1,64}|originals\/[A-Za-z0-9]{22})\.[a-z0-9]{1,8}$/.test(r2Key)
        ) {
            return invalid();
        }
        if (typeof name !== "string" || name.trim() === "" || name.length > 200) return invalid();
        if (typeof itemId !== "string" || !/^[A-Za-z0-9]{1,64}$/.test(itemId)) return invalid();
        if (typeof rawType !== "string") return invalid();
        const contentType = rawType.trim().toLowerCase();
        if (!/^video\/[a-z0-9.+-]+$/.test(contentType) && contentType !== "image/gif") {
            return studioErr(400, "error.studio.not_video");
        }
        if (typeof bytes !== "number" || !Number.isInteger(bytes) || bytes <= 0) return invalid();
        if (bytes > MAX_SOURCE_BYTES) return studioErr(413, "error.studio.too_large");

        await this.reapOrphans();
        if ((await this.saveActive()) || this.encoding()) {
            return studioErr(429, "error.studio.busy");
        }

        const sid = mintSid(this.d.randomBytes);
        const now = this.d.now();
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, created_at, expires_at) VALUES (?1, ?2, ?3, 'upload', ?4, 'saving', ?5, ?6, ?7, ?8, ?9)",
                )
                .bind(sid, keyId, `upload:${itemId}`, name.trim(), r2Key, contentType, bytes, now, now + SESSION_TTL_MS)
                .run();
        } catch {
            return studioErr(503, "error.api.generic");
        }
        try {
            const rec: SaveRecord = { phase: "probing", startedAt: now, attempts: 0, lastAdvance: now };
            await this.d.storage.put(`save:${sid}`, rec);
        } catch {
            // step() recognises an upload session without a record
        }

        const base = this.d.webBaseUrl.replace(/\/+$/, "");
        return {
            status: 201,
            body: { status: "success", id: sid, url: `${base}/studio/${sid}` },
        };
    }

    // One probe attempt of an adopted upload: stream the stored object into the
    // helper, which measures it and answers {duration,width,height}.
    private async probeStep(sid: string, row: SessionRow, rec: SaveRecord): Promise<number> {
        const key = row.r2_key;
        if (!key) return await this.fail(sid, "error.studio.storage");
        try {
            await this.d.ensureRunning();
        } catch {
            return await this.miss(sid, rec);
        }

        let obj: Awaited<ReturnType<OriginalsBucket["get"]>>;
        try {
            obj = await this.d.originals.get(key);
        } catch (e) {
            console.error("[studio] probe: R2 get failed", sid, String(e));
            return await this.fail(sid, "error.studio.storage");
        }
        if (!obj) return await this.fail(sid, "error.studio.storage");

        let res: Response;
        const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
        try {
            this.d.renew?.();
            res = await this.callHelper(
                `/probe?id=${sid}`,
                {
                    method: "POST",
                    headers: {
                        "content-type": "application/octet-stream",
                        "content-length": String(obj.size),
                    },
                    body: obj.body,
                },
                this.d.probeTimeoutMs ?? 50_000,
            );
        } catch {
            await obj.body.cancel().catch(() => {});
            await this.d.ensureRunning().catch(() => {});
            return await this.miss(sid, rec);
        } finally {
            if (keepAwake !== undefined) clearInterval(keepAwake);
        }

        if (res.status === 429) {
            // the helper is doing something else (one job at a time)
            await obj.body.cancel().catch(() => {});
            const since = rec.busySince ?? this.d.now();
            if (this.d.now() - since >= BUSY_WAIT_MS) return await this.fail(sid, "error.studio.busy");
            await this.d.storage.put(`save:${sid}`, { ...rec, busySince: since, missSince: undefined });
            return BUSY_RETRY_MS;
        }

        const body = await this.readJson(res);
        if (res.status !== 200) {
            await obj.body.cancel().catch(() => {});
            const code = body?.error?.code;
            // the helper refused this file for good (not a video, too large)
            if (res.status < 500 && typeof code === "string") return await this.fail(sid, code);
            return await this.miss(sid, rec);
        }
        const width = finite(body?.width);
        const height = finite(body?.height);
        if (width === null || height === null) return await this.fail(sid, "error.studio.not_video");

        // (0 changes = marked lost meanwhile; the upload is not ours to delete)
        await this.d.db
            .prepare(
                "UPDATE studio_sessions SET status = 'ready', error_code = NULL, duration = ?1, width = ?2, height = ?3, bytes = ?4 WHERE id = ?5 AND status = 'saving'",
            )
            .bind(finite(body?.duration), width, height, obj.size, sid)
            .run();
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        return POLL_INTERVAL_MS;
    }

    // ---- renders ----------------------------------------------------------------------

    // Session lookups shared by both render routes.
    private async lookup(
        sid: string,
    ): Promise<{ row: SessionRow } | { reply: StudioReply }> {
        let row: SessionRow | null;
        try {
            row = await getSession(this.d.db, sid);
        } catch {
            return { reply: studioErr(503, "error.api.generic") };
        }
        if (!row) return { reply: studioErr(404, "error.studio.not_found") };
        if (this.d.now() > row.expires_at) return { reply: studioErr(410, "error.studio.expired") };
        return { row };
    }

    async render(sid: string, rawBody: string): Promise<StudioReply> {
        const found = await this.lookup(sid);
        if ("reply" in found) return found.reply;
        const row = found.row;
        if (row.status !== "ready" || !row.r2_key) {
            return studioErr(409, "error.studio.not_ready");
        }

        let parsed: unknown;
        try {
            if (rawBody.length > MAX_BODY_BYTES) throw new Error("too large");
            parsed = JSON.parse(rawBody);
        } catch {
            return studioErr(400, "error.webp.invalid_params");
        }
        const check = validateRender(parsed, { duration: row.duration, width: row.width });
        if (!check.ok) return studioErr(check.status, check.code);
        const p = check.params;

        await this.reapOrphans();
        // a save is running: the helper is not free (one job at a time)
        if (await this.saveActive()) return studioErr(429, "error.webp.busy");

        const r2Key = row.r2_key;
        const params: WebpParams = {
            url: row.link ?? "",
            start: p.start,
            length: p.length,
            width: p.width,
            fps: RENDER_FPS,
            quality: p.quality,
        };
        const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
        let reply;
        try {
            reply = await this.d.webp.createFromUpload(`studio:${sid}`, params, async () => {
                const obj = await this.d.originals.get(r2Key);
                return obj ? { body: obj.body, size: obj.size } : null;
            });
        } finally {
            if (keepAwake !== undefined) clearInterval(keepAwake);
        }

        const body = reply.body as { status: string; id?: string; error?: { code: string } };
        if (reply.status !== 202 || body.status !== "pending" || !body.id) {
            return { status: reply.status, body: reply.body };
        }
        const job = body.id;
        this.encodes.set(job, this.d.now());
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO studio_renders (id, session_id, status, start, length, width, quality, created_at) VALUES (?1, ?2, 'pending', ?3, ?4, ?5, ?6, ?7)",
                )
                .bind(job, sid, p.start, p.length, p.effectiveWidth, p.quality, this.d.now())
                .run();
        } catch {
            return studioErr(503, "error.api.generic");
        }
        return { status: 202, body: { status: "pending", job } };
    }

    async renderStatus(sid: string, job: string, waitSeconds: number): Promise<StudioReply> {
        const found = await this.lookup(sid);
        if ("reply" in found) return found.reply;

        let row: RenderRow | null;
        try {
            row = await getRender(this.d.db, sid, job);
        } catch {
            return studioErr(503, "error.api.generic");
        }
        if (!row) return studioErr(404, "error.studio.not_found");
        if (row.status === "success") return { status: 200, body: this.successBody(row) };
        if (row.status === "error") {
            return studioErr(200, row.error_code ?? "error.webp.encode_failed");
        }

        const r = await this.d.webp.status(`studio:${sid}`, job, waitSeconds);
        const body = r.body as {
            status: string;
            url?: string;
            bytes?: number;
            width?: number;
            height?: number;
            seconds?: number;
            error?: { code: string };
        };

        if (r.status === 200 && body.status === "success") {
            const done: RenderRow = {
                ...row,
                status: "success",
                url: body.url ?? null,
                bytes: body.bytes ?? null,
                out_width: body.width ?? null,
                out_height: body.height ?? null,
                seconds: body.seconds ?? null,
            };
            const upd = await this.d.db
                .prepare(
                    "UPDATE studio_renders SET status = 'success', error_code = NULL, url = ?1, bytes = ?2, out_width = ?3, out_height = ?4, seconds = ?5 WHERE id = ?6 AND status = 'pending'",
                )
                .bind(done.url, done.bytes, done.out_width, done.out_height, done.seconds, job)
                .run();
            this.encodes.delete(job);
            // Library bookkeeping, once: only the poll that made the row a success.
            const mediaName = mediaNameFromUrl(done.url);
            if (Number(upd.meta?.changes ?? 0) > 0 && mediaName) {
                const title = found.row.title?.trim();
                await insertMediaItem(this.d.db, {
                    kind: "public",
                    source: "studio",
                    bucket: "media",
                    r2_key: mediaName,
                    url: done.url,
                    name: title ? `${title.replace(/\.[A-Za-z0-9]{1,5}$/, "")}.webp` : mediaName,
                    content_type: "image/webp",
                    bytes: done.bytes,
                    width: done.out_width,
                    height: done.out_height,
                    duration: done.seconds,
                    link: pageLink(found.row.link),
                    session_id: sid,
                    key_id: found.row.key_id,
                    created_at: this.d.now(),
                });
            }
            return { status: 200, body: this.successBody(done) };
        }

        // Terminal failures the DO recorded (status 200). A missing job record
        // (404 error.webp.not_found: DO storage lost or pruned) is a lost job.
        const lost = r.status === 404;
        if ((r.status === 200 && body.status === "error") || lost) {
            const code = lost ? "error.webp.job_lost" : (body.error?.code ?? "error.webp.encode_failed");
            await this.d.db
                .prepare(
                    "UPDATE studio_renders SET status = 'error', error_code = ?1 WHERE id = ?2 AND status = 'pending'",
                )
                .bind(code, job)
                .run();
            this.encodes.delete(job);
            return studioErr(200, code);
        }

        if (r.status === 200 && body.status === "pending") {
            return { status: 200, body: { status: "pending", job } };
        }
        // transient (502 storage/upstream): not recorded, the client polls again
        return { status: r.status, body: r.body };
    }

    private successBody(row: RenderRow) {
        return {
            status: "success",
            job: row.id,
            url: row.url,
            bytes: row.bytes,
            width: row.out_width,
            height: row.out_height,
            seconds: row.seconds,
        };
    }
}

// --- routing (inside the Durable Object) -----------------------------------------------

export const isStudioRoute = (pathname: string) =>
    pathname === "/studio" ||
    pathname.startsWith("/studio/") ||
    pathname === "/library/adopt";

const toResponse = (r: StudioReply) =>
    new Response(JSON.stringify(r.body), {
        status: r.status,
        headers: { "content-type": "application/json" },
    });

// POST /studio (needs the key id the Worker set after its D1 lookup),
// GET /studio/<sid>/advance (a saving session's poll), POST /studio/<sid>/render
// and GET /studio/<sid>/render/<job>. The Worker
// answers everything else itself; ids were already checked there and are
// checked again here.
export async function handleStudioRoute(
    service: StudioService,
    request: Request,
): Promise<Response> {
    const url = new URL(request.url);
    const p = url.pathname;

    if (request.method === "POST" && p === "/studio") {
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        return toResponse(await service.create(keyId, await request.text()));
    }

    // POST /library/adopt: the web Worker's service call. The Worker only
    // reaches here after service auth and sets the key id; anything else is
    // refused again here.
    if (request.method === "POST" && p === "/library/adopt") {
        if (request.headers.get(KEY_ID_HEADER) !== SERVICE_KEY_ID) {
            return new Response(null, { status: 403 });
        }
        return toResponse(await service.adopt(SERVICE_KEY_ID, await request.text()));
    }

    const parts = p.split("/"); // "", "studio", sid, "render", job?
    // GET /studio/<sid>/advance?wait=N: internal, only the Worker's forward for a
    // saving session reaches it (the public gate answers 404 for this subpath).
    if (request.method === "GET" && parts.length === 4 && parts[1] === "studio" && parts[3] === "advance") {
        const sid = parts[2];
        if (!STUDIO_SID_REGEX.test(sid)) return toResponse(studioErr(404, "error.studio.not_found"));
        return toResponse(await service.advance(sid, parseStudioWait(url.searchParams.get("wait"))));
    }
    if (parts.length >= 4 && parts[1] === "studio" && parts[3] === "render") {
        const sid = parts[2];
        if (!STUDIO_SID_REGEX.test(sid)) return toResponse(studioErr(404, "error.studio.not_found"));
        if (request.method === "POST" && parts.length === 4) {
            return toResponse(await service.render(sid, await request.text()));
        }
        if (request.method === "GET" && parts.length === 5) {
            const job = parts[4];
            if (!STUDIO_JOB_REGEX.test(job)) return toResponse(studioErr(404, "error.studio.not_found"));
            return toResponse(
                await service.renderStatus(sid, job, parseStudioWait(url.searchParams.get("wait"))),
            );
        }
    }
    return new Response(null, { status: 404 });
}
