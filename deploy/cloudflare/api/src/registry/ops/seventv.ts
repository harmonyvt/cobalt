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
    EMOTE_FIT_PATH,
    sevenTvUploads,
    sevenTvOwned,
    sevenTvAddMany,
    sevenTvClonePlan,
    sevenTvPermissions,
    ADD_MANY_MAX,
} from "../../seventv";
import { gateOf } from "../../seventv-gate";
import { DRAFT_ID } from "../../emote-draft";
import { getDraftFile, makeEmote, removeDraft, saveDraft, type MakeDeps } from "../../emote-make";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";

const deps = (ctx: OpContext): SevenTvDeps => ({ db: ctx.db, now: ctx.now, secret: ctx.env.COBALT_API_KEY, gate: gateOf(ctx.env) });
const uploadDeps = (ctx: OpContext): SevenTvUploadDeps => ({
    ...deps(ctx),
    media: ctx.env.MEDIA,
    originals: ctx.env.ORIGINALS,
    keyId: ctx.keyId,
    draftBucket: ctx.env.ORIGINALS,
    // the container's emote fit (57.10), through the Durable Object with the internal key
    fit: (body, bytes, query) =>
        ctx.container.fetch(
            new Request(`https://do.internal${EMOTE_FIT_PATH}?${query}`, {
                method: "POST",
                headers: { "x-internal-key": ctx.env.COBALT_API_KEY, "content-length": String(bytes), "content-type": "application/octet-stream" },
                body,
                duplex: "half",
            } as RequestInit),
        ),
});
const makeDeps = (ctx: OpContext): MakeDeps => {
    const u = uploadDeps(ctx);
    return { db: ctx.db, now: ctx.now, keyId: ctx.keyId, originals: ctx.env.ORIGINALS, media: ctx.env.MEDIA, ...(u.fit ? { fit: u.fit } : {}) };
};
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

const FitCrop = z
    .object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1), w: z.number().gt(0).max(1), h: z.number().gt(0).max(1) })
    .describe("crop box before uploading, fractions of the picture: left, top, width, height (look at it with a grid first; never guess)");
const FitSize = z.number().int().min(32).max(1000).describe("longest side in px after fitting (default 512 when it has to shrink; never enlarged)");
const UploadShape = z
    .object({
        status: Status,
        emote_id: z.string(),
        name: z.string(),
        file_id: z.string().describe("the library file that was uploaded"),
        page_url: z.string(),
        pending: z.boolean().describe("7TV still processing the images (usually a minute)"),
        fitted: z
            .object({ width: z.number(), height: z.number(), frames: z.number(), bytes: z.number(), quality: z.number() })
            .nullable()
            .describe("what was sent when the picture was cropped or resized first; null when it went as it was"),
        added: z.object({ set_id: z.string(), alias: z.string().nullable() }).nullable(),
        add_error: z.object({ code: z.string(), message: z.string().optional() }).optional(),
    })
    .meta({ id: "SevenTvUpload" });
const MakeShape = z
    .object({
        status: Status,
        draft_id: z.string().describe("22 url-safe characters; the draft lives 24 h"),
        format: z.enum(["webp", "gif", "png"]),
        content_type: z.string(),
        width: z.number().int(),
        height: z.number().int(),
        frames: z.number().int(),
        duration_ms: z.number().int().describe("one loop, bounce included"),
        bytes: z.number().int(),
        quality: z.number().int().describe("the quality used (a gif: its palette as a share of 256 colours; a png: 100)"),
        over_cap: z.boolean().describe("a fixed quality came out over 7 MiB less 64 KiB: the file is made, the app shows it amber"),
        url: z.string().describe("/7tv/drafts/<draft_id> on this host"),
        expires_at: z.number().int().describe("ms"),
    })
    .meta({ id: "SevenTvEmoteDraft" });
const MakeInput = z.looseObject({
    file: z.string().max(64).describe("library file id, public id or post id: a picture or a video"),
    crop: FitCrop.nullable().optional(),
    stretch: z
        .object({ w: z.number().min(0.25).max(4), h: z.number().min(0.25).max(4) })
        .nullable()
        .optional()
        .describe("squash or stretch after the crop, each way on its own (1 = unchanged)"),
    size: FitSize.nullable().optional(),
    format: z.enum(["webp", "gif", "png"]).nullable().optional(),
    quality: z.number().int().min(1).max(100).nullable().optional().describe("one encode at this quality; absent = the automatic ladder"),
    fps: z.number().int().min(5).max(50).nullable().optional(),
    start: z.number().min(0).nullable().optional().describe("video only, seconds"),
    end: z.number().min(0).nullable().optional().describe("video only, seconds; end - start is 0.2 to 10"),
    bounce: z.boolean().nullable().optional(),
    frame: z.number().min(0).nullable().optional().describe("seconds into the source: the still for png"),
    replace: z.string().max(64).nullable().optional().describe("a draft id of this key to delete first"),
});
const SavedDraftShape = z.object({ status: Status, item_id: z.string(), file_id: z.string() }).meta({ id: "SevenTvDraftSaved" });
const UploadsShape = z
    .object({
        uploads: z.array(
            z.object({ file_id: z.string(), emote_id: z.string(), name: z.string(), set_id: z.string().nullable(), created_at: z.number() }),
        ),
    })
    .meta({ id: "SevenTvUploads" });
const OwnedShape = z
    .object({
        owner_id: z.string(),
        total: z.number().describe("how many the account owns; at most 500 are listed"),
        emotes: z.array(
            z.object({
                emote_id: z.string(),
                name: z.string(),
                animated: z.boolean(),
                private: z.boolean(),
                zero_width: z.boolean(),
                pending: z.boolean().describe("7TV still processing the images"),
                preview_url: z.string().nullable(),
                file_url: z.string().nullable(),
                page_url: z.string(),
                file_id: z.string().nullable().describe("the library file it was uploaded from, when capystore uploaded it"),
                created_at: z.number().nullable().describe("ms, from the emote id"),
            }),
        ),
    })
    .meta({ id: "SevenTvOwned" });
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
        summary: "Forget the 7TV token (DELETE /7tv); ?logout=1 also ends that session on 7TV (the app's own login sheet).",
        run: (ctx) => sevenTvUnlink(deps(ctx), { logout: ctx.query.get("logout") === "1" }),
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
            file: z.string().max(64).optional(),
            draft: z.string().max(64).nullable().optional().describe("a draft id of this key (POST /7tv/emotes/make) instead of file: its bytes go as they are"),
            name: z.string().max(400),
            tags: z.array(z.string().max(64)).max(6).optional(),
            zero_width: z.boolean().optional(),
            private: z.boolean().optional(),
            set_id: z.string().max(64).nullable().optional(),
            alias: z.string().max(400).nullable().optional(),
            crop: FitCrop.nullable().optional(),
            size: FitSize.nullable().optional(),
        }),
        output: UploadShape,
        summary: "Upload a library picture (webp, gif, png, avif, jpeg) as a new 7TV emote, optionally cropped and resized first and added to a set (POST /7tv/emotes).",
        run: (ctx, input) => sevenTvUpload(uploadDeps(ctx), input),
    }),
    route({
        name: "seventv_http.make",
        method: "POST",
        path: "/7tv/emotes/make",
        input: MakeInput,
        output: MakeShape,
        summary:
            "Make a draft emote from a library picture or video: crop, squash, format (webp, gif, png), quality, frame rate, video moment, bounce. The draft lives 24 h (POST /7tv/emotes/make).",
        run: (ctx, input) => makeEmote(makeDeps(ctx), input as Record<string, unknown>),
    }),
    route({
        name: "seventv_http.draft_delete",
        method: "DELETE",
        path: "/7tv/drafts/:id",
        params: { id: DRAFT_ID },
        output: z.object({ status: Status, deleted: z.literal(true) }),
        summary: "Delete an emote draft (DELETE /7tv/drafts/<id>).",
        run: (ctx) => removeDraft(makeDeps(ctx), ctx.params.id!),
    }),
    route({
        name: "seventv_http.draft_save",
        method: "POST",
        path: "/7tv/drafts/:id/save",
        params: { id: DRAFT_ID },
        input: z.looseObject({ title: z.string().max(400).nullable().optional() }),
        output: SavedDraftShape,
        summary: "Save an emote draft as a private library item; the draft is kept (POST /7tv/drafts/<id>/save).",
        run: (ctx, input) => saveDraft(makeDeps(ctx), ctx.params.id!, input as Record<string, unknown>),
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
    route({
        name: "seventv_http.uploads",
        method: "GET",
        path: "/7tv/uploads",
        output: UploadsShape.extend({ status: Status }),
        summary: "Emotes uploaded to 7TV through capystore, newest first, at most 100 (GET /7tv/uploads).",
        run: (ctx) => sevenTvUploads(deps(ctx)),
    }),
    route({
        name: "seventv_http.owned",
        method: "GET",
        path: "/7tv/owned",
        output: OwnedShape.extend({ status: Status }),
        summary: "Every emote the linked 7TV account owns (uploaded anywhere), newest first, at most 500 (GET /7tv/owned).",
        run: (ctx) => sevenTvOwned(deps(ctx)),
    }),
    // the draft's file itself (71.2): bytes, not JSON
    defineOp({
        name: "seventv_http.draft",
        route: { method: "GET", path: "/7tv/drafts/:id", params: { id: DRAFT_ID } },
        auth: "key",
        runs: "worker",
        cors: true,
        raw: true,
        input: z.looseObject({}),
        badRequest: "error.seventv.bad",
        ai: { tier: "hidden", summary: "An emote draft's file (GET /7tv/drafts/<id>), private to the key that made it." },
        handler: (ctx) => getDraftFile(makeDeps(ctx), ctx.params.id!),
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
    "error.seventv.name_taken": "that name is already in the set: add it under another alias, rename the one there, or pass override_conflicts to replace it",
    "error.seventv.rejected": "7TV refused that",
    "error.seventv.unavailable": "7TV is not answering",
    "error.seventv.file_not_found": "no library file or post by that id (show_post lists a post's files)",
    "error.seventv.file_type": "7TV takes webp, gif, png, avif or jpeg pictures, not videos",
    "error.seventv.too_big": "7TV takes files up to 7 MB",
    "error.seventv.too_large": "7TV would drop this picture",
    "error.seventv.fit_failed": "the picture could not be resized for 7TV",
    "error.seventv.busy": "the media helper is busy; try again in a minute",
    "error.seventv.set_full": "the set has no room for that many",
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
        summary: "Add a 7TV emote to an emote set (find it with emotes.find). A name already in the set answers error.seventv.name_taken: pick another alias, rename the one there, or override_conflicts: true to replace it (say which to Harmony). Asks Harmony first.",
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
        crop: FitCrop.optional(),
        size: FitSize.optional(),
    }),
    output: UploadShape.omit({ status: true }),
    ai: {
        refs: { file: "file" },
        tier: "ask",
        only: true,
        summary:
            "Upload a library picture (an animated webp, gif, png...) to 7TV as a NEW emote owned by the linked account, and optionally add it to a set. Pictures over 7 MB or 1000 px are shrunk first (longest side 512 px, animation kept, at most 1000 frames); pass crop (look at the picture with a grid first, never guess) to cut a box out, or size to choose the longest side. A picture wider than 3:1 needs a crop. 7TV processes it for about a minute (seventv.emote shows when it is ready). A private emote can only go into the uploader's own sets. Asks Harmony first.",
        params: ["file", "name"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `upload ${input.file} to 7TV as “${input.name}”${input.set_id ? ` and add it to set ${input.set_id}` : ""}`,
            effect: { file: input.file, name: input.name, ...(input.set_id ? { set_id: input.set_id } : {}), ...(input.private ? { private: true } : {}), ...(input.crop ? { crop: input.crop } : {}), ...(input.size ? { size: input.size } : {}) },
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

const uploadsOp = defineOp({
    name: "seventv.uploads",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: UploadsShape,
    ai: { tier: "free", only: true, summary: "Emotes uploaded to 7TV through capystore (which library file became which emote), newest first.", params: [] },
    handler: (ctx) => strip(sevenTvUploads(deps(ctx))),
});

const ownedOp = defineOp({
    name: "seventv.owned",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: OwnedShape,
    ai: { tier: "free", only: true, summary: "Every emote the linked 7TV account owns (uploaded through capystore or on 7tv.app), newest first; add one to a set with seventv.add.", params: [] },
    handler: (ctx) => strip(sevenTvOwned(deps(ctx))),
});

// ---- section 63.4-63.5: many adds with one approval, cloning a set, and what the account may do ----------------------------

const AddItemShape = z.object({ emote_id: z.string(), alias: z.string().nullable() });
const AddManyShape = z
    .object({
        set_id: z.string(),
        set_name: z.string(),
        capacity: z.number().nullable(),
        count_before: z.number(),
        count_after: z.number().optional(),
        dry_run: z.literal(true).optional(),
        would_add: z.array(AddItemShape).optional().describe("dry_run: what a real call would add"),
        added: z.array(AddItemShape),
        skipped: z.array(AddItemShape.extend({ why: z.string() })).describe("already in the set: a repeated call skips what went in before"),
        failed: z.array(AddItemShape.extend({ code: z.string(), message: z.string().optional() })),
        remaining: z.array(AddItemShape).describe("not tried because the call stopped (see stopped): call again with the same list"),
        stopped: z.string().optional(),
    })
    .meta({ id: "SevenTvAddMany" });
const ManyItem = z.object({ emote_id: EmoteId, alias: Alias.optional().describe("its name in the set, when different from the emote's own") });

const addManyOp = defineOp({
    name: "seventv.addMany",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        set_id: SetId,
        emotes: z.array(ManyItem).min(1).max(ADD_MANY_MAX).describe(`the emotes to add, 1 to ${ADD_MANY_MAX}`),
        override_conflicts: z.boolean().optional().describe("an alias already in the set is replaced by the new emote"),
        dry_run: z.boolean().optional().describe("only answer what would be added and skipped (no approval needed)"),
    }),
    output: AddManyShape,
    ai: {
        tier: "ask",
        only: true,
        summary:
            "Add many emotes to one 7TV set with ONE approval (instead of seventv.add per emote). Reads the set first: what is already in under that alias is skipped (so the same call can be repeated to finish), a set too full is refused up front, a refused account (LACKING_PRIVILEGES) stops at the first batch, rate limits wait and retry. Answers added / skipped / failed / remaining. dry_run: true previews. Asks Harmony first.",
        params: ["set_id", "emotes"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `${input.dry_run ? "preview adding" : "add"} ${input.emotes.length} 7TV emote${input.emotes.length === 1 ? "" : "s"} to set ${input.set_id}${input.override_conflicts ? ", replacing names already there" : ""}`,
            effect: { set_id: input.set_id, count: input.emotes.length, first: input.emotes.slice(0, 8).map((e) => e.alias ?? e.emote_id) },
        }),
    },
    handler: (ctx, input) =>
        strip(
            sevenTvAddMany(
                deps(ctx),
                input.set_id,
                input.emotes.map((e) => ({ emote_id: e.emote_id, alias: e.alias ?? null })),
                { ...(input.override_conflicts ? { override_conflicts: true } : {}), ...(input.dry_run ? { dry_run: true } : {}) },
            ),
        ),
});

const cloneSetOp = defineOp({
    name: "seventv.cloneSet",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        from_set_id: SetId.describe("the set to copy (e.g. the live set)"),
        to_set_id: SetId.describe("the set to fill (make it first, or ask the channel to)"),
        swap: z.array(z.object({ alias: z.string().trim().min(1).max(100), emote_id: EmoteId })).max(ADD_MANY_MAX).optional().describe("aliases of the source set to fill with another emote (e.g. its festive version); the alias stays"),
        skip: z.array(z.string().trim().min(1).max(100)).max(ADD_MANY_MAX).optional().describe("aliases to leave out"),
        only: z.array(z.string().trim().min(1).max(100)).max(ADD_MANY_MAX).optional().describe("copy only these aliases"),
        dry_run: z.boolean().optional().describe("only answer the plan"),
    }),
    output: AddManyShape.extend({
        from: z.object({ id: z.string(), name: z.string(), count: z.number() }),
        swapped: z.number(),
        unknown_swaps: z.array(z.string()).describe("swap aliases that are not in the source set (nothing was done with them)"),
    }),
    ai: {
        tier: "ask",
        only: true,
        summary:
            "Copy a 7TV set into another with ONE approval: every emote keeps its alias, swap: [{ alias, emote_id }] puts another emote under an alias (a seasonal version), skip/only pick aliases. Runs like seventv.addMany (skips what is already there, so it can be repeated). dry_run: true answers the plan first. Never touches the source set. Asks Harmony first.",
        params: ["from_set_id", "to_set_id"],
        options: true,
        preview: async (_ctx, input) => ({
            summary: `${input.dry_run ? "preview copying" : "copy"} 7TV set ${input.from_set_id} into ${input.to_set_id}${input.swap?.length ? ` with ${input.swap.length} swap${input.swap.length === 1 ? "" : "s"}` : ""}`,
            effect: { from_set_id: input.from_set_id, to_set_id: input.to_set_id, swaps: input.swap?.length ?? 0, ...(input.skip?.length ? { skip: input.skip.length } : {}), ...(input.only?.length ? { only: input.only.length } : {}) },
        }),
    },
    handler: async (ctx, input) => {
        const plan = await sevenTvClonePlan(deps(ctx), input);
        if ("status" in plan) {
            await run(Promise.resolve(plan));
            throw new OpError(502, "error.api.generic");
        }
        if (plan.items.length === 0) throw new OpError(400, "error.seventv.bad", "seventv.cloneSet: nothing to copy (the source set is empty, or skip/only left nothing)");
        const body = await run<Record<string, unknown>>(sevenTvAddMany(deps(ctx), input.to_set_id, plan.items, input.dry_run ? { dry_run: true } : {}));
        const { status: _s, ...rest } = body;
        return ok({ ...rest, from: plan.from, swapped: plan.swapped, unknown_swaps: plan.unknown_swaps });
    },
});

const PermChannel = z.object({
    channel_id: z.string(),
    name: z.string(),
    you: z.boolean(),
    editor_state: z.string().nullable(),
    active_set_id: z.string().nullable(),
    sets: z.number().describe("the channel's emote sets"),
    set_limit: z.number().nullable().describe("its most sets (known for your own channel only)"),
    can: z.object({
        add_remove_rename: z.boolean(),
        create_sets: z.boolean(),
        make_live: z.boolean(),
        upload_emotes: z.boolean().describe("uploads always go to your own account: true on your own channel only"),
    }),
    blockers: z.array(z.string()).describe("what 7TV will refuse and why, before you try"),
    editor_permissions: z.unknown().nullable(),
});

const permissionsOp = defineOp({
    name: "seventv.permissions",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ channel: ChannelRef.optional().describe("one channel (default: every channel the account can reach)") }),
    output: z.object({
        account: z.object({ id: z.string(), name: z.string(), set_limit: z.number().nullable(), set_capacity: z.number().nullable() }),
        channels: z.array(PermChannel),
    }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "Check before a 7TV job what the linked account may do on each channel: add/remove/rename emotes, create sets, make a set live, upload, each with the reason when it may not (the LACKING_PRIVILEGES cases, e.g. no \"create\" right on someone else's channel, or a channel at its set limit).",
        params: [],
        options: true,
    },
    handler: async (ctx, input) => {
        const ch = input.channel ? await channelOf(ctx, input.channel) : null;
        return strip(sevenTvPermissions(deps(ctx), ch?.id ?? null));
    },
});

export const SEVENTV_OPS = [...ROUTE_OPS, statusOp, setsOp, setOp, addOp, removeOp, renameOp, makeLiveOp, createSetOp, renameSetOp, uploadOp, emoteOp, uploadsOp, ownedOp, addManyOp, cloneSetOp, permissionsOp];
