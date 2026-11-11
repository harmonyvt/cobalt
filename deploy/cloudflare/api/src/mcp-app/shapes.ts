// The MCP app's wire shapes (MCP-APP-CONTRACT.md section 3): what each app tool puts in `structuredContent`, and what
// the widgets read. One file, so the tools and the widgets cannot drift. Every object is loose (extra fields pass), every
// "may be missing" value is nullable, and every result carries `view`, the widget view that draws it.
import * as z from "zod";

export const VIEWS = ["search", "post", "edit", "collections", "links", "webp", "upload", "save"] as const;
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
    // a public poster or picture; null when the post has none a browser can load (private or off)
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
});

export const SearchOut = z.looseObject({
    view: z.literal("search"),
    query: z.string(),
    // "meaning": the embedding search answered; "text": the title/link match did (search off or waking up)
    mode: z.enum(["meaning", "text"]),
    total: z.number().int(),
    items: z.array(PostSummary),
});

export const PostOut = z.looseObject({
    view: z.literal("post"),
    post: PostSummary.extend({
        source_link: url,
        caption: z.string().nullable(),
        transcript_excerpt: z.string().nullable(),
        share_url: url,
        private_url: url,
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
});
export const EditOverlay = z.looseObject({
    id: z.string(),
    name: z.string(),
    // image, video, text, cutout...
    kind: z.string(),
    start: z.number(),
    end: z.number(),
});
export const EditRender = z.looseObject({
    status: z.enum(["queued", "running", "done", "error"]),
    progress: z.number().nullable(),
    post_id: z.string().nullable(),
    poster_url: url,
    // true when the render is of an older revision than the project's
    stale: z.boolean(),
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
});
