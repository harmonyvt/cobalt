// d1/migrations/0044_swarm_messages.sql (section 61.1): one new table and three new columns on swarm_tasks (steps, asked_at; stats for 62.3), nothing else.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");

describe("migration 0044", () => {
    it("comes right after 0043", () => {
        const at = files.indexOf("0044_swarm_messages.sql");
        expect(files[at - 1]).toBe("0043_swarms.sql");
    });

    it("applies on top of every earlier migration, keeps the tasks it finds, and takes messages", () => {
        const db = createFakeD1(files.filter((f) => f < "0044").map(sql).join("\n"));
        db.raw.prepare("INSERT INTO swarm_tasks (swarm, idx, items) VALUES ('S', 0, '[]')").run();
        db.raw.exec(sql("0044_swarm_messages.sql"));
        expect(db.raw.prepare("SELECT status, steps, asked_at, stats FROM swarm_tasks").get()).toEqual({ status: "queued", steps: null, asked_at: null, stats: null });
        db.raw.prepare("INSERT INTO swarm_messages (swarm, task, dir, kind, sender, text, created_at) VALUES ('S', 0, 'up', 'ask', 'agent', 'which set?', 5)").run();
        db.raw.prepare("INSERT INTO swarm_messages (swarm, task, dir, kind, sender, text, created_at) VALUES ('S', NULL, 'down', 'note', 'you', 'all: go on', 6)").run();
        expect(db.raw.prepare("SELECT id, task, dir, kind, read_at, answered_at FROM swarm_messages ORDER BY id").all()).toEqual([
            { id: 1, task: 0, dir: "up", kind: "ask", read_at: null, answered_at: null },
            { id: 2, task: null, dir: "down", kind: "note", read_at: null, answered_at: null },
        ]);
    });
});
