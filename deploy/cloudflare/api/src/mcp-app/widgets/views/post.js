VIEWS.post = (d) => {
    const p = d.post || {};
    const files = p.file_list || [];
    const open = files.filter((f) => webUrl(f.url));
    let cur = 0;
    const pillCls = p.status === "public" ? "pill" : p.status === "private" ? "pill warn" : "pill mute";
    const w = h("div", null, head(p.title || "post", h("span", { class: pillCls, text: p.status || "" })));
    const player = h("div", { class: "player" });
    const meta = h("dl", { class: "meta" });
    const fileRow = h("div", { class: "files", role: "group", "aria-label": "files in this post" });

    function media() {
        player.replaceChildren();
        const f = open[cur];
        if (!f) {
            player.style.background = grad(p.id);
            if (safeUrl(p.thumb_url)) player.appendChild(h("img", { src: p.thumb_url, alt: "" }));
            player.appendChild(h("div", { class: "none" }, h("span", { text: "private: open in capystore" }), h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) })));
        } else if (f.kind === "video") {
            player.appendChild(h("video", { controls: true, playsinline: true, preload: "metadata", poster: safeUrl(p.thumb_url) ? p.thumb_url : null, src: f.url, "aria-label": p.title || "video" }));
        } else {
            player.appendChild(h("img", { src: f.url, alt: p.title || "" }));
        }
        [...fileRow.children].forEach((b, i) => b.setAttribute("aria-pressed", String(i === cur)));
    }
    open.forEach((f, i) => {
        if (open.length > 1) fileRow.appendChild(h("button", { class: "btn", type: "button", "aria-label": `file ${i + 1}`, text: String(i + 1), onclick: () => {
            cur = i;
            media();
        } }));
    });

    const row = (k, v) => {
        if (v == null || v === "" || (Array.isArray(v) && !v.length)) return;
        meta.appendChild(h("dt", { text: k }));
        meta.appendChild(h("dd", null, v));
    };
    const from = [];
    if (p.source_host) from.push(webUrl(p.source_link) ? ext(p.source_link, p.source_host) : p.source_host);
    if (p.saved_at) from.push((from.length ? " · " : "") + "saved " + fmtDate(p.saved_at, true));
    row("From", from);
    const f0 = open[0] || files[0];
    const size = f0 && num(f0.width) && num(f0.height) ? `${f0.width}×${f0.height}` : "";
    const len = num(p.duration_s) && p.kind === "video" ? dur(p.duration_s) : "";
    row(p.kind === "video" ? "Length" : "Size", [len, len && size ? " · " : "", size].filter(Boolean));
    if (files.length > 1) row("Files", `${files.length} files${open.length < files.length ? ` (${open.length} public)` : ""}`);
    row("Caption", p.caption);
    if (p.transcript_excerpt) {
        meta.appendChild(h("dt", { text: "Transcript" }));
        meta.appendChild(h("dd", { class: "mute", text: "“" + p.transcript_excerpt + "”" }));
    }
    const lr = (u, name) => h("div", { class: "linkrow" }, ext(u, urlLabel(u), ""), copyBtn(u, "copy", `copy ${name}`));
    if (webUrl(p.share_url)) row("Share link", lr(p.share_url, "share link"));
    if (webUrl(p.private_url)) row("Private link", lr(p.private_url, "private link"));

    const acts = h("div", { class: "row", style: "margin-top:12px" },
        h("button", { class: "btn pri", type: "button", text: "find similar", onclick: () => go("search_library", { query: (p.title || p.id || "").slice(0, 200) }) }),
        h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) }));
    if (open[0] && open[0].kind === "video" && bridge.canFull()) acts.appendChild(h("button", { class: "btn", type: "button", text: "full screen", onclick: () => bridge.fullscreen() }));

    media();
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "post" }, h("div", null, player, fileRow), h("div", null, meta, acts))));
    return w;
};
