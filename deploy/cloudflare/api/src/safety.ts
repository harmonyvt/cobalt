// Per-file safety ratings (APP-API-CONTRACT.md section 51). Clef-omni is the only automated gate: there is no
// second model and no disagreement review. Pure functions (levels, the stage rule, the Clef questions, the clip
// plan's twin on the helper) so the tests run under plain node. The D1 side is safety-store.ts, the call is
// safety-clef.ts, the clip is the helper.

export const SAFETY_LEVELS = ["general", "sensitive", "questionable", "explicit"] as const;
export type SafetyContentLevel = (typeof SAFETY_LEVELS)[number];
export type SafetyLevel = SafetyContentLevel | "pending" | "failed";

export const LEVEL_RANK: Record<SafetyContentLevel, number> = {
    general: 0,
    sensitive: 1,
    questionable: 2,
    explicit: 3,
};

export const CLEF_MODEL_ID = "@cf/cloudflare/clef-omni";
export const CLEF_MODEL = "clef-omni";
// Bump when the questions change: every rated file is rated again. A threshold change does not bump this.
export const QUESTIONS_VERSION = "v1";

export const SAFETY_MAX_ATTEMPTS = 3;
export const SAFETY_RETRY_MS = 24 * 60 * 60 * 1000;
// The 15-minute cron's Clef calls. Workers AI paid models are assumed at 20 requests a minute; the default
// stays far under that. 0 turns the calls off (files stay pending, so they stay off the stage).
export const SAFETY_PER_RUN_DEFAULT = 4;
export const SAFETY_PER_RUN_MAX = 15;
// The labelled pilot may use a few more of the same minute, still at the gap below.
export const SAFETY_PILOT_PER_RUN = 20;
export const SAFETY_PILOT_MAX = 60;
export const SAFETY_MIN_GAP_MS = 3_000;
// New saves only, unless SAFETY_BACKFILL is "1" or the id is in the pilot list. The existing library stays
// unrated (off the stage) until Harmony runs that later.
export const SAFETY_NEW_HOURS_DEFAULT = 48;
export const PILOT_LABELS_KEY = "about/pilot-labels.json";
export const PILOT_REPORT_KEY = "about/pilot-report.json";

// A noul flag counts as yes at or above this, until the config says otherwise. Stored probs make the change free.
export const SAFETY_FLAG_AT = 0.5;

export type SafetyConfig = {
    // A file reaches the stage only when its effective level ranks at or under this. Default: general only.
    stageMax: SafetyContentLevel;
    goreAt: number;
    minorAt: number;
    drawnAt: number;
    perRun: number;
    backfill: boolean;
    newHours: number;
};

const clamp01 = (raw: string | undefined, fallback: number): number => {
    if (raw === undefined || raw.trim() === "") return fallback;
    const n = Number(raw);
    return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : fallback;
};

const clampInt = (raw: string | undefined, fallback: number, min: number, max: number): number => {
    if (raw === undefined || raw.trim() === "") return fallback;
    const n = Math.floor(Number(raw));
    return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
};

export function safetyConfigFrom(env: {
    SAFETY_STAGE_MAX?: string;
    SAFETY_GORE_AT?: string;
    SAFETY_MINOR_AT?: string;
    SAFETY_DRAWN_AT?: string;
    SAFETY_PER_RUN?: string;
    SAFETY_BACKFILL?: string;
    SAFETY_NEW_HOURS?: string;
}): SafetyConfig {
    const asked = (env.SAFETY_STAGE_MAX ?? "").trim() as SafetyContentLevel;
    return {
        stageMax: (SAFETY_LEVELS as readonly string[]).includes(asked) ? asked : "general",
        goreAt: clamp01(env.SAFETY_GORE_AT, SAFETY_FLAG_AT),
        minorAt: clamp01(env.SAFETY_MINOR_AT, SAFETY_FLAG_AT),
        drawnAt: clamp01(env.SAFETY_DRAWN_AT, SAFETY_FLAG_AT),
        perRun: clampInt(env.SAFETY_PER_RUN, SAFETY_PER_RUN_DEFAULT, 0, SAFETY_PER_RUN_MAX),
        backfill: (env.SAFETY_BACKFILL ?? "").trim() === "1",
        newHours: clampInt(env.SAFETY_NEW_HOURS, SAFETY_NEW_HOURS_DEFAULT, 1, 24 * 365),
    };
}

export const contentLevel = (v: string | null | undefined): SafetyContentLevel | null =>
    v && (SAFETY_LEVELS as readonly string[]).includes(v) ? (v as SafetyContentLevel) : null;

export const stricterLevel = (a: SafetyContentLevel, b: SafetyContentLevel): SafetyContentLevel =>
    LEVEL_RANK[a] >= LEVEL_RANK[b] ? a : b;

// The post's level: the strictest content level among its items, or pending when any item is still unrated or failed.
export function rollupLevels(levels: readonly string[]): SafetyLevel {
    if (levels.length === 0) return "pending";
    const content: SafetyContentLevel[] = [];
    for (const level of levels) {
        const c = contentLevel(level);
        if (!c) return "pending";
        content.push(c);
    }
    return content.reduce(stricterLevel);
}

export type SafetyProbs = {
    level: Record<SafetyContentLevel, number>;
    gore: number;
    drawn: number;
    minor_sexual: number;
};

export type SafetyFlags = { gore: boolean; drawn: boolean; minor: boolean };

export type SafetySnapshot = {
    level: string;
    user_level: string | null;
    probs: string | null;
    gore: number;
    drawn: number;
    minor_sexual: number;
};

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

export function parseProbs(raw: string | null | undefined): SafetyProbs | null {
    if (!raw) return null;
    try {
        const v = JSON.parse(raw) as { level?: Record<string, unknown>; gore?: unknown; drawn?: unknown; minor_sexual?: unknown };
        const level = {} as Record<SafetyContentLevel, number>;
        for (const name of SAFETY_LEVELS) {
            const n = num(v.level?.[name]);
            if (n === null) return null;
            level[name] = n;
        }
        const gore = num(v.gore);
        const drawn = num(v.drawn);
        const minor = num(v.minor_sexual);
        if (gore === null || drawn === null || minor === null) return null;
        return { level, gore, drawn, minor_sexual: minor };
    } catch {
        return null;
    }
}

export function flagsOf(row: Pick<SafetySnapshot, "probs" | "gore" | "drawn" | "minor_sexual">, cfg: SafetyConfig): SafetyFlags {
    const probs = parseProbs(row.probs);
    if (!probs) return { gore: row.gore === 1, drawn: row.drawn === 1, minor: row.minor_sexual === 1 };
    return { gore: probs.gore >= cfg.goreAt, drawn: probs.drawn >= cfg.drawnAt, minor: probs.minor_sexual >= cfg.minorAt };
}

export type EffectiveSafety = {
    level: SafetyLevel;
    rated: boolean;
    override: boolean;
    inherited: boolean;
    gore: boolean;
    drawn: boolean;
    minor: boolean;
};

const UNRATED: EffectiveSafety = { level: "pending", rated: false, override: false, inherited: false, gore: false, drawn: false, minor: false };

// Own rating when Clef (or Harmony) has one. Until then a derived file takes the strictest rated source, and stays
// pending when any source is still unrated. `minor` is never waived. `gore` is waived only by that file's own override.
export function effectiveSafety(
    id: string,
    rows: ReadonlyMap<string, SafetySnapshot>,
    sources: ReadonlyMap<string, readonly string[]>,
    cfg: SafetyConfig,
    stack: Set<string> = new Set(),
): EffectiveSafety {
    if (stack.has(id) || stack.size > 6) return UNRATED;
    stack.add(id);
    const row = rows.get(id);
    const flags = row ? flagsOf(row, cfg) : { gore: false, drawn: false, minor: false };
    const user = contentLevel(row?.user_level ?? null);
    if (user) return { level: user, rated: true, override: true, inherited: false, ...flags };
    const own = contentLevel(row?.level ?? null);
    if (own) return { level: own, rated: true, override: false, inherited: false, ...flags };
    const srcs = sources.get(id) ?? [];
    if (srcs.length === 0) return { ...UNRATED, level: row?.level === "failed" ? "failed" : "pending" };
    const parts = srcs.map((s) => effectiveSafety(s, rows, sources, cfg, stack));
    const minor = parts.some((p) => p.minor);
    const drawn = parts.some((p) => p.drawn);
    const gore = parts.some((p) => p.gore && !p.override);
    if (parts.some((p) => !p.rated)) return { level: "pending", rated: false, override: false, inherited: true, gore, drawn, minor };
    return {
        level: parts.reduce((a, p) => stricterLevel(a, p.level as SafetyContentLevel), "general" as SafetyContentLevel),
        rated: true,
        override: false,
        inherited: true,
        gore,
        drawn,
        minor,
    };
}

// The stage (Twitch). Unrated, pending, failed, below the level, gore, or minor_sexual never. Harmony's override
// wins over the model level and over gore. minor_sexual hard-blocks even then.
export function stageAllows(e: EffectiveSafety, cfg: SafetyConfig): boolean {
    const level = contentLevel(e.level);
    if (!e.rated || !level) return false;
    if (e.minor) return false;
    if (LEVEL_RANK[level] > LEVEL_RANK[cfg.stageMax]) return false;
    if (e.gore && !e.override) return false;
    return true;
}

// ---- Clef-omni questions (System One). The wording is the rating: bump QUESTIONS_VERSION when it changes. ----

export const SAFETY_STATE =
    "One saved file from Harmony's private library (furry, anime, fursuits, cosplay, photos and ordinary clips all occur). Rate what is shown. When audio is attached, it is the soundtrack and the video clips have none. A clip longer than two minutes may be sped up so the whole of it still fits.";

export const SAFETY_QUESTIONS = {
    level: {
        type: "choice" as const,
        instructions:
            "How explicit is this, on the Danbooru scale? Judge the picture and the sound. Drawn or animated sexual content uses the same scale; do not mark it higher just because it is drawn.",
        criteria: {
            general: "Safe for a public stream: everyday clothes, no sexual content.",
            sensitive: "Mild: swimwear, a non-sexual shirtless shot, mild fanservice.",
            questionable: "Suggestive or sexual, but not explicit.",
            explicit: "Explicit sexual content, genitals, or sex acts.",
        },
    },
    gore: {
        type: "noul" as const,
        instructions: "Does this show gore: realistic blood, injury, or a corpse? A cartoon joke with no realistic harm is no.",
    },
    drawn: {
        type: "noul" as const,
        instructions: "Is this drawn or rendered (anime, furry art, illustration, 3D) rather than a photograph or live footage of real people?",
    },
    minor_sexual: {
        type: "noul" as const,
        instructions:
            "Does anyone who looks under 18 appear in a sexual or suggestive context? Ordinary children with no sexual context are no. Yes only for that combination.",
    },
};

export type ClefRating = {
    level: SafetyContentLevel;
    probs: SafetyProbs;
};

const choiceOf = (answer: unknown): { choice: string | null; probs: Partial<Record<SafetyContentLevel, number>> } => {
    if (!answer || typeof answer !== "object") return { choice: null, probs: {} };
    const a = answer as Record<string, unknown>;
    const choice = typeof a.choice === "string" ? a.choice : typeof a.answer === "string" ? a.answer : null;
    const bag = (a.probabilities ?? a.probs ?? a.scores ?? a.distribution) as Record<string, unknown> | undefined;
    const probs: Partial<Record<SafetyContentLevel, number>> = {};
    if (bag && typeof bag === "object") {
        for (const name of SAFETY_LEVELS) {
            const n = num(bag[name]);
            if (n !== null) probs[name] = n;
        }
    }
    return { choice, probs };
};

const noulOf = (answer: unknown): number | null => {
    if (typeof answer === "number") return Number.isFinite(answer) ? answer : null;
    if (!answer || typeof answer !== "object") return null;
    const a = answer as Record<string, unknown>;
    return num(a.noul) ?? num(a.probability) ?? num(a.yes) ?? num(a.score);
};

// The binding has answered as the object, as JSON text, or wrapped in result/response. Null when it is not a rating.
export function parseClefAnswer(raw: unknown): ClefRating | null {
    let v = raw;
    if (typeof v === "string") {
        try {
            v = JSON.parse(v);
        } catch {
            return null;
        }
    }
    for (let i = 0; i < 2 && v && typeof v === "object" && !("answers" in v); i++) {
        const inner = (v as { result?: unknown; response?: unknown }).result ?? (v as { response?: unknown }).response;
        if (!inner || typeof inner !== "object") break;
        v = inner;
    }
    if (!v || typeof v !== "object") return null;
    const answers = (v as { answers?: unknown }).answers;
    if (!answers || typeof answers !== "object") return null;
    const a = answers as Record<string, unknown>;
    const picked = choiceOf(a.level);
    const choice = contentLevel(picked.choice);
    if (!choice) return null;
    const probs = {} as Record<SafetyContentLevel, number>;
    const have = SAFETY_LEVELS.every((name) => picked.probs[name] !== undefined);
    if (have) {
        for (const name of SAFETY_LEVELS) probs[name] = picked.probs[name]!;
    } else {
        for (const name of SAFETY_LEVELS) probs[name] = name === choice ? 1 : 0;
    }
    const gore = noulOf(a.gore);
    const drawn = noulOf(a.drawn);
    const minor = noulOf(a.minor_sexual);
    if (gore === null || drawn === null || minor === null) return null;
    return { level: choice, probs: { level: probs, gore, drawn, minor_sexual: minor } };
}

export function snapshotFlags(probs: SafetyProbs, cfg: SafetyConfig): { gore: number; drawn: number; minor_sexual: number } {
    return {
        gore: probs.gore >= cfg.goreAt ? 1 : 0,
        drawn: probs.drawn >= cfg.drawnAt ? 1 : 0,
        minor_sexual: probs.minor_sexual >= cfg.minorAt ? 1 : 0,
    };
}

// clip | still | nothing the stage can show. HEIC stays unrated (the canvas cannot draw it either).
// Animated WebP stays a still: it is `image/webp`, and the container's ffmpeg cannot decode an animated WebP
// (poster.ts). kind=clip would call that same decoder and fail the same way, so prep of those files fails
// until something other than ffmpeg can read them.
export function safetyKind(contentType: string | null): "clip" | "still" | null {
    const t = (contentType ?? "").split(";")[0]!.trim().toLowerCase();
    if (t === "image/heic" || t === "image/heif") return null;
    if (t === "image/gif" || t.startsWith("video/")) return "clip";
    if (t.startsWith("image/")) return "still";
    return null;
}

export function toBase64(bytes: Uint8Array): string {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(bin);
}

export async function sha256(s: string): Promise<string> {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
