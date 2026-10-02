// POST /studio/<sid>/publish (LIBRARY-CONTRACT.md route 1): copies a ready
// session's stored original from the private bucket to the public one under a
// new unguessable name, and records it in the library. Runs in the Worker
// (D1 + R2 only), the container is never involved. Free of Cloudflare imports
// so it runs under plain node in the tests.
//
// The copy hands the R2 object's own body to the other bucket's put(): the
// object body has a known length, so there is no buffering and no FixedLength
// wrapper, and no ReadableStream.pipeTo() (unimplemented between streams in
// this runtime, which hung a put until the Durable Object died, 2026-10-01).

import { randomBase62 } from "./ids";
import { insertMediaItem, pageLink, SERVICE_KEY_ID } from "./library";
import { MEDIA_NAME_LENGTH } from "./webp";
import { getSession, studioErr, type OriginalsBucket, type SessionRow, type StudioReply } from "./studio";

// The public bucket `cobalt-media`, as publish needs it (a stream body).
export interface PublishBucket {
    put(
        key: string,
        value: ReadableStream,
        options: {
            httpMetadata: { contentType: string; cacheControl: string };
            customMetadata: Record<string, string>;
        },
    ): Promise<{ size: number } | null>;
}

export type PublishDeps = {
    db: D1Database;
    originals: OriginalsBucket;
    media: PublishBucket;
    mediaBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
};

const extOf = (key: string): string => {
    const m = /\.([A-Za-z0-9]{1,8})$/.exec(key);
    return m ? m[1].toLowerCase() : "bin";
};

// "<title>.<ext>" unless the title already ends that way (uploads carry their file name).
function displayName(row: SessionRow, ext: string, name: string): string {
    const title = row.title?.trim();
    if (!title) return name;
    return title.toLowerCase().endsWith(`.${ext}`) ? title : `${title}.${ext}`;
}

export async function publishStudio(
    d: PublishDeps,
    sid: string,
    keyId: string = SERVICE_KEY_ID,
): Promise<StudioReply> {
    let row: SessionRow | null;
    try {
        row = await getSession(d.db, sid);
    } catch {
        return studioErr(503, "error.api.generic");
    }
    if (!row) return studioErr(404, "error.studio.not_found");
    if (d.now() > row.expires_at) return studioErr(410, "error.studio.expired");
    if (row.status !== "ready" || !row.r2_key) return studioErr(409, "error.studio.not_ready");

    const ext = extOf(row.r2_key);
    const contentType = row.content_type || "video/mp4";
    const name = `${randomBase62(MEDIA_NAME_LENGTH, d.randomBytes)}.${ext}`;

    let obj;
    try {
        obj = await d.originals.get(row.r2_key);
    } catch {
        return studioErr(502, "error.studio.storage");
    }
    if (!obj) return studioErr(502, "error.studio.storage");

    let stored: { size: number } | null;
    try {
        stored = await d.media.put(name, obj.body, {
            httpMetadata: {
                contentType,
                cacheControl: "public, max-age=31536000, immutable",
            },
            customMetadata: {
                keyId,
                source: (pageLink(row.link) ?? "").slice(0, 1000),
                sessionId: sid,
                createdAt: String(d.now()),
                published: "1",
            },
        });
    } catch (e) {
        console.error("[publish] R2 copy failed", sid, String(e));
        await obj.body.cancel().catch(() => {});
        return studioErr(502, "error.studio.storage");
    }

    const bytes = stored?.size ?? obj.size;
    const base = d.mediaBaseUrl.endsWith("/") ? d.mediaBaseUrl : `${d.mediaBaseUrl}/`;
    const url = `${base}${name}`;
    const itemId = await insertMediaItem(
        d.db,
        {
            kind: "public",
            source: "host",
            bucket: "media",
            r2_key: name,
            url,
            name: displayName(row, ext, name),
            content_type: contentType,
            bytes,
            width: row.width,
            height: row.height,
            duration: row.duration,
            link: pageLink(row.link),
            session_id: sid,
            key_id: keyId,
            created_at: d.now(),
        },
        d.randomBytes,
    );

    return {
        status: 201,
        body: { status: "success", url, bytes, content_type: contentType, item_id: itemId },
    };
}
