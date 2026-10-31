// Make ops (APP-API-CONTRACT.md 33.8, plan T4): the routes that make files (the webp render of one video, the slideshow,
// the gallery image, reopening a library file, the editor) moved onto the registry unchanged, and the chat AI's calls
// that use them: cobalt.make.webp / still / trim / crop / slideshow / galleryImage, cobalt.edits.*, and
// cobalt.jobs.wait / jobs.onDone. Everything the AI starts counts against a per-thread daily cap (CHAT_DAILY_RENDERS, default 10).
//
// The route ops wrap the old handlers: same parsing, same error codes, same headers (the route snapshot pins them).
import * as z from "zod";
import { libraryStudio, POST_KEY_SQL } from "../../app-routes";
import { editsKeyed, kickRenderers, parseEditTimeline, type EditsOp, type RendererNamespace } from "../../edits";
import { EDIT_PROJECT_ID_REGEX, EDIT_RENDER_ID_REGEX, ITEM_ID_REGEX, STUDIO_JOB_REGEX, STUDIO_SID_REGEX } from "../../gate";
import { KEY_ID_HEADER } from "../../headers";
import { getSession, itemTypeOf, STILL_ADOPT_TYPES, type SessionRow } from "../../studio";
import { studioStatus } from "../../studio-edge";
import { HIDDEN_HINT, sessionPostKey } from "../../hidden";
import { hiddenRows } from "../../hidden-store";
import { effectiveVisibility } from "../../visibility";
import { budgetPort, dailyCap } from "../budget";
import { AGENT_JOB_REGEX, agentJobState, agentRow, isMissingTable } from "../../chat-agents";
import { defineOp, ok, OpError, type OpContext, type OpReply, capThreadOf } from "../op";

export const CHAT_DAILY_RENDERS_DEFAULT = 10;
// A code run stops after 30 s (chat-limits.ts), so one wait is at most 25 s; the model calls it again while pending.
export const JOB_WAIT_MAX_SECONDS = 25;

// ---- the routes ---------------------------------------------------------------------------------------------------

// These routes keep their old handlers' parsing; nothing is read here.
const NoInput = z.object({});
const noInput = () => ({});

// The editor's deps for one call (section 31.13), or null while the editor is off.
function editsDeps(ctx: OpContext) {
    if (!ctx.env.EDIT_RENDERER) return null;
    return {
        db: ctx.db,
        mediaBaseUrl: ctx.mediaBaseUrl,
        now: ctx.now,
        keyId: ctx.keyId ?? "",
        kick: kickRenderers(ctx.env.EDIT_RENDERER as unknown as RendererNamespace),
    };
}

const editOff = (): OpReply => ({ status: 404, body: { status: "error", error: { code: "error.edit.off" } } });

// POST /studio/<sid>/render and GET /studio/<sid>/render/<job> (sections 4, 10, 18.13): capability URLs (the session id
// is the credential). The request goes to the Durable Object exactly as it came (no key id; the client's headers stay).
export const studioRenderRoute = defineOp({
    name: "studio.render",
    route: { method: "POST", path: "/studio/:sid/render", params: { sid: STUDIO_SID_REGEX } },
    auth: "capability",
    runs: "durable_object",
    cors: false,
    input: NoInput,
    http: noInput,
    raw: true,
    ai: { tier: "hidden", summary: "A webp render of one video (POST /studio/<sid>/render)." },
    handler: async (ctx) => ctx.container.fetch(ctx.request!),
});

export const studioRenderStatusRoute = defineOp({
    name: "studio.render_status",
    route: { method: "GET", path: "/studio/:sid/render/:job", params: { sid: STUDIO_SID_REGEX, job: STUDIO_JOB_REGEX } },
    auth: "capability",
    runs: "durable_object",
    cors: false,
    input: NoInput,
    http: noInput,
    raw: true,
    ai: { tier: "hidden", summary: "A studio job's progress (GET /studio/<sid>/render/<job>)." },
    handler: async (ctx) => ctx.container.fetch(ctx.request!),
});

// POST /studio/<sid>/slideshow and /gallery-image (sections 18.5, 18.10, 18.11, 18.14): keyed (the service gets 404),
// answered by the Durable Object with the verified key id (it checks the session's owner).
export const studioSlideshowRoute = defineOp({
    name: "studio.slideshow",
    route: { method: "POST", path: "/studio/:sid/slideshow", params: { sid: STUDIO_SID_REGEX } },
    auth: "key",
    runs: "durable_object",
    cors: false,
    input: NoInput,
    ai: { tier: "hidden", summary: "A slideshow or a still webp (POST /studio/<sid>/slideshow)." },
});

export const studioGalleryImageRoute = defineOp({
    name: "studio.gallery_image",
    route: { method: "POST", path: "/studio/:sid/gallery-image", params: { sid: STUDIO_SID_REGEX } },
    auth: "key",
    runs: "durable_object",
    cors: false,
    input: NoInput,
    ai: { tier: "hidden", summary: "A gallery image (POST /studio/<sid>/gallery-image)." },
});

// POST /library/items/<id>/studio (sections 5d, 17.3, 18.14): reopen a private original as a studio session. Keyed or the
// library service; `?queue=1` joins the server's line.
export const libraryReopenRoute = defineOp({
    name: "library.reopen",
    route: { method: "POST", path: "/library/items/:id/studio", params: { id: ITEM_ID_REGEX } },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: noInput,
    ai: { tier: "hidden", summary: "Reopen a library file in the studio (POST /library/items/<id>/studio)." },
    handler: async (ctx) => {
        const queue = ctx.query.get("queue");
        if (queue !== null && queue !== "" && !["1", "true", "0", "false"].includes(queue)) {
            throw new OpError(400, "error.library.bad_request");
        }
        const r = await libraryStudio(ctx.app(), ctx.params.id!, ctx.keyId!, queue === "1" || queue === "true");
        return { status: r.status, body: r.body };
    },
});

// The editor routes (section 31.12): keyed only, no CORS, no-store, D1 only (the renderers are only kicked).
const editRoute = (name: string, method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE", path: string, op: EditsOp) =>
    defineOp({
        name,
        route: { method, path, params: { id: EDIT_PROJECT_ID_REGEX, rid: EDIT_RENDER_ID_REGEX } },
        auth: "key",
        runs: "worker",
        cors: false,
        noStore: true,
        input: NoInput,
        http: noInput,
        ai: { tier: "hidden", summary: `The editor: ${method} ${path}.` },
        handler: async (ctx) => {
            const d = editsDeps(ctx);
            if (!d) return editOff();
            const r = await editsKeyed(d, op, ctx.request!, ctx.params, ctx.query);
            return { status: r.status, body: r.body };
        },
    });

export const EDIT_ROUTES = [
    editRoute("edits.route.list", "GET", "/edits", "list"),
    editRoute("edits.route.create", "POST", "/edits", "create"),
    editRoute("edits.route.renders", "GET", "/edits/renders", "renders"),
    editRoute("edits.route.render_get", "GET", "/edits/renders/:rid", "render_get"),
    editRoute("edits.route.render_cancel", "DELETE", "/edits/renders/:rid", "render_cancel"),
    editRoute("edits.route.get", "GET", "/edits/:id", "get"),
    editRoute("edits.route.update", "PUT", "/edits/:id", "update"),
    editRoute("edits.route.rename", "PATCH", "/edits/:id", "rename"),
    editRoute("edits.route.delete", "DELETE", "/edits/:id", "delete"),
    editRoute("edits.route.render", "POST", "/edits/:id/render", "render"),
];

// ---- the chat AI's side: finding the file -------------------------------------------------------------------------

export type FileRow = {
    id: string;
    name: string | null;
    session_id: string | null;
    role: string | null;
    item_index: number | null;
    content_type: string | null;
    bucket: string;
    kind: string;
    source: string;
    r2_key: string;
    url: string | null;
    visibility: string | null;
    duration: number | null;
    width: number | null;
    height: number | null;
    created_at: number;
    post_key: string;
};

export const FILE_SELECT = `SELECT * FROM (SELECT m.id, m.name, m.session_id, m.role, m.item_index, m.content_type, m.bucket, m.kind, m.source,
        m.r2_key, m.url, m.visibility, m.duration, m.width, m.height, m.created_at, ${POST_KEY_SQL} AS post_key
   FROM media_items m WHERE m.deleted_at IS NULL)`;

const typeOf = (f: Pick<FileRow, "content_type">) => itemTypeOf(f.content_type);
// a file the post was saved as (an item of a gallery, or the original), never something made from it
export const isSource = (f: FileRow) => f.role === "item" || (f.bucket === "originals" && (f.source === "saved" || f.source === "upload") && !f.role);

const stop = (call: string, message: string) => new OpError(400, "error.make.refused", `cobalt.${call}: ${message}`);

// A post id or a file id -> the file a make reads: the file itself, or the post's first source file of the wanted type.
// Nothing is made of a hidden post (section 37.2): the refusal the model reads, with the way out.
const hiddenStop = (call: string, what: string) => new OpError(409, "error.hidden", `cobalt.${call}: ${what}: ${HIDDEN_HINT}`);
export async function refuseHiddenPost(ctx: OpContext, call: string, postKey: string | null | undefined): Promise<void> {
    if (postKey && (await hiddenRows(ctx.db, [postKey])).get(postKey)?.state === "hidden") throw hiddenStop(call, postKey);
}

async function fileFor(ctx: OpContext, call: string, id: string, want: "video" | "photo"): Promise<FileRow> {
    const f = await fileForAny(ctx, call, id, want);
    await refuseHiddenPost(ctx, call, f.post_key);
    return f;
}

async function fileForAny(ctx: OpContext, call: string, id: string, want: "video" | "photo"): Promise<FileRow> {
    const ok = (f: FileRow) => (want === "video" ? typeOf(f) !== "photo" : typeOf(f) === "photo");
    const label = want === "video" ? "a video or gif" : "a photo";
    if (ITEM_ID_REGEX.test(id)) {
        const f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
        if (f && isSource(f) && ok(f)) return f;
        // (a post keyed by its own file's id goes on to the post's files)
        if (f && f.post_key !== id) throw stop(call, `file ${id} is not ${label} the post was saved as`);
    }
    const { results } = await ctx.db.prepare(`${FILE_SELECT} WHERE post_key = ?1 ORDER BY item_index, created_at, id`).bind(id).all<FileRow>();
    if (results.length === 0) throw stop(call, `no post or file with id ${id}`);
    const found = results.filter(isSource).find(ok);
    if (!found) throw stop(call, `post ${id} has no ${label}`);
    return found;
}

// The studio session a make of this file runs on: the file's own session while it is open (with the item's index for a
// gallery item), else null (the file must be reopened first).
async function openSessionOf(ctx: OpContext, f: FileRow): Promise<{ session: SessionRow; item?: number } | null> {
    if (!f.session_id || !STUDIO_SID_REGEX.test(f.session_id)) return null;
    const s = await getSession(ctx.db, f.session_id);
    if (!s || s.status !== "ready" || s.expires_at <= ctx.now()) return null;
    if (f.role === "item" && typeof f.item_index === "number") return { session: s, item: f.item_index };
    return s.r2_key === f.r2_key ? { session: s } : null;
}

// Reopen a library file as a new studio session (POST /library/items/<id>/studio with the chat's key id, joining the line).
async function reopen(ctx: OpContext, call: string, f: FileRow): Promise<string> {
    const r = await libraryStudio(ctx.app(), f.id, ctx.keyId!, true);
    const b = r.body as { id?: unknown; error?: { code?: unknown } };
    if ((r.status === 200 || r.status === 201) && typeof b.id === "string") return b.id;
    const code = typeof b.error?.code === "string" ? b.error.code : "error.api.generic";
    throw new OpError(r.status, code, `cobalt.${call}: could not open the file (${code})`);
}

// A session's state, advancing a save for up to `wait` seconds (GET /studio/<sid>?wait=N, section 2).
async function sessionState(ctx: OpContext, sid: string, wait: number): Promise<{ status: string; code: string | null }> {
    const res = await studioStatus(ctx.db, ctx.container, sid, wait, ctx.edge);
    const b = (await res.json().catch(() => null)) as { status?: unknown; error?: { code?: unknown }; error_code?: unknown } | null;
    const status = typeof b?.status === "string" ? b.status : "error";
    const code = typeof b?.error?.code === "string" ? b.error.code : typeof b?.error_code === "string" ? b.error_code : null;
    return { status, code };
}

// ---- jobs ---------------------------------------------------------------------------------------------------------

// A job id the model holds:
//   studio:<sid>:<job>  a webp render, slideshow, still or gallery image (polled through the Durable Object)
//   edit:<rid>          an editor render (D1)
//   open:<sid>:<plan>   a file still opening; the plan (base64url JSON) starts when it is ready. Starting takes a unit of the
//                       cap then, so a made-up plan id cannot get around it.
type Plan = { route: "render" | "slideshow" | "gallery-image"; body: Record<string, unknown> };

// (plans are ASCII JSON: numbers, enums and ids)
const b64url = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (s: string) => atob(s.replace(/-/g, "+").replace(/_/g, "/"));

export const JobSchema = z
    .object({
        job: z.string().describe("pass it to cobalt.jobs.onDone; it can change while a file opens, so keep the newest"),
        status: z.enum(["opening", "queued", "running", "done", "error", "cancelled"]),
        progress: z.number().nullable().optional().describe("0..1 while running, when known"),
        queue_ahead: z.number().nullable().optional().describe("jobs ahead of it in the line"),
        error: z.string().optional().describe("the error code when status is error"),
        file_id: z.string().optional().describe("done: the made file's id"),
        post_id: z.string().optional().describe("done: the post it is in (use with library.post, show)"),
        kind: z.enum(["video", "image"]).optional(),
        bytes: z.number().nullable().optional(),
        width: z.number().nullable().optional(),
        height: z.number().nullable().optional(),
        seconds: z.number().nullable().optional(),
        public: z.boolean().optional(),
        share_url: z.string().nullable().optional().describe("done and public: the link to give Harmony"),
        // a sub-agent's job, agent:<id> (section 43.4)
        agent: z.string().optional().describe("agent jobs: the sub-agent's id"),
        name: z.string().optional().describe("agent jobs: its name"),
        activity: z.string().nullable().optional().describe("agent jobs while running: the call it made last"),
        result: z.string().optional().describe("agent jobs that ended: its report"),
        post_ids: z.array(z.string()).optional().describe("agent jobs that ended: the posts it showed"),
    })
    .meta({ id: "Job" });
type Job = z.infer<typeof JobSchema>;

export const rendersCap = (ctx: OpContext) => dailyCap(ctx.env.CHAT_DAILY_RENDERS, CHAT_DAILY_RENDERS_DEFAULT);

function threadOf(ctx: OpContext, call: string): string {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", `cobalt.${call}: only the chat can call this`);
    // a sub-agent uses its parent's caps and box (section 43.7)
    return capThreadOf(ctx.chat);
}

// One unit of today's render cap for this thread, or a refusal the model can read.
async function takeRender(ctx: OpContext, call: string): Promise<void> {
    const cap = rendersCap(ctx);
    if (!(await budgetPort(ctx.container).take(threadOf(ctx, call), "renders", cap))) {
        throw new OpError(429, "error.chat.render_cap", `cobalt.${call}: this chat already made ${cap} files today, the most it may make in a day. Tell Harmony it can make more tomorrow.`);
    }
}
const refundRender = (ctx: OpContext, call: string) => budgetPort(ctx.container).refund(threadOf(ctx, call), "renders");

// Start a studio make (render, slideshow, gallery image) on an open session. The keyed ones run as the session's owner:
// the chat is Harmony's own, and the Durable Object only lets the key that made a session add to it.
async function startStudio(ctx: OpContext, call: string, sid: string, plan: Plan): Promise<Job> {
    const session = await getSession(ctx.db, sid);
    await refuseHiddenPost(ctx, call, session ? sessionPostKey(sid, session.link) : null);
    await takeRender(ctx, call);
    let res: Response;
    try {
        const headers: Record<string, string> = { "content-type": "application/json" };
        if (plan.route !== "render") {
            const s = await getSession(ctx.db, sid);
            headers[KEY_ID_HEADER] = s?.key_id ?? ctx.keyId ?? "";
        }
        res = await ctx.container.fetch(
            new Request(`https://do.internal/studio/${sid}/${plan.route}`, { method: "POST", headers, body: JSON.stringify({ ...plan.body, queue: true }) }),
        );
    } catch (e) {
        await refundRender(ctx, call);
        throw e;
    }
    const b = (await res.json().catch(() => null)) as { status?: unknown; job?: unknown; queued?: unknown; queue_ahead?: unknown; error?: { code?: unknown } } | null;
    if (res.status !== 202 || typeof b?.job !== "string") {
        await refundRender(ctx, call);
        const code = typeof b?.error?.code === "string" ? b.error.code : "error.api.generic";
        if (code === "error.hidden") throw hiddenStop(call, sid);
        throw new OpError(res.status, code, `cobalt.${call} failed: ${code}`);
    }
    return { job: `studio:${sid}:${b.job}`, status: b.queued === true ? "queued" : "running", queue_ahead: typeof b.queue_ahead === "number" ? b.queue_ahead : null };
}

// Where a make on one file runs: `item` is the gallery item's index on the gallery's own session, or on a reopened
// photo of a gallery (18.14); `reopened` is a new session of that one file.
type At = { item?: number; reopened: boolean };

// A make on one file: on its open session now, or after reopening it (the job then starts in cobalt.jobs.wait).
async function makeOnFile(ctx: OpContext, call: string, f: FileRow, plan: (at: At) => Plan): Promise<Job> {
    threadOf(ctx, call);
    const open = await openSessionOf(ctx, f);
    if (open) return startStudio(ctx, call, open.session.id, plan({ item: open.item, reopened: false }));
    const sid = await reopen(ctx, call, f);
    const p = plan({ item: f.role === "item" && typeof f.item_index === "number" ? f.item_index : undefined, reopened: true });
    const state = await sessionState(ctx, sid, 8);
    if (state.status === "ready") return startStudio(ctx, call, sid, p);
    if (state.status === "error") throw new OpError(409, state.code ?? "error.studio.failed", `cobalt.${call}: the file did not open (${state.code ?? "error"})`);
    return { job: `open:${sid}:${b64url(JSON.stringify(p))}`, status: "opening" };
}

// What the model gets about a made file.
async function fileReport(ctx: OpContext, id: string): Promise<Partial<Job>> {
    const f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
    if (!f) return { file_id: id };
    const pub = effectiveVisibility(f) === "public" && !!f.url;
    const name = pub ? (/\/([A-Za-z0-9]{6,40})\.[A-Za-z0-9]{1,8}$/.exec(f.url!)?.[1] ?? null) : null;
    const share = ctx.shareBaseUrl ? (ctx.shareBaseUrl.endsWith("/") ? ctx.shareBaseUrl : `${ctx.shareBaseUrl}/`) : null;
    return {
        file_id: f.id,
        post_id: f.post_key,
        kind: (f.content_type ?? "").startsWith("video/") ? "video" : "image",
        public: pub,
        share_url: share && name ? `${share}${name}` : null,
    };
}

const remaining = (ctx: OpContext, deadline: number) => Math.max(0, Math.floor((deadline - ctx.now()) / 1000));

async function waitStudio(ctx: OpContext, sid: string, job: string, deadline: number): Promise<Job> {
    const id = `studio:${sid}:${job}`;
    for (let i = 0; i < 40; i++) {
        const wait = Math.min(10, remaining(ctx, deadline));
        const res = await ctx.container.fetch(new Request(`https://do.internal/studio/${sid}/render/${job}?wait=${wait}`));
        const b = (await res.json().catch(() => null)) as Record<string, any> | null;
        if (b?.status === "success") {
            // a slideshow or gallery image names its row; a webp render is found by its public URL
            let itemId: string | null = typeof b.item_id === "string" ? b.item_id : null;
            if (!itemId && typeof b.url === "string") {
                itemId = (await ctx.db.prepare("SELECT id FROM media_items WHERE url = ?1 AND deleted_at IS NULL LIMIT 1").bind(b.url).first<{ id: string }>())?.id ?? null;
            }
            const num = (v: unknown) => (typeof v === "number" ? v : null);
            return {
                job: id,
                status: "done",
                bytes: num(b.bytes),
                width: num(b.width),
                height: num(b.height),
                seconds: num(b.seconds),
                ...(itemId ? await fileReport(ctx, itemId) : {}),
            };
        }
        if (b?.status === "error" || res.status >= 400) {
            const code = typeof b?.error?.code === "string" ? b.error.code : "error.api.generic";
            return { job: id, status: code === "error.studio.cancelled" ? "cancelled" : "error", error: code };
        }
        const frames = typeof b?.frames_total === "number" && b.frames_total > 0 && typeof b.frames_done === "number" ? b.frames_done / b.frames_total : null;
        const pending: Job = {
            job: id,
            status: b?.phase === "queued" ? "queued" : "running",
            progress: frames === null ? null : Math.round(frames * 100) / 100,
            queue_ahead: typeof b?.queue_ahead === "number" ? b.queue_ahead : null,
        };
        if (remaining(ctx, deadline) <= 0) return pending;
        if (wait === 0) await ctx.edge.sleep(1000);
    }
    return { job: id, status: "running" };
}

async function waitEdit(ctx: OpContext, rid: string, deadline: number): Promise<Job> {
    const id = `edit:${rid}`;
    const d = editsDeps(ctx);
    if (!d) return { job: id, status: "error", error: "error.edit.off" };
    for (let i = 0; i < 40; i++) {
        const r = await editsKeyed(d, "render_get", new Request("https://do.internal/edits"), { rid }, new URLSearchParams());
        if (r.status !== 200) return { job: id, status: "error", error: (r.body as any)?.error?.code ?? "error.api.generic" };
        const render = (r.body as { render: Record<string, any> }).render;
        if (render.status === "done") {
            return {
                job: id,
                status: "done",
                bytes: render.bytes ?? null,
                width: render.width ?? null,
                height: render.height ?? null,
                seconds: render.duration ?? null,
                ...(typeof render.item_id === "string" ? await fileReport(ctx, render.item_id) : {}),
            };
        }
        if (render.status === "error") return { job: id, status: "error", error: render.error ?? "error.edit.render_failed" };
        if (render.status === "cancelled") return { job: id, status: "cancelled" };
        const pending: Job = { job: id, status: render.status === "queued" ? "queued" : "running", progress: render.progress ?? null, queue_ahead: render.queue_ahead ?? null };
        if (remaining(ctx, deadline) <= 0) return pending;
        await ctx.edge.sleep(Math.min(3000, Math.max(0, deadline - ctx.now())));
    }
    return { job: id, status: "running" };
}

// A sub-agent (section 43.4): only its parent and its siblings may wait on it. Read from D1 every 2 s.
async function waitAgent(ctx: OpContext, id: string, deadline: number): Promise<Job> {
    const parent = ctx.chat ? capThreadOf(ctx.chat) : null;
    for (;;) {
        const row = await agentRow(ctx.db, id).catch((e) => (isMissingTable(e) ? null : Promise.reject(e)));
        if (!row || row.parent !== parent) throw stop("jobs.wait", `agent:${id} is not one of this chat's sub-agents`);
        const state = agentJobState(row) as Job;
        if (state.status !== "queued" && state.status !== "running") return state;
        if (remaining(ctx, deadline) <= 0) return state;
        await ctx.edge.sleep(Math.min(2000, Math.max(0, deadline - ctx.now())));
    }
}

// A job's state after waiting up to `seconds` (0: right now). The chat's job watcher (chat-jobs.ts) reads it too.
export async function waitJob(ctx: OpContext, job: string, seconds: number): Promise<Job> {
    const deadline = ctx.now() + seconds * 1000;
    const studio = /^studio:([A-Za-z0-9]{22}):([A-Za-z0-9]{20})$/.exec(job);
    if (studio) return waitStudio(ctx, studio[1]!, studio[2]!, deadline);
    const edit = /^edit:([A-Za-z0-9]{20})$/.exec(job);
    if (edit) return waitEdit(ctx, edit[1]!, deadline);
    const agent = AGENT_JOB_REGEX.exec(job);
    if (agent) return waitAgent(ctx, agent[1]!, deadline);
    const open = /^open:([A-Za-z0-9]{22}):([A-Za-z0-9_-]{1,4000})$/.exec(job);
    if (open) {
        let plan: Plan;
        try {
            plan = JSON.parse(unb64url(open[2]!)) as Plan;
            if (!["render", "slideshow", "gallery-image"].includes(plan.route) || !plan.body || typeof plan.body !== "object") throw new Error("bad plan");
        } catch {
            throw stop("jobs.wait", `${job} is not a job id`);
        }
        const sid = open[1]!;
        for (let i = 0; i < 10; i++) {
            const state = await sessionState(ctx, sid, Math.min(10, remaining(ctx, deadline)));
            if (state.status === "ready") {
                const started = await startStudio(ctx, "jobs.wait", sid, plan);
                const m = /^studio:([A-Za-z0-9]{22}):([A-Za-z0-9]{20})$/.exec(started.job)!;
                return remaining(ctx, deadline) > 0 ? waitStudio(ctx, m[1]!, m[2]!, deadline) : started;
            }
            if (state.status === "error") return { job, status: "error", error: state.code ?? "error.studio.failed" };
            if (remaining(ctx, deadline) <= 0) break;
        }
        return { job, status: "opening" };
    }
    throw stop("jobs.wait", `${job} is not a job id`);
}

// ---- the chat AI's calls ------------------------------------------------------------------------------------------

const Id = z.string().min(1).max(2048).describe("a post id, or one file's id from library.post");
const Quality = z.enum(["low", "med", "high"]);
const CropSchema = z
    .object({
        x: z.number().min(0).max(1),
        y: z.number().min(0).max(1),
        w: z.number().gt(0).max(1),
        h: z.number().gt(0).max(1),
    })
    .describe("fractions of the picture: left, top, width, height");

const fail = (call: string, e: unknown): never => {
    throw e instanceof OpError ? e : new OpError(503, "error.api.generic", `cobalt.${call} failed: ${e instanceof Error ? e.message : String(e)}`);
};

export const makeWebpOp = defineOp({
    name: "make.webp",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: Id,
        start: z.number().min(0).describe("seconds into the video"),
        end: z.number().gt(0).describe("seconds; at most 10 s after start"),
        crop: CropSchema.optional(),
        width: z.union([z.literal(320), z.literal(480)]).optional().describe("default 480"),
        quality: Quality.optional().describe("default med"),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary: "An animated webp (silent, loops) of 0.5 to 10 s of a video or gif, optionally cropped. Returns a job: hand it to jobs.onDone.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "make.webp";
        const length = Math.round((input.end - input.start) * 1000) / 1000;
        if (length < 0.5 || length > 10) throw stop(call, "a webp is 0.5 to 10 s long (end - start)");
        const f = await fileFor(ctx, call, input.id, "video");
        const body = { start: input.start, length, width: input.width ?? 480, quality: input.quality ?? "med", ...(input.crop ? { crop: input.crop } : {}) };
        // a reopened item is its session's lead: `item` only on the gallery's own session (18.13)
        const plan = (at: At): Plan => ({ route: "render", body: at.item === undefined || at.reopened ? body : { ...body, item: at.item } });
        return ok(await makeOnFile(ctx, call, f, plan).catch((e) => fail(call, e)));
    },
});

export const makeStillOp = defineOp({
    name: "make.still",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: Id,
        seconds: z.number().min(0.5).max(15).optional().describe("how long it shows, default 2"),
        width: z.union([z.literal(320), z.literal(480), z.literal(640)]).optional().describe("default 640"),
        quality: Quality.optional(),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary: "An animated webp of one photo (looks still), so Discord lets people favourite it. Returns a job.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "make.still";
        const f = await fileFor(ctx, call, input.id, "photo");
        if (!STILL_ADOPT_TYPES.has(f.content_type ?? "")) throw stop(call, "only jpeg, png and webp photos can be made animated");
        const seconds = Math.round((input.seconds ?? 2) * 10) / 10;
        // a lone photo is item 0 of its session; a gallery's photo keeps its index, reopened or not (18.14)
        const plan = (at: At): Plan => ({
            route: "slideshow",
            body: { items: [at.item ?? 0], seconds: [seconds], format: "webp", width: input.width ?? 640, quality: input.quality ?? "med" },
        });
        return ok(await makeOnFile(ctx, call, f, plan).catch((e) => fail(call, e)));
    },
});

// The gallery a slideshow or gallery image is made from: its open session and its live items.
async function galleryOf(ctx: OpContext, call: string, id: string, fileIds: string[] | undefined) {
    let post = id;
    if (ITEM_ID_REGEX.test(id)) {
        const f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
        if (f) post = f.post_key;
    }
    const { results } = await ctx.db.prepare(`${FILE_SELECT} WHERE post_key = ?1 AND role = 'item' ORDER BY item_index, id`).bind(post).all<FileRow>();
    if (results.length < 2) throw stop(call, `post ${id} is not a gallery (it needs 2 or more items)`);
    const sid = results[0]!.session_id;
    const session = sid ? await getSession(ctx.db, sid) : null;
    if (!session || session.status !== "ready") throw stop(call, "this gallery's studio session is gone, so nothing can be made from it");
    if (session.expires_at <= ctx.now()) throw stop(call, "galleries can only be made into slideshows and gallery images within 7 days of saving");
    let items = results;
    if (fileIds && fileIds.length > 0) {
        items = fileIds.map((fid) => {
            const f = results.find((r) => r.id === fid);
            if (!f) throw stop(call, `file ${fid} is not an item of this gallery`);
            return f;
        });
    }
    return { sid: session.id, items };
}

export const makeSlideshowOp = defineOp({
    name: "make.slideshow",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: Id.describe("a gallery post's id"),
        items: z.array(z.string()).max(20).optional().describe("file ids from library.post, in play order (default: every item)"),
        seconds: z.number().min(0.5).max(15).optional().describe("seconds per photo, default 2 (videos play their own length)"),
        format: z.enum(["mp4", "webp"]).optional().describe("default mp4; a webp is silent and at most 60 s"),
        fade: z.boolean().optional(),
        frame: z.enum(["keep", "9:16", "1:1"]).optional(),
        sound: z.enum(["none", "own"]).optional().describe("mp4 only: the videos' own sound"),
        width: z.union([z.literal(320), z.literal(480)]).optional().describe("webp only"),
        quality: Quality.optional().describe("webp only"),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary: "A slideshow of a gallery's items (2 to 20). Only for galleries saved in the last 7 days. Returns a job.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "make.slideshow";
        threadOf(ctx, call);
        const g = await galleryOf(ctx, call, input.id, input.items);
        if (g.items.length < 2) throw stop(call, "a slideshow needs 2 or more items");
        const webp = input.format === "webp";
        const per = Math.round((input.seconds ?? 2) * 10) / 10;
        const body: Record<string, unknown> = {
            items: g.items.map((f) => f.item_index),
            seconds: g.items.map((f) => (typeOf(f) === "photo" ? per : null)),
            format: input.format ?? "mp4",
            ...(input.fade !== undefined ? { fade: input.fade } : {}),
            ...(input.frame ? { frame: input.frame } : {}),
            ...(input.sound && !webp ? { sound: input.sound } : {}),
            ...(webp ? { width: input.width ?? 480, quality: input.quality ?? "med" } : {}),
        };
        return ok(await startStudio(ctx, call, g.sid, { route: "slideshow", body }).catch((e) => fail(call, e)));
    },
});

export const makeGalleryImageOp = defineOp({
    name: "make.galleryImage",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: Id.describe("a gallery post's id"),
        layout: z.enum(["strip", "grid2", "grid3", "row"]).optional().describe("default grid2"),
        items: z.array(z.string()).max(20).optional().describe("photo file ids in drawing order (default: every photo)"),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary: "One jpeg of a gallery's photos (2 to 20) side by side or in a grid. Only for galleries saved in the last 7 days. Returns a job.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const call = "make.galleryImage";
        threadOf(ctx, call);
        const g = await galleryOf(ctx, call, input.id, input.items);
        const photos = g.items.filter((f) => typeOf(f) === "photo");
        if (input.items && photos.length !== g.items.length) throw stop(call, "a gallery image takes photos only");
        if (photos.length < 2) throw stop(call, "a gallery image needs 2 or more photos");
        const body = { items: photos.map((f) => f.item_index), layout: input.layout ?? "grid2" };
        return ok(await startStudio(ctx, call, g.sid, { route: "gallery-image", body }).catch((e) => fail(call, e)));
    },
});

// ---- the editor from chat -----------------------------------------------------------------------------------------

// One editor route for the chat, with the chat's key id; a refusal says the code and the field.
export async function editCall(ctx: OpContext, call: string, op: EditsOp, params: Record<string, string>, body?: unknown): Promise<Record<string, any>> {
    const d = editsDeps(ctx);
    if (!d) throw new OpError(404, "error.edit.off", `cobalt.${call}: the editor is off on this server`);
    const req = new Request("https://do.internal/edits", {
        method: body === undefined ? "GET" : "POST",
        ...(body === undefined ? {} : { body: JSON.stringify(body), headers: { "content-type": "application/json" } }),
    });
    const r = await editsKeyed(d, op, req, params, new URLSearchParams());
    const b = r.body as Record<string, any>;
    if (r.status < 200 || r.status > 299) {
        const code = typeof b?.error?.code === "string" ? b.error.code : "error.api.generic";
        const where = typeof b?.path === "string" && b.path ? ` at ${b.path}` : "";
        const items = Array.isArray(b?.items) && b.items.length ? ` (files ${b.items.join(", ")})` : "";
        throw new OpError(r.status, code, `cobalt.${call}: ${code}${where}${items}`);
    }
    return b;
}

// Start a render of the project's current revision: one unit of the cap (taken here unless the caller already took it),
// given back when nothing new started.
async function renderProject(ctx: OpContext, call: string, projectId: string, taken = false): Promise<Job> {
    let got: Record<string, any>;
    try {
        got = await editCall(ctx, call, "get", { id: projectId });
    } catch (e) {
        if (taken) await refundRender(ctx, call);
        throw e;
    }
    if (!taken) await takeRender(ctx, call);
    let r: Record<string, any>;
    try {
        const d = editsDeps(ctx)!;
        const reply = await editsKeyed(
            d,
            "render",
            new Request("https://do.internal/edits", { method: "POST", body: JSON.stringify({ revision: got.project.revision }), headers: { "content-type": "application/json" } }),
            { id: projectId },
            new URLSearchParams(),
        );
        r = reply.body as Record<string, any>;
        if (reply.status !== 202) {
            await refundRender(ctx, call);
            if (reply.status === 200 && r.render) return { job: `edit:${r.render.id}`, status: r.render.status === "queued" ? "queued" : "running" };
            const code = typeof r?.error?.code === "string" ? r.error.code : "error.api.generic";
            if (code === "error.hidden") throw hiddenStop(call, Array.isArray(r.ids) ? r.ids.join(", ") : projectId);
            const where = typeof r?.path === "string" && r.path ? ` at ${r.path}` : "";
            throw new OpError(reply.status, code, `cobalt.${call}: ${code}${where}`);
        }
    } catch (e) {
        if (!(e instanceof OpError)) await refundRender(ctx, call);
        throw e;
    }
    return { job: `edit:${r.render.id}`, status: "queued", queue_ahead: r.render.queue_ahead ?? null };
}

// The editor validator (section 31.3), wrapped: the model reads the same code and field the app gets.
const TimelineInput = z
    .unknown()
    .superRefine((v, c) => {
        const p = parseEditTimeline(v);
        if (!p.ok) c.addIssue({ code: "custom", message: `${p.code} at ${p.path}` });
    })
    .meta({ ts: "Timeline" });

const TIMELINE_TYPE = `type Timeline = { version: 1; canvas: { w, h, fps: 30 | 60 } (w x h: 1080x1920, 720x1280, 1080x1080, 720x720, 1920x1080, 1280x720);
  main: { id: string /* unique, letters */; item: string /* a video file id */; in: number; out: number /* source seconds */; speed: number /* 0.25..4 */;
          crop?: { aspect: "free"; x; y; w; h } /* fractions */; fit: "fill" | "fit"; volume: number /* 0..1 */; muted: boolean; pitch?: number /* semitones -12..12 */ }[];
  overlay: { id; item /* a video, gif, photo, webp (7TV emotes too) or cutout file id */; at: number /* output seconds */; in; out /* video: source seconds; picture: in 0, out = seconds shown */;
             frame: { x; y; w } /* top-left + width, canvas fractions; height follows the picture */; opacity: number; volume; muted; track?: number /* layer 0..7, higher on top */ }[] }
  // overlay[] sorted by at; overlays on one track never overlap, on different tracks they may (stack stickers, several videos at once).
  // Adding one overlay to an existing project: edits.addOverlay is simpler.`;

export const ProjectSchema = z.object({ id: z.string(), title: z.string(), revision: z.number(), duration: z.number(), render: z.unknown().nullable() }).meta({ id: "EditProject" });
export const projectOf = (p: Record<string, any>) => ({ id: p.id, title: p.title, revision: p.revision, duration: p.duration, render: p.render ?? null });

// The canvas for one clip, by the shape of what it shows (31.2.1), 1080p 30 fps.
function canvasFor(w: number | null, h: number | null, shape?: "9:16" | "1:1" | "16:9") {
    const s = shape ?? (!w || !h ? "9:16" : h > 1.1 * w ? "9:16" : w > 1.1 * h ? "16:9" : "1:1");
    return s === "9:16" ? { w: 1080, h: 1920, fps: 30 } : s === "16:9" ? { w: 1920, h: 1080, fps: 30 } : { w: 1080, h: 1080, fps: 30 };
}

const titleFor = (f: FileRow, what: string) => {
    const base = (f.name ?? "").replace(/\.[A-Za-z0-9]{1,5}$/, "").replace(/[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g, "").trim();
    return base ? `${[...base].slice(0, 60).join("")} ${what}` : what;
};

const r3 = (n: number) => Math.round(n * 1000) / 1000;

// trim and crop: a one-clip edit rendered to an mp4 (the editor's container; each one costs real money).
async function oneClip(
    ctx: OpContext,
    call: string,
    input: { id: string; start?: number; end?: number; crop?: { x: number; y: number; w: number; h: number }; fit?: "fill" | "fit"; canvas?: "9:16" | "1:1" | "16:9"; title?: string },
    what: string,
): Promise<Job & { project_id: string }> {
    threadOf(ctx, call);
    const f = await fileFor(ctx, call, input.id, "video");
    if (typeOf(f) !== "video") throw stop(call, "the editor takes videos only (a gif can be made into a webp)");
    const start = input.start ?? 0;
    const end = input.end ?? f.duration;
    if (end === null || end === undefined) throw stop(call, "this video's length is unknown: give end");
    if (!(end > start)) throw stop(call, "end must be after start");
    if (f.duration !== null && end > f.duration + 0.05) throw stop(call, `the video is ${f.duration} s long`);
    const cw = input.crop && f.width ? input.crop.w * f.width : f.width;
    const ch = input.crop && f.height ? input.crop.h * f.height : f.height;
    const timeline = {
        version: 1,
        canvas: canvasFor(cw, ch, input.canvas),
        main: [
            {
                id: "c1",
                item: f.id,
                in: r3(start),
                out: r3(end),
                speed: 1,
                ...(input.crop ? { crop: { aspect: "free", x: input.crop.x, y: input.crop.y, w: input.crop.w, h: input.crop.h } } : {}),
                fit: input.fit ?? "fit",
                volume: 1,
                muted: false,
            },
        ],
        overlay: [],
    };
    // the cap first, so a refused trim leaves no project behind
    await takeRender(ctx, call);
    let created: Record<string, any>;
    try {
        created = await editCall(ctx, call, "create", {}, { title: input.title ?? titleFor(f, what), timeline });
    } catch (e) {
        await refundRender(ctx, call);
        throw e;
    }
    try {
        const job = await renderProject(ctx, call, created.project.id, true);
        return { ...job, project_id: created.project.id };
    } catch (e) {
        // a one-clip edit that cannot render is not kept in the editor's list
        await editCall(ctx, call, "delete", { id: created.project.id }).catch(() => {});
        throw e;
    }
}

const ClipOpts = {
    fit: z.enum(["fill", "fit"]).optional().describe('default "fit" (the whole picture, bars if needed)'),
    canvas: z.enum(["9:16", "1:1", "16:9"]).optional().describe("default: the shape of the picture"),
    title: z.string().min(1).max(80).optional(),
};
const OneClipJob = z.intersection(JobSchema, z.object({ project_id: z.string() }));

export const makeTrimOp = defineOp({
    name: "make.trim",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: Id, start: z.number().min(0).describe("seconds"), end: z.number().gt(0).describe("seconds"), ...ClipOpts }),
    output: OneClipJob,
    ai: {
        tier: "free",
        only: true,
        summary: "A new mp4 of part of a video (made by the editor). Returns a job and the edit project's id.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => ok(await oneClip(ctx, "make.trim", input, "trim").catch((e) => fail("make.trim", e))),
});

export const makeCropOp = defineOp({
    name: "make.crop",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: Id,
        crop: CropSchema,
        start: z.number().min(0).optional().describe("seconds, default 0"),
        end: z.number().gt(0).optional().describe("seconds, default the end"),
        ...ClipOpts,
    }),
    output: OneClipJob,
    ai: {
        tier: "free",
        only: true,
        summary: "A new mp4 of a video cropped to part of the picture (and trimmed if start/end are given), one fixed box for the whole clip. Look at its frames with a grid and check the box with look({ box }) first; never guess the centre. Returns a job and the edit project's id. Pictures: make.cropImage.",
        params: ["id", "crop"],
        options: true,
    },
    handler: async (ctx, input) => {
        // a picture is cropped by make.cropImage (section 44.2)
        const { results: rows } = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1 OR post_key = ?1`).bind(input.id).all<FileRow>();
        const still = (f: FileRow) => String(f.content_type ?? "").startsWith("image/") && f.content_type !== "image/gif";
        const exact = rows.find((f) => f.id === input.id && f.post_key !== input.id);
        if (exact ? still(exact) : rows.length > 0 && rows.every(still)) {
            throw stop("make.crop", "that is a picture: crop pictures with make.cropImage (make.crop is for videos)");
        }
        return ok(await oneClip(ctx, "make.crop", input, "crop").catch((e) => fail("make.crop", e)));
    },
});

export const editsListOp = defineOp({
    name: "edits.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.array(ProjectSchema),
    ai: { tier: "free", only: true, summary: "The editor's projects, most recently changed first." },
    handler: async (ctx) => ok(((await editCall(ctx, "edits.list", "list", {})).projects as Record<string, any>[]).map(projectOf)),
});

export const editsGetOp = defineOp({
    name: "edits.get",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(EDIT_PROJECT_ID_REGEX, "an edit project id") }),
    output: z.intersection(
        ProjectSchema,
        z.object({
            timeline: z.unknown().meta({ ts: "Timeline" }),
            sources: z.record(z.string(), z.unknown()).optional().describe("every file the timeline names: kind, content_type, width, height, duration, source"),
        }),
    ),
    ai: { tier: "free", only: true, summary: "One project with its timeline and the files it uses.", params: ["id"] },
    handler: async (ctx, input) => {
        const b = await editCall(ctx, "edits.get", "get", { id: input.id });
        return ok({ ...projectOf(b.project), timeline: b.project.timeline, sources: b.sources ?? {} });
    },
});

export const editsCreateOp = defineOp({
    name: "edits.create",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ timeline: TimelineInput, title: z.string().min(1).max(80).optional() }),
    output: ProjectSchema,
    ai: {
        tier: "free",
        only: true,
        summary: `A new editor project (nothing renders until edits.render). Output at most 600 s, 50 clips; main clips are videos.\n${TIMELINE_TYPE}`,
        params: ["timeline"],
        options: true,
    },
    handler: async (ctx, input) => ok(projectOf((await editCall(ctx, "edits.create", "create", {}, { timeline: input.timeline, ...(input.title ? { title: input.title } : {}) })).project)),
});

export const editsUpdateOp = defineOp({
    name: "edits.update",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(EDIT_PROJECT_ID_REGEX, "an edit project id"), timeline: TimelineInput, title: z.string().min(1).max(80).optional() }),
    output: ProjectSchema,
    ai: { tier: "free", only: true, summary: "Replace a project's timeline (and title).", params: ["id", "timeline"], options: true },
    handler: async (ctx, input) => {
        const call = "edits.update";
        const cur = (await editCall(ctx, call, "get", { id: input.id })).project;
        const body = { timeline: input.timeline, base_revision: cur.revision, ...(input.title ? { title: input.title } : {}) };
        return ok(projectOf((await editCall(ctx, call, "update", { id: input.id }, body)).project));
    },
});

export const editsRenderOp = defineOp({
    name: "edits.render",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(EDIT_PROJECT_ID_REGEX, "an edit project id") }),
    output: JobSchema,
    ai: { tier: "free", only: true, summary: "Render a project to an mp4 in the library (costs real money: only when Harmony wants it). Returns a job.", params: ["id"] },
    handler: async (ctx, input) => ok(await renderProject(ctx, "edits.render", input.id).catch((e) => fail("edits.render", e))),
});

export const editsDeleteOp = defineOp({
    name: "edits.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(EDIT_PROJECT_ID_REGEX, "an edit project id") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete an editor project (its rendered videos stay in the library).",
        params: ["id"],
        preview: async (ctx, input) => {
            const p = await editCall(ctx, "edits.delete", "get", { id: input.id });
            return { summary: `delete the edit "${p.project.title}"`, effect: { edits: 1, clips: p.project.clip_count ?? null } };
        },
    },
    handler: async (ctx, input) => {
        await editCall(ctx, "edits.delete", "delete", { id: input.id });
        return ok({ deleted: input.id });
    },
});

export const jobsWaitOp = defineOp({
    name: "jobs.wait",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        job: z.string().min(1).max(4100),
        seconds: z.number().min(0).max(JOB_WAIT_MAX_SECONDS).optional().describe(`default 15, at most ${JOB_WAIT_MAX_SECONDS}`),
    }),
    output: JobSchema,
    ai: {
        tier: "free",
        only: true,
        summary: `A quick look at a job: waits up to \`seconds\`, then its state. Never call it again in later runs to poll: hand a job that is still going to jobs.onDone instead.`,
        params: ["job", "seconds"],
    },
    handler: async (ctx, input) => {
        threadOf(ctx, "jobs.wait");
        return ok(await waitJob(ctx, input.job, input.seconds ?? 15).catch((e) => fail("jobs.wait", e)));
    },
});

// cobalt.jobs.onDone(job, note?) (section 33.14): the server hook. A job that ends within a few seconds answers at once;
// otherwise the chat's job watcher (the ChatJobs Durable Object) takes it, the model ends its reply, and the server
// continues the chat with the result when the job ends. Never a route.
export const JOB_ONDONE_FIRST_WAIT_S = 8;
export const jobsOnDoneOp = defineOp({
    name: "jobs.onDone",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        job: z.string().min(1).max(4100),
        note: z.string().max(300).optional().describe("what to do with the result, e.g. \"show it and give the share link\""),
    }),
    output: JobSchema.extend({ watching: z.boolean().optional().describe("true: the server continues the chat when it ends; end your reply now") }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "Hand a job to the server: it tells you when the job ends, with the result. Done within a few seconds: the result at once. Otherwise `watching: true`: end your reply in one short line (it is on its way); a new reply starts by itself when the job ends.",
        params: ["job", "note"],
    },
    handler: async (ctx, input) => {
        threadOf(ctx, "jobs.onDone");
        const state = await waitJob(ctx, input.job, JOB_ONDONE_FIRST_WAIT_S).catch((e) => fail("jobs.onDone", e));
        if (["done", "error", "cancelled"].includes(state.status)) return ok(state);
        const watch = ctx.chat?.watchJob;
        if (!watch) return ok(state);
        await watch(state.job, input.note ?? null).catch((e) => fail("jobs.onDone", e));
        return ok({ ...state, watching: true });
    },
});

export const MAKE_OPS = [
    studioRenderRoute,
    studioRenderStatusRoute,
    studioSlideshowRoute,
    studioGalleryImageRoute,
    libraryReopenRoute,
    ...EDIT_ROUTES,
    makeWebpOp,
    makeStillOp,
    makeTrimOp,
    makeCropOp,
    makeSlideshowOp,
    makeGalleryImageOp,
    editsListOp,
    editsGetOp,
    editsCreateOp,
    editsUpdateOp,
    editsRenderOp,
    editsDeleteOp,
    jobsWaitOp,
    jobsOnDoneOp,
];
