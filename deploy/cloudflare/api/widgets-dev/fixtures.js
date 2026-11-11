// Realistic fixtures for every view and state (the shapes of src/mcp-app/shapes.ts), with inline pictures only.
const svgs = {};
export function art(c1, c2, label = "") {
    const key = c1 + c2 + label;
    if (!svgs[key]) {
        const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 240 240"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/></linearGradient></defs><rect width="240" height="240" fill="url(#g)"/><text x="120" y="130" font-size="22" text-anchor="middle" fill="rgba(255,255,255,.8)" font-family="sans-serif">${label}</text></svg>`;
        svgs[key] = "data:image/svg+xml;utf8," + encodeURIComponent(svg);
    }
    return svgs[key];
}
const A = (i) => [["#f7a1c4", "#b3477d"], ["#ffc3dd", "#d65e98"], ["#c9b8ff", "#e2589a"], ["#ffb199", "#c94b7c"], ["#ffd2e6", "#e2589a"], ["#ffe3b3", "#e36f8f"], ["#9ccc65", "#33691e"], ["#90caf9", "#3b6fd8"]][i % 8];
export const thumb = (i, label) => art(...A(i), label || "");
const MEDIA = "https://media.capybaraharmony.com";
const SHARE = "https://share.capybaraharmony.com";
export const XSS_TITLE = '<img src=x onerror="window.__xss=1">pwned <b>bold</b>';

const post = (o) => ({ id: "p0", title: "post", kind: "image", thumb_url: null, duration_s: null, saved_at: "2026-11-11T14:14:00Z", source_host: "x.com", status: "public", files: 1, bytes: null, ...o });
export const POSTS = [
    post({ id: "post-img-1", title: "Trainwrecks tweaking - pink hair (blown out)", thumb_url: thumb(0, "image"), source_host: "x.com" }),
    post({ id: "post-vid-1", title: "cat girl reacts to the new emote", kind: "video", thumb_url: thumb(3, "video"), duration_s: 14, files: 1 }),
    post({ id: "post-gal-1", title: "pink hair edit, side by side", kind: "gallery", thumb_url: thumb(2, "gallery"), files: 4 }),
    post({ id: "post-priv-1", title: "for the mods only", kind: "video", thumb_url: null, duration_s: 61.5, status: "private", files: 1 }),
    post({ id: "post-xss", title: XSS_TITLE, kind: "image", thumb_url: thumb(5, "xss") }),
    post({ id: "post-img-2", title: "Ming Dynasty meme - expression (no zoom)", thumb_url: thumb(5, "image") }),
    post({ id: "post-img-3", title: "Trainwrecks tweaking - pink catgirl swap (WebP)", thumb_url: thumb(4, "webp") }),
    post({ id: "post-off-1", title: "saved from tiktok, no link yet", kind: "video", thumb_url: null, duration_s: 9, status: "off", source_host: "tiktok.com" }),
];
const file = (o) => ({ id: "f0", kind: "image", content_type: "image/png", url: null, width: 1080, height: 1920, duration_s: null, bytes: 1234567, ...o });
export const postDetail = (id) => {
    const p = POSTS.find((x) => x.id === id);
    if (!p) return null;
    const extra = { source_link: "https://x.com/someone/status/1987", caption: "Lia sees the new emote and loses it completely", transcript_excerpt: "wait is that me? that's so me", share_url: p.status === "public" ? `${SHARE}/Qm3vT8x2` : null, private_url: p.status === "private" ? `${SHARE}/p/9fK2/1.mp4` : null };
    let file_list = [file({ id: "f1", kind: p.kind === "video" ? "video" : "image", content_type: p.kind === "video" ? "video/mp4" : "image/png", url: p.status === "public" ? `${MEDIA}/${p.id}.${p.kind === "video" ? "mp4" : "png"}` : null, duration_s: p.duration_s })];
    if (p.kind === "gallery") file_list = [1, 2, 3, 4].map((n) => file({ id: "g" + n, url: `${MEDIA}/gal-${n}.png`, width: 1080, height: 1080 }));
    if (p.id === "post-vid-1") extra.caption = "Lia sees the new emote and loses it completely (>w<)";
    return { view: "post", post: { ...p, ...extra, file_list } };
};

export const searchOut = (query, n = 8) => ({ view: "search", query, mode: "meaning", total: n === 8 ? 21 : n, items: POSTS.slice(0, n) });

const clip = (o) => ({ in: null, out: null, speed: null, muted: null, poster_url: null, ...o });
export const EDIT = {
    id: "edit-1", title: "Shrek then pink cat girl", revision: 3, duration_s: 34.43, canvas: { w: 720, h: 1280, fps: 30 },
    main: [
        clip({ id: "c1", name: "Shrek clip", start: 0, end: 16.2, in: 0, out: 16.2, speed: 1, muted: false, poster_url: thumb(6, "shrek") }),
        clip({ id: "c2", name: "pink cat girl dance", start: 16.2, end: 34.43, in: 4, out: 22.2, speed: 1, muted: true, poster_url: thumb(0, "dance") }),
    ],
    overlay: [
        { id: "o1", name: "Lia cutout", kind: "cutout", start: 18, end: 28 },
        { id: "o2", name: "caption", kind: "text", start: 20, end: 30 },
    ],
    render: { status: "done", progress: 1, post_id: "post-vid-1", poster_url: thumb(3, "render"), stale: false },
};
export const editOut = (project) => ({ view: "edit", project, projects: [] });
export const editList = () => ({
    view: "edit", project: null,
    projects: [
        { id: "edit-1", title: "Shrek then pink cat girl", revision: 3, duration_s: 34.43, rendered: true, poster_url: thumb(3, "") },
        { id: "edit-2", title: "jumpscare compilation", revision: 1, duration_s: 61, rendered: false, poster_url: null },
        { id: "edit-3", title: XSS_TITLE, revision: 7, duration_s: 9.5, rendered: true, poster_url: thumb(5, "") },
    ],
});
export const editLong = () => editOut({ ...EDIT, id: "edit-long", title: "stream vod cut", duration_s: 3725, main: [clip({ id: "l1", name: "intro", start: 0, end: 600 }), clip({ id: "l2", name: "game", start: 600, end: 3600, muted: false }), clip({ id: "l3", name: "outro", start: 3600, end: 3725 })], overlay: [], render: { status: "running", progress: 0.4, post_id: null, poster_url: null, stale: false } });
export const editShort = () => editOut({ ...EDIT, id: "edit-short", title: "tiny loop", duration_s: 3, main: [clip({ id: "s1", name: "loop", start: 0, end: 3 })], overlay: [], render: { status: "done", progress: 1, post_id: null, poster_url: null, stale: true } });

const link = (o) => ({ id: "l0", url: `${SHARE}/g/7Kp2xQ`, title: null, files: 1, private: false, created_at: "2026-11-06T10:00:00Z", thumbs: [], collection: null, ...o });
export const LINKS = [
    link({ id: "lk1", url: `${SHARE}/g/7Kp2xQ`, title: "pink hair edits (all 4)", files: 4, thumbs: [0, 1, 2, 3].map((i) => thumb(i)) }),
    link({ id: "lk2", url: `${SHARE}/g/Mn81Lz`, title: null, files: 10, thumbs: [4, 5].map((i) => thumb(i)), collection: "Lia Share 23" }),
    link({ id: "lk3", url: `${SHARE}/p/9fK2/1.mp4`, title: "for the mods only", files: 1, private: true, thumbs: [] }),
    link({ id: "lk4", url: `${SHARE}/g/Xyz123`, title: XSS_TITLE, files: 2, thumbs: [6].map((i) => thumb(i)) }),
];
export const linksOut = (o = {}) => ({ view: "links", total: LINKS.length, links: LINKS, created: null, ...o });

export const collectionsOut = () => ({
    view: "collections", total: 19,
    collections: [
        { id: "col1", name: "Lia Share 23", links: [{ id: "lk1", url: `${SHARE}/g/aaa`, files: 10, private: false }], posts: 10, thumbs: [0, 1, 2, 3, 4, 5, 6, 7].map((i) => thumb(i)) },
        { id: "col2", name: "Lia Share 5", links: [{ id: "lk2", url: `${SHARE}/g/bbb`, files: 10, private: false }, { id: "lk3", url: `${SHARE}/g/ccc`, files: 10, private: false }], posts: 20, thumbs: [2, 3, 4].map((i) => thumb(i)) },
        { id: "col3", name: "empty one", links: [], posts: 0, thumbs: [] },
        { id: "col4", name: XSS_TITLE, links: [{ id: "lk4", url: `${SHARE}/g/ddd`, files: 3, private: true }], posts: 3, thumbs: [1].map((i) => thumb(i)) },
    ],
});

const src = (o = {}) => ({ id: "post-vid-2", title: "HARMONY JUMPSCARE", duration_s: 60, poster_url: thumb(2, "source"), url: `${MEDIA}/jumpscare.mp4`, ...o });
export const webp = (state, o = {}) => ({ view: "webp", state, job: null, progress: null, error: null, source: src(), range: null, width: 480, quality: "med", post: null, share_url: null, ...o });
export const webpPick = () => webp("pick");
export const webpRunning = () => webp("running", { job: "job-webp-1", progress: 0.2, range: { start: 41, end: 45.5 } });
export const webpDone = () => webp("done", { range: { start: 41, end: 45.5 }, progress: 1, post: post({ id: "post-webp-1", title: "HARMONY JUMPSCARE (WebP)", thumb_url: thumb(4, "webp"), bytes: 1887436 }), share_url: `${SHARE}/jmpscr-webp` });
export const webpError = () => webp("error", { error: "the clip could not be read", range: { start: 41, end: 45.5 } });

export const uploadOut = (base, names = ["dance.mp4", "lia-wave.gif", "thumb.png"]) => ({
    view: "upload",
    uploads: names.map((n, i) => ({ name: n, upload_url: `${base}/mcp/upload/tok${i}-${n}`, expires_at: new Date(Date.now() + 15 * 60000).toISOString(), curl: "curl -T FILE ..." })),
    max_bytes: 100000000, accept: ["mp4", "mov", "gif", "jpg", "png", "webp", "heic"], public: false,
});
export const saveOut = (state, o = {}) => ({ view: "save", state, job: state === "running" ? "job-save-1" : null, url: "https://x.com/someone/status/1987654321", engine: null, error: null, post: null, share_url: null, ...o });
export const saveDone = () => saveOut("done", { post: POSTS[1], share_url: `${SHARE}/Qm3vT8x2` });
export const saveError = () => saveOut("error", { error: "that link has no video we can download", engine: "ytdlp" });
