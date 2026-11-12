// box_run, box_pull and box_save drawn as a terminal (MCP-APP-CONTRACT.md section 5.1). They are registry ops; their
// result gets this view through src/mcp-app/follow.ts. Output is untrusted: term.js splits and classifies it and every
// piece goes in through textContent. One tool result per widget (each result is its own frame), so there is no history
// of earlier runs here.
const TAIL = 8;
const BOX_TOOL = { run: "box_run", pull: "box_pull", save: "box_save" };

function termHead(tool, right) {
    return head(h("span", { class: "tt" }, ic("term", 13), h("b", { text: BOX_TOOL[tool] || "box" })), right);
}
const msText = (ms) => (!num(ms) ? "" : ms < 60000 ? (ms / 1000).toFixed(1) + " s" : dur(ms / 1000));
const fileKind = (t) => (/^(video|image|audio)\//.exec(t || "") || [, "file"])[1];
// which tool a call was from its arguments (an error or a call still running has no result to say it)
const toolOfArgs = (a) => (!a ? null : typeof a.cmd === "string" ? "run" : typeof a.path === "string" ? "save" : typeof a.id === "string" ? "pull" : null);

// "box awake · wiped in 1:42 if idle", counting down from the result's sleeps_at (the server's clock plus 2 minutes)
function boxStatus(d) {
    const at = Date.parse(d.sleeps_at || "");
    if (!isFinite(at)) return null;
    const dot = h("span", { class: "dot" });
    const lab = h("b");
    const left = h("span", { class: "wipe" });
    const note = h("span", { class: "note" });
    const tick = () => {
        const s = Math.ceil((at - Date.now()) / 1000);
        if (s <= 0) {
            dot.className = "dot off";
            lab.textContent = "box asleep";
            left.textContent = "";
            note.textContent = "files wiped, unless used since";
            return false;
        }
        lab.textContent = "box awake";
        left.textContent = `wiped in ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
        left.classList.toggle("low", s < 60);
        note.textContent = "if idle";
        return true;
    };
    if (tick()) {
        const t = setInterval(() => tick() || clearInterval(t), 1000);
        onCleanup(() => clearInterval(t));
    }
    return h("div", { class: "bstat" }, dot, lab, h("span", { class: "sp" }), left, note);
}

const runsInto = (el, runs) => runs.forEach((r) => el.appendChild(r.c ? h("span", { class: r.c, text: r.t }) : document.createTextNode(r.t)));

function cmdLine(cmd) {
    const tx = h("span", { class: "tx" });
    runsInto(tx, cmdRuns(cmd));
    const cp = copyBtn(cmd, "copy", "copy command");
    cp.classList.add("sm");
    return h("div", { class: "cmd" }, h("span", { class: "ps", text: "/workspace $" }), tx, cp);
}

function runView(d) {
    const timed = d.timed_out === true;
    const fail = !timed && d.code !== 0;
    const lines = ansiLines(d.stdout).map((l) => [l, 0]).concat(ansiLines(d.stderr).map((l) => [l, 1]));
    const w = h("div", null, termHead("run", num(d.ms) ? h("span", { class: "opt", text: msText(d.ms) }) : null), boxStatus(d));
    const term = h("div", { class: "term" }, cmdLine(d.cmd));
    if (!lines.length) term.appendChild(h("div", { class: "noout", text: "no output" }));
    else {
        const pre = h("pre", { class: "out" });
        lines.forEach(([runs, e]) => {
            const ln = h("span", { class: "ln" + (isCutLine(runs) ? " cutl" : e ? (fail ? " e hard" : " e") : "") });
            runsInto(ln, runs);
            pre.appendChild(ln);
        });
        const n = lines.length;
        if (n > TAIL) {
            // tail first: the end of the output is what matters; the host's full screen shows it all
            let open = false;
            const lab = h("span");
            const btn = h("button", { type: "button", onclick: () => ((open = !open), paint()) });
            const bar = h("div", { class: "tail" }, lab, btn);
            const paint = () => {
                const all = open || roomy();
                [...pre.children].forEach((x, i) => (x.hidden = !all && i < n - TAIL));
                lab.textContent = all ? `${n} lines` : `${n - TAIL} earlier lines hidden`;
                btn.textContent = open ? `show last ${TAIL}` : `show all ${n} lines`;
                btn.setAttribute("aria-expanded", String(open));
                bar.hidden = roomy();
            };
            CTX_HOOKS.push(paint);
            paint();
            term.appendChild(bar);
        }
        term.appendChild(pre);
    }
    const cut = [d.stdout_cut && "stdout", d.stderr_cut && "stderr"].filter(Boolean);
    const copyOut = lines.length ? copyBtn(() => [plainText(d.stdout), plainText(d.stderr)].filter(Boolean).join("\n"), "copy output", "copy output") : null;
    if (copyOut) copyOut.classList.add("sm");
    term.appendChild(
        h("div", { class: "tmeta" },
            timed ? h("span", { class: "pill warn", text: "timed out" }) : h("span", { class: "pill code" + (d.code ? " bad" : ""), text: `exit ${d.code}` }),
            d.code === 127 && !timed ? h("span", { class: "bad", text: "command not found" }) : null,
            num(d.ms) ? h("span", { text: msText(d.ms) }) : null,
            cut.length ? h("span", { class: "clip", text: `${cut.join(" and ")} cut to 8 KB` }) : null,
            h("span", { class: "sp" }),
            copyOut),
    );
    w.appendChild(term);
    return w;
}

function pullView(d) {
    const files = d.files || [];
    const w = h("div", null, termHead("pull", h("span", { text: plural(files.length, "file") })), boxStatus(d));
    w.appendChild(h("div", { class: "cwd", text: "/workspace · ls -lh" }));
    if (!files.length) {
        w.appendChild(h("div", { class: "empty", text: "nothing was copied in." }));
        return w;
    }
    const box = h("div", { class: "ls" });
    files.forEach((f) => {
        const m = /^(.*?)(\.[^.]*)?$/.exec(String(f.path || ""));
        const shape = [num(f.width) && num(f.height) ? `${f.width}×${f.height}` : "", num(f.seconds) ? dur(f.seconds) : ""].filter(Boolean).join(" · ");
        box.appendChild(h("div", { class: "lsr", title: [f.path, shape].filter(Boolean).join(" · ") },
            h("span", { class: "n" }, m[1], m[2] ? h("i", { text: m[2] }) : null),
            h("span", { class: "z", text: lsSize(f.bytes) }),
            h("span", { class: "k", text: fileKind(f.content_type) })));
    });
    const ml = limitList(box, 3);
    w.appendChild(box);
    w.appendChild(h("div", { class: "lsfoot" }, ml.btn));
    return w;
}

function saveView(d) {
    const p = d.post || null;
    const pub = p ? p.status === "public" : !!d.public_url;
    const th = p ? (safeUrl(p.thumb_url) ? p.thumb_url : signed(p.id, "thumb")) : null;
    const pc = pic(th, d.post_id);
    if (!pub) pc.appendChild(lockb("", false));
    const facts = [d.kind || (p && p.kind), fmtBytes(d.bytes), pub ? "public" : "private", d.processing ? "processing" : ""].filter(Boolean).join(" · ");
    const w = h("div", null, termHead("save", h("span", { class: "pill", text: "saved" })), boxStatus(d));
    w.appendChild(h("div", { class: "sv" }, pc,
        h("div", { class: "t" }, h("span", { class: "ok" }, ic("check", 11), "saved to library"), h("b", { text: (p && p.title) || "saved post" }), h("span", { text: facts })),
        h("button", { class: "btn", type: "button", text: "open", "aria-label": "open the saved post", onclick: () => go("show_post", { id: d.post_id }) })));
    return w;
}

// a failed call (the box off, its daily minutes used, a file it could not read): one red line, the command above it
function failView(d) {
    const w = h("div", null, termHead(d.tool, null));
    if (d.cmd) w.appendChild(h("div", { class: "term" }, cmdLine(d.cmd)));
    w.appendChild(h("div", { class: "wbody" }, h("div", { class: "err", role: "alert", style: "margin:0" }, h("span", { text: d.error }))));
    return w;
}

VIEWS.terminal = (d) => (d.error ? failView(d) : d.tool === "run" ? runView(d) : d.tool === "pull" ? pullView(d) : d.tool === "save" ? saveView(d) : h("div", { class: "empty", text: "done." }));
// the call's arguments arrive before its result: the command and a running line
VIEWS.terminal.wait = (a) => {
    const tool = toolOfArgs(a);
    const w = h("div", { "aria-busy": "true", "aria-label": "running" }, termHead(tool, null));
    const say = tool === "run" ? "running" : tool === "save" ? `saving ${a.path} to the library` : `copying ${a.id} into /workspace`;
    w.appendChild(h("div", { class: "term" }, tool === "run" ? cmdLine(a.cmd) : null, h("div", { class: "noout" }, say, h("span", { class: "cur" }))));
    return w;
};
// an error result: the message, and the command when the call had one
VIEWS.terminal.fail = (msg, a) => ({ view: "terminal", tool: toolOfArgs(a), error: msg, cmd: a && typeof a.cmd === "string" ? a.cmd : null });
