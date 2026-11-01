// Library writes (APP-API-CONTRACT.md 33.7, plan thread T3): the save, upload, publish, visibility, title, delete, made
// file, recent, line, cancel and retry routes as ops, plus the chat AI's calls that change the library:
// cobalt.library.save, .title, .visibility, .delete, .deleteFile and cobalt.queue (library.ts).
//
// The route ops wrap the existing handlers unchanged (same parsing, bodies, headers and request log). The chat calls
// take a post id (the `id` of library.list / search / post), find the post's files, and call the same handlers. Deletes
// and making something private are tier `ask`: Harmony gets a confirm card first.
import * as z from "zod";
import {
    libraryItemDelete,
    libraryMade,
    libraryPostDelete,
    libraryPostTitle,
    libraryPublish,
    libraryVisibility,
    POST_KEY_SQL,
    studioUpload,
    uploadLogInfo,
} from "../../app-routes";
import { loadPosts } from "../../chat-tools";
import { ITEM_ID_REGEX, STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "../../gate";
import { KEY_ID_HEADER } from "../../headers";
import { publishStudio } from "../../publish";
import { HIDDEN_HINT, hiddenTargets } from "../../hidden";
import { bodyLink, describeBody, logRequest, normalizeUrlField } from "../../request-log";
import { studioErr } from "../../studio";
import { studioStatus } from "../../studio-edge";
import { effectiveVisibility, isWebpSource, purgeFrom } from "../../visibility";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";

// ---- the routes -------------------------------------------------------------------------------------------------------

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// The route ops below read their own request (bodies are streamed or parsed by the old handlers): no schema input.
const NoInput = z.object({});
const none = () => ({});
const reply = (r: { status: number; body: unknown }): OpReply => ({ status: r.status, body: r.body });
const keyOf = (ctx: OpContext) => ctx.keyId!;

// POST /studio (sections 2, 14, 17.3, 18.2): the free-text `url` is cut to its first link, a body with no link is
// refused here, everything else goes to the Durable Object with the verified key id. Logged in request_log.
export const studioCreateOp = defineOp({
    name: "studio.create",
    route: { method: "POST", path: "/studio" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    raw: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Save a link (POST /studio); the chat uses library.save." },
    handler: async (ctx) => {
        // Log AFTER extraction: a Shortcut may send its clipboard as `url`, which must never be stored (worker.ts history).
        const request = await normalizeUrlField(ctx.request!);
        const logEntry = await describeBody(request);
        if (logEntry.urlPrefix !== null && !/^https?:\/\//i.test(logEntry.urlPrefix)) logEntry.urlPrefix = null;
        if ((await bodyLink(request)) === null) {
            const res = json(400, studioErr(400, "error.studio.no_link").body);
            await logRequest(ctx.db, "POST /studio", keyOf(ctx), request, logEntry, res);
            return res;
        }
        const headers = new Headers(request.headers);
        headers.delete("Authorization");
        headers.set(KEY_ID_HEADER, keyOf(ctx));
        const res = await ctx.container.fetch(new Request(request, { headers }));
        await logRequest(ctx.db, "POST /studio", keyOf(ctx), request, logEntry, res);
        return res;
    },
});

// PUT /studio/upload (section 3): the body is streamed to R2, never read here, and never reaches the request log.
export const studioUploadOp = defineOp({
    name: "studio.upload",
    route: { method: "PUT", path: "/studio/upload" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    raw: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Upload a file (PUT /studio/upload)." },
    handler: async (ctx) => {
        const r = await studioUpload(ctx.app(), ctx.request!, keyOf(ctx), ctx.query);
        const res = json(r.status, r.body);
        await logRequest(ctx.db, "PUT /studio/upload", keyOf(ctx), ctx.request!, uploadLogInfo(ctx.request!), res);
        return res;
    },
});

// POST /studio/<sid>/publish (sections 13, 16.3): D1 + R2, answered here.
export const studioPublishOp = defineOp({
    name: "studio.publish",
    route: { method: "POST", path: "/studio/:sid/publish", params: { sid: STUDIO_SID_REGEX } },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Host a session's original publicly (legacy)." },
    handler: async (ctx) =>
        reply(
            await publishStudio(
                {
                    db: ctx.db,
                    originals: ctx.env.ORIGINALS,
                    media: ctx.env.MEDIA,
                    mediaBaseUrl: ctx.mediaBaseUrl,
                    now: ctx.now,
                    purge: purgeFrom(ctx.env),
                },
                ctx.params.sid!,
                keyOf(ctx),
            ),
        ),
});

const itemRoute = (method: "POST" | "PATCH" | "DELETE" | "PUT", sub: string) => ({
    method,
    path: `/library/items/:id${sub}`,
    params: { id: ITEM_ID_REGEX },
});

// POST /library/items/<id>/publish (16.3): the legacy spelling of "public on".
export const libraryPublishOp = defineOp({
    name: "library.publish",
    route: itemRoute("POST", "/publish"),
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Host an original publicly (legacy)." },
    handler: async (ctx) => reply(await libraryPublish(ctx.app(), ctx.params.id!, keyOf(ctx))),
});

// PATCH /library/items/<id>/visibility (16.2): no CORS, no-store.
export const libraryVisibilityRouteOp = defineOp({
    name: "library.visibility.route",
    route: itemRoute("PATCH", "/visibility"),
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "One file public or private." },
    handler: async (ctx) => reply(await libraryVisibility(ctx.app(), ctx.params.id!, ctx.request!, keyOf(ctx))),
});

// PATCH /library/items/<id>/post (section 15): a post's custom title. No CORS, no-store.
export const libraryTitleRouteOp = defineOp({
    name: "library.title.route",
    route: itemRoute("PATCH", "/post"),
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "A post's custom title." },
    handler: async (ctx) => reply(await libraryPostTitle(ctx.app(), ctx.params.id!, ctx.request!, keyOf(ctx))),
});

// DELETE /library/items/<id>/post (section 12): the whole post. No CORS, no-store.
export const libraryPostDeleteRouteOp = defineOp({
    name: "library.delete.route",
    route: itemRoute("DELETE", "/post"),
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Delete a whole post." },
    handler: async (ctx) => reply(await libraryPostDelete(ctx.app(), ctx.params.id!)),
});

// DELETE /library/items/<id> (18.4): one item of a gallery, or a made file. No CORS, no-store.
export const libraryItemDeleteRouteOp = defineOp({
    name: "library.deleteFile.route",
    route: itemRoute("DELETE", ""),
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Delete one file of a post." },
    handler: async (ctx) => reply(await libraryItemDelete(ctx.app(), ctx.params.id!)),
});

// PUT /library/items/<id>/made (18.6): a crop or export made on the device; the body is streamed to R2.
export const libraryMadeOp = defineOp({
    name: "library.made",
    route: itemRoute("PUT", "/made"),
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Store a file made on the device." },
    handler: async (ctx) => reply(await libraryMade(ctx.app(), ctx.params.id!, ctx.request!, keyOf(ctx), ctx.query)),
});

// The Durable Object's keyed studio routes: client keys only (the library service gets 404), forwarded with the key id.
const doRoute = (name: string, method: "GET" | "POST" | "DELETE", path: string, summary: string, params?: Record<string, RegExp>) =>
    defineOp({
        name,
        route: { method, path, ...(params ? { params } : {}) },
        auth: "key",
        runs: "durable_object",
        cors: false,
        input: NoInput,
        ai: { tier: "hidden", summary },
    });

// GET /studio/recent (14.2), GET /studio/line (17.4), the cancels (17.7) and the retry of failed gallery items (18.2).
export const studioRecentOp = doRoute("studio.recent", "GET", "/studio/recent", "A share sheet's recent saves.");
export const studioLineOp = doRoute("studio.line", "GET", "/studio/line", "The server's line.");
export const studioCancelOp = doRoute("studio.cancel", "DELETE", "/studio/:sid/line", "Cancel a waiting save.", { sid: STUDIO_SID_REGEX });
export const studioRenderCancelOp = doRoute("studio.render.cancel", "DELETE", "/studio/:sid/render/:job", "Cancel a waiting render.", {
    sid: STUDIO_SID_REGEX,
    job: STUDIO_JOB_REGEX,
});
export const studioRetryOp = doRoute("studio.items.retry", "POST", "/studio/:sid/items/retry", "Save a gallery's failed items again.", {
    sid: STUDIO_SID_REGEX,
});

// ---- the chat AI's calls -------------------------------------------------------------------------------------------

export const CHAT_DAILY_SAVES = 20;
export const SAVE_WAIT_MAX_S = 60;
const DAY_MS = 24 * 60 * 60 * 1000;
// one long-poll of the save (the advance route clamps its own wait at 25 s)
const SAVE_POLL_S = 20;

// The per-thread cap on saves in any 24 hours (`CHAT_DAILY_SAVES`, default 20; "0" turns chat saves off).
export function dailySaves(env: { CHAT_DAILY_SAVES?: string }): number {
    const raw = env.CHAT_DAILY_SAVES;
    if (raw === undefined || raw.trim() === "") return CHAT_DAILY_SAVES;
    const n = Number(raw);
    return Number.isInteger(n) && n >= 0 ? n : CHAT_DAILY_SAVES;
}

const chatOnly = (ctx: OpContext) => {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", "only the chat can call this");
    return ctx.chat;
};

type PostFileRow = {
    id: string;
    public_id: string | null;
    bucket: string;
    source: string;
    role: string | null;
    visibility: string | null;
    url: string | null;
    bytes: number | null;
    name: string | null;
};

// Every live file of a post, oldest first (the post id is the `id` the read tools give: POST_KEY_SQL).
async function postFiles(db: D1Database, postId: string): Promise<PostFileRow[]> {
    const { results } = await db
        .prepare(
            `SELECT m.id, m.public_id, m.bucket, m.source, m.role, m.visibility, m.url, m.bytes, m.name FROM media_items m
             WHERE m.deleted_at IS NULL AND ${POST_KEY_SQL} = ?1 ORDER BY m.created_at, m.id`,
        )
        .bind(postId)
        .all<PostFileRow>();
    return results;
}

async function onePost(ctx: OpContext, postId: string) {
    const files = await postFiles(ctx.db, postId);
    if (files.length === 0) throw new OpError(404, "error.library.not_found", `no post ${JSON.stringify(postId)} in the library (use an id from library.list, search or post)`);
    const [post] = await loadPosts({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl }, [postId]);
    return { files, title: post?.record.title ?? null, record: post?.record ?? null };
}

const isPublicRow = (r: PostFileRow) => effectiveVisibility(r) === "public" && !!r.url;
// The rows the visibility toggle accepts (visibility.ts `toggleable`): originals, and webps in the public bucket.
const toggleable = (r: PostFileRow) => r.bucket === "originals" || (r.bucket === "media" && isWebpSource(r.source));

// Live gallery share links that show any of these files.
async function shareLinksWith(db: D1Database, files: PostFileRow[]): Promise<number> {
    const ids = [...new Set(files.flatMap((f) => (f.public_id ? [f.id, f.public_id] : [f.id])))];
    if (ids.length === 0) return 0;
    const row = await db
        .prepare(
            `SELECT COUNT(*) AS n FROM share_sets s WHERE s.revoked_at IS NULL
             AND EXISTS (SELECT 1 FROM json_each(s.items) j WHERE j.value IN (${ids.map((_, i) => `?${i + 1}`).join(", ")}))`,
        )
        .bind(...ids)
        .first<{ n: number }>();
    return row?.n ?? 0;
}

const quoted = (title: string | null) => (title ? `“${title.length > 60 ? `${title.slice(0, 59)}…` : title}”` : "this post");
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// What a handler refused, as the error the model reads.
const refused = (r: { status: number; body: unknown }, what: string) => {
    const code = (r.body as { error?: { code?: unknown } } | null)?.error?.code;
    return new OpError(r.status, typeof code === "string" ? code : "error.api.generic", `${what} failed: ${typeof code === "string" ? code : `status ${r.status}`}`);
};

// A body the old handlers read from a Request.
const jsonRequest = (method: string, body: unknown) =>
    new Request("https://do.internal/chat", { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

type SessionPeek = { status?: string; step?: string | null; error?: { code?: string } | null };

const PostId = z.string().min(1).max(2048).describe("a post id (from library.list, search or post)");

export const SaveResult = z
    .object({
        status: z.enum(["ready", "saving", "queued", "error"]).describe('"saving"/"queued": still going after the wait; check later with cobalt.queue()'),
        save_id: z.string().describe("the save (studio session) id"),
        post_id: z.string().nullable().describe("the new post's id once ready (use it with post, show, title...)"),
        title: z.string().nullable(),
        kind: z.enum(["video", "image", "gallery"]).nullable(),
        files: z.number().nullable(),
        public: z.boolean().nullable(),
        error: z.string().nullable().describe('why it failed, e.g. "error.studio.fetch_failed"'),
        saves_left_today: z.number(),
    })
    .meta({ id: "SaveResult" });

// cobalt.library.save(url, { items, public, title, wait }): the app's POST /studio as the chat (key id chat:<thread>,
// always queued so a busy helper never refuses it), then up to `wait` seconds of the save's own long-poll.
// The chat's save (library.save and ytdlp.save, section 49.6): POST /studio as the chat, then the save's own long-poll.
export type ChatSaveInput = {
    url: string;
    items?: "all" | "first-video" | number[];
    public?: boolean;
    title?: string;
    wait?: number;
    engine?: "cobalt" | "ytdlp";
};
export async function chatSave(ctx: OpContext, input: ChatSaveInput): Promise<OpReply> {
    chatOnly(ctx);
    const keyId = ctx.keyId!;
    const cap = dailySaves(ctx.env);
    const since = ctx.now() - DAY_MS;
    const used =
        (await ctx.db.prepare("SELECT COUNT(*) AS n FROM studio_sessions WHERE key_id = ?1 AND created_at > ?2").bind(keyId, since).first<{ n: number }>())?.n ?? 0;
    if (used >= cap) {
        throw new OpError(429, "error.chat.save_cap", `this thread already saved ${used} links today (the cap is ${cap}); tell Harmony to save it in the app or try tomorrow`);
    }
    const body: Record<string, unknown> = { url: input.url.trim(), queue: true };
    if (input.items !== undefined) body.items = input.items;
    if (input.public !== undefined) body.public = input.public;
    if (input.title !== undefined) body.title = input.title;
    if (input.engine !== undefined) body.engine = input.engine;
    const res = await ctx.durableObject("/studio", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    const created = (await res.json().catch(() => null)) as { id?: unknown; queued?: unknown; error?: { code?: unknown } } | null;
    if (res.status !== 201 || typeof created?.id !== "string") throw refused({ status: res.status, body: created }, "cobalt.library.save");
    const sid = created.id;

    // the save's own long-poll (GET /studio/<sid>?wait=N), as the app polls it
    let session: SessionPeek | null = null;
    const waitS = input.wait ?? SAVE_WAIT_MAX_S;
    const deadline = ctx.now() + waitS * 1000;
    for (let left = waitS; ; ) {
        const step = Math.min(SAVE_POLL_S, Math.max(0, left));
        const r = await studioStatus(ctx.db, ctx.container, sid, step, ctx.edge);
        session = r.ok ? ((await r.json().catch(() => null)) as SessionPeek | null) : null;
        if (!session || session.status !== "saving") break;
        left -= SAVE_POLL_S;
        if (left <= 0 || ctx.now() >= deadline) break;
    }
    const left = Math.max(0, cap - used - 1);
    const st = session?.status;
    if (st === "ready") {
        const [post] = await loadPosts({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl }, [sid]);
        return ok({
            status: "ready",
            save_id: sid,
            post_id: post ? post.record.id : null,
            title: post?.record.title ?? null,
            kind: post?.record.kind ?? null,
            files: post?.record.files ?? null,
            public: post?.record.public ?? null,
            error: null,
            saves_left_today: left,
        });
    }
    return ok({
        status: st === "error" || st === "expired" ? "error" : session?.step === "queued" || created.queued === true ? "queued" : "saving",
        save_id: sid,
        post_id: null,
        title: null,
        kind: null,
        files: null,
        public: null,
        error: st === "error" || st === "expired" ? (session?.error?.code ?? "error.api.generic") : null,
        saves_left_today: left,
    });
}

export const librarySaveOp = defineOp({
    name: "library.save",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        url: z
            .string()
            .min(1)
            .max(4096)
            .refine((u) => /^https?:\/\/\S+$/i.test(u.trim()), "must be one http(s) link")
            .describe("the link to save (a post, a video page, or a direct file link)"),
        items: z
            .union([z.literal("all"), z.literal("first-video"), z.array(z.number().int().min(0)).min(1).max(20)])
            .optional()
            .describe('a gallery: "all", "first-video", or picker indices; default: its first video'),
        public: z.boolean().optional().describe("also give it a public link (default: private)"),
        title: z.string().max(80).optional().describe("a custom title"),
        wait: z.number().min(0).max(SAVE_WAIT_MAX_S).optional().describe(`seconds to wait for it, default and max ${SAVE_WAIT_MAX_S}`),
        engine: z
            .enum(["cobalt", "ytdlp"])
            .optional()
            .describe('which downloader goes first: "ytdlp" (yt-dlp) for a site cobalt cannot save; default: cobalt, then yt-dlp when cobalt fails. Not with items'),
    }),
    output: SaveResult,
    ai: {
        tier: "free",
        only: true,
        summary: `Save a link into the library, like pasting it in the app. Waits for the save (up to ${SAVE_WAIT_MAX_S} s) and returns the new post's id.\nAt most ${CHAT_DAILY_SAVES} saves per thread a day. Only save what Harmony asked for.`,
        params: ["url"],
        options: true,
    },
    handler: (ctx, input) => chatSave(ctx, input),
});

// cobalt.library.title(id, title): the post's custom title (section 15); null clears it.
export const libraryTitleOp = defineOp({
    name: "library.title",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: PostId, title: z.string().max(80).nullable().describe("1..80 characters; null clears it") }),
    output: z.object({ post_id: z.string(), title: z.string().nullable() }),
    ai: { tier: "free", only: true, summary: "Set a post's title (null goes back to the original name).", params: ["id", "title"] },
    handler: async (ctx, input) => {
        chatOnly(ctx);
        const { files } = await onePost(ctx, input.id);
        const r = await libraryPostTitle(ctx.app(), files[0]!.id, jsonRequest("PATCH", { title: input.title }), ctx.keyId!);
        if (r.status < 200 || r.status > 299) throw refused(r, "cobalt.library.title");
        const t = (r.body as { title?: unknown } | null)?.title;
        return ok({ post_id: input.id, title: typeof t === "string" ? t : null });
    },
});

// One post id or a list of them (a card can cover several posts: "delete 5 posts").
export const POSTS_PER_CARD = 50;
const PostIds = z.preprocess(
    (v) => [...new Set(Array.isArray(v) ? v : [v])],
    z.array(PostId).min(1).max(POSTS_PER_CARD),
).describe(`one post id or a list (max ${POSTS_PER_CARD})`);

// The posts behind a card, each with its live files; an unknown id fails the whole call (nothing is asked or run).
async function somePosts(ctx: OpContext, ids: string[]) {
    const out: { id: string; files: PostFileRow[]; title: string | null }[] = [];
    for (const id of ids) out.push({ id, ...(await onePost(ctx, id)) });
    return out;
}
const titleOf = (posts: { title: string | null }[]) => (posts.length === 1 ? quoted(posts[0]!.title) : `${posts.length} posts`);
const someTitles = (posts: { title: string | null }[]) => posts.slice(0, 5).map((p) => p.title ?? "untitled");

// cobalt.library.visibility(ids, public): every file of the posts that can be toggled. Making them private asks first.
export const libraryVisibilityOp = defineOp({
    name: "library.visibility",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ids: PostIds, public: z.boolean().describe("true: give them public links; false: make them private") }),
    output: z.object({ public: z.boolean(), changed: z.number(), posts: z.array(z.object({ id: z.string(), links: z.array(z.string()) })) }),
    ai: {
        tier: "ask",
        only: true,
        summary:
            "Make posts public (their files get public links; then use library.post for share_url) or private (their public links stop working).\nMaking them private asks Harmony first; making them public just runs.",
        params: ["ids", "public"],
        asks: (input) => !input.public,
        preview: async (ctx, input) => {
            const posts = await somePosts(ctx, input.ids);
            const going = posts.flatMap((p) => p.files.filter((f) => toggleable(f) && isPublicRow(f)));
            if (going.length === 0) throw new OpError(409, "error.library.already_private", `${titleOf(posts)} ${posts.length === 1 ? "is" : "are"} already private: nothing to ask`);
            return {
                summary: `make ${titleOf(posts)} private`,
                effect: {
                    titles: someTitles(posts),
                    posts: posts.length,
                    files: going.length,
                    public_links: going.length,
                    share_links: await shareLinksWith(ctx.db, going),
                },
            };
        },
    },
    handler: async (ctx, input) => {
        chatOnly(ctx);
        const want = input.public;
        // a hidden post is never made public (section 37.6)
        if (want) {
            const hidden = await hiddenTargets(ctx.db, input.ids);
            if (hidden.length > 0) throw new OpError(409, "error.hidden", `${hidden.join(", ")}: ${HIDDEN_HINT}`);
        }
        let changed = 0;
        const out: { id: string; links: string[] }[] = [];
        for (const p of await somePosts(ctx, input.ids)) {
            for (const f of p.files.filter((f) => toggleable(f) && isPublicRow(f) !== want)) {
                const r = await libraryVisibility(ctx.app(), f.id, jsonRequest("PATCH", { public: want }), ctx.keyId!);
                if (r.status < 200 || r.status > 299) throw refused(r, "cobalt.library.visibility");
                changed++;
            }
            out.push({ id: p.id, links: want ? (await postFiles(ctx.db, p.id)).filter(isPublicRow).map((f) => f.url!) : [] });
        }
        return ok({ public: want, changed, posts: out });
    },
});

// cobalt.library.delete(ids): whole posts (section 12). Always asks first.
export const libraryDeleteOp = defineOp({
    name: "library.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ids: PostIds }),
    output: z.object({ deleted: z.array(z.string()), files: z.number() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete whole posts and every file of them, public links included. Several posts go on one card.",
        params: ["ids"],
        preview: async (ctx, input) => {
            const posts = await somePosts(ctx, input.ids);
            const files = posts.flatMap((p) => p.files);
            const one = posts.length === 1 && files.length > 1 ? ` (${plural(files.length, "file")})` : "";
            return {
                summary: `delete ${titleOf(posts)}${one}`,
                effect: {
                    titles: someTitles(posts),
                    posts: posts.length,
                    files: files.length,
                    bytes: files.reduce((n, f) => n + (f.bytes ?? 0), 0),
                    public_links: files.filter(isPublicRow).length,
                    share_links: await shareLinksWith(ctx.db, files),
                },
            };
        },
    },
    handler: async (ctx, input) => {
        chatOnly(ctx);
        const deleted: string[] = [];
        let n = 0;
        for (const id of input.ids) {
            // a post deleted while the card waited is skipped, not an error
            const files = await postFiles(ctx.db, id);
            if (files.length === 0) continue;
            const r = await libraryPostDelete(ctx.app(), files[0]!.id);
            if (r.status < 200 || r.status > 299) throw refused(r, "cobalt.library.delete");
            deleted.push(id);
            n += files.length;
        }
        return ok({ deleted, files: n });
    },
});

// cobalt.library.deleteFile(fileId): one item of a gallery or a made file (18.4). Always asks first.
export const libraryDeleteFileOp = defineOp({
    name: "library.deleteFile",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(ITEM_ID_REGEX, "a file id (16 letters/digits, from library.post's files)") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete one file of a post: a gallery item or a made file (a crop, export, slideshow). The post's last item can't go this way: delete the post.",
        params: ["id"],
        preview: async (ctx, input) => {
            const f = await ctx.db
                .prepare(
                    `SELECT m.id, m.public_id, m.bucket, m.source, m.role, m.visibility, m.url, m.bytes, m.name, ${POST_KEY_SQL} AS post_key
                     FROM media_items m WHERE m.id = ?1 AND m.deleted_at IS NULL`,
                )
                .bind(input.id)
                .first<PostFileRow & { post_key: string }>();
            if (!f) throw new OpError(404, "error.library.not_found", `no file ${input.id}`);
            if (f.role !== "item" && f.role !== "slideshow" && f.role !== "crop" && f.role !== "export") {
                throw new OpError(409, "error.library.not_deletable", "that is a post's original: delete the whole post with cobalt.library.delete");
            }
            const [post] = await loadPosts({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl }, [f.post_key]);
            const name = f.name ?? (f.role === "item" ? "one file" : `the ${f.role}`);
            return {
                summary: `delete ${quoted(name)} from ${quoted(post?.record.title ?? null)}`,
                effect: {
                    title: post?.record.title ?? null,
                    files: 1,
                    bytes: f.bytes ?? 0,
                    public_links: isPublicRow(f) ? 1 : 0,
                    share_links: await shareLinksWith(ctx.db, [f]),
                },
            };
        },
    },
    handler: async (ctx, input) => {
        chatOnly(ctx);
        const r = await libraryItemDelete(ctx.app(), input.id);
        if (r.status < 200 || r.status > 299) throw refused(r, "cobalt.library.deleteFile");
        return ok({ deleted: input.id });
    },
});

export const LIBRARY_WRITE_OPS = [
    librarySaveOp,
    libraryTitleOp,
    libraryVisibilityOp,
    libraryDeleteOp,
    libraryDeleteFileOp,
    studioCreateOp,
    studioUploadOp,
    studioPublishOp,
    libraryPublishOp,
    libraryVisibilityRouteOp,
    libraryTitleRouteOp,
    libraryPostDeleteRouteOp,
    libraryItemDeleteRouteOp,
    libraryMadeOp,
    studioRecentOp,
    studioLineOp,
    studioCancelOp,
    studioRenderCancelOp,
    studioRetryOp,
];
