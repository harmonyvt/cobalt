// A file plays from its public URL, or (a private file) from the signed one-hour preview link the result carried in _meta.
const fileSrc = (f) => (webUrl(f.url) ? f.url : signed(f.id, "url"));

VIEWS.post = (d) => {
    const p = d.post || {};
    const files = p.file_list || [];
    const open = files.filter((f) => fileSrc(f));
    let cur = 0;
    const pv = (f) => f && !webUrl(f.url) && !!signed(f.id, "url");
    const until = p.preview_expires_at ? clockAt(p.preview_expires_at) : "";
    const pillCls = p.status === "public" ? "pill" : p.status === "private" ? "pv" : "pill mute";
    const pill = h("span", { class: pillCls }, p.status === "private" ? ic("lock", 10) : null, p.status === "off" ? "not shared" : p.status || "");
    const w = h("div", null, head(p.title || "post", pill));
    const player = h("div", { class: "vp" });
    const meta = h("dl", { class: "kv" });
    const fileRow = h("div", { class: "files", role: "group", "aria-label": "files in this post" });
    const f0 = open[0] || files[0];
    // the box takes the file's shape: a tall video stays narrow, a wide one fills the row
    if (f0 && num(f0.width) && num(f0.height)) {
        player.style.setProperty("--ar", `${f0.width}/${f0.height}`);
        if (f0.width >= f0.height) player.classList.add("wide");
    }

    function media() {
        player.replaceChildren();
        player.classList.remove("playing");
        const f = open[cur];
        if (!f) {
            player.style.background = grad(p.id);
            const th = safeUrl(p.thumb_url) ? p.thumb_url : signed(p.id, "thumb");
            if (th) player.appendChild(h("img", { class: "still", src: th, alt: "" }));
            player.appendChild(h("div", { class: "none" }, h("span", { text: "private: open in capystore" }), h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) })));
        } else {
            const src = fileSrc(f);
            const poster = signed(f.id, "poster") || (safeUrl(p.thumb_url) ? p.thumb_url : signed(p.id, "thumb"));
            if (f.kind === "video") {
                const v = h("video", { controls: true, playsinline: true, preload: "metadata", poster, src, "aria-label": p.title || "video" });
                // a signed link that ran out: say so and offer a fresh one
                v.addEventListener("error", () => {
                    if (!pv(f)) return;
                    player.appendChild(h("div", { class: "none" }, h("span", { text: p.preview_expires_at && Date.parse(p.preview_expires_at) < Date.now() ? "the preview link expired" : "couldn't play the preview" }),
                        h("button", { class: "btn", type: "button", text: "refresh preview", onclick: () => go("show_post", { id: p.id }, { push: false }) })));
                });
                player.appendChild(v);
            } else player.appendChild(h("img", { class: "still", src, alt: p.title || "" }));
            if (pv(f)) player.appendChild(lockb("private · link valid 1 h", true));
        }
        [...fileRow.children].forEach((b, i) => b.setAttribute("aria-pressed", String(i === cur)));
    }
    open.forEach((f, i) => {
        if (open.length > 1) fileRow.appendChild(h("button", { class: "btn", type: "button", "aria-label": `file ${i + 1}`, text: String(i + 1), onclick: () => {
            cur = i;
            media();
        } }));
    });

    const row = (k, v, cls) => {
        if (v == null || v === "" || (Array.isArray(v) && !v.length)) return;
        meta.appendChild(h("dt", { text: k }));
        meta.appendChild(h("dd", { class: cls || null }, v));
    };
    const from = [];
    if (p.source_host) from.push(webUrl(p.source_link) ? ext(p.source_link, p.source_host) : p.source_host);
    if (p.saved_at) from.push((from.length ? " · " : "") + "saved " + fmtDate(p.saved_at, true));
    row("from", from);
    const size = f0 && num(f0.width) && num(f0.height) ? `${f0.width}×${f0.height}` : "";
    const len = num(p.duration_s) && p.kind === "video" ? dur(p.duration_s) : "";
    row("length", [len, len && size ? " · " : "", size, files.length > 1 ? ` · ${plural(files.length, "file")}${open.length < files.length ? ` (${open.length} playable)` : ""}` : "", num(p.bytes) ? ` · ${fmtBytes(p.bytes)}` : ""].filter(Boolean));
    if (open.some(pv)) row("preview", [h("span", { class: "pv" }, ic("lock", 10), "private · link valid 1 h"), until ? h("span", { class: "note", text: ` until ${until}` }) : null]);
    if (p.caption) {
        const cap = h("div", { class: "cap", text: p.caption, title: "tap to read it all" });
        cap.addEventListener("click", () => cap.classList.toggle("open"));
        row("caption", cap);
    }
    if (p.transcript_excerpt) row("says", h("span", { class: "mute cap", text: "“" + p.transcript_excerpt + "”" }));
    const lr = (u, name) => h("div", { class: "linkrow" }, ext(u, urlLabel(u), ""), copyBtn(u, "copy", `copy ${name}`));
    if (webUrl(p.share_url)) row("link", lr(p.share_url, "share link"));
    if (webUrl(p.private_url)) row("private", lr(p.private_url, "private link"));

    const acts = h("div", { class: "acts" },
        h("button", { class: "btn pri", type: "button", text: "find similar", onclick: () => go("search_library", { query: (p.title || p.id || "").slice(0, 200) }) }));
    if (p.status === "public" && !webUrl(p.share_url)) acts.appendChild(h("button", { class: "btn", type: "button", text: "share link", onclick: () => go("create_share_link", { ids: [p.id] }) }));
    acts.appendChild(h("button", { class: "btn", type: "button", text: "open in capystore", onclick: () => bridge.openLink(APP_URL) }));

    media();
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "cpost" }, h("div", null, player, fileRow), h("div", null, meta, acts))));
    return w;
};
