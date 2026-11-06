// d1/migrations/0032_safety.sql (APP-API-CONTRACT.md section 51): additive, applies cleanly on top of 0031, one row
// per item, only the known levels. It is NOT applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = readFileSync(dir + "0032_safety.sql", "utf8");
const statements = sql
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0032", () => {
    it("comes right after 0031", () => {
        const at = files.indexOf("0032_safety.sql");
        expect(files[at - 1]).toBe("0031_search_names.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0032").toBe(true);
    });
    it("holds one new table and one index, nothing else", () => {
        expect(statements).toHaveLength(2);
        expect(statements[0]).toMatch(/^CREATE TABLE media_safety \(/);
        expect(statements[1]).toMatch(/^CREATE INDEX idx_media_safety_due ON media_safety \(prep, level\)$/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("defaults to pending, keeps one row per item, and only the known levels", () => {
        const db = createFakeD1();
        db.raw.prepare("INSERT INTO media_safety (item_id, updated_at) VALUES ('a', 1)").run();
        expect(db.raw.prepare("SELECT level, gore, drawn, minor_sexual, user_level, attempts, prep, clips, stills, has_audio FROM media_safety").get()).toEqual({
            level: "pending",
            gore: 0,
            drawn: 0,
            minor_sexual: 0,
            user_level: null,
            attempts: 0,
            prep: "pending",
            clips: 0,
            stills: 0,
            has_audio: 0,
        });
        expect(() => db.raw.prepare("INSERT INTO media_safety (item_id, updated_at) VALUES ('a', 1)").run()).toThrow();
        expect(() => db.raw.prepare("INSERT INTO media_safety (item_id, level, updated_at) VALUES ('b', 'spicy', 1)").run()).toThrow();
        expect(() => db.raw.prepare("INSERT INTO media_safety (item_id, user_level, updated_at) VALUES ('c', 'pending', 1)").run()).toThrow();
        db.raw.prepare("INSERT INTO media_safety (item_id, level, user_level, updated_at) VALUES ('d', 'explicit', 'general', 1)").run();
        const plan = db.raw.prepare("EXPLAIN QUERY PLAN SELECT * FROM media_safety WHERE prep = 'ready' AND level = 'pending'").all() as { detail: string }[];
        expect(JSON.stringify(plan)).toContain("idx_media_safety_due");
    });
});
