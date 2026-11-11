// Demo data for the local MCP dev server: a seeded library on the real migrations (node:sqlite), plus the pictures the
// dev server draws for it. Demo only: nothing here touches the real library.
import type { FakeD1 } from "../../test-support/d1-sqlite";

const SIGN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export const randomId = (n: number) => Array.from({ length: n }, () => SIGN[Math.floor(Math.random() * SIGN.length)]).join("");

export type Seeded = {
    keyId: string;
    // the rendered edit's post and the long video (for the webp picker)
    ids: Record<string, string>;
    editProjects: EditProject[];
};

export type EditProject = {
    id: string;
    title: string;
    revision: number;
    duration: number;
    render: Record<string, unknown> | null;
    timeline: Record<string, unknown>;
    sources: Record<string, unknown>;
};

type Item = {
    key: string; // the file's public name without extension
    title: string;
    type: "video" | "image" | "webp";
    secs?: number;
    visibility?: "public" | "private";
    link?: string | null;
    hoursAgo: number;
    post?: string; // post key (a gallery's files share one)
    role?: string;
    index?: number;
    w?: number;
    h?: number;
};

export function seedDemo(db: FakeD1, o: { mediaBase: string; shareBase: string; now: number; keyId: string }): Seeded {
    const { mediaBase: MEDIA, now } = o;
    const ids: Record<string, string> = {};
    const fileId = (key: string) => `Demo${key}`.padEnd(16, "0").slice(0, 16);
    const ext = { video: "mp4", image: "jpg", webp: "webp" } as const;
    const ctype = { video: "video/mp4", image: "image/jpeg", webp: "image/webp" } as const;

    const add = (it: Item) => {
        const id = fileId(it.key);
        ids[it.key] = id;
        const pub = (it.visibility ?? "public") === "public";
        const name = `${it.key}.${ext[it.type]}`;
        const poster = it.type === "video" ? `${MEDIA}Poster${it.key}.jpg` : null;
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, poster, visibility, post_key, role, item_index)
                 VALUES (?, ?, 'saved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            )
            .run(
                id,
                pub ? "public" : "private",
                pub ? "media" : "originals",
                pub ? name : `originals/${id}.${ext[it.type]}`,
                pub ? `${MEDIA}${name}` : null,
                `${it.title.toLowerCase().replace(/[^a-z0-9]+/g, "-")}.${ext[it.type]}`,
                ctype[it.type],
                it.type === "video" ? 2_400_000 : 180_000,
                it.w ?? (it.type === "video" ? 720 : 1080),
                it.h ?? (it.type === "video" ? 1280 : 1350),
                it.type === "video" ? (it.secs ?? 10) : null,
                it.link === undefined ? null : it.link,
                o.keyId,
                now - it.hoursAgo * 3_600_000,
                poster,
                pub ? "public" : "private",
                it.post ?? id,
                it.role ?? null,
                it.index ?? null,
            );
        db.raw.prepare("INSERT OR REPLACE INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, ?, ?)").run(it.post ?? id, it.title, o.keyId, now);
        return id;
    };

    add({ key: "CatGlass0001", title: "Cat knocks a glass off the counter", type: "video", secs: 9.6, link: "https://www.tiktok.com/@catsdaily/video/7301", hoursAgo: 3 });
    add({ key: "BaySunset002", title: "Sunset timelapse over the bay", type: "video", secs: 42, link: "https://www.youtube.com/watch?v=bayset", hoursAgo: 5 });
    add({ key: "Kickflip0003", title: "Skater lands a kickflip", type: "video", secs: 14, link: "https://x.com/skatepark/status/1203", hoursAgo: 9 });
    add({ key: "DancePrac004", title: "Dance practice, take three", type: "video", secs: 27, link: "https://www.instagram.com/reel/Cdance/", hoursAgo: 14 });
    add({ key: "Pancake00005", title: "Pancake flip goes wrong", type: "video", secs: 6.2, link: "https://www.tiktok.com/@kitchen/video/9001", hoursAgo: 20 });
    add({ key: "Corgi0000006", title: "Corgi discovers snow", type: "image", link: "https://x.com/dogs/status/77", hoursAgo: 26 });
    add({ key: "Ramen0000007", title: "Ramen bowl, close up", type: "image", link: null, hoursAgo: 30 });
    add({ key: "RainLoop0008", title: "Rainy window loop", type: "video", secs: 11.5, link: "https://www.youtube.com/watch?v=rainy", hoursAgo: 40 });
    add({ key: "NeonStreet009", title: "Neon street at night", type: "image", link: null, hoursAgo: 50 });
    add({ key: "Jumpscare010", title: "Jumpscare compilation (render)", type: "video", secs: 20, link: null, hoursAgo: 60 });
    // a gallery of three pictures
    const gal = fileId("Lisbon00011");
    ids.Lisbon = gal;
    ["a", "b", "c"].forEach((s, i) => add({ key: `Lisbon0001${s}`, title: "Trip to Lisbon", type: "image", link: "https://www.instagram.com/p/Clisbon/", hoursAgo: 72, post: gal, role: "item", index: i }));
    // one private post (with its own private link), one hidden post
    const priv = add({ key: "Receipt00012", title: "Receipt scan (private)", type: "image", visibility: "private", hoursAgo: 80 });
    db.raw
        .prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at, opened, last_opened_at) VALUES (?, 'item', ?, ?, NULL, 0, NULL)")
        .run("PrivDemoKeyReceipt00012".slice(0, 22), priv, now);
    const hidden = add({ key: "Hidden000013", title: "Hidden draft clip", type: "video", secs: 8, hoursAgo: 90 });
    db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'hidden', 'you', NULL, ?)").run(hidden, now);

    // three share links and two collections
    const set = (id: string, items: string[], title: string | null, ago: number) =>
        db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, NULL)").run(id, JSON.stringify(items), title, o.keyId, now - ago * 3_600_000);
    set("CatsAndSkate", [ids.CatGlass0001!, ids.Kickflip0003!], "Cat and skater", 2);
    set("LisbonTrip01", [ids.Lisbon0001a!, ids.Lisbon0001b!, ids.Lisbon0001c!], "Lisbon trip", 8);
    set("QuietLinkOne", [ids.Corgi0000006!, ids.Ramen0000007!], null, 12);
    db.raw
        .prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at, opened, last_opened_at) VALUES (?, 'set', ?, ?, NULL, 0, NULL)")
        .run("PrivDemoSetKeyQuietLink".slice(0, 22), "QuietLinkOne", now);
    const col = (id: string, name: string, sets: string[]) => {
        db.raw.prepare("INSERT INTO share_collections (id, name, key_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)").run(id, name, o.keyId, now, now);
        sets.forEach((s, i) => db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?, ?, ?)").run(id, s, now + (sets.length - i)));
    };
    col("ColFunnyClips01", "Funny clips", ["CatsAndSkate", "QuietLinkOne"]);
    col("ColTravel00002", "Travel", ["LisbonTrip01"]);

    // two editor projects: one rendered, one with overlays
    const src = (key: string, name: string, kind: string, duration: number | null, poster: boolean) => ({
        id: ids[key]!,
        name,
        kind,
        duration,
        poster_url: poster ? `${MEDIA}Poster${key}.jpg` : null,
    });
    const sources = {
        [ids.CatGlass0001!]: src("CatGlass0001", "cat-glass.mp4", "video", 9.6, true),
        [ids.Kickflip0003!]: src("Kickflip0003", "kickflip.mp4", "video", 14, true),
        [ids.DancePrac004!]: src("DancePrac004", "dance.mp4", "video", 27, true),
        [ids.RainLoop0008!]: src("RainLoop0008", "rain.mp4", "video", 11.5, true),
        [ids.Corgi0000006!]: src("Corgi0000006", "corgi-cutout.png", "photo", null, false),
    };
    const canvas = { w: 1080, h: 1920, fps: 30 };
    const clip = (id: string, key: string, from: number, to: number, speed = 1, muted = false) => ({ id, item: ids[key], in: from, out: to, speed, fit: "fit", volume: 1, muted });
    const editProjects: EditProject[] = [
        {
            id: "EdMontage000001a",
            title: "Friday montage",
            revision: 4,
            duration: 17.4,
            render: { id: "RenderDemo01", status: "done", revision: 4, progress: 1, item_id: ids.Jumpscare010, poster_url: `${MEDIA}PosterJumpscare010.jpg` },
            timeline: {
                version: 1,
                canvas,
                main: [clip("c1", "CatGlass0001", 0, 6), clip("c2", "Kickflip0003", 2, 10, 1), clip("c3", "RainLoop0008", 0, 6.8, 2, true)],
                overlay: [],
            },
            sources,
        },
        {
            id: "EdOverlays000002",
            title: "Dance cut with stickers",
            revision: 2,
            duration: 18,
            render: null,
            timeline: {
                version: 1,
                canvas,
                main: [clip("c1", "DancePrac004", 3, 15), clip("c2", "CatGlass0001", 0, 9.6, 1.6, true)],
                overlay: [
                    { id: "o1", item: ids.Corgi0000006, at: 2, in: 0, out: 4, frame: { x: 0, y: 0, w: 0.4 }, opacity: 1, volume: 1, muted: true },
                    { id: "o2", item: ids.RainLoop0008, at: 8, in: 0, out: 3.5, frame: { x: 0.5, y: 0, w: 0.5 }, opacity: 0.8, volume: 0, muted: true },
                ],
            },
            sources,
        },
    ];
    return { keyId: o.keyId, ids, editProjects };
}

// ---- pictures -------------------------------------------------------------------------------------------------------

const hueOf = (s: string) => [...s].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

function wrap(text: string, per: number): string[] {
    const lines: string[] = [];
    let line = "";
    for (const w of text.split(/\s+/)) {
        if ((line + " " + w).trim().length > per && line) {
            lines.push(line);
            line = w;
        } else line = (line + " " + w).trim();
    }
    if (line) lines.push(line);
    return lines.slice(0, 4);
}

// A placeholder picture drawn on the fly: a gradient from the name, the post's title, and a play mark for a video.
export function placeholderSvg(o: { name: string; title: string; kind: "video" | "image" | "webp"; secs?: number | null; w?: number; h?: number }): string {
    const w = 540;
    const h = o.kind === "image" ? 675 : 960;
    const hue = hueOf(o.name);
    const lines = wrap(o.title, 18);
    const text = lines.map((l, i) => `<text x="${w / 2}" y="${h / 2 + 80 + i * 44}" text-anchor="middle" font-family="system-ui,sans-serif" font-size="36" font-weight="700" fill="#fff">${esc(l)}</text>`).join("");
    const play = o.kind === "video" ? `<circle cx="${w / 2}" cy="${h / 2 - 40}" r="62" fill="#0006"/><path d="M${w / 2 - 20} ${h / 2 - 78}l56 38-56 38z" fill="#fff"/>` : "";
    const badge = o.kind === "video" && o.secs ? `<rect x="${w - 112}" y="${h - 58}" width="92" height="38" rx="9" fill="#000a"/><text x="${w - 66}" y="${h - 31}" text-anchor="middle" font-family="system-ui,sans-serif" font-size="24" fill="#fff">0:${String(Math.round(o.secs)).padStart(2, "0")}</text>` : "";
    // an animated mark so a webp looks like it moves
    const anim =
        o.kind === "webp"
            ? `<circle r="38" cy="${h / 2 - 40}" fill="#fff8"><animate attributeName="cx" values="120;${w - 120};120" dur="1.6s" repeatCount="indefinite"/></circle>`
            : "";
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue} 70% 52%)"/><stop offset="1" stop-color="hsl(${(hue + 60) % 360} 65% 28%)"/></linearGradient></defs><rect width="${w}" height="${h}" fill="url(#g)"/>${play}${anim}${text}${badge}</svg>`;
}
