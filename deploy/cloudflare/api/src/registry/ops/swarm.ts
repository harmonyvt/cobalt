// Agent swarms (APP-API-CONTRACT.md section 59): plan, follow, stop and retry a swarm (the agent's calls, also MCP tools),
// and approve, decline, review and apply one (Harmony's calls: the web Worker behind Cloudflare Access, or a signed-in
// device session; never a client key, never the chat or the MCP). The rules, the D1 side and the runner are in
// src/swarm.ts; a swarm's tasks run in its Swarm Durable Object (src/swarm-do.ts).
import * as z from "zod";
import { mintCollectionId } from "../../share-collections";
import {
    trackSwarm,
    PLAN_TTL_MS,
    PLANS_ALL,
    PLANS_PER_KEY,
    EDIT_ARGS,
    argsHash,
    badSpec,
    clashGroup,
    SWARM_ID_REGEX,
    SwarmSpecSchema,
    batchesOf,
    changeShape,
    checkSpec,
    cheatSheet,
    proposalDoc,
    d1,
    dailyUsdOf,
    daySpent,
    estimateUsd,
    expirePlans,
    insertPlan,
    itemsFromSource,
    refreshClashes,
    resultShape,
    statsOf,
    TASKS_MAX,
    asksByTask,
    runningCounts,
    runningLimitsOf,
    setSwarm,
    shapeOf,
    specHash,
    specOf,
    splitItems,
    swarmRow,
    swarmsOn,
    swarmsPort,
    taskSystem,
    type ChangeRow,
    type Spec,
    type SwarmRow,
    type SwarmsNamespace,
    type TaskRow,
    INBOX_MAX,
    MESSAGES_PAGE_MAX,
    MESSAGE_MAX,
    insertMessage,
    messageShape,
    parseSteps,
    refreshClashes as refresh,
    swarmLive,
    type MessageRow,
} from "../../swarm";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { mediaHostsOf } from "../../media-refs";
import { BOARD_LIMIT_DEFAULT, BOARD_LIMIT_MAX, agentRows, answeredOf, boardPage, outcomeOf } from "../../swarm-board";

const Params = { id: SWARM_ID_REGEX };
const BAD = "error.swarm.bad_spec";

// ---- shapes (APP-API-CONTRACT.md 59.4) -----------------------------------------------------------------------------------

const TaskStatus = z.enum(["queued", "running", "waiting", "done", "failed", "skipped"]);
export const SwarmSchema = z
    .object({
        swarm: z.string().describe("its id"),
        name: z.string(),
        mode: z.enum(["propose", "read", "act"]),
        status: z.enum(["awaiting_approval", "running", "stopping", "done", "failed", "stopped", "declined", "expired"]),
        spec_hash: z.string().describe("the approve and apply POSTs send it back"),
        prompt: z.string(),
        tools: z.array(z.string()),
        writes: z.array(z.string()),
        scope: z.record(z.string(), z.array(z.string())),
        items: z.number(),
        batch_size: z.number(),
        concurrency: z.number(),
        tasks: z.object({
            total: z.number(),
            queued: z.number(),
            running: z.number(),
            waiting: z.number().describe("agents parked on a question to their owner"),
            done: z.number(),
            failed: z.number(),
            cells: z.array(z.object({ idx: z.number(), status: TaskStatus, error: z.string().nullable(), step: z.string().nullable().describe("its last step") })),
        }),
        estimate_usd: z.object({ low: z.number(), high: z.number() }),
        cap_usd: z.number(),
        spent_usd: z.number(),
        created_at: z.number(),
        approved_at: z.number().nullable(),
        finished_at: z.number().nullable(),
        expires_at: z.number().nullable().describe("an unapproved plan expires then"),
        reduce: z.string().nullable().describe("the reduce step's summary"),
        error: z.string().nullable(),
        changes: z.object({ total: z.number(), kept: z.number(), done: z.number(), failed: z.number() }).nullable().describe("propose mode"),
        apply: z.object({ status: z.enum(["none", "ready", "applying", "applied", "failed"]), done: z.number(), failed: z.number(), total: z.number() }),
        spec_preview: z
            .object({
                items_sample: z.array(z.unknown()).describe("the first 10 items"),
                source: z.object({ call: z.string(), args: z.record(z.string(), z.unknown()), path: z.string().nullable() }).nullable(),
                output_schema: z.unknown().nullable(),
                reduce_prompt: z.string().nullable(),
                board: z.unknown().nullable().describe("output.board, the program's board mapping"),
                prefetch: z.object({ call: z.string(), args: z.record(z.string(), z.unknown()), as: z.string() }).nullable().describe("looks up each item with this call first (section 62.6)"),
                turns_per_task: z.number(),
                attempts: z.number(),
                stop_after_failed_tasks: z.number(),
            })
            .describe("what the approve page shows of the spec"),
        unscoped_writes: z.array(z.string()).describe("write ops no scope key limits (none of their input fields is a scope key)"),
        approve_url: z.string().describe("Harmony approves (and reviews) here; give this link to Harmony"),
        job: z.string().describe("swarm:<id>, for job_status"),
        messages: z.object({ total: z.number(), waiting: z.number().describe("open questions: answer with swarm.send") }),
        planner: z.string().describe("who planned it: the client key's name, chat or mcp"),
        score: z.number().nullable().describe("the mean of the ended agents' scores (section 62.3), null before any ended"),
    })
    .meta({ id: "Swarm" });

export const SwarmMessageSchema = z
    .object({
        id: z.number(),
        swarm: z.string(),
        agent: z.number().nullable().describe("1-based; null: to every agent"),
        dir: z.enum(["up", "down"]).describe("up: an agent to its owner; down: to agents"),
        kind: z.enum(["ask", "tell", "reply", "note"]),
        sender: z.enum(["agent", "owner", "you"]),
        text: z.string(),
        at: z.number(),
        answered: z.boolean(),
    })
    .meta({ id: "SwarmMessage" });

export const SwarmChangeSchema = z
    .object({
        n: z.number(),
        task: z.number(),
        op: z.string(),
        args: z.record(z.string(), z.unknown()),
        target: z.string().nullable(),
        before: z.string().nullable(),
        after: z.string().nullable(),
        edit_arg: z.string().nullable(),
        preview_url: z.string().nullable(),
        keep: z.boolean(),
        status: z.enum(["proposed", "applying", "done", "failed", "skipped"]),
        error: z.string().nullable(),
        clash: z.string().nullable(),
    })
    .meta({ id: "SwarmChange" });

export const OutcomeSchema = z
    .object({
        status: z.string(),
        items: z.number(),
        answered: z.number().describe("how many of its items appear in its rows"),
        tool_calls: z.number(),
        tool_errors: z.number().describe("calls that still failed after their retries"),
        asks: z.number(),
        turns: z.number(),
        usd: z.number(),
        ms: z.number().nullable(),
        score: z.number().nullable().describe("0..1: answered / items × (1 − tool_errors / max(tool_calls, 1)); 0 for a failed agent; null while it runs"),
    })
    .meta({ id: "SwarmOutcome" });

export const SwarmResultSchema = z
    .object({
        task: z.number(),
        status: z.string(),
        result: z.unknown(),
        error: z.string().nullable(),
        usd: z.number(),
        items: z.array(z.unknown()).describe("the agent's batch, always"),
        outcome: OutcomeSchema,
    })
    .meta({ id: "SwarmResult" });

// ---- who is asking --------------------------------------------------------------------------------------------------------

// The key a swarm belongs to: the MCP's client key, else the caller's key id (a client key, or chat:<thread>).
const ownerKey = (ctx: OpContext) => ctx.chat?.mcp?.clientKeyId ?? ctx.keyId ?? "";

async function isSession(ctx: OpContext): Promise<boolean> {
    if (ctx.caller !== "key" || !ctx.keyId) return false;
    const r = await ctx.db.prepare("SELECT kind FROM api_keys WHERE id = ?1").bind(ctx.keyId).first<{ kind: string }>();
    return r?.kind === "session";
}

// Harmony only: the web Worker (after Access) or a device session. Never a client key, the chat or the MCP.
async function requireOwner(ctx: OpContext): Promise<string> {
    if (!ctx.chat) {
        if (ctx.caller === "service") return "service";
        if (await isSession(ctx)) return ctx.keyId!;
    }
    throw new OpError(403, "error.swarm.owner_only", "only Harmony can do this, on the swarm's page in capystore");
}

const notFound = () => new OpError(404, "error.swarm.not_found", "no swarm with that id");

// The swarm, when this caller may see it: the service and sessions see every swarm, a key its own.
async function mustSee(ctx: OpContext, id: string): Promise<SwarmRow> {
    await d1(expirePlans(ctx.db, ctx.now()));
    const row = await d1(swarmRow(ctx.db, id));
    if (!row) throw notFound();
    if (ctx.caller === "service" || row.key_id === ownerKey(ctx) || (await isSession(ctx))) return row;
    throw notFound();
}

const webOrigin = (ctx: OpContext) => ctx.env.CORS_URL;
const shape = async (ctx: OpContext, id: string) => shapeOf(ctx.db, ctx.registry, (await swarmRow(ctx.db, id))!, webOrigin(ctx));
const port = (ctx: OpContext) => swarmsPort(ctx.env.SWARMS as unknown as SwarmsNamespace, ctx.env.COBALT_API_KEY);
const notAwaiting = (what: string) => new OpError(409, "error.swarm.not_awaiting", `swarm: ${what}`);
const FINISHED = ["done", "failed", "stopped"];

// The estimate's system prompt size: the task prompt with its cheat sheets, as the runner writes it.
function systemChars(ctx: OpContext, spec: Spec, total: number, items: number): number {
    const reads = cheatSheet(ctx, spec.mode === "act" ? [...spec.tools, ...spec.writes] : spec.tools);
    const writes = spec.mode === "propose" ? proposalDoc(ctx, spec.writes) : "";
    return taskSystem(spec, { index: 1, total, items, reads, writes, now: ctx.now() }).length;
}

// ---- swarm.plan -----------------------------------------------------------------------------------------------------------

export const swarmPlanOp = defineOp({
    name: "swarm.plan",
    route: { method: "POST", path: "/swarms" },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: SwarmSpecSchema,
    output: SwarmSchema,
    ai: {
        tier: "free",
        summary:
            "Plan a swarm: one Haiku task per batch of items (e.g. 1000 7TV emotes in batches of 50), each in code mode with only the read calls in `tools`. Nothing runs until Harmony approves it on approve_url (give Harmony that link); it answers the plan with its cost estimate. mode propose (default) answers { changes } Harmony reviews before they are applied; read answers results; act may call `writes` itself. Follow it with swarm.get or job_status on its job.",
        options: true,
        when: (f) => f.subagent !== true,
    },
    handler: async (ctx, input) => {
        if (ctx.chat?.agent) throw new OpError(403, BAD, "swarm: a sub-agent cannot plan swarms: put it in your report");
        const now = ctx.now();
        const keyId = ownerKey(ctx);
        await d1(expirePlans(ctx.db, now));
        const waiting = await d1(
            ctx.db
                .prepare("SELECT COUNT(*) AS all_n, COALESCE(SUM(CASE WHEN key_id = ?1 THEN 1 ELSE 0 END), 0) AS mine FROM swarms WHERE status = 'awaiting_approval'")
                .bind(keyId)
                .first<{ all_n: number; mine: number }>(),
        );
        if ((waiting?.mine ?? 0) >= PLANS_PER_KEY) throw new OpError(429, "error.swarm.busy", `swarm: ${PLANS_PER_KEY} plans are already waiting for Harmony`);
        if ((waiting?.all_n ?? 0) >= PLANS_ALL) throw new OpError(429, "error.swarm.busy", `swarm: ${PLANS_ALL} plans are already waiting for Harmony`);
        const spec = checkSpec(input, ctx.registry, ctx.env);
        const id = mintCollectionId();
        const items = spec.source ? await itemsFromSource(ctx, id, spec, ctx.edge.sleep) : input.items!;
        const batches = splitItems(items, spec.batch_size);
        const estimate = estimateUsd(spec, batches, systemChars(ctx, spec, batches.length, items.length));
        const hash = await specHash(spec, batches, 1);
        await d1(insertPlan(ctx.db, { id, keyId, spec, batches, items: items.length, hash, estimate, now }));
        trackSwarm(ctx, "planned", id, {
            surface: ctx.chat?.mcp ? "mcp" : ctx.chat ? "chat" : "tool",
            mode: spec.mode,
            items: items.length,
            tasks: batches.length,
            batch_size: spec.batch_size,
            concurrency: spec.concurrency,
            est_low_usd: estimate.low,
            est_high_usd: estimate.high,
            cap_usd: spec.cap_usd,
            tools: spec.tools,
            writes: spec.writes,
            source: spec.source?.call,
        });
        // section 61.5: the approve island on Harmony's newest device
        await swarmLive(ctx).start(id);
        return ok(await shape(ctx, id));
    },
});

// ---- reads -----------------------------------------------------------------------------------------------------------------

export const swarmListOp = defineOp({
    name: "swarm.list",
    route: { method: "GET", path: "/swarms" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: z.object({}),
    output: z.object({ swarms: z.array(SwarmSchema) }),
    ai: { tier: "free", summary: "Your swarms, newest first (at most 50)." },
    handler: async (ctx) => {
        await d1(expirePlans(ctx.db, ctx.now()));
        const all = ctx.caller === "service" || (await isSession(ctx));
        const { results } = await d1(
            (all ? ctx.db.prepare("SELECT * FROM swarms ORDER BY created_at DESC, id LIMIT 50") : ctx.db.prepare("SELECT * FROM swarms WHERE key_id = ?1 ORDER BY created_at DESC, id LIMIT 50").bind(ownerKey(ctx))).all<SwarmRow>(),
        );
        return ok({ swarms: await Promise.all(results.map((r) => shapeOf(ctx.db, ctx.registry, r, webOrigin(ctx)))) });
    },
});

const IdInput = z.object({ id: z.string().regex(SWARM_ID_REGEX, "a swarm id").describe("the swarm's id") });

export const swarmGetOp = defineOp({
    name: "swarm.get",
    route: { method: "GET", path: "/swarms/:id", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput,
    output: SwarmSchema,
    ai: { tier: "free", summary: "One swarm: status, tasks done/running/failed, dollars spent, the reduce summary, and (propose mode) how many changes are proposed and applied.", params: ["id"] },
    handler: async (ctx, input) => ok(await shapeOf(ctx.db, ctx.registry, await mustSee(ctx, input.id), webOrigin(ctx))),
});

const Page = (max: number) =>
    IdInput.extend({
        offset: z.coerce.number().int().min(0).max(1_000_000).optional().describe("default 0"),
        limit: z.coerce.number().int().min(1).max(max).optional().describe(`default and most ${max}`),
    });

export const swarmResultsOp = defineOp({
    name: "swarm.results",
    route: { method: "GET", path: "/swarms/:id/results", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: Page(100),
    output: z.object({ results: z.array(SwarmResultSchema), total: z.number(), offset: z.number() }),
    ai: { tier: "free", summary: "A swarm's results in task order (a page of up to 100), each with its error and cost.", params: ["id"], options: true },
    handler: async (ctx, input) => {
        await mustSee(ctx, input.id);
        const offset = input.offset ?? 0;
        const { results } = await ctx.db.prepare("SELECT * FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx LIMIT ?2 OFFSET ?3").bind(input.id, input.limit ?? 100, offset).all<TaskRow>();
        const total = await ctx.db.prepare("SELECT COUNT(*) AS n FROM swarm_tasks WHERE swarm = ?1").bind(input.id).first<{ n: number }>();
        const asks = await asksByTask(ctx.db, input.id);
        return ok({ results: results.map((t) => resultShape(t, asks.get(t.idx) ?? 0)), total: total?.n ?? 0, offset });
    },
});

export const swarmChangesOp = defineOp({
    name: "swarm.changes",
    route: { method: "GET", path: "/swarms/:id/changes", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: Page(200),
    output: z.object({ changes: z.array(SwarmChangeSchema), total: z.number(), offset: z.number() }),
    ai: { tier: "free", summary: "A propose-mode swarm's proposed changes in task order (a page of up to 200), with what Harmony kept, applied and what clashes.", params: ["id"], options: true },
    handler: async (ctx, input) => {
        await mustSee(ctx, input.id);
        const offset = input.offset ?? 0;
        const { results } = await ctx.db.prepare("SELECT * FROM swarm_changes WHERE swarm = ?1 ORDER BY task, n LIMIT ?2 OFFSET ?3").bind(input.id, input.limit ?? 200, offset).all<ChangeRow>();
        const total = await ctx.db.prepare("SELECT COUNT(*) AS n FROM swarm_changes WHERE swarm = ?1").bind(input.id).first<{ n: number }>();
        return ok({ changes: results.map(changeShape), total: total?.n ?? 0, offset });
    },
});

// ---- stop, retry ---------------------------------------------------------------------------------------------------------

export const swarmStopOp = defineOp({
    name: "swarm.stop",
    route: { method: "POST", path: "/swarms/:id/stop", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput,
    output: SwarmSchema,
    ai: { tier: "free", summary: "Stop a swarm: no new tasks start, running ones stop after their current step (or stop applying changes). Nothing is undone.", params: ["id"] },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        const now = ctx.now();
        if (row.status === "awaiting_approval") await setSwarm(ctx.db, row.id, { status: "stopped", finished_at: now, expires_at: null }, now);
        else if (row.status === "running" || row.status === "stopping") await setSwarm(ctx.db, row.id, { status: "stopping", stop_requested: 1 }, now);
        else if (row.apply_status === "applying") await setSwarm(ctx.db, row.id, { stop_requested: 1 }, now);
        else return ok(await shapeOf(ctx.db, ctx.registry, row, webOrigin(ctx)));
        if (row.status !== "awaiting_approval" && ctx.env.SWARMS) await port(ctx).wake(row.id).catch((e) => console.error("[swarm] wake failed", String(e)));
        trackSwarm(ctx, "stop_asked", row.id, { mode: row.mode, was: row.status, applying: row.apply_status === "applying" });
        await swarmLive(ctx).push(row.id);
        return ok(await shape(ctx, row.id));
    },
});

export const swarmRetryOp = defineOp({
    name: "swarm.retry",
    route: { method: "POST", path: "/swarms/:id/retry", params: Params },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput,
    output: SwarmSchema,
    ai: {
        tier: "free",
        summary: "Run a finished swarm's failed (and skipped) tasks again: it goes back to awaiting Harmony's approval, with a new estimate and a new approve link check.",
        params: ["id"],
        when: (f) => f.subagent !== true,
    },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        if (!FINISHED.includes(row.status)) throw notAwaiting(`it is ${row.status.replace("_", " ")}; only a finished swarm can run its failed tasks again`);
        if (row.apply_status === "applying") throw notAwaiting("its changes are being applied");
        const now = ctx.now();
        const spec = specOf(row);
        const redo = await ctx.db.prepare("SELECT idx, items FROM swarm_tasks WHERE swarm = ?1 AND status IN ('failed', 'skipped') ORDER BY idx").bind(row.id).all<{ idx: number; items: string }>();
        if (redo.results.length === 0) throw notAwaiting("no task failed");
        const batches = await batchesOf(ctx.db, row.id);
        const again = redo.results.map((r) => JSON.parse(r.items) as unknown[]);
        const estimate = estimateUsd(spec, again, systemChars(ctx, spec, row.task_count, row.item_count));
        const round = row.round + 1;
        const hash = await specHash(spec, batches, round);
        await ctx.db.batch([
            ctx.db
                .prepare("UPDATE swarm_tasks SET status = 'queued', attempts = 0, requeues = 0, state = NULL, error = NULL, ended_at = NULL WHERE swarm = ?1 AND status IN ('failed', 'skipped')")
                .bind(row.id),
            ctx.db
                .prepare(
                    `UPDATE swarms SET status = 'awaiting_approval', round = ?2, spec_hash = ?3, est_low = ?4, est_high = ?5, expires_at = ?6, finished_at = NULL,
                            approved_at = NULL, approved_by = NULL, error = NULL, stop_requested = 0, updated_at = ?7 WHERE id = ?1`,
                )
                .bind(row.id, round, hash, estimate.low, estimate.high, now + PLAN_TTL_MS, now),
        ]);
        trackSwarm(ctx, "retry_planned", row.id, { mode: row.mode, round, est_low_usd: estimate.low, est_high_usd: estimate.high });
        // back to awaiting approval: a new island (the old one ended with the swarm)
        await swarmLive(ctx).start(row.id);
        return ok(await shape(ctx, row.id));
    },
});

// ---- Harmony's: approve, decline, decide, apply -----------------------------------------------------------------------------

const HashInput = IdInput.extend({ spec_hash: z.string().min(1).max(128) });

// The swarm for Harmony's own calls (every swarm), with an unapproved plan past its hour marked expired.
async function ownersSwarm(ctx: OpContext, id: string): Promise<SwarmRow & { by: string }> {
    const by = await requireOwner(ctx);
    await d1(expirePlans(ctx.db, ctx.now()));
    const row = await d1(swarmRow(ctx.db, id));
    if (!row) throw notFound();
    return { ...row, by };
}

export const swarmApproveOp = defineOp({
    name: "swarm.approve",
    route: { method: "POST", path: "/swarms/:id/approve", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: HashInput,
    output: SwarmSchema,
    ai: { tier: "hidden", summary: "Harmony approves a swarm's plan (the web page or a device session); its tasks start." },
    handler: async (ctx, input) => {
        const row = await ownersSwarm(ctx, input.id);
        const by = row.by;
        if (row.status === "expired") throw new OpError(410, "error.swarm.expired", "swarm: the plan expired; plan it again");
        if (row.status !== "awaiting_approval") throw notAwaiting(`it is ${row.status.replace("_", " ")}`);
        if (input.spec_hash !== row.spec_hash) throw new OpError(409, "error.swarm.hash_mismatch", "swarm: the plan changed since this page loaded");
        if (!swarmsOn(ctx.env)) throw new OpError(503, "error.swarm.off", "swarms cannot run on this server");
        const now = ctx.now();
        const running = await runningCounts(ctx.db, row.key_id);
        const limits = runningLimitsOf(ctx.env);
        if (running.mine >= limits.perKey) throw new OpError(429, "error.swarm.busy", `swarm: ${running.mine} swarms planned by the same key are running (the most is ${limits.perKey}); approve this one when one ends`);
        if (running.all >= limits.all) throw new OpError(429, "error.swarm.busy", `swarm: ${running.all} swarms are running (the most is ${limits.all}); approve this one when one ends`);
        if ((await daySpent(ctx.db, now)) >= dailyUsdOf(ctx.env)) throw new OpError(429, "error.swarm.daily_cap", "swarm: today's swarm budget is spent");
        if (row.spent_usd >= row.cap_usd) throw new OpError(409, "error.swarm.over_cap", "swarm: its dollar cap is spent");
        const r = await ctx.db
            .prepare("UPDATE swarms SET status = 'running', approved_at = ?2, approved_by = ?3, expires_at = NULL, stop_requested = 0, error = NULL, updated_at = ?2 WHERE id = ?1 AND status = 'awaiting_approval' AND spec_hash = ?4")
            .bind(row.id, now, by, input.spec_hash)
            .run();
        if ((r.meta?.changes ?? 0) === 0) throw notAwaiting("it was answered already");
        try {
            await port(ctx).wake(row.id);
        } catch (e) {
            console.error("[swarm] wake failed", String(e));
            await setSwarm(ctx.db, row.id, { status: "awaiting_approval", approved_at: null, approved_by: null, expires_at: now + PLAN_TTL_MS }, now);
            throw new OpError(503, "error.swarm.off", "swarm: the runner did not start; try again");
        }
        trackSwarm(ctx, "approved", row.id, { mode: row.mode, by: ctx.caller === "service" ? "web" : "app", wait_ms: now - row.created_at, cap_usd: row.cap_usd });
        await swarmLive(ctx).push(row.id);
        return ok(await shape(ctx, row.id));
    },
});

export const swarmDeclineOp = defineOp({
    name: "swarm.decline",
    route: { method: "POST", path: "/swarms/:id/decline", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput,
    output: SwarmSchema,
    ai: { tier: "hidden", summary: "Harmony declines a swarm's plan; nothing runs." },
    handler: async (ctx, input) => {
        const row = await ownersSwarm(ctx, input.id);
        if (row.status !== "awaiting_approval") throw notAwaiting(`it is ${row.status.replace("_", " ")}`);
        const now = ctx.now();
        await setSwarm(ctx.db, row.id, { status: "declined", finished_at: now, expires_at: null }, now);
        trackSwarm(ctx, "declined", row.id, { mode: row.mode, by: ctx.caller === "service" ? "web" : "app" });
        await swarmLive(ctx).push(row.id);
        return ok(await shape(ctx, row.id));
    },
});

export const DECIDE_MAX = 500;

// The review's state (propose mode): the tasks have ended and nothing is being applied.
function reviewable(row: SwarmRow): void {
    if (row.mode !== "propose") throw notAwaiting("only a propose-mode swarm has changes to review");
    if (!FINISHED.includes(row.status)) throw notAwaiting(`its tasks are not finished (${row.status.replace("_", " ")})`);
    if (row.apply_status === "applying") throw notAwaiting("its changes are being applied");
}

export const swarmDecideOp = defineOp({
    name: "swarm.decide",
    route: { method: "POST", path: "/swarms/:id/changes", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput.extend({
        changes: z
            .array(z.object({ n: z.number().int().min(1), keep: z.boolean().optional(), after: z.string().max(300).nullable().optional() }))
            .min(1)
            .max(DECIDE_MAX),
    }),
    output: z.object({ swarm: SwarmSchema, changes: z.array(SwarmChangeSchema) }),
    ai: { tier: "hidden", summary: "Harmony ticks or edits proposed changes on the review page (a draft until apply)." },
    handler: async (ctx, input) => {
        const row = await ownersSwarm(ctx, input.id);
        reviewable(row);
        const spec = specOf(row);
        const ns = [...new Set(input.changes.map((c) => c.n))];
        // one JSON param (D1 allows 100 bound params a statement)
        const pick = (order: string) =>
            ctx.db.prepare(`SELECT * FROM swarm_changes WHERE swarm = ?1 AND n IN (SELECT value FROM json_each(?2))${order}`).bind(row.id, JSON.stringify(ns)).all<ChangeRow>();
        const { results } = await pick("");
        const byN = new Map(results.map((r) => [r.n, r]));
        for (const c of input.changes) {
            const cur = byN.get(c.n);
            if (c.after !== undefined && cur && !(EDIT_ARGS[cur.op] && cur.edit_arg === EDIT_ARGS[cur.op]))
                throw badSpec(`change #${c.n} (${cur.op}) has no editable field: only keep can change`);
        }
        const stmts: D1PreparedStatement[] = [];
        const groups = new Set<string>();
        for (const c of input.changes) {
            const cur = byN.get(c.n);
            if (!cur || cur.status === "done") continue; // an applied change stays as it is
            const args = JSON.parse(cur.args) as Record<string, unknown>;
            groups.add(clashGroup(spec, cur.op, args));
            if (c.after !== undefined) {
                // the edited field and `after` move together: `after` is always args[edit_arg]
                args[cur.edit_arg!] = c.after;
                // null clears the field: as null where the op takes null (library.title), else left out (an optional alias)
                if (c.after === null && !ctx.registry.op(cur.op)?.input.safeParse(args).success) delete args[cur.edit_arg!];
                groups.add(clashGroup(spec, cur.op, args));
            }
            const after = cur.edit_arg ? (typeof args[cur.edit_arg] === "string" ? (args[cur.edit_arg] as string) : null) : cur.after;
            const keep = c.keep === undefined ? cur.keep : c.keep ? 1 : 0;
            // re-ticking a change whose apply ended unknown: Harmony checked it, so its pending ledger row goes and it
            // can be applied again
            const unknown = c.keep === true && cur.status === "failed" && (cur.error ?? "").startsWith("unknown:");
            const next: ChangeRow = { ...cur, args: JSON.stringify(args), after, keep, status: unknown ? "proposed" : cur.status, error: unknown ? null : cur.error };
            byN.set(c.n, next);
            stmts.push(
                ctx.db
                    .prepare("UPDATE swarm_changes SET keep = ?3, after = ?4, args = ?5, status = ?6, error = ?7 WHERE swarm = ?1 AND n = ?2")
                    .bind(row.id, c.n, keep, after, next.args, next.status, next.error),
            );
            if (unknown) {
                const hash = await argsHash(cur.op, ctx.registry.op(cur.op)?.input.safeParse(JSON.parse(cur.args)).data ?? JSON.parse(cur.args));
                stmts.push(ctx.db.prepare("DELETE FROM swarm_writes WHERE swarm = ?1 AND op = ?2 AND args_hash = ?3 AND status = 'pending'").bind(row.id, cur.op, hash));
            }
        }
        for (let i = 0; i < stmts.length; i += 50) await ctx.db.batch(stmts.slice(i, i + 50));
        await refreshClashes(ctx.db, ctx.registry, row.id, spec, groups);
        const { results: after } = await pick(" ORDER BY task, n");
        await swarmLive(ctx).push(row.id);
        return ok({ swarm: await shape(ctx, row.id), changes: after.map(changeShape) });
    },
});

export const swarmApplyOp = defineOp({
    name: "swarm.apply",
    route: { method: "POST", path: "/swarms/:id/apply", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: HashInput.extend({
        skip_clashes: z.boolean().optional().describe("untick every kept change with a clash first (the Live Activity's apply)"),
        count: z.number().int().min(0).max(100_000).optional().describe("how many changes the caller expects to apply (the island's count); 409 when it is not that many"),
    }),
    output: SwarmSchema,
    ai: { tier: "hidden", summary: "Harmony applies the kept changes of a propose-mode swarm (no model: each through its op)." },
    handler: async (ctx, input) => {
        const row = await ownersSwarm(ctx, input.id);
        reviewable(row);
        if (input.spec_hash !== row.spec_hash) throw new OpError(409, "error.swarm.hash_mismatch", "swarm: the swarm changed since this page loaded");
        if (!swarmsOn(ctx.env)) throw new OpError(503, "error.swarm.off", "swarms cannot run on this server");
        // every check first; nothing is unticked unless the apply starts (section 61.4)
        const open = await ctx.db
            .prepare("SELECT n, clash IS NOT NULL AS clash FROM swarm_changes WHERE swarm = ?1 AND keep = 1 AND status <> 'done'")
            .bind(row.id)
            .all<{ n: number; clash: number }>();
        const clashing = input.skip_clashes ? open.results.filter((c) => c.clash).map((c) => c.n) : [];
        const toApply = open.results.length - clashing.length;
        if (input.count !== undefined && input.count !== toApply)
            throw new OpError(409, "error.swarm.count_mismatch", `swarm: ${toApply} changes would be applied, not ${input.count}; look again`);
        if (toApply === 0) throw notAwaiting("no kept change is left to apply");
        const running = await runningCounts(ctx.db, row.key_id);
        const limits = runningLimitsOf(ctx.env);
        if (running.all >= limits.all) throw new OpError(429, "error.swarm.busy", `swarm: ${running.all} swarms are running (the most is ${limits.all}); apply when one ends`);
        const now = ctx.now();
        // the transition and the untick in one batch: the untick only happens when this call started the apply
        const started = "(SELECT apply_status = 'applying' AND updated_at = ?2 FROM swarms WHERE id = ?1)";
        const [r] = await ctx.db.batch([
            ctx.db
                .prepare("UPDATE swarms SET apply_status = 'applying', stop_requested = 0, updated_at = ?2 WHERE id = ?1 AND apply_status IN ('ready', 'failed', 'none', 'applied')")
                .bind(row.id, now),
            ctx.db.prepare(`UPDATE swarm_changes SET keep = 0 WHERE swarm = ?1 AND n IN (SELECT value FROM json_each(?3)) AND ${started}`).bind(row.id, now, JSON.stringify(clashing)),
            ctx.db.prepare(`UPDATE swarm_changes SET status = 'proposed', error = NULL WHERE swarm = ?1 AND keep = 1 AND status = 'failed' AND ${started}`).bind(row.id, now),
        ]);
        if ((r?.meta?.changes ?? 0) === 0) throw notAwaiting("it is being applied already");
        if (clashing.length > 0) await refresh(ctx.db, ctx.registry, row.id, specOf(row));
        try {
            await port(ctx).wake(row.id);
        } catch (e) {
            console.error("[swarm] wake failed", String(e));
            // the apply did not start: put back what it unticked
            await ctx.db.batch([
                ctx.db.prepare("UPDATE swarms SET apply_status = 'ready', updated_at = ?2 WHERE id = ?1").bind(row.id, now),
                ctx.db.prepare("UPDATE swarm_changes SET keep = 1 WHERE swarm = ?1 AND n IN (SELECT value FROM json_each(?2))").bind(row.id, JSON.stringify(clashing)),
            ]);
            if (clashing.length > 0) await refresh(ctx.db, ctx.registry, row.id, specOf(row));
            throw new OpError(503, "error.swarm.off", "swarm: the runner did not start; try again");
        }
        trackSwarm(ctx, "apply_started", row.id, { mode: row.mode, to_apply: toApply, by: ctx.caller === "service" ? "web" : "app", skip_clashes: input.skip_clashes === true });
        await swarmLive(ctx).push(row.id);
        return ok(await shape(ctx, row.id));
    },
});

// ---- messages and one agent (section 61.3) ------------------------------------------------------------------------------

// A device session or the service is Harmony herself ("you"); anyone else who may see the swarm is its owner.
async function senderOf(ctx: OpContext): Promise<"you" | "owner"> {
    return !ctx.chat && (ctx.caller === "service" || (await isSession(ctx))) ? "you" : "owner";
}

const AgentNo = z.coerce.number().int().min(1).max(200);

export const swarmInboxOp = defineOp({
    name: "swarm.inbox",
    route: { method: "GET", path: "/swarms/inbox" },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: z.object({}),
    output: z.object({ messages: z.array(SwarmMessageSchema) }),
    ai: {
        tier: "free",
        summary: "Unread messages from the agents of your swarms (questions and reports), oldest first, at most 100; they are marked read. Answer a question with swarm.send.",
    },
    handler: async (ctx) => {
        const all = await isSession(ctx);
        const { results } = await d1(
            (all
                ? ctx.db.prepare(`SELECT m.* FROM swarm_messages m WHERE m.dir = 'up' AND m.read_at IS NULL ORDER BY m.id LIMIT ${INBOX_MAX}`)
                : ctx.db
                      .prepare(
                          `SELECT m.* FROM swarm_messages m JOIN swarms s ON s.id = m.swarm WHERE s.key_id = ?1 AND m.dir = 'up' AND m.read_at IS NULL ORDER BY m.id LIMIT ${INBOX_MAX}`,
                      )
                      .bind(ownerKey(ctx))
            ).all<MessageRow>(),
        );
        if (results.length > 0) {
            await ctx.db
                .prepare("UPDATE swarm_messages SET read_at = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND read_at IS NULL")
                .bind(ctx.now(), JSON.stringify(results.map((m) => m.id)))
                .run();
        }
        return ok({ messages: results.map(messageShape) });
    },
});

export const swarmSendOp = defineOp({
    name: "swarm.send",
    route: { method: "POST", path: "/swarms/:id/messages", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput.extend({
        to: z.union([z.number().int().min(1).max(200), z.literal("all")]).describe('an agent number (from 1), or "all"'),
        text: z.string().trim().min(1).max(MESSAGE_MAX),
    }),
    output: z.object({ sent: z.boolean(), to: z.union([z.number(), z.literal("all")]), woke: z.boolean().describe("an agent waiting on a question was woken") }),
    ai: {
        tier: "free",
        summary: "Message a running swarm's agents: answer an agent's question (to: its number) or tell every agent (to: \"all\"). It never changes the program: tools, writes, scope, cap and prompt stay what was approved.",
        params: ["id", "to", "text"],
    },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        if (row.status !== "running" && row.status !== "stopping") throw new OpError(409, "error.swarm.not_running", `swarm: it is ${row.status.replace("_", " ")}; only a running swarm takes messages`);
        const task = input.to === "all" ? null : input.to - 1;
        if (task !== null && task >= row.task_count) throw badSpec(`to: this swarm has ${row.task_count} agents (1..${row.task_count})`);
        const now = ctx.now();
        const sender = await senderOf(ctx);
        // an answer when it reaches an agent with an open question
        const open = await ctx.db
            .prepare(
                `SELECT COUNT(*) AS n FROM swarm_messages WHERE swarm = ?1 AND dir = 'up' AND kind = 'ask' AND answered_at IS NULL AND (?2 IS NULL OR task = ?2)`,
            )
            .bind(row.id, task)
            .first<{ n: number }>();
        const answers = (open?.n ?? 0) > 0;
        await insertMessage(ctx.db, { swarm: row.id, task, dir: "down", kind: answers ? "reply" : "note", sender, text: input.text, now });
        await ctx.db.batch([
            ctx.db
                .prepare("UPDATE swarm_messages SET answered_at = ?3 WHERE swarm = ?1 AND dir = 'up' AND kind = 'ask' AND answered_at IS NULL AND (?2 IS NULL OR task = ?2)")
                .bind(row.id, task, now),
        ]);
        const woke = await ctx.db
            .prepare("UPDATE swarm_tasks SET status = 'queued', asked_at = NULL WHERE swarm = ?1 AND status = 'waiting' AND (?2 IS NULL OR idx = ?2)")
            .bind(row.id, task)
            .run();
        const n = woke.meta?.changes ?? 0;
        if (n > 0 && ctx.env.SWARMS) await port(ctx).wake(row.id).catch((e) => console.error("[swarm] wake failed", String(e)));
        if (answers) trackSwarm(ctx, "answered", row.id, { to: input.to === "all" ? "all" : "agent", by: sender, woke: n, chars: input.text.length });
        if (n > 0) await swarmLive(ctx).push(row.id);
        return ok({ sent: true, to: input.to, woke: n > 0 });
    },
});

export const swarmMessagesOp = defineOp({
    name: "swarm.messages",
    route: { method: "GET", path: "/swarms/:id/messages", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput.extend({
        agent: AgentNo.optional().describe("one agent's messages (and those to every agent)"),
        after: z.coerce.number().int().min(0).optional().describe("only messages after this id"),
    }),
    output: z.object({ messages: z.array(SwarmMessageSchema) }),
    ai: { tier: "free", summary: "A swarm's messages, both ways, oldest first (at most 200); does not mark them read.", params: ["id"], options: true },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        const task = input.agent === undefined ? null : input.agent - 1;
        const { results } = await ctx.db
            .prepare(`SELECT * FROM swarm_messages WHERE swarm = ?1 AND id > ?2 AND (?3 IS NULL OR task IS NULL OR task = ?3) ORDER BY id LIMIT ${MESSAGES_PAGE_MAX}`)
            .bind(row.id, input.after ?? 0, task)
            .all<MessageRow>();
        return ok({ messages: results.map(messageShape) });
    },
});

export const SwarmAgentSchema = z
    .object({
        swarm: z.string(),
        agent: z.number(),
        status: TaskStatus,
        items: z.array(z.unknown()),
        attempts: z.number(),
        in_tokens: z.number(),
        out_tokens: z.number(),
        usd: z.number(),
        started_at: z.number().nullable(),
        ended_at: z.number().nullable(),
        error: z.string().nullable(),
        result: z.unknown(),
        steps: z.array(z.object({ at: z.number(), text: z.string() })),
        messages: z.array(SwarmMessageSchema),
        changes: z.array(SwarmChangeSchema).describe("propose mode: this agent's changes"),
    })
    .meta({ id: "SwarmAgent" });

export const swarmAgentOp = defineOp({
    name: "swarm.agent",
    route: { method: "GET", path: "/swarms/:id/agents/:agent", params: { ...Params, agent: /^[1-9][0-9]{0,2}$/ } },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: IdInput.extend({ agent: AgentNo.describe("the agent's number, from 1") }),
    output: SwarmAgentSchema,
    ai: { tier: "free", summary: "One agent of a swarm: its items, status, cost, last steps, result, messages and (propose mode) changes.", params: ["id", "agent"] },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        const idx = input.agent - 1;
        const t = await ctx.db.prepare("SELECT * FROM swarm_tasks WHERE swarm = ?1 AND idx = ?2").bind(row.id, idx).first<TaskRow>();
        if (!t) throw new OpError(404, "error.swarm.not_found", `swarm: no agent ${input.agent} (it has ${row.task_count})`);
        const [msgs, changes] = await Promise.all([
            ctx.db.prepare(`SELECT * FROM swarm_messages WHERE swarm = ?1 AND (task IS NULL OR task = ?2) ORDER BY id LIMIT ${MESSAGES_PAGE_MAX}`).bind(row.id, idx).all<MessageRow>(),
            row.mode === "propose" ? ctx.db.prepare("SELECT * FROM swarm_changes WHERE swarm = ?1 AND task = ?2 ORDER BY n").bind(row.id, idx).all<ChangeRow>() : Promise.resolve({ results: [] as ChangeRow[] }),
        ]);
        const r = resultShape(t);
        return ok({
            swarm: row.id,
            agent: input.agent,
            status: t.status,
            items: JSON.parse(t.items) as unknown[],
            attempts: t.attempts,
            in_tokens: t.in_tokens,
            out_tokens: t.out_tokens,
            usd: r.usd,
            started_at: t.started_at,
            ended_at: t.ended_at,
            error: t.error,
            result: r.result,
            steps: parseSteps(t.steps ?? null),
            messages: msgs.results.map(messageShape),
            changes: changes.results.map(changeShape),
        });
    },
});

// ---- the results board (section 62.4) --------------------------------------------------------------------------------------

export const MediaRefSchema = z
    .object({
        ref: z.string(),
        kind: z.enum(["post", "file", "emote", "image", "video"]),
        preview_url: z.string().nullable(),
        open_url: z.string().nullable(),
        title: z.string().optional(),
        animated: z.boolean().optional(),
    })
    .meta({ id: "MediaRef" });

export const BoardRowSchema = z
    .object({
        agent: z.number(),
        n: z.number().describe("the row's number within its agent, from 1"),
        title: z.string(),
        score: z.number().nullable(),
        group: z.string().nullable(),
        fields: z.record(z.string(), z.union([z.string(), z.number(), z.boolean(), z.null()])).describe("the other plain values, at most 12"),
        media: z.array(MediaRefSchema).describe("resolved, at most 4"),
        links: z.array(z.string()),
    })
    .meta({ id: "BoardRow" });

type BoardTask = Pick<TaskRow, "idx" | "status" | "error" | "result" | "usd" | "started_at" | "ended_at" | "items"> & { stats: string | null; n_items: number };

export const swarmBoardOp = defineOp({
    name: "swarm.board",
    route: { method: "GET", path: "/swarms/:id/board", params: Params },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    badRequest: BAD,
    input: z.object({
        id: z.string().regex(SWARM_ID_REGEX),
        q: z.string().trim().max(200).optional().describe("matches any text of a row (case-insensitive)"),
        agent: z.coerce.number().int().min(1).max(TASKS_MAX).optional().describe("one agent's rows (from 1)"),
        status: z.enum(["queued", "running", "waiting", "done", "failed", "skipped"]).optional().describe("only agents with this status"),
        group: z.string().max(200).optional().describe("one group's rows"),
        sort: z.enum(["agent", "score", "title"]).optional().describe("agent (default), score (best first) or title"),
        offset: z.coerce.number().int().min(0).max(1_000_000).optional().describe("default 0"),
        limit: z.coerce.number().int().min(1).max(BOARD_LIMIT_MAX).optional().describe(`default ${BOARD_LIMIT_DEFAULT}, at most ${BOARD_LIMIT_MAX}`),
    }),
    output: z.object({
        swarm: SwarmSchema,
        total: z.number(),
        offset: z.number(),
        groups: z.array(z.object({ value: z.string(), count: z.number() })),
        agents: z.array(z.object({ agent: z.number(), status: z.string(), outcome: OutcomeSchema, error: z.string().nullable() })).describe("every agent, for the strip"),
        rows: z.array(BoardRowSchema),
    }),
    ai: {
        tier: "free",
        summary:
            "A swarm's results as one board: every agent's outcome and score, and a row per thing its agents answered (title, score, group, other fields, up to 4 media previews). Failed agents appear as a row too. Filter with q, agent, status, group; sort by agent, score or title; pages of up to 200.",
        params: ["id"],
        options: true,
    },
    handler: async (ctx, input) => {
        const row = await mustSee(ctx, input.id);
        const spec = specOf(row);
        const [{ results: tasks }, changes, asks, swarm] = await Promise.all([
            // only what the board reads: never the message history (state), and the items (which prefetch enlarges) only where a
            // row names them or the answered count was not kept
            ctx.db
                .prepare(
                    `SELECT idx, status, error, result, usd, started_at, ended_at, stats, json_array_length(items) AS n_items,
                            CASE WHEN status IN ('failed', 'skipped') OR json_extract(stats, '$.answered') IS NULL THEN items ELSE '[]' END AS items
                       FROM swarm_tasks WHERE swarm = ?1 ORDER BY idx`,
                )
                .bind(row.id)
                .all<BoardTask>(),
            row.mode === "propose" ? ctx.db.prepare("SELECT * FROM swarm_changes WHERE swarm = ?1 ORDER BY task, n").bind(row.id).all<ChangeRow>() : Promise.resolve({ results: [] as ChangeRow[] }),
            asksByTask(ctx.db, row.id),
            shapeOf(ctx.db, ctx.registry, row, webOrigin(ctx)),
        ]);
        const bases = { mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl, hosts: mediaHostsOf(ctx.env as { MEDIA_HOSTS?: string }, ctx) };
        const byTask = new Map<number, ChangeRow[]>();
        for (const c of changes.results) byTask.set(c.task, [...(byTask.get(c.task) ?? []), c]);
        const agents = [];
        const rows = [];
        for (const t of tasks) {
            const mine = agentRows(spec, t, byTask.get(t.idx) ?? [], bases);
            const stats = statsOf(t.stats);
            agents.push({ agent: t.idx + 1, status: t.status, outcome: outcomeOf(t, stats, stats.answered ?? answeredOf(JSON.parse(t.items) as unknown[], mine), asks.get(t.idx) ?? 0), error: t.error });
            if (!input.status || t.status === input.status) rows.push(...mine);
        }
        const page = await boardPage(ctx.db, rows, input, bases);
        return ok({ swarm, ...page, agents });
    },
});

export const SWARM_OPS = [
    swarmPlanOp,
    swarmListOp,
    swarmGetOp,
    swarmResultsOp,
    swarmChangesOp,
    swarmStopOp,
    swarmRetryOp,
    swarmApproveOp,
    swarmDeclineOp,
    swarmDecideOp,
    swarmApplyOp,
    swarmInboxOp,
    swarmSendOp,
    swarmMessagesOp,
    swarmAgentOp,
    swarmBoardOp,
];
