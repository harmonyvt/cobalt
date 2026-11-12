const MAIN_COLORS = ["#2f7d4a", "#b83a78", "#2f6fb0", "#a8641c", "#6b4fb3", "#1f7f86"];
const OV_COLORS = ["#9b84e6", "#e2589a", "#e3ab4a", "#4aa3a0", "#d9774a", "#6c9be8"];

function renderPill(r) {
    const dot = (cls) => h("i", { class: "dot " + cls });
    if (!r) return h("span", { class: "pill mute" }, dot("off"), "not rendered");
    if (r.status === "done") return r.stale ? h("span", { class: "pill warn" }, "render out of date") : h("span", { class: "pill" }, dot(""), "rendered");
    if (r.status === "error") return h("span", { class: "pill bad", text: "render failed" });
    return h("span", { class: "pill warn", text: "rendering" + (num(r.progress) ? " " + Math.round(r.progress * 100) + "%" : "") });
}

// tick spacing: the smallest "nice" step that keeps labels about 56 px apart or more
function tickStep(total, px) {
    const max = Math.max(2, Math.floor(px / 56));
    for (const s of [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]) if (total / s <= max) return s;
    return 7200;
}

// a private source has no URL in structuredContent: its signed link comes from _meta, by file id (a picture with no poster is its own)
function withSigned(o, kind) {
    if (!o || !o.private || !o.file_id) return o;
    const url = signed(o.file_id, "url");
    const poster = signed(o.file_id, "poster") || (o.media_kind === "image" ? url : null);
    return Object.assign({}, o, kind === "render" ? { video_url: url, poster_url: poster } : kind === "overlay" ? { url, poster_url: poster } : { video_url: url, poster_url: poster });
}

function editList(d) {
    const ps = d.projects || [];
    const w = h("div", null, head(ps.length ? plural(ps.length, "edit") : "no edits", null));
    if (!ps.length) {
        w.appendChild(h("div", { class: "empty", text: "no edit projects yet." }));
        return w;
    }
    const box = h("div");
    ps.forEach((p) => {
        box.appendChild(h("div", { class: "lk" },
            h("div", { class: "stack", "aria-hidden": "true" }, pic(p.poster_url || signed(p.id, "poster"), p.id)),
            h("div", { class: "t" }, h("b", { text: p.title }), h("span", { text: `rev ${p.revision} · ${dur(p.duration_s)}` })),
            h("div", { class: "m" }, h("i", { class: "dot" + (p.rendered ? "" : " off"), role: "img", "aria-label": p.rendered ? "rendered" : "not rendered", title: p.rendered ? "rendered" : "not rendered" })),
            h("button", { class: "btn", type: "button", "aria-label": `open ${p.title}`, text: "open", onclick: () => go("show_edit", { id: p.id }) })));
    });
    const ml = limitList(box, 3);
    w.appendChild(h("div", { class: "wbody", style: "padding-top:2px;padding-bottom:var(--p)" }, box, ml.btn));
    return w;
}

VIEWS.edit = (d) => {
    if (!d.project) return editList(d);
    const p = d.project;
    const total = Math.max(num(p.duration_s) ? p.duration_s : 0, 0.1);
    const main = (p.main || []).map((c) => withSigned(c, "clip"));
    const ovs = (p.overlay || []).map((o) => withSigned(o, "overlay"));
    const cv = p.canvas || {};
    const fps = num(cv.fps) && cv.fps > 0 ? cv.fps : 30;
    const r = withSigned(p.render, "render");
    const renderUrl = r && r.status === "done" && webUrl(r.video_url) ? r.video_url : null;
    let t = 0;
    let playing = false;
    let mode = "timeline"; // or "render"
    const right = [h("span", { class: "opt", text: `rev ${p.revision} · ${dur(total)}${num(cv.w) && num(cv.h) ? ` · ${cv.w}×${cv.h}` : ""}` }), renderPill(r)];
    const w = h("div", null, head(p.title, right));

    // ---- preview: plays the source under the playhead, overlays boxed at their frames
    const fallbackPoster = (r && r.poster_url) || (main.find((c) => c.poster_url) || {}).poster_url || null;
    const prev = h("div", { class: "vp cprev" });
    if (num(cv.w) && num(cv.h)) {
        prev.style.setProperty("--ar", `${cv.w}/${cv.h}`);
        if (cv.h > cv.w) prev.classList.add("tall");
    }
    prev.style.background = grad(p.id);
    const still = h("img", { class: "still", alt: "", hidden: true });
    const vid = h("video", { playsinline: true, preload: "metadata", "aria-label": "timeline preview", hidden: true });
    prev.append(still, vid);
    const boxes = ovs.map((o, i) => {
        const f = o.frame;
        if (!f) return null;
        const c = OV_COLORS[i % OV_COLORS.length];
        const bh = num(f.h) ? f.h : num(cv.w) && num(cv.h) ? (f.w * cv.w) / cv.h : f.w;
        const b = h("div", { class: "ovb" + (f.y < 0.08 ? " below" : ""), "aria-hidden": "true" }, safeUrl(o.poster_url) ? h("img", { src: o.poster_url, alt: "" }) : null, h("span", { text: o.name }));
        b.style.cssText = `left:${(f.x * 100).toFixed(2)}%;top:${(f.y * 100).toFixed(2)}%;width:${(f.w * 100).toFixed(2)}%;height:${(bh * 100).toFixed(2)}%;border-color:${c};background:${c}22`;
        b.querySelector("span").style.background = c;
        prev.appendChild(b);
        return b;
    });
    const anyPrivate = main.some((c) => c.private) || ovs.some((o) => o.private) || !!(r && r.private && renderUrl);
    const lock = anyPrivate ? lockb("private · link valid 1 h", true) : null;
    if (lock) prev.appendChild(lock);
    const big = h("button", { class: "big", type: "button", "aria-label": "play timeline preview", onclick: () => toggle() }, ic("play", 18));
    const pbtn = h("button", { class: "ib", type: "button", "aria-label": "play", onclick: () => toggle() }, ic("play", 14));
    const tcSmall = h("span", { class: "tc" });
    prev.append(big, h("div", { class: "bar" }, pbtn, tcSmall));
    const msg = h("div", { class: "none", hidden: true });
    prev.appendChild(msg);

    // ---- the engine: one clock (the video's when it plays, else the wall clock), the source switched at clip boundaries
    const clips = main.map((c) => ({ ...c, speed: num(c.speed) && c.speed > 0 ? c.speed : 1, in: num(c.in) ? c.in : 0 }));
    const clipAt = (x) => clips.find((c) => x >= c.start && x < c.end) || (x >= total ? clips[clips.length - 1] : null) || null;
    let loaded = null; // the src the <video> holds
    let loadedAt = 0;
    const renderClip = { start: 0, end: total, in: 0, speed: 1, video_url: renderUrl, media_kind: "video", poster_url: r && r.poster_url, muted: false };
    function wantTime(c) {
        return mode === "render" ? t : c.in + (t - c.start) * c.speed;
    }
    function sync(force) {
        const c = mode === "render" ? renderClip : clipAt(t);
        const url = c && c.media_kind !== "image" && webUrl(c.video_url) ? c.video_url : null;
        if (!url) {
            vid.hidden = true;
            if (!vid.paused) vid.pause();
            const im = (c && (c.media_kind === "image" ? c.video_url : c.poster_url)) || fallbackPoster;
            still.hidden = !safeUrl(im);
            if (safeUrl(im) && still.getAttribute("src") !== im) still.setAttribute("src", im);
            return;
        }
        still.hidden = true;
        vid.hidden = false;
        vid.muted = !!c.muted;
        const rate = clamp(c.speed || 1, 0.0625, 16);
        if (vid.playbackRate !== rate) vid.playbackRate = rate;
        const want = wantTime(c);
        if (loaded !== url) {
            loaded = url;
            loadedAt = Date.now();
            msg.hidden = true;
            if (safeUrl(c.poster_url)) vid.poster = c.poster_url;
            vid.src = url;
        } else if (force || !playing || Math.abs(vid.currentTime - want) > 0.45) {
            try {
                vid.currentTime = want;
            } catch {}
            if (playing && vid.paused) vid.play().catch(() => {});
        }
    }
    // a source finished loading: seek to where the playhead is NOW (it may have moved, or crossed a clip, while this loaded)
    vid.addEventListener("loadedmetadata", () => {
        const c = mode === "render" ? renderClip : clipAt(t);
        if (!c) return;
        try {
            vid.currentTime = wantTime(c);
        } catch {}
        if (playing) vid.play().catch(() => {});
    });
    vid.addEventListener("error", () => {
        if (!loaded) return;
        const expired = p.preview_expires_at && Date.parse(p.preview_expires_at) < Date.now();
        playing = false;
        loaded = null;
        msg.replaceChildren(h("span", { text: expired ? "the preview link expired" : "couldn't play this source" }),
            anyPrivate ? h("button", { class: "btn", type: "button", text: "refresh preview", onclick: () => go("show_edit", { id: p.id }, { push: false }) }) : null);
        msg.hidden = false;
        vid.hidden = true;
        update();
    });

    let raf = 0;
    let last = 0;
    function tick(now) {
        if (!playing) return;
        const dt = Math.min(0.25, (now - last) / 1000);
        last = now;
        const c = mode === "render" ? { start: 0, in: 0, speed: 1, out: total } : clipAt(t);
        const driving = c && !vid.hidden && !vid.paused && !vid.seeking && vid.readyState >= 2 && loaded && Date.now() - loadedAt > 200;
        if (driving && mode === "render") t = vid.currentTime;
        else if (driving) {
            const nt = c.start + (vid.currentTime - c.in) / c.speed;
            // only trust the video when it is near where the clock says (right after a seek it can still be behind)
            t = Math.abs(nt - t) < 0.6 ? nt : t + dt;
        } else t += dt;
        if (t >= total - 0.02) {
            t = total;
            playing = false;
            vid.pause();
            update();
            return;
        }
        // a clip's end: move to the next clip's start (the source switches there)
        if (mode !== "render" && c && t >= c.end) t = c.end + 1e-6;
        update();
        sync(false);
        raf = requestAnimationFrame(tick);
    }
    function toggle() {
        if (playing) {
            playing = false;
            cancelAnimationFrame(raf);
            vid.pause();
        } else {
            if (t >= total - 0.05) t = 0;
            playing = true;
            last = performance.now();
            sync(true);
            if (!vid.hidden) vid.play().catch(() => {});
            raf = requestAnimationFrame(tick);
        }
        update();
    }
    onCleanup(() => {
        playing = false;
        cancelAnimationFrame(raf);
        vid.pause();
    });

    // ---- side: the timecode, transport, what is under the playhead
    const tcBig = h("span", { "data-tc": "" });
    const tcTot = h("small", { text: `/ ${dur(total, 1)}` });
    const playBtn2 = h("button", { class: "ib", type: "button", "aria-label": "play", onclick: () => toggle() }, ic("play", 13));
    const step = (dir) => h("button", { class: "ib", type: "button", "aria-label": dir < 0 ? "back one frame" : "forward one frame", onclick: () => {
        playing = false;
        vid.pause();
        setT(t + dir / fps);
    } }, ic(dir < 0 ? "stepb" : "stepf", 12));
    const tcRow = h("div", { class: "tcbig" }, tcBig, tcTot, h("span", { class: "spacer" }), step(-1), playBtn2, step(1));
    const underList = h("ul");
    const under = h("div", { class: "under", "aria-live": "polite" }, h("h4", { text: "under the playhead" }), underList);
    const acts = h("div", { class: "acts", style: "margin-top:2px" });
    if (renderUrl) {
        const seg = h("span", { class: "seg", role: "group", "aria-label": "what to play" });
        const bT = h("button", { type: "button", text: "timeline", "aria-pressed": "true" });
        const bR = h("button", { type: "button", "aria-label": "play the render", "aria-pressed": "false" }, ic("render", 12), " render");
        const setMode = (m) => {
            mode = m;
            bT.setAttribute("aria-pressed", String(m === "timeline"));
            bR.setAttribute("aria-pressed", String(m === "render"));
            boxes.forEach((b) => b && (b.style.visibility = m === "render" ? "hidden" : ""));
            loaded = null;
            sync(true);
            update();
        };
        bT.addEventListener("click", () => setMode("timeline"));
        bR.addEventListener("click", () => setMode("render"));
        seg.append(bT, bR);
        acts.appendChild(seg);
    }
    if (r && r.post_id && r.status === "done") acts.appendChild(h("button", { class: "btn pri", type: "button", text: "view render", onclick: () => go("show_post", { id: r.post_id }) }));
    acts.appendChild(h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) }));
    const side = h("div", { class: "tside" }, tcRow, under);
    if (anyPrivate) side.appendChild(h("p", { class: "under", style: "margin-top:auto" }, ic("lock", 10), ` source is private: the preview streams through a signed link${p.preview_expires_at ? " until " + clockAt(p.preview_expires_at) : ""}.`));
    side.appendChild(acts);

    // ---- tracks: ruler, overlay lanes, a filmstrip main track, sound
    const area = h("div", { class: "area", role: "slider", tabindex: "0", "aria-label": "playhead", "aria-valuemin": "0", "aria-valuemax": String(Math.round(total * 10) / 10) });
    const ruler = h("div", { class: "cruler h-r", "aria-hidden": "true" });
    area.appendChild(ruler);
    const pct = (x) => (clamp(x / total, 0, 1) * 100).toFixed(3) + "%";
    const spanPct = (a, b) => (clamp((b - a) / total, 0, 1) * 100).toFixed(3) + "%";
    const live = []; // [el, start, end]
    // overlays: stacked into as few rows as they need
    const rows = [];
    ovs.map((o, i) => ({ o, i })).sort((a, b) => a.o.start - b.o.start).forEach(({ o, i }) => {
        let rw = rows.find((x) => x.end <= o.start);
        if (!rw) rows.push((rw = { end: 0, items: [] }));
        rw.end = o.end;
        rw.items.push({ o, i });
    });
    if (!rows.length) rows.push({ items: [] });
    const labs = h("div", { class: "labs", "aria-hidden": "true" }, h("div", { class: "h-r" }));
    rows.forEach((rw, ri) => {
        labs.appendChild(h("div", { class: "h-o", text: ri ? "" : "overlay" }));
        const lane = h("div", { class: "clane h-o" });
        if (!rw.items.length) lane.appendChild(h("span", { class: "note", style: "padding:0 6px;font-size:9.5px", text: "none" }));
        rw.items.forEach(({ o, i }) => {
            const e = h("div", { class: "cclip", title: `${o.name} · ${o.kind} · ${o.start}–${o.end} s`, text: `${o.name} · ${o.kind}` });
            e.style.left = pct(o.start);
            e.style.width = spanPct(o.start, o.end);
            e.style.background = OV_COLORS[i % OV_COLORS.length];
            lane.appendChild(e);
            live.push([e, o.start, o.end]);
        });
        area.appendChild(lane);
    });
    labs.appendChild(h("div", { class: "h-m", text: "main" }));
    labs.appendChild(h("div", { class: "h-s", text: "sound" }));
    const lm = h("div", { class: "clane h-m", style: "background:none" });
    main.forEach((c, i) => {
        const e = h("div", { class: "film", title: c.name });
        e.style.left = pct(c.start);
        e.style.width = spanPct(c.start, c.end);
        e.style.setProperty("--c", MAIN_COLORS[i % MAIN_COLORS.length]);
        filmBg(e, c.poster_url);
        const span = num(c.in) && num(c.out) ? ` · ${dur(c.in)}–${dur(c.out)}` : "";
        const sp = num(c.speed) && c.speed !== 1 ? ` ×${c.speed}` : "";
        e.appendChild(h("span", { class: "lbl", text: c.name + span + sp }));
        lm.appendChild(e);
        live.push([e, c.start, c.end]);
    });
    area.appendChild(lm);
    const ls = h("div", { class: "clane h-s" });
    main.forEach((c) => {
        const e = h("div", { class: "cclip" + (c.muted ? " dim" : ""), text: c.muted ? "muted" : c.name });
        e.style.left = pct(c.start);
        e.style.width = spanPct(c.start, c.end);
        e.style.background = "#3f73b8";
        ls.appendChild(e);
        live.push([e, c.start, c.end]);
    });
    area.appendChild(ls);
    const ph = h("div", { class: "cph" });
    area.appendChild(ph);

    function update() {
        ph.style.left = (clamp(t / total, 0, 1) * 100).toFixed(3) + "%";
        area.setAttribute("aria-valuenow", String(Math.round(t * 10) / 10));
        area.setAttribute("aria-valuetext", dur(t, 1));
        tcBig.textContent = dur(t, 1);
        tcSmall.textContent = `${dur(t, 1)} / ${dur(total, 1)}`;
        live.forEach(([e, s, en]) => e.classList.toggle("on", t >= s && t < en));
        const m = mode === "render" ? null : clipAt(t);
        const act = ovs.map((o, i) => ({ o, i })).filter(({ o }) => t >= o.start && t < o.end);
        boxes.forEach((b, i) => b && b.classList.toggle("on", mode !== "render" && t >= ovs[i].start && t < ovs[i].end));
        underList.replaceChildren();
        if (m) underList.appendChild(h("li", null, h("i", { class: "sw", style: `background:${MAIN_COLORS[main.findIndex((c) => c.id === m.id) % MAIN_COLORS.length]}` }), h("span", { class: "n", text: m.name }), h("span", { class: "r", text: `main · ${dur(m.in + (t - m.start) * m.speed, 1)}` })));
        act.forEach(({ o, i }) => underList.appendChild(h("li", null, h("i", { class: "sw", style: `background:${OV_COLORS[i % OV_COLORS.length]}` }), h("span", { class: "n", text: o.name }), h("span", { class: "r", text: `${o.kind} · ${dur(t - o.start, 1)}` }))));
        if (!underList.children.length) underList.appendChild(h("li", { class: "note", text: "nothing under the playhead" }));
        for (const b of [pbtn, playBtn2]) {
            b.replaceChildren(ic(playing ? "pause" : "play", b === pbtn ? 14 : 13));
            b.setAttribute("aria-label", playing ? "pause" : "play");
        }
        big.setAttribute("aria-label", playing ? "pause timeline preview" : "play timeline preview");
        prev.classList.toggle("playing", playing);
        // the lock shows while what plays is private: the clip under the playhead, or the private render
        if (lock) lock.hidden = mode === "render" ? !(r && r.private) : !(m && m.private);
    }
    function setT(x) {
        t = clamp(x, 0, total);
        update();
        sync(true);
    }
    drag(area, (e) => {
        const rc = area.getBoundingClientRect();
        setT(((e.clientX - rc.left) / Math.max(1, rc.width)) * total);
        area.focus({ preventScroll: true });
    });
    area.addEventListener("keydown", (e) => {
        const stepS = e.shiftKey ? 5 : total > 120 ? 2 : 0.5;
        const k = { ArrowLeft: -stepS, ArrowDown: -stepS, ArrowRight: stepS, ArrowUp: stepS, PageDown: -10, PageUp: 10 }[e.key];
        if (k !== undefined) setT(t + k);
        else if (e.key === "Home") setT(0);
        else if (e.key === "End") setT(total);
        else if (e.key === " " || e.key === "k") toggle();
        else return;
        e.preventDefault();
    });

    function buildRuler() {
        const px = area.clientWidth;
        if (px <= 0) return;
        const stepT = tickStep(total, px);
        ruler.replaceChildren();
        for (let s = 0; s <= total + 1e-6; s += stepT) {
            const sp = h("span", { text: dur(s, stepT < 1) });
            const f = s / total;
            sp.style.left = (f * 100).toFixed(3) + "%";
            if (f < 0.05) sp.className = "first";
            else if (f > 0.93) sp.className = "last";
            ruler.appendChild(sp);
        }
    }
    const ro = new ResizeObserver(buildRuler);
    ro.observe(area);
    onCleanup(() => ro.disconnect());

    sync(true);
    update();
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "ctop" }, prev, side), h("div", { class: "ctracks" }, labs, area)));
    return w;
};
