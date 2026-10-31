// The editor's keyed routes (APP-API-CONTRACT.md section 31.12), the editor's reads for GET /queue and
// GET /capabilities (31.13), and the cron's recovery of stale renders (31.9). D1 only: the render container
// and the EditRenderer Durable Object are reached through `kick` and nothing else. No Cloudflare imports, so
// it runs under plain node in the tests.
//
// A project is a timeline (31.2) saved in `edit_projects`; a render (`edit_renders`) is one revision of it,
// queued in D1 and made into an MP4 by an EditRenderer instance (src/edit-render-core.ts).

import { raceCeiling } from "./ceiling";
import { hiddenFileIds } from "./hidden-store";
import { randomBase62 } from "./ids";
import { readCapped } from "./library";
import { cleanTitle, type StudioReply } from "./studio";
import {
    EDIT_MAX_INPUT_BYTES,
    EDIT_MAX_JSON_BYTES,
    EDIT_MAX_OUTPUT_BYTES,
    EDIT_MAX_PROJECTS,
    EDIT_QUEUE_MAX,
    canonicalJSON,
    checkSources,
    parseTimeline,
    timing,
} from "../../editor/helper/timeline.js";

// ---- the validator, as this file uses it ------------------------------------------------------------------

export type Crop = { aspect: string; x: number; y: number; w: number; h: number };
export type MainClip = { id: string; item: string; in: number; out: number; speed: number; crop?: Crop; fit: string; volume: number; muted: boolean; pitch?: number };
export type OverlayClip = {
    id: string;
    item: string;
    at: number;
    in: number;
    out: number;
    frame: { x: number; y: number; w: number };
    opacity: number;
    volume: number;
    muted: boolean;
    pitch?: number;
};
export type Timeline = { version: 1; canvas: { w: number; h: number; fps: number }; main: MainClip[]; overlay: OverlayClip[] };
export type Validation = { ok: true; timeline?: Timeline } | { ok: false; code: string; path: string; items?: string[] };

// What `checkSources` wants of a library row (31.3).
export type SourceRow = {
    id: string;
    content_type: string | null;
    source: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
    bytes: number | null;
    deleted: boolean;
};

const parse = parseTimeline as unknown as (raw: unknown) => { ok: true; timeline: Timeline } | { ok: false; code: string; path: string };
const checkRows = checkSources as unknown as (t: Timeline, rows: SourceRow[]) => Validation;
const canonical = canonicalJSON as unknown as (t: Timeline) => string;
const timingOf = timing as unknown as (t: Timeline) => { fps: number; frames: number; seconds: number };

// what edit-render-core.ts and the capability limits take from the validator, through this one import
export { EDIT_QUEUE_MAX, EDIT_MAX_PROJECTS, EDIT_MAX_OUTPUT_BYTES };
export const checkEditSources = checkRows;
export const parseEditTimeline = parse;

// ---- shapes and constants ---------------------------------------------------------------------------------

// the body of POST /edits and PUT /edits/<id> (31.12): a 64 KiB timeline plus the envelope
export const EDIT_BODY_CAP = 72 * 1024;
export const EDIT_DEFAULT_TITLE = "untitled edit";
// A claimed render nobody has written to for this long is stale (31.9).
export const EDIT_STALE_MS = 10 * 60 * 1000;
export const EDIT_RENDERS_DEFAULT = 20;
export const EDIT_RENDERS_MAX = 50;
// GET /queue lists renders that ended in this window (31.13)
export const EDIT_QUEUE_RECENT_MS = 30 * 60 * 1000;
export const EDIT_QUEUE_LIST_MAX = 20;
export const EDIT_INSTANCES = ["r0", "r1"] as const;
// each /kick call's cap (31.8)
export const EDIT_KICK_MS = 2_000;

export const ACTIVE_STATUSES = ["queued", "preparing", "rendering", "finishing"] as const;
const CLAIMED_STATUSES = ["preparing", "rendering", "finishing"] as const;

export type EditsDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    now: () => number;
    // the key id the Worker's D1 lookup found (set by the Worker, never by the client)
    keyId: string;
    // posts /kick to both EditRenderer instances (2 s cap each, errors swallowed: the cron recovers)
    kick: () => Promise<void>;
    randomBytes?: (n: number) => Uint8Array;
};

export type EditsOp =
    | "list"
    | "create"
    | "get"
    | "update"
    | "rename"
    | "delete"
    | "render"
    | "renders"
    | "render_get"
    | "render_cancel";

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});
const ok = (status: number, body: Record<string, unknown>): StudioReply => ({ status, body: { status: "success", ...body } });
const generic = () => err(503, "error.api.generic");

// The status each validation code is answered with (31.12's table).
const VALIDATION_STATUS: Record<string, number> = {
    "error.edit.bad_request": 400,
    "error.edit.canvas": 400,
    "error.edit.empty": 400,
    "error.edit.too_many_clips": 400,
    "error.edit.too_long": 400,
    "error.edit.range": 400,
    "error.edit.overlay_overlap": 400,
    "error.edit.overlay_past_end": 400,
    "error.edit.source_missing": 409,
    "error.edit.not_video": 409,
    "error.edit.unsupported_source": 409,
    "error.edit.past_source_end": 409,
    "error.edit.too_large": 413,
};

function validationReply(v: { code: string; path?: string; items?: string[] }): StudioReply {
    const status = VALIDATION_STATUS[v.code] ?? 400;
    const code = v.code in VALIDATION_STATUS ? v.code : "error.edit.bad_request";
    return {
        status,
        body: { status: "error", error: { code }, path: v.path ?? "", ...(v.items ? { items: v.items } : {}) },
    };
}
const badRequest = (path: string) => validationReply({ code: "error.edit.bad_request", path });

// ---- the migration probe (31.7) -----------------------------------------------------------------------------

// Whether migration 0021 is applied, probed with `SELECT 1 FROM edit_projects LIMIT 0` once per isolate for the
// flag. A positive answer is kept for the life of the isolate; a negative one is asked again after a minute (the
// owner applies the migration before the deploy, so this only matters for a deploy that ran first).
const probed = new WeakMap<object, { ok: boolean; at: number }>();
export const EDIT_PROBE_RETRY_MS = 60_000;

export async function editTablesPresent(db: D1Database, now: number = Date.now()): Promise<boolean> {
    const known = probed.get(db);
    if (known && (known.ok || now - known.at < EDIT_PROBE_RETRY_MS)) return known.ok;
    let present = false;
    try {
        await db.prepare("SELECT 1 FROM edit_projects LIMIT 0").all();
        await db.prepare("SELECT 1 FROM edit_renders LIMIT 0").all();
        present = true;
    } catch (e) {
        // Only a missing table means "not applied". Any other D1 error is a blip: answer false for this call, remember nothing.
        if (!/no such table/i.test(e instanceof Error ? e.message : String(e))) return known?.ok ?? false;
        present = false;
    }
    probed.set(db, { ok: present, at: now });
    return present;
}

// ---- kicking the renderers -----------------------------------------------------------------------------------

// The slice of a Durable Object namespace the kick needs.
export type RendererNamespace = {
    idFromName(name: string): unknown;
    get(id: any): { fetch(request: Request): Promise<Response> };
};

// POST https://edit.internal/kick to r0 and r1 at once, each capped at EDIT_KICK_MS and each failure swallowed
// (the 15-minute cron kicks again). The kick only arms the instance's tick and answers 202 (edit-renderer.ts).
export function kickRenderers(ns: RendererNamespace | undefined, ms: number = EDIT_KICK_MS): () => Promise<void> {
    return async () => {
        if (!ns) return;
        await Promise.all(
            EDIT_INSTANCES.map(async (name) => {
                try {
                    const stub = ns.get(ns.idFromName(name));
                    const res = await raceCeiling(stub.fetch(new Request("https://edit.internal/kick", { method: "POST", headers: { "x-edit-instance": name } })), ms, "edit kick");
                    await res.body?.cancel().catch(() => {});
                } catch (e) {
                    console.error("[edits] kick failed", name, e instanceof Error ? e.name : "error");
                }
            }),
        );
    };
}

// ---- rows -----------------------------------------------------------------------------------------------------

type ProjectRow = {
    id: string;
    title: string;
    timeline: string;
    revision: number;
    canvas_w: number;
    canvas_h: number;
    fps: number;
    frames: number;
    clip_count: number;
    cover_item: string | null;
    created_at: number;
    updated_at: number;
};

export type RenderRow = {
    id: string;
    // 'edit' | 'chat' (section 45, migration 0028)
    kind?: string | null;
    thread_id?: string | null;
    project_id: string;
    revision: number;
    title: string;
    status: string;
    cancel_requested: number;
    sent_bytes: number | null;
    input_bytes: number | null;
    seconds_done: number | null;
    seconds_total: number;
    error_code: string | null;
    item_id: string | null;
    bytes: number | null;
    width: number | null;
    height: number | null;
    duration: number | null;
    created_at: number;
    started_at: number | null;
    finished_at: number | null;
    queue_ahead: number | null;
    poster: string | null;
};

// The columns of a <render> (31.12), `queue_ahead` in the claim's own order (created_at, id) and the result's poster.
// Shared by the routes and GET /queue.
export const RENDER_SELECT = `SELECT r.id, r.kind, r.thread_id, r.project_id, r.revision, r.title, r.status, r.cancel_requested, r.sent_bytes, r.input_bytes,
    r.seconds_done, r.seconds_total, r.error_code, r.item_id, r.bytes, r.width, r.height, r.duration, r.created_at, r.started_at, r.finished_at,
    (SELECT COUNT(*) FROM edit_renders q WHERE q.status = 'queued' AND q.cancel_requested = 0
        AND (q.created_at < r.created_at OR (q.created_at = r.created_at AND q.id < r.id))) AS queue_ahead,
    (SELECT m.poster FROM media_items m WHERE m.id = r.item_id AND m.deleted_at IS NULL) AS poster
  FROM edit_renders r`;

const clamp01 = (n: number) => Math.min(1, Math.max(0, n));

// 31.12: preparing = 0.1 x sent / input; rendering = 0.1 + 0.85 x done / total; finishing = 0.95; done = 1.
export function renderProgress(r: Pick<RenderRow, "status" | "sent_bytes" | "input_bytes" | "seconds_done" | "seconds_total">): number | null {
    switch (r.status) {
        case "preparing":
            return 0.1 * (r.input_bytes && r.input_bytes > 0 ? clamp01((r.sent_bytes ?? 0) / r.input_bytes) : 0);
        case "rendering":
            return 0.1 + 0.85 * (r.seconds_total > 0 ? clamp01((r.seconds_done ?? 0) / r.seconds_total) : 0);
        case "finishing":
            return 0.95;
        case "done":
            return 1;
        default:
            return null;
    }
}

export function renderShape(r: RenderRow) {
    return {
        id: r.id,
        kind: r.kind === "chat" ? "chat" : "edit",
        thread_id: r.kind === "chat" ? (r.thread_id ?? null) : null,
        project_id: r.project_id,
        revision: r.revision,
        title: r.title,
        status: r.status,
        queue_ahead: r.status === "queued" ? (r.queue_ahead ?? 0) : null,
        progress: renderProgress(r),
        seconds_done: r.seconds_done ?? null,
        seconds_total: r.seconds_total,
        error: r.error_code ?? null,
        item_id: r.item_id ?? null,
        poster_url: r.item_id ? (r.poster ?? null) : null,
        bytes: r.bytes ?? null,
        width: r.width ?? null,
        height: r.height ?? null,
        duration: r.duration ?? null,
        cancel_requested: r.cancel_requested === 1,
        created_at: r.created_at,
        started_at: r.started_at ?? null,
        finished_at: r.finished_at ?? null,
    };
}

export type RenderShape = ReturnType<typeof renderShape>;

export async function getRender(db: D1Database, rid: string): Promise<RenderRow | null> {
    return await db.prepare(`${RENDER_SELECT} WHERE r.id = ?1`).bind(rid).first<RenderRow>();
}

async function newestRender(db: D1Database, projectId: string): Promise<RenderRow | null> {
    return await db
        .prepare(`${RENDER_SELECT} WHERE r.project_id = ?1 ORDER BY r.created_at DESC, r.id DESC LIMIT 1`)
        .bind(projectId)
        .first<RenderRow>();
}

const coverUrl = async (db: D1Database, item: string | null): Promise<string | null> => {
    if (!item) return null;
    const row = await db.prepare("SELECT poster FROM media_items WHERE id = ?1 AND deleted_at IS NULL").bind(item).first<{ poster: string | null }>();
    return row?.poster ?? null;
};

function projectSummary(p: ProjectRow, cover: string | null, render: RenderRow | null) {
    return {
        id: p.id,
        title: p.title,
        revision: p.revision,
        canvas: { w: p.canvas_w, h: p.canvas_h, fps: p.fps },
        duration: p.frames / p.fps,
        clip_count: p.clip_count,
        cover_url: cover,
        created_at: p.created_at,
        updated_at: p.updated_at,
        render: render ? renderShape(render) : null,
    };
}

const projectShape = (p: ProjectRow, cover: string | null, render: RenderRow | null) => {
    const { render: r, ...rest } = projectSummary(p, cover, render);
    return { ...rest, timeline: JSON.parse(p.timeline) as Timeline, render: r };
};

async function getProjectRow(db: D1Database, id: string): Promise<ProjectRow | null> {
    return await db
        .prepare(
            "SELECT id, title, timeline, revision, canvas_w, canvas_h, fps, frames, clip_count, cover_item, created_at, updated_at FROM edit_projects WHERE id = ?1 AND deleted_at IS NULL",
        )
        .bind(id)
        .first<ProjectRow>();
}

async function loadProject(db: D1Database, id: string) {
    const row = await getProjectRow(db, id);
    if (!row) return null;
    const [cover, render] = await Promise.all([coverUrl(db, row.cover_item), newestRender(db, id)]);
    return projectShape(row, cover, render);
}

// ---- library rows ---------------------------------------------------------------------------------------------

type MediaRow = {
    id: string;
    name: string;
    content_type: string | null;
    source: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
    bytes: number | null;
    poster: string | null;
    deleted_at: number | null;
};

// The distinct item ids of a timeline in order: main first, then overlay.
export const timelineItems = (t: Pick<Timeline, "main" | "overlay">): string[] => [...new Set([...t.main.map((c) => c.item), ...t.overlay.map((c) => c.item)])];

async function mediaRows(db: D1Database, ids: string[]): Promise<Map<string, MediaRow>> {
    const out = new Map<string, MediaRow>();
    if (ids.length === 0) return out;
    const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(`SELECT id, name, content_type, source, width, height, duration, bytes, poster, deleted_at FROM media_items WHERE id IN (${marks})`)
        .bind(...ids)
        .all<MediaRow>();
    for (const r of results) out.set(r.id, r);
    return out;
}

export const sourceKind = (contentType: string | null): "video" | "gif" | "photo" | "unsupported" => {
    switch (contentType) {
        case "video/mp4":
        case "video/quicktime":
        case "video/x-m4v":
            return "video";
        case "image/gif":
            return "gif";
        case "image/jpeg":
        case "image/png":
        case "image/webp": // a still or an animated webp (section 39): the render finds out which from the bytes
            return "photo";
        default:
            return "unsupported";
    }
};

const sourceShape = (id: string, r: MediaRow | undefined) => ({
    id,
    name: r?.name ?? "",
    kind: r ? sourceKind(r.content_type) : "unsupported",
    content_type: r?.content_type ?? null,
    width: r?.width ?? null,
    height: r?.height ?? null,
    duration: r?.duration ?? null,
    bytes: r?.bytes ?? null,
    poster_url: r?.poster ?? null,
    source: r?.source ?? null,
    available: !!r && r.deleted_at === null,
});

const sourceRowsFor = (rows: Map<string, MediaRow>): SourceRow[] =>
    [...rows.values()].map((r) => ({
        id: r.id,
        content_type: r.content_type,
        source: r.source,
        width: r.width,
        height: r.height,
        duration: r.duration,
        bytes: r.bytes,
        deleted: r.deleted_at !== null,
    }));

// The half of the overlay frame rule the timeline alone cannot check (31.2): `y + h <= 1.001`, with
// `h = w x canvas.w / canvas.h x srcH / srcW`, where the library row knows the picture's size. (The render
// checks it again on the probed size, always.)
function overlayFits(t: Timeline, rows: Map<string, MediaRow>): { ok: true } | { ok: false; path: string } {
    for (let i = 0; i < t.overlay.length; i++) {
        const o = t.overlay[i]!;
        const src = rows.get(o.item);
        if (!src || !src.width || !src.height || src.width <= 0 || src.height <= 0) continue;
        const h = ((o.frame.w * t.canvas.w) / t.canvas.h) * (src.height / src.width);
        if (o.frame.y + h > 1.001) return { ok: false, path: `overlay[${i}].frame` };
    }
    return { ok: true };
}

// ---- bodies ---------------------------------------------------------------------------------------------------

type Body = { ok: true; body: Record<string, unknown> } | { ok: false; reply: StudioReply };

async function readBody(request: Request, allowed: string[]): Promise<Body> {
    let text: string | null;
    try {
        text = await readCapped(request, EDIT_BODY_CAP);
    } catch {
        return { ok: false, reply: badRequest("") };
    }
    if (text === null) return { ok: false, reply: badRequest("") };
    let parsed: unknown;
    try {
        parsed = JSON.parse(text);
    } catch {
        return { ok: false, reply: badRequest("") };
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, reply: badRequest("") };
    const body = parsed as Record<string, unknown>;
    for (const k of Object.keys(body)) if (!allowed.includes(k)) return { ok: false, reply: badRequest(k) };
    return { ok: true, body };
}

// An optional title: absent = undefined; present = cleaned (1..80 code points, no control characters); else bad.
function bodyTitle(body: Record<string, unknown>): { ok: true; title: string | undefined } | { ok: false } {
    if (!("title" in body)) return { ok: true, title: undefined };
    const t = cleanTitle(body.title);
    return t.ok && t.title !== null ? { ok: true, title: t.title } : { ok: false };
}

const isRevision = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= Number.MAX_SAFE_INTEGER;

// parseTimeline, the 64 KiB cap and the overlay height check where the rows know the size (POST, PUT).
async function checkTimelineForSave(
    d: EditsDeps,
    raw: unknown,
): Promise<{ ok: true; timeline: Timeline; json: string; frames: number; rows: Map<string, MediaRow> } | { ok: false; reply: StudioReply }> {
    const p = parse(raw);
    if (!p.ok) return { ok: false, reply: validationReply(p) };
    const timeline = p.timeline;
    const json = canonical(timeline);
    if (new TextEncoder().encode(json).byteLength > EDIT_MAX_JSON_BYTES) return { ok: false, reply: badRequest("timeline") };
    const rows = await mediaRows(d.db, timelineItems(timeline));
    const fit = overlayFits(timeline, rows);
    if (!fit.ok) return { ok: false, reply: validationReply({ code: "error.edit.range", path: fit.path }) };
    return { ok: true, timeline, json, frames: timingOf(timeline).frames, rows };
}

// ---- the routes -------------------------------------------------------------------------------------------------

export async function editsKeyed(
    d: EditsDeps,
    op: EditsOp,
    request: Request,
    params: Record<string, string>,
    searchParams: URLSearchParams,
): Promise<StudioReply> {
    try {
        switch (op) {
            case "list":
                return await listProjects(d);
            case "create":
                return await createProject(d, request);
            case "get":
                return await getProject(d, params.id ?? "");
            case "update":
                return await updateProject(d, request, params.id ?? "");
            case "rename":
                return await renameProject(d, request, params.id ?? "");
            case "delete":
                return await deleteProject(d, params.id ?? "");
            case "render":
                return await startRender(d, request, params.id ?? "");
            case "renders":
                return await listRenders(d, searchParams);
            case "render_get":
                return await getRenderRoute(d, params.rid ?? "");
            case "render_cancel":
                return await cancelRender(d, params.rid ?? "");
            default:
                return err(404, "error.edit.not_found");
        }
    } catch (e) {
        // D1 failed, or migration 0021 is missing: the same answer (31.7)
        console.error("[edits] route failed", op, e instanceof Error ? e.message : String(e));
        return generic();
    }
}

const notFound = () => err(404, "error.edit.not_found");

// GET /edits
async function listProjects(d: EditsDeps): Promise<StudioReply> {
    const [projects, covers, renders] = await Promise.all([
        d.db
            .prepare(
                `SELECT id, title, timeline, revision, canvas_w, canvas_h, fps, frames, clip_count, cover_item, created_at, updated_at
                   FROM edit_projects WHERE deleted_at IS NULL ORDER BY updated_at DESC, id DESC LIMIT ${EDIT_MAX_PROJECTS}`,
            )
            .all<ProjectRow>(),
        d.db
            .prepare(
                "SELECT id, poster FROM media_items WHERE deleted_at IS NULL AND id IN (SELECT cover_item FROM edit_projects WHERE deleted_at IS NULL AND cover_item IS NOT NULL)",
            )
            .all<{ id: string; poster: string | null }>(),
        // each project's newest render, without a bind per project (D1 allows 100 per statement)
        d.db
            .prepare(
                `${RENDER_SELECT} WHERE r.project_id IN (SELECT id FROM edit_projects WHERE deleted_at IS NULL)
                    AND r.id = (SELECT x.id FROM edit_renders x WHERE x.project_id = r.project_id ORDER BY x.created_at DESC, x.id DESC LIMIT 1)`,
            )
            .all<RenderRow>(),
    ]);
    const poster = new Map(covers.results.map((c) => [c.id, c.poster]));
    const latest = new Map(renders.results.map((r) => [r.project_id, r]));
    return ok(200, {
        projects: projects.results.map((p) => projectSummary(p, p.cover_item ? (poster.get(p.cover_item) ?? null) : null, latest.get(p.id) ?? null)),
    });
}

// POST /edits
async function createProject(d: EditsDeps, request: Request): Promise<StudioReply> {
    const b = await readBody(request, ["title", "timeline"]);
    if (!b.ok) return b.reply;
    const title = bodyTitle(b.body);
    if (!title.ok) return badRequest("title");
    if (!("timeline" in b.body)) return badRequest("timeline");
    const t = await checkTimelineForSave(d, b.body.timeline);
    if (!t.ok) return t.reply;
    const live = await d.db.prepare("SELECT COUNT(*) AS n FROM edit_projects WHERE deleted_at IS NULL").first<{ n: number }>();
    if ((live?.n ?? 0) >= EDIT_MAX_PROJECTS) return err(409, "error.edit.too_many");
    const id = randomBase62(16, d.randomBytes);
    const now = d.now();
    await d.db
        .prepare(
            `INSERT INTO edit_projects (id, title, timeline, revision, canvas_w, canvas_h, fps, frames, clip_count, cover_item, key_id, updated_key, created_at, updated_at)
             VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?11, ?11)`,
        )
        .bind(
            id,
            title.title ?? EDIT_DEFAULT_TITLE,
            t.json,
            t.timeline.canvas.w,
            t.timeline.canvas.h,
            t.timeline.canvas.fps,
            t.frames,
            t.timeline.main.length + t.timeline.overlay.length,
            t.timeline.main[0]?.item ?? null,
            d.keyId,
            now,
        )
        .run();
    const project = await loadProject(d.db, id);
    return project ? ok(201, { project }) : generic();
}

// GET /edits/<id>
async function getProject(d: EditsDeps, id: string): Promise<StudioReply> {
    const project = await loadProject(d.db, id);
    if (!project) return notFound();
    const items = timelineItems(project.timeline);
    const rows = await mediaRows(d.db, items);
    const sources: Record<string, ReturnType<typeof sourceShape>> = {};
    for (const item of items) sources[item] = sourceShape(item, rows.get(item));
    return ok(200, { project, sources });
}

// 409 error.edit.conflict carries the current project (31.12)
async function conflict(d: EditsDeps, id: string): Promise<StudioReply> {
    const project = await loadProject(d.db, id);
    return project ? err(409, "error.edit.conflict", { project }) : notFound();
}

// PUT /edits/<id>
async function updateProject(d: EditsDeps, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request, ["timeline", "base_revision", "title"]);
    if (!b.ok) return b.reply;
    if (!isRevision(b.body.base_revision)) return badRequest("base_revision");
    const title = bodyTitle(b.body);
    if (!title.ok) return badRequest("title");
    if (!("timeline" in b.body)) return badRequest("timeline");
    const t = await checkTimelineForSave(d, b.body.timeline);
    if (!t.ok) return t.reply;
    const cur = await getProjectRow(d.db, id);
    if (!cur) return notFound();
    if (cur.revision !== b.body.base_revision) return conflict(d, id);
    // the revision check is repeated in the statement: two saves that both read revision n cannot both win
    const res = await d.db
        .prepare(
            `UPDATE edit_projects SET title = ?1, timeline = ?2, revision = revision + 1, canvas_w = ?3, canvas_h = ?4, fps = ?5, frames = ?6,
                    clip_count = ?7, cover_item = ?8, updated_key = ?9, updated_at = ?10
              WHERE id = ?11 AND revision = ?12 AND deleted_at IS NULL`,
        )
        .bind(
            title.title ?? cur.title,
            t.json,
            t.timeline.canvas.w,
            t.timeline.canvas.h,
            t.timeline.canvas.fps,
            t.frames,
            t.timeline.main.length + t.timeline.overlay.length,
            t.timeline.main[0]?.item ?? null,
            d.keyId,
            d.now(),
            id,
            cur.revision,
        )
        .run();
    if (Number(res.meta?.changes ?? 0) === 0) return conflict(d, id);
    const project = await loadProject(d.db, id);
    return project ? ok(200, { project }) : notFound();
}

// PATCH /edits/<id>
async function renameProject(d: EditsDeps, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request, ["title"]);
    if (!b.ok) return b.reply;
    const title = bodyTitle(b.body);
    if (!title.ok || title.title === undefined) return badRequest("title");
    const res = await d.db
        .prepare("UPDATE edit_projects SET title = ?1, revision = revision + 1, updated_key = ?2, updated_at = ?3 WHERE id = ?4 AND deleted_at IS NULL")
        .bind(title.title, d.keyId, d.now(), id)
        .run();
    if (Number(res.meta?.changes ?? 0) === 0) return notFound();
    const project = await loadProject(d.db, id);
    return project ? ok(200, { project }) : notFound();
}

// DELETE /edits/<id>: a soft delete; its queued renders are cancelled, a running one finishes and files its video.
async function deleteProject(d: EditsDeps, id: string): Promise<StudioReply> {
    const now = d.now();
    const res = await d.db
        .prepare("UPDATE edit_projects SET deleted_at = ?1, updated_key = ?2, updated_at = ?1 WHERE id = ?3 AND deleted_at IS NULL")
        .bind(now, d.keyId, id)
        .run();
    if (Number(res.meta?.changes ?? 0) === 0) return notFound();
    await d.db
        .prepare(
            "UPDATE edit_renders SET status = 'cancelled', cancel_requested = 1, error_code = 'error.edit.cancelled', finished_at = ?1, updated_at = ?1 WHERE project_id = ?2 AND status = 'queued'",
        )
        .bind(now, id)
        .run();
    return ok(200, {});
}

// POST /edits/<id>/render
async function startRender(d: EditsDeps, request: Request, id: string): Promise<StudioReply> {
    const b = await readBody(request, ["revision", "notify"]);
    if (!b.ok) return b.reply;
    if (!isRevision(b.body.revision)) return badRequest("revision");
    if ("notify" in b.body && typeof b.body.notify !== "boolean") return badRequest("notify");
    const notify = b.body.notify === true;
    const row = await getProjectRow(d.db, id);
    if (!row) return notFound();
    if (row.revision !== b.body.revision) return conflict(d, id);

    // the same revision already in the line or running: that render (idempotent)
    const existing = await d.db
        .prepare(`${RENDER_SELECT} WHERE r.project_id = ?1 AND r.revision = ?2 AND r.status IN ('queued', 'preparing', 'rendering', 'finishing') ORDER BY r.created_at DESC, r.id DESC LIMIT 1`)
        .bind(id, row.revision)
        .first<RenderRow>();
    if (existing) return ok(200, { render: renderShape(existing) });

    // the full check (31.12): the stored timeline again, then the library rows
    const p = parse(JSON.parse(row.timeline));
    if (!p.ok) return validationReply(p);
    const rows = await mediaRows(d.db, timelineItems(p.timeline));
    const checked = checkRows(p.timeline, sourceRowsFor(rows));
    if (!checked.ok) return validationReply(checked);
    // nothing is made of a hidden post (section 37.2): its clips are refused, named by file id
    const hidden = await hiddenFileIds(d.db, timelineItems(p.timeline));
    if (hidden.length > 0) return { status: 409, body: { status: "error", error: { code: "error.hidden" }, ids: hidden } };
    let inputBytes = 0;
    for (const r of rows.values()) inputBytes += r.bytes ?? 0;
    if (inputBytes > EDIT_MAX_INPUT_BYTES) return validationReply({ code: "error.edit.too_large", path: "main" });

    const busy = await d.db
        .prepare("SELECT COUNT(*) AS n FROM edit_renders WHERE status IN ('queued', 'preparing', 'rendering', 'finishing')")
        .first<{ n: number }>();
    if ((busy?.n ?? 0) >= EDIT_QUEUE_MAX) return err(429, "error.edit.queue_full");

    const rid = randomBase62(20, d.randomBytes);
    const now = d.now();
    await d.db
        .prepare(
            `INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, cancel_requested, attempts, input_bytes, seconds_total, notify, key_id, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 'queued', 0, 0, ?6, ?7, ?8, ?9, ?10, ?10)`,
        )
        .bind(rid, id, row.revision, row.title, row.timeline, inputBytes, row.frames / row.fps, notify ? 1 : 0, d.keyId, now)
        .run();
    // wake the renderers; a failure is swallowed (the 15-minute cron kicks again)
    await d.kick().catch(() => {});
    const made = await getRender(d.db, rid);
    return made ? ok(202, { render: renderShape(made) }) : generic();
}

// GET /edits/renders?limit=1..50
async function listRenders(d: EditsDeps, q: URLSearchParams): Promise<StudioReply> {
    let limit = EDIT_RENDERS_DEFAULT;
    const raw = q.get("limit");
    if (raw !== null) {
        if (!/^\d{1,3}$/.test(raw) || Number(raw) < 1 || Number(raw) > EDIT_RENDERS_MAX) return badRequest("limit");
        limit = Number(raw);
    }
    const { results } = await d.db
        .prepare(`${RENDER_SELECT} ORDER BY r.created_at DESC, r.id DESC LIMIT ?1`)
        .bind(limit)
        .all<RenderRow>();
    return ok(200, { renders: results.map(renderShape) });
}

// GET /edits/renders/<rid>
async function getRenderRoute(d: EditsDeps, rid: string): Promise<StudioReply> {
    const row = await getRender(d.db, rid);
    return row ? ok(200, { render: renderShape(row) }) : notFound();
}

// DELETE /edits/renders/<rid>: queued ends at once; a claimed render gets `cancel_requested` and its renderer
// stops it within one tick; a cancelled one answers the same 200; a finished one is 409.
async function cancelRender(d: EditsDeps, rid: string): Promise<StudioReply> {
    const row = await getRender(d.db, rid);
    if (!row) return notFound();
    if (row.status === "cancelled") return ok(200, { render: renderShape(row) });
    if (row.status === "done" || row.status === "error") return err(409, "error.edit.finished");
    const now = d.now();
    if (row.status === "queued") {
        const res = await d.db
            .prepare(
                "UPDATE edit_renders SET status = 'cancelled', cancel_requested = 1, error_code = 'error.edit.cancelled', finished_at = ?1, updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
            )
            .bind(now, rid)
            .run();
        if (Number(res.meta?.changes ?? 0) > 0) {
            const fresh = await getRender(d.db, rid);
            return fresh ? ok(200, { render: renderShape(fresh) }) : notFound();
        }
        // claimed meanwhile: it is now the renderer's to stop
    }
    await d.db
        .prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?1 AND status IN ('preparing', 'rendering', 'finishing')")
        .bind(rid)
        .run();
    const fresh = await getRender(d.db, rid);
    if (!fresh) return notFound();
    if (fresh.status === "done" || fresh.status === "error") return err(409, "error.edit.finished");
    return ok(200, { render: renderShape(fresh) });
}

// ---- GET /queue (31.13) --------------------------------------------------------------------------------------------

// Every render queued or running, then those that ended in the last 30 minutes; each group newest first, at most 20.
// One D1 query; the container is never woken.
export async function queueEdits(db: D1Database, now: number): Promise<RenderShape[]> {
    const { results } = await db
        .prepare(
            `${RENDER_SELECT}
              WHERE r.status IN ('queued', 'preparing', 'rendering', 'finishing')
                 OR (r.finished_at IS NOT NULL AND r.finished_at >= ?1)
              ORDER BY CASE WHEN r.status IN ('queued', 'preparing', 'rendering', 'finishing') THEN 0 ELSE 1 END, r.created_at DESC, r.id DESC
              LIMIT ${EDIT_QUEUE_LIST_MAX}`,
        )
        .bind(now - EDIT_QUEUE_RECENT_MS)
        .all<RenderRow>();
    return results.map(renderShape);
}

// ---- the cron's recovery (31.9) --------------------------------------------------------------------------------------

export type RecoverDeps = {
    db: D1Database;
    now: () => number;
    kick: () => Promise<void>;
    // called with the id of each render this run ended `error.edit.lost` (index.ts wires the Hark message, 31.11)
    onLost?: (rid: string) => Promise<void>;
};

// A claimed render nobody has written to for 10 minutes lost its renderer (a deploy, an eviction): back into the line
// (`attempts < 2`), else it ends `error.edit.lost`; a cancel already asked ends it cancelled. Then both instances are
// kicked when anything is queued. D1 only unless there is work.
export async function editsRecover(d: RecoverDeps): Promise<{ requeued: number; lost: number; cancelled: number; queued: number }> {
    const now = d.now();
    const cutoff = now - EDIT_STALE_MS;
    const { results } = await d.db
        .prepare("SELECT id, attempts, cancel_requested FROM edit_renders WHERE status IN ('preparing', 'rendering', 'finishing') AND updated_at < ?1")
        .bind(cutoff)
        .all<{ id: string; attempts: number; cancel_requested: number }>();
    let requeued = 0;
    let lost = 0;
    let cancelled = 0;
    // each statement repeats the staleness test: a renderer that wrote meanwhile keeps its render
    const stale = "status IN ('preparing', 'rendering', 'finishing') AND updated_at < ?3";
    for (const r of results) {
        let changed: number;
        if (r.cancel_requested === 1) {
            changed = Number(
                (
                    await d.db
                        .prepare(`UPDATE edit_renders SET status = 'cancelled', error_code = 'error.edit.cancelled', finished_at = ?1, updated_at = ?1 WHERE id = ?2 AND ${stale}`)
                        .bind(now, r.id, cutoff)
                        .run()
                ).meta?.changes ?? 0,
            );
            if (changed > 0) cancelled++;
        } else if (r.attempts < 2) {
            changed = Number(
                (
                    await d.db
                        .prepare(
                            `UPDATE edit_renders SET status = 'queued', instance = NULL, started_at = NULL, sent_bytes = NULL, seconds_done = NULL, updated_at = ?1 WHERE id = ?2 AND ${stale}`,
                        )
                        .bind(now, r.id, cutoff)
                        .run()
                ).meta?.changes ?? 0,
            );
            if (changed > 0) requeued++;
        } else {
            changed = Number(
                (
                    await d.db
                        .prepare(`UPDATE edit_renders SET status = 'error', error_code = 'error.edit.lost', finished_at = ?1, updated_at = ?1 WHERE id = ?2 AND ${stale}`)
                        .bind(now, r.id, cutoff)
                        .run()
                ).meta?.changes ?? 0,
            );
            if (changed > 0) {
                lost++;
                if (d.onLost) await d.onLost(r.id).catch(() => {});
            }
        }
    }
    const q = await d.db.prepare("SELECT COUNT(*) AS n FROM edit_renders WHERE status = 'queued' AND cancel_requested = 0").first<{ n: number }>();
    const queued = q?.n ?? 0;
    if (queued > 0) await d.kick().catch(() => {});
    return { requeued, lost, cancelled, queued };
}
