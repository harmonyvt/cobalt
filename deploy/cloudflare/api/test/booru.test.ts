// The booru tab (APP-API-CONTRACT.md section 72): general only (72.9), the hard block, themes, the blacklist, the
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
    level: "g",
    themes: defaultThemes(),
    blacklist: "",
    updated_at: null,
    ...over,
});

const H = defaultThemes();

describe("judge", () => {
    it("keeps general only: s, q, e and unrated posts are dropped", () => {
        for (const rating of ["s", "q", "e", undefined]) {
            expect(judge(post({ rating }), "g", H, [], {})).toEqual({ keep: false, why: "level" });
        }
        expect(judge(post(), "g", H, [], {})).toEqual({ keep: true, blur: false });
    });
    it("hides every theme, always, and nudity tags even on a general post", () => {
        expect(Object.values(H).every((m) => m === "hide")).toBe(true);
        expect(judge(post({ tag_string: "swimsuit" }), "g", H, [], {})).toEqual({ keep: false, why: "theme" });
        expect(judge(post({ tag_string: "blood" }), "g", H, [], {})).toEqual({ keep: false, why: "theme" });
        expect(judge(post({ tag_string: "nude" }), "g", H, [], {})).toEqual({ keep: false, why: "level" });
    });
    it("always blocks the hard-block tags", () => {
        expect(judge(post({ tag_string: "shota" }), "g", H, [], {})).toEqual({ keep: false, why: "hard" });
    });
    it("drops posts without a usable file", () => {
        expect(judge(post({ file_url: undefined }), "g", H, [], {}).keep).toBe(false);
        expect(judge(post({ file_url: "https://evil.example/x.png" }), "g", H, [], {}).keep).toBe(false);
        expect(judge(post({ file_ext: "zip" }), "g", H, [], {}).keep).toBe(false);
        expect(judge(post({ is_deleted: true }), "g", H, [], {}).keep).toBe(false);
    });
    it("refines by score, media and shape", () => {
        expect(judge(post({ score: 3 }), "g", H, [], { min_score: 5 }).keep).toBe(false);
        expect(judge(post({ file_ext: "mp4" }), "g", H, [], { media: "image" }).keep).toBe(false);
        expect(judge(post(), "g", H, [], { shape: "tall" }).keep).toBe(true);
        expect(judge(post(), "g", H, [], { shape: "wide" }).keep).toBe(false);
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
        expect(judge(post(), "g", H, rules, {})).toEqual({ keep: false, why: "blacklist" });
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
    it("asks for general only, filters again, and counts what it hid, whatever level is asked", async () => {
        const urls: string[] = [];
        const fetchFn = async (url: string) => {
            urls.push(url);
            return Response.json([post({ id: 1 }), post({ id: 2, rating: "e" }), post({ id: 3, rating: "s" }), post({ id: 4, tag_string: "loli" }), post({ id: 5, tag_string: "bikini" })]);
        };
        const r = await searchPosts(fetchFn, settings(), { tags: "miku", page: 1, order: "popular", level: "s" });
        expect(decodeURIComponent(urls[0])).toContain("tags=miku order:rank rating:g");
        expect(decodeURIComponent(urls[0])).not.toContain("rating:g,");
        expect(r.posts.map((p) => p.id)).toEqual([1]);
        expect(r.hidden).toEqual({ level: 2, theme: 1, blacklist: 0, refine: 0, blocked: 1 });
        expect(r.next_page).toBeNull();
        expect(r.level).toBe("g");
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
    it("is general with every theme hidden, saves only the blacklist, and ignores old level and theme rows", async () => {
        const db = createFakeD1();
        expect(await readSettings(db, "k1")).toMatchObject({ level: "g", themes: H, blacklist: "" });
        const w = await writeSettings(db, "k1", { level: "s", themes: { violence: "show" }, blacklist: "rain" }, 5);
        expect(w).toMatchObject({ level: "g", themes: H, blacklist: "rain", updated_at: 5 });
        expect(await readSettings(db, "k1")).toMatchObject({ level: "g", themes: H, blacklist: "rain", updated_at: 5 });
        await db.prepare(`INSERT INTO booru_settings (key_id, level, themes, updated_at) VALUES ('old', 'q', '{"revealing":"show","violence":"show"}', 1)`).run();
        expect(await readSettings(db, "old")).toMatchObject({ level: "g", themes: H });
        await expect(
            db.prepare("INSERT INTO booru_settings (key_id, level, updated_at) VALUES ('k3', 'e', 1)").run(),
        ).rejects.toThrow();
    });
});

describe("filterRaw (POST /booru/filter)", () => {
    it("keeps general only on a page the app fetched, even when an older app asks for sensitive", () => {
        const raw = [post({ id: 1 }), post({ id: 2, rating: "e" }), post({ id: 3, rating: "s" }), post({ id: 4, tag_string: "loli" }), "junk", null, [1]];
        const r = filterRaw(settings(), { posts: raw, level: "s" });
        expect(r.level).toBe("g");
        expect(r.posts.map((p) => p.id)).toEqual([1]);
        expect(r.hidden).toMatchObject({ level: 2, blocked: 1 });
    });
});

describe("PUT /booru/settings input", () => {
    it("still accepts what older apps send (ignored), and refuses q, e and unknown themes", async () => {
        const { SettingsPatch } = await import("../src/registry/ops/booru");
        expect(SettingsPatch.safeParse({ themes: { violence: "blur" } }).success).toBe(true);
        expect(SettingsPatch.safeParse({ level: "s", themes: { violence: "hide", horror: "hide" } }).success).toBe(true);
        expect(SettingsPatch.safeParse({ blacklist: "rain" }).success).toBe(true);
        expect(SettingsPatch.safeParse({ themes: { nope: "blur" } }).success).toBe(false);
        expect(SettingsPatch.safeParse({ level: "e" }).success).toBe(false);
        expect(SettingsPatch.safeParse({ level: "q" }).success).toBe(false);
    });
});
