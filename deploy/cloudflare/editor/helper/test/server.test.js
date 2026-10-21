// The container API (31.9) in-process on an ephemeral port, driving the real ffmpeg.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import http from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { createEditServer, keyMatches, posterArgs, posterTime } from "../server.js";
import { FFMPEG, ffmpegAvailable, makeMedia, videoFacts } from "./media.js";

const have = ffmpegAvailable() && spawnSync("ffprobe", ["-version"]).status === 0;
const skip = have ? false : "ffmpeg/ffprobe not available";
const KEY = "test-internal-key";
const RID = "R1234567890abcdefghi", RID2 = "R2234567890abcdefghi";
const I = { idx: "AAAAAAAAAAAAAAAA", gif: "GGGGGGGGGGGGGGGG", png: "HHHHHHHHHHHHHHHH" };

let work = "", media, h, base;

before(async () => {
    if (!have) return;
    work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-server-"));
    media = makeMedia(path.join(work, "media"));
    h = createEditServer({ internalKey: KEY, workDir: path.join(work, "render"), ffmpeg: FFMPEG, version: "v-test", idleMs: 60_000 });
    await h.clean();
    await new Promise((r) => h.server.listen(0, "127.0.0.1", r));
    base = `http://127.0.0.1:${h.server.address().port}`;
});
after(async () => {
    if (!have) return;
    await h.killAll();
    await new Promise((r) => h.server.close(r));
    h.server.closeAllConnections?.();
    rmSync(work, { recursive: true, force: true });
});

const call = (method, p, body, headers = {}) => fetch(base + p, { method, body, headers: { "x-internal-key": KEY, ...headers } });
const get = async (p) => {
    const r = await call("GET", p);
    return { status: r.status, body: await r.json().catch(() => null) };
};
const put = (rid, n, file) => call("PUT", `/renders/${rid}/inputs/${n}`, readFileSync(file));
const startBody = (timeline, inputs) => JSON.stringify({ timeline, inputs });
const tl = (main, overlay = [], canvas = { w: 720, h: 720, fps: 30 }) => ({ version: 1, canvas, main, overlay });
const mc = (o) => ({ id: "m1", item: I.idx, in: 0, out: 2, speed: 1, fit: "fill", volume: 1, muted: false, ...o });
const oc = (o) => ({ id: "o1", item: I.gif, at: 0.5, in: 0, out: 1, frame: { x: 0.25, y: 0.25, w: 0.4 }, opacity: 1, volume: 1, muted: true, ...o });
const inputs = [{ n: 0, item: I.idx, kind: "video" }, { n: 1, item: I.gif, kind: "gif" }];

async function waitFor(rid, pred, ms = 60_000) {
    const t0 = Date.now();
    for (;;) {
        const r = await get(`/renders/${rid}`);
        if (pred(r.body)) return r.body;
        assert.ok(Date.now() - t0 < ms, `timed out: ${JSON.stringify(r.body)}`);
        await new Promise((x) => setTimeout(x, 100));
    }
}

test("posterTime and posterArgs are 13.3's recipe", () => {
    assert.equal(posterTime(10), 1);
    assert.equal(posterTime(100), 3);
    assert.equal(posterTime(null), 0);
    const a = posterArgs({ input: "in.mp4", output: "p.jpg", at: 1 });
    assert.deepEqual(a.slice(a.indexOf("-q:v"), a.indexOf("-q:v") + 2), ["-q:v", "4"]);
    assert.ok(a.join(" ").includes("min(720,iw)"));
    assert.equal(keyMatches("a", "a"), true);
    assert.equal(keyMatches("a", ""), false);
    assert.equal(keyMatches(undefined, "a"), false);
});

test("every request needs x-internal-key", { skip }, async () => {
    for (const headers of [{}, { "x-internal-key": "nope" }, { "x-internal-key": "" }]) {
        const r = await fetch(`${base}/health`, { headers });
        assert.equal(r.status, 403);
        assert.equal((await r.json()).error.code, "error.edit.forbidden");
    }
    assert.equal((await fetch(`${base}/renders/${RID}`, { method: "DELETE" })).status, 403);
    const r = await get("/health");
    assert.deepEqual(r.body, { render: null, status: "ok", version: "v-test" });
});

test("a container without a key refuses everything", { skip }, async () => {
    const open = createEditServer({ internalKey: "", workDir: path.join(work, "x") });
    await new Promise((r) => open.server.listen(0, "127.0.0.1", r));
    const res = await fetch(`http://127.0.0.1:${open.server.address().port}/health`, { headers: { "x-internal-key": "" } });
    assert.equal(res.status, 403);
    open.server.close();
    open.reap();
});

test("a whole render: inputs, start, progress, file, poster, delete", { skip }, async () => {
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    assert.equal((await put(RID, 1, media.files.gif)).status, 204);
    assert.equal((await get("/health")).body.render, RID);
    const early = await get(`/renders/${RID}`);
    assert.equal(early.body.status, "receiving");
    assert.equal(early.body.error, null);
    // file and poster are not there yet
    assert.equal((await call("GET", `/renders/${RID}/file`)).status, 409);

    const r = await call("POST", `/renders/${RID}/start`, startBody(tl([mc({ in: 1, out: 4, speed: 1.5 }), mc({ id: "m2", in: 5, out: 6 })], [oc()]), inputs));
    assert.equal(r.status, 202);
    const done = await waitFor(RID, (b) => b.status === "done" || b.status === "error");
    assert.equal(done.status, "done", JSON.stringify(done));
    assert.equal(done.error, null);
    assert.deepEqual([done.width, done.height], [720, 720]);
    assert.equal(done.seconds_total, 3);
    assert.equal(done.seconds_done, 3);
    assert.ok(Math.abs(done.duration - 3) < 0.05, `${done.duration}`);
    assert.ok(done.bytes > 1000);

    const f = await call("GET", `/renders/${RID}/file`);
    assert.equal(f.status, 200);
    assert.equal(f.headers.get("content-type"), "video/mp4");
    const bytes = Buffer.from(await f.arrayBuffer());
    assert.equal(Number(f.headers.get("content-length")), bytes.length);
    assert.equal(bytes.length, done.bytes);
    const file = path.join(work, "got.mp4");
    (await import("node:fs")).writeFileSync(file, bytes);
    const v = videoFacts(file);
    assert.deepEqual([v.frames, v.width, v.height, v.codec], [90, 720, 720, "h264"]);

    const p = await call("GET", `/renders/${RID}/poster`);
    assert.equal(p.status, 200);
    assert.equal(p.headers.get("content-type"), "image/jpeg");
    const jpg = Buffer.from(await p.arrayBuffer());
    assert.deepEqual([...jpg.subarray(0, 3)], [0xff, 0xd8, 0xff]);
    assert.ok(jpg.length < 100_000);

    const dir = h.current().dir;
    assert.ok(existsSync(dir));
    assert.equal((await call("DELETE", `/renders/${RID}`)).status, 204);
    assert.equal((await call("DELETE", `/renders/${RID}`)).status, 204, "idempotent");
    assert.equal(existsSync(dir), false);
    assert.equal((await get(`/renders/${RID}`)).status, 404);
    assert.equal((await get("/health")).body.render, null);
});

test("one render per container: another rid is busy until DELETE", { skip }, async () => {
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    const other = await put(RID2, 0, media.files.idx);
    assert.equal(other.status, 409);
    assert.equal((await other.json()).error.code, "error.edit.busy");
    assert.equal((await call("POST", `/renders/${RID2}/start`, startBody(tl([mc()]), inputs))).status, 409);
    assert.equal((await get(`/renders/${RID2}`)).status, 409);
    assert.equal((await call("DELETE", `/renders/${RID2}`)).status, 204);
    assert.equal(h.current().rid, RID, "deleting another rid frees nothing");
    assert.equal((await call("DELETE", `/renders/${RID}`)).status, 204);
    assert.equal((await put(RID2, 0, media.files.idx)).status, 204);
    await call("DELETE", `/renders/${RID2}`);
});

test("input uploads: bad n, no content-length, over the cap, a body shorter than its length, re-upload replaces", { skip }, async () => {
    assert.equal((await put(RID, 50, media.files.idx)).status, 400);
    assert.equal((await put(RID, "x", media.files.idx)).status, 400);
    assert.equal((await put(RID, -1, media.files.idx)).status, 400);
    assert.equal((await get("/health")).body.render, null, "a bad n does not take the container");
    // chunked: no content-length
    const status = await new Promise((resolve) => {
        const req = http.request(`${base}/renders/${RID}/inputs/0`, { method: "PUT", headers: { "x-internal-key": KEY, "transfer-encoding": "chunked" } }, (res) => {
            res.resume();
            resolve(res.statusCode);
        });
        req.end(Buffer.alloc(10));
    });
    assert.equal(status, 411);
    // a body that stops early
    const short = await new Promise((resolve) => {
        const req = http.request(`${base}/renders/${RID}/inputs/0`, { method: "PUT", headers: { "x-internal-key": KEY, "content-length": "100" } }, (res) => {
            res.resume();
            resolve(res.statusCode);
        });
        req.on("error", () => resolve("closed"));
        req.write(Buffer.alloc(10));
        setTimeout(() => req.destroy(), 100);
    });
    assert.ok(short === "closed" || short === 400);
    await new Promise((x) => setTimeout(x, 150));
    assert.equal(existsSync(path.join(h.current()?.dir ?? "/nonexistent", "in", "0")), false, "no half file under the real name");
    await call("DELETE", `/renders/${RID}`);
    // the cap
    const small = createEditServer({ internalKey: KEY, workDir: path.join(work, "small"), ffmpeg: FFMPEG, maxInputBytes: 1000 });
    await new Promise((r) => small.server.listen(0, "127.0.0.1", r));
    const u = `http://127.0.0.1:${small.server.address().port}/renders/${RID}/inputs/0`;
    const big = await fetch(u, { method: "PUT", body: Buffer.alloc(1001), headers: { "x-internal-key": KEY } });
    assert.equal(big.status, 413);
    assert.equal((await big.json()).error.code, "error.edit.too_large");
    assert.equal((await fetch(u, { method: "PUT", body: Buffer.alloc(900), headers: { "x-internal-key": KEY } })).status, 204);
    assert.equal((await fetch(u, { method: "PUT", body: Buffer.alloc(950), headers: { "x-internal-key": KEY } })).status, 204, "the same n replaces, it does not add");
    const second = await fetch(u.replace("/0", "/1"), { method: "PUT", body: Buffer.alloc(100), headers: { "x-internal-key": KEY } });
    assert.equal(second.status, 413, "950 + 100 over 1000");
    await small.killAll();
    small.server.close();
});

test("start: refusals come back as 400/409 with a code and a path", { skip }, async () => {
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    assert.equal((await put(RID, 1, media.files.gif)).status, 204);
    // a refused start leaves the render in "error" (the DO ends it and DELETEs), so each case starts from a fresh upload
    let first = true;
    const start = async (timeline, ins = inputs) => {
        if (!first) {
            await call("DELETE", `/renders/${RID}`);
            await put(RID, 0, media.files.idx);
            await put(RID, 1, media.files.gif);
        }
        first = false;
        const r = await call("POST", `/renders/${RID}/start`, startBody(timeline, ins));
        return { status: r.status, body: await r.json().catch(() => ({})) };
    };
    // parseTimeline
    let r = await start(tl([mc({ speed: 9 })]));
    assert.deepEqual([r.status, r.body.error.code, r.body.path], [400, "error.edit.range", "main[0].speed"]);
    r = await start({ ...tl([mc()]), version: 2 });
    assert.deepEqual([r.status, r.body.error.code, r.body.path], [400, "error.edit.bad_request", "version"]);
    // an input that was never uploaded
    r = await start(tl([mc({ item: "ZZZZZZZZZZZZZZZZ" })]), [...inputs, { n: 2, item: "ZZZZZZZZZZZZZZZZ", kind: "video" }]);
    assert.deepEqual([r.status, r.body.error.code, r.body.path, r.body.items], [409, "error.edit.input_missing", "main[0].item", ["ZZZZZZZZZZZZZZZZ"]]);
    r = await start(tl([mc({ item: "ZZZZZZZZZZZZZZZZ" })]));
    assert.equal(r.body.error.code, "error.edit.input_missing", "not in the inputs list at all");
    r = await start(tl([mc()]), [{ n: 7, item: I.idx, kind: "video" }]);
    assert.equal(r.body.error.code, "error.edit.input_missing", "listed, but that n was never uploaded");
    // the kind is checked by the bytes
    r = await start(tl([mc({ item: I.gif })]), [{ n: 1, item: I.gif, kind: "video" }]);
    assert.deepEqual([r.status, r.body.error.code, r.body.path], [400, "error.edit.unsupported_source", "main[0].item"]);
    // the real duration decides (10 s long): out past it
    r = await start(tl([mc({ in: 9, out: 10.2 })]));
    assert.deepEqual([r.status, r.body.error.code, r.body.path], [400, "error.edit.past_source_end", "main[0].out"]);
    // a gif cannot be a main clip
    r = await start(tl([mc({ item: I.gif })]), [{ n: 1, item: I.gif, kind: "gif" }]);
    assert.deepEqual([r.status, r.body.error.code], [400, "error.edit.not_video"]);
    // a crop under 64 px of the real 320x180 picture
    r = await start(tl([mc({ crop: { aspect: "free", x: 0, y: 0, w: 0.1, h: 1 } })]));
    assert.deepEqual([r.status, r.body.error.code, r.body.path], [400, "error.edit.range", "main[0].crop"]);
    // inside the 0.05 s slack: clamped, accepted
    r = await start(tl([mc({ in: 9, out: 10.04 })]));
    assert.equal(r.status, 202, JSON.stringify(r.body));
    const done = await waitFor(RID, (b) => b.status === "done" || b.status === "error");
    assert.equal(done.status, "done");
    assert.ok(Math.abs(done.seconds_total - 1) < 0.001, `${done.seconds_total}`);
    // a render that is running cannot be started or fed again
    assert.equal((await call("POST", `/renders/${RID}/start`, startBody(tl([mc()]), inputs))).status, 409);
    assert.equal((await put(RID, 0, media.files.idx)).status, 409);
    await call("DELETE", `/renders/${RID}`);
    // a refused start leaves a readable error
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    await call("POST", `/renders/${RID}/start`, startBody(tl([mc({ in: 9, out: 11 })]), inputs));
    const st = await get(`/renders/${RID}`);
    assert.deepEqual([st.body.status, st.body.error], ["error", { code: "error.edit.past_source_end" }]);
    await call("DELETE", `/renders/${RID}`);
});

test("progress, and DELETE while ffmpeg runs kills it", { skip }, async () => {
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    // 8 clips of the 10 s source at 1080p60: long enough to watch
    const main = Array.from({ length: 8 }, (_, i) => mc({ id: `m${i}`, in: 0, out: 10 }));
    const r = await call("POST", `/renders/${RID}/start`, startBody(tl(main, [], { w: 1920, h: 1080, fps: 60 }), [inputs[0]]));
    assert.equal(r.status, 202);
    const seen = await waitFor(RID, (b) => b.status === "encoding" && b.seconds_done > 0 && b.speed > 0);
    assert.equal(seen.seconds_total, 80);
    assert.ok(seen.seconds_done > 0 && seen.seconds_done < 80);
    assert.equal(typeof seen.speed, "number");
    assert.equal(seen.duration, null);
    const child = h.current().child;
    assert.ok(child && child.exitCode === null);
    const dir = h.current().dir;
    assert.equal((await call("DELETE", `/renders/${RID}`)).status, 204);
    await new Promise((res) => (child.exitCode !== null || child.signalCode ? res() : child.once("close", res)));
    assert.equal(child.signalCode, "SIGKILL");
    assert.equal(existsSync(dir), false);
    assert.equal(h.current(), null);
});

test("a render nobody touches for the idle time is killed and deleted", { skip }, async () => {
    const idle = createEditServer({ internalKey: KEY, workDir: path.join(work, "idle"), ffmpeg: FFMPEG, idleMs: 300, log: () => {} });
    await new Promise((r) => idle.server.listen(0, "127.0.0.1", r));
    const b = `http://127.0.0.1:${idle.server.address().port}`;
    const res = await fetch(`${b}/renders/${RID}/inputs/0`, { method: "PUT", body: Buffer.alloc(50), headers: { "x-internal-key": KEY } });
    assert.equal(res.status, 204);
    const dir = idle.current().dir;
    assert.ok(existsSync(dir));
    await new Promise((x) => setTimeout(x, 150));
    await fetch(`${b}/renders/${RID}`, { headers: { "x-internal-key": KEY } }); // a touch
    await new Promise((x) => setTimeout(x, 250));
    assert.ok(idle.current(), "touched, so still held");
    await new Promise((x) => setTimeout(x, 700));
    assert.equal(idle.current(), null);
    assert.equal(existsSync(dir), false);
    await idle.killAll();
    idle.server.close();
});

test("a photo overlay renders; an ffmpeg that dies is reported as render_failed", { skip }, async () => {
    // a PNG overlay through the server (the kind comes from the DO)
    assert.equal((await put(RID, 0, media.files.idx)).status, 204);
    assert.equal((await put(RID, 1, media.files.png)).status, 204);
    const ins = [{ n: 0, item: I.idx, kind: "video" }, { n: 1, item: I.png, kind: "photo" }];
    const r = await call("POST", `/renders/${RID}/start`, startBody(tl([mc({ out: 2 })], [oc({ item: I.png, out: 1 })]), ins));
    assert.equal(r.status, 202);
    const done = await waitFor(RID, (b) => b.status === "done" || b.status === "error");
    assert.equal(done.status, "done");
    await call("DELETE", `/renders/${RID}`);
    // an ffmpeg that probes fine but dies when asked to encode
    const wrapper = path.join(work, "bad-ffmpeg.sh");
    (await import("node:fs")).writeFileSync(wrapper, `#!/bin/sh\nfor a in "$@"; do [ "$a" = "-filter_complex" ] && { echo boom >&2; exit 1; }; done\nexec ${FFMPEG} "$@"\n`, { mode: 0o755 });
    const broken = createEditServer({ internalKey: KEY, workDir: path.join(work, "broken"), ffmpeg: wrapper, log: () => {} });
    await new Promise((x) => broken.server.listen(0, "127.0.0.1", x));
    const b = `http://127.0.0.1:${broken.server.address().port}`;
    const hd = { "x-internal-key": KEY };
    await fetch(`${b}/renders/${RID}/inputs/0`, { method: "PUT", body: readFileSync(media.files.idx), headers: hd });
    const s = await fetch(`${b}/renders/${RID}/start`, { method: "POST", body: startBody(tl([mc({ out: 1 })]), [inputs[0]]), headers: hd });
    assert.equal(s.status, 202);
    let body;
    for (let i = 0; i < 100; i++) {
        body = await (await fetch(`${b}/renders/${RID}`, { headers: hd })).json();
        if (body.status === "error") break;
        await new Promise((x) => setTimeout(x, 50));
    }
    assert.equal(body.status, "error");
    assert.deepEqual(body.error, { code: "error.edit.render_failed" });
    assert.equal((await fetch(`${b}/renders/${RID}/file`, { headers: hd })).status, 409);
    await broken.killAll();
    broken.server.close();
});
