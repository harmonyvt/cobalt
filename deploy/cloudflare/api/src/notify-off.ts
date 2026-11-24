// The Hark notification bridge is gone (Phase 1 de-slop, 2026-11): nothing sends a push through a
// webhook any more, and `GET /capabilities` has said `features.notify_bridge: false` since the owner
// turned it off on 2026-10-23. Apps that read the flag never call these routes; this file only keeps
// the answers an older build or the extension would get from them, so a stray call still sees the
// same shape it always saw while the bridge was off: `bridge: false`, nothing stored, nothing sent.
//
// Free of Cloudflare imports so it runs under plain node in the tests.

import { STUDIO_SID_REGEX } from "./gate";
import { KEY_ID_HEADER } from "./headers";

export const NOTIFY_MAX_BODY_BYTES = 1024;
const NOTIFY_MAX_LABEL = 60;
const NOTIFY_EVENTS = ["saved", "rendered", "failed"] as const;
type NotifyEvent = (typeof NOTIFY_EVENTS)[number];

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

// PUT /studio/line/notify takes no body: empty, or an empty JSON object (section 17.8).
export function isEmptyLineBody(raw: string): boolean {
    if (raw.trim() === "") return true;
    try {
        const b: unknown = JSON.parse(raw);
        return isRecord(b) && Object.keys(b).length === 0;
    } catch {
        return false;
    }
}

// What a save's opt-in answers while the bridge is off (the same body the bridge's own `put` gave).
export const bridgeOffBody = (parsed: { on: NotifyEvent[]; label: string | null }) => ({
    status: "success",
    bridge: false,
    on: parsed.on,
    label: parsed.label,
    expires_at: null,
});

const err = (status: number, code: string): Response =>
    new Response(JSON.stringify({ status: "error", error: { code } }), { status, headers: { "content-type": "application/json" } });

// PUT|DELETE /studio/<sid>/notify
export const isNotifyRoute = (pathname: string): boolean => {
    const parts = pathname.split("/"); // "", "studio", sid, "notify"
    return parts.length === 4 && parts[1] === "studio" && parts[3] === "notify" && STUDIO_SID_REGEX.test(parts[2] ?? "");
};

// Never calls super.fetch and never wakes the container. The Worker sets the key id after its D1 lookup; a request
// without it is refused. The session must be the caller's (404 otherwise), the body must parse (400 otherwise);
// then the answer is always "bridge off".
export async function handleNotifyRoute(db: D1Database, request: Request): Promise<Response> {
    const keyId = request.headers.get(KEY_ID_HEADER);
    if (!keyId) return new Response(null, { status: 403 });
    const sid = new URL(request.url).pathname.split("/")[2] ?? "";
    if (request.method !== "PUT" && request.method !== "DELETE") return new Response(null, { status: 404 });
    let parsed: ReturnType<typeof parseOptIn> = null;
    if (request.method === "PUT") {
        const declared = Number(request.headers.get("content-length"));
        if (Number.isFinite(declared) && declared > NOTIFY_MAX_BODY_BYTES) return err(400, "error.notify.invalid");
        const text = await request.text();
        if (new TextEncoder().encode(text).length > NOTIFY_MAX_BODY_BYTES) return err(400, "error.notify.invalid");
        parsed = parseOptIn(text);
        if (!parsed) return err(400, "error.notify.invalid");
    }
    let owned: boolean;
    try {
        const row = await db.prepare("SELECT key_id FROM studio_sessions WHERE id = ?1").bind(sid).first<{ key_id: string | null }>();
        owned = !!row && row.key_id === keyId;
    } catch {
        return err(503, "error.api.generic");
    }
    if (!owned) return err(404, "error.studio.not_found");
    if (!parsed) return new Response(null, { status: 204 });
    return new Response(JSON.stringify(bridgeOffBody(parsed)), { status: 200, headers: { "content-type": "application/json" } });
}
