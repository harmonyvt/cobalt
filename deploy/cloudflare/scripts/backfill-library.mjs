#!/usr/bin/env node
// Backfills the library's `media_items` table (d1/migrations/0004_library.sql,
// LIBRARY-CONTRACT.md) with what existed before the library did:
//
//   studio_sessions status 'ready' (not uploads)  -> 'saved'  (private, originals)
//   studio_renders  status 'success'              -> 'studio' (public, media)
//   R2 `cobalt-media` objects not covered above   -> 'webp'   (public, media), using the
//                                                    object's customMetadata when present
//
// It only ADDS rows and is idempotent: a row is skipped when media_items already
// has one for the same bucket + r2_key (the INSERT itself carries the same guard,
// so a second run, or the Worker writing a row meanwhile, never duplicates).
//
// Uses the global Cloudflare CLI (`cf`), authenticated as usual:
//   cf d1 query <db-id> --sql ... | --batch ...      (D1 database `cobalt-keys`)
//   cf r2 objects list --bucket-name cobalt-media
// Typed parameters (NULL, numbers) travel in --batch JSON, since --params only
// carries strings.
//
//   node deploy/cloudflare/scripts/backfill-library.mjs --dry-run   # print, write nothing
//   node deploy/cloudflare/scripts/backfill-library.mjs             # insert
//
// Options: --db <id> (default: the cobalt-keys id), --media-bucket <name>,
//          --media-base-url <url>, --cf <path to the cf binary>.

import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { pathToFileURL } from "node:url";

export const DEFAULT_DB = "42f18bb0-837a-47f7-b1e2-606eb705ab6c";
const DEFAULT_BUCKET = "cobalt-media";
const DEFAULT_BASE_URL = "https://media.capybaraharmony.com/";

export const COLUMNS = [
    "id", "kind", "source", "bucket", "r2_key", "url", "name", "content_type", "bytes",
    "width", "height", "duration", "link", "session_id", "key_id", "created_at",
];

// Same shape and guard as the Worker's insert (src/library.ts).
export const INSERT_SQL =
    `INSERT INTO media_items (${COLUMNS.join(", ")}) ` +
    `SELECT ${COLUMNS.map((_, i) => `?${i + 1}`).join(", ")} ` +
    "WHERE NOT EXISTS (SELECT 1 FROM media_items WHERE bucket = ?4 AND r2_key = ?5)";

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export function newId(rb = randomBytes) {
    let out = "";
    while (out.length < 16) {
        for (const b of rb(32)) if (b < 248 && out.length < 16) out += BASE62[b % 62];
    }
    return out;
}

const pageLink = (l) => (typeof l === "string" && /^https?:\/\//i.test(l) ? l : null);
const nameOfUrl = (url) => {
    try {
        return decodeURIComponent(new URL(url).pathname.split("/").pop() || "") || null;
    } catch {
        return null;
    }
};
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const ms = (v) => {
    const n = typeof v === "string" ? Number(v) : v;
    if (Number.isFinite(n) && n > 0) return n;
    const t = typeof v === "string" ? Date.parse(v) : NaN;
    return Number.isFinite(t) ? t : null;
};

// ---- pure planning (exported for the tests) ---------------------------------

/** 'saved': one private row per ready, non-upload session whose original is stored. */
export function planSaved(sessions) {
    return sessions
        .filter((s) => s.status === "ready" && s.r2_key && s.service !== "upload")
        .map((s) => ({
            kind: "private",
            source: "saved",
            bucket: "originals",
            r2_key: s.r2_key,
            url: null,
            name: s.title || s.r2_key.split("/").pop(),
            content_type: s.content_type ?? null,
            bytes: num(s.bytes),
            width: num(s.width),
            height: num(s.height),
            duration: num(s.duration),
            link: pageLink(s.link),
            session_id: s.id,
            key_id: s.key_id ?? null,
            created_at: s.created_at,
        }));
}

/** 'studio': one public row per successful render (renders joined with their session). */
export function planStudio(renders) {
    const out = [];
    for (const r of renders) {
        const key = nameOfUrl(r.url);
        if (r.status !== "success" || !key) continue;
        const title = (r.title || "").trim();
        out.push({
            kind: "public",
            source: "studio",
            bucket: "media",
            r2_key: key,
            url: r.url,
            name: title ? `${title.replace(/\.[A-Za-z0-9]{1,5}$/, "")}.webp` : key,
            content_type: "image/webp",
            bytes: num(r.bytes),
            width: num(r.out_width),
            height: num(r.out_height),
            duration: num(r.seconds),
            link: pageLink(r.link),
            session_id: r.session_id,
            key_id: r.key_id ?? null,
            created_at: r.created_at,
        });
    }
    return out;
}

/** True for a server-made poster (APP-API-CONTRACT.md section 13): it is not a library file. */
export const isPosterObject = (o) => (o.custom_metadata ?? o.customMetadata ?? {}).poster === "1";

/**
 * 'webp': R2 objects (as `cf r2 objects list` returns them) no row covers yet. Posters (JPEGs the
 * Durable Object cut out of a saved video, tagged `poster: "1"` in their custom metadata) live in the
 * same bucket but are not library files: media_items points at them through `poster`.
 */
export function planWebp(objects, baseUrl) {
    const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
    return objects.filter((o) => !isPosterObject(o)).map((o) => {
        const meta = o.custom_metadata ?? o.customMetadata ?? {};
        const http = o.http_metadata ?? o.httpMetadata ?? {};
        const keyId = typeof meta.keyId === "string" ? meta.keyId : null;
        // A studio render whose row is gone (older than the session tables): keep its session.
        const studio = keyId?.startsWith("studio:") ?? false;
        return {
            kind: "public",
            source: studio ? "studio" : "webp",
            bucket: "media",
            r2_key: o.key,
            url: `${base}${o.key}`,
            name: o.key,
            content_type: http.contentType ?? http.content_type ?? "image/webp",
            bytes: num(o.size),
            width: null,
            height: null,
            duration: null,
            link: pageLink(meta.source),
            session_id: studio ? keyId.slice("studio:".length) : null,
            key_id: keyId && !studio ? keyId : null,
            created_at: ms(meta.createdAt) ?? ms(o.last_modified ?? o.lastModified) ?? Date.now(),
        };
    });
}

/** Drops candidates whose bucket + key is already listed (or appears twice), in order. */
export function dedupe(candidates, existing) {
    const seen = new Set(existing);
    const out = [];
    for (const c of candidates) {
        const k = `${c.bucket}\u0000${c.r2_key}`;
        if (seen.has(k)) continue;
        seen.add(k);
        out.push(c);
    }
    return out;
}

/** Statement + typed params for one row (id minted here). */
export function insertStatement(row, rb) {
    const withId = { id: newId(rb), ...row };
    return { sql: INSERT_SQL, params: COLUMNS.map((c) => withId[c] ?? null) };
}

// ---- cf wrappers --------------------------------------------------------------

// `cf` may print the API envelope or just its result; accept both.
export function rowsOf(json) {
    if (Array.isArray(json)) {
        if (json.length && json.every((x) => x && typeof x === "object" && Array.isArray(x.results))) {
            return json.flatMap((x) => x.results);
        }
        return json;
    }
    if (json && typeof json === "object") {
        if (Array.isArray(json.results)) return json.results;
        if ("result" in json) return rowsOf(json.result);
    }
    return null;
}
export function objectsOf(json) {
    if (Array.isArray(json)) return json;
    if (json && typeof json === "object") {
        if (Array.isArray(json.objects)) return json.objects;
        if ("result" in json) return objectsOf(json.result);
    }
    return null;
}
export function cursorOf(json) {
    if (!json || typeof json !== "object") return null;
    const info = json.result_info ?? json.resultInfo ?? json;
    const truncated = info.is_truncated ?? info.isTruncated ?? json.truncated;
    const cursor = info.cursor ?? json.cursor ?? null;
    return truncated === false ? null : cursor || null;
}

function parseJson(stdout) {
    const t = stdout.trim();
    try {
        return JSON.parse(t);
    } catch {
        const i = t.search(/[[{]/);
        if (i < 0) throw new Error(`no JSON in cf output: ${t.slice(0, 200)}`);
        return JSON.parse(t.slice(i));
    }
}

function makeCf(bin) {
    const run = (args) => parseJson(execFileSync(bin, ["-q", ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }));
    return {
        query(db, sql) {
            const j = run(["d1", "query", db, "--sql", sql]);
            const rows = rowsOf(j);
            if (!rows) throw new Error(`unexpected cf d1 query output: ${JSON.stringify(j).slice(0, 300)}`);
            return rows;
        },
        batch(db, statements) {
            return run(["d1", "query", db, "--batch", JSON.stringify(statements)]);
        },
        listObjects(bucket) {
            const all = [];
            let cursor = null;
            do {
                const args = ["r2", "objects", "list", "--bucket-name", bucket, "--per-page", "1000"];
                if (cursor) args.push("--cursor", cursor);
                const j = run(args);
                const page = objectsOf(j);
                if (!page) throw new Error(`unexpected cf r2 objects list output: ${JSON.stringify(j).slice(0, 300)}`);
                all.push(...page);
                cursor = cursorOf(j);
            } while (cursor);
            return all;
        },
    };
}

// ---- main ---------------------------------------------------------------------

function parseArgs(argv) {
    const o = { dryRun: false, db: DEFAULT_DB, bucket: DEFAULT_BUCKET, base: DEFAULT_BASE_URL, cf: "cf" };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--dry-run") o.dryRun = true;
        else if (a === "--db") o.db = argv[++i];
        else if (a === "--media-bucket") o.bucket = argv[++i];
        else if (a === "--media-base-url") o.base = argv[++i];
        else if (a === "--cf") o.cf = argv[++i];
        else {
            console.error(`unknown argument: ${a}`);
            process.exit(64);
        }
    }
    return o;
}

export async function main(argv = process.argv.slice(2)) {
    const o = parseArgs(argv);
    const cf = makeCf(o.cf);

    const existingRows = cf.query(o.db, "SELECT bucket, r2_key FROM media_items");
    const existing = existingRows.map((r) => `${r.bucket}\u0000${r.r2_key}`);
    console.error(`media_items already holds ${existing.length} row(s)`);

    const sessions = cf.query(
        o.db,
        "SELECT id, key_id, link, service, title, status, r2_key, content_type, bytes, duration, width, height, created_at FROM studio_sessions WHERE status = 'ready' AND r2_key IS NOT NULL ORDER BY created_at",
    );
    const renders = cf.query(
        o.db,
        "SELECT r.session_id, r.status, r.url, r.bytes, r.out_width, r.out_height, r.seconds, r.created_at, s.title, s.link, s.key_id " +
            "FROM studio_renders r LEFT JOIN studio_sessions s ON s.id = r.session_id WHERE r.status = 'success' AND r.url IS NOT NULL ORDER BY r.created_at",
    );
    const objects = cf.listObjects(o.bucket);
    console.error(`found ${sessions.length} ready session(s), ${renders.length} successful render(s), ${objects.length} object(s) in ${o.bucket}`);

    // Order matters for the guard: saved, then studio renders, then whatever R2
    // holds that neither explains.
    const plan = dedupe(
        [...planSaved(sessions), ...planStudio(renders), ...planWebp(objects, o.base)],
        existing,
    );

    const count = {};
    for (const r of plan) count[r.source] = (count[r.source] ?? 0) + 1;
    console.error(
        plan.length === 0
            ? "nothing to insert: the library is already complete"
            : `${o.dryRun ? "would insert" : "inserting"} ${plan.length} row(s): ${JSON.stringify(count)}`,
    );
    for (const r of plan) {
        console.log(`${r.source.padEnd(7)} ${r.kind.padEnd(7)} ${r.bucket}/${r.r2_key}  ${r.name}${r.link ? `  <- ${r.link}` : ""}`);
    }
    if (o.dryRun || plan.length === 0) return;

    for (let i = 0; i < plan.length; i += 20) {
        cf.batch(o.db, plan.slice(i, i + 20).map((r) => insertStatement(r)));
        console.error(`  inserted ${Math.min(i + 20, plan.length)}/${plan.length}`);
    }
    const summary = cf.query(o.db, "SELECT source, kind, COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL GROUP BY source, kind");
    console.error("media_items now:", JSON.stringify(summary));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch((e) => {
        console.error(String(e?.stack || e));
        process.exit(1);
    });
}
