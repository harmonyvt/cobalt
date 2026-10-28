// Stage and emote ops (APP-API-CONTRACT.md 33.8): the stage owner routes (section 30.10) and the 7TV routes (section
// 20), tier hidden, wrapping the existing handlers unchanged; plus the chat AI's calls cobalt.stage.* and
// cobalt.emotes.*. Locking or unlocking the viewer store asks Harmony first. Rewards, redemptions, the canvas token and
// Twitch connect stay owner-only (no AI call).
import * as z from "zod";
import { stageDepsFrom } from "../../deps";
import { saveEmote, searchEmotes } from "../../emotes";
import { stageKeyed, type StageDeps, type StageOp } from "../../stage";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { bodyRequest, findCollection, linkFiles, makeLink, collectionDeps, unwrap } from "./share";
import { createCollection, updateCollection } from "../../share-collections";
import { SHARE_SET_MAX } from "../../share-sets";

// /stage/rewards/<action>
export const STAGE_ACTION_REGEX = /^(summon|chaos|shuffle|pin)$/;

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
        density: z.number().optional().describe("tiles on screen, 5..100"),
        tile_seconds: z.number().optional().describe("3..120"),
        tile_scale: z.number().optional().describe("0.5..1.6"),
        spotlight_auto: z.boolean().optional(),
        spotlight_seconds: z.number().optional().describe("10..120"),
        sound: z.boolean().optional().describe("the spotlight plays sound"),
        sound_all: z.boolean().optional().describe("every video plays sound"),
        play_through: z.boolean().optional().describe("video tiles stay until played once"),
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
    "error.emote.query": "an emote search is 1 to 64 characters",
    "error.emote.unavailable": "7TV did not answer: try again later",
    "error.emote.not_found": "no 7TV emote with that id",
    "error.emote.too_big": "that emote's file is too big to save",
};

export const emotesSearchOp = defineOp({
    name: "emotes.find",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ query: z.string().trim().min(1).max(64) }),
    output: z.array(
        z.object({
            id: z.string().describe("the 7TV emote id (for save)"),
            name: z.string(),
            animated: z.boolean(),
            preview_url: z.string(),
            library_id: z.string().nullable().describe("already saved: its library file id"),
        }),
    ),
    ai: { tier: "free", only: true, summary: "Search 7TV emotes by name.", params: ["query"] },
    handler: async (ctx, input) => {
        const r = await searchEmotes(ctx.app(), new URLSearchParams({ q: input.query }));
        return ok(unwrap<{ items: unknown[] }>(r, EMOTE_MESSAGES).items);
    },
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
    emotesSaveOp,
];
