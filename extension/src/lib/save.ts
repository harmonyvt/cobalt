// POST /studio and GET /studio/<id>, from the background worker only. credentials: "omit" so a site
// cookie is never sent. origin "extension" is not listed in GET /studio/recent (section 65).

import { EMPTY_PROGRESS, friendlyError, progressOf, type SaveProgress } from "./progress";

export const API_ORIGIN = "https://api.capybaraharmony.com";
export const WEB_ORIGIN = "https://cobalt.capybaraharmony.com";
export const LIBRARY_URL = `${WEB_ORIGIN}/library`;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type SaveOutcome =
    | { kind: "saving"; id: string; studioUrl: string; progress: SaveProgress }
    | { kind: "saved"; id: string; studioUrl: string; progress: SaveProgress; shareUrl: string | null }
    | { kind: "error"; message: string; code: string | null }
    | { kind: "signed-out" }
    | { kind: "offline" };

export type { SaveProgress };

export function studioUrl(id: string): string {
    return `${WEB_ORIGIN}/studio/${id}`;
}

export async function createSave(fetchImpl: FetchLike, key: string, pageUrl: string, phone = true): Promise<SaveOutcome> {
    const res = await ask(fetchImpl, `${API_ORIGIN}/studio`, {
        method: "POST",
        headers: jsonHeaders(key),
        body: JSON.stringify({ url: pageUrl, origin: "extension", queue: true, phone }),
    });
    if (res === "offline") return { kind: "offline" };
    if (res.status === 401) return { kind: "signed-out" };
    const body = await readJson(res);
    if (res.status === 201 && body?.status === "success" && typeof body.id === "string") {
        const studio = typeof body.url === "string" ? body.url : studioUrl(body.id);
        const progress = progressOf(body);
        if (body.queued === true) progress.step = "queued";
        else progress.waking = true;
        if (typeof body.queue_ahead === "number") progress.queueAhead = body.queue_ahead;
        return { kind: "saving", id: body.id, studioUrl: studio, progress };
    }
    const code = codeOf(body);
    return { kind: "error", message: friendlyError(code), code };
}

export async function pollSave(fetchImpl: FetchLike, key: string, id: string, knownStudio: string, waitSeconds = 0): Promise<SaveOutcome> {
    const wait = Math.max(0, Math.min(25, waitSeconds));
    const res = await ask(fetchImpl, `${API_ORIGIN}/studio/${encodeURIComponent(id)}?wait=${wait}`, {
        method: "GET",
        headers: { authorization: `Api-Key ${key}` },
    });
    if (res === "offline") return { kind: "offline" };
    if (res.status === 401) return { kind: "signed-out" };
    const body = await readJson(res);
    const progress = progressOf(body);
    if (res.status === 200 && body?.status === "ready") {
        return { kind: "saved", id, studioUrl: knownStudio, progress, shareUrl: progress.publicUrl };
    }
    if (res.status === 200 && body?.status === "saving") return { kind: "saving", id, studioUrl: knownStudio, progress };
    const code = codeOf(body);
    return { kind: "error", message: friendlyError(code), code };
}

// Poll until the save finishes, the session is rejected, or the deadline passes.
// `now` and `sleep` are injected so a test does not wait on a wall clock.
export async function followSave(opts: {
    fetch: FetchLike;
    key: string;
    id: string;
    studioUrl: string;
    waitSeconds?: number;
    sleep?: (ms: number) => Promise<void>;
    now?: () => number;
    deadlineMs?: number;
    onProgress?: (outcome: SaveOutcome) => void;
}): Promise<SaveOutcome> {
    const sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    const now = opts.now ?? Date.now;
    const deadline = now() + (opts.deadlineMs ?? 15 * 60 * 1000);
    let last: SaveOutcome = { kind: "saving", id: opts.id, studioUrl: opts.studioUrl, progress: EMPTY_PROGRESS };
    while (now() < deadline) {
        const started = now();
        last = await pollSave(opts.fetch, opts.key, opts.id, opts.studioUrl, opts.waitSeconds ?? 0);
        opts.onProgress?.(last);
        if (last.kind !== "saving") return last;
        const elapsed = now() - started;
        await sleep(elapsed < 1000 ? 1500 : 250);
    }
    return { kind: "error", message: "Still saving. It will show up in the library.", code: null };
}

export function isSessionKey(key: unknown): key is string {
    return typeof key === "string" && UUID.test(key);
}

function jsonHeaders(key: string): Record<string, string> {
    return { authorization: `Api-Key ${key}`, "content-type": "application/json" };
}

async function ask(fetchImpl: FetchLike, url: string, init: RequestInit): Promise<Response | "offline"> {
    try {
        return await fetchImpl(url, { ...init, credentials: "omit", cache: "no-store" });
    } catch {
        return "offline";
    }
}

async function readJson(res: Response): Promise<Record<string, any> | null> {
    try {
        const body = await res.json();
        return body && typeof body === "object" ? (body as Record<string, any>) : null;
    } catch {
        return null;
    }
}

function codeOf(body: Record<string, any> | null): string | null {
    const code = body?.error?.code;
    return typeof code === "string" && code.length > 0 && code.length < 80 ? code : null;
}
