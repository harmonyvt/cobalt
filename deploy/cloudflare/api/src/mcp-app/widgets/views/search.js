// private and off posts have a signed one-hour thumbnail (from the result's _meta, by post id) and a lock; a tile shows its kind and length
const isPriv = (p) => p.status === "private" || p.status === "off";

VIEWS.search = (d) => {
    const items = d.items || [];
    // mode "list": no query, the library newest first
    const what = d.query ? ` · "${d.query}"` : "";
    const title = items.length || d.total ? `${plural(d.total == null ? items.length : d.total, "post")}${what}` : d.query ? `nothing for "${d.query}"` : "nothing here";
    let layout = "grid";
    const right = [];
    if (d.mode === "text") right.push(h("span", { class: "tag", title: "matched on titles and links", text: "text match" }));
    else if (d.mode === "meaning") right.push(h("span", { class: "opt", text: "meaning match" }));
    const w = h("div");
    if (!items.length) {
        w.appendChild(head(title, right));
        w.appendChild(h("div", { class: "empty", text: d.query ? "no posts found. try other words." : "no posts match those filters." }));
        return w;
    }
    const seg = h("span", { class: "seg", role: "group", "aria-label": "layout" });
    const bGrid = h("button", { type: "button", "aria-label": "grid", "aria-pressed": "true" }, ic("grid", 12));
    const bList = h("button", { type: "button", "aria-label": "list", "aria-pressed": "false" }, ic("list", 12));
    seg.append(bGrid, bList);
    right.push(seg);
    w.appendChild(head(title, right));

    // grid: the first row of tiles (3 on a phone, 6 when wider)
    const grid = h("div", { class: "thumbs" });
    items.forEach((p) => {
        const img = pic(p.thumb_url || signed(p.id, "thumb"), p.id, "img");
        if (isPriv(p)) img.appendChild(lockb(null, false));
        img.appendChild(h("span", { class: "kind", text: p.kind }));
        if (p.kind === "video" && num(p.duration_s)) img.appendChild(h("span", { class: "badge", text: dur(p.duration_s) }));
        grid.appendChild(h("button", { class: "th", type: "button", title: p.title, "aria-label": `${p.title}, ${p.kind}${isPriv(p) ? ", private" : ""}`, onclick: () => go("show_post", { id: p.id }) }, img, h("span", { class: "t", text: p.title })));
    });
    const cols = () => {
        const n = getComputedStyle(grid).gridTemplateColumns.split(" ").length;
        return grid.isConnected && n > 1 ? n : 3;
    };
    const gl = limitList(grid, cols);
    const gridPane = h("div", { class: "wbody" }, grid, gl.btn);
    const ro = new ResizeObserver(() => gl.refresh());
    ro.observe(grid);
    onCleanup(() => ro.disconnect());

    // list: thumb, title, kind and length, date, public/private dot; the first 3
    const ul = h("ul", { class: "clist" });
    items.forEach((p) => {
        const dotCls = "dot" + (p.status === "private" ? " priv" : p.status === "off" ? " off" : "");
        const row = h("button", { class: "cr", type: "button", onclick: () => go("show_post", { id: p.id }) },
            (() => {
                const im = pic(p.thumb_url || signed(p.id, "thumb"), p.id);
                if (isPriv(p)) im.appendChild(lockb(null, false));
                return im;
            })(),
            h("span", { class: "tt", text: p.title }),
            h("span", { class: "k" }, p.kind + (p.kind === "video" && num(p.duration_s) ? " · " + dur(p.duration_s) : ""), h("span", { class: "d", text: " · " + fmtDate(p.saved_at) })),
            h("i", { class: dotCls, role: "img", "aria-label": p.status === "public" ? "public" : p.status === "private" ? "private" : "not shared" }));
        ul.appendChild(h("li", null, row));
    });
    const ll = limitList(ul, 3);
    const listPane = h("div", { class: "wbody", hidden: true }, ul, ll.btn);

    const pick = (m) => {
        layout = m;
        bGrid.setAttribute("aria-pressed", String(m === "grid"));
        bList.setAttribute("aria-pressed", String(m === "list"));
        gridPane.hidden = m !== "grid";
        listPane.hidden = m !== "list";
        gl.refresh();
        ll.refresh();
    };
    bGrid.addEventListener("click", () => pick("grid"));
    bList.addEventListener("click", () => pick("list"));
    w.append(gridPane, listPane);

    const nPriv = items.filter(isPriv).length;
    const foot = h("div", { class: "cfoot" }, h("span", { class: "note", text: d.total > items.length ? `${items.length} of ${d.total} · ask for more or narrow the search` : `${items.length} of ${d.total == null ? items.length : d.total}` }), h("span", { class: "sp" }));
    if (nPriv) foot.appendChild(h("span", null, h("i", { class: "dot priv" }), ` ${nPriv} private`));
    w.appendChild(foot);
    return w;
};
