// Rich link pages (APP-API-CONTRACT.md section 22): https://share.../<name> for every public file, with
// the Open Graph / Twitter card tags link unfurlers read. The Worker and the real SQL (node:sqlite on
// every migration) run together; the container must never be reached from the share host.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { escapeHtml, shareUrlFor } from "../src/share";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

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

beforeEach(() => {
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
});

describe("a public video", () => {
    beforeEach(() => {
        row({
            visibility: "public",
            public_key: "AbCdEfGh12.mp4",
            url: `${MEDIA}AbCdEfGh12.mp4`,
            poster: `${MEDIA}PoStEr0001.jpg`,
            session_id: "SessionOne",
        });
    });

    it("has a page with a playable video card and its poster, without waking the container", async () => {
        const res = await get(`${SHARE}AbCdEfGh12`);
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
        expect(res.headers.get("cache-control")).toBe("public, max-age=60");
        expect(res.headers.get("content-security-policy")).toContain("media-src https://media.capybaraharmony.com");
        const html = await res.text();
        expect(meta(html, "og:type")).toBe("video.other");
        expect(meta(html, "og:video")).toBe(`${MEDIA}AbCdEfGh12.mp4`);
        expect(meta(html, "og:video:secure_url")).toBe(`${MEDIA}AbCdEfGh12.mp4`);
        expect(meta(html, "og:video:type")).toBe("video/mp4");
        expect(meta(html, "og:video:width")).toBe("480");
        expect(meta(html, "og:video:height")).toBe("560");
        expect(meta(html, "og:image")).toBe(`${MEDIA}PoStEr0001.jpg`);
        expect(meta(html, "twitter:card")).toBe("player");
        expect(meta(html, "twitter:player:stream")).toBe(`${MEDIA}AbCdEfGh12.mp4`);
        expect(meta(html, "og:url")).toBe(`${SHARE}AbCdEfGh12`);
        expect(meta(html, "og:title")).toBe("x_2105237035271258436");
        expect(meta(html, "og:description")).toBe("0:10");
        expect(html).toContain(`<video src="${MEDIA}AbCdEfGh12.mp4" poster="${MEDIA}PoStEr0001.jpg"`);
        expect(containerCalls).toEqual([]);
    });

    it("uses the post's custom title", async () => {
        db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, ?, ?)").run("SessionOne", "my clip", "k", 1);
        const html = await (await get(`${SHARE}AbCdEfGh12`)).text();
        expect(meta(html, "og:title")).toBe("my clip");
        expect(html).toContain("<title>my clip</title>");
    });

    it("also answers with the extension and a trailing slash, and HEAD has no body", async () => {
        expect((await get(`${SHARE}AbCdEfGh12.mp4`)).status).toBe(200);
        expect((await get(`${SHARE}AbCdEfGh12/`)).status).toBe(200);
        expect((await get(`${SHARE}AbCdEfGh12.webp`)).status).toBe(404);
        const head = await get(`${SHARE}AbCdEfGh12`, { method: "HEAD" });
        expect(head.status).toBe(200);
        expect(await head.text()).toBe("");
        expect((await get(`${SHARE}AbCdEfGh12`, { method: "POST" })).status).toBe(405);
    });

    it("is gone once the file is made private or deleted", async () => {
        db.raw.prepare("UPDATE media_items SET visibility = 'private'").run();
        expect((await get(`${SHARE}AbCdEfGh12`)).status).toBe(404);
        db.raw.prepare("UPDATE media_items SET visibility = 'public', deleted_at = 9").run();
        expect((await get(`${SHARE}AbCdEfGh12`)).status).toBe(404);
    });
});

describe("other files", () => {
    it("a webp in the public bucket is a large image card", async () => {
        row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", url: `${MEDIA}WeBpWeBp01.webp`, content_type: "image/webp", name: "clip.webp", duration: null });
        const html = await (await get(`${SHARE}WeBpWeBp01`)).text();
        expect(meta(html, "twitter:card")).toBe("summary_large_image");
        expect(meta(html, "og:image")).toBe(`${MEDIA}WeBpWeBp01.webp`);
        expect(meta(html, "og:image:type")).toBe("image/webp");
        expect(meta(html, "og:video")).toBeNull();
        expect(html).toContain(`<img src="${MEDIA}WeBpWeBp01.webp"`);
    });

    it("a webp switched private (bucket originals, public_key kept) has no page", async () => {
        row({ source: "webp", bucket: "originals", r2_key: "webps/WeBpWeBp02.webp", public_key: "WeBpWeBp02.webp", visibility: "private", content_type: "image/webp" });
        expect((await get(`${SHARE}WeBpWeBp02`)).status).toBe(404);
    });

    it("a private original, an unknown name, the root and odd paths are 404s", async () => {
        row({ r2_key: "originals/PrIvAtE001.mp4" });
        for (const p of ["PrIvAtE001", "originals", "NoSuchName", "", "a/b", "AbC", "../x", "PrIvAtE001.mp4.x"]) {
            expect((await get(`${SHARE}${p}`)).status, p).toBe(404);
        }
        expect(containerCalls).toEqual([]);
    });

    it("escapes the title", async () => {
        row({ visibility: "public", public_key: "EsCaPe0001.mp4", name: `"><script>alert(1)</script>` });
        const html = await (await get(`${SHARE}EsCaPe0001`)).text();
        expect(html).not.toContain("<script>");
        expect(html).toContain("&quot;&gt;&lt;script&gt;");
    });

    it("never uses a poster from another host", async () => {
        row({ visibility: "public", public_key: "PoStEr0002.mp4", poster: "https://evil.example/x.jpg" });
        const html = await (await get(`${SHARE}PoStEr0002`)).text();
        expect(meta(html, "og:image")).toBeNull();
        expect(html).not.toContain("evil.example");
    });

    it("robots may not index", async () => {
        expect(await (await get(`${SHARE}robots.txt`)).text()).toContain("Disallow: /");
    });
});

describe("wiring", () => {
    it("the API host is unchanged: a share path there goes through the gate", async () => {
        row({ visibility: "public", public_key: "AbCdEfGh12.mp4" });
        const res = await get("https://api.capybaraharmony.com/AbCdEfGh12");
        expect(res.headers.get("content-type") ?? "").not.toContain("text/html");
        expect(res.status).not.toBe(200);
    });

    it("GET /capabilities sends share_base_url, null when it is not set", async () => {
        const on = (await (await get("https://api.capybaraharmony.com/capabilities")).json()) as any;
        expect(on.share_base_url).toBe(SHARE);
        const off = (await (await get("https://api.capybaraharmony.com/capabilities", {}, { ...env, SHARE_BASE_URL: "" })).json()) as any;
        expect(off.share_base_url).toBeNull();
        const notHttps = (await (await get("https://api.capybaraharmony.com/capabilities", {}, { ...env, SHARE_BASE_URL: "http://share.capybaraharmony.com/" })).json()) as any;
        expect(notHttps.share_base_url).toBeNull();
    });

    it("shareUrlFor maps a public file URL to its page, and nothing else", () => {
        expect(shareUrlFor(`${MEDIA}AbCdEfGh12.mp4`, MEDIA, SHARE)).toBe(`${SHARE}AbCdEfGh12`);
        expect(shareUrlFor("https://elsewhere.example/AbCdEfGh12.mp4", MEDIA, SHARE)).toBeNull();
        expect(shareUrlFor(`${MEDIA}a/b.mp4`, MEDIA, SHARE)).toBeNull();
        expect(escapeHtml(`<&>"'`)).toBe("&lt;&amp;&gt;&quot;&#39;");
    });
});
