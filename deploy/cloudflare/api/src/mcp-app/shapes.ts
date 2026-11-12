// The MCP app's wire shapes (MCP-APP-CONTRACT.md section 3): what each app tool puts in `structuredContent`, and what
// the widgets read. One file, so the tools and the widgets cannot drift. Every object is loose (extra fields pass), every
// "may be missing" value is nullable, and every result carries `view`, the widget view that draws it.
import * as z from "zod";

export const VIEWS = ["search", "post", "edit", "collections", "links", "webp", "upload", "save", "terminal"] as const;
export type View = (typeof VIEWS)[number];
export const widgetUri = (view: View) => `ui://capystore/${view}.html`;

const iso = z.string().describe("ISO 8601 time");
const url = z.string().nullable();

// public: it has public links; private: its own private link; off: no link
export const PostStatus = z.enum(["public", "private", "off"]);

export const PostSummary = z.looseObject({
    id: z.string(),
    title: z.string(),
    kind: z.enum(["video", "image", "gallery"]),
    // a public poster or picture; null when the post has none a browser can load (private or off: its signed link is in the result's _meta under the post's id)
    thumb_url: url,
    duration_s: z.number().nullable(),
    saved_at: iso,
    source_host: z.string().nullable(),
    status: PostStatus,
    files: z.number().int(),
    // the lead file's size in bytes; null when unknown
    bytes: z.number().nullable(),
});
export type PostSummary = z.infer<typeof PostSummary>;

export const PostFile = z.looseObject({
    id: z.string(),
    kind: z.enum(["video", "image"]),
    content_type: z.string(),
    // the public file; null when it is not public
    url,
    width: z.number().nullable(),
    height: z.number().nullable(),
    duration_s: z.number().nullable(),
    bytes: z.number().nullable(),
    // the file's name and role (original, webp, frame...), as library.post names them
    name: z.string().nullable(),
    role: z.string().nullable(),
    // its share page (share.capybaraharmony.com/<name>) while public
    share_url: url,
    // its own private link while it has one, and that link's direct file
    private_url: url,
    private_file_url: url,
});

// A search or list row: a post summary plus what the search knew about it.
export const SearchItem = PostSummary.extend({
    // the original link and the roast caption title, as library.list gave them
    source_link: url,
    caption: z.string().nullable(),
    // meaning search only: its score, up to 3 tags closest to the query, and where it is said in the video
    score: z.number().nullable(),
    why: z.array(z.string()).nullable(),
    // at/end in seconds; timecode is at as "m:ss" (or "h:mm:ss") to cite the moment
    said: z.array(z.looseObject({ at: z.number(), end: z.number(), timecode: z.string(), text: z.string(), match: z.string() })).nullable(),
});

export const SearchOut = z.looseObject({
    view: z.literal("search"),
    query: z.string(),
    // "meaning": the embedding search answered; "text": the title/link match did (search off or waking up); "list": no
    // query, the library newest first (`query` is then "")
    mode: z.enum(["meaning", "text", "list"]),
    total: z.number().int(),
    items: z.array(SearchItem),
});

export const PostOut = z.looseObject({
    view: z.literal("post"),
    post: PostSummary.extend({
        source_link: url,
        caption: z.string().nullable(),
        transcript_excerpt: z.string().nullable(),
        // the same opening lines with their times (start/end in seconds, timecode "m:ss"); empty without a transcript
        transcript_lines: z.array(z.object({ start: z.number(), end: z.number(), timecode: z.string(), text: z.string() })),
        share_url: url,
        private_url: url,
        // that private link's direct file (the bytes), while it has one
        private_file_url: url,
        // when the signed preview links of this result stop working (ISO 8601); null when none was signed
        preview_expires_at: iso.nullable(),
        file_list: z.array(PostFile),
    }),
});

export const EditClip = z.looseObject({
    id: z.string(),
    name: z.string(),
    // where it sits on the timeline, in seconds
    start: z.number(),
    end: z.number(),
    // the part of the source it plays, in source seconds
    in: z.number().nullable(),
    out: z.number().nullable(),
    speed: z.number().nullable(),
    muted: z.boolean().nullable(),
    poster_url: url,
    // what plays: the source file (a public URL; null when `private`: its signed one-hour link is in the result's _meta), its kind and size
    video_url: url,
    media_kind: z.enum(["video", "image"]).nullable(),
    private: z.boolean(),
    src_w: z.number().nullable(),
    src_h: z.number().nullable(),
    // the source file's id; when it is `private` its signed preview link is in the result's _meta under this id
    file_id: z.string().nullable(),
});
export const EditOverlay = z.looseObject({
    id: z.string(),
    name: z.string(),
    // image, video, text, cutout...
    kind: z.string(),
    start: z.number(),
    end: z.number(),
    // the part of the source it plays (source seconds), and where it sits on the canvas as fractions of the canvas width
    // (x, w) and height (y, h); h is worked out from the source's shape, null when that is unknown
    in: z.number().nullable(),
    out: z.number().nullable(),
    frame: z.looseObject({ x: z.number(), y: z.number(), w: z.number(), h: z.number().nullable() }).nullable(),
    opacity: z.number().nullable(),
    // what draws it: the source file (public URL; null when `private`, see `file_id`), its kind and poster
    url,
    media_kind: z.enum(["video", "image"]).nullable(),
    poster_url: url,
    private: z.boolean(),
    // the source file's id (its signed preview link is in the result's _meta under this id when `private`)
    file_id: z.string().nullable(),
});
export const EditRender = z.looseObject({
    status: z.enum(["queued", "running", "done", "error"]),
    progress: z.number().nullable(),
    post_id: z.string().nullable(),
    poster_url: url,
    // the rendered file: a public URL; null while it is not done or `private` (signed link in _meta under `file_id`)
    video_url: url,
    private: z.boolean(),
    // true when the render is of an older revision than the project's
    stale: z.boolean(),
    // the rendered file's id (its signed preview link is in the result's _meta under this id when `private`)
    file_id: z.string().nullable(),
});
export const EditProject = z.looseObject({
    id: z.string(),
    title: z.string(),
    revision: z.number().int(),
    duration_s: z.number(),
    canvas: z.looseObject({ w: z.number(), h: z.number(), fps: z.number() }),
    main: z.array(EditClip),
    overlay: z.array(EditOverlay),
    render: EditRender.nullable(),
    // when the signed preview links in this project stop working (ISO 8601); null when none was signed
    preview_expires_at: iso.nullable(),
    // the timeline as the editor holds it (what edits_update takes back); ids and numbers, no names or pictures
    timeline: z.unknown().nullable(),
});
export const EditOut = z.looseObject({
    view: z.literal("edit"),
    // one project's timeline, or null when `projects` is a list to pick from
    project: EditProject.nullable(),
    projects: z.array(
        z.looseObject({ id: z.string(), title: z.string(), revision: z.number().int(), duration_s: z.number(), rendered: z.boolean(), poster_url: url }),
    ),
});

export const ShareLink = z.looseObject({
    id: z.string(),
    url: z.string(),
    title: z.string().nullable(),
    files: z.number().int(),
    private: z.boolean(),
    created_at: iso,
    // up to 4 public pictures of its posts
    thumbs: z.array(z.string()),
    // the name of the collection it is in
    collection: z.string().nullable(),
    // the posts in it, and a private link's direct file links (null: a file that is gone), as links.list gave them
    post_ids: z.array(z.string()).nullable(),
    file_urls: z.array(z.string().nullable()).nullable(),
});
export const LinksOut = z.looseObject({
    view: z.literal("links"),
    total: z.number().int(),
    links: z.array(ShareLink),
    // set by create_share_link: the id of the link just made
    created: z.string().nullable(),
});

export const CollectionsOut = z.looseObject({
    view: z.literal("collections"),
    total: z.number().int(),
    collections: z.array(
        z.looseObject({
            id: z.string(),
            name: z.string(),
            links: z.array(z.looseObject({ id: z.string(), url: z.string(), files: z.number().int(), private: z.boolean() })),
            posts: z.number().int(),
            // up to 8 public pictures of its posts
            thumbs: z.array(z.string()),
            // every live link and post in it, as collections.list gave them
            link_ids: z.array(z.string()).nullable(),
            post_ids: z.array(z.string()).nullable(),
        }),
    ),
});

// A job the widget follows with `job_status`.
export const JobState = z.enum(["running", "done", "error"]);
export const JobOut = z.looseObject({
    job: z.string(),
    state: JobState,
    // 0 to 1
    progress: z.number().nullable(),
    error: z.string().nullable(),
    // the post the job made, when done
    post: PostSummary.nullable(),
    share_url: url,
    // done: the made file's id and the post's id, when the job says them
    file_id: z.string().nullable(),
    post_id: z.string().nullable(),
    // waiting: jobs ahead of it in the line
    queue_ahead: z.number().nullable(),
    // a finished render: its file's size and shape
    file: z.looseObject({ kind: z.string().nullable(), bytes: z.number().nullable(), width: z.number().nullable(), height: z.number().nullable(), seconds: z.number().nullable() }).nullable(),
    // an agent job (agent:<id>): its name, what it did last, its report and the posts it showed
    agent: z.looseObject({ id: z.string().nullable(), name: z.string().nullable(), activity: z.string().nullable(), result: z.string().nullable(), post_ids: z.array(z.string()).nullable() }).nullable(),
});

export const WebpOut = z.looseObject({
    view: z.literal("webp"),
    // pick: no start/end were given, nothing ran, the widget shows the range picker and calls convert_to_webp again
    state: z.enum(["pick", "running", "done", "error"]),
    job: z.string().nullable(),
    progress: z.number().nullable(),
    error: z.string().nullable(),
    source: z.looseObject({ id: z.string(), title: z.string(), duration_s: z.number().nullable(), poster_url: url, url }),
    range: z.looseObject({ start: z.number(), end: z.number() }).nullable(),
    width: z.union([z.literal(320), z.literal(480)]),
    quality: z.enum(["low", "med", "high"]),
    post: PostSummary.nullable(),
    share_url: url,
});

export const UploadOut = z.looseObject({
    view: z.literal("upload"),
    uploads: z.array(z.looseObject({ name: z.string(), upload_url: z.string(), expires_at: iso, curl: z.string() })),
    max_bytes: z.number().int(),
    // file extensions the upload takes
    accept: z.array(z.string()),
    public: z.boolean(),
});

export const SaveOut = z.looseObject({
    view: z.literal("save"),
    state: JobState,
    job: z.string().nullable(),
    url: z.string(),
    // the engine the caller picked, so a retry keeps it
    engine: z.enum(["auto", "cobalt", "ytdlp"]).nullable(),
    error: z.string().nullable(),
    post: PostSummary.nullable(),
    // the share page of the saved post, when it is public
    share_url: url,
    // the save's studio session id and how many saves the thread has left today, as library.save gave them
    save_id: z.string().nullable(),
    saves_left_today: z.number().nullable(),
});

// The workbench box tools (box_run, box_pull, box_save: registry ops, not app tools) drawn as a terminal
// (src/mcp-app/follow.ts). Each is the op's own JSON plus `view`, `tool` and `sleeps_at`, so a reader of the plain
// structuredContent loses nothing.
const BoxCommon = {
    view: z.literal("terminal"),
    // when the box sleeps and its files are wiped if no other box call comes first (2 minutes after this one); null: unknown
    sleeps_at: iso.nullable(),
};
export const TerminalRun = z.looseObject({
    ...BoxCommon,
    tool: z.literal("run"),
    cmd: z.string(),
    code: z.number(),
    stdout: z.string(),
    stderr: z.string(),
    timed_out: z.boolean(),
    // how long the command ran; null from an older op
    ms: z.number().nullable(),
    // the stream was over 8 KB: its middle was cut ("… (N bytes cut) …")
    stdout_cut: z.boolean(),
    stderr_cut: z.boolean(),
});
export const TerminalPull = z.looseObject({
    ...BoxCommon,
    tool: z.literal("pull"),
    files: z.array(
        z.looseObject({
            path: z.string(),
            file_id: z.string(),
            content_type: z.string().nullable(),
            bytes: z.number(),
            seconds: z.number().nullable(),
            width: z.number().nullable(),
            height: z.number().nullable(),
        }),
    ),
});
export const TerminalSave = z.looseObject({
    ...BoxCommon,
    tool: z.literal("save"),
    post_id: z.string(),
    kind: z.enum(["video", "image"]),
    bytes: z.number(),
    processing: z.boolean(),
    public_url: url,
    // the new post as search and show_post show it (a private one's signed thumbnail in _meta); null when it could not be read
    post: PostSummary.nullable(),
});
export const TerminalOut = z.discriminatedUnion("tool", [TerminalRun, TerminalPull, TerminalSave]);
