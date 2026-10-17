// Library search (APP-API-CONTRACT.md section 21): the post inputs, the cron's indexer, the Space
// client and GET /library/search, on the real migrations (node:sqlite). The Space is a fake that
// "sees" a poster through a table of words per poster URL, so a word that is only in the picture
// still finds the post, as the real multimodal model does.
import { afterEach, describe, expect, it, vi } from "vitest";
import { capabilities, type AppDeps } from "../src/app-routes";
import {
    EMBED_DIMS,
    EMBED_MAX_ATTEMPTS,
    EMBED_MODEL,
    EMBED_RETRY_MS,
    EmbedError,
    SEARCH_RUN_BUDGET_MS,
    decodeVector,
    drainIndexer,
    dot,
    encodeVector,
    librarySearch,
    librarySearchIndex,
    librarySearchPost,
    MAX_POST_KEY_CHARS,
    normalize,
    postInputs,
    runIndexer,
    spaceClient,
    type EmbedClient,
    type EmbedInput,
} from "../src/embed";
import { decide, type GateRequest } from "../src/gate";
import { KEY_ID_HEADER, SERVICE_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { queueSnapshot } from "../src/queue";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SPACE = "https://capybaraharmony-cobalt-embed.hf.space";
const T0 = 1_800_000_000_000;

// ---- a fake Space ------------------------------------------------------------------------------

const PICTURES: Record<string, string> = {
    [`${MEDIA}posters/aaaaaaaaaa.jpg`]: "cat skateboard",
    [`${MEDIA}posters/bbbbbbbbbb.jpg`]: "beach sunset",
};

function wordVector(words: string): number[] {
    const v = new Array(EMBED_DIMS).fill(0);
    for (const w of words.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)) {
        let h = 0;
        for (const c of w) h = (h * 31 + c.charCodeAt(0)) >>> 0;
        v[h % EMBED_DIMS] += 1;
    }
    v[EMBED_DIMS - 1] += 0.01; // never all zero
    return normalize(v);
}

class FakeSpace implements EmbedClient {
    calls: { kind: string; inputs: EmbedInput[] }[] = [];
    fail: ((inputs: EmbedInput[]) => EmbedError | null) | null = null;
    async embed(kind: "document" | "query", inputs: EmbedInput[]) {
        this.calls.push({ kind, inputs });
        const e = this.fail?.(inputs);
        if (e) throw e;
        return {
            model: EMBED_MODEL,
            vectors: inputs.map((i) =>
                wordVector(`${kind === "document" ? (i.title ?? "") : ""} ${i.text} ${i.image_url ? (PICTURES[i.image_url] ?? "") : ""}`),
            ),
            images: inputs.map((i) => Boolean(i.image_url && PICTURES[i.image_url])),
        };
    }
}

// ---- the library -------------------------------------------------------------------------------

let n = 0;
function addFile(
    db: FakeD1,
    over: Partial<{
        id: string;
        name: string;
        link: string | null;
        poster: string | null;
        session_id: string | null;
        source: string;
        bucket: string;
        content_type: string;
        role: string | null;
        item_index: number | null;
        created_at: number;
        deleted_at: number | null;
    }> = {},
) {
    n++;
    const id = over.id ?? `item${String(n).padStart(12, "0")}`;
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, link, poster, session_id, role, item_index, created_at, deleted_at)
             VALUES (?, 'private', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
            id,
            over.source ?? "saved",
            over.bucket ?? "originals",
            `originals/${id}.mp4`,
            over.name ?? "clip.mp4",
            over.content_type ?? "video/mp4",
            over.link ?? null,
            over.poster ?? null,
            over.session_id ?? null,
            over.role ?? null,
            over.item_index ?? null,
            over.created_at ?? T0 + n,
            over.deleted_at ?? null,
        );
    return id;
}

function world() {
    const db: FakeD1 = createBatchD1();
    let now = T0 + 1_000_000;
    const space = new FakeSpace();
    const d: AppDeps = {
        db: db as unknown as D1Database,
        originals: new MemoryOriginals(),
        media: new MemoryMedia(),
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
    const index = (batch?: number) => runIndexer({ db: d.db, client: space, mediaBaseUrl: MEDIA, now: () => now, batch });
    const drain = (budgetMs = SEARCH_RUN_BUDGET_MS, batch?: number) =>
        drainIndexer({ db: d.db, client: space, mediaBaseUrl: MEDIA, now: () => now, batch, budgetMs });
    const runs = () => db.raw.prepare("SELECT * FROM search_index_runs ORDER BY id").all() as any[];
    const rows = () => db.raw.prepare("SELECT * FROM media_embeddings ORDER BY post_key").all() as any[];
    const search = (q: string, extra = "") => librarySearch({ ...d, embed: space }, new URLSearchParams(`q=${encodeURIComponent(q)}${extra}`));
    const tick = (ms: number) => (now += ms);
    return { db, d, space, index, drain, runs, rows, search, tick, now: () => now };
}

// ---- vectors -----------------------------------------------------------------------------------

describe("vectors", () => {
    it("round-trip through the column format as float32", () => {
        const v = wordVector("hello world");
        const back = decodeVector(encodeVector(v))!;
        expect(back.length).toBe(EMBED_DIMS);
        expect(dot(back, v)).toBeCloseTo(1, 5);
        expect(encodeVector(v).length).toBe(Math.ceil((EMBED_DIMS * 4) / 3) * 4);
    });

    it("refuse a column that is not whole floats", () => {
        expect(decodeVector("AAA=")).toBeNull();
        expect(decodeVector("%%%")).toBeNull();
    });
});

// ---- inputs ------------------------------------------------------------------------------------

describe("post inputs", () => {
    it("one input per live post: custom title first, names and link words, poster only from the media domain", () => {
        const w = world();
        addFile(w.db, { session_id: "sessA", name: "IMG_4021.mp4", link: "https://x.com/someone/status/1", poster: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        addFile(w.db, { session_id: "sessA", name: "IMG_4021.webp", source: "webp", bucket: "media", content_type: "image/webp" });
        addFile(w.db, { session_id: "sessB", name: "other.mp4", poster: "https://evil.example/p.jpg" });
        addFile(w.db, { session_id: "sessC", name: "gone.mp4", deleted_at: T0 });
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('sessA', 'my cat', 1)").run();

        return postInputs(w.d.db, MEDIA).then((inputs) => {
            expect(inputs.map((p) => p.post_key)).toEqual(["sessB", "sessA"]);
            const a = inputs.find((p) => p.post_key === "sessA")!;
            expect(a.title).toBe("my cat");
            expect(a.text).toContain("IMG_4021.mp4");
            expect(a.text).toContain("IMG_4021.webp");
            expect(a.text).toContain("x.com/someone/status/1");
            expect(a.image_url).toBe(`${MEDIA}posters/aaaaaaaaaa.jpg`);
            const b = inputs.find((p) => p.post_key === "sessB")!;
            expect(b.title).toBe("other.mp4");
            expect(b.image_url).toBeNull();
        });
    });
});

// ---- indexer -----------------------------------------------------------------------------------

describe("indexer", () => {
    it("embeds new posts a batch at a time, newest first, then nothing while inputs stay the same", async () => {
        const w = world();
        for (let i = 0; i < 5; i++) addFile(w.db, { session_id: `s${i}`, name: `clip${i}.mp4` });
        const r1 = await w.index(3);
        expect(r1).toMatchObject({ posts: 5, indexed: 3, failed: 0, pending: 2, unavailable: false });
        expect(w.space.calls[0]!.inputs.map((i) => i.title)).toEqual(["clip4.mp4", "clip3.mp4", "clip2.mp4"]);
        const r2 = await w.index(3);
        expect(r2).toMatchObject({ indexed: 2, pending: 0 });
        const r3 = await w.index(3);
        expect(r3).toMatchObject({ indexed: 0, pending: 0 });
        expect(w.space.calls).toHaveLength(2);
        const row = w.rows()[0];
        expect(row).toMatchObject({ model: EMBED_MODEL, dims: EMBED_DIMS, attempts: 0, failed_at: null });
        expect(decodeVector(row.vector)!.length).toBe(EMBED_DIMS);
    });

    it("re-embeds a post whose title or poster changed, and deletes the rows of posts that are gone", async () => {
        const w = world();
        const keep = addFile(w.db, { session_id: "sKeep", name: "a.mp4" });
        addFile(w.db, { session_id: "sGone", name: "b.mp4" });
        await w.index();
        expect(w.rows()).toHaveLength(2);

        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('sKeep', 'renamed', 1)").run();
        w.db.raw.prepare("UPDATE media_items SET poster = ? WHERE id = ?").run(`${MEDIA}posters/aaaaaaaaaa.jpg`, keep);
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE session_id = 'sGone'").run();
        const r = await w.index();
        expect(r).toMatchObject({ indexed: 1, removed: 1 });
        expect(w.space.calls[1]!.inputs[0]).toMatchObject({ title: "renamed", image_url: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        expect(w.rows().map((x) => x.post_key)).toEqual(["sKeep"]);
        expect(w.rows()[0].has_image).toBe(1);
    });

    it("a Space that is asleep or down holds nothing against the posts", async () => {
        const w = world();
        addFile(w.db, { session_id: "s1" });
        w.space.fail = () => new EmbedError("unavailable", 503);
        for (let i = 0; i < 5; i++) {
            const r = await w.index();
            expect(r).toMatchObject({ indexed: 0, failed: 0, pending: 1, unavailable: true });
        }
        expect(w.rows()).toHaveLength(0);
        w.space.fail = null;
        expect(await w.index()).toMatchObject({ indexed: 1 });
    });

    it("a refused batch is retried one by one; only the bad post waits an hour, and is given up after three refusals", async () => {
        const w = world();
        addFile(w.db, { session_id: "good", name: "fine.mp4" });
        addFile(w.db, { session_id: "bad", name: "poison.mp4" });
        w.space.fail = (inputs) => (inputs.some((i) => i.title === "poison.mp4") ? new EmbedError("rejected", 400) : null);

        const r1 = await w.index();
        expect(r1).toMatchObject({ indexed: 1, failed: 1, pending: 0 });
        const bad = () => w.rows().find((x) => x.post_key === "bad");
        expect(bad()).toMatchObject({ vector: null, attempts: 1, failed_at: expect.any(Number) });

        // not again within the hour
        const calls = w.space.calls.length;
        expect(await w.index()).toMatchObject({ indexed: 0, failed: 0 });
        expect(w.space.calls.length).toBe(calls);

        for (let i = 2; i <= EMBED_MAX_ATTEMPTS; i++) {
            w.tick(EMBED_RETRY_MS + 1);
            await w.index();
            expect(bad().attempts).toBe(i);
        }
        w.tick(EMBED_RETRY_MS + 1);
        const before = w.space.calls.length;
        await w.index();
        expect(w.space.calls.length).toBe(before);

        // a changed input starts over
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('bad', 'better', 1)").run();
        w.space.fail = null;
        expect(await w.index()).toMatchObject({ indexed: 1 });
        expect(bad()).toMatchObject({ attempts: 0, failed_at: null });
    });
});

// ---- the cron's drain ---------------------------------------------------------------------------

describe("drain", () => {
    const posts = (w: ReturnType<typeof world>, k: number) => {
        for (let i = 0; i < k; i++) addFile(w.db, { session_id: `s${i}`, name: `clip${i}.mp4` });
    };

    it("loops passes until nothing is pending, and records the run", async () => {
        const w = world();
        posts(w, 20);
        const r = await w.drain();
        expect(r).toMatchObject({ posts: 20, indexed: 20, failed: 0, pending: 0, unavailable: false, passes: 3, stop: "empty" });
        expect(w.space.calls).toHaveLength(3);
        expect(w.runs()).toEqual([
            { id: 1, trigger: "cron", started_at: w.now(), finished_at: w.now(), passes: 3, indexed: 20, failed: 0, unavailable: 0, stop: "empty" },
        ]);
        // nothing to do: one pass, no Space call, still recorded
        expect(await w.drain()).toMatchObject({ indexed: 0, passes: 1, stop: "empty" });
        expect(w.space.calls).toHaveLength(3);
        expect(w.runs()).toHaveLength(2);
    });

    it("stops when the Space is unavailable", async () => {
        const w = world();
        posts(w, 20);
        w.space.fail = () => (w.space.calls.length > 1 ? new EmbedError("unavailable", 503) : null);
        const r = await w.drain();
        expect(r).toMatchObject({ indexed: 8, pending: 12, unavailable: true, passes: 2, stop: "unavailable" });
        expect(w.runs()[0]).toMatchObject({ passes: 2, indexed: 8, unavailable: 1, stop: "unavailable" });
    });

    it("stops when the next pass would not fit in the budget (~96 posts in 10 minutes at 50 s a batch)", async () => {
        const w = world();
        posts(w, 200);
        const embed = w.space.embed.bind(w.space);
        w.space.embed = async (kind, inputs) => {
            w.tick(50_000);
            return embed(kind, inputs);
        };
        const start = w.now();
        const r = await w.drain();
        expect(r).toMatchObject({ indexed: 96, pending: 104, passes: 12, stop: "budget" });
        expect(w.now() - start).toBeLessThanOrEqual(SEARCH_RUN_BUDGET_MS);
        expect(w.runs()[0]).toMatchObject({ started_at: start, finished_at: w.now(), indexed: 96, stop: "budget" });
    });

    it("stops when a pass moves nothing", async () => {
        const w = world();
        posts(w, 3);
        expect(await w.drain(SEARCH_RUN_BUDGET_MS, 0)).toMatchObject({ indexed: 0, pending: 3, passes: 1, stop: "stalled" });
    });

    it("shows progress while it runs, and the queue says running", async () => {
        const w = world();
        posts(w, 12);
        const seen: any[] = [];
        const embed = w.space.embed.bind(w.space);
        w.space.embed = async (kind, inputs) => {
            if (w.space.calls.length === 1) {
                seen.push(w.runs()[0]);
                seen.push(await queueSnapshot({ db: w.d.db, mediaBaseUrl: MEDIA, now: w.now, searchEnabled: true, line: async () => null }));
            }
            return embed(kind, inputs);
        };
        await w.drain();
        expect(seen[0]).toMatchObject({ passes: 1, indexed: 8, finished_at: null, stop: null });
        expect(seen[1].body.search).toMatchObject({ running: true, indexed: 8, pending: 4 });
        expect(w.runs()[0]).toMatchObject({ passes: 2, indexed: 12, stop: "empty" });
    });

    it("still indexes without the run table (migration 0011 not applied yet)", async () => {
        const w = world();
        posts(w, 2);
        w.db.raw.exec("DROP TABLE search_index_runs");
        expect(await w.drain()).toMatchObject({ indexed: 2, stop: "empty" });
    });

    it("POST /library/search/index is one pass; ?drain=1 loops under the request budget; anything else is 400", async () => {
        const w = world();
        posts(w, 20);
        const call = (q: string) => librarySearchIndex({ ...w.d, embed: w.space }, new URLSearchParams(q));
        const one = await call("");
        expect(one).toEqual({
            status: 200,
            body: { status: "success", posts: 20, indexed: 8, failed: 0, removed: 0, pending: 12, unavailable: false },
        });
        expect((await call("drain=1")).body).toMatchObject({ indexed: 12, pending: 0, passes: 2, stop: "empty" });
        expect(w.runs().map((r) => r.trigger)).toEqual(["request", "request"]);
        expect((await call("drain=yes")).status).toBe(400);
    });
});

// ---- search ------------------------------------------------------------------------------------

describe("GET /library/search", () => {
    async function library() {
        const w = world();
        addFile(w.db, { session_id: "catpost", name: "IMG_4021.mp4", poster: `${MEDIA}posters/aaaaaaaaaa.jpg`, link: "https://x.com/a/status/1" });
        addFile(w.db, { session_id: "beachpost", name: "IMG_4022.mp4", poster: `${MEDIA}posters/bbbbbbbbbb.jpg` });
        addFile(w.db, { session_id: "named", name: "skateboard tricks compilation.mp4" });
        await w.index();
        return w;
    }

    it("finds a post by what its poster shows, in the GET /library post shape with a score", async () => {
        const w = await library();
        const r = await w.search("cat");
        expect(r.status).toBe(200);
        const body = r.body as any;
        expect(body.posts[0]).toMatchObject({ id: "catpost", title: "IMG_4021.mp4", poster_url: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        expect(body.posts[0].files.length).toBe(1);
        expect(typeof body.posts[0].score).toBe("number");
        expect(body.index).toEqual({ posts: 3, pending: 0 });
        expect(w.space.calls.at(-1)).toMatchObject({ kind: "query", inputs: [{ text: "cat" }] });
    });

    it("a plain text match ranks first, even for a post not embedded yet", async () => {
        const w = await library();
        addFile(w.db, { session_id: "fresh", name: "sunset drive.mp4" });
        const body = (await w.search("sunset drive")).body as any;
        expect(body.posts[0].id).toBe("fresh");
        expect(body.index.pending).toBe(1);
        const sk = (await w.search("skateboard")).body as any;
        expect(sk.posts.slice(0, 2).map((p: any) => p.id).sort()).toEqual(["catpost", "named"]);
        expect(sk.posts[0].id).toBe("named");
    });

    it("never returns a deleted post, and honours limit", async () => {
        const w = await library();
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE session_id = 'catpost'").run();
        const body = (await w.search("cat", "&limit=1")).body as any;
        expect(body.posts).toHaveLength(1);
        expect(body.posts[0].id).not.toBe("catpost");
    });

    it("refuses an empty or too long query and a bad limit", async () => {
        const w = await library();
        for (const q of ["", "   ", "x".repeat(201)]) expect((await w.search(q)).status).toBe(400);
        for (const l of ["0", "51", "abc"]) expect((await w.search("cat", `&limit=${l}`)).status).toBe(400);
    });

    it("a sleeping Space answers 503 error.search.waking; none configured is error.search.off", async () => {
        const w = await library();
        w.space.fail = () => new EmbedError("unavailable", null);
        const r = await w.search("cat");
        expect(r).toEqual({ status: 503, body: { status: "error", error: { code: "error.search.waking" } } });
        const off = await librarySearch({ ...w.d, embed: null }, new URLSearchParams("q=cat"));
        expect(off).toEqual({ status: 503, body: { status: "error", error: { code: "error.search.off" } } });
    });
});

// ---- the Space client --------------------------------------------------------------------------

describe("Space client", () => {
    const vec = () => new Array(EMBED_DIMS).fill(0).map((_, i) => (i === 0 ? 2 : 0));
    const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

    it("is off without an https URL or a token", () => {
        expect(spaceClient({ url: SPACE })).toBeNull();
        expect(spaceClient({ url: "http://x.hf.space", token: "hf_x" })).toBeNull();
        expect(spaceClient({ url: SPACE, token: "" })).toBeNull();
        expect(spaceClient({ url: SPACE, token: "hf_x" })).not.toBeNull();
    });

    it("posts the contract with both credentials and normalizes what comes back", async () => {
        const seen: { url: string; init: RequestInit }[] = [];
        const c = spaceClient({ url: `${SPACE}/`, token: "hf_tok", key: "space-key" }, (async (url: string, init: RequestInit) => {
            seen.push({ url, init });
            return ok({ model: EMBED_MODEL, dims: EMBED_DIMS, vectors: [vec()], images: [true] });
        }) as unknown as typeof fetch)!;
        const r = await c.embed("document", [{ title: "t", text: "x", image_url: null }], 1000);
        expect(seen[0]!.url).toBe(`${SPACE}/embed`);
        const h = seen[0]!.init.headers as Record<string, string>;
        expect(h.authorization).toBe("Bearer hf_tok");
        expect(h["x-embed-key"]).toBe("space-key");
        expect(JSON.parse(seen[0]!.init.body as string)).toEqual({ kind: "document", dims: EMBED_DIMS, inputs: [{ title: "t", text: "x", image_url: null }] });
        expect(r.vectors[0]![0]).toBeCloseTo(1, 6);
        expect(r.images).toEqual([true]);
    });

    it("maps failures: 400 rejected; 401/403/404, 5xx, a booting HTML page, a wrong shape and a timeout unavailable", async () => {
        const run = async (res: () => Promise<Response>, timeout = 1000) => {
            const c = spaceClient({ url: SPACE, token: "hf" }, (async () => res()) as unknown as typeof fetch)!;
            try {
                await c.embed("query", [{ title: null, text: "q", image_url: null }], timeout);
                return "ok";
            } catch (e) {
                return e instanceof EmbedError ? `${e.kind}:${e.status}` : "other";
            }
        };
        expect(await run(async () => ok({ detail: "inputs" }, 400))).toBe("rejected:400");
        expect(await run(async () => ok({}, 401))).toBe("unavailable:401");
        expect(await run(async () => ok({}, 404))).toBe("unavailable:404");
        expect(await run(async () => ok({}, 503))).toBe("unavailable:503");
        expect(await run(async () => new Response("<html>building</html>", { status: 200 }))).toBe("unavailable:200");
        expect(await run(async () => ok({ model: EMBED_MODEL, vectors: [[1, 2, 3]] }))).toBe("unavailable:200");
        expect(await run(async () => Promise.reject(new TypeError("network")))).toBe("unavailable:null");
        expect(await run(() => new Promise<Response>(() => {}), 20)).toBe("unavailable:null");
    });
});

// ---- the gate, the Worker and capabilities ------------------------------------------------------

describe("routing", () => {
    const req = (method: string, pathname: string): GateRequest => ({
        method,
        pathname,
        searchParams: new URLSearchParams(),
        origin: null,
        authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11",
        service: false,
    });

    it("GET /library/search and POST /library/search/index are keyed routes; other methods 404", () => {
        expect(decide(req("GET", "/library/search"), { corsUrl: "x", now: 0 })).toMatchObject({ action: "lookup", then: "library_search" });
        expect(decide(req("POST", "/library/search/index"), { corsUrl: "x", now: 0 })).toMatchObject({ action: "lookup", then: "library_search_index" });
        expect(decide(req("POST", "/library/search"), { corsUrl: "x", now: 0 })).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req("GET", "/library/search/index"), { corsUrl: "x", now: 0 })).toMatchObject({ action: "reject", status: 404 });
        expect(decide({ ...req("GET", "/library/search"), authorization: null }, { corsUrl: "x", now: 0 }).action).toBe("reject");
    });

    afterEach(() => vi.unstubAllGlobals());

    it("the Worker answers a keyed search through the Space configured in its env, without the container", async () => {
        const w = world();
        addFile(w.db, { session_id: "catpost", poster: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        await w.index();
        const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
        w.db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run("k1", "test", await hashKey(KEY), "0b5f2c3e", 1);
        const space = new FakeSpace();
        const calls: string[] = [];
        vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
            calls.push(url);
            const body = JSON.parse(init.body as string);
            return new Response(JSON.stringify(await space.embed(body.kind, body.inputs)), { status: 200 });
        });
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
            DB: w.d.db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: MEDIA,
            EMBED_URL: SPACE,
            EMBED_TOKEN: "hf_tok",
        };
        const container = { fetch: async () => new Response("container must not be called", { status: 500 }) };
        const res = await handleRequest(
            new Request("https://api.capybaraharmony.com/library/search?q=skateboard&v=3", { headers: { Authorization: `Api-Key ${KEY}` } }),
            env,
            container,
            { now: () => T0 + 1_000_000 },
        );
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        const body = (await res.json()) as any;
        expect(body.posts.map((p: any) => p.id)).toEqual(["catpost"]);
        expect(calls).toEqual([`${SPACE}/embed`]);

        const off = await handleRequest(
            new Request("https://api.capybaraharmony.com/library/search?q=cat", { headers: { Authorization: `Api-Key ${KEY}` } }),
            { ...env, EMBED_TOKEN: undefined },
            container,
        );
        expect(off.status).toBe(503);
        expect(((await off.json()) as any).error.code).toBe("error.search.off");
    });

    it("capabilities says features.search only while the Space is configured", async () => {
        const w = world();
        const on = (await capabilities(w.d, "missing", undefined, false, false, false, false, false, true)).body as any;
        const off = (await capabilities(w.d, "missing", undefined)).body as any;
        expect(on.features.search).toBe(true);
        expect(off.features.search).toBe(false);
        expect(on.features.queue).toBe(true);
        expect(off.features.queue).toBe(true);
    });
});

// ---- GET /queue --------------------------------------------------------------------------------

describe("GET /queue", () => {
    const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const snapshot = (w: ReturnType<typeof world>, over: Partial<Parameters<typeof queueSnapshot>[0]> = {}) =>
        queueSnapshot({ db: w.d.db, mediaBaseUrl: MEDIA, now: w.now, searchEnabled: true, line: async () => null, ...over });

    it("search: posts = indexed + pending + failed, the next five newest first, and the run numbers", async () => {
        const w = world();
        for (let i = 0; i < 9; i++) addFile(w.db, { session_id: `s${i}`, name: `clip${i}.mp4` });
        let body = (await snapshot(w)).body as any;
        expect(body.search).toMatchObject({ enabled: true, posts: 9, indexed: 0, pending: 9, failed: 0, running: false, last_run_at: null, rate_per_hour: null });

        const start = w.now();
        await w.drain(SEARCH_RUN_BUDGET_MS, 2);
        // keep two vectors, and have the Space refuse the next newest post
        w.db.raw.exec("DELETE FROM media_embeddings WHERE post_key NOT IN ('s8', 's7')");
        w.space.fail = (inputs) => (inputs.some((i) => i.title === "clip6.mp4") ? new EmbedError("rejected", 400) : null);
        await w.index(1);
        w.tick(1000);

        body = (await snapshot(w)).body as any;
        expect(body.now).toBe(w.now());
        expect(body.search).toEqual({
            enabled: true,
            posts: 9,
            indexed: 2,
            pending: 6,
            failed: 1,
            running: false,
            last_run_at: start,
            rate_per_hour: 9,
            next: [5, 4, 3, 2, 1].map((i) => ({ post_key: `s${i}`, title: `clip${i}.mp4` })),
        });
        // rate counts the runs of the last hour only
        w.tick(60 * 60 * 1000);
        expect(((await snapshot(w)).body as any).search.rate_per_hour).toBeNull();
    });

    it("search off is { enabled: false }; posters counts the originals still without a poster", async () => {
        const w = world();
        addFile(w.db, { session_id: "a" });
        addFile(w.db, { session_id: "b", poster: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        addFile(w.db, { session_id: "c", content_type: "image/heic" });
        const body = (await snapshot(w, { searchEnabled: false })).body as any;
        expect(body.search).toEqual({ enabled: false });
        expect(body.posters).toEqual({ pending: 1 });
        expect(body.line).toBeNull();
    });

    it("a part that fails is null; the answer is still 200", async () => {
        const w = world();
        w.db.breakIt();
        const r = await snapshot(w, { line: async () => ({ status: "success", entries: [] }) });
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ line: { status: "success", entries: [] }, search: null, posters: null });
        const hung = await snapshot(world(), { line: () => new Promise(() => {}) });
        expect((hung.body as any).line).toBeNull();
    }, 10_000);

    it("the gate: keyed GET only; the service credential and other methods are 404", () => {
        const req = (method: string, over: Partial<GateRequest> = {}): GateRequest => ({
            method,
            pathname: "/queue",
            searchParams: new URLSearchParams(),
            origin: null,
            authorization: `Api-Key ${KEY}`,
            service: false,
            ...over,
        });
        const cfg = { corsUrl: "x", now: 0 };
        expect(decide(req("GET"), cfg)).toMatchObject({ action: "lookup", then: "queue" });
        expect(decide(req("POST"), cfg)).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req("GET", { service: true }), cfg)).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req("GET", { authorization: null }), cfg)).toMatchObject({ action: "reject", status: 401 });
    });

    it("the Worker: 401 without a key; with one, the line comes from the Durable Object's GET /studio/line for that key", async () => {
        const w = world();
        addFile(w.db, { session_id: "s1", name: "one.mp4" });
        w.db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run("k1", "test", await hashKey(KEY), "0b5f2c3e", 1);
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
            DB: w.d.db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: MEDIA,
            EMBED_URL: SPACE,
            EMBED_TOKEN: "hf_tok",
        };
        const line = { status: "success", now: 1, running: null, entries: [], max: 50, wait_ms: 1800000 };
        const seen: Request[] = [];
        let lineStatus = 200;
        const container = {
            fetch: async (r: Request) => {
                seen.push(r);
                return new Response(JSON.stringify(line), { status: lineStatus });
            },
        };
        const call = (headers: Record<string, string> = {}) =>
            handleRequest(new Request("https://api.capybaraharmony.com/queue", { headers }), env, container, { now: () => T0 + 5 });

        const anon = await call();
        expect(anon.status).toBe(401);
        expect(seen).toHaveLength(0);

        const res = await call({ Authorization: `Api-Key ${KEY}` });
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        const body = (await res.json()) as any;
        expect(body).toMatchObject({ status: "success", now: T0 + 5, line, posters: { pending: 1 } });
        expect(body.search).toMatchObject({ enabled: true, posts: 1, pending: 1, next: [{ post_key: "s1", title: "one.mp4" }] });
        expect(seen).toHaveLength(1);
        expect(seen[0]!.method).toBe("GET");
        expect(new URL(seen[0]!.url).pathname).toBe("/studio/line");
        expect(seen[0]!.headers.get(KEY_ID_HEADER)).toBe("k1");
        expect(seen[0]!.headers.get("authorization")).toBeNull();

        lineStatus = 503;
        expect(((await (await call({ Authorization: `Api-Key ${KEY}` })).json()) as any).line).toBeNull();
    });
});

// ---- GET /library/search/post ------------------------------------------------------------------

describe("GET /library/search/post", () => {
    const status = (w: ReturnType<typeof world>, key: string, searchEnabled = true) =>
        librarySearchPost({ db: w.d.db, mediaBaseUrl: MEDIA, searchEnabled }, new URLSearchParams({ key }));
    const body = async (w: ReturnType<typeof world>, key: string, searchEnabled = true) => {
        const r = await status(w, key, searchEnabled);
        expect(r.status).toBe(200);
        return r.body as any;
    };

    it("pending: never embedded; the input is what would be embedded now", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1", name: "IMG_1.mp4", link: "https://x.com/a/status/1", poster: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        addFile(w.db, { session_id: "other", name: "other.mp4" });
        const b = await body(w, "p1");
        expect(b).toEqual({
            status: "success",
            post_key: "p1",
            state: "pending",
            search_enabled: true,
            attempts: 0,
            input: { title: "IMG_1.mp4", text: "IMG_1.mp4 · x.com/a/status/1", image_url: `${MEDIA}posters/aaaaaaaaaa.jpg` },
            embedded_matches_input: false,
        });
        // the one-post input is the same as the whole-library one
        const all = (await postInputs(w.d.db, MEDIA)).find((p) => p.post_key === "p1")!;
        expect(b.input).toEqual({ title: all.title, text: all.text, image_url: all.image_url });
    });

    it("indexed: the vector of the current input, with model, dims, when and whether the poster was seen; never the vector", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1", poster: `${MEDIA}posters/aaaaaaaaaa.jpg` });
        await w.index();
        const b = await body(w, "p1");
        expect(b).toMatchObject({
            state: "indexed",
            model: EMBED_MODEL,
            dims: EMBED_DIMS,
            embedded_at: w.now(),
            has_image: true,
            attempts: 0,
            embedded_matches_input: true,
        });
        expect(b).not.toHaveProperty("vector");
        expect(b).not.toHaveProperty("failed_at");
        expect(b).not.toHaveProperty("retry_at");
    });

    it("stale: a vector of an older input (renamed); indexed again after the next pass", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1", name: "a.mp4" });
        await w.index();
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('p1', 'renamed', 1)").run();
        const b = await body(w, "p1");
        expect(b).toMatchObject({ state: "stale", model: EMBED_MODEL, embedded_matches_input: false, input: { title: "renamed" } });
        await w.index();
        expect((await body(w, "p1")).state).toBe("indexed");
    });

    it("failed: refused, with failed_at, attempts and retry_at; gave_up after the last attempt; a changed input starts over", async () => {
        const w = world();
        addFile(w.db, { session_id: "bad", name: "poison.mp4" });
        w.space.fail = () => new EmbedError("rejected", 400);
        await w.index();
        const failedAt = w.now();
        let b = await body(w, "bad");
        expect(b).toMatchObject({ state: "failed", failed_at: failedAt, retry_at: failedAt + EMBED_RETRY_MS, attempts: 1, embedded_matches_input: false });
        expect(b).not.toHaveProperty("model");
        for (let i = 2; i <= EMBED_MAX_ATTEMPTS; i++) {
            w.tick(EMBED_RETRY_MS + 1);
            await w.index();
        }
        b = await body(w, "bad");
        expect(b).toMatchObject({ state: "gave_up", attempts: EMBED_MAX_ATTEMPTS, failed_at: w.now() });
        expect(b).not.toHaveProperty("retry_at");

        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('bad', 'better', 1)").run();
        expect(await body(w, "bad")).toMatchObject({ state: "pending", attempts: 0, failed_at: expect.any(Number) });
    });

    it("a refusal after an earlier vector: failed (the old vector is kept, stale), not indexed", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1", name: "a.mp4" });
        await w.index();
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('p1', 'poison', 1)").run();
        w.space.fail = () => new EmbedError("rejected", 400);
        await w.index();
        const b = await body(w, "p1");
        expect(b).toMatchObject({ state: "failed", model: EMBED_MODEL, attempts: 1, embedded_matches_input: false });
    });

    it("search off still answers from D1 with search_enabled: false", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1" });
        await w.index();
        expect(await body(w, "p1", false)).toMatchObject({ state: "indexed", search_enabled: false });
    });

    it("404 for a key that is not a live post (unknown or deleted); 400 for a missing or oversized key", async () => {
        const w = world();
        addFile(w.db, { session_id: "gone", deleted_at: T0 });
        for (const key of ["nope", "gone"]) {
            const r = await status(w, key);
            expect(r).toEqual({ status: 404, body: { status: "error", error: { code: "error.library.not_found" } } });
        }
        for (const q of ["", "key=", `key=${"a".repeat(MAX_POST_KEY_CHARS + 1)}`]) {
            const r = await librarySearchPost({ db: w.d.db, mediaBaseUrl: MEDIA, searchEnabled: true }, new URLSearchParams(q));
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.library.bad_request" } } });
        }
    });

    it("the gate: GET keyed or service; other methods 404; no credential 401", () => {
        const req = (method: string, over: Partial<GateRequest> = {}): GateRequest => ({
            method,
            pathname: "/library/search/post",
            searchParams: new URLSearchParams("key=p1"),
            origin: null,
            authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11",
            service: false,
            ...over,
        });
        const cfg = { corsUrl: "x", now: 0 };
        expect(decide(req("GET"), cfg)).toMatchObject({ action: "lookup", then: "library_search_post" });
        expect(decide(req("GET", { service: true, authorization: null }), cfg)).toMatchObject({ action: "service", then: "library_search_post" });
        for (const m of ["POST", "PUT", "PATCH", "DELETE"]) expect(decide(req(m), cfg)).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req("GET", { authorization: null }), cfg)).toMatchObject({ action: "reject", status: 401 });
    });

    it("the Worker: keyed and service answer from D1 without the container or the Space; 401 without a credential", async () => {
        const w = world();
        addFile(w.db, { session_id: "p1", name: "one.mp4" });
        await w.index();
        const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
        const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
        w.db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run("k1", "test", await hashKey(KEY), "0b5f2c3e", 1);
        const fetches: string[] = [];
        vi.stubGlobal("fetch", async (u: string) => {
            fetches.push(u);
            return new Response("no", { status: 500 });
        });
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: w.d.db,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: MEDIA,
            EMBED_URL: SPACE,
            EMBED_TOKEN: "hf_tok",
        };
        const container = { fetch: async () => new Response("container must not be called", { status: 500 }) };
        const call = (headers: Record<string, string>, e: WorkerEnv = env, key = "p1") =>
            handleRequest(
                new Request(`https://api.capybaraharmony.com/library/search/post?key=${encodeURIComponent(key)}`, { headers }),
                e,
                container,
                { now: () => T0 + 1_000_000 },
            );
        try {
            const keyed = await call({ Authorization: `Api-Key ${KEY}` });
            expect(keyed.status).toBe(200);
            expect(keyed.headers.get("cache-control")).toBe("no-store");
            expect(await keyed.json()).toMatchObject({ status: "success", post_key: "p1", state: "indexed", search_enabled: true });

            const svc = await call({ [SERVICE_HEADER]: INTERNAL });
            expect(svc.status).toBe(200);
            expect(((await svc.json()) as any).state).toBe("indexed");

            const off = await call({ Authorization: `Api-Key ${KEY}` }, { ...env, EMBED_TOKEN: undefined });
            expect(await off.json()).toMatchObject({ state: "indexed", search_enabled: false });

            expect((await call({ Authorization: `Api-Key ${KEY}` }, env, "missing")).status).toBe(404);
            expect((await call({})).status).toBe(401);
            expect(fetches).toEqual([]);
        } finally {
            vi.unstubAllGlobals();
        }
    });
});
