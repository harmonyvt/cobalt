// Draws a chat at any moment t of its script (plan.js). render.js calls cv.init(cfg) once, then cv.seek(t) for every
// frame in order and screenshots the page. Deterministic: the only clock is t (the camera eases from frame to frame, so
// frames must be sought in order, which render.js does).
import { words } from "./plan.js";

const $ = (s, r = document) => r.querySelector(s);
const h = (tag, cls, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
};
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const easeOut = (p) => 1 - Math.pow(1 - p, 3);
// a soft overshoot for things that pop in
const pop = (p) => (p >= 1 ? 1 : 1 + 2.2 * Math.pow(p - 1, 3) + 1.2 * Math.pow(p - 1, 2));

const ICON = {
    search: ["#2f8af9", "⌕"], look: ["#a78bfa", "◉"], emotes: ["#30bd1b", "☺"], edit: ["#f5ad5b", "▤"], job: ["#ff8fc8", "◆"],
    box: ["#9effe4", "$"], files: ["#c9c9d1", "⇅"], link: ["#2f8af9", "↗"], collection: ["#f5c16c", "▦"], saved: ["#30bd1b", "✓"],
    facts: ["#c9c9d1", "≡"],
};
const chipColor = (op) => {
    const a = op.split(".")[0];
    return { library: "#2f8af9", links: "#2f8af9", look: "#a78bfa", emotes: "#30bd1b", edits: "#f5ad5b", make: "#ff8fc8", jobs: "#ff8fc8", box: "#9effe4", collections: "#f5c16c", sets: "#f5c16c", agents: "#a78bfa" }[a] ?? "#8f8f8f";
};

let S; // { cfg, els: Map<el, {node, beat}>, cam, lastT }

/** Text as word spans (markdown kept small: **bold**, `code`, bare links). */
function textNode(text) {
    const box = h("div", "text");
    let bold = false;
    let code = false;
    for (const w of words(text)) {
        const span = h("span", "w");
        // open what an earlier word left open; the span closes it again
        let s = (bold ? "<b>" : "") + (code ? "<code>" : "");
        s += esc(w)
            .replace(/\*\*/g, () => ((bold = !bold) ? "<b>" : "</b>"))
            .replace(/`/g, () => ((code = !code) ? "<code>" : "</code>"));
        if (/^(https?:\/\/|([a-z0-9-]+\.)+[a-z]{2,}\/)\S+/i.test(w)) s = `<span class="url">${s}</span>`;
        span.innerHTML = s;
        box.append(span);
    }
    return box;
}

function thumb(postId, extra = "") {
    const src = S.cfg.media[postId]?.poster;
    const t = h("div", "th " + extra);
    if (src) t.style.backgroundImage = `url("${src}")`;
    return t;
}

function card(c) {
    const [color, glyph] = ICON[c.type] ?? ICON.facts;
    const el = h("div", "card");
    const head = (t, s) => {
        const d = h("div", "ch", `<div class="ic" style="background:${color}">${glyph}</div><span class="t">${esc(t)}</span><span class="s">${esc(s ?? "")}</span>`);
        el.append(d);
    };
    switch (c.type) {
        case "search": {
            head("searched", `"${c.query}"${c.within ? " in " + c.within : ""} · ${c.total}`);
            const row = h("div", "thumbs");
            (c.hits ?? []).slice(0, 6).forEach((x, i) => {
                const t = thumb(x.post_id, i === 0 ? "hit" : "");
                if (x.score != null) t.append(Object.assign(h("div", "bar"), { style: `width:${Math.round(x.score * 100)}%` }));
                if (x.score != null) t.append(h("small", "", x.score.toFixed(2)));
                row.append(t);
            });
            el.append(row);
            break;
        }
        case "look": {
            head("looked at", `${(c.post_ids ?? []).length} posts`);
            const row = h("div", "thumbs");
            (c.post_ids ?? []).slice(0, 6).forEach((id) => row.append(thumb(id)));
            el.append(row);
            break;
        }
        case "link": {
            head(c.private ? "private link" : "share link", `${c.files ?? 1} file${c.files === 1 ? "" : "s"}`);
            const row = h("div", "link");
            const post = Object.values(S.cfg.snap.posts ?? {}).find((p) => (p.files ?? []).some((f) => c.id && String(f.share_url ?? "").endsWith("/" + c.id)));
            row.append(post ? thumb(post.id) : thumb(""));
            row.append(h("div", "", `<div class="lt">${esc(c.title ?? "")}</div><div class="url2">${esc(String(c.url).replace(/^https:\/\//, ""))}</div>`));
            el.append(row);
            break;
        }
        case "job": {
            head(c.op, c.status);
            const p = c.status === "done" ? 1 : c.progress ?? 0;
            el.append(h("div", "prog", `<div style="width:${Math.round(p * 100)}%"></div>`));
            if (c.post_id) el.append(h("div", "thumbs")).append(thumb(c.post_id));
            break;
        }
        case "emotes": {
            head(c.saved ? "saved emote" : "7tv emotes", c.query ?? c.sort ?? "");
            const g = h("div", "emotes");
            (c.emotes ?? []).slice(0, 12).forEach((e) => {
                const d = h("div", "emo");
                if (S.cfg.media["emote:" + e.id]?.poster) d.style.backgroundImage = `url("${S.cfg.media["emote:" + e.id].poster}")`;
                g.append(d);
            });
            el.append(g);
            break;
        }
        case "box": {
            head("ran in the box", c.code === 0 ? "exit 0" : `exit ${c.code}`);
            el.append(h("div", "term", `<span class="p">$</span> ${esc(c.cmd)}\n${esc(String(c.stdout ?? "").slice(-400))}`));
            break;
        }
        case "edit": {
            head(`edit ${c.change}`, `${c.title ?? ""} · ${Math.round(c.duration)} s`);
            const row = h("div", "thumbs");
            for (const tr of c.tracks ?? []) for (const cl of tr.clips.slice(0, 6)) if (cl.post_id) row.append(thumb(cl.post_id, cl.is_new ? "hit" : ""));
            el.append(row);
            break;
        }
        case "collection":
            head(c.of === "set" ? "set " + c.change : "collection " + c.change, `${c.name} · ${c.count}`);
            break;
        case "saved":
            head("saved", c.title ?? "");
            if (c.post_ids?.length) {
                const row = h("div", "thumbs");
                c.post_ids.slice(0, 6).forEach((id) => row.append(thumb(id)));
                el.append(row);
            }
            break;
        default: {
            head(c.title ?? c.type, "");
            if (c.rows?.length) el.append(h("div", "rows", c.rows.map(([a, b]) => `<span>${esc(a)}</span><span>${esc(b)}</span>`).join("")));
        }
    }
    return el;
}

function mediaNode(postId, maxW, n = 1) {
    const post = S.cfg.snap.posts[postId];
    const f = (post.files ?? []).find((x) => x.width && x.height) ?? { width: 3, height: 4 };
    const ar = f.width / f.height;
    const colW = Math.min(S.cfg.w, 620) - 32;
    const gap = 8;
    let w = n > 1 ? (Math.min(colW, maxW * colW * 1.5) - gap * (n - 1)) / n : Math.min(maxW * colW, ar >= 1 ? colW : 300);
    let hh = w / ar;
    const maxH = S.cfg.h * (n > 1 ? 0.36 : 0.5);
    if (hh > maxH) {
        hh = maxH;
        w = hh * ar;
    }
    const box = h("div", "media");
    box.style.width = `${Math.round(w)}px`;
    box.style.height = `${Math.round(hh)}px`;
    const img = h("img");
    const src = S.cfg.media[postId]?.poster;
    if (src) img.src = src;
    box.append(img);
    return box;
}

function build() {
    const { snap, script } = S.cfg;
    $("#title").textContent = snap.thread?.title ?? "chat";
    const col = $("#col");
    const byEl = new Map(script.beats.map((b) => [b.el, b]));
    const reg = (name, node) => {
        const beat = byEl.get(name);
        if (beat) S.els.set(name, { node, beat });
        return node;
    };
    const keep = new Set(script.messages);
    for (const m of snap.messages) {
        if (!keep.has(m.id)) continue;
        if (m.role === "user") {
            const node = reg(`m${m.id}`, h("div", "msg user"));
            node.append(h("div", "bubble", esc(m.text)));
            (m.post_ids ?? []).forEach((id, i) => {
                if (byEl.has(`m${m.id}.post${i}`)) node.append(reg(`m${m.id}.post${i}`, mediaNode(id, 0.5)));
            });
            col.append(node);
            const tb = byEl.get(`m${m.id}.type`);
            if (tb) S.typing.push(tb);
            continue;
        }
        const think = reg(`m${m.id}.think`, h("div", "msg"));
        think.append(h("div", "who", "<i></i>capystore"), h("div", "think", "<span></span><span></span><span></span>"));
        col.append(think);
        const node = reg(`m${m.id}`, h("div", "msg"));
        node.append(h("div", "who", "<i></i>capystore"));
        const reply = h("div", "reply");
        node.append(reply);
        (m.steps ?? []).forEach((s, si) => {
            const step = reg(`m${m.id}.s${si}`, h("div", "step"));
            const n = (s.calls ?? []).length;
            step.append(h("div", "sh", `<span class="d"></span><span class="g">ran code · ${n} tool${n === 1 ? "" : "s"}</span><span>${s.duration_ms != null ? (s.duration_ms / 1000).toFixed(1) + " s" : ""}</span>`));
            const trail = h("div", "trail");
            const cards = h("div", "cards");
            (s.calls ?? []).forEach((c, ci) => {
                trail.append(reg(`m${m.id}.s${si}.c${ci}`, h("span", "chip" + (c.status === "error" ? " err" : ""), `<i style="background:${chipColor(c.op)}"></i>${esc(c.op)} <span class="ms">${c.ms} ms</span>`)));
                if (c.card && byEl.has(`m${m.id}.s${si}.card${ci}`)) cards.append(reg(`m${m.id}.s${si}.card${ci}`, card(c.card)));
            });
            step.append(trail);
            if (cards.childElementCount) step.append(cards);
            reply.append(step);
        });
        if (byEl.has(`m${m.id}.text`)) reply.append(reg(`m${m.id}.text`, textNode(m.text)));
        const shown = (m.post_ids ?? []).filter((id, i) => byEl.has(`m${m.id}.post${i}`));
        if (shown.length) {
            const row = h("div", "mrow");
            shown.forEach((id, i) => row.append(reg(`m${m.id}.post${i}`, mediaNode(id, 0.62, shown.length))));
            reply.append(row);
        }
        col.append(node);
    }
}

async function seek(t) {
    const { cfg } = S;
    const decodes = [];
    for (const [name, { node, beat }] of S.els) {
        const on = t >= beat.at && (beat.until == null || name.endsWith(".text") || t < beat.until);
        node.style.display = on ? "" : "none";
        if (!on) continue;
        const p = clamp((t - beat.at) / 0.32);
        if (name.endsWith(".think")) {
            node.querySelectorAll(".think span").forEach((d, i) => (d.style.opacity = String(0.3 + 0.7 * Math.max(0, Math.sin((t - beat.at) * 7 - i * 0.9)))));
        }
        if (name.endsWith(".text")) {
            const n = beat.words;
            const shown = Math.ceil(clamp((t - beat.at) / Math.max(0.01, beat.until - beat.at)) * n);
            [...node.children].forEach((w, i) => {
                w.style.display = i < shown ? "" : "none";
                w.style.opacity = i === shown - 1 ? String(clamp(((t - beat.at) / (beat.until - beat.at)) * n - (shown - 1))) : "";
            });
            continue;
        }
        const s = pop(p);
        node.style.opacity = String(easeOut(p));
        node.style.transform = p >= 1 ? "" : `translateY(${(1 - easeOut(p)) * 14}px) scale(${0.94 + 0.06 * s})`;
        if (beat.play) {
            const img = node.querySelector("img");
            const fr = cfg.media[beat.post]?.frames;
            let pb = node.querySelector(".pb");
            if (!pb) {
                pb = h("div", "pb", "<div></div>");
                node.append(pb, h("div", "tag", '<span class="snd"></span>playing'));
            }
            const k = (t - beat.play.at) * fr.fps;
            const prog = clamp((t - beat.play.at) / beat.play.length);
            pb.firstChild.style.width = `${prog * 100}%`;
            node.querySelector(".tag").style.display = prog > 0 && prog < 1 ? "" : "none";
            if (k >= 0) {
                const i = Math.min(fr.count - 1, Math.floor(k));
                const src = fr.pattern.replace("%05d", String(i + 1).padStart(5, "0"));
                if (img.getAttribute("src") !== src) {
                    img.src = src;
                    decodes.push(img.decode().catch(() => {}));
                }
            }
        }
    }
    // composer
    const typing = S.typing.find((b) => t >= b.at && t < b.until + 0.05);
    const field = $("#field");
    if (typing) {
        const n = Math.round(clamp((t - typing.at) / Math.max(0.01, typing.until - typing.at - 0.25)) * typing.text.length);
        $("#typed").textContent = typing.text.slice(0, n);
        $("#ph").style.display = "none";
        field.classList.toggle("long", $("#typed").offsetWidth > field.clientWidth - 40);
        $("#send").classList.toggle("on", n > 0);
    } else {
        $("#typed").textContent = "";
        $("#ph").style.display = "";
        field.classList.remove("long");
        $("#send").classList.remove("on");
    }
    $("#caret").style.opacity = typing ? (Math.floor(t * 2.5) % 2 ? "0.2" : "1") : "0";
    // camera: keep the newest thing in view, eased
    await Promise.all(decodes);
    const col = $("#col");
    const view = $("#view");
    const target = Math.max(0, col.offsetHeight - view.clientHeight);
    const dt = S.lastT == null ? 1 : Math.max(0, t - S.lastT);
    S.cam += (target - S.cam) * (1 - Math.exp(-dt / 0.14));
    if (target < S.cam) S.cam = target;
    S.lastT = t;
    col.style.transform = `translateY(${-S.cam.toFixed(2)}px)`;
}

window.cv = {
    async init(cfg) {
        S = { cfg, els: new Map(), cam: 0, lastT: null, typing: [] };
        document.documentElement.style.setProperty("--w", cfg.w + "px");
        document.documentElement.style.setProperty("--h", cfg.h + "px");
        if (cfg.theme === "light") document.body.classList.add("light");
        build();
        await document.fonts.ready;
        await Promise.all([...document.images].map((i) => i.decode().catch(() => {})));
        return true;
    },
    seek,
};
window.cvReady = true;
