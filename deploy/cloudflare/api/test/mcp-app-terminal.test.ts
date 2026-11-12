// The box terminal (MCP-APP-CONTRACT.md section 5.1): the widget's text helpers (src/mcp-app/widgets/term.js: ANSI colours,
// \r progress lines, ls sizes, the command highlight) under node, and box_run / box_pull / box_save through the real MCP
// server: their widget link in tools/list, their structuredContent (the op's JSON plus the terminal's fields), the signed
// thumbnail of a saved private post in _meta, and text answers that stay the op's JSON.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import type { McpCaller } from "../src/mcp";
import { serveMcpRequest } from "../src/mcp-app/server";
import { TerminalOut } from "../src/mcp-app/shapes";
import { forCall } from "../src/registry/context";
import { opBase, REGISTRY } from "../src/registry/index";
import type { BoxRun } from "../src/workbench-core";
import { SLEEP_MS } from "../src/workbench-rules";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

// ---- term.js, as the bundle runs it (plain script, no imports) -------------------------------------------------------------

type Run = { t: string; c: string };
type Term = {
    ansiLines(text: string): Run[][];
    plainText(text: string): string;
    isCutLine(runs: Run[]): boolean;
    lsSize(n: number): string;
    cmdRuns(cmd: string): Run[];
};
const src = readFileSync(join(__dirname, "../src/mcp-app/widgets/term.js"), "utf8");
const T = new Function(`${src}\nreturn { ansiLines, plainText, isCutLine, lsSize, cmdRuns };`)() as Term;
const E = "\x1b";
const text = (runs: Run[]) => runs.map((r) => r.t).join("");

describe("term.js: ANSI colours", () => {
    it("plain text passes through as text, markup and entities included (the view sets it with textContent)", () => {
        const lines = T.ansiLines('<img src=x onerror="alert(1)"> &amp; <b>x</b>\n');
        expect(lines).toEqual([[{ t: '<img src=x onerror="alert(1)"> &amp; <b>x</b>', c: "" }]]);
    });

    it("SGR colours, bold, dim and underline become classes; 0, 22, 24 and 39 undo them", () => {
        const [line] = T.ansiLines(`a${E}[1;32mB${E}[22mC${E}[39mD${E}[2;4;91mE${E}[0mF`);
        expect(line).toEqual([
            { t: "a", c: "" },
            { t: "B", c: "a32 ab" },
            { t: "C", c: "a32" },
            { t: "D", c: "" },
            { t: "E", c: "a91 ad au" },
            { t: "F", c: "" },
        ]);
        // ESC[m is a reset too
        expect(T.ansiLines(`${E}[31mred${E}[mplain`)[0]).toEqual([{ t: "red", c: "a31" }, { t: "plain", c: "" }]);
    });

    it("colours carry across lines until reset, as in a terminal", () => {
        expect(T.ansiLines(`${E}[33mone\ntwo${E}[0m\nthree`)).toEqual([[{ t: "one", c: "a33" }], [{ t: "two", c: "a33" }], [{ t: "three", c: "" }]]);
    });

    it("256-colour and true-colour codes: 0..15 map to the 16, the rest and backgrounds are skipped without eating text", () => {
        expect(T.ansiLines(`${E}[38;5;2mg${E}[38;5;9mr${E}[38;5;200mx${E}[38;2;1;2;3my${E}[48;5;4;1mz`)[0]).toEqual([
            { t: "g", c: "a32" },
            { t: "r", c: "a91" },
            { t: "xy", c: "" },
            { t: "z", c: "ab" },
        ]);
        expect(T.ansiLines(`${E}[41;30mbg${E}[0m`)[0]).toEqual([{ t: "bg", c: "a30" }]);
    });

    it("other escape sequences and control characters are dropped: erase line, cursor moves, OSC titles, bells", () => {
        expect(text(T.ansiLines(`${E}[2K${E}[1Gdone${E}[K${E}]0;my title\x07!${E}]8;;http://x${E}\\link\x07\x08`)[0]!)).toBe("done!link");
        expect(T.ansiLines(`tab\there${E}`)[0]).toEqual([{ t: "tab\there", c: "" }]);
    });
});

describe("term.js: lines and \\r", () => {
    it("a line overwritten with \\r keeps its last part; a trailing \\r keeps the part before it", () => {
        expect(T.ansiLines("frame=1\rframe=2\rframe=3\nnext\n").map(text)).toEqual(["frame=3", "next"]);
        expect(T.ansiLines("50%\r100%\r").map(text)).toEqual(["100%"]);
        expect(T.ansiLines(`10%\r${E}[K`).map(text)).toEqual(["10%"]);
    });

    it("\\r\\n is a plain line end; a final newline makes no empty line; blank lines in the middle stay", () => {
        expect(T.ansiLines("a\r\nb\r\n").map(text)).toEqual(["a", "b"]);
        expect(T.ansiLines("a\n\nb").map(text)).toEqual(["a", "", "b"]);
        expect(T.ansiLines("")).toEqual([]);
        expect(T.ansiLines(undefined as never)).toEqual([]);
    });

    it("colour set in an overwritten part still holds for the part that is kept", () => {
        expect(T.ansiLines(`${E}[32m10%\r100%${E}[0m`)[0]).toEqual([{ t: "100%", c: "a32" }]);
    });

    it("plainText is what a person copies: no escapes, no overwritten progress", () => {
        expect(T.plainText(`${E}[1;34m[x]${E}[0m ok\r\nframe=1\rframe=2\n`)).toBe("[x] ok\nframe=2");
    });

    it("the 8 KB cut marker line is recognised", () => {
        const lines = T.ansiLines("head\n… (61442 bytes cut) …\ntail\n");
        expect(lines.map(T.isCutLine)).toEqual([false, true, false]);
    });
});

describe("term.js: ls sizes and the command highlight", () => {
    it("writes sizes as ls -lh does", () => {
        expect([0, 96, 1023, 1024, 98_304, 421_888, 1_887_436, 9_856_614, 29_360_128, 5 * 1024 ** 3].map(T.lsSize)).toEqual(["0", "96", "1023", "1.0K", "96K", "412K", "1.8M", "9.4M", "28M", "5.0G"]);
        expect(T.lsSize(NaN)).toBe("");
        expect(T.lsSize(-1)).toBe("");
    });

    it("marks the program after each separator, flags and quoted strings", () => {
        const runs = T.cmdRuns(`FOO=1 ffmpeg -y -i "a b.mp4" out.mp4 && ls -lh | grep 'x'`);
        expect(text(runs)).toBe(`FOO=1 ffmpeg -y -i "a b.mp4" out.mp4 && ls -lh | grep 'x'`);
        expect(runs.filter((r) => r.c === "cm").map((r) => r.t)).toEqual(["ffmpeg", "ls", "grep"]);
        expect(runs.filter((r) => r.c === "fl").map((r) => r.t)).toEqual(["-y", "-i", "-lh"]);
        expect(runs.filter((r) => r.c === "st").map((r) => r.t)).toEqual(['"a b.mp4"', "'x'"]);
        // markup in a command is just text
        expect(text(T.cmdRuns("echo <script>x</script>"))).toBe("echo <script>x</script>");
    });
});

// ---- the box tools through the MCP server ------------------------------------------------------------------------------------

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const T0 = 1_760_000_000_000;
const NOW = T0 + 100_000;

let db: FakeD1;
let env: any;
let runs: { thread: string; cmd: string; timeoutS?: number }[];
let boxAnswer: BoxRun | { error: string };
let fakes: Record<string, (input: any) => unknown>;

// the Workbench object as the ops reach it: run answers boxAnswer; pull and save are faked at the op (below)
const workbench = {
    idFromName: () => "main",
    get: () => ({
        async run(thread: string, cmd: string, timeoutS?: number) {
            runs.push({ thread, cmd, ...(timeoutS === undefined ? {} : { timeoutS }) });
            return boxAnswer;
        },
    }),
};

function seedFile(id: string, name: string, pub: boolean) {
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, poster, visibility, post_key)
             VALUES (?, ?, 'upload', ?, ?, ?, ?, 'video/mp4', 9856614, 720, 1280, 24, NULL, 'chat:x', ?, ?, ?, ?)`,
        )
        .run(id, pub ? "public" : "private", pub ? "media" : "originals", pub ? `${id}.mp4` : `originals/${id}.mp4`, pub ? `${MEDIA}${id}.mp4` : null, name, T0, `${MEDIA}Poster${id}.jpg`, pub ? "public" : "private", id);
}

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent", await hashKey("0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11"), "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        WORKBENCH: workbench,
    };
    runs = [];
    fakes = {};
    boxAnswer = { code: 0, stdout: "24.040000\n", stderr: "", timed_out: false, ms: 312 };
    seedFile("BoxSaved00000001", "clip.mp4", false);
    seedFile("BoxPublic0000002", "clip-public.mp4", true);
});

const container = { fetch: async () => Response.json({ status: "error" }, { status: 503 }) };
const callerFor = (): McpCaller => {
    const base = opBase(env, container, { now: () => NOW, sleep: async () => {}, fixedLength: fixedLengthPair } as never, REGISTRY);
    return { ctx: forCall(base, { keyId: "key-1", caller: "key" }), clientKeyId: "key-1", origin: API };
};
// the real registry; `fakes` answer instead of an op's handler (box.pull and box.save need R2 and the upload path)
const recording = Object.create(REGISTRY, {
    toolsFor: {
        value: (surface: "chat", flags: any) =>
            REGISTRY.toolsFor(surface, flags).map((op) => (op.handler && fakes[op.callName] ? { ...op, handler: async (_ctx: any, input: any) => ({ status: 200, body: fakes[op.callName]!(input) }) } : op)),
    },
});
let id = 1;
async function rpc(method: string, params?: unknown): Promise<any> {
    const body = { jsonrpc: "2.0", id: id++, method, ...(params === undefined ? {} : { params }) };
    const res = await serveMcpRequest(recording, callerFor(), new Request(`${API}/mcp`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }), body);
    return res.json();
}
const call = async (name: string, args: Record<string, unknown> = {}) => (await rpc("tools/call", { name, arguments: args })).result;
const SLEEPS = new Date(NOW + SLEEP_MS).toISOString();
const link = { ui: { resourceUri: "ui://capystore/terminal.html" }, "ui/resourceUri": "ui://capystore/terminal.html" };

describe("box tools end on the terminal widget", () => {
    it("tools/list links box_run, box_pull and box_save to the terminal while the box is on; off, they are not listed", async () => {
        const tools = (await rpc("tools/list")).result.tools as any[];
        for (const name of ["box_run", "box_pull", "box_save"]) expect(tools.find((t) => t.name === name)?._meta, name).toEqual(link);
        // annotations and the input schema are the op's as before (free tier: none)
        expect(tools.find((t) => t.name === "box_run").annotations).toBeUndefined();
        expect(tools.find((t) => t.name === "box_run").inputSchema.required).toEqual(["cmd"]);
        delete env.WORKBENCH;
        const off = (await rpc("tools/list")).result.tools as any[];
        expect(off.map((t) => t.name)).not.toContain("box_run");
        const read = (await rpc("resources/read", { uri: "ui://capystore/terminal.html" })).result;
        expect(read.contents[0].text).toContain('data-default-view="terminal"');
    });

    it("box_run: the text is the op's JSON (now with ms); structuredContent adds the terminal's fields", async () => {
        const r = await call("box_run", { cmd: "ffprobe -v error clip.mp4", timeoutS: 30 });
        expect(r.isError).toBeUndefined();
        expect(JSON.parse(r.content[0].text)).toEqual({ code: 0, stdout: "24.040000\n", stderr: "", timed_out: false, ms: 312 });
        expect(runs).toEqual([{ thread: expect.any(String), cmd: "ffprobe -v error clip.mp4", timeoutS: 30 }]);
        expect(r.structuredContent).toEqual({
            view: "terminal",
            tool: "run",
            cmd: "ffprobe -v error clip.mp4",
            code: 0,
            stdout: "24.040000\n",
            stderr: "",
            timed_out: false,
            ms: 312,
            stdout_cut: false,
            stderr_cut: false,
            sleeps_at: SLEEPS,
        });
        expect(TerminalOut.parse(r.structuredContent)).toBeTruthy();
        expect(r._meta).toBeUndefined();
    });

    it("box_run: a stream cut to 8 KB, a failure and a timeout are results, not errors", async () => {
        boxAnswer = { code: 124, stdout: "start\n… (4096 bytes cut) …\nend\n", stderr: "(killed after 60 s)", timed_out: true, ms: 60_004 };
        const r = await call("box_run", { cmd: "slow" });
        expect(r.isError).toBeUndefined();
        expect(r.structuredContent).toMatchObject({ tool: "run", code: 124, timed_out: true, stdout_cut: true, stderr_cut: false, ms: 60_004 });
        boxAnswer = { code: 127, stdout: "", stderr: "bash: line 1: yt-dl: command not found\n", timed_out: false, ms: 9 };
        expect((await call("box_run", { cmd: "yt-dl" })).structuredContent).toMatchObject({ code: 127, stderr: "bash: line 1: yt-dl: command not found\n" });
    });

    it("box_run with the box used up: an error, no structuredContent (the widget draws one red line)", async () => {
        boxAnswer = { error: "the workbench is used up for today (60 awake minutes); it opens again at midnight UTC" };
        const r = await call("box_run", { cmd: "ls" });
        expect(r.isError).toBe(true);
        expect(r.content[0].text).toBe("cobalt.box.run: the workbench is used up for today (60 awake minutes); it opens again at midnight UTC");
        expect(r.structuredContent).toBeUndefined();
    });

    it("box_pull: the files as the op gave them", async () => {
        const files = [{ path: "BoxSaved00000001.mp4", file_id: "BoxSaved00000001", content_type: "video/mp4", bytes: 9_856_614, seconds: 24, width: 720, height: 1280 }];
        fakes["box.pull"] = () => ({ files });
        const r = await call("box_pull", { id: "BoxSaved00000001" });
        expect(JSON.parse(r.content[0].text)).toEqual({ files });
        expect(r.structuredContent).toEqual({ view: "terminal", tool: "pull", files, sleeps_at: SLEEPS });
        expect(TerminalOut.parse(r.structuredContent)).toBeTruthy();
    });

    it("box_save: the new post; one not public (an upload has no link: off) has its signed thumbnail in _meta only", async () => {
        const op = { post_id: "BoxSaved00000001", kind: "video", bytes: 9_856_614, processing: true, public_url: null };
        fakes["box.save"] = () => op;
        const r = await call("box_save", { path: "clip.mp4", title: "clip 720p" });
        expect(JSON.parse(r.content[0].text)).toEqual(op);
        expect(TerminalOut.parse(r.structuredContent)).toBeTruthy();
        expect(r.structuredContent).toMatchObject({ ...op, view: "terminal", tool: "save", sleeps_at: SLEEPS, post: { id: "BoxSaved00000001", status: "off", kind: "video", thumb_url: null } });
        const meta = r._meta["capystore/preview"];
        expect(Object.keys(meta)).toEqual(["BoxSaved00000001"]);
        expect(meta.BoxSaved00000001.thumb).toMatch(/^https:\/\/api\.capybaraharmony\.com\/mcp\/media\/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\/poster$/);
        expect(JSON.stringify(r.structuredContent) + r.content[0].text).not.toContain("/mcp/media/");

        // a public post: its public poster, no _meta
        fakes["box.save"] = () => ({ ...op, post_id: "BoxPublic0000002", processing: false, public_url: `${MEDIA}BoxPublic0000002.mp4` });
        const p = await call("box_save", { path: "clip.mp4", public: true });
        expect(p.structuredContent.post).toMatchObject({ id: "BoxPublic0000002", status: "public" });
        expect(p._meta).toBeUndefined();
    });

    it("box_save: a post it cannot read still draws the row (post null); a hidden one is not shown", async () => {
        fakes["box.save"] = () => ({ post_id: "NoSuchPost000001", kind: "image", bytes: 10, processing: false, public_url: null });
        const r = await call("box_save", { path: "x.png" });
        expect(r.structuredContent).toMatchObject({ view: "terminal", tool: "save", post_id: "NoSuchPost000001", post: null });
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES ('BoxSaved00000001', 'hidden', 'you', NULL, ?)").run(T0);
        fakes["box.save"] = () => ({ post_id: "BoxSaved00000001", kind: "video", bytes: 10, processing: false, public_url: null });
        const h = await call("box_save", { path: "x.mp4" });
        expect(h.structuredContent.post).toBeNull();
        expect(h._meta).toBeUndefined();
    });
});
