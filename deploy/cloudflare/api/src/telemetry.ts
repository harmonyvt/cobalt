// Crash and log telemetry from the native app (../TELEMETRY-CONTRACT.md, pinned).
// `POST /telemetry` is answered by the Worker from D1 and R2 only: the container
// and the Durable Object are never involved. Free of Cloudflare imports (like
// app-routes.ts), so it runs under plain node in the tests.
//
//   POST /telemetry   a batch of events and crashes (keyed, no CORS)
//   cron (daily)      runTelemetryRetention(): delete rows and R2 objects past 30 days

import type { OriginalsBucket } from "./studio";

export const MAX_BODY_BYTES = 256 * 1024;
export const MAX_EVENTS = 500;
export const MAX_CRASHES = 10;
export const MAX_MSG_CHARS = 300;
export const MAX_DATA_KEYS = 20;
export const MAX_DATA_KEY_CHARS = 64;
export const MAX_BATCHES_PER_MINUTE = 60;
export const RATE_WINDOW_MS = 60_000;
export const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

export const LEVELS = ["debug", "info", "warn", "error"] as const;
export const CATS = ["app", "pipeline", "upload", "share", "photos", "sync", "net", "store", "ui", "live"] as const;
export const KINDS = ["crash", "hang", "cpu", "disk", "launch", "unclean_exit"] as const;
export const PLATFORMS = ["ios", "macos"] as const;
export const PROCESSES = ["app", "share", "widgets"] as const;

export type Level = (typeof LEVELS)[number];
export type Cat = (typeof CATS)[number];
export type Kind = (typeof KINDS)[number];

export const CRASH_KEY_PREFIX = "telemetry/crashes/";

// Rows per INSERT: 14 bound parameters each, D1 allows 100 per statement.
const EVENT_ROWS_PER_STATEMENT = 7;
// Statements per db.batch() call.
const STATEMENTS_PER_BATCH = 50;

// ---- rate limit ----------------------------------------------------------------------

// Fixed one-minute window per key id, held IN THE ISOLATE'S MEMORY (not D1). It is
// a brake on a runaway client, not an exact quota: a second isolate has its own
// counters, so the effective ceiling for one key is 60 per minute per isolate. At
// one owner and one app that is plenty accurate, and it costs no D1 write.
export class RateLimiter {
    private windows = new Map<string, { start: number; n: number }>();
    constructor(
        private max = MAX_BATCHES_PER_MINUTE,
        private windowMs = RATE_WINDOW_MS,
    ) {}

    // Counts this attempt. ok=false when it is over the limit; retryAfterS says
    // when the window ends.
    hit(key: string, now: number): { ok: boolean; retryAfterS: number } {
        if (this.windows.size > 256) {
            for (const [k, w] of this.windows) if (now - w.start >= this.windowMs) this.windows.delete(k);
        }
        let w = this.windows.get(key);
        if (!w || now - w.start >= this.windowMs || now < w.start) {
            w = { start: now, n: 0 };
            this.windows.set(key, w);
        }
        w.n++;
        return {
            ok: w.n <= this.max,
            retryAfterS: Math.max(1, Math.ceil((w.start + this.windowMs - now) / 1000)),
        };
    }

    reset() {
        this.windows.clear();
    }
}

const defaultLimiter = new RateLimiter();
export const resetTelemetryRateLimits = () => defaultLimiter.reset();

// ---- types ---------------------------------------------------------------------------

export type TelemetryDeps = {
    db: D1Database;
    // The private bucket cobalt-originals. Only put (a JSON string) and delete are used.
    originals: Pick<OriginalsBucket, "put" | "delete">;
    now: () => number;
    limiter?: RateLimiter;
};

export type TelemetryReply = {
    status: number;
    body: unknown;
    headers?: Record<string, string>;
};

type Flat = Record<string, string | number | boolean>;
export type TelemetryEvent = { ts: number; level: Level; cat: Cat; msg: string; data: Flat | null };
type AppInfo = {
    version: string;
    build: string;
    platform: string;
    os: string | null;
    device: string | null;
    process: string;
};
type Crash = {
    ts: number;
    kind: Kind;
    summary: string;
    payload: Record<string, unknown> | null;
    events: TelemetryEvent[];
};
type Batch = { app: AppInfo; install: string; events: TelemetryEvent[]; crashes: Crash[] };

const err = (status: number, code: string, headers?: Record<string, string>): TelemetryReply => ({
    status,
    body: { status: "error", error: { code } },
    ...(headers ? { headers } : {}),
});

class Invalid extends Error {}
const invalid = (why: string): never => {
    throw new Invalid(why);
};

// ---- parsing -------------------------------------------------------------------------

const isObject = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

// A secret must never be stored even if the app logs one by accident: an
// `Authorization: Api-Key <key>` line or a bearer token is blanked.
const SECRET_RE = /\b(api-key|bearer)\s+[A-Za-z0-9._~+/=-]+/gi;
export const redact = (s: string): string => s.replace(SECRET_RE, "$1 [redacted]");

const clip = (s: string, n: number) => (s.length > n ? Array.from(s).slice(0, n).join("") : s);
const text = (s: string, n = MAX_MSG_CHARS) => redact(clip(s, n));

const enumOf = <T extends string>(v: unknown, list: readonly T[], what: string): T =>
    typeof v === "string" && (list as readonly string[]).includes(v) ? (v as T) : invalid(what);

function parseTs(v: unknown, what: string): number {
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1e14) return invalid(what);
    return Math.floor(v);
}

// A flat map of string/number/bool: more than 20 keys, values of any other type
// and long strings are trimmed rather than rejected (a log line must not lose its
// whole batch over one odd value).
function parseData(v: unknown): Flat | null {
    if (v === undefined || v === null) return null;
    if (!isObject(v)) return invalid("data");
    const out: Flat = {};
    let n = 0;
    for (const [k, val] of Object.entries(v)) {
        if (n >= MAX_DATA_KEYS) break;
        if (typeof val === "string") out[clip(k, MAX_DATA_KEY_CHARS)] = text(val);
        else if (typeof val === "number" && Number.isFinite(val)) out[clip(k, MAX_DATA_KEY_CHARS)] = val;
        else if (typeof val === "boolean") out[clip(k, MAX_DATA_KEY_CHARS)] = val;
        else continue;
        n++;
    }
    return n > 0 ? out : null;
}

function parseEvent(v: unknown): TelemetryEvent {
    if (!isObject(v)) return invalid("event");
    if (typeof v.msg !== "string") return invalid("msg");
    return {
        ts: parseTs(v.ts, "ts"),
        level: enumOf(v.level, LEVELS, "level"),
        cat: enumOf(v.cat, CATS, "cat"),
        msg: text(v.msg),
        data: parseData(v.data),
    };
}

function parseEvents(v: unknown, max: number): TelemetryEvent[] {
    if (v === undefined || v === null) return [];
    if (!Array.isArray(v) || v.length > max) return invalid("events");
    return v.map(parseEvent);
}

const optString = (v: unknown, n: number): string | null => {
    if (v === undefined || v === null) return null;
    if (typeof v !== "string") return invalid("string");
    return clip(v, n);
};

function parseApp(v: unknown): AppInfo {
    if (!isObject(v)) return invalid("app");
    const str = (x: unknown) => (typeof x === "string" && x.length > 0 && x.length <= 32 ? x : invalid("app field"));
    // build may arrive as a number (CFBundleVersion is often numeric)
    const build = typeof v.build === "number" && Number.isFinite(v.build) ? String(v.build) : str(v.build);
    return {
        version: str(v.version),
        build,
        platform: enumOf(v.platform, PLATFORMS, "platform"),
        os: optString(v.os, 64),
        device: optString(v.device, 64),
        process: enumOf(v.process, PROCESSES, "process"),
    };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseCrash(v: unknown): Crash {
    if (!isObject(v)) return invalid("crash");
    if (typeof v.summary !== "string") return invalid("summary");
    let payload: Record<string, unknown> | null = null;
    if (v.payload !== undefined && v.payload !== null) {
        if (!isObject(v.payload)) return invalid("payload");
        payload = v.payload;
    }
    return {
        ts: parseTs(v.ts, "ts"),
        kind: enumOf(v.kind, KINDS, "kind"),
        summary: text(v.summary),
        payload,
        events: parseEvents(v.events, MAX_EVENTS),
    };
}

export function parseBatch(raw: unknown): Batch {
    if (!isObject(raw)) return invalid("body");
    if (typeof raw.install !== "string" || !UUID_RE.test(raw.install)) return invalid("install");
    const crashes = raw.crashes === undefined || raw.crashes === null ? [] : raw.crashes;
    if (!Array.isArray(crashes) || crashes.length > MAX_CRASHES) return invalid("crashes");
    return {
        app: parseApp(raw.app),
        install: raw.install.toLowerCase(),
        events: parseEvents(raw.events, MAX_EVENTS),
        crashes: crashes.map(parseCrash),
    };
}

// ---- reading the body ----------------------------------------------------------------

// All of a stream, or null as soon as it passes `max` bytes (the rest is cancelled).
async function readCapped(stream: ReadableStream<Uint8Array> | null, max: number): Promise<Uint8Array | null> {
    if (!stream) return new Uint8Array(0);
    const reader = stream.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > max) {
            await reader.cancel().catch(() => {});
            return null;
        }
        chunks.push(value);
    }
    const out = new Uint8Array(total);
    let o = 0;
    for (const c of chunks) (out.set(c, o), (o += c.byteLength));
    return out;
}

// gunzip with the same ceiling on the INFLATED size (a small gzip can be huge).
// Read and write run together: the writable side would stall on backpressure
// otherwise. A bad stream throws.
async function gunzipCapped(bytes: Uint8Array, max: number): Promise<Uint8Array | null> {
    const ds = new DecompressionStream("gzip");
    const writer = ds.writable.getWriter();
    const writing = writer
        .write(bytes as unknown as Uint8Array<ArrayBuffer>)
        .then(() => writer.close())
        .catch(() => {});
    try {
        return await readCapped(ds.readable, max);
    } finally {
        await writing;
    }
}

// ---- storing -------------------------------------------------------------------------

const hex = (buf: ArrayBuffer) =>
    [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Deterministic id: the same event or crash sent twice (a retry after a lost
// response) lands on the same row and is ignored the second time.
async function stableId(parts: unknown[]): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(parts)));
    return hex(digest).slice(0, 24);
}

const isoDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);
export const crashKey = (ts: number, id: string) => `${CRASH_KEY_PREFIX}${isoDay(ts)}/${id}.json`;

const EVENT_COLUMNS =
    "id, key_id, install, ts, level, cat, msg, data, version, build, platform, device, process, received_at";

async function storeBatch(d: TelemetryDeps, b: Batch, keyId: string): Promise<void> {
    const received = d.now();
    const a = b.app;

    // Crashes first: the JSON object goes into R2, then the row that points at it,
    // so no row ever names a missing object.
    const crashStatements: D1PreparedStatement[] = [];
    for (const c of b.crashes) {
        const id = await stableId([b.install, c.ts, c.kind, c.summary]);
        const key = crashKey(c.ts, id);
        await d.originals.put(
            key,
            JSON.stringify({
                id,
                install: b.install,
                ts: c.ts,
                kind: c.kind,
                summary: c.summary,
                app: a,
                received_at: received,
                payload: c.payload,
                events: c.events,
            }),
            { httpMetadata: { contentType: "application/json" }, customMetadata: { kind: c.kind } },
        );
        crashStatements.push(
            d.db
                .prepare(
                    "INSERT OR IGNORE INTO telemetry_crashes (id, key_id, install, ts, kind, summary, r2_key, version, build, platform, device, process, received_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                )
                .bind(id, keyId, b.install, c.ts, c.kind, c.summary, key, a.version, a.build, a.platform, a.device, a.process, received),
        );
    }

    const rows: (string | number | null)[][] = [];
    for (const e of b.events) {
        const data = e.data ? JSON.stringify(e.data) : null;
        const id = await stableId([b.install, e.ts, e.level, e.cat, e.msg, data]);
        rows.push([id, keyId, b.install, e.ts, e.level, e.cat, e.msg, data, a.version, a.build, a.platform, a.device, a.process, received]);
    }
    const eventStatements: D1PreparedStatement[] = [];
    for (let i = 0; i < rows.length; i += EVENT_ROWS_PER_STATEMENT) {
        const chunk = rows.slice(i, i + EVENT_ROWS_PER_STATEMENT);
        const placeholders = chunk.map(() => `(${EVENT_COLUMNS.split(",").map(() => "?").join(", ")})`).join(", ");
        eventStatements.push(
            d.db.prepare(`INSERT OR IGNORE INTO telemetry_events (${EVENT_COLUMNS}) VALUES ${placeholders}`).bind(...chunk.flat()),
        );
    }

    const all = [...crashStatements, ...eventStatements];
    for (let i = 0; i < all.length; i += STATEMENTS_PER_BATCH) {
        await d.db.batch(all.slice(i, i + STATEMENTS_PER_BATCH));
    }
}

// ---- POST /telemetry -----------------------------------------------------------------

export async function ingestTelemetry(d: TelemetryDeps, request: Request, keyId: string): Promise<TelemetryReply> {
    const cancel = () => void request.body?.cancel().catch(() => {});

    const limit = (d.limiter ?? defaultLimiter).hit(keyId, d.now());
    if (!limit.ok) {
        cancel();
        return err(429, "error.telemetry.rate_limited", { "retry-after": String(limit.retryAfterS) });
    }

    const declared = request.headers.get("content-length");
    if (declared !== null && /^\d{1,15}$/.test(declared) && Number(declared) > MAX_BODY_BYTES) {
        cancel();
        return err(413, "error.telemetry.too_large");
    }

    const encoding = (request.headers.get("content-encoding") ?? "").trim().toLowerCase();
    if (encoding !== "" && encoding !== "identity" && encoding !== "gzip") {
        cancel();
        return err(400, "error.telemetry.invalid");
    }

    let bytes = await readCapped(request.body, MAX_BODY_BYTES);
    if (bytes === null) return err(413, "error.telemetry.too_large");
    if (encoding === "gzip") {
        try {
            bytes = await gunzipCapped(bytes, MAX_BODY_BYTES);
        } catch {
            return err(400, "error.telemetry.invalid");
        }
        if (bytes === null) return err(413, "error.telemetry.too_large");
    }

    let batch: Batch;
    try {
        batch = parseBatch(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)));
    } catch {
        return err(400, "error.telemetry.invalid");
    }

    try {
        await storeBatch(d, batch, keyId);
    } catch (e) {
        // Retryable: the client keeps the batch. The detail is only the error name,
        // never the batch.
        console.error("[telemetry] store failed", e instanceof Error ? e.name : "error");
        return err(503, "error.telemetry.unavailable");
    }
    return {
        status: 202,
        body: { status: "success", accepted: { events: batch.events.length, crashes: batch.crashes.length } },
    };
}

// ---- retention -----------------------------------------------------------------------

const CRASH_PAGE = 50;
const CRASH_PAGES_PER_RUN = 40;
const EVENT_PAGE = 1000;
const EVENT_PAGES_PER_RUN = 50;

export type RetentionResult = { events: number; crashes: number; failed: number };

// Deletes everything that arrived more than `retentionMs` ago. A crash's R2 object
// goes first and its row only after the object is gone, so a failed delete is
// retried by the next run instead of orphaning the object. Bounded per run
// (2000 crashes, 50000 events); the next daily run takes the rest.
export async function runTelemetryRetention(
    d: Pick<TelemetryDeps, "db" | "now"> & { originals: Pick<OriginalsBucket, "delete"> },
    retentionMs: number = RETENTION_MS,
): Promise<RetentionResult> {
    const cutoff = d.now() - retentionMs;
    const result: RetentionResult = { events: 0, crashes: 0, failed: 0 };

    for (let page = 0; page < CRASH_PAGES_PER_RUN; page++) {
        const { results } = await d.db
            .prepare("SELECT id, r2_key FROM telemetry_crashes WHERE received_at < ?1 ORDER BY received_at LIMIT ?2")
            .bind(cutoff, CRASH_PAGE)
            .all<{ id: string; r2_key: string }>();
        if (results.length === 0) break;
        const gone: string[] = [];
        for (const row of results) {
            try {
                await d.originals.delete(row.r2_key);
                gone.push(row.id);
            } catch {
                result.failed++;
            }
        }
        if (gone.length === 0) break; // nothing progressed: do not loop on the same rows
        await d.db
            .prepare(`DELETE FROM telemetry_crashes WHERE id IN (${gone.map((_, i) => `?${i + 1}`).join(", ")})`)
            .bind(...gone)
            .run();
        result.crashes += gone.length;
        if (results.length < CRASH_PAGE) break;
    }

    for (let page = 0; page < EVENT_PAGES_PER_RUN; page++) {
        const r = await d.db
            .prepare(
                "DELETE FROM telemetry_events WHERE id IN (SELECT id FROM telemetry_events WHERE received_at < ?1 LIMIT ?2)",
            )
            .bind(cutoff, EVENT_PAGE)
            .run();
        const n = Number(r.meta?.changes ?? 0);
        result.events += n;
        if (n < EVENT_PAGE) break;
    }
    return result;
}
