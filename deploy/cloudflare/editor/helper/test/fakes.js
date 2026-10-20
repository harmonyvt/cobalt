// Deterministic stand-ins for probed sources, so the compiler's argv can be compared without any ffmpeg.
/** @param {import("../timeline.js").Timeline} t @returns {Record<string, import("../probe.js").Source>} */
export function fakeSources(t) {
    const items = [...new Set([...t.main.map((c) => c.item), ...t.overlay.map((o) => o.item)])];
    /** @type {Record<string, import("../probe.js").Source>} */
    const out = {};
    items.forEach((item, i) => {
        const n = i;
        const isOverlay = t.overlay.some((o) => o.item === item) && !t.main.some((c) => c.item === item);
        const base = { item, path: `/in/${n}`, bytes: 1000, orientation: 1, squareFrom: null, hdr: false, transfer: null };
        if (isOverlay && i % 3 === 1) out[item] = { ...base, kind: "gif", contentType: "image/gif", width: 500, height: 500, duration: null, hasAudio: false, channels: null };
        else if (isOverlay && i % 3 === 2) out[item] = { ...base, kind: "photo", contentType: "image/jpeg", width: 3024, height: 4032, duration: null, hasAudio: false, channels: null, orientation: 6 };
        else if (i % 4 === 1) out[item] = { ...base, kind: "video", contentType: "video/mp4", width: 1080, height: 1920, duration: 100, hasAudio: true, channels: 1 };
        else if (i % 4 === 2) out[item] = { ...base, kind: "video", contentType: "video/mp4", width: 3840, height: 2160, duration: 100, hasAudio: true, channels: 2, hdr: true, transfer: "arib-std-b67" };
        else if (i % 4 === 3) out[item] = { ...base, kind: "video", contentType: "video/mp4", width: 720, height: 540, squareFrom: { w: 720, h: 480 }, duration: 100, hasAudio: false, channels: null };
        else out[item] = { ...base, kind: "video", contentType: "video/mp4", width: 1920, height: 1080, duration: 100, hasAudio: true, channels: 2 };
    });
    return out;
}
