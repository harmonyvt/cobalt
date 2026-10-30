// d1/migrations/0024_private_links.sql (APP-API-CONTRACT.md section 36.1): additive, applies cleanly on top of 0001-0023,
// keeps at most one live private link per file or gallery link, and one settings row. It is NOT applied to any remote
// database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const m24 = readFileSync(dir + "0024_private_links.sql", "utf8");
const statements = m24
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

describe("migration 0024", () => {
    it("is the next file after 0023", () => {
        const at = files.indexOf("0024_private_links.sql");
        expect(files[at - 1]).toBe("0023_mcp_links.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0024").toBe(true);
    });
    it("holds two new tables and one index, nothing else", () => {
        expect(statements).toHaveLength(3);
        expect(statements[0]).toMatch(/^CREATE TABLE private_links \(/);
        expect(statements[1]).toMatch(/^CREATE UNIQUE INDEX idx_private_links_live ON private_links/);
        expect(statements[2]).toMatch(/^CREATE TABLE share_settings \(/);
        for (const s of statements) expect(s).not.toMatch(/\b(DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW|ALTER)\b/i);
    });
    it("allows one live link per target, any number revoked, and one settings row", () => {
        const db = createFakeD1();
        const add = (key: string, kind: string, target: string, revoked: number | null) =>
            db.raw.prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at) VALUES (?, ?, ?, 1, ?)").run(key, kind, target, revoked);
        add("a", "item", "x", 5);
        add("b", "item", "x", 6);
        add("c", "item", "x", null);
        expect(() => add("d", "item", "x", null)).toThrow();
        add("e", "set", "x", null); // another kind is another target
        expect(() => add("f", "folder", "y", null)).toThrow();
        expect(() => db.raw.prepare("INSERT INTO share_settings (id, new_links, updated_at) VALUES (2, 'public', 1)").run()).toThrow();
        expect(() => db.raw.prepare("INSERT INTO share_settings (id, new_links, updated_at) VALUES (1, 'secret', 1)").run()).toThrow();
        db.raw.prepare("INSERT INTO share_settings (id, updated_at) VALUES (1, 1)").run();
        expect((db.raw.prepare("SELECT new_links FROM share_settings").get() as any).new_links).toBe("public");
    });
});
