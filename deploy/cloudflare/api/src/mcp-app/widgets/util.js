// Shared helpers. Every value that came from the library goes in through textContent or a checked URL: titles and
// names are untrusted.
const APP_URL = "https://cobalt.capybaraharmony.com/library";
const S = { data: null, stack: [], err: null, busy: false, cleanups: [], defView: document.body.dataset.defaultView || "search" };
const VIEWS = {};

function add(el, c) {
    if (c == null || c === false) return;
    if (Array.isArray(c)) c.forEach((x) => add(el, x));
    else el.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
}
const PROPS = { value: 1, checked: 1, disabled: 1, hidden: 1, readOnly: 1, type: 1, multiple: 1 };
function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    if (props) {
        for (const k in props) {
            const v = props[k];
            if (v == null || v === false) continue;
            if (k === "class") el.className = v;
            else if (k === "text") el.textContent = v;
            else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
            else if (k in PROPS) el[k] = v;
            else el.setAttribute(k, v === true ? "" : v);
        }
    }
    kids.forEach((c) => add(el, c));
    return el;
}
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many || one + "s"}`;
const num = (n) => typeof n === "number" && isFinite(n);

// picture URLs: http(s) or an inline image only
const safeUrl = (u) => typeof u === "string" && /^(https?:\/\/|data:image\/)/i.test(u);
const webUrl = (u) => typeof u === "string" && /^https?:\/\//i.test(u);

const PAL = [["#f7a1c4", "#b3477d"], ["#ffc3dd", "#d65e98"], ["#c9b8ff", "#e2589a"], ["#ffb199", "#c94b7c"], ["#ffd2e6", "#e2589a"], ["#ffe3b3", "#e36f8f"], ["#9ccc65", "#33691e"], ["#90caf9", "#3b6fd8"]];
function grad(seed) {
    let n = 0;
    const s = String(seed == null ? "" : seed);
    for (let i = 0; i < s.length; i++) n = (n * 31 + s.charCodeAt(i)) >>> 0;
    const p = PAL[n % PAL.length];
    return `linear-gradient(135deg,${p[0]},${p[1]})`;
}
// a square-ish picture box: the picture when there is a loadable URL, a gradient otherwise
function pic(url, seed, cls) {
    const d = h("div", { class: "pic " + (cls || "") });
    d.style.background = grad(seed);
    if (safeUrl(url)) {
        const im = h("img", { src: url, alt: "", loading: "lazy", decoding: "async" });
        im.addEventListener("error", () => im.remove());
        d.appendChild(im);
    }
    return d;
}

function dur(s, dec) {
    if (!num(s)) return "";
    s = Math.max(0, s);
    const t = dec ? Math.floor(s * 10) / 10 : Math.floor(s);
    const hrs = Math.floor(t / 3600);
    const m = Math.floor((t % 3600) / 60);
    let sec = t % 60;
    const ss = dec ? sec.toFixed(1).padStart(4, "0") : String(Math.floor(sec)).padStart(2, "0");
    return hrs ? `${hrs}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}
function fmtDate(iso, long) {
    const d = new Date(iso);
    if (isNaN(d)) return "";
    const c = bridge.ctx();
    const loc = c.locale || undefined;
    const tz = c.timeZone ? { timeZone: c.timeZone } : {};
    try {
        if (!loc || /^en\b/i.test(loc)) {
            // "6 Nov" and "6 Nov, 2:14 pm", the way the app words it
            const day = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", ...tz }).format(d);
            if (!long) return day;
            return day + ", " + new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", ...tz }).format(d).toLowerCase();
        }
        return d.toLocaleString(loc, long ? { day: "numeric", month: "short", hour: "numeric", minute: "2-digit", ...tz } : { day: "numeric", month: "short", ...tz });
    } catch {
        return d.toDateString();
    }
}
function fmtBytes(n) {
    if (!num(n)) return "";
    if (n < 1000) return n + " B";
    if (n < 1e6) return Math.round(n / 1000) + " KB";
    return (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + " MB";
}
const urlLabel = (u) => String(u).replace(/^https?:\/\//i, "");

// a link that opens through the host (fallback: a plain new-tab anchor)
function ext(url, text, cls) {
    const a = h("a", { class: cls == null ? "ext" : cls, href: webUrl(url) ? url : null, target: "_blank", rel: "noopener noreferrer", text: text == null ? urlLabel(url) : text });
    a.addEventListener("click", (e) => {
        e.preventDefault();
        if (webUrl(url)) bridge.openLink(url);
    });
    return a;
}

// copy: the clipboard from the click; when refused, the text in a selected field to copy by hand
function copyBtn(text, label, name) {
    const b = h("button", { class: "btn", type: "button", "aria-label": name || "copy link", text: label || "copy" });
    b.addEventListener("click", async () => {
        const t = typeof text === "function" ? text() : text;
        const old = document.querySelector(".cpfall");
        if (old) old.remove();
        try {
            // a sandbox without clipboard-write would only log a policy error: go straight to the visible fallback
            const fp = document.featurePolicy;
            if (fp && fp.allowsFeature && !fp.allowsFeature("clipboard-write")) throw new Error("clipboard blocked");
            await navigator.clipboard.writeText(t);
            flash(b, label || "copy");
        } catch {
            const inp = h("textarea", { readOnly: true, value: t, rows: Math.min(4, t.split("\n").length), "aria-label": "text to copy" });
            const note = h("small", { text: "select and copy:" });
            const box = h("div", { class: "cpfall" }, note, inp);
            const anchor = b.closest(".lk,.linkrow,.col,.whead,.job") || b.parentNode;
            anchor.insertAdjacentElement("afterend", box);
            inp.focus();
            inp.select();
            try {
                if (document.execCommand("copy")) {
                    note.textContent = "copied";
                    flash(b, label || "copy");
                }
            } catch {}
        }
    });
    return b;
}
function flash(b, back) {
    b.textContent = "copied";
    setTimeout(() => {
        b.textContent = back;
    }, 1600);
}

// pointer drag: fn(event) on press and on every move until release
function drag(el, fn) {
    el.addEventListener("pointerdown", (e) => {
        if (e.button) return;
        e.preventDefault();
        try {
            el.setPointerCapture(e.pointerId);
        } catch {}
        fn(e);
        const mv = (ev) => fn(ev);
        const up = () => {
            el.removeEventListener("pointermove", mv);
            el.removeEventListener("pointerup", up);
            el.removeEventListener("pointercancel", up);
        };
        el.addEventListener("pointermove", mv);
        el.addEventListener("pointerup", up);
        el.addEventListener("pointercancel", up);
    });
}

// the view's header; a back arrow when the widget was reached from another view
function head(title, right, extra) {
    const hl = h("div", { class: "hl" });
    if (S.stack.length) hl.appendChild(h("button", { class: "btn back", type: "button", "aria-label": "back", text: "←", onclick: back }));
    hl.appendChild(typeof title === "string" ? h("b", { text: title }) : title);
    if (extra) hl.appendChild(extra);
    return h("div", { class: "whead" }, hl, right ? h("div", { class: "hr" }, right) : null);
}
const onCleanup = (fn) => S.cleanups.push(fn);

// polls job_status: waits for each answer, backs off to every 3 s, gives up (with a note) after 5 minutes. An answer can
// carry a NEW job id (a file that was still opening starts its render under another id): the next call uses the newest,
// because asking again with the old one could start the work a second time.
function poll(job, onUpdate) {
    let cur = job;
    let stopped = false;
    let t0 = Date.now();
    let n = 0;
    let fails = 0;
    let timer = 0;
    async function tick() {
        if (stopped) return;
        const r = await rpc("job_status", { job: cur });
        if (stopped) return;
        if (r.error) {
            if (++fails >= 3) return onUpdate({ stalled: true, error: r.error });
        } else {
            fails = 0;
            if (r.sc && typeof r.sc.job === "string" && r.sc.job) cur = r.sc.job;
            onUpdate(r.sc || {});
            if (r.sc && r.sc.state && r.sc.state !== "running") return;
        }
        if (Date.now() - t0 > 300000) return onUpdate({ stalled: true });
        timer = setTimeout(tick, Math.min(3000, 1000 + 500 * n++));
    }
    timer = setTimeout(tick, 800);
    const stop = () => {
        stopped = true;
        clearTimeout(timer);
    };
    stop.restart = () => {
        stopped = false;
        t0 = Date.now();
        n = 0;
        fails = 0;
        tick();
    };
    onCleanup(stop);
    return stop;
}
