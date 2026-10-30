// Hidden posts and auto-hide rules (APP-API-CONTRACT.md section 37): hiding and unhiding, the bulk status route, what a
// hidden post is left out of and what refuses it, the rules (matching, the routes, apply and preview), a save that a rule
// hides before it is ever public, the `held` flow of about rules, and a database without migration 0025. The Worker, the
// Durable Object's services and the real SQL (node:sqlite) run together; the helper and both R2 buckets are fakes.
import { beforeEach, describe, expect, it } from "vitest";
import { HELD_GIVE_UP_MS, normalizeRuleValue, releaseHeld, ruleMatches, type PostFacts } from "../src/hidden";
import { HOST_URL, INTERNAL, KEY_ID, LINK, MEDIA_BASE, asBody, auth, json, world, type World } from "./poster-world";

const SHARE = "https://share.capybaraharmony.com/";

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
});

type Res = { status: number; body: any };
const api = async (method: string, path: string, body?: unknown, headers: Record<string, string> = auth): Promise<Res> => {
    const r = await w.call(path, {
        method,
        headers: { ...headers, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, body: text ? JSON.parse(text) : null };
};
const lib = async (q = "v=3") => (await api("GET", `/library?${q}`)).body;
const one = (sql: string, ...p: unknown[]) => w.db.raw.prepare(sql).get(...(p as any[])) as any;
const all = (sql: string, ...p: unknown[]) => w.db.raw.prepare(sql).all(...(p as any[])) as any[];
const hiddenRow = (key: string) => one("SELECT post_key, state, by, rule_id FROM media_hidden WHERE post_key = ?", key);
const mirrors = () => [...w.media.objects.keys()].filter((k) => !k.endsWith(".jpg"));

// A saved post, made public by `public: true` at save. Returns its session id (the post key) and its original's row.
async function publicPost(link = LINK) {
    const sid = asBody(await w.studio.create(KEY_ID, json({ url: link, public: true }))).id as string;
    const done = asBody(await w.settle(sid));
    expect(done.public_url).toMatch(HOST_URL);
    return { sid, item: w.items().find((i) => i.session_id === sid && i.source === "saved")! };
}
async function privatePost(link = LINK) {
    const sid = asBody(await w.studio.create(KEY_ID, json({ url: link }))).id as string;
    await w.settle(sid);
    return { sid, item: w.items().find((i) => i.session_id === sid && i.source === "saved")! };
}
const status = (ids: string[], s: string) => api("POST", "/library/status", { ids, status: s });
const addRule = (body: Record<string, unknown>) => api("POST", "/hidden/rules", body);
const heldDeps = () => ({
    db: w.db as unknown as D1Database,
    vis: { db: w.db as unknown as D1Database, originals: w.originals, media: w.media, mediaBaseUrl: MEDIA_BASE, now: w.clock.now },
    now: w.clock.now,
    keyId: "cron:hidden",
});

describe("hiding a post by hand (POST /library/status)", () => {
    it("turns every file off first, then the post is out of the library, its counts and its search; hidden=1 lists it", async () => {
        const a = await publicPost();
        const b = await privatePost("https://www.tiktok.com/@cat/video/1");
        expect(mirrors()).toHaveLength(1);
        const r = await status([a.sid], "hidden");
        expect(r.status).toBe(200);
        expect(r.body.failed).toEqual([]);
        expect(r.body.posts).toHaveLength(1);
        expect(r.body.posts[0]).toMatchObject({ id: a.sid, post_key: a.sid, status: "hidden" });
        expect(r.body.posts[0].files[0]).toMatchObject({ id: a.item.id, visibility: "private", url: null, private_url: null });
        // section 16 OFF: the public copy is gone and the row says private
        expect(mirrors()).toEqual([]);
        expect(w.item(a.item.id)).toMatchObject({ visibility: "private", url: null });
        expect(hiddenRow(a.sid)).toEqual({ post_key: a.sid, state: "hidden", by: "you", rule_id: null });

        const l = await lib();
        expect(l.posts.map((p: any) => p.id)).toEqual([b.sid]);
        expect(l.posts[0]).toMatchObject({ hidden: false, hidden_by: null, hidden_rule: null });
        expect(l.counts).toEqual({ posts: 1, files: 1, hidden: 1 });
        // the legacy and v=2 shapes leave it out too
        expect((await lib("")).posts.map((p: any) => p.id)).toEqual([b.sid]);
        expect((await lib("v=2")).posts.map((p: any) => p.id)).toEqual([b.sid]);

        const h = await lib("v=3&hidden=1");
        expect(h.posts.map((p: any) => p.id)).toEqual([a.sid]);
        expect(h.posts[0]).toMatchObject({ hidden: true, hidden_by: "you", hidden_rule: null });
        expect(h.posts[0].files).toHaveLength(1);
        expect((await api("GET", "/library?hidden=2")).status).toBe(400);
        // the file's bytes still answer (the app opens a hidden post from the album)
        expect((await w.call(`/library/items/${a.item.id}/file`, { headers: auth })).status).toBe(200);
    });

    it("nothing can share it: visibility on, legacy publish, the session publish, a private link, a gallery link", async () => {
        w.env.SHARE_BASE_URL = SHARE;
        const a = await publicPost();
        const b = await publicPost("https://x.com/other/status/2");
        await status([a.sid], "hidden");
        const refused = { status: "error", error: { code: "error.hidden" } };
        expect(await api("PATCH", `/library/items/${a.item.id}/visibility`, { public: true })).toEqual({ status: 409, body: refused });
        expect(await api("PATCH", `/library/items/${a.item.id}/visibility`, { public: true, scope: "post" })).toEqual({ status: 409, body: refused });
        expect((await api("POST", `/library/items/${a.item.id}/publish`)).body).toEqual(refused);
        expect((await api("POST", `/studio/${a.sid}/publish`)).body).toEqual(refused);
        expect(await api("PUT", `/share/private/items/${a.item.id}`)).toEqual({ status: 409, body: refused });
        const set = await api("POST", "/share/sets", { items: [b.item.id, a.item.id] });
        expect(set).toEqual({ status: 409, body: { ...refused, ids: [a.item.id] } });
        expect(w.item(a.item.id)).toMatchObject({ visibility: "private", url: null });
        expect(mirrors()).toHaveLength(1);
        // turning it off still works (it is off already)
        expect((await api("PATCH", `/library/items/${a.item.id}/visibility`, { public: false })).status).toBe(200);
    });

    it("a gallery link treats a hidden file as deleted: the public page drops it, the list marks it", async () => {
        w.env.SHARE_BASE_URL = SHARE;
        const a = await publicPost();
        const b = await publicPost("https://x.com/b/status/2");
        const c = await publicPost("https://x.com/c/status/3");
        const set = await api("POST", "/share/sets", { items: [a.item.id, b.item.id, c.item.id] });
        expect(set.status).toBe(201);
        await status([a.sid], "hidden");
        const list = await api("GET", "/share/sets");
        const items = list.body.sets[0].items;
        expect(items[0]).toMatchObject({ id: a.item.id, url: null, hidden: true });
        expect(items[1].hidden).toBeUndefined();
        const page = await w.call(`/g/${set.body.set.id}`, {});
        // (the share host is its own origin; the API host has no /g/ route)
        expect(page.status).toBe(404);
        const share = await (await import("../src/worker")).handleRequest(new Request(`${SHARE}g/${set.body.set.id}`), w.env, w.container, { now: w.clock.now, sleep: w.clock.sleep });
        const html = await share.text();
        expect(share.status).toBe(200);
        expect(html).not.toContain(a.item.public_key);
        expect(html).toContain(b.item.public_key ?? w.item(b.item.id).public_key);
        // rerolling a collection that holds it is refused
        const col = await api("POST", "/share/collections", { name: "c", set_ids: [set.body.set.id] });
        expect(col.status).toBe(201);
        const reroll = await api("POST", `/share/collections/${col.body.collection.id}/reroll`);
        expect(reroll).toEqual({ status: 409, body: { status: "error", error: { code: "error.hidden" }, ids: [a.item.id] } });
    });

    it("off unhides (exempt): files stay off, the post is back, and no rule hides it again", async () => {
        const a = await publicPost();
        await status([a.sid], "hidden");
        const r = await status([a.item.id], "off"); // a file id names its post
        expect(r.body.posts[0]).toMatchObject({ id: a.item.id, post_key: a.sid, status: "off" });
        expect(hiddenRow(a.sid)).toMatchObject({ state: "exempt", by: "you" });
        expect(mirrors()).toEqual([]);
        expect((await lib()).posts.map((p: any) => p.id)).toEqual([a.sid]);
        const rule = await addRule({ kind: "site", value: "x.com", apply: true });
        expect(rule.status).toBe(201);
        expect(rule.body.applied).toBe(0);
        expect(hiddenRow(a.sid).state).toBe("exempt");
        // by hand it can still be hidden again
        await status([a.sid], "hidden");
        expect(hiddenRow(a.sid).state).toBe("hidden");
    });

    it("public and private unhide and share; unknown ids and posts with nothing to toggle go to failed", async () => {
        w.env.SHARE_BASE_URL = SHARE;
        const a = await privatePost();
        const b = await privatePost("https://x.com/b/status/2");
        await status([a.sid, b.sid], "hidden");
        const pub = await status([a.sid, "nope"], "public");
        expect(pub.body.failed).toEqual([{ id: "nope", error: "error.library.not_found" }]);
        expect(pub.body.posts[0].files[0]).toMatchObject({ visibility: "public" });
        expect(pub.body.posts[0].files[0].url).toMatch(HOST_URL);
        expect(hiddenRow(a.sid).state).toBe("exempt");
        const priv = await status([b.sid], "private");
        expect(priv.body.posts[0].files[0]).toMatchObject({ visibility: "private", url: null });
        expect(priv.body.posts[0].files[0].private_url).toMatch(/^https:\/\/share\.capybaraharmony\.com\/p\/[A-Za-z0-9]{22}$/);
        // back to off: the private link is revoked, the public copy deleted
        const off = await status([a.sid, b.sid], "off");
        expect(off.body.failed).toEqual([]);
        expect(off.body.posts.flatMap((p: any) => p.files.map((f: any) => [f.visibility, f.private_url]))).toEqual([
            ["private", null],
            ["private", null],
        ]);
        expect(mirrors()).toEqual([]);
        // hidden again revokes a private link too
        await status([b.sid], "private");
        await status([b.sid], "hidden");
        expect(all("SELECT key FROM private_links WHERE revoked_at IS NULL")).toEqual([]);
        // a legacy host copy is not toggleable: public/private refuse the post, hidden still works
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)")
            .run("HostOnly00000001", "public", "host", "media", "HoStOnLy01.mp4", `${MEDIA_BASE}HoStOnLy01.mp4`, "h.mp4", "video/mp4", 10, "https://x.com/h/status/9", 5);
        const host = "https://x.com/h/status/9";
        expect((await status([host], "public")).body.failed).toEqual([{ id: host, error: "error.private.not_toggleable" }]);
        const hid = await status([host], "hidden");
        expect(hid.body.posts[0].post_key).toBe(host);
        expect(hid.body.failed).toEqual([{ id: "HostOnly00000001", error: "error.library.not_toggleable" }]);
        expect(hiddenRow(host).state).toBe("hidden");
    });

    it("refuses a bad body (400) and takes at most 200 ids", async () => {
        for (const body of [{}, { ids: [], status: "off" }, { ids: ["a"], status: "gone" }, { ids: Array.from({ length: 201 }, (_, i) => `x${i}`), status: "off" }]) {
            const r = await api("POST", "/library/status", body);
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.library.bad_request" } } });
        }
        const caps = (await (await w.call("/capabilities")).json()) as any;
        expect(caps.features.hidden).toBe(true);
        expect(caps.limits.status_ids).toBe(200);
    });

    it("the moving preview of a hidden video is deleted with it", async () => {
        const a = await publicPost();
        w.media.objects.set("LoOpLoOp01.webp", { bytes: 3, meta: {}, contentType: "image/webp", data: new Uint8Array(3), viaStream: false } as any);
        w.db.raw.prepare("INSERT INTO media_loops (item_id, url, r2_key, bytes, made_at) VALUES (?, ?, ?, 3, 1)").run(a.item.id, `${MEDIA_BASE}LoOpLoOp01.webp`, "LoOpLoOp01.webp");
        await status([a.sid], "hidden");
        expect(w.media.objects.has("LoOpLoOp01.webp")).toBe(false);
        expect(all("SELECT * FROM media_loops")).toEqual([]);
    });
});

describe("rule matching (37.3)", () => {
    const facts = (over: Partial<PostFacts> = {}): PostFacts => ({
        post_key: "p",
        latest: 1,
        link: null,
        title: null,
        names: [],
        captions: [],
        upload: false,
        tags: [],
        words: "",
        ...over,
    });
    const site = (value: string, link: string) => ruleMatches({ kind: "site", value: normalizeRuleValue("site", value)! }, facts({ link }));

    it("site: the host or any subdomain, twitter = x, and a path on a / boundary", () => {
        expect(site("instagram.com", "https://www.instagram.com/reel/abc/")).toBe(true);
        expect(site("instagram.com", "https://instagram.com/p/1")).toBe(true);
        expect(site("instagram.com", "https://notinstagram.com/p/1")).toBe(false);
        expect(site("tiktok.com", "https://vm.tiktok.com/ZMabc/")).toBe(true);
        expect(site("tiktok.com", "https://m.tiktok.com/v/1.html")).toBe(true);
        expect(site("x.com/name", "https://x.com/name/status/1")).toBe(true);
        expect(site("x.com/name", "https://x.com/Name")).toBe(true);
        expect(site("x.com/name", "https://x.com/names/status/1")).toBe(false);
        expect(site("x.com/name", "https://twitter.com/name/status/1")).toBe(true);
        expect(site("twitter.com/name", "https://x.com/name/status/1")).toBe(true);
        expect(site("twitter.com", "https://mobile.twitter.com/a/status/1")).toBe(true);
        expect(site("x.com", "https://mobile.twitter.com/a/status/1")).toBe(true);
        expect(site("tiktok.com/@cat", "https://www.tiktok.com/@cat/video/7")).toBe(true);
        expect(site("tiktok.com/@cat", "https://www.tiktok.com/@catalina/video/7")).toBe(false);
        expect(site("https://www.TikTok.com/@Cat/", "https://www.tiktok.com/@cat/video/7")).toBe(true);
        expect(ruleMatches({ kind: "site", value: "x.com" }, facts({ link: null }))).toBe(false);
        expect(ruleMatches({ kind: "site", value: "x.com" }, facts({ link: "upload:abc" }))).toBe(false);
    });

    it("site values are normalized; anything that is not a host is refused", () => {
        expect(normalizeRuleValue("site", " https://www.Instagram.com/ ")).toBe("instagram.com");
        expect(normalizeRuleValue("site", "x.com/Name/")).toBe("x.com/name");
        expect(normalizeRuleValue("site", "x.com/name?x=1")).toBe("x.com/name");
        for (const bad of ["", "localhost", "not a host", "x..com", "-x.com", "x.com:8080", 5, null]) expect(normalizeRuleValue("site", bad)).toBeNull();
        expect(normalizeRuleValue("upload", "whatever")).toBe("");
        expect(normalizeRuleValue("words", "  Furry  Thing ")).toBe("furry thing");
        expect(normalizeRuleValue("words", "a".repeat(60))).toBe("a".repeat(60));
        expect(normalizeRuleValue("words", "a".repeat(61))).toBeNull();
        expect(normalizeRuleValue("words", "   ")).toBeNull();
        expect(normalizeRuleValue("about", "b".repeat(40))).toBe("b".repeat(40));
        expect(normalizeRuleValue("about", "b".repeat(41))).toBeNull();
    });

    it("words: in the custom title, a file name, a roast title or the link, any case", () => {
        const m = (value: string, over: Partial<PostFacts>) => ruleMatches({ kind: "words", value }, facts(over));
        expect(m("nsfw", { title: "So NSFW lol" })).toBe(true);
        expect(m("nsfw", { names: ["clip_NSFW.mp4"] })).toBe(true);
        expect(m("nsfw", { captions: ["harmony's nsfw era"] })).toBe(true);
        expect(m("nsfw", { link: "https://x.com/nsfwbot/status/1" })).toBe(true);
        expect(m("nsfw", { title: "safe", names: ["a.mp4"] })).toBe(false);
    });

    it("about: a tag or sound tag exactly, or a whole word (or words) of the sentence or transcript", () => {
        const m = (value: string, over: Partial<PostFacts>) => ruleMatches({ kind: "about", value }, facts(over));
        expect(m("fursuit", { tags: ["fursuit", "dance"] })).toBe(true);
        expect(m("phonk", { tags: ["phonk"] })).toBe(true);
        expect(m("fur", { tags: ["fursuit"] })).toBe(false);
        expect(m("cat", { words: "a cat jumps on a table" })).toBe(true);
        expect(m("cat", { words: "a catalog of things" })).toBe(false);
        expect(m("black cat", { words: "a black cat jumps" })).toBe(true);
        expect(m("cat", { words: "" })).toBe(false);
    });

    it("upload: any uploaded file", () => {
        expect(ruleMatches({ kind: "upload", value: "" }, facts({ upload: true }))).toBe(true);
        expect(ruleMatches({ kind: "upload", value: "" }, facts({ upload: false }))).toBe(false);
    });
});

describe("the rules routes (37.4)", () => {
    it("create, list, preview, apply (hits), update, delete; posts a deleted rule hid stay hidden", async () => {
        const a = await privatePost("https://x.com/name/status/1");
        const b = await privatePost("https://x.com/names/status/2");
        const c = await privatePost("https://www.tiktok.com/@cat/video/3");
        const prev = await api("POST", "/hidden/rules/preview", { kind: "site", value: "twitter.com/name" });
        expect(prev).toEqual({ status: 200, body: { status: "success", matches: 1, sample: [a.sid] } });
        expect(hiddenRow(a.sid)).toBeUndefined();

        const r = await addRule({ kind: "site", value: "X.com/Name", apply: true });
        expect(r.status).toBe(201);
        expect(r.body.rule).toMatchObject({ kind: "site", value: "x.com/name", enabled: true, hits: 1 });
        expect(r.body.rule.id).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(r.body.applied).toBe(1);
        expect(hiddenRow(a.sid)).toEqual({ post_key: a.sid, state: "hidden", by: "rule", rule_id: r.body.rule.id });
        expect(hiddenRow(b.sid)).toBeUndefined();
        expect((await lib("v=3&hidden=1")).posts[0]).toMatchObject({ id: a.sid, hidden_by: "rule", hidden_rule: r.body.rule.id });

        w.clock.t += 1; // rules list oldest first (ties fall back to the random id)
        const w2 = await addRule({ kind: "site", value: "tiktok.com", enabled: false });
        expect(w2.body.rule.enabled).toBe(false);
        expect(w2.body.applied).toBe(0);
        const list = await api("GET", "/hidden/rules");
        expect(list.body).toMatchObject({ status: "success", hidden: 1, held: 0 });
        expect(list.body.rules.map((x: any) => x.id)).toEqual([r.body.rule.id, w2.body.rule.id]);

        const on = await api("PATCH", `/hidden/rules/${w2.body.rule.id}`, { enabled: true, apply: true });
        expect(on.body).toMatchObject({ rule: { enabled: true, hits: 1 }, applied: 1 });
        expect(hiddenRow(c.sid).state).toBe("hidden");
        expect((await api("PATCH", `/hidden/rules/${w2.body.rule.id}`, { value: "not a host" })).body.error.code).toBe("error.hidden.bad_rule");
        expect((await api("PATCH", "/hidden/rules/AAAAAAAAAAAAAAAA", { enabled: false })).status).toBe(404);

        expect(await api("DELETE", `/hidden/rules/${r.body.rule.id}`)).toEqual({ status: 200, body: { status: "success" } });
        expect(await api("DELETE", `/hidden/rules/${r.body.rule.id}`)).toEqual({ status: 404, body: { status: "error", error: { code: "error.hidden.not_found" } } });
        expect(hiddenRow(a.sid).state).toBe("hidden");
    });

    it("refuses bad rules and the 51st", async () => {
        for (const body of [{ kind: "nope", value: "x" }, { kind: "site", value: "nothost" }, { kind: "words", value: "" }, { kind: "about", value: "a".repeat(41) }, {}]) {
            expect(await addRule(body)).toEqual({ status: 400, body: { status: "error", error: { code: "error.hidden.bad_rule" } } });
        }
        for (let i = 0; i < 50; i++) expect((await addRule({ kind: "words", value: `w${i}` })).status).toBe(201);
        expect(await addRule({ kind: "upload" })).toEqual({ status: 409, body: { status: "error", error: { code: "error.hidden.too_many" } } });
    });

    it("the routes take the web Worker's service credential too, never an unknown key", async () => {
        const svc = { "x-cobalt-service": INTERNAL };
        expect((await api("GET", "/hidden/rules", undefined, svc)).status).toBe(200);
        expect((await api("POST", "/hidden/rules", { kind: "words", value: "svc" }, svc)).status).toBe(201);
        expect((await api("GET", "/hidden/rules", undefined, { authorization: "Api-Key 11111111-2222-4333-8444-555555555555" })).status).toBe(401);
        expect((await api("GET", "/hidden/rules", undefined, {})).status).toBe(401);
    });
});

describe("a save that a rule hides (37.3)", () => {
    it("public: true with a matching site rule is never public, not even briefly", async () => {
        await addRule({ kind: "site", value: "x.com" });
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: LINK, public: true }))).id as string;
        const done = asBody(await w.settle(sid));
        expect(done).toMatchObject({ status: "ready" });
        expect(done.public_url).toBeNull();
        expect(w.session(sid)).toMatchObject({ public_state: null, public_url: null });
        // no mirror was ever written
        expect(w.media.puts.filter((p) => !p.key.endsWith(".jpg"))).toEqual([]);
        expect(hiddenRow(sid)).toMatchObject({ state: "hidden", by: "rule" });
        expect(one("SELECT hits FROM hidden_rules").hits).toBe(1);
        expect((await lib()).posts).toEqual([]);
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("public:"))).toEqual([]);
    });

    it("a save without public: true is hidden too; one that matches nothing is untouched", async () => {
        await addRule({ kind: "words", value: "maria_rcks" });
        const a = await privatePost();
        const b = await privatePost("https://www.tiktok.com/@cat/video/3");
        expect(hiddenRow(a.sid)).toMatchObject({ state: "hidden", by: "rule" });
        expect(hiddenRow(b.sid)).toBeUndefined();
    });

    it("an upload rule hides an upload at once (a public image is never hosted)", async () => {
        await addRule({ kind: "upload" });
        const res = await w.call("/studio/upload?name=photo.png&public=1", {
            method: "PUT",
            headers: { ...auth, "content-type": "image/png", "content-length": "4096" },
            body: new Uint8Array(4096).fill(3) as unknown as BodyInit,
        });
        const b = (await res.json()) as any;
        expect(res.status).toBe(201);
        expect(b).toMatchObject({ public_state: null, public_url: null, item: { visibility: "private" } });
        expect(w.media.objects.size).toBe(0);
        expect(hiddenRow(b.item.id)).toMatchObject({ state: "hidden", by: "rule" });
    });

    it("a disabled rule does nothing", async () => {
        await addRule({ kind: "site", value: "x.com", enabled: false });
        await publicPost();
    });
});

describe("about rules hold a public save (37.3)", () => {
    async function heldSave(link = LINK) {
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: link, public: true }))).id as string;
        const done = asBody(await w.settle(sid));
        expect(done.status).toBe("ready");
        return sid;
    }
    const writeAbout = (sid: string, tags: string[], sentence = "a video") => {
        const item = w.items().find((i) => i.session_id === sid)!;
        w.db.raw
            .prepare(
                "INSERT INTO media_about (post_key, item_id, probe_state, tags, sound_tags, sentence, written_at, updated_at) VALUES (?, ?, 'done', ?, '[]', ?, ?, ?)",
            )
            .run(sid, item.id, JSON.stringify(tags), sentence, w.clock.t, w.clock.t);
    };

    it("is not published at ready: held, listed normally as off, the session still pending", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        expect(hiddenRow(sid)).toMatchObject({ state: "held", by: "rule", rule_id: null });
        expect(mirrors()).toEqual([]);
        expect(w.session(sid).public_state).toBe("pending");
        const l = await lib();
        expect(l.posts.map((p: any) => p.id)).toEqual([sid]);
        expect(l.posts[0]).toMatchObject({ hidden: false, visibility: "private" });
        expect((await api("GET", "/hidden/rules")).body).toMatchObject({ hidden: 0, held: 1 });
        // still waiting: nothing written yet
        expect(await releaseHeld(heldDeps(), { aboutOn: true })).toEqual({ held: 1, hidden: 0, published: 0, waiting: 1 });
    });

    it("a match once the words are written hides it", async () => {
        const rule = await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        writeAbout(sid, ["cat", "table"]);
        expect(await releaseHeld(heldDeps(), { aboutOn: true })).toMatchObject({ hidden: 1, published: 0 });
        expect(hiddenRow(sid)).toEqual({ post_key: sid, state: "hidden", by: "rule", rule_id: rule.body.rule.id });
        expect(mirrors()).toEqual([]);
        expect(w.session(sid).public_state).toBeNull();
    });

    it("no match: the row goes and the section 13 publish runs then", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        writeAbout(sid, ["dog"], "a dog catches a ball");
        expect(await releaseHeld(heldDeps(), { aboutOn: true })).toMatchObject({ hidden: 0, published: 1 });
        expect(hiddenRow(sid)).toBeUndefined();
        expect(mirrors()).toHaveLength(1);
        expect(w.session(sid).public_state).toBe("ready");
        expect(w.session(sid).public_url).toMatch(HOST_URL);
    });

    it("gives up after 60 minutes (and at once while about is off)", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        w.clock.t += HELD_GIVE_UP_MS - 1;
        expect((await releaseHeld(heldDeps(), { aboutOn: true })).waiting).toBe(1);
        w.clock.t += 1;
        expect((await releaseHeld(heldDeps(), { aboutOn: true })).published).toBe(1);
        expect(w.session(sid).public_state).toBe("ready");

        const sid2 = await heldSave("https://x.com/b/status/2");
        expect(hiddenRow(sid2).state).toBe("held");
        expect((await releaseHeld(heldDeps(), { aboutOn: false })).published).toBe(1);
    });

    it("a failed probe or three failed writes give up too", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        const item = w.items().find((i) => i.session_id === sid)!;
        w.db.raw.prepare("INSERT INTO media_about (post_key, item_id, probe_state, attempts, updated_at) VALUES (?, ?, 'failed', 0, 1)").run(sid, item.id);
        expect((await releaseHeld(heldDeps(), { aboutOn: true })).published).toBe(1);
    });

    it("sharing a held post by hand ends the wait (the owner decided)", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        const item = w.items().find((i) => i.session_id === sid)!;
        expect((await api("PATCH", `/library/items/${item.id}/visibility`, { public: true })).status).toBe(200);
        expect(hiddenRow(sid)).toBeUndefined();
        writeAbout(sid, ["cat"]);
        expect(await releaseHeld(heldDeps(), { aboutOn: true })).toEqual({ held: 0, hidden: 0, published: 0, waiting: 0 });
    });

    it("off on a held post drops the hold, so the cron never publishes it", async () => {
        await addRule({ kind: "about", value: "cat" });
        const sid = await heldSave();
        await status([sid], "off");
        expect(hiddenRow(sid)).toBeUndefined();
        w.clock.t += HELD_GIVE_UP_MS;
        expect((await releaseHeld(heldDeps(), { aboutOn: true })).published).toBe(0);
        expect(mirrors()).toEqual([]);
    });

    it("a save not asked to be public is never held", async () => {
        await addRule({ kind: "about", value: "cat" });
        const p = await privatePost();
        expect(hiddenRow(p.sid)).toBeUndefined();
    });
});

describe("without migration 0025", () => {
    beforeEach(() => {
        w.db.raw.exec("DROP TABLE media_hidden; DROP TABLE hidden_rules;");
    });
    it("the routes answer 503, the library and saves behave as before, features.hidden is false", async () => {
        const a = await publicPost();
        const generic = { status: "error", error: { code: "error.api.generic" } };
        expect(await status([a.sid], "hidden")).toEqual({ status: 503, body: generic });
        expect(await api("GET", "/hidden/rules")).toEqual({ status: 503, body: generic });
        expect(await addRule({ kind: "upload" })).toEqual({ status: 503, body: generic });
        expect(await api("POST", "/hidden/rules/preview", { kind: "upload" })).toEqual({ status: 503, body: generic });
        const l = await lib();
        expect(l.posts.map((p: any) => p.id)).toEqual([a.sid]);
        expect(l.posts[0]).toMatchObject({ hidden: false, hidden_by: null, hidden_rule: null });
        expect(l.counts).toEqual({ posts: 1, files: 1, hidden: 0 });
        expect((await lib("v=3&hidden=1")).posts).toEqual([]);
        expect(((await (await w.call("/capabilities")).json()) as any).features.hidden).toBe(false);
        // visibility still toggles both ways
        expect((await api("PATCH", `/library/items/${a.item.id}/visibility`, { public: false })).status).toBe(200);
        expect((await api("PATCH", `/library/items/${a.item.id}/visibility`, { public: true })).status).toBe(200);
        expect(await releaseHeld(heldDeps(), { aboutOn: true })).toEqual({ held: 0, hidden: 0, published: 0, waiting: 0 });
    });
});

describe("nothing is made of a hidden post (37.2)", () => {
    const render = (sid: string) => w.studio.render(sid, json({ start: 0, length: 2 }));

    it("a render, slideshow or gallery image of a hidden post is refused before it starts", async () => {
        const a = await publicPost();
        await status([a.sid], "hidden");
        const puts = w.media.puts.length;
        expect(await render(a.sid)).toEqual({ status: 409, body: { status: "error", error: { code: "error.hidden" } } });
        expect(await w.studio.slideshow(KEY_ID, a.sid, json({ items: [0], seconds: [2], queue: true }))).toEqual({ status: 409, body: { status: "error", error: { code: "error.hidden" } } });
        expect(await w.studio.galleryImage(KEY_ID, a.sid, json({ layout: "grid2", queue: true }))).toEqual({ status: 409, body: { status: "error", error: { code: "error.hidden" } } });
        expect(one("SELECT COUNT(*) AS n FROM studio_renders WHERE session_id = ?", a.sid).n).toBe(0);
        expect(w.media.puts.length).toBe(puts);
        // unhidden (off), it renders again
        await status([a.sid], "off");
        expect((await render(a.sid)).status).toBe(202);
    });

    it("a render that finishes after its post was hidden is recorded off: no public object, no URL", async () => {
        const a = await publicPost();
        const r = await render(a.sid);
        expect(r.status).toBe(202);
        await status([a.sid], "hidden");
        const done = asBody(await w.studio.renderStatus(a.sid, asBody(r).job, 0));
        expect(done).toMatchObject({ status: "success", url: null });
        const webps = all("SELECT bucket, visibility, url, r2_key FROM media_items WHERE session_id = ? AND content_type = 'image/webp' AND deleted_at IS NULL", a.sid);
        expect(webps).toHaveLength(1);
        expect(webps[0]).toMatchObject({ bucket: "originals", visibility: "private", url: null });
        expect([...w.media.objects.keys()].filter((k) => k.endsWith(".webp"))).toEqual([]);
        expect(one("SELECT url FROM studio_renders WHERE id = ?", asBody(r).job).url).toBeNull();
        // polled again: the same answer
        expect(asBody(await w.studio.renderStatus(a.sid, asBody(r).job, 0)).url).toBeNull();
    });

    it("a render of a post that is not hidden is recorded public as before", async () => {
        const a = await publicPost();
        const r = await render(a.sid);
        const done = asBody(await w.studio.renderStatus(a.sid, asBody(r).job, 0));
        expect(done.url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]+\.webp$/);
    });
});

describe("a legacy host copy when hiding (37.2)", () => {
    const hostCopy = (sid: string, id = "HostCopy00000001", name = "HoStCoPy01.mp4") => {
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, link, session_id, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
            .run(id, "public", "host", "media", name, `${MEDIA_BASE}${name}`, "h.mp4", "video/mp4", 10, LINK, sid, 5);
        return w.media.put(name, new Uint8Array(10).buffer, { httpMetadata: { contentType: "video/mp4", cacheControl: "" }, customMetadata: {} });
    };

    it("is deleted when the post's original is in the private bucket: nothing fails", async () => {
        const a = await privatePost();
        await hostCopy(a.sid);
        const r = await status([a.sid], "hidden");
        expect(r.body.failed).toEqual([]);
        expect(w.media.objects.has("HoStCoPy01.mp4")).toBe(false);
        expect(one("SELECT deleted_at FROM media_items WHERE id = 'HostCopy00000001'").deleted_at).not.toBeNull();
        expect(one("SELECT deleted_at FROM media_items WHERE id = ?", a.item.id).deleted_at).toBeNull();
        expect(w.originals.objects.has(a.item.r2_key)).toBe(true);
    });

    it("is kept (and reported under failed) when the original's object is missing", async () => {
        const a = await privatePost();
        await hostCopy(a.sid);
        w.originals.objects.delete(a.item.r2_key);
        const r = await status([a.sid], "hidden");
        expect(r.body.failed).toEqual([{ id: "HostCopy00000001", error: "error.library.not_toggleable" }]);
        expect(w.media.objects.has("HoStCoPy01.mp4")).toBe(true);
        expect(hiddenRow(a.sid).state).toBe("hidden");
    });
});
