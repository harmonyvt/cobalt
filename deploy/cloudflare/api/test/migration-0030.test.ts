// d1/migrations/0030_transcripts.sql (APP-API-CONTRACT.md section 47): additive, applies cleanly on top of the earlier
// files, keeps one transcript row per post with only the known states, and one moment per post and index. It is NOT
// applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = readFileSync(dir + "0030_transcripts.sql", "utf8");
const statements = sql
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0030", () => {
    it("comes after 0027 (0028 and 0029 belong to other work) and is the last so far", () => {
        const at = files.indexOf("0030_transcripts.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]! < "0030").toBe(true);
        expect(files.includes("0027_chat_agents.sql")).toBe(true);
        expect(files[at + 1] === undefined || files[at + 1]! > "0030").toBe(true);
    });
    it("holds two new tables, nothing else", () => {
        expect(statements).toHaveLength(2);
        expect(statements[0]).toMatch(/^CREATE TABLE media_transcripts \(/);
        expect(statements[1]).toMatch(/^CREATE TABLE media_moments \(/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("keeps one transcript per post with only the known states, and one moment per post and index", () => {
        const db = createFakeD1();
        const add = (key: string, state: string) =>
            db.raw.prepare("INSERT INTO media_transcripts (post_key, item_id, state, created_at, updated_at) VALUES (?, 'i', ?, 1, 1)").run(key, state);
        add("a", "done");
        add("b", "no_speech");
        add("c", "failed");
        expect(() => add("a", "done")).toThrow();
        expect(() => add("d", "pending")).toThrow();
        expect((db.raw.prepare("SELECT attempts FROM media_transcripts WHERE post_key = 'a'").get() as any).attempts).toBe(0);
        const moment = (key: string, idx: number) =>
            db.raw.prepare(`INSERT INTO media_moments (post_key, idx, start, "end", text, input_hash, updated_at) VALUES (?, ?, 0, 1, 't', 'h', 1)`).run(key, idx);
        moment("a", 0);
        moment("a", 1);
        expect(() => moment("a", 0)).toThrow();
    });
});
