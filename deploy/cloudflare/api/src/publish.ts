// POST /studio/<sid>/publish (LIBRARY-CONTRACT.md route 1, APP-API-CONTRACT.md section 16): makes a
// ready session's stored original public. Since migration 0008 there is one row per file: this is
// the legacy spelling of "toggle on" (visibility.ts) on the session's original row, so a repeat
// returns the same link and nothing is copied twice. Runs in the Worker (D1 + R2 only), the
// container is never involved. Free of Cloudflare imports so it runs under plain node in the tests.

import { SERVICE_KEY_ID, insertMediaItem, pageLink } from "./library";
import { getOriginalByKey, publishOriginal, type PurgeFn } from "./visibility";
import { getSession, studioErr, type OriginalsBucket, type StudioReply } from "./studio";

// The public bucket `cobalt-media`, as publish needs it (a stream body). Posters, mirrors and
// the webp switch also read it back (head / get).
export interface PublishBucket {
    put(
        key: string,
        value: ReadableStream,
        options: {
            httpMetadata: { contentType: string; cacheControl: string };
            customMetadata: Record<string, string>;
        },
    ): Promise<{ size: number } | null>;
    delete(key: string): Promise<void>;
    head(key: string): Promise<{ size: number } | null>;
    get(key: string): Promise<{
        body: ReadableStream;
        size: number;
        httpMetadata?: { contentType?: string };
    } | null>;
}

export type PublishDeps = {
    db: D1Database;
    originals: OriginalsBucket;
    media: PublishBucket;
    mediaBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    // edge-cache purge (section 16); absent = not configured
    purge?: PurgeFn;
};

export async function publishStudio(
    d: PublishDeps,
    sid: string,
    keyId: string = SERVICE_KEY_ID,
): Promise<StudioReply> {
    let session;
    let row: Awaited<ReturnType<typeof getOriginalByKey>> = null;
    try {
        session = await getSession(d.db, sid);
        if (session?.r2_key) row = await getOriginalByKey(d.db, session.r2_key);
    } catch {
        return studioErr(503, "error.api.generic");
    }
    if (!session) return studioErr(404, "error.studio.not_found");
    if (session.status !== "ready" || !session.r2_key) return studioErr(409, "error.studio.not_ready");
    // the row outlives the session, so a session past its 7 days can still be published
    if (!row) {
        // A ready save whose library row was never written (the insert is bookkeeping that may fail
        // without failing the save): write it now, then publish it like any other.
        const upload = (session.link ?? "").startsWith("upload:");
        await insertMediaItem(
            d.db,
            {
                kind: "private",
                source: upload ? "upload" : "saved",
                bucket: "originals",
                r2_key: session.r2_key,
                name: session.title ?? session.r2_key.split("/").pop() ?? session.r2_key,
                content_type: session.content_type,
                bytes: session.bytes,
                width: session.width,
                height: session.height,
                duration: session.duration,
                link: pageLink(session.link),
                session_id: session.id,
                key_id: session.key_id,
                created_at: d.now(),
                poster: session.poster ?? null,
            },
            d.randomBytes,
        );
        try {
            row = await getOriginalByKey(d.db, session.r2_key);
        } catch {
            return studioErr(503, "error.api.generic");
        }
        if (!row) return studioErr(503, "error.api.generic");
    }
    return publishOriginal(d, row, keyId);
}
