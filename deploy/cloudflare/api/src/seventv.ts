// 7TV accounts (APP-API-CONTRACT.md section 57): one linked 7TV login, and the emote sets of its own channel and of
// every channel that made it an editor. Everything goes through 7TV's v4 GraphQL with the stored session token. The
// queries and mutations are pinned from 7TV's own `schema.graphql` (57.3).
//
// 7TV has no third-party sign-in: the token is the session JWT 7tv.app keeps in localStorage ("7tv-token"). It lasts
// 30 days from login. An invalid or expired one is an HTTP 401 before GraphQL runs; the row then goes to "relink".

import { pickWebp, previewWebp, type EmoteImage } from "./emotes";
import type { StudioReply } from "./studio";

export const SEVENTV_GQL = "https://7tv.io/v4/gql";
const CDN_HOST = "cdn.7tv.app";
export const SEVENTV_ID = /^[0-9A-Za-z]{20,32}$/;
const TOKEN_SHAPE = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const TOKEN_MAX = 4096;
const SESSION_MS = 30 * 24 * 3600_000;
export const SET_PAGE = 60;
export const NAME_MAX = 100;

export type SevenTvDeps = {
    db: D1Database;
    now: () => number;
    // HKDF base for the stored token (COBALT_API_KEY)
    secret: string;
    fetch?: typeof fetch;
};

type Row = {
    user_id: string;
    name: string;
    avatar_url: string | null;
    token: string;
    expires_at: number | null;
    linked_at: number;
    status: string;
};

const enc = new TextEncoder();

const reply = (status: number, body: Record<string, unknown>): StudioReply => ({ status, body });
const success = (body: Record<string, unknown>, status = 200): StudioReply => reply(status, { status: "success", ...body });
export const fail = (status: number, code: string, message?: string): StudioReply =>
    reply(status, { status: "error", error: { code }, ...(message ? { message } : {}) });

// ---- the stored token: AES-GCM, key = HKDF-SHA-256 of COBALT_API_KEY ----------------------------------------------------

const b64 = (b: Uint8Array): string => {
    let s = "";
    for (const x of b) s += String.fromCharCode(x);
    return btoa(s);
};
const unb64 = (s: string): Uint8Array => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function tokenKey(secret: string): Promise<CryptoKey> {
    const base = await crypto.subtle.importKey("raw", enc.encode(secret), "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: enc.encode("seventv-token") },
        base,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt", "decrypt"],
    );
}

export async function sealToken(secret: string, plain: string): Promise<string> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await tokenKey(secret), enc.encode(plain)));
    return `${b64(iv)}.${b64(ct)}`;
}

export async function openToken(secret: string, stored: string): Promise<string> {
    const [iv, ct] = stored.split(".");
    if (!iv || !ct) throw new Error("bad token format");
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await tokenKey(secret), unb64(ct));
    return new TextDecoder().decode(plain);
}

// The JWT's exp in ms, unverified (display only). Null when it has none.
export function tokenExpiry(token: string): number | null {
    try {
        const part = token.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/");
        const json = JSON.parse(atob(part + "===".slice((part.length + 3) % 4))) as { exp?: unknown };
        return typeof json.exp === "number" && Number.isFinite(json.exp) ? json.exp * 1000 : null;
    } catch {
        return null;
    }
}

// The token as 7tv.app stores it may be JSON-quoted; trim that and whitespace.
export function cleanToken(raw: unknown): string | null {
    if (typeof raw !== "string") return null;
    const t = raw.trim().replace(/^"+|"+$/g, "").replace(/^Bearer\s+/i, "");
    return t.length > 0 && t.length <= TOKEN_MAX && TOKEN_SHAPE.test(t) ? t : null;
}

// ---- talking to 7TV ----------------------------------------------------------------------------------------------------

export class SevenTvError extends Error {
    constructor(readonly reply: StudioReply, readonly relink = false) {
        super(String((reply.body as { error?: { code?: string } }).error?.code));
    }
}

type GqlError = { message?: unknown; extensions?: { status?: unknown; code?: unknown; message?: unknown } };

const errorFor = (e: GqlError): StudioReply => {
    const status = typeof e.extensions?.status === "number" ? e.extensions.status : 400;
    const msg =
        typeof e.extensions?.message === "string" ? e.extensions.message : typeof e.message === "string" ? e.message : undefined;
    if (status === 401) return fail(409, "error.seventv.relink");
    if (status === 403) return fail(403, "error.seventv.forbidden", msg);
    if (status === 404) return fail(404, "error.seventv.not_found", msg);
    if (status === 429) return fail(429, "error.seventv.rate_limited", msg);
    if (status >= 500) return fail(502, "error.seventv.unavailable");
    return fail(400, "error.seventv.rejected", msg);
};

export async function gql<T>(d: SevenTvDeps, token: string, query: string, variables: Record<string, unknown> = {}): Promise<T> {
    const f = d.fetch ?? fetch;
    let res: Response;
    try {
        res = await f(SEVENTV_GQL, {
            method: "POST",
            headers: { "content-type": "application/json", accept: "application/json", authorization: `Bearer ${token}` },
            body: JSON.stringify({ query, variables }),
            signal: AbortSignal.timeout(20_000),
        });
    } catch {
        throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    }
    if (res.status === 401) throw new SevenTvError(fail(409, "error.seventv.relink"), true);
    if (res.status === 429) throw new SevenTvError(fail(429, "error.seventv.rate_limited"));
    let body: { data?: unknown; errors?: GqlError[] };
    try {
        body = (await res.json()) as typeof body;
    } catch {
        throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    }
    if (Array.isArray(body.errors) && body.errors.length > 0) {
        const r = errorFor(body.errors[0]!);
        throw new SevenTvError(r, (r.body as { error: { code: string } }).error.code === "error.seventv.relink");
    }
    if (!res.ok || body.data == null) throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    return body.data as T;
}

// ---- the queries and mutations (57.3) ------------------------------------------------------------------------------------

const CONN = "mainConnection { platformDisplayName platformAvatarUrl }";
const ME = `query { users { me { id ${CONN} style { activeEmoteSetId }
  editorFor { state userId permissions { superAdmin emoteSet { manage create } user { manageProfile } }
    user { id ${CONN} style { activeEmoteSetId } } } } } }`;
const SETS = `query($id: Id!) { users { user(id: $id) { id style { activeEmoteSetId }
  ownedEmoteSets { id name kind capacity emotes(page: 1, perPage: 1) { totalCount } } } } }`;
const IMG = "images { url mime size scale width height frameCount }";
const SET = `query($id: Id!, $q: String, $page: Int!, $perPage: Int!) { emoteSets { emoteSet(id: $id) { id name kind capacity ownerId
  owner { id style { activeEmoteSetId } }
  emotes(query: $q, page: $page, perPage: $perPage) { totalCount pageCount
    items { id alias addedAt emote { id defaultName flags { animated } ${IMG} } } } } } }`;
const ADD = `mutation($set: Id!, $e: EmoteSetEmoteId!, $over: Boolean) { emoteSets { emoteSet(id: $set) {
  addEmote(id: $e, overrideConflicts: $over) { id } } } }`;
const REMOVE = `mutation($set: Id!, $e: EmoteSetEmoteId!) { emoteSets { emoteSet(id: $set) { removeEmote(id: $e) { id } } } }`;
const ALIAS = `mutation($set: Id!, $e: EmoteSetEmoteId!, $alias: String!) { emoteSets { emoteSet(id: $set) {
  updateEmoteAlias(id: $e, alias: $alias) { alias } } } }`;
const RENAME_SET = `mutation($set: Id!, $name: String!) { emoteSets { emoteSet(id: $set) { name(name: $name) { id name capacity } } } }`;
const CREATE_SET = `mutation($name: String!, $owner: Id) { emoteSets { create(name: $name, tags: [], ownerId: $owner) { id name capacity } } }`;
const LIVE = `mutation($user: Id!, $set: Id) { users { user(id: $user) { activeEmoteSet(emoteSetId: $set) { id style { activeEmoteSetId } } } } }`;

type Conn = { platformDisplayName?: string; platformAvatarUrl?: string | null } | null;
type MeUser = { id: string; mainConnection: Conn; style?: { activeEmoteSetId?: string | null } };
type Editor = {
    state: string;
    userId: string;
    permissions: { superAdmin: boolean; emoteSet: { manage: boolean; create: boolean }; user: { manageProfile: boolean } };
    user: MeUser | null;
};
type Me = { users: { me: (MeUser & { editorFor: Editor[] }) | null } };

const nameOf = (u: MeUser) => u.mainConnection?.platformDisplayName?.trim() || u.id;
const avatarOf = (u: MeUser) => {
    const a = u.mainConnection?.platformAvatarUrl;
    return typeof a === "string" && a.startsWith("https://") ? a : null;
};

export type Channel = {
    id: string;
    name: string;
    avatar_url: string | null;
    you: boolean;
    active_set_id: string | null;
    can: { manage_sets: boolean; create_sets: boolean; make_live: boolean };
};

export function channelsOf(me: MeUser & { editorFor: Editor[] }): Channel[] {
    const own: Channel = {
        id: me.id,
        name: nameOf(me),
        avatar_url: avatarOf(me),
        you: true,
        active_set_id: me.style?.activeEmoteSetId ?? null,
        can: { manage_sets: true, create_sets: true, make_live: true },
    };
    const edited = (me.editorFor ?? [])
        .filter((e) => e.state === "ACCEPTED" && e.user && e.user.id !== me.id)
        .map((e): Channel => {
            const p = e.permissions;
            return {
                id: e.user!.id,
                name: nameOf(e.user!),
                avatar_url: avatarOf(e.user!),
                you: false,
                active_set_id: e.user!.style?.activeEmoteSetId ?? null,
                can: {
                    manage_sets: p.superAdmin || p.emoteSet.manage,
                    create_sets: p.superAdmin || p.emoteSet.create,
                    make_live: p.superAdmin || p.user.manageProfile,
                },
            };
        })
        .sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
    return [own, ...edited];
}

// ---- the stored account ------------------------------------------------------------------------------------------------

async function readRow(d: SevenTvDeps): Promise<Row | null | "missing"> {
    try {
        return (
            (await d.db
                .prepare("SELECT user_id, name, avatar_url, token, expires_at, linked_at, status FROM seventv_account WHERE id = 'main'")
                .first<Row>()) ?? null
        );
    } catch {
        return "missing";
    }
}

const accountShape = (r: Row, status = r.status) => ({
    id: r.user_id,
    name: r.name,
    avatar_url: r.avatar_url,
    linked_at: r.linked_at,
    expires_at: r.expires_at,
    status,
});

async function markRelink(d: SevenTvDeps): Promise<void> {
    await d.db
        .prepare("UPDATE seventv_account SET status = 'relink', status_at = ?1 WHERE id = 'main' AND status != 'relink'")
        .bind(d.now())
        .run()
        .catch(() => {});
}

// The token to call 7TV with, or the reply that says why there is none.
async function session(d: SevenTvDeps): Promise<{ row: Row; token: string } | StudioReply> {
    const row = await readRow(d);
    if (row === "missing") return fail(503, "error.seventv.not_ready");
    if (!row) return fail(409, "error.seventv.not_linked");
    if (row.status === "relink") return fail(409, "error.seventv.relink");
    try {
        return { row, token: await openToken(d.secret, row.token) };
    } catch {
        await markRelink(d);
        return fail(409, "error.seventv.relink");
    }
}

const isReply = (v: unknown): v is StudioReply => !!v && typeof v === "object" && "status" in v && "body" in v;

// Runs `fn` with the token; a 7TV refusal becomes its reply, and a dead session marks the row.
export async function withToken(d: SevenTvDeps, fn: (token: string, row: Row) => Promise<StudioReply>): Promise<StudioReply> {
    const s = await session(d);
    if (isReply(s)) return s;
    try {
        return await fn(s.token, s.row);
    } catch (e) {
        if (e instanceof SevenTvError) {
            if (e.relink) await markRelink(d);
            return e.reply;
        }
        throw e;
    }
}

// ---- the routes (57.4) ---------------------------------------------------------------------------------------------------

export async function sevenTvStatus(d: SevenTvDeps): Promise<StudioReply> {
    const row = await readRow(d);
    if (row === "missing") return fail(503, "error.seventv.not_ready");
    if (!row) return success({ linked: false });
    if (row.status === "relink") return success({ linked: true, account: accountShape(row), channels: [] });
    let token: string;
    try {
        token = await openToken(d.secret, row.token);
    } catch {
        await markRelink(d);
        return success({ linked: true, account: accountShape(row, "relink"), channels: [] });
    }
    try {
        const data = await gql<Me>(d, token, ME);
        const me = data.users?.me;
        if (!me) {
            await markRelink(d);
            return success({ linked: true, account: accountShape(row, "relink"), channels: [] });
        }
        return success({ linked: true, account: accountShape(row), channels: channelsOf(me) });
    } catch (e) {
        if (e instanceof SevenTvError && e.relink) {
            await markRelink(d);
            return success({ linked: true, account: accountShape(row, "relink"), channels: [] });
        }
        if (e instanceof SevenTvError) return e.reply;
        throw e;
    }
}

export async function sevenTvLink(d: SevenTvDeps, body: { token?: unknown }): Promise<StudioReply> {
    if ((await readRow(d)) === "missing") return fail(503, "error.seventv.not_ready");
    const token = cleanToken(body.token);
    if (!token) return fail(400, "error.seventv.token_invalid");
    let me: Me["users"]["me"];
    try {
        me = (await gql<Me>(d, token, ME)).users?.me ?? null;
    } catch (e) {
        if (e instanceof SevenTvError) {
            return e.relink ? fail(400, "error.seventv.token_invalid") : e.reply;
        }
        throw e;
    }
    if (!me) return fail(400, "error.seventv.token_invalid");
    const now = d.now();
    const row: Row = {
        user_id: me.id,
        name: nameOf(me),
        avatar_url: avatarOf(me),
        token: await sealToken(d.secret, token),
        expires_at: tokenExpiry(token) ?? now + SESSION_MS,
        linked_at: now,
        status: "ok",
    };
    await d.db
        .prepare(
            `INSERT INTO seventv_account (id, user_id, name, avatar_url, token, expires_at, linked_at, status, status_at)
             VALUES ('main', ?1, ?2, ?3, ?4, ?5, ?6, 'ok', ?6)
             ON CONFLICT (id) DO UPDATE SET user_id = excluded.user_id, name = excluded.name, avatar_url = excluded.avatar_url,
               token = excluded.token, expires_at = excluded.expires_at, linked_at = excluded.linked_at, status = 'ok',
               status_at = excluded.status_at`,
        )
        .bind(row.user_id, row.name, row.avatar_url, row.token, row.expires_at, now)
        .run();
    return success({ linked: true, account: accountShape(row), channels: channelsOf(me) });
}

export async function sevenTvUnlink(d: SevenTvDeps): Promise<StudioReply> {
    if ((await readRow(d)) === "missing") return fail(503, "error.seventv.not_ready");
    await d.db.prepare("DELETE FROM seventv_account WHERE id = 'main'").run();
    return success({ linked: false });
}

type RawSet = { id: string; name: string; kind: string; capacity: number | null; emotes?: { totalCount?: number } };

export async function sevenTvChannelSets(d: SevenTvDeps, channelId: string): Promise<StudioReply> {
    if (!SEVENTV_ID.test(channelId)) return fail(404, "error.seventv.not_found");
    return withToken(d, async (token) => {
        type Data = { users: { user: { id: string; style?: { activeEmoteSetId?: string | null }; ownedEmoteSets: RawSet[] } | null } };
        const u = (await gql<Data>(d, token, SETS, { id: channelId })).users?.user;
        if (!u) return fail(404, "error.seventv.not_found");
        const live = u.style?.activeEmoteSetId ?? null;
        const sets = (u.ownedEmoteSets ?? [])
            .filter((s) => s.kind === "NORMAL")
            .map((s) => ({ id: s.id, name: s.name, capacity: s.capacity ?? null, count: s.emotes?.totalCount ?? 0, live: s.id === live }))
            .sort((a, b) => Number(b.live) - Number(a.live) || a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
        return success({ channel_id: u.id, active_set_id: live, sets });
    });
}

const onCdn = (url: string) => {
    try {
        return new URL(url).host === CDN_HOST;
    } catch {
        return false;
    }
};

type RawSetEmote = {
    id: string;
    alias: string;
    addedAt: string;
    emote: { id: string; defaultName: string; flags?: { animated?: boolean }; images?: EmoteImage[] } | null;
};

export function setEmoteShape(e: RawSetEmote) {
    const animated = e.emote?.flags?.animated === true;
    const images = (e.emote?.images ?? []).filter((i) => i && typeof i.url === "string");
    const preview = previewWebp(images, animated);
    const file = pickWebp(images, animated);
    const name = e.emote?.defaultName ?? e.alias;
    const added = Date.parse(e.addedAt);
    return {
        emote_id: e.emote?.id ?? e.id,
        alias: e.alias,
        name,
        renamed: e.alias !== name,
        animated,
        preview_url: preview && onCdn(preview.url) ? preview.url : null,
        file_url: file && onCdn(file.url) ? file.url : null,
        added_at: Number.isFinite(added) ? added : null,
    };
}

export async function sevenTvSet(d: SevenTvDeps, setId: string, q: URLSearchParams): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId)) return fail(404, "error.seventv.not_found");
    const query = (q.get("q") ?? "").trim();
    if (query.length > 100) return fail(400, "error.seventv.bad");
    const pageRaw = q.get("page");
    const page = pageRaw === null || pageRaw === "" ? 1 : Number(pageRaw);
    if (!Number.isInteger(page) || page < 1 || page > 1000) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        type Data = {
            emoteSets: {
                emoteSet: {
                    id: string;
                    name: string;
                    kind: string;
                    capacity: number | null;
                    ownerId: string | null;
                    owner: { id: string; style?: { activeEmoteSetId?: string | null } } | null;
                    emotes: { totalCount: number; pageCount: number; items: RawSetEmote[] };
                } | null;
            };
        };
        const s = (await gql<Data>(d, token, SET, { id: setId, q: query || null, page, perPage: SET_PAGE })).emoteSets?.emoteSet;
        if (!s) return fail(404, "error.seventv.not_found");
        // with a filter totalCount is the matches; the set's own count is the unfiltered total
        let count = s.emotes.totalCount;
        if (query) {
            type Count = { emoteSets: { emoteSet: { emotes: { totalCount: number } } | null } };
            const c = await gql<Count>(d, token, `query($id: Id!) { emoteSets { emoteSet(id: $id) { emotes(page: 1, perPage: 1) { totalCount } } } }`, { id: setId });
            count = c.emoteSets?.emoteSet?.emotes.totalCount ?? count;
        }
        return success({
            set: {
                id: s.id,
                name: s.name,
                capacity: s.capacity ?? null,
                count,
                owner_id: s.ownerId,
                live: !!s.owner && s.owner.style?.activeEmoteSetId === s.id,
            },
            page,
            has_more: page < (s.emotes.pageCount ?? 0),
            emotes: (s.emotes.items ?? []).map(setEmoteShape),
        });
    });
}

const goodName = (v: unknown): string | null => {
    if (typeof v !== "string") return null;
    const t = v.trim();
    return t.length >= 1 && t.length <= NAME_MAX && !/[\u0000-\u001f\u007f]/.test(t) ? t : null;
};
const goodAlias = (v: unknown): string | null => {
    const t = goodName(v);
    return t && !/\s/.test(t) ? t : null;
};

export async function sevenTvCreateSet(d: SevenTvDeps, body: { owner_id?: unknown; name?: unknown }): Promise<StudioReply> {
    const name = goodName(body.name);
    const owner = typeof body.owner_id === "string" && SEVENTV_ID.test(body.owner_id) ? body.owner_id : null;
    if (!name || !owner) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        type Data = { emoteSets: { create: { id: string; name: string; capacity: number | null } } };
        const s = (await gql<Data>(d, token, CREATE_SET, { name, owner })).emoteSets.create;
        return success({ set: { id: s.id, name: s.name, capacity: s.capacity ?? null, count: 0, owner_id: owner, live: false } }, 201);
    });
}

export async function sevenTvRenameSet(d: SevenTvDeps, setId: string, body: { name?: unknown }): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId)) return fail(404, "error.seventv.not_found");
    const name = goodName(body.name);
    if (!name) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        type Data = { emoteSets: { emoteSet: { name: { id: string; name: string; capacity: number | null } } } };
        const s = (await gql<Data>(d, token, RENAME_SET, { set: setId, name })).emoteSets.emoteSet.name;
        return success({ set: { id: s.id, name: s.name, capacity: s.capacity ?? null } });
    });
}

export async function sevenTvAddEmote(
    d: SevenTvDeps,
    setId: string,
    body: { emote_id?: unknown; alias?: unknown; override_conflicts?: unknown },
): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId)) return fail(404, "error.seventv.not_found");
    const emoteId = typeof body.emote_id === "string" && SEVENTV_ID.test(body.emote_id) ? body.emote_id : null;
    const alias = body.alias === undefined || body.alias === null || body.alias === "" ? null : goodAlias(body.alias);
    if (!emoteId || (body.alias !== undefined && body.alias !== null && body.alias !== "" && !alias)) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        await gql(d, token, ADD, {
            set: setId,
            e: { emoteId, ...(alias ? { alias } : {}) },
            over: body.override_conflicts === true ? true : null,
        });
        return success({ set_id: setId, emote_id: emoteId, alias }, 201);
    });
}

export async function sevenTvRenameEmote(
    d: SevenTvDeps,
    setId: string,
    emoteId: string,
    body: { alias?: unknown; from?: unknown },
): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId) || !SEVENTV_ID.test(emoteId)) return fail(404, "error.seventv.not_found");
    const alias = goodAlias(body.alias);
    const from = body.from === undefined || body.from === null ? null : goodName(body.from);
    if (!alias || (body.from !== undefined && body.from !== null && !from)) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        type Data = { emoteSets: { emoteSet: { updateEmoteAlias: { alias: string } } } };
        const r = await gql<Data>(d, token, ALIAS, { set: setId, e: { emoteId, ...(from ? { alias: from } : {}) }, alias });
        return success({ set_id: setId, emote_id: emoteId, alias: r.emoteSets.emoteSet.updateEmoteAlias.alias ?? alias });
    });
}

export async function sevenTvRemoveEmote(d: SevenTvDeps, setId: string, emoteId: string, alias: string | null): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId) || !SEVENTV_ID.test(emoteId)) return fail(404, "error.seventv.not_found");
    const a = alias === null || alias === "" ? null : goodName(alias);
    if (alias && !a) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        await gql(d, token, REMOVE, { set: setId, e: { emoteId, ...(a ? { alias: a } : {}) } });
        return success({ set_id: setId, emote_id: emoteId, removed: true });
    });
}

export async function sevenTvMakeLive(d: SevenTvDeps, channelId: string, body: { set_id?: unknown }): Promise<StudioReply> {
    if (!SEVENTV_ID.test(channelId)) return fail(404, "error.seventv.not_found");
    const setId = body.set_id === null ? null : typeof body.set_id === "string" && SEVENTV_ID.test(body.set_id) ? body.set_id : undefined;
    if (setId === undefined) return fail(400, "error.seventv.bad");
    return withToken(d, async (token) => {
        type Data = { users: { user: { activeEmoteSet: { id: string; style?: { activeEmoteSetId?: string | null } } } | null } };
        const r = await gql<Data>(d, token, LIVE, { user: channelId, set: setId });
        if (!r.users?.user) return fail(404, "error.seventv.not_found");
        return success({ channel_id: channelId, active_set_id: r.users.user.activeEmoteSet.style?.activeEmoteSetId ?? setId });
    });
}

// ---- uploading a library picture as a new 7TV emote (57.9) ---------------------------------------------------------------

// 7TV's REST upload (apps/api/src/http/v4/rest/emotes.rs): multipart `file` + `metadata` JSON, 7 MiB body cap.
export const SEVENTV_UPLOAD = "https://api.7tv.app/v4/emotes";
export const UPLOAD_MAX = 7 * 1024 * 1024 - 64 * 1024; // room for the multipart wrapping
// 7TV's own name and tag rules (apps/api/src/http/validators.rs)
const EMOTE_NAME = /^[a-zA-Z0-9_\-():!+|.'?><\p{Emoji_Presentation}*$#]{1,100}$/u;
const TAG = /^\w{3,30}$/;
const UPLOAD_TYPES = ["image/webp", "image/gif", "image/png", "image/avif", "image/jpeg"];

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream; size: number; httpMetadata?: { contentType?: string } } | null> };
export type SevenTvUploadDeps = SevenTvDeps & { media: ReadBucket; originals: ReadBucket };

type FileRow = { id: string; bucket: string; r2_key: string; content_type: string | null; bytes: number | null; name: string | null; width: number | null; height: number | null };

// 7TV's processing drops (soft-deletes) an emote over 1000 px a side or outside 1:32..3:1; caught here when the size is known.
export function sizeProblem(w: number | null, h: number | null): string | null {
    if (!w || !h) return null;
    if (w > 1000 || h > 1000) return `7TV takes at most 1000x1000 px; this is ${w}x${h}`;
    const r = w / h;
    if (r > 3 || r < 1 / 32) return `7TV takes width:height between 1:32 and 3:1; this is ${w}x${h}`;
    return null;
}

export function cleanEmoteName(v: unknown): string | null {
    if (typeof v !== "string") return null;
    const t = v.trim();
    return EMOTE_NAME.test(t) ? t : null;
}

// A file id (or its public id) of the library; a post id answers its first picture.
async function fileRow(db: D1Database, ref: string): Promise<FileRow | null> {
    const cols = "id, bucket, r2_key, content_type, bytes, name, width, height";
    const direct = await db
        .prepare(`SELECT ${cols} FROM media_items WHERE (id = ?1 OR public_id = ?1) AND deleted_at IS NULL ORDER BY (id = ?1) DESC LIMIT 1`)
        .bind(ref)
        .first<FileRow>();
    if (direct) return direct;
    try {
        return (
            (await db
                .prepare(
                    `SELECT ${cols} FROM media_items WHERE post_key = ?1 AND deleted_at IS NULL AND content_type LIKE 'image/%' ORDER BY created_at, id LIMIT 1`,
                )
                .bind(ref)
                .first<FileRow>()) ?? null
        );
    } catch {
        return null;
    }
}

async function uploadError(res: Response): Promise<SevenTvError> {
    let msg: string | undefined;
    try {
        const b = (await res.json()) as { error?: unknown; message?: unknown };
        msg = typeof b.error === "string" ? b.error : typeof b.message === "string" ? b.message : undefined;
    } catch {
        msg = undefined;
    }
    if (res.status === 401) return new SevenTvError(fail(409, "error.seventv.relink"), true);
    if (res.status === 403) return new SevenTvError(fail(403, "error.seventv.forbidden", msg));
    if (res.status === 413) return new SevenTvError(fail(413, "error.seventv.too_big"));
    if (res.status === 429) return new SevenTvError(fail(429, "error.seventv.rate_limited", msg));
    if (res.status >= 500) return new SevenTvError(fail(502, "error.seventv.unavailable"));
    return new SevenTvError(fail(400, "error.seventv.rejected", msg));
}

export async function sevenTvUpload(
    d: SevenTvUploadDeps,
    body: { file?: unknown; name?: unknown; tags?: unknown; zero_width?: unknown; private?: unknown; set_id?: unknown; alias?: unknown },
): Promise<StudioReply> {
    const ref = typeof body.file === "string" ? body.file.trim() : "";
    const name = cleanEmoteName(body.name);
    const tags = body.tags === undefined || body.tags === null ? [] : body.tags;
    const setId = body.set_id === undefined || body.set_id === null || body.set_id === "" ? null : body.set_id;
    const alias = body.alias === undefined || body.alias === null || body.alias === "" ? null : cleanEmoteName(body.alias);
    if (
        !ref ||
        ref.length > 64 ||
        !name ||
        !Array.isArray(tags) ||
        tags.length > 6 ||
        !tags.every((t) => typeof t === "string" && TAG.test(t)) ||
        (setId !== null && !(typeof setId === "string" && SEVENTV_ID.test(setId))) ||
        (body.alias !== undefined && body.alias !== null && body.alias !== "" && !alias)
    ) {
        return fail(400, "error.seventv.bad");
    }
    const row = await fileRow(d.db, ref);
    if (!row) return fail(404, "error.seventv.file_not_found");
    const type = (row.content_type ?? "").toLowerCase().split(";")[0]!.trim();
    if (!UPLOAD_TYPES.includes(type)) return fail(415, "error.seventv.file_type");
    if (row.bytes !== null && row.bytes > UPLOAD_MAX) return fail(413, "error.seventv.too_big");
    const size = sizeProblem(row.width, row.height);
    if (size) return fail(400, "error.seventv.too_large", size);

    return withToken(d, async (token) => {
        const obj = await (row.bucket === "media" ? d.media : d.originals).get(row.r2_key).catch(() => null);
        if (!obj) return fail(404, "error.seventv.file_not_found");
        if (obj.size > UPLOAD_MAX) {
            await obj.body.cancel().catch(() => {});
            return fail(413, "error.seventv.too_big");
        }
        const bytes = await new Response(obj.body).arrayBuffer();
        const form = new FormData();
        form.append(
            "metadata",
            JSON.stringify({ name, tags, default_zero_width: body.zero_width === true, private: body.private === true }),
        );
        form.append("file", new Blob([bytes], { type }), `${row.id}.${type.split("/")[1]}`);
        const f = d.fetch ?? fetch;
        let res: Response;
        try {
            res = await f(SEVENTV_UPLOAD, {
                method: "POST",
                headers: { accept: "application/json", authorization: `Bearer ${token}` },
                body: form,
                signal: AbortSignal.timeout(60_000),
            });
        } catch {
            throw new SevenTvError(fail(502, "error.seventv.unavailable"));
        }
        if (!res.ok) throw await uploadError(res);
        let emoteId: unknown;
        try {
            emoteId = ((await res.json()) as { emote_id?: unknown }).emote_id;
        } catch {
            emoteId = undefined;
        }
        if (typeof emoteId !== "string" || !SEVENTV_ID.test(emoteId)) throw new SevenTvError(fail(502, "error.seventv.unavailable"));

        // Put it in a set too when asked. The emote exists now even if this part fails, so that is reported, not thrown.
        let added: { set_id: string; alias: string | null } | null = null;
        let addError: { code: string; message?: string } | null = null;
        if (typeof setId === "string") {
            try {
                await gql(d, token, ADD, { set: setId, e: { emoteId, ...(alias ? { alias } : {}) }, over: null });
                added = { set_id: setId, alias };
            } catch (e) {
                if (!(e instanceof SevenTvError)) throw e;
                const b = e.reply.body as { error: { code: string }; message?: string };
                addError = { code: b.error.code, ...(b.message ? { message: b.message } : {}) };
            }
        }
        return success(
            {
                emote_id: emoteId,
                name,
                file_id: row.id,
                page_url: `https://7tv.app/emotes/${emoteId}`,
                pending: true,
                added,
                ...(addError ? { add_error: addError } : {}),
            },
            201,
        );
    });
}

const EMOTE = `query($id: Id!) { emotes { emote(id: $id) { id defaultName deleted imagesPending ownerId
  flags { animated private defaultZeroWidth } ${IMG} } } }`;

export async function sevenTvEmote(d: SevenTvDeps, emoteId: string): Promise<StudioReply> {
    if (!SEVENTV_ID.test(emoteId)) return fail(404, "error.seventv.not_found");
    return withToken(d, async (token) => {
        type Data = {
            emotes: {
                emote: {
                    id: string;
                    defaultName: string;
                    deleted: boolean;
                    imagesPending: boolean;
                    ownerId: string;
                    flags: { animated: boolean; private: boolean; defaultZeroWidth: boolean };
                    images: EmoteImage[];
                } | null;
            };
        };
        const e = (await gql<Data>(d, token, EMOTE, { id: emoteId })).emotes?.emote;
        // 7TV soft-deletes an upload whose processing failed (too big, too many frames, odd shape): it reads as gone
        if (!e || e.deleted) return fail(404, "error.seventv.not_found", "no such emote; a fresh upload that vanished failed 7TV's processing (at most 1000x1000 px, 1000 frames, width:height 1:32 to 3:1)");
        const shaped = setEmoteShape({ id: e.id, alias: e.defaultName, addedAt: "", emote: { id: e.id, defaultName: e.defaultName, flags: e.flags, images: e.images ?? [] } });
        return success({
            emote_id: e.id,
            name: e.defaultName,
            owner_id: e.ownerId,
            pending: e.imagesPending,
            animated: e.flags?.animated === true,
            private: e.flags?.private === true,
            zero_width: e.flags?.defaultZeroWidth === true,
            preview_url: shaped.preview_url,
            file_url: shaped.file_url,
            page_url: `https://7tv.app/emotes/${e.id}`,
        });
    });
}
