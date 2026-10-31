// Device sessions (APP-API-CONTRACT.md section 42): an api_keys row with kind = 'session' whose token has the shape of
// a client key (lowercase UUIDv4), so every route and key_id column works unchanged. Only the token's SHA-256 is stored.
//
// The web Worker mints sessions too (POST /api/auth/web) and cannot import from this package:
// deploy/cloudflare/web/src/sessions.ts duplicates the SQL below character for character, and the web tests import
// this file to pin that (test/sessions.test.ts there).
import { hashKey, SESSION_TTL_MS } from "./keys";

// At most this many active sessions: minting one more revokes the least recently used (42.2).
export const MAX_SESSIONS = 50;
export const MAX_DEVICE_LENGTH = 40;
export const PLATFORMS = ["ios", "ipados", "mac", "web"] as const;
export type Platform = (typeof PLATFORMS)[number];

// An active session: not revoked, not expired (?1 = now).
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

export type SessionRow = {
    id: string;
    device: string | null;
    platform: string | null;
    created_at: number;
    last_used_at: number | null;
    expires_at: number | null;
    last_country: string | null;
};
export const SESSION_COLUMNS = "id, device, platform, created_at, last_used_at, expires_at, last_country";

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

export const sessionBody = (r: SessionRow, currentId: string | null): Session => ({
    id: r.id,
    device: r.device ?? "",
    platform: r.platform ?? "",
    created_at: r.created_at,
    last_used_at: r.last_used_at ?? r.created_at,
    expires_at: r.expires_at ?? 0,
    country: r.last_country ?? null,
    current: r.id === currentId,
});

// A device name as 42.3 allows it: 1..40 printable characters after trimming (no control characters or line breaks), else null.
export function cleanDevice(raw: unknown): string | null {
    if (typeof raw !== "string") return null;
    const s = raw.trim();
    const n = Array.from(s).length;
    if (n < 1 || n > MAX_DEVICE_LENGTH) return null;
    if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(s)) return null;
    return s;
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
