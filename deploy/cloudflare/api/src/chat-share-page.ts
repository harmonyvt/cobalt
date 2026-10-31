// The share host's shared chats (APP-API-CONTRACT.md section 46.3): share.../c/<key> is the page of one chat (its
// messages up to the point it was shared, its tool cards, its videos and pictures playable), share.../c/<key>/chat.json
// is the same chat as JSON (the transcript, chat-share.ts), and share.../c/<key>/<n>.<ext> (and <n>.poster.jpg) stream
// file <n> of the share with Range support. Anything that is not a live key is the same plain 404. Nothing is cached:
// a rotate or a stop takes effect at once. The page is plain HTML and CSS, no script. Free of Cloudflare imports.
import type { ToolCard } from "./chat-cards";
import { chatTranscript, fileIdsOf, noteShareOpened, shareByKey, type ChatTranscript, type SharedMessage, type SharedPost, type SharedStep } from "./chat-share";
import { notHiddenClause } from "./hidden-store";
import { escapeHtml as e, type ShareDeps } from "./share";
import { streamObject } from "./share-private";
import { extOf } from "./visibility";

const PAGE_PATH = /^\/c\/([A-Za-z0-9]{22})\/?$/;
const JSON_PATH = /^\/c\/([A-Za-z0-9]{22})\/chat\.json$/;
const FILE_PATH = /^\/c\/([A-Za-z0-9]{22})\/([1-9][0-9]{0,2})\.(poster\.jpg|[A-Za-z0-9]{1,8})$/;

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const NOT_FOUND = () =>
    new Response("not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
const TRY_AGAIN = () => new Response("try again\n", { status: 503, headers: { "content-type": "text/plain", "cache-control": "no-store", "retry-after": "5" } });

// 7TV emote pictures in the cards come from its CDN
const EMOTE_ORIGIN = "https://cdn.7tv.app";

// The headers of a chat page: files come from the media domain or the share host itself, emotes from 7TV.
const chatPageHeaders = (shareOrigin: string, mediaOrigin: string): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": `default-src 'none'; img-src ${shareOrigin} ${mediaOrigin} ${EMOTE_ORIGIN}; media-src ${shareOrigin} ${mediaOrigin}; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`,
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "x-robots-tag": "noindex",
});

// GET|HEAD /c/<key>, /c/<key>/chat.json and /c/<key>/<n>.<ext> (sharePage has answered other methods with a 405).
export async function chatShareRoute(d: ShareDeps, request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    try {
        const page = PAGE_PATH.exec(path);
        if (page) return await chatPage(d, request, page[1]!);
        const json = JSON_PATH.exec(path);
        if (json) return await chatJson(d, request, json[1]!);
        const file = FILE_PATH.exec(path);
        if (file) return await chatFile(d, request, file[1]!, Number(file[2]), file[3]!);
        return NOT_FOUND();
    } catch (err) {
        console.error("[chat-share] share host failed", String(err));
        return TRY_AGAIN();
    }
}

async function transcriptFor(d: ShareDeps, key: string): Promise<ChatTranscript | null> {
    const share = await shareByKey(d.db, key);
    if (!share) return null;
    return chatTranscript({ db: d.db, mediaBaseUrl: d.mediaBaseUrl, shareBaseUrl: d.shareBaseUrl, now: d.now ?? Date.now }, share);
}

async function chatPage(d: ShareDeps, request: Request, key: string): Promise<Response> {
    const t = await transcriptFor(d, key);
    if (!t) return NOT_FOUND();
    if (request.method === "GET") await noteShareOpened(d.db, key, (d.now ?? Date.now)());
    const html = chatPageHtml(t);
    return new Response(request.method === "HEAD" ? null : html, {
        headers: chatPageHeaders(new URL(withSlash(d.shareBaseUrl)).origin, new URL(withSlash(d.mediaBaseUrl)).origin),
    });
}

async function chatJson(d: ShareDeps, request: Request, key: string): Promise<Response> {
    const t = await transcriptFor(d, key);
    if (!t) return NOT_FOUND();
    return new Response(request.method === "HEAD" ? null : JSON.stringify(t), {
        headers: {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "access-control-allow-origin": "*",
            "x-content-type-options": "nosniff",
            "x-robots-tag": "noindex",
        },
    });
}

type FileRow = { id: string; bucket: string; r2_key: string; poster: string | null; content_type: string | null };

// File <n> of a live share: still not deleted, its post not hidden since, and the share shows media.
async function chatFile(d: ShareDeps, request: Request, key: string, n: number, ext: string): Promise<Response> {
    const share = await shareByKey(d.db, key);
    if (!share || share.media !== 1) return NOT_FOUND();
    const id = fileIdsOf(share)[n - 1];
    if (!id) return NOT_FOUND();
    const row = await d.db
        .prepare(`SELECT m.id, m.bucket, m.r2_key, m.poster, m.content_type FROM media_items m WHERE m.id = ?1 AND m.deleted_at IS NULL${await notHiddenClause(d.db)}`)
        .bind(id)
        .first<FileRow>();
    if (!row) return NOT_FOUND();
    if (ext === "poster.jpg") {
        const media = withSlash(d.mediaBaseUrl);
        if (!d.media || !row.poster || !row.poster.startsWith(media)) return NOT_FOUND();
        return streamObject(d.media, row.poster.slice(media.length), request, "image/jpeg");
    }
    if (ext.toLowerCase() !== extOf(row.r2_key)) return NOT_FOUND();
    const bucket = row.bucket === "media" ? d.media : d.originals;
    if (!bucket) return NOT_FOUND();
    const type = (row.content_type ?? "").split(";")[0]!.trim().toLowerCase() || "application/octet-stream";
    return streamObject(bucket, row.r2_key, request, type);
}

// ---- the page ------------------------------------------------------------------------------------------------------------

const fmtDuration = (s: number | null): string => {
    if (s === null || !Number.isFinite(s)) return "";
    const t = Math.max(0, Math.round(s));
    return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
};
const fmtDate = (ms: number) => new Date(ms).toLocaleDateString("en-AU", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const fmtMs = (ms: number | null) => (ms === null ? "" : ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`);
const fmtBytes = (b: number | null) => (b === null ? "" : b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB` : b >= 1e3 ? `${Math.round(b / 1e3)} kB` : `${b} B`);
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// A small, safe slice of Markdown: escaped first, then `code`, **bold**, *italic*, [links](https://...), bare links,
// "- " lists and paragraphs. Nothing else is ever HTML.
export function miniMarkdown(src: string): string {
    const inline = (s: string) => {
        let h = e(s);
        const codes: string[] = [];
        h = h.replace(/`([^`\n]+)`/g, (_, c: string) => `\u0000${codes.push(`<code>${c}</code>`) - 1}\u0000`);
        h = h.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, (_, t: string, u: string) => `<a href="${u}" rel="noopener nofollow">${t}</a>`);
        h = h.replace(/(^|[\s(])(https?:\/\/[^\s<)"]+)/g, (_, pre: string, u: string) => `${pre}<a href="${u}" rel="noopener nofollow">${u}</a>`);
        h = h.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>").replace(/(^|[\s(])\*([^*\n]+)\*/g, "$1<i>$2</i>");
        return h.replace(/\u0000(\d+)\u0000/g, (_, i: string) => codes[Number(i)]!);
    };
    const out: string[] = [];
    let list: string[] = [];
    let para: string[] = [];
    const flush = () => {
        if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
        if (list.length) out.push(`<ul>${list.map((l) => `<li>${inline(l)}</li>`).join("")}</ul>`);
        para = [];
        list = [];
    };
    for (const line of src.split(/\r?\n/)) {
        const li = /^\s*[-*•]\s+(.*)$/.exec(line);
        if (line.trim() === "") flush();
        else if (li) {
            if (para.length) {
                out.push(`<p>${para.map(inline).join("<br>")}</p>`);
                para = [];
            }
            list.push(li[1]!);
        } else {
            if (list.length) {
                out.push(`<ul>${list.map((l) => `<li>${inline(l)}</li>`).join("")}</ul>`);
                list = [];
            }
            para.push(line.replace(/^#{1,6}\s+/, ""));
        }
    }
    flush();
    return out.join("");
}

const thumb = (p: SharedPost | undefined, label?: string): string => {
    if (!p) return "";
    const f = p.file;
    const pic = f ? (f.type === "image" ? f.url : f.poster) : null;
    const badge = label ?? (p.duration ? fmtDuration(p.duration) : p.kind === "gallery" ? `${p.files}` : "");
    const inner = pic ? `<img src="${e(pic)}" alt="" loading="lazy">` : `<span class="nt">${e((p.title ?? "").slice(0, 40))}</span>`;
    const href = f ? `#post-${e(p.id)}` : null;
    const body = `${inner}${badge ? `<small>${e(badge)}</small>` : ""}`;
    return href ? `<a class="th" href="${href}" title="${e(p.title ?? "")}">${body}</a>` : `<span class="th" title="${e(p.title ?? "")}">${body}</span>`;
};
const thumbs = (ids: string[], posts: Record<string, SharedPost>) => {
    const h = ids.map((id) => thumb(posts[id])).filter(Boolean);
    return h.length ? `<div class="thumbs">${h.join("")}</div>` : "";
};

const icon = (letter: string, color: string) => `<span class="ic" style="background:${color}">${letter}</span>`;
const head = (letter: string, color: string, title: string, sub: string) =>
    `<div class="ch">${icon(letter, color)}<span class="t">${e(title)}</span><span class="s">${e(sub)}</span></div>`;

const CLIP_COLORS = ["#ff8fc8", "#f5c16c", "#6fb7ff", "#7bc96f", "#ff9a6b", "#9effe4", "#c9c9d1"];

function cardHtml(card: ToolCard, posts: Record<string, SharedPost>): string {
    switch (card.type) {
        case "search":
            return `<div class="card">${head("S", "var(--blue)", "search", `"${card.query}" · ${card.total} found`)}${thumbs(card.hits.map((h) => h.post_id), posts)}</div>`;
        case "look":
            return `<div class="card">${head("L", "var(--blue)", "looked at", plural(card.post_ids.length, "post"))}${thumbs(card.post_ids, posts)}</div>`;
        case "emotes": {
            if (card.emotes.length === 0) return "";
            const em = card.emotes
                .map((x) => `<span class="emo" title="${e(x.name)}"><img src="${e(x.url)}" alt="${e(x.name)}" loading="lazy"></span>`)
                .join("");
            const sub = card.saved ? `saved ${card.emotes[0]?.name ?? ""}` : `${card.query ? `"${card.query}"` : card.sort ?? "7TV"} · ${card.emotes.length}`;
            return `<div class="card">${head("7", "var(--violet)", "emotes", sub)}<div class="emotes">${em}</div></div>`;
        }
        case "edit": {
            const total = Math.max(card.duration, ...card.tracks.flatMap((t) => t.clips.map((c) => c.at + c.length)), 0.1);
            const tracks = card.tracks
                .map((t) => {
                    const clips = t.clips
                        .map((c, i) => {
                            const left = (c.at / total) * 100;
                            const width = Math.max(1.5, (c.length / total) * 100);
                            const name = c.title ?? c.kind ?? "clip";
                            return `<span class="clip" style="left:${left.toFixed(2)}%;width:${width.toFixed(2)}%;background:${CLIP_COLORS[i % CLIP_COLORS.length]}" title="${e(name)}">${e(name)}</span>`;
                        })
                        .join("");
                    return `<div class="trk"><b>${t.name === "main" ? "main" : `over ${t.index}`}</b>${clips}</div>`;
                })
                .join("");
            const size = card.width && card.height ? ` · ${card.width}×${card.height}` : "";
            const render = card.render ? `<div class="sub">render ${e(card.render.status)}${card.render.progress !== null && card.render.status !== "done" ? ` · ${Math.round(card.render.progress * 100)}%` : ""}</div>` : "";
            return `<div class="card">${head("E", "var(--violet)", "edit", `${card.title ?? "untitled"} · ${card.duration.toFixed(1)} s${size}`)}<div class="tl">${tracks}</div>${render}</div>`;
        }
        case "job": {
            const done = card.status === "done";
            const pct = done ? 100 : card.progress !== null ? Math.round(card.progress * 100) : 0;
            const bits = [card.status, card.seconds ? `${Math.round(card.seconds)} s` : "", fmtBytes(card.bytes)].filter(Boolean).join(" · ");
            const color = card.status === "error" ? "var(--red)" : done ? "var(--green)" : "var(--amber)";
            return `<div class="card">${head("J", color, card.op.replace(/^make\./, "") || "job", bits)}<div class="job"><div class="bar"><i style="width:${pct}%;background:${color}"></i></div><small>${pct}%</small></div>${card.error ? `<div class="sub err">${e(card.error)}</div>` : ""}</div>`;
        }
        case "box": {
            const out = [card.stdout, card.stderr].filter(Boolean).join("\n");
            return `<div class="card">${head("$", "var(--amber)", "box", card.timed_out ? "timed out" : `exit ${card.code ?? "?"}`)}<pre class="code open">$ ${e(card.cmd)}${out ? `\n${e(out)}` : ""}</pre></div>`;
        }
        case "files":
            return `<div class="card">${head("F", "var(--amber)", card.direction === "in" ? "into the box" : "out of the box", card.files.map((f) => f.name).join(", "))}${card.post_id ? thumbs([card.post_id], posts) : ""}</div>`;
        case "link":
            return `<div class="card">${head("↗", "var(--green)", card.private ? "private link" : "share link", `${card.title ?? ""}${card.files ? ` · ${plural(card.files, "file")}` : ""}`)}${
                card.url ? `<a class="lnk" href="${e(card.url)}" rel="noopener nofollow">${e(card.url)}</a>` : ""
            }</div>`;
        case "collection":
            return `<div class="card">${head("C", "var(--green)", card.of === "set" ? "set" : "collection", `${card.name} · ${card.change}${card.count !== null ? ` · ${card.count}` : ""}`)}</div>`;
        case "saved":
            return `<div class="card">${head("↓", "var(--green)", "saved", card.title ?? card.status ?? "")}${thumbs(card.post_ids, posts)}</div>`;
        case "facts":
            return `<div class="card">${head("i", "var(--cap)", card.title, "")}<table class="facts">${card.rows.map(([k, v]) => `<tr><td>${e(k)}</td><td>${e(v)}</td></tr>`).join("")}</table>${thumbs(card.post_ids, posts)}</div>`;
        case "agents": {
            const rows = card.agents
                .map((a) => `<div class="agent"><b>${e(a.name)}</b> <small>${e(a.status)}</small><div class="sub">${e(a.result ?? a.activity ?? a.task)}</div></div>`)
                .join("");
            const msg = card.message ? `<div class="sub">to ${e(card.message.to)}: ${e(card.message.text)}</div>` : "";
            const mail = card.mail.map((m) => `<div class="sub">from ${e(m.from)}: ${e(m.text)}</div>`).join("");
            return `<div class="card">${head("A", "var(--violet)", "helpers", card.change)}${rows}${msg}${mail}</div>`;
        }
        default:
            return "";
    }
}

function stepHtml(s: SharedStep, posts: Record<string, SharedPost>): string {
    if (s.kind === "confirm" && s.confirm) {
        const st = s.confirm.status === "yes" ? "approved" : s.confirm.status === "no" ? "declined" : s.confirm.status;
        return `<div class="card">${head("?", "var(--amber)", "asked first", st)}<div class="sub">${e(s.confirm.summary)}</div></div>`;
    }
    if (s.kind === "job" && s.job) {
        return `<div class="card">${head("J", "var(--amber)", "waited for a job", s.job.status)}${s.job.note ? `<div class="sub">${e(s.job.note)}</div>` : ""}</div>`;
    }
    const chips = s.calls.map((c) => `<span class="chip${c.status === "error" ? " err" : ""}">${e(c.op)} <em>${e(fmtMs(c.ms))}</em></span>`).join("");
    const label = `${s.status === "error" ? "code failed" : "ran code"}${s.duration_ms !== null ? ` · ${fmtMs(s.duration_ms)}` : ""}`;
    const stepBox =
        s.code !== null
            ? `<details class="step"><summary><span class="dot${s.status === "error" ? " bad" : ""}"></span><span class="grow">${e(label)}</span></summary><pre class="code">${e(s.code)}</pre>${chips ? `<div class="trail">${chips}</div>` : ""}</details>`
            : chips
              ? `<div class="step"><div class="sh"><span class="dot${s.status === "error" ? " bad" : ""}"></span><span class="grow">${e(label)}</span></div><div class="trail">${chips}</div></div>`
              : "";
    const cards = s.calls.map((c) => (c.card ? cardHtml(c.card, posts) : "")).join("");
    return stepBox + cards;
}

function playerHtml(p: SharedPost): string {
    const f = p.file;
    if (!f) return `<div class="nofile">${e(p.title ?? "a post")}</div>`;
    const cap = [p.title, fmtDuration(f.duration ?? p.duration)].filter(Boolean).join(" · ");
    const ratio = f.width && f.height ? ` style="aspect-ratio:${f.width}/${f.height}"` : "";
    const media =
        f.type === "video"
            ? `<video src="${e(f.url)}"${f.poster ? ` poster="${e(f.poster)}"` : ""} controls playsinline preload="metadata"${ratio}></video>`
            : `<img src="${e(f.url)}" alt="${e(p.title ?? "")}" loading="lazy"${ratio}>`;
    return `<figure class="player" id="post-${e(p.id)}">${media}${cap ? `<figcaption>${e(cap)}${p.kind === "gallery" ? ` · 1 of ${p.files}` : ""}</figcaption>` : ""}</figure>`;
}

function messageHtml(m: SharedMessage, posts: Record<string, SharedPost>, placed: Set<string>): string {
    if (m.role === "user") {
        const shown = m.post_ids.map((id) => posts[id]).filter((p): p is SharedPost => !!p);
        return `<div class="user">${miniMarkdown(m.text)}${shown.length ? thumbs(shown.map((p) => p.id), posts) : ""}</div>`;
    }
    const parts: string[] = [`<div class="who"><i></i>capystore</div>`];
    for (const s of m.steps) parts.push(stepHtml(s, posts));
    if (m.ranked) {
        const rows = m.ranked.hits
            .map((h, i) => `<div class="rank"><b>${i + 1}</b>${thumb(posts[h.post_id])}<span>${e(posts[h.post_id]?.title ?? "")}<small>${e(h.why.join(" · "))}</small></span></div>`)
            .join("");
        parts.push(`<div class="card">${head("#", "var(--blue)", m.ranked.title ?? "ranked", m.ranked.query ?? "")}${rows}</div>`);
    }
    if (m.collage) {
        parts.push(`<div class="card">${head("▦", "var(--blue)", m.collage.title ?? "collage", `${m.collage.total} posts`)}${thumbs(m.collage.post_ids, posts)}</div>`);
    }
    if (m.text.trim()) parts.push(`<div class="text">${miniMarkdown(m.text)}</div>`);
    // the posts the reply showed play right here (each once on the page; later mentions are thumbnails)
    const play = m.post_ids.map((id) => posts[id]).filter((p): p is SharedPost => !!p && !placed.has(p.id));
    for (const p of play) placed.add(p.id);
    if (play.length) parts.push(`<div class="players${play.length > 1 ? " many" : ""}">${play.map(playerHtml).join("")}</div>`);
    if (m.status === "error") parts.push(`<div class="sub err">this reply stopped part way</div>`);
    return `<div class="reply">${parts.join("")}</div>`;
}

const STYLE = `
:root{--bg:#000;--surface:#191919;--elev:#282828;--text:#e1e1e1;--cap:#8f8f8f;--row:#222;--hair:rgba(255,255,255,.07);
--blue:#2f8af9;--green:#30bd1b;--red:#ff5c6c;--amber:#f5ad5b;--violet:#a78bfa;
--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:light){:root{--bg:#fff;--surface:#f4f4f4;--elev:#e3e3e3;--text:#000;--cap:#6e6e75;--row:#fff;--hair:rgba(0,0,0,.09);--violet:#6d4fd8;--amber:#a65b08;--blue:#196bd4}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:14px/1.6 var(--mono)}
a{color:var(--blue)}
header,main,footer{max-width:680px;margin:0 auto;padding:0 18px}
header{padding-top:30px;padding-bottom:14px;border-bottom:1px solid var(--hair)}
h1{font-size:20px;margin:0 0 6px;line-height:1.3}
.meta{color:var(--cap);font-size:12px;display:flex;gap:14px;flex-wrap:wrap}
.meta b{color:var(--text);font-weight:500}
main{padding-top:20px;padding-bottom:40px;display:flex;flex-direction:column;gap:18px}
.user{align-self:flex-end;max-width:82%;background:var(--elev);border-radius:18px;padding:10px 14px}
.user p,.text p{margin:0 0 8px}.user p:last-child,.text p:last-child{margin:0}
.text ul{margin:0 0 8px;padding-left:20px}
code{background:var(--surface);padding:1px 5px;border-radius:5px;font-size:.92em}
.reply{display:flex;flex-direction:column;gap:10px;min-width:0}
.who{font-size:11px;color:var(--cap);display:flex;gap:6px;align-items:center}
.who i{width:16px;height:16px;border-radius:5px;background:linear-gradient(135deg,var(--violet),var(--blue));display:inline-block}
.step{background:var(--surface);border-radius:12px;overflow:hidden}
.step summary,.sh{display:flex;align-items:center;gap:8px;padding:8px 10px;color:var(--cap);font-size:12px;cursor:pointer;list-style:none}
.step summary::-webkit-details-marker{display:none}
.step summary::after{content:"▾"}
.dot{width:7px;height:7px;border-radius:50%;background:var(--green);flex:none}.dot.bad{background:var(--red)}
.grow{flex:1}
.code{margin:0 10px 8px;padding:8px;background:var(--bg);border-radius:8px;font-size:11.5px;white-space:pre;overflow-x:auto;max-height:420px}
.card .code{margin:0}
.trail{display:flex;flex-wrap:wrap;gap:5px;padding:0 10px 9px}
.chip{font-size:11px;padding:3px 7px;border-radius:7px;background:var(--elev)}.chip em{font-style:normal;color:var(--cap)}.chip.err{color:var(--red)}
.card{background:var(--row);border:1px solid var(--hair);border-radius:14px;padding:10px 11px;min-width:0}
.ch{display:flex;align-items:center;gap:8px;font-size:12px;margin-bottom:8px}
.ic{width:22px;height:22px;border-radius:7px;display:grid;place-items:center;font-size:12px;font-weight:600;color:#000;flex:none}
.ch .t{font-weight:600}.ch .s{color:var(--cap);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sub{color:var(--cap);font-size:12px;margin-top:6px}.err{color:var(--red)}
.thumbs{display:flex;gap:6px;overflow-x:auto;padding-bottom:2px}
.th{flex:none;width:72px;height:96px;border-radius:9px;position:relative;overflow:hidden;background:var(--elev);display:block;color:var(--cap);text-decoration:none}
.th img{width:100%;height:100%;object-fit:cover;display:block}
.th .nt{display:block;padding:6px;font-size:10px;line-height:1.3}
.th small{position:absolute;left:4px;bottom:4px;font-size:10px;background:rgba(0,0,0,.65);color:#e1e1e1;padding:1px 4px;border-radius:5px}
.emotes{display:grid;grid-template-columns:repeat(auto-fill,minmax(52px,1fr));gap:6px}
.emo{aspect-ratio:1;border-radius:10px;background:var(--surface);display:grid;place-items:center}
.emo img{width:72%;height:72%;object-fit:contain}
.tl{background:var(--bg);border-radius:10px;padding:8px 8px 8px 58px;font-size:10.5px}
.trk{position:relative;height:24px;margin:4px 0}
.trk b{position:absolute;left:-52px;top:4px;color:var(--cap);font-weight:400;white-space:nowrap}
.clip{position:absolute;top:0;height:24px;border-radius:6px;padding:4px 6px;color:#000;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;font-weight:500}
.job{display:flex;align-items:center;gap:10px}.job small{color:var(--cap)}
.job .bar{flex:1;height:6px;background:var(--elev);border-radius:3px;overflow:hidden}.job .bar i{display:block;height:100%}
.lnk{font-size:12px;word-break:break-all}
.facts{font-size:12px;border-collapse:collapse}.facts td{padding:2px 12px 2px 0;vertical-align:top}.facts td:first-child{color:var(--cap)}
.agent{margin-top:6px}.agent small{color:var(--cap)}
.rank{display:flex;gap:10px;align-items:center;margin-top:6px}.rank b{width:18px;color:var(--cap);font-weight:500}
.rank .th{width:48px;height:64px}.rank span{display:flex;flex-direction:column;font-size:12.5px;min-width:0}.rank small{color:var(--cap)}
.players{display:flex;flex-direction:column;gap:10px}
.players.many{flex-direction:row;flex-wrap:wrap}
.player{margin:0;max-width:360px}
.players.many .player{max-width:calc(50% - 5px);min-width:150px}
.player video,.player img{width:100%;max-height:70vh;border-radius:14px;background:#111;display:block;object-fit:contain}
.player figcaption{color:var(--cap);font-size:11.5px;margin-top:5px}
.nofile{color:var(--cap);font-size:12px;background:var(--surface);border-radius:10px;padding:8px 10px}
footer{padding-top:16px;padding-bottom:34px;color:var(--cap);font-size:11.5px;border-top:1px solid var(--hair);display:flex;justify-content:space-between}
`;

// The whole page of a shared chat, from its transcript.
export function chatPageHtml(t: ChatTranscript): string {
    const placed = new Set<string>();
    const body = t.messages.map((m) => messageHtml(m, t.posts, placed)).join("\n");
    const firstUser = t.messages.find((m) => m.role === "user")?.text ?? "";
    const desc = [
        `a chat · ${plural(t.counts.messages, "message")}`,
        t.counts.videos ? plural(t.counts.videos, "video") : "",
        t.counts.pictures ? plural(t.counts.pictures, "picture") : "",
    ]
        .filter(Boolean)
        .join(" · ");
    const ogDesc = firstUser ? `${desc}\n“${Array.from(firstUser.replace(/\s+/g, " ").trim()).slice(0, 160).join("")}”` : desc;
    // the preview picture: the first poster or picture the page shows
    const first = Object.values(t.posts).find((p) => p.file && (p.file.type === "image" || p.file.poster))?.file ?? null;
    const image = first ? (first.type === "image" ? first.url : first.poster) : null;
    const meta = [
        `<meta property="og:site_name" content="capystore">`,
        `<meta property="og:type" content="article">`,
        `<meta property="og:title" content="${e(t.thread.title)}">`,
        `<meta property="og:description" content="${e(ogDesc)}">`,
        `<meta property="og:url" content="${e(t.thread.url)}">`,
        `<meta name="twitter:title" content="${e(t.thread.title)}">`,
        `<meta name="twitter:description" content="${e(ogDesc)}">`,
        `<meta name="theme-color" content="#a78bfa">`,
        ...(image
            ? [
                  `<meta property="og:image" content="${e(image)}">`,
                  ...(first?.width && first.height ? [`<meta property="og:image:width" content="${first.width}">`, `<meta property="og:image:height" content="${first.height}">`] : []),
                  `<meta name="twitter:card" content="summary_large_image">`,
                  `<meta name="twitter:image" content="${e(image)}">`,
              ]
            : [`<meta name="twitter:card" content="summary">`]),
    ];
    const metaLine = [
        `<span><b>capystore</b> chat</span>`,
        `<span>${e(fmtDate(t.thread.shared_at))}</span>`,
        `<span>${e(plural(t.counts.messages, "message"))}</span>`,
        t.counts.videos ? `<span>${e(plural(t.counts.videos, "video"))}</span>` : "",
        t.counts.pictures ? `<span>${e(plural(t.counts.pictures, "picture"))}</span>` : "",
    ].join("");
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${e(t.thread.title)} · capystore</title>
<link rel="canonical" href="${e(t.thread.url)}">
${meta.join("\n")}
<style>${STYLE}</style>
</head>
<body>
<header><h1>${e(t.thread.title)}</h1><div class="meta">${metaLine}</div></header>
<main>
${body}
</main>
<footer><span>shared from capystore</span><span>made with Claude</span></footer>
</body>
</html>
`;
}
