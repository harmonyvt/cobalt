// Rich link previews for public media (APP-API-CONTRACT.md section 22): the fixupx idea. A public file
// at https://media.../<name>.<ext> also has a share page at https://<share host>/<name>, an HTML page
// whose Open Graph and Twitter card tags point at the file, so a pasted link unfurls as a playable
// video or a full-size image in Discord, iMessage, X, Telegram, Slack and the like. People who open it
// get the same file on a plain page. Only files that are public right now have a page; a private,
// deleted or unknown name is a 404 that says nothing about which. Runs in the Worker (D1 only), the
// container is never involved. Free of Cloudflare imports so it runs under plain node in the tests.

import { POST_KEY_SQL } from "./app-routes";
import { ITEM_COLUMNS, effectiveVisibility, extOf, type MediaRow } from "./visibility";

export type ShareDeps = {
    db: D1Database;
    // https://media.../ (with or without the slash)
    mediaBaseUrl: string;
    // https://<share host>/ (with or without the slash)
    shareBaseUrl: string;
};

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

type Found = MediaRow & { custom_title: string | null };

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
            `SELECT ${cols}, (SELECT t.title FROM media_titles t WHERE t.post_key = ${POST_KEY_SQL}) AS custom_title
               FROM media_items m
              WHERE m.deleted_at IS NULL
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
    return (t.replace(/\.[A-Za-z0-9]{1,8}$/, "") || "cobalt").slice(0, 200);
};

const fmtDuration = (s: number): string => {
    const t = Math.max(0, Math.round(s));
    return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
};

// One page per public file. HEAD gets the same headers.
export async function sharePage(d: ShareDeps, request: Request): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
    }
    const url = new URL(request.url);
    const media = withSlash(d.mediaBaseUrl);
    if (url.pathname === "/" || url.pathname === "") return NOT_FOUND();
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
    const type = (row.content_type || TYPES[extOf(key)] || "application/octet-stream").split(";")[0].trim().toLowerCase();
    const isVideo = type.startsWith("video/");
    const isImage = type.startsWith("image/");
    // a poster only from the public media domain (the column is written by this server, but be strict)
    const poster = row.poster && row.poster.startsWith(media) ? row.poster : null;
    const title = titleOf(row);
    const w = row.width && row.width > 0 ? Math.round(row.width) : null;
    const h = row.height && row.height > 0 ? Math.round(row.height) : null;
    const desc = isVideo && row.duration ? fmtDuration(row.duration) : "";

    const e = escapeHtml;
    const meta: string[] = [
        `<meta property="og:site_name" content="cobalt">`,
        `<meta property="og:title" content="${e(title)}">`,
        `<meta property="og:url" content="${e(pageUrl)}">`,
        `<meta name="twitter:title" content="${e(title)}">`,
        `<meta name="theme-color" content="#000000">`,
    ];
    if (desc) meta.push(`<meta property="og:description" content="${e(desc)}">`);
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

    const body = isVideo
        ? `<video src="${e(fileUrl)}"${poster ? ` poster="${e(poster)}"` : ""} controls autoplay muted loop playsinline></video>`
        : isImage
          ? `<img src="${e(fileUrl)}" alt="${e(title)}">`
          : `<a href="${e(fileUrl)}">${e(title)}</a>`;

    const html = `<!doctype html>
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
    const mediaOrigin = new URL(media).origin;
    return new Response(request.method === "HEAD" ? null : html, {
        headers: {
            "content-type": "text/html; charset=utf-8",
            // short: a file made private stops having a page within a minute
            "cache-control": "public, max-age=60",
            "content-security-policy": `default-src 'none'; img-src ${mediaOrigin}; media-src ${mediaOrigin}; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`,
            "x-content-type-options": "nosniff",
            "referrer-policy": "no-referrer",
            "x-robots-tag": "noindex",
        },
    });
}
