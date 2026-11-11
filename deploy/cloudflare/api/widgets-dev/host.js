// The dev host: plays the host side of the MCP Apps protocol on ext-apps' real AppBridge, with fixtures for every view.
import { AppBridge, PostMessageTransport } from "@modelcontextprotocol/ext-apps/app-bridge";
import { WIDGETS } from "../src/mcp-app/widgets.generated.ts";
import * as F from "./fixtures.js";

const params = new URLSearchParams(location.search);
let UP = params.get("up") || "http://127.0.0.1:9";
// ?mcp=<url>: a dev MCP server (mcp-dev.mjs). Tool calls from a widget go to it, not to the fixtures, and __host.loadLive()
// opens a widget from a real tool result and the widget HTML the server serves (with the CSP it advertises).
const MCP = params.get("mcp");
const LIVE_VIEW = { search_library: "search", show_post: "post", show_edit: "edit", list_collections: "collections", list_share_links: "links", create_share_link: "links", convert_to_webp: "webp", upload_files: "upload", save_link: "save" };
let rpcId = 1;
async function mcpRpc(method, p) {
    const res = await fetch(MCP, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: rpcId++, method, params: p }) });
    const j = await res.json();
    if (j.error) throw new Error(j.error.message);
    return j.result;
}
let MAX = null;
let VARS = null;
const FIX = {
    "search.grid": { tool: "search_library", args: { query: "pink cat girl edits" }, out: () => F.searchOut("pink cat girl edits", 8) },
    "search.few": { tool: "search_library", args: { query: "jumpscare" }, out: () => ({ ...F.searchOut("jumpscare", 2), mode: "text" }) },
    "search.empty": { tool: "search_library", args: { query: "zzzz" }, out: () => ({ view: "search", query: "zzzz", mode: "meaning", total: 0, items: [] }) },
    "post.video": { tool: "show_post", args: { id: "post-vid-1" }, out: () => F.postDetail("post-vid-1") },
    "post.image": { tool: "show_post", args: { id: "post-img-1" }, out: () => F.postDetail("post-img-1") },
    "post.gallery": { tool: "show_post", args: { id: "post-gal-1" }, out: () => F.postDetail("post-gal-1") },
    "post.private": { tool: "show_post", args: { id: "post-priv-1" }, out: () => F.postDetail("post-priv-1") },
    "post.xss": { tool: "show_post", args: { id: "post-xss" }, out: () => F.postDetail("post-xss") },
    "edit.project": { tool: "show_edit", args: { query: "Shrek" }, out: () => F.editOut(F.EDIT) },
    "edit.list": { tool: "show_edit", args: {}, out: F.editList },
    "edit.long": { tool: "show_edit", args: { id: "edit-long" }, out: F.editLong },
    "edit.short": { tool: "show_edit", args: { id: "edit-short" }, out: F.editShort },
    "collections.grid": { tool: "list_collections", args: {}, out: F.collectionsOut },
    "collections.empty": { tool: "list_collections", args: {}, out: () => ({ view: "collections", total: 0, collections: [] }) },
    "links.list": { tool: "list_share_links", args: {}, out: () => F.linksOut() },
    "links.created": { tool: "create_share_link", args: { ids: ["post-img-1"] }, out: () => F.linksOut({ created: "lk2" }) },
    "links.empty": { tool: "list_share_links", args: {}, out: () => ({ view: "links", total: 0, links: [], created: null }) },
    "webp.pick": { tool: "convert_to_webp", args: { id: "post-vid-2" }, out: F.webpPick },
    "webp.running": { tool: "convert_to_webp", args: { id: "post-vid-2", start: 41, end: 45.5 }, out: F.webpRunning },
    "webp.done": { tool: "convert_to_webp", args: { id: "post-vid-2", start: 41, end: 45.5 }, out: F.webpDone },
    "webp.error": { tool: "convert_to_webp", args: { id: "post-vid-2", start: 41, end: 45.5 }, out: F.webpError },
    "upload.tray": { tool: "upload_files", args: { files: [{ name: "dance.mp4" }, { name: "lia-wave.gif" }, { name: "thumb.png" }] }, out: () => upOut() },
    "save.running": { tool: "save_link", args: { url: "https://x.com/someone/status/1987654321" }, out: () => F.saveOut("running") },
    "save.done": { tool: "save_link", args: { url: "https://x.com/someone/status/1987654321" }, out: F.saveDone },
    "save.error": { tool: "save_link", args: { url: "https://x.com/someone/status/1987654321" }, out: F.saveError },
    // never answers: the skeleton
    "skeleton.search": { tool: "search_library", args: { query: "pink" }, out: null, view: "search" },
    "skeleton.webp": { tool: "convert_to_webp", args: { id: "x" }, out: null, view: "webp" },
    // a failed first call
    "error.first": { tool: "show_post", args: { id: "gone" }, error: "no post with that id", view: "post" },
};

const upOut = (names) => ({ ...F.uploadOut(UP, names), ...(MAX ? { max_bytes: MAX } : {}) });
const jobs = {};
const log = { calls: [], links: [], messages: [], display: [], sizes: [], failNext: null, delay: 0 };
const text = (t) => [{ type: "text", text: t }];
const ok = (sc) => ({ content: text(sc.view + " ok"), structuredContent: sc });
const bad = (m) => ({ isError: true, content: text(m) });

function handleCall(p) {
    const a = p.arguments || {};
    log.calls.push({ name: p.name, arguments: JSON.parse(JSON.stringify(a)) });
    if (log.failNext && (log.failNext.tool === p.name || log.failNext.tool === "*")) {
        const f = log.failNext;
        if (--f.times <= 0) log.failNext = null;
        return bad(f.msg);
    }
    switch (p.name) {
        case "show_post": {
            const d = F.postDetail(a.id);
            return d ? ok(d) : bad("no post with that id");
        }
        case "search_library": return ok(F.searchOut(a.query, 6));
        case "list_share_links": return ok({ ...F.linksOut(), links: F.LINKS.slice(0, 2), total: 2 });
        case "show_edit": return ok(F.editOut(F.EDIT));
        case "convert_to_webp": return ok(F.webp("running", { job: "job-webp-2", progress: 0, range: { start: a.start, end: a.end }, width: a.width, quality: a.quality }));
        case "save_link": return ok(F.saveOut("running", { url: a.url, job: "job-save-2" }));
        case "upload_files": return ok(upOut((a.files || [{ name: "file" }]).map((f) => f.name)));
        case "job_status": {
            const n = (jobs[a.job] = (jobs[a.job] || 0) + 1);
            if (a.job === "job-fail") return { content: text("x"), structuredContent: { job: a.job, state: "error", progress: null, error: "ffmpeg ran out of memory", post: null, share_url: null } };
            if (a.job === "job-slow") return { content: text("x"), structuredContent: { job: a.job, state: "running", progress: 0.1, error: null, post: null, share_url: null } };
            if (n < 3) return { content: text("running"), structuredContent: { job: a.job, state: "running", progress: n === 1 ? 0.3 : 0.7, error: null, post: null, share_url: null } };
            const isSave = a.job.startsWith("job-save");
            return { content: text("done"), structuredContent: { job: a.job, state: "done", progress: 1, error: null, post: isSave ? F.POSTS[1] : F.webpDone().post, share_url: isSave ? null : `https://share.capybaraharmony.com/jmpscr-webp` } };
        }
        default: return bad("unknown tool " + p.name);
    }
}

async function liveCall(p) {
    log.calls.push({ name: p.name, arguments: JSON.parse(JSON.stringify(p.arguments || {})) });
    return mcpRpc("tools/call", { name: p.name, arguments: p.arguments || {} });
}
async function loadLive(tool, args, opts = {}) {
    const result = await mcpRpc("tools/call", { name: tool, arguments: args });
    const view = (result.structuredContent && result.structuredContent.view) || LIVE_VIEW[tool];
    const res = await mcpRpc("resources/read", { uri: `ui://capystore/${view}.html` });
    const c = res.contents[0];
    const csp = c._meta && c._meta.ui && c._meta.ui.csp ? c._meta.ui.csp : { resourceDomains: [], connectDomains: [] };
    const list = (a) => a.join(" ");
    const meta = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: ${list(csp.resourceDomains)}; media-src ${list(csp.resourceDomains)}; connect-src ${list(csp.connectDomains)}">`;
    log.calls.length = 0;
    return mount("live:" + tool, { args, view, result }, { ...opts, widget: { view, html: c.text }, csp: meta });
}

const stage = document.getElementById("stage");
const frameBox = document.getElementById("frame");
const state = { theme: "light", width: 640, clip: params.get("clip") === "1", bridge: null, iframe: null, key: null };

async function load(key, opts = {}) {
    const fx = FIX[key];
    if (!fx) throw new Error("no fixture " + key);
    return mount(key, fx, opts);
}
async function mount(key, fx, opts = {}) {
    const view = fx.view || fx.out().view;
    const w = opts.widget || WIDGETS.find((x) => x.view === view);
    if (state.bridge) { try { state.bridge.close(); } catch {} }
    frameBox.replaceChildren();
    state.key = key;
    log.sizes.length = 0;
    const iframe = document.createElement("iframe");
    iframe.title = "widget";
    iframe.setAttribute("sandbox", "allow-scripts");
    if (state.clip) iframe.setAttribute("allow", "clipboard-write");
    iframe.style.cssText = `width:100%;border:0;display:block;height:${opts.height || 120}px;color-scheme:normal`;
    const upOrigin = new URL(UP).origin;
    const csp = opts.csp || `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: https://media.capybaraharmony.com https://share.capybaraharmony.com; media-src https://media.capybaraharmony.com; connect-src ${upOrigin} https://api.capybaraharmony.com">`;
    iframe.srcdoc = w.html.replace("<head>", "<head>" + csp);
    const bridge = new AppBridge(null, { name: "dev-host", version: "1.0.0" }, { openLinks: {}, serverTools: {}, message: { text: {} }, updateModelContext: { text: {} }, logging: {} }, {
        hostContext: hostContext(),
    });
    bridge.oncalltool = async (p) => {
        if (log.delay) await new Promise((r) => setTimeout(r, log.delay));
        return MCP ? liveCall(p) : handleCall(p);
    };
    bridge.onopenlink = async (p) => { log.links.push(p.url); return {}; };
    bridge.onmessage = async (p) => { log.messages.push(p); return {}; };
    bridge.onupdatemodelcontext = async () => ({});
    bridge.onrequestdisplaymode = async (p) => { log.display.push(p.mode); bridge.setHostContext({ ...hostContext(), displayMode: p.mode }); return { mode: p.mode }; };
    bridge.onsizechange = (p) => { log.sizes.push(p); if (p.height) iframe.style.height = p.height + "px"; };
    bridge.onloggingmessage = () => {};
    state.bridge = bridge;
    state.iframe = iframe;
    const ready = new Promise((resolve) => {
        bridge.oninitialized = async () => {
            await bridge.sendToolInput({ arguments: fx.args });
            if (fx.error) await bridge.sendToolResult(bad(fx.error));
            else if (fx.result) await bridge.sendToolResult(fx.result);
            else if (fx.out) await bridge.sendToolResult(ok(fx.out()));
            resolve();
        };
    });
    frameBox.appendChild(iframe);
    await bridge.connect(new PostMessageTransport(iframe.contentWindow, iframe.contentWindow));
    await ready;
}
function hostContext() {
    return { theme: state.theme, ...(VARS ? { styles: { variables: VARS } } : {}), displayMode: "inline", availableDisplayModes: ["inline", "fullscreen"], locale: "en-US", timeZone: "UTC", platform: "web", containerDimensions: { maxWidth: state.width } };
}
function applyChrome() {
    document.documentElement.setAttribute("data-theme", state.theme);
    frameBox.style.width = state.width ? state.width + "px" : "100%";
    if (state.bridge) state.bridge.setHostContext(hostContext());
}

window.__host = {
    ...log, log, keys: Object.keys(FIX), load, loadLive, mcp: MCP,
    setTheme(t) { state.theme = t; applyChrome(); },
    setWidth(w) { state.width = w; applyChrome(); },
    failNext(tool, msg = "capystore said no", times = 1) { log.failNext = { tool, msg, times }; },
    setDelay(ms) { log.delay = ms; },
    reset() { log.calls.length = 0; log.links.length = 0; log.messages.length = 0; log.display.length = 0; for (const k in jobs) delete jobs[k]; log.failNext = null; log.delay = 0; },
    setMax(n) { MAX = n; },
    setUploadBase(u) { UP = u; },
    setVars(v) { VARS = v; applyChrome(); },
    html: (view) => WIDGETS.find((w) => w.view === view).html,
    teardown: () => state.bridge && state.bridge.teardownResource({}),
};

const nav = document.getElementById("nav");
for (const k of Object.keys(FIX)) {
    const b = document.createElement("button");
    b.textContent = k;
    b.onclick = () => { location.hash = k; load(k); };
    nav.appendChild(b);
}
document.getElementById("theme").onchange = (e) => { state.theme = e.target.value; applyChrome(); };
document.getElementById("width").onchange = (e) => { state.width = Number(e.target.value); applyChrome(); };
applyChrome();
document.body.dataset.ready = "1";
if (location.hash.length > 1) load(decodeURIComponent(location.hash.slice(1)));
