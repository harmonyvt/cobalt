// Proves the widgets in Chromium: every view and state on the dev host (ext-apps' real AppBridge) -- renders from the
// fixture, the main interaction sends the right tools/call, light and dark, 320 px, text-only titles, screenshots.
//   node widgets-dev/check.mjs      (Playwright with Chromium must be installed globally)
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { buildHost } from "./build.mjs";
import { serve } from "./serve.mjs";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const here = dirname(fileURLToPath(import.meta.url));
const shots = join(here, "shots");
rmSync(shots, { recursive: true, force: true });
mkdirSync(shots, { recursive: true });

execFileSync("node", [join(here, "../scripts/build-widgets.mjs")], { stdio: "inherit" });
await buildHost();

// ---- a stand-in for PUT /mcp/upload/<token>: CORS, and the real route's answers
const puts = [];
const up = { fail401: 0 };
const upSrv = createServer((req, res) => {
    const cors = { "access-control-allow-origin": "*", "access-control-allow-methods": "PUT, OPTIONS", "access-control-allow-headers": "content-type", "access-control-max-age": "600" };
    if (req.method === "OPTIONS") return res.writeHead(204, cors).end();
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
        const body = Buffer.concat(chunks);
        const type = (req.headers["content-type"] || "").split(";")[0];
        const reply = (st, o) => res.writeHead(st, { ...cors, "content-type": "application/json" }).end(JSON.stringify(o));
        const path = req.url.split("?")[0];
        puts.push({ url: path, qname: new URL(req.url, "http://x").searchParams.get("name"), type, bytes: body.length, method: req.method });
        if (up.fail401 > 0) { up.fail401--; return reply(401, { status: "error", error: { code: "error.mcp.upload_link" } }); }
        if (type === "application/octet-stream" || type === "text/plain") return reply(415, { status: "error", error: { code: "error.library.unsupported" } });
        const name = decodeURIComponent(path.split("/").pop()).replace(/^tok\d+-/, "");
        reply(201, { status: "success", id: null, url: null, item: { id: "up-" + puts.length, kind: "private", name, content_type: type, bytes: body.length, poster_url: null, visibility: "private" }, studio_error: null, public_state: null, public_url: null });
    });
});
await new Promise((r) => upSrv.listen(0, "127.0.0.1", r));
const upBase = `http://127.0.0.1:${upSrv.address().port}`;

const web = await serve(0);
const base = `http://127.0.0.1:${web.address().port}`;

// ---- tiny test kit
let pass = 0;
const fails = [];
function ok(cond, msg) {
    if (cond) pass++;
    else { fails.push(msg); console.log("  FAIL " + msg); }
}
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), `${msg}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
const ONLY = process.argv[2]; // optional: run only the steps whose name contains this text
async function step(name, fn) {
    if (ONLY && !name.includes(ONLY)) return;
    const before = fails.length;
    try { await fn(); } catch (e) { fails.push(`${name}: ${String(e.message).split("\n")[0]}`); console.log(`  FAIL ${name}: ${String(e.message).split("\n")[0]}`); }
    console.log(`${fails.length === before ? "ok  " : "FAIL"} ${name}`);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, permissions: ["clipboard-read", "clipboard-write"] });
const external = [];
await ctx.route("**/*", (route) => {
    const u = route.request().url();
    if (u.startsWith(base) || u.startsWith(upBase) || u.startsWith("data:") || u.startsWith("about:") || u.startsWith("blob:")) return route.continue();
    external.push(u);
    return route.abort();
});
const page = await ctx.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|ERR_FAILED|net::/.test(m.text())) pageErrors.push(m.text()); });
// A scripted job_status for one test: answers the widget's tools/call itself (before the host's bridge sees it) and gives
// every answer a NEW job id, as the real tool does when a file that was opening starts its render.
await page.addInitScript(() => {
    window.__jobScript = null;
    window.addEventListener(
        "message",
        (ev) => {
            const m = ev.data;
            const s = window.__jobScript;
            if (!s || !m || m.method !== "tools/call" || !m.params || m.params.name !== "job_status") return;
            ev.stopImmediatePropagation();
            s.seen.push(m.params.arguments.job);
            const done = s.seen.length >= 3;
            const post = { id: "post-new", title: "made by the new job", kind: "image", thumb_url: null, duration_s: null, saved_at: "2026-11-11T14:14:00Z", source_host: null, status: "public", files: 1, bytes: null };
            ev.source.postMessage({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: "x" }], structuredContent: { job: s.to, state: done ? "done" : "running", progress: 0.5, error: null, post: done ? post : null, share_url: null } } }, "*");
        },
        true,
    );
});
await page.goto(`${base}/?up=${encodeURIComponent(upBase)}`);
await page.waitForSelector("body[data-ready]");
const keys = await page.evaluate(() => __host.keys);

const fr = () => page.frames().find((f) => f !== page.mainFrame());
const F = () => page.frameLocator("iframe");
async function open(key, { theme = "light", width = 640, quiet = false } = {}) {
    await page.evaluate(([k, t, w]) => { __host.reset(); __host.setTheme(t); __host.setWidth(w); return __host.load(k); }, [key, theme, width]);
    if (!key.startsWith("skeleton")) await F().locator(".widget > *").first().waitFor({ timeout: 5000 });
    await page.waitForTimeout(120);
}
const calls = () => page.evaluate(() => __host.log.calls);
const lastCall = async () => {
    await page.waitForTimeout(150);
    return (await calls()).at(-1);
};
const hostLinks = async () => {
    await page.waitForTimeout(150);
    return page.evaluate(() => __host.log.links);
};
const shot = (name) => page.locator("iframe").screenshot({ path: join(shots, name + ".png") });
const txt = (sel) => F().locator(sel).first().innerText();
const count = (sel) => F().locator(sel).count();

// ---------------------------------------------------------------- every fixture: light, dark, 320, no overflow
for (const key of keys) {
    await step(`${key}: light, dark, 320 px`, async () => {
        await open(key);
        if (key.startsWith("skeleton")) { ok((await count(".sk")) > 0, `${key} shows a skeleton`); await shot(key + ".light"); return; }
        ok((await count(".widget")) === 1, `${key} draws a widget`);
        const sizes = await page.evaluate(() => __host.log.sizes.length);
        ok(sizes > 0, `${key} sent size-changed`);
        const h = await page.evaluate(() => document.querySelector("iframe").getBoundingClientRect().height);
        const ch = await fr().evaluate(() => Math.ceil(document.documentElement.getBoundingClientRect().height));
        ok(Math.abs(h - ch) <= 2, `${key} iframe height ${h} follows content ${ch}`);
        await shot(key + ".light");
        const bgL = await fr().evaluate(() => getComputedStyle(document.querySelector(".widget")).backgroundColor);
        await open(key, { theme: "dark" });
        await shot(key + ".dark");
        const bgD = await fr().evaluate(() => getComputedStyle(document.querySelector(".widget")).backgroundColor);
        ok(bgL !== bgD, `${key} dark differs from light (${bgL} vs ${bgD})`);
        await open(key, { width: 320 });
        const over = await fr().evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        ok(over <= 1, `${key} fits 320 px (overflow ${over})`);
        // nothing may be cut off by the widget's own overflow:hidden either
        const cut = await fr().evaluate(() => {
            const limit = document.querySelector(".widget").getBoundingClientRect().right + 1;
            return [...document.querySelectorAll(".widget *")]
                .filter((e) => !e.closest(".lane, .cells, .mos, .pic, .stack, .sk, .skg") && !e.classList.contains("hd") && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().right > limit)
                .map((e) => e.className || e.tagName).slice(0, 5);
        });
        eq(cut, [], `${key} has nothing cut off at 320 px`);
        await shot(key + ".w320");
        await open(key, { width: 760 });
        const over2 = await fr().evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        ok(over2 <= 1, `${key} fits 760 px`);
    });
}

// ---------------------------------------------------------------- search -> post -> back
await step("search: grid, kinds, placeholders, tap to post, back without a call", async () => {
    await open("search.grid");
    eq(await count(".th"), 8, "eight thumbs");
    ok((await txt(".whead")).includes("21 posts"), "header counts the total");
    eq(await count(".th .pic img"), 6, "six thumbs have pictures, two are placeholders");
    ok((await F().locator(".th .badge").allInnerTexts()).includes("0:14"), "video duration badge");
    ok((await F().locator(".th .kind").allInnerTexts()).includes("gallery"), "kind badge");
    ok((await txt(".note")).includes("showing 8 of 21"), "shows 8 of 21 note");
    await F().locator(".th").nth(1).click();
    await F().locator(".post").waitFor();
    eq(await lastCall(), { name: "show_post", arguments: { id: "post-vid-1" } }, "tap calls show_post");
    ok((await count("video[controls][playsinline][preload=metadata]")) === 1, "post draws a video with controls");
    ok((await F().locator("video").getAttribute("poster")).startsWith("data:image"), "poster from thumb_url");
    const n = (await calls()).length;
    await F().locator("button[aria-label=back]").click();
    await F().locator(".thumbs").waitFor();
    eq((await calls()).length, n, "back makes no call");
    eq(await count(".th"), 8, "grid is back");
});
await step("search: empty and text mode", async () => {
    await open("search.empty");
    ok((await txt(".empty")).includes("no posts found"), "empty message");
    await open("search.few");
    ok((await txt(".whead")).includes("text match"), "text mode tag");
});

// ---------------------------------------------------------------- post
await step("post.video: meta, share row, copy fallback, similar, links, full screen", async () => {
    await open("post.video");
    ok((await txt(".whead")).includes("cat girl reacts"), "title");
    ok((await txt(".pill")) === "public", "status pill");
    const meta = await txt(".meta");
    ok(meta.includes("x.com") && meta.includes("0:14") && meta.includes("1080×1920"), "from, length and size rows");
    ok(meta.includes("wait is that me"), "transcript excerpt");
    ok((await txt(".linkrow")).includes("share.capybaraharmony.com/Qm3vT8x2"), "share link row");
    await F().locator(".linkrow .btn").click();
    await F().locator(".cpfall textarea").waitFor();
    eq(await F().locator(".cpfall textarea").inputValue(), "https://share.capybaraharmony.com/Qm3vT8x2", "sandboxed clipboard refused: text is selected in a field");
    await F().getByRole("button", { name: "find similar" }).click();
    await F().locator(".thumbs").waitFor();
    eq(await lastCall(), { name: "search_library", arguments: { query: "cat girl reacts to the new emote" } }, "find similar");
    await open("post.video");
    await F().locator(".meta a.ext").first().click();
    eq((await hostLinks()).at(-1), "https://x.com/someone/status/1987", "source link opens through the host");
    await F().getByRole("button", { name: "open in capystore" }).first().click();
    ok((await hostLinks()).at(-1).includes("cobalt.capybaraharmony.com"), "open in capystore");
    await F().getByRole("button", { name: "full screen" }).click();
    await page.waitForTimeout(150);
    eq(await page.evaluate(() => __host.log.display), ["fullscreen"], "full screen asks the host");
});
await step("post: image, gallery files, private placeholder", async () => {
    await open("post.image");
    eq(await count(".player img"), 1, "image post draws an img");
    eq(await count("video"), 0, "no video");
    await open("post.gallery");
    eq(await count(".files .btn"), 4, "four file buttons");
    await F().locator(".files .btn").nth(2).click();
    ok((await F().locator(".player img").getAttribute("src")).endsWith("gal-3.png"), "third file shown");
    await open("post.private");
    ok((await txt(".player .none")).includes("private: open in capystore"), "private placeholder");
    eq(await count("video"), 0, "no video for a private post");
    ok((await txt(".meta")).includes("p/9fK2/1.mp4"), "private link row");
    ok((await txt(".pill")) === "private", "private pill");
});

// ---------------------------------------------------------------- injection: titles stay text
await step("titles with markup stay text", async () => {
    const x = "<img src=x onerror=\"window.__xss=1\">pwned <b>bold</b>";
    await open("post.xss");
    eq(await txt(".whead b"), x, "post title is the literal text");
    await open("links.list");
    ok((await F().locator(".lk .t b").allInnerTexts()).includes(x), "link title literal");
    await open("collections.grid");
    ok((await F().locator(".col b").allInnerTexts()).includes(x), "collection name literal");
    await open("edit.list");
    ok((await F().locator(".lk .t b").allInnerTexts()).includes(x), "edit title literal");
    await open("search.grid");
    await F().locator("button.th").first().waitFor();
    eq(await count("img[src=x]"), 0, "no injected img element");
    eq(await fr().evaluate(() => window.__xss), undefined, "injected handler never ran");
});

// ---------------------------------------------------------------- edit
await step("edit: tracks, clip geometry, playhead (click, drag, keys), highlight, ruler", async () => {
    await open("edit.project");
    ok((await txt(".whead")).includes("rev 3"), "revision in header");
    ok((await txt(".whead .pill")).includes("rendered"), "render pill");
    eq(await F().locator(".trk label").allInnerTexts(), ["overlay", "", "main", "sound"], "track labels (overlays stack in two rows)");
    const w = await F().locator(".lane").nth(2).locator(".clip").first().evaluate((e) => e.style.width);
    ok(Math.abs(parseFloat(w) - 47.05) < 0.1, `first main clip width ${w}`);
    eq(await count(".lane .clip.dim"), 1, "muted clip dimmed in the sound track");
    const ticks = await F().locator(".ruler span").allInnerTexts();
    ok(ticks.length >= 4 && ticks.length <= 10 && ticks[0] === "0:00", `ruler ticks ${ticks.join(" ")}`);
    const box = await F().locator(".tracks").boundingBox();
    const at = (f) => ({ x: box.x + 64 + (box.width - 74) * f, y: box.y + box.height / 2 });
    let p = at(0.5);
    await page.mouse.click(p.x, p.y);
    ok(/^0:17\.\d \/ 0:34\.4$/.test(await txt(".tc")), `click sets the timecode: ${await txt(".tc")}`);
    eq(await F().locator(".lane").nth(2).locator(".clip.on").count(), 1, "clip under the playhead highlighted");
    ok((await txt(".ph").catch(() => "")) === "", "playhead has no text");
    p = at(0.2);
    await page.mouse.move(at(0.1).x, p.y);
    await page.mouse.down();
    await page.mouse.move(p.x, p.y, { steps: 4 });
    await page.mouse.up();
    ok(/^0:0[67]\.\d \//.test(await txt(".tc")), `drag moves the playhead: ${await txt(".tc")}`);
    await F().locator(".ph").focus();
    await page.keyboard.press("ArrowRight");
    const v1 = await F().locator(".ph").getAttribute("aria-valuenow");
    await page.keyboard.press("ArrowRight");
    ok(Math.abs(Number(await F().locator(".ph").getAttribute("aria-valuenow")) - Number(v1) - 0.5) < 0.01, "arrow key moves by half a second");
    await page.keyboard.press("End");
    ok((await txt(".tc")).startsWith("0:34.4"), "End goes to the end");
    await page.keyboard.press("Home");
    ok((await txt(".tc")).startsWith("0:00.0"), "Home goes to the start");
    eq(await F().locator(".ph").getAttribute("role"), "slider", "playhead is a slider");
    await F().getByRole("button", { name: "view render" }).click();
    await F().locator(".post").waitFor();
    eq(await lastCall(), { name: "show_post", arguments: { id: "post-vid-1" } }, "view render opens the post");
});
await step("edit: long and short timelines, list, no render", async () => {
    await open("edit.long");
    const t = await F().locator(".ruler span").allInnerTexts();
    ok(t.length <= 9 && t.some((x) => x.startsWith("1:")) , `long ruler: ${t.join(" ")}`);
    ok((await txt(".whead .pill")).includes("rendering 40%"), "running render pill");
    await open("edit.short");
    const s = await F().locator(".ruler span").allInnerTexts();
    ok(s.length >= 4 && s.some((x) => x.includes(".")), `short ruler has sub-second ticks: ${s.join(" ")}`);
    ok((await txt(".whead .pill")).includes("out of date"), "stale pill");
    await open("edit.list");
    eq(await count(".lk"), 3, "three projects");
    await F().locator(".lk .btn").first().click();
    await F().locator(".tracks").waitFor();
    eq(await lastCall(), { name: "show_edit", arguments: { id: "edit-1" } }, "row calls show_edit");
});

// ---------------------------------------------------------------- collections, links
await step("collections: mosaics, counts, copy all, open, new", async () => {
    await open("collections.grid");
    eq(await count(".col"), 4, "four cards");
    ok((await txt(".whead")).includes("19 collections"), "total");
    eq(await F().locator(".col").nth(0).locator(".mos .pic").count(), 8, "mosaic of eight");
    ok((await txt(".col small")).includes("1 link · 10 posts"), "counts");
    eq(await F().locator(".col").nth(2).locator(".btn").count(), 0, "no copy-all on a collection without links");
    await F().locator(".col").nth(1).locator(".btn").click();
    await F().locator(".cpfall textarea").waitFor();
    eq(await F().locator(".cpfall textarea").inputValue(), "https://share.capybaraharmony.com/g/bbb\nhttps://share.capybaraharmony.com/g/ccc", "copy all joins the urls with newlines");
    await F().getByRole("button", { name: "new collection" }).click();
    await page.waitForTimeout(150);
    eq(await page.evaluate(() => __host.log.messages.length), 1, "new collection sends a message");
    await F().locator(".col .open").nth(1).click();
    await F().locator(".lk").first().waitFor();
    eq(await lastCall(), { name: "list_share_links", arguments: { collection: "Lia Share 5" } }, "tap opens the links");
    await F().locator("button[aria-label=back]").click();
    eq(await count(".col"), 4, "back to the grid");
    await open("collections.empty");
    ok((await txt(".empty")).includes("no collections"), "empty");
});
await step("links: rows, fallback title, private tag, created highlight, copy", async () => {
    await open("links.created");
    eq(await count(".lk"), 4, "four rows");
    const titles = await F().locator(".lk .t b").allInnerTexts();
    ok(titles.includes("10 files · 6 Nov"), `fallback title: ${titles.join(" | ")}`);
    eq(await count(".lk.new"), 1, "created link highlighted");
    ok((await F().locator(".lk.new").innerText()).includes("10 files"), "it is the created one");
    eq(await F().locator(".lk .tag.w").allInnerTexts(), ["private"], "private tag");
    eq(await F().locator(".lk").nth(0).locator(".stack .pic").count(), 4, "stacked thumbs");
    await F().locator(".lk .btn").nth(0).click();
    eq(await F().locator(".cpfall textarea").inputValue(), "https://share.capybaraharmony.com/g/7Kp2xQ", "copy fallback text");
    await F().getByRole("button", { name: "copy all links" }).click();
    ok((await F().locator(".cpfall textarea").inputValue()).split("\n").length === 4, "copy all has four lines");
    await F().locator(".lk .t a").first().click();
    eq((await hostLinks()).at(-1), "https://share.capybaraharmony.com/g/7Kp2xQ", "url opens through the host");
    await open("links.empty");
    ok((await txt(".empty")).includes("no share links"), "empty");
});

// ---------------------------------------------------------------- webp
await step("webp pick: handles, limits, keys, drag, convert -> running -> done", async () => {
    await open("webp.pick");
    ok((await txt(".whead")).includes("HARMONY JUMPSCARE"), "source title");
    eq(await count(".hd"), 2, "two handles");
    ok((await txt(".whead .hr")).includes("5.0 s · 480 px · med"), "live readout");
    const he = F().locator(".hd[aria-label=end]");
    await he.focus();
    await page.keyboard.press("Shift+ArrowRight");
    ok((await txt(".whead .hr")).includes("10.0 s"), "grows to ten");
    await page.keyboard.press("Shift+ArrowRight");
    ok((await txt(".whead .hr")).includes("10.0 s"), "stays at the ten second limit");
    eq(await he.getAttribute("aria-valuenow"), "15", "end moved, start pushed");
    const hs = F().locator(".hd[aria-label=start]");
    eq(await hs.getAttribute("aria-valuenow"), "5", "start pushed to 5");
    await hs.focus();
    for (let i = 0; i < 40; i++) await page.keyboard.press("Shift+ArrowRight");
    await he.focus();
    for (let i = 0; i < 40; i++) await page.keyboard.press("Shift+ArrowLeft");
    ok((await txt(".whead .hr")).includes("0.5 s"), `shortest is half a second: ${await txt(".whead .hr")}`);
    // drag the end handle across the strip
    const sb = await F().locator(".strip").boundingBox();
    const hb = await he.boundingBox();
    await page.mouse.move(hb.x + hb.width / 2, hb.y + hb.height / 2);
    await page.mouse.down();
    await page.mouse.move(sb.x + sb.width * 0.2, hb.y + 10, { steps: 5 });
    await page.mouse.up();
    const endv = Number(await he.getAttribute("aria-valuenow"));
    const startv = Number(await hs.getAttribute("aria-valuenow"));
    ok(endv > 10 && endv - startv <= 10.0001 && endv - startv >= 0.5, `drag respects limits: ${startv}-${endv}`);
    await F().getByRole("button", { name: "high" }).click();
    await F().getByRole("button", { name: "320" }).click();
    ok((await txt(".whead .hr")).includes("320 px · high"), "segments update the readout");
    await F().getByRole("button", { name: "convert" }).click();
    await F().locator(".prog").waitFor();
    const c = await calls();
    const conv = c.find((x) => x.name === "convert_to_webp");
    eq([conv.arguments.id, conv.arguments.width, conv.arguments.quality, typeof conv.arguments.start, typeof conv.arguments.end], ["post-vid-2", 320, "high", "number", "number"], "convert_to_webp arguments");
    ok(Math.abs(conv.arguments.start - startv) < 0.01 && Math.abs(conv.arguments.end - endv) < 0.01, "the picked range is what is sent");
    await F().locator(".result").waitFor({ timeout: 9000 });
    const polls = (await calls()).filter((x) => x.name === "job_status");
    ok(polls.length >= 3 && polls.every((x) => x.arguments.job === "job-webp-2"), `polled job_status ${polls.length} times`);
    ok((await txt(".result")).includes("share.capybaraharmony.com/jmpscr-webp"), "done shows the share link");
    await F().getByRole("button", { name: "open post" }).click();
    eq(await lastCall(), { name: "show_post", arguments: { id: "post-webp-1" } }, "open post");
});
await step("webp running: polls with the newest job id an answer carried", async () => {
    await open("webp.running");
    await page.evaluate(() => { window.__jobScript = { to: "studio:SID:newjob", seen: [] }; });
    await F().locator(".result").waitFor({ timeout: 12000 });
    const seen = await page.evaluate(() => window.__jobScript.seen);
    await page.evaluate(() => { window.__jobScript = null; });
    eq(seen[0], "job-webp-1", "the first poll uses the id the tool gave");
    ok(seen.length >= 3 && seen.slice(1).every((j) => j === "studio:SID:newjob"), `later polls use the newest id: ${JSON.stringify(seen)}`);
});
await step("save running: polls with the newest job id too", async () => {
    await open("save.running");
    await page.evaluate(() => { window.__jobScript = { to: "save:NEWID", seen: [] }; });
    await F().locator(".result").waitFor({ timeout: 12000 });
    const seen = await page.evaluate(() => window.__jobScript.seen);
    await page.evaluate(() => { window.__jobScript = null; });
    ok(seen.length >= 3 && seen.slice(1).every((j) => j === "save:NEWID"), `later polls use the newest id: ${JSON.stringify(seen)}`);
});
await step("webp running: bar moves, polls one at a time, stops on teardown; stalls note", async () => {
    await open("webp.running");
    ok((await F().locator(".prog").getAttribute("aria-valuenow")) === "20", "starts at the fixture progress");
    await page.evaluate(() => __host.setDelay(400));
    await F().locator(".result").waitFor({ timeout: 12000 });
    ok(true, "reached done");
    await open("webp.running");
    await page.evaluate(() => __host.teardown());
    const n = (await calls()).length;
    await page.waitForTimeout(2500);
    eq((await calls()).length, n, "no polling after teardown");
    // the job cannot be reached three times in a row: a note and a way to check again
    await open("webp.running");
    await page.evaluate(() => __host.failNext("job_status", "gateway timeout", 3));
    await F().getByRole("button", { name: "check again" }).waitFor({ timeout: 12000 });
    ok((await txt(".steps")).includes("can't reach the job"), "stalled note");
    await F().getByRole("button", { name: "check again" }).click();
    await F().locator(".result").waitFor({ timeout: 9000 });
    ok(true, "check again resumes to done");
});
await step("webp error: message and retry; done: copy", async () => {
    await open("webp.error");
    ok((await txt(".err")).includes("the clip could not be read"), "error message");
    await F().getByRole("button", { name: "retry" }).click();
    await F().locator(".prog").waitFor();
    eq(await lastCall(), { name: "convert_to_webp", arguments: { id: "post-vid-2", start: 41, end: 45.5, width: 480, quality: "med" } }, "retry repeats the conversion");
    await open("webp.done");
    ok((await txt(".note")).includes("4.5 s · 480 px · med · 1.9 MB"), `result facts: ${await txt(".note")}`);
    await F().locator(".linkrow .btn").click();
    eq(await F().locator(".cpfall textarea").inputValue(), "https://share.capybaraharmony.com/jmpscr-webp", "copy share link");
    eq(await count(".result .pic img"), 1, "result picture");
});

// ---------------------------------------------------------------- save
await step("save: running -> done card; error retry", async () => {
    await open("save.running");
    ok((await txt(".job .u")).includes("x.com/someone/status/1987654321"), "shows the link");
    await F().locator(".result").waitFor({ timeout: 9000 });
    ok((await txt(".result")).includes("cat girl reacts"), "saved post card");
    await F().getByRole("button", { name: "open post" }).click();
    await F().locator(".post").waitFor();
    eq(await lastCall(), { name: "show_post", arguments: { id: "post-vid-1" } }, "card opens the post");
    await open("save.error");
    ok((await txt(".err")).includes("no video we can download"), "error plain");
    await F().getByRole("button", { name: "retry" }).click();
    await F().locator(".prog").waitFor();
    eq(await lastCall(), { name: "save_link", arguments: { url: "https://x.com/someone/status/1987654321", engine: "ytdlp" } }, "retry calls save_link and keeps the chosen engine");
    await open("save.done");
    ok((await count(".result")) === 1, "done draws the card at once");
    ok((await txt(".result")).includes("share.capybaraharmony.com/Qm3vT8x2"), "a finished save shows its share link");
});

// ---------------------------------------------------------------- upload
const buf = (n) => Buffer.alloc(n, 7);
const f3 = () => [
    { name: "dance.mp4", mimeType: "video/mp4", buffer: buf(2_500_000) },
    { name: "lia-wave.gif", mimeType: "image/gif", buffer: buf(321_000) },
    { name: "thumb.png", mimeType: "image/png", buffer: buf(41_200) },
];
await step("upload: pairs files with links, PUTs with progress, shows items, taps open a post", async () => {
    puts.length = 0;
    await open("upload.tray");
    eq(await count(".up"), 3, "three slots");
    ok((await txt(".up")).includes("waiting for a file"), "slots wait for files");
    ok((await F().locator("input[type=file]").getAttribute("accept")).includes(".mp4"), "accept from the result");
    await F().locator("input[type=file]").setInputFiles(f3());
    await F().locator(".up.ok").nth(2).waitFor({ timeout: 8000 });
    eq(puts.filter((p) => p.method === "PUT").map((p) => [p.type, p.bytes]), [["video/mp4", 2_500_000], ["image/gif", 321_000], ["image/png", 41_200]], "three PUTs with the right bytes and types");
    ok(puts.filter((p) => p.method === "PUT").map((p) => p.url).every((u, i) => u.includes(["dance.mp4", "lia-wave.gif", "thumb.png"][i])), "each file went to its own link");
    eq(puts.filter((p) => p.method === "PUT").map((p) => p.qname), ["dance.mp4", "lia-wave.gif", "thumb.png"], "each PUT names the chosen file");
    eq(await count(".up .tag"), 3, "in library tags");
    eq(await F().locator(".up .prog").first().getAttribute("aria-valuenow"), "100", "progress at 100");
    await F().locator(".up .btn").first().click();
    await page.waitForTimeout(300);
    eq(await lastCall(), { name: "show_post", arguments: { id: "up-1" } }, "tap calls show_post with the item id");
    eq(await count(".up"), 3, "a failed show_post leaves the tray alone");
    ok((await txt(".err.top")).includes("no post with that id"), "inline error on top");
    await shot("upload.done");
});
await step("upload: the chosen file's own name goes with the PUT, cut to 200 characters keeping its extension", async () => {
    puts.length = 0;
    await open("upload.tray");
    const long = "x".repeat(250) + ".png";
    await F().locator("input[type=file]").setInputFiles([{ name: "other.png", mimeType: "image/png", buffer: buf(900) }, { name: long, mimeType: "image/png", buffer: buf(900) }]);
    await F().locator(".up.ok").nth(1).waitFor({ timeout: 8000 });
    const names = puts.filter((p) => p.method === "PUT").map((p) => p.qname);
    eq(names[0], "other.png", "a file paired with a link of another name still goes under its own name");
    ok(names[1].length === 200 && names[1].endsWith(".png"), `a long name is cut to 200 with its extension: ${names[1] && names[1].length}`);
});
await step("upload: more files than links, expired link, unsupported, too big, unreachable", async () => {
    puts.length = 0;
    await open("upload.tray");
    await F().locator("input[type=file]").setInputFiles([...f3(), { name: "extra.png", mimeType: "image/png", buffer: buf(5000) }]);
    await F().locator(".up.ok").nth(3).waitFor({ timeout: 8000 });
    eq(await count(".up"), 4, "a fourth row");
    ok((await calls()).some((c) => c.name === "upload_files" && JSON.stringify(c.arguments) === JSON.stringify({ files: [{ name: "extra.png" }], public: false })), "asked for one more link");
    // an expired link
    await open("upload.tray");
    up.fail401 = 1;
    await F().locator("input[type=file]").setInputFiles([f3()[2]]);
    await F().getByRole("button", { name: "get a fresh link" }).waitFor({ timeout: 5000 });
    ok((await txt(".up.bad")).includes("link expired"), "expired link is explained");
    await F().getByRole("button", { name: "get a fresh link" }).click();
    await F().locator(".up.ok").waitFor({ timeout: 5000 });
    ok((await calls()).some((c) => c.name === "upload_files" && c.arguments.files[0].name === "thumb.png"), "fresh link requested for that file");
    // a type the library refuses
    await open("upload.tray");
    await F().locator("input[type=file]").setInputFiles([{ name: "notes.txt", mimeType: "text/plain", buffer: buf(300) }]);
    await F().locator(".up.bad").waitFor({ timeout: 5000 });
    ok((await txt(".up.bad")).includes("file type isn't supported"), "unsupported reason");
    ok((await F().getByRole("button", { name: "retry" }).count()) === 1, "retry offered");
    // too big
    await page.evaluate(() => __host.setMax(1000));
    await open("upload.tray");
    await F().locator("input[type=file]").setInputFiles([f3()[2]]);
    await F().locator(".up.bad").waitFor({ timeout: 5000 });
    ok((await txt(".up.bad")).includes("too big"), "too big reason");
    await page.evaluate(() => __host.setMax(null));
    // the service cannot be reached
    await page.evaluate(() => __host.setUploadBase("http://127.0.0.1:9"));
    await open("upload.tray");
    await F().locator("input[type=file]").setInputFiles([f3()[2]]);
    await F().locator(".up.bad").waitFor({ timeout: 8000 });
    ok((await txt(".up.bad")).includes("couldn't reach capystore"), "network failure reason");
    await page.evaluate((u) => __host.setUploadBase(u), upBase);
    // drop zone is a real keyboard control
    await open("upload.tray");
    eq(await F().locator(".drop").getAttribute("role"), "button", "drop zone is a button");
});

// ---------------------------------------------------------------- errors, skeleton, host styles, copy, standalone
await step("tool error: inline banner with retry, view kept", async () => {
    await open("search.grid");
    await page.evaluate(() => __host.failNext("show_post", "the library is asleep"));
    await F().locator(".th").first().click();
    await F().locator(".err.top").waitFor();
    ok((await txt(".err.top")).includes("the library is asleep"), "message shown");
    eq(await count(".th"), 8, "grid still there");
    await F().getByRole("button", { name: "try again" }).click();
    await F().locator(".post").waitFor();
    eq((await calls()).filter((c) => c.name === "show_post").length, 2, "retry called again");
    await open("error.first");
    ok((await txt(".err")).includes("no post with that id"), "first call error shown, not blank");
});
await step("host CSS variables are used", async () => {
    await page.evaluate(() => __host.setVars({ "--color-background-primary": "rgb(16, 32, 48)" }));
    await open("links.list");
    eq(await fr().evaluate(() => getComputedStyle(document.querySelector(".whead")).backgroundColor), "rgb(16, 32, 48)", "host variable reaches the header");
    await page.evaluate(() => __host.setVars(null));
});
await step("copy works when the host allows the clipboard", async () => {
    await page.goto(`${base}/?up=${encodeURIComponent(upBase)}&clip=1`);
    await page.waitForSelector("body[data-ready]");
    await open("links.list");
    await F().locator(".lk .btn").first().click();
    await page.waitForTimeout(200);
    eq(await txt(".lk .btn"), "copied", "button says copied");
    eq(await page.evaluate(() => navigator.clipboard.readText()), "https://share.capybaraharmony.com/g/7Kp2xQ", "clipboard holds the link");
    await page.goto(`${base}/?up=${encodeURIComponent(upBase)}`);
    await page.waitForSelector("body[data-ready]");
});
await step("standalone: prefers-color-scheme, reduced motion, injected result (window.openai)", async () => {
    const html = await page.evaluate(() => __host.html("search"));
    const p2 = await ctx.newPage();
    await p2.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
    await p2.setContent(html);
    await p2.waitForSelector(".sk", { state: "attached", timeout: 5000 });
    ok((await p2.locator(".sk").count()) > 0, "skeleton before a result");
    eq(await p2.evaluate(() => getComputedStyle(document.querySelector(".sk")).animationName), "none", "reduced motion stops the shimmer");
    const bg = await p2.evaluate(() => getComputedStyle(document.querySelector(".whead")).backgroundColor);
    eq(bg, "rgb(31, 29, 27)", "dark from prefers-color-scheme");
    await p2.close();
    const p3 = await ctx.newPage();
    await p3.addInitScript(() => { window.openai = { toolOutput: { view: "links", total: 1, created: null, links: [{ id: "a", url: "https://share.capybaraharmony.com/g/a", title: "injected", files: 1, private: false, created_at: "2026-11-06T10:00:00Z", thumbs: [], collection: null }] } }; });
    // init scripts only run on a real navigation: serve the page from a fake address
    await p3.route("https://widget.test/", (r) => r.fulfill({ contentType: "text/html", body: html }));
    await p3.goto("https://widget.test/");
    await p3.waitForSelector(".lk", { timeout: 5000 });
    eq(await p3.locator(".lk .t b").innerText(), "injected", "result injected by the host is drawn");
    await p3.close();
});
await step("only the allowed origins were asked for", async () => {
    const bad = external.filter((u) => !/^https:\/\/(media|share)\.capybaraharmony\.com\//.test(u) && !u.startsWith("http://127.0.0.1:9/"));
    eq(bad, [], "no other origin was requested");
    eq(pageErrors, [], "no script errors");
});

await browser.close();
web.close();
upSrv.close();
console.log(`\n${pass} assertions passed, ${fails.length} failed`);
console.log(`screenshots: ${shots}`);
if (fails.length) { console.log(fails.map((f) => " - " + f).join("\n")); process.exit(1); }
