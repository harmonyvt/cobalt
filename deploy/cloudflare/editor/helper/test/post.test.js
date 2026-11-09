// Post frames (APP-API-CONTRACT.md section 52.5): the layout maths (pure) and, when Chromium is there (CHAT_CHROMIUM or the
// Alpine path), whole renders through the container API.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { chromiumPath } from "../chat/cdp.js";
import { ASPECT_MAX, ASPECT_MIN, boxAspect, ffmpegArgs, placement } from "../post/render.js";
import { createEditServer } from "../server.js";
import { FFMPEG, ff, ffmpegAvailable, videoFacts } from "./media.js";

test("the video's box keeps the video's shape between 21:9 and 4:5", () => {
    assert.equal(boxAspect(1280, 720), 720 / 1280);
    assert.equal(boxAspect(720, 1280), ASPECT_MAX);
    assert.equal(boxAspect(3000, 500), ASPECT_MIN);
    assert.equal(boxAspect(null, null), 9 / 16);
});

test("fit is the card's own size; 9:16 and 1:1 centre the card with a margin", () => {
    const card = { w: 1080, h: 831, box: { x: 150, y: 240, w: 846, h: 476 } };
    const fit = placement({ canvas: "fit", card });
    assert.deepEqual([fit.W, fit.H, fit.cardX, fit.cardY], [1080, 832, 0, 0]);
    assert.equal(fit.W % 2 + fit.H % 2 + fit.boxW % 2 + fit.boxH % 2, 0);
    assert.ok(fit.boxX <= 150 && fit.boxX + fit.boxW >= 150 + 846, "the video covers the hole");
    const tall = placement({ canvas: "portrait", card });
    assert.deepEqual([tall.W, tall.H], [1080, 1920]);
    assert.ok(tall.cardX >= 60 && tall.cardY >= 60 && tall.cardX + tall.cardW <= 1020);
    const sq = placement({ canvas: "square", card: { w: 1080, h: 2000, box: { x: 0, y: 100, w: 1080, h: 1350 } } });
    assert.ok(sq.cardH <= 960 && sq.cardY >= 60, JSON.stringify(sq));
});

test("ffmpeg: blurred background only off fit, the sound kept when there is one, the trim applied", () => {
    const p = placement({ canvas: "portrait", card: { w: 1080, h: 900, box: { x: 10, y: 10, w: 1000, h: 560 } } });
    const a = ffmpegArgs({ video: "v", card: "c.png", out: "o.mp4", from: 2, length: 5, p, blurBg: true, bg: "black", audio: true }).join(" ");
    assert.match(a, /-ss 2\.000 -t 5\.000 -i v/);
    assert.match(a, /boxblur/);
    assert.match(a, /-map 0:a:0/);
    const b = ffmpegArgs({ video: "v", card: "c.png", out: "o.mp4", from: 0, length: 5, p, blurBg: false, bg: "black", audio: false }).join(" ");
    assert.doesNotMatch(b, /boxblur|-ss|0:a/);
    assert.match(b, /color=c=black/);
});

const chromium = process.env.CHAT_CHROMIUM || chromiumPath();
const can = ffmpegAvailable() && spawnSync("ffprobe", ["-version"]).status === 0 && existsSync(chromium);

test("a post frame renders through the container API: card size, the video inside, its sound, poster", { skip: can ? false : "no ffmpeg or Chromium", timeout: 240_000 }, async () => {
    const work = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "post-frame-"));
    const KEY = "k";
    const h = createEditServer({ internalKey: KEY, workDir: path.join(work, "render"), ffmpeg: FFMPEG, chromium, idleMs: 120_000 });
    try {
        await h.clean();
        await new Promise((r) => h.server.listen(0, "127.0.0.1", r));
        const base = `http://127.0.0.1:${h.server.address().port}`;
        const call = (method, p, body) => fetch(base + p, { method, body, headers: { "x-internal-key": KEY } });
        const clip = path.join(work, "clip.mp4"), avatar = path.join(work, "a.jpg");
        // a pure red video: its colour must show inside the card's hole
        ff(["-f", "lavfi", "-i", "color=c=red:s=640x360:r=30:d=3", "-f", "lavfi", "-i", "sine=f=440:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", clip]);
        ff(["-f", "lavfi", "-i", "color=c=blue:s=100x100", "-frames:v", "1", avatar]);
        for (const [i, [style, theme, canvas]] of [["x", "dark", "fit"], ["youtube", "light", "portrait"], ["generic", "light", "square"]].entries()) {
            const RID = `Rpost00000000000000${i}`;
            assert.equal((await call("PUT", `/renders/${RID}/inputs/0`, readFileSync(clip))).status, 204);
            assert.equal((await call("PUT", `/renders/${RID}/inputs/1`, readFileSync(avatar))).status, 204);
            const spec = {
                kind: "post", style, theme, canvas, from: 1, to: 2.5, host: "example.com",
                details: { name: "mochi", handle: "@mochibytes", text: "<img src=x onerror=alert(1)> the cat", title: "a title", posted_at: 1762600000000, counts: { likes: 18000, views: 402000 } },
            };
            const st = await call("POST", `/renders/${RID}/start`, JSON.stringify({ post: spec, inputs: [] }));
            assert.equal(st.status, 202);
            let body;
            for (const t0 = Date.now(); ; ) {
                body = await (await call("GET", `/renders/${RID}`)).json();
                if (body.status === "done" || body.status === "error") break;
                assert.ok(Date.now() - t0 < 120_000, JSON.stringify(body));
                await new Promise((r) => setTimeout(r, 200));
            }
            assert.equal(body.status, "done", JSON.stringify(body));
            assert.equal(body.width, 1080);
            if (canvas === "portrait") assert.equal(body.height, 1920);
            if (canvas === "square") assert.equal(body.height, 1080);
            assert.ok(Math.abs(body.duration - 1.5) < 0.2, JSON.stringify(body));
            const out = path.join(work, `out${i}.mp4`);
            writeFileSync(out, Buffer.from(await (await call("GET", `/renders/${RID}/file`)).arrayBuffer()));
            assert.equal(videoFacts(out).width, 1080);
            const audio = spawnSync("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0", out]).stdout.toString().trim();
            assert.equal(audio, "aac");
            // the frame's colours: red (the video) is in it, and so is the card (not all red)
            const px = spawnSync(FFMPEG, ["-v", "error", "-ss", "0.5", "-i", out, "-frames:v", "1", "-vf", "scale=54:-2", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]).stdout;
            let red = 0, other = 0;
            for (let k = 0; k + 2 < px.length; k += 3) {
                if (px[k] > 200 && px[k + 1] < 60 && px[k + 2] < 60) red++;
                else other++;
            }
            assert.ok(red > 50 && other > 50, `red ${red}, other ${other}`);
            assert.equal((await call("GET", `/renders/${RID}/poster`)).status, 200);
            assert.equal((await call("DELETE", `/renders/${RID}`)).status, 204);
        }
    } finally {
        await h.killAll();
        await new Promise((r) => h.server.close(r));
        rmSync(work, { recursive: true, force: true });
    }
});
