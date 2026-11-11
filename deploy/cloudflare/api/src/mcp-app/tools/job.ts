// job_status: where a job is (MCP-APP-CONTRACT.md section 4). The model and the widgets both call it. A job id is whatever
// convert_to_webp or save_link answered: a registry job (studio:..., edit:..., open:...) or `save:<id>` for a save. The id
// in the answer is the one to use next: an `open:` job (a file still opening) becomes a `studio:` job once its render starts.
import * as z from "zod";
import { studioStatus } from "../../studio-edge";
import { JobOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, cut, num, rec, str } from "./common";
import { madePost, phaseOf, SAVE_JOB } from "./jobs";

const Input = z.object({ job: z.string().min(1).max(4100) });

// a short wait: the widget asks again
export const JOB_WAIT_S = 8;

type Out = z.infer<typeof JobOut>;

export const jobStatus: AppTool<z.infer<typeof Input>> = {
    name: "job_status",
    title: "Check a job",
    description:
        "Check on a conversion or a save that convert_to_webp or save_link left running, with the job id it gave. Waits a few seconds, then says whether it is running, done (with the post and its share link) or failed. If it is still running, call it again with the job id in the answer (it can change while a file opens). Call it one at a time.",
    input: Input,
    output: JobOut,
    // it can move a job along (a file that has finished opening starts its render), so it is not a pure read
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: false },
    view: null,
    async run(ctx, input) {
        const save = SAVE_JOB.exec(input.job);
        if (save) return saveStatus(ctx, input.job, save[1]!);
        const job = rec(await ctx.call("jobs.wait", { job: await startedJob(ctx, input.job), seconds: JOB_WAIT_S }));
        const phase = phaseOf(job);
        const id = str(job.job) ?? input.job;
        if (phase.state === "done") {
            const made = await madePost(ctx, str(job.post_id), str(job.share_url));
            const text = made.post
                ? [`Done: ${cut(made.post.title, 80)} (${made.post.kind}, post ${made.post.id}).`, made.share_url ? `Share link: ${made.share_url}` : null].filter(Boolean).join("\n")
                : "Done.";
            return { text, structured: { job: id, state: "done", progress: 1, error: null, post: made.post, share_url: made.share_url } satisfies Out };
        }
        if (phase.state === "error") {
            return { text: `The job failed (${phase.error}).`, structured: { job: id, state: "error", progress: phase.progress, error: phase.error, post: null, share_url: null } satisfies Out };
        }
        const pct = phase.progress !== null ? `${Math.round(phase.progress * 100)}%` : "in progress";
        return { text: `Still running (${pct}).`, structured: { job: id, state: "running", progress: phase.progress, error: null, post: null, share_url: null } satisfies Out };
    },
};

// jobs.wait on an `open:<session>:<plan>` job STARTS the plan's render (and takes a unit of the render cap) every time the
// session is ready, so asking again with the same id would render again. Once the session has a render, the job is that
// render: answer with its `studio:` id. (Not idempotent in make.ts waitJob; this guard is why a stale id is harmless.)
const OPEN_JOB = /^open:([A-Za-z0-9]{22}):[A-Za-z0-9_-]{1,4000}$/;
const RENDER_ID = /^[A-Za-z0-9]{20}$/;
export async function startedJob(ctx: Parameters<AppTool["run"]>[0], job: string): Promise<string> {
    const open = OPEN_JOB.exec(job);
    if (!open) return job;
    try {
        const sid = open[1]!;
        const res = await ctx.op.db.prepare("SELECT id, status FROM studio_renders WHERE session_id = ?1 ORDER BY created_at DESC, id DESC LIMIT 10").bind(sid).all();
        const rows = arr(res.results).map(rec);
        // a running or finished render first; a failed one still means the plan was started
        const row = rows.find((r) => r.status !== "error") ?? rows[0];
        const id = str(row?.id);
        if (id && RENDER_ID.test(id)) return `studio:${sid}:${id}`;
    } catch {
        // no way to tell: the registry decides
    }
    return job;
}

// How far a save is, 0 to 1: the bytes of its step; a gallery counts the files done as well. Null when the session does not say.
function saveProgress(body: Record<string, unknown>): number | null {
    const bytes = num(body.step_bytes);
    const total = num(body.step_total);
    const step = bytes !== null && total !== null && total > 0 ? Math.min(1, Math.max(0, bytes / total)) : null;
    const items = num(body.items_total);
    if (items !== null && items > 0) return Math.min(1, ((num(body.items_done) ?? 0) + (step ?? 0)) / items);
    return step;
}

// A save: the studio session advances while it is asked about, so this asks it (as the app's own long-poll does).
async function saveStatus(ctx: Parameters<AppTool["run"]>[0], job: string, sid: string) {
    const res = await studioStatus(ctx.op.db, ctx.op.container, sid, JOB_WAIT_S, ctx.op.edge);
    const body = rec(await res.json().catch(() => null));
    const status = str(body.status);
    const code = str(rec(body.error).code) ?? str(body.error_code);
    if (status === "ready") {
        const made = await madePost(ctx, sid);
        const text = made.post ? `Saved: ${cut(made.post.title, 80)} (${made.post.kind}, post ${made.post.id}).` : "Saved.";
        return { text, structured: { job, state: "done", progress: 1, error: null, post: made.post, share_url: made.share_url } satisfies Out };
    }
    if (status === "saving") {
        return { text: "Still saving.", structured: { job, state: "running", progress: saveProgress(body), error: null, post: null, share_url: null } satisfies Out };
    }
    const error = code ?? "error.api.generic";
    return { text: `The save failed (${error}).`, structured: { job, state: "error", progress: null, error, post: null, share_url: null } satisfies Out };
}
