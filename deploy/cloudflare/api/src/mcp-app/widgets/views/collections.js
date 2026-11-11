VIEWS.collections = (d) => {
    const cols = d.collections || [];
    const right = [];
    if (bridge.canMessage()) right.push(h("button", { class: "btn", type: "button", text: "new collection", onclick: () => bridge.message("make a new capystore collection. ask me what to call it.").catch(() => {}) }));
    const w = h("div", null, head(cols.length ? plural(d.total == null ? cols.length : d.total, "collection") : "no collections", right));
    if (!cols.length) {
        w.appendChild(h("div", { class: "empty", text: "no collections yet." }));
        return w;
    }
    const grid = h("div", { class: "cols" });
    cols.forEach((c) => {
        const mos = h("div", { class: "mos", "aria-hidden": "true" });
        const th = (c.thumbs || []).slice(0, 8);
        for (let i = 0; i < 8; i++) mos.appendChild(th[i] ? pic(th[i], c.id + i) : h("div", { class: "pic" }));
        const links = c.links || [];
        const sub = `${plural(links.length, "link")} · ${plural(c.posts || 0, "post")}`;
        const card = h("div", { class: "col" },
            h("button", { class: "open", type: "button", "aria-label": `${c.name}, ${sub}. show its links`, onclick: () => go("list_share_links", { collection: c.name }) }, mos, h("b", { text: c.name }), h("small", { text: sub })));
        const urls = links.map((l) => l.url).filter(Boolean);
        if (urls.length) card.appendChild(copyBtn(() => urls.join("\n"), "copy all links", `copy all links in ${c.name}`));
        grid.appendChild(card);
    });
    w.appendChild(h("div", { class: "wbody" }, grid));
    return w;
};
