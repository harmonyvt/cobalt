import { JwksCache, type AccessConfig } from "../src/access";

export const TEAM = "harmonyvt.cloudflareaccess.com";
export const AUD = "9afe49f50618965d109d9205999018b35bf49ec1847cd6465afb6330fc009b66";
export const OWNER = "maskeowl@icloud.com";
export const WEB_ORIGIN = "https://cobalt.capybaraharmony.com";
export const NOW = 1_800_000_000_000; // ms
export const NOW_S = NOW / 1000;

export const cfg: AccessConfig = { teamDomain: TEAM, aud: AUD, ownerEmail: OWNER };

const b64u = (b: ArrayBuffer | Uint8Array | string) => {
    const bytes = typeof b === "string" ? new TextEncoder().encode(b) : new Uint8Array(b);
    let s = "";
    for (const x of bytes) s += String.fromCharCode(x);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

export type Signer = {
    kid: string;
    jwk: JsonWebKey;
    sign(claims: Record<string, unknown>, header?: Record<string, unknown>): Promise<string>;
};

export async function makeSigner(kid = "kid-1"): Promise<Signer> {
    const pair = (await crypto.subtle.generateKey(
        {
            name: "RSASSA-PKCS1-v1_5",
            modulusLength: 2048,
            publicExponent: new Uint8Array([1, 0, 1]),
            hash: "SHA-256",
        },
        true,
        ["sign", "verify"],
    )) as CryptoKeyPair;
    const jwk: JsonWebKey & { kid: string } = { ...((await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey), kid, alg: "RS256", use: "sig" };
    return {
        kid,
        jwk,
        async sign(claims, header = {}) {
            const h = b64u(JSON.stringify({ alg: "RS256", kid, typ: "JWT", ...header }));
            const p = b64u(JSON.stringify(claims));
            const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(`${h}.${p}`));
            return `${h}.${p}.${b64u(sig)}`;
        },
    };
}

export const goodClaims = (over: Record<string, unknown> = {}) => ({
    aud: [AUD],
    iss: `https://${TEAM}`,
    email: OWNER,
    iat: NOW_S - 10,
    nbf: NOW_S - 10,
    exp: NOW_S + 3600,
    type: "app",
    ...over,
});

export const rawToken = (header: object, claims: object, sig = "") =>
    `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(claims))}.${sig}`;

// A JWKS endpoint stub. Records every URL it was asked for.
export function makeJwksFetch(signers: () => Signer[]) {
    const calls: string[] = [];
    const fetchFn = async (url: string) => {
        calls.push(url);
        return new Response(JSON.stringify({ keys: signers().map((s) => s.jwk) }), {
            headers: { "content-type": "application/json" },
        });
    };
    return { calls, fetchFn };
}

export const newCache = (fetchFn: (u: string) => Promise<Response>) => new JwksCache(TEAM, fetchFn);
