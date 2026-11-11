const WEBP_MAX = 10;
const WEBP_MIN = 0.5;

function postCard(post, shareUrl, openLabel) {
    const box = h("div", { class: "result" }, pic(post && (post.thumb_url || signed(post.id, "thumb")), post ? post.id : "x"));
    const side = h("div");
    if (post) side.appendChild(h("b", { text: post.title }));
    if (shareUrl) side.appendChild(h("div", { class: "linkrow", style: "margin-top:3px" }, ext(shareUrl, urlLabel(shareUrl), ""), copyBtn(shareUrl, "copy", "copy share link")));
    if (post) side.appendChild(h("div", { class: "acts", style: "margin-top:6px" }, h("button", { class: "btn pri", type: "button", text: openLabel || "open post", onclick: () => go("show_post", { id: post.id }) })));
    box.appendChild(side);
    return box;
}

function webpPick(d) {
    const src = d.source || {};
    const total = num(src.duration_s) && src.duration_s > 0 ? src.duration_s : Math.max(10, (d.range && d.range.end) || 0);
    let s = d.range ? d.range.start : 0;
    let e = d.range ? d.range.end : Math.min(5, total);
    let width = d.width === 320 ? 320 : 480;
    let quality = d.quality || "med";
    const w = h("div");
    const readout = h("span", { "aria-live": "polite" });
    const status = h("span", { class: "note" });
    w.appendChild(head(h("b", { text: `webp · ${src.title || ""}` }), readout));

    const cells = h("div", { class: "cells" });
    if (safeUrl(src.poster_url)) filmBg(cells, src.poster_url);
    else cells.style.background = grad(src.id);
    const sel = h("div", { class: "sel" });
    cells.appendChild(sel);
    const strip = h("div", { class: "strip" }, cells);
    const hs = h("button", { class: "hd", type: "button", role: "slider", "aria-label": "start" });
    const he = h("button", { class: "hd", type: "button", role: "slider", "aria-label": "end" });
    strip.append(hs, he);

    const setRange = (which, t) => {
        t = Math.round(t * 10) / 10;
        if (which === "s") {
            s = clamp(t, 0, Math.max(0, total - WEBP_MIN));
            if (e < s + WEBP_MIN) e = s + WEBP_MIN;
            if (e - s > WEBP_MAX) e = s + WEBP_MAX;
            e = Math.min(e, total);
        } else {
            e = clamp(t, Math.min(WEBP_MIN, total), total);
            if (s > e - WEBP_MIN) s = Math.max(0, e - WEBP_MIN);
            if (e - s > WEBP_MAX) s = e - WEBP_MAX;
        }
        s = Math.round(s * 10) / 10;
        e = Math.round(e * 10) / 10;
        paint();
    };
    function paint() {
        const l = (s / total) * 100;
        const r = (e / total) * 100;
        sel.style.left = l + "%";
        sel.style.width = r - l + "%";
        hs.style.left = l + "%";
        he.style.left = r + "%";
        hs.setAttribute("aria-valuemin", "0");
        hs.setAttribute("aria-valuemax", String(total));
        hs.setAttribute("aria-valuenow", String(s));
        hs.setAttribute("aria-valuetext", dur(s, 1));
        he.setAttribute("aria-valuemin", "0");
        he.setAttribute("aria-valuemax", String(total));
        he.setAttribute("aria-valuenow", String(e));
        he.setAttribute("aria-valuetext", dur(e, 1));
        readout.textContent = `${(e - s).toFixed(1)} s · ${width} px · ${quality}`;
        status.textContent = `start ${dur(s, 1)} · end ${dur(e, 1)}`;
    }
    const at = (ev) => {
        const r = strip.getBoundingClientRect();
        return clamp((ev.clientX - r.left) / Math.max(1, r.width), 0, 1) * total;
    };
    drag(hs, (ev) => setRange("s", at(ev)));
    drag(he, (ev) => setRange("e", at(ev)));
    [[hs, "s"], [he, "e"]].forEach(([el, which]) =>
        el.addEventListener("keydown", (ev) => {
            const step = ev.shiftKey ? 5 : 0.5;
            const cur = which === "s" ? s : e;
            const k = { ArrowLeft: -step, ArrowDown: -step, ArrowRight: step, ArrowUp: step }[ev.key];
            if (k === undefined) return;
            ev.preventDefault();
            setRange(which, cur + k);
        }),
    );

    const seg = (label, opts, get, set) => {
        const g = h("span", { class: "seg", role: "group", "aria-label": label });
        opts.forEach((o) => g.appendChild(h("button", { type: "button", text: String(o), "aria-pressed": String(get() === o), onclick: () => {
            set(o);
            [...g.children].forEach((b, i) => b.setAttribute("aria-pressed", String(opts[i] === o)));
            paint();
        } })));
        return g;
    };
    const go2 = h("button", { class: "btn pri", type: "button", text: "convert", onclick: () => go("convert_to_webp", { id: src.id, start: s, end: e, width, quality }, { push: false }) });
    w.appendChild(h("div", { class: "wbody" }, strip,
        h("div", { class: "row", style: "justify-content:space-between;margin:4px 6px 0;font:10.5px var(--mono);color:var(--mute)" }, h("span", { text: "0:00" }), status, h("span", { text: dur(total) })),
        h("div", { class: "rng" }, seg("quality", ["low", "med", "high"], () => quality, (v) => (quality = v)), seg("width in pixels", [320, 480], () => width, (v) => (width = v)), h("span", { class: "spacer" }), go2),
        h("p", { class: "note", style: "margin:6px 0 0", text: `up to ${WEBP_MAX} s. drag the pink handles, or focus one and use the arrow keys.` })));
    paint();
    return w;
}

function webpRunning(d) {
    const src = d.source || {};
    const r = d.range;
    const w = h("div", null, head(`webp · ${src.title || ""}`, r ? `${dur(r.start, 1)}–${dur(r.end, 1)} · ${d.width} px · ${d.quality}` : null));
    const bar = h("i");
    const prog = h("div", { class: "prog", role: "progressbar", "aria-label": "converting", "aria-valuemin": "0", "aria-valuemax": "100" }, bar);
    const text = h("div", { class: "steps", "aria-live": "polite" });
    const again = h("button", { class: "btn", type: "button", text: "check again", hidden: true });
    function paintProg(pr, msg) {
        if (num(pr)) {
            prog.classList.remove("ind");
            bar.style.width = clamp(pr, 0, 1) * 100 + "%";
            prog.setAttribute("aria-valuenow", String(Math.round(pr * 100)));
            text.textContent = msg || `converting · ${Math.round(pr * 100)}%`;
        } else {
            prog.classList.add("ind");
            prog.removeAttribute("aria-valuenow");
            text.textContent = msg || "converting";
        }
    }
    paintProg(d.progress);
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "job" }, pic(src.poster_url, src.id), h("div", null, prog, text, again))));
    if (d.job) {
        const stop = poll(d.job, (u) => {
            if (u.job) d.job = u.job;
            if (u.stalled) {
                paintProg(null, u.error ? `can't reach the job: ${u.error}` : "still working. big clips take a while.");
                again.hidden = false;
            } else if (u.state === "done") show(Object.assign({}, d, { state: "done", job: u.job || d.job, progress: 1, post: u.post || null, share_url: u.share_url || null, error: null }), { push: false });
            else if (u.state === "error") show(Object.assign({}, d, { state: "error", job: u.job || d.job, error: u.error || "the conversion failed" }), { push: false });
            else paintProg(u.progress);
        });
        again.addEventListener("click", () => {
            again.hidden = true;
            paintProg(d.progress);
            stop.restart();
        });
    }
    return w;
}

VIEWS.webp = (d) => {
    const src = d.source || {};
    if (d.state === "pick") return webpPick(d);
    if (d.state === "running") return webpRunning(d);
    if (d.state === "error") {
        const retry = () => (d.range ? go("convert_to_webp", { id: src.id, start: d.range.start, end: d.range.end, width: d.width, quality: d.quality }, { push: false }) : show(Object.assign({}, d, { state: "pick", error: null }), { push: false }));
        return h("div", null, head(`webp · ${src.title || ""}`, null),
            h("div", { class: "wbody" }, h("div", { class: "err", style: "margin:0" }, h("span", { text: d.error || "the conversion failed" }), h("button", { class: "btn", type: "button", text: "retry", onclick: retry }))));
    }
    // done
    const post = d.post;
    const bytes = post && num(post.bytes) ? ` · ${fmtBytes(post.bytes)}` : "";
    const r = d.range;
    return h("div", null, head(`webp ready · ${src.title || ""}`, h("span", { class: "pill", text: "done" })),
        h("div", { class: "wbody" }, postCard(post, d.share_url, "open post"),
            h("p", { class: "note", style: "margin:6px 0 0", text: `${r ? (r.end - r.start).toFixed(1) + " s · " : ""}${d.width} px · ${d.quality}${bytes}` })));
};
