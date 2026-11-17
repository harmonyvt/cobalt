// Width, height, duration and an RFC 6381 codecs string from the start of an ISO-BMFF file
// (mp4 / mov) or a WebM. Same idea as jpegSize: walk the bytes, never throw, and stop when the
// buffer runs out. A file whose `moov` sits past the bytes we were given comes back partial
// (no width, no codecs); `moovOffset` says where to read next.

export type Mp4Info = {
    width?: number;
    height?: number;
    duration?: number;
    codecs?: string;
};

// How much of a stored video the upload and the dimensions backfill read. `moov` is usually at the
// front; when it is not, `moovOffset` points at it and a second read of this size covers the header.
export const VIDEO_PROBE_BYTES = 2 * 1024 * 1024;
// The share page only needs the sample description. One small read, then one more at `moov` if it is at the end.
export const SHARE_CODEC_BYTES = 64 * 1024;

// VP9.2 10-bit PQ/BT.2020, the alternate we attach when a WebM carries no CodecPrivate.
export const VP9_HDR_CODECS = "vp09.02.10.10.01.09.16.09.01";

const CONTAINERS = new Set(["moov", "trak", "mdia", "minf", "stbl"]);
const VIDEO_FOURCC = new Set(["avc1", "avc3", "hvc1", "hev1", "av01", "vp09", "vp08"]);

type RawBox = { type: string; offset: number; header: number; size: number; complete: boolean };

const ascii = (b: Uint8Array, o: number, n: number): string => {
    let s = "";
    for (let i = 0; i < n; i++) {
        const c = b[o + i] ?? 0;
        if (c < 0x20 || c > 0x7e) return "";
        s += String.fromCharCode(c);
    }
    return s;
};

const u16 = (b: Uint8Array, o: number): number | null => (o + 2 <= b.length ? (b[o]! << 8) | b[o + 1]! : null);

const u32 = (b: Uint8Array, o: number): number | null =>
    o + 4 <= b.length ? ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0 : null;

// Fits in a JS number (files we probe are far smaller than 2^53).
const u64 = (b: Uint8Array, o: number): number | null => {
    const hi = u32(b, o);
    const lo = u32(b, o + 4);
    if (hi == null || lo == null) return null;
    return hi * 0x100000000 + lo;
};

// Top-level (or in-parent) boxes. A box whose body runs past `buf` is still reported, with
// `complete: false`, so a size in the header can locate `moov` past the bytes we hold.
function boxesIn(buf: Uint8Array, start: number, end: number): RawBox[] {
    const out: RawBox[] = [];
    let o = start;
    const limit = Math.min(end, buf.length);
    while (o + 8 <= limit) {
        const size32 = u32(buf, o);
        const type = ascii(buf, o + 4, 4);
        if (size32 == null || !type) break;
        let header = 8;
        let size = size32;
        if (size32 === 1) {
            const big = u64(buf, o + 8);
            if (big == null) break;
            header = 16;
            size = big;
        } else if (size32 === 0) {
            size = Math.max(header, end - o);
        }
        if (!Number.isFinite(size) || size < header) break;
        const complete = o + size <= buf.length && o + size <= end;
        out.push({ type, offset: o, header, size, complete });
        if (!complete) break;
        o += size;
    }
    return out;
}

// File offset of a `moov` that is not fully inside `head`, or null when the head already has it
// (or the layout does not say where it is). `fileSize` is the whole object.
export function moovOffset(head: Uint8Array, fileSize: number): number | null {
    if (!Number.isFinite(fileSize) || fileSize <= 0) return null;
    const top = boxesIn(head, 0, fileSize);
    const moov = top.find((b) => b.type === "moov");
    if (moov) return moov.complete ? null : moov.offset;
    for (const b of top) {
        const next = b.offset + b.size;
        if (!b.complete && next > head.length && next < fileSize) return next;
    }
    if (top.length > 0 && top.every((b) => b.complete)) {
        const last = top[top.length - 1]!;
        const next = last.offset + last.size;
        if (next >= head.length && next < fileSize) return next;
    }
    return null;
}

const bitReverse32 = (v: number): number => {
    let r = 0;
    for (let i = 0; i < 32; i++) {
        r = ((r << 1) | (v & 1)) >>> 0;
        v >>>= 1;
    }
    return r >>> 0;
};

const hex2 = (n: number) => n.toString(16).toUpperCase().padStart(2, "0");
const dec2 = (n: number) => String(n).padStart(2, "0");

// ISO 14496-15 AVC: avc1.PPCCLL
function avcCodecs(brand: string, body: Uint8Array): string | undefined {
    if (body.length < 4 || body[0] !== 1) return undefined;
    return `${brand}.${hex2(body[1]!)}${hex2(body[2]!)}${hex2(body[3]!)}`;
}

// ISO 14496-15 Annex E. The compatibility flags are stored MSB-first (flag 0 is the high bit) and
// written in the codecs string LSB-first, which is why Main 10's 0x20000000 becomes "4":
// hvc1.2.4.L120.90
function hevcCodecs(brand: string, body: Uint8Array): string | undefined {
    if (body.length < 13 || body[0] !== 1) return undefined;
    const space = (body[1]! >> 6) & 3;
    const tier = (body[1]! >> 5) & 1;
    const profile = body[1]! & 31;
    const compat = u32(body, 2);
    if (compat == null) return undefined;
    const level = body[12]!;
    const prefix = ["", "A", "B", "C"][space] ?? "";
    let s = `${brand}.${prefix}${profile}.${bitReverse32(compat).toString(16)}.${tier ? "H" : "L"}${level}`;
    let last = 11;
    while (last >= 6 && body[last] === 0) last--;
    for (let i = 6; i <= last; i++) s += `.${hex2(body[i]!)}`;
    return s;
}

type Colr = { cp: number; tc: number; mc: number; full: number };

function parseColr(body: Uint8Array): Colr | null {
    if (body.length < 11 || ascii(body, 0, 4) !== "nclx") return null;
    const cp = u16(body, 4);
    const tc = u16(body, 6);
    const mc = u16(body, 8);
    if (cp == null || tc == null || mc == null) return null;
    return { cp, tc, mc, full: (body[10]! >> 7) & 1 };
}

// https://aomediacodec.github.io/av1-isobmff/#codecsparam — colour fields only when a colr box says them.
function av1Codecs(body: Uint8Array, colr: Colr | null): string | undefined {
    if (body.length < 4 || (body[0]! & 0x80) === 0) return undefined;
    const profile = (body[1]! >> 5) & 7;
    const level = body[1]! & 31;
    const b2 = body[2]!;
    const tier = (b2 >> 7) & 1;
    const high = (b2 >> 6) & 1;
    const twelve = (b2 >> 5) & 1;
    const mono = (b2 >> 4) & 1;
    const subX = (b2 >> 3) & 1;
    const subY = (b2 >> 2) & 1;
    const pos = b2 & 3;
    const bitDepth = high === 0 ? 8 : twelve ? 12 : 10;
    let s = `av01.${profile}.${dec2(level)}${tier ? "H" : "M"}.${dec2(bitDepth)}`;
    if (colr) s += `.${mono}.${subX}${subY}${pos}.${dec2(colr.cp)}.${dec2(colr.tc)}.${dec2(colr.mc)}.${colr.full}`;
    return s;
}

// https://www.webmproject.org/vp9/mp4/ — the vpcC record, also VP9's WebM CodecPrivate.
export function vp9Codecs(body: Uint8Array): string | undefined {
    if (body.length < 6) return undefined;
    const bitDepth = body[2]! >> 4;
    const chroma = (body[2]! >> 1) & 7;
    const full = body[2]! & 1;
    if (bitDepth !== 8 && bitDepth !== 10 && bitDepth !== 12) return undefined;
    return `vp09.${dec2(body[0]!)}.${dec2(body[1]!)}.${dec2(bitDepth)}.${dec2(chroma)}.${dec2(body[3]!)}.${dec2(body[4]!)}.${dec2(body[5]!)}.${dec2(full)}`;
}

// Visual sample entry: 8 byte box header, then 78 bytes, then child boxes (avcC / hvcC / av1C / vpcC / colr).
function parseSampleEntry(buf: Uint8Array, entry: RawBox): { codecs?: string } {
    const payload = entry.offset + entry.header;
    const end = Math.min(entry.offset + entry.size, buf.length);
    const childAt = payload + 78;
    if (childAt >= end) return {};
    let colr: Colr | null = null;
    let av1: Uint8Array | null = null;
    let codecs: string | undefined;
    for (const c of boxesIn(buf, childAt, end)) {
        const body = buf.subarray(c.offset + c.header, Math.min(c.offset + c.size, end));
        if ((entry.type === "avc1" || entry.type === "avc3") && c.type === "avcC") codecs = avcCodecs(entry.type, body);
        else if ((entry.type === "hvc1" || entry.type === "hev1") && c.type === "hvcC") codecs = hevcCodecs(entry.type, body);
        else if (entry.type === "av01" && c.type === "av1C") av1 = body;
        else if ((entry.type === "vp09" || entry.type === "vp08") && c.type === "vpcC") codecs = vp9Codecs(body);
        else if (c.type === "colr") colr = parseColr(body) ?? colr;
        if (!c.complete) break;
    }
    if (av1) codecs = av1Codecs(av1, colr);
    return { codecs };
}

type Trak = { video: boolean; width?: number; height?: number; codecs?: string };

function parseTkhd(body: Uint8Array): { width?: number; height?: number } {
    if (body.length < 4) return {};
    const at = body[0] === 1 ? 88 : 76;
    const w = u32(body, at);
    const h = u32(body, at + 4);
    if (w == null || h == null) return {};
    const width = Math.round(w / 65536);
    const height = Math.round(h / 65536);
    return { width: width > 0 ? width : undefined, height: height > 0 ? height : undefined };
}

function parseMvhd(body: Uint8Array): number | undefined {
    if (body.length < 4) return undefined;
    const v1 = body[0] === 1;
    const timescale = u32(body, v1 ? 20 : 12);
    const dur = v1 ? u64(body, 24) : u32(body, 16);
    if (timescale == null || !timescale || dur == null) return undefined;
    if (!v1 && dur === 0xffffffff) return undefined;
    const seconds = dur / timescale;
    if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
    return Math.round(seconds * 1000) / 1000;
}

function parseStsd(buf: Uint8Array, payload: number, end: number, trak: Trak): void {
    if (payload + 8 > end) return;
    for (const entry of boxesIn(buf, payload + 8, end)) {
        if (!VIDEO_FOURCC.has(entry.type)) {
            if (!entry.complete) break;
            continue;
        }
        trak.video = true;
        const got = parseSampleEntry(buf, entry);
        if (got.codecs) trak.codecs = got.codecs;
        if (!trak.width) {
            const p = entry.offset + entry.header;
            const w = u16(buf, p + 24);
            const h = u16(buf, p + 26);
            if (w && h) {
                trak.width = w;
                trak.height = h;
            }
        }
        if (!entry.complete) break;
    }
}

// null when `bytes` is not ISO-BMFF. An object with missing fields when the header is cut off
// (`moov` at the end of the file, or a short read): width, height, duration and codecs stay unset.
export function mp4Info(bytes: Uint8Array): Mp4Info | null {
    if (bytes.length < 8) return null;
    const top = boxesIn(bytes, 0, bytes.length);
    if (top.length === 0) return null;
    let duration: number | undefined;
    const videos: Trak[] = [];
    const walk = (start: number, end: number, trak: Trak | null) => {
        for (const box of boxesIn(bytes, start, end)) {
            const payload = box.offset + box.header;
            const boxEnd = Math.min(box.offset + box.size, bytes.length, end);
            if (box.type === "mvhd" && !trak) {
                duration = parseMvhd(bytes.subarray(payload, boxEnd)) ?? duration;
            } else if (box.type === "trak") {
                const t: Trak = { video: false };
                walk(payload, boxEnd, t);
                if (t.video || t.codecs) videos.push(t);
            } else if (trak && box.type === "tkhd") {
                const d = parseTkhd(bytes.subarray(payload, boxEnd));
                if (d.width) trak.width = d.width;
                if (d.height) trak.height = d.height;
            } else if (trak && box.type === "hdlr") {
                if (ascii(bytes, payload + 8, 4) === "vide") trak.video = true;
            } else if (trak && box.type === "stsd") {
                parseStsd(bytes, payload, boxEnd, trak);
            } else if (CONTAINERS.has(box.type)) {
                walk(payload, boxEnd, trak);
            }
            if (!box.complete) break;
        }
    };
    walk(0, bytes.length, null);
    const v = videos.find((t) => t.codecs) ?? videos.find((t) => t.video);
    const info: Mp4Info = {};
    if (v?.width) info.width = v.width;
    if (v?.height) info.height = v.height;
    if (v?.codecs) info.codecs = v.codecs;
    if (duration != null) info.duration = duration;
    return info;
}

export type RangeRead = (offset: number, length: number) => Promise<{ bytes: Uint8Array; size: number } | null>;

const merge = (a: Mp4Info | null, b: Mp4Info | null): Mp4Info | null => {
    if (!a) return b;
    if (!b) return a;
    const out: Mp4Info = {};
    const width = a.width ?? b.width;
    const height = a.height ?? b.height;
    const duration = a.duration ?? b.duration;
    const codecs = a.codecs ?? b.codecs;
    if (width) out.width = width;
    if (height) out.height = height;
    if (duration != null) out.duration = duration;
    if (codecs) out.codecs = codecs;
    return out;
};

// `read(offset, length)` is a ranged read of one object; `size` on the result is the whole object.
// The second read happens only when `moov` is not in the first window.
export async function readMp4Info(read: RangeRead, window: number): Promise<Mp4Info | null> {
    let head: { bytes: Uint8Array; size: number } | null;
    try {
        head = await read(0, window);
    } catch {
        return null;
    }
    if (!head || head.bytes.length === 0) return null;
    const first = mp4Info(head.bytes);
    if (!first) return null;
    const off = moovOffset(head.bytes, head.size);
    if (off == null) return first;
    let more: { bytes: Uint8Array; size: number } | null = null;
    try {
        more = await read(off, window);
    } catch {
        return first;
    }
    if (!more) return first;
    return merge(first, mp4Info(more.bytes));
}

// ---- WebM (EBML), only what an alternate copy needs ----------------------------------------------

const ebmlLen = (first: number): number => {
    for (let i = 0; i < 8; i++) if (first & (0x80 >> i)) return i + 1;
    return 0;
};

// `mask` strips the length marker (element sizes). Ids keep it.
function readVint(buf: Uint8Array, o: number, mask: boolean): { n: number; len: number } | null {
    if (o >= buf.length) return null;
    const len = ebmlLen(buf[o]!);
    if (len === 0 || o + len > buf.length) return null;
    let n = mask ? buf[o]! & ((0xff >> len) & 0xff) : buf[o]!;
    for (let i = 1; i < len; i++) n = n * 256 + buf[o + i]!;
    if (!Number.isFinite(n)) return null;
    return { n, len };
}

const ID_SEGMENT = 0x18538067;
const ID_INFO = 0x1549a966;
const ID_TRACKS = 0x1654ae6b;
const ID_TRACK = 0xae;
const ID_VIDEO = 0xe0;
const ID_CODEC = 0x86;
const ID_PRIVATE = 0x63a2;
const ID_WIDTH = 0xb0;
const ID_HEIGHT = 0xba;
const ID_DURATION = 0x4489;
const ID_SCALE = 0x2ad7b1;
const CONTAINERS_EBML = new Set([0x1a45dfa3, ID_SEGMENT, ID_INFO, ID_TRACKS, ID_TRACK, ID_VIDEO]);

const uintOf = (body: Uint8Array): number | null => {
    if (body.length === 0 || body.length > 6) return null;
    let n = 0;
    for (const b of body) n = n * 256 + b;
    return n;
};

const floatOf = (body: Uint8Array): number | null => {
    if (body.length !== 4 && body.length !== 8) return null;
    const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
    const n = body.length === 8 ? view.getFloat64(0) : view.getFloat32(0);
    return Number.isFinite(n) ? n : null;
};

// null when `bytes` is not a WebM. Codecs only when a VP9 CodecPrivate is in the bytes we have.
export function webmInfo(bytes: Uint8Array): Mp4Info | null {
    if (bytes.length < 4 || bytes[0] !== 0x1a || bytes[1] !== 0x45 || bytes[2] !== 0xdf || bytes[3] !== 0xa3) return null;
    let width: number | undefined;
    let height: number | undefined;
    let durationUnits: number | undefined;
    let scale = 1_000_000;
    let codecs: string | undefined;
    let codecId = "";
    const walk = (start: number, end: number) => {
        let o = start;
        while (o + 2 <= end) {
            const id = readVint(bytes, o, false);
            if (!id) return;
            const size = readVint(bytes, o + id.len, true);
            if (!size) return;
            const dataAt = o + id.len + size.len;
            // an all-ones size means "unknown": the element runs to the parent end (a size of 0 is empty)
            const unknown = size.n > 0 && size.n >= 2 ** (7 * size.len) - 1;
            const dataEnd = unknown ? end : Math.min(end, dataAt + size.n);
            if (dataAt > end) return;
            const body = bytes.subarray(dataAt, dataEnd);
            if (id.n === ID_TRACK) codecId = "";
            if (CONTAINERS_EBML.has(id.n)) walk(dataAt, dataEnd);
            else if (id.n === ID_CODEC) codecId = new TextDecoder().decode(body);
            else if (id.n === ID_PRIVATE && (codecId === "V_VP9" || codecId === "V_VP8")) codecs = vp9Codecs(body) ?? codecs;
            else if (id.n === ID_WIDTH) width = uintOf(body) ?? width;
            else if (id.n === ID_HEIGHT) height = uintOf(body) ?? height;
            else if (id.n === ID_DURATION) durationUnits = floatOf(body) ?? durationUnits;
            else if (id.n === ID_SCALE) scale = uintOf(body) ?? scale;
            if (unknown) return;
            o = dataAt + size.n;
        }
    };
    walk(0, bytes.length);
    const info: Mp4Info = {};
    if (width && width > 0) info.width = width;
    if (height && height > 0) info.height = height;
    if (durationUnits != null && scale > 0) {
        const seconds = (durationUnits * scale) / 1e9;
        if (Number.isFinite(seconds) && seconds > 0) info.duration = Math.round(seconds * 1000) / 1000;
    }
    if (codecs) info.codecs = codecs;
    return info;
}
