// Shared by the gallery tests (APP-API-CONTRACT.md section 18): a post of N items as the fake helper resolves it, a
// save of it through the Worker to its end, and the rows it leaves.
import { asBody, auth, json, type World } from "./poster-world";
import type { GalleryItemSpec } from "./studio-fakes";

export const POST = "https://www.instagram.com/p/Ddy0-gpGg5U/";
export const photos = (n: number): GalleryItemSpec[] => Array.from({ length: n }, () => ({ type: "photo" }));

// POST /studio through the Worker (so the gate and the key are in the picture), then the save to its end.
export async function saveGallery(world: World, specs: GalleryItemSpec[] | null, body: Record<string, unknown> = {}, settle = true) {
    if (specs) world.helper.gallery = specs;
    const res = await world.call("/studio", {
        method: "POST",
        headers: { ...auth, "content-type": "application/json" },
        body: json({ url: POST, items: "all", ...(specs ? { item_count: specs.length } : {}), ...body }),
    });
    const created = (await res.json()) as any;
    if (res.status !== 201 || !settle) return { res, created, sid: created.id as string, done: null as any };
    const done = asBody(await world.settle(created.id));
    return { res, created, sid: created.id as string, done };
}
export const itemRows = (w: World, sid: string) =>
    w.db.raw.prepare("SELECT * FROM media_items WHERE session_id = ? AND role = 'item' ORDER BY item_index").all(sid) as any[];
