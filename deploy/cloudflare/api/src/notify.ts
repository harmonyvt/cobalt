// Hark notification bridge (APP-API-CONTRACT.md section 9): a push to the owner's phone
// through a Hark webhook when a job they walked away from finishes. Free of Cloudflare
// imports so it runs under plain node in the tests.
//
// Why: APNs is not available yet (no push key), and a job started from the share sheet
// and closed finishes with nobody watching. The webhook URL is a SECRET
// (HARK_WEBHOOK_URL): it is never logged, never stored, never sent to a client. The bridge is
// off (and `features.notify_bridge` false) when it is missing, empty or not an https URL.
//
// Opt-in, so a foreground run never notifies: the app asks for it when it walks away
// (`PUT /studio/<sid>/notify`, or `"notify": true` on a render). Storage keys, all in the
// one `main` Durable Object next to job:/save:/live:*:
//   notify:optin:<sid>        {keyId, on, label, createdAt, expiresAt}     session opt-in (24 h)
//   notify:job:<sid>:<job>    {expiresAt}                                   render-only opt-in (24 h)
//   notify:ev:<sid>:<event>   EventRecord: the message while it is being sent / retried, then
//                             only a marker (done: true). It is the exactly-once record: an
//                             event with a record is never started again, whichever of a client
//                             poll or the sweep sees it first. Kept SESSION_TTL_MS (7 days).
//
// Nothing here runs after a response: every send is awaited by the poll or the sweep that
// caused it, raced against our own 3 s ceiling (AbortSignal timeouts are not honoured inside
// the Durable Object). A failed send (5xx, network error, timeout) is retried at most twice,
// by the sweep, after 5 s and 20 s; a 4xx is never retried.

import { raceCeiling } from "./ceiling";
import { STUDIO_SID_REGEX } from "./gate";
import { KEY_ID_HEADER } from "./headers";
import { formatBytes } from "./live";
import { serviceFromUrl, type KV } from "./webp";

// ---- constants --------------------------------------------------------------------

export const NOTIFY_TTL_MS = 24 * 60 * 60 * 1000;
// How long an event's sent marker is kept (the session's own lifetime).
export const NOTIFY_MARKER_TTL_MS = 7 * 24 * 60 * 60 * 1000;
// Our own ceiling on one webhook call.
export const NOTIFY_HTTP_MS = 3000;
// After the first failed send and after the second (the third failure gives up): the first
// try plus two retries.
export const NOTIFY_RETRY_DELAYS_MS: readonly number[] = [5_000, 20_000];
export const NOTIFY_MAX_TRIES = NOTIFY_RETRY_DELAYS_MS.length + 1;
// A sweep pass sends at most this many due retries (the rest stay due for the next pass).
export const NOTIFY_PASS_MAX = 5;
export const NOTIFY_MAX_BODY_BYTES = 1024;
export const NOTIFY_MAX_LABEL = 60;
// Hark's limits.
export const HARK_MAX_TITLE = 80;
export const HARK_MAX_BODY = 2000;

// What a tap on the notification opens: the app, on this session's run (the app routes
// `cobalt-apple://session/<sid>` in AppModel.openRunLink). The sid is a studio session id, not
// a secret; the webhook URL and the key never go into it.
export const sessionUrl = (sid: string): string => `cobalt-apple://session/${sid}`;

export const NOTIFY_EVENTS = ["saved", "rendered", "failed"] as const;
export type NotifyEvent = (typeof NOTIFY_EVENTS)[number];

const OPTIN_PREFIX = "notify:optin:";
const JOB_PREFIX = "notify:job:";
const EV_PREFIX = "notify:ev:";

// ---- config -----------------------------------------------------------------------

type EnvLike = { HARK_WEBHOOK_URL?: unknown };

// The webhook URL, or null (bridge off): a non-empty string that is an https URL.
export function harkConfigFrom(env: EnvLike): string | null {
    const raw = env.HARK_WEBHOOK_URL;
    if (typeof raw !== "string") return null;
    const t = raw.trim();
    if (t === "") return null;
    try {
        return new URL(t).protocol === "https:" ? t : null;
    } catch {
        return null;
    }
}

export const harkConfigured = (env: EnvLike): boolean => harkConfigFrom(env) !== null;

// ---- copy -------------------------------------------------------------------------

const clip = (s: string, max: number): string => {
    const chars = [...s];
    return chars.length <= max ? s : `${chars.slice(0, max - 1).join("")}…`;
};

// "9.6", "5": one decimal at most.
const secondsText = (n: number): string => String(Math.round(n * 10) / 10);

// What the owner knows the job as: the label the app gave, else "<service> · <ref>" (ref is
// the link's last path segment, e.g. a post id), else the clip's title.
export function describeJob(
    label: string | null,
    row: { service: string | null; link: string | null; title: string | null } | null,
): string {
    if (label) return label;
    if (row) {
        const service = row.service && row.service !== "unknown" ? row.service : row.link ? serviceFromUrl(row.link) : "";
        let ref = "";
        if (row.link && /^https?:\/\//i.test(row.link)) {
            try {
                const last = new URL(row.link).pathname.split("/").filter(Boolean).pop() ?? "";
                if (/^[\w.-]{1,40}$/.test(last)) ref = last;
            } catch {
                // no ref
            }
        }
        const named = [service === "unknown" ? "" : service, ref].filter(Boolean).join(" · ");
        if (named) return named;
        if (row.title?.trim()) return clip(row.title.trim(), 60);
    }
    return "your video";
}

export function savedMessage(what: string, duration: number | null): { title: string; body: string } {
    const dur = duration !== null && Number.isFinite(duration) && duration > 0 ? ` · ${secondsText(duration)} s` : "";
    return {
        title: "cobalt",
        body: clip(`${what} is saved${dur} — open cobalt to make a webp`, HARK_MAX_BODY),
    };
}

export type RenderSuccess = {
    url: string;
    bytes: number | null;
    width: number | null;
    height: number | null;
};

export function renderedMessage(r: RenderSuccess): { title: string; body: string } {
    const parts = ["webp ready"];
    if (r.width && r.height) parts.push(`${r.width}×${r.height}`);
    if (r.bytes && r.bytes > 0) parts.push(formatBytes(r.bytes));
    return { title: "cobalt", body: clip(`${parts.join(" · ")}\n${r.url}`, HARK_MAX_BODY) };
}

// A short plain reason for an error code the owner may see on the lock screen.
export function plainReason(code: string): string {
    if (code.startsWith("error.api.fetch.") || code.startsWith("error.api.content.") || code.startsWith("error.api.link.")) {
        return "the link could not be fetched";
    }
    switch (code) {
        case "error.webp.no_video":
        case "error.webp.bad_source":
        case "error.webp.download_failed":
            return "the link could not be fetched";
        case "error.studio.busy":
        case "error.webp.busy":
            return "the server was busy";
        case "error.studio.save_lost":
        case "error.webp.job_lost":
            return "the server lost track of the job";
        case "error.studio.too_large":
        case "error.webp.too_large":
        case "error.library.too_large":
            return "the video is too large";
        case "error.webp.unsupported":
        case "error.library.unsupported":
        case "error.studio.not_video":
            return "that kind of video is not supported";
        case "error.studio.expired":
            return "the session expired";
        case "error.studio.storage":
        case "error.webp.storage":
            return "storing the file failed";
        case "error.studio.unavailable":
            return "the server was not available";
        case "error.webp.too_long":
            return "the clip is too long";
        default:
            return "something went wrong on the server";
    }
}

export function failedMessage(phase: "saving" | "rendering", what: string, code: string): { title: string; body: string } {
    const lead = phase === "saving" ? `couldn't save ${what}` : "couldn't make the webp";
    return { title: "cobalt couldn't finish", body: clip(`${lead} — ${plainReason(code)}`, HARK_MAX_BODY) };
}

// ---- records ----------------------------------------------------------------------

type OptIn = { keyId: string; on: NotifyEvent[]; label: string | null; createdAt: number; expiresAt: number };
type JobOptIn = { expiresAt: number };

type EventRecord = {
    sid: string;
    // the message while the event is being sent / retried; dropped once it is done
    title?: string;
    body?: string;
    // sends started so far (written BEFORE each send, so a Durable Object that dies mid-send
    // still counts it and the retries stay bounded)
    tries: number;
    // not before this (null: no retry left)
    retryAt: number | null;
    done: boolean;
    outcome?: "sent" | "rejected" | "gave_up" | "cancelled";
    expiresAt: number;
};

export type NotifyRenderEvent =
    | ({ kind: "success" } & RenderSuccess)
    | { kind: "failed"; code: string };

export type NotifyHooks = {
    onSaved(sid: string): Promise<void>;
    onSaveFailed(sid: string, code: string): Promise<void>;
    onRender(sid: string, job: string, e: NotifyRenderEvent): Promise<void>;
    // `"notify": true` on a render: this job only (its success or its failure)
    optInJob(sid: string, job: string): Promise<void>;
};

export type SweepNotify = {
    // Sends the due retries, drops what expired, answers when the next retry is due (null:
    // none pending) so the sweep re-arms for it even with nothing else pending.
    retryDue(now: number): Promise<{ nextInMs: number | null }>;
};

export type NotifyReply = { status: number; body: unknown };

export type NotifyDeps = {
    storage: KV;
    db: D1Database;
    now: () => number;
    // The Hark webhook URL (a secret); null or empty: the bridge is off.
    webhookUrl: string | null;
    fetch: (url: string, init: RequestInit) => Promise<Response>;
    // Arms the job sweep (a failed send is retried by it).
    scheduleSweep?: () => void | Promise<void>;
    httpMs?: number;
    // Log lines: only "hark sent <status>" / "hark failed <status>" with a session id
    // prefix. Never the URL, the key, the message or an error text.
    log?: (line: string) => void;
    warn?: (line: string) => void;
};

const err = (status: number, code: string): NotifyReply => ({ status, body: { status: "error", error: { code } } });
const invalid = () => err(400, "error.notify.invalid");
const notFound = () => err(404, "error.studio.not_found");

const isRecord = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;

// PUT body: `on` (1-3 of the events, repeats allowed) and an optional `label` (at most 60
// characters, no control characters; empty = none).
export function parseOptIn(raw: string): { on: NotifyEvent[]; label: string | null } | null {
    let b: unknown;
    try {
        b = JSON.parse(raw);
    } catch {
        return null;
    }
    if (!isRecord(b) || !Array.isArray(b.on) || b.on.length < 1 || b.on.length > 8) return null;
    const on: NotifyEvent[] = [];
    for (const e of b.on) {
        if (typeof e !== "string" || !(NOTIFY_EVENTS as readonly string[]).includes(e)) return null;
        if (!on.includes(e as NotifyEvent)) on.push(e as NotifyEvent);
    }
    let label: string | null = null;
    if (b.label !== undefined && b.label !== null) {
        if (typeof b.label !== "string") return null;
        const t = b.label.trim();
        if ([...t].length > NOTIFY_MAX_LABEL || CONTROL.test(t)) return null;
        label = t === "" ? null : t;
    }
    return { on, label };
}

// ---- the service (Durable Object) -----------------------------------------------------

type SendResult = { kind: "ok"; status: number } | { kind: "rejected"; status: number } | { kind: "retry"; status: number | "timeout" | "network" };

export class NotifyService implements NotifyHooks, SweepNotify {
    // event key -> the operation running on it: a poll and the sweep may race, and the
    // second must find the first one's record.
    private chains = new Map<string, Promise<unknown>>();

    constructor(private d: NotifyDeps) {}

    enabled(): boolean {
        return !!this.d.webhookUrl;
    }

    private withEvent<T>(key: string, fn: () => Promise<T>): Promise<T> {
        const prev = this.chains.get(key) ?? Promise.resolve();
        const p = prev.catch(() => {}).then(fn);
        this.chains.set(key, p);
        const clear = () => {
            if (this.chains.get(key) === p) this.chains.delete(key);
        };
        p.then(clear, clear);
        return p;
    }

    private logLine(sid: string, outcome: "sent" | "failed", status: number | string) {
        const line = `[notify] hark ${outcome} ${status} sid=${sid.slice(0, 8)}`;
        if (outcome === "sent") (this.d.log ?? ((l) => console.log(l)))(line);
        else (this.d.warn ?? ((l) => console.warn(l)))(line);
    }

    // ---- the opt-in routes ----

    private async sessionOwnedBy(sid: string, keyId: string): Promise<boolean | "error"> {
        try {
            const row = await this.d.db
                .prepare("SELECT key_id FROM studio_sessions WHERE id = ?1")
                .bind(sid)
                .first<{ key_id: string | null }>();
            return !!row && row.key_id === keyId;
        } catch {
            return "error";
        }
    }

    // PUT /studio/<sid>/notify. Idempotent: a repeat replaces the opt-in and starts its 24 h
    // again; it never resets what was already sent.
    async put(keyId: string, sid: string, raw: string): Promise<NotifyReply> {
        const parsed = parseOptIn(raw);
        if (!parsed) return invalid();
        const owned = await this.sessionOwnedBy(sid, keyId);
        if (owned === "error") return err(503, "error.api.generic");
        if (!owned) return notFound();
        if (!this.enabled()) {
            // nothing is stored and nothing will be sent: the app learns it from the answer
            // (and from `features.notify_bridge`)
            return { status: 200, body: { status: "success", bridge: false, on: parsed.on, label: parsed.label, expires_at: null } };
        }
        const now = this.d.now();
        const rec: OptIn = { keyId, on: parsed.on, label: parsed.label, createdAt: now, expiresAt: now + NOTIFY_TTL_MS };
        await this.d.storage.put(`${OPTIN_PREFIX}${sid}`, rec);
        return { status: 200, body: { status: "success", bridge: true, on: rec.on, label: rec.label, expires_at: rec.expiresAt } };
    }

    // DELETE /studio/<sid>/notify: the owner is back. Removes the opt-ins and cancels events
    // still waiting for a retry (their markers stay, so nothing is ever sent twice).
    async remove(keyId: string, sid: string): Promise<NotifyReply> {
        const owned = await this.sessionOwnedBy(sid, keyId);
        if (owned === "error") return err(503, "error.api.generic");
        if (!owned) return notFound();
        await this.d.storage.delete(`${OPTIN_PREFIX}${sid}`);
        for (const k of (await this.d.storage.list<JobOptIn>({ prefix: `${JOB_PREFIX}${sid}:` })).keys()) {
            await this.d.storage.delete(k);
        }
        for (const [k, rec] of await this.d.storage.list<EventRecord>({ prefix: `${EV_PREFIX}${sid}:` })) {
            if (rec && !rec.done) {
                await this.withEvent(k, async () => {
                    const cur = await this.d.storage.get<EventRecord>(k);
                    if (cur && !cur.done) await this.d.storage.put(k, this.marker(cur, "cancelled"));
                });
            }
        }
        return { status: 204, body: null };
    }

    // ---- hooks ----

    async optInJob(sid: string, job: string): Promise<void> {
        if (!this.enabled()) return;
        await this.d.storage.put(`${JOB_PREFIX}${sid}:${job}`, { expiresAt: this.d.now() + NOTIFY_TTL_MS } satisfies JobOptIn);
    }

    // The label and the events a session (or a render job) asked for; null: nobody asked.
    private async wanted(sid: string, kind: NotifyEvent, job: string | null): Promise<{ label: string | null } | null> {
        const now = this.d.now();
        const opt = await this.d.storage.get<OptIn>(`${OPTIN_PREFIX}${sid}`);
        if (opt && opt.expiresAt > now && opt.on.includes(kind)) return { label: opt.label };
        if (job) {
            const j = await this.d.storage.get<JobOptIn>(`${JOB_PREFIX}${sid}:${job}`);
            if (j && j.expiresAt > now) return { label: opt && opt.expiresAt > now ? opt.label : null };
        }
        return null;
    }

    private async sessionRow(sid: string) {
        try {
            return await this.d.db
                .prepare("SELECT service, link, title, duration FROM studio_sessions WHERE id = ?1")
                .bind(sid)
                .first<{ service: string | null; link: string | null; title: string | null; duration: number | null }>();
        } catch {
            return null;
        }
    }

    async onSaved(sid: string): Promise<void> {
        if (!this.enabled()) return;
        const want = await this.wanted(sid, "saved", null);
        if (!want) return;
        const row = await this.sessionRow(sid);
        const msg = savedMessage(describeJob(want.label, row), row?.duration ?? null);
        await this.fire(`${EV_PREFIX}${sid}:saved`, sid, msg);
    }

    async onSaveFailed(sid: string, code: string): Promise<void> {
        if (!this.enabled()) return;
        const want = await this.wanted(sid, "failed", null);
        if (!want) return;
        const row = await this.sessionRow(sid);
        await this.fire(`${EV_PREFIX}${sid}:save-failed`, sid, failedMessage("saving", describeJob(want.label, row), code));
    }

    // One notification per render job, success or failure (a job is one or the other).
    async onRender(sid: string, job: string, e: NotifyRenderEvent): Promise<void> {
        if (!this.enabled()) return;
        const want = await this.wanted(sid, e.kind === "success" ? "rendered" : "failed", job);
        if (!want) return;
        const msg =
            e.kind === "success" ? renderedMessage(e) : failedMessage("rendering", describeJob(want.label, null), e.code);
        await this.fire(`${EV_PREFIX}${sid}:r:${job}`, sid, msg);
    }

    // ---- sending ----

    private marker(rec: EventRecord, outcome: NonNullable<EventRecord["outcome"]>): EventRecord {
        return { sid: rec.sid, tries: rec.tries, retryAt: null, done: true, outcome, expiresAt: rec.expiresAt };
    }

    // Starts an event unless it already has a record (then it is only a retry when one is due).
    private fire(key: string, sid: string, msg: { title: string; body: string }): Promise<void> {
        return this.withEvent(key, async () => {
            const existing = await this.d.storage.get<EventRecord>(key);
            if (existing) {
                await this.attempt(key, existing);
                return;
            }
            const rec: EventRecord = {
                sid,
                title: clip(msg.title, HARK_MAX_TITLE),
                body: clip(msg.body, HARK_MAX_BODY),
                tries: 0,
                retryAt: null,
                done: false,
                expiresAt: this.d.now() + NOTIFY_MARKER_TTL_MS,
            };
            await this.attempt(key, rec);
        });
    }

    // One send of the event's message (the caller holds the event's chain). Bounded: the
    // record carries the try count, written before the call.
    private async attempt(key: string, rec: EventRecord): Promise<void> {
        if (rec.done || rec.title === undefined || rec.body === undefined) return;
        const now = this.d.now();
        if (rec.retryAt !== null && now < rec.retryAt) return; // backing off
        if (rec.tries >= NOTIFY_MAX_TRIES) {
            await this.d.storage.put(key, this.marker(rec, "gave_up"));
            return;
        }
        const tries = rec.tries + 1;
        const delay = NOTIFY_RETRY_DELAYS_MS[tries - 1];
        const next: EventRecord = { ...rec, tries, retryAt: delay === undefined ? null : now + delay };
        await this.d.storage.put(key, next);

        const r = await this.send(rec.title, rec.body, rec.sid);
        if (r.kind === "ok") {
            this.logLine(rec.sid, "sent", r.status);
            await this.d.storage.put(key, this.marker(next, "sent"));
        } else if (r.kind === "rejected") {
            this.logLine(rec.sid, "failed", r.status);
            await this.d.storage.put(key, this.marker(next, "rejected"));
        } else {
            this.logLine(rec.sid, "failed", r.status);
            if (next.retryAt === null) {
                await this.d.storage.put(key, this.marker(next, "gave_up"));
            } else {
                try {
                    await this.d.scheduleSweep?.();
                } catch {
                    // the next poll retries it
                }
            }
        }
    }

    private async send(title: string, body: string, sid: string): Promise<SendResult> {
        const url = this.d.webhookUrl;
        if (!url) return { kind: "retry", status: "network" };
        const ac = new AbortController();
        try {
            const res = await raceCeiling(
                this.d.fetch(url, {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ title, body, url: sessionUrl(sid) }),
                    redirect: "manual",
                    signal: ac.signal,
                }),
                this.d.httpMs ?? NOTIFY_HTTP_MS,
                "hark",
            );
            await res.body?.cancel().catch(() => {});
            if (res.status >= 200 && res.status < 300) return { kind: "ok", status: res.status };
            if (res.status >= 500) return { kind: "retry", status: res.status };
            return { kind: "rejected", status: res.status };
        } catch (e) {
            ac.abort();
            // the error text is never logged: a fetch error can carry the URL
            return { kind: "retry", status: e instanceof Error && e.name === "CeilingError" ? "timeout" : "network" };
        }
    }

    // ---- the sweep ----

    async retryDue(now: number): Promise<{ nextInMs: number | null }> {
        // housekeeping first (also with the bridge off)
        for (const prefix of [OPTIN_PREFIX, JOB_PREFIX, EV_PREFIX]) {
            for (const [k, rec] of await this.d.storage.list<{ expiresAt?: number }>({ prefix })) {
                if (rec && typeof rec.expiresAt === "number" && rec.expiresAt <= now) await this.d.storage.delete(k);
            }
        }
        if (!this.enabled()) return { nextInMs: null };

        let sent = 0;
        let next: number | null = null;
        const note = (retryAt: number | null) => {
            if (retryAt === null) return;
            const inMs = Math.max(0, retryAt - this.d.now());
            next = next === null ? inMs : Math.min(next, inMs);
        };
        for (const [k, listed] of await this.d.storage.list<EventRecord>({ prefix: EV_PREFIX })) {
            if (!listed || listed.done) continue;
            if (listed.retryAt !== null && listed.retryAt > now) {
                note(listed.retryAt);
                continue;
            }
            if (sent >= NOTIFY_PASS_MAX) {
                note(now); // still due: the next pass
                continue;
            }
            sent++;
            await this.withEvent(k, async () => {
                const cur = await this.d.storage.get<EventRecord>(k);
                if (!cur || cur.done) return;
                // a crash during the last allowed try left no retry: it is over
                await this.attempt(k, cur);
                const after = await this.d.storage.get<EventRecord>(k);
                if (after && !after.done) note(after.retryAt);
            });
        }
        return { nextInMs: next };
    }
}

// ---- routing (inside the Durable Object) ------------------------------------------------

// PUT|DELETE /studio/<sid>/notify
export const isNotifyRoute = (pathname: string): boolean => {
    const parts = pathname.split("/"); // "", "studio", sid, "notify"
    return parts.length === 4 && parts[1] === "studio" && parts[3] === "notify" && STUDIO_SID_REGEX.test(parts[2] ?? "");
};

const toResponse = (r: NotifyReply) =>
    r.body === null
        ? new Response(null, { status: r.status })
        : new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });

// Never calls super.fetch and never wakes the container. The Worker sets the key id after
// its D1 lookup; a request without it is refused.
export async function handleNotifyRoute(service: NotifyService, request: Request): Promise<Response> {
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });
    const sid = new URL(request.url).pathname.split("/")[2] ?? "";
    if (request.method === "DELETE") return toResponse(await service.remove(keyId, sid));
    if (request.method === "PUT") {
        const declared = Number(request.headers.get("content-length"));
        if (Number.isFinite(declared) && declared > NOTIFY_MAX_BODY_BYTES) return toResponse(invalid());
        const text = await request.text();
        if (new TextEncoder().encode(text).length > NOTIFY_MAX_BODY_BYTES) return toResponse(invalid());
        return toResponse(await service.put(keyId, sid, text));
    }
    return new Response(null, { status: 404 });
}
