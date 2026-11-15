// Media refs (APP-API-CONTRACT.md section 62.1): what counts as one, the allowlist, and one batch that turns a list into
// previews (capystore refs through the section 60 resolver, real SQL; 7TV emotes as their CDN picture; URLs as given).
import { describe, expect, it } from "vitest";
import { EMOTE_ID, MEDIA_HOSTS_DEFAULT, mediaHostsOf, mediaPosts, parseMediaRef, resolveMedia } from "../src/media-refs";
import { lookMediaBlocks, lookMediaImages } from "../src/look-pictures";
import { MEDIA, SHARE, world } from "./stage-world";

const ULID = "01HZX5Q8M3Y9K2B7C4D6E8F0GA";
const OID = "60ae958e229664e8667aea38";
const BASES = { mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, hosts: mediaHostsOf({}, { mediaBaseUrl: MEDIA, shareBaseUrl: SHARE }) };

describe("parseMediaRef", () => {
    it("reads 7TV emotes in every form", () => {
        expect(EMOTE_ID.test(ULID) && EMOTE_ID.test(OID)).toBe(true);
        for (const r of [ULID, OID, `https://7tv.app/emotes/${ULID}`, `7tv.app/emotes/${ULID}`, `https://cdn.7tv.app/emote/${ULID}/4x.avif`, `<https://old.7tv.app/emotes/${OID}>`]) {
            expect(parseMediaRef(r, BASES), r).toEqual({ kind: "emote", id: r.includes(OID) ? OID : ULID });
        }
    });

    it("allowlisted https URLs are images or videos; others are refused; the house hosts are capystore refs", () => {
        const b = { ...BASES, hosts: mediaHostsOf({ MEDIA_HOSTS: "i.example.com" }, BASES) };
        expect(parseMediaRef("https://i.example.com/a/b.png", b)).toEqual({ kind: "url", url: "https://i.example.com/a/b.png", media: "image" });
        expect(parseMediaRef("https://i.example.com/clip.mp4", b)).toEqual({ kind: "url", url: "https://i.example.com/clip.mp4", media: "video" });
        expect(parseMediaRef("https://evil.example.com/x.png", b)).toEqual({ kind: "refused", error: "error.media.host_not_allowed" });
        expect(parseMediaRef("http://i.example.com/x.png", b)).toEqual({ kind: "refused", error: "error.media.not_https" });
        expect(parseMediaRef(`${MEDIA}vFhaasY6GA.webp`, b)).toEqual({ kind: "capystore", ref: `${MEDIA}vFhaasY6GA.webp` });
        expect(parseMediaRef(`${SHARE}g/1111111111111111111`, b)).toEqual({ kind: "capystore", ref: `${SHARE}g/1111111111111111111` });
        expect(parseMediaRef("Item000000000001", b)).toEqual({ kind: "capystore", ref: "Item000000000001" });
        // plain words and numbers are not refs
        for (const x of ["cat", "a cat sitting", 42, null, "", "x".repeat(3000)]) expect(parseMediaRef(x, b)).toBeNull();
    });

    it("the allowlist: the var, else the default, always with the house hosts", () => {
        expect(mediaHostsOf({})).toEqual(MEDIA_HOSTS_DEFAULT.split(","));
        expect(mediaHostsOf({ MEDIA_HOSTS: " I.Example.com , bad host,cdn.7tv.app" }, { mediaBaseUrl: "https://m.example.net/" })).toEqual(["i.example.com", "cdn.7tv.app", "m.example.net"]);
    });
});

describe("resolveMedia", () => {
    it("one batch: posts and files with their pictures, emotes, URLs, and an error for the rest, in order", async () => {
        const w = await world();
        const pub = w.file();
        const vid = w.video({ visibility: "private" });
        const gone = w.file({ deleted_at: 5 });
        const refs = [pub.url!, vid.id, ULID, `https://cdn.7tv.app/emote/${OID}/1x.webp`, "https://media.capybaraharmony.com/Nothing123.webp", `${MEDIA}${gone.r2_key}`, "https://evil.example.com/a.png", "just words"];
        const out = await resolveMedia(w.env.DB, refs, BASES);
        expect(out.map((o) => o.ref)).toEqual(refs);
        expect(out[0]).toMatchObject({ kind: "file", preview_url: pub.url, open_url: pub.url });
        expect(out[1]).toMatchObject({ kind: "post", open_url: null, animated: true });
        expect(out[2]).toEqual({ ref: ULID, kind: "emote", preview_url: `https://cdn.7tv.app/emote/${ULID}/2x.webp`, open_url: `https://7tv.app/emotes/${ULID}` });
        expect(out[3]).toMatchObject({ kind: "emote", preview_url: `https://cdn.7tv.app/emote/${OID}/2x.webp` });
        expect(out[4]).toEqual({ ref: refs[4], error: "error.media.not_found" });
        expect(out[5]).toEqual({ ref: refs[5], error: "error.media.deleted" });
        expect(out[6]).toEqual({ ref: refs[6], error: "error.media.host_not_allowed" });
        expect(out[7]).toEqual({ ref: "just words", error: "error.media.not_a_ref" });
        // the posts behind capystore refs, for look's frame path
        expect(await mediaPosts(w.env.DB, [pub.url!, ULID, vid.id], BASES)).toEqual(new Map([[pub.url!, pub.id], [vid.id, vid.id]]));
    });
});

describe("look({ media })", () => {
    it("a post's picture, an emote fetched and sent inline, an image link that fails falls back to its URL, a video link and a bad ref get a note", async () => {
        const w = await world();
        const pub = w.file();
        const fetched: string[] = [];
        const fetchImpl = (async (url: string) => {
            fetched.push(url);
            return url.includes("cdn.7tv.app")
                ? new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/webp" } })
                : new Response("no", { status: 404, headers: { "content-type": "text/plain" } });
        }) as unknown as typeof fetch;
        const hosts = mediaHostsOf({ MEDIA_HOSTS: "i.example.com" }, BASES);
        const refs = [pub.url!, ULID, "https://i.example.com/a.png", "https://i.example.com/a.mp4", "words"];
        const out = await lookMediaImages({ db: w.env.DB, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, hosts, images: null, fetch: fetchImpl }, refs);
        expect(fetched).toEqual([`https://cdn.7tv.app/emote/${ULID}/2x.webp`, "https://i.example.com/a.png"]);
        expect(out.get(pub.url!)!.images[0]).toMatchObject({ label: expect.stringMatching(/^Picture of file /), url: pub.url });
        expect(out.get(ULID)!.images).toEqual([{ label: `Picture of emote ${ULID} (https://cdn.7tv.app/emote/${ULID}/2x.webp):`, data: "AQID", mediaType: "image/webp" }]);
        expect(out.get(refs[2]!)!.images).toEqual([{ label: `Picture of image ${refs[2]}:`, url: refs[2] }]);
        expect(out.get(refs[3]!)).toMatchObject({ images: [], note: expect.stringMatching(/video link outside capystore/) });
        expect(out.get("words")).toEqual({ images: [], note: "words: not a ref" });
        expect(lookMediaBlocks(ULID, out.get(ULID))).toEqual([
            { type: "text", text: out.get(ULID)!.images[0]!.label },
            { type: "image", source: { type: "base64", media_type: "image/webp", data: "AQID" } },
        ]);
        expect(lookMediaBlocks("x", undefined)).toEqual([{ type: "text", text: "x could not be looked at." }]);
    });
});
