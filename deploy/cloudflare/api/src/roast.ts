// Captions (APP-API-CONTRACT.md section 25): one sentence summing up every public file and gallery
// link, in a cute, funny furry anime cat-girl voice with kaomoji, never emoji, never announcing itself.
// Owner, 2026-10-18: "just make it one sentence summary of all the content ... a cute furry cat girl ...
// don't announce urself", "furry anime girl ascii emoji cute funny", "the ai summary can just be the
// title". The sentence is the preview title; the description is left empty and ignored.
// Written once by Claude Haiku and stored in D1 (media_captions), so a share page never waits on the
// model: new gallery links get theirs at creation (bounded wait), everything else from the
// 15-minute cron backfill. Off unless ANTHROPIC_API_KEY is set.

import Anthropic from "@anthropic-ai/sdk";
import { POST_KEY_SQL } from "./app-routes";
import type { ModelFetch } from "./model-fetch";
import { ITEM_COLUMNS, effectiveVisibility, visSql, type MediaRow } from "./visibility";

export const ROAST_MODEL_DEFAULT = "claude-haiku-5-5";
// The sentence the model is asked for, and the hard cap: a longer one is asked for again once, then cut at a word.
export const ROAST_TITLE_TARGET = 110;
export const ROAST_TITLE_MAX = 140;
// Bumped when the voice changes: captions written in an older style are rewritten by the backfill. Captions of
// CAPTION_STYLE_CUT (the previous style) are rewritten only when they were cut off (they end in "...").
export const CAPTION_STYLE = "v4-kaomoji-catgirl-short";
export const CAPTION_STYLE_CUT = "v3-kaomoji-catgirl";
export const ROAST_DESC_MAX = 280;
// A failed caption is retried after this long, at most ROAST_MAX_ATTEMPTS times.
export const ROAST_RETRY_MS = 24 * 60 * 60 * 1000;
export const ROAST_MAX_ATTEMPTS = 3;

export type Caption = { title: string; description: string };

export type RoastFile = {
    name: string | null; // the file or post title
    link: string | null; // where it was saved from
    kind: "video" | "image";
    duration: number | null;
    imageUrl: string | null; // a public jpeg/png/gif/webp to look at (a video's poster), or null
};

export type RoastInput = { files: RoastFile[]; userTitle: string | null };

export type Captioner = { model: string; caption(input: RoastInput): Promise<Caption> };

const SYSTEM = `You write the link preview title for files Harmony shares with friends on Discord: ONE short sentence that sums up all of the content (every file, if there are several): at most 110 characters, kaomoji included. Shorter is better; leave out details rather than run long.

Voice: a cute, funny furry anime cat girl talking to Harmony, warm and playfully teasing, decorated with one or two kaomoji text faces such as (=^･ω･^=), ฅ^•ﻌ•^ฅ, (≧▽≦), >w<, :3 or UwU (vary them; a soft "nya" now and then is fine). Never use emoji pictures. Never introduce yourself, never name yourself or say what you are, never mention being a cat, a bot or an AI: just say the sentence. Keep it wholesome: nothing sexual or suggestive, no jokes about bodies, race, religion or identity, never mean about the people shown.

Describe what is actually there (what you can see in the pictures, the titles, where it was saved from); don't invent facts. No hashtags, no links, no quotation marks around the sentence.`;

const SCHEMA = {
    type: "object",
    properties: {
        summary: { type: "string", description: "One short sentence, at most 110 characters including a kaomoji, no emoji, summing up all the content." },
    },
    required: ["summary"],
    additionalProperties: false,
};

const IMAGE_TYPES = /\.(jpe?g|png|gif|webp)(?:$|\?)/i;

const sourceOf = (link: string | null): string | null => {
    if (!link) return null;
    try {
        return new URL(link).hostname.replace(/^www\./, "");
    } catch {
        return null;
    }
};

function describe(input: RoastInput): string {
    const lines: string[] = [];
    lines.push(input.files.length > 1 ? `A gallery link with ${input.files.length} files:` : "One file:");
    input.files.forEach((f, i) => {
        const bits = [
            `${input.files.length > 1 ? `${i + 1}. ` : ""}${f.kind}`,
            f.duration ? `${Math.round(f.duration)} s` : null,
            f.name ? `titled "${f.name.slice(0, 200)}"` : null,
            sourceOf(f.link) ? `saved from ${sourceOf(f.link)}` : null,
            f.imageUrl ? "(picture attached)" : null,
        ].filter(Boolean);
        lines.push(bits.join(", "));
    });
    if (input.userTitle) lines.push(`Harmony titled the link "${input.userTitle}".`);
    lines.push("Write the one-sentence summary.");
    return lines.join("\n");
}

const clip = (s: string, max: number): string => {
    // eslint-disable-next-line no-control-regex
    const t = s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
    const cps = Array.from(t);
    return cps.length > max ? `${cps.slice(0, max - 1).join("").trimEnd()}…` : t;
};

// The Anthropic API (optionally through Cloudflare AI Gateway: baseURL
// https://gateway.ai.cloudflare.com/v1/<account>/<gateway>/anthropic), or null while no key is set.
export function captionerFrom(
    env: { ANTHROPIC_API_KEY?: string; ROAST_BASE_URL?: string; ROAST_MODEL?: string },
    modelFetch?: ModelFetch,
): Captioner | null {
    const apiKey = env.ANTHROPIC_API_KEY?.trim();
    if (!apiKey) return null;
    const baseURL = env.ROAST_BASE_URL?.trim() || undefined;
    const model = env.ROAST_MODEL?.trim() || ROAST_MODEL_DEFAULT;
    const client = new Anthropic({ apiKey, baseURL, maxRetries: 1, timeout: 30_000, ...(modelFetch ? { fetch: modelFetch } : {}) });
    return {
        model: `${model}+${CAPTION_STYLE}`,
        async caption(input) {
            const images = input.files
                .map((f) => f.imageUrl)
                .filter((u): u is string => !!u && IMAGE_TYPES.test(u))
                .slice(0, 4);
            const first: ChatTurn[] = [
                {
                    role: "user",
                    content: [
                        ...images.map((url) => ({ type: "image" as const, source: { type: "url" as const, url } })),
                        { type: "text" as const, text: describe(input) },
                    ],
                },
            ];
            return captionWithRetry(async (messages) => {
                const response = await client.messages.create({
                    model,
                    max_tokens: 2000,
                    system: SYSTEM,
                    output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
                    messages,
                });
                if (response.stop_reason === "refusal") throw new Error("refusal");
                return response.content.map((b) => (b.type === "text" ? b.text : "")).join("");
            }, first);
        },
    };
}

// No emoji: anything drawn as a colour emoji by default, and the joiners, selectors, skin tones, keycaps and
// flags that build them, are removed; kaomoji (=^･ω･^=) and text symbols like ♡ stay. Control characters go.
export const stripEmoji = (t: string): string =>
    t
        .replace(/\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F|[\uFE0E\uFE0F\u200D\u20E3]|[\u{1F3FB}-\u{1F3FF}]|[\u{1F1E6}-\u{1F1FF}]/gu, "")
        // eslint-disable-next-line no-control-regex
        .replace(/[\u0000-\u001f\u007f]/g, " ")
        .replace(/\s+/g, " ")
        .trim();

type ChatTurn = Anthropic.MessageParam;

/** The model's sentence, emoji removed and whitespace collapsed (not cut). */
export function readSummary(text: string): string {
    const v = JSON.parse(text) as { summary?: unknown; title?: unknown };
    const raw = typeof v.summary === "string" ? v.summary : typeof v.title === "string" ? v.title : null;
    if (raw === null) throw new Error("bad caption");
    const s = stripEmoji(raw);
    if (!s) throw new Error("empty caption");
    return s;
}

// A trailing kaomoji or text face: the last word when it has no letters (=^･ω･^=), (≧▽≦), ♡, or is a known face.
const FACE = /^(?:[^\p{L}\p{N}]*[^\p{L}\p{N}\s.,!?]+[^\p{L}\p{N}]*|.*[()^ω･•ﻌ≧≦▽ฅ♡<>].*|[:;x]3|uwu|owo|nya~?)$/iu;

/** Last resort for a sentence over ROAST_TITLE_MAX: cut at a word boundary with "...", keeping a closing kaomoji. */
export function fitCaption(s: string, max = ROAST_TITLE_MAX): string {
    const cps = Array.from(s);
    if (cps.length <= max) return s;
    const words = s.split(" ");
    const last = words[words.length - 1] ?? "";
    const face = words.length > 1 && FACE.test(last) && Array.from(last).length <= 16 ? last : "";
    const body = face ? words.slice(0, -1) : words;
    const room = max - 3 - (face ? Array.from(face).length + 1 : 0);
    let out = "";
    for (const w of body) {
        const next = out ? `${out} ${w}` : w;
        if (Array.from(next).length > room) break;
        out = next;
    }
    if (!out) out = Array.from(body.join(" ")).slice(0, room).join("");
    out = out.replace(/[\s,;:.!?-]+$/u, "");
    return face ? `${out}... ${face}` : `${out}...`;
}

/** Ask, and once more when the sentence runs over ROAST_TITLE_MAX; cut only if the second answer is long too. */
export async function captionWithRetry(call: (messages: ChatTurn[]) => Promise<string>, first: ChatTurn[]): Promise<Caption> {
    const text = await call(first);
    let s = readSummary(text);
    if (Array.from(s).length > ROAST_TITLE_MAX) {
        try {
            const again = await call([
                ...first,
                { role: "assistant", content: text },
                {
                    role: "user",
                    content: `That is ${Array.from(s).length} characters. Write it again as one sentence of at most ${ROAST_TITLE_TARGET} characters, kaomoji included, keeping the same voice.`,
                },
            ]);
            const t = readSummary(again);
            if (Array.from(t).length < Array.from(s).length) s = t;
        } catch {
            // keep the first answer and cut it below
        }
    }
    return { title: fitCaption(s), description: "" };
}

export function parseCaption(text: string): Caption {
    return { title: fitCaption(readSummary(text)), description: "" };
}

// ---- storage --------------------------------------------------------------------------------------

export const itemSubject = (id: string) => `item:${id}`;
export const setSubject = (id: string) => `set:${id}`;

export async function captionOf(db: D1Database, subject: string): Promise<Caption | null> {
    try {
        const r = await db
            .prepare("SELECT title, description FROM media_captions WHERE subject = ?1 AND title IS NOT NULL")
            .bind(subject)
            .first<{ title: string; description: string | null }>();
        // the title is the whole caption (owner: "not additional description"); older rows' descriptions are ignored
        return r ? { title: r.title, description: "" } : null;
    } catch {
        return null; // before migration 0013, or D1 trouble: the page shows what it did before
    }
}

async function record(db: D1Database, subject: string, model: string, now: number, c: Caption | null, skip = false): Promise<void> {
    // a skip (nothing to caption: no page, no files left) is stored as used-up attempts, so it is not picked again
    await db
        .prepare(
            `INSERT INTO media_captions (subject, title, description, model, created_at, attempts) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT (subject) DO UPDATE SET title = excluded.title, description = excluded.description,
               model = excluded.model, created_at = excluded.created_at,
               attempts = CASE WHEN ?6 > 1 THEN ?6 ELSE media_captions.attempts + 1 END`,
        )
        .bind(subject, c?.title ?? null, c?.description ?? null, model, now, skip ? ROAST_MAX_ATTEMPTS : 1)
        .run();
}

// Write one caption; a failure is recorded (retried later) and never thrown.
export async function writeCaption(
    d: { db: D1Database; captioner: Captioner; now: () => number },
    subject: string,
    input: RoastInput,
): Promise<Caption | null> {
    let c: Caption | null = null;
    try {
        c = await d.captioner.caption(input);
    } catch (e) {
        console.error("[roast] caption failed", subject, e instanceof Error ? e.message.slice(0, 200) : "error");
    }
    try {
        await record(d.db, subject, d.captioner.model, d.now(), c);
    } catch {
        // D1 trouble: the next cron run tries again
    }
    return c;
}

// The model input for a media row (public URL or poster to look at when it is a picture).
export function fileOf(r: MediaRow & { custom_title?: string | null }, url: string | null): RoastFile {
    const type = (r.content_type ?? "").toLowerCase();
    const kind = type.startsWith("video/") ? "video" : "image";
    const imageUrl = kind === "video" ? (url && r.poster && r.poster.startsWith(url.slice(0, url.lastIndexOf("/") + 1)) ? r.poster : null) : url;
    return {
        name: (r.custom_title ?? "").trim() || (r.name ?? "").trim() || null,
        link: r.link ?? null,
        kind,
        duration: r.duration ?? null,
        imageUrl,
    };
}

// ---- backfill (the 15-minute cron) ----------------------------------------------------------------

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const PUBLIC_NAME = /^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/;

export type BackfillDeps = {
    db: D1Database;
    captioner: Captioner;
    mediaBaseUrl: string;
    now: () => number;
    budgetMs: number;
    batch?: number; // rows per query (default 24)
    concurrency?: number; // default 4
    // a gallery link's model input, from share-sets.ts (kept out of here to avoid an import cycle)
    setInput?: (id: string) => Promise<RoastInput | null>;
};

// The stored model of the previous style for this captioner ("<model>+v3-…"): its captions are redone only when cut.
const cutStyleOf = (model: string) => (model.endsWith(`+${CAPTION_STYLE}`) ? `${model.slice(0, -CAPTION_STYLE.length)}${CAPTION_STYLE_CUT}` : model);

export type BackfillResult = { written: number; failed: number };

// Public files and live gallery links without a caption (or with a failed one due for a retry),
// newest first, until the budget runs out.
export async function backfillCaptions(d: BackfillDeps): Promise<BackfillResult> {
    const start = d.now();
    const out: BackfillResult = { written: 0, failed: 0 };
    const batch = d.batch ?? 24;
    const conc = Math.max(1, d.concurrency ?? 4);
    const media = withSlash(d.mediaBaseUrl);
    const due = (now: number) => now - ROAST_RETRY_MS;
    const tried = new Set<string>();

    const run = async (jobs: { subject: string; input: () => Promise<RoastInput | null> }[]) => {
        let i = 0;
        const worker = async () => {
            while (i < jobs.length && d.now() - start < d.budgetMs) {
                const job = jobs[i++]!;
                tried.add(job.subject);
                const input = await job.input().catch(() => undefined);
                if (input === undefined) continue; // D1 trouble: next run
                if (!input || input.files.length === 0) {
                    await record(d.db, job.subject, d.captioner.model, d.now(), null, true).catch(() => {});
                    continue;
                }
                const c = await writeCaption(d, job.subject, input);
                if (c) out.written++;
                else out.failed++;
            }
        };
        await Promise.all(Array.from({ length: conc }, worker));
    };

    // gallery links first: they are the ones being pasted around
    if (d.setInput) {
        const { results } = await d.db
            .prepare(
                `SELECT s.id FROM share_sets s LEFT JOIN media_captions c ON c.subject = 'set:' || s.id
                  WHERE s.revoked_at IS NULL
                    AND (c.subject IS NULL OR (c.title IS NULL AND c.attempts < ?1 AND c.created_at < ?2) OR (c.title IS NOT NULL AND c.model IS NOT ?4 AND (c.model IS NOT ?5 OR c.title LIKE '%...%')))
                  ORDER BY s.created_at DESC LIMIT ?3`,
            )
            .bind(ROAST_MAX_ATTEMPTS, due(d.now()), batch, d.captioner.model, cutStyleOf(d.captioner.model))
            .all<{ id: string }>();
        await run(results.map((r) => ({ subject: setSubject(r.id), input: () => d.setInput!(r.id) })));
    }

    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    while (d.now() - start < d.budgetMs) {
        const { results } = await d.db
            .prepare(
                `SELECT ${cols}, (SELECT t.title FROM media_titles t WHERE t.post_key = ${POST_KEY_SQL}) AS custom_title
                   FROM media_items m LEFT JOIN media_captions c ON c.subject = 'item:' || m.id
                  WHERE m.deleted_at IS NULL AND ${visSql("m.")} = 'public'
                    AND (c.subject IS NULL OR (c.title IS NULL AND c.attempts < ?1 AND c.created_at < ?2) OR (c.title IS NOT NULL AND c.model IS NOT ?4 AND (c.model IS NOT ?5 OR c.title LIKE '%...%')))
                  ORDER BY m.created_at DESC LIMIT ?3`,
            )
            .bind(ROAST_MAX_ATTEMPTS, due(d.now()), batch + tried.size, d.captioner.model, cutStyleOf(d.captioner.model))
            .all<MediaRow & { custom_title: string | null }>();
        const fresh = results.filter((r) => !tried.has(itemSubject(r.id)));
        if (fresh.length === 0) break;
        await run(
            fresh.map((r) => ({
                subject: itemSubject(r.id),
                input: async () => {
                    if (effectiveVisibility(r) !== "public") return null;
                    const key = r.bucket === "media" ? r.r2_key : r.public_key;
                    if (!key || !PUBLIC_NAME.test(key)) return null;
                    return { files: [fileOf(r, `${media}${key}`)], userTitle: null };
                },
            })),
        );
    }
    return out;
}
