// Section 49.3: the yt-dlp box's own HTTP API (deploy/cloudflare/ytdlp/server.mjs), run against a stand-in yt-dlp (a node
// script that acts out each case from the link it is given) and a missing ffprobe.
import { chmodSync, mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { codeFor, makeHandler, ytdlpArgs } from "../../ytdlp/server.mjs";

const KEY = "internal-key";
let dir: string;
let server: Server;
let base: string;

const FAKE = `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
const url = args[args.length - 1];
const out = args[args.indexOf("-o") + 1];
const file = out.replace("%(ext)s", "mp4");
if (url.includes("unsupported")) { console.error("ERROR: Unsupported URL: " + url); process.exit(1); }
if (url.includes("private")) { console.error("ERROR: [youtube] abc: Private video. Sign in if you've been granted access"); process.exit(1); }
// over --max-filesize: yt-dlp is quiet under -O, so it says nothing, writes nothing and exits 0
if (url.includes("big")) { process.exit(0); }
if (url.includes("slow")) { setTimeout(() => {}, 60000); return; }
console.log("@@P 1000 4000 NA");
console.log("@@P 4000 4000 NA");
console.log("[Merger] Merging formats into " + JSON.stringify(file));
fs.writeFileSync(file, Buffer.alloc(4000, 7));
console.log("@@D " + JSON.stringify({ title: "Me at the zoo", duration: 19, width: 320, height: 240, extractor_key: "Youtube", ext: "mp4", filepath: file }));
`;

beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), "ytdlp-test-"));
    const bin = join(dir, "yt-dlp");
    writeFileSync(bin, FAKE);
    chmodSync(bin, 0o755);
    const handle = makeHandler({ internalKey: KEY, dir: join(dir, "jobs"), bin, ffprobe: join(dir, "no-ffprobe"), timeoutMs: 1500, log: () => {} });
    server = createServer((req, res) => void handle(req, res));
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const a = server.address() as { port: number };
    base = `http://127.0.0.1:${a.port}`;
});
afterAll(() => {
    server?.close();
    rmSync(dir, { recursive: true, force: true });
});

const H = { "x-internal-key": KEY, "content-type": "application/json" };
const start = (id: string, url: unknown) => fetch(`${base}/fetch`, { method: "POST", headers: H, body: JSON.stringify({ id, url }) });
const poll = async (id: string) => {
    for (let i = 0; i < 100; i++) {
        const b = (await (await fetch(`${base}/fetch/${id}`, { headers: H })).json()) as any;
        if (b.status !== "pending") return b;
        await new Promise((r) => setTimeout(r, 30));
    }
    throw new Error("still pending");
};

describe("yt-dlp box", () => {
    it("asks yt-dlp for one ≤720p mp4 of at most 200 MB, never a playlist", () => {
        const a = ytdlpArgs("https://x.test/v", "/tmp/ytdlp/abc", { jsRuntime: "node" });
        expect(a).toEqual(expect.arrayContaining(["--no-playlist", "--merge-output-format", "mp4", "--max-filesize", String(200 * 1024 * 1024), "--js-runtimes", "node"]));
        expect(a.slice(-2)).toEqual(["--", "https://x.test/v"]);
        expect(a[a.indexOf("-S") + 1]).toMatch(/^res:720,/);
    });

    it("maps yt-dlp's words to the codes the app knows", () => {
        expect(codeFor("ERROR: Unsupported URL: https://a.test")).toBe("error.api.link.unsupported");
        expect(codeFor("Sign in to confirm you're not a bot")).toBe("error.api.youtube.login");
        expect(codeFor("Sign in to confirm your age")).toBe("error.api.content.video.age");
        expect(codeFor("ERROR: Private video")).toBe("error.api.content.video.private");
        expect(codeFor("ERROR: Video unavailable")).toBe("error.api.content.video.unavailable");
        expect(codeFor("something else")).toBe("error.api.fetch.fail");
    });

    it("refuses a call without the internal key; /health needs none", async () => {
        expect((await fetch(`${base}/fetch/abc`)).status).toBe(403);
        expect((await fetch(`${base}/fetch/abc`, { headers: { "x-internal-key": "nope" } })).status).toBe(403);
        expect((await fetch(`${base}/health`)).status).toBe(200);
    });

    it("refuses a bad id or a link that is not http(s)", async () => {
        expect((await start("../x", "https://a.test/v")).status).toBe(400);
        for (const u of ["file:///etc/passwd", "ftp://a.test/v", "", 5, "https://a.test/" + "a".repeat(2100)]) {
            expect((await start("abc", u)).status).toBe(400);
        }
    });

    it("downloads, reports progress, answers done and serves the file with its length, then forgets it on DELETE", async () => {
        expect((await start("ok1", "https://www.youtube.com/watch?v=ok")).status).toBe(202);
        // the same id again is the same job
        expect((await start("ok1", "https://www.youtube.com/watch?v=ok")).status).toBe(202);
        const b = await poll("ok1");
        expect(b).toEqual({
            status: "done",
            bytes: 4000,
            contentType: "video/mp4",
            ext: "mp4",
            duration: 19,
            width: 320,
            height: 240,
            title: "Me at the zoo",
            service: "youtube",
            picker_count: null,
            engine: "ytdlp",
        });
        const f = await fetch(`${base}/fetch/ok1/file`, { headers: H });
        expect(f.status).toBe(200);
        expect(f.headers.get("content-length")).toBe("4000");
        expect(f.headers.get("x-file-bytes")).toBe("4000");
        expect(new Uint8Array(await f.arrayBuffer())).toEqual(new Uint8Array(4000).fill(7));
        expect((await fetch(`${base}/fetch/ok1/thumb`, { headers: H })).status).toBe(404);
        expect((await fetch(`${base}/fetch/ok1`, { method: "DELETE", headers: H })).status).toBe(200);
        expect((await fetch(`${base}/fetch/ok1`, { headers: H })).status).toBe(404);
        expect(existsSync(join(dir, "jobs", "ok1"))).toBe(false);
    });

    it("failures carry a code", async () => {
        await start("e1", "https://a.test/unsupported");
        expect(await poll("e1")).toEqual({ status: "error", error: { code: "error.api.link.unsupported" } });
        await start("e2", "https://www.youtube.com/watch?v=private");
        expect(await poll("e2")).toEqual({ status: "error", error: { code: "error.api.content.video.private" } });
        await start("e3", "https://a.test/big");
        expect(await poll("e3")).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        expect((await fetch(`${base}/fetch/e3/file`, { headers: H })).status).toBe(409);
    });

    it("one fetch at a time: another id is 429 while one runs; a hung one times out", async () => {
        expect((await start("s1", "https://a.test/slow")).status).toBe(202);
        expect((await start("s2", "https://www.youtube.com/watch?v=ok")).status).toBe(429);
        expect(await poll("s1")).toEqual({ status: "error", error: { code: "error.webp.timeout" } });
        expect((await start("s2", "https://www.youtube.com/watch?v=ok")).status).toBe(202);
        expect((await poll("s2")).status).toBe("done");
    });
});
