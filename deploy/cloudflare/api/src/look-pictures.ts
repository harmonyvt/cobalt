// What `look` shows the model (APP-API-CONTRACT.md section 44.3): a post's picture (public ones by URL, private ones read
// from R2 and sent as base64), optionally with a grid every tenth, and optionally up to 3 frames across a video (the
// stored "what it's about" frames of section 34). The chat (chat.ts) and the MCP (mcp.ts) both use it.
// No Cloudflare imports here beyond types: the tests run it under node with fakes.

import { frameKey } from "./about-store";
import { POST_KEY_SQL } from "./app-routes";
import { picturesOf } from "./chat-tools";
import { decodePng, encodePng, isPng, pngSize } from "./cutout-core";
import type { ImagesPort } from "./cutout";
import { drawGrid } from "./image-crop-core";

export type LookOpts = { grid?: boolean; frames?: boolean };
/** One picture for the model: by URL (public files) or inline. */
export type LookImage = { label: string; url?: string; data?: string; mediaType?: string };

/** The model's own size limit for a picture's longer side, and the most bytes one picture may be. */
export const LOOK_SIDE = 1568;
export const LOOK_MAX_BYTES = 3_900_000;
export const LOOK_FRAMES = 3;

type Bucket = { get(key: string): Promise<{ body: ReadableStream<Uint8Array>; size: number; httpMetadata?: { contentType?: string } } | null> };

export type LookDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    originals?: Bucket;
    media?: Bucket;
    images?: ImagesPort | null;
};

type Row = { id: string; r2_key: string; bucket: string; content_type: string | null; poster: string | null; url: string | null; role: string | null; item_index: number | null; post_key: string };

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const isVideo = (r: Row) => String(r.content_type ?? "").startsWith("video/");
const isStill = (r: Row) => String(r.content_type ?? "").startsWith("image/");

export const GRID_NOTE = "grid lines every 0.1 of the width and height (thicker at 0.5), counted from the top-left: read a crop box off them";

function toBase64(bytes: Uint8Array): string {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

async function readAll(b: ReadableStream<Uint8Array>): Promise<Uint8Array> {
    return new Uint8Array(await new Response(b).arrayBuffer());
}

/** A picture's bytes made ready for the model: at most LOOK_SIDE a side, a grid drawn when asked. null when it can't be. */
async function prepare(d: LookDeps, bytes: Uint8Array, type: string, grid: boolean): Promise<{ data: Uint8Array; mediaType: string } | null> {
    try {
        if (d.images) {
            const out = await d.images
                .input(new Response(bytes).body!)
                .transform({ width: LOOK_SIDE, height: LOOK_SIDE, fit: "scale-down" })
                .output({ format: grid ? "image/png" : "image/jpeg" });
            let data: Uint8Array = new Uint8Array(await out.response().arrayBuffer());
            if (!grid) return data.length <= LOOK_MAX_BYTES ? { data, mediaType: "image/jpeg" } : null;
            data = await encodePng(drawGrid(await decodePng(data, LOOK_SIDE * LOOK_SIDE)));
            // a big PNG goes back through Images as a JPEG
            if (data.length > LOOK_MAX_BYTES) {
                const j = await d.images.input(new Response(data).body!).transform({}).output({ format: "image/jpeg" });
                data = new Uint8Array(await j.response().arrayBuffer());
                return data.length <= LOOK_MAX_BYTES ? { data, mediaType: "image/jpeg" } : null;
            }
            return { data, mediaType: "image/png" };
        }
        // no Images binding: small PNGs (any) and small JPEGs (no grid) only
        if (isPng(bytes)) {
            const s = pngSize(bytes);
            if (!s || s.width > LOOK_SIDE || s.height > LOOK_SIDE) return null;
            const data = grid ? await encodePng(drawGrid(await decodePng(bytes, LOOK_SIDE * LOOK_SIDE))) : bytes;
            return data.length <= LOOK_MAX_BYTES ? { data, mediaType: "image/png" } : null;
        }
        if (!grid && (type === "image/jpeg" || type === "image/webp" || type === "image/gif") && bytes.length <= LOOK_MAX_BYTES) return { data: bytes, mediaType: type };
        return null;
    } catch (e) {
        console.error("[look] could not prepare a picture", String(e));
        return null;
    }
}

async function fromBucket(d: LookDeps, bucket: "media" | "originals", key: string, grid: boolean, label: string): Promise<LookImage | null> {
    const b = bucket === "media" ? d.media : d.originals;
    if (!b) return null;
    const obj = await b.get(key).catch(() => null);
    if (!obj) return null;
    if (obj.size > 30 * 1024 * 1024) {
        await obj.body.cancel().catch(() => {});
        return null;
    }
    const bytes = await readAll(obj.body);
    const type = obj.httpMetadata?.contentType ?? (/\.png$/i.test(key) ? "image/png" : /\.jpe?g$/i.test(key) ? "image/jpeg" : /\.webp$/i.test(key) ? "image/webp" : "");
    const p = await prepare(d, bytes, type, grid);
    return p ? { label, data: toBase64(p.data), mediaType: p.mediaType } : null;
}

/**
 * The pictures `look` shows for each post id (in order; a post with nothing to show gets []). Public pictures go by URL
 * unless a grid is wanted; everything else is read from R2.
 */
export async function lookImages(d: LookDeps, ids: string[], opts: Record<string, LookOpts> = {}): Promise<Map<string, LookImage[]>> {
    const out = new Map<string, LookImage[]>();
    if (ids.length === 0) return out;
    const pub = await picturesOf(d, ids);
    const base = withSlash(d.mediaBaseUrl);
    const { results } = await d.db
        .prepare(
            `SELECT * FROM (SELECT m.id, m.r2_key, m.bucket, m.content_type, m.poster, m.url, m.role, m.item_index, m.created_at, ${POST_KEY_SQL} AS post_key
                            FROM media_items m WHERE m.deleted_at IS NULL)
             WHERE post_key IN (${ids.map((_, i) => `?${i + 1}`).join(", ")}) ORDER BY item_index, created_at, id`,
        )
        .bind(...ids)
        .all<Row>();
    for (const id of ids) {
        const o = opts[id] ?? {};
        const grid = o.grid === true;
        const rows = results.filter((r) => r.post_key === id);
        const list: LookImage[] = [];
        const label = `Picture of post ${id}${grid ? ` (${GRID_NOTE})` : ""}:`;
        const url = pub.get(id) ?? null;
        if (url && !grid) list.push({ label, url });
        else {
            let img: LookImage | null = null;
            if (url && url.startsWith(base)) img = await fromBucket(d, "media", decodeURIComponent(url.slice(base.length)), grid, label);
            const still = rows.find(isStill);
            if (!img && still) img = await fromBucket(d, still.bucket === "media" ? "media" : "originals", still.r2_key, grid, label);
            const video = rows.find(isVideo);
            if (!img && video?.poster?.startsWith(base)) img = await fromBucket(d, "media", decodeURIComponent(video.poster.slice(base.length)), grid, label);
            if (!img && video) img = await fromBucket(d, "originals", frameKey(video.id, 1), grid, label);
            if (img) list.push(img);
            else if (url) list.push({ label: `Picture of post ${id} (no grid: it could not be drawn on this one):`, url });
        }
        if (o.frames) {
            const video = rows.find(isVideo);
            if (video) {
                for (let n = 1; n <= LOOK_FRAMES; n++) {
                    const f = await fromBucket(d, "originals", frameKey(video.id, n), grid, `Frame ${n} across video post ${id}${grid ? ` (${GRID_NOTE})` : ""}:`);
                    if (f) list.push(f);
                }
            }
        }
        out.set(id, list);
    }
    return out;
}

/** Turns lookImages' answer into the Messages API's content blocks (text label, then the image). */
export function lookBlocks(id: string, imgs: LookImage[] | undefined, wantedFrames: boolean): any[] {
    const content: any[] = [];
    if (!imgs || imgs.length === 0) return [{ type: "text", text: `Post ${id} has no picture to look at.` }];
    for (const im of imgs) {
        content.push({ type: "text", text: im.label });
        content.push(im.url ? { type: "image", source: { type: "url", url: im.url } } : { type: "image", source: { type: "base64", media_type: im.mediaType, data: im.data } });
    }
    if (wantedFrames && !imgs.some((i) => i.label.startsWith("Frame "))) content.push({ type: "text", text: `Post ${id} has no stored frames (not a video, or not described yet).` });
    return content;
}
