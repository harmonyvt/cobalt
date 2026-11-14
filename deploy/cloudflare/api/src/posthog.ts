// PostHog (US cloud) events from the Worker (APP-API-CONTRACT.md section 58). Every op call (HTTP, chat, MCP), the
// warn/error lines and crashes the apps upload to POST /telemetry, and the cron's runs go to PostHog's capture API as
// plain fetches (no PostHog package). Off unless POSTHOG_PROJECT_TOKEN is set. Free of Cloudflare imports.
//
// Rules, one for every caller:
//  - Never changes an answer: a send is fire-and-forget through background() with its own timeout, and a failure is
//    only a console line.
//  - Never sends keys, request bodies, saved links, file contents or chat text: an op event carries the op's name,
//    who called it, the status, the error code and the time it took.
//  - One person: everything is `distinct_id: "owner"` (one-owner deployment). The app's own SDK identifies as
//    "owner" too, so its replays and these events sit on one person. An app request's `x-capy-session` (the SDK's
//    session id) becomes `$session_id`, so the server's events show inside that replay.
import { background } from "./background";

export const DEFAULT_HOST = "https://us.i.posthog.com";
export const DISTINCT_ID = "owner";
export const SESSION_HEADER = "x-capy-session";
export const INSTALL_HEADER = "x-capy-install";
export const CLIENT_HEADER = "x-capy-client";
export const SEND_TIMEOUT_MS = 3000;
const MAX_PROP_CHARS = 300;

export type PostHogEnv = { POSTHOG_PROJECT_TOKEN?: string; POSTHOG_HOST?: string };
export type PostHogEvent = { event: string; distinct_id: string; timestamp: string; properties: Record<string, unknown> };
export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export type PostHogConfig = { token: string; host: string };

// The token and host, or null when PostHog is off.
export function postHogConfig(env: PostHogEnv): PostHogConfig | null {
    const token = (env.POSTHOG_PROJECT_TOKEN ?? "").trim();
    if (!token) return null;
    const host = (env.POSTHOG_HOST ?? "").trim().replace(/\/+$/, "") || DEFAULT_HOST;
    return { token, host };
}

const clip = (v: unknown): unknown => (typeof v === "string" && v.length > MAX_PROP_CHARS ? v.slice(0, MAX_PROP_CHARS) : v);

export function makeEvent(event: string, ts: number, properties: Record<string, unknown>): PostHogEvent {
    const props: Record<string, unknown> = { $lib: "capystore-worker" };
    for (const [k, v] of Object.entries(properties)) if (v !== undefined && v !== null) props[k] = clip(v);
    return { event, distinct_id: DISTINCT_ID, timestamp: new Date(ts).toISOString(), properties: props };
}

// POSTs one batch. Resolves either way; returns whether PostHog took it (tests read it).
export async function sendBatch(cfg: PostHogConfig, events: PostHogEvent[], fetchFn: FetchLike = fetch): Promise<boolean> {
    if (events.length === 0) return true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    // AbortSignal timeouts are not always honoured in the Workers runtime: race our own (CLAUDE.md runtime lessons)
    const timeout = new Promise<"timeout">((resolve) => (timer = setTimeout(() => resolve("timeout"), SEND_TIMEOUT_MS)));
    try {
        const res = await Promise.race([
            fetchFn(`${cfg.host}/batch/`, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ api_key: cfg.token, batch: events }),
            }),
            timeout,
        ]);
        if (res === "timeout") {
            console.error("[posthog] send timed out");
            return false;
        }
        if (!res.ok) console.error(`[posthog] send answered ${res.status}`);
        void res.body?.cancel().catch(() => {});
        return res.ok;
    } catch (e) {
        console.error("[posthog] send failed", e instanceof Error ? e.name : "error");
        return false;
    } finally {
        if (timer) clearTimeout(timer);
    }
}

// Fire-and-forget: hands the send to waitUntil when there is one. Never rejects.
export function capture(
    env: PostHogEnv,
    waitUntil: ((p: Promise<unknown>) => void) | undefined,
    events: PostHogEvent[],
    fetchFn?: FetchLike,
): Promise<void> {
    const cfg = postHogConfig(env);
    if (!cfg || events.length === 0) return Promise.resolve();
    return background(waitUntil, () => sendBatch(cfg, events, fetchFn)).catch(() => {});
}

// ---- op events ----------------------------------------------------------------------------------

export type OpSurface = "app" | "web" | "tool" | "service" | "chat" | "mcp" | "agent" | "public";

export type OpCall = {
    op: string;
    surface: OpSurface;
    status: number;
    ms: number;
    error?: string | null;
    host?: string; // api | share | stage | studio
    method?: string;
    keyId?: string | null;
    session?: string | null; // the app's PostHog session id
    install?: string | null;
    client?: string | null; // ios | macos | web, as the client said
    thread?: string | null; // chat or MCP thread
};

// The PostHog session id the app sent: a UUID (the SDK's are UUIDv7). Anything else is dropped.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const cleanId = (v: string | null | undefined): string | null => (v && UUID.test(v.trim()) ? v.trim().toLowerCase() : null);
const cleanClient = (v: string | null | undefined): string | null => (v && /^(ios|ipados|macos|web)$/i.test(v.trim()) ? v.trim().toLowerCase() : null);

// Who an HTTP call came from, from its caller and the app's headers.
export function httpSurface(caller: "key" | "service" | "chat" | "open", request: Request | undefined): OpSurface {
    if (caller === "service") return "service";
    if (caller === "open") return "public";
    const client = cleanClient(request?.headers.get(CLIENT_HEADER));
    if (client === "web") return "web";
    if (client) return "app";
    return "tool";
}

// Whether an op call is worth an event. Public hosts (share pages, the stage canvas, studio) answer crawlers and OBS
// all day: only their failures are sent. /telemetry is its own mirror (below).
export function worthSending(c: OpCall): boolean {
    if (c.op === "telemetry") return false;
    if (c.surface === "public") return c.status >= 500;
    return true;
}

export function opEvent(c: OpCall, ts: number): PostHogEvent[] {
    const failed = c.status >= 500 || (c.status === 0 && !!c.error);
    const props: Record<string, unknown> = {
        op: c.op,
        surface: c.surface,
        status: c.status,
        ms: Math.round(c.ms),
        ok: c.status >= 200 && c.status < 400,
        error_code: c.error ?? undefined,
        route_host: c.host,
        method: c.method,
        // a key's id, never the key; chat:<thread> ids say which thread
        key_id: c.keyId ?? undefined,
        $session_id: cleanId(c.session) ?? undefined,
        install: cleanId(c.install) ?? undefined,
        client: cleanClient(c.client) ?? undefined,
        thread: c.thread ?? undefined,
    };
    const out = [makeEvent("op", ts, props)];
    if (failed) {
        out.push(
            makeEvent("$exception", ts, {
                ...props,
                $exception_list: [{ type: "OpFailed", value: `${c.op} answered ${c.status}${c.error ? ` ${c.error}` : ""}`, mechanism: { handled: true, synthetic: true } }],
                $exception_level: "error",
                source: "worker",
            }),
        );
    }
    return out;
}

// ---- the apps' telemetry batches (POST /telemetry) ------------------------------------------------

export type MirrorApp = { version: string; build: string; platform: string; os?: string | null; device?: string | null; process: string };
export type MirrorBatch = {
    app: MirrorApp;
    install: string;
    events: { ts: number; level: string; cat: string; msg: string; data: Record<string, string | number | boolean> | null }[];
    crashes: { ts: number; kind: string; summary: string }[];
};

// Warn and error lines become `app_log`, crashes `$exception`. Debug and info lines stay in D1 only (volume).
export function telemetryEvents(b: MirrorBatch, session: string | null): PostHogEvent[] {
    const base = {
        install: cleanId(b.install) ?? undefined,
        platform: b.app.platform,
        app_version: b.app.version,
        app_build: b.app.build,
        os_version: b.app.os ?? undefined,
        device: b.app.device ?? undefined,
        process: b.app.process,
        $session_id: cleanId(session) ?? undefined,
    };
    const out: PostHogEvent[] = [];
    for (const e of b.events) {
        if (e.level !== "warn" && e.level !== "error") continue;
        const data: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(e.data ?? {})) data[`data_${k}`] = v;
        out.push(makeEvent("app_log", e.ts, { ...base, ...data, level: e.level, cat: e.cat, msg: e.msg }));
    }
    for (const c of b.crashes) {
        out.push(
            makeEvent("$exception", c.ts, {
                ...base,
                source: "app",
                crash_kind: c.kind,
                $exception_list: [{ type: c.kind, value: c.summary, mechanism: { handled: false, synthetic: true } }],
                $exception_level: c.kind === "crash" ? "fatal" : "error",
            }),
        );
    }
    return out;
}

// ---- cron ---------------------------------------------------------------------------------------

export function cronEvent(job: string, ts: number, ms: number, ok: boolean, detail: Record<string, unknown> = {}): PostHogEvent {
    const flat: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(detail)) if (["string", "number", "boolean"].includes(typeof v)) flat[k] = v;
    return makeEvent("cron_run", ts, { ...flat, job, ms: Math.round(ms), ok });
}
