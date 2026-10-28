// Library ops (APP-API-CONTRACT.md 33.4): the chat AI's read tools (section 27.3, now under cobalt.library.*, cobalt.links.*,
// cobalt.collections.*, plus look, show and collage) and the library read routes (GET /library, /library/search,
// /library/map, /queue). The route ops wrap the existing handlers unchanged: same parsing, same bodies, same headers.
import * as z from "zod";
import { libraryList } from "../../app-routes";
import { LIBRARY_MAX_LIMIT, SEARCH_MAX } from "../../chat-tools";
import { libraryMap, librarySearch } from "../../embed";
import { queueSnapshot } from "../../queue";
import { defineOp, ok, OpError, type OpContext } from "../op";

// ---- shapes the model sees ------------------------------------------------------------------------------------------

export const PostSchema = z
    .object({
        id: z.string().describe("the post id (use it with post, look, show)"),
        title: z.string().nullable(),
        saved_at: z.string().describe("ISO date it was saved"),
        source: z.string().nullable().describe('host it was saved from, e.g. "tiktok.com", "x.com"'),
        link: z.string().nullable().describe("the original link"),
        kind: z.enum(["video", "image", "gallery"]),
        files: z.number().describe("items in a gallery, else 1"),
        duration: z.number().nullable().describe("seconds (videos)"),
        public: z.boolean().describe("has a public link"),
        caption: z.string().nullable().describe("the roast caption title, if written"),
    })
    .meta({ id: "Post" });

const PostFileSchema = z
    .object({
    id: z.string(),
    name: z.string().nullable(),
    role: z.string(),
    kind: z.enum(["video", "image"]),
    content_type: z.string().nullable(),
    duration: z.number().nullable(),
    width: z.number().nullable(),
    height: z.number().nullable(),
    bytes: z.number().nullable(),
    public: z.boolean(),
    url: z.string().nullable(),
    share_url: z.string().nullable(),
    })
    .meta({ id: "PostFile" });

const LinkSchema = z.object({ id: z.string(), url: z.string().nullable(), title: z.string().nullable(), created_at: z.string(), post_ids: z.array(z.string()) });
const CollectionSchema = z.object({ id: z.string(), name: z.string(), link_ids: z.array(z.string()) });

// ids: one id or a list (the tools always took both); anything that is not a string is dropped, as before
const Ids = z.preprocess(
    (v) => (Array.isArray(v) ? v : [v]).filter((x) => typeof x === "string"),
    z.array(z.string()),
);
const When = z.union([z.string(), z.number()]);

// The read tools of chat-tools.ts, for this code run.
const tools = (ctx: OpContext) => {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", "only the chat can call this");
    return ctx.chat.tools;
};

// ---- the chat AI's read tools -----------------------------------------------------------------------------------------

export const libraryListOp = defineOp({
    name: "library.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        since: When.optional().describe("ISO date or ms"),
        until: When.optional().describe("ISO date or ms"),
        source: z.string().optional().describe('a host, e.g. "tiktok.com"'),
        kind: z.enum(["video", "image", "gallery"]).optional(),
        query: z.string().optional().describe("substring of title, names, link, caption"),
        limit: z.number().int().min(1).optional().describe(`default 100, max ${LIBRARY_MAX_LIMIT}`),
    }),
    output: z.array(PostSchema),
    ai: {
        tier: "free",
        only: true,
        summary: "Posts newest first. since/until: ISO date or ms. source: a host. query: substring of title, names, link, caption.",
        aliases: ["library"],
        options: true,
    },
    handler: async (ctx, input) => ok(await tools(ctx).library!(input)),
});

export const librarySearchOp = defineOp({
    name: "library.search",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        query: z.string().min(1).max(200),
        limit: z.number().int().min(1).optional(),
    }),
    output: z.array(z.intersection(PostSchema, z.object({ score: z.number() }))),
    ai: {
        tier: "free",
        only: true,
        summary: `Meaning search over titles and pictures, best first (default 10, max ${SEARCH_MAX}; every post gets a score, so cut where the scores drop). Throws while the search model is waking up.`,
        aliases: ["search"],
        params: ["query", "limit"],
        when: (f) => f.search,
    },
    handler: async (ctx, input) => ok(await tools(ctx).search!(input.query, input.limit)),
});

export const libraryPostOp = defineOp({
    name: "library.post",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().min(1) }),
    output: z.intersection(PostSchema, z.object({ files: z.array(PostFileSchema) })),
    ai: {
        tier: "free",
        only: true,
        summary: "One post with its files (public url and share_url when public).",
        aliases: ["post"],
        params: ["id"],
    },
    handler: async (ctx, input) => ok(await tools(ctx).post!(input.id)),
});

export const lookOp = defineOp({
    name: "look",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ids: Ids }),
    output: z.number(),
    ai: {
        tier: "free",
        only: true,
        summary: "You get to SEE these posts' pictures (poster or image) after this code returns. Max 4 per reply. Returns how many are queued.",
        params: ["ids"],
    },
    handler: async (ctx, input) => ok(await tools(ctx).look!(input.ids)),
});

export const showOp = defineOp({
    name: "show",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ids: Ids }),
    output: z.array(z.string()),
    ai: {
        tier: "free",
        only: true,
        summary: "Show these posts to Harmony as thumbnails under your reply (max 12 per reply). Returns the ids accepted.",
        params: ["ids"],
    },
    handler: async (ctx, input) => ok(await tools(ctx).show!(input.ids)),
});

export const collageOp = defineOp({
    name: "collage",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        ids: Ids,
        title: z.string().optional(),
        query: z.string().optional(),
    }),
    output: z.number(),
    ai: {
        tier: "free",
        only: true,
        summary:
            "A big result set (up to 500 posts, in order) shown as a paged collage under your reply, e.g. every\ncat when Harmony asks for cats. title: a short label; query: the search words, so Harmony can open the\nsame search in the library. One per reply (a later call replaces it). Returns how many were kept.",
        params: ["ids"],
        options: true,
        // a bare string as the second argument was always the title
        args: ([ids, opts]) => ({
            ids,
            ...(typeof opts === "string" ? { title: opts } : opts && typeof opts === "object" && !Array.isArray(opts) ? opts : {}),
        }),
    },
    handler: async (ctx, input) => ok(await tools(ctx).collage!(input.ids, { title: input.title, query: input.query })),
});

export const linksListOp = defineOp({
    name: "links.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.array(LinkSchema),
    ai: { tier: "free", only: true, summary: "Gallery share links, newest first.", aliases: ["links"] },
    handler: async (ctx) => ok(await tools(ctx).links!()),
});

export const collectionsListOp = defineOp({
    name: "collections.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.array(CollectionSchema),
    ai: { tier: "free", only: true, summary: "The collections (folders) the gallery links are in.", aliases: ["collections"] },
    handler: async (ctx) => ok(await tools(ctx).collections!()),
});

// ---- the library read routes ----------------------------------------------------------------------------------------

// These routes read their query themselves (the handlers' own checks and error codes); the schema only names it.
const AnyQuery = z.record(z.string(), z.string());

// GET /library (section 5, v2/v3 shapes in 13 and 18): keyed or the library service.
export const libraryIndexOp = defineOp({
    name: "library.index",
    route: { method: "GET", path: "/library" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: AnyQuery,
    http: (ctx) => Object.fromEntries(ctx.query),
    ai: { tier: "hidden", summary: "The app's library pages (GET /library)." },
    handler: async (ctx) => {
        const r = await libraryList(ctx.app(), ctx.query);
        return { status: r.status, body: r.body };
    },
});

// GET /library/search (section 21): keyed or the library service, no CORS.
export const libraryQueryOp = defineOp({
    name: "library.query",
    route: { method: "GET", path: "/library/search" },
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: AnyQuery,
    http: (ctx) => Object.fromEntries(ctx.query),
    ai: { tier: "hidden", summary: "The app's meaning search (GET /library/search)." },
    handler: async (ctx) => {
        const r = await librarySearch({ ...ctx.app(), embed: ctx.embed() }, ctx.query);
        return { status: r.status, body: r.body };
    },
});

// GET /library/map (section 21): the vectors of the sky map, keyed or the library service, no CORS.
export const libraryMapOp = defineOp({
    name: "library.map",
    route: { method: "GET", path: "/library/map" },
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: AnyQuery,
    http: (ctx) => Object.fromEntries(ctx.query),
    ai: { tier: "hidden", summary: "The library map's vectors (GET /library/map)." },
    handler: async (ctx) => {
        const r = await libraryMap({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, searchEnabled: ctx.embed() !== null });
        return { status: r.status, body: r.body };
    },
});

// GET /queue (section 23): keyed only (the service gets 404), D1 plus the Durable Object's line answer.
export const queueOp = defineOp({
    name: "queue",
    route: { method: "GET", path: "/queue" },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: AnyQuery,
    http: (ctx) => Object.fromEntries(ctx.query),
    // the chat may read it (section 33.7): its own saves are the line's `mine` entries
    ai: {
        tier: "free",
        summary:
            "Everything in flight: the server's line of saves and renders (entries with mine: true are this chat's own saves, by sid),\nthe search index and the posters. Use it to check on a save that was still going.",
    },
    handler: async (ctx) => {
        const r = await queueSnapshot({
            db: ctx.db,
            mediaBaseUrl: ctx.mediaBaseUrl,
            now: ctx.now,
            searchEnabled: ctx.embed() !== null,
            line: async () => {
                const res = await ctx.durableObject("/studio/line");
                return res.ok ? await res.json() : null;
            },
        });
        return { status: r.status, body: r.body };
    },
});

export const LIBRARY_OPS = [
    libraryListOp,
    librarySearchOp,
    libraryPostOp,
    lookOp,
    showOp,
    collageOp,
    linksListOp,
    collectionsListOp,
    libraryIndexOp,
    libraryQueryOp,
    libraryMapOp,
    queueOp,
];
