// d1/migrations/0036_post_details.sql (section 52.1): one new table, nothing else touched.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");

describe("migration 0036", () => {
    it("comes right after 0035", () => {
        const at = files.indexOf("0036_post_details.sql");
        expect(files[at - 1]).toBe("0035_safety_prep_error.sql");
    });

    it("applies on top of every earlier migration and takes a row", () => {
        const db = createFakeD1(files.filter((f) => f < "0037").map(sql).join("\n"));
        db.raw
            .prepare("INSERT INTO post_details (link, site, found, name, counts, fetched_at) VALUES ('https://x.com/a/status/1', 'x', 1, 'mochi', '{\"likes\":3}', 5)")
            .run();
        expect(db.raw.prepare("SELECT site, found, name, verified, edited_at FROM post_details").get()).toEqual({ site: "x", found: 1, name: "mochi", verified: 0, edited_at: null });
    });
});
