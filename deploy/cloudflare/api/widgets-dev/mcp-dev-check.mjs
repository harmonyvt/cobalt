// Proves the MCP dev server end to end. Part 1: the official MCP client over real HTTP against the server (initialize,
// tools, widgets and their CSP, every app tool's answer against its own zod schema, the webp, save and upload flows).
// Part 2: Chromium (Playwright) drives the widgets on the dev host with its tool calls going to this server.
//   node widgets-dev/mcp-dev-check.mjs      (Playwright with Chromium must be installed globally)
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { deflateSync, crc32 } from "node:zlib";
import { buildHost } from "./build.mjs";
import { buildToolsBundle, startDev } from "./mcp-dev.mjs";
import { serve } from "./serve.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const shots = join(here, "shots");
mkdirSync(shots, { recursive: true });
const { APP_TOOLS, shapes, WIDGETS } = await import(pathToFileURL(await buildToolsBundle()).href);

let pass = 0;
const fails = [];
function ok(cond, msg) {
    if (cond) pass++;
    else {
        fails.push(msg);
        console.log("  FAIL " + msg);
    }
}
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), `${msg}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
async function step(name, fn) {
    const before = fails.length;
    try {
        await fn();
    } catch (e) {
        fails.push(`${name}: ${String(e.message).split("\n")[0]} @ ${String(e.stack).split("\n").find((l) => /mcp-dev-check/.test(l))?.trim()}`);
        console.log(`  FAIL ${name}: ${String(e.message).split("\n")[0]}`);
    }
    console.log(`${fails.length === before ? "ok  " : "FAIL"} ${name}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// a small valid PNG (solid colour), made here so no file is needed
function png(w, h, [r, g, b]) {
    const chunk = (type, data) => {
        const body = Buffer.concat([Buffer.from(type), data]);
        const len = Buffer.alloc(4);
        len.writeUInt32BE(data.length);
        const crc = Buffer.alloc(4);
        crc.writeUInt32BE(crc32(body));
        return Buffer.concat([len, body, crc]);
    };
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0);
    ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: w }, () => [r, g, b]).flat())]);
    const raw = Buffer.concat(Array.from({ length: h }, () => row));
    return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

// a short webp encode and save keep this quick; one call still waits at most 1.2 s, so the widgets see the jobs run
const dev = await startDev({ port: 0, webpMs: 3500, saveMs: 2500, waitCapMs: 1200 });
const origin = dev.publicOrigin;
const toolOf = (name) => APP_TOOLS.find((t) => t.name === name);
console.log(`dev server on ${dev.mcpUrl}`);

const client = new Client({ name: "mcp-dev-check", version: "1" });
await client.connect(new StreamableHTTPClientTransport(new URL(dev.mcpUrl)));

// call a tool, require success, and check structuredContent against the tool's own output schema
async function call(name, args = {}) {
    const r = await client.callTool({ name, arguments: args });
    ok(!r.isError, `${name} ${JSON.stringify(args).slice(0, 60)} succeeds: ${r.isError ? r.content?.[0]?.text : ""}`);
    ok(typeof r.content?.[0]?.text === "string" && r.content[0].text.length > 0, `${name} has a text answer`);
    const t = toolOf(name);
    const parsed = t.output.safeParse(r.structuredContent);
    ok(parsed.success, `${name} structuredContent passes its output schema${parsed.success ? "" : ": " + JSON.stringify(parsed.error.issues.slice(0, 2))}`);
    return r;
}
const sc = async (name, args) => (await call(name, args)).structuredContent;

await step("initialize, tools/list and resources over HTTP", async () => {
    eq(client.getServerVersion()?.name, "capystore", "server name");
    const caps = client.getServerCapabilities();
    ok(!!caps?.tools && !!caps?.resources, "tools and resources capabilities");
    ok(/search_library/.test(client.getInstructions() ?? ""), "instructions name the app tools");
    const { tools } = await client.listTools();
    const app = ["search_library", "show_post", "show_edit", "list_collections", "list_share_links", "convert_to_webp", "upload_files", "create_share_link", "save_link", "job_status"];
    eq(tools.slice(0, 10).map((t) => t.name), app, "ten app tools first");
    ok(tools.length > 10 && tools.some((t) => t.name === "library_title"), "the older tools follow");
    ok(!["library_list", "library_search", "library_post", "upload_begin", "jobs_wait"].some((n) => tools.some((t) => t.name === n)), "the retired duplicates are not listed");
    for (const t of tools.slice(0, 10)) {
        ok(t.outputSchema?.type === "object", `${t.name} has an outputSchema`);
        if (t.name === "job_status") eq(t._meta, undefined, "job_status is an ordinary tool: no widget, not hidden from the model");
        else ok(/^ui:\/\/capystore\/\w+\.html$/.test(t._meta?.ui?.resourceUri ?? "") && t._meta["ui/resourceUri"] === t._meta.ui.resourceUri, `${t.name} has _meta.ui.resourceUri`);
        ok(typeof t.annotations?.readOnlyHint === "boolean", `${t.name} has readOnlyHint`);
    }
    const { resources } = await client.listResources();
    eq(resources.map((r) => r.uri).sort(), WIDGETS.map((w) => w.uri).sort(), "resources/list names every widget");
    eq(resources.length, 8, "eight widgets");
    for (const w of WIDGETS) {
        const read = await client.readResource({ uri: w.uri });
        const c = read.contents[0];
        eq(c.mimeType, "text/html;profile=mcp-app", `${w.view} mime type`);
        ok(c.text.includes("<html") && c.text === w.html, `${w.view} html is the generated widget`);
        eq(c._meta?.ui?.csp, { resourceDomains: [origin], connectDomains: [origin] }, `${w.view} CSP names the public origin`);
    }
});

await step("CSP and ui.domain follow --public-url", async () => {
    const other = await startDev({ port: 0, publicUrl: "https://demo-tunnel.example.com" });
    const c2 = new Client({ name: "x", version: "1" });
    // the public URL is not reachable here: connect locally, the server still advertises the public origin
    await c2.connect(new StreamableHTTPClientTransport(new URL(`http://localhost:${other.port}/mcp`)));
    const read = await c2.readResource({ uri: "ui://capystore/search.html" });
    eq(read.contents[0]._meta.ui.csp, { resourceDomains: ["https://demo-tunnel.example.com"], connectDomains: ["https://demo-tunnel.example.com"] }, "CSP names the tunnel origin");
    const s = await c2.callTool({ name: "search_library", arguments: { query: "cat" } });
    ok(s.structuredContent.items[0].thumb_url.startsWith("https://demo-tunnel.example.com/media/"), "pictures use the public origin");
    ok(/^[0-9a-f]{32}\.claudemcpcontent\.com$/.test(other.claudeDomain), "claude ui.domain is printed");
    // a request that looks like Claude gets the domain worked out from the public URL
    const asClaude = await fetch(`http://localhost:${other.port}/mcp`, { method: "POST", headers: { "content-type": "application/json", "user-agent": "Claude-User/1.0" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "resources/read", params: { uri: "ui://capystore/post.html" } }) }).then((r) => r.json());
    eq(asClaude.result.contents[0]._meta.ui.domain, other.claudeDomain, "ui.domain for a Claude request is the printed one");
    await c2.close();
    await other.close();
});

let ids = {};
await step("read tools: every answer passes its schema", async () => {
    const sr = await call("search_library", { query: "a", limit: 24 });
    const s = sr.structuredContent;
    ok(s.items.length >= 11, `search lists the demo posts (${s.items.length})`);
    ok(s.items.some((i) => i.kind === "gallery") && s.items.some((i) => i.kind === "image") && s.items.some((i) => i.kind === "video"), "videos, images and a gallery");
    ok(s.items.some((i) => i.status === "private"), "a private post shows as private");
    ok(!s.items.some((i) => /hidden/i.test(i.title)), "the hidden post never shows");
    const priv = s.items.find((i) => i.status === "private");
    // a private post's thumbnail is a signed one-hour preview link on the API origin, filed in the result's _meta (by post id),
    // never in structuredContent or the text; it loads with no headers
    eq(priv.thumb_url, null, "a private post has no thumb_url in structuredContent");
    ok(!JSON.stringify(sr.structuredContent).includes("/mcp/media/") && !sr.content[0].text.includes("/mcp/media/"), "no signed link in structuredContent or the text");
    const thumb = sr._meta?.["capystore/preview"]?.[priv.id]?.thumb;
    ok(/\/mcp\/media\/[\w-]+\.[\w-]{43}(\/poster)?$/.test(thumb || ""), `a private post has a signed thumb in _meta (${thumb})`);
    const thumbRes = await fetch(thumb);
    ok(thumbRes.status === 200 && (await thumbRes.arrayBuffer()).byteLength > 50, "the signed thumb answers with the picture");
    // a forged signature of the right shape (a malformed token matches no route at all, so it would be a 404)
    ok((await fetch(thumb.replace(/\.[\w-]{43}(\/poster)?$/, `.${"A".repeat(43)}$1`))).status === 403, "a tampered signed link is a 403");
    if (thumb.endsWith("/poster")) ok((await fetch(thumb.slice(0, -"/poster".length))).status === 403, "a poster link never opens the original");
    ids = { video: s.items.find((i) => i.title.startsWith("Sunset")).id, short: s.items.find((i) => i.title.startsWith("Pancake")).id, image: s.items.find((i) => i.kind === "image" && i.status === "public").id, gallery: s.items.find((i) => i.kind === "gallery").id, priv: priv.id };
    await sc("search_library", { query: "cat", kind: "video" });
    await sc("search_library", { query: "zzz-nothing" });
    for (const k of ["video", "image", "gallery", "priv"]) {
        const p = await sc("show_post", { id: ids[k] });
        eq(p.post.id, ids[k], `show_post ${k}`);
    }
    const g = await sc("show_post", { id: ids.gallery });
    eq(g.post.file_list.length, 3, "the gallery has three files");
    const e = await sc("show_edit", {});
    eq(e.projects.length, 2, "two edit projects");
    const rendered = e.projects.find((p) => p.rendered);
    const one = await sc("show_edit", { id: rendered.id });
    ok(one.project.main.length >= 2 && one.project.render?.status === "done", "the rendered project has clips and a done render");
    const two = await sc("show_edit", { query: "stickers" });
    ok(two.project.overlay.length === 2, "the second project has overlays");
    const c = await sc("list_collections", {});
    eq(c.total, 2, "two collections");
    const l = await sc("list_share_links", {});
    eq(l.total, 3, "three share links");
    await sc("list_share_links", { collection: "Travel" });
    await sc("list_collections", { name: "fun" });
});

await step("create_share_link makes a link and a collection", async () => {
    const made = await sc("create_share_link", { ids: [ids.video, ids.image], title: "From the check", collection: "Check runs" });
    ok(!!made.created && made.links.some((l) => l.id === made.created), "the new link is the created one");
    const links = await sc("list_share_links", {});
    eq(links.total, 4, "four links now");
    const cols = await sc("list_collections", {});
    ok(cols.collections.some((c) => c.name === "Check runs"), "the collection was made");
});

await step("webp flow: pick -> running -> done through job_status", async () => {
    const pick = await sc("convert_to_webp", { id: ids.video });
    eq(pick.state, "pick", "a long video without a range asks");
    ok(pick.source.duration_s > 10 && !!pick.source.url, "the picker has the source url and length");
    const run = await sc("convert_to_webp", { id: ids.video, start: 3, end: 8, width: 320, quality: "high" });
    eq(run.state, "running", "a range starts a job (running)");
    ok(!!run.job, "with a job id");
    const states = [];
    let last = run;
    for (let i = 0; i < 20 && last.state === "running"; i++) {
        last = await sc("job_status", { job: run.job });
        states.push(last.state);
    }
    ok(states[0] === "running" || states.length > 0, "job_status answered");
    eq(last.state, "done", "the job ends done");
    ok(states.filter((s) => s === "running").length >= 1, `job_status showed running first (${states.join(",")})`);
    ok(!!last.post && last.post.kind === "image" && last.post.status === "public", "the job made a public image post");
    ok(!!last.share_url && last.share_url.startsWith(`${origin}/s/`), "with a share link on the dev server");
    const found = await sc("search_library", { query: "webp" });
    ok(found.items.some((i) => i.id === last.post.id), "the new post is in the library");
    const shown = await sc("show_post", { id: last.post.id });
    eq(shown.post.file_list[0].content_type, "image/webp", "show_post shows the webp");
    const short = await sc("convert_to_webp", { id: ids.short });
    eq(short.state, "running", "a short video converts whole");
    const bad = await client.callTool({ name: "job_status", arguments: { job: "studio:nope" } });
    ok(bad.isError === true, "an unknown job is an error");
});

await step("save flow completes (and a failing link errors)", async () => {
    const run = await sc("save_link", { url: "https://www.tiktok.com/@someone/video/123" });
    eq(run.state, "running", "a save runs");
    ok(/^save:[A-Za-z0-9]{22}$/.test(run.job ?? ""), "with a save job id");
    let last = run;
    const seen = [];
    for (let i = 0; i < 20 && last.state === "running"; i++) {
        last = await sc("job_status", { job: run.job });
        seen.push(last.state);
    }
    eq(last.state, "done", `the save ends done (${seen.join(",")})`);
    ok(!!last.post && last.post.title.startsWith("Saved from tiktok.com"), "the saved post is there");
    const shown = await sc("show_post", { id: last.post.id });
    eq(shown.post.source_link, "https://www.tiktok.com/@someone/video/123", "with its source link");
    const fail = await sc("save_link", { url: "https://example.com/fail-this" });
    let f = fail;
    for (let i = 0; i < 20 && f.state === "running"; i++) f = await sc("job_status", { job: fail.job });
    eq(f.state, "error", "a failing link ends in error");
    ok(!!f.error, "with an error code");
});

await step("upload: links, CORS preflight, PUT of a PNG, then the post", async () => {
    const up = await sc("upload_files", { files: [{ name: "check-dot.png", title: "Check dot" }], public: true });
    eq(up.uploads.length, 1, "one upload link");
    const url = up.uploads[0].upload_url;
    ok(url.startsWith(`${origin}/mcp/upload/`), "the link points at the dev server");
    const pre = await fetch(url, { method: "OPTIONS", headers: { origin: "https://abc.claudemcpcontent.com", "access-control-request-method": "PUT", "access-control-request-headers": "content-type" } });
    eq(pre.status, 204, "preflight is 204");
    eq(pre.headers.get("access-control-allow-origin"), "*", "preflight allows any origin");
    ok(/PUT/.test(pre.headers.get("access-control-allow-methods") ?? ""), "preflight allows PUT");
    const bytes = png(64, 64, [200, 60, 120]);
    const put = await fetch(url, { method: "PUT", headers: { "content-type": "image/png", origin: "https://abc.claudemcpcontent.com" }, body: bytes });
    const body = await put.json();
    ok(put.status === 201 || put.status === 200, `PUT answers ${put.status}: ${JSON.stringify(body).slice(0, 200)}`);
    eq(put.headers.get("access-control-allow-origin"), "*", "PUT carries CORS *");
    ok(!!body.item?.id, "the answer has the new item");
    const found = await sc("search_library", { query: "check dot" });
    const hit = found.items.find((i) => i.title === "Check dot");
    ok(!!hit, "the upload is found by search_library");
    const shown = await sc("show_post", { id: hit.id });
    eq(shown.post.kind, "image", "show_post shows it as an image");
    ok(hit.status === "public" && !!hit.thumb_url, `public upload has a picture (${hit.status})`);
    const pic = await fetch(hit.thumb_url);
    eq(pic.headers.get("content-type"), "image/png", "its picture is served from the dev server as the PNG it was");
    eq(Buffer.from(await pic.arrayBuffer()).equals(bytes), true, "byte for byte");
    // a bad link
    const forged = await fetch(`${origin}/mcp/upload/${"A".repeat(20)}.${"B".repeat(43)}`, { method: "PUT", headers: { "content-type": "image/png" }, body: bytes });
    eq(forged.status, 401, "a forged link is refused");
    eq(forged.headers.get("access-control-allow-origin"), "*", "and still carries CORS");
});

await step("media and share pages, errors", async () => {
    const poster = await fetch(`${origin}/media/PosterBaySunset002.jpg`);
    eq(poster.headers.get("content-type"), "image/svg+xml", "a poster is drawn");
    const vid = await fetch(`${origin}/media/BaySunset002.mp4`, { headers: { range: "bytes=0-99" } });
    ok(vid.status === 206 || vid.status === 404, "a video answers a range (206) or 404 without ffmpeg");
    const page = await fetch(`${origin}/s/BaySunset002`);
    ok((await page.text()).includes("Sunset timelapse"), "a share page names the post");
    const bad = await client.callTool({ name: "show_post", arguments: { id: "nope" } });
    ok(bad.isError === true, "an unknown post is an error");
    const post = (url, body) => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());
    const appOnly = await post(`${dev.mcpUrl}?tools=app`, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    eq(appOnly.result.tools.length, 10, "?tools=app lists the ten app tools only");
    const batch = await post(dev.mcpUrl, [{ jsonrpc: "2.0", id: "a", method: "ping" }, { jsonrpc: "2.0", id: "b", method: "ping" }]);
    eq(batch.map((r) => r.id), ["a", "b"], "a batch answers in order");
    const pre = await fetch(dev.mcpUrl, { method: "OPTIONS", headers: { origin: "http://127.0.0.1:1", "access-control-request-method": "POST" } });
    eq(pre.status, 204, "the harness page's preflight to /mcp is answered");
    const raw = await fetch(dev.mcpUrl, { method: "GET" });
    eq(raw.status, 405, "GET /mcp is 405");
});
await client.close();

// ================================================================ part 2: the widgets in Chromium, calling this server
const { chromium } = createRequire(import.meta.url)("playwright");
await buildHost();
const web = await serve(0);
const base = `http://127.0.0.1:${web.address().port}`;
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 900, height: 900 } });
const external = [];
await ctx.route("**/*", (route) => {
    const u = route.request().url();
    if (u.startsWith(base) || u.startsWith(origin) || /^(data|about|blob):/.test(u)) return route.continue();
    external.push(u);
    return route.abort();
});
const page = await ctx.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));
page.on("console", (m) => {
    if (m.type() === "error" && !/Failed to load resource|ERR_FAILED|net::/.test(m.text())) pageErrors.push(m.text());
});
await page.goto(`${base}/?mcp=${encodeURIComponent(dev.mcpUrl)}`);
await page.waitForSelector("body[data-ready]");
const F = () => page.frameLocator("iframe");
const frame = () => page.frames().find((f) => f !== page.mainFrame());
const shot = (name) => page.locator("iframe").screenshot({ path: join(shots, `dev-${name}.png`) });
const live = async (tool, args, { theme = "light", width = 640 } = {}) => {
    await page.evaluate(([t, w]) => { __host.setTheme(t); __host.setWidth(w); }, [theme, width]);
    await page.evaluate(([t, a]) => __host.loadLive(t, a), [tool, args]);
    await F().locator(".widget > *").first().waitFor({ timeout: 8000 });
    await page.waitForTimeout(250);
};
const hostCalls = () => page.evaluate(() => __host.log.calls);
// the pictures drawn now: the compact lists keep the rest behind "show more" (hidden, so a lazy image there never loads)
const loaded = async (sel) => frame().evaluate(async (s) => {
    const imgs = [...document.querySelectorAll(s)].filter((i) => !i.closest("[hidden]"));
    await Promise.all(imgs.map((i) => (i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; }))));
    return imgs.map((i) => i.naturalWidth);
}, sel);

await step("browser: search grid draws demo posts with pictures", async () => {
    await live("search_library", { query: "a", limit: 12 });
    const n = await F().locator(".th").count();
    ok(n >= 10, `grid has ${n} posts`);
    ok((await F().locator(".th .pic img").count()) >= 8, "every post tile has a picture");
    const widths = await loaded(".th .pic img");
    ok(widths.length >= 3 && widths.every((w) => w > 0), `drawn pictures loaded (naturalWidth > 0): ${widths.length} images, min ${Math.min(...widths)}`);
    await shot("search");
    await live("search_library", { query: "a", limit: 12 }, { theme: "dark", width: 320 });
    await shot("search-dark-320");
});

await step("browser: tapping a post shows the post view (video plays from the dev server)", async () => {
    await live("search_library", { query: "sunset" });
    // the webp flow above made a second "sunset" post (an image); the video is the one with a length badge
    await F().locator(".th:has(.badge)").first().click();
    await F().locator(".cpost video").waitFor({ timeout: 8000 });
    const c = await hostCalls();
    eq(c.at(-1)?.name, "show_post", "tap calls show_post through the server");
    ok((await F().locator(".whead").innerText()).includes("Sunset timelapse"), "post title");
    ok((await F().locator("video").count()) === 1, "a video element");
    const dur = await frame().evaluate(() => new Promise((r) => {
        const v = document.querySelector("video");
        if (v.readyState >= 1) return r(v.duration);
        v.addEventListener("loadedmetadata", () => r(v.duration));
        v.addEventListener("error", () => r(-1));
        setTimeout(() => r(-2), 5000);
    }));
    ok(dur > 10 || dur === -1, `video metadata loaded under the CSP (duration ${dur}; -1 means no ffmpeg sample)`);
    await shot("post");
    await live("show_post", { id: ids.gallery });
    ok((await loaded(".vp img")).every((w) => w > 0), "gallery picture loads");
    await live("show_post", { id: ids.priv });
    ok((await F().locator(".vp .lockb").count()) === 1, "the private post shows the lock badge");
    ok((await loaded(".vp img.still")).every((w) => w > 0), "the private picture loads through its signed link under the CSP");
});

await step("browser: edit timeline renders clips", async () => {
    await live("show_edit", { query: "montage" });
    const clips = await F().locator(".film, .cclip").count();
    ok(clips >= 3, `timeline has clips (${clips})`);
    ok((await F().locator(".whead .pill").innerText()).includes("rendered"), "render pill");
    await shot("edit");
    await live("show_edit", { query: "stickers" });
    ok((await F().locator(".labs div").count()) >= 4, "tracks drawn for the overlay edit");
    await shot("edit-overlays");
    await live("show_edit", {});
    ok((await F().locator("button, .th, .row, [role=button]").count()) > 0, "the project list draws");
});

await step("browser: collections and share links", async () => {
    await live("list_collections", {});
    ok((await F().locator(".widget").innerText()).includes("Funny clips"), "collection names");
    await shot("collections");
    await live("list_share_links", {});
    ok((await F().locator(".widget").innerText()).includes("Lisbon trip"), "link titles");
    ok((await loaded(".widget img")).every((w) => w > 0), "link thumbs load");
    await shot("links");
});

await step("browser: webp picker converts and reaches done", async () => {
    await live("convert_to_webp", { id: ids.video });
    ok((await F().locator(".hd").count()) === 2, "two handles");
    await F().getByRole("button", { name: "convert" }).click();
    await F().locator(".prog").waitFor({ timeout: 8000 });
    await shot("webp-running");
    await F().locator(".result").waitFor({ timeout: 15000 });
    const c = await hostCalls();
    ok(c.some((x) => x.name === "convert_to_webp" && typeof x.arguments.start === "number"), "convert_to_webp went to the server with the range");
    ok(c.filter((x) => x.name === "job_status").length >= 2, `job_status polled (${c.filter((x) => x.name === "job_status").length}x)`);
    ok((await F().locator(".result").innerText()).includes(`${new URL(origin).host}/s/`), "done shows the dev server's share link");
    await shot("webp-done");
});

await step("browser: save widget completes", async () => {
    await live("save_link", { url: "https://x.com/someone/status/42" });
    await F().locator(".widget").waitFor();
    await frame().waitForFunction(() => /Saved from x\.com/.test(document.body.innerText), null, { timeout: 15000 });
    await shot("save-done");
});

await step("browser: upload tray uploads a file and shows it saved", async () => {
    await live("upload_files", { files: [{ name: "tray-dot.png", title: "Tray dot" }], public: true });
    ok((await F().locator(".up").count()) === 1, "one slot");
    await F().locator("input[type=file]").setInputFiles([{ name: "tray-dot.png", mimeType: "image/png", buffer: png(48, 48, [30, 140, 200]) }]);
    await F().locator(".up.ok").first().waitFor({ timeout: 10000 });
    ok((await F().locator(".up .tag").count()) === 1, "in library tag");
    await shot("upload-done");
    await F().locator(".up .btn").first().click();
    await F().locator(".cpost").waitFor({ timeout: 8000 });
    ok((await F().locator(".whead").innerText()).toLowerCase().includes("tray"), "tapping the item opens its post");
    const found = await fetch(dev.mcpUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search_library", arguments: { query: "tray" } } }) }).then((r) => r.json());
    ok(found.result.structuredContent.items.length === 1, "the server has the uploaded post");
});

ok(external.length === 0, `no request left the dev servers: ${external.slice(0, 3).join(", ")}`);
eq(pageErrors, [], "no page errors");
await browser.close();
await new Promise((r) => web.close(r));
await dev.close();
fails.forEach((f) => console.log("  - " + f));
console.log(`\n${pass} passed, ${fails.length} failed`);
console.log(`screenshots: ${shots}/dev-*.png`);
process.exit(fails.length ? 1 : 0);
