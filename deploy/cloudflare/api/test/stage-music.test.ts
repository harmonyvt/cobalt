// Stage music (APP-API-CONTRACT.md section 56): Spotify connect, the song reward, now playing and up next, the
// owner's skip, and turning the music down while a summoned video plays. Real SQL on node:sqlite, fake Twitch,
// fake Spotify and YouTube oEmbed, no network.
import { describe, expect, it } from "vitest";
import { STAGE, T0, spTrack, world, type World } from "./stage-world";
import { parseSongInput, youtubeQuery } from "../src/stage-spotify";
import { NOW_PLAYING_TTL_MS } from "../src/stage-music";

const SONG = spTrack("blueHour", "blue hour", "tidepool", 201_000);
const LONG = spTrack("tenHourMix", "10 hour lofi mix", "beats", 36_000_000);
const RUDE = spTrack("rudeSong", "rude song", "potty mouth", 180_000, true);
const SUGAR = spTrack("sugarRush", "sugar rush", "kiki and the pops", 178_000);

// on air, Twitch and Spotify connected, the song reward on
async function live(): Promise<World> {
    const w = await world({ spotify: true });
    w.video({ name: "red cat.mp4" });
    await w.goLive();
    await w.connectTwitch();
    await w.connectSpotify();
    await w.owner("PATCH", "/stage/rewards/song", { enabled: true });
    for (const t of [SONG, LONG, RUDE, SUGAR]) w.spotify.add(t);
    w.room.events.length = 0;
    return w;
}
const lastRedemption = (w: World) => w.one("SELECT * FROM stage_redemptions ORDER BY rowid DESC LIMIT 1");
const lastSettle = (w: World) => w.twitch.redemptions.at(-1)?.status;
const toasts = (w: World) => w.room.events.filter((e) => e.type === "toast").map((e: any) => e.toast);

describe("connecting Spotify (56.2)", () => {
    it("features.stage_spotify needs both secrets and the stage", async () => {
        const caps = async (w: World) => ((await w.api("/capabilities").then((r) => r.json())) as any).features;
        expect(await caps(await world({ spotify: true }))).toMatchObject({ stage: true, stage_spotify: true });
        expect(await caps(await world())).toMatchObject({ stage_spotify: false });
        expect(await caps(await world({ spotify: true, env: { SPOTIFY_CLIENT_SECRET: " " } }))).toMatchObject({ stage_spotify: false });
        expect(await caps(await world({ spotify: true, stage: false }))).toMatchObject({ stage_spotify: false });
    });

    it("connect gives the authorize URL; the callback stores the account with encrypted tokens", async () => {
        const w = await world({ spotify: true });
        const { res, authorize_url } = await w.connectSpotify();
        const u = new URL(authorize_url);
        expect(u.origin + u.pathname).toBe("https://accounts.spotify.com/authorize");
        expect(u.searchParams.get("redirect_uri")).toBe(`${STAGE}spotify/callback`);
        expect(u.searchParams.get("scope")).toBe("user-read-currently-playing user-read-playback-state user-modify-playback-state");
        expect(res.status).toBe(200);
        expect(await res.text()).toContain("cobalt-apple://stage?spotify=connected");
        const row = w.one("SELECT * FROM stage_spotify");
        expect(row).toMatchObject({ user_id: "harmony", display_name: "Harmony", product: "premium", status: "ok", expires_at: T0 + 3600_000 });
        expect(JSON.stringify(row)).not.toContain("sp-at-1");
        expect(JSON.stringify(row)).not.toContain("sp-rt-1");
        expect(w.stageRow().spotify_state).toBeNull();
        const g = await w.owner("GET", "/stage");
        expect(g.body.stage.music).toMatchObject({
            card: "full",
            up_next: true,
            song_youtube: true,
            song_max_seconds: 600,
            song_queue_max: 5,
            song_explicit: false,
            duck: true,
            duck_volume: 20,
            spotify: { display_name: "Harmony", product: "premium", status: "ok" },
        });
        expect(g.body.rewards.find((r: any) => r.action === "song")).toMatchObject({ title: "song request", enabled: false });
    });

    it("a wrong or spent state connects nothing; without the secrets the routes are 404", async () => {
        const w = await world({ spotify: true });
        const { state } = await w.connectSpotify();
        const again = await w.site(`/spotify/callback?code=sp-code&state=${state}`);
        expect(again.status).toBe(400);
        expect(await again.text()).toContain("reason=state");
        const off = await world();
        expect((await off.owner("POST", "/stage/spotify/connect")).status).toBe(404);
        expect((await off.owner("DELETE", "/stage/spotify")).status).toBe(404);
    });

    it("DELETE /stage/spotify forgets the account", async () => {
        const w = await world({ spotify: true });
        await w.connectSpotify();
        const r = await w.owner("DELETE", "/stage/spotify");
        expect(r.status).toBe(200);
        expect(r.body.stage.music.spotify).toBeNull();
        expect(w.q("SELECT * FROM stage_spotify")).toHaveLength(0);
    });

    it("PATCH /stage takes the music keys, clamps numbers and refuses wrong types", async () => {
        const w = await world({ spotify: true });
        const r = await w.owner("PATCH", "/stage", { music_card: "compact", music_up_next: false, song_max_seconds: 5, song_queue_max: 99, duck_volume: 140, song_explicit: true, duck: false });
        expect(r.body.stage.music).toMatchObject({ card: "compact", up_next: false, song_max_seconds: 60, song_queue_max: 20, duck_volume: 100, song_explicit: true, duck: false });
        expect((await w.owner("PATCH", "/stage", { music_card: "huge" })).status).toBe(400);
        expect((await w.owner("PATCH", "/stage", { duck: "yes" })).status).toBe(400);
        // the canvas hears the card setting
        expect(w.room.last("settings")!.stage).toMatchObject({ music_card: "compact", music_up_next: false, duck: false });
    });
});

describe("song requests (56.4)", () => {
    it("a Spotify link goes straight into the queue and up next", async () => {
        const w = await live();
        await w.redeem("song", `https://open.spotify.com/intl-de/track/${SONG.id}?si=abc`, { user: "lunar_tea", cost: 300 });
        expect(w.spotify.queued).toEqual([`spotify:track:${SONG.id}`]);
        expect(lastSettle(w)).toBe("FULFILLED");
        expect(lastRedemption(w)).toMatchObject({ action: "song", status: "done", reason: null });
        expect(w.one("SELECT * FROM stage_songs")).toMatchObject({ user_name: "lunar_tea", source: "spotify", title: "blue hour", artist: "tidepool", state: "waiting" });
        expect(toasts(w)[0]).toMatchObject({ by: "lunar_tea", action: "song", cost: 300, detail: "blue hour · tidepool, up next #1" });
        expect(w.room.types()).toContain("music");
        const m = await w.siteJson(`/live/${await w.token()}/music`);
        expect(m.body.up_next).toEqual([
            { id: expect.any(String), title: "blue hour", artist: "tidepool", art_url: `https://i.scdn.co/image/${SONG.id}-300`, duration_ms: 201_000, by: "lunar_tea", source: "spotify" },
        ]);
    });

    it("words are searched; a YouTube link is matched by its cleaned-up title", async () => {
        const w = await live();
        await w.redeem("song", "blue hour tidepool", { user: "a" });
        expect(toasts(w).at(-1).detail).toBe('"blue hour tidepool" → blue hour · tidepool, up next #1');
        w.spotify.youtube.set("dQw4w9WgXcQ", { title: "Kiki & The Pops - Sugar Rush (Official Music Video) [4K]", author_name: "KikiVEVO" });
        w.spotify.searches.set("Kiki & The Pops - Sugar Rush", SUGAR.id);
        await w.redeem("song", "https://youtu.be/dQw4w9WgXcQ?si=x", { user: "b" });
        expect(w.spotify.queued.at(-1)).toBe(`spotify:track:${SUGAR.id}`);
        expect(toasts(w).at(-1).detail).toBe("from youtube: sugar rush · kiki and the pops, up next #2");
        expect(w.one("SELECT source FROM stage_songs WHERE title = 'sugar rush'").source).toBe("youtube");
    });

    it("refunds say why: too long, explicit, one each, a full queue, the same song, a bad link, nothing found", async () => {
        const w = await live();
        const refunded = async (input: string, user: string, detail: string | RegExp, reason: string) => {
            await w.redeem("song", input, { user });
            expect(lastSettle(w)).toBe("CANCELED");
            expect(lastRedemption(w)).toMatchObject({ status: "refunded", reason });
            expect(toasts(w).at(-1)).toMatchObject({ action: "song", cost: 0, refunded: true });
            expect(toasts(w).at(-1).detail).toMatch(detail);
        };
        await refunded("10 hour lofi mix", "a", '"10 hour lofi mix" is over 10 min, points refunded', "too_long");
        await refunded("rude song", "a", '"rude song" is explicit, points refunded', "explicit");
        await refunded("https://open.spotify.com/album/1234567890123456789012", "a", "that open.spotify.com link isn't a song, points refunded", "bad_link");
        await refunded("https://example.com/song", "a", "that example.com link isn't a song, points refunded", "bad_link");
        await refunded("zzz nothing", "a", 'nothing on spotify for "zzz nothing", points refunded', "no_match");
        await refunded("", "a", "type a song or paste a link, points refunded", "no_match");
        await w.redeem("song", "blue hour", { user: "a" });
        expect(lastSettle(w)).toBe("FULFILLED");
        await refunded("sugar rush", "a", "you already have one waiting, points refunded", "waiting");
        await refunded("blue hour", "b", '"blue hour" is already up next, points refunded', "duplicate");
        await w.owner("PATCH", "/stage", { song_queue_max: 1 });
        await refunded("sugar rush", "c", "1 songs are already waiting, points refunded", "full");
        expect(w.spotify.queued).toHaveLength(1);
    });

    it("no device, no premium, YouTube off, Spotify not connected, off air and the reward off are refunds", async () => {
        const w = await live();
        w.spotify.device = null;
        await w.redeem("song", "blue hour", { user: "a" });
        expect(toasts(w).at(-1).detail).toBe("spotify isn't on, points refunded");
        expect(lastRedemption(w).reason).toBe("no_device");
        w.spotify.device = { id: "d", volume_percent: 50, supports_volume: true };
        w.spotify.premium = false;
        await w.redeem("song", "blue hour", { user: "a" });
        expect(lastRedemption(w).reason).toBe("premium");
        w.spotify.premium = true;
        await w.owner("PATCH", "/stage", { song_youtube: false });
        await w.redeem("song", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", { user: "a" });
        expect(lastRedemption(w).reason).toBe("youtube_off");
        await w.owner("DELETE", "/stage/spotify");
        await w.redeem("song", "blue hour", { user: "a" });
        expect(lastRedemption(w).reason).toBe("spotify_off");
        await w.owner("PATCH", "/stage", { on_air: false });
        await w.redeem("song", "blue hour", { user: "a" });
        expect(lastRedemption(w).reason).toBe("off_air");
        expect(w.spotify.queued).toHaveLength(0);
    });

    it("a refused refresh token marks Spotify for reconnecting and refunds", async () => {
        const w = await live();
        w.tick(2 * 60 * 60 * 1000);
        w.spotify.refreshFails = true;
        await w.redeem("song", "blue hour", { user: "a" });
        expect(lastRedemption(w)).toMatchObject({ status: "refunded", reason: "spotify_off" });
        expect(w.one("SELECT status FROM stage_spotify").status).toBe("reconnect");
        expect((await w.owner("GET", "/stage")).body.stage.music.spotify.status).toBe("reconnect");
    });
});

describe("now playing and up next (56.3)", () => {
    it("shows the track and who asked for it, moves up next along, and shares one Spotify call", async () => {
        const w = await live();
        await w.redeem("song", "blue hour", { user: "lunar_tea" });
        await w.redeem("song", "sugar rush", { user: "pixelfox" });
        const tok = await w.token();
        // the owner's own song first
        w.spotify.add(spTrack("ownSong", "own song", "me"));
        w.spotify.playing = { id: spTrack("ownSong", "", "").id, progress_ms: 1000, is_playing: true };
        let m = await w.siteJson(`/live/${tok}/music`);
        expect(m.body).toMatchObject({ connected: true, card: "full", up_next_on: true, queue_max: 5 });
        expect(m.body.now_playing).toMatchObject({ title: "own song", artist: "me", by: null, playing: true, progress_ms: 1000, at: w.now() });
        expect(m.body.up_next.map((s: any) => s.by)).toEqual(["lunar_tea", "pixelfox"]);
        // a request comes up
        w.tick(NOW_PLAYING_TTL_MS);
        w.spotify.playing = { id: SONG.id, progress_ms: 0, is_playing: true };
        m = await w.siteJson(`/live/${tok}/music`);
        expect(m.body.now_playing).toMatchObject({ title: "blue hour", by: "lunar_tea" });
        expect(m.body.up_next.map((s: any) => s.by)).toEqual(["pixelfox"]);
        // within the few seconds, nobody asks Spotify again
        const calls = w.spotify.calls.length;
        await w.siteJson(`/live/${tok}/music`);
        await w.siteJson(`/store/api/music`).catch(() => null);
        expect(w.spotify.calls.length).toBe(calls);
        // the next song: the request before it is played
        w.tick(NOW_PLAYING_TTL_MS);
        w.spotify.playing = { id: SUGAR.id, progress_ms: 0, is_playing: false };
        m = await w.siteJson(`/live/${tok}/music`);
        expect(m.body.now_playing).toMatchObject({ title: "sugar rush", by: "pixelfox", playing: false });
        expect(w.q("SELECT state FROM stage_songs ORDER BY created_at").map((r) => r.state)).toEqual(["played", "playing"]);
        expect(m.body.up_next).toEqual([]);
    });

    it("a request never heard drops off up next after 3 hours; nothing playing is null", async () => {
        const w = await live();
        await w.redeem("song", "blue hour", { user: "a" });
        w.tick(3 * 60 * 60 * 1000 + 1);
        const m = await w.siteJson(`/live/${await w.token()}/music`);
        expect(m.body.now_playing).toBeNull();
        expect(m.body.up_next).toEqual([]);
        expect(w.one("SELECT state FROM stage_songs").state).toBe("gone");
    });

    it("the store shows the same, the canvas token guards the canvas route", async () => {
        const w = await live();
        await w.owner("PATCH", "/stage", { store_open: true });
        w.spotify.playing = { id: SONG.id, progress_ms: 5, is_playing: true };
        const s = await w.siteJson("/store/api/music");
        expect(s.status).toBe(200);
        expect(s.body.now_playing.title).toBe("blue hour");
        expect((await w.siteJson("/live/wrongtoken/music")).status).toBe(404);
        const page = await (await w.site("/store")).text();
        expect(page).toContain('id="musicsec"');
        expect(page).toContain("song request");
    });

    it("the owner's skip moves Spotify on and marks the request skipped", async () => {
        const w = await live();
        await w.redeem("song", "blue hour", { user: "a" });
        w.spotify.playing = { id: SONG.id, progress_ms: 5, is_playing: true };
        await w.siteJson(`/live/${await w.token()}/music`);
        const r = await w.owner("POST", "/stage/action", { type: "song_skip" });
        expect(r.status).toBe(200);
        expect(w.spotify.nexts).toBe(1);
        expect(w.one("SELECT state FROM stage_songs").state).toBe("skipped");
        expect(w.room.types()).toContain("music");
        w.spotify.device = null;
        expect((await w.owner("POST", "/stage/action", { type: "song_skip" })).body.error.code).toBe("error.stage.spotify_no_device");
    });
});

describe("turning the music down (56.6)", () => {
    const duck = (w: World, tok: string, on: boolean) => w.siteJson(`/live/${tok}/duck`, { method: "POST", body: JSON.stringify({ on }), headers: { "content-type": "application/json" } });

    it("down to duck_volume while a summon plays, back to the owner's volume after", async () => {
        const w = await live();
        const tok = await w.token();
        expect((await duck(w, tok, true)).body).toEqual({ status: "success", ducked: true });
        expect(w.spotify.volumes).toEqual([20]);
        // a second "on" keeps it down without touching Spotify
        expect((await duck(w, tok, true)).body.ducked).toBe(true);
        expect(w.spotify.volumes).toEqual([20]);
        expect((await duck(w, tok, false)).body.ducked).toBe(false);
        expect(w.spotify.volumes.at(-1)).toBe(70);
        expect(w.spotify.volumes).toHaveLength(4);
        // nothing to lift twice
        await duck(w, tok, false);
        expect(w.spotify.volumes).toHaveLength(4);
    });

    it("a phone that refuses volume, a quiet volume, duck off and a wrong token change nothing", async () => {
        const w = await live();
        const tok = await w.token();
        w.spotify.device = { id: "phone", volume_percent: 80, supports_volume: false };
        expect((await duck(w, tok, true)).body.ducked).toBe(false);
        w.spotify.device = { id: "mac", volume_percent: 15, supports_volume: true };
        expect((await duck(w, tok, true)).body.ducked).toBe(false);
        w.spotify.device = { id: "mac", volume_percent: 60, supports_volume: true };
        await w.owner("PATCH", "/stage", { duck: false });
        expect((await duck(w, tok, true)).body.ducked).toBe(false);
        expect(w.spotify.volumes).toEqual([]);
        expect((await duck(w, "nope", true)).status).toBe(404);
        expect((await w.siteJson(`/live/${tok}/duck`, { method: "POST", body: "{}" })).status).toBe(400);
    });

    it("a duck the canvas never lifted is lifted by now playing after 5 minutes", async () => {
        const w = await live();
        const tok = await w.token();
        await duck(w, tok, true);
        w.tick(5 * 60 * 1000 + 1);
        await w.siteJson(`/live/${tok}/music`);
        expect(w.spotify.volumes.at(-1)).toBe(70);
        expect(w.one("SELECT duck_restore FROM stage_spotify").duck_restore).toBeNull();
    });

    it("the canvas page carries the card and the duck calls", async () => {
        const w = await live();
        const html = await (await w.site(`/live/${await w.token()}`)).text();
        expect(html).toContain('id="np"');
        expect(html).toContain("/duck");
        expect(html).toContain("only=nowplaying");
    });
});

describe("reading what a viewer typed (56.4)", () => {
    it("parses links and words", () => {
        expect(parseSongInput("spotify:track:4uLU6hMCjMI75M1A2tKUQC")).toEqual({ kind: "spotify", id: "4uLU6hMCjMI75M1A2tKUQC" });
        expect(parseSongInput("play this https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=1 pls")).toEqual({ kind: "spotify", id: "4uLU6hMCjMI75M1A2tKUQC" });
        expect(parseSongInput("open.spotify.com/intl-ja/track/4uLU6hMCjMI75M1A2tKUQC")).toEqual({ kind: "spotify", id: "4uLU6hMCjMI75M1A2tKUQC" });
        expect(parseSongInput("https://youtu.be/dQw4w9WgXcQ?t=3")).toEqual({ kind: "youtube", id: "dQw4w9WgXcQ" });
        expect(parseSongInput("https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=x")).toEqual({ kind: "youtube", id: "dQw4w9WgXcQ" });
        expect(parseSongInput("https://music.youtube.com/watch?v=dQw4w9WgXcQ")).toEqual({ kind: "youtube", id: "dQw4w9WgXcQ" });
        expect(parseSongInput("https://www.youtube.com/shorts/dQw4w9WgXcQ")).toEqual({ kind: "youtube", id: "dQw4w9WgXcQ" });
        expect(parseSongInput("https://spotify.link/abc")).toEqual({ kind: "link", host: "spotify.link" });
        expect(parseSongInput("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")).toEqual({ kind: "link", host: "open.spotify.com" });
        expect(parseSongInput("  never gonna give you up  ")).toEqual({ kind: "words", q: "never gonna give you up" });
        expect(parseSongInput("   ")).toEqual({ kind: "empty" });
    });

    it("turns a YouTube title into search words", () => {
        expect(youtubeQuery("Rick Astley - Never Gonna Give You Up (Official Music Video)", "Rick Astley")).toBe("Rick Astley - Never Gonna Give You Up");
        expect(youtubeQuery("Blue Hour [Lyrics]", "Tidepool - Topic")).toBe("Tidepool Blue Hour");
        expect(youtubeQuery("Sugar Rush | Live at the O2 #shorts", "KikiVEVO")).toBe("Kiki Sugar Rush");
        expect(youtubeQuery("song title", "")).toBe("song title");
    });
});
