// tiny client for the same-origin /api/keys endpoints of the deployed site.
// the login session is a cloudflare access cookie, so requests never follow
// redirects: an expired session shows up as an opaque redirect (or a 401).

export type ApiKey = {
    id: string;
    name: string;
    prefix: string;
    created_at: number;
    last_used_at: number | null;
};

export type CreatedApiKey = ApiKey & { key: string };

export type KeysError =
    | { reason: "expired" }
    | { reason: "unavailable" }
    | { reason: "api"; code: string };

export type KeysResult<T> =
    | { ok: true; data: T }
    | ({ ok: false } & KeysError);

const call = async <T>(
    path: string,
    init: RequestInit,
    okStatuses: number[],
    notFoundMeansUnavailable = false
): Promise<KeysResult<T>> => {
    let res: Response;

    try {
        res = await fetch(path, {
            ...init,
            redirect: "manual",
            cache: "no-store",
            credentials: "same-origin",
        });
    } catch {
        return { ok: false, reason: "unavailable" };
    }

    if (
        res.type === "opaqueredirect" ||
        res.status === 0 ||
        res.status === 401
    ) {
        return { ok: false, reason: "expired" };
    }

    if (notFoundMeansUnavailable && res.status === 404) {
        return { ok: false, reason: "unavailable" };
    }

    if (okStatuses.includes(res.status)) {
        if (res.status === 204) {
            return { ok: true, data: undefined as T };
        }

        try {
            return { ok: true, data: (await res.json()) as T };
        } catch {
            // 2xx that isn't json: a static fallback page, no worker behind us
            return { ok: false, reason: "unavailable" };
        }
    }

    try {
        const body = await res.json();
        if (typeof body?.error === "string") {
            return { ok: false, reason: "api", code: body.error };
        }
    } catch {
        // fall through
    }

    return { ok: false, reason: "api", code: "server_error" };
};

export const listKeys = async (): Promise<KeysResult<ApiKey[]>> => {
    const res = await call<{ keys: ApiKey[] }>(
        "/api/keys",
        { method: "GET", headers: { accept: "application/json" } },
        [200],
        true
    );

    if (!res.ok) return res;
    if (!Array.isArray(res.data?.keys)) {
        return { ok: false, reason: "unavailable" };
    }

    return { ok: true, data: res.data.keys };
};

export const createKey = (name: string) =>
    call<CreatedApiKey>(
        "/api/keys",
        {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ name }),
        },
        [201]
    );

export const revokeKey = (id: string) =>
    call<void>(
        `/api/keys/${encodeURIComponent(id)}`,
        { method: "DELETE" },
        [204]
    );
