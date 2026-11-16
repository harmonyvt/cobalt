// 7TV accounts (APP-API-CONTRACT.md section 57): one linked 7TV login, and the emote sets of its own channel and of
// every channel that made it an editor. Everything goes through 7TV's v4 GraphQL with the stored session token. The
// queries and mutations are pinned from 7TV's own `schema.graphql` (57.3).
//
// 7TV has no third-party sign-in: the token is the session JWT 7tv.app keeps in localStorage ("7tv-token"). It lasts
// 30 days from login. An invalid or expired one is an HTTP 401 before GraphQL runs; the row then goes to "relink".

import { pickWebp, previewWebp, type EmoteImage } from "./emotes";
import type { StudioReply } from "./studio";
import { retryAfterSeconds, type SevenTvGate } from "./seventv-gate";

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
    // section 62.5: the shared pace of every 7TV API call (absent: nothing waits)
    gate?: SevenTvGate | null;
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
    // a name already in the set (addEmote, updateEmoteAlias): 7TV answers 409 CONFLICT (57.11)
    if (status === 409 || (typeof e.extensions?.code === "string" && /CONFLICT/i.test(e.extensions.code)) || (msg && /conflict/i.test(msg))) {
        return fail(409, "error.seventv.name_taken", msg);
    }
    return fail(400, "error.seventv.rejected", msg);
};

// A 429, with 7TV's Retry-After passed on (section 62.5: a swarm's retry waits at least that long).
function rateLimited(res: Response, now: number): StudioReply {
    const after = retryAfterSeconds(res.headers.get("retry-after"), now);
    const r = fail(429, "error.seventv.rate_limited");
    if (after !== null) (r.body as { error: Record<string, unknown> }).error.retry_after = after;
    return r;
}

export async function gql<T>(d: SevenTvDeps, token: string, query: string, variables: Record<string, unknown> = {}): Promise<T> {
    const f = d.fetch ?? fetch;
    await d.gate?.slot(/^\s*mutation\b/.test(query) ? "write" : "read");
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
    if (res.status === 429) {
        await d.gate?.slow();
        throw new SevenTvError(rateLimited(res, d.now()));
    }
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

// 7TV's logout (apps/api/src/http/v4/rest/auth.rs): deletes the session the token belongs to, so it is dead for good.
export const SEVENTV_LOGOUT = "https://api.7tv.app/v4/auth/logout";

/**
 * DELETE /7tv. With `logout` (57.12: the app linked through its own 7tv.app login sheet, so the session is capystore's
 * alone) 7TV's session is ended too, best effort: a failure there still forgets the token here.
 */
export async function sevenTvUnlink(d: SevenTvDeps, opts: { logout?: boolean } = {}): Promise<StudioReply> {
    const row = await readRow(d);
    if (row === "missing") return fail(503, "error.seventv.not_ready");
    let loggedOut = false;
    if (opts.logout && row) {
        const token = await openToken(d.secret, row.token).catch(() => null);
        if (token) {
            try {
                const res = await (d.fetch ?? fetch)(SEVENTV_LOGOUT, {
                    method: "POST",
                    headers: { accept: "application/json", authorization: `Bearer ${token}` },
                    signal: AbortSignal.timeout(10_000),
                });
                loggedOut = res.ok || res.status === 401;
                await res.body?.cancel().catch(() => {});
            } catch {
                loggedOut = false;
            }
        }
    }
    await d.db.prepare("DELETE FROM seventv_account WHERE id = 'main'").run();
    return success({ linked: false, ...(opts.logout ? { logged_out: loggedOut } : {}) });
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
/** The container's emote fit (57.10), reached through the Durable Object; absent: nothing is fitted. */
export type EmoteFit = (body: ReadableStream, bytes: number, query: string) => Promise<Response>;
export type SevenTvUploadDeps = SevenTvDeps & { media: ReadBucket; originals: ReadBucket; fit?: EmoteFit };
/** The Durable Object's internal path for the fit (src/index.ts). */
export const EMOTE_FIT_PATH = "/internal/7tv-fit";
/** Pictures the fit can read (ffmpeg plus the animated WebP composer). */
const FIT_TYPES = ["image/webp", "image/gif", "image/png", "image/jpeg"];
const FIT_INPUT_MAX = 64 * 1024 * 1024;
type Crop = { x: number; y: number; w: number; h: number };

function cleanCrop(v: unknown): Crop | null | false {
    if (v === undefined || v === null) return null;
    if (typeof v !== "object") return false;
    const c = v as Record<string, unknown>;
    const n = [c.x, c.y, c.w, c.h];
    if (!n.every((x) => typeof x === "number" && Number.isFinite(x))) return false;
    const [x, y, w, h] = n as number[];
    if (x! < 0 || y! < 0 || w! <= 0 || h! <= 0 || x! + w! > 1.0001 || y! + h! > 1.0001) return false;
    return { x: x!, y: y!, w: w!, h: h! };
}

type FileRow = { id: string; bucket: string; r2_key: string; content_type: string | null; bytes: number | null; name: string | null; width: number | null; height: number | null };

// 7TV's processing drops (soft-deletes) an emote over 1000 px a side or outside 1:32..3:1; caught here when the size is known.
// A side over 1000 px is shrunk by the fit (57.10); the shape only changes with a crop box the caller picks.
export function ratioProblem(w: number | null, h: number | null): string | null {
    if (!w || !h) return null;
    const r = w / h;
    return r > 3 || r < 1 / 32 ? `7TV takes width:height between 1:32 and 3:1; this is ${w}x${h}: pass a crop box` : null;
}

export function sizeProblem(w: number | null, h: number | null): string | null {
    if (!w || !h) return null;
    if (w > 1000 || h > 1000) return `7TV takes at most 1000x1000 px; this is ${w}x${h}`;
    return ratioProblem(w, h);
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
    body: {
        file?: unknown; name?: unknown; tags?: unknown; zero_width?: unknown; private?: unknown; set_id?: unknown; alias?: unknown;
        crop?: unknown; size?: unknown;
    },
): Promise<StudioReply> {
    const ref = typeof body.file === "string" ? body.file.trim() : "";
    const name = cleanEmoteName(body.name);
    const tags = body.tags === undefined || body.tags === null ? [] : body.tags;
    const setId = body.set_id === undefined || body.set_id === null || body.set_id === "" ? null : body.set_id;
    const alias = body.alias === undefined || body.alias === null || body.alias === "" ? null : cleanEmoteName(body.alias);
    const crop = cleanCrop(body.crop);
    const sizeAsk = body.size === undefined || body.size === null ? null : body.size;
    if (
        crop === false ||
        (sizeAsk !== null && !(typeof sizeAsk === "number" && Number.isInteger(sizeAsk) && sizeAsk >= 32 && sizeAsk <= 1000))
    ) {
        return fail(400, "error.seventv.bad", "crop is {x, y, w, h} as fractions of the picture; size is 32 to 1000 px");
    }
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
    const canFit = !!d.fit && FIT_TYPES.includes(type);
    // Fit (57.10) when asked (a crop box or a size) or when the file is over 7TV's bytes or 1000 px a side.
    const overBytes = row.bytes !== null && row.bytes > UPLOAD_MAX;
    const overSide = (row.width ?? 0) > 1000 || (row.height ?? 0) > 1000;
    let wantFit = crop !== null || sizeAsk !== null || overBytes || overSide;
    if (wantFit && !canFit) {
        if (crop !== null || sizeAsk !== null) return fail(415, "error.seventv.file_type", "this kind of picture cannot be resized or cropped here");
        if (overBytes) return fail(413, "error.seventv.too_big");
    }
    // the shape is only fixed by a crop box: never guessed
    const ratio = crop === null ? ratioProblem(row.width, row.height) : null;
    if (ratio) return fail(400, "error.seventv.too_large", ratio);
    if (overSide && !canFit) return fail(400, "error.seventv.too_large", sizeProblem(row.width, row.height) ?? undefined);
    if (row.bytes !== null && row.bytes > FIT_INPUT_MAX) return fail(413, "error.seventv.too_big");

    return withToken(d, async (token) => {
        const obj = await (row.bucket === "media" ? d.media : d.originals).get(row.r2_key).catch(() => null);
        if (!obj) return fail(404, "error.seventv.file_not_found");
        if (obj.size > UPLOAD_MAX && !canFit) {
            await obj.body.cancel().catch(() => {});
            return fail(413, "error.seventv.too_big");
        }
        if (obj.size > UPLOAD_MAX) wantFit = true;
        let bytes: ArrayBuffer;
        let sendType = type;
        let fitted: { width: number; height: number; frames: number; bytes: number; quality: number } | null = null;
        if (wantFit && d.fit) {
            const q = new URLSearchParams({ max_bytes: String(UPLOAD_MAX) });
            if (crop) q.set("crop", [crop.x, crop.y, crop.w, crop.h].map((n) => +n.toFixed(5)).join(","));
            if (sizeAsk !== null) q.set("size", String(sizeAsk));
            let res: Response;
            try {
                res = await d.fit(obj.body, obj.size, q.toString());
            } catch {
                return fail(502, "error.seventv.fit_failed", "the resize step did not answer; try again");
            }
            if (!res.ok) {
                const b = (await res.json().catch(() => null)) as { error?: { code?: string; detail?: string } } | null;
                const code = b?.error?.code ?? "";
                const detail = b?.error?.detail || undefined;
                if (res.status === 429) return fail(429, "error.seventv.busy", "the media helper is busy with another job; try again in a minute");
                if (code === "error.seventv.fit_shape") return fail(400, "error.seventv.too_large", detail);
                if (code === "error.seventv.fit_too_big" || res.status === 413) return fail(413, "error.seventv.too_big", detail);
                return fail(422, "error.seventv.fit_failed", detail);
            }
            bytes = await res.arrayBuffer();
            const num = (h: string) => Number(res.headers.get(h)) || 0;
            fitted = { width: num("x-emote-width"), height: num("x-emote-height"), frames: num("x-emote-frames"), bytes: bytes.byteLength, quality: num("x-emote-quality") };
            sendType = "image/webp";
        } else {
            bytes = await new Response(obj.body).arrayBuffer();
        }
        const form = new FormData();
        form.append(
            "metadata",
            JSON.stringify({ name, tags, default_zero_width: body.zero_width === true, private: body.private === true }),
        );
        form.append("file", new Blob([bytes], { type: sendType }), `${row.id}.${sendType.split("/")[1]}`);
        const f = d.fetch ?? fetch;
        await d.gate?.slot("write");
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

        // Remembered for the 7tv tab (57.11). Before migration 0042 the table is missing: the upload still stands.
        await d.db
            .prepare("INSERT OR REPLACE INTO seventv_uploads (emote_id, file_id, name, set_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
            .bind(emoteId, row.id, name, typeof setId === "string" ? setId : null, d.now())
            .run()
            .catch(() => {});
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
                fitted,
                added,
                ...(addError ? { add_error: addError } : {}),
            },
            201,
        );
    });
}

const EMOTE = `query($id: Id!) { emotes { emote(id: $id) { id defaultName deleted imagesPending ownerId
  flags { animated private defaultZeroWidth } ${IMG} } } }`;

/** GET /7tv/uploads (57.11): what capystore uploaded, newest first. No 7TV call; empty before migration 0042. */
export async function sevenTvUploads(d: SevenTvDeps): Promise<StudioReply> {
    type Row = { emote_id: string; file_id: string; name: string; set_id: string | null; created_at: number };
    let rows: Row[] = [];
    try {
        rows = (await d.db.prepare("SELECT emote_id, file_id, name, set_id, created_at FROM seventv_uploads ORDER BY created_at DESC LIMIT 100").all<Row>()).results ?? [];
    } catch {
        rows = [];
    }
    return success({ uploads: rows.map((r) => ({ file_id: r.file_id, emote_id: r.emote_id, name: r.name, set_id: r.set_id, created_at: r.created_at })) });
}

const OWNED = `query { users { me { id ownedEmotes { id defaultName deleted imagesPending
  flags { animated private defaultZeroWidth } ${IMG} } } } }`;
/** At most this many owned emotes answer (newest first). */
export const OWNED_MAX = 500;

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/** The time in a ULID (7TV ids are ULIDs): its first 10 characters, in ms; null when it is not one. */
export function ulidTime(id: string): number | null {
    if (!/^[0-9A-HJKMNP-TV-Z]{26}$/i.test(id)) return null;
    let t = 0;
    for (const ch of id.slice(0, 10).toUpperCase()) t = t * 32 + CROCKFORD.indexOf(ch);
    return t;
}

/**
 * GET /7tv/owned (57.14): every emote the linked account owns on 7TV (uploaded here or on 7tv.app), newest first, at most
 * OWNED_MAX, with the library file it came from when capystore uploaded it (D1 `seventv_uploads`).
 */
export async function sevenTvOwned(d: SevenTvDeps): Promise<StudioReply> {
    return withToken(d, async (token) => {
        type Raw = {
            id: string;
            defaultName: string;
            deleted?: boolean;
            imagesPending?: boolean;
            flags?: { animated?: boolean; private?: boolean; defaultZeroWidth?: boolean };
            images?: EmoteImage[];
        };
        type Data = { users: { me: { id: string; ownedEmotes?: Raw[] } | null } };
        const me = (await gql<Data>(d, token, OWNED, {})).users?.me;
        if (!me) return fail(409, "error.seventv.relink");
        const files = new Map<string, string>();
        try {
            const rows = (await d.db.prepare("SELECT emote_id, file_id FROM seventv_uploads").all<{ emote_id: string; file_id: string }>()).results ?? [];
            for (const r of rows) files.set(r.emote_id, r.file_id);
        } catch {
            // before migration 0042: no files to name
        }
        const owned = (me.ownedEmotes ?? []).filter((e) => e && typeof e.id === "string" && !e.deleted);
        const total = owned.length;
        const emotes = owned
            .sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0))
            .slice(0, OWNED_MAX)
            .map((e) => {
                const shaped = setEmoteShape({ id: e.id, alias: e.defaultName, addedAt: "", emote: { id: e.id, defaultName: e.defaultName, flags: e.flags, images: e.images ?? [] } });
                return {
                    emote_id: e.id,
                    name: e.defaultName,
                    animated: e.flags?.animated === true,
                    private: e.flags?.private === true,
                    zero_width: e.flags?.defaultZeroWidth === true,
                    pending: e.imagesPending === true,
                    preview_url: shaped.preview_url,
                    file_url: shaped.file_url,
                    page_url: `https://7tv.app/emotes/${e.id}`,
                    file_id: files.get(e.id) ?? null,
                    created_at: ulidTime(e.id),
                };
            });
        return success({ owner_id: me.id, total, emotes });
    });
}

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

// ---- many emotes into one set, and cloning a set (section 63.4) ----------------------------------------------------------

/** Adds sent to 7TV in one request (top-level aliased mutations run one after another, each with its own error). */
export const ADD_BATCH = 10;
/** The most emotes one call adds; more is a second call (what is already in the set is skipped). */
export const ADD_MANY_MAX = 1000;
/** A call stops starting new batches after this long and answers what is left. */
export const ADD_MANY_BUDGET_MS = 100_000;

type AddItem = { emote_id: string; alias: string | null };
type AddFailure = AddItem & { code: string; message?: string };

// One GraphQL request that may partly fail: its data and its errors, as they came. Throws SevenTvError only when the
// whole request failed (no answer, 401, 429, 5xx).
async function gqlParts(d: SevenTvDeps, token: string, query: string, variables: Record<string, unknown>): Promise<{ data: Record<string, unknown> | null; errors: GqlError[] }> {
    const f = d.fetch ?? fetch;
    await d.gate?.slot("write");
    let res: Response;
    try {
        res = await f(SEVENTV_GQL, {
            method: "POST",
            headers: { "content-type": "application/json", accept: "application/json", authorization: `Bearer ${token}` },
            body: JSON.stringify({ query, variables }),
            signal: AbortSignal.timeout(30_000),
        });
    } catch {
        throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    }
    if (res.status === 401) throw new SevenTvError(fail(409, "error.seventv.relink"), true);
    if (res.status === 429) {
        await d.gate?.slow();
        throw new SevenTvError(rateLimited(res, d.now()));
    }
    let body: { data?: Record<string, unknown> | null; errors?: (GqlError & { path?: unknown[] })[] };
    try {
        body = (await res.json()) as typeof body;
    } catch {
        throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    }
    if (res.status >= 500 && !body.data) throw new SevenTvError(fail(502, "error.seventv.unavailable"));
    return { data: body.data ?? null, errors: Array.isArray(body.errors) ? body.errors : [] };
}

/** Every emote of a set (all pages): its emote id and alias. */
async function setContents(d: SevenTvDeps, token: string, setId: string): Promise<{ set: { id: string; name: string; capacity: number | null; ownerId: string | null }; emotes: RawSetEmote[] }> {
    const emotes: RawSetEmote[] = [];
    let info: { id: string; name: string; capacity: number | null; ownerId: string | null } | null = null;
    for (let page = 1; page <= 50; page++) {
        type Data = { emoteSets: { emoteSet: { id: string; name: string; capacity: number | null; ownerId: string | null; emotes: { pageCount: number; items: RawSetEmote[] } } | null } };
        const s = (await gql<Data>(d, token, SET, { id: setId, q: null, page, perPage: SET_PAGE })).emoteSets?.emoteSet;
        if (!s) throw new SevenTvError(fail(404, "error.seventv.not_found", `no emote set ${setId}`));
        info ??= { id: s.id, name: s.name, capacity: s.capacity ?? null, ownerId: s.ownerId };
        emotes.push(...(s.emotes.items ?? []));
        if (page >= (s.emotes.pageCount ?? 0)) break;
    }
    return { set: info!, emotes };
}

export type AddManyOptions = { override_conflicts?: boolean; dry_run?: boolean; budgetMs?: number; sleep?: (ms: number) => Promise<void> };

const errAlias = (e: { path?: unknown[] }) => (Array.isArray(e.path) && typeof e.path[0] === "string" ? e.path[0] : null);
const codeOf = (r: StudioReply) => (r.body as { error: { code: string } }).error.code;
const msgOf = (r: StudioReply) => (r.body as { message?: string }).message;

/**
 * Many emotes into one set in one call (section 63.4): the set is read first (what is already there under the same alias
 * is skipped, so a call can simply be repeated), its capacity checked, then the adds go 10 to a request. A refusal of
 * the whole account (LACKING_PRIVILEGES) stops at the first batch; a rate limit waits and retries that batch's misses.
 */
export async function sevenTvAddMany(d: SevenTvDeps, setId: string, items: AddItem[], o: AddManyOptions = {}): Promise<StudioReply> {
    if (!SEVENTV_ID.test(setId)) return fail(404, "error.seventv.not_found");
    if (items.length < 1 || items.length > ADD_MANY_MAX) return fail(400, "error.seventv.bad", `1 to ${ADD_MANY_MAX} emotes a call`);
    for (const it of items) {
        if (!SEVENTV_ID.test(it.emote_id) || (it.alias !== null && !goodAlias(it.alias))) return fail(400, "error.seventv.bad", `bad emote ${it.emote_id}${it.alias ? ` (${it.alias})` : ""}`);
    }
    const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
    const started = Date.now();
    const budget = o.budgetMs ?? ADD_MANY_BUDGET_MS;
    return withToken(d, async (token) => {
        const before = await setContents(d, token, setId);
        const have = new Map(before.emotes.map((e) => [(e.alias ?? "").toLowerCase(), e.emote?.id ?? e.id]));
        const skipped: (AddItem & { why: string })[] = [];
        const todo: AddItem[] = [];
        const seen = new Set<string>();
        for (const it of items) {
            const name = (it.alias ?? "").toLowerCase();
            const key = `${it.emote_id}:${name}`;
            if (seen.has(key)) continue;
            seen.add(key);
            if (it.alias !== null && have.get(name) === it.emote_id) skipped.push({ ...it, why: "already in the set under that name" });
            else if (it.alias === null && before.emotes.some((e) => (e.emote?.id ?? e.id) === it.emote_id)) skipped.push({ ...it, why: "already in the set" });
            else todo.push(it);
        }
        const cap = before.set.capacity;
        const room = cap === null ? Infinity : cap - before.emotes.length;
        const summary = { set_id: setId, set_name: before.set.name, capacity: cap, count_before: before.emotes.length };
        // an add over a name already there replaces it (override_conflicts): it takes no new room
        const replacing = o.override_conflicts ? todo.filter((it) => it.alias !== null && have.has(it.alias.toLowerCase())).length : 0;
        if (todo.length - replacing > room) {
            return fail(409, "error.seventv.set_full", `set ${before.set.name} has room for ${Math.max(0, room)} more (${before.emotes.length} of ${cap}); this call adds ${todo.length - replacing}`);
        }
        if (o.dry_run) return success({ ...summary, dry_run: true, would_add: todo, skipped, added: [], failed: [], remaining: [] });

        const added: AddItem[] = [];
        const failed: AddFailure[] = [];
        let queue = todo.slice();
        let stopped: string | null = null;
        let waits = 0;
        const resent = new Set<string>();
        while (queue.length > 0) {
            if (Date.now() - started > budget) {
                stopped = "time: call again with the same list to add the rest (what is in already is skipped)";
                break;
            }
            const batch = queue.slice(0, ADD_BATCH);
            const vars: Record<string, unknown> = { set: setId, over: o.override_conflicts === true ? true : null };
            const defs = ["$set: Id!", "$over: Boolean"];
            const parts = batch.map((it, k) => {
                vars[`e${k}`] = { emoteId: it.emote_id, ...(it.alias ? { alias: it.alias } : {}) };
                defs.push(`$e${k}: EmoteSetEmoteId!`);
                return `a${k}: emoteSets { emoteSet(id: $set) { addEmote(id: $e${k}, overrideConflicts: $over) { id } } }`;
            });
            let res;
            try {
                res = await gqlParts(d, token, `mutation(${defs.join(", ")}) { ${parts.join(" ")} }`, vars);
            } catch (e) {
                if (e instanceof SevenTvError && codeOf(e.reply) === "error.seventv.rate_limited" && waits < 4) {
                    waits++;
                    const after = Number((e.reply.body as { error: { retry_after?: number } }).error.retry_after ?? 0);
                    await sleep(Math.min(30_000, Math.max(2_000 * waits, after * 1000)));
                    continue;
                }
                throw e;
            }
            const byAlias = new Map<string, GqlError>();
            for (const er of res.errors) {
                const a = errAlias(er as { path?: unknown[] });
                if (a && !byAlias.has(a)) byAlias.set(a, er);
            }
            // errors with no path (a whole-request refusal) apply to every add of the batch
            const whole = res.errors.find((er) => !errAlias(er as { path?: unknown[] })) ?? null;
            const retry: AddItem[] = [];
            // an add counts only when its own answer came back: one failed add nulls the whole answer (live 7TV:
            // data null, an error for that alias alone), so the rest of the batch is unknown until the set is read again
            const unsure: AddItem[] = [];
            batch.forEach((it, k) => {
                const er = byAlias.get(`a${k}`) ?? whole;
                if (!er && res.data?.[`a${k}`]) {
                    added.push(it);
                    return;
                }
                if (!er) {
                    unsure.push(it);
                    return;
                }
                const r = errorFor(er);
                if (codeOf(r) === "error.seventv.rate_limited") retry.push(it);
                else failed.push({ ...it, code: codeOf(r), ...(msgOf(r) ? { message: msgOf(r) } : {}) });
            });
            if (unsure.length > 0) {
                const now = await setContents(d, token, setId);
                const inSet = (it: AddItem) => now.emotes.some((e) => (e.emote?.id ?? e.id) === it.emote_id && (it.alias === null || (e.alias ?? "").toLowerCase() === it.alias.toLowerCase()));
                for (const it of unsure) {
                    const key = `${it.emote_id}:${(it.alias ?? "").toLowerCase()}`;
                    if (inSet(it)) added.push(it);
                    else if (!resent.has(key)) {
                        resent.add(key);
                        retry.push(it);
                    } else failed.push({ ...it, code: "error.seventv.rejected", message: "7TV did not add it and gave no reason (another add in its batch failed)" });
                }
            }
            queue = [...retry, ...queue.slice(batch.length)];
            // a set the account may not edit refuses every add: no point sending the rest
            const refused = failed.find((f) => f.code === "error.seventv.forbidden" || f.code === "error.seventv.relink");
            if (refused) {
                stopped = `7TV refused the account: ${refused.message ?? refused.code} (seventv_permissions shows what it may do)`;
                break;
            }
            const limited = retry.some((it) => !unsure.includes(it));
            if (limited) {
                if (waits >= 4) {
                    stopped = "7TV kept rate limiting: call again in a minute with the same list";
                    break;
                }
                waits++;
                await sleep(2_000 * waits);
            }
        }
        return success({
            ...summary,
            count_after: before.emotes.length + added.length,
            added,
            skipped,
            failed,
            remaining: stopped ? queue : [],
            ...(stopped ? { stopped } : {}),
        });
    });
}

export type CloneInput = {
    from_set_id: string;
    to_set_id: string;
    swap?: { alias: string; emote_id: string }[];
    skip?: string[];
    only?: string[];
};

/** The list a clone adds: every emote of the source set under its alias, with the swaps put in (section 63.4). */
export async function sevenTvClonePlan(d: SevenTvDeps, input: CloneInput): Promise<StudioReply | { items: AddItem[]; swapped: number; unknown_swaps: string[]; from: { id: string; name: string; count: number } }> {
    if (!SEVENTV_ID.test(input.from_set_id) || !SEVENTV_ID.test(input.to_set_id)) return fail(404, "error.seventv.not_found");
    if (input.from_set_id === input.to_set_id) return fail(400, "error.seventv.bad", "from and to are the same set");
    const s = await session(d);
    if (isReply(s)) return s;
    let src;
    try {
        src = await setContents(d, s.token, input.from_set_id);
    } catch (e) {
        if (e instanceof SevenTvError) return e.reply;
        throw e;
    }
    const swaps = new Map((input.swap ?? []).map((w) => [w.alias.toLowerCase(), w.emote_id]));
    const skip = new Set((input.skip ?? []).map((a) => a.toLowerCase()));
    const only = input.only ? new Set(input.only.map((a) => a.toLowerCase())) : null;
    const used = new Set<string>();
    let swapped = 0;
    const items: AddItem[] = [];
    for (const e of src.emotes) {
        const alias = e.alias;
        const k = alias.toLowerCase();
        if (skip.has(k) || (only && !only.has(k))) continue;
        const swap = swaps.get(k);
        if (swap) {
            used.add(k);
            swapped++;
        }
        const id = swap ?? e.emote?.id ?? e.id;
        // the alias is kept even when it is the emote's own name: the new set reads the same in chat
        items.push({ emote_id: id, alias });
    }
    return { items, swapped, unknown_swaps: [...swaps.keys()].filter((k) => !used.has(k)), from: { id: src.set.id, name: src.set.name, count: src.emotes.length } };
}

// ---- what the linked account may do, per channel (section 63.5) -----------------------------------------------------------

const PERMS = `query { users { me { id ${CONN} style { activeEmoteSetId }
  permissions { emoteSetLimit emoteSetCapacity emote { upload } }
  ownedEmoteSets { id kind }
  editorFor { state userId permissions { superAdmin emoteSet { admin manage create } emote { admin manage create } user { admin manageProfile } }
    user { id ${CONN} style { activeEmoteSetId } ownedEmoteSets { id kind } } } } } }`;

type PermEditor = {
    state: string;
    userId: string;
    permissions: { superAdmin: boolean; emoteSet: { admin?: boolean; manage: boolean; create: boolean }; emote?: { admin?: boolean; manage?: boolean; create?: boolean }; user: { admin?: boolean; manageProfile: boolean } };
    user: (MeUser & { ownedEmoteSets?: { id: string; kind: string }[] }) | null;
};
type PermMe = MeUser & {
    permissions?: { emoteSetLimit?: number | null; emoteSetCapacity?: number | null; emote?: { upload?: boolean } } | null;
    ownedEmoteSets?: { id: string; kind: string }[];
    editorFor: PermEditor[];
};

const normalSets = (s: { kind: string }[] | undefined) => (s ?? []).filter((x) => x.kind === "NORMAL").length;

/**
 * GET /7tv/permissions (section 63.5): for each channel the account can reach, what it may do there and, when it may
 * not, why, in the words of 7TV's own checks (apps/api/src/http/v4/gql/mutations/emote_set): adding, removing and
 * renaming need the editor's emote-set "manage", a new set needs "create" and room under the channel's set limit, making
 * a set live needs "manage profile". A channel's own set limit is private to it: only its set count is shown.
 */
export async function sevenTvPermissions(d: SevenTvDeps, channelId: string | null): Promise<StudioReply> {
    return withToken(d, async (token) => {
        const me = (await gql<{ users: { me: PermMe | null } }>(d, token, PERMS)).users?.me;
        if (!me) return fail(409, "error.seventv.relink");
        const limit = me.permissions?.emoteSetLimit ?? null;
        const capacity = me.permissions?.emoteSetCapacity ?? null;
        const ownSets = normalSets(me.ownedEmoteSets);
        const ownBlockers: string[] = [];
        if (capacity !== null && capacity <= 0) ownBlockers.push("create_sets: your account's set capacity is 0");
        if (limit !== null && ownSets >= limit) ownBlockers.push(`create_sets: you have ${ownSets} sets, your limit is ${limit}: delete one first`);
        const own = {
            channel_id: me.id,
            name: nameOf(me),
            you: true,
            editor_state: null,
            active_set_id: me.style?.activeEmoteSetId ?? null,
            sets: ownSets,
            set_limit: limit,
            can: {
                add_remove_rename: true,
                create_sets: ownBlockers.length === 0,
                make_live: true,
                upload_emotes: me.permissions?.emote?.upload !== false,
            },
            blockers: [...ownBlockers, ...(me.permissions?.emote?.upload === false ? ["upload_emotes: 7TV does not let this account upload emotes"] : [])],
            editor_permissions: null,
        };
        const others = (me.editorFor ?? [])
            .filter((e) => e.user && e.user.id !== me.id)
            .map((e) => {
                const p = e.permissions;
                const accepted = e.state === "ACCEPTED";
                const all = p.superAdmin === true;
                const manage = accepted && (all || p.emoteSet.admin === true || p.emoteSet.manage);
                const create = accepted && (all || p.emoteSet.admin === true || p.emoteSet.create);
                const live = accepted && (all || p.user.admin === true || p.user.manageProfile);
                const sets = normalSets(e.user!.ownedEmoteSets);
                const blockers: string[] = [];
                if (!accepted) blockers.push(`everything: the editor invite is ${e.state.toLowerCase()}, not accepted`);
                else {
                    if (!manage) blockers.push("add_remove_rename: the channel did not give you emote-set \"manage\"");
                    if (!create) blockers.push(`create_sets: the channel did not give you emote-set "create" (LACKING_PRIVILEGES): ask them to make the set, or to tick "create" for you`);
                    if (!live) blockers.push("make_live: the channel did not give you \"manage profile\"");
                }
                return {
                    channel_id: e.user!.id,
                    name: nameOf(e.user!),
                    you: false,
                    editor_state: e.state,
                    active_set_id: e.user!.style?.activeEmoteSetId ?? null,
                    sets,
                    set_limit: null,
                    can: { add_remove_rename: manage, create_sets: create, make_live: live, upload_emotes: false },
                    blockers: create ? [...blockers, `create_sets: 7TV also refuses once the channel is at its own set limit (private to it; it has ${sets} sets)`] : blockers,
                    editor_permissions: p,
                };
            })
            .sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
        const channels = [own, ...others];
        const picked = channelId ? channels.filter((c) => c.channel_id === channelId) : channels;
        if (channelId && picked.length === 0) return fail(404, "error.seventv.not_found", "the linked account is not an editor of that channel");
        return success({ account: { id: me.id, name: nameOf(me), set_limit: limit, set_capacity: capacity }, channels: picked });
    });
}
