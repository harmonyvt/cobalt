// swarm_board (APP-API-CONTRACT.md section 62.4): any swarm's results as one board. A strip of its agents coloured by
// score, a search, the group chips, and a grid of cards (the first picture, the title, the score, up to 3 fields); more
// load on scroll (100 at a time); a card opens with all of it. Every filter is a new swarm_board call.
const bdPct = (s) => (num(s) ? Math.round(s * 100) + "%" : "–");
const bdTone = (s) => (!num(s) ? "" : s >= 0.75 ? "t-good" : s >= 0.4 ? "t-mid" : "t-low");
const bdBtn = (text, on, fn) => h("button", { class: "btn sm", type: "button", text, "aria-pressed": String(!!on), onclick: fn });

function bdDetail(r, back) {
    const w = h("div", null, h("div", { class: "acts" }, bdBtn("back", false, back)));
    for (const m of r.media || []) {
        if (!safeUrl(m.preview_url)) continue;
        const im = pic(m.preview_url, m.ref, "img bdi");
        w.appendChild(webUrl(m.open_url) ? h("button", { class: "th", type: "button", onclick: () => bridge.openLink(m.open_url) }, im) : im);
    }
    const kv = h("div", { class: "swk" }, h("b", { text: r.title }), swKv("agent", `${r.agent} · ${r.n}`));
    if (num(r.score)) kv.appendChild(swKv("score", bdPct(r.score)));
    if (r.group) kv.appendChild(swKv("group", r.group));
    for (const k in r.fields || {}) kv.appendChild(swKv(k, String(r.fields[k])));
    for (const l of r.links || []) if (webUrl(l)) kv.appendChild(h("button", { class: "lnk", type: "button", text: urlLabel(l), onclick: () => bridge.openLink(l) }));
    w.appendChild(kv);
    return w;
}

VIEWS.board = (d) => {
    const sw = d.swarm || {};
    const q = { id: sw.swarm, q: d.q, agent: d.agent, group: d.group, sort: d.sort, status: d.status };
    const ask = (more) => go("swarm_board", Object.assign({}, q, more), { push: false });
    const w = h("div", null, head(sw.name || "swarm results", h("span", { class: "pill", text: num(sw.score) ? "score " + bdPct(sw.score) : String(sw.status || "") })));
    const body = h("div", { class: "wbody" });
    w.appendChild(body);
    // the agents, coloured by score; tap one for its rows
    const strip = h("div", { class: "bdst" });
    for (const a of d.agents || []) {
        const o = a.outcome || {};
        const t = `agent ${a.agent}: ${a.status}, score ${bdPct(o.score)}, ${o.answered} of ${o.items} answered${a.error ? ", " + a.error : ""}`;
        strip.appendChild(h("button", { type: "button", class: "bda " + (a.status === "failed" ? "t-bad" : bdTone(o.score)), title: t, "aria-label": t, "aria-pressed": String(d.agent === a.agent), onclick: () => ask({ agent: d.agent === a.agent ? undefined : a.agent }) }));
    }
    body.appendChild(strip);
    const input = h("input", { type: "search", placeholder: "search", "aria-label": "search results", value: d.q || "" });
    input.addEventListener("keydown", (e) => e.key === "Enter" && ask({ q: input.value.trim() || undefined }));
    const tools = h("div", { class: "bdt" }, input);
    for (const [v, t] of [["agent", "by agent"], ["score", "best"], ["title", "a–z"]]) tools.appendChild(bdBtn(t, (d.sort || "agent") === v, () => ask({ sort: v })));
    body.appendChild(tools);
    if ((d.groups || []).length) {
        const chips = h("div", { class: "bdt" }, bdBtn("all", d.group === undefined, () => ask({ group: undefined })));
        for (const g of d.groups) chips.appendChild(bdBtn(`${g.value} ${g.count}`, d.group === g.value, () => ask({ group: g.value })));
        body.appendChild(chips);
    }
    const rows = (d.rows || []).slice();
    if (!rows.length) {
        body.appendChild(h("div", { class: "empty", text: "nothing here." }));
        return w;
    }
    const grid = h("div", { class: "thumbs" });
    const end = h("div");
    const box = h("div", { class: "bdg" }, grid, end);
    const detail = h("div");
    const show = (r) => {
        box.hidden = grid.hidden = !!r;
        detail.replaceChildren(r ? bdDetail(r, () => show(null)) : "");
    };
    const add = (list) =>
        list.forEach((r) => {
            const m = (r.media || []).find((x) => safeUrl(x.preview_url));
            const img = pic(m && m.preview_url, r.title, "img bdi");
            if (num(r.score)) img.appendChild(h("span", { class: "badge " + bdTone(r.score), text: bdPct(r.score) }));
            const f = Object.keys(r.fields || {}).slice(0, 3).map((k) => h("span", { class: "bdf", text: `${k}: ${r.fields[k]}` }));
            grid.appendChild(h("button", { class: "th", type: "button", title: r.title, onclick: () => show(r) }, img, h("span", { class: "t", text: r.title }), ...f));
        });
    add(rows);
    const total = d.total || rows.length;
    const note = h("div", { class: "note" });
    const count = () => (note.textContent = `${rows.length} of ${plural(total, "result")}`);
    count();
    body.append(box, detail, note);
    // more on scroll: the next page when the end of the scroll box shows
    let busy = false;
    const io = new IntersectionObserver(async (es) => {
        if (busy || rows.length >= total || grid.hidden || !es.some((e) => e.isIntersecting)) return;
        busy = true;
        const r = await rpc("swarm_board", Object.assign({}, q, { offset: rows.length }));
        busy = false;
        if (!r.sc || !Array.isArray(r.sc.rows)) return;
        rows.push(...r.sc.rows);
        add(r.sc.rows);
        count();
    });
    io.observe(end);
    onCleanup(() => io.disconnect());
    return w;
};
