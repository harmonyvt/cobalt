// Pictures to embed (APP-API-CONTRACT.md section 63.7): artifact pages and other sandboxed HTML block remote images, so
// media.export turns media refs (7TV emotes, capystore posts and files, allowed image links) into small data URIs, or
// one sprite sheet with each tile's place, as a file to download (and inline when it is small). An animated emote stays
// animated (its own WebP at the scale asked for); everything else is scaled down through Images to a WebP.
import * as z from "zod";
import { decodePng, encodePng, isPng, type Rgba } from "../../cutout-core";
import type { ImagesPort } from "../../cutout";
import { blank, pasteFit } from "../../canvas-draw";
import { emoteFrames, emoteInfos, type EmoteInfo } from "../../emote-frames";
import { decodeGif, isGif } from "../../gif";
import { lookImages } from "../../look-pictures";
import { mediaHostsOf, mediaPosts, parseMediaRef } from "../../media-refs";
import { writeExport } from "../../mcp-export";
import { gateOf } from "../../seventv-gate";
import { defineOp, ok, OpError } from "../op";

export const EXPORT_REFS_MAX = 60;
/** Answered inline as well as in the file when the whole JSON is at most this long. */
export const EXPORT_INLINE_MAX = 120_000;
const FETCH_MAX = 16 * 1024 * 1024;

type Pic = { ref: string; label: string; mime: string; bytes: Uint8Array; width: number; height: number; animated: boolean };
type Failed = { ref: string; error: string };

const b64 = (b: Uint8Array) => {
    let s = "";
    for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
    return btoa(s);
};

async function fetchBytes(url: string): Promise<{ bytes: Uint8Array; type: string } | null> {
    try {
        const res = await fetch(url, { headers: { accept: "image/*" }, redirect: "manual", signal: AbortSignal.timeout(15_000) });
        if (res.status !== 200) {
            await res.body?.cancel().catch(() => {});
            return null;
        }
        const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
        const bytes = new Uint8Array(await res.arrayBuffer());
        return bytes.length > 0 && bytes.length <= FETCH_MAX ? { bytes, type } : null;
    } catch {
        return null;
    }
}

/** The emote's WebP at the smallest 7TV scale that is at least `size` px tall (animated kept unless `still`). */
function emoteWebp(e: EmoteInfo, size: number, still: boolean) {
    const rows = e.images.filter((i) => i.mime === "image/webp" && (still || !e.animated ? i.url.includes("_static") || !e.animated : !i.url.includes("_static"))).sort((a, b) => a.scale - b.scale);
    return rows.find((i) => i.height >= size) ?? rows[rows.length - 1] ?? null;
}

async function scaled(images: ImagesPort | null, bytes: Uint8Array, size: number, format: "image/webp" | "image/png"): Promise<{ bytes: Uint8Array; mime: string } | null> {
    if (!images) return isPng(bytes) ? { bytes, mime: "image/png" } : null;
    try {
        const out = await images.input(new Response(bytes).body!).transform({ width: size, height: size, fit: "scale-down" }).output({ format, ...(format === "image/webp" ? { quality: 82 } : {}) } as { format: string });
        return { bytes: new Uint8Array(await out.response().arrayBuffer()), mime: format };
    } catch {
        return null;
    }
}

const dims = (b: Uint8Array): { width: number; height: number } => {
    // PNG IHDR, or WebP VP8X / VP8 / VP8L headers
    if (isPng(b)) return { width: (b[16]! << 24) | (b[17]! << 16) | (b[18]! << 8) | b[19]!, height: (b[20]! << 24) | (b[21]! << 16) | (b[22]! << 8) | b[23]! };
    const tag = String.fromCharCode(...b.subarray(12, 16));
    if (tag === "VP8X") return { width: 1 + (b[24]! | (b[25]! << 8) | (b[26]! << 16)), height: 1 + (b[27]! | (b[28]! << 8) | (b[29]! << 16)) };
    if (tag === "VP8 ") return { width: (b[26]! | (b[27]! << 8)) & 0x3fff, height: (b[28]! | (b[29]! << 8)) & 0x3fff };
    if (tag === "VP8L") {
        const v = b[21]! | (b[22]! << 8) | (b[23]! << 16) | (b[24]! << 24);
        return { width: (v & 0x3fff) + 1, height: ((v >>> 14) & 0x3fff) + 1 };
    }
    return { width: 0, height: 0 };
};

export const mediaExportOp = defineOp({
    name: "media.export",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        refs: z.array(z.string().trim().min(1).max(2048)).min(1).max(EXPORT_REFS_MAX).describe("media refs: 7TV emote ids or links, capystore links, post or file ids, allowed image URLs"),
        size: z.number().int().min(16).max(512).optional().describe("longest side in px (default 128)"),
        format: z.enum(["data_uri", "sprite"]).optional().describe("data_uri (default): one data: URI each; sprite: one sheet plus each tile's x, y, w, h (stills only)"),
        still: z.boolean().optional().describe("animated emotes as their first frame (data_uri keeps them moving by default)"),
        labels: z.array(z.string().max(80)).max(EXPORT_REFS_MAX).optional().describe("a name for each ref, in order (default the emote or post name)"),
    }),
    output: z.object({
        url: z.string().describe("the JSON file: GET within an hour (curl -o)"),
        file: z.string(),
        bytes: z.number(),
        expires_at: z.string(),
        curl: z.string(),
        items: z.array(z.object({ ref: z.string(), label: z.string(), width: z.number(), height: z.number(), bytes: z.number(), animated: z.boolean(), x: z.number().optional(), y: z.number().optional() })),
        failed: z.array(z.object({ ref: z.string(), error: z.string() })),
        sprite: z.object({ width: z.number(), height: z.number(), tile: z.number(), bytes: z.number() }).optional(),
        inline: z.unknown().optional().describe("the file's own JSON, when it is small"),
    }),
    ai: {
        tier: "free",
        only: true,
        summary:
            `Pictures to EMBED in an artifact or any HTML that blocks remote images: up to ${EXPORT_REFS_MAX} refs (7TV emotes, capystore posts/files, image links) as small data: URIs (animated emotes stay animated), or one sprite sheet with each tile's place. Answers a one-hour JSON file link (curl -o), and the JSON inline when it is small. File: { items: [{ ref, label, width, height, data_uri }] } or { sprite: { data_uri, width, height, tile }, items: [{ ref, label, x, y, w, h }], css }.`,
        params: ["refs"],
        options: true,
        when: (f) => f.mcp === true,
    },
    handler: async (ctx, input) => {
        const mcp = ctx.chat?.mcp;
        if (!ctx.chat || !mcp) throw new OpError(404, "error.mcp.only", "media.export: only the MCP server can call this");
        const size = input.size ?? 128;
        const sprite = input.format === "sprite";
        const images = ((ctx.env as { IMAGES?: unknown }).IMAGES ?? null) as ImagesPort | null;
        const env = ctx.env as { ORIGINALS?: unknown; MEDIA?: unknown };
        const bases = { mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl, hosts: mediaHostsOf(ctx.env as { MEDIA_HOSTS?: string }, ctx) };
        const refs = input.refs;
        const parsed = refs.map((r) => parseMediaRef(r, bases));
        const emoteIds = parsed.flatMap((p) => (p?.kind === "emote" ? [p.id] : []));
        const fd = { gate: gateOf(ctx.env), now: ctx.now };
        const infos = emoteIds.length > 0 ? await emoteInfos(fd, emoteIds).catch(() => new Map<string, EmoteInfo>()) : new Map<string, EmoteInfo>();
        const posts = await mediaPosts(ctx.db, refs.filter((_, i) => parsed[i] && parsed[i]!.kind === "capystore"), bases).catch(() => new Map<string, string>());

        const pics: Pic[] = [];
        const rgba = new Map<string, Rgba>();
        const failed: Failed[] = [];
        for (let i = 0; i < refs.length; i++) {
            const ref = refs[i]!;
            const p = parsed[i];
            const label = input.labels?.[i] ?? "";
            if (!p || p.kind === "refused") {
                failed.push({ ref, error: p?.kind === "refused" ? p.error : "not a media ref" });
                continue;
            }
            if (p.kind === "emote") {
                const e = infos.get(p.id);
                if (!e) {
                    failed.push({ ref, error: "no such emote on 7TV" });
                    continue;
                }
                if (sprite) {
                    const f = await emoteFrames(fd, e, 1, Math.min(4, Math.max(1, Math.ceil(size / 32))));
                    if (!f.frames[0]) {
                        failed.push({ ref, error: f.note ?? "no picture" });
                        continue;
                    }
                    rgba.set(ref, f.frames[0]);
                    pics.push({ ref, label: label || e.name, mime: "image/png", bytes: new Uint8Array(), width: f.frames[0].width, height: f.frames[0].height, animated: false });
                    continue;
                }
                const w = emoteWebp(e, size, input.still === true);
                const got = w ? await fetchBytes(w.url) : null;
                if (!w || !got) {
                    failed.push({ ref, error: "7TV's CDN did not answer" });
                    continue;
                }
                pics.push({ ref, label: label || e.name, mime: "image/webp", bytes: got.bytes, width: w.width, height: w.height, animated: e.animated && input.still !== true });
                continue;
            }
            // a capystore ref or an image link: its picture, scaled down
            let src: { bytes: Uint8Array; type: string } | null = null;
            let name = label;
            if (p.kind === "url") {
                if (p.media !== "image") {
                    failed.push({ ref, error: "a video link: save it, then export the post" });
                    continue;
                }
                src = await fetchBytes(p.url);
            } else {
                const post = posts.get(ref);
                if (!post) {
                    failed.push({ ref, error: "not found in the library" });
                    continue;
                }
                const pic = (await lookImages({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, originals: env.ORIGINALS as never, media: env.MEDIA as never, images }, [post])).get(post)?.[0];
                if (pic?.url) src = await fetchBytes(pic.url);
                else if (pic?.data) src = { bytes: Uint8Array.from(atob(pic.data), (c) => c.charCodeAt(0)), type: pic.mediaType ?? "" };
                name ||= post;
            }
            if (!src) {
                failed.push({ ref, error: "no picture" });
                continue;
            }
            if (sprite) {
                let img: Rgba | null = null;
                try {
                    if (isGif(src.bytes)) img = decodeGif(src.bytes, { want: [0], maxPixels: 60_000_000 }).frames[0]!.image;
                    else {
                        const png = await scaled(images, src.bytes, Math.max(size, 256), "image/png");
                        if (png) img = await decodePng(png.bytes, 4096 * 4096);
                    }
                } catch {
                    img = null;
                }
                if (!img) {
                    failed.push({ ref, error: "would not decode" });
                    continue;
                }
                rgba.set(ref, img);
                pics.push({ ref, label: name || ref, mime: "image/png", bytes: new Uint8Array(), width: img.width, height: img.height, animated: false });
                continue;
            }
            const out = await scaled(images, src.bytes, size, "image/webp");
            if (!out) {
                failed.push({ ref, error: "could not scale it here" });
                continue;
            }
            const d = dims(out.bytes);
            pics.push({ ref, label: name || ref, mime: out.mime, bytes: out.bytes, width: d.width, height: d.height, animated: false });
        }
        if (pics.length === 0) throw new OpError(422, "error.export.empty", `media.export: nothing could be exported: ${failed.map((f) => `${f.ref}: ${f.error}`).slice(0, 5).join("; ")}`);

        let file: Record<string, unknown>;
        let items: { ref: string; label: string; width: number; height: number; bytes: number; animated: boolean; x?: number; y?: number }[];
        let spriteInfo: { width: number; height: number; tile: number; bytes: number } | undefined;
        if (sprite) {
            const cols = Math.ceil(Math.sqrt(pics.length));
            const rows = Math.ceil(pics.length / cols);
            const sheet = blank(cols * size, rows * size, [0, 0, 0]);
            sheet.data.fill(0);
            items = pics.map((p, i) => {
                const x = (i % cols) * size;
                const y = Math.floor(i / cols) * size;
                pasteFit(sheet, rgba.get(p.ref)!, x, y, size, size, 4);
                return { ref: p.ref, label: p.label, width: size, height: size, bytes: 0, animated: false, x, y };
            });
            let bytes: Uint8Array = await encodePng(sheet);
            let mime = "image/png";
            const webp = images ? await scaled(images, bytes, Math.max(sheet.width, sheet.height), "image/webp") : null;
            if (webp && webp.bytes.length < bytes.length) {
                bytes = webp.bytes;
                mime = webp.mime;
            }
            spriteInfo = { width: sheet.width, height: sheet.height, tile: size, bytes: bytes.length };
            const css = [
                `.sprite{display:inline-block;width:${size}px;height:${size}px;background-image:url(data:${mime};base64,…);background-repeat:no-repeat}`,
                ...items.map((t, i) => `.sprite-${i}{background-position:${t.x ? -t.x : 0}px ${t.y ? -t.y : 0}px}`),
            ].join("\n");
            file = { sprite: { data_uri: `data:${mime};base64,${b64(bytes)}`, width: sheet.width, height: sheet.height, tile: size }, items: items.map((t) => ({ ref: t.ref, label: t.label, x: t.x, y: t.y, w: size, h: size })), css, failed };
        } else {
            items = pics.map((p) => ({ ref: p.ref, label: p.label, width: p.width, height: p.height, bytes: p.bytes.length, animated: p.animated }));
            file = { items: pics.map((p) => ({ ref: p.ref, label: p.label, width: p.width, height: p.height, animated: p.animated, data_uri: `data:${p.mime};base64,${b64(p.bytes)}` })), failed };
        }
        const text = JSON.stringify(file);
        const link = await writeExport(
            { bucket: ctx.env.ORIGINALS as never, secret: ctx.env.COBALT_API_KEY, now: ctx.now, origin: mcp.origin, clientKeyId: mcp.clientKeyId },
            sprite ? "sprite.json" : "images.json",
            text,
            "application/json",
        );
        return ok({ ...link, items, failed, ...(spriteInfo ? { sprite: spriteInfo } : {}), ...(text.length <= EXPORT_INLINE_MAX ? { inline: file } : {}) });
    },
});

export const EXPORT_OPS = [mediaExportOp];
