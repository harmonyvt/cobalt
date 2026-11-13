// Stage music (APP-API-CONTRACT.md section 56): the Spotify side. OAuth for the owner's account, the Web API calls
// the studio makes (what is playing, add to queue, skip, volume, search, one track), YouTube's oEmbed title lookup,
// and the parsing of what a viewer typed into "song request". `fetch` is injected so the tests run on fakes with no
// network. Free of Cloudflare imports. Tokens are stored encrypted with stage-twitch.ts's encryptToken, keyed by
// SPOTIFY_CLIENT_SECRET.

export const SPOTIFY_ACCOUNTS = "https://accounts.spotify.com";
export const SPOTIFY_API = "https://api.spotify.com/v1";
export const YOUTUBE_OEMBED = "https://www.youtube.com/oembed";
// what is playing, the player (volume, device) and changing it (queue, skip, volume)
export const SPOTIFY_SCOPES = ["user-read-currently-playing", "user-read-playback-state", "user-modify-playback-state"] as const;
export const SPOTIFY_CALL_MS = 8_000;

export type SpotifyConfig = { clientId: string; clientSecret: string };
export type SpotifyFetch = (input: string, init?: RequestInit) => Promise<Response>;

// Both secrets, or null while either is missing or empty (`features.stage_spotify` is false then).
export function spotifyConfigFrom(env: { SPOTIFY_CLIENT_ID?: string; SPOTIFY_CLIENT_SECRET?: string }): SpotifyConfig | null {
    const clientId = (env.SPOTIFY_CLIENT_ID ?? "").trim();
    const clientSecret = (env.SPOTIFY_CLIENT_SECRET ?? "").trim();
    return clientId && clientSecret ? { clientId, clientSecret } : null;
}

// What Spotify said when it refused. `status` 0 = no answer. `reason` is the player API's reason
// (NO_ACTIVE_DEVICE, PREMIUM_REQUIRED, VOLUME_CONTROL_DISALLOW, ...) or the OAuth error (invalid_grant).
export class SpotifyError extends Error {
    constructor(
        readonly status: number,
        readonly reason: string,
        readonly detail: string = "",
    ) {
        super(`spotify ${status}${reason ? ` ${reason}` : ""}${detail ? ` ${detail}` : ""}`);
        this.name = "SpotifyError";
    }
}

export type SpotifyTokens = { access_token: string; refresh_token: string; expires_in: number; scope: string[] };
export type SpotifyUser = { id: string; display_name: string; product: string };
export type Track = { id: string; uri: string; title: string; artist: string; art_url: string | null; duration_ms: number; explicit: boolean };
export type Playing = { playing: boolean; progress_ms: number; track: Track | null };
export type Device = { id: string | null; volume_percent: number | null; supports_volume: boolean };

export type SpotifyClient = {
    authorizeUrl(redirectUri: string, state: string): string;
    exchangeCode(code: string, redirectUri: string): Promise<SpotifyTokens>;
    refresh(refreshToken: string): Promise<SpotifyTokens>;
    me(token: string): Promise<SpotifyUser>;
    // null: nothing playing (204), or something that is not a track (an ad, a podcast episode)
    playing(token: string): Promise<Playing | null>;
    // the active device, or null when none is
    device(token: string): Promise<Device | null>;
    track(token: string, id: string): Promise<Track | null>;
    search(token: string, q: string): Promise<Track | null>;
    queue(token: string, uri: string): Promise<void>;
    next(token: string): Promise<void>;
    volume(token: string, percent: number, deviceId: string | null): Promise<void>;
    // YouTube's public oEmbed (no key): the video's title and channel, or null when it has none (private, removed)
    youtube(videoId: string): Promise<{ title: string; author: string } | null>;
};

const form = (o: Record<string, string>) => new URLSearchParams(o).toString();
const str = (v: unknown): string => (typeof v === "string" ? v : "");

async function failure(res: Response): Promise<SpotifyError> {
    let reason = "";
    let detail = "";
    try {
        const t = await res.text();
        try {
            const j = JSON.parse(t) as { error?: unknown; error_description?: unknown };
            if (j.error && typeof j.error === "object") {
                const e = j.error as { reason?: unknown; message?: unknown };
                reason = str(e.reason);
                detail = str(e.message);
            } else {
                reason = str(j.error);
                detail = str(j.error_description);
            }
        } catch {
            detail = t.slice(0, 200);
        }
    } catch {
        /* no body */
    }
    return new SpotifyError(res.status, reason.slice(0, 60), detail.slice(0, 200));
}

type RawTrack = {
    id?: unknown;
    uri?: unknown;
    name?: unknown;
    type?: unknown;
    duration_ms?: unknown;
    explicit?: unknown;
    artists?: { name?: unknown }[];
    album?: { images?: { url?: unknown; width?: unknown }[] };
};

// A track as the studio uses it, or null for anything else (an episode, a local file without an id).
export function trackOf(raw: unknown): Track | null {
    const t = raw as RawTrack | null;
    if (!t || typeof t !== "object" || (t.type !== undefined && t.type !== "track")) return null;
    if (typeof t.id !== "string" || typeof t.uri !== "string" || typeof t.name !== "string") return null;
    const artists = (Array.isArray(t.artists) ? t.artists : []).map((a) => str(a?.name)).filter(Boolean);
    const images = (Array.isArray(t.album?.images) ? t.album!.images! : []).filter((i) => typeof i?.url === "string");
    // the smallest picture at least 160 wide (Spotify lists them largest first), else the largest there is
    const fit = [...images].reverse().find((i) => typeof i.width === "number" && i.width >= 160) ?? images[0];
    return {
        id: t.id,
        uri: t.uri,
        title: t.name.slice(0, 200),
        artist: artists.join(", ").slice(0, 200),
        art_url: fit && /^https:\/\//.test(String(fit.url)) ? String(fit.url) : null,
        duration_ms: typeof t.duration_ms === "number" && Number.isFinite(t.duration_ms) ? Math.max(0, Math.round(t.duration_ms)) : 0,
        explicit: t.explicit === true,
    };
}

export function spotifyClient(cfg: SpotifyConfig, fetchFn: SpotifyFetch, timeoutMs: number = SPOTIFY_CALL_MS): SpotifyClient {
    // Never lets a network error escape untyped (status 0), and every call is raced against our own timeout.
    const send = async (url: string, init: RequestInit): Promise<Response> => {
        const ctrl = new AbortController();
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<never>((_, reject) => {
            timer = setTimeout(() => {
                reject(new SpotifyError(0, "timeout"));
                ctrl.abort();
            }, timeoutMs);
        });
        try {
            return await Promise.race([fetchFn(url, { ...init, signal: ctrl.signal }), timeout]);
        } catch (e) {
            if (e instanceof SpotifyError) throw e;
            throw new SpotifyError(0, e instanceof Error ? e.name : "network");
        } finally {
            clearTimeout(timer);
        }
    };
    const tokenCall = async (body: Record<string, string>): Promise<SpotifyTokens> => {
        const res = await send(`${SPOTIFY_ACCOUNTS}/api/token`, {
            method: "POST",
            headers: {
                "content-type": "application/x-www-form-urlencoded",
                authorization: `Basic ${btoa(`${cfg.clientId}:${cfg.clientSecret}`)}`,
            },
            body: form(body),
        });
        if (!res.ok) throw await failure(res);
        const j = (await res.json().catch(() => null)) as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown; scope?: unknown } | null;
        if (!j || typeof j.access_token !== "string") throw new SpotifyError(res.status, "no_token");
        return {
            access_token: j.access_token,
            // a refresh may or may not hand out a new refresh token
            refresh_token: str(j.refresh_token),
            expires_in: typeof j.expires_in === "number" ? j.expires_in : 3600,
            scope: str(j.scope).split(" ").filter(Boolean),
        };
    };
    const api = async (token: string, method: string, path: string): Promise<Response> => {
        const res = await send(`${SPOTIFY_API}${path}`, { method, headers: { authorization: `Bearer ${token}` } });
        if (!res.ok) throw await failure(res);
        return res;
    };
    const json = async (res: Response): Promise<any> => (res.status === 204 ? null : res.json().catch(() => null));
    return {
        authorizeUrl(redirectUri, state) {
            const q = new URLSearchParams({
                response_type: "code",
                client_id: cfg.clientId,
                redirect_uri: redirectUri,
                scope: SPOTIFY_SCOPES.join(" "),
                state,
                show_dialog: "true",
            });
            return `${SPOTIFY_ACCOUNTS}/authorize?${q.toString()}`;
        },
        exchangeCode: (code, redirectUri) => tokenCall({ grant_type: "authorization_code", code, redirect_uri: redirectUri }),
        refresh: (refreshToken) => tokenCall({ grant_type: "refresh_token", refresh_token: refreshToken }),
        async me(token) {
            const j = await json(await api(token, "GET", "/me"));
            if (!j || typeof j.id !== "string") throw new SpotifyError(200, "no_user");
            return { id: j.id, display_name: str(j.display_name) || j.id, product: str(j.product) };
        },
        async playing(token) {
            const j = await json(await api(token, "GET", "/me/player/currently-playing"));
            if (!j || typeof j !== "object") return null;
            const track = trackOf(j.item);
            if (!track) return null;
            return { playing: j.is_playing === true, progress_ms: typeof j.progress_ms === "number" ? Math.max(0, j.progress_ms) : 0, track };
        },
        async device(token) {
            const j = await json(await api(token, "GET", "/me/player"));
            const dv = j?.device;
            if (!dv || typeof dv !== "object") return null;
            return {
                id: typeof dv.id === "string" ? dv.id : null,
                volume_percent: typeof dv.volume_percent === "number" ? dv.volume_percent : null,
                supports_volume: dv.supports_volume !== false,
            };
        },
        async track(token, id) {
            try {
                return trackOf(await json(await api(token, "GET", `/tracks/${encodeURIComponent(id)}`)));
            } catch (e) {
                if (e instanceof SpotifyError && (e.status === 404 || e.status === 400)) return null;
                throw e;
            }
        },
        async search(token, q) {
            const j = await json(await api(token, "GET", `/search?${new URLSearchParams({ q, type: "track", limit: "1" }).toString()}`));
            return trackOf(j?.tracks?.items?.[0]);
        },
        async queue(token, uri) {
            await api(token, "POST", `/me/player/queue?${new URLSearchParams({ uri }).toString()}`);
        },
        async next(token) {
            await api(token, "POST", "/me/player/next");
        },
        async volume(token, percent, deviceId) {
            const q = new URLSearchParams({ volume_percent: String(Math.max(0, Math.min(100, Math.round(percent)))) });
            if (deviceId) q.set("device_id", deviceId);
            await api(token, "PUT", `/me/player/volume?${q.toString()}`);
        },
        async youtube(videoId) {
            const q = new URLSearchParams({ url: `https://www.youtube.com/watch?v=${videoId}`, format: "json" });
            const res = await send(`${YOUTUBE_OEMBED}?${q.toString()}`, { method: "GET" });
            if (res.status === 404 || res.status === 401 || res.status === 403 || res.status === 400) return null;
            if (!res.ok) throw new SpotifyError(res.status, "youtube");
            const j = (await res.json().catch(() => null)) as { title?: unknown; author_name?: unknown } | null;
            if (!j || typeof j.title !== "string" || !j.title.trim()) return null;
            return { title: j.title.trim().slice(0, 200), author: str(j.author_name).trim().slice(0, 100) };
        },
    };
}

// ---- what a viewer typed -------------------------------------------------------------------------------------------------------

export type SongInput =
    | { kind: "spotify"; id: string }
    | { kind: "youtube"; id: string }
    | { kind: "words"; q: string }
    // a link we cannot use: an album, a playlist, another site, a Spotify short link
    | { kind: "link"; host: string }
    | { kind: "empty" };

const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;
const YOUTUBE_ID = /^[A-Za-z0-9_-]{11}$/;

export function parseSongInput(raw: string): SongInput {
    const text = raw.replace(/\s+/g, " ").trim();
    if (!text) return { kind: "empty" };
    const uri = /^spotify:track:([A-Za-z0-9]{22})$/.exec(text);
    if (uri) return { kind: "spotify", id: uri[1]! };
    // the first thing that looks like a link wins; the words around it are ignored
    const m = /(?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,}\/\S*/i.exec(text);
    if (!m) return { kind: "words", q: text.slice(0, 120) };
    let url: URL;
    try {
        url = new URL(/^https?:\/\//i.test(m[0]) ? m[0] : `https://${m[0]}`);
    } catch {
        return { kind: "words", q: text.slice(0, 120) };
    }
    const host = url.hostname.toLowerCase().replace(/^www\.|^m\./, "");
    const parts = url.pathname.split("/").filter(Boolean);
    if (host === "open.spotify.com" || host === "play.spotify.com") {
        // /track/<id>, /intl-xx/track/<id>, /embed/track/<id>
        const i = parts.indexOf("track");
        const id = i >= 0 ? parts[i + 1] : undefined;
        return id && SPOTIFY_ID.test(id) ? { kind: "spotify", id } : { kind: "link", host };
    }
    if (host === "youtu.be") {
        const id = parts[0];
        return id && YOUTUBE_ID.test(id) ? { kind: "youtube", id } : { kind: "link", host };
    }
    if (host === "youtube.com" || host === "music.youtube.com") {
        const v = url.searchParams.get("v");
        if (v && YOUTUBE_ID.test(v)) return { kind: "youtube", id: v };
        if ((parts[0] === "shorts" || parts[0] === "live" || parts[0] === "embed") && parts[1] && YOUTUBE_ID.test(parts[1])) return { kind: "youtube", id: parts[1] };
        return { kind: "link", host };
    }
    return { kind: "link", host };
}

// A YouTube title and channel as Spotify search words: "Artist - Song (Official Video) [4K]" by "ArtistVEVO" becomes
// "Artist - Song"; a title with no artist in it gets the channel name in front ("Song" by "Artist - Topic").
export function youtubeQuery(title: string, author: string): string {
    let t = title
        .replace(/\[[^\]]*\]/g, " ")
        .replace(/\((?:[^)]*\b(?:official|video|audio|lyrics?|visuali[sz]er|mv|m\/v|hd|4k|remaster(?:ed)?|live)\b[^)]*)\)/gi, " ")
        .replace(/\b(?:official\s+(?:music\s+)?video|official\s+audio|lyric\s+video|music\s+video)\b/gi, " ")
        .replace(/[|｜].*$/, " ")
        .replace(/#\S+/g, " ")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/[-–—:]\s*$/, "")
        .trim();
    if (!t) t = title.trim();
    const channel = author.replace(/\s*-\s*topic$/i, "").replace(/vevo$/i, "").replace(/\s*official$/i, "").trim();
    const hasArtist = /\s[-–—]\s/.test(t) || (channel && t.toLowerCase().includes(channel.toLowerCase()));
    return (hasArtist || !channel ? t : `${channel} ${t}`).slice(0, 120);
}
