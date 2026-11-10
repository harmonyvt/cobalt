// A local Miniflare run of GET /sync: the real syncPage, on workerd's D1, after the real migrations.
// Not part of npm test. Writes the sample response next to the process's stdout.
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
// D1's exec splits on every semicolon, which cuts a trigger in half. Triggers in 0038 end with a line `END;`.
const splitSql = (sql) => {
    const stripped = sql.replace(/--.*$/gm, "");
    const parts = [];
    let buf = "";
    let inTrigger = false;
    for (const line of stripped.split("\n")) {
        const t = line.trim();
        if (!inTrigger && /^CREATE\s+TRIGGER\b/i.test(t)) inTrigger = true;
        buf += line + "\n";
        if (inTrigger) {
            if (/^END\s*;\s*$/i.test(t)) {
                inTrigger = false;
                if (buf.trim()) parts.push(buf.trim());
                buf = "";
            }
        } else if (t.endsWith(";")) {
            if (buf.trim()) parts.push(buf.trim());
            buf = "";
        }
    }
    if (buf.trim()) parts.push(buf.trim());
    return parts;
};
for (const file of files) {
    for (const statement of splitSql(readFileSync(resolve(migrations, file), "utf8"))) {
        await d1.prepare(statement).run();
    }
}
await mf.dispatchFetch("http://sync.local/seed", { method: "POST" });
const res = await mf.dispatchFetch("http://sync.local/sync?since=0&limit=500");
const text = await res.text();
console.log("status", res.status);
console.log(text);
await mf.dispose();
