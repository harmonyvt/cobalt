// Animated WebP hosting: everything the Durable Object does for /webp and
// /media, kept free of Cloudflare imports so it runs under plain node in tests.
// The Durable Object (index.ts) wires WebpService to the real container, DO
// storage and the R2 bucket; the tests wire it to fakes.
//
// Flow: POST /webp starts a job in the container helper (helper/supervisor.js,
// port 9100) and returns an id. GET /webp/:id polls the helper; when the encode
// is done the DO copies the file into R2 under an unguessable name and answers
// with its public URL. Nothing else touches R2 except DELETE /media/:name.

import { raceCeiling } from "./ceiling";
import { MEDIA_NAME_REGEX, WEBP_ID_REGEX } from "./gate";
import { KEY_ID_HEADER } from "./headers";
import { randomBase62 } from "./ids";
import { insertMediaItem, markMediaDeleted } from "./library";
import { cropToWire, parseCrop } from "../helper/crop.js";

export const WEBP_ID_LENGTH = 20;
export const MEDIA_NAME_LENGTH = 10;
export const MAX_WAIT_SECONDS = 25;
export const DEFAULT_WAIT_SECONDS = 20;
export const POLL_INTERVAL_MS = 1000;
// A job or result record older than this is dropped the next time a job starts.
export const RECORD_TTL_MS = 24 * 60 * 60 * 1000;
export const MAX_BODY_BYTES = 8192;
// Our own ceiling on one helper call (see ceiling.ts: AbortSignal.timeout is not
// honoured for containerFetch inside the Durable Object). Roughly the budgets
// index.ts passes as the abort signal: job calls are quick, the result download
// is bigger, the studio upload moves a whole video.
export const HELPER_CALL_MS = 20_000;
export const HELPER_FILE_MS = 60_000;
export const HELPER_UPLOAD_MS = 300_000;

export type Quality = "low" | "med" | "high";

export type WebpParams = {
    url: string;
    start: number;
    // Omitted = from `start` to the end of the video (the helper enforces
    // WEBP_MAX_SECONDS on the resulting clip).
    length?: number;
    width: 320 | 480 | 640;
    fps: number;
    quality: Quality;
    // Optional spatial crop, normalized 0..1 in the source's display orientation
    // (APP-API-CONTRACT.md section 10). Absent = the whole frame; the key is then
    // not present at all, so every record and helper call is what it always was.
    crop?: Crop;
};

export type Crop = { x: number; y: number; w: number; h: number };

export type ErrorBody = { status: "error"; error: { code: string } };
// Render progress (APP-API-CONTRACT.md section 4). `phase` null = not known (an
// old helper, or this Durable Object lost its in-memory copy).
export type RenderPhase = "fetching" | "decode" | "pack";
export type Progress = {
    phase: RenderPhase | null;
    frames_done: number | null;
    frames_total: number | null;
};
export type PendingBody = { status: "pending"; id: string } & Partial<Progress>;
export type SuccessBody = {
    status: "success";
    id: string;
    url: string;
    bytes: number;
    width: number;
    height: number;
    seconds: number;
};
export type ResultBody = SuccessBody | ErrorBody;

export type Reply = { status: number; body: PendingBody | ResultBody | { status: "success" } };

const err = (status: number, code: string): Reply => ({
    status,
    body: { status: "error", error: { code } },
});

// --- ids and names ---------------------------------------------------------

export { randomBase62 };

export const mintId = (rb?: (n: number) => Uint8Array) =>
    randomBase62(WEBP_ID_LENGTH, rb);
export const mintName = (rb?: (n: number) => Uint8Array) =>
    `${randomBase62(MEDIA_NAME_LENGTH, rb)}.webp`;

// --- request validation ----------------------------------------------------

export type ParseResult =
    | { ok: true; params: WebpParams }
    | { ok: false };

// A number, or a numeric string (Shortcuts can send either); undefined, null
// and "" mean "use the default" (which may be undefined = not set).
export function num<D extends number | undefined>(v: unknown, dflt: D): number | D | null {
    if (v === undefined || v === null || v === "") return dflt;
    if (typeof v === "number") return Number.isFinite(v) ? v : null;
    if (typeof v === "string" && v.trim() !== "") {
        const n = Number(v);
        return Number.isFinite(n) ? n : null;
    }
    return null;
}

export function validateParams(body: unknown): ParseResult {
    const bad: ParseResult = { ok: false };
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
        return bad;
    }
    const b = body as Record<string, unknown>;

    if (typeof b.url !== "string" || b.url.length === 0 || b.url.length > 2048) {
        return bad;
    }
    try {
        const u = new URL(b.url);
        if (u.protocol !== "http:" && u.protocol !== "https:") return bad;
    } catch {
        return bad;
    }

    const start = num(b.start, 0);
    // No default: absent length means "to the end of the video".
    const length = num(b.length, undefined);
    const width = num(b.width, 480);
    const fps = num(b.fps, 15);
    if (start === null || start < 0 || start > 3600) return bad;
    // 600 is only a sanity bound; the real gate is the helper's WEBP_MAX_SECONDS.
    if (length === null || (length !== undefined && (length < 1 || length > 600))) {
        return bad;
    }
    if (width !== 320 && width !== 480 && width !== 640) return bad;
    if (fps === null || !Number.isInteger(fps) || fps < 10 || fps > 25) {
        return bad;
    }

    let quality: Quality = "med";
    if (b.quality !== undefined && b.quality !== null && b.quality !== "") {
        if (b.quality !== "low" && b.quality !== "med" && b.quality !== "high") {
            return bad;
        }
        quality = b.quality;
    }

    const params: WebpParams = { url: b.url, start, width, fps, quality };
    if (length !== undefined) params.length = length;
    // The URL source's size is only known to the helper, which converts the crop to
    // pixels (and refuses one under 64 px with error.webp.invalid_params) at encode time.
    const crop = parseCrop(b.crop);
    if (!crop.ok) return bad;
    if (crop.crop) params.crop = crop.crop;
    return { ok: true, params };
}

// Wait seconds from ?wait=N: default 20, clamped to 0..25, junk -> default.
export function parseWait(raw: string | null): number {
    if (raw === null || raw.trim() === "") return DEFAULT_WAIT_SECONDS;
    const n = Number(raw);
    if (!Number.isFinite(n)) return DEFAULT_WAIT_SECONDS;
    return Math.min(MAX_WAIT_SECONDS, Math.max(0, n));
}

// --- result shaping --------------------------------------------------------

// First public label of the host, e.g. https://www.twitter.com/x -> "twitter".
export function serviceFromUrl(raw: string): string {
    try {
        const labels = new URL(raw).hostname.split(".");
        return (labels.length >= 2 ? labels[labels.length - 2] : labels[0]) || "unknown";
    } catch {
        return "unknown";
    }
}

export type HelperDone = {
    status: "done";
    bytes: number;
    width: number;
    height: number;
    seconds: number;
    filename?: string;
    service?: string;
};

export function shapeSuccess(
    id: string,
    mediaBaseUrl: string,
    name: string,
    done: Pick<HelperDone, "bytes" | "width" | "height" | "seconds">,
): SuccessBody {
    const base = mediaBaseUrl.endsWith("/") ? mediaBaseUrl : `${mediaBaseUrl}/`;
    return {
        status: "success",
        id,
        url: `${base}${name}`,
        bytes: done.bytes,
        width: done.width,
        height: done.height,
        seconds: done.seconds,
    };
}

// --- service ---------------------------------------------------------------

export type JobRecord = {
    keyId: string;
    createdAt: number;
    params: WebpParams;
};

export interface KV {
    get<T>(key: string): Promise<T | undefined>;
    put(key: string, value: unknown): Promise<void>;
    delete(key: string): Promise<unknown>;
    list<T>(opts: { prefix: string }): Promise<Map<string, T>>;
}

export interface MediaBucket {
    put(
        key: string,
        value: ArrayBuffer,
        options: {
            httpMetadata: { contentType: string; cacheControl: string };
            customMetadata: Record<string, string>;
        },
    ): Promise<unknown>;
    delete(key: string): Promise<void>;
}

export type WebpDeps = {
    storage: KV;
    bucket: MediaBucket;
    mediaBaseUrl: string;
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    randomBytes?: (n: number) => Uint8Array;
    // Starts the container if needed and waits for ports 9000 and 9100.
    ensureRunning: () => Promise<void>;
    // Calls the helper on port 9100 (adds the internal key); path like "/jobs".
    helper: (path: string, init?: RequestInit) => Promise<Response>;
    // Overrides the ceiling on every helper call (tests); default by path.
    helperTimeoutMs?: number;
    // D1 database for the library's media_items rows (omitted: no rows).
    db?: D1Database;
    // Asks the Durable Object to run the job sweep soon, so a job nobody polls
    // still gets collected. Awaited, never allowed to fail the request.
    scheduleSweep?: () => void | Promise<void>;
};

const NO_PROGRESS: Progress = { phase: null, frames_done: null, frames_total: null };

const count = (v: unknown): number | null =>
    typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null;

// The progress fields of a helper's pending body; anything odd is "unknown".
function progressOf(body: any): Progress {
    const phase = body?.phase;
    if (phase !== "fetching" && phase !== "decode" && phase !== "pack") return NO_PROGRESS;
    return { phase, frames_done: count(body.frames_done), frames_total: count(body.frames_total) };
}

async function readJson(res: Response): Promise<any | null> {
    try {
        return await res.json();
    } catch {
        return null;
    }
}

export class WebpService {
    // id -> upload in progress, so concurrent polls of one id upload once.
    private inflight = new Map<string, Promise<Reply>>();
    // id -> the progress of the last pending helper poll (in memory only)
    private progress = new Map<string, Progress>();

    constructor(private d: WebpDeps) {}

    // Every helper call goes through here: it rejects once its ceiling passes,
    // so a hung call becomes an ordinary miss instead of freezing the poll, the
    // sweep (whose alarm() the container library awaits before it may sleep) or
    // a job start.
    private callHelper(path: string, init?: RequestInit): Promise<Response> {
        const ms =
            this.d.helperTimeoutMs ??
            (path.startsWith("/jobs/upload")
                ? HELPER_UPLOAD_MS
                : path.endsWith("/file")
                  ? HELPER_FILE_MS
                  : HELPER_CALL_MS);
        return raceCeiling(
            Promise.resolve().then(() => this.d.helper(path, init)),
            ms,
            `helper ${path.split("?")[0]}`,
        );
    }

    private async scheduleSweep(): Promise<void> {
        try {
            await this.d.scheduleSweep?.();
        } catch (e) {
            console.error("[webp] scheduling the job sweep failed", String(e));
        }
    }

    async create(keyId: string, rawBody: string): Promise<Reply> {
        let parsed: unknown;
        try {
            if (rawBody.length > MAX_BODY_BYTES) throw new Error("too large");
            parsed = JSON.parse(rawBody);
        } catch {
            return err(400, "error.webp.invalid_params");
        }
        const v = validateParams(parsed);
        if (!v.ok) return err(400, "error.webp.invalid_params");

        try {
            await this.d.ensureRunning();
        } catch {
            return err(503, "error.webp.unavailable");
        }

        await this.prune();

        const id = mintId(this.d.randomBytes);
        let res: Response;
        try {
            res = await this.callHelper("/jobs", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ id, ...v.params }),
            });
        } catch {
            return err(502, "error.webp.unavailable");
        }
        if (res.status === 429) return err(429, "error.webp.busy");
        if (res.status !== 202) {
            const body = await readJson(res);
            const code = body?.error?.code;
            return err(502, typeof code === "string" ? code : "error.webp.unavailable");
        }

        const record: JobRecord = {
            keyId,
            createdAt: this.d.now(),
            params: v.params,
        };
        await this.d.storage.put(`job:${id}`, record);
        await this.scheduleSweep();
        return { status: 202, body: { status: "pending", id } };
    }

    // Studio renders: the same job, but the video is the stored original,
    // streamed from R2 into the helper (POST /jobs/upload) instead of being
    // resolved and downloaded again. `keyId` is the job's owner label
    // ("studio:<session id>"); status() then only answers for that owner.
    // `getUpload` runs after the container is up, so the R2 stream is not held
    // open through a cold start; the body is passed on as a stream, never
    // buffered here. A null upload (object missing) is a storage error.
    async createFromUpload(
        keyId: string,
        params: WebpParams,
        getUpload: () => Promise<{ body: ReadableStream; size: number } | null>,
        // A job id minted earlier (a queued render has its id from the moment it joined the line,
        // APP-API-CONTRACT.md section 17); absent = minted here.
        opts: { id?: string } = {},
    ): Promise<Reply> {
        try {
            await this.d.ensureRunning();
        } catch {
            return err(503, "error.webp.unavailable");
        }

        await this.prune();

        const id = opts.id ?? mintId(this.d.randomBytes);
        let upload: { body: ReadableStream; size: number } | null;
        try {
            upload = await getUpload();
        } catch {
            return err(502, "error.webp.storage");
        }
        if (!upload) return err(502, "error.webp.storage");

        const q = new URLSearchParams({
            id,
            start: String(params.start),
            width: String(params.width),
            fps: String(params.fps),
            quality: params.quality,
        });
        if (params.length !== undefined) q.set("length", String(params.length));
        if (params.crop) q.set("crop", cropToWire(params.crop));

        let res: Response;
        try {
            res = await this.callHelper(`/jobs/upload?${q}`, {
                method: "POST",
                headers: {
                    "content-type": "application/octet-stream",
                    "content-length": String(upload.size),
                },
                body: upload.body,
            });
        } catch {
            return err(502, "error.webp.unavailable");
        }
        if (res.status !== 202) {
            // the helper did not take the video: release the R2 stream
            await upload.body.cancel().catch(() => {});
            if (res.status === 429) return err(429, "error.webp.busy");
            const body = await readJson(res);
            const code = body?.error?.code;
            return err(502, typeof code === "string" ? code : "error.webp.unavailable");
        }

        const record: JobRecord = { keyId, createdAt: this.d.now(), params };
        await this.d.storage.put(`job:${id}`, record);
        await this.scheduleSweep();
        return { status: 202, body: { status: "pending", id } };
    }

    async status(keyId: string, id: string, waitSeconds: number): Promise<Reply> {
        const notFound = () => err(404, "error.webp.not_found");
        const job = await this.d.storage.get<JobRecord>(`job:${id}`);
        // A job that belongs to another key looks exactly like an unknown one.
        if (!job || job.keyId !== keyId) return notFound();

        const deadline = this.d.now() + waitSeconds * 1000;
        for (;;) {
            // Re-read at the top of every pass: the job sweep (or another poll)
            // may have collected it while this long-poll slept. Whoever
            // collects deletes the helper's job, so polling the helper again
            // would only find a 404.
            const stored = await this.d.storage.get<ResultBody>(`result:${id}`);
            if (stored) return { status: 200, body: stored };

            const reply = await this.pollOnce(id, job);
            if (reply) return reply;
            if (this.d.now() >= deadline) {
                return { status: 200, body: { status: "pending", id, ...(this.progress.get(id) ?? NO_PROGRESS) } };
            }
            await this.d.sleep(POLL_INTERVAL_MS);
        }
    }

    // One helper poll. Returns a final reply, or null while the job is pending
    // (or the helper could not be reached; the caller keeps waiting).
    private async pollOnce(id: string, job: JobRecord): Promise<Reply | null> {
        let res: Response;
        try {
            res = await this.callHelper(`/jobs/${id}`);
        } catch {
            return null;
        }
        if (res.status === 404) {
            // Either the container restarted since the job was accepted (it is
            // gone), or somebody else collected it between our last read and
            // this poll and dropped the helper's copy: then the result is
            // stored and is what to answer.
            const stored = await this.d.storage.get<ResultBody>(`result:${id}`);
            if (stored) return { status: 200, body: stored };
            return this.finish(id, {
                status: "error",
                error: { code: "error.webp.job_lost" },
            });
        }
        const body = await readJson(res);
        if (!body || typeof body.status !== "string") return null;

        if (body.status === "pending") {
            this.progress.set(id, progressOf(body));
            return null;
        }
        if (body.status === "error") {
            const code = body.error?.code;
            return this.finish(id, {
                status: "error",
                error: { code: typeof code === "string" ? code : "error.webp.encode_failed" },
            });
        }
        if (body.status === "done") {
            const existing = this.inflight.get(id);
            if (existing) return existing;
            const p = this.upload(id, job, body as HelperDone).finally(() =>
                this.inflight.delete(id),
            );
            this.inflight.set(id, p);
            return p;
        }
        return null;
    }

    // Persist a terminal error (so polling again is stable) and free the helper.
    // A stored result is final: finish() never replaces it (a poll that lost the
    // race to the sweep would otherwise turn a collected success into job_lost).
    private async finish(id: string, result: ErrorBody): Promise<Reply> {
        const stored = await this.d.storage.get<ResultBody>(`result:${id}`);
        if (stored) return { status: 200, body: stored };
        this.progress.delete(id);
        await this.d.storage.put(`result:${id}`, result);
        await this.dropHelperJob(id);
        return { status: 200, body: result };
    }

    private async upload(id: string, job: JobRecord, done: HelperDone): Promise<Reply> {
        // Another poll may have finished while this one waited its turn.
        const stored = await this.d.storage.get<ResultBody>(`result:${id}`);
        if (stored) return { status: 200, body: stored };

        let buf: ArrayBuffer;
        try {
            const res = await this.callHelper(`/jobs/${id}/file`);
            if (!res.ok) {
                // 404: collected (and dropped) by someone else since we looked
                const gone = res.status === 404 ? await this.d.storage.get<ResultBody>(`result:${id}`) : undefined;
                return gone ? { status: 200, body: gone } : err(502, "error.webp.upstream");
            }
            buf = await res.arrayBuffer();
        } catch {
            return err(502, "error.webp.upstream");
        }

        const name = mintName(this.d.randomBytes);
        try {
            await this.d.bucket.put(name, buf, {
                httpMetadata: {
                    contentType: "image/webp",
                    cacheControl: "public, max-age=31536000, immutable",
                },
                customMetadata: {
                    keyId: job.keyId,
                    // R2 caps custom metadata at 2 KiB in total
                    source: job.params.url.slice(0, 1000),
                    service: done.service || serviceFromUrl(job.params.url),
                    createdAt: String(this.d.now()),
                },
            });
        } catch {
            // Not stored: the helper still has the file, the next poll retries.
            return err(502, "error.webp.storage");
        }

        const result = shapeSuccess(id, this.d.mediaBaseUrl, name, {
            ...done,
            bytes: buf.byteLength,
        });
        await this.d.storage.put(`result:${id}`, result);
        this.progress.delete(id);
        // Library bookkeeping. A studio render (owner label "studio:<sid>") is
        // recorded by the studio when the render is collected, with its session.
        if (!job.keyId.startsWith("studio:")) {
            await insertMediaItem(this.d.db, {
                kind: "public",
                source: "webp",
                bucket: "media",
                r2_key: name,
                url: result.url,
                name: done.filename || name,
                content_type: "image/webp",
                bytes: buf.byteLength,
                width: done.width ?? null,
                height: done.height ?? null,
                duration: done.seconds ?? null,
                link: job.params.url,
                key_id: job.keyId,
                created_at: this.d.now(),
            });
        }
        await this.dropHelperJob(id);
        return { status: 200, body: result };
    }

    private async dropHelperJob(id: string): Promise<void> {
        try {
            await this.callHelper(`/jobs/${id}`, { method: "DELETE" });
        } catch {
            // best effort: the helper expires jobs on its own
        }
    }

    async deleteMedia(name: string): Promise<Reply> {
        // R2 delete is idempotent: deleting a missing object succeeds.
        try {
            await this.d.bucket.delete(name);
        } catch {
            return err(502, "error.webp.storage");
        }
        await markMediaDeleted(this.d.db, "media", name, this.d.now());
        return { status: 200, body: { status: "success" } };
    }

    // Drop job/result records older than a day so DO storage stays small.
    async prune(): Promise<void> {
        const cutoff = this.d.now() - RECORD_TTL_MS;
        const jobs = await this.d.storage.list<JobRecord>({ prefix: "job:" });
        for (const [key, rec] of jobs) {
            if (rec.createdAt < cutoff) {
                await this.d.storage.delete(key);
                await this.d.storage.delete(`result:${key.slice("job:".length)}`);
            }
        }
    }
}

// --- routing ---------------------------------------------------------------

export const isWebpRoute = (pathname: string) =>
    pathname === "/webp" ||
    pathname.startsWith("/webp/") ||
    pathname.startsWith("/media/");

const toResponse = (r: Reply) =>
    new Response(JSON.stringify(r.body), {
        status: r.status,
        headers: { "content-type": "application/json" },
    });

// Handles /webp* and /media* inside the Durable Object. The caller checks
// isWebpRoute() first. The key id comes ONLY from the header the Worker set
// after its D1 lookup; without it nothing runs.
export async function handleWebpRoute(
    service: WebpService,
    request: Request,
): Promise<Response> {
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });

    const url = new URL(request.url);
    const p = url.pathname;

    if (request.method === "POST" && p === "/webp") {
        return toResponse(await service.create(keyId, await request.text()));
    }
    if (request.method === "GET" && p.startsWith("/webp/")) {
        const id = p.slice("/webp/".length);
        if (!WEBP_ID_REGEX.test(id)) return toResponse(err(404, "error.webp.not_found"));
        return toResponse(
            await service.status(keyId, id, parseWait(url.searchParams.get("wait"))),
        );
    }
    if (request.method === "DELETE" && p.startsWith("/media/")) {
        const name = p.slice("/media/".length);
        if (!MEDIA_NAME_REGEX.test(name)) return new Response(null, { status: 404 });
        return toResponse(await service.deleteMedia(name));
    }
    return new Response(null, { status: 404 });
}
