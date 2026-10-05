// POST /library/visibility/migrate (apple/CONTRACT-VISIBILITY.md section 4): the data step that turns
// the old "private original + public host copy" pairs into one row each, on a database shaped like
// production (6 pairs: 5 saved + 1 upload; 51 private-only; 29 webps). Real SQL on node:sqlite over
// every migration, fake buckets; the step writes D1 only and never touches an object.
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { auth, svc, world, type World } from "./poster-world";
import { allRows, assertInvariants, liveRows, listAll, migrate, patchVisibility, seedProduction, stubPurge } from "./visibility-fixture";

let w: World;
let fx: ReturnType<typeof seedProduction>;
const snapshot = () => ({
    items: allRows(w),
    sessions: w.db.raw.prepare("SELECT * FROM studio_sessions ORDER BY id").all(),
    originals: [...w.originals.objects.keys()].sort(),
    media: [...w.media.objects.keys()].sort(),
});
const stripNew = (rows: any[]) => rows.map(({ visibility, public_key, public_id, merged_into, ...rest }) => rest);

beforeEach(async () => {
    w = world();
    await w.addKey();
    fx = seedProduction(w);
    w.clock.t += 1000;
});
afterEach(() => stubPurge(w).restore());

describe("dry run (the default)", () => {
    it("reports exactly today's numbers: 6 pairs (5 saved + 1 upload), 0 skipped; 92 rows become 86 files, 35 public / 51 private, 6 tombstones", async () => {
        const r = await migrate(w, "dry_run=1&limit=100");
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ status: "success", dry_run: true, undo: false, remaining: 0 });
        expect(r.body.report).toEqual({
            rows_live: 92,
            originals: 57,
            hosts_live: 6,
            webps: 29,
            merge: { pairs: 6, saved: 5, upload: 1, already_merged: 0 },
            skipped: { no_original: 0, several_originals: 0, several_hosts: 0, object_missing: 0, size_mismatch: 0, storage_error: 0 },
            after: { rows_live: 86, public: 35, private: 51, tombstones: 6 },
            visibility_unset: 92,
            posters_missing: 0,
            r2_writes: 0,
            r2_deletes: 0,
        });
        expect(r.body.items).toEqual(
            fx.pairs.map((p) => ({ host: p.host, original: p.orig, url: p.url, action: "merge" })),
        );
    });

    it("is the default: no query at all is a dry run, and it writes nothing (no row, no session, no object)", async () => {
        const before = snapshot();
        const r = await migrate(w, "");
        expect(r.body.dry_run).toBe(true);
        expect(snapshot()).toEqual(before);
        expect(w.media.puts).toHaveLength(0);
        expect(w.media.deletes).toHaveLength(0);
    });

    it("only an explicit dry_run=0 (or false) writes; junk values and bad limits are 400", async () => {
        for (const q of ["dry_run=2", "dry_run=", "dry_run=yes", "limit=0", "limit=101", "limit=abc", "limit=", "undo=2"]) {
            const r = await migrate(w, q);
            expect(r.status, q).toBe(400);
            expect(r.body).toEqual({ status: "error", error: { code: "error.library.bad_request" } });
        }
        expect(snapshot().items.every((i: any) => i.merged_into === null)).toBe(true);
    });

    it("needs a key or the service credential; no key is 401", async () => {
        expect((await migrate(w, "", {})).status).toBe(401);
        expect((await migrate(w, "", svc)).status).toBe(200);
    });
});

describe("apply (dry_run=0)", () => {
    it("merges the six pairs: the original takes the host's file, URL and id; the host row is retired as a tombstone; sessions say ready; every unset row gets its visibility", async () => {
        const before = snapshot();
        const r = await migrate(w, "dry_run=0&limit=100");
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ dry_run: false, remaining: 0, report: { processed: 6, backfilled: 80 } });

        for (const p of fx.pairs) {
            const o = w.item(p.orig);
            expect(o).toMatchObject({ visibility: "public", public_key: p.key, public_id: p.host, url: p.url, kind: "private", bucket: "originals", deleted_at: null });
            const h = w.item(p.host);
            expect(h.deleted_at).not.toBeNull();
            expect(h.merged_into).toBe(p.orig);
            expect(w.session(p.sid)).toMatchObject({ public_state: "ready", public_url: p.url });
        }
        const live = liveRows(w);
        expect(live).toHaveLength(86);
        expect(live.filter((x) => x.visibility === "public")).toHaveLength(35);
        expect(live.filter((x) => x.visibility === "private")).toHaveLength(51);
        expect(live.filter((x) => x.visibility === null)).toHaveLength(0);
        assertInvariants(w);

        // no object moved, copied or deleted
        const after = snapshot();
        expect(after.originals).toEqual(before.originals);
        expect(after.media).toEqual(before.media);
        expect(w.media.puts).toHaveLength(0);
        expect(w.media.deletes).toHaveLength(0);
        // the rows other than the 6 + 6 are untouched apart from their visibility
        const touched = new Set(fx.pairs.flatMap((p) => [p.orig, p.host]));
        const pick = (rows: any[]) => stripNew(rows.filter((x) => !touched.has(x.id)));
        expect(pick(after.items)).toEqual(pick(before.items));
    });

    it("is idempotent: a second run changes nothing and reports the six as already merged", async () => {
        await migrate(w, "dry_run=0&limit=100");
        const once = snapshot();
        const again = await migrate(w, "dry_run=0&limit=100");
        expect(again.status).toBe(200);
        expect(again.body.report.merge).toEqual({ pairs: 0, saved: 0, upload: 0, already_merged: 6 });
        expect(again.body.report.skipped).toEqual({ no_original: 0, several_originals: 0, several_hosts: 0, object_missing: 0, size_mismatch: 0, storage_error: 0 });
        expect(again.body.report).toMatchObject({ rows_live: 86, visibility_unset: 0, r2_writes: 0, r2_deletes: 0 });
        expect(again.body.items.map((i: any) => i.action)).toEqual(new Array(6).fill("already_merged"));
        expect(snapshot()).toEqual(once);
    });

    it("pages with `limit`: 2 pairs per call, remaining 4 / 2 / 0, and the visibility backfill runs once after the last page", async () => {
        const unset = () => (w.db.raw.prepare("SELECT COUNT(*) AS n FROM media_items WHERE visibility IS NULL AND deleted_at IS NULL").get() as any).n;
        const a = await migrate(w, "dry_run=0&limit=2");
        expect(a.body).toMatchObject({ remaining: 4, report: { processed: 2 } });
        expect(unset()).toBeGreaterThan(0);
        const b = await migrate(w, "dry_run=0&limit=2");
        expect(b.body).toMatchObject({ remaining: 2, report: { processed: 2 } });
        expect(unset()).toBeGreaterThan(0);
        const c = await migrate(w, "dry_run=0&limit=2");
        expect(c.body).toMatchObject({ remaining: 0, report: { processed: 2 } });
        expect(unset()).toBe(0);
        expect(liveRows(w)).toHaveLength(86);
        assertInvariants(w);
    });

    it("a dry run with a small limit lists that page and says how many remain", async () => {
        const r = await migrate(w, "dry_run=1&limit=4");
        expect(r.body.items).toHaveLength(4);
        expect(r.body.remaining).toBe(2);
        expect(r.body.report.merge.pairs).toBe(6); // the whole picture, not the page
    });

    it("is all-or-nothing per pair: a statement that fails rolls the pair back (503), later pairs are not started", async () => {
        const before = snapshot();
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            const st = orig(sql);
            if (!/UPDATE studio_sessions SET public_state = 'ready'/.test(sql)) return st;
            return { ...st, bind: (...a: unknown[]) => ({ ...st.bind(...a), run: async () => { throw new Error("D1_ERROR: boom"); } }) };
        };
        const r = await migrate(w, "dry_run=0&limit=100");
        expect(r.status).toBe(503);
        (w.db as any).prepare = orig;
        // the first pair's first two statements ran inside the transaction and were rolled back
        expect(snapshot()).toEqual(before);
        // and the retry (nothing broken) finishes the job
        expect((await migrate(w, "dry_run=0&limit=100")).body.report.processed).toBe(6);
    });
});

describe("what is skipped (and reported, never guessed)", () => {
    const only = (r: any, reason: string) => {
        expect(r.body.report.skipped[reason]).toBe(1);
        expect(r.body.report.merge.pairs).toBe(5);
        expect(r.body.items.find((i: any) => i.action === `skip:${reason}`)).toBeTruthy();
    };

    it("no_original: a host whose session has no live original (an image hosted from an upload, a vanished session)", async () => {
        const p = fx.pairs[0]!;
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(p.orig);
        only(await migrate(w), "no_original");
        w.db.raw.prepare("UPDATE media_items SET deleted_at = NULL WHERE id = ?").run(p.orig);
        w.db.raw.prepare("UPDATE media_items SET session_id = NULL WHERE id = ?").run(p.host);
        only(await migrate(w), "no_original");
    });
    it("several_originals: one host that reaches two live originals", async () => {
        const p = fx.pairs[1]!;
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, bytes, created_at) VALUES ('DupOriginal00001','private','saved','originals',?,'dup',?, 5)")
            .run(w.item(p.orig).r2_key, p.bytes);
        only(await migrate(w), "several_originals");
    });
    it("several_hosts: two host copies of one original are left alone (every shared link must keep working; the newest is NOT picked)", async () => {
        const p = fx.pairs[2]!;
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, bytes, session_id, created_at) VALUES ('SecondHost000001','public','host','media','Second0001.mp4','https://media.capybaraharmony.com/Second0001.mp4','x',?,?,9)")
            .run(p.bytes, p.sid);
        w.media.objects.set("Second0001.mp4", { bytes: p.bytes, meta: {}, data: new Uint8Array(p.bytes), viaStream: true });
        const r = await migrate(w);
        // the original with two hosts is skipped once per host (two skips), the other five pairs merge
        expect(r.body.report.skipped.several_hosts).toBe(2);
        expect(r.body.report.merge.pairs).toBe(5);
        const applied = await migrate(w, "dry_run=0&limit=100");
        expect(applied.body.report.processed).toBe(5);
        expect(w.item(p.orig)).toMatchObject({ public_key: null, url: null });
        expect(w.item(p.host).deleted_at).toBeNull(); // both hosts still live and listed
        expect(w.item("SecondHost000001").deleted_at).toBeNull();
    });
    it("object_missing: the public object, or the original's, is gone", async () => {
        const p = fx.pairs[3]!;
        w.media.objects.delete(p.key);
        only(await migrate(w), "object_missing");
        w.media.objects.set(p.key, { bytes: p.bytes, meta: {}, data: new Uint8Array(p.bytes), viaStream: true });
        w.originals.objects.delete(w.item(p.orig).r2_key);
        only(await migrate(w), "object_missing");
    });
    it("size_mismatch: a row or an object whose byte count disagrees", async () => {
        const p = fx.pairs[4]!;
        w.db.raw.prepare("UPDATE media_items SET bytes = bytes + 1 WHERE id = ?").run(p.host);
        only(await migrate(w), "size_mismatch");
        w.db.raw.prepare("UPDATE media_items SET bytes = ? WHERE id = ?").run(p.bytes, p.host);
        w.media.objects.set(p.key, { bytes: p.bytes + 5, meta: {}, data: new Uint8Array(p.bytes + 5), viaStream: true });
        only(await migrate(w), "size_mismatch");
    });
    it("a skipped pair stays exactly as it was after an apply (nothing half done); the rest merges", async () => {
        const p = fx.pairs[5]!;
        w.media.objects.delete(p.key);
        const r = await migrate(w, "dry_run=0&limit=100");
        expect(r.body.report.processed).toBe(5);
        expect(w.item(p.host).deleted_at).toBeNull();
        expect(w.item(p.orig)).toMatchObject({ visibility: "private", public_key: null, url: null });
    });
    it("a head that throws is reported as storage_error, not as a missing object", async () => {
        const orig = w.media.head.bind(w.media);
        w.media.head = async (k: string) => {
            if (k === fx.pairs[0]!.key) throw new Error("R2 down");
            return orig(k);
        };
        const r = await migrate(w);
        expect(r.body.report.skipped.storage_error).toBe(1);
        expect(r.body.report.skipped.object_missing).toBe(0);
    });
});

describe("old apps (1.0-1.6): GET /library without v keeps showing what it showed", () => {
    // what an old client can read: everything but the additive keys
    const legacy = (f: any) => {
        const { visibility, visibility_toggle, ...rest } = f;
        return rest;
    };
    const byPost = (l: Awaited<ReturnType<typeof listAll>>) =>
        Object.fromEntries(
            l.posts.map((p: any) => {
                const { created_at, visibility, files, ...rest } = p; // a post is sorted by its newest live file: a retired host row no longer counts
                return [p.id, { ...rest, files: files.map(legacy) }];
            }),
        );

    it("before and after the migration the old shape is the same posts with the same files in the same order (host files synthesized with their old ids and times); only counts.files shrinks", async () => {
        const pre = await listAll(w);
        await migrate(w, "dry_run=0&limit=100");
        const post = await listAll(w);
        expect(post.posts.map((p) => p.id).sort()).toEqual(pre.posts.map((p) => p.id).sort());
        expect(byPost(post)).toEqual(byPost(pre));
        expect(post.usage).toEqual(pre.usage);
        expect(pre.counts).toEqual({ posts: pre.posts.length, files: 92 });
        expect(post.counts).toEqual({ posts: pre.posts.length, files: 86 });
        // the host files old apps see are the retired host rows: same ids, urls, kinds, sources
        for (const p of fx.pairs) {
            const f = post.files.find((x) => x.id === p.host);
            expect(f).toMatchObject({ kind: "public", source: "host", url: p.url, media_name: p.key, deletable: false });
            const o = post.files.find((x) => x.id === p.orig);
            expect(o).toMatchObject({ kind: "private", url: null });
        }
    });

    it("every id an old app holds (the host's, now the public_id) still resolves on the item routes", async () => {
        await migrate(w, "dry_run=0&limit=100");
        const p = fx.pairs[0]!;
        const file = await w.call(`/library/items/${p.host}/file`, { headers: auth });
        expect(file.status).toBe(200);
        expect((await file.arrayBuffer()).byteLength).toBe(p.bytes);
        const pub = await w.call(`/library/items/${p.host}/publish`, { method: "POST", headers: auth });
        expect(pub.status).toBe(201); // the same link, nothing copied
        expect(((await pub.json()) as any)).toMatchObject({ url: p.url, item_id: p.host });
        expect(w.media.puts).toHaveLength(0);
        const t = await w.call(`/library/items/${p.host}/post`, { method: "PATCH", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ title: "T" }) });
        expect(t.status).toBe(200);
    });
});

describe("the v2 shape after the migration", () => {
    it("one entry per file: 86 files, 59-ish posts, six public originals at their old URLs, every original with its poster", async () => {
        await migrate(w, "dry_run=0&limit=100");
        const l = await listAll(w, "v=2");
        expect(l.files).toHaveLength(86);
        expect(l.counts.files).toBe(86);
        const pub = l.files.filter((f) => f.source === "saved" || f.source === "upload").filter((f) => f.visibility === "public");
        expect(pub.map((f) => f.url).sort()).toEqual(fx.pairs.map((p) => p.url).sort());
        for (const f of l.files.filter((f) => f.source === "saved" || f.source === "upload")) {
            expect(f.poster_url, f.id).toMatch(/^https:\/\/media\.capybaraharmony\.com\/Poster\d{4}\.jpg$/);
            expect(f.visibility_toggle).toBe(true);
            expect(f.media_name).toBeNull();
            expect(f.deletable).toBe(false);
        }
        expect(l.files.filter((f) => f.source === "host")).toHaveLength(0);
        expect(l.files.filter((f) => f.visibility === "private")).toHaveLength(51);
        expect(l.files.filter((f) => f.visibility === "public")).toHaveLength(35);
        // posts: visibility is the original's
        const pubPosts = l.posts.filter((p) => p.visibility === "public").map((p) => p.public_url);
        expect(pubPosts.filter(Boolean).sort()).toEqual([...fx.pairs.map((p) => p.url), ...l.files.filter((f) => f.source === "studio" || f.source === "webp").map(() => null)].filter(Boolean).sort());
        expect(l.usage.public_bytes).toBeGreaterThan(0);
    });

    it("works before the migration too: the same call lists 92 rows, every file with a visibility derived from its bucket", async () => {
        const l = await listAll(w, "v=2");
        expect(l.files).toHaveLength(92);
        expect(l.files.filter((f) => f.visibility === "public")).toHaveLength(35); // 29 webps + 6 host copies
        expect(l.files.filter((f) => f.source === "saved" || f.source === "upload").every((f) => f.visibility === "private")).toBe(true);
    });
});

describe("toggling around the migration keeps the same link", () => {
    it("after: off deletes the mirror, on brings back the SAME url (the old shared link) from the private original", async () => {
        const p = fx.pairs[0]!;
        await migrate(w, "dry_run=0&limit=100");
        const off = await patchVisibility(w, p.orig, { public: false });
        expect(off.status).toBe(200);
        expect(off.body.item).toMatchObject({ id: p.orig, visibility: "private", url: null });
        expect(w.media.objects.has(p.key)).toBe(false);
        expect(w.item(p.orig)).toMatchObject({ visibility: "private", public_key: p.key, public_id: p.host, url: null });
        const on = await patchVisibility(w, p.orig, { public: true });
        expect(on.body.item).toMatchObject({ visibility: "public", url: p.url });
        expect(w.media.objects.has(p.key)).toBe(true);
        expect(w.media.objects.get(p.key)!.data).toEqual(w.originals.objects.get(w.item(p.orig).r2_key)!.bytes);
        assertInvariants(w);
    });

    it("BEFORE the migration the toggle merges that pair lazily: no second mirror is made, the host's object and URL are reused", async () => {
        const p = fx.pairs[1]!;
        const on = await patchVisibility(w, p.orig, { public: true });
        expect(on.status).toBe(200);
        expect(on.body.item).toMatchObject({ visibility: "public", url: p.url });
        expect(w.media.puts).toHaveLength(0);
        expect(w.item(p.host).merged_into).toBe(p.orig);
        expect(w.item(p.orig)).toMatchObject({ public_key: p.key, public_id: p.host });
        // and off, before the migration, deletes that very object
        const off = await patchVisibility(w, p.orig, { public: false });
        expect(off.status).toBe(200);
        expect(w.media.objects.has(p.key)).toBe(false);
        // the other five pairs are still waiting for the data step
        expect((await migrate(w)).body.report.merge.pairs).toBe(5);
    });
});

describe("undo (the rollback)", () => {
    it("is a dry run by default and lists what it would restore", async () => {
        await migrate(w, "dry_run=0&limit=100");
        const before = snapshot();
        const r = await migrate(w, "undo=1&limit=100");
        expect(r.body).toMatchObject({ undo: true, dry_run: true, remaining: 0, report: { tombstones: 6, new_code_publics: 0 } });
        expect(r.body.items.map((i: any) => i.action)).toEqual(new Array(6).fill("restore"));
        expect(snapshot()).toEqual(before);
    });

    it("restores the exact pre-merge rows, byte for byte (every column, new ones back to NULL), and the old shape works again", async () => {
        const pre = allRows(w);
        const preList = await listAll(w);
        await migrate(w, "dry_run=0&limit=100");
        const r = await migrate(w, "undo=1&dry_run=0&limit=100");
        expect(r.body).toMatchObject({ remaining: 0, report: { processed: 6 } });
        expect(allRows(w)).toEqual(pre);
        expect(JSON.stringify(allRows(w))).toBe(JSON.stringify(pre));
        const back = await listAll(w);
        expect(JSON.stringify(back.posts)).toBe(JSON.stringify(preList.posts));
        // and the data step can run again
        expect((await migrate(w)).body.report.merge.pairs).toBe(6);
    });

    it("also undoes an original the NEW code made public (no tombstone): the host row old code expects is inserted, the original's columns cleared", async () => {
        await migrate(w, "dry_run=0&limit=100");
        const priv = fx.privates[0]!;
        const on = await patchVisibility(w, priv, { public: true });
        const { url, public_id } = { url: on.body.item.url as string, public_id: w.item(priv).public_id as string };
        const key = w.item(priv).public_key as string;
        const r = await migrate(w, "undo=1&dry_run=0&limit=100");
        expect(r.body.report).toMatchObject({ tombstones: 6, new_code_publics: 1, processed: 7 });
        const host = w.item(public_id);
        expect(host).toMatchObject({ kind: "public", source: "host", bucket: "media", r2_key: key, url, content_type: "video/mp4", deleted_at: null });
        expect(w.item(priv)).toMatchObject({ url: null, public_key: null, public_id: null, visibility: null });
        // a private toggle (off again) needs nothing: its mirror is gone and old code agrees
        const other = fx.privates[1]!;
        await patchVisibility(w, other, { public: true });
        await patchVisibility(w, other, { public: false });
        const r2 = await migrate(w, "undo=1&dry_run=0&limit=100");
        expect(r2.body.report.new_code_publics).toBe(0);
    });
});
