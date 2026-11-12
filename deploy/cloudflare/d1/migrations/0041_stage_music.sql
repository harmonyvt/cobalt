-- Stage music (APP-API-CONTRACT.md section 56): the owner's Spotify on the canvas ("now playing", "up next"),
-- a sixth channel-point reward `song` that adds a viewer's song to the owner's Spotify queue, and turning the
-- music down while a summoned video plays. Additive: new tables, new settings columns with defaults, and
-- stage_rewards rebuilt so its CHECK allows 'song' (SQLite cannot alter a CHECK; every row is copied).
-- Apply BEFORE deploying the API Worker (old code never reads any of it). The song row itself is inserted by the
-- API on read (INSERT OR IGNORE, like the other rewards).

CREATE TABLE stage_rewards_next (
    action           TEXT PRIMARY KEY CHECK (action IN ('summon', 'chaos', 'shuffle', 'pin', 'skip', 'song')),
    twitch_reward_id TEXT,
    title            TEXT NOT NULL,
    prompt           TEXT NOT NULL,
    cost             INTEGER NOT NULL,
    cooldown_seconds INTEGER NOT NULL,
    enabled          INTEGER NOT NULL,
    synced           INTEGER NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL
);

INSERT INTO stage_rewards_next (action, twitch_reward_id, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at)
SELECT action, twitch_reward_id, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at FROM stage_rewards;

DROP TABLE stage_rewards;

ALTER TABLE stage_rewards_next RENAME TO stage_rewards;

-- The music settings (one row, like the rest of stage_settings).
--   music_card:        'full' | 'compact' | 'off': the now playing card on the canvas
--   music_up_next:     the viewers' songs still waiting, under the card
--   song_youtube:      a YouTube link is looked up and matched to the same song on Spotify
--   song_max_seconds:  longest song a viewer may request (60..3600)
--   song_queue_max:    how many requests may wait at once (1..20)
--   song_explicit:     songs Spotify marks explicit may be requested
--   duck:              turn the owner's Spotify down while a summoned video with sound is in the spotlight
--   duck_volume:       how far down (0..100, Spotify's volume percent)
--   spotify_state(_at): the Spotify connect flow's state (single use, 10 minutes)
ALTER TABLE stage_settings ADD COLUMN music_card TEXT NOT NULL DEFAULT 'full';
ALTER TABLE stage_settings ADD COLUMN music_up_next INTEGER NOT NULL DEFAULT 1;
ALTER TABLE stage_settings ADD COLUMN song_youtube INTEGER NOT NULL DEFAULT 1;
ALTER TABLE stage_settings ADD COLUMN song_max_seconds INTEGER NOT NULL DEFAULT 600;
ALTER TABLE stage_settings ADD COLUMN song_queue_max INTEGER NOT NULL DEFAULT 5;
ALTER TABLE stage_settings ADD COLUMN song_explicit INTEGER NOT NULL DEFAULT 0;
ALTER TABLE stage_settings ADD COLUMN duck INTEGER NOT NULL DEFAULT 1;
ALTER TABLE stage_settings ADD COLUMN duck_volume INTEGER NOT NULL DEFAULT 20;
ALTER TABLE stage_settings ADD COLUMN spotify_state TEXT;
ALTER TABLE stage_settings ADD COLUMN spotify_state_at INTEGER;

-- At most one row, id = 'main': the owner's Spotify account. Tokens AES-GCM encrypted like stage_twitch's (key from
-- SPOTIFY_CLIENT_SECRET). np_json/np_at cache what is playing for a few seconds so every open page shares one call.
-- duck_restore is the volume to go back to while the music is turned down (NULL when it is not).
CREATE TABLE stage_spotify (
    id            TEXT PRIMARY KEY CHECK (id = 'main'),
    user_id       TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    product       TEXT NOT NULL DEFAULT '',              -- 'premium' | 'free' | ...: queue and volume need premium
    access_token  TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    expires_at    INTEGER NOT NULL,
    scopes        TEXT NOT NULL DEFAULT '',
    connected_at  INTEGER NOT NULL,
    status        TEXT NOT NULL DEFAULT 'ok',            -- 'ok' | 'reconnect'
    status_at     INTEGER NOT NULL DEFAULT 0,
    np_json       TEXT,
    np_at         INTEGER NOT NULL DEFAULT 0,
    duck_restore  INTEGER,
    duck_device   TEXT,
    duck_at       INTEGER
);

-- Every song a viewer got into the queue (the Twitch redemption id). `state`: waiting (in Spotify's queue, not yet
-- heard), playing, played, skipped (the owner skipped it), gone (never seen playing within 3 hours). Rows older than
-- 30 days are deleted by the daily cron with the redemptions.
CREATE TABLE stage_songs (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    user_name   TEXT NOT NULL,
    input       TEXT NOT NULL DEFAULT '',
    source      TEXT NOT NULL CHECK (source IN ('spotify', 'youtube', 'words')),
    track_id    TEXT NOT NULL,
    uri         TEXT NOT NULL,
    title       TEXT NOT NULL,
    artist      TEXT NOT NULL DEFAULT '',
    art_url     TEXT,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    state       TEXT NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'playing', 'played', 'skipped', 'gone')),
    created_at  INTEGER NOT NULL,
    started_at  INTEGER,
    ended_at    INTEGER
);
CREATE INDEX idx_stage_songs_state ON stage_songs (state, created_at);
