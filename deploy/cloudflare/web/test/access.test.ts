import { beforeAll, describe, expect, it } from "vitest";
import { verifyAccessJwt } from "../src/access";
import {
    AUD, NOW, NOW_S, OWNER, TEAM, cfg, goodClaims, makeJwksFetch, makeSigner, newCache, rawToken,
    type Signer,
} from "./support";

let signer: Signer;
let other: Signer; // a second, unrelated keypair reusing the same kid
beforeAll(async () => {
    signer = await makeSigner("kid-1");
    other = await makeSigner("kid-1");
});

// The JWKS endpoint only ever publishes `signer`'s key.
const verify = async (token: string | null) => {
    const { fetchFn, calls } = makeJwksFetch(() => [signer]);
    const r = await verifyAccessJwt(token, cfg, newCache(fetchFn), NOW);
    return { r, calls };
};

const reason = (r: Awaited<ReturnType<typeof verifyAccessJwt>>) => (r.ok ? "ok" : r.reason);

describe("verifyAccessJwt", () => {
    it("accepts a valid owner token and only fetches the hard-coded JWKS URL", async () => {
        const { r, calls } = await verify(await signer.sign(goodClaims()));
        expect(r).toEqual({ ok: true, email: OWNER });
        expect(calls).toEqual([`https://${TEAM}/cdn-cgi/access/certs`]);
    });
    it("accepts a string aud, an aud list with extras, and any email casing", async () => {
        expect((await verify(await signer.sign(goodClaims({ aud: AUD })))).r.ok).toBe(true);
        expect((await verify(await signer.sign(goodClaims({ aud: ["x", AUD] })))).r.ok).toBe(true);
        expect((await verify(await signer.sign(goodClaims({ email: "MaskeOwl@iCloud.com" })))).r.ok).toBe(true);
    });
    it("rejects a missing or malformed token", async () => {
        expect(reason((await verify(null)).r)).toBe("missing");
        expect(reason((await verify("")).r)).toBe("missing");
        expect(reason((await verify("a.b")).r)).toBe("malformed");
        expect(reason((await verify("a.b.c.d")).r)).toBe("malformed");
        expect(reason((await verify("!!!.@@@.###")).r)).toBe("malformed");
    });
    it("rejects the wrong aud (and a missing aud)", async () => {
        expect(reason((await verify(await signer.sign(goodClaims({ aud: ["other"] })))).r)).toBe("aud");
        expect(reason((await verify(await signer.sign(goodClaims({ aud: undefined })))).r)).toBe("aud");
        expect(reason((await verify(await signer.sign(goodClaims({ aud: [] })))).r)).toBe("aud");
    });
    it("rejects the wrong iss", async () => {
        expect(reason((await verify(await signer.sign(goodClaims({ iss: "https://evil.cloudflareaccess.com" })))).r)).toBe("iss");
        expect(reason((await verify(await signer.sign(goodClaims({ iss: TEAM })))).r)).toBe("iss");
    });
    it("rejects an expired token, honouring 60 s skew", async () => {
        expect(reason((await verify(await signer.sign(goodClaims({ exp: NOW_S - 61 })))).r)).toBe("exp");
        expect(reason((await verify(await signer.sign(goodClaims({ exp: NOW_S - 60 })))).r)).toBe("exp");
        expect((await verify(await signer.sign(goodClaims({ exp: NOW_S - 59 })))).r.ok).toBe(true);
        expect(reason((await verify(await signer.sign(goodClaims({ exp: undefined })))).r)).toBe("exp");
        expect(reason((await verify(await signer.sign(goodClaims({ exp: "9999999999" })))).r)).toBe("exp");
    });
    it("rejects nbf in the future, honouring 60 s skew", async () => {
        expect(reason((await verify(await signer.sign(goodClaims({ nbf: NOW_S + 61 })))).r)).toBe("nbf");
        expect((await verify(await signer.sign(goodClaims({ nbf: NOW_S + 60 })))).r.ok).toBe(true);
    });
    it("rejects the wrong email, a missing email, and an empty email", async () => {
        expect(reason((await verify(await signer.sign(goodClaims({ email: "someone@else.com" })))).r)).toBe("email");
        expect(reason((await verify(await signer.sign(goodClaims({ email: "xmaskeowl@icloud.com" })))).r)).toBe("email");
        expect(reason((await verify(await signer.sign(goodClaims({ email: undefined })))).r)).toBe("email");
        expect(reason((await verify(await signer.sign(goodClaims({ email: "" })))).r)).toBe("email");
        expect(reason((await verify(await signer.sign(goodClaims({ email: ["maskeowl@icloud.com"] })))).r)).toBe("email");
    });
    it("rejects alg none and HS256 without fetching any key", async () => {
        const claims = goodClaims();
        for (const alg of ["none", "HS256", "RS512", "ES256"]) {
            const { r, calls } = await verify(rawToken({ alg, kid: "kid-1" }, claims, "AAAA"));
            expect(reason(r)).toBe("alg");
            expect(calls).toEqual([]);
        }
        // "none" with the usual empty signature part
        expect(reason((await verify(rawToken({ alg: "none" }, claims))).r)).toBe("alg");
        // missing alg
        expect(reason((await verify(rawToken({ kid: "kid-1" }, claims, "AAAA"))).r)).toBe("alg");
    });
    it("HS256 signed with the public JWK material as the secret is rejected", async () => {
        const secret = new TextEncoder().encode(JSON.stringify(signer.jwk));
        const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
        const h = btoa(JSON.stringify({ alg: "HS256", kid: "kid-1" })).replace(/=+$/, "");
        const p = btoa(JSON.stringify(goodClaims())).replace(/=+$/, "");
        const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${h}.${p}`)));
        const s = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
        expect(reason((await verify(`${h}.${p}.${s}`)).r)).toBe("alg");
    });
    it("rejects an unknown kid after exactly one refetch attempt", async () => {
        const stranger = await makeSigner("not-in-jwks");
        const { r, calls } = await verify(await stranger.sign(goodClaims()));
        expect(reason(r)).toBe("unknown_kid");
        // initial load only: the cache was just fetched, so no second fetch inside the throttle window
        expect(calls.length).toBe(1);
    });
    it("rejects a valid-looking token signed by a different key with a known kid", async () => {
        const { r } = await verify(await other.sign(goodClaims()));
        expect(reason(r)).toBe("signature");
    });
    it("rejects a tampered payload", async () => {
        const t = await signer.sign(goodClaims({ email: "someone@else.com" }));
        const [h, , s] = t.split(".");
        const forgedPayload = btoa(JSON.stringify(goodClaims())).replace(/=+$/, "");
        expect(reason((await verify(`${h}.${forgedPayload}.${s}`)).r)).toBe("signature");
    });
    it("fails closed when the JWKS cannot be fetched", async () => {
        const cache = newCache(async () => new Response("nope", { status: 503 }));
        const r = await verifyAccessJwt(await signer.sign(goodClaims()), cfg, cache, NOW);
        expect(reason(r)).toBe("jwks");
        const boom = newCache(async () => { throw new Error("network"); });
        expect(reason(await verifyAccessJwt(await signer.sign(goodClaims()), cfg, boom, NOW))).toBe("jwks");
    });
});

describe("JWKS cache", () => {
    it("caches keys across verifications", async () => {
        const { calls, fetchFn } = makeJwksFetch(() => [signer]);
        const cache = newCache(fetchFn);
        const t = await signer.sign(goodClaims());
        await verifyAccessJwt(t, cfg, cache, NOW);
        await verifyAccessJwt(t, cfg, cache, NOW + 1000);
        expect(calls.length).toBe(1);
    });
    it("refetches once when a rotated-in kid appears, then accepts it", async () => {
        let live = [signer];
        const { calls, fetchFn } = makeJwksFetch(() => live);
        const cache = newCache(fetchFn);
        await verifyAccessJwt(await signer.sign(goodClaims()), cfg, cache, NOW);
        const rotated = await makeSigner("kid-2");
        live = [signer, rotated];
        const later = NOW + 60_000; // past the refetch throttle
        const r = await verifyAccessJwt(await rotated.sign(goodClaims()), cfg, cache, later);
        expect(r.ok).toBe(true);
        expect(calls.length).toBe(2);
    });
    it("does not refetch on every unknown kid (throttled)", async () => {
        const { calls, fetchFn } = makeJwksFetch(() => [signer]);
        const cache = newCache(fetchFn);
        const stranger = await makeSigner("zzz");
        for (let i = 0; i < 5; i++) {
            await verifyAccessJwt(await stranger.sign(goodClaims()), cfg, cache, NOW + i * 100);
        }
        expect(calls.length).toBe(1);
    });
    it("refreshes after the TTL", async () => {
        const { calls, fetchFn } = makeJwksFetch(() => [signer]);
        const cache = newCache(fetchFn);
        const t = await signer.sign(goodClaims({ exp: NOW_S + 10_000 }));
        await verifyAccessJwt(t, cfg, cache, NOW);
        await verifyAccessJwt(t, cfg, cache, NOW + 2 * 60 * 60 * 1000);
        expect(calls.length).toBe(2);
    });
});
