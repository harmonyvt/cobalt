import {
    createCobaltError,
    probeCobaltTunnel,
    requestCobalt,
} from "@imput/cobalt-client";
import { get } from "svelte/store";

import settings from "$lib/state/settings";

import { getSession, resetSession } from "$lib/api/session";
import { currentApiURL } from "$lib/api/api-url";
import { turnstileEnabled, turnstileSolved } from "$lib/state/turnstile";
import cachedInfo from "$lib/state/server-info";
import { getServerInfo } from "$lib/api/server-info";

import type { CobaltAPIResponse, CobaltErrorResponse, CobaltSaveRequestBody } from "$lib/types/api";

const waitForTurnstile = async () => {
    return await new Promise((resolve, reject) => {
        const unsub = turnstileSolved.subscribe((solved) => {
            if (solved) {
                unsub();
                resolve(true);
            }
        });

        // wait for turnstile to finish for 15 seconds
        setTimeout(() => {
            unsub();
            reject(false);
        }, 15 * 1000)
    });
}

const getAuthorization = async () => {
    const processing = get(settings).processing;
    if (processing.enableCustomApiKey && processing.customApiKey.length > 0) {
        return `Api-Key ${processing.customApiKey}`;
    }

    if (!get(turnstileEnabled)) {
        return;
    }

    if (!get(turnstileSolved)) {
        try {
            await waitForTurnstile();
        } catch {
            return createCobaltError("error.captcha_too_long") as CobaltErrorResponse;
        }
    }

    const session = await getSession();

    if (session) {
        if ("error" in session) {
            if (session.error.code !== "error.api.auth.not_configured") {
                return session;
            }
        } else {
            return `Bearer ${session.token}`;
        }
    }
}

const request = async (requestBody: CobaltSaveRequestBody, justRetried = false) => {
    await getServerInfo();

    const getCachedInfo = get(cachedInfo);

    if (!getCachedInfo) {
        return createCobaltError("error.api.unreachable") as CobaltErrorResponse;
    }

    const api = currentApiURL();
    const authorization = await getAuthorization();

    if (authorization && typeof authorization !== "string") {
        return authorization;
    }

    let authorizationHeader: string | undefined;

    if (authorization) {
        authorizationHeader = authorization;
    }

    const response = await requestCobalt(
        api,
        requestBody,
        authorizationHeader
    ) as CobaltAPIResponse | undefined;

    if (
        response?.status === 'error'
            && response?.error.code === 'error.api.auth.jwt.invalid'
            && !justRetried
    ) {
        resetSession();
        await getAuthorization();
        return request(requestBody, true);
    }

    return response;
}

export default {
    request,
    probeCobaltTunnel,
}
