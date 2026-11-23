// The booru tab (APP-API-CONTRACT.md section 72): Danbooru search through the Worker, with the content level and the
// filters applied here, so a device can never see more than its own setting allows.
//
//  - General only (owner, 2026-11-23: "just general, not even sensitive, and no toggles"). Danbooru's s, q and e ratings
//    are never asked for, and a post rated anything but g is dropped even if Danbooru returns one. Every theme is hidden,
//    always (THEMES): the level and the theme modes are no longer settings, and old saved values are ignored. Nudity tags
//    are always hidden too (ALWAYS_HIDDEN).
//  - A hard block is always on, at every level, for every key: sexualised child-like characters (HARD_BLOCK). Not a setting.
//  - Each key (each device session, each key for tools) has its own row in D1 `booru_settings` (migration 0046). Only its
//    blacklist still counts (it can only hide more); the level and theme columns are read as general and hide.
//  - Danbooru lets an anonymous search use 2 tags. The owner's own tags come first; the rating clause and the order are
//    extras, dropped (and reported in `dropped`) when Danbooru refuses the tag count. Every filter is applied here again
//    on the posts that come back, so dropping an extra only makes pages thinner, never less safe.

export type BooruLevel = "g";
export const LEVELS: readonly BooruLevel[] = ["g"];
export type ThemeMode = "show" | "blur" | "hide";
export const THEME_MODES: readonly ThemeMode[] = ["show", "blur", "hide"];

export const DANBOORU = "https://danbooru.donmai.us";
const USER_AGENT = "capystore/1.0 (private booru tab)";
export const PAGE_LIMIT = 100; // posts asked of Danbooru per page (it allows 200)
export const MAX_USER_TAGS = 2;
export const BLACKLIST_MAX_CHARS = 8000;
const TIMEOUT_MS = 12_000;

// Always hidden, at every level, whatever the settings say.
export const HARD_BLOCK: readonly string[] = ["loli", "shota", "toddlercon", "lolicon", "shotacon", "child_on_child"];
// Nudity, always hidden, in case a post rated g carries one.
export const ALWAYS_HIDDEN: readonly string[] = ["nude", "completely_nude", "nipples", "pussy", "penis", "areolae"];

export type BooruTheme = { id: string; label: string; detail: string; tags: string[]; default: ThemeMode; min_level: BooruLevel };

// The themes (section 72.3). A theme matches when a post has any of its tags, and a matching post is always hidden (72.9:
// the modes are no longer settings). Ids are one word: the app decodes with convertFromSnakeCase, which also rewrites
// dictionary keys.
export const THEMES: readonly BooruTheme[] = [
    {
        id: "revealing",
        label: "revealing outfits",
        detail: "swimsuits, underwear, lingerie",
        tags: ["swimsuit", "bikini", "one-piece_swimsuit", "underwear", "panties", "bra", "lingerie", "leotard", "underwear_only"],
        default: "hide",
        min_level: "g",
    },
    {
        id: "suggestive",
        label: "suggestive",
        detail: "poses and focus shots",
        tags: ["cleavage", "ass_focus", "breast_focus", "pantyshot", "upskirt", "groin", "skindentation", "covering_breasts"],
        default: "hide",
        min_level: "g",
    },
    {
        id: "partial",
        label: "partial nudity",
        detail: "topless, covered nudity",
        tags: ["topless", "bottomless", "convenient_censoring", "naked_towel", "nude_cover", "naked_shirt", "censored"],
        default: "hide",
        min_level: "g",
    },
    {
        id: "violence",
        label: "violence and gore",
        detail: "blood, injury, guro",
        tags: ["guro", "blood", "injury", "corpse", "death", "decapitation", "severed_limb"],
        default: "hide",
        min_level: "g",
    },
    {
        id: "horror",
        label: "body horror",
        detail: "gross-out",
        tags: ["body_horror", "scat", "vomit", "vore"],
        default: "hide",
        min_level: "g",
    },
];

export type BooruSettings = { level: BooruLevel; themes: Record<string, ThemeMode>; blacklist: string; updated_at: number | null };

// Every theme hidden: the only modes there are (72.9).
export const defaultThemes = (): Record<string, ThemeMode> => Object.fromEntries(THEMES.map((t) => [t.id, "hide" as ThemeMode]));

export const isLevel = (v: unknown): v is BooruLevel => typeof v === "string" && (LEVELS as readonly string[]).includes(v);
export const levelRank = (l: BooruLevel) => LEVELS.indexOf(l);

// ---- settings in D1 -------------------------------------------------------------------------------------------------

type SettingsRow = { level: string; themes: string; blacklist: string; updated_at: number };

export async function readSettings(db: D1Database, keyId: string): Promise<BooruSettings> {
    let row: SettingsRow | null = null;
    try {
        row = await db.prepare("SELECT level, themes, blacklist, updated_at FROM booru_settings WHERE key_id = ?1").bind(keyId).first<SettingsRow>();
    } catch {
        row = null; // migration 0046 not applied yet: the defaults
    }
    // a row's saved level (s, or the old q) and theme modes no longer count: general, every theme hidden (72.9)
    return {
        level: "g",
        themes: defaultThemes(),
        blacklist: row?.blacklist ?? "",
        updated_at: row?.updated_at ?? null,
    };
}

export type SettingsPatch = { level?: string; themes?: Partial<Record<string, ThemeMode>>; blacklist?: string };

// Only the blacklist is saved; a level or theme modes in the patch (an older app) are ignored (72.9).
export async function writeSettings(db: D1Database, keyId: string, patch: SettingsPatch, now: number): Promise<BooruSettings> {
    const cur = await readSettings(db, keyId);
    const next: BooruSettings = {
        level: "g",
        themes: defaultThemes(),
        blacklist: patch.blacklist !== undefined ? patch.blacklist.slice(0, BLACKLIST_MAX_CHARS) : cur.blacklist,
        updated_at: now,
    };
    await db
        .prepare(
            `INSERT INTO booru_settings (key_id, level, themes, blacklist, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(key_id) DO UPDATE SET level = excluded.level, themes = excluded.themes, blacklist = excluded.blacklist,
             updated_at = excluded.updated_at`,
        )
        .bind(keyId, next.level, JSON.stringify(next.themes), next.blacklist, now)
        .run();
    return next;
}

// ---- credit for a saved post (72.10) ------------------------------------------------------------------------------------

// `booru` on POST /studio: a save from the booru tab keeps the Danbooru post page as its link (not the bare file) and the
// artist's own link in its post details (52.1: name = the artist, text = their link, site_name "danbooru").
export type BooruCredit = { page: string; artist: string | null; source: string | null; title: string | null; posted_at: number | null; favs: number | null };

const PAGE_RE = /^https:\/\/danbooru\.donmai\.us\/posts\/(\d{1,12})$/;
const short = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

/** null: no `booru` field; "bad": one that is not a Danbooru post saved from its own file. */
export function parseBooruCredit(v: unknown, fileLink: string): BooruCredit | null | "bad" {
    if (v === undefined || v === null) return null;
    if (typeof v !== "object" || Array.isArray(v)) return "bad";
    const o = v as Record<string, unknown>;
    if (typeof o.page !== "string" || !PAGE_RE.test(o.page)) return "bad";
    let host = "";
    try {
        host = new URL(fileLink).hostname.toLowerCase();
    } catch {
        return "bad";
    }
    if (!host.endsWith(".donmai.us")) return "bad";
    let source: string | null = null;
    if (typeof o.source === "string" && o.source.trim()) {
        try {
            const u = new URL(o.source.trim());
            if ((u.protocol === "https:" || u.protocol === "http:") && o.source.length <= 2048) source = u.toString();
        } catch {
            source = null;
        }
    }
    const t = typeof o.posted_at === "number" && Number.isFinite(o.posted_at) && o.posted_at > 0 ? Math.round(o.posted_at) : null;
    const favs = typeof o.favs === "number" && Number.isFinite(o.favs) && o.favs >= 0 ? Math.round(o.favs) : null;
    return { page: o.page, artist: short(o.artist, 200), source, title: short(o.title, 200), posted_at: t, favs };
}

/** The post details row for a booru save; a row already there (Harmony may have edited it) is left alone. */
export async function writeBooruDetails(db: D1Database, c: BooruCredit, now: number): Promise<void> {
    await db
        .prepare(
            `INSERT INTO post_details (link, site, found, name, handle, text, title, channel, game, clipper, site_name, posted_at, counts, verified, avatar_key, fetched_at, edited_at)
             VALUES (?1, 'generic', 1, ?2, NULL, ?3, ?4, NULL, NULL, NULL, 'danbooru', ?5, ?6, 0, NULL, ?7, NULL)
             ON CONFLICT(link) DO NOTHING`,
        )
        .bind(c.page, c.artist, c.source, c.title, c.posted_at, c.favs === null ? null : JSON.stringify({ likes: c.favs }), now)
        .run();
}

// ---- the blacklist: Danbooru's own rule format ------------------------------------------------------------------------

// One rule per line. Every plain term must match; `-tag` must not; `~a ~b` means any of them. Metatags: rating:<g|s|q>
// (comma lists too), score:<N / >N / <=N / >=N. `#` starts a comment.
export type Rule = { all: string[]; none: string[]; any: string[]; meta: ((p: DanbooruPost) => boolean)[] };

export function parseBlacklist(text: string): Rule[] {
    const rules: Rule[] = [];
    for (const raw of text.split("\n")) {
        const line = raw.replace(/#.*/, "").trim().toLowerCase();
        if (!line) continue;
        const rule: Rule = { all: [], none: [], any: [], meta: [] };
        for (const term of line.split(/\s+/)) {
            const neg = term.startsWith("-");
            const or = term.startsWith("~");
            const body = neg || or ? term.slice(1) : term;
            if (!body) continue;
            const meta = metaTest(body);
            if (meta) {
                rule.meta.push(neg ? (p) => !meta(p) : meta);
                continue;
            }
            if (neg) rule.none.push(body);
            else if (or) rule.any.push(body);
            else rule.all.push(body);
        }
        if (rule.all.length || rule.none.length || rule.any.length || rule.meta.length) rules.push(rule);
    }
    return rules;
}

function metaTest(term: string): ((p: DanbooruPost) => boolean) | null {
    const rating = /^rating:([a-z,]+)$/.exec(term);
    if (rating) {
        const set = new Set(rating[1].split(",").map((r) => r[0]));
        return (p) => set.has(p.rating ?? "");
    }
    const score = /^score:(<=|>=|<|>)?(-?\d+)$/.exec(term);
    if (score) {
        const n = Number(score[2]);
        const op = score[1] ?? "=";
        return (p) => {
            const s = p.score ?? 0;
            return op === "<" ? s < n : op === ">" ? s > n : op === "<=" ? s <= n : op === ">=" ? s >= n : s === n;
        };
    }
    return null;
}

export function ruleMatches(rule: Rule, tags: Set<string>, post: DanbooruPost): boolean {
    if (!rule.all.every((t) => tagMatch(tags, t))) return false;
    if (rule.none.some((t) => tagMatch(tags, t))) return false;
    if (rule.any.length && !rule.any.some((t) => tagMatch(tags, t))) return false;
    return rule.meta.every((m) => m(post));
}

// `tag*` matches a prefix, like Danbooru's wildcard
function tagMatch(tags: Set<string>, t: string): boolean {
    if (!t.endsWith("*")) return tags.has(t);
    const prefix = t.slice(0, -1);
    for (const tag of tags) if (tag.startsWith(prefix)) return true;
    return false;
}

// ---- Danbooru's post, and ours ----------------------------------------------------------------------------------------

export type DanbooruPost = {
    id?: number;
    rating?: string;
    tag_string?: string;
    tag_string_artist?: string;
    tag_string_character?: string;
    tag_string_copyright?: string;
    tag_string_general?: string;
    tag_string_meta?: string;
    score?: number;
    fav_count?: number;
    file_ext?: string;
    file_size?: number;
    image_width?: number;
    image_height?: number;
    created_at?: string;
    source?: string;
    file_url?: string;
    large_file_url?: string;
    preview_file_url?: string;
    is_deleted?: boolean;
    is_banned?: boolean;
    is_pending?: boolean;
    media_asset?: { variants?: { type?: string; url?: string; width?: number; height?: number }[] };
};

export type BooruMedia = "image" | "animated" | "video";

export type BooruPost = {
    id: number;
    rating: BooruLevel;
    blur: boolean;
    media: BooruMedia;
    ext: string;
    width: number;
    height: number;
    size: number;
    score: number;
    favs: number;
    created_at: string | null;
    source: string | null;
    page_url: string;
    thumb_url: string;
    sample_url: string;
    file_url: string;
    tags: { artist: string[]; character: string[]; copyright: string[]; general: string[]; meta: string[] };
};

const split = (s: string | undefined) => (s ? s.split(" ").filter(Boolean) : []);

export function mediaOf(ext: string): BooruMedia {
    if (ext === "mp4" || ext === "webm") return "video";
    if (ext === "gif" || ext === "zip") return "animated";
    return "image";
}

function variant(p: DanbooruPost, type: string): string | undefined {
    return p.media_asset?.variants?.find((v) => v.type === type)?.url;
}

const safeUrl = (u: string | undefined) => (u && /^https:\/\/[a-z0-9.-]+\.donmai\.us\//.test(u) ? u : undefined);

export type Refine = {
    min_score?: number;
    media?: BooruMedia;
    shape?: "tall" | "square" | "wide";
};

export type Verdict = { keep: false; why: "level" | "hard" | "theme" | "blacklist" | "refine" | "unusable" } | { keep: true; blur: boolean };

// What happens to one Danbooru post under these settings. Order matters: the level and the hard block first.
export function judge(p: DanbooruPost, level: BooruLevel, themes: Record<string, ThemeMode>, rules: Rule[], refine: Refine): Verdict {
    if (!isLevel(p.rating) || levelRank(p.rating) > levelRank(level)) return { keep: false, why: "level" };
    const tags = new Set(split(p.tag_string));
    if (HARD_BLOCK.some((t) => tags.has(t))) return { keep: false, why: "hard" };
    if (ALWAYS_HIDDEN.some((t) => tags.has(t))) return { keep: false, why: "level" };
    if (p.is_deleted || p.is_banned) return { keep: false, why: "unusable" };
    const file = safeUrl(p.file_url);
    if (!p.id || !file || ext(p) === "zip" || ext(p) === "swf") return { keep: false, why: "unusable" };
    let blur = false;
    for (const t of THEMES) {
        if (!t.tags.some((tag) => tags.has(tag))) continue;
        const mode = themes[t.id] ?? t.default;
        if (mode === "hide") return { keep: false, why: "theme" };
        if (mode === "blur") blur = true;
    }
    if (rules.some((r) => ruleMatches(r, tags, p))) return { keep: false, why: "blacklist" };
    if (refine.min_score !== undefined && (p.score ?? 0) < refine.min_score) return { keep: false, why: "refine" };
    if (refine.media && mediaOf(ext(p)) !== refine.media) return { keep: false, why: "refine" };
    if (refine.shape) {
        const w = p.image_width ?? 0;
        const h = p.image_height ?? 0;
        const r = h > 0 ? w / h : 1;
        const shape = r < 0.9 ? "tall" : r > 1.1 ? "wide" : "square";
        if (shape !== refine.shape) return { keep: false, why: "refine" };
    }
    return { keep: true, blur };
}

const ext = (p: DanbooruPost) => (p.file_ext ?? "").toLowerCase();

export function toPost(p: DanbooruPost, blur: boolean): BooruPost {
    const file = safeUrl(p.file_url)!;
    const sample = safeUrl(p.large_file_url) ?? file;
    const thumb = safeUrl(variant(p, "360x360")) ?? safeUrl(p.preview_file_url) ?? sample;
    return {
        id: p.id!,
        rating: p.rating as BooruLevel,
        blur,
        media: mediaOf(ext(p)),
        ext: ext(p),
        width: p.image_width ?? 0,
        height: p.image_height ?? 0,
        size: p.file_size ?? 0,
        score: p.score ?? 0,
        favs: p.fav_count ?? 0,
        created_at: p.created_at ?? null,
        source: p.source && /^https?:\/\//.test(p.source) ? p.source : null,
        page_url: `${DANBOORU}/posts/${p.id}`,
        thumb_url: thumb,
        sample_url: sample,
        file_url: file,
        tags: {
            artist: split(p.tag_string_artist),
            character: split(p.tag_string_character),
            copyright: split(p.tag_string_copyright),
            general: split(p.tag_string_general),
            meta: split(p.tag_string_meta),
        },
    };
}

// ---- search -----------------------------------------------------------------------------------------------------------

export type Order = "new" | "popular" | "score" | "favs" | "random";
export const ORDERS: readonly Order[] = ["new", "popular", "score", "favs", "random"];
const ORDER_TAG: Record<Order, string | null> = {
    new: null,
    popular: "order:rank",
    score: "order:score",
    favs: "order:favcount",
    random: "order:random",
};

export type SearchInput = { tags: string; page: number; order: Order; level?: string } & Refine;

export type SearchResult = {
    status: "success";
    level: BooruLevel;
    posts: BooruPost[];
    hidden: { level: number; theme: number; blacklist: number; refine: number; blocked: number };
    next_page: number | null;
    dropped: string[];
};

export class BooruError extends Error {
    constructor(
        readonly status: number,
        readonly code: string,
    ) {
        super(code);
    }
}

// The owner's tags, cleaned: lowercase, at most 2, and no metatag that could widen the level (rating:, status: and the
// like are ours to set). Throws error.booru.too_many_tags past 2.
export function cleanTags(raw: string): string[] {
    const out: string[] = [];
    for (const t of raw.trim().toLowerCase().split(/\s+/)) {
        if (!t) continue;
        const body = t.replace(/^[-~]/, "");
        if (!body || /^(rating|status|is|limit|order|ordfav|ordpool):/.test(body)) continue;
        out.push(t);
    }
    if (out.length > MAX_USER_TAGS) throw new BooruError(400, "error.booru.too_many_tags");
    return out;
}

const ratingClause = (level: BooruLevel) => `rating:${LEVELS.slice(0, levelRank(level) + 1).join(",")}`;

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

async function getJson(fetchFn: FetchFn, url: string): Promise<{ status: number; body: unknown }> {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    try {
        const res = await Promise.race([
            fetchFn(url, { headers: { "user-agent": USER_AGENT, accept: "application/json" }, signal: ctl.signal }),
            new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timeout")), TIMEOUT_MS)),
        ]);
        let body: unknown = null;
        try {
            body = await res.json();
        } catch {
            body = null;
        }
        if (res.status >= 400 || body === null) {
            console.error("[booru] danbooru answered", res.status, res.headers.get("cf-mitigated"), res.headers.get("server"), url.split("?")[0]);
        }
        return { status: res.status, body };
    } catch (e) {
        if (e instanceof BooruError) throw e;
        console.error("[booru] danbooru fetch failed", String(e), url.split("?")[0]);
        throw new BooruError(502, "error.booru.upstream");
    } finally {
        clearTimeout(timer);
    }
}

const tagLimitRefusal = (status: number, body: unknown) =>
    status === 422 && /tag/i.test(JSON.stringify(body ?? "")) && /limit|more than|cannot search/i.test(JSON.stringify(body ?? ""));

// Every filter over one page of Danbooru posts: the level, the hard block, the themes, the blacklist and refine.
export function filterPosts(raw: DanbooruPost[], level: BooruLevel, themes: Record<string, ThemeMode>, rules: Rule[], refine: Refine) {
    const hidden = { level: 0, theme: 0, blacklist: 0, refine: 0, blocked: 0 };
    const posts: BooruPost[] = [];
    for (const p of raw) {
        if (!p || typeof p !== "object") continue;
        const v = judge(p, level, themes, rules, refine);
        if (v.keep) posts.push(toPost(p, v.blur));
        else if (v.why === "level") hidden.level++;
        else if (v.why === "hard") hidden.blocked++;
        else if (v.why === "theme") hidden.theme++;
        else if (v.why === "blacklist") hidden.blacklist++;
        else if (v.why === "refine") hidden.refine++;
    }
    return { posts, hidden };
}

// POST /booru/filter (72.7): Danbooru answers the apps' own requests but refuses the Worker's (live, 2026-11-21), so the
// apps fetch a page of posts.json themselves and hand it here; this key's settings decide what comes back, exactly as on
// GET /booru/posts.
export type FilterInput = { posts: unknown[]; level?: string } & Refine;

export function filterRaw(settings: BooruSettings, input: FilterInput) {
    const level: BooruLevel = "g"; // general only; an older app's `level` is ignored (72.9)
    const raw = input.posts.filter((p): p is DanbooruPost => !!p && typeof p === "object" && !Array.isArray(p));
    const { posts, hidden } = filterPosts(raw, level, settings.themes, parseBlacklist(settings.blacklist), input);
    return { status: "success" as const, level, posts, hidden };
}

export async function searchPosts(fetchFn: FetchFn, settings: BooruSettings, input: SearchInput): Promise<SearchResult> {
    const level: BooruLevel = "g"; // general only; an older app's `level` is ignored (72.9)
    const userTags = cleanTags(input.tags);
    const rules = parseBlacklist(settings.blacklist);
    const order = ORDER_TAG[input.order];
    // extras in the order they are given up when Danbooru refuses the tag count
    const extras: { name: string; tag: string }[] = [];
    if (order) extras.push({ name: "order", tag: order });
    extras.push({ name: "rating", tag: ratingClause(level) });
    const dropped: string[] = [];
    let answer: { status: number; body: unknown } | null = null;
    for (;;) {
        const q = [...userTags, ...extras.map((e) => e.tag)].join(" ");
        const url = `${DANBOORU}/posts.json?limit=${PAGE_LIMIT}&page=${input.page}&tags=${encodeURIComponent(q)}`;
        answer = await getJson(fetchFn, url);
        if (tagLimitRefusal(answer.status, answer.body) && extras.length) {
            dropped.push(extras.shift()!.name);
            continue;
        }
        break;
    }
    if (answer.status === 429) throw new BooruError(429, "error.booru.busy");
    if (answer.status >= 400 || !Array.isArray(answer.body)) throw new BooruError(502, "error.booru.upstream");
    const raw = answer.body as DanbooruPost[];
    const { posts, hidden } = filterPosts(raw, level, settings.themes, rules, input);
    return {
        status: "success",
        level,
        posts,
        hidden,
        // Danbooru's numbered pages stop at 1000 for anonymous searches
        next_page: raw.length >= PAGE_LIMIT && input.page < 1000 ? input.page + 1 : null,
        dropped,
    };
}

// GET /booru/autocomplete: Danbooru's tag suggestions, with their kind (0 general, 1 artist, 3 copyright, 4 character,
// 5 meta) and post count. The hard-blocked tags are never suggested.
export type Suggestion = { name: string; kind: "general" | "artist" | "copyright" | "character" | "meta"; count: number };
const KINDS: Record<number, Suggestion["kind"]> = { 0: "general", 1: "artist", 3: "copyright", 4: "character", 5: "meta" };

export async function autocomplete(fetchFn: FetchFn, q: string): Promise<Suggestion[]> {
    const term = q.trim().toLowerCase().replace(/^[-~]/, "");
    if (!term || term.includes(":")) return [];
    const url = `${DANBOORU}/autocomplete.json?search[query]=${encodeURIComponent(term)}&search[type]=tag_query&limit=10`;
    const answer = await getJson(fetchFn, url);
    if (answer.status >= 400 || !Array.isArray(answer.body)) throw new BooruError(502, "error.booru.upstream");
    const out: Suggestion[] = [];
    for (const s of answer.body as { value?: string; category?: number; post_count?: number }[]) {
        const name = s.value ?? "";
        if (!name || name.includes(":") || HARD_BLOCK.some((b) => name === b || name.startsWith(`${b}_`))) continue;
        out.push({ name, kind: KINDS[s.category ?? 0] ?? "general", count: s.post_count ?? 0 });
    }
    return out;
}
