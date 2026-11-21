// Emote drafts (APP-API-CONTRACT.md section 71): the file the emote editor makes on every change. A draft is not a
// library item: one R2 object in cobalt-originals, `emote-drafts/<key id>/<draft id>.<ext>`, with its numbers in the
// custom metadata, alive 24 h (checked when it is read; an expired one is deleted then). Only the key that made it sees it.

import type { OriginalsBucket } from "./studio";

export const DRAFT_TTL_MS = 24 * 3600_000;
export const DRAFT_ID_LENGTH = 22;
export const DRAFT_ID = /^[0-9A-Za-z]{22}$/;
export const DRAFT_EXT = { "image/webp": "webp", "image/gif": "gif", "image/png": "png" } as const;
const EXTS = ["webp", "gif", "png"] as const;
const TYPE_OF: Record<string, string> = { webp: "image/webp", gif: "image/gif", png: "image/png" };

export type DraftBucket = Pick<OriginalsBucket, "put" | "get" | "delete">;

export type DraftInfo = {
    format: "webp" | "gif" | "png";
    content_type: string;
    width: number;
    height: number;
    frames: number;
    duration_ms: number;
    bytes: number;
    quality: number;
    over_cap: boolean;
    created: number;
};

export const draftKey = (keyId: string, id: string, ext: string) => `emote-drafts/${keyId}/${id}.${ext}`;

export async function putDraft(bucket: DraftBucket, keyId: string, id: string, bytes: Uint8Array, info: DraftInfo): Promise<void> {
    await bucket.put(draftKey(keyId, id, info.format), bytes, {
        httpMetadata: { contentType: info.content_type },
        customMetadata: {
            created: String(info.created),
            format: info.format,
            width: String(info.width),
            height: String(info.height),
            frames: String(info.frames),
            duration_ms: String(info.duration_ms),
            bytes: String(info.bytes),
            quality: String(info.quality),
            over_cap: info.over_cap ? "1" : "0",
        },
    });
}

export async function deleteDraft(bucket: DraftBucket, keyId: string, id: string): Promise<boolean> {
    if (!DRAFT_ID.test(id)) return false;
    let found = false;
    for (const ext of EXTS) {
        const key = draftKey(keyId, id, ext);
        const o = await bucket.get(key).catch(() => null);
        if (!o) continue;
        found = true;
        await o.body.cancel().catch(() => {});
        await bucket.delete(key).catch(() => {});
    }
    return found;
}

export type Draft = { body: ReadableStream; size: number; contentType: string; format: string; created: number; expiresAt: number; meta: Record<string, string> };

/** The key's draft, or null when it is missing, another key's, or older than 24 h (which is then deleted). */
export async function readDraft(bucket: DraftBucket, keyId: string, id: string, now: number): Promise<Draft | null> {
    if (!DRAFT_ID.test(id) || !keyId) return null;
    for (const ext of EXTS) {
        const key = draftKey(keyId, id, ext);
        const o = await bucket.get(key).catch(() => null);
        if (!o) continue;
        const created = Number(o.customMetadata?.created ?? o.uploaded?.getTime() ?? NaN);
        if (!Number.isFinite(created) || now - created >= DRAFT_TTL_MS) {
            await o.body.cancel().catch(() => {});
            await bucket.delete(key).catch(() => {});
            return null;
        }
        return { body: o.body, size: o.size, contentType: o.httpMetadata?.contentType ?? TYPE_OF[ext]!, format: ext, created, expiresAt: created + DRAFT_TTL_MS, meta: o.customMetadata ?? {} };
    }
    return null;
}
