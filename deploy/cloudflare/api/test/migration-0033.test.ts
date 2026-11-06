// d1/migrations/0033_safety_prep_rev.sql: one column on media_safety. Apply before the API
// deploy. A row that already exists comes out prep_rev 0, which is "failed on an older path".
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo32 = files.filter((f) => f < "0033").map(sql).join("\n");
const m33 = sql("0033_safety_prep_rev.sql");

describe("migration 0033", () => {
    it("comes right after 0032", () => {
        const at = files.indexOf("0033_safety_prep_rev.sql");
        expect(files[at - 1]).toBe("0032_safety.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0033").toBe(true);
    });

    it("is one additive column", () => {
        const stmts = m33
            .split("\n")
            .filter((l) => !l.trim().startsWith("--"))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toEqual(["ALTER TABLE media_safety ADD COLUMN prep_rev INTEGER NOT NULL DEFAULT 0"]);
    });

    it("leaves an existing row, with prep_rev 0, and old column lists still run", () => {
        const db = createFakeD1(upTo32);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, prep_attempts, updated_at) VALUES ('aaaabbbbccccdddd', 'pending', 'failed', 3, 1)").run();
        db.raw.exec(m33);
        expect(db.raw.prepare("SELECT level, prep, prep_attempts FROM media_safety").get()).toEqual({
            level: "pending",
            prep: "failed",
            prep_attempts: 3,
        });
        expect(db.raw.prepare("SELECT prep_rev FROM media_safety").get()).toEqual({ prep_rev: 0 });
    });
});
