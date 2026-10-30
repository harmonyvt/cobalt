// Hidden posts and auto-hide rules (APP-API-CONTRACT.md section 37): what the routes, the chat/MCP ops, the Durable
// Object (a save that becomes ready) and the 15-minute cron (held posts) do. The D1 readers every other path uses to
// leave hidden posts out are in src/hidden-store.ts.
//
// Privacy first: hiding writes the `hidden` row BEFORE the files are turned off, so every read leaves the post out at
// once and no route can make a file of it public meanwhile (visibility.ts makePublic refuses a hidden post). A file
// whose OFF fails is reported under `failed`; the row stays hidden and a retry (the same call) finishes it.
//
// Every action answers a StudioReply (status + body), so the HTTP routes return it as is and the chat unwraps it. Until
// migration 0025 is applied each one answers 503 error.api.generic and changes nothing. Free of Cloudflare imports.
import { effectiveTags, parseList, ABOUT_MAX_ATTEMPTS, type AboutRow } from "./about-store";
import {
    deleteHiddenRow,
    hiddenCount,
    hiddenReady,
    hiddenRows,
    postKeysOfFiles,
    setHiddenRow,
    type HiddenBy,
    type HiddenRow,
} from "./hidden-store";
import { randomBase62 } from "./ids";
import { POST_KEY_SQL } from "./post-key";
import { itemOn, type PrivateDeps } from "./private-actions";
import { revokeLinkQuietly } from "./private-links";
import type { StudioReply } from "./studio";
import {
    ITEM_COLUMNS,
    effectiveVisibility,
    isOriginalSource,
    itemShape,
    privateUrlsOf,
    publishOriginal,
    purgeUrls,
    setVisibility,
    toggleable,
    type MediaRow,
    type VisDeps,
} from "./visibility";

export const HIDDEN_RULES_MAX = 50;
export const STATUS_IDS_MAX = 200;
export const CHAT_STATUS_IDS_MAX = 50;
export const STATUS_CONCURRENCY = 4;
export const RULE_WORDS_MAX = 60;
export const RULE_ABOUT_MAX = 40;
export const RULE_SITE_MAX = 200;
export const PREVIEW_SAMPLE = 6;
// a post held for an about rule is published (or hidden) at the latest this long after it was held
export const HELD_GIVE_UP_MS = 60 * 60 * 1000;

export type RuleKind = "site" | "words" | "about" | "upload";
export const RULE_KINDS: readonly RuleKind[] = ["site", "words", "about", "upload"];
export type Status = "off" | "public" | "private" | "hidden";
export const STATUSES: readonly Status[] = ["off", "public", "private", "hidden"];

export type RuleRow = { id: string; kind: RuleKind; value: string; enabled: number; hits: number; created_at: number; updated_at: number };
export const ruleShape = (r: RuleRow) => ({
    id: r.id,
    kind: r.kind,
    value: r.value,
    enabled: !!r.enabled,
    hits: r.hits,
    created_at: r.created_at,
    updated_at: r.updated_at,
});

export type HiddenDeps = {
    db: D1Database;
    // the section 16 toggle's deps; absent (no public bucket), a public file of a post being hidden is reported as failed
    vis?: VisDeps;
    // the share host's base URL: answers carry private links, and `private` needs it (36.3)
    shareBaseUrl?: string;
    now: () => number;
    keyId: string;
    randomBytes?: (n: number) => Uint8Array;
};

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});
const generic = () => err(503, "error.api.generic");
const codeOf = (r: StudioReply) => (r.body as { error?: { code?: string } } | null)?.error?.code ?? "error.api.generic";

async function guarded(db: D1Database, what: string, run: () => Promise<StudioReply>): Promise<StudioReply> {
    try {
        if (!(await hiddenReady(db))) return generic();
        return await run();
    } catch (e) {
        console.error(`[hidden] ${what} failed`, String(e));
        return generic();
    }
}

// At most `n` of `jobs` running at once, results in order.
async function pool<T, R>(items: T[], n: number, job: (x: T) => Promise<R>): Promise<R[]> {
    const out: R[] = new Array(items.length);
    let i = 0;
    const worker = async () => {
        while (i < items.length) {
            const at = i++;
            out[at] = await job(items[at]!);
        }
    };
    await Promise.all(Array.from({ length: Math.max(1, Math.min(n, items.length)) }, worker));
    return out;
}

// ---- rules: values -------------------------------------------------------------------------------------------------------

const codePoints = (s: string) => Array.from(s).length;
const HOST = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$/;

// twitter.com and x.com are the same site (37.3)
const canonHost = (h: string) => (h === "twitter.com" || h.endsWith(".twitter.com") ? `${h.slice(0, -"twitter.com".length)}x.com` : h);
const trimPath = (p: string) => p.replace(/\/+$/, "");

// "instagram.com", "https://www.TikTok.com/@name/" -> { host: "tiktok.com", path: "/@name" }; null: not a host.
export function parseSite(raw: string): { host: string; path: string } | null {
    let s = raw.trim().toLowerCase();
    s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, "").replace(/^www\./, "");
    const slash = s.indexOf("/");
    const host = slash === -1 ? s : s.slice(0, slash);
    const path = trimPath(slash === -1 ? "" : s.slice(slash).replace(/[?#].*$/, ""));
    if (!HOST.test(host) || /\s/.test(path)) return null;
    return { host, path };
}

// A rule's value as stored (37.1), or null when it is not one this kind takes.
export function normalizeRuleValue(kind: RuleKind, raw: unknown): string | null {
    if (kind === "upload") return "";
    if (typeof raw !== "string") return null;
    const v = raw.replace(/\s+/g, " ").trim().toLowerCase();
    if (kind === "site") {
        if (codePoints(v) > RULE_SITE_MAX) return null;
        const p = parseSite(v);
        return p ? `${p.host}${p.path}` : null;
    }
    const max = kind === "words" ? RULE_WORDS_MAX : RULE_ABOUT_MAX;
    return codePoints(v) >= 1 && codePoints(v) <= max ? v : null;
}

// ---- rules: matching -----------------------------------------------------------------------------------------------------

// What the rules read of one post.
export type PostFacts = {
    post_key: string;
    latest: number;
    link: string | null;
    title: string | null;
    names: string[];
    captions: string[];
    upload: boolean;
    // its about tags (the owner's replacing Haiku's) and sound tags, lower case
    tags: string[];
    // its sentence and transcript, as lower-case words joined by one space
    words: string;
};

const wordsOf = (s: string | null | undefined) =>
    (s ?? "")
        .toLowerCase()
        .split(/[^\p{L}\p{N}]+/u)
        .filter(Boolean)
        .join(" ");

function linkParts(link: string | null): { host: string; path: string } | null {
    if (!link || !/^https?:\/\//i.test(link)) return null;
    try {
        const u = new URL(link);
        return { host: canonHost(u.hostname.toLowerCase()), path: trimPath(u.pathname.toLowerCase()) };
    } catch {
        return null;
    }
}

export function ruleMatches(rule: Pick<RuleRow, "kind" | "value">, p: PostFacts): boolean {
    switch (rule.kind) {
        case "upload":
            return p.upload;
        case "site": {
            const want = parseSite(rule.value);
            const have = linkParts(p.link);
            if (!want || !have) return false;
            const host = canonHost(want.host);
            if (have.host !== host && !have.host.endsWith(`.${host}`)) return false;
            return !want.path || have.path === want.path || have.path.startsWith(`${want.path}/`);
        }
        case "words": {
            const hay = [p.title ?? "", ...p.names, ...p.captions, p.link ?? ""].join("\n").toLowerCase();
            return rule.value.length > 0 && hay.includes(rule.value);
        }
        case "about": {
            if (!rule.value) return false;
            if (p.tags.includes(rule.value)) return true;
            const w = wordsOf(rule.value);
            return w.length > 0 && ` ${p.words} `.includes(` ${w} `);
        }
    }
}

// The first enabled rule (oldest first) that matches, or null.
export const firstMatch = (rules: RuleRow[], p: PostFacts): RuleRow | null => rules.find((r) => !!r.enabled && ruleMatches(r, p)) ?? null;

type FactRow = { id: string; name: string | null; link: string | null; source: string; created_at: number; post_key: string };

// The facts of these posts (every live post when `keys` is absent), newest first.
export async function postFacts(db: D1Database, keys?: string[]): Promise<PostFacts[]> {
    if (keys && keys.length === 0) return [];
    const filter = keys ? " WHERE post_key IN (SELECT value FROM json_each(?1))" : "";
    const fStmt = db.prepare(
        `SELECT * FROM (SELECT m.id, m.name, m.link, m.source, m.created_at, ${POST_KEY_SQL} AS post_key FROM media_items m WHERE m.deleted_at IS NULL)${filter}
          ORDER BY created_at, id`,
    );
    const { results: files } = await (keys ? fStmt.bind(JSON.stringify(keys)) : fStmt).all<FactRow>();
    if (files.length === 0) return [];
    const tStmt = db.prepare(`SELECT post_key, title FROM media_titles${filter}`);
    const titles = new Map((await (keys ? tStmt.bind(JSON.stringify(keys)) : tStmt).all<{ post_key: string; title: string }>()).results.map((t) => [t.post_key, t.title]));
    const captions = new Map<string, string>();
    try {
        const cStmt = keys
            ? db
                  .prepare("SELECT subject, title FROM media_captions WHERE title IS NOT NULL AND subject IN (SELECT 'item:' || value FROM json_each(?1))")
                  .bind(JSON.stringify(files.map((f) => f.id)))
            : db.prepare("SELECT subject, title FROM media_captions WHERE title IS NOT NULL AND subject LIKE 'item:%'");
        for (const c of (await cStmt.all<{ subject: string; title: string }>()).results) captions.set(c.subject.slice(5), c.title);
    } catch {
        // no captions table (before section 25's migration)
    }
    const about = new Map<string, Pick<AboutRow, "tags" | "user_tags" | "sound_tags" | "sentence" | "transcript">>();
    try {
        const aStmt = db.prepare(`SELECT post_key, tags, user_tags, sound_tags, sentence, transcript FROM media_about${filter}`);
        for (const a of (await (keys ? aStmt.bind(JSON.stringify(keys)) : aStmt).all<AboutRow>()).results) about.set(a.post_key, a);
    } catch {
        // no about table (before 0022)
    }
    const byPost = new Map<string, FactRow[]>();
    for (const f of files) {
        const list = byPost.get(f.post_key);
        if (list) list.push(f);
        else byPost.set(f.post_key, [f]);
    }
    const out: PostFacts[] = [];
    for (const [key, fs] of byPost) {
        const original = fs.find((f) => isOriginalSource(f.source) && f.link) ?? fs.find((f) => f.link);
        const a = about.get(key);
        out.push({
            post_key: key,
            latest: Math.max(...fs.map((f) => f.created_at)),
            link: original?.link ?? null,
            title: titles.get(key) ?? null,
            names: fs.map((f) => f.name ?? "").filter(Boolean),
            captions: fs.map((f) => captions.get(f.id)).filter((c): c is string => !!c),
            upload: fs.some((f) => f.source === "upload"),
            tags: a ? [...effectiveTags(a), ...parseList(a.sound_tags)].map((t) => t.toLowerCase().trim()) : [],
            words: a ? `${wordsOf(a.sentence)} ${wordsOf(a.transcript)}`.trim() : "",
        });
    }
    out.sort((x, y) => y.latest - x.latest || (x.post_key < y.post_key ? 1 : -1));
    return out;
}

async function enabledRules(db: D1Database): Promise<RuleRow[]> {
    return (await db.prepare("SELECT * FROM hidden_rules WHERE enabled = 1 ORDER BY created_at, id").all<RuleRow>()).results;
}

// ---- hiding and unhiding --------------------------------------------------------------------------------------------------

// Every live file of a post, oldest first.
async function postRows(db: D1Database, postKey: string): Promise<MediaRow[]> {
    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    return (
        await db
            .prepare(`SELECT ${cols} FROM media_items m WHERE m.deleted_at IS NULL AND ${POST_KEY_SQL} = ?1 ORDER BY COALESCE(m.item_index, 1000000), m.created_at, m.id`)
            .bind(postKey)
            .all<MediaRow>()
    ).results;
}

export type FileFailure = { id: string; error: string };

// The post's session gave up on its section 13 publish (it is hidden): never "pending" again.
async function sessionsNotPublic(db: D1Database, postKey: string): Promise<void> {
    await db
        .prepare("UPDATE studio_sessions SET public_state = NULL, public_url = NULL WHERE (id = ?1 OR link = 'upload:' || ?1) AND public_state = 'pending'")
        .bind(postKey)
        .run()
        .catch((e) => console.error("[hidden] session state failed", String(e)));
}

// The moving previews (section 29) of these files are public objects of their own: they go with the post.
async function dropLoops(d: HiddenDeps, ids: string[]): Promise<void> {
    if (ids.length === 0) return;
    try {
        const { results } = await d.db
            .prepare("SELECT item_id, r2_key FROM media_loops WHERE item_id IN (SELECT value FROM json_each(?1))")
            .bind(JSON.stringify(ids))
            .all<{ item_id: string; r2_key: string | null }>();
        for (const l of results) {
            if (l.r2_key && d.vis) await d.vis.media.delete(l.r2_key);
            await d.db.prepare("DELETE FROM media_loops WHERE item_id = ?1").bind(l.item_id).run();
        }
    } catch (e) {
        if (!/no such table/i.test(String(e))) console.error("[hidden] dropping previews failed", String(e));
    }
}

// Turns off every file of a post: section 16 OFF for the public ones, the private link (36) revoked for all.
// A legacy host copy (section 16: `source 'host'`, the public bucket, never toggleable) of a hidden post is deleted when
// that is safe: its session's original is a live row in the private bucket and its object is there, so the post keeps its
// canonical copy. The public object goes first (privacy first), then the row, then the edge cache and the session's
// public URL. False (the caller reports it under failed) when it is not safe or a step failed.
async function dropHostCopy(d: HiddenDeps, f: MediaRow): Promise<boolean> {
    if (!d.vis || f.source !== "host" || f.bucket !== "media" || !f.session_id) return false;
    try {
        const o = await d.db
            .prepare(
                `SELECT o.r2_key AS r2_key FROM studio_sessions s
                   JOIN media_items o ON o.deleted_at IS NULL AND o.bucket = 'originals' AND o.r2_key = s.r2_key
                  WHERE s.id = ?1 AND o.source IN ('saved', 'upload') LIMIT 1`,
            )
            .bind(f.session_id)
            .first<{ r2_key: string }>();
        if (!o || !(await d.vis.originals.head(o.r2_key))) return false;
        await d.vis.media.delete(f.r2_key);
        await d.db.prepare("UPDATE media_items SET deleted_at = ?2 WHERE id = ?1 AND deleted_at IS NULL").bind(f.id, d.now()).run();
        if (f.url) {
            await d.db.prepare("UPDATE studio_sessions SET public_state = NULL, public_url = NULL WHERE public_url = ?1").bind(f.url).run();
            await purgeUrls(d.vis, [f.url]);
        }
        return true;
    } catch (e) {
        console.error("[hidden] host copy delete failed", f.id, String(e));
        return false;
    }
}

async function allOff(d: HiddenDeps, files: MediaRow[]): Promise<FileFailure[]> {
    const failed: FileFailure[] = [];
    for (const f of files) {
        if (effectiveVisibility(f) === "public") {
            if (!toggleable(f)) {
                if (!(await dropHostCopy(d, f))) failed.push({ id: f.id, error: "error.library.not_toggleable" });
            }
            else if (!d.vis) failed.push({ id: f.id, error: "error.api.generic" });
            else {
                const r = await setVisibility(d.vis, f.id, false, d.keyId);
                if (r.status !== 200) failed.push({ id: f.id, error: codeOf(r) });
            }
        }
        await revokeLinkQuietly(d.db, "item", f.id, d.now());
    }
    return failed;
}

// 37.2 hiding: the row first, then every file off. `ruleId` with by "rule" counts a hit when the post was not hidden yet.
export async function hidePost(d: HiddenDeps, postKey: string, by: HiddenBy, ruleId: string | null = null): Promise<{ files: MediaRow[]; failed: FileFailure[] }> {
    const before = (await hiddenRows(d.db, [postKey])).get(postKey);
    const kept = before?.state === "hidden";
    await setHiddenRow(d.db, kept ? before! : { post_key: postKey, state: "hidden", by, rule_id: ruleId, at: d.now() });
    if (!kept && ruleId) await d.db.prepare("UPDATE hidden_rules SET hits = hits + 1 WHERE id = ?1").bind(ruleId).run();
    const files = await postRows(d.db, postKey);
    const failed = await allOff(d, files);
    await dropLoops(d, files.map((f) => f.id));
    await sessionsNotPublic(d.db, postKey);
    return { files, failed };
}

// Unhiding: the row says exempt (no rule hides it again); the files stay as they are (off). A held row is dropped (the
// owner decided). No row: nothing to do.
async function unhide(d: HiddenDeps, row: HiddenRow | undefined, by: HiddenBy): Promise<void> {
    if (row?.state === "hidden") await setHiddenRow(d.db, { post_key: row.post_key, state: "exempt", by, rule_id: null, at: d.now() });
    else if (row?.state === "held") await deleteHiddenRow(d.db, row.post_key, "held");
}

// ---- POST /library/status (37.4) ------------------------------------------------------------------------------------------

export type StatusPost = { id: string; post_key: string; status: Status; files: ReturnType<typeof itemShape>[] };

// Each id as a post key: a live post's key as is, else a live file's (by its id or public id) post. null: unknown.
export async function postKeysOf(db: D1Database, ids: string[]): Promise<Map<string, string | null>> {
    const { results } = await db
        .prepare(
            `SELECT DISTINCT post_key FROM (SELECT m.deleted_at, ${POST_KEY_SQL} AS post_key FROM media_items m)
              WHERE deleted_at IS NULL AND post_key IN (SELECT value FROM json_each(?1))`,
        )
        .bind(JSON.stringify([...new Set(ids)]))
        .all<{ post_key: string }>();
    const posts = new Set(results.map((r) => r.post_key));
    const rest = ids.filter((i) => !posts.has(i));
    const files = await postKeysOfFiles(db, rest);
    return new Map(ids.map((i) => [i, posts.has(i) ? i : (files.get(i) ?? null)]));
}

async function shapes(d: HiddenDeps, files: MediaRow[]) {
    const fresh = new Map<string, MediaRow>();
    if (files.length > 0) {
        const { results } = await d.db
            .prepare(`SELECT ${ITEM_COLUMNS} FROM media_items WHERE deleted_at IS NULL AND id IN (SELECT value FROM json_each(?1))`)
            .bind(JSON.stringify(files.map((f) => f.id)))
            .all<MediaRow>();
        for (const r of results) fresh.set(r.id, r);
    }
    const live = files.map((f) => fresh.get(f.id)).filter((r): r is MediaRow => !!r);
    const priv = await privateUrlsOf(d, live.map((r) => r.id));
    return live.map((r) => itemShape(r, priv.get(r.id) ?? null));
}

async function statusOne(d: HiddenDeps, id: string, postKey: string, status: Status, by: HiddenBy): Promise<{ post?: StatusPost; failed: FileFailure[] }> {
    const files = await postRows(d.db, postKey);
    if (files.length === 0) return { failed: [{ id, error: "error.library.not_found" }] };
    const toggle = files.filter(toggleable);
    if ((status === "public" || status === "private") && toggle.length === 0) return { failed: [{ id, error: "error.private.not_toggleable" }] };
    let failed: FileFailure[] = [];
    if (status === "hidden") {
        failed = (await hidePost(d, postKey, by)).failed;
    } else {
        await unhide(d, (await hiddenRows(d.db, [postKey])).get(postKey), by);
        if (status === "off") {
            failed = await allOff(d, toggle);
        } else if (status === "public") {
            if (!d.vis) failed = toggle.map((f) => ({ id: f.id, error: "error.api.generic" }));
            else
                for (const f of toggle) {
                    const r = await setVisibility(d.vis, f.id, true, d.keyId);
                    if (r.status !== 200) failed.push({ id: f.id, error: codeOf(r) });
                }
        } else {
            if (!d.vis || !d.shareBaseUrl) failed = toggle.map((f) => ({ id: f.id, error: d.shareBaseUrl ? "error.api.generic" : "error.share.off" }));
            else {
                const pd: PrivateDeps = { db: d.db, vis: d.vis, shareBaseUrl: d.shareBaseUrl, now: d.now, keyId: d.keyId };
                for (const f of toggle) {
                    const r = await itemOn(pd, f.id);
                    if (r.status !== 200) failed.push({ id: f.id, error: codeOf(r) });
                }
            }
        }
    }
    return { post: { id, post_key: postKey, status, files: await shapes(d, files) }, failed };
}

// POST /library/status { ids, status } (37.4); `by` is "chat" for the chat and the MCP.
export function setStatus(d: HiddenDeps, ids: string[], status: Status, by: HiddenBy): Promise<StudioReply> {
    return guarded(d.db, "status", async () => {
        const keys = await postKeysOf(d.db, ids);
        const failed: FileFailure[] = [];
        const todo: { id: string; key: string }[] = [];
        const seen = new Set<string>();
        for (const id of ids) {
            const key = keys.get(id);
            if (!key) failed.push({ id, error: "error.library.not_found" });
            else if (!seen.has(key)) {
                seen.add(key);
                todo.push({ id, key });
            }
        }
        // at most STATUS_CONCURRENCY posts at once, each one's files one after the other
        const done = await pool(todo, STATUS_CONCURRENCY, (t) => statusOne(d, t.id, t.key, status, by));
        const posts: StatusPost[] = [];
        for (const r of done) {
            if (r.post) posts.push(r.post);
            failed.push(...r.failed);
        }
        return { status: 200, body: { status: "success", posts, failed } };
    });
}

// ---- rules: the routes (37.4) ------------------------------------------------------------------------------------------------

async function ruleById(db: D1Database, id: string): Promise<RuleRow | null> {
    return (await db.prepare("SELECT * FROM hidden_rules WHERE id = ?1").bind(id).first<RuleRow>()) ?? null;
}

export async function listRules(d: Pick<HiddenDeps, "db">): Promise<StudioReply> {
    return guarded(d.db, "rules", async () => {
        const { results } = await d.db.prepare("SELECT * FROM hidden_rules ORDER BY created_at, id").all<RuleRow>();
        return {
            status: 200,
            body: { status: "success", rules: results.map(ruleShape), hidden: await hiddenCount(d.db, "hidden"), held: await hiddenCount(d.db, "held") },
        };
    });
}

// The saved posts a rule would hide now: not exempt, not hidden (held ones count). Newest first.
async function candidates(db: D1Database, rule: Pick<RuleRow, "kind" | "value">): Promise<PostFacts[]> {
    const rows = await hiddenRows(db);
    return (await postFacts(db)).filter((p) => {
        const s = rows.get(p.post_key)?.state;
        return s !== "exempt" && s !== "hidden" && ruleMatches(rule, p);
    });
}

// Runs one rule over the library (apply): every match hidden by it. Answers how many.
async function applyRule(d: HiddenDeps, rule: RuleRow): Promise<number> {
    const matches = await candidates(d.db, rule);
    await pool(matches, STATUS_CONCURRENCY, (p) => hidePost(d, p.post_key, "rule", rule.id));
    return matches.length;
}

const parseKind = (v: unknown): RuleKind | null => (typeof v === "string" && (RULE_KINDS as readonly string[]).includes(v) ? (v as RuleKind) : null);

export function addRule(d: HiddenDeps, input: { kind: string; value?: string; enabled?: boolean; apply?: boolean }): Promise<StudioReply> {
    return guarded(d.db, "add rule", async () => {
        const kind = parseKind(input.kind);
        const value = kind ? normalizeRuleValue(kind, input.value ?? "") : null;
        if (!kind || value === null) return err(400, "error.hidden.bad_rule");
        const n = await d.db.prepare("SELECT COUNT(*) AS n FROM hidden_rules").first<{ n: number }>();
        if (Number(n?.n ?? 0) >= HIDDEN_RULES_MAX) return err(409, "error.hidden.too_many");
        const now = d.now();
        const rule: RuleRow = { id: randomBase62(16, d.randomBytes), kind, value, enabled: input.enabled === false ? 0 : 1, hits: 0, created_at: now, updated_at: now };
        await d.db
            .prepare("INSERT INTO hidden_rules (id, kind, value, enabled, hits, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)")
            .bind(rule.id, rule.kind, rule.value, rule.enabled, now)
            .run();
        const applied = input.apply && rule.enabled ? await applyRule(d, rule) : 0;
        return { status: 201, body: { status: "success", rule: ruleShape((await ruleById(d.db, rule.id)) ?? rule), applied } };
    });
}

export function previewRule(d: Pick<HiddenDeps, "db">, input: { kind: string; value?: string }): Promise<StudioReply> {
    return guarded(d.db, "preview", async () => {
        const kind = parseKind(input.kind);
        const value = kind ? normalizeRuleValue(kind, input.value ?? "") : null;
        if (!kind || value === null) return err(400, "error.hidden.bad_rule");
        const m = await candidates(d.db, { kind, value });
        return { status: 200, body: { status: "success", matches: m.length, sample: m.slice(0, PREVIEW_SAMPLE).map((p) => p.post_key) } };
    });
}

export function updateRule(d: HiddenDeps, id: string, input: { enabled?: boolean; value?: string; apply?: boolean }): Promise<StudioReply> {
    return guarded(d.db, "update rule", async () => {
        const rule = await ruleById(d.db, id);
        if (!rule) return err(404, "error.hidden.not_found");
        let value = rule.value;
        if (input.value !== undefined) {
            const v = normalizeRuleValue(rule.kind, input.value);
            if (v === null) return err(400, "error.hidden.bad_rule");
            value = v;
        }
        const enabled = input.enabled === undefined ? rule.enabled : input.enabled ? 1 : 0;
        const now = d.now();
        await d.db.prepare("UPDATE hidden_rules SET value = ?2, enabled = ?3, updated_at = ?4 WHERE id = ?1").bind(id, value, enabled, now).run();
        const fresh = { ...rule, value, enabled, updated_at: now };
        const applied = input.apply && enabled ? await applyRule(d, fresh) : 0;
        return { status: 200, body: { status: "success", rule: ruleShape((await ruleById(d.db, id)) ?? fresh), applied } };
    });
}

// Posts it hid stay hidden.
export function deleteRule(d: Pick<HiddenDeps, "db">, id: string): Promise<StudioReply> {
    return guarded(d.db, "delete rule", async () => {
        const r = await d.db.prepare("DELETE FROM hidden_rules WHERE id = ?1").bind(id).run();
        if (Number(r.meta?.changes ?? 0) === 0) return err(404, "error.hidden.not_found");
        return { status: 200, body: { status: "success" } };
    });
}

// ---- a save becomes ready (37.3) ------------------------------------------------------------------------------------------

// The post key of a studio session's post: an upload's item id ("upload:<id>"), else the session id.
export const sessionPostKey = (sid: string, link: string | null | undefined) => (link?.startsWith("upload:") ? link.slice(7) : sid);

export type Gate = "go" | "hidden" | "held";

// Runs when a save first becomes ready, BEFORE section 13's publish: the rules hide it, or (asked to be public, with an
// enabled about rule) it waits as `held`, or it goes on. Throws on a D1 failure: the caller must not publish then.
export async function atReady(d: HiddenDeps, postKey: string, wantsPublic: boolean): Promise<Gate> {
    if (!(await hiddenReady(d.db))) return "go";
    const row = (await hiddenRows(d.db, [postKey])).get(postKey);
    if (row?.state === "hidden") return "hidden";
    if (row?.state === "exempt") return "go";
    const rules = await enabledRules(d.db);
    const hit = rules.length > 0 ? (await postFacts(d.db, [postKey])).map((f) => firstMatch(rules, f))[0] : null;
    if (hit) {
        await hidePost(d, postKey, "rule", hit.id);
        return "hidden";
    }
    if (!wantsPublic) return row?.state === "held" ? "held" : "go";
    if (rules.some((r) => r.kind === "about")) {
        if (row?.state !== "held") await setHiddenRow(d.db, { post_key: postKey, state: "held", by: "rule", rule_id: null, at: d.now() });
        return "held";
    }
    // (held before, and the about rules are gone since: it goes now)
    if (row?.state === "held") await deleteHiddenRow(d.db, postKey, "held");
    return "go";
}

// The section 13 publish of a post released from `held`: every original file made public (one mirror per file), and its
// session's public state recorded.
async function publishPost(d: HiddenDeps, postKey: string): Promise<boolean> {
    const files = (await postRows(d.db, postKey)).filter((f) => f.bucket === "originals" && (f.role === "item" || (!f.role && isOriginalSource(f.source))));
    let url: string | null = null;
    let all = files.length > 0 && !!d.vis;
    if (d.vis) {
        for (const f of files) {
            const r = await publishOriginal(d.vis, f, d.keyId);
            const u = (r.body as { url?: unknown }).url;
            if (r.status === 201 && typeof u === "string") url ??= u;
            else all = false;
        }
    }
    await d.db
        .prepare("UPDATE studio_sessions SET public_state = ?2, public_url = ?3 WHERE (id = ?1 OR link = 'upload:' || ?1) AND public_state = 'pending'")
        .bind(postKey, url ? "ready" : "failed", url)
        .run();
    return all;
}

export type HeldResult = { held: number; hidden: number; published: number; waiting: number };

// The 15-minute cron (37.3): each held post whose about words are written (or given up on: probe failed, 3 failed
// writes, or HELD_GIVE_UP_MS since it was held; at once while "what it's about" is off) runs the rules again: a match
// hides it, otherwise the row goes and the section 13 publish runs.
export async function releaseHeld(d: HiddenDeps, o: { aboutOn: boolean }): Promise<HeldResult> {
    const out: HeldResult = { held: 0, hidden: 0, published: 0, waiting: 0 };
    if (!(await hiddenReady(d.db))) return out;
    const { results: held } = await d.db.prepare("SELECT post_key, state, by, rule_id, at FROM media_hidden WHERE state = 'held' ORDER BY at").all<HiddenRow>();
    out.held = held.length;
    if (held.length === 0) return out;
    const about = new Map<string, Pick<AboutRow, "probe_state" | "written_at" | "user_tags" | "attempts">>();
    try {
        const { results } = await d.db
            .prepare("SELECT post_key, probe_state, written_at, user_tags, attempts FROM media_about WHERE post_key IN (SELECT value FROM json_each(?1))")
            .bind(JSON.stringify(held.map((h) => h.post_key)))
            .all<AboutRow>();
        for (const a of results) about.set(a.post_key, a);
    } catch {
        // before 0022: nothing will ever be written, so the give-up time decides
    }
    const rules = await enabledRules(d.db);
    const now = d.now();
    for (const h of held) {
        const a = about.get(h.post_key);
        const done =
            !o.aboutOn ||
            !rules.some((r) => r.kind === "about") ||
            now - h.at >= HELD_GIVE_UP_MS ||
            (!!a && (a.written_at !== null || a.user_tags !== null || a.probe_state === "failed" || a.attempts >= ABOUT_MAX_ATTEMPTS));
        if (!done) {
            out.waiting++;
            continue;
        }
        try {
            const [facts] = await postFacts(d.db, [h.post_key]);
            if (!facts) {
                await deleteHiddenRow(d.db, h.post_key, "held");
                continue;
            }
            const hit = firstMatch(rules, facts);
            if (hit) {
                await hidePost(d, h.post_key, "rule", hit.id);
                out.hidden++;
                continue;
            }
            // the owner may have decided meanwhile (the row is gone or changed): only a row still held publishes
            const r = await d.db.prepare("DELETE FROM media_hidden WHERE post_key = ?1 AND state = 'held'").bind(h.post_key).run();
            if (Number(r.meta?.changes ?? 0) === 0) continue;
            await publishPost(d, h.post_key);
            out.published++;
        } catch (e) {
            console.error("[hidden] releasing a held post failed", h.post_key, String(e));
        }
    }
    return out;
}

// ---- reads for the ops ------------------------------------------------------------------------------------------------------

// What the chat's refusals say about a hidden target (37.6).
export const HIDDEN_HINT = "it's hidden; unhide it first with library.status";

// Which of these ids (post or file ids) are hidden posts now. Empty before 0025.
export async function hiddenTargets(db: D1Database, ids: string[]): Promise<string[]> {
    if (ids.length === 0 || !(await hiddenReady(db))) return [];
    const keys = await postKeysOf(db, ids);
    const rows = await hiddenRows(db, [...new Set([...keys.values()].filter((k): k is string => !!k))]);
    return ids.filter((i) => rows.get(keys.get(i) ?? "")?.state === "hidden");
}

// The hidden posts, newest hidden first, with who hid them.
export async function hiddenList(db: D1Database): Promise<HiddenRow[]> {
    if (!(await hiddenReady(db))) return [];
    return (await db.prepare("SELECT post_key, state, by, rule_id, at FROM media_hidden WHERE state = 'hidden' ORDER BY at DESC, post_key DESC").all<HiddenRow>()).results;
}

export { hiddenReady };
