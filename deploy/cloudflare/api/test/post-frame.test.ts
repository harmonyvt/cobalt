// Post frames (APP-API-CONTRACT.md section 52): the details lookups (pure parsing and with fake sites), the routes, and a
// 'post' render through the editor's step machine.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
    backfillPostDetails,
    detailsShape,
    ensureDetails,
    merge,
    parseOpenGraph,
    parsePatch,
    parseXEmbed,
    parseYtInfo,
    refreshDetails,
    siteOf,
    twitchRef,
    xStatusId,
    xToken,
    type LookupDeps,
    type YtInfo,
} from "../src/post-details";
import { buildPostSpec, parsePostFrameOptions, postSpecInputs, postStartSpec, queuePostFrame, type PostItemRow } from "../src/post-frame";
import { KEY_ID, MEDIA_BASE, coreWorld, ids, world, type CoreWorld } from "./edits-world";

const XLINK = "https://x.com/mochibytes/status/1987000000000000001";
const X_EMBED = {
    text: "the cat learned to open the fridge &amp; now we live in fear https://t.co/AbCdEf",
    display_text_range: [0, 59],
    created_at: "2026-11-08T10:00:00.000Z",
    favorite_count: 18000,
    conversation_count: 312,
    user: { name: "mochi", screen_name: "mochibytes", profile_image_url_https: "https://pbs.twimg.com/profile_images/1/a_normal.jpg", is_blue_verified: true },
};

describe("sites and links (52.4)", () => {
    it("names the style from the host, generic otherwise", () => {
        expect(siteOf("https://twitter.com/a/status/1").site).toBe("x");
        expect(siteOf("https://www.instagram.com/reel/abc/").site).toBe("instagram");
        expect(siteOf("https://clips.twitch.tv/FunnySlug").site).toBe("twitch");
        expect(siteOf("https://youtu.be/xyz").site).toBe("youtube");
        expect(siteOf("https://vimeo.com/1")).toEqual({ site: "generic", host: "vimeo.com" });
        expect(siteOf("not a url")).toEqual({ site: "generic", host: null });
    });

    it("reads an X post id and computes its embed token; finds Twitch clips and VODs", () => {
        expect(xStatusId(XLINK)).toBe("1987000000000000001");
        expect(xStatusId("https://x.com/home")).toBeNull();
        expect(xToken("1987000000000000001")).toMatch(/^[0-9a-z]+$/);
        expect(twitchRef("https://www.twitch.tv/pixelmaru/clip/FunnySlug-abc?x=1")).toEqual({ clip: "FunnySlug-abc" });
        expect(twitchRef("https://clips.twitch.tv/FunnySlug")).toEqual({ clip: "FunnySlug" });
        expect(twitchRef("https://www.twitch.tv/videos/12345")).toEqual({ video: "12345" });
        expect(twitchRef("https://www.twitch.tv/pixelmaru")).toBeNull();
    });
});

describe("parsing (52.1)", () => {
    it("X's embed lookup: the text without its media link, the big avatar, the counts", () => {
        expect(parseXEmbed(X_EMBED)).toEqual({
            name: "mochi",
            handle: "@mochibytes",
            text: "the cat learned to open the fridge & now we live in fear",
            posted_at: Date.parse("2026-11-08T10:00:00.000Z"),
            counts: { likes: 18000, replies: 312 },
            verified: true,
            avatar: "https://pbs.twimg.com/profile_images/1/a_400x400.jpg",
        });
        expect(parseXEmbed({})).toBeNull();
    });

    it("yt-dlp's info per site", () => {
        const info: YtInfo = { uploader: "Tofu", channel: "tofu.the.shiba", description: "walk", timestamp: 1762400000, like_count: 24118, comment_count: 381 };
        expect(parseYtInfo("instagram", info)).toMatchObject({ name: "Tofu", handle: "tofu.the.shiba", text: "walk", posted_at: 1762400000000, counts: { likes: 24118, comments: 381 } });
        const yt = parseYtInfo("youtube", { channel: "Little Builds", uploader_id: "@littlebuilds", title: "tiny city", upload_date: "20241027", view_count: 2300000, channel_follower_count: 1200000 });
        expect(yt).toMatchObject({ channel: "Little Builds", handle: "@littlebuilds", title: "tiny city", posted_at: Date.UTC(2024, 9, 27), counts: { views: 2300000, subscribers: 1200000 } });
        expect(parseYtInfo("twitch", { uploader: "pixelmaru", creator: "nightowl", title: "no way", view_count: 5 })).toMatchObject({ name: "pixelmaru", clipper: "nightowl", title: "no way", counts: { views: 5 } });
        expect(parseYtInfo("x", { uploader: "mochi", uploader_id: "mochibytes", comment_count: 3 })).toMatchObject({ handle: "@mochibytes", counts: { replies: 3 } });
        expect(parseYtInfo("generic", null)).toBeNull();
    });

    it("Open Graph tags in either attribute order, entities decoded", () => {
        const og = parseOpenGraph(`<meta property="og:title" content="Lights &amp; lake"><meta content="Vimeo" property="og:site_name"><meta name="twitter:description" content="no edits">`);
        expect(og).toEqual({ "og:title": "Lights & lake", "og:site_name": "Vimeo", "twitter:description": "no edits" });
    });

    it("merge fills only what is missing, counts key by key", () => {
        expect(merge({ name: "a", counts: { likes: 1 } }, { name: "b", text: "t", counts: { likes: 9, views: 2 } })).toEqual({ name: "a", text: "t", counts: { likes: 1, views: 2 } });
    });

    it("PATCH bodies: known fields only, sizes capped, empty clears", () => {
        expect(parsePatch({ name: " mochi ", text: "", posted_at: 5 })).toEqual({ ok: true, patch: { name: "mochi", text: null, posted_at: 5 } });
        expect(parsePatch({ avatar_key: "x" })).toEqual({ ok: false, path: "avatar_key" });
        expect(parsePatch({ text: "x".repeat(4001) })).toEqual({ ok: false, path: "text" });
        expect(parsePatch({ posted_at: "yesterday" })).toEqual({ ok: false, path: "posted_at" });
        expect(parsePatch([])).toEqual({ ok: false, path: "" });
    });
});

// a fake web: answers by URL prefix
function fakeFetch(routes: Record<string, () => Response>) {
    const calls: string[] = [];
    const fn = async (input: string) => {
        calls.push(input);
        for (const [prefix, answer] of Object.entries(routes)) if (input.startsWith(prefix)) return answer();
        return new Response("nope", { status: 404 });
    };
    return { fn, calls };
}
const jsonRes = (b: unknown) => new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const jpeg = () => new Response(new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3]), { headers: { "content-type": "image/jpeg" } });

describe("lookups and the stored row", () => {
    let w: ReturnType<typeof world>;
    beforeEach(() => {
        w = world();
    });
    const deps = (fetchFn: (u: string) => Promise<Response>, yt: YtInfo | null = null, over: Partial<LookupDeps> = {}): LookupDeps => ({
        db: w.db,
        originals: w.originals,
        fetch: fetchFn,
        ytdlpInfo: async () => yt,
        twitch: null,
        now: w.clock.now,
        ...over,
    });

    it("X: the embed lookup, yt-dlp for the views, the avatar copied into originals", async () => {
        const f = fakeFetch({ "https://cdn.syndication.twimg.com/": () => jsonRes(X_EMBED), "https://pbs.twimg.com/": jpeg });
        const row = await refreshDetails(deps(f.fn, { view_count: 402000, repost_count: 2100 }), XLINK);
        expect(row).toMatchObject({ site: "x", found: 1, name: "mochi", handle: "@mochibytes", verified: 1 });
        expect(JSON.parse(row.counts!)).toEqual({ likes: 18000, replies: 312, views: 402000, reposts: 2100 });
        expect(row.avatar_key).toMatch(/^post-avatars\/[0-9a-f]{64}$/);
        expect(w.originals.objects.get(row.avatar_key!)?.contentType).toBe("image/jpeg");
        expect(f.calls[0]).toContain(`token=${xToken("1987000000000000001")}`);
        const shaped = detailsShape(row, "https://api/x/avatar");
        expect(shaped).toMatchObject({ found: true, verified: true, avatar_url: "https://api/x/avatar", edited: false });
    });

    it("nothing found: a row with found 0 stops repeat lookups for a day; an avatar that is not a picture is not kept", async () => {
        let looked = 0;
        const d = deps(fakeFetch({}).fn, null, { ytdlpInfo: async () => (looked++, null) });
        const row = await ensureDetails(d, "https://www.instagram.com/reel/abc/");
        expect(row).toMatchObject({ site: "instagram", found: 0, avatar_key: null });
        await ensureDetails(d, "https://www.instagram.com/reel/abc/");
        expect(looked).toBe(1);
        w.clock.t += 25 * 3600 * 1000;
        await ensureDetails(d, "https://www.instagram.com/reel/abc/");
        expect(looked).toBe(2);
    });

    it("Harmony's edits survive a refresh; a refresh fills what is still empty", async () => {
        const link = "https://vimeo.com/1";
        const d = deps(fakeFetch({}).fn, { uploader: "Aurora", title: "lights" });
        await refreshDetails(d, link);
        const { patchDetails } = await import("../src/post-details");
        await patchDetails(w.db, link, { name: "Aurora Notes", text: null }, w.clock.now());
        const again = await refreshDetails(deps(fakeFetch({}).fn, { uploader: "Someone", title: "other", description: "desc" }), link);
        expect(again).toMatchObject({ name: "Aurora Notes", title: "lights", text: "desc" });
        expect(again.edited_at).not.toBeNull();
    });

    it("YouTube's avatar comes from the channel page; Twitch adds the game and avatar with its app login", async () => {
        const yt = fakeFetch({
            "https://www.youtube.com/@littlebuilds": () => new Response(`<meta property="og:image" content="https://yt3.example/av.jpg">`, { headers: { "content-type": "text/html" } }),
            "https://yt3.example/": jpeg,
        });
        const row = await refreshDetails(deps(yt.fn, { channel: "Little Builds", channel_url: "https://www.youtube.com/@littlebuilds", title: "t" }), "https://youtu.be/abc");
        expect(row.avatar_key).not.toBeNull();
        const tw = fakeFetch({
            "https://id.twitch.tv/oauth2/token": () => jsonRes({ access_token: "tok" }),
            "https://api.twitch.tv/helix/clips": () => jsonRes({ data: [{ broadcaster_id: "9", broadcaster_name: "pixelmaru", creator_name: "nightowl", game_id: "5", title: "no way", view_count: 58204, created_at: "2026-11-04T00:00:00Z" }] }),
            "https://api.twitch.tv/helix/users": () => jsonRes({ data: [{ login: "pixelmaru", profile_image_url: "https://static-cdn.example/a.png" }] }),
            "https://api.twitch.tv/helix/games": () => jsonRes({ data: [{ name: "Just Chatting" }] }),
            "https://static-cdn.example/": jpeg,
        });
        const t = await refreshDetails(deps(tw.fn, null, { twitch: { clientId: "c", clientSecret: "s" } }), "https://clips.twitch.tv/FunnySlug");
        expect(t).toMatchObject({ site: "twitch", found: 1, name: "pixelmaru", handle: "pixelmaru", clipper: "nightowl", game: "Just Chatting", title: "no way" });
        expect(t.avatar_key).not.toBeNull();
    });

    it("the cron looks up recent saved videos without a row, at most `limit`", async () => {
        w.addItem({ id: ids.a });
        w.addItem({ id: ids.b });
        w.addItem({ id: ids.photo, contentType: "image/jpeg" });
        w.db.raw.prepare("UPDATE media_items SET link = 'https://vimeo.com/' || id").run();
        const d = deps(fakeFetch({}).fn, { uploader: "someone" });
        expect(await backfillPostDetails(d, { limit: 1, hours: 48 })).toEqual({ looked: 1, found: 1 });
        expect(await backfillPostDetails(d, { limit: 5, hours: 48 })).toEqual({ looked: 1, found: 1 });
        expect(await backfillPostDetails(d, { limit: 5, hours: 48 })).toEqual({ looked: 0, found: 0 });
        expect(await backfillPostDetails(d, { limit: 0, hours: 48 })).toEqual({ looked: 0, found: 0 });
    });
});

describe("the frame's options and spec (52.2, 52.5)", () => {
    it("checks the body: defaults, bad keys named", () => {
        const ok = parsePostFrameOptions({});
        expect(ok).toEqual({ ok: true, options: { style: null, theme: "dark", canvas: "fit", show: { avatar: true, text: true, counts: true, time: true }, from: null, to: null, details: {}, notify: false } });
        expect(parsePostFrameOptions({ style: "tiktok" })).toEqual({ ok: false, path: "style" });
        expect(parsePostFrameOptions({ show: { likes: false } })).toEqual({ ok: false, path: "show.likes" });
        expect(parsePostFrameOptions({ from: 5, to: 2 })).toEqual({ ok: false, path: "to" });
        expect(parsePostFrameOptions({ details: { avatar: "x" } })).toEqual({ ok: false, path: "details.avatar" });
        expect(parsePostFrameOptions({ zoom: 2 })).toEqual({ ok: false, path: "zoom" });
    });

    const item: PostItemRow = { id: ids.a, bucket: "originals", r2_key: `originals/${ids.a}.bin`, bytes: 1500, content_type: "video/mp4", width: 1080, height: 1920, duration: 12, link: XLINK, name: "a.mp4", deleted_at: null };

    it("freezes the details with this render's overrides, the avatar as input 1", () => {
        const row = {
            link: XLINK, site: "x" as const, found: 1, name: "mochi", handle: "@mochibytes", text: "fridge", title: null, channel: null, game: null, clipper: null, site_name: null,
            posted_at: 5, counts: '{"likes":3}', verified: 1, avatar_key: "post-avatars/abc", fetched_at: 1, edited_at: null,
        };
        const p = parsePostFrameOptions({ theme: "light", canvas: "portrait", from: 1, to: 2000, details: { text: "my words", name: null } });
        if (!p.ok) throw new Error("bad");
        const spec = buildPostSpec(item, row, p.options);
        expect(spec).toMatchObject({ kind: "post", style: "x", theme: "light", canvas: "portrait", from: 1, to: 601, host: "x.com", video: { width: 1080, height: 1920 } });
        expect(spec.details).toEqual({ handle: "@mochibytes", text: "my words", posted_at: 5, verified: true, counts: { likes: 3 } });
        expect(spec.inputs).toEqual([
            { n: 0, item: ids.a, bucket: "originals", key: `originals/${ids.a}.bin`, bytes: 1500, kind: "video" },
            { n: 1, item: ids.a, bucket: "originals", key: "post-avatars/abc", bytes: 0, kind: "photo" },
        ]);
        expect(postSpecInputs(JSON.stringify(spec))).toEqual(spec.inputs);
        expect(postSpecInputs(JSON.stringify({ ...spec, inputs: [] }))).toBeNull();
        expect(postStartSpec(spec)).not.toHaveProperty("inputs");
        const generic = buildPostSpec({ ...item, link: null }, null, { ...p.options, style: null });
        expect(generic.style).toBe("generic");
        expect(generic.inputs).toHaveLength(1);
    });

    it("queues a 'post' render for a video only", async () => {
        const w = world();
        await w.addKey();
        let kicks = 0;
        const d = { db: w.db, mediaBaseUrl: MEDIA_BASE, now: w.clock.now, keyId: KEY_ID, kick: async () => void (kicks += 1) };
        const p = parsePostFrameOptions({});
        if (!p.ok) throw new Error("bad");
        const r = await queuePostFrame(d, item, null, p.options, "fridge cat");
        expect(r.status).toBe(202);
        expect((r.body as any).render).toMatchObject({ kind: "post", project_id: `post:${ids.a}`, title: "fridge cat (post)", status: "queued" });
        expect(kicks).toBe(1);
        expect((await queuePostFrame(d, { ...item, content_type: "image/jpeg" }, null, p.options, "x")).body).toMatchObject({ error: { code: "error.post.not_video" } });
    });
});

describe("the routes (52.2)", () => {
    let w: ReturnType<typeof world>;
    beforeEach(async () => {
        w = world();
        await w.addKey();
        w.seedLibrary();
        w.db.raw.prepare("UPDATE media_items SET link = ?1 WHERE id = ?2").run(XLINK, ids.a);
        const f = fakeFetch({ "https://cdn.syndication.twimg.com/": () => jsonRes(X_EMBED), "https://pbs.twimg.com/": jpeg });
        vi.stubGlobal("fetch", f.fn);
    });
    afterEach(() => vi.unstubAllGlobals());

    it("reads (looking up), serves the avatar, saves an edit, and frames", async () => {
        const r = await w.api("GET", `/library/items/${ids.a}/post-details`);
        expect(r.status).toBe(200);
        expect(r.json.details).toMatchObject({ site: "x", name: "mochi", handle: "@mochibytes", avatar_url: `https://api.capybaraharmony.com/library/items/${ids.a}/post-details/avatar`, edited: false });
        const av = await w.api("GET", `/library/items/${ids.a}/post-details/avatar`);
        expect(av.status).toBe(200);
        expect(av.res.headers.get("content-type")).toBe("image/jpeg");
        const e = await w.api("PATCH", `/library/items/${ids.a}/post-details`, { text: "fixed words" });
        expect(e.json.details).toMatchObject({ text: "fixed words", edited: true });
        expect((await w.api("PATCH", `/library/items/${ids.a}/post-details`, { zzz: 1 })).json).toMatchObject({ error: { code: "error.post.bad_request" }, path: "zzz" });
        const fr = await w.api("POST", `/library/items/${ids.a}/post-frame`, { theme: "light" });
        expect(fr.status).toBe(202);
        expect(fr.json.render).toMatchObject({ kind: "post", status: "queued" });
        const spec = JSON.parse((w.db.raw.prepare("SELECT timeline FROM edit_renders WHERE id = ?").get(fr.json.render.id) as any).timeline);
        expect(spec.details.text).toBe("fixed words");
        expect(spec.inputs).toHaveLength(2);
    });

    it("unknown item 404, no link 409, a picture 409, bad body 400", async () => {
        expect((await w.api("GET", "/library/items/ZZZZZZZZZZZZZZZZ/post-details")).status).toBe(404);
        expect((await w.api("GET", `/library/items/${ids.b}/post-details`)).json).toMatchObject({ error: { code: "error.post.no_link" } });
        w.db.raw.prepare("UPDATE media_items SET link = ?1 WHERE id = ?2").run(XLINK, ids.photo);
        expect((await w.api("POST", `/library/items/${ids.photo}/post-frame`, {})).json).toMatchObject({ error: { code: "error.post.not_video" } });
        expect((await w.api("POST", `/library/items/${ids.a}/post-frame`, "{nope")).status).toBe(400);
        // an upload without a link can still be framed with a style and typed details
        expect((await w.api("POST", `/library/items/${ids.b}/post-frame`, { style: "generic", details: { name: "me" } })).status).toBe(202);
    });
});

describe("a 'post' render through the step machine", () => {
    let cw: CoreWorld;
    beforeEach(async () => {
        cw = coreWorld();
        await cw.addKey();
        cw.seedLibrary();
        cw.clock.t += 1000;
    });

    const spec = (avatarKey: string | null) => {
        const p = parsePostFrameOptions({ canvas: "square" });
        if (!p.ok) throw new Error("bad");
        const item: PostItemRow = { id: ids.a, bucket: "originals", r2_key: `originals/${ids.a}.bin`, bytes: 1500, content_type: "video/mp4", width: 1080, height: 1920, duration: 12, link: XLINK, name: "a.mp4", deleted_at: null };
        const row = avatarKey
            ? { link: XLINK, site: "x" as const, found: 1, name: "mochi", handle: null, text: null, title: null, channel: null, game: null, clipper: null, site_name: null, posted_at: null, counts: null, verified: 0, avatar_key: avatarKey, fetched_at: 1, edited_at: null }
            : null;
        return buildPostSpec(item, row, p.options);
    };

    it("streams the video (and skips an avatar that is gone), starts with {post}, files the mp4 as a post frame", async () => {
        const s = spec("post-avatars/gone");
        const id = cw.queueRender({ kind: "post", project_id: `post:${ids.a}`, revision: 0, title: "fridge (post)", timeline: s, seconds_total: 12 });
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.row(id)).toMatchObject({ status: "done", error_code: null });
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toEqual(["PUT /renders/<rid>/inputs/0"]);
        const made = cw.db.raw.prepare("SELECT * FROM media_items WHERE source = 'studio'").get() as any;
        expect(JSON.parse(made.made_spec)).toEqual({ kind: "post", item: ids.a, style: "x", render: id });
        expect(JSON.parse(made.made_from)).toEqual([ids.a]);
        expect(made.name).toBe("fridge (post).mp4");
    });

    it("the start body is the spec without its inputs", async () => {
        cw.originals.objects.set("post-avatars/abc", { bytes: new Uint8Array([1, 2, 3]), contentType: "image/jpeg", meta: {} });
        const s = spec("post-avatars/abc");
        const id = cw.queueRender({ kind: "post", project_id: `post:${ids.a}`, revision: 0, title: "fridge (post)", timeline: s });
        const core = cw.makeCore("r0");
        for (let i = 0; i < 20 && cw.row(id).status !== "rendering"; i++) {
            await core.tick();
            cw.clock.t += 5000;
        }
        const st = cw.container.renders.get(id)!;
        expect(st.started).toEqual({ post: postStartSpec(s), inputs: [{ n: 0, item: ids.a, kind: "video" }, { n: 1, item: ids.a, kind: "photo" }] });
    });

    it("a video that is gone ends the render as source_missing", async () => {
        cw.originals.objects.delete(`originals/${ids.a}.bin`);
        const id = cw.queueRender({ kind: "post", project_id: `post:${ids.a}`, revision: 0, title: "x", timeline: spec(null) });
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.source_missing" });
    });
});
