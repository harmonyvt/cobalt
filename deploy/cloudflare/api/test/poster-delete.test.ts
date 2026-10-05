// Posters and deletion (APP-API-CONTRACT.md section 13): "delete everything" removes the posters
// with the post, a poster shared by an original and its public copy goes only when nothing live
// names it, the lifetime paths (session expiry, the sweep, the 30-day telemetry retention)
// never touch or orphan one, and a poster object can not be reached by DELETE /media/<name>.
import { beforeEach, describe, expect, it } from "vitest";
import { POSTER_NAME_REGEX, releasePoster } from "../src/library";
import { runTelemetryRetention } from "../src/telemetry";
import { MEDIA_BASE, auth, svc, world, type World } from "./poster-world";

let w: World;
const posterObj = (name: string) => w.media.objects.set(name, { bytes: 3, meta: { poster: "1" }, data: new Uint8Array(3), viaStream: false });
const has = (name: string) => w.media.objects.has(name);
const live = () => (w.db.raw.prepare("SELECT id FROM media_items WHERE deleted_at IS NULL ORDER BY id").all() as any[]).map((r) => r.id);
const del = (id: string, headers: Record<string, string> = auth) => w.call(`/library/items/${id}/post`, { method: "DELETE", headers });

// A post: a saved original and the public mp4 hosted from it, which share ONE poster object,
// plus a webp render (no poster).
function post(tag: string) {
    const { sid, itemId, r2 } = w.seed();
    const name = `Poster${tag}.jpg`; // 10 chars
    posterObj(name);
    const url = `${MEDIA_BASE}${name}`;
    w.db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = ?").run(url, itemId);
    w.db.raw.prepare("UPDATE studio_sessions SET poster = ? WHERE id = ?").run(url, sid);
    const hostKey = `Host${tag}12.mp4`; // 10 chars + .mp4
    w.media.objects.set(hostKey, { bytes: 5, meta: {}, data: new Uint8Array(5), viaStream: true });
    const hostId = `Host${tag}`.padEnd(16, "0");
    w.db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, session_id, created_at, poster) VALUES (?, 'public', 'host', 'media', ?, ?, 'a.mp4', 'video/mp4', 5, ?, ?, ?, ?)",
        )
        .run(hostId, hostKey, `${MEDIA_BASE}${hostKey}`, "https://x.com/a/status/1", sid, w.clock.t + 1, url);
    return { sid, itemId, r2, name, url, hostId, hostKey };
}

beforeEach(async () => {
    w = world();
    await w.addKey();
    w.clock.t += 3_600_000;
});

describe("DELETE /library/items/<id>/post", () => {
    it("deletes the poster with the post: every row soft-deleted, the original, the public copy AND the poster object gone", async () => {
        const a = post("AAAA");
        const b = post("BBBB"); // another post: untouched
        const res = await del(a.itemId);
        expect(res.status).toBe(200);
        expect(await res.json()).toMatchObject({ status: "success", deleted: { files: 2 }, remaining: [] });
        expect(has(a.name)).toBe(false);
        expect(has(a.hostKey)).toBe(false);
        expect(w.originals.objects.has(a.r2)).toBe(false);
        expect(live().sort()).toEqual([b.itemId, b.hostId].sort());
        expect(has(b.name)).toBe(true);
        expect(has(b.hostKey)).toBe(true);
    });

    it("the poster shared by the original and the public copy is deleted once, and a second call is a quiet 200 with zeros", async () => {
        const a = post("AAAA");
        const deletes: string[] = [];
        const orig = w.media.delete.bind(w.media);
        w.media.delete = async (k: string) => {
            deletes.push(k);
            return orig(k);
        };
        expect((await del(a.hostId)).status).toBe(200); // any file of the post is the anchor
        expect(deletes.filter((k) => k === a.name)).toEqual([a.name]);
        deletes.length = 0;
        const again = await del(a.itemId);
        expect(again.status).toBe(200);
        expect(await again.json()).toMatchObject({ deleted: { files: 0, bytes: 0 } });
        expect(deletes).toEqual([]);
    });

    it("a post without a poster (or old rows that never had the column set) deletes exactly as before", async () => {
        const { itemId } = w.seed();
        const res = await del(itemId);
        expect(res.status).toBe(200);
        expect(live()).toEqual([]);
        expect(w.media.objects.size).toBe(0);
    });

    it("a poster another LIVE row still names stays (it is deleted only when nothing live uses it)", async () => {
        const a = post("AAAA");
        // a row of another post that carries the same poster URL
        const other = w.seed();
        w.db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = ?").run(a.url, other.itemId);
        expect((await del(a.itemId)).status).toBe(200);
        expect(has(a.name)).toBe(true);
        expect(live()).toEqual([other.itemId]);
        // once that row goes, the object goes with it
        expect((await del(other.itemId)).status).toBe(200);
        expect(has(a.name)).toBe(false);
    });

    it("a file that could not be deleted stays live with its poster (502 partial); the retry removes everything", async () => {
        const a = post("AAAA");
        const orig = w.originals.delete.bind(w.originals);
        let fail = true;
        w.originals.delete = async (k: string) => {
            if (fail && k === a.r2) throw new Error("R2 down");
            return orig(k);
        };
        const res = await del(a.hostId);
        expect(res.status).toBe(502);
        expect(await res.json()).toMatchObject({ error: { code: "error.library.partial" }, remaining: [a.itemId] });
        expect(live()).toEqual([a.itemId]);
        expect(has(a.name)).toBe(true); // the live original still shows it
        fail = false;
        expect((await del(a.hostId)).status).toBe(200);
        expect(has(a.name)).toBe(false);
        expect(live()).toEqual([]);
    });

    it("a poster delete that fails is logged, never reported: the post is still deleted (200)", async () => {
        const a = post("AAAA");
        const orig = w.media.delete.bind(w.media);
        w.media.delete = async (k: string) => {
            if (k.endsWith(".jpg")) throw new Error("R2 down");
            return orig(k);
        };
        const res = await del(a.itemId);
        expect(res.status).toBe(200);
        expect(live()).toEqual([]);
        expect(has(a.hostKey)).toBe(false);
        expect(has(a.name)).toBe(true); // the one thing left: an orphan nothing lists
    });

    it("works with the service header too", async () => {
        const a = post("AAAA");
        expect((await del(a.itemId, svc)).status).toBe(200);
        expect(has(a.name)).toBe(false);
    });
});

describe("releasePoster", () => {
    it("only ever deletes an object shaped like a poster (<10 base62>.jpg)", async () => {
        const deleted: string[] = [];
        const media = { delete: async (k: string) => void deleted.push(k) };
        const got = [
            await releasePoster(w.db, media, `${MEDIA_BASE}Abcdefghij.jpg`),
            await releasePoster(w.db, media, `${MEDIA_BASE}Abcdefghij.mp4`),
            await releasePoster(w.db, media, `${MEDIA_BASE}Abcdefghij.webp`),
            await releasePoster(w.db, media, `${MEDIA_BASE}short.jpg`),
            await releasePoster(w.db, media, `${MEDIA_BASE}..%2FAbcdefghij.jpg`),
            await releasePoster(w.db, media, "not a url"),
            await releasePoster(w.db, media, null),
            await releasePoster(undefined, media, `${MEDIA_BASE}Abcdefghij.jpg`),
            await releasePoster(w.db, undefined, `${MEDIA_BASE}Abcdefghij.jpg`),
        ];
        expect(got).toEqual([true, false, false, false, false, false, false, false, false]);
        expect(deleted).toEqual(["Abcdefghij.jpg"]);
        expect(POSTER_NAME_REGEX.test("Abcdefghij.webp")).toBe(false); // so DELETE /media can never match one
    });
});

describe("a poster can not be deleted by hand, and nothing on a lifetime path orphans one", () => {
    it("DELETE /media/<name>.jpg is a 404 at the gate; a webp name is still deletable and touches no poster", async () => {
        const a = post("AAAA");
        const jpg = await w.call(`/media/${a.name}`, { method: "DELETE", headers: auth });
        expect(jpg.status).toBe(404);
        expect(has(a.name)).toBe(true);
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, created_at) VALUES ('WebpItem00000001','public','webp','media','Abcdefghij.webp','u','a.webp','image/webp',1)")
            .run();
        w.media.objects.set("Abcdefghij.webp", { bytes: 3, meta: {}, data: new Uint8Array(3), viaStream: false });
        // (the DO owns DELETE /media; the stub container answers ok) -> only the route's reachability matters here
        const webp = await w.call("/media/Abcdefghij.webp", { method: "DELETE", headers: auth });
        expect(webp.status).not.toBe(404);
        expect(has(a.name)).toBe(true);
    });

    it("the 7-day session expiry and the job sweep never delete the original, its poster or its public copy", async () => {
        const a = post("AAAA");
        w.clock.t += 30 * 24 * 3_600_000; // a month later: the session is long expired
        await w.studio.sweep();
        await w.studio.sweep();
        expect(w.session(a.sid).expires_at).toBeLessThan(w.clock.t);
        expect(has(a.name)).toBe(true);
        expect(has(a.hostKey)).toBe(true);
        expect(w.originals.objects.has(a.r2)).toBe(true);
        expect(live().sort()).toEqual([a.itemId, a.hostId].sort());
        // an expired session still answers 410, the poster is still its original's
        expect((await w.call(`/studio/${a.sid}`)).status).toBe(410);
    });

    it("the daily 30-day retention only touches telemetry: library rows and every bucket object are as they were", async () => {
        const a = post("AAAA");
        w.db.raw
            .prepare("INSERT INTO telemetry_crashes (id, key_id, install, ts, kind, summary, r2_key, received_at) VALUES ('c1','k','i',1,'crash','s','telemetry/crashes/2026-08-01/c1.json',1)")
            .run();
        w.originals.objects.set("telemetry/crashes/2026-08-01/c1.json", { bytes: new Uint8Array(2), contentType: "application/json", meta: {} });
        const r = await runTelemetryRetention({ db: w.db, originals: w.originals, now: w.clock.now });
        expect(r.crashes).toBe(1);
        expect(w.originals.objects.has("telemetry/crashes/2026-08-01/c1.json")).toBe(false);
        expect(has(a.name)).toBe(true);
        expect(has(a.hostKey)).toBe(true);
        expect(w.originals.objects.has(a.r2)).toBe(true);
        expect(live().sort()).toEqual([a.itemId, a.hostId].sort());
    });

    it("every deletion path that exists is accounted for: the API only deletes through DELETE /media (webps), DELETE /library/items/<id>/post and a publish rollback", async () => {
        // a grep, as a test: any new `.delete(` on a bucket in src/ must be reviewed against posters
        const { readdirSync, readFileSync } = await import("node:fs");
        const dir = new URL("../src/", import.meta.url);
        const hits: string[] = [];
        for (const f of readdirSync(dir)) {
            if (!f.endsWith(".ts")) continue;
            const text = readFileSync(new URL(f, dir), "utf8");
            for (const m of text.matchAll(/\b(?:media|bucket|originals)\.delete\(/g)) hits.push(`${f}:${m[0]}`);
        }
        expect([...new Set(hits)].sort()).toEqual(
            [
                "app-routes.ts:originals.delete(", // upload rollbacks, post delete (session originals)
                "app-routes.ts:media.delete(", // post delete (the file's mirror), poster release
                "library.ts:media.delete(", // releasePoster
                "poster.ts:media.delete(", // an orphan guard / a failed put of a poster
                "studio.ts:originals.delete(", // a save marked lost meanwhile
                "telemetry.ts:originals.delete(", // crash payloads
                // section 16: a toggle off deletes the public mirror (never a poster: the names differ in
                // extension and the keys come from the row's own public_key), a failed or wrong-length
                // mirror copy deletes the half-made object, and a webp's private copy is deleted again
                // when its row turned out gone or its length wrong
                "visibility.ts:media.delete(",
                "visibility.ts:originals.delete(",
                "webp.ts:bucket.delete(", // DELETE /media/<name>.webp
            ].sort(),
        );
    });
});
