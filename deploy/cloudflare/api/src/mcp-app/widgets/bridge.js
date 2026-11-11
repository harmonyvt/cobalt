// The MCP Apps bridge, by hand: JSON-RPC 2.0 over window.parent.postMessage (ext-apps spec 2026-01-26).
// View -> host: ui/initialize, ui/notifications/initialized, tools/call, ui/open-link, ui/message,
// ui/request-display-mode, ui/notifications/size-changed. Host -> view: ui/notifications/tool-input, tool-result,
// tool-cancelled, host-context-changed, and the requests ui/resource-teardown and ping.
const bridge = (() => {
    const PROTO = "2026-01-26";
    let id = 1;
    let caps = {};
    let ctx = {};
    let connected = false;
    const pending = new Map();
    const subs = { result: [], input: [], cancelled: [], context: [], teardown: [] };
    const emit = (k, v) => subs[k].forEach((f) => f(v));
    const send = (m) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, m), "*");
    const standalone = window.parent === window;

    function request(method, params, ms) {
        return new Promise((resolve, reject) => {
            const i = id++;
            const t = setTimeout(() => {
                pending.delete(i);
                reject(new Error("no answer from the host"));
            }, ms || 60000);
            pending.set(i, { resolve, reject, t });
            send({ id: i, method, params });
        });
    }
    const notify = (method, params) => send(params === undefined ? { method } : { method, params });

    function setContext(c) {
        ctx = c || {};
        const root = document.documentElement;
        if (ctx.theme === "light" || ctx.theme === "dark") {
            root.setAttribute("data-theme", ctx.theme);
            root.style.colorScheme = ctx.theme;
        }
        const vars = ctx.styles && ctx.styles.variables;
        if (vars) for (const k in vars) if (vars[k] != null && /^--[\w-]+$/.test(k)) root.style.setProperty(k, vars[k]);
        if (ctx.displayMode) root.setAttribute("data-display", ctx.displayMode);
        emit("context", ctx);
    }

    window.addEventListener("message", (e) => {
        if (e.source !== window.parent) return;
        const m = e.data;
        if (!m || m.jsonrpc !== "2.0") return;
        if (m.method) {
            if (m.id !== undefined) {
                if (m.method === "ping") send({ id: m.id, result: {} });
                else if (m.method === "ui/resource-teardown") {
                    emit("teardown");
                    send({ id: m.id, result: {} });
                } else send({ id: m.id, error: { code: -32601, message: "method not found" } });
            } else if (m.method === "ui/notifications/tool-result") emit("result", m.params || {});
            else if (m.method === "ui/notifications/tool-input") emit("input", (m.params && m.params.arguments) || {});
            else if (m.method === "ui/notifications/tool-cancelled") emit("cancelled", (m.params && m.params.reason) || "");
            else if (m.method === "ui/notifications/host-context-changed") setContext(Object.assign({}, ctx, m.params));
        } else if (m.id !== undefined) {
            const p = pending.get(m.id);
            if (!p) return;
            pending.delete(m.id);
            clearTimeout(p.t);
            if (m.error) p.reject(Object.assign(new Error(m.error.message || "request failed"), { code: m.error.code }));
            else p.resolve(m.result);
        }
    });

    // tell the host the content height (same method as the reference client: measure with height max-content)
    function watchSize() {
        let queued = false;
        let lw = 0;
        let lh = 0;
        const f = () => {
            if (queued) return;
            queued = true;
            requestAnimationFrame(() => {
                queued = false;
                const d = document.documentElement;
                const old = d.style.height;
                d.style.height = "max-content";
                const hh = Math.ceil(d.getBoundingClientRect().height);
                d.style.height = old;
                const w = Math.ceil(window.innerWidth);
                if (w !== lw || hh !== lh) {
                    lw = w;
                    lh = hh;
                    notify("ui/notifications/size-changed", { width: w, height: hh });
                }
            });
        };
        f();
        const ro = new ResizeObserver(f);
        ro.observe(document.documentElement);
        ro.observe(document.body);
    }

    async function init() {
        // hosts that inject the result (window.openai) hand it over at load
        if (typeof window.openai !== "undefined" && window.openai && window.openai.toolOutput) emit("result", { structuredContent: window.openai.toolOutput, _meta: window.openai.toolResponseMetadata });
        window.addEventListener("openai:set_globals", (e) => {
            const o = e.detail && e.detail.globals && e.detail.globals.toolOutput;
            if (o) emit("result", { structuredContent: o, _meta: e.detail.globals.toolResponseMetadata || (window.openai && window.openai.toolResponseMetadata) });
        });
        if (standalone) return;
        try {
            const r = await request("ui/initialize", { appInfo: { name: "capystore", version: "1.0.0" }, appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }, protocolVersion: PROTO }, 15000);
            caps = (r && r.hostCapabilities) || {};
            connected = true;
            setContext((r && r.hostContext) || {});
            notify("ui/notifications/initialized");
        } catch {
            // no handshake: still listen, still draw what arrives
        }
        watchSize();
    }

    const hasFull = () => (ctx.availableDisplayModes || []).includes("fullscreen") || (typeof window.openai !== "undefined" && !!window.openai && typeof window.openai.requestDisplayMode === "function");
    return {
        init,
        on: (k, f) => subs[k].push(f),
        ctx: () => ctx,
        caps: () => caps,
        connected: () => connected,
        call: (name, args) => request("tools/call", { name, arguments: args || {} }, 180000),
        async openLink(url) {
            try {
                if (!caps.openLinks) throw new Error("no open-link");
                const r = await request("ui/open-link", { url }, 10000);
                if (r && r.isError) throw new Error("refused");
            } catch {
                window.open(url, "_blank", "noopener");
            }
        },
        message: (text) => request("ui/message", { role: "user", content: [{ type: "text", text }] }, 10000),
        canMessage: () => !!caps.message,
        canFull: hasFull,
        async fullscreen() {
            const mode = ctx.displayMode === "fullscreen" ? "inline" : "fullscreen";
            if ((ctx.availableDisplayModes || []).includes("fullscreen")) {
                try {
                    await request("ui/request-display-mode", { mode }, 10000);
                    return;
                } catch {}
            }
            // the standard request is the way; ChatGPT's own call is the fallback where it exists
            if (typeof window.openai !== "undefined" && window.openai && typeof window.openai.requestDisplayMode === "function") window.openai.requestDisplayMode({ mode });
        },
    };
})();
