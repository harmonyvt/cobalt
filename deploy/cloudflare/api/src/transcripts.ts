// Timed transcripts (APP-API-CONTRACT.md section 47): what Whisper heard in a post's sound, kept with the time of every
// word, for the app's subtitles, the timed "heard" list, search lines that open a video at the moment ("said at 0:12")
// and "moments by meaning" (a vector for each stretch of speech). One `media_transcripts` row per post (migration
// 0030), written by the cron's listening pass (`timeTranscripts`, which also re-hears posts heard before this section)
// or by the about writer when it transcribes; `media_moments` holds the stretches and their vectors (`indexMoments`).
// Free of Cloudflare imports so it runs under node in the tests (Whisper and the Space are injected).

import { ABOUT_MAX_ATTEMPTS, ABOUT_RETRY_MS, TRANSCRIPT_MAX, audioKey, postLeads, probeable, runAll, type AboutRow } from "./about-store";
import type { Transcriber } from "./about-writer";
import { EMBED_BATCH, EMBED_CALL_MS, EMBED_DIMS, EMBED_MODEL, EmbedError, decodeVector, dot, encodeVector, type EmbedClient } from "./embed";

// ---- the shape of a transcript ----------------------------------------------------------------------------------------

// A word: its text and its start and end, in seconds from the start of the clip.
export type Word = { t: string; s: number; e: number };
// A subtitle line: at most LINE_MAX_CHARS characters and LINE_MAX_SECONDS long, broken where Whisper's own segments
// end, at a pause, or after a sentence.
export type Line = { s: number; e: number; t: string; w: Word[] };

export const LINE_MAX_CHARS = 84;
export const LINE_MAX_SECONDS = 6;
// a pause this long between two words starts a new line
export const LINE_GAP_SECONDS = 1.2;
// a sentence end breaks the line once it holds this much
export const LINE_SENTENCE_CHARS = 24;
export const MAX_LINES = 800;
export const MAX_WORDS = 6000;
// Bumped when the lines are built differently: every post is heard again.
export const TRANSCRIPT_VERSION = "v1";

const round2 = (n: number) => Math.round(n * 100) / 100;
// eslint-disable-next-line no-control-regex
const cleanText = (s: string) => s.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null);

type Segment = { start: number; end: number; text: string; words: Word[] | null };

// "00:01:02.500" or "01:02.500" in seconds.
function vttTime(s: string): number | null {
    const m = /^(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})$/.exec(s.trim());
    if (!m) return null;
    return Number(m[1] ?? 0) * 3600 + Number(m[2]) * 60 + Number(m[3]) + Number(m[4]!.padEnd(3, "0")) / 1000;
}

// The cues of a WebVTT text, as segments without words.
export function segmentsFromVtt(vtt: string): Segment[] {
    const out: Segment[] = [];
    const blocks = vtt.replace(/\r/g, "").split(/\n\n+/);
    for (const b of blocks) {
        const lines = b.split("\n");
        const i = lines.findIndex((l) => l.includes("-->"));
        if (i < 0) continue;
        const [a, z] = lines[i]!.split("-->");
        const start = vttTime(a ?? "");
        const end = vttTime((z ?? "").trim().split(/\s+/)[0] ?? "");
        const text = cleanText(lines.slice(i + 1).join(" "));
        if (start === null || end === null || !text) continue;
        out.push({ start, end: Math.max(start, end), text, words: null });
    }
    return out;
}

// Whisper's segments (Workers AI whisper-large-v3-turbo: `segments: [{ start, end, text, words: [{ word, start, end }] }]`,
// plus a `vtt` text). Anything malformed is skipped; no segments at all falls back to the vtt cues.
export function segmentsOf(answer: unknown): Segment[] {
    const r = (answer ?? {}) as { segments?: unknown; vtt?: unknown };
    const out: Segment[] = [];
    if (Array.isArray(r.segments)) {
        for (const raw of r.segments) {
            const sg = (raw ?? {}) as { start?: unknown; end?: unknown; text?: unknown; words?: unknown };
            const start = num(sg.start);
            const end = num(sg.end);
            const text = typeof sg.text === "string" ? cleanText(sg.text) : "";
            if (start === null || end === null) continue;
            let words: Word[] | null = null;
            if (Array.isArray(sg.words)) {
                words = [];
                for (const w of sg.words) {
                    const ww = (w ?? {}) as { word?: unknown; start?: unknown; end?: unknown };
                    const t = typeof ww.word === "string" ? cleanText(ww.word) : "";
                    const s = num(ww.start);
                    const e = num(ww.end);
                    if (!t || s === null || e === null) continue;
                    words.push({ t, s, e: Math.max(s, e) });
                }
                if (words.length === 0) words = null;
            }
            if (!text && !words) continue;
            out.push({ start, end: Math.max(start, end), text, words });
        }
    }
    if (out.length === 0 && typeof r.vtt === "string") return segmentsFromVtt(r.vtt);
    return out;
}

// AssemblyAI Universal (Workers AI `assemblyai/universal-3.5-pro`): `words: [{ text, start, end }]` in milliseconds and
// `utterances` (same words) when speakers are labelled. Each utterance is a segment; without them, one segment of all words.
export function segmentsOfAssembly(answer: unknown): Segment[] {
    const r = (answer ?? {}) as { words?: unknown; utterances?: unknown };
    const wordsOf = (list: unknown): Word[] => {
        const out: Word[] = [];
        if (!Array.isArray(list)) return out;
        for (const w of list) {
            const ww = (w ?? {}) as { text?: unknown; start?: unknown; end?: unknown };
            const t = typeof ww.text === "string" ? cleanText(ww.text) : "";
            const s = num(ww.start);
            const e = num(ww.end);
            if (!t || s === null || e === null) continue;
            out.push({ t, s: s / 1000, e: Math.max(s, e) / 1000 });
        }
        return out;
    };
    const seg = (words: Word[]): Segment => ({ start: words[0]!.s, end: words[words.length - 1]!.e, text: words.map((w) => w.t).join(" "), words });
    if (Array.isArray(r.utterances) && r.utterances.length > 0) {
        const out = r.utterances.map((u) => wordsOf((u as { words?: unknown } | null)?.words)).filter((w) => w.length > 0).map(seg);
        if (out.length > 0) return out;
    }
    const all = wordsOf(r.words);
    return all.length > 0 ? [seg(all)] : [];
}

// A segment without word times: its words spread over the segment by their length.
function spreadWords(sg: Segment): Word[] {
    const parts = sg.text.split(" ").filter(Boolean);
    if (parts.length === 0) return [];
    const total = parts.reduce((n, p) => n + p.length + 1, 0);
    const span = Math.max(0, sg.end - sg.start);
    let at = sg.start;
    return parts.map((p) => {
        const len = (span * (p.length + 1)) / total;
        const w = { t: p, s: at, e: at + len };
        at += len;
        return w;
    });
}

// The subtitle lines of Whisper's segments: words in order with times that never run backwards, broken at segment
// ends, pauses, sentence ends, and the length limits. Capped at MAX_LINES lines and MAX_WORDS words.
export function linesOf(segments: Segment[]): Line[] {
    const lines: Line[] = [];
    let cur: Word[] = [];
    let words = 0;
    let last = 0;
    const flush = () => {
        if (cur.length === 0) return;
        if (lines.length < MAX_LINES) {
            lines.push({ s: round2(cur[0]!.s), e: round2(cur[cur.length - 1]!.e), t: cur.map((w) => w.t).join(" "), w: cur.map((w) => ({ t: w.t, s: round2(w.s), e: round2(w.e) })) });
        }
        cur = [];
    };
    const chars = () => cur.reduce((n, w) => n + w.t.length + 1, -1);
    for (const sg of segments) {
        flush();
        for (const raw of sg.words ?? spreadWords(sg)) {
            if (words >= MAX_WORDS || lines.length >= MAX_LINES) break;
            const s = Math.max(last, raw.s);
            const w = { t: raw.t, s, e: Math.max(s, raw.e) };
            const prev = cur[cur.length - 1];
            if (
                prev &&
                (w.s - prev.e >= LINE_GAP_SECONDS ||
                    chars() + 1 + w.t.length > LINE_MAX_CHARS ||
                    w.e - cur[0]!.s > LINE_MAX_SECONDS ||
                    (/[.!?…]["')\]]?$/.test(prev.t) && chars() >= LINE_SENTENCE_CHARS))
            )
                flush();
            cur.push(w);
            last = w.s;
            words++;
        }
    }
    flush();
    return lines;
}

export const linesText = (lines: Line[]): string => lines.map((l) => l.t).join(" ");

// ---- D1 ----------------------------------------------------------------------------------------------------------------

export type TranscriptState = "done" | "no_speech" | "failed";

export type TranscriptRow = {
    post_key: string;
    item_id: string;
    probe_at: number | null;
    state: TranscriptState;
    language: string | null;
    text: string | null;
    lines: string | null;
    model: string | null;
    attempts: number;
    failed_at: number | null;
    created_at: number;
    updated_at: number;
};

export function parseLines(s: string | null | undefined): Line[] {
    if (!s) return [];
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? (v as Line[]) : [];
    } catch {
        return [];
    }
}

export const transcriptModel = (whisperModel: string) => `${whisperModel}+${TRANSCRIPT_VERSION}`;

// The heard words of one probe, stored (or a failure, counted against the probe).
export async function saveTranscript(
    db: D1Database,
    row: Pick<AboutRow, "post_key" | "item_id" | "probe_at">,
    heard: { ok: true; language: string | null; lines: Line[]; text: string | null; model: string } | { ok: false; model: string },
    now: number,
): Promise<void> {
    if (!heard.ok) {
        await db
            .prepare(
                `INSERT INTO media_transcripts (post_key, item_id, probe_at, state, model, attempts, failed_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, 'failed', ?4, 1, ?5, ?5, ?5)
                 ON CONFLICT (post_key) DO UPDATE SET
                   attempts = CASE WHEN media_transcripts.item_id = excluded.item_id AND media_transcripts.probe_at IS excluded.probe_at
                                   AND media_transcripts.state = 'failed' THEN media_transcripts.attempts + 1 ELSE 1 END,
                   item_id = excluded.item_id, probe_at = excluded.probe_at, model = excluded.model,
                   state = CASE WHEN media_transcripts.item_id = excluded.item_id AND media_transcripts.probe_at IS excluded.probe_at
                                AND media_transcripts.state <> 'failed' THEN media_transcripts.state ELSE 'failed' END,
                   failed_at = excluded.failed_at, updated_at = excluded.updated_at`,
            )
            .bind(row.post_key, row.item_id, row.probe_at, heard.model, now)
            .run();
        return;
    }
    const text = heard.lines.length > 0 ? linesText(heard.lines) : heard.text;
    await db
        .prepare(
            `INSERT INTO media_transcripts (post_key, item_id, probe_at, state, language, text, lines, model, attempts, failed_at, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, NULL, ?9, ?9)
             ON CONFLICT (post_key) DO UPDATE SET item_id = excluded.item_id, probe_at = excluded.probe_at, state = excluded.state,
               language = excluded.language, text = excluded.text, lines = excluded.lines, model = excluded.model, attempts = 0,
               failed_at = NULL, updated_at = excluded.updated_at`,
        )
        .bind(row.post_key, row.item_id, row.probe_at, text ? "done" : "no_speech", heard.language, text, JSON.stringify(heard.lines), heard.model, now)
        .run();
}

// The stored transcript of this probe when it was heard by this model (done or no speech), else null.
export async function heardTranscript(db: D1Database, row: Pick<AboutRow, "post_key" | "item_id" | "probe_at">, model: string): Promise<TranscriptRow | null> {
    const t = await db.prepare("SELECT * FROM media_transcripts WHERE post_key = ?1").bind(row.post_key).first<TranscriptRow>();
    if (!t || t.item_id !== row.item_id || t.probe_at !== row.probe_at || t.state === "failed" || t.model !== model) return null;
    return t;
}

// ---- the listening pass (the 15-minute cron) ---------------------------------------------------------------------------

export const TRANSCRIPT_RUN_BUDGET_MS = 60_000;
export const TRANSCRIPT_RUN_MAX = 40;
export const TRANSCRIPT_CONCURRENCY = 3;

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream; size: number } | null> };

export type ListenDeps = {
    db: D1Database;
    originals: ReadBucket;
    transcriber: Transcriber;
    now: () => number;
    budgetMs: number;
    max?: number;
    concurrency?: number;
};

export type ListenResult = { due: number; heard: number; failed: number; removed: number };

// The posts to hear: probe done with sound, and no transcript of that probe by this model yet (or a failure more than a
// day ago, fewer than ABOUT_MAX_ATTEMPTS times). Newest probe first. Transcripts whose post is gone, or whose post has no
// sound now, are removed first.
export async function dueTranscripts(db: D1Database, model: string, now: number): Promise<AboutRow[]> {
    const { results } = await db
        .prepare(
            `SELECT a.* FROM media_about a LEFT JOIN media_transcripts t ON t.post_key = a.post_key
             WHERE a.probe_state = 'done' AND a.has_audio = 1
               AND (t.post_key IS NULL OR t.item_id <> a.item_id OR t.probe_at IS NOT a.probe_at OR t.model IS NOT ?1
                    OR (t.state = 'failed' AND t.failed_at <= ?2 AND t.attempts < ?3))
             ORDER BY a.probe_at DESC, a.post_key`,
        )
        .bind(model, now - ABOUT_RETRY_MS, ABOUT_MAX_ATTEMPTS)
        .all<AboutRow>();
    return results;
}

export async function timeTranscripts(d: ListenDeps): Promise<ListenResult> {
    const start = d.now();
    const out: ListenResult = { due: 0, heard: 0, failed: 0, removed: 0 };
    const gone = await d.db
        .prepare(
            `DELETE FROM media_transcripts WHERE post_key NOT IN (SELECT post_key FROM media_about)
               OR post_key IN (SELECT post_key FROM media_about WHERE probe_state IN ('done', 'none') AND has_audio = 0)`,
        )
        .run();
    out.removed = gone.meta?.changes ?? 0;
    const model = transcriptModel(d.transcriber.model);
    const due = (await dueTranscripts(d.db, model, d.now())).slice(0, d.max ?? TRANSCRIPT_RUN_MAX);
    out.due = due.length;
    let i = 0;
    const worker = async () => {
        while (i < due.length && d.now() - start < d.budgetMs) {
            const row = due[i++]!;
            try {
                const ok = await hearOne(d.db, d.originals, d.transcriber, row, d.now);
                if (ok) out.heard++;
                else out.failed++;
            } catch (e) {
                out.failed++;
                console.error("[transcript] failed", row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
            }
        }
    };
    await Promise.all(Array.from({ length: Math.max(1, d.concurrency ?? TRANSCRIPT_CONCURRENCY) }, worker));
    return out;
}

// Hears one probe's sound and stores the transcript; the post's plain transcript (media_about, read by the describer
// and the search text) follows it. False when Whisper failed (counted). A missing audio object is a failure too.
export async function hearOne(
    db: D1Database,
    originals: ReadBucket,
    transcriber: Transcriber,
    row: Pick<AboutRow, "post_key" | "item_id" | "probe_at">,
    now: () => number,
): Promise<{ text: string | null; language: string | null } | null> {
    const model = transcriptModel(transcriber.model);
    const o = await originals.get(audioKey(row.item_id)).catch(() => null);
    if (!o) {
        await saveTranscript(db, row, { ok: false, model }, now());
        return null;
    }
    let heard;
    try {
        heard = await transcriber.transcribe(new Uint8Array(await new Response(o.body).arrayBuffer()));
    } catch (e) {
        console.error("[transcript] whisper failed", row.post_key, e instanceof Error ? e.message.slice(0, 200) : "error");
        await saveTranscript(db, row, { ok: false, model }, now());
        return null;
    }
    const lines = heard.lines ?? [];
    await saveTranscript(db, row, { ok: true, language: heard.language, lines, text: heard.text, model }, now());
    const text = lines.length > 0 ? clip(linesText(lines)) : heard.text;
    await db
        .prepare("UPDATE media_about SET transcript = ?2, language = ?3, updated_at = ?4 WHERE post_key = ?1 AND item_id = ?5")
        .bind(row.post_key, text, text ? heard.language : null, now(), row.item_id)
        .run();
    return { text, language: text ? heard.language : null };
}

const clip = (s: string) => Array.from(s).slice(0, TRANSCRIPT_MAX).join("");

// ---- moments: a vector for each stretch of speech ---------------------------------------------------------------------

export type Moment = { idx: number; s: number; e: number; t: string };

// a stretch closes once it holds this much text or time
export const MOMENT_MIN_CHARS = 120;
export const MOMENT_MAX_SECONDS = 12;
export const MOMENT_MAX_PER_POST = 60;
export const MOMENTS_RUN_BUDGET_MS = 45_000;
// Bumped when stretches are cut differently: every moment is embedded again.
export const MOMENT_VERSION = "m1";

export function momentsOf(lines: Line[]): Moment[] {
    const out: Moment[] = [];
    let group: Line[] = [];
    const flush = () => {
        if (group.length === 0 || out.length >= MOMENT_MAX_PER_POST) return void (group = []);
        out.push({ idx: out.length, s: group[0]!.s, e: group[group.length - 1]!.e, t: group.map((l) => l.t).join(" ") });
        group = [];
    };
    for (const l of lines) {
        group.push(l);
        const chars = group.reduce((n, g) => n + g.t.length + 1, 0);
        if (chars >= MOMENT_MIN_CHARS || l.e - group[0]!.s >= MOMENT_MAX_SECONDS) flush();
    }
    flush();
    return out;
}

async function sha256(s: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type MomentsResult = { posts: number; embedded: number; removed: number; unavailable: boolean };

// Brings `media_moments` up to the transcripts: removes the stretches of posts without a transcript (and the ones past a
// post's last stretch), and embeds (document mode, EMBED_BATCH a call) every stretch whose text changed, while the budget
// lasts. A stretch the Space refuses keeps no vector (it is tried again when its text changes).
export async function indexMoments(d: { db: D1Database; client: EmbedClient; now: () => number; budgetMs: number }): Promise<MomentsResult> {
    const start = d.now();
    const out: MomentsResult = { posts: 0, embedded: 0, removed: 0, unavailable: false };
    const gone = await d.db
        .prepare("DELETE FROM media_moments WHERE post_key NOT IN (SELECT post_key FROM media_transcripts WHERE state = 'done')")
        .run();
    out.removed += gone.meta?.changes ?? 0;
    const { results: ts } = await d.db
        .prepare("SELECT post_key, lines FROM media_transcripts WHERE state = 'done' ORDER BY updated_at DESC, post_key")
        .all<{ post_key: string; lines: string | null }>();
    const { results: have } = await d.db
        .prepare("SELECT post_key, idx, input_hash, model, dims, vector IS NOT NULL AS has FROM media_moments")
        .all<{ post_key: string; idx: number; input_hash: string; model: string | null; dims: number | null; has: number }>();
    const known = new Map(have.map((h) => [`${h.post_key}\u0000${h.idx}`, h]));
    const todo: { post_key: string; m: Moment; hash: string }[] = [];
    const now = d.now();
    for (const t of ts) {
        out.posts++;
        const ms = momentsOf(parseLines(t.lines));
        const stmts: D1PreparedStatement[] = [
            d.db.prepare("DELETE FROM media_moments WHERE post_key = ?1 AND idx >= ?2").bind(t.post_key, ms.length),
        ];
        for (const m of ms) {
            const hash = await sha256(`${MOMENT_VERSION}\u0000${m.t}`);
            const k = known.get(`${t.post_key}\u0000${m.idx}`);
            if (k && k.input_hash === hash) {
                if (!k.has || k.model !== EMBED_MODEL || k.dims !== EMBED_DIMS) todo.push({ post_key: t.post_key, m, hash });
                continue;
            }
            stmts.push(
                d.db
                    .prepare(
                        `INSERT INTO media_moments (post_key, idx, start, "end", text, input_hash, model, dims, vector, updated_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, NULL, ?7)
                         ON CONFLICT (post_key, idx) DO UPDATE SET start = excluded.start, "end" = excluded."end", text = excluded.text,
                           input_hash = excluded.input_hash, model = NULL, dims = NULL, vector = NULL, updated_at = excluded.updated_at`,
                    )
                    .bind(t.post_key, m.idx, m.s, m.e, m.t, hash, now),
            );
            todo.push({ post_key: t.post_key, m, hash });
        }
        await runAll(d.db, stmts);
    }
    for (let i = 0; i < todo.length; i += EMBED_BATCH) {
        const left = d.budgetMs - (d.now() - start);
        if (left < 2_000) break;
        const batch = todo.slice(i, i + EMBED_BATCH);
        try {
            const r = await d.client.embed("document", batch.map((b) => ({ title: null, text: b.m.t, image_url: null })), Math.min(EMBED_CALL_MS, left));
            await runAll(
                d.db,
                batch.map((b, j) =>
                    d.db
                        .prepare("UPDATE media_moments SET model = ?4, dims = ?5, vector = ?6, updated_at = ?7 WHERE post_key = ?1 AND idx = ?2 AND input_hash = ?3")
                        .bind(b.post_key, b.m.idx, b.hash, r.model, EMBED_DIMS, encodeVector(r.vectors[j]!), d.now()),
                ),
            );
            out.embedded += batch.length;
        } catch (e) {
            if (!(e instanceof EmbedError) || e.kind === "unavailable") {
                out.unavailable = true;
                break;
            }
            // a refused batch: skipped this run (the texts are plain words, so this should not happen)
            console.error("[moments] batch refused", e.message);
        }
    }
    return out;
}

// ---- search: where the words were said ---------------------------------------------------------------------------------

export type Said = { start: number; end: number; text: string; match: "words" | "meaning" };

export const SAID_MAX = 5;
// a moment explains a hit when its score is at least this, and within MOMENT_SLACK of the post's own score
export const MOMENT_FLOOR = 0.25;
export const MOMENT_SLACK = 0.05;

export type SaidIndex = {
    // the full heard text of each post with a transcript, lowercase
    text: Map<string, string>;
    // each post's best moment for the query vector (null when there is no query vector)
    best: Map<string, { score: number; s: number; e: number; t: string }>;
};

// `queryVector` may still be on its way: both tables are read while it is, then the moments are scored.
export async function saidIndex(db: D1Database, queryVector: number[] | null | Promise<number[] | null>): Promise<SaidIndex> {
    const text = new Map<string, string>();
    const best = new Map<string, { score: number; s: number; e: number; t: string }>();
    try {
        const [{ results }, { results: ms }] = await Promise.all([
            db.prepare("SELECT post_key, text FROM media_transcripts WHERE state = 'done' AND text IS NOT NULL").all<{ post_key: string; text: string }>(),
            db
                .prepare(`SELECT post_key, start, "end" AS e, text, vector FROM media_moments WHERE model = ?1 AND dims = ?2 AND vector IS NOT NULL`)
                .bind(EMBED_MODEL, EMBED_DIMS)
                .all<{ post_key: string; start: number; e: number; text: string; vector: string }>(),
        ]);
        for (const r of results) text.set(r.post_key, r.text.toLowerCase());
        const qv = await queryVector;
        if (qv) {
            for (const m of ms) {
                const v = decodeVector(m.vector);
                if (!v || v.length !== EMBED_DIMS) continue;
                const score = dot(qv, v);
                const was = best.get(m.post_key);
                if (!was || score > was.score) best.set(m.post_key, { score, s: m.start, e: m.e, t: m.text });
            }
        }
    } catch (e) {
        // before migration 0030: search works as before
        if (!/no such table/i.test(String(e))) throw e;
    }
    return { text, best };
}

// The lines of the given posts that hold the query (lowercase, whole), at most SAID_MAX each, in order.
export async function saidLines(db: D1Database, postKeys: string[], needle: string): Promise<Map<string, Said[]>> {
    const out = new Map<string, Said[]>();
    if (postKeys.length === 0 || !needle) return out;
    for (let i = 0; i < postKeys.length; i += 50) {
        const keys = postKeys.slice(i, i + 50);
        const { results } = await db
            .prepare(`SELECT post_key, lines FROM media_transcripts WHERE state = 'done' AND post_key IN (${keys.map((_, j) => `?${j + 1}`).join(", ")})`)
            .bind(...keys)
            .all<{ post_key: string; lines: string | null }>();
        for (const r of results) {
            const hits = parseLines(r.lines)
                .filter((l) => l.t.toLowerCase().includes(needle))
                .slice(0, SAID_MAX)
                .map((l): Said => ({ start: l.s, end: l.e, text: l.t, match: "words" }));
            if (hits.length > 0) out.set(r.post_key, hits);
        }
    }
    return out;
}

// ---- GET /library/transcript --------------------------------------------------------------------------------------------

export type TranscriptAnswerState = "done" | "no_speech" | "pending" | "no_sound" | "failed" | "off";

export type TranscriptLineOut = { start: number; end: number; text: string; words?: { text: string; start: number; end: number }[] };

export type TranscriptAnswer = {
    post_key: string;
    state: TranscriptAnswerState;
    language: string | null;
    model: string | null;
    updated_at: number | null;
    lines: TranscriptLineOut[];
};

export class TranscriptNotFound extends Error {}

// The transcript of one post (`words: false` leaves the words out; `from`/`to` keep the lines that overlap them).
export async function transcriptOf(
    d: { db: D1Database; soundOn: boolean },
    key: string,
    opts: { words?: boolean; from?: number; to?: number } = {},
): Promise<TranscriptAnswer> {
    const leads = await postLeads(d.db, key);
    const post = leads.get(key);
    if (!post) throw new TranscriptNotFound(key);
    const about = await d.db.prepare("SELECT * FROM media_about WHERE post_key = ?1").bind(key).first<AboutRow>();
    let t: TranscriptRow | null = null;
    try {
        t = await d.db.prepare("SELECT * FROM media_transcripts WHERE post_key = ?1").bind(key).first<TranscriptRow>();
    } catch (e) {
        if (!/no such table/i.test(String(e))) throw e;
    }
    const fresh = !!t && !!about && t.item_id === about.item_id && t.probe_at === about.probe_at;
    let state: TranscriptAnswerState;
    if (fresh && t!.state !== "failed") state = t!.state;
    else if (fresh && t!.attempts >= ABOUT_MAX_ATTEMPTS) state = "failed";
    else if (!probeable(post.lead.content_type) || about?.probe_state === "none") state = "no_sound";
    else if (about?.probe_state === "failed" && about.probe_attempts >= ABOUT_MAX_ATTEMPTS) state = "failed";
    else if (about?.probe_state === "done" && !about.has_audio) state = "no_sound";
    else state = "pending";
    if (state === "pending" && !d.soundOn) state = "off";
    const from = opts.from ?? 0;
    const to = opts.to ?? Infinity;
    const lines = state === "done" ? parseLines(t!.lines).filter((l) => l.e >= from && l.s <= to) : [];
    return {
        post_key: key,
        state,
        language: state === "done" ? (t!.language ?? null) : null,
        model: fresh ? (t!.model ?? null) : null,
        updated_at: fresh ? t!.updated_at : null,
        lines: lines.map((l) => ({
            start: l.s,
            end: l.e,
            text: l.t,
            ...(opts.words === false ? {} : { words: l.w.map((w) => ({ text: w.t, start: w.s, end: w.e })) }),
        })),
    };
}
