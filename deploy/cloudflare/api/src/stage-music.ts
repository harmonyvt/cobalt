// Stage music (APP-API-CONTRACT.md section 56): the owner's Spotify on the stage. The connect flow and its tokens,
// "now playing" (one Spotify call every few seconds at most, shared by every open page through stage_spotify.np_json),
// the viewers' song requests (the `song` reward: a Spotify link, a YouTube link matched on Spotify, or words), the
// up-next list (stage_songs, moved along as Spotify plays them), and turning the music down while a summoned video
// plays (duck). Spotify's own queue cannot be read reliably (it holds autoplay) nor edited, so "up next" is our list.
// Free of Cloudflare imports; the tests run it on node:sqlite with a fake Spotify.

import { randomBase62 } from "./ids";
import type { StudioReply } from "./studio";
import { decryptToken, encryptToken } from "./stage-twitch";
import { SPOTIFY_SCOPES, SpotifyError, parseSongInput, spotifyClient, youtubeQuery, type SpotifyClient, type Track } from "./stage-spotify";
import { readSettings, writeSettings, type SettingsRow, type StageDeps } from "./stage";

// ---- constants -------------------------------------------------------------------------------------------------------------

// how long one "what is playing" answer is shared before Spotify is asked again
export const NOW_PLAYING_TTL_MS = 4_000;
// a waiting request not heard within this long is dropped from up next (skipped past, queue cleared by hand)
export const SONG_WAIT_MS = 3 * 60 * 60 * 1000;
// a duck nobody lifted (the canvas closed mid-video) is lifted by the next now-playing call after this long
export const DUCK_MAX_MS = 5 * 60 * 1000;
export const SPOTIFY_STATE_TTL_MS = 10 * 60 * 1000;
export const UP_NEXT_MAX = 20;
export const MUSIC_CARDS = ["full", "compact", "off"] as const;
export type MusicCard = (typeof MUSIC_CARDS)[number];

const log = (what: string, e?: unknown) => console.error(`[stage music] ${what}`, e === undefined ? "" : e instanceof Error ? `${e.name}: ${e.message}` : String(e));
const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });
const ok = (body: Record<string, unknown> = {}): StudioReply => ({ status: 200, body: { status: "success", ...body } });
const rbytes = (d: Pick<StageDeps, "randomBytes">) => d.randomBytes ?? ((n: number) => crypto.getRandomValues(new Uint8Array(n)));

// ---- rows ---------------------------------------------------------------------------------------------------------------------

type SpotifyRow = {
    user_id: string;
    display_name: string;
    product: string;
    access_token: string;
    refresh_token: string;
    expires_at: number;
    scopes: string;
    connected_at: number;
    status: "ok" | "reconnect";
    status_at: number;
    np_json: string | null;
    np_at: number;
    duck_restore: number | null;
    duck_device: string | null;
    duck_at: number | null;
};

export type SongRow = {
    id: string;
    user_id: string;
    user_name: string;
    input: string;
    source: "spotify" | "youtube" | "words";
    track_id: string;
    uri: string;
    title: string;
    artist: string;
    art_url: string | null;
    duration_ms: number;
    state: "waiting" | "playing" | "played" | "skipped" | "gone";
    created_at: number;
    started_at: number | null;
    ended_at: number | null;
};

// What every page draws: the track, how far in, and who asked for it (null: the owner's own music).
export type NowPlaying = {
    playing: boolean;
    title: string;
    artist: string;
    art_url: string | null;
    uri: string;
    progress_ms: number;
    duration_ms: number;
    by: string | null;
    // ms (server clock) the progress was read: pages move the bar along from here
    at: number;
};

export type UpNext = { id: string; title: string; artist: string; art_url: string | null; duration_ms: number; by: string; source: SongRow["source"] };

const readSpotify = (d: StageDeps) => d.db.prepare("SELECT * FROM stage_spotify WHERE id = 'main'").first<SpotifyRow>();

export const spotifyClientOf = (d: StageDeps): SpotifyClient | null =>
    d.spotify ? spotifyClient(d.spotify, d.spotifyFetch ?? ((u, i) => fetch(u, i))) : null;

// ---- settings -----------------------------------------------------------------------------------------------------------------

export type MusicSettings = {
    card: MusicCard;
    up_next: boolean;
    song_youtube: boolean;
    song_max_seconds: number;
    song_queue_max: number;
    song_explicit: boolean;
    duck: boolean;
    duck_volume: number;
};

export const musicCardOf = (s: Pick<SettingsRow, "music_card">): MusicCard =>
    (MUSIC_CARDS as readonly string[]).includes(s.music_card) ? (s.music_card as MusicCard) : "full";

export function musicSettings(s: SettingsRow): MusicSettings {
    return {
        card: musicCardOf(s),
        up_next: s.music_up_next === 1,
        song_youtube: s.song_youtube === 1,
        song_max_seconds: s.song_max_seconds,
        song_queue_max: s.song_queue_max,
        song_explicit: s.song_explicit === 1,
        duck: s.duck === 1,
        duck_volume: s.duck_volume,
    };
}

// PATCH /stage's music keys (56.4): numbers are clamped, a wrong type is refused (null).
export const MUSIC_NUMBERS = [
    { key: "song_max_seconds", lo: 60, hi: 3600 },
    { key: "song_queue_max", lo: 1, hi: 20 },
    { key: "duck_volume", lo: 0, hi: 100 },
] as const;
export const MUSIC_BOOLS = [
    ["music_up_next", "music_up_next"],
    ["song_youtube", "song_youtube"],
    ["song_explicit", "song_explicit"],
    ["duck", "duck"],
] as const;

export function musicPatch(b: Record<string, unknown>): Record<string, number | string> | null {
    const set: Record<string, number | string> = {};
    if (b.music_card !== undefined) {
        if (typeof b.music_card !== "string" || !(MUSIC_CARDS as readonly string[]).includes(b.music_card)) return null;
        set.music_card = b.music_card;
    }
    for (const [key, col] of MUSIC_BOOLS) {
        if (b[key] === undefined) continue;
        if (typeof b[key] !== "boolean") return null;
        set[col] = b[key] ? 1 : 0;
    }
    for (const n of MUSIC_NUMBERS) {
        const v = b[n.key];
        if (v === undefined) continue;
        if (typeof v !== "number" || !Number.isFinite(v)) return null;
        set[n.key] = Math.min(n.hi, Math.max(n.lo, Math.round(v)));
    }
    return set;
}

// ---- tokens -------------------------------------------------------------------------------------------------------------------

async function setStatus(d: StageDeps, status: SpotifyRow["status"]): Promise<void> {
    await d.db.prepare("UPDATE stage_spotify SET status = ?1, status_at = ?2 WHERE id = 'main' AND status <> ?1").bind(status, d.now()).run();
}

// The owner's access token, refreshed when it expires within 2 minutes (or `force`: Spotify said 401). A refused
// refresh token, or tokens this secret cannot open, sets status "reconnect".
async function accessToken(d: StageDeps, sp: SpotifyClient, force: boolean): Promise<string> {
    const row = await readSpotify(d);
    if (!row || !d.spotify) throw new SpotifyError(404, "not_connected");
    if (row.status === "reconnect") throw new SpotifyError(401, "reconnect");
    const secret = d.spotify.clientSecret;
    try {
        if (!force && row.expires_at - d.now() > 2 * 60_000) return await decryptToken(secret, row.access_token);
        const old = await decryptToken(secret, row.refresh_token);
        const t = await sp.refresh(old);
        await d.db
            .prepare("UPDATE stage_spotify SET access_token = ?1, refresh_token = ?2, expires_at = ?3, scopes = ?4 WHERE id = 'main'")
            .bind(
                await encryptToken(secret, t.access_token),
                await encryptToken(secret, t.refresh_token || old),
                d.now() + t.expires_in * 1000,
                t.scope.length > 0 ? t.scope.join(" ") : row.scopes,
            )
            .run();
        return t.access_token;
    } catch (e) {
        if (!(e instanceof SpotifyError) || e.status === 400 || e.status === 401) {
            await setStatus(d, "reconnect").catch(() => undefined);
            throw new SpotifyError(401, "reconnect");
        }
        throw e;
    }
}

// Runs a Spotify call as the owner; a 401 refreshes the token once and tries again.
async function asOwner<T>(d: StageDeps, sp: SpotifyClient, call: (token: string) => Promise<T>): Promise<T> {
    let token = await accessToken(d, sp, false);
    try {
        return await call(token);
    } catch (e) {
        if (!(e instanceof SpotifyError) || e.status !== 401) throw e;
        token = await accessToken(d, sp, true);
        return await call(token);
    }
}

// ---- the owner's view (56.5) -----------------------------------------------------------------------------------------------------

export async function musicShape(d: StageDeps, s: SettingsRow) {
    const row = d.spotify ? await readSpotify(d) : null;
    return {
        ...musicSettings(s),
        spotify: row ? { display_name: row.display_name, product: row.product, status: row.status, connected_at: row.connected_at } : null,
        now_playing: row ? cachedNowPlaying(row, d.now(), 60_000) : null,
        queue: await upNext(d),
    };
}

// ---- connect (56.2) -----------------------------------------------------------------------------------------------------------

export async function spotifyConnect(d: StageDeps): Promise<StudioReply> {
    const sp = spotifyClientOf(d);
    if (!sp) return err(404, "error.stage.spotify_off");
    await readSettings(d);
    const state = randomBase62(32, rbytes(d));
    await writeSettings(d, { spotify_state: state, spotify_state_at: d.now() });
    return ok({ authorize_url: sp.authorizeUrl(`${d.stageBaseUrl}spotify/callback`, state) });
}

export async function spotifyDisconnect(d: StageDeps): Promise<void> {
    // Spotify has no token revoke endpoint: forgetting the tokens is the disconnect. A duck in progress is lifted first.
    await duckOff(d).catch(() => undefined);
    await d.db.prepare("DELETE FROM stage_spotify WHERE id = 'main'").run();
}

const HTML_HEADERS = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex", "referrer-policy": "no-referrer" };

function callbackPage(good: boolean, reason?: string): Response {
    const target = good ? "cobalt-apple://stage?spotify=connected" : `cobalt-apple://stage?spotify=failed&reason=${encodeURIComponent(reason ?? "error")}`;
    const text = good ? "spotify is connected. you can close this." : "spotify did not connect. you can close this.";
    const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>spotify</title>
<style>body{background:#000;color:#fff;font:16px/1.5 ui-monospace,Menlo,monospace;display:grid;place-items:center;min-height:100vh;margin:0;text-align:center}a{color:#1ed760}</style>
</head><body><main><p>${text}</p><p><a href="${target}">back to the app</a></p></main>
<script>location.replace(${JSON.stringify(target)})</script></body></html>`;
    return new Response(html, { status: good ? 200 : 400, headers: HTML_HEADERS });
}

export async function spotifyCallback(d: StageDeps, url: URL): Promise<Response> {
    const sp = spotifyClientOf(d);
    if (!sp || !d.spotify) return callbackPage(false, "off");
    await readSettings(d);
    const state = url.searchParams.get("state") ?? "";
    // single use, spent in one statement by the request carrying the live state (as Twitch's, 30.8)
    const claimed = state
        ? await d.db
              .prepare("UPDATE stage_settings SET spotify_state = NULL, spotify_state_at = NULL WHERE id = 'main' AND spotify_state = ?1 AND spotify_state_at >= ?2")
              .bind(state, d.now() - SPOTIFY_STATE_TTL_MS)
              .run()
        : null;
    if (Number(claimed?.meta?.changes ?? 0) !== 1) return callbackPage(false, "state");
    const code = url.searchParams.get("code");
    if (url.searchParams.has("error") || !code) return callbackPage(false, "denied");
    try {
        const t = await sp.exchangeCode(code, `${d.stageBaseUrl}spotify/callback`);
        if (!SPOTIFY_SCOPES.every((x) => t.scope.includes(x))) return callbackPage(false, "scope");
        const me = await sp.me(t.access_token);
        const secret = d.spotify.clientSecret;
        const now = d.now();
        await d.db
            .prepare(
                `INSERT INTO stage_spotify (id, user_id, display_name, product, access_token, refresh_token, expires_at, scopes, connected_at, status, status_at, np_json, np_at)
                 VALUES ('main', ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'ok', ?8, NULL, 0)
                 ON CONFLICT (id) DO UPDATE SET user_id = ?1, display_name = ?2, product = ?3, access_token = ?4, refresh_token = ?5,
                    expires_at = ?6, scopes = ?7, connected_at = ?8, status = 'ok', status_at = ?8, np_json = NULL, np_at = 0`,
            )
            .bind(me.id, me.display_name, me.product, await encryptToken(secret, t.access_token), await encryptToken(secret, t.refresh_token), now + t.expires_in * 1000, t.scope.join(" "), now)
            .run();
    } catch (e) {
        log("spotify connect failed", e);
        return callbackPage(false, e instanceof SpotifyError && e.status !== 0 ? "exchange" : "error");
    }
    return callbackPage(true);
}

// ---- up next and now playing (56.3) ----------------------------------------------------------------------------------------------

export async function upNext(d: StageDeps, limit = UP_NEXT_MAX): Promise<UpNext[]> {
    const { results } = await d.db
        .prepare("SELECT * FROM stage_songs WHERE state = 'waiting' AND created_at >= ?1 ORDER BY created_at, id LIMIT ?2")
        .bind(d.now() - SONG_WAIT_MS, limit)
        .all<SongRow>();
    return results.map((r) => ({ id: r.id, title: r.title, artist: r.artist, art_url: r.art_url, duration_ms: r.duration_ms, by: r.user_name, source: r.source }));
}

function cachedNowPlaying(row: Pick<SpotifyRow, "np_json" | "np_at">, now: number, maxAge: number): NowPlaying | null {
    if (!row.np_json || now - row.np_at > maxAge) return null;
    try {
        return JSON.parse(row.np_json) as NowPlaying;
    } catch {
        return null;
    }
}

// Moves the request list along with what Spotify plays: the request now playing becomes `playing` (the one before it
// `played`), and a waiting one older than 3 hours is `gone`. Returns who asked for the current track, if anyone.
async function advanceSongs(d: StageDeps, uri: string | null): Promise<string | null> {
    const now = d.now();
    await d.db.prepare("UPDATE stage_songs SET state = 'gone', ended_at = ?1 WHERE state = 'waiting' AND created_at < ?2").bind(now, now - SONG_WAIT_MS).run();
    const playing = await d.db.prepare("SELECT * FROM stage_songs WHERE state = 'playing' ORDER BY started_at DESC LIMIT 1").first<SongRow>();
    if (playing && playing.uri === uri) return playing.user_name;
    if (playing) await d.db.prepare("UPDATE stage_songs SET state = 'played', ended_at = ?1 WHERE state = 'playing'").bind(now).run();
    if (!uri) return null;
    const next = await d.db
        .prepare("SELECT * FROM stage_songs WHERE state = 'waiting' AND uri = ?1 ORDER BY created_at, id LIMIT 1")
        .bind(uri)
        .first<SongRow>();
    if (!next) return null;
    await d.db.prepare("UPDATE stage_songs SET state = 'playing', started_at = ?2 WHERE id = ?1").bind(next.id, now).run();
    return next.user_name;
}

// What the owner's Spotify is playing, at most one Spotify call per NOW_PLAYING_TTL_MS for everyone. null: not
// connected, nothing playing, or Spotify did not answer (the last answer is kept for a minute then).
export async function nowPlaying(d: StageDeps): Promise<{ connected: boolean; now_playing: NowPlaying | null }> {
    const sp = spotifyClientOf(d);
    if (!sp) return { connected: false, now_playing: null };
    const row = await readSpotify(d);
    if (!row || row.status === "reconnect") return { connected: false, now_playing: null };
    const now = d.now();
    if (now - row.np_at < NOW_PLAYING_TTL_MS) return { connected: true, now_playing: cachedNowPlaying(row, now, Number.MAX_SAFE_INTEGER) };
    // one caller refreshes; the others keep the answer they have
    const claim = await d.db.prepare("UPDATE stage_spotify SET np_at = ?1 WHERE id = 'main' AND np_at = ?2").bind(now, row.np_at).run();
    if (Number(claim.meta?.changes ?? 0) !== 1) return { connected: true, now_playing: cachedNowPlaying(row, now, 60_000) };
    // a duck left behind (the canvas went away mid-video) is lifted here
    if (row.duck_restore !== null && row.duck_at !== null && now - row.duck_at > DUCK_MAX_MS) await duckOff(d).catch((e) => log("lifting a stale duck failed", e));
    let np: NowPlaying | null = null;
    try {
        const p = await asOwner(d, sp, (t) => sp.playing(t));
        const by = await advanceSongs(d, p?.track?.uri ?? null);
        np = p?.track
            ? {
                  playing: p.playing,
                  title: p.track.title,
                  artist: p.track.artist,
                  art_url: p.track.art_url,
                  uri: p.track.uri,
                  progress_ms: p.progress_ms,
                  duration_ms: p.track.duration_ms,
                  by,
                  at: now,
              }
            : null;
    } catch (e) {
        if (e instanceof SpotifyError && e.reason === "reconnect") return { connected: false, now_playing: null };
        log("now playing failed", e);
        return { connected: true, now_playing: cachedNowPlaying(row, now, 60_000) };
    }
    await d.db.prepare("UPDATE stage_spotify SET np_json = ?1 WHERE id = 'main'").bind(np ? JSON.stringify(np) : null).run();
    return { connected: true, now_playing: np };
}

// GET /live/<token>/music and /store/api/music (56.3)
export async function musicState(d: StageDeps, s: SettingsRow): Promise<StudioReply> {
    const m = musicSettings(s);
    const { connected, now_playing } = m.card === "off" && !m.up_next ? { connected: false, now_playing: null } : await nowPlaying(d);
    return ok({
        connected,
        card: m.card,
        up_next_on: m.up_next,
        queue_max: s.song_queue_max,
        now_playing,
        up_next: m.up_next ? await upNext(d, Math.min(UP_NEXT_MAX, s.song_queue_max)) : [],
        now: d.now(),
    });
}

// The owner's skip: Spotify moves to the next track, and a request that was playing counts as skipped.
export async function songSkip(d: StageDeps): Promise<StudioReply> {
    const sp = spotifyClientOf(d);
    if (!sp || !(await readSpotify(d))) return err(409, "error.stage.spotify_not_connected");
    try {
        await asOwner(d, sp, (t) => sp.next(t));
    } catch (e) {
        return err(409, spotifyRefusal(e));
    }
    const now = d.now();
    await d.db.prepare("UPDATE stage_songs SET state = 'skipped', ended_at = ?1 WHERE state = 'playing'").bind(now).run();
    // the next page asks Spotify again
    await d.db.prepare("UPDATE stage_spotify SET np_at = 0 WHERE id = 'main'").run();
    return ok();
}

const spotifyRefusal = (e: unknown): string => {
    if (!(e instanceof SpotifyError)) return "error.stage.spotify";
    if (e.reason === "reconnect") return "error.stage.spotify_reconnect";
    if (e.reason === "NO_ACTIVE_DEVICE" || e.status === 404) return "error.stage.spotify_no_device";
    if (e.reason === "PREMIUM_REQUIRED") return "error.stage.spotify_premium";
    return "error.stage.spotify";
};

// ---- turning the music down (56.6) -------------------------------------------------------------------------------------------------

// The canvas asks while a summoned (or owner-picked) video with sound is in the spotlight. Remembers the volume the
// owner had and sets duck_volume; a second "on" while down only keeps it down. Spotify refuses volume on some
// devices (phones: VOLUME_CONTROL_DISALLOW): then nothing happens and the canvas is told `ducked: false`.
export async function duckOn(d: StageDeps, s: SettingsRow): Promise<{ ducked: boolean }> {
    const sp = spotifyClientOf(d);
    if (!sp || s.duck !== 1) return { ducked: false };
    const row = await readSpotify(d);
    if (!row || row.status === "reconnect") return { ducked: false };
    const now = d.now();
    if (row.duck_restore !== null) {
        await d.db.prepare("UPDATE stage_spotify SET duck_at = ?1 WHERE id = 'main'").bind(now).run();
        return { ducked: true };
    }
    try {
        const dev = await asOwner(d, sp, (t) => sp.device(t));
        if (!dev || !dev.supports_volume || dev.volume_percent === null) return { ducked: false };
        // already at or under the duck level: nothing to turn down, nothing to restore
        if (dev.volume_percent <= s.duck_volume) return { ducked: false };
        const claim = await d.db
            .prepare("UPDATE stage_spotify SET duck_restore = ?1, duck_device = ?2, duck_at = ?3 WHERE id = 'main' AND duck_restore IS NULL")
            .bind(dev.volume_percent, dev.id, now)
            .run();
        if (Number(claim.meta?.changes ?? 0) !== 1) return { ducked: true };
        try {
            await asOwner(d, sp, (t) => sp.volume(t, s.duck_volume, dev.id));
        } catch (e) {
            await d.db.prepare("UPDATE stage_spotify SET duck_restore = NULL, duck_device = NULL, duck_at = NULL WHERE id = 'main'").run();
            throw e;
        }
        return { ducked: true };
    } catch (e) {
        log("turning the music down failed", e);
        return { ducked: false };
    }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Back to the remembered volume, in three steps (a short fade). Nothing to do when the music is not down.
export async function duckOff(d: StageDeps, stepMs = 150): Promise<{ ducked: boolean }> {
    const sp = spotifyClientOf(d);
    const row = await readSpotify(d);
    if (!sp || !row || row.duck_restore === null) return { ducked: false };
    const claim = await d.db
        .prepare("UPDATE stage_spotify SET duck_restore = NULL, duck_device = NULL, duck_at = NULL WHERE id = 'main' AND duck_restore = ?1")
        .bind(row.duck_restore)
        .run();
    if (Number(claim.meta?.changes ?? 0) !== 1) return { ducked: false };
    const s = await readSettings(d);
    const from = Math.min(s.duck_volume, row.duck_restore);
    try {
        for (const f of [1 / 3, 2 / 3]) {
            await asOwner(d, sp, (t) => sp.volume(t, from + (row.duck_restore! - from) * f, row.duck_device));
            if (stepMs > 0) await sleep(stepMs);
        }
        await asOwner(d, sp, (t) => sp.volume(t, row.duck_restore!, row.duck_device));
    } catch (e) {
        log("turning the music back up failed", e);
    }
    return { ducked: false };
}

// ---- the song reward (56.4) ----------------------------------------------------------------------------------------------------------

export type SongVerdict = { status: "done" | "refunded"; reason: string | null; detail: string; title: string | null };

const refund = (reason: string, detail: string): SongVerdict => ({ status: "refunded", reason, detail, title: null });
const mins = (s: number) => (s % 60 === 0 ? `${s / 60} min` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`);
const shortName = (t: Track) => (t.artist ? `${t.title} · ${t.artist}` : t.title);

// One viewer's request: find the track, check the rules, add it to the owner's Spotify queue and to up next.
export async function requestSong(
    d: StageDeps,
    s: SettingsRow,
    ev: { id: string; user_id: string; user_name: string },
    input: string,
): Promise<SongVerdict> {
    const sp = spotifyClientOf(d);
    const row = sp ? await readSpotify(d) : null;
    if (!sp || !row) return refund("spotify_off", "spotify isn't connected, points refunded");
    if (row.status === "reconnect") return refund("spotify_off", "spotify needs connecting again, points refunded");
    const parsed = parseSongInput(input);
    if (parsed.kind === "empty") return refund("no_match", "type a song or paste a link, points refunded");
    if (parsed.kind === "link") return refund("bad_link", `that ${parsed.host} link isn't a song, points refunded`);
    if (parsed.kind === "youtube" && s.song_youtube !== 1) return refund("youtube_off", "youtube links are off, points refunded");

    // the per-viewer and queue limits first: they cost no Spotify call
    const now = d.now();
    const waiting = await d.db
        .prepare("SELECT user_id, track_id FROM stage_songs WHERE state = 'waiting' AND created_at >= ?1")
        .bind(now - SONG_WAIT_MS)
        .all<{ user_id: string; track_id: string }>();
    if (waiting.results.some((w) => w.user_id === ev.user_id)) return refund("waiting", "you already have one waiting, points refunded");
    if (waiting.results.length >= s.song_queue_max) return refund("full", `${s.song_queue_max} songs are already waiting, points refunded`);

    let track: Track | null = null;
    let source: SongRow["source"] = "words";
    try {
        if (parsed.kind === "spotify") {
            source = "spotify";
            track = await asOwner(d, sp, (t) => sp.track(t, parsed.id));
        } else if (parsed.kind === "youtube") {
            source = "youtube";
            const yt = await sp.youtube(parsed.id);
            if (!yt) return refund("no_match", "couldn't read that youtube link, points refunded");
            track = await asOwner(d, sp, (t) => sp.search(t, youtubeQuery(yt.title, yt.author)));
            if (!track) return refund("no_match", "couldn't find that youtube song on spotify, points refunded");
        } else {
            track = await asOwner(d, sp, (t) => sp.search(t, parsed.q));
        }
    } catch (e) {
        if (e instanceof SpotifyError && e.reason === "reconnect") return refund("spotify_off", "spotify needs connecting again, points refunded");
        throw e;
    }
    if (!track) return refund("no_match", `nothing on spotify for "${input.slice(0, 60)}", points refunded`);
    if (track.duration_ms > s.song_max_seconds * 1000) return refund("too_long", `"${track.title.slice(0, 60)}" is over ${mins(s.song_max_seconds)}, points refunded`);
    if (track.explicit && s.song_explicit !== 1) return refund("explicit", `"${track.title.slice(0, 60)}" is explicit, points refunded`);
    if (waiting.results.some((w) => w.track_id === track!.id)) return refund("duplicate", `"${track.title.slice(0, 60)}" is already up next, points refunded`);

    try {
        await asOwner(d, sp, (t) => sp.queue(t, track!.uri));
    } catch (e) {
        const code = spotifyRefusal(e);
        if (code === "error.stage.spotify_no_device") return refund("no_device", "spotify isn't on, points refunded");
        if (code === "error.stage.spotify_premium") return refund("premium", "spotify needs premium for requests, points refunded");
        if (code === "error.stage.spotify_reconnect") return refund("spotify_off", "spotify needs connecting again, points refunded");
        throw e;
    }
    await d.db
        .prepare(
            `INSERT OR IGNORE INTO stage_songs (id, user_id, user_name, input, source, track_id, uri, title, artist, art_url, duration_ms, state, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'waiting', ?12)`,
        )
        .bind(ev.id, ev.user_id, ev.user_name, input, source, track.id, track.uri, track.title, track.artist, track.art_url, track.duration_ms, now)
        .run();
    const place = waiting.results.length + 1;
    // words show what was typed; a link only says where it came from
    const asked = parsed.kind === "words" ? `"${input.slice(0, 60)}" → ` : parsed.kind === "youtube" ? "from youtube: " : "";
    return { status: "done", reason: null, detail: `${asked}${shortName(track)}, up next #${place}`, title: shortName(track) };
}

// The daily cron: requests older than 30 days.
export async function songRetention(db: D1Database, now: number, keepMs: number): Promise<number> {
    const r = await db.prepare("DELETE FROM stage_songs WHERE created_at < ?1").bind(now - keepMs).run();
    return Number(r.meta?.changes ?? 0);
}
