// Search names (APP-API-CONTRACT.md section 48): the routes (create, list, change, delete, clashes and limits), the point
// math, which posts carry a name, the preview and one post's names, the cron step, GET /library/search with and without
// names (names=0, the name-match fallback, hidden posts), the chat calls, and a database without migration 0031. The
// real SQL runs on node:sqlite; the Space is a fake that answers a vector per exact text.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { capabilities, type AppDeps } from "../src/app-routes";
import { chatTools } from "../src/chat-tools";
import { mcpToolList } from "../src/mcp";
import {
    EMBED_DIMS,
    EMBED_MODEL,
    EmbedError,
    TEXT_MATCH_BONUS,
    decodeVector,
    dot,
    encodeVector,
    librarySearch,
    normalize,
    resetQueryVectorMemo,
    searchPosts,
    type EmbedClient,
    type EmbedInput,
} from "../src/embed";
import { hashKey } from "../src/keys";
import {
    applyNames,
    carries,

    meaningHash,
    namePoint,
    NAMES_MAX,
    previewName,
    refreshNames,
    saidNames,
    saveName,
} from "../src/names";
import { chatToolbox, runConfirmed } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import type { PendingConfirm, PendingPort } from "../src/registry/pending";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SPACE = "https://capybaraharmony-cobalt-embed.hf.space";
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const T0 = 1_800_000_000_000;
const MEANING = "pink-haired cat girl";
const KEY_HASH = await hashKey(KEY);

// ---- vectors ----------------------------------------------------------------------------------------------------------

const vecOf = (parts: Record<number, number>): number[] => {
    const v = new Array<number>(EMBED_DIMS).fill(0);
    for (const [i, x] of Object.entries(parts)) v[Number(i)] = x;
    return normalize(v);
};
const axis = (i: number) => vecOf({ [i]: 1 });

// The fake Space: a vector per exact text (axis 255 for any other text).
class FakeSpace implements EmbedClient {
    table: Record<string, number[]> = { [MEANING]: axis(0), "a dog": axis(2) };
    calls: { kind: string; texts: string[] }[] = [];
    down = false;
    async embed(kind: "document" | "query", inputs: EmbedInput[]) {
        this.calls.push({ kind, texts: inputs.map((i) => i.text) });
        if (this.down) throw new EmbedError("unavailable", 503);
        return { model: EMBED_MODEL, vectors: inputs.map((i) => this.table[i.text] ?? axis(EMBED_DIMS - 1)), images: inputs.map(() => false) };
    }
}

// ---- the world --------------------------------------------------------------------------------------------------------

let n = 0;
function world() {
    const db: FakeD1 = createBatchD1();
    let now = T0;
    const space = new FakeSpace();
    const addPost = (key: string, name: string, v: number[] | null) => {
        n++;
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, session_id, created_at)
                 VALUES (?, 'private', 'saved', 'originals', ?, ?, 'video/mp4', ?, ?)`,
            )
            .run(`item${String(n).padStart(12, "0")}`, `originals/${n}.mp4`, name, key, T0 + n);
        if (v) {
            db.raw
                .prepare("INSERT INTO media_embeddings (post_key, model, dims, vector, input_hash, embedded_at) VALUES (?, ?, ?, ?, 'h', ?)")
                .run(key, EMBED_MODEL, EMBED_DIMS, encodeVector(v), T0);
        }
    };
    const hide = (key: string) => db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'hidden', 'you', NULL, 1)").run(key);
    const d = { db: db as unknown as D1Database, embed: space as EmbedClient | null, now: () => now };
    const app: AppDeps = {
        db: d.db,
        originals: new MemoryOriginals(),
        media: new MemoryMedia(),
        mediaBaseUrl: MEDIA,
        apiUrl: `${API}/`,
        webUrl: "https://cobalt.capybaraharmony.com",
        now: () => now,
        fixedLength: () => {
            throw new Error("unused");
        },
        adopt: async () => {
            throw new Error("unused");
        },
    };
    const search = (q: string, extra = "") => librarySearch({ ...app, embed: space }, new URLSearchParams(`q=${encodeURIComponent(q)}&v=3${extra}`));
    const env: WorkerEnv = {
        API_URL: `${API}/`,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
        DB: d.db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        EMBED_URL: SPACE,
        EMBED_TOKEN: "hf_tok",
    };
    const container = { fetch: async () => new Response("container must not be called", { status: 500 }) };
    const http = async (method: string, path: string, body?: unknown) => {
        const res = await handleRequest(
            new Request(`${API}${path}`, {
                method,
                headers: { Authorization: `Api-Key ${KEY}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
                body: body === undefined ? undefined : JSON.stringify(body),
            }),
            env,
            container,
            { now: () => now },
        );
        const text = await res.text();
        return { status: res.status, body: text ? JSON.parse(text) : null, headers: res.headers };
    };
    const one = (sql: string, ...p: unknown[]) => db.raw.prepare(sql).get(...(p as any[])) as any;
    const tick = (ms: number) => (now += ms);
    return { db, d, app, space, env, addPost, hide, search, http, one, tick };
}
type World = ReturnType<typeof world>;

// The Worker's Space client goes through fetch: answer it from the world's fake.
let current: World | null = null;
beforeEach(async () => {
    resetQueryVectorMemo();
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
        if (!current || !String(url).endsWith("/embed")) return new Response("no", { status: 404 });
        const body = JSON.parse(init.body as string);
        return new Response(JSON.stringify(await current.space.embed(body.kind, body.inputs)), { status: 200 });
    });
});
afterEach(() => {
    vi.unstubAllGlobals();
    current = null;
});

async function setup() {
    const w = world();
    current = w;
    w.db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("k1", "test", KEY_HASH, "0b5f2c3e", 1);
    // lia1 is the meaning itself, lia2 close, half too far for the default cut-off, far nothing like it
    w.addPost("lia1", "IMG_0001.mp4", axis(0));
    w.addPost("lia2", "IMG_0002.mp4", vecOf({ 0: 0.8, 1: 0.6 }));
    w.addPost("half", "IMG_0003.mp4", vecOf({ 0: 0.4, 3: Math.sqrt(1 - 0.16) }));
    w.addPost("far", "IMG_0004.mp4", axis(2));
    w.addPost("fresh", "IMG_0005.mp4", null);
    return w;
}
const lia = (over: Record<string, unknown> = {}) => ({ name: "Lia", meaning: MEANING, aliases: ["lia-chan", "my model"], ...over });

// ---- the point and carrying (48.2) ----------------------------------------------------------------------------------

describe("the point (48.2)", () => {
    it("only the meaning, only the examples, both blended by strength, neither null", () => {
        const m = axis(0);
        expect(namePoint(null, [], [], 0.5)).toBeNull();
        expect(namePoint(m, [], [], 0.5)).toEqual(m);
        // only examples: their normalized average
        const c = namePoint(null, [axis(1), axis(2)], [], 0.5)!;
        expect(c[1]).toBeCloseTo(Math.SQRT1_2, 6);
        expect(c[2]).toBeCloseTo(Math.SQRT1_2, 6);
        // strength 0 is the meaning, 1 the examples, 0.5 halfway
        expect(namePoint(m, [axis(1)], [], 0)!).toEqual(m);
        expect(namePoint(m, [axis(1)], [], 1)![1]).toBeCloseTo(1, 6);
        const half = namePoint(m, [axis(1)], [], 0.5)!;
        expect(half[0]).toBeCloseTo(Math.SQRT1_2, 6);
        expect(half[1]).toBeCloseTo(Math.SQRT1_2, 6);
    });
    it("not posts pull the examples' average away, by a quarter", () => {
        const c = namePoint(null, [axis(1)], [axis(2)], 1)!;
        const want = normalize(axis(1).map((x, i) => x - 0.25 * axis(2)[i]!));
        for (let i = 0; i < 4; i++) expect(c[i]).toBeCloseTo(want[i]!, 6);
        expect(c[2]).toBeLessThan(0);
    });
    it("a post carries a name when marked yes, never when marked no, else by the cut-off", () => {
        const p = axis(0);
        expect(carries("yes", null, null, 0.9)).toBe(true);
        expect(carries("no", p, p, 0)).toBe(false);
        expect(carries(null, null, p, 0)).toBe(false);
        expect(carries(null, p, null, 0)).toBe(false);
        expect(carries(null, vecOf({ 0: 0.6, 1: 0.8 }), p, 0.5)).toBe(true);
        expect(carries(null, vecOf({ 0: 0.4, 1: 0.9 }), p, 0.5)).toBe(false);
    });
    it("a query says a name as whole words, longest first, one span for one name", () => {
        const rows = [
            { id: "a", name_key: "lia", aliases: JSON.stringify(["lia-chan", "my model"]) },
            { id: "b", name_key: "capy", aliases: "[]" },
            { id: "c", name_key: "model", aliases: "[]" },
        ];
        expect(saidNames("Lia at the beach", rows).map((x) => x.row.id)).toEqual(["a"]);
        expect(saidNames("liam", rows)).toEqual([]);
        expect(saidNames("LIA-CHAN dancing", rows)).toEqual([{ row: rows[0], word: "lia-chan" }]);
        // "my model" is a's; "model" inside it is used up, so c is not said
        expect(saidNames("my model with capy", rows).map((x) => x.row.id)).toEqual(["a", "b"]);
        expect(saidNames("a model and capy", rows).map((x) => x.row.id)).toEqual(["c", "b"]);
    });
});

// ---- the routes (48.4) ------------------------------------------------------------------------------------------------

describe("the routes (48.4)", () => {
    it("create, list, change and delete a name; the meaning is embedded at once", async () => {
        const w = await setup();
        const c = await w.http("POST", "/library/names", lia({ aliases: ["Lia-Chan", "lia", "  my   model ", "lia-chan"], yes: ["lia2"] }));
        expect(c.status).toBe(201);
        expect(c.headers.get("cache-control")).toBe("no-store");
        const name = c.body.name;
        expect(name).toMatchObject({
            name: "Lia",
            aliases: ["lia-chan", "my model"],
            meaning: MEANING,
            strength: 0.5,
            cutoff: 0.5,
            enabled: true,
            yes: ["lia2"],
            no: [],
            embedded: true,
        });
        expect(name.id).toMatch(/^[A-Za-z0-9]{16}$/);
        // lia1, lia2 (also an example); half is under the cut-off
        expect(name.posts).toBe(2);
        expect(w.space.calls).toEqual([{ kind: "query", texts: [MEANING] }]);
        const row = w.one("SELECT * FROM search_names WHERE id = ?", name.id);
        expect(row).toMatchObject({ name_key: "lia", model: EMBED_MODEL, dims: EMBED_DIMS, meaning_hash: await meaningHash(MEANING) });
        expect(Array.from(decodeVector(row.vector)!)).toEqual(axis(0).map((x) => Math.fround(x)));
        // the point is the meaning and lia2 blended half and half
        const want = normalize(axis(0).map((x, i) => 0.5 * x + 0.5 * vecOf({ 0: 0.8, 1: 0.6 })[i]!));
        expect(decodeVector(row.point)![1]).toBeCloseTo(want[1]!, 5);

        w.tick(1);
        const second = await w.http("POST", "/library/names", { name: "capy", meaning: "a capybara" });
        expect(second.status).toBe(201);
        const list = await w.http("GET", "/library/names");
        expect(list.status).toBe(200);
        expect(list.body.names.map((x: any) => x.name)).toEqual(["Lia", "capy"]);

        // change: the cut-off, a mark (no on lia1, then yes off lia2), the meaning not re-embedded when unchanged
        w.tick(1000);
        const p = await w.http("PATCH", `/library/names/${name.id}`, { cutoff: 0.95, mark: [{ post_key: "lia1", kind: "no" }, { post_key: "lia2", kind: null }] });
        expect(p.status).toBe(200);
        expect(p.body.name).toMatchObject({ cutoff: 0.95, yes: [], no: ["lia1"], posts: 0, updated_at: T0 + 1001, created_at: T0 });
        expect(w.space.calls).toHaveLength(2);
        // yes/no lists replace the marks
        const r = await w.http("PATCH", `/library/names/${name.id}`, { yes: ["half", "far"], no: [] });
        expect(r.body.name).toMatchObject({ yes: expect.arrayContaining(["half", "far"]), no: [] });
        expect(w.one("SELECT COUNT(*) AS n FROM search_name_posts WHERE name_id = ?", name.id).n).toBe(2);

        expect(await w.http("DELETE", `/library/names/${name.id}`)).toMatchObject({ status: 200, body: { status: "success" } });
        expect(w.one("SELECT COUNT(*) AS n FROM search_name_posts").n).toBe(0);
        expect((await w.http("DELETE", `/library/names/${name.id}`)).body.error.code).toBe("error.names.not_found");
        expect((await w.http("PATCH", `/library/names/${name.id}`, { cutoff: 0.2 })).status).toBe(404);
        expect((await w.http("PATCH", "/library/names/bad", { cutoff: 0.2 })).status).toBe(404);
    });

    it("refuses input that does not fit 48.1 with 400 error.names.bad", async () => {
        const w = await setup();
        const bad = async (body: unknown) => {
            const r = await w.http("POST", "/library/names", body);
            expect(r.status).toBe(400);
            expect(r.body.error.code).toBe("error.names.bad");
        };
        await bad({ name: "Lia" });
        await bad({ meaning: MEANING });
        await bad(lia({ name: "   " }));
        await bad(lia({ name: "x".repeat(41) }));
        await bad(lia({ meaning: "x".repeat(301) }));
        await bad(lia({ aliases: Array.from({ length: 9 }, (_, i) => `a${i}`) }));
        await bad(lia({ aliases: [" "] }));
        await bad(lia({ strength: 1.5 }));
        await bad(lia({ cutoff: -0.1 }));
        await bad(lia({ yes: ["lia1"], no: ["lia1"] }));
        await bad(lia({ yes: Array.from({ length: 201 }, (_, i) => `p${i}`) }));
        expect(w.one("SELECT COUNT(*) AS n FROM search_names").n).toBe(0);
        // exactly 40 characters is fine
        expect((await w.http("POST", "/library/names", lia({ name: "x".repeat(40) }))).status).toBe(201);
    });

    it("words are unique across names: 409 error.names.taken with the word", async () => {
        const w = await setup();
        const a = (await w.http("POST", "/library/names", lia())).body.name;
        expect(await w.http("POST", "/library/names", { name: "LIA", meaning: "x" })).toMatchObject({ status: 409, body: { error: { code: "error.names.taken" }, word: "lia" } });
        expect(await w.http("POST", "/library/names", { name: "Mia", meaning: "x", aliases: ["My  Model"] })).toMatchObject({ status: 409, body: { word: "my model" } });
        const b = (await w.http("POST", "/library/names", { name: "Mia", meaning: "x" })).body.name;
        expect((await w.http("PATCH", `/library/names/${b.id}`, { aliases: ["lia-chan"] })).body.word).toBe("lia-chan");
        // a name may keep its own words
        expect((await w.http("PATCH", `/library/names/${a.id}`, { name: "lia", aliases: ["my model"] })).status).toBe(200);
    });

    it(`at most ${NAMES_MAX} names (409 error.names.too_many) and 200 marks per name`, async () => {
        const w = await setup();
        for (let i = 0; i < NAMES_MAX; i++) {
            w.db.raw
                .prepare("INSERT INTO search_names (id, name, name_key, meaning, created_at, updated_at) VALUES (?, ?, ?, 'm', 1, 1)")
                .run(`N${String(i).padStart(15, "0")}`, `n${i}`, `n${i}`);
        }
        expect(await w.http("POST", "/library/names", lia())).toMatchObject({ status: 409, body: { error: { code: "error.names.too_many" } } });
        w.db.raw.prepare("DELETE FROM search_names WHERE id = ?").run("N000000000000000");
        const id = (await w.http("POST", "/library/names", lia({ yes: Array.from({ length: 200 }, (_, i) => `p${i}`) }))).body.name.id;
        expect(w.one("SELECT COUNT(*) AS n FROM search_name_posts WHERE name_id = ?", id).n).toBe(200);
        expect((await w.http("PATCH", `/library/names/${id}`, { mark: [{ post_key: "one-more", kind: "no" }] })).status).toBe(400);
        expect((await w.http("PATCH", `/library/names/${id}`, { mark: Array.from({ length: 51 }, (_, i) => ({ post_key: `p${i}`, kind: null })) })).status).toBe(400);
    });

    it("a Space that cannot answer: the save succeeds with embedded false and the point from the examples; the cron embeds it", async () => {
        const w = await setup();
        w.space.down = true;
        const r = await saveName(w.d, null, lia({ yes: ["lia2"] }));
        expect(r.status).toBe(201);
        const name = (r.body as any).name;
        expect(name.embedded).toBe(false);
        const row = w.one("SELECT * FROM search_names WHERE id = ?", name.id);
        expect(row).toMatchObject({ vector: null, meaning_hash: null, model: null });
        expect(Array.from(decodeVector(row.point)!)).toEqual(vecOf({ 0: 0.8, 1: 0.6 }).map((x) => Math.fround(x)));
        // a name without a meaning vector or examples has no point
        w.tick(1);
        const bare = (await saveName(w.d, null, { name: "capy", meaning: "a capybara" })).body as any;
        expect(w.one("SELECT point FROM search_names WHERE id = ?", bare.name.id).point).toBeNull();

        expect(await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).toEqual({ embedded: 0, points: 0, unavailable: true });
        w.space.down = false;
        w.space.calls = [];
        expect(await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).toEqual({ embedded: 2, points: 2, unavailable: false });
        // one batch call for both meanings
        expect(w.space.calls).toEqual([{ kind: "query", texts: [MEANING, "a capybara"] }]);
        expect((await w.http("GET", "/library/names")).body.names.map((x: any) => x.embedded)).toEqual([true, true]);
        // nothing changed: nothing written, no Space call
        w.space.calls = [];
        expect(await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).toEqual({ embedded: 0, points: 0, unavailable: false });
        expect(w.space.calls).toEqual([]);
        // an example indexed since: the point moves on the next run
        w.addPost("late", "late.mp4", null);
        await saveName(w.d, name.id, { mark: [{ post_key: "late", kind: "yes" }] });
        w.db.raw.prepare("INSERT INTO media_embeddings (post_key, model, dims, vector, input_hash, embedded_at) VALUES ('late', ?, ?, ?, 'h', 1)").run(EMBED_MODEL, EMBED_DIMS, encodeVector(axis(5)));
        expect((await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).points).toBe(1);
        // a meaning edited behind the vector's back is embedded again
        w.db.raw.prepare("UPDATE search_names SET meaning = 'a dog' WHERE id = ?").run(bare.name.id);
        expect((await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).embedded).toBe(1);
    });

    it("the preview: marked posts first, then by score, cut to limit, each with its post; nothing saved", async () => {
        const w = await setup();
        const r = await w.http("POST", "/library/names/preview", { meaning: MEANING, no: ["lia2"], yes: ["fresh"] });
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ status: "success", embedded: true, indexed: 4 });
        expect(r.body.posts.map((p: any) => [p.post_key, p.mark, p.carries])).toEqual([
            ["fresh", "yes", true],
            ["lia2", "no", false],
            ["lia1", null, true],
            ["half", null, false],
            ["far", null, false],
        ]);
        expect(r.body.posts[0].score).toBe(1);
        expect(r.body.carries).toBe(2);
        expect(r.body.posts[2].post).toMatchObject({ id: "lia1", title: "IMG_0001.mp4" });
        expect(r.body.posts[2].post.files).toHaveLength(1);
        expect(w.one("SELECT COUNT(*) AS n FROM search_names").n).toBe(0);
        // the meaning is cached: a slider change costs no Space call
        const calls = w.space.calls.length;
        const r2 = await w.http("POST", "/library/names/preview", { meaning: MEANING, cutoff: 0.3, limit: 2 });
        expect(w.space.calls.length).toBe(calls);
        expect(r2.body.posts.map((p: any) => p.post_key)).toEqual(["lia1", "lia2"]);
        expect(r2.body.carries).toBe(3);
        // a saved name: missing fields from it
        const id = (await w.http("POST", "/library/names", lia({ yes: ["far"] }))).body.name.id;
        const r3 = await w.http("POST", "/library/names/preview", { id, strength: 0 });
        expect(r3.body.posts[0]).toMatchObject({ post_key: "far", mark: "yes", carries: true });
        expect(r3.body.carries).toBe(3);
        expect((await w.http("POST", "/library/names/preview", {})).status).toBe(400);
        expect((await w.http("POST", "/library/names/preview", { id: "AbCdEfGh12345678" })).status).toBe(404);
        expect((await w.http("POST", "/library/names/preview", { meaning: MEANING, limit: 101 })).status).toBe(400);
        // the Space cannot answer a new meaning: embedded false, examples only
        w.space.down = true;
        const r4 = (await previewName(w.d, { meaning: "something new", yes: ["lia1"] })).body as any;
        expect(r4).toMatchObject({ embedded: false, carries: 2 });
    });

    it("one post's names: carried or marked, best first", async () => {
        const w = await setup();
        const a = (await w.http("POST", "/library/names", lia())).body.name;
        const b = (await w.http("POST", "/library/names", { name: "dog", meaning: "a dog", no: ["lia1"] })).body.name;
        await w.http("POST", "/library/names", { name: "off", meaning: MEANING.toUpperCase(), enabled: false, yes: ["lia1"] });
        const r = await w.http("GET", "/library/names/post?key=lia1");
        expect(r.status).toBe(200);
        expect(r.body.names).toEqual([
            { id: a.id, name: "Lia", score: 1, mark: null, carries: true },
            { id: b.id, name: "dog", score: 0, mark: "no", carries: false },
        ]);
        expect((await w.http("GET", "/library/names/post?key=far")).body.names).toEqual([{ id: b.id, name: "dog", score: 1, mark: null, carries: true }]);
        expect((await w.http("GET", "/library/names/post")).status).toBe(400);
    });

    it("features.names says whether 0031 is applied", async () => {
        const w = await setup();
        expect(((await capabilities(w.app, "missing", undefined)).body as any).features.names).toBe(true);
    });
});

// ---- search (48.3) ---------------------------------------------------------------------------------------------------

describe("GET /library/search with names (48.3)", () => {
    it("a query that says a name embeds its meaning, mixes its point, and the posts that carry it rank first with the bonus", async () => {
        const w = await setup();
        const id = (await w.http("POST", "/library/names", lia({ yes: ["fresh"] }))).body.name.id;
        w.space.calls = [];
        const r = await w.search("lia");
        expect(r.status).toBe(200);
        const body = r.body as any;
        expect(w.space.calls).toEqual([{ kind: "query", texts: [`lia (Lia: ${MEANING})`] }]);
        expect(body.names).toEqual([{ id, name: "Lia" }]);
        const ids = body.posts.map((p: any) => p.id);
        expect(ids.slice(0, 3).sort()).toEqual(["fresh", "lia1", "lia2"]);
        for (const p of body.posts) {
            if (["lia1", "lia2", "fresh"].includes(p.id)) expect(p.why[0]).toBe("Lia");
            else expect(p.why).not.toContain("Lia");
        }
        // the full bonus for a query that is only the name: lia1 = cos(qv, axis 0) + 0.3
        const lia1 = body.posts.find((p: any) => p.id === "lia1");
        expect(lia1.score).toBeCloseTo(Math.SQRT1_2 + TEXT_MATCH_BONUS, 3);
        // fresh has no vector: the bonus alone
        expect(body.posts.find((p: any) => p.id === "fresh").score).toBeCloseTo(TEXT_MATCH_BONUS, 4);

        // names=0: the query as typed, no names
        w.space.calls = [];
        const off = (await w.search("lia", "&names=0")).body as any;
        expect(w.space.calls).toEqual([{ kind: "query", texts: ["lia"] }]);
        expect(off.names).toEqual([]);
        expect(off.posts.map((p: any) => p.id)).not.toContain("fresh");
        for (const p of off.posts) expect(p.why).not.toContain("Lia");

        // a name turned off is not said
        await w.http("PATCH", `/library/names/${id}`, { enabled: false });
        expect(((await w.search("lia")).body as any).names).toEqual([]);
    });

    it("the bonus is the share of the query's words that are the name's, and never adds past one TEXT_MATCH_BONUS", async () => {
        const w = await setup();
        await w.http("POST", "/library/names", lia({ yes: ["lia1"] }));
        const a = await applyNames(w.d.db, "lia dance");
        expect(a.text).toBe(`lia dance (Lia: ${MEANING})`);
        expect(a.bonus("lia1", axis(0))).toBeCloseTo(TEXT_MATCH_BONUS / 2, 6);
        expect(a.bonus("far", axis(2))).toBe(0);
        expect(a.carried("lia1")).toEqual(["Lia"]);
        expect(a.carried("far")).toEqual([]);
        expect((await applyNames(w.d.db, "my model")).bonus("lia1", null)).toBeCloseTo(TEXT_MATCH_BONUS, 6);
        expect((await applyNames(w.d.db, "lia", false)).said).toEqual([]);
        // a post whose title holds the query and that carries the name: one bonus, not two
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('lia1', 'lia', 'k', 1)").run();
        const r = await searchPosts({ db: w.d.db, client: w.space, mediaBaseUrl: MEDIA }, "lia", 10);
        if (!r.ok) throw new Error("search failed");
        const hit = r.hits.find((h) => h.post_key === "lia1")!;
        expect(hit.score - dot(r.queryVector!, axis(0))).toBeCloseTo(TEXT_MATCH_BONUS, 5);
        expect(r.names.said.map((s) => s.name)).toEqual(["Lia"]);
    });

    it("the name-match fallback counts a post that carries a said name as holding its words", async () => {
        const w = await setup();
        await w.http("POST", "/library/names", lia({ yes: ["fresh"], no: ["lia2"] }));
        w.space.down = true;
        const body = (await w.search("lia")).body as any;
        expect(body.fallback).toBe("text");
        expect(body.posts.map((p: any) => p.id).sort()).toEqual(["fresh", "lia1"]);
        expect(body.posts[0].why[0]).toBe("Lia");
        const off = (await w.search("lia", "&names=0")).body as any;
        expect(off.posts).toEqual([]);
    });

    it("hidden posts never carry a name: not in search, the preview, the counts or one post's names", async () => {
        const w = await setup();
        w.hide("lia1");
        w.hide("fresh");
        const name = (await w.http("POST", "/library/names", lia({ yes: ["fresh"] }))).body.name;
        expect(name.posts).toBe(1);
        const body = (await w.search("lia")).body as any;
        expect(body.posts.map((p: any) => p.id)).not.toContain("lia1");
        expect(body.posts.map((p: any) => p.id)).not.toContain("fresh");
        const pv = await w.http("POST", "/library/names/preview", { id: name.id });
        expect(pv.body.posts.map((p: any) => p.post_key)).toEqual(["lia2", "half", "far"]);
        expect(pv.body).toMatchObject({ carries: 1, indexed: 3 });
        expect((await w.http("GET", "/library/names/post?key=lia1")).body.names).toEqual([]);
        expect((await w.http("GET", "/library/names/post?key=fresh")).body.names).toEqual([{ id: name.id, name: "Lia", score: null, mark: "yes", carries: false }]);
    });

    it("a query that says no name is searched exactly as before", async () => {
        const w = await setup();
        await w.http("POST", "/library/names", lia());
        w.space.calls = [];
        const body = (await w.search("liam")).body as any;
        expect(w.space.calls).toEqual([{ kind: "query", texts: ["liam"] }]);
        expect(body.names).toEqual([]);
    });
});

// ---- the chat (48.5) -------------------------------------------------------------------------------------------------

class MemoryPending implements PendingPort {
    cards = new Map<string, PendingConfirm>();
    async put(thread: string, rec: PendingConfirm) {
        this.cards.set(thread, rec);
    }
    async take(thread: string, id: string) {
        const rec = this.cards.get(thread);
        if (!rec || rec.id !== id) return null;
        this.cards.delete(thread);
        return rec;
    }
    async drop(thread: string) {
        this.cards.delete(thread);
    }
}

describe("the chat and MCP calls (48.5)", () => {
    const THREAD = "Thread0000000048";
    async function chat() {
        const w = await setup();
        const container = {
            async fetch(): Promise<Response> {
                throw new Error("the container must not be reached");
            },
        };
        const edge = { now: () => T0, sleep: async () => {}, captioner: null, waitUntil: () => {} };
        const base = opBase(w.env, container, edge as any, REGISTRY, { stageRoom: null as any, stageEmbed: null });
        const cards = new MemoryPending();
        const legacyFor = (collect: { look: string[]; show: string[] }) => chatTools({ db: w.d.db, mediaBaseUrl: MEDIA, embed: w.space }, collect);
        const call = (name: string, ...args: unknown[]) => {
            const collect = { look: [] as string[], show: [] as string[] };
            return chatToolbox(REGISTRY, base, { threadId: THREAD, messageId: null, collect, legacy: legacyFor(collect), flags: { search: true }, pending: cards }).tools[name]!(...args) as Promise<any>;
        };
        const confirm = async () => {
            const rec = cards.cards.get(THREAD)!;
            cards.cards.delete(THREAD);
            const collect = { look: [] as string[], show: [] as string[] };
            return (await runConfirmed(REGISTRY, base, THREAD, rec, legacyFor(collect), collect)) as { result: any };
        };
        return { ...w, call, cards, confirm };
    }

    it("names.set asks first, then teaches; names.list and names.preview are free; names.delete asks", async () => {
        const w = await chat();
        const set = await w.call("names.set", { name: "Lia", meaning: MEANING, yes: ["lia2"] });
        expect(set.pending_confirm).toMatchObject({ summary: `teach search “Lia”: ${MEANING}` });
        expect(w.one("SELECT COUNT(*) AS n FROM search_names").n).toBe(0);
        const done = (await w.confirm()).result;
        expect(done.name).toMatchObject({ name: "Lia", yes: 1, no: 0, posts: 2, embedded: true });
        const list = await w.call("names.list");
        expect(list.names).toHaveLength(1);
        expect(list.names[0]).toMatchObject({ id: done.name.id, yes: 1 });
        const pv = await w.call("names.preview", { id: done.name.id });
        expect(pv).toMatchObject({ embedded: true, carries: 2, indexed: 4 });
        expect(pv.posts[0]).toEqual({ id: "lia2", title: "IMG_0002.mp4", score: expect.any(Number), mark: "yes", carries: true });
        const del = await w.call("names.delete", done.name.id);
        expect(del.pending_confirm).toMatchObject({ summary: "delete the name “Lia”" });
        expect((await w.confirm()).result).toEqual({ deleted: done.name.id });
        expect(w.one("SELECT COUNT(*) AS n FROM search_names").n).toBe(0);
    });

    it("the MCP serves them as tools while search is on", () => {
        const tools = mcpToolList(REGISTRY, { search: true, mcp: true } as any).map((t: { name: string }) => t.name);
        for (const t of ["names_list", "names_preview", "names_set", "names_delete"]) expect(tools).toContain(t);
    });
});

// ---- without migration 0031 ------------------------------------------------------------------------------------------

describe("without migration 0031", () => {
    it("the routes answer 503, search behaves as before with names: [], features.names is false, the cron does nothing", async () => {
        const w = world();
        current = w;
        w.db.raw.exec("DROP TABLE search_name_posts; DROP TABLE search_names;");
        w.db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("k1", "test", KEY_HASH, "0b5f2c3e", 1);
        w.addPost("lia1", "IMG_0001.mp4", axis(0));
        const generic = { status: "error", error: { code: "error.api.generic" } };
        expect(await w.http("GET", "/library/names")).toMatchObject({ status: 503, body: generic });
        expect(await w.http("POST", "/library/names", lia())).toMatchObject({ status: 503, body: generic });
        expect(await w.http("POST", "/library/names/preview", { meaning: MEANING })).toMatchObject({ status: 503, body: generic });
        expect(await w.http("GET", "/library/names/post?key=lia1")).toMatchObject({ status: 503, body: generic });
        expect(await w.http("PATCH", "/library/names/AbCdEfGh12345678", { cutoff: 0.1 })).toMatchObject({ status: 503, body: generic });
        expect(await w.http("DELETE", "/library/names/AbCdEfGh12345678")).toMatchObject({ status: 503, body: generic });
        w.space.calls = [];
        const body = (await w.search("lia")).body as any;
        expect(body).toMatchObject({ status: "success", names: [] });
        expect(body.posts.map((p: any) => p.id)).toEqual(["lia1"]);
        expect(w.space.calls).toEqual([{ kind: "query", texts: ["lia"] }]);
        expect(((await capabilities(w.app, "missing", undefined)).body as any).features.names).toBe(false);
        expect(await refreshNames({ db: w.d.db, client: w.space, now: w.d.now })).toEqual({ embedded: 0, points: 0, unavailable: false });
    });
});
