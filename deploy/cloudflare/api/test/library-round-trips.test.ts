// The library routes ask D1 as few times as they can (D1 is one region away from where the Worker may run, and every
// statement asked on its own is a full round trip): what a route reads goes in one batch per step, and what its answer
// does not report does not hold it. Each case here pins two things for one route: how many round trips it makes, and
// that the batched path answers exactly what the statement-by-statement path answers. That second path is still what
// runs when the database has no batch (the plain fake) or a batch fails, so both are run over the same library.
import { afterEach, describe, expect, it, vi } from "vitest";
import { aboutObjectKeys } from "../src/about-store";
import { capabilities, encodeCursor, libraryItemDelete, libraryList, libraryPostDelete, type AppDeps } from "../src/app-routes";
import { timedDb, type D1Stats } from "../src/d1-timing";
import { listRules } from "../src/hidden";
import { KeyCache, hashKey } from "../src/keys";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { countWaits } from "./d1-waits";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const T = 1_800_000_000_000;
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

const sid = (s: string) => s.padEnd(22, "a");
const iid = (s: string) => s.padEnd(16, "0");

// a saved video: its original (public, a merged pair with a retired host row), a webp, a webp switched private
const S1 = sid("Sess1");
const O1 = iid("Orig1");
const H1 = iid("Host1");
const W1 = iid("Webp1");
const W1P = iid("Webp1p");
// an uploaded picture with a private link and a title of its own
const U2 = iid("Upl2");
const LINK_KEY = "Kk".padEnd(22, "3");
// a gallery: two photos (a third could not be saved) and a slideshow made from them
const S3 = sid("Sess3");
const G3A = iid("Gal3a");
const G3B = iid("Gal3b");
const G3S = iid("Gal3s");
// a hidden post
const X4 = iid("Hid4");
// two more uploads, and a saved video that still has no poster
const U5 = iid("Upl5");
const U6 = iid("Upl6");
const S7 = sid("Sess7");
const O7 = iid("Orig7");
// what only a delete finds: the stored original of a second session of post 1, which no row names
const S1B = sid("Sess1b");
const LEFTOVER = "uploads/Left000000000001.mp4";

const POSTER = `${MEDIA}Poster0001.jpg`;

type Row = Record<string, string | number | null>;

function addItem(db: FakeD1, row: Row) {
    const full: Row = {
        kind: "private",
        source: "upload",
        bucket: "originals",
        url: null,
        content_type: "image/png",
        bytes: 100,
        width: null,
        height: null,
        duration: null,
        link: null,
        session_id: null,
        key_id: "key-1",
        deleted_at: null,
        poster: null,
        poster_at: null,
        visibility: null,
        public_key: null,
        public_id: null,
        merged_into: null,
        item_index: null,
        role: null,
        made_from: null,
        made_spec: null,
        post_key: null,
        ...row,
    };
    const cols = Object.keys(full);
    db.raw.prepare(`INSERT INTO media_items (${cols.join(", ")}) VALUES (${cols.map((c) => `@${c}`).join(", ")})`).run(full as any);
}

function addSession(db: FakeD1, row: Row) {
    const full: Row = { key_id: "key-1", service: null, title: null, status: "ready", content_type: "video/mp4", bytes: 1000, items: null, ...row };
    const cols = Object.keys(full);
    db.raw.prepare(`INSERT INTO studio_sessions (${cols.join(", ")}) VALUES (${cols.map((c) => `@${c}`).join(", ")})`).run(full as any);
}

function seed(db: FakeD1) {
    addSession(db, { id: S1, link: "https://x.com/a/status/1", service: "x", r2_key: `originals/${S1}.mp4`, created_at: T - 9000, expires_at: T + 1_000_000 });
    addSession(db, { id: S1B, link: `upload:${S1}`, r2_key: LEFTOVER, created_at: T - 8900, expires_at: T + 1_000_000 });
    addItem(db, {
        id: O1,
        source: "saved",
        r2_key: `originals/${S1}.mp4`,
        name: "clip",
        content_type: "video/mp4",
        bytes: 1000,
        width: 480,
        height: 560,
        duration: 9.5,
        link: "https://x.com/a/status/1",
        session_id: S1,
        created_at: T - 9000,
        poster: POSTER,
        visibility: "public",
        public_key: "PubKey0001.mp4",
        public_id: H1,
        url: `${MEDIA}PubKey0001.mp4`,
    });
    addItem(db, {
        id: H1,
        kind: "public",
        source: "host",
        bucket: "media",
        r2_key: "PubKey0001.mp4",
        url: `${MEDIA}PubKey0001.mp4`,
        name: "clip.mp4",
        content_type: "video/mp4",
        bytes: 900,
        session_id: S1,
        created_at: T - 8500,
        deleted_at: T - 8000,
        merged_into: O1,
        poster: POSTER,
    });
    addItem(db, { id: W1, kind: "public", source: "studio", bucket: "media", r2_key: "Abcdefghij.webp", url: `${MEDIA}Abcdefghij.webp`, name: "clip.webp", content_type: "image/webp", bytes: 300, session_id: S1, created_at: T - 8200, visibility: "public" });
    addItem(db, { id: W1P, source: "studio", r2_key: "webp/Abcdefghik.webp", name: "clip 2.webp", content_type: "image/webp", bytes: 40, session_id: S1, created_at: T - 8100, visibility: "private" });
    db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, ?, ?)").run(S1, "the clip", "key-1", T - 100);
    db.raw.prepare("INSERT INTO media_about (post_key, item_id, probe_state, updated_at) VALUES (?, ?, 'done', ?)").run(S1, O1, T - 100);

    addItem(db, { id: U2, r2_key: `uploads/${U2}.png`, name: "pic.png", bytes: 50, created_at: T - 7000 });
    db.raw.prepare("INSERT INTO private_links (key, kind, target_id, created_at) VALUES (?, 'item', ?, ?)").run(LINK_KEY, U2, T - 6900);
    db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, ?, ?)").run(U2, "my pic", "key-1", T - 100);

    addSession(db, {
        id: S3,
        link: "https://www.tiktok.com/@a/photo/3",
        service: "tiktok",
        r2_key: `originals/${S3}-00.jpg`,
        content_type: "image/jpeg",
        created_at: T - 6000,
        expires_at: T + 1_000_000,
        items: JSON.stringify([{ i: 0, status: "ready" }, { i: 1, status: "ready" }, { i: 2, status: "error" }]),
    });
    const gallery = { source: "saved", content_type: "image/jpeg", link: "https://www.tiktok.com/@a/photo/3", session_id: S3, post_key: S3 };
    addItem(db, { ...gallery, id: G3A, r2_key: `originals/${S3}-00.jpg`, name: "photo 1", role: "item", item_index: 0, created_at: T - 6000 });
    addItem(db, { ...gallery, id: G3B, r2_key: `originals/${S3}-01.jpg`, name: "photo 2", role: "item", item_index: 1, created_at: T - 5990 });
    addItem(db, { ...gallery, id: G3S, source: "studio", r2_key: `made/${G3S}.mp4`, name: "slideshow.mp4", content_type: "video/mp4", role: "slideshow", made_from: JSON.stringify([G3A, G3B]), made_spec: JSON.stringify({ format: "mp4" }), created_at: T - 5000 });

    addItem(db, { id: X4, r2_key: `uploads/${X4}.png`, name: "hidden.png", created_at: T - 4000 });
    db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'hidden', 'you', NULL, ?)").run(X4, T - 3900);

    addItem(db, { id: U5, r2_key: `uploads/${U5}.png`, name: "five.png", created_at: T - 3000 });
    addItem(db, { id: U6, r2_key: `uploads/${U6}.png`, name: "six.png", created_at: T - 3000 });

    addSession(db, { id: S7, link: "https://x.com/a/status/7", service: "x", r2_key: `originals/${S7}.mp4`, created_at: T - 2000, expires_at: T + 1_000_000 });
    addItem(db, { id: O7, source: "saved", r2_key: `originals/${S7}.mp4`, name: "no poster yet", content_type: "video/mp4", bytes: 2000, link: "https://x.com/a/status/7", session_id: S7, created_at: T - 2000 });
}

type World = { fake: FakeD1; d: AppDeps; stats: D1Stats; originals: MemoryOriginals; media: MemoryMedia; purged: string[][] };

// One library, over a database with a batch ("batch", as the binding has) or without one ("plain").
function world(kind: "batch" | "plain", change: (db: FakeD1) => void = () => {}): World {
    const fake = kind === "batch" ? createBatchD1() : createFakeD1();
    seed(fake);
    change(fake);
    const { db, stats } = timedDb(fake);
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const blob = { bytes: new Uint8Array(1), contentType: "application/octet-stream", meta: {} };
    for (const r of fake.raw.prepare("SELECT bucket, r2_key, public_key, id FROM media_items WHERE deleted_at IS NULL").all() as any[]) {
        if (r.bucket === "originals") originals.objects.set(r.r2_key, blob);
        else media.objects.set(r.r2_key, { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
        if (r.public_key) media.objects.set(r.public_key, { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
        // one of the "what it's about" objects cut from each file
        originals.objects.set(aboutObjectKeys(r.id)[0]!, blob);
    }
    originals.objects.set(LEFTOVER, blob);
    media.objects.set("Poster0001.jpg", { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
    const purged: string[][] = [];
    const d: AppDeps = {
        db,
        originals,
        media,
        mediaBaseUrl: MEDIA,
        apiUrl: "https://api.capybaraharmony.com/",
        webUrl: "https://cobalt.capybaraharmony.com",
        shareBaseUrl: SHARE,
        now: () => T,
        fixedLength: () => {
            throw new Error("unused");
        },
        adopt: async () => {
            throw new Error("unused");
        },
        purge: async (urls) => {
            purged.push(urls);
            return true;
        },
    };
    return { fake, d, stats, originals, media, purged };
}

const q = (s = "") => new URLSearchParams(s);
// what a route did to the library: every row's state, the sessions' expiry, the titles, the about rows, the objects
const state = (w: World) => ({
    items: w.fake.raw.prepare("SELECT id, deleted_at FROM media_items ORDER BY id").all(),
    sessions: w.fake.raw.prepare("SELECT id, expires_at, r2_key FROM studio_sessions ORDER BY id").all(),
    titles: w.fake.raw.prepare("SELECT post_key, title FROM media_titles ORDER BY post_key").all(),
    about: w.fake.raw.prepare("SELECT post_key FROM media_about ORDER BY post_key").all(),
    originals: [...w.originals.objects.keys()].sort(),
    media: [...w.media.objects.keys()].sort(),
});
// the round trips `run` makes
async function trips<R>(w: World, run: () => Promise<R>): Promise<{ n: number; out: R }> {
    const before = w.stats.n;
    const out = await run();
    return { n: w.stats.n - before, out };
}

afterEach(() => {
    vi.restoreAllMocks();
});

describe("GET /library", () => {
    const QUERIES = ["", "v=2", "v=3", "hidden=1", "v=3&hidden=1", "v=3&limit=2", "limit=3", "v=2&limit=50"];

    it("answers from two batches exactly what it answers statement by statement, in every shape and on every page", async () => {
        const a = world("batch");
        const b = world("plain");
        for (const query of QUERIES) {
            const x = await libraryList(a.d, q(query));
            expect(x.status).toBe(200);
            expect(x, query).toEqual(await libraryList(b.d, q(query)));
        }
        // page by page to the end, in both
        for (const shape of ["v=3&limit=2", "limit=1"]) {
            let cursor: string | null = null;
            const seen: string[] = [];
            do {
                const query = shape + (cursor ? `&cursor=${cursor}` : "");
                const x = await libraryList(a.d, q(query));
                expect(x, query).toEqual(await libraryList(b.d, q(query)));
                const body = x.body as { posts: { id: string }[]; next: string | null; counts: unknown; usage: unknown };
                seen.push(...body.posts.map((p) => p.id));
                // the totals are the whole library's on every page
                // v=3 counts every live file of a shown post; without it a private webp and the gallery's made
                // files stay out, and the hidden post is out of both
                expect(body.counts).toEqual({ posts: 6, files: shape.startsWith("v=3") ? 10 : 7, hidden: 1 });
                // hidden posts are out of the page and still in the byte totals (X4, 100 bytes)
                expect(body.usage).toEqual({ public_bytes: 1300, private_bytes: 3690 });
                cursor = body.next;
            } while (cursor);
            expect(seen).toEqual([S7, U6, U5, S3, U2, S1]);
        }
    });

    it("the batched answer carries what each of the folded reads was for", async () => {
        const w = world("batch");
        const v3 = (await libraryList(w.d, q("v=3"))).body as any;
        const post = (id: string) => v3.posts.find((p: any) => p.id === id);
        // titles, sessions, the gallery fields
        // the newer ready session of the post (the upload one) is the one a client can reopen
        expect(post(S1)).toMatchObject({ custom_title: "the clip", service: "x", session: { id: S1B }, visibility: "public", hidden: false, hidden_by: null });
        expect(post(S3)).toMatchObject({ kind: "gallery", item_count: 2, items_failed: [2], custom_title: null });
        expect(post(S3).files.map((f: any) => f.id)).toEqual([G3A, G3B, G3S]);
        // the private link of the one file that has one
        expect(post(U2).files).toHaveLength(1);
        expect(post(U2).files[0].private_url).toBe(`${SHARE}p/${LINK_KEY}`);
        expect(v3.posts.flatMap((p: any) => p.files).filter((f: any) => f.private_url !== null)).toHaveLength(1);
        // the hidden rows
        const hidden = (await libraryList(w.d, q("v=3&hidden=1"))).body as any;
        expect(hidden.posts).toHaveLength(1);
        expect(hidden.posts[0]).toMatchObject({ id: X4, hidden: true, hidden_by: "you", hidden_rule: null });
        // legacy: the retired host row of the merged pair gives the synthesized public file its old id, name, size and time
        const legacy = (await libraryList(w.d, q())).body as any;
        const host = legacy.posts.find((p: any) => p.id === S1).files.find((f: any) => f.id === H1);
        expect(host).toMatchObject({ kind: "public", source: "host", name: "clip.mp4", bytes: 900, created_at: T - 8500, media_name: "PubKey0001.mp4", private_url: null });
    });

    it("makes two round trips where it made ten: the page with the totals, then everything about the page's posts", async () => {
        const w = world("batch");
        // the first request of an isolate also learns that migration 0025 is applied (one statement, kept for good)
        expect((await trips(w, () => libraryList(w.d, q("v=3")))).n).toBe(3);
        for (const query of ["v=3", "v=2", "", "hidden=1", "v=3&hidden=1", "v=3&limit=2", "limit=50"]) {
            expect((await trips(w, () => libraryList(w.d, q(query)))).n, query).toBe(2);
        }
        const first = (await libraryList(w.d, q("v=3&limit=2"))).body as { next: string };
        expect((await trips(w, () => libraryList(w.d, q(`v=3&limit=2&cursor=${first.next}`)))).n).toBe(2);
        // past the last post there is nothing to read about a page: one round trip, the totals still the library's
        const past = await trips(w, () => libraryList(w.d, q(`v=3&cursor=${encodeCursor(1, "a")}`)));
        expect(past.n).toBe(1);
        expect(past.out.body).toMatchObject({ posts: [], counts: { posts: 6, files: 10, hidden: 1 }, next: null });

        // without a batch: statement by statement, as it always was
        const plain = world("plain");
        await libraryList(plain.d, q("v=3"));
        expect((await trips(plain, () => libraryList(plain.d, q("v=3")))).n).toBe(10);
    });

    it("a database without the private links table fails the batch as a whole: the reads go one by one and the links are null", async () => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const drop = (db: FakeD1) => db.raw.exec("DROP TABLE private_links");
        const a = world("batch", drop);
        const b = world("plain", drop);
        for (const query of ["v=3", "", "v=3&hidden=1"]) {
            const x = await libraryList(a.d, q(query));
            expect(x.status).toBe(200);
            expect(x, query).toEqual(await libraryList(b.d, q(query)));
            const files = (x.body as any).posts.flatMap((p: any) => p.files);
            expect(files.length).toBeGreaterThan(0);
            expect(files.every((f: any) => f.private_url === null)).toBe(true);
        }
        expect(((await libraryList(a.d, q("v=3&hidden=1"))).body as any).posts[0]).toMatchObject({ id: X4, hidden: true });
    });

    it("D1 down: 503 from either path", async () => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        for (const kind of ["batch", "plain"] as const) {
            const w = world(kind);
            await libraryList(w.d, q("v=3"));
            w.fake.breakIt();
            expect(await libraryList(w.d, q("v=3"))).toEqual({ status: 503, body: { status: "error", error: { code: "error.api.generic" } } });
        }
    });

    it("the poster kick does not hold the answer where the request keeps it alive; without that it is awaited, as before", async () => {
        const w = world("batch");
        let kicks = 0;
        let answer: () => void = () => {};
        const kickPosters = () => {
            kicks += 1;
            return new Promise<{ status: number; body: unknown }>((resolve) => (answer = () => resolve({ status: 200, body: {} })));
        };
        // with waitUntil: answered while the kick is still out, and the kick is handed over
        const kept: Promise<unknown>[] = [];
        const r = await libraryList({ ...w.d, kickPosters, waitUntil: (p) => void kept.push(p) }, q("v=3"));
        expect(r.status).toBe(200);
        expect(kicks).toBe(1);
        expect(kept).toHaveLength(1);
        answer();
        await kept[0];

        // without one (a test, a Durable Object): the answer waits for the kick
        let done = false;
        const waiting = libraryList({ ...w.d, kickPosters }, q("v=3")).then((x) => {
            done = true;
            return x;
        });
        await new Promise((resolve) => setTimeout(resolve, 40));
        expect(kicks).toBe(2);
        expect(done).toBe(false);
        answer();
        expect(await waiting).toEqual(r);

        // a kick that fails is nobody's error, either way
        const failing = async () => {
            throw new Error("the Durable Object is away");
        };
        expect(await libraryList({ ...w.d, kickPosters: failing }, q("v=3"))).toEqual(r);
        expect(await libraryList({ ...w.d, kickPosters: failing, waitUntil: (p) => void kept.push(p) }, q("v=3"))).toEqual(r);
        await Promise.all(kept);

        // and a page with nothing to make a poster of does not kick
        w.fake.raw.prepare("UPDATE media_items SET poster = ? WHERE poster IS NULL").run(POSTER);
        const before = kicks;
        await libraryList({ ...w.d, kickPosters }, q("v=3"));
        expect(kicks).toBe(before);
    });
});

describe("GET /capabilities", () => {
    async function keyed(change: (db: FakeD1) => void = () => {}) {
        const fake = createBatchD1();
        fake.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "laptop", await hashKey(KEY), "0b5f2c3e", 1);
        change(fake);
        const waits = countWaits(fake);
        const { db, stats } = timedDb(fake);
        const d = { db, mediaBaseUrl: MEDIA, now: () => T, shareBaseUrl: SHARE, keyCache: new KeyCache() };
        // chat and the editor on, so that the two migrations they need are asked about too
        const caps = (dd: typeof d | Omit<typeof d, "keyCache"> = d) => capabilities(dd, "key", KEY, false, false, false, false, false, false, false, true, false, false, true);
        return { fake, d, stats, waits, caps };
    }

    it("waits for D1 once, whatever it has to ask: the key, its name and the migrations at the same time", async () => {
        const w = await keyed();
        // a new isolate: the key check, the name, and four "is this migration applied" answers
        const first = await w.caps();
        expect(first.body).toMatchObject({ key: "valid", key_name: "laptop", features: { hidden: true, names: true, chat_video: true, post_frame: true } });
        expect([w.stats.n, w.waits.n]).toEqual([6, 1]);
        // after that the key is cached and an applied migration is not asked about again: only the name is read
        expect(await w.caps()).toEqual(first);
        expect([w.stats.n, w.waits.n]).toEqual([7, 2]);
        // a key the isolate has not cached: the check and the name, still one wait
        const { keyCache: _, ...uncached } = w.d;
        expect(await w.caps(uncached)).toEqual(first);
        expect([w.stats.n, w.waits.n]).toEqual([9, 3]);
        // no key: nothing to ask at all
        expect((await capabilities(w.d, "missing", undefined, false, false, false, false, false, false, false, true, false, false, true)).body).toMatchObject({ key: "missing", key_name: null });
        expect([w.stats.n, w.waits.n]).toEqual([9, 3]);
    });

    it("a migration that is not applied is asked about again on every request, and noticed once it is", async () => {
        const w = await keyed((db) => db.raw.exec("DROP TABLE post_details"));
        expect((await w.caps()).body).toMatchObject({ features: { chat_video: true, post_frame: false } });
        const before = w.stats.n;
        expect((await w.caps()).body).toMatchObject({ features: { post_frame: false } });
        // the name, and post_details again
        expect(w.stats.n - before).toBe(2);
        w.fake.raw.exec("CREATE TABLE post_details (link TEXT PRIMARY KEY)");
        expect((await w.caps()).body).toMatchObject({ features: { post_frame: true } });
        const after = w.stats.n;
        expect((await w.caps()).body).toMatchObject({ features: { post_frame: true } });
        expect(w.stats.n - after).toBe(1);
    });

    it("an unknown key, and D1 down, answer as before", async () => {
        const w = await keyed();
        expect((await capabilities(w.d, "key", "0b5f2c3e-6c1a-4f5e-9a57-000000000000")).body).toMatchObject({ key: "invalid", key_name: null });
        w.fake.breakIt();
        const { keyCache: _, ...uncached } = w.d;
        expect((await capabilities(uncached, "key", KEY)).body).toMatchObject({ status: "success", key: "unknown", key_name: null });
    });
});

describe("DELETE /library/items/<id>/post", () => {
    const gone = [O1, W1, W1P];

    it("deletes from one batch exactly what it deletes statement by statement", async () => {
        const a = world("batch");
        const b = world("plain");
        const x = await libraryPostDelete(a.d, W1);
        expect(x).toEqual({ status: 200, body: { status: "success", post: S1, deleted: { files: 3, bytes: 1340 }, remaining: [] } });
        expect(await libraryPostDelete(b.d, W1)).toEqual(x);
        expect(state(a)).toEqual(state(b));
        expect(a.purged).toEqual(b.purged);

        const s = state(a);
        expect(s.items.filter((r: any) => r.deleted_at === T).map((r: any) => r.id).sort()).toEqual([...gone].sort());
        expect(s.sessions.filter((r: any) => r.expires_at === T).map((r: any) => r.id).sort()).toEqual([S1, S1B].sort());
        expect(s.titles).toEqual([{ post_key: U2, title: "my pic" }]);
        expect(s.about).toEqual([]);
        // the objects of the files, the public mirror, the poster, the probe objects and the second session's original
        expect(s.media).toEqual([]);
        expect(s.originals.some((k) => k === LEFTOVER || k === `originals/${S1}.mp4` || gone.some((id) => k === aboutObjectKeys(id)[0]))).toBe(false);
        expect(a.purged).toEqual([[`${MEDIA}PubKey0001.mp4`, `${MEDIA}Abcdefghij.webp`]]);

        // again: a quiet 200 with zeros, from either path
        const again = await libraryPostDelete(a.d, W1);
        expect(again).toEqual({ status: 200, body: { status: "success", post: S1, deleted: { files: 0, bytes: 0 }, remaining: [] } });
        expect(await libraryPostDelete(b.d, W1)).toEqual(again);
    });

    it("waits for D1 once, and not at all for what the answer does not report", async () => {
        const w = world("batch");
        await libraryList(w.d, q("v=3")); // (nothing of the delete depends on it; the isolate is simply not new)
        // the probe objects are the first thing left for later: hold them, so "later" can be looked at
        let release: () => void = () => {};
        const held = new Promise<void>((resolve) => (release = resolve));
        const probe = new Set(gone.flatMap((id) => aboutObjectKeys(id)));
        const realDelete = w.originals.delete.bind(w.originals);
        w.originals.delete = async (key: string) => {
            if (probe.has(key)) await held;
            return realDelete(key);
        };
        const kept: Promise<unknown>[] = [];
        const { n, out } = await trips(w, () => libraryPostDelete({ ...w.d, waitUntil: (p) => void kept.push(p) }, O1));
        expect(out).toEqual({ status: 200, body: { status: "success", post: S1, deleted: { files: 3, bytes: 1340 }, remaining: [] } });
        // one batch: the post, the expiry, the row marks, the title and the about row
        expect(n).toBe(1);
        expect(kept).toHaveLength(1);
        // answered: the rows, the title and the about row are done, the files' own objects are gone ...
        let s = state(w);
        expect(s.items.filter((r: any) => r.deleted_at === T)).toHaveLength(3);
        expect(s.titles).toEqual([{ post_key: U2, title: "my pic" }]);
        expect(s.about).toEqual([]);
        expect(s.media).toEqual(["Poster0001.jpg"]);
        // ... and the leftovers are still there
        expect(s.originals).toContain(LEFTOVER);
        expect(s.originals).toContain(aboutObjectKeys(O1)[0]);
        expect(w.purged).toEqual([]);

        release();
        await kept[0];
        s = state(w);
        expect(s.media).toEqual([]);
        expect(s.originals).not.toContain(LEFTOVER);
        expect(s.originals).not.toContain(aboutObjectKeys(O1)[0]);
        expect(w.purged).toHaveLength(1);
        // the library's first read (migration check + two batches), this delete's one batch, and the poster's
        // "is it still used" check once the leftovers run
        expect(w.stats.n).toBe(3 + 1 + 1);
    });

    it("a post that is busy is refused from the first batch: nothing expired, nothing deleted", async () => {
        const busy = (db: FakeD1) =>
            db.raw.prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES ('Render0000000001', ?, 'pending', ?)").run(S1B, T - 1000);
        for (const kind of ["batch", "plain"] as const) {
            const w = world(kind, busy);
            const before = state(w);
            const { n, out } = await trips(w, () => libraryPostDelete(w.d, O1));
            expect(out).toEqual({ status: 409, body: { status: "error", error: { code: "error.library.busy" } } });
            expect(state(w)).toEqual(before);
            if (kind === "batch") expect(n).toBe(1);
        }
        // a session still saving is busy too
        const w = world("batch", (db) => db.raw.prepare("UPDATE studio_sessions SET status = 'saving', created_at = ? WHERE id = ?").run(T - 1000, S1B));
        expect((await libraryPostDelete(w.d, O1)).status).toBe(409);
        expect((await libraryPostDelete(w.d, iid("Nope"))).status).toBe(404);
    });

    it("an object that will not go keeps its row, and the title: reported the same from either path", async () => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const run = async (kind: "batch" | "plain") => {
            const w = world(kind);
            const real = w.media.delete.bind(w.media);
            w.media.delete = async (key: string | string[]) => {
                for (const k of Array.isArray(key) ? key : [key]) {
                    if (k === "Abcdefghij.webp") throw new Error("R2 down");
                    await real(k);
                }
            };
            return { w, out: await libraryPostDelete(w.d, O1) };
        };
        const a = await run("batch");
        const b = await run("plain");
        expect(a.out).toEqual({
            status: 502,
            body: { status: "error", error: { code: "error.library.partial" }, post: S1, deleted: { files: 2, bytes: 1040 }, remaining: [W1] },
        });
        expect(b.out).toEqual(a.out);
        expect(state(a.w)).toEqual(state(b.w));
        expect(state(a.w).titles).toContainEqual({ post_key: S1, title: "the clip" });
        expect(state(a.w).about).toEqual([{ post_key: S1 }]);
    });

    it("a database without the about table fails the write batch as a whole: the rows are then written one by one", async () => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const drop = (db: FakeD1) => db.raw.exec("DROP TABLE media_about");
        const a = world("batch", drop);
        const b = world("plain", drop);
        const noAbout = (w: World) => ({ ...state(w), about: undefined });
        const x = await libraryPostDelete(a.d, O1);
        expect(x).toEqual({ status: 200, body: { status: "success", post: S1, deleted: { files: 3, bytes: 1340 }, remaining: [] } });
        expect(await libraryPostDelete(b.d, O1)).toEqual(x);
        const read = (w: World) => ({
            items: w.fake.raw.prepare("SELECT id, deleted_at FROM media_items ORDER BY id").all(),
            titles: w.fake.raw.prepare("SELECT post_key FROM media_titles ORDER BY post_key").all(),
        });
        expect(read(a)).toEqual(read(b));
        expect(read(a).titles).toEqual([{ post_key: U2 }]);
        expect(read(a).items.filter((r: any) => r.deleted_at === T)).toHaveLength(3);
        void noAbout;
    });
});

describe("DELETE /library/items/<id>", () => {
    it("deletes one item the same from either path; the lookups are one round trip", async () => {
        const a = world("batch");
        const b = world("plain");
        await libraryList(a.d, q("v=3"));
        const { n, out } = await trips(a, () => libraryItemDelete(a.d, G3A));
        expect(out).toEqual({ status: 200, body: { status: "success", deleted: { files: 1, bytes: 100 } } });
        // the file with the count of its post's other items; the row; the session's lead read and moved
        expect(n).toBe(4);
        expect(await libraryItemDelete(b.d, G3A)).toEqual(out);
        expect(state(a)).toEqual(state(b));
        expect(a.fake.raw.prepare("SELECT r2_key FROM studio_sessions WHERE id = ?").get(S3)).toEqual({ r2_key: `originals/${S3}-01.jpg` });

        // the last item of a post is not deletable here, a file with no role neither, an unknown id is a 404
        for (const w of [a, b]) {
            expect(await libraryItemDelete(w.d, G3B)).toEqual({ status: 409, body: { status: "error", error: { code: "error.library.last_item" } } });
            expect(await libraryItemDelete(w.d, U2)).toEqual({ status: 409, body: { status: "error", error: { code: "error.library.not_deletable" } } });
            expect(await libraryItemDelete(w.d, iid("Nope"))).toEqual({ status: 404, body: { status: "error", error: { code: "error.library.not_found" } } });
        }
        // a made file goes whatever the items are
        const made = await libraryItemDelete(a.d, G3S);
        expect(made).toEqual({ status: 200, body: { status: "success", deleted: { files: 1, bytes: 100 } } });
        expect(await libraryItemDelete(b.d, G3S)).toEqual(made);
    });

    it("the poster, the edge copy and the probe objects do not hold the answer", async () => {
        const w = world("batch");
        w.fake.raw.prepare("UPDATE media_items SET poster = ?, url = ? WHERE id = ?").run(`${MEDIA}Poster0002.jpg`, `${MEDIA}Slide00001.mp4`, G3S);
        w.media.objects.set("Poster0002.jpg", { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
        let release: () => void = () => {};
        const held = new Promise<void>((resolve) => (release = resolve));
        const realDelete = w.media.delete.bind(w.media);
        w.media.delete = async (key: string) => {
            if (key === "Poster0002.jpg") await held;
            return realDelete(key);
        };
        const kept: Promise<unknown>[] = [];
        const out = await libraryItemDelete({ ...w.d, waitUntil: (p) => void kept.push(p) }, G3S);
        expect(out.status).toBe(200);
        expect(kept).toHaveLength(1);
        expect(w.media.objects.has("Poster0002.jpg")).toBe(true);
        expect(w.purged).toEqual([]);
        release();
        await kept[0];
        expect(w.media.objects.has("Poster0002.jpg")).toBe(false);
        expect(w.purged).toEqual([[`${MEDIA}Slide00001.mp4`]]);
        expect(w.originals.objects.has(aboutObjectKeys(G3S)[0]!)).toBe(false);
    });
});

describe("GET /hidden/rules", () => {
    it("the rules and the two counts are one round trip, and the same answer as one by one", async () => {
        const rules = (db: FakeD1) => {
            db.raw.prepare("INSERT INTO hidden_rules (id, kind, value, enabled, hits, created_at, updated_at) VALUES ('Rule000000000001', 'upload', '', 1, 2, ?, ?)").run(T - 50, T - 50);
            db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'held', 'rule', NULL, ?)").run(U5, T - 10);
        };
        const a = world("batch", rules);
        const b = world("plain", rules);
        await listRules(a.d);
        const { n, out } = await trips(a, () => listRules(a.d));
        expect(n).toBe(1);
        expect(out.status).toBe(200);
        expect(out.body).toMatchObject({ status: "success", hidden: 1, held: 1 });
        expect((out.body as any).rules).toHaveLength(1);
        expect(await listRules(b.d)).toEqual(out);
        await listRules(b.d);
        expect((await trips(b, () => listRules(b.d))).n).toBe(3);
    });
});
