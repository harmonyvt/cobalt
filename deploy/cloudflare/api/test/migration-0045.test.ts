// d1/migrations/0045_extension_pairings.sql (section 65.2): one new table. Renumbered from
// 0039_extension_pairings.sql, which production already applied on 2026-11-12, so a second apply is a no-op.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");

describe("migration 0045", () => {
    it("comes right after 0044", () => {
        const at = files.indexOf("0045_extension_pairings.sql");
        expect(files[at - 1]).toBe("0044_swarm_messages.sql");
        expect(files.some((f) => f.startsWith("0039_"))).toBe(false);
    });

    it("applies on top of every earlier migration, takes a pairing, and applies again", () => {
        const db = createFakeD1(files.filter((f) => f < "0045").map(sql).join("\n"));
        db.raw.exec(sql("0045_extension_pairings.sql"));
        db.raw
            .prepare(
                "INSERT INTO extension_pairings (device_hash, user_hash, challenge, state, device, email, created_at, expires_at) VALUES ('d', 'u', 'c', 's', 'Browser extension', NULL, 1, 2)",
            )
            .run();
        db.raw.exec(sql("0045_extension_pairings.sql"));
        expect(db.raw.prepare("SELECT device_hash, user_hash, expires_at FROM extension_pairings").get()).toEqual({
            device_hash: "d",
            user_hash: "u",
            expires_at: 2,
        });
    });
});
