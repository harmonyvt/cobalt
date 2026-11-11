const MAIN_COLORS = ["#2f7d4a", "#b83a78", "#2f6fb0", "#a8641c", "#6b4fb3", "#1f7f86"];

function renderPill(r) {
    if (!r) return h("span", { class: "pill mute", text: "not rendered" });
    if (r.status === "done") return r.stale ? h("span", { class: "pill warn", text: "render out of date" }) : h("span", { class: "pill", text: "rendered" });
    if (r.status === "error") return h("span", { class: "pill bad", text: "render failed" });
    return h("span", { class: "pill warn", text: "rendering" + (num(r.progress) ? " " + Math.round(r.progress * 100) + "%" : "") });
}

// tick spacing: the smallest "nice" step that keeps labels about 56 px apart or more
function tickStep(total, px) {
    const max = Math.max(2, Math.floor(px / 56));
    for (const s of [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]) if (total / s <= max) return s;
    return 7200;
}

function editList(d) {
    const ps = d.projects || [];
    const w = h("div", null, head(ps.length ? plural(ps.length, "edit") : "no edits", null));
    if (!ps.length) {
        w.appendChild(h("div", { class: "empty", text: "no edit projects yet." }));
        return w;
    }
    const body = h("div", { class: "wbody", style: "padding:4px 14px" });
    ps.forEach((p) => {
        body.appendChild(h("div", { class: "lk" },
            h("div", { class: "stack", "aria-hidden": "true" }, pic(p.poster_url, p.id)),
            h("div", { class: "t" }, h("b", { text: p.title }), h("span", { class: "mute", style: "font-size:12px", text: `rev ${p.revision} · ${dur(p.duration_s)} · ${p.rendered ? "rendered" : "not rendered"}` })),
            h("button", { class: "btn", type: "button", "aria-label": `open ${p.title}`, text: "open", onclick: () => go("show_edit", { id: p.id }) })));
    });
    w.appendChild(body);
    return w;
}

VIEWS.edit = (d) => {
    if (!d.project) return editList(d);
    const p = d.project;
    const total = Math.max(num(p.duration_s) ? p.duration_s : 0, 0.1);
    const main = p.main || [];
    const ovs = p.overlay || [];
    let t = 0;
    const cv = p.canvas || {};
    const right = [h("span", { text: `rev ${p.revision} · ${dur(total)}${num(cv.w) && num(cv.h) ? ` · ${cv.w}×${cv.h}` : ""}` }), renderPill(p.render)];
    const w = h("div", null, head(p.title, right));

    // preview
    const fallbackPoster = (p.render && p.render.poster_url) || (main.find((c) => c.poster_url) || {}).poster_url || null;
    const prev = pic(fallbackPoster, p.id, "tlprev");
    const tc = h("span", { class: "tc" });
    prev.appendChild(tc);
    let shown = fallbackPoster;
    const acts = h("div", { class: "row", style: "margin-top:10px" });
    if (p.render && p.render.post_id && p.render.status === "done") acts.appendChild(h("button", { class: "btn pri", type: "button", text: "view render", onclick: () => go("show_post", { id: p.render.post_id }) }));
    acts.appendChild(h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) }));

    // tracks
    const tracks = h("div", { class: "tracks" });
    const ruler = h("div", { class: "ruler", "aria-hidden": "true" });
    tracks.appendChild(ruler);
    const pct = (x) => (clamp(x / total, 0, 1) * 100).toFixed(3) + "%";
    const clipEl = (c, bg, label, cls) => {
        const e = h("div", { class: "clip" + (cls ? " " + cls : ""), title: label, text: label });
        e.style.left = pct(c.start);
        e.style.width = (clamp((c.end - c.start) / total, 0, 1) * 100).toFixed(3) + "%";
        e.style.background = bg;
        return e;
    };
    const lane = (name, thin) => {
        const l = h("div", { class: "lane" + (thin ? " thin" : "") });
        tracks.appendChild(h("div", { class: "trk" }, h("label", { text: name }), l));
        return l;
    };
    const live = []; // [el, start, end]
    const track = (l, c, bg, label, cls) => {
        const e = clipEl(c, bg, label, cls);
        l.appendChild(e);
        live.push([e, c.start, c.end]);
    };
    // overlays: stacked into as few rows as they need
    const rows = [];
    ovs.slice().sort((a, b) => a.start - b.start).forEach((o) => {
        let r = rows.find((x) => x.end <= o.start);
        if (!r) rows.push((r = { end: 0, items: [] }));
        r.end = o.end;
        r.items.push(o);
    });
    if (!rows.length) rows.push({ items: [] });
    rows.forEach((r, i) => {
        const l = lane(i ? "" : "overlay", true);
        if (!r.items.length) l.appendChild(h("span", { class: "note", style: "padding:0 8px;font-size:11px", text: "none" }));
        r.items.forEach((o) => track(l, o, "#7b5cc6", `${o.name} · ${o.kind}`));
    });
    const lm = lane("main", false);
    main.forEach((c, i) => {
        const span = num(c.in) && num(c.out) ? ` · ${dur(c.in)}–${dur(c.out)}` : "";
        const sp = num(c.speed) && c.speed !== 1 ? ` ×${c.speed}` : "";
        track(lm, c, MAIN_COLORS[i % MAIN_COLORS.length], c.name + span + sp);
    });
    const ls = lane("sound", true);
    main.forEach((c) => track(ls, c, "#3f73b8", c.muted ? "muted" : c.name, c.muted ? "dim" : ""));

    const ph = h("div", { class: "ph", role: "slider", tabindex: "0", "aria-label": "playhead", "aria-valuemin": "0", "aria-valuemax": String(Math.round(total * 10) / 10) });
    tracks.appendChild(ph);
    const info = h("p", { class: "note", style: "margin:8px 0 0" });

    function update() {
        ph.style.left = `calc(64px + (100% - 74px) * ${(clamp(t / total, 0, 1)).toFixed(5)})`;
        ph.setAttribute("aria-valuenow", String(Math.round(t * 10) / 10));
        ph.setAttribute("aria-valuetext", dur(t, 1));
        tc.textContent = `${dur(t, 1)} / ${dur(total, 1)}`;
        live.forEach(([e, s, en]) => e.classList.toggle("on", t >= s && t < en));
        const m = main.find((c) => t >= c.start && t < c.end);
        const o = ovs.find((c) => t >= c.start && t < c.end);
        info.textContent = [m ? `main: ${m.name}` : "", o ? `overlay: ${o.name}` : ""].filter(Boolean).join(" · ") || "nothing under the playhead";
        const want = (m && m.poster_url) || fallbackPoster;
        if (want !== shown) {
            shown = want;
            const im = prev.querySelector("img");
            if (im) im.remove();
            if (safeUrl(want)) prev.insertBefore(h("img", { src: want, alt: "" }), tc);
        }
    }
    const setT = (x) => {
        t = clamp(x, 0, total);
        update();
    };
    drag(tracks, (e) => {
        const r = tracks.getBoundingClientRect();
        const x0 = r.left + 64;
        setT(((e.clientX - x0) / Math.max(1, r.width - 74)) * total);
        ph.focus({ preventScroll: true });
    });
    ph.addEventListener("keydown", (e) => {
        const step = e.shiftKey ? 5 : total > 120 ? 2 : 0.5;
        const k = { ArrowLeft: -step, ArrowDown: -step, ArrowRight: step, ArrowUp: step, PageDown: -10, PageUp: 10 }[e.key];
        if (k !== undefined) setT(t + k);
        else if (e.key === "Home") setT(0);
        else if (e.key === "End") setT(total);
        else return;
        e.preventDefault();
    });

    function buildRuler() {
        const px = tracks.clientWidth - 74;
        if (px <= 0) return;
        const step = tickStep(total, px);
        ruler.replaceChildren();
        for (let s = 0; s <= total + 1e-6; s += step) {
            const sp = h("span", { text: dur(s, step < 1) });
            const f = s / total;
            sp.style.left = (f * 100).toFixed(3) + "%";
            if (f > 0.93) sp.className = "last";
            ruler.appendChild(sp);
        }
    }
    const ro = new ResizeObserver(buildRuler);
    ro.observe(tracks);
    onCleanup(() => ro.disconnect());

    update();
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "tl" }, h("div", null, prev, acts), h("div", null, tracks, info))));
    return w;
};
