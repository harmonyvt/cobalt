// Chat videos (APP-API-CONTRACT.md section 45): the planner (pure) and, when Chromium is there (CHAT_CHROMIUM or the
// Alpine path), a whole render through the container API.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { LIMITS, PACE, SHAPES, plan, words } from "../chat/plan.js";
import { chromiumPath } from "../chat/cdp.js";
import { createEditServer } from "../server.js";
import { FFMPEG, ff, ffmpegAvailable, videoFacts } from "./media.js";

const msg = (id, role, text, extra = {}) => ({ id, role, text, status: "done", post_ids: [], steps: [], ...extra });
const snap = (messages, posts = {}) => ({ version: 1, thread: { id: "T", title: "a chat" }, messages, posts });

test("words keep the text whole", () => {
    const t = "found him **so no**\n\nhere's  your link";
    assert.equal(words(t).join(""), t);
    assert.deepEqual(words(""), []);
});

test("a user message types, sends, and the reply comes after it", () => {
    const p = plan(snap([msg("1", "user", "hello there"), msg("2", "assistant", "hi (=^･ω･^=)")]));
    const at = Object.fromEntries(p.beats.map((b) => [b.el, b]));
    assert.equal(at["m1.type"].at, PACE.intro);
    assert.ok(at["m1"].at > at["m1.type"].at);
    assert.ok(at["m2.think"].at >= at["m1"].at);
    assert.ok(at["m2"].at > at["m2.think"].at);
    assert.ok(at["m2.text"].at >= at["m2"].at);
    assert.equal(at["m2.text"].words, 2);
    assert.ok(p.seconds > at["m2.text"].until);
    assert.deepEqual(p.sounds, []);
});

test("chips, cards (at most 6), text, then shown posts; a video plays with its sound", () => {
    const calls = Array.from({ length: 8 }, (_, i) => ({ op: "library.search", ms: 10, status: "done", card: { type: "search", query: "q", within: null, total: 1, hits: [] } }));
    const posts = {
        v: { id: "v", title: "clip", kind: "video", poster: "0", files: [{ kind: "video", url: "1", width: 720, height: 1280, duration: 30 }] },
        i: { id: "i", title: "pic", kind: "photo", poster: "2", files: [{ kind: "image", url: "2", width: 600, height: 800 }] },
    };
    const p = plan(snap([msg("1", "user", "go"), msg("2", "assistant", "here", { post_ids: ["v", "i", "gone"], steps: [{ id: "s", kind: "code", status: "done", calls }] })], posts));
    const els = p.beats.map((b) => b.el);
    assert.equal(els.filter((e) => /\.c\d+$/.test(e)).length, 8);
    assert.equal(els.filter((e) => /\.card\d+$/.test(e)).length, LIMITS.cards);
    const v = p.beats.find((b) => b.el === "m2.post0");
    assert.equal(v.play.length, PACE.videoMax);
    assert.ok(v.at > p.beats.find((b) => b.el === "m2.text").at);
    assert.equal(p.sounds.length, 1);
    assert.equal(p.sounds[0].at, v.play.at);
    assert.ok(p.beats.find((b) => b.el === "m2.post1").at >= v.play.at + v.play.length);
    assert.equal(p.beats.find((b) => b.el === "m2.post2"), undefined, "a post missing from the map is left out");
});

test("speed scales the pacing, from/to pick messages, the length is capped", () => {
    const s = snap([msg("1", "user", "a ".repeat(40)), msg("2", "assistant", "b ".repeat(100)), msg("3", "user", "c"), msg("4", "assistant", "d")]);
    const slow = plan(s), fast = plan(s, { speed: 2 });
    assert.ok(fast.seconds < slow.seconds * 0.6);
    assert.deepEqual(plan(s, { from: "2", to: "3" }).messages, ["2", "3"]);
    const many = snap(Array.from({ length: 200 }, (_, i) => msg(String(i + 1), i % 2 ? "assistant" : "user", "word ".repeat(80))));
    const p = plan(many);
    assert.ok(p.seconds <= LIMITS.seconds);
    assert.ok(p.messages.length <= LIMITS.messages);
    assert.deepEqual(Object.keys(SHAPES), ["portrait", "landscape", "square"]);
});

const chromium = process.env.CHAT_CHROMIUM || chromiumPath();
const can = ffmpegAvailable() && spawnSync("ffprobe", ["-version"]).status === 0 && existsSync(chromium);

test("a chat renders through the container API: frames, the played video's sound, poster", { skip: can ? false : "no ffmpeg or Chromium", timeout: 240_000 }, async () => {
    const work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "chat-video-"));
    const KEY = "k";
    const h = createEditServer({ internalKey: KEY, workDir: path.join(work, "render"), ffmpeg: FFMPEG, chromium, idleMs: 120_000 });
    try {
        await h.clean();
        await new Promise((r) => h.server.listen(0, "127.0.0.1", r));
        const base = `http://127.0.0.1:${h.server.address().port}`;
        const call = (method, p, body) => fetch(base + p, { method, body, headers: { "x-internal-key": KEY } });
        const clip = path.join(work, "clip.mp4"), poster = path.join(work, "poster.jpg");
        ff(["-f", "lavfi", "-i", "testsrc2=s=360x640:r=30:d=2", "-f", "lavfi", "-i", "sine=f=440:d=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", clip]);
        ff(["-f", "lavfi", "-i", "color=c=pink:s=180x240", "-frames:v", "1", poster]);
        const RID = "Rchat000000000000001";
        assert.equal((await call("PUT", `/renders/${RID}/inputs/0`, readFileSync(poster))).status, 204);
        assert.equal((await call("PUT", `/renders/${RID}/inputs/1`, readFileSync(clip))).status, 204);
        const s = snap(
            [
                msg("1", "user", "find the clip"),
                msg("2", "assistant", "here it is **(=^･ω･^=)**", {
                    post_ids: ["p"],
                    steps: [{ id: "s", kind: "code", status: "done", duration_ms: 300, calls: [{ op: "library.search", ms: 120, status: "done", card: { type: "search", query: "clip", within: null, total: 1, hits: [{ post_id: "p", score: 0.9 }] } }] }],
                }),
            ],
            { p: { id: "p", title: "clip", kind: "video", poster: "0", files: [{ kind: "video", url: "1", width: 360, height: 640, duration: 2 }] }, q: { id: "q", title: "missing", kind: "photo", poster: "7", files: [] } },
        );
        const st = await call("POST", `/renders/${RID}/start`, JSON.stringify({ chat: { snapshot: s, options: { shape: "square", speed: 2 } }, inputs: [] }));
        assert.equal(st.status, 202);
        let body;
        for (const t0 = Date.now(); ; ) {
            body = await (await call("GET", `/renders/${RID}`)).json();
            if (body.status === "done" || body.status === "error") break;
            assert.ok(Date.now() - t0 < 200_000, JSON.stringify(body));
            await new Promise((r) => setTimeout(r, 200));
        }
        assert.equal(body.status, "done", JSON.stringify(body));
        assert.equal(body.width, 1080);
        assert.equal(body.height, 1080);
        assert.ok(body.duration > 4 && Math.abs(body.duration - body.seconds_total) < 0.5, JSON.stringify(body));
        const file = await call("GET", `/renders/${RID}/file`);
        assert.equal(file.status, 200);
        const out = path.join(work, "out.mp4");
        (await import("node:fs")).writeFileSync(out, Buffer.from(await file.arrayBuffer()));
        const v = videoFacts(out);
        assert.equal(v.width, 1080);
        const audio = spawnSync("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0", out]).stdout.toString().trim();
        assert.equal(audio, "aac");
        // the clip's tone is heard while it plays, silence before
        const vol = (from) => {
            const r = spawnSync(FFMPEG, ["-v", "info", "-ss", String(from), "-t", "0.5", "-i", out, "-af", "volumedetect", "-f", "null", "-"]);
            return Number(/mean_volume: (-?[\d.]+)/.exec(r.stderr.toString())?.[1] ?? -99);
        };
        assert.ok(vol(0.2) < -60, "silent at the start");
        assert.equal((await call("GET", `/renders/${RID}/poster`)).status, 200);
        void readFileSync;
    } finally {
        await h.killAll();
        await new Promise((r) => h.server.close(r));
        rmSync(work, { recursive: true, force: true });
    }
});
