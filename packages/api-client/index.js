const JSON_HEADERS = {
    Accept: "application/json",
    "Content-Type": "application/json",
};

export const cobaltFileMetadataKeys = [
    "album",
    "composer",
    "genre",
    "copyright",
    "title",
    "artist",
    "album_artist",
    "track",
    "date",
    "sublanguage",
];

export function normalizeApiBase(url) {
    return new URL(url).origin;
}

export function createCobaltError(code, context) {
    return {
        status: "error",
        error: context ? { code, context } : { code },
    };
}

export function isCobaltError(value) {
    return value?.status === "error" && typeof value?.error?.code === "string";
}

export function withAbsoluteSessionExpiry(session, nowSeconds = Math.floor(Date.now() / 1000)) {
    return {
        ...session,
        exp: nowSeconds + session.exp,
    };
}

export function createAuthorizationHeader({ apiKey, bearerToken } = {}) {
    if (apiKey) {
        return `Api-Key ${apiKey}`;
    }

    if (bearerToken) {
        return `Bearer ${bearerToken}`;
    }

    return undefined;
}

async function parseJsonResponse(response) {
    return response.json().catch(() => undefined);
}

async function timedJsonRequest(url, init, timeoutMs, timeoutCode) {
    try {
        const response = await fetch(url, {
            ...init,
            redirect: "manual",
            signal: AbortSignal.timeout(timeoutMs),
        });

        const parsed = await parseJsonResponse(response);
        return parsed;
    } catch (error) {
        if (error?.message?.includes("timed out")) {
            return createCobaltError(timeoutCode);
        }

        return undefined;
    }
}

export async function getCobaltServerInfo(apiBase) {
    return timedJsonRequest(`${normalizeApiBase(apiBase)}/`, undefined, 10000, "error.api.timed_out");
}

export async function createCobaltSession(apiBase, turnstileToken) {
    const headers = turnstileToken
        ? { "cf-turnstile-response": turnstileToken }
        : undefined;

    return timedJsonRequest(
        `${normalizeApiBase(apiBase)}/session`,
        {
            method: "POST",
            headers,
        },
        10000,
        "error.api.timed_out",
    );
}

export async function requestCobalt(apiBase, requestBody, authorization) {
    const extraHeaders = authorization
        ? { Authorization: authorization }
        : undefined;

    return timedJsonRequest(
        normalizeApiBase(apiBase),
        {
            method: "POST",
            body: JSON.stringify(requestBody),
            headers: {
                ...JSON_HEADERS,
                ...extraHeaders,
            },
        },
        20000,
        "error.api.timed_out",
    );
}

export async function probeCobaltTunnel(url) {
    try {
        const response = await fetch(`${url}&p=1`);
        return response.status === 200 ? response.status : 0;
    } catch {
        return 0;
    }
}
