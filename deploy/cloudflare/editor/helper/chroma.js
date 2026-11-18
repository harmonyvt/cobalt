// Chroma key (APP-API-CONTRACT.md section 66). Pure: no I/O. The editor container's copy of the
// rules in api/helper/chroma.js (this image's build context is editor/ only). Tests pin the same strings.

/** Preset chips. An eyedropper colour is any other #RRGGBB and is not despilled. */
export const KEY_GREEN = "#00B140";
export const KEY_BLUE = "#0047BB";

const HEX = /^#[0-9A-Fa-f]{6}$/;

/** @param {unknown} color @returns {string | null} `#RRGGBB` uppercase, or null. */
export function normalizeHex(color) {
    if (typeof color !== "string") return null;
    const s = color.trim();
    if (!HEX.test(s)) return null;
    return `#${s.slice(1).toUpperCase()}`;
}

/** Plain decimal, at most 3 places: never "1e-7", which ffmpeg would misread. @param {number} n */
const dec = (n) => String(+Number(n).toFixed(3));

/** @param {number} n @param {number} lo @param {number} hi */
const inRange = (n, lo, hi) => typeof n === "number" && Number.isFinite(n) && n >= lo - 1e-9 && n <= hi + 1e-9;

/**
 * @param {unknown} raw an object, or a JSON string (the upload query)
 * @returns {{ok: true, key: {color: string, similarity: number, blend: number, spill: number} | null} | {ok: false}}
 * Absent (`undefined`, `null`, `""`) is `{ok: true, key: null}` so a job without a key stays what it was.
 */
export function parseChromaKey(raw) {
    if (raw === undefined || raw === null || raw === "") return { ok: true, key: null };
    let v = raw;
    if (typeof raw === "string") {
        try {
            v = JSON.parse(raw);
        } catch {
            return { ok: false };
        }
    }
    if (typeof v !== "object" || v === null || Array.isArray(v)) return { ok: false };
    const o = /** @type {Record<string, unknown>} */ (v);
    const color = normalizeHex(o.color);
    if (!color) return { ok: false };
    const similarity = typeof o.similarity === "number" ? o.similarity : Number(o.similarity);
    const blend = typeof o.blend === "number" ? o.blend : Number(o.blend);
    const spill = typeof o.spill === "number" ? o.spill : Number(o.spill);
    if (!inRange(similarity, 0.01, 0.6)) return { ok: false };
    if (!inRange(blend, 0, 0.5)) return { ok: false };
    if (!inRange(spill, 0, 1)) return { ok: false };
    return {
        ok: true,
        key: { blend: +blend.toFixed(3), color, similarity: +similarity.toFixed(3), spill: +spill.toFixed(3) },
    };
}

/** @param {string} color @returns {"green" | "blue" | null} */
export function despillType(color) {
    const c = normalizeHex(color);
    if (c === KEY_GREEN) return "green";
    if (c === KEY_BLUE) return "blue";
    return null;
}

/**
 * The filter chain on one keyed stream, ending in `format=`. Green and blue presets add
 * `despill=type=green|blue:mix=SPILL:expand=0`. An eyedropper colour does not.
 * @param {{color: string, similarity: number, blend: number, spill: number}} key
 * @param {"rgba" | "yuva420p"} format
 */
export function chromaChain(key, format) {
    const parts = [`chromakey=color=0x${key.color.slice(1)}:similarity=${dec(key.similarity)}:blend=${dec(key.blend)}`];
    const spill = despillType(key.color);
    if (spill) parts.push(`despill=type=${spill}:mix=${dec(key.spill)}:expand=0`);
    parts.push(`format=${format}`);
    return parts.join(",");
}

/**
 * What sits behind the keyed subject. Absent is transparent.
 * `clip` is the editor's main track (a studio WebP has no second clip and refuses it).
 * @param {unknown} raw
 * @returns {{ok: true, background: {type: "transparent" | "clip"} | {type: "color", color: string} | null} | {ok: false}}
 */
export function parseBackground(raw) {
    if (raw === undefined || raw === null || raw === "") return { ok: true, background: null };
    let v = raw;
    if (typeof raw === "string") {
        try {
            v = JSON.parse(raw);
        } catch {
            return { ok: false };
        }
    }
    if (typeof v !== "object" || v === null || Array.isArray(v)) return { ok: false };
    const o = /** @type {Record<string, unknown>} */ (v);
    if (o.type === "transparent" || o.type === "clip") return { ok: true, background: { type: o.type } };
    if (o.type === "color") {
        const color = normalizeHex(o.color);
        if (!color) return { ok: false };
        return { ok: true, background: { type: "color", color } };
    }
    return { ok: false };
}

/**
 * A solid underlay (`color=c=0xRRGGBB`). `seconds` is how long the plate lasts.
 * @param {string} color `#RRGGBB`
 * @param {number} w @param {number} h @param {number} fps @param {number} seconds
 */
export function colorUnderlay(color, w, h, fps, seconds) {
    return `color=c=0x${normalizeHex(color)?.slice(1) ?? "000000"}:s=${w}x${h}:r=${fps}:d=${dec(seconds)}`;
}

/** @typedef {"webp" | "webm" | "prores" | "mp4"} KeyedFormat */

/** @param {unknown} raw @returns {KeyedFormat | null | ""} null = absent (keep the default); `""` = present but not a format. */
export function parseKeyedFormat(raw) {
    if (raw === undefined || raw === null || raw === "") return null;
    if (raw === "webp" || raw === "webm" || raw === "prores" || raw === "mp4") return raw;
    return "";
}
