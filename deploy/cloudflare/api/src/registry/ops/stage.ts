// Stage and emote ops (APP-API-CONTRACT.md 33.10): the stage owner routes (section 30.10) and the 7TV routes (section
// 20), tier hidden, wrapping the existing handlers unchanged; plus the chat AI's calls cobalt.stage.* and
// cobalt.emotes.*. Locking or unlocking the viewer store asks Harmony first. Rewards, redemptions, the canvas token and
// Twitch connect stay owner-only (no AI call).
import * as z from "zod";
import { stageDepsFrom } from "../../deps";
import { EMOTE_SORT_KEYS, FIND_MANY_MAX, VARIANT_PAGES_MAX, VARIANT_WORDS_MAX, deepVariants, findManyEmotes, saveEmote, searchEmotes, type EmoteSort } from "../../emotes";
import { parseMediaRef } from "../../media-refs";
import { stageKeyed, type StageDeps, type StageOp } from "../../stage";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { bodyRequest, findCollection, linkFiles, makeLink, collectionDeps, unwrap } from "./share";
import { createCollection, updateCollection } from "../../share-collections";
import { SHARE_SET_MAX } from "../../share-sets";

// /stage/rewards/<action>
export const STAGE_ACTION_REGEX = /^(summon|chaos|shuffle|pin|skip)$/;

const stageDeps = (ctx: OpContext): StageDeps | null => stageDepsFrom(ctx.env, ctx.edge, ctx.stageEdge);
const offBody = { status: "error", error: { code: "error.stage.off" } };

// ---- the routes (tier hidden) ---------------------------------------------------------------------------------------

const NoInput = z.object({});

const stageRoute = (op: StageOp, method: "GET" | "POST" | "PATCH" | "DELETE", path: string, params?: Record<string, RegExp>) =>
    defineOp({
        name: `stage_owner.${op}`,
        route: { method, path, ...(params ? { params } : {}) },
        auth: "key",
        runs: "worker",
        cors: true,
        noStore: true,
        input: NoInput,
        http: () => ({}),
        ai: { tier: "hidden", summary: `${method} ${path}` },
        handler: async (ctx): Promise<OpReply> => {
            const d = stageDeps(ctx);
            if (!d) return { status: 404, body: offBody };
            // the token goes to a signed-in device only, never to a key for tools
            if (op === "twitch_session") {
                const row = await ctx.db.prepare("SELECT kind FROM api_keys WHERE id = ?1").bind(ctx.keyId).first<{ kind: string }>();
                if (row?.kind !== "session") return { status: 403, body: { status: "error", error: { code: "error.stage.twitch_session_device_only" } } };
            }
            const r = await stageKeyed(d, op, ctx.request!, ctx.params, ctx.query);
            return { status: r.status, body: r.body };
        },
    });

const STAGE_ROUTES = [
    stageRoute("get", "GET", "/stage"),
    stageRoute("patch", "PATCH", "/stage"),
    stageRoute("rotate", "POST", "/stage/rotate"),
    stageRoute("action", "POST", "/stage/action"),
    stageRoute("pool", "GET", "/stage/pool"),
    stageRoute("redemptions", "GET", "/stage/redemptions"),
    stageRoute("twitch_delete", "DELETE", "/stage/twitch"),
    stageRoute("twitch_connect", "POST", "/stage/twitch/connect"),
    stageRoute("twitch_session", "GET", "/stage/twitch/session"),
    stageRoute("reward", "PATCH", "/stage/rewards/:action", { action: STAGE_ACTION_REGEX }),
];

// 7TV search and save (section 20): keyed or the library service, CORS, Worker only.
const EMOTE_ROUTES = [
    defineOp({
        name: "emotes_http.search",
        route: { method: "GET", path: "/emotes" },
        auth: "key_or_service",
        runs: "worker",
        cors: true,
        input: NoInput,
        http: () => ({}),
        ai: { tier: "hidden", summary: "GET /emotes" },
        handler: async (ctx) => {
            const r = await searchEmotes(ctx.app(), ctx.query);
            return { status: r.status, body: r.body };
        },
    }),
    defineOp({
        name: "emotes_http.save",
        route: { method: "POST", path: "/emotes" },
        auth: "key_or_service",
        runs: "worker",
        cors: true,
        input: NoInput,
        http: () => ({}),
        ai: { tier: "hidden", summary: "POST /emotes" },
        handler: async (ctx) => {
            const r = await saveEmote(ctx.app(), ctx.request!, ctx.keyId!);
            return { status: r.status, body: r.body };
        },
    }),
];

// ---- the chat AI's calls --------------------------------------------------------------------------------------------

const STAGE_MESSAGES: Record<string, string> = {
    "error.stage.off": "the studio (stage) is off on this server",
    "error.stage.off_air": "the studio is off air: cobalt.stage.set({ on_air: true }) first",
    "error.stage.not_found": "that file is not in the studio's pool (cobalt.stage.items() lists it)",
    "error.stage.videos_only": "the spotlight is videos only: pick a video from cobalt.stage.items()",
    "error.stage.search_unavailable": "the meaning search is asleep or off, so a search pool cannot be made now: try again in a minute",
    "error.stage.bad_request": "the studio refused those settings",
};

const needStage = (ctx: OpContext): StageDeps => {
    const d = stageDeps(ctx);
    if (!d) throw new OpError(404, "error.stage.off", STAGE_MESSAGES["error.stage.off"]);
    return d;
};

const run = async (ctx: OpContext, op: StageOp, body?: unknown, q: Record<string, string> = {}): Promise<Record<string, unknown>> => {
    const d = needStage(ctx);
    const req = body === undefined ? new Request("https://chat.internal/") : bodyRequest(op === "patch" ? "PATCH" : "POST", body);
    const r: StudioReply = await stageKeyed(d, op, req, {}, new URLSearchParams(q));
    const { status: _s, ...rest } = unwrap<Record<string, unknown>>(r, STAGE_MESSAGES);
    return rest;
};

const PoolInfo = z.object({
    kind: z.enum(["library", "collection", "group", "search"]).describe("group = a set"),
    ref: z.string().nullable().describe("the collection or set id, or the search words"),
    name: z.string().nullable(),
    count: z.number().describe("files in the pool"),
    missing: z.boolean().describe("its collection or set was deleted"),
});
const StageInfo = z
    .object({
        on_air: z.boolean(),
        pool: PoolInfo,
        density: z.number(),
        tile_seconds: z.number(),
        tile_scale: z.number(),
        spotlight_auto: z.boolean(),
        spotlight_seconds: z.number(),
        sound: z.boolean(),
        sound_all: z.boolean(),
        play_through: z.boolean(),
        video_max: z.number(),
        store_open: z.boolean().describe("the viewer store (store_url) is unlocked"),
        store_hint: z.boolean(),
        live_url: z.string().describe("the OBS browser-source link: private, never share it"),
        store_url: z.string(),
        twitch: z.unknown().describe("null while Twitch is not connected"),
        spotlight: z.unknown().describe("what is spotlit right now, or null"),
        updated_at: z.number(),
        connected_canvases: z.number().nullable().describe("canvases (OBS browser sources) connected to the studio right now; 0 means nothing is showing it; null = not known"),
    })
    .meta({ id: "Stage" });
const StageItem = z
    .object({ id: z.string().describe("a file id"), code: z.string(), title: z.string().nullable(), kind: z.enum(["image", "video"]), url: z.string() })
    .meta({ id: "StageItem" });

export const stageGetOp = defineOp({
    name: "stage.get",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: StageInfo,
    ai: {
        tier: "free",
        only: true,
        summary: 'The studio: Harmony\'s stream canvas (an OBS browser source) that shows public files from its pool, and the viewers\' store.\nIn the app and to Harmony it is called "studio".',
    },
    handler: async (ctx) => ok((await run(ctx, "get")).stage),
});

// Every setting PATCH /stage takes except the pool (cobalt.stage.pool) and the store lock (cobalt.stage.store).
const Settings = z
    .object({
        on_air: z.boolean().optional().describe("the canvas shows files"),
        density: z.number().optional().describe("tiles on screen, 0..100 (0 = no scatter: only the spotlight, summons and chaos show)"),
        tile_seconds: z.number().optional().describe("3..120"),
        tile_scale: z.number().optional().describe("0.5..1.6"),
        spotlight_auto: z.boolean().optional(),
        spotlight_seconds: z.number().optional().describe("10..120"),
        sound: z.boolean().optional().describe("the spotlight plays sound"),
        sound_all: z.boolean().optional().describe("every video plays sound"),
        play_through: z.boolean().optional().describe("a playing video stays until it has played once"),
        video_max: z.number().optional().describe("videos on screen at once, 0..24"),
        store_hint: z.boolean().optional().describe("the canvas shows the store's link"),
    })
    .strict()
    .refine((o) => Object.keys(o).length > 0, { message: "give at least one setting" });

export const stageSetOp = defineOp({
    name: "stage.set",
    auth: "key",
    runs: "worker",
    cors: false,
    input: Settings,
    output: StageInfo,
    ai: {
        tier: "free",
        only: true,
        summary: "Change studio settings (numbers out of range are clamped). The pool and the store lock have their own calls.",
        options: true,
    },
    handler: async (ctx, input) => ok((await run(ctx, "patch", input)).stage),
});

export const stageStoreOp = defineOp({
    name: "stage.store",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ open: z.boolean().describe("true unlocks the viewer store, false locks it (viewers get a 404)") }),
    output: StageInfo,
    ai: {
        tier: "ask",
        only: true,
        summary: "Lock or unlock the viewers' store.",
        params: ["open"],
        preview: async (ctx, input) => {
            const d = needStage(ctx);
            const row = await ctx.db.prepare("SELECT store_open FROM stage_settings WHERE id = 'main'").first<{ store_open: number }>().catch(() => null);
            return {
                summary: input.open ? "unlock the viewer store" : "lock the viewer store",
                effect: { store_url: `${d.stageBaseUrl}store`, now: row?.store_open === 1 ? "open" : "locked", after: input.open ? "open" : "locked" },
            };
        },
    },
    handler: async (ctx, input) => ok((await run(ctx, "patch", { store_open: input.open })).stage),
});

// stage.pool(postIds): the files go into gallery links filed in this collection, and the pool is that collection.
export const STAGE_PICKS = "stage picks";
export const STAGE_PICKS_MAX_FILES = 200;

// n files in links of at most SHARE_SET_MAX and at least 2 (n >= 2), as even as they go.
export function chunks<T>(xs: T[], max = SHARE_SET_MAX): T[][] {
    const k = Math.ceil(xs.length / max);
    const out: T[][] = [];
    let at = 0;
    for (let i = 0; i < k; i++) {
        const size = Math.floor(xs.length / k) + (i < xs.length % k ? 1 : 0);
        out.push(xs.slice(at, at + size));
        at += size;
    }
    return out;
}

async function picksCollection(ctx: OpContext, ids: string[]): Promise<{ id: string; links: number; notPublic: string[]; files: number }> {
    const found = await linkFiles(ctx, ids);
    if (found.unknown.length > 0) throw new OpError(404, "error.share.not_found", `no post or file with id ${found.unknown.join(", ")}`);
    if (found.files.length < 2) {
        throw new OpError(400, "error.stage.bad_request", `the studio needs at least 2 public files (${found.files.length} given${found.notPublic.length ? `; not public: ${found.notPublic.join(", ")}` : ""})`);
    }
    if (found.files.length > STAGE_PICKS_MAX_FILES) {
        throw new OpError(400, "error.stage.bad_request", `that is ${found.files.length} files; pick at most ${STAGE_PICKS_MAX_FILES}, or use a search, a collection or a set as the pool`);
    }
    const cd = collectionDeps(ctx);
    if (!cd) throw new OpError(404, "error.share.off", "share links are off on this server, so a pool of picks cannot be made");
    // no inline captions: the 15-minute cron writes them
    const links: string[] = [];
    for (const part of chunks(found.files)) {
        const l = await makeLink(ctx, part, STAGE_PICKS, { captions: false });
        links.push(l.id!);
    }
    const existing = await findCollection(ctx.db, STAGE_PICKS);
    let id: string;
    if (existing) {
        const { results } = await ctx.db
            .prepare("SELECT set_id FROM share_collection_items WHERE collection_id = ?1")
            .bind(existing.id)
            .all<{ set_id: string }>();
        // the collection holds only this pool's links; earlier picks' links stay live in the links tab
        const r = await updateCollection(cd, bodyRequest("PATCH", { add: links, remove: results.map((x) => x.set_id).filter((x) => !links.includes(x)) }), existing.id);
        id = unwrap<{ collection: { id: string } }>(r).collection.id;
    } else {
        const r = await createCollection(cd, bodyRequest("POST", { name: STAGE_PICKS, set_ids: links }), ctx.keyId!);
        id = unwrap<{ collection: { id: string } }>(r, { "error.collection.too_many": "there are already 100 collections, so the picks have nowhere to go" }).collection.id;
    }
    return { id, links: links.length, notPublic: found.notPublic, files: found.files.length };
}

export const stagePoolOp = defineOp({
    name: "stage.pool",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        pool: z.union([
            z.literal("library"),
            z.array(z.string().min(1).max(2048)).min(1),
            z.object({ collection: z.string().min(1) }).strict(),
            z.object({ set: z.string().min(1) }).strict(),
            z.object({ search: z.string().trim().min(1).max(200) }).strict(),
        ]),
    }),
    output: z.object({
        pool: PoolInfo,
        links: z.number().optional().describe(`picks only: the gallery links made for them, filed in "${STAGE_PICKS}"`),
        not_public: z.array(z.string()).optional().describe("picks left out because they are private"),
    }),
    ai: {
        tier: "free",
        only: true,
        summary: `What the studio shows: "library" (the newest public files), an array of post ids (they become gallery links in the collection "${STAGE_PICKS}"), { collection }, { set } (an id or a name) or { search: "words" }.\nOnly public files ever reach the canvas.`,
        params: ["pool"],
    },
    handler: async (ctx, input) => {
        needStage(ctx);
        const p = input.pool;
        let spec: { kind: string; ref?: string };
        let extra: Record<string, unknown> = {};
        if (p === "library") spec = { kind: "library" };
        else if (Array.isArray(p)) {
            const picks = await picksCollection(ctx, [...new Set(p)]);
            spec = { kind: "collection", ref: picks.id };
            extra = { links: picks.links, ...(picks.notPublic.length ? { not_public: picks.notPublic } : {}) };
        } else if ("collection" in p) {
            const c = await findCollection(ctx.db, p.collection);
            if (!c) throw new OpError(404, "error.collection.not_found", `no collection called or with id "${p.collection}"`);
            spec = { kind: "collection", ref: c.id };
        } else if ("set" in p) {
            const g = await ctx.db
                .prepare("SELECT id FROM collection_groups WHERE id = ?1 OR lower(name) = lower(?1) ORDER BY (id = ?1) DESC, updated_at DESC LIMIT 1")
                .bind(p.set.trim())
                .first<{ id: string }>();
            if (!g) throw new OpError(404, "error.group.not_found", `no set called or with id "${p.set}"`);
            spec = { kind: "group", ref: g.id };
        } else spec = { kind: "search", ref: p.search };
        const s = (await run(ctx, "patch", { pool: spec })).stage as { pool: unknown };
        return ok({ pool: s.pool, ...extra });
    },
});

export const stageItemsOp = defineOp({
    name: "stage.items",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ offset: z.number().int().min(0).optional(), limit: z.number().int().min(1).max(100).optional().describe("default 60") }),
    output: z.object({ total: z.number(), offset: z.number(), next: z.number().nullable(), items: z.array(StageItem) }),
    ai: { tier: "free", only: true, summary: "The files in the studio's pool, a page at a time.", options: true },
    handler: async (ctx, input) => {
        const q: Record<string, string> = {};
        if (input.offset !== undefined) q.offset = String(input.offset);
        if (input.limit !== undefined) q.limit = String(input.limit);
        return ok(await run(ctx, "pool", undefined, q));
    },
});

export const stageActionOp = defineOp({
    name: "stage.action",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        type: z.enum(["skip", "pin", "unpin", "shuffle", "chaos", "spotlight"]),
        item_id: z.string().optional().describe("spotlight only: a file id from cobalt.stage.items()"),
    }),
    output: StageInfo,
    ai: { tier: "free", only: true, summary: "Do something on the live canvas (it must be on air).", params: ["type"], options: true },
    handler: async (ctx, input) => ok((await run(ctx, "action", input)).stage),
});

const EMOTE_MESSAGES: Record<string, string> = {
    "error.emote.query": "an emote search is up to 64 characters (a name is needed without a sort), page 1 to 50",
    "error.emote.unavailable": "7TV did not answer: try again later",
    "error.emote.not_found": "no 7TV emote with that id",
    "error.emote.too_big": "that emote's file is too big to save",
    "error.emote.rate_limited": "7TV is rate limiting: wait a little and try again",
};

const EmoteHitShape = z.object({
    id: z.string().describe("the 7TV emote id (for save)"),
    name: z.string(),
    animated: z.boolean(),
    preview_url: z.string(),
    file_url: z.string().describe("the largest webp on 7TV's CDN"),
    width: z.number(),
    height: z.number(),
    library_id: z.string().nullable().describe("already saved: its library file id"),
    library_url: z.string().nullable(),
});

export const emotesSearchOp = defineOp({
    name: "emotes.find",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z
        .object({
            query: z.string().trim().max(64).optional().describe("an emote name to look for; leave out to browse a sort"),
            sort: z
                .enum(EMOTE_SORT_KEYS as [EmoteSort, ...EmoteSort[]])
                .optional()
                .describe(
                    "top = most used of all time; top_daily/top_weekly/top_monthly = most used over that window; trending_daily/trending_weekly/trending_monthly = rising fastest; new = newest uploads; global = 7TV's global emote set. Default top.",
                ),
            page: z.number().int().min(1).max(50).optional().describe("24 per page, default 1"),
        })
        .refine((v) => (v.query ?? "").length > 0 || v.sort !== undefined, { message: "give a query, a sort, or both" }),
    output: z.object({
        sort: z.string(),
        page: z.number(),
        has_more: z.boolean(),
        items: z.array(EmoteHitShape),
        cached: z.literal(true).optional().describe("answered from the 24 h cache (section 62.5)"),
    }),
    ai: {
        tier: "free",
        only: true,
        summary: "Search or browse 7TV emotes: by name, and/or by top (all time, day, week, month), trending (day, week, month), new, or the global set.",
        params: ["query", "sort", "page"],
    },
    handler: async (ctx, input) => {
        const q = new URLSearchParams();
        if (input.query) q.set("q", input.query);
        q.set("sort", input.sort ?? "top");
        if (input.page) q.set("page", String(input.page));
        const r = await searchEmotes(ctx.app(), q);
        return ok(unwrap<{ items: unknown[]; sort: string; page: number; has_more: boolean }>(r, EMOTE_MESSAGES));
    },
});

// Section 62.5: several names in one 7TV request (the cache first), first page only.
export const emotesFindManyOp = defineOp({
    name: "emotes.findMany",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        queries: z.array(z.string().trim().min(1).max(64)).min(1).max(FIND_MANY_MAX).describe(`emote names to look for, 1 to ${FIND_MANY_MAX}`),
        sort: z.enum(EMOTE_SORT_KEYS as [EmoteSort, ...EmoteSort[]]).optional().describe("as emotes.find, default top"),
    }),
    output: z.object({
        sort: z.string(),
        results: z.array(z.object({ q: z.string(), emotes: z.array(EmoteHitShape).describe("the first page (24)"), cached: z.boolean() })),
    }),
    ai: {
        tier: "free",
        only: true,
        summary: `Look up several 7TV emote names at once (1 to ${FIND_MANY_MAX}): one request to 7TV instead of one each. Answers each name's first page.`,
        params: ["queries"],
        options: true,
    },
    handler: async (ctx, input) => ok(unwrap(await findManyEmotes(ctx.app(), input.queries, input.sort), EMOTE_MESSAGES)),
});

export const emotesSaveOp = defineOp({
    name: "emotes.save",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().min(1).max(64) }),
    output: z.record(z.string(), z.unknown()),
    ai: { tier: "free", only: true, summary: "Save a 7TV emote into the library as a public webp (an emote already saved is returned as is).", params: ["id"] },
    handler: async (ctx, input) => ok(unwrap(await saveEmote(ctx.app(), bodyRequest("POST", { id: input.id }), ctx.keyId!), EMOTE_MESSAGES)),
});

// Section 63.2: every same-name and seasonal-named upload of an emote, across all result pages.
export const emotesVariantsOp = defineOp({
    name: "emotes.variants",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z
        .object({
            emote: z.string().trim().min(1).max(200).optional().describe("the emote: a 7TV emote id or 7tv.app link (its own name, animated flag and shape are then the filters)"),
            name: z.string().trim().min(1).max(64).optional().describe("or just a name to look for (use the emote's real 7TV name, not a set alias)"),
            season: z.string().trim().max(20).optional().describe("christmas, halloween, valentine, easter, newyear or summer: also names with its words (xmas, santa...)"),
            words: z.array(z.string().trim().min(2).max(20)).max(VARIANT_WORDS_MAX).optional().describe("extra words a variant's name may carry"),
            animated: z.enum(["same", "any", "yes", "no"]).optional().describe("same (default when an emote is given) = the emote's own flag"),
            size: z.enum(["same", "any"]).optional().describe("same (default when an emote is given) = width:height within 8% of the emote's"),
            max_pages: z.number().int().min(1).max(VARIANT_PAGES_MAX).optional().describe(`pages of 24 per search (default and most ${VARIANT_PAGES_MAX})`),
        })
        .refine((v) => !!v.emote || !!v.name, { message: "give an emote or a name" }),
    output: z.object({
        name: z.string(),
        base: z.object({ emote_id: z.string(), animated: z.boolean(), width: z.number(), height: z.number() }).optional(),
        words: z.array(z.string()),
        filters: z.object({ animated: z.string(), size: z.string() }),
        pages_read: z.object({ same_name: z.number(), contains: z.number(), seasonal: z.number() }),
        complete: z.boolean().describe("every result page was read (false: more than max_pages)"),
        found: z.number().describe("matches before the animated and size filters"),
        dropped: z.object({ animated: z.number(), size: z.number() }),
        variants: z.array(
            z.object({
                emote_id: z.string(),
                name: z.string(),
                match: z.enum(["same_name", "contains", "seasonal"]),
                word: z.string().optional(),
                animated: z.boolean(),
                frames: z.number().nullable(),
                width: z.number(),
                height: z.number(),
                preview_url: z.string(),
                page_url: z.string(),
                library_id: z.string().nullable(),
            }),
        ),
    }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "Deep 7TV variant search: every upload with the emote's same name (any case), its name inside a longer one, and seasonal names (season: christmas finds LaPeaceXmas, SantaLaPeace...), across ALL result pages (not just the top few), filtered to the same animated flag and shape. Festive edits are often deep in the results. Then compare.canvas to look at them.",
        params: ["emote"],
        options: true,
    },
    handler: async (ctx, input) => {
        const p = input.emote ? parseMediaRef(input.emote, { mediaBaseUrl: ctx.mediaBaseUrl, hosts: [] }) : null;
        if (input.emote && p?.kind !== "emote") throw new OpError(400, "error.emote.query", "emotes.variants: emote is a 7TV emote id or link; give a plain name as name");
        const r = await deepVariants(ctx.app(), {
            ...(p?.kind === "emote" ? { emote_id: p.id } : {}),
            ...(input.name ? { name: input.name } : {}),
            ...(input.season ? { season: input.season } : {}),
            ...(input.words ? { words: input.words } : {}),
            ...(input.animated ? { animated: input.animated } : {}),
            ...(input.size ? { size: input.size } : {}),
            ...(input.max_pages ? { max_pages: input.max_pages } : {}),
        });
        return ok(unwrap(r, EMOTE_MESSAGES));
    },
});

export const STAGE_OPS = [
    ...STAGE_ROUTES,
    ...EMOTE_ROUTES,
    stageGetOp,
    stageSetOp,
    stageStoreOp,
    stagePoolOp,
    stageItemsOp,
    stageActionOp,
    emotesSearchOp,
    emotesFindManyOp,
    emotesSaveOp,
    emotesVariantsOp,
];
