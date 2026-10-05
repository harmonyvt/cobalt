// Custom titles (APP-API-CONTRACT.md section 15, apple/CONTRACT-LIBRARY2.md section 6):
// migration 0007, PATCH /library/items/<id>/post, `custom_title` in GET /library, the
// delete-post cleanup, the copy to a hosted image, and the capability flag. The Worker and the
// real SQL (node:sqlite over every migration) run together; the container is never reached.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it } from "vitest";
import { parseTitle } from "../src/app-routes";
import { SESSION_TTL_MS } from "../src/studio";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { MEDIA_BASE, ORIGIN, SID, auth, svc, world, type World } from "./poster-world";

const T = 1_800_000_000_000;
const L1 = "https://www.instagram.com/reel/Dd7P496wolG/";
const L2 = "https://vimeo.com/123456";
const U = "UploadItem000001"; // 16
const SAVED = "SavedItem0000001";
const HOST = "HostItem00000001";
const R1 = "RenderItem000001";
const UP_RENDER = "RenderOfUpload01";
const REOPEN_SID = "ReopenedSession0000000c"; // 22
const REOPEN_RENDER = "RenderReopened01";
const WEBP1 = "WebpOnlyItem0001";
const WEBP2 = "WebpOnlyItem0002";
const IMG = "ImageUpload00001";

let w: World;
let n = 0;

const item = (over: Record<string, unknown>) => {
    const r: Record<string, unknown> = {
        id: `Item${String(++n).padStart(12, "0")}`,
        kind: "public",
        source: "webp",
        bucket: "media",
        r2_key: `Key${String(n).padStart(7, "0")}.webp`,
        url: null,
        name: "n",
        content_type: "image/webp",
        bytes: 100,
        width: null,
        height: null,
        duration: null,
        link: null,
        session_id: null,
        key_id: null,
        created_at: T,
        deleted_at: null,
        ...over,
    };
    if (r.kind === "public" && r.url === null) r.url = `${MEDIA_BASE}${r.r2_key}`;
    w.db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at)",
        )
        .run(r as any);
    if (r.bucket === "media") w.media.objects.set(r.r2_key as string, { bytes: 3, meta: {}, data: new Uint8Array(3), viaStream: false });
    else w.originals.objects.set(r.r2_key as string, { bytes: new Uint8Array(3), contentType: "video/mp4", meta: {} });
    return r as any;
};
const sess = (over: Record<string, unknown>) => w.seed({ expires_at: T + SESSION_TTL_MS, created_at: T, ...over }, { row: false, object: false });

// Four posts of every kind the contract names.
function seedAll() {
    // A: a saved original (post key = its session id) with a hosted copy and a render
    sess({ id: SID, link: L1, r2_key: `originals/${SID}.mp4` });
    item({ id: SAVED, kind: "private", source: "saved", bucket: "originals", r2_key: `originals/${SID}.mp4`, name: "instagram_Dd7P496wolG", content_type: "video/mp4", link: L1, session_id: SID, created_at: T + 10 });
    item({ id: HOST, source: "host", r2_key: "Klmnopqrst.mp4", name: "instagram_Dd7P496wolG", content_type: "video/mp4", link: L1, session_id: SID, created_at: T + 20 });
    item({ id: R1, source: "studio", r2_key: "Abcdefghij.webp", link: L1, session_id: SID, created_at: T + 30 });
    // B: an upload and a render of its adopted session (post key = the upload's item id)
    item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.mov`, name: "IMG_0412.mov", content_type: "video/quicktime", created_at: T + 40 });
    sess({ id: "BsessionUpload0000000d", link: `upload:${U}`, service: "upload", title: "IMG_0412.mov", r2_key: `uploads/${U}.mov` });
    item({ id: UP_RENDER, source: "studio", r2_key: "Rndr012345.webp", session_id: "BsessionUpload0000000d", created_at: T + 50 });
    // C: webp-only posts keyed by their link (no original)
    item({ id: WEBP1, link: L2, r2_key: "Webp000001.webp", created_at: T + 60 });
    item({ id: WEBP2, link: L2, r2_key: "Webp000002.webp", created_at: T + 70 });
    // D: a saved post that was reopened: its renders stay in the original's post
    sess({ id: "DsavedSession00000000e", link: "https://example.com/d", r2_key: "originals/DsavedSession00000000e.mp4" });
    item({ id: "SavedReopened001", kind: "private", source: "saved", bucket: "originals", r2_key: "originals/DsavedSession00000000e.mp4", content_type: "video/mp4", link: "https://example.com/d", session_id: "DsavedSession00000000e", created_at: T + 80 });
    sess({ id: REOPEN_SID, link: "upload:DsavedSession00000000e", service: "upload" });
    item({ id: REOPEN_RENDER, source: "studio", r2_key: "Rndr0RE001.webp", session_id: REOPEN_SID, created_at: T + 90 });
}

const patch = (id: string, body: unknown, headers: Record<string, string> = auth, raw = false) =>
    w.call(`/library/items/${id}/post`, {
        method: "PATCH",
        headers: { "content-type": "application/json", ...headers },
        body: raw ? (body as string) : JSON.stringify(body),
    });
const titles = () => w.db.raw.prepare("SELECT * FROM media_titles ORDER BY post_key").all() as any[];
const library = async (q = "") => (await (await w.call(`/library${q}`, { headers: auth })).json()) as any;
const customOf = (b: any, id: string) => b.posts.find((p: any) => p.id === id)?.custom_title;

beforeEach(async () => {
    w = world();
    await w.addKey();
    w.clock.t = T + 3_600_000;
    n = 0;
});

describe("migration 0007_titles.sql", () => {
    const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
    const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
    const sql = (name: string) => readFileSync(dir + name, "utf8");

    it("follows 0006 and is one additive CREATE TABLE", () => {
        expect(files[files.indexOf("0007_titles.sql") - 1]).toBe("0006_posters_public.sql");
        const stmts = sql("0007_titles.sql")
            .split("\n")
            .filter((l) => !l.trim().startsWith("--"))
            .map((l) => l.replace(/--.*$/, ""))
            .join("\n")
            .split(";")
            .map((s) => s.trim())
            .filter(Boolean);
        expect(stmts).toHaveLength(1);
        expect(stmts[0]).toMatch(/^CREATE TABLE media_titles \(/);
        expect(stmts[0]).not.toMatch(/\b(DROP|DELETE|UPDATE|RENAME|ALTER)\b/i);
    });

    it("applies on top of 0006 with data in the old tables, leaving every old row as it was", () => {
        const upTo6 = files.filter((f) => f < "0007").map(sql).join("\n");
        const db = createFakeD1(upTo6);
        const r = db.raw;
        r.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES ('k1','a','h','p',1)").run();
        r.prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, created_at) VALUES ('M1','private','saved','originals','originals/S1.mp4',NULL,'t','video/mp4',10,100)",
        ).run();
        const before = r.prepare("SELECT * FROM media_items").all();
        r.exec(sql("0007_titles.sql"));
        expect(r.prepare("SELECT * FROM media_items").all()).toEqual(before);
        expect((r.prepare("SELECT count(*) AS n FROM api_keys").get() as any).n).toBe(1);
        expect((r.prepare("PRAGMA table_info(media_titles)").all() as any[]).map((c) => c.name)).toEqual(["post_key", "title", "key_id", "updated_at"]);
        // the pre-0007 library query still runs on the migrated database
        expect(r.prepare("SELECT COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL").get()).toEqual({ n: 1 });
    });
});

describe("parseTitle (the validation, on its own)", () => {
    const ok = (t: string | null) => parseTitle(JSON.stringify({ title: t }));
    it("trims, clears on null and empty, counts code points", () => {
        expect(ok("  Beach day \n")).toEqual({ ok: true, title: "Beach day" });
        expect(ok(null)).toEqual({ ok: true, title: null });
        expect(ok("   ")).toEqual({ ok: true, title: null });
        expect(ok("a".repeat(80))).toEqual({ ok: true, title: "a".repeat(80) });
        expect(ok("a".repeat(81))).toEqual({ ok: false });
        // 80 emoji = 160 UTF-16 units but 80 code points
        expect(ok("\u{1F600}".repeat(80))).toEqual({ ok: true, title: "\u{1F600}".repeat(80) });
        expect(ok("\u{1F600}".repeat(81))).toEqual({ ok: false });
    });
    it("rejects every control character inside, and unpaired surrogates", () => {
        for (const c of ["\n", "\r", "\t", "\u0000", "\u0007", "\u001F", "\u007F", "\u0085", "\u009F", " ", " "]) {
            expect(ok(`a${c}b`), JSON.stringify(c)).toEqual({ ok: false });
        }
        expect(parseTitle('{"title":"a\\ud800b"}')).toEqual({ ok: false });
        // a control character at the very end that trim() does not take off
        expect(ok("ab\u0007")).toEqual({ ok: false });
        // characters that are not controls pass: nbsp inside, combining marks, a ZWJ sequence
        expect(ok("a b")).toEqual({ ok: true, title: "a b" });
        expect(ok("é \u{1F468}‍\u{1F469}")).toMatchObject({ ok: true });
    });
    it("rejects the wrong shapes", () => {
        for (const raw of ["", "nope", "{", "[]", "null", "7", '"x"', "{}", '{"name":"x"}', '{"title":7}', '{"title":true}', '{"title":["x"]}', '{"title":{}}']) {
            expect(parseTitle(raw), raw).toEqual({ ok: false });
        }
        expect(parseTitle(null)).toEqual({ ok: false });
        // an extra key does not matter
        expect(parseTitle('{"title":"x","other":1}')).toEqual({ ok: true, title: "x" });
    });
});

describe("PATCH /library/items/<id>/post", () => {
    it("sets a title on the post of any of its files: the answer names the post key, and the row records the key and the time", async () => {
        seedAll();
        const res = await patch(HOST, { title: "Trip to Kyoto" });
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("content-type")).toBe("application/json");
        expect(await res.json()).toEqual({ status: "success", post: SID, title: "Trip to Kyoto" });
        expect(titles()).toEqual([{ post_key: SID, title: "Trip to Kyoto", key_id: "key-row-1", updated_at: w.clock.t }]);
        expect(w.seen).toHaveLength(0); // never the container nor a Durable Object
    });

    it("the anchor can be any file of any kind of post: all resolve to the one post key", async () => {
        seedAll();
        const cases: [string[], string][] = [
            [[SAVED, HOST, R1], SID], // saved original, hosted copy, render
            [[U, UP_RENDER], U], // upload and a render of its adopted session
            [[WEBP1, WEBP2], L2], // webp-only post, keyed by its link
            [["SavedReopened001", REOPEN_RENDER], "DsavedSession00000000e"], // reopened saved session
        ];
        for (const [ids, post] of cases) {
            for (const id of ids) {
                const res = await patch(id, { title: `t ${id}` });
                expect(res.status, id).toBe(200);
                expect(((await res.json()) as any).post, id).toBe(post);
            }
        }
        expect(titles().map((t) => t.post_key).sort()).toEqual([SID, U, L2, "DsavedSession00000000e"].sort());
    });

    it("replaces: one row per post, the last write wins", async () => {
        seedAll();
        await patch(R1, { title: "first" });
        w.clock.t += 5;
        await patch(SAVED, { title: "second" });
        expect(titles()).toEqual([{ post_key: SID, title: "second", key_id: "key-row-1", updated_at: w.clock.t }]);
    });

    it("clears with null and with whitespace only; clearing nothing is still a 200 (idempotent)", async () => {
        seedAll();
        await patch(SAVED, { title: "keep me?" });
        const a = await patch(SAVED, { title: null });
        expect(a.status).toBe(200);
        expect(await a.json()).toEqual({ status: "success", post: SID, title: null });
        expect(titles()).toEqual([]);
        await patch(SAVED, { title: "again" });
        const b = await patch(SAVED, { title: "  \n " });
        expect(b.status).toBe(200);
        expect(((await b.json()) as any).title).toBeNull();
        expect(titles()).toEqual([]);
        const c = await patch(SAVED, { title: null }); // nothing to clear
        expect(c.status).toBe(200);
        expect(((await c.json()) as any).title).toBeNull();
    });

    it("setting the same title twice gives the same answer", async () => {
        seedAll();
        const a = await (await patch(SAVED, { title: "same" })).json();
        const b = await (await patch(SAVED, { title: "same" })).json();
        expect(b).toEqual(a);
        expect(titles()).toHaveLength(1);
    });

    it("trims leading and trailing spaces and line breaks", async () => {
        seedAll();
        const res = await patch(SAVED, { title: " \n  Beach day \t\n" });
        expect(res.status).toBe(200);
        expect(((await res.json()) as any).title).toBe("Beach day");
        expect(titles()[0].title).toBe("Beach day");
    });

    it("exactly 80 code points is stored (an emoji counts as one); 81 is a 400 and nothing changes", async () => {
        seedAll();
        const eighty = "\u{1F600}".repeat(79) + "x";
        expect((await patch(SAVED, { title: eighty })).status).toBe(200);
        expect(titles()[0].title).toBe(eighty);
        const bad = await patch(SAVED, { title: eighty + "y" });
        expect(bad.status).toBe(400);
        expect(await bad.json()).toEqual({ status: "error", error: { code: "error.library.bad_title" } });
        expect(titles()[0].title).toBe(eighty);
        expect((await patch(SAVED, { title: "a".repeat(81) })).status).toBe(400);
    });

    it("a control character inside is a 400 (a line break inside, a bell, a DEL)", async () => {
        seedAll();
        for (const t of ["two\nlines", "bell\u0007", "del\u007F", "next\u0085line", "sep x"]) {
            const res = await patch(SAVED, { title: t });
            expect(res.status, JSON.stringify(t)).toBe(400);
            expect(((await res.json()) as any).error.code).toBe("error.library.bad_title");
        }
        expect(titles()).toEqual([]);
    });

    it("bad JSON, a number, a missing key, an array and a body over 1024 bytes are 400 error.library.bad_title; nothing is stored", async () => {
        seedAll();
        const bodies: [string, string][] = [
            ["bad json", "{nope"],
            ["empty", ""],
            ["a number", "7"],
            ["a string", '"x"'],
            ["an array", '["x"]'],
            ["a missing key", '{"name":"x"}'],
            ["a number title", '{"title":7}'],
            ["a boolean title", '{"title":false}'],
            ["too large", JSON.stringify({ title: "x", pad: "p".repeat(1100) })],
        ];
        for (const [name, raw] of bodies) {
            const res = await patch(SAVED, raw, auth, true);
            expect(res.status, name).toBe(400);
            expect(((await res.json()) as any).error.code, name).toBe("error.library.bad_title");
        }
        expect(titles()).toEqual([]);
        // not UTF-8
        const res = await w.call(`/library/items/${SAVED}/post`, {
            method: "PATCH",
            headers: { ...auth, "content-type": "application/json" },
            body: new Uint8Array([0x7b, 0x22, 0x74, 0x22, 0x3a, 0xff, 0x7d]) as unknown as BodyInit,
        });
        expect(res.status).toBe(400);
    });

    it("a body of exactly 1024 bytes is read; 1025 is refused (the cap is on the body, with or without a content-length)", async () => {
        seedAll();
        const head = '{"title":"x","p":"';
        const fit = head + "p".repeat(1024 - head.length - 2) + '"}';
        expect(new TextEncoder().encode(fit).length).toBe(1024);
        expect((await patch(SAVED, fit, auth, true)).status).toBe(200);
        expect((await patch(SAVED, fit + " ", auth, true)).status).toBe(400);
        // a streamed body with no content-length is capped as it is read
        const stream = new ReadableStream<Uint8Array>({
            pull(c) {
                c.enqueue(new Uint8Array(512).fill(0x20));
            },
        });
        const res = await w.call(`/library/items/${SAVED}/post`, {
            method: "PATCH",
            headers: auth,
            body: stream,
            duplex: "half",
        } as RequestInit);
        expect(res.status).toBe(400);
    });

    it("404 error.library.not_found for an unknown id and for a soft-deleted anchor; a live file of the same post still works", async () => {
        seedAll();
        const unknown = await patch("DoesNotExist0001", { title: "x" });
        expect(unknown.status).toBe(404);
        expect(await unknown.json()).toEqual({ status: "error", error: { code: "error.library.not_found" } });
        w.db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(T, R1);
        expect((await patch(R1, { title: "x" })).status).toBe(404);
        expect((await patch(SAVED, { title: "x" })).status).toBe(200);
        expect(titles()).toHaveLength(1);
    });

    it("a bad body is judged before the lookup, so it is a 400 even for an unknown id", async () => {
        seedAll();
        expect((await patch("DoesNotExist0001", { title: 7 })).status).toBe(400);
    });

    it("D1 failing is a 503 error.api.generic and nothing is stored", async () => {
        seedAll();
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/media_titles/.test(sql)) throw new Error("D1_ERROR: down");
            return orig(sql);
        };
        const res = await patch(SAVED, { title: "x" });
        expect(res.status).toBe(503);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
        (w.db as any).prepare = orig;
        expect(titles()).toEqual([]);
    });

    describe("auth and routing", () => {
        it("no key is 401, a wrong key is 401, nothing stored", async () => {
            seedAll();
            const none = await patch(SAVED, { title: "x" }, {});
            expect(none.status).toBe(401);
            expect(((await none.json()) as any).error.code).toBe("error.api.auth.key.missing");
            const bad = await patch(SAVED, { title: "x" }, { authorization: `Api-Key ${"1".repeat(8)}-1111-4111-8111-111111111111` });
            expect(bad.status).toBe(401);
            expect(titles()).toEqual([]);
        });
        it("the web Worker's service header works as a key, and the row says service:library", async () => {
            seedAll();
            expect((await patch(SAVED, { title: "from the web" }, svc)).status).toBe(200);
            expect(titles()[0]).toMatchObject({ post_key: SID, key_id: "service:library" });
        });
        it("a 15 or 17 character id is 404; GET, POST, PUT and HEAD on .../post are still 404", async () => {
            seedAll();
            for (const id of [SAVED.slice(0, 15), SAVED + "x"]) expect((await patch(id, { title: "x" })).status, id).toBe(404);
            for (const method of ["GET", "POST", "PUT", "HEAD"]) {
                const res = await w.call(`/library/items/${SAVED}/post`, { method, headers: auth });
                expect(res.status, method).toBe(404);
            }
            expect(titles()).toEqual([]);
        });
        it("a browser Origin gets no CORS header: the web page does not call this route", async () => {
            seedAll();
            const res = await patch(SAVED, { title: "x" }, { ...auth, origin: ORIGIN });
            expect(res.status).toBe(200);
            expect(res.headers.get("access-control-allow-origin")).toBeNull();
        });
    });
});

describe("GET /library: custom_title", () => {
    it("is on the right post and null everywhere else; `title` (the file name) is unchanged", async () => {
        seedAll();
        const before = await library();
        expect(before.posts).toHaveLength(4);
        for (const p of before.posts) expect(p.custom_title, p.id).toBeNull();
        await patch(UP_RENDER, { title: "Kyoto, day 2" });
        const after = await library();
        expect(customOf(after, U)).toBe("Kyoto, day 2");
        for (const p of after.posts) if (p.id !== U) expect(p.custom_title, p.id).toBeNull();
        expect(after.posts.find((p: any) => p.id === U).title).toBe("IMG_0412.mov");
        expect(after.posts.find((p: any) => p.id === SID).title).toBe("instagram_Dd7P496wolG");
        // the rest of the post's shape is as it was
        expect(Object.keys(after.posts[0]).sort()).toEqual(
            ["created_at", "custom_title", "duration", "files", "height", "id", "link", "poster_url", "public_url", "service", "session", "title", "width"].sort(),
        );
    });

    it("every post of a page gets its own title (webp-only post keyed by link included), and a cleared one goes back to null", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        await patch(U, { title: "B" });
        await patch(WEBP2, { title: "C" });
        await patch(REOPEN_RENDER, { title: "D" });
        const b = await library();
        expect([customOf(b, SID), customOf(b, U), customOf(b, L2), customOf(b, "DsavedSession00000000e")]).toEqual(["A", "B", "C", "D"]);
        await patch(U, { title: null });
        expect(customOf(await library(), U)).toBeNull();
    });

    it("pages: a post on page 2 carries its title; one query for the page, not one per post", async () => {
        seedAll();
        await patch(WEBP1, { title: "oldest-ish" });
        await patch(R1, { title: "newer" });
        const p1 = await library("?limit=2");
        expect(p1.posts).toHaveLength(2);
        const p2 = await library(`?limit=2&cursor=${p1.next}`);
        expect(p2.next).toBeNull();
        const all = [...p1.posts, ...p2.posts];
        expect(all.find((p: any) => p.id === L2).custom_title).toBe("oldest-ish");
        expect(all.find((p: any) => p.id === SID).custom_title).toBe("newer");
        const queries: string[] = [];
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/media_titles/.test(sql)) queries.push(sql);
            return orig(sql);
        };
        await library();
        (w.db as any).prepare = orig;
        expect(queries).toHaveLength(1);
    });

    it("a title row of a post with no live file shows nowhere", async () => {
        seedAll();
        w.db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('ghost', 'orphan', NULL, 1)").run();
        const b = await library();
        expect(b.posts.map((p: any) => p.id)).not.toContain("ghost");
        expect(b.posts.every((p: any) => p.custom_title === null)).toBe(true);
    });

    it("D1 failing on the titles query is a 503, never a list with the titles silently missing", async () => {
        seedAll();
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/FROM media_titles/.test(sql)) throw new Error("D1_ERROR: down");
            return orig(sql);
        };
        const res = await w.call("/library", { headers: auth });
        (w.db as any).prepare = orig;
        expect(res.status).toBe(503);
    });
});

describe("DELETE /library/items/<id>/post removes the title", () => {
    it("the post's row goes with it; other posts' titles stay", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        await patch(U, { title: "B" });
        const res = await w.call(`/library/items/${HOST}/post`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(titles().map((t) => [t.post_key, t.title])).toEqual([[U, "B"]]);
    });

    it("a second delete (already gone) is still a 200 and leaves other titles alone", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        await patch(U, { title: "B" });
        await w.call(`/library/items/${SAVED}/post`, { method: "DELETE", headers: auth });
        const again = await w.call(`/library/items/${SAVED}/post`, { method: "DELETE", headers: auth });
        expect(again.status).toBe(200);
        expect(titles().map((t) => t.post_key)).toEqual([U]);
    });

    it("a partial delete (one object will not go) keeps the title until the retry finishes the post", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        const orig = w.media.delete.bind(w.media);
        (w.media as any).delete = async (k: string) => {
            if (k === "Abcdefghij.webp") throw new Error("R2 down");
            return orig(k);
        };
        const part = await w.call(`/library/items/${SAVED}/post`, { method: "DELETE", headers: auth });
        expect(part.status).toBe(502);
        expect(titles()).toHaveLength(1);
        (w.media as any).delete = orig;
        const retry = await w.call(`/library/items/${SAVED}/post`, { method: "DELETE", headers: auth });
        expect(retry.status).toBe(200);
        expect(titles()).toEqual([]);
    });

    it("a failing title delete is logged, not reported: the post delete is still a 200", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/DELETE FROM media_titles/.test(sql)) throw new Error("D1_ERROR: down");
            return orig(sql);
        };
        const res = await w.call(`/library/items/${SAVED}/post`, { method: "DELETE", headers: auth });
        (w.db as any).prepare = orig;
        expect(res.status).toBe(200);
    });

    it("deleting a single webp (DELETE /media/<name>) leaves the post's title", async () => {
        seedAll();
        await patch(SAVED, { title: "A" });
        const res = await w.call("/media/Abcdefghij.webp", { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(titles()).toHaveLength(1);
        expect(customOf(await library(), SID)).toBe("A");
    });
});

describe("POST /library/items/<id>/publish copies the title to a hosted image", () => {
    const upload = async (type: string, name: string) => {
        const res = await w.call(`/studio/upload?name=${encodeURIComponent(name)}`, {
            method: "PUT",
            headers: { ...auth, "content-type": type, "content-length": "300" },
            body: new Uint8Array(300).fill(4) as unknown as BodyInit,
        });
        expect(res.status).toBe(201);
        return ((await res.json()) as any).item.id as string;
    };
    const publish = async (id: string) => {
        const res = await w.call(`/library/items/${id}/publish`, { method: "POST", headers: auth });
        expect(res.status).toBe(201);
        return (await res.json()) as any;
    };

    it("an image upload's title stays with it when hosted: one row, one post (section 16), nothing to copy", async () => {
        const id = await upload("image/png", "photo.png");
        await patch(id, { title: "Sunset" });
        const hosted = await publish(id);
        const rows = titles();
        expect(rows.map((r) => [r.post_key, r.title])).toEqual([[id, "Sunset"]]);
        expect(hosted.item_id).not.toBe(id); // the public id old apps know, resolved by every item route
        const lib = await library();
        expect(lib.posts).toHaveLength(1);
        expect(lib.posts[0].custom_title).toBe("Sunset");
    });

    it("hosting an image twice is the same link; a title set afterwards is on the one post", async () => {
        const id = await upload("image/jpeg", "a.jpg");
        const h1 = await publish(id);
        expect(titles()).toEqual([]);
        await patch(id, { title: "late" });
        expect(titles().map((t) => t.post_key)).toEqual([id]);
        const h2 = await publish(id);
        expect(h2.url).toBe(h1.url);
        expect(h2.item_id).toBe(h1.item_id);
        await patch(h1.item_id, { title: "mine" }); // the public id resolves like the item id
        expect(titles().map((t) => [t.post_key, t.title])).toEqual([[id, "mine"]]);
    });

    it("a video's host copy stays in the source post: one row, nothing added", async () => {
        seedAll();
        await patch(SAVED, { title: "Clip" });
        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(30).fill(7), contentType: "video/mp4", meta: {} });
        const res = await w.call(`/library/items/${SAVED}/publish`, { method: "POST", headers: auth });
        expect(res.status).toBe(201);
        expect(titles()).toEqual([expect.objectContaining({ post_key: SID, title: "Clip" })]);
    });
});

describe("GET /capabilities", () => {
    it("features.titles is true, from the server, with or without a key; nothing else was lost", async () => {
        for (const headers of [{}, auth]) {
            const res = await w.call("/capabilities", { headers });
            const b = (await res.json()) as any;
            expect(b.features.titles).toBe(true);
            expect(b.features).toMatchObject({ delete_post: true, poster: true, public_default: true, create_notify: true });
        }
    });
});
