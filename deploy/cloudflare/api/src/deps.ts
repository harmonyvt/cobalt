// The per-request deps the Worker's routes share, wired to the request's bindings: the app's routes (AppDeps), the search
// Space client and the share host. Used by worker.ts (the old route chain) and the op registry (src/registry/), so both
// build them the same way. Free of Cloudflare imports (tests run it under node).
import type { AppDeps } from "./app-routes";
import { spaceClient, type EmbedClient } from "./embed";
import { KEY_ID_HEADER } from "./headers";
import type { EdgeDeps } from "./studio-edge";
import { purgeFrom } from "./visibility";
import type { WorkerEnv } from "./worker";

// The single "main" Container Durable Object (a stub in production).
export interface ContainerStub {
    fetch(request: Request): Promise<Response>;
}

// The hostname of SHARE_BASE_URL, or null while it is not set (or not an https URL).
export const shareHost = (env: Pick<WorkerEnv, "SHARE_BASE_URL">): string | null => {
    if (!env.SHARE_BASE_URL) return null;
    try {
        const u = new URL(env.SHARE_BASE_URL);
        return u.protocol === "https:" ? u.hostname : null;
    } catch {
        return null;
    }
};

// The share base URL while the share host is on, else undefined.
export const shareBaseFrom = (env: Pick<WorkerEnv, "SHARE_BASE_URL">): string | undefined =>
    shareHost(env) ? env.SHARE_BASE_URL : undefined;

// The Space client, or null while search is not configured (embed.ts).
export const embedFrom = (env: WorkerEnv): EmbedClient | null =>
    spaceClient({ url: env.EMBED_URL, token: env.EMBED_TOKEN, key: env.EMBED_KEY, space: env.EMBED_SPACE });

// A JSON reply from the Durable Object, or a generic failure when it is not JSON.
async function doJson(res: Response): Promise<{ status: number; body: unknown }> {
    let parsed: unknown = null;
    try {
        parsed = await res.json();
    } catch {
        // not JSON: reported as a generic failure below
    }
    return { status: res.status, body: parsed ?? { status: "error", error: { code: "error.api.generic" } } };
}

// What the app's routes need, wired to this request's bindings. The one call
// into the Durable Object is the internal adopt path a stored video continues
// into; the caller's key id (set here, after the D1 lookup) travels in the
// header the Worker strips from every client request.
export function appDeps(env: WorkerEnv, container: ContainerStub, edge: EdgeDeps): AppDeps {
    return {
        db: env.DB,
        originals: env.ORIGINALS,
        media: env.MEDIA,
        mediaBaseUrl: env.MEDIA_BASE_URL,
        shareBaseUrl: shareBaseFrom(env),
        apiUrl: env.API_URL,
        webUrl: env.CORS_URL,
        now: edge.now,
        purge: purgeFrom(env),
        fixedLength: edge.fixedLength ?? ((n) => new FixedLengthStream(n)),
        // Queues the missing posters in the Durable Object (records only; it answers at once).
        kickPosters: async (limit) =>
            doJson(
                await container.fetch(
                    new Request(`https://do.internal/posters/kick${limit ? `?limit=${limit}` : ""}`, {
                        method: "POST",
                        headers: { [KEY_ID_HEADER]: "worker:posters" },
                    }),
                ),
            ),
        adopt: async (keyId, body) =>
            doJson(
                await container.fetch(
                    new Request("https://do.internal/studio/upload/adopt", {
                        method: "POST",
                        headers: { "content-type": "application/json", [KEY_ID_HEADER]: keyId },
                        body: JSON.stringify(body),
                    }),
                ),
            ),
    };
}
