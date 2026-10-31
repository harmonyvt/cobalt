// Chat snapshot -> a timed script for the chat video (the "beats"). Pure: no I/O, no clock, no randomness.
// The page (page.js) draws the chat at any time t from this script; render.js steps t frame by frame.
//
// A beat is { el, at, ...extra } where `el` names one thing on screen and `at` is when it appears (seconds).
// The order of the chat is kept: the composer types the user's message, it is sent as a bubble, the assistant
// "thinks", its tool chips and cards pop in one by one, its text streams in word by word, then its pictures and
// videos appear; a video plays (with its sound) before the chat goes on.

/** Default pacing, seconds. `speed` divides every duration (2 = twice as fast). */
export const PACE = {
    intro: 0.6, // empty chat before the first message
    typeCps: 28, // composer typing speed (characters per second)
    typeMax: 2.2, // a long message types for at most this long
    sendHold: 0.25, // a finished message sits in the composer before it is sent
    afterUser: 0.45,
    thinking: 0.9, // the three dots before the first chip
    chip: 0.22, // between tool chips
    card: 0.5, // between cards
    textWps: 14, // assistant words per second
    textMax: 5,
    media: 0.35, // between shown files
    videoMax: 12, // a shown video plays at most this long
    imageHold: 1.2,
    afterReply: 0.9,
    outro: 1.6,
};

/** Output sizes (device pixels; the page is drawn at half of this, 2x). */
export const SHAPES = {
    portrait: { w: 1080, h: 1920 },
    landscape: { w: 1920, h: 1080 },
    square: { w: 1080, h: 1080 },
};

export const LIMITS = { messages: 40, seconds: 180, cards: 6, media: 4 };

/** Words of a text, keeping the spaces and newlines with the word before them (so joining gives the text back). */
export function words(text) {
    return String(text).match(/\S+\s*/g) ?? [];
}

/**
 * @param {any} snap the snapshot (GET /chat/threads/<id> body without the model's own turns; see CHAT-VIDEO.md)
 * @param {{speed?: number, videoMax?: number, from?: string|null, to?: string|null}} [opts]
 */
export function plan(snap, opts = {}) {
    const speed = Math.min(4, Math.max(0.25, opts.speed ?? 1));
    const P = Object.fromEntries(Object.entries(PACE).map(([k, v]) => [k, k.endsWith("Cps") || k.endsWith("Wps") ? v * speed : v / speed]));
    const videoMax = opts.videoMax ?? PACE.videoMax;
    const posts = snap.posts ?? {};
    let msgs = (snap.messages ?? []).filter((m) => m.role === "user" || m.role === "assistant");
    if (opts.from) msgs = msgs.slice(Math.max(0, msgs.findIndex((m) => m.id === opts.from)));
    if (opts.to) {
        const i = msgs.findIndex((m) => m.id === opts.to);
        if (i >= 0) msgs = msgs.slice(0, i + 1);
    }
    msgs = msgs.slice(0, LIMITS.messages);

    /** @type {any[]} */
    const beats = [];
    /** @type {{post: string, file: any, at: number, length: number, el: string}[]} */
    const sounds = [];
    let t = P.intro;

    for (const m of msgs) {
        if (m.role === "user") {
            const text = String(m.text ?? "");
            const typing = Math.min(P.typeMax, text.length / P.typeCps);
            beats.push({ el: `m${m.id}.type`, at: t, until: t + typing + P.sendHold, text });
            t += typing + P.sendHold;
            beats.push({ el: `m${m.id}`, at: t, kind: "user" });
            const att = (m.post_ids ?? []).filter((id) => posts[id]).slice(0, LIMITS.media);
            att.forEach((id, i) => beats.push({ el: `m${m.id}.post${i}`, at: t + 0.1 * (i + 1), post: id, still: true }));
            t += P.afterUser;
            continue;
        }
        // assistant
        beats.push({ el: `m${m.id}.think`, at: t, until: t + P.thinking });
        t += P.thinking;
        beats.push({ el: `m${m.id}`, at: t, kind: "assistant" });
        let cards = 0;
        (m.steps ?? []).forEach((s, si) => {
            beats.push({ el: `m${m.id}.s${si}`, at: t });
            t += P.chip;
            (s.calls ?? []).forEach((c, ci) => {
                beats.push({ el: `m${m.id}.s${si}.c${ci}`, at: t });
                t += P.chip;
            });
            (s.calls ?? []).forEach((c, ci) => {
                if (!c.card || cards >= LIMITS.cards) return;
                cards++;
                beats.push({ el: `m${m.id}.s${si}.card${ci}`, at: t });
                t += P.card;
            });
        });
        const w = words(m.text ?? "");
        if (w.length) {
            const len = Math.min(P.textMax, w.length / P.textWps);
            beats.push({ el: `m${m.id}.text`, at: t, until: t + len, words: w.length });
            t += len + 0.15;
        }
        const shown = (m.post_ids ?? []).filter((id) => posts[id]).slice(0, LIMITS.media);
        for (let i = 0; i < shown.length; i++) {
            const post = posts[shown[i]];
            const file = (post.files ?? []).find((f) => f.kind === "video" && f.url);
            const el = `m${m.id}.post${i}`;
            if (file) {
                const length = Math.min(videoMax, file.duration ?? videoMax);
                beats.push({ el, at: t, post: post.id, play: { url: file.url, at: t + 0.3, length } });
                sounds.push({ post: post.id, file, at: t + 0.3, length, el });
                t += 0.3 + length;
            } else {
                beats.push({ el, at: t, post: post.id });
                t += P.media;
                if (i === shown.length - 1) t += P.imageHold;
            }
        }
        t += P.afterReply;
        if (t > LIMITS.seconds) break;
    }
    const seconds = Math.min(LIMITS.seconds, t + P.outro - P.afterReply);
    return { seconds, beats, sounds, messages: msgs.map((m) => m.id) };
}
