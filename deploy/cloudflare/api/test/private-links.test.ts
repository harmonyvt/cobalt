// Private share links (APP-API-CONTRACT.md section 36): the /share/private routes, a collection's privacy switch, private
// gallery links at creation, and the share host's /p/<key> pages and files. The Worker, the registry, the real handlers
// and the real SQL (node:sqlite) run together; R2 is in memory and the container is never reached.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const DISCORD = { "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" };
const KEY = /^https:\/\/share\.capybaraharmony\.com\/p\/([A-Za-z0-9]{22})$/;

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let media: MemoryMedia;
let clock: number;
let containerCalls: string[];

const container = {
    async fetch(r: Request) {
        containerCalls.push(new URL(r.url).pathname);
        await r.body?.cancel().catch(() => {});
        return Response.json({ status: "success" });
    },
};

const send = (url: string, init: RequestInit = {}) =>
    handleRequest(new Request(url, init), env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });
const api = async (method: string, path: string, body?: unknown, headers: Record<string, string> = AUTH) => {
    const r = await send(`${API}${path}`, {
        method,
        headers: { ...headers, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, headers: r.headers, body: text ? (JSON.parse(text) as any) : null };
};
const share = (path: string, init: RequestInit = {}) => send(`${SHARE.replace(/\/$/, "")}${path}`, init);
const keyOf = (url: string) => KEY.exec(url)![1]!;

const bytes = (n: number, seed = 1) => Uint8Array.from({ length: n }, (_, i) => (i * 7 + seed) % 251);

let n = 0;
function row(over: Record<string, unknown>) {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: `clip${n}.mp4`,
        content_type: "video/mp4",
        bytes: 1000,
        width: 480,
        height: 640,
        duration: 9.6,
        link: "https://x.com/someone/status/1",
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
    return r;
}
const putOriginal = (key: string, data: Uint8Array, contentType = "video/mp4") => originals.objects.set(key, { bytes: data, contentType, meta: {} });
const putMedia = (key: string, data: Uint8Array, contentType = "video/mp4") =>
    media.objects.set(key, { bytes: data.length, meta: {}, contentType, data, viaStream: false });
const one = (sql: string, ...p: unknown[]) => db.raw.prepare(sql).get(...(p as any[])) as any;

// A public original video (with its public copy and a poster), a private original image, and a webp still in the public bucket.
let pubVideo: any, privImage: any, webp: any;
const VIDEO = bytes(1000, 3);
const IMAGE = bytes(300, 5);
const WEBP = bytes(200, 9);
const POSTER = bytes(50, 11);

beforeEach(async () => {
    clock = 1_800_000_000_000;
    containerCalls = [];
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    media = new MemoryMedia();
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    pubVideo = row({ visibility: "public", public_key: "PuBlIcViD01.mp4", url: `${MEDIA}PuBlIcViD01.mp4`, poster: `${MEDIA}PoStEr0001.jpg`, bytes: VIDEO.length });
    putOriginal(pubVideo.r2_key, VIDEO);
    putMedia("PuBlIcViD01.mp4", VIDEO);
    putMedia("PoStEr0001.jpg", POSTER, "image/jpeg");
    privImage = row({ r2_key: "originals/photo1.jpg", name: "photo.jpg", content_type: "image/jpeg", duration: null, bytes: IMAGE.length, source: "upload" });
    putOriginal(privImage.r2_key, IMAGE, "image/jpeg");
    webp = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", url: `${MEDIA}WeBpWeBp01.webp`, content_type: "image/webp", duration: null, bytes: WEBP.length });
    putMedia("WeBpWeBp01.webp", WEBP, "image/webp");
});

const urlsIn = (html: string) => [...html.matchAll(/https?:\/\/[^"'\s<>\\]+/g)].map((m) => m[0]);

describe("a file's private link", () => {
    it("turning it on makes a public file not public first, then only /p/<key> opens it", async () => {
        const r = await api("PUT", `/share/private/items/${pubVideo.id}`);
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(r.body).toMatchObject({ status: "success", link: { kind: "item", target_id: pubVideo.id, opened: 0, last_opened_at: null, created_at: clock } });
        expect(r.body.link.url).toMatch(KEY);
        // section 16 OFF ran: the public copy is gone, the row says private, the public page is a 404
        expect(media.objects.has("PuBlIcViD01.mp4")).toBe(false);
        expect(one("SELECT visibility, url FROM media_items WHERE id = ?", pubVideo.id)).toEqual({ visibility: "private", url: null });
        expect((await share("/PuBlIcViD01")).status).toBe(404);
        // the same link again
        const again = await api("PUT", `/share/private/items/${pubVideo.id}`);
        expect(again.body.link.url).toBe(r.body.link.url);
        // the library lists it as the file's private_url
        const lib = await api("GET", "/library?v=3");
        const f = lib.body.posts.flatMap((p: any) => p.files).find((x: any) => x.id === pubVideo.id);
        expect(f).toMatchObject({ visibility: "private", url: null, private_url: r.body.link.url });
        expect(lib.body.posts.flatMap((p: any) => p.files).find((x: any) => x.id === privImage.id).private_url).toBeNull();
        // GET /share/private lists it
        const list = await api("GET", "/share/private");
        expect(list.body).toEqual({ status: "success", links: [r.body.link], new_links: "public", sets: [] });
        // the container is never woken for it (GET /library only asks the Durable Object to queue posters)
        expect(containerCalls.filter((c) => c !== "/posters/kick")).toEqual([]);
    });

    it("its page: Open Graph through /p/<key>/ only, no-store, CSP of the share origin, counted on GET", async () => {
        const url = (await api("PUT", `/share/private/items/${pubVideo.id}`)).body.link.url as string;
        const key = keyOf(url);
        const res = await send(url, { headers: DISCORD });
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("x-robots-tag")).toBe("noindex");
        expect(res.headers.get("content-security-policy")).toContain(`img-src https://share.capybaraharmony.com; media-src https://share.capybaraharmony.com;`);
        const html = await res.text();
        expect(html).toContain(`<meta property="og:video" content="${SHARE}p/${key}/1.mp4">`);
        expect(html).toContain(`<meta property="og:image" content="${SHARE}p/${key}/1.poster.jpg">`);
        for (const u of urlsIn(html)) expect(u.startsWith(`${SHARE}p/${key}`)).toBe(true);
        expect(html).not.toContain(MEDIA);
        // HEAD does not count
        expect((await send(url, { method: "HEAD" })).status).toBe(200);
        expect(one("SELECT opened, last_opened_at FROM private_links WHERE key = ?", key)).toEqual({ opened: 1, last_opened_at: clock });
        // the file and its poster stream from R2 (the original from cobalt-originals, the poster from cobalt-media)
        const file = await share(`/p/${key}/1.mp4`);
        expect(file.status).toBe(200);
        expect(file.headers.get("content-type")).toBe("video/mp4");
        expect(file.headers.get("cache-control")).toBe("private, no-store");
        expect(file.headers.get("x-content-type-options")).toBe("nosniff");
        expect(new Uint8Array(await file.arrayBuffer())).toEqual(VIDEO);
        const poster = await share(`/p/${key}/1.poster.jpg`);
        expect(poster.status).toBe(200);
        expect(new Uint8Array(await poster.arrayBuffer())).toEqual(POSTER);
        // file fetches do not count either
        expect(one("SELECT opened FROM private_links WHERE key = ?", key).opened).toBe(1);
        // wrong extension, wrong number, other methods
        expect((await share(`/p/${key}/1.webm`)).status).toBe(404);
        expect((await share(`/p/${key}/2.mp4`)).status).toBe(404);
        expect((await share(`/p/${key}`, { method: "POST" })).status).toBe(405);
    });

    it("Range: 206 with the right bytes, a suffix range, HEAD, and 416 when unsatisfiable", async () => {
        const key = keyOf((await api("PUT", `/share/private/items/${privImage.id}`)).body.link.url);
        const part = await share(`/p/${key}/1.jpg`, { headers: { range: "bytes=10-19" } });
        expect(part.status).toBe(206);
        expect(part.headers.get("content-range")).toBe(`bytes 10-19/${IMAGE.length}`);
        expect(part.headers.get("content-length")).toBe("10");
        expect(part.headers.get("accept-ranges")).toBe("bytes");
        expect(part.headers.get("content-type")).toBe("image/jpeg");
        expect(new Uint8Array(await part.arrayBuffer())).toEqual(IMAGE.slice(10, 20));
        expect(originals.gets.at(-1)).toEqual({ key: privImage.r2_key, range: { offset: 10, length: 10 } });
        const tail = await share(`/p/${key}/1.jpg`, { headers: { range: "bytes=-5" } });
        expect(tail.status).toBe(206);
        expect(new Uint8Array(await tail.arrayBuffer())).toEqual(IMAGE.slice(-5));
        const head = await share(`/p/${key}/1.jpg`, { method: "HEAD", headers: { range: "bytes=0-0" } });
        expect(head.status).toBe(206);
        expect(head.headers.get("content-range")).toBe(`bytes 0-0/${IMAGE.length}`);
        const bad = await share(`/p/${key}/1.jpg`, { headers: { range: "bytes=5000-" } });
        expect(bad.status).toBe(416);
        expect(bad.headers.get("content-range")).toBe(`bytes */${IMAGE.length}`);
        // no poster: 404
        expect((await share(`/p/${key}/1.poster.jpg`)).status).toBe(404);
    });

    it("rotating makes a new key and the old one is a 404 at once; DELETE revokes and the file stays not public", async () => {
        const first = (await api("PUT", `/share/private/items/${privImage.id}`)).body.link.url as string;
        clock += 1000;
        const rot = await api("POST", `/share/private/items/${privImage.id}/rotate`);
        expect(rot.status).toBe(200);
        expect(rot.body.link.url).toMatch(KEY);
        expect(rot.body.link.url).not.toBe(first);
        expect(rot.body.link.created_at).toBe(clock);
        expect((await send(first)).status).toBe(404);
        expect((await share(`/p/${keyOf(first)}/1.jpg`)).status).toBe(404);
        expect((await send(rot.body.link.url)).status).toBe(200);
        // revoked rows stay
        expect(one("SELECT COUNT(*) AS n FROM private_links WHERE target_id = ?", privImage.id).n).toBe(2);

        const off = await api("DELETE", `/share/private/items/${privImage.id}`);
        expect(off).toMatchObject({ status: 200, body: { status: "success" } });
        expect((await send(rot.body.link.url)).status).toBe(404);
        expect(one("SELECT visibility FROM media_items WHERE id = ?", privImage.id).visibility).toBeNull();
        // none live: still 200; rotate: 404
        expect((await api("DELETE", `/share/private/items/${privImage.id}`)).status).toBe(200);
        expect(await api("POST", `/share/private/items/${privImage.id}/rotate`)).toMatchObject({ status: 404, body: { error: { code: "error.private.not_found" } } });
    });

    it("making the file public (section 16) revokes its private link", async () => {
        const url = (await api("PUT", `/share/private/items/${pubVideo.id}`)).body.link.url as string;
        const r = await api("PATCH", `/library/items/${pubVideo.id}/visibility`, { public: true });
        expect(r.status).toBe(200);
        expect(r.body.item).toMatchObject({ visibility: "public", private_url: null });
        expect((await send(url)).status).toBe(404);
        expect(one("SELECT revoked_at FROM private_links WHERE key = ?", keyOf(url)).revoked_at).toBe(clock);
        expect((await share("/PuBlIcViD01")).status).toBe(200);
        // and the legacy publish route too
        const again = (await api("PUT", `/share/private/items/${pubVideo.id}`)).body.link.url as string;
        expect((await api("POST", `/library/items/${pubVideo.id}/publish`)).status).toBe(201);
        expect((await send(again)).status).toBe(404);
    });

    it("making a file private through section 16 keeps its link, and the answer carries it", async () => {
        const url = (await api("PUT", `/share/private/items/${privImage.id}`)).body.link.url as string;
        const r = await api("PATCH", `/library/items/${privImage.id}/visibility`, { public: false });
        expect(r.body.item.private_url).toBe(url);
    });

    it("a webp still in the public bucket moves private first; a deleted file or an unknown id is 404, a poster row 409", async () => {
        const r = await api("PUT", `/share/private/items/${webp.id}`);
        expect(r.status).toBe(200);
        expect(one("SELECT bucket, visibility FROM media_items WHERE id = ?", webp.id)).toEqual({ bucket: "originals", visibility: "private" });
        const key = keyOf(r.body.link.url);
        const f = await share(`/p/${key}/1.webp`);
        expect(f.status).toBe(200);
        expect(new Uint8Array(await f.arrayBuffer())).toEqual(WEBP);

        const gone = row({ deleted_at: 5 });
        expect(await api("PUT", `/share/private/items/${gone.id}`)).toMatchObject({ status: 404, body: { error: { code: "error.private.not_found" } } });
        expect((await api("PUT", "/share/private/items/Unknown000000001")).status).toBe(404);
        const host = row({ kind: "public", source: "host", bucket: "media", r2_key: "HoStCoPy01.mp4" });
        expect(await api("PUT", `/share/private/items/${host.id}`)).toMatchObject({ status: 409, body: { error: { code: "error.private.not_toggleable" } } });
    });

    it("a deleted file's link opens nothing", async () => {
        const url = (await api("PUT", `/share/private/items/${privImage.id}`)).body.link.url as string;
        db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(privImage.id);
        expect((await send(url)).status).toBe(404);
        expect((await share(`/p/${keyOf(url)}/1.jpg`)).status).toBe(404);
    });
});

describe("a gallery link's private link", () => {
    const makeSet = async (items: string[], extra: Record<string, unknown> = {}) => {
        const r = await api("POST", "/share/sets", { items, ...extra });
        expect(r.status).toBe(201);
        return r.body.set;
    };

    it("PUT hides /g/<id> and its status and oEmbed routes; DELETE makes it public again", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        expect(set).toMatchObject({ private: false, link: null, url: `${SHARE}g/${set.id}`, public_url: `${SHARE}g/${set.id}` });
        expect((await share(`/g/${set.id}`)).status).toBe(200);

        const on = await api("PUT", `/share/private/sets/${set.id}`);
        expect(on.body.link).toMatchObject({ kind: "set", target_id: set.id });
        for (const p of [`/g/${set.id}`, `/api/v1/statuses/${set.id}`, `/users/cobalt/statuses/${set.id}`, `/owoembed?id=${set.id}`]) {
            expect((await share(p)).status).toBe(404);
        }
        expect((await send(on.body.link.url)).status).toBe(200);
        // the set shape: url is the link that works now
        const listed = (await api("GET", "/share/sets")).body.sets[0];
        expect(listed).toMatchObject({ id: set.id, private: true, url: on.body.link.url, public_url: `${SHARE}g/${set.id}`, link: { ...on.body.link, opened: 1, last_opened_at: clock } });
        const key = keyOf(on.body.link.url);
        expect(listed.items.map((i: any) => i.url)).toEqual([`${SHARE}p/${key}/1.mp4`, `${SHARE}p/${key}/2.webp`]);
        expect(listed.items[0].poster_url).toBe(`${SHARE}p/${key}/1.poster.jpg`);

        expect((await api("DELETE", `/share/private/sets/${set.id}`)).status).toBe(200);
        expect((await share(`/g/${set.id}`)).status).toBe(200);
        expect((await send(on.body.link.url)).status).toBe(404);
        expect((await api("GET", "/share/sets")).body.sets[0]).toMatchObject({ private: false, link: null, url: `${SHARE}g/${set.id}` });
    });

    it("its page for Discordbot carries the component embed with only /p/<key>/ URLs", async () => {
        const set = await makeSet([pubVideo.id, privImage.id, webp.id], { private: true, title: "trip" });
        expect(set.private).toBe(true);
        const key = keyOf(set.url);
        const res = await send(set.url, { headers: DISCORD });
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        const html = await res.text();
        const m = /<script id="discord:component-embed" type="application\/json">(.*?)<\/script>/s.exec(html);
        expect(m).not.toBeNull();
        const embed = JSON.parse(m![1]!);
        expect(embed.component.components[1].items.map((i: any) => i.media.url)).toEqual([
            `${SHARE}p/${key}/1.mp4`,
            `${SHARE}p/${key}/2.jpg`,
            `${SHARE}p/${key}/3.webp`,
        ]);
        // no "watch with sound" button: no moving previews through a private link
        expect(embed.component.components).toHaveLength(2);
        for (const u of urlsIn(html)) expect(u.startsWith(`${SHARE}p/${key}`)).toBe(true);
        expect(html).not.toContain("media.capybaraharmony.com");
        // a file that is not public is served through the key
        const img = await share(`/p/${key}/2.jpg`);
        expect(img.status).toBe(200);
        expect(new Uint8Array(await img.arrayBuffer())).toEqual(IMAGE);
        // a deleted file drops out of the page; its number stays unused
        db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(privImage.id);
        expect((await share(`/p/${key}/2.jpg`)).status).toBe(404);
        const after = await (await send(set.url, { headers: DISCORD })).text();
        expect(after).toContain(`${SHARE}p/${key}/3.webp`);
        expect(after).not.toContain(`${SHARE}p/${key}/2.jpg`);
    });

    it("POST /share/sets private: files that are not public may be in it; only missing or deleted ids are refused", async () => {
        const gone = row({ deleted_at: 9 });
        const bad = await api("POST", "/share/sets", { items: [privImage.id, gone.id, "Missing000000001"], private: true });
        expect(bad).toMatchObject({ status: 409, body: { error: { code: "error.share.not_public" }, items: [gone.id, "Missing000000001"] } });
        // public (the default): a private file is refused as before
        const pub = await api("POST", "/share/sets", { items: [privImage.id, webp.id] });
        expect(pub).toMatchObject({ status: 409, body: { items: [privImage.id] } });
        expect((await api("POST", "/share/sets", { items: [privImage.id, webp.id], private: "yes" })).status).toBe(400);
        const set = await makeSet([privImage.id, webp.id], { private: true });
        expect(set).toMatchObject({ private: true, public_url: `${SHARE}g/${set.id}` });
        expect(set.url).toMatch(KEY);
        expect((await share(`/g/${set.id}`)).status).toBe(404);
        expect(one("SELECT COUNT(*) AS n FROM private_links WHERE kind = 'set' AND target_id = ? AND revoked_at IS NULL", set.id).n).toBe(1);
    });

    it("new_links decides when `private` is absent", async () => {
        expect(await api("PATCH", "/share/private/settings", { new_links: "maybe" })).toMatchObject({ status: 400, body: { error: { code: "error.private.bad_request" } } });
        expect((await api("PATCH", "/share/private/settings", { new_links: "private" })).body).toEqual({ status: "success", new_links: "private" });
        expect((await api("GET", "/share/private")).body.new_links).toBe("private");
        const set = await makeSet([privImage.id, webp.id]);
        expect(set.private).toBe(true);
        const explicit = await makeSet([pubVideo.id, webp.id], { private: false });
        expect(explicit.private).toBe(false);
    });

    it("revoking the gallery link revokes its private link", async () => {
        const set = await makeSet([privImage.id, webp.id], { private: true });
        expect((await api("DELETE", `/share/sets/${set.id}`)).status).toBe(200);
        expect((await send(set.url)).status).toBe(404);
        expect(one("SELECT revoked_at FROM private_links WHERE target_id = ?", set.id).revoked_at).toBe(clock);
        expect(await api("PUT", `/share/private/sets/${set.id}`)).toMatchObject({ status: 404, body: { error: { code: "error.private.not_found" } } });
    });

    it("a public gallery link still shows only public files", async () => {
        const set = await makeSet([pubVideo.id, webp.id]);
        await api("PUT", `/share/private/items/${pubVideo.id}`);
        const html = await (await share(`/g/${set.id}`)).text();
        expect(html).not.toContain("PuBlIcViD01");
        expect(html).toContain("WeBpWeBp01.webp");
    });
});

describe("rotate-all and collections", () => {
    it("rotates every live key in one batch", async () => {
        const a = (await api("PUT", `/share/private/items/${privImage.id}`)).body.link.url as string;
        const set = (await api("POST", "/share/sets", { items: [pubVideo.id, webp.id], private: true })).body.set;
        clock += 5;
        const r = await api("POST", "/share/private/rotate-all");
        expect(r.status).toBe(200);
        expect(r.body.rotated).toBe(2);
        expect(r.body.links).toHaveLength(2);
        const urls = r.body.links.map((l: any) => l.url);
        expect(urls).not.toContain(a);
        expect(urls).not.toContain(set.url);
        expect((await send(a)).status).toBe(404);
        expect((await send(set.url)).status).toBe(404);
        for (const u of urls) expect((await send(u)).status).toBe(200);
        expect((await api("GET", "/share/private")).body.links.map((l: any) => l.url).sort()).toEqual([...urls].sort());
    });

    it("POST /share/collections/<id>/privacy: private, rotate, public again", async () => {
        const s1 = (await api("POST", "/share/sets", { items: [pubVideo.id, webp.id] })).body.set;
        const s2 = (await api("POST", "/share/sets", { items: [webp.id, pubVideo.id] })).body.set;
        const c = (await api("POST", "/share/collections", { name: "memes", set_ids: [s1.id, s2.id] })).body.collection;
        expect((await api("POST", `/share/collections/${c.id}/privacy`, {})).body.error.code).toBe("error.collection.bad_request");
        expect((await api("POST", `/share/collections/${c.id}/privacy`, { private: true, rotate: true })).status).toBe(400);
        expect((await api("POST", "/share/collections/Unknown000000001/privacy", { private: true })).body.error.code).toBe("error.collection.not_found");

        const on = await api("POST", `/share/collections/${c.id}/privacy`, { private: true });
        expect(on.status).toBe(200);
        expect(on.body.links.map((l: any) => l.target_id)).toEqual([s1.id, s2.id]);
        expect((await share(`/g/${s1.id}`)).status).toBe(404);
        expect((await share(`/g/${s2.id}`)).status).toBe(404);

        const rot = await api("POST", `/share/collections/${c.id}/privacy`, { rotate: true });
        expect(rot.body.links.map((l: any) => l.url)).not.toContain(on.body.links[0].url);
        expect((await send(on.body.links[0].url)).status).toBe(404);

        const off = await api("POST", `/share/collections/${c.id}/privacy`, { private: false });
        expect(off.body).toEqual({ status: "success", links: [] });
        expect((await share(`/g/${s1.id}`)).status).toBe(200);
        // keyed only, like the rest of section 26
        expect((await api("POST", `/share/collections/${c.id}/privacy`, { private: true }, { "x-cobalt-service": INTERNAL })).status).toBe(404);
    });

    it("a reroll keeps a private link private, with a new key", async () => {
        const s1 = (await api("POST", "/share/sets", { items: [privImage.id, webp.id], private: true })).body.set;
        const c = (await api("POST", "/share/collections", { name: "x", set_ids: [s1.id] })).body.collection;
        const r = await api("POST", `/share/collections/${c.id}/reroll`);
        expect(r.status).toBe(200);
        const fresh = r.body.replaced[s1.id];
        expect((await send(s1.url)).status).toBe(404);
        const listed = (await api("GET", "/share/sets")).body.sets.find((s: any) => s.id === fresh);
        expect(listed.private).toBe(true);
        expect((await send(listed.url)).status).toBe(200);
    });
});

describe("who may call", () => {
    it("the web Worker's service credential may (the owner's web library); anonymous may not", async () => {
        const svc = { "x-cobalt-service": INTERNAL };
        expect((await api("GET", "/share/private", undefined, svc)).status).toBe(200);
        expect((await api("PUT", `/share/private/items/${privImage.id}`, undefined, svc)).status).toBe(200);
        expect((await api("GET", "/share/private", undefined, {})).status).toBe(401);
    });
    it("everything is 404 error.share.off while the share host is off", async () => {
        env = { ...env, SHARE_BASE_URL: undefined };
        expect(await api("GET", "/share/private")).toMatchObject({ status: 404, body: { error: { code: "error.share.off" } } });
        expect((await api("GET", "/capabilities")).body.features.private_links).toBe(false);
    });
    it("capabilities: private_links with the share host", async () => {
        expect((await api("GET", "/capabilities")).body.features.private_links).toBe(true);
    });
});

describe("before migration 0024", () => {
    beforeEach(() => db.raw.exec("DROP TABLE private_links; DROP TABLE share_settings;"));

    it("the routes answer 503 (GET: none, public), nothing changes, and everything else is as before", async () => {
        expect(await api("GET", "/share/private")).toMatchObject({ status: 200, body: { status: "success", links: [], new_links: "public" } });
        for (const [m, p, b] of [
            ["PUT", `/share/private/items/${pubVideo.id}`],
            ["DELETE", `/share/private/items/${pubVideo.id}`],
            ["POST", `/share/private/items/${pubVideo.id}/rotate`],
            ["PUT", "/share/private/sets/1234567890123456789"],
            ["POST", "/share/private/rotate-all"],
            ["PATCH", "/share/private/settings", { new_links: "private" }],
        ] as const) {
            expect(await api(m, p, b)).toMatchObject({ status: 503, body: { error: { code: "error.api.generic" } } });
        }
        // the public file was NOT made private for a link that could not be stored
        expect(media.objects.has("PuBlIcViD01.mp4")).toBe(true);
        expect(one("SELECT visibility FROM media_items WHERE id = ?", pubVideo.id).visibility).toBe("public");
        // gallery links, the library, the toggle and the share host work as before
        const set = (await api("POST", "/share/sets", { items: [pubVideo.id, webp.id] })).body.set;
        expect(set).toMatchObject({ private: false, link: null });
        expect((await share(`/g/${set.id}`)).status).toBe(200);
        expect((await api("GET", "/share/sets")).status).toBe(200);
        expect((await api("DELETE", `/share/sets/${set.id}`)).status).toBe(200);
        const lib = await api("GET", "/library?v=3");
        expect(lib.status).toBe(200);
        expect(lib.body.posts.flatMap((p: any) => p.files).every((f: any) => f.private_url === null)).toBe(true);
        expect((await api("PATCH", `/library/items/${privImage.id}/visibility`, { public: true })).status).toBe(200);
        expect((await share("/p/AbCdEfGh1234567890ZzYy")).status).toBe(404);
        expect((await share("/p/AbCdEfGh1234567890ZzYy/1.mp4")).status).toBe(404);
        expect((await share("/PuBlIcViD01")).status).toBe(200);
    });
});
