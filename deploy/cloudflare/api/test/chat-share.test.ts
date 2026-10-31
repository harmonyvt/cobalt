// Shared chats (APP-API-CONTRACT.md section 46): the /chat/threads/<id>/share routes and the share host's /c/<key> page,
// JSON and files. The Worker, the registry, the real handlers and the real SQL (node:sqlite) run together; R2 is in
// memory and the container is never reached.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { miniMarkdown } from "../src/chat-share-page";
import { scrubber } from "../src/chat-share";
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
const KEY = /^https:\/\/share\.capybaraharmony\.com\/c\/([A-Za-z0-9]{22})$/;
const THREAD = "ThReAd0123456789";

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let media: MemoryMedia;
let clock: number;

const container = {
    async fetch(r: Request) {
        await r.body?.cancel().catch(() => {});
        return Response.json({ status: "success" });
    },
};

const send = (url: string, init: RequestInit = {}) =>
    handleRequest(new Request(url, init), env, container, { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair });
const api = async (method: string, path: string, body?: unknown) => {
    const r = await send(`${API}${path}`, {
        method,
        headers: { ...AUTH, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, headers: r.headers, body: text ? (JSON.parse(text) as any) : null };
};
const share = (path: string, init: RequestInit = {}) => send(`${SHARE.replace(/\/$/, "")}${path}`, init);
const keyOf = (url: string) => KEY.exec(url)![1]!;
const one = (sql: string, ...p: unknown[]) => db.raw.prepare(sql).get(...(p as any[])) as any;
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
        link: null,
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

let msgId = 0;
function message(role: "user" | "assistant", text: string, o: { post_ids?: string[]; steps?: unknown[]; status?: string; updated_at?: number } = {}) {
    msgId++;
    db.raw
        .prepare(
            `INSERT INTO chat_messages (id, thread_id, role, text, post_ids, steps, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(msgId, THREAD, role, text, JSON.stringify(o.post_ids ?? []), JSON.stringify(o.steps ?? []), o.status ?? "done", 10_000 + msgId, o.updated_at ?? 10_000 + msgId);
    return msgId;
}

const VIDEO = bytes(1000, 3);
const IMAGE = bytes(300, 5);
const POSTER = bytes(50, 11);
let pubVideo: any, privImage: any, privVideo: any;

beforeEach(async () => {
    clock = 1_800_000_000_000;
    msgId = 0;
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
    pubVideo = row({ visibility: "public", public_key: "PuBlIcViD01.mp4", url: `${MEDIA}PuBlIcViD01.mp4`, poster: `${MEDIA}PoStEr0001.jpg`, name: "loaf.mp4" });
    originals.objects.set(pubVideo.r2_key, { bytes: VIDEO, contentType: "video/mp4", meta: {} });
    media.objects.set("PuBlIcViD01.mp4", { bytes: VIDEO.length, meta: {}, contentType: "video/mp4", data: VIDEO, viaStream: false } as any);
    privImage = row({ r2_key: "originals/photo1.jpg", name: "photo.jpg", content_type: "image/jpeg", duration: null, bytes: IMAGE.length, source: "upload" });
    originals.objects.set(privImage.r2_key, { bytes: IMAGE, contentType: "image/jpeg", meta: {} });
    privVideo = row({ name: "zoomies.mp4", poster: `${MEDIA}PoStEr0002.jpg` });
    originals.objects.set(privVideo.r2_key, { bytes: VIDEO, contentType: "video/mp4", meta: {} });
    media.objects.set("PoStEr0002.jpg", { bytes: POSTER.length, meta: {}, contentType: "image/jpeg", data: POSTER, viaStream: false } as any);

    db.raw.prepare("INSERT INTO chat_threads (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)").run(THREAD, "cat edits for friday", 9_000, 9_000);
    message("user", "find my best cat clips");
    message("assistant", "found 3 (=^･ω･^=) the **loaf** one is peak\nold link: https://share.capybaraharmony.com/p/AbCdEfGh1234567890ZzYy", {
        post_ids: [pubVideo.id, privVideo.id],
        steps: [
            {
                id: "s1",
                kind: "code",
                status: "done",
                code: "return await cobalt.library.search({ query: 'cat' })",
                logs: [],
                result: null,
                error: null,
                duration_ms: 1200,
                calls: [
                    {
                        op: "library.search",
                        ms: 340,
                        status: "done",
                        card: { type: "search", query: "cat", within: null, total: 3, hits: [pubVideo.id, privImage.id, privVideo.id].map((id) => ({ post_id: id, score: 0.9 })) },
                    },
                    { op: "links.private", ms: 20, status: "done", card: { type: "link", id: "x", url: "https://share.capybaraharmony.com/p/ZyXwVuTs9876543210AbCd", title: "secret", files: 1, private: true } },
                ],
            },
        ],
    });
});

describe("sharing a chat", () => {
    it("PUT shares it up to its latest message; the page shows the chat with its cards and files", async () => {
        expect((await api("GET", `/chat/threads/${THREAD}/share`)).body).toEqual({ status: "success", share: null });
        const r = await api("PUT", `/chat/threads/${THREAD}/share`);
        expect(r.status).toBe(201);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(r.body.share).toMatchObject({ thread_id: THREAD, upto_id: "2", messages: 2, behind: 0, files: 3, media: true, code: false, opened: 0 });
        expect(r.body.share.url).toMatch(KEY);
        const key = keyOf(r.body.share.url);
        // the same share again
        expect((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url).toBe(r.body.share.url);

        const page = await share(`/c/${key}`);
        expect(page.status).toBe(200);
        expect(page.headers.get("cache-control")).toBe("no-store");
        expect(page.headers.get("content-security-policy")).toContain("media-src https://share.capybaraharmony.com https://media.capybaraharmony.com");
        const html = await page.text();
        expect(html).toContain("<h1>cat edits for friday</h1>");
        expect(html).toContain('<meta property="og:title" content="cat edits for friday">');
        expect(html).toContain("find my best cat clips");
        expect(html).toContain("<b>loaf</b>");
        expect(html).toContain("&quot;cat&quot; · 3 found");
        expect(html).toContain(`<meta property="og:image" content="${MEDIA}PoStEr0001.jpg">`);
        // the public video plays from the media domain; the private one streams through the link, with its poster
        expect(html).toContain(`<video src="${MEDIA}PuBlIcViD01.mp4" poster="${MEDIA}PoStEr0001.jpg"`);
        expect(html).toContain(`<video src="${SHARE}c/${key}/2.mp4" poster="${SHARE}c/${key}/2.poster.jpg"`);
        // the private image is a thumbnail streamed through the link
        expect(html).toContain(`<img src="${SHARE}c/${key}/3.jpg"`);
        // code is off; a private link's key is never on the page
        expect(html).not.toContain("cobalt.library.search({");
        expect(html).not.toContain("AbCdEfGh1234567890ZzYy");
        expect(html).not.toContain("ZyXwVuTs9876543210AbCd");
        expect(html).toContain("[private link]");
        expect(html).not.toMatch(/<script/i);
        // the open was counted (GET, not HEAD)
        await share(`/c/${key}`, { method: "HEAD" });
        expect((await api("GET", `/chat/threads/${THREAD}/share`)).body.share).toMatchObject({ opened: 1, last_opened_at: clock });
    });

    it("streams the share's files with Range, and nothing else", async () => {
        const key = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        const whole = await share(`/c/${key}/3.jpg`);
        expect(whole.status).toBe(200);
        expect(whole.headers.get("content-type")).toBe("image/jpeg");
        expect(new Uint8Array(await whole.arrayBuffer())).toEqual(IMAGE);
        const part = await share(`/c/${key}/2.mp4`, { headers: { range: "bytes=0-9" } });
        expect(part.status).toBe(206);
        expect(new Uint8Array(await part.arrayBuffer())).toEqual(VIDEO.slice(0, 10));
        expect((await share(`/c/${key}/2.poster.jpg`)).status).toBe(200);
        // wrong extension, out of range, unknown key
        expect((await share(`/c/${key}/3.png`)).status).toBe(404);
        expect((await share(`/c/${key}/9.mp4`)).status).toBe(404);
        expect((await share(`/c/AbCdEfGh1234567890ZzYy/1.mp4`)).status).toBe(404);
        // a file deleted since is gone from the link
        db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(privImage.id);
        expect((await share(`/c/${key}/3.jpg`)).status).toBe(404);
    });

    it("a post hidden since leaves the page and its file stops streaming", async () => {
        const key = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, at) VALUES (?, 'hidden', 'you', 1)").run(privVideo.id);
        expect((await share(`/c/${key}/2.mp4`)).status).toBe(404);
        const html = await (await share(`/c/${key}`)).text();
        expect(html).not.toContain(`${SHARE}c/${key}/2.mp4`);
        expect(html).not.toContain("zoomies");
    });

    it("stays at the message it was shared at until updated", async () => {
        const key = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        message("user", "now make it snappy");
        // a reply still being written never counts
        message("assistant", "working on it", { status: "running", updated_at: clock });
        expect((await api("GET", `/chat/threads/${THREAD}/share`)).body.share).toMatchObject({ upto_id: "2", messages: 2, behind: 2 });
        expect(await (await share(`/c/${key}`)).text()).not.toContain("snappy");
        const up = await api("PUT", `/chat/threads/${THREAD}/share`, { upto: "latest" });
        expect(up.status).toBe(200);
        expect(up.body.share).toMatchObject({ upto_id: "3", behind: 1 });
        expect(up.body.share.url).toBe(`${SHARE}c/${key}`);
        const html = await (await share(`/c/${key}`)).text();
        expect(html).toContain("snappy");
        expect(html).not.toContain("working on it");
    });

    it("settings: media off shows titles only and streams nothing; code on shows the code folded", async () => {
        const key = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`, { media: false, code: true })).body.share.url);
        const html = await (await share(`/c/${key}`)).text();
        expect(html).not.toContain("<video");
        expect(html).toContain("<details class=\"step\">");
        expect(html).toContain("cobalt.library.search({ query: &#39;cat&#39; })");
        expect((await share(`/c/${key}/2.mp4`)).status).toBe(404);
        const on = await api("PUT", `/chat/threads/${THREAD}/share`, { media: true });
        expect(on.body.share).toMatchObject({ media: true, code: true });
        expect((await share(`/c/${key}/2.mp4`)).status).toBe(200);
        expect((await api("PUT", `/chat/threads/${THREAD}/share`, { media: "yes" })).status).toBe(400);
    });

    it("rotate makes a new key and kills the old one; DELETE stops sharing; deleting the chat does too", async () => {
        const old = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        const r = await api("POST", `/chat/threads/${THREAD}/share/rotate`);
        expect(r.status).toBe(200);
        const key = keyOf(r.body.share.url);
        expect(key).not.toBe(old);
        expect((await share(`/c/${old}`)).status).toBe(404);
        expect((await share(`/c/${key}`)).status).toBe(200);
        expect((await share(`/c/${key}/2.mp4`)).status).toBe(200);

        expect((await api("DELETE", `/chat/threads/${THREAD}/share`)).body).toEqual({ status: "success" });
        expect((await share(`/c/${key}`)).status).toBe(404);
        expect((await api("GET", `/chat/threads/${THREAD}/share`)).body.share).toBeNull();
        expect((await api("DELETE", `/chat/threads/${THREAD}/share`)).status).toBe(404);
        expect((await api("POST", `/chat/threads/${THREAD}/share/rotate`)).status).toBe(404);

        const again = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        expect(again).not.toBe(key);
        db.raw.prepare("DELETE FROM chat_messages WHERE thread_id = ?").run(THREAD);
        db.raw.prepare("DELETE FROM chat_threads WHERE id = ?").run(THREAD);
        expect((await share(`/c/${again}`)).status).toBe(404);
        expect(one("SELECT COUNT(*) AS n FROM chat_shares WHERE revoked_at IS NULL").n).toBe(1);
    });

    it("an unknown chat is a 404; an empty one is a 409", async () => {
        expect((await api("PUT", `/chat/threads/AbCdEfGh12345678/share`)).status).toBe(404);
        db.raw.prepare("INSERT INTO chat_threads (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)").run("EmPtY01234567890", "empty", 1, 1);
        expect((await api("PUT", `/chat/threads/EmPtY01234567890/share`)).body.error.code).toBe("error.chat_share.empty");
    });

    it("chat.json is the transcript the page is drawn from", async () => {
        const key = keyOf((await api("PUT", `/chat/threads/${THREAD}/share`)).body.share.url);
        const r = await share(`/c/${key}/chat.json`);
        expect(r.status).toBe(200);
        expect(r.headers.get("access-control-allow-origin")).toBe("*");
        const t = (await r.json()) as any;
        expect(t).toMatchObject({ version: 1, thread: { id: THREAD, title: "cat edits for friday", url: `${SHARE}c/${key}` }, media: true, code: false });
        expect(t.counts).toEqual({ messages: 2, videos: 2, pictures: 1 });
        expect(t.messages.map((m: any) => m.role)).toEqual(["user", "assistant"]);
        expect(t.messages[1].steps[0].calls[1].card.url).toBe("");
        expect(t.posts[privVideo.id].file).toMatchObject({ n: 2, type: "video", url: `${SHARE}c/${key}/2.mp4` });
    });
});

describe("page helpers", () => {
    it("miniMarkdown escapes everything and allows only a few safe things", () => {
        expect(miniMarkdown("<script>x</script> **hi** `a<b` [t](javascript:alert(1)) https://x.y/z")).toBe(
            '<p>&lt;script&gt;x&lt;/script&gt; <b>hi</b> <code>a&lt;b</code> [t](javascript:alert(1)) <a href="https://x.y/z" rel="noopener nofollow">https://x.y/z</a></p>',
        );
        expect(miniMarkdown("a\n- one\n- two\n\nb")).toBe("<p>a</p><ul><li>one</li><li>two</li></ul><p>b</p>");
    });
    it("scrubber hides private and shared-chat keys only", () => {
        const s = scrubber(SHARE);
        expect(s("see https://share.capybaraharmony.com/p/AbCdEfGh1234567890ZzYy/1.mp4 and share.capybaraharmony.com/c/AbCdEfGh1234567890ZzYy")).toBe(
            "see [private link] and [private link]",
        );
        expect(s("https://share.capybaraharmony.com/AbCdEf12")).toBe("https://share.capybaraharmony.com/AbCdEf12");
    });
});
