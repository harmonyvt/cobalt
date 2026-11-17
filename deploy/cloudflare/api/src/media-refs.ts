// Media refs (APP-API-CONTRACT.md section 62.1): one way to name a picture or video anywhere in capystore, whatever a swarm,
// the chat or the MCP is working on. A media ref is any of:
//  - a capystore ref (section 60: a post key, a file id, a media/share/gallery link, a saved page's URL)
//  - a 7TV emote: its id, a 7tv.app/emotes/<id> link or a cdn.7tv.app/emote/<id>/... URL
//  - any other https image or video URL on the media allowlist (MEDIA_HOSTS, comma separated hosts)
// `resolveMedia` turns a list into previews in one batch: capystore refs through resolveRefs (one D1 round trip or two, then
// the posts' public pictures), emotes as their CDN picture, URLs as given after the host check. Nothing is fetched to
// resolve. Free of Cloudflare imports: the tests run it under node.
import { loadPosts } from "./chat-tools";
import { PLAIN_ID, looksLikeRef, resolveRefs, type RefBases } from "./refs";

export const MEDIA_HOSTS_DEFAULT = "cdn.7tv.app,media.capybaraharmony.com,share.capybaraharmony.com";
export const MEDIA_REFS_MAX = 200;

export type MediaKind = "post" | "file" | "emote" | "image" | "video";
export type MediaRef = { ref: string; kind: MediaKind; preview_url: string | null; open_url: string | null; title?: string; animated?: boolean };
export type MediaRefError = { ref: string; error: string };
export type MediaAnswer = MediaRef | MediaRefError;
export const isMedia = (a: MediaAnswer): a is MediaRef => !("error" in a);

export type MediaBases = RefBases & { hosts: string[] };

// The allowlist: the MEDIA_HOSTS var, else the default, always with the house media and share hosts.
export function mediaHostsOf(env: { MEDIA_HOSTS?: string }, bases?: RefBases): string[] {
    const list = (env.MEDIA_HOSTS?.trim() ? env.MEDIA_HOSTS : MEDIA_HOSTS_DEFAULT)
        .split(",")
        .map((h) => h.trim().toLowerCase())
        .filter((h) => /^[a-z0-9.-]+$/.test(h));
    for (const u of [bases?.mediaBaseUrl, bases?.shareBaseUrl]) {
        try {
            if (u) list.push(new URL(u).hostname.toLowerCase());
        } catch {
            // not a URL: nothing to add
        }
    }
    return [...new Set(list)];
}

// A 7TV emote id: a ULID (26, upper case) or an old ObjectId (24 hex).
export const EMOTE_ID = /^(?:[0-9A-Z]{26}|[0-9a-f]{24})$/;
const SEVENTV_SITE = new Set(["7tv.app", "www.7tv.app", "old.7tv.app"]);
const VIDEO_EXT = /\.(?:mp4|m4v|mov|webm|mkv)$/i;
const IMAGE_EXT = /\.(?:webp|avif|gif|png|jpe?g)$/i;

export const emotePreview = (id: string) => `https://cdn.7tv.app/emote/${id}/2x.webp`;
export const emotePage = (id: string) => `https://7tv.app/emotes/${id}`;

const clean = (raw: string) =>
    raw
        .trim()
        .replace(/^[<"'`(\[]+|[>"'`)\].,;]+$/g, "")
        .trim();

export type MediaParse =
    | { kind: "emote"; id: string }
    | { kind: "url"; url: string; media: "image" | "video" }
    | { kind: "capystore"; ref: string }
    | { kind: "refused"; error: string };

function asUrl(s: string): URL | null {
    const u = /^https?:\/\//i.test(s) ? s : /^[a-z0-9.-]+\.[a-z]{2,}\/\S/i.test(s) ? `https://${s}` : null;
    if (!u) return null;
    try {
        return new URL(u);
    } catch {
        return null;
    }
}

// What kind of media ref a string is (no lookups), or null when it is not one at all (plain words, a number).
export function parseMediaRef(raw: unknown, bases: MediaBases): MediaParse | null {
    if (typeof raw !== "string") return null;
    const s = clean(raw);
    if (s.length === 0 || s.length > 2048) return null;
    if (EMOTE_ID.test(s)) return { kind: "emote", id: s };
    const url = asUrl(s);
    if (url) {
        const host = url.hostname.toLowerCase();
        const parts = url.pathname.split("/").filter(Boolean);
        if (SEVENTV_SITE.has(host) && parts[0] === "emotes" && parts[1] && EMOTE_ID.test(parts[1])) return { kind: "emote", id: parts[1] };
        if (host === "cdn.7tv.app" && parts[0] === "emote" && parts[1] && EMOTE_ID.test(parts[1])) return { kind: "emote", id: parts[1] };
        const media = hostOf(bases.mediaBaseUrl);
        const share = hostOf(bases.shareBaseUrl);
        // the house hosts are capystore refs (a public file, a share or gallery link)
        if (host === media || host === share || (media === null && host.startsWith("media.")) || (share === null && host.startsWith("share."))) return { kind: "capystore", ref: s };
        if (url.protocol !== "https:") return { kind: "refused", error: "error.media.not_https" };
        if (!bases.hosts.includes(host)) return { kind: "refused", error: "error.media.host_not_allowed" };
        return { kind: "url", url: url.toString(), media: VIDEO_EXT.test(url.pathname) ? "video" : "image" };
    }
    // a post key, a file id or a public file name
    if (PLAIN_ID.test(s) || looksLikeRef(s)) return { kind: "capystore", ref: s };
    return null;
}

const hostOf = (u: string | undefined) => {
    try {
        return u ? new URL(u).hostname.toLowerCase() : null;
    } catch {
        return null;
    }
};

// Every ref resolved, in order (duplicates answered once each). Capystore refs need the library (`db`); the rest do not.
export async function resolveMedia(db: D1Database, refs: string[], bases: MediaBases): Promise<MediaAnswer[]> {
    const list = refs.slice(0, MEDIA_REFS_MAX);
    const parsed = list.map((r) => ({ ref: r, p: parseMediaRef(r, bases) }));
    const capy = [...new Set(parsed.flatMap((x) => (x.p?.kind === "capystore" ? [x.p.ref] : [])))];
    const found = capy.length > 0 ? await resolveRefs(db, capy, bases).catch(() => new Map()) : new Map();
    const postIds = [...new Set([...found.values()].flatMap((f) => (f && !f.gone ? f.posts.slice(0, 1) : [])))];
    const posts = postIds.length > 0 ? new Map((await loadPosts({ db, mediaBaseUrl: bases.mediaBaseUrl }, postIds).catch(() => [])).map((p) => [p.record.id, p])) : new Map();
    return parsed.map(({ ref, p }): MediaAnswer => {
        if (!p) return { ref, error: "error.media.not_a_ref" };
        if (p.kind === "refused") return { ref, error: p.error };
        if (p.kind === "emote") return { ref, kind: "emote", preview_url: emotePreview(p.id), open_url: emotePage(p.id) };
        if (p.kind === "url") return { ref, kind: p.media, preview_url: p.media === "image" || IMAGE_EXT.test(p.url) ? p.url : null, open_url: p.url };
        const r = found.get(p.ref);
        if (!r || r.gone || r.posts.length === 0) return { ref, error: r?.gone ? "error.media.deleted" : "error.media.not_found" };
        const post = posts.get(r.posts[0]!);
        if (!post) return { ref, error: "error.media.not_found" };
        const lead = post.lead as { url?: string | null };
        const pub = post.record.public && typeof lead.url === "string" ? lead.url : null;
        return {
            ref,
            kind: r.file ? "file" : "post",
            preview_url: post.picture,
            open_url: pub,
            ...(post.record.title ? { title: post.record.title } : {}),
            ...(post.record.kind === "video" ? { animated: true } : {}),
        };
    });
}

// For the board's guesser and look: the capystore post ids behind some refs (one batch).
export async function mediaPosts(db: D1Database, refs: string[], bases: MediaBases): Promise<Map<string, string>> {
    const capy = [...new Set(refs.flatMap((r) => (parseMediaRef(r, bases)?.kind === "capystore" ? [clean(r)] : [])))];
    if (capy.length === 0) return new Map();
    const found = await resolveRefs(db, capy, bases).catch(() => new Map());
    const out = new Map<string, string>();
    for (const r of refs) {
        const f = found.get(clean(r));
        if (f && !f.gone && f.posts[0]) out.set(r, f.posts[0]);
    }
    return out;
}

