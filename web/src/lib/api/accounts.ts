// fork-only: device sessions (APP-API-CONTRACT.md section 42). the site sits
// behind cloudflare access, so the browser mints its own session through the
// same-origin web worker (POST /api/auth/web) and keeps the token where the
// pasted custom api key lives. a 401 `error.api.auth.key.invalid` flips the
// app to "signed out"; a pinned bar offers to sign in again.

import { get, writable } from "svelte/store";

import settings, { updateSetting } from "$lib/state/settings";
import { currentApiURL } from "$lib/api/api-url";

const SIGNED_OUT_FLAG = "cobalt-signed-out";

export type Session = {
    id: string;
    device: string;
    platform: "ios" | "ipados" | "mac" | "web" | string;
    created_at: number;
    last_used_at: number;
    expires_at: number;
    country: string | null;
    current: boolean;
};

export type Me = {
    caller: {
        kind: "key" | "session";
        id: string;
        device?: string;
        platform?: string;
        email?: string;
        expires_at?: number;
    };
    sessions: number;
    keys: number;
};

const readFlag = () => {
    try {
        return localStorage.getItem(SIGNED_OUT_FLAG) === "1";
    } catch {
        return false;
    }
};

const writeFlag = (on: boolean) => {
    try {
        if (on) localStorage.setItem(SIGNED_OUT_FLAG, "1");
        else localStorage.removeItem(SIGNED_OUT_FLAG);
    } catch {
        // storage blocked: the bar still shows for this page load
    }
};

// true while the app should show the "signed out" bar
export const signedOut = writable(false);

const currentKey = () => {
    const p = get(settings).processing;
    return p.enableCustomApiKey && p.customApiKey.length > 0
        ? p.customApiKey
        : "";
};

const usesCustomInstance = () => {
    const p = get(settings).processing;
    return p.enableCustomInstances && p.customInstanceURL.length > 0;
};

const storeKey = (key: string) =>
    updateSetting({
        processing: { enableCustomApiKey: true, customApiKey: key },
    });

const clearKey = () =>
    updateSetting({
        processing: { enableCustomApiKey: false, customApiKey: "" },
    });

type WebSignIn = "ok" | "expired" | "unavailable";

// POST /api/auth/web. "expired": access redirected us (cookie ran out);
// "unavailable": not the deployed site, or a non-json answer
const mint = async (replace?: string): Promise<WebSignIn> => {
    let res: Response;

    try {
        res = await fetch("/api/auth/web", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                accept: "application/json",
            },
            body: JSON.stringify(replace ? { replace } : {}),
            redirect: "manual",
            cache: "no-store",
            credentials: "same-origin",
        });
    } catch {
        return "expired";
    }

    if (res.type === "opaqueredirect" || res.status === 0 || res.status === 401) {
        return "expired";
    }

    if (res.status !== 200) return "unavailable";

    try {
        const body = await res.json();
        if (typeof body?.key !== "string" || body.key.length === 0) {
            return "unavailable";
        }
        storeKey(body.key);
        writeFlag(false);
        signedOut.set(false);
        return "ok";
    } catch {
        return "unavailable";
    }
};

let pending: Promise<void> | null = null;
let attempted = false;

// no custom key yet: mint one. once per page load, and concurrent callers
// share one request. never throws; failure just leaves the app as it was.
export const ensureSignedIn = (): Promise<void> => {
    if (typeof window === "undefined") return Promise.resolve();

    if (readFlag()) {
        signedOut.set(true);
        return Promise.resolve();
    }

    if (currentKey() || usesCustomInstance() || attempted) {
        return pending ?? Promise.resolve();
    }

    attempted = true;
    pending = mint()
        .then(() => {})
        .finally(() => {
            pending = null;
        });

    return pending;
};

// the signed-out bar's button
export const signInAgain = async (): Promise<boolean> => {
    const old = currentKey();
    const result = await mint(old || undefined);

    if (result === "ok") return true;

    // access session gone (or something odd): go through access's login
    location.reload();
    return false;
};

export const markSignedOut = () => signedOut.set(true);

export const KEY_INVALID = "error.api.auth.key.invalid";

let recovering: Promise<boolean> | null = null;

// a 401 key.invalid. access's cookie is usually still good, so first try a
// silent mint(replace). true: new key stored, the caller retries once.
// false: the bar is showing (access expired, a mint failed, the person signed
// out on purpose, or this isn't the deployed site's own api). one mint in
// flight at a time; callers share it.
export const recoverFromInvalidKey = (): Promise<boolean> => {
    if (typeof window === "undefined") return Promise.resolve(false);

    if (usesCustomInstance()) return Promise.resolve(false);

    if (readFlag()) {
        markSignedOut();
        return Promise.resolve(false);
    }

    recovering ??= mint(currentKey() || undefined)
        .then((r) => r === "ok")
        .finally(() => {
            recovering = null;
        });

    return recovering.then((ok) => {
        if (!ok) markSignedOut();
        return ok;
    });
};

// errors from calls that don't retry themselves: just flip the bar
export const noteApiError = (code: unknown) => {
    if (code === KEY_INVALID) markSignedOut();
};

export type AccountResult<T> =
    | { ok: true; data: T }
    | { ok: false; reason: "signed_out" | "unavailable" | "api"; code?: string };

const call = async <T>(
    path: string,
    method = "GET",
    retried = false
): Promise<AccountResult<T>> => {
    const key = currentKey();
    if (!key) return { ok: false, reason: "signed_out" };

    let res: Response;
    try {
        res = await fetch(`${currentApiURL()}${path}`, {
            method,
            headers: { accept: "application/json", authorization: `Api-Key ${key}` },
            cache: "no-store",
            redirect: "manual",
        });
    } catch {
        return { ok: false, reason: "unavailable" };
    }

    let body: any = null;
    try {
        body = await res.json();
    } catch {
        // not json
    }

    if (res.ok && body) return { ok: true, data: body as T };

    const code: string | undefined = body?.error?.code ?? body?.error;

    if (code === KEY_INVALID && !retried && path !== "/auth/signout") {
        if (await recoverFromInvalidKey()) return call<T>(path, method, true);
    } else {
        noteApiError(code);
    }

    if (res.status === 401) return { ok: false, reason: "signed_out", code };
    if (res.status === 404 && !code) return { ok: false, reason: "unavailable" };
    return { ok: false, reason: "api", code };
};

// `features.accounts` from GET /capabilities
export const accountsAvailable = async (): Promise<boolean> => {
    const res = await call<{ features?: { accounts?: boolean } }>("/capabilities");
    return res.ok && res.data?.features?.accounts === true;
};

export const getMe = () => call<Me>("/auth/me");
export const listSessions = () =>
    call<{ sessions: Session[] }>("/auth/sessions");
export const revokeSession = (id: string) =>
    call<{ status: string }>(`/auth/sessions/${encodeURIComponent(id)}`, "DELETE");
export const signOutOthers = () =>
    call<{ count: number }>("/auth/signout-others", "POST");

// revoke this session on the server, forget the token, show the bar
export const signOut = async () => {
    await call<{ signed_out: boolean }>("/auth/signout", "POST");
    clearKey();
    writeFlag(true);
    signedOut.set(true);
};
