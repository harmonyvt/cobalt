// The MCP app's tools (MCP-APP-CONTRACT.md section 4) against the real SQL on node:sqlite. The read ops (library.list,
// library.post, links.list, collections.list) are the real chat toolbox over the seeded database; the ops that need a
// container or a Durable Object (webp, save, upload, edits, links.create) answer recorded, realistic bodies.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { chatTools } from "../src/chat-tools";
import type { OpContext } from "../src/registry/op";
import { OpError } from "../src/registry/op";
import { CollectionsOut, EditOut, JobOut, LinksOut, PostOut, SaveOut, SearchOut, UploadOut, WebpOut } from "../src/mcp-app/shapes";
import { APP_TOOLS } from "../src/mcp-app/tools";
import type { AppTool, AppToolCtx, AppToolResult } from "../src/mcp-app/types";
import { withBatch } from "./d1-batch";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const T0 = 1_760_000_000_000;

let db: FakeD1;
let batches: number;
let singles: number;
let inOp = false;
let inBatch = false;

const tool = (name: string) => APP_TOOLS.find((t) => t.name === name)! as AppTool;

// ---- seeding -------------------------------------------------------------------------------------------------------

let n = 0;
type Seed = Partial<{
    id: string;
    name: string;
    content_type: string;
    visibility: "public" | "private";
    duration: number | null;
    poster: string | null;
    link: string | null;
    post_key: string;
    role: string | null;
    item_index: number | null;
    created_at: number;
}>;
// a library file; public ones live in the media bucket under a 12-character name
function file(o: Seed = {}) {
    n += 1;
    const id = o.id ?? `File${String(n).padStart(12, "0")}`;
    const pub = (o.visibility ?? "public") === "public";
    const type = o.content_type ?? "video/mp4";
    const ext = type === "video/mp4" ? "mp4" : type === "image/webp" ? "webp" : "jpg";
    const key = `Nm${String(n).padStart(10, "0")}`;
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, poster, visibility, post_key, role, item_index)
             VALUES (?, ?, 'saved', ?, ?, ?, ?, ?, 1000, 720, 1280, ?, ?, 'k', ?, ?, ?, ?, ?, ?)`,
        )
        .run(
            id,
            pub ? "public" : "private",
            pub ? "media" : "originals",
            pub ? `${key}.${ext}` : `originals/${id}.${ext}`,
            pub ? `${MEDIA}${key}.${ext}` : null,
            o.name ?? `${id}.${ext}`,
            type,
            o.duration === undefined ? (type.startsWith("video/") ? 9.6 : null) : o.duration,
            o.link === undefined ? "https://www.tiktok.com/@a/video/1" : o.link,
            o.created_at ?? T0 + n * 1000,
            o.poster === undefined ? (type.startsWith("video/") ? `${MEDIA}Poster${String(n).padStart(6, "0")}.jpg` : null) : o.poster,
            pub ? "public" : "private",
            o.post_key ?? id,
            o.role ?? null,
            o.item_index ?? null,
        );
    return { id, url: pub ? `${MEDIA}${key}.${ext}` : null, name: key };
}
const title = (postKey: string, text: string) => db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, 'k', ?)").run(postKey, text, T0);
const hide = (postKey: string) => db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'hidden', 'you', NULL, ?)").run(postKey, T0);
const privateLink = (itemId: string) =>
    db.raw
        .prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at, opened, last_opened_at) VALUES (?, 'item', ?, ?, NULL, 0, NULL)")
        .run(`Pk${itemId}`.padEnd(22, "0").slice(0, 22), itemId, T0);
const set = (id: string, items: string[], over: { title?: string | null; revoked?: boolean; private?: boolean } = {}) => {
    db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, ?, 'k', ?, ?)").run(id, JSON.stringify(items), over.title ?? null, T0 + 5, over.revoked ? T0 : null);
    if (over.private)
        db.raw.prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at, opened, last_opened_at) VALUES (?, 'set', ?, ?, NULL, 0, NULL)").run(`PrivateSetKey${id}`.padEnd(22, "0").slice(0, 22), id, T0);
};
const collection = (id: string, name: string, setIds: string[]) => {
    db.raw.prepare("INSERT INTO share_collections (id, name, key_id, created_at, updated_at) VALUES (?, ?, 'k', ?, ?)").run(id, name, T0, T0);
    setIds.forEach((s, i) => db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?, ?, ?)").run(id, s, T0 + (setIds.length - i)));
};

// ---- the context ----------------------------------------------------------------------------------------------------

type Answer = unknown | ((input: any) => unknown | Promise<unknown>);
let answers: Record<string, Answer>;
let calls: { name: string; input: any }[];
let offered: Set<string> | null;
let container: { fetch: (req: Request) => Promise<Response> };

const realOps = (): Record<string, (input: any) => Promise<unknown>> => {
    const t = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, embed: null }, { look: [], show: [], collage: null } as never);
    return {
        "library.list": (i) => t.library!(i),
        "library.post": (i) => t.post!(i.id),
        "links.list": () => t.links!(),
        "collections.list": () => t.collections!(),
    };
};

function context(): AppToolCtx {
    const real = realOps();
    const op = { db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, now: () => T0, container, edge: { now: () => T0, sleep: async () => {} } } as unknown as OpContext;
    const ctx: AppToolCtx = {
        op,
        flags: { search: false, mcp: true },
        origin: "https://api.capybaraharmony.com",
        has: (name) => (offered ? offered.has(name) : name !== "library.search"),
        async call(name, input) {
            calls.push({ name, input });
            const a = answers[name];
            if (a !== undefined) return typeof a === "function" ? (a as (i: unknown) => unknown)(input) : a;
            if (real[name]) {
                inOp = true;
                try {
                    return await real[name]!(input);
                } finally {
                    inOp = false;
                }
            }
            throw new OpError(404, "error.test.no_op", `no answer for ${name}`);
        },
    };
    return ctx;
}

// parse like the core does, run, and check the structured answer against the tool's own output schema
async function run(name: string, input: unknown = {}): Promise<AppToolResult & { out: any }> {
    const t = tool(name);
    const r = await t.run(context(), t.input.parse(input));
    const out = t.output.parse(r.structured);
    return { ...r, out };
}

beforeEach(() => {
    n = 0;
    db = withBatch(createFakeD1());
    batches = 0;
    singles = 0;
    inOp = false;
    const batch = (db as any).batch.bind(db);
    (db as any).batch = async (...a: unknown[]) => {
        if (!inOp) batches++;
        inBatch = true;
        try {
            return await batch(...a);
        } finally {
            inBatch = false;
        }
    };
    const prepare = (db as any).prepare.bind(db);
    (db as any).prepare = (sql: string) => {
        const st = prepare(sql);
        for (const m of ["all", "first", "run"] as const) {
            const orig = st[m].bind(st);
            st[m] = (...a: unknown[]) => {
                if (!inOp && !inBatch) singles++;
                return orig(...a);
            };
        }
        const bind = st.bind.bind(st);
        st.bind = (...p: unknown[]) => {
            const b = bind(...p);
            for (const m of ["all", "first", "run"] as const) {
                const orig = b[m].bind(b);
                b[m] = (...a: unknown[]) => {
                    if (!inOp && !inBatch) singles++;
                    return orig(...a);
                };
            }
            return b;
        };
        return st;
    };
    answers = {};
    calls = [];
    offered = null;
    container = {
        async fetch() {
            return Response.json({ status: "saving" });
        },
    };
});

it("the registry has the ten tools of the contract, with the right kinds and views", () => {
    expect(APP_TOOLS.map((t) => [t.name, t.readOnly, t.view, t.appOnly ?? false])).toEqual([
        ["search_library", true, "search", false],
        ["show_post", true, "post", false],
        ["show_edit", true, "edit", false],
        ["list_collections", true, "collections", false],
        ["list_share_links", true, "links", false],
        ["convert_to_webp", false, "webp", false],
        ["upload_files", false, "upload", false],
        ["create_share_link", false, "links", false],
        ["save_link", false, "save", false],
        ["job_status", false, null, false],
    ]);
    for (const t of APP_TOOLS) {
        expect(t.name).toMatch(/^[a-z_]+$/);
        expect(t.title.length).toBeGreaterThan(3);
        expect(t.description.length).toBeGreaterThan(20);
    }
});

it("every tool declares what it does not do: no destructive writes, only save_link reaches the open web", () => {
    const hints = Object.fromEntries(APP_TOOLS.map((t) => [t.name, t.annotations ?? null]));
    for (const name of ["search_library", "show_post", "show_edit", "list_collections", "list_share_links"]) expect(hints[name], name).toEqual({ openWorldHint: false });
    for (const name of ["convert_to_webp", "upload_files", "create_share_link", "job_status"]) expect(hints[name], name).toEqual({ destructiveHint: false, openWorldHint: false });
    expect(hints.save_link).toEqual({ destructiveHint: false, openWorldHint: true });
    // job_status is an ordinary tool the model may call: the texts of the job tools tell it to
    expect(tool("job_status").appOnly).toBeFalsy();
    expect(tool("job_status").description).toMatch(/convert_to_webp|save_link/);
});

// ---- search_library ---------------------------------------------------------------------------------------------------------

describe("search_library", () => {
    it("meaning search: public posts get their poster, private and off ones none, hidden ones never show", async () => {
        const pub = file({ name: "cat.mp4" });
        const priv = file({ visibility: "private", name: "secret.mp4" });
        const off = file({ visibility: "private", name: "off.mp4" });
        const gone = file({ name: "hidden.mp4" });
        privateLink(priv.id);
        hide(gone.id);
        title(pub.id, "A cat falls off a shelf");
        offered = new Set(["library.search", "library.list"]);
        const rec = (id: string, t: string, public_: boolean) => ({ id, title: t, saved_at: "2025-10-09T00:00:00.000Z", source: "tiktok.com", link: null, kind: "video", files: 1, duration: 9.6, public: public_, caption: null, score: 0.5, why: [] });
        answers["library.search"] = [rec(pub.id, "A cat falls off a shelf", true), rec(priv.id, "secret", false), rec(off.id, "off", false), rec(gone.id, "hidden", true)];
        const r = await run("search_library", { query: "cat" });
        SearchOut.parse(r.out);
        expect(r.out.mode).toBe("meaning");
        expect(r.out.items.map((i: any) => [i.id, i.status, i.thumb_url])).toEqual([
            [pub.id, "public", expect.stringMatching(/^https:\/\/media\.capybaraharmony\.com\/Poster/)],
            [priv.id, "private", null],
            [off.id, "off", null],
        ]);
        expect(r.out.items[0]).toMatchObject({ title: "A cat falls off a shelf", kind: "video", duration_s: 9.6, source_host: "tiktok.com", files: 1 });
        // one D1 batch for the whole answer, nothing one by one
        expect(batches).toBe(1);
        expect(singles).toBe(0);
        const lines = r.text.split("\n");
        expect(lines[0]).toMatch(/^3 posts for “cat” \(searched by meaning\)/);
        // one line per row: title, kind and length, id, day saved, where from, share page (or its state), score
        expect(lines[1]).toBe(`1. A cat falls off a shelf · video 0:10 · ${pub.id} · 2025-10-09 · tiktok.com · ${SHARE}${pub.name} · score 0.5`);
        expect(lines[2]).toBe(`2. secret · video 0:10 · ${priv.id} · 2025-10-09 · tiktok.com · private · score 0.5`);
        expect(lines[3]).toBe(`3. off · video 0:10 · ${off.id} · 2025-10-09 · tiktok.com · not shared · score 0.5`);
        expect(r.text).not.toContain("hidden");
        expect(r.text).not.toMatch(/media\.capybaraharmony\.com/);
        expect(r.text).not.toMatch(/[{}\[\]]/);
    });

    it("the total counts what can be shown: a hidden post beyond the slice is not counted, and a hidden one in it does not take a place", async () => {
        const a = file({ name: "cat a.mp4", created_at: T0 + 3000 });
        const b = file({ name: "cat b.mp4", created_at: T0 + 2000 });
        const c = file({ name: "cat c.mp4", created_at: T0 + 1000 });
        hide(a.id);
        hide(c.id);
        const r = await run("search_library", { query: "cat", limit: 1 });
        expect(r.out.total).toBe(1);
        expect(r.out.items.map((p: any) => p.id)).toEqual([b.id]);
        expect(r.text).toMatch(/^1 post for/);
        expect(r.text).not.toContain("showing");
    });

    it("every post carries the lead file's size", async () => {
        const v = file({ name: "cat sized.mp4" });
        db.raw.prepare("UPDATE media_items SET bytes = 4321 WHERE id = ?").run(v.id);
        expect((await run("search_library", { query: "cat" })).out.items[0].bytes).toBe(4321);
        expect((await run("show_post", { id: v.id })).out.post.bytes).toBe(4321);
    });

    it("falls back to the title match (mode text) while meaning search is off, with the kind and date filters", async () => {
        const a = file({ name: "dog park.mp4", created_at: T0 + 1000 });
        file({ name: "dog photo.jpg", content_type: "image/jpeg", created_at: T0 + 2000 });
        file({ name: "dog old.mp4", created_at: T0 - 90 * 86_400_000 });
        file({ name: "bird.mp4" });
        const r = await run("search_library", { query: "dog", kind: "video", since: new Date(T0 - 86_400_000).toISOString() });
        expect(r.out.mode).toBe("text");
        expect(r.out.items.map((i: any) => i.id)).toEqual([a.id]);
        expect(calls.map((c) => c.name)).toEqual(["library.list"]);
        expect(calls[0]!.input).toMatchObject({ query: "dog", kind: "video" });
        expect(r.text).toContain("searched by title");
    });

    it("a search that throws (the model is waking up) falls back to the title match", async () => {
        const a = file({ name: "dog.mp4" });
        offered = new Set(["library.search", "library.list"]);
        answers["library.search"] = () => {
            throw new Error("search is waking up, try again in a minute");
        };
        const r = await run("search_library", { query: "dog" });
        expect(r.out.mode).toBe("text");
        expect(r.out.items.map((i: any) => i.id)).toEqual([a.id]);
    });

    it("limit defaults to 12 and goes up to 1000; the text lists every row asked for; an empty result still answers", async () => {
        for (let i = 0; i < 30; i++) file({ name: `clip ${i}.mp4` });
        const r = await run("search_library", { query: "clip" });
        expect(r.out.items).toHaveLength(12);
        expect(r.out.total).toBeGreaterThanOrEqual(12);
        // the text lists the rows asked for (12), not 10, and says how many more there are
        expect(r.text.split("\n").filter((l) => /^\d+\. /.test(l))).toHaveLength(12);
        expect(r.text).toMatch(/the first 12; there may be more: raise limit/);
        const many = await run("search_library", { query: "clip", limit: 30 });
        expect(many.out.items).toHaveLength(30);
        expect(many.text.split("\n").filter((l) => /^\d+\. /.test(l))).toHaveLength(30);
        expect(tool("search_library").input.safeParse({ query: "x", limit: 1000 }).success).toBe(true);
        // above 1000 is cut to 1000, as the older tools did
        expect(tool("search_library").input.parse({ query: "x", limit: 5000 }).limit).toBe(1000);
        expect(tool("search_library").input.safeParse({ query: "" }).success).toBe(false);
        expect(tool("search_library").input.safeParse({ query: "x", since: "not a date" }).success).toBe(false);
        const none = await run("search_library", { query: "zebra" });
        expect(none.out).toMatchObject({ total: 0, items: [] });
        expect(none.text).toMatch(/^No posts found for “zebra”/);
    });

    it("a database without the hidden and private-link tables (migrations 0024, 0025 not applied) still answers", async () => {
        const a = file({ name: "cat.mp4" });
        db.raw.exec("DROP TABLE media_hidden; DROP TABLE private_links;");
        const r = await run("search_library", { query: "cat" });
        expect(r.out.items.map((i: any) => [i.id, i.status])).toEqual([[a.id, "public"]]);
    });

    it("a gallery's thumbnail is its first public picture, and a picture post shows itself", async () => {
        const g1 = file({ id: "GalItemOne00001", content_type: "image/jpeg", post_key: "GalleryPost0001", role: "item", item_index: 0, name: "a.jpg" });
        file({ id: "GalItemTwo00002", content_type: "image/jpeg", post_key: "GalleryPost0001", role: "item", item_index: 1, name: "b.jpg" });
        title("GalleryPost0001", "Trip");
        const pic = file({ content_type: "image/jpeg", name: "sunset.jpg" });
        const r = await run("search_library", { query: "Trip" });
        expect(r.out.items[0]).toMatchObject({ id: "GalleryPost0001", kind: "gallery", files: 2, thumb_url: g1.url });
        const s = await run("search_library", { query: "sunset" });
        expect(s.out.items[0]).toMatchObject({ id: pic.id, kind: "image", thumb_url: pic.url });
    });
});

// ---- show_post ------------------------------------------------------------------------------------------------------------------

describe("show_post", () => {
    it("a public video: files, share link, caption and the start of what is said", async () => {
        const v = file({ name: "tiktok.mp4", link: "https://www.tiktok.com/@a/video/1" });
        title(v.id, "The big jump");
        db.raw.prepare("INSERT INTO media_captions (subject, title, description, model, created_at) VALUES (?, ?, NULL, 'm', ?)").run(`item:${v.id}`, "Roasted title", T0);
        answers["library.transcript"] = { post_key: v.id, state: "done", language: "en", model: "m", updated_at: 1, lines: [{ start: 0, end: 2, text: "hello there" }, { start: 2, end: 4, text: "watch this" }] };
        offered = new Set(["library.post", "library.transcript"]);
        const r = await run("show_post", { id: v.id });
        PostOut.parse(r.out);
        expect(r.out.post).toMatchObject({
            id: v.id,
            title: "The big jump",
            kind: "video",
            status: "public",
            source_link: "https://www.tiktok.com/@a/video/1",
            caption: "Roasted title",
            transcript_excerpt: "hello there watch this",
            share_url: `${SHARE}${v.name}`,
            private_url: null,
        });
        expect(r.out.post.file_list).toEqual([expect.objectContaining({ id: v.id, kind: "video", content_type: "video/mp4", url: v.url, width: 720, height: 1280, duration_s: 9.6, bytes: 1000 })]);
        expect(r.text).toContain("The big jump · " + v.id);
        expect(r.text).toContain(`Share link: ${SHARE}${v.name}`);
        expect(r.text).toContain("Says: hello there watch this");
        expect(calls.find((c) => c.name === "library.transcript")!.input).toMatchObject({ key: v.id });
    });

    it("a private post has no picture and no public url; its private link is the one to give", async () => {
        const v = file({ visibility: "private", name: "mine.mp4" });
        privateLink(v.id);
        const r = await run("show_post", { id: v.id });
        expect(r.out.post).toMatchObject({ status: "private", thumb_url: null, share_url: null, transcript_excerpt: null });
        expect(r.out.post.private_url).toMatch(/^https:\/\/share\.capybaraharmony\.com\/p\//);
        expect(r.out.post.file_list[0].url).toBeNull();
        expect(r.text).toContain("Private link: https://share.capybaraharmony.com/p/");
    });

    it("an unknown id and a hidden post are errors (a hidden one is never shown)", async () => {
        await expect(run("show_post", { id: "NoSuchPost" })).rejects.toThrow(/no post with id/);
        const h = file({ name: "h.mp4" });
        hide(h.id);
        await expect(run("show_post", { id: h.id })).rejects.toThrow(/is hidden \(library_status unhides it\)/);
        expect(tool("show_post").input.safeParse({}).success).toBe(false);
    });

    it("a missing transcript is fine", async () => {
        const v = file();
        offered = new Set(["library.post", "library.transcript"]);
        answers["library.transcript"] = () => {
            throw new OpError(404, "error.library.not_found");
        };
        const r = await run("show_post", { id: v.id });
        expect(r.out.post.transcript_excerpt).toBeNull();
    });
});

// ---- show_edit ------------------------------------------------------------------------------------------------------------------

describe("show_edit", () => {
    const EDIT_ID = "Edit0000000000000001";
    const got = (over: Record<string, unknown> = {}) => ({
        id: EDIT_ID,
        title: "Friday montage",
        revision: 4,
        duration: 11,
        render: null,
        timeline: {
            version: 1,
            canvas: { w: 1080, h: 1920, fps: 30 },
            main: [
                { id: "c1", item: "SrcA", in: 1, out: 5, speed: 1, fit: "fit", volume: 1, muted: false },
                { id: "c2", item: "SrcB", in: 0, out: 8, speed: 2, fit: "fit", volume: 1, muted: true },
            ],
            overlay: [
                { id: "o1", item: "SrcC", at: 2, in: 0, out: 3, frame: { x: 0, y: 0, w: 0.5 }, opacity: 1, volume: 1, muted: true },
                { id: "o2", item: "SrcD", at: 6, in: 0, out: 1.5, frame: { x: 0, y: 0, w: 0.5 }, opacity: 1, volume: 1, muted: true },
            ],
        },
        sources: {
            SrcA: { id: "SrcA", name: "intro.mp4", kind: "video", duration: 20, poster_url: `${MEDIA}PosterA.jpg` },
            SrcB: { id: "SrcB", name: "main.mp4", kind: "video", duration: 8, poster_url: null },
            SrcC: { id: "SrcC", name: "my-cutout.png", kind: "photo", poster_url: null },
            SrcD: { id: "SrcD", name: "spin.gif", kind: "gif", poster_url: null },
        },
        ...over,
    });

    // the editor's source files, as library files under the ids the project names
    const seedSources = (vis: Partial<Record<"SrcA" | "SrcB" | "SrcC" | "SrcD", "public" | "private">> = {}) => {
        for (const [id, name] of [["SrcA", "intro.mp4"], ["SrcB", "main.mp4"], ["SrcC", "my-cutout.png"], ["SrcD", "spin.gif"]] as const) file({ id, name, visibility: vis[id] ?? "public", content_type: id === "SrcC" ? "image/png" : id === "SrcD" ? "image/gif" : "video/mp4" });
    };

    it("an id: the main track laid end to end (speed counted), overlays by kind, and a stale render flagged", async () => {
        seedSources();
        const made = file({ name: "montage.mp4" });
        answers["edits.get"] = got({ render: { id: "R1", status: "done", revision: 3, progress: 1, item_id: made.id, poster_url: `${MEDIA}PosterM.jpg` } });
        const r = await run("show_edit", { id: EDIT_ID });
        EditOut.parse(r.out);
        const p = r.out.project;
        expect(p).toMatchObject({ id: EDIT_ID, title: "Friday montage", revision: 4, duration_s: 11, canvas: { w: 1080, h: 1920, fps: 30 } });
        expect(p.main).toEqual([
            expect.objectContaining({ id: "c1", name: "intro.mp4", start: 0, end: 4, in: 1, out: 5, speed: 1, muted: false, poster_url: `${MEDIA}PosterA.jpg` }),
            expect.objectContaining({ id: "c2", name: "main.mp4", start: 4, end: 8, speed: 2, muted: true, poster_url: null }),
        ]);
        expect(p.overlay).toEqual([
            { id: "o1", name: "my-cutout.png", kind: "cutout", start: 2, end: 5 },
            { id: "o2", name: "spin.gif", kind: "gif", start: 6, end: 7.5 },
        ]);
        expect(p.render).toEqual({ status: "done", progress: 1, post_id: made.id, poster_url: `${MEDIA}PosterM.jpg`, stale: true });
        expect(r.out.projects).toEqual([]);
        expect(r.text).toContain("Edit “Friday montage”");
        expect(r.text).toContain("1. intro.mp4 · 0:00–0:04");
        expect(r.text).toContain("2. main.mp4 · 0:04–0:08 · 2x · muted");
        expect(r.text).toContain("changed since");
        expect(batches).toBe(1);
    });

    it("a private source shows no picture; a hidden or unknown one gets a neutral name; still one D1 round trip", async () => {
        seedSources({ SrcA: "private" });
        hide("SrcB");
        // SrcC is a file nobody has (gone), SrcD is public
        db.raw.prepare("DELETE FROM media_items WHERE id = 'SrcC'").run();
        answers["edits.get"] = got();
        const r = await run("show_edit", { id: EDIT_ID });
        const p = r.out.project;
        // private: the owner's own name stays, the picture goes (it is not a link a browser can load)
        expect(p.main[0]).toMatchObject({ name: "intro.mp4", poster_url: null });
        // hidden: neither the name nor the picture
        expect(p.main[1]).toMatchObject({ name: "clip 2", poster_url: null });
        expect(JSON.stringify(r.out) + r.text).not.toContain("main.mp4");
        // gone: a neutral name
        expect(p.overlay[0]).toMatchObject({ name: "overlay 1" });
        expect(p.overlay[1]).toMatchObject({ name: "spin.gif", kind: "gif" });
        expect(r.text).not.toContain("main.mp4");
        expect(batches).toBe(1);
        // a public source keeps its picture
        db.raw.prepare("DELETE FROM media_hidden").run();
        db.raw.prepare("UPDATE media_items SET visibility = 'public' WHERE id = 'SrcA'").run();
        db.raw.prepare("UPDATE media_items SET url = ?, bucket = 'media' WHERE id = 'SrcA'").run(`${MEDIA}NmSrcA.mp4`);
        expect((await run("show_edit", { id: EDIT_ID })).out.project.main[0].poster_url).toBe(`${MEDIA}PosterA.jpg`);
    });

    it("a render of a private post gets no poster; a running one maps to running", async () => {
        const made = file({ visibility: "private" });
        answers["edits.get"] = got({ render: { id: "R1", status: "rendering", revision: 4, progress: 0.4, item_id: made.id, poster_url: `${MEDIA}P.jpg` } });
        const r = await run("show_edit", { id: EDIT_ID });
        expect(r.out.project.render).toEqual({ status: "running", progress: 0.4, post_id: made.id, poster_url: null, stale: false });
        expect(r.text).toContain("Rendering (40%)");
    });

    it("neither id nor query lists the projects; several matches list them; one match opens it", async () => {
        const made = file();
        const list = [
            { id: "Edit0000000000000001", title: "Friday montage", revision: 4, duration: 11, render: { status: "done", revision: 4, item_id: made.id, poster_url: `${MEDIA}PosterM.jpg` } },
            { id: "Edit0000000000000002", title: "Friday outtakes", revision: 1, duration: 5, render: null },
            { id: "Edit0000000000000003", title: "Cats", revision: 2, duration: 8, render: null },
        ];
        answers["edits.list"] = list;
        answers["edits.get"] = got();
        const all = await run("show_edit", {});
        expect(all.out.project).toBeNull();
        expect(all.out.projects).toEqual([
            { id: "Edit0000000000000001", title: "Friday montage", revision: 4, duration_s: 11, rendered: true, poster_url: `${MEDIA}PosterM.jpg` },
            { id: "Edit0000000000000002", title: "Friday outtakes", revision: 1, duration_s: 5, rendered: false, poster_url: null },
            { id: "Edit0000000000000003", title: "Cats", revision: 2, duration_s: 8, rendered: false, poster_url: null },
        ]);
        expect(all.text).toMatch(/^3 edit projects/);
        expect(all.text).toContain(`1. Friday montage · 11 s · rendered · Edit0000000000000001`);
        const several = await run("show_edit", { query: "friday" });
        expect(several.out.project).toBeNull();
        expect(several.out.projects.map((p: any) => p.title)).toEqual(["Friday montage", "Friday outtakes"]);
        expect(calls.some((c) => c.name === "edits.get")).toBe(false);
        const one = await run("show_edit", { query: "cats" });
        expect(one.out.project.id).toBe(EDIT_ID);
        expect(calls.find((c) => c.name === "edits.get")!.input).toEqual({ id: "Edit0000000000000003" });
        const none = await run("show_edit", { query: "zebra" });
        expect(none.out).toMatchObject({ project: null, projects: [] });
        expect(none.text).toContain("No edit projects match");
    });

    it("an unknown id is the editor's own error", async () => {
        answers["edits.get"] = () => {
            throw new OpError(404, "error.edit.not_found", "no such project");
        };
        await expect(run("show_edit", { id: "Edit0000000000000009" })).rejects.toThrow(/no such project/);
    });

    it("a bare answer (no timeline, no sources) does not crash", async () => {
        answers["edits.get"] = { id: EDIT_ID, title: "Empty", revision: 1, duration: 0, render: null, timeline: {}, sources: {} };
        const r = await run("show_edit", { id: EDIT_ID });
        expect(r.out.project).toMatchObject({ main: [], overlay: [], render: null });
    });
});

// ---- collections and share links ------------------------------------------------------------------------------------------------

describe("list_collections and list_share_links", () => {
    function seed() {
        const a = file({ name: "a.mp4" });
        const b = file({ name: "b.mp4" });
        const c = file({ visibility: "private", name: "c.mp4" });
        const d = file({ name: "d.mp4" });
        const e = file({ content_type: "image/jpeg", name: "e.jpg" });
        hide(d.id);
        title(a.id, "Alpha");
        set("SetOne", [a.id, b.id], { title: "Cats" });
        set("SetTwo", [c.id, e.id], { title: null, private: true });
        set("SetThree", [d.id, a.id]);
        set("SetGone", [a.id, b.id], { revoked: true });
        collection("ColA", "Favourites", ["SetOne", "SetTwo"]);
        collection("ColB", "Other", ["SetThree"]);
        return { a, b, c, d, e };
    }

    it("collections: links with file counts, post counts and up to 8 public pictures (none from private or hidden posts)", async () => {
        const { a, b, e } = seed();
        const r = await run("list_collections", {});
        CollectionsOut.parse(r.out);
        expect(r.out.total).toBe(2);
        const fav = r.out.collections.find((c: any) => c.name === "Favourites");
        expect(fav.links).toEqual([
            { id: "SetOne", url: `${SHARE}g/SetOne`, files: 2, private: false },
            { id: "SetTwo", url: expect.stringMatching(/^https:\/\/share\.capybaraharmony\.com\/p\//), files: 2, private: true },
        ]);
        expect(fav.posts).toBe(4);
        // a and b are public videos; the picture post e is public; c is private
        expect(fav.thumbs.length).toBe(3);
        expect(fav.thumbs.every((t: string) => t.startsWith(MEDIA))).toBe(true);
        expect(fav.thumbs).toContain(e.url);
        expect(fav.thumbs).not.toContain(a.url);
        const other = r.out.collections.find((c: any) => c.name === "Other");
        // the hidden post never counts or shows
        expect(other.posts).toBe(1);
        void b;
        expect(r.text).toMatch(/^2 collections\./);
        expect(r.text).toContain(`1. `);
        expect(batches).toBe(1);
        expect(r.text).not.toMatch(/media\.capybaraharmony/);
    });

    it("collections: a name filter, a limit, and none", async () => {
        seed();
        const f = await run("list_collections", { name: "fav" });
        expect(f.out.collections.map((c: any) => c.name)).toEqual(["Favourites"]);
        expect((await run("list_collections", { limit: 1 })).out.collections).toHaveLength(1);
        const none = await run("list_collections", { name: "zzz" });
        expect(none.out).toMatchObject({ total: 0, collections: [] });
        expect(none.text).toContain("No collection matches");
        expect(tool("list_collections").input.safeParse({ limit: 500 }).success).toBe(true);
        expect(tool("list_collections").input.safeParse({ limit: 501 }).success).toBe(false);
        expect(tool("list_collections").input.safeParse({ limit: 0 }).success).toBe(false);
    });

    it("links: newest first, share.* urls only, the collection name, files and thumbs; revoked ones never", async () => {
        seed();
        const r = await run("list_share_links", {});
        LinksOut.parse(r.out);
        expect(r.out.created).toBeNull();
        expect(r.out.links.map((l: any) => l.id).sort()).toEqual(["SetOne", "SetThree", "SetTwo"]);
        const one = r.out.links.find((l: any) => l.id === "SetOne");
        expect(one).toMatchObject({ url: `${SHARE}g/SetOne`, title: "Cats", files: 2, private: false, collection: "Favourites" });
        expect(one.thumbs).toHaveLength(2);
        const two = r.out.links.find((l: any) => l.id === "SetTwo");
        expect(two.private).toBe(true);
        expect(two.url).toMatch(/\/p\//);
        // c is private, e is a public picture
        expect(two.thumbs).toHaveLength(1);
        const three = r.out.links.find((l: any) => l.id === "SetThree");
        // the hidden post gives no picture
        expect(three.thumbs).toHaveLength(1);
        for (const l of r.out.links) for (const t of l.thumbs) expect(t.startsWith(MEDIA)).toBe(true);
        expect(r.text).toMatch(/^3 share links\./);
        expect(r.text).toContain(`Cats · 2 files · SetOne · ${SHARE}g/SetOne`);
        expect(r.text).not.toContain("SetGone");
        expect(batches).toBe(1);
    });

    it("links: by collection (id or name), by query, and the limit", async () => {
        seed();
        expect((await run("list_share_links", { collection: "Favourites" })).out.links.map((l: any) => l.id).sort()).toEqual(["SetOne", "SetTwo"]);
        expect((await run("list_share_links", { collection: "ColB" })).out.links.map((l: any) => l.id)).toEqual(["SetThree"]);
        expect((await run("list_share_links", { query: "cats" })).out.links.map((l: any) => l.id)).toEqual(["SetOne"]);
        expect((await run("list_share_links", { limit: 1 })).out.links).toHaveLength(1);
        const missing = await run("list_share_links", { collection: "nope" });
        expect(missing.out.links).toEqual([]);
        expect(missing.text).toContain("none found");
    });

    it("more than 100 posts in one read still works (one JSON parameter, no 100-parameter limit)", async () => {
        const ids: string[] = [];
        for (let i = 0; i < 130; i++) ids.push(file({ name: `p${i}.mp4` }).id);
        set("BigSet", ids.slice(0, 10), { title: "Big" });
        collection("BigCol", "Big", ["BigSet"]);
        const r = await run("list_collections", {});
        expect(r.out.collections[0].posts).toBe(10);
        const search = await run("search_library", { query: "p", limit: 24 });
        expect(search.out.items).toHaveLength(24);
    });
});

// ---- convert_to_webp --------------------------------------------------------------------------------------------------------------

describe("convert_to_webp", () => {
    const JOB = "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt";

    it("a long video with no range: pick, nothing runs", async () => {
        const v = file({ duration: 42, name: "long.mp4" });
        title(v.id, "Long one");
        const r = await run("convert_to_webp", { id: v.id });
        expect(r.out).toMatchObject({ state: "pick", job: null, range: null, width: 480, quality: "med", post: null, share_url: null });
        expect(r.out.source).toMatchObject({ id: v.id, title: "Long one", duration_s: 42, url: v.url });
        expect(r.out.source.poster_url).toMatch(/Poster/);
        expect(r.text).toContain("Pick the part");
        expect(r.text).toContain("Nothing has been converted yet");
        expect(calls.map((c) => c.name)).not.toContain("make.webp");
    });

    it("only one end given still asks (start without end on a long video)", async () => {
        const v = file({ duration: 42 });
        const r = await run("convert_to_webp", { id: v.id, start: 3 });
        expect(r.out.state).toBe("pick");
    });

    it("a short video runs whole, and a quick encode comes back done with the post and its share link", async () => {
        const src = file({ duration: 6.5, name: "short.mp4" });
        const made = file({ content_type: "image/webp", name: "made.webp", duration: null, poster: null });
        title(made.id, "Short as a webp");
        answers["make.webp"] = { job: JOB, status: "running", queue_ahead: null };
        answers["jobs.wait"] = { job: JOB, status: "done", bytes: 50_000, width: 480, height: 854, seconds: 6.5, file_id: made.id, post_id: made.id, kind: "image", public: true, share_url: `${SHARE}${made.name}` };
        const r = await run("convert_to_webp", { id: src.id });
        expect(calls.find((c) => c.name === "make.webp")!.input).toEqual({ id: src.id, start: 0, end: 6.5, width: 480, quality: "med" });
        expect(calls.find((c) => c.name === "jobs.wait")!.input).toMatchObject({ job: JOB });
        expect(calls.find((c) => c.name === "jobs.wait")!.input.seconds).toBeLessThanOrEqual(10);
        expect(r.out).toMatchObject({ state: "done", job: JOB, progress: 1, range: { start: 0, end: 6.5 }, share_url: `${SHARE}${made.name}` });
        expect(r.out.post).toMatchObject({ id: made.id, title: "Short as a webp", kind: "image", status: "public", thumb_url: made.url });
        expect(r.text).toContain(`Share link: ${SHARE}${made.name}`);
    });

    it("a range runs and, when the encode is slow, answers running with the newest job id", async () => {
        const src = file({ duration: 60 });
        const NEW = "studio:AbCdEfGhIjKlMnOpQrStUv:ZZZZZZZZZZZZZZZZZZZZ";
        answers["make.webp"] = { job: "open:AbCdEfGhIjKlMnOpQrStUv:eyJhIjoxfQ", status: "opening" };
        answers["jobs.wait"] = { job: NEW, status: "running", progress: 0.35 };
        const r = await run("convert_to_webp", { id: src.id, start: 4, end: 9, width: 320, quality: "high" });
        expect(calls.find((c) => c.name === "make.webp")!.input).toEqual({ id: src.id, start: 4, end: 9, width: 320, quality: "high" });
        expect(r.out).toMatchObject({ state: "running", job: NEW, progress: 0.35, range: { start: 4, end: 9 }, width: 320, quality: "high", post: null });
        expect(r.text).toContain("35%");
        expect(r.text).toContain(NEW);
        expect(r.text).toContain("job_status");
    });

    it("a gallery's file id is what make.webp gets, and its own video is the source", async () => {
        const g1 = file({ post_key: "GalPost", id: "GalFile0000001", role: "item", item_index: 0, content_type: "image/jpeg", duration: null, poster: null });
        const g2 = file({ post_key: "GalPost", id: "GalFile0000002", role: "item", item_index: 1, duration: 40, name: "second.mp4" });
        title("GalPost", "A gallery");
        const r = await run("convert_to_webp", { id: g2.id });
        // the second video, not the lead picture, is the source (the post's lead is the picture)
        expect(r.out.source).toMatchObject({ id: g2.id, title: "A gallery", duration_s: 40, url: g2.url });
        answers["make.webp"] = { job: JOB, status: "running" };
        answers["jobs.wait"] = { job: JOB, status: "running" };
        await run("convert_to_webp", { id: g2.id, start: 0, end: 3 });
        expect(calls.find((c) => c.name === "make.webp")!.input).toMatchObject({ id: g2.id });
        // the library.post read used the post's key, not the file id
        expect(calls.find((c) => c.name === "library.post")!.input).toEqual({ id: "GalPost" });
        // a picture file of the gallery is refused
        await expect(run("convert_to_webp", { id: g1.id })).rejects.toThrow(/picture/);
    });

    it("a picture post is refused up front, pointing at make_still; nothing runs", async () => {
        const pic = file({ content_type: "image/png", duration: null, poster: null, name: "p.png" });
        await expect(run("convert_to_webp", { id: pic.id })).rejects.toThrow(/make_still/);
        await expect(run("convert_to_webp", { id: pic.id, start: 0, end: 3 })).rejects.toThrow(/picture/);
        expect(calls.map((c) => c.name)).not.toContain("make.webp");
        // a gif is motion: it is a source
        const gif = file({ content_type: "image/gif", duration: 30, poster: null, name: "g.gif" });
        expect((await run("convert_to_webp", { id: gif.id })).out.state).toBe("pick");
    });

    it("a failed encode answers error with its code", async () => {
        const src = file({ duration: 60 });
        answers["make.webp"] = { job: JOB, status: "queued", queue_ahead: 1 };
        answers["jobs.wait"] = { job: JOB, status: "error", error: "error.studio.render_failed" };
        const r = await run("convert_to_webp", { id: src.id, start: 0, end: 5 });
        expect(r.out).toMatchObject({ state: "error", error: "error.studio.render_failed", post: null });
        expect(r.text).toContain("error.studio.render_failed");
    });

    it("a range outside 0.5 to 10 s, an unknown id and a hidden post are errors; an end past the video is cut to it", async () => {
        const src = file({ duration: 30 });
        await expect(run("convert_to_webp", { id: src.id, start: 0, end: 12 })).rejects.toThrow(/0.5 to 10/);
        await expect(run("convert_to_webp", { id: src.id, start: 5, end: 5.2 })).rejects.toThrow(/0.5 to 10/);
        await expect(run("convert_to_webp", { id: "NoSuchPost" })).rejects.toThrow(/no post with id/);
        const h = file({ duration: 3 });
        hide(h.id);
        await expect(run("convert_to_webp", { id: h.id })).rejects.toThrow(/no post with id/);
        answers["make.webp"] = { job: JOB, status: "running" };
        answers["jobs.wait"] = { job: JOB, status: "running" };
        const cutShort = await run("convert_to_webp", { id: src.id, start: 25, end: 40 });
        expect(cutShort.out.range).toEqual({ start: 25, end: 30 });
        expect(tool("convert_to_webp").input.safeParse({ id: "x", width: 640 }).success).toBe(false);
        expect(tool("convert_to_webp").input.safeParse({ id: "x", quality: "ultra" }).success).toBe(false);
    });
});

// ---- upload_files ---------------------------------------------------------------------------------------------------------------

describe("upload_files", () => {
    const begin = (i: any) => ({
        upload_url: `https://api.capybaraharmony.com/mcp/upload/tok${i.name ?? "x"}.sig?${i.name ? `name=${i.name}` : ""}${i.public ? "&public=1" : ""}`,
        method: "PUT",
        expires_at: "2025-10-09T00:15:00.000Z",
        max_bytes: 100_000_000,
        types: ["image/gif", "image/webp", "image/png", "image/jpeg", "video/mp4", "video/quicktime", "image/heic"],
        curl: "curl -sS -T FILE 'x'",
    });

    it("no files: one link; the limits and accepted types come from the op", async () => {
        answers["upload.begin"] = begin;
        const r = await run("upload_files", {});
        UploadOut.parse(r.out);
        expect(r.out.uploads).toHaveLength(1);
        expect(r.out).toMatchObject({ max_bytes: 100_000_000, public: false });
        expect(r.out.accept).toEqual([".gif", ".webp", ".png", ".jpg", ".mp4", ".mov", ".heic", ".jpeg"]);
        expect(r.out.uploads[0].curl).toMatch(/^curl -sS -T FILE 'https:\/\/api\.capybaraharmony\.com\/mcp\/upload\//);
        expect(calls).toEqual([{ name: "upload.begin", input: {} }]);
        expect(r.text).toMatch(/^1 upload link ready/);
        expect(r.text).toContain("100 MB");
    });

    it("up to 10 files, one link each, with their names, titles and public flag", async () => {
        answers["upload.begin"] = begin;
        const files = Array.from({ length: 10 }, (_, i) => ({ name: `clip ${i}.mp4`, ...(i === 0 ? { title: "First" } : {}) }));
        const r = await run("upload_files", { files, public: true });
        expect(r.out.uploads).toHaveLength(10);
        expect(r.out.public).toBe(true);
        expect(r.out.uploads[0]).toMatchObject({ name: "clip 0.mp4", expires_at: "2025-10-09T00:15:00.000Z" });
        // FILE stands for the path on disk, as the older tool's line had it
        expect(r.out.uploads[0].curl).toMatch(/^curl -sS -T FILE 'https:/);
        expect(r.text).toContain("Replace FILE with the path");
        expect(calls.filter((c) => c.name === "upload.begin")).toHaveLength(10);
        expect(calls[0]!.input).toEqual({ name: "clip 0.mp4", title: "First", public: true });
        expect(r.text.split("\n").filter((l) => /^\d+\. /.test(l))).toHaveLength(10);
        expect(tool("upload_files").input.safeParse({ files: [] }).success).toBe(false);
        expect(tool("upload_files").input.safeParse({ files: Array.from({ length: 11 }, () => ({ name: "a.mp4" })) }).success).toBe(false);
        expect(tool("upload_files").input.safeParse({ files: [{ name: "" }] }).success).toBe(false);
    });

    it("the curl line has the FILE placeholder whatever the name", async () => {
        answers["upload.begin"] = begin;
        const r = await run("upload_files", { files: [{ name: "it's.mp4" }] });
        expect(r.out.uploads[0].curl).toMatch(/^curl -sS -T FILE 'https:/);
    });
});

// ---- create_share_link --------------------------------------------------------------------------------------------------------

describe("create_share_link", () => {
    it("a gallery link of several posts, with thumbs; share.* url, never a media url", async () => {
        const a = file({ name: "a.mp4" });
        const b = file({ name: "b.mp4" });
        answers["links.create"] = { id: "NewSet", url: `${SHARE}g/NewSet`, title: "Two cats", files: 2 };
        const r = await run("create_share_link", { ids: [a.id, b.id], title: "Two cats" });
        LinksOut.parse(r.out);
        expect(calls[0]).toEqual({ name: "links.create", input: { ids: [a.id, b.id], title: "Two cats" } });
        expect(calls.some((c) => c.name === "collections.add")).toBe(false);
        expect(r.out).toMatchObject({ total: 1, created: "NewSet" });
        expect(r.out.links[0]).toMatchObject({ id: "NewSet", url: `${SHARE}g/NewSet`, title: "Two cats", files: 2, private: false, collection: null, created_at: new Date(T0).toISOString() });
        expect(r.out.links[0].thumbs).toHaveLength(2);
        expect(r.text).toContain(`${SHARE}g/NewSet`);
        expect(r.text).not.toMatch(/media\.capybaraharmony/);
    });

    it("with a collection it is added and named", async () => {
        const a = file();
        const b = file();
        answers["links.create"] = { id: "NewSet", url: `${SHARE}g/NewSet`, title: null, files: 2, private: true, file_urls: [] };
        answers["collections.add"] = { id: "ColX", name: "Weekend", link_ids: ["NewSet"], post_ids: [], created: true };
        const r = await run("create_share_link", { ids: [a.id, b.id], private: true, collection: "Weekend" });
        expect(calls.find((c) => c.name === "collections.add")!.input).toEqual({ collection: "Weekend", links: ["NewSet"] });
        expect(calls[0]!.input).toMatchObject({ private: true });
        expect(r.out.links[0]).toMatchObject({ private: true, collection: "Weekend" });
        expect(r.text).toContain("Made the collection “Weekend”");
        expect(r.text).toContain("private");
    });

    it("one file gets its share page (no gallery id), which cannot go in a collection", async () => {
        const a = file({ name: "solo.mp4" });
        answers["links.create"] = { id: null, url: `${SHARE}${a.name}`, title: null, files: 1 };
        const r = await run("create_share_link", { ids: [a.id], collection: "Weekend" });
        expect(r.out.created).toBe(a.name);
        expect(r.out.links[0]).toMatchObject({ id: a.name, url: `${SHARE}${a.name}`, files: 1, collection: null });
        expect(calls.some((c) => c.name === "collections.add")).toBe(false);
        expect(r.text).toContain("not put in “Weekend”");
    });

    it("a private post gives no thumbs; a refusal from the op is the error; the op, not the tool, limits the files", async () => {
        const p = file({ visibility: "private" });
        answers["links.create"] = { id: "S1", url: `${SHARE}p/${"k".repeat(22)}`, title: null, files: 1, private: true };
        const r = await run("create_share_link", { ids: [p.id], private: true });
        expect(r.out.links[0].thumbs).toEqual([]);
        answers["links.create"] = () => {
            throw new OpError(409, "error.share.not_public", "not public, so a public link cannot hold them");
        };
        await expect(run("create_share_link", { ids: [p.id] })).rejects.toThrow(/not public/);
        expect(tool("create_share_link").input.safeParse({ ids: [] }).success).toBe(false);
        // links.create takes any number of post ids (a gallery post brings its files) and counts the files itself
        expect(tool("create_share_link").input.safeParse({ ids: Array.from({ length: 11 }, (_, i) => `id${i}`) }).success).toBe(true);
        expect(tool("create_share_link").input.safeParse({ ids: "one-id" }).success).toBe(true);
    });
});

// ---- save_link ----------------------------------------------------------------------------------------------------------------

describe("save_link", () => {
    const SID = "AbCdEfGhIjKlMnOpQrStUv";

    it("engine auto leaves the op's engine unset; cobalt and ytdlp pass through", async () => {
        answers["library.save"] = { status: "saving", save_id: SID, post_id: null, title: null, kind: null, files: null, public: null, error: null, saves_left_today: 9 };
        await run("save_link", { url: "https://x.com/a/status/1" });
        expect(calls[0]!.input).toEqual({ url: "https://x.com/a/status/1", wait: 8 });
        await run("save_link", { url: "https://x.com/a/status/1", engine: "ytdlp" });
        expect(calls[1]!.input).toMatchObject({ engine: "ytdlp" });
        await run("save_link", { url: "https://x.com/a/status/1", engine: "cobalt" });
        expect(calls[2]!.input).toMatchObject({ engine: "cobalt" });
        expect(tool("save_link").input.safeParse({ url: "ftp://x" }).success).toBe(false);
        expect(tool("save_link").input.safeParse({ url: "not a url" }).success).toBe(false);
        expect(tool("save_link").input.safeParse({ url: "https://a.b/c", engine: "wget" }).success).toBe(false);
    });

    it("still going: running with a job id the widget follows", async () => {
        answers["library.save"] = { status: "queued", save_id: SID, post_id: null, title: null, kind: null, files: null, public: null, error: null, saves_left_today: 9 };
        const r = await run("save_link", { url: "https://www.tiktok.com/@a/video/1" });
        expect(r.out).toMatchObject({ state: "running", job: `save:${SID}`, url: "https://www.tiktok.com/@a/video/1", error: null, post: null });
        expect(r.text).toContain("waiting in line");
        expect(r.text).toContain(`job_status with job save:${SID}`);
    });

    it("saved within the wait: done with the new post", async () => {
        const v = file({ post_key: SID, id: "SavedFile000001", name: "saved.mp4" });
        title(SID, "Saved clip");
        answers["library.save"] = { status: "ready", save_id: SID, post_id: SID, title: "Saved clip", kind: "video", files: 1, public: true, error: null, saves_left_today: 9 };
        const r = await run("save_link", { url: "https://www.tiktok.com/@a/video/1" });
        expect(r.out).toMatchObject({ state: "done", error: null });
        expect(r.out.post).toMatchObject({ id: SID, title: "Saved clip", kind: "video", status: "public" });
        expect(r.text).toContain("Saved “Saved clip”");
        expect(r.text).toContain(`Share link: ${SHARE}${v.name}`);
        // the finished save carries its share link and the engine asked for, so the widget can show the link and retry
        expect(r.out).toMatchObject({ share_url: `${SHARE}${v.name}`, engine: "auto" });
        SaveOut.parse(r.out);
    });

    it("a running or failed save carries the engine asked for and no share link", async () => {
        answers["library.save"] = { status: "queued", save_id: SID, post_id: null, title: null, kind: null, files: null, public: null, error: null, saves_left_today: 9 };
        expect((await run("save_link", { url: "https://x.com/a/status/1", engine: "ytdlp" })).out).toMatchObject({ engine: "ytdlp", share_url: null });
        answers["library.save"] = { status: "error", save_id: SID, post_id: null, title: null, kind: null, files: null, public: null, error: "error.studio.fetch_failed", saves_left_today: 9 };
        expect((await run("save_link", { url: "https://x.com/a/status/1", engine: "cobalt" })).out).toMatchObject({ engine: "cobalt", share_url: null });
    });

    it("a failed save: error with the code", async () => {
        answers["library.save"] = { status: "error", save_id: SID, post_id: null, title: null, kind: null, files: null, public: null, error: "error.studio.fetch_failed", saves_left_today: 9 };
        const r = await run("save_link", { url: "https://example.com/v" });
        expect(r.out).toMatchObject({ state: "error", error: "error.studio.fetch_failed" });
        expect(r.text).toContain("error.studio.fetch_failed");
    });

    it("the save cap and other refusals are the op's own errors", async () => {
        answers["library.save"] = () => {
            throw new OpError(429, "error.chat.save_cap", "this thread already saved 20 links today");
        };
        await expect(run("save_link", { url: "https://example.com/v" })).rejects.toThrow(/saved 20 links/);
    });
});

// ---- job_status -----------------------------------------------------------------------------------------------------------------

describe("job_status", () => {
    const JOB = "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt";
    const SID = "SaveSessionId000000aXY";

    it("a running job maps to running with its progress; the wait is short", async () => {
        answers["jobs.wait"] = { job: JOB, status: "running", progress: 0.5 };
        const r = await run("job_status", { job: JOB });
        expect(r.out).toEqual({ job: JOB, state: "running", progress: 0.5, error: null, post: null, share_url: null, file_id: null, post_id: null, queue_ahead: null, file: null, agent: null });
        expect(calls[0]!.input).toEqual({ job: JOB, seconds: 8 });
        expect(r.text).toContain("50%");
    });

    it("queued and opening are running too; cancelled and error are error", async () => {
        for (const status of ["queued", "opening"]) {
            answers["jobs.wait"] = { job: JOB, status };
            expect((await run("job_status", { job: JOB })).out.state).toBe("running");
        }
        answers["jobs.wait"] = { job: JOB, status: "cancelled" };
        expect((await run("job_status", { job: JOB })).out).toMatchObject({ state: "error", error: "cancelled" });
        answers["jobs.wait"] = { job: JOB, status: "error", error: "error.studio.render_failed" };
        expect((await run("job_status", { job: JOB })).out).toMatchObject({ state: "error", error: "error.studio.render_failed" });
    });

    it("done: the made post as a PostSummary and its share link", async () => {
        const made = file({ content_type: "image/webp", name: "made.webp", duration: null, poster: null });
        title(made.id, "Made");
        answers["jobs.wait"] = { job: JOB, status: "done", post_id: made.id, share_url: `${SHARE}${made.name}`, public: true };
        const r = await run("job_status", { job: JOB });
        JobOut.parse(r.out);
        expect(r.out).toMatchObject({ state: "done", progress: 1, share_url: `${SHARE}${made.name}` });
        expect(r.out.post).toMatchObject({ id: made.id, title: "Made", thumb_url: made.url, status: "public" });
        expect(r.text).toContain(`Share link: ${SHARE}${made.name}`);
    });

    it("done with a private result has no share link and no picture; a hidden one has no post", async () => {
        const made = file({ visibility: "private" });
        answers["jobs.wait"] = { job: JOB, status: "done", post_id: made.id, public: false };
        const r = await run("job_status", { job: JOB });
        expect(r.out.post).toMatchObject({ id: made.id, status: "off", thumb_url: null });
        expect(r.out.share_url).toBeNull();
        hide(made.id);
        const h = await run("job_status", { job: JOB });
        expect(h.out).toMatchObject({ state: "done", post: null, share_url: null });
    });

    it("a refusal from jobs.wait (not a job id) is the error", async () => {
        answers["jobs.wait"] = () => {
            throw new OpError(400, "error.chat.job", "nope is not a job id");
        };
        await expect(run("job_status", { job: "nope" })).rejects.toThrow(/not a job id/);
    });

    it("a save: the session is asked, a ready one comes back done with its post", async () => {
        const v = file({ id: "SavedFile000002", post_key: SID, name: "s.mp4" });
        title(SID, "From the web");
        db.raw
            .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, created_at, expires_at) VALUES (?, 'k', 'https://x.com/a', 'x', 't', 'ready', ?, ?)")
            .run(SID, T0, T0 + 86_400_000);
        const r = await run("job_status", { job: `save:${SID}` });
        expect(r.out).toMatchObject({ job: `save:${SID}`, state: "done", progress: 1 });
        expect(r.out.post).toMatchObject({ id: SID, title: "From the web" });
        expect(r.out.share_url).toBe(`${SHARE}${v.name}`);
        expect(calls.some((c) => c.name === "jobs.wait")).toBe(false);
    });

    it("a save still going is running; a failed or unknown one is an error", async () => {
        db.raw
            .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, created_at, expires_at) VALUES (?, 'k', 'https://x.com/a', 'x', 't', 'saving', ?, ?)")
            .run(SID, T0, T0 + 86_400_000);
        container = { fetch: async () => Response.json({ status: "saving", step: "downloading" }) };
        expect((await run("job_status", { job: `save:${SID}` })).out).toMatchObject({ state: "running", error: null });
        const BAD = "SaveSessionId000000bXY";
        db.raw
            .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, error_code, created_at, expires_at) VALUES (?, 'k', 'https://x.com/b', 'x', 't', 'error', 'error.studio.fetch_failed', ?, ?)")
            .run(BAD, T0, T0 + 86_400_000);
        expect((await run("job_status", { job: `save:${BAD}` })).out).toMatchObject({ state: "error", error: expect.stringMatching(/^error\./) });
        expect((await run("job_status", { job: "save:UnknownSession000000XY" })).out).toMatchObject({ state: "error", error: "error.studio.not_found" });
    });

    describe("an open: job (a file still opening) cannot start a second render", () => {
        const SID_O = "AbCdEfGhIjKlMnOpQrStUv";
        const OPEN = `open:${SID_O}:eyJyb3V0ZSI6InJlbmRlciIsImJvZHkiOnt9fQ`;
        const render = (id: string, status: string, at: number) =>
            db.raw.prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES (?, ?, ?, ?)").run(id, SID_O, status, at);

        it("no render yet: the registry gets the open id (it starts the render, once)", async () => {
            answers["jobs.wait"] = { job: `studio:${SID_O}:NewRender0000000001`, status: "running", progress: 0.1 };
            const r = await run("job_status", { job: OPEN });
            expect(calls[0]!.input.job).toBe(OPEN);
            // the answer carries the id to use from now on
            expect(r.out.job).toBe(`studio:${SID_O}:NewRender0000000001`);
        });
        it("a render already running or done: its studio id is waited on, the open id never reaches jobs.wait", async () => {
            render("OldFailed00000000001", "error", T0 - 5);
            render("Running000000000001a", "pending", T0 - 1);
            answers["jobs.wait"] = (i: any) => ({ job: i.job, status: "running" });
            const r = await run("job_status", { job: OPEN });
            expect(calls.filter((c) => c.name === "jobs.wait").map((c) => c.input.job)).toEqual([`studio:${SID_O}:Running000000000001a`]);
            expect(r.out.job).toBe(`studio:${SID_O}:Running000000000001a`);
            db.raw.prepare("UPDATE studio_renders SET status = 'success' WHERE id = 'Running000000000001a'").run();
            await run("job_status", { job: OPEN });
            expect(calls.filter((c) => c.name === "jobs.wait").every((c) => !c.input.job.startsWith("open:"))).toBe(true);
        });
        it("only a failed render: that one answers (its error), no new render is started", async () => {
            render("OldFailed00000000001", "error", T0 - 5);
            answers["jobs.wait"] = (i: any) => ({ job: i.job, status: "error", error: "error.studio.render_failed" });
            const r = await run("job_status", { job: OPEN });
            expect(calls[0]!.input.job).toBe(`studio:${SID_O}:OldFailed00000000001`);
            expect(r.out).toMatchObject({ state: "error", error: "error.studio.render_failed" });
        });
    });

    it("a saving session's progress is its step's bytes over its total (0 to 1), null when unknown", async () => {
        db.raw
            .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, created_at, expires_at) VALUES (?, 'k', 'https://x.com/a', 'x', 't', 'saving', ?, ?)")
            .run(SID, T0, T0 + 86_400_000);
        container = { fetch: async () => Response.json({ status: "saving", step: "downloading", step_bytes: 50, step_total: 200 }) };
        expect((await run("job_status", { job: `save:${SID}` })).out.progress).toBe(0.25);
        container = { fetch: async () => Response.json({ status: "saving", step: "downloading", step_bytes: null, step_total: null }) };
        expect((await run("job_status", { job: `save:${SID}` })).out.progress).toBeNull();
        container = { fetch: async () => Response.json({ status: "saving", step_bytes: 500, step_total: 200, items_done: 1, items_total: 4 }) };
        expect((await run("job_status", { job: `save:${SID}` })).out.progress).toBe(0.5);
    });

    it("an empty job id is refused by the input check", () => {
        expect(tool("job_status").input.safeParse({ job: "" }).success).toBe(false);
    });
});

// ---- the options of the retired tools ---------------------------------------------------------------------------------------
// MCP-APP-CONTRACT.md section 6.3: the app tools take over every option the tools they replace had, and forward it.

describe("search_library: what library.search and library.list could do", () => {
    const row = (id: string, o: Record<string, unknown> = {}) => ({ id, title: id, saved_at: "2025-10-09T00:00:00.000Z", source: "tiktok.com", link: `https://tiktok.com/${id}`, kind: "video", files: 1, duration: 9.6, public: true, caption: "roasted", ...o });

    it("with no query it lists the library newest first (mode list), with every library.list option forwarded", async () => {
        const a = file({ name: "new.mp4", created_at: T0 + 5000 });
        file({ name: "old.mp4", created_at: T0 + 1000 });
        const r = await run("search_library", { kind: "video", since: "2025-01-01", until: T0 + 10_000_000, source: "tiktok.com", limit: 50 });
        expect(r.out).toMatchObject({ mode: "list", query: "", total: 2 });
        expect(r.out.items[0].id).toBe(a.id);
        expect(calls.map((c) => c.name)).toEqual(["library.list"]);
        expect(calls[0]!.input).toEqual({ kind: "video", since: "2025-01-01", until: T0 + 10_000_000, source: "tiktok.com", limit: 50 });
        expect(r.text).toMatch(/^2 posts, newest first\./);
        // every row names its id, the day saved and where it came from
        expect(r.text).toContain(a.id);
        expect(r.text).toMatch(/2025-10-09 · https:\/\/www\.tiktok\.com/);
        expect(tool("search_library").input.parse({}).limit).toBeUndefined();
    });

    it("limit goes to 1000 for the list and 500 for a meaning search; the text lists every row asked for", async () => {
        for (let i = 0; i < 40; i++) file({ name: `clip ${i}.mp4` });
        const r = await run("search_library", { limit: 40 });
        expect(r.out.items).toHaveLength(40);
        expect(r.text.split("\n").filter((l) => /^\d+\. /.test(l))).toHaveLength(40);
        expect(calls[0]!.input).toMatchObject({ limit: 40 });
        offered = new Set(["library.search", "library.list"]);
        answers["library.search"] = [];
        await run("search_library", { query: "clip", limit: 900 });
        expect(calls.find((c) => c.name === "library.search")!.input.limit).toBe(500);
    });

    it("meaning search forwards within, and gives each row its score, why and where it is said", async () => {
        const a = file({ name: "a.mp4" });
        offered = new Set(["library.search", "library.list"]);
        answers["library.search"] = [row(a.id, { score: 0.83, why: ["cat", "shelf"], said: [{ at: 12, end: 14, text: "watch this cat", match: "words" }] })];
        const r = await run("search_library", { query: "cat", within: { collection: "Favourites" }, limit: 5 });
        expect(calls[0]).toEqual({ name: "library.search", input: { query: "cat", limit: 5, within: { collection: "Favourites" } } });
        expect(r.out.items[0]).toMatchObject({ score: 0.83, why: ["cat", "shelf"], said: [{ at: 12, end: 14, text: "watch this cat", match: "words" }], caption: "roasted", source_link: `https://tiktok.com/${a.id}` });
        expect(r.text).toContain("score 0.83");
        expect(r.text).toContain("why: cat, shelf");
        expect(r.text).toContain("says @0:12: “watch this cat”");
        // a plain string and a posts list are accepted too
        expect(tool("search_library").input.safeParse({ query: "x", within: "Favourites" }).success).toBe(true);
        expect(tool("search_library").input.safeParse({ query: "x", within: { posts: ["a"] } }).success).toBe(true);
        expect(tool("search_library").input.safeParse({ query: "x", within: { nope: 1 } }).success).toBe(false);
    });

    it("rows without a score (the title match) carry null score and why", async () => {
        file({ name: "dog.mp4" });
        const r = await run("search_library", { query: "dog" });
        expect(r.out.items[0]).toMatchObject({ score: null, why: null, said: null });
    });

    it("match: text keeps the substring match of library.list even while meaning search is on", async () => {
        const a = file({ name: "found by name.mp4" });
        offered = new Set(["library.search", "library.list"]);
        const r = await run("search_library", { query: "by name", match: "text" });
        expect(calls.map((c) => c.name)).toEqual(["library.list"]);
        expect(calls[0]!.input).toMatchObject({ query: "by name" });
        expect(r.out).toMatchObject({ mode: "text" });
        expect(r.out.items.map((i: any) => i.id)).toEqual([a.id]);
    });

    it("within needs meaning search: while it is off or failing the call says so instead of ignoring it", async () => {
        file({ name: "dog.mp4" });
        await expect(run("search_library", { query: "dog", within: "Favourites" })).rejects.toThrow(/needs meaning search/);
        offered = new Set(["library.search", "library.list"]);
        answers["library.search"] = () => {
            throw new Error("search is waking up");
        };
        await expect(run("search_library", { query: "dog", within: "Favourites" })).rejects.toThrow(/waking up/);
        // ... without within the title match answers, as before
        expect((await run("search_library", { query: "dog" })).out.mode).toBe("text");
    });
});

describe("show_post: everything library.post gave", () => {
    it("every file with its id, role, name, urls and private links; the text lists them", async () => {
        const v = file({ name: "orig.mp4", role: "original" });
        const w = file({ name: "made.webp", content_type: "image/webp", post_key: v.id, role: "webp", duration: null, poster: null });
        answers["library.post"] = {
            id: v.id, title: "orig", saved_at: "2025-10-09T00:00:00.000Z", source: "x.com", link: "https://x.com/a/status/1", kind: "video", duration: 9.6, public: true, caption: null,
            files: [
                { id: v.id, name: "orig.mp4", role: "original", kind: "video", content_type: "video/mp4", duration: 9.6, width: 720, height: 1280, bytes: 1000, public: true, url: v.url, share_url: `${SHARE}${v.name}`, private_url: `${SHARE}p/${"k".repeat(22)}`, private_file_url: `${SHARE}p/${"k".repeat(22)}/1.mp4` },
                { id: w.id, name: "made.webp", role: "webp", kind: "image", content_type: "image/webp", duration: null, width: 480, height: 854, bytes: 500, public: true, url: w.url, share_url: null },
            ],
        };
        offered = new Set(["library.post"]);
        const r = await run("show_post", { id: v.id });
        expect(r.out.post.file_list[0]).toMatchObject({ id: v.id, role: "original", name: "orig.mp4", url: v.url, share_url: `${SHARE}${v.name}`, private_url: `${SHARE}p/${"k".repeat(22)}`, private_file_url: `${SHARE}p/${"k".repeat(22)}/1.mp4` });
        expect(r.out.post.file_list[1]).toMatchObject({ id: w.id, role: "webp", name: "made.webp", share_url: null, private_url: null, private_file_url: null });
        expect(r.out.post.private_file_url).toBe(`${SHARE}p/${"k".repeat(22)}/1.mp4`);
        expect(r.text).toContain("Files:");
        expect(r.text).toContain(`${v.id} · original · orig.mp4 · video/mp4 · url ${v.url} · share ${SHARE}${v.name} · private ${SHARE}p/`);
        expect(r.text).toContain(`${w.id} · webp · made.webp`);
    });

    it("a hidden post gives no urls at all", async () => {
        const v = file({ name: "h.mp4" });
        hide(v.id);
        await expect(run("show_post", { id: v.id })).rejects.toThrow(/post \S+ is hidden \(library_status unhides it\)/);
    });
});

describe("list_collections and list_share_links: the ids library.* gave", () => {
    it("collections carry link_ids and post_ids, and the text row names the link ids", async () => {
        const a = file({ name: "a.mp4" });
        const b = file({ name: "b.mp4" });
        set("SetOne", [a.id, b.id], { title: "Cats" });
        collection("ColA", "Favourites", ["SetOne"]);
        const r = await run("list_collections", {});
        expect(r.out.collections[0]).toMatchObject({ id: "ColA", link_ids: ["SetOne"], post_ids: expect.arrayContaining([a.id, b.id]) });
        expect(r.text).toContain("Favourites · 1 link · 2 posts · ColA · links: SetOne");
    });

    it("links carry post_ids and a private link's file_urls; rows past 10 are listed when asked for", async () => {
        const a = file({ name: "a.mp4" });
        const b = file({ name: "b.mp4" });
        for (let i = 0; i < 14; i++) set(`Set${String(i).padStart(2, "0")}`, [a.id, b.id], { title: `link ${i}` });
        set("SetPriv", [a.id, b.id], { title: "secret", private: true });
        answers["links.list"] = [
            { id: "SetPriv", url: `${SHARE}p/${"k".repeat(22)}`, private: true, title: "secret", created_at: "2025-10-09T00:00:00.000Z", post_ids: [a.id, b.id], file_urls: [`${SHARE}p/${"k".repeat(22)}/1.mp4`, null] },
            ...Array.from({ length: 14 }, (_, i) => ({ id: `Set${String(i).padStart(2, "0")}`, url: `${SHARE}g/Set${i}`, private: false, title: `link ${i}`, created_at: "2025-10-09T00:00:00.000Z", post_ids: [a.id, b.id] })),
        ];
        const r = await run("list_share_links", { limit: 15 });
        expect(r.out.links[0]).toMatchObject({ id: "SetPriv", post_ids: [a.id, b.id], file_urls: [`${SHARE}p/${"k".repeat(22)}/1.mp4`, null] });
        expect(r.out.links[1]).toMatchObject({ post_ids: [a.id, b.id], file_urls: null });
        expect(r.text.split("\n").filter((l) => /^\d+\. /.test(l))).toHaveLength(15);
        expect(r.text).toContain(`posts: ${a.id}, ${b.id}`);
        expect(tool("list_share_links").input.safeParse({ limit: 500 }).success).toBe(true);
    });
});

describe("create_share_link, convert_to_webp, upload_files, save_link, job_status: the retired options", () => {
    it("create_share_link: a lone string id and more than 10 post ids go to links.create as the old tool sent them", async () => {
        const p = file({ name: "p.mp4" });
        answers["links.create"] = { id: "S1", url: `${SHARE}g/S1`, title: "t", files: 2, private: true, file_urls: [`${SHARE}p/${"k".repeat(22)}/1.mp4`, null] };
        const one = await run("create_share_link", { ids: p.id, title: "t", private: true });
        expect(calls[0]!.input).toEqual({ ids: [p.id], title: "t", private: true });
        expect(one.out.links[0]).toMatchObject({ post_ids: [p.id], file_urls: [`${SHARE}p/${"k".repeat(22)}/1.mp4`, null] });
        expect(one.text).toContain("Link id: S1");
        expect(one.text).toContain(`${SHARE}p/${"k".repeat(22)}/1.mp4`);
        const ids = Array.from({ length: 12 }, (_, i) => `post${i}`);
        await run("create_share_link", { ids });
        expect(calls.at(-1)!.input).toEqual({ ids });
    });

    it("convert_to_webp: crop is forwarded with the range, width and quality", async () => {
        const src = file({ duration: 30, name: "s.mp4" });
        answers["make.webp"] = { job: "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt", status: "running" };
        answers["jobs.wait"] = { job: "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt", status: "running" };
        await run("convert_to_webp", { id: src.id, start: 1, end: 4, crop: { x: 0.1, y: 0.2, w: 0.5, h: 0.6 }, width: 320, quality: "high" });
        expect(calls.find((c) => c.name === "make.webp")!.input).toEqual({ id: src.id, start: 1, end: 4, crop: { x: 0.1, y: 0.2, w: 0.5, h: 0.6 }, width: 320, quality: "high" });
        expect(tool("convert_to_webp").input.safeParse({ id: "x", crop: { x: 0, y: 0, w: 0, h: 1 } }).success).toBe(false);
    });

    it("upload_files: the flat single-file form (name, title) and queue are forwarded", async () => {
        answers["upload.begin"] = () => ({ upload_url: "https://api.capybaraharmony.com/mcp/upload/tok.sig", method: "PUT", expires_at: "2025-10-09T00:15:00.000Z", max_bytes: 100_000_000, types: ["video/mp4"], curl: "x" });
        const r = await run("upload_files", { name: "cat.mp4", title: "a cat", public: true, queue: true });
        expect(calls[0]).toEqual({ name: "upload.begin", input: { name: "cat.mp4", title: "a cat", public: true, queue: true } });
        expect(r.out.uploads).toHaveLength(1);
        expect(r.out.uploads[0].name).toBe("cat.mp4");
        // a title without a name is a link too
        await run("upload_files", { title: "only a title" });
        expect(calls.at(-1)!.input).toEqual({ title: "only a title" });
    });

    it("save_link: items, public, title and wait go to library.save; the saves left are said", async () => {
        answers["library.save"] = { save_id: "SaveSessionId000000aXY", status: "downloading", saves_left_today: 7 };
        const r = await run("save_link", { url: "https://x.com/a/status/1", items: [0, 2], public: true, title: "mine", wait: 40, engine: "ytdlp" });
        expect(calls[0]).toEqual({ name: "library.save", input: { url: "https://x.com/a/status/1", wait: 40, items: [0, 2], public: true, title: "mine", engine: "ytdlp" } });
        expect(r.out).toMatchObject({ save_id: "SaveSessionId000000aXY", saves_left_today: 7 });
        expect(r.text).toContain("7 saves left today");
        await run("save_link", { url: "https://x.com/a/status/2", items: "all" });
        expect(calls.at(-1)!.input).toEqual({ url: "https://x.com/a/status/2", wait: 8, items: "all" });
        expect(tool("save_link").input.safeParse({ url: "https://x.com/a", wait: 61 }).success).toBe(false);
        expect(tool("save_link").input.safeParse({ url: "https://x.com/a", items: [] }).success).toBe(false);
    });

    it("job_status: seconds is forwarded (0 to 25); a finished render says its file; a helper's report comes through", async () => {
        const JOB = "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt";
        answers["jobs.wait"] = { job: JOB, status: "queued", queue_ahead: 2 };
        const q = await run("job_status", { job: JOB, seconds: 20 });
        expect(calls[0]!.input).toEqual({ job: JOB, seconds: 20 });
        expect(q.out).toMatchObject({ state: "running", queue_ahead: 2 });
        expect(q.text).toContain("2 jobs ahead");
        expect(tool("job_status").input.safeParse({ job: JOB, seconds: 26 }).success).toBe(false);
        expect(tool("job_status").input.safeParse({ job: JOB, seconds: 0 }).success).toBe(true);

        const made = file({ content_type: "image/webp", name: "m.webp", duration: null, poster: null });
        answers["jobs.wait"] = { job: JOB, status: "done", file_id: made.id, post_id: made.id, kind: "image", bytes: 5000, width: 480, height: 854, seconds: 6.5 };
        const d = await run("job_status", { job: JOB });
        expect(d.out).toMatchObject({ state: "done", file_id: made.id, post_id: made.id, file: { kind: "image", bytes: 5000, width: 480, height: 854, seconds: 6.5 } });
        expect(d.text).toContain(`File: ${made.id} (480x854, 6.5 s)`);

        const AGENT = "agent:Ab3dE6gH9jK2mN5p";
        answers["jobs.wait"] = { job: AGENT, status: "done", agent: "Ab3dE6gH9jK2mN5p", name: "scout", result: "found 3 cats", post_ids: ["p1", "p2"] };
        const a = await run("job_status", { job: AGENT });
        expect(a.out.agent).toMatchObject({ id: "Ab3dE6gH9jK2mN5p", name: "scout", result: "found 3 cats", post_ids: ["p1", "p2"] });
        expect(a.text).toContain("Report: found 3 cats");
        expect(a.text).toContain("Posts it showed: p1, p2");
        answers["jobs.wait"] = { job: AGENT, status: "running", agent: "Ab3dE6gH9jK2mN5p", name: "scout", activity: "library.search" };
        expect((await run("job_status", { job: AGENT })).text).toContain("scout last did: library.search");
    });
});

describe("show_edit: the timeline an agent edits", () => {
    it("carries the raw timeline in structuredContent and text (ids and numbers, no names)", async () => {
        const timeline = { version: 1, canvas: { w: 720, h: 1280, fps: 30 }, main: [{ id: "a", item: "FileX", in: 0, out: 2 }], overlay: [] };
        answers["edits.get"] = { id: "Proj000000000001", title: "Mine", revision: 3, duration: 2, timeline, sources: { FileX: { name: "secret name.mp4", poster_url: "https://media.capybaraharmony.com/x.jpg" } }, render: null };
        const r = await run("show_edit", { id: "Proj000000000001" });
        expect(r.out.project.timeline).toEqual(timeline);
        expect(r.text).toContain(`Timeline (for edits_update):\n${JSON.stringify(timeline)}`);
        // the sources (names, pictures) are not passed on: a hidden post's name must not come through
        expect(JSON.stringify(r.structured)).not.toContain("secret name");
    });
});

// ---- review fixes -------------------------------------------------------------------------------------------------------------

describe("search_library: limits, within and big answers", () => {
    it("within with no limit scores up to 500, not 12; an explicit limit is kept", async () => {
        file({ name: "dog.mp4" });
        offered = new Set(["library.search", "library.list"]);
        answers["library.search"] = [];
        await run("search_library", { query: "dog", within: { collection: "Favourites" } });
        expect(calls.find((c) => c.name === "library.search")!.input.limit).toBe(500);
        calls.length = 0;
        await run("search_library", { query: "dog", within: { collection: "Favourites" }, limit: 7 });
        expect(calls.find((c) => c.name === "library.search")!.input.limit).toBe(7);
        calls.length = 0;
        await run("search_library", { query: "dog" });
        expect(calls.find((c) => c.name === "library.search")!.input.limit).toBe(12);
    });

    it("within without a query is an error, not the whole library", async () => {
        file({ name: "dog.mp4" });
        await expect(run("search_library", { within: { collection: "Cats" } })).rejects.toThrow(/add a query/);
        expect(calls).toHaveLength(0);
    });

    it("counts are right past 400 posts (the read is not capped at 400)", async () => {
        for (let i = 0; i < 450; i++) file({ name: `bulk ${i}.mp4` });
        const r = await run("search_library", { limit: 450 });
        expect(r.out.items).toHaveLength(450);
        expect(r.out.total).toBe(450);
    });
});

describe("create_share_link and list_share_links: review fixes", () => {
    it("an empty title is accepted and means no title", () => {
        expect(tool("create_share_link").input.parse({ ids: "a", title: "" }).title).toBeUndefined();
        expect(tool("create_share_link").input.parse({ ids: "a", title: "x" }).title).toBe("x");
    });

    it("a private link's row prints its direct file urls", async () => {
        const a = file({ name: "a.mp4" });
        set("1000000000000000009", [a.id], { private: true, title: "Mine" });
        answers["links.list"] = [{ id: "1000000000000000009", url: `${SHARE}p/${"k".repeat(22)}`, title: "Mine", private: true, created_at: "2025-10-09T00:00:00.000Z", post_ids: [a.id], file_urls: ["https://api.example/f/one", "https://api.example/f/two"] }];
        answers["collections.list"] = [];
        const r = await run("list_share_links");
        expect(r.text).toContain("files: https://api.example/f/one, https://api.example/f/two");
    });
});

describe("save_link and job_status: a hidden or unreadable saved post", () => {
    const SID = "AbCdEfGhIjKlMnOpQrStUv";

    it("a hidden saved post still prints its id, says hidden and does not advise a share link", async () => {
        const v = file({ post_key: SID, id: "SavedFile000009", name: "h.mp4" });
        hide(SID);
        answers["library.save"] = { status: "ready", save_id: SID, post_id: SID, title: "Secret", kind: "video", files: 1, public: false, error: null, saves_left_today: 9 };
        const r = await run("save_link", { url: "https://www.tiktok.com/@a/video/1" });
        expect(v.id).toBeTruthy();
        expect(r.text).toContain(`post ${SID}, hidden`);
        expect(r.text).not.toContain("share link to send");
        expect(r.out.post).toBeNull();
    });

    it("a post that cannot be read still prints its id, without advice", async () => {
        answers["library.save"] = { status: "ready", save_id: SID, post_id: "GonePost", title: "Gone", kind: "video", files: 1, public: false, error: null, saves_left_today: 9 };
        answers["library.post"] = () => {
            throw new OpError(404, "error.library.not_found");
        };
        const r = await run("save_link", { url: "https://www.tiktok.com/@a/video/1" });
        expect(r.text).toContain("post GonePost");
        expect(r.text).not.toContain("share link to send");
    });

    it("a running job names its id to ask again with", async () => {
        answers["jobs.wait"] = { job: "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt", status: "running", progress: 0.4 };
        const r = await run("job_status", { job: "studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt" });
        expect(r.text).toContain("job studio:AbCdEfGhIjKlMnOpQrStUv:AbCdEfGhIjKlMnOpQrSt");
    });
});
