// Agent swarms (APP-API-CONTRACT.md section 59): plan over HTTP (and as the chat), Harmony's approval (service or a device
// session only), the Swarm Durable Object's alarm running the tasks (SwarmRunnerCore for real on a Map, swarmTick with a
// scripted model and the real sandbox source), the review, and the deterministic apply. The real SQL runs on node:sqlite.
// The 7TV calls are stand-in ops under the real names, so the rules (allowlists, scope, ledger, throttle) run for real.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as z from "zod";
import { ALL_MIGRATIONS_SQL, createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import type { ChatModel, CodeRunner, ModelTurn } from "../src/chat";
import { sandboxModule } from "../src/chat-loader-module";
import { chatTools } from "../src/chat-tools";
import { hashKey } from "../src/keys";
import { mcpToolName } from "../src/mcp";
import { forCall } from "../src/registry/context";
import { chatToolbox, opBase, REGISTRY } from "../src/registry/index";
import { defineOp, ok, OpError } from "../src/registry/op";
import { waitJob } from "../src/registry/ops/make";
import { SWARM_OPS } from "../src/registry/ops/swarm";
import { Registry } from "../src/registry/registry";
import {
    EDIT_ARGS,
    Limiter,
    PLANS_ALL,
    PLANS_PER_KEY,
    UNKNOWN_WRITE,
    argsHash,
    checkProposals,
    swarmToolbox,
    unscopedWrites,
    SWARM_READ_OPS,
    SWARM_WRITE_OPS,
    SwarmRunnerCore,
    SwarmSpecSchema,
    checkSpec,
    clashesOf,
    estimateUsd,
    fillPrompt,
    handleSwarmRoute,
    positionalArgs,
    splitItems,
    swarmRunDeps,
    swarmTick,
    usdOf,
    type ChangeRow,
} from "../src/swarm";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const SESSION = "5e55e55e-6c1a-4f5e-9a57-1d0e6c9f2a22";
const SET = "01HSETAAAAAAAAAAAAAAAAAAAA";
const OTHER_SET = "01HSETBBBBBBBBBBBBBBBBBBBB";
const emoteId = (i: number) => `01HEMOTE${String(i).padStart(18, "0")}`;

let db: FakeD1;
let env: WorkerEnv;
let clock = 0;
let slept: number[];
let runners: Map<string, { core: SwarmRunnerCore; alarm: number | null }>;
let renames: { set_id: string; emote_id: string; alias: string; at: number }[];
// the scripted model: one queue per task index (from "batch <n> of"), and "reduce"
let scripts: Map<string, ((s: Seen) => ModelTurn)[]>;
let seen: (Seen & { who: string })[];
let modelFailures: string[];
type Seen = { system: string; messages: any[]; tools: any[] };

// ---- stand-ins for the 7TV calls, under their real names and inputs ------------------------------------------------------

const Id = /^[0-9A-Z]{20,32}$/;
const SetId = z.string().regex(Id);
const EmoteId = z.string().regex(Id);
const Alias = z.string().trim().min(1).max(100).regex(/^\S+$/, "no spaces");
const SET_EMOTES = Array.from({ length: 130 }, (_, i) => ({ id: emoteId(i), name: `emote_${i}` }));

const fakeOps = [
    defineOp({
        name: "seventv.set",
        auth: "key",
        runs: "worker",
        cors: false,
        input: z.object({ set_id: SetId, query: z.string().optional(), page: z.number().int().min(1).optional() }),
        ai: { tier: "free", only: true, summary: "One 7TV emote set and a page (60) of its emotes.", params: ["set_id"], options: true },
        handler: async (_ctx, input) => {
            const page = input.page ?? 1;
            const emotes = SET_EMOTES.slice((page - 1) * 60, page * 60);
            return ok({ set: { id: input.set_id }, page, has_more: page * 60 < SET_EMOTES.length, emotes });
        },
    }),
    defineOp({
        name: "seventv.emote",
        auth: "key",
        runs: "worker",
        cors: false,
        input: z.object({ emote_id: EmoteId }),
        ai: { tier: "free", only: true, summary: "One 7TV emote.", params: ["emote_id"] },
        handler: async (_ctx, input) => ok({ id: input.emote_id, name: `emote of ${input.emote_id.slice(-3)}` }),
    }),
    defineOp({
        name: "seventv.rename",
        auth: "key",
        runs: "worker",
        cors: false,
        input: z.object({ set_id: SetId, emote_id: EmoteId, alias: Alias, from: z.string().optional() }),
        ai: { tier: "ask", only: true, summary: "Rename an emote inside one 7TV emote set. Asks Harmony first.", params: ["set_id", "emote_id", "alias"], options: true },
        handler: async (_ctx, input) => {
            if (input.alias === "taken") throw new OpError(409, "error.seventv.name_taken", "that name is already in the set");
            renames.push({ ...input, at: clock });
            return ok({ set_id: input.set_id, emote_id: input.emote_id, alias: input.alias });
        },
    }),
    defineOp({
        name: "seventv.remove",
        auth: "key",
        runs: "worker",
        cors: false,
        input: z.object({ set_id: SetId, emote_id: EmoteId }),
        ai: { tier: "ask", only: true, summary: "Remove an emote from a 7TV emote set. Asks Harmony first.", params: ["set_id", "emote_id"], options: true },
        handler: async () => ok({ removed: true }),
    }),
];
// the registry of this world: the swarm ops, the stand-ins, and jobs.wait (job ids)
const REG = new Registry([...SWARM_OPS, ...fakeOps, REGISTRY.op("jobs.wait")!]);

// ---- the world ------------------------------------------------------------------------------------------------------------

const container = {
    async fetch(): Promise<Response> {
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

const USAGE = { input_tokens: 10_000, output_tokens: 1000 }; // $0.0015 a turn
const say = (text: string, usage = USAGE): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn", usage });
const code = (id: string, src: string, usage = USAGE): ModelTurn => ({ content: [{ type: "tool_use", id, name: "run_code", input: { code: src } }], stop_reason: "tool_use", usage });
const lastResult = (s: Seen) => JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);

const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, tools }) {
        const fail = modelFailures.shift();
        if (fail) throw new Error(fail);
        const who = /^You summarise/.test(system) ? "reduce" : (/you see only batch (\d+) of/.exec(system)?.[1] ?? "?");
        const s = { system, messages: JSON.parse(JSON.stringify(messages)), tools, who };
        seen.push(s);
        const next = scripts.get(who)?.shift();
        if (!next) throw new Error(`no script left for ${who}`);
        return next(s);
    },
    async title() {
        return null;
    },
};

const sleep = async (ms: number) => {
    slept.push(ms);
    clock += ms;
};
const edge = () => ({ now: () => clock, sleep, chatModel: model, codeRunner: runner });
const base = () => opBase(env, container, edge(), REG);

const req = (path: string, method: string, headers: Record<string, string>, body?: unknown) =>
    handleRequest(
        new Request(`${API}${path}`, { method, headers: { ...headers, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }),
        env,
        container,
        { ...edge(), registry: REG },
    );
const KEY = { authorization: `Api-Key ${CLIENT}` };
const SESS = { authorization: `Api-Key ${SESSION}` };
const SERVICE = { "x-cobalt-service": INTERNAL };
const json = async (r: Response | Promise<Response>) => {
    const res = await r;
    return { status: res.status, body: (await res.json()) as any };
};

// The shared fake runs a batch as BEGIN ... COMMIT around awaited statements, so two batches at once (two tasks ending
// together) would nest; the real binding runs them side by side. Queue them.
function serialBatches(d: FakeD1): FakeD1 {
    const batch = (d as any).batch.bind(d);
    let chain: Promise<unknown> = Promise.resolve();
    (d as any).batch = (stmts: unknown[]) => {
        const p = chain.then(() => batch(stmts));
        chain = p.catch(() => {});
        return p;
    };
    return d;
}

// One alarm of a swarm's Durable Object.
async function tick(id: string) {
    const r = runners.get(id);
    if (!r) throw new Error(`no runner for ${id}`);
    r.alarm = null;
    await r.core.tick();
}
// Alarms until it has none left.
async function drain(id: string, max = 20) {
    for (let i = 0; i < max && runners.get(id)?.alarm !== null; i++) await tick(id);
}

const row = (id: string) => db.raw.prepare("SELECT * FROM swarms WHERE id = ?").get(id) as any;
const tasks = (id: string) => db.raw.prepare("SELECT * FROM swarm_tasks WHERE swarm = ? ORDER BY idx").all(id) as any[];

const SPEC = (over: Record<string, unknown> = {}) => ({
    name: "tidy emote names",
    items: SET_EMOTES.slice(0, 4).map((e) => ({ emote_id: e.id, name: e.name })),
    batch: { size: 2 },
    prompt: "Batch {{index}} of {{total}} ({{count}}) for {{name}}:\n{{items}}\nSuggest a clean name for each.",
    tools: ["seventv.emote"],
    writes: ["seventv.rename"],
    scope: { set_id: [SET] },
    ...over,
});
const rename = (i: number, alias: string, set = SET) => ({
    op: "seventv.rename",
    args: { set_id: set, emote_id: emoteId(i), alias },
    target: `emote_${i}`,
    before: `emote_${i}`,
    after: alias,
    edit_arg: "alias",
    preview_url: `https://cdn.7tv.app/emote/${emoteId(i)}/2x.webp`,
});

async function plan(spec: Record<string, unknown> = SPEC(), headers = KEY) {
    const r = await json(req("/swarms", "POST", headers, spec));
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body;
}
async function approve(id: string, hash: string, headers: Record<string, string> = SERVICE) {
    return json(req(`/swarms/${id}/approve`, "POST", headers, { spec_hash: hash }));
}

function freshEnv(withSwarms = true) {
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        ANTHROPIC_API_KEY: "test",
    } as WorkerEnv;
    if (!withSwarms) return;
    env.SWARMS = {
        idFromName: (n: string) => n,
        get: (id: string) => ({
            fetch: (r: Request) => {
                let entry = runners.get(id);
                if (!entry) {
                    const store = new Map<string, unknown>();
                    const e: { core: SwarmRunnerCore; alarm: number | null } = { core: null as any, alarm: null };
                    e.core = new SwarmRunnerCore({
                        storage: { get: async <T,>(k: string) => store.get(k) as T | undefined, put: async (k, v) => void store.set(k, v) },
                        setAlarm: async (ms) => void (e.alarm = ms),
                        tick: (sid) => swarmTick(swarmRunDeps(base(), model, sleep), sid),
                    });
                    runners.set(id, e);
                    entry = e;
                }
                return handleSwarmRoute(entry.core, r, INTERNAL);
            },
        }),
    } as unknown as DurableObjectNamespace;
}

// D1's limits, which node:sqlite does not have: 100 bound params a statement (and batches kept small here).
function d1Limits(d: FakeD1): FakeD1 {
    const prepare = (d as any).prepare.bind(d);
    (d as any).prepare = (sql: string) => {
        const st = prepare(sql);
        const bind = st.bind.bind(st);
        st.bind = (...p: unknown[]) => {
            if (p.length > 100) throw new Error(`D1_ERROR: too many SQL variables (${p.length})`);
            return bind(...p);
        };
        return st;
    };
    const batch = (d as any).batch.bind(d);
    (d as any).batch = (stmts: unknown[]) => {
        if (stmts.length > 100) throw new Error(`test: a batch of ${stmts.length} statements`);
        return batch(stmts);
    };
    return d;
}

beforeEach(async () => {
    db = serialBatches(d1Limits(withBatch(createFakeD1())));
    const now = 1_800_000_000_000;
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent key", await hashKey(CLIENT), "0b5f2c3e", 1);
    db.raw
        .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at, kind, device, platform, expires_at) VALUES (?, ?, ?, ?, ?, 'session', 'phone', 'ios', ?)")
        .run("sess-1", "phone", await hashKey(SESSION), "5e55e55e", 1, now + 90 * 86_400_000);
    clock = now;
    slept = [];
    runners = new Map();
    renames = [];
    scripts = new Map();
    seen = [];
    modelFailures = [];
    freshEnv();
});

// ---- the program's rules -------------------------------------------------------------------------------------------------

describe("the program", () => {
    const check = (over: Record<string, unknown>) => () => checkSpec(SwarmSpecSchema.parse(SPEC(over)), REGISTRY, {});
    const refused = (over: Record<string, unknown>, why: RegExp) => expect(check(over)).toThrow(why);

    it("fills in the defaults and keeps the items out of the stored program", () => {
        const s = checkSpec(SwarmSpecSchema.parse(SPEC({ batch: undefined })), REGISTRY, {});
        expect(s).toMatchObject({ mode: "propose", batch_size: 50, concurrency: 5, cap_usd: 1, turns: 6, attempts: 2, stop_after: 5, output: null, reduce: null });
        expect(s).not.toHaveProperty("items");
    });

    it("refuses what the rules do not allow", () => {
        refused({ source: { call: "seventv.set", args: { set_id: SET } } }, /items or source/);
        refused({ items: undefined }, /items or source/);
        refused({ tools: ["library.delete"] }, /not a swarm read call/);
        refused({ tools: ["box.run"] }, /not a swarm read call/);
        refused({ writes: ["library.delete"] }, /not a swarm write/);
        refused({ writes: ["make.webp"] }, /not a swarm write/);
        refused({ writes: [], scope: undefined }, /propose mode needs writes/);
        refused({ mode: "act", writes: [], scope: undefined }, /act mode needs writes/);
        refused({ mode: "read" }, /read mode has no writes/);
        refused({ prompt: "no items here" }, /must contain \{\{items\}\}/);
        refused({ prompt: "{{items}} {{secret}}" }, /\{\{secret\}\} is not a placeholder/);
        refused({ output: { schema: { type: "object" } } }, /output.schema is for read and act/);
        refused({ budget: { usd: 11 } }, /at most 10/);
        expect(() => checkSpec(SwarmSpecSchema.parse(SPEC({ budget: { usd: 11 } })), REGISTRY, { SWARM_MAX_USD: "20" })).not.toThrow();
        expect(() => SwarmSpecSchema.parse(SPEC({ budget: { usd: 0.01 } }))).toThrow();
        expect(() => SwarmSpecSchema.parse(SPEC({ concurrency: 9 }))).toThrow();
        expect(() => SwarmSpecSchema.parse(SPEC({ budget: { turns_per_task: 11 } }))).toThrow();
        expect(() => SwarmSpecSchema.parse(SPEC({ prompt: `{{items}}${"x".repeat(8000)}` }))).toThrow();
    });

    it("splits into at most 200 tasks of at most 5000 items", () => {
        expect(splitItems([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
        expect(() => splitItems(Array.from({ length: 201 }, (_, i) => i), 1)).toThrow(/201 tasks: at most 200/);
        expect(() => splitItems(Array.from({ length: 5001 }, (_, i) => i), 200)).toThrow(/at most 5000 items/);
        expect(() => splitItems(["x".repeat(600_000)], 1)).toThrow(/512 KB/);
        expect(() => splitItems([], 1)).toThrow(/no items/);
    });

    it("fills only its placeholders", () => {
        expect(fillPrompt("{{name}}: {{index}}/{{total}} has {{count}}: {{items}} {{other}}", { items: [1, "a"], index: 2, total: 3, name: "n" })).toBe('n: 2/3 has 2: [1,"a"] {{other}}');
    });

    it("prices Haiku 5.5 and estimates a range: half to all", () => {
        expect(usdOf({ input_tokens: 10_000, output_tokens: 10_000, cache_read_input_tokens: 10_000, cache_creation_input_tokens: 10_000 })).toBeCloseTo((0.1 + 0.5 + 0.01 + 0.125) / 100, 8);
        const spec = { turns: 6, reduce: null, prompt: "{{items}}" };
        const batches = splitItems(Array.from({ length: 1000 }, (_, i) => ({ id: emoteId(i), name: `emote_${i}` })), 50);
        const e = estimateUsd(spec, batches, 6000);
        expect(e.low).toBeCloseTo(e.high / 2, 3);
        // the plan's ballpark: 1000 emotes in 20 tasks is cents, not dollars
        expect(e.high).toBeGreaterThan(0.1);
        expect(e.high).toBeLessThan(1);
        expect(estimateUsd({ ...spec, reduce: { prompt: "sum up" } }, batches, 6000).high).toBeGreaterThan(e.high);
    });

    it("its read and write calls are real, offered, positional ops: no deletes, makes, box, saves, links or agents", () => {
        for (const name of [...SWARM_READ_OPS, ...SWARM_WRITE_OPS]) {
            const op = REGISTRY.op(name);
            expect(op, name).toBeDefined();
            expect(op!.ai.tier, name).not.toBe("hidden");
            if (SWARM_WRITE_OPS.includes(name)) expect(op!.ai.args, name).toBeUndefined();
            expect(name).not.toMatch(/delete|^make\.|^box\.|save|^links\.create|^agents\./);
        }
        for (const name of SWARM_WRITE_OPS) expect(SWARM_READ_OPS).not.toContain(name);
        const op = REGISTRY.op("seventv.rename")!;
        expect(positionalArgs(op, { set_id: "s", emote_id: "e", alias: "a", from: "b" })).toEqual(["s", "e", "a", { from: "b" }]);
    });

    it("clashes: two kept changes taking one name in one set, the same change twice, args that no longer pass", () => {
        const spec = { writes: ["seventv.rename"], scope: { set_id: [SET, OTHER_SET] } };
        const r = (n: number, alias: string, set = SET, keep = 1): ChangeRow =>
            ({ swarm: "s", n, task: 0, op: "seventv.rename", args: JSON.stringify({ set_id: set, emote_id: emoteId(n), alias }), after: alias, keep }) as ChangeRow;
        const c = clashesOf(REG, spec, [r(1, "Cat"), r(2, "cat"), r(3, "cat", OTHER_SET), r(4, "dog"), r(5, "dog", SET, 0), r(6, "has space"), { ...r(7, "x"), args: r(1, "Cat").args }]);
        expect(c.get(1)).toMatch(/duplicate name: also proposed by #2/);
        expect(c.get(2)).toMatch(/duplicate name/);
        expect(c.get(3)).toBeNull();
        expect(c.get(4)).toBeNull();
        expect(c.get(5)).toBeNull();
        expect(c.get(6)).toMatch(/^invalid: alias: no spaces/);
        expect(c.get(7)).toMatch(/duplicate: the same change as #1/);
    });
});

// ---- plan and approve -----------------------------------------------------------------------------------------------------

describe("planning and approval", () => {
    it("a key plans: nothing runs, the shape has the estimate, the hash and the approve link", async () => {
        const s = await plan();
        expect(s).toMatchObject({
            name: "tidy emote names",
            mode: "propose",
            status: "awaiting_approval",
            items: 4,
            batch_size: 2,
            concurrency: 5,
            tools: ["seventv.emote"],
            writes: ["seventv.rename"],
            scope: { set_id: [SET] },
            cap_usd: 1,
            spent_usd: 0,
            approved_at: null,
            expires_at: clock + 3_600_000,
            changes: { total: 0, kept: 0, done: 0, failed: 0 },
            apply: { status: "none", done: 0, failed: 0, total: 0 },
            approve_url: `${WEB}/swarms/${s.swarm}`,
            job: `swarm:${s.swarm}`,
        });
        expect(s.swarm).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(s.spec_hash).toMatch(/^[0-9a-f]{64}$/);
        expect(s.tasks).toMatchObject({ total: 2, queued: 2, running: 0, done: 0, failed: 0 });
        expect(s.estimate_usd.high).toBeGreaterThan(0);
        expect(seen).toHaveLength(0);
        expect(runners.size).toBe(0);
        // the agent sees its own swarms, the service and sessions every swarm
        expect((await json(req("/swarms", "GET", KEY))).body.swarms).toHaveLength(1);
        expect((await json(req("/swarms", "GET", SERVICE))).body.swarms).toHaveLength(1);
        expect((await json(req(`/swarms/${s.swarm}`, "GET", SESS))).body.swarm).toBe(s.swarm);
    });

    it("a bad program is 400 error.swarm.bad_spec", async () => {
        const r = await json(req("/swarms", "POST", KEY, SPEC({ tools: ["library.delete"] })));
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.swarm.bad_spec" } } });
        expect((await json(req("/swarms", "POST", KEY, { name: "x" }))).body.error.code).toBe("error.swarm.bad_spec");
    });

    it("source: a read call runs at plan time and its pages are followed", async () => {
        const s = await plan(SPEC({ items: undefined, source: { call: "seventv.set", args: { set_id: SET }, path: "emotes" }, batch: { size: 50 } }));
        expect(s.items).toBe(130);
        expect(s.tasks.total).toBe(3);
        const first = JSON.parse(tasks(s.swarm)[0].items);
        expect(first[0]).toEqual({ id: emoteId(0), name: "emote_0" });
        const bad = await json(req("/swarms", "POST", KEY, SPEC({ items: undefined, source: { call: "seventv.set", args: { set_id: SET }, path: "nope" } })));
        expect(bad.status).toBe(400);
    });

    it("only Harmony approves: never a client key, the chat or the MCP; the hash must match", async () => {
        const s = await plan();
        expect((await approve(s.swarm, s.spec_hash, KEY)).body.error.code).toBe("error.swarm.owner_only");
        expect((await approve(s.swarm, s.spec_hash, KEY)).status).toBe(403);
        // as the chat or the MCP: not even offered (hidden), and refused if reached
        const collect = { look: [], show: [], collage: null };
        const tools = chatToolbox(REG, base(), { threadId: "AbCdEfGh12345678", messageId: null, collect, legacy: chatTools({ db, mediaBaseUrl: MEDIA, embed: null }, collect), flags: { search: false, mcp: true }, pending: null }).tools;
        expect(Object.keys(tools).filter((k) => k.startsWith("swarm."))).toEqual(["swarm.plan", "swarm.list", "swarm.get", "swarm.results", "swarm.changes", "swarm.stop", "swarm.retry"]);
        expect(["swarm.plan", "swarm.get"].map(mcpToolName)).toEqual(["swarm_plan", "swarm_get"]);
        const chatCtx = forCall(base(), { keyId: "chat:AbCdEfGh12345678", caller: "chat", chat: { threadId: "AbCdEfGh12345678", collect, tools: {}, mcp: { origin: API, clientKeyId: "sess-1" } } });
        await expect(REG.op("swarm.approve")!.handler!(chatCtx, { id: s.swarm, spec_hash: s.spec_hash })).rejects.toMatchObject({ code: "error.swarm.owner_only" });
        expect((await approve(s.swarm, "0".repeat(64))).body.error.code).toBe("error.swarm.hash_mismatch");
        // a device session may
        const ok = await approve(s.swarm, s.spec_hash, SESS);
        expect(ok.status).toBe(200);
        expect(ok.body).toMatchObject({ status: "running", expires_at: null });
        expect(row(s.swarm).approved_by).toBe("sess-1");
        expect(runners.get(s.swarm)?.alarm).toBe(0);
        // an approval is not reused
        expect((await approve(s.swarm, s.spec_hash)).body.error.code).toBe("error.swarm.not_awaiting");
    });

    it("decline: nothing runs; a plan expires after an hour", async () => {
        const a = await plan();
        const d = await json(req(`/swarms/${a.swarm}/decline`, "POST", SERVICE, {}));
        expect(d.body.status).toBe("declined");
        expect((await approve(a.swarm, a.spec_hash)).body.error.code).toBe("error.swarm.not_awaiting");
        const b = await plan();
        clock += 3_600_001;
        expect((await json(req(`/swarms/${b.swarm}`, "GET", KEY))).body.status).toBe("expired");
        const late = await approve(b.swarm, b.spec_hash);
        expect(late).toEqual({ status: 410, body: { status: "error", error: { code: "error.swarm.expired" } } });
    });

    it("limits: 10 waiting plans per key, 1 running per key, 2 overall, the day's dollars", async () => {
        const first = await plan();
        for (let i = 1; i < PLANS_PER_KEY; i++) await plan();
        expect((await json(req("/swarms", "POST", KEY, SPEC()))).body.error.code).toBe("error.swarm.busy");
        expect((await approve(first.swarm, first.spec_hash)).status).toBe(200);
        const list = (await json(req("/swarms", "GET", KEY))).body.swarms;
        const second = list.find((s: any) => s.status === "awaiting_approval");
        expect((await approve(second.swarm, second.spec_hash)).body.error.code).toBe("error.swarm.busy");
        // another key's swarm may run beside it; a third may not
        db.raw.prepare("UPDATE swarms SET key_id = 'other' WHERE id = ?").run(second.swarm);
        expect((await approve(second.swarm, second.spec_hash)).status).toBe(200);
        const third = list.filter((s: any) => s.status === "awaiting_approval")[1];
        db.raw.prepare("UPDATE swarms SET key_id = 'third' WHERE id = ?").run(third.swarm);
        expect((await approve(third.swarm, third.spec_hash)).body.error.code).toBe("error.swarm.busy");
        db.raw.prepare("UPDATE swarms SET status = 'done' WHERE id IN (?, ?)").run(first.swarm, second.swarm);
        db.raw.prepare("INSERT INTO swarm_spend (day, usd) VALUES (?, 5)").run(new Date(clock).toISOString().slice(0, 10));
        expect((await approve(third.swarm, third.spec_hash)).body.error.code).toBe("error.swarm.daily_cap");
    });

    it("plans still work without the binding; approving them is 503 error.swarm.off", async () => {
        freshEnv(false);
        const s = await plan();
        expect(await approve(s.swarm, s.spec_hash)).toEqual({ status: 503, body: { status: "error", error: { code: "error.swarm.off" } } });
        freshEnv(true);
        env.ANTHROPIC_API_KEY = "";
        expect((await approve(s.swarm, s.spec_hash)).body.error.code).toBe("error.swarm.off");
    });

    it("before migration 0043 every call is 503 error.swarm.not_ready", async () => {
        db = serialBatches(withBatch(createFakeD1(ALL_MIGRATIONS_SQL.split("CREATE TABLE swarms")[0]!)));
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent key", await hashKey(CLIENT), "0b5f2c3e", 1);
        freshEnv();
        for (const [path, method, body] of [
            ["/swarms", "POST", SPEC()],
            ["/swarms", "GET", undefined],
            ["/swarms/AbCdEfGh12345678", "GET", undefined],
        ] as const) {
            expect(await json(req(path, method, KEY, body))).toEqual({ status: 503, body: { status: "error", error: { code: "error.swarm.not_ready" } } });
        }
        expect((await json(req("/swarms/AbCdEfGh12345678/approve", "POST", SERVICE, { spec_hash: "x" }))).body.error.code).toBe("error.swarm.not_ready");
    });

    it("a sub-agent cannot plan a swarm", async () => {
        const collect = { look: [], show: [], collage: null };
        const tools = chatToolbox(REG, base(), {
            threadId: "AbCdEfGh12345678",
            messageId: null,
            collect,
            legacy: {},
            flags: { search: false, subagent: true },
            pending: null,
            agent: { id: "AbCdEfGh12345678", parent: "ZyXwVuTs98765432" },
        }).tools;
        expect(tools["swarm.plan"]).toBeUndefined();
        expect(tools["swarm.retry"]).toBeUndefined();
        expect(tools["swarm.get"]).toBeDefined();
    });
});

// ---- running ------------------------------------------------------------------------------------------------------------

describe("a propose swarm, end to end", () => {
    it("runs its tasks in the alarm, reviews, and applies the kept changes once, a second apart", async () => {
        const s = await plan(SPEC({ concurrency: 2 }));
        // batch 1: reads an emote with its only tool, then proposes two renames
        scripts.set("1", [
            (x) => {
                expect(x.system).toContain('you see only batch 1 of 2');
                expect(x.system).toContain("seventv: {");
                expect(x.system).toContain("emote(emote_id: string)");
                expect(x.system).not.toMatch(/^\s*set\(/m);
                expect(x.system).toContain("(for proposals only: they are not in cobalt)");
                expect(x.system).toMatch(/- seventv.rename: Rename an emote inside one 7TV emote set. args: \{"type":"object","properties":\{"set_id"/);
                expect(x.system).not.toMatch(/Asks Harmony first|pending_confirm/);
                expect(x.messages[0].content).toContain('Batch 1 of 2 (2) for tidy emote names:\n[{"emote_id"');
                return code("tu_1", `const a = await cobalt.seventv.emote("${emoteId(0)}"); let e; try { await cobalt.seventv.rename("${SET}", "${emoteId(0)}", "x"); } catch (err) { e = err.message } let d; try { await cobalt.library.delete("x") } catch (err) { d = err.message } return { a, e, d };`);
            },
            (x) => {
                const r = lastResult(x);
                expect(r.result.a.name).toBe("emote of 000");
                expect(r.result.e).toMatch(/does not exist/);
                expect(r.result.d).toMatch(/does not exist/);
                return say(JSON.stringify({ changes: [rename(0, "Cat"), rename(1, "dog")] }));
            },
        ]);
        // batch 2: a bad answer, one repair turn, then a change that clashes with batch 1's
        scripts.set("2", [
            () => say("Here you go: renames!"),
            (x) => {
                expect(x.messages[x.messages.length - 1].content).toMatch(/did not match: it is not JSON/);
                return say("```json\n" + JSON.stringify({ changes: [rename(2, "cat"), rename(3, "Bird")] }) + "\n```");
            },
        ]);
        expect((await approve(s.swarm, s.spec_hash)).status).toBe(200);
        await drain(s.swarm);
        const got = (await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body;
        expect(got).toMatchObject({ status: "done", error: null, changes: { total: 4, kept: 4, done: 0, failed: 0 }, apply: { status: "ready", total: 4 } });
        expect(got.tasks).toMatchObject({ total: 2, done: 2, failed: 0 });
        expect(got.spent_usd).toBeCloseTo(4 * usdOf(USAGE), 6);
        expect(tasks(s.swarm).map((t) => [t.attempts, t.in_tokens, t.out_tokens])).toEqual([
            [1, 20_000, 2000],
            [1, 20_000, 2000],
        ]);
        const results = (await json(req(`/swarms/${s.swarm}/results?offset=0&limit=100`, "GET", KEY))).body;
        expect(results).toMatchObject({ total: 2, offset: 0, results: [{ task: 0, status: "done", result: { changes: 2 }, error: null }, { task: 1, status: "done" }] });
        const changes = (await json(req(`/swarms/${s.swarm}/changes`, "GET", KEY))).body;
        expect(changes.total).toBe(4);
        expect(changes.changes.map((c: any) => [c.task, c.after, c.keep, c.status, c.clash === null])).toEqual([
            [0, "Cat", true, "proposed", false],
            [0, "dog", true, "proposed", true],
            [1, "cat", true, "proposed", false],
            [1, "Bird", true, "proposed", true],
        ]);
        expect(changes.changes[0]).toMatchObject({ op: "seventv.rename", args: { set_id: SET, emote_id: emoteId(0), alias: "Cat" }, edit_arg: "alias", target: "emote_0", preview_url: `https://cdn.7tv.app/emote/${emoteId(0)}/2x.webp` });
        // nothing was written while the tasks ran
        expect(renames).toEqual([]);

        // the review: a client key may not; Harmony unticks one, renames another (its args follow), one will fail on 7TV
        const nOf = (after: string) => changes.changes.find((c: any) => c.after === after).n;
        const decide = { changes: [{ n: nOf("cat"), after: "kitty" }, { n: nOf("dog"), keep: false }, { n: nOf("Bird"), after: "taken" }] };
        expect((await json(req(`/swarms/${s.swarm}/changes`, "POST", KEY, decide))).body.error.code).toBe("error.swarm.owner_only");
        const decided = (await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, decide))).body;
        expect(decided.swarm.changes).toMatchObject({ total: 4, kept: 3 });
        const kitty = decided.changes.find((c: any) => c.after === "kitty");
        expect(kitty).toMatchObject({ args: { alias: "kitty" }, clash: null });
        expect((await json(req(`/swarms/${s.swarm}/changes`, "GET", KEY))).body.changes[0].clash).toBeNull();

        // apply: Harmony only, bound to the hash
        expect((await json(req(`/swarms/${s.swarm}/apply`, "POST", KEY, { spec_hash: s.spec_hash }))).body.error.code).toBe("error.swarm.owner_only");
        expect((await json(req(`/swarms/${s.swarm}/apply`, "POST", SESS, { spec_hash: "nope" }))).body.error.code).toBe("error.swarm.hash_mismatch");
        const applying = (await json(req(`/swarms/${s.swarm}/apply`, "POST", SESS, { spec_hash: s.spec_hash }))).body;
        expect(applying.apply.status).toBe("applying");
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Cat", "kitty"]);
        expect(renames[1]!.at - renames[0]!.at).toBeGreaterThanOrEqual(1000);
        const after = (await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body;
        expect(after.apply).toEqual({ status: "failed", done: 2, failed: 1, total: 3 });
        const rows = (await json(req(`/swarms/${s.swarm}/changes`, "GET", KEY))).body.changes;
        expect(rows.find((c: any) => c.after === "taken")).toMatchObject({ status: "failed", error: expect.stringMatching(/already in the set/) });
        expect(rows.find((c: any) => c.after === "dog")).toMatchObject({ keep: false, status: "proposed" });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM swarm_writes WHERE swarm = ?").get(s.swarm)).toEqual({ n: 2 });

        // applying again retries the failed one only; the ledger keeps the done ones from running twice
        await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: nOf("Bird"), after: "bird" }] }));
        db.raw.prepare("UPDATE swarm_changes SET status = 'proposed' WHERE swarm = ? AND after = 'Cat'").run(s.swarm);
        await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Cat", "kitty", "bird"]);
        expect((await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body.apply).toEqual({ status: "applied", done: 3, failed: 0, total: 3 });
        expect((await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }))).body.error.code).toBe("error.swarm.not_awaiting");
    });
});

describe("the runner's rules", () => {
    it("the dollar cap is checked before every model call: the rest is skipped and the swarm stops", async () => {
        const s = await plan(SPEC({ concurrency: 1, budget: { usd: 0.05 } }));
        const big = { input_tokens: 90_000, output_tokens: 102_000 }; // $0.06
        scripts.set("1", [() => say(JSON.stringify({ changes: [] }), big)]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        const got = (await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body;
        expect(got).toMatchObject({ status: "stopped", error: "error.swarm.over_cap" });
        expect(got.tasks.cells.map((c: any) => [c.status, c.error])).toEqual([
            ["done", null],
            ["skipped", "error.swarm.over_cap"],
        ]);
        expect(got.spent_usd).toBeCloseTo(0.009 + 0.051, 6);
    });

    it("the day's cap stops a swarm too", async () => {
        const s = await plan(SPEC({ concurrency: 1, budget: { usd: 10 } }));
        scripts.set("1", [() => say(JSON.stringify({ changes: [] }), { input_tokens: 0, output_tokens: 12_000_000 })]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        expect(row(s.swarm)).toMatchObject({ status: "stopped", error: "error.swarm.daily_cap" });
    });

    it("a model 429 or overload is tried again with backoff, without counting an attempt", async () => {
        const s = await plan(SPEC({ items: [{ id: 1 }], batch: { size: 1 } }));
        modelFailures = ["429 rate_limit_error", "529 overloaded_error"];
        scripts.set("1", [() => say(JSON.stringify({ changes: [] }))]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        expect(slept.slice(0, 2)).toEqual([2000, 8000]);
        expect(tasks(s.swarm)[0]).toMatchObject({ status: "done", attempts: 1 });
    });

    it("a bad answer gets one repair turn, then the attempt fails; attempts run out; too many failures fail the swarm", async () => {
        const s = await plan(SPEC({ concurrency: 1, retry: { attempts: 2, stop_after_failed_tasks: 1 } }));
        const bad = () => say(JSON.stringify({ changes: [rename(0, "has space")] }));
        const outside = () => say(JSON.stringify({ changes: [rename(0, "ok", OTHER_SET)] }));
        scripts.set("1", [bad, bad, outside, (x) => (expect(x.messages.at(-1).content).toMatch(/outside this swarm's scope/), outside())]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        const got = (await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body;
        expect(got).toMatchObject({ status: "failed", error: "error.swarm.too_many_failed" });
        expect(tasks(s.swarm).map((t) => [t.status, t.attempts])).toEqual([
            ["failed", 2],
            ["skipped", 0],
        ]);
        expect(tasks(s.swarm)[0].error).toMatch(/^error.swarm.bad_answer: changes\[0\]: set_id .* outside this swarm's scope/);
        // retry: back to Harmony with a new hash; the old approval does not match
        const again = (await json(req(`/swarms/${s.swarm}/retry`, "POST", KEY, {}))).body;
        expect(again).toMatchObject({ status: "awaiting_approval", error: null, tasks: { queued: 2, failed: 0 } });
        expect(again.spec_hash).not.toBe(s.spec_hash);
        expect((await approve(s.swarm, s.spec_hash)).body.error.code).toBe("error.swarm.hash_mismatch");
        scripts.set("1", [() => say(JSON.stringify({ changes: [] }))]);
        scripts.set("2", [() => say(JSON.stringify({ changes: [rename(3, "Bird")] }))]);
        expect((await approve(s.swarm, again.spec_hash)).status).toBe(200);
        await drain(s.swarm);
        expect(row(s.swarm)).toMatchObject({ status: "done", apply_status: "ready", round: 2 });
    });

    it("stop: no new tasks start, the swarm ends stopped", async () => {
        const s = await plan(SPEC({ concurrency: 1 }));
        scripts.set("1", [
            () => say(JSON.stringify({ changes: [] })),
        ]);
        await approve(s.swarm, s.spec_hash);
        const stopped = (await json(req(`/swarms/${s.swarm}/stop`, "POST", KEY, {}))).body;
        expect(stopped.status).toBe("stopping");
        await drain(s.swarm);
        expect(row(s.swarm)).toMatchObject({ status: "stopped", error: null });
        expect(tasks(s.swarm).map((t) => t.status)).toEqual(["skipped", "skipped"]);
        expect(seen).toHaveLength(0);
    });

    it("the watchdog queues a task with a stale heartbeat again once, then fails it", async () => {
        const s = await plan(SPEC({ concurrency: 1, items: [{ id: 1 }], batch: { size: 1 } }));
        await approve(s.swarm, s.spec_hash);
        db.raw.prepare("UPDATE swarm_tasks SET status = 'running', attempts = 1, heartbeat_at = ? WHERE swarm = ?").run(clock - 6 * 60_000, s.swarm);
        scripts.set("1", [() => say(JSON.stringify({ changes: [] }))]);
        await tick(s.swarm);
        expect(tasks(s.swarm)[0]).toMatchObject({ status: "done", requeues: 1 });
        // a second stall of the same task fails it
        const t = await plan(SPEC({ concurrency: 1, items: [{ id: 1 }], batch: { size: 1 } }));
        db.raw.prepare("UPDATE swarms SET status = 'done' WHERE id = ?").run(s.swarm);
        await approve(t.swarm, t.spec_hash);
        db.raw.prepare("UPDATE swarm_tasks SET status = 'running', attempts = 1, requeues = 1, heartbeat_at = ? WHERE swarm = ?").run(clock - 6 * 60_000, t.swarm);
        await tick(t.swarm);
        expect(tasks(t.swarm)[0]).toMatchObject({ status: "failed", error: "error.swarm.stalled" });
        expect(row(t.swarm)).toMatchObject({ status: "failed", error: "error.swarm.all_failed" });
    });

    it("a task cut off by the alarm's time budget goes on in the next alarm from where it was", async () => {
        const s = await plan(SPEC({ concurrency: 1, items: [{ id: 1 }], batch: { size: 1 } }));
        scripts.set("1", [
            () => {
                clock += 13 * 60_000; // a long first turn: past the alarm's hard limit
                return code("tu_1", "return 1 + 1;");
            },
            (x) => {
                expect(lastResult(x).result).toBe(2);
                return say(JSON.stringify({ changes: [] }));
            },
        ]);
        await approve(s.swarm, s.spec_hash);
        await tick(s.swarm);
        expect(tasks(s.swarm)[0]).toMatchObject({ status: "queued", attempts: 1 });
        expect(runners.get(s.swarm)!.alarm).toBe(0);
        await drain(s.swarm);
        expect(tasks(s.swarm)[0]).toMatchObject({ status: "done", attempts: 1 });
    });
});

describe("act and read mode", () => {
    it("act: a task's writes run without a card, only in scope, once each (the ledger), a second apart", async () => {
        const s = await plan(SPEC({ mode: "act", items: [{ id: 1 }], batch: { size: 1 } }));
        scripts.set("1", [
            (x) => {
                expect(x.system).toContain("already approved for this swarm");
                return code(
                    "tu_1",
                    `const a = await cobalt.seventv.rename("${SET}", "${emoteId(0)}", "Cat");
                     const b = await cobalt.seventv.rename("${SET}", "${emoteId(0)}", "Cat");
                     const c = await cobalt.seventv.rename("${SET}", "${emoteId(1)}", "Dog");
                     let d; try { await cobalt.seventv.rename("${OTHER_SET}", "${emoteId(1)}", "Dog"); } catch (e) { d = e.message }
                     let r; try { await cobalt.seventv.remove("${SET}", "${emoteId(1)}"); } catch (e) { r = e.message }
                     return { a, b, c, d, r };`,
                );
            },
            (x) => {
                const r = lastResult(x).result;
                expect(r.a).toEqual({ set_id: SET, emote_id: emoteId(0), alias: "Cat" });
                expect(r.b).toEqual(r.a);
                expect(r.d).toMatch(/outside this swarm's scope/);
                expect(r.r).toMatch(/does not exist/);
                return say(JSON.stringify({ renamed: 2 }));
            },
        ]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Cat", "Dog"]);
        expect(renames[1]!.at - renames[0]!.at).toBeGreaterThanOrEqual(1000);
        expect(row(s.swarm)).toMatchObject({ status: "done", apply_status: "none" });
        expect(JSON.parse(tasks(s.swarm)[0].result)).toEqual({ renamed: 2 });
        expect((await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body.changes).toBeNull();
    });

    it("read: answers must match output.schema; the reduce step sums up; job_status follows swarm:<id>", async () => {
        const schema = { type: "array", items: { type: "object", properties: { id: { type: "number" }, ok: { type: "boolean" } }, required: ["id", "ok"] } };
        const s = await plan(SPEC({ mode: "read", writes: undefined, scope: undefined, tools: [], items: [{ id: 1 }, { id: 2 }], batch: { size: 1 }, output: { schema }, reduce: { prompt: "How many are ok?" } }));
        scripts.set("1", [
            (x) => {
                expect(x.tools).toEqual([]);
                expect(x.system).toContain('"required":["id","ok"]');
                return say(JSON.stringify([{ id: 1, ok: "yes" }]));
            },
            (x) => (expect(x.messages.at(-1).content).toMatch(/did not match: 0\.ok: /), say(JSON.stringify([{ id: 1, ok: true }]))),
        ]);
        scripts.set("2", [() => say(JSON.stringify([{ id: 2, ok: false }]))]);
        scripts.set("reduce", [(x) => (expect(x.messages[0].content).toMatch(/How many are ok\?[\s\S]*"result":\[\{"id":1,"ok":true\}\]/), say("1 of 2 ok."))]);
        const ctx = forCall(base(), { keyId: "key-1", caller: "key" });
        expect((await waitJob(ctx, `swarm:${s.swarm}`, 0)).status).toBe("queued");
        const other = forCall(base(), { keyId: "someone-else", caller: "key" });
        await expect(waitJob(other, `swarm:${s.swarm}`, 0)).rejects.toThrow(/not one of your swarms/);
        await approve(s.swarm, s.spec_hash);
        expect(await waitJob(ctx, `swarm:${s.swarm}`, 0)).toMatchObject({ status: "running", swarm: s.swarm, progress: 0 });
        await drain(s.swarm);
        const got = (await json(req(`/swarms/${s.swarm}`, "GET", KEY))).body;
        expect(got).toMatchObject({ status: "done", reduce: "1 of 2 ok.", changes: null });
        const results = (await json(req(`/swarms/${s.swarm}/results`, "GET", KEY))).body.results;
        expect(results.map((r: any) => r.result)).toEqual([[{ id: 1, ok: true }], [{ id: 2, ok: false }]]);
        expect(await waitJob(ctx, `swarm:${s.swarm}`, 0)).toMatchObject({ status: "done", name: "tidy emote names", result: expect.stringMatching(/^2 of 2 tasks done, \$[0-9.]+ spent\. 1 of 2 ok\.$/) });
    });
});

describe("review fixes", () => {
    const changesOf = async (id: string) => {
        const out: any[] = [];
        for (let offset = 0; ; offset += 200) {
            const page = (await json(req(`/swarms/${id}/changes?offset=${offset}&limit=200`, "GET", KEY))).body.changes as any[];
            out.push(...page);
            if (page.length < 200) return out;
        }
    };

    it("prices a request over 100K input tokens at the long tier", () => {
        expect(usdOf({ input_tokens: 100_000, output_tokens: 1_000_000 })).toBeCloseTo(0.01 + 0.5, 8);
        expect(usdOf({ input_tokens: 100_001, output_tokens: 1_000_000 })).toBeCloseTo((100_001 * 0.5) / 1e6 + 2.5, 8);
        // cached tokens count toward the 100K, and keep their own prices
        expect(usdOf({ input_tokens: 1000, cache_read_input_tokens: 150_000, output_tokens: 0 })).toBeCloseTo((1000 * 0.5) / 1e6 + (150_000 * 0.01) / 1e6, 8);
    });

    it("scope keys must be inputs of a write; act mode must scope every write by its id field; unscoped writes are shown", async () => {
        const check = (over: Record<string, unknown>, reg = REGISTRY) => () => checkSpec(SwarmSpecSchema.parse(SPEC(over)), reg, {});
        expect(check({ scope: { channel: ["x"] } })).toThrow(/scope: channel is not an input of any op in writes/);
        expect(check({ mode: "act", scope: undefined })).toThrow(/act mode: scope must limit seventv.rename by set_id/);
        expect(check({ mode: "act", scope: { emote_id: [emoteId(0)] } })).toThrow(/act mode: scope must limit seventv.rename by set_id/);
        expect(check({ mode: "act", writes: ["library.title"], scope: { set_id: [SET] } })).toThrow(/scope: set_id is not an input/);
        expect(check({ mode: "act", writes: ["library.title"], scope: { id: ["abc"] } })).not.toThrow();
        expect(check({ mode: "act", writes: ["seventv.rename", "library.title"], scope: { set_id: [SET] } })).toThrow(/scope must limit library.title by id/);
        // propose may be unscoped: the shape says so
        expect(check({ scope: undefined })).not.toThrow();
        expect(unscopedWrites(REGISTRY, { writes: ["seventv.rename", "library.title"], scope: { set_id: [SET] } })).toEqual(["library.title"]);
        const open = await plan(SPEC({ scope: undefined }));
        expect(open.unscoped_writes).toEqual(["seventv.rename"]);
        expect((await plan()).unscoped_writes).toEqual([]);
    });

    it("the shape previews the spec for the approve page", async () => {
        const items = Array.from({ length: 30 }, (_, i) => ({ emote_id: emoteId(i), name: `emote_${i}` }));
        const s = await plan(SPEC({ items, batch: { size: 4 }, budget: { usd: 1, turns_per_task: 4 }, retry: { attempts: 3, stop_after_failed_tasks: 2 } }));
        expect(s.spec_preview).toEqual({ items_sample: items.slice(0, 10), source: null, output_schema: null, reduce_prompt: null, turns_per_task: 4, attempts: 3, stop_after_failed_tasks: 2 });
        const schema = { type: "object", properties: { ok: { type: "boolean" } } };
        const r = await plan(SPEC({ mode: "read", writes: undefined, scope: undefined, tools: [], source: { call: "seventv.set", args: { set_id: SET }, path: "emotes" }, items: undefined, output: { schema }, reduce: { prompt: "sum up" } }));
        expect(r.spec_preview).toMatchObject({ source: { call: "seventv.set", args: { set_id: SET }, path: "emotes" }, output_schema: schema, reduce_prompt: "sum up", turns_per_task: 6 });
        expect(r.spec_preview.items_sample).toEqual(SET_EMOTES.slice(0, 10));
    });

    it("edit_arg comes from the op's whitelist and after from args; decide moves both, and refuses after without edit_arg", async () => {
        expect(EDIT_ARGS).toEqual({ "seventv.rename": "alias", "seventv.add": "alias", "library.title": "title" });
        const spec = checkSpec(SwarmSpecSchema.parse(SPEC({ writes: ["seventv.rename", "seventv.remove"] })), REG, {});
        const got = checkProposals(REG, spec, {
            changes: [
                { ...rename(0, "Cat"), after: "Something else", edit_arg: "set_id" },
                { op: "seventv.remove", args: { set_id: SET, emote_id: emoteId(1) }, after: "gone", edit_arg: "emote_id" },
            ],
        });
        expect(got).toMatchObject({ ok: true, changes: [{ after: "Cat", edit_arg: "alias" }, { after: "gone", edit_arg: null }] });

        const s = await plan(SPEC({ writes: ["seventv.rename", "seventv.remove"], items: [{ id: 1 }], batch: { size: 1 } }));
        scripts.set("1", [
            () =>
                say(
                    JSON.stringify({
                        changes: [
                            { ...rename(0, "Cat"), after: "Dog", edit_arg: "set_id" },
                            { ...rename(1, "Cat2"), edit_arg: undefined, after: undefined },
                            { op: "seventv.remove", args: { set_id: SET, emote_id: emoteId(2) }, target: "emote_2", after: "(removed)" },
                        ],
                    }),
                ),
        ]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        const rows = await changesOf(s.swarm);
        expect(rows.map((c) => [c.op, c.after, c.edit_arg, c.args.alias ?? null])).toEqual([
            ["seventv.rename", "Cat", "alias", "Cat"],
            ["seventv.rename", "Cat2", "alias", "Cat2"],
            ["seventv.remove", "(removed)", null, null],
        ]);
        expect(rows[2].args).toEqual({ set_id: SET, emote_id: emoteId(2) });
        const refusedAfter = await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: rows[0].n, after: "X" }, { n: rows[2].n, after: "keep it" }] }));
        expect(refusedAfter).toMatchObject({ status: 400, body: { error: { code: "error.swarm.bad_spec" } } });
        expect((await changesOf(s.swarm))[0].after).toBe("Cat"); // nothing of a refused decide is written
        // a keep-only decide on the remove row is fine; an edit moves after and args together
        const ok = (await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: rows[2].n, keep: false }, { n: rows[1].n, after: "cat" }] }))).body;
        expect(ok.changes.find((c: any) => c.n === rows[1].n)).toMatchObject({ after: "cat", args: { alias: "cat" } });
        // clashes read args: "Cat" and "cat" collide in the set, whatever the display says
        expect((await changesOf(s.swarm)).filter((c) => c.clash?.startsWith("duplicate name")).map((c) => c.n)).toEqual([rows[0].n, rows[1].n]);
        // a clash group untouched by a decide is not looked at
        db.raw.prepare("UPDATE swarm_changes SET clash = 'stale' WHERE swarm = ? AND n = ?").run(s.swarm, rows[0].n);
        db.raw.prepare("UPDATE swarm_changes SET op = 'seventv.rename', args = ? WHERE swarm = ? AND n = ?").run(JSON.stringify({ set_id: OTHER_SET, emote_id: emoteId(2), alias: "x" }), s.swarm, rows[2].n);
        await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: rows[2].n, keep: true }] }));
        expect((await changesOf(s.swarm))[0].clash).toBe("stale");
        await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: rows[1].n, keep: true }] }));
        expect((await changesOf(s.swarm))[0].clash).toMatch(/^duplicate name/);
    });

    it("stores 250 proposals of one task and decides 250 at once inside D1's 100-param limit", async () => {
        const s = await plan(SPEC({ items: [{ id: 1 }], batch: { size: 1 }, budget: { usd: 1 } }));
        const many = Array.from({ length: 250 }, (_, i) => rename(i, `name_${i}`));
        scripts.set("1", [() => say(JSON.stringify({ changes: many }))]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        const rows = await changesOf(s.swarm);
        expect(rows.map((c) => c.n)).toEqual(Array.from({ length: 250 }, (_, i) => i + 1));
        expect(rows.map((c) => c.after)).toEqual(many.map((c) => c.after));
        const decided = await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: rows.map((c) => ({ n: c.n, keep: false })) }));
        expect(decided.status, JSON.stringify(decided.body).slice(0, 300)).toBe(200);
        expect(decided.body.changes).toHaveLength(250);
        expect(decided.body.swarm.changes).toMatchObject({ total: 250, kept: 0 });
        // a second task's proposals carry on numbering after the first's
        const t = await plan(SPEC({ items: [{ id: 1 }, { id: 2 }], batch: { size: 1 }, concurrency: 1 }));
        scripts.set("1", [() => say(JSON.stringify({ changes: many.slice(0, 120) }))]);
        scripts.set("2", [() => say(JSON.stringify({ changes: many.slice(120, 240) }))]);
        await approve(t.swarm, t.spec_hash);
        await drain(t.swarm);
        expect((await changesOf(t.swarm)).map((c) => c.n)).toEqual(Array.from({ length: 240 }, (_, i) => i + 1));
    });

    it("a pending ledger row means unknown: the change fails for Harmony to check and re-tick, and is not written again", async () => {
        const s = await plan(SPEC({ items: [{ id: 1 }], batch: { size: 1 } }));
        scripts.set("1", [() => say(JSON.stringify({ changes: [rename(0, "Cat"), rename(1, "Dog"), rename(2, "Bird")] }))]);
        await approve(s.swarm, s.spec_hash);
        await drain(s.swarm);
        const birdN = (await changesOf(s.swarm))[2].n;
        await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: birdN, keep: false }] }));
        // an earlier apply's alarm died between the ledger's pending row and the write's answer
        const hash = await argsHash("seventv.rename", { set_id: SET, emote_id: emoteId(0), alias: "Cat" });
        db.raw.prepare("INSERT INTO swarm_writes (swarm, op, args_hash, task, status, at) VALUES (?, 'seventv.rename', ?, NULL, 'pending', 1)").run(s.swarm, hash);
        await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Dog"]);
        let rows = await changesOf(s.swarm);
        expect(rows[0]).toMatchObject({ status: "failed", error: UNKNOWN_WRITE });
        expect(row(s.swarm).apply_status).toBe("failed");
        // applying again without a re-tick keeps it unknown
        await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Dog"]);
        // Harmony checked 7TV and re-ticks it: the pending row goes and the change runs
        rows = (await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: rows[0].n, keep: true }] }))).body.changes;
        expect(rows[0]).toMatchObject({ status: "proposed", error: null });
        await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Dog", "Cat"]);
        expect(row(s.swarm).apply_status).toBe("applied");
        expect(db.raw.prepare("SELECT status FROM swarm_writes WHERE swarm = ? ORDER BY status").all(s.swarm)).toEqual([{ status: "done" }, { status: "done" }]);

        // an applied swarm applies again when a kept change is not done (re-apply runs only that one)
        const bird = (await changesOf(s.swarm)).find((c) => c.after === "Bird");
        expect(bird).toMatchObject({ keep: false, status: "proposed" });
        expect((await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }))).body.error.code).toBe("error.swarm.not_awaiting");
        expect((await json(req(`/swarms/${s.swarm}/changes`, "POST", SERVICE, { changes: [{ n: bird.n, keep: true }] }))).status).toBe(200);
        const again = await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        expect(again.body.apply?.status, JSON.stringify(again.body)).toBe("applying");
        await drain(s.swarm);
        expect(renames.map((r) => r.alias)).toEqual(["Dog", "Cat", "Bird"]);
        expect(row(s.swarm).apply_status).toBe("applied");
    });

    it("two identical act-mode writes at once run once: the ledger insert is the guard", async () => {
        const spec = checkSpec(SwarmSpecSchema.parse(SPEC({ mode: "act" })), REG, {});
        const tools = swarmToolbox(base(), { swarm: "S1", spec, calls: ["seventv.rename"], collect: { look: [], show: [], collage: null }, limiter: new Limiter(() => clock, sleep), task: 0 });
        const call = () => tools["seventv.rename"]!(SET, emoteId(0), "Cat");
        const both = await Promise.allSettled([call(), call()]);
        expect(renames).toHaveLength(1);
        expect(both.filter((r) => r.status === "fulfilled")).not.toHaveLength(0);
        for (const r of both) if (r.status === "rejected") expect(String(r.reason)).toContain(UNKNOWN_WRITE);
        // once done, the same write answers its stored result without running
        expect(await call()).toEqual({ set_id: SET, emote_id: emoteId(0), alias: "Cat" });
        expect(renames).toHaveLength(1);
        // a write the op refused leaves no ledger row, so it may be tried again
        await expect(tools["seventv.rename"]!(SET, emoteId(1), "taken")).rejects.toThrow(/already in the set/);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM swarm_writes WHERE swarm = 'S1'").get()).toEqual({ n: 1 });
    });

    it("20 plans may wait overall; a session key or the service may wait on any swarm job", async () => {
        const first = await plan();
        const copy = db.raw.prepare(
            `INSERT INTO swarms (id, key_id, name, mode, spec, spec_hash, round, status, item_count, task_count, est_low, est_high, cap_usd, created_at, updated_at, expires_at)
             SELECT ?, ?, name, mode, spec, spec_hash, round, status, item_count, task_count, est_low, est_high, cap_usd, created_at, updated_at, expires_at FROM swarms WHERE id = ?`,
        );
        for (let i = 1; i < PLANS_ALL; i++) copy.run(`copy${String(i).padStart(12, "0")}`, `other-${i}`, first.swarm);
        const r = await json(req("/swarms", "POST", KEY, SPEC()));
        expect(r.body.error.code).toBe("error.swarm.busy");
        // under the per-key cap (this key has 1 waiting), so the overall cap answered
        expect((await waitJob(forCall(base(), { keyId: "sess-1", caller: "key" }), `swarm:${first.swarm}`, 0)).status).toBe("queued");
        expect((await waitJob(forCall(base(), { keyId: null, caller: "service" } as any), `swarm:${first.swarm}`, 0)).status).toBe("queued");
        await expect(waitJob(forCall(base(), { keyId: "someone-else", caller: "key" }), `swarm:${first.swarm}`, 0)).rejects.toThrow(/not one of your swarms/);
    });
});

describe("PostHog (59.10)", () => {
    afterEach(() => vi.unstubAllGlobals());

    it("sends one `swarm` event per step, numbers and codes only, and a task's calls as surface swarm", async () => {
        const sent: { event: string; properties: Record<string, any> }[] = [];
        vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
            if (String(url).includes("posthog")) sent.push(...JSON.parse(String(init.body)).batch);
            return new Response("{}");
        });
        (env as any).POSTHOG_PROJECT_TOKEN = "phc_test";
        const s = await plan(SPEC());
        scripts.set("1", [() => code("tu_1", `return await cobalt.seventv.emote("${emoteId(0)}");`), () => say(JSON.stringify({ changes: [rename(0, "Cat")] }))]);
        scripts.set("2", [() => say(JSON.stringify({ changes: [rename(2, "Bird")] }))]);
        expect((await approve(s.swarm, s.spec_hash)).status).toBe(200);
        await drain(s.swarm);
        await json(req(`/swarms/${s.swarm}/apply`, "POST", SERVICE, { spec_hash: s.spec_hash }));
        await drain(s.swarm);
        await new Promise((r) => setTimeout(r, 0));

        const swarm = sent.filter((e) => e.event === "swarm");
        expect(swarm.map((e) => e.properties.stage)).toEqual(["planned", "approved", "task_ended", "task_ended", "finished", "apply_started", "applied"]);
        for (const e of swarm) expect(e.properties).toMatchObject({ swarm: s.swarm, thread: `swarm:${s.swarm}`, model: "claude-haiku-5-5" });
        expect(swarm[0]!.properties).toMatchObject({ mode: "propose", items: 4, tasks: 2, cap_usd: 1, tools: ["seventv.emote"], writes: ["seventv.rename"] });
        expect(swarm[1]!.properties).toMatchObject({ by: "web" });
        const ended = swarm
            .filter((e) => e.properties.stage === "task_ended")
            .sort((a, b) => Number(a.properties.task) - Number(b.properties.task));
        expect(ended.map((e) => [e.properties.status, e.properties.changes, e.properties.in_tokens])).toEqual([
            ["done", 1, 20_000],
            ["done", 1, 10_000],
        ]);
        expect(ended[0]!.properties.usd).toBeGreaterThan(0);
        expect(swarm[4]!.properties).toMatchObject({ status: "done", done: 2, failed: 0, changes: 2 });
        expect(swarm[6]!.properties).toMatchObject({ done: 2, failed: 0 });
        // never the program's words, the items or the answers
        const text = JSON.stringify(swarm);
        expect(text).not.toContain("Suggest a clean name");
        expect(text).not.toContain("emote_0");
        expect(text).not.toContain("Cat");
        // the task's own calls and the apply's writes are `op` events from the swarm
        const ops = sent.filter((e) => e.event === "op" && e.properties.surface === "swarm");
        expect(ops.map((e) => e.properties.op)).toEqual(["seventv.emote", "seventv.rename", "seventv.rename"]);
        expect(ops[0]!.properties.thread).toBe(`swarm:${s.swarm}`);
    });
});
