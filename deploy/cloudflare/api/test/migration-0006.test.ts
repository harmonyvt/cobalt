// d1/migrations/0006_posters_public.sql (APP-API-CONTRACT.md section 13): additive, applies
// cleanly on top of 0005 with data in every table, and old statements (the ones the code before
// this change ran, which name their columns) keep working on the migrated database.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo5 = files.filter((f) => f < "0006").map(sql).join("\n");
const m6 = sql("0006_posters_public.sql");

const cols = (db: any, table: string) => (db.raw.prepare(`PRAGMA table_info(${table})`).all() as any[]).map((c) => c.name);

describe("migration 0006", () => {
    it("is the next file after 0005, and the last one", () => {
        expect(files.slice(-2)).toEqual(["0005_telemetry.sql", "0006_posters_public.sql"]);
    });

    it("is additive only: nullable ADD COLUMNs and an index, nothing dropped, rewritten or deleted", () => {
        const stmts = m6
            .split("\n")
            .filter((l) => !l.trim().startsWith("--"))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toHaveLength(6);
        for (const s of stmts) {
            expect(s).toMatch(/^(ALTER TABLE \w+ ADD COLUMN \w+ (TEXT|INTEGER)|CREATE INDEX \w+ ON \w+ \([\w, ]+\))$/);
            expect(s).not.toMatch(/NOT NULL|DEFAULT|DROP|DELETE|UPDATE|RENAME/i);
        }
    });

    it("applies on top of 0005 with data in every table: every old row survives untouched and the new columns are NULL", () => {
        const db = createFakeD1(upTo5);
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
        r.prepare("INSERT INTO telemetry_events (id, ts, level, cat, msg, received_at) VALUES ('E1',1,'info','app','m',1)").run();
        const before = {
            session: r.prepare("SELECT * FROM studio_sessions").all(),
            item: r.prepare("SELECT * FROM media_items").all(),
            render: r.prepare("SELECT * FROM studio_renders").all(),
        };

        r.exec(m6); // what `cf d1 migrations apply` runs

        expect(cols(db, "media_items")).toEqual([...Object.keys(before.item[0] as object), "poster", "poster_at"]);
        expect(cols(db, "studio_sessions")).toEqual([...Object.keys(before.session[0] as object), "poster", "public_state", "public_url"]);
        const strip = (rows: any[], extra: string[]) => rows.map((x) => Object.fromEntries(Object.entries(x).filter(([k]) => !extra.includes(k))));
        expect(strip(r.prepare("SELECT * FROM studio_sessions").all(), ["poster", "public_state", "public_url"])).toEqual(before.session);
        expect(strip(r.prepare("SELECT * FROM media_items").all(), ["poster", "poster_at"])).toEqual(before.item);
        expect(r.prepare("SELECT * FROM studio_renders").all()).toEqual(before.render);
        expect(r.prepare("SELECT poster, poster_at FROM media_items").get()).toEqual({ poster: null, poster_at: null });
        expect(r.prepare("SELECT poster, public_state, public_url FROM studio_sessions").get()).toEqual({ poster: null, public_state: null, public_url: null });
        expect((r.prepare("SELECT count(*) AS n FROM telemetry_events").get() as any).n).toBe(1);
        expect((r.prepare("SELECT count(*) AS n FROM api_keys").get() as any).n).toBe(1);
        const idx = (r.prepare("PRAGMA index_list(media_items)").all() as any[]).map((i) => i.name);
        expect(idx).toContain("idx_media_items_object");
        expect(idx).toContain("idx_media_items_listing"); // the old ones stay
        expect(idx).toContain("idx_media_items_session");
    });

    it("the statements the code BEFORE this change ran still work on the migrated database (so it can be applied first, deployed after)", () => {
        const db = createFakeD1(); // every migration
        const r = db.raw;
        // old insertMediaItem / upload / publish: 16 named columns, no poster
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at) VALUES ('M1','private','saved','originals','k',NULL,'n','video/mp4',1,2,3,4,NULL,NULL,NULL,5)",
        ).run();
        r.prepare(
            "INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at) VALUES ('S1','k','https://x.com/a','x','saving',1,2)",
        ).run();
        r.prepare(
            "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, created_at, expires_at) VALUES ('S2','k','upload:M1','upload','a.mp4','saving','uploads/M1.mp4','video/mp4',10,1,2)",
        ).run();
        r.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'e' WHERE id = 'S1' AND status = 'saving'").run();
        r.prepare(
            "UPDATE studio_sessions SET status = 'ready', error_code = NULL, r2_key = 'originals/S1.mp4', content_type = 'video/mp4', bytes = 1, duration = 1, width = 1, height = 1, title = 't' WHERE id = 'S2' AND status = 'saving'",
        ).run();
        r.prepare("UPDATE media_items SET deleted_at = 9 WHERE bucket = 'originals' AND r2_key = 'k' AND deleted_at IS NULL").run();
        expect(r.prepare("SELECT * FROM media_items WHERE id = 'M1'").get()).toMatchObject({ deleted_at: 9, poster: null });
    });

    it("the whole set applies in order on an empty database (what a fresh install and the tests run)", () => {
        const db = createFakeD1();
        expect(cols(db, "media_items")).toContain("poster_at");
        expect(cols(db, "studio_sessions")).toContain("public_state");
    });
});
