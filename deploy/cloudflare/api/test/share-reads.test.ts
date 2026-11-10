// The share routes' D1 round trips (src/share-reads.ts and the batches in share-sets.ts, share-collections.ts and
// collection-groups.ts): how many each route makes, and that the batched reads answer exactly what the statements
// they replace answer one after another. The same world is built twice, on a database that refuses a batch that
// starts with a read (every route then takes its sequential path, the code as it was) and on one that batches, and
// each call's answer and the tables it leaves are compared.
import { describe, expect, it } from "vitest";
import type { FakeD1 } from "../../test-support/d1-sqlite";
import { createGroup, deleteGroup, listGroups, updateGroup, type GroupDeps } from "../src/collection-groups";
import { timedDb } from "../src/d1-timing";
import { hashKey } from "../src/keys";
import { createCollection, deleteCollection, listCollections, rerollCollection, updateCollection, type CollectionDeps } from "../src/share-collections";
import { createShareSet, listShareSets, revokeShareSet, updateShareSet, type ShareSetDeps } from "../src/share-sets";
import type { StudioReply } from "../src/studio";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";

// A database as the routes knew it before they batched their reads: a batch of writes works (the routes always had
// those), one that starts with a SELECT fails, so every reader falls back to its statements one after another.
function readsInTurn(db: FakeD1): FakeD1 {
    const sqlOf = new WeakMap<object, string>();
    const tag = (s: any, sql: string) => {
        sqlOf.set(s, sql);
        const bind = s.bind;
        s.bind = (...p: unknown[]) => tag(bind(...p), sql);
        return s;
    };
    const prepare = db.prepare.bind(db);
    (db as any).prepare = (sql: string) => tag(prepare(sql), sql);
    const batch = (db as any).batch;
    (db as any).batch = async (statements: object[]) => {
        if (/^\s*SELECT/i.test(sqlOf.get(statements[0]!) ?? "")) throw new Error("D1_ERROR: a batch that starts with a read is refused here");
        return batch(statements);
    };
    return db;
}

// bytes that are the same every time a world is built, so both worlds mint the same ids and keys
const bytes = (seed: number) => {
    return (n: number) => Uint8Array.from({ length: n }, () => (seed = (seed * 73 + 41) % 241));
};

type World = {
    db: FakeD1;
    sets: ShareSetDeps;
    collections: CollectionDeps;
    groups: GroupDeps;
    file: (over: Record<string, unknown>) => string;
};

function world(db: FakeD1, real: D1Database = db): World {
    let t = 10_000;
    const now = () => (t += 10);
    let n = 0;
    const file = (over: Record<string, unknown>): string => {
        n++;
        const r = {
            id: `File${String(n).padStart(12, "0")}`,
            kind: "private",
            source: "saved",
            bucket: "originals",
            r2_key: `originals/sess${n}.mp4`,
            url: null,
            name: `clip${n}.mp4`,
            content_type: "video/mp4",
            bytes: 4096,
            width: 480,
            height: 560,
            duration: 9.6,
            // its own link: its own post
            link: `https://x.com/someone/status/${n}`,
            session_id: null,
            key_id: "k",
            created_at: 1_000 + n,
            deleted_at: null,
            poster: null,
            visibility: null,
            public_key: null,
            public_id: null,
            post_key: null,
            ...over,
        };
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key)
                 VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key)`,
            )
            .run(r as any);
        return r.id;
    };
    return {
        db,
        sets: { db: real, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, now, randomBytes: bytes(1), keyBytes: bytes(2) },
        collections: { db: real, now, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, randomBytes: bytes(3), setRandomBytes: bytes(4) },
        groups: { db: real, now, randomBytes: bytes(5) },
        file,
    };
}

const publicFile = (w: World, n: number, over: Record<string, unknown> = {}) =>
    w.file({ visibility: "public", public_key: `PuBlIc${String(n).padStart(4, "0")}.mp4`, poster: `${MEDIA}PoStEr${String(n).padStart(4, "0")}.jpg`, ...over });
const post = (body: unknown) => new Request("https://x/", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const patch = (body: unknown) => new Request("https://x/", { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const hide = (w: World, postKey: string, state = "hidden") =>
    w.db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, ?, 'you', NULL, 1)").run(postKey, state);
const postKeyOf = (n: number) => `https://x.com/someone/status/${n}`;
const TABLES = ["share_sets", "private_links", "media_hidden", "share_collections", "share_collection_items", "collection_groups", "collection_group_items", "media_captions"];
// a private link's key is last: a reroll's new keys are random, so the rows are put in order by everything else
const dump = (db: FakeD1) =>
    Object.fromEntries(TABLES.map((t) => [t, db.raw.prepare(`SELECT * FROM ${t} ORDER BY ${t === "private_links" ? "created_at, target_id, revoked_at" : "1, 2"}`).all().map((r) => ({ ...r }))]));
// The same value with every private link key (22 letters and digits) named by when it first comes up: a reroll gives
// its links random keys, which no two runs share.
const keysNamed = <T>(value: T): T => {
    const names = new Map<string, string>();
    return JSON.parse(
        JSON.stringify(value).replace(/(\/p\/|"key":")([A-Za-z0-9]{22})(?![A-Za-z0-9])/g, (_m, lead: string, key: string) => {
            if (!names.has(key)) names.set(key, `key-${names.size + 1}`);
            return `${lead}${names.get(key)}`;
        }),
    );
};

// Every share route, in an order that meets each of their branches. Returns each answer, in order.
async function script(w: World): Promise<StudioReply[]> {
    const out: StudioReply[] = [];
    const say = async (r: Promise<StudioReply>) => {
        const reply = await r;
        out.push(reply);
        return reply.body as any;
    };
    const a = publicFile(w, 1);
    const b = publicFile(w, 2);
    const c = publicFile(w, 3, { content_type: "image/jpeg", public_key: "PuBlIc0003.jpg", duration: null });
    const priv = w.file({});
    const gone = publicFile(w, 5, { deleted_at: 9 });
    const hidden = publicFile(w, 6);
    const held = publicFile(w, 7);
    // a public copy named by its own id in a link (old links store it): the original's row answers for it
    const copy = publicFile(w, 8, { public_id: "Copy000000000008" });

    // gallery links: public, private by request, private by the owner's setting, the refusals
    const one = (await say(createShareSet(w.sets, post({ items: [a, b], title: "first" }), "key-1"))).set.id;
    const two = (await say(createShareSet(w.sets, post({ items: [b, c, priv], private: true }), "key-1"))).set.id;
    await say(createShareSet(w.sets, post({ items: [a, priv] }), "key-1"));
    await say(createShareSet(w.sets, post({ items: [a, gone] }), "key-1"));
    w.db.raw.prepare("INSERT INTO share_settings (id, new_links, updated_at) VALUES (1, 'private', 1)").run();
    const three = (await say(createShareSet(w.sets, post({ items: [a, c, priv] }), "key-1"))).set.id;
    w.db.raw.prepare("UPDATE share_settings SET new_links = 'public'").run();
    const four = (await say(createShareSet(w.sets, post({ items: [a, held, hidden, copy] }), "key-1"))).set.id;
    // a held post's wait ended when it was shared; a post hidden later drops out of its links
    hide(w, postKeyOf(7), "held");
    hide(w, postKeyOf(6));
    await say(createShareSet(w.sets, post({ items: [hidden, held] }), "key-1"));
    await say(createShareSet(w.sets, post({ items: [a, "Copy000000000008"] }), "key-1"));
    await say(listShareSets(w.sets));

    // PATCH: move, add, take out, title, the refusals and both 409s
    await say(updateShareSet(w.sets, patch({ items: [b, a] }), one));
    await say(updateShareSet(w.sets, patch({ items: [b, a, c], title: null }), one));
    await say(updateShareSet(w.sets, patch({ items: [b, a, c, priv] }), one));
    await say(updateShareSet(w.sets, patch({ items: [b, a, c, hidden] }), one));
    hide(w, postKeyOf(1), "held");
    await say(updateShareSet(w.sets, patch({ items: [c, b, priv, a] }), two));
    await say(updateShareSet(w.sets, patch({ items: [a, b], expect: [a, b] }), one));
    await say(updateShareSet(w.sets, patch({ title: "typed" }), four));
    await say(updateShareSet(w.sets, patch({ title: "x" }), "1111111111111111111"));

    // collections and their sets
    const col = (await say(createCollection(w.collections, post({ name: "picks", set_ids: [one, two] }), "key-1"))).collection.id;
    const other = (await say(createCollection(w.collections, post({ name: "other", set_ids: [two, three] }), "key-1"))).collection.id;
    await say(createCollection(w.collections, post({ name: "bad", set_ids: ["1111111111111111111"] }), "key-1"));
    await say(updateCollection(w.collections, patch({ name: "renamed", add: [three, four], remove: [two] }), col));
    await say(updateCollection(w.collections, patch({ add: ["1111111111111111111"] }), col));
    await say(updateCollection(w.collections, patch({ name: "x" }), "AAAAAAAAAAAAAAAA"));
    await say(listCollections(w.collections));
    const group = (await say(createGroup(w.groups, post({ name: "all", collection_ids: [col, other] }), "key-1"))).group.id;
    await say(createGroup(w.groups, post({ name: "bad", collection_ids: ["AAAAAAAAAAAAAAAA"] }), "key-1"));
    await say(updateGroup(w.groups, patch({ name: "both", remove: [other], add: [other] }), group));
    await say(updateGroup(w.groups, patch({ name: "x" }), "AAAAAAAAAAAAAAAA"));
    await say(listGroups(w.groups));

    // reroll: refused while a link holds a hidden file, then every link gets a new id (a private one stays private)
    await say(rerollCollection(w.collections, col, "key-1"));
    await say(rerollCollection(w.collections, other, "key-1"));
    await say(listShareSets(w.sets));
    await say(listCollections(w.collections));

    // revoke and delete, each twice
    await say(revokeShareSet(w.sets, one));
    await say(revokeShareSet(w.sets, one));
    await say(revokeShareSet(w.sets, "1111111111111111111"));
    await say(deleteCollection(w.collections, other));
    await say(deleteCollection(w.collections, other));
    await say(deleteGroup(w.groups, group));
    await say(deleteGroup(w.groups, group));
    await say(listShareSets(w.sets));
    await say(listCollections(w.collections));
    await say(listGroups(w.groups));
    return out;
}

describe("batched and one after another", () => {
    it("every share route answers the same and leaves the same rows", async () => {
        const plain = world(readsInTurn(createBatchD1()));
        const batched = world(createBatchD1());
        const a = await script(plain);
        const b = await script(batched);
        // the script reached what it set out to: no call fell over, and each kind of refusal came up
        expect(a.map((r) => r.status)).not.toContain(503);
        expect(a.map((r) => (r.body as any).error?.code).filter(Boolean)).toEqual(
            expect.arrayContaining(["error.share.not_public", "error.hidden", "error.share.changed", "error.share.not_found", "error.collection.link_not_found", "error.collection.not_found", "error.group.collection_not_found", "error.group.not_found"]),
        );
        expect(keysNamed({ answers: b, rows: dump(batched.db) })).toEqual(keysNamed({ answers: a, rows: dump(plain.db) }));
        // the private links made by request and by the owner's setting are in there, and a reroll kept one private
        expect(a.filter((r) => r.status === 201 && (r.body as any).set?.private === true)).toHaveLength(2);
        expect(a.map((r) => `${r.status} ${(r.body as any).error?.code ?? ""}`.trim())).toMatchInlineSnapshot(`
          [
            "201",
            "201",
            "409 error.share.not_public",
            "409 error.share.not_public",
            "201",
            "201",
            "409 error.hidden",
            "409 error.share.not_public",
            "200",
            "200",
            "200",
            "409 error.share.not_public",
            "409 error.hidden",
            "200",
            "409 error.share.changed",
            "200",
            "404 error.share.not_found",
            "201",
            "201",
            "409 error.collection.link_not_found",
            "200",
            "409 error.collection.link_not_found",
            "404 error.collection.not_found",
            "200",
            "201",
            "409 error.group.collection_not_found",
            "200",
            "404 error.group.not_found",
            "200",
            "409 error.hidden",
            "200",
            "200",
            "200",
            "200",
            "200",
            "404 error.share.not_found",
            "200",
            "404 error.collection.not_found",
            "200",
            "404 error.group.not_found",
            "200",
            "200",
            "200",
          ]
        `);
        expect((dump(batched.db).private_links as any[]).map((r) => r.revoked_at === null)).toEqual(expect.arrayContaining([true, false]));
        // the held post's wait ended (shareGate's other half), on both paths
        expect(dump(batched.db).media_hidden!.map((r: any) => r.state)).toEqual(["hidden"]);
    });

    it("a database without private links or the new-links setting still answers, one statement after another", async () => {
        const w = world(createBatchD1());
        const a = publicFile(w, 1);
        const b = publicFile(w, 2);
        w.db.raw.exec("DROP TABLE private_links; DROP TABLE share_settings;");
        const made = await createShareSet(w.sets, post({ items: [a, b] }), "key-1");
        expect(made.status).toBe(201);
        const id = (made.body as any).set.id;
        const listed = await listShareSets(w.sets);
        expect((listed.body as any).sets.map((s: any) => [s.id, s.private, s.items.length])).toEqual([[id, false, 2]]);
        expect((await updateShareSet(w.sets, patch({ items: [b, a] }), id)).status).toBe(200);
        expect((await revokeShareSet(w.sets, id)).status).toBe(200);
        expect(((await listShareSets(w.sets)).body as any).sets).toEqual([]);
    });

    it("a link whose stored list is not JSON is listed with no files, as before", async () => {
        const w = world(createBatchD1());
        const a = publicFile(w, 1);
        const b = publicFile(w, 2);
        const id = ((await createShareSet(w.sets, post({ items: [a, b] }), "key-1")).body as any).set.id;
        w.db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at) VALUES ('2222222222222222222', 'not json', NULL, 'k', 1)").run();
        const listed = ((await listShareSets(w.sets)).body as any).sets;
        expect(listed.map((s: any) => [s.id, s.items.length])).toEqual([
            [id, 2],
            ["2222222222222222222", 0],
        ]);
    });
});

describe("round trips", () => {
    // each call's round trips, on a database that batches; the first call of a world also asks once whether the hidden
    // posts' migration is applied (hidden-store.ts keeps the answer for the isolate's life)
    const counted = async () => {
        const raw = createBatchD1();
        const { db, stats } = timedDb(raw);
        const w = world(raw, db);
        await listShareSets(w.sets);
        // `call` starts the route: a route may send its first statement before its first await
        const trips = async <T>(call: () => Promise<T>): Promise<[number, T]> => {
            const before = stats.n;
            const value = await call();
            return [stats.n - before, value];
        };
        return { w, trips };
    };

    it("gallery links: the list is one; a new link two; a change three or four; a revoke one", async () => {
        const { w, trips } = await counted();
        const [a, b, c] = [publicFile(w, 1), publicFile(w, 2), publicFile(w, 3)];
        // the checks, then the insert
        const [made, first] = await trips(() => createShareSet(w.sets, post({ items: [a, b] }), "key-1"));
        expect([made, first.status]).toEqual([2, 201]);
        const id = (first.body as any).set.id;
        const [madePrivate, second] = await trips(() => createShareSet(w.sets, post({ items: [a, b], private: true }), "key-1"));
        expect([madePrivate, second.status]).toEqual([2, 201]);
        // 200 links of 10 files were 1 + 23 + 1 + 2 statements
        expect((await trips(() => listShareSets(w.sets)))[0]).toBe(1);
        // the link, the UPDATE, the answer
        const [retitled, t] = await trips(() => updateShareSet(w.sets, patch({ title: "typed" }), id));
        expect([retitled, t.status]).toEqual([3, 200]);
        // and the checks on the added file
        const [added, u] = await trips(() => updateShareSet(w.sets, patch({ items: [a, b, c] }), id));
        expect([added, u.status]).toEqual([4, 200]);
        // a 409 for another device's change: the link, and the set it answers
        const [changed, v] = await trips(() => updateShareSet(w.sets, patch({ items: [a, b], expect: [a, b] }), id));
        expect([changed, v.status]).toEqual([2, 409]);
        const [revoked, x] = await trips(() => revokeShareSet(w.sets, id));
        expect([revoked, x.status]).toEqual([1, 200]);
        expect((await trips(() => revokeShareSet(w.sets, "1111111111111111111")))[1].status).toBe(404);
    });

    it("a new link's caption: one more when the route waits for it, none before the answer when it does not", async () => {
        const { w, trips } = await counted();
        const [a, b] = [publicFile(w, 1), publicFile(w, 2)];
        // the model answers when `answer` is called
        let answer = () => {};
        const asked = new Promise<void>((r) => (answer = r));
        const captioner = { model: "fake", caption: async () => (await asked, { title: "two clips (=^･ω･^=)", description: "" }) };
        answer();
        expect((await trips(() => createShareSet({ ...w.sets, captioner }, post({ items: [a, b] }), "key-1")))[0]).toBe(3);
        const later: Promise<unknown>[] = [];
        const slow = { model: "fake", caption: () => new Promise<{ title: string; description: string }>((r) => (answer = () => r({ title: "two clips (=^･ω･^=)", description: "" }))) };
        const [n, made] = await trips(() => createShareSet({ ...w.sets, captioner: slow, waitUntil: (p) => later.push(p) }, post({ items: [a, b] }), "key-1"));
        expect([n, made.status, later.length]).toEqual([2, 201, 1]);
        answer();
        await Promise.all(later);
        expect(w.db.raw.prepare("SELECT title FROM media_captions WHERE subject = ?").get(`set:${(made.body as any).set.id}`)).toEqual({ title: "two clips (=^･ω･^=)" });
    });

    it("collections and their sets: a list is one, a create or a change two, a delete one", async () => {
        const { w, trips } = await counted();
        const [a, b] = [publicFile(w, 1), publicFile(w, 2)];
        const mk = async () => ((await createShareSet(w.sets, post({ items: [a, b] }), "key-1")).body as any).set.id as string;
        const [s1, s2, s3] = [await mk(), await mk(), await mk()];
        const [made, c] = await trips(() => createCollection(w.collections, post({ name: "picks", set_ids: [s1, s2] }), "key-1"));
        expect([made, c.status]).toEqual([2, 201]);
        const col = (c.body as any).collection.id;
        const [changed, u] = await trips(() => updateCollection(w.collections, patch({ name: "renamed", add: [s3], remove: [s1] }), col));
        expect([changed, u.status]).toEqual([2, 200]);
        expect((u.body as any).collection).toMatchObject({ name: "renamed", set_ids: [s3, s2] });
        expect((await trips(() => listCollections(w.collections)))[0]).toBe(1);
        // the collection, its links, the hidden check (two), their private links, the writes with the answer behind them
        const [rerolled, r] = await trips(() => rerollCollection(w.collections, col, "key-1"));
        expect([rerolled, r.status]).toEqual([6, 200]);

        const [gMade, g] = await trips(() => createGroup(w.groups, post({ name: "all", collection_ids: [col] }), "key-1"));
        expect([gMade, g.status]).toEqual([2, 201]);
        const group = (g.body as any).group.id;
        const [gChanged, gu] = await trips(() => updateGroup(w.groups, patch({ name: "both" }), group));
        expect([gChanged, gu.status]).toEqual([2, 200]);
        expect((gu.body as any).group).toMatchObject({ name: "both", collection_ids: [col] });
        expect((await trips(() => listGroups(w.groups)))[0]).toBe(1);
        expect((await trips(() => deleteGroup(w.groups, group)))[0]).toBe(1);
        expect((await trips(() => deleteCollection(w.collections, col)))[0]).toBe(1);
        expect((await listCollections(w.collections)).body).toEqual({ status: "success", collections: [] });
    });

    it("through the Worker: GET /share/sets is the key and the list; GET /share/private adds its two reads", async () => {
        const raw = createBatchD1();
        const { db, stats } = timedDb(raw);
        const w = world(raw, db);
        const [a, b] = [publicFile(w, 1), publicFile(w, 2)];
        await createShareSet(w.sets, post({ items: [a, b] }), "key-1");
        const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
        raw.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
            DB: db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: MEDIA,
            SHARE_BASE_URL: SHARE,
        };
        const container = { fetch: async () => new Response("{}") };
        const get = async (path: string) => {
            const before = stats.n;
            const res = await handleRequest(new Request(`https://api.capybaraharmony.com${path}`, { headers: { authorization: `Api-Key ${CLIENT}` } }), env, container, { now: () => 5_000 });
            expect(res.status).toBe(200);
            return [stats.n - before, (await res.json()) as any] as const;
        };
        const [sets, listed] = await get("/share/sets");
        expect(sets).toBe(2);
        expect(listed.sets).toHaveLength(1);
        // its links and the new-links setting are private-actions.ts's own two statements
        const [priv, body] = await get("/share/private");
        expect(priv).toBe(4);
        expect(body.sets).toEqual(listed.sets);
    });
});
