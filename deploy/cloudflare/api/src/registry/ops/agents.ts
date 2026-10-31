// Sub-agents (APP-API-CONTRACT.md section 43): cobalt.agents.* for the chat AI and MCP, and the app's read of a thread's
// agents. The rules and the D1 side are in chat-agents.ts; an agent's replies run in its ChatAgent Durable Object.
import * as z from "zod";
import {
    AGENT_LIVE,
    AGENT_MAIL_MAX,
    AGENT_NAME_MAX,
    AGENT_POSTS_MAX,
    AGENT_TASK_MAX,
    AGENT_TURNS_MAX,
    AGENTS_RUNNING_MAX,
    CHAT_DAILY_AGENTS_DEFAULT,
    agentNames,
    agentRow,
    agentShape,
    agentsOf,
    agentsOn,
    agentsPort,
    agentsToDrop,
    agentsWithUnread,
    dropAgents,
    findAgent,
    isMissingTable,
    mailShape,
    putMail,
    setAgent,
    takeMail,
    unreadCount,
    whoOf,
    type AgentRow,
    type AgentsNamespace,
    type MailRow,
    type Who,
} from "../../chat-agents";
import { loadPosts } from "../../chat-tools";
import { THREAD_ID_REGEX } from "../../gate";
import { mintCollectionId } from "../../share-collections";
import { budgetPort, dailyCap } from "../budget";
import { chatKeyId } from "../ai";
import { defineOp, ok, OpError, type OpContext } from "../op";

const AgentSchema = z
    .object({
        agent: z.string().describe("its id"),
        job: z.string().describe("agent:<id>: hand it to jobs.onDone to hear when it finishes"),
        name: z.string(),
        status: z.enum(["queued", "running", "done", "error", "stopped"]),
        task: z.string(),
        activity: z.string().nullable().describe("while running: the call it made last"),
        result: z.string().nullable().describe("its report (its last reply), once it ended"),
        post_ids: z.array(z.string()).describe("the posts it showed"),
        error: z.string().nullable(),
        turns: z.number().describe("replies it ran: its task, then one per message that woke it"),
        unread: z.number().describe("messages waiting for it"),
        created_at: z.number(),
        updated_at: z.number(),
        ended_at: z.number().nullable(),
    })
    .meta({ id: "Agent" });

const MailSchema = z
    .object({
        id: z.number(),
        from: z.string().describe('"parent" or an agent id'),
        from_name: z.string(),
        to: z.string(),
        to_name: z.string(),
        text: z.string(),
        created_at: z.number(),
        read: z.boolean(),
    })
    .meta({ id: "AgentMail" });

const refuse = (call: string, message: string, status = 400, code = "error.chat.agents_refused") => new OpError(status, code, `cobalt.agents.${call}: ${message}`);

// The caller as a chat call: its thread, and whether it is a sub-agent.
function callerOf(ctx: OpContext, call: string): { who: Who; threadId: string; agent: { id: string; parent: string } | null } {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", `cobalt.agents.${call}: only the chat can call this`);
    if (!agentsOn(ctx.env)) throw refuse(call, "sub-agents are off on this server", 404, "error.chat.agents_off");
    const agent = ctx.chat.agent ?? null;
    return { who: whoOf(ctx.chat.threadId, agent), threadId: ctx.chat.threadId, agent };
}

// D1 before the migration: one clear refusal instead of a generic error.
async function d1<T>(call: string, p: Promise<T>): Promise<T> {
    try {
        return await p;
    } catch (e) {
        if (isMissingTable(e)) throw refuse(call, "sub-agents are not set up on this server yet (migration 0027)", 503, "error.chat.agents_not_ready");
        throw e;
    }
}

const port = (ctx: OpContext) => agentsPort(ctx.env.CHAT_AGENTS as unknown as AgentsNamespace, ctx.env.COBALT_API_KEY);
const agentsCap = (ctx: OpContext) => dailyCap(ctx.env.CHAT_DAILY_AGENTS, CHAT_DAILY_AGENTS_DEFAULT);

// eslint-disable-next-line no-control-regex
const oneLine = (s: string) => s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();

async function mustFind(ctx: OpContext, call: string, parent: string, ref: string): Promise<AgentRow> {
    const row = await d1(call, findAgent(ctx.db, parent, ref));
    if (!row) throw refuse(call, `no sub-agent "${ref}" in this chat (cobalt.agents.list() names them)`, 404, "error.chat.agent_not_found");
    return row;
}

// ---- cobalt.agents.spawn ----------------------------------------------------------------------------------------------

export const agentsSpawnOp = defineOp({
    name: "agents.spawn",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        task: z.string().min(1).max(AGENT_TASK_MAX).describe("everything the helper needs: it does not see this chat"),
        name: z.string().min(1).max(AGENT_NAME_MAX).optional().describe("a short name to call it by (default helper 1, helper 2, ...)"),
        posts: z.array(z.string().min(1).max(2048)).max(AGENT_POSTS_MAX).optional().describe("post ids to hand it with the task"),
    }),
    output: AgentSchema,
    ai: {
        tier: "free",
        only: true,
        summary: `Start a sub-agent (a helper chat AI with the same tools) on one task; it works in the background. At most ${AGENTS_RUNNING_MAX} at once. Hand its job to jobs.onDone to get its report when it finishes.`,
        params: ["task"],
        options: true,
        when: (f) => f.agents === true && f.subagent !== true,
    },
    handler: async (ctx, input) => {
        const call = "spawn";
        const { threadId, agent } = callerOf(ctx, call);
        if (agent) throw refuse(call, "a sub-agent cannot start sub-agents of its own: say in your report what else should be done");
        const parent = threadId;
        const rows = await d1(call, agentsOf(ctx.db, parent));
        const live = rows.filter((r) => AGENT_LIVE.includes(r.status));
        if (live.length >= AGENTS_RUNNING_MAX) {
            throw refuse(call, `${live.length} sub-agents are already working (${live.map((r) => r.name).join(", ")}): wait for one with jobs.onDone, or stop one`, 429, "error.chat.agents_busy");
        }
        let name = input.name ? oneLine(input.name) : "";
        if (!name) {
            for (let n = rows.length + 1; ; n++) {
                name = `helper ${n}`;
                if (!rows.some((r) => r.name.toLowerCase() === name)) break;
            }
        }
        if (Array.from(name).length > AGENT_NAME_MAX) name = Array.from(name).slice(0, AGENT_NAME_MAX).join("");
        const dropped = new Set(agentsToDrop(rows));
        if (rows.some((r) => r.name.toLowerCase() === name.toLowerCase() && !dropped.has(r.id))) {
            throw refuse(call, `a sub-agent named "${name}" already exists in this chat: pick another name`, 409, "error.chat.agent_name_taken");
        }
        const cap = agentsCap(ctx);
        if (!(await budgetPort(ctx.container).take(parent, "agents", cap))) {
            throw refuse(call, `this chat already started ${cap} sub-agents today, the most it may start in a day: do the rest yourself`, 429, "error.chat.agents_cap");
        }
        try {
            await dropAgents(ctx.db, parent, [...dropped]);
            const posts = input.posts && input.posts.length > 0 ? (await loadPosts({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl }, [...new Set(input.posts)])).map((p) => p.record.id) : [];
            const now = ctx.now();
            const id = mintCollectionId();
            await ctx.db.batch([
                ctx.db
                    .prepare("INSERT INTO chat_threads (id, title, titled_by, key_id, created_at, updated_at) VALUES (?1, ?2, 'user', ?3, ?4, ?4)")
                    .bind(id, name, chatKeyId(parent), now),
                ctx.db
                    .prepare("INSERT INTO chat_agents (id, parent, name, task, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?5)")
                    .bind(id, parent, name, input.task, now),
                // its task is the thread's first message (with the posts it was handed)
                ctx.db
                    .prepare("INSERT INTO chat_messages (thread_id, role, text, post_ids, status, created_at, updated_at) VALUES (?1, 'user', ?2, ?3, 'done', ?4, ?4)")
                    .bind(id, input.task, JSON.stringify(posts), now),
            ]);
            try {
                await port(ctx).wake(id);
            } catch (e) {
                console.error("[agents] wake failed", String(e));
                await setAgent(ctx.db, id, { status: "error", error: "error.chat.agent_start", ended_at: now }, now);
                throw refuse(call, "the sub-agent could not start: do it yourself", 503, "error.chat.agent_start");
            }
            return ok(agentShape((await agentRow(ctx.db, id))!));
        } catch (e) {
            await budgetPort(ctx.container).refund(parent, "agents");
            throw e;
        }
    },
});

// ---- list, get ----------------------------------------------------------------------------------------------------

export const agentsListOp = defineOp({
    name: "agents.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.object({ agents: z.array(AgentSchema), unread: z.number().describe("messages waiting for you (agents.inbox)") }),
    ai: {
        tier: "free",
        only: true,
        summary: "This chat's sub-agents, oldest first, with what each is doing or found.",
        when: (f) => f.agents === true,
    },
    handler: async (ctx) => {
        const { who } = callerOf(ctx, "list");
        const agents = await d1("list", agentsWithUnread(ctx.db, who.parent));
        return ok({ agents, unread: await unreadCount(ctx.db, who) });
    },
});

// The op names of a sub-agent's latest calls, newest last (from its thread's last reply).
async function lastCalls(ctx: OpContext, id: string): Promise<string[]> {
    const r = await ctx.db
        .prepare("SELECT steps FROM chat_messages WHERE thread_id = ?1 AND role = 'assistant' ORDER BY id DESC LIMIT 1")
        .bind(id)
        .first<{ steps: string }>();
    try {
        const steps = JSON.parse(r?.steps ?? "[]") as { calls?: { op?: unknown }[] }[];
        return steps.flatMap((s) => (s.calls ?? []).map((c) => String(c.op ?? ""))).filter(Boolean).slice(-12);
    } catch {
        return [];
    }
}

export const agentsGetOp = defineOp({
    name: "agents.get",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ agent: z.string().min(1).max(64).describe("its id or name") }),
    output: AgentSchema.extend({ calls: z.array(z.string()).describe("its latest calls in its current or last reply") }),
    ai: {
        tier: "free",
        only: true,
        summary: "One sub-agent: its task, status, what it is doing now, its report and posts.",
        params: ["agent"],
        when: (f) => f.agents === true,
    },
    handler: async (ctx, input) => {
        const { who } = callerOf(ctx, "get");
        const row = await mustFind(ctx, "get", who.parent, input.agent);
        const unread = await unreadCount(ctx.db, { parent: who.parent, me: row.id });
        return ok({ ...agentShape(row, unread), calls: await lastCalls(ctx, row.id) });
    },
});

// ---- send, inbox, stop ------------------------------------------------------------------------------------------------

export const agentsSendOp = defineOp({
    name: "agents.send",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        to: z.string().min(1).max(64).describe('a sub-agent\'s name or id, or "parent" (from a sub-agent)'),
        text: z.string().min(1).max(AGENT_MAIL_MAX),
    }),
    output: z.object({ sent: z.number(), to: z.string(), to_name: z.string(), woke: z.boolean().describe("it had finished, and starts a new reply to answer") }),
    ai: {
        tier: "free",
        only: true,
        summary: "Send a message. A running sub-agent reads it before its next step; one that finished wakes up and answers it.",
        params: ["to", "text"],
        when: (f) => f.agents === true,
    },
    handler: async (ctx, input) => {
        const call = "send";
        const { who } = callerOf(ctx, call);
        const now = ctx.now();
        if (input.to.trim().toLowerCase() === "parent") {
            if (who.me === "parent") throw refuse(call, 'you are the parent: send to a sub-agent by its name');
            const sent = await d1(call, putMail(ctx.db, who.parent, who.me, "parent", input.text, now));
            return ok({ sent, to: "parent", to_name: "parent", woke: false });
        }
        const row = await mustFind(ctx, call, who.parent, input.to);
        if (row.id === who.me) throw refuse(call, "that is you");
        if (row.status === "stopped") throw refuse(call, `"${row.name}" was stopped`, 409, "error.chat.agent_stopped");
        const sent = await putMail(ctx.db, who.parent, who.me, row.id, input.text, now);
        let woke = false;
        if (!AGENT_LIVE.includes(row.status) && row.turns < AGENT_TURNS_MAX) {
            await setAgent(ctx.db, row.id, { status: "queued", ended_at: null }, now);
            await port(ctx).wake(row.id).catch((e) => console.error("[agents] wake failed", String(e)));
            woke = true;
        } else if (AGENT_LIVE.includes(row.status)) {
            // it reads it between steps; its runner picks it up after the reply if it was too late for that
            await port(ctx).wake(row.id).catch(() => {});
        }
        return ok({ sent, to: row.id, to_name: row.name, woke });
    },
});

export const agentsInboxOp = defineOp({
    name: "agents.inbox",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.object({ messages: z.array(MailSchema) }),
    ai: {
        tier: "free",
        only: true,
        summary: "Messages sent to you by sub-agents (or, for a sub-agent, by the parent and its siblings) that you have not read yet.",
        when: (f) => f.agents === true,
    },
    handler: async (ctx) => {
        const { who } = callerOf(ctx, "inbox");
        const mail = await d1("inbox", takeMail(ctx.db, who, ctx.now()));
        const names = await agentNames(ctx.db, who.parent);
        return ok({ messages: mail.map((m) => mailShape(m, names)) });
    },
});

export const agentsStopOp = defineOp({
    name: "agents.stop",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ agent: z.string().min(1).max(64).describe("its id or name") }),
    output: AgentSchema,
    ai: {
        tier: "free",
        only: true,
        summary: "Stop a sub-agent after the step it is on. Its report so far stays.",
        params: ["agent"],
        when: (f) => f.agents === true && f.subagent !== true,
    },
    handler: async (ctx, input) => {
        const { who } = callerOf(ctx, "stop");
        const row = await mustFind(ctx, "stop", who.parent, input.agent);
        const now = ctx.now();
        if (row.status !== "stopped") await setAgent(ctx.db, row.id, { status: "stopped", activity: null, ...(AGENT_LIVE.includes(row.status) ? { ended_at: now } : {}) }, now);
        return ok(agentShape((await agentRow(ctx.db, row.id))!));
    },
});

// ---- GET /chat/threads/:id/agents (the app, section 43.6) --------------------------------------------------------------

export const MAIL_PAGE = 50;

export const chatAgentsRouteOp = defineOp({
    name: "chat.agents",
    route: { method: "GET", path: "/chat/threads/:id/agents", params: { id: THREAD_ID_REGEX } },
    auth: "key",
    runs: "worker",
    cors: true,
    noStore: true,
    input: z.object({ id: z.string() }),
    http: (ctx: OpContext) => ({ id: ctx.params.id }),
    output: z.object({ agents: z.array(AgentSchema), mail: z.array(MailSchema) }),
    ai: { tier: "hidden", summary: "A chat thread's sub-agents and their messages (section 43.6)." },
    handler: async (ctx, input) => {
        const t = await ctx.db.prepare("SELECT id FROM chat_threads WHERE id = ?1").bind(input.id).first<{ id: string }>();
        if (!t) return { status: 404, body: { status: "error", error: { code: "error.chat.not_found" } }, headers: { "cache-control": "no-store" } };
        let agents: ReturnType<typeof agentShape>[] = [];
        let mail: MailRow[] = [];
        try {
            agents = await agentsWithUnread(ctx.db, input.id);
            mail = (
                await ctx.db
                    .prepare(`SELECT * FROM chat_agent_mail WHERE parent = ?1 ORDER BY id DESC LIMIT ${MAIL_PAGE}`)
                    .bind(input.id)
                    .all<MailRow>()
            ).results.reverse();
        } catch (e) {
            if (!isMissingTable(e)) throw e;
        }
        const names = new Map(agents.map((a) => [a.agent, a.name]));
        return { status: 200, body: { status: "success", agents, mail: mail.map((m) => mailShape(m, names)) }, headers: { "cache-control": "no-store" } };
    },
});

export const AGENT_OPS = [agentsSpawnOp, agentsListOp, agentsGetOp, agentsSendOp, agentsInboxOp, agentsStopOp, chatAgentsRouteOp];
