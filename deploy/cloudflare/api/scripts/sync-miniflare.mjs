// A local Miniflare run of GET /sync: the real syncPage, on workerd's D1, after the real migrations.
// Not part of npm test. Writes the sample response next to the process's stdout.
//
// It also rehearses the apply of 0038 the way the real one is sent: the whole file, comments and trigger bodies
// included, as ONE statement string (`cf d1 migrations apply` posts the file in one call). Then it applies the file
// again, and once more after some writes, and stops with exit code 1 unless each run leaves the database as it was.
import { build } from "esbuild";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as miniflare from "miniflare";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../src");
const migrations = resolve(here, "../../d1/migrations");

const WORKER = `
import { syncPage } from "./sync";
const NOW = 1_700_000_000_000;
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/seed") {
      await env.DB.prepare(
        "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, created_at, visibility, post_key) VALUES ('p2', 'private', 'saved', 'originals', 'originals/p2.mp4', 'https://media.capybaraharmony.com/p2.mp4', 'capybara.mp4', 'video/mp4', 1200, 1920, 1080, 4, 'https://x.com/a/status/2', ?1, 'public', 'p2')",
      ).bind(NOW).run();
      await env.DB.prepare("INSERT INTO media_titles (post_key, title, updated_at) VALUES ('p2', 'capybara spa day', ?1)").bind(NOW).run();
      await env.DB.prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, created_at, visibility, post_key) VALUES ('p3', 'private', 'upload', 'originals', 'uploads/p3.mp4', 'old.mp4', 'video/mp4', ?1, 'private', 'p3')").bind(NOW).run();
      await env.DB.prepare("UPDATE media_items SET deleted_at = ?1 WHERE id = 'p3'").bind(NOW).run();
      return new Response("ok");
    }
    const page = await syncPage(
      { db: env.DB, now: () => NOW, apiUrl: "https://api.capybaraharmony.com/", shareBaseUrl: "https://share.capybaraharmony.com/" },
      url.searchParams,
    );
    return Response.json(page.body, { status: page.status });
  },
};
`;

const bundled = await build({
    stdin: { contents: WORKER, resolveDir: src, sourcefile: "sync-mf.ts", loader: "ts" },
    bundle: true,
    format: "esm",
    target: "es2022",
    platform: "neutral",
    external: ["node:*"],
    plugins: [
        {
            name: "stub-npm",
            setup(b) {
                // syncPage's import graph reaches SDKs it never calls. Those packages are not installed for a
                // neutral bundle; a stand-in keeps the module graph loadable. The sync path does not call them.
                b.onResolve({ filter: /.*/ }, (args) => {
                    if (args.path.startsWith(".") || args.path.startsWith("/") || args.path.startsWith("\0") || args.path.startsWith("node:")) return null;
                    if (args.namespace === "stub") return null;
                    return { path: args.path, namespace: "stub" };
                });
                b.onLoad({ filter: /.*/, namespace: "stub" }, () => ({
                    contents: "const noop = () => ({}); const p = new Proxy(noop, { get: () => p, apply: () => p }); export default p; export const z = p;",
                    loader: "js",
                }));
            },
        },
    ],
    write: false,
    logLevel: "silent",
});
const script = bundled.outputFiles[0].text;

const options = {
    modules: true,
    script,
    compatibilityDate: "2026-09-01",
    d1Databases: { DB: "cobalt-keys" },
};
const mf = new miniflare.Miniflare(typeof miniflare.convertV4MiniflareOptions === "function" ? miniflare.convertV4MiniflareOptions(options) : options);

const d1 = await mf.getD1Database("DB");
const files = readdirSync(migrations).filter((f) => f.endsWith(".sql")).sort();
const SYNC = files.find((f) => f.startsWith("0038"));
// The earlier migrations hold no trigger, so a statement ends at its semicolon. (0038 is not split: see above.)
const splitSql = (sql) =>
    sql
        .replace(/--.*$/gm, "")
        .split(";")
        .map((part) => part.trim())
        .filter((part) => part !== "");
for (const file of files.filter((f) => f < SYNC)) {
    for (const statement of splitSql(readFileSync(resolve(migrations, file), "utf8"))) {
        await d1.prepare(statement).run();
    }
}

// A library from before the migration: files with no stored key, a deleted one, and one of each other thing.
const NOW = 1_700_000_000_000;
const item = (id, sessionId, link, createdAt, deletedAt) =>
    d1
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, link, session_id, created_at, visibility, deleted_at) VALUES (?1, 'private', 'saved', 'originals', ?2, ?3, 'video/mp4', 10, ?4, ?5, ?6, 'private', ?7)",
        )
        .bind(id, `originals/${id}.mp4`, `${id}.mp4`, link, sessionId, createdAt, deletedAt)
        .run();
await d1.prepare("INSERT INTO studio_sessions (id, link, status, created_at, expires_at) VALUES ('sessUpload', 'upload:old1', 'ready', 1, 9), ('sessSaved', 'https://x.com/a/status/1', 'ready', 1, 9)").run();
await item("old1", null, null, NOW - 300, null);
await item("old1render", "sessUpload", null, NOW - 250, null);
await item("old2", "sessSaved", "https://x.com/a/status/1", NOW - 100, null);
await item("old3", null, "https://y.com/z", NOW - 200, null);
await item("oldDead", null, null, NOW - 50, NOW);
await d1.prepare("INSERT INTO share_sets (id, items, created_at) VALUES ('1234567890123456789', '[]', 1)").run();
await d1.prepare("INSERT INTO share_collections (id, name, created_at, updated_at) VALUES ('col0000000000001', 'trips', 1, 1)").run();
await d1.prepare("INSERT INTO collection_groups (id, name, created_at, updated_at) VALUES ('set0000000000001', 'summer', 1, 1)").run();
await d1.prepare("INSERT INTO hidden_rules (id, kind, value, created_at, updated_at) VALUES ('rule000000000001', 'words', 'capybara', 1, 1)").run();

const rows = async (sql) => (await d1.prepare(sql).all()).results;
const state = async () =>
    JSON.stringify({
        schema: await rows("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type, name"),
        keys: await rows("SELECT id, post_key FROM media_items ORDER BY id"),
        changes: await rows("SELECT seq, entity, id, gone FROM changes ORDER BY seq"),
        state: await rows("SELECT id, trimmed_seq FROM sync_state"),
    });
const whole = readFileSync(resolve(migrations, SYNC), "utf8");
const apply = async (label) => {
    const result = await d1.prepare(whole).run();
    console.log(label, "applied as one string; rows written", result.meta?.changes);
    return state();
};
let failed = false;
const same = (label, a, b) => {
    console.log(label, a === b ? "same state" : "STATE DIFFERS");
    if (a !== b) failed = true;
};

const first = await apply("0038, first run:");
const parsed = JSON.parse(first);
console.log("triggers", parsed.schema.filter((r) => r.type === "trigger").length, "change rows", parsed.changes.length);
console.log("seed order", parsed.changes.map((c) => `${c.seq}:${c.entity}:${c.id}`).join(" "));
console.log("keys", parsed.keys.map((k) => `${k.id}=${k.post_key}`).join(" "));
same("0038, second run:", first, await apply("0038, second run:"));

await mf.dispatchFetch("http://sync.local/seed", { method: "POST" });
// writes the new triggers must log: a session for an existing post, a private link, a moved membership row
await d1.prepare("INSERT INTO studio_sessions (id, link, service, status, created_at, expires_at) VALUES ('sessReopen', 'upload:old1', 'upload', 'ready', 2, 9)").run();
await d1.prepare("INSERT INTO private_links (key, kind, target_id, created_at) VALUES ('kkkkkkkkkkkkkkkkkkkkkk', 'item', 'old2', 5)").run();
await d1.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES ('col0000000000001', '1234567890123456789', 1)").run();
const one = await d1.prepare("UPDATE studio_sessions SET status = 'saving' WHERE id = 'sessReopen'").run();
console.log("one session update, meta.changes", one.meta?.changes, "(on D1 this counts the trigger's delete and insert too)");
const moved = await state();
console.log("after writes", JSON.parse(moved).changes.map((c) => `${c.seq}:${c.entity}:${c.id}:${c.gone}`).join(" "));
same("0038, run after writes:", moved, await apply("0038, run after writes:"));

const res = await mf.dispatchFetch("http://sync.local/sync?since=0&limit=500");
const text = await res.text();
console.log("status", res.status);
console.log(text);
const above = await mf.dispatchFetch("http://sync.local/sync?since=999999");
console.log("a cursor above the head:", above.status, await above.text());
await mf.dispose();
if (failed) process.exit(1);
