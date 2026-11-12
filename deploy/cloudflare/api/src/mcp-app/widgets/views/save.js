VIEWS.save = (d) => {
    const w = h("div", null, head("saving to capystore", null));
    const label = urlLabel(d.url || "");
    if (d.state === "error") {
        w.appendChild(h("div", { class: "wbody" }, h("div", { class: "err", style: "margin:0 0 6px" }, h("span", { text: d.error || "couldn't save that link" }), h("button", { class: "btn", type: "button", text: "retry", onclick: () => go("save_link", d.engine && d.engine !== "auto" ? { url: d.url, engine: d.engine } : { url: d.url }, { push: false }) })), h("p", { class: "note", style: "margin:0;overflow-wrap:anywhere", text: label })));
        return w;
    }
    if (d.state === "done") {
        w.replaceChildren(head("saved to capystore", h("span", { class: "pill", text: "done" })));
        w.appendChild(h("div", { class: "wbody" }, d.post ? postCard(d.post, d.share_url || null, "open post") : h("p", { class: "note", style: "margin:0", text: `saved ${label}` })));
        return w;
    }
    const bar = h("i");
    const prog = h("div", { class: "prog", role: "progressbar", "aria-label": "saving", "aria-valuemin": "0", "aria-valuemax": "100" }, bar);
    const text = h("div", { class: "steps", "aria-live": "polite" });
    const again = h("button", { class: "btn", type: "button", text: "check again", hidden: true });
    function paintProg(pr, msg) {
        if (num(pr)) {
            prog.classList.remove("ind");
            bar.style.width = clamp(pr, 0, 1) * 100 + "%";
            prog.setAttribute("aria-valuenow", String(Math.round(pr * 100)));
            text.textContent = msg || `downloading · ${Math.round(pr * 100)}%`;
        } else {
            prog.classList.add("ind");
            prog.removeAttribute("aria-valuenow");
            text.textContent = msg || "downloading";
        }
    }
    paintProg(null);
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "job" }, pic(null, d.url || "save"), h("div", null, h("div", { class: "u", text: label }), prog, text, again))));
    if (d.job) {
        const stop = poll(d.job, (u) => {
            if (u.job) d.job = u.job;
            if (u.stalled) {
                paintProg(null, u.error ? `can't reach the job: ${u.error}` : "still working. some links take a while.");
                again.hidden = false;
            } else if (u.state === "done") show(Object.assign({}, d, { state: "done", job: u.job || d.job, post: u.post || null, share_url: u.share_url || null, error: null }), { push: false });
            else if (u.state === "error") show(Object.assign({}, d, { state: "error", job: u.job || d.job, error: u.error || "couldn't save that link" }), { push: false });
            else paintProg(u.progress);
        });
        again.addEventListener("click", () => {
            again.hidden = true;
            paintProg(null);
            stop.restart();
        });
    }
    return w;
};
