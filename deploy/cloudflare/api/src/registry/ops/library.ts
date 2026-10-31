// Library ops (APP-API-CONTRACT.md 33.4): the chat AI's read tools (section 27.3, now under cobalt.library.*, cobalt.links.*,
// cobalt.collections.*, plus look, show and collage) and the library read routes (GET /library, /library/search,
// /library/map, /queue). The route ops wrap the existing handlers unchanged: same parsing, same bodies, same headers.
import * as z from "zod";
import { libraryList } from "../../app-routes";
import { LIBRARY_MAX_LIMIT, loadPosts, RANK_MAX, SEARCH_MAX } from "../../chat-tools";
import { libraryAbout, libraryAboutSet } from "../../about";
import { USER_TAGS_MAX } from "../../about-store";
import { libraryMap, librarySearch } from "../../embed";
import { transcriptOf, TranscriptNotFound } from "../../transcripts";
import { WITHIN_POSTS_MAX } from "../../within";
import { queueSnapshot } from "../../queue";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { LibraryIndexShape } from "../shapes";

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

const LinkSchema = z.object({
    id: z.string(),
    url: z.string().nullable().describe("the URL that works now: share.../p/<key> while private, else share.../g/<id>"),
    private: z.boolean(),
    title: z.string().nullable(),
    created_at: z.string(),
    post_ids: z.array(z.string()),
});
const CollectionSchema = z.object({
    id: z.string(),
    name: z.string(),
    link_ids: z.array(z.string()),
    post_ids: z.array(z.string()).describe("every post in its live links (search within it with { within: { collection } })"),
});

// search's `within` (section 34.6): a collection (id or name; a plain string means one), a gallery link, or posts
const Within = z.union([
    z.string().min(1).max(200),
    z.object({ collection: z.string().min(1).max(200) }),
    z.object({ link: z.string().min(1).max(64) }),
    z.object({ posts: z.array(z.string().min(1).max(2048)).min(1).max(WITHIN_POSTS_MAX) }),
]);

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
        limit: z.number().int().min(1).optional().describe(`default 10 (with within: every post in it), max ${SEARCH_MAX}`),
        within: Within.optional().describe(
            "only these: { collection: id or name } | { link: id } | { posts: [ids] }; every post in it is scored (a string is a collection)",
        ),
    }),
    output: z.array(
        z.intersection(
            PostSchema,
            z.object({
                score: z.number(),
                why: z.array(z.string()).describe("up to 3 of its tags or sound tags, closest to the query first"),
                said: z
                    .array(z.object({ at: z.number(), end: z.number(), text: z.string(), match: z.enum(["words", "meaning"]) }))
                    .optional()
                    .describe("where it is said in the video: the lines holding the query (words) or the moment closest to it (meaning), seconds"),
                indexed: z.literal(false).optional().describe("no vector yet: scored by its text only"),
            }),
        ),
    ),
    ai: {
        tier: "free",
        only: true,
        summary: `Meaning search over titles, pictures, what posts are about and what is heard in them, best first (default 10, max ${SEARCH_MAX}; every post gets a score, so cut where the scores drop).\nWith within, every post of that collection, link or list is scored. Throws while the search model is waking up.`,
        aliases: ["search"],
        params: ["query"],
        options: true,
        // the old search(query, limit) still works
        args: ([query, second]) => ({
            query,
            ...(typeof second === "number" ? { limit: second } : second && typeof second === "object" && !Array.isArray(second) ? second : {}),
        }),
        when: (f) => f.search,
    },
    handler: async (ctx, input) => ok(await tools(ctx).search!(input.query, { limit: input.limit, within: input.within })),
});

export const libraryPostOp = defineOp({
    name: "library.post",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().min(1) }),
    output: z.intersection(
        PostSchema,
        z.object({
            files: z.array(PostFileSchema),
            hidden: z.literal(true).optional().describe("a hidden post: it cannot be shared until library.status unhides it"),
        }),
    ),
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
    input: z.object({
        ids: Ids,
        grid: z.boolean().optional().describe("draw lines every 0.1 of the width and height, to read off a crop box for make.cropImage"),
        frames: z.boolean().optional().describe("a video: also up to 3 frames spread across it, not only its poster"),
        box: z
            .object({ x: z.number().min(0).lt(1), y: z.number().min(0).lt(1), w: z.number().gt(0).max(1), h: z.number().gt(0).max(1) })
            .optional()
            .describe("a crop you are about to make, drawn on the pictures (and frames) in cyan with the outside darkened: check it before cropping"),
    }),
    output: z.number(),
    ai: {
        tier: "free",
        only: true,
        summary: "You get to SEE these posts' pictures (poster or image, private ones too) after this code returns. Max 4 per reply. Returns how many are queued.",
        params: ["ids"],
        options: true,
    },
    handler: async (ctx, input) =>
        ok(await tools(ctx).look!(input.ids, { ...(input.grid ? { grid: true } : {}), ...(input.frames ? { frames: true } : {}), ...(input.box ? { box: input.box } : {}) })),
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
    ai: { tier: "free", only: true, summary: "Gallery share links, newest first, each with the URL that works now (private ones: share.../p/<key>).", aliases: ["links"] },
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

// cobalt.rank (section 34.6): a scored list under the reply, for "which of these are X" answers.
export const rankOp = defineOp({
    name: "chat.rank",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        hits: z
            .array(
                z.union([
                    z.string().min(1),
                    z.object({
                        id: z.string().min(1),
                        score: z.number().optional(),
                        why: z.array(z.string()).optional().describe("up to 4 short words, e.g. the search hit's why"),
                    }),
                ]),
            )
            .max(SEARCH_MAX)
            .describe(`best first, at most ${RANK_MAX} kept`),
        title: z.string().optional(),
        query: z.string().optional(),
        within: z.string().optional().describe('a short label of what was searched, e.g. "lia share 11"'),
    }),
    output: z.number(),
    ai: {
        tier: "free",
        only: true,
        call: "rank",
        summary:
            "Show Harmony a scored list under your reply (up to 50 posts, best first: thumbnail, title, the why words, the score), for answers to\n\"which of these / in this collection are X\". One per reply (a later call replaces it). Returns how many were kept.",
        params: ["hits"],
        options: true,
    },
    handler: async (ctx, input) => ok(await tools(ctx).rank!(input.hits, { title: input.title, query: input.query, within: input.within })),
});

// ---- "what it's about" (section 34) ----------------------------------------------------------------------------------

const AboutShape = z.object({
    sentence: z.string().nullable(),
    tags: z.array(z.string()),
    edited: z.boolean().describe("Harmony set these tags"),
    sound_tags: z.array(z.string()),
    transcript: z.string().nullable(),
    language: z.string().nullable(),
    frames: z.number(),
    has_audio: z.boolean(),
    model: z.string().nullable(),
    written_at: z.number().nullable(),
});

const AboutBody = z.object({
    post_key: z.string(),
    probe: z.enum(["pending", "done", "none", "failed"]),
    about: AboutShape.nullable().describe("null until it is described"),
    words: z.array(z.object({ word: z.string(), score: z.number() })).describe("the words its vector reads closest to"),
    neighbours: z.array(z.object({ post_id: z.string(), score: z.number() })).describe("the 4 nearest posts"),
    posts: z.record(z.string(), z.unknown()).optional().describe("the neighbours' GET /library post shapes (left out for the chat: use post(id))"),
    index: z.record(z.string(), z.unknown()).describe("the body of GET /library/search/post"),
});

const aboutDeps = (ctx: OpContext) => ({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, searchEnabled: ctx.embed() !== null, app: ctx.app(), now: ctx.now });
// the model gets the body without the neighbours' post shapes (it has post() for those)
const forModel = (body: unknown) => {
    const { status: _s, posts: _p, ...rest } = (body ?? {}) as Record<string, unknown>;
    return rest;
};

// GET /library/about?key=<post key> (34.6): keyed or the library service, no CORS; the chat's cobalt.library.about(id).
export const libraryAboutOp = defineOp({
    name: "library.about",
    route: { method: "GET", path: "/library/about" },
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    badRequest: "error.library.bad_request",
    input: z.object({ key: z.string().min(1).max(2048).describe("the post id") }),
    output: AboutBody,
    ai: {
        tier: "free",
        summary: "What a post is about: its description, tags and sound tags, what is said in it, the words its vector reads closest to, its nearest posts.",
        params: ["key"],
        args: ([key]) => ({ key }),
        result: forModel,
    },
    handler: async (ctx, input) => {
        const r = await libraryAbout(aboutDeps(ctx), input.key);
        return { status: r.status, body: r.body };
    },
});

// PATCH /library/about { key, tags } (34.6): the owner's tags (null: back to the written ones). Keyed only; the chat asks.
export const libraryAboutSetOp = defineOp({
    name: "library.about.set",
    route: { method: "PATCH", path: "/library/about" },
    auth: "key",
    runs: "worker",
    cors: false,
    noStore: true,
    badRequest: "error.library.bad_request",
    input: z.object({
        key: z.string().min(1).max(2048).describe("the post id"),
        tags: z
            .array(z.string())
            .max(USER_TAGS_MAX)
            .nullable()
            .describe(`0..${USER_TAGS_MAX} tags, each 1..30 characters (lowercased); null goes back to the written ones`),
    }),
    output: AboutBody,
    ai: {
        tier: "ask",
        summary: "Replace a post's tags with Harmony's own (null goes back to the written ones). Only when Harmony asks.",
        params: ["key", "tags"],
        result: forModel,
        preview: async (ctx, input) => {
            const [post] = await loadPosts({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl }, [input.key]);
            if (!post) throw new OpError(404, "error.library.not_found", `no post ${JSON.stringify(input.key)} in the library`);
            const name = post.record.title ? `“${post.record.title.length > 60 ? `${post.record.title.slice(0, 59)}…` : post.record.title}”` : "this post";
            return {
                summary: input.tags === null ? `reset the tags of ${name}` : `set the tags of ${name}`,
                effect: { tags: input.tags },
            };
        },
    },
    handler: async (ctx, input) => {
        const r = await libraryAboutSet(aboutDeps(ctx), input.key, input.tags);
        return { status: r.status, body: r.body };
    },
});

// ---- timed transcripts (section 47) ----------------------------------------------------------------------------------

const TranscriptWord = z.object({ text: z.string(), start: z.number(), end: z.number() }).meta({ id: "TranscriptWord" });
const TranscriptLine = z
    .object({
        start: z.number().describe("seconds from the start of the clip"),
        end: z.number(),
        text: z.string(),
        words: z.array(TranscriptWord).optional().describe("each word's own time (left out for the chat AI)"),
    })
    .meta({ id: "TranscriptLine" });

const TranscriptBody = z.object({
    post_key: z.string(),
    state: z
        .enum(["done", "no_speech", "pending", "no_sound", "failed", "off"])
        .describe("done: lines below; no_speech: heard, nothing said; pending: not heard yet; no_sound: nothing to hear; failed; off: no Whisper"),
    language: z.string().nullable(),
    model: z.string().nullable(),
    updated_at: z.number().nullable(),
    lines: z.array(TranscriptLine).describe("subtitle lines, in order (the first 10 minutes of the sound)"),
});

const seconds = (v: string | null): number | undefined => {
    if (v === null || v === "") return undefined;
    const n = Number(v);
    return Number.isFinite(n) ? n : NaN;
};

// GET /library/transcript?key=<post key>[&from=<s>&to=<s>] (47.3): keyed or the library service, no CORS; the chat's
// cobalt.library.transcript(id, { from, to }) ("what does she say at 0:12?").
export const libraryTranscriptOp = defineOp({
    name: "library.transcript",
    route: { method: "GET", path: "/library/transcript" },
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    badRequest: "error.library.bad_request",
    input: z.object({
        key: z.string().min(1).max(2048).describe("the post id"),
        from: z.number().min(0).optional().describe("seconds: only the lines that end at or after this"),
        to: z.number().min(0).optional().describe("seconds: only the lines that start at or before this"),
    }),
    output: TranscriptBody,
    http: (ctx) => ({ key: ctx.query.get("key") ?? "", from: seconds(ctx.query.get("from")), to: seconds(ctx.query.get("to")) }),
    ai: {
        tier: "free",
        summary: "What is said in a video, line by line with times in seconds (from/to: only that part). state says why there are no lines.",
        params: ["key"],
        options: true,
        result: (body: unknown) => {
            const { status: _s, ...rest } = (body ?? {}) as Record<string, unknown>;
            return rest;
        },
    },
    handler: async (ctx, input) => {
        try {
            const t = await transcriptOf({ db: ctx.db, soundOn: !!(ctx.env as { AI?: unknown }).AI }, input.key, {
                words: ctx.caller !== "chat",
                from: input.from,
                to: input.to,
            });
            return ok({ status: "success", ...t });
        } catch (e) {
            if (e instanceof TranscriptNotFound) throw new OpError(404, "error.library.not_found", `no post ${JSON.stringify(input.key)} in the library`);
            throw e;
        }
    },
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
    output: LibraryIndexShape,
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
    rankOp,
    linksListOp,
    collectionsListOp,
    libraryAboutOp,
    libraryAboutSetOp,
    libraryTranscriptOp,
    libraryIndexOp,
    libraryQueryOp,
    libraryMapOp,
    queueOp,
];
