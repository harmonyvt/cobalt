// The results board (APP-API-CONTRACT.md section 62.3 and 62.4): any swarm's answers as rows with a title, media, a score
// and a group, every agent's outcome and score, computed from what is stored (D1 and one resolveMedia batch for the page),
// never by a model. The program may map its answer's fields (output.board); without it the board guesses.
// Free of Cloudflare imports: the tests run it under node.
import { isMedia, parseMediaRef, resolveMedia, type MediaBases, type MediaRef } from "./media-refs";
import type { BoardMap, ChangeRow, Spec, TaskRow, TaskStats } from "./swarm";

export const BOARD_LIMIT_MAX = 200;
export const BOARD_LIMIT_DEFAULT = 100;
export const BOARD_FIELDS_MAX = 12;
export const BOARD_MEDIA_MAX = 4;
const TEXT_MAX = 500;
const HOLDERS = ["results", "matches", "items", "rows", "answers"];
const TITLES = ["title", "name", "alias", "label", "id"];
const MEDIA_NAMES = new Set(["media", "image", "url", "link", "preview_url", "id"]);
const isMediaName = (k: string) => MEDIA_NAMES.has(k) || k.endsWith("_url") || k.endsWith("_id");
const SCORE_WORDS: Record<string, number> = { high: 0.9, medium: 0.6, low: 0.3 };

type Json = Record<string, unknown>;
type Plain = string | number | boolean | null;
const isObj = (v: unknown): v is Json => !!v && typeof v === "object" && !Array.isArray(v);
const isPlain = (v: unknown): v is Plain => v === null || typeof v === "string" || typeof v === "number" || typeof v === "boolean";
const clipText = (s: string) => (s.length > TEXT_MAX ? `${s.slice(0, TEXT_MAX - 1)}…` : s);

// One row before its media are resolved.
export type RawRow = {
    agent: number;
    n: number;
    title: string;
    score: number | null;
    group: string | null;
    fields: Record<string, Plain>;
    refs: string[];
    links: string[];
    // every text of the row, lower case, for q
    text: string;
    // every plain value, for matching items (answered)
    values: string[];
};
export type BoardRow = Omit<RawRow, "refs" | "text" | "values"> & { media: MediaRef[] };

const parse = <T>(s: string | null | undefined, fallback: T): T => {
    if (s === null || s === undefined) return fallback;
    try {
        return JSON.parse(s) as T;
    } catch {
        return fallback;
    }
};

// A score as the board reads it: a number 0..1 (0..100 is read as a percentage), or high / medium / low.
export function scoreValue(v: unknown): number | null {
    if (typeof v === "number" && Number.isFinite(v)) {
        if (v >= 0 && v <= 1) return v;
        if (v > 1 && v <= 100) return v / 100;
        return null;
    }
    if (typeof v === "string") {
        const w = SCORE_WORDS[v.trim().toLowerCase()];
        if (w !== undefined) return w;
        const n = Number(v);
        return v.trim() !== "" && Number.isFinite(n) ? scoreValue(n) : null;
    }
    return null;
}

// Every plain value inside a value (objects and arrays walked, a few levels deep).
function plainValues(v: unknown, out: string[] = [], depth = 0): string[] {
    if (depth > 4 || out.length > 400) return out;
    if (typeof v === "string" || typeof v === "number") out.push(String(v));
    else if (Array.isArray(v)) for (const x of v) plainValues(x, out, depth + 1);
    else if (isObj(v)) for (const x of Object.values(v)) plainValues(x, out, depth + 1);
    return out;
}

// The answer's rows: an array, or one held under results / matches / items / rows / answers, else the answer itself.
export function answerRows(result: unknown): unknown[] {
    if (Array.isArray(result)) return result;
    if (isObj(result)) {
        for (const k of HOLDERS) if (Array.isArray(result[k])) return result[k] as unknown[];
    }
    return result === null || result === undefined ? [] : [result];
}

const strOf = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : typeof v === "number" ? String(v) : null);
const httpLink = (v: unknown) => typeof v === "string" && /^https?:\/\/\S+$/i.test(v.trim());

// One answer row as the board shows it (media refs not resolved yet).
export function toRow(raw: unknown, agent: number, n: number, map: BoardMap | null, bases: MediaBases): RawRow {
    const o: Json = isObj(raw) ? raw : { value: raw };
    const used = new Set<string>();
    // title
    let title: string | null = null;
    if (map?.title) {
        title = strOf(o[map.title]);
        used.add(map.title);
    } else {
        for (const k of TITLES) {
            const t = strOf(o[k]);
            if (t && typeof o[k] === "string") {
                title = t;
                used.add(k);
                break;
            }
        }
        if (title === null && typeof o.value === "string") {
            title = o.value;
            used.add("value");
        }
    }
    // score
    let score: number | null = null;
    if (map?.score) {
        score = scoreValue(o[map.score]);
        used.add(map.score);
    } else {
        for (const k of ["score", "confidence"]) {
            if (k in o) {
                score = scoreValue(o[k]);
                used.add(k);
                break;
            }
        }
    }
    // group
    let group: string | null = null;
    const gk = map?.group ?? (["group", "category"].find((k) => typeof o[k] === "string") as string | undefined);
    if (gk) {
        group = strOf(o[gk]);
        used.add(gk);
    }
    // media: the mapped fields, else every field with a media-ish name whose value is a media ref
    const refs: string[] = [];
    const take = (k: string, v: unknown) => {
        for (const x of Array.isArray(v) ? v : [v]) {
            if (typeof x !== "string" || refs.includes(x) || refs.length >= BOARD_MEDIA_MAX * 2) continue;
            const p = parseMediaRef(x, bases);
            if (!p || p.kind === "refused") continue;
            refs.push(x);
            if (!map) used.add(k);
        }
    };
    if (map?.media) for (const k of map.media) take(k, o[k]);
    else for (const [k, v] of Object.entries(o)) if (isMediaName(k)) take(k, v);
    // fields: the mapped ones, else the other plain values
    const fields: Record<string, Plain> = {};
    const keys = map?.fields ?? Object.keys(o).filter((k) => !used.has(k));
    for (const k of keys) {
        if (Object.keys(fields).length >= BOARD_FIELDS_MAX) break;
        const v = o[k];
        if (isPlain(v)) fields[k] = typeof v === "string" ? clipText(v) : v;
        else if (Array.isArray(v) && v.every(isPlain) && !map?.media?.includes(k)) fields[k] = clipText(v.map(String).join(", "));
    }
    const values = plainValues(o);
    const links = [...new Set(values.filter((v) => httpLink(v) && !refs.includes(v)))].slice(0, 8);
    return {
        agent,
        n,
        title: title ?? `agent ${agent} #${n}`,
        score,
        group,
        fields,
        refs,
        links,
        text: values.join(" \u0001 ").toLowerCase(),
        values: values.map((v) => v.toLowerCase()),
    };
}

// What identifies an item: itself (a plain value), else its name / id / title.
function itemKeys(item: unknown): string[] {
    if (typeof item === "string" || typeof item === "number") return [String(item).toLowerCase()];
    if (isObj(item)) return ["name", "id", "title", "value"].flatMap((k) => (typeof item[k] === "string" || typeof item[k] === "number" ? [String(item[k]).toLowerCase()] : []));
    return [];
}

// How many of an agent's items appear in its rows (section 62.3).
export function answeredOf(items: unknown[], rows: Pick<RawRow, "values">[]): number {
    const seen = new Set(rows.flatMap((r) => r.values));
    let n = 0;
    for (const it of items) {
        const keys = itemKeys(it);
        if (keys.length > 0 ? keys.some((k) => seen.has(k)) : rows.length > 0) n++;
    }
    return n;
}

// The score (section 62.3): answered / items × (1 − tool_errors / max(tool_calls, 1)), 0 for a failed agent.
export function scoreOf(status: string, items: number, answered: number, stats: Pick<TaskStats, "tool_calls" | "tool_errors">): number {
    if (status !== "done" || items === 0) return 0;
    const s = (answered / items) * (1 - stats.tool_errors / Math.max(stats.tool_calls, 1));
    return Math.round(Math.max(0, Math.min(1, s)) * 1000) / 1000;
}

// A propose-mode change as a row: its target, the new value, the picture.
function changeRow(c: ChangeRow, agent: number, n: number): RawRow {
    const values = [c.target, c.before, c.after, c.op, ...Object.values(parse<Json>(c.args, {})).filter((v): v is string | number => typeof v === "string" || typeof v === "number").map(String)].filter(
        (v): v is string => typeof v === "string",
    );
    const fields: Record<string, Plain> = { op: c.op, target: c.target, before: c.before, after: c.after, status: c.status, keep: c.keep === 1 };
    if (c.clash) fields.clash = c.clash;
    if (c.error) fields.error = c.error;
    return {
        agent,
        n,
        title: c.after ?? c.target ?? `change ${c.n}`,
        score: null,
        group: c.op,
        fields,
        refs: c.preview_url ? [c.preview_url] : [],
        links: [],
        text: values.join(" \u0001 ").toLowerCase(),
        values: values.map((v) => v.toLowerCase()),
    };
}

// Every row of one agent: its answer's rows (or its changes), or one row saying why it has none.
export function agentRows(spec: Pick<Spec, "mode" | "board">, t: Pick<TaskRow, "idx" | "status" | "error" | "items" | "result">, changes: ChangeRow[], bases: MediaBases): RawRow[] {
    const agent = t.idx + 1;
    if (t.status === "failed" || t.status === "skipped") {
        const items = parse<unknown[]>(t.items, []);
        const reason = t.error ?? t.status;
        return [
            {
                agent,
                n: 1,
                title: `agent ${agent} ${t.status}: ${reason}`,
                score: null,
                group: null,
                fields: { items: clipText(items.map((i) => (isObj(i) ? (strOf(i.name) ?? strOf(i.id) ?? strOf(i.value) ?? JSON.stringify(i).slice(0, 80)) : String(i))).join(", ")) },
                refs: [],
                links: [],
                text: `agent ${agent} ${t.status} ${reason}`.toLowerCase(),
                values: [],
            },
        ];
    }
    if (t.status !== "done") return [];
    if (spec.mode === "propose") return changes.map((c, i) => changeRow(c, agent, i + 1));
    return answerRows(parse<unknown>(t.result, null)).map((r, i) => toRow(r, agent, i + 1, spec.board ?? null, bases));
}

export type BoardQuery = { q?: string; agent?: number; status?: string; group?: string; sort?: "agent" | "score" | "title"; offset?: number; limit?: number };

export type BoardAgent = { agent: number; status: string; outcome: Outcome; error: string | null };
export type Outcome = { status: string; items: number; answered: number; tool_calls: number; tool_errors: number; asks: number; turns: number; usd: number; ms: number | null; score: number | null };

// One agent's outcome (section 62.3). A running agent has no score yet.
export function outcomeOf(t: Pick<TaskRow, "status" | "items" | "usd" | "started_at" | "ended_at"> & { stats?: string | null }, stats: TaskStats, answered: number, asks: number): Outcome {
    const items = parse<unknown[]>(t.items, []).length;
    const ended = t.status === "done" || t.status === "failed" || t.status === "skipped";
    return {
        status: t.status,
        items,
        answered,
        tool_calls: stats.tool_calls,
        tool_errors: stats.tool_errors,
        asks,
        turns: stats.turns,
        usd: Math.round(t.usd * 10000) / 10000,
        ms: t.started_at && t.ended_at ? Math.max(0, t.ended_at - t.started_at) : null,
        score: ended ? (stats.score ?? scoreOf(t.status, items, answered, stats)) : null,
    };
}

// The board over all rows: filtered, grouped, sorted, one page with its media resolved in one batch.
export async function boardPage(db: D1Database, rows: RawRow[], query: BoardQuery, bases: MediaBases) {
    const q = query.q?.trim().toLowerCase() ?? "";
    let list = rows.filter((r) => (query.agent === undefined || r.agent === query.agent) && (!q || r.text.includes(q) || r.title.toLowerCase().includes(q)));
    const groups = new Map<string, number>();
    for (const r of list) if (r.group !== null) groups.set(r.group, (groups.get(r.group) ?? 0) + 1);
    if (query.group !== undefined) list = list.filter((r) => r.group === query.group);
    const sort = query.sort ?? "agent";
    list = [...list].sort((a, b) => {
        if (sort === "score") return (b.score ?? -1) - (a.score ?? -1) || a.agent - b.agent || a.n - b.n;
        if (sort === "title") return a.title.localeCompare(b.title) || a.agent - b.agent || a.n - b.n;
        return a.agent - b.agent || a.n - b.n;
    });
    const offset = Math.max(0, query.offset ?? 0);
    const limit = Math.min(BOARD_LIMIT_MAX, Math.max(1, query.limit ?? BOARD_LIMIT_DEFAULT));
    const page = list.slice(offset, offset + limit);
    const refs = [...new Set(page.flatMap((r) => r.refs))];
    const answers = refs.length > 0 ? await resolveMedia(db, refs, bases) : [];
    const byRef = new Map(answers.filter(isMedia).map((a) => [a.ref, a]));
    return {
        total: list.length,
        offset,
        groups: [...groups.entries()].map(([value, count]) => ({ value, count })).sort((a, b) => b.count - a.count || a.value.localeCompare(b.value)),
        rows: page.map(({ refs: r, text: _t, values: _v, ...rest }) => ({ ...rest, media: r.flatMap((x) => (byRef.has(x) ? [byRef.get(x)!] : [])).slice(0, BOARD_MEDIA_MAX) })),
    };
}
