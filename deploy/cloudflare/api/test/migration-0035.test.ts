// d1/migrations/0035_safety_prep_error.sql: one nullable column on media_safety.
// Apply before the API deploy. A row that already exists comes out prep_error NULL.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo34 = files.filter((f) => f < "0035").map(sql).join("\n");
const m35 = sql("0035_safety_prep_error.sql");

describe("migration 0035", () => {
    it("comes right after 0034", () => {
        const at = files.indexOf("0035_safety_prep_error.sql");
        expect(files[at - 1]).toBe("0034_stage_skip.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0035").toBe(true);
    });

    it("is one additive nullable column", () => {
        const stmts = m35
            .split("\n")
            .filter((l) => !l.trim().startsWith("--"))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toEqual(["ALTER TABLE media_safety ADD COLUMN prep_error TEXT"]);
    });

    it("leaves an existing row, with prep_error null", () => {
        const db = createFakeD1(upTo34);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, prep_attempts, prep_rev, updated_at) VALUES ('aaaabbbbccccdddd', 'pending', 'failed', 2, 1, 1)").run();
        db.raw.exec(m35);
        expect(db.raw.prepare("SELECT level, prep, prep_attempts, prep_rev, prep_error FROM media_safety").get()).toEqual({
            level: "pending",
            prep: "failed",
            prep_attempts: 2,
            prep_rev: 1,
            prep_error: null,
        });
    });
});
