// The booru tab (APP-API-CONTRACT.md section 72): Danbooru search, tag suggestions and each key's filter settings. The
// work is in src/booru.ts.
//  - A client key or a device session (auth "key"), CORS for the web app, no-store. Settings are per key, but only the
//    blacklist is still a setting.
//  - General only (72.9): no sensitive, questionable or explicit, every theme hidden. `level` and theme modes are still
//    accepted from older apps and ignored.
//  - Never the chat AI's or the MCP's (tier hidden).
import * as z from "zod";
import {
    autocomplete,
    filterRaw,
    BLACKLIST_MAX_CHARS,
    BooruError,
    LEVELS,
    ORDERS,
    readSettings,
    searchPosts,
    THEME_MODES,
    THEMES,
    writeSettings,
    type BooruSettings,
} from "../../booru";
import { defineOp, ok, type OpContext, type OpReply } from "../op";

const Status = z.literal("success");
const Level = z.literal("g").describe("g general, the only level there is");
// what older apps still send (8.37 and before): accepted, ignored
const LegacyLevel = z.enum(["g", "s"]).describe("ignored: general is the only level (older apps sent s)");
const Mode = z.enum(THEME_MODES as unknown as ["show", "blur", "hide"]);
const ThemeIds = THEMES.map((t) => t.id) as [string, ...string[]];

const fail = (status: number, code: string): OpReply => ({ status, body: { status: "error", error: { code } } });
const guard = async (run: () => Promise<OpReply>): Promise<OpReply> => {
    try {
        return await run();
    } catch (e) {
        if (e instanceof BooruError) return fail(e.status, e.code);
        console.error("[booru] failed", String(e));
        return fail(500, "error.booru.generic");
    }
};

const settingsBody = (s: BooruSettings) => ({
    status: "success" as const,
    level: s.level,
    levels: [...LEVELS],
    themes: s.themes,
    theme_list: THEMES.map((t) => ({ id: t.id, label: t.label, detail: t.detail, default: t.default, min_level: t.min_level, tags: t.tags })),
    blacklist: s.blacklist,
    updated_at: s.updated_at,
});

const fetchFn = (url: string, init?: RequestInit) => fetch(url, init);

const PostShape = z
    .object({
        id: z.number().int(),
        rating: Level,
        blur: z.boolean().describe("always false now: a theme match hides the post"),
        media: z.enum(["image", "animated", "video"]),
        ext: z.string(),
        width: z.number().int(),
        height: z.number().int(),
        size: z.number().int(),
        score: z.number().int(),
        favs: z.number().int(),
        created_at: z.string().nullable(),
        source: z.string().nullable(),
        page_url: z.string(),
        thumb_url: z.string(),
        sample_url: z.string(),
        file_url: z.string(),
        tags: z.object({
            artist: z.array(z.string()),
            character: z.array(z.string()),
            copyright: z.array(z.string()),
            general: z.array(z.string()),
            meta: z.array(z.string()),
        }),
    })
    .meta({ id: "BooruPost" });

const SearchQuery = z.object({
    tags: z.string().max(200).optional().default(""),
    page: z.coerce.number().int().min(1).max(1000).optional().default(1),
    order: z.enum(ORDERS as unknown as ["new", "popular", "score", "favs", "random"]).optional().default("new"),
    level: LegacyLevel.optional(),
    min_score: z.coerce.number().int().min(-100).max(100000).optional(),
    media: z.enum(["image", "animated", "video"]).optional(),
    shape: z.enum(["tall", "square", "wide"]).optional(),
});

export const SettingsPatch = z.object({
    level: LegacyLevel.optional(),
    // ignored (every theme is hidden); partialRecord: zod 4's record with enum keys requires every key, which refused every one-theme change (live 400s)
    themes: z.partialRecord(z.enum(ThemeIds), Mode).optional(),
    blacklist: z.string().max(BLACKLIST_MAX_CHARS).optional(),
});

const SettingsShape = z.object({
    status: Status,
    level: Level,
    levels: z.array(Level),
    themes: z.record(z.string(), Mode),
    theme_list: z.array(
        z.object({ id: z.string(), label: z.string(), detail: z.string(), default: Mode, min_level: Level, tags: z.array(z.string()) }),
    ),
    blacklist: z.string(),
    updated_at: z.number().int().nullable(),
});

const base = { auth: "key" as const, runs: "worker" as const, cors: true, noStore: true, badRequest: "error.booru.bad" };

export const BOORU_OPS = [
    defineOp({
        ...base,
        name: "booru.posts",
        route: { method: "GET", path: "/booru/posts" },
        input: SearchQuery,
        http: (ctx: OpContext) => Object.fromEntries(ctx.query),
        output: z.object({
            status: Status,
            level: Level,
            posts: z.array(PostShape),
            hidden: z.object({ level: z.number().int(), theme: z.number().int(), blacklist: z.number().int(), refine: z.number().int(), blocked: z.number().int() }),
            next_page: z.number().int().nullable(),
            dropped: z.array(z.string()).describe("extras Danbooru's 2-tag limit did not take (order, rating); filtered here anyway"),
        }),
        ai: { tier: "hidden", summary: "Danbooru posts under this key's level and filters (GET /booru/posts)." },
        handler: (ctx, input) =>
            guard(async () => {
                const settings = await readSettings(ctx.db, ctx.keyId!);
                return ok(await searchPosts(fetchFn, settings, input));
            }),
    }),
    defineOp({
        ...base,
        name: "booru.filter",
        route: { method: "POST", path: "/booru/filter" },
        input: z.object({
            posts: z.array(z.unknown()).max(200).describe("one page of Danbooru's posts.json, as the app fetched it"),
            level: LegacyLevel.optional(),
            min_score: z.number().int().min(-100).max(100000).optional(),
            media: z.enum(["image", "animated", "video"]).optional(),
            shape: z.enum(["tall", "square", "wide"]).optional(),
        }),
        output: z.object({
            status: Status,
            level: Level,
            posts: z.array(PostShape),
            hidden: z.object({ level: z.number().int(), theme: z.number().int(), blacklist: z.number().int(), refine: z.number().int(), blocked: z.number().int() }),
        }),
        ai: { tier: "hidden", summary: "Filter a page of Danbooru posts the app fetched under this key's level and filters (POST /booru/filter)." },
        handler: (ctx, input) =>
            guard(async () => ok(filterRaw(await readSettings(ctx.db, ctx.keyId!), input))),
    }),
    defineOp({
        ...base,
        name: "booru.autocomplete",
        route: { method: "GET", path: "/booru/autocomplete" },
        input: z.object({ q: z.string().max(100).optional().default("") }),
        http: (ctx: OpContext) => Object.fromEntries(ctx.query),
        output: z.object({
            status: Status,
            tags: z.array(z.object({ name: z.string(), kind: z.enum(["general", "artist", "copyright", "character", "meta"]), count: z.number().int() })),
        }),
        ai: { tier: "hidden", summary: "Danbooru tag suggestions (GET /booru/autocomplete)." },
        handler: (_ctx, input) => guard(async () => ok({ status: "success", tags: await autocomplete(fetchFn, input.q) })),
    }),
    defineOp({
        ...base,
        name: "booru.settings",
        route: { method: "GET", path: "/booru/settings" },
        input: z.object({}),
        http: () => ({}),
        output: SettingsShape,
        ai: { tier: "hidden", summary: "This key's booru level, themes and blacklist (GET /booru/settings)." },
        handler: (ctx) => guard(async () => ok(settingsBody(await readSettings(ctx.db, ctx.keyId!)))),
    }),
    defineOp({
        ...base,
        name: "booru.settings_update",
        route: { method: "PUT", path: "/booru/settings" },
        input: SettingsPatch,
        output: SettingsShape,
        ai: { tier: "hidden", summary: "Change this key's booru level, themes or blacklist (PUT /booru/settings)." },
        handler: (ctx, input) =>
            guard(async () => {
                try {
                    return ok(settingsBody(await writeSettings(ctx.db, ctx.keyId!, input, ctx.now())));
                } catch (e) {
                    if (e instanceof BooruError) throw e;
                    // the table is missing until migration 0046 is applied
                    console.error("[booru] settings write failed", String(e));
                    return fail(503, "error.booru.not_ready");
                }
            }),
    }),
];
