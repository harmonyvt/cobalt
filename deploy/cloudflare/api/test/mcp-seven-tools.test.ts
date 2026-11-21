// Section 63: the deep 7TV variant search, frames of 7TV emotes, and the signed download links of exports. No network:
// 7TV's GraphQL and CDN are fakes shaped like their live answers (checked 2026-11-16).
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { AppDeps } from "../src/app-routes";
import { deepVariants } from "../src/emotes";
import { compareCanvas, decodable, emoteFrames, emoteInfos, frameStrip, canvasWidth, type EmoteInfo } from "../src/emote-frames";
import { signDownloadToken, verifyDownloadToken, writeExport, EXPORT_KEEP_MS } from "../src/mcp-export";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const GQL = "https://7tv.io/v4/gql";
const fixture = (n: string) => new Uint8Array(readFileSync(new URL(`./fixtures/${n}`, import.meta.url)));
const id = (n: number) => `01HV${String(n).padStart(22, "0")}`;
const img = (eid: string, w: number, h: number, frames: number) => [
    { url: `https://cdn.7tv.app/emote/${eid}/4x.webp`, mime: "image/webp", size: 9000, scale: 4, width: w, height: h, frameCount: frames },
    { url: `https://cdn.7tv.app/emote/${eid}/4x.gif`, mime: "image/gif", size: 9000, scale: 4, width: w, height: h, frameCount: frames },
    { url: `https://cdn.7tv.app/emote/${eid}/4x.png`, mime: "image/png", size: 900, scale: 4, width: w, height: h, frameCount: 1 },
];
const emote = (n: number, name: string, animated = true, w = 216, h = 128) => ({ id: id(n), defaultName: name, deleted: false, flags: { animated, private: false, defaultZeroWidth: false }, images: img(id(n), w, h, animated ? 30 : 1) });

function deps(): AppDeps {
    return {
        db: createBatchD1() as unknown as D1Database,
        originals: new MemoryOriginals(),
        media: new MemoryMedia(),
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
}

describe("deep variant search (63.2)", () => {
    // 30 same-name uploads (2 pages of 24 exact), a fuzzy search with the festive one on its 3rd page, and seasonal searches
    const same = Array.from({ length: 30 }, (_, i) => emote(100 + i, i % 2 ? "lapeace" : "LaPeace", i !== 7, i === 9 ? 128 : 216, 128));
    const fuzzy = [...same, emote(200, "LaPeaceSmile"), emote(201, "Peace"), emote(202, "LaPeaceXmas"), emote(203, "LaPeaceXmas", false)];
    const seasonal = [emote(202, "LaPeaceXmas"), emote(204, "SantaLaPeace")];
    const BASE = emote(1, "LaPeace");
    const queries: string[] = [];
    const page = (list: unknown[], p: number) => ({ pageCount: Math.ceil(list.length / 24), items: list.slice((p - 1) * 24, p * 24) });
    const fetchFake = (async (url: string, init: RequestInit) => {
        expect(url).toBe(GQL);
        const { query, variables } = JSON.parse(String(init.body));
        queries.push(query);
        if (query.includes("emote(id: $id)")) return Response.json({ data: { emotes: { emote: BASE } } });
        const data: Record<string, unknown> = {};
        for (const m of query.matchAll(/(s\d+): emotes \{ search\(query: \$q\d+, sort: \$sort, (filters: \{ exactMatch: true \}, )?/g)) {
            const k = m[1]!.slice(1);
            const q = String(variables[`q${k}`]).toLowerCase();
            const list = m[2] ? same : q === "lapeace" ? fuzzy : seasonal.filter((e) => e.defaultName.toLowerCase().includes(q.replace(/ /g, "").replace("lapeace", "")) );
            data[m[1]!] = { search: page(list, variables[`p${k}`]) };
        }
        return Response.json({ data });
    }) as unknown as typeof fetch;

    it("finds every same-name upload across pages, the seasonal ones, and filters by the base's animation and shape", async () => {
        const r = (await deepVariants(deps(), { emote_id: id(1), season: "christmas" }, fetchFake)).body as any;
        expect(r.name).toBe("LaPeace");
        expect(r.base).toEqual({ emote_id: id(1), animated: true, width: 216, height: 128 });
        expect(r.words).toEqual(["xmas", "christmas", "santa", "winter", "snow", "festive"]);
        expect(r.pages_read).toMatchObject({ same_name: 2, contains: 2 });
        expect(r.complete).toBe(true);
        // 30 same-name + LaPeaceSmile + 2 LaPeaceXmas + SantaLaPeace
        expect(r.found).toBe(34);
        // a still one (#7, and the still Xmas) and a square one (#9) are dropped
        expect(r.dropped).toEqual({ animated: 2, size: 1 });
        expect(r.variants.filter((v: any) => v.match === "same_name")).toHaveLength(28);
        expect(r.variants.filter((v: any) => v.match === "seasonal").map((v: any) => [v.name, v.word])).toEqual([
            ["LaPeaceXmas", "xmas"],
            ["SantaLaPeace", "santa"],
        ]);
        expect(r.variants.at(-1)).toMatchObject({ name: "LaPeaceSmile", match: "contains", animated: true, page_url: `https://7tv.app/emotes/${id(200)}` });
        expect(r.variants.some((v: any) => v.emote_id === id(201))).toBe(false); // "Peace" does not contain the name
        // pages are fetched 10 to a request: a handful of 7TV calls for the whole search
        expect(queries.length).toBe(7); // base, 2 + 2 pages, 18 seasonal searches in 2
    });

    it("by name only there is no base to filter on; animated and size filters can be set", async () => {
        const r = (await deepVariants(deps(), { name: "LaPeace", animated: "no", max_pages: 1 }, fetchFake)).body as any;
        expect(r.base).toBeUndefined();
        expect(r.complete).toBe(false);
        expect(r.variants.every((v: any) => v.animated === false)).toBe(true);
        expect((await deepVariants(deps(), { name: "" }, fetchFake)).status).toBe(400);
    });
});

describe("frames of 7TV emotes (63.3)", () => {
    const anim: EmoteInfo = { id: id(1), name: "anim", animated: true, frames: 4, width: 40, height: 30, images: img(id(1), 40, 30, 4) };
    const fetchCdn = (bytes: Uint8Array) =>
        (async (url: string) => {
            expect(url).toBe(`https://cdn.7tv.app/emote/${id(1)}/4x.gif`);
            return new Response(bytes, { status: 200 });
        }) as unknown as typeof fetch;

    it("picks the GIF for an animated emote, the PNG for a still one", () => {
        expect(decodable(anim)?.mime).toBe("image/gif");
        expect(decodable({ ...anim, animated: false })?.mime).toBe("image/png");
        expect(decodable({ ...anim, images: [] })).toBeNull();
    });

    it("spreads frames over the loop and draws them as a labelled strip", async () => {
        const f = await emoteFrames({ fetch: fetchCdn(fixture("anim.gif")), now: () => 0 }, anim, 3);
        expect(f).toMatchObject({ source: "gif", count: 4, at: [0, 1, 2] });
        expect(f.frames).toHaveLength(3);
        const strip = frameStrip(f, 64);
        expect(strip.width).toBe(6 + 3 * 70);
        const bad = await emoteFrames({ fetch: (async () => new Response("no", { status: 404 })) as unknown as typeof fetch, now: () => 0 }, anim, 3);
        expect(bad).toMatchObject({ source: "none", frames: [], note: "7TV's CDN did not answer" });
    });

    it("reads many emotes' info in one aliased request, skipping deleted ones", async () => {
        const seen: string[] = [];
        const f = (async (_u: string, init: RequestInit) => {
            const { query } = JSON.parse(String(init.body));
            seen.push(query);
            return Response.json({ data: { emotes: { e0: emote(1, "a"), e1: { ...emote(2, "b"), deleted: true }, e2: null } } });
        }) as unknown as typeof fetch;
        const m = await emoteInfos({ fetch: f, now: () => 0 }, [id(1), id(2), id(3), id(1)]);
        expect([...m.keys()]).toEqual([id(1)]);
        expect(m.get(id(1))).toMatchObject({ name: "a", animated: true, frames: 30, width: 216 });
        expect(seen).toHaveLength(1);
        expect(seen[0]).toContain("e2: emote(id: $i2)");
    });

    it("lays out a compare canvas: 3 frames a side is 958 px wide, a failed side says why", async () => {
        const f = await emoteFrames({ fetch: fetchCdn(fixture("anim.gif")), now: () => 0 }, anim, 3);
        expect(canvasWidth(3)).toBe(958);
        const c = compareCanvas(
            [
                { n: 1, label: "LaPeace", left: { frames: f.frames, count: 4 }, right: { frames: [], count: 0, error: "no GIF" } },
                { n: 2, label: "catJAM", left: { frames: f.frames, count: 4 }, right: { frames: f.frames, count: 4 } },
            ],
            3,
        );
        expect([c.width, c.height]).toEqual([958, 30 + 2 * 138]);
        // the first frame's red square (anim.gif) lands in row 1, left side
        const px = (x: number, y: number) => [...c.data.subarray((y * c.width + x) * 4, (y * c.width + x) * 4 + 3)];
        expect(px(0, 0)).toEqual([72, 72, 72]);
    });
});

describe("exports and their download links (63.6)", () => {
    const SECRET = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
    const NOW = 1_800_000_000_000;

    it("signs a link that only opens its own file, for its key, until it expires", async () => {
        const t = await signDownloadToken(SECRET, { k: "key-1", f: "exports/abc/x.json", n: "x.json", e: NOW + 1000 });
        expect(await verifyDownloadToken(SECRET, t, NOW)).toEqual({ k: "key-1", f: "exports/abc/x.json", n: "x.json", e: NOW + 1000 });
        expect(await verifyDownloadToken(SECRET, t, NOW + 1000)).toBeNull();
        expect(await verifyDownloadToken("another", t, NOW)).toBeNull();
        const [p, s] = t.split(".");
        expect(await verifyDownloadToken(SECRET, `${p}x.${s}`, NOW)).toBeNull();
        // a token for a file outside exports/ is never honoured, even signed
        const out = await signDownloadToken(SECRET, { k: "key-1", f: "canvases/abc.png", n: "a.png", e: NOW + 1000 });
        expect(await verifyDownloadToken(SECRET, out, NOW)).toBeNull();
    });

    it("writes the file, answers a curl line, and clears exports older than a day", async () => {
        const puts: { key: string; type?: string; meta?: Record<string, string> }[] = [];
        const objects = [
            { key: "exports/old/a.json", uploaded: new Date(NOW - EXPORT_KEEP_MS - 1) },
            { key: "exports/new/b.json", uploaded: new Date(NOW - 1000) },
        ];
        const deleted: string[] = [];
        const bucket = {
            put: async (key: string, _v: unknown, o?: any) => void puts.push({ key, type: o?.httpMetadata?.contentType, meta: o?.customMetadata }),
            list: async () => ({ objects }),
            delete: async (k: string | string[]) => void deleted.push(...[k].flat()),
        };
        const link = await writeExport({ bucket, secret: SECRET, now: () => NOW, origin: "https://api.capybaraharmony.com", clientKeyId: "key-1", random: () => "r1" }, "swarm 12/results.json", '{"a":1}', "application/json");
        expect(deleted).toEqual(["exports/old/a.json"]);
        expect(puts).toEqual([{ key: "exports/r1/swarm-12-results.json", type: "application/json", meta: { keyId: "key-1", createdAt: String(NOW) } }]);
        expect(link).toMatchObject({ file: "swarm-12-results.json", bytes: 7, expires_at: new Date(NOW + 3_600_000).toISOString() });
        expect(link.curl).toBe(`curl -sS -o swarm-12-results.json '${link.url}'`);
        const token = link.url.split("/mcp/download/")[1]!;
        expect(await verifyDownloadToken(SECRET, token, NOW)).toMatchObject({ k: "key-1", f: "exports/r1/swarm-12-results.json" });
    });
});
