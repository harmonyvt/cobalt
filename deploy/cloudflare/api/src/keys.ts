// D1 side of the key gate. Kept apart from index.ts (which imports the
// Containers library and so cannot load under plain node) so it can be tested
// against real SQLite.

const hex = (buf: ArrayBuffer) =>
    [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Lowercase hex SHA-256 of the key string, the only form ever stored. The web
// Worker (deploy/cloudflare/web/src/keys.ts) hashes identically when it creates
// a key; both test suites pin the same vector.
export async function hashKey(key: string): Promise<string> {
    return hex(
        await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)),
    );
}

// A device session (APP-API-CONTRACT.md section 42) lives this long after its last use: every accepted lookup slides
// its expires_at to now + SESSION_TTL_MS. Keys (kind = 'key') have no expiry.
export const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;

// One statement (section 42.2): it checks that the key exists, is not revoked and has not expired, AND records the use
// (last_used_at, last_country when known, and for a session the sliding expiry). Returns the key's id (api_keys.id), or
// null for an unknown, revoked or expired key (all three answer 401 error.api.auth.key.invalid). Throws if D1 is
// unavailable.
export async function lookupKey(
    db: D1Database,
    key: string,
    now: number,
    country?: string | null,
): Promise<string | null> {
    const hash = await hashKey(key);
    let res: D1Result<{ id: string }>;
    try {
        res = await db
            .prepare(
                `UPDATE api_keys SET last_used_at = ?1,
                    last_country = COALESCE(?3, last_country),
                    expires_at = CASE WHEN kind = 'session' THEN ?1 + ?4 ELSE expires_at END
                 WHERE key_hash = ?2 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?1)
                 RETURNING id`,
            )
            .bind(now, hash, countryCode(country), SESSION_TTL_MS)
            .all<{ id: string }>();
    } catch (e) {
        // A Worker deployed before migration 0026 was applied: the key check as it was, so the API stays up.
        if (!/no such column/i.test(e instanceof Error ? e.message : String(e))) throw e;
        res = await db
            .prepare("UPDATE api_keys SET last_used_at = ?1 WHERE key_hash = ?2 AND revoked_at IS NULL RETURNING id")
            .bind(now, hash)
            .all<{ id: string }>();
    }
    return res.results[0]?.id ?? null;
}

// cf.country is a two-letter code (or "XX"/"T1"); anything else is not stored.
export function countryCode(country: unknown): string | null {
    return typeof country === "string" && /^[A-Z0-9]{2}$/.test(country) ? country : null;
}

// The request's cf.country, when the runtime gave one.
export function countryOf(request: Request | undefined): string | null {
    const cf = (request as { cf?: { country?: unknown } } | undefined)?.cf;
    return countryCode(cf?.country);
}
