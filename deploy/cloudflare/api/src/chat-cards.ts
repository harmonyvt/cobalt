// Rich tool cards (APP-API-CONTRACT.md section 38): what each `cobalt.*` call of a chat code run did, as a small record
// the app draws under the step: a chip for every call, and a card for the calls with something to see (pictures it
// searched or looked at, 7TV emotes, an edit as a mini timeline, jobs, box commands, links, collections).
//
// Built from the op's checked input and its result, after the call; never shown to the model. Every card is small (lists
// are cut) and only carries post ids, which the message's `posts` map turns into thumbnails. Free of Cloudflare imports.
import { POST_KEY_SQL } from "./post-key";

export const CALLS_MAX = 40;
const HITS_MAX = 8;
const EMOTES_MAX = 24;
const POSTS_MAX = 12;
const CLIPS_MAX = 60;
const OUT_TAIL = 1500;
const ERR_TAIL = 800;
const CMD_MAX = 600;
const TEXT_MAX = 200;

export type ClipKind = "video" | "photo" | "gif" | "webp" | "emote" | "cutout";

export type EditClip = {
    id: string;
    item: string;
    // the post the clip's file is in, for its thumbnail; null when the file is gone
    post_id: string | null;
    kind: ClipKind | null;
    title: string | null;
    // a public picture of the clip (an emote's webp, an image's own URL, a video's poster), when there is one
    picture: string | null;
    // where it sits on the output timeline, in seconds
    at: number;
    length: number;
    // the part of the source it plays
    in: number;
    out: number;
    speed: number;
    pitch: number | null;
    // added (or its id first seen) by this call
    is_new: boolean;
};

export type ToolCard =
    | { type: "search"; query: string; within: string | null; total: number; hits: { post_id: string; score: number | null }[] }
    | { type: "look"; post_ids: string[] }
    | {
          type: "emotes";
          query: string | null;
          sort: string | null;
          // emotes.save: the one emote it saved
          saved: boolean;
          emotes: { id: string; name: string; animated: boolean; url: string; library_id: string | null }[];
      }
    | {
          type: "edit";
          project_id: string;
          title: string | null;
          revision: number | null;
          duration: number;
          width: number | null;
          height: number | null;
          change: "created" | "updated" | "viewed";
          tracks: { name: "main" | "overlay"; index: number; clips: EditClip[] }[];
          render: { status: string; progress: number | null; post_id: string | null } | null;
      }
    | {
          type: "job";
          op: string;
          job: string;
          status: string;
          progress: number | null;
          error: string | null;
          post_id: string | null;
          kind: string | null;
          seconds: number | null;
          width: number | null;
          height: number | null;
          bytes: number | null;
          share_url: string | null;
          // the server continues the chat when it ends (jobs.onDone)
          watching: boolean;
          project_id: string | null;
      }
    | { type: "box"; cmd: string; code: number | null; timed_out: boolean; stdout: string; stderr: string }
    | { type: "files"; direction: "in" | "out"; files: { name: string; bytes: number | null }[]; post_id: string | null }
    | { type: "link"; id: string | null; url: string; title: string | null; files: number | null; private: boolean }
    | { type: "collection"; of: "collection" | "set"; id: string; name: string; count: number | null; change: "created" | "added" | "updated" }
    | { type: "saved"; post_ids: string[]; title: string | null; status: string | null }
    | { type: "facts"; title: string; rows: [string, string][]; post_ids: string[] }
    // sub-agents (section 43.6): the ones a call started, listed, looked at or stopped, a message sent, mail read
    | {
          type: "agents";
          change: "started" | "listed" | "viewed" | "stopped" | "sent" | "inbox" | "waiting";
          agents: AgentCardRow[];
          message: { to: string; text: string } | null;
          mail: { from: string; text: string }[];
      };

export type AgentCardRow = {
    id: string;
    name: string;
    status: string;
    task: string;
    activity: string | null;
    result: string | null;
    post_ids: string[];
    // jobs.onDone: the server continues the chat when it finishes
    watching: boolean;
};

export type ToolCall = {
    // the op name ("library.search"); the model's call name when it differs
    op: string;
    ms: number;
    status: "done" | "error" | "asked";
    error?: string;
    card?: ToolCard;
};

// ---- helpers ------------------------------------------------------------------------------------------------------------

type Any = Record<string, any>;
const obj = (v: unknown): Any | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Any) : null);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const clip = (s: string, max: number) => (s.length > max ? `${s.slice(0, max)}…` : s);
const tail = (s: unknown, max: number) => {
    const t = typeof s === "string" ? s.trimEnd() : "";
    return t.length > max ? `…${t.slice(t.length - max)}` : t;
};
const round = (n: number) => Math.round(n * 1000) / 1000;
const idsOf = (v: unknown): string[] =>
    (Array.isArray(v) ? v : typeof v === "string" ? [v] : []).filter((x): x is string => typeof x === "string" && x !== "").slice(0, POSTS_MAX);

// ---- the cards ----------------------------------------------------------------------------------------------------------

export type CardDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    // edits.update / edits.addOverlay: the project's timeline before the call, when the toolbox read it
    before?: unknown;
};

// The card for one call, or null (a chip only). Never throws: a card that cannot be built is left out.
export async function cardFor(op: string, input: unknown, out: unknown, d: CardDeps): Promise<ToolCard | null> {
    try {
        return await build(op, obj(input) ?? {}, out, d);
    } catch (e) {
        console.error("[chat-cards] card failed", op, String(e));
        return null;
    }
}

async function build(op: string, input: Any, out: unknown, d: CardDeps): Promise<ToolCard | null> {
    const o = obj(out);
    switch (op) {
        case "library.search": {
            const list = Array.isArray(out) ? (out as Any[]) : [];
            const w = input.within;
            const within = typeof w === "string" ? w : obj(w) ? String(w.collection ?? w.link ?? (Array.isArray(w.posts) ? `${w.posts.length} posts` : "")) || null : null;
            return {
                type: "search",
                query: clip(String(input.query ?? ""), TEXT_MAX),
                within,
                total: list.length,
                hits: list.slice(0, HITS_MAX).flatMap((p) => (str(p?.id) ? [{ post_id: p.id as string, score: num(p.score) }] : [])),
            };
        }
        case "library.list": {
            const list = Array.isArray(out) ? (out as Any[]) : [];
            const q = [input.query, input.source, input.kind].filter((x) => typeof x === "string" && x).join(" · ");
            return { type: "search", query: clip(q || "newest", TEXT_MAX), within: null, total: list.length, hits: list.slice(0, HITS_MAX).flatMap((p) => (str(p?.id) ? [{ post_id: p.id as string, score: null }] : [])) };
        }
        case "look": {
            const ids = idsOf(input.ids);
            return ids.length ? { type: "look", post_ids: ids } : null;
        }
        case "emotes.find": {
            // a bare array (before section 20.1's paging) or { sort, page, has_more, items }
            const items = Array.isArray(out) ? (out as Any[]) : Array.isArray(o?.items) ? (o!.items as Any[]) : [];
            return {
                type: "emotes",
                query: str(input.query),
                sort: str(o?.sort) ?? str(input.sort),
                saved: false,
                emotes: items.slice(0, EMOTES_MAX).flatMap(emoteOf),
            };
        }
        case "emotes.save": {
            if (!o) return null;
            const e = emoteOf({ id: o.id ?? o.emote_id ?? input.id, name: o.name, animated: o.animated, preview_url: o.preview_url ?? o.url, library_id: o.library_id ?? o.item_id ?? o.id_in_library });
            return { type: "emotes", query: null, sort: null, saved: true, emotes: e };
        }
        case "edits.get":
            return o ? editCard(d, o, obj(o.timeline), "viewed", null) : null;
        case "edits.create":
            return o ? editCard(d, o, obj(input.timeline), "created", null) : null;
        case "edits.update":
        case "edits.addOverlay": {
            if (!o) return null;
            // edits.update sends the whole timeline; addOverlay answers with it
            const t = obj(input.timeline) ?? obj(o.timeline);
            return t ? editCard(d, o, t, "updated", obj(d.before)) : { type: "facts", title: "edit changed", rows: [["edit", String(o.title ?? o.id ?? "")]], post_ids: [] };
        }
        case "make.webp":
        case "make.still":
        case "make.slideshow":
        case "make.galleryImage":
        case "make.trim":
        case "make.crop":
        case "make.cutout":
        case "make.cropImage":
        case "edits.render":
        case "chat.video":
        case "jobs.wait":
        case "jobs.onDone":
            if (o && /^agent:/.test(String(o.job))) return { type: "agents", change: "waiting", agents: [agentCardRow(o)], message: null, mail: [] };
            return o && str(o.job) ? jobCard(op, o) : null;
        case "agents.spawn":
        case "agents.get":
        case "agents.stop":
            return o && str(o.agent)
                ? { type: "agents", change: op === "agents.spawn" ? "started" : op === "agents.stop" ? "stopped" : "viewed", agents: [agentCardRow(o)], message: null, mail: [] }
                : null;
        case "agents.list":
            return o && Array.isArray(o.agents)
                ? { type: "agents", change: "listed", agents: (o.agents as Any[]).slice(0, AGENTS_SHOWN).map(agentCardRow), message: null, mail: [] }
                : null;
        case "agents.send":
            return o ? { type: "agents", change: "sent", agents: [], message: { to: String(o.to_name ?? input.to ?? ""), text: clip(String(input.text ?? ""), TEXT_MAX) }, mail: [] } : null;
        case "agents.inbox": {
            const mail = Array.isArray(o?.messages) ? (o!.messages as Any[]) : [];
            return mail.length > 0
                ? { type: "agents", change: "inbox", agents: [], message: null, mail: mail.slice(0, AGENTS_SHOWN).map((m) => ({ from: String(m.from_name ?? m.from ?? ""), text: clip(String(m.text ?? ""), TEXT_MAX) })) }
                : null;
        }
        case "box.run":
            return o
                ? { type: "box", cmd: clip(String(input.cmd ?? ""), CMD_MAX), code: num(o.code), timed_out: o.timed_out === true, stdout: tail(o.stdout, OUT_TAIL), stderr: tail(o.stderr, ERR_TAIL) }
                : null;
        case "box.pull": {
            const files = Array.isArray(o?.files) ? (o!.files as Any[]) : [];
            return { type: "files", direction: "in", files: files.slice(0, POSTS_MAX).map((f) => ({ name: String(f.path ?? f.file_id ?? ""), bytes: num(f.bytes) })), post_id: str(input.id) };
        }
        case "box.save": {
            if (!o) return null;
            const name = String(input.path ?? "").split("/").pop() ?? "";
            return { type: "files", direction: "out", files: [{ name, bytes: num(o.bytes) }], post_id: str(o.post_id) };
        }
        case "library.save":
            return o ? { type: "saved", post_ids: idsOf(o.post_id), title: str(o.title), status: str(o.status) } : null;
        case "links.create":
        case "links.rotate":
        case "links.private":
            return o && str(o.url)
                ? { type: "link", id: str(o.id), url: o.url as string, title: str(o.title), files: num(o.files), private: o.private === true || /\/p\//.test(o.url as string) }
                : null;
        case "collections.create":
        case "collections.add":
        case "collections.update":
            return o && str(o.id)
                ? { type: "collection", of: "collection", id: o.id as string, name: String(o.name ?? ""), count: Array.isArray(o.link_ids) ? o.link_ids.length : null, change: op === "collections.create" ? "created" : op === "collections.add" ? "added" : "updated" }
                : null;
        case "sets.create":
        case "sets.add":
        case "sets.update":
            return o && str(o.id)
                ? { type: "collection", of: "set", id: o.id as string, name: String(o.name ?? ""), count: Array.isArray(o.collection_ids) ? o.collection_ids.length : null, change: op === "sets.create" ? "created" : op === "sets.add" ? "added" : "updated" }
                : null;
        case "library.title":
            return o ? { type: "facts", title: "renamed", rows: [["title", o.title === null ? "(original name)" : String(o.title)]], post_ids: idsOf(o.post_id) } : null;
        case "library.visibility":
            return o
                ? { type: "facts", title: o.public ? "made public" : "made private", rows: [["posts", String(num(o.changed) ?? 0)]], post_ids: idsOf(Array.isArray(o.posts) ? o.posts.map((p: Any) => p?.id) : []) }
                : null;
        case "library.about.set":
            return { type: "facts", title: "about changed", rows: [], post_ids: idsOf(input.id) };
        default:
            return null;
    }
}

function emoteOf(e: Any): { id: string; name: string; animated: boolean; url: string; library_id: string | null }[] {
    const url = str(e?.preview_url) ?? str(e?.file_url) ?? str(e?.url);
    const id = str(e?.id);
    if (!url || !id || !/^https:\/\//.test(url)) return [];
    return [{ id, name: clip(String(e.name ?? ""), 64), animated: e.animated === true, url, library_id: str(e.library_id) }];
}

const AGENTS_SHOWN = 8;

function agentCardRow(o: Any): AgentCardRow {
    // an agent's shape (agents.*) or its job state (jobs.wait / jobs.onDone on agent:<id>)
    const status = String(o.status ?? "running");
    return {
        id: String(o.agent ?? String(o.job ?? "").replace(/^agent:/, "")),
        name: String(o.name ?? ""),
        status: status === "cancelled" ? "stopped" : status,
        task: clip(String(o.task ?? ""), TEXT_MAX),
        activity: str(o.activity),
        result: typeof o.result === "string" && o.result !== "" ? clip(o.result, 300) : null,
        post_ids: idsOf(o.post_ids),
        watching: o.watching === true,
    };
}

function jobCard(op: string, o: Any): ToolCard {
    return {
        type: "job",
        op,
        job: clip(String(o.job), 200),
        status: String(o.status ?? "queued"),
        progress: num(o.progress),
        error: str(o.error),
        post_id: str(o.post_id),
        kind: str(o.kind),
        seconds: num(o.seconds),
        width: num(o.width),
        height: num(o.height),
        bytes: num(o.bytes),
        share_url: str(o.share_url),
        watching: o.watching === true,
        project_id: str(o.project_id),
    };
}

type ItemRow = { id: string; post_key: string; name: string | null; content_type: string | null; source: string | null; poster: string | null; url: string | null; title: string | null };

async function itemRows(db: D1Database, ids: string[]): Promise<Map<string, ItemRow>> {
    const out = new Map<string, ItemRow>();
    if (ids.length === 0) return out;
    const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
    const { results } = await db
        .prepare(
            `SELECT x.*, t.title FROM (SELECT m.id, m.name, m.content_type, m.source, m.poster, m.url, ${POST_KEY_SQL} AS post_key
                                         FROM media_items m WHERE m.deleted_at IS NULL AND m.id IN (${marks})) x
               LEFT JOIN media_titles t ON t.post_key = x.post_key`,
        )
        .bind(...ids)
        .all<ItemRow>();
    for (const r of results) out.set(r.id, r);
    return out;
}

function kindOf(r: ItemRow | undefined): ClipKind | null {
    if (!r) return null;
    if (r.source === "emote") return "emote";
    if (/cutout/i.test(r.name ?? "")) return "cutout";
    const t = (r.content_type ?? "").toLowerCase();
    if (t.startsWith("video/")) return "video";
    if (t === "image/gif") return "gif";
    if (t === "image/webp") return "webp";
    if (t.startsWith("image/")) return "photo";
    return null;
}

const isPicture = (k: ClipKind | null) => k === "photo" || k === "gif" || k === "webp" || k === "emote" || k === "cutout";

async function editCard(d: CardDeps, project: Any, timeline: Any | null, change: "created" | "updated" | "viewed", before: Any | null): Promise<ToolCard | null> {
    const id = str(project.id);
    if (!id || !timeline) return null;
    const main = (Array.isArray(timeline.main) ? (timeline.main as Any[]) : []).slice(0, CLIPS_MAX);
    const overlay = (Array.isArray(timeline.overlay) ? (timeline.overlay as Any[]) : []).slice(0, CLIPS_MAX);
    const render = obj(project.render);
    const rendered = str(render?.item_id);
    const rows = await itemRows(d.db, [
        ...new Set([...[...main, ...overlay].map((c) => c?.item), rendered].filter((x): x is string => typeof x === "string")),
    ]);
    // clips added by this call: ids the timeline before it did not have (nothing is new when we did not see it)
    const had = before ? new Set([...(before.main ?? []), ...(before.overlay ?? [])].map((c: Any) => c?.id)) : null;
    const base = d.mediaBaseUrl.endsWith("/") ? d.mediaBaseUrl : `${d.mediaBaseUrl}/`;
    const shape = (c: Any, at: number, length: number): EditClip => {
        const r = rows.get(c.item);
        const kind = kindOf(r);
        const own = r?.url && r.url.startsWith(base) && isPicture(kind) ? r.url : null;
        const poster = r?.poster && r.poster.startsWith(base) ? r.poster : null;
        return {
            id: String(c.id ?? ""),
            item: String(c.item ?? ""),
            post_id: r?.post_key ?? null,
            kind,
            title: r ? clip(r.title ?? (r.name ?? "").replace(/\.[A-Za-z0-9]{1,5}$/, ""), 80) || null : null,
            picture: own ?? poster,
            at: round(at),
            length: round(Math.max(0, length)),
            in: round(num(c.in) ?? 0),
            out: round(num(c.out) ?? 0),
            speed: num(c.speed) ?? 1,
            pitch: num(c.pitch),
            is_new: change !== "viewed" && had !== null && !had.has(c.id),
        };
    };
    let t = 0;
    const mainClips = main.map((c) => {
        const len = ((num(c.out) ?? 0) - (num(c.in) ?? 0)) / (num(c.speed) || 1);
        const s = shape(c, t, len);
        t += len;
        return s;
    });
    // overlay clips by layer (`track`, 0 when absent, section 39), lowest first
    const layers = new Map<number, EditClip[]>();
    let end = t;
    for (const c of overlay) {
        const at = num(c.at) ?? 0;
        const len = ((num(c.out) ?? 0) - (num(c.in) ?? 0)) / (num(c.speed) || 1);
        end = Math.max(end, at + len);
        const k = Math.max(0, Math.floor(num(c.track) ?? 0));
        const list = layers.get(k) ?? [];
        list.push(shape(c, at, len));
        layers.set(k, list);
    }
    const tracks: { name: "main" | "overlay"; index: number; clips: EditClip[] }[] = [{ name: "main", index: 0, clips: mainClips }];
    for (const k of [...layers.keys()].sort((a, b) => a - b)) tracks.push({ name: "overlay", index: k, clips: layers.get(k)!.sort((a, b) => a.at - b.at) });
    const canvas = obj(timeline.canvas);
    return {
        type: "edit",
        project_id: id,
        title: str(project.title),
        revision: num(project.revision),
        duration: round(num(project.duration) ?? end),
        width: num(canvas?.w),
        height: num(canvas?.h),
        change,
        tracks,
        render: render ? { status: String(render.status ?? ""), progress: num(render.progress), post_id: rendered ? (rows.get(rendered)?.post_key ?? rendered) : null } : null,
    };
}

// Every post id the cards of these steps name, for the message's `posts` map.
export function cardPostIds(steps: { calls?: ToolCall[] }[]): string[] {
    const out: string[] = [];
    for (const s of steps) for (const c of s.calls ?? []) if (c.card) out.push(...postIdsOf(c.card));
    return [...new Set(out)];
}

export function postIdsOf(card: ToolCard): string[] {
    switch (card.type) {
        case "search":
            return card.hits.map((h) => h.post_id);
        case "look":
        case "saved":
        case "facts":
            return card.post_ids;
        case "edit":
            return [
                ...card.tracks.flatMap((t) => t.clips.map((c) => c.post_id).filter((x): x is string => x !== null)),
                ...(card.render?.post_id ? [card.render.post_id] : []),
            ];
        case "job":
            return card.post_id ? [card.post_id] : [];
        case "files":
            return card.post_id ? [card.post_id] : [];
        case "emotes":
            return card.emotes.map((e) => e.library_id).filter((x): x is string => x !== null);
        case "agents":
            return card.agents.flatMap((a) => a.post_ids);
        default:
            return [];
    }
}
