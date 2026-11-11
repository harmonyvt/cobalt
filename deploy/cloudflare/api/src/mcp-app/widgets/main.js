const root = document.getElementById("root");

// a tool call, normalised: { error } or { sc (structuredContent), text }
async function rpc(name, args) {
    let r;
    try {
        r = await bridge.call(name, args);
    } catch (e) {
        return { error: (e && e.message) || "couldn't reach capystore" };
    }
    const text = ((r && r.content) || []).filter((c) => c && c.type === "text").map((c) => c.text).join("\n");
    if (!r || r.isError) return { error: text || "that didn't work" };
    return { sc: r.structuredContent || null, text };
}

function show(data, opts) {
    if ((!opts || opts.push !== false) && S.data) S.stack.push(S.data);
    S.data = data;
    S.err = null;
    render();
    window.scrollTo(0, 0);
}
function back() {
    if (!S.stack.length) return;
    S.data = S.stack.pop();
    S.err = null;
    render();
}
// call a tool and draw its answer; a failure stays inline with a retry
async function go(name, args, opts) {
    if (S.busy) return null;
    S.busy = true;
    root.firstChild && root.firstChild.classList.add("busy");
    const r = await rpc(name, args);
    S.busy = false;
    if (r.error || !r.sc || !VIEWS[r.sc.view]) {
        // the view stays as it is (a half-made upload list or a picked range survives); the banner goes on top
        S.err = { msg: r.error || "capystore sent back something this view can't draw", retry: () => go(name, args, opts) };
        const wd = root.firstChild;
        if (wd) {
            wd.classList.remove("busy");
            mountErr(wd);
        } else render();
        return null;
    }
    show(r.sc, opts);
    return r.sc;
}

function skeleton(view) {
    const sk = (css) => {
        const e = h("div", { class: "sk", "aria-hidden": "true" });
        e.style.cssText = css;
        return e;
    };
    const w = h("div", { "aria-busy": "true", "aria-label": "loading" }, h("div", { class: "whead" }, sk("height:16px;width:40%")));
    let body;
    if (view === "search" || view === "collections") {
        body = h("div", { class: "skg" });
        for (let i = 0; i < 8; i++) body.appendChild(sk("aspect-ratio:1;border-radius:10px"));
    } else if (view === "links" || view === "upload") {
        body = h("div");
        for (let i = 0; i < 3; i++) body.appendChild(sk("height:44px;margin:8px 0"));
    } else {
        body = h("div");
        body.appendChild(sk("height:150px;margin-bottom:10px"));
        body.appendChild(sk("height:14px;width:70%"));
    }
    w.appendChild(h("div", { class: "wbody" }, body));
    return w;
}

function errBanner(e) {
    const gone = () => {
        S.err = null;
        const old = root.querySelector(".err.top");
        if (old) old.remove();
    };
    return h("div", { class: "err top", role: "alert" }, h("span", { text: e.msg }),
        h("span", { class: "row", style: "flex:none" },
            e.retry ? h("button", { class: "btn", type: "button", text: "try again", onclick: () => {
                gone();
                e.retry();
            } }) : null,
            h("button", { class: "btn", type: "button", text: "dismiss", onclick: gone })));
}
function mountErr(wd) {
    const old = wd.querySelector(".err.top");
    if (old) old.remove();
    if (S.err) wd.insertBefore(errBanner(S.err), wd.firstChild);
}

function render() {
    S.cleanups.splice(0).forEach((f) => {
        try {
            f();
        } catch {}
    });
    const wrap = h("div", { class: "widget" });
    mountErr(wrap);
    if (S.data) {
        let node;
        try {
            node = VIEWS[S.data.view](S.data);
        } catch (x) {
            node = h("div", { class: "empty", text: "this view couldn't be drawn." });
            console.error(x);
        }
        wrap.appendChild(node);
    } else if (!S.err) wrap.appendChild(skeleton(S.defView));
    root.replaceChildren(wrap);
}

// the first result: a tool answer pushed by the host
bridge.on("result", (p) => {
    const sc = p && p.structuredContent;
    S.stack = [];
    if (p && p.isError) {
        S.data = null;
        S.err = { msg: ((p.content || []).map((c) => c.text).filter(Boolean).join(" ")) || "that didn't work" };
    } else if (sc && VIEWS[sc.view]) {
        S.data = sc;
        S.err = null;
    } else {
        S.data = null;
        const text = ((p && p.content) || []).map((c) => c.text).filter(Boolean).join("\n");
        S.err = { msg: text || "nothing to show yet" };
    }
    render();
});
bridge.on("cancelled", () => {
    if (!S.data) {
        S.err = { msg: "cancelled" };
        render();
    }
});
bridge.on("teardown", () => S.cleanups.splice(0).forEach((f) => f()));
bridge.on("context", () => {
    // a theme change needs no redraw (CSS variables); a locale change would only touch dates
});
render();
bridge.init();
