// d1/migrations/0008_visibility.sql (APP-API-CONTRACT.md section 16): additive, applies cleanly on top of
// 0007 with data in every table, and the statements the code BEFORE this change ran (which name their
// columns) keep working on the migrated database, so it can be applied first and the Workers deployed after.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo7 = files.filter((f) => f < "0008").map(sql).join("\n");
const m8 = sql("0008_visibility.sql");
const cols = (db: any, table: string) => (db.raw.prepare(`PRAGMA table_info(${table})`).all() as any[]).map((c) => c.name);

describe("migration 0008", () => {
    it("is the next file after 0007", () => {
        const at = files.indexOf("0008_visibility.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]).toBe("0007_titles.sql");
    });

    it("is additive only: four nullable ADD COLUMNs and two indexes, nothing dropped, rewritten, defaulted or deleted", () => {
        const stmts = m8
            .split("\n")
            .filter((l) => !l.trim().startsWith("--"))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toHaveLength(6);
        for (const s of stmts) {
            expect(s).toMatch(/^(ALTER TABLE media_items ADD COLUMN \w+ TEXT|CREATE INDEX \w+ ON media_items \(\w+\))$/);
            expect(s).not.toMatch(/NOT NULL|DEFAULT|DROP|DELETE|UPDATE|RENAME|INSERT/i);
        }
        expect(stmts.filter((s) => s.startsWith("ALTER")).map((s) => /COLUMN (\w+)/.exec(s)![1])).toEqual(["visibility", "public_key", "public_id", "merged_into"]);
    });

    it("applies on top of 0007 with data in every table: every old row survives untouched and the four new columns are NULL; the old indexes stay and the new ones exist", () => {
        const db = createFakeD1(upTo7);
        const r = db.raw;
        r.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES ('k1','a','h','p',1)").run();
        r.prepare("INSERT INTO request_log (ts, route, key_id, status) VALUES (1,'POST /','k1',200)").run();
        r.prepare(
            "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, duration, width, height, created_at, expires_at) VALUES ('S1','k1','https://x.com/a','x','t','ready','originals/S1.mp4','video/mp4',10,1.5,2,3,100,200)",
        ).run();
        r.prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES ('R1','S1','success',101)").run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, created_at) VALUES ('M1','private','saved','originals','originals/S1.mp4',NULL,'t','video/mp4',10,100)",
        ).run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, session_id, created_at) VALUES ('H1','public','host','media','Abcdefghij.mp4','https://m/Abcdefghij.mp4','t.mp4','video/mp4',10,'S1',101)",
        ).run();
        r.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('S1','T','k1',1)").run();
        const before = {
            items: r.prepare("SELECT * FROM media_items ORDER BY id").all(),
            sessions: r.prepare("SELECT * FROM studio_sessions").all(),
            renders: r.prepare("SELECT * FROM studio_renders").all(),
            titles: r.prepare("SELECT * FROM media_titles").all(),
        };

        r.exec(m8); // what `cf d1 migrations apply` runs

        expect(cols(db, "media_items")).toEqual([...Object.keys(before.items[0] as object), "visibility", "public_key", "public_id", "merged_into"]);
        const strip = (rows: any[]) => rows.map((x) => Object.fromEntries(Object.entries(x).filter(([k]) => !["visibility", "public_key", "public_id", "merged_into"].includes(k))));
        expect(strip(r.prepare("SELECT * FROM media_items ORDER BY id").all())).toEqual(before.items);
        expect(r.prepare("SELECT visibility, public_key, public_id, merged_into FROM media_items").all()).toEqual([
            { visibility: null, public_key: null, public_id: null, merged_into: null },
            { visibility: null, public_key: null, public_id: null, merged_into: null },
        ]);
        expect(r.prepare("SELECT * FROM studio_sessions").all()).toEqual(before.sessions);
        expect(r.prepare("SELECT * FROM studio_renders").all()).toEqual(before.renders);
        expect(r.prepare("SELECT * FROM media_titles").all()).toEqual(before.titles);
        expect((r.prepare("SELECT count(*) AS n FROM api_keys").get() as any).n).toBe(1);
        const idx = (r.prepare("PRAGMA index_list(media_items)").all() as any[]).map((i) => i.name);
        for (const name of ["idx_media_items_listing", "idx_media_items_session", "idx_media_items_object", "idx_media_items_public_id", "idx_media_items_public_key"]) {
            expect(idx).toContain(name);
        }
    });

    it("the statements the code BEFORE this change ran still work on the migrated database (so it can be applied first, deployed after)", () => {
        const db = createFakeD1(); // every migration
        const r = db.raw;
        // old insertMediaItem (17 named columns), old upload insert, old publish insert, old soft delete
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster) VALUES ('M1','private','saved','originals','k',NULL,'n','video/mp4',1,2,3,4,NULL,NULL,NULL,5,NULL)",
        ).run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, key_id, created_at) VALUES ('M2','private','upload','originals','u',NULL,'n','video/mp4',1,'k',5)",
        ).run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster) VALUES ('H1','public','host','media','h.mp4','u','n','video/mp4',1,2,3,4,NULL,NULL,'k',5,NULL)",
        ).run();
        r.prepare("UPDATE media_items SET deleted_at = 9 WHERE bucket = 'originals' AND r2_key = 'k' AND deleted_at IS NULL").run();
        // the old list query's grouping, the old usage query
        expect(r.prepare("SELECT kind, COALESCE(SUM(bytes), 0) AS total FROM media_items WHERE deleted_at IS NULL GROUP BY kind").all()).toHaveLength(2);
        expect(r.prepare("SELECT * FROM media_items WHERE id = 'M1'").get()).toMatchObject({ deleted_at: 9, visibility: null, public_key: null, public_id: null, merged_into: null });
    });

    it("the whole set applies in order on an empty database (what a fresh install and the tests run)", () => {
        const db = createFakeD1();
        expect(cols(db, "media_items")).toEqual(expect.arrayContaining(["visibility", "public_key", "public_id", "merged_into"]));
    });
});
