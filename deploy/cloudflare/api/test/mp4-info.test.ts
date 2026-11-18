// ISO-BMFF / WebM headers: hand-built boxes lock the codecs strings, and the tiny ffmpeg fixtures
// (test/fixtures/hdr, 64x64, a fraction of a second) check a real hvcC, av1C and WebM.
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { alphaCutIn, isQuickTime, moovOffset, mp4Info, readMp4Info, readQuicktimeAlphaCut, vp9Codecs, webmInfo, VP9_HDR_CODECS } from "../src/mp4-info";

const dir = path.join(import.meta.dirname, "fixtures/hdr");
const file = (name: string) => new Uint8Array(readFileSync(path.join(dir, name)));

const concat = (...parts: Uint8Array[]) => {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let o = 0;
    for (const p of parts) {
        out.set(p, o);
        o += p.length;
    }
    return out;
};
const box = (type: string, payload: Uint8Array) => {
    const out = new Uint8Array(8 + payload.length);
    new DataView(out.buffer).setUint32(0, out.length);
    out.set(new TextEncoder().encode(type), 4);
    out.set(payload, 8);
    return out;
};
const u32 = (n: number) => {
    const b = new Uint8Array(4);
    new DataView(b.buffer).setUint32(0, n);
    return b;
};
const zeros = (n: number) => new Uint8Array(n);

// version 0 movie header: timescale 1000, duration `ms` (the parser reads the first 20 bytes).
const mvhd = (ms: number) => {
    const p = zeros(20);
    const v = new DataView(p.buffer);
    v.setUint32(12, 1000);
    v.setUint32(16, ms);
    return box("mvhd", p);
};
// version 0 track header. Width and height are 16.16 fixed, at byte 76.
const tkhd = (w: number, h: number) => {
    const p = zeros(84);
    const v = new DataView(p.buffer);
    v.setUint32(76, w * 65536);
    v.setUint32(80, h * 65536);
    return box("tkhd", p);
};
const hdlr = box("hdlr", concat(zeros(8), new TextEncoder().encode("vide")));

// A visual sample entry: 78 bytes of header, then the codec boxes.
const sample = (fourcc: string, children: Uint8Array) => box(fourcc, concat(zeros(78), children));
const stsd = (entry: Uint8Array) => box("stsd", concat(zeros(4), u32(1), entry));
const videoTrak = (entry: Uint8Array, w: number, h: number) => box("trak", concat(tkhd(w, h), box("mdia", concat(hdlr, box("minf", box("stbl", stsd(entry)))))));
const movie = (entry: Uint8Array, w: number, h: number, ms: number) => concat(box("ftyp", new TextEncoder().encode("isom")), box("moov", concat(mvhd(ms), videoTrak(entry, w, h))));

describe("mp4Info", () => {
    it("builds hvc1.2.4.L120.90 from a Main 10 hvcC (flag 2 stored MSB-first)", () => {
        // profile_idc 2, compatibility 0x20000000 (bit-reverses to 4), constraint 0x90, level 120
        const hvcC = box("hvcC", Uint8Array.from([0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78]));
        expect(mp4Info(movie(sample("hvc1", hvcC), 676, 676, 1500))).toEqual({
            width: 676,
            height: 676,
            duration: 1.5,
            codecs: "hvc1.2.4.L120.90",
        });
        const hev1 = mp4Info(movie(sample("hev1", hvcC), 16, 16, 1000));
        expect(hev1?.codecs).toBe("hev1.2.4.L120.90");
    });

    it("builds avc1.64001F from avcC and av01 from av1C plus a colr box", () => {
        const avcC = box("avcC", Uint8Array.from([0x01, 0x64, 0x00, 0x1f, 0xff]));
        expect(mp4Info(movie(sample("avc1", avcC), 320, 240, 2000))?.codecs).toBe("avc1.64001F");
        // profile 0, level 0, 10-bit, 4:2:0 (subsampling 1,1 position 0), tier M. colr nclx BT.2020 / PQ.
        const av1C = box("av1C", Uint8Array.from([0x81, 0x00, 0x4c, 0x00]));
        const colr = box("colr", Uint8Array.from([0x6e, 0x63, 0x6c, 0x78, 0x00, 0x09, 0x00, 0x10, 0x00, 0x09, 0x00]));
        expect(mp4Info(movie(sample("av01", concat(av1C, colr)), 64, 64, 200))?.codecs).toBe("av01.0.00M.10.0.110.09.16.09.0");
        const vpc = Uint8Array.from([0x02, 0x0a, 0xa3, 0x09, 0x10, 0x09]);
        expect(vp9Codecs(vpc)).toBe(VP9_HDR_CODECS);
        expect(mp4Info(movie(sample("vp09", box("vpcC", vpc)), 64, 64, 200))?.codecs).toBe(VP9_HDR_CODECS);
    });

    it("returns null for bytes that are not a file, and a partial object when moov is past the buffer", () => {
        expect(mp4Info(new Uint8Array(0))).toBeNull();
        expect(mp4Info(Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8]))).toBeNull();
        expect(mp4Info(new Uint8Array(64).fill(9))).toBeNull();
        const hvcC = box("hvcC", Uint8Array.from([0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78]));
        const moov = box("moov", concat(mvhd(1500), videoTrak(sample("hvc1", hvcC), 676, 676)));
        const file = concat(box("ftyp", new TextEncoder().encode("isom")), box("mdat", new Uint8Array(400)), moov);
        const head = file.subarray(0, 64);
        expect(mp4Info(head)).toEqual({});
        const off = moovOffset(head, file.length);
        expect(off).toBeGreaterThan(64);
        expect(mp4Info(file.subarray(off!))).toMatchObject({ width: 676, height: 676, codecs: "hvc1.2.4.L120.90" });
    });

    it("reads a moov that sits at the end of a real HEVC file through a short first window", async () => {
        const hevc = file("hevc.mp4");
        const end = file("hevc-end.mp4");
        expect(mp4Info(hevc)).toMatchObject({ width: 64, height: 64, duration: 0.2, codecs: "hvc1.2.4.L30.90" });
        // faststart, and the whole header is in the first 8 KB: nothing left to fetch
        expect(moovOffset(hevc.subarray(0, 8192), hevc.length)).toBeNull();
        // a 64-byte peek cuts the moov off, so the next read starts where that box starts
        expect(moovOffset(hevc.subarray(0, 64), hevc.length)).toBe(28);
        // moov after mdat: 64 bytes do not hold it
        expect(mp4Info(end.subarray(0, 64))).toEqual({});
        const off = moovOffset(end.subarray(0, 64), end.length);
        expect(off).toBe(138);
        const read = async (offset: number, length: number) => ({ bytes: end.subarray(offset, offset + length), size: end.length });
        expect(await readMp4Info(read, 8192)).toEqual({ width: 64, height: 64, duration: 0.2, codecs: "hvc1.2.4.L30.90" });
    });

    it("reads an AV1 10-bit PQ mp4 from ffmpeg", () => {
        expect(mp4Info(file("av1.mp4"))).toMatchObject({
            width: 64,
            height: 64,
            duration: 0.2,
            codecs: "av01.0.00M.10.0.110.09.16.09.0",
        });
    });
});

describe("quicktime alpha cuts", () => {
    const qt = (entry: Uint8Array, ms = 1500) => concat(box("ftyp", concat(new TextEncoder().encode("qt  "), u32(0), new TextEncoder().encode("qt  "))), box("moov", concat(mvhd(ms), videoTrak(entry, 64, 64))));
    const visual = (fourcc: string, depth: number, name = "", children = new Uint8Array()) => {
        const head = zeros(78);
        const view = new DataView(head.buffer);
        view.setUint16(24, 320);
        view.setUint16(26, 180);
        view.setUint16(74, depth);
        if (name) {
            const bytes = new TextEncoder().encode(name).subarray(0, 31);
            head[42] = bytes.length;
            head.set(bytes, 43);
        }
        return box(fourcc, concat(head, children));
    };

    it("accepts ProRes 4444 and 4444 XQ, and refuses 422 and a non-QuickTime brand", () => {
        const prores = qt(visual("ap4h", 32));
        expect(isQuickTime(prores)).toBe(true);
        expect(alphaCutIn(prores)).toMatchObject({ codec: "prores4444", codecs: "ap4h", width: 320, height: 180, duration: 1.5 });
        expect(alphaCutIn(qt(visual("ap4x", 32)))).toMatchObject({ codec: "prores4444", codecs: "ap4x" });
        expect(alphaCutIn(qt(visual("apcn", 24)))).toBeNull();
        expect(isQuickTime(movie(sample("ap4h", new Uint8Array()), 64, 64, 1000))).toBe(false);
        expect(alphaCutIn(movie(sample("ap4h", new Uint8Array()), 64, 64, 1000))).toMatchObject({ codecs: "ap4h" });
    });

    it("accepts HEVC only when the sample entry says it has alpha", () => {
        const hvcC = box("hvcC", Uint8Array.from([0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78]));
        expect(alphaCutIn(qt(visual("hvc1", 24, "HEVC")))).toBeNull();
        expect(alphaCutIn(qt(visual("hvc1", 32, "", hvcC)))).toMatchObject({ codec: "hevc_alpha", codecs: "hvc1.2.4.L120.90", width: 320, height: 180 });
        expect(alphaCutIn(qt(visual("hev1", 24, "HEVC Video with Alpha")))).toMatchObject({ codec: "hevc_alpha", codecs: "hev1" });
        expect(alphaCutIn(qt(visual("muxa", 24)))).toMatchObject({ codec: "hevc_alpha", codecs: "muxa" });
        const auxi = box("auxi", new TextEncoder().encode("urn:mpeg:mpegB:cicp:systems:auxiliary:alpha"));
        expect(alphaCutIn(qt(visual("hvc1", 24, "", auxi)))).toMatchObject({ codec: "hevc_alpha" });
        expect(alphaCutIn(qt(visual("avc1", 32)))).toBeNull();
    });

    it("reads a moov that sits past the first window", async () => {
        const entry = visual("ap4h", 32);
        const moov = box("moov", concat(mvhd(1500), videoTrak(entry, 64, 64)));
        const fileBytes = concat(box("ftyp", concat(new TextEncoder().encode("qt  "), u32(0))), box("mdat", new Uint8Array(800)), moov);
        const read = async (offset: number, length: number) => ({ bytes: fileBytes.subarray(offset, offset + length), size: fileBytes.length });
        expect(await readQuicktimeAlphaCut(read, 512)).toMatchObject({ codec: "prores4444", codecs: "ap4h", width: 320, height: 180, duration: 1.5 });
        expect(await readQuicktimeAlphaCut(async () => ({ bytes: file("av1.mp4"), size: file("av1.mp4").length }), 4096)).toBeNull();
    });
});

describe("webmInfo", () => {
    it("reads the ffmpeg VP9 file's size and duration, and a CodecPrivate when one is present", () => {
        const info = webmInfo(file("vp9.webm"));
        expect(info).toMatchObject({ width: 64, height: 64, duration: 0.2 });
        expect(info?.codecs).toBeUndefined();
        expect(webmInfo(Uint8Array.from([0, 1, 2, 3]))).toBeNull();
        // EBML (empty) + Segment + Tracks + TrackEntry + CodecID V_VP9 + the vpcC bytes above + Video size
        const vint = (n: number) => Uint8Array.from([0x80 | n]); // 1-byte size, n < 127
        const id = (bytes: number[], payload: Uint8Array) => concat(Uint8Array.from(bytes), vint(payload.length), payload);
        const text = (s: string) => new TextEncoder().encode(s);
        const video = id([0xe0], concat(id([0xb0], Uint8Array.from([0x40])), id([0xba], Uint8Array.from([0x40]))));
        const track = id([0xae], concat(id([0x86], text("V_VP9")), id([0x63, 0xa2], Uint8Array.from([0x02, 0x0a, 0xa3, 0x09, 0x10, 0x09])), video));
        const tracks = id([0x16, 0x54, 0xae, 0x6b], track);
        const segment = id([0x18, 0x53, 0x80, 0x67], tracks);
        const ebml = id([0x1a, 0x45, 0xdf, 0xa3], id([0x42, 0x82], text("webm")));
        expect(webmInfo(concat(ebml, segment))).toMatchObject({ width: 64, height: 64, codecs: VP9_HDR_CODECS });
    });
});
