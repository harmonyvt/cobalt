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

// One statement: it checks that the key exists and is not revoked AND records
// the use. Returns the key's id (api_keys.id), or null for an unknown or
// revoked key. Throws if D1 is unavailable.
export async function lookupKey(
    db: D1Database,
    key: string,
    now: number,
): Promise<string | null> {
    const res = await db
        .prepare(
            "UPDATE api_keys SET last_used_at = ?1 WHERE key_hash = ?2 AND revoked_at IS NULL RETURNING id",
        )
        .bind(now, await hashKey(key))
        .all<{ id: string }>();
    return res.results[0]?.id ?? null;
}
