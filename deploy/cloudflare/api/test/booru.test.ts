// The booru tab (APP-API-CONTRACT.md section 72): levels (never explicit), the hard block, themes, the blacklist, the
// 2-tag fallback and the per-key settings, on the real migration.
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import {
    autocomplete,
    cleanTags,
    defaultThemes,
    filterRaw,
    judge,
    parseBlacklist,
    ruleMatches,
    readSettings,
    searchPosts,
    writeSettings,
    type BooruSettings,
    type DanbooruPost,
} from "../src/booru";

const post = (over: Partial<DanbooruPost> = {}): DanbooruPost => ({
    id: 1,
    rating: "g",
    tag_string: "1girl umbrella rain",
    tag_string_general: "1girl umbrella rain",
    score: 10,
    fav_count: 5,
    file_ext: "png",
    file_size: 1000,
    image_width: 800,
    image_height: 1200,
    file_url: "https://cdn.donmai.us/original/aa/bb/aabb.png",
    large_file_url: "https://cdn.donmai.us/sample/aa/bb/sample-aabb.jpg",
    preview_file_url: "https://cdn.donmai.us/180x180/aa/bb/aabb.jpg",
    ...over,
});

const settings = (over: Partial<BooruSettings> = {}): BooruSettings => ({
    level: "s",
    themes: defaultThemes(),
    blacklist: "",
    updated_at: null,
    ...over,
});

describe("judge", () => {
    it("never keeps explicit, at any level", () => {
        for (const level of ["g", "s", "q"] as const) {
            expect(judge(post({ rating: "e" }), level, defaultThemes(), [], {})).toEqual({ keep: false, why: "level" });
        }
    });
    it("keeps levels up to the setting only", () => {
        expect(judge(post({ rating: "q" }), "s", defaultThemes(), [], {}).keep).toBe(false);
        expect(judge(post({ rating: "s" }), "s", defaultThemes(), [], {}).keep).toBe(true);
        expect(judge(post({ rating: "s" }), "g", defaultThemes(), [], {}).keep).toBe(false);
        expect(judge(post({ rating: undefined }), "q", defaultThemes(), [], {}).keep).toBe(false);
    });
    it("always blocks the hard-block tags, even at general with every theme shown", () => {
        const all = Object.fromEntries(Object.keys(defaultThemes()).map((k) => [k, "show" as const]));
        expect(judge(post({ tag_string: "loli smile" }), "q", all, [], {})).toEqual({ keep: false, why: "hard" });
        expect(judge(post({ rating: "g", tag_string: "shota" }), "g", all, [], {})).toEqual({ keep: false, why: "hard" });
    });
    it("applies theme modes", () => {
        const t = defaultThemes();
        expect(judge(post({ rating: "q", tag_string: "topless" }), "q", t, [], {})).toEqual({ keep: true, blur: true });
        expect(judge(post({ rating: "q", tag_string: "nude" }), "q", t, [], {})).toEqual({ keep: false, why: "theme" });
        expect(judge(post({ tag_string: "blood" }), "q", t, [], {})).toEqual({ keep: false, why: "theme" });
        expect(judge(post({ tag_string: "blood" }), "q", { ...t, violence: "show" }, [], {})).toEqual({ keep: true, blur: false });
    });
    it("drops posts without a usable file", () => {
        expect(judge(post({ file_url: undefined }), "q", defaultThemes(), [], {}).keep).toBe(false);
        expect(judge(post({ file_url: "https://evil.example/x.png" }), "q", defaultThemes(), [], {}).keep).toBe(false);
        expect(judge(post({ file_ext: "zip" }), "q", defaultThemes(), [], {}).keep).toBe(false);
        expect(judge(post({ is_deleted: true }), "q", defaultThemes(), [], {}).keep).toBe(false);
    });
    it("refines by score, media and shape", () => {
        expect(judge(post({ score: 3 }), "q", defaultThemes(), [], { min_score: 5 }).keep).toBe(false);
        expect(judge(post({ file_ext: "mp4" }), "q", defaultThemes(), [], { media: "image" }).keep).toBe(false);
        expect(judge(post(), "q", defaultThemes(), [], { shape: "tall" }).keep).toBe(true);
        expect(judge(post(), "q", defaultThemes(), [], { shape: "wide" }).keep).toBe(false);
    });
});

describe("blacklist", () => {
    const tags = (s: string) => new Set(s.split(" "));
    it("parses Danbooru's rule lines", () => {
        const rules = parseBlacklist("# comment\nrain\numbrella -rain\n~cat ~dog\nscore:<0\nrating:q\nfoo*");
        expect(rules).toHaveLength(6);
        const p = post();
        const hit = (s: string, pp = p) => rules.some((r) => ruleMatches(r, tags(s), pp));
        expect(hit("rain")).toBe(true);
        expect(hit("umbrella sun")).toBe(true);
        expect(hit("dog")).toBe(true);
        expect(hit("bird", post({ score: -1 }))).toBe(true);
        expect(hit("bird", post({ rating: "q" }))).toBe(true);
        expect(hit("foobar")).toBe(true);
        expect(hit("bird")).toBe(false);
    });
    it("hides matching posts in judge", () => {
        const rules = parseBlacklist("umbrella");
        expect(judge(post(), "q", defaultThemes(), rules, {})).toEqual({ keep: false, why: "blacklist" });
    });
});

describe("cleanTags", () => {
    it("drops metatags that would change the level, and limits to 2 tags", () => {
        expect(cleanTags("Hatsune_Miku rating:e status:any")).toEqual(["hatsune_miku"]);
        expect(cleanTags("-rating:g ~a")).toEqual(["~a"]);
        expect(() => cleanTags("a b c")).toThrow("error.booru.too_many_tags");
    });
});

describe("searchPosts", () => {
    it("asks for the rating clause, filters again, and counts what it hid", async () => {
        const urls: string[] = [];
        const fetchFn = async (url: string) => {
            urls.push(url);
            return Response.json([post({ id: 1 }), post({ id: 2, rating: "e" }), post({ id: 3, rating: "q" }), post({ id: 4, tag_string: "loli" }), post({ id: 5, rating: "s", tag_string: "topless" })]);
        };
        const r = await searchPosts(fetchFn, settings({ level: "s", themes: { ...defaultThemes(), partial: "blur" } }), { tags: "miku", page: 1, order: "popular" });
        expect(decodeURIComponent(urls[0])).toContain("tags=miku order:rank rating:g,s");
        expect(r.posts.map((p) => p.id)).toEqual([1, 5]);
        expect(r.posts[1].blur).toBe(true);
        expect(r.hidden).toEqual({ level: 2, theme: 0, blacklist: 0, refine: 0, blocked: 1 });
        expect(r.next_page).toBeNull();
        expect(r.level).toBe("s");
    });
    it("never goes above the key's level, even when asked", async () => {
        const urls: string[] = [];
        const fetchFn = async (url: string) => (urls.push(url), Response.json([post({ rating: "q" })]));
        const r = await searchPosts(fetchFn, settings({ level: "g" }), { tags: "", page: 1, order: "new", level: "q" });
        expect(r.level).toBe("g");
        expect(r.posts).toHaveLength(0);
        expect(decodeURIComponent(urls[0])).toContain("rating:g");
        expect(decodeURIComponent(urls[0])).not.toContain("rating:g,s");
    });
    it("gives up the extras when Danbooru refuses the tag count", async () => {
        const urls: string[] = [];
        const fetchFn = async (url: string) => {
            urls.push(decodeURIComponent(url));
            if (urls.length < 3) return Response.json({ success: false, message: "You cannot search for more than 2 tags at a time." }, { status: 422 });
            return Response.json([post({ rating: "q" }), post({ id: 9, rating: "g" })]);
        };
        const r = await searchPosts(fetchFn, settings({ level: "g" }), { tags: "a b", page: 1, order: "score" });
        expect(r.dropped).toEqual(["order", "rating"]);
        expect(urls[2].endsWith("tags=a b")).toBe(true);
        expect(r.posts.map((p) => p.id)).toEqual([9]);
    });
    it("answers upstream errors without throwing raw", async () => {
        await expect(searchPosts(async () => { throw new Error("down"); }, settings(), { tags: "", page: 1, order: "new" })).rejects.toThrow("error.booru.upstream");
        await expect(searchPosts(async () => new Response("x", { status: 429 }), settings(), { tags: "", page: 1, order: "new" })).rejects.toThrow("error.booru.busy");
    });
});

describe("autocomplete", () => {
    it("maps kinds and never suggests hard-blocked tags", async () => {
        const fetchFn = async () =>
            Response.json([
                { value: "hatsune_miku", category: 4, post_count: 100 },
                { value: "loli", category: 0, post_count: 5 },
                { value: "rating:e", category: 0, post_count: 1 },
            ]);
        expect(await autocomplete(fetchFn, "h")).toEqual([{ name: "hatsune_miku", kind: "character", count: 100 }]);
    });
});

describe("settings", () => {
    it("defaults to general, saves per key, and refuses explicit at the table", async () => {
        const db = createFakeD1();
        expect((await readSettings(db, "k1")).level).toBe("g");
        await writeSettings(db, "k1", { level: "q", themes: { violence: "blur" }, blacklist: "rain" }, 5);
        const s = await readSettings(db, "k1");
        expect(s).toMatchObject({ level: "q", blacklist: "rain", updated_at: 5 });
        expect(s.themes.violence).toBe("blur");
        expect(s.themes.nudity).toBe("hide");
        expect((await readSettings(db, "k2")).level).toBe("g");
        await expect(
            db.prepare("INSERT INTO booru_settings (key_id, level, updated_at) VALUES ('k3', 'e', 1)").run(),
        ).rejects.toThrow();
    });
});

describe("filterRaw (POST /booru/filter)", () => {
    it("applies the key's level, the hard block and the themes to a page the app fetched, and never goes higher", () => {
        const raw = [post({ id: 1 }), post({ id: 2, rating: "e" }), post({ id: 3, rating: "q" }), post({ id: 4, tag_string: "loli" }), "junk", null, [1]];
        const r = filterRaw(settings({ level: "s" }), { posts: raw, level: "q" });
        expect(r.level).toBe("s");
        expect(r.posts.map((p) => p.id)).toEqual([1]);
        expect(r.hidden).toMatchObject({ level: 2, blocked: 1 });
        expect(filterRaw(settings({ level: "q" }), { posts: raw, level: "g" }).posts.map((p) => p.id)).toEqual([1]);
    });
});

describe("PUT /booru/settings input", () => {
    it("takes one theme at a time, and refuses unknown themes and modes", async () => {
        const { SettingsPatch } = await import("../src/registry/ops/booru");
        expect(SettingsPatch.safeParse({ themes: { violence: "blur" } }).success).toBe(true);
        expect(SettingsPatch.safeParse({ level: "s", themes: { violence: "hide", horror: "hide" } }).success).toBe(true);
        expect(SettingsPatch.safeParse({ themes: { nope: "blur" } }).success).toBe(false);
        expect(SettingsPatch.safeParse({ themes: { violence: "maybe" } }).success).toBe(false);
        expect(SettingsPatch.safeParse({ level: "e" }).success).toBe(false);
    });
});
