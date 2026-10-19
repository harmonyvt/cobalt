// Stage (APP-API-CONTRACT.md section 29.8, 29.9): the Twitch side. OAuth for the broadcaster, the
// Helix calls for channel point rewards and their redemptions, the EventSub webhook subscription, the
// webhook's HMAC check, and the encryption of the stored tokens. `fetch` and `now` are injected so the
// tests run with fakes and no network. Free of Cloudflare imports (WebCrypto and fetch only).

export const TWITCH_OAUTH = "https://id.twitch.tv/oauth2";
export const TWITCH_HELIX = "https://api.twitch.tv/helix";
export const REWARD_SCOPE = "channel:manage:redemptions";
export const REDEMPTION_EVENT = "channel.channel_points_custom_reward_redemption.add";

export type TwitchConfig = { clientId: string; clientSecret: string; eventsubSecret: string };
export type TwitchFetch = (input: string, init?: RequestInit) => Promise<Response>;

// The three secrets, or null while any is missing or empty (`features.stage_twitch` is false then).
export function twitchConfigFrom(env: {
    TWITCH_CLIENT_ID?: string;
    TWITCH_CLIENT_SECRET?: string;
    TWITCH_EVENTSUB_SECRET?: string;
}): TwitchConfig | null {
    const clientId = (env.TWITCH_CLIENT_ID ?? "").trim();
    const clientSecret = (env.TWITCH_CLIENT_SECRET ?? "").trim();
    const eventsubSecret = (env.TWITCH_EVENTSUB_SECRET ?? "").trim();
    return clientId && clientSecret && eventsubSecret ? { clientId, clientSecret, eventsubSecret } : null;
}

// What Twitch said when it refused: `status` is the HTTP status (0 = the request never got an answer).
export class TwitchError extends Error {
    constructor(
        readonly status: number,
        readonly detail: string,
    ) {
        super(`twitch ${status}${detail ? ` ${detail}` : ""}`);
        this.name = "TwitchError";
    }
}

export type TokenSet = { access_token: string; refresh_token: string; expires_in: number; scope: string[] };
export type TwitchUser = { id: string; login: string; display_name: string };
export type ValidatedToken = { client_id: string; login: string; user_id: string; scopes: string[]; expires_in: number };

export type RewardBody = {
    title?: string;
    cost?: number;
    prompt?: string;
    is_enabled?: boolean;
    is_user_input_required?: boolean;
    is_global_cooldown_enabled?: boolean;
    global_cooldown_seconds?: number;
    should_redemptions_skip_request_queue?: boolean;
};

export type TwitchClient = {
    authorizeUrl(redirectUri: string, state: string): string;
    exchangeCode(code: string, redirectUri: string): Promise<TokenSet>;
    refresh(refreshToken: string): Promise<TokenSet>;
    appToken(): Promise<string>;
    validate(userToken: string): Promise<ValidatedToken>;
    revoke(userToken: string): Promise<void>;
    user(userToken: string): Promise<TwitchUser>;
    // the rewards this app made (only_manageable_rewards): ours to adopt after a reconnect
    listManageableRewards(userToken: string, broadcasterId: string): Promise<{ id: string; title: string }[]>;
    createReward(userToken: string, broadcasterId: string, body: RewardBody): Promise<{ id: string; title: string }>;
    updateReward(userToken: string, broadcasterId: string, rewardId: string, body: RewardBody): Promise<void>;
    deleteReward(userToken: string, broadcasterId: string, rewardId: string): Promise<void>;
    setRedemption(userToken: string, broadcasterId: string, rewardId: string, redemptionId: string, status: "FULFILLED" | "CANCELED"): Promise<void>;
    createSubscription(appToken: string, broadcasterId: string, callback: string): Promise<string>;
    deleteSubscription(appToken: string, id: string): Promise<void>;
};

const form = (o: Record<string, string>) => new URLSearchParams(o).toString();

async function failure(res: Response): Promise<TwitchError> {
    let detail = "";
    try {
        const t = await res.text();
        try {
            const j = JSON.parse(t) as { message?: unknown; error?: unknown };
            detail = String(j.message ?? j.error ?? "").slice(0, 200);
        } catch {
            detail = t.slice(0, 200);
        }
    } catch {
        /* no body */
    }
    return new TwitchError(res.status, detail);
}

export const TWITCH_CALL_MS = 10_000;

// The app access token (client credentials) is good for weeks, so it is kept across calls and requests for
// as long as this isolate lives, per client id. A 401 on it drops it.
const appTokens = new Map<string, { token: string; exp: number }>();
export const clearAppTokens = (): void => appTokens.clear();

export function twitchClient(
    cfg: TwitchConfig,
    fetchFn: TwitchFetch,
    now: () => number = () => Date.now(),
    timeoutMs: number = TWITCH_CALL_MS,
): TwitchClient {
    // Never lets a network error escape untyped: the caller sees status 0. Every call is raced against a
    // timeout of our own (a hung Twitch call must not eat the Worker's waitUntil budget).
    const send = async (url: string, init: RequestInit): Promise<Response> => {
        const ctrl = new AbortController();
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<never>((_, reject) => {
            timer = setTimeout(() => {
                // reject first: aborting makes the fetch fail at once, and that must not be what the caller sees
                reject(new TwitchError(0, "timeout"));
                ctrl.abort();
            }, timeoutMs);
        });
        try {
            return await Promise.race([fetchFn(url, { ...init, signal: ctrl.signal }), timeout]);
        } catch (e) {
            if (e instanceof TwitchError) throw e;
            throw new TwitchError(0, e instanceof Error ? e.name : "network");
        } finally {
            clearTimeout(timer);
        }
    };
    const tokenCall = async (body: Record<string, string>): Promise<TokenSet> => {
        const res = await send(`${TWITCH_OAUTH}/token`, {
            method: "POST",
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: form({ client_id: cfg.clientId, client_secret: cfg.clientSecret, ...body }),
        });
        if (!res.ok) throw await failure(res);
        const j = (await res.json().catch(() => null)) as Partial<TokenSet> | null;
        if (!j || typeof j.access_token !== "string") throw new TwitchError(res.status, "no token");
        return {
            access_token: j.access_token,
            refresh_token: typeof j.refresh_token === "string" ? j.refresh_token : "",
            expires_in: typeof j.expires_in === "number" ? j.expires_in : 0,
            scope: Array.isArray(j.scope) ? j.scope.filter((s): s is string => typeof s === "string") : [],
        };
    };
    const helix = async (token: string, method: string, path: string, body?: unknown): Promise<Response> => {
        const res = await send(`${TWITCH_HELIX}${path}`, {
            method,
            headers: {
                "client-id": cfg.clientId,
                authorization: `Bearer ${token}`,
                ...(body === undefined ? {} : { "content-type": "application/json" }),
            },
            body: body === undefined ? undefined : JSON.stringify(body),
        });
        if (!res.ok) {
            const cached = appTokens.get(cfg.clientId);
            if (res.status === 401 && cached && cached.token === token) appTokens.delete(cfg.clientId);
            throw await failure(res);
        }
        return res;
    };
    return {
        authorizeUrl(redirectUri, state) {
            const q = new URLSearchParams({
                response_type: "code",
                client_id: cfg.clientId,
                redirect_uri: redirectUri,
                scope: REWARD_SCOPE,
                state,
                force_verify: "true",
            });
            return `${TWITCH_OAUTH}/authorize?${q.toString()}`;
        },
        exchangeCode: (code, redirectUri) => tokenCall({ code, grant_type: "authorization_code", redirect_uri: redirectUri }),
        refresh: (refreshToken) => tokenCall({ grant_type: "refresh_token", refresh_token: refreshToken }),
        async appToken() {
            const cached = appTokens.get(cfg.clientId);
            if (cached && cached.exp - 60_000 > now()) return cached.token;
            const t = await tokenCall({ grant_type: "client_credentials" });
            appTokens.set(cfg.clientId, { token: t.access_token, exp: now() + t.expires_in * 1000 });
            return t.access_token;
        },
        async validate(userToken) {
            const res = await send(`${TWITCH_OAUTH}/validate`, { headers: { authorization: `OAuth ${userToken}` } });
            if (!res.ok) throw await failure(res);
            const j = (await res.json().catch(() => null)) as Partial<ValidatedToken> | null;
            if (!j || typeof j.client_id !== "string" || typeof j.user_id !== "string" || typeof j.login !== "string") {
                throw new TwitchError(res.status, "bad validate answer");
            }
            return {
                client_id: j.client_id,
                login: j.login,
                user_id: j.user_id,
                scopes: Array.isArray(j.scopes) ? j.scopes.filter((s): s is string => typeof s === "string") : [],
                expires_in: typeof j.expires_in === "number" ? j.expires_in : 0,
            };
        },
        async revoke(userToken) {
            await send(`${TWITCH_OAUTH}/revoke`, {
                method: "POST",
                headers: { "content-type": "application/x-www-form-urlencoded" },
                body: form({ client_id: cfg.clientId, token: userToken }),
            }).catch(() => undefined);
        },
        async user(userToken) {
            const res = await helix(userToken, "GET", "/users");
            const j = (await res.json().catch(() => null)) as { data?: { id?: unknown; login?: unknown; display_name?: unknown }[] } | null;
            const u = j?.data?.[0];
            if (!u || typeof u.id !== "string" || typeof u.login !== "string") throw new TwitchError(res.status, "no user");
            return { id: u.id, login: u.login, display_name: typeof u.display_name === "string" && u.display_name ? u.display_name : u.login };
        },
        async listManageableRewards(userToken, broadcasterId) {
            const res = await helix(userToken, "GET", `/channel_points/custom_rewards?broadcaster_id=${encodeURIComponent(broadcasterId)}&only_manageable_rewards=true`);
            const j = (await res.json().catch(() => null)) as { data?: { id?: unknown; title?: unknown }[] } | null;
            return (j?.data ?? []).flatMap((r) => (typeof r.id === "string" && typeof r.title === "string" ? [{ id: r.id, title: r.title }] : []));
        },
        async createReward(userToken, broadcasterId, body) {
            const res = await helix(userToken, "POST", `/channel_points/custom_rewards?broadcaster_id=${encodeURIComponent(broadcasterId)}`, body);
            const j = (await res.json().catch(() => null)) as { data?: { id?: unknown; title?: unknown }[] } | null;
            const r = j?.data?.[0];
            if (!r || typeof r.id !== "string") throw new TwitchError(res.status, "no reward");
            return { id: r.id, title: typeof r.title === "string" ? r.title : (body.title ?? "") };
        },
        async updateReward(userToken, broadcasterId, rewardId, body) {
            await helix(
                userToken,
                "PATCH",
                `/channel_points/custom_rewards?broadcaster_id=${encodeURIComponent(broadcasterId)}&id=${encodeURIComponent(rewardId)}`,
                body,
            );
        },
        async deleteReward(userToken, broadcasterId, rewardId) {
            await helix(
                userToken,
                "DELETE",
                `/channel_points/custom_rewards?broadcaster_id=${encodeURIComponent(broadcasterId)}&id=${encodeURIComponent(rewardId)}`,
            );
        },
        async setRedemption(userToken, broadcasterId, rewardId, redemptionId, status) {
            await helix(
                userToken,
                "PATCH",
                `/channel_points/custom_rewards/redemptions?broadcaster_id=${encodeURIComponent(broadcasterId)}&reward_id=${encodeURIComponent(rewardId)}&id=${encodeURIComponent(redemptionId)}`,
                { status },
            );
        },
        async createSubscription(appToken, broadcasterId, callback) {
            const body = {
                type: REDEMPTION_EVENT,
                version: "1",
                condition: { broadcaster_user_id: broadcasterId },
                transport: { method: "webhook", callback, secret: cfg.eventsubSecret },
            };
            try {
                const res = await helix(appToken, "POST", "/eventsub/subscriptions", body);
                const j = (await res.json().catch(() => null)) as { data?: { id?: unknown }[] } | null;
                const id = j?.data?.[0]?.id;
                if (typeof id !== "string") throw new TwitchError(res.status, "no subscription");
                return id;
            } catch (e) {
                // 409: the same subscription already exists (a reconnect): adopt it instead of failing
                if (!(e instanceof TwitchError) || e.status !== 409) throw e;
                const res = await helix(appToken, "GET", `/eventsub/subscriptions?type=${REDEMPTION_EVENT}`);
                const j = (await res.json().catch(() => null)) as {
                    data?: { id?: unknown; condition?: { broadcaster_user_id?: unknown }; transport?: { callback?: unknown } }[];
                } | null;
                const found = j?.data?.find((s) => s.condition?.broadcaster_user_id === broadcasterId && s.transport?.callback === callback);
                if (typeof found?.id !== "string") throw e;
                return found.id;
            }
        },
        async deleteSubscription(appToken, id) {
            await helix(appToken, "DELETE", `/eventsub/subscriptions?id=${encodeURIComponent(id)}`);
        },
    };
}

// ---- EventSub webhook signature (29.9) ------------------------------------------------------------

const enc = new TextEncoder();

const hexToBytes = (hex: string): Uint8Array | null => {
    if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
    const out = new Uint8Array(32);
    for (let i = 0; i < 32; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return out;
};

export const bytesToHex = (b: Uint8Array): string => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

// `sha256=` + hex HMAC-SHA-256(secret, message id + timestamp + raw body). The comparison is
// crypto.subtle.verify, which is constant time.
export async function verifyEventSub(
    secret: string,
    messageId: string | null,
    timestamp: string | null,
    rawBody: string,
    signature: string | null,
): Promise<boolean> {
    if (!messageId || !timestamp || !signature || !signature.startsWith("sha256=")) return false;
    const sig = hexToBytes(signature.slice("sha256=".length));
    if (!sig) return false;
    const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    return crypto.subtle.verify("HMAC", key, sig, enc.encode(messageId + timestamp + rawBody));
}

// Signs like Twitch does (the tests, and nothing else, call it).
export async function signEventSub(secret: string, messageId: string, timestamp: string, rawBody: string): Promise<string> {
    const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return `sha256=${bytesToHex(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(messageId + timestamp + rawBody))))}`;
}

// ---- stored tokens (29.2): AES-GCM, key = HKDF-SHA-256 of the client secret ----------------------------

const b64 = (b: Uint8Array): string => {
    let s = "";
    for (const x of b) s += String.fromCharCode(x);
    return btoa(s);
};
const unb64 = (s: string): Uint8Array => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function tokenKey(clientSecret: string): Promise<CryptoKey> {
    const base = await crypto.subtle.importKey("raw", enc.encode(clientSecret), "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: enc.encode("stage-twitch-tokens") },
        base,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt", "decrypt"],
    );
}

// base64(iv).base64(ciphertext). `iv` is injectable for the tests only.
export async function encryptToken(clientSecret: string, plain: string, iv: Uint8Array = crypto.getRandomValues(new Uint8Array(12))): Promise<string> {
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await tokenKey(clientSecret), enc.encode(plain)));
    return `${b64(iv)}.${b64(ct)}`;
}

// Throws on a wrong key (the client secret was rotated), a damaged value or a malformed one.
export async function decryptToken(clientSecret: string, stored: string): Promise<string> {
    const [iv, ct] = stored.split(".");
    if (!iv || !ct) throw new Error("bad token format");
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await tokenKey(clientSecret), unb64(ct));
    return new TextDecoder().decode(plain);
}
