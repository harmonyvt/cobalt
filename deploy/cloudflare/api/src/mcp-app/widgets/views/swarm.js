// swarm_plan and swarm_get (APP-API-CONTRACT.md section 59) drawn as one card: the plan Harmony approves, the batch strip
// while it runs, and what it made. They are registry ops; the result gets this view through src/mcp-app/follow.ts.
// There is no approve or apply button on purpose: the agent cannot approve its own swarm, so the only way forward is a link
// to the approval page in capystore, opened with the host's open-link.
const SW_STATE = {
    awaiting_approval: ["needs approval", "warn"],
    running: ["running", ""],
    stopping: ["stopping", "warn"],
    done: ["done", ""],
    failed: ["failed", "bad"],
    stopped: ["stopped", "mute"],
    declined: ["declined", "mute"],
    expired: ["expired", "mute"],
};
const swUsd = (n) => (!num(n) ? "$0" : n >= 100 ? "$" + Math.round(n) : "$" + n.toFixed(2));
const swList = (a) => (Array.isArray(a) ? a.filter((x) => typeof x === "string") : []);

// the scope: { kind: [ids] } as "kind (3)" parts
function swScope(sc) {
    const parts = [];
    for (const k in sc || {}) parts.push(Array.isArray(sc[k]) ? `${k} (${sc[k].length})` : k);
    return parts.join(", ");
}

// long text clamped to a few lines, with a toggle only when it is long
function swText(text, cls) {
    const p = h("p", { class: "swt clamp " + (cls || ""), text });
    if (text.length < 150 && text.split("\n").length < 3) {
        p.classList.remove("clamp");
        return p;
    }
    let open = false;
    const b = h("button", { class: "btn sm", type: "button", "aria-expanded": "false", text: "show all", onclick: () => {
        open = !open;
        p.classList.toggle("clamp", !open);
        b.textContent = open ? "show less" : "show all";
        b.setAttribute("aria-expanded", String(open));
    } });
    return h("div", null, p, b);
}

const swKv = (k, v) => h("div", { class: "kvr" }, h("span", { class: "k", text: k }), h("span", { class: "v", text: v }));

function swCells(t) {
    const strip = h("div", { class: "swcells", role: "img", "aria-label": `${t.done} of ${t.total} batches done` });
    for (const c of t.cells || []) strip.appendChild(h("i", { class: "c-" + c.status, title: `batch ${c.idx + 1}: ${c.status}` }));
    const bits = [];
    if (t.done) bits.push(`${t.done} done`);
    if (t.running) bits.push(`${t.running} running`);
    if (t.failed) bits.push(`${t.failed} failed`);
    if (t.queued) bits.push(`${t.queued} queued`);
    return h("div", null, strip, h("div", { class: "note", text: `${plural(t.total, "batch", "batches")}: ${bits.join(" · ") || "none"}` }));
}

function swOpen(url, label, pri) {
    if (!webUrl(url)) return null;
    return h("button", { class: "btn" + (pri ? " pri" : ""), type: "button", text: label, onclick: () => bridge.openLink(url) });
}

VIEWS.swarm = (d) => {
    const st = SW_STATE[d.status] || [String(d.status || "swarm"), "mute"];
    const t = d.tasks || { total: 0, queued: 0, running: 0, done: 0, failed: 0, cells: [] };
    const w = h("div", null, head(d.name || "swarm", h("span", { class: "pill" + (st[1] ? " " + st[1] : ""), text: st[0] })));
    const body = h("div", { class: "wbody swb" });
    w.appendChild(body);
    const est = d.estimate_usd || { low: 0, high: 0 };
    const mode = { propose: "proposes changes", read: "reads", act: "acts" }[d.mode] || d.mode;

    if (d.status === "awaiting_approval") {
        body.appendChild(h("div", { class: "swk" },
            swKv("size", `${plural(d.items, "item")} in ${plural(t.total, "task")}`),
            swKv("mode", mode),
            swList(d.tools).length ? swKv("reads", swList(d.tools).join(", ")) : null,
            swList(d.writes).length ? swKv("writes", swList(d.writes).join(", ")) : null,
            swScope(d.scope) ? swKv("scope", swScope(d.scope)) : null,
            swKv("cost", `${swUsd(est.low)} to ${swUsd(est.high)} (cap ${swUsd(d.cap_usd)})`)));
        if (d.prompt) body.appendChild(swText(d.prompt));
        body.appendChild(h("div", { class: "acts" }, swOpen(d.approve_url, "Approve in capystore", true)));
        body.appendChild(h("p", { class: "note swn", text: "Nothing runs until you approve it. The agent can't approve it." + (d.expires_at ? ` The plan expires ${fmtDate(new Date(d.expires_at).toISOString())}.` : "") }));
        return w;
    }

    if (d.status === "running" || d.status === "stopping") {
        body.appendChild(swCells(t));
        const cap = num(d.cap_usd) && d.cap_usd > 0 ? d.cap_usd : 0;
        const bar = h("i");
        bar.style.width = (cap ? clamp(d.spent_usd / cap, 0, 1) * 100 : 0) + "%";
        body.appendChild(h("div", { class: "prog", role: "progressbar", "aria-label": "spent of cap", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(cap ? clamp(d.spent_usd / cap, 0, 1) * 100 : 0)) }, bar));
        body.appendChild(h("div", { class: "note", text: `spent ${swUsd(d.spent_usd)} of ${swUsd(d.cap_usd)} cap` }));
        body.appendChild(h("div", { class: "acts" }, h("button", { class: "btn", type: "button", text: "refresh", onclick: () => go("swarm_get", { id: d.swarm }, { push: false }) })));
        return w;
    }

    if (d.status === "done") {
        const c = d.changes;
        body.appendChild(swCells(t));
        if (d.mode === "propose" && c) {
            body.appendChild(h("div", { class: "swk" },
                swKv("proposed", plural(c.total, "change")),
                swKv("kept", String(c.kept)),
                c.done || c.failed || (d.apply && d.apply.status !== "none") ? swKv("applied", `${c.done} done, ${c.failed} failed`) : null,
                swKv("spent", swUsd(d.spent_usd))));
            const n = c.total;
            body.appendChild(h("div", { class: "acts" }, swOpen(d.approve_url, n ? `Review ${plural(n, "change")}` : "Open in capystore", n > 0 && !(d.apply && d.apply.status === "applied"))));
            body.appendChild(h("p", { class: "note swn", text: "Changes happen only after you review and apply them in capystore." }));
        } else {
            if (d.reduce) body.appendChild(swText(d.reduce, "swr"));
            body.appendChild(h("div", { class: "swk" }, swKv("tasks", `${t.done} done${t.failed ? `, ${t.failed} failed` : ""}`), swKv("spent", swUsd(d.spent_usd))));
            const open = swOpen(d.approve_url, "Open in capystore", false);
            if (open) body.appendChild(h("div", { class: "acts" }, open));
        }
        return w;
    }

    // failed, stopped, declined, expired
    if (d.error) body.appendChild(h("div", { class: "err", style: "margin:0 0 6px" }, h("span", { text: d.error })));
    else body.appendChild(h("p", { class: "note", style: "margin:0 0 6px", text: d.status === "declined" ? "Harmony declined this plan." : d.status === "expired" ? "The plan expired before it was approved." : "It did not finish." }));
    if (t.total && (d.status === "failed" || d.status === "stopped")) body.appendChild(swCells(t));
    if (num(d.spent_usd) && d.spent_usd > 0) body.appendChild(h("div", { class: "note", text: `spent ${swUsd(d.spent_usd)}` }));
    const open = swOpen(d.approve_url, "Open in capystore", false);
    if (open) body.appendChild(h("div", { class: "acts" }, open));
    return w;
};
