// The public/private toggle (apple/CONTRACT-VISIBILITY.md section 3.1): PATCH /library/items/<id>/visibility,
// the legacy routes that now mean "make public", webps that can be switched too (owner, 2026-10-05), the
// edge-cache purge, delete-everything, and the invariants after every operation. Real SQL on node:sqlite
// over every migration; both R2 buckets and the purge API are fakes.
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { purgeFrom } from "../src/visibility";
import { MEDIA_BASE, auth, svc, world, type World } from "./poster-world";
import { assertInvariants, listAll, patchVisibility, stubPurge } from "./visibility-fixture";

let w: World;
let purge: ReturnType<typeof stubPurge>;
beforeEach(async () => {
    w = world();
    await w.addKey();
    purge = stubPurge(w);
});
afterEach(() => purge.restore());

const row = (id: string) => w.item(id);
const urlOf = (r: any) => `${MEDIA_BASE}${r.public_key}`;
const WEBP = "WebpTest00000001";
const WEBP_NAME = "Abcdefghij.webp";
const seedWebp = (over: Record<string, unknown> = {}, id = WEBP, name = WEBP_NAME) => {
    const bytes = 1500;
    w.db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, visibility) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        )
        .run(id, "public", "studio", "media", name, `${MEDIA_BASE}${name}`, "clip.webp", "image/webp", bytes, 480, 854, 5, "https://x.com/a/status/1", "k", w.clock.t, (over.visibility as string | undefined) ?? null);
    w.media.objects.set(name, { bytes, meta: {}, data: new Uint8Array(bytes).fill(9), viaStream: false });
    return { id, name, bytes };
};
const seedHost = () => {
    w.db.raw
        .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, created_at) VALUES ('HostRow000000001','public','host','media','Hostmp4001.mp4',?,'a.mp4','video/mp4',10,1)")
        .run(`${MEDIA_BASE}Hostmp4001.mp4`);
};

describe("PATCH /library/items/<id>/visibility: the request", () => {
    it("the body is judged before the lookup: not JSON, not an object, no boolean `public`, or over 256 bytes is 400 error.library.bad_request, even for an unknown id", async () => {
        for (const body of ["nope", "[]", "null", "{}", '{"public":"yes"}', '{"public":1}', '{"public":null}', JSON.stringify({ public: true, pad: "x".repeat(300) })]) {
            const r = await patchVisibility(w, "Unknown000000000", body);
            expect(r.status, body.slice(0, 30)).toBe(400);
            expect(r.body).toEqual({ status: "error", error: { code: "error.library.bad_request" } });
        }
        const { itemId } = w.seed();
        expect((await patchVisibility(w, itemId, "{")).status).toBe(400);
        expect(row(itemId).visibility).toBeNull();
    });

    it("extra keys are ignored; an unknown or deleted item is 404 error.library.not_found; no key is 401; the service credential works", async () => {
        const { itemId } = w.seed();
        expect((await patchVisibility(w, itemId, { public: true, whatever: 1 })).status).toBe(200);
        expect((await patchVisibility(w, "Unknown000000000", { public: true })).body).toEqual({ status: "error", error: { code: "error.library.not_found" } });
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 5 WHERE id = ?").run(itemId);
        expect((await patchVisibility(w, itemId, { public: false })).status).toBe(404);
        expect((await patchVisibility(w, itemId, { public: true }, {})).status).toBe(401);
        const again = w.seed();
        expect((await patchVisibility(w, again.itemId, { public: true }, svc)).status).toBe(200);
    });

    it("answers with no-store and no CORS, from the Worker (the container is never involved)", async () => {
        const { itemId } = w.seed();
        const res = await w.call(`/library/items/${itemId}/visibility`, {
            method: "PATCH",
            headers: { ...auth, origin: "https://cobalt.capybaraharmony.com", "content-type": "application/json" },
            body: '{"public":true}',
        });
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("access-control-allow-origin")).toBeNull();
        expect(w.seen).toHaveLength(0);
    });

    it("webps, studio renders and legacy host copies: legacy host copies (and only they) are 409 error.library.not_toggleable", async () => {
        seedHost();
        const r = await patchVisibility(w, "HostRow000000001", { public: false });
        expect(r.status).toBe(409);
        expect(r.body).toEqual({ status: "error", error: { code: "error.library.not_toggleable" } });
        seedWebp();
        expect((await patchVisibility(w, WEBP, { public: true })).status).toBe(200); // a webp is switchable
    });
});

describe("toggle on", () => {
    it("copies the original to <10 base62>.<ext> with a one-hour cache lifetime, flips the row, syncs the session, purges the URL, answers the v2 file", async () => {
        const { itemId, sid, r2 } = w.seed();
        const r = await patchVisibility(w, itemId, { public: true });
        expect(r.status).toBe(200);
        const key = row(itemId).public_key as string;
        expect(key).toMatch(/^[A-Za-z0-9]{10}\.mp4$/);
        const url = `${MEDIA_BASE}${key}`;
        expect(r.body).toMatchObject({
            status: "success",
            cache_cleared: null, // only an OFF reports a purge
            item: { id: itemId, kind: "private", source: "saved", visibility: "public", visibility_toggle: true, url, media_name: null, deletable: false },
        });
        const obj = w.media.objects.get(key)!;
        expect(obj.data).toEqual(w.originals.objects.get(r2)!.bytes);
        expect(obj.cacheControl).toBe("public, max-age=3600");
        expect(obj.contentType).toBe("video/mp4");
        expect(obj.meta).toMatchObject({ mirror: "1", published: "1", itemId, sessionId: sid, keyId: expect.any(String), createdAt: expect.any(String) });
        expect(row(itemId)).toMatchObject({ visibility: "public", public_key: key, public_id: expect.stringMatching(/^[A-Za-z0-9]{16}$/), url });
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: url });
        expect(w.originals.objects.has(r2)).toBe(true);
        // an ON also purges (a cached 404 from an earlier OFF must not outlive it)
        expect(purge.calls).toEqual([{ zone: "560c4ad4961a65fa19899b4dfa8b5702", urls: [url], authorization: "Bearer test-token-not-a-secret" }]);
    });

    it("is idempotent: on when on is a 200 with no copy, no delete and the same item", async () => {
        const { itemId } = w.seed();
        const a = await patchVisibility(w, itemId, { public: true });
        const puts = w.media.puts.length;
        const b = await patchVisibility(w, itemId, { public: true });
        expect(b.status).toBe(200);
        expect(b.body.item).toEqual(a.body.item);
        expect(w.media.puts).toHaveLength(puts);
        expect(w.media.deletes).toEqual([]);
    });

    it("a missing original is 404 error.library.missing and the row is unchanged; a failing get or put is 502 error.library.storage, row unchanged, nothing half-copied", async () => {
        const { itemId, r2 } = w.seed({}, { object: false });
        const missing = await patchVisibility(w, itemId, { public: true });
        expect(missing.status).toBe(404);
        expect(missing.body.error.code).toBe("error.library.missing");
        w.originals.objects.set(r2, { bytes: new Uint8Array(4096).fill(7), contentType: "video/mp4", meta: {} });
        w.originals.failGet = true;
        expect((await patchVisibility(w, itemId, { public: true })).status).toBe(502);
        w.originals.failGet = false;
        w.media.failPut = true;
        const put = await patchVisibility(w, itemId, { public: true });
        expect(put.status).toBe(502);
        expect(put.body.error.code).toBe("error.library.storage");
        expect(row(itemId)).toMatchObject({ visibility: null, public_key: null, url: null, public_id: null });
        expect(w.media.objects.size).toBe(0);
    });

    it("a copy of the wrong length is no copy: 502, the half-made object is deleted", async () => {
        const { itemId, r2 } = w.seed();
        const real = w.originals.get.bind(w.originals);
        w.originals.get = async (k: string, o?: any) => {
            const x = await real(k, o);
            return x ? { ...x, size: x.size - 1 } : x;
        };
        const r = await patchVisibility(w, itemId, { public: true });
        expect(r.status).toBe(502);
        expect(w.media.objects.size).toBe(0);
        expect(row(itemId).visibility).toBeNull();
        void r2;
    });

    it("D1 refusing the row update after the copy is 503 and the new object is removed again", async () => {
        const { itemId } = w.seed();
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/^UPDATE media_items SET visibility = 'public'/.test(sql)) throw new Error("D1_ERROR: down");
            return orig(sql);
        };
        const r = await patchVisibility(w, itemId, { public: true });
        (w.db as any).prepare = orig;
        expect(r.status).toBe(503);
        expect(w.media.objects.size).toBe(0);
    });

    it("a row deleted while the copy ran does not leave a public object behind", async () => {
        const { itemId } = w.seed();
        const put = w.media.put.bind(w.media);
        w.media.put = async (k: string, v: any, o: any) => {
            const out = await put(k, v, o);
            w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(itemId);
            return out;
        };
        const r = await patchVisibility(w, itemId, { public: true });
        expect(r.status).toBe(404);
        expect(w.media.objects.size).toBe(0);
    });
});

describe("toggle off", () => {
    const on = async () => {
        const s = w.seed();
        const r = await patchVisibility(w, s.itemId, { public: true });
        const key = row(s.itemId).public_key as string;
        purge.calls.length = 0;
        w.media.deletes.length = 0;
        return { ...s, key, url: r.body.item.url as string };
    };

    it("deletes the public object BEFORE the row says private, keeps public_key and public_id, clears the session, purges the old URL, reports cache_cleared true", async () => {
        const { itemId, sid, key, url } = await on();
        const pid = row(itemId).public_id;
        let rowWhenDeleted: any = null;
        const del = w.media.delete.bind(w.media);
        w.media.delete = async (k: string) => {
            rowWhenDeleted = row(itemId); // what D1 says at the moment the object goes
            return del(k);
        };
        const r = await patchVisibility(w, itemId, { public: false });
        expect(r.status).toBe(200);
        expect(rowWhenDeleted).toMatchObject({ visibility: "public", url }); // still a truthful "public" while the object exists
        expect(w.media.objects.has(key)).toBe(false);
        expect(row(itemId)).toMatchObject({ visibility: "private", url: null, public_key: key, public_id: pid });
        expect(w.session(sid)).toMatchObject({ public_state: null, public_url: null });
        expect(r.body).toMatchObject({ status: "success", cache_cleared: true, item: { visibility: "private", url: null } });
        expect(purge.calls.map((c) => c.urls)).toEqual([[url]]);
    });

    it("a delete that throws is 502 and the row stays public (the failure is truthful, the toggle did not happen)", async () => {
        const { itemId, key } = await on();
        w.media.failDelete = true;
        const r = await patchVisibility(w, itemId, { public: false });
        expect(r.status).toBe(502);
        expect(r.body.error.code).toBe("error.library.storage");
        expect(row(itemId)).toMatchObject({ visibility: "public", url: `${MEDIA_BASE}${key}` });
        expect(purge.calls).toEqual([]);
    });

    it("purge outcomes never change the toggle: success:false is cache_cleared false, a network error is false, no token or zone is null", async () => {
        for (const [setup, want] of [
            [() => (purge.state.fail = true), false],
            [() => ((purge.state.fail = false), (purge.state.down = true)), false],
            [() => ((purge.state.down = false), delete w.env.MEDIA_PURGE_TOKEN), null],
            [() => ((w.env.MEDIA_PURGE_TOKEN = "t"), delete w.env.MEDIA_ZONE_ID), null],
            [() => (w.env.MEDIA_ZONE_ID = "not-a-zone"), null],
        ] as const) {
            const { itemId, key } = await on();
            (setup as () => void)();
            const r = await patchVisibility(w, itemId, { public: false });
            expect(r.status).toBe(200);
            expect(r.body.cache_cleared).toBe(want);
            expect(w.media.objects.has(key)).toBe(false);
            expect(row(itemId).visibility).toBe("private");
            purge.state.fail = false;
            purge.state.down = false;
            w.env.MEDIA_PURGE_TOKEN = "test-token-not-a-secret";
            w.env.MEDIA_ZONE_ID = "560c4ad4961a65fa19899b4dfa8b5702";
        }
    });

    it("off when off is a 200 with no delete; off for a file that was never public changes nothing", async () => {
        const { itemId } = w.seed();
        const r = await patchVisibility(w, itemId, { public: false });
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ cache_cleared: null, item: { visibility: "private", url: null } });
        expect(w.media.deletes).toEqual([]);
        expect(purge.calls).toEqual([]);
        const s = await on();
        await patchVisibility(w, s.itemId, { public: false });
        w.media.deletes.length = 0;
        const twice = await patchVisibility(w, s.itemId, { public: false });
        expect(twice.status).toBe(200);
        expect(w.media.deletes).toEqual([]);
    });

    it("on -> off -> on is the SAME key, the same URL and the same public id every time", async () => {
        const { itemId, key, url } = await on();
        const pid = row(itemId).public_id;
        for (let i = 0; i < 3; i++) {
            expect((await patchVisibility(w, itemId, { public: false })).status).toBe(200);
            expect(w.media.objects.has(key)).toBe(false);
            const back = await patchVisibility(w, itemId, { public: true });
            expect(back.body.item.url).toBe(url);
            expect(row(itemId)).toMatchObject({ public_key: key, public_id: pid, visibility: "public" });
            expect(w.media.objects.get(key)!.data).toHaveLength(4096);
        }
        assertInvariants(w);
    });
});

describe("reconcile: racing toggles converge on the row", () => {
    it("an ON that lands while an OFF is deleting: the OFF's closing pass deletes the object the ON made, so the object matches the row (private)", async () => {
        const { itemId } = w.seed();
        await patchVisibility(w, itemId, { public: true });
        const key = row(itemId).public_key as string;
        const del = w.media.delete.bind(w.media);
        let raced = false;
        w.media.delete = async (k: string) => {
            await del(k);
            if (!raced) {
                raced = true;
                // the racing ON runs to completion between the OFF's delete and its row update
                await patchVisibility(w, itemId, { public: true });
            }
        };
        const r = await patchVisibility(w, itemId, { public: false });
        expect(r.status).toBe(200);
        expect(row(itemId).visibility).toBe("private");
        expect(w.media.objects.has(key)).toBe(false);
        assertInvariants(w);
    });

    it("a public row whose object is gone (deleted behind our back) is repaired by the next ON: one copy, the same URL", async () => {
        const { itemId } = w.seed();
        await patchVisibility(w, itemId, { public: true });
        const key = row(itemId).public_key as string;
        w.media.objects.delete(key);
        const puts = w.media.puts.length;
        const r = await patchVisibility(w, itemId, { public: true });
        expect(r.status).toBe(200);
        expect(w.media.puts).toHaveLength(puts + 1);
        expect(w.media.objects.has(key)).toBe(true);
        assertInvariants(w);
    });

    it("a private row that still has an object (a delete that failed earlier) loses it on the next OFF", async () => {
        const { itemId } = w.seed();
        await patchVisibility(w, itemId, { public: true });
        const key = row(itemId).public_key as string;
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private', url = NULL WHERE id = ?").run(itemId);
        expect(w.media.objects.has(key)).toBe(true);
        await patchVisibility(w, itemId, { public: false });
        expect(w.media.objects.has(key)).toBe(false);
    });
});

describe("the public_id resolves like an id on every item route", () => {
    it("file (GET and HEAD), publish, visibility, post title and delete post, and studio reopen all accept the id old apps know the public file by", async () => {
        const { itemId, sid, r2 } = w.seed();
        const pub = (await (await w.call(`/library/items/${itemId}/publish`, { method: "POST", headers: auth })).json()) as any;
        const pid = pub.item_id as string;
        expect(pid).toBe(row(itemId).public_id);
        expect(pid).not.toBe(itemId);

        const get = await w.call(`/library/items/${pid}/file`, { headers: auth });
        expect(get.status).toBe(200);
        expect((await get.arrayBuffer()).byteLength).toBe(4096);
        expect((await w.call(`/library/items/${pid}/file`, { method: "HEAD", headers: auth })).status).toBe(200);
        expect(((await (await w.call(`/library/items/${pid}/publish`, { method: "POST", headers: auth })).json()) as any).url).toBe(pub.url);
        expect((await patchVisibility(w, pid, { public: true })).body.item.id).toBe(itemId);
        const title = await w.call(`/library/items/${pid}/post`, { method: "PATCH", headers: { ...auth, "content-type": "application/json" }, body: '{"title":"T"}' });
        expect(title.status).toBe(200);
        const studio = await w.call(`/library/items/${pid}/studio`, { method: "POST", headers: auth });
        expect([200, 201]).toContain(studio.status);
        const del = await w.call(`/library/items/${pid}/post`, { method: "DELETE", headers: auth });
        expect(del.status).toBe(200);
        expect(w.originals.objects.has(r2)).toBe(false);
        void sid;
    });
});

describe("the legacy routes mean make public", () => {
    it("POST /library/items/<id>/publish: 201 {status,url,bytes,content_type,item_id} with the SAME link on a repeat, and 409 already_public for a webp in the public bucket", async () => {
        const { itemId } = w.seed();
        const a = await w.call(`/library/items/${itemId}/publish`, { method: "POST", headers: auth });
        const b = await w.call(`/library/items/${itemId}/publish`, { method: "POST", headers: auth });
        expect(a.status).toBe(201);
        const ja = (await a.json()) as any;
        expect(ja).toEqual({ status: "success", url: expect.stringMatching(/^https:\/\/media/), bytes: 4096, content_type: "video/mp4", item_id: expect.any(String) });
        expect(await b.json()).toEqual(ja);
        expect(w.media.puts).toHaveLength(1);
        seedWebp();
        const res = await w.call(`/library/items/${WEBP}/publish`, { method: "POST", headers: auth });
        expect(res.status).toBe(409);
        expect(((await res.json()) as any).error.code).toBe("error.library.already_public");
    });

    it("`public: true` on a save makes ONE row public (see public-default.test.ts); the session answer carries item_id and visibility", async () => {
        const { itemId, sid } = w.seed();
        const before = (await (await w.call(`/studio/${sid}`)).json()) as any;
        expect(before).toMatchObject({ item_id: itemId, visibility: "private" });
        await patchVisibility(w, itemId, { public: true });
        const after = (await (await w.call(`/studio/${sid}`)).json()) as any;
        expect(after).toMatchObject({ item_id: itemId, visibility: "public", public_state: "ready", public_url: expect.stringMatching(/^https:\/\/media/) });
    });

    it("a session with no original row of its own says item_id null / visibility null", async () => {
        const { sid } = w.seed({}, { row: false });
        const s = (await (await w.call(`/studio/${sid}`)).json()) as any;
        expect(s).toMatchObject({ item_id: null, visibility: null });
    });
});

describe("delete everything deletes both copies and purges", () => {
    it("a public original: the canonical object, the mirror and the row go; the mirror's URL is purged; a private one purges nothing", async () => {
        const a = w.seed();
        await patchVisibility(w, a.itemId, { public: true });
        const key = row(a.itemId).public_key as string;
        purge.calls.length = 0;
        const del = await w.call(`/library/items/${a.itemId}/post`, { method: "DELETE", headers: auth });
        expect(del.status).toBe(200);
        expect(w.originals.objects.has(a.r2)).toBe(false);
        expect(w.media.objects.has(key)).toBe(false);
        expect(row(a.itemId).deleted_at).not.toBeNull();
        expect(purge.calls.map((c) => c.urls)).toEqual([[`${MEDIA_BASE}${key}`]]);

        const b = w.seed();
        await patchVisibility(w, b.itemId, { public: true });
        await patchVisibility(w, b.itemId, { public: false });
        purge.calls.length = 0;
        expect((await w.call(`/library/items/${b.itemId}/post`, { method: "DELETE", headers: auth })).status).toBe(200);
        expect(purge.calls).toEqual([]);
        expect(w.originals.objects.has(b.r2)).toBe(false);
    });

    it("a mirror that cannot be deleted leaves the row live and reports it (502 partial); the retry finishes; a failed purge never changes the answer", async () => {
        const a = w.seed();
        await patchVisibility(w, a.itemId, { public: true });
        const key = row(a.itemId).public_key as string;
        w.media.failDelete = true;
        const res = await w.call(`/library/items/${a.itemId}/post`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(502);
        expect(((await res.json()) as any).remaining).toEqual([a.itemId]);
        expect(row(a.itemId).deleted_at).toBeNull();
        w.media.failDelete = false;
        purge.state.down = true;
        expect((await w.call(`/library/items/${a.itemId}/post`, { method: "DELETE", headers: auth })).status).toBe(200);
        expect(w.media.objects.has(key)).toBe(false);
    });

    it("a post of a saved link with a webp render and a public original: every file's public URL is purged", async () => {
        const a = w.seed();
        await patchVisibility(w, a.itemId, { public: true });
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, session_id, created_at, visibility) VALUES ('RenderRow0000001','public','studio','media','Renderabcd.webp',?,'r.webp','image/webp',3,?,?,?, 'public')")
            .run(`${MEDIA_BASE}Renderabcd.webp`, "https://x.com/a/status/2105237035271258436", a.sid, w.clock.t + 1);
        w.media.objects.set("Renderabcd.webp", { bytes: 3, meta: {}, data: new Uint8Array(3), viaStream: false });
        purge.calls.length = 0;
        const res = await w.call(`/library/items/${a.itemId}/post`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(purge.calls).toHaveLength(1);
        expect(purge.calls[0]!.urls.sort()).toEqual([`${MEDIA_BASE}${w.item(a.itemId).public_key}`, `${MEDIA_BASE}Renderabcd.webp`].sort());
    });
});

describe("webps are switchable (owner, 2026-10-05)", () => {
    const priv = (name = WEBP_NAME) => `webps/${name}`;

    it("OFF moves the canonical bytes to the private bucket first (verified), THEN deletes the public object, purges its URL, and marks the row private", async () => {
        const { id, name, bytes } = seedWebp();
        const url = `${MEDIA_BASE}${name}`;
        let seenWhenDeleted: any = null;
        const del = w.media.delete.bind(w.media);
        w.media.delete = async (k: string) => {
            seenWhenDeleted = { priv: w.originals.objects.has(priv()), row: row(id) };
            return del(k);
        };
        const r = await patchVisibility(w, id, { public: false });
        expect(r.status).toBe(200);
        // the private copy existed (and the row already pointed at it) before the public object went
        expect(seenWhenDeleted.priv).toBe(true);
        expect(seenWhenDeleted.row).toMatchObject({ bucket: "originals", r2_key: priv(), public_key: name, visibility: "public" });
        expect(w.originals.objects.get(priv())!.bytes).toEqual(new Uint8Array(bytes).fill(9));
        expect(w.originals.objects.get(priv())!.contentType).toBe("image/webp");
        expect(w.media.objects.has(name)).toBe(false);
        expect(row(id)).toMatchObject({ bucket: "originals", r2_key: priv(), public_key: name, visibility: "private", url: null, kind: "public", source: "studio" });
        expect(r.body).toMatchObject({ cache_cleared: true, item: { visibility: "private", url: null, visibility_toggle: true, media_name: name, deletable: true } });
        expect(purge.calls.map((c) => c.urls)).toEqual([[url]]);
        assertInvariants(w);
    });

    it("OFF -> ON -> OFF -> ON keeps the SAME URL, keeps the private copy (later toggles cost one copy, and none to the private side)", async () => {
        const { id, name } = seedWebp();
        const url = `${MEDIA_BASE}${name}`;
        await patchVisibility(w, id, { public: false });
        const privPuts = w.originals.putValueTypes.length;
        const on = await patchVisibility(w, id, { public: true });
        expect(on.body.item).toMatchObject({ visibility: "public", url });
        expect(w.media.objects.get(name)!.data).toEqual(new Uint8Array(1500).fill(9));
        expect(w.originals.objects.has(priv())).toBe(true); // kept
        await patchVisibility(w, id, { public: false });
        await patchVisibility(w, id, { public: true });
        expect(row(id)).toMatchObject({ visibility: "public", url, public_key: name, bucket: "originals" });
        expect(w.originals.putValueTypes).toHaveLength(privPuts); // the private side was written once
        assertInvariants(w);
    });

    it("a webp never switched is public: ON is a no-op 200, nothing copied", async () => {
        const { id } = seedWebp();
        const r = await patchVisibility(w, id, { public: true });
        expect(r.status).toBe(200);
        expect(r.body.item).toMatchObject({ visibility: "public", visibility_toggle: true });
        expect(w.media.puts).toHaveLength(0);
        expect(w.originals.putValueTypes).toHaveLength(0);
        expect(row(id).bucket).toBe("media");
    });

    it("a failed private copy leaves everything as it was: 502, the webp still public, no private object, no row change", async () => {
        const { id, name } = seedWebp();
        w.originals.failPut = true;
        const r = await patchVisibility(w, id, { public: false });
        expect(r.status).toBe(502);
        expect(w.media.objects.has(name)).toBe(true);
        expect(row(id)).toMatchObject({ bucket: "media", r2_key: name, visibility: null });
        w.originals.failPut = false;
        // a copy that is shorter than the source is not accepted either
        const real = w.originals.head.bind(w.originals);
        w.originals.head = async (k: string) => {
            const h = await real(k);
            return h ? { ...h, size: h.size - 1 } : h;
        };
        expect((await patchVisibility(w, id, { public: false })).status).toBe(502);
        expect(w.originals.objects.has(priv())).toBe(false); // the bad copy is removed
        expect(row(id).bucket).toBe("media");
        expect(w.media.objects.has(name)).toBe(true);
        w.originals.head = real;
        // a webp whose public object is gone cannot be switched: 404 missing
        w.media.objects.delete(name);
        const gone = await patchVisibility(w, id, { public: false });
        expect(gone.status).toBe(404);
        expect(gone.body.error.code).toBe("error.library.missing");
    });

    it("the library: v2 lists a private webp with url null and its switch; the legacy list simply leaves it out (old apps have no word for it), and a webp-only post vanishes from it", async () => {
        const { id } = seedWebp();
        await patchVisibility(w, id, { public: false });
        const v2 = await listAll(w, "v=2");
        const f = v2.files.find((x) => x.id === id)!;
        expect(f).toMatchObject({ visibility: "private", url: null, visibility_toggle: true, media_name: WEBP_NAME, deletable: true, source: "studio" });
        expect(v2.posts.find((p) => p.files.some((x: any) => x.id === id))!.visibility).toBe("private");
        expect(v2.counts.files).toBe(1);
        const old = await listAll(w);
        expect(old.files.find((x) => x.id === id)).toBeUndefined();
        expect(old.posts).toHaveLength(0);
        expect(old.counts).toEqual({ posts: 0, files: 0 });
        // public again: back in both
        await patchVisibility(w, id, { public: true });
        const back = await listAll(w);
        expect(back.files.find((x) => x.id === id)).toMatchObject({ kind: "public", url: `${MEDIA_BASE}${WEBP_NAME}`, media_name: WEBP_NAME, deletable: true, visibility: "public", visibility_toggle: true });
    });

    it("a private webp inside a post with a video: the old list shows the post and the video without the webp; v2 shows both; usage counts the private copy as private bytes", async () => {
        const a = w.seed();
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, session_id, created_at, visibility) VALUES ('RenderRow0000001','public','studio','media','Renderabcd.webp',?,'r.webp','image/webp',300,?,?,?, 'public')")
            .run(`${MEDIA_BASE}Renderabcd.webp`, "https://x.com/a/status/2105237035271258436", a.sid, w.clock.t + 1);
        w.media.objects.set("Renderabcd.webp", { bytes: 300, meta: {}, data: new Uint8Array(300), viaStream: false });
        await patchVisibility(w, "RenderRow0000001", { public: false });
        const old = await listAll(w);
        expect(old.posts).toHaveLength(1);
        expect(old.files.map((f) => f.id)).toEqual([a.itemId]);
        const v2 = await listAll(w, "v=2");
        expect(v2.files.map((f) => f.id).sort()).toEqual([a.itemId, "RenderRow0000001"].sort());
        expect(v2.usage).toEqual({ public_bytes: 0, private_bytes: 4096 + 300 });
        expect(old.usage).toEqual(v2.usage);
    });

    it("DELETE /media/<name>.webp of a switched webp deletes BOTH copies, marks the row deleted and purges the URL; a never-switched webp goes through the webp service as before", async () => {
        const a = seedWebp();
        await patchVisibility(w, a.id, { public: false });
        await patchVisibility(w, a.id, { public: true });
        purge.calls.length = 0;
        const res = await w.call(`/media/${a.name}`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success" });
        expect(w.media.objects.has(a.name)).toBe(false);
        expect(w.originals.objects.has(priv(a.name))).toBe(false);
        expect(row(a.id).deleted_at).not.toBeNull();
        expect(purge.calls.map((c) => c.urls)).toEqual([[`${MEDIA_BASE}${a.name}`]]);
        // never switched: the webp service (the Durable Object) does it, the row is marked as always
        const b = seedWebp({}, "WebpTest00000002", "Klmnopqrst.webp");
        const plain = await w.call(`/media/${b.name}`, { method: "DELETE", headers: auth });
        expect(plain.status).toBe(200);
        expect(w.media.objects.has(b.name)).toBe(false);
        expect(row(b.id).deleted_at).not.toBeNull();
    });

    it("delete everything with a private webp copy deletes the private copy too (and a public one both)", async () => {
        const a = seedWebp();
        const b = seedWebp({}, "WebpTest00000002", "Klmnopqrst.webp");
        await patchVisibility(w, a.id, { public: false });
        await patchVisibility(w, b.id, { public: false });
        await patchVisibility(w, b.id, { public: true });
        for (const x of [a, b]) {
            const res = await w.call(`/library/items/${x.id}/post`, { method: "DELETE", headers: auth });
            expect(res.status).toBe(200);
            expect(w.originals.objects.has(priv(x.name))).toBe(false);
            expect(w.media.objects.has(x.name)).toBe(false);
            expect(row(x.id).deleted_at).not.toBeNull();
        }
    });

    it("POST /library/items/<id>/publish turns a private webp public again at the same URL", async () => {
        const { id, name } = seedWebp();
        await patchVisibility(w, id, { public: false });
        const res = await w.call(`/library/items/${id}/publish`, { method: "POST", headers: auth });
        expect(res.status).toBe(201);
        expect(((await res.json()) as any).url).toBe(`${MEDIA_BASE}${name}`);
        expect(row(id).visibility).toBe("public");
    });

    it("the migration leaves webps public with no private copy (nothing to move), and undo leaves a switched webp alone and says so", async () => {
        const { id } = seedWebp();
        const r = await w.call("/library/visibility/migrate?dry_run=0&limit=100", { method: "POST", headers: auth });
        expect(r.status).toBe(200);
        expect(row(id)).toMatchObject({ bucket: "media", visibility: "public" });
        expect(w.originals.objects.size).toBe(0);
        await patchVisibility(w, id, { public: false });
        const u = (await (await w.call("/library/visibility/migrate?undo=1&dry_run=0&limit=100", { method: "POST", headers: auth })).json()) as any;
        expect(u.report.webps_switched).toBe(1);
        expect(row(id)).toMatchObject({ bucket: "originals", visibility: "private" });
    });
});

describe("GET /library: visibility on every entry", () => {
    it("v2 and legacy both carry visibility and visibility_toggle on real files; the post says its original's visibility in v2 only; the legacy public original is followed by its synthesized host file", async () => {
        const a = w.seed();
        await patchVisibility(w, a.itemId, { public: true });
        const pid = row(a.itemId).public_id as string;
        const v2 = await listAll(w, "v=2");
        expect(v2.posts[0]).toMatchObject({ visibility: "public", public_url: urlOf(row(a.itemId)) });
        expect(v2.files).toEqual([expect.objectContaining({ id: a.itemId, kind: "private", url: urlOf(row(a.itemId)), visibility: "public", visibility_toggle: true })]);
        const old = await listAll(w);
        expect(old.posts[0].visibility).toBeUndefined();
        expect(old.posts[0].public_url).toBe(urlOf(row(a.itemId)));
        expect(old.files.map((f) => [f.id, f.kind, f.source, f.url === null ? null : "url"])).toEqual([
            [a.itemId, "private", "saved", null],
            [pid, "public", "host", "url"],
        ]);
        expect(old.files[1]).toMatchObject({ media_name: row(a.itemId).public_key, deletable: false, name: expect.stringMatching(/\.mp4$/), visibility: "public", visibility_toggle: false });
        expect(old.counts.files).toBe(1);
        // the usage totals: the public original is stored twice
        expect(v2.usage).toEqual({ public_bytes: 4096, private_bytes: 4096 });
    });

    it("a private original is the same in both shapes: url null, no synthesized file", async () => {
        const a = w.seed();
        for (const q of ["", "v=2"]) {
            const l = await listAll(w, q);
            expect(l.files).toEqual([expect.objectContaining({ id: a.itemId, url: null, visibility: "private" })]);
        }
    });

    it("an unknown v is the legacy shape", async () => {
        const a = w.seed();
        await patchVisibility(w, a.itemId, { public: true });
        const l = await listAll(w, "v=3");
        expect(l.files).toHaveLength(2);
    });
});

describe("the edge purge (purgeFrom)", () => {
    const calls: any[] = [];
    const ZONE = "560c4ad4961a65fa19899b4dfa8b5702";
    const fakeFetch = (answer: () => Response | Promise<Response>) =>
        (async (u: any, init: any) => {
            calls.push({ u: String(u), method: init.method, headers: init.headers, body: JSON.parse(init.body) });
            return answer();
        }) as unknown as typeof fetch;
    beforeEach(() => (calls.length = 0));

    it("is off without a token or a zone id (and for a zone id that is not 32 hex)", () => {
        expect(purgeFrom({})).toBeUndefined();
        expect(purgeFrom({ MEDIA_PURGE_TOKEN: "t" })).toBeUndefined();
        expect(purgeFrom({ MEDIA_ZONE_ID: ZONE })).toBeUndefined();
        expect(purgeFrom({ MEDIA_PURGE_TOKEN: "", MEDIA_ZONE_ID: ZONE })).toBeUndefined();
        expect(purgeFrom({ MEDIA_PURGE_TOKEN: "t", MEDIA_ZONE_ID: "zone" })).toBeUndefined();
    });

    it("POSTs {files:[url]} to the zone's purge_cache with the bearer token; success:true is true", async () => {
        const p = purgeFrom({ MEDIA_PURGE_TOKEN: "tok", MEDIA_ZONE_ID: ZONE }, fakeFetch(() => Response.json({ success: true })))!;
        expect(await p([`${MEDIA_BASE}a.mp4`])).toBe(true);
        expect(calls).toEqual([
            { u: `https://api.cloudflare.com/client/v4/zones/${ZONE}/purge_cache`, method: "POST", headers: { authorization: "Bearer tok", "content-type": "application/json" }, body: { files: [`${MEDIA_BASE}a.mp4`] } },
        ]);
    });

    it("an error status, success:false, a non-JSON body and a throw are all false; more than 30 URLs go in several calls; a slow API gives up after 3 s", async () => {
        const mk = (answer: () => Response | Promise<Response>) => purgeFrom({ MEDIA_PURGE_TOKEN: "t", MEDIA_ZONE_ID: ZONE }, fakeFetch(answer))!;
        expect(await mk(() => Response.json({ success: false }))(["u"])).toBe(false);
        expect(await mk(() => Response.json({ success: true }, { status: 500 }))(["u"])).toBe(false);
        expect(await mk(() => new Response("nope"))(["u"])).toBe(false);
        expect(await mk(() => Promise.reject(new Error("x")))(["u"])).toBe(false);
        calls.length = 0;
        const urls = Array.from({ length: 65 }, (_, i) => `${MEDIA_BASE}f${i}.mp4`);
        expect(await mk(() => Response.json({ success: true }))(urls)).toBe(true);
        expect(calls.map((c) => c.body.files.length)).toEqual([30, 30, 5]);
        expect(await mk(() => Response.json({ success: true }))([])).toBeNull();
        const slow = mk(() => new Promise<Response>(() => {}));
        const t0 = Date.now();
        expect(await slow(["u"])).toBe(false);
        expect(Date.now() - t0).toBeLessThan(5000);
    }, 10_000);
});
