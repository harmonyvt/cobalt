// Agent swarms (APP-API-CONTRACT.md section 59): plan, follow, stop and retry a swarm (the agent's calls, also MCP tools),
// and approve, decline, review and apply one (Harmony's calls: the web Worker behind Cloudflare Access, or a signed-in
// device session; never a client key, never the chat or the MCP). The rules, the D1 side and the runner are in
// src/swarm.ts; a swarm's tasks run in its Swarm Durable Object (src/swarm-do.ts).
import * as z from "zod";
import { mintCollectionId } from "../../share-collections";
import {
    PLAN_TTL_MS,
    PLANS_ALL,
    PLANS_PER_KEY,
    EDIT_ARGS,
    argsHash,
    badSpec,
    clashGroup,
    RUNNING_ALL,
    RUNNING_PER_KEY,
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
    runningCounts,
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
} from "../../swarm";
import { defineOp, ok, OpError, type OpContext } from "../op";

const Params = { id: SWARM_ID_REGEX };
const BAD = "error.swarm.bad_spec";

// ---- shapes (APP-API-CONTRACT.md 59.4) -----------------------------------------------------------------------------------

const TaskStatus = z.enum(["queued", "running", "done", "failed", "skipped"]);
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
            done: z.number(),
            failed: z.number(),
            cells: z.array(z.object({ idx: z.number(), status: TaskStatus, error: z.string().nullable() })),
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
                turns_per_task: z.number(),
                attempts: z.number(),
                stop_after_failed_tasks: z.number(),
            })
            .describe("what the approve page shows of the spec"),
        unscoped_writes: z.array(z.string()).describe("write ops no scope key limits (none of their input fields is a scope key)"),
        approve_url: z.string().describe("Harmony approves (and reviews) here; give this link to Harmony"),
        job: z.string().describe("swarm:<id>, for job_status"),
    })
    .meta({ id: "Swarm" });

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

export const SwarmResultSchema = z
    .object({ task: z.number(), status: z.string(), result: z.unknown(), error: z.string().nullable(), usd: z.number() })
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
        return ok({ results: results.map(resultShape), total: total?.n ?? 0, offset });
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
        if (running.mine >= RUNNING_PER_KEY || running.all >= RUNNING_ALL) throw new OpError(429, "error.swarm.busy", "swarm: another swarm is running; approve this one when it ends");
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
    input: HashInput,
    output: SwarmSchema,
    ai: { tier: "hidden", summary: "Harmony applies the kept changes of a propose-mode swarm (no model: each through its op)." },
    handler: async (ctx, input) => {
        const row = await ownersSwarm(ctx, input.id);
        reviewable(row);
        if (input.spec_hash !== row.spec_hash) throw new OpError(409, "error.swarm.hash_mismatch", "swarm: the swarm changed since this page loaded");
        if (!swarmsOn(ctx.env)) throw new OpError(503, "error.swarm.off", "swarms cannot run on this server");
        const kept = await ctx.db.prepare("SELECT COUNT(*) AS n FROM swarm_changes WHERE swarm = ?1 AND keep = 1 AND status <> 'done'").bind(row.id).first<{ n: number }>();
        if ((kept?.n ?? 0) === 0) throw notAwaiting("no kept change is left to apply");
        const running = await runningCounts(ctx.db, row.key_id);
        if (running.all >= RUNNING_ALL) throw new OpError(429, "error.swarm.busy", "swarm: other swarms are running; apply when one ends");
        const now = ctx.now();
        const r = await ctx.db
            .prepare("UPDATE swarms SET apply_status = 'applying', stop_requested = 0, updated_at = ?2 WHERE id = ?1 AND apply_status IN ('ready', 'failed', 'none', 'applied')")
            .bind(row.id, now)
            .run();
        if ((r.meta?.changes ?? 0) === 0) throw notAwaiting("it is being applied already");
        await ctx.db.prepare("UPDATE swarm_changes SET status = 'proposed', error = NULL WHERE swarm = ?1 AND keep = 1 AND status = 'failed'").bind(row.id).run();
        try {
            await port(ctx).wake(row.id);
        } catch (e) {
            console.error("[swarm] wake failed", String(e));
            await setSwarm(ctx.db, row.id, { apply_status: "ready" }, now);
            throw new OpError(503, "error.swarm.off", "swarm: the runner did not start; try again");
        }
        return ok(await shape(ctx, row.id));
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
];
