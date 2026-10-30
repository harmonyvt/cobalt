// d1/migrations/0025_hidden.sql (APP-API-CONTRACT.md section 37): additive, applies cleanly on top of 0001-0024, keeps
// one state row per post with only the known states and setters, and one row per rule with only the known kinds. It is
// NOT applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const m25 = readFileSync(dir + "0025_hidden.sql", "utf8");
const statements = m25
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0025", () => {
    it("is the next file after 0024", () => {
        const at = files.indexOf("0025_hidden.sql");
        expect(files[at - 1]).toBe("0024_private_links.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0025").toBe(true);
    });
    it("holds two new tables and one index, nothing else", () => {
        expect(statements).toHaveLength(3);
        expect(statements[0]).toMatch(/^CREATE TABLE media_hidden \(/);
        expect(statements[1]).toMatch(/^CREATE INDEX idx_media_hidden_state ON media_hidden/);
        expect(statements[2]).toMatch(/^CREATE TABLE hidden_rules \(/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("keeps one row per post, with only the known states and setters", () => {
        const db = createFakeD1();
        const add = (key: string, state: string, by: string) =>
            db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, ?, ?, NULL, 1)").run(key, state, by);
        add("a", "hidden", "you");
        add("b", "exempt", "chat");
        add("c", "held", "rule");
        expect(() => add("a", "exempt", "you")).toThrow();
        expect(() => add("d", "gone", "you")).toThrow();
        expect(() => add("e", "hidden", "someone")).toThrow();
        expect(() => db.raw.prepare("INSERT INTO media_hidden (post_key, state, by) VALUES ('f', 'hidden', 'you')").run()).toThrow();
    });
    it("keeps rules of the four kinds, enabled by default with no hits", () => {
        const db = createFakeD1();
        const add = (id: string, kind: string, enabled = 1) =>
            db.raw.prepare("INSERT INTO hidden_rules (id, kind, value, enabled, created_at, updated_at) VALUES (?, ?, 'v', ?, 1, 1)").run(id, kind, enabled);
        for (const [i, k] of ["site", "words", "about", "upload"].entries()) add(`r${i}`, k);
        expect(() => add("r9", "tag")).toThrow();
        expect(() => add("r8", "words", 2)).toThrow();
        db.raw.prepare("INSERT INTO hidden_rules (id, kind, value, created_at, updated_at) VALUES ('d', 'upload', '', 1, 1)").run();
        expect(db.raw.prepare("SELECT enabled, hits FROM hidden_rules WHERE id = 'd'").get()).toEqual({ enabled: 1, hits: 0 });
    });
});
