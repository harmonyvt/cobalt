// Chat reply Live Activities pushed to other devices (APP-API-CONTRACT.md section 27.9, apple/CONTRACT-PARALLEL.md 15.10).
//
// The app draws a reply's activity itself when it sent the message. A message sent from somewhere else (the Mac app, a Mac
// Shortcut) reaches the owner's iPhone only through APNs: each iPhone registers a push-to-start token for chat activities,
// the Worker's chat route folds the reply's events into the activity state (ChatLivePusher) and hands it to the `main`
// Durable Object (ChatLiveService), which push-starts the activity on every device with a token except the sender's, then
// updates and ends it once the device has handed back the activity's update token.
//
// Free of Cloudflare imports so it runs under plain node in the tests; the APNs wire work is apns.ts.
//
// Storage (in the one `main` Durable Object, next to live.ts and edit-live.ts):
//   live:chatstart:<key id>  {token, env, updatedAt}   a device's push-to-start token for chat activities
//   live:chat:<thread>       ChatLiveRecord            the reply being shown; replaced by the next reply, dropped after an hour
//
// Routes (inside the Durable Object; the Worker's gate lets the first two through, keyed):
//   PUT|DELETE /live/chat-start-token              {"token": "<hex>", "environment": "sandbox"|"production"}
//   PUT        /live/chats/<thread>                {"token": "<hex>", "environment": ...}  a push-started activity's token
//   POST       /live/chats/<thread>/state          from the Worker (x-internal-key): {key_id, prompt, state}

import type { ApnsClient, ApnsPush, Environment } from "./apns";
import { KEY_ID_HEADER } from "./headers";
import { TOKEN_REGEX } from "./live";
import type { KV } from "./webp";

export const CHAT_START_PREFIX = "live:chatstart:";
export const CHAT_LIVE_PREFIX = "live:chat:";
export const CHAT_THREAD_REGEX = /^[A-Za-z0-9]{16}$/;
export const CHAT_LIVE_MAX_BODY = 4096;
// More reply text goes to the Durable Object at most this often; the DO pushes text at most every CHAT_LIVE_TEXT_PUSH_MS
// (iOS budgets Live Activity updates). A status change (a tool call, done) goes at once.
export const CHAT_LIVE_TEXT_MS = 3000;
export const CHAT_LIVE_TEXT_PUSH_MS = 5000;
export const CHAT_LIVE_STALE_S = 90;
export const CHAT_LIVE_DISMISS_DONE_S = 600;
export const CHAT_LIVE_DISMISS_FAILED_S = 300;
export const CHAT_LIVE_TTL_MS = 60 * 60 * 1000;
export const CHAT_START_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000;
export const CHAT_PROMPT_MAX = 120;
export const CHAT_REPLY_MAX = 160;

// ChatLiveContentState in the app: Swift property names, `steps`, `failedSteps` and `shown` always present, absent
// optionals omitted, `since` in unix seconds.
export type ChatLiveStatus = "thinking" | "working" | "writing" | "done" | "failed";
export type ChatLiveState = {
    status: ChatLiveStatus;
    since: number;
    steps: number;
    failedSteps: number;
    tool?: string;
    reply?: string;
    shown: number;
    code?: string;
};

export const isChatLiveTerminal = (s: ChatLiveState) => s.status === "done" || s.status === "failed";

const KEY_ORDER = ["status", "since", "steps", "failedSteps", "tool", "reply", "shown", "code"] as const;
export function canonicalChat(s: ChatLiveState): ChatLiveState {
    const out: Record<string, unknown> = {};
    for (const k of KEY_ORDER) {
        const v = (s as Record<string, unknown>)[k];
        if (v !== undefined && v !== null) out[k] = v;
    }
    return out as ChatLiveState;
}
const sameState = (a: ChatLiveState | null, b: ChatLiveState) => a !== null && JSON.stringify(canonicalChat(a)) === JSON.stringify(canonicalChat(b));

// ---- words (the app's ChatLiveCopy, line for line) ---------------------------------------------------------------------

const TOOL_WORDS: Record<string, string> = {
    search: "searching your library",
    library: "looking through your library",
    post: "opening a post",
    look: "looking at pictures",
    show: "picking files to show",
    collage: "making a collage",
    links: "reading your links",
    collections: "reading your collections",
};

export function toolNames(code: string): string[] {
    const out: string[] = [];
    for (const m of code.matchAll(/cobalt\.([A-Za-z0-9_.]+)\s*\(/g)) {
        const parts = m[1]!.split(".").filter(Boolean);
        const last = parts[parts.length - 1];
        if (last && !out.includes(last)) out.push(last);
    }
    return out;
}

export function toolWords(code: string): string {
    const name = toolNames(code)[0];
    if (!name) return "running code";
    if (TOOL_WORDS[name]) return TOOL_WORDS[name]!;
    return `using ${name.replace(/_/g, " ").replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase()}`;
}

export function plain(markdown: string): string {
    const lines: string[] = [];
    for (const raw of markdown.split(/\r\n|\r|\n/)) {
        let line = raw.trim();
        if (line.startsWith("```")) continue;
        line = line.replace(/^[#>]+/, "");
        line = line.replace(/^[-*+] /, "");
        line = line.replace(/\*\*|__|`/g, "").trim();
        if (line) lines.push(line);
    }
    return lines.join(" ").split(" ").filter(Boolean).join(" ");
}

const chars = (s: string) => [...s];
export const clip = (s: string, n: number) => (chars(s).length <= n ? s : chars(s).slice(0, n - 1).join("").trim() + "…");
export const tail = (s: string, n: number) => (chars(s).length <= n ? s : "…" + chars(s).slice(-(n - 1)).join("").trim());

export function reasonOf(code: string | undefined): string {
    switch (code) {
        case "error.chat.interrupted":
            return "the reply was cut off";
        default:
            return "the reply failed";
    }
}

// ---- the tracker (the app's ChatLiveTracker) ----------------------------------------------------------------------------

export type Change = "none" | "minor" | "major";

export class ChatLiveTracker {
    state: ChatLiveState;
    private stepStatus = new Map<string, string>();
    private shownIds = new Set<string>();
    private collage = 0;
    private text = "";

    constructor(sinceMs: number) {
        this.state = { status: "thinking", since: Math.floor(sinceMs / 1000), steps: 0, failedSteps: 0, shown: 0 };
    }

    private get running() {
        return [...this.stepStatus.values()].includes("running");
    }

    apply(event: string, data: any): Change {
        if (isChatLiveTerminal(this.state)) return "none";
        const before = { ...this.state };
        switch (event) {
            case "text":
                if (typeof data?.delta !== "string" || !data.delta) return "none";
                this.text += data.delta;
                this.state.reply = tail(plain(this.text), CHAT_REPLY_MAX);
                if (!this.running) this.state.status = "writing";
                break;
            case "step": {
                const step = data?.step;
                if (!step || typeof step.id !== "string") return "none";
                this.stepStatus.set(step.id, String(step.status));
                this.state.steps = this.stepStatus.size;
                this.state.failedSteps = [...this.stepStatus.values()].filter((s) => s === "error").length;
                if (step.status === "running") {
                    this.state.status = "working";
                    this.state.tool = toolWords(typeof step.code === "string" ? step.code : "");
                } else if (!this.running) {
                    this.state.status = this.text ? "writing" : "thinking";
                }
                break;
            }
            case "posts":
                for (const id of Array.isArray(data?.post_ids) ? data.post_ids : []) if (typeof id === "string") this.shownIds.add(id);
                this.state.shown = this.shownIds.size + this.collage;
                break;
            case "collage":
                this.collage = typeof data?.collage?.total === "number" ? data.collage.total : 0;
                this.state.shown = this.shownIds.size + this.collage;
                break;
            case "done":
                this.finish(data?.message);
                break;
            case "error":
                this.state.status = "failed";
                this.state.code = typeof data?.code === "string" ? data.code : "error.api.generic";
                if (typeof data?.message?.text === "string" && data.message.text) this.state.reply = clip(plain(data.message.text), CHAT_REPLY_MAX);
                break;
            default:
                return "none";
        }
        if (sameState(before, this.state)) return "none";
        const s = this.state;
        return s.status === before.status && s.tool === before.tool && s.steps === before.steps && s.failedSteps === before.failedSteps && s.shown === before.shown
            ? "minor"
            : "major";
    }

    // The reply ended without a done or error event (the stream broke): it is shown as cut off.
    end(code = "error.chat.interrupted") {
        if (isChatLiveTerminal(this.state)) return;
        this.state.status = "failed";
        this.state.code = code;
    }

    private finish(message: any) {
        this.state.status = "done";
        const text = typeof message?.text === "string" ? message.text : this.text;
        const p = plain(text);
        if (p) this.state.reply = clip(p, CHAT_REPLY_MAX);
        else delete this.state.reply;
        for (const id of Array.isArray(message?.post_ids) ? message.post_ids : []) if (typeof id === "string") this.shownIds.add(id);
        if (typeof message?.collage?.total === "number") this.collage = message.collage.total;
        this.state.shown = this.shownIds.size + this.collage;
        if (Array.isArray(message?.steps) && message.steps.length > 0) {
            this.state.steps = Math.max(this.state.steps, message.steps.length);
            this.state.failedSteps = message.steps.filter((s: any) => s?.status === "error").length;
        }
    }
}

// ---- the Worker side: folds a reply's events and hands them to the Durable Object -----------------------------------------

export type ChatLivePost = (body: { key_id: string; prompt: string; state: ChatLiveState }) => Promise<{ targets: number } | null>;

// One per reply. `event` is called with every event the chat route emits; `close` when the reply is over (awaited by the
// reply's own waitUntil, since work after a response does not survive). After the first hand-over says no device wants the
// activity, nothing more is sent.
export class ChatLivePusher {
    private tracker: ChatLiveTracker;
    private chain: Promise<void> = Promise.resolve();
    private lastSent = 0;
    private pending = false;
    private off = false;
    private closed = false;

    constructor(
        private o: { thread: string; keyId: string; prompt: string; now: () => number; post: ChatLivePost },
    ) {
        this.tracker = new ChatLiveTracker(o.now());
        this.send();
    }

    get state(): ChatLiveState {
        return this.tracker.state;
    }

    event(name: string, data: unknown) {
        if (this.closed) return;
        const change = this.tracker.apply(name, data);
        if (change === "none") return;
        if (change === "minor" && this.o.now() - this.lastSent < CHAT_LIVE_TEXT_MS) {
            this.pending = true;
            return;
        }
        this.send();
    }

    async close(): Promise<void> {
        if (!this.closed) {
            this.closed = true;
            this.tracker.end();
            this.send();
        }
        await this.chain;
    }

    private send() {
        this.pending = false;
        this.lastSent = this.o.now();
        const state = canonicalChat({ ...this.tracker.state });
        const body = { key_id: this.o.keyId, prompt: clip(plain(this.o.prompt), CHAT_PROMPT_MAX), state };
        this.chain = this.chain.then(async () => {
            if (this.off) return;
            try {
                const r = await this.o.post(body);
                if (r && r.targets === 0) this.off = true;
            } catch (e) {
                console.error("[chat-live] hand-over failed", e instanceof Error ? e.message : String(e));
            }
        });
    }
}

// ---- the Durable Object side ------------------------------------------------------------------------------------------

export type ChatStartToken = { token: string; env: Environment; updatedAt: number };
export type ChatLiveTarget = {
    keyId: string;
    env: Environment;
    // the push-start went out (its outcome may be unknown: never sent twice)
    started: boolean;
    // the activity's update token, once the device handed it back
    token: string | null;
    sent: ChatLiveState | null;
    sentAt: number;
    ended: boolean;
};
export type ChatLiveRecord = {
    thread: string;
    senderKeyId: string;
    prompt: string;
    since: number;
    latest: ChatLiveState;
    targets: ChatLiveTarget[];
    createdAt: number;
};

const secs = (ms: number) => Math.floor(ms / 1000);

export function chatAlert(s: ChatLiveState, prompt: string): { title: string; body: string } | null {
    if (s.status === "done") return { title: "chat replied", body: s.reply ?? prompt };
    if (s.status === "failed") return { title: "chat couldn't reply", body: reasonOf(s.code) };
    return null;
}

export function chatStartPayload(thread: string, prompt: string, s: ChatLiveState, now: number) {
    return {
        aps: {
            timestamp: secs(now),
            event: "start",
            "attributes-type": "CobaltChatActivityAttributes",
            attributes: { thread, prompt, source: "other" },
            "content-state": canonicalChat(s),
            "stale-date": secs(now) + CHAT_LIVE_STALE_S,
            "input-push-token": 1,
            alert: { title: "chat is thinking", body: prompt },
        },
    };
}

export function chatUpdatePayload(s: ChatLiveState, prompt: string, now: number) {
    const terminal = isChatLiveTerminal(s);
    const aps: Record<string, unknown> = { timestamp: secs(now), event: terminal ? "end" : "update", "content-state": canonicalChat(s) };
    if (terminal) {
        aps["dismissal-date"] = secs(now) + (s.status === "done" ? CHAT_LIVE_DISMISS_DONE_S : CHAT_LIVE_DISMISS_FAILED_S);
        const alert = chatAlert(s, prompt);
        if (alert) aps.alert = alert;
    } else {
        aps["stale-date"] = secs(now) + CHAT_LIVE_STALE_S;
    }
    return { aps };
}

// What to push to a target that has its update token, or null when nothing should go now.
export function decideChatPush(t: Pick<ChatLiveTarget, "sent" | "sentAt">, next: ChatLiveState, prompt: string, now: number): ApnsPush | null {
    if (sameState(t.sent, next)) return null;
    const terminal = isChatLiveTerminal(next);
    const sent = t.sent;
    const textOnly =
        sent !== null && sent.status === next.status && sent.tool === next.tool && sent.steps === next.steps && sent.failedSteps === next.failedSteps && sent.shown === next.shown;
    if (!terminal && textOnly && now - t.sentAt < CHAT_LIVE_TEXT_PUSH_MS) return null;
    const counter = !terminal && textOnly;
    return {
        event: terminal ? "end" : "update",
        priority: counter ? 5 : 10,
        expiration: secs(now) + (counter ? 60 : 3600),
        payload: chatUpdatePayload(next, prompt, now),
    };
}

export type ChatLiveDeps = {
    storage: KV;
    now: () => number;
    // null: APNs is not configured; nothing is stored or pushed
    apns: ApnsClient | null;
};

type Reply = { status: number; body: unknown };
const ok = (body: Record<string, unknown> = {}): Reply => ({ status: 200, body: { status: "success", ...body } });
const bad = (): Reply => ({ status: 400, body: { status: "error", error: { code: "error.live.bad_request" } } });
const parse = (raw: string): any => {
    try {
        return JSON.parse(raw);
    } catch {
        return null;
    }
};
const isEnv = (v: unknown): v is Environment => v === "sandbox" || v === "production";

function sanitizeState(raw: any): ChatLiveState | null {
    if (!raw || typeof raw !== "object") return null;
    if (!["thinking", "working", "writing", "done", "failed"].includes(raw.status)) return null;
    const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.floor(v) : 0);
    const str = (v: unknown, max: number) => (typeof v === "string" && v ? clip(v, max) : undefined);
    if (typeof raw.since !== "number" || !Number.isFinite(raw.since)) return null;
    return canonicalChat({
        status: raw.status,
        since: Math.floor(raw.since),
        steps: n(raw.steps),
        failedSteps: n(raw.failedSteps),
        tool: str(raw.tool, 80),
        reply: str(raw.reply, CHAT_REPLY_MAX),
        shown: n(raw.shown),
        code: str(raw.code, 60),
    });
}

export class ChatLiveService {
    // one record change at a time (the Worker's hand-overs and the device's token can cross)
    private queue: Promise<unknown> = Promise.resolve();

    constructor(private d: ChatLiveDeps) {}

    private serial<T>(f: () => Promise<T>): Promise<T> {
        const run = this.queue.then(f, f);
        this.queue = run.catch(() => {});
        return run;
    }

    async putStartToken(keyId: string, raw: string): Promise<Reply> {
        const b = parse(raw);
        if (typeof b?.token !== "string" || !TOKEN_REGEX.test(b.token) || !isEnv(b.environment)) return bad();
        if (!this.d.apns) return ok({ pushing: false, reason: "not_configured" });
        await this.d.storage.put(`${CHAT_START_PREFIX}${keyId}`, { token: b.token, env: b.environment, updatedAt: this.d.now() } satisfies ChatStartToken);
        return ok({ pushing: true });
    }

    async deleteStartToken(keyId: string): Promise<Reply> {
        await this.d.storage.delete(`${CHAT_START_PREFIX}${keyId}`);
        return ok();
    }

    // A push-started activity's update token: catches the activity up with the reply (or ends it, when it already ended).
    putToken(keyId: string, thread: string, raw: string): Promise<Reply> {
        return this.serial(async () => {
            const b = parse(raw);
            if (typeof b?.token !== "string" || !TOKEN_REGEX.test(b.token) || !isEnv(b.environment)) return bad();
            const rec = await this.d.storage.get<ChatLiveRecord>(`${CHAT_LIVE_PREFIX}${thread}`);
            const target = rec?.targets.find((t) => t.keyId === keyId);
            if (!rec || !target) return ok({ pushing: false });
            if (target.token !== b.token) {
                target.token = b.token;
                target.env = b.environment;
                target.sent = null;
                target.sentAt = 0;
            }
            await this.pushTarget(rec, target);
            await this.save(rec);
            return ok({ pushing: !target.ended });
        });
    }

    // From the Worker's chat route. Returns how many devices are shown the reply (0: the Worker stops handing over).
    onState(thread: string, raw: string): Promise<Reply> {
        return this.serial(async () => {
            const b = parse(raw);
            const state = sanitizeState(b?.state);
            if (!state || typeof b?.key_id !== "string" || !b.key_id) return bad();
            const prompt = typeof b.prompt === "string" ? clip(plain(b.prompt), CHAT_PROMPT_MAX) : "";
            if (!this.d.apns) return ok({ targets: 0 });
            const key = `${CHAT_LIVE_PREFIX}${thread}`;
            let rec = await this.d.storage.get<ChatLiveRecord>(key);
            const now = this.d.now();
            if (!rec || rec.since !== state.since || rec.senderKeyId !== b.key_id) {
                // a new reply: every device with a chat start token but the sender's
                const targets: ChatLiveTarget[] = [];
                for (const [k, v] of await this.d.storage.list<ChatStartToken>({ prefix: CHAT_START_PREFIX })) {
                    const keyId = k.slice(CHAT_START_PREFIX.length);
                    if (keyId === b.key_id) continue;
                    if (now - v.updatedAt > CHAT_START_TOKEN_TTL_MS) {
                        await this.d.storage.delete(k);
                        continue;
                    }
                    targets.push({ keyId, env: v.env, started: false, token: null, sent: null, sentAt: 0, ended: false });
                }
                if (targets.length === 0) {
                    if (rec) await this.d.storage.delete(key);
                    return ok({ targets: 0 });
                }
                // the reply this replaces never ended on those devices: it simply stops being updated (it goes stale)
                rec = { thread, senderKeyId: b.key_id, prompt, since: state.since, latest: state, targets, createdAt: now };
                for (const t of targets) await this.start(rec, t, now);
            } else {
                rec.latest = state;
                for (const t of rec.targets) await this.pushTarget(rec, t);
            }
            await this.save(rec);
            return ok({ targets: rec.targets.filter((t) => !t.ended).length });
        });
    }

    private async save(rec: ChatLiveRecord) {
        const key = `${CHAT_LIVE_PREFIX}${rec.thread}`;
        if (rec.targets.every((t) => t.ended) || this.d.now() - rec.createdAt > CHAT_LIVE_TTL_MS) await this.d.storage.delete(key);
        else await this.d.storage.put(key, rec);
    }

    private async start(rec: ChatLiveRecord, t: ChatLiveTarget, now: number) {
        const apns = this.d.apns!;
        const startToken = await this.d.storage.get<ChatStartToken>(`${CHAT_START_PREFIX}${t.keyId}`);
        if (!startToken) {
            t.ended = true;
            return;
        }
        t.started = true;
        const push: ApnsPush = { event: "start", priority: 10, expiration: secs(now) + 300, payload: chatStartPayload(rec.thread, rec.prompt, rec.latest, now) };
        const dlv = await apns.deliver(startToken.token, startToken.env, push, `chat:${rec.thread}`);
        if (dlv.kind === "drop") {
            await this.d.storage.delete(`${CHAT_START_PREFIX}${t.keyId}`);
            t.ended = true;
        } else if (dlv.kind === "sent") {
            t.env = dlv.env;
            t.sent = rec.latest;
            t.sentAt = now;
        } else if (dlv.kind === "unhealthy" && !dlv.maybeDelivered) {
            t.ended = true; // never reached Apple: no activity to keep current
        }
    }

    private async pushTarget(rec: ChatLiveRecord, t: ChatLiveTarget) {
        const apns = this.d.apns;
        if (!apns || t.ended || !t.started || !t.token) return;
        const now = this.d.now();
        const push = decideChatPush(t, rec.latest, rec.prompt, now);
        if (!push) return;
        const dlv = await apns.deliver(t.token, t.env, push, `chat:${rec.thread}`);
        if (dlv.kind === "sent") {
            t.env = dlv.env;
            t.sent = rec.latest;
            t.sentAt = now;
            if (push.event === "end") t.ended = true;
        } else if (dlv.kind === "drop") {
            t.ended = true;
        }
    }
}

// ---- routing (inside the Durable Object) ---------------------------------------------------------------------------

export const isChatLiveRoute = (pathname: string) => pathname === "/live/chat-start-token" || pathname.startsWith("/live/chats/");

const toResponse = (r: Reply) => new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });

export async function handleChatLiveRoute(service: ChatLiveService, request: Request, internalKey: string): Promise<Response> {
    const p = new URL(request.url).pathname;
    const m = request.method;
    const body = async (): Promise<string | null> => {
        const declared = Number(request.headers.get("content-length"));
        if (Number.isFinite(declared) && declared > CHAT_LIVE_MAX_BODY) return null;
        const text = await request.text();
        return new TextEncoder().encode(text).length > CHAT_LIVE_MAX_BODY ? null : text;
    };
    if (p.startsWith("/live/chats/")) {
        const [thread, sub, ...rest] = p.slice("/live/chats/".length).split("/");
        if (!CHAT_THREAD_REGEX.test(thread ?? "") || rest.length > 0) return new Response(null, { status: 404 });
        if (sub === "state") {
            if (m !== "POST" || !internalKey || request.headers.get("x-internal-key") !== internalKey) return new Response(null, { status: 403 });
            const text = await body();
            return toResponse(text === null ? bad() : await service.onState(thread!, text));
        }
        if (sub !== undefined) return new Response(null, { status: 404 });
        const keyId = request.headers.get(KEY_ID_HEADER);
        if (!keyId) return new Response(null, { status: 403 });
        if (m !== "PUT") return new Response(null, { status: 404 });
        const text = await body();
        return toResponse(text === null ? bad() : await service.putToken(keyId, thread!, text));
    }
    // the Worker sets the key id after its D1 lookup; a request without it is refused
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });
    if (m === "PUT") {
        const text = await body();
        return toResponse(text === null ? bad() : await service.putStartToken(keyId, text));
    }
    if (m === "DELETE") return toResponse(await service.deleteStartToken(keyId));
    return new Response(null, { status: 404 });
}
