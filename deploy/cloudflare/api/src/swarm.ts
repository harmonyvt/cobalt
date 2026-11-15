// Agent swarms (APP-API-CONTRACT.md section 59): an agent (MCP or the in-app chat) sends one JSON program; capystore splits
// its items into batches and runs one Haiku 5.5 task per batch, in code mode with the same `run_code` sandbox and `cobalt`
// toolbox as the chat, cut down to the program's allowlist. Nothing runs until Harmony approves the plan where the agent
// cannot reach (the web page behind Cloudflare Access, or a signed-in device session).
//
// Modes: "propose" (the default) answers changes only, which Harmony reviews and a deterministic executor (no model)
// applies; "read" answers results; "act" may also call the write ops the program names, inside its scope.
//
// This file holds the rules, the D1 side and the runner, free of Cloudflare imports so the tests run it under node. The
// runner is driven by the `Swarm` Durable Object's alarm (swarm-do.ts), because work after a response does not survive.
import * as z from "zod";
import { CHAT_MODEL_DEFAULT, type ChatModel, type CodeRunner, type ModelTurn, type ModelUsage } from "./chat";
import { chatTools, type ChatCollect, type ChatTools } from "./chat-tools";
import { lookBlocks, lookImages, type LookDeps } from "./look-pictures";
import { chatToolbox } from "./registry/ai";
import type { OpBase } from "./registry/context";
import { OpError, type AiFlags, type Op } from "./registry/op";
import { Registry } from "./registry/registry";
import { argsToInput, toolTypesFor } from "./registry/typescript";

// ---- limits ---------------------------------------------------------------------------------------------------------

export const SWARM_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const SWARM_JOB_REGEX = /^swarm:([A-Za-z0-9]{16})$/;
export const swarmJob = (id: string) => `swarm:${id}`;
export const SWARM_MODEL = CHAT_MODEL_DEFAULT;

export const ITEMS_MAX = 5000;
export const ITEMS_BYTES_MAX = 512 * 1024;
export const TASKS_MAX = 200;
export const BATCH_DEFAULT = 50;
export const BATCH_MAX = 200;
export const PROMPT_MAX = 8000;
export const SCHEMA_BYTES_MAX = 8 * 1024;
export const CONCURRENCY_DEFAULT = 5;
export const CONCURRENCY_MAX = 8;
export const TURNS_DEFAULT = 6;
export const TURNS_MAX = 10;
export const USD_DEFAULT = 1;
export const USD_MIN = 0.05;
export const ATTEMPTS_DEFAULT = 2;
export const STOP_AFTER_DEFAULT = 5;
export const SWARM_MAX_USD_DEFAULT = 10;
export const SWARM_DAILY_USD_DEFAULT = 5;
// running (or stopping) at once: per planning key, and over all keys
export const RUNNING_PER_KEY = 1;
export const RUNNING_ALL = 2;
// plans waiting for approval per key, and how long one waits
export const PLANS_PER_KEY = 10;
export const PLANS_ALL = 20;
export const PLAN_TTL_MS = 60 * 60 * 1000;
// a running task whose heartbeat is older than this is queued again (once)
export const HEARTBEAT_STALE_MS = 5 * 60 * 1000;
// one alarm launches tasks for this long, and a task still going after HARD pauses (its conversation is kept)
export const TICK_BUDGET_MS = 8 * 60 * 1000;
export const TICK_HARD_MS = 10 * 60 * 1000;
// a model call that failed for a passing reason (429, 5xx, overloaded, the relay's 403) is tried again after these waits
export const MODEL_BACKOFF_MS = [2000, 8000, 30_000];
// changes one task may propose, and what one change's texts may hold
export const CHANGES_PER_TASK_MAX = 1000;
const TEXT_FIELD_MAX = 300;
const RESULT_MAX = 20_000;
const LOGS_MAX = 30;
// the reduce step reads at most this much of the results
const REDUCE_INPUT_MAX = 120_000;
// 7TV: writes at most 1 a second, reads 5 a second, across all tasks of a swarm
export const SEVENTV_WRITE_GAP_MS = 1000;
export const SEVENTV_READ_GAP_MS = 200;
const SOURCE_PAGES_MAX = 100;

// Haiku 5.5, dollars per million tokens; a request whose input (cache reads and writes included) is over 100K tokens is
// priced at the long-prompt tier for its input and output
export const PRICE = { input: 0.1, output: 0.5, cache_read: 0.01, cache_write: 0.125 };
export const PRICE_LONG = { input: 0.5, output: 2.5 };
export const LONG_PROMPT_TOKENS = 100_000;

// The ops a swarm task may read with (`tools`) and the ops it may write or propose (`writes`). Never deletes, makes or
// renders, the box, saves, share links or sub-agents: a swarm cannot spend money beyond its own tokens.
export const SWARM_READ_OPS: readonly string[] = [
    "library.list",
    "library.search",
    "library.post",
    "library.about",
    "library.transcript",
    "look",
    "collections.list",
    "links.list",
    "sets.list",
    "names.list",
    "emotes.find",
    "seventv.status",
    "seventv.sets",
    "seventv.set",
    "seventv.emote",
    "seventv.owned",
    "seventv.uploads",
];
export const SWARM_WRITE_OPS: readonly string[] = ["seventv.rename", "seventv.add", "seventv.remove", "library.title", "library.about.set"];

// The one arg of each write that holds the new value Harmony may edit on the review page (a change's `edit_arg`, and its
// `after`). Never an id or a scope key. library.about.set's tags are a list, and seventv.remove's alias picks a copy:
// neither has one.
export const EDIT_ARGS: Readonly<Record<string, string>> = { "seventv.rename": "alias", "seventv.add": "alias", "library.title": "title" };

// The id fields of each write, one of which `scope` must cover in act mode.
export const SCOPE_IDS: Readonly<Record<string, readonly string[]>> = {
    "seventv.rename": ["set_id"],
    "seventv.add": ["set_id"],
    "seventv.remove": ["set_id"],
    "library.title": ["id"],
    "library.about.set": ["key"],
};

export type SwarmMode = "propose" | "read" | "act";
export type SwarmStatus = "awaiting_approval" | "running" | "stopping" | "done" | "failed" | "stopped" | "declined" | "expired";
export type TaskStatus = "queued" | "running" | "done" | "failed" | "skipped";
export type ApplyStatus = "none" | "ready" | "applying" | "applied" | "failed";
export const SWARM_LIVE: readonly SwarmStatus[] = ["running", "stopping"];

const err = (status: number, code: string, message?: string) => new OpError(status, code, message);
export const badSpec = (message: string) => err(400, "error.swarm.bad_spec", `swarm: ${message}`);

// A D1 error from a database that migration 0043 has not reached yet.
export const isMissingTable = (e: unknown) => /no such table: swarm/.test(String(e instanceof Error ? e.message : e));

// D1 before the migration: one clear refusal instead of a generic error.
export async function d1<T>(p: Promise<T>): Promise<T> {
    try {
        return await p;
    } catch (e) {
        if (isMissingTable(e)) throw err(503, "error.swarm.not_ready", "swarms are not set up on this server yet (migration 0043)");
        throw e;
    }
}

const num = (v: string | undefined, fallback: number) => {
    const n = Number(v?.trim());
    return v !== undefined && v.trim() !== "" && Number.isFinite(n) && n >= 0 ? n : fallback;
};
export const maxUsdOf = (env: { SWARM_MAX_USD?: string }) => num(env.SWARM_MAX_USD, SWARM_MAX_USD_DEFAULT);
export const dailyUsdOf = (env: { SWARM_DAILY_USD?: string }) => num(env.SWARM_DAILY_USD, SWARM_DAILY_USD_DEFAULT);
// Swarms can run while the Durable Object binding and the model key are there.
export const swarmsOn = (env: { SWARMS?: unknown; ANTHROPIC_API_KEY?: string }) => !!env.SWARMS && !!env.ANTHROPIC_API_KEY?.trim();

// ---- the program ----------------------------------------------------------------------------------------------------

const CallName = z.string().trim().min(1).max(64);
export const SwarmSpecSchema = z.object({
    name: z.string().trim().min(1).max(80).describe("shown on the approve page"),
    mode: z.enum(["propose", "read", "act"]).optional().describe("propose (default): tasks only read and answer { changes }, Harmony reviews them, then they are applied; read: tasks answer results; act: tasks may also call `writes` themselves"),
    items: z.array(z.unknown()).max(ITEMS_MAX).optional().describe(`the items to split (at most ${ITEMS_MAX}, JSON at most 512 KB); or give source`),
    source: z
        .object({
            call: CallName.describe("a swarm read call, e.g. seventv.set"),
            args: z.record(z.string(), z.unknown()).optional().describe("its input object"),
            path: z.string().max(200).optional().describe("dot path to the list in its answer, e.g. emotes"),
        })
        .optional()
        .describe("fetch the items server-side now (pages are followed, at most 5000 items)"),
    batch: z.object({ size: z.number().int().min(1).max(BATCH_MAX).optional().describe(`items per task, default ${BATCH_DEFAULT}`) }).optional(),
    prompt: z.string().min(1).max(PROMPT_MAX).describe("each task's message; must contain {{items}}; may use {{index}} {{total}} {{count}} {{name}}"),
    tools: z.array(CallName).max(30).optional().describe(`read calls a task may make: ${SWARM_READ_OPS.join(", ")}`),
    writes: z.array(CallName).max(10).optional().describe(`propose: ops a change may name; act: ops a task may call. Any of ${SWARM_WRITE_OPS.join(", ")}`),
    scope: z
        .record(z.string().min(1).max(64), z.array(z.string().min(1).max(200)).min(1).max(5000))
        .optional()
        .describe("a write whose args have key k must have args[k] in scope[k], e.g. { set_id: [\"...\"] }"),
    output: z.object({ schema: z.record(z.string(), z.unknown()).describe("a JSON Schema") }).optional().describe("read/act: each task's answer must match this JSON Schema"),
    reduce: z.object({ prompt: z.string().min(1).max(4000) }).optional().describe("one final summary over all results"),
    concurrency: z.number().int().min(1).max(CONCURRENCY_MAX).optional().describe(`tasks at once, default ${CONCURRENCY_DEFAULT}`),
    budget: z
        .object({
            usd: z.number().min(USD_MIN).optional().describe(`the dollar cap, default ${USD_DEFAULT} (at most SWARM_MAX_USD, 10 by default)`),
            turns_per_task: z.number().int().min(1).max(TURNS_MAX).optional().describe(`model turns per task, default ${TURNS_DEFAULT}`),
        })
        .optional(),
    retry: z
        .object({
            attempts: z.number().int().min(1).max(5).optional().describe(`attempts per task, default ${ATTEMPTS_DEFAULT}`),
            stop_after_failed_tasks: z.number().int().min(1).max(TASKS_MAX).optional().describe(`the swarm stops after this many failed tasks, default ${STOP_AFTER_DEFAULT}`),
        })
        .optional(),
});
export type SwarmSpecInput = z.infer<typeof SwarmSpecSchema>;

// The program as it is stored and run: every default filled in, items left out (they are in the tasks).
export type Spec = {
    name: string;
    mode: SwarmMode;
    prompt: string;
    tools: string[];
    writes: string[];
    scope: Record<string, string[]>;
    output: { schema: Record<string, unknown> } | null;
    reduce: { prompt: string } | null;
    source: { call: string; args: Record<string, unknown>; path: string | null } | null;
    batch_size: number;
    concurrency: number;
    cap_usd: number;
    turns: number;
    attempts: number;
    stop_after: number;
};

const PLACEHOLDERS = new Set(["items", "index", "total", "count", "name"]);

// Checks a program against the rules and the registry, and fills in the defaults. Throws error.swarm.bad_spec.
export function checkSpec(input: SwarmSpecInput, registry: Registry, env: { SWARM_MAX_USD?: string }): Spec {
    const mode: SwarmMode = input.mode ?? "propose";
    if ((input.items === undefined) === (input.source === undefined)) throw badSpec("give items or source (one of them)");
    const tools = [...new Set(input.tools ?? [])];
    const writes = [...new Set(input.writes ?? [])];
    for (const t of tools) {
        if (!SWARM_READ_OPS.includes(t)) throw badSpec(`tools: ${t} is not a swarm read call (${SWARM_READ_OPS.join(", ")})`);
        if (!registry.op(t)) throw badSpec(`tools: ${t} does not exist on this server`);
    }
    for (const w of writes) {
        if (!SWARM_WRITE_OPS.includes(w)) throw badSpec(`writes: ${w} is not a swarm write (${SWARM_WRITE_OPS.join(", ")})`);
        if (!registry.op(w)) throw badSpec(`writes: ${w} does not exist on this server`);
    }
    const scope = input.scope ?? {};
    for (const k of Object.keys(scope)) {
        if (!writes.some((w) => inputFields(registry, w).includes(k))) throw badSpec(`scope: ${k} is not an input of any op in writes`);
    }
    if (mode === "act") {
        for (const w of writes) {
            const ids = SCOPE_IDS[w] ?? [];
            if (!ids.some((k) => k in scope)) throw badSpec(`act mode: scope must limit ${w} by ${ids.join(" or ")}`);
        }
    }
    if (mode === "read" && writes.length > 0) throw badSpec("read mode has no writes");
    if (mode !== "read" && writes.length === 0) throw badSpec(`${mode} mode needs writes: the ops its changes may use`);
    if (mode === "propose" && input.output) throw badSpec("output.schema is for read and act mode; propose answers { changes }");
    if (!input.prompt.includes("{{items}}")) throw badSpec("prompt must contain {{items}}");
    for (const m of input.prompt.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)) {
        if (!PLACEHOLDERS.has(m[1]!)) throw badSpec(`prompt: {{${m[1]}}} is not a placeholder ({{items}} {{index}} {{total}} {{count}} {{name}})`);
    }
    let output: Spec["output"] = null;
    if (input.output) {
        if (JSON.stringify(input.output.schema).length > SCHEMA_BYTES_MAX) throw badSpec("output.schema is over 8 KB");
        schemaOf(input.output.schema);
        output = { schema: input.output.schema };
    }
    let source: Spec["source"] = null;
    if (input.source) {
        if (!SWARM_READ_OPS.includes(input.source.call) || !registry.op(input.source.call)) throw badSpec(`source.call: ${input.source.call} is not a swarm read call`);
        source = { call: input.source.call, args: input.source.args ?? {}, path: input.source.path ?? null };
    }
    const max = maxUsdOf(env);
    const usd = input.budget?.usd ?? USD_DEFAULT;
    if (usd > max) throw badSpec(`budget.usd: at most ${max}`);
    return {
        name: input.name,
        mode,
        prompt: input.prompt,
        tools,
        writes,
        scope,
        output,
        reduce: input.reduce ?? null,
        source,
        batch_size: input.batch?.size ?? BATCH_DEFAULT,
        concurrency: input.concurrency ?? CONCURRENCY_DEFAULT,
        cap_usd: usd,
        turns: input.budget?.turns_per_task ?? TURNS_DEFAULT,
        attempts: input.retry?.attempts ?? ATTEMPTS_DEFAULT,
        stop_after: input.retry?.stop_after_failed_tasks ?? STOP_AFTER_DEFAULT,
    };
}

// The top-level input fields of an op (its zod object's keys).
export function inputFields(registry: Registry, op: string): string[] {
    const shape = (registry.op(op)?.input as unknown as { shape?: Record<string, unknown> } | undefined)?.shape;
    return shape ? Object.keys(shape) : [];
}

// The writes no scope key limits (none of their input fields is a scope key): shown on the approve page.
export const unscopedWrites = (registry: Registry, spec: Pick<Spec, "writes" | "scope">) =>
    spec.writes.filter((w) => !inputFields(registry, w).some((k) => k in spec.scope));

// The zod check of an output.schema (JSON Schema). Throws error.swarm.bad_spec when it is not one zod can read.
export function schemaOf(schema: Record<string, unknown>): z.ZodType {
    try {
        return z.fromJSONSchema(schema as any) as unknown as z.ZodType;
    } catch (e) {
        throw badSpec(`output.schema is not a JSON Schema this server can check (${e instanceof Error ? e.message.slice(0, 200) : "invalid"})`);
    }
}

// The items, checked and split into batches.
export function splitItems(items: unknown[], size: number): unknown[][] {
    if (items.length === 0) throw badSpec("there are no items");
    if (items.length > ITEMS_MAX) throw badSpec(`at most ${ITEMS_MAX} items`);
    if (JSON.stringify(items).length > ITEMS_BYTES_MAX) throw badSpec("the items are over 512 KB of JSON");
    const out: unknown[][] = [];
    for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
    if (out.length > TASKS_MAX) throw badSpec(`${out.length} tasks: at most ${TASKS_MAX} (raise batch.size)`);
    return out;
}

// One task's message: the template with its placeholders filled in. Nothing else is filled in.
export function fillPrompt(template: string, v: { items: unknown[]; index: number; total: number; name: string }): string {
    return template.replace(/\{\{\s*(items|index|total|count|name)\s*\}\}/g, (_, k: string) => {
        switch (k) {
            case "items":
                return JSON.stringify(v.items);
            case "index":
                return String(v.index);
            case "total":
                return String(v.total);
            case "count":
                return String(v.items.length);
            default:
                return v.name;
        }
    });
}

// What a list of model calls cost, in dollars.
export function usdOf(u: ModelUsage | undefined | null): number {
    if (!u) return 0;
    const n = (x: number | null | undefined) => (typeof x === "number" && Number.isFinite(x) && x > 0 ? x : 0);
    const long = n(u.input_tokens) + n(u.cache_read_input_tokens) + n(u.cache_creation_input_tokens) > LONG_PROMPT_TOKENS;
    const pin = long ? PRICE_LONG.input : PRICE.input;
    const pout = long ? PRICE_LONG.output : PRICE.output;
    return (n(u.input_tokens) * pin + n(u.output_tokens) * pout + n(u.cache_read_input_tokens) * PRICE.cache_read + n(u.cache_creation_input_tokens) * PRICE.cache_write) / 1e6;
}

// One request's dollars at the estimate's assumptions (all input uncached).
const turnUsd = (inTokens: number, outTokens: number) => usdOf({ input_tokens: inTokens, output_tokens: outTokens });

const round4 = (x: number) => Math.round(x * 10_000) / 10_000;
const tokensOf = (chars: number) => Math.ceil(chars / 4);

// The cost estimate: per task, turns x (system + cheat sheet + batch + 1500 tokens per earlier turn) in and 600 out per
// turn, at the input price (no caching assumed); plus the reduce step. Shown as { low: half, high: all }.
export function estimateUsd(spec: Pick<Spec, "turns" | "reduce" | "prompt">, batches: unknown[][], systemChars: number): { low: number; high: number } {
    let usd = 0;
    for (const b of batches) {
        const base = tokensOf(systemChars + spec.prompt.length + JSON.stringify(b).length);
        for (let t = 0; t < spec.turns; t++) usd += turnUsd(base + 1500 * t, 600);
    }
    if (spec.reduce) usd += turnUsd(tokensOf(spec.reduce.prompt.length) + Math.min(tokensOf(REDUCE_INPUT_MAX), batches.length * 1500), 1000);
    return { low: round4(usd * 0.5), high: round4(usd) };
}

export async function sha256Hex(text: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// JSON with object keys in order, so equal values hash the same.
export function stableJson(v: unknown): string {
    if (Array.isArray(v)) return `[${v.map(stableJson).join(",")}]`;
    if (v && typeof v === "object") {
        return `{${Object.keys(v as object)
            .sort()
            .map((k) => `${JSON.stringify(k)}:${stableJson((v as Record<string, unknown>)[k])}`)
            .join(",")}}`;
    }
    return JSON.stringify(v ?? null);
}

// The approval binds this: the program, the frozen batches and the round.
export const specHash = (spec: Spec, batches: unknown[][], round: number) => sha256Hex(stableJson({ spec, batches, round }));
export const argsHash = (op: string, args: unknown) => sha256Hex(`${op}\n${stableJson(args)}`);

// A dot path into an answer ("emotes", "data.items"); "" or null is the answer itself.
export function atPath(v: unknown, path: string | null): unknown {
    if (!path) return v;
    let cur = v;
    for (const k of path.split(".")) {
        if (cur === null || typeof cur !== "object") return undefined;
        cur = (cur as Record<string, unknown>)[k];
    }
    return cur;
}

// Whether a write's input stays in the scope: every scoped key it has must hold an allowed value.
export function scopeProblem(scope: Record<string, string[]>, input: unknown): string | null {
    if (!input || typeof input !== "object") return null;
    for (const [k, allowed] of Object.entries(scope)) {
        if (!(k in (input as object))) continue;
        const v = (input as Record<string, unknown>)[k];
        if (v === undefined) continue;
        if (typeof v !== "string" || !allowed.includes(v)) return `${k} ${JSON.stringify(v)} is outside this swarm's scope (${allowed.slice(0, 5).join(", ")}${allowed.length > 5 ? ", ..." : ""})`;
    }
    return null;
}

// A call's arguments in the order the chat's `cobalt.<call>(...)` takes them, from its input object.
export function positionalArgs(op: Op, input: Record<string, unknown>): unknown[] {
    if (op.ai.args) return [input];
    const params = op.ai.params ?? [];
    const list: unknown[] = params.map((k) => input[k]);
    if (op.ai.options) {
        const rest = Object.fromEntries(Object.entries(input).filter(([k]) => !params.includes(k)));
        if (Object.keys(rest).length > 0) list.push(rest);
    }
    return list;
}

// ---- rows and shapes --------------------------------------------------------------------------------------------------

export type SwarmRow = {
    id: string;
    key_id: string;
    name: string;
    mode: SwarmMode;
    spec: string;
    spec_hash: string;
    round: number;
    status: SwarmStatus;
    item_count: number;
    task_count: number;
    est_low: number;
    est_high: number;
    cap_usd: number;
    spent_usd: number;
    stop_requested: number;
    apply_status: ApplyStatus;
    approved_by: string | null;
    reduce_result: string | null;
    error: string | null;
    created_at: number;
    updated_at: number;
    approved_at: number | null;
    finished_at: number | null;
    expires_at: number | null;
};

export type TaskRow = {
    swarm: string;
    idx: number;
    items: string;
    status: TaskStatus;
    attempts: number;
    requeues: number;
    thread_id: string | null;
    state: string | null;
    result: string | null;
    error: string | null;
    in_tokens: number;
    out_tokens: number;
    usd: number;
    started_at: number | null;
    heartbeat_at: number | null;
    ended_at: number | null;
};

export type ChangeRow = {
    swarm: string;
    n: number;
    task: number;
    op: string;
    args: string;
    target: string | null;
    before: string | null;
    after: string | null;
    edit_arg: string | null;
    preview_url: string | null;
    keep: number;
    status: "proposed" | "applying" | "done" | "failed" | "skipped";
    error: string | null;
    clash: string | null;
};

export const specOf = (r: SwarmRow): Spec => JSON.parse(r.spec) as Spec;

const parse = <T>(s: string | null, fallback: T): T => {
    if (s === null) return fallback;
    try {
        return JSON.parse(s) as T;
    } catch {
        return fallback;
    }
};

type Cell = { idx: number; status: TaskStatus; error: string | null };
type ChangeCounts = { total: number; kept: number; done: number; failed: number };

export const approveUrl = (webOrigin: string, id: string) => `${webOrigin.replace(/\/+$/, "")}/swarms/${id}`;

// The swarm as the routes, the MCP and the web page see it.
export const ITEMS_SAMPLE = 10;

export function swarmShape(
    r: SwarmRow,
    cells: Cell[],
    changes: ChangeCounts | null,
    webOrigin: string,
    extra: { itemsSample: unknown[]; unscopedWrites: string[] } = { itemsSample: [], unscopedWrites: [] },
) {
    const spec = specOf(r);
    const count = (s: TaskStatus) => cells.filter((c) => c.status === s).length;
    return {
        swarm: r.id,
        name: r.name,
        mode: r.mode,
        status: r.status,
        spec_hash: r.spec_hash,
        prompt: spec.prompt,
        tools: spec.tools,
        writes: spec.writes,
        scope: spec.scope,
        items: r.item_count,
        batch_size: spec.batch_size,
        concurrency: spec.concurrency,
        tasks: { total: cells.length, queued: count("queued"), running: count("running"), done: count("done"), failed: count("failed"), cells },
        estimate_usd: { low: r.est_low, high: r.est_high },
        cap_usd: r.cap_usd,
        spent_usd: round4(r.spent_usd),
        created_at: r.created_at,
        approved_at: r.approved_at,
        finished_at: r.finished_at,
        expires_at: r.expires_at,
        reduce: r.reduce_result,
        error: r.error,
        changes: r.mode === "propose" ? (changes ?? { total: 0, kept: 0, done: 0, failed: 0 }) : null,
        apply: { status: r.apply_status, done: changes?.done ?? 0, failed: changes?.failed ?? 0, total: changes?.kept ?? 0 },
        spec_preview: {
            items_sample: extra.itemsSample.slice(0, ITEMS_SAMPLE),
            source: spec.source,
            output_schema: (spec.output?.schema ?? null) as unknown,
            reduce_prompt: spec.reduce?.prompt ?? null,
            turns_per_task: spec.turns,
            attempts: spec.attempts,
            stop_after_failed_tasks: spec.stop_after,
        },
        unscoped_writes: extra.unscopedWrites,
        approve_url: approveUrl(webOrigin, r.id),
        job: swarmJob(r.id),
    };
}
export type SwarmShape = ReturnType<typeof swarmShape>;

export const changeShape = (c: ChangeRow) => ({
    n: c.n,
    task: c.task,
    op: c.op,
    args: parse<Record<string, unknown>>(c.args, {}),
    target: c.target,
    before: c.before,
    after: c.after,
    edit_arg: c.edit_arg,
    preview_url: c.preview_url,
    keep: c.keep === 1,
    status: c.status,
    error: c.error,
    clash: c.clash,
});
export type SwarmChange = ReturnType<typeof changeShape>;

export const resultShape = (t: TaskRow) => ({ task: t.idx, status: t.status, result: parse<unknown>(t.result, null), error: t.error, usd: round4(t.usd) });

// ---- D1 ---------------------------------------------------------------------------------------------------------------

export async function swarmRow(db: D1Database, id: string): Promise<SwarmRow | null> {
    return (await db.prepare("SELECT * FROM swarms WHERE id = ?1").bind(id).first<SwarmRow>()) ?? null;
}

export async function cellsOf(db: D1Database, id: string): Promise<Cell[]> {
    const { results } = await db.prepare("SELECT idx, status, error FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx").bind(id).all<Cell>();
    return results.map((c) => ({ idx: c.idx, status: c.status, error: c.error }));
}

export async function changeCounts(db: D1Database, id: string): Promise<ChangeCounts> {
    const r = await db
        .prepare(
            `SELECT COUNT(*) AS total, COALESCE(SUM(keep), 0) AS kept,
                    COALESCE(SUM(CASE WHEN keep = 1 AND status = 'done' THEN 1 ELSE 0 END), 0) AS done,
                    COALESCE(SUM(CASE WHEN keep = 1 AND status = 'failed' THEN 1 ELSE 0 END), 0) AS failed
               FROM swarm_changes WHERE swarm = ?1`,
        )
        .bind(id)
        .first<ChangeCounts>();
    return { total: r?.total ?? 0, kept: r?.kept ?? 0, done: r?.done ?? 0, failed: r?.failed ?? 0 };
}

export async function itemsSample(db: D1Database, id: string): Promise<unknown[]> {
    const { results } = await db.prepare("SELECT items FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx LIMIT ?2").bind(id, ITEMS_SAMPLE).all<{ items: string }>();
    return results.flatMap((t) => parse<unknown[]>(t.items, [])).slice(0, ITEMS_SAMPLE);
}

export async function shapeOf(db: D1Database, registry: Registry, r: SwarmRow, webOrigin: string): Promise<SwarmShape> {
    const [cells, changes, sample] = await Promise.all([cellsOf(db, r.id), r.mode === "propose" ? changeCounts(db, r.id) : Promise.resolve(null), itemsSample(db, r.id)]);
    return swarmShape(r, cells, changes, webOrigin, { itemsSample: sample, unscopedWrites: unscopedWrites(registry, specOf(r)) });
}

export async function setSwarm(db: D1Database, id: string, fields: Partial<Omit<SwarmRow, "id">>, now: number): Promise<void> {
    const keys = Object.keys(fields) as (keyof typeof fields)[];
    const sets = keys.map((k, i) => `${k} = ?${i + 2}`).join(", ");
    await db
        .prepare(`UPDATE swarms SET ${sets}${keys.length ? ", " : ""}updated_at = ?${keys.length + 2} WHERE id = ?1`)
        .bind(id, ...keys.map((k) => fields[k] as unknown), now)
        .run();
}

// Plans nobody approved within the hour become `expired`.
export async function expirePlans(db: D1Database, now: number): Promise<void> {
    await db.prepare("UPDATE swarms SET status = 'expired', updated_at = ?1 WHERE status = 'awaiting_approval' AND expires_at IS NOT NULL AND expires_at <= ?1").bind(now).run();
}

export const dayOf = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export async function daySpent(db: D1Database, now: number): Promise<number> {
    const r = await db.prepare("SELECT usd FROM swarm_spend WHERE day = ?1").bind(dayOf(now)).first<{ usd: number }>();
    return r?.usd ?? 0;
}

export async function runningCounts(db: D1Database, keyId: string): Promise<{ mine: number; all: number }> {
    const r = await db
        .prepare("SELECT COUNT(*) AS all_n, COALESCE(SUM(CASE WHEN key_id = ?1 THEN 1 ELSE 0 END), 0) AS mine FROM swarms WHERE status IN ('running', 'stopping') OR apply_status = 'applying'")
        .bind(keyId)
        .first<{ all_n: number; mine: number }>();
    return { mine: r?.mine ?? 0, all: r?.all_n ?? 0 };
}

// Stores a checked plan with its tasks (status awaiting_approval).
export async function insertPlan(
    db: D1Database,
    p: { id: string; keyId: string; spec: Spec; batches: unknown[][]; items: number; hash: string; estimate: { low: number; high: number }; now: number },
): Promise<void> {
    const stmts: D1PreparedStatement[] = [
        db
            .prepare(
                `INSERT INTO swarms (id, key_id, name, mode, spec, spec_hash, round, status, item_count, task_count, est_low, est_high, cap_usd, created_at, updated_at, expires_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, 'awaiting_approval', ?7, ?8, ?9, ?10, ?11, ?12, ?12, ?13)`,
            )
            .bind(p.id, p.keyId, p.spec.name, p.spec.mode, JSON.stringify(p.spec), p.hash, p.items, p.batches.length, p.estimate.low, p.estimate.high, p.spec.cap_usd, p.now, p.now + PLAN_TTL_MS),
    ];
    // the tasks over one JSON param a statement (D1 allows 100 bound params a statement)
    for (let i = 0; i < p.batches.length; i += INSERT_CHUNK) {
        const items = p.batches.slice(i, i + INSERT_CHUNK).map((b) => JSON.stringify(b));
        stmts.push(
            db.prepare("INSERT INTO swarm_tasks (swarm, idx, items) SELECT ?1, ?2 + j.key, j.value FROM json_each(?3) j ORDER BY j.key").bind(p.id, i, JSON.stringify(items)),
        );
    }
    await db.batch(stmts);
}

export async function batchesOf(db: D1Database, id: string): Promise<unknown[][]> {
    const { results } = await db.prepare("SELECT items FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx").bind(id).all<{ items: string }>();
    return results.map((r) => parse<unknown[]>(r.items, []));
}

// What jobs.wait / job_status see for `swarm:<id>`.
export function swarmJobState(r: SwarmRow, cells: Cell[]) {
    const done = cells.filter((c) => c.status === "done").length;
    const failed = cells.filter((c) => c.status === "failed").length;
    const base = { job: swarmJob(r.id), swarm: r.id, name: r.name };
    const summary = `${done} of ${cells.length} tasks done${failed ? `, ${failed} failed` : ""}, $${round4(r.spent_usd)} spent`;
    switch (r.status) {
        case "awaiting_approval":
            return { ...base, status: "queued", activity: "waiting for Harmony to approve" };
        case "running":
        case "stopping":
            return { ...base, status: "running", progress: cells.length ? Math.round(((done + failed) / cells.length) * 100) / 100 : null, activity: summary };
        case "done":
            return { ...base, status: "done", result: r.reduce_result ? `${summary}. ${r.reduce_result}` : `${summary}.` };
        case "failed":
            return { ...base, status: "error", error: r.error ?? "error.swarm.failed", result: summary };
        default:
            return { ...base, status: "cancelled", result: `${r.status}: ${summary}` };
    }
}

// ---- the toolbox ------------------------------------------------------------------------------------------------------

// A token bucket per kind of 7TV call, shared by every task of one alarm.
export class Limiter {
    private next = new Map<string, number>();
    constructor(
        private now: () => number,
        private sleep: (ms: number) => Promise<void>,
    ) {}
    async wait(kind: string, gapMs: number): Promise<void> {
        const now = this.now();
        const at = Math.max(now, this.next.get(kind) ?? 0);
        this.next.set(kind, at + gapMs);
        if (at > now) await this.sleep(at - now);
    }
}

export type ToolboxOpts = {
    swarm: string;
    spec: Spec;
    // the calls this toolbox offers: reads (tools) and, for act mode and the executor, writes
    calls: string[];
    collect: ChatCollect;
    limiter: Limiter;
    task: number | null;
};

const swarmFlags = (base: OpBase): AiFlags => ({ search: base.embed() !== null, subagent: true });

// The ops of these call names that are offered with these flags, as their own little registry (the cheat sheet).
function subRegistry(base: OpBase, calls: string[]): Registry {
    const want = new Set(calls);
    return new Registry(base.registry.toolsFor("chat", swarmFlags(base)).filter((op) => want.has(op.name)));
}

// A swarm never shows confirm cards: its writes were approved with the swarm, so the cheat sheet's "asks first" goes.
const noAsking = (text: string) =>
    text
        .split("\n")
        .filter((l) => !/^\s*\/\/ (Asks Harmony first: returns|When it asks Harmony first)/.test(l))
        .join("\n")
        .replace(/ Asks Harmony first\./g, "");

export const cheatSheet = (base: OpBase, calls: string[]) => noAsking(toolTypesFor(subRegistry(base, calls), swarmFlags(base)));

// The calls a proposal may name, as the args object each takes (JSON Schema), one line each.
export function proposalDoc(base: OpBase, writes: string[]): string {
    return writes
        .map((name) => {
            const op = base.registry.op(name);
            if (!op) return "";
            let schema: Record<string, unknown> = {};
            try {
                schema = z.toJSONSchema(op.input, { target: "draft-2020-12", unrepresentable: "any", io: "input" }) as Record<string, unknown>;
            } catch {
                // an input JSON Schema cannot show: the summary alone
            }
            delete schema.$schema;
            return `- ${name}: ${noAsking(op.ai.summary.split("\n")[0]!)} args: ${JSON.stringify(schema)}`;
        })
        .filter(Boolean)
        .join("\n");
}

export const UNKNOWN_WRITE = "unknown: may already be applied, check and re-tick";

// A swarm's `cobalt`: only the allowed calls. Writes run without a confirm card (the swarm's approval covered them),
// only inside the scope, at most one 7TV write a second, and each at most once (the swarm_writes ledger).
export function swarmToolbox(base: OpBase, o: ToolboxOpts): ChatTools {
    const allowed = new Set(o.calls);
    const writes = new Set(o.spec.writes);
    const legacy = chatTools({ db: base.db, mediaBaseUrl: base.mediaBaseUrl, shareBaseUrl: base.shareBaseUrl, embed: base.embed() }, o.collect);
    const box = chatToolbox(base.registry, base, {
        threadId: o.swarm,
        messageId: null,
        collect: o.collect,
        legacy,
        flags: swarmFlags(base),
        pending: null,
        jobs: null,
        allow: (op) => allowed.has(op.name),
        preapproved: (op, input) => writes.has(op.name) && allowed.has(op.name) && scopeProblem(o.spec.scope, input) === null,
    });
    const tools: ChatTools = {};
    for (const [name, fn] of Object.entries(box.tools)) {
        const op = base.registry.byCall(name);
        if (!op || !fn) continue;
        const sevenTv = op.name.startsWith("seventv.") || op.name === "emotes.find";
        if (!writes.has(op.name)) {
            tools[name] = sevenTv
                ? async (...args: unknown[]) => {
                      await o.limiter.wait("7tv:read", SEVENTV_READ_GAP_MS);
                      return fn(...args);
                  }
                : fn;
            continue;
        }
        tools[name] = async (...args: unknown[]) => {
            const parsed = op.input.safeParse(argsToInput(op, args));
            if (!parsed.success) return fn(...args); // the toolbox answers the input's mistake
            const problem = scopeProblem(o.spec.scope, parsed.data);
            if (problem) throw new Error(`cobalt.${op.callName}: ${problem}`);
            const hash = await argsHash(op.name, parsed.data);
            // the ledger row is the guard: a pending row goes in before the write, so two identical writes (two tasks,
            // or a resumed alarm) cannot both run; whoever did not insert it does not write
            const claimed = await base.db
                .prepare("INSERT OR IGNORE INTO swarm_writes (swarm, op, args_hash, task, status, at) VALUES (?1, ?2, ?3, ?4, 'pending', ?5)")
                .bind(o.swarm, op.name, hash, o.task, base.now())
                .run();
            if ((claimed.meta?.changes ?? 0) === 0) {
                const had = await base.db
                    .prepare("SELECT status, result FROM swarm_writes WHERE swarm = ?1 AND op = ?2 AND args_hash = ?3")
                    .bind(o.swarm, op.name, hash)
                    .first<{ status: string; result: string | null }>();
                if (had?.status === "done") return parse<unknown>(had.result, null);
                throw new Error(UNKNOWN_WRITE);
            }
            let out: unknown;
            try {
                if (sevenTv) await o.limiter.wait("7tv:write", SEVENTV_WRITE_GAP_MS);
                out = await fn(...args);
            } catch (e) {
                // the op refused (it did not write): the change may be tried again
                await base.db.prepare("DELETE FROM swarm_writes WHERE swarm = ?1 AND op = ?2 AND args_hash = ?3 AND status = 'pending'").bind(o.swarm, op.name, hash).run();
                throw e;
            }
            await base.db
                .prepare("UPDATE swarm_writes SET status = 'done', result = ?4, at = ?5 WHERE swarm = ?1 AND op = ?2 AND args_hash = ?3")
                .bind(o.swarm, op.name, hash, JSON.stringify(out ?? null).slice(0, 4000), base.now())
                .run();
            return out;
        };
    }
    return tools;
}

// `source` (section 59.2): a read call run at plan time, its pages followed, the list at `path`.
export async function itemsFromSource(base: OpBase, swarm: string, spec: Spec, sleep: (ms: number) => Promise<void>): Promise<unknown[]> {
    const src = spec.source!;
    const op = base.registry.op(src.call);
    if (!op) throw badSpec(`source.call: ${src.call} does not exist`);
    const tools = swarmToolbox(base, { swarm, spec: { ...spec, writes: [] }, calls: [src.call], collect: { look: [], show: [], collage: null }, limiter: new Limiter(base.now, sleep), task: null });
    const fn = tools[op.callName];
    if (!fn) throw badSpec(`source.call: ${src.call} is not offered on this server`);
    const items: unknown[] = [];
    let args: Record<string, unknown> = { ...src.args };
    for (let page = 0; page < SOURCE_PAGES_MAX; page++) {
        let out: unknown;
        try {
            out = await fn(...positionalArgs(op, args));
        } catch (e) {
            throw badSpec(`source: ${e instanceof Error ? e.message.slice(0, 300) : String(e)}`);
        }
        const list = atPath(out, src.path);
        if (!Array.isArray(list)) throw badSpec(`source: the answer has no list at ${src.path ? `"${src.path}"` : "its top"}`);
        items.push(...list);
        if (items.length >= ITEMS_MAX) break;
        const o = out as { has_more?: unknown; page?: unknown };
        if (o?.has_more !== true || typeof o.page !== "number" || !("page" in (((op.input as unknown as { shape?: object }).shape) ?? {}))) break;
        args = { ...args, page: o.page + 1 };
    }
    return items.slice(0, ITEMS_MAX);
}

// ---- a task's prompt and answer ---------------------------------------------------------------------------------------

export const RUN_CODE_TOOL = {
    name: "run_code",
    description:
        "Run JavaScript against Harmony's library. The code is the body of an async function: use await and `return` the result. The global `cobalt` object is the only API (see the system prompt for its types); there is no network, no fetch, no require or import. Returns { result, logs } or { error, logs }.",
    input_schema: {
        type: "object",
        properties: { code: { type: "string", description: "JavaScript, the body of an async function. Return the result." } },
        required: ["code"],
        additionalProperties: false,
    },
    cache_control: { type: "ephemeral" },
};

export function taskSystem(spec: Spec, o: { index: number; total: number; items: number; reads: string; writes: string; now: number }): string {
    const scope = Object.keys(spec.scope).length ? ` Writes are limited to this scope: ${JSON.stringify(spec.scope)}.` : "";
    const modeText =
        spec.mode === "propose"
            ? `Change nothing yourself: you propose. Your answer is {"changes":[...]}, one object per change: { "op": one of ${JSON.stringify(spec.writes)}, "args": the exact input object of that call (shapes below, never run them), "target": what it changes (a short label), "before": the current value or null, "after": the new value or null, "edit_arg": the key in args that holds the new value Harmony may edit (e.g. "alias"), "preview_url": an https picture of the target or null (a 7TV emote: https://cdn.7tv.app/emote/<id>/2x.webp) }.${scope} Leave out anything that needs no change; {"changes":[]} is a fine answer.

The calls a change may name (for proposals only: they are not in cobalt), with the args object each takes:
${o.writes}`
            : spec.mode === "act"
              ? `You may call these writes yourself, already approved for this swarm (no confirm card): ${spec.writes.map((w) => `cobalt.${w}`).join(", ")}.${scope} Make each write once, only when the task asks for it. Then answer with JSON${spec.output ? " matching this JSON Schema" : ""}.${spec.output ? `\n${JSON.stringify(spec.output.schema)}` : ""}`
              : `You only read. Answer with JSON${spec.output ? " matching this JSON Schema" : ""}.${spec.output ? `\n${JSON.stringify(spec.output.schema)}` : ""}`;
    return `You are one worker in a swarm of AI tasks inside capystore, Harmony's private media saver. The swarm "${spec.name}" split ${o.items} items into ${o.total} batches; you see only batch ${o.index} of ${o.total}, in the message below. Other workers handle the other batches: never ask about them.

You work through the run_code tool: JavaScript (not TypeScript) run as the body of an async function in a sandbox with no network. The global \`cobalt\` holds only the calls listed below; \`return\` a small result (a few fields beat whole records). console.log works. You have at most ${spec.turns} model turns. Today is ${new Date(o.now).toISOString().slice(0, 10)}.

${modeText}

Your final message must be ONLY the JSON answer: no prose, no markdown, no code fences.

The API:
${o.reads}`;
}

// The JSON in a final message: the whole text, or the text inside a code fence, or from its first { or [ on.
export function answerJson(text: string): { ok: true; value: unknown } | { ok: false } {
    const t = text.trim();
    const tries = [t, /```(?:json)?\s*([\s\S]*?)```/.exec(t)?.[1]?.trim() ?? ""];
    const first = t.search(/[[{]/);
    if (first >= 0) tries.push(t.slice(first, Math.max(t.lastIndexOf("}"), t.lastIndexOf("]")) + 1));
    for (const s of tries) {
        if (!s) continue;
        try {
            return { ok: true, value: JSON.parse(s) };
        } catch {
            // the next way
        }
    }
    return { ok: false };
}

const str = (v: unknown, max = TEXT_FIELD_MAX): string | null => {
    if (v === null || v === undefined) return null;
    const s = typeof v === "string" ? v : JSON.stringify(v);
    return Array.from(s).slice(0, max).join("");
};

export type Proposal = { op: string; args: Record<string, unknown>; target: string | null; before: string | null; after: string | null; edit_arg: string | null; preview_url: string | null };

// The checks one change must pass: an op in writes, args its zod input takes, inside the scope.
export function changeProblem(registry: Registry, spec: Pick<Spec, "writes" | "scope">, op: string, args: unknown): string | null {
    if (!spec.writes.includes(op)) return `op ${JSON.stringify(op)} is not one of ${JSON.stringify(spec.writes)}`;
    const o = registry.op(op);
    if (!o) return `op ${op} does not exist`;
    if (!args || typeof args !== "object" || Array.isArray(args)) return "args must be an object";
    const parsed = o.input.safeParse(args);
    if (!parsed.success) return parsed.error.issues.slice(0, 3).map((i) => `${i.path.length ? i.path.join(".") : "args"}: ${i.message}`).join("; ");
    return scopeProblem(spec.scope, parsed.data);
}

// A propose-mode answer, checked: the changes, or what is wrong with it (for the repair turn).
export function checkProposals(registry: Registry, spec: Spec, value: unknown): { ok: true; changes: Proposal[] } | { ok: false; why: string } {
    const list = (value as { changes?: unknown } | null)?.changes;
    if (!value || typeof value !== "object" || Array.isArray(value) || !Array.isArray(list)) return { ok: false, why: 'the answer must be an object {"changes": [...]}' };
    if (list.length > CHANGES_PER_TASK_MAX) return { ok: false, why: `at most ${CHANGES_PER_TASK_MAX} changes` };
    const out: Proposal[] = [];
    const problems: string[] = [];
    list.forEach((c, i) => {
        const ch = c as Record<string, unknown> | null;
        if (!ch || typeof ch !== "object" || Array.isArray(ch)) return void problems.push(`changes[${i}]: not an object`);
        const op = typeof ch.op === "string" ? ch.op.replace(/^cobalt\./, "") : "";
        const problem = changeProblem(registry, spec, op, ch.args);
        if (problem) return void problems.push(`changes[${i}]: ${problem}`);
        const args = registry.op(op)!.input.parse(ch.args) as Record<string, unknown>;
        // edit_arg comes from the op's whitelist only (never the model's word), and then `after` is that arg's value.
        const editArg = EDIT_ARGS[op] ?? null;
        const after = editArg ? str(args[editArg] ?? null) : str(ch.after);
        const preview = typeof ch.preview_url === "string" && /^https:\/\/[^\s]+$/.test(ch.preview_url) && ch.preview_url.length <= 1000 ? ch.preview_url : null;
        out.push({ op, args, target: str(ch.target), before: str(ch.before), after, edit_arg: editArg, preview_url: preview });
    });
    if (problems.length > 0) return { ok: false, why: problems.slice(0, 6).join("\n") };
    return { ok: true, changes: out };
}

// The group a change belongs to for clashes: its op and the target it writes to (the scope keys' values, or else its
// id-like args other than the item's own id).
export function clashGroup(spec: Pick<Spec, "scope">, op: string, args: Record<string, unknown>): string {
    const keys = Object.keys(spec.scope);
    const where = keys.length
        ? keys.map((k) => `${k}=${String(args[k] ?? "")}`).join("&")
        : Object.entries(args)
              .filter(([k]) => /(^|_)id$/.test(k) && k !== "emote_id" && k !== "id")
              .sort(([a], [b]) => (a < b ? -1 : 1))
              .map(([k, v]) => `${k}=${String(v)}`)
              .join("&");
    return `${op}\n${where}`;
}

// The clash of each kept change (null: none): its args no longer pass the checks, the same change twice, or the same
// edited value (args[edit_arg]) as another kept change of the same op on the same target (two emotes taking one name in
// a set). Computed from args only, never from the display text.
export function clashesOf(registry: Registry, spec: Pick<Spec, "writes" | "scope">, rows: ChangeRow[]): Map<number, string | null> {
    const out = new Map<number, string | null>();
    const seen = new Map<string, number>();
    const afters = new Map<string, number[]>();
    for (const r of rows) {
        out.set(r.n, null);
        if (r.keep !== 1) continue;
        const args = parse<Record<string, unknown>>(r.args, {});
        const problem = changeProblem(registry, spec, r.op, args);
        if (problem) {
            out.set(r.n, `invalid: ${problem}`.slice(0, 300));
            continue;
        }
        const key = `${r.op}\n${stableJson(args)}`;
        const twin = seen.get(key);
        if (twin !== undefined) {
            out.set(r.n, `duplicate: the same change as #${twin}`);
            continue;
        }
        seen.set(key, r.n);
        const editArg = EDIT_ARGS[r.op];
        const value = editArg ? args[editArg] : undefined;
        if (typeof value === "string" && value !== "") {
            const ak = `${clashGroup(spec, r.op, args)}\n${value.toLowerCase()}`;
            afters.set(ak, [...(afters.get(ak) ?? []), r.n]);
        }
    }
    for (const ns of afters.values()) {
        if (ns.length < 2) continue;
        for (const n of ns) if (out.get(n) === null) out.set(n, `duplicate name: also proposed by #${ns.filter((x) => x !== n).slice(0, 3).join(", #")}`);
    }
    return out;
}

const UPDATE_CHUNK = 50;

// Writes the clashes of a swarm's changes (only the rows whose clash changed). With `groups`, only the changes in those
// clash groups (the ones a decide touched) are looked at.
export async function refreshClashes(db: D1Database, registry: Registry, swarm: string, spec: Spec, groups?: Set<string>): Promise<void> {
    const { results } = await db.prepare("SELECT * FROM swarm_changes WHERE swarm = ?1 ORDER BY task, n").bind(swarm).all<ChangeRow>();
    const rows = groups ? results.filter((r) => groups.has(clashGroup(spec, r.op, parse<Record<string, unknown>>(r.args, {})))) : results;
    if (rows.length === 0) return;
    const clashes = clashesOf(registry, spec, rows);
    const changed = rows.filter((r) => (clashes.get(r.n) ?? null) !== r.clash);
    // one statement per chunk, one bound JSON param each (D1 allows 100 bound params a statement)
    for (let i = 0; i < changed.length; i += UPDATE_CHUNK * 10) {
        const pairs = changed.slice(i, i + UPDATE_CHUNK * 10).map((r) => [r.n, clashes.get(r.n) ?? null]);
        await db
            .prepare(
                `UPDATE swarm_changes SET clash = (SELECT json_extract(j.value, '$[1]') FROM json_each(?2) j WHERE json_extract(j.value, '$[0]') = swarm_changes.n)
                  WHERE swarm = ?1 AND n IN (SELECT json_extract(value, '$[0]') FROM json_each(?2))`,
            )
            .bind(swarm, JSON.stringify(pairs))
            .run();
    }
}

// ---- the runner -------------------------------------------------------------------------------------------------------

export type SwarmRunDeps = {
    base: OpBase;
    model: ChatModel | null;
    runner: CodeRunner | null;
    sleep: (ms: number) => Promise<void>;
    look?: LookDeps;
    // tests shorten these
    tickBudgetMs?: number;
    tickHardMs?: number;
};

// What one alarm comes to: run again in this many ms, or nothing left (null).
export type SwarmTickOutcome = { again: number | null };

type TaskState = { messages: any[]; turns: number; repaired: boolean };

const RETRYABLE = /\b(429|500|502|503|504|529)\b|overloaded|rate.?limit|Request not allowed|timed? ?out|ECONNRESET|fetch failed|network/i;
export const retryableModelError = (e: unknown) => RETRYABLE.test(e instanceof Error ? e.message : String(e));

// One model call, tried again on a passing failure (not an attempt of the task).
async function modelTurn(d: SwarmRunDeps, req: { system: string; tools: any[]; messages: any[] }): Promise<ModelTurn> {
    for (let i = 0; ; i++) {
        try {
            return await d.model!.turn({ ...req, onText: () => {} });
        } catch (e) {
            if (i < MODEL_BACKOFF_MS.length && retryableModelError(e)) {
                await d.sleep(MODEL_BACKOFF_MS[i]!);
                continue;
            }
            throw e;
        }
    }
}

// Books a model call's dollars on the task, the swarm and the day.
async function charge(d: SwarmRunDeps, swarm: string, idx: number | null, usage: ModelUsage | undefined, fallbackChars: number): Promise<number> {
    const usd = usage ? usdOf(usage) : (tokensOf(fallbackChars) * PRICE.input) / 1e6;
    const now = d.base.now();
    const db = d.base.db;
    const stmts = [
        db.prepare("UPDATE swarms SET spent_usd = spent_usd + ?2, updated_at = ?3 WHERE id = ?1").bind(swarm, usd, now),
        db.prepare("INSERT INTO swarm_spend (day, usd) VALUES (?1, ?2) ON CONFLICT(day) DO UPDATE SET usd = usd + excluded.usd").bind(dayOf(now), usd),
    ];
    if (idx !== null) {
        stmts.push(
            db
                .prepare("UPDATE swarm_tasks SET in_tokens = in_tokens + ?3, out_tokens = out_tokens + ?4, usd = usd + ?5, heartbeat_at = ?6 WHERE swarm = ?1 AND idx = ?2")
                .bind(swarm, idx, (usage?.input_tokens ?? 0) + (usage?.cache_read_input_tokens ?? 0) + (usage?.cache_creation_input_tokens ?? 0), usage?.output_tokens ?? 0, usd, now),
        );
    }
    await db.batch(stmts);
    return usd;
}

// Why no more model calls may start now (stop asked, the swarm's cap, the day's cap), or null.
async function haltReason(d: SwarmRunDeps, swarm: string): Promise<string | null> {
    const r = await swarmRow(d.base.db, swarm);
    if (!r || r.stop_requested === 1 || r.status === "stopping") return "error.swarm.stopped";
    if (r.spent_usd >= r.cap_usd) return "error.swarm.over_cap";
    if ((await daySpent(d.base.db, d.base.now())) >= dailyUsdOf(d.base.env)) return "error.swarm.daily_cap";
    return null;
}

const clip = (s: string, max: number) => (s.length > max ? `${s.slice(0, max)}… (cut: return less)` : s);
const textOf = (content: any[]) =>
    content
        .filter((b) => b?.type === "text")
        .map((b) => String(b.text ?? ""))
        .join("\n");

type TaskEnd = { kind: "done"; result: unknown; changes: Proposal[] } | { kind: "failed"; error: string } | { kind: "halted"; error: string } | { kind: "paused" };

// One attempt of one task, from its saved conversation on. Never throws for the model's own mistakes.
async function attemptTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, task: TaskRow, limiter: Limiter, deadline: number): Promise<TaskEnd> {
    const { base } = d;
    const db = base.db;
    const total = row.task_count;
    const items = parse<unknown[]>(task.items, []);
    const reads = cheatSheet(base, spec.mode === "act" ? [...spec.tools, ...spec.writes] : spec.tools);
    const writes = spec.mode === "propose" ? proposalDoc(base, spec.writes) : "";
    const system = taskSystem(spec, { index: task.idx + 1, total, items: row.item_count, reads, writes, now: base.now() });
    const state = parse<TaskState | null>(task.state, null) ?? {
        messages: [{ role: "user", content: fillPrompt(spec.prompt, { items, index: task.idx + 1, total, name: spec.name }) }],
        turns: 0,
        repaired: false,
    };
    const save = () =>
        db.prepare("UPDATE swarm_tasks SET state = ?3, heartbeat_at = ?4 WHERE swarm = ?1 AND idx = ?2").bind(row.id, task.idx, JSON.stringify(state), base.now()).run();
    const calls = spec.mode === "act" ? [...spec.tools, ...spec.writes] : spec.tools;
    const output = spec.output ? schemaOf(spec.output.schema) : null;
    for (;;) {
        if (state.turns >= spec.turns + (state.repaired ? 1 : 0)) return { kind: "failed", error: "error.swarm.out_of_turns" };
        if (base.now() >= deadline) {
            await save();
            return { kind: "paused" };
        }
        const halt = await haltReason(d, row.id);
        if (halt) return { kind: "halted", error: halt };
        let res: ModelTurn;
        try {
            res = await modelTurn(d, { system, tools: calls.length > 0 ? [RUN_CODE_TOOL] : [], messages: state.messages });
        } catch (e) {
            console.error("[swarm] model failed", String(e).slice(0, 300));
            return { kind: "failed", error: "error.swarm.model" };
        }
        state.turns++;
        await charge(d, row.id, task.idx, res.usage, system.length + JSON.stringify(state.messages).length);
        state.messages.push({ role: "assistant", content: res.content });
        const uses = res.content.filter((b: any) => b?.type === "tool_use");
        if (res.stop_reason === "tool_use" && uses.length > 0) {
            const results: any[] = [];
            for (const u of uses) {
                if (u.name !== "run_code" || typeof u.input?.code !== "string" || !d.runner || calls.length === 0) {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: calls.length === 0 ? "This swarm has no tools: answer from the message alone." : "Only run_code exists, with { code: string }." });
                    continue;
                }
                const collect: ChatCollect = { look: [], show: [], collage: null };
                const tools = swarmToolbox(base, { swarm: row.id, spec, calls, collect, limiter, task: task.idx });
                const out = await d.runner(u.input.code, tools);
                const logs = out.logs.slice(0, LOGS_MAX).map((l) => clip(l, 500));
                const body = out.error !== undefined ? { error: out.error, logs } : { result: out.result ?? null, logs };
                const content: any[] = [{ type: "text", text: clip(JSON.stringify(body) ?? "null", RESULT_MAX) }];
                if (collect.look.length > 0 && d.look) {
                    const imgs = await lookImages(d.look, collect.look.slice(0, 4), collect.lookOpts ?? {}).catch(() => new Map());
                    for (const pid of collect.look.slice(0, 4)) content.push(...lookBlocks(pid, imgs.get(pid), collect.lookOpts?.[pid]?.frames === true));
                }
                results.push({ type: "tool_result", tool_use_id: u.id, ...(out.error !== undefined ? { is_error: true } : {}), content });
            }
            state.messages.push({ role: "user", content: results });
            await save();
            continue;
        }
        // the final answer
        const parsed = answerJson(textOf(res.content));
        let why: string | null = null;
        let result: unknown = null;
        let changes: Proposal[] = [];
        if (!parsed.ok) why = "it is not JSON";
        else if (spec.mode === "propose") {
            const c = checkProposals(base.registry, spec, parsed.value);
            if (c.ok) {
                changes = c.changes;
                result = { changes: c.changes.length };
            } else why = c.why;
        } else if (output) {
            const r = output.safeParse(parsed.value);
            if (r.success) result = parsed.value;
            else why = r.error.issues.slice(0, 4).map((i) => `${i.path.length ? i.path.join(".") : "answer"}: ${i.message}`).join("; ");
        } else result = parsed.value;
        if (why === null) return { kind: "done", result, changes };
        if (state.repaired) return { kind: "failed", error: `error.swarm.bad_answer: ${why}`.slice(0, 500) };
        state.repaired = true;
        state.messages.push({ role: "user", content: `Your answer did not match: ${why}\nAnswer again with ONLY the JSON, nothing else.` });
        await save();
    }
}

// Runs one claimed task to its end (or a pause) and records it.
async function runTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, idx: number, limiter: Limiter, deadline: number): Promise<void> {
    const db = d.base.db;
    const task = await db.prepare("SELECT * FROM swarm_tasks WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx).first<TaskRow>();
    if (!task) return;
    let end: TaskEnd;
    try {
        end = await attemptTask(d, row, spec, task, limiter, deadline);
    } catch (e) {
        console.error("[swarm] task failed", String(e).slice(0, 300));
        end = { kind: "failed", error: "error.swarm.task" };
    }
    const now = d.base.now();
    if (end.kind === "paused") {
        await db.prepare("UPDATE swarm_tasks SET status = 'queued' WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx).run();
        return;
    }
    if (end.kind === "halted") {
        await db.prepare("UPDATE swarm_tasks SET status = 'skipped', error = ?3, state = NULL, ended_at = ?4 WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx, end.error, now).run();
        return;
    }
    if (end.kind === "failed") {
        const again = task.attempts < spec.attempts;
        await db
            .prepare("UPDATE swarm_tasks SET status = ?3, error = ?4, state = NULL, ended_at = ?5 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, idx, again ? "queued" : "failed", end.error, again ? null : now)
            .run();
        return;
    }
    const stmts = [
        db.prepare("UPDATE swarm_tasks SET status = 'done', result = ?3, error = NULL, state = NULL, ended_at = ?4 WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx, JSON.stringify(end.result ?? null), now),
        // a task that ran again replaces its earlier proposals
        db.prepare("DELETE FROM swarm_changes WHERE swarm = ?1 AND task = ?2").bind(row.id, idx),
        ...insertChanges(db, row.id, idx, end.changes),
    ];
    await db.batch(stmts);
}

export const INSERT_CHUNK = 100;

// A task's proposals as a few INSERT ... SELECT statements over one JSON param each (D1 allows 100 bound params a
// statement): n continues from the swarm's highest.
export function insertChanges(db: D1Database, swarm: string, task: number, changes: Proposal[]): D1PreparedStatement[] {
    const out: D1PreparedStatement[] = [];
    for (let i = 0; i < changes.length; i += INSERT_CHUNK) {
        const rows = changes.slice(i, i + INSERT_CHUNK).map((c) => [c.op, JSON.stringify(c.args), c.target, c.before, c.after, c.edit_arg, c.preview_url]);
        out.push(
            db
                .prepare(
                    `INSERT INTO swarm_changes (swarm, n, task, op, args, target, before, after, edit_arg, preview_url)
                     SELECT ?1, top.m + j.key + 1, ?2, json_extract(j.value, '$[0]'), json_extract(j.value, '$[1]'), json_extract(j.value, '$[2]'),
                            json_extract(j.value, '$[3]'), json_extract(j.value, '$[4]'), json_extract(j.value, '$[5]'), json_extract(j.value, '$[6]')
                       FROM json_each(?3) j, (SELECT COALESCE(MAX(n), 0) AS m FROM swarm_changes WHERE swarm = ?1) top
                      ORDER BY j.key`,
                )
                .bind(swarm, task, JSON.stringify(rows)),
        );
    }
    return out;
}

// Running tasks with no heartbeat for 5 minutes (their alarm died): queued again once, then failed.
async function watchdog(d: SwarmRunDeps, swarm: string): Promise<void> {
    const db = d.base.db;
    const now = d.base.now();
    const stale = now - HEARTBEAT_STALE_MS;
    await db.batch([
        db
            .prepare("UPDATE swarm_tasks SET status = 'failed', error = 'error.swarm.stalled', state = NULL, ended_at = ?2 WHERE swarm = ?1 AND status = 'running' AND requeues >= 1 AND COALESCE(heartbeat_at, 0) < ?3")
            .bind(swarm, now, stale),
        db.prepare("UPDATE swarm_tasks SET status = 'queued', requeues = requeues + 1 WHERE swarm = ?1 AND status = 'running' AND COALESCE(heartbeat_at, 0) < ?2").bind(swarm, stale),
    ]);
}

// Claims the next queued task: it is `running` from here on (a new attempt unless it resumes a paused one).
async function claimNext(d: SwarmRunDeps, swarm: string): Promise<number | null> {
    const now = d.base.now();
    const r = await d.base.db
        .prepare(
            `UPDATE swarm_tasks SET status = 'running', attempts = attempts + CASE WHEN state IS NULL THEN 1 ELSE 0 END,
                    started_at = COALESCE(started_at, ?2), heartbeat_at = ?2, error = CASE WHEN state IS NULL THEN NULL ELSE error END
              WHERE swarm = ?1 AND idx = (SELECT idx FROM swarm_tasks WHERE swarm = ?1 AND status = 'queued' ORDER BY idx LIMIT 1) AND status = 'queued'
              RETURNING idx`,
        )
        .bind(swarm, now)
        .first<{ idx: number }>();
    return r?.idx ?? null;
}

type Counts = { queued: number; running: number; done: number; failed: number; skipped: number };
async function taskCounts(db: D1Database, swarm: string): Promise<Counts> {
    const { results } = await db.prepare("SELECT status, COUNT(*) AS n FROM swarm_tasks WHERE swarm = ?1 GROUP BY status").bind(swarm).all<{ status: TaskStatus; n: number }>();
    const c: Counts = { queued: 0, running: 0, done: 0, failed: 0, skipped: 0 };
    for (const r of results) c[r.status] = r.n;
    return c;
}

// The reduce step: one model turn, no tools, over every result.
async function runReduce(d: SwarmRunDeps, row: SwarmRow, spec: Spec): Promise<{ text: string | null; error: string | null }> {
    const halt = await haltReason(d, row.id);
    if (halt) return { text: null, error: halt };
    const { results } = await d.base.db.prepare("SELECT idx, status, result, error FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx").bind(row.id).all<TaskRow>();
    const all = JSON.stringify(results.map((t) => ({ task: t.idx + 1, status: t.status, result: parse<unknown>(t.result, null), error: t.error })));
    const system = `You summarise the results of a swarm of AI tasks ("${spec.name}") inside capystore, Harmony's private media saver, in plain text for Harmony. Be short and concrete.`;
    const messages = [{ role: "user", content: `${spec.reduce!.prompt}\n\nThe results, task by task:\n${clip(all, REDUCE_INPUT_MAX)}` }];
    try {
        const res = await modelTurn(d, { system, tools: [], messages });
        await charge(d, row.id, null, res.usage, system.length + messages[0]!.content.length);
        return { text: textOf(res.content).trim().slice(0, 8000) || null, error: null };
    } catch (e) {
        console.error("[swarm] reduce failed", String(e).slice(0, 300));
        return { text: null, error: "error.swarm.reduce_failed" };
    }
}

// The end of the tasks: the swarm's final status, the reduce step, and the review (propose mode).
async function finishTasks(d: SwarmRunDeps, row: SwarmRow, spec: Spec, halt: string | null): Promise<void> {
    const db = d.base.db;
    const now = d.base.now();
    // a stop asked after a cap or too many failures had already stopped it keeps that reason
    if (halt === "error.swarm.stopped" && row.error && /^error\.swarm\.(over_cap|daily_cap|too_many_failed)$/.test(row.error)) halt = row.error;
    await db.prepare("UPDATE swarm_tasks SET status = 'skipped', error = ?2, state = NULL WHERE swarm = ?1 AND status = 'queued'").bind(row.id, halt ?? "error.swarm.stopped").run();
    const c = await taskCounts(db, row.id);
    let status: SwarmStatus;
    let error: string | null = null;
    let reduce: string | null = null;
    if (halt === "error.swarm.too_many_failed") {
        status = "failed";
        error = halt;
    } else if (halt) {
        status = "stopped";
        error = halt === "error.swarm.stopped" ? null : halt;
    } else if (c.done === 0) {
        status = "failed";
        error = "error.swarm.all_failed";
    } else {
        status = "done";
        if (spec.reduce) {
            const r = await runReduce(d, row, spec);
            reduce = r.text;
            error = r.error;
        }
    }
    let apply: ApplyStatus = "none";
    if (spec.mode === "propose") {
        await refreshClashes(db, d.base.registry, row.id, spec);
        apply = (await changeCounts(db, row.id)).total > 0 ? "ready" : "none";
    }
    await setSwarm(db, row.id, { status, error, reduce_result: reduce, finished_at: now, stop_requested: 0, apply_status: apply }, now);
}

// The tasks' part of one alarm: launch up to `concurrency` at once until the time budget, a stop or a cap.
async function tickTasks(d: SwarmRunDeps, row: SwarmRow, spec: Spec, started: number): Promise<SwarmTickOutcome> {
    const db = d.base.db;
    await watchdog(d, row.id);
    const limiter = new Limiter(d.base.now, d.sleep);
    const budget = started + (d.tickBudgetMs ?? TICK_BUDGET_MS);
    const deadline = started + (d.tickHardMs ?? TICK_HARD_MS);
    const inflight = new Set<Promise<void>>();
    let halt: string | null = null;
    for (;;) {
        halt = await haltReason(d, row.id);
        if (!halt && (await taskCounts(db, row.id)).failed >= spec.stop_after) halt = "error.swarm.too_many_failed";
        if (halt || d.base.now() >= budget) break;
        while (inflight.size < spec.concurrency) {
            const idx = await claimNext(d, row.id);
            if (idx === null) break;
            const p: Promise<void> = runTask(d, row, spec, idx, limiter, deadline).finally(() => inflight.delete(p));
            inflight.add(p);
        }
        if (inflight.size === 0) break;
        await Promise.race(inflight);
    }
    await Promise.all(inflight);
    if (halt === "error.swarm.stopped" || halt === "error.swarm.over_cap" || halt === "error.swarm.daily_cap" || halt === "error.swarm.too_many_failed") {
        if (halt !== "error.swarm.stopped") await setSwarm(db, row.id, { status: "stopping", error: halt }, d.base.now());
    }
    const c = await taskCounts(db, row.id);
    if (!halt) {
        if (c.queued > 0) return { again: 0 };
        if (c.running > 0) return { again: 60_000 }; // tasks of a dead alarm: the watchdog takes them
    } else if (c.running > 0) return { again: 60_000 };
    const fresh = (await swarmRow(db, row.id)) ?? row;
    await finishTasks(d, fresh, spec, halt ?? (c.failed >= spec.stop_after ? "error.swarm.too_many_failed" : null));
    return { again: null };
}

// The apply executor (propose mode): no model, the kept changes through their ops, in order, each at most once.
async function tickApply(d: SwarmRunDeps, row: SwarmRow, spec: Spec, started: number): Promise<SwarmTickOutcome> {
    const db = d.base.db;
    const budget = started + (d.tickBudgetMs ?? TICK_BUDGET_MS);
    const limiter = new Limiter(d.base.now, d.sleep);
    const tools = swarmToolbox(d.base, { swarm: row.id, spec, calls: spec.writes, collect: { look: [], show: [], collage: null }, limiter, task: null });
    // a change an earlier alarm left mid-way runs again through the ledger: done there answers its stored result, pending
    // fails it as unknown (UNKNOWN_WRITE) for Harmony to check and re-tick
    await db.prepare("UPDATE swarm_changes SET status = 'proposed' WHERE swarm = ?1 AND status = 'applying'").bind(row.id).run();
    for (;;) {
        const cur = await swarmRow(db, row.id);
        if (!cur || cur.stop_requested === 1) {
            await setSwarm(db, row.id, { apply_status: "ready", stop_requested: 0 }, d.base.now());
            return { again: null };
        }
        if (d.base.now() >= budget) return { again: 0 };
        const c = await db.prepare("SELECT * FROM swarm_changes WHERE swarm = ?1 AND keep = 1 AND status = 'proposed' ORDER BY task, n LIMIT 1").bind(row.id).first<ChangeRow>();
        if (!c) break;
        await db.prepare("UPDATE swarm_changes SET status = 'applying' WHERE swarm = ?1 AND n = ?2").bind(row.id, c.n).run();
        const op = d.base.registry.op(c.op);
        const args = parse<Record<string, unknown>>(c.args, {});
        const problem = changeProblem(d.base.registry, spec, c.op, args);
        let status: ChangeRow["status"] = "done";
        let error: string | null = null;
        if (problem || !op || !tools[op.callName]) {
            status = "failed";
            error = (problem ?? `cobalt.${c.op} is not offered on this server`).slice(0, 300);
        } else {
            try {
                await tools[op.callName]!(...positionalArgs(op, op.input.parse(args) as Record<string, unknown>));
            } catch (e) {
                status = "failed";
                error = (e instanceof Error ? e.message : String(e)).slice(0, 300);
            }
        }
        await db.prepare("UPDATE swarm_changes SET status = ?3, error = ?4 WHERE swarm = ?1 AND n = ?2").bind(row.id, c.n, status, error).run();
    }
    const counts = await changeCounts(db, row.id);
    await setSwarm(db, row.id, { apply_status: counts.failed > 0 ? "failed" : "applied" }, d.base.now());
    return { again: null };
}

// One alarm of a swarm's Durable Object.
export async function swarmTick(d: SwarmRunDeps, id: string): Promise<SwarmTickOutcome> {
    const started = d.base.now();
    const row = await swarmRow(d.base.db, id).catch((e) => (isMissingTable(e) ? null : Promise.reject(e)));
    if (!row) return { again: null };
    const spec = specOf(row);
    if (row.status === "running" || row.status === "stopping") {
        if (!d.model) {
            await d.base.db.prepare("UPDATE swarm_tasks SET status = 'skipped', error = 'error.swarm.off' WHERE swarm = ?1 AND status IN ('queued', 'running')").bind(id).run();
            await setSwarm(d.base.db, id, { status: "failed", error: "error.swarm.off", finished_at: started }, started);
            return { again: null };
        }
        return tickTasks(d, row, spec, started);
    }
    if (row.apply_status === "applying") return tickApply(d, row, spec, started);
    return { again: null };
}

// ---- the Durable Object's side ----------------------------------------------------------------------------------------

export const SWARM_INTERNAL_HEADER = "x-internal-key";

export type SwarmsNamespace = {
    idFromName(name: string): unknown;
    get(id: unknown): { fetch(r: Request): Promise<Response> };
};

// Wakes a swarm's object: its alarm runs the tasks (or the apply step).
export type SwarmsPort = { wake(id: string): Promise<void> };

export function swarmsPort(ns: SwarmsNamespace, internalKey: string): SwarmsPort {
    return {
        async wake(id) {
            const res = await ns.get(ns.idFromName(id)).fetch(
                new Request("https://swarms.internal/wake", {
                    method: "PUT",
                    headers: { "content-type": "application/json", [SWARM_INTERNAL_HEADER]: internalKey },
                    body: JSON.stringify({ swarm: id }),
                }),
            );
            await res.body?.cancel().catch(() => {});
            if (!res.ok) throw new Error(`the swarm runner answered ${res.status}`);
        },
    };
}

type Storage = { get<T>(key: string): Promise<T | undefined>; put(key: string, value: unknown): Promise<void> };

export type SwarmRunnerDeps = {
    storage: Storage;
    setAlarm: (inMs: number) => Promise<void>;
    tick: (id: string) => Promise<SwarmTickOutcome>;
};

export class SwarmRunnerCore {
    constructor(private d: SwarmRunnerDeps) {}

    async wake(raw: unknown): Promise<boolean> {
        const id = (raw as { swarm?: unknown } | null)?.swarm;
        if (typeof id !== "string" || !SWARM_ID_REGEX.test(id)) return false;
        await this.d.storage.put("swarm", id);
        await this.d.setAlarm(0);
        return true;
    }

    async tick(): Promise<void> {
        const id = await this.d.storage.get<string>("swarm");
        if (!id) return;
        const out = await this.d.tick(id);
        if (out.again !== null) await this.d.setAlarm(out.again);
    }
}

export async function handleSwarmRoute(core: SwarmRunnerCore, request: Request, internalKey: string): Promise<Response> {
    if (!internalKey || request.headers.get(SWARM_INTERNAL_HEADER) !== internalKey) return new Response(null, { status: 403 });
    const { pathname } = new URL(request.url);
    if (pathname === "/wake" && request.method === "PUT") {
        return (await core.wake(await request.json().catch(() => null)))
            ? Response.json({ status: "success" })
            : Response.json({ status: "error", error: { code: "error.swarm.bad_spec" } }, { status: 400 });
    }
    return new Response(null, { status: 404 });
}

// The runner's deps from an op base: the model fixed to Haiku 5.5 (through the ModelRelay when the edge has it).
export function swarmRunDeps(base: OpBase, model: ChatModel | null, sleep: (ms: number) => Promise<void>): SwarmRunDeps {
    const env = base.env as typeof base.env & { ORIGINALS?: unknown; MEDIA?: unknown; IMAGES?: unknown };
    return {
        base,
        model,
        runner: base.edge.codeRunner ?? null,
        sleep,
        look: { db: base.db, mediaBaseUrl: base.mediaBaseUrl, originals: env.ORIGINALS as never, media: env.MEDIA as never, images: (env.IMAGES ?? null) as never },
    };
}
