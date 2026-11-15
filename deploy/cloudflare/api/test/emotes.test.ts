// 7TV search and save (APP-API-CONTRACT.md section 20). No network: a fake fetch
// returns the live catJAM image list captured 2026-10-14.
import { describe, expect, it } from "vitest";
import { libraryPostDelete, type AppDeps } from "../src/app-routes";
import { findManyEmotes, pickWebp, previewWebp, saveEmote, searchEmotes, type EmoteCache, type EmoteImage } from "../src/emotes";
import type { GateRequest } from "../src/gate";
import { dispatch as decide } from "./dispatch";
import { REGISTRY } from "../src/registry/index";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const CAT = "01F6MQ33FG000FFJ97ZB8MWV52";
const ZERO = "01ZW0000000000000000000000";
const GQL = "https://7tv.io/v4/gql";

const catjam: EmoteImage[] = [
    { url: `https://cdn.7tv.app/emote/${CAT}/4x_static.webp`, mime: "image/webp", size: 2238, scale: 4, width: 128, height: 128, frameCount: 1 },
    { url: `https://cdn.7tv.app/emote/${CAT}/4x.gif`, mime: "image/gif", size: 1050253, scale: 4, width: 128, height: 128, frameCount: 158 },
    { url: `https://cdn.7tv.app/emote/${CAT}/4x.avif`, mime: "image/avif", size: 226038, scale: 4, width: 128, height: 128, frameCount: 158 },
    { url: `https://cdn.7tv.app/emote/${CAT}/2x.webp`, mime: "image/webp", size: 199384, scale: 2, width: 64, height: 64, frameCount: 158 },
    { url: `https://cdn.7tv.app/emote/${CAT}/4x.webp`, mime: "image/webp", size: 346368, scale: 4, width: 128, height: 128, frameCount: 158 },
    { url: `https://cdn.7tv.app/emote/${CAT}/3x.webp`, mime: "image/webp", size: 316206, scale: 3, width: 96, height: 96, frameCount: 158 },
];

const emote = (over: Record<string, unknown> = {}) => ({
    id: CAT,
    defaultName: "catJAM",
    deleted: false,
    flags: { animated: true, defaultZeroWidth: false, private: false },
    images: catjam,
    ...over,
});

const jsonRes = (body: unknown, status = 200): Response =>
    ({
        ok: status >= 200 && status < 300,
        status,
        url: GQL,
        json: async () => body,
        arrayBuffer: async () => new ArrayBuffer(0),
    }) as unknown as Response;

const bytesRes = (n: number, url: string): Response => {
    const buf = new ArrayBuffer(n);
    new Uint8Array(buf).fill(7);
    return {
        ok: true,
        status: 200,
        url,
        json: async () => ({}),
        arrayBuffer: async () => buf,
    } as unknown as Response;
};

function world() {
    const db: FakeD1 = createBatchD1();
    const media = new MemoryMedia();
    const d: AppDeps = {
        db: db as unknown as D1Database,
        originals: new MemoryOriginals(),
        media,
        mediaBaseUrl: "https://media.capybaraharmony.com/",
        apiUrl: "https://api.capybaraharmony.com/",
        webUrl: "https://cobalt.capybaraharmony.com",
        now: () => 1_800_000_000_000,
        fixedLength: () => {
            throw new Error("unused");
        },
        adopt: async () => {
            throw new Error("unused");
        },
    };
    return { db, media, d };
}

describe("webp choice", () => {
    it("keeps the largest animated webp and previews at 2x", () => {
        expect(pickWebp(catjam, true)?.url).toMatch(/\/4x\.webp$/);
        expect(previewWebp(catjam, true)?.url).toMatch(/\/2x\.webp$/);
    });

    it("steps down a scale when the largest file is over 15 MB", () => {
        const big = catjam.map((i) => (i.url.endsWith("/4x.webp") ? { ...i, size: 15_000_001 } : i));
        expect(pickWebp(big, true)?.url).toMatch(/\/3x\.webp$/);
    });

    it("takes the largest still webp and ignores a still frame of an animation", () => {
        const still: EmoteImage[] = [
            { url: "https://cdn.7tv.app/emote/STILL000000000000000001/1x.webp", mime: "image/webp", size: 100, scale: 1, width: 32, height: 32, frameCount: 1 },
            { url: "https://cdn.7tv.app/emote/STILL000000000000000001/3x.webp", mime: "image/webp", size: 200, scale: 3, width: 96, height: 96, frameCount: 1 },
        ];
        expect(pickWebp(still, false)?.url).toMatch(/\/3x\.webp$/);
        expect(pickWebp(catjam.filter((i) => i.frameCount === 1), true)).toBeNull();
    });
});

describe("GET /emotes", () => {
    const req = (authorization: string | null, pathname = "/emotes", method = "GET"): GateRequest => ({
        method,
        pathname,
        searchParams: new URLSearchParams(),
        origin: null,
        authorization,
    });

    it("is an op: keyed or the library service; other methods are the gate's 404", () => {
        expect(REGISTRY.match("GET", "/emotes")).toMatchObject({ op: { name: "emotes_http.search", auth: "key_or_service" } });
        expect(REGISTRY.match("POST", "/emotes")).toMatchObject({ op: { name: "emotes_http.save", auth: "key_or_service" } });
        expect(REGISTRY.match("PUT", "/emotes")).toBeNull();
        expect(decide(req(`Api-Key ${KEY}`, "/emotes", "PUT"), { corsUrl: "https://cobalt.capybaraharmony.com", now: 0 })).toEqual({ action: "reject", status: 404, errorCode: undefined });
    });

    it("rejects a blank query and hides a zero-width emote", async () => {
        const { d } = world();
        const blank = await searchEmotes(d, new URLSearchParams("q="));
        expect(blank).toMatchObject({ status: 400, body: { error: { code: "error.emote.query" } } });

        const fetchImpl = async () =>
            jsonRes({
                data: {
                    emotes: {
                        search: {
                            items: [
                                emote(),
                                emote({
                                    id: ZERO,
                                    defaultName: "wide",
                                    flags: { animated: false, defaultZeroWidth: true, private: false },
                                    images: catjam,
                                }),
                            ],
                        },
                    },
                },
            });
        const found = await searchEmotes(d, new URLSearchParams("q=cat"), fetchImpl);
        expect(found.status).toBe(200);
        const items = (found.body as { items: { id: string; name: string; preview_url: string; file_url: string; library_id: string | null; library_url: string | null }[] }).items;
        expect(items[0].library_url).toBeNull();
        expect(items.map((i) => i.id)).toEqual([CAT]);
        expect(items[0].name).toBe("catJAM");
        expect(items[0].preview_url).toMatch(/\/2x\.webp$/);
        expect(items[0].file_url).toMatch(/\/4x\.webp$/);
        expect(items[0].library_id).toBeNull();
    });

    it("browses a sort without a name, pages, and asks 7TV for the right SortBy", async () => {
        const { d } = world();
        const sent: { query: string; variables: Record<string, unknown> }[] = [];
        const fetchImpl = async (_url: unknown, init?: RequestInit) => {
            sent.push(JSON.parse(String(init?.body)));
            return jsonRes({ data: { emotes: { search: { pageCount: 3, items: [emote()] } } } });
        };
        const daily = await searchEmotes(d, new URLSearchParams("sort=trending_daily&page=2"), fetchImpl as typeof fetch);
        expect(daily.status).toBe(200);
        expect(daily.body).toMatchObject({ sort: "trending_daily", page: 2, has_more: true, items: [{ id: CAT, width: 128, height: 128 }] });
        expect(sent[0].variables).toEqual({ query: null, sort: { sortBy: "TRENDING_DAILY", order: "DESCENDING" }, page: 2, perPage: 24 });

        const last = await searchEmotes(d, new URLSearchParams("q=cat&sort=top_monthly&page=3"), fetchImpl as typeof fetch);
        expect(last.body).toMatchObject({ sort: "top_monthly", page: 3, has_more: false });
        expect(sent[1].variables).toMatchObject({ query: "cat", sort: { sortBy: "TOP_MONTHLY" } });

        // The old search (q only) is still top of all time.
        const old = await searchEmotes(d, new URLSearchParams("q=cat"), fetchImpl as typeof fetch);
        expect(old.body).toMatchObject({ sort: "top", page: 1 });
        expect(sent[2].variables).toMatchObject({ sort: { sortBy: "TOP_ALL_TIME" } });

        for (const bad of ["sort=hot", "sort=top&page=0", "sort=top&page=51", "sort=top&page=1.5", `sort=top&q=${"x".repeat(65)}`]) {
            expect(await searchEmotes(d, new URLSearchParams(bad), fetchImpl as typeof fetch)).toMatchObject({
                status: 400,
                body: { error: { code: "error.emote.query" } },
            });
        }
        expect(sent).toHaveLength(3);
    });

    it("lists 7TV's global set", async () => {
        const { d } = world();
        const sent: { query: string; variables: Record<string, unknown> }[] = [];
        const fetchImpl = async (_url: unknown, init?: RequestInit) => {
            sent.push(JSON.parse(String(init?.body)));
            return jsonRes({ data: { emoteSets: { global: { emotes: { pageCount: 1, items: [{ alias: "catJAM", emote: emote() }] } } } } });
        };
        const r = await searchEmotes(d, new URLSearchParams("sort=global"), fetchImpl as typeof fetch);
        expect(r.body).toMatchObject({ sort: "global", page: 1, has_more: false, items: [{ id: CAT, name: "catJAM" }] });
        expect(sent[0].query).toContain("global");
        expect(sent[0].variables).toEqual({ query: null, page: 1, perPage: 24 });
    });

    it("is 502 when 7TV does not answer", async () => {
        const { d } = world();
        const r = await searchEmotes(d, new URLSearchParams("q=cat"), async () => {
            throw new Error("down");
        });
        expect(r).toMatchObject({ status: 502, body: { error: { code: "error.emote.unavailable" } } });
    });
});

describe("POST /emotes", () => {
    const saveFetch = (fileUrl = `https://cdn.7tv.app/emote/${CAT}/4x.webp`, bytes = 4) => {
        const calls: string[] = [];
        const fetchImpl = async (input: RequestInfo | URL, init?: RequestInit) => {
            const url = String(input);
            calls.push(url);
            if (url === GQL) {
                const asked = JSON.parse(String(init?.body)) as { query: string };
                if (asked.query.includes("search(")) {
                    return jsonRes({ data: { emotes: { search: { items: [emote()] } } } });
                }
                return jsonRes({ data: { emotes: { emote: emote() } } });
            }
            return bytesRes(bytes, fileUrl);
        };
        return { calls, fetchImpl };
    };

    const post = (id: unknown) => new Request("https://api.capybaraharmony.com/emotes", { method: "POST", body: JSON.stringify({ id }) });

    it("stores the largest animated webp once, then deletes the post", async () => {
        const { d, db, media } = world();
        const { fetchImpl } = saveFetch();
        const first = await saveEmote(d, post(CAT), "key-row-1", fetchImpl);
        expect(first.status).toBe(201);
        const body = first.body as { id: string; source: string; content_type: string; link: string; emote_id: string; name: string };
        expect(body.source).toBe("emote");
        expect(body.content_type).toBe("image/webp");
        expect(body.link).toBe(`7tv:${CAT}`);
        expect(body.emote_id).toBe(CAT);
        expect(body.name).toBe("catJAM");
        expect(media.puts).toHaveLength(1);
        expect(media.puts[0].key).toMatch(/^[A-Za-z0-9]{10}\.webp$/);
        expect(media.puts[0].value).toBeInstanceOf(ArrayBuffer);

        const row = db.raw.prepare("SELECT source, content_type, link, bucket FROM media_items WHERE id = ?").get(body.id) as {
            source: string;
            content_type: string;
            link: string;
            bucket: string;
        };
        expect(row).toMatchObject({ source: "emote", content_type: "image/webp", link: `7tv:${CAT}`, bucket: "media" });

        const again = await saveEmote(d, post(CAT), "key-row-1", async () => {
            throw new Error("must not download twice");
        });
        expect(again.status).toBe(200);
        expect((again.body as { id: string }).id).toBe(body.id);
        expect(media.puts).toHaveLength(1);

        const listed = await searchEmotes(d, new URLSearchParams("q=cat"), saveFetch().fetchImpl);
        const items = (listed.body as { items: { library_id: string | null; library_url: string | null }[] }).items;
        expect(items[0].library_id).toBe(body.id);
        expect(items[0].library_url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.webp$/);

        const gone = await libraryPostDelete(d, body.id);
        expect(gone.status).toBe(200);
        const live = db.raw.prepare("SELECT deleted_at FROM media_items WHERE id = ?").get(body.id) as { deleted_at: number };
        expect(live.deleted_at).toBeTypeOf("number");
        expect(media.objects.size).toBe(0);
    });

    it("refuses a bad id, an empty file, a non-cdn download, and a silent 7TV", async () => {
        const { d } = world();
        expect((await saveEmote(d, post("nope"), "key-row-1")).status).toBe(400);

        const empty = await saveEmote(d, post(CAT), "key-row-1", saveFetch(`https://cdn.7tv.app/emote/${CAT}/4x.webp`, 0).fetchImpl);
        expect(empty).toMatchObject({ status: 400, body: { error: { code: "error.emote.too_big" } } });

        const hijack = await saveEmote(d, post(CAT), "key-row-1", saveFetch("https://evil.example/4x.webp", 4).fetchImpl);
        expect(hijack).toMatchObject({ status: 502, body: { error: { code: "error.emote.unavailable" } } });

        const down = await saveEmote(d, post(CAT), "key-row-1", async () => {
            throw new Error("down");
        });
        expect(down).toMatchObject({ status: 502, body: { error: { code: "error.emote.unavailable" } } });
    });
});

// ---- fewer 7TV requests (section 62.5): the 24 h cache, the batch, Retry-After, the gate -------------------------------

class MemoryCache implements EmoteCache {
    store = new Map<string, string>();
    ttl = new Map<string, string | null>();
    async match(key: Request) {
        const v = this.store.get(key.url);
        return v === undefined ? undefined : new Response(v);
    }
    async put(key: Request, res: Response) {
        this.store.set(key.url, await res.text());
        this.ttl.set(key.url, res.headers.get("cache-control"));
    }
}

describe("fewer 7TV requests (62.5)", () => {
    const searchBody = (n = 1) => ({ data: { emotes: { search: { pageCount: 1, items: Array.from({ length: n }, () => emote()) } } } });

    it("a search is kept for a day: the second asks nobody and says cached", async () => {
        const { d } = world();
        const cache = new MemoryCache();
        let calls = 0;
        const fetchImpl = (async () => (calls++, jsonRes(searchBody()))) as unknown as typeof fetch;
        const dc = { ...d, emoteCache: cache };
        const a = await searchEmotes(dc, new URLSearchParams("q=Cat"), fetchImpl);
        const b = await searchEmotes(dc, new URLSearchParams("q=  cat "), fetchImpl);
        expect(calls).toBe(1);
        expect(a.body).not.toHaveProperty("cached");
        expect(b.body).toMatchObject({ cached: true, items: [{ id: CAT, library_id: null }] });
        expect([...cache.store.keys()]).toEqual(["https://emote-cache.internal/find?q=cat&sort=top&page=1"]);
    });

    it("findMany: the names not in the cache go out as one aliased request, in the asked order", async () => {
        const { d } = world();
        const cache = new MemoryCache();
        const dc = { ...d, emoteCache: cache };
        await searchEmotes(dc, new URLSearchParams("q=cat"), (async () => jsonRes(searchBody())) as unknown as typeof fetch);
        const sent: { query: string; variables: Record<string, unknown> }[] = [];
        const fetchImpl = (async (_u: string, init: RequestInit) => {
            sent.push(JSON.parse(String(init.body)));
            return jsonRes({ data: { s0: { search: { pageCount: 1, items: [emote({ defaultName: "dog" })] } }, s1: { search: { pageCount: 1, items: [] } } } });
        }) as unknown as typeof fetch;
        const r = await findManyEmotes(dc, ["dog", "cat", "nothing", "Dog"], undefined, fetchImpl);
        expect(r.status).toBe(200);
        expect(sent).toHaveLength(1);
        expect(sent[0]!.query).toMatch(/s0: emotes \{ search\(query: \$q0/);
        expect(sent[0]!.query).toMatch(/s1: emotes \{ search\(query: \$q1/);
        expect(sent[0]!.variables).toMatchObject({ q0: "dog", q1: "nothing" });
        const body = r.body as { sort: string; results: { q: string; cached: boolean; emotes: { name: string }[] }[] };
        expect(body.sort).toBe("top");
        expect(body.results.map((x) => [x.q, x.cached, x.emotes.length])).toEqual([
            ["dog", false, 1],
            ["cat", true, 1],
            ["nothing", false, 0],
            ["Dog", false, 1],
        ]);
        // over 20 names, or an empty one, is refused before any request
        expect((await findManyEmotes(dc, Array.from({ length: 21 }, (_, i) => `n${i}`), undefined, fetchImpl)).status).toBe(400);
        expect((await findManyEmotes(dc, [" "], undefined, fetchImpl)).status).toBe(400);
        expect((await findManyEmotes(dc, ["a"], "nope", fetchImpl)).status).toBe(400);
        expect(sent).toHaveLength(1);
    });

    it("a partial answer (GraphQL errors, a null alias) is answered but not cached; an empty one is kept 10 minutes", async () => {
        const { d } = world();
        const cache = new MemoryCache();
        const dc = { ...d, emoteCache: cache };
        // one search with errors beside its data
        const partial = (async () => jsonRes({ data: { emotes: { search: { pageCount: 1, items: [] } } }, errors: [{ message: "timeout" }] })) as unknown as typeof fetch;
        expect((await searchEmotes(dc, new URLSearchParams("q=cat"), partial)).status).toBe(200);
        expect(cache.store.size).toBe(0);
        // findMany: s0 answered, s1 null with an error -> nothing cached (the whole answer is partial)
        const many = (async () => jsonRes({ data: { s0: { search: { pageCount: 1, items: [emote()] } }, s1: null }, errors: [{ message: "s1 failed", path: ["s1"] }] })) as unknown as typeof fetch;
        const r = await findManyEmotes(dc, ["cat", "dog"], undefined, many);
        expect((r.body as { results: { q: string; emotes: unknown[] }[] }).results.map((x) => [x.q, x.emotes.length])).toEqual([
            ["cat", 1],
            ["dog", 0],
        ]);
        expect(cache.store.size).toBe(0);
        // a clean answer with no emotes: cached briefly; with emotes: a day
        const empty = (async () => jsonRes({ data: { s0: { search: { pageCount: 0, items: [] } }, s1: { search: { pageCount: 1, items: [emote()] } } } })) as unknown as typeof fetch;
        await findManyEmotes(dc, ["nothing", "cat"], undefined, empty);
        expect(Object.fromEntries([...cache.ttl].map(([k, v]) => [new URL(k).searchParams.get("q"), v]))).toEqual({ nothing: "public, max-age=600", cat: "public, max-age=86400" });
    });

    it("a 429 answers error.emote.rate_limited with 7TV's Retry-After, and slows the gate", async () => {
        const { d } = world();
        const gateCalls: string[] = [];
        const gate = { slot: async (k: string) => void gateCalls.push(`slot:${k}`), slow: async () => void gateCalls.push("slow") };
        const res429 = (h: string | null) => (async () => ({ ...jsonRes({}, 429), headers: new Headers(h ? { "retry-after": h } : {}) })) as unknown as typeof fetch;
        const dg = { ...d, sevenTvGate: gate };
        expect(await searchEmotes(dg, new URLSearchParams("q=cat"), res429("12"))).toEqual({ status: 429, body: { status: "error", error: { code: "error.emote.rate_limited", retry_after: 12 } } });
        expect(await findManyEmotes(dg, ["cat"], undefined, res429(null))).toEqual({ status: 429, body: { status: "error", error: { code: "error.emote.rate_limited" } } });
        expect(gateCalls).toEqual(["slot:read", "slow", "slot:read", "slow"]);
    });
});
