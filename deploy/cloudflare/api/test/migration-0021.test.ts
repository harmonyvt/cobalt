// d1/migrations/0021_edits.sql (APP-API-CONTRACT.md section 31.7): additive, applies cleanly on top of 0020 with data in every
// table, and holds only CREATE TABLE and CREATE INDEX. It is NOT applied to any remote database by the tests: the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo20 = files.filter((f) => f < "0021").map(sql).join("\n");
const m21 = sql("0021_edits.sql");
const statements = m21
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);
const cols = (db: any, table: string) => (db.raw.prepare(`PRAGMA table_info(${table})`).all() as any[]).map((c) => c.name);
const tables = (db: any) => (db.raw.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as any[]).map((r) => r.name);
const indexes = (db: any) => (db.raw.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%' ORDER BY name").all() as any[]).map((r) => r.name);

describe("migration 0021", () => {
    it("is the next file after 0020", () => {
        const at = files.indexOf("0021_edits.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]).toBe("0020_stage_sound_all.sql");
        expect(files[at + 1]).toBeUndefined();
    });

    it("holds only CREATE TABLE and CREATE INDEX: two tables, three indexes, nothing existing touched", () => {
        expect(statements).toHaveLength(5);
        for (const s of statements) {
            expect(s).toMatch(/^CREATE (TABLE edit_(projects|renders) \(|INDEX idx_edit_(projects|renders)_\w+ ON edit_(projects|renders) \()/);
            expect(s).not.toMatch(/\b(ALTER|DROP|DELETE|UPDATE|INSERT|RENAME|REPLACE|PRAGMA|TRIGGER|VIEW)\b/i);
        }
        expect(statements.filter((s) => s.startsWith("CREATE TABLE")).map((s) => /CREATE TABLE (\w+)/.exec(s)![1])).toEqual(["edit_projects", "edit_renders"]);
        expect(statements.filter((s) => s.startsWith("CREATE INDEX")).map((s) => /CREATE INDEX (\w+)/.exec(s)![1])).toEqual([
            "idx_edit_projects_listing",
            "idx_edit_renders_status",
            "idx_edit_renders_project",
        ]);
    });

    it("applies on top of 0020 with data in the existing tables: every old row survives, the old tables and indexes are as they were", () => {
        const db = createFakeD1(upTo20);
        const r = db.raw;
        r.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES ('k1','a','h','p',1)").run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, created_at) VALUES ('Item000000000001','private','upload','originals','originals/x.mp4','x.mp4','video/mp4',1)",
        ).run();
        r.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('Item000000000001','t','k1',1)").run();
        const before = tables(db);
        const mediaCols = cols(db, "media_items");
        const oldIndexes = indexes(db);
        r.exec(m21);
        expect(tables(db)).toEqual([...before, "edit_projects", "edit_renders"].sort());
        expect(cols(db, "media_items")).toEqual(mediaCols);
        expect(oldIndexes.every((i) => indexes(db).includes(i))).toBe(true);
        expect(r.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 1 });
        expect(r.prepare("SELECT COUNT(*) AS n FROM api_keys").get()).toEqual({ n: 1 });
        expect(r.prepare("SELECT COUNT(*) AS n FROM media_titles").get()).toEqual({ n: 1 });
        // the new tables are empty and take rows
        expect(r.prepare("SELECT COUNT(*) AS n FROM edit_projects").get()).toEqual({ n: 0 });
        expect(indexes(db)).toEqual(expect.arrayContaining(["idx_edit_projects_listing", "idx_edit_renders_status", "idx_edit_renders_project"]));
    });

    it("has the columns of 31.7, in order, with the defaults the code relies on", () => {
        const db = createFakeD1(`${upTo20}\n${m21}`);
        expect(cols(db, "edit_projects")).toEqual([
            "id", "title", "timeline", "revision", "canvas_w", "canvas_h", "fps", "frames", "clip_count", "cover_item", "key_id", "updated_key",
            "created_at", "updated_at", "deleted_at",
        ]);
        expect(cols(db, "edit_renders")).toEqual([
            "id", "project_id", "revision", "title", "timeline", "status", "cancel_requested", "instance", "attempts", "input_bytes", "sent_bytes",
            "seconds_done", "seconds_total", "error_code", "item_id", "bytes", "width", "height", "duration", "notify", "notified_at", "key_id",
            "created_at", "started_at", "updated_at", "finished_at",
        ]);
        const r = db.raw;
        r.prepare(
            "INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, seconds_total, created_at, updated_at) VALUES ('R','P',1,'t','{}','queued',9,1,1)",
        ).run();
        expect(r.prepare("SELECT cancel_requested, attempts, notify, instance, notified_at FROM edit_renders").get()).toEqual({
            cancel_requested: 0,
            attempts: 0,
            notify: 0,
            instance: null,
            notified_at: null,
        });
        // NOT NULL where the spec says so
        expect(() => r.prepare("INSERT INTO edit_projects (id) VALUES ('x')").run()).toThrow();
        expect(() => r.prepare("INSERT INTO edit_renders (id) VALUES ('x')").run()).toThrow();
    });

    it("the claim statement of 31.8 runs on it: oldest first, once", () => {
        const db = createFakeD1(`${upTo20}\n${m21}`);
        const r = db.raw;
        const ins = r.prepare("INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, seconds_total, created_at, updated_at) VALUES (?, 'P', 1, 't', '{}', 'queued', 9, ?, ?)");
        ins.run("B", 20, 20);
        ins.run("A", 10, 10);
        const claim = r.prepare(
            `UPDATE edit_renders SET status = 'preparing', instance = ?1, attempts = attempts + 1, started_at = ?2, updated_at = ?2
              WHERE id = (SELECT id FROM edit_renders WHERE status = 'queued' AND cancel_requested = 0 ORDER BY created_at, id LIMIT 1)
                AND status = 'queued'
          RETURNING *`,
        );
        expect((claim.get("r0", 99) as any).id).toBe("A");
        expect((claim.get("r1", 99) as any).id).toBe("B");
        expect(claim.get("r0", 99)).toBeUndefined();
    });
});
