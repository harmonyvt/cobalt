// Gallery share links (APP-API-CONTRACT.md section 24): the keyed create / list / revoke routes and
// the share host's page, Mastodon status and oEmbed. The Worker and the real SQL run together; the
// container must never be reached.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { mintSetId } from "../src/share-sets";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
let KEY_HASH = "";
let db: FakeD1;
let containerCalls: string[];
let env: WorkerEnv;

const container = {
    async fetch(r: Request) {
        containerCalls.push(new URL(r.url).pathname);
        return new Response("{}", { headers: { "content-type": "application/json" } });
    },
};

let n = 0;
const row = (over: Record<string, unknown>) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: "x_2105237035271258436.mp4",
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
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
};

const get = (url: string, init: RequestInit = {}, e: WorkerEnv = env) =>
    handleRequest(new Request(url, init), e, container, { now: () => 5_000 });

const meta = (html: string, key: string): string | null => {
    const m = new RegExp(`<meta (?:property|name)="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(html);
    return m ? m[1] : null;
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = createFakeD1();
    containerCalls = [];
    env = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
});


const API = "https://api.capybaraharmony.com";
const create = async (body: unknown) => {
    const r = await get(`${API}/share/sets`, { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: JSON.stringify(body) });
    return { status: r.status, body: (await r.json()) as any };
};
const list = async () => (await (await get(`${API}/share/sets`, { headers: AUTH })).json()) as any;

let video: any, webp: any, photo: any, privateOne: any, fifth: any;
beforeEach(() => {
    video = row({ visibility: "public", public_key: "ViDeO00001.mp4", poster: `${MEDIA}PoStEr0001.jpg`, width: 3840, height: 2160 });
    webp = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", content_type: "image/webp", width: 480, height: 270 });
    photo = row({ visibility: "public", public_key: "PhOtO00001.jpg", content_type: "image/jpeg", width: 1080, height: 1350, duration: null });
    privateOne = row({ r2_key: "originals/private.mp4" });
    fifth = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp02.webp", content_type: "image/webp" });
});

describe("POST /share/sets", () => {
    it("makes a set of 2..4 public files and answers its link", async () => {
        const r = await create({ items: [video.id, webp.id, photo.id], title: "  trip  " });
        expect(r.status).toBe(201);
        const set = r.body.set;
        expect(set.id).toMatch(/^[1-9][0-9]{18}$/);
        expect(set.url).toBe(`${SHARE}g/${set.id}`);
        expect(set.title).toBe("trip");
        expect(set.items.map((i: any) => i.url)).toEqual([`${MEDIA}ViDeO00001.mp4`, `${MEDIA}WeBpWeBp01.webp`, `${MEDIA}PhOtO00001.jpg`]);
        expect(set.items[0].poster_url).toBe(`${MEDIA}PoStEr0001.jpg`);
        expect(containerCalls).toEqual([]);
    });
    it("refuses fewer than 2, more than 4, duplicates, bad ids and long titles", async () => {
        for (const b of [
            { items: [video.id] },
            { items: [video.id, webp.id, photo.id, fifth.id, "x".repeat(16)] },
            { items: [video.id, video.id] },
            { items: [video.id, "nope"] },
            { items: "x" },
            { items: [video.id, webp.id], title: "t".repeat(81) },
        ]) {
            const r = await create(b);
            expect(r.status, JSON.stringify(b)).toBe(400);
            expect(r.body.error.code).toBe("error.share.bad_request");
        }
    });
    it("refuses private, deleted and unknown files and names them", async () => {
        const r = await create({ items: [video.id, privateOne.id, "Unknown000000000"] });
        expect(r.status).toBe(409);
        expect(r.body).toMatchObject({ error: { code: "error.share.not_public" }, items: [privateOne.id, "Unknown000000000"] });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM share_sets").get()).toMatchObject({ n: 0 });
    });
    it("needs a key; the library service gets a 404", async () => {
        const noKey = await get(`${API}/share/sets`, { method: "POST", body: "{}" });
        expect(noKey.status).toBe(401);
        const svc = await get(`${API}/share/sets`, { headers: { "x-cobalt-service": INTERNAL } });
        expect(svc.status).toBe(404);
    });
});

describe("listing and revoking", () => {
    it("lists live sets newest first, a gone file has url null, revoke hides it and its page", async () => {
        const a = (await create({ items: [video.id, webp.id] })).body.set;
        const b = (await create({ items: [photo.id, fifth.id] })).body.set;
        db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(fifth.id);
        let l = await list();
        expect(l.sets.map((s: any) => s.id).sort()).toEqual([a.id, b.id].sort());
        expect(l.sets.find((s: any) => s.id === b.id).items[1].url).toBeNull();
        expect((await get(`${SHARE}g/${a.id}`)).status).toBe(200);
        const del = await get(`${API}/share/sets/${a.id}`, { method: "DELETE", headers: AUTH });
        expect(del.status).toBe(200);
        expect((await get(`${API}/share/sets/${a.id}`, { method: "DELETE", headers: AUTH })).status).toBe(200);
        l = await list();
        expect(l.sets.map((s: any) => s.id)).toEqual([b.id]);
        expect((await get(`${SHARE}g/${a.id}`)).status).toBe(404);
        expect((await get(`${SHARE}api/v1/statuses/${a.id}`)).status).toBe(404);
        expect((await get(`${API}/share/sets/1234567890123456789`, { method: "DELETE", headers: AUTH })).status).toBe(404);
    });
});

describe("the share host", () => {
    let set: any;
    beforeEach(async () => {
        set = (await create({ items: [video.id, webp.id, photo.id], title: "<b>trip</b>" })).body.set;
    });
    it("the page carries the first video and every picture, and no Mastodon link for others", async () => {
        const html = await (await get(`${SHARE}g/${set.id}`)).text();
        expect(meta(html, "og:video")).toBe(`${MEDIA}ViDeO00001.mp4`);
        expect(meta(html, "og:video:width")).toBe("1920");
        const images = [...html.matchAll(/<meta property="og:image" content="([^"]*)">/g)].map((m) => m[1]);
        expect(images).toEqual([`${MEDIA}PoStEr0001.jpg`, `${MEDIA}WeBpWeBp01.webp`, `${MEDIA}PhOtO00001.jpg`]);
        expect(html).not.toContain("activity+json");
        expect(html).not.toContain("<b>trip");
    });
    it("Discord's crawler gets a component embed: every file in one media gallery", async () => {
        const html = await (await get(`${SHARE}g/${set.id}`, { headers: { "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" } })).text();
        const m = /<script id="discord:component-embed" type="application\/json">([^<]*)<\/script>/.exec(html);
        expect(m).not.toBeNull();
        expect(m![1].length).toBeLessThanOrEqual(3000);
        const doc = JSON.parse(m![1]);
        expect(Object.keys(doc)).toEqual(["component"]);
        expect(doc.component.type).toBe(17);
        expect(doc.component.components[0]).toEqual({ type: 10, content: "\\<b\\>trip\\</b\\>" });
        expect(doc.component.components[1]).toEqual({
            type: 12,
            items: [`${MEDIA}ViDeO00001.mp4`, `${MEDIA}WeBpWeBp01.webp`, `${MEDIA}PhOtO00001.jpg`].map((url) => ({ media: { url } })),
        });
        expect(html).not.toContain("activity+json");
        // Open Graph stays as the fallback
        expect(meta(html, "og:video")).toBe(`${MEDIA}ViDeO00001.mp4`);
    });
    it("the status lists every file as an attachment, big videos halved", async () => {
        for (const path of [`api/v1/statuses/${set.id}`, `users/cobalt/statuses/${set.id}`]) {
            const res = await get(`${SHARE}${path}`);
            expect(res.headers.get("content-type")).toContain("application/json");
            const st = (await res.json()) as any;
            expect(st.id).toBe(set.id);
            expect(st.content).toBe("<p>&lt;b&gt;trip&lt;/b&gt;</p>");
            expect(st.media_attachments.map((m: any) => [m.type, m.url])).toEqual([
                ["video", `${MEDIA}ViDeO00001.mp4`],
                ["image", `${MEDIA}WeBpWeBp01.webp`],
                ["image", `${MEDIA}PhOtO00001.jpg`],
            ]);
            expect(st.media_attachments[0].meta.original).toMatchObject({ width: 1920, height: 1080 });
            expect(st.media_attachments[0].preview_url).toBe(`${MEDIA}PoStEr0001.jpg`);
        }
        const oe = (await (await get(`${SHARE}owoembed?id=${set.id}`)).json()) as any;
        expect(oe).toMatchObject({ version: "1.0", type: "rich", provider_name: "cobalt", author_name: "<b>trip</b>" });
    });
    it("a file made private drops out; with none left the set is a 404", async () => {
        db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id = ?").run(video.id);
        const st = (await (await get(`${SHARE}api/v1/statuses/${set.id}`)).json()) as any;
        expect(st.media_attachments).toHaveLength(2);
        db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id IN (?, ?)").run(webp.id, photo.id);
        expect((await get(`${SHARE}g/${set.id}`)).status).toBe(404);
        expect((await get(`${SHARE}g/123`)).status).toBe(404);
    });
    it("capabilities advertise share_sets and the limit", async () => {
        const c = (await (await get(`${API}/capabilities`)).json()) as any;
        expect(c.features.share_sets).toBe(true);
        expect(c.limits.share_set_max).toBe(4);
        const off = (await (await get(`${API}/capabilities`, {}, { ...env, SHARE_BASE_URL: "" })).json()) as any;
        expect(off.features.share_sets).toBe(false);
    });
    it("set ids are 19 digits", () => {
        for (let i = 0; i < 50; i++) expect(mintSetId()).toMatch(/^[1-9][0-9]{18}$/);
    });
});
