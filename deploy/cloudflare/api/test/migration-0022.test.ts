// d1/migrations/0022_about.sql (APP-API-CONTRACT.md section 34.1): additive, applies cleanly on top of 0001-0021 with data
// in the existing tables, and holds two CREATE TABLE, one CREATE INDEX and one ALTER TABLE ... ADD COLUMN. It is NOT
// applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo21 = files.filter((f) => f < "0022").map(sql).join("\n");
const m22 = sql("0022_about.sql");
const statements = m22
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);
const cols = (db: any, table: string) => (db.raw.prepare(`PRAGMA table_info(${table})`).all() as any[]).map((c) => c.name);
const tables = (db: any) => (db.raw.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as any[]).map((r) => r.name);

describe("migration 0022", () => {
    it("is the next file after 0021", () => {
        const at = files.indexOf("0022_about.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]).toBe("0021_edits.sql");
        expect(files[at + 1]).toBeUndefined();
    });

    it("holds two new tables, one index and one new nullable column, nothing else", () => {
        expect(statements).toHaveLength(4);
        expect(statements[0]).toMatch(/^CREATE TABLE media_about \(/);
        expect(statements[1]).toMatch(/^CREATE INDEX idx_media_about_item ON media_about \(item_id\)$/);
        expect(statements[2]).toMatch(/^CREATE TABLE embed_terms \(/);
        expect(statements[3]).toBe("ALTER TABLE chat_messages ADD COLUMN ranked TEXT");
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW)\b/i);
    });

    it("applies on top of 0001-0021 with data in the existing tables: every old row survives, with ranked null", () => {
        const db = createFakeD1(upTo21);
        const r = db.raw;
        r.prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, created_at) VALUES ('Item000000000001','private','upload','originals','originals/x.mp4','x.mp4','video/mp4',1)").run();
        r.prepare("INSERT INTO chat_threads (id, title, titled_by, created_at, updated_at) VALUES ('T000000000000001', 't', 'auto', 1, 1)").run();
        r.prepare("INSERT INTO chat_messages (thread_id, role, text, status, created_at, updated_at) VALUES ('T000000000000001', 'user', 'hi', 'done', 1, 1)").run();
        const before = tables(db);
        const chatCols = cols(db, "chat_messages");
        r.exec(m22);
        expect(tables(db)).toEqual([...before, "embed_terms", "media_about"].sort());
        expect(cols(db, "chat_messages")).toEqual([...chatCols, "ranked"]);
        expect(r.prepare("SELECT text, ranked FROM chat_messages").get()).toEqual({ text: "hi", ranked: null });
        expect(r.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 1 });
    });

    it("has the columns of 34.1, in order, with the defaults the code relies on", () => {
        const db = createFakeD1(`${upTo21}\n${m22}`);
        expect(cols(db, "media_about")).toEqual([
            "post_key", "item_id", "probe_state", "probe_at", "probe_attempts", "frames", "has_audio", "transcript", "language", "sentence", "tags",
            "sound_tags", "user_tags", "model", "input_hash", "written_at", "failed_at", "attempts", "updated_at",
        ]);
        expect(cols(db, "embed_terms")).toEqual(["term", "source", "model", "dims", "vector", "mean", "created_at"]);
        const r = db.raw;
        r.prepare("INSERT INTO media_about (post_key, item_id, updated_at) VALUES ('p', 'i', 1)").run();
        expect(r.prepare("SELECT probe_state, probe_attempts, frames, has_audio, attempts, user_tags FROM media_about").get()).toEqual({
            probe_state: "pending",
            probe_attempts: 0,
            frames: 0,
            has_audio: 0,
            attempts: 0,
            user_tags: null,
        });
        expect(() => r.prepare("INSERT INTO media_about (post_key) VALUES ('x')").run()).toThrow();
        expect(() => r.prepare("INSERT INTO embed_terms (term) VALUES ('x')").run()).toThrow();
        expect(() => r.prepare("INSERT INTO media_about (post_key, item_id, updated_at) VALUES ('p', 'j', 1)").run()).toThrow(); // one row per post
    });
});
