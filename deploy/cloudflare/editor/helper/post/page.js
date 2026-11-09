// Draws one post frame card (APP-API-CONTRACT.md section 52.5) for render.js: window.pf.draw(cfg) lays the card out and
// answers its size and the video box's position in CSS pixels. The cards are original drawings in each site's layout:
// no site logos or artwork. Every text from the post goes in through textContent, never as HTML.

const AV_COLORS = ["#e9457a", "#d97706", "#7c3aed", "#059669", "#2563eb", "#db2777", "#0891b2", "#65a30d"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** @param {string} tag @param {Record<string, any> | null} [attrs] @param {...any} kids */
function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs ?? {})) {
        if (v === null || v === undefined || v === false) continue;
        if (k === "class") el.className = v;
        else if (k === "style") el.setAttribute("style", v);
        else el.setAttribute(k, v);
    }
    for (const kid of kids.flat()) {
        if (kid === null || kid === undefined || kid === false || kid === "") continue;
        el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
}

/** An icon from a fixed list (drawn here, generic shapes). @param {string} name @param {number} [size] */
function icon(name, size = 16) {
    const paths = {
        reply: '<path d="M4 5h16v11H9l-5 4z"/>',
        repost: '<path d="M7 4 4 7l3 3M4 7h12a4 4 0 0 1 4 4v1M17 20l3-3-3-3M20 17H8a4 4 0 0 1-4-4v-1"/>',
        heart: '<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>',
        bars: '<path d="M5 20v-6M10 20V8M15 20v-9M20 20V4"/>',
        send: '<path d="M21 3 3 10l7 3 3 7z"/>',
        mark: '<path d="M6 3h12v18l-6-5-6 5z"/>',
        thumb: '<path d="M7 10v10H4V10zM7 10l4-7a2 2 0 0 1 3 2l-1 4h6a2 2 0 0 1 2 2l-2 7a2 2 0 0 1-2 2H7"/>',
    };
    if (name === "dots") {
        const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        s.setAttribute("width", String(size));
        s.setAttribute("height", String(size));
        s.setAttribute("viewBox", "0 0 24 24");
        s.setAttribute("fill", "currentColor");
        s.innerHTML = '<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>';
        return s;
    }
    if (name === "tick") {
        const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        s.setAttribute("width", "15");
        s.setAttribute("height", "15");
        s.setAttribute("viewBox", "0 0 24 24");
        s.innerHTML = '<circle cx="12" cy="12" r="10" fill="#4a8cff"/><path d="m7.5 12.3 3 3 6-6.3" fill="none" stroke="#fff" stroke-width="2.2"/>';
        return s;
    }
    const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    s.setAttribute("width", String(size));
    s.setAttribute("height", String(size));
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("fill", "none");
    s.setAttribute("stroke", "currentColor");
    s.setAttribute("stroke-width", "1.8");
    s.innerHTML = paths[/** @type {keyof typeof paths} */ (name)] ?? "";
    return s;
}

/** 18000 -> "18K", 2300000 -> "2.3M". @param {unknown} n */
export function compact(n) {
    if (typeof n !== "number" || !Number.isFinite(n) || n < 0) return null;
    if (n < 1000) return String(Math.round(n));
    const units = [[1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (const [v, u] of units) {
        if (n >= v) {
            const x = n / v;
            const s = x >= 100 ? String(Math.round(x)) : x.toFixed(1).replace(/\.0$/, "");
            return s + u;
        }
    }
    return String(n);
}
/** 24118 -> "24,118". @param {unknown} n */
const full = (n) => (typeof n === "number" && Number.isFinite(n) && n >= 0 ? Math.round(n).toLocaleString("en-US") : null);
/** ms -> "Nov 8, 2026" (UTC; the card is a snapshot, so never "4h"). @param {unknown} ms @param {boolean} [long] */
export function dateText(ms, long = false) {
    if (typeof ms !== "number" || !Number.isFinite(ms)) return null;
    const d = new Date(ms);
    return `${(long ? MONTHS_LONG : MONTHS)[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}
/** seconds -> "0:12", "14:07", "1:02:03". @param {unknown} s */
function clock(s) {
    if (typeof s !== "number" || !Number.isFinite(s) || s <= 0) return null;
    const t = Math.round(s);
    const hh = Math.floor(t / 3600), mm = Math.floor((t % 3600) / 60), ss = t % 60;
    return hh > 0 ? `${hh}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}` : `${mm}:${String(ss).padStart(2, "0")}`;
}

/** @param {string | null | undefined} name @param {string | null} img @param {number} size @param {string} seed */
function avatar(name, img, size, seed) {
    let hsh = 0;
    for (const ch of seed || "?") hsh = (hsh * 31 + ch.codePointAt(0)) >>> 0;
    const el = h("div", { class: "av", style: `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.42)}px;background:${AV_COLORS[hsh % AV_COLORS.length]}` });
    if (img) el.append(h("img", { src: img, alt: "" }));
    else el.append([...(String(name ?? "").replace(/^@/, "").trim() || "?")][0].toUpperCase());
    return el;
}

/** The video's box: `aspect` is height / width. @param {number} width @param {number} aspect @param {string | null} dur */
function slot(width, aspect, dur, extra = []) {
    return h("div", { class: "slot", style: `width:${width}px;height:${Math.round(width * aspect)}px` }, ...extra, dur ? h("span", { class: "dur" }, dur) : null);
}

/**
 * @typedef {{name?: string|null, handle?: string|null, text?: string|null, title?: string|null, channel?: string|null,
 *   game?: string|null, clipper?: string|null, site_name?: string|null, posted_at?: number|null, verified?: boolean,
 *   counts?: Record<string, number>}} Details
 * @typedef {{style: string, theme: string, flat?: boolean, show?: Record<string, boolean>, d: Details, host?: string|null,
 *   avatar?: string|null, aspect: number, duration?: number|null}} Cfg
 */

/** @param {Cfg} c */
function build(c) {
    const show = { avatar: true, text: true, counts: true, time: true, ...(c.show ?? {}) };
    const d = c.d ?? {};
    const counts = d.counts ?? {};
    const dark = c.theme === "dark" ? " dark" : "";
    const flat = c.flat ? " flat" : "";
    const seed = d.handle || d.name || d.channel || c.host || "?";
    const dur = clock(c.duration);
    const when = show.time ? dateText(d.posted_at) : null;

    if (c.style === "x") {
        const name = d.name || d.handle?.replace(/^@/, "") || "post";
        const handle = d.handle ? (d.handle.startsWith("@") ? d.handle : `@${d.handle}`) : null;
        const meta = [handle, when].filter(Boolean).join(" · ");
        const row = show.counts
            ? h("div", { class: "icons" },
                  h("span", null, icon("reply"), compact(counts.replies) ?? ""),
                  h("span", null, icon("repost"), compact(counts.reposts) ?? ""),
                  h("span", null, icon("heart"), compact(counts.likes) ?? ""),
                  h("span", null, icon("bars"), compact(counts.views) ?? ""))
            : null;
        const inner = show.avatar ? 360 - 28 - 50 : 360 - 28;
        return h("div", { class: `pf x${dark}${flat}` },
            h("div", { class: "hd" },
                show.avatar ? avatar(name, c.avatar ?? null, 40, seed) : null,
                h("div", { style: "flex:1;min-width:0" },
                    h("div", { class: "line" }, h("span", { class: "nm" }, name), d.verified ? icon("tick") : null, meta ? h("span", { class: "muted" }, meta) : null, h("span", { style: "flex:1" }), h("span", { class: "muted" }, icon("dots", 18))),
                    show.text && d.text ? h("div", { class: "txt" }, d.text) : h("div", { style: "height:8px" }),
                    slot(inner, c.aspect, dur),
                    row)));
    }
    if (c.style === "instagram") {
        const user = d.handle?.replace(/^@/, "") || d.name || "post";
        return h("div", { class: `pf ig${dark}${flat}` },
            h("div", { class: "hd" },
                show.avatar ? h("div", { class: "ring" }, avatar(user, c.avatar ?? null, 32, seed)) : null,
                h("b", { style: "font-size:13.5px" }, user), d.verified ? icon("tick") : null,
                h("span", { style: "flex:1" }), icon("dots", 18)),
            slot(360, c.aspect, null),
            h("div", { class: "bar" }, icon("heart", 22), icon("reply", 22), icon("send", 22), h("span", { class: "sp" }), icon("mark", 22)),
            h("div", { class: "body" },
                show.counts && full(counts.likes) ? h("div", null, h("b", null, `${full(counts.likes)} likes`)) : null,
                show.text && d.text ? h("div", { class: "txt" }, h("b", null, user), " ", d.text) : null,
                show.counts && full(counts.comments) ? h("div", { class: "muted" }, `view all ${full(counts.comments)} comments`) : null,
                when ? h("div", { class: "muted", style: "font-size:11.5px" }, dateText(d.posted_at, true)) : null));
    }
    if (c.style === "twitch") {
        const ch = d.name || d.channel || d.handle?.replace(/^@/, "") || "channel";
        const line = [d.clipper ? `clipped by ${d.clipper}` : null, show.counts && full(counts.views) ? `${full(counts.views)} views` : null, when].filter(Boolean).join(" · ");
        return h("div", { class: `pf tw${dark}${flat}` },
            slot(420, c.aspect, dur, [d.clipper ? h("span", { class: "clip" }, "CLIP") : null]),
            h("div", { class: "info" },
                show.avatar ? h("div", { class: "ring" }, avatar(ch, c.avatar ?? null, 44, seed)) : null,
                h("div", { style: "min-width:0;display:grid;gap:3px" },
                    show.text && d.title ? h("div", { class: "ttl" }, d.title) : null,
                    h("div", { class: "ch" }, ch),
                    d.game ? h("div", { class: "muted", style: "font-size:13px" }, d.game) : null,
                    line ? h("div", { class: "muted", style: "font-size:12.5px" }, line) : null)));
    }
    if (c.style === "youtube") {
        const ch = d.channel || d.name || d.handle || "channel";
        const top = [show.counts && compact(counts.views) ? `${compact(counts.views)} views` : null, when].filter(Boolean).join("  ");
        const desc = show.text && d.text ? d.text.split("\n").slice(0, 3).join("\n").slice(0, 220) : null;
        return h("div", { class: `pf yt${dark}${flat}` },
            slot(420, c.aspect, dur),
            show.text && d.title ? h("div", { class: "ttl" }, d.title) : h("div", { style: "height:10px" }),
            h("div", { class: "chrow" },
                show.avatar ? avatar(ch, c.avatar ?? null, 36, seed) : null,
                h("div", { style: "line-height:1.25;min-width:0" }, h("b", { style: "font-size:14px" }, ch), show.counts && compact(counts.subscribers) ? [h("br"), h("span", { class: "muted", style: "font-size:12px" }, `${compact(counts.subscribers)} subscribers`)] : null),
                h("span", { class: "sub" }, "Subscribe"), h("span", { class: "sp" }),
                show.counts && compact(counts.likes) ? h("span", { class: "pillb" }, icon("thumb"), compact(counts.likes)) : null),
            top || desc ? h("div", { class: "desc" }, top ? h("b", null, top) : null, top && desc ? h("br") : null, desc ? h("span", { class: "txt" }, desc) : null) : null);
    }
    // generic
    const site = d.site_name || c.host || "link";
    const who = d.name || d.channel || d.handle || null;
    return h("div", { class: `pf gen${dark}${flat}` },
        h("div", { class: "site" }, h("span", { class: "fav" }, [...site][0].toUpperCase()), site),
        who || when ? h("div", { class: "hd" },
            show.avatar && who ? avatar(who, c.avatar ?? null, 32, seed) : null,
            h("div", { style: "line-height:1.25" }, who ? h("b", { style: "font-size:13.5px" }, who) : null, who && when ? h("br") : null, when ? h("span", { class: "muted", style: "font-size:12px" }, when) : null)) : null,
        show.text && d.title ? h("div", { style: "font-weight:600;margin-bottom:3px" }, d.title) : null,
        show.text && d.text ? h("div", { class: "muted txt", style: "font-size:13px;margin-bottom:10px" }, d.text.slice(0, 400)) : null,
        slot(336, c.aspect, dur),
        h("div", { class: "foot" }, h("span", null, c.host ?? ""), h("span", null, "saved with capystore")));
}

/** Rounded-rectangle hole in the card's colour layer. @param {number} w @param {number} h @param {{x:number,y:number,w:number,h:number,r:number}} b */
function holeMask(w, h, b) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><path fill-rule="evenodd" fill="#fff" d="M0 0H${w}V${h}H0Z ` +
        `M${b.x + b.r} ${b.y}H${b.x + b.w - b.r}A${b.r} ${b.r} 0 0 1 ${b.x + b.w} ${b.y + b.r}V${b.y + b.h - b.r}A${b.r} ${b.r} 0 0 1 ${b.x + b.w - b.r} ${b.y + b.h}` +
        `H${b.x + b.r}A${b.r} ${b.r} 0 0 1 ${b.x} ${b.y + b.h - b.r}V${b.y + b.r}A${b.r} ${b.r} 0 0 1 ${b.x + b.r} ${b.y}Z"/></svg>`;
    return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
}

/** @param {Cfg} cfg */
async function draw(cfg) {
    const root = /** @type {HTMLElement} */ (document.getElementById("card"));
    root.replaceChildren();
    const card = build(cfg);
    const bgl = h("div", { class: "bgl" });
    card.prepend(bgl);
    root.append(card);
    await Promise.all([...card.querySelectorAll("img")].map((i) => i.decode().catch(() => i.remove())));
    await document.fonts.ready;
    const cr = card.getBoundingClientRect();
    const s = /** @type {HTMLElement} */ (card.querySelector(".slot"));
    const sr = s.getBoundingClientRect();
    const radius = parseFloat(getComputedStyle(s).borderTopLeftRadius) || 0;
    const box = { x: sr.left - cr.left, y: sr.top - cr.top, w: sr.width, h: sr.height, r: Math.min(radius, sr.width / 2, sr.height / 2) };
    const mask = holeMask(cr.width, cr.height, box);
    bgl.style.webkitMaskImage = mask;
    bgl.style.maskImage = mask;
    bgl.style.webkitMaskSize = "100% 100%";
    return { width: cr.width, height: cr.height, box: { x: box.x, y: box.y, w: box.w, h: box.h }, radius: box.r };
}

// @ts-ignore
window.pf = { draw };
// @ts-ignore
window.pfReady = true;
