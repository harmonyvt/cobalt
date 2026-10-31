// Sub-agents (APP-API-CONTRACT.md section 43): a real chat reply starts two helpers and hands their jobs to the server;
// each helper's Durable Object runs its reply (AgentRunnerCore for real on a Map, runAgentTurn with the route's own
// deps); the helpers message each other and the parent; the ChatJobs watcher continues the parent chat with their reports.
// The real SQL runs on node:sqlite, the model is scripted per thread, the code runs through the real sandbox source.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { resumeAfterJobs, runAgentTurn, systemPrompt, type ChatModel, type CodeRunner, type ModelTurn } from "../src/chat";
import { AGENTS_KEPT_MAX, AgentRunnerCore, agentsToDrop, handleAgentRoute, type AgentRow } from "../src/chat-agents";
import { ChatJobsCore, handleChatJobsRoute } from "../src/chat-jobs";
import { sandboxModule } from "../src/chat-loader-module";
import { chatTools } from "../src/chat-tools";
import { hashKey } from "../src/keys";
import { mcpFlags, mcpOps, mcpToolName } from "../src/mcp";
import { chatKeyId } from "../src/registry/ai";
import { forCall } from "../src/registry/context";
import { chatToolbox, opBase, REGISTRY, toolTypes } from "../src/registry/index";
import { handleChatBudgetRoute } from "../src/registry/budget";
import { handleChatPendingRoute } from "../src/registry/pending";
import { chatDepsFrom } from "../src/registry/ops/chat";
import { waitJob } from "../src/registry/ops/make";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };

let KEY_HASH = "";
let db: FakeD1;
let env: WorkerEnv;
let clock = 0;
let storage: Map<string, unknown>;
let runners: Map<string, { core: AgentRunnerCore; alarm: number | null }>;
let jobs: ChatJobsCore;
// the scripted model: one queue per speaker ("parent" or a helper's name), picked from the system prompt
let scripts: Map<string, ((s: Seen) => ModelTurn)[]>;
let seen: (Seen & { who: string })[];
type Seen = { system: string; messages: any[] };

const st = {
    get: async <T,>(k: string) => storage.get(k) as T | undefined,
    put: async (k: string, v: unknown) => void storage.set(k, structuredClone(v)),
    delete: async (k: string) => storage.delete(k),
};
const mapStorage = (m: Map<string, unknown>) => ({
    get: async <T,>(k: string) => m.get(k) as T | undefined,
    put: async (k: string, v: unknown) => void m.set(k, structuredClone(v)),
    delete: async (k: string) => m.delete(k),
    list: async <T,>(o: { prefix: string }) => new Map([...m].filter(([k]) => k.startsWith(o.prefix)).sort(([a], [b]) => a.localeCompare(b, "en", { numeric: true })) as [string, T][]),
});

const container = {
    async fetch(req: Request): Promise<Response> {
        const p = new URL(req.url).pathname;
        if (p.startsWith("/chat/budget/")) return handleChatBudgetRoute(st, req, clock);
        if (p.startsWith("/chat/pending/")) return handleChatPendingRoute(st, req, clock);
        return Response.json({ status: "error", error: { code: "error.test.unexpected" } }, { status: 500 });
    },
};

const runner: CodeRunner = async (code, tools) => {
    const mod = sandboxModule(code).replace(/^import .*$/m, "").replace("export default class Run", "return class Run");
    // eslint-disable-next-line @typescript-eslint/no-implied-eval
    const Run = new Function("WorkerEntrypoint", mod)(class {});
    const d = {
        call: async (name: string, args: string) => {
            const fn = Object.prototype.hasOwnProperty.call(tools, name) ? tools[name] : undefined;
            if (!fn) return JSON.stringify({ error: `cobalt.${name} does not exist` });
            try {
                return JSON.stringify({ result: (await fn(...JSON.parse(args))) ?? null });
            } catch (e) {
                return JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
            }
        },
    };
    const r = await new Run().evaluate(d);
    return r.error !== undefined ? { error: r.error, logs: r.logs, calls: 0 } : { result: JSON.parse(r.result), logs: r.logs, calls: 0 };
};

const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
const code = (id: string, src: string): ModelTurn => ({ content: [{ type: "tool_use", id, name: "run_code", input: { code: src } }], stop_reason: "tool_use" });
const lastText = (s: Seen) => JSON.stringify(s.messages[s.messages.length - 1].content);
const resultOf = (s: Seen) => JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);

const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, onText }) {
        const who = /^You are "([^"]+)", a helper/.exec(system)?.[1] ?? "parent";
        const s = { system, messages: JSON.parse(JSON.stringify(messages)), who };
        seen.push(s);
        const next = scripts.get(who)?.shift();
        if (!next) throw new Error(`no script left for ${who}`);
        const r = next(s);
        for (const b of r.content) if (b.type === "text") onText(b.text);
        return r;
    },
    async title() {
        return null;
    },
};

const edge = () => ({ now: () => clock, sleep: async (ms: number) => void (clock += ms), chatModel: model, codeRunner: runner });
const base = () => opBase(env, container, edge(), REGISTRY);

const call = (path: string, method: string, body?: unknown) =>
    handleRequest(
        new Request(`${API}${path}`, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }),
        env,
        container,
        edge(),
    );
const json = async (r: Response | Promise<Response>) => (await (await r).json()) as any;

// One alarm of a helper's Durable Object.
async function tickAgent(id: string) {
    const r = runners.get(id);
    if (!r) throw new Error(`no runner for ${id}`);
    r.alarm = null;
    await r.core.tick();
}

const agentRows = () => db.raw.prepare("SELECT * FROM chat_agents ORDER BY created_at, rowid").all() as AgentRow[];

// The parent thread's `cobalt` for one run, outside a reply (as chat.ts builds it).
function toolbox(threadId: string, agent: { id: string; parent: string } | null = null): Record<string, ((...a: unknown[]) => Promise<any>) | undefined> {
    const collect = { look: [], show: [], collage: null };
    const legacy = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, embed: null }, collect);
    return chatToolbox(REGISTRY, base(), {
        threadId,
        messageId: null,
        collect,
        legacy,
        flags: { search: false, agents: true, subagent: !!agent },
        pending: null,
        agent,
    }).tools;
}
const thrown = async (p: Promise<unknown>) => {
    try {
        await p;
    } catch (e) {
        return (e as Error).message;
    }
    throw new Error("did not throw");
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    clock = 1_800_000_000_000;
    storage = new Map();
    runners = new Map();
    scripts = new Map();
    seen = [];
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        ANTHROPIC_API_KEY: "test",
    } as WorkerEnv;
    // each helper's ChatAgent object: its rules for real, its alarm recorded (the test fires it with tickAgent)
    env.CHAT_AGENTS = {
        idFromName: (n: string) => n,
        get: (id: string) => ({
            fetch: (r: Request) => {
                let entry = runners.get(id);
                if (!entry) {
                    const store = new Map<string, unknown>();
                    const e: { core: AgentRunnerCore; alarm: number | null } = { core: null as any, alarm: null };
                    e.core = new AgentRunnerCore({
                        storage: mapStorage(store),
                        setAlarm: async (ms) => void (e.alarm = ms),
                        turn: (agent) => runAgentTurn(chatDepsFrom(base())!, agent),
                    });
                    runners.set(id, e);
                    entry = e;
                }
                return handleAgentRoute(entry.core, r, INTERNAL);
            },
        }),
    } as unknown as DurableObjectNamespace;
    // the parent thread's ChatJobs object
    jobs = new ChatJobsCore({
        storage: mapStorage(new Map()),
        now: () => clock,
        setAlarm: async () => {},
        check: (thread, job) => waitJob(forCall(base(), { keyId: chatKeyId(thread), caller: "chat", chat: { threadId: thread, collect: { look: [], show: [], collage: null }, tools: {} } }), job, 0),
        resume: (thread, ended) => resumeAfterJobs(chatDepsFrom(base())!, thread, ended),
    });
    env.CHAT_JOBS = {
        idFromName: (n: string) => n,
        get: () => ({ fetch: (r: Request) => handleChatJobsRoute(jobs, r, INTERNAL) }),
    } as unknown as DurableObjectNamespace;
});

describe("sub-agents through the chat", () => {
    it("the parent starts two helpers and waits; they run, message each other and the parent; the parent gets their reports", async () => {
        scripts.set("parent", [
            (s) => {
                expect(s.system).toContain("Sub-agents: for a big job");
                expect(s.system).toContain("spawn(task: string");
                return code(
                    "tu_1",
                    `const a = await cobalt.agents.spawn("count the videos from march", { name: "counter" });
                     const b = await cobalt.agents.spawn("check the cat collection");
                     await cobalt.jobs.onDone(a.job, "tell Harmony the count");
                     await cobalt.jobs.onDone(b.job);
                     return [a.name, a.status, b.name];`,
                );
            },
            (s) => {
                const r = resultOf(s);
                expect(r.result).toEqual(["counter", "queued", "helper 2"]);
                expect(r.note).toMatch(/server is watching that job/);
                return say("two helpers are on it (=^･ω･^=)");
            },
            // the continuation once both helpers ended
            (s) => {
                const t = lastText(s);
                expect(t).toContain("cobalt.jobs.onDone have ended");
                expect(t).toContain("12 videos in march");
                expect(t).toContain("no cats here");
                expect(t).toContain("A sub-agent's result is its report");
                // the helper's message to the parent came in with it
                expect(t).toContain('from sub-agent \\"counter\\"');
                expect(t).toContain("halfway there");
                return say("12 videos in march, and no cats (｡•̀ᴗ-)✧");
            },
        ]);
        scripts.set("counter", [
            (s) => {
                expect(s.system).toMatch(/^You are "counter", a helper \(sub-agent\)/);
                expect(s.system).not.toContain("spawn(task");
                expect(s.system).not.toContain("Sub-agents: for a big job");
                expect(lastText(s)).toContain("count the videos from march");
                return code(
                    "tu_c1",
                    `await cobalt.agents.send("parent", "halfway there");
                     await cobalt.agents.send("helper 2", "psst, cats are in Lia Share 11");
                     try { await cobalt.agents.spawn("more"); return "spawned"; } catch (e) { return String(e.message ?? e); }`,
                );
            },
            (s) => {
                expect(resultOf(s).result).toMatch(/cobalt.agents.spawn does not exist/);
                return say("12 videos in march");
            },
        ]);
        scripts.set("helper 2", [
            (s) => {
                const t = lastText(s);
                expect(t).toContain("check the cat collection");
                // counter's message was waiting before its first turn
                expect(t).toContain('from sub-agent \\"counter\\"');
                expect(t).toContain("cats are in Lia Share 11");
                return code("tu_h1", `return await cobalt.library.delete(["AbCdEfGh12345678"]);`);
            },
            (s) => {
                expect(lastText(s)).toMatch(/a sub-agent cannot ask/);
                return say("no cats here; the parent should delete AbCdEfGh12345678");
            },
        ]);

        const t = (await json(call("/chat/threads", "POST", {}))).thread;
        const text = await (await call(`/chat/threads/${t.id}/messages`, "POST", { text: "how many march videos, and any cats?" })).text();
        expect(text).toContain("event: done");

        // two queued helpers, each with its own thread (left out of the thread list) and its runner woken
        let rows = agentRows();
        expect(rows.map((r) => [r.name, r.status, r.parent])).toEqual([
            ["counter", "queued", t.id],
            ["helper 2", "queued", t.id],
        ]);
        const [counter, helper] = rows as [AgentRow, AgentRow];
        expect(runners.get(counter.id)!.alarm).toBe(0);
        expect((await json(call("/chat/threads", "GET"))).threads.map((x: any) => x.id)).toEqual([t.id]);
        let agents = await json(call(`/chat/threads/${t.id}/agents`, "GET"));
        expect(agents.agents.map((a: any) => [a.name, a.status, a.job])).toEqual([
            ["counter", "queued", `agent:${counter.id}`],
            ["helper 2", "queued", `agent:${helper.id}`],
        ]);
        // the parent's step cards show the helpers it started and the jobs it handed over
        const parentMsg = (await json(call(`/chat/threads/${t.id}`, "GET"))).messages[1];
        const calls = parentMsg.steps[0].calls;
        expect(calls.map((c: any) => c.op)).toEqual(["agents.spawn", "agents.spawn", "jobs.onDone", "jobs.onDone"]);
        expect(calls[0].card).toMatchObject({ type: "agents", change: "started", agents: [{ name: "counter", status: "queued" }] });
        expect(calls[2].card).toMatchObject({ type: "agents", change: "waiting", agents: [{ id: counter.id, watching: true }] });
        expect(parentMsg.steps.filter((s: any) => s.kind === "job")).toHaveLength(2);

        // the counter runs: done, with its report; its messages wait for the parent and for helper 2
        await tickAgent(counter.id);
        rows = agentRows();
        expect(rows[0]).toMatchObject({ status: "done", result: "12 videos in march", turns: 1, activity: null });
        agents = await json(call(`/chat/threads/${t.id}/agents`, "GET"));
        expect(agents.agents[1]).toMatchObject({ name: "helper 2", unread: 1 });
        expect(agents.mail.map((m: any) => [m.from_name, m.to_name, m.read])).toEqual([
            ["counter", "parent", false],
            ["counter", "helper 2", false],
        ]);
        // its own thread, read-only
        const own = await json(call(`/chat/threads/${counter.id}`, "GET"));
        expect(own.agent).toMatchObject({ id: counter.id, parent: t.id, name: "counter", status: "done" });
        expect(own.messages.map((m: any) => [m.role, m.text])).toEqual([
            ["user", "count the videos from march"],
            ["assistant", "12 videos in march"],
        ]);
        const write = await call(`/chat/threads/${counter.id}/messages`, "POST", { text: "hi" });
        expect(write.status).toBe(409);
        expect((await write.json()) as any).toMatchObject({ error: { code: "error.chat.agent_thread" } });

        // helper 2 runs: the counter's message reached it, a delete is refused (no card), it reports
        await tickAgent(helper.id);
        expect(agentRows()[1]).toMatchObject({ status: "done", result: "no cats here; the parent should delete AbCdEfGh12345678" });
        expect([...storage.keys()].filter((k) => k.startsWith("chat:pending:"))).toEqual([]);

        // the parent's watcher sees both ended: one continuation with both reports and the counter's message
        await jobs.tick();
        expect(scripts.get("parent")).toHaveLength(0);
        const thread = await json(call(`/chat/threads/${t.id}`, "GET"));
        expect(thread.messages.map((m: any) => m.text)).toEqual([
            "how many march videos, and any cats?",
            "two helpers are on it (=^･ω･^=)",
            "12 videos in march, and no cats (｡•̀ᴗ-)✧",
        ]);
        expect(thread.messages[1].steps.filter((s: any) => s.kind === "job").map((s: any) => s.job.status)).toEqual(["done", "done"]);
        agents = await json(call(`/chat/threads/${t.id}/agents`, "GET"));
        expect(agents.mail.every((m: any) => m.read)).toBe(true);

        // a message to a finished helper wakes it: a new reply answers it
        scripts.set("counter", [
            (s) => {
                expect(lastText(s)).toContain("and april?");
                expect(lastText(s)).toContain("from your parent");
                return say("9 in april");
            },
        ]);
        const sent = await toolbox(t.id)["agents.send"]!("counter", "and april?");
        expect(sent).toMatchObject({ to: counter.id, to_name: "counter", woke: true });
        expect(agentRows()[0]).toMatchObject({ status: "queued" });
        await tickAgent(counter.id);
        expect(agentRows()[0]).toMatchObject({ status: "done", result: "9 in april", turns: 2 });
        const got = await toolbox(t.id)["jobs.wait"]!(`agent:${counter.id}`, 0);
        expect(got).toMatchObject({ status: "done", result: "9 in april", name: "counter" });

        // deleting the parent deletes its helpers, their threads and mail
        expect((await call(`/chat/threads/${t.id}`, "DELETE")).status).toBe(200);
        expect(agentRows()).toEqual([]);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM chat_threads").get()).toEqual({ n: 0 });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM chat_agent_mail").get()).toEqual({ n: 0 });
    });

    it("a running helper reads new mail between its runs, and a stopped one ends after its step", async () => {
        const t = (await json(call("/chat/threads", "POST", {}))).thread;
        const a = await toolbox(t.id)["agents.spawn"]!("look through everything", { name: "slow" });
        scripts.set("slow", [
            () => {
                // the parent's message lands while this run goes
                db.raw.prepare("INSERT INTO chat_agent_mail (parent, sender, recipient, text, created_at) VALUES (?, 'parent', ?, 'only the videos please', ?)").run(t.id, a.agent, clock);
                return code("tu_1", "return 1;");
            },
            (s) => {
                const last = s.messages[s.messages.length - 1];
                expect(last.content.map((b: any) => b.type)).toEqual(["tool_result", "text"]);
                expect(last.content[1].text).toContain("only the videos please");
                // the parent stops it now
                db.raw.prepare("UPDATE chat_agents SET status = 'stopped' WHERE id = ?").run(a.agent);
                return code("tu_2", "return 2;");
            },
            // never reached: it was stopped
        ]);
        await tickAgent(a.agent);
        expect(scripts.get("slow")).toHaveLength(0);
        expect(agentRows()[0]).toMatchObject({ status: "stopped" });
        expect(await toolbox(t.id)["jobs.wait"]!(`agent:${a.agent}`, 0)).toMatchObject({ status: "cancelled" });
        expect(await thrown(toolbox(t.id)["agents.send"]!("slow", "hello?"))).toMatch(/was stopped/);
    });
});

describe("cobalt.agents rules", () => {
    let t: string;
    beforeEach(async () => {
        t = (await json(call("/chat/threads", "POST", {}))).thread.id;
    });

    it("at most 4 at once, names are unique, and the daily cap holds", async () => {
        const box = toolbox(t);
        for (let i = 0; i < 4; i++) await box["agents.spawn"]!(`task ${i}`);
        expect(agentRows().map((r) => r.name)).toEqual(["helper 1", "helper 2", "helper 3", "helper 4"]);
        expect(await thrown(box["agents.spawn"]!("one more"))).toMatch(/4 sub-agents are already working/);
        db.raw.prepare("UPDATE chat_agents SET status = 'done'").run();
        expect(await thrown(box["agents.spawn"]!("dup", { name: "Helper 1" }))).toMatch(/already exists/);
        env.CHAT_DAILY_AGENTS = "5";
        await box["agents.spawn"]!("five");
        expect(await thrown(box["agents.spawn"]!("six"))).toMatch(/already started 5 sub-agents today/);
        // the refused one took no unit
        expect((storage.get(`chat:budget:${t}:agents`) as any).n).toBe(5);
    });

    it("a sub-agent cannot start one, waits only on its siblings, and acts as its parent's key", async () => {
        const a = await toolbox(t)["agents.spawn"]!("a");
        const b = await toolbox(t)["agents.spawn"]!("b");
        const child = toolbox(a.agent, { id: a.agent, parent: t });
        expect(child["agents.spawn"]).toBeUndefined();
        expect(child["agents.stop"]).toBeUndefined();
        expect(await child["jobs.wait"]!(b.job, 0)).toMatchObject({ status: "queued", name: "helper 2" });
        // another chat's helper is not reachable
        const other = (await json(call("/chat/threads", "POST", {}))).thread.id;
        expect(await thrown(toolbox(other)["jobs.wait"]!(a.job, 0))).toMatch(/not one of this chat's sub-agents/);
        expect(await thrown(toolbox(other)["agents.get"]!("helper 1"))).toMatch(/no sub-agent "helper 1"/);
        // it talks to the parent and its sibling; "parent" from the parent is refused
        expect(await child["agents.send"]!("parent", "hi")).toMatchObject({ to: "parent", woke: false });
        expect(await child["agents.send"]!("helper 2", "hey")).toMatchObject({ to: b.agent, woke: false });
        expect(await thrown(toolbox(t)["agents.send"]!("parent", "me?"))).toMatch(/you are the parent/);
        expect(await toolbox(t)["agents.inbox"]!()).toMatchObject({ messages: [{ from_name: "helper 1", text: "hi", to: "parent" }] });
        expect(await toolbox(t)["agents.inbox"]!()).toEqual({ messages: [] });
        expect(await toolbox(t)["agents.list"]!()).toMatchObject({ agents: [{ unread: 0 }, { unread: 1 }], unread: 0 });
    });

    it("the oldest finished ones are dropped past the keep limit", () => {
        const row = (i: number, status: AgentRow["status"]): AgentRow =>
            ({ id: `id${i}`, parent: "p", name: `n${i}`, task: "t", status, result: null, post_ids: "[]", error: null, activity: null, turns: 0, created_at: i, updated_at: i, ended_at: null }) as AgentRow;
        const rows = Array.from({ length: AGENTS_KEPT_MAX }, (_, i) => row(i, i === 0 ? "running" : "done"));
        expect(agentsToDrop(rows)).toEqual(["id1"]);
        expect(agentsToDrop(rows.slice(1))).toEqual([]);
    });

    it("off without the binding, or with a cap of 0: no agents in the API", async () => {
        const flags = { search: false, agents: true };
        expect(toolTypes(false, REGISTRY, false, flags)).toContain("agents: {");
        expect(toolTypes(false, REGISTRY, false, {})).not.toContain("agents: {");
        expect(systemPrompt(0, false, toolTypes(false, REGISTRY, false, {}))).not.toContain("Sub-agents:");
        env.CHAT_DAILY_AGENTS = "0";
        expect(chatDepsFrom(base())!.agents).toBeNull();
        expect(await thrown(toolbox(t)["agents.list"]!())).toMatch(/sub-agents are off/);
    });

    it("MCP clients get the agent tools", () => {
        const names = mcpOps(REGISTRY, mcpFlags(base() as any)).map((o) => mcpToolName(o.callName));
        expect(names).toEqual(expect.arrayContaining(["agents_spawn", "agents_list", "agents_get", "agents_send", "agents_inbox", "agents_stop"]));
    });

    it("before migration 0027 the calls answer not ready, and the thread routes still work", async () => {
        db.raw.exec("DROP TABLE chat_agent_mail; DROP TABLE chat_agents;");
        expect(await thrown(toolbox(t)["agents.list"]!())).toMatch(/migration 0027/);
        expect((await json(call("/chat/threads", "GET"))).threads).toHaveLength(1);
        expect((await call(`/chat/threads/${t}`, "GET")).status).toBe(200);
        expect(await json(call(`/chat/threads/${t}/agents`, "GET"))).toEqual({ status: "success", agents: [], mail: [] });
        expect((await call(`/chat/threads/${t}`, "DELETE")).status).toBe(200);
    });
});
