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
import { lookBlocks, lookImages, lookMediaBlocks, lookMediaImages, type LookDeps } from "./look-pictures";
import { mediaHostsOf } from "./media-refs";
import { gateOf } from "./seventv-gate";
import { agentRows, answeredOf, outcomeOf, scoreOf } from "./swarm-board";
import { chatToolbox } from "./registry/ai";
import type { OpBase } from "./registry/context";
import { OpError, type AiFlags, type Op } from "./registry/op";
import { Registry } from "./registry/registry";
import { argsToInput, toolTypesFor } from "./registry/typescript";
import { capture, swarmEvent, type SwarmStage } from "./posthog";
import { livePushConfigured } from "./apns";

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
    "emotes.findMany",
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
// waiting: parked on a question to its owner (section 61.2): no concurrency slot, no spend
export type TaskStatus = "queued" | "running" | "waiting" | "done" | "failed" | "skipped";
export type ApplyStatus = "none" | "ready" | "applying" | "applied" | "failed";
export const SWARM_LIVE: readonly SwarmStatus[] = ["running", "stopping"];

const err = (status: number, code: string, message?: string) => new OpError(status, code, message);
export const badSpec = (message: string) => err(400, "error.swarm.bad_spec", `swarm: ${message}`);

// A D1 error from a database that migration 0043 (or 0044, the messages and steps) has not reached yet.
export const isMissingTable = (e: unknown) => /no such table: swarm|no such column: (steps|asked_at|stats)/.test(String(e instanceof Error ? e.message : e));

// D1 before the migration: one clear refusal instead of a generic error.
export async function d1<T>(p: Promise<T>): Promise<T> {
    try {
        return await p;
    } catch (e) {
        if (isMissingTable(e)) throw err(503, "error.swarm.not_ready", "swarms are not set up on this server yet (migrations 0043 and 0044)");
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
// How long an agent waits for an answer to its question before it goes on (section 61.2); the var is for tests.
export const SWARM_ASK_WAIT_MS = 10 * 60 * 1000;
export const askWaitOf = (env: { SWARM_ASK_WAIT_MS?: string }) => num(env.SWARM_ASK_WAIT_MS, SWARM_ASK_WAIT_MS);

// ---- the program ----------------------------------------------------------------------------------------------------

const CallName = z.string().trim().min(1).max(64);
const FieldName = z.string().trim().min(1).max(64);
// Section 62.4: which answer fields the board reads (each a field name of a row).
export const BoardMapSchema = z.object({
    title: FieldName.optional(),
    media: z.union([FieldName, z.array(FieldName).min(1).max(4)]).optional(),
    score: FieldName.optional(),
    group: FieldName.optional(),
    fields: z.array(FieldName).max(12).optional(),
});
export type BoardMap = { title?: string; media?: string[]; score?: string; group?: string; fields?: string[] };
export const SwarmSpecSchema = z.object({
    name: z.string().trim().min(1).max(80).describe("shown on the approve page"),
    mode: z.enum(["propose", "read", "act"]).optional().describe("propose (default): tasks only read and answer { changes }, Harmony reviews them, then they are applied; read: tasks answer results; act: tasks may also call `writes` themselves"),
    items: z.array(z.unknown()).max(ITEMS_MAX).optional().describe(`the items to split (at most ${ITEMS_MAX}, JSON at most 512 KB); or give source`),
    source: z
        .object({
            call: CallName.describe("a swarm read call, e.g. seventv.set (for a set's emotes: one read gives every name, id and picture; better than searching for each)"),
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
    output: z
        .object({
            schema: z.record(z.string(), z.unknown()).optional().describe("read/act: each task's answer must match this JSON Schema"),
            board: BoardMapSchema.optional().describe("how the answers read on the results board (section 62.4); guessed when left out"),
        })
        .optional()
        .describe("read/act: the answer's JSON Schema; any mode: the board mapping"),
    prefetch: z
        .object({
            call: CallName.describe("a swarm read call run by the runner (no model) once per item before its agent starts, e.g. emotes.find"),
            args: z.record(z.string(), z.unknown()).describe('its input; string values may use {{item}} or {{item.path}}, e.g. { "q": "{{item.name}}" }'),
            as: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,39}$/).optional().describe('the key the answer is attached under on each item, default "lookup"'),
        })
        .optional()
        .describe("look each item up before its agent starts (section 62.6); the answer is attached to the item (4 KB at most)"),
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
    // section 62.4 (absent in programs stored before it)
    board?: BoardMap | null;
    // section 62.6
    prefetch?: { call: string; args: Record<string, unknown>; as: string } | null;
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
    if (mode === "propose" && input.output?.schema) throw badSpec("output.schema is for read and act mode; propose answers { changes }");
    if (!input.prompt.includes("{{items}}")) throw badSpec("prompt must contain {{items}}");
    for (const m of input.prompt.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)) {
        if (!PLACEHOLDERS.has(m[1]!)) throw badSpec(`prompt: {{${m[1]}}} is not a placeholder ({{items}} {{index}} {{total}} {{count}} {{name}})`);
    }
    let output: Spec["output"] = null;
    if (input.output?.schema) {
        if (JSON.stringify(input.output.schema).length > SCHEMA_BYTES_MAX) throw badSpec("output.schema is over 8 KB");
        schemaOf(input.output.schema);
        output = { schema: input.output.schema };
    }
    const board = input.output?.board ? checkBoardMap(input.output.board, output?.schema ?? null) : null;
    let prefetch: Spec["prefetch"] = null;
    if (input.prefetch) {
        const p = input.prefetch;
        if (!SWARM_READ_OPS.includes(p.call) || !registry.op(p.call)) throw badSpec(`prefetch.call: ${p.call} is not a swarm read call (${SWARM_READ_OPS.join(", ")})`);
        if (JSON.stringify(p.args).length > PREFETCH_ARGS_MAX) throw badSpec("prefetch.args is over 4 KB");
        for (const m of JSON.stringify(p.args).matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)) {
            if (!/^item(?:\.[A-Za-z0-9_]{1,64}){0,4}$/.test(m[1]!)) throw badSpec(`prefetch.args: {{${m[1]}}} is not {{item}} or {{item.path}}`);
        }
        prefetch = { call: p.call, args: p.args, as: p.as ?? "lookup" };
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
        board,
        prefetch,
        reduce: input.reduce ?? null,
        source,
        batch_size: input.batch?.size ?? BATCH_DEFAULT,
        // section 62.5: a swarm calling 7TV starts at most 3 agents at once unless the program asks for more
        concurrency: input.concurrency ?? ([...tools, ...writes, ...(prefetch ? [prefetch.call] : [])].some(isSevenTvOp) ? CONCURRENCY_SEVENTV : CONCURRENCY_DEFAULT),
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

export const PREFETCH_ARGS_MAX = 4096;
export const CONCURRENCY_SEVENTV = 3;
export const isSevenTvOp = (name: string) => name.startsWith("seventv.") || name.startsWith("emotes.");

// Section 62.4: the board mapping, checked. With an output.schema, every field it names must be one the answer's rows can
// have (the properties of the schema's array items, or of the object, or of the object's first array property).
function checkBoardMap(b: z.infer<typeof BoardMapSchema>, schema: Record<string, unknown> | null): BoardMap {
    const media = b.media === undefined ? undefined : Array.isArray(b.media) ? b.media : [b.media];
    const out: BoardMap = {
        ...(b.title ? { title: b.title } : {}),
        ...(media ? { media } : {}),
        ...(b.score ? { score: b.score } : {}),
        ...(b.group ? { group: b.group } : {}),
        ...(b.fields ? { fields: b.fields } : {}),
    };
    const known = schema ? rowProperties(schema) : null;
    if (known) {
        for (const f of [out.title, ...(out.media ?? []), out.score, out.group, ...(out.fields ?? [])]) {
            if (f !== undefined && !known.has(f)) throw badSpec(`output.board: ${f} is not a field of the answer's rows (${[...known].join(", ") || "none"})`);
        }
    }
    return out;
}

function rowProperties(schema: Record<string, unknown>): Set<string> | null {
    const props = (x: unknown) => {
        const p = (x as { properties?: unknown } | null)?.properties;
        return p && typeof p === "object" ? (p as Record<string, unknown>) : null;
    };
    const items = (x: unknown) => (x as { items?: unknown } | null)?.items;
    if ((schema as { type?: unknown }).type === "array") {
        const p = props(items(schema));
        return p ? new Set(Object.keys(p)) : null;
    }
    const top = props(schema);
    if (!top) return null;
    for (const k of ["results", "matches", "items", "rows", "answers"]) {
        const p = props(items(top[k]));
        if (p) return new Set(Object.keys(p));
    }
    return new Set(Object.keys(top));
}

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
    // migration 0044 (section 61): the step log and when a parked agent asked its question
    steps?: string | null;
    asked_at?: number | null;
    // section 62.3: TaskStats JSON
    stats?: string | null;
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

// `step`: the agent's last step text (section 61.3), or null
type Cell = { idx: number; status: TaskStatus; error: string | null; step: string | null };
type ChangeCounts = { total: number; kept: number; done: number; failed: number };
// section 61.3: the messages so far
type MessageCounts = { total: number };

export const approveUrl = (webOrigin: string, id: string) => `${webOrigin.replace(/\/+$/, "")}/swarms/${id}`;

// The swarm as the routes, the MCP and the web page see it.
export const ITEMS_SAMPLE = 10;

export function swarmShape(
    r: SwarmRow,
    cells: Cell[],
    changes: ChangeCounts | null,
    webOrigin: string,
    extra: { itemsSample: unknown[]; unscopedWrites: string[]; messages?: MessageCounts; planner?: string; score?: number | null } = { itemsSample: [], unscopedWrites: [] },
) {
    const spec = specOf(r);
    const count = (s: TaskStatus) => cells.filter((c) => c.status === s).length;
    const waiting = count("waiting");
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
        tasks: { total: cells.length, queued: count("queued"), running: count("running"), waiting, done: count("done"), failed: count("failed"), cells },
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
            board: spec.board ?? null,
            prefetch: spec.prefetch ?? null,
            turns_per_task: spec.turns,
            attempts: spec.attempts,
            stop_after_failed_tasks: spec.stop_after,
        },
        unscoped_writes: extra.unscopedWrites,
        approve_url: approveUrl(webOrigin, r.id),
        job: swarmJob(r.id),
        // section 61.3: `waiting` = agents parked on an open question
        messages: { total: extra.messages?.total ?? 0, waiting },
        planner: extra.planner ?? plannerOfKey(r.key_id, null),
        // section 62.3: the mean of the ended agents' scores
        score: extra.score ?? null,
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

// Section 62.3: every agent's items, always, and its outcome. `asks`: its questions so far.
export const resultShape = (t: TaskRow, asks = 0) => {
    const stats = statsOf(t.stats);
    return {
        task: t.idx,
        status: t.status,
        result: parse<unknown>(t.result, null),
        error: t.error,
        usd: round4(t.usd),
        items: parse<unknown[]>(t.items, []),
        outcome: outcomeOf(t, stats, stats.answered ?? 0, asks),
    };
};

// How many questions each agent of a swarm asked (section 62.3).
export async function asksByTask(db: D1Database, swarm: string): Promise<Map<number, number>> {
    const { results } = await db
        .prepare("SELECT task, COUNT(*) AS n FROM swarm_messages WHERE swarm = ?1 AND dir = 'up' AND kind = 'ask' AND task IS NOT NULL GROUP BY task")
        .bind(swarm)
        .all<{ task: number; n: number }>()
        .catch(() => ({ results: [] as { task: number; n: number }[] }));
    return new Map(results.map((r) => [r.task, r.n]));
}

// ---- D1 ---------------------------------------------------------------------------------------------------------------

export async function swarmRow(db: D1Database, id: string): Promise<SwarmRow | null> {
    return (await db.prepare("SELECT * FROM swarms WHERE id = ?1").bind(id).first<SwarmRow>()) ?? null;
}

export async function cellsOf(db: D1Database, id: string): Promise<Cell[]> {
    const { results } = await db
        .prepare("SELECT idx, status, error, json_extract(steps, '$[#-1].text') AS step FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx")
        .bind(id)
        .all<Cell>();
    return results.map((c) => ({ idx: c.idx, status: c.status, error: c.error, step: c.step ?? null }));
}

// The planner's short name (section 61.3): the client key's name, "chat" for the in-app chat, else "mcp".
export const plannerOfKey = (keyId: string, name: string | null) => (keyId.startsWith("chat:") ? "chat" : name?.trim() ? name.trim().slice(0, 40) : "mcp");

export async function plannerOf(db: D1Database, keyId: string): Promise<string> {
    if (keyId.startsWith("chat:")) return "chat";
    const k = await db.prepare("SELECT name FROM api_keys WHERE id = ?1").bind(keyId).first<{ name: string | null }>().catch(() => null);
    return plannerOfKey(keyId, k?.name ?? null);
}

export async function messageTotal(db: D1Database, id: string): Promise<number> {
    const r = await db.prepare("SELECT COUNT(*) AS n FROM swarm_messages WHERE swarm = ?1").bind(id).first<{ n: number }>();
    return r?.n ?? 0;
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
    const [cells, changes, sample, total, planner, score] = await Promise.all([
        cellsOf(db, r.id),
        r.mode === "propose" ? changeCounts(db, r.id) : Promise.resolve(null),
        itemsSample(db, r.id),
        messageTotal(db, r.id),
        plannerOf(db, r.key_id),
        meanScore(db, r.id),
    ]);
    return swarmShape(r, cells, changes, webOrigin, { itemsSample: sample, unscopedWrites: unscopedWrites(registry, specOf(r)), messages: { total }, planner, score });
}

// Section 62.3: the mean of the ended agents' scores (a failed agent counts 0), or null before any ended.
export async function meanScore(db: D1Database, id: string): Promise<number | null> {
    const r = await db
        .prepare(
            `SELECT AVG(CASE WHEN status = 'failed' THEN COALESCE(json_extract(stats, '$.score'), 0) ELSE json_extract(stats, '$.score') END) AS s
               FROM swarm_tasks WHERE swarm = ?1 AND status IN ('done', 'failed')`,
        )
        .bind(id)
        .first<{ s: number | null }>()
        .catch(() => null);
    return typeof r?.s === "number" ? Math.round(r.s * 1000) / 1000 : null;
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
// `asks`: the open questions of its agents (section 61.3), for jobs.wait and the chat's jobs.onDone hook.
export function swarmJobState(r: SwarmRow, cells: Pick<Cell, "status">[], asks: SwarmAsk[] = []) {
    const done = cells.filter((c) => c.status === "done").length;
    const failed = cells.filter((c) => c.status === "failed").length;
    const waiting = cells.filter((c) => c.status === "waiting").length;
    const base = { job: swarmJob(r.id), swarm: r.id, name: r.name };
    const summary = `${done} of ${cells.length} tasks done${failed ? `, ${failed} failed` : ""}, $${round4(r.spent_usd)} spent`;
    switch (r.status) {
        case "awaiting_approval":
            return { ...base, status: "queued", activity: "waiting for Harmony to approve" };
        case "running":
        case "stopping":
            return {
                ...base,
                status: "running",
                progress: cells.length ? Math.round(((done + failed) / cells.length) * 100) / 100 : null,
                activity: waiting ? `${summary}, ${waiting === 1 ? "1 question" : `${waiting} questions`} waiting` : summary,
                ...(asks.length ? { asks } : {}),
            };
        case "done":
            return { ...base, status: "done", result: r.reduce_result ? `${summary}. ${r.reduce_result}` : `${summary}.` };
        case "failed":
            return { ...base, status: "error", error: r.error ?? "error.swarm.failed", result: summary };
        default:
            return { ...base, status: "cancelled", result: `${r.status}: ${summary}` };
    }
}

// ---- messages and steps (section 61) ----------------------------------------------------------------------------------

// What one agent may send up, and how long a message may be.
export const ASKS_PER_AGENT = 3;
export const MESSAGES_PER_AGENT = 20;
export const MESSAGE_MAX = 2000;
export const STEPS_KEPT = 20;
export const STEP_TEXT_MAX = 80;
export const INBOX_MAX = 100;
export const MESSAGES_PAGE_MAX = 200;
// the open questions a job state lists (jobs.wait, jobs.onDone)
const ASKS_SHOWN = 10;

export type MessageDir = "up" | "down";
export type MessageKind = "ask" | "tell" | "reply" | "note";
export type MessageSender = "agent" | "owner" | "you";
export type MessageRow = {
    id: number;
    swarm: string;
    task: number | null;
    dir: MessageDir;
    kind: MessageKind;
    sender: MessageSender;
    text: string;
    created_at: number;
    read_at: number | null;
    answered_at: number | null;
};

// SwarmMessage (61.3): agents are numbered from 1 wherever a person or a model sees them.
export const messageShape = (m: MessageRow) => ({
    id: m.id,
    swarm: m.swarm,
    agent: m.task === null ? null : m.task + 1,
    dir: m.dir,
    kind: m.kind,
    sender: m.sender,
    text: m.text,
    at: m.created_at,
    answered: m.answered_at !== null,
});
export type SwarmMessage = ReturnType<typeof messageShape>;

// An open question as a job state lists it.
export type SwarmAsk = { id: number; agent: number; text: string };

export type Step = { at: number; text: string };
export const parseSteps = (s: string | null): Step[] => {
    const v = parse<unknown>(s, []);
    return Array.isArray(v) ? (v.filter((x) => x && typeof x === "object" && typeof (x as Step).text === "string") as Step[]) : [];
};
export const stepText = (text: string) => Array.from(text.replace(/\s+/g, " ").trim()).slice(0, STEP_TEXT_MAX).join("");

// A task's step log (the last STEPS_KEPT), kept in memory while its attempt runs and written with the task's other writes.
export class StepLog {
    private steps: Step[];
    private dirty = false;
    constructor(
        private db: D1Database,
        private swarm: string,
        private idx: number,
        raw: string | null,
        private now: () => number,
    ) {
        this.steps = parseSteps(raw);
    }
    add(text: string): void {
        this.steps.push({ at: this.now(), text: stepText(text) });
        if (this.steps.length > STEPS_KEPT) this.steps = this.steps.slice(-STEPS_KEPT);
        this.dirty = true;
    }
    json(): string {
        return JSON.stringify(this.steps);
    }
    async flush(): Promise<void> {
        if (!this.dirty) return;
        this.dirty = false;
        await this.db.prepare("UPDATE swarm_tasks SET steps = ?3 WHERE swarm = ?1 AND idx = ?2").bind(this.swarm, this.idx, this.json()).run();
    }
}

// The open questions of a swarm's waiting agents, oldest first.
export async function openAsks(db: D1Database, swarm: string): Promise<SwarmAsk[]> {
    const { results } = await db
        .prepare(
            `SELECT m.id, m.task, m.text FROM swarm_messages m JOIN swarm_tasks t ON t.swarm = m.swarm AND t.idx = m.task
              WHERE m.swarm = ?1 AND m.dir = 'up' AND m.kind = 'ask' AND m.answered_at IS NULL AND t.status = 'waiting'
              ORDER BY m.id LIMIT ${ASKS_SHOWN}`,
        )
        .bind(swarm)
        .all<{ id: number; task: number; text: string }>();
    return results.map((m) => ({ id: m.id, agent: m.task + 1, text: m.text }));
}

// Parked agents whose answer arrived (a down message for them, or for every agent, they were not given yet) or whose
// wait ran out go back to the queue; their next turn starts with the answer or the timeout line. Returns how many woke.
export async function wakeWaiting(db: D1Database, swarm: string, now: number, waitMs: number): Promise<number> {
    const r = await db
        .prepare(
            `UPDATE swarm_tasks SET status = 'queued', asked_at = NULL
              WHERE swarm = ?1 AND status = 'waiting'
                AND (COALESCE(asked_at, 0) <= ?2 - ?3
                     OR EXISTS (SELECT 1 FROM swarm_messages m WHERE m.swarm = ?1 AND m.dir = 'down' AND (m.task IS NULL OR m.task = swarm_tasks.idx)
                                 AND m.id > COALESCE(json_extract(swarm_tasks.state, '$.seen'), 0)))`,
        )
        .bind(swarm, now, waitMs)
        .run();
    return r.meta?.changes ?? 0;
}

// When the next parked agent's wait runs out (ms from now), or null when none waits.
export async function nextAskTimeout(db: D1Database, swarm: string, now: number, waitMs: number): Promise<number | null> {
    const r = await db.prepare("SELECT MIN(asked_at) AS at FROM swarm_tasks WHERE swarm = ?1 AND status = 'waiting'").bind(swarm).first<{ at: number | null }>();
    if (r?.at === null || r?.at === undefined) return null;
    return Math.max(0, r.at + waitMs - now);
}

// The down messages a task has not been given yet (after id `seen`), oldest first.
export async function downFor(db: D1Database, swarm: string, idx: number, seen: number): Promise<MessageRow[]> {
    const { results } = await db
        .prepare("SELECT * FROM swarm_messages WHERE swarm = ?1 AND dir = 'down' AND (task IS NULL OR task = ?2) AND id > ?3 ORDER BY id LIMIT 50")
        .bind(swarm, idx, seen)
        .all<MessageRow>();
    return results;
}

export async function insertMessage(
    db: D1Database,
    m: { swarm: string; task: number | null; dir: MessageDir; kind: MessageKind; sender: MessageSender; text: string; now: number },
): Promise<number> {
    const r = await db
        .prepare("INSERT INTO swarm_messages (swarm, task, dir, kind, sender, text, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) RETURNING id")
        .bind(m.swarm, m.task, m.dir, m.kind, m.sender, m.text, m.now)
        .first<{ id: number }>();
    return r!.id;
}

// What the model reads at the start of its next turn: each down message on its own line.
export function downLines(msgs: MessageRow[], planner: string): string {
    return msgs.map((m) => (m.sender === "you" ? `[message from Harmony]: ${m.text}` : `[answer from ${planner}]: ${m.text}`)).join("\n");
}
export const noAnswerLine = (waitMs: number) => `[no answer in ${Math.max(1, Math.round(waitMs / 60_000))} minutes: go on with your best guess and say so in your answer]`;

// Text from a model or an owner: trimmed, 1..MESSAGE_MAX characters.
export function messageText(v: unknown, call: string): string {
    const t = typeof v === "string" ? v.trim() : "";
    if (t.length === 0 || Array.from(t).length > MESSAGE_MAX) throw new Error(`${call}: text must be 1..${MESSAGE_MAX} characters`);
    return t;
}

// ---- the toolbox ------------------------------------------------------------------------------------------------------

// A token bucket per kind of 7TV call, shared by every task of one alarm.
export class Limiter {
    private next = new Map<string, number>();
    // section 62.2: a kind's widened gap after a passing failure, and when it was last widened
    private wide = new Map<string, { gap: number; at: number }>();
    constructor(
        private now: () => number,
        private sleep: (ms: number) => Promise<void>,
    ) {}
    // the gap now: the widened one for a minute after the last widening, else the base
    gapOf(kind: string, baseMs: number): number {
        const w = this.wide.get(kind);
        if (!w || this.now() - w.at >= LIMITER_CALM_MS) return baseMs;
        return Math.max(baseMs, w.gap);
    }
    // a passing failure (rate limited, busy): the gap doubles, up to LIMITER_GAP_MAX_MS
    widen(kind: string, baseMs: number): void {
        this.wide.set(kind, { gap: Math.min(LIMITER_GAP_MAX_MS, this.gapOf(kind, baseMs) * 2), at: this.now() });
    }
    async wait(kind: string, gapMs: number): Promise<void> {
        const now = this.now();
        const gap = this.gapOf(kind, gapMs);
        const at = Math.max(now, this.next.get(kind) ?? 0);
        this.next.set(kind, at + gap);
        if (at > now) await this.sleep(at - now);
    }
    pause(ms: number): Promise<void> {
        return this.sleep(ms);
    }
}

// Section 62.2: a read that fails for a passing reason is tried again after these waits before the agent sees it.
export const READ_RETRY_MS = [2000, 8000, 30_000];
export const LIMITER_GAP_MAX_MS = 2000;
export const LIMITER_CALM_MS = 60_000;
export const RETRY_AFTER_MAX_MS = 60_000;

// Whether a call's error is passing: rate limited, busy, a 5xx, timed out, the network.
export function passingError(e: unknown): boolean {
    const x = e as { status?: unknown; code?: unknown; message?: unknown } | null;
    const status = typeof x?.status === "number" ? x.status : null;
    if (status !== null && (status === 429 || status >= 500)) return true;
    const code = typeof x?.code === "string" ? x.code : "";
    if (/rate_limited|busy|unavailable|timeout|timed_out|upstream/.test(code)) return true;
    if (status !== null) return false;
    const msg = typeof x?.message === "string" ? x.message : String(e);
    return /rate.?limit|\bbusy\b|timed? ?out|ECONNRESET|fetch failed|network|\b(429|502|503|504)\b/i.test(msg);
}
// A Retry-After the op passed on (seconds), as ms, capped.
const retryAfterOf = (e: unknown): number | null => {
    const r = (e as { retryAfter?: unknown } | null)?.retryAfter;
    return typeof r === "number" && r > 0 ? Math.min(RETRY_AFTER_MAX_MS, r * 1000) : null;
};

export type ToolboxOpts = {
    swarm: string;
    spec: Spec;
    // the calls this toolbox offers: reads (tools) and, for act mode and the executor, writes
    calls: string[];
    collect: ChatCollect;
    limiter: Limiter;
    task: number | null;
    // section 62.2: a read waited out a passing failure ("<op> busy, waited <s> s")
    onWait?: (op: string, ms: number) => void;
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
        swarm: o.swarm,
    });
    const tools: ChatTools = {};
    // section 62.5: with the shared gate bound, it paces every 7TV call (and slows after a 429); the swarm's own limiter
    // paces them only without it
    const paced = gateOf(base.env as { SEVENTV_GATE?: unknown }) === null;
    for (const [name, fn] of Object.entries(box.tools)) {
        const op = base.registry.byCall(name);
        if (!op || !fn) continue;
        const sevenTv = paced && isSevenTvOp(op.name);
        if (!writes.has(op.name)) {
            // a read: paced (7TV), and tried again after 2, 8 and 30 s on a passing failure (section 62.2)
            tools[name] = async (...args: unknown[]) => {
                for (let i = 0; ; i++) {
                    if (sevenTv) await o.limiter.wait("7tv:read", SEVENTV_READ_GAP_MS);
                    try {
                        return await fn(...args);
                    } catch (e) {
                        if (i >= READ_RETRY_MS.length || !passingError(e)) throw e;
                        if (sevenTv) o.limiter.widen("7tv:read", SEVENTV_READ_GAP_MS);
                        const ms = Math.max(READ_RETRY_MS[i]!, retryAfterOf(e) ?? 0);
                        await o.limiter.pause(ms);
                        o.onWait?.(op.name, ms);
                    }
                }
            };
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

// ---- prefetch (section 62.6): the runner looks each item up before its agent starts ------------------------------------

export const PREFETCH_ANSWER_MAX = 4096;
export const PREFETCH_BATCH = 20;

// {{item}} and {{item.path}} in the args' string values: a string that is only the placeholder takes the value as it is.
export function fillPrefetchArgs(args: unknown, item: unknown): unknown {
    const at = (path: string) => (path ? path.split(".").reduce<unknown>((v, k) => (v && typeof v === "object" ? (v as Record<string, unknown>)[k] : undefined), item) : item);
    const one = (str: string): unknown => {
        const whole = /^\{\{\s*item((?:\.[A-Za-z0-9_]+)*)\s*\}\}$/.exec(str);
        if (whole) return at(whole[1]!.slice(1));
        return str.replace(/\{\{\s*item((?:\.[A-Za-z0-9_]+)*)\s*\}\}/g, (_, p: string) => {
            const v = at(p.slice(1));
            return v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v);
        });
    };
    if (typeof args === "string") return one(args);
    if (Array.isArray(args)) return args.map((a) => fillPrefetchArgs(a, item));
    if (args && typeof args === "object") return Object.fromEntries(Object.entries(args).map(([k, v]) => [k, fillPrefetchArgs(v, item)]));
    return args;
}

// An answer kept on an item: at most 4 KB of JSON, cut lists first, else a note.
export function trimAnswer(v: unknown): unknown {
    const size = (x: unknown) => JSON.stringify(x ?? null).length;
    if (size(v) <= PREFETCH_ANSWER_MAX) return v ?? null;
    const cut = (x: unknown): unknown => {
        if (Array.isArray(x)) {
            let list = x;
            while (list.length > 1 && size(list) > PREFETCH_ANSWER_MAX / 2) list = list.slice(0, Math.ceil(list.length / 2));
            return list.map(cut);
        }
        if (x && typeof x === "object") return Object.fromEntries(Object.entries(x).map(([k, y]) => [k, cut(y)]));
        return typeof x === "string" && x.length > 300 ? `${x.slice(0, 300)}…` : x;
    };
    const c = cut(v);
    return size(c) <= PREFETCH_ANSWER_MAX ? c : { cut: true, text: JSON.stringify(c).slice(0, PREFETCH_ANSWER_MAX - 100) };
}

// An item with its lookup: an object gains the key; anything else becomes { value, <as> }.
const attach = (item: unknown, as: string, answer: unknown) => (item && typeof item === "object" && !Array.isArray(item) ? { ...(item as Record<string, unknown>), [as]: answer } : { value: item, [as]: answer });
const hasLookup = (item: unknown, as: string) => !!item && typeof item === "object" && !Array.isArray(item) && as in (item as Record<string, unknown>);

// Looks up every item of one task's batch (the ones not looked up yet), in order, saving as it goes; false when the tick ran
// out of time first (the rest is done at the next claim). emotes.find lookups of a batch go out as emotes.findMany.
export async function prefetchTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, task: TaskRow, tc: TaskCtx, steps: StepLog, stats: TaskStats): Promise<boolean> {
    const pf = spec.prefetch!;
    const base = d.base;
    const db = base.db;
    const items = parse<unknown[]>(task.items, []);
    const calls = pf.call === "emotes.find" && base.registry.op("emotes.findMany") ? [pf.call, "emotes.findMany"] : [pf.call];
    const tools = swarmToolbox(base, {
        swarm: row.id,
        spec: { ...spec, writes: [] },
        calls,
        collect: { look: [], show: [], collage: null },
        limiter: tc.limiter,
        task: task.idx,
        onWait: (op, ms) => {
            stats.waits++;
            steps.add(`${op} busy, waited ${Math.round(ms / 1000)} s`);
        },
    });
    const op = base.registry.op(pf.call)!;
    const fn = tools[op.callName];
    const many = calls.length > 1 ? tools[base.registry.op("emotes.findMany")!.callName] : undefined;
    const save = async () => {
        task.items = JSON.stringify(items);
        await db.prepare("UPDATE swarm_tasks SET items = ?3, heartbeat_at = ?4, steps = ?5 WHERE swarm = ?1 AND idx = ?2").bind(row.id, task.idx, task.items, base.now(), steps.json()).run();
    };
    const errorOf = (e: unknown) => ({ error: (e instanceof Error ? e.message : String(e)).slice(0, 300) });
    const todo = items.map((it, i) => ({ i, it })).filter(({ it }) => !hasLookup(it, pf.as));
    for (let k = 0; k < todo.length; ) {
        if (base.now() >= tc.deadline) {
            await save();
            return false;
        }
        const chunk = todo.slice(k, k + (many ? PREFETCH_BATCH : 1));
        const inputs = chunk.map(({ it }) => fillPrefetchArgs(pf.args, it) as Record<string, unknown>);
        // emotes.find with only a query (and a shared sort): one emotes.findMany for the chunk
        const batchable =
            many && chunk.length > 1 && inputs.every((x) => typeof x.query === "string" && x.query.trim() && Object.keys(x).every((key) => key === "query" || key === "sort") && x.sort === inputs[0]!.sort);
        if (batchable) {
            try {
                const out = (await many(inputs.map((x) => x.query), ...(inputs[0]!.sort ? [{ sort: inputs[0]!.sort }] : []))) as { sort: string; results: { emotes: unknown[]; cached: boolean }[] };
                chunk.forEach(({ i }, j) => {
                    const r = out.results[j];
                    items[i] = attach(items[i], pf.as, trimAnswer(r ? { sort: out.sort, page: 1, items: r.emotes, ...(r.cached ? { cached: true } : {}) } : { error: "no answer" }));
                });
            } catch (e) {
                chunk.forEach(({ i }) => (items[i] = attach(items[i], pf.as, errorOf(e))));
            }
            stats.tool_calls++;
        } else {
            for (const [j, { i }] of chunk.entries()) {
                stats.tool_calls++;
                try {
                    items[i] = attach(items[i], pf.as, trimAnswer(await fn!(...positionalArgs(op, inputs[j]!))));
                } catch (e) {
                    stats.tool_errors++;
                    items[i] = attach(items[i], pf.as, errorOf(e));
                }
            }
        }
        k += chunk.length;
        steps.add(`prefetched ${items.length - todo.length + k} of ${items.length}`);
        await save();
    }
    return true;
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

Your final message must be ONLY the JSON answer: no prose, no markdown, no code fences.${spec.mode === "propose" ? "" : ` ${MEDIA_TIP}`}${tips(spec)}

The API:
${o.reads}

${SWARM_CALLS_DOC}`;
}

// Section 62.1: answers that name things carry a media ref, so the board can show them.
export const MEDIA_TIP =
    'Beside every thing you name in your answer (an emote, a post, a file, a picture), put a "media" field with a media ref: a 7TV emote id or cdn.7tv.app link, a capystore link or post id, or an https image URL; add "preview_url" and the ids when you have them. A bare name is not enough. cobalt.look({ media }) lets you SEE one (when look is among your calls).';

// Section 62.5: fewer 7TV requests.
function tips(spec: Pick<Spec, "tools">): string {
    const out: string[] = [];
    if (spec.tools.includes("emotes.findMany")) out.push("To look up several emote names, use cobalt.emotes.findMany(queries) once (up to 20 names in one request) instead of emotes.find for each.");
    if (spec.tools.includes("look")) out.push("To compare emotes or pictures, look at them (cobalt.look({ media })) rather than matching by name alone.");
    return out.length ? `\n\n${out.join("\n")}` : "";
}

// cobalt.swarm.* (section 61.2): every swarm agent has them, whatever the program's tools.
export const SWARM_CALLS_DOC = `Talking to whoever planned this swarm (use sparingly; most tasks need neither):
declare const cobalt: { swarm: {
  // A question you cannot answer from your batch and your calls (at most ${ASKS_PER_AGENT}). Your turn ends after this run_code; the answer (or, after a while, a note that none came) is your next message. Never ask about other batches.
  ask(text: string): Promise<{ asked: true; note: string }>;
  // A short report the owner should see (no answer comes). At most ${MESSAGES_PER_AGENT} messages in all, each at most ${MESSAGE_MAX} characters.
  tell(text: string): Promise<{ sent: true }>;
} };`;

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

// A step of a swarm's life to PostHog (section 59.10). Fire and forget: never changes what the swarm does.
export function trackSwarm(base: Pick<OpBase, "env" | "edge" | "now">, stage: SwarmStage, swarm: string, detail: Record<string, unknown> = {}): void {
    try {
        void capture(base.env as { POSTHOG_PROJECT_TOKEN?: string; POSTHOG_HOST?: string }, base.edge.waitUntil, [swarmEvent(stage, swarm, base.now(), { model: CHAT_MODEL_DEFAULT, ...detail })]);
    } catch {
        // never
    }
}

async function trackTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, idx: number, status: string, error: string | null, changes: number | null): Promise<void> {
    const t = await d.base.db
        .prepare("SELECT attempts, in_tokens, out_tokens, usd, started_at, ended_at FROM swarm_tasks WHERE swarm = ?1 AND idx = ?2")
        .bind(row.id, idx)
        .first<Pick<TaskRow, "attempts" | "in_tokens" | "out_tokens" | "usd" | "started_at" | "ended_at">>()
        .catch(() => null);
    trackSwarm(d.base, "task_ended", row.id, {
        mode: spec.mode,
        task: idx,
        status,
        error_code: error ?? undefined,
        attempts: t?.attempts,
        in_tokens: t?.in_tokens,
        out_tokens: t?.out_tokens,
        usd: t?.usd,
        ms: t?.started_at && t?.ended_at ? t.ended_at - t.started_at : undefined,
        changes: changes ?? undefined,
    });
}

export type SwarmRunDeps = {
    base: OpBase;
    model: ChatModel | null;
    runner: CodeRunner | null;
    sleep: (ms: number) => Promise<void>;
    look?: LookDeps & { fetch?: typeof fetch };
    // tests shorten these
    tickBudgetMs?: number;
    tickHardMs?: number;
    // the swarm moved: its Live Activity may need a push (section 61.5). Never throws.
    live?: (swarm: string) => Promise<void>;
};

// What one alarm comes to: run again in this many ms, or nothing left (null).
export type SwarmTickOutcome = { again: number | null };

// `seen`: the highest down message (section 61) this conversation was given; `asked`: its last run asked a question that
// has not been answered yet (the next turn starts with the answer or the timeout line)
type TaskState = { messages: any[]; turns: number; repaired: boolean; seen?: number; asked?: boolean };

// Adds text to the conversation's last user message (the API wants user and assistant turns in turn).
function appendUser(messages: any[], text: string): void {
    const last = messages[messages.length - 1];
    if (!last || last.role !== "user") {
        messages.push({ role: "user", content: text });
        return;
    }
    if (typeof last.content === "string") last.content = `${last.content}\n\n${text}`;
    else last.content = [...(last.content as any[]), { type: "text", text }];
}

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

type TaskEnd =
    | { kind: "done"; result: unknown; changes: Proposal[] }
    | { kind: "failed"; error: string }
    | { kind: "halted"; error: string }
    | { kind: "paused" }
    // section 61.2: it asked a question; parked until the answer comes or the wait runs out
    | { kind: "waiting"; askedAt: number };

// What one alarm knows for every task it runs: the planner's name (the agents' answers come from it).
type TaskCtx = { limiter: Limiter; deadline: number; planner: string; waitMs: number };

// cobalt.swarm.ask / tell for one agent (section 61.2): stored as `up` messages, at most ASKS_PER_AGENT asks and
// MESSAGES_PER_AGENT messages an agent. An ask ends the agent's turn after the run_code it is in (`onAsk`).
function swarmMailTools(d: SwarmRunDeps, swarm: string, idx: number, steps: StepLog, onAsk: (at: number) => void): ChatTools {
    const db = d.base.db;
    const used = async () => {
        const r = await db
            .prepare("SELECT COUNT(*) AS n, COALESCE(SUM(CASE WHEN kind = 'ask' THEN 1 ELSE 0 END), 0) AS asks FROM swarm_messages WHERE swarm = ?1 AND task = ?2 AND dir = 'up'")
            .bind(swarm, idx)
            .first<{ n: number; asks: number }>();
        return { n: r?.n ?? 0, asks: r?.asks ?? 0 };
    };
    return {
        "swarm.ask": async (text: unknown) => {
            const t = messageText(text, "cobalt.swarm.ask");
            const u = await used();
            if (u.asks >= ASKS_PER_AGENT) throw new Error(`cobalt.swarm.ask: you asked ${ASKS_PER_AGENT} questions already, the most an agent may: go on with your best guess and say so in your answer`);
            if (u.n >= MESSAGES_PER_AGENT) throw new Error(`cobalt.swarm.ask: you sent ${MESSAGES_PER_AGENT} messages already, the most an agent may`);
            const now = d.base.now();
            await insertMessage(db, { swarm, task: idx, dir: "up", kind: "ask", sender: "agent", text: t, now });
            steps.add("asked a question");
            onAsk(now);
            trackSwarm(d.base, "asked", swarm, { task: idx, agent: idx + 1, asks: u.asks + 1, messages: u.n + 1, chars: t.length });
            return { asked: true, note: "your turn ends now; the answer comes as your next message" };
        },
        "swarm.tell": async (text: unknown) => {
            const t = messageText(text, "cobalt.swarm.tell");
            const u = await used();
            if (u.n >= MESSAGES_PER_AGENT) throw new Error(`cobalt.swarm.tell: you sent ${MESSAGES_PER_AGENT} messages already, the most an agent may`);
            await insertMessage(db, { swarm, task: idx, dir: "up", kind: "tell", sender: "agent", text: t, now: d.base.now() });
            steps.add("told the owner");
            trackSwarm(d.base, "told", swarm, { task: idx, agent: idx + 1, messages: u.n + 1, chars: t.length });
            return { sent: true };
        },
    };
}

// An agent's counts for its outcome (section 62.3), kept across its attempts in swarm_tasks.stats. `answered` and `score`
// are set when it ends.
export type TaskStats = { tool_calls: number; tool_errors: number; waits: number; turns: number; answered?: number; score?: number };
export const statsOf = (raw: string | null | undefined): TaskStats => {
    const p = parse<Partial<TaskStats> | null>(raw ?? null, null);
    const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
    return {
        tool_calls: n(p?.tool_calls),
        tool_errors: n(p?.tool_errors),
        waits: n(p?.waits),
        turns: n(p?.turns),
        ...(typeof p?.answered === "number" ? { answered: p.answered } : {}),
        ...(typeof p?.score === "number" ? { score: p.score } : {}),
    };
};

// The program's calls with the step log written around them: "read <op>" or "wrote <op>" (section 61.3), counted for the
// outcome (section 62.3: a call that still failed after its retries is a tool error).
function withSteps(base: OpBase, tools: ChatTools, writes: Set<string>, steps: StepLog, stats: TaskStats): ChatTools {
    const out: ChatTools = {};
    for (const [name, fn] of Object.entries(tools)) {
        const op = base.registry.byCall(name);
        const label = `${op && writes.has(op.name) ? "wrote" : "read"} ${op?.name ?? name}`;
        out[name] = async (...args: unknown[]) => {
            stats.tool_calls++;
            try {
                return await fn(...args);
            } catch (e) {
                stats.tool_errors++;
                throw e;
            } finally {
                steps.add(label);
            }
        };
    }
    return out;
}

// One attempt of one task, from its saved conversation on. Never throws for the model's own mistakes.
async function attemptTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, task: TaskRow, tc: TaskCtx, steps: StepLog, stats: TaskStats): Promise<TaskEnd> {
    const { base } = d;
    const db = base.db;
    const total = row.task_count;
    const items = parse<unknown[]>(task.items, []);
    const reads = cheatSheet(base, spec.mode === "act" ? [...spec.tools, ...spec.writes] : spec.tools);
    const writes = spec.mode === "propose" ? proposalDoc(base, spec.writes) : "";
    const system = taskSystem(spec, { index: task.idx + 1, total, items: row.item_count, reads, writes, now: base.now() });
    const saved = parse<TaskState | null>(task.state, null);
    const state: TaskState = saved ?? {
        messages: [{ role: "user", content: fillPrompt(spec.prompt, { items, index: task.idx + 1, total, name: spec.name }) }],
        turns: 0,
        repaired: false,
    };
    if (!saved) steps.add("started");
    const save = async () => {
        await db
            .prepare("UPDATE swarm_tasks SET state = ?3, heartbeat_at = ?4, steps = ?5, stats = ?6 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, task.idx, JSON.stringify(state), base.now(), steps.json(), JSON.stringify(stats))
            .run();
    };
    const calls = spec.mode === "act" ? [...spec.tools, ...spec.writes] : spec.tools;
    const writeSet = new Set(spec.mode === "act" ? spec.writes : []);
    const output = spec.output ? schemaOf(spec.output.schema) : null;
    for (;;) {
        if (state.turns >= spec.turns + (state.repaired ? 1 : 0)) return { kind: "failed", error: "error.swarm.out_of_turns" };
        if (base.now() >= tc.deadline) {
            await save();
            return { kind: "paused" };
        }
        const halt = await haltReason(d, row.id);
        if (halt) return { kind: "halted", error: halt };
        // messages from the owner (section 61.2): the answer to its question, a note to it or to every agent; a question
        // nobody answered in time goes on with the timeout line
        const down = await downFor(db, row.id, task.idx, state.seen ?? 0);
        if (down.length > 0) {
            appendUser(state.messages, downLines(down, tc.planner));
            state.seen = down[down.length - 1]!.id;
            if (state.asked) {
                steps.add("answer arrived");
            }
            state.asked = false;
        } else if (state.asked) {
            appendUser(state.messages, noAnswerLine(tc.waitMs));
            steps.add("no answer, going on");
            trackSwarm(base, "ask_timeout", row.id, { task: task.idx, agent: task.idx + 1 });
            state.asked = false;
        }
        let res: ModelTurn;
        try {
            res = await modelTurn(d, { system, tools: [RUN_CODE_TOOL], messages: state.messages });
        } catch (e) {
            console.error("[swarm] model failed", String(e).slice(0, 300));
            return { kind: "failed", error: "error.swarm.model" };
        }
        state.turns++;
        stats.turns++;
        await charge(d, row.id, task.idx, res.usage, system.length + JSON.stringify(state.messages).length);
        state.messages.push({ role: "assistant", content: res.content });
        const uses = res.content.filter((b: any) => b?.type === "tool_use");
        if (res.stop_reason === "tool_use" && uses.length > 0) {
            const results: any[] = [];
            let askedAt: number | null = null;
            for (const u of uses) {
                if (u.name !== "run_code" || typeof u.input?.code !== "string" || !d.runner) {
                    results.push({ type: "tool_result", tool_use_id: u.id, is_error: true, content: "Only run_code exists, with { code: string }." });
                    continue;
                }
                const collect: ChatCollect = { look: [], show: [], collage: null };
                const program = calls.length > 0 ? swarmToolbox(base, {
                              swarm: row.id,
                              spec,
                              calls,
                              collect,
                              limiter: tc.limiter,
                              task: task.idx,
                              onWait: (op, ms) => {
                                  stats.waits++;
                                  steps.add(`${op} busy, waited ${Math.round(ms / 1000)} s`);
                              },
                          })
                        : {};
                const tools: ChatTools = {
                    ...withSteps(base, program, writeSet, steps, stats),
                    ...swarmMailTools(d, row.id, task.idx, steps, (at) => (askedAt ??= at)),
                };
                const out = await d.runner(u.input.code, tools);
                const logs = out.logs.slice(0, LOGS_MAX).map((l) => clip(l, 500));
                const body = out.error !== undefined ? { error: out.error, logs } : { result: out.result ?? null, logs };
                const content: any[] = [{ type: "text", text: clip(JSON.stringify(body) ?? "null", RESULT_MAX) }];
                if (collect.look.length > 0 && d.look) {
                    const imgs = await lookImages(d.look, collect.look.slice(0, 4), collect.lookOpts ?? {}).catch(() => new Map());
                    for (const pid of collect.look.slice(0, 4)) content.push(...lookBlocks(pid, imgs.get(pid), collect.lookOpts?.[pid]?.frames === true));
                }
                // look({ media }) (section 62.1): an emote, a link or a capystore ref
                const media = (collect.lookMedia ?? []).slice(0, 4);
                if (media.length > 0 && d.look) {
                    const deps = { ...d.look, shareBaseUrl: base.shareBaseUrl, hosts: mediaHostsOf(base.env as { MEDIA_HOSTS?: string }, base) };
                    const imgs = await lookMediaImages(deps, media).catch(() => new Map());
                    for (const ref of media) content.push(...lookMediaBlocks(ref, imgs.get(ref)));
                }
                results.push({ type: "tool_result", tool_use_id: u.id, ...(out.error !== undefined ? { is_error: true } : {}), content });
            }
            state.messages.push({ role: "user", content: results });
            if (askedAt !== null) {
                // the turn ends on a question: parked, holding no slot, until the answer comes (or the wait runs out)
                state.asked = true;
                await save();
                return { kind: "waiting", askedAt };
            }
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

// Runs one claimed task to its end (or a pause, or a question) and records it.
async function runTask(d: SwarmRunDeps, row: SwarmRow, spec: Spec, idx: number, tc: TaskCtx): Promise<void> {
    const db = d.base.db;
    const task = await db.prepare("SELECT * FROM swarm_tasks WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx).first<TaskRow>();
    if (!task) return;
    const steps = new StepLog(db, row.id, idx, task.steps ?? null, d.base.now);
    const stats = statsOf(task.stats);
    let end: TaskEnd;
    try {
        // section 62.6: the agent starts only when its batch is looked up
        if (spec.prefetch && !task.state && !(await prefetchTask(d, row, spec, task, tc, steps, stats))) {
            // not an attempt yet: the claim that resumes it counts one again
            await db.prepare("UPDATE swarm_tasks SET attempts = MAX(attempts - 1, 0) WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx).run();
            end = { kind: "paused" };
        }
        else end = await attemptTask(d, row, spec, task, tc, steps, stats);
    } catch (e) {
        // a crash keeps the agent's items and says why (section 62.3)
        console.error("[swarm] task failed", String(e).slice(0, 300));
        end = { kind: "failed", error: `error.swarm.task: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` };
    }
    const now = d.base.now();
    const items = parse<unknown[]>(task.items, []);
    // an agent that ended: its score (0 unless it finished)
    const ended = (status: string, result: unknown, changes: Proposal[]) => {
        const bases = { mediaBaseUrl: d.base.mediaBaseUrl, shareBaseUrl: d.base.shareBaseUrl, hosts: [] as string[] };
        const rows =
            status !== "done"
                ? []
                : spec.mode === "propose"
                  ? changes.map((c) => ({ values: [c.target, c.before, c.after, ...Object.values(c.args).map((v) => (typeof v === "string" || typeof v === "number" ? String(v) : ""))].filter((v): v is string => !!v).map((v) => v.toLowerCase()) }))
                  : agentRows(spec, { idx, status, error: null, items: task.items, result: JSON.stringify(result ?? null) }, [], bases);
        stats.answered = answeredOf(items, rows);
        stats.score = scoreOf(status, items.length, stats.answered, stats);
        return JSON.stringify(stats);
    };
    if (end.kind === "paused") {
        await db.prepare("UPDATE swarm_tasks SET status = 'queued', steps = ?3, stats = ?4 WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx, steps.json(), JSON.stringify(stats)).run();
        return;
    }
    if (end.kind === "waiting") {
        // the conversation is kept (state); waiting does not count as a turn and spends nothing
        await db
            .prepare("UPDATE swarm_tasks SET status = 'waiting', asked_at = ?3, steps = ?4, stats = ?5 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, idx, end.askedAt, steps.json(), JSON.stringify(stats))
            .run();
        await d.live?.(row.id);
        return;
    }
    if (end.kind === "halted") {
        await db
            .prepare("UPDATE swarm_tasks SET status = 'skipped', error = ?3, state = NULL, ended_at = ?4, asked_at = NULL, steps = ?5, stats = ?6 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, idx, end.error, now, steps.json(), ended("skipped", null, []))
            .run();
        await trackTask(d, row, spec, idx, "skipped", end.error, null);
        return;
    }
    if (end.kind === "failed") {
        const again = task.attempts < spec.attempts;
        steps.add(again ? "retrying" : `failed: ${end.error}`);
        await db
            .prepare("UPDATE swarm_tasks SET status = ?3, error = ?4, state = NULL, ended_at = ?5, asked_at = NULL, steps = ?6, stats = ?7 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, idx, again ? "queued" : "failed", end.error, again ? null : now, steps.json(), again ? JSON.stringify(stats) : ended("failed", null, []))
            .run();
        await trackTask(d, row, spec, idx, again ? "retrying" : "failed", end.error, null);
        if (!again) await d.live?.(row.id);
        return;
    }
    if (spec.mode === "propose") steps.add(`proposed ${end.changes.length} ${end.changes.length === 1 ? "change" : "changes"}`);
    steps.add("done");
    const stmts = [
        db
            .prepare("UPDATE swarm_tasks SET status = 'done', result = ?3, error = NULL, state = NULL, ended_at = ?4, asked_at = NULL, steps = ?5, stats = ?6 WHERE swarm = ?1 AND idx = ?2")
            .bind(row.id, idx, JSON.stringify(end.result ?? null), now, steps.json(), ended("done", end.result, end.changes)),
        // a task that ran again replaces its earlier proposals
        db.prepare("DELETE FROM swarm_changes WHERE swarm = ?1 AND task = ?2").bind(row.id, idx),
        ...insertChanges(db, row.id, idx, end.changes),
    ];
    await db.batch(stmts);
    await trackTask(d, row, spec, idx, "done", null, spec.mode === "propose" ? end.changes.length : null);
    await d.live?.(row.id);
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

type Counts = { queued: number; running: number; waiting: number; done: number; failed: number; skipped: number };
async function taskCounts(db: D1Database, swarm: string): Promise<Counts> {
    const { results } = await db.prepare("SELECT status, COUNT(*) AS n FROM swarm_tasks WHERE swarm = ?1 GROUP BY status").bind(swarm).all<{ status: TaskStatus; n: number }>();
    const c: Counts = { queued: 0, running: 0, waiting: 0, done: 0, failed: 0, skipped: 0 };
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
    // queued agents and agents parked on a question end skipped (section 61.2)
    await db
        .prepare("UPDATE swarm_tasks SET status = 'skipped', error = ?2, state = NULL, asked_at = NULL WHERE swarm = ?1 AND status IN ('queued', 'waiting')")
        .bind(row.id, halt ?? "error.swarm.stopped")
        .run();
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
    await d.live?.(row.id);
    const fin = await swarmRow(db, row.id).catch(() => null);
    trackSwarm(d.base, "finished", row.id, {
        mode: spec.mode,
        status,
        error_code: error ?? undefined,
        tasks: c.done + c.failed + c.skipped,
        done: c.done,
        failed: c.failed,
        spent_usd: fin?.spent_usd,
        cap_usd: fin?.cap_usd,
        changes: spec.mode === "propose" ? (await changeCounts(db, row.id).catch(() => null))?.total : undefined,
        ms: fin?.approved_at ? now - fin.approved_at : undefined,
    });
}

// The tasks' part of one alarm: launch up to `concurrency` at once until the time budget, a stop or a cap.
async function tickTasks(d: SwarmRunDeps, row: SwarmRow, spec: Spec, started: number): Promise<SwarmTickOutcome> {
    const db = d.base.db;
    await watchdog(d, row.id);
    const budget = started + (d.tickBudgetMs ?? TICK_BUDGET_MS);
    const waitMs = askWaitOf(d.base.env as { SWARM_ASK_WAIT_MS?: string });
    const tc: TaskCtx = {
        limiter: new Limiter(d.base.now, d.sleep),
        deadline: started + (d.tickHardMs ?? TICK_HARD_MS),
        planner: await plannerOf(db, row.key_id),
        waitMs,
    };
    const inflight = new Set<Promise<void>>();
    let halt: string | null = null;
    for (;;) {
        halt = await haltReason(d, row.id);
        if (!halt && (await taskCounts(db, row.id)).failed >= spec.stop_after) halt = "error.swarm.too_many_failed";
        if (halt || d.base.now() >= budget) break;
        // parked agents whose answer came (or whose wait ran out) queue again (section 61.2)
        await wakeWaiting(db, row.id, d.base.now(), waitMs);
        while (inflight.size < spec.concurrency) {
            const idx = await claimNext(d, row.id);
            if (idx === null) break;
            const p: Promise<void> = runTask(d, row, spec, idx, tc).finally(() => inflight.delete(p));
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
        // the swarm never ends while an agent waits on a question: come back when the next wait runs out
        if (c.waiting > 0) {
            if ((await wakeWaiting(db, row.id, d.base.now(), waitMs)) > 0) return { again: 0 };
            return { again: (await nextAskTimeout(db, row.id, d.base.now(), waitMs)) ?? 60_000 };
        }
    } else if (c.running > 0) return { again: 60_000 };
    const fresh = (await swarmRow(db, row.id)) ?? row;
    await finishTasks(d, fresh, spec, halt ?? (c.failed >= spec.stop_after ? "error.swarm.too_many_failed" : null));
    return { again: null };
}

const APPLY_LIVE_GAP_MS = 5000;

// The apply executor (propose mode): no model, the kept changes through their ops, in order, each at most once.
async function tickApply(d: SwarmRunDeps, row: SwarmRow, spec: Spec, started: number): Promise<SwarmTickOutcome> {
    const db = d.base.db;
    const budget = started + (d.tickBudgetMs ?? TICK_BUDGET_MS);
    const limiter = new Limiter(d.base.now, d.sleep);
    const tools = swarmToolbox(d.base, { swarm: row.id, spec, calls: spec.writes, collect: { look: [], show: [], collage: null }, limiter, task: null });
    // a change an earlier alarm left mid-way runs again through the ledger: done there answers its stored result, pending
    // fails it as unknown (UNKNOWN_WRITE) for Harmony to check and re-tick
    await db.prepare("UPDATE swarm_changes SET status = 'proposed' WHERE swarm = ?1 AND status = 'applying'").bind(row.id).run();
    let livePushed = d.base.now();
    for (;;) {
        const cur = await swarmRow(db, row.id);
        if (!cur || cur.stop_requested === 1) {
            await setSwarm(db, row.id, { apply_status: "ready", stop_requested: 0 }, d.base.now());
            await d.live?.(row.id);
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
        // the Live Activity's "<done> of <total>" (its own throttle decides what goes out)
        if (d.base.now() - livePushed >= APPLY_LIVE_GAP_MS) {
            livePushed = d.base.now();
            await d.live?.(row.id);
        }
    }
    const counts = await changeCounts(db, row.id);
    await setSwarm(db, row.id, { apply_status: counts.failed > 0 ? "failed" : "applied" }, d.base.now());
    await d.live?.(row.id);
    trackSwarm(d.base, "applied", row.id, { mode: spec.mode, kept: counts.kept, done: counts.done, failed: counts.failed, writes: spec.writes });
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
            await d.live?.(id);
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
        live: (swarm) => swarmLive(base).push(swarm),
    };
}

// ---- the swarm Live Activity (section 61.5) -------------------------------------------------------------------------------

// The main Durable Object keeps each swarm's island (src/swarm-live.ts): `start` push-starts it on the owner's newest device
// when a plan is stored, `push` tells it the swarm moved (it reads D1 and decides what goes out). Off without APNs. Never
// throws and never waits long: an island is never worth failing or slowing a swarm call for.
export const SWARM_LIVE_CALL_MS = 4000;
export function swarmLive(base: Pick<OpBase, "env" | "container">): { start(id: string): Promise<void>; push(id: string): Promise<void> } {
    const call = async (id: string, what: "start" | "push") => {
        if (!livePushConfigured(base.env as never)) return;
        try {
            const res = await Promise.race([
                base.container.fetch(
                    new Request(`https://do.internal/live/swarms/${id}/${what}`, { method: "POST", headers: { [SWARM_INTERNAL_HEADER]: base.env.COBALT_API_KEY } }),
                ),
                new Promise<null>((r) => setTimeout(() => r(null), SWARM_LIVE_CALL_MS)),
            ]);
            await res?.body?.cancel().catch(() => {});
        } catch (e) {
            console.error(`[swarm] live ${what} failed`, String(e).slice(0, 200));
        }
    };
    return { start: (id) => call(id, "start"), push: (id) => call(id, "push") };
}
