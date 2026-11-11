VIEWS.search = (d) => {
    const items = d.items || [];
    const title = items.length || d.total ? `${plural(d.total == null ? items.length : d.total, "post")} · "${d.query || ""}"` : `nothing for "${d.query || ""}"`;
    const right = [];
    if (d.mode === "text") right.push(h("span", { class: "tag", title: "matched on titles and links", text: "text match" }));
    const w = h("div", null, head(title, right));
    if (!items.length) {
        w.appendChild(h("div", { class: "empty", text: "no posts found. try other words." }));
        return w;
    }
    const grid = h("div", { class: "thumbs" });
    items.forEach((p) => {
        const img = pic(p.thumb_url, p.id, "img");
        img.appendChild(h("span", { class: "kind", text: p.kind }));
        if (p.kind === "video" && num(p.duration_s)) img.appendChild(h("span", { class: "badge", text: dur(p.duration_s) }));
        grid.appendChild(h("button", { class: "th", type: "button", onclick: () => go("show_post", { id: p.id }) }, img, h("div", { class: "t", text: p.title })));
    });
    const body = h("div", { class: "wbody" }, grid);
    if (d.total > items.length) body.appendChild(h("p", { class: "note", style: "margin:10px 0 0", text: `showing ${items.length} of ${d.total}. ask for more or narrow the search.` }));
    w.appendChild(body);
    return w;
};
