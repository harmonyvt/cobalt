// Device sessions (APP-API-CONTRACT.md section 42), the web Worker's copy. The API Worker owns the same code in
// deploy/cloudflare/api/src/sessions.ts; this Worker cannot import from that package, so the SQL below is duplicated
// character for character and test/sessions.test.ts imports the API's file to pin that they stay identical.
import { hashKey } from "./keys";

export const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const MAX_SESSIONS = 50;
export const MAX_DEVICE_LENGTH = 40;
export const PLATFORMS = ["ios", "ipados", "mac", "web"] as const;
export type Platform = (typeof PLATFORMS)[number];

export const ACTIVE_SESSION_SQL = "kind = 'session' AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?1)";

// ?1 id, ?2 device (also the row's name), ?3 key_hash, ?4 prefix, ?5 now (created and last used), ?6 platform,
// ?7 email, ?8 expires_at, ?9 last_country (the signing-in request's, or NULL).
export const SESSION_INSERT_SQL =
    "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, last_used_at, kind, device, platform, email, expires_at, last_country) " +
    "VALUES (?1, ?2, ?3, ?4, ?5, ?5, 'session', ?2, ?6, ?7, ?8, ?9)";

// ?1 now, ?2 MAX_SESSIONS: revokes every active session past the newest-used MAX_SESSIONS.
export const SESSION_CAP_SQL =
    "UPDATE api_keys SET revoked_at = ?1 WHERE id IN (SELECT id FROM api_keys WHERE " +
    ACTIVE_SESSION_SQL +
    " ORDER BY last_used_at DESC, created_at DESC, id DESC LIMIT -1 OFFSET ?2)";

// <session> (42.5)
export type Session = {
    id: string;
    device: string;
    platform: string;
    created_at: number;
    last_used_at: number;
    expires_at: number;
    country: string | null;
    current: boolean;
};

// A device name as 42.3 allows it: 1..40 printable characters after trimming (no control characters or line breaks), else null.
export function cleanDevice(raw: unknown): string | null {
    if (typeof raw !== "string") return null;
    const s = raw.trim();
    const n = Array.from(s).length;
    if (n < 1 || n > MAX_DEVICE_LENGTH) return null;
    if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(s)) return null;
    return s;
}

// cf.country is a two-letter code (or "XX"/"T1"); anything else is not stored.
export function countryOf(request: Request): string | null {
    const c = (request as { cf?: { country?: unknown } }).cf?.country;
    return typeof c === "string" && /^[A-Z0-9]{2}$/.test(c) ? c : null;
}

// A new session: the plaintext token goes back to the caller once and is never stored. Then the cap.
export async function mintSession(
    db: D1Database,
    s: { device: string; platform: Platform; email: string; country?: string | null },
    now: number,
): Promise<{ key: string; session: Session }> {
    const id = crypto.randomUUID();
    const key = crypto.randomUUID();
    const expiresAt = now + SESSION_TTL_MS;
    await db.prepare(SESSION_INSERT_SQL).bind(id, s.device, await hashKey(key), key.slice(0, 8), now, s.platform, s.email, expiresAt, s.country ?? null).run();
    await db.prepare(SESSION_CAP_SQL).bind(now, MAX_SESSIONS).run();
    return {
        key,
        session: { id, device: s.device, platform: s.platform, created_at: now, last_used_at: now, expires_at: expiresAt, country: s.country ?? null, current: true },
    };
}

// 42.4: "safari on mac", "chrome on windows", "firefox on linux", ...; "browser" when the browser is not recognised.
export function deviceFromUserAgent(ua: string | null): string {
    const u = ua ?? "";
    let browser: string | null = null;
    if (/Firefox\/|FxiOS\//.test(u)) browser = "firefox";
    else if (/Edg(e|A|iOS)?\//.test(u)) browser = "edge";
    else if (/OPR\/|Opera/.test(u)) browser = "opera";
    else if (/Chrome\/|CriOS\/|Chromium\//.test(u)) browser = "chrome";
    else if (/Safari\//.test(u) && /Version\//.test(u)) browser = "safari";
    if (!browser) return "browser";
    let os: string | null = null;
    if (/iPhone|iPod/.test(u)) os = "iphone";
    else if (/iPad/.test(u)) os = "ipad";
    else if (/Android/.test(u)) os = "android";
    else if (/CrOS/.test(u)) os = "chromeos";
    else if (/Macintosh|Mac OS X/.test(u)) os = "mac";
    else if (/Windows/.test(u)) os = "windows";
    else if (/Linux/.test(u)) os = "linux";
    return os ? `${browser} on ${os}` : browser;
}
