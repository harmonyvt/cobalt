// V0 replay (apple/CONTRACT-VISIBILITY.md section 8.2): runs the data step against a COPY of the real
// database. Skipped unless VIS_REPLAY_DIR points at a directory holding
//   prod.sql               `cf d1 export <db> --dump-options-tables media_items studio_sessions studio_renders media_titles`
//   media-objects.json     `cf r2 objects list --bucket-name cobalt-media`
//   originals-objects.json `cf r2 objects list --bucket-name cobalt-originals`
// and writes replay-report.json there. Nothing here can reach production: the database is an
// in-memory node:sqlite copy and both buckets are listings whose put/delete THROW (the step must
// never write or delete an object).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { SERVICE_HEADER } from "../src/headers";
import { withBatch } from "./d1-batch";

const DIR = process.env.VIS_REPLAY_DIR;
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

type Listing = { key: string; size: number }[];
const bucket = (list: Listing, writes: string[]) => {
    const m = new Map(list.map((o) => [o.key, o.size]));
    const refuse = (what: string) => async (k: string) => {
        writes.push(`${what} ${k}`);
        throw new Error(`replay: ${what} is not allowed`);
    };
    return {
        head: async (k: string) => (m.has(k) ? { size: m.get(k)! } : null),
        get: async () => null,
        put: refuse("put"),
        delete: refuse("delete"),
    } as any;
};

describe.skipIf(!DIR || !existsSync(`${DIR}/prod.sql`))("replay against a copy of the production database", () => {
    it("dry run, apply, rerun, undo: the contract's numbers, both list shapes, no object written", async () => {
        const read = (f: string) => readFileSync(`${DIR}/${f}`, "utf8");
        const media: Listing = JSON.parse(read("media-objects.json"));
        const originals: Listing = JSON.parse(read("originals-objects.json"));
        const db = createFakeD1(read("prod.sql"));
        const m8 = readFileSync(new URL("../../d1/migrations/0008_visibility.sql", import.meta.url), "utf8");
        withBatch(db);
        const rawRows = () => db.raw.prepare("SELECT * FROM media_items ORDER BY created_at, id").all() as any[];
        const before = rawRows(); // before 0008
        db.raw.exec(m8);

        const writes: string[] = [];
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: db,
            ORIGINALS: bucket(originals, writes),
            MEDIA: bucket(media, writes),
            MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        };
        const container = { fetch: async () => new Response("{}") };
        const call = async (path: string, init: RequestInit = {}) => {
            const res = await handleRequest(
                new Request(`https://api.capybaraharmony.com${path}`, { ...init, headers: { [SERVICE_HEADER]: INTERNAL, ...(init.headers ?? {}) } }),
                env,
                container,
                { now: () => Date.now() },
            );
            return { status: res.status, body: (await res.json()) as any };
        };
        const migrate = (q: string) => call(`/library/visibility/migrate?${q}`, { method: "POST" });
        const listAll = async (q: string) => {
            const posts: any[] = [];
            let cursor: string | null = null;
            let last: any;
            do {
                const r = await call(`/library?limit=50${q}${cursor ? `&cursor=${cursor}` : ""}`);
                expect(r.status).toBe(200);
                last = r.body;
                posts.push(...last.posts);
                cursor = last.next;
            } while (cursor);
            return { posts, counts: last.counts, usage: last.usage, files: posts.flatMap((p) => p.files) as any[] };
        };
        const live = () => rawRows().filter((r) => r.deleted_at === null);
        const report: Record<string, unknown> = {
            export: {
                media_items_rows: before.length,
                live: before.filter((r) => r.deleted_at === null).length,
                sessions: (db.raw.prepare("SELECT COUNT(*) AS n FROM studio_sessions").get() as any).n,
                media_objects: media.length,
                originals_objects: originals.length,
            },
        };

        const legacyBefore = await listAll("");
        const v2Before = await listAll("&v=2");

        const dry = await migrate("dry_run=1&limit=100");
        expect(dry.status).toBe(200);
        report.dry_run = dry.body;
        expect(rawRows()).toHaveLength(before.length);
        expect(live().every((r) => r.visibility === null && r.merged_into === null)).toBe(true); // wrote nothing

        const apply = await migrate("dry_run=0&limit=100");
        expect(apply.status).toBe(200);
        report.apply = apply.body;
        const after = live();
        report.after_apply = {
            rows_live: after.length,
            public: after.filter((r) => r.visibility === "public").length,
            private: after.filter((r) => r.visibility === "private").length,
            unset: after.filter((r) => r.visibility === null).length,
            tombstones: rawRows().filter((r) => r.merged_into !== null).length,
            public_originals: after.filter((r) => r.bucket === "originals" && r.visibility === "public").map((r) => ({ id: r.id, public_id: r.public_id, url: r.url, public_key: r.public_key })),
        };
        // I1 and I2 on the copy: public <=> url, a public original's mirror is a listed object, a private row has none
        const mediaKeys = new Set(media.map((o) => o.key));
        for (const r of after) {
            expect(r.visibility === "public", `I1 ${r.id}`).toBe(r.url !== null);
            if (r.bucket === "media") expect(r.visibility).toBe("public");
            if (r.bucket === "originals" && r.public_key) expect(mediaKeys.has(r.public_key), `I2 ${r.id}`).toBe(r.visibility === "public");
        }
        const keys = after.map((r) => r.public_key).filter(Boolean);
        expect(new Set(keys).size).toBe(keys.length);

        const rerun = await migrate("dry_run=0&limit=100");
        report.rerun = rerun.body;
        expect(rerun.body.report.merge.pairs).toBe(0);
        expect(rerun.body.report.merge.already_merged).toBe(apply.body.report.merge.pairs);

        const legacyAfter = await listAll("");
        const v2After = await listAll("&v=2");
        report.lists = {
            legacy_before: { posts: legacyBefore.posts.length, files: legacyBefore.counts.files, listed_files: legacyBefore.files.length, usage: legacyBefore.usage },
            legacy_after: { posts: legacyAfter.posts.length, files: legacyAfter.counts.files, listed_files: legacyAfter.files.length, usage: legacyAfter.usage },
            v2_before: { posts: v2Before.posts.length, files: v2Before.counts.files, listed_files: v2Before.files.length, usage: v2Before.usage },
            v2_after: {
                posts: v2After.posts.length,
                files: v2After.counts.files,
                listed_files: v2After.files.length,
                usage: v2After.usage,
                public_originals: v2After.files.filter((f) => (f.source === "saved" || f.source === "upload") && f.visibility === "public").length,
                originals_with_poster: v2After.files.filter((f) => (f.source === "saved" || f.source === "upload") && f.poster_url).length,
                originals: v2After.files.filter((f) => f.source === "saved" || f.source === "upload").length,
            },
        };
        // the old shape: same posts, same files (minus the additive keys), only counts.files differs
        const norm = (l: Awaited<ReturnType<typeof listAll>>) =>
            Object.fromEntries(l.posts.map((p) => [p.id, p.files.map(({ visibility, visibility_toggle, ...f }: any) => f)]));
        expect(norm(legacyAfter)).toEqual(norm(legacyBefore));
        expect(legacyAfter.usage).toEqual(legacyBefore.usage);

        const undoDry = await migrate("undo=1&limit=100");
        report.undo_dry_run = undoDry.body;
        const undo = await migrate("undo=1&dry_run=0&limit=100");
        report.undo = undo.body;
        const restored = rawRows();
        // byte for byte: every pre-0008 row, with the four new columns NULL again
        const strip = (rows: any[]) => rows.map(({ visibility, public_key, public_id, merged_into, ...rest }) => rest);
        expect(strip(restored)).toEqual(before);
        expect(restored.every((r) => r.visibility === null && r.public_key === null && r.public_id === null && r.merged_into === null)).toBe(true);
        report.undo_restores_exported_rows_exactly = true;
        expect(writes).toEqual([]);
        report.object_writes_or_deletes = writes.length;

        writeFileSync(`${DIR}/replay-report.json`, JSON.stringify(report, null, 2));
    });
});
