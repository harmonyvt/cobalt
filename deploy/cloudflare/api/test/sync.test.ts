// Sync engine slice 1: stored post keys, the change log's triggers, GET /sync (one D1 batch, the app's contract),
// Idempotency-Key on the four write routes, and the change number on those answers.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { timedDb } from "../src/d1-timing";
import { hashKey, KeyCache } from "../src/keys";
import { CHANGE_SEQ_HEADER, syncPage, trimGoneMarkers } from "../src/sync";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createBatchD1, withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com/";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const ORIGIN = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const NOW = 1_800_000_000_000;

const container = { async fetch() { return new Response("{}", { headers: { "content-type": "application/json" } }); } };

let db: FakeD1;
let env: WorkerEnv;

const call = (path: string, init: RequestInit = {}) =>
    handleRequest(new Request(`https://api.capybaraharmony.com${path}`, init), env, container, { now: () => NOW, keyCache: new KeyCache() });

const insertItem = (id: string, over: Record<string, unknown> = {}) => {
    const row = {
        id,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/${id}.mp4`,
        url: null,
        name: `${id}.mp4`,
        content_type: "video/mp4",
        bytes: 10,
        width: 100,
        height: 80,
        duration: 1,
        link: `https://x.com/a/status/${id}`,
        session_id: null,
        key_id: "key-1",
        created_at: NOW,
        visibility: "private",
        post_key: id,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, visibility, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@visibility,@post_key)`,
        )
        .run(row as any);
    return row;
};

const changes = () => db.raw.prepare("SELECT seq, entity, id, gone FROM changes ORDER BY seq").all() as { seq: number; entity: string; id: string; gone: number }[];

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "phone", await hashKey(CLIENT), "0b5f2c3e", 1);
    env = {
        API_URL: API,
        CORS_URL: ORIGIN,
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
});

describe("change log triggers", () => {
    it("records one row per thing, a gone marker, and both keys of a merge", () => {
        insertItem("postA");
        insertItem("postB");
        expect(changes().filter((c) => c.entity === "post").map((c) => [c.id, c.gone])).toEqual([
            ["postA", 0],
            ["postB", 0],
        ]);

        db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('postA', 'spa day', 5)").run();
        const titled = changes().filter((c) => c.entity === "post");
        expect(titled.map((c) => c.id)).toEqual(["postB", "postA"]);
        expect(titled.find((c) => c.id === "postA")!.seq).toBeGreaterThan(changes()[0]!.seq);

        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'postB'").run();
        expect(changes().find((c) => c.id === "postB")).toMatchObject({ entity: "post", gone: 1 });

        insertItem("keep");
        insertItem("move");
        db.raw.prepare("UPDATE media_items SET post_key = 'keep' WHERE id = 'move'").run();
        const merged = changes().filter((c) => c.id === "move" || c.id === "keep");
        expect(merged.find((c) => c.id === "move")).toMatchObject({ gone: 1 });
        expect(merged.find((c) => c.id === "keep")).toMatchObject({ gone: 0 });
        expect(new Set(merged.map((c) => c.seq)).size).toBe(2);
    });

    it("records links, collections, sets, names and rules, including a delete", () => {
        const now = 10;
        db.raw.prepare("INSERT INTO share_sets (id, items, created_at) VALUES ('1234567890123456789', '[\"a\"]', ?)").run(now);
        db.raw.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES ('col0000000000001', 'trips', ?, ?)").run(now, now);
        db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES ('col0000000000001', '1234567890123456789', ?)").run(now);
        db.raw.prepare("INSERT INTO collection_groups (id, name, created_at, updated_at) VALUES ('set0000000000001', 'summer', ?, ?)").run(now, now);
        db.raw.prepare("INSERT INTO search_names (id, name, name_key, meaning, created_at, updated_at) VALUES ('name000000000001', 'Lia', 'lia', 'a cat', ?, ?)").run(now, now);
        db.raw.prepare("INSERT INTO hidden_rules (id, kind, value, created_at, updated_at) VALUES ('rule000000000001', 'words', 'capybara', ?, ?)").run(now, now);
        const live = changes().filter((c) => c.gone === 0);
        expect(live.map((c) => `${c.entity}:${c.id}`).sort()).toEqual([
            "collection:col0000000000001",
            "link:1234567890123456789",
            "name:name000000000001",
            "rule:rule000000000001",
            "set:set0000000000001",
        ]);

        db.raw.prepare("DELETE FROM share_sets WHERE id = '1234567890123456789'").run();
        db.raw.prepare("DELETE FROM share_collections WHERE id = 'col0000000000001'").run();
        db.raw.prepare("DELETE FROM collection_groups WHERE id = 'set0000000000001'").run();
        db.raw.prepare("DELETE FROM search_names WHERE id = 'name000000000001'").run();
        db.raw.prepare("DELETE FROM hidden_rules WHERE id = 'rule000000000001'").run();
        expect(changes().map((c) => [c.entity, c.gone]).sort()).toEqual([
            ["collection", 1],
            ["link", 1],
            ["name", 1],
            ["rule", 1],
            ["set", 1],
        ]);
    });

    it("fills post_key on an insert that leaves it null", () => {
        db.raw.prepare("INSERT INTO studio_sessions (id, link, status, created_at, expires_at) VALUES ('sess00000000000000001', 'upload:file000000000001', 'ready', 1, 9)").run();
        db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, created_at, session_id) VALUES ('made000000000001', 'private', 'saved', 'originals', 'k', 'n', 1, 'sess00000000000000001')")
            .run();
        expect(db.raw.prepare("SELECT post_key FROM media_items WHERE id = 'made000000000001'").get()).toEqual({ post_key: "file000000000001" });
        expect(changes().map((c) => c.id)).toContain("file000000000001");
    });
});

describe("GET /sync", () => {
    const body = async (path: string, headers: Record<string, string> = AUTH) => {
        const res = await call(path, { headers });
        return { status: res.status, headers: res.headers, json: (await res.json().catch(() => null)) as any };
    };

    it("pages with more, then stops, and matches GET /library including a hidden post", async () => {
        insertItem("vis", { created_at: NOW });
        insertItem("hid", { created_at: NOW + 1 });
        const hidden = await call("/library/status", {
            method: "POST",
            headers: { ...AUTH, "content-type": "application/json" },
            body: JSON.stringify({ ids: ["hid"], status: "hidden" }),
        });
        expect(hidden.status).toBe(200);

        const first = await body("/sync?since=0&limit=1");
        expect(first.status).toBe(200);
        expect(first.json.more).toBe(true);
        expect(first.json.posts.length + first.json.gone.length).toBe(1);
        const seq = first.json.seq as number;

        const second = await body(`/sync?since=${seq}&limit=1`);
        expect(second.status).toBe(200);
        expect(second.json.seq).toBeGreaterThan(seq);
        const rest = await body(`/sync?since=${second.json.seq}&limit=500`);
        expect(rest.json.more).toBe(false);

        const all = await body("/sync?since=0&limit=500");
        expect(all.json.more).toBe(false);
        const posts = all.json.posts as any[];
        expect(posts.map((p) => p.id).sort()).toEqual(["hid", "vis"]);

        const library = await body("/library?v=3");
        const album = await body("/library?hidden=1&v=3");
        const synced = Object.fromEntries(posts.map((p) => [p.id, p]));
        expect(library.json.posts.map((p: { id: string }) => p.id)).toEqual(["vis"]);
        expect(album.json.posts.map((p: { id: string }) => p.id)).toEqual(["hid"]);
        expect(synced.vis).toEqual(library.json.posts[0]);
        expect(synced.hid).toEqual(album.json.posts[0]);
        expect(synced.hid.hidden).toBe(true);
        expect(synced.vis.hidden).toBe(false);
        expect(synced.vis.created_at).toBe(NOW);
        expect(Array.isArray(synced.vis.files)).toBe(true);

        const caughtUp = await body(`/sync?since=${all.json.seq}`);
        expect(caughtUp.json).toMatchObject({ seq: all.json.seq, more: false, posts: [], gone: [] });
    });

    it("is one D1 round trip, and a cached key makes the whole request one", async () => {
        insertItem("only");
        const fake = createBatchD1();
        fake.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "phone", await hashKey(CLIENT), "0b5f2c3e", 1);
        fake.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at, visibility, post_key)
                 VALUES ('only', 'private', 'saved', 'originals', 'originals/only.mp4', 'only.mp4', 'video/mp4', 10, ?, 'private', 'only')`,
            )
            .run(NOW);
        const { db: timed, stats } = timedDb(fake);
        const direct = await syncPage({ db: timed, now: () => NOW, apiUrl: API, shareBaseUrl: SHARE }, new URLSearchParams("since=0&limit=500"));
        expect(direct.status).toBe(200);
        expect(stats.n).toBe(1);
        expect((direct.body as { posts: { id: string }[] }).posts.map((p) => p.id)).toEqual(["only"]);

        const cache = new KeyCache();
        const world = { ...env, DB: timed };
        const hit = (path: string) =>
            handleRequest(new Request(`https://api.capybaraharmony.com${path}`, { headers: AUTH }), world, container, { now: () => NOW, keyCache: cache });
        await hit("/sync?since=0");
        const before = stats.n;
        const again = await hit("/sync?since=0");
        expect(again.status).toBe(200);
        expect(stats.n - before).toBe(1);
    });

    it("answers 410 once delete markers older than since were trimmed, and since=0 still works", async () => {
        insertItem("gone");
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'gone'").run();
        db.raw.prepare("UPDATE changes SET at = 1 WHERE id = 'gone'").run();
        const watermark = await trimGoneMarkers(db, 1_000);
        expect(watermark).toBeGreaterThan(0);
        const stale = await body(`/sync?since=${watermark - 1}`);
        expect(stale.status).toBe(410);
        expect(stale.json).toEqual({ error: "sync.cursor_too_old" });
        const fresh = await body("/sync?since=0");
        expect(fresh.status).toBe(200);
        expect(fresh.json.posts).toEqual([]);
    });

    it("requires the same Api-Key as the library and rejects a bad cursor", async () => {
        expect((await body("/sync", {})).status).toBe(401);
        expect((await body("/sync", { authorization: "Api-Key 00000000-0000-4000-8000-000000000000" })).status).toBe(401);
        const service = await call("/sync?since=0", { headers: { "x-cobalt-service": INTERNAL } });
        expect(service.status).toBe(200);
        expect((await body("/sync?since=-1")).status).toBe(400);
        expect((await body("/sync?limit=0")).status).toBe(400);
    });
});

describe("idempotent writes", () => {
    it("does not apply a retried title, delete, status or visibility twice, and every answer carries the change number", async () => {
        insertItem("file000000000001");
        const key = "11111111-1111-4111-8111-111111111111";
        const patch = (title: string, idem = key) =>
            call("/library/items/file000000000001/post", {
                method: "PATCH",
                headers: { ...AUTH, "content-type": "application/json", "idempotency-key": idem },
                body: JSON.stringify({ title }),
            });
        const first = await patch("spa day");
        expect(first.status).toBe(200);
        const seq = first.headers.get(CHANGE_SEQ_HEADER);
        expect(seq).toMatch(/^\d+$/);
        const titles = () => db.raw.prepare("SELECT title FROM media_titles").all();
        expect(titles()).toEqual([{ title: "spa day" }]);
        const seqs = () => changes().map((c) => c.seq);

        const again = await patch("spa day");
        expect(again.status).toBe(200);
        expect(again.headers.get(CHANGE_SEQ_HEADER)).toBe(seq);
        expect(await again.json()).toEqual(await first.clone().json());
        expect(titles()).toEqual([{ title: "spa day" }]);
        const after = seqs();

        const clash = await patch("other", key);
        expect(clash.status).toBe(409);
        expect(clash.headers.get(CHANGE_SEQ_HEADER)).toBe(seq);
        expect(titles()).toEqual([{ title: "spa day" }]);
        expect(seqs()).toEqual(after);

        const fresh = await patch("renamed", "22222222-2222-4222-8222-222222222222");
        expect(fresh.status).toBe(200);
        expect(Number(fresh.headers.get(CHANGE_SEQ_HEADER))).toBeGreaterThan(Number(seq));
        expect(titles()).toEqual([{ title: "renamed" }]);

        const statusKey = "33333333-3333-4333-8333-333333333333";
        const status = () =>
            call("/library/status", {
                method: "POST",
                headers: { ...AUTH, "content-type": "application/json", "idempotency-key": statusKey },
                body: JSON.stringify({ ids: ["file000000000001"], status: "hidden" }),
            });
        const hid = await status();
        expect(hid.status).toBe(200);
        expect(hid.headers.get(CHANGE_SEQ_HEADER)).toMatch(/^\d+$/);
        const hiddenRows = () => db.raw.prepare("SELECT state FROM media_hidden").all();
        expect(hiddenRows()).toEqual([{ state: "hidden" }]);
        const hidAgain = await status();
        expect(hidAgain.status).toBe(200);
        expect(hidAgain.headers.get(CHANGE_SEQ_HEADER)).toBe(hid.headers.get(CHANGE_SEQ_HEADER));
        expect(hiddenRows()).toEqual([{ state: "hidden" }]);

        const visKey = "44444444-4444-4444-8444-444444444444";
        const vis = () =>
            call("/library/items/file000000000001/visibility", {
                method: "PATCH",
                headers: { ...AUTH, "content-type": "application/json", "idempotency-key": visKey },
                body: JSON.stringify({ public: false }),
            });
        const priv = await vis();
        expect(priv.headers.get(CHANGE_SEQ_HEADER)).toMatch(/^\d+$/);
        const beforeVis = changes().length;
        const privAgain = await vis();
        expect(privAgain.status).toBe(priv.status);
        expect(privAgain.headers.get(CHANGE_SEQ_HEADER)).toBe(priv.headers.get(CHANGE_SEQ_HEADER));
        expect(changes().length).toBe(beforeVis);

        const delKey = "55555555-5555-4555-8555-555555555555";
        const del = () =>
            call("/library/items/file000000000001/post", { method: "DELETE", headers: { ...AUTH, "idempotency-key": delKey } });
        const deleted = await del();
        expect(deleted.status).toBe(200);
        expect(deleted.headers.get(CHANGE_SEQ_HEADER)).toMatch(/^\d+$/);
        const deletedAgain = await del();
        expect(deletedAgain.status).toBe(200);
        expect(deletedAgain.headers.get(CHANGE_SEQ_HEADER)).toBe(deleted.headers.get(CHANGE_SEQ_HEADER));
        expect(await deletedAgain.json()).toEqual(await deleted.clone().json());
    });
});
