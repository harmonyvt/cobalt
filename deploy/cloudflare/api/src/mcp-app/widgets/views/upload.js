const PUT_TYPES = ["image/gif", "image/webp", "image/png", "image/jpeg", "video/mp4", "video/quicktime", "image/heic"];

// the name a link is asked for with: at most 200 characters, the extension kept
function upName(name) {
    const s = String(name || "");
    if (s.length <= 200) return s;
    const m = /\.[A-Za-z0-9]{1,8}$/.exec(s);
    const ext = m ? m[0] : "";
    return s.slice(0, 200 - ext.length) + ext;
}

VIEWS.upload = (d) => {
    const max = num(d.max_bytes) ? d.max_bytes : 100000000;
    const slots = (d.uploads || []).map((u) => ({ link: u, file: null, state: "idle", pct: 0, msg: "", item: null, row: null }));
    const ERR = {
        "error.library.unsupported": "that file type isn't supported",
        "error.library.too_large": `too big (the limit is ${fmtBytes(max)})`,
        "error.library.empty": "the file is empty",
        "error.library.incomplete": "the upload was cut short",
        "error.library.length_required": "the browser didn't send a file size",
        "error.mcp.not_found": "uploads are switched off",
        "error.api.generic": "capystore had a problem. try again.",
    };
    const w = h("div", null, head("upload to capystore", [h("span", { text: `links last 15 min · ${fmtBytes(max)} each` }), d.public ? h("span", { class: "tag", text: "public" }) : null]));
    const list = h("div", { style: "margin-top:6px" });
    const ml = limitList(list, 3);
    const note = h("p", { class: "note", style: "margin:6px 0 0", "aria-live": "polite", text: "the files go from here straight to capystore, not through the chat." });
    const input = h("input", { type: "file", multiple: true, accept: (d.accept || []).map((x) => "." + String(x).replace(/^\./, "")).join(","), "aria-hidden": "true", tabindex: "-1" });
    const drop = h("div", { class: "drop", role: "button", tabindex: "0", "aria-label": "choose files to upload" },
        h("span", { text: "drop videos or pictures, or tap to choose" }), h("span", { class: "sp" }), h("span", { class: "btn", text: "choose" }), input);
    w.appendChild(h("div", { class: "wbody" }, drop, list, ml.btn, note));

    function paintRow(s) {
        const name = s.file ? s.file.name : s.link.name;
        const row = s.row || (s.row = h("div", { class: "up" }));
        const bar = h("i");
        bar.style.width = (s.state === "saved" ? 100 : s.pct) + "%";
        const status = { idle: "waiting for a file", waiting: "waiting", uploading: `uploading ${s.pct}%`, saved: s.item ? "saved" : "saved", failed: s.msg, expired: s.msg }[s.state];
        const t = h("div", { class: "t" }, h("b", { text: name }), s.file ? h("small", { text: " " + fmtBytes(s.file.size) }) : null);
        if (s.file) t.appendChild(h("div", { class: "prog", role: "progressbar", "aria-label": `${name} progress`, "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(s.state === "saved" ? 100 : s.pct) }, bar));
        t.appendChild(h("small", { class: "st", text: status }));
        row.className = "up" + (s.state === "saved" ? " ok" : s.state === "failed" || s.state === "expired" ? " bad" : "");
        const acts = h("div", { class: "acts2" });
        row.replaceChildren(h("div", { class: "ic pic" }), t, acts);
        row.firstChild.style.background = grad(name);
        if (s.state === "saved") {
            acts.appendChild(h("span", { class: "tag", text: "in library" }));
            if (s.item && s.item.id) acts.appendChild(h("button", { class: "btn", type: "button", "aria-label": `open ${name}`, text: "open", onclick: () => go("show_post", { id: s.item.id }) }));
        } else if (s.state === "expired") acts.appendChild(h("button", { class: "btn", type: "button", text: "get a fresh link", onclick: () => fresh(s).then(pump) }));
        else if (s.state === "failed") acts.appendChild(h("button", { class: "btn", type: "button", text: "retry", onclick: () => {
            s.state = "waiting";
            s.pct = 0;
            paintRow(s);
            pump();
        } }));
    }
    const paintAll = () => {
        list.replaceChildren();
        slots.forEach((s) => {
            paintRow(s);
            list.appendChild(s.row);
        });
        ml.refresh();
    };

    // a new link for a slot (the old one expired), or for files beyond the links we have
    async function fresh(s) {
        s.state = "waiting";
        s.msg = "";
        paintRow(s);
        const r = await rpc("upload_files", { files: [{ name: upName(s.file.name) }], public: d.public === true });
        const u = r.sc && r.sc.uploads && r.sc.uploads[0];
        if (!u) {
            s.state = "failed";
            s.msg = r.error || "couldn't get a fresh link";
            paintRow(s);
            return;
        }
        s.link = u;
        s.state = "waiting";
        paintRow(s);
    }

    function send(s) {
        return new Promise((resolve) => {
            const xhr = new XMLHttpRequest();
            // the library shows the name of the file that was chosen, whichever link it was paired with (the name is not part
            // of the signed token, so setting it changes nothing about who may upload)
            let url = s.link.upload_url;
            try {
                const u = new URL(url);
                u.searchParams.set("name", upName(s.file.name));
                url = u.toString();
            } catch {}
            xhr.open("PUT", url);
            xhr.setRequestHeader("Content-Type", PUT_TYPES.includes(s.file.type) ? s.file.type : "application/octet-stream");
            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                    s.pct = Math.min(99, Math.round((e.loaded / e.total) * 100));
                    paintRow(s);
                }
            };
            xhr.onload = () => {
                let body = null;
                try {
                    body = JSON.parse(xhr.responseText);
                } catch {}
                resolve({ status: xhr.status, body });
            };
            xhr.onerror = () => resolve({ status: 0, body: null });
            xhr.ontimeout = xhr.onerror;
            xhr.send(s.file);
        });
    }
    async function upload(s) {
        if (s.file.size > max) {
            s.state = "failed";
            s.msg = `too big (the limit is ${fmtBytes(max)})`;
            return paintRow(s);
        }
        if (Date.parse(s.link.expires_at) < Date.now() + 2000) {
            await fresh(s);
            if (s.state === "failed") return;
        }
        s.state = "uploading";
        s.pct = 0;
        paintRow(s);
        const r = await send(s);
        if (r.status >= 200 && r.status < 300 && r.body && r.body.status === "success") {
            s.state = "saved";
            s.item = r.body.item || null;
        } else if (r.status === 401) {
            s.state = "expired";
            s.msg = "the upload link expired";
        } else {
            s.state = "failed";
            const code = r.body && r.body.error && r.body.error.code;
            s.msg = r.status === 0 ? "couldn't reach capystore" : ERR[code] || `capystore refused it (${r.status})`;
        }
        paintRow(s);
    }
    let running = false;
    async function pump() {
        if (running) return;
        running = true;
        let s;
        while ((s = slots.find((x) => x.state === "waiting"))) await upload(s);
        running = false;
        const n = slots.filter((x) => x.state === "saved").length;
        note.textContent = n ? `${plural(n, "file")} in your library.` : note.textContent;
    }

    async function addFiles(files) {
        const fs = [...files].slice(0, 10);
        const extra = [];
        for (const f of fs) {
            const free = slots.filter((x) => !x.file);
            const s = free.find((x) => x.link.name === f.name) || free[0];
            if (s) {
                s.file = f;
                s.state = "waiting";
            } else extra.push(f);
        }
        if (extra.length) {
            note.textContent = "getting more upload links…";
            const r = await rpc("upload_files", { files: extra.map((f) => ({ name: upName(f.name) })), public: d.public === true });
            const ups = (r.sc && r.sc.uploads) || [];
            extra.forEach((f, i) => {
                const s = { link: ups[i] || { name: f.name, upload_url: "", expires_at: "" }, file: f, state: ups[i] ? "waiting" : "failed", pct: 0, msg: r.error || "couldn't get an upload link", item: null, row: null };
                slots.push(s);
            });
            note.textContent = r.error ? r.error : "the files go from here straight to capystore, not through the chat.";
        }
        paintAll();
        pump();
    }
    input.addEventListener("change", () => {
        if (input.files.length) addFiles(input.files);
        input.value = "";
    });
    drop.addEventListener("click", () => input.click());
    drop.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            input.click();
        }
    });
    drop.addEventListener("dragover", (e) => {
        e.preventDefault();
        drop.classList.add("over");
    });
    drop.addEventListener("dragleave", () => drop.classList.remove("over"));
    drop.addEventListener("drop", (e) => {
        e.preventDefault();
        drop.classList.remove("over");
        if (e.dataTransfer && e.dataTransfer.files.length) addFiles(e.dataTransfer.files);
    });
    paintAll();
    return w;
};
