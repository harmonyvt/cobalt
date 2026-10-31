// Search names (APP-API-CONTRACT.md section 48): the routes under /library/names (48.4) and the chat AI's calls (48.5,
// which the MCP serves as tools like every chat op). The work is in src/names.ts.
//  - The routes take the app's client key or the web Worker's library service credential, CORS for the web app,
//    no-store. Until migration 0031 they answer 503.
//  - Chat and MCP: names.list / names.preview (free), names.set / names.delete (ask). Offered while search is on.
import * as z from "zod";
import { loadPosts } from "../../chat-tools";
import {
    deleteName,
    listNames,
    namesForPost,
    NAME_ALIASES_MAX,
    NAME_ID_REGEX,
    NAME_MARK_PATCH_MAX,
    NAME_MARKS_MAX,
    NAME_MEANING_MAX,
    NAME_POST_KEY_MAX,
    NAME_PREVIEW_MAX,
    NAME_WORD_MAX,
    NAMES_MAX,
    previewName,
    previewWithPosts,
    saveName,
    type NameShape,
    type NamesDeps,
    type PreviewPost,
} from "../../names";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { unwrap } from "./share";

const namesDeps = (ctx: OpContext): NamesDeps => ({ db: ctx.db, embed: ctx.embed(), now: ctx.now });
const reply = (r: StudioReply): OpReply => ({ status: r.status, body: r.body });

// ---- shapes -----------------------------------------------------------------------------------------------------------

const Status = z.literal("success");
const PostKey = z.string().min(1).max(NAME_POST_KEY_MAX);
const Unit = z.number().min(0).max(1);
const Mark = z.enum(["yes", "no"]);

export const NameShapeSchema = z
    .object({
        id: z.string(),
        name: z.string().describe("as typed"),
        aliases: z.array(z.string()).describe("other words for it, normalized"),
        meaning: z.string(),
        strength: z.number().describe("0 = only the words, 1 = only the examples"),
        cutoff: z.number().describe("how close a post must be to carry the name"),
        enabled: z.boolean(),
        yes: z.array(z.string()).describe("example post keys, newest mark first"),
        no: z.array(z.string()).describe("not-this post keys, newest mark first"),
        posts: z.number().int().describe("posts that carry it now"),
        embedded: z.boolean().describe("the meaning has a vector for the current model"),
        created_at: z.number().int(),
        updated_at: z.number().int(),
    })
    .meta({ id: "SearchName" });

const Fields = {
    name: z.string().max(200).describe(`the word, 1 to ${NAME_WORD_MAX} characters`),
    meaning: z.string().max(2000).describe(`what it means, 1 to ${NAME_MEANING_MAX} characters`),
    aliases: z.array(z.string().max(200)).max(NAME_ALIASES_MAX).describe("other words for the same thing"),
    strength: Unit.describe("0 = only the meaning's words, 1 = only the example posts (default 0.5)"),
    cutoff: Unit.describe("cosine a post needs to carry the name (default 0.5)"),
    enabled: z.boolean(),
    yes: z.array(PostKey).max(NAME_MARKS_MAX).describe("posts that are it (replaces the examples)"),
    no: z.array(PostKey).max(NAME_MARKS_MAX).describe("posts that are not it (replaces them)"),
};
const MarkPatch = z.array(z.object({ post_key: PostKey, kind: Mark.nullable() })).max(NAME_MARK_PATCH_MAX);

const CreateInput = z.object({
    name: Fields.name,
    meaning: Fields.meaning,
    aliases: Fields.aliases.optional(),
    strength: Fields.strength.optional(),
    cutoff: Fields.cutoff.optional(),
    enabled: Fields.enabled.optional(),
    yes: Fields.yes.optional(),
    no: Fields.no.optional(),
});
const UpdateFields = {
    name: Fields.name.optional(),
    meaning: Fields.meaning.optional(),
    aliases: Fields.aliases.optional(),
    strength: Fields.strength.optional(),
    cutoff: Fields.cutoff.optional(),
    enabled: Fields.enabled.optional(),
    yes: Fields.yes.optional(),
    no: Fields.no.optional(),
    mark: MarkPatch.optional().describe("single posts: yes, no, or null to take the mark off (after yes/no)"),
};
const PreviewFields = {
    id: z.string().max(64).optional().describe("a saved name: missing fields come from it"),
    name: Fields.name.optional(),
    meaning: Fields.meaning.optional().describe("required without id"),
    strength: Fields.strength.optional(),
    cutoff: Fields.cutoff.optional(),
    yes: Fields.yes.optional(),
    no: Fields.no.optional(),
    limit: z.number().int().min(1).max(NAME_PREVIEW_MAX).optional(),
};

const NameReply = z.object({ status: Status, name: NameShapeSchema });

// ---- the routes (48.4) --------------------------------------------------------------------------------------------------

const route = <I>(o: {
    name: string;
    method: "GET" | "POST" | "PATCH" | "DELETE";
    path: string;
    params?: Record<string, RegExp>;
    input?: z.ZodType<I>;
    query?: boolean;
    output?: z.ZodType;
    summary: string;
    run: (ctx: OpContext, input: I) => Promise<StudioReply>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path, ...(o.params ? { params: o.params } : {}) },
        auth: "key_or_service",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? z.object({})) as z.ZodType<I>,
        ...(o.query ? { http: (ctx: OpContext) => Object.fromEntries(ctx.query) } : o.input ? {} : { http: () => ({}) }),
        badRequest: "error.names.bad",
        ...(o.output ? { output: o.output } : {}),
        ai: { tier: "hidden", summary: o.summary },
        handler: async (ctx, input) => reply(await o.run(ctx, input)),
    });

const IdParams = { id: NAME_ID_REGEX };

const ROUTE_OPS = [
    route({
        name: "library_names.list",
        method: "GET",
        path: "/library/names",
        output: z.object({ status: Status, names: z.array(NameShapeSchema) }),
        summary: "The search names, oldest first (GET /library/names).",
        run: (ctx) => listNames(ctx),
    }),
    route({
        name: "library_names.create",
        method: "POST",
        path: "/library/names",
        input: CreateInput,
        output: NameReply,
        summary: `Teach search a new name (at most ${NAMES_MAX}) (POST /library/names).`,
        run: (ctx, input) => saveName(namesDeps(ctx), null, input),
    }),
    route({
        name: "library_names.preview",
        method: "POST",
        path: "/library/names/preview",
        input: z.object(PreviewFields),
        output: z.object({
            status: Status,
            embedded: z.boolean(),
            carries: z.number().int(),
            indexed: z.number().int(),
            posts: z.array(
                z.object({
                    post_key: z.string(),
                    score: z.number(),
                    mark: Mark.nullable(),
                    carries: z.boolean(),
                    post: z.looseObject({ id: z.string() }).nullable().describe("the post in the GET /library?v=3 shape"),
                }),
            ),
        }),
        summary: "Which posts a name would carry with these values, saving nothing (POST /library/names/preview).",
        run: (ctx, input) => previewWithPosts({ ...namesDeps(ctx), app: ctx.app() }, input),
    }),
    route({
        name: "library_names.post",
        method: "GET",
        path: "/library/names/post",
        input: z.object({ key: PostKey }),
        query: true,
        output: z.object({
            status: Status,
            names: z.array(z.object({ id: z.string(), name: z.string(), score: z.number().nullable(), mark: Mark.nullable(), carries: z.boolean() })),
        }),
        summary: "The names one post carries or is marked for, best first (GET /library/names/post?key=).",
        run: (ctx, input) => namesForPost(ctx, input.key),
    }),
    route({
        name: "library_names.update",
        method: "PATCH",
        path: "/library/names/:id",
        params: IdParams,
        input: z.object({ id: z.string(), ...UpdateFields }),
        output: NameReply,
        summary: "Change a name, its marks included (PATCH /library/names/<id>).",
        run: (ctx, input) => {
            const { id: _id, ...rest } = input;
            return saveName(namesDeps(ctx), ctx.params.id!, rest);
        },
    }),
    route({
        name: "library_names.delete",
        method: "DELETE",
        path: "/library/names/:id",
        params: IdParams,
        summary: "Delete a name and its marks (DELETE /library/names/<id>).",
        run: (ctx) => deleteName(ctx, ctx.params.id!),
    }),
];

// ---- the chat AI's calls (48.5) ---------------------------------------------------------------------------------------

const MESSAGES: Record<string, string> = {
    "error.names.bad": `a name is { name: 1-${NAME_WORD_MAX} chars, meaning: 1-${NAME_MEANING_MAX} chars, aliases: up to ${NAME_ALIASES_MAX}, strength and cutoff 0..1, yes/no: post ids (never the same post in both, at most ${NAME_MARKS_MAX}) }`,
    "error.names.not_found": "no such name (cobalt.names.list() lists them)",
    "error.names.taken": "another name already uses that word",
    "error.names.too_many": `there are already ${NAMES_MAX} names`,
    "error.api.generic": "search names are not set up on this server yet",
};
const run = async <T = Record<string, unknown>>(r: Promise<StudioReply>): Promise<T> => {
    const res = await r;
    if (res.status === 409 && (res.body as { word?: string } | null)?.word) {
        throw new OpError(409, "error.names.taken", `another name already uses the word "${(res.body as { word: string }).word}"`);
    }
    return unwrap<T>(res, MESSAGES);
};

const NameSummary = z.object({
    id: z.string(),
    name: z.string(),
    aliases: z.array(z.string()),
    meaning: z.string(),
    strength: z.number(),
    cutoff: z.number(),
    enabled: z.boolean(),
    yes: z.number().describe("example posts"),
    no: z.number().describe("not-this posts"),
    posts: z.number().describe("posts that carry it now"),
    embedded: z.boolean(),
});
const summarize = (n: NameShape) => ({
    id: n.id,
    name: n.name,
    aliases: n.aliases,
    meaning: n.meaning,
    strength: n.strength,
    cutoff: n.cutoff,
    enabled: n.enabled,
    yes: n.yes.length,
    no: n.no.length,
    posts: n.posts,
    embedded: n.embedded,
});
const searchOn = (f: { search: boolean }) => f.search;

export const namesListOp = defineOp({
    name: "names.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.object({ names: z.array(NameSummary) }),
    ai: {
        tier: "free",
        only: true,
        when: searchOn,
        summary:
            "The search names: words Harmony taught search (\"Lia\" = \"pink-haired cat girl\"). A search that says one looks for its meaning\nand its example posts.",
    },
    handler: async (ctx) => {
        const { names } = await run<{ names: NameShape[] }>(listNames(ctx));
        return ok({ names: names.map(summarize) });
    },
});

export const namesPreviewOp = defineOp({
    name: "names.preview",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ...PreviewFields, limit: PreviewFields.limit.describe("default 20") }),
    output: z.object({
        embedded: z.boolean(),
        carries: z.number().describe("posts that would carry it"),
        indexed: z.number(),
        posts: z.array(z.object({ id: z.string(), title: z.string().nullable(), score: z.number(), mark: Mark.nullable(), carries: z.boolean() })),
    }),
    ai: {
        tier: "free",
        only: true,
        when: searchOn,
        summary: "Which posts a name would carry with these values (a saved name's id, or a new meaning), best first; saves nothing.",
        options: true,
    },
    handler: async (ctx, input) => {
        const body = await run<{ embedded: boolean; carries: number; indexed: number; posts: PreviewPost[] }>(previewName(namesDeps(ctx), input, 20));
        const titles = new Map((await loadPosts(ctx, body.posts.map((p) => p.post_key))).map((p) => [p.record.id, p.record.title]));
        return ok({
            embedded: body.embedded,
            carries: body.carries,
            indexed: body.indexed,
            posts: body.posts.map((p) => ({ id: p.post_key, title: titles.get(p.post_key) ?? null, score: p.score, mark: p.mark, carries: p.carries })),
        });
    },
});

const nameLabel = async (ctx: OpContext, id: string) => {
    const r = NAME_ID_REGEX.test(id) ? await ctx.db.prepare("SELECT name FROM search_names WHERE id = ?1").bind(id).first<{ name: string }>().catch(() => null) : null;
    if (!r) throw new OpError(404, "error.names.not_found", MESSAGES["error.names.not_found"]);
    return `“${r.name}”`;
};

export const namesSetOp = defineOp({
    name: "names.set",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().max(64).optional().describe("a saved name to change; without it a new name (name and meaning required)"), ...UpdateFields }),
    output: z.object({ name: NameSummary }),
    ai: {
        tier: "ask",
        only: true,
        when: searchOn,
        summary:
            "Teach search a name (no id) or change one (with id): its word, aliases, meaning, and example (yes) or not (no) posts. Asks Harmony first.",
        options: true,
        preview: async (ctx, input) => {
            const what = input.id ? `change the name ${await nameLabel(ctx, input.id)}` : `teach search “${input.name ?? ""}”`;
            return {
                summary: `${what}${input.meaning ? `: ${input.meaning.slice(0, 80)}` : ""}`,
                effect: {
                    ...(input.name !== undefined ? { name: input.name } : {}),
                    ...(input.meaning !== undefined ? { meaning: input.meaning } : {}),
                    ...(input.aliases !== undefined ? { aliases: input.aliases } : {}),
                    ...(input.yes !== undefined ? { yes: input.yes.length } : {}),
                    ...(input.no !== undefined ? { no: input.no.length } : {}),
                    ...(input.mark !== undefined ? { marks: input.mark.length } : {}),
                },
            };
        },
    },
    handler: async (ctx, input) => {
        const { id, ...rest } = input;
        const { name } = await run<{ name: NameShape }>(saveName(namesDeps(ctx), id ?? null, rest));
        return ok({ name: summarize(name) });
    },
});

export const namesDeleteOp = defineOp({
    name: "names.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().max(64).describe("a name id from names.list()") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        when: searchOn,
        summary: "Delete a search name and its marks. Asks Harmony first.",
        params: ["id"],
        preview: async (ctx, input) => ({ summary: `delete the name ${await nameLabel(ctx, input.id)}`, effect: { id: input.id } }),
    },
    handler: async (ctx, input) => {
        await run(deleteName(ctx, input.id));
        return ok({ deleted: input.id });
    },
});

export const NAMES_OPS = [...ROUTE_OPS, namesListOp, namesPreviewOp, namesSetOp, namesDeleteOp];
