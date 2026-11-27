// Audio loudness measurement & non-destructive leveling (Cobalt v10.1):
// classification rules, helper ffmpeg loudnorm parsing & live 2-pass render,
// AudioLevelService lifecycle, visibility/delete cascades, HTTP API routes,
// library/sync payloads, and share route `?audio=normal` resolution.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import {
    AUDIO_SPEC_KIND,
    AudioLevelService,
    classifyLoudness,
    findAudioAlt,
    readAudioSettings,
    removeAudioAlt,
    wantsNormalAudio,
    withNormalAudioQuery,
    withoutAudioQuery,
} from "../src/audio-loudness";
import {
    buildLoudnormLevelArgs,
    buildLoudnormMeasureArgs,
    parseAudioTarget,
    parseLoudnormStats,
} from "../helper/lib.js";
import { createHelper } from "../helper/server.js";
import { hashKey } from "../src/keys";
import { setVisibility } from "../src/visibility";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryKV, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

function hasFfmpeg(): boolean {
    try {
        execFileSync("ffmpeg", ["-version"], { stdio: "ignore" });
        return true;
    } catch {
        return false;
    }
}

const FFMPEG_OK = hasFfmpeg();

describe("classifyLoudness & URL helpers", () => {
    it("classifies silent, loud, quiet, balanced, and the -11.2 LUFS peak-clip edge case", () => {
        expect(classifyLoudness(-99, -99)).toMatchObject({ zone: "silent", autoLevel: false });
        expect(classifyLoudness(-60, -50)).toMatchObject({ zone: "silent", autoLevel: false });
        expect(classifyLoudness(-Infinity, -Infinity)).toMatchObject({ zone: "silent", autoLevel: false });

        expect(classifyLoudness(-6.2, -0.2)).toMatchObject({ zone: "loud", autoLevel: true });
        expect(classifyLoudness(-10.4, -1.8)).toMatchObject({ zone: "loud", autoLevel: true });

        // The -11.2 LUFS case: flips on true peak alone (> -0.3 dBTP)
        expect(classifyLoudness(-11.2, -0.1)).toMatchObject({ zone: "loud", autoLevel: true });
        expect(classifyLoudness(-11.2, -0.3)).toMatchObject({ zone: "balanced", autoLevel: false });
        expect(classifyLoudness(-11.2, -0.5)).toMatchObject({ zone: "balanced", autoLevel: false });

        // Quiet & balanced boundaries
        expect(classifyLoudness(-28.4, -12.0)).toMatchObject({ zone: "quiet", autoLevel: true });
        expect(classifyLoudness(-22.1, -9.0)).toMatchObject({ zone: "quiet", autoLevel: true });
        expect(classifyLoudness(-22.0, -9.0)).toMatchObject({ zone: "balanced", autoLevel: false });
        expect(classifyLoudness(-15.1, -1.6)).toMatchObject({ zone: "balanced", autoLevel: false });
        expect(classifyLoudness(-10.5, -1.2)).toMatchObject({ zone: "balanced", autoLevel: false });
    });

    it("handles ?audio=normal query helpers cleanly", () => {
        expect(wantsNormalAudio(new URL("https://share.example/AbCdEfGh12?audio=normal"))).toBe(true);
        expect(wantsNormalAudio(new URL("https://share.example/AbCdEfGh12?audio=NORMAL"))).toBe(true);
        expect(wantsNormalAudio(new URL("https://share.example/AbCdEfGh12"))).toBe(false);
        expect(wantsNormalAudio(new URL("https://share.example/AbCdEfGh12?audio=orig"))).toBe(false);
        expect(withNormalAudioQuery("https://share.example/AbCdEfGh12")).toBe("https://share.example/AbCdEfGh12?audio=normal");
        expect(withoutAudioQuery("https://share.example/AbCdEfGh12?audio=normal")).toBe("https://share.example/AbCdEfGh12");
    });
});

describe("helper/lib.js loudnorm builders & parser", () => {
    it("parses targets and ffmpeg loudnorm JSON summaries including -inf silent tracks", () => {
        expect(parseAudioTarget(undefined)).toBe(-14);
        expect(parseAudioTarget("-14")).toBe(-14);
        expect(parseAudioTarget("-16")).toBe(-16);
        expect(parseAudioTarget("-12")).toBeNull();

        const stderr = `
[Parsed_loudnorm_0 @ 0x123]
{
    "input_i" : "-6.24",
    "input_tp" : "-0.12",
    "input_lra" : "4.80",
    "input_thresh" : "-16.40",
    "output_i" : "-14.01",
    "output_tp" : "-1.50",
    "output_lra" : "4.20",
    "output_thresh" : "-24.10",
    "normalization_type" : "linear",
    "target_offset" : "0.01"
}
`;
        expect(parseLoudnormStats(stderr)).toEqual({
            integrated_lufs: -6.24,
            true_peak_dbtp: -0.12,
            lra_lu: 4.8,
            threshold_lufs: -16.4,
            offset_db: 0.01,
            output_lufs: -14.01,
            output_true_peak: -1.5,
            normalization_type: "linear",
        });

        const silent = `{"input_i":"-inf","input_tp":"-inf","input_lra":"0.00","input_thresh":"-inf","target_offset":"inf"}`;
        expect(parseLoudnormStats(silent)).toMatchObject({
            integrated_lufs: -99,
            true_peak_dbtp: -99,
            lra_lu: 0,
            offset_db: 0,
        });
        expect(parseLoudnormStats("no json here")).toBeNull();
    });

    it("builds Pass 1 measure args and Pass 2 linear level args with optional libx264 fallback", () => {
        const mArgs = buildLoudnormMeasureArgs({ input: "/tmp/in.mp4", target: -14 });
        expect(mArgs).toContain("loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json");

        const lArgs = buildLoudnormLevelArgs({
            input: "/tmp/in.mp4",
            output: "/tmp/out.mp4",
            target: -16,
            measured: { integrated_lufs: -6.2, true_peak_dbtp: -0.1, lra_lu: 4.5, threshold_lufs: -16.5, offset_db: 0.1 },
        });
        expect(lArgs).toContain("-c:v");
        expect(lArgs[lArgs.indexOf("-c:v") + 1]).toBe("copy");
        const af = lArgs[lArgs.indexOf("-af") + 1];
        expect(af).toContain("I=-16:TP=-1.5:LRA=11");
        expect(af).toContain("measured_I=-6.20:measured_TP=-0.10:measured_LRA=4.50:measured_thresh=-16.50:offset=0.10:linear=true");

        const reenc = buildLoudnormLevelArgs({ input: "/tmp/in.mp4", output: "/tmp/out.mp4", target: -14, reencodeVideo: true });
        expect(reenc[reenc.indexOf("-c:v") + 1]).toBe("libx264");
    });
});

describe.skipIf(!FFMPEG_OK)("helper server live ffmpeg /audio/measure & /audio/level", () => {
    let dir: string;
    let server: http.Server;
    let base: string;
    let loudMp4: Buffer;
    let quietMp4: Buffer;

    beforeAll(async () => {
        dir = mkdtempSync(path.join(os.tmpdir(), "cobalt-audio-test-"));
        const loudPath = path.join(dir, "loud.mp4");
        const quietPath = path.join(dir, "quiet.mp4");
        execFileSync(
            "ffmpeg",
            [
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=160x120:r=15:d=1.6",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000:duration=1.6",
                "-af",
                "volume=14dB",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-movflags",
                "+faststart",
                loudPath,
            ],
            { stdio: "ignore" },
        );
        execFileSync(
            "ffmpeg",
            [
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=160x120:r=15:d=1.6",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000:duration=1.6",
                "-af",
                "volume=0.04",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-movflags",
                "+faststart",
                quietPath,
            ],
            { stdio: "ignore" },
        );
        loudMp4 = readFileSync(loudPath);
        quietMp4 = readFileSync(quietPath);

        const helper = createHelper({ workDir: dir, aboutDir: dir, internalKey: INTERNAL, ffmpegPath: () => "ffmpeg" });
        server = helper.server;
        await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
        const addr = server.address() as { port: number };
        base = `http://127.0.0.1:${addr.port}`;
    }, 30_000);

    afterAll(async () => {
        await new Promise<void>((resolve) => server.close(() => resolve()));
        rmSync(dir, { recursive: true, force: true });
    });

    it("measures loud and quiet clips via POST /audio/measure and levels them via POST /audio/level", async () => {
        const mLoud = await fetch(`${base}/audio/measure?id=LoudItem00000001&target=-14`, {
            method: "POST",
            headers: { "content-type": "application/octet-stream", "x-internal-key": INTERNAL },
            body: new Uint8Array(loudMp4),
        });
        expect(mLoud.status).toBe(200);
        const loudJson = (await mLoud.json()) as { loudness: { integrated_lufs: number; true_peak_dbtp: number; lra_lu: number; threshold_lufs: number; offset_db: number } };
        expect(loudJson.loudness.integrated_lufs).toBeGreaterThan(-10);

        const mQuiet = await fetch(`${base}/audio/measure?id=QuietItem0000001&target=-14`, {
            method: "POST",
            headers: { "content-type": "application/octet-stream", "x-internal-key": INTERNAL },
            body: new Uint8Array(quietMp4),
        });
        expect(mQuiet.status).toBe(200);
        const quietJson = (await mQuiet.json()) as { loudness: { integrated_lufs: number } };
        expect(quietJson.loudness.integrated_lufs).toBeLessThan(-24);

        const q = new URLSearchParams({
            id: "LoudItem00000001",
            target: "-14",
            mi: String(loudJson.loudness.integrated_lufs),
            mtp: String(loudJson.loudness.true_peak_dbtp),
            mlra: String(loudJson.loudness.lra_lu),
            mthresh: String(loudJson.loudness.threshold_lufs),
            offset: String(loudJson.loudness.offset_db),
        });
        const lvl = await fetch(`${base}/audio/level?${q}`, {
            method: "POST",
            headers: { "content-type": "application/octet-stream", "x-internal-key": INTERNAL },
            body: new Uint8Array(loudMp4),
        });
        expect(lvl.status).toBe(200);
        expect(lvl.headers.get("content-type")).toBe("video/mp4");
        const outLufs = Number(lvl.headers.get("x-audio-output-lufs"));
        const outTp = Number(lvl.headers.get("x-audio-output-tp"));
        expect(outLufs).toBeGreaterThan(-16.5);
        expect(outLufs).toBeLessThan(-11.5);
        expect(outTp).toBeLessThanOrEqual(-1.0);
        const outBytes = new Uint8Array(await lvl.arrayBuffer());
        expect(outBytes.byteLength).toBeGreaterThan(500);
    }, 30_000);
});

describe("AudioLevelService, visibility/delete cascades, HTTP API, library/sync & share routes", () => {
    let db: FakeD1;
    let originals: MemoryOriginals;
    let media: MemoryMedia;
    let storage: MemoryKV;
    let env: WorkerEnv;
    let nowMs: number;
    let helperCalls: string[];
    let nextHelperLevelPayload: Uint8Array;
    let audioService: AudioLevelService;

    function seedVideo(over: Record<string, unknown> = {}) {
        const id = (over.id as string) ?? "VidItem000000001";
        const r2Key = (over.r2_key as string) ?? `originals/${id}.mp4`;
        const row = {
            id,
            kind: "private",
            source: "saved",
            bucket: "originals",
            r2_key: r2Key,
            url: null,
            name: "clip.mp4",
            content_type: "video/mp4",
            bytes: 2048,
            width: 720,
            height: 1280,
            duration: 6.5,
            link: "https://x.com/test/status/1",
            session_id: "Sess000000000000000001",
            key_id: "key-1",
            created_at: 10_000,
            deleted_at: null,
            poster: `${MEDIA}PoStEr0001.jpg`,
            visibility: "private",
            public_key: null,
            public_id: null,
            role: "item",
            post_key: "Sess000000000000000001",
            ...over,
        };
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, role, post_key)
                 VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@role,@post_key)`,
            )
            .run(row as any);
        originals.objects.set(r2Key, { bytes: new Uint8Array(64).fill(0x55), contentType: "video/mp4", meta: {} });
        if (row.visibility === "public" && row.public_key) {
            media.objects.set(row.public_key as string, {
                bytes: 64,
                data: new Uint8Array(64).fill(0x55),
                contentType: "video/mp4",
                cacheControl: "public, max-age=31536000",
                meta: {},
                viaStream: false,
            });
        }
        return row;
    }

    beforeEach(async () => {
        db = withBatch(createFakeD1());
        originals = new MemoryOriginals();
        media = new MemoryMedia();
        storage = new MemoryKV();
        nowMs = 1_800_000_000_000;
        helperCalls = [];
        nextHelperLevelPayload = new Uint8Array(96).fill(0xaa);

        const hash = await hashKey(CLIENT);
        await db
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES ('key-1', 'test', ?1, ?2, ?3)")
            .bind(hash, CLIENT.slice(0, 8), nowMs)
            .run();

        audioService = new AudioLevelService({
            db,
            storage,
            originals,
            media,
            mediaBaseUrl: MEDIA,
            now: () => nowMs,
            ensureRunning: async () => {},
            helperBusy: async () => false,
            callHelper: async (p) => {
                helperCalls.push(p);
                if (p.startsWith("/audio/measure")) {
                    return new Response(
                        JSON.stringify({
                            loudness: {
                                integrated_lufs: -26.4,
                                true_peak_dbtp: -9.2,
                                lra_lu: 6.1,
                                threshold_lufs: -36.5,
                                offset_db: 0.4,
                            },
                        }),
                        { status: 200, headers: { "content-type": "application/json" } },
                    );
                }
                if (p.startsWith("/audio/level")) {
                    const url = new URL(`http://h${p}`);
                    const target = Number(url.searchParams.get("target") ?? -14);
                    return new Response(nextHelperLevelPayload, {
                        status: 200,
                        headers: {
                            "content-type": "video/mp4",
                            "x-audio-input-lufs": url.searchParams.get("mi") ?? "-6.2",
                            "x-audio-input-tp": url.searchParams.get("mtp") ?? "-0.1",
                            "x-audio-input-lra": url.searchParams.get("mlra") ?? "4.8",
                            "x-audio-input-thresh": url.searchParams.get("mthresh") ?? "-16.4",
                            "x-audio-offset": url.searchParams.get("offset") ?? "0.02",
                            "x-audio-output-lufs": String(target),
                            "x-audio-output-tp": "-1.5",
                            "x-audio-norm-type": "linear",
                        },
                    });
                }
                return new Response("not found", { status: 404 });
            },
        });

        env = {
            API_URL: `${API}/`,
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: db,
            ORIGINALS: originals,
            MEDIA: media,
            MEDIA_BASE_URL: MEDIA,
            SHARE_BASE_URL: SHARE,
        };
    });

    const container = {
        async fetch(r: Request) {
            const u = new URL(r.url);
            if (u.pathname.startsWith("/audio/level/")) {
                const itemId = u.pathname.slice("/audio/level/".length);
                const t = u.searchParams.get("target");
                const target = t === "-16" ? -16 : t === "-14" ? -14 : undefined;
                const res = await audioService.requestLevel(itemId, { target });
                if (!res.ok) return Response.json({ status: "error", error: { code: res.code } }, { status: res.status });
                return Response.json({ status: "success", ...res }, { status: 202 });
            }
            if (u.pathname === "/audio/kick") {
                const limit = Number(u.searchParams.get("limit") ?? 25);
                const backfill = u.searchParams.get("backfill") === "1";
                const res = await audioService.kick(limit, { backfill });
                return Response.json({ status: "success", ...res }, { status: 200 });
            }
            return Response.json({ status: "error" }, { status: 404 });
        },
    };

    const call = (pathWithQuery: string, init: RequestInit = {}) =>
        handleRequest(new Request(`${API}${pathWithQuery}`, init), env, container, { now: () => nowMs });

    const authHeaders = { authorization: `Api-Key ${CLIENT}`, "content-type": "application/json" };

    it("auto-levels loud clips from piggybacked /about, respects measure/off modes, replaces alt on re-level, and cascades visibility & deletes", async () => {
        const parent = seedVideo({
            id: "VidLoud000000001",
            visibility: "public",
            public_key: "AbCdEfGh12.mp4",
            url: `${MEDIA}AbCdEfGh12.mp4`,
        });

        // 1. Piggybacked /about measurement in default `auto` mode queues leveling
        await audioService.onAboutLoudness(parent.id, {
            integrated_lufs: -6.2,
            true_peak_dbtp: -0.1,
            lra_lu: 4.8,
            threshold_lufs: -16.4,
            offset_db: 0.02,
        });
        expect(await audioService.sweep()).toBe(0);
        const alt1 = await findAudioAlt(db, parent.id);
        expect(alt1).not.toBeNull();
        expect(alt1!.visibility).toBe("public");
        expect(alt1!.public_key).toBeTruthy();
        expect(media.objects.has(alt1!.public_key!)).toBe(true);
        expect(originals.objects.has(alt1!.r2_key)).toBe(true);
        const spec1 = JSON.parse(
            (db.raw.prepare("SELECT made_spec FROM media_items WHERE id = ?").get(alt1!.id) as { made_spec: string }).made_spec,
        );
        expect(spec1.kind).toBe(AUDIO_SPEC_KIND);
        expect(spec1.target_lufs).toBe(-14);

        // 2. Visibility toggle parent private -> alt becomes private too; back public -> alt mirrors public again
        const visDeps = { db, originals, media, mediaBaseUrl: MEDIA, now: () => nowMs };
        const offRes = await setVisibility(visDeps, parent.id, false, "key-1");
        expect(offRes.status).toBe(200);
        const altAfterPrivate = await findAudioAlt(db, parent.id);
        expect(altAfterPrivate!.visibility).toBe("private");
        expect(media.objects.has(alt1!.public_key!)).toBe(false);

        const onRes = await setVisibility(visDeps, parent.id, true, "key-1");
        expect(onRes.status).toBe(200);
        const altAfterPublic = await findAudioAlt(db, parent.id);
        expect(altAfterPublic!.visibility).toBe("public");
        expect(altAfterPublic!.public_key).toBeTruthy();
        expect(media.objects.has(altAfterPublic!.public_key!)).toBe(true);

        // 3. Re-level to -16 LUFS replaces previous alt cleanly
        nextHelperLevelPayload = new Uint8Array(112).fill(0xbb);
        const reReq = await audioService.requestLevel(parent.id, { target: -16 });
        expect(reReq.ok).toBe(true);
        await audioService.sweep();
        const alt2 = await findAudioAlt(db, parent.id);
        expect(alt2).not.toBeNull();
        expect(alt2!.id).not.toBe(alt1!.id);
        expect(originals.objects.has(alt1!.r2_key)).toBe(false);
        expect(originals.objects.has(alt2!.r2_key)).toBe(true);

        // 4. GET /library?v=3 and GET /sync both expose file.audio
        const libRes = await call("/library?v=3", { headers: authHeaders });
        expect(libRes.status).toBe(200);
        const libBody = (await libRes.json()) as { posts: { files: { id: string; audio?: any }[] }[] };
        const fileInLib = libBody.posts[0]!.files.find((f) => f.id === parent.id);
        expect(fileInLib?.audio).toMatchObject({
            integrated_lufs: -6.2,
            zone: "loud",
            state: "ready",
            target_lufs: -16,
            output_lufs: -16,
            alt_id: alt2!.id,
        });
        expect(fileInLib?.audio.alt_url).toBeTruthy();

        const syncRes = await call("/sync?since=0", { headers: authHeaders });
        expect(syncRes.status).toBe(200);
        const syncBody = (await syncRes.json()) as { posts: { files: { id: string; audio?: any }[] }[] };
        const fileInSync = syncBody.posts[0]!.files.find((f) => f.id === parent.id);
        expect(fileInSync?.audio).toMatchObject({
            state: "ready",
            target_lufs: -16,
            alt_id: alt2!.id,
        });

        // 5. removeAudioAlt deletes alt objects & resets row to measured
        const rm = await removeAudioAlt(visDeps, parent.id);
        expect(rm.removed).toBe(true);
        expect(await findAudioAlt(db, parent.id)).toBeNull();
        expect(originals.objects.has(alt2!.r2_key)).toBe(false);
        const rowAfterRm = db.raw.prepare("SELECT state, alt_item_id FROM media_audio WHERE item_id = ?").get(parent.id) as {
            state: string;
            alt_item_id: string | null;
        };
        expect(rowAfterRm).toEqual({ state: "measured", alt_item_id: null });

        // 6. Mode = measure records measurement without queuing auto-level; mode = off skips entirely
        const putMeasure = await call("/audio/settings", {
            method: "PUT",
            headers: authHeaders,
            body: JSON.stringify({ mode: "measure", target_lufs: -16, default_link: "normal" }),
        });
        expect(putMeasure.status).toBe(200);
        expect(await readAudioSettings(db)).toMatchObject({ mode: "measure", target_lufs: -16, default_link: "normal" });

        const quietVid = seedVideo({ id: "VidQuiet00000001", post_key: "SessQuiet001" });
        await audioService.onAboutLoudness(quietVid.id, {
            integrated_lufs: -28.4,
            true_peak_dbtp: -11.0,
            lra_lu: 7.0,
            threshold_lufs: -39.0,
            offset_db: 0.3,
        });
        expect(await audioService.sweep()).toBe(0);
        expect(await findAudioAlt(db, quietVid.id)).toBeNull();
        const qRow = db.raw.prepare("SELECT zone, state FROM media_audio WHERE item_id = ?").get(quietVid.id) as { zone: string; state: string };
        expect(qRow).toEqual({ zone: "quiet", state: "measured" });

        // Soft-deleting parent triggers automatic cleanup of media_audio row
        db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(nowMs, quietVid.id);
        expect(db.raw.prepare("SELECT * FROM media_audio WHERE item_id = ?").get(quietVid.id)).toBeUndefined();
    });

    it("handles HTTP API settings, manual level/delete, and backfill", async () => {
        const v1 = seedVideo({ id: "VidApi0000000001", post_key: "SessApi1" });

        const getRes = await call("/audio/settings", { headers: authHeaders });
        expect(getRes.status).toBe(200);
        const getBody = (await getRes.json()) as { mode: string; target_lufs: number; default_link: string; counts: any };
        expect(getBody).toMatchObject({ mode: "auto", target_lufs: -14, default_link: "orig" });
        expect(getBody.counts).toEqual({
            total_videos: 1,
            measured: 0,
            leveled: 0,
            needs_level: 0,
            rendering: 0,
            failed: 0,
        });

        const badPut = await call("/audio/settings", {
            method: "PUT",
            headers: authHeaders,
            body: JSON.stringify({ target_lufs: -12 }),
        });
        expect(badPut.status).toBe(400);

        const bf = await call("/audio/backfill", { method: "POST", headers: authHeaders, body: JSON.stringify({ limit: 10 }) });
        expect(bf.status).toBe(200);
        expect(await bf.json()).toMatchObject({ status: "success", queued_measure: 1 });
        // First sweep measures v1 -> quiet (-26.4 LUFS) -> auto queues level; second sweep levels it
        await audioService.sweep();
        await audioService.sweep();
        expect(await findAudioAlt(db, v1.id)).not.toBeNull();

        const delRes = await call(`/library/items/${v1.id}/audio/level`, { method: "DELETE", headers: authHeaders });
        expect(delRes.status).toBe(200);
        expect(await delRes.json()).toMatchObject({ status: "success", removed: true });
        expect(await findAudioAlt(db, v1.id)).toBeNull();

        const lvlRes = await call(`/library/items/${v1.id}/audio/level`, {
            method: "POST",
            headers: authHeaders,
            body: JSON.stringify({ target_lufs: -16 }),
        });
        expect(lvlRes.status).toBe(202);
        expect(await lvlRes.json()).toMatchObject({ status: "success", state: "rendering", target_lufs: -16 });
    });

    it("resolves ?audio=normal across public /<slug>, private /p/<key>, and gallery /g/<id> while keeping bare links unchanged", async () => {
        // Public video + leveled alt
        const pubParent = seedVideo({
            id: "VidPub0000000001",
            visibility: "public",
            public_key: "PubOrig001.mp4",
            url: `${MEDIA}PubOrig001.mp4`,
            post_key: "SessPub1",
        });
        await audioService.requestLevel(pubParent.id, { target: -14 });
        await audioService.sweep();
        const pubAlt = await findAudioAlt(db, pubParent.id);
        expect(pubAlt?.public_key).toBeTruthy();
        const pubAltUrl = `${MEDIA}${pubAlt!.public_key}`;

        // Public video WITHOUT leveled alt (for fallback test)
        const noAltParent = seedVideo({
            id: "VidNoAlt00000001",
            visibility: "public",
            public_key: "PubNoAlt01.mp4",
            url: `${MEDIA}PubNoAlt01.mp4`,
            post_key: "SessNoAlt1",
        });

        // 1. Bare /<slug> must serve ONLY original (audio_level alt excluded from videoSources!) + offer toggle link
        const bareRes = await handleRequest(new Request(`${SHARE}PubOrig001`), env, container, { now: () => nowMs });
        expect(bareRes.status).toBe(200);
        const bareHtml = await bareRes.text();
        expect(bareHtml).toContain(`content="${MEDIA}PubOrig001.mp4"`);
        expect(bareHtml).not.toContain(pubAltUrl);
        expect(bareHtml).toContain(`href="${SHARE}PubOrig001?audio=normal"`);
        expect(bareHtml).toContain("Hear leveled audio");

        // 2. /<slug>?audio=normal swaps video + OG tags to leveled alt & offers Hear original link
        const normRes = await handleRequest(new Request(`${SHARE}PubOrig001?audio=normal`), env, container, { now: () => nowMs });
        expect(normRes.status).toBe(200);
        const normHtml = await normRes.text();
        expect(normHtml).toContain(`property="og:video" content="${pubAltUrl}"`);
        expect(normHtml).toContain(`name="twitter:player:stream" content="${pubAltUrl}"`);
        expect(normHtml).toContain(`property="og:url" content="${SHARE}PubOrig001?audio=normal"`);
        expect(normHtml).toContain(`<source src="${pubAltUrl}"`);
        expect(normHtml).toContain(`href="${SHARE}PubOrig001"`);
        expect(normHtml).toContain("Audio leveled");

        // 3. /<slug>?audio=normal with NO leveled alt falls back silently to original
        const fbRes = await handleRequest(new Request(`${SHARE}PubNoAlt01?audio=normal`), env, container, { now: () => nowMs });
        expect(fbRes.status).toBe(200);
        const fbHtml = await fbRes.text();
        expect(fbHtml).toContain(`property="og:video" content="${MEDIA}PubNoAlt01.mp4"`);
        expect(fbHtml).not.toContain("Audio leveled");

        // 4. Private link /p/<key> & /p/<key>/1.mp4?audio=normal (22-char key, private video + private alt)
        const privParent = seedVideo({
            id: "VidPriv000000001",
            visibility: "private",
            public_key: null,
            url: null,
            post_key: "SessPriv1",
        });
        await audioService.requestLevel(privParent.id, { target: -14 });
        await audioService.sweep();
        const privAlt = await findAudioAlt(db, privParent.id);
        expect(privAlt?.visibility).toBe("private");
        const privKey = "PrivKey000000000000001";
        db.raw
            .prepare("INSERT INTO private_links (key, kind, target_id, created_at) VALUES (?, 'item', ?, ?)")
            .run(privKey, privParent.id, nowMs);
        const pOrig = await handleRequest(new Request(`${SHARE}p/${privKey}/1.mp4`), env, container, { now: () => nowMs });
        expect(pOrig.status).toBe(200);
        expect((await pOrig.arrayBuffer()).byteLength).toBe(64); // original bytes

        const pNorm = await handleRequest(new Request(`${SHARE}p/${privKey}/1.mp4?audio=normal`), env, container, { now: () => nowMs });
        expect(pNorm.status).toBe(200);
        expect((await pNorm.arrayBuffer()).byteLength).toBe(nextHelperLevelPayload.byteLength); // leveled bytes

        const pPage = await handleRequest(new Request(`${SHARE}p/${privKey}?audio=normal`), env, container, { now: () => nowMs });
        expect(pPage.status).toBe(200);
        const pHtml = await pPage.text();
        expect(pHtml).toContain(`/p/${privKey}/1.mp4?audio=normal`);
        expect(pHtml).toContain("Audio leveled");

        // 5. Public gallery /g/<id>?audio=normal swaps only items that have a leveled alt
        db.raw
            .prepare("INSERT INTO share_sets (id, title, items, created_at) VALUES ('1234567890123456789', 'Test Gallery', ?, ?)")
            .run(JSON.stringify([pubParent.id, noAltParent.id]), nowMs);
        const gBare = await handleRequest(new Request(`${SHARE}g/1234567890123456789`), env, container, { now: () => nowMs });
        expect(gBare.status).toBe(200);
        const gBareHtml = await gBare.text();
        expect(gBareHtml).toContain(`${MEDIA}PubOrig001.mp4`);
        expect(gBareHtml).not.toContain(pubAltUrl);
        expect(gBareHtml).toContain("?audio=normal");

        const gNorm = await handleRequest(new Request(`${SHARE}g/1234567890123456789?audio=normal`), env, container, { now: () => nowMs });
        expect(gNorm.status).toBe(200);
        const gNormHtml = await gNorm.text();
        expect(gNormHtml).toContain(pubAltUrl);
        expect(gNormHtml).toContain(`${MEDIA}PubNoAlt01.mp4`); // non-leveled item stays original!
        expect(gNormHtml).toContain("Audio leveled");
    });
});
