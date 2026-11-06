// d1/migrations/0034_stage_skip.sql: stage_rewards.action may be 'skip'. The table is rebuilt
// because SQLite cannot change a CHECK. Existing reward rows are copied. Apply before the API deploy.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo33 = files.filter((f) => f < "0034").map(sql).join("\n");
const m34 = sql("0034_stage_skip.sql");

const insert = (db: ReturnType<typeof createFakeD1>, action: string) =>
    db.raw
        .prepare(
            "INSERT INTO stage_rewards (action, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at) VALUES (?, ?, 'p', 10, 1, 1, 0, 5)",
        )
        .run(action, action);

describe("migration 0034", () => {
    it("comes right after 0033", () => {
        const at = files.indexOf("0034_stage_skip.sql");
        expect(files[at - 1]).toBe("0033_safety_prep_rev.sql");
        expect(files[at + 1] === undefined || files[at + 1]! > "0034").toBe(true);
    });

    it("copies the rewards that are already there and then allows skip", () => {
        const db = createFakeD1(upTo33);
        insert(db, "summon");
        expect(() => insert(db, "skip")).toThrow();
        db.raw.exec(m34);
        expect(db.raw.prepare("SELECT action, title, cost, updated_at FROM stage_rewards").get()).toEqual({
            action: "summon",
            title: "summon",
            cost: 10,
            updated_at: 5,
        });
        insert(db, "skip");
        expect(db.raw.prepare("SELECT action FROM stage_rewards ORDER BY action").all()).toEqual([{ action: "skip" }, { action: "summon" }]);
        expect(() => insert(db, "nope")).toThrow();
    });
});
