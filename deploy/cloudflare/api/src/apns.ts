// APNs for Live Activities (APP-API-CONTRACT.md section 8.4): the ES256 provider
// token, the request headers and the answer handling. Pure: `fetch` (through the
// injected transport), `crypto.subtle` and `now` are injected, so it runs under
// plain node in the tests. No Cloudflare imports.
//
// Nothing secret is ever logged: not the key, not the JWT, not a full device
// token (a log line carries the first 8 characters only).

import { CeilingError, raceCeiling } from "./ceiling";
import type { KV } from "./webp";

export type Environment = "sandbox" | "production";
export type ApnsEvent = "start" | "update" | "end";

export const APNS_HOSTS: Record<Environment, string> = {
    production: "api.push.apple.com",
    sandbox: "api.sandbox.push.apple.com",
};
export const APNS_HOST_LIST: readonly string[] = [APNS_HOSTS.production, APNS_HOSTS.sandbox];

// A JWT is reused this long, and never re-signed inside the second window
// (APNs answers TooManyProviderTokenUpdates to frequent refreshes), except once
// after a 403 ExpiredProviderToken.
export const JWT_REUSE_MS = 50 * 60 * 1000;
export const JWT_MIN_REFRESH_MS = 20 * 60 * 1000;
// One HTTP attempt to Apple (or to the helper relay) is abandoned after this;
// the caller's own ceiling (LIVE_PUSH_MS = 3000) is just above it.
export const APNS_CALL_MS = 2500;
// Getting the transport ready (the helper transport's cold container start) has its
// own budget, spent BEFORE and OUTSIDE the per-attempt ceiling above: a start or end
// push used to time out while the container was still waking, mark the key unhealthy,
// and then be delivered anyway by the waking container.
export const APNS_WAKE_MS = 30_000;
// DO storage key of the provider token ({token, at, forced, kid, iss}).
export const JWT_STORAGE_KEY = "live:jwt";

export type ApnsConfig = {
    keyP8: string;
    keyId: string;
    teamId: string;
    bundleId: string;
    via: "worker" | "helper";
};

type EnvLike = {
    APNS_KEY_P8?: unknown;
    APNS_KEY_ID?: unknown;
    APNS_TEAM_ID?: unknown;
    APNS_BUNDLE_ID?: unknown;
    APNS_VIA?: unknown;
};

const nonEmpty = (v: unknown): v is string => typeof v === "string" && v.trim() !== "";

// All three secrets present and non-empty, else null (no pushes, capability
// false). The bundle id and transport have defaults.
export function apnsConfigFrom(env: EnvLike): ApnsConfig | null {
    if (!nonEmpty(env.APNS_KEY_P8) || !nonEmpty(env.APNS_KEY_ID) || !nonEmpty(env.APNS_TEAM_ID)) return null;
    return {
        keyP8: env.APNS_KEY_P8,
        keyId: env.APNS_KEY_ID.trim(),
        teamId: env.APNS_TEAM_ID.trim(),
        bundleId: nonEmpty(env.APNS_BUNDLE_ID) ? env.APNS_BUNDLE_ID.trim() : "com.capybaraharmony.cobalt",
        via: typeof env.APNS_VIA === "string" && env.APNS_VIA.trim().toLowerCase() === "helper" ? "helper" : "worker",
    };
}

export const livePushConfigured = (env: EnvLike): boolean => apnsConfigFrom(env) !== null;

// ---- base64 / JWT -----------------------------------------------------------------

export function base64url(bytes: Uint8Array): string {
    let s = "";
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const textBytes = (s: string) => new TextEncoder().encode(s);

// PEM (as one string; `\n` may arrive as real newlines or as the two characters
// backslash-n when a secrets file was escaped twice) -> the PKCS#8 DER bytes.
export function pemToDer(pem: string): Uint8Array {
    const body = pem
        .replace(/\\n/g, "\n")
        .replace(/-----BEGIN [A-Z ]+-----/g, "")
        .replace(/-----END [A-Z ]+-----/g, "")
        .replace(/[^A-Za-z0-9+/=]/g, "");
    const bin = atob(body);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

// ---- transport --------------------------------------------------------------------

// What goes to Apple: the same bytes whichever way they travel.
export type ApnsRequest = {
    host: string;
    path: string;
    headers: Record<string, string>;
    body: string;
};
export type ApnsAnswer = { status: number; reason: string | null; apnsId: string | null };
export type TransportMeta = {
    event: ApnsEvent;
    // a counter may be skipped while the container sleeps (helper transport); start,
    // end and the self-test wake it
    wake: boolean;
};
export type Transport = ((req: ApnsRequest, meta: TransportMeta) => Promise<ApnsAnswer>) & {
    // Runs before the first attempt of a delivery, outside the per-attempt ceiling and
    // under APNS_WAKE_MS. Throws SkippedPush to say "do not send this one" (a counter
    // while the helper's container sleeps).
    prepare?: (meta: TransportMeta) => Promise<void>;
};

// A transport that decided not to send (the helper relay with a sleeping container
// and a counter): not a failure, nothing changes, the next event sends the latest.
export class SkippedPush extends Error {
    constructor(why: string) {
        super(why);
        this.name = "SkippedPush";
    }
}

// Straight from the Worker / Durable Object: HTTP/2 is negotiated by the runtime.
export function fetchTransport(fetchFn: (url: string, init: RequestInit) => Promise<Response>): Transport {
    return async (req) => {
        const res = await fetchFn(`https://${req.host}${req.path}`, {
            method: "POST",
            headers: req.headers,
            body: req.body,
        });
        let reason: string | null = null;
        try {
            const j = (await res.json()) as { reason?: unknown };
            if (typeof j?.reason === "string") reason = j.reason;
        } catch {
            // 200 has no body
        }
        return { status: res.status, reason, apnsId: res.headers.get("apns-id") };
    };
}

// Through the helper's POST /apns (helper/server.js, node:http2): the DO still
// signed and built the request, the helper only relays the bytes.
export function helperTransport(d: {
    helper: (path: string, init?: RequestInit) => Promise<Response>;
    isRunning: () => boolean;
    ensureRunning: () => Promise<void>;
}): Transport {
    // Waking the container is `prepare`, not part of the attempt: the ApnsClient runs it
    // outside the per-attempt ceiling with its own budget, so a cold start is never
    // mistaken for a failed push.
    const prepare = async (meta: TransportMeta) => {
        if (d.isRunning()) return;
        if (!meta.wake) throw new SkippedPush("container asleep");
        await d.ensureRunning();
    };
    const send: Transport = async (req, meta) => {
        // asleep again between prepare and the call: a counter is still skipped
        if (!meta.wake && !d.isRunning()) throw new SkippedPush("container asleep");
        const res = await d.helper("/apns", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ host: req.host, path: req.path, headers: req.headers, body: req.body }),
        });
        if (!res.ok) throw new Error(`helper relay answered ${res.status}`);
        const j = (await res.json()) as { status?: unknown; reason?: unknown; apns_id?: unknown };
        if (typeof j?.status !== "number") throw new Error("helper relay sent no status");
        return {
            status: j.status,
            reason: typeof j.reason === "string" ? j.reason : null,
            apnsId: typeof j.apns_id === "string" ? j.apns_id : null,
        };
    };
    return Object.assign(send, { prepare });
}

// ---- the client -------------------------------------------------------------------

export type ApnsPush = {
    event: ApnsEvent;
    priority: 5 | 10;
    // unix seconds
    expiration: number;
    payload: unknown;
};

// What happened to one delivery, for the caller to record.
export type Delivery =
    | { kind: "sent"; env: Environment; status: 200; apnsId: string | null }
    // the token is dead: the caller forgets it
    | { kind: "drop"; env: Environment; status: number; reason: string | null }
    // a non-token failure (403 other, 5xx, network, ceiling, a provider token refused as
    // updated too often, a transport that could not be made ready): health bad for 10
    // min. `maybeDelivered`: the request left us but no answer came back (a transport
    // error or timeout after sending), so Apple may still have accepted it; false when
    // Apple answered with a refusal or nothing was sent (jwt or wake failure).
    | { kind: "unhealthy"; env: Environment; status: number; reason: string; maybeDelivered: boolean }
    // 429, or a counter skipped by the helper transport: nothing to record
    | { kind: "quiet"; env: Environment; status: number; reason: string | null };

const shortToken = (t: string) => t.slice(0, 8);
const shortRun = (r: string) => r.slice(0, 8);

export type ApnsDeps = ApnsConfig & {
    transport: Transport;
    now: () => number;
    callMs?: number;
    // budget for transport.prepare (the helper's cold start); APNS_WAKE_MS by default
    wakeMs?: number;
    // DO storage: the provider token is kept here so a Durable Object eviction does not
    // re-sign it (Apple refuses a new token within 20 minutes of the last one)
    storage?: KV;
    subtle?: SubtleCrypto;
    // where lines go (console by default); never given anything secret
    log?: (line: string) => void;
};

export class ApnsClient {
    private key: CryptoKey | null = null;
    private jwt: { token: string; at: number; forced: boolean } | null = null;
    private signing: Promise<string> | null = null;
    private loading: Promise<void> | null = null;
    private loaded = false;

    constructor(private d: ApnsDeps) {}

    get topic(): string {
        return `${this.d.bundleId}.push-type.liveactivity`;
    }
    get via(): "worker" | "helper" {
        return this.d.via;
    }

    private get subtle(): SubtleCrypto {
        return this.d.subtle ?? crypto.subtle;
    }

    private async importKey(): Promise<CryptoKey> {
        if (this.key) return this.key;
        this.key = await this.subtle.importKey(
            "pkcs8",
            pemToDer(this.d.keyP8),
            { name: "ECDSA", namedCurve: "P-256" },
            false,
            ["sign"],
        );
        return this.key;
    }

    private async sign(): Promise<string> {
        const iat = Math.floor(this.d.now() / 1000);
        const header = base64url(textBytes(JSON.stringify({ alg: "ES256", kid: this.d.keyId })));
        const claims = base64url(textBytes(JSON.stringify({ iss: this.d.teamId, iat })));
        const input = `${header}.${claims}`;
        const sig = await this.subtle.sign(
            { name: "ECDSA", hash: "SHA-256" },
            await this.importKey(),
            textBytes(input),
        );
        // WebCrypto's ECDSA signature is already the raw 64-byte r||s ES256 wants.
        return `${input}.${base64url(new Uint8Array(sig))}`;
    }

    // The persisted provider token ({token, at, forced, kid, iss}), read once per
    // instance. A token minted for another key id or team id (a rotated secret) is not
    // used. A storage failure only means a token is minted again.
    private load(): Promise<void> {
        if (this.loaded) return Promise.resolve();
        this.loading ??= (async () => {
            try {
                const v = await this.d.storage?.get<{ token?: unknown; at?: unknown; forced?: unknown; kid?: unknown; iss?: unknown }>(JWT_STORAGE_KEY);
                if (
                    v &&
                    !this.jwt &&
                    typeof v.token === "string" &&
                    typeof v.at === "number" &&
                    v.kid === this.d.keyId &&
                    v.iss === this.d.teamId
                ) {
                    this.jwt = { token: v.token, at: v.at, forced: v.forced === true };
                }
                this.loaded = true;
            } catch (e) {
                console.error("[live] reading the stored provider token failed:", e instanceof Error ? e.message : String(e));
            } finally {
                this.loading = null;
            }
        })();
        return this.loading;
    }

    // The provider token: reused for 50 minutes, across Durable Object evictions.
    // Concurrent callers share one signing.
    async token(): Promise<string> {
        await this.load();
        const now = this.d.now();
        if (this.jwt && now - this.jwt.at < JWT_REUSE_MS) return this.jwt.token;
        return this.mint(false);
    }

    private async mint(forced: boolean): Promise<string> {
        if (!this.signing) {
            this.signing = this.sign()
                .then(async (token) => {
                    this.jwt = { token, at: this.d.now(), forced };
                    try {
                        await this.d.storage?.put(JWT_STORAGE_KEY, { ...this.jwt, kid: this.d.keyId, iss: this.d.teamId });
                    } catch (e) {
                        console.error("[live] storing the provider token failed:", e instanceof Error ? e.message : String(e));
                    }
                    return token;
                })
                .finally(() => {
                    this.signing = null;
                });
        }
        return this.signing;
    }

    // After a 403 ExpiredProviderToken: sign once more. Returns null when that was
    // already done within the last 20 minutes (it did not help; do not hammer APNs
    // with token refreshes). A token that is no longer the one that failed was
    // already replaced by a concurrent push.
    private async refreshAfterExpired(failed: string): Promise<string | null> {
        const now = this.d.now();
        if (this.jwt && this.jwt.token !== failed) return this.jwt.token;
        if (this.jwt?.forced && now - this.jwt.at < JWT_MIN_REFRESH_MS) return null;
        return this.mint(true);
    }

    private requestFor(token: string, env: Environment, push: ApnsPush, jwt: string): ApnsRequest {
        return {
            host: APNS_HOSTS[env],
            path: `/3/device/${token}`,
            headers: {
                authorization: `bearer ${jwt}`,
                "apns-topic": this.topic,
                "apns-push-type": "liveactivity",
                "apns-priority": String(push.priority),
                "apns-expiration": String(push.expiration),
                "content-type": "application/json",
            },
            body: JSON.stringify(push.payload),
        };
    }

    private line(status: string, reason: string | null, push: ApnsPush, run: string, token: string, apnsId: string | null) {
        const text = `[live] apns ${status} ${reason ?? "-"} event=${push.event} pri=${push.priority} run=${shortRun(run)} token=${shortToken(token)} apns-id=${apnsId ?? "-"}`;
        (this.d.log ?? ((l) => console.log(l)))(text);
    }

    // One HTTP attempt. Never throws: a transport failure is status 0 with a
    // "transport: <message>" reason (the message scrubbed of the token and the jwt).
    private async attempt(
        token: string,
        env: Environment,
        push: ApnsPush,
        jwt: string,
        run: string,
        wake: boolean,
    ): Promise<ApnsAnswer & { skipped?: boolean }> {
        let answer: ApnsAnswer;
        try {
            answer = await raceCeiling(
                Promise.resolve().then(() => this.d.transport(this.requestFor(token, env, push, jwt), { event: push.event, wake })),
                this.d.callMs ?? APNS_CALL_MS,
                "apns",
            );
        } catch (e) {
            if (e instanceof SkippedPush) return { status: 0, reason: null, apnsId: null, skipped: true };
            const msg = e instanceof CeilingError ? "timed out" : e instanceof Error ? e.message : String(e);
            const clean = msg.split(token).join(shortToken(token)).split(jwt).join("<jwt>").slice(0, 160);
            const reason = `transport: ${clean}`;
            this.line("0", reason, push, run, token, null);
            return { status: 0, reason, apnsId: null };
        }
        this.line(String(answer.status), answer.reason, push, run, token, answer.apnsId);
        return answer;
    }

    // The whole policy of the answer table (8.4). `env` is where the token is
    // believed to belong; the Delivery says where it was actually accepted.
    async deliver(token: string, env: Environment, push: ApnsPush, run: string): Promise<Delivery> {
        const wake = push.event !== "update";
        let jwt: string;
        try {
            jwt = await this.token();
        } catch (e) {
            const reason = `jwt: ${e instanceof Error ? e.message : String(e)}`.slice(0, 160);
            this.line("0", reason, push, run, token, null);
            return { kind: "unhealthy", env, status: 0, reason, maybeDelivered: false };
        }

        // The transport is made ready (the helper's container woken) BEFORE and OUTSIDE
        // the per-attempt ceiling, under its own budget. Nothing has been sent yet when
        // this fails, so the caller may safely try again later.
        const notReady = await this.prepare(push, env, run, token, wake);
        if (notReady) return notReady;

        let at = env;
        let a = await this.attempt(token, at, push, jwt, run, wake);
        let retriedHost = false;
        let resigned = false;

        for (;;) {
            if (a.skipped) return { kind: "quiet", env: at, status: 0, reason: null };
            if (a.status === 200) return { kind: "sent", env: at, status: 200, apnsId: a.apnsId };

            if (a.status === 403 && a.reason === "ExpiredProviderToken" && !resigned) {
                resigned = true;
                let fresh: string | null = null;
                try {
                    fresh = await this.refreshAfterExpired(jwt);
                } catch {
                    fresh = null;
                }
                if (fresh) {
                    jwt = fresh;
                    a = await this.attempt(token, at, push, jwt, run, wake);
                    continue;
                }
            }
            if (a.status === 400 && a.reason === "BadDeviceToken" && !retriedHost) {
                retriedHost = true;
                at = at === "sandbox" ? "production" : "sandbox";
                a = await this.attempt(token, at, push, jwt, run, wake);
                continue;
            }
            break;
        }

        if (
            a.status === 410 ||
            (a.status === 400 && (a.reason === "ExpiredToken" || a.reason === "BadDeviceToken" || a.reason === "DeviceTokenNotForTopic"))
        ) {
            return { kind: "drop", env: at, status: a.status, reason: a.reason };
        }
        if (a.status === 429) {
            // Not a throttle of the push: Apple refused the PROVIDER TOKEN as renewed too
            // often (a re-sign inside its 20-minute floor). That used to be "quiet" and so
            // a silently lost push; it is a failure now (the reason is in the log line),
            // and the key counts as unhealthy for the guard window.
            if (a.reason === "TooManyProviderTokenUpdates") {
                return { kind: "unhealthy", env: at, status: 429, reason: a.reason, maybeDelivered: false };
            }
            return { kind: "quiet", env: at, status: 429, reason: a.reason };
        }
        return {
            kind: "unhealthy",
            env: at,
            status: a.status,
            reason: a.reason ?? (a.status === 0 ? "transport" : `http ${a.status}`),
            // status 0 after the transport ran: sent, no answer seen
            maybeDelivered: a.status === 0,
        };
    }

    // transport.prepare under APNS_WAKE_MS. null: ready (or nothing to prepare).
    private async prepare(push: ApnsPush, env: Environment, run: string, token: string, wake: boolean): Promise<Delivery | null> {
        const prep = this.d.transport.prepare;
        if (!prep) return null;
        try {
            await raceCeiling(
                Promise.resolve().then(() => prep({ event: push.event, wake })),
                this.d.wakeMs ?? APNS_WAKE_MS,
                "apns wake",
            );
            return null;
        } catch (e) {
            if (e instanceof SkippedPush) return { kind: "quiet", env, status: 0, reason: null };
            const msg = e instanceof CeilingError ? "timed out" : e instanceof Error ? e.message : String(e);
            const reason = `wake: ${msg}`.slice(0, 160);
            this.line("0", reason, push, run, token, null);
            return { kind: "unhealthy", env, status: 0, reason, maybeDelivered: false };
        }
    }

    // The live check of the transport (8.6): one update to the SANDBOX host for the
    // device token of 64 zeros. BadDeviceToken is the good answer (HTTP/2, the JWT
    // and the topic all work). No retry on the other host, no re-sign.
    async selftest(payload: unknown, expiration: number): Promise<{
        transport: "worker" | "helper";
        host: string;
        jwt: "ok" | "error";
        apns_status: number | null;
        apns_reason: string | null;
    }> {
        const host = APNS_HOSTS.sandbox;
        const base = { transport: this.d.via, host };
        let jwt: string;
        try {
            jwt = await this.token();
        } catch (e) {
            return { ...base, jwt: "error", apns_status: null, apns_reason: `jwt: ${e instanceof Error ? e.message : String(e)}`.slice(0, 160) };
        }
        const zeros = "0".repeat(64);
        const push: ApnsPush = { event: "update", priority: 10, expiration, payload };
        const notReady = await this.prepare(push, "sandbox", "selftest", zeros, true);
        if (notReady?.kind === "unhealthy") return { ...base, jwt: "ok", apns_status: null, apns_reason: notReady.reason };
        const a = await this.attempt(zeros, "sandbox", push, jwt, "selftest", true);
        if (a.status === 0) {
            return { ...base, jwt: "ok", apns_status: null, apns_reason: a.reason ?? "transport: unknown" };
        }
        return { ...base, jwt: "ok", apns_status: a.status, apns_reason: a.reason };
    }
}
