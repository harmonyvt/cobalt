// 7TV search and save (APP-API-CONTRACT.md section 20). No network: a fake fetch
// returns the live catJAM image list captured 2026-10-14.
import { describe, expect, it } from "vitest";
import { libraryPostDelete, type AppDeps } from "../src/app-routes";
import { pickWebp, previewWebp, saveEmote, searchEmotes, type EmoteImage } from "../src/emotes";
import { decide, type GateRequest } from "../src/gate";
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

    it("asks for a key, then searches", () => {
        expect(decide(req(null), { corsUrl: "https://cobalt.capybaraharmony.com", now: 0 })).toEqual({
            action: "reject",
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
        expect(decide(req(`Api-Key ${KEY}`), { corsUrl: "https://cobalt.capybaraharmony.com", now: 0 })).toEqual({
            action: "lookup",
            key: KEY,
            then: "emotes_search",
        });
        expect(decide(req(`Api-Key ${KEY}`, "/emotes", "POST"), { corsUrl: "https://cobalt.capybaraharmony.com", now: 0 })).toEqual({
            action: "lookup",
            key: KEY,
            then: "emotes_save",
        });
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
