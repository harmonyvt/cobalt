import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
    JobError,
    buildFrameArgs,
    buildImg2webpArgs,
    downloadToFile,
    encodeAnimatedWebp,
    keyMatches,
    parseDuration,
    parseWebp,
    planClip,
    resolveSource,
    rewriteMediaUrl,
    serviceFromUrl,
    validateJobInput,
} from "../helper/lib.js";

const ID = "aB3dE6gH9jK2mN5pQ8sT";
const good = { id: ID, url: "https://twitter.com/X/status/1", start: 0, length: 6, width: 480, fps: 15, quality: "med" };

describe("keyMatches", () => {
    it("matches only the exact key", () => {
        expect(keyMatches("secret", "secret")).toBe(true);
        expect(keyMatches("secreT", "secret")).toBe(false);
        expect(keyMatches("secret ", "secret")).toBe(false);
        expect(keyMatches("", "secret")).toBe(false);
        expect(keyMatches(undefined, "secret")).toBe(false);
    });
    it("refuses everything when the expected key is unset", () => {
        expect(keyMatches("", "")).toBe(false);
        expect(keyMatches("x", undefined)).toBe(false);
    });
});

describe("validateJobInput", () => {
    it("accepts the DO's payload", () => {
        expect(validateJobInput(good)).toEqual(good);
    });
    it("length is optional: absent or null means to the end of the video", () => {
        const { length: _l, ...noLen } = good;
        expect(validateJobInput(noLen)).toEqual(noLen);
        expect(validateJobInput({ ...good, length: null })).toEqual(noLen);
        expect(validateJobInput({ ...good, length: 600 })).toMatchObject({ length: 600 });
    });
    it.each([
        ["no id", { ...good, id: undefined }],
        ["short id", { ...good, id: "abc" }],
        ["id with a slash", { ...good, id: "../../etc/passwd/aaaa" }],
        ["file url", { ...good, url: "file:///etc/passwd" }],
        ["bad width", { ...good, width: 500 }],
        ["bad fps", { ...good, fps: 30 }],
        ["length below 1", { ...good, length: 0.5 }],
        ["length over 600", { ...good, length: 601 }],
        ["length not a number", { ...good, length: "abc" }],
        ["bad start", { ...good, start: -1 }],
        ["bad quality", { ...good, quality: "max" }],
        ["null", null],
    ])("rejects %s", (_n, b) => {
        expect(validateJobInput(b)).toBeNull();
    });
});

describe("buildFrameArgs", () => {
    const base = { input: "/tmp/webp/x/in", framesDir: "/tmp/webp/x/frames", start: 0, length: 6, width: 480, fps: 15 };
    const args = buildFrameArgs(base);
    const at = (flag: string) => args[args.indexOf(flag) + 1];

    it("decodes to numbered PNG frames, never upscaling", () => {
        expect(args.slice(0, 6)).toEqual(["-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe"]);
        expect(at("-vf")).toBe("fps=15,scale='min(480,iw)':-2:flags=lanczos");
        expect(at("-f")).toBe("image2");
        expect(args).toContain("-an");
        expect(args).not.toContain("-c:v"); // no WebP encoder in this step any more
        expect(args.at(-1)).toBe("/tmp/webp/x/frames/f%05d.png");
    });
    it("puts -ss and -t before -i (input options) and the output last", () => {
        const i = args.indexOf("-i");
        expect(args.indexOf("-ss")).toBeLessThan(i);
        expect(args.indexOf("-t")).toBeLessThan(i);
        expect(args.indexOf("-protocol_whitelist")).toBeLessThan(i);
        expect(args[i + 1]).toBe(base.input);
    });
    it("formats start/length/width/fps", () => {
        const a = buildFrameArgs({ ...base, start: 12.5, length: 3, width: 640, fps: 25 });
        expect(a[a.indexOf("-ss") + 1]).toBe("12.5");
        expect(a[a.indexOf("-t") + 1]).toBe("3");
        expect(a[a.indexOf("-vf") + 1]).toBe("fps=25,scale='min(640,iw)':-2:flags=lanczos");
        const tiny = buildFrameArgs({ ...base, start: 1e-7 });
        expect(tiny[tiny.indexOf("-ss") + 1]).toBe("0");
    });
    it("passes -t only when a length is given", () => {
        expect(args.includes("-t")).toBe(true);
        const { length: _l, ...noLen } = base;
        const a = buildFrameArgs(noLen);
        expect(a.includes("-t")).toBe(false);
        expect(a[a.indexOf("-ss") + 1]).toBe("0");
        expect(a[a.indexOf("-ss") + 2]).toBe("-i");
    });
    it("formats a fractional effective clip", () => {
        const a = buildFrameArgs({ ...base, length: 5.9994999 });
        expect(a[a.indexOf("-t") + 1]).toBe("5.999");
    });
});

describe("buildImg2webpArgs", () => {
    const frames = ["f00001.png", "f00002.png", "f00003.png"];
    const base = { frames, output: "/tmp/webp/x/out.webp", fps: 15, quality: "med" as const };
    const args = buildImg2webpArgs(base);

    it("is the measured command line: lossy, forced keyframes every 3 to 5 frames", () => {
        expect(args.slice(0, 13)).toEqual(["-loop", "0", "-d", "67", "-lossy", "-q", "75", "-m", "4", "-kmin", "3", "-kmax", "5"]);
        expect(args.at(-2)).toBe("-o");
        expect(args.at(-1)).toBe(base.output);
    });
    it("passes the frames in order, after the per-frame options, as given (relative names)", () => {
        expect(args.slice(13, -2)).toEqual(frames);
        expect(args.slice(13, -2).every((f) => !f.includes("/"))).toBe(true);
    });
    it("maps quality low/med/high to 65/75/85", () => {
        for (const [q, v] of [["low", "65"], ["med", "75"], ["high", "85"]] as const) {
            const a = buildImg2webpArgs({ ...base, quality: q });
            expect(a[a.indexOf("-q") + 1]).toBe(v);
        }
    });
    it("derives -d from fps as round(1000 / fps)", () => {
        for (const [fps, d] of [[10, "100"], [12, "83"], [15, "67"], [20, "50"], [24, "42"], [25, "40"]] as const) {
            const a = buildImg2webpArgs({ ...base, fps });
            expect(a[a.indexOf("-d") + 1]).toBe(d);
        }
    });
    it("keeps the argv small for the longest job (60 s x 25 fps, relative names)", () => {
        const many = Array.from({ length: 1500 }, (_, i) => `f${String(i + 1).padStart(5, "0")}.png`);
        const bytes = buildImg2webpArgs({ ...base, frames: many, fps: 25 }).reduce((n, a) => n + a.length + 1, 0);
        expect(bytes).toBeLessThan(20_000);
    });
});

describe("encodeAnimatedWebp (stubbed spawn)", () => {
    const root = mkdtempSync(join(tmpdir(), "webp-enc-"));
    afterAll(() => rmSync(root, { recursive: true, force: true }));

    type Call = { bin: string; args: string[]; cwd?: string };
    type SpawnFn = typeof import("node:child_process").spawn;
    // A fake child: `behave` runs on spawn and returns the exit code, or "hang".
    function harness(behave: (c: Call) => number | "hang") {
        const calls: Call[] = [];
        const killed: string[] = [];
        const spawnImpl = ((bin: string, args: string[], opts: { cwd?: string }) => {
            const call = { bin, args, cwd: opts.cwd };
            calls.push(call);
            const child: any = new EventEmitter();
            child.stderr = new EventEmitter();
            child.kill = (sig: string) => {
                killed.push(sig);
                queueMicrotask(() => child.emit("close", null));
            };
            const r = behave(call);
            if (r !== "hang") {
                queueMicrotask(() => {
                    child.stderr.emit("data", "some stderr");
                    child.emit("close", r);
                });
            }
            return child;
        }) as unknown as SpawnFn;
        return { calls, killed, spawnImpl };
    }
    const job = (name: string) => ({
        ffmpegBin: "ffmpeg",
        img2webpBin: "img2webp",
        input: join(root, name, "in"),
        output: join(root, name, "out.webp"),
        framesDir: join(root, name, "frames"),
        start: 0,
        length: 1,
        width: 480,
        fps: 15,
        quality: "med" as const,
        timeoutMs: 5000,
    });
    // ffmpeg stub: writes n frames into the dir its output pattern names
    const writeFrames = (c: Call, n: number) => {
        const dir = c.args.at(-1)!.replace(/\/f%05d\.png$/, "");
        for (let i = 1; i <= n; i++) writeFileSync(join(dir, `f${String(i).padStart(5, "0")}.png`), Buffer.alloc(100));
    };

    it("runs ffmpeg then img2webp (relative frame names, cwd = frames dir) and removes the frames", async () => {
        const j = job("ok");
        const h = harness((c) => {
            if (c.bin === "ffmpeg") writeFrames(c, 3);
            else writeFileSync(j.output, "webp");
            return 0;
        });
        const r = await encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl });
        expect(r).toEqual({ frames: 3, frameBytes: 300 });
        expect(h.calls.map((c) => c.bin)).toEqual(["ffmpeg", "img2webp"]);
        expect(h.calls[1].cwd).toBe(j.framesDir);
        expect(h.calls[1].args.slice(13, 16)).toEqual(["f00001.png", "f00002.png", "f00003.png"]);
        expect(h.calls[1].args.at(-1)).toBe(j.output);
        expect(existsSync(j.framesDir)).toBe(false);
        expect(existsSync(j.output)).toBe(true);
    });
    it("onPhase: decode (with the expected count) fires before ffmpeg, pack (with the real count) after the frames are listed and before img2webp", async () => {
        const j = { ...job("phases"), length: 2, fps: 15 };
        const order: string[] = [];
        const h = harness((c) => {
            order.push(`spawn ${c.bin}`);
            if (c.bin === "ffmpeg") writeFrames(c, 31); // ffmpeg made one more than 2 s * 15 fps
            else writeFileSync(j.output, "webp");
            return 0;
        });
        await encodeAnimatedWebp({
            ...j,
            spawnImpl: h.spawnImpl,
            onPhase: (phase, info) => order.push(`${phase} ${JSON.stringify(info)}`),
        });
        expect(order).toEqual([
            'decode {"total":30}',
            "spawn ffmpeg",
            'pack {"frames":31}',
            "spawn img2webp",
        ]);
    });
    it("onPhase: the expected count is at least 1, and null when no length is given", async () => {
        const seen: unknown[] = [];
        const run = async (name: string, extra: Record<string, unknown>) => {
            const j = { ...job(name), ...extra } as ReturnType<typeof job> & { length?: number };
            const h = harness((c) => {
                if (c.bin === "ffmpeg") writeFrames(c, 1);
                else writeFileSync(j.output, "webp");
                return 0;
            });
            await encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl, onPhase: (p, i) => p === "decode" && seen.push(i) });
        };
        await run("tiny", { length: 0.01, fps: 10 });
        await run("nolen", { length: undefined });
        expect(seen).toEqual([{ total: 1 }, { total: null }]);
    });
    it("onPhase: a failing ffmpeg reports decode but never pack", async () => {
        const j = job("phasefail");
        const phases: string[] = [];
        const h = harness(() => 1);
        await expect(
            encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl, onPhase: (p) => phases.push(p) }),
        ).rejects.toMatchObject({ code: "error.webp.encode_failed" });
        expect(phases).toEqual(["decode"]);
    });
    it("img2webp exiting non-zero is encode_failed and the frames are still removed", async () => {
        const j = job("i2wfail");
        const h = harness((c) => {
            if (c.bin === "ffmpeg") {
                writeFrames(c, 2);
                return 0;
            }
            return 1;
        });
        await expect(encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl })).rejects.toMatchObject({ code: "error.webp.encode_failed" });
        expect(existsSync(j.framesDir)).toBe(false);
    });
    it("ffmpeg failing is encode_failed, img2webp never runs, frames removed", async () => {
        const j = job("fffail");
        const h = harness((c) => {
            writeFrames(c, 1);
            return 1;
        });
        await expect(encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl })).rejects.toMatchObject({ code: "error.webp.encode_failed" });
        expect(h.calls.map((c) => c.bin)).toEqual(["ffmpeg"]);
        expect(existsSync(j.framesDir)).toBe(false);
    });
    it("no frames is encode_failed", async () => {
        const j = job("noframes");
        const h = harness(() => 0);
        await expect(encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl })).rejects.toMatchObject({ code: "error.webp.encode_failed" });
        expect(h.calls).toHaveLength(1);
        expect(existsSync(j.framesDir)).toBe(false);
    });
    it("a hung process is killed at the deadline: timeout, frames removed", async () => {
        const j = { ...job("hang"), timeoutMs: 50 };
        const h = harness((c) => {
            if (c.bin === "ffmpeg") {
                writeFrames(c, 1);
                return 0;
            }
            return "hang";
        });
        await expect(encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl })).rejects.toMatchObject({ code: "error.webp.timeout" });
        expect(h.killed).toEqual(["SIGKILL"]);
        expect(existsSync(j.framesDir)).toBe(false);
    });
    it("the budget is shared: img2webp only gets what ffmpeg left", async () => {
        const j = { ...job("budget"), timeoutMs: 120 };
        const h = harness((c) => {
            if (c.bin === "ffmpeg") writeFrames(c, 1);
            return c.bin === "ffmpeg" ? 0 : "hang";
        });
        const t0 = Date.now();
        await expect(encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl })).rejects.toMatchObject({ code: "error.webp.timeout" });
        expect(Date.now() - t0).toBeLessThan(400);
    });
    it("a missing binary (spawn error event) is encode_failed", async () => {
        const j = job("enoent");
        const spawnImpl = (() => {
            const child: any = new EventEmitter();
            child.stderr = new EventEmitter();
            child.kill = () => {};
            queueMicrotask(() => child.emit("error", new Error("ENOENT")));
            return child;
        }) as unknown as SpawnFn;
        await expect(encodeAnimatedWebp({ ...j, spawnImpl })).rejects.toMatchObject({ code: "error.webp.encode_failed" });
        expect(existsSync(j.framesDir)).toBe(false);
    });
    it("reports the running child through onChild and clears it on exit", async () => {
        const j = job("onchild");
        const seen: unknown[] = [];
        const h = harness((c) => {
            if (c.bin === "ffmpeg") writeFrames(c, 1);
            return 0;
        });
        await encodeAnimatedWebp({ ...j, spawnImpl: h.spawnImpl, onChild: (c) => seen.push(c) });
        expect(seen.map((c) => c === undefined)).toEqual([false, true, false, true]);
    });
});

describe("parseDuration", () => {
    const wrap = (line: string) =>
        `Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/tmp/webp/x/in':\n  Metadata:\n    major_brand     : isom\n${line}\n  Stream #0:0[0x1](und): Video: h264, yuv420p, 1280x720, 30 fps\nAt least one output file must be specified\n`;
    it.each([
        ["short mp4", "  Duration: 00:00:06.02, start: 0.000000, bitrate: 1013 kb/s", 6.02],
        ["minutes", "  Duration: 00:01:30.50, start: 0.000000, bitrate: 900 kb/s", 90.5],
        ["hours", "  Duration: 01:02:03.25, start: 0.000000, bitrate: 900 kb/s", 3723.25],
        ["no fraction", "  Duration: 00:00:10, start: 0.000000", 10],
        ["spacing", "Duration:00:00:03.00, start", 3],
    ])("%s", (_n, line, secs) => {
        expect(parseDuration(wrap(line))).toBeCloseTo(secs, 5);
    });
    it.each([
        ["N/A", "  Duration: N/A, start: 0.000000, bitrate: N/A"],
        ["absent", "  Stream #0:0: Video: h264"],
        ["zero", "  Duration: 00:00:00.00, start: 0.000000"],
    ])("null for %s", (_n, line) => {
        expect(parseDuration(wrap(line))).toBeNull();
    });
    it("null for empty stderr", () => {
        expect(parseDuration("")).toBeNull();
    });
});

describe("planClip", () => {
    const ok = (seconds: number, truncated = false) => ({ ok: true, seconds, truncated });
    it("whole video by default", () => {
        expect(planClip({ start: 0, duration: 6.02, maxSeconds: 60 })).toEqual(ok(6.02));
    });
    it("start trims the front", () => {
        const p = planClip({ start: 2, duration: 6.02, maxSeconds: 60 });
        expect(p.ok && p.seconds).toBeCloseTo(4.02, 5);
    });
    it("length shorter than the remainder wins", () => {
        expect(planClip({ start: 2, length: 2, duration: 6.02, maxSeconds: 60 })).toEqual(ok(2));
    });
    it("length longer than the remainder is clamped to it", () => {
        const p = planClip({ start: 5, length: 30, duration: 6, maxSeconds: 60 });
        expect(p).toEqual(ok(1));
    });
    it("start at or past the end is invalid_params", () => {
        expect(planClip({ start: 6, duration: 6, maxSeconds: 60 })).toEqual({ ok: false, code: "error.webp.invalid_params" });
        expect(planClip({ start: 100, length: 5, duration: 6, maxSeconds: 60 })).toEqual({ ok: false, code: "error.webp.invalid_params" });
    });
    it("a clip over the max is too_long (no encode)", () => {
        expect(planClip({ start: 0, duration: 61.5, maxSeconds: 60 })).toEqual({ ok: false, code: "error.webp.too_long" });
        expect(planClip({ start: 0, duration: 6, maxSeconds: 3 })).toEqual({ ok: false, code: "error.webp.too_long" });
        expect(planClip({ start: 0, length: 90, duration: 300, maxSeconds: 60 })).toEqual({ ok: false, code: "error.webp.too_long" });
    });
    it("trimming a long video down under the max is fine", () => {
        expect(planClip({ start: 0, length: 45, duration: 3600, maxSeconds: 60 })).toEqual(ok(45));
        expect(planClip({ start: 3590, duration: 3600, maxSeconds: 60 })).toEqual(ok(10));
    });
    it("tolerates a few hundredths over the max and clamps -t to it", () => {
        expect(planClip({ start: 0, duration: 60.03, maxSeconds: 60 })).toEqual(ok(60));
        expect(planClip({ start: 0, duration: 60.5, maxSeconds: 60 }).ok).toBe(true);
        expect(planClip({ start: 0, duration: 60.51, maxSeconds: 60 }).ok).toBe(false);
    });
    it("unknown duration: hard stop at the max, or the given length", () => {
        expect(planClip({ start: 0, duration: null, maxSeconds: 60 })).toEqual(ok(60, true));
        expect(planClip({ start: 0, length: 12, duration: null, maxSeconds: 60 })).toEqual(ok(12));
        expect(planClip({ start: 0, length: 90, duration: null, maxSeconds: 60 })).toEqual({ ok: false, code: "error.webp.too_long" });
    });
    it("defaults to WEBP_MAX_SECONDS (60) when no max is passed", () => {
        expect(planClip({ start: 0, duration: 59 }).ok).toBe(true);
        expect(planClip({ start: 0, duration: 120 }).ok).toBe(false);
    });
});

describe("rewriteMediaUrl", () => {
    const api = "https://api.capybaraharmony.com";
    const q = "?id=abc&exp=1&sig=s&sec=c&iv=i";
    it("rewrites a tunnel URL on the public API origin to the local origin", () => {
        expect(rewriteMediaUrl(`${api}/tunnel${q}`, { apiOrigin: api })).toBe(`http://127.0.0.1:9000/tunnel${q}`);
    });
    it("keeps an already-local tunnel URL", () => {
        expect(rewriteMediaUrl(`http://127.0.0.1:9000/tunnel${q}`)).toBe(`http://127.0.0.1:9000/tunnel${q}`);
    });
    it("refuses a /tunnel path on any other host", () => {
        expect(rewriteMediaUrl(`https://evil.example/tunnel${q}`, { apiOrigin: api })).toBeNull();
        expect(rewriteMediaUrl(`${api}/tunnel${q}`)).toBeNull(); // apiOrigin unknown
    });
    it("tunnelOnly refuses ordinary URLs", () => {
        expect(rewriteMediaUrl("https://cdn.example/v.mp4", { tunnelOnly: true })).toBeNull();
    });
    it("passes public http(s) URLs (redirect items)", () => {
        expect(rewriteMediaUrl("https://video.twimg.com/a/b.mp4?tag=12")).toBe("https://video.twimg.com/a/b.mp4?tag=12");
    });
    it.each([
        "file:///etc/passwd",
        "ftp://x.test/a",
        "javascript:alert(1)",
        "http://127.0.0.1:9100/jobs",
        "http://localhost:9000/",
        "http://10.0.0.5/a",
        "http://172.16.3.4/a",
        "http://192.168.1.1/a",
        "http://169.254.169.254/latest",
        "http://[::1]:9100/",
        "http://[fd00::1]/",
        "http://metadata.internal/x",
        "https://user:pw@cdn.example/v.mp4",
        "not a url",
    ])("refuses %s", (u) => {
        expect(rewriteMediaUrl(u)).toBeNull();
    });
    it("does not mistake ordinary hostnames for private ranges", () => {
        expect(rewriteMediaUrl("https://10.example.com/a")).not.toBeNull();
        expect(rewriteMediaUrl("https://fdn.example.com/a")).not.toBeNull();
        expect(rewriteMediaUrl("http://172.32.0.1/a")).not.toBeNull();
    });
});

describe("resolveSource (stubbed cobalt)", () => {
    const api = "https://api.capybaraharmony.com";
    const stub = (body: unknown, status = 200) => {
        const calls: { url: string; init: RequestInit }[] = [];
        const fetchImpl = (async (url: string, init: RequestInit) => {
            calls.push({ url, init });
            return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
        }) as unknown as typeof fetch;
        return { fetchImpl, calls };
    };
    const run = (body: unknown, status?: number) => {
        const s = stub(body, status);
        return { s, p: resolveSource({ url: good.url, internalKey: "K", fetchImpl: s.fetchImpl, apiOrigin: api }) };
    };
    const code = async (p: Promise<unknown>) => {
        try {
            await p;
        } catch (e) {
            expect(e).toBeInstanceOf(JobError);
            return (e as JobError).code;
        }
        throw new Error("did not throw");
    };

    it("sends the documented request to the local cobalt with the internal key", async () => {
        const { s, p } = run({ status: "tunnel", url: `${api}/tunnel?id=1`, filename: "clip.mp4" });
        await p;
        expect(s.calls).toHaveLength(1);
        expect(s.calls[0].url).toBe("http://127.0.0.1:9000/");
        expect(s.calls[0].init.method).toBe("POST");
        expect(s.calls[0].init.headers).toEqual({
            authorization: "Api-Key K",
            accept: "application/json",
            "content-type": "application/json",
        });
        expect(JSON.parse(String(s.calls[0].init.body))).toEqual({ url: good.url, alwaysProxy: true, videoQuality: "720" });
    });
    it("tunnel: rewrites to the local origin and keeps the filename", async () => {
        const { p } = run({ status: "tunnel", url: `${api}/tunnel?id=1&exp=2`, filename: "clip.mp4" });
        expect(await p).toEqual({ url: "http://127.0.0.1:9000/tunnel?id=1&exp=2", filename: "clip.mp4" });
    });
    it("tunnel: refuses a URL that is not a tunnel on our origin", async () => {
        expect(await code(run({ status: "tunnel", url: "https://evil.example/tunnel?id=1" }).p)).toBe("error.webp.bad_source");
        expect(await code(run({ status: "tunnel", url: "https://cdn.example/v.mp4" }).p)).toBe("error.webp.bad_source");
        expect(await code(run({ status: "tunnel" }).p)).toBe("error.webp.bad_source");
    });
    it("redirect: uses the (public) url as is", async () => {
        expect(await run({ status: "redirect", url: "https://cdn.example/v.mp4", filename: "v.mp4" }).p).toEqual({
            url: "https://cdn.example/v.mp4",
            filename: "v.mp4",
        });
        expect(await code(run({ status: "redirect", url: "http://127.0.0.1:9100/x" }).p)).toBe("error.webp.bad_source");
    });
    it("picker: first video item, tunnel URLs rewritten", async () => {
        const r = await run({
            status: "picker",
            picker: [
                { type: "photo", url: "https://cdn.example/p.jpg" },
                { type: "video", url: `${api}/tunnel?id=A` },
                { type: "video", url: `${api}/tunnel?id=B` },
            ],
        }).p;
        expect(r.url).toBe("http://127.0.0.1:9000/tunnel?id=A");
    });
    it("picker: falls back to a gif item, else no_video", async () => {
        const r = await run({ status: "picker", picker: [{ type: "photo", url: "https://c.example/p.jpg" }, { type: "gif", url: "https://c.example/g.mp4" }] }).p;
        expect(r.url).toBe("https://c.example/g.mp4");
        expect(await code(run({ status: "picker", picker: [{ type: "photo", url: "https://c.example/p.jpg" }] }).p)).toBe("error.webp.no_video");
        expect(await code(run({ status: "picker", picker: [] }).p)).toBe("error.webp.no_video");
        expect(await code(run({ status: "picker" }).p)).toBe("error.webp.no_video");
    });
    it("error: passes cobalt's error code straight through", async () => {
        expect(await code(run({ status: "error", error: { code: "error.api.link.unsupported", context: { service: "x" } } }, 400).p)).toBe(
            "error.api.link.unsupported",
        );
        expect(await code(run({ status: "error", error: { code: "error.api.content.video.unavailable" } }, 400).p)).toBe(
            "error.api.content.video.unavailable",
        );
        expect(await code(run({ status: "error" }).p)).toBe("error.webp.upstream");
    });
    it("local-processing: unsupported", async () => {
        expect(await code(run({ status: "local-processing", type: "merge" }).p)).toBe("error.webp.unsupported");
    });
    it("garbage, unknown status and network failure: upstream", async () => {
        expect(await code(run("<html>").p)).toBe("error.webp.upstream");
        expect(await code(run({ status: "weird" }).p)).toBe("error.webp.upstream");
        expect(
            await code(resolveSource({ url: good.url, internalKey: "K", fetchImpl: (async () => { throw new Error("down"); }) as unknown as typeof fetch })),
        ).toBe("error.webp.upstream");
    });
});

describe("downloadToFile", () => {
    const dir = mkdtempSync(join(tmpdir(), "webp-dl-"));
    afterAll(() => rmSync(dir, { recursive: true, force: true }));
    const respond = (bytes: Uint8Array, init: ResponseInit = {}) =>
        (async () => new Response(bytes, init)) as unknown as typeof fetch;

    it("writes the body to disk and reports the size", async () => {
        const dest = join(dir, "ok");
        const data = new Uint8Array(5000).map((_, i) => i % 251);
        const n = await downloadToFile({ url: "http://x/", dest, fetchImpl: respond(data) });
        expect(n).toBe(5000);
        expect(Buffer.compare(readFileSync(dest), Buffer.from(data))).toBe(0);
    });
    describe("onProgress", () => {
        const chunks = (sizes: number[], init: ResponseInit = {}) => {
            let i = 0;
            const stream = new ReadableStream<Uint8Array>({
                async pull(c) {
                    if (i >= sizes.length) return c.close();
                    // a tick between chunks, so the pipeline delivers them one by one
                    await new Promise((r) => setTimeout(r, 1));
                    c.enqueue(new Uint8Array(sizes[i++]));
                },
            });
            return (async () => new Response(stream, init)) as unknown as typeof fetch;
        };

        it("reports bytes so far with the content-length as total, throttled to 256 KB, and a final report with the full size", async () => {
            const seen: [number, number | null][] = [];
            const sizes = Array.from({ length: 10 }, () => 100 * 1024); // ten 100 KB chunks = 1000 KB
            const n = await downloadToFile({
                url: "http://x/",
                dest: join(dir, "prog"),
                fetchImpl: chunks(sizes, { headers: { "content-length": String(1000 * 1024) } }),
                onProgress: (b, t) => seen.push([b, t]),
            });
            expect(n).toBe(1000 * 1024);
            // every report carries the total, bytes only grow, and the last one is the whole file
            expect(seen.every(([, t]) => t === 1000 * 1024)).toBe(true);
            expect(seen.map(([b]) => b)).toEqual([...seen.map(([b]) => b)].sort((a, b) => a - b));
            expect(seen.at(-1)).toEqual([1000 * 1024, 1000 * 1024]);
            // throttled: at least 256 KB between two reports (the final one aside), so far fewer than 10
            const mid = seen.slice(0, -1).map(([b]) => b);
            for (let i = 1; i < mid.length; i++) expect(mid[i] - mid[i - 1]).toBeGreaterThanOrEqual(256 * 1024);
            expect(seen.length).toBeLessThanOrEqual(5);
        });
        it("total is null when the response has no content-length", async () => {
            const seen: [number, number | null][] = [];
            await downloadToFile({
                url: "http://x/",
                dest: join(dir, "prog2"),
                fetchImpl: chunks([1000, 1000]),
                onProgress: (b, t) => seen.push([b, t]),
            });
            expect(seen.length).toBeGreaterThanOrEqual(1);
            expect(seen.every(([, t]) => t === null)).toBe(true);
            expect(seen.at(-1)![0]).toBe(2000);
        });
        it("reports at least every 250 ms even for small chunks", async () => {
            const seen: number[] = [];
            const slow = (async () => {
                let i = 0;
                return new Response(
                    new ReadableStream<Uint8Array>({
                        async pull(c) {
                            if (i++ >= 3) return c.close();
                            await new Promise((r) => setTimeout(r, 300));
                            c.enqueue(new Uint8Array(10));
                        },
                    }),
                );
            }) as unknown as typeof fetch;
            await downloadToFile({ url: "http://x/", dest: join(dir, "prog3"), fetchImpl: slow, onProgress: (b) => seen.push(b) });
            expect(seen.slice(0, 3)).toEqual([10, 20, 30]); // one per chunk, each 300 ms apart
        });
        it("a throwing callback never fails the download", async () => {
            const n = await downloadToFile({
                url: "http://x/",
                dest: join(dir, "prog4"),
                fetchImpl: respond(new Uint8Array(500)),
                onProgress: () => {
                    throw new Error("boom");
                },
            });
            expect(n).toBe(500);
        });
        it("no report for a download that fails", async () => {
            const seen: number[] = [];
            await expect(
                downloadToFile({
                    url: "http://x/",
                    dest: join(dir, "prog5"),
                    maxBytes: 1000,
                    fetchImpl: chunks([600, 600]),
                    onProgress: (b) => seen.push(b),
                }),
            ).rejects.toMatchObject({ code: "error.webp.too_large" });
            expect(seen.at(-1) ?? 0).toBeLessThanOrEqual(600);
        });
    });

    it("too_large when the body outgrows the cap (no content-length)", async () => {
        const dest = join(dir, "big");
        const stream = new ReadableStream({
            start(c) {
                c.enqueue(new Uint8Array(600));
                c.enqueue(new Uint8Array(600));
                c.close();
            },
        });
        const fetchImpl = (async () => new Response(stream)) as unknown as typeof fetch;
        await expect(downloadToFile({ url: "http://x/", dest, maxBytes: 1000, fetchImpl })).rejects.toMatchObject({ code: "error.webp.too_large" });
    });
    it("too_large straight from content-length", async () => {
        const dest = join(dir, "declared");
        const fetchImpl = (async () => new Response(new Uint8Array(10), { headers: { "content-length": "999999" } })) as unknown as typeof fetch;
        await expect(downloadToFile({ url: "http://x/", dest, maxBytes: 1000, fetchImpl })).rejects.toMatchObject({ code: "error.webp.too_large" });
        expect(existsSync(dest)).toBe(false);
    });
    it("download_failed on a non-2xx status or a network error", async () => {
        await expect(downloadToFile({ url: "http://x/", dest: join(dir, "a"), fetchImpl: respond(new Uint8Array(1), { status: 404 }) })).rejects.toMatchObject({
            code: "error.webp.download_failed",
        });
        await expect(
            downloadToFile({ url: "http://x/", dest: join(dir, "b"), fetchImpl: (async () => { throw new Error("reset"); }) as unknown as typeof fetch }),
        ).rejects.toMatchObject({ code: "error.webp.download_failed" });
    });
    it("timeout when aborted", async () => {
        const fetchImpl = (async () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); }) as unknown as typeof fetch;
        await expect(downloadToFile({ url: "http://x/", dest: join(dir, "c"), fetchImpl })).rejects.toMatchObject({ code: "error.webp.timeout" });
    });
});

// A minimal animated WebP: RIFF/WEBP + VP8X (animation flag) + ANIM + 3 ANMF of 40/60/70 ms.
function chunk(fourcc: string, payload: Buffer) {
    const head = Buffer.alloc(8);
    head.write(fourcc, 0, "latin1");
    head.writeUInt32LE(payload.length, 4);
    return Buffer.concat([head, payload, payload.length & 1 ? Buffer.alloc(1) : Buffer.alloc(0)]);
}
function fakeAnimatedWebp(w: number, h: number, durations: number[]) {
    const vp8x = Buffer.alloc(10);
    vp8x[0] = 0x02;
    vp8x.writeUIntLE(w - 1, 4, 3);
    vp8x.writeUIntLE(h - 1, 7, 3);
    const anim = Buffer.alloc(6);
    const anmf = durations.map((d) => {
        const p = Buffer.alloc(17);
        p.writeUIntLE(d, 12, 3);
        return chunk("ANMF", p);
    });
    const body = Buffer.concat([Buffer.from("WEBP", "latin1"), chunk("VP8X", vp8x), chunk("ANIM", anim), ...anmf]);
    const riff = Buffer.alloc(8);
    riff.write("RIFF", 0, "latin1");
    riff.writeUInt32LE(body.length, 4);
    return Buffer.concat([riff, body]);
}

describe("parseWebp", () => {
    it("reads canvas size, animation flag, frame count and duration", () => {
        expect(parseWebp(fakeAnimatedWebp(480, 270, [40, 60, 70]))).toEqual({
            width: 480,
            height: 270,
            animated: true,
            frames: 3,
            durationMs: 170,
        });
    });
    it("returns null for anything that is not a WebP", () => {
        expect(parseWebp(Buffer.from("GIF89a....................", "latin1"))).toBeNull();
        expect(parseWebp(Buffer.alloc(4))).toBeNull();
        expect(parseWebp(Buffer.from("RIFF0000WAVEfmt ", "latin1"))).toBeNull();
    });
    it("survives a truncated file", () => {
        const full = fakeAnimatedWebp(320, 180, [50, 50]);
        expect(parseWebp(full.subarray(0, full.length - 10))).toMatchObject({ width: 320, animated: true });
    });
});

describe("serviceFromUrl (helper)", () => {
    it("matches the DO's rule", () => {
        expect(serviceFromUrl("https://www.twitter.com/x")).toBe("twitter");
        expect(serviceFromUrl("nope")).toBe("unknown");
    });
});
