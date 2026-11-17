// Rich link previews for public media (APP-API-CONTRACT.md section 22): the fixupx idea. A public file
// at https://media.../<name>.<ext> also has a share page at https://<share host>/<name>, an HTML page
// whose Open Graph and Twitter card tags point at the file, so a pasted link unfurls as a playable
// video or a full-size image in Discord, iMessage, X, Telegram, Slack and the like. People who open it
// get the same file on a plain page. Only files that are public right now have a page; a private,
// deleted or unknown name is a 404 that says nothing about which. Runs in the Worker (D1 only), the
// container is never involved. Free of Cloudflare imports so it runs under plain node in the tests.

import { notHiddenClause } from "./hidden-store";
import { POST_KEY_SQL } from "./app-routes";
import { readMp4Info, SHARE_CODEC_BYTES } from "./mp4-info";
import { captionOf, fileOf, itemSubject, writeCaption, type Caption, type Captioner } from "./roast";
import { shareSetRoute } from "./share-sets";
import { privateRoute, type ByteBucket } from "./share-private";
import { chatShareRoute } from "./chat-share-page";
import { ITEM_COLUMNS, effectiveVisibility, extOf, type MediaRow } from "./visibility";

export type ShareDeps = {
    db: D1Database;
    // https://media.../ (with or without the slash)
    mediaBaseUrl: string;
    // https://<share host>/ (with or without the slash)
    shareBaseUrl: string;
    // Roast captions (section 25): a public file seen for the first time gets its title written right
    // then, so the first unfurl already has it. Absent: the page uses what the cron wrote.
    captioner?: Captioner | null;
    waitUntil?: (p: Promise<unknown>) => void;
    captionWaitMs?: number;
    // gallery links' moving previews in Discord (section 29.1); absent = on
    loops?: boolean;
    // the buckets a private link's files are streamed from (section 36): `cobalt-originals` and `cobalt-media`.
    // Absent: /p/<key>/<n>.<ext> is a 404.
    originals?: ByteBucket;
    media?: ByteBucket;
    // the clock a private link's open count reads (absent: Date.now)
    now?: () => number;
};

// How long the first page view waits for its caption before answering without it (Discord gives up
// on slow pages after about 10 s); the caption still finishes and is used from the next view on.
export const FIRST_CAPTION_WAIT_MS = 6000;

// The caption of a public file, written now when it has never been tried (the cron retries failures).
async function captionNow(d: ShareDeps, row: Found, fileUrl: string): Promise<Caption | null> {
    const have = await captionOf(d.db, itemSubject(row.id));
    if (have || !d.captioner) return have;
    try {
        const tried = await d.db.prepare("SELECT 1 AS x FROM media_captions WHERE subject = ?1").bind(itemSubject(row.id)).first();
        if (tried) return null;
    } catch {
        return null;
    }
    const job = writeCaption({ db: d.db, captioner: d.captioner, now: () => Date.now() }, itemSubject(row.id), { files: [fileOf(row, fileUrl)], userTitle: null });
    d.waitUntil?.(job);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<null>((r) => (timer = setTimeout(() => r(null), d.captionWaitMs ?? FIRST_CAPTION_WAIT_MS)));
    try {
        return await Promise.race([job, late]);
    } finally {
        clearTimeout(timer);
    }
}

// The last path segment: the public object's name with or without its extension.
const SHARE_PATH = /^\/([A-Za-z0-9]{6,40})(?:\.([A-Za-z0-9]{1,8}))?\/?$/;

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

const TYPES: Record<string, string> = {
    mp4: "video/mp4",
    m4v: "video/mp4",
    mov: "video/quicktime",
    webm: "video/webm",
    webp: "image/webp",
    gif: "image/gif",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    png: "image/png",
    heic: "image/heic",
    avif: "image/avif",
};

export const escapeHtml = (s: string): string =>
    s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

// The share link of a public media URL, or null when it is not one of this server's public files.
// The app derives the same link from `share_base_url` in GET /capabilities.
export function shareUrlFor(mediaUrl: string, mediaBaseUrl: string, shareBaseUrl: string): string | null {
    const base = withSlash(mediaBaseUrl);
    if (!mediaUrl.startsWith(base)) return null;
    const m = /^([A-Za-z0-9]{6,40})\.[A-Za-z0-9]{1,8}$/.exec(mediaUrl.slice(base.length));
    return m ? `${withSlash(shareBaseUrl)}${m[1]}` : null;
}

// The mapper for messages that carry a public link (the Hark notifications), or undefined while
// SHARE_BASE_URL is unset or not https.
export function shareLinkFrom(env: { MEDIA_BASE_URL: string; SHARE_BASE_URL?: string }): ((url: string) => string) | undefined {
    const share = env.SHARE_BASE_URL;
    if (!share) return undefined;
    try {
        if (new URL(share).protocol !== "https:") return undefined;
    } catch {
        return undefined;
    }
    return (url) => shareUrlFor(url, env.MEDIA_BASE_URL, share) ?? url;
}

export type Found = MediaRow & { custom_title: string | null; post_key?: string | null };

// One <source> on the share page. `type` is the whole type attribute, codecs included when we know them.
export type PageSource = { url: string; type: string };

const SAFE_CODECS = /^[A-Za-z0-9.]{1,80}$/;

// video/mp4 for HEVC/AVC/AV1 (and a quicktime file, which is the same boxes); video/webm for VP9.
export function sourceType(mime: string, codecs?: string | null): string {
    const base = mime === "video/webm" ? "video/webm" : "video/mp4";
    return codecs && SAFE_CODECS.test(codecs) ? `${base}; codecs="${codecs}"` : base;
}

// The original's codecs string, remembered for a while so a page view does not re-read R2. Empty means
// "looked, and the header did not say" — a miss is not fetched again until the isolate drops it.
const codecCache = new Map<string, string>();
const CODEC_CACHE_MAX = 128;
const rememberCodec = (key: string, codecs: string) => {
    if (codecCache.has(key)) codecCache.delete(key);
    codecCache.set(key, codecs);
    while (codecCache.size > CODEC_CACHE_MAX) {
        const first = codecCache.keys().next().value;
        if (first === undefined) break;
        codecCache.delete(first);
    }
};

// The live public row whose public object is `<base>.<ext>` (or exactly `<base>.<ext>` when the link
// carries the extension). The public object is r2_key for a row in the public bucket, else public_key.
async function findPublic(db: D1Database, base: string, ext: string | undefined): Promise<Found | null> {
    // `<base>.` <= key < `<base>/` is every key that starts with `<base>.` ('/' sorts right after '.'),
    // an index range on both (bucket, r2_key) and public_key.
    const lo = ext ? `${base}.${ext}` : `${base}.`;
    const hi = ext ? lo : `${base}/`;
    const op = ext ? "<=" : "<";
    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    const { results } = await db
        .prepare(
            `SELECT ${cols}, ${POST_KEY_SQL} AS post_key, (SELECT t.title FROM media_titles t WHERE t.post_key = ${POST_KEY_SQL}) AS custom_title
               FROM media_items m
              WHERE m.deleted_at IS NULL${await notHiddenClause(db)}
                AND ((m.bucket = 'media' AND m.r2_key >= ?1 AND m.r2_key ${op} ?2)
                  OR (m.bucket = 'originals' AND m.public_key >= ?1 AND m.public_key ${op} ?2))
              ORDER BY m.created_at DESC
              LIMIT 5`,
        )
        .bind(lo, hi)
        .all<Found>();
    for (const r of results) {
        if (effectiveVisibility(r) !== "public") continue;
        const key = r.bucket === "media" ? r.r2_key : r.public_key;
        // the name must be exactly `<base>.<ext>`: no deeper keys (`<base>.x/y`), no posters' second dot
        if (key && /^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/.test(key)) return r;
    }
    return null;
}

const NOT_FOUND = () =>
    new Response("not found\n", {
        status: 404,
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=60" },
    });

const titleOf = (r: Found): string => {
    const t = (r.custom_title ?? "").trim() || (r.name ?? "").trim();
    // a bare file name says nothing: drop its extension
    return (t.replace(/\.[A-Za-z0-9]{1,8}$/, "") || "capystore").slice(0, 200);
};

const fmtDuration = (s: number): string => {
    const t = Math.max(0, Math.round(s));
    return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
};

// The page of one file: its Open Graph and Twitter card tags and a plain player. `fileUrl`, `poster` and `pageUrl` are
// where the page says the file, its poster and the page itself are: the media domain for a public file (section 22),
// share.../p/<key>/ for a private link (section 36).
export function singlePageHtml(p: {
    row: Found;
    type: string;
    fileUrl: string;
    poster: string | null;
    pageUrl: string;
    caption: Caption | null;
    // Public HDR alternates first, then the original with its codecs, then a plain video/mp4 catch-all.
    // Absent (a private link): one plain source for the file.
    sources?: PageSource[];
}): string {
    const { row, type, fileUrl, poster, pageUrl } = p;
    const isVideo = type.startsWith("video/");
    const isImage = type.startsWith("image/");
    // a title Harmony set wins; then the roast caption (section 25); then the file name
    const custom = (row.custom_title ?? "").trim() !== "";
    const caption = custom ? null : p.caption;
    const title = custom ? titleOf(row) : (caption?.title ?? titleOf(row));
    const w = row.width && row.width > 0 ? Math.round(row.width) : null;
    const h = row.height && row.height > 0 ? Math.round(row.height) : null;
    const desc = [caption?.description ?? "", isVideo && row.duration ? fmtDuration(row.duration) : ""].filter(Boolean).join(" · ");

    const e = escapeHtml;
    const meta: string[] = [
        `<meta property="og:site_name" content="capystore">`,
        `<meta property="og:title" content="${e(title)}">`,
        `<meta property="og:url" content="${e(pageUrl)}">`,
        `<meta name="twitter:title" content="${e(title)}">`,
        `<meta name="theme-color" content="#000000">`,
    ];
    if (desc) meta.push(`<meta property="og:description" content="${e(desc)}">`, `<meta name="twitter:description" content="${e(desc)}">`);
    if (isVideo) {
        meta.push(
            `<meta property="og:type" content="video.other">`,
            `<meta property="og:video" content="${e(fileUrl)}">`,
            `<meta property="og:video:url" content="${e(fileUrl)}">`,
            `<meta property="og:video:secure_url" content="${e(fileUrl)}">`,
            `<meta property="og:video:type" content="${e(type)}">`,
            ...(w && h ? [`<meta property="og:video:width" content="${w}">`, `<meta property="og:video:height" content="${h}">`] : []),
            `<meta name="twitter:card" content="player">`,
            `<meta name="twitter:player" content="${e(pageUrl)}">`,
            `<meta name="twitter:player:stream" content="${e(fileUrl)}">`,
            `<meta name="twitter:player:stream:content_type" content="${e(type)}">`,
            ...(w && h ? [`<meta name="twitter:player:width" content="${w}">`, `<meta name="twitter:player:height" content="${h}">`] : []),
        );
        if (poster) {
            meta.push(
                `<meta property="og:image" content="${e(poster)}">`,
                ...(w && h ? [`<meta property="og:image:width" content="${w}">`, `<meta property="og:image:height" content="${h}">`] : []),
                `<meta name="twitter:image" content="${e(poster)}">`,
            );
        }
    } else if (isImage) {
        meta.push(
            `<meta property="og:type" content="website">`,
            `<meta property="og:image" content="${e(fileUrl)}">`,
            `<meta property="og:image:secure_url" content="${e(fileUrl)}">`,
            `<meta property="og:image:type" content="${e(type)}">`,
            ...(w && h ? [`<meta property="og:image:width" content="${w}">`, `<meta property="og:image:height" content="${h}">`] : []),
            `<meta name="twitter:card" content="summary_large_image">`,
            `<meta name="twitter:image" content="${e(fileUrl)}">`,
        );
    } else {
        meta.push(`<meta property="og:type" content="website">`);
    }

    const sources = p.sources && p.sources.length > 0 ? p.sources : isVideo ? [{ url: fileUrl, type: sourceType(type) }] : [];
    const body = isVideo
        ? `<video${poster ? ` poster="${e(poster)}"` : ""} controls autoplay muted loop playsinline>${sources.map((s) => `<source src="${e(s.url)}" type='${s.type}'>`).join("")}</video>`
        : isImage
          ? `<img src="${e(fileUrl)}" alt="${e(title)}">`
          : `<a href="${e(fileUrl)}">${e(title)}</a>`;

    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${e(title)}</title>
<link rel="canonical" href="${e(pageUrl)}">
${meta.join("\n")}
<style>
html,body{margin:0;height:100%;background:#000;color:#ddd;font:15px -apple-system,system-ui,sans-serif}
main{display:flex;align-items:center;justify-content:center;height:100%}
video,img{max-width:100vw;max-height:100vh;display:block}
a{color:#ddd}
</style>
</head>
<body><main>${body}</main></body>
</html>
`;
}

// The headers of a link page: its files may come only from `fileOrigin` (the media domain, or the share host itself for
// a private link).
export const pageHeaders = (fileOrigin: string, cacheControl: string, extra: Record<string, string> = {}): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "cache-control": cacheControl,
    ...extra,
    "content-security-policy": `default-src 'none'; img-src ${fileOrigin}; media-src ${fileOrigin}; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`,
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "x-robots-tag": "noindex",
});

// The content type a page reports for a row (its own, else from the key's extension).
export const typeOf = (row: Pick<MediaRow, "content_type">, key: string): string =>
    (row.content_type || TYPES[extOf(key)] || "application/octet-stream").split(";")[0]!.trim().toLowerCase();

const codecsOf = (raw: string | null): string | undefined => {
    if (!raw) return undefined;
    try {
        const spec = JSON.parse(raw) as { codecs?: unknown };
        return typeof spec.codecs === "string" && SAFE_CODECS.test(spec.codecs) ? spec.codecs : undefined;
    } catch {
        return undefined;
    }
};

// Public HDR alternates of this post (newest first), then the original with its codecs when the header
// says, then a plain video/mp4 source so a browser that declines the codecs strings still plays it.
// og:video stays the original; this list is only the <video> element.
async function videoSources(d: ShareDeps, row: Found, fileUrl: string, type: string): Promise<PageSource[]> {
    const out: PageSource[] = [];
    const media = withSlash(d.mediaBaseUrl);
    if (row.post_key) {
        try {
            const { results } = await d.db
                .prepare(
                    `SELECT m.id, m.content_type, m.public_key, m.made_spec, m.visibility, m.bucket
                       FROM media_items m
                      WHERE m.deleted_at IS NULL AND m.role = 'alt' AND ${POST_KEY_SQL} = ?1
                      ORDER BY m.created_at DESC, m.id DESC`,
                )
                .bind(row.post_key)
                .all<{ id: string; content_type: string | null; public_key: string | null; made_spec: string | null; visibility: string | null; bucket: string }>();
            for (const a of results) {
                if (a.id === row.id || effectiveVisibility(a) !== "public" || !a.public_key) continue;
                if (!/^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/.test(a.public_key)) continue;
                const mime = (a.content_type || "video/mp4").split(";")[0]!.trim().toLowerCase();
                out.push({ url: `${media}${a.public_key}`, type: sourceType(mime, codecsOf(a.made_spec)) });
            }
        } catch (e) {
            console.error("[share] alt lookup failed", String(e));
        }
    }
    const mime = type.split(";")[0]!.trim().toLowerCase();
    if (mime === "video/mp4" || mime === "video/quicktime") {
        const codecs = await originalCodecs(d, row);
        if (codecs) out.push({ url: fileUrl, type: sourceType(mime, codecs) });
    }
    out.push({ url: fileUrl, type: sourceType(mime) });
    return out;
}

async function originalCodecs(d: ShareDeps, row: Found): Promise<string | undefined> {
    const cacheKey = `${row.bucket}\0${row.r2_key}`;
    const hit = codecCache.get(cacheKey);
    if (hit !== undefined) return hit || undefined;
    const bucket = row.bucket === "media" ? d.media : d.originals;
    if (!bucket) return undefined;
    try {
        const info = await readMp4Info(async (offset, length) => {
            const obj = await bucket.get(row.r2_key, { range: { offset, length } });
            if (!obj) return null;
            return { bytes: new Uint8Array(await new Response(obj.body).arrayBuffer()), size: obj.size };
        }, SHARE_CODEC_BYTES);
        const codecs = info?.codecs && SAFE_CODECS.test(info.codecs) ? info.codecs : "";
        rememberCodec(cacheKey, codecs);
        return codecs || undefined;
    } catch (e) {
        console.error("[share] codec probe failed", row.id, String(e));
        return undefined;
    }
}

// One page per public file. HEAD gets the same headers.
export async function sharePage(d: ShareDeps, request: Request): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
    }
    const url = new URL(request.url);
    const media = withSlash(d.mediaBaseUrl);
    if (url.pathname === "/" || url.pathname === "") return NOT_FOUND();
    // private links (section 36): /p/<key> and its files
    if (url.pathname === "/p" || url.pathname.startsWith("/p/")) return privateRoute(d, request);
    // shared chats (section 46): /c/<key>, its JSON and its files
    if (url.pathname === "/c" || url.pathname.startsWith("/c/")) return chatShareRoute(d, request);
    // gallery share links (section 24): /g/<id>, the Mastodon status Discord reads, its oEmbed
    const set = await shareSetRoute({ ...d, now: () => Date.now() }, request);
    if (set) return set;
    if (url.pathname === "/robots.txt") {
        // Link unfurlers fetch pages, they do not crawl; search engines may not index the pages.
        return new Response("User-agent: *\nDisallow: /\n", { headers: { "content-type": "text/plain" } });
    }
    const m = SHARE_PATH.exec(url.pathname);
    if (!m) return NOT_FOUND();

    let row: Found | null;
    try {
        row = await findPublic(d.db, m[1], m[2]?.toLowerCase());
    } catch {
        return new Response("try again\n", { status: 503, headers: { "content-type": "text/plain", "retry-after": "5" } });
    }
    if (!row) return NOT_FOUND();

    const key = (row.bucket === "media" ? row.r2_key : row.public_key)!;
    const fileUrl = `${media}${key}`;
    const pageUrl = `${withSlash(d.shareBaseUrl)}${m[1]}`;
    // a poster only from the public media domain (the column is written by this server, but be strict)
    const poster = row.poster && row.poster.startsWith(media) ? row.poster : null;
    const custom = (row.custom_title ?? "").trim() !== "";
    const caption = custom ? null : await captionNow(d, row, fileUrl);
    const type = typeOf(row, key);
    const sources = type.startsWith("video/") ? await videoSources(d, row, fileUrl, type) : undefined;
    const html = singlePageHtml({ row, type, fileUrl, poster, pageUrl, caption, sources });
    return new Response(request.method === "HEAD" ? null : html, {
        // short: a file made private stops having a page within a minute
        headers: pageHeaders(new URL(media).origin, "public, max-age=60"),
    });
}
