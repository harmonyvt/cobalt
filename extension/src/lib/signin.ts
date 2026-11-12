// Device sign-in. Chrome finishes on a chromiumapp.org redirect (launchWebAuthFlow). Safari, and a Chrome
// flow that throws, polls POST /auth/extension/poll after the owner approves /connect/extension.
// The verifier never leaves this module except as a PKCE challenge. The token comes back once.

import { API_ORIGIN, WEB_ORIGIN, isSessionKey, type FetchLike } from "./save";

const CODE = /^[A-Za-z0-9_-]{43}$/;

export type SignedIn = { ok: true; key: string; id: string; device: string };
export type SignInResult = SignedIn | { ok: false; message: string };

export function prefersWebAuthFlow(ua: string, hasLaunch: boolean): boolean {
    if (!hasLaunch) return false;
    const safari = /Safari\//.test(ua) && !/Chrome\/|Chromium\/|Edg\//.test(ua);
    return !safari;
}

export function randomUrlSafe(bytes = 32): string {
    const buf = new Uint8Array(bytes);
    crypto.getRandomValues(buf);
    let s = "";
    for (const b of buf) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function pkceChallenge(verifier: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    let s = "";
    for (const b of new Uint8Array(digest)) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function chromeApproveUrl(opts: { challenge: string; state: string; redirectUri: string }): string {
    const u = new URL(`${WEB_ORIGIN}/connect/extension`);
    u.searchParams.set("challenge", opts.challenge);
    u.searchParams.set("state", opts.state);
    u.searchParams.set("redirect_uri", opts.redirectUri);
    return u.toString();
}

export function safariApproveUrl(userCode: string): string {
    const u = new URL(`${WEB_ORIGIN}/connect/extension`);
    u.searchParams.set("user_code", userCode);
    return u.toString();
}

export function parseRedirect(finalUrl: string, expectedState: string): { ok: true; code: string } | { ok: false; message: string } {
    let u: URL;
    try {
        u = new URL(finalUrl);
    } catch {
        return { ok: false, message: "Sign-in did not finish." };
    }
    if (u.searchParams.get("error")) return { ok: false, message: "Sign-in was cancelled." };
    if (u.searchParams.get("state") !== expectedState) return { ok: false, message: "Sign-in was interrupted. Try again." };
    const code = u.searchParams.get("code");
    if (!code || !CODE.test(code)) return { ok: false, message: "Sign-in did not finish." };
    return { ok: true, code };
}

export async function runSignIn(opts: {
    fetch: FetchLike;
    ua: string;
    redirectUri: string | null;
    launch: ((url: string) => Promise<string>) | null;
    openTab: (url: string) => Promise<void>;
    sleep?: (ms: number) => Promise<void>;
    now?: () => number;
}): Promise<SignInResult> {
    const verifier = randomUrlSafe(32);
    const state = randomUrlSafe(16);
    const challenge = await pkceChallenge(verifier);
    const sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    const now = opts.now ?? Date.now;
    if (prefersWebAuthFlow(opts.ua, opts.launch !== null) && opts.redirectUri && opts.launch) {
        try {
            const finalUrl = await opts.launch(chromeApproveUrl({ challenge, state, redirectUri: opts.redirectUri }));
            const parsed = parseRedirect(finalUrl, state);
            if (!parsed.ok) return parsed;
            return exchange(opts.fetch, parsed.code, verifier);
        } catch {
            // The window was closed, or this browser's launchWebAuthFlow does not work. Poll instead.
        }
    }
    const began = await postJson(opts.fetch, `${API_ORIGIN}/auth/extension/begin`, { challenge, state });
    if (began === "offline") return { ok: false, message: "Offline. Try again when Capystore is reachable." };
    if (!began.ok) return { ok: false, message: "Couldn't start sign-in." };
    const deviceCode = began.body.device_code;
    const userCode = began.body.user_code;
    const expires = typeof began.body.expires_at === "number" ? began.body.expires_at : now() + 5 * 60 * 1000;
    const interval = typeof began.body.interval === "number" ? began.body.interval : 2;
    if (typeof deviceCode !== "string" || typeof userCode !== "string") return { ok: false, message: "Couldn't start sign-in." };
    await opts.openTab(safariApproveUrl(userCode));
    while (now() < expires) {
        await sleep(Math.max(1, interval) * 1000);
        const polled = await postJson(opts.fetch, `${API_ORIGIN}/auth/extension/poll`, { device_code: deviceCode, verifier, state });
        if (polled === "offline") return { ok: false, message: "Offline. Try again when Capystore is reachable." };
        if (polled.status === 202) continue;
        if (!polled.ok) return { ok: false, message: "Sign-in expired. Try again." };
        return sessionFrom(polled.body);
    }
    return { ok: false, message: "Sign-in expired. Try again." };
}

async function exchange(fetchImpl: FetchLike, code: string, verifier: string): Promise<SignInResult> {
    const res = await postJson(fetchImpl, `${API_ORIGIN}/auth/exchange`, { code, verifier });
    if (res === "offline") return { ok: false, message: "Offline. Try again when Capystore is reachable." };
    if (!res.ok) return { ok: false, message: "Sign-in did not finish." };
    return sessionFrom(res.body);
}

function sessionFrom(body: Record<string, unknown>): SignInResult {
    const key = body.key;
    const session = body.session as { id?: unknown; device?: unknown } | undefined;
    if (!isSessionKey(key) || !session || typeof session.id !== "string") return { ok: false, message: "Sign-in did not finish." };
    return { ok: true, key, id: session.id, device: typeof session.device === "string" && session.device ? session.device : "Browser extension" };
}

type JsonResult = { ok: true; status: number; body: Record<string, unknown> } | { ok: false; status: number; body: Record<string, unknown> } | "offline";

async function postJson(fetchImpl: FetchLike, url: string, body: unknown): Promise<JsonResult> {
    try {
        const res = await fetchImpl(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
            credentials: "omit",
            cache: "no-store",
        });
        const parsed = await res.json().catch(() => null);
        const obj = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
        return { ok: res.status >= 200 && res.status < 300, status: res.status, body: obj };
    } catch {
        return "offline";
    }
}
