// d1/migrations/0009_gallery.sql (APP-API-CONTRACT.md section 18.1): additive, applies cleanly on top of 0008 with data in
// every table, and the statements the code BEFORE this change ran (which name their columns) keep working on the
// migrated database, so it can be applied first and the Workers deployed after. It is NOT applied to any remote
// database by the tests (or by this lane): the owner runs it.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { POST_KEY_SQL } from "../src/app-routes";

const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = (name: string) => readFileSync(dir + name, "utf8");
const upTo8 = files.filter((f) => f < "0009").map(sql).join("\n");
const m9 = sql("0009_gallery.sql");
const cols = (db: any, table: string) => (db.raw.prepare(`PRAGMA table_info(${table})`).all() as any[]).map((c) => c.name);
const MEDIA_NEW = ["item_index", "role", "made_from", "made_spec", "post_key"];

describe("migration 0009", () => {
    it("is the next file after 0008", () => {
        const at = files.indexOf("0009_gallery.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]).toBe("0008_visibility.sql");
    });

    it("is additive only: nine nullable ADD COLUMNs and one index, nothing dropped, rewritten, defaulted, constrained or deleted", () => {
        const stmts = m9
            .split("\n")
            .map((l) => l.replace(/--.*$/, ""))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toHaveLength(10);
        for (const s of stmts) {
            expect(s).toMatch(/^(ALTER TABLE (media_items|studio_sessions|studio_renders) ADD COLUMN \w+ (TEXT|INTEGER)|CREATE INDEX \w+ ON media_items \(\w+(, \w+)?\))$/);
            expect(s).not.toMatch(/NOT NULL|DEFAULT|DROP|DELETE|UPDATE|RENAME|INSERT|UNIQUE|REFERENCES|CHECK/i);
        }
        const added = stmts.filter((s) => s.startsWith("ALTER")).map((s) => /ALTER TABLE (\w+) ADD COLUMN (\w+)/.exec(s)!.slice(1).join("."));
        expect(added).toEqual([
            "media_items.item_index",
            "media_items.role",
            "media_items.made_from",
            "media_items.made_spec",
            "media_items.post_key",
            "studio_sessions.item_count",
            "studio_sessions.items",
            "studio_renders.kind",
            "studio_renders.plan",
        ]);
        // (no index on post_key: the post key is a COALESCE over several columns, no lookup could use one)
        expect(stmts.filter((s) => s.startsWith("CREATE INDEX"))).toEqual([
            "CREATE INDEX idx_media_items_session_item ON media_items (session_id, item_index)",
        ]);
    });

    it("applies on top of 0008 with data in every table: every old row survives untouched, the new columns are NULL, the old indexes stay and the new ones exist", () => {
        const db = createFakeD1(upTo8);
        const r = db.raw;
        r.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES ('k1','a','h','p',1)").run();
        r.prepare("INSERT INTO request_log (ts, route, key_id, status) VALUES (1,'POST /','k1',200)").run();
        r.prepare(
            "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, duration, width, height, created_at, expires_at) VALUES ('S1','k1','https://x.com/a','x','t','ready','originals/S1.mp4','video/mp4',10,1.5,2,3,100,200)",
        ).run();
        r.prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES ('R1','S1','success',101)").run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, created_at, visibility, public_key, public_id) VALUES ('M1','private','saved','originals','originals/S1.mp4',NULL,'t','video/mp4',10,100,'public','Abcdefghij.mp4','P1')",
        ).run();
        r.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('S1','T','k1',1)").run();
        const before = {
            items: r.prepare("SELECT * FROM media_items ORDER BY id").all(),
            sessions: r.prepare("SELECT * FROM studio_sessions").all(),
            renders: r.prepare("SELECT * FROM studio_renders").all(),
            titles: r.prepare("SELECT * FROM media_titles").all(),
        };

        r.exec(m9); // what `cf d1 migrations apply` runs

        expect(cols(db, "media_items")).toEqual([...Object.keys(before.items[0] as object), ...MEDIA_NEW]);
        expect(cols(db, "studio_sessions")).toEqual([...Object.keys(before.sessions[0] as object), "item_count", "items"]);
        expect(cols(db, "studio_renders")).toEqual([...Object.keys(before.renders[0] as object), "kind", "plan"]);
        const strip = (rows: any[], drop: string[]) => rows.map((x) => Object.fromEntries(Object.entries(x).filter(([k]) => !drop.includes(k))));
        expect(strip(r.prepare("SELECT * FROM media_items ORDER BY id").all(), MEDIA_NEW)).toEqual(before.items);
        expect(strip(r.prepare("SELECT * FROM studio_sessions").all(), ["item_count", "items"])).toEqual(before.sessions);
        expect(strip(r.prepare("SELECT * FROM studio_renders").all(), ["kind", "plan"])).toEqual(before.renders);
        expect(r.prepare("SELECT * FROM media_titles").all()).toEqual(before.titles);
        expect(r.prepare(`SELECT ${MEDIA_NEW.join(", ")} FROM media_items`).all()).toEqual([{ item_index: null, role: null, made_from: null, made_spec: null, post_key: null }]);
        expect(r.prepare("SELECT item_count, items FROM studio_sessions").all()).toEqual([{ item_count: null, items: null }]);
        expect(r.prepare("SELECT kind, plan FROM studio_renders").all()).toEqual([{ kind: null, plan: null }]);
        expect((r.prepare("SELECT count(*) AS n FROM api_keys").get() as any).n).toBe(1);
        const idx = (r.prepare("PRAGMA index_list(media_items)").all() as any[]).map((i) => i.name);
        for (const name of ["idx_media_items_listing", "idx_media_items_session", "idx_media_items_object", "idx_media_items_public_id", "idx_media_items_public_key", "idx_media_items_session_item"]) {
            expect(idx).toContain(name);
        }
    });

    it("the statements the code BEFORE this change ran still work on the migrated database (so it can be applied first, deployed after)", () => {
        const db = createFakeD1(); // every migration
        const r = db.raw;
        // old insertMediaItem (18 named columns), old upload insert, old session / render inserts, old reads
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster, visibility) VALUES ('M1','private','saved','originals','k',NULL,'n','video/mp4',1,2,3,4,NULL,NULL,NULL,5,NULL,'private')",
        ).run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, key_id, created_at, visibility) VALUES ('M2','private','upload','originals','u',NULL,'n','video/mp4',1,'k',5,'private')",
        ).run();
        r.prepare("INSERT INTO studio_sessions (id, key_id, link, service, status, created_at, expires_at, public_state) VALUES ('S1','k','https://x.com/a','x','saving',1,2,NULL)").run();
        r.prepare("INSERT INTO studio_renders (id, session_id, status, start, length, width, quality, created_at) VALUES ('R1','S1','pending',0,2,480,'med',1)").run();
        r.prepare("UPDATE studio_sessions SET status = 'ready', error_code = NULL, r2_key = 'k', content_type = 'video/mp4', bytes = 1, duration = 1, width = 1, height = 1, title = 't' WHERE id = 'S1' AND status = 'saving'").run();
        r.prepare("UPDATE media_items SET deleted_at = 9 WHERE bucket = 'originals' AND r2_key = 'k' AND deleted_at IS NULL").run();
        expect(r.prepare("SELECT * FROM studio_renders WHERE session_id = 'S1' AND status = 'pending'").all()).toHaveLength(1);
        expect(r.prepare("SELECT * FROM media_items WHERE id = 'M1'").get()).toMatchObject({ deleted_at: 9, role: null, item_index: null, made_from: null, made_spec: null, post_key: null });
        expect(r.prepare("SELECT * FROM studio_sessions WHERE id = 'S1'").get()).toMatchObject({ item_count: null, items: null });
    });

    it("the post key before and after: a row with post_key NULL groups as it always did, one with post_key set groups there", () => {
        const db = createFakeD1();
        const r = db.raw;
        const ins = (id: string, session: string | null, link: string | null, postKey: string | null) =>
            r.prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, session_id, link, created_at, post_key) VALUES (?, 'private','saved','originals',?, 'n', ?, ?, 1, ?)").run(id, `k/${id}`, session, link, postKey);
        r.prepare("INSERT INTO studio_sessions (id, link, status, created_at, expires_at) VALUES ('UP1', 'upload:ITEM1', 'ready', 1, 2)").run();
        ins("a", "S1", "https://x/1", null); // a link post: its session
        ins("b", null, "https://x/2", null); // no session: its link
        ins("c", null, null, null); // neither: its own id
        ins("d", "UP1", null, null); // a render of an upload: the upload's id
        ins("e", "S9", "https://x/9", "GALLERY"); // names its post
        ins("f", null, null, "ITEM1"); // a made row of an upload
        const keys = Object.fromEntries((r.prepare(`SELECT m.id, ${POST_KEY_SQL} AS k FROM media_items m`).all() as any[]).map((x) => [x.id, x.k]));
        expect(keys).toEqual({ a: "S1", b: "https://x/2", c: "c", d: "ITEM1", e: "GALLERY", f: "ITEM1" });
    });

    it("the whole set applies in order on an empty database (what a fresh install and the tests run)", () => {
        const db = createFakeD1();
        expect(cols(db, "media_items")).toEqual(expect.arrayContaining(MEDIA_NEW));
        expect(cols(db, "studio_sessions")).toEqual(expect.arrayContaining(["item_count", "items"]));
        expect(cols(db, "studio_renders")).toEqual(expect.arrayContaining(["kind", "plan"]));
    });
});
