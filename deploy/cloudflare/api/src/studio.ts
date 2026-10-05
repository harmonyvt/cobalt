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

import { raceCeiling } from "./ceiling";
import { Crop, JobRecord, KV, Quality, WebpParams, WebpService, num, randomBase62, serviceFromUrl } from "./webp";
import { KEY_ID_HEADER } from "./headers";
import { cropToPixels, parseCrop } from "../helper/crop.js";
import { STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "./gate";
import { SERVICE_KEY_ID, insertMediaItem, mediaNameFromUrl, pageLink } from "./library";
import { LIVE_PUSH_MS, type LiveHooks, type LiveRenderEvent } from "./live";
import { NOTIFY_MAX_BODY_BYTES, parseOptIn, type NotifyHooks, type NotifyRenderEvent } from "./notify";
import { PosterService, POSTER_BATCH, type MediaStore } from "./poster";
import { publishStudio } from "./publish";
import { sessionItem, type PurgeFn } from "./visibility";

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
// The same for a share-sheet save (`origin: "share"`, section 14): its client is a background
// upload that must be answered before the extension goes, so the container's cold start
// (several seconds) is left to the sweep, which is already scheduled.
export const SHARE_KICK_MS = 1200;
// `GET /studio/recent` (section 14): the sessions a key created from a share sheet are
// remembered this long, and at most this many are listed.
export const SHARE_KEEP_MS = 24 * 60 * 60 * 1000;
export const RECENT_MAX = 25;
const SHARE_PREFIX = "share:";
type ShareRecord = { keyId: string; at: number };

// What POST /studio needs of the Hark service: the very call `PUT /studio/<sid>/notify` makes
// (NotifyService.put, notify.ts). A structural type so `NotifyHooks` stays as it is.
type NotifyOptInCall = {
    put(keyId: string, sid: string, raw: string): Promise<{ status: number; body: unknown }>;
};
const canOptIn = (n: unknown): n is NotifyOptInCall =>
    typeof n === "object" && n !== null && typeof (n as { put?: unknown }).put === "function";
export const MAX_SOURCE_BYTES = 200 * 1024 * 1024;
export const MAX_BODY_BYTES = 8192;
export const MAX_STUDIO_WAIT_SECONDS = 25;
// GET /studio/<sid>/<name> with ?wait=N holds a request longer (APP-API-CONTRACT section 11).
export const MAX_SOURCE_WAIT_SECONDS = 90;
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
export const RENDER_QUALITIES = ["low", "med", "high"] as const;

// The job sweep (StudioService.sweep): a render job is collected by the sweep for
// this long after it was accepted (the helper's 240 s budget plus the upload
// into R2); a save is advanced by it while its current helper fetch is younger
// than SAVE_BUDGET_MS plus this slack.
export const SWEEP_RENDER_MS = 6 * 60 * 1000;
export const SWEEP_SAVE_SLACK_MS = 60_000;
// Ceiling on one item of a sweep pass (one render poll or one save step): the
// Containers library awaits the whole pass inside alarm() before it checks
// sleepAfter, so one hung item must never be able to hold the container awake.
// (The pass as a whole is capped again in sweep.ts: SWEEP_PASS_MS.)
export const SWEEP_ITEM_MS = 30_000;

// One notification call (the webhook call inside is capped at 3 s by notify.ts).
export const NOTIFY_CALL_MS = 5000;

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
    // migration 0006 (section 13). Optional: rows seeded without them read as null.
    // The poster JPEG's public URL, mirrored from the session's original.
    poster?: string | null;
    // `public: true` on the save: 'pending' until the original is hosted, then 'ready'
    // (public_url) or 'failed'; null when it was never asked for.
    public_state?: PublicState | null;
    public_url?: string | null;
};

export type PublicState = "pending" | "ready" | "failed";

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

// What a save in flight is doing right now (in memory on the Durable Object,
// not persisted: after an eviction the next step repopulates it). APP-API-
// CONTRACT.md section 2.
export type SaveStep = "fetching" | "reading" | "storing";
export type SaveProgress = {
    step: SaveStep;
    bytes: number | null;
    total: number | null;
    waking: boolean;
};

export function sessionBody(
    row: SessionRow,
    renders: RenderRow[],
    progress?: SaveProgress | null,
    // the session's original in the library (section 16): its row id and visibility, null = none
    item?: { item_id: string; visibility: "public" | "private" } | null,
) {
    // progress only means something while the session is saving
    const p = row.status === "saving" ? (progress ?? null) : null;
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
        // server-made thumbnail (null until the container has cut it; section 13)
        poster_url: row.poster ?? null,
        // public hosting asked for with `public: true` (null = not asked) and where it is
        public_state: row.public_state ?? null,
        public_url: row.public_url ?? null,
        // the library row of this session's original and whether it is public (section 16)
        item_id: item?.item_id ?? null,
        visibility: item?.visibility ?? null,
        // save progress (null / false when the DO does not know)
        step: p?.step ?? null,
        step_bytes: p?.bytes ?? null,
        step_total: p?.total ?? null,
        waking: p?.waking ?? false,
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

// ?wait=N for the video route: absent or junk = 0 (today's behaviour),
// clamped to 0..90.
export function parseSourceWait(raw: string | null): number {
    if (raw === null || raw.trim() === "") return 0;
    const n = Number(raw);
    if (!Number.isFinite(n)) return 0;
    return Math.min(MAX_SOURCE_WAIT_SECONDS, Math.max(0, n));
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
    // what is recorded: the requested width, never above the source's (or the crop's)
    effectiveWidth: number;
    // optional spatial crop, normalized (section 10); absent = the whole frame
    crop?: Crop;
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
    source: { duration: number | null; width: number | null; height?: number | null },
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
        if (!(RENDER_QUALITIES as readonly unknown[]).includes(b.quality)) return invalid();
        quality = b.quality as Quality;
    }

    // Optional crop (section 10): normalized in the display orientation. With the size
    // probed at save time it is converted to pixels here too, so a crop under 64 px is a
    // 400 before anything starts, and the recorded width is min(width, cropped width).
    const parsedCrop = parseCrop(b.crop);
    if (!parsedCrop.ok) return invalid();
    let effectiveWidth = source.width ? Math.min(width, source.width) : width;
    if (parsedCrop.crop && source.width && source.height) {
        const px = cropToPixels(parsedCrop.crop, source.width, source.height);
        if (!px) return invalid();
        effectiveWidth = Math.min(width, px.w);
    }
    return {
        ok: true,
        params: { start, length, width, quality, effectiveWidth, ...(parsedCrop.crop ? { crop: parsedCrop.crop } : {}) },
    };
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
        // a stream (stored files) or a string (telemetry crash JSON, telemetry.ts)
        value: ReadableStream | string,
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
    // Metadata only (no body): the object's real size, null when it is missing.
    head(key: string): Promise<{
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
    // `onChunk` is called with each chunk's byte length as it passes (the
    // "storing" progress).
    fixedLength: (
        stream: ReadableStream,
        length: number,
        onChunk?: (n: number) => void,
    ) => ReadableStream;
    // Is the container running right now? (`waking` in the save progress.)
    isRunning?: () => boolean;
    // Asks the Durable Object to run the job sweep soon (see sweep()). Awaited,
    // never allowed to fail the request that asked.
    scheduleSweep?: () => void | Promise<void>;
    // How long POST /studio waits for the helper to accept the fetch (KICK_MS).
    kickMs?: number;
    // Our own ceiling on a helper call. The helper's AbortSignal.timeout is not
    // honoured for containerFetch inside the DO: a hung call stalled a poll for
    // 5.5 min live (2026-10-01).
    helperTimeoutMs?: number;
    // Ceiling on one item of a sweep pass (default SWEEP_ITEM_MS).
    sweepItemMs?: number;
    // The same for the probe of an adopted upload, whose call carries the whole
    // video into the helper (default 50 s, inside LOCK_STALE_MS).
    probeTimeoutMs?: number;
    // Renews the container's sleepAfter timer (long streams make no helper calls).
    renew?: () => void;
    // Live Activity push (APP-API-CONTRACT.md section 8). Every call is awaited but
    // raced against `livePushMs` (LIVE_PUSH_MS): it can never fail or stall a poll.
    live?: LiveHooks;
    livePushMs?: number;
    // Hark notification bridge (APP-API-CONTRACT.md section 9). Every call is awaited but raced
    // against `notifyMs` (default NOTIFY_CALL_MS): it can never fail or stall a poll for long.
    notify?: NotifyHooks;
    notifyMs?: number;
    // The public bucket and its base URL (APP-API-CONTRACT.md section 13): server-made posters
    // and `public: true` hosting. Absent = both off (a save that asks for `public` ends with
    // public_state 'failed'; no poster jobs are queued).
    media?: MediaStore;
    mediaBaseUrl?: string;
    // Edge-cache purge (section 16); absent = not configured
    purge?: PurgeFn;
    // How long a save, upload or render waits for a poster being made (POSTER_IDLE_WAIT_MS).
    posterIdleMs?: number;
};

// A save's public copy is retried by the sweep this many times, then it is 'failed'.
export const MAX_PUBLIC_ATTEMPTS = 4;
type PublicJob = { attempts: number; at: number };
const PUBLIC_PREFIX = "public:";

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

const isPlainObject = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

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
    // sid -> what the save is doing now (in memory only, see SaveProgress)
    private progress = new Map<string, SaveProgress>();
    // sid -> when the copy into R2 last told the live service its byte count
    private lastStoringPush = new Map<string, number>();

    // Server-made posters (section 13); undefined when no public bucket is wired.
    private posters?: PosterService;
    // sid -> its public copy is being made right now (in memory only)
    private hosting = new Set<string>();

    constructor(private d: StudioDeps) {
        if (d.media && d.mediaBaseUrl) {
            this.posters = new PosterService({
                db: d.db,
                storage: d.storage,
                originals: d.originals,
                media: d.media,
                mediaBaseUrl: d.mediaBaseUrl,
                now: d.now,
                randomBytes: d.randomBytes,
                ensureRunning: d.ensureRunning,
                callHelper: (path, init, ms) => this.callHelper(path, init, ms),
                helperBusy: async () => (await this.saveActive()) || this.encoding(),
                scheduleSweep: () => this.scheduleSweep(),
                renew: d.renew,
            });
        }
    }

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[studio] scheduling the job sweep failed", String(e));
        }
    }

    // ---- Live Activity hooks (section 8.3) ---------------------------------------

    // Awaited, raced against LIVE_PUSH_MS, errors logged: a hook that throws or
    // hangs never fails or stalls the poll beyond that.
    private async liveCall(label: string, fn: (live: LiveHooks) => Promise<void>): Promise<void> {
        const live = this.d.live;
        if (!live) return;
        try {
            await raceCeiling(
                Promise.resolve().then(() => fn(live)),
                this.d.livePushMs ?? LIVE_PUSH_MS,
                `live ${label}`,
            );
        } catch (e) {
            console.error("[studio] live push failed:", label, String(e));
        }
    }

    // The one place the save progress changes (APP-API-CONTRACT.md 8.3): set it and
    // tell the live service. `probeStep` does not come through here (an upload's
    // server read is not shown: the device is reading frames then).
    private async setProgress(
        sid: string,
        p: SaveProgress,
        extra: { title?: string | null; duration?: number | null } = {},
    ): Promise<void> {
        this.progress.set(sid, p);
        await this.liveCall("save progress", (l) => l.onSave(sid, { kind: "progress", progress: p, ...extra }));
    }

    private async liveRender(sid: string, job: string, e: LiveRenderEvent): Promise<void> {
        await this.liveCall("render", (l) => l.onRender(sid, job, e));
    }

    // The render events that follow from what renderStatus answered, so a client
    // poll and the sweep reach the live service the same way (a repeated success
    // is an event too: an equal state is never re-sent, a lost push is).
    private async emitRender(sid: string, job: string, reply: StudioReply): Promise<void> {
        if (!this.d.live || reply.status !== 200) return;
        const b = reply.body as {
            status?: unknown;
            url?: unknown;
            bytes?: unknown;
            width?: unknown;
            height?: unknown;
            seconds?: unknown;
            phase?: unknown;
            frames_done?: unknown;
            frames_total?: unknown;
            error?: { code?: unknown };
        };
        if (b.status === "success" && typeof b.url === "string") {
            await this.liveRender(sid, job, {
                kind: "success",
                url: b.url,
                bytes: finite(b.bytes),
                width: finite(b.width),
                height: finite(b.height),
                seconds: finite(b.seconds),
            });
        } else if (b.status === "error" && typeof b.error?.code === "string") {
            await this.liveRender(sid, job, { kind: "failed", code: b.error.code });
        } else if (b.status === "pending") {
            await this.liveRender(sid, job, {
                kind: "pending",
                phase: b.phase === "fetching" || b.phase === "decode" || b.phase === "pack" ? b.phase : null,
                framesDone: finite(b.frames_done),
                framesTotal: finite(b.frames_total),
            });
        }
    }

    // ---- Hark notification hooks (section 9) ------------------------------------------

    // Awaited, raced against NOTIFY_CALL_MS, errors logged by label only: a hook that
    // throws or hangs never fails or stalls the poll beyond that. (No error text: nothing
    // from the webhook call may reach a log.)
    private async notifyCall(label: string, fn: (n: NotifyHooks) => Promise<void>): Promise<void> {
        const notify = this.d.notify;
        if (!notify) return;
        try {
            await raceCeiling(
                Promise.resolve().then(() => fn(notify)),
                this.d.notifyMs ?? NOTIFY_CALL_MS,
                `notify ${label}`,
            );
        } catch (e) {
            console.error("[studio] notify failed:", label, e instanceof Error ? e.name : "error");
        }
    }

    // The notification that follows from what renderStatus answered: a poll and the sweep
    // reach it the same way, and the event's own record makes a repeat a no-op.
    private async notifyRender(sid: string, job: string, reply: StudioReply): Promise<void> {
        if (!this.d.notify || reply.status !== 200) return;
        const b = reply.body as {
            status?: unknown;
            url?: unknown;
            bytes?: unknown;
            width?: unknown;
            height?: unknown;
            error?: { code?: unknown };
        };
        let e: NotifyRenderEvent | null = null;
        if (b.status === "success" && typeof b.url === "string") {
            e = { kind: "success", url: b.url, bytes: finite(b.bytes), width: finite(b.width), height: finite(b.height) };
        } else if (b.status === "error" && typeof b.error?.code === "string") {
            e = { kind: "failed", code: b.error.code };
        }
        if (e) {
            const ev = e;
            await this.notifyCall("render", (n) => n.onRender(sid, job, ev));
        }
    }

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
        let publicFlag: unknown;
        let originField: unknown;
        let notifyField: unknown;
        try {
            if (rawBody.length <= MAX_BODY_BYTES) {
                const parsed = JSON.parse(rawBody);
                if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
                    link = linkFrom((parsed as { url?: unknown }).url);
                    publicFlag = (parsed as { public?: unknown }).public;
                    originField = (parsed as { origin?: unknown }).origin;
                    notifyField = (parsed as { notify?: unknown }).notify;
                }
            }
        } catch {
            // no link
        }
        if (!link) return studioErr(400, "error.studio.no_link");
        // `public: true` (section 13): host the original publicly once the save is ready
        if (publicFlag !== undefined && publicFlag !== null && typeof publicFlag !== "boolean") {
            return studioErr(400, "error.studio.invalid_params");
        }
        const wantsPublic = publicFlag === true;
        // `origin: "share"` (section 14): a share sheet's background save. Nothing else is accepted.
        if (originField !== undefined && originField !== null && originField !== "share") {
            return studioErr(400, "error.studio.invalid_params");
        }
        const fromShare = originField === "share";
        // `notify: {on, label}` (section 14): the opt-in of PUT /studio/<sid>/notify, validated by
        // the same parser BEFORE anything is created.
        let optIn: string | null = null;
        if (notifyField !== undefined && notifyField !== null) {
            const text = isPlainObject(notifyField) ? JSON.stringify(notifyField) : "";
            if (text === "" || new TextEncoder().encode(text).length > NOTIFY_MAX_BODY_BYTES || !parseOptIn(text)) {
                return studioErr(400, "error.notify.invalid");
            }
            optIn = text;
        }

        await this.posters?.idle(this.d.posterIdleMs);
        await this.reapOrphans();
        // A share sheet has no one to retry a refusal: its save queues behind the one running (a
        // save waits for the helper up to BUSY_WAIT_MS, then fails with error.studio.busy, which
        // the opt-in announces).
        if (!fromShare && ((await this.saveActive()) || this.encoding())) {
            return studioErr(429, "error.studio.busy");
        }

        const sid = mintSid(this.d.randomBytes);
        const now = this.d.now();
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at, public_state) VALUES (?1, ?2, ?3, ?4, 'saving', ?5, ?6, ?7)",
                )
                .bind(sid, keyId, link, serviceFromUrl(link), now, now + SESSION_TTL_MS, wantsPublic ? "pending" : null)
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
        if (fromShare) await this.rememberShare(keyId, sid, now);
        // The opt-in goes in before the save can move, so even an instant save is announced.
        const notifyBody = optIn === null ? undefined : await this.optInAtCreate(keyId, sid, optIn);

        // Nothing runs after this response: the save only moves while the
        // studio page polls GET /studio/<sid> (-> advance), or the job sweep
        // (scheduled below) runs. Try once now to have the helper accept the
        // fetch, but never hold the 201 for long.
        await this.scheduleSweep();
        await this.kick(sid, fromShare ? SHARE_KICK_MS : undefined);

        const base = this.d.webBaseUrl.replace(/\/+$/, "");
        return {
            status: 201,
            body: {
                status: "success",
                id: sid,
                url: `${base}/studio/${sid}`,
                ...(notifyBody ? { notify: notifyBody } : {}),
            },
        };
    }

    // The session was made by a share sheet: `GET /studio/recent` lists it for its key. Records
    // older than SHARE_KEEP_MS are dropped here. Never fails the create.
    private async rememberShare(keyId: string, sid: string, now: number): Promise<void> {
        try {
            const all = await this.d.storage.list<ShareRecord>({ prefix: SHARE_PREFIX });
            for (const [k, rec] of all) {
                if (!rec || now - rec.at > SHARE_KEEP_MS) await this.d.storage.delete(k);
            }
            await this.d.storage.put(`${SHARE_PREFIX}${sid}`, { keyId, at: now } satisfies ShareRecord);
        } catch (e) {
            console.error("[studio] could not remember share", String(e instanceof Error ? e.name : "error"));
        }
    }

    // The Hark opt-in of a session that was just created (the body of PUT /studio/<sid>/notify,
    // answered by the same service). The save is not refused when it cannot be stored: the owner
    // still has the app's own poll.
    private async optInAtCreate(
        keyId: string,
        sid: string,
        raw: string,
    ): Promise<{ bridge: boolean; on: unknown; label: unknown; expires_at: unknown } | undefined> {
        const notify = this.d.notify;
        if (!canOptIn(notify)) return undefined;
        let out: { bridge: boolean; on: unknown; label: unknown; expires_at: unknown } | undefined;
        await this.notifyCall("create opt-in", async () => {
            const r = await notify.put(keyId, sid, raw);
            const b = r.body as { bridge?: unknown; on?: unknown; label?: unknown; expires_at?: unknown } | null;
            if (r.status === 200 && b) out = { bridge: b.bridge === true, on: b.on ?? null, label: b.label ?? null, expires_at: b.expires_at ?? null };
        });
        return out;
    }

    // GET /studio/recent?since=<ms>&limit=<1..25> (keyed): the sessions this key created from a
    // share sheet in the last 24 hours (newest first), as GET /studio/<sid> shows them. The
    // app asks when it opens: a build with no app group cannot read what the extension left.
    async recent(keyId: string, sinceRaw: string | null, limitRaw: string | null): Promise<StudioReply> {
        const now = this.d.now();
        const floor = now - SHARE_KEEP_MS;
        const parsedSince = sinceRaw !== null && /^\d{1,15}$/.test(sinceRaw) ? Number(sinceRaw) : floor;
        const since = Math.max(floor, parsedSince);
        const parsedLimit = limitRaw !== null && /^\d{1,3}$/.test(limitRaw) ? Number(limitRaw) : RECENT_MAX;
        const limit = Math.min(RECENT_MAX, Math.max(1, parsedLimit));
        const mine: { sid: string; at: number }[] = [];
        try {
            for (const [k, rec] of await this.d.storage.list<ShareRecord>({ prefix: SHARE_PREFIX })) {
                if (!rec) continue;
                if (rec.keyId === keyId && rec.at >= since) mine.push({ sid: k.slice(SHARE_PREFIX.length), at: rec.at });
            }
        } catch {
            return studioErr(503, "error.api.generic");
        }
        mine.sort((a, b) => b.at - a.at);
        const sessions: unknown[] = [];
        try {
            for (const { sid } of mine.slice(0, limit)) {
                const row = await getSession(this.d.db, sid);
                // an expired session is gone for the app too; a row of another key never shows
                if (!row || row.key_id !== keyId || row.expires_at <= now) continue;
                sessions.push(sessionBody(row, [], this.progress.get(row.id), await sessionItem(this.d.db, row.r2_key)));
            }
        } catch {
            return studioErr(503, "error.api.generic");
        }
        return { status: 200, body: { status: "success", now, sessions } };
    }

    // One advance step under the lock, bounded by KICK_MS. If it overruns, it
    // keeps going (still holding the lock) and the 201 is sent anyway.
    // The kick runs OUTSIDE the per-session lock: a kicked step still running
    // after the 201 (waking the container outlasts KICK_MS) hung with the lock
    // held, and every later poll just waited on it (live, 2026-10-01). Unlocked,
    // a hung kick blocks nothing; the helper treats a repeated /fetch for the
    // same id as the same job.
    private async kick(sid: string, capMs?: number): Promise<void> {
        const p = this.step(sid).catch(() => POLL_INTERVAL_MS);
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<void>((resolve) => {
            // a share sheet's cap never exceeds the configured one (tests shorten it)
            timer = setTimeout(resolve, Math.min(capMs ?? Infinity, this.d.kickMs ?? KICK_MS));
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

    // Whether this call is the one that made the session an error.
    private async markError(sid: string, code: string): Promise<boolean> {
        try {
            const res = await this.d.db
                .prepare(
                    "UPDATE studio_sessions SET status = 'error', error_code = ?1, public_state = NULL WHERE id = ?2 AND status = 'saving'",
                )
                .bind(code, sid)
                .run();
            return Number(res.meta?.changes ?? 0) > 0;
        } catch (e) {
            console.error("[studio] could not record save error", sid, String(e));
            return false;
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
        const changed = await this.markError(sid, code);
        await this.dropHelperCopy(sid);
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        this.progress.delete(sid);
        this.lastStoringPush.delete(sid);
        await this.liveCall("save failed", (l) => l.onSave(sid, { kind: "failed", code }));
        if (changed) await this.notifyCall("save failed", (n) => n.onSaveFailed(sid, code));
        return POLL_INTERVAL_MS;
    }

    // ---- GET /studio/<sid>/advance?wait=N (internal, called by the Worker) ---------------

    private async sessionReply(row: SessionRow): Promise<StudioReply> {
        try {
            const renders = row.status === "ready" ? await listSuccessfulRenders(this.d.db, row.id) : [];
            return { status: 200, body: sessionBody(row, renders, this.progress.get(row.id), await sessionItem(this.d.db, row.r2_key)) };
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
            this.progress.delete(sid);
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
        // `waking`: this save is waiting for the container to start
        await this.setProgress(sid, {
            step: "fetching",
            bytes: null,
            total: null,
            waking: this.d.isRunning ? !this.d.isRunning() : false,
        });
        try {
            await this.d.ensureRunning();
        } catch {
            await this.setProgress(sid, { step: "fetching", bytes: null, total: null, waking: false });
            return await this.miss(sid, rec);
        }
        await this.setProgress(sid, { step: "fetching", bytes: null, total: null, waking: false });
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
            // what the helper says it is doing; an old helper says nothing
            const bytes = finite(body.bytes);
            const total = finite(body.total);
            await this.setProgress(
                sid,
                body.stage === "probing"
                    ? { step: "reading", bytes, total: null, waking: false }
                    : body.stage === "downloading"
                      ? { step: "fetching", bytes, total, waking: false }
                      : { step: "fetching", bytes: null, total: null, waking: false },
            );
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
            typeof done.contentType === "string" &&
            (/^video\/[a-z0-9.+-]+$/i.test(done.contentType) || done.contentType === "image/gif")
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
            // `storing`: bytes copied into R2 so far, out of the file's size
            const progress: SaveProgress = { step: "storing", bytes: 0, total: bytes, waking: false };
            const clip = {
                title: typeof done.title === "string" && done.title.trim() ? done.title.trim().slice(0, 200) : null,
                duration: finite(done.duration),
            };
            await this.setProgress(sid, progress, clip);
            this.lastStoringPush.set(sid, this.d.now());
            stored = await this.d.originals.put(
                key,
                this.d.fixedLength(file.body, bytes, (n) => {
                    progress.bytes = (progress.bytes ?? 0) + n;
                    // The copy can run for a minute inside this one request and
                    // nothing else reports it (the sweep leaves a locked save
                    // alone), so it tells the live service its byte count itself,
                    // at most once a second. Not awaited: it is called from the
                    // stream; liveCall swallows errors and is bounded.
                    const at = this.d.now();
                    if (at - (this.lastStoringPush.get(sid) ?? 0) >= 1000) {
                        this.lastStoringPush.set(sid, at);
                        void this.liveCall("save storing", (l) => l.onSave(sid, { kind: "progress", progress, ...clip }));
                    }
                }),
                {
                    httpMetadata: { contentType },
                    customMetadata: {
                        keyId,
                        source: link.slice(0, 1000),
                        sessionId: sid,
                        createdAt: String(this.d.now()),
                    },
                },
            );
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
        let becameReady = false;
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
            // the save is ready: the owner who walked away is told (once: the event's record)
            await this.notifyCall("saved", (n) => n.onSaved(sid));
            becameReady = true;
        }
        await this.dropHelperCopy(sid);
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        this.progress.delete(sid);
        this.lastStoringPush.delete(sid);
        // The poster and, when asked for, the public copy (section 13). `ready` is already recorded
        // and the helper and the save record are already free, so neither can delay what else wants
        // them, and a failure of either never fails the save.
        if (becameReady) await this.afterReady(sid, row.public_state === "pending", key);
        return POLL_INTERVAL_MS;
    }

    // ---- after a save is ready: the poster, and the public copy (section 13) ------------------

    // Both are bookkeeping that must never fail or delay the save: the poster is only queued
    // (the sweep makes it), the public copy is made here when asked for, with a record for the
    // sweep to finish it if this attempt does not (a Durable Object eviction, an R2 hiccup).
    private async afterReady(sid: string, wantsPublic: boolean, r2Key: string): Promise<void> {
        try {
            await this.posters?.onReady(r2Key);
            if (!wantsPublic) return;
            await this.d.storage.put(`${PUBLIC_PREFIX}${sid}`, { attempts: 0, at: this.d.now() } satisfies PublicJob);
            await this.scheduleSweep();
            await this.hostPublic(sid);
        } catch (e) {
            console.error("[studio] after-ready work failed", sid, String(e));
        }
    }

    private async setPublic(sid: string, state: PublicState, url: string | null): Promise<void> {
        try {
            await this.d.db
                .prepare("UPDATE studio_sessions SET public_state = ?1, public_url = ?2 WHERE id = ?3 AND public_state = 'pending'")
                .bind(state, url, sid)
                .run();
        } catch (e) {
            console.error("[studio] could not record the public copy", sid, String(e));
        }
    }

    // Hosts a ready session's original publicly (the same code path as POST /studio/<sid>/publish:
    // publishStudio, the same names, the same `host` row). Idempotent: a session already hosted
    // (an earlier attempt copied the file but died before recording it) just records it. A
    // transient failure leaves the `public:<sid>` record for the next sweep pass; after
    // MAX_PUBLIC_ATTEMPTS, or on a failure that cannot improve, the state is 'failed' and the
    // original stays private (the owner can still host it by hand). Never throws.
    async hostPublic(sid: string): Promise<void> {
        if (this.hosting.has(sid)) return;
        this.hosting.add(sid);
        const key = `${PUBLIC_PREFIX}${sid}`;
        try {
            const row = await getSession(this.d.db, sid);
            if (!row || row.public_state !== "pending" || row.status !== "ready") {
                await this.d.storage.delete(key).catch(() => {});
                return;
            }
            const rec = (await this.d.storage.get<PublicJob>(key)) ?? { attempts: 0, at: this.d.now() };
            if (!this.d.media || !this.d.mediaBaseUrl) {
                await this.setPublic(sid, "failed", null);
                await this.d.storage.delete(key).catch(() => {});
                return;
            }
            let url: string | null = null;
            // the original is already public (one row per file, section 16): just record it
            const have = row.r2_key
                ? await this.d.db
                      .prepare(
                          "SELECT url FROM media_items WHERE bucket = 'originals' AND r2_key = ?1 AND visibility = 'public' AND url IS NOT NULL AND deleted_at IS NULL LIMIT 1",
                      )
                      .bind(row.r2_key)
                      .first<{ url: string | null }>()
                : null;
            if (have?.url) url = have.url;
            if (!url) {
                if (rec.attempts >= MAX_PUBLIC_ATTEMPTS) {
                    await this.setPublic(sid, "failed", null);
                    await this.d.storage.delete(key).catch(() => {});
                    return;
                }
                // counted when it starts: an attempt that takes the Durable Object down still ends
                await this.d.storage.put(key, { attempts: rec.attempts + 1, at: this.d.now() } satisfies PublicJob);
                const reply = await publishStudio(
                    {
                        db: this.d.db,
                        originals: this.d.originals,
                        media: this.d.media,
                        mediaBaseUrl: this.d.mediaBaseUrl,
                        now: this.d.now,
                        randomBytes: this.d.randomBytes,
                        purge: this.d.purge,
                    },
                    sid,
                    row.key_id ?? SERVICE_KEY_ID,
                );
                const b = reply.body as { url?: unknown; error?: { code?: unknown } };
                if (reply.status === 201 && typeof b.url === "string") {
                    url = b.url;
                } else {
                    const code = typeof b.error?.code === "string" ? b.error.code : "error.api.generic";
                    console.error("[studio] public copy failed", sid, reply.status, code);
                    // a session that is gone, expired or not ready will not get better
                    if (reply.status === 404 || reply.status === 410 || reply.status === 409) {
                        await this.setPublic(sid, "failed", null);
                        await this.d.storage.delete(key).catch(() => {});
                    }
                    return;
                }
            }
            await this.setPublic(sid, "ready", url);
            await this.d.storage.delete(key).catch(() => {});
        } catch (e) {
            console.error("[studio] public copy threw", sid, String(e));
        } finally {
            this.hosting.delete(sid);
        }
    }

    // POST /posters/kick (the Worker's call: the library read, the cron, the backfill route):
    // queues the posters still missing. Never wakes the container (the sweep does the work).
    async kickPosters(limit?: number): Promise<StudioReply> {
        if (!this.posters) return studioErr(503, "error.api.generic");
        try {
            const r = await this.posters.kick(limit ?? POSTER_BATCH);
            return { status: 200, body: { status: "success", queued: r.queued, eligible: r.eligible } };
        } catch (e) {
            console.error("[studio] poster kick failed", String(e));
            return studioErr(503, "error.api.generic");
        }
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
        // `public: true` (section 13): host the original publicly once it is ready
        if (b.public !== undefined && b.public !== null && typeof b.public !== "boolean") return invalid();
        const wantsPublic = b.public === true;
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

        await this.posters?.idle(this.d.posterIdleMs);
        await this.reapOrphans();
        if ((await this.saveActive()) || this.encoding()) {
            return studioErr(429, "error.studio.busy");
        }

        const sid = mintSid(this.d.randomBytes);
        const now = this.d.now();
        try {
            // (a reopened original that already has a poster hands it to its new session)
            await this.d.db
                .prepare(
                    `INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, created_at, expires_at, public_state, poster, public_url)
                     VALUES (?1, ?2, ?3, 'upload', ?4, 'saving', ?5, ?6, ?7, ?8, ?9,
                             COALESCE(?10, (SELECT CASE WHEN visibility = 'public' AND url IS NOT NULL THEN 'ready' END FROM media_items WHERE bucket = 'originals' AND r2_key = ?5 AND deleted_at IS NULL LIMIT 1)),
                             (SELECT poster FROM media_items WHERE bucket = 'originals' AND r2_key = ?5 AND deleted_at IS NULL LIMIT 1),
                             (SELECT CASE WHEN visibility = 'public' THEN url END FROM media_items WHERE bucket = 'originals' AND r2_key = ?5 AND deleted_at IS NULL LIMIT 1))`,
                )
                .bind(sid, keyId, `upload:${itemId}`, name.trim(), r2Key, contentType, bytes, now, now + SESSION_TTL_MS, wantsPublic ? "pending" : null)
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
        await this.scheduleSweep();

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
        this.progress.set(sid, { step: "reading", bytes: null, total: null, waking: false });
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
        const ready = await this.d.db
            .prepare(
                "UPDATE studio_sessions SET status = 'ready', error_code = NULL, duration = ?1, width = ?2, height = ?3, bytes = ?4 WHERE id = ?5 AND status = 'saving'",
            )
            .bind(finite(body?.duration), width, height, obj.size, sid)
            .run();
        await this.d.storage.delete(`save:${sid}`).catch(() => {});
        this.progress.delete(sid);
        if (Number(ready.meta?.changes ?? 0) > 0) await this.afterReady(sid, row.public_state === "pending", key);
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
        // `"notify": true`: tell the owner about this render's result (section 9.3)
        const notifyFlag = isPlainObject(parsed) ? parsed.notify : undefined;
        if (notifyFlag !== undefined && typeof notifyFlag !== "boolean") return studioErr(400, "error.webp.invalid_params");
        const check = validateRender(parsed, { duration: row.duration, width: row.width, height: row.height });
        if (!check.ok) return studioErr(check.status, check.code);
        const p = check.params;

        await this.posters?.idle(this.d.posterIdleMs);
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
            ...(p.crop ? { crop: p.crop } : {}),
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
        // accepted: the run (if one is registered for this session) is now rendering
        await this.liveRender(sid, job, { kind: "accepted", title: row.title, duration: row.duration });
        if (notifyFlag === true) await this.notifyCall("render opt-in", (n) => n.optInJob(sid, job));
        return { status: 202, body: { status: "pending", job } };
    }

    async renderStatus(sid: string, job: string, waitSeconds: number): Promise<StudioReply> {
        const reply = await this.renderStatusInner(sid, job, waitSeconds);
        await this.emitRender(sid, job, reply);
        await this.notifyRender(sid, job, reply);
        return reply;
    }

    private async renderStatusInner(sid: string, job: string, waitSeconds: number): Promise<StudioReply> {
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
            const upd = await this.d.db
                .prepare(
                    "UPDATE studio_renders SET status = 'error', error_code = ?1 WHERE id = ?2 AND status = 'pending'",
                )
                .bind(code, job)
                .run();
            this.encodes.delete(job);
            if (Number(upd.meta?.changes ?? 0) === 0) {
                // The row is no longer pending: another poll (or the sweep)
                // settled it while this one was away. Answer what is recorded,
                // so a collected success is never reported as an error.
                try {
                    const now = await getRender(this.d.db, sid, job);
                    if (now?.status === "success") return { status: 200, body: this.successBody(now) };
                    if (now?.status === "error") return studioErr(200, now.error_code ?? code);
                } catch {
                    // fall through to this poll's own answer
                }
            }
            return studioErr(200, code);
        }

        if (r.status === 200 && body.status === "pending") {
            const p = body as { phase?: unknown; frames_done?: unknown; frames_total?: unknown };
            return {
                status: 200,
                body: {
                    status: "pending",
                    job,
                    phase: p.phase ?? null,
                    frames_done: p.frames_done ?? null,
                    frames_total: p.frames_total ?? null,
                },
            };
        }
        // transient (502 storage/upstream): not recorded, the client polls again
        return { status: r.status, body: r.body };
    }

    // ---- the job sweep ------------------------------------------------------------------

    // One non-waiting pass over everything that only moves while somebody
    // collects it, so a job finishes with nobody polling (APP-API-CONTRACT.md
    // section 6; the Durable Object runs it from a Containers `schedule()`):
    //  1. render jobs (`job:<id>` without a `result:<id>`, accepted within
    //     SWEEP_RENDER_MS): collected exactly as a client poll would, which
    //     records the D1 row, the library item and the R2 object. A studio
    //     render ("studio:<sid>") goes through renderStatus, a /webp job through
    //     the WebP service;
    //  2. saves (`save:<sid>`) that are not being advanced right now and whose
    //     current helper fetch is younger than SAVE_BUDGET_MS plus a minute: one
    //     step each. (Their `lastAdvance` is refreshed by this very sweep, so
    //     the budget is anchored on `startedAt`, the time the helper accepted
    //     the fetch.)
    // Returns how many things are still pending; the caller runs it again soon
    // while that is above zero, so the container stays awake exactly while
    // something is pending. Never rejects.
    async sweep(): Promise<{ pending: number }> {
        let pending = 0;
        const now = this.d.now();
        const itemMs = this.d.sweepItemMs ?? SWEEP_ITEM_MS;

        let jobs: Map<string, JobRecord> = new Map();
        try {
            jobs = await this.d.storage.list<JobRecord>({ prefix: "job:" });
        } catch (e) {
            console.error("[studio] sweep: listing jobs failed", String(e));
        }
        for (const [key, rec] of jobs) {
            const id = key.slice("job:".length);
            try {
                if (!rec || now - rec.createdAt > SWEEP_RENDER_MS) continue;
                if (await this.d.storage.get(`result:${id}`)) continue;
                const owner = rec.keyId;
                const r = await raceCeiling(
                    owner.startsWith("studio:")
                        ? this.renderStatus(owner.slice("studio:".length), id, 0)
                        : this.d.webp.status(owner, id, 0),
                    itemMs,
                    `sweep of job ${id}`,
                );
                const body = r.body as { status?: string };
                if ((r.status === 200 && body.status === "pending") || r.status >= 500) pending++;
            } catch (e) {
                console.error("[studio] sweep: job failed", id, String(e));
                pending++;
            }
        }

        let saves: Map<string, SaveRecord> = new Map();
        try {
            saves = await this.d.storage.list<SaveRecord>({ prefix: "save:" });
        } catch (e) {
            console.error("[studio] sweep: listing saves failed", String(e));
        }
        for (const [key, rec] of saves) {
            const sid = key.slice("save:".length);
            try {
                // The budget first: a save past it is never advanced and never
                // counts as pending, even with a (hung) step still holding its
                // lock, or the sweep would re-arm every 5 s for ever.
                const started = rec?.startedAt ?? rec?.createdAt ?? 0;
                if (now - started > SAVE_BUDGET_MS + SWEEP_SAVE_SLACK_MS) continue;
                // A poll is advancing it right now: leave it be, unless that
                // lock is stale (a hung helper call): then advance() drops it
                // and starts a fresh step, exactly as a client poll would.
                const lockedSince = this.advancing.has(sid) ? this.advancingSince.get(sid) : undefined;
                if (this.advancing.has(sid) && !(lockedSince !== undefined && now - lockedSince > LOCK_STALE_MS)) {
                    pending++;
                    continue;
                }
                await raceCeiling(this.advance(sid, 0), itemMs, `sweep of save ${sid}`);
                if (await this.d.storage.get(`save:${sid}`)) pending++;
            } catch (e) {
                console.error("[studio] sweep: save failed", sid, String(e));
                pending++;
            }
        }

        // public copies that did not finish inline (section 13): the same record-driven retry
        let publics: Map<string, PublicJob> = new Map();
        try {
            publics = await this.d.storage.list<PublicJob>({ prefix: PUBLIC_PREFIX });
        } catch (e) {
            console.error("[studio] sweep: listing public copies failed", String(e));
        }
        for (const [key] of publics) {
            const sid = key.slice(PUBLIC_PREFIX.length);
            try {
                if (!this.hosting.has(sid)) await raceCeiling(this.hostPublic(sid), itemMs, `sweep of public copy ${sid}`);
                if (await this.d.storage.get(key)) pending++;
            } catch (e) {
                console.error("[studio] sweep: public copy failed", sid, String(e));
                pending++;
            }
        }

        // posters: one per pass, only while nothing else needs the helper (the poster service
        // checks that itself and counts what is still queued)
        if (this.posters) {
            try {
                pending += await raceCeiling(this.posters.sweep(), itemMs, "sweep of posters");
            } catch (e) {
                console.error("[studio] sweep: poster failed", String(e));
                pending++;
            }
        }
        return { pending };
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
    pathname === "/library/adopt" ||
    pathname === "/posters/kick";

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

    // GET /studio/recent: the share sheet's saves, for the key the Worker verified (section 14).
    if (request.method === "GET" && p === "/studio/recent") {
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        const res = toResponse(await service.recent(keyId, url.searchParams.get("since"), url.searchParams.get("limit")));
        res.headers.set("cache-control", "no-store");
        return res;
    }

    // POST /studio/upload/adopt: the Worker's own call after PUT /studio/upload
    // stored a video (internal: the public gate answers 404 for this path, and
    // the Worker strips the key id header from clients). The key id header is
    // the caller's, set after the Worker's D1 lookup.
    if (request.method === "POST" && p === "/studio/upload/adopt") {
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        return toResponse(await service.adopt(keyId, await request.text()));
    }

    // POST /posters/kick?limit=N: the Worker's own call (a library read that saw missing
    // posters, POST /library/posters/backfill) or the cron's. Internal like the adopt path:
    // the public gate answers 404 for the path, the key id header is the Worker's word.
    if (request.method === "POST" && p === "/posters/kick") {
        if (!request.headers.get(KEY_ID_HEADER)) return new Response(null, { status: 403 });
        const raw = url.searchParams.get("limit");
        const limit = raw !== null && /^\d{1,4}$/.test(raw) ? Number(raw) : undefined;
        return toResponse(await service.kickPosters(limit));
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
