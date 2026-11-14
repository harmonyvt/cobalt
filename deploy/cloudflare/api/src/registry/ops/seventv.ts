// 7TV accounts (APP-API-CONTRACT.md section 57): the owner routes under /7tv (57.4, tier hidden) and the chat AI's
// calls cobalt.seventv.* (57.6, which the MCP serves as tools like every chat op). The work is in src/seventv.ts.
//  - Routes: a client key or session, CORS for the web app, no-store. Linking and unlinking are never AI calls.
//  - Chat and MCP: status / sets / set are free; every write asks Harmony first.
import * as z from "zod";
import {
    SEVENTV_ID,
    sevenTvAddEmote,
    sevenTvChannelSets,
    sevenTvCreateSet,
    sevenTvEmote,
    sevenTvUpload,
    sevenTvLink,
    sevenTvMakeLive,
    sevenTvRemoveEmote,
    sevenTvRenameEmote,
    sevenTvRenameSet,
    sevenTvSet,
    sevenTvStatus,
    sevenTvUnlink,
    type Channel,
    type SevenTvDeps,
    type SevenTvUploadDeps,
} from "../../seventv";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";

const deps = (ctx: OpContext): SevenTvDeps => ({ db: ctx.db, now: ctx.now, secret: ctx.env.COBALT_API_KEY });
const uploadDeps = (ctx: OpContext): SevenTvUploadDeps => ({ ...deps(ctx), media: ctx.env.MEDIA, originals: ctx.env.ORIGINALS });
const reply = (r: StudioReply): OpReply => ({ status: r.status, body: r.body });

const Id = SEVENTV_ID;
const Status = z.literal("success");

// ---- shapes -------------------------------------------------------------------------------------------------------------

const ChannelShape = z
    .object({
        id: z.string(),
        name: z.string(),
        avatar_url: z.string().nullable(),
        you: z.boolean().describe("the linked account's own channel"),
        active_set_id: z.string().nullable().describe("the live emote set"),
        can: z.object({ manage_sets: z.boolean(), create_sets: z.boolean(), make_live: z.boolean() }),
    })
    .meta({ id: "SevenTvChannel" });
const AccountShape = z
    .object({
        id: z.string(),
        name: z.string(),
        avatar_url: z.string().nullable(),
        linked_at: z.number().int(),
        expires_at: z.number().int().nullable(),
        status: z.enum(["ok", "relink"]),
    })
    .meta({ id: "SevenTvAccount" });
const StatusShape = z.object({ status: Status, linked: z.boolean(), account: AccountShape.optional(), channels: z.array(ChannelShape).optional() });
const SetSummary = z
    .object({ id: z.string(), name: z.string(), capacity: z.number().int().nullable(), count: z.number().int(), live: z.boolean() })
    .meta({ id: "SevenTvSetSummary" });
const SetEmote = z
    .object({
        emote_id: z.string(),
        alias: z.string().describe("its name in this set"),
        name: z.string().describe("its own 7TV name"),
        renamed: z.boolean(),
        animated: z.boolean(),
        preview_url: z.string().nullable(),
        file_url: z.string().nullable(),
        added_at: z.number().int().nullable(),
    })
    .meta({ id: "SevenTvSetEmote" });
const SetInfo = z
    .object({
        id: z.string(),
        name: z.string(),
        capacity: z.number().int().nullable(),
        count: z.number().int().optional(),
        owner_id: z.string().nullable().optional(),
        live: z.boolean().optional(),
    })
    .meta({ id: "SevenTvSet" });

const UploadShape = z
    .object({
        status: Status,
        emote_id: z.string(),
        name: z.string(),
        file_id: z.string().describe("the library file that was uploaded"),
        page_url: z.string(),
        pending: z.boolean().describe("7TV still processing the images (usually a minute)"),
        added: z.object({ set_id: z.string(), alias: z.string().nullable() }).nullable(),
        add_error: z.object({ code: z.string(), message: z.string().optional() }).optional(),
    })
    .meta({ id: "SevenTvUpload" });
const EmoteInfo = z
    .object({
        emote_id: z.string(),
        name: z.string(),
        owner_id: z.string(),
        pending: z.boolean(),
        animated: z.boolean(),
        private: z.boolean(),
        zero_width: z.boolean(),
        preview_url: z.string().nullable(),
        file_url: z.string().nullable(),
        page_url: z.string(),
    })
    .meta({ id: "SevenTvEmote" });

// ---- the routes (57.4) --------------------------------------------------------------------------------------------------

const route = <I>(o: {
    name: string;
    method: "GET" | "POST" | "PATCH" | "DELETE";
    path: string;
    params?: Record<string, RegExp>;
    input?: z.ZodType<I>;
    output?: z.ZodType;
    summary: string;
    run: (ctx: OpContext, input: I) => Promise<StudioReply>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path, ...(o.params ? { params: o.params } : {}) },
        auth: "key",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? z.looseObject({})) as z.ZodType<I>,
        badRequest: "error.seventv.bad",
        ...(o.output ? { output: o.output } : {}),
        ai: { tier: "hidden", summary: o.summary },
        handler: async (ctx, input) => reply(await o.run(ctx, input)),
    });

const ROUTE_OPS = [
    route({
        name: "seventv_http.status",
        method: "GET",
        path: "/7tv",
        output: StatusShape,
        summary: "The linked 7TV account and the channels it can edit (GET /7tv).",
        run: (ctx) => sevenTvStatus(deps(ctx)),
    }),
    route({
        name: "seventv_http.link",
        method: "POST",
        path: "/7tv/link",
        input: z.looseObject({ token: z.string().max(8192) }),
        output: StatusShape,
        summary: "Link a 7TV account with its session token from 7tv.app (POST /7tv/link).",
        run: (ctx, input) => sevenTvLink(deps(ctx), input),
    }),
    route({
        name: "seventv_http.unlink",
        method: "DELETE",
        path: "/7tv",
        summary: "Forget the 7TV token (DELETE /7tv).",
        run: (ctx) => sevenTvUnlink(deps(ctx)),
    }),
    route({
        name: "seventv_http.sets",
        method: "GET",
        path: "/7tv/channels/:id/sets",
        params: { id: Id },
        output: z.object({ status: Status, channel_id: z.string(), active_set_id: z.string().nullable(), sets: z.array(SetSummary) }),
        summary: "A channel's emote sets, live first (GET /7tv/channels/<id>/sets).",
        run: (ctx) => sevenTvChannelSets(deps(ctx), ctx.params.id!),
    }),
    route({
        name: "seventv_http.live",
        method: "POST",
        path: "/7tv/channels/:id/live",
        params: { id: Id },
        input: z.looseObject({ set_id: z.string().max(64).nullable() }),
        output: z.object({ status: Status, channel_id: z.string(), active_set_id: z.string().nullable() }),
        summary: "Make an emote set the channel's live set (POST /7tv/channels/<id>/live).",
        run: (ctx, input) => sevenTvMakeLive(deps(ctx), ctx.params.id!, input),
    }),
    route({
        name: "seventv_http.set",
        method: "GET",
        path: "/7tv/sets/:id",
        params: { id: Id },
        output: z.object({ status: Status, set: SetInfo, page: z.number().int(), has_more: z.boolean(), emotes: z.array(SetEmote) }),
        summary: "An emote set and a page of its emotes (GET /7tv/sets/<id>?q=&page=).",
        run: (ctx) => sevenTvSet(deps(ctx), ctx.params.id!, ctx.query),
    }),
    route({
        name: "seventv_http.create_set",
        method: "POST",
        path: "/7tv/sets",
        input: z.looseObject({ owner_id: z.string().max(64), name: z.string().max(400) }),
        output: z.object({ status: Status, set: SetInfo }),
        summary: "Make a new emote set on a channel (POST /7tv/sets).",
        run: (ctx, input) => sevenTvCreateSet(deps(ctx), input),
    }),
    route({
        name: "seventv_http.rename_set",
        method: "PATCH",
        path: "/7tv/sets/:id",
        params: { id: Id },
        input: z.looseObject({ name: z.string().max(400) }),
        output: z.object({ status: Status, set: SetInfo }),
        summary: "Rename an emote set (PATCH /7tv/sets/<id>).",
        run: (ctx, input) => sevenTvRenameSet(deps(ctx), ctx.params.id!, input),
    }),
    route({
        name: "seventv_http.add",
        method: "POST",
        path: "/7tv/sets/:id/emotes",
        params: { id: Id },
        input: z.looseObject({ emote_id: z.string().max(64), alias: z.string().max(400).nullable().optional(), override_conflicts: z.boolean().optional() }),
        output: z.object({ status: Status, set_id: z.string(), emote_id: z.string(), alias: z.string().nullable() }),
        summary: "Add a 7TV emote to a set (POST /7tv/sets/<id>/emotes).",
        run: (ctx, input) => sevenTvAddEmote(deps(ctx), ctx.params.id!, input),
    }),
    route({
        name: "seventv_http.rename",
        method: "PATCH",
        path: "/7tv/sets/:id/emotes/:emote",
        params: { id: Id, emote: Id },
        input: z.looseObject({ alias: z.string().max(400), from: z.string().max(400).nullable().optional() }),
        output: z.object({ status: Status, set_id: z.string(), emote_id: z.string(), alias: z.string() }),
        summary: "Rename an emote in a set (PATCH /7tv/sets/<id>/emotes/<emote>).",
        run: (ctx, input) => sevenTvRenameEmote(deps(ctx), ctx.params.id!, ctx.params.emote!, input),
    }),
    route({
        name: "seventv_http.remove",
        method: "DELETE",
        path: "/7tv/sets/:id/emotes/:emote",
        params: { id: Id, emote: Id },
        output: z.object({ status: Status, set_id: z.string(), emote_id: z.string(), removed: z.literal(true) }),
        summary: "Remove an emote from a set (DELETE /7tv/sets/<id>/emotes/<emote>?alias=).",
        run: (ctx) => sevenTvRemoveEmote(deps(ctx), ctx.params.id!, ctx.params.emote!, ctx.query.get("alias")),
    }),
    route({
        name: "seventv_http.upload",
        method: "POST",
        path: "/7tv/emotes",
        input: z.looseObject({
            file: z.string().max(64),
            name: z.string().max(400),
            tags: z.array(z.string().max(64)).max(6).optional(),
            zero_width: z.boolean().optional(),
            private: z.boolean().optional(),
            set_id: z.string().max(64).nullable().optional(),
            alias: z.string().max(400).nullable().optional(),
        }),
        output: UploadShape,
        summary: "Upload a library picture (webp, gif, png, avif, jpeg; up to 7 MB) as a new 7TV emote, optionally into a set (POST /7tv/emotes).",
        run: (ctx, input) => sevenTvUpload(uploadDeps(ctx), input),
    }),
    route({
        name: "seventv_http.emote",
        method: "GET",
        path: "/7tv/emotes/:id",
        params: { id: Id },
        output: EmoteInfo.extend({ status: Status }),
        summary: "One 7TV emote: its name, owner, and whether 7TV is still processing it (GET /7tv/emotes/<id>).",
        run: (ctx) => sevenTvEmote(deps(ctx), ctx.params.id!),
    }),
];

// ---- the chat AI's calls (57.6) -----------------------------------------------------------------------------------------

const MESSAGES: Record<string, string> = {
    "error.seventv.not_linked": "no 7TV account is linked (Harmony links one in the app's studio tab)",
    "error.seventv.relink": "7TV signed the linked account out: Harmony needs to link it again in the studio tab",
    "error.seventv.not_ready": "7TV accounts are not set up on this server yet",
    "error.seventv.not_found": "7TV has no such channel, set or emote",
    "error.seventv.forbidden": "the linked account may not do that on this channel",
    "error.seventv.rate_limited": "7TV is rate limiting: wait a little and try again",
    "error.seventv.rejected": "7TV refused that",
    "error.seventv.unavailable": "7TV is not answering",
    "error.seventv.file_not_found": "no library file or post by that id (show_post lists a post's files)",
    "error.seventv.file_type": "7TV takes webp, gif, png, avif or jpeg pictures, not videos",
    "error.seventv.too_big": "7TV takes files up to 7 MB",
    "error.seventv.bad": "a 7TV id is 20-32 letters or digits; names are 1-100 characters, an emote's name has no spaces",
};

async function run<T = Record<string, unknown>>(r: Promise<StudioReply>): Promise<T> {
    const res = await r;
    if (res.status >= 200 && res.status <= 299) return res.body as T;
    const body = res.body as { error?: { code?: string }; message?: string };
    const code = body.error?.code ?? "error.api.generic";
    const base = MESSAGES[code] ?? code;
    throw new OpError(res.status, code, body.message ? `${base}: ${body.message}` : base);
}

// A channel by its 7TV id or its name (case-insensitive), from the linked account's channels.
async function channelOf(ctx: OpContext, ref: string): Promise<Channel> {
    const status = await run<{ linked: boolean; account?: { status: string }; channels?: Channel[] }>(sevenTvStatus(deps(ctx)));
    if (!status.linked) throw new OpError(409, "error.seventv.not_linked", MESSAGES["error.seventv.not_linked"]);
    if (status.account?.status === "relink") throw new OpError(409, "error.seventv.relink", MESSAGES["error.seventv.relink"]);
    const want = ref.trim().toLowerCase();
    const hit = (status.channels ?? []).find((c) => c.id === ref.trim() || c.name.toLowerCase() === want);
    if (!hit) throw new OpError(404, "error.seventv.not_found", "the linked account can't edit a channel by that name or id (cobalt.seventv.status() lists them)");
    return hit;
}

const ChannelRef = z.string().trim().min(1).max(64).describe("a channel's 7TV id or its name");
const SetId = z.string().regex(Id, "a 7TV emote set id").describe("an emote set id from seventv.sets()");
const EmoteId = z.string().regex(Id, "a 7TV emote id").describe("an emote id (emotes.find() or seventv.set())");
const Alias = z.string().trim().min(1).max(100).regex(/^\S+$/, "no spaces");

const statusOp = defineOp({
    name: "seventv.status",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.object({ linked: z.boolean(), account: AccountShape.optional(), channels: z.array(ChannelShape).optional() }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "The linked 7TV account and the channels it can edit (its own first), each with its live emote set and what it may do.",
    },
    handler: async (ctx) => {
        const { status: _s, ...rest } = await run<Record<string, unknown>>(sevenTvStatus(deps(ctx)));
        return ok(rest);
    },
});

const setsOp = defineOp({
    name: "seventv.sets",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ channel: ChannelRef }),
    output: z.object({ channel_id: z.string(), active_set_id: z.string().nullable(), sets: z.array(SetSummary) }),
    ai: { tier: "free", only: true, summary: "A channel's 7TV emote sets (live first), with their sizes.", params: ["channel"] },
    handler: async (ctx, input) => {
        const ch = await channelOf(ctx, input.channel);
        const { status: _s, ...rest } = await run<Record<string, unknown>>(sevenTvChannelSets(deps(ctx), ch.id));
        return ok(rest);
    },
});

const setOp = defineOp({
    name: "seventv.set",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set_id: SetId, query: z.string().trim().max(100).optional().describe("filter by name in the set"), page: z.number().int().min(1).max(1000).optional() }),
    output: z.object({ set: SetInfo, page: z.number(), has_more: z.boolean(), emotes: z.array(SetEmote) }),
    ai: { tier: "free", only: true, summary: "One 7TV emote set and a page (60) of its emotes, optionally filtered by name.", params: ["set_id"], options: true },
    handler: async (ctx, input) => {
        const q = new URLSearchParams();
        if (input.query) q.set("q", input.query);
        if (input.page) q.set("page", String(input.page));
        const { status: _s, ...rest } = await run<Record<string, unknown>>(sevenTvSet(deps(ctx), input.set_id, q));
        return ok(rest);
    },
});

const strip = async (r: Promise<StudioReply>) => {
    const { status: _s, ...rest } = await run<Record<string, unknown>>(r);
    return ok(rest);
};

const addOp = defineOp({
    name: "seventv.add",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set_id: SetId, emote_id: EmoteId, alias: Alias.optional().describe("a different name in this set"), override_conflicts: z.boolean().optional() }),
    output: z.object({ set_id: z.string(), emote_id: z.string(), alias: z.string().nullable() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Add a 7TV emote to an emote set (find it with emotes.find). Asks Harmony first.",
        params: ["set_id", "emote_id"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `add 7TV emote ${input.emote_id}${input.alias ? ` as ${input.alias}` : ""} to set ${input.set_id}`,
            effect: { set_id: input.set_id, emote_id: input.emote_id, ...(input.alias ? { alias: input.alias } : {}) },
        }),
    },
    handler: (ctx, input) => strip(sevenTvAddEmote(deps(ctx), input.set_id, input)),
});

const removeOp = defineOp({
    name: "seventv.remove",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set_id: SetId, emote_id: EmoteId, alias: z.string().trim().min(1).max(100).optional().describe("which copy, when the emote is in the set twice") }),
    output: z.object({ set_id: z.string(), emote_id: z.string(), removed: z.literal(true) }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Remove an emote from a 7TV emote set. Asks Harmony first.",
        params: ["set_id", "emote_id"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `remove ${input.alias ?? `emote ${input.emote_id}`} from 7TV set ${input.set_id}`,
            effect: { set_id: input.set_id, emote_id: input.emote_id },
        }),
    },
    handler: (ctx, input) => strip(sevenTvRemoveEmote(deps(ctx), input.set_id, input.emote_id, input.alias ?? null)),
});

const renameOp = defineOp({
    name: "seventv.rename",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set_id: SetId, emote_id: EmoteId, alias: Alias.describe("the new name in this set"), from: z.string().trim().min(1).max(100).optional() }),
    output: z.object({ set_id: z.string(), emote_id: z.string(), alias: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Rename an emote inside one 7TV emote set (its alias there; the emote itself keeps its name). Asks Harmony first.",
        params: ["set_id", "emote_id", "alias"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `rename ${input.from ?? `emote ${input.emote_id}`} to ${input.alias} in 7TV set ${input.set_id}`,
            effect: { set_id: input.set_id, emote_id: input.emote_id, alias: input.alias },
        }),
    },
    handler: (ctx, input) => strip(sevenTvRenameEmote(deps(ctx), input.set_id, input.emote_id, input)),
});

const makeLiveOp = defineOp({
    name: "seventv.makeLive",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ channel: ChannelRef, set_id: SetId }),
    output: z.object({ channel_id: z.string(), active_set_id: z.string().nullable() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Make an emote set the channel's live 7TV set (chat sees it at once). Asks Harmony first.",
        params: ["channel", "set_id"],
        preview: async (_ctx, input) => ({
            summary: `make set ${input.set_id} live on ${input.channel}`,
            effect: { channel: input.channel, set_id: input.set_id },
        }),
    },
    handler: async (ctx, input) => {
        const ch = await channelOf(ctx, input.channel);
        return strip(sevenTvMakeLive(deps(ctx), ch.id, { set_id: input.set_id }));
    },
});

const createSetOp = defineOp({
    name: "seventv.createSet",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ channel: ChannelRef, name: z.string().trim().min(1).max(100) }),
    output: z.object({ set: SetInfo }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Make a new empty 7TV emote set on a channel. Asks Harmony first.",
        params: ["channel", "name"],
        preview: async (_ctx, input) => ({ summary: `make a 7TV set “${input.name}” on ${input.channel}`, effect: { channel: input.channel, name: input.name } }),
    },
    handler: async (ctx, input) => {
        const ch = await channelOf(ctx, input.channel);
        return strip(sevenTvCreateSet(deps(ctx), { owner_id: ch.id, name: input.name }));
    },
});

const renameSetOp = defineOp({
    name: "seventv.renameSet",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set_id: SetId, name: z.string().trim().min(1).max(100) }),
    output: z.object({ set: SetInfo }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Rename a 7TV emote set. Asks Harmony first.",
        params: ["set_id", "name"],
        preview: async (_ctx, input) => ({ summary: `rename 7TV set ${input.set_id} to “${input.name}”`, effect: { set_id: input.set_id, name: input.name } }),
    },
    handler: (ctx, input) => strip(sevenTvRenameSet(deps(ctx), input.set_id, input)),
});

const uploadOp = defineOp({
    name: "seventv.uploadEmote",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        file: z.string().trim().min(1).max(64).describe("a library file id (or a post id: its first picture), e.g. an animated webp"),
        name: z.string().trim().min(1).max(100).describe("the emote's name on 7TV: letters, digits and _-():!+|.'?><*$#, no spaces"),
        tags: z.array(z.string()).max(6).optional().describe("up to 6 tags, 3-30 word characters each"),
        zero_width: z.boolean().optional().describe("an overlay emote that sits on the emote before it"),
        private: z.boolean().optional().describe("hidden from 7TV search (still usable in sets)"),
        set_id: SetId.optional().describe("also add it to this emote set"),
        alias: Alias.optional().describe("its name in that set, when different"),
    }),
    output: UploadShape.omit({ status: true }),
    ai: {
        tier: "ask",
        only: true,
        summary:
            "Upload a library picture (an animated webp, gif, png...) to 7TV as a NEW emote owned by the linked account, and optionally add it to a set. 7TV processes it for about a minute (seventv.emote shows when it is ready). Asks Harmony first.",
        params: ["file", "name"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `upload ${input.file} to 7TV as “${input.name}”${input.set_id ? ` and add it to set ${input.set_id}` : ""}`,
            effect: { file: input.file, name: input.name, ...(input.set_id ? { set_id: input.set_id } : {}), ...(input.private ? { private: true } : {}) },
        }),
    },
    handler: (ctx, input) => strip(sevenTvUpload(uploadDeps(ctx), input)),
});

const emoteOp = defineOp({
    name: "seventv.emote",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ emote_id: EmoteId }),
    output: EmoteInfo,
    ai: { tier: "free", only: true, summary: "One 7TV emote: name, owner, flags, and pending = 7TV is still processing an upload.", params: ["emote_id"] },
    handler: (ctx, input) => strip(sevenTvEmote(deps(ctx), input.emote_id)),
});

export const SEVENTV_OPS = [...ROUTE_OPS, statusOp, setsOp, setOp, addOp, removeOp, renameOp, makeLiveOp, createSetOp, renameSetOp, uploadOp, emoteOp];
