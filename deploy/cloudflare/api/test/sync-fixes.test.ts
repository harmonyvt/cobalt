// Sync engine, the review's fixes: session and private-link changes reach the log, a membership UPDATE logs both
// owners, a first load finishes after delete markers were trimmed, a cursor above the head is refused, the migration
// can be applied again, the seed is newest first, and idempotency keys belong to their caller.
import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey, KeyCache } from "../src/keys";
import { CHANGE_SEQ_HEADER, IDEMPOTENCY_KEY_MAX, WALK_BASE, trimGoneMarkers } from "../src/sync";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const OTHER = "7c1d9e2a-3b4f-4a6c-8d5e-2f0a1b3c4d5e";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const NOW = 1_800_000_000_000;

const container = { async fetch() { return new Response("{}", { headers: { "content-type": "application/json" } }); } };

let db: FakeD1;
let env: WorkerEnv;

const call = (path: string, init: RequestInit = {}) =>
    handleRequest(new Request(`https://api.capybaraharmony.com${path}`, init), env, container, { now: () => NOW, keyCache: new KeyCache() });
const get = async (path: string) => {
    const res = await call(path, { headers: AUTH });
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
};

const ITEM_SQL = `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, visibility, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@visibility,@post_key)`;
const itemRow = (id: string, over: Record<string, unknown> = {}) => ({
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
});
const insertItem = (id: string, over: Record<string, unknown> = {}) => db.raw.prepare(ITEM_SQL).run(itemRow(id, over) as any);

type Change = { seq: number; entity: string; id: string; gone: number };
const changes = () => db.raw.prepare("SELECT seq, entity, id, gone FROM changes ORDER BY seq").all() as Change[];
const head = () => Number((db.raw.prepare("SELECT COALESCE(MAX(seq), 0) AS n FROM changes").get() as { n: number }).n);
const seqOf = (entity: string, id: string) => changes().find((c) => c.entity === entity && c.id === id)?.seq ?? null;
// Runs a write and says which things it logged (their rows are new, with numbers above the old head).
const logged = (sql: string, ...params: (string | number | null)[]) => {
    const before = head();
    db.raw.prepare(sql).run(...params);
    return changes().filter((c) => c.seq > before).map((c) => `${c.entity}:${c.id}:${c.gone}`);
};

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "phone", await hashKey(CLIENT), "0b5f2c3e", 1);
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-2", "mac", await hashKey(OTHER), "7c1d9e2a", 1);
    env = {
        API_URL: API,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        SHARE_BASE_URL: "https://share.capybaraharmony.com/",
    };
});

describe("studio_sessions triggers", () => {
    const SESSION = "INSERT INTO studio_sessions (id, link, service, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)";

    it("logs the post a reopened studio belongs to, and each later change of what the post shows", () => {
        insertItem("file000000000001");
        // a reopen: the session names its post in the link
        expect(logged(SESSION, "sess0000000000000000a", "upload:file000000000001", "upload", "saving", 1, 9)).toEqual(["post:file000000000001:0"]);
        expect(logged("UPDATE studio_sessions SET status = 'ready' WHERE id = 'sess0000000000000000a'")).toEqual(["post:file000000000001:0"]);
        expect(logged("UPDATE studio_sessions SET expires_at = 5 WHERE id = 'sess0000000000000000a'")).toEqual(["post:file000000000001:0"]);
        expect(logged("UPDATE studio_sessions SET items = '[{\"i\":0,\"status\":\"error\"}]' WHERE id = 'sess0000000000000000a'")).toEqual(["post:file000000000001:0"]);
        expect(logged("UPDATE studio_sessions SET service = 'tiktok' WHERE id = 'sess0000000000000000a'")).toEqual(["post:file000000000001:0"]);
        expect(logged("DELETE FROM studio_sessions WHERE id = 'sess0000000000000000a'")).toEqual(["post:file000000000001:0"]);
        expect(changes().filter((c) => c.entity === "post").length).toBe(1);
    });

    it("logs a saved post by its session id", () => {
        db.raw.prepare(SESSION).run("sess0000000000000000b", "https://x.com/a/status/1", "x", "ready", 1, 9);
        insertItem("file000000000002", { session_id: "sess0000000000000000b", post_key: "sess0000000000000000b" });
        expect(logged("UPDATE studio_sessions SET status = 'saving' WHERE id = 'sess0000000000000000b'")).toEqual(["post:sess0000000000000000b:0"]);
    });

    it("writes nothing when no shown value changed, for a session with no file yet, or for a deleted post", () => {
        insertItem("file000000000001");
        db.raw.prepare(SESSION).run("sess0000000000000000a", "upload:file000000000001", "upload", "ready", 1, 9);
        // the same values again, and a column the post does not show
        expect(logged("UPDATE studio_sessions SET status = 'ready', expires_at = 9 WHERE id = 'sess0000000000000000a'")).toEqual([]);
        expect(logged("UPDATE studio_sessions SET title = 'clip', poster = 'p.jpg' WHERE id = 'sess0000000000000000a'")).toEqual([]);
        // a save that has not stored its first file
        expect(logged(SESSION, "sess0000000000000000c", "https://x.com/a/status/3", "x", "saving", 1, 9)).toEqual([]);
        expect(logged("UPDATE studio_sessions SET status = 'error' WHERE id = 'sess0000000000000000c'")).toEqual([]);
        // a post whose files are all deleted keeps its delete marker, with its number
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'file000000000001'").run();
        const marker = seqOf("post", "file000000000001");
        expect(logged("UPDATE studio_sessions SET status = 'saving' WHERE id = 'sess0000000000000000a'")).toEqual([]);
        expect(changes().find((c) => c.id === "file000000000001")).toMatchObject({ gone: 1, seq: marker });
    });

    it("makes GET /sync send the post again with the session GET /library shows", async () => {
        insertItem("file000000000001");
        const cursor = (await get("/sync?since=0")).json.seq as number;
        db.raw.prepare(SESSION).run("sess0000000000000000a", "upload:file000000000001", "upload", "ready", NOW - 5, NOW + 60_000);
        const page = await get(`/sync?since=${cursor}`);
        const library = await get("/library?v=3");
        expect(page.json.posts.map((p: { id: string }) => p.id)).toEqual(["file000000000001"]);
        expect(page.json.posts[0]).toEqual(library.json.posts[0]);
        expect(page.json.posts[0].session).toMatchObject({ id: "sess0000000000000000a", status: "ready" });
    });
});

describe("private_links triggers", () => {
    const LINK = "INSERT INTO private_links (key, kind, target_id, created_at) VALUES (?, ?, ?, ?)";

    it("logs the file's post when its link is turned on, off or rotated, and never for a view", () => {
        db.raw.prepare("INSERT INTO studio_sessions (id, link, status, created_at, expires_at) VALUES ('sess0000000000000000b', 'https://x.com/a/status/1', 'ready', 1, 9)").run();
        insertItem("file000000000002", { session_id: "sess0000000000000000b", post_key: "sess0000000000000000b" });
        expect(logged(LINK, "k".repeat(22), "item", "file000000000002", 5)).toEqual(["post:sess0000000000000000b:0"]);
        expect(logged("UPDATE private_links SET opened = opened + 1, last_opened_at = 7 WHERE key = ?", "k".repeat(22))).toEqual([]);
        // a rotate: the old row is revoked, a new one is made
        expect(logged("UPDATE private_links SET revoked_at = 8 WHERE key = ?", "k".repeat(22))).toEqual(["post:sess0000000000000000b:0"]);
        expect(logged(LINK, "n".repeat(22), "item", "file000000000002", 8)).toEqual(["post:sess0000000000000000b:0"]);
        // the same value again is not a change
        expect(logged("UPDATE private_links SET revoked_at = 8 WHERE key = ?", "k".repeat(22))).toEqual([]);
    });

    it("leaves a gallery link's private link out: GET /sync's link does not carry it", () => {
        db.raw.prepare("INSERT INTO share_sets (id, items, created_at) VALUES ('1234567890123456789', '[\"a\"]', 1)").run();
        expect(logged(LINK, "s".repeat(22), "set", "1234567890123456789", 5)).toEqual([]);
        expect(logged("UPDATE private_links SET revoked_at = 8 WHERE key = ?", "s".repeat(22))).toEqual([]);
    });

    it("moves the change number on POST /library/status private and off, and GET /sync then equals GET /library", async () => {
        insertItem("file000000000001");
        const cursor = (await get("/sync?since=0")).json.seq as number;
        const status = (value: string) =>
            call("/library/status", {
                method: "POST",
                headers: { ...AUTH, "content-type": "application/json" },
                body: JSON.stringify({ ids: ["file000000000001"], status: value }),
            });
        const on = await status("private");
        expect(on.status).toBe(200);
        const after = Number(on.headers.get(CHANGE_SEQ_HEADER));
        expect(after).toBeGreaterThan(cursor);
        const page = await get(`/sync?since=${cursor}`);
        const library = await get("/library?v=3");
        expect(page.json.posts[0]).toEqual(library.json.posts[0]);
        expect(page.json.posts[0].files[0].private_url).toMatch(/^https:\/\//);

        const rotated = await call("/share/private/items/file000000000001/rotate", { method: "POST", headers: AUTH });
        expect(rotated.status).toBe(200);
        const again = await get(`/sync?since=${after}`);
        const libraryAgain = await get("/library?v=3");
        expect(again.json.posts[0]).toEqual(libraryAgain.json.posts[0]);
        expect(again.json.posts[0].files[0].private_url).not.toBe(page.json.posts[0].files[0].private_url);

        const off = await status("off");
        expect(Number(off.headers.get(CHANGE_SEQ_HEADER))).toBeGreaterThan(again.json.seq);
        const last = await get(`/sync?since=${again.json.seq}`);
        expect(last.json.posts[0].files[0].private_url).toBeNull();
    });
});

describe("membership UPDATE triggers", () => {
    it("logs every collection a rerolled link sits in, and both collections when a row changes hands", () => {
        db.raw.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES ('colA', 'a', 1, 1), ('colB', 'b', 1, 1)").run();
        db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES ('colA', 'linkOld', 1), ('colB', 'linkOld', 1)").run();
        // the reroll's statement: both collections now hold the new link, neither is written beside it
        expect(logged("UPDATE share_collection_items SET set_id = 'linkNew' WHERE set_id = 'linkOld'").sort()).toEqual(["collection:colA:0", "collection:colB:0"]);
        db.raw.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES ('colC', 'c', 1, 1)").run();
        expect(logged("UPDATE share_collection_items SET collection_id = 'colC' WHERE collection_id = 'colB'").sort()).toEqual(["collection:colB:0", "collection:colC:0"]);
        expect(changes().filter((c) => c.entity === "collection").length).toBe(3);
    });

    it("does the same for the collections of a set", () => {
        db.raw.prepare("INSERT INTO collection_groups (id, name, created_at, updated_at) VALUES ('setA', 'a', 1, 1), ('setB', 'b', 1, 1)").run();
        db.raw.prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES ('setA', 'col1', 1)").run();
        expect(logged("UPDATE collection_group_items SET collection_id = 'col2' WHERE collection_id = 'col1'")).toEqual(["set:setA:0"]);
        expect(logged("UPDATE collection_group_items SET group_id = 'setB' WHERE group_id = 'setA'").sort()).toEqual(["set:setA:0", "set:setB:0"]);
        expect(changes().filter((c) => c.entity === "set").length).toBe(2);
    });
});

describe("410 sync.cursor_too_old", () => {
    // five posts, then one of them deleted, and its marker trimmed
    const trimmedLibrary = async (ids = ["p1", "p2", "p3", "p4", "p5"], dead = "p5") => {
        for (const id of ids) insertItem(id);
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = ?").run(dead);
        db.raw.prepare("UPDATE changes SET at = 1 WHERE gone = 1").run();
        return trimGoneMarkers(db, 1_000);
    };
    const walk = async (limit: number) => {
        const posts: string[] = [];
        const cursors: number[] = [];
        let since = 0;
        for (let i = 0; i < 20; i++) {
            const page = await get(`/sync?since=${since}&limit=${limit}`);
            expect(page.status).toBe(200);
            posts.push(...page.json.posts.map((p: { id: string }) => p.id));
            cursors.push(page.json.seq);
            if (!page.json.more) return { posts, cursors, seq: page.json.seq as number };
            // what the app does: with more to come, it stops on a cursor that did not move
            expect(page.json.seq).toBeGreaterThan(since);
            since = page.json.seq;
        }
        throw new Error("the walk did not end");
    };

    it("lets a load from 0 finish, page by page, after delete markers were trimmed", async () => {
        const trimmed = await trimmedLibrary();
        expect(trimmed).toBe(6);
        const done = await walk(2);
        expect(done.posts).toEqual(["p1", "p2", "p3", "p4"]);
        expect(done.cursors.length).toBe(2);
        // the device is caught up: its cursor is not below the trim, and the next pull is an empty page
        expect(done.seq).toBe(trimmed);
        const next = await get(`/sync?since=${done.seq}`);
        expect(next.status).toBe(200);
        expect(next.json).toMatchObject({ seq: done.seq, more: false, posts: [], gone: [] });
        // and it goes on from there
        insertItem("p6");
        const later = await get(`/sync?since=${done.seq}`);
        expect(later.json.posts.map((p: { id: string }) => p.id)).toEqual(["p6"]);
    });

    it("ends a one-page load at the trim when the newest change was a trimmed delete", async () => {
        const trimmed = await trimmedLibrary(["p1", "p2", "p3"], "p3");
        expect(head()).toBeLessThan(trimmed);
        const page = await get("/sync?since=0");
        expect(page.json).toMatchObject({ seq: trimmed, more: false });
        expect(page.json.posts.map((p: { id: string }) => p.id)).toEqual(["p1", "p2"]);
        expect((await get(`/sync?since=${trimmed}`)).status).toBe(200);
    });

    it("still refuses a cursor from before the trim, whatever row it names", async () => {
        const trimmed = await trimmedLibrary();
        for (const since of [1, 2, 4, trimmed - 1]) {
            const stale = await get(`/sync?since=${since}&limit=2`);
            expect(stale.status).toBe(410);
            expect(stale.json).toEqual({ error: "sync.cursor_too_old" });
        }
        expect((await get(`/sync?since=${trimmed}`)).status).toBe(200);
    });

    it("refuses the cursor of a load that was left unfinished while more was trimmed", async () => {
        await trimmedLibrary();
        const first = await get("/sync?since=0&limit=2");
        expect(first.json.more).toBe(true);
        expect(first.json.seq).toBeGreaterThan(WALK_BASE);
        // p1 was on the page the device holds; it is deleted, and that marker is trimmed before the device returns
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'p1'").run();
        db.raw.prepare("UPDATE changes SET at = 1 WHERE gone = 1").run();
        await trimGoneMarkers(db, 1_000);
        expect((await get(`/sync?since=${first.json.seq}&limit=2`)).status).toBe(410);
        const again = await walk(2);
        expect(again.posts).toEqual(["p2", "p3", "p4"]);
    });

    it("hands out plain numbers while nothing was trimmed", async () => {
        for (const id of ["p1", "p2", "p3"]) insertItem(id);
        const first = await get("/sync?since=0&limit=2");
        expect(first.json).toMatchObject({ seq: 2, more: true });
        const second = await get("/sync?since=2&limit=2");
        expect(second.json).toMatchObject({ seq: 3, more: false });
    });

    it("refuses a cursor above the head, and not the cursor of a device that is caught up", async () => {
        for (const id of ["p1", "p2", "p3"]) insertItem(id);
        expect((await get(`/sync?since=${head()}`)).status).toBe(200);
        const above = await get(`/sync?since=${head() + 1}`);
        expect(above.status).toBe(410);
        expect(above.json).toEqual({ error: "sync.cursor_too_old" });
        expect((await get("/sync?since=999999")).status).toBe(410);
        // an empty log has head 0
        db.raw.prepare("DELETE FROM changes").run();
        expect((await get("/sync?since=0")).status).toBe(200);
        expect((await get("/sync?since=1")).status).toBe(410);
    });

    it("counts a trimmed newest row as the head", async () => {
        insertItem("p1");
        insertItem("p2");
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'p2'").run();
        const caughtUp = (await get("/sync?since=0")).json.seq as number;
        expect(caughtUp).toBe(head());
        db.raw.prepare("UPDATE changes SET at = 1 WHERE gone = 1").run();
        await trimGoneMarkers(db, 1_000);
        expect(head()).toBeLessThan(caughtUp);
        expect((await get(`/sync?since=${caughtUp}`)).json).toMatchObject({ seq: caughtUp, more: false, posts: [], gone: [] });
        expect((await get(`/sync?since=${caughtUp + 1}`)).status).toBe(410);
    });
});

describe("change numbers past the first-load cursor's base", () => {
    // p1 and p2 keep low numbers, p3's delete marker is trimmed, then the log's numbers jump to `to`
    const grownLog = async (to: number) => {
        for (const id of ["p1", "p2", "p3"]) insertItem(id);
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'p3'").run();
        db.raw.prepare("UPDATE changes SET at = 1 WHERE gone = 1").run();
        const trimmed = await trimGoneMarkers(db, 1_000);
        db.raw.prepare("UPDATE sqlite_sequence SET seq = ? WHERE name = 'changes'").run(to);
        insertItem("p4");
        expect(head()).toBe(to + 1);
        return trimmed;
    };

    it("keeps a caught-up device's plain cursor good, and reads on from it", async () => {
        const trimmed = await grownLog(WALK_BASE + 122);
        expect(trimmed).toBe(4);
        const load = await get("/sync?since=0");
        expect(load.json).toMatchObject({ seq: WALK_BASE + 123, more: false });
        // the same number would name row 123 of a load under trimmed_seq 1 if it were read as that form
        const idle = await get(`/sync?since=${load.json.seq}`);
        expect(idle.status).toBe(200);
        expect(idle.json).toMatchObject({ seq: WALK_BASE + 123, more: false, posts: [], gone: [] });
        insertItem("p5");
        const next = await get(`/sync?since=${load.json.seq}`);
        expect(next.status).toBe(200);
        expect(next.json.posts.map((p: { id: string }) => p.id)).toEqual(["p5"]);
        expect(next.json.seq).toBe(WALK_BASE + 124);
        // also when trimmed_seq is the one that number would name
        db.raw.prepare("UPDATE sync_state SET trimmed_seq = 1 WHERE id = 1").run();
        const same = await get(`/sync?since=${load.json.seq}`);
        expect(same.json.posts.map((p: { id: string }) => p.id)).toEqual(["p5"]);
        // above the head is still refused
        expect((await get(`/sync?since=${WALK_BASE + 125}`)).status).toBe(410);
    });

    it("still lets a load from 0 finish page by page, and refuses it after another trim", async () => {
        const trimmed = await grownLog(WALK_BASE + 122);
        const first = await get("/sync?since=0&limit=1");
        expect(first.json).toMatchObject({ seq: trimmed * WALK_BASE + 1, more: true });
        const second = await get(`/sync?since=${first.json.seq}&limit=1`);
        expect(second.json).toMatchObject({ seq: trimmed * WALK_BASE + 2, more: true });
        expect(second.json.posts.map((p: { id: string }) => p.id)).toEqual(["p2"]);
        const third = await get(`/sync?since=${second.json.seq}&limit=1`);
        expect(third.json).toMatchObject({ seq: WALK_BASE + 123, more: false });
        expect(third.json.posts.map((p: { id: string }) => p.id)).toEqual(["p4"]);
        db.raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'p1'").run();
        db.raw.prepare("UPDATE changes SET at = 1 WHERE gone = 1").run();
        await trimGoneMarkers(db, 1_000);
        expect((await get(`/sync?since=${second.json.seq}&limit=1`)).status).toBe(410);
    });

    it("hands out no first-load cursor the head could reach: the page answers the plain number", async () => {
        const trimmed = await grownLog(4 * WALK_BASE);
        expect(trimmed).toBe(4);
        const first = await get("/sync?since=0&limit=1");
        expect(first.json).toMatchObject({ seq: 1, more: true });
        // the limit the contract states: that plain number is below the trim
        expect((await get("/sync?since=1&limit=1")).status).toBe(410);
        // and a number of the first-load form's size that is not above the head is a plain cursor
        const plain = await get(`/sync?since=${trimmed * WALK_BASE + 1}`);
        expect(plain.status).toBe(200);
        expect(plain.json).toMatchObject({ seq: 4 * WALK_BASE + 1, more: false, posts: [], gone: [] });
        // one page still loads everything
        const whole = await get("/sync?since=0");
        expect(whole.json.posts.map((p: { id: string }) => p.id)).toEqual(["p1", "p2", "p4"]);
    });
});

describe("after a database restore", () => {
    it("the runbook step makes every device reload, and the numbers go on above every old cursor", async () => {
        for (const id of ["p1", "p2", "p3"]) insertItem(id);
        const device = (await get("/sync?since=0")).json.seq as number;
        // the restored log has grown back past the device's cursor: the rule alone cannot see it
        db.raw.prepare("UPDATE sqlite_sequence SET seq = seq + 1000000 WHERE name = 'changes'").run();
        db.raw.prepare("UPDATE sync_state SET trimmed_seq = (SELECT seq FROM sqlite_sequence WHERE name = 'changes') WHERE id = 1").run();
        expect((await get(`/sync?since=${device}`)).status).toBe(410);
        const reload = await get("/sync?since=0");
        expect(reload.json.posts.length).toBe(3);
        expect(reload.json.seq).toBe(1_000_003);
        insertItem("p4");
        const next = await get(`/sync?since=${reload.json.seq}`);
        expect(next.json.posts.map((p: { id: string }) => p.id)).toEqual(["p4"]);
        expect(next.json.seq).toBe(1_000_004);
    });
});

describe("migration 0038 applied again", () => {
    const DIR = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
    const files = readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort();
    const before = files.filter((f) => f < "0038").map((f) => readFileSync(DIR + f, "utf8")).join("\n");
    const sync = readFileSync(DIR + files.find((f) => f.startsWith("0038"))!, "utf8");

    // a library from before the migration: keys not stored yet, and one of each synced thing
    const seeded = () => {
        const raw = new DatabaseSync(":memory:");
        raw.exec(before);
        raw.prepare("INSERT INTO studio_sessions (id, link, status, created_at, expires_at) VALUES ('sessUpload', 'upload:fileOld', 'ready', 1, 9), ('sessSaved', 'https://x.com/1', 'ready', 1, 9)").run();
        const item = raw.prepare(ITEM_SQL);
        item.run(itemRow("fileOld", { post_key: null, link: null, created_at: 100 }) as any);
        item.run(itemRow("fileRender", { post_key: null, session_id: "sessUpload", created_at: 150 }) as any);
        item.run(itemRow("fileSaved", { post_key: null, session_id: "sessSaved", created_at: 300 }) as any);
        item.run(itemRow("fileLink", { post_key: null, link: "https://y.com/z", created_at: 200 }) as any);
        item.run(itemRow("fileMade", { post_key: "fileLink", created_at: 50 }) as any);
        raw.prepare("UPDATE media_items SET deleted_at = 5 WHERE id = 'fileMade'").run();
        item.run(itemRow("fileDead", { post_key: null, link: null, created_at: 400 }) as any);
        raw.prepare("UPDATE media_items SET deleted_at = 5 WHERE id = 'fileDead'").run();
        raw.prepare("INSERT INTO share_sets (id, items, created_at) VALUES ('linkOld', '[]', 1), ('linkNew', '[]', 2)").run();
        raw.prepare("INSERT INTO share_sets (id, items, created_at, revoked_at) VALUES ('linkOff', '[]', 3, 4)").run();
        raw.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES ('col1', 'trips', 1, 1)").run();
        raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES ('col1', 'linkOld', 1)").run();
        raw.prepare("INSERT INTO collection_groups (id, name, created_at, updated_at) VALUES ('set1', 'summer', 1, 1)").run();
        raw.prepare("INSERT INTO search_names (id, name, name_key, meaning, created_at, updated_at) VALUES ('name1', 'Lia', 'lia', 'a cat', 1, 1)").run();
        raw.prepare("INSERT INTO hidden_rules (id, kind, value, created_at, updated_at) VALUES ('rule1', 'words', 'capybara', 1, 1)").run();
        return raw;
    };
    // everything the migration makes or fills (the change log without its clock)
    const state = (raw: DatabaseSync) => ({
        schema: raw.prepare("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").all(),
        keys: raw.prepare("SELECT id, post_key FROM media_items ORDER BY id").all(),
        changes: raw.prepare("SELECT seq, entity, id, gone FROM changes ORDER BY seq").all(),
        next: raw.prepare("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").all(),
        state: raw.prepare("SELECT id, trimmed_seq FROM sync_state").all(),
        idempotency: raw.prepare("SELECT caller, key FROM idempotency_keys ORDER BY caller, key").all(),
    });

    it("ends in the same state when applied twice, and again after writes", () => {
        const raw = seeded();
        raw.exec(sync);
        const once = state(raw);
        expect(once.keys).toEqual([
            { id: "fileDead", post_key: "fileDead" },
            { id: "fileLink", post_key: "https://y.com/z" },
            { id: "fileMade", post_key: "fileLink" },
            { id: "fileOld", post_key: "fileOld" },
            { id: "fileRender", post_key: "fileOld" },
            { id: "fileSaved", post_key: "sessSaved" },
        ]);
        expect(once.changes.length).toBe(9);
        expect(once.state).toEqual([{ id: 1, trimmed_seq: 0 }]);
        raw.exec(sync);
        expect(state(raw)).toEqual(once);

        // the library moves on: an edit, a delete, a new file, a trim, a stored key
        raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('sessSaved', 'spa day', 5)").run();
        raw.prepare("UPDATE media_items SET deleted_at = 9 WHERE id = 'fileLink'").run();
        raw.prepare(ITEM_SQL).run(itemRow("fileNew", { post_key: null, link: null }) as any);
        raw.prepare("DELETE FROM share_sets WHERE id = 'linkOld'").run();
        raw.prepare("UPDATE sync_state SET trimmed_seq = 4 WHERE id = 1").run();
        raw.prepare("INSERT INTO idempotency_keys (caller, key, fingerprint, status, body, seq, created_at) VALUES ('c', 'k', 'f', 200, '{}', 1, 1)").run();
        const moved = state(raw);
        expect(moved).not.toEqual(once);
        raw.exec(sync);
        expect(state(raw)).toEqual(moved);
    });

    it("does not fail when a live write logged a thing between the triggers and the seed", () => {
        const raw = seeded();
        const cut = sync.indexOf("-- ---- backfill, then the index");
        expect(cut).toBeGreaterThan(0);
        raw.exec(sync.slice(0, cut));
        // the API is live while the file runs: a title for a post whose key the insert already stored, and a new link
        raw.prepare(ITEM_SQL).run(itemRow("fileLive", { post_key: null, link: null, created_at: 500 }) as any);
        raw.prepare("INSERT INTO share_sets (id, items, created_at) VALUES ('linkLive', '[]', 9)").run();
        expect(raw.prepare("SELECT entity, id FROM changes ORDER BY seq").all()).toEqual([
            { entity: "post", id: "fileLive" },
            { entity: "link", id: "linkLive" },
        ]);
        raw.exec(sync.slice(cut));
        const rows = raw.prepare("SELECT entity, id FROM changes").all() as { entity: string; id: string }[];
        expect(rows.filter((r) => r.id === "fileLive" || r.id === "linkLive").length).toBe(2);
        expect(new Set(rows.map((r) => `${r.entity}:${r.id}`)).size).toBe(rows.length);
        expect(rows.length).toBe(11);
    });

    it("seeds the newest posts first, so a first page shows recent saves", () => {
        const raw = seeded();
        raw.exec(sync);
        const posts = raw.prepare("SELECT id FROM changes WHERE entity = 'post' ORDER BY seq").all().map((r) => (r as { id: string }).id);
        // newest file of each post: sessSaved 300, https://y.com/z 200, fileOld 150 (its render); the deleted ones are not seeded
        expect(posts).toEqual(["sessSaved", "https://y.com/z", "fileOld"]);
        const links = raw.prepare("SELECT id FROM changes WHERE entity = 'link' ORDER BY seq").all().map((r) => (r as { id: string }).id);
        expect(links).toEqual(["linkNew", "linkOld"]);
        expect((raw.prepare("SELECT MIN(seq) AS n FROM changes WHERE entity = 'post'").get() as { n: number }).n).toBe(1);
    });
});

describe("idempotency keys", () => {
    const patch = (title: string, key: string, client = CLIENT) =>
        call("/library/items/file000000000001/post", {
            method: "PATCH",
            headers: { authorization: `Api-Key ${client}`, "content-type": "application/json", "idempotency-key": key },
            body: JSON.stringify({ title }),
        });
    const stored = () => db.raw.prepare("SELECT caller, key FROM idempotency_keys ORDER BY rowid").all() as { caller: string; key: string }[];

    it("belong to the caller: the same key from another client key is its own, and never replays the first one's answer", async () => {
        insertItem("file000000000001");
        const key = "11111111-1111-4111-8111-111111111111";
        const first = await patch("spa day", key);
        expect(first.status).toBe(200);
        // another device, the same key, another body: with one shared key this was a 409 for a write it never made
        const other = await patch("bath time", key, OTHER);
        expect(other.status).toBe(200);
        expect(db.raw.prepare("SELECT title FROM media_titles").all()).toEqual([{ title: "bath time" }]);
        expect(Number(other.headers.get(CHANGE_SEQ_HEADER))).toBeGreaterThan(Number(first.headers.get(CHANGE_SEQ_HEADER)));
        const rows = stored();
        expect(rows.map((r) => r.key)).toEqual([key, key]);
        expect(rows[0]!.caller).not.toBe(rows[1]!.caller);
        // nothing in the table is a credential
        for (const r of rows) {
            expect(r.caller).toMatch(/^[0-9a-f]{64}$/);
            expect([await hashKey(CLIENT), await hashKey(OTHER)]).not.toContain(r.caller);
        }
        // each caller's retry still replays its own answer
        const again = await patch("spa day", key);
        expect(again.headers.get(CHANGE_SEQ_HEADER)).toBe(first.headers.get(CHANGE_SEQ_HEADER));
        expect(db.raw.prepare("SELECT title FROM media_titles").all()).toEqual([{ title: "bath time" }]);
    });

    it("refuses a key over the limit and does not run the write", async () => {
        insertItem("file000000000001");
        const long = await patch("spa day", "k".repeat(IDEMPOTENCY_KEY_MAX + 1));
        expect(long.status).toBe(400);
        expect(await long.json()).toEqual({ status: "error", error: { code: "error.idempotency.bad_key" } });
        // like every answer of these routes it carries the change number
        expect(long.headers.get(CHANGE_SEQ_HEADER)).toBe(String(head()));
        expect(head()).toBeGreaterThan(0);
        expect(db.raw.prepare("SELECT title FROM media_titles").all()).toEqual([]);
        expect(stored()).toEqual([]);
        const fits = await patch("spa day", "k".repeat(IDEMPOTENCY_KEY_MAX));
        expect(fits.status).toBe(200);
        expect(stored().length).toBe(1);
    });

    it("scopes a key by the Authorization header alone: a service header an op could never see adds nothing", async () => {
        insertItem("file000000000001");
        const key = "22222222-2222-4222-8222-222222222222";
        const first = await patch("spa day", key);
        expect(first.status).toBe(200);
        const expected = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`idempotency\nApi-Key ${CLIENT}`)))]
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("");
        expect(stored()).toEqual([{ caller: expected, key }]);
    });

    it("leaves a request without the header as it was: the write runs every time and nothing is stored", async () => {
        insertItem("file000000000001");
        const plain = (title: string) =>
            call("/library/items/file000000000001/post", {
                method: "PATCH",
                headers: { ...AUTH, "content-type": "application/json" },
                body: JSON.stringify({ title }),
            });
        const first = await plain("spa day");
        const second = await plain("spa day");
        expect([first.status, second.status]).toEqual([200, 200]);
        expect(first.headers.get(CHANGE_SEQ_HEADER)).toMatch(/^\d+$/);
        expect(stored()).toEqual([]);
    });
});
