// The words of "what it's about" (APP-API-CONTRACT.md section 34.3), written by the 15-minute cron after the roast
// captions and before the search indexer: the sound transcribed by Whisper (Workers AI), then one plain, factual
// sentence and tags by Claude Haiku from the probe's frames (or the picture itself), the title, the link's site and the
// transcript. These words are for search (they go into the post's vector, embed.ts postInputs), so they are NOT written
// in the caption voice. Every Anthropic call goes through ModelRelay (the modelFetch). Free of Cloudflare imports so it
// runs under node in the tests (Haiku and Whisper are injected).

import Anthropic from "@anthropic-ai/sdk";
import {
    ABOUT_MAX_ATTEMPTS,
    ABOUT_MODEL_DEFAULT,
    ABOUT_RETRY_MS,
    SENTENCE_MAX,
    SOUND_TAGS_MAX,
    TAGS_MAX,
    TRANSCRIPT_MAX,
    audioKey,
    cleanTagList,
    frameKey,
    postLeads,
    type AboutRow,
    type LeadRow,
} from "./about-store";
import type { ModelFetch } from "./model-fetch";
import { stripEmoji } from "./roast";
import { heardTranscript, hearOne, linesOf, segmentsOf, segmentsOfAssembly, transcriptModel, type Line } from "./transcripts";

// The writer's share of each 15-minute run.
export const ABOUT_RUN_BUDGET_MS = 120_000;
export const ABOUT_CONCURRENCY = 3;
// Bumped when the prompt changes: every post is described again.
export const ABOUT_STYLE = "v1-plain";
// A picture read from R2 for a still (no public copy, no poster) is sent only under this size.
export const ABOUT_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const WHISPER_MODEL = "@cf/openai/whisper-large-v3-turbo";
// AssemblyAI Universal on Workers AI: more accurate, about 7x Whisper's price (TRANSCRIBE_MODEL, section 47.1).
export const ASSEMBLY_MODEL = "assemblyai/universal-3.5-pro";

const IMAGE_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"];

// ---- the describer (Haiku) ------------------------------------------------------------------------------------------

export type AboutImage = { base64: string; mediaType: string } | { url: string };

export type DescribeInput = {
    kind: "video" | "gif" | "image";
    images: AboutImage[];
    title: string | null;
    site: string | null;
    // null: no speech recognised (or no transcriber); has_audio says whether there was sound at all
    transcript: string | null;
    hasAudio: boolean;
};

export type AboutText = { sentence: string; tags: string[]; sound_tags: string[] };

export type Describer = { model: string; describe(input: DescribeInput): Promise<AboutText> };

export const ABOUT_SYSTEM = `You describe one saved video or picture for the search index of Harmony's private media library. Write plain, factual words about what is shown and heard, the way a careful librarian tags things: no jokes, no persona, no emoji, no opinions about quality.

Never guess who a person is: no names unless the name is written in the picture or said in the sound. Describe people by what they look like and do. Prefer the everyday words someone would type into a search: the animals, characters and costumes (fursuit, cosplay, mascot), the place, the activity, the game, the kind of video (meme, tutorial, gameplay, music video, vlog) and the mood.

Answer with:
- sentence: one sentence of at most 160 characters saying what it is.
- tags: 5 to 12 lowercase words or short phrases of at most 30 characters, the most important first.
- sound_tags: 0 to 6 lowercase words for what is heard (music, phonk, speech, laughter, screaming, asmr, meowing, ...); [] when it is silent or has no sound.`;

const SCHEMA = {
    type: "object",
    properties: {
        sentence: { type: "string", description: "One plain sentence, at most 160 characters." },
        tags: { type: "array", items: { type: "string" }, description: "5 to 12 lowercase words or short phrases, at most 30 characters each." },
        sound_tags: { type: "array", items: { type: "string" }, description: "0 to 6 lowercase words for the sound; [] when silent." },
    },
    required: ["sentence", "tags", "sound_tags"],
    additionalProperties: false,
};

export function describePrompt(input: DescribeInput): string {
    const what = input.kind === "image" ? "A picture" : input.kind === "gif" ? "A gif" : "A video";
    const lines = [
        `${what}${input.site ? ` saved from ${input.site}` : ""}${input.title ? `, titled "${input.title.slice(0, 200)}"` : ""}.`,
        input.images.length === 0
            ? "No picture of it is attached."
            : input.kind === "image"
              ? "The picture is attached."
              : input.images.length === 1
                ? "One frame of it is attached."
                : `${input.images.length} frames of it are attached, in order (15 %, 50 % and 85 % through).`,
        input.kind === "image" || input.kind === "gif"
            ? ""
            : !input.hasAudio
              ? "It has no sound (or the sound is silent)."
              : input.transcript
                ? `It has sound. What is said (an automatic transcript, may be wrong): "${input.transcript.slice(0, 3000)}"`
                : "It has sound, but no speech was recognised in it (music or noise).",
        "Describe it.",
    ];
    return lines.filter(Boolean).join("\n");
}

const clipChars = (s: string, max: number): string => {
    const cps = Array.from(s);
    return cps.length > max ? `${cps.slice(0, max - 1).join("").trimEnd()}…` : s;
};

// The model's JSON as stored: a one-line sentence (no emoji, at most SENTENCE_MAX), clean tag lists.
export function readAboutText(text: string): AboutText {
    const v = JSON.parse(text) as { sentence?: unknown; tags?: unknown; sound_tags?: unknown };
    if (typeof v.sentence !== "string") throw new Error("bad description");
    const sentence = clipChars(stripEmoji(v.sentence), SENTENCE_MAX);
    if (!sentence) throw new Error("empty description");
    return { sentence, tags: cleanTagList(v.tags, TAGS_MAX), sound_tags: cleanTagList(v.sound_tags, SOUND_TAGS_MAX) };
}

export function describerFrom(
    env: { ANTHROPIC_API_KEY?: string; ROAST_BASE_URL?: string; ABOUT_MODEL?: string },
    modelFetch?: ModelFetch,
): Describer | null {
    const apiKey = env.ANTHROPIC_API_KEY?.trim();
    if (!apiKey) return null;
    const baseURL = env.ROAST_BASE_URL?.trim() || undefined;
    const model = env.ABOUT_MODEL?.trim() || ABOUT_MODEL_DEFAULT;
    const client = new Anthropic({ apiKey, baseURL, maxRetries: 1, timeout: 45_000, ...(modelFetch ? { fetch: modelFetch } : {}) });
    return {
        model: `${model}+${ABOUT_STYLE}`,
        async describe(input) {
            const images = input.images.slice(0, 3).map((i) =>
                "url" in i
                    ? { type: "image" as const, source: { type: "url" as const, url: i.url } }
                    : { type: "image" as const, source: { type: "base64" as const, media_type: i.mediaType as "image/jpeg", data: i.base64 } },
            );
            const response = await client.messages.create({
                model,
                max_tokens: 1000,
                system: ABOUT_SYSTEM,
                output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
                messages: [{ role: "user", content: [...images, { type: "text" as const, text: describePrompt(input) }] }],
            } as any);
            if (response.stop_reason === "refusal") throw new Error("refusal");
            return readAboutText(response.content.map((b: { type: string; text?: string }) => (b.type === "text" ? (b.text ?? "") : "")).join(""));
        },
    };
}

// ---- the transcriber (Whisper on Workers AI) ------------------------------------------------------------------------

export type Transcript = { text: string | null; language: string | null; lines?: Line[] };
export type Transcriber = { model: string; transcribe(mp3: Uint8Array): Promise<Transcript> };
export type AiRunner = { run(model: string, inputs: Record<string, unknown>): Promise<unknown> };

export function toBase64(bytes: Uint8Array): string {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(bin);
}

const cleanHeard = (s: string) =>
    // eslint-disable-next-line no-control-regex
    s.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();

function heardFrom(text: string, lang: unknown, lines: Line[]): Transcript {
    return {
        text: text ? Array.from(text).slice(0, TRANSCRIPT_MAX).join("") : null,
        language: typeof lang === "string" && lang ? lang.slice(0, 16) : null,
        lines: text ? lines : [],
    };
}

// Workers AI's whisper-large-v3-turbo takes the audio as base64 (`audio`) and answers `{ text, transcription_info:
// { language }, segments: [{ start, end, text, words: [{ word, start, end }] }], vtt }`. An empty text is "no speech".
// The segments become timed subtitle lines (section 47, transcripts.ts).
export function whisperFrom(ai: AiRunner | undefined | null): Transcriber | null {
    if (!ai || typeof ai.run !== "function") return null;
    return {
        model: WHISPER_MODEL,
        async transcribe(mp3) {
            const r = (await ai.run(WHISPER_MODEL, { audio: toBase64(mp3), task: "transcribe", vad_filter: true })) as {
                text?: unknown;
                transcription_info?: { language?: unknown };
            } | null;
            if (!r || typeof r.text !== "string") throw new Error("bad whisper answer");
            const text = cleanHeard(r.text);
            return heardFrom(text, r.transcription_info?.language, text ? linesOf(segmentsOf(r)) : []);
        },
    };
}

// AssemblyAI Universal takes the audio as a data URI (`audio_url`) and answers `{ text, language_code, words: [{ text,
// start, end }] }` with times in milliseconds.
// The partner model's answer has come back as the transcript object, as JSON text, as a Response, or wrapped in
// `result` / `response`; this unwraps whichever arrives.
async function assemblyAnswer(raw: unknown): Promise<unknown> {
    let r = raw;
    if (r instanceof Response) r = await r.text();
    if (typeof r === "string") {
        try {
            r = JSON.parse(r);
        } catch {
            return null;
        }
    }
    for (let i = 0; i < 2 && r && typeof r === "object" && !("text" in r); i++) {
        const o = r as { result?: unknown; response?: unknown };
        const inner = o.result ?? o.response;
        if (!inner || typeof inner !== "object") break;
        r = inner;
    }
    return r;
}

// What an unreadable answer looked like, for the log: its type and top-level keys (never the words).
function answerShape(raw: unknown): string {
    if (raw === null || raw === undefined) return String(raw);
    if (raw instanceof Response) return `Response ${raw.status}`;
    if (typeof raw !== "object") return typeof raw;
    return `keys ${Object.keys(raw).slice(0, 12).join(",")}`;
}

export function assemblyFrom(ai: AiRunner | undefined | null): Transcriber | null {
    if (!ai || typeof ai.run !== "function") return null;
    return {
        model: ASSEMBLY_MODEL,
        async transcribe(mp3) {
            const raw = await ai.run(ASSEMBLY_MODEL, { audio_url: `data:audio/mpeg;base64,${toBase64(mp3)}`, language_detection: true });
            const r = (await assemblyAnswer(raw)) as { text?: unknown; language_code?: unknown } | null;
            if (!r || (typeof r.text !== "string" && r.text !== null)) throw new Error(`bad assemblyai answer: ${answerShape(raw)}`);
            const text = cleanHeard(typeof r.text === "string" ? r.text : "");
            return heardFrom(text, r.language_code, text ? linesOf(segmentsOfAssembly(r)) : []);
        },
    };
}

// The speech model named by TRANSCRIBE_MODEL: "assemblyai" (default, most accurate) or "whisper" (cheapest). Switching
// hears every post again on the next cron runs, since a transcript remembers the model that heard it.
export function transcriberFrom(ai: AiRunner | undefined | null, name?: string | null): Transcriber | null {
    const n = (name ?? "").trim().toLowerCase();
    if (n === "whisper" || n === WHISPER_MODEL) return whisperFrom(ai);
    return assemblyFrom(ai);
}

// ---- the cron's run -------------------------------------------------------------------------------------------------

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream; size: number; httpMetadata?: { contentType?: string } } | null> };

export type AboutWriterDeps = {
    db: D1Database;
    originals: ReadBucket;
    // the public bucket, for a still that lives only there and has no public URL to send
    media?: ReadBucket;
    mediaBaseUrl: string;
    describer: Describer;
    transcriber: Transcriber | null;
    now: () => number;
    budgetMs: number;
    concurrency?: number;
};

export type AboutWriteResult = { due: number; written: number; failed: number; transcribed: number };

const siteOf = (link: string | null): string | null => {
    if (!link || !/^https?:\/\//i.test(link)) return null;
    try {
        return new URL(link).hostname.replace(/^www\./, "").toLowerCase();
    } catch {
        return null;
    }
};

async function sha256(s: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const bytesOf = async (o: { body: ReadableStream }) => new Uint8Array(await new Response(o.body).arrayBuffer());

type Planned = { row: AboutRow; lead: LeadRow; latest: number; title: string | null; site: string | null; picture: string | null; hash: string };

// The picture a still is described from, without reading it: its poster or its public URL (on the media domain), else
// its stored bytes (a reference for the hash).
function stillPicture(lead: LeadRow, base: string): string | null {
    if (lead.poster && lead.poster.startsWith(base)) return lead.poster;
    const type = (lead.content_type ?? "").toLowerCase();
    if (lead.url && lead.url.startsWith(base) && IMAGE_TYPES.includes(type)) return lead.url;
    if (IMAGE_TYPES.includes(type) && (lead.bytes ?? 0) <= ABOUT_IMAGE_MAX_BYTES) return `r2:${lead.bucket}:${lead.r2_key}`;
    return null;
}

// The posts whose words are due (34.3): probe done or none, and an input that changed since the words were written,
// or a failure more than a day ago with fewer than ABOUT_MAX_ATTEMPTS attempts. Newest first.
export async function dueAbouts(d: Pick<AboutWriterDeps, "db" | "mediaBaseUrl" | "describer" | "transcriber" | "now">): Promise<Planned[]> {
    const { results: rows } = await d.db.prepare("SELECT * FROM media_about WHERE probe_state IN ('done', 'none')").all<AboutRow>();
    if (rows.length === 0) return [];
    const leads = await postLeads(d.db);
    const { results: titleRows } = await d.db.prepare("SELECT post_key, title FROM media_titles").all<{ post_key: string; title: string }>();
    const titles = new Map(titleRows.map((t) => [t.post_key, t.title]));
    const base = d.mediaBaseUrl.endsWith("/") ? d.mediaBaseUrl : `${d.mediaBaseUrl}/`;
    const now = d.now();
    const out: Planned[] = [];
    for (const row of rows) {
        const post = leads.get(row.post_key);
        if (!post || post.lead.id !== row.item_id) continue; // gone or moved: the next sync fixes the row
        const lead = post.lead;
        const title = titles.get(row.post_key) ?? lead.name ?? null;
        const site = siteOf(lead.link ?? post.files.find((f) => f.link)?.link ?? null);
        const picture = row.probe_state === "none" ? stillPicture(lead, base) : null;
        const hash = await sha256(
            JSON.stringify([
                ABOUT_STYLE,
                d.describer.model,
                row.probe_state,
                row.probe_at,
                row.frames,
                row.has_audio,
                row.has_audio && d.transcriber ? "sound" : "",
                title,
                site,
                picture,
            ]),
        );
        const changed = row.input_hash !== hash;
        const retry = !changed && row.failed_at !== null && row.failed_at <= now - ABOUT_RETRY_MS && row.attempts < ABOUT_MAX_ATTEMPTS;
        if (changed || retry) out.push({ row, lead, latest: post.latest, title, site, picture, hash });
    }
    out.sort((a, b) => b.latest - a.latest || (a.row.post_key < b.row.post_key ? 1 : -1));
    return out;
}

export async function writeAbouts(d: AboutWriterDeps): Promise<AboutWriteResult> {
    const start = d.now();
    const due = await dueAbouts(d);
    const out: AboutWriteResult = { due: due.length, written: 0, failed: 0, transcribed: 0 };
    let i = 0;
    const worker = async () => {
        while (i < due.length && d.now() - start < d.budgetMs) {
            const p = due[i++]!;
            try {
                await writeOne(d, p, out);
            } catch (e) {
                console.error("[about] write failed", p.row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
            }
        }
    };
    await Promise.all(Array.from({ length: Math.max(1, d.concurrency ?? ABOUT_CONCURRENCY) }, worker));
    return out;
}

async function writeOne(d: AboutWriterDeps, p: Planned, out: AboutWriteResult): Promise<void> {
    const { row, lead } = p;
    const images: AboutImage[] = [];
    if (row.probe_state === "done") {
        for (let n = 1; n <= row.frames; n++) {
            const o = await d.originals.get(frameKey(row.item_id, n)).catch(() => null);
            if (o) images.push({ base64: toBase64(await bytesOf(o)), mediaType: "image/jpeg" });
        }
    } else if (p.picture?.startsWith("r2:")) {
        const bucket = lead.bucket === "media" ? d.media : d.originals;
        const o = bucket ? await bucket.get(lead.r2_key).catch(() => null) : null;
        if (o && o.size <= ABOUT_IMAGE_MAX_BYTES) images.push({ base64: toBase64(await bytesOf(o)), mediaType: (lead.content_type ?? "image/jpeg").toLowerCase() });
        else await o?.body.cancel().catch(() => {});
    } else if (p.picture) images.push({ url: p.picture });

    // the sound first: the description reads the transcript
    let transcript = row.transcript;
    let language = row.language;
    if (!row.has_audio) {
        transcript = null;
        language = null;
    } else if (d.transcriber) {
        // heard already by the listening pass (section 47): its words, without a second Whisper call
        const heard = await heardTranscript(d.db, row, transcriptModel(d.transcriber.model)).catch(() => null);
        if (heard) {
            transcript = heard.text ? Array.from(heard.text).slice(0, TRANSCRIPT_MAX).join("") : null;
            language = heard.text ? heard.language : null;
        } else {
            const t = await hearOneSafe(d, row);
            if (t) {
                transcript = t.text;
                language = t.language;
                out.transcribed++;
            }
        }
    }

    const kind = row.probe_state === "none" ? "image" : (lead.content_type ?? "").toLowerCase() === "image/gif" ? "gif" : "video";
    let text: AboutText | null = null;
    try {
        text = await d.describer.describe({ kind, images, title: p.title, site: p.site, transcript, hasAudio: !!row.has_audio });
    } catch (e) {
        console.error("[about] description failed", row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
    }
    const now = d.now();
    if (!text) {
        await d.db
            .prepare(
                `UPDATE media_about SET attempts = CASE WHEN input_hash IS ?2 THEN attempts + 1 ELSE 1 END, input_hash = ?2, failed_at = ?3,
                        transcript = ?4, language = ?5, updated_at = ?3 WHERE post_key = ?1`,
            )
            .bind(row.post_key, p.hash, now, transcript, language)
            .run();
        out.failed++;
        return;
    }
    // the owner's tags (user_tags) are never touched: they win over these everywhere
    await d.db
        .prepare(
            `UPDATE media_about SET sentence = ?2, tags = ?3, sound_tags = ?4, transcript = ?5, language = ?6, model = ?7, input_hash = ?8,
                    written_at = ?9, failed_at = NULL, attempts = 0, updated_at = ?9 WHERE post_key = ?1`,
        )
        .bind(row.post_key, text.sentence, JSON.stringify(text.tags), JSON.stringify(text.sound_tags), transcript, language, d.describer.model, p.hash, now)
        .run();
    out.written++;
}

// Whisper through the listening pass's own path (the timed transcript is stored too); before migration 0030 the plain
// transcript only. Null when Whisper failed or the sound is missing: the words are written without it (an earlier
// transcript is kept).
async function hearOneSafe(d: AboutWriterDeps, row: AboutRow): Promise<{ text: string | null; language: string | null } | null> {
    try {
        return await hearOne(d.db, d.originals, d.transcriber!, row, d.now);
    } catch (e) {
        if (!/no such table/i.test(String(e))) {
            console.error("[about] transcript failed", row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
            return null;
        }
    }
    const o = await d.originals.get(audioKey(row.item_id)).catch(() => null);
    if (!o) return null;
    try {
        const t = await d.transcriber!.transcribe(await bytesOf(o));
        return { text: t.text, language: t.language };
    } catch (e) {
        console.error("[about] transcript failed", row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
        return null;
    }
}
