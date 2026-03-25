import { createCobaltError, createCobaltSession, withAbsoluteSessionExpiry } from "@imput/cobalt-client";
import turnstile from "$lib/api/turnstile";
import { currentApiURL } from "$lib/api/api-url";

import type { CobaltSession, CobaltErrorResponse, CobaltSessionResponse } from "$lib/types/api";

let cache: CobaltSession | undefined;

export const requestSession = async () => {
    const turnstileResponse = turnstile.getResponse();

    const response = await createCobaltSession(
        currentApiURL(),
        turnstileResponse ?? undefined
    ) as CobaltSessionResponse | undefined;

    turnstile.reset();

    return response;
}

export const getSession = async () => {
    const currentTime = () => Math.floor(new Date().getTime() / 1000);

    if (cache?.token && cache?.exp - 2 > currentTime()) {
        return cache;
    }

    const newSession = await requestSession();

    if (!newSession) return createCobaltError("error.api.unreachable") as CobaltErrorResponse

    if (!("status" in newSession)) {
        cache = withAbsoluteSessionExpiry(newSession, currentTime());
    }
    return newSession;
}

export const resetSession = () => cache = undefined;
