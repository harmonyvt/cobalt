// Cloudflare Access JWT verification with plain WebCrypto (no dependencies).
//
// Why hand-rolled instead of `jose`: the accepted surface is one algorithm
// (RS256) and one key source (the team's JWKS), which is ~100 lines and keeps
// the Worker bundle free of third-party code on the auth path. Everything a
// verifier must not trust from the token (algorithm, issuer, key location) is
// pinned here instead of read from it.

export type AccessConfig = {
    teamDomain: string; // e.g. harmonyvt.cloudflareaccess.com
    aud: string; // Access application AUD tag
    ownerEmail: string;
};

export type JwtResult = { ok: true; email: string } | { ok: false; reason: string };

type Jwk = JsonWebKey & { kid?: string };

export const SKEW_SECONDS = 60;
const JWKS_TTL_MS = 60 * 60 * 1000; // Access rotates keys about every 6 weeks
const REFETCH_MIN_INTERVAL_MS = 30 * 1000; // bounds fetches an attacker can force with random kids

const jwksUrl = (teamDomain: string) => `https://${teamDomain}/cdn-cgi/access/certs`;

export type Fetcher = (url: string) => Promise<Response>;

// Signing keys for one team domain. The URL is derived from configuration
// only, never from the token. An unknown kid triggers one refetch (rotation),
// rate-limited so garbage tokens cannot turn this Worker into a fetch cannon.
export class JwksCache {
    private jwks = new Map<string, Jwk>();
    private imported = new Map<string, CryptoKey>();
    private fetchedAt = -Infinity;

    constructor(
        private teamDomain: string,
        private fetchFn: Fetcher = (u) => fetch(u),
    ) {}

    private async refresh(now: number) {
        this.fetchedAt = now; // count failures too, so an outage is not hammered
        const res = await this.fetchFn(jwksUrl(this.teamDomain));
        if (!res.ok) throw new Error(`jwks http ${res.status}`);
        const body = (await res.json()) as { keys?: Jwk[] };
        const next = new Map<string, Jwk>();
        for (const k of body.keys ?? []) {
            if (k.kid && k.kty === "RSA" && (!k.alg || k.alg === "RS256")) {
                next.set(k.kid, k);
            }
        }
        this.jwks = next;
        this.imported = new Map();
    }

    async getKey(kid: string, now: number): Promise<CryptoKey | null> {
        const stale = now - this.fetchedAt > JWKS_TTL_MS;
        if (stale) await this.refresh(now);
        let jwk = this.jwks.get(kid);
        if (!jwk && !stale && now - this.fetchedAt >= REFETCH_MIN_INTERVAL_MS) {
            await this.refresh(now);
            jwk = this.jwks.get(kid);
        }
        if (!jwk) return null;
        let key = this.imported.get(kid);
        if (!key) {
            key = await crypto.subtle.importKey(
                "jwk",
                { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
                { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
                false,
                ["verify"],
            );
            this.imported.set(kid, key);
        }
        return key;
    }
}

const b64uToBytes = (s: string): Uint8Array => {
    if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("bad base64url");
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(b, (c) => c.charCodeAt(0));
};

const parseJson = (s: string): unknown => JSON.parse(new TextDecoder().decode(b64uToBytes(s)));

const isObject = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v);

const fail = (reason: string): JwtResult => ({ ok: false, reason });

// Returns ok only if the token is a correctly signed RS256 Access token for
// this application (aud), this team (iss), currently valid, issued to the owner.
export async function verifyAccessJwt(
    token: string | null,
    cfg: AccessConfig,
    jwks: JwksCache,
    now: number = Date.now(),
): Promise<JwtResult> {
    if (!token) return fail("missing");
    const parts = token.split(".");
    if (parts.length !== 3) return fail("malformed");
    const [h, p, s] = parts as [string, string, string];

    let header: unknown, payload: unknown, sig: Uint8Array;
    try {
        header = parseJson(h);
        payload = parseJson(p);
        sig = b64uToBytes(s);
    } catch {
        return fail("malformed");
    }
    if (!isObject(header) || !isObject(payload)) return fail("malformed");

    // Pin the algorithm before touching any key: rejects "none" and HS256
    // (the classic key-confusion attack on RSA public keys).
    if (header.alg !== "RS256") return fail("alg");
    if (typeof header.kid !== "string" || !header.kid) return fail("kid");

    let key: CryptoKey | null;
    try {
        key = await jwks.getKey(header.kid, now);
    } catch {
        return fail("jwks");
    }
    if (!key) return fail("unknown_kid");

    const valid = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        key,
        sig,
        new TextEncoder().encode(`${h}.${p}`),
    );
    if (!valid) return fail("signature");

    const nowSec = Math.floor(now / 1000);
    const { aud, iss, exp, nbf, email } = payload;

    const audList = Array.isArray(aud) ? aud : typeof aud === "string" ? [aud] : [];
    if (!audList.includes(cfg.aud)) return fail("aud");
    if (iss !== `https://${cfg.teamDomain}`) return fail("iss");
    if (typeof exp !== "number" || !(nowSec < exp + SKEW_SECONDS)) return fail("exp");
    if (nbf !== undefined && (typeof nbf !== "number" || nbf - SKEW_SECONDS > nowSec)) {
        return fail("nbf");
    }
    if (
        typeof email !== "string" ||
        !email ||
        !cfg.ownerEmail ||
        email.toLowerCase() !== cfg.ownerEmail.toLowerCase()
    ) {
        return fail("email");
    }
    return { ok: true, email };
}
