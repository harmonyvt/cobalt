// What the job-shaped tools share: reading a registry job, and the post a finished job made.
import type { PostSummary } from "../shapes";
import type { AppToolCtx } from "../types";
import { readPosts, rec, str, summaryOf, num, type Rec } from "./common";

export type Phase = { state: "running" | "done" | "error"; progress: number | null; error: string | null };

// A registry job (make.webp, jobs.wait): opening, queued and running are all "running"; a cancelled job ended without a result.
export function phaseOf(job: unknown): Phase {
    const j = rec(job);
    const status = str(j.status);
    const progress = num(j.progress);
    if (status === "done") return { state: "done", progress: 1, error: null };
    if (status === "error" || status === "cancelled") return { state: "error", progress, error: str(j.error) ?? (status === "cancelled" ? "cancelled" : "error.api.generic") };
    return { state: "running", progress, error: null };
}

export type MadePost = { post: PostSummary | null; share_url: string | null };

// The post a job made, as a PostSummary, and its share page when it has one. Null post: not found, or hidden.
export async function madePost(ctx: AppToolCtx, postId: string | null, jobShare: string | null = null): Promise<MadePost> {
    if (!postId) return { post: null, share_url: jobShare };
    let record: Rec;
    try {
        record = rec(await ctx.call("library.post", { id: postId }));
    } catch {
        return { post: null, share_url: jobShare };
    }
    if (record.hidden === true) return { post: null, share_url: null };
    const read = await readPosts(ctx.op, { posts: [postId] });
    const post = summaryOf(record, read);
    return { post, share_url: post ? (jobShare ?? read.posts.get(postId)?.share_url ?? null) : null };
}

// A save is followed by its own id: `save:<studio session id>` (the registry has no job id for one).
export const SAVE_JOB = /^save:([A-Za-z0-9]{22})$/;
