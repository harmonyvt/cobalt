// What `look` shows the model (APP-API-CONTRACT.md section 44.3): a post's picture (public ones by URL, private ones read
// from R2 and sent as base64), optionally with a grid every tenth, and optionally up to 3 frames across a video (the
// stored "what it's about" frames of section 34). The chat (chat.ts) and the MCP (mcp.ts) both use it.
// No Cloudflare imports here beyond types: the tests run it under node with fakes.

import { frameKey } from "./about-store";
import { POST_KEY_SQL } from "./app-routes";
import { picturesOf } from "./chat-tools";
import { decodePng, encodePng, isPng, pngSize, type Rgba } from "./cutout-core";
import type { ImagesPort } from "./cutout";
import { drawBox, drawGrid, type CropBox } from "./image-crop-core";
import { isMedia, mediaPosts, resolveMedia } from "./media-refs";
import { emoteFrames, emoteInfos, frameStrip } from "./emote-frames";
import type { SevenTvGate } from "./seventv-gate";

export type LookOpts = { grid?: boolean; frames?: boolean; box?: CropBox };
type Marks = { grid: boolean; box: CropBox | null };
const marked = (m: Marks) => m.grid || m.box !== null;
const paint = (img: Rgba, m: Marks): Rgba => {
    let out = img;
    if (m.box) out = drawBox(out, m.box);
    if (m.grid) out = drawGrid(out);
    return out;
};
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

export const GRID_NOTE = "magenta grid lines every 0.1 of the width and height, labelled 1..9 (tenths) along the top and left edges, thicker at 0.5, counted from the top-left: read a crop box off them";
export const BOX_NOTE = "the cyan rectangle is the proposed crop, outside it is darkened: check nothing wanted is cut off and nothing extra is in";
const noteOf = (m: Marks) => [m.grid ? GRID_NOTE : null, m.box ? BOX_NOTE : null].filter(Boolean).join("; ");

function toBase64(bytes: Uint8Array): string {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

async function readAll(b: ReadableStream<Uint8Array>): Promise<Uint8Array> {
    return new Uint8Array(await new Response(b).arrayBuffer());
}

/** A picture's bytes made ready for the model: at most LOOK_SIDE a side, a grid drawn when asked. null when it can't be. */
async function prepare(d: LookDeps, bytes: Uint8Array, type: string, m: Marks): Promise<{ data: Uint8Array; mediaType: string } | null> {
    try {
        if (d.images) {
            const out = await d.images
                .input(new Response(bytes).body!)
                .transform({ width: LOOK_SIDE, height: LOOK_SIDE, fit: "scale-down" })
                .output({ format: marked(m) ? "image/png" : "image/jpeg" });
            let data: Uint8Array = new Uint8Array(await out.response().arrayBuffer());
            if (!marked(m)) return data.length <= LOOK_MAX_BYTES ? { data, mediaType: "image/jpeg" } : null;
            data = await encodePng(paint(await decodePng(data, LOOK_SIDE * LOOK_SIDE), m));
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
            const data = marked(m) ? await encodePng(paint(await decodePng(bytes, LOOK_SIDE * LOOK_SIDE), m)) : bytes;
            return data.length <= LOOK_MAX_BYTES ? { data, mediaType: "image/png" } : null;
        }
        if (!marked(m) && (type === "image/jpeg" || type === "image/webp" || type === "image/gif") && bytes.length <= LOOK_MAX_BYTES) return { data: bytes, mediaType: type };
        return null;
    } catch (e) {
        console.error("[look] could not prepare a picture", String(e));
        return null;
    }
}

async function fromBucket(d: LookDeps, bucket: "media" | "originals", key: string, grid: Marks, label: string): Promise<LookImage | null> {
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
        const grid: Marks = { grid: o.grid === true, box: o.box ?? null };
        const note = noteOf(grid);
        const rows = results.filter((r) => r.post_key === id);
        const list: LookImage[] = [];
        const label = `Picture of post ${id}${note ? ` (${note})` : ""}:`;
        const url = pub.get(id) ?? null;
        if (url && !marked(grid)) list.push({ label, url });
        else {
            let img: LookImage | null = null;
            if (url && url.startsWith(base)) img = await fromBucket(d, "media", decodeURIComponent(url.slice(base.length)), grid, label);
            const still = rows.find(isStill);
            if (!img && still) img = await fromBucket(d, still.bucket === "media" ? "media" : "originals", still.r2_key, grid, label);
            const video = rows.find(isVideo);
            if (!img && video?.poster?.startsWith(base)) img = await fromBucket(d, "media", decodeURIComponent(video.poster.slice(base.length)), grid, label);
            if (!img && video) img = await fromBucket(d, "originals", frameKey(video.id, 1), grid, label);
            if (img) list.push(img);
            else if (url) list.push({ label: `Picture of post ${id} (the grid or box could not be drawn on this one):`, url });
        }
        if (o.frames) {
            const video = rows.find(isVideo);
            if (video) {
                for (let n = 1; n <= LOOK_FRAMES; n++) {
                    const f = await fromBucket(d, "originals", frameKey(video.id, n), grid, `Frame ${n} across video post ${id}${note ? ` (${note})` : ""}:`);
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
    if (wantedFrames && !imgs.some((i) => i.label.startsWith("Frame "))) content.push({ type: "text", text: `Post ${id} has no stored frames (not a video, or not described yet): cobalt.make.frames(id, { count }) saves frames to look at.` });
    return content;
}

// ---- look({ media }) (APP-API-CONTRACT.md section 62.1) -------------------------------------------------------------------

export type MediaLookDeps = LookDeps & { shareBaseUrl?: string | undefined; hosts: string[]; fetch?: typeof fetch; gate?: SevenTvGate | null; now?: () => number };
/** Frames look shows of an animated emote (section 63.3), in one strip. */
export const LOOK_EMOTE_FRAMES = 6;
export type MediaLook = { images: LookImage[]; note?: string };

export const MEDIA_FETCH_MS = 10_000;
export const MEDIA_FETCH_MAX_BYTES = 10 * 1024 * 1024;

// A picture fetched from an allowlisted URL (an emote's CDN picture, an image link) and made ready for the model: an
// animated one becomes its first frame through Images. null when it cannot be fetched or prepared.
async function fetchPicture(d: MediaLookDeps, url: string, label: string): Promise<LookImage | null> {
    const f = d.fetch ?? fetch;
    const deadline = Date.now() + MEDIA_FETCH_MS;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<null>((r) => (timer = setTimeout(() => r(null), MEDIA_FETCH_MS)));
    try {
        // no redirects: only the allowlisted URL itself is fetched (a 3xx is no picture)
        const res = await Promise.race([f(url, { headers: { accept: "image/*" }, redirect: "manual" }), timeout]);
        if (!res) return null;
        const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
        const declared = Number(res.headers.get("content-length") ?? 0);
        if (!res.ok || res.status !== 200 || (res.url && res.url !== url) || !type.startsWith("image/") || declared > MEDIA_FETCH_MAX_BYTES || !res.body) {
            await res.body?.cancel().catch(() => {});
            return null;
        }
        // the body is read in chunks under the same clock, and dropped past the byte cap
        const bytes = await Promise.race([readCapped(res.body, MEDIA_FETCH_MAX_BYTES, deadline), timeout]);
        if (!bytes) return null;
        const p = await prepare(d, bytes, type, { grid: false, box: null });
        return p ? { label, data: toBase64(p.data), mediaType: p.mediaType } : null;
    } catch {
        return null;
    } finally {
        clearTimeout(timer);
    }
}

// A body read to its end, or null when it is longer than `max` bytes or the deadline passes (the stream is cancelled).
export async function readCapped(body: ReadableStream<Uint8Array>, max: number, deadline: number): Promise<Uint8Array | null> {
    const reader = body.getReader();
    const parts: Uint8Array[] = [];
    let n = 0;
    try {
        for (;;) {
            if (Date.now() > deadline) {
                await reader.cancel().catch(() => {});
                return null;
            }
            const { done, value } = await reader.read();
            if (done) break;
            n += value.byteLength;
            if (n > max) {
                await reader.cancel().catch(() => {});
                return null;
            }
            parts.push(value);
        }
    } finally {
        reader.releaseLock();
    }
    const out = new Uint8Array(n);
    let at = 0;
    for (const p of parts) {
        out.set(p, at);
        at += p.byteLength;
    }
    return out;
}

/** What look({ media }) shows for each ref: a capystore post's picture (the frame path, private ones too), an emote's or
 * an image link's picture fetched directly (falling back to the URL), or a note why there is none. */
export async function lookMediaImages(d: MediaLookDeps, refs: string[], opts: LookOpts = {}, perRef: Record<string, LookOpts> = {}): Promise<Map<string, MediaLook>> {
    const bases = { mediaBaseUrl: d.mediaBaseUrl, shareBaseUrl: d.shareBaseUrl, hosts: d.hosts };
    const out = new Map<string, MediaLook>();
    if (refs.length === 0) return out;
    const answers = await resolveMedia(d.db, refs, bases);
    const posts = await mediaPosts(d.db, refs, bases);
    const postIds = [...new Set([...posts.values()])];
    const pictures = postIds.length > 0 ? await lookImages(d, postIds, Object.fromEntries(postIds.map((p) => [p, opts]))) : new Map<string, LookImage[]>();
    for (const a of answers) {
        if (!isMedia(a)) {
            out.set(a.ref, { images: [], note: `${a.ref}: ${a.error.replace("error.media.", "").replace(/_/g, " ")}` });
            continue;
        }
        const label = `Picture of ${a.kind} ${a.ref}${a.title ? ` (${a.title})` : ""}${a.kind === "emote" && a.preview_url ? ` (${a.preview_url})` : ""}:`;
        if (a.kind === "post" || a.kind === "file") {
            const pid = posts.get(a.ref);
            const list = (pid ? pictures.get(pid) : undefined) ?? [];
            out.set(a.ref, list.length > 0 ? { images: list.map((im, i) => (i === 0 ? { ...im, label } : im)) } : { images: [], note: `${a.ref} has no picture to look at.` });
            continue;
        }
        if (!a.preview_url) {
            out.set(a.ref, { images: [], note: `${a.ref} is a video link outside capystore: there is no frame to show (save it first, then look at the post).` });
            continue;
        }
        if (a.kind === "emote" && (perRef[a.ref] ?? opts).frames) {
            const strip = await emoteStrip(d, a.preview_url, a.ref).catch(() => null);
            if (strip) {
                out.set(a.ref, strip);
                continue;
            }
        }
        const img = await fetchPicture(d, a.preview_url, label);
        out.set(a.ref, { images: [img ?? { label, url: a.preview_url }] });
    }
    return out;
}

// An emote's frames (section 63.3): its GIF decoded here, LOOK_EMOTE_FRAMES frames spread across it in one strip. null
// when it is not an emote this can read (the caller shows the plain picture instead).
async function emoteStrip(d: MediaLookDeps, previewUrl: string, ref: string): Promise<MediaLook | null> {
    const id = /\/emote\/([0-9A-Za-z]{20,32})\//.exec(previewUrl)?.[1];
    if (!id) return null;
    const fd = { fetch: d.fetch, gate: d.gate ?? null, now: d.now ?? Date.now };
    const info = (await emoteInfos(fd, [id])).get(id);
    if (!info) return null;
    const f = await emoteFrames(fd, info, info.animated ? LOOK_EMOTE_FRAMES : 1, 4);
    if (f.frames.length === 0) return { images: [], note: `${ref}: no frames (${f.note ?? "nothing to decode"})` };
    const png = await encodePng(frameStrip(f, 128));
    const label = `Frames of 7TV emote ${info.name} (${id}), ${f.count} frame${f.count === 1 ? "" : "s"} in all${info.animated ? `, showing ${f.at.map((i) => i + 1).join(", ")}` : ", a still emote"}, left to right:`;
    return { images: [{ label, data: toBase64(png), mediaType: "image/png" }] };
}

/** look({ media }) as the Messages API's content blocks. */
export function lookMediaBlocks(ref: string, m: MediaLook | undefined): any[] {
    if (!m) return [{ type: "text", text: `${ref} could not be looked at.` }];
    const content: any[] = [];
    for (const im of m.images) {
        content.push({ type: "text", text: im.label });
        content.push(im.url ? { type: "image", source: { type: "url", url: im.url } } : { type: "image", source: { type: "base64", media_type: im.mediaType, data: im.data } });
    }
    if (m.note) content.push({ type: "text", text: m.note });
    return content;
}
