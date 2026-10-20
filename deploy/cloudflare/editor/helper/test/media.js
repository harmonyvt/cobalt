// Test support: small source clips made with ffmpeg, and readers that look at what a render produced. Nothing here ships in
// the image (helper/test is in .dockerignore).

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";

export function ffmpegAvailable() {
    const r = spawnSync(FFMPEG, ["-version"], { encoding: "utf8" });
    return r.status === 0 && /libx264/.test(spawnSync(FFMPEG, ["-hide_banner", "-encoders"], { encoding: "utf8" }).stdout);
}

/** @param {string[]} args */
export function ff(args) {
    const r = spawnSync(FFMPEG, ["-hide_banner", "-v", "error", "-nostdin", "-y", ...args], { encoding: "utf8", maxBuffer: 1 << 28 });
    if (r.status !== 0) throw new Error(`ffmpeg ${args.join(" ")}\n${r.stderr}`);
    return r;
}

/** Luma that encodes the frame number: 16 + 3 * (N mod 70), so a decoded pixel says which source frame it came from. */
export const IDX = "geq=lum='16+3*mod(N,70)':cb=128:cr=128";
/** Frame number back from a decoded luma. @param {number} y */
export const idxOf = (y) => Math.round((y - 16) / 3);

/**
 * Makes the shared clips in a fresh temp dir (or `dir`) and returns their paths. Sizes are small so the suite stays quick.
 * @param {string} [dir]
 */
export function makeMedia(dir) {
    const d = dir ?? mkdtempSync(path.join(process.env.EDIT_TEST_TMP || tmpdir(), "edit-media-"));
    mkdirSync(d, { recursive: true });
    const p = (/** @type {string} */ n) => path.join(d, n);
    const x264 = ["-c:v", "libx264", "-crf", "8", "-preset", "veryfast", "-pix_fmt", "yuv420p"];
    // 10 s, 30 fps, indexed frames, GOP 60, stereo 44.1 kHz sine
    ff(["-f", "lavfi", "-i", `color=c=gray:s=320x180:r=30:d=10,format=yuv420p,${IDX}`, "-f", "lavfi", "-i", "sine=f=300:r=44100:d=10,aformat=channel_layouts=stereo",
        ...x264, "-g", "60", "-c:a", "aac", p("idx.mp4")]);
    // variable frame rate: frames 0,1,4 of every 5 survive, in their original times
    ff(["-f", "lavfi", "-i", `color=c=gray:s=320x180:r=30:d=6,format=yuv420p,${IDX}`, "-f", "lavfi", "-i", "sine=f=300:r=48000:d=6",
        "-vf", "select='lt(mod(n,5),2)+eq(mod(n,5),4)'", "-fps_mode", "passthrough", ...x264, "-c:a", "aac", p("vfr.mp4")]);
    // portrait, 25 fps, no audio stream
    ff(["-f", "lavfi", "-i", "testsrc2=s=360x640:r=25:d=4", ...x264, "-an", p("noaudio.mp4")]);
    // landscape 640x360 stored, display matrix 90: displays as 360x640; mono audio
    ff(["-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=4", "-f", "lavfi", "-i", "sine=f=500:r=44100:d=4,aformat=channel_layouts=mono", ...x264, "-c:a", "aac", p("rot-src.mp4")]);
    ff(["-display_rotation", "90", "-i", p("rot-src.mp4"), "-c", "copy", p("rot.mp4")]);
    // non-square pixels: 360x360 stored, SAR 4:3 -> display 360x270 with the width kept
    ff(["-f", "lavfi", "-i", "testsrc2=s=360x360:r=30:d=3,setsar=4/3", ...x264, "-an", p("sar.mp4")]);
    // HLG, 10 bit, bt2020
    let hlg = false;
    try {
        ff(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=3,format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast", "-crf", "18", "-pix_fmt", "yuv420p10le",
            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-color_range", "tv", "-tag:v", "hvc1", "-an", p("hlg.mp4")]);
        hlg = true;
    } catch {}
    // GIF: four solid frames, 10 fps (0.4 s loop): red, green, blue, white
    ff(["-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=0.4,format=rgb24,geq=r='255*(eq(mod(N,4),0)+eq(mod(N,4),3))':g='255*(eq(mod(N,4),1)+eq(mod(N,4),3))':b='255*(eq(mod(N,4),2)+eq(mod(N,4),3))'",
        "-filter_complex", "[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0", p("anim.gif")]);
    // PNG, 100x100, red at 50 % alpha
    ff(["-f", "lavfi", "-i", "color=c=red@0.5:s=100x100,format=rgba", "-frames:v", "1", p("alpha.png")]);
    // JPEG 200x100 stored, EXIF orientation 6 (rotate 90 CW): displays 100x200
    ff(["-f", "lavfi", "-i", "testsrc2=s=200x100", "-frames:v", "1", "-q:v", "2", p("plain.jpg")]);
    writeFileSync(p("photo.jpg"), withExifOrientation(readFileSync(p("plain.jpg")), 6));
    return { dir: d, hlg, path: p, files: { idx: p("idx.mp4"), vfr: p("vfr.mp4"), noaudio: p("noaudio.mp4"), rot: p("rot.mp4"), sar: p("sar.mp4"), hlgFile: hlg ? p("hlg.mp4") : null, gif: p("anim.gif"), png: p("alpha.png"), jpg: p("photo.jpg") } };
}

/** A JPEG with an EXIF APP1 segment (big-endian, one IFD0 entry: Orientation) inserted after SOI. @param {Buffer} jpeg @param {number} orientation */
export function withExifOrientation(jpeg, orientation) {
    const tiff = Buffer.from([0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, orientation, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    const body = Buffer.concat([Buffer.from("Exif\0\0", "latin1"), tiff]);
    const seg = Buffer.concat([Buffer.from([0xff, 0xe1, (body.length + 2) >> 8, (body.length + 2) & 255]), body]);
    return Buffer.concat([jpeg.subarray(0, 2), seg, jpeg.subarray(2)]);
}

/** Frame count, width, height, duration of a video's first stream, packets counted (not the header's claim). @param {string} file */
export function videoFacts(file) {
    const r = spawnSync("ffprobe", ["-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries", "stream=width,height,nb_read_packets,r_frame_rate,codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,color_range:format=duration", "-of", "json", file], { encoding: "utf8" });
    const j = JSON.parse(r.stdout);
    const s = j.streams[0];
    return { frames: Number(s.nb_read_packets), width: s.width, height: s.height, rate: s.r_frame_rate, codec: s.codec_name, profile: s.profile, pixFmt: s.pix_fmt, space: s.color_space, trc: s.color_transfer, primaries: s.color_primaries, range: s.color_range, duration: Number(j.format.duration) };
}

/** Number of decoded audio samples (48 kHz stereo) in a file, and whether it has an audio stream. @param {string} file */
export function audioFacts(file) {
    const r = spawnSync("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate,channels,duration", "-of", "json", file], { encoding: "utf8" });
    const s = JSON.parse(r.stdout).streams?.[0];
    if (!s) return null;
    const pcm = decodeAudio(file);
    return { codec: s.codec_name, rate: Number(s.sample_rate), channels: s.channels, samples: pcm.length / 2 / 2, pcm };
}

/** Raw s16le stereo 48 kHz of a file's first audio stream. @param {string} file @returns {Buffer} */
export function decodeAudio(file) {
    const r = spawnSync(FFMPEG, ["-v", "error", "-nostdin", "-i", file, "-map", "0:a:0", "-ar", "48000", "-ac", "2", "-f", "s16le", "-"], { maxBuffer: 1 << 29 });
    return r.stdout;
}

/** RMS of s16le stereo samples in [from, to) (sample indexes), 0..1. @param {Buffer} pcm @param {number} from @param {number} to */
export function rms(pcm, from, to) {
    let sum = 0, n = 0;
    for (let i = from; i < to; i++) {
        for (let c = 0; c < 2; c++) {
            const v = pcm.readInt16LE((i * 2 + c) * 2) / 32768;
            sum += v * v;
            n++;
        }
    }
    return Math.sqrt(sum / Math.max(1, n));
}

/**
 * Mean R, G, B (0..255) of a w*h box at (x, y) for EVERY frame of a video (decoded, in order), as [[r,g,b], ...].
 * @param {string} file @param {{x: number, y: number, w: number, h: number}} box
 */
export function boxColors(file, box) {
    const r = spawnSync(FFMPEG, ["-v", "error", "-nostdin", "-i", file, "-vf", `crop=${box.w}:${box.h}:${box.x}:${box.y},scale=1:1:flags=area:in_range=tv:out_range=pc,format=rgb24`, "-f", "rawvideo", "-fps_mode", "passthrough", "-"], { maxBuffer: 1 << 28 });
    const out = [];
    for (let i = 0; i + 2 < r.stdout.length; i += 3) out.push([r.stdout[i], r.stdout[i + 1], r.stdout[i + 2]]);
    return out;
}

/** Mean luma (tv range, 16..235 raw Y) of a box for every frame. @param {string} file @param {{x: number, y: number, w: number, h: number}} box */
export function boxLuma(file, box) {
    const r = spawnSync(FFMPEG, ["-v", "error", "-nostdin", "-i", file, "-vf", `crop=${box.w}:${box.h}:${box.x}:${box.y},format=yuv420p,extractplanes=y,setparams=range=pc,scale=1:1:flags=area`, "-pix_fmt", "gray", "-f", "rawvideo", "-fps_mode", "passthrough", "-"], { maxBuffer: 1 << 28 });
    return Array.from(r.stdout);
}

/** One decoded frame as RGB: {w, h, data}. @param {string} file @param {number} k */
export function frameRGB(file, k) {
    const f = videoFacts(file);
    const r = spawnSync(FFMPEG, ["-v", "error", "-nostdin", "-i", file, "-vf", `select=eq(n\\,${k}),format=rgb24`, "-frames:v", "1", "-f", "rawvideo", "-fps_mode", "passthrough", "-"], { maxBuffer: 1 << 28 });
    return { w: f.width, h: f.height, data: r.stdout };
}

export const exists = existsSync;
