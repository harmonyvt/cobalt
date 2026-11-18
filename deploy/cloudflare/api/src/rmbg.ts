// AI video background removal (APP-API-CONTRACT.md section 67). Bria v-rmbg-3.0 through the Workers AI
// binding (`env.AI.run`), the call the model page documents. A clip is at most 60 s and costs $0.0225/s.
// The job lives in Durable Object storage and is polled like a studio render, so a Live Activity registered
// for the session and GET ?wait= see the same pending / success / error shape.
//
// Free of the Containers SDK. Tests construct it with fakes.

import { insertMediaItem } from "./library";
import { PREVIEW_TOKEN_REGEX, servePreview, signPreviewToken, verifyPreviewToken, type PreviewDeps } from "./mcp-preview";
import { randomBase62 } from "./ids";
import type { LiveHooks, LiveRenderEvent } from "./live";
import type { OriginalsBucket } from "./studio";
import type { KV } from "./webp";

export const RMBG_MODEL = "bria/v-rmbg-3.0";
export const RMBG_MAX_SECONDS = 60;
export const RMBG_USD_PER_SECOND = 0.0225;
/** How long the signed original stays fetchable by Bria. */
export const RMBG_URL_TTL_MS = 15 * 60 * 1000;
export const RMBG_JOB_LENGTH = 20;
const MAX_RESULT_BYTES = 500 * 1024 * 1024;

export type AiRunner = { run(model: string, inputs: Record<string, unknown>): Promise<unknown> };

export type RmbgStart = {
    keyId: string;
    itemId: string;
    seconds: number;
    spill: number;
    videoUrl: string;
    sessionId: string | null;
    postKey: string | null;
    width: number | null;
    height: number | null;
    title: string | null;
};

export type RmbgJob = RmbgStart & {
    id: string;
    status: "pending" | "running" | "success" | "error";
    estimate_usd: number;
    createdAt: number;
    error?: string;
    warning?: string;
    result?: { item_id: string; bytes: number; content_type: string; seconds: number };
};

export const estimateUsd = (seconds: number) => Math.round(seconds * RMBG_USD_PER_SECOND * 10000) / 10000;

/** The documented input. Transparent output needs the ProRes preset; spill is the greenscreen fringe control. */
export function briaInput(video: string, spill: number): Record<string, unknown> {
    return {
        video,
        background_color: "Transparent",
        output_container_and_codec: "mov_proresks",
        preserve_audio: true,
        spill_suppression: spill,
        auto_zoom: false,
    };
}

export function videoUrlOf(raw: unknown): { video: string; warning?: string } | null {
    if (!raw || typeof raw !== "object") return null;
    const o = raw as Record<string, unknown>;
    if (typeof o.state === "string" && o.state !== "Completed") return null;
    const result = o.result && typeof o.result === "object" ? (o.result as Record<string, unknown>) : o;
    const video = result.video;
    if (typeof video !== "string" || !/^https:\/\//.test(video)) return null;
    const warning = typeof result.warning === "string" ? result.warning : undefined;
    return warning ? { video, warning } : { video };
}

export type RmbgDeps = {
    storage: KV;
    db: D1Database;
    originals: OriginalsBucket;
    ai: AiRunner | undefined;
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    fetch: typeof fetch;
    randomBytes?: (n: number) => Uint8Array;
    waitUntil?: (p: Promise<unknown>) => void;
    live?: Pick<LiveHooks, "onRender">;
};

const err = (status: number, code: string) => ({ status, body: { status: "error" as const, error: { code } } });

export class RmbgService {
    private inflight = new Set<string>();
    constructor(private d: RmbgDeps) {}

    async start(input: RmbgStart): Promise<{ status: number; body: unknown }> {
        if (!this.d.ai) return err(503, "error.rmbg.off");
        if (!(input.seconds > 0)) return err(400, "error.rmbg.unknown_duration");
        if (input.seconds > RMBG_MAX_SECONDS) return err(400, "error.rmbg.too_long");
        if (!(input.spill >= 0 && input.spill <= 1)) return err(400, "error.rmbg.bad_request");
        const id = randomBase62(RMBG_JOB_LENGTH, this.d.randomBytes);
        const job: RmbgJob = {
            ...input,
            id,
            status: "pending",
            estimate_usd: estimateUsd(input.seconds),
            createdAt: this.d.now(),
        };
        await this.d.storage.put(`rmbg:${id}`, job);
        this.kick(id);
        await this.note(job, { kind: "accepted", title: input.title, duration: input.seconds });
        return {
            status: 202,
            body: { status: "pending", id, seconds: input.seconds, estimate_usd: job.estimate_usd, max_seconds: RMBG_MAX_SECONDS },
        };
    }

    async status(id: string, owner: string, waitSeconds: number): Promise<{ status: number; body: unknown }> {
        const first = await this.d.storage.get<RmbgJob>(`rmbg:${id}`);
        if (!first || first.keyId !== owner) return err(404, "error.rmbg.not_found");
        if (first.status === "pending" || first.status === "running") this.kick(id);
        const deadline = this.d.now() + Math.max(0, waitSeconds) * 1000;
        let job = first;
        while ((job.status === "pending" || job.status === "running") && this.d.now() < deadline) {
            await this.d.sleep(50);
            job = (await this.d.storage.get<RmbgJob>(`rmbg:${id}`)) ?? job;
        }
        return { status: 200, body: publicJob(job) };
    }

    private kick(id: string) {
        if (this.inflight.has(id)) return;
        this.inflight.add(id);
        const p = this.execute(id).finally(() => this.inflight.delete(id));
        this.d.waitUntil?.(p);
    }

    private async execute(id: string): Promise<void> {
        const job = await this.d.storage.get<RmbgJob>(`rmbg:${id}`);
        if (!job || job.status === "success" || job.status === "error") return;
        if (!this.d.ai) return this.fail(job, "error.rmbg.off");
        job.status = "running";
        await this.d.storage.put(`rmbg:${id}`, job);
        await this.note(job, { kind: "pending", phase: "decode", framesDone: null, framesTotal: null });
        let raw: unknown;
        try {
            raw = await this.d.ai.run(RMBG_MODEL, briaInput(job.videoUrl, job.spill));
        } catch (e) {
            console.error("[rmbg] model", String(e));
            return this.fail(job, "error.rmbg.failed");
        }
        const found = videoUrlOf(raw);
        if (!found) return this.fail(job, "error.rmbg.failed");
        let bytes: Uint8Array;
        try {
            const res = await this.d.fetch(found.video);
            if (!res.ok || !res.body) return this.fail(job, "error.rmbg.failed");
            const buf = new Uint8Array(await res.arrayBuffer());
            if (buf.byteLength === 0 || buf.byteLength > MAX_RESULT_BYTES) return this.fail(job, "error.rmbg.failed");
            bytes = buf;
        } catch (e) {
            console.error("[rmbg] download", String(e));
            return this.fail(job, "error.rmbg.failed");
        }
        const key = `rmbg/${id}.mov`;
        try {
            const put = await this.d.originals.put(key, bytes, {
                httpMetadata: { contentType: "video/quicktime" },
                customMetadata: { source: "rmbg", item: job.itemId, createdAt: String(this.d.now()) },
            });
            if (!put) return this.fail(job, "error.rmbg.storage");
        } catch (e) {
            console.error("[rmbg] store", String(e));
            return this.fail(job, "error.rmbg.storage");
        }
        const itemId = await insertMediaItem(this.d.db, {
            kind: "private",
            source: "made",
            bucket: "originals",
            r2_key: key,
            name: `${(job.title || "background").slice(0, 80)}.mov`,
            content_type: "video/quicktime",
            bytes: bytes.byteLength,
            width: job.width,
            height: job.height,
            duration: job.seconds,
            session_id: job.sessionId,
            post_key: job.postKey,
            key_id: job.keyId.startsWith("studio:") ? null : job.keyId,
            role: "alt",
            made_from: JSON.stringify([job.itemId]),
            made_spec: JSON.stringify({ kind: "rmbg", model: RMBG_MODEL, spill: job.spill, source: job.itemId }),
            created_at: this.d.now(),
        });
        if (!itemId) return this.fail(job, "error.rmbg.storage");
        job.status = "success";
        job.warning = found.warning;
        job.result = { item_id: itemId, bytes: bytes.byteLength, content_type: "video/quicktime", seconds: job.seconds };
        await this.d.storage.put(`rmbg:${id}`, job);
        await this.note(job, { kind: "success", url: "", bytes: bytes.byteLength, width: job.width, height: job.height, seconds: job.seconds });
    }

    private async fail(job: RmbgJob, code: string) {
        job.status = "error";
        job.error = code;
        await this.d.storage.put(`rmbg:${job.id}`, job);
        await this.note(job, { kind: "failed", code });
    }

    private async note(job: RmbgJob, e: LiveRenderEvent) {
        if (!job.sessionId || !this.d.live) return;
        await this.d.live.onRender(job.sessionId, job.id, e).catch(() => {});
    }
}

function publicJob(job: RmbgJob) {
    if (job.status === "error") return { status: "error", id: job.id, error: { code: job.error ?? "error.rmbg.failed" } };
    if (job.status === "success" && job.result) {
        return {
            status: "success",
            id: job.id,
            item_id: job.result.item_id,
            bytes: job.result.bytes,
            content_type: job.result.content_type,
            seconds: job.result.seconds,
            estimate_usd: job.estimate_usd,
            ...(job.warning ? { warning: job.warning } : {}),
        };
    }
    return { status: "pending", id: job.id, phase: job.status === "running" ? "running" : "queued", estimate_usd: job.estimate_usd, seconds: job.seconds };
}

export type Quote = { seconds: number; estimate_usd: number; max_seconds: number; too_long: boolean };

export function quoteFor(seconds: number | null): Quote | null {
    if (seconds === null || !(seconds > 0)) return null;
    return { seconds, estimate_usd: estimateUsd(seconds), max_seconds: RMBG_MAX_SECONDS, too_long: seconds > RMBG_MAX_SECONDS };
}

/** A public file is already a URL Bria can fetch. Anything else gets a 15-minute signed link. */
export async function sourceUrlFor(o: {
    secret: string;
    origin: string;
    keyId: string;
    itemId: string;
    publicUrl: string | null;
    now: number;
}): Promise<string> {
    if (o.publicUrl && /^https:\/\//.test(o.publicUrl)) return o.publicUrl;
    const token = await signPreviewToken(o.secret, { k: o.keyId, i: o.itemId, e: o.now + RMBG_URL_TTL_MS, p: 0 });
    return `${o.origin.replace(/\/+$/, "")}/rmbg/media/${token}`;
}

// GET /rmbg/media/<token>: the signed original, for Bria. The token is the credential (same HMAC as a preview).
// It does not depend on the MCP mode: Bria is not an MCP widget. Hidden and deleted files are still 404.
export async function serveRmbgMedia(d: PreviewDeps & { secret: string; now: number }, request: Request, token: string): Promise<Response> {
    if (!PREVIEW_TOKEN_REGEX.test(token)) return new Response("not found\n", { status: 404 });
    const claims = await verifyPreviewToken(d.secret, token, d.now);
    if (!claims || claims.p !== 0) return new Response("forbidden\n", { status: 403 });
    return servePreview(d, request, claims, false);
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

/** POST /rmbg and GET /rmbg/:id inside the Durable Object. The Worker has already checked the caller. */
export async function handleRmbgRoute(service: RmbgService, request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] !== "rmbg" || parts.length > 2) return json(404, { status: "error", error: { code: "error.rmbg.not_found" } });
    if (request.method === "POST" && parts.length === 1) {
        let body: RmbgStart;
        try {
            body = (await request.json()) as RmbgStart;
        } catch {
            return json(400, { status: "error", error: { code: "error.rmbg.bad_request" } });
        }
        if (!body || typeof body.videoUrl !== "string" || typeof body.itemId !== "string" || typeof body.keyId !== "string") {
            return json(400, { status: "error", error: { code: "error.rmbg.bad_request" } });
        }
        const r = await service.start({
            keyId: body.keyId,
            itemId: body.itemId,
            seconds: Number(body.seconds),
            spill: Number(body.spill ?? 0),
            videoUrl: body.videoUrl,
            sessionId: body.sessionId ?? null,
            postKey: body.postKey ?? null,
            width: body.width ?? null,
            height: body.height ?? null,
            title: body.title ?? null,
        });
        return json(r.status, r.body);
    }
    if (request.method === "GET" && parts.length === 2) {
        const owner = url.searchParams.get("owner") ?? "";
        const wait = Number(url.searchParams.get("wait") ?? "0");
        const r = await service.status(parts[1]!, owner, Number.isFinite(wait) ? wait : 0);
        return json(r.status, r.body);
    }
    return json(404, { status: "error", error: { code: "error.rmbg.not_found" } });
}
