// Live Activities for editor renders (APP-API-CONTRACT.md section 32, apple/CONTRACT-EDITOR.md section 11): the app starts an
// activity for a render it asked for and hands over the activity's update token; the server keeps the Dynamic Island and the
// Lock Screen current with the app closed, from the EditRenderer's ticks, and ends it when the render ends.
//
// Lives in the one `main` Durable Object next to the run store of live.ts, so every APNs push still comes from one place
// with one provider token (Apple refuses a token re-signed more often than every 20 minutes). Free of Cloudflare imports so
// it runs under plain node in the tests.
//
// Storage: live:edit:<rid>  EditLiveRecord   one per render with an activity; deleted after its end push (or a dead token)
//
// Routes (inside the Durable Object; the Worker's gate lets only the first two through, keyed):
//   PUT    /live/edits/<rid>        {"token": "<hex>", "env": "sandbox"|"production"}  the app's activity token
//   DELETE /live/edits/<rid>        the app ended the activity itself
//   POST   /live/edits/<rid>/push   from the EditRenderer (x-internal-key): the render moved, push if it changed enough

import type { ApnsClient, ApnsPush, Environment } from "./apns";
import { KEY_ID_HEADER } from "./headers";
import { RENDER_SELECT, renderProgress, type RenderRow } from "./edits";
import { TOKEN_REGEX } from "./live";
import { plainReason } from "./notify";
import type { KV } from "./webp";

export const EDIT_LIVE_PREFIX = "live:edit:";
export const RENDER_ID_REGEX = /^[A-Za-z0-9]{20}$/;
export const EDIT_LIVE_MAX_BODY = 1024;
// A progress push goes at most every this often, and only when the bar moved at least EDIT_LIVE_MIN_STEP (iOS budgets
// Live Activity updates; a 5 s tick for a 10-minute render would be 120 pushes).
export const EDIT_LIVE_MIN_GAP_MS = 10_000;
export const EDIT_LIVE_MIN_STEP = 0.04;
// No push for this long (a stuck render, a lost container) and iOS greys the activity out.
export const EDIT_LIVE_STALE_S = 180;
export const EDIT_LIVE_DISMISS_DONE_S = 900;
export const EDIT_LIVE_DISMISS_FAILED_S = 300;
// A record whose render never moves again (the token arrived for a render that already ended) is dropped after this.
export const EDIT_LIVE_TTL_MS = 6 * 60 * 60 * 1000;

export type EditLiveStatus = "queued" | "preparing" | "rendering" | "finishing" | "done" | "failed" | "cancelled";

// EditLiveContentState in the app (Swift property names, camelCase, absent optionals omitted, times in unix seconds).
export type EditLiveState = {
    status: EditLiveStatus;
    since: number;
    title: string;
    progress?: number;
    queueAhead?: number;
    resultSeconds?: number;
    resultWidth?: number;
    resultHeight?: number;
    resultBytes?: number;
    code?: string;
};

export type EditLiveRecord = {
    rid: string;
    keyId: string;
    token: string;
    env: Environment;
    sent: EditLiveState | null;
    sentAt: number;
    createdAt: number;
};

const secs = (ms: number) => Math.floor(ms / 1000);
const round3 = (n: number) => Math.round(n * 1000) / 1000;

export const isEditLiveTerminal = (s: EditLiveState) => s.status === "done" || s.status === "failed" || s.status === "cancelled";

// The render row (RENDER_SELECT) as the activity shows it. `since` is when the current status began, as far as the row knows.
export function editLiveState(r: RenderRow): EditLiveState {
    const title = (r.title || "untitled edit").slice(0, 120);
    const status: EditLiveStatus =
        r.status === "error"
            ? r.error_code === "error.edit.cancelled"
                ? "cancelled"
                : "failed"
            : (["queued", "preparing", "rendering", "finishing", "done", "cancelled"] as const).find((s) => s === r.status) ?? "queued";
    const since = secs(
        status === "queued" ? r.created_at : isEditLiveTerminal({ status } as EditLiveState) ? (r.finished_at ?? r.created_at) : (r.started_at ?? r.created_at),
    );
    const s: EditLiveState = { status, since, title };
    const p = renderProgress(r);
    if (p !== null) s.progress = round3(p);
    if (status === "queued") s.queueAhead = r.queue_ahead ?? 0;
    if (status === "done") {
        if (typeof r.duration === "number") s.resultSeconds = round3(r.duration);
        if (typeof r.width === "number") s.resultWidth = r.width;
        if (typeof r.height === "number") s.resultHeight = r.height;
        if (typeof r.bytes === "number") s.resultBytes = r.bytes;
    }
    if (status === "failed" && r.error_code) s.code = r.error_code;
    return s;
}

const KEY_ORDER = ["status", "since", "title", "progress", "queueAhead", "resultSeconds", "resultWidth", "resultHeight", "resultBytes", "code"] as const;
export function canonicalEdit(s: EditLiveState): EditLiveState {
    const out: Record<string, unknown> = {};
    for (const k of KEY_ORDER) {
        const v = (s as Record<string, unknown>)[k];
        if (v !== undefined && v !== null) out[k] = v;
    }
    return out as EditLiveState;
}
const same = (a: EditLiveState | null, b: EditLiveState) => a !== null && JSON.stringify(canonicalEdit(a)) === JSON.stringify(canonicalEdit(b));

export function editLivePayload(s: EditLiveState, now: number) {
    const aps: Record<string, unknown> = {
        timestamp: secs(now),
        event: isEditLiveTerminal(s) ? "end" : "update",
        "content-state": canonicalEdit(s),
    };
    if (s.status === "done") {
        aps["dismissal-date"] = secs(now) + EDIT_LIVE_DISMISS_DONE_S;
        aps.alert = { title: "video ready", body: s.title };
    } else if (s.status === "failed") {
        aps["dismissal-date"] = secs(now) + EDIT_LIVE_DISMISS_FAILED_S;
        aps.alert = { title: "couldn't render", body: `${s.title} — ${s.code ? plainReason(s.code) : "something went wrong"}` };
    } else if (s.status === "cancelled") {
        aps["dismissal-date"] = secs(now);
    } else {
        aps["stale-date"] = secs(now) + EDIT_LIVE_STALE_S;
    }
    return { aps };
}

// What a push of `next` after `rec.sent` would be, or null when nothing should go now.
export function decideEditPush(rec: Pick<EditLiveRecord, "sent" | "sentAt">, next: EditLiveState, now: number): ApnsPush | null {
    if (same(rec.sent, next)) return null;
    const terminal = isEditLiveTerminal(next);
    const statusChanged = rec.sent === null || rec.sent.status !== next.status || rec.sent.queueAhead !== next.queueAhead;
    if (!terminal && !statusChanged) {
        if (now - rec.sentAt < EDIT_LIVE_MIN_GAP_MS) return null;
        if (Math.abs((next.progress ?? 0) - (rec.sent?.progress ?? 0)) < EDIT_LIVE_MIN_STEP) return null;
    }
    const counter = !terminal && !statusChanged;
    return {
        event: terminal ? "end" : "update",
        priority: counter ? 5 : 10,
        expiration: secs(now) + (counter ? 60 : 3600),
        payload: editLivePayload(next, now),
    };
}

export type EditLiveDeps = {
    storage: KV;
    db: D1Database;
    now: () => number;
    // null: APNs is not configured; tokens are refused with pushing: false and nothing is stored
    apns: ApnsClient | null;
};

type Reply = { status: number; body: unknown };
const bad = (): Reply => ({ status: 400, body: { status: "error", error: { code: "error.live.bad_request" } } });

export class EditLiveService {
    constructor(private d: EditLiveDeps) {}

    private key(rid: string) {
        return `${EDIT_LIVE_PREFIX}${rid}`;
    }

    private async row(rid: string): Promise<RenderRow | null> {
        return await this.d.db.prepare(`${RENDER_SELECT} WHERE r.id = ?1`).bind(rid).first<RenderRow>();
    }

    async putToken(keyId: string, rid: string, raw: string): Promise<Reply> {
        let body: unknown;
        try {
            body = JSON.parse(raw);
        } catch {
            return bad();
        }
        const b = body as { token?: unknown; env?: unknown };
        if (typeof b?.token !== "string" || !TOKEN_REGEX.test(b.token)) return bad();
        if (b.env !== "sandbox" && b.env !== "production") return bad();
        if (!this.d.apns) return { status: 200, body: { status: "success", pushing: false, reason: "not_configured" } };
        const row = await this.row(rid);
        if (!row) return { status: 404, body: { status: "error", error: { code: "error.edit.not_found" } } };
        const prev = await this.d.storage.get<EditLiveRecord>(this.key(rid));
        const rec: EditLiveRecord = {
            rid,
            keyId,
            token: b.token,
            env: b.env,
            // a new token (a new activity) has been sent nothing yet; the same token keeps what it was sent
            sent: prev && prev.token === b.token ? prev.sent : null,
            sentAt: prev && prev.token === b.token ? prev.sentAt : 0,
            createdAt: prev?.createdAt ?? this.d.now(),
        };
        await this.d.storage.put(this.key(rid), rec);
        // the render may have moved (or ended) between the app's last poll and now: catch the activity up
        await this.pushRow(rec, row);
        return { status: 200, body: { status: "success", pushing: true } };
    }

    async deleteToken(rid: string): Promise<Reply> {
        await this.d.storage.delete(this.key(rid));
        return { status: 200, body: { status: "success" } };
    }

    // From the EditRenderer after a tick that held this render. Cheap when the render has no activity (one storage read).
    async onRender(rid: string): Promise<{ pushed: boolean }> {
        const rec = await this.d.storage.get<EditLiveRecord>(this.key(rid));
        if (!rec || !this.d.apns) return { pushed: false };
        if (this.d.now() - rec.createdAt > EDIT_LIVE_TTL_MS) {
            await this.d.storage.delete(this.key(rid));
            return { pushed: false };
        }
        const row = await this.row(rid);
        if (!row) {
            await this.d.storage.delete(this.key(rid));
            return { pushed: false };
        }
        return { pushed: await this.pushRow(rec, row) };
    }

    private async pushRow(rec: EditLiveRecord, row: RenderRow): Promise<boolean> {
        const apns = this.d.apns;
        if (!apns) return false;
        const now = this.d.now();
        const next = editLiveState(row);
        const push = decideEditPush(rec, next, now);
        if (!push) return false;
        const dlv = await apns.deliver(rec.token, rec.env, push, rec.rid);
        switch (dlv.kind) {
            case "sent":
                if (push.event === "end") {
                    await this.d.storage.delete(this.key(rec.rid));
                } else {
                    await this.d.storage.put(this.key(rec.rid), { ...rec, env: dlv.env, sent: next, sentAt: now });
                }
                return true;
            case "drop":
                await this.d.storage.delete(this.key(rec.rid));
                return false;
            default:
                // unhealthy or quiet: nothing recorded, the next tick tries the newest state again
                return false;
        }
    }
}

// ---- routing (inside the Durable Object) ---------------------------------------------------------------------------

export const isEditLiveRoute = (pathname: string) => pathname.startsWith("/live/edits/");

const toResponse = (r: Reply) =>
    new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });

export async function handleEditLiveRoute(service: EditLiveService, request: Request, internalKey: string): Promise<Response> {
    const [rid, sub, ...rest] = new URL(request.url).pathname.slice("/live/edits/".length).split("/");
    if (!RENDER_ID_REGEX.test(rid ?? "") || rest.length > 0) return new Response(null, { status: 404 });
    const m = request.method;
    if (sub === "push") {
        if (m !== "POST" || !internalKey || request.headers.get("x-internal-key") !== internalKey) {
            return new Response(null, { status: 403 });
        }
        return toResponse({ status: 200, body: { status: "success", ...(await service.onRender(rid!)) } });
    }
    if (sub !== undefined) return new Response(null, { status: 404 });
    // the Worker sets the key id after its D1 lookup; a request without it is refused
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });
    if (m === "PUT") {
        const declared = Number(request.headers.get("content-length"));
        if (Number.isFinite(declared) && declared > EDIT_LIVE_MAX_BODY) return toResponse(bad());
        const text = await request.text();
        if (new TextEncoder().encode(text).length > EDIT_LIVE_MAX_BODY) return toResponse(bad());
        return toResponse(await service.putToken(keyId, rid!, text));
    }
    if (m === "DELETE") return toResponse(await service.deleteToken(rid!));
    return new Response(null, { status: 404 });
}
