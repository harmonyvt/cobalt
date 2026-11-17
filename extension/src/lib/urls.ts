// Canonical post URLs for the four sites. The button saves this, never the page URL of a feed.
// Shapes follow api/src/processing/service-config.js and url.js: what POST /studio can actually fetch.

const X_HOSTS = new Set(["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "m.twitter.com"]);

export function canonicalX(href: string, base: string): string | null {
    const u = parse(href, base);
    if (!u || !X_HOSTS.has(u.hostname)) return null;
    const m = u.pathname.match(/^\/([^/]+)\/status\/(\d+)/);
    if (!m || m[1] === "i") return null;
    return `https://x.com/${m[1]}/status/${m[2]}`;
}

export function canonicalYouTube(href: string, base: string): string | null {
    const u = parse(href, base);
    if (!u) return null;
    if (u.hostname === "youtu.be") {
        const id = u.pathname.split("/").filter(Boolean)[0] ?? "";
        return videoId(id) ? `https://www.youtube.com/watch?v=${id}` : null;
    }
    if (!/(^|\.)youtube\.com$/.test(u.hostname) && u.hostname !== "www.youtube-nocookie.com" && u.hostname !== "youtube-nocookie.com") return null;
    const shorts = u.pathname.match(/^\/shorts\/([^/?#]+)/);
    if (shorts && videoId(shorts[1]!)) return `https://www.youtube.com/shorts/${shorts[1]}`;
    const live = u.pathname.match(/^\/live\/([^/?#]+)/);
    if (live && videoId(live[1]!)) return `https://www.youtube.com/watch?v=${live[1]}`;
    const pathId = u.pathname.match(/^\/(?:embed|v)\/([^/?#]+)/);
    const id = u.searchParams.get("v") || pathId?.[1] || "";
    return videoId(id) ? `https://www.youtube.com/watch?v=${id}` : null;
}

export function canonicalTwitch(href: string, base: string): string | null {
    const u = parse(href, base);
    if (!u) return null;
    if (u.hostname === "clips.twitch.tv") {
        const slug = u.pathname.split("/").filter(Boolean)[0] ?? "";
        return clipSlug(slug) ? `https://clips.twitch.tv/${slug}` : null;
    }
    if (u.hostname !== "twitch.tv" && u.hostname !== "www.twitch.tv" && u.hostname !== "m.twitch.tv") return null;
    const m = u.pathname.match(/^\/([^/]+)\/clip\/([^/?#]+)/);
    if (!m || !clipSlug(m[2]!)) return null;
    if (m[1] === "_") return `https://clips.twitch.tv/${m[2]}`;
    return `https://www.twitch.tv/${m[1]}/clip/${m[2]}`;
}

export function canonicalInstagram(href: string, base: string): string | null {
    const u = parse(href, base);
    if (!u || u.hostname !== "www.instagram.com" && u.hostname !== "instagram.com") return null;
    const parts = u.pathname.split("/").filter(Boolean);
    const kinds = new Set(["p", "reel", "reels", "tv"]);
    let kind = "";
    let id = "";
    if (parts.length >= 2 && kinds.has(parts[0]!)) {
        kind = parts[0]!;
        id = parts[1]!;
    } else if (parts.length >= 3 && kinds.has(parts[1]!)) {
        kind = parts[1]!;
        id = parts[2]!;
    }
    if (!kind || !/^[\w-]+$/.test(id)) return null;
    const canon = kind === "reels" || kind === "tv" ? "reel" : kind;
    return `https://www.instagram.com/${canon}/${id}/`;
}

function parse(href: string, base: string): URL | null {
    try {
        return new URL(href, base);
    } catch {
        return null;
    }
}

function videoId(id: string): boolean {
    return /^[\w-]{11}$/.test(id);
}

function clipSlug(slug: string): boolean {
    return /^[\w-]{1,100}$/.test(slug);
}
