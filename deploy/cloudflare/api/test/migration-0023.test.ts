// d1/migrations/0023_mcp_links.sql (APP-API-CONTRACT.md section 35.5): additive, applies cleanly on top of 0001-0022, and
// allows one live private link at a time. It is NOT applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const m23 = readFileSync(dir + "0023_mcp_links.sql", "utf8");
const statements = m23
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0023", () => {
    it("is the next file after 0022", () => {
        const at = files.indexOf("0023_mcp_links.sql");
        expect(files[at - 1]).toBe("0022_about.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0023").toBe(true);
    });
    it("holds two new tables and one index, nothing else", () => {
        expect(statements).toHaveLength(3);
        expect(statements[0]).toMatch(/^CREATE TABLE mcp_settings \(/);
        expect(statements[1]).toMatch(/^CREATE TABLE mcp_links \(/);
        expect(statements[2]).toMatch(/^CREATE UNIQUE INDEX idx_mcp_links_live ON mcp_links/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("allows one live link and one settings row", () => {
        const db = createFakeD1();
        const add = (id: string, revoked: number | null) =>
            db.raw.prepare("INSERT INTO mcp_links (id, link_hash, tail, made_at, revoked_at) VALUES (?, ?, 'abcd', 1, ?)").run(id, `h-${id}`, revoked);
        add("a", 5);
        add("b", null);
        expect(() => add("c", null)).toThrow();
        expect(() => db.raw.prepare("INSERT INTO mcp_settings (id, mode, updated_at) VALUES (2, 'off', 1)").run()).toThrow();
        expect(() => db.raw.prepare("INSERT INTO mcp_settings (id, mode, updated_at) VALUES (1, 'open', 1)").run()).toThrow();
    });
});
