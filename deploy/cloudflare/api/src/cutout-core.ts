// Background removal by colour (APP-API-CONTRACT.md section 39.5): the pure part, no Cloudflare imports, so the tests run it
// under node. A PNG decoder and encoder (zlib through the platform's (De)CompressionStream) and the cutout itself: the
// background colour is taken out where it touches the picture's edges (or everywhere), with a tolerance, a softened edge
// and an optional trim to the subject. The app's on-device colour cutout (CobaltKit `Cutout`) follows the same rules.

export type Rgba = { width: number; height: number; data: Uint8Array };

export type CutoutMode = "white" | "color";
export type CutoutOptions = {
    mode: CutoutMode;
    /** `color` mode: the background, [r, g, b] 0..255 */
    color?: [number, number, number];
    /** 0..100: how far from the background colour a pixel may be and still go (default 20) */
    tolerance: number;
    /** only the background connected to the picture's edges (keeps white eyes inside a white-backed sticker) */
    edgesOnly: boolean;
    /** 0..3 px of softened edge */
    soften: number;
    /** crop to the subject's box */
    trim: boolean;
};

export const CUTOUT_DEFAULTS = { tolerance: 20, edgesOnly: true, soften: 1, trim: true } as const;
/** Pixels with alpha under this are background whatever their colour (a picture that is already see-through). */
export const CUTOUT_CLEAR_ALPHA = 16;
/** After the cutout, a pixel counts as part of the subject (for the trim and the "nothing left" check) from this alpha. */
export const CUTOUT_SUBJECT_ALPHA = 8;
/** The longest side the Worker works on (the Images binding scales a bigger picture down first). */
export const CUTOUT_MAX_SIDE = 2048;

/** "#rgb" / "#rrggbb" (with or without #) -> [r, g, b], or null. */
export function parseHexColor(s: string): [number, number, number] | null {
    const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(s.trim());
    if (!m) return null;
    const h = m[1]!.length === 3 ? [...m[1]!].map((c) => c + c).join("") : m[1]!;
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}

/**
 * Takes the background out of `img` (in place on a copy) and returns the new picture, or null when nothing of the subject is
 * left. Distance is Euclidean in RGB, as a percentage of the black-to-white distance: a pixel is background when it is at
 * most `tolerance` % away from the key colour (or almost fully transparent already). `edgesOnly`: only background pixels
 * 4-connected to the border go. The softened edge lowers a subject pixel's alpha by up to 90 % by the share of background in
 * the (2 * soften + 1)² square around it.
 */
export function cutout(img: Rgba, o: CutoutOptions): Rgba | null {
    const { width: w, height: h } = img;
    const src = img.data;
    const n = w * h;
    const key = o.mode === "color" && o.color ? o.color : ([255, 255, 255] as const);
    const limit = (Math.max(0, Math.min(100, o.tolerance)) / 100) * Math.sqrt(3) * 255;
    const lim2 = limit * limit;
    const isBg = (p: number) => {
        const k = p * 4;
        if (src[k + 3]! < CUTOUT_CLEAR_ALPHA) return true;
        const dr = src[k]! - key[0], dg = src[k + 1]! - key[1], db = src[k + 2]! - key[2];
        return dr * dr + dg * dg + db * db <= lim2;
    };
    const bg = new Uint8Array(n);
    if (o.edgesOnly) {
        const stack: number[] = [];
        const seed = (p: number) => {
            if (!bg[p] && isBg(p)) {
                bg[p] = 1;
                stack.push(p);
            }
        };
        for (let x = 0; x < w; x++) {
            seed(x);
            seed((h - 1) * w + x);
        }
        for (let y = 0; y < h; y++) {
            seed(y * w);
            seed(y * w + w - 1);
        }
        while (stack.length) {
            const p = stack.pop()!;
            const x = p % w;
            if (x > 0) seed(p - 1);
            if (x < w - 1) seed(p + 1);
            if (p >= w) seed(p - w);
            if (p < n - w) seed(p + w);
        }
    } else {
        for (let p = 0; p < n; p++) if (isBg(p)) bg[p] = 1;
    }

    const out = new Uint8Array(src);
    const r = Math.max(0, Math.min(3, Math.round(o.soften)));
    // integral image of the background mask, for the share of background around each pixel in O(1)
    let sum: Uint32Array | null = null;
    if (r > 0) {
        sum = new Uint32Array((w + 1) * (h + 1));
        for (let y = 0; y < h; y++) {
            let row = 0;
            for (let x = 0; x < w; x++) {
                row += bg[y * w + x]!;
                sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1]! + row;
            }
        }
    }
    for (let p = 0; p < n; p++) {
        if (bg[p]) {
            out[p * 4 + 3] = 0;
            continue;
        }
        if (!sum) continue;
        const x = p % w, y = (p - x) / w;
        const x0 = Math.max(0, x - r), x1 = Math.min(w, x + r + 1), y0 = Math.max(0, y - r), y1 = Math.min(h, y + r + 1);
        const c = sum[y1 * (w + 1) + x1]! - sum[y0 * (w + 1) + x1]! - sum[y1 * (w + 1) + x0]! + sum[y0 * (w + 1) + x0]!;
        if (c > 0) {
            const total = (x1 - x0) * (y1 - y0);
            out[p * 4 + 3] = Math.round(out[p * 4 + 3]! * (1 - (0.9 * c) / total));
        }
    }
    const cut: Rgba = { width: w, height: h, data: out };
    const box = subjectBox(cut);
    if (!box) return null;
    return o.trim ? crop(cut, box) : cut;
}

/** The smallest box holding every pixel with alpha >= CUTOUT_SUBJECT_ALPHA, or null when there is none. */
export function subjectBox(img: Rgba): { x: number; y: number; w: number; h: number } | null {
    const { width: w, height: h, data } = img;
    let x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
            if (data[(y * w + x) * 4 + 3]! >= CUTOUT_SUBJECT_ALPHA) {
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
            }
        }
    }
    return x1 < 0 ? null : { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
}

export function crop(img: Rgba, b: { x: number; y: number; w: number; h: number }): Rgba {
    const out = new Uint8Array(b.w * b.h * 4);
    for (let y = 0; y < b.h; y++) out.set(img.data.subarray(((b.y + y) * img.width + b.x) * 4, ((b.y + y) * img.width + b.x + b.w) * 4), y * b.w * 4);
    return { width: b.w, height: b.h, data: out };
}

// ---- PNG ----------------------------------------------------------------------------------------------------------

const SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
export const isPng = (b: Uint8Array) => b.length >= 8 && SIG.every((v, i) => b[i] === v);

let CRC_TABLE: Uint32Array | null = null;
function crc32(bytes: Uint8Array): number {
    if (!CRC_TABLE) {
        CRC_TABLE = new Uint32Array(256);
        for (let i = 0; i < 256; i++) {
            let c = i;
            for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
            CRC_TABLE[i] = c >>> 0;
        }
    }
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

async function through(kind: "compress" | "decompress", data: Uint8Array): Promise<Uint8Array> {
    const stream = kind === "compress" ? new CompressionStream("deflate") : new DecompressionStream("deflate");
    const writer = stream.writable.getWriter();
    void writer.write(data).catch(() => {});
    void writer.close().catch(() => {});
    const chunks: Uint8Array[] = [];
    let total = 0;
    const reader = stream.readable.getReader();
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        total += value.length;
    }
    const out = new Uint8Array(total);
    let o = 0;
    for (const c of chunks) {
        out.set(c, o);
        o += c.length;
    }
    return out;
}

/** Width and height from a PNG's IHDR, or null. */
export function pngSize(b: Uint8Array): { width: number; height: number } | null {
    if (!isPng(b) || b.length < 24) return null;
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    if (String.fromCharCode(b[12]!, b[13]!, b[14]!, b[15]!) !== "IHDR") return null;
    return { width: v.getUint32(16), height: v.getUint32(20) };
}

/**
 * Decodes a non-interlaced PNG of bit depth 8 or 16 (grey, RGB, palette, grey + alpha, RGBA; tRNS applied) to RGBA 8-bit.
 * Throws on anything else (the Images binding writes 8-bit RGB(A)). `maxPixels` refuses a picture before it is inflated.
 */
export async function decodePng(b: Uint8Array, maxPixels = CUTOUT_MAX_SIDE * CUTOUT_MAX_SIDE): Promise<Rgba> {
    if (!isPng(b)) throw new Error("not a png");
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    let pos = 8;
    let w = 0, h = 0, depth = 0, type = 0, interlace = 0;
    let palette: Uint8Array | null = null;
    let trns: Uint8Array | null = null;
    const idat: Uint8Array[] = [];
    while (pos + 8 <= b.length) {
        const len = v.getUint32(pos);
        const t = String.fromCharCode(b[pos + 4]!, b[pos + 5]!, b[pos + 6]!, b[pos + 7]!);
        const d = b.subarray(pos + 8, pos + 8 + len);
        if (t === "IHDR") {
            w = v.getUint32(pos + 8);
            h = v.getUint32(pos + 12);
            depth = d[8]!;
            type = d[9]!;
            interlace = d[12]!;
        } else if (t === "PLTE") palette = d;
        else if (t === "tRNS") trns = d;
        else if (t === "IDAT") idat.push(d);
        else if (t === "IEND") break;
        pos += 12 + len;
    }
    if (!w || !h || w * h > maxPixels) throw new Error("png size");
    if (interlace !== 0 || (depth !== 8 && depth !== 16) || ![0, 2, 3, 4, 6].includes(type) || (type === 3 && depth !== 8)) throw new Error("png format");
    const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[type as 0 | 2 | 3 | 4 | 6]!;
    const bpp = (channels * depth) / 8;
    const stride = w * bpp;
    let total = 0;
    for (const c of idat) total += c.length;
    const z = new Uint8Array(total);
    let o = 0;
    for (const c of idat) {
        z.set(c, o);
        o += c.length;
    }
    const raw = await through("decompress", z);
    if (raw.length < (stride + 1) * h) throw new Error("png data");
    const px = new Uint8Array(stride * h);
    for (let y = 0; y < h; y++) {
        const f = raw[y * (stride + 1)]!;
        const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
        const cur = px.subarray(y * stride, (y + 1) * stride);
        const prev = y > 0 ? px.subarray((y - 1) * stride, y * stride) : null;
        for (let i = 0; i < stride; i++) {
            const a = i >= bpp ? cur[i - bpp]! : 0;
            const up = prev ? prev[i]! : 0;
            const c = prev && i >= bpp ? prev[i - bpp]! : 0;
            let x = line[i]!;
            if (f === 1) x += a;
            else if (f === 2) x += up;
            else if (f === 3) x += (a + up) >> 1;
            else if (f === 4) {
                const p = a + up - c, pa = Math.abs(p - a), pb = Math.abs(p - up), pc = Math.abs(p - c);
                x += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
            } else if (f !== 0) throw new Error("png filter");
            cur[i] = x & 0xff;
        }
    }
    const out = new Uint8Array(w * h * 4);
    const step = depth / 8; // bytes per sample; 16-bit keeps the high byte
    for (let p = 0; p < w * h; p++) {
        const s = p * bpp;
        const sample = (k: number) => px[s + k * step]!;
        let r: number, g: number, bl: number, al = 255;
        if (type === 0 || type === 4) {
            r = g = bl = sample(0);
            if (type === 4) al = sample(1);
            else if (trns && trns.length >= 2 && (depth === 8 ? trns[1] === r : (trns[0]! << 8 | trns[1]!) === (px[s]! << 8 | px[s + 1]!))) al = 0;
        } else if (type === 3) {
            const i = px[s]!;
            r = palette?.[i * 3] ?? 0;
            g = palette?.[i * 3 + 1] ?? 0;
            bl = palette?.[i * 3 + 2] ?? 0;
            al = trns && i < trns.length ? trns[i]! : 255;
        } else {
            r = sample(0);
            g = sample(1);
            bl = sample(2);
            if (type === 6) al = sample(3);
            else if (trns && trns.length >= 6 && depth === 8 && trns[1] === r && trns[3] === g && trns[5] === bl) al = 0;
        }
        out.set([r, g, bl, al], p * 4);
    }
    return { width: w, height: h, data: out };
}

/** RGBA 8-bit PNG, filter "sub" on every row (smaller than none for flat backgrounds, still trivial). */
export async function encodePng(img: Rgba): Promise<Uint8Array> {
    const { width: w, height: h, data } = img;
    const stride = w * 4;
    const raw = new Uint8Array((stride + 1) * h);
    for (let y = 0; y < h; y++) {
        const o = y * (stride + 1);
        raw[o] = 1;
        const row = data.subarray(y * stride, (y + 1) * stride);
        for (let i = 0; i < stride; i++) raw[o + 1 + i] = (row[i]! - (i >= 4 ? row[i - 4]! : 0)) & 0xff;
    }
    const z = await through("compress", raw);
    const chunk = (type: string, d: Uint8Array) => {
        const c = new Uint8Array(12 + d.length);
        const v = new DataView(c.buffer);
        v.setUint32(0, d.length);
        for (let i = 0; i < 4; i++) c[4 + i] = type.charCodeAt(i);
        c.set(d, 8);
        v.setUint32(8 + d.length, crc32(c.subarray(4, 8 + d.length)));
        return c;
    };
    const ihdr = new Uint8Array(13);
    const iv = new DataView(ihdr.buffer);
    iv.setUint32(0, w);
    iv.setUint32(4, h);
    ihdr[8] = 8;
    ihdr[9] = 6;
    const parts = [new Uint8Array(SIG), chunk("IHDR", ihdr), chunk("IDAT", z), chunk("IEND", new Uint8Array(0))];
    const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
    let o = 0;
    for (const p of parts) {
        out.set(p, o);
        o += p.length;
    }
    return out;
}
