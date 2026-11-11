// Proves the share routes' batched reads against the real D1, not the node:sqlite fake: workerd's own D1 binding,
// started by Miniflare (both come with the Wrangler devDependency). No network, no secrets, no deploy.
//
//   node scripts/share-reads-proof.mjs        (from deploy/cloudflare/api; exits 1 if any check fails)
//
// The route functions themselves (src/share-sets.ts, src/share-collections.ts, src/collection-groups.ts, bundled from
// the sources) run here in node against two D1 databases of the real schema (every migration):
//   A. the binding as it is: every route batches its reads (src/share-reads.ts);
//   B. the same binding refusing any batch that starts with a SELECT: every route reads one statement after another,
//      the code as it was before.
// The same calls are made on both, in the order of test/share-reads.test.ts, and every answer and every row left behind
// must be the same; A's round trips are counted with src/d1-timing.ts and must be the numbers that test pins.
// Not part of `npm test` (it starts a workerd process); run it after touching the SQL in src/share-reads.ts.
import { build } from "esbuild";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as miniflare from "miniflare";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../src");
const migrations = resolve(here, "../../d1/migrations");

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";

let failed = 0;
const check = (name, ok, detail = "") => {
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  ${detail}` : ""}`);
};

// the route functions, bundled for node
const bundled = await build({
    stdin: {
        contents: `
            export { createShareSet, listShareSets, revokeShareSet, updateShareSet } from "./share-sets";
            export { createCollection, deleteCollection, listCollections, rerollCollection, updateCollection } from "./share-collections";
            export { createGroup, deleteGroup, listGroups, updateGroup } from "./collection-groups";
            export { timedDb } from "./d1-timing";
        `,
        resolveDir: src,
        sourcefile: "proof-entry.ts",
        loader: "ts",
    },
    bundle: true,
    format: "esm",
    target: "es2022",
    platform: "node",
    external: ["cloudflare:*"],
    write: false,
    logLevel: "silent",
});
const dir = mkdtempSync(join(tmpdir(), "share-reads-proof-"));
const file = join(dir, "routes.mjs");
writeFileSync(file, bundled.outputFiles[0].text);
const routes = await import(pathToFileURL(file).href);

const options = { modules: true, script: "export default { fetch() { return new Response('ok'); } };", compatibilityDate: "2026-09-01", d1Databases: ["DB", "DB2"] };
const mf = new miniflare.Miniflare(typeof miniflare.convertV4MiniflareOptions === "function" ? miniflare.convertV4MiniflareOptions(options) : options);

// The binding with every batch that starts with a read refused: tryBatch answers null and the routes fall back.
function readsInTurn(db) {
    const sqlOf = new WeakMap();
    const tag = (statement, sql) => {
        const wrapped = new Proxy(statement, {
            get(target, prop) {
                if (prop === "bind") return (...values) => tag(target.bind(...values), sql);
                const value = Reflect.get(target, prop, target);
                return typeof value === "function" ? value.bind(target) : value;
            },
        });
        sqlOf.set(wrapped, { sql, statement });
        return wrapped;
    };
    return new Proxy(db, {
        get(target, prop) {
            if (prop === "prepare") return (sql) => tag(target.prepare(sql), sql);
            if (prop === "batch") {
                return async (statements) => {
                    if (/^\s*SELECT/i.test(sqlOf.get(statements[0])?.sql ?? "")) throw new Error("D1_ERROR: a batch that starts with a read is refused here");
                    return target.batch(statements.map((s) => sqlOf.get(s)?.statement ?? s));
                };
            }
            const value = Reflect.get(target, prop, target);
            return typeof value === "function" ? value.bind(target) : value;
        },
    });
}

const bytes = (seed) => (n) => Uint8Array.from({ length: n }, () => (seed = (seed * 73 + 41) % 241));
const post = (body) => new Request("https://x/", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const patch = (body) => new Request("https://x/", { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const postKeyOf = (n) => `https://x.com/someone/status/${n}`;

// The calls of test/share-reads.test.ts's script, on `db` (through `routed`, what the routes are given).
async function script(db, routed, trips) {
    let t = 10_000;
    const now = () => (t += 10);
    const sets = { db: routed, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, now, randomBytes: bytes(1), keyBytes: bytes(2) };
    const collections = { db: routed, now, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, randomBytes: bytes(3), setRandomBytes: bytes(4) };
    const groups = { db: routed, now, randomBytes: bytes(5) };
    let n = 0;
    const fileRow = async (over = {}) => {
        n++;
        const r = {
            id: `File${String(n).padStart(12, "0")}`,
            kind: "private",
            source: "saved",
            bucket: "originals",
            r2_key: `originals/sess${n}.mp4`,
            name: `clip${n}.mp4`,
            content_type: "video/mp4",
            link: postKeyOf(n),
            created_at: 1_000 + n,
            deleted_at: null,
            poster: null,
            visibility: null,
            public_key: null,
            public_id: null,
            ...over,
        };
        await db
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, width, height, duration, link, key_id, created_at, deleted_at, poster, visibility, public_key, public_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 4096, 480, 560, 9.6, ?8, 'k', ?9, ?10, ?11, ?12, ?13, ?14)`,
            )
            .bind(r.id, r.kind, r.source, r.bucket, r.r2_key, r.name, r.content_type, r.link, r.created_at, r.deleted_at, r.poster, r.visibility, r.public_key, r.public_id)
            .run();
        return r.id;
    };
    const pub = (i, over = {}) => fileRow({ visibility: "public", public_key: `PuBlIc${String(i).padStart(4, "0")}.mp4`, poster: `${MEDIA}PoStEr${String(i).padStart(4, "0")}.jpg`, ...over });
    const hide = (key, state = "hidden") => db.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?1, ?2, 'you', NULL, 1)").bind(key, state).run();
    const out = [];
    const say = async (label, expected, call) => {
        const before = trips();
        const reply = await call();
        out.push({ label, status: reply.status, body: reply.body, trips: trips() - before, expected });
        return reply.body;
    };

    const a = await pub(1);
    const b = await pub(2);
    const c = await pub(3, { content_type: "image/jpeg", public_key: "PuBlIc0003.jpg" });
    const priv = await fileRow();
    const gone = await pub(5, { deleted_at: 9 });
    const hidden = await pub(6);
    const held = await pub(7);
    const copy = await pub(8, { public_id: "Copy000000000008" });

    // (the first route call also asks once whether posts can be hidden: hidden-store.ts keeps the answer)
    await routes.listShareSets(sets);
    const one = (await say("create a public link", 2, () => routes.createShareSet(sets, post({ items: [a, b], title: "first" }), "key-1"))).set.id;
    const two = (await say("create a private link", 2, () => routes.createShareSet(sets, post({ items: [b, c, priv], private: true }), "key-1"))).set.id;
    await say("create: a private file refused", 1, () => routes.createShareSet(sets, post({ items: [a, priv] }), "key-1"));
    await say("create: a deleted file refused", 1, () => routes.createShareSet(sets, post({ items: [a, gone] }), "key-1"));
    await db.prepare("INSERT INTO share_settings (id, new_links, updated_at) VALUES (1, 'private', 1)").run();
    const three = (await say("create: private by the owner's setting", 2, () => routes.createShareSet(sets, post({ items: [a, c, priv] }), "key-1"))).set.id;
    await db.prepare("UPDATE share_settings SET new_links = 'public'").run();
    const four = (await say("create a link of four", 2, () => routes.createShareSet(sets, post({ items: [a, held, hidden, copy] }), "key-1"))).set.id;
    await hide(postKeyOf(7), "held");
    await hide(postKeyOf(6));
    await say("create: a hidden post refused, a held one's wait ended", 2, () => routes.createShareSet(sets, post({ items: [hidden, held] }), "key-1"));
    await say("create: a public copy's id is not a file", 1, () => routes.createShareSet(sets, post({ items: [a, "Copy000000000008"] }), "key-1"));
    await say("list the links", 1, () => routes.listShareSets(sets));

    await say("PATCH: move", 3, () => routes.updateShareSet(sets, patch({ items: [b, a] }), one));
    await say("PATCH: add and clear the title", 4, () => routes.updateShareSet(sets, patch({ items: [b, a, c], title: null }), one));
    await say("PATCH: a private file refused", 2, () => routes.updateShareSet(sets, patch({ items: [b, a, c, priv] }), one));
    await say("PATCH: a hidden file refused", 2, () => routes.updateShareSet(sets, patch({ items: [b, a, c, hidden] }), one));
    await hide(postKeyOf(1), "held");
    await say("PATCH: a private link takes any file, a held one's wait ended", 5, () => routes.updateShareSet(sets, patch({ items: [c, b, priv, a] }), two));
    await say("PATCH: another device changed it", 2, () => routes.updateShareSet(sets, patch({ items: [a, b], expect: [a, b] }), one));
    await say("PATCH: a title", 3, () => routes.updateShareSet(sets, patch({ title: "typed" }), four));
    await say("PATCH: an unknown link", 1, () => routes.updateShareSet(sets, patch({ title: "x" }), "1111111111111111111"));

    const col = (await say("create a collection", 2, () => routes.createCollection(collections, post({ name: "picks", set_ids: [one, two] }), "key-1"))).collection.id;
    const other = (await say("create another", 2, () => routes.createCollection(collections, post({ name: "other", set_ids: [two, three] }), "key-1"))).collection.id;
    await say("create: an unknown link refused", 1, () => routes.createCollection(collections, post({ name: "bad", set_ids: ["1111111111111111111"] }), "key-1"));
    await say("change a collection", 2, () => routes.updateCollection(collections, patch({ name: "renamed", add: [three, four], remove: [two] }), col));
    await say("change: an unknown link refused", 1, () => routes.updateCollection(collections, patch({ add: ["1111111111111111111"] }), col));
    await say("change: an unknown collection", 1, () => routes.updateCollection(collections, patch({ name: "x" }), "AAAAAAAAAAAAAAAA"));
    await say("list the collections", 1, () => routes.listCollections(collections));
    const group = (await say("create a set of collections", 2, () => routes.createGroup(groups, post({ name: "all", collection_ids: [col, other] }), "key-1"))).group.id;
    await say("create: an unknown collection refused", 1, () => routes.createGroup(groups, post({ name: "bad", collection_ids: ["AAAAAAAAAAAAAAAA"] }), "key-1"));
    await say("change a set", 2, () => routes.updateGroup(groups, patch({ name: "both", remove: [other], add: [other] }), group));
    await say("change: an unknown set", 1, () => routes.updateGroup(groups, patch({ name: "x" }), "AAAAAAAAAAAAAAAA"));
    await say("list the sets", 1, () => routes.listGroups(groups));

    await say("reroll: refused for a hidden file", 4, () => routes.rerollCollection(collections, col, "key-1"));
    await say("reroll", 6, () => routes.rerollCollection(collections, other, "key-1"));
    await say("list the links after the reroll", 1, () => routes.listShareSets(sets));
    await say("list the collections after the reroll", 1, () => routes.listCollections(collections));

    await say("revoke a link", 1, () => routes.revokeShareSet(sets, one));
    await say("revoke it again", 1, () => routes.revokeShareSet(sets, one));
    await say("revoke an unknown link", 1, () => routes.revokeShareSet(sets, "1111111111111111111"));
    await say("delete a collection", 1, () => routes.deleteCollection(collections, other));
    await say("delete it again", 1, () => routes.deleteCollection(collections, other));
    await say("delete a set", 1, () => routes.deleteGroup(groups, group));
    await say("delete it again", 1, () => routes.deleteGroup(groups, group));
    await say("list the links at the end", 1, () => routes.listShareSets(sets));
    await say("list the collections at the end", 1, () => routes.listCollections(collections));
    await say("list the sets at the end", 1, () => routes.listGroups(groups));
    return out;
}

const TABLES = ["share_sets", "private_links", "media_hidden", "share_collections", "share_collection_items", "collection_groups", "collection_group_items"];
const dump = async (db) => {
    const out = {};
    for (const t of TABLES) out[t] = (await db.prepare(`SELECT * FROM ${t} ORDER BY ${t === "private_links" ? "created_at, target_id, revoked_at" : "1, 2"}`).all()).results;
    return out;
};
// every private link key named by when it first comes up: a reroll's keys are random
const keysNamed = (value) => {
    const names = new Map();
    return JSON.stringify(value).replace(/(\/p\/|"key":")([A-Za-z0-9]{22})(?![A-Za-z0-9])/g, (_m, lead, key) => {
        if (!names.has(key)) names.set(key, `key-${names.size + 1}`);
        return `${lead}${names.get(key)}`;
    });
};

try {
    const dbs = [await mf.getD1Database("DB"), await mf.getD1Database("DB2")];
    for (const db of dbs) {
        for (const name of readdirSync(migrations).filter((f) => f.endsWith(".sql")).sort()) {
            const sql = readFileSync(resolve(migrations, name), "utf8").replace(/--.*$/gm, "");
            for (const statement of sql.split(";").map((s) => s.trim()).filter(Boolean)) await db.prepare(statement).run();
        }
    }
    const { db: counted, stats } = routes.timedDb(dbs[0]);
    const batched = await script(dbs[0], counted, () => stats.n);
    const inTurn = await script(dbs[1], readsInTurn(dbs[1]), () => 0);

    check("no call fell over", !batched.some((r) => r.status === 503) && !inTurn.some((r) => r.status === 503), batched.filter((r) => r.status === 503).map((r) => r.label).join(", "));
    for (const [i, r] of batched.entries()) {
        const other = inTurn[i];
        const same = keysNamed([r.status, r.body]) === keysNamed([other.status, other.body]);
        check(`${r.label}: ${r.status}, ${r.trips} round trip${r.trips === 1 ? "" : "s"}`, same && r.trips === r.expected, same ? (r.trips === r.expected ? "" : `expected ${r.expected}`) : "the two paths answer differently");
    }
    check("every answer in order, keys named across the whole run", keysNamed(batched.map((r) => [r.status, r.body])) === keysNamed(inTurn.map((r) => [r.status, r.body])));
    check("the same rows are left behind", keysNamed(await dump(dbs[0])) === keysNamed(await dump(dbs[1])));
    const total = batched.reduce((sum, r) => sum + r.trips, 0);
    console.log(`\n${batched.length} calls, ${total} round trips batched`);
} finally {
    await mf.dispose();
    rmSync(dir, { recursive: true, force: true });
}

if (failed > 0) {
    console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
    process.exit(1);
}
console.log("\nall checks passed");
