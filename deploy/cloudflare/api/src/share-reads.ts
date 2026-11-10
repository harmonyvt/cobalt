// What the gallery link routes read, as ONE D1 batch where it used to be one statement after another. D1 lives in one
// region and the Worker often runs far from it, so a route's time is its round trips: GET /share/sets made eight of
// them. A batch is one round trip and one snapshot. Free of Cloudflare imports (the tests run it under node).
//
// The statements here ask what helpers in other modules ask, each of which awaits its own statement:
//   the rows      rowsById (share-sets.ts)
//   the link      liveLinksFor (private-links.ts; its statement for a batch is liveLinksInStmt there)
//   the gate      postKeysOfFiles + hiddenRows, as hiddenFileIds and shareGate use them (hidden-store.ts)
//   new links     newLinksSetting (private-links.ts)
// Those helpers forgive a database without a newer migration (no private_links, no share_settings). A batch cannot: one
// failing statement fails all of them. So every reader here answers null when the database has no batch() (the tests'
// plain fake) or the batch failed, and its caller then takes the sequential path it always took, which forgives as
// before. test/share-reads.test.ts holds the two paths to the same answers.
import { hiddenReady, NOT_HIDDEN_SQL } from "./hidden-store";
import { POST_KEY_SQL } from "./post-key";
import { liveLinksInStmt, type NewLinks, type PrivateLinkRow } from "./private-links";
import type { SetRow } from "./share-sets";
import { ITEM_COLUMNS, type MediaRow } from "./visibility";

// The statements' results, in order, or null: no batch() on this database, or the batch failed (nothing was applied).
export async function tryBatch(db: D1Database, statements: D1PreparedStatement[]): Promise<D1Result<unknown>[] | null> {
    if (typeof (db as { batch?: unknown }).batch !== "function") return null;
    try {
        return await db.batch(statements);
    } catch {
        return null;
    }
}

// Statements that only read, in one round trip; one after another on a database without batch(), or when the batch
// failed. These are statements whose callers forgive nothing, so the second try fails the same way if D1 is why.
export async function readTogether(db: D1Database, statements: D1PreparedStatement[]): Promise<D1Result<unknown>[]> {
    const together = await tryBatch(db, statements);
    if (together) return together;
    const out: D1Result<unknown>[] = [];
    for (const s of statements) out.push(await s.all());
    return out;
}

// statement `i`'s rows
export const rowsOf = <T>(res: D1Result<unknown>[], i: number): T[] => (res[i]?.results ?? []) as T[];

// ---- the statements, each over a list of ids given as SQL ---------------------------------------------------------------

// the ids of one bound JSON list
const BOUND = "SELECT value FROM json_each(?1)";
const ITEM_COLS = ITEM_COLUMNS.split(", ")
    .map((c) => `m.${c}`)
    .join(", ");
// rowsById: the live rows of these files; a hidden post's files are left out while migration 0025 is applied
const rowsSql = (ids: string, notHidden: string) => `SELECT ${ITEM_COLS} FROM media_items m WHERE m.id IN (${ids}) AND m.deleted_at IS NULL${notHidden}`;
// liveLinksFor: the live private link of one gallery link
const linkOf = (db: D1Database, setId: string) => liveLinksInStmt(db, "set", BOUND, [JSON.stringify([setId])]);
// postKeysOfFiles and hiddenRows in one: each live file named by its id or its public copy's id, its post, and that
// post's state in media_hidden (NULL: none)
const gateSql = (ids: string) =>
    `SELECT m.id AS id, m.public_id AS public_id, ${POST_KEY_SQL} AS post_key,
            (SELECT h.state FROM media_hidden h WHERE h.post_key = ${POST_KEY_SQL}) AS state
       FROM media_items m
      WHERE m.deleted_at IS NULL AND (m.id IN (${ids}) OR m.public_id IN (${ids}))`;

type GateRow = { id: string; public_id: string | null; post_key: string; state: string | null };
type Gate = { post: Map<string, string>; state: Map<string, string> };

// An id's post is its own row's; an id that is only some row's public copy takes that row's (postKeysOfFiles).
function gateOf(rows: GateRow[]): Gate {
    const post = new Map<string, string>();
    const state = new Map<string, string>();
    for (const r of rows) {
        post.set(r.id, r.post_key);
        if (r.public_id && !post.has(r.public_id)) post.set(r.public_id, r.post_key);
        if (r.state) state.set(r.post_key, r.state);
    }
    return { post, state };
}

// hiddenFileIds: the ones of these ids whose post is hidden, in the order given
const hiddenAmong = (ids: string[], g: Gate): string[] => [...new Set(ids)].filter((id) => g.state.get(g.post.get(id) ?? "") === "hidden");

// shareGate's other half: a post held for an about rule (section 37.3) stops waiting once its file is shared by hand
async function forgetHeld(db: D1Database, g: Gate): Promise<void> {
    const held = [...new Set(g.post.values())].filter((key) => g.state.get(key) === "held");
    if (held.length === 0) return;
    await db.prepare("DELETE FROM media_hidden WHERE state = 'held' AND post_key IN (SELECT value FROM json_each(?1))").bind(JSON.stringify(held)).run();
}

const byId = (rows: MediaRow[]) => new Map(rows.map((r) => [r.id, r]));
const json = (ids: string[]) => JSON.stringify([...new Set(ids)]);

// ---- the readers ----------------------------------------------------------------------------------------------------------

export type SetParts = { rows: Map<string, MediaRow>; link: PrivateLinkRow | null; hidden: string[] };

// One gallery link as the list shows it: its files' live rows, its live private link, which of its files are hidden.
export async function readSetParts(db: D1Database, setId: string, ids: string[]): Promise<SetParts | null> {
    const gated = await hiddenReady(db);
    const res = await tryBatch(db, [
        db.prepare(rowsSql(BOUND, gated ? NOT_HIDDEN_SQL : "")).bind(json(ids)),
        linkOf(db, setId),
        ...(gated ? [db.prepare(gateSql(BOUND)).bind(json(ids))] : []),
    ]);
    if (!res) return null;
    return {
        rows: byId(rowsOf<MediaRow>(res, 0)),
        link: rowsOf<PrivateLinkRow>(res, 1)[0] ?? null,
        hidden: gated ? hiddenAmong(ids, gateOf(rowsOf<GateRow>(res, 2))) : [],
    };
}

export type SetList = { sets: SetRow[]; rows: Map<string, MediaRow>; links: Map<string, PrivateLinkRow>; hidden: (ids: string[]) => string[] };

// GET /share/sets: the newest `limit` live links with everything the list says about them, in one round trip. The
// other statements name the same links by repeating the list as a subquery, so nothing has to come back first. A link
// whose `items` is not JSON fails json_each and with it the batch: the sequential path reads such a row as no files.
export async function readSetList(db: D1Database, limit: number): Promise<SetList | null> {
    const gated = await hiddenReady(db);
    const live = `SELECT id, items, title, created_at, revoked_at FROM share_sets WHERE revoked_at IS NULL ORDER BY created_at DESC, id DESC LIMIT ${limit}`;
    const files = `SELECT j.value FROM (${live}) l, json_each(l.items) j`;
    const res = await tryBatch(db, [
        db.prepare(live),
        db.prepare(rowsSql(files, gated ? NOT_HIDDEN_SQL : "")),
        liveLinksInStmt(db, "set", `SELECT l.id FROM (${live}) l`, []),
        ...(gated ? [db.prepare(gateSql(files))] : []),
    ]);
    if (!res) return null;
    const links = new Map<string, PrivateLinkRow>();
    for (const r of rowsOf<PrivateLinkRow>(res, 2)) links.set(r.target_id, r);
    const gate = gated ? gateOf(rowsOf<GateRow>(res, 3)) : null;
    return {
        sets: rowsOf<SetRow>(res, 0),
        rows: byId(rowsOf<MediaRow>(res, 1)),
        links,
        hidden: (ids) => (gate ? hiddenAmong(ids, gate) : []),
    };
}

export type NewSetChecks = { hidden: string[]; newLinks: NewLinks | null; rows: Map<string, MediaRow> };

// POST /share/sets: may these files be shared (shareGate), does a new link start private (asked only when the request
// does not say), and the files' rows.
export async function readForNewSet(db: D1Database, ids: string[], askNewLinks: boolean): Promise<NewSetChecks | null> {
    const gated = await hiddenReady(db);
    const statements = [db.prepare(rowsSql(BOUND, gated ? NOT_HIDDEN_SQL : "")).bind(json(ids))];
    const gateAt = gated ? statements.push(db.prepare(gateSql(BOUND)).bind(json(ids))) - 1 : -1;
    const settingAt = askNewLinks ? statements.push(db.prepare("SELECT new_links FROM share_settings WHERE id = 1")) - 1 : -1;
    const res = await tryBatch(db, statements);
    if (!res) return null;
    const gate = gateAt < 0 ? null : gateOf(rowsOf<GateRow>(res, gateAt));
    if (gate) await forgetHeld(db, gate);
    return {
        hidden: gate ? hiddenAmong(ids, gate) : [],
        newLinks: settingAt < 0 ? null : rowsOf<{ new_links: string }>(res, settingAt)[0]?.new_links === "private" ? "private" : "public",
        rows: byId(rowsOf<MediaRow>(res, 0)),
    };
}

export type AddChecks = { hidden: string[]; rows: Map<string, MediaRow>; isPrivate: boolean };

// PATCH /share/sets/<id> with new files: may the added ones be shared (shareGate), the rows of the whole new list, and
// whether the link is private (a private link takes files that are not public).
export async function readForAdd(db: D1Database, setId: string, added: string[], next: string[]): Promise<AddChecks | null> {
    const gated = await hiddenReady(db);
    const res = await tryBatch(db, [
        db.prepare(rowsSql(BOUND, gated ? NOT_HIDDEN_SQL : "")).bind(json(next)),
        linkOf(db, setId),
        ...(gated ? [db.prepare(gateSql(BOUND)).bind(json(added))] : []),
    ]);
    if (!res) return null;
    const gate = gated ? gateOf(rowsOf<GateRow>(res, 2)) : null;
    if (gate) await forgetHeld(db, gate);
    return {
        hidden: gate ? hiddenAmong(added, gate) : [],
        rows: byId(rowsOf<MediaRow>(res, 0)),
        isPrivate: rowsOf<PrivateLinkRow>(res, 1).length > 0,
    };
}
