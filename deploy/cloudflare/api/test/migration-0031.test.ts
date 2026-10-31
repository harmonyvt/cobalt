// d1/migrations/0031_search_names.sql (APP-API-CONTRACT.md section 48): additive, applies cleanly on top of the earlier
// files, keeps one name per normalized word, only the known flags and mark kinds, and one mark per post per name. It is
// NOT applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = readFileSync(dir + "0031_search_names.sql", "utf8");
const statements = sql
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0031", () => {
    it("comes right after 0030 and is the last so far", () => {
        const at = files.indexOf("0031_search_names.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]).toBe("0030_transcripts.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0031").toBe(true);
    });
    it("holds two new tables and one index, nothing else", () => {
        expect(statements).toHaveLength(3);
        expect(statements[0]).toMatch(/^CREATE TABLE search_names \(/);
        expect(statements[1]).toMatch(/^CREATE TABLE search_name_posts \(/);
        expect(statements[2]).toMatch(/^CREATE INDEX idx_search_name_posts_post ON search_name_posts \(post_key\)$/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("keeps the defaults, one name per word, enabled 0 or 1, and one yes or no mark per post per name", () => {
        const db = createFakeD1();
        const add = (id: string, key: string, enabled = 1) =>
            db.raw.prepare("INSERT INTO search_names (id, name, name_key, meaning, enabled, created_at, updated_at) VALUES (?, ?, ?, 'm', ?, 1, 1)").run(id, key, key, enabled);
        add("a", "lia");
        expect(() => add("b", "lia")).toThrow();
        expect(() => add("c", "capy", 2)).toThrow();
        const row = db.raw.prepare("SELECT * FROM search_names WHERE id = 'a'").get() as any;
        expect(row).toMatchObject({ aliases: "[]", strength: 0.5, cutoff: 0.5, enabled: 1, vector: null, point: null, meaning_hash: null });
        const mark = (name: string, post: string, kind: string) =>
            db.raw.prepare("INSERT INTO search_name_posts (name_id, post_key, kind, created_at) VALUES (?, ?, ?, 1)").run(name, post, kind);
        mark("a", "p1", "yes");
        mark("a", "p2", "no");
        mark("b", "p1", "no");
        expect(() => mark("a", "p1", "no")).toThrow();
        expect(() => mark("a", "p3", "maybe")).toThrow();
        const plan = db.raw.prepare("EXPLAIN QUERY PLAN SELECT * FROM search_name_posts WHERE post_key = 'p1'").all() as any[];
        expect(JSON.stringify(plan)).toContain("idx_search_name_posts_post");
    });
});
