// d1/migrations/0039_stage_music.sql (APP-API-CONTRACT.md section 56): stage_rewards rebuilt so action may be 'song'
// (rows copied), the music settings columns with their defaults, stage_spotify and stage_songs. Apply before the API.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo38 = files.filter((f) => f < "0039").map(sql).join("\n");
const m39 = sql("0039_stage_music.sql");

const insert = (db: ReturnType<typeof createFakeD1>, action: string) =>
    db.raw
        .prepare("INSERT INTO stage_rewards (action, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at) VALUES (?, ?, 'p', 10, 1, 1, 0, 5)")
        .run(action, action);

describe("migration 0039", () => {
    it("comes right after 0038", () => {
        const at = files.indexOf("0039_stage_music.sql");
        expect(files[at - 1]).toBe("0038_sync.sql");
    });

    it("keeps the rewards and settings that are there, then allows song, with the music defaults", () => {
        const db = createFakeD1(upTo38);
        insert(db, "skip");
        db.raw.prepare("INSERT INTO stage_settings (id, live_token, updated_at, density) VALUES ('main', 't', 1, 0)").run();
        expect(() => insert(db, "song")).toThrow();
        db.raw.exec(m39);
        expect(db.raw.prepare("SELECT action, cost, updated_at FROM stage_rewards").get()).toEqual({ action: "skip", cost: 10, updated_at: 5 });
        insert(db, "song");
        expect(() => insert(db, "nope")).toThrow();
        expect(db.raw.prepare("SELECT density, music_card, music_up_next, song_youtube, song_max_seconds, song_queue_max, song_explicit, duck, duck_volume, spotify_state FROM stage_settings").get()).toEqual({
            density: 0,
            music_card: "full",
            music_up_next: 1,
            song_youtube: 1,
            song_max_seconds: 600,
            song_queue_max: 5,
            song_explicit: 0,
            duck: 1,
            duck_volume: 20,
            spotify_state: null,
        });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM stage_spotify").get()).toEqual({ n: 0 });
        expect(() =>
            db.raw
                .prepare("INSERT INTO stage_songs (id, user_id, user_name, source, track_id, uri, title, state, created_at) VALUES ('r', 'u', 'U', 'tiktok', 't', 'spotify:track:t', 'x', 'waiting', 1)")
                .run(),
        ).toThrow();
    });
});
