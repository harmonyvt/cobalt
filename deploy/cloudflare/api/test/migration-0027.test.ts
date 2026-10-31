// d1/migrations/0027_chat_agents.sql (APP-API-CONTRACT.md section 43): additive, applies cleanly on top of 0001-0026, keeps
// one row per sub-agent with only the known statuses, and its mail. It is NOT applied to any remote database by the tests:
// the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = readFileSync(dir + "0027_chat_agents.sql", "utf8");
const statements = sql
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0027", () => {
    it("is the next file after 0026", () => {
        const at = files.indexOf("0027_chat_agents.sql");
        expect(files[at - 1]).toBe("0026_sessions.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0027").toBe(true);
    });
    it("holds two new tables and two indexes, nothing else", () => {
        expect(statements).toHaveLength(4);
        expect(statements[0]).toMatch(/^CREATE TABLE chat_agents \(/);
        expect(statements[1]).toMatch(/^CREATE INDEX idx_chat_agents_parent ON chat_agents/);
        expect(statements[2]).toMatch(/^CREATE TABLE chat_agent_mail \(/);
        expect(statements[3]).toMatch(/^CREATE INDEX idx_chat_agent_mail_to ON chat_agent_mail/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("keeps agents with only the known statuses, and their mail unread by default", () => {
        const db = createFakeD1();
        const add = (id: string, status: string) =>
            db.raw.prepare("INSERT INTO chat_agents (id, parent, name, task, status, created_at, updated_at) VALUES (?, 'p', ?, 't', ?, 1, 1)").run(id, id, status);
        for (const s of ["queued", "running", "done", "error", "stopped"]) add(s, s);
        expect(() => add("x", "paused")).toThrow();
        expect(() => add("done", "done")).toThrow();
        expect(db.raw.prepare("SELECT post_ids, turns, result FROM chat_agents WHERE id = 'done'").get()).toEqual({ post_ids: "[]", turns: 0, result: null });
        db.raw.prepare("INSERT INTO chat_agent_mail (parent, sender, recipient, text, created_at) VALUES ('p', 'parent', 'done', 'hi', 1)").run();
        expect(db.raw.prepare("SELECT id, read_at FROM chat_agent_mail").get()).toEqual({ id: 1, read_at: null });
    });
});
