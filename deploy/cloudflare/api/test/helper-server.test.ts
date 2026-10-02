// The helper's HTTP API (helper/server.js) with cobalt, the network, ffmpeg and
// img2webp stubbed: argument handling, one-job-at-a-time, the 200 MB cap and
// cleanup. The real ffmpeg/img2webp path is exercised in the docker run (README).
import http from "node:http";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { mkdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeEach, describe, expect, it } from "vitest";
import { createHelper } from "../helper/server.js";
import {
    JobError,
    MAX_FETCH_BYTES,
    downloadToFile,
    parseVideoInfo,
    studioCode,
    titleFromFilename,
    validateEncodeFields,
    validateFetchInput,
    videoExt,
} from "../helper/lib.js";

const KEY = "internal-key";
const FID = "aB3dE6gH9jK2mN5pQ8sTuV"; // 22
const JID = "aB3dE6gH9jK2mN5pQ8sT"; // 20
const LINK = "https://x.com/maria_rcks/status/2105237035271258436";

const root = mkdtempSync(path.join(tmpdir(), "studio-helper-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// A minimal animated WebP (VP8X + ANIM + one ANMF of 67 ms) that parseWebp reads.
function tinyWebp(w = 480, h = 560) {
    const b = Buffer.alloc(12 + 18 + 14 + 8 + 16);
    b.write("RIFF", 0, "latin1");
    b.writeUInt32LE(b.length - 8, 4);
    b.write("WEBP", 8, "latin1");
    let o = 12;
    b.write("VP8X", o, "latin1");
    b.writeUInt32LE(10, o + 4);
    b[o + 8] = 0x02;
    b.writeUIntLE(w - 1, o + 12, 3);
    b.writeUIntLE(h - 1, o + 15, 3);
    o += 18;
    b.write("ANIM", o, "latin1");
    b.writeUInt32LE(6, o + 4);
    o += 14;
    b.write("ANMF", o, "latin1");
    b.writeUInt32LE(16, o + 4);
    b.writeUIntLE(67, o + 8 + 12, 3);
    return b;
}

type Ctl = {
    resolve: () => Promise<{ url: string; filename: string | null }>;
    download: (o: any) => Promise<number>;
    probe: () => Promise<{ duration: number | null; width: number | null; height: number | null }>;
    encode: (o: any) => Promise<{ frames: number; frameBytes: number }>;
    encodeCalls: any[];
    resolveCalls: any[];
};

let helper: ReturnType<typeof createHelper>;
let base: string;
let ctl: Ctl;
let dirs: { work: string; fetch: string; probe: string };

const startHelper = async (over: Record<string, unknown> = {}) => {
    ctl = {
        encodeCalls: [],
        resolveCalls: [],
        resolve: async () => ({ url: "http://127.0.0.1:1/v", filename: "twitter_2105237035271258436.mp4" }),
        download: async (o) => {
            await writeFile(o.dest, Buffer.alloc(1234, 1));
            o.onResponse?.(new Response(null, { headers: { "content-type": "video/mp4" } }));
            return 1234;
        },
        probe: async () => ({ duration: 9.6, width: 480, height: 560 }),
        encode: async (o) => {
            await mkdir(o.framesDir, { recursive: true });
            await writeFile(o.output, tinyWebp());
            return { frames: 5, frameBytes: 100 };
        },
    } as Ctl;
    const id = Math.random().toString(36).slice(2);
    dirs = { work: path.join(root, id, "webp"), fetch: path.join(root, id, "fetch"), probe: path.join(root, id, "probe") };
    helper = createHelper({
        internalKey: KEY,
        workDir: dirs.work,
        fetchDir: dirs.fetch,
        probeDir: dirs.probe,
        waitForCobalt: async () => {},
        ffmpegPath: () => "ffmpeg",
        img2webpPath: () => "img2webp",
        resolveSource: async (o: any) => {
            ctl.resolveCalls.push(o);
            return ctl.resolve();
        },
        downloadToFile: (o: any) => ctl.download(o),
        probe: () => ctl.probe(),
        encodeAnimatedWebp: async (o: any) => {
            ctl.encodeCalls.push(o);
            return ctl.encode(o);
        },
        ...over,
    });
    await new Promise<void>((r) => helper.server.listen(0, "127.0.0.1", () => r()));
    base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
};

beforeEach(() => startHelper());
afterEach(() => helper.close());

const call = (path_: string, init: RequestInit & { duplex?: string } = {}, key: string | null = KEY) =>
    fetch(`${base}${path_}`, {
        ...init,
        headers: { ...(key === null ? {} : { "x-internal-key": key }), ...(init.headers as any) },
    });
const json = async (r: Response) => (await r.json()) as any;
const post = (p: string, b: unknown) =>
    call(p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) });
const until = async (p: string, want = (b: any) => b.status !== "pending") => {
    for (let i = 0; i < 200; i++) {
        const b = await json(await call(p));
        if (want(b)) return b;
        await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error("timed out waiting for " + p);
};
// a download that stays pending until released
const gated = () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    return { gate, release };
};

const upload = (id: string, q: Record<string, string> = {}, body: BodyInit = Buffer.alloc(2000, 3), headers: Record<string, string> = {}) => {
    const params = new URLSearchParams({ id, start: "2", length: "5", width: "480", fps: "15", quality: "med", ...q });
    for (const [k, v] of [...params]) if (v === "") params.delete(k);
    return call(`/jobs/upload?${params}`, { method: "POST", body, headers: { "content-type": "application/octet-stream", ...headers }, duplex: "half" });
};

describe("auth", () => {
    it.each([
        ["POST", "/fetch"],
        ["GET", `/fetch/${FID}`],
        ["POST", `/jobs/upload?id=${JID}`],
        ["POST", `/probe?id=${JID}`],
    ])("403 %s %s without the internal key or with a wrong one", async (method, p) => {
        expect((await call(p, { method }, null)).status).toBe(403);
        expect((await call(p, { method }, "wrong")).status).toBe(403);
    });
});

describe("POST /fetch", () => {
    it.each([
        ["no id", { url: LINK }],
        ["short id", { id: "abc", url: LINK }],
        ["id with a slash", { id: "../../etc/passwd/aaaaaaaa", url: LINK }],
        ["no url", { id: FID }],
        ["ftp url", { id: FID, url: "ftp://a.test/x" }],
        ["file url", { id: FID, url: "file:///etc/passwd" }],
        ["url over 2048", { id: FID, url: "https://a.test/" + "x".repeat(2050) }],
        ["null", null],
    ])("400 for %s, nothing is created", async (_n, b) => {
        const res = await post("/fetch", b);
        expect(res.status).toBe(400);
        expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(helper.fetches.size).toBe(0);
    });
    it("400 for a body that is not JSON; 405 for GET /fetch", async () => {
        expect((await call("/fetch", { method: "POST", body: "nope" })).status).toBe(400);
        expect((await call("/fetch")).status).toBe(405);
    });

    it("202, resolves through cobalt with the internal key, downloads, probes, then done", async () => {
        const { gate, release } = gated();
        const inner = ctl.download;
        ctl.download = async (o) => {
            await gate;
            return inner(o);
        };
        const res = await post("/fetch", { id: FID, url: LINK });
        expect(res.status).toBe(202);
        expect(await json(res)).toEqual({ status: "pending", id: FID });
        expect(await json(await call(`/fetch/${FID}`))).toEqual({ status: "pending" });
        release();
        const done = await until(`/fetch/${FID}`);
        expect(done).toEqual({
            status: "done",
            bytes: 1234,
            contentType: "video/mp4",
            ext: "mp4",
            duration: 9.6,
            width: 480,
            height: 560,
            title: "twitter_2105237035271258436",
            service: "x",
        });
        expect(ctl.resolveCalls[0]).toMatchObject({ url: LINK, internalKey: KEY });
        expect(existsSync(path.join(dirs.fetch, FID, "in"))).toBe(true);
    });

    it("passes the 200 MB cap to the download", async () => {
        let seen: any;
        ctl.download = async (o) => {
            seen = o;
            await writeFile(o.dest, "x");
            return 1;
        };
        await post("/fetch", { id: FID, url: LINK });
        await until(`/fetch/${FID}`);
        expect(seen.maxBytes).toBe(200 * 1024 * 1024);
        expect(MAX_FETCH_BYTES).toBe(200 * 1024 * 1024);
    });

    it("serves the file with content-length and content-type once done, 409 before", async () => {
        const { gate, release } = gated();
        const inner = ctl.download;
        ctl.download = async (o) => {
            await gate;
            return inner(o);
        };
        await post("/fetch", { id: FID, url: LINK });
        expect((await call(`/fetch/${FID}/file`)).status).toBe(409);
        release();
        await until(`/fetch/${FID}`);
        const file = await call(`/fetch/${FID}/file`);
        expect(file.status).toBe(200);
        expect(file.headers.get("content-length")).toBe("1234");
        expect(file.headers.get("content-type")).toBe("video/mp4");
        expect(Buffer.from(await file.arrayBuffer())).toEqual(Buffer.alloc(1234, 1));
    });

    it("uses the download's content type for the extension (webm)", async () => {
        ctl.download = async (o) => {
            await writeFile(o.dest, "abc");
            o.onResponse(new Response(null, { headers: { "content-type": "video/webm; codecs=vp9" } }));
            return 3;
        };
        await post("/fetch", { id: FID, url: LINK });
        expect(await until(`/fetch/${FID}`)).toMatchObject({ status: "done", ext: "webm", contentType: "video/webm" });
    });

    it("keeps a null duration (unknown) and a null title", async () => {
        ctl.probe = async () => ({ duration: null, width: 320, height: 240 });
        ctl.resolve = async () => ({ url: "http://127.0.0.1:1/v", filename: null });
        await post("/fetch", { id: FID, url: LINK });
        expect(await until(`/fetch/${FID}`)).toMatchObject({ status: "done", duration: null, title: null });
    });

    it("DELETE removes the file, and the job is gone", async () => {
        await post("/fetch", { id: FID, url: LINK });
        await until(`/fetch/${FID}`);
        const dir = path.join(dirs.fetch, FID);
        expect(existsSync(dir)).toBe(true);
        const del = await call(`/fetch/${FID}`, { method: "DELETE" });
        expect(await json(del)).toEqual({ status: "success" });
        expect(existsSync(dir)).toBe(false);
        expect((await call(`/fetch/${FID}`)).status).toBe(404);
        expect(helper.fetches.size).toBe(0);
    });

    it("404 for unknown, malformed or non-GET routes", async () => {
        expect((await call(`/fetch/${FID}`)).status).toBe(404);
        expect((await call("/fetch/short")).status).toBe(404);
        await post("/fetch", { id: FID, url: LINK });
        await until(`/fetch/${FID}`);
        expect((await call(`/fetch/${FID}`, { method: "POST" })).status).toBe(405);
    });

    describe("failures leave nothing behind", () => {
        const failWith = async (tweak: () => void, code: string) => {
            tweak();
            await post("/fetch", { id: FID, url: LINK });
            expect(await until(`/fetch/${FID}`)).toEqual({ status: "error", error: { code } });
            expect(existsSync(path.join(dirs.fetch, FID))).toBe(false);
            // and the helper is free again
            expect((await post("/fetch", { id: "B".repeat(22), url: LINK })).status).toBe(202);
        };
        it("cobalt's error code passes through", async () => {
            await failWith(() => (ctl.resolve = async () => Promise.reject(new JobError("error.api.fetch.fail"))), "error.api.fetch.fail");
        });
        it("too_large becomes error.studio.too_large", async () => {
            await failWith(() => (ctl.download = async () => Promise.reject(new JobError("error.webp.too_large"))), "error.studio.too_large");
        });
        it("a file with no video stream is bad_source", async () => {
            await failWith(() => (ctl.probe = async () => ({ duration: 3, width: null, height: null })), "error.webp.bad_source");
        });
        it("an unexpected exception is download_failed", async () => {
            await failWith(() => (ctl.download = async () => Promise.reject(new Error("boom"))), "error.webp.download_failed");
        });
    });
});

describe("the 200 MB cap with the real download", () => {
    let origin: http.Server;
    let url: string;
    beforeEach(async () => {
        origin = http.createServer((req, res) => {
            const chunked = req.url === "/chunked";
            res.writeHead(200, { "content-type": "video/mp4", ...(chunked ? {} : { "content-length": 5000 }) });
            if (chunked) {
                res.write(Buffer.alloc(2500));
                setTimeout(() => res.end(Buffer.alloc(2500)), 5);
            } else res.end(Buffer.alloc(5000));
        });
        await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
        url = `http://127.0.0.1:${(origin.address() as any).port}`;
    });
    afterEach(() => origin.close());

    const withCap = async (cap: number, path_: string) => {
        helper.close();
        await startHelper({
            maxFetchBytes: cap,
            downloadToFile,
            resolveSource: async () => ({ url: `${url}${path_}`, filename: "v.mp4" }),
        });
        await post("/fetch", { id: FID, url: LINK });
        return until(`/fetch/${FID}`);
    };
    it("refuses a declared length over the cap", async () => {
        expect(await withCap(1000, "/declared")).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        expect(existsSync(path.join(dirs.fetch, FID))).toBe(false);
    });
    it("refuses a streamed body that grows past the cap", async () => {
        expect(await withCap(3000, "/chunked")).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        expect(existsSync(path.join(dirs.fetch, FID))).toBe(false);
    });
    it("accepts a body exactly at the cap", async () => {
        expect(await withCap(5000, "/declared")).toMatchObject({ status: "done", bytes: 5000 });
    });
});

describe("one job at a time", () => {
    it("a pending fetch makes /fetch, /jobs and /jobs/upload answer 429 busy", async () => {
        const { gate, release } = gated();
        ctl.download = async (o) => {
            await gate;
            await writeFile(o.dest, "x");
            return 1;
        };
        await post("/fetch", { id: FID, url: LINK });
        const busy = { status: "error", error: { code: "error.webp.busy" } };
        const r1 = await post("/fetch", { id: "C".repeat(22), url: LINK });
        expect(r1.status).toBe(429);
        expect(await json(r1)).toEqual(busy);
        const r2 = await post("/jobs", { id: JID, url: LINK, start: 0, width: 480, fps: 15, quality: "med" });
        expect(r2.status).toBe(429);
        const r3 = await upload(JID);
        expect(r3.status).toBe(429);
        expect(await json(r3)).toEqual(busy);
        expect(helper.jobs.size).toBe(0); // the refused upload left no job
        release();
        await until(`/fetch/${FID}`);
        // done fetches do not block
        expect((await upload(JID)).status).toBe(202);
    });

    it("a pending upload encode makes /fetch answer 429", async () => {
        const { gate, release } = gated();
        ctl.encode = async (o) => {
            await gate;
            await writeFile(o.output, tinyWebp());
            return { frames: 1, frameBytes: 1 };
        };
        expect((await upload(JID)).status).toBe(202);
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(429);
        expect((await upload("D".repeat(20))).status).toBe(429);
        release();
        await until(`/jobs/${JID}`);
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(202);
    });

    it("an existing id is refused too", async () => {
        await post("/fetch", { id: FID, url: LINK });
        await until(`/fetch/${FID}`);
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(429);
    });
});

describe("POST /jobs/upload", () => {
    it.each([
        ["no id", { id: "" }],
        ["short id", { id: "abc" }],
        ["missing width", { width: "" }],
        ["width 500", { width: "500" }],
        ["width abc", { width: "abc" }],
        ["fps 9", { fps: "9" }],
        ["fps 26", { fps: "26" }],
        ["quality ultra", { quality: "ultra" }],
        ["missing quality", { quality: "" }],
        ["negative start", { start: "-1" }],
        ["length 0.4", { length: "0.4" }],
        ["length 601", { length: "601" }],
        ["length abc", { length: "abc" }],
    ])("400 for %s, no job, no files", async (_n, q) => {
        const id = "id" in q ? (q as any).id : JID;
        const res = await upload(id, { ...(q as any), id });
        expect(res.status).toBe(400);
        expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(helper.jobs.size).toBe(0);
        expect(existsSync(path.join(dirs.work, JID))).toBe(false);
    });
    it("405 for GET", async () => {
        expect((await call(`/jobs/upload?id=${JID}`)).status).toBe(405);
    });

    it("streams the body to disk, then encodes it as /jobs would and reports the result", async () => {
        const body = Buffer.alloc(300_000, 5);
        let inputSeen: Buffer | undefined;
        ctl.encode = async (o) => {
            inputSeen = await (await import("node:fs/promises")).readFile(o.input);
            await mkdir(o.framesDir, { recursive: true });
            await writeFile(o.output, tinyWebp());
            return { frames: 5, frameBytes: 1000 };
        };
        const res = await upload(JID, { start: "2", length: "5", width: "320", quality: "high" }, body);
        expect(res.status).toBe(202);
        expect(await json(res)).toEqual({ status: "pending", id: JID });
        const done = await until(`/jobs/${JID}`);
        expect(done).toEqual({ status: "done", bytes: tinyWebp().length, width: 480, height: 560, seconds: 0.1, filename: "cobalt.webp", service: "studio" });
        expect(inputSeen).toEqual(body);
        // no cobalt round trip, no download
        expect(ctl.resolveCalls).toHaveLength(0);
        const o = ctl.encodeCalls[0];
        expect(o).toMatchObject({ start: 2, length: 5, width: 320, fps: 15, quality: "high" });
        expect(o.input).toBe(path.join(dirs.work, JID, "in"));
        // the source copy is deleted once encoded
        expect(existsSync(o.input)).toBe(false);
        expect(existsSync(path.join(dirs.work, JID, "out.webp"))).toBe(true);
        const file = await call(`/jobs/${JID}/file`);
        expect(file.headers.get("content-type")).toBe("image/webp");
        expect(Buffer.from(await file.arrayBuffer()).subarray(0, 4).toString()).toBe("RIFF");
    });

    it("plans the clip against the probed duration (never past the end)", async () => {
        ctl.probe = async () => ({ duration: 9.6, width: 480, height: 560 });
        await upload(JID, { start: "8", length: "" });
        await until(`/jobs/${JID}`);
        expect(ctl.encodeCalls[0].length).toBeCloseTo(1.6, 5);
    });
    it("a start past the end of the video is invalid_params", async () => {
        await upload(JID, { start: "20", length: "2" });
        expect(await until(`/jobs/${JID}`)).toEqual({ status: "error", error: { code: "error.webp.invalid_params" } });
        expect(ctl.encodeCalls).toHaveLength(0);
        expect(existsSync(path.join(dirs.work, JID))).toBe(false);
    });

    it("an encode failure marks the job and removes its files", async () => {
        ctl.encode = async () => Promise.reject(new JobError("error.webp.encode_failed"));
        await upload(JID);
        expect(await until(`/jobs/${JID}`)).toEqual({ status: "error", error: { code: "error.webp.encode_failed" } });
        expect(existsSync(path.join(dirs.work, JID))).toBe(false);
    });

    it("DELETE /jobs/:id removes an upload job's directory", async () => {
        await upload(JID);
        await until(`/jobs/${JID}`);
        expect(existsSync(path.join(dirs.work, JID))).toBe(true);
        await call(`/jobs/${JID}`, { method: "DELETE" });
        expect(existsSync(path.join(dirs.work, JID))).toBe(false);
    });

    describe("the 200 MB cap", () => {
        beforeEach(async () => {
            helper.close();
            await startHelper({ maxFetchBytes: 1000 });
        });
        it("413 error.webp.too_large from the declared length, before reading the body", async () => {
            const res = await upload(JID, {}, Buffer.alloc(5000));
            expect(res.status).toBe(413);
            expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.too_large" } });
            expect(helper.jobs.size).toBe(0);
            expect(ctl.encodeCalls).toHaveLength(0);
        });
        it("413 and cleanup for a chunked body that grows past the cap", async () => {
            const stream = new ReadableStream({
                async start(c) {
                    c.enqueue(new Uint8Array(600));
                    await new Promise((r) => setTimeout(r, 5));
                    c.enqueue(new Uint8Array(600));
                    c.close();
                },
            });
            const res = await upload(JID, {}, stream as any);
            expect(res.status).toBe(413);
            expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.too_large" } });
            expect(helper.jobs.size).toBe(0);
            expect(existsSync(path.join(dirs.work, JID))).toBe(false);
            expect(ctl.encodeCalls).toHaveLength(0);
            // and the helper is free again
            expect((await upload(JID, {}, Buffer.alloc(1000))).status).toBe(202);
        });
        it("a body exactly at the cap is accepted", async () => {
            expect((await upload(JID, {}, Buffer.alloc(1000))).status).toBe(202);
        });
    });

    it("an empty body is bad_source and leaves nothing", async () => {
        const res = await upload(JID, {}, Buffer.alloc(0));
        expect(res.status).toBe(400);
        expect(await json(res)).toEqual({ status: "error", error: { code: "error.webp.bad_source" } });
        expect(helper.jobs.size).toBe(0);
        expect(existsSync(path.join(dirs.work, JID))).toBe(false);
    });
});

describe("POST /jobs still works after the split (cobalt path)", () => {
    it("resolves, downloads, encodes", async () => {
        const res = await post("/jobs", { id: JID, url: LINK, start: 0, length: 6, width: 480, fps: 15, quality: "med" });
        expect(res.status).toBe(202);
        const done = await until(`/jobs/${JID}`);
        expect(done).toMatchObject({ status: "done", service: "x", filename: "twitter_2105237035271258436.webp" });
        expect(ctl.resolveCalls[0]).toMatchObject({ url: LINK, internalKey: KEY });
    });
});

describe("lib: what a saved video is", () => {
    const ff = (extra: string) => `Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'in':
  Duration: 00:00:09.60, start: 0.000000, bitrate: 1053 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 480x560 [SAR 1:1 DAR 6:7], 1000 kb/s, 30 fps, 30 tbr, 15360 tbn (default)
${extra}`;
    it("reads size and duration", () => {
        expect(parseVideoInfo(ff(""))).toEqual({ duration: 9.6, width: 480, height: 560 });
    });
    it("swaps for a 90 degree rotation, not for 180", () => {
        const rot = (d: string) => `${ff(`  Side data:\n    displaymatrix: rotation of ${d} degrees\n  Stream #0:1: Audio: aac`)}`;
        expect(parseVideoInfo(rot("-90.00"))).toEqual({ duration: 9.6, width: 560, height: 480 });
        expect(parseVideoInfo(rot("270.00"))).toMatchObject({ width: 560, height: 480 });
        expect(parseVideoInfo(rot("180.00"))).toMatchObject({ width: 480, height: 560 });
    });
    it("ignores cover art and audio-only files", () => {
        expect(parseVideoInfo("  Duration: 00:03:00.00, start: 0\n  Stream #0:0: Audio: mp3, 44100 Hz\n  Stream #0:1: Video: mjpeg (Baseline), yuvj420p, 500x500, 90k tbr (attached pic)")).toEqual({ duration: 180, width: null, height: null });
        expect(parseVideoInfo("nothing here")).toEqual({ duration: null, width: null, height: null });
    });
    it("picks the first real video stream and skips hex like 0x31637661", () => {
        expect(parseVideoInfo("  Stream #0:0[0x1]: Video: h264 (avc1 / 0x31637661), yuv420p, 1920x1080, 30 fps")).toMatchObject({ width: 1920, height: 1080 });
    });
    it("videoExt: content type first, then filename, else mp4", () => {
        expect(videoExt({ contentType: "video/webm; codecs=vp9", filename: "a.mp4" })).toBe("webm");
        expect(videoExt({ contentType: "application/octet-stream", filename: "a.MOV" })).toBe("mov");
        expect(videoExt({ contentType: "video/quicktime" })).toBe("mov");
        expect(videoExt({ contentType: "text/html", filename: "a.exe" })).toBe("mp4");
        expect(videoExt({ contentType: null, filename: null })).toBe("mp4");
        expect(videoExt({ contentType: "video/x-matroska" })).toBe("mkv");
    });
    it("titleFromFilename", () => {
        expect(titleFromFilename("twitter_123.mp4")).toBe("twitter_123");
        expect(titleFromFilename("noext")).toBe("noext");
        expect(titleFromFilename("")).toBeNull();
        expect(titleFromFilename(null)).toBeNull();
        expect(titleFromFilename("x".repeat(300) + ".mp4")).toHaveLength(200);
    });
    it("studioCode maps only the size code", () => {
        expect(studioCode("error.webp.too_large")).toBe("error.studio.too_large");
        expect(studioCode("error.api.fetch.fail")).toBe("error.api.fetch.fail");
    });
    it("validateFetchInput / validateEncodeFields", () => {
        expect(validateFetchInput({ id: FID, url: LINK })).toEqual({ id: FID, url: LINK });
        expect(validateFetchInput({ id: FID, url: "x" })).toBeNull();
        expect(validateEncodeFields({ start: "2", length: "5", width: "480", fps: "15", quality: "med" }, { minLength: 0.5 })).toEqual({ start: 2, length: 5, width: 480, fps: 15, quality: "med" });
        expect(validateEncodeFields({ start: 0, length: 0.5, width: 320, fps: 15, quality: "low" }, { minLength: 0.5 })).toMatchObject({ length: 0.5 });
        expect(validateEncodeFields({ start: 0, length: 0.5, width: 320, fps: 15, quality: "low" }, { minLength: 1 })).toBeNull();
        expect(validateEncodeFields({ start: 0, width: 320, fps: 15, quality: "toString" }, { minLength: 1 })).toBeNull();
    });
});

// POST /probe: measures a stored file the Worker streams in (library adopt).
describe("POST /probe", () => {
    const probeReq = (id = JID, body: BodyInit = Buffer.alloc(3000, 5), headers: Record<string, string> = {}) =>
        call(`/probe?id=${id}`, {
            method: "POST",
            body,
            headers: { "content-type": "application/octet-stream", ...headers },
            duplex: "half",
        });

    it("answers {duration,width,height}, reads the streamed bytes from disk and deletes them", async () => {
        let seen = -1;
        ctl.probe = async () => {
            seen = (await stat(path.join(dirs.probe, JID, "in"))).size;
            return { duration: 4.2, width: 640, height: 360 };
        };
        const res = await probeReq();
        expect(res.status).toBe(200);
        expect(await json(res)).toEqual({ duration: 4.2, width: 640, height: 360 });
        expect(seen).toBe(3000);
        expect(existsSync(path.join(dirs.probe, JID))).toBe(false);
    });
    it("passes a null duration through (a gif with no duration line)", async () => {
        ctl.probe = async () => ({ duration: null, width: 200, height: 100 });
        expect(await json(await probeReq())).toEqual({ duration: null, width: 200, height: 100 });
    });
    it("400 error.studio.not_video when there is no video stream; the file is gone", async () => {
        ctl.probe = async () => ({ duration: 3, width: null, height: null });
        const res = await probeReq();
        expect(res.status).toBe(400);
        expect(await json(res)).toEqual({ status: "error", error: { code: "error.studio.not_video" } });
        expect(existsSync(path.join(dirs.probe, JID))).toBe(false);
    });
    it("400 not_video for an empty body", async () => {
        const res = await probeReq(JID, Buffer.alloc(0));
        expect(res.status).toBe(400);
        expect((await json(res)).error.code).toBe("error.studio.not_video");
    });
    it("400 for a bad id, 405 for GET", async () => {
        expect((await probeReq("../x")).status).toBe(400);
        expect((await call(`/probe?id=${JID}`)).status).toBe(405);
    });
    it("413 over the size cap, by header and by counting; nothing is left", async () => {
        helper.close();
        await startHelper({ maxFetchBytes: 1000 });
        const declared = await probeReq(JID, Buffer.alloc(3000, 5));
        expect(declared.status).toBe(413);
        expect((await json(declared)).error.code).toBe("error.studio.too_large");
        // chunked: no content-length to refuse early
        const chunked = await call(`/probe?id=${JID}`, {
            method: "POST",
            body: new ReadableStream({
                start(c) {
                    c.enqueue(new Uint8Array(600));
                    c.enqueue(new Uint8Array(600));
                    c.close();
                },
            }),
            duplex: "half",
        });
        expect(chunked.status).toBe(413);
        expect(existsSync(path.join(dirs.probe, JID))).toBe(false);
    });
    it("429 while a fetch is pending", async () => {
        const { gate, release } = gated();
        ctl.download = async () => {
            await gate;
            return 1;
        };
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(202);
        const res = await probeReq();
        expect(res.status).toBe(429);
        expect((await json(res)).error.code).toBe("error.webp.busy");
        release();
    });
    it("holds the helper while it runs: a fetch started meanwhile is 429, afterwards it is free again", async () => {
        const { gate, release } = gated();
        ctl.probe = async () => {
            await gate;
            return { duration: 1, width: 10, height: 10 };
        };
        const running = probeReq();
        for (let i = 0; i < 200 && !existsSync(path.join(dirs.probe, JID, "in")); i++) {
            await new Promise((r) => setTimeout(r, 10));
        }
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(429);
        expect((await probeReq(FID)).status).toBe(429);
        release();
        expect((await running).status).toBe(200);
        expect((await post("/fetch", { id: FID, url: LINK })).status).toBe(202);
    });
});
