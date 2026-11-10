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

// ---- the per-isolate key cache --------------------------------------------------------------------------------------
// D1 is in Oceania and the check below is a write, so it was a full round trip in front of every request. A key that
// passed the check in the last KEY_CACHE_TTL_MS is answered from this isolate's memory instead, with no D1 call at all.
//
// The trade-off, accepted for the speed: in an isolate that has it cached, a revoked key or a signed-out session keeps
// working until its entry runs out, at most KEY_CACHE_TTL_MS after the check that cached it. That window is what a key
// revoked by the web Worker, or by another isolate of this one, gets. Two things keep it from being more than that
// (both in registry/http.ts): the routes that hand out or take away a credential never take the cache's word (`fresh`
// below), so a session signed out elsewhere cannot use its last minute to make itself a key; and a write through the
// account routes empties this isolate's cache, so the isolate that did the revoking refuses the key on its very next
// request.
// last_used_at, last_country and a session's sliding expiry are then written at most once a minute per isolate (by the
// next miss) instead of on every request, so the lists that show them (GET /auth/sessions, GET /auth/keys) can be up to
// a minute behind for every row but the caller's own.
//
// Only accepted keys are kept (an unknown, revoked or expired key asks D1 every time), under the key's SHA-256 hash,
// never the key itself.
export const KEY_CACHE_TTL_MS = 60_000;
export const KEY_CACHE_MAX = 500;

export class KeyCache {
    // key hash -> the key's id and the moment (ms) the entry stops counting. A Map keeps insertion order, so the first
    // entry is the oldest.
    private readonly entries = new Map<string, { id: string; until: number }>();

    constructor(
        readonly ttlMs: number = KEY_CACHE_TTL_MS,
        readonly max: number = KEY_CACHE_MAX,
    ) {}

    get size(): number {
        return this.entries.size;
    }

    // The cached key id for this hash, or null (never cached, or the entry has run out).
    get(hash: string, now: number): string | null {
        const hit = this.entries.get(hash);
        if (!hit) return null;
        if (now < hit.until) return hit.id;
        this.entries.delete(hash);
        return null;
    }

    // Remembers an accepted key until now + ttlMs, or until the row's own expires_at when that comes first.
    set(hash: string, id: string, now: number, expiresAt?: number | null): void {
        const until = Math.min(now + this.ttlMs, typeof expiresAt === "number" ? expiresAt : Infinity);
        this.entries.delete(hash);
        if (!(until > now)) return;
        while (this.entries.size >= this.max) {
            const oldest = this.entries.keys().next();
            if (oldest.done) break;
            this.entries.delete(oldest.value);
        }
        this.entries.set(hash, { id, until });
    }

    // Forgets one key by its hash (D1 has just refused it).
    drop(hash: string): void {
        this.entries.delete(hash);
    }

    // Forgets a key or session by its api_keys.id, for code that revokes one and knows which. A walk over at most `max`
    // entries.
    dropId(id: string): void {
        for (const [hash, entry] of this.entries) if (entry.id === id) this.entries.delete(hash);
    }

    // Forgets everything: what registry/http.ts does after a write through the account routes, which may have revoked
    // any number of keys and sessions.
    clear(): void {
        this.entries.clear();
    }
}

// One statement (section 42.2): it checks that the key exists, is not revoked and has not expired, AND records the use
// (last_used_at, last_country when known, and for a session the sliding expiry). Returns the key's id (api_keys.id), or
// null for an unknown, revoked or expired key (all three answer 401 error.api.auth.key.invalid). Throws if D1 is
// unavailable.
//
// With a `cache` (the Worker's one per isolate, src/index.ts), a key accepted in the last KEY_CACHE_TTL_MS is answered
// from it and D1 is not called; see KeyCache for what that costs. Without one, every call is the statement.
// `fresh` (the routes that must not act on a stale answer) asks D1 whatever the cache holds, and the cache then learns
// what D1 said: an accepted key is remembered anew, a refused one is forgotten.
export async function lookupKey(
    db: D1Database,
    key: string,
    now: number,
    country?: string | null,
    cache?: KeyCache,
    fresh = false,
    // a caller that already hashed the key (the capabilities name lookup) passes it, so the two statements start together
    knownHash?: string,
): Promise<string | null> {
    const hash = knownHash ?? (await hashKey(key));
    const cached = fresh ? null : (cache?.get(hash, now) ?? null);
    if (cached !== null) return cached;
    let res: D1Result<{ id: string; expires_at?: number | null }>;
    try {
        res = await db
            .prepare(
                `UPDATE api_keys SET last_used_at = ?1,
                    last_country = COALESCE(?3, last_country),
                    expires_at = CASE WHEN kind = 'session' THEN ?1 + ?4 ELSE expires_at END
                 WHERE key_hash = ?2 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?1)
                 RETURNING id, expires_at`,
            )
            .bind(now, hash, countryCode(country), SESSION_TTL_MS)
            .all<{ id: string; expires_at: number | null }>();
    } catch (e) {
        // A Worker deployed before migration 0026 was applied: the key check as it was, so the API stays up.
        if (!/no such column/i.test(e instanceof Error ? e.message : String(e))) throw e;
        res = await db
            .prepare("UPDATE api_keys SET last_used_at = ?1 WHERE key_hash = ?2 AND revoked_at IS NULL RETURNING id")
            .bind(now, hash)
            .all<{ id: string }>();
    }
    const row = res.results[0];
    if (!row) {
        cache?.drop(hash);
        return null;
    }
    // expires_at is the row's value after the update (a session's has just slid to now + SESSION_TTL_MS); the pre-0026
    // statement has no such column and nothing to cap.
    cache?.set(hash, row.id, now, row.expires_at);
    return row.id;
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
