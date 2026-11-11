// show_edit: one editor project's timeline, or the list of projects to pick from (MCP-APP-CONTRACT.md section 4).
import * as z from "zod";
import { EditOut } from "../shapes";
import type { AppTool, AppToolCtx } from "../types";
import { arr, clock, cut, int, listText, num, plural, readPosts, rec, round, seconds, str, type PostsRead } from "./common";

const Input = z.object({
    id: z.string().min(1).max(200).optional(),
    query: z.string().min(1).max(200).optional(),
});

// edits.list answered every project; so does this, up to a hundred
const PROJECTS_MAX = 100;

type Out = z.infer<typeof EditOut>;
type Project = NonNullable<Out["project"]>;

// the editor's render states (preparing, rendering, finishing are all "running")
function renderState(status: unknown): "queued" | "running" | "done" | "error" {
    switch (status) {
        case "queued":
            return "queued";
        case "done":
            return "done";
        case "error":
        case "cancelled":
            return "error";
        default:
            return "running";
    }
}

// a poster is a public media URL; anything else is not a picture a browser can load
const posterOf = (v: unknown): string | null => {
    const s = str(v);
    return s && /^https?:\/\//i.test(s) ? s : null;
};

const overlayKind = (source: Record<string, unknown>): string => {
    const kind = str(source.kind);
    if (kind === "video" || kind === "gif") return kind;
    if (/cutout/i.test(str(source.name) ?? "")) return "cutout";
    return "image";
};

// The source files a project uses (clips and overlays), by file id.
function sourceIds(got: Record<string, unknown>): string[] {
    const timeline = rec(got.timeline);
    return [...arr(timeline.main), ...arr(timeline.overlay)].map((x) => str(rec(x).item)).filter((x): x is string => !!x);
}

async function projectOf(ctx: AppToolCtx, got: Record<string, unknown>, read: PostsRead): Promise<Project> {
    const timeline = rec(got.timeline);
    const sources = rec(got.sources);
    // A source's name and picture are shown only for a post that is in the library's view: one that is hidden or gone gets a
    // neutral name, and only a public post's picture is a link a browser can load.
    const seen = (item: string | null) => (item ? read.postOfFile.get(item) : undefined);
    const nameOf = (item: string | null, src: Record<string, unknown>, fallback: string) => (seen(item) ? str(src.name) || fallback : fallback);
    const posterFor = (item: string | null, src: Record<string, unknown>) => {
        const post = seen(item);
        return post && read.posts.get(post)?.status === "public" ? posterOf(src.poster_url) : null;
    };
    const canvas = rec(timeline.canvas);
    // What plays for a source file: its public URL, or a signed one-hour preview for one that is not public (section 9). Only a
    // file of a post that is in the library's view; a hidden or gone one plays nothing.
    let signed = false;
    const playable = async (item: string | null, src: Record<string, unknown>) => {
        const facts = item && seen(item) ? read.files.get(item) : undefined;
        if (!facts)
            return {
                url: null,
                poster: null,
                private: false,
                file_id: null as string | null,
                kind: null,
                w: null,
                h: null,
            };
        let url = facts.url;
        let poster = posterFor(item, src);
        if (facts.private) {
            signed = true;
            // the signed links ride in _meta under the file's id
            url = null;
            poster = null;
            await ctx.preview(facts.id, facts.id, "url");
            if (facts.has_poster) await ctx.preview(facts.id, facts.id, "poster");
        }
        return {
            url,
            poster,
            private: facts.private,
            file_id: facts.id as string | null,
            kind: facts.kind,
            w: facts.width,
            h: facts.height,
        };
    };
    let t = 0;
    const mainSrc = await Promise.all(arr(timeline.main).map((c) => playable(str(rec(c).item), rec(sources[str(rec(c).item) ?? ""]))));
    const main = arr(timeline.main).map((c, i) => {
        const clip = rec(c);
        const src = rec(sources[str(clip.item) ?? ""]);
        const from = num(clip.in) ?? 0;
        const to = num(clip.out) ?? from;
        const speed = num(clip.speed) && num(clip.speed)! > 0 ? num(clip.speed)! : 1;
        const start = round(t);
        t += Math.max(0, (to - from) / speed);
        return {
            id: str(clip.id) ?? `clip${i + 1}`,
            name: nameOf(str(clip.item), src, `clip ${i + 1}`),
            start,
            end: round(t),
            in: num(clip.in),
            out: num(clip.out),
            speed: num(clip.speed),
            muted: typeof clip.muted === "boolean" ? clip.muted : null,
            poster_url: mainSrc[i]!.poster,
            video_url: mainSrc[i]!.url,
            media_kind: mainSrc[i]!.kind,
            private: mainSrc[i]!.private,
            src_w: mainSrc[i]!.w,
            src_h: mainSrc[i]!.h,
            file_id: mainSrc[i]!.file_id,
        };
    });
    const ovSrc = await Promise.all(arr(timeline.overlay).map((o) => playable(str(rec(o).item), rec(sources[str(rec(o).item) ?? ""]))));
    const cw = num(canvas.w) ?? 0;
    const ch = num(canvas.h) ?? 0;
    const overlay = arr(timeline.overlay).map((o, i) => {
        const ov = rec(o);
        const src = rec(sources[str(ov.item) ?? ""]);
        const at = num(ov.at) ?? 0;
        return {
            id: str(ov.id) ?? `overlay${i + 1}`,
            name: nameOf(str(ov.item), src, `overlay ${i + 1}`),
            kind: overlayKind(src),
            start: round(at),
            end: round(at + Math.max(0, (num(ov.out) ?? 0) - (num(ov.in) ?? 0))),
            in: num(ov.in),
            out: num(ov.out),
            frame: (() => {
                const f = rec(ov.frame);
                const x = num(f.x);
                const y = num(f.y);
                const w = num(f.w);
                if (x === null || y === null || w === null) return null;
                const sw = ovSrc[i]!.w;
                const sh = ovSrc[i]!.h;
                // the editor's rule: height = width * canvas aspect * source height / source width
                return {
                    x,
                    y,
                    w,
                    h: sw && sh && cw && ch ? round((w * cw * sh) / (ch * sw), 4) : null,
                };
            })(),
            opacity: num(ov.opacity),
            url: ovSrc[i]!.url,
            media_kind: ovSrc[i]!.kind,
            poster_url: ovSrc[i]!.poster,
            private: ovSrc[i]!.private,
            file_id: ovSrc[i]!.file_id,
        };
    });
    const revision = int(got.revision);
    const r = got.render ? rec(got.render) : null;
    let render: Project["render"] = null;
    if (r) {
        const itemId = str(r.item_id);
        const postId = itemId ? (read.postOfFile.get(itemId) ?? null) : null;
        render = {
            status: renderState(r.status),
            progress: num(r.progress),
            post_id: postId,
            // the poster of a post that is public only
            poster_url: postId && read.posts.get(postId)?.status === "public" ? posterOf(r.poster_url) : null,
            video_url: null,
            private: false,
            stale: (num(r.revision) ?? revision) < revision,
            file_id: null,
        };
        const rf = itemId ? read.files.get(itemId) : undefined;
        if (rf && render && r.status === "done") {
            if (rf.private) {
                signed = true;
                await ctx.preview(rf.id, rf.id, "url");
                render.private = true;
                if (rf.has_poster) await ctx.preview(rf.id, rf.id, "poster");
            } else render.video_url = rf.url;
            render.file_id = rf.id;
        }
    }
    return {
        id: str(got.id) ?? "",
        title: str(got.title) ?? "untitled edit",
        revision,
        duration_s: round(num(got.duration) ?? t),
        canvas: {
            w: num(canvas.w) ?? 0,
            h: num(canvas.h) ?? 0,
            fps: num(canvas.fps) ?? 30,
        },
        main,
        overlay,
        render,
        preview_expires_at: signed ? ctx.previewExpires : null,
        timeline: got.timeline ?? null,
    };
}

function projectText(p: Project): string {
    const head = `Edit “${p.title}” · ${p.id} · revision ${p.revision} · ${seconds(p.duration_s)} · ${p.canvas.w}x${p.canvas.h} at ${p.canvas.fps} fps`;
    const clips = listText(
        `${plural(p.main.length, "clip")} on the main track:`,
        p.main.map(
            (c) => `${cut(c.name, 60)} · ${clock(c.start)}–${clock(c.end)}${c.speed && c.speed !== 1 ? ` · ${c.speed}x` : ""}${c.muted ? " · muted" : ""}`,
        ),
        p.main.length,
        50,
    );
    const overlays =
        p.overlay.length === 0
            ? "No overlays."
            : `${plural(p.overlay.length, "overlay")}: ${p.overlay
                  .slice(0, 5)
                  .map((o) => `${cut(o.name, 30)} (${o.kind}) ${clock(o.start)}–${clock(o.end)}`)
                  .join("; ")}${p.overlay.length > 5 ? "; …" : ""}`;
    const r = p.render;
    const render = !r
        ? "Not rendered yet."
        : r.status === "done"
          ? `Rendered${r.stale ? ", but the edit changed since (render again to update the video)" : ""}${r.post_id ? `: post ${r.post_id}` : ""}.`
          : r.status === "error"
            ? "The last render failed."
            : `Rendering${r.progress !== null ? ` (${Math.round(r.progress * 100)}%)` : ""}.`;
    // the timeline itself, so an agent can change it and hand it to edits_update (it has no names or pictures)
    const timeline = p.timeline ? `Timeline (for edits_update):\n${JSON.stringify(p.timeline)}` : null;
    return [head, clips, overlays, render, timeline].filter(Boolean).join("\n");
}

export const showEdit: AppTool<z.infer<typeof Input>> = {
    name: "show_edit",
    title: "Show an edit",
    description:
        "Show a video editor project as a timeline: its clips, overlays and render state. Give an id, or part of a title; with neither (or several matches) it lists the projects to pick from.",
    input: Input,
    output: EditOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "edit",
    async run(ctx, input) {
        let id = input.id ?? null;
        let list: Record<string, unknown>[] | null = null;
        if (!id) {
            list = arr(await ctx.call("edits.list", {})).map(rec);
            const q = input.query?.toLowerCase();
            if (q) list = list.filter((p) => (str(p.title) ?? "").toLowerCase().includes(q));
            if (q && list.length === 1) id = str(list[0]!.id);
        }
        if (id) {
            const got = rec(await ctx.call("edits.get", { id }));
            const itemId = str(rec(got.render).item_id);
            const read = await readPosts(ctx.op, {
                files: [...sourceIds(got), ...(itemId ? [itemId] : [])],
            });
            const project = await projectOf(ctx, got, read);
            return {
                text: projectText(project),
                structured: { view: "edit", project, projects: [] } satisfies Out,
            };
        }
        const shown = (list ?? []).slice(0, PROJECTS_MAX);
        const items = shown.map((p) => str(rec(p.render).item_id)).filter((x): x is string => !!x);
        const read = await readPosts(ctx.op, { files: items });
        const projects = await Promise.all(
            shown.map(async (p) => {
                const render = p.render ? rec(p.render) : null;
                const itemId = render ? str(render.item_id) : null;
                const postId = itemId ? (read.postOfFile.get(itemId) ?? null) : null;
                if (itemId && postId && read.posts.get(postId)?.status !== "public" && read.files.get(itemId)?.private && read.files.get(itemId)?.has_poster) await ctx.preview(str(p.id) ?? "", itemId, "poster");
                return {
                    id: str(p.id) ?? "",
                    title: str(p.title) ?? "untitled edit",
                    revision: int(p.revision),
                    duration_s: round(num(p.duration) ?? 0),
                    rendered: render?.status === "done",
                    // a private render's poster is a signed link in _meta under this project's id
                    poster_url: postId && read.posts.get(postId)?.status === "public" ? posterOf(render?.poster_url) : null,
                };
            }),
        );
        const total = (list ?? []).length;
        const count =
            total === 0
                ? input.query
                    ? `No edit projects match “${input.query}”.`
                    : "There are no edit projects yet."
                : `${plural(total, "edit project")}${input.query ? ` match “${input.query}”` : ""}; pick one by id.`;
        const text =
            total === 0
                ? count
                : listText(
                      count,
                      projects.map((p) => `${cut(p.title, 60)} · ${seconds(p.duration_s)} · ${p.rendered ? "rendered" : "not rendered"} · ${p.id}`),
                      total,
                      PROJECTS_MAX,
                  );
        return {
            text,
            structured: { view: "edit", project: null, projects } satisfies Out,
        };
    },
};
