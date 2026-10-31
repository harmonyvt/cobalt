// "What it's about" (APP-API-CONTRACT.md section 34) on the Worker side, on the real migrations (node:sqlite): search
// inside a collection, a link or a list of posts; the `why` words; collections() with post_ids; what a post is embedded
// from; the writer (a fake Haiku and a fake Whisper); the word list ("reads closest to"); GET and PATCH /library/about
// and their chat calls; the capability flags. The Space is a fake whose vectors are bags of words, so a word in a
// post's text is close to the same word as a query.
import { afterEach, describe, expect, it, vi } from "vitest";
import { indexTerms, libraryAbout, nearestWords, refreshTermMeans, termVectors, whyFor, type TermVector } from "../src/about";
import { STARTER_TERMS } from "../src/about-terms";
import { syncAboutRows } from "../src/about-store";
import { ABOUT_STYLE, dueAbouts, readAboutText, whisperFrom, writeAbouts, type DescribeInput, type Describer, type Transcriber } from "../src/about-writer";
import { capabilities, type AppDeps } from "../src/app-routes";
import { chatTools } from "../src/chat-tools";
import {
    EMBED_DIMS,
    EMBED_MODEL,
    EmbedError,
    decodeVector,
    dot,
    encodeVector,
    inputHash,
    librarySearch,
    librarySearchPost,
    normalize,
    postInputs,
    runIndexer,
    type EmbedClient,
    type EmbedInput,
} from "../src/embed";
import { hashKey } from "../src/keys";
import { chatToolbox, opBase, REGISTRY } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals, fakeJpeg } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SPACE = "https://capybaraharmony-cobalt-embed.hf.space";
const API = "https://api.capybaraharmony.com";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const T0 = 1_800_000_000_000;
const DAY = 24 * 60 * 60 * 1000;

// ---- a fake Space: bags of words ---------------------------------------------------------------------------------------

function wordVector(words: string): number[] {
    const v = new Array(EMBED_DIMS).fill(0);
    for (const w of words.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)) {
        let h = 0;
        for (const c of w) h = (h * 31 + c.charCodeAt(0)) >>> 0;
        v[h % EMBED_DIMS] += 1;
    }
    v[EMBED_DIMS - 1] += 0.01;
    return normalize(v);
}

class FakeSpace implements EmbedClient {
    calls: { kind: string; inputs: EmbedInput[] }[] = [];
    fail: ((inputs: EmbedInput[]) => EmbedError | null) | null = null;
    async embed(kind: "document" | "query", inputs: EmbedInput[]) {
        this.calls.push({ kind, inputs });
        const e = this.fail?.(inputs);
        if (e) throw e;
        return { model: EMBED_MODEL, vectors: inputs.map((i) => wordVector(`${kind === "document" ? (i.title ?? "") : ""} ${i.text}`)), images: inputs.map(() => false) };
    }
}

// ---- the library ------------------------------------------------------------------------------------------------------

let n = 0;
type FileOver = Partial<{
    id: string;
    name: string;
    link: string | null;
    poster: string | null;
    url: string | null;
    session_id: string | null;
    source: string;
    bucket: string;
    content_type: string;
    role: string | null;
    item_index: number | null;
    public_id: string | null;
    visibility: string | null;
    bytes: number | null;
    created_at: number;
    deleted_at: number | null;
}>;
function addFile(db: FakeD1, over: FileOver = {}) {
    n++;
    const id = over.id ?? `item${String(n).padStart(12, "0")}`;
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, link, poster, session_id, role, item_index, public_id, visibility, bytes, created_at, deleted_at)
             VALUES (?, 'private', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
            id,
            over.source ?? "saved",
            over.bucket ?? "originals",
            `originals/${id}.mp4`,
            over.url ?? null,
            over.name ?? "clip.mp4",
            over.content_type ?? "video/mp4",
            over.link ?? null,
            over.poster ?? null,
            over.session_id ?? null,
            over.role ?? null,
            over.item_index ?? null,
            over.public_id ?? null,
            over.visibility ?? null,
            over.bytes ?? 4096,
            over.created_at ?? T0 + n,
            over.deleted_at ?? null,
        );
    return id;
}

const addSet = (db: FakeD1, id: string, items: string[], o: { title?: string; revoked?: boolean } = {}) =>
    db.raw
        .prepare("INSERT INTO share_sets (id, items, title, created_at, revoked_at) VALUES (?, ?, ?, ?, ?)")
        .run(id, JSON.stringify(items), o.title ?? null, T0, o.revoked ? T0 + 1 : null);
const addCollection = (db: FakeD1, id: string, name: string, sets: string[], updated = T0) => {
    db.raw.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)").run(id, name, T0, updated);
    for (const s of sets) db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?, ?, ?)").run(id, s, T0);
};
const setAbout = (db: FakeD1, post_key: string, item_id: string, f: Record<string, unknown> = {}) => {
    const row = { post_key, item_id, probe_state: "done", updated_at: T0, ...f };
    const cols = Object.keys(row);
    db.raw
        .prepare(`INSERT OR REPLACE INTO media_about (${cols.join(", ")}) VALUES (${cols.map((c) => `@${c}`).join(", ")})`)
        .run(row as any);
};
const aboutOf = (db: FakeD1, post_key: string) => db.raw.prepare("SELECT * FROM media_about WHERE post_key = ?").get(post_key) as any;

function world() {
    const db: FakeD1 = createBatchD1();
    let now = T0 + 1_000_000;
    const space = new FakeSpace();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const d: AppDeps = {
        db: db as unknown as D1Database,
        originals,
        media,
        mediaBaseUrl: MEDIA,
        apiUrl: "https://api.capybaraharmony.com/",
        webUrl: "https://cobalt.capybaraharmony.com",
        now: () => now,
        fixedLength: () => {
            throw new Error("unused");
        },
        adopt: async () => {
            throw new Error("unused");
        },
    };
    const index = async () => {
        for (let i = 0; i < 20; i++) if ((await runIndexer({ db: d.db, client: space, mediaBaseUrl: MEDIA, now: () => now, batch: 50 })).pending === 0) return;
    };
    const search = (q: string, extra = "") => librarySearch({ ...d, embed: space }, new URLSearchParams(`q=${encodeURIComponent(q)}${extra}`));
    const tick = (ms: number) => (now += ms);
    return { db, d, space, originals, media, index, search, tick, now: () => now };
}

// Four posts: two fursuit videos and a cat in "Lia Share 11" (two live links and a revoked one), one fursuit outside it.
function furryLibrary() {
    const w = world();
    const f1 = addFile(w.db, { session_id: "postF1", name: "fursuit dance.mp4" });
    const f2 = addFile(w.db, { session_id: "postF2", name: "instagram_De84mWBOe72.mp4" });
    const cat = addFile(w.db, { session_id: "postCat", name: "cat on a couch.mp4" });
    const out = addFile(w.db, { session_id: "postOut", name: "fursuit parade.mp4" });
    // the reel whose name says nothing: its words come from the description (34.3)
    setAbout(w.db, "postF2", f2, { sentence: "A person in a fox fursuit dances in a kitchen.", tags: JSON.stringify(["fursuit", "dance", "fox"]), sound_tags: JSON.stringify(["music"]), written_at: T0 });
    addSet(w.db, "1111111111111111111", [f1, cat], { title: "lia picks" });
    addSet(w.db, "2222222222222222222", [f2]);
    addSet(w.db, "3333333333333333333", [out], { revoked: true });
    addCollection(w.db, "CollLia000000011", "Lia Share 11", ["1111111111111111111", "2222222222222222222", "3333333333333333333"]);
    addCollection(w.db, "CollOther0000001", "other", []);
    return { w, f1, f2, cat, out };
}

const realFetch = globalThis.fetch;
afterEach(() => {
    globalThis.fetch = realFetch;
});

// ---- 34.6: within ------------------------------------------------------------------------------------------------------

describe("search within a collection, a link or posts (34.6)", () => {
    it("a collection by id or by name scores every post in it, the unindexed ones by their text, and says what it searched", async () => {
        const { w } = furryLibrary();
        await w.index();
        // the cat lost its vector: it is still in the answer, with indexed: false
        w.db.raw.prepare("DELETE FROM media_embeddings WHERE post_key = 'postCat'").run();
        for (const within of ["collection=CollLia000000011", "collection=%20lia%20share%2011%20", "collection=LIA%20SHARE%2011"]) {
            const r = await w.search("fursuit", `&${within}`);
            expect(r.status).toBe(200);
            const b = r.body as any;
            expect(b.within).toEqual({ kind: "collection", id: "CollLia000000011", name: "Lia Share 11", posts: 3 });
            const ids = b.posts.map((p: any) => p.id);
            expect([...ids].sort()).toEqual(["postCat", "postF1", "postF2"]);
            expect(ids.slice(0, 2).sort()).toEqual(["postF1", "postF2"]); // the fursuits first
            expect(ids).not.toContain("postOut"); // in a revoked link only
            const cat = b.posts.find((p: any) => p.id === "postCat");
            expect(cat.indexed).toBe(false);
            expect(cat.score).toBe(0);
            expect(b.posts.find((p: any) => p.id === "postF2").indexed).toBe(true);
        }
        // without within: the library-wide top N, no indexed field, no within
        const all = (await w.search("fursuit")).body as any;
        expect(all.within).toBeUndefined();
        expect(all.posts.map((p: any) => p.id)).toContain("postOut");
        expect(all.posts.every((p: any) => p.indexed === undefined)).toBe(true);
    });

    it("a link, a list of posts, and the refusals: unknown collection or link 404, two at once or a bad list 400", async () => {
        const { w } = furryLibrary();
        await w.index();
        const link = (await w.search("fursuit", "&link=1111111111111111111")).body as any;
        expect(link.within).toEqual({ kind: "link", id: "1111111111111111111", name: "lia picks", posts: 2 });
        expect(link.posts.map((p: any) => p.id)).toEqual(["postF1", "postCat"]);
        const posts = (await w.search("fursuit", "&posts=postOut,postCat,nope")).body as any;
        expect(posts.within).toEqual({ kind: "posts", id: null, name: null, posts: 2 });
        expect(posts.posts.map((p: any) => p.id)).toEqual(["postOut", "postCat"]);

        const code = async (extra: string) => {
            const r = await w.search("fursuit", extra);
            return [r.status, (r.body as any).error?.code];
        };
        expect(await code("&collection=nope")).toEqual([404, "error.collection.not_found"]);
        expect(await code("&link=9999999999999999999")).toEqual([404, "error.share.not_found"]);
        expect(await code("&link=3333333333333333333")).toEqual([404, "error.share.not_found"]); // revoked
        expect(await code("&collection=other&link=1111111111111111111")).toEqual([400, "error.library.bad_request"]);
        expect(await code("&posts=")).toEqual([400, "error.library.bad_request"]);
        expect(await code(`&posts=${Array.from({ length: 501 }, (_, i) => `p${i}`).join(",")}`)).toEqual([400, "error.library.bad_request"]);
        // with within the limit goes to 500; without it stays at 50
        expect((await w.search("fursuit", "&collection=other&limit=500")).status).toBe(200);
        expect(await code("&collection=other&limit=501")).toEqual([400, "error.library.bad_request"]);
        expect(await code("&limit=51")).toEqual([400, "error.library.bad_request"]);
        // an empty collection answers no posts, not an error
        expect(((await w.search("fursuit", "&collection=other")).body as any).within).toEqual({ kind: "collection", id: "CollOther0000001", name: "other", posts: 0 });
    });

    it("a share link's public copy id finds the post too", async () => {
        const w = world();
        const priv = addFile(w.db, { session_id: "postPub", name: "fursuit.mp4", public_id: "PubCopy000000001", visibility: "public" });
        addSet(w.db, "4444444444444444444", ["PubCopy000000001"]);
        await w.index();
        const b = (await w.search("fursuit", "&link=4444444444444444444")).body as any;
        expect(b.posts.map((p: any) => p.id)).toEqual(["postPub"]);
        expect(priv).toBeTruthy();
    });

    it("every hit carries why: the post's tags and sound tags closest to the query (by the tags' own vectors), [] without words", async () => {
        const { w } = furryLibrary();
        setAbout(w.db, "postCat", "x", { tags: JSON.stringify(["cat", "couch", "sleeping"]), user_tags: JSON.stringify(["my cat", "nap"]), written_at: T0 });
        await w.index();
        // before the tags have vectors: a tag the query names comes first
        let b = (await w.search("fox dance", "&collection=CollLia000000011")).body as any;
        const why = (id: string) => b.posts.find((p: any) => p.id === id).why;
        expect(why("postF2")).toEqual(["dance", "fox", "fursuit"]);
        expect(why("postF1")).toEqual([]);
        expect(why("postCat")).toEqual(["my cat", "nap"]); // the owner's tags replace Haiku's
        // with the word list embedded, the vectors decide
        await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 });
        b = (await w.search("music", "&collection=CollLia000000011")).body as any;
        expect(why("postF2")[0]).toBe("music");
        expect(why("postF2")).toHaveLength(3);
        const direct = await whyFor(w.d.db, wordVector("fox"), "fox", ["postF2", "nope"]);
        expect(direct.get("postF2")![0]).toBe("fox");
        expect(direct.get("nope")).toEqual([]);
    });

    it("the chat: search(q, { within }) with an id, a name, a string, a link or posts; the old search(q, limit); collections() with post_ids", async () => {
        const { w, f1 } = furryLibrary();
        await w.index();
        const tools = chatTools({ db: w.d.db, mediaBaseUrl: MEDIA, embed: w.space }, { look: [], show: [] });
        const ids = (hits: any[]) => hits.map((h) => h.id).sort();
        expect(ids(await tools.search!("fursuit", { within: { collection: "Lia Share 11" } }) as any[])).toEqual(["postCat", "postF1", "postF2"]);
        expect(ids(await tools.search!("fursuit", { within: "lia share 11" }) as any[])).toEqual(["postCat", "postF1", "postF2"]);
        expect(ids(await tools.search!("fursuit", { within: { collection: "CollLia000000011" }, limit: 2 }) as any[])).toHaveLength(2);
        expect(ids(await tools.search!("fursuit", { within: { link: "2222222222222222222" } }) as any[])).toEqual(["postF2"]);
        expect(ids(await tools.search!("fursuit", { within: { posts: ["postOut"] } }) as any[])).toEqual(["postOut"]);
        const old = (await tools.search!("fursuit", 1)) as any[];
        expect(old).toHaveLength(1);
        expect(old[0]).toMatchObject({ score: expect.any(Number), why: expect.any(Array) });
        expect(old[0].indexed).toBeUndefined();
        await expect(tools.search!("fursuit", { within: { collection: "nope" } })).rejects.toThrow(/no collection "nope"/);
        await expect(tools.search!("fursuit", { within: { link: "9" } })).rejects.toThrow(/no live gallery link/);
        await expect(tools.search!("fursuit", { within: { collection: "a", link: "b" } })).rejects.toThrow(/within must be/);
        const cols = (await tools.collections!()) as any[];
        const lia = cols.find((c) => c.name === "Lia Share 11");
        expect(lia.link_ids.sort()).toEqual(["1111111111111111111", "2222222222222222222"]);
        expect(lia.post_ids.sort()).toEqual(["postCat", "postF1", "postF2"]);
        expect(cols.find((c) => c.name === "other").post_ids).toEqual([]);
        expect(f1).toBeTruthy();
    });

    it("the registry's library.search op takes within, and still takes the old positional limit", async () => {
        const { w } = furryLibrary();
        await w.index();
        const op = REGISTRY.byCall("library.search")!;
        expect(op.input.safeParse({ query: "x", within: { collection: "a" } }).success).toBe(true);
        expect(op.input.safeParse({ query: "x", within: "a" }).success).toBe(true);
        expect(op.input.safeParse({ query: "x", within: { posts: [] } }).success).toBe(false);
        expect(op.input.safeParse({ query: "x", within: { nope: 1 } }).success).toBe(false);
        const { argsToInput } = await import("../src/registry/typescript");
        expect(argsToInput(op, ["cats", 5])).toEqual({ query: "cats", limit: 5 });
        expect(argsToInput(op, ["cats", { within: { link: "1" } }])).toEqual({ query: "cats", within: { link: "1" } });
        expect(argsToInput(op, ["cats"])).toEqual({ query: "cats" });
    });
});

// ---- 34.4: what a post is embedded from ------------------------------------------------------------------------------

describe("what a post is embedded from (34.4)", () => {
    it("names, link words, the sentence, the tags (the owner's when set), the sound tags, the caption and the transcript's start", async () => {
        const w = world();
        const id = addFile(w.db, { session_id: "postA", name: "instagram_De84mWBOe72.mp4", link: "https://www.instagram.com/reel/De84mWBOe72/" });
        const [before] = await postInputs(w.d.db, MEDIA);
        expect(before!.text).toBe("instagram_De84mWBOe72.mp4 · instagram.com/reel/De84mWBOe72/");
        const oldHash = await inputHash(before!);

        setAbout(w.db, "postA", id, {
            sentence: "A fox fursuiter waves.",
            tags: JSON.stringify(["fursuit", "fox"]),
            sound_tags: JSON.stringify(["music", "laughter"]),
            transcript: `hello ${"x".repeat(2000)}`,
            written_at: T0,
        });
        w.db.raw.prepare("INSERT INTO media_captions (subject, title, created_at) VALUES (?, ?, ?)").run(`item:${id}`, "a floofy fox (=^･ω･^=)", T0);
        const [after] = await postInputs(w.d.db, MEDIA);
        const parts = after!.text.split(" · ");
        expect(parts.slice(0, 6)).toEqual([
            "instagram_De84mWBOe72.mp4",
            "instagram.com/reel/De84mWBOe72/",
            "A fox fursuiter waves.",
            "fursuit, fox",
            "music, laughter",
            "a floofy fox (=^･ω･^=)",
        ]);
        expect(parts[6]).toBe(`hello ${"x".repeat(2000)}`.slice(0, 1200));
        expect(after!.title).toBe(before!.title);
        expect(await inputHash(after!)).not.toBe(oldHash);
        // the owner's tags replace Haiku's
        w.db.raw.prepare("UPDATE media_about SET user_tags = ? WHERE post_key = 'postA'").run(JSON.stringify(["lia", "floof"]));
        const [edited] = await postInputs(w.d.db, MEDIA, "postA");
        expect(edited!.text.split(" · ")[3]).toBe("lia, floof");
        // GET /library/search/post shows the new text
        const status = await librarySearchPost({ db: w.d.db, mediaBaseUrl: MEDIA, searchEnabled: true }, new URLSearchParams({ key: "postA" }));
        expect((status.body as any).input.text).toBe(edited!.text);
        // cut at 3,000
        w.db.raw.prepare("UPDATE media_about SET sentence = ? WHERE post_key = 'postA'").run("y".repeat(5000));
        expect((await postInputs(w.d.db, MEDIA, "postA"))[0]!.text.length).toBe(3000);
    });

    it("without migration 0022's table the text is what it was", async () => {
        const w = world();
        addFile(w.db, { session_id: "postA", name: "a.mp4" });
        w.db.raw.exec("DROP TABLE media_about");
        expect((await postInputs(w.d.db, MEDIA))[0]!.text).toBe("a.mp4");
    });
});

// ---- 34.3: the writer ----------------------------------------------------------------------------------------------------

class FakeHaiku implements Describer {
    model = `claude-haiku-5-5+${ABOUT_STYLE}`;
    seen: DescribeInput[] = [];
    fail = false;
    async describe(input: DescribeInput) {
        this.seen.push(input);
        if (this.fail) throw new Error("overloaded");
        return { sentence: `A clip with ${input.images.length} pictures.`, tags: ["fursuit", "dance", "kitchen", "fox", "music video"], sound_tags: input.hasAudio ? ["music"] : [] };
    }
}
class FakeWhisper implements Transcriber {
    model = "fake-whisper";
    seen: Uint8Array[] = [];
    fail = false;
    text: string | null = "hey look at him go";
    async transcribe(mp3: Uint8Array) {
        this.seen.push(mp3);
        if (this.fail) throw new Error("whisper down");
        return { text: this.text, language: this.text ? "en" : null };
    }
}

describe("the writer (34.3)", () => {
    const probed = (w: ReturnType<typeof world>, post: string, o: { frames?: number; audio?: boolean; name?: string; at?: number } = {}) => {
        const id = addFile(w.db, { session_id: post, name: o.name ?? `${post}.mp4`, link: "https://www.tiktok.com/@a/video/1" });
        const frames = o.frames ?? 3;
        for (let i = 1; i <= frames; i++) w.originals.objects.set(`about/${id}/frame-${i}.jpg`, { bytes: fakeJpeg(50, i), contentType: "image/jpeg", meta: {} });
        if (o.audio) w.originals.objects.set(`about/${id}/audio.mp3`, { bytes: Uint8Array.from([0x49, 0x44, 0x33, 1, 2, 3]), contentType: "audio/mpeg", meta: {} });
        setAbout(w.db, post, id, { frames, has_audio: o.audio ? 1 : 0, probe_at: o.at ?? T0 });
        return id;
    };
    const run = (w: ReturnType<typeof world>, haiku: Describer, whisper: Transcriber | null, budgetMs = 120_000) =>
        writeAbouts({ db: w.d.db, originals: w.originals, media: w.media, mediaBaseUrl: MEDIA, describer: haiku, transcriber: whisper, now: w.now, budgetMs });

    it("transcribes the sound, describes the frames with the title, the site and the transcript, and stores it once", async () => {
        const w = world();
        probed(w, "postA", { audio: true, name: "instagram_x.mp4" });
        const haiku = new FakeHaiku();
        const whisper = new FakeWhisper();
        expect(await run(w, haiku, whisper)).toEqual({ due: 1, written: 1, failed: 0, transcribed: 1 });
        const input = haiku.seen[0]!;
        expect(input.kind).toBe("video");
        expect(input.images).toHaveLength(3);
        expect(input.images.every((i) => "base64" in i && i.mediaType === "image/jpeg")).toBe(true);
        expect(input).toMatchObject({ title: "instagram_x.mp4", site: "tiktok.com", transcript: "hey look at him go", hasAudio: true });
        expect(whisper.seen[0]![0]).toBe(0x49);
        const row = aboutOf(w.db, "postA");
        expect(row).toMatchObject({
            sentence: "A clip with 3 pictures.",
            transcript: "hey look at him go",
            language: "en",
            model: haiku.model,
            written_at: w.now(),
            failed_at: null,
            attempts: 0,
            user_tags: null,
        });
        expect(JSON.parse(row.tags)).toEqual(["fursuit", "dance", "kitchen", "fox", "music video"]);
        expect(JSON.parse(row.sound_tags)).toEqual(["music"]);
        // nothing changed: nothing is due
        expect(await run(w, haiku, whisper)).toEqual({ due: 0, written: 0, failed: 0, transcribed: 0 });
        // a new title is a new input
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('postA', 'lia dancing', 1)").run();
        expect((await run(w, haiku, whisper)).written).toBe(1);
        expect(haiku.seen[1]!.title).toBe("lia dancing");
    });

    it("leaves the owner's tags alone, and the owner's tags win everywhere", async () => {
        const w = world();
        probed(w, "postA");
        w.db.raw.prepare("UPDATE media_about SET user_tags = ? WHERE post_key = 'postA'").run(JSON.stringify(["mine"]));
        await run(w, new FakeHaiku(), null);
        const row = aboutOf(w.db, "postA");
        expect(JSON.parse(row.user_tags)).toEqual(["mine"]);
        expect(JSON.parse(row.tags)).toContain("fursuit");
        expect((await postInputs(w.d.db, MEDIA, "postA"))[0]!.text).toContain("mine");
        expect((await postInputs(w.d.db, MEDIA, "postA"))[0]!.text).not.toContain("fursuit");
    });

    it("a failure is tried again a day later, at most 3 times, and at once when the input changes", async () => {
        const w = world();
        probed(w, "postA");
        const haiku = new FakeHaiku();
        haiku.fail = true;
        expect(await run(w, haiku, null)).toMatchObject({ due: 1, written: 0, failed: 1 });
        expect(aboutOf(w.db, "postA")).toMatchObject({ attempts: 1, failed_at: w.now(), sentence: null });
        expect((await run(w, haiku, null)).due).toBe(0);
        w.tick(DAY);
        expect((await run(w, haiku, null)).failed).toBe(1);
        w.tick(DAY);
        expect((await run(w, haiku, null)).failed).toBe(1);
        expect(aboutOf(w.db, "postA").attempts).toBe(3);
        w.tick(DAY * 2);
        expect((await run(w, haiku, null)).due).toBe(0); // given up until the input changes
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('postA', 'renamed', 1)").run();
        haiku.fail = false;
        expect(await run(w, haiku, null)).toMatchObject({ due: 1, written: 1 });
        expect(aboutOf(w.db, "postA")).toMatchObject({ attempts: 0, failed_at: null });
    });

    it("Whisper failing or off: the words are written without the sound; no speech is a null transcript", async () => {
        const w = world();
        probed(w, "postA", { audio: true });
        probed(w, "postB", { audio: true });
        probed(w, "postC", { audio: true });
        const whisper = new FakeWhisper();
        whisper.fail = true;
        const haiku = new FakeHaiku();
        const r = await writeAbouts({ db: w.d.db, originals: w.originals, mediaBaseUrl: MEDIA, describer: haiku, transcriber: whisper, now: w.now, budgetMs: 60_000, concurrency: 1 });
        expect(r).toMatchObject({ due: 3, written: 3, transcribed: 0 });
        expect(aboutOf(w.db, "postA").transcript).toBeNull();
        expect(haiku.seen.every((s) => s.transcript === null && s.hasAudio)).toBe(true);
        // no speech recognised
        whisper.fail = false;
        whisper.text = null;
        w.db.raw.prepare("UPDATE media_about SET input_hash = 'old'").run();
        await run(w, haiku, whisper);
        expect(aboutOf(w.db, "postB")).toMatchObject({ transcript: null, language: null });
        // Whisper off: the same
        w.db.raw.prepare("UPDATE media_about SET input_hash = 'old'").run();
        await run(w, haiku, null);
        expect(aboutOf(w.db, "postC").transcript).toBeNull();
    });

    it("a still is described from its poster or public URL, else from its bytes under 5 MB; a pending probe is not due", async () => {
        const w = world();
        const a = addFile(w.db, { session_id: "postPoster", content_type: "image/jpeg", name: "a.jpg", poster: `${MEDIA}AAAAAAAAAA.jpg` });
        const b = addFile(w.db, { session_id: "postPriv", content_type: "image/png", name: "b.png", bytes: 1000 });
        w.originals.objects.set(`originals/${b}.mp4`, { bytes: Uint8Array.from([0x89, 0x50, 0x4e, 0x47]), contentType: "image/png", meta: {} });
        addFile(w.db, { session_id: "postBig", content_type: "image/heic", name: "c.heic", bytes: 9_000_000 });
        addFile(w.db, { session_id: "postVid", name: "v.mp4" });
        await syncAboutRows(w.d.db, w.now());
        expect(aboutOf(w.db, "postPoster").probe_state).toBe("none");
        expect(aboutOf(w.db, "postVid").probe_state).toBe("pending");
        const haiku = new FakeHaiku();
        const r = await writeAbouts({ db: w.d.db, originals: w.originals, mediaBaseUrl: MEDIA, describer: haiku, transcriber: null, now: w.now, budgetMs: 60_000, concurrency: 1 });
        expect(r.due).toBe(3); // the stills; the video waits for its probe
        const byTitle = new Map(haiku.seen.map((s) => [s.title, s]));
        expect(byTitle.get("a.jpg")!.images).toEqual([{ url: `${MEDIA}AAAAAAAAAA.jpg` }]);
        expect(byTitle.get("b.png")!.images).toEqual([{ base64: "iVBORw==", mediaType: "image/png" }]);
        expect(byTitle.get("c.heic")!.images).toEqual([]);
        expect([...byTitle.values()].every((s) => s.kind === "image" && !s.hasAudio)).toBe(true);
        expect(a).toBeTruthy();
    });

    it("stops starting new posts when the budget is used", async () => {
        const w = world();
        for (let i = 0; i < 5; i++) probed(w, `post${i}`);
        const haiku = new FakeHaiku();
        const slow: Describer = {
            model: haiku.model,
            describe: async (input) => {
                w.tick(50_000);
                return haiku.describe(input);
            },
        };
        const r = await writeAbouts({ db: w.d.db, originals: w.originals, mediaBaseUrl: MEDIA, describer: slow, transcriber: null, now: w.now, budgetMs: 120_000, concurrency: 1 });
        expect(r).toMatchObject({ due: 5, written: 3 });
        expect((await dueAbouts({ db: w.d.db, mediaBaseUrl: MEDIA, describer: slow, transcriber: null, now: w.now })).length).toBe(2);
    });

    it("reads the model's JSON plainly: one sentence, clean tags, no emoji", () => {
        expect(readAboutText(JSON.stringify({ sentence: "A fox 🦊 dances.\n", tags: [" Fursuit ", "fursuit", "x".repeat(31), 3, "Dance"], sound_tags: ["MUSIC"] }))).toEqual({
            sentence: "A fox dances.",
            tags: ["fursuit", "dance"],
            sound_tags: ["music"],
        });
        expect(Array.from(readAboutText(JSON.stringify({ sentence: "y".repeat(400), tags: [], sound_tags: [] })).sentence)).toHaveLength(160);
        expect(() => readAboutText(JSON.stringify({ tags: [] }))).toThrow();
    });

    it("the Whisper adapter sends base64 audio and reads text and language", async () => {
        const calls: any[] = [];
        const t = whisperFrom({
            run: async (model, inputs) => {
                calls.push({ model, inputs });
                return { text: "  hello\nthere ", transcription_info: { language: "en" } };
            },
        })!;
        expect(await t.transcribe(Uint8Array.from([1, 2, 3]))).toEqual({ text: "hello there", language: "en", lines: [] });
        expect(t.model).toBe("@cf/openai/whisper-large-v3-turbo");
        expect(calls[0]).toEqual({ model: "@cf/openai/whisper-large-v3-turbo", inputs: { audio: "AQID", task: "transcribe", vad_filter: true } });
        expect(whisperFrom(undefined)).toBeNull();
        const empty = whisperFrom({ run: async () => ({ text: "   " }) })!;
        expect(await empty.transcribe(new Uint8Array(1))).toEqual({ text: null, language: null, lines: [] });
        const bad = whisperFrom({ run: async () => ({ nope: 1 }) })!;
        await expect(bad.transcribe(new Uint8Array(1))).rejects.toThrow();
    });
});

// ---- 34.5: the word list ---------------------------------------------------------------------------------------------

describe("the word list and reads closest to (34.5)", () => {
    const tv = (term: string, v: number[], mean: number | null = null): TermVector => ({ term, v: Float32Array.from(v), mean });

    it("nearest words: cosine minus the term's average, best 8, rounded to 2 places", () => {
        const post = [1, 0, 0];
        const terms = [tv("a", [1, 0, 0], 0.9), tv("b", [0.8, 0.6, 0], 0), tv("c", [0, 1, 0], -0.2), tv("d", [0.6, 0.8, 0])];
        expect(nearestWords(post, terms)).toEqual([
            { word: "b", score: 0.8 },
            { word: "d", score: 0.6 },
            { word: "c", score: 0.2 },
            { word: "a", score: 0.1 },
        ]);
        const many = Array.from({ length: 20 }, (_, i) => tv(`t${i}`, [i / 20, 0, 0]));
        expect(nearestWords(post, many)).toHaveLength(8);
        expect(nearestWords(post, many)[0]!.word).toBe("t19");
    });

    it("indexTerms adds the starter words and every tag, embeds them in query mode 32 a call, and the averages are the mean cosines", async () => {
        const { w } = furryLibrary();
        await w.index();
        w.space.calls.length = 0;
        const r = await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 });
        expect(r.unavailable).toBe(false);
        expect(r.embedded).toBe(r.added);
        // every tag of the library here (fursuit, dance, fox, music) is a starter word already
        expect(r.added).toBe(STARTER_TERMS.length);
        expect(w.space.calls.every((c) => c.kind === "query" && c.inputs.length <= 32 && c.inputs.every((i) => i.title === null && i.image_url === null))).toBe(true);
        expect(w.space.calls.length).toBe(Math.ceil(r.added / 32));
        const rows = w.db.raw.prepare("SELECT * FROM embed_terms").all() as any[];
        expect(rows.every((t) => t.vector && t.model === EMBED_MODEL && t.dims === EMBED_DIMS && typeof t.mean === "number")).toBe(true);
        expect(rows.find((t) => t.term === "fursuit").source).toBe("starter");
        // the average cosine, the long way
        const posts = (w.db.raw.prepare("SELECT vector FROM media_embeddings").all() as any[]).map((p) => decodeVector(p.vector)!);
        const t = rows.find((x) => x.term === "cat")!;
        const tvec = decodeVector(t.vector)!;
        const mean = posts.reduce((s, p) => s + dot(p, tvec), 0) / posts.length;
        expect(t.mean).toBeCloseTo(mean, 5);
        // a second run adds nothing, embeds nothing, and only refreshes when asked
        w.space.calls.length = 0;
        expect(await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 })).toEqual({ added: 0, embedded: 0, refreshed: 0, unavailable: false });
        expect((await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000, refreshMeans: true })).refreshed).toBe(rows.length);
        expect(w.space.calls).toHaveLength(0);
        // a new tag is added as a tag term
        setAbout(w.db, "postCat", "x", { tags: JSON.stringify(["floofy loaf"]) });
        expect(await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 })).toMatchObject({ added: 1, embedded: 1 });
        expect((w.db.raw.prepare("SELECT source FROM embed_terms WHERE term = 'floofy loaf'").get() as any).source).toBe("tag");
    });

    it("a sleeping Space stops it; a word the Space refuses is dropped; the budget is kept", async () => {
        const w = world();
        w.space.fail = () => new EmbedError("unavailable", 503);
        expect(await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 })).toMatchObject({ embedded: 0, unavailable: true });
        expect(w.space.calls).toHaveLength(1);
        w.space.fail = (inputs) => (inputs.some((i) => i.text === "cat") ? new EmbedError("rejected", 400) : null);
        const r = await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 });
        expect(r.unavailable).toBe(false);
        expect(w.db.raw.prepare("SELECT 1 FROM embed_terms WHERE term = 'cat'").get()).toBeUndefined();
        expect((w.db.raw.prepare("SELECT COUNT(*) AS n FROM embed_terms WHERE vector IS NULL").get() as any).n).toBe(0);
        // no time: nothing is sent
        w.db.raw.prepare("UPDATE embed_terms SET vector = NULL").run();
        w.space.calls.length = 0;
        w.space.fail = null;
        await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 1_000 });
        expect(w.space.calls).toHaveLength(0);
    });

    it("refreshTermMeans with no posts sets every mean to 0", async () => {
        const w = world();
        w.db.raw.prepare("INSERT INTO embed_terms (term, source, model, dims, vector, created_at) VALUES ('cat', 'starter', ?, ?, ?, 1)").run(EMBED_MODEL, EMBED_DIMS, encodeVector(wordVector("cat")));
        expect(await refreshTermMeans(w.d.db)).toBe(1);
        expect((w.db.raw.prepare("SELECT mean FROM embed_terms").get() as any).mean).toBe(0);
        expect((await termVectors(w.d.db)).map((t) => t.term)).toEqual(["cat"]);
    });
});

// ---- 34.6: GET and PATCH /library/about, and their chat calls --------------------------------------------------------

describe("GET and PATCH /library/about (34.6)", () => {
    async function http() {
        const lib = furryLibrary();
        const { w } = lib;
        await w.index();
        await indexTerms({ db: w.d.db, client: w.space, now: w.now, budgetMs: 600_000 });
        w.db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
        globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
            const url = String(input instanceof Request ? input.url : input);
            if (!url.startsWith(SPACE)) throw new Error(`unexpected fetch ${url}`);
            const body = JSON.parse(init!.body as string);
            return new Response(JSON.stringify(await w.space.embed(body.kind, body.inputs)), { status: 200 });
        }) as typeof fetch;
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: w.d.db,
            ORIGINALS: w.originals,
            MEDIA: w.media,
            MEDIA_BASE_URL: MEDIA,
            EMBED_URL: SPACE,
            EMBED_TOKEN: "hf_tok",
        };
        const container = { fetch: async () => new Response("container must not be called", { status: 500 }) };
        const call = (path: string, init: RequestInit = {}, e: WorkerEnv = env) =>
            handleRequest(new Request(`${API}${path}`, { ...init, headers: { ...AUTH, "content-type": "application/json", ...(init.headers ?? {}) } }), e, container, { now: w.now });
        return { ...lib, env, container, call };
    }

    it("answers the post's words, what it reads closest to, its neighbours with their post shapes, and the index status", async () => {
        const { call } = await http();
        const r = await call("/library/about?key=postF2");
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const b = (await r.json()) as any;
        expect(Object.keys(b).sort()).toEqual(["about", "index", "neighbours", "post_key", "posts", "probe", "status", "words"]);
        expect(b).toMatchObject({ status: "success", post_key: "postF2", probe: "done" });
        expect(b.about).toEqual({
            sentence: "A person in a fox fursuit dances in a kitchen.",
            tags: ["fursuit", "dance", "fox"],
            edited: false,
            sound_tags: ["music"],
            transcript: null,
            language: null,
            frames: 0,
            has_audio: false,
            model: null,
            written_at: T0,
        });
        expect(b.words).toHaveLength(8);
        // the fake's vectors are hashed bags of words: a word of its text is among the nearest, best first
        expect(b.words.map((x: any) => x.word)).toContain("music");
        expect(b.words.map((x: any) => x.score)).toEqual([...b.words.map((x: any) => x.score)].sort((x: number, y: number) => y - x));
        for (const x of b.words) expect(Math.round(x.score * 100) / 100).toBe(x.score);
        expect(b.neighbours).toHaveLength(3); // only three other posts
        expect(Object.keys(b.posts).sort()).toEqual(b.neighbours.map((x: any) => x.post_id).sort());
        expect(b.posts[b.neighbours[0].post_id]).toMatchObject({ id: b.neighbours[0].post_id, files: expect.any(Array) });
        expect(b.index).toMatchObject({ post_key: "postF2", state: "indexed", search_enabled: true });
        expect(b.index.status).toBeUndefined();
        // a post with no row yet
        const cat = (await (await call("/library/about?key=postCat")).json()) as any;
        expect(cat).toMatchObject({ probe: "pending", about: null });
        expect(cat.words).toHaveLength(8);
    });

    it("refuses a missing or unknown key; with search off the words and neighbours are empty; before 0022 about is null", async () => {
        const { call, env, w } = await http();
        expect((await call("/library/about")).status).toBe(400);
        const unknown = await call("/library/about?key=nope");
        expect(unknown.status).toBe(404);
        expect(((await unknown.json()) as any).error.code).toBe("error.library.not_found");
        const off = (await (await call("/library/about?key=postF2", {}, { ...env, EMBED_TOKEN: undefined })).json()) as any;
        expect(off).toMatchObject({ words: [], neighbours: [], posts: {} });
        expect(off.about.sentence).toContain("fursuit");
        w.db.raw.exec("DROP TABLE media_about; DROP TABLE embed_terms;");
        const old = (await (await call("/library/about?key=postF2")).json()) as any;
        expect(old).toMatchObject({ status: "success", probe: "pending", about: null, words: [] });
    });

    it("PATCH sets the owner's tags (trimmed, lowercased, deduplicated), null goes back, bad bodies are 400, the service is refused", async () => {
        const { call, w } = await http();
        const patch = (body: unknown, headers: Record<string, string> = {}) => call("/library/about", { method: "PATCH", body: JSON.stringify(body), headers });
        const before = (await postInputs(w.d.db, MEDIA, "postF2"))[0]!;
        const r = await patch({ key: "postF2", tags: ["  Lia ", "lia", "Fox Fursuit"] });
        expect(r.status).toBe(200);
        const b = (await r.json()) as any;
        expect(b.about).toMatchObject({ tags: ["lia", "fox fursuit"], edited: true });
        expect(JSON.parse(aboutOf(w.db, "postF2").user_tags)).toEqual(["lia", "fox fursuit"]);
        expect(await inputHash((await postInputs(w.d.db, MEDIA, "postF2"))[0]!)).not.toBe(await inputHash(before));
        // [] is "no tags", null goes back to Haiku's
        expect(((await (await patch({ key: "postF2", tags: [] })).json()) as any).about.tags).toEqual([]);
        const reset = (await (await patch({ key: "postF2", tags: null })).json()) as any;
        expect(reset.about).toMatchObject({ tags: ["fursuit", "dance", "fox"], edited: false });
        // a post with no row yet gets one
        expect(((await (await patch({ key: "postCat", tags: ["nap"] })).json()) as any).about).toMatchObject({ sentence: null, tags: ["nap"], edited: true });
        expect(aboutOf(w.db, "postCat")).toMatchObject({ probe_state: "pending" });
        for (const bad of [{ key: "postF2" }, { key: "postF2", tags: ["x".repeat(31)] }, { key: "postF2", tags: [""] }, { key: "postF2", tags: [3] }, { key: "postF2", tags: Array.from({ length: 17 }, (_, i) => `t${i}`) }, { tags: [] }, "nope"]) {
            const res = await patch(bad);
            expect(res.status).toBe(400);
            expect(((await res.json()) as any).error.code).toBe("error.library.bad_request");
        }
        expect((await patch({ key: "nope", tags: [] })).status).toBe(404);
        const svc = await call("/library/about", { method: "PATCH", body: JSON.stringify({ key: "postF2", tags: [] }), headers: { authorization: "", "x-cobalt-service": INTERNAL } });
        expect(svc.status).toBe(404);
        // GET is fine for the service
        expect((await call("/library/about?key=postF2", { headers: { authorization: "", "x-cobalt-service": INTERNAL } })).status).toBe(200);
    });

    it("the chat: library.about is free (without the post shapes); library.about.set asks first", async () => {
        const { env, container, w } = await http();
        const pending: any[] = [];
        const collect = { look: [], show: [] };
        const box = chatToolbox(REGISTRY, opBase(env, container, { now: w.now, sleep: async () => {} }, REGISTRY), {
            threadId: "Thread0000000001",
            messageId: "1",
            collect,
            legacy: chatTools({ db: w.d.db, mediaBaseUrl: MEDIA, embed: w.space }, collect),
            flags: { search: true },
            pending: { put: async (_t, r) => void pending.push(r), take: async () => null, drop: async () => {} },
        });
        const about = (await box.tools["library.about"]!("postF2")) as any;
        expect(about).toMatchObject({ post_key: "postF2", probe: "done" });
        expect(about.posts).toBeUndefined();
        expect(about.status).toBeUndefined();
        expect(about.neighbours.length).toBeGreaterThan(0);
        const asked = (await box.tools["library.about.set"]!("postF2", ["lia"])) as any;
        expect(asked.pending_confirm.summary).toBe("set the tags of “instagram_De84mWBOe72.mp4”");
        expect(pending[0]).toMatchObject({ op: "library.about.set", input: { key: "postF2", tags: ["lia"] }, effect: { tags: ["lia"] } });
        expect(aboutOf(w.db, "postF2").user_tags).toBeNull(); // nothing ran
        // once a run asked, every later call in it is refused; a fresh run reads an unknown post as not found
        await expect(box.tools["library.about"]!("postF2")).rejects.toThrow(/waiting for Harmony/);
        const fresh = chatToolbox(REGISTRY, opBase(env, container, { now: w.now, sleep: async () => {} }, REGISTRY), {
            threadId: "Thread0000000001",
            messageId: "1",
            collect,
            legacy: chatTools({ db: w.d.db, mediaBaseUrl: MEDIA, embed: w.space }, collect),
            flags: { search: true },
            pending: null,
        });
        await expect(fresh.tools["library.about"]!("nope")).rejects.toThrow(/error.library.not_found/);
    });

    it("libraryAbout's neighbours are the 4 nearest live posts", async () => {
        const w = world();
        for (let i = 0; i < 7; i++) addFile(w.db, { session_id: `p${i}`, name: `fursuit ${"x".repeat(i)}.mp4` });
        addFile(w.db, { session_id: "gone", name: "fursuit.mp4", deleted_at: T0 });
        await w.index();
        const r = (await libraryAbout({ db: w.d.db, mediaBaseUrl: MEDIA, searchEnabled: true, app: w.d, now: w.now }, "p0")).body as any;
        expect(r.neighbours).toHaveLength(4);
        expect(r.neighbours.map((x: any) => x.post_id)).not.toContain("p0");
        expect(r.neighbours.map((x: any) => x.post_id)).not.toContain("gone");
        const scores = r.neighbours.map((x: any) => x.score);
        expect([...scores].sort((a: number, b: number) => b - a)).toEqual(scores);
    });
});

// ---- 34.6: GET /capabilities -------------------------------------------------------------------------------------------

describe("features.about and features.about_sound", () => {
    it("about exactly while search is on and the Anthropic key is set; about_sound while Workers AI is there too", async () => {
        const w = world();
        const f = async (search: boolean, about: boolean, sound: boolean) =>
            ((await capabilities(w.d, "missing", undefined, false, false, false, false, false, false, search, false, false, false, false, false, about, sound)).body as any).features;
        expect(await f(true, true, true)).toMatchObject({ about: true, about_sound: true });
        expect(await f(true, true, false)).toMatchObject({ about: true, about_sound: false });
        expect(await f(false, true, true)).toMatchObject({ about: false, about_sound: false });
        expect(await f(true, false, true)).toMatchObject({ about: false, about_sound: false });
    });

    it("GET /capabilities reads them from the env", async () => {
        const w = world();
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: w.d.db,
            ORIGINALS: w.originals,
            MEDIA: w.media,
            MEDIA_BASE_URL: MEDIA,
            EMBED_URL: SPACE,
            EMBED_TOKEN: "hf_tok",
            ANTHROPIC_API_KEY: "sk-ant",
            AI: { run: async () => ({}) },
        };
        const container = { fetch: async () => Response.json({}) };
        const get = async (e: WorkerEnv) => ((await (await handleRequest(new Request(`${API}/capabilities`), e, container, { now: w.now })).json()) as any).features;
        expect(await get(env)).toMatchObject({ about: true, about_sound: true });
        expect(await get({ ...env, AI: undefined })).toMatchObject({ about: true, about_sound: false });
        expect(await get({ ...env, ANTHROPIC_API_KEY: undefined })).toMatchObject({ about: false, about_sound: false });
    });
});
