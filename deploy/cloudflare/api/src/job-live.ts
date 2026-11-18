// One Live Activity for every job (apple/CONTRACT-JOBLIVE.md, APP-API-CONTRACT.md 8.13). The save/webp runs (live.ts),
// editor renders (edit-live.ts) and chat replies (chat-live.ts) keep their own run stores and push rules; a run whose
// device registered with `type: "job"` is sent this shape instead of its module's own: the steps the job really has,
// by name, and every word the island shows. The widget only draws it.
//
// Pure (no storage, no Cloudflare imports) and type-only imports, so the three modules can all use it without a cycle.

import type { ChatLiveState } from "./chat-live";
import type { EditLiveState } from "./edit-live";
import type { LiveState, RunAttributes } from "./live";

export const JOB_ATTRIBUTES_TYPE = "CobaltJobActivityAttributes";
// No change pushed for this long and the widget shows "no news" (ActivityKit's stale-date).
export const JOB_STALE_S = 180;
export const JOB_LOST_CODE = "error.live.lost";

export type JobKind = "save" | "upload" | "make" | "edit" | "chat" | "swarm";
export type JobPhase = "waiting" | "working" | "quiet" | "done" | "failed" | "lost";

// JobLiveAttributes / CobaltJobActivityAttributes in the app (Swift property names).
export type JobAttributes = { id: string; kind: JobKind; title: string; agent: boolean; open?: string };

// JobLiveState in the app. Absent optionals are omitted, never null.
export type JobState = {
    phase: JobPhase;
    steps: string[];
    step: number;
    headline: string;
    detail?: string;
    fraction?: number;
    compact?: string;
    since: number;
    result?: string;
    link?: string;
    // a swarm (APP-API-CONTRACT 61.5): one letter per agent (q r w d f s, at most 200), the buttons in order, the spec hash
    // the approve and apply buttons send, and the apply button's number
    cells?: string;
    actions?: SwarmAction[];
    hash?: string;
    count?: number;
};

export type SwarmAction = "approve" | "decline" | "stop" | "check" | "apply" | "open";

export type Job = { attributes: JobAttributes; state: JobState };

const KEY_ORDER = ["phase", "steps", "step", "headline", "detail", "fraction", "compact", "since", "result", "link", "cells", "actions", "hash", "count"] as const;
const LIMITS: Partial<Record<(typeof KEY_ORDER)[number], number>> = { headline: 60, detail: 90, compact: 7, result: 60, link: 300 };

// Canonical key order and the length caps, so two equal states serialise to the same bytes (the fixture pins it).
export function canonicalJob(s: JobState): JobState {
    const out: Record<string, unknown> = {};
    const src = s as Record<string, unknown>;
    for (const k of KEY_ORDER) {
        let v = src[k];
        if (v === undefined || v === null) continue;
        const max = LIMITS[k];
        if (max !== undefined && typeof v === "string" && v.length > max) v = `${v.slice(0, max - 1)}…`;
        if (k === "fraction" && typeof v === "number") v = Math.round(Math.min(1, Math.max(0, v)) * 1000) / 1000;
        out[k] = v;
    }
    return out as JobState;
}

export const isJobTerminal = (s: JobState) => s.phase === "done" || s.phase === "failed" || s.phase === "lost";

// ---- words -------------------------------------------------------------------------------------------------------

export function bytesText(n: number): string {
    if (n >= 1_000_000_000) return `${(n / 1e9).toFixed(1)} GB`;
    if (n >= 1_000_000) return `${(n / 1e6).toFixed(1)} MB`;
    return `${Math.max(1, Math.round(n / 1e3))} KB`;
}
const secondsText = (s: number) => `${Math.round(s * 10) / 10} s`;
const percent = (f: number) => `${Math.round(Math.min(1, Math.max(0, f)) * 100)}%`;
const ratio = (done?: number, total?: number) => (typeof done === "number" && typeof total === "number" && total > 0 ? Math.min(1, done / total) : undefined);

// "1280×720 · 30 s · 8.9 MB"; undefined when nothing is known.
export function resultText(r: { width?: number; height?: number; seconds?: number; bytes?: number }): string | undefined {
    const parts: string[] = [];
    if (typeof r.width === "number" && typeof r.height === "number") parts.push(`${r.width}×${r.height}`);
    if (typeof r.seconds === "number") parts.push(secondsText(r.seconds));
    if (typeof r.bytes === "number") parts.push(bytesText(r.bytes));
    return parts.length > 0 ? parts.join(" · ") : undefined;
}

// A failure code in plain words (the app's failure copy, by the codes the server sends).
export function reasonText(code: string | undefined): string {
    const c = code ?? "";
    if (c === JOB_LOST_CODE) return "it may still finish: look in your library.";
    if (c.startsWith("error.api.fetch.") || c.startsWith("error.api.content.") || c.startsWith("error.api.link.") || c === "error.studio.fetch_failed")
        return "the link could not be fetched.";
    if (c.includes("busy")) return "the server was busy. try again in a bit.";
    if (c.includes("too_large") || c.includes("too_big")) return "that file is over the size limit.";
    if (c.includes("unsupported") || c.includes("not_video")) return "that link isn't supported.";
    if (c.includes("expired") || c.includes("lost")) return "the server lost this job. try again.";
    if (c === "error.chat.interrupted") return "the reply was cut off.";
    if (c.startsWith("error.edit.")) return "a clip in this edit couldn't be used.";
    return "something went wrong. open capystore to see what happened.";
}

const titleOf = (service: string, ref: string, input: string) => {
    if (input === "file" || service === "file" || service === "") return ref || "a file";
    return ref ? `${service} · ${ref}` : service;
};

// ---- saves, uploads and webps (live.ts) ---------------------------------------------------------------------------

// `agent`: the run's `agent` field (live.ts startAgent). A make started by the agent has only the make step; an app run
// that goes on to the trim and a webp grows "read" and "make" as it gets there, so the steps are always the real ones.
export function jobOfSave(a: RunAttributes, s: LiveState, agent?: "save" | "make" | "browser"): Job {
    const upload = a.input === "file";
    const making = agent === "make";
    const browser = agent === "browser";
    const kind: JobKind = making ? "make" : upload ? "upload" : "save";
    const attributes: JobAttributes = {
        id: a.run,
        kind,
        title: browser ? "from your browser" : titleOf(a.service, a.ref, a.input),
        agent: agent === "save" || agent === "make",
    };

    const reads = s.stage === "reading" || s.stage === "ready";
    const makes = s.stage === "rendering" || (s.stage === "done" && s.resultURL !== undefined) || (s.stage === "failed" && s.rail === 3);
    let steps: string[];
    if (making) steps = ["make"];
    else {
        steps = [upload ? "upload" : "download", "store"];
        if (reads) steps.push("read");
        if (makes) steps.push("make");
    }
    const at = (name: string) => Math.max(0, steps.indexOf(name));
    const base = { steps, since: s.since };
    const service = a.service && a.service !== "file" ? a.service : null;

    const byteDetail = () => {
        if (typeof s.bytes !== "number") return undefined;
        return typeof s.total === "number" && s.total > 0 ? `${bytesText(s.bytes)} of ${bytesText(s.total)}` : bytesText(s.bytes);
    };
    const frameDetail = () =>
        typeof s.framesDone === "number" && typeof s.framesTotal === "number" ? `frame ${s.framesDone} of ${s.framesTotal}` : undefined;

    let state: JobState;
    switch (s.stage) {
        case "fetching": {
            const fraction = ratio(s.bytes, s.total);
            state = {
                ...base,
                phase: "working",
                step: at("download"),
                headline: s.waking ? "waking the server" : service ? `downloading from ${service}` : "downloading",
                detail: byteDetail(),
                fraction,
                compact: fraction !== undefined ? percent(fraction) : undefined,
            };
            break;
        }
        case "uploading": {
            const fraction = ratio(s.bytes, s.total);
            state = { ...base, phase: "working", step: at("upload"), headline: "uploading", detail: byteDetail(), fraction, compact: fraction !== undefined ? percent(fraction) : undefined };
            break;
        }
        case "saving": {
            const fraction = ratio(s.bytes, s.total);
            state = { ...base, phase: "working", step: at("store"), headline: "storing in your library", detail: byteDetail(), fraction, compact: fraction !== undefined ? percent(fraction) : undefined };
            break;
        }
        case "reading": {
            const fraction = ratio(s.framesDone, s.framesTotal);
            state = { ...base, phase: "working", step: at("read"), headline: "reading the video", detail: frameDetail(), fraction, compact: fraction !== undefined ? percent(fraction) : undefined };
            break;
        }
        case "ready":
            state = { ...base, phase: "waiting", step: at("read"), headline: "ready to trim", detail: s.title };
            break;
        case "rendering": {
            const fraction = ratio(s.framesDone, s.framesTotal);
            const removing = s.work === "rmbg";
            state = {
                ...base,
                phase: "working",
                step: at("make"),
                headline: removing ? "removing background" : s.packing ? "packing the webp" : "making the webp",
                detail: frameDetail(),
                fraction,
                compact: typeof s.framesDone === "number" && typeof s.framesTotal === "number" ? `${s.framesDone}/${s.framesTotal}` : undefined,
            };
            break;
        }
        case "done":
            state = {
                ...base,
                phase: "done",
                step: steps.length,
                headline: s.work === "rmbg" ? "background removed" : s.resultURL !== undefined ? "webp ready" : "saved",
                result: resultText({ width: s.resultWidth, height: s.resultHeight, seconds: s.resultSeconds, bytes: s.resultBytes }),
                link: s.resultURL,
            };
            break;
        case "failed": {
            const lost = s.code === JOB_LOST_CODE;
            const removing = s.work === "rmbg";
            const railStep = Math.min(steps.length - 1, making ? 0 : s.rail >= 3 ? at("make") : s.rail === 2 && reads ? at("read") : Math.min(s.rail, 1));
            state = {
                ...base,
                phase: lost ? "lost" : "failed",
                step: Math.max(0, railStep),
                headline: lost
                    ? `lost track of this ${removing ? "background removal" : kind === "make" ? "webp" : kind === "upload" ? "upload" : "save"}`
                    : removing
                      ? "couldn't remove the background"
                      : making || s.rail >= 3
                        ? "couldn't make the webp"
                        : "couldn't save",
                detail: reasonText(s.code),
            };
            break;
        }
    }
    return { attributes, state: canonicalJob(state) };
}

// ---- editor renders (edit-live.ts) ----------------------------------------------------------------------------------

const EDIT_STEPS = ["prepare", "render", "save"];

export function jobOfEdit(rid: string, s: EditLiveState): Job {
    const attributes: JobAttributes = { id: rid, kind: "edit", title: `edit · ${s.title}`, agent: false };
    const base = { steps: EDIT_STEPS, since: s.since };
    let state: JobState;
    switch (s.status) {
        case "queued":
            state = { ...base, phase: "waiting", step: 0, headline: "waiting for its turn", detail: s.queueAhead ? `${s.queueAhead} ahead` : "next", compact: s.queueAhead ? `+${s.queueAhead}` : "next" };
            break;
        case "preparing":
            state = { ...base, phase: "working", step: 0, headline: "sending the clips", fraction: s.progress };
            break;
        case "rendering":
            state = { ...base, phase: "working", step: 1, headline: "rendering", detail: s.progress !== undefined ? percent(s.progress) : undefined, fraction: s.progress, compact: s.progress !== undefined ? percent(s.progress) : undefined };
            break;
        case "finishing":
            state = { ...base, phase: "working", step: 2, headline: "saving the video", fraction: s.progress };
            break;
        case "done":
            state = { ...base, phase: "done", step: 3, headline: "video ready", result: resultText({ width: s.resultWidth, height: s.resultHeight, seconds: s.resultSeconds, bytes: s.resultBytes }) };
            break;
        case "cancelled":
            state = { ...base, phase: "failed", step: 1, headline: "render cancelled" };
            break;
        case "failed":
            state = { ...base, phase: "failed", step: 1, headline: "couldn't render", detail: reasonText(s.code) };
            break;
    }
    return { attributes, state: canonicalJob(state) };
}

// ---- chat replies (chat-live.ts) -----------------------------------------------------------------------------------

const CHAT_STEPS = ["think", "tools", "write"];

export function jobOfChat(thread: string, prompt: string, s: ChatLiveState): Job {
    const attributes: JobAttributes = { id: thread, kind: "chat", title: `chat · ${prompt}`.slice(0, 80), agent: false };
    const base = { steps: CHAT_STEPS, since: s.since };
    const tools = s.steps > 0 ? `${s.steps} so far${s.tool ? ` · ${s.tool}` : ""}` : s.tool;
    let state: JobState;
    switch (s.status) {
        case "thinking":
            state = { ...base, phase: "working", step: 0, headline: "thinking" };
            break;
        case "working":
            state = { ...base, phase: "working", step: 1, headline: "using tools", detail: tools, compact: s.steps > 0 ? `${s.steps}` : undefined };
            break;
        case "writing":
            state = { ...base, phase: "working", step: 2, headline: "writing", detail: s.reply };
            break;
        case "done":
            state = { ...base, phase: "done", step: 3, headline: "reply ready", detail: s.reply };
            break;
        case "failed":
            state = { ...base, phase: "failed", step: s.steps > 0 ? 1 : 0, headline: "couldn't reply", detail: reasonText(s.code) };
            break;
    }
    return { attributes, state: canonicalJob(state) };
}

// ---- swarms (APP-API-CONTRACT 61.5) ------------------------------------------------------------------------------

// What the swarm island is drawn from: the swarm's row and counts (swarm-live.ts reads them from D1).
export type SwarmLiveInput = {
    id: string;
    name: string;
    mode: "propose" | "read" | "act";
    status: "awaiting_approval" | "running" | "stopping" | "done" | "failed" | "stopped" | "declined" | "expired";
    apply_status: "none" | "ready" | "applying" | "applied" | "failed";
    spec_hash: string;
    planner: string;
    est_low: number;
    est_high: number;
    spent_usd: number;
    cap_usd: number;
    error: string | null;
    reduce: string | null;
    created_at: number;
    approved_at: number | null;
    finished_at: number | null;
    expires_at: number | null;
    // one letter per agent, in order: q queued, r running, w waiting on a question, d done, f failed, s skipped
    cells: string;
    // propose mode: every change, the kept ones, the kept ones not applied yet and how many of those clash, applied, failed
    changes: { total: number; kept: number; open: number; clashes: number; done: number; failed: number };
};

export const SWARM_CELLS_MAX = 200;
export const SWARM_TITLE_MAX = 40;

// Money as the island says it: cents under $1 ("21¢", "<1¢"), dollars above ("$1.40").
export function moneyText(usd: number): string {
    const c = Math.round(usd * 100);
    if (c >= 100) return `$${(c / 100).toFixed(2)}`;
    return usd > 0 && c === 0 ? "<1¢" : `${c}¢`;
}

const cut = (s: string, n: number) => (Array.from(s).length <= n ? s : `${Array.from(s).slice(0, n - 1).join("").trimEnd()}…`);
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

function swarmReason(s: SwarmLiveInput): string {
    switch (s.status) {
        case "declined":
            return "you declined it.";
        case "expired":
            return "nobody approved it within an hour.";
        default:
            break;
    }
    switch (s.error) {
        case "error.swarm.over_cap":
            return `it reached its ${moneyText(s.cap_usd)} cap.`;
        case "error.swarm.daily_cap":
            return "today's swarm budget is spent.";
        case "error.swarm.too_many_failed":
            return "too many agents failed.";
        case "error.swarm.all_failed":
            return "no agent finished.";
        case "error.swarm.off":
            return "swarms are off on this server.";
        case null:
            return s.status === "stopped" ? "it was stopped. nothing was undone." : "something went wrong. open capystore to see what happened.";
        default:
            return "something went wrong. open capystore to see what happened.";
    }
}

// The swarm island (61.5): every word, the buttons, the grid. `now` (ms) only for "expires in <m> min".
export function jobOfSwarm(s: SwarmLiveInput, now: number): Job {
    const attributes: JobAttributes = { id: `swarm:${s.id}`, kind: "swarm", title: cut(`swarm · ${s.name}`, SWARM_TITLE_MAX), agent: true, open: `cobalt-apple://swarm/${s.id}` };
    const steps = s.mode === "propose" ? ["approve", "run", "review", "apply"] : ["approve", "run"];
    const cells = s.cells.slice(0, SWARM_CELLS_MAX);
    const n = (c: string) => cells.split("").filter((x) => x === c).length;
    const total = cells.length;
    const done = n("d");
    const ended = done + n("f") + n("s");
    const waiting = n("w");
    const spent = moneyText(s.spent_usd);
    const secs = (ms: number | null) => Math.floor((ms ?? s.created_at) / 1000);
    const base = { steps, cells };
    const expired = s.status === "expired" || (s.status === "awaiting_approval" && s.expires_at !== null && s.expires_at <= now);
    let state: JobState;
    if (s.status === "awaiting_approval" && !expired) {
        const mins = Math.max(1, Math.ceil(((s.expires_at ?? now) - now) / 60_000));
        state = {
            ...base,
            phase: "waiting",
            step: 0,
            headline: s.name,
            detail: `from ${s.planner} · about ${moneyText(s.est_low)}–${moneyText(s.est_high)} · expires in ${mins} min`,
            since: secs(s.created_at),
            actions: ["approve", "decline"],
            hash: s.spec_hash,
        };
    } else if (s.status === "running") {
        state = {
            ...base,
            phase: "working",
            step: 1,
            headline: `${done} of ${total} agents done`,
            detail:
                waiting > 0
                    ? waiting === 1
                        ? `1 agent is asking ${s.planner} a question`
                        : `${waiting} agents are asking ${s.planner} questions`
                    : s.mode === "propose"
                      ? `${plural(s.changes.total, "change", "changes")} · ${spent}`
                      : `${spent} spent`,
            fraction: total > 0 ? ended / total : undefined,
            compact: `${done}/${total}`,
            since: secs(s.approved_at),
            actions: ["stop"],
        };
    } else if (s.status === "stopping") {
        state = { ...base, phase: "working", step: 1, headline: "stopping", detail: `${done} of ${total} agents done · ${spent}`, fraction: total > 0 ? ended / total : undefined, compact: `${done}/${total}`, since: secs(s.approved_at) };
    } else if (s.mode === "propose" && s.apply_status === "applying") {
        const all = s.changes.kept;
        state = { ...base, phase: "working", step: 3, headline: "applying changes", detail: `${s.changes.done} of ${all}`, fraction: all > 0 ? s.changes.done / all : undefined, compact: `${s.changes.done}/${all}`, since: secs(s.finished_at) };
    } else if (s.mode === "propose" && s.apply_status === "ready" && s.changes.open > 0 && (s.status === "done" || s.status === "stopped" || s.status === "failed")) {
        const count = s.changes.open - s.changes.clashes;
        state = {
            ...base,
            phase: "waiting",
            step: 2,
            headline: `${plural(s.changes.open, "change", "changes")} ready`,
            detail: s.changes.clashes > 0 ? `${s.changes.clashes} ${s.changes.clashes === 1 ? "looks like a duplicate and is" : "look like duplicates and are"} left out · ${spent}` : `${spent} spent`,
            since: secs(s.finished_at),
            actions: count > 0 ? ["check", "apply"] : ["check"],
            hash: s.spec_hash,
            count,
        };
    } else if (s.mode === "propose" && (s.apply_status === "applied" || s.apply_status === "failed")) {
        state = {
            ...base,
            phase: "done",
            step: steps.length,
            headline: `applied ${plural(s.changes.done, "change", "changes")}`,
            detail: s.changes.failed > 0 ? `${s.changes.failed} failed · ${spent}` : `${spent} spent`,
            since: secs(s.finished_at),
            actions: ["open"],
        };
    } else if (s.status === "done") {
        const words = s.reduce?.replace(/\s+/g, " ").trim();
        state = { ...base, phase: "done", step: steps.length, headline: "done", detail: words ? words : `${done} of ${total} agents done · ${spent}`, since: secs(s.finished_at), actions: ["open"] };
    } else {
        const capped = s.error === "error.swarm.over_cap" || s.error === "error.swarm.daily_cap";
        const headline = expired ? "expired" : s.status === "declined" ? "declined" : capped ? "stopped at its cap" : s.status === "stopped" ? "stopped" : "failed";
        state = {
            ...base,
            phase: "failed",
            step: expired || s.status === "declined" ? 0 : 1,
            headline,
            detail: expired ? swarmReason({ ...s, status: "expired" }) : swarmReason(s),
            since: secs(s.finished_at ?? s.expires_at),
            actions: ["open"],
        };
    }
    return { attributes, state: canonicalJob(state) };
}

// The swarm island ends at once (no lingering card) when nobody approved it.
export const swarmEndsAtOnce = (s: Pick<SwarmLiveInput, "status" | "expires_at">, now: number) =>
    s.status === "declined" || s.status === "expired" || (s.status === "awaiting_approval" && s.expires_at !== null && s.expires_at <= now);

// ---- payloads -------------------------------------------------------------------------------------------------------

// A module's own payload, re-dressed for a job run: the content state is the job's, a start names the job type and its
// attributes, and an open state goes stale (the widget's "no news") JOB_STALE_S after this push, or at the module's own
// stale date when that is later. Everything else (event,
// timestamp, dismissal, alert, input-push-token) is the module's, so the push rules stay in one place each.
export function asJobPayload(payload: { aps: Record<string, unknown> }, job: Job, now: number): { aps: Record<string, unknown> } {
    const aps: Record<string, unknown> = { ...payload.aps, "content-state": canonicalJob(job.state) };
    if (aps.event === "start") {
        aps["attributes-type"] = JOB_ATTRIBUTES_TYPE;
        const a: Record<string, unknown> = { id: job.attributes.id, kind: job.attributes.kind, title: job.attributes.title, agent: job.attributes.agent };
        if (job.attributes.open) a.open = job.attributes.open;
        aps.attributes = a;
    }
    // never sooner than the module's own: "ready to trim" waits on the owner for 30 minutes and is not "no news"
    if (aps.event !== "end") {
        const own = typeof payload.aps["stale-date"] === "number" ? (payload.aps["stale-date"] as number) : 0;
        aps["stale-date"] = Math.max(own, Math.floor(now / 1000) + JOB_STALE_S);
    }
    return { aps };
}
