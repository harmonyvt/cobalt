// Sub-agents (APP-API-CONTRACT.md section 43): the chat AI (or an MCP client) hands one task to a second chat AI that
// works on it in the background, tracks it, and the two (and sibling agents) send each other messages.
//
// A sub-agent is a row in chat_agents (migration 0027) plus a hidden chat thread with the same id: its replies, steps and
// tool cards are ordinary chat_messages, so the app opens it like any thread. Its replies run in the ChatAgent Durable
// Object's alarm (chat-agents-do.ts), one object per agent; this file holds the rules and the D1 side, free of Cloudflare
// imports so it runs under node in the tests. The reply itself is chat.ts's runAgentTurn.
//
// Mail (chat_agent_mail): sender and recipient are 'parent' or an agent id, inside one parent. A running reply (parent or
// agent) gets its unread mail before each model turn; a finished agent is woken by a message and answers it in a new
// reply.

export const AGENT_ID_REGEX = /^[A-Za-z0-9]{16}$/;
export const AGENT_JOB_REGEX = /^agent:([A-Za-z0-9]{16})$/;
export const agentJob = (id: string) => `agent:${id}`;
// running or queued at once, per parent
export const AGENTS_RUNNING_MAX = 4;
// rows kept per parent (older finished ones are dropped when a new one starts)
export const AGENTS_KEPT_MAX = 30;
// started per parent per UTC day (CHAT_DAILY_AGENTS overrides)
export const CHAT_DAILY_AGENTS_DEFAULT = 20;
// replies one agent may run: its task, then up to this many minus one wakes by a message
export const AGENT_TURNS_MAX = 6;
export const AGENT_NAME_MAX = 40;
export const AGENT_TASK_MAX = 4000;
export const AGENT_MAIL_MAX = 2000;
export const AGENT_POSTS_MAX = 20;
// unread messages handed to one model turn
const MAIL_BATCH = 10;
const RESULT_SHOWN_MAX = 4000;

export type AgentStatus = "queued" | "running" | "done" | "error" | "stopped";
export const AGENT_LIVE: readonly AgentStatus[] = ["queued", "running"];

export type AgentRow = {
    id: string;
    parent: string;
    name: string;
    task: string;
    status: AgentStatus;
    result: string | null;
    post_ids: string;
    error: string | null;
    activity: string | null;
    turns: number;
    created_at: number;
    updated_at: number;
    ended_at: number | null;
};

export type MailRow = { id: number; parent: string; sender: string; recipient: string; text: string; created_at: number; read_at: number | null };

// Who a reply speaks as: a parent thread (me = "parent") or one of its agents (me = the agent id).
export type Who = { parent: string; me: string };
export const whoOf = (threadId: string, agent?: { id: string; parent: string } | null): Who =>
    agent ? { parent: agent.parent, me: agent.id } : { parent: threadId, me: "parent" };

const parseIds = (s: string | null): string[] => {
    try {
        const v = JSON.parse(s ?? "[]");
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

// A D1 error from a database the migration has not reached yet.
export const isMissingTable = (e: unknown) => /no such table: chat_agent/.test(String(e instanceof Error ? e.message : e));

// The agent as the model, MCP and the app see it.
export function agentShape(r: AgentRow, unread = 0) {
    return {
        agent: r.id,
        job: agentJob(r.id),
        name: r.name,
        status: r.status,
        task: r.task,
        activity: r.status === "running" ? r.activity : null,
        result: r.result,
        post_ids: parseIds(r.post_ids),
        error: r.error,
        turns: r.turns,
        unread,
        created_at: r.created_at,
        updated_at: r.updated_at,
        ended_at: r.ended_at,
    };
}
export type AgentShape = ReturnType<typeof agentShape>;

export const mailShape = (m: MailRow, names: Map<string, string>) => ({
    id: m.id,
    from: m.sender,
    from_name: m.sender === "parent" ? "parent" : (names.get(m.sender) ?? m.sender),
    to: m.recipient,
    to_name: m.recipient === "parent" ? "parent" : (names.get(m.recipient) ?? m.recipient),
    text: m.text,
    created_at: m.created_at,
    read: m.read_at !== null,
});

// ---- D1 ------------------------------------------------------------------------------------------------------------

export async function agentRow(db: D1Database, id: string): Promise<AgentRow | null> {
    return (await db.prepare("SELECT * FROM chat_agents WHERE id = ?1").bind(id).first<AgentRow>()) ?? null;
}

export async function agentsOf(db: D1Database, parent: string): Promise<AgentRow[]> {
    const { results } = await db.prepare("SELECT * FROM chat_agents WHERE parent = ?1 ORDER BY created_at, rowid").bind(parent).all<AgentRow>();
    return results;
}

// The parent's agents with how many unread messages each has.
export async function agentsWithUnread(db: D1Database, parent: string): Promise<AgentShape[]> {
    const rows = await agentsOf(db, parent);
    if (rows.length === 0) return [];
    const { results } = await db
        .prepare("SELECT recipient, COUNT(*) AS n FROM chat_agent_mail WHERE parent = ?1 AND read_at IS NULL GROUP BY recipient")
        .bind(parent)
        .all<{ recipient: string; n: number }>();
    const unread = new Map(results.map((r) => [r.recipient, r.n]));
    return rows.map((r) => agentShape(r, unread.get(r.id) ?? 0));
}

// An agent of this parent by id or name (names are matched without case).
export async function findAgent(db: D1Database, parent: string, ref: string): Promise<AgentRow | null> {
    const rows = await agentsOf(db, parent);
    const want = ref.trim().toLowerCase();
    return rows.find((r) => r.id === ref) ?? rows.find((r) => r.name.toLowerCase() === want) ?? null;
}

export async function setAgent(db: D1Database, id: string, fields: Partial<Omit<AgentRow, "id" | "parent">>, now: number): Promise<void> {
    const keys = Object.keys(fields) as (keyof typeof fields)[];
    if (keys.length === 0) return;
    const sets = keys.map((k, i) => `${k} = ?${i + 2}`).join(", ");
    await db
        .prepare(`UPDATE chat_agents SET ${sets}, updated_at = ?${keys.length + 2} WHERE id = ?1`)
        .bind(id, ...keys.map((k) => fields[k] as unknown), now)
        .run();
}

// Unread mail for `who`, oldest first (at most MAIL_BATCH), marked read.
export async function takeMail(db: D1Database, who: Who, now: number): Promise<MailRow[]> {
    const { results } = await db
        .prepare(`SELECT * FROM chat_agent_mail WHERE parent = ?1 AND recipient = ?2 AND read_at IS NULL ORDER BY id LIMIT ${MAIL_BATCH}`)
        .bind(who.parent, who.me)
        .all<MailRow>();
    if (results.length > 0) {
        await db
            .prepare(`UPDATE chat_agent_mail SET read_at = ?2 WHERE id IN (${results.map((_, i) => `?${i + 3}`).join(", ")}) AND parent = ?1`)
            .bind(who.parent, now, ...results.map((m) => m.id))
            .run();
    }
    return results;
}

export async function unreadCount(db: D1Database, who: Who): Promise<number> {
    const r = await db
        .prepare("SELECT COUNT(*) AS n FROM chat_agent_mail WHERE parent = ?1 AND recipient = ?2 AND read_at IS NULL")
        .bind(who.parent, who.me)
        .first<{ n: number }>();
    return r?.n ?? 0;
}

export async function putMail(db: D1Database, parent: string, sender: string, recipient: string, text: string, now: number): Promise<number> {
    const r = await db
        .prepare("INSERT INTO chat_agent_mail (parent, sender, recipient, text, created_at) VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id")
        .bind(parent, sender, recipient, text, now)
        .first<{ id: number }>();
    return r!.id;
}

export async function agentNames(db: D1Database, parent: string): Promise<Map<string, string>> {
    return new Map((await agentsOf(db, parent)).map((r) => [r.id, r.name]));
}

// The mail as one note the model reads (null when there is none).
export function mailNote(mail: MailRow[], names: Map<string, string>, who: Who): string | null {
    if (mail.length === 0) return null;
    const from = (s: string) => (s === "parent" ? (who.me === "parent" ? "you" : "your parent (the main chat)") : `sub-agent "${names.get(s) ?? s}" (${s})`);
    const lines = mail.map((m) => `- from ${from(m.sender)}: ${m.text}`);
    return `[New ${mail.length === 1 ? "message" : "messages"} (cobalt.agents):\n${lines.join("\n")}]`;
}

// Pull the unread mail for one reply turn, as a note (null: none, or agents are off / not migrated).
export async function pullMail(db: D1Database, who: Who, now: number): Promise<string | null> {
    try {
        const mail = await takeMail(db, who, now);
        if (mail.length === 0) return null;
        return mailNote(mail, await agentNames(db, who.parent), who);
    } catch (e) {
        if (!isMissingTable(e)) console.error("[chat-agents] mail failed", String(e));
        return null;
    }
}

// The rows to drop so a new agent fits under AGENTS_KEPT_MAX: the oldest finished ones.
export function agentsToDrop(rows: AgentRow[]): string[] {
    const over = rows.length + 1 - AGENTS_KEPT_MAX;
    if (over <= 0) return [];
    return rows
        .filter((r) => !AGENT_LIVE.includes(r.status))
        .sort((a, b) => a.created_at - b.created_at)
        .slice(0, over)
        .map((r) => r.id);
}

// Deletes agents with their threads and mail.
export async function dropAgents(db: D1Database, parent: string, ids: string[]): Promise<void> {
    if (ids.length === 0) return;
    const list = ids.map((_, i) => `?${i + 2}`).join(", ");
    await db.batch([
        db.prepare(`DELETE FROM chat_messages WHERE thread_id IN (${list})`).bind(parent, ...ids),
        db.prepare(`DELETE FROM chat_threads WHERE id IN (${list})`).bind(parent, ...ids),
        db.prepare(`DELETE FROM chat_agent_mail WHERE parent = ?1 AND (sender IN (${list}) OR recipient IN (${list}))`).bind(parent, ...ids),
        db.prepare(`DELETE FROM chat_agents WHERE parent = ?1 AND id IN (${list})`).bind(parent, ...ids),
    ]);
}

// Every agent of a parent thread, with the parent's own mail (the parent thread was deleted).
export async function dropAllAgents(db: D1Database, parent: string): Promise<void> {
    try {
        const ids = (await agentsOf(db, parent)).map((r) => r.id);
        if (ids.length > 0) await dropAgents(db, parent, ids);
        await db.prepare("DELETE FROM chat_agent_mail WHERE parent = ?1").bind(parent).run();
    } catch (e) {
        if (!isMissingTable(e)) throw e;
    }
}

// What jobs.wait / jobs.onDone see for `agent:<id>` (section 43.4).
export function agentJobState(r: AgentRow) {
    const base = { job: agentJob(r.id), agent: r.id, name: r.name };
    switch (r.status) {
        case "done":
            return { ...base, status: "done", result: r.result ? (r.result.length > RESULT_SHOWN_MAX ? `${r.result.slice(0, RESULT_SHOWN_MAX)}…` : r.result) : "", post_ids: parseIds(r.post_ids) };
        case "error":
            return { ...base, status: "error", error: r.error ?? "error.chat.agent_failed", result: r.result ?? "" };
        case "stopped":
            return { ...base, status: "cancelled", result: r.result ?? "" };
        default:
            return { ...base, status: r.status === "queued" ? "queued" : "running", activity: r.activity };
    }
}

// ---- the Durable Object's side -------------------------------------------------------------------------------------

export const AGENT_INTERNAL_HEADER = "x-internal-key";

export type AgentsNamespace = {
    idFromName(name: string): unknown;
    get(id: unknown): { fetch(r: Request): Promise<Response> };
};

// Wakes an agent's object: it runs the agent's next reply in its alarm.
export type AgentsPort = { wake(id: string): Promise<void> };

export function agentsPort(ns: AgentsNamespace, internalKey: string): AgentsPort {
    return {
        async wake(id) {
            const res = await ns.get(ns.idFromName(id)).fetch(
                new Request("https://chat-agents.internal/wake", {
                    method: "PUT",
                    headers: { "content-type": "application/json", [AGENT_INTERNAL_HEADER]: internalKey },
                    body: JSON.stringify({ agent: id }),
                }),
            );
            await res.body?.cancel().catch(() => {});
            if (!res.ok) throw new Error(`the agent runner answered ${res.status}`);
        },
    };
}

type Storage = { get<T>(key: string): Promise<T | undefined>; put(key: string, value: unknown): Promise<void> };

// What one alarm comes to: run again at once ("again"), or nothing left ("idle").
export type AgentTickOutcome = "again" | "idle";

export type AgentRunnerDeps = {
    storage: Storage;
    setAlarm: (inMs: number) => Promise<void>;
    // the agent's next reply (chat.ts runAgentTurn)
    turn: (id: string) => Promise<AgentTickOutcome>;
};

export class AgentRunnerCore {
    constructor(private d: AgentRunnerDeps) {}

    async wake(raw: unknown): Promise<boolean> {
        const id = (raw as { agent?: unknown } | null)?.agent;
        if (typeof id !== "string" || !AGENT_ID_REGEX.test(id)) return false;
        await this.d.storage.put("agent", id);
        await this.d.setAlarm(0);
        return true;
    }

    async tick(): Promise<void> {
        const id = await this.d.storage.get<string>("agent");
        if (!id) return;
        const outcome = await this.d.turn(id);
        if (outcome === "again") await this.d.setAlarm(0);
    }
}

export async function handleAgentRoute(core: AgentRunnerCore, request: Request, internalKey: string): Promise<Response> {
    if (!internalKey || request.headers.get(AGENT_INTERNAL_HEADER) !== internalKey) return new Response(null, { status: 403 });
    const { pathname } = new URL(request.url);
    if (pathname === "/wake" && request.method === "PUT") {
        return (await core.wake(await request.json().catch(() => null)))
            ? Response.json({ status: "success" })
            : Response.json({ status: "error", error: { code: "error.chat.bad_request" } }, { status: 400 });
    }
    return new Response(null, { status: 404 });
}

// Sub-agents are on while the binding is there and the daily cap is not 0.
export const agentsOn = (env: { CHAT_AGENTS?: unknown; CHAT_DAILY_AGENTS?: string }) => !!env.CHAT_AGENTS && env.CHAT_DAILY_AGENTS?.trim() !== "0";
