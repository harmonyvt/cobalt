// The chat's workbench box (APP-API-CONTRACT.md section 33.11): the outbound rule, typing a saved file by its bytes, the
// 8 KB output clip, the daily ledger, the box itself (WorkbenchCore) against a stub container that runs real bash in a
// temp directory, and the two ops through a whole chat reply (the real sandbox source, the real upload path, the real
// SQL on node:sqlite).
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import type { ChatModel, CodeRunner, ModelTurn } from "../src/chat";
import { systemPrompt } from "../src/chat";
import { CODE_TIMEOUT_BOX_MS } from "../src/chat-limits";
import { sandboxModule } from "../src/chat-loader-module";
import { hashKey } from "../src/keys";
import { REGISTRY, toolTypes } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { WorkbenchCore, type BoxExecOptions, type BoxProcess, type WorkbenchDeps } from "../src/workbench-core";
import {
    checkOutbound,
    Clip,
    dailyMinutes,
    emptyLedger,
    forwardOutbound,
    isPublicIp,
    markActive,
    markAsleep,
    markAwake,
    sniffSave,
    usedMs,
    workbenchOn,
} from "../src/workbench-rules";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const bytes = (...xs: (number | string)[]) =>
    new Uint8Array(xs.flatMap((x) => (typeof x === "string" ? [...x].map((c) => c.charCodeAt(0)) : [x])));

describe("the outbound rule", () => {
    it("lets public http(s) out and refuses private, odd and our own destinations", () => {
        const ok = [
            "https://example.com/a?b=1",
            "http://example.com/",
            "https://cdn.discordapp.com/attachments/1/2/a.gif",
            "https://media.capybaraharmony.com/abc.mp4",
            "https://93.184.216.34/",
            "http://[2606:4700::1111]/",
        ];
        for (const u of ok) expect(checkOutbound(u), u).toMatchObject({ ok: true });
        const no: [string, RegExp][] = [
            ["http://169.254.169.254/latest/meta-data/", /not a public address/],
            ["http://10.0.0.1/", /not a public address/],
            ["http://127.0.0.1/", /not a public address/],
            ["http://192.168.1.1/", /not a public address/],
            ["http://100.64.0.1/", /not a public address/],
            ["http://[::1]/", /not a public address/],
            ["http://[::ffff:10.0.0.1]/", /not a public address/],
            ["http://[fd00::1]/", /not a public address/],
            ["http://[64:ff9b::a00:1]/", /not a public address/],
            ["http://localhost/", /private name/],
            ["http://metadata.google.internal/", /private name/],
            ["http://printer.local/", /private name/],
            ["http://intranet/", /private name/],
            ["https://example.com:8443/", /port 8443/],
            ["http://example.com:9000/", /port 9000/],
            ["https://user:pw@example.com/", /credentials/],
            ["ftp://example.com/", /ftp: is not allowed/],
            ["https://api.capybaraharmony.com/", /capystore's own server/],
            ["https://share.capybaraharmony.com/x", /capystore's own server/],
            ["https://studio.capybaraharmony.com/live/x", /capystore's own server/],
            ["https://cobalt.capybaraharmony.com/", /capystore's own server/],
            ["https://capybaraharmony.com/", /capystore's own server/],
            ["https://API.CapybaraHarmony.com./", /capystore's own server/],
            ["https://someone.workers.dev/", /Workers host/],
            ["https://x.pages.dev/", /Workers host/],
        ];
        for (const [u, why] of no) {
            const d = checkOutbound(u);
            expect(d.ok, u).toBe(false);
            if (!d.ok) expect(d.reason, u).toMatch(why);
        }
        // the same tables as the helper's isPublicIp
        expect(isPublicIp("8.8.8.8")).toBe(true);
        expect(isPublicIp("2002:0a00:0001::1")).toBe(false);
        expect(isPublicIp("2001:db8::1")).toBe(false);
        expect(isPublicIp("not-an-ip")).toBe(false);
    });

    it("answers a refusal itself and sends the rest out with redirects left to the box", async () => {
        const sent: Request[] = [];
        const fetcher = async (r: Request) => {
            sent.push(r);
            return new Response("ok", { status: 302, headers: { location: "http://10.0.0.1/" } });
        };
        const blocked = await forwardOutbound(new Request("http://169.254.169.254/"), fetcher);
        expect(blocked.status).toBe(403);
        expect(await blocked.text()).toContain("workbench: blocked");
        expect(sent).toEqual([]);
        const out = await forwardOutbound(new Request("https://example.com/x", { method: "POST", body: "hi" }), fetcher);
        expect(out.status).toBe(302);
        expect(sent).toHaveLength(1);
        expect(sent[0]!.redirect).toBe("manual");
        expect(sent[0]!.method).toBe("POST");
        expect(await sent[0]!.text()).toBe("hi");
    });
});

describe("what box.save takes", () => {
    it("types a file by its bytes: the upload path's types, nothing else", () => {
        expect(sniffSave(bytes(0xff, 0xd8, 0xff, 0xe0))).toEqual({ contentType: "image/jpeg", ext: "jpg" });
        expect(sniffSave(bytes(0x89, "PNG", 0x0d, 0x0a, 0x1a, 0x0a))).toEqual({ contentType: "image/png", ext: "png" });
        expect(sniffSave(bytes("RIFF", 0, 0, 0, 0, "WEBPVP8 "))).toEqual({ contentType: "image/webp", ext: "webp" });
        expect(sniffSave(bytes("GIF89a", 1, 0))).toEqual({ contentType: "image/gif", ext: "gif" });
        expect(sniffSave(bytes(0, 0, 0, 0x18, "ftypisom"))).toEqual({ contentType: "video/mp4", ext: "mp4" });
        expect(sniffSave(bytes(0, 0, 0, 0x14, "ftypqt  "))).toEqual({ contentType: "video/quicktime", ext: "mov" });
        expect(sniffSave(bytes(0, 0, 0, 0x18, "ftypheic"))).toEqual({ contentType: "image/heic", ext: "heic" });
        // webm, m4a audio, html, mp3: not something the upload path stores
        expect(sniffSave(bytes(0x1a, 0x45, 0xdf, 0xa3, "webm"))).toBeNull();
        expect(sniffSave(bytes(0, 0, 0, 0x18, "ftypM4A "))).toBeNull();
        expect(sniffSave(bytes("<!doctype html>"))).toBeNull();
        expect(sniffSave(bytes("ID3", 4, 0))).toBeNull();
        expect(sniffSave(bytes())).toBeNull();
    });
});

describe("the output clip", () => {
    it("keeps everything up to 8 KB, then the first 2 KB and the last 6 KB, and says how much went", () => {
        const small = new Clip();
        small.push(new TextEncoder().encode("hello\n"));
        expect(small.text()).toBe("hello\n");
        const big = new Clip();
        const chunk = (ch: string, n: number) => new TextEncoder().encode(ch.repeat(n));
        big.push(chunk("a", 3000));
        for (let i = 0; i < 10; i++) big.push(chunk("b", 1000));
        big.push(chunk("c", 100));
        const t = big.text();
        expect(big.total).toBe(13_100);
        expect(t.startsWith("a".repeat(2048))).toBe(true);
        expect(t.endsWith("b".repeat(6044) + "c".repeat(100))).toBe(true);
        expect(t).toContain(`… (${13_100 - 8192} bytes cut) …`);
    });
});

describe("the daily ledger", () => {
    const T = Date.UTC(2026, 9, 28, 10, 0, 0);
    it("counts awake time per UTC day, charges a missed stop up to the sleep, and starts each day from zero", () => {
        let l = markAwake(emptyLedger(T), T, "t1");
        expect(usedMs(l, T + 60_000)).toBe(60_000);
        l = markActive(l, T + 5 * 60_000);
        // learned about the stop an hour later: charged to last_active + 2 min, not the hour
        l = markAsleep(l, T + 65 * 60_000);
        expect(l.used_ms).toBe(7 * 60_000);
        expect(l.awake_since).toBeNull();
        expect(l.owner).toBeNull();
        // a stretch over midnight counts from midnight on the new day
        const late = Date.UTC(2026, 9, 28, 23, 59, 0);
        l = markAwake(l, late, "t2");
        expect(usedMs(l, Date.UTC(2026, 9, 29, 0, 1, 0))).toBe(60_000);
    });
    it("reads its switches: a 60 minute default, 0 is off, no binding is off", () => {
        expect(dailyMinutes({})).toBe(60);
        expect(dailyMinutes({ WORKBENCH_DAILY_MINUTES: "15" })).toBe(15);
        expect(dailyMinutes({ WORKBENCH_DAILY_MINUTES: "nope" })).toBe(60);
        expect(workbenchOn({ WORKBENCH: {}, WORKBENCH_DAILY_MINUTES: "0" })).toBe(false);
        expect(workbenchOn({ WORKBENCH_DAILY_MINUTES: "60" })).toBe(false);
        expect(workbenchOn({ WORKBENCH: {} })).toBe(true);
    });
});

// ---- the box against a stub container: real bash in a temp directory ------------------------------------------------

type Box = {
    core: WorkbenchCore;
    root: string;
    log: string[];
    clock: { now: number };
    state: { running: boolean; starts: number; wipes: number; renews: number };
    storage: Map<string, unknown>;
};

function stubContainer(cap = 60): Box {
    const root = mkdtempSync(join(tmpdir(), "workbench-"));
    const log: string[] = [];
    const clock = { now: Date.UTC(2026, 9, 28, 10, 0, 0) };
    const state = { running: false, starts: 0, wipes: 0, renews: 0 };
    const storage = new Map<string, unknown>();
    const exec = async (argv: string[], o: BoxExecOptions): Promise<BoxProcess> => {
        log.push(`${o.user ?? "?"} ${argv[0] === "bash" ? `bash ${argv[2]}` : argv.join(" ")}`);
        if (!state.running) throw new Error("container is not running");
        if (argv[0] === "/usr/local/bin/box-init") {
            return { stdout: null, stderr: new Blob([]).stream(), exitCode: Promise.resolve(0), kill() {} };
        }
        const child = spawn(argv[0]!, argv.slice(1), {
            cwd: o.cwd === "/workspace" ? root : o.cwd,
            env: { PATH: process.env.PATH ?? "/usr/bin:/bin", LANG: "C.UTF-8" },
            stdio: ["ignore", o.stdout === "ignore" ? "ignore" : "pipe", o.stderr === "ignore" ? "ignore" : "pipe"],
        });
        child.on("error", () => {});
        const exitCode = new Promise<number>((res) => child.on("close", (c, sig) => res(c ?? (sig ? 137 : -1))));
        o.signal?.addEventListener("abort", () => child.kill("SIGKILL"));
        return {
            stdout: child.stdout ? (Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>) : null,
            stderr: child.stderr ? (Readable.toWeb(child.stderr) as ReadableStream<Uint8Array>) : null,
            exitCode,
            kill: (s) => void child.kill(s ?? "SIGKILL"),
        };
    };
    const deps: WorkbenchDeps = {
        storage: { get: async <T,>(k: string) => storage.get(k) as T | undefined, put: async (k, v) => void storage.set(k, structuredClone(v)) },
        now: () => clock.now,
        running: () => state.running,
        start: async () => {
            state.running = true;
            state.starts++;
        },
        wipe: async () => {
            state.running = false;
            state.wipes++;
            // the disk goes with it
            rmSync(root, { recursive: true, force: true });
            mkdirSync(root, { recursive: true });
            await core.stopped();
        },
        exec,
        renew: () => void state.renews++,
        capMinutes: cap,
    };
    const core = new WorkbenchCore(deps);
    return { core, root, log, clock, state, storage };
}

const boxes: Box[] = [];
const newBox = (cap?: number) => {
    const b = stubContainer(cap);
    boxes.push(b);
    return b;
};
afterEach(() => {
    for (const b of boxes.splice(0)) rmSync(b.root, { recursive: true, force: true });
});

describe("the box", () => {
    it("wakes on the first call, runs box-init as root once, then commands as the box user in /workspace", async () => {
        const b = newBox();
        const r = await b.core.run("t1", "echo hi; echo oops >&2; pwd; exit 3");
        expect(r).toMatchObject({ code: 3, stdout: `hi\n${b.root}\n`, stderr: "oops\n", timed_out: false });
        await b.core.run("t1", "true");
        expect(b.state.starts).toBe(1);
        expect(b.log).toEqual(["0:0 /usr/local/bin/box-init", "1000:1000 bash echo hi; echo oops >&2; pwd; exit 3", "1000:1000 bash true"]);
        expect(b.state.renews).toBeGreaterThan(0);
    });

    it("cuts a long output to 8 KB and kills a command at its timeout", async () => {
        const b = newBox();
        const r = (await b.core.run("t1", "head -c 100000 /dev/zero | tr '\\0' x; echo; echo END")) as any;
        expect(r.code).toBe(0);
        expect(r.stdout.length).toBeLessThan(8300);
        expect(r.stdout).toContain("bytes cut");
        expect(r.stdout.endsWith("END\n")).toBe(true);
        const t0 = Date.now();
        const slow = (await b.core.run("t1", "echo started; sleep 30", 1)) as any;
        expect(Date.now() - t0).toBeLessThan(10_000);
        expect(slow).toMatchObject({ code: 124, timed_out: true, stdout: "started\n" });
        expect(slow.stderr).toContain("killed after 1 s");
    }, 20_000);

    it("keeps a thread's files while awake and wipes the box before another thread gets it", async () => {
        const b = newBox();
        await b.core.run("t1", "echo secret > notes.txt");
        expect(((await b.core.run("t1", "cat notes.txt")) as any).stdout).toBe("secret\n");
        const other = (await b.core.run("t2", "ls")) as any;
        expect(b.state.wipes).toBe(1);
        expect(b.state.starts).toBe(2);
        expect(other.stdout).toBe("");
    });

    it("refuses past the daily cap and puts the box to sleep", async () => {
        const b = newBox(10);
        await b.core.run("t1", "true");
        b.clock.now += 11 * 60_000;
        const r = await b.core.run("t1", "true");
        expect(r).toEqual({ error: expect.stringContaining("used up for today (10 awake minutes)") });
        expect(b.state.running).toBe(false);
        // the next UTC day opens again
        b.clock.now += 24 * 60 * 60_000;
        expect(await b.core.run("t1", "echo again")).toMatchObject({ code: 0, stdout: "again\n" });
    });

    it("stats and streams a file for box.save, and says when it is missing", async () => {
        const b = newBox();
        writeFileSync(join(b.root, "a.gif"), bytes("GIF89a", 1, 0, 1, 0, 0, 0, 0));
        const st = await b.core.stat("t1", "a.gif");
        expect(st).toEqual({ size: 13, head: [...bytes("GIF89a", 1, 0, 1, 0, 0, 0, 0)] });
        const s = await b.core.read("t1", "a.gif");
        expect(s).toBeInstanceOf(ReadableStream);
        expect(new Uint8Array(await new Response(s as ReadableStream).arrayBuffer())).toEqual(bytes("GIF89a", 1, 0, 1, 0, 0, 0, 0));
        expect(await b.core.stat("t1", "nope.gif")).toEqual({ error: "no such file: nope.gif" });
        expect(await b.core.stat("t1", "a file; rm -rf /")).toEqual({ error: "no such file: a file; rm -rf /" });
    });
});

// ---- the ops through a chat reply -------------------------------------------------------------------------------------

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}`, "content-type": "application/json" };

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let box: Box;
let adopts: { key: string | null; body: any }[];
let runOpts: unknown[];
let seen: { system: string; messages: any[] }[];
let script: ((s: { system: string; messages: any[] }) => ModelTurn)[];

const container = {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);
        if (u.pathname === "/studio/upload/adopt") {
            adopts.push({ key: req.headers.get("x-cobalt-key-id"), body: await req.json() });
            return Response.json({ status: "success", id: "Sess000000000000000001", url: `${WEB}/studio/Sess000000000000000001` }, { status: 201 });
        }
        return Response.json({ status: "error", error: { code: "error.test.unexpected" } }, { status: 500 });
    },
};

// the real module source the Worker Loader runs, with a stand-in WorkerEntrypoint
const runner: CodeRunner = async (code, tools, opts) => {
    runOpts.push(opts ?? null);
    const mod = sandboxModule(code, opts?.timeoutMs).replace(/^import .*$/m, "").replace("export default class Run", "return class Run");
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

const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn({ system, messages, onText }) {
        const s = { system, messages: JSON.parse(JSON.stringify(messages)) };
        seen.push(s);
        const next = script.shift();
        if (!next) throw new Error("script ran out");
        const r = next(s);
        for (const blk of r.content) if (blk.type === "text") onText(blk.text);
        return r;
    },
    async title() {
        return null;
    },
};
const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
const code = (id: string, src: string): ModelTurn => ({ content: [{ type: "tool_use", id, name: "run_code", input: { code: src } }], stop_reason: "tool_use" });
const lastResult = (s: { messages: any[] }) => JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);

const call = (path: string, init: RequestInit = {}) =>
    handleRequest(new Request(`${API}${path}`, init), env, container as any, { now: () => 2_000_000, chatModel: model, codeRunner: runner } as any);
const reply = async (thread: string, text: string) => (await call(`/chat/threads/${thread}/messages`, { method: "POST", headers: AUTH, body: JSON.stringify({ text }) })).text();
const newThread = async () => ((await (await call("/chat/threads", { method: "POST", headers: AUTH, body: "{}" })).json()) as any).thread.id as string;

// The Workbench namespace: one object ("main"), the box above behind the same RPC methods src/workbench.ts has.
const namespace = () => ({
    idFromName: (name: string) => ({ name }),
    get: (id: { name: string }) => {
        expect(id.name).toBe("main");
        return { run: box.core.run.bind(box.core), stat: box.core.stat.bind(box.core), read: box.core.read.bind(box.core) };
    },
});

describe("cobalt.box in a chat reply", () => {
    beforeEach(async () => {
        db = withBatch(createFakeD1());
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
        originals = new MemoryOriginals();
        box = newBox();
        env = {
            API_URL: `${API}/`,
            CORS_URL: WEB,
            COBALT_API_KEY: INTERNAL,
            DB: db as unknown as D1Database,
            ORIGINALS: originals,
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: MEDIA,
            WORKBENCH: namespace() as unknown as DurableObjectNamespace,
        };
        adopts = [];
        runOpts = [];
        seen = [];
        script = [];
    });

    it("is offered only while the box is on, last in the prompt, with its own guidance", () => {
        expect(toolTypes(true)).not.toContain("box: {");
        const on = toolTypes(true, REGISTRY, true);
        expect(on).toContain("  box: {\n");
        expect(on).toContain("run(cmd: string, opts?: {\n      timeoutS?: number; // default 60, max 120\n    }): Promise<{ code: number; stdout: string; stderr: string; timed_out: boolean }>;");
        expect(on).toMatch(/save\(path: string, opts\?: \{/);
        expect(systemPrompt(0, true, on)).toContain("cobalt.box is a real Linux box");
        expect(systemPrompt(0, true, toolTypes(true))).not.toContain("cobalt.box");
    });

    it("runs a command and saves a file into the library as the chat, like an upload", async () => {
        const t = await newThread();
        // an mp4 head and some bytes
        const mp4 = new Uint8Array([...bytes(0, 0, 0, 0x18, "ftypisom", 0, 0, 2, 0, "isomiso2"), ...new Uint8Array(5000).fill(7)]);
        writeFileSync(join(box.root, "clip.download"), mp4);
        script = [
            (s) => {
                expect(s.system).toContain("cobalt.box is a real Linux box");
                return code(
                    "tu_1",
                    `const r = await cobalt.box.run("ls; echo warn >&2");
                     const s = await cobalt.box.save("clip.download", { title: "the clip" });
                     return { r, s };`,
                );
            },
            (s) => {
                const r = lastResult(s);
                expect(r.result.r).toEqual({ code: 0, stdout: "clip.download\n", stderr: "warn\n", timed_out: false });
                expect(r.result.s).toEqual({ post_id: expect.any(String), kind: "video", bytes: mp4.length, processing: true, public_url: null });
                return say("saved it (=^･ω･^=)");
            },
        ];
        const out = await reply(t, "save that weird link");
        expect(out).toContain("event: done");
        expect(script).toEqual([]);
        // the run got the long budget because it called the box
        expect(runOpts).toEqual([{ timeoutMs: CODE_TIMEOUT_BOX_MS }]);
        // stored like PUT /studio/upload: the bytes, a private upload row with the chat's key id, the title, the adopt
        const row = db.raw.prepare("SELECT id, source, content_type, bytes, key_id, name, r2_key FROM media_items").get() as any;
        expect(row).toMatchObject({ source: "upload", content_type: "video/mp4", bytes: mp4.length, key_id: `chat:${t}`, name: "clip.mp4" });
        expect(originals.objects.get(row.r2_key)!.bytes).toEqual(mp4);
        expect((db.raw.prepare("SELECT title FROM media_titles").get() as any).title).toBe("the clip");
        expect(adopts).toEqual([{ key: `chat:${t}`, body: expect.objectContaining({ item_id: row.id, content_type: "video/mp4", queue: true }) }]);
    });

    it("tells the model what it cannot save, and a plain run keeps the normal budget", async () => {
        const t = await newThread();
        writeFileSync(join(box.root, "page.html"), "<!doctype html><p>hi</p>");
        script = [
            () => code("tu_0", `return (await cobalt.library.list()).length;`),
            () =>
                code(
                    "tu_1",
                    `const out = [];
                     for (const p of ["page.html", "missing.mp4"]) { try { await cobalt.box.save(p); } catch (e) { out.push(e.message); } }
                     try { await cobalt.box.run("x", { timeoutS: 500 }); } catch (e) { out.push(e.message); }
                     return out;`,
                ),
            (s) => {
                const r = lastResult(s).result;
                expect(r[0]).toMatch(/not a jpg, png, webp, gif, heic, mp4 or mov by its bytes; convert it with ffmpeg/);
                expect(r[1]).toBe("cobalt.box.save: no such file: missing.mp4");
                expect(r[2]).toMatch(/^cobalt\.box\.run: timeoutS: /);
                return say("nope");
            },
        ];
        await reply(t, "try");
        expect(script).toEqual([]);
        expect(runOpts).toEqual([null, { timeoutMs: CODE_TIMEOUT_BOX_MS }]);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 0 });
    });

    it("does not exist for the model while the box is off", async () => {
        env.WORKBENCH_DAILY_MINUTES = "0";
        const t = await newThread();
        script = [
            (s) => {
                expect(s.system).not.toContain("cobalt.box");
                return code("tu_1", `return await cobalt.box.run("id");`);
            },
            (s) => {
                expect(lastResult(s).error).toBe("cobalt.box.run does not exist");
                return say("no box");
            },
        ];
        await reply(t, "run id");
        expect(script).toEqual([]);
        expect(box.state.starts).toBe(0);
    });
});
