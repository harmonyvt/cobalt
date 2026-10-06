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
import { Crop, JobRecord, KV, Quality, WebpParams, WebpService, mintId, num, randomBase62, serviceFromUrl } from "./webp";
import { KEY_ID_HEADER } from "./headers";
import { cropToPixels, parseCrop } from "../helper/crop.js";
import { STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "./gate";
import { SERVICE_KEY_ID, insertMediaItem, mediaNameFromUrl, pageLink } from "./library";
import { LIVE_PUSH_MS, type LiveHooks, type LiveRenderEvent } from "./live";
import {
    LINE_BUSY_WAIT_MS,
    LINE_MAX,
    LINE_WAIT_MS,
    LineStore,
    isFocusedKey,
    parseFlag,
    startingFresh,
    type LineEntry,
} from "./line";
import { NOTIFY_MAX_BODY_BYTES, isEmptyLineBody, parseOptIn, type LineOutcome, type NotifyHooks, type NotifyRenderEvent } from "./notify";
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
export const CORS_EXPOSE = "content-range, content-length, accept-ranges, etag, last-modified";

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
    // jobs that run before this save, the one running now included (section 17.4); a number only
    // for a save waiting in the server's line, which then answers `step: "queued"`
    queueAhead?: number | null,
) {
    // progress only means something while the session is saving
    const queued = row.status === "saving" && typeof queueAhead === "number";
    const p = row.status === "saving" && !queued ? (progress ?? null) : null;
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
        step: queued ? "queued" : (p?.step ?? null),
        step_bytes: p?.bytes ?? null,
        step_total: p?.total ?? null,
        waking: p?.waking ?? false,
        queue_ahead: queued ? queueAhead : null,
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

// --- custom titles (section 15.2, shared by POST /studio and the upload) -----------------------------

export const MAX_TITLE_CODE_POINTS = 80;

// U+0000-U+001F, U+007F-U+009F, U+2028, U+2029, and unpaired surrogates (which no
// well-formed JSON text from a client should carry and D1 would mangle).
const BAD_TITLE_CHARS =
    /[\u0000-\u001F\u007F-\u009F\u2028\u2029]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

// The rules of section 15.2: a string or null; trimmed, no control characters, at most 80 code
// points; empty or whitespace = none (null).
export function cleanTitle(raw: unknown): { ok: true; title: string | null } | { ok: false } {
    if (raw === null) return { ok: true, title: null };
    if (typeof raw !== "string") return { ok: false };
    const title = raw.trim();
    if (title === "") return { ok: true, title: null };
    if (BAD_TITLE_CHARS.test(title)) return { ok: false };
    if (Array.from(title).length > MAX_TITLE_CODE_POINTS) return { ok: false };
    return { ok: true, title };
}

// The post's custom title (`media_titles`, post key = a new session's id, or an upload's item id).
export async function upsertTitle(db: D1Database, postKey: string, title: string, keyId: string, now: number): Promise<void> {
    await db
        .prepare(
            `INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(post_key) DO UPDATE SET title = excluded.title, key_id = excluded.key_id, updated_at = excluded.updated_at`,
        )
        .bind(postKey, title, keyId, now)
        .run();
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
        httpEtag?: string;
        uploaded?: Date;
    } | null>;
    // Metadata only (no body): the object's real size, null when it is missing.
    head(key: string): Promise<{
        size: number;
        httpMetadata?: { contentType?: string };
        httpEtag?: string;
        uploaded?: Date;
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
    // started from the server's line (section 17.5): a foreign 429 is waited out for
    // LINE_BUSY_WAIT_MS instead of BUSY_WAIT_MS; `queuedAt` is when it joined
    lined?: boolean;
    queuedAt?: number;
};

// What holds the helper right now (section 17.2). `owner` is an api_keys.id when the record
// itself says (a /webp job, a render being started from the line); else it is looked up.
export type Held = { kind: "save" | "render" | "webp" | "poster"; sid?: string; job?: string; owner?: string | null };
type LineItem = { key: string; entry: LineEntry };
type LineView = { held: Held | null; entries: LineItem[]; waiting: LineItem[] };

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

    // The server's line (section 17): what waits for the helper, in order.
    private line: LineStore;
    // The decisions that would jump the line or lose a job (start the head, cancel, expire) run one
    // at a time; the slow work (a render's upload into the helper) never holds this.
    private lineChain: Promise<unknown> = Promise.resolve();
    // job -> when this Durable Object began uploading that queued render into the helper (in memory
    // only: after an eviction the entry's own `starting` ages out, LINE_START_STALE_MS)
    private startingJobs = new Map<string, number>();
    // poster sweeps running (counted around PosterService.sweep, which runs a job to its end; a count,
    // not a flag, so a later pass ending never clears an earlier poster that is still running)
    private posterRuns = 0;

    // Server-made posters (section 13); undefined when no public bucket is wired.
    private posters?: PosterService;
    // sid -> its public copy is being made right now (in memory only)
    private hosting = new Set<string>();

    constructor(private d: StudioDeps) {
        this.line = new LineStore(d.storage, d.now);
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
                // a poster never cuts what waits: busy while anything holds the helper (its own
                // in-flight flag excluded: this is asked from inside the poster's sweep) or the
                // line is not empty
                helperBusy: async () => (await this.held({ ignorePoster: true })) !== null || (await this.line.size()) > 0,
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
            // a render still waiting in the line is not rendering: the run hears `accepted` when it starts
            if (b.phase === "queued") return;
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
            // a cancelled render (section 17.7) is the owner's own doing: no Hark message, however
            // often it is polled again
            if (b.error.code === "error.webp.cancelled") return;
            e = { kind: "failed", code: b.error.code };
        }
        if (e) {
            const ev = e;
            await this.notifyCall("render", (n) => n.onRender(sid, job, ev));
            await this.settleLine(sid, job, ev.kind === "success" ? { ...ev, kind: "rendered" } : ev);
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

    // ---- the server's line (APP-API-CONTRACT.md section 17) ---------------------------------

    // Runs `fn` after every earlier line decision has finished (never rejects the chain).
    private withLine<T>(fn: () => Promise<T>): Promise<T> {
        const p = this.lineChain.then(fn, fn);
        this.lineChain = p.catch(() => {});
        return p;
    }

    private async settleLine(sid: string, job: string | null, outcome: LineOutcome): Promise<void> {
        await this.notifyCall("line settle", (n) => n.onLineSettle(sid, job, outcome));
    }

    // What holds the helper (17.2): a `save:` record; a render or /webp job record accepted within
    // SWEEP_RENDER_MS with no result yet (durable, unlike the in-memory `encodes`, which is still
    // consulted); a poster in flight; a render entry of the line whose upload is under way.
    // null = the helper is free.
    private async held(opts: { ignorePoster?: boolean } = {}): Promise<Held | null> {
        const now = this.d.now();
        for (const key of (await this.d.storage.list<unknown>({ prefix: "save:" })).keys()) {
            return { kind: "save", sid: key.slice("save:".length) };
        }
        for (const [key, rec] of await this.d.storage.list<JobRecord>({ prefix: "job:" })) {
            if (!rec || now - rec.createdAt >= SWEEP_RENDER_MS) continue;
            const id = key.slice("job:".length);
            if (await this.d.storage.get(`result:${id}`)) continue;
            return rec.keyId.startsWith("studio:")
                ? { kind: "render", sid: rec.keyId.slice("studio:".length), job: id }
                : { kind: "webp", job: id, owner: rec.keyId };
        }
        if (this.encoding()) {
            const [job] = [...this.encodes.keys()];
            return { kind: "render", job };
        }
        if (!opts.ignorePoster && this.posterRuns > 0) return { kind: "poster" };
        for (const { entry } of await this.line.list()) {
            if (await this.uploading(entry, now)) {
                return { kind: "render", sid: entry.sid, job: entry.job ?? undefined, owner: entry.keyId };
            }
        }
        return null;
    }

    // A render entry whose upload into the helper is (presumably) still going on. Once the helper has
    // taken it its `job:` record exists and the entry is only a leftover (the object died before
    // removing it): the pump drops it, and it must not keep the helper "held" until it ages out.
    private async uploading(entry: LineEntry, now: number): Promise<boolean> {
        if (entry.kind !== "render" || !startingFresh(entry, now)) return false;
        return !(entry.job && (await this.d.storage.get(`job:${entry.job}`)));
    }

    // Free for a request = not held AND no entry that would go before it: for a save or an
    // unprioritised render, an empty line; for a focused render, no focused entry.
    private async isFree(focusedRender = false): Promise<boolean> {
        if (await this.held()) return false;
        const entries = await this.line.list();
        return focusedRender ? !entries.some((e) => isFocusedKey(e.key)) : entries.length === 0;
    }

    private async lineView(): Promise<LineView> {
        const held = await this.held();
        const entries = await this.line.list();
        const now = this.d.now();
        // an entry being started IS the running job (`held`), not a waiting one
        const waiting: LineItem[] = [];
        for (const e of entries) if (!(await this.uploading(e.entry, now))) waiting.push(e);
        return { held, entries, waiting };
    }

    // Jobs that run before the entry: the one running now, then the waiting entries ahead of it.
    private aheadOf(view: LineView, key: string): number {
        const i = view.waiting.findIndex((e) => e.key === key);
        return i < 0 ? 0 : (view.held ? 1 : 0) + i;
    }

    // `queue_ahead` of a save waiting in the line; null when it is not (a save that has its `save:`
    // record is started, whatever an entry the pump has not removed yet says).
    private async saveQueueAhead(sid: string): Promise<number | null> {
        const hit = await this.line.find(sid, null);
        if (!hit) return null;
        if (await this.d.storage.get(`save:${sid}`)) return null;
        return this.aheadOf(await this.lineView(), hit.key);
    }

    // A session with a save entry in the line and no `save:` record: it is answered, never stepped
    // (`step()` would build the missing record from the row and start it, jumping the line).
    private async waitingInLine(sid: string): Promise<boolean> {
        if (!(await this.line.find(sid, null))) return false;
        return !(await this.d.storage.get(`save:${sid}`));
    }

    private async dropTitle(sid: string): Promise<void> {
        try {
            await this.d.db.prepare("DELETE FROM media_titles WHERE post_key = ?1").bind(sid).run();
        } catch (e) {
            console.error("[studio] could not drop the title of", sid, String(e));
        }
    }

    // Ending a queued job is two steps so the line lock is never held across a notification: the
    // row is marked first (`markEnd`, D1 only, safe under the lock; it is also what makes a poll that
    // races the removal of the entry see a finished session, never a startable one), then the hooks
    // run (`endHooks`) once the lock is released. A `silent` end is the owner's doing (a cancel, a
    // deleted post): no Hark message, and the line summary drops the member.
    private async markEnd(sid: string, job: string | null, code: string): Promise<boolean> {
        if (job === null) return await this.markError(sid, code);
        try {
            const upd = await this.d.db
                .prepare("UPDATE studio_renders SET status = 'error', error_code = ?1 WHERE id = ?2 AND status = 'pending'")
                .bind(code, job)
                .run();
            return Number(upd.meta?.changes ?? 0) > 0;
        } catch (e) {
            console.error("[studio] could not end the queued render", job, String(e));
            return false;
        }
    }

    private async endHooks(sid: string, job: string | null, code: string, silent: boolean, changed: boolean): Promise<void> {
        if (job === null) {
            await this.dropTitle(sid);
            this.progress.delete(sid);
            await this.liveCall("save failed", (l) => l.onSave(sid, { kind: "failed", code }));
            if (!changed) return;
            if (!silent) await this.notifyCall("save failed", (n) => n.onSaveFailed(sid, code));
            await this.settleLine(sid, null, silent ? { kind: "cancelled" } : { kind: "failed", code });
            return;
        }
        this.encodes.delete(job);
        await this.liveRender(sid, job, { kind: "failed", code });
        if (!changed) return;
        if (!silent) await this.notifyCall("render", (n) => n.onRender(sid, job, { kind: "failed", code }));
        await this.settleLine(sid, job, silent ? { kind: "cancelled" } : { kind: "failed", code });
    }

    // Both steps at once, for callers that do not hold the line lock.
    private async endQueuedSave(sid: string, code: string, silent: boolean): Promise<void> {
        await this.endHooks(sid, null, code, silent, await this.markEnd(sid, null, code));
    }
    private async endQueuedRender(sid: string, job: string, code: string, silent: boolean): Promise<void> {
        await this.endHooks(sid, job, code, silent, await this.markEnd(sid, job, code));
    }

    // Under the line lock: removes the entry and marks its row; returns the hooks to run after the
    // lock is released. `code` / `silent` as for an end; an entry that waited past LINE_WAIT_MS is
    // `error.studio.busy` / `error.webp.busy`.
    private async endEntry(key: string, entry: LineEntry, code: string, silent: boolean): Promise<() => Promise<void>> {
        const job = entry.kind === "render" ? entry.job : null;
        if (entry.kind === "render" && !job) {
            await this.line.remove(key);
            return async () => {};
        }
        const changed = await this.markEnd(entry.sid, job, code);
        await this.line.remove(key);
        return () => this.endHooks(entry.sid, job, code, silent, changed);
    }

    private async expireStale(): Promise<void> {
        const after: Array<() => Promise<void>> = [];
        await this.withLine(async () => {
            const now = this.d.now();
            for (const { key, entry } of await this.line.list()) {
                if (now - entry.at <= LINE_WAIT_MS) continue;
                if (await this.uploading(entry, now)) continue;
                after.push(await this.endEntry(key, entry, entry.kind === "save" ? "error.studio.busy" : "error.webp.busy", false));
            }
        });
        for (const run of after) await run();
    }

    // Starts the head of the line when the helper is free: ONE start per call (17.5). A save gets
    // its `save:` record and is kicked; a render is uploaded into the helper. Entries that cannot
    // run any more (session gone, expired, not saving; render not pending) are dropped, and a
    // render whose start failed for good ends that render and the next entry is looked at.
    async pumpLine(): Promise<void> {
        for (let i = 0; i <= LINE_MAX; i++) {
            if ((await this.pumpOnce()) !== "again") return;
        }
    }

    private async pumpOnce(): Promise<"done" | "again"> {
        let kickSid: string | null = null;
        let start: { key: string; entry: LineEntry; r2Key: string; title: string | null; duration: number | null } | null = null;
        // the hooks of entries that ended in here run after the lock is released
        const after: Array<() => Promise<void>> = [];
        await this.withLine(async () => {
            if (await this.held()) return;
            const now = this.d.now();
            for (const { key, entry } of await this.line.list()) {
                if (now - entry.at > LINE_WAIT_MS) {
                    after.push(await this.endEntry(key, entry, entry.kind === "save" ? "error.studio.busy" : "error.webp.busy", false));
                    continue;
                }
                if (entry.kind === "save") {
                    let row: SessionRow | null;
                    try {
                        row = await getSession(this.d.db, entry.sid);
                    } catch {
                        return; // a D1 blip: the next pass
                    }
                    if (row && row.status === "saving" && row.expires_at <= now) {
                        // its post was deleted while it waited: the row ends, silently (the owner did
                        // it), so the line summary does not wait on it for a day
                        after.push(await this.endEntry(key, entry, "error.studio.expired", true));
                        continue;
                    }
                    if (!row || row.status !== "saving") {
                        await this.line.remove(key);
                        continue;
                    }
                    // started already (a crash between the pump's two writes)
                    if (await this.d.storage.get(`save:${entry.sid}`)) {
                        await this.line.remove(key);
                        continue;
                    }
                    // the record first, THEN the entry goes (a crash in between leaves a started
                    // save and an entry the next pump drops, never a lost save)
                    const rec: SaveRecord = {
                        phase: entry.adopt ? "probing" : "starting",
                        startedAt: now,
                        attempts: 0,
                        lastAdvance: now,
                        lined: true,
                        queuedAt: entry.at,
                    };
                    await this.d.storage.put(`save:${entry.sid}`, rec);
                    await this.line.remove(key);
                    // an adopted upload's first step carries the whole video into the helper: it is
                    // left to the next sweep pass (locked), not run unlocked after a cap
                    kickSid = entry.adopt ? null : entry.sid;
                    return;
                }
                // a render
                const job = entry.job;
                if (!job) {
                    await this.line.remove(key);
                    continue;
                }
                let render: RenderRow | null;
                let session: SessionRow | null;
                try {
                    render = await getRender(this.d.db, entry.sid, job);
                    session = await getSession(this.d.db, entry.sid);
                } catch {
                    return;
                }
                if (!render || render.status !== "pending") {
                    await this.line.remove(key);
                    continue;
                }
                // started already (the helper took it and `job:` was written, then the object died
                // before the entry was removed): it is collected like any running render
                if (await this.d.storage.get(`job:${job}`)) {
                    await this.line.remove(key);
                    continue;
                }
                if (!session || session.expires_at <= now || session.status !== "ready" || !session.r2_key || !entry.render) {
                    // an expired session means its post was deleted: the owner's doing, no message
                    const gone = !session || session.expires_at <= now;
                    after.push(await this.endEntry(key, entry, gone ? "error.studio.expired" : "error.studio.not_ready", gone));
                    continue;
                }
                // an upload this very object began and has not finished: leave it
                if (this.startingJobs.has(job)) return;
                const marked: LineEntry = { ...entry, starting: now };
                await this.line.put(key, marked);
                this.startingJobs.set(job, now);
                start = { key, entry: marked, r2Key: session.r2_key, title: session.title, duration: session.duration };
                return;
            }
        });
        for (const run of after) await run();
        // whatever the pump started must be seen to: the sweep re-arms itself while it runs (an
        // adopted upload has no kick, its first step is the next pass)
        if (kickSid || start) await this.scheduleSweep();
        if (kickSid) await this.kick(kickSid);
        if (start) return await this.startQueuedRender(start);
        return "done";
    }

    // Uploads a queued render into the helper exactly as render() does (17.5 step 3).
    private async startQueuedRender(s: {
        key: string;
        entry: LineEntry;
        r2Key: string;
        title: string | null;
        duration: number | null;
    }): Promise<"done" | "again"> {
        const { key, entry } = s;
        const job = entry.job!;
        const keepAwake = this.d.renew ? setInterval(this.d.renew, 20_000) : undefined;
        let reply;
        try {
            this.d.renew?.();
            reply = await this.d.webp.createFromUpload(
                `studio:${entry.sid}`,
                entry.render!.params,
                async () => {
                    const obj = await this.d.originals.get(s.r2Key);
                    return obj ? { body: obj.body, size: obj.size } : null;
                },
                { id: job },
            );
        } catch (e) {
            console.error("[studio] starting a queued render threw", job, String(e));
            reply = null;
        } finally {
            if (keepAwake !== undefined) clearInterval(keepAwake);
            this.startingJobs.delete(job);
        }
        const body = reply?.body as { status?: string; id?: string; error?: { code?: string } } | undefined;
        if (reply && reply.status === 202 && body?.status === "pending") {
            this.encodes.set(job, this.d.now());
            await this.line.remove(key);
            await this.liveRender(entry.sid, job, { kind: "accepted", title: s.title, duration: s.duration });
            return "done";
        }
        // a foreign 429 (a /webp job or a poster `held()` did not see), a container that could not be
        // reached (503, or 502 error.webp.unavailable) or a call that threw: it stays at the head and
        // the next pass tries again; the 30 min ceiling bounds it. (Nobody is waiting to retry it.)
        const transient =
            !reply ||
            reply.status === 429 ||
            reply.status === 503 ||
            (reply.status === 502 && (body?.error?.code ?? "error.webp.unavailable") === "error.webp.unavailable");
        if (transient) {
            await this.line.put(key, { ...entry, starting: null, attempts: entry.attempts + 1 });
            return "done";
        }
        const code = typeof body?.error?.code === "string" ? body.error.code : "error.webp.unavailable";
        await this.line.remove(key);
        await this.endQueuedRender(entry.sid, job, code, false);
        return "again";
    }

    // One pass of the line for the sweep (before the posters): stale entries end, a save stuck
    // holding the helper is reaped, then the head starts. Returns how many entries still wait (a
    // non-empty line counts as pending, so the sweep re-arms every SWEEP_DELAY_S while anything waits).
    private async lineSweep(): Promise<number> {
        try {
            if ((await this.line.size()) === 0) return 0;
        } catch (e) {
            // storage that cannot list counts as nothing waiting, like the other lists of the sweep
            console.error("[studio] sweep: listing the line failed", String(e));
            return 0;
        }
        await this.expireStale();
        await this.reapOrphans();
        await this.pumpLine();
        // What still waits, plus whatever the pump has just started (it runs at the END of the pass,
        // after the loops that count saves and jobs: without this, the pass that starts the last
        // queued job reports nothing pending and the sweep is never re-armed for it).
        return (await this.line.size()) + ((await this.held()) ? 1 : 0);
    }

    // ---- POST /studio/<sid>/line cancel ---------------------------------------------------------

    private async ownedSession(keyId: string, sid: string): Promise<{ row: SessionRow } | { reply: StudioReply }> {
        let row: SessionRow | null;
        try {
            row = await getSession(this.d.db, sid);
        } catch {
            return { reply: studioErr(503, "error.api.generic") };
        }
        // an unknown session and somebody else's look the same
        if (!row || row.key_id !== keyId) return { reply: studioErr(404, "error.studio.not_found") };
        return { row };
    }

    // DELETE /studio/<sid>/line: cancels the session's queued save (section 17.7).
    async cancelSave(keyId: string, sid: string): Promise<StudioReply> {
        const owned = await this.ownedSession(keyId, sid);
        if ("reply" in owned) return owned.reply;
        // under the line lock the session is marked cancelled BEFORE its entry goes, so a poll that
        // lands in between sees a finished session, never one it could start
        let hooks: (() => Promise<void>) | null = null;
        await this.withLine(async () => {
            const found = await this.line.find(sid, null);
            // started (it has its `save:` record) or no longer saving: not ours to stop
            if (!found || (await this.d.storage.get(`save:${sid}`))) return;
            hooks = await this.endEntry(found.key, found.entry, "error.studio.cancelled", true);
        });
        if (hooks) {
            await (hooks as () => Promise<void>)();
            return { status: 200, body: { status: "success", cancelled: true } };
        }
        // a repeat is the same answer
        let row = owned.row;
        try {
            row = (await getSession(this.d.db, sid)) ?? row;
        } catch {
            // the row read before stands
        }
        if (row.status === "error" && row.error_code === "error.studio.cancelled") {
            return { status: 200, body: { status: "success", cancelled: true } };
        }
        return studioErr(409, "error.studio.started");
    }

    // DELETE /studio/<sid>/render/<job>: cancels a queued render (section 17.7).
    async cancelRender(keyId: string, sid: string, job: string): Promise<StudioReply> {
        const owned = await this.ownedSession(keyId, sid);
        if ("reply" in owned) return owned.reply;
        let render: RenderRow | null;
        try {
            render = await getRender(this.d.db, sid, job);
        } catch {
            return studioErr(503, "error.api.generic");
        }
        if (!render) return studioErr(404, "error.studio.not_found");
        let hooks: (() => Promise<void>) | null = null;
        await this.withLine(async () => {
            const found = await this.line.find(sid, job);
            if (!found || render!.status !== "pending") return;
            // its upload into the helper has begun (or the helper already took it): it runs
            if (startingFresh(found.entry, this.d.now()) || this.startingJobs.has(job)) return;
            if (await this.d.storage.get(`job:${job}`)) return;
            hooks = await this.endEntry(found.key, found.entry, "error.webp.cancelled", true);
        });
        if (hooks) {
            await (hooks as () => Promise<void>)();
            return { status: 200, body: { status: "success", cancelled: true } };
        }
        let now = render;
        try {
            now = (await getRender(this.d.db, sid, job)) ?? render;
        } catch {
            // the row read before stands
        }
        if (now.status === "error" && now.error_code === "error.webp.cancelled") {
            return { status: 200, body: { status: "success", cancelled: true } };
        }
        return studioErr(409, "error.studio.started");
    }

    // ---- GET /studio/line ---------------------------------------------------------------------

    async lineStatus(keyId: string): Promise<StudioReply> {
        let view: LineView;
        try {
            view = await this.lineView();
        } catch {
            return studioErr(503, "error.api.generic");
        }
        const { held, waiting } = view;
        // who owns the running job: a save's or a render's session row, else the record itself
        const sessionRows = new Map<string, { key_id: string | null; link: string | null }>();
        const wanted = new Set<string>();
        for (const { entry } of waiting) if (entry.keyId === keyId) wanted.add(entry.sid);
        if (held?.sid) wanted.add(held.sid);
        let dbOk = true;
        try {
            if (wanted.size > 0) {
                const ids = [...wanted];
                const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
                const { results } = await this.d.db
                    .prepare(`SELECT id, key_id, link FROM studio_sessions WHERE id IN (${marks})`)
                    .bind(...ids)
                    .all<{ id: string; key_id: string | null; link: string | null }>();
                for (const r of results) sessionRows.set(r.id, r);
            }
        } catch {
            dbOk = false;
        }
        const runningOwner: string | null = held?.owner ?? (held?.sid ? (sessionRows.get(held.sid)?.key_id ?? null) : null);
        const names = new Map<string, string>();
        try {
            const ids = new Set<string>();
            if (runningOwner) ids.add(runningOwner);
            for (const { entry } of waiting) ids.add(entry.keyId);
            if (ids.size > 0) {
                const list = [...ids];
                const marks = list.map((_, i) => `?${i + 1}`).join(", ");
                const { results } = await this.d.db
                    .prepare(`SELECT id, name FROM api_keys WHERE id IN (${marks})`)
                    .bind(...list)
                    .all<{ id: string; name: string }>();
                for (const r of results) names.set(r.id, r.name);
            }
        } catch {
            // the answer still comes, with no names
        }
        const nameOf = (id: string | null) => (id && id !== SERVICE_KEY_ID ? (names.get(id) ?? null) : null);

        let running: unknown = null;
        if (held) {
            const mine = runningOwner !== null && runningOwner === keyId && (held.sid !== undefined ? dbOk : true);
            let origin: "share" | null = null;
            if (held.kind === "save" && held.sid && (await this.d.storage.get(`${SHARE_PREFIX}${held.sid}`))) origin = "share";
            running = {
                kind: held.kind,
                mine,
                sid: mine ? (held.sid ?? null) : null,
                job: mine ? (held.job ?? null) : null,
                origin,
                key_name: nameOf(runningOwner),
            };
        }
        const base = held ? 2 : 1;
        const entries = waiting.map(({ key, entry }, i) => {
            const mine = entry.keyId === keyId;
            return {
                position: base + i,
                kind: entry.kind,
                mine,
                sid: mine ? entry.sid : null,
                job: mine ? entry.job : null,
                at: entry.at,
                origin: entry.origin,
                priority: entry.kind === "render" && isFocusedKey(key) ? "focused" : null,
                key_name: nameOf(entry.keyId),
                link: mine ? (sessionRows.get(entry.sid)?.link ?? null) : null,
            };
        });
        return {
            status: 200,
            body: { status: "success", now: this.d.now(), running, entries, max: LINE_MAX, wait_ms: LINE_WAIT_MS },
        };
    }

    // ---- PUT|DELETE /studio/line/notify (the line summary, section 17.8) -------------------------

    // What the key has in flight: its line entries, its sessions with a `save:` record and the
    // unfinished render jobs of its sessions.
    private async lineMembers(keyId: string): Promise<string[]> {
        const members = new Set<string>();
        for (const { entry } of await this.line.list()) {
            if (entry.keyId === keyId) members.add(entry.kind === "save" || !entry.job ? entry.sid : `${entry.sid}:${entry.job}`);
        }
        for (const key of (await this.d.storage.list<unknown>({ prefix: "save:" })).keys()) {
            const sid = key.slice("save:".length);
            const row = await getSession(this.d.db, sid);
            if (row && row.key_id === keyId && row.status === "saving") members.add(sid);
        }
        const now = this.d.now();
        for (const [key, rec] of await this.d.storage.list<JobRecord>({ prefix: "job:" })) {
            if (!rec || !rec.keyId.startsWith("studio:") || now - rec.createdAt > SWEEP_RENDER_MS) continue;
            const id = key.slice("job:".length);
            if (await this.d.storage.get(`result:${id}`)) continue;
            const sid = rec.keyId.slice("studio:".length);
            const row = await getSession(this.d.db, sid);
            if (row && row.key_id === keyId) members.add(`${sid}:${id}`);
        }
        return [...members];
    }

    async lineNotifyPut(keyId: string, rawBody: string): Promise<StudioReply> {
        if (!isEmptyLineBody(rawBody)) return studioErr(400, "error.notify.invalid");
        const notify = this.d.notify as (NotifyHooks & { putLine?: unknown }) | undefined;
        if (!notify || typeof notify.putLine !== "function") {
            // no Hark service in this Durable Object: nothing stored, nothing will be sent
            return { status: 200, body: { status: "success", bridge: false, watching: 0, expires_at: null } };
        }
        let members: string[];
        try {
            members = await this.lineMembers(keyId);
        } catch {
            return studioErr(503, "error.api.generic");
        }
        const put = notify as unknown as { putLine(keyId: string, members: string[]): Promise<StudioReply> };
        try {
            return await raceCeiling(put.putLine(keyId, members), this.d.notifyMs ?? NOTIFY_CALL_MS, "notify line");
        } catch {
            return studioErr(503, "error.api.generic");
        }
    }

    async lineNotifyDelete(keyId: string): Promise<StudioReply> {
        const notify = this.d.notify as { removeLine?: (keyId: string) => Promise<StudioReply> } | undefined;
        if (!notify || typeof notify.removeLine !== "function") return { status: 204, body: null };
        try {
            await raceCeiling(notify.removeLine(keyId), this.d.notifyMs ?? NOTIFY_CALL_MS, "notify line");
        } catch {
            return studioErr(503, "error.api.generic");
        }
        return { status: 204, body: null };
    }

    // ---- POST /studio ------------------------------------------------------------

    async create(keyId: string, rawBody: string): Promise<StudioReply> {
        let link: string | null = null;
        let publicFlag: unknown;
        let originField: unknown;
        let notifyField: unknown;
        let queueField: unknown;
        let titleField: unknown;
        try {
            if (rawBody.length <= MAX_BODY_BYTES) {
                const parsed = JSON.parse(rawBody);
                if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
                    link = linkFrom((parsed as { url?: unknown }).url);
                    publicFlag = (parsed as { public?: unknown }).public;
                    originField = (parsed as { origin?: unknown }).origin;
                    notifyField = (parsed as { notify?: unknown }).notify;
                    queueField = (parsed as { queue?: unknown }).queue;
                    titleField = (parsed as { title?: unknown }).title;
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
        // `queue: true` (section 17.3): wait in the server's line instead of the `429`. A share
        // sheet has no one to retry a refusal, so `origin: "share"` implies it.
        const queueFlag = parseFlag(queueField);
        if (queueFlag === null) return studioErr(400, "error.studio.invalid_params");
        const wantsQueue = queueFlag || fromShare;
        // `title` (section 17.3): the rules of section 15.2, judged before anything is created
        let title: string | null = null;
        if (titleField !== undefined) {
            const t = cleanTitle(titleField);
            if (!t.ok) return studioErr(400, "error.library.bad_title");
            title = t.title;
        }

        await this.posters?.idle(this.d.posterIdleMs);
        await this.reapOrphans();
        // Free = the helper is not held and nobody waits ahead (section 17.2). Not free: a client that
        // did not ask to queue gets today's 429 (while anything waits too, so it never jumps the
        // line); a client that did, waits in the line (also a share, which is never refused). The
        // check, the row and the claim (a `save:` record, or the line entry) are one step.
        const claim = await this.claimSlot({
            keyId,
            wantsQueue,
            busyCode: "error.studio.busy",
            adopt: false,
            origin: fromShare ? "share" : null,
            insert: async (sid, now) => {
                await this.d.db
                    .prepare(
                        "INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at, public_state) VALUES (?1, ?2, ?3, ?4, 'saving', ?5, ?6, ?7)",
                    )
                    .bind(sid, keyId, link, serviceFromUrl(link), now, now + SESSION_TTL_MS, wantsPublic ? "pending" : null)
                    .run();
            },
        });
        if (!claim.ok) return claim.reply;
        const { sid, now, free } = claim;
        // the custom title is written at once (a row with no live file shows nowhere, section 15.3);
        // it is deleted when the save fails or is cancelled. Best effort.
        if (title !== null) {
            try {
                await upsertTitle(this.d.db, sid, title, keyId, now);
            } catch (e) {
                console.error("[studio] could not store the title", sid, String(e));
            }
        }
        if (fromShare) await this.rememberShare(keyId, sid, now);
        // The opt-in goes in before the save can move, so even an instant save is announced.
        const notifyBody = optIn === null ? undefined : await this.optInAtCreate(keyId, sid, optIn);

        // Not free: the save is in the line (no `save:` record, no kick): the sweep starts it when
        // its turn comes, polled or not.
        const ahead = claim.ahead;
        if (!free) {
            await this.scheduleSweep();
        } else {
            // Nothing runs after this response: the save only moves while the
            // studio page polls GET /studio/<sid> (-> advance), or the job sweep
            // (scheduled below) runs. Try once now to have the helper accept the
            // fetch, but never hold the 201 for long.
            await this.scheduleSweep();
            await this.kick(sid, fromShare ? SHARE_KICK_MS : undefined);
        }

        const base = this.d.webBaseUrl.replace(/\/+$/, "");
        return {
            status: 201,
            body: {
                status: "success",
                id: sid,
                url: `${base}/studio/${sid}`,
                // only for a caller that opted in (a share, or `queue: true`): the rest see today's shape
                ...(wantsQueue ? { queued: !free, queue_ahead: ahead } : {}),
                ...(notifyBody ? { notify: notifyBody } : {}),
            },
        };
    }

    // The free check, the session row and the claim are ONE step under the line lock: two creates
    // that both find the helper free would otherwise both take the free path (the check and the
    // `save:` record used to be split by a D1 insert). Free: the row and the `save:` record. Not
    // free and queuing: the row and a line entry. Otherwise a refusal, with nothing created.
    private async claimSlot(o: {
        keyId: string;
        wantsQueue: boolean;
        busyCode: string;
        adopt: boolean;
        origin: "share" | null;
        insert: (sid: string, now: number) => Promise<void>;
    }): Promise<
        | { ok: true; sid: string; now: number; free: boolean; ahead: number | null }
        | { ok: false; reply: StudioReply }
    > {
        const sid = mintSid(this.d.randomBytes);
        const now = this.d.now();
        type Out = { kind: "refused"; code: string } | { kind: "failed" } | { kind: "free" } | { kind: "queued"; key: string };
        const out = await this.withLine(async (): Promise<Out> => {
            const free = await this.isFree();
            if (!free) {
                if (!o.wantsQueue) return { kind: "refused", code: o.busyCode };
                if ((await this.line.size()) >= LINE_MAX) return { kind: "refused", code: "error.studio.line_full" };
            }
            try {
                await o.insert(sid, now);
            } catch {
                return { kind: "failed" };
            }
            if (free) {
                try {
                    const rec: SaveRecord = { phase: o.adopt ? "probing" : "starting", startedAt: now, attempts: 0, lastAdvance: now };
                    await this.d.storage.put(`save:${sid}`, rec);
                } catch {
                    // step() starts the save from the D1 row when there is no record
                }
                return { kind: "free" };
            }
            const q = await this.line.enqueue(
                { kind: "save", sid, job: null, keyId: o.keyId, at: now, origin: o.origin, adopt: o.adopt, render: null },
                false,
            );
            if ("full" in q) {
                await this.undoCreate(sid);
                return { kind: "refused", code: "error.studio.line_full" };
            }
            return { kind: "queued", key: q.key };
        });
        if (out.kind === "refused") return { ok: false, reply: await this.refuse(out.code) };
        if (out.kind === "failed") return { ok: false, reply: studioErr(503, "error.api.generic") };
        if (out.kind === "free") return { ok: true, sid, now, free: true, ahead: null };
        return { ok: true, sid, now, free: false, ahead: this.aheadOf(await this.lineView(), out.key) };
    }

    // A refusal while the line is not empty also arms the sweep: if its chain ever died (an eviction
    // between two passes), the next client that is turned away restarts it.
    private async refuse(code: string, status = 429): Promise<StudioReply> {
        try {
            if ((await this.line.size()) > 0) await this.scheduleSweep();
        } catch {
            // the refusal stands
        }
        return studioErr(status, code);
    }

    // Adds an entry to the line and answers how many jobs run before it (the one running now
    // included); null = the line is full. The count and the write are one step.
    private async joinLine(e: Omit<LineEntry, "starting" | "attempts">, focused: boolean): Promise<number | null> {
        const q = await this.withLine(() => this.line.enqueue(e, focused));
        if ("full" in q) return null;
        return this.aheadOf(await this.lineView(), q.key);
    }

    // A session row that never got into the line (it was full): as if it had not been created.
    private async undoCreate(sid: string): Promise<void> {
        try {
            await this.d.db.prepare("DELETE FROM studio_sessions WHERE id = ?1").bind(sid).run();
        } catch (e) {
            console.error("[studio] could not undo a refused create", sid, String(e));
        }
        await this.dropTitle(sid);
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
                sessions.push(
                    sessionBody(
                        row,
                        [],
                        this.progress.get(row.id),
                        await sessionItem(this.d.db, row.r2_key),
                        row.status === "saving" ? await this.saveQueueAhead(row.id) : null,
                    ),
                );
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
        if (changed) {
            await this.notifyCall("save failed", (n) => n.onSaveFailed(sid, code));
            // a failed save leaves no title behind (section 17.3), and settles the line summary
            await this.dropTitle(sid);
            await this.settleLine(sid, null, { kind: "failed", code });
        }
        return POLL_INTERVAL_MS;
    }

    // ---- GET /studio/<sid>/advance?wait=N (internal, called by the Worker) ---------------

    private async sessionReply(row: SessionRow): Promise<StudioReply> {
        try {
            const renders = row.status === "ready" ? await listSuccessfulRenders(this.d.db, row.id) : [];
            const ahead = row.status === "saving" ? await this.saveQueueAhead(row.id) : null;
            return {
                status: 200,
                body: sessionBody(row, renders, this.progress.get(row.id), await sessionItem(this.d.db, row.r2_key), ahead),
            };
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

            // Waiting in the server's line: answered (`step: "queued"`), never stepped. A step would
            // build the missing `save:` record from the row and start it: the first poll would jump
            // the line (section 17.5). The long-poll waits for the sweep to start it.
            if (await this.waitingInLine(sid)) {
                const remaining = deadline - this.d.now();
                if (remaining <= 0) return this.sessionReply(row);
                await this.d.sleep(Math.min(remaining, POLL_INTERVAL_MS));
                continue;
            }

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
        // in the server's line, not started: never stepped (every path to a step, a poll, the kick
        // and the sweep, comes through here)
        try {
            if (!rec && (await this.line.find(sid, null))) return POLL_INTERVAL_MS;
        } catch {
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
                if (this.d.now() - since >= (rec.lined ? LINE_BUSY_WAIT_MS : BUSY_WAIT_MS)) {
                    return await this.fail(sid, "error.studio.busy");
                }
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
            await this.settleLine(sid, null, { kind: "saved" });
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
    async adopt(keyId: string, rawBody: string, opts: { allowQueue?: boolean } = {}): Promise<StudioReply> {
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
        // `queue: true` (section 17.3, from `?queue=1`): join the line when the helper is not free.
        // The web Worker's /library/adopt never queues.
        const queueFlag = parseFlag(b.queue);
        if (queueFlag === null) return invalid();
        const wantsQueue = queueFlag && opts.allowQueue !== false;
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
        // the free check, the row and the claim are one step (see claimSlot)
        const claim = await this.claimSlot({
            keyId,
            wantsQueue,
            busyCode: "error.studio.busy",
            adopt: true,
            origin: null,
            insert: async (sid, now) => {
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
            },
        });
        if (!claim.ok) return claim.reply;
        const { sid, free, ahead } = claim;
        await this.scheduleSweep();

        const base = this.d.webBaseUrl.replace(/\/+$/, "");
        return {
            status: 201,
            body: {
                status: "success",
                id: sid,
                url: `${base}/studio/${sid}`,
                ...(wantsQueue ? { queued: !free, queue_ahead: ahead } : {}),
            },
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
            if (this.d.now() - since >= (rec.lined ? LINE_BUSY_WAIT_MS : BUSY_WAIT_MS)) {
                return await this.fail(sid, "error.studio.busy");
            }
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
        if (Number(ready.meta?.changes ?? 0) > 0) {
            await this.settleLine(sid, null, { kind: "saved" });
            await this.afterReady(sid, row.public_state === "pending", key);
        }
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
        // `queue` and `priority` (section 17.3): wait in the line instead of the 429; the render the
        // owner asked for from the screen is `"priority": "focused"`, which needs `queue`.
        const queueFlag = parseFlag(isPlainObject(parsed) ? parsed.queue : undefined);
        if (queueFlag === null) return studioErr(400, "error.webp.invalid_params");
        const priority = isPlainObject(parsed) ? parsed.priority : undefined;
        if (priority !== undefined && priority !== null && priority !== "focused") return studioErr(400, "error.webp.invalid_params");
        if (priority === "focused" && !queueFlag) return studioErr(400, "error.webp.invalid_params");
        const focused = priority === "focused";
        const check = validateRender(parsed, { duration: row.duration, width: row.width, height: row.height });
        if (!check.ok) return studioErr(check.status, check.code);
        const p = check.params;

        await this.posters?.idle(this.d.posterIdleMs);
        await this.reapOrphans();
        // the helper is held (one job at a time), or somebody waits ahead of this render
        const free = await this.isFree(focused);

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
        const joinOpts = { sid, row, params, p, focused, notifyFlag: notifyFlag === true };
        if (!free) {
            if (!queueFlag) return await this.refuse("error.webp.busy");
            return await this.enqueueRender(joinOpts);
        }
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
        // a 429 from the helper that `held()` did not see (a /webp job, a poster): a client that
        // asked to queue never sees it, the render waits in the line instead
        if (reply.status === 429 && queueFlag) return await this.enqueueRender(joinOpts);
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
        return { status: 202, body: { status: "pending", job, ...(queueFlag ? { queued: false, queue_ahead: null } : {}) } };
    }

    // A render that waits: its id is minted here, its row inserted `pending` as on the free path, its
    // `notify` opt-in registered now, and the entry carries the validated params (17.3).
    private async enqueueRender(o: {
        sid: string;
        row: SessionRow;
        params: WebpParams;
        p: RenderParams;
        focused: boolean;
        notifyFlag: boolean;
    }): Promise<StudioReply> {
        if ((await this.line.size()) >= LINE_MAX) return studioErr(429, "error.studio.line_full");
        const job = mintId(this.d.randomBytes);
        const now = this.d.now();
        try {
            await this.d.db
                .prepare(
                    "INSERT INTO studio_renders (id, session_id, status, start, length, width, quality, created_at) VALUES (?1, ?2, 'pending', ?3, ?4, ?5, ?6, ?7)",
                )
                .bind(job, o.sid, o.p.start, o.p.length, o.p.effectiveWidth, o.p.quality, now)
                .run();
        } catch {
            return studioErr(503, "error.api.generic");
        }
        if (o.notifyFlag) await this.notifyCall("render opt-in", (n) => n.optInJob(o.sid, job));
        const joined = await this.joinLine(
            {
                kind: "render",
                sid: o.sid,
                job,
                // the render route is a capability URL (no key): the session's owner is who asked
                keyId: o.row.key_id ?? "",
                at: now,
                origin: null,
                adopt: false,
                render: {
                    params: o.params,
                    effectiveWidth: o.p.effectiveWidth,
                    quality: o.p.quality,
                    start: o.p.start,
                    length: o.p.length,
                },
            },
            o.focused,
        );
        if (joined === null) {
            try {
                await this.d.db.prepare("DELETE FROM studio_renders WHERE id = ?1").bind(job).run();
            } catch {
                // a pending row with no entry: the sweep never starts it and the client's poll sees job_lost
            }
            return studioErr(429, "error.studio.line_full");
        }
        await this.scheduleSweep();
        return { status: 202, body: { status: "pending", job, queued: true, queue_ahead: joined } };
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

        // A render waiting in the line has no `job:` record: webp.status would answer 404, which
        // this method turns into error.webp.job_lost. Answered here first (section 17.5).
        // (An entry whose `job:` record exists was taken by the helper: the object died before the
        // entry was removed. It is a running render, collected below, never "queued" for ever.)
        const waiting = (await this.d.storage.get(`job:${job}`)) ? null : await this.line.find(sid, job);
        if (waiting) {
            const ahead = startingFresh(waiting.entry, this.d.now()) ? 0 : this.aheadOf(await this.lineView(), waiting.key);
            return {
                status: 200,
                body: { status: "pending", job, phase: "queued", frames_done: null, frames_total: null, queue_ahead: ahead },
            };
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
                    queue_ahead: null,
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
                // A lined save that is still waiting for the helper to take it (a foreign 429) has no
                // fetch yet: its budget is its own busy wait (LINE_BUSY_WAIT_MS from the first 429),
                // not the download budget counted from the pump's start.
                const waitingBusy = !!rec?.lined && rec.busySince !== undefined && rec.phase !== "fetching";
                const started = waitingBusy ? rec!.busySince! : (rec?.startedAt ?? rec?.createdAt ?? 0);
                const budget = waitingBusy ? LINE_BUSY_WAIT_MS : SAVE_BUDGET_MS;
                if (now - started > budget + SWEEP_SAVE_SLACK_MS) continue;
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

        // the line (section 17.5): start the head when the helper is free; what still waits is pending,
        // so the sweep re-arms every SWEEP_DELAY_S for as long as anything does
        try {
            pending += await raceCeiling(this.lineSweep(), itemMs, "sweep of the line");
        } catch (e) {
            console.error("[studio] sweep: the line failed", String(e));
            pending++;
        }

        // posters: one per pass, only while nothing else needs the helper (the poster service
        // checks that itself and counts what is still queued)
        if (this.posters) {
            try {
                // in flight until the job ends, even when this pass stops waiting for it
                this.posterRuns++;
                const run = this.posters.sweep();
                const done = () => {
                    this.posterRuns--;
                };
                void run.then(done, done);
                pending += await raceCeiling(run, itemMs, "sweep of posters");
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
    r.status === 204
        ? new Response(null, { status: 204 })
        : new Response(JSON.stringify(r.body), {
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

    // The server's line (section 17): GET /studio/line, PUT|DELETE /studio/line/notify. The key id
    // header is the Worker's word (403 without it); the library-service key id is a 404.
    if (p === "/studio/line" || p === "/studio/line/notify") {
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        if (keyId === SERVICE_KEY_ID) return new Response(null, { status: 404 });
        if (p === "/studio/line" && request.method === "GET") {
            const res = toResponse(await service.lineStatus(keyId));
            res.headers.set("cache-control", "no-store");
            return res;
        }
        if (p === "/studio/line/notify" && request.method === "DELETE") return toResponse(await service.lineNotifyDelete(keyId));
        if (p === "/studio/line/notify" && request.method === "PUT") {
            const declared = Number(request.headers.get("content-length"));
            if (Number.isFinite(declared) && declared > NOTIFY_MAX_BODY_BYTES) return toResponse(studioErr(400, "error.notify.invalid"));
            const text = await request.text();
            if (new TextEncoder().encode(text).length > NOTIFY_MAX_BODY_BYTES) return toResponse(studioErr(400, "error.notify.invalid"));
            return toResponse(await service.lineNotifyPut(keyId, text));
        }
        return new Response(null, { status: 404 });
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
        return toResponse(await service.adopt(SERVICE_KEY_ID, await request.text(), { allowQueue: false }));
    }

    const parts = p.split("/"); // "", "studio", sid, "render", job?
    // GET /studio/<sid>/advance?wait=N: internal, only the Worker's forward for a
    // saving session reaches it (the public gate answers 404 for this subpath).
    if (request.method === "GET" && parts.length === 4 && parts[1] === "studio" && parts[3] === "advance") {
        const sid = parts[2];
        if (!STUDIO_SID_REGEX.test(sid)) return toResponse(studioErr(404, "error.studio.not_found"));
        return toResponse(await service.advance(sid, parseStudioWait(url.searchParams.get("wait"))));
    }
    // DELETE /studio/<sid>/line and DELETE /studio/<sid>/render/<job>: cancel what has not started
    // (section 17.7). Keyed, the creating key only; the service key id and a missing key id are refused.
    if (request.method === "DELETE" && parts[1] === "studio" && (parts.length === 4 ? parts[3] === "line" : parts.length === 5 && parts[3] === "render")) {
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        if (keyId === SERVICE_KEY_ID) return new Response(null, { status: 404 });
        const sid = parts[2];
        if (!STUDIO_SID_REGEX.test(sid)) return toResponse(studioErr(404, "error.studio.not_found"));
        if (parts.length === 4) return toResponse(await service.cancelSave(keyId, sid));
        const job = parts[4];
        if (!STUDIO_JOB_REGEX.test(job)) return toResponse(studioErr(404, "error.studio.not_found"));
        return toResponse(await service.cancelRender(keyId, sid, job));
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
