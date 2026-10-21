import assert from "node:assert/strict";
import { test } from "node:test";
import { displaySize, exifOrientation, orientationFilters, parseInfo, sniffKind } from "../probe.js";
import { withExifOrientation } from "./media.js";

const IPHONE = `Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'IMG_0001.MOV':
  Metadata:
    major_brand     : qt
  Duration: 00:00:07.42, start: 0.000000, bitrate: 23455 kb/s
  Stream #0:0[0x1](und): Video: hevc (Main 10) (hvc1 / 0x31637668), yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67), 1920x1080, 23227 kb/s, 29.99 fps, 30 tbr, 600 tbn (default)
    Side data:
      displaymatrix: rotation of -90.00 degrees
  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 62 kb/s (default)
  Stream #0:2[0x3](und): Data: none (mebx / 0x7862656D), 0 kb/s`;

test("parseInfo: an iPhone HLG clip, rotated, with mono audio", () => {
    const i = parseInfo(IPHONE);
    assert.equal(i.duration, 7.42);
    assert.deepEqual([i.width, i.height, i.rotation], [1080, 1920, 270]);
    assert.deepEqual([i.hasVideo, i.hasAudio, i.channels], [true, true, 1]);
    assert.deepEqual([i.transfer, i.hdr, i.videoCodec], ["arib-std-b67", true, "hevc"]);
    assert.deepEqual(i.sar, [1, 1]);
});

test("parseInfo: PQ, SDR, SAR, stereo, 5.1, no audio, a GIF, an audio-only file", () => {
    assert.equal(parseInfo("Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160, 30 fps").transfer, "smpte2084");
    assert.equal(parseInfo("Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160, 30 fps").hdr, true);
    const sdr = parseInfo("Stream #0:0: Video: h264 (High), yuv420p(tv, bt709, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 30 fps\n  Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp");
    assert.deepEqual([sdr.transfer, sdr.hdr, sdr.channels], [null, false, 2]);
    const unspecified = parseInfo("Stream #0:0: Video: h264, yuv420p(tv, bt709/unknown/unknown), 1280x720, 30 fps");
    assert.equal(unspecified.hdr, false);
    const ana = parseInfo("Stream #0:0: Video: mpeg2video, yuv420p(tv, bt470bg), 720x480 [SAR 32:27 DAR 16:9], 29.97 fps");
    assert.deepEqual(ana.sar, [32, 27]);
    assert.equal(parseInfo("Stream #0:1: Audio: ac3, 48000 Hz, 5.1(side), fltp").channels, 6);
    const none = parseInfo("  Duration: 00:00:10.00, start: 0.0\n  Stream #0:0: Video: h264, yuv420p, 320x180, 30 fps");
    assert.deepEqual([none.hasAudio, none.channels], [false, null]);
    const gif = parseInfo("  Duration: N/A, start: 0.000000, bitrate: N/A\n  Stream #0:0: Video: gif, bgra, 64x64, 10 fps, 10 tbr, 100 tbn");
    assert.deepEqual([gif.duration, gif.width, gif.height, gif.hasVideo], [null, 64, 64, true]);
    const a = parseInfo("  Duration: 00:00:01.00, start: 0.0\n  Stream #0:0: Audio: aac (LC), 44100 Hz, stereo, fltp");
    assert.deepEqual([a.hasVideo, a.width, a.hasAudio], [false, null, true]);
    // cover art is not a video
    const cover = parseInfo("Stream #0:0: Audio: mp3, 44100 Hz, stereo\n  Stream #0:1: Video: mjpeg (Baseline), yuvj420p, 500x500, 90k tbr (attached pic)");
    assert.equal(cover.hasVideo, false);
    // 0x31637661 style hex is not a size
    assert.deepEqual([parseInfo("Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 640x360, 30 fps").width], [640]);
    assert.equal(parseInfo("").duration, null);
    // rotation 90 swaps the size and the pixel shape; 180 does not
    const r90 = parseInfo("Stream #0:0: Video: h264, yuv420p, 640x360 [SAR 4:3 DAR 16:9], 30 fps\n    displaymatrix: rotation of 90.00 degrees");
    assert.deepEqual([r90.width, r90.height, r90.sar], [360, 640, [3, 4]]);
    const r180 = parseInfo("Stream #0:0: Video: h264, yuv420p, 640x360, 30 fps\n    displaymatrix: rotation of 180.00 degrees");
    assert.deepEqual([r180.width, r180.height], [640, 360]);
    // side data of a LATER stream does not rotate the video
    const later = parseInfo("Stream #0:0: Video: h264, yuv420p, 640x360, 30 fps\n  Stream #0:1: Data: none\n    displaymatrix: rotation of 90.00 degrees");
    assert.deepEqual([later.width, later.height], [640, 360]);
});

test("displaySize keeps the (rotated) width and changes the height for non-square pixels", () => {
    assert.deepEqual(displaySize(720, 480, [1, 1]), { height: 480, squareFrom: null, width: 720 });
    assert.deepEqual(displaySize(720, 480, [32, 27]), { height: 405, squareFrom: { h: 480, w: 720 }, width: 720 });
    assert.deepEqual(displaySize(360, 360, [4, 3]), { height: 270, squareFrom: { h: 360, w: 360 }, width: 360 });
    assert.equal(displaySize(10, 1, [2, 1]).height, 2);
});

test("sniffKind reads the bytes, never a name", () => {
    const b = (/** @type {string} */ s) => Buffer.from(s, "latin1");
    assert.equal(sniffKind(b("GIF89a\x01\x00")), "gif");
    assert.equal(sniffKind(b("GIF87a")), "gif");
    assert.equal(sniffKind(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0])), "jpeg");
    assert.equal(sniffKind(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0])), "png");
    assert.equal(sniffKind(b("\0\0\0\x18ftypisom\0\0\0\0")), "mp4");
    assert.equal(sniffKind(b("\0\0\0\x14ftypqt  \0\0\0\0")), "mp4");
    assert.equal(sniffKind(b("\0\0\0\x14ftypM4V \0\0\0\0")), "mp4");
    assert.equal(sniffKind(b("\0\0\0\x08wide\0\0\0\x10mdat")), "mp4", "old QuickTime");
    assert.equal(sniffKind(b("\0\0\0\x08free\0\0\0\x10moov")), "mp4");
    assert.equal(sniffKind(b("\0\0\0\x10moov\0\0\0\0\0\0\0\0")), "mp4");
    assert.equal(sniffKind(b("\0\0\0\x18ftypheic\0\0\0\0")), null, "a HEIC still");
    assert.equal(sniffKind(b("\0\0\0\x18ftypM4A \0\0\0\0")), null, "audio only");
    assert.equal(sniffKind(Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0])), null, "webm / matroska");
    assert.equal(sniffKind(b("RIFF\0\0\0\0WEBPVP8 ")), null, "webp");
    assert.equal(sniffKind(Buffer.alloc(0)), null);
    assert.equal(sniffKind(b("<html>")), null);
});

test("exifOrientation: all eight values, both byte orders, and the cases with none", () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9]);
    for (let o = 1; o <= 8; o++) assert.equal(exifOrientation(withExifOrientation(jpeg, o)), o);
    assert.equal(exifOrientation(jpeg), 1, "no EXIF");
    assert.equal(exifOrientation(withExifOrientation(jpeg, 0)), 1, "0 is not an orientation");
    assert.equal(exifOrientation(withExifOrientation(jpeg, 9)), 1);
    // little-endian TIFF
    const tiff = Buffer.from([0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    const body = Buffer.concat([Buffer.from("Exif\0\0", "latin1"), tiff]);
    const le = Buffer.concat([jpeg.subarray(0, 2), Buffer.from([0xff, 0xe1, (body.length + 2) >> 8, (body.length + 2) & 255]), body, jpeg.subarray(2)]);
    assert.equal(exifOrientation(le), 8);
    // truncated or garbage: 1, never a throw
    assert.equal(exifOrientation(withExifOrientation(jpeg, 6).subarray(0, 20)), 1);
    assert.equal(exifOrientation(Buffer.from("not a jpeg")), 1);
    assert.equal(exifOrientation(Buffer.alloc(0)), 1);
});

test("orientationFilters undo EXIF 1..8", () => {
    assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 8, 9].map((o) => orientationFilters(o).join(",")), ["", "hflip", "hflip,vflip", "vflip", "transpose=0", "transpose=1", "transpose=3", "transpose=2", ""]);
});

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { FFMPEG, ff, ffmpegAvailable } from "./media.js";

const pil = spawnSync("python3", ["-I", "-c", "import PIL"]).status === 0;
test("EXIF orientations 1..8 match Pillow's exif_transpose pixel for pixel (within JPEG noise)", { skip: !ffmpegAvailable() || !pil ? "ffmpeg or python3 + Pillow missing" : false }, () => {
    const dir = mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-exif-"));
    try {
        const base = path.join(dir, "base.jpg");
        // asymmetric: red grows to the right, green grows downward
        ff(["-f", "lavfi", "-i", "color=c=black:s=48x32,format=rgb24,geq=r='X*5':g='Y*7':b='40'", "-frames:v", "1", "-q:v", "1", base]);
        const jpeg = readFileSync(base);
        const check = path.join(dir, "check.py");
        writeFileSync(check, `import sys
from PIL import Image, ImageOps
im = ImageOps.exif_transpose(Image.open(sys.argv[1])).convert("RGB")
sys.stdout.buffer.write(bytes([im.width, im.height]) + im.tobytes())
`);
        for (let o = 1; o <= 8; o++) {
            const f = path.join(dir, `o${o}.jpg`);
            writeFileSync(f, withExifOrientation(jpeg, o));
            const want = spawnSync("python3", ["-I", check, f], { maxBuffer: 1 << 24 }).stdout;
            const [w, h] = [want[0], want[1]];
            const filters = orientationFilters(exifOrientation(readFileSync(f)));
            const got = spawnSync(FFMPEG, ["-v", "error", "-noautorotate", "-i", f, "-vf", [...filters, "format=rgb24"].join(","), "-f", "rawvideo", "-frames:v", "1", "-"], { maxBuffer: 1 << 24 }).stdout;
            assert.equal(got.length, w * h * 3, `orientation ${o}: size`);
            let diff = 0;
            for (let i = 0; i < got.length; i++) diff += Math.abs(got[i] - want[2 + i]);
            assert.ok(diff / got.length < 6, `orientation ${o}: mean abs diff ${diff / got.length}`);
        }
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});
