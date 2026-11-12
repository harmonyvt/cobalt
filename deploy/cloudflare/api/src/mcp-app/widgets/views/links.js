VIEWS.links = (d) => {
    const links = d.links || [];
    const right = links.length > 1 ? copyBtn(() => links.map((l) => l.url).join("\n"), "copy all", "copy all links") : null;
    const w = h("div", null, head(links.length ? `share links · ${d.total == null ? links.length : d.total}` : "share links", right));
    if (!links.length) {
        w.appendChild(h("div", { class: "empty", text: "no share links here yet." }));
        return w;
    }
    const box = h("div");
    links.forEach((l) => {
        const stack = h("div", { class: "stack", "aria-hidden": "true" });
        const th = (l.thumbs || []).slice(0, 3);
        if (th.length) th.forEach((t, i) => stack.appendChild(pic(t, l.id + i)));
        else stack.appendChild(pic(null, l.id));
        const title = l.title || `${plural(l.files, "file")} · ${fmtDate(l.created_at)}`.replace(/ · $/, "");
        const isNew = d.created && d.created === l.id;
        box.appendChild(h("div", { class: "lk" + (isNew ? " new" : "") }, stack,
            h("div", { class: "t" }, h("b", { text: title }), ext(l.url, urlLabel(l.url), "")),
            h("div", { class: "m" },
                isNew ? h("span", { class: "tag n", text: "new" }) : null,
                h("span", { class: "tag", text: plural(l.files, "file") }),
                l.private ? h("span", { class: "tag w" }, ic("lock", 9), "private") : null,
                l.collection ? h("span", { class: "tag", text: l.collection }) : null),
            copyBtn(l.url, "copy", `copy link ${title}`)));
    });
    const ml = limitList(box, 3);
    w.appendChild(h("div", { class: "wbody", style: "padding-top:2px" }, box, ml.btn));
    return w;
};
