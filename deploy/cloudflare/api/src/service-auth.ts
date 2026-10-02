// Service authentication for the web Worker's library calls (see
// LIBRARY-CONTRACT.md, "Internal service auth"): the caller sends the internal
// COBALT_API_KEY in `x-cobalt-service`. A match counts as a valid API key with
// the key id "service:library"; anything else is ignored as if the header were
// absent (the request then needs an Api-Key like any other).

const sha256 = async (s: string) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// Constant-time comparison: both sides are hashed to 32 bytes first, so the
// time taken depends neither on where the values differ nor on their length.
export async function serviceAuthorized(
    header: string | null,
    secret: string | undefined,
): Promise<boolean> {
    if (!header || !secret) return false;
    const [a, b] = await Promise.all([sha256(header), sha256(secret)]);
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
    return diff === 0;
}
