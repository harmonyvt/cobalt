// show_post: one post, its files, its share link and where it says something (MCP-APP-CONTRACT.md section 4).
import * as z from "zod";
import { OpError } from "../../registry/op";
import { PostOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, clock, cut, num, plural, readPosts, rec, str, summaryOf } from "./common";

const Input = z.object({ id: z.string().min(1).max(2048) });

const FILES_MAX = 24;
const EXCERPT_CHARS = 280;
// the first lines of speech: the start of the clip is what an excerpt is for
const EXCERPT_SECONDS = 45;

export const notFound = (id: string) => new OpError(404, "error.library.not_found", `no post with id ${id}`);

export const showPost: AppTool<z.infer<typeof Input>> = {
    name: "show_post",
    title: "Show a post",
    description: "Open one post from the capystore library: its title, caption, files, share link and the start of what is said in it.",
    input: Input,
    output: PostOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "post",
    async run(ctx, input) {
        const post = rec(await ctx.call("library.post", { id: input.id }));
        // a hidden post answers with hidden: true; it is not shown here
        if (post.hidden === true) throw notFound(input.id);
        const id = str(post.id) ?? input.id;
        const isVideo = post.kind === "video";
        const [read, transcript] = await Promise.all([
            readPosts(ctx.op, { posts: [id] }),
            isVideo && ctx.has("library.transcript")
                ? ctx.call("library.transcript", { key: id, from: 0, to: EXCERPT_SECONDS }).catch(() => null)
                : Promise.resolve(null),
        ]);
        const summary = summaryOf(post, read);
        if (!summary) throw notFound(input.id);

        const t = rec(transcript);
        const lines = t.state === "done" ? arr(t.lines).map((l) => str(rec(l).text)?.trim() ?? "").filter(Boolean) : [];
        const excerpt = lines.length > 0 ? cut(lines.join(" "), EXCERPT_CHARS) : null;

        const files = arr(post.files).map(rec);
        const fileList = files.slice(0, FILES_MAX).flatMap((f) => {
            const fid = str(f.id);
            if (!fid) return [];
            return [
                {
                    id: fid,
                    kind: f.kind === "video" ? ("video" as const) : ("image" as const),
                    content_type: str(f.content_type) ?? "",
                    url: f.public === true ? str(f.url) : null,
                    width: num(f.width),
                    height: num(f.height),
                    duration_s: num(f.duration),
                    bytes: num(f.bytes),
                },
            ];
        });
        // the first file with a share page (the lead file of a video or picture)
        const shareUrl = read.posts.get(id)?.share_url ?? files.map((f) => str(f.share_url)).find(Boolean) ?? null;
        const privateUrl = files.map((f) => str(f.private_url)).find(Boolean) ?? null;
        const caption = str(post.caption);
        const structured = {
            view: "post" as const,
            post: { ...summary, source_link: str(post.link), caption, transcript_excerpt: excerpt, share_url: shareUrl, private_url: privateUrl, file_list: fileList },
        } satisfies z.infer<typeof PostOut>;

        const facts = [
            summary.kind,
            summary.duration_s !== null ? clock(summary.duration_s) : null,
            plural(summary.files, "file"),
            summary.status === "public" ? "public" : summary.status === "private" ? "private link only" : "not shared",
        ].filter(Boolean);
        const text = [
            `${summary.title} · ${summary.id}`,
            facts.join(" · "),
            caption && caption !== summary.title ? `Caption: ${caption}` : null,
            str(post.link) ? `Saved from: ${str(post.link)}` : summary.source_host ? `Saved from: ${summary.source_host}` : null,
            shareUrl ? `Share link: ${shareUrl}` : privateUrl ? `Private link: ${privateUrl}` : "No share link yet.",
            excerpt ? `Says: ${excerpt}` : null,
        ]
            .filter(Boolean)
            .join("\n");
        return { text, structured };
    },
};
