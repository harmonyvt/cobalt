// scripts/backfill-library.mjs: the planning (pure), the INSERT against the real
// schema (node:sqlite), and the whole script against a fake `cf` binary. The
// real CLI and the remote database are never touched.
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
    COLUMNS,
    cursorOf,
    dedupe,
    insertStatement,
    main,
    newId,
    objectsOf,
    planSaved,
    planStudio,
    planWebp,
    rowsOf,
} from "../../scripts/backfill-library.mjs";
import { createFakeD1 } from "../../test-support/d1-sqlite";

const BASE = "https://media.capybaraharmony.com/";
const SESSIONS = [
    {
        id: "S1aaaaaaaaaaaaaaaaaaaa",
        key_id: "k1",
        link: "https://x.com/a/status/1",
        service: "x",
        title: "x_1",
        status: "ready",
        r2_key: "originals/S1aaaaaaaaaaaaaaaaaaaa.mp4",
        content_type: "video/mp4",
        bytes: 4096,
        duration: 9.6,
        width: 480,
        height: 560,
        created_at: 1000,
    },
    // an upload's session is not a 'saved' item (it is the upload's own item)
    { id: "S2", service: "upload", link: "upload:abc", title: "a.mp4", status: "ready", r2_key: "uploads/abc.mp4", created_at: 1500 },
];
const RENDERS = [
    {
        session_id: "S1aaaaaaaaaaaaaaaaaaaa",
        status: "success",
        url: `${BASE}Render0001.webp`,
        bytes: 1500,
        out_width: 480,
        out_height: 560,
        seconds: 5,
        created_at: 2000,
        title: "x_1",
        link: "https://x.com/a/status/1",
        key_id: "k1",
    },
];
const OBJECTS = [
    { key: "Render0001.webp", size: 1500, last_modified: "2026-09-30T10:00:00Z" }, // explained by the render
    {
        key: "Plain00001.webp",
        size: 900,
        last_modified: "2026-09-29T10:00:00Z",
        http_metadata: { contentType: "image/webp" },
        custom_metadata: { keyId: "k1", source: "https://tiktok.com/v/1", createdAt: "1790000000000" },
    },
    { key: "Old0000001.webp", size: 800, last_modified: "2026-09-28T10:00:00Z" }, // no metadata at all
    {
        key: "StudioGone.webp",
        size: 700,
        last_modified: "2026-09-27T10:00:00Z",
        custom_metadata: { keyId: "studio:S9zzzzzzzzzzzzzzzzzzzz", source: "upload:abc" },
    },
];

describe("planning", () => {
    it("planSaved: ready sessions only, never uploads", () => {
        const rows = planSaved([...SESSIONS, { ...SESSIONS[0], id: "S3", status: "saving" }, { ...SESSIONS[0], id: "S4", r2_key: null }]);
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({
            kind: "private",
            source: "saved",
            bucket: "originals",
            r2_key: "originals/S1aaaaaaaaaaaaaaaaaaaa.mp4",
            url: null,
            name: "x_1",
            link: "https://x.com/a/status/1",
            session_id: "S1aaaaaaaaaaaaaaaaaaaa",
            created_at: 1000,
        });
    });
    it("planStudio: public webp rows keyed by the file name in the URL", () => {
        const [r] = planStudio([...RENDERS, { ...RENDERS[0], status: "error", url: `${BASE}Nope000000.webp` }, { ...RENDERS[0], url: null }]);
        expect(r).toMatchObject({
            kind: "public",
            source: "studio",
            bucket: "media",
            r2_key: "Render0001.webp",
            url: `${BASE}Render0001.webp`,
            name: "x_1.webp",
            width: 480,
            height: 560,
            duration: 5,
            session_id: "S1aaaaaaaaaaaaaaaaaaaa",
        });
    });
    it("planWebp: uses customMetadata when present, falls back to the object's own data", () => {
        const rows = planWebp(OBJECTS, BASE);
        const by = Object.fromEntries(rows.map((r: any) => [r.r2_key, r]));
        expect(by["Plain00001.webp"]).toMatchObject({
            source: "webp",
            url: `${BASE}Plain00001.webp`,
            link: "https://tiktok.com/v/1",
            key_id: "k1",
            created_at: 1790000000000,
            bytes: 900,
            content_type: "image/webp",
        });
        expect(by["Old0000001.webp"]).toMatchObject({ source: "webp", link: null, key_id: null, created_at: Date.parse("2026-09-28T10:00:00Z") });
        expect(by["StudioGone.webp"]).toMatchObject({ source: "studio", session_id: "S9zzzzzzzzzzzzzzzzzzzz", key_id: null, link: null });
    });
    it("dedupe: skips what exists and what repeats; the earlier plan wins", () => {
        const all = [...planStudio(RENDERS), ...planWebp(OBJECTS, BASE)];
        const out = dedupe(all, ["media\u0000Old0000001.webp"]);
        expect(out.map((r: any) => `${r.source}:${r.r2_key}`)).toEqual([
            "studio:Render0001.webp", // not planned again as 'webp'
            "webp:Plain00001.webp",
            "studio:StudioGone.webp",
        ]);
    });
    it("newId is 16 base62 characters", () => {
        expect(newId()).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(newId()).not.toBe(newId());
    });
    it("understands the envelopes cf may print", () => {
        expect(rowsOf([{ results: [{ a: 1 }], success: true }])).toEqual([{ a: 1 }]);
        expect(rowsOf({ result: [{ results: [{ a: 1 }, { a: 2 }] }] })).toEqual([{ a: 1 }, { a: 2 }]);
        expect(rowsOf({ results: [{ a: 1 }] })).toEqual([{ a: 1 }]);
        expect(rowsOf([{ a: 1 }])).toEqual([{ a: 1 }]);
        expect(rowsOf([])).toEqual([]);
        expect(rowsOf("nope")).toBeNull();
        expect(objectsOf({ result: [{ key: "a" }], result_info: { cursor: "c", is_truncated: true } })).toEqual([{ key: "a" }]);
        expect(objectsOf({ result: { objects: [{ key: "a" }] } })).toEqual([{ key: "a" }]);
        expect(objectsOf([{ key: "a" }])).toEqual([{ key: "a" }]);
        expect(cursorOf({ result_info: { cursor: "c", is_truncated: true } })).toBe("c");
        expect(cursorOf({ result_info: { cursor: "c", is_truncated: false } })).toBeNull();
        expect(cursorOf({ result: [] })).toBeNull();
    });
});

describe("the INSERT, against the real schema", () => {
    it("inserts a typed row (NULLs included) and is idempotent per bucket + key", async () => {
        const db = createFakeD1();
        const [row] = planStudio(RENDERS);
        const { sql, params } = insertStatement(row);
        expect(params).toHaveLength(COLUMNS.length);
        const first = await db.prepare(sql).bind(...params).run();
        const second = await db.prepare(sql).bind(...insertStatement(row).params).run();
        expect(first.meta.changes).toBe(1);
        expect(second.meta.changes).toBe(0);
        const rows = db.raw.prepare("SELECT * FROM media_items").all() as any[];
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({ kind: "public", source: "studio", bucket: "media", r2_key: "Render0001.webp", deleted_at: null, width: 480 });
        // the same key in the other bucket is a different object
        const saved = planSaved(SESSIONS)[0];
        await db.prepare(sql).bind(...insertStatement({ ...saved, r2_key: "Render0001.webp" }).params).run();
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 2 });
    });
});

// ---- the whole script against a fake `cf` ---------------------------------------------

const dir = mkdtempSync(path.join(tmpdir(), "backfill-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

function fakeCf(existing: unknown[]) {
    const log = path.join(dir, `log-${Math.random().toString(36).slice(2)}.jsonl`);
    const bin = path.join(dir, `cf-${Math.random().toString(36).slice(2)}.mjs`);
    writeFileSync(
        bin,
        `#!/usr/bin/env node
import { appendFileSync } from "node:fs";
const args = process.argv.slice(2).filter((a) => a !== "-q");
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + "\\n");
const data = ${JSON.stringify({ existing, sessions: SESSIONS, renders: RENDERS, objects: OBJECTS })};
const arg = (n) => args[args.indexOf(n) + 1];
const out = (o) => console.log(JSON.stringify(o));
if (args[0] === "d1") {
    const sql = arg("--sql") ?? "";
    if (args.includes("--batch")) out({ result: [{ results: [], success: true }] });
    else if (sql.includes("FROM studio_renders")) out({ result: [{ results: data.renders, success: true }] });
    else if (sql.includes("FROM studio_sessions")) out({ result: [{ results: data.sessions, success: true }] });
    else if (sql.includes("GROUP BY")) out({ result: [{ results: [{ source: "x", kind: "y", n: 1 }], success: true }] });
    else out({ result: [{ results: data.existing, success: true }] });
} else if (args[0] === "r2") {
    // two pages
    if (!args.includes("--cursor")) out({ result: data.objects.slice(0, 2), result_info: { cursor: "c1", is_truncated: true } });
    else out({ result: data.objects.slice(2), result_info: { cursor: null, is_truncated: false } });
} else {
    console.error("unexpected " + args.join(" "));
    process.exit(2);
}
`,
    );
    chmodSync(bin, 0o755);
    const calls = () =>
        readFileSync(log, "utf8")
            .trim()
            .split("\n")
            .filter(Boolean)
            .map((l) => JSON.parse(l) as string[]);
    return { bin, calls };
}

const run = async (argv: string[]) => {
    const lines: string[] = [];
    const orig = console.log;
    const origErr = console.error;
    console.log = (...a: unknown[]) => void lines.push(a.join(" "));
    console.error = () => {};
    try {
        await main(argv);
    } finally {
        console.log = orig;
        console.error = origErr;
    }
    return lines;
};

describe("backfill-library.mjs against a fake cf", () => {
    it("--dry-run prints the plan and writes nothing", async () => {
        const f = fakeCf([{ bucket: "media", r2_key: "Old0000001.webp" }]);
        const lines = await run(["--dry-run", "--cf", f.bin]);
        expect(lines).toHaveLength(4);
        expect(lines.map((l) => l.split(/\s+/)[0])).toEqual(["saved", "studio", "webp", "studio"]);
        // pagination: both R2 pages were read
        expect(f.calls().filter((c) => c[0] === "r2")).toHaveLength(2);
        // no batch (write) call at all
        expect(f.calls().some((c) => c.includes("--batch"))).toBe(false);
    });
    it("without it, inserts only what is missing, as typed batch statements that really insert", async () => {
        const f = fakeCf([{ bucket: "media", r2_key: "Old0000001.webp" }]);
        await run(["--cf", f.bin]);
        const batches = f.calls().filter((c) => c.includes("--batch"));
        expect(batches).toHaveLength(1);
        const statements = JSON.parse(batches[0][batches[0].indexOf("--batch") + 1]) as { sql: string; params: unknown[] }[];
        expect(statements).toHaveLength(4);
        const db = createFakeD1();
        for (const s of statements) await db.prepare(s.sql).bind(...(s.params as any[])).run();
        const rows = db.raw.prepare("SELECT source, kind, bucket, r2_key, width FROM media_items ORDER BY created_at").all();
        expect(rows).toEqual([
            { source: "saved", kind: "private", bucket: "originals", r2_key: "originals/S1aaaaaaaaaaaaaaaaaaaa.mp4", width: 480 },
            { source: "studio", kind: "public", bucket: "media", r2_key: "Render0001.webp", width: 480 },
            { source: "webp", kind: "public", bucket: "media", r2_key: "Plain00001.webp", width: null },
            { source: "studio", kind: "public", bucket: "media", r2_key: "StudioGone.webp", width: null },
        ]);
        // running the same statements again changes nothing
        for (const s of statements) await db.prepare(s.sql).bind(...(s.params as any[])).run();
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_items").get()).toEqual({ n: 4 });
    });
    it("a complete library inserts nothing", async () => {
        const f = fakeCf([
            { bucket: "originals", r2_key: "originals/S1aaaaaaaaaaaaaaaaaaaa.mp4" },
            ...OBJECTS.map((o) => ({ bucket: "media", r2_key: o.key })),
        ]);
        expect(await run(["--cf", f.bin])).toEqual([]);
        expect(f.calls().some((c) => c.includes("--batch"))).toBe(false);
    });
});
