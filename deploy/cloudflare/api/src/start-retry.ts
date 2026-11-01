// Retry a container start that failed (2026-11-01). Right after a deploy the runtime can report the cobalt container as
// stopped for a moment while it is still booting. @cloudflare/containers 0.3.7 then gives up at once: containerFetch answers
// 500 "Failed to start container: …", or 503 "There is no Container instance available …" before the instance is placed.
// The app showed those as a failed save, and the next paste worked. Here a start failure waits and tries again; any other
// answer (cobalt's own, whatever its status) is passed through untouched.

export const START_RETRY_DELAYS_MS = [2000, 4000, 6000];

export async function isStartFailure(res: Response): Promise<boolean> {
    if (res.status !== 500 && res.status !== 503) return false;
    const text = await res.clone().text().catch(() => "");
    return res.status === 500
        ? text.startsWith("Failed to start container")
        : text.startsWith("There is no Container instance available");
}

// `send` is called with a fresh copy of the request each time (a body can only be read once).
export async function fetchWithStartRetry(
    request: Request,
    send: (r: Request) => Promise<Response>,
    sleep: (ms: number) => Promise<unknown> = (ms) => new Promise((r) => setTimeout(r, ms)),
    delays: readonly number[] = START_RETRY_DELAYS_MS,
): Promise<Response> {
    const body = request.method === "GET" || request.method === "HEAD" ? null : await request.arrayBuffer();
    const copy = () => new Request(request.url, { method: request.method, headers: request.headers, body, signal: request.signal });
    for (let attempt = 0; ; attempt++) {
        const res = await send(copy());
        if (attempt >= delays.length || !(await isStartFailure(res))) return res;
        console.warn(`[cobalt-do] container start failed (${res.status}), retry ${attempt + 1} in ${delays[attempt]} ms`);
        await res.body?.cancel().catch(() => {});
        await sleep(delays[attempt]!);
    }
}
