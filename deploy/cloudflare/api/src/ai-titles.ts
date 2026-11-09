// AI video titles (APP-API-CONTRACT.md section 53): MiniMax M3.1 Flash watches each video post and writes its title.
// Owner, 2026-11-09: "having video titles be created by minimax-m3.1-flash ... reading the video and outputting title",
// "backlogged and rewrite all the titles in prod", then (after a 10-clip test, video vs video + transcript) "implement
// your suggestion": video only, the transcript added only for videos longer than 2 minutes, provider pinned to Together.
//
// The 15-minute cron titles new videos and works through the backlog (titleVideos). A title goes into media_titles with
// key_id 'ai:titles', so every place that shows custom titles shows it; a title the owner set is never replaced. What
// was asked and what it cost is kept per post in media_ai_titles (migration 0037). Only public videos (the model fetches
// the public media URL); a gallery is left alone. Off unless OPENROUTER_API_KEY is set (and AI_TITLES is not "0").
// Free of Cloudflare imports so it runs under node in the tests.

import { pickLead, type LeadFields } from "./about-store";
import { hiddenRows } from "./hidden-store";
import { POST_KEY_SQL } from "./post-key";
import { MAX_TITLE_CODE_POINTS, cleanTitle } from "./studio";
import { effectiveVisibility } from "./visibility";

export const AI_TITLE_MODEL_DEFAULT = "minimax/minimax-m3.1-flash";
// Bumped when the prompt changes: every AI title is written again.
export const AI_TITLE_STYLE = "v1";
export const AI_TITLE_KEY_ID = "ai:titles";
// Longer videos get their transcript too (the test: it helped the long talky ones, and hurt short clips by copying
// transcription mistakes).
export const AI_TITLE_TRANSCRIPT_FROM_S = 120;
export const AI_TITLE_TRANSCRIPT_MAX = 4000;
// OpenRouter provider slug. Together counted video at ~175 tokens per second; StreamLake at about twice that.
export const AI_TITLE_PROVIDER = "together";
export const AI_TITLE_CALL_MS = 90_000;
export const AI_TITLE_RETRY_MS = 24 * 60 * 60 * 1000;
export const AI_TITLE_MAX_ATTEMPTS = 3;
// Each 15-minute run: at most this many calls, this many at once, inside this budget (the backlog of ~700 videos
// clears in about 7 hours).
export const AI_TITLE_RUN_MAX = 24;
export const AI_TITLE_CONCURRENCY = 4;
export const AI_TITLE_RUN_BUDGET_MS = 75_000;

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

const SYSTEM = `You title videos for a personal media library. Watch the whole video (picture and sound) and reply with only a title: at most 10 words, specific about who or what is shown and what happens. Write it in sentence case. Describe things plainly: no crude or sexual wording, never mean about the people shown. No emoji, no quotation marks, no hashtags, no "video of", no ending full stop.`;

export type TitleInput = { videoUrl: string; duration: number | null; transcript: string | null };
export type TitleAnswer = {
    title: string;
    promptTokens: number | null;
    completionTokens: number | null;
    cost: number | null;
};
export type Titler = { model: string; title(input: TitleInput): Promise<TitleAnswer> };

export type TitlerEnv = { OPENROUTER_API_KEY?: string; AI_TITLE_MODEL?: string; AI_TITLES?: string };

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

// The model's answer as a stored title: first line, no wrapping quotes, no trailing full stop, spaces collapsed, at
// most MAX_TITLE_CODE_POINTS (cut at a word). Null when nothing usable is left.
export function fitTitle(raw: unknown): string | null {
    if (typeof raw !== "string") return null;
    let t = raw
        .replace(/<think>[\s\S]*?<\/think>/gi, "")
        .trim()
        .split(/\r?\n/)
        .map((l) => l.trim())
        .find((l) => l !== "");
    if (!t) return null;
    t = t.replace(/^(?:title\s*:\s*)/i, "").replace(/^[#*\s]+|[*\s]+$/g, "");
    t = t.replace(/^["'“”‘’「『]+|["'“”‘’」』]+$/g, "").trim();
    t = t.replace(/\.$/, "").replace(/\s+/g, " ").trim();
    const cps = Array.from(t);
    if (cps.length > MAX_TITLE_CODE_POINTS) {
        const cut = cps.slice(0, MAX_TITLE_CODE_POINTS).join("");
        const at = cut.lastIndexOf(" ");
        t = (at > 20 ? cut.slice(0, at) : cut).replace(/[\s,;:–—-]+$/, "");
    }
    const c = cleanTitle(t);
    return c.ok && c.title ? c.title : null;
}

// The user text: the transcript only for long videos that have one.
export function userText(input: TitleInput): string {
    if (input.transcript && (input.duration ?? 0) > AI_TITLE_TRANSCRIPT_FROM_S) {
        return `Title this video. Transcript of what is said (machine transcription, may contain errors):\n${input.transcript.slice(0, AI_TITLE_TRANSCRIPT_MAX)}`;
    }
    return "Title this video.";
}

export function titleRequest(model: string, input: TitleInput): Record<string, unknown> {
    return {
        model,
        messages: [
            { role: "system", content: SYSTEM },
            {
                role: "user",
                content: [
                    { type: "video_url", video_url: { url: input.videoUrl } },
                    { type: "text", text: userText(input) },
                ],
            },
        ],
        // The model always reasons first (default effort "max"); low effort and room to answer, or the title is empty.
        reasoning: { effort: "low" },
        max_tokens: 1000,
        temperature: 0.3,
        usage: { include: true },
        provider: { order: [AI_TITLE_PROVIDER], allow_fallbacks: false },
    };
}

// OpenRouter's answer as a title, or a thrown Error naming what went wrong.
export function parseAnswer(body: unknown): TitleAnswer {
    const b = body as { choices?: { message?: { content?: unknown } }[]; usage?: Record<string, unknown>; error?: { message?: unknown } };
    if (b?.error) throw new Error(`openrouter: ${String(b.error.message ?? "error").slice(0, 200)}`);
    const content = b?.choices?.[0]?.message?.content;
    const text = Array.isArray(content)
        ? content.map((p) => (typeof p === "object" && p && "text" in p ? String((p as { text: unknown }).text) : "")).join("")
        : content;
    const title = fitTitle(text);
    if (!title) throw new Error("empty title");
    return {
        title,
        promptTokens: num(b.usage?.prompt_tokens),
        completionTokens: num(b.usage?.completion_tokens),
        cost: num(b.usage?.cost),
    };
}

export function titlerFrom(env: TitlerEnv, fetchFn: typeof fetch = fetch): Titler | null {
    const key = (env.OPENROUTER_API_KEY ?? "").trim();
    if (!key || env.AI_TITLES === "0") return null;
    const model = (env.AI_TITLE_MODEL ?? "").trim() || AI_TITLE_MODEL_DEFAULT;
    return {
        model,
        async title(input) {
            const ctrl = new AbortController();
            let timer: ReturnType<typeof setTimeout> | undefined;
            const timeout = new Promise<never>((_, reject) => {
                timer = setTimeout(() => {
                    ctrl.abort();
                    reject(new Error("timeout"));
                }, AI_TITLE_CALL_MS);
            });
            try {
                const res = await Promise.race([
                    fetchFn(OPENROUTER_URL, {
                        method: "POST",
                        headers: {
                            authorization: `Bearer ${key}`,
                            "content-type": "application/json",
                            "x-title": "capystore",
                        },
                        body: JSON.stringify(titleRequest(model, input)),
                        signal: ctrl.signal,
                    }),
                    timeout,
                ]);
                const text = await Promise.race([res.text(), timeout]);
                let body: unknown = null;
                try {
                    body = JSON.parse(text);
                } catch {
                    // not JSON
                }
                if (!res.ok) {
                    const msg = (body as { error?: { message?: unknown } } | null)?.error?.message;
                    throw new Error(`openrouter ${res.status}: ${String(msg ?? text).slice(0, 200)}`);
                }
                return parseAnswer(body);
            } finally {
                clearTimeout(timer);
            }
        },
    };
}

// ---- which posts are due ------------------------------------------------------------------------------------------------

type FileRow = LeadFields & {
    id: string;
    r2_key: string;
    public_key: string | null;
    visibility: string | null;
    duration: number | null;
    created_at: number;
    post_key: string;
};

type StateRow = { post_key: string; item_id: string; state: string; style: string | null; model: string | null; attempts: number; updated_at: number };

export type DueTitle = { postKey: string; itemId: string; videoUrl: string; duration: number | null; attempts: number };

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const PUBLIC_NAME = /^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/;

// Posts whose lead file is a public video (not a gallery, not hidden, no title the owner set) and that have no AI title
// of this model and style for that file yet, or a failure due for a retry. Newest first.
export async function dueTitles(db: D1Database, mediaBaseUrl: string, model: string, now: number): Promise<DueTitle[]> {
    const { results: files } = await db
        .prepare(
            `SELECT * FROM (SELECT m.id, m.bucket, m.r2_key, m.public_key, m.visibility, m.content_type, m.source, m.role, m.item_index,
                                   m.duration, m.created_at, ${POST_KEY_SQL} AS post_key
                            FROM media_items m WHERE m.deleted_at IS NULL)
             ORDER BY created_at DESC, id DESC`,
        )
        .all<FileRow>();
    const byPost = new Map<string, FileRow[]>();
    for (const f of files) {
        const list = byPost.get(f.post_key);
        if (list) list.push(f);
        else byPost.set(f.post_key, [f]);
    }
    const { results: owned } = await db
        .prepare("SELECT post_key FROM media_titles WHERE key_id IS NULL OR key_id <> ?1")
        .bind(AI_TITLE_KEY_ID)
        .all<{ post_key: string }>();
    const ownerTitled = new Set(owned.map((r) => r.post_key));
    const { results: states } = await db.prepare("SELECT post_key, item_id, state, style, model, attempts, updated_at FROM media_ai_titles").all<StateRow>();
    const stateOf = new Map(states.map((s) => [s.post_key, s]));
    const hidden = await hiddenRows(db);
    const media = withSlash(mediaBaseUrl);

    const out: DueTitle[] = [];
    for (const [postKey, list] of byPost) {
        if (ownerTitled.has(postKey)) continue;
        if (hidden.get(postKey)?.state === "hidden") continue;
        if (list.some((f) => f.role === "item")) continue; // a gallery
        const lead = pickLead(list) ?? list[0]!;
        if (!(lead.content_type ?? "").toLowerCase().startsWith("video/")) continue;
        if (effectiveVisibility(lead) !== "public") continue;
        const key = lead.bucket === "media" ? lead.r2_key : lead.public_key;
        if (!key || !PUBLIC_NAME.test(key)) continue;
        const s = stateOf.get(postKey);
        let attempts = 0;
        if (s && s.item_id === lead.id && s.model === model && s.style === AI_TITLE_STYLE) {
            if (s.state !== "failed") continue;
            if (s.attempts >= AI_TITLE_MAX_ATTEMPTS || s.updated_at > now - AI_TITLE_RETRY_MS) continue;
            attempts = s.attempts;
        }
        out.push({ postKey, itemId: lead.id, videoUrl: `${media}${key}`, duration: lead.duration, attempts });
    }
    return out;
}

// The post's transcript as plain text (section 47), or null.
export async function transcriptText(db: D1Database, postKey: string): Promise<string | null> {
    const t = await db
        .prepare("SELECT state, text FROM media_transcripts WHERE post_key = ?1")
        .bind(postKey)
        .first<{ state: string; text: string | null }>()
        .catch(() => null);
    const text = t?.state === "done" ? (t.text ?? "").replace(/\s+/g, " ").trim() : "";
    return text || null;
}

// ---- writing ------------------------------------------------------------------------------------------------------------

export type TitleDeps = {
    db: D1Database;
    titler: Titler;
    mediaBaseUrl: string;
    now: () => number;
    budgetMs?: number;
    max?: number;
    concurrency?: number;
};

export type TitleResult = { due: number; written: number; kept: number; failed: number };

// One post: ask, then record the answer and (unless the owner titled the post meanwhile) set the title.
export async function titleOne(d: Omit<TitleDeps, "mediaBaseUrl">, job: DueTitle): Promise<"written" | "kept" | "failed"> {
    const long = (job.duration ?? 0) > AI_TITLE_TRANSCRIPT_FROM_S;
    const transcript = long ? await transcriptText(d.db, job.postKey) : null;
    let answer: TitleAnswer | null = null;
    let error: string | null = null;
    try {
        answer = await d.titler.title({ videoUrl: job.videoUrl, duration: job.duration, transcript });
    } catch (e) {
        error = (e instanceof Error ? e.message : String(e)).slice(0, 300);
        console.error("[titles] failed", job.postKey, error);
    }
    const now = d.now();
    let outcome: "written" | "kept" | "failed" = "failed";
    if (answer) {
        // Never over a title the owner set (also one set while the model was watching).
        const r = await d.db
            .prepare(
                `INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(post_key) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at
                 WHERE media_titles.key_id = ?3`,
            )
            .bind(job.postKey, answer.title, AI_TITLE_KEY_ID, now)
            .run();
        outcome = (r.meta?.changes ?? 1) > 0 ? "written" : "kept";
    }
    await d.db
        .prepare(
            `INSERT INTO media_ai_titles (post_key, item_id, state, title, model, style, with_transcript, prompt_tokens, completion_tokens, cost, attempts, error, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(post_key) DO UPDATE SET item_id = excluded.item_id, state = excluded.state, title = excluded.title, model = excluded.model,
               style = excluded.style, with_transcript = excluded.with_transcript, prompt_tokens = excluded.prompt_tokens,
               completion_tokens = excluded.completion_tokens, cost = excluded.cost, attempts = excluded.attempts, error = excluded.error,
               updated_at = excluded.updated_at`,
        )
        .bind(
            job.postKey,
            job.itemId,
            answer ? (outcome === "kept" ? "skipped" : "done") : "failed",
            answer?.title ?? null,
            d.titler.model,
            AI_TITLE_STYLE,
            transcript ? 1 : 0,
            answer?.promptTokens ?? null,
            answer?.completionTokens ?? null,
            answer?.cost ?? null,
            answer ? 0 : job.attempts + 1,
            error,
            now,
        )
        .run();
    return outcome;
}

// The cron's pass: newest due posts first, up to `max` calls inside the budget. Throws before migration 0037.
export async function titleVideos(d: TitleDeps): Promise<TitleResult> {
    const start = d.now();
    const budget = d.budgetMs ?? AI_TITLE_RUN_BUDGET_MS;
    const due = await dueTitles(d.db, d.mediaBaseUrl, d.titler.model, start);
    const jobs = due.slice(0, d.max ?? AI_TITLE_RUN_MAX);
    const out: TitleResult = { due: due.length, written: 0, kept: 0, failed: 0 };
    let i = 0;
    const worker = async () => {
        while (i < jobs.length && d.now() - start < budget) {
            const job = jobs[i++]!;
            try {
                out[await titleOne(d, job)]++;
            } catch (e) {
                out.failed++;
                console.error("[titles] record failed", job.postKey, e instanceof Error ? e.name : "error");
            }
        }
    };
    await Promise.all(Array.from({ length: Math.max(1, d.concurrency ?? AI_TITLE_CONCURRENCY) }, worker));
    return out;
}
