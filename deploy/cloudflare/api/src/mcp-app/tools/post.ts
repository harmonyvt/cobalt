// show_post: one post, its files, its share link and where it says something (MCP-APP-CONTRACT.md section 4).
import * as z from "zod";
import { OpError } from "../../registry/op";
import { PostOut } from "../shapes";
import { timecode } from "../../transcripts";
import type { AppTool } from "../types";
import { arr, clock, cut, num, plural, readPosts, rec, signThumbs, str, summaryOf } from "./common";

const Input = z.object({ id: z.string().min(1).max(2048) });

// a gallery saved from a picker holds at most 20 items; every file is listed
const FILES_MAX = 100;
const EXCERPT_CHARS = 280;
// the first lines of speech: the start of the clip is what an excerpt is for
const EXCERPT_SECONDS = 45;

export const hiddenPost = (id: string) => new OpError(409, "error.library.hidden", `post ${id} is hidden (library_status unhides it)`);
export const notFound = (id: string) => new OpError(404, "error.library.not_found", `no post with id ${id}`);

// "id · role · name · type · public url / share page / private link", one file per line
const fileLine = (f: z.infer<typeof PostOut>["post"]["file_list"][number]) =>
    [
        f.id,
        f.role,
        f.name,
        f.content_type,
        f.url ? `url ${f.url}` : null,
        f.share_url ? `share ${f.share_url}` : null,
        f.private_url ? `private ${f.private_url}` : null,
        f.private_file_url ? `private file ${f.private_file_url}` : null,
    ]
        .filter(Boolean)
        .join(" · ");

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
        if (post.hidden === true) throw hiddenPost(input.id);
        const id = str(post.id) ?? input.id;
        const isVideo = post.kind === "video";
        const [read, transcript] = await Promise.all([
            readPosts(ctx.op, { posts: [id] }),
            isVideo && ctx.has("library.transcript")
                ? ctx
                      .call("library.transcript", {
                          key: id,
                          from: 0,
                          to: EXCERPT_SECONDS,
                      })
                      .catch(() => null)
                : Promise.resolve(null),
        ]);
        const summary = summaryOf(post, read);
        if (!summary) throw notFound(input.id);
        // a post that is not public plays through signed one-hour links (in the result's _meta, never the text or structuredContent)
        await signThumbs(ctx, read, [summary]);
        let signed = summary.status !== "public" && !!read.posts.get(id)?.thumb_source;

        const t = rec(transcript);
        const timed =
            t.state === "done"
                ? arr(t.lines).flatMap((l) => {
                      const line = rec(l);
                      const text = str(line.text)?.trim() ?? "";
                      const start = num(line.start);
                      return text && start !== null ? [{ start, end: num(line.end) ?? start, timecode: timecode(start), text }] : [];
                  })
                : [];
        const excerpt = timed.length > 0 ? cut(timed.map((l) => l.text).join(" "), EXCERPT_CHARS) : null;
        // the lines the excerpt was cut from, with their times, as far as EXCERPT_CHARS of text goes
        let room = EXCERPT_CHARS;
        const transcriptLines = timed.filter((l) => {
            if (room <= 0) return false;
            room -= l.text.length + 1;
            return true;
        });

        const files = arr(post.files).map(rec);
        const fileList = (
            await Promise.all(
                files.slice(0, FILES_MAX).map(async (f) => {
                    const fid = str(f.id);
                    if (!fid) return [];
                    // a file of this post that is here and not public (read.files only holds posts that are not hidden)
                    const facts = read.files.get(fid);
                    const priv = !!facts && facts.private && f.public !== true;
                    if (priv) signed = true;
                    if (priv) {
                        await ctx.preview(fid, fid, "url");
                        if (facts!.has_poster) await ctx.preview(fid, fid, "poster");
                    }
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
                            name: str(f.name),
                            role: str(f.role),
                            // the same links library.post gave this caller; a hidden post never gets here
                            share_url: str(f.share_url),
                            private_url: str(f.private_url),
                            private_file_url: str(f.private_file_url),
                        },
                    ];
                }),
            )
        ).flat();
        // the first file with a share page (the lead file of a video or picture)
        const shareUrl = read.posts.get(id)?.share_url ?? files.map((f) => str(f.share_url)).find(Boolean) ?? null;
        const privateUrl = files.map((f) => str(f.private_url)).find(Boolean) ?? null;
        const privateFileUrl = files.map((f) => str(f.private_file_url)).find(Boolean) ?? null;
        const caption = str(post.caption);
        const structured = {
            view: "post" as const,
            post: {
                ...summary,
                source_link: str(post.link),
                caption,
                transcript_excerpt: excerpt,
                transcript_lines: transcriptLines,
                share_url: shareUrl,
                private_url: privateUrl,
                private_file_url: privateFileUrl,
                preview_expires_at: signed ? ctx.previewExpires : null,
                file_list: fileList,
            },
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
            transcriptLines.length > 0
                ? `Says (library_transcript has every line with its time):\n${transcriptLines.map((l) => `[${l.timecode}] ${cut(l.text, EXCERPT_CHARS)}`).join("\n")}`
                : null,
            fileList.length > 0 ? `Files:\n${fileList.map(fileLine).join("\n")}` : null,
        ]
            .filter(Boolean)
            .join("\n");
        return { text, structured };
    },
};
