// Post details for post frames (APP-API-CONTRACT.md section 52.1): who posted a saved video, when, what they wrote, the
// counts and the avatar, looked up from X's public embed lookup, yt-dlp's info, Twitch's API and a page's Open Graph tags,
// and kept in D1 `post_details` (migration 0036), one row per source link. No Cloudflare imports; every network call is
// injected and raced against its own timeout.
import type { OriginalsBucket } from "./studio";

export const POST_SITES = ["x", "instagram", "twitch", "youtube", "generic"] as const;
export type PostSite = (typeof POST_SITES)[number];

export const LOOKUP_MS = 8_000;
// yt-dlp's box may have to wake first
export const YTDLP_INFO_MS = 45_000;
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024;
// a row whose lookup found nothing is tried again on its own after this long
export const RETRY_NOTHING_MS = 24 * 3600 * 1000;
export const FIELD_MAX = 2000;
export const TEXT_MAX = 4000;

export type Counts = { likes?: number; reposts?: number; replies?: number; views?: number; comments?: number; subscribers?: number };

export type DetailsRow = {
    link: string;
    site: PostSite;
    found: number;
    name: string | null;
    handle: string | null;
    text: string | null;
    title: string | null;
    channel: string | null;
    game: string | null;
    clipper: string | null;
    site_name: string | null;
    posted_at: number | null;
    counts: string | null;
    verified: number;
    avatar_key: string | null;
    fetched_at: number;
    edited_at: number | null;
};

// What the routes answer (52.2).
export type PostDetails = {
    link: string;
    site: PostSite;
    found: boolean;
    name: string | null;
    handle: string | null;
    text: string | null;
    title: string | null;
    channel: string | null;
    game: string | null;
    clipper: string | null;
    site_name: string | null;
    posted_at: number | null;
    counts: Counts;
    verified: boolean;
    avatar_url: string | null;
    edited: boolean;
};

// The subset of yt-dlp's info (ytdlp/server.mjs, 49.6 + 52.1) read here.
export type YtInfo = {
    title?: string | null;
    uploader?: string | null;
    uploader_id?: string | null;
    channel?: string | null;
    channel_url?: string | null;
    creator?: string | null;
    extractor?: string | null;
    upload_date?: string | null;
    timestamp?: number | null;
    view_count?: number | null;
    like_count?: number | null;
    comment_count?: number | null;
    repost_count?: number | null;
    channel_follower_count?: number | null;
    description?: string | null;
};

export type LookupDeps = {
    db: D1Database;
    originals: Pick<OriginalsBucket, "put" | "get">;
    fetch: (input: string, init?: RequestInit) => Promise<Response>;
    // null while yt-dlp is off
    ytdlpInfo: ((url: string) => Promise<YtInfo | null>) | null;
    twitch: { clientId: string; clientSecret: string } | null;
    now: () => number;
};

// ---- sites -------------------------------------------------------------------------------------------------------------

const HOSTS: Record<string, PostSite> = {
    "x.com": "x",
    "twitter.com": "x",
    "mobile.twitter.com": "x",
    "fxtwitter.com": "x",
    "vxtwitter.com": "x",
    "fixupx.com": "x",
    "instagram.com": "instagram",
    "twitch.tv": "twitch",
    "clips.twitch.tv": "twitch",
    "m.twitch.tv": "twitch",
    "youtube.com": "youtube",
    "m.youtube.com": "youtube",
    "music.youtube.com": "youtube",
    "youtu.be": "youtube",
};

/** The style a link gets (52.4) and its host (without www.). */
export function siteOf(link: string | null | undefined): { site: PostSite; host: string | null } {
    let host: string | null = null;
    try {
        host = new URL(String(link ?? "")).hostname.toLowerCase().replace(/^www\./, "");
    } catch {
        return { site: "generic", host: null };
    }
    return { site: HOSTS[host] ?? "generic", host };
}

/** The post id of an X link (`/<user>/status/<id>`), else null. */
export function xStatusId(link: string): string | null {
    try {
        const m = /\/status(?:es)?\/(\d{5,25})/.exec(new URL(link).pathname);
        return m ? m[1]! : null;
    } catch {
        return null;
    }
}

/** X's embed lookup token for a post id (the one its embeds compute). */
export function xToken(id: string): string {
    return ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
}

/** A Twitch link's clip slug or VOD id. */
export function twitchRef(link: string): { clip: string } | { video: string } | null {
    try {
        const u = new URL(link);
        const host = u.hostname.toLowerCase().replace(/^www\./, "");
        const parts = u.pathname.split("/").filter(Boolean);
        if (host === "clips.twitch.tv" && parts[0] && parts[0] !== "embed") return { clip: parts[0] };
        if (host === "clips.twitch.tv" && parts[0] === "embed") return u.searchParams.get("clip") ? { clip: u.searchParams.get("clip")! } : null;
        const ci = parts.indexOf("clip");
        if (ci >= 0 && parts[ci + 1]) return { clip: parts[ci + 1]! };
        if (parts[0] === "videos" && /^\d+$/.test(parts[1] ?? "")) return { video: parts[1]! };
        return null;
    } catch {
        return null;
    }
}

// ---- parsing (pure) ----------------------------------------------------------------------------------------------------

const str = (v: unknown, max = FIELD_MAX): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);

type Found = Partial<Omit<DetailsRow, "link" | "site" | "found" | "fetched_at" | "edited_at" | "counts" | "avatar_key" | "verified">> & {
    counts?: Counts;
    verified?: boolean;
    avatar?: string | null;
};

/** X's embed lookup answer -> details. The media's trailing t.co link is cut off the text. */
export function parseXEmbed(j: any): Found | null {
    if (!j || typeof j !== "object" || !j.user) return null;
    let text: string | null = typeof j.text === "string" ? j.text : null;
    if (text !== null) text = text.replace(/\s*https:\/\/t\.co\/\w+\s*$/, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
    const posted = typeof j.created_at === "string" ? Date.parse(j.created_at) : NaN;
    const avatar = str(j.user.profile_image_url_https, 2048);
    return {
        name: str(j.user.name),
        handle: str(j.user.screen_name) ? `@${str(j.user.screen_name)}` : null,
        text: str(text, TEXT_MAX),
        posted_at: Number.isFinite(posted) ? posted : null,
        counts: { likes: num(j.favorite_count), replies: num(j.conversation_count) },
        verified: j.user.is_blue_verified === true || j.user.verified === true,
        avatar: avatar ? avatar.replace(/_normal(\.\w+)$/, "_400x400$1") : null,
    };
}

const ytDate = (s: unknown): number | null => {
    const m = typeof s === "string" ? /^(\d{4})(\d{2})(\d{2})$/.exec(s) : null;
    return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
};

/** yt-dlp's info -> details, per site (each extractor fills the fields its own way). */
export function parseYtInfo(site: PostSite, i: YtInfo | null): Found | null {
    if (!i) return null;
    const posted = typeof i.timestamp === "number" && Number.isFinite(i.timestamp) ? i.timestamp * 1000 : ytDate(i.upload_date);
    const counts: Counts = {
        likes: num(i.like_count),
        views: num(i.view_count),
        comments: num(i.comment_count),
        reposts: num(i.repost_count),
        subscribers: num(i.channel_follower_count),
    };
    const at = (s: string | null) => (s ? (s.startsWith("@") ? s : `@${s}`) : null);
    if (site === "x") {
        return { name: str(i.uploader), handle: at(str(i.uploader_id)), text: str(i.description, TEXT_MAX), posted_at: posted, counts: { ...counts, replies: counts.comments, comments: undefined } };
    }
    if (site === "instagram") {
        // channel = the username, uploader = the full name
        return { name: str(i.uploader), handle: str(i.channel) ?? str(i.uploader_id), text: str(i.description, TEXT_MAX), posted_at: posted, counts };
    }
    if (site === "twitch") {
        const channel = str(i.uploader) ?? str(i.channel);
        const clipper = str(i.creator);
        return { name: channel, handle: str(i.uploader_id), title: str(i.title), clipper: clipper && clipper !== channel ? clipper : null, posted_at: posted, counts: { views: counts.views } };
    }
    if (site === "youtube") {
        const id = str(i.uploader_id);
        return { channel: str(i.channel) ?? str(i.uploader), name: str(i.uploader), handle: id && id.startsWith("@") ? id : null, title: str(i.title), text: str(i.description, TEXT_MAX), posted_at: posted, counts };
    }
    return { name: str(i.uploader) ?? str(i.channel), title: str(i.title), text: str(i.description, TEXT_MAX), site_name: str(i.extractor, 80), posted_at: posted, counts };
}

const decodeEntities = (s: string) =>
    s.replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

/** The page's Open Graph (and twitter:) tags, from its first 512 KB of HTML. */
export function parseOpenGraph(html: string): Record<string, string> {
    const out: Record<string, string> = {};
    const re = /<meta\s+[^>]*?(?:property|name)\s*=\s*["']((?:og|twitter|article):[a-z_:]+)["'][^>]*?content\s*=\s*["']([^"']*)["'][^>]*>|<meta\s+[^>]*?content\s*=\s*["']([^"']*)["'][^>]*?(?:property|name)\s*=\s*["']((?:og|twitter|article):[a-z_:]+)["'][^>]*>/gi;
    for (const m of html.slice(0, 512 * 1024).matchAll(re)) {
        const key = (m[1] ?? m[4] ?? "").toLowerCase();
        const val = decodeEntities(m[2] ?? m[3] ?? "").trim();
        if (key && val && !(key in out)) out[key] = val;
    }
    return out;
}

/** Fills what `base` lacks from `more` (counts key by key). */
export function merge(base: Found, more: Found | null): Found {
    if (!more) return base;
    const out: Found = { ...base };
    for (const [k, v] of Object.entries(more) as [keyof Found, unknown][]) {
        if (k === "counts") continue;
        if ((out[k] === undefined || out[k] === null) && v !== undefined && v !== null) (out as any)[k] = v;
    }
    const counts: Counts = { ...(more.counts ?? {}) };
    for (const [k, v] of Object.entries(base.counts ?? {})) if (v !== undefined) (counts as any)[k] = v;
    out.counts = counts;
    if (base.verified === undefined && more.verified !== undefined) out.verified = more.verified;
    return out;
}

const hasAny = (f: Found) =>
    !!(f.name || f.handle || f.text || f.title || f.channel || f.posted_at || Object.values(f.counts ?? {}).some((v) => v !== undefined));

// ---- network -----------------------------------------------------------------------------------------------------------

async function race<T>(p: Promise<T>, ms: number): Promise<T | null> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
        return await Promise.race([p, new Promise<null>((r) => (timer = setTimeout(() => r(null), ms)))]);
    } catch {
        return null;
    } finally {
        clearTimeout(timer);
    }
}

const UA = "Mozilla/5.0 (compatible; capystore/1.0; +https://cobalt.capybaraharmony.com)";

async function getJson(d: LookupDeps, url: string, init: RequestInit = {}): Promise<any | null> {
    return race(
        (async () => {
            const res = await d.fetch(url, { ...init, headers: { "user-agent": UA, accept: "application/json", ...(init.headers ?? {}) } });
            if (!res.ok) {
                await res.body?.cancel().catch(() => {});
                return null;
            }
            return await res.json().catch(() => null);
        })(),
        LOOKUP_MS,
    );
}

async function getHtml(d: LookupDeps, url: string): Promise<string | null> {
    return race(
        (async () => {
            const res = await d.fetch(url, { headers: { "user-agent": UA, accept: "text/html", "accept-language": "en" }, redirect: "follow" });
            const type = res.headers.get("content-type") ?? "";
            if (!res.ok || !type.includes("html")) {
                await res.body?.cancel().catch(() => {});
                return null;
            }
            // the head is enough: read at most 512 KB
            const reader = res.body?.getReader();
            if (!reader) return null;
            const parts: Uint8Array[] = [];
            let got = 0;
            while (got < 512 * 1024) {
                const { done, value } = await reader.read();
                if (done || !value) break;
                parts.push(value);
                got += value.byteLength;
            }
            await reader.cancel().catch(() => {});
            const all = new Uint8Array(got);
            let o = 0;
            for (const p of parts) {
                all.set(p.subarray(0, Math.min(p.byteLength, got - o)), o);
                o += p.byteLength;
            }
            return new TextDecoder().decode(all);
        })(),
        LOOKUP_MS,
    );
}

async function sha256Hex(s: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Copies an avatar into cobalt-originals; its key, or null. */
async function storeAvatar(d: LookupDeps, url: string | null | undefined): Promise<string | null> {
    if (!url || !/^https:\/\//i.test(url)) return null;
    const key = `post-avatars/${await sha256Hex(url)}`;
    const bytes = await race(
        (async () => {
            const res = await d.fetch(url, { headers: { "user-agent": UA, accept: "image/*" } });
            const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
            if (!res.ok || !/^image\/(jpeg|png|webp|gif)$/.test(type)) {
                await res.body?.cancel().catch(() => {});
                return null;
            }
            const b = new Uint8Array(await res.arrayBuffer());
            return b.byteLength > 0 && b.byteLength <= AVATAR_MAX_BYTES ? { b, type } : null;
        })(),
        LOOKUP_MS,
    );
    if (!bytes) return null;
    try {
        await d.originals.put(key, bytes.b, { httpMetadata: { contentType: bytes.type }, customMetadata: { kind: "post-avatar" } });
        return key;
    } catch {
        return null;
    }
}

async function twitchLookup(d: LookupDeps, link: string): Promise<Found | null> {
    const t = d.twitch;
    const ref = twitchRef(link);
    if (!t || !ref) return null;
    const tok = await getJson(d, "https://id.twitch.tv/oauth2/token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: t.clientId, client_secret: t.clientSecret, grant_type: "client_credentials" }).toString(),
    });
    if (!tok || typeof tok.access_token !== "string") return null;
    const helix = (path: string) => getJson(d, `https://api.twitch.tv/helix/${path}`, { headers: { "client-id": t.clientId, authorization: `Bearer ${tok.access_token}` } });
    let userId: string | null = null;
    let gameId: string | null = null;
    let found: Found = {};
    if ("clip" in ref) {
        const c = (await helix(`clips?id=${encodeURIComponent(ref.clip)}`))?.data?.[0];
        if (!c) return null;
        userId = str(c.broadcaster_id);
        gameId = str(c.game_id);
        const posted = Date.parse(String(c.created_at ?? ""));
        found = { name: str(c.broadcaster_name), title: str(c.title), clipper: str(c.creator_name), posted_at: Number.isFinite(posted) ? posted : null, counts: { views: num(c.view_count) } };
    } else {
        const v = (await helix(`videos?id=${encodeURIComponent(ref.video)}`))?.data?.[0];
        if (!v) return null;
        userId = str(v.user_id);
        const posted = Date.parse(String(v.created_at ?? ""));
        found = { name: str(v.user_name), handle: str(v.user_login), title: str(v.title), posted_at: Number.isFinite(posted) ? posted : null, counts: { views: num(v.view_count) } };
    }
    const [u, g] = await Promise.all([
        userId ? helix(`users?id=${encodeURIComponent(userId)}`) : null,
        gameId ? helix(`games?id=${encodeURIComponent(gameId)}`) : null,
    ]);
    const user = u?.data?.[0];
    if (user) {
        found.handle = found.handle ?? str(user.login);
        found.avatar = str(user.profile_image_url, 2048);
    }
    const game = g?.data?.[0];
    if (game) found.game = str(game.name);
    return found;
}

/** Looks a link up everywhere it can (52.1). Never throws. */
export async function lookupDetails(d: LookupDeps, link: string): Promise<{ site: PostSite; found: Found; any: boolean; yt: YtInfo | null }> {
    const { site } = siteOf(link);
    let found: Found = {};
    let yt: YtInfo | null = null;
    if (site === "x") {
        const id = xStatusId(link);
        if (id) found = merge(found, parseXEmbed(await getJson(d, `https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=en&token=${xToken(id)}`)));
    }
    if (site === "twitch") found = merge(found, await twitchLookup(d, link));
    // yt-dlp for what is still missing (always for the sites the first lookups do not cover)
    const needYt = site !== "x" || !found.name || found.counts?.views === undefined;
    if (needYt && d.ytdlpInfo) {
        yt = await race(d.ytdlpInfo(link), YTDLP_INFO_MS);
        found = merge(found, parseYtInfo(site, yt));
    }
    if (site === "generic" && !hasAny(found)) {
        const html = await getHtml(d, link);
        if (html) {
            const og = parseOpenGraph(html);
            found = merge(found, {
                title: str(og["og:title"] ?? og["twitter:title"]),
                text: str(og["og:description"] ?? og["twitter:description"], TEXT_MAX),
                site_name: str(og["og:site_name"], 80),
                name: str(og["article:author"]) && !/^https?:/.test(og["article:author"]!) ? str(og["article:author"]) : null,
            });
        }
    }
    return { site, found, any: hasAny(found), yt };
}

/** The YouTube channel's avatar: its page's og:image. */
async function youtubeAvatar(d: LookupDeps, channelUrl: string | null | undefined): Promise<string | null> {
    if (!channelUrl || !/^https:\/\/(www\.)?youtube\.com\//.test(channelUrl)) return null;
    const html = await getHtml(d, channelUrl);
    return html ? (parseOpenGraph(html)["og:image"] ?? null) : null;
}

// ---- storage -----------------------------------------------------------------------------------------------------------

export const DETAILS_COLUMNS =
    "link, site, found, name, handle, text, title, channel, game, clipper, site_name, posted_at, counts, verified, avatar_key, fetched_at, edited_at";

export async function readDetails(db: D1Database, link: string): Promise<DetailsRow | null> {
    return await db.prepare(`SELECT ${DETAILS_COLUMNS} FROM post_details WHERE link = ?1`).bind(link).first<DetailsRow>();
}

const cleanCounts = (c: Counts | undefined): string | null => {
    const o: Counts = {};
    for (const [k, v] of Object.entries(c ?? {})) if (typeof v === "number" && Number.isFinite(v)) (o as any)[k] = v;
    return Object.keys(o).length ? JSON.stringify(o) : null;
};

/**
 * Looks a link up and writes its row. A row Harmony edited keeps every field that is not NULL (a refresh fills the rest).
 */
export async function refreshDetails(d: LookupDeps, link: string): Promise<DetailsRow> {
    const r = await lookupDetails(d, link);
    let avatarUrl = r.found.avatar ?? null;
    // a YouTube channel's avatar is its page's preview picture
    if (r.site === "youtube" && !avatarUrl) avatarUrl = await youtubeAvatar(d, r.yt?.channel_url ?? null);
    const avatarKey = await storeAvatar(d, avatarUrl);
    const now = d.now();
    const old = await readDetails(d.db, link);
    const f = r.found;
    const keep = (k: keyof DetailsRow, v: unknown) => (old && old.edited_at !== null && old[k] !== null ? old[k] : (v ?? null));
    const row: DetailsRow = {
        link,
        site: r.site,
        found: r.any ? 1 : old?.found ?? 0,
        name: keep("name", f.name) as string | null,
        handle: keep("handle", f.handle) as string | null,
        text: keep("text", f.text) as string | null,
        title: keep("title", f.title) as string | null,
        channel: keep("channel", f.channel) as string | null,
        game: keep("game", f.game) as string | null,
        clipper: keep("clipper", f.clipper) as string | null,
        site_name: keep("site_name", f.site_name) as string | null,
        posted_at: keep("posted_at", f.posted_at) as number | null,
        counts: cleanCounts(f.counts) ?? old?.counts ?? null,
        verified: f.verified === undefined ? old?.verified ?? 0 : f.verified ? 1 : 0,
        avatar_key: avatarKey ?? old?.avatar_key ?? null,
        fetched_at: now,
        edited_at: old?.edited_at ?? null,
    };
    await d.db
        .prepare(
            `INSERT INTO post_details (${DETAILS_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
             ON CONFLICT(link) DO UPDATE SET site = excluded.site, found = excluded.found, name = excluded.name, handle = excluded.handle,
                text = excluded.text, title = excluded.title, channel = excluded.channel, game = excluded.game, clipper = excluded.clipper,
                site_name = excluded.site_name, posted_at = excluded.posted_at, counts = excluded.counts, verified = excluded.verified,
                avatar_key = excluded.avatar_key, fetched_at = excluded.fetched_at`,
        )
        .bind(row.link, row.site, row.found, row.name, row.handle, row.text, row.title, row.channel, row.game, row.clipper, row.site_name, row.posted_at, row.counts, row.verified, row.avatar_key, row.fetched_at, row.edited_at)
        .run();
    return row;
}

/** The row, looked up first when there is none (or `refresh`, or nothing was found and a day went by). */
export async function ensureDetails(d: LookupDeps, link: string, refresh = false): Promise<DetailsRow> {
    const row = await readDetails(d.db, link);
    if (row && !refresh && (row.found === 1 || d.now() - row.fetched_at < RETRY_NOTHING_MS)) return row;
    return await refreshDetails(d, link);
}

export const PATCH_FIELDS = ["name", "handle", "text", "title", "channel", "game", "clipper", "posted_at"] as const;
export type DetailsPatch = Partial<Record<(typeof PATCH_FIELDS)[number], string | number | null>>;

/** Checks a PATCH body (52.2): the field that is wrong, or the patch. */
export function parsePatch(b: unknown): { ok: true; patch: DetailsPatch } | { ok: false; path: string } {
    if (typeof b !== "object" || b === null || Array.isArray(b)) return { ok: false, path: "" };
    const out: DetailsPatch = {};
    for (const [k, v] of Object.entries(b as Record<string, unknown>)) {
        if (!(PATCH_FIELDS as readonly string[]).includes(k)) return { ok: false, path: k };
        if (k === "posted_at") {
            if (v !== null && (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 8.64e15)) return { ok: false, path: k };
            out.posted_at = v === null ? null : Math.round(v);
            continue;
        }
        if (v !== null && typeof v !== "string") return { ok: false, path: k };
        if (typeof v === "string" && v.length > (k === "text" ? TEXT_MAX : FIELD_MAX)) return { ok: false, path: k };
        (out as any)[k] = v === null || v.trim() === "" ? null : v.trim();
    }
    return { ok: true, patch: out };
}

/** Saves Harmony's own edits (52.3); the row must exist. */
export async function patchDetails(db: D1Database, link: string, patch: DetailsPatch, now: number): Promise<void> {
    const keys = Object.keys(patch) as (keyof DetailsPatch)[];
    const sets = keys.map((k, i) => `${k} = ?${i + 1}`);
    sets.push(`edited_at = ?${keys.length + 1}`);
    await db
        .prepare(`UPDATE post_details SET ${sets.join(", ")} WHERE link = ?${keys.length + 2}`)
        .bind(...keys.map((k) => patch[k] ?? null), now, link)
        .run();
}

/** A row as the routes answer it (52.2). */
export function detailsShape(row: DetailsRow, avatarUrl: string | null): PostDetails {
    let counts: Counts = {};
    try {
        const c = row.counts ? JSON.parse(row.counts) : {};
        if (c && typeof c === "object") counts = c;
    } catch {
        /* a broken cell reads as no counts */
    }
    return {
        link: row.link,
        site: (POST_SITES as readonly string[]).includes(row.site) ? row.site : "generic",
        found: row.found === 1,
        name: row.name,
        handle: row.handle,
        text: row.text,
        title: row.title,
        channel: row.channel,
        game: row.game,
        clipper: row.clipper,
        site_name: row.site_name,
        posted_at: row.posted_at,
        counts,
        verified: row.verified === 1,
        avatar_url: row.avatar_key ? avatarUrl : null,
        edited: row.edited_at !== null,
    };
}

// ---- the cron (52.1) ---------------------------------------------------------------------------------------------------

export const POST_DETAILS_PER_RUN = 6;
export const POST_DETAILS_NEW_HOURS = 48;

/** Looks up recent saves that have no row yet. */
export async function backfillPostDetails(d: LookupDeps, o: { limit: number; hours: number }): Promise<{ looked: number; found: number }> {
    if (o.limit <= 0) return { looked: 0, found: 0 };
    const since = d.now() - o.hours * 3600 * 1000;
    const { results } = await d.db
        .prepare(
            `SELECT DISTINCT m.link AS link FROM media_items m LEFT JOIN post_details p ON p.link = m.link
              WHERE m.source = 'saved' AND m.link IS NOT NULL AND m.link != '' AND m.deleted_at IS NULL AND m.created_at >= ?1
                AND m.content_type LIKE 'video/%' AND p.link IS NULL
              ORDER BY m.created_at DESC LIMIT ?2`,
        )
        .bind(since, o.limit)
        .all<{ link: string }>();
    let found = 0;
    for (const r of results) {
        const row = await refreshDetails(d, r.link).catch(() => null);
        if (row?.found === 1) found++;
    }
    return { looked: results.length, found };
}

/** Plain-var config: POST_DETAILS_PER_RUN, POST_DETAILS_NEW_HOURS. */
export function postDetailsConfigFrom(env: { POST_DETAILS_PER_RUN?: string; POST_DETAILS_NEW_HOURS?: string }): { limit: number; hours: number } {
    const n = (v: string | undefined, dflt: number, max: number) => {
        const x = Number(v);
        return v !== undefined && v.trim() !== "" && Number.isFinite(x) && x >= 0 ? Math.min(max, Math.floor(x)) : dflt;
    };
    return { limit: n(env.POST_DETAILS_PER_RUN, POST_DETAILS_PER_RUN, 50), hours: n(env.POST_DETAILS_NEW_HOURS, POST_DETAILS_NEW_HOURS, 24 * 30) };
}
