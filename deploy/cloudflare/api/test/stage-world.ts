// Shared fixtures for the stage tests (APP-API-CONTRACT.md section 29): the Worker with real SQL on
// node:sqlite, a fake StageRoom that records what was broadcast, a fake Twitch (OAuth, Helix, EventSub) and a
// fake meaning-search Space. No network anywhere.
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { withBatch } from "./d1-batch";
import { EMBED_DIMS, EMBED_MODEL, encodeVector, type EmbedClient, type EmbedInput } from "../src/embed";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { emptyRoom, reduceRoom, type CanvasEvent, type RoomPort, type RoomState } from "../src/stage";
import { signEventSub } from "../src/stage-twitch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

export const T0 = 1_760_000_000_000;
export const MEDIA = "https://media.capybaraharmony.com/";
export const SHARE = "https://share.capybaraharmony.com/";
export const STAGE = "https://studio.capybaraharmony.com/";
export const API = "https://api.capybaraharmony.com";
export const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
export const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
export const AUTH = { authorization: `Api-Key ${CLIENT}` };
export const TWITCH_ID = "twitch-client-id";
export const TWITCH_SECRET = "twitch-client-secret";
export const EVENTSUB_SECRET = "eventsub-secret-0123456789";

let KEY_HASH = "";

// ---- the fake room -------------------------------------------------------------------------------------

export class FakeRoom implements RoomPort {
    events: CanvasEvent[] = [];
    state_: RoomState = emptyRoom();
    connects: Request[] = [];
    broken = false;
    async send(e: CanvasEvent) {
        if (this.broken) throw new Error("room is down");
        this.events.push(e);
        this.state_ = reduceRoom(this.state_, e);
    }
    async state() {
        if (this.broken) throw new Error("room is down");
        return this.state_;
    }
    async connect(request: Request) {
        this.connects.push(request);
        return new Response("connected", { status: 200, headers: { "x-room": "ws" } });
    }
    types() {
        return this.events.map((e) => e.type);
    }
    last<T extends CanvasEvent["type"]>(type: T): Extract<CanvasEvent, { type: T }> | undefined {
        return [...this.events].reverse().find((e) => e.type === type) as any;
    }
}

// ---- the fake meaning search ----------------------------------------------------------------------------------

// word -> a unit vector along one axis; unknown words are orthogonal to every post
const axis = (i: number) => {
    const v = new Array<number>(EMBED_DIMS).fill(0);
    v[i] = 1;
    return v;
};
export class FakeSpace implements EmbedClient {
    axes: Record<string, number> = {};
    down = false;
    queries: string[] = [];
    async embed(_kind: "document" | "query", inputs: EmbedInput[]) {
        if (this.down) {
            const { EmbedError } = await import("../src/embed");
            throw new EmbedError("unavailable", 503);
        }
        for (const i of inputs) this.queries.push(i.text);
        return {
            model: EMBED_MODEL,
            vectors: inputs.map((i) => (i.text in this.axes ? axis(this.axes[i.text]!) : axis(EMBED_DIMS - 1))),
            images: inputs.map(() => false),
        };
    }
}

// ---- the fake Twitch ----------------------------------------------------------------------------------------------

type FakeReward = { id: string; title: string; cost: number; is_enabled: boolean; prompt: string; cooldown: number | null; input: boolean };

export class FakeTwitch {
    calls: { method: string; url: string; body: any; headers: Headers }[] = [];
    rewards = new Map<string, FakeReward>();
    subs: { id: string; broadcaster: string; callback: string; secret: string }[] = [];
    redemptions: { reward_id: string; id: string; status: string }[] = [];
    // access tokens the Helix API accepts (the broadcaster's), and viewers' tokens for /validate
    validAccess = new Set<string>(["at-1"]);
    viewers = new Map<string, { client_id: string; login: string; user_id: string }>();
    // behaviours the tests switch on
    forbidRewards = false;
    refreshFails = false;
    takenTitles = new Set<string>();
    failRedemptions = false;
    failSubscriptions = false;
    failRewardUpdates = false;
    redemptionGate: Promise<void> | null = null;
    unauthorizedOnce = 0;
    code = "good-code";
    scope = ["channel:manage:redemptions"];
    private n = 0;

    private json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

    fetch = async (input: string, init: RequestInit = {}): Promise<Response> => {
        const url = new URL(input);
        const method = (init.method ?? "GET").toUpperCase();
        const headers = new Headers(init.headers);
        const raw = typeof init.body === "string" ? init.body : "";
        const isForm = headers.get("content-type")?.includes("x-www-form-urlencoded");
        const body = isForm ? Object.fromEntries(new URLSearchParams(raw)) : raw ? JSON.parse(raw) : null;
        this.calls.push({ method, url: input, body, headers });
        const path = url.pathname;

        if (url.host === "id.twitch.tv") {
            if (path === "/oauth2/token") {
                if (body.grant_type === "authorization_code") {
                    if (body.code !== this.code) return this.json(400, { status: 400, message: "Invalid authorization code" });
                    this.validAccess.add("at-1");
                    return this.json(200, { access_token: "at-1", refresh_token: "rt-1", expires_in: 14400, scope: this.scope, token_type: "bearer" });
                }
                if (body.grant_type === "refresh_token") {
                    if (this.refreshFails) return this.json(400, { status: 400, message: "Invalid refresh token" });
                    const t = `at-r${++this.n}`;
                    this.validAccess.add(t);
                    return this.json(200, { access_token: t, refresh_token: `rt-r${this.n}`, expires_in: 14400, scope: this.scope, token_type: "bearer" });
                }
                if (body.grant_type === "client_credentials") return this.json(200, { access_token: "app-token", expires_in: 5_000_000, token_type: "bearer" });
            }
            if (path === "/oauth2/validate") {
                const t = (headers.get("authorization") ?? "").replace(/^OAuth /, "");
                const v = this.viewers.get(t);
                return v ? this.json(200, { ...v, scopes: [], expires_in: 1000 }) : this.json(401, { status: 401, message: "invalid access token" });
            }
            if (path === "/oauth2/revoke") return new Response(null, { status: 200 });
            return this.json(404, {});
        }

        // Helix
        const bearer = (headers.get("authorization") ?? "").replace(/^Bearer /, "");
        if (headers.get("client-id") !== TWITCH_ID) return this.json(401, { message: "bad client id" });
        if (this.unauthorizedOnce > 0 && bearer !== "app-token") {
            this.unauthorizedOnce--;
            this.validAccess.delete(bearer);
        }
        const isApp = bearer === "app-token";
        if (!isApp && !this.validAccess.has(bearer)) return this.json(401, { status: 401, message: "Invalid OAuth token" });
        if (path === "/helix/users") return this.json(200, { data: [{ id: "b123", login: "harmony", display_name: "Harmony" }] });
        if (path === "/helix/channel_points/custom_rewards") {
            if (this.forbidRewards) return this.json(403, { message: "The broadcaster must have partner or affiliate status" });
            const id = url.searchParams.get("id");
            if (method === "GET") return this.json(200, { data: [...this.rewards.values()].map((r) => ({ id: r.id, title: r.title })) });
            if (method === "POST") {
                if (this.takenTitles.has(body.title) || [...this.rewards.values()].some((r) => r.title === body.title)) {
                    return this.json(400, { message: "CREATE_CUSTOM_REWARD_DUPLICATE_REWARD" });
                }
                const r: FakeReward = {
                    id: `rw-${++this.n}`,
                    title: body.title,
                    cost: body.cost,
                    is_enabled: body.is_enabled,
                    prompt: body.prompt,
                    cooldown: body.is_global_cooldown_enabled ? body.global_cooldown_seconds : null,
                    input: body.is_user_input_required,
                };
                this.rewards.set(r.id, r);
                return this.json(200, { data: [{ id: r.id, title: r.title }] });
            }
            const r = id ? this.rewards.get(id) : undefined;
            if (!r) return this.json(404, { message: "not found" });
            if (method === "PATCH") {
                if (this.failRewardUpdates) return this.json(500, { message: "twitch is having a moment" });
                Object.assign(r, {
                    ...(body.cost !== undefined ? { cost: body.cost } : {}),
                    ...(body.is_enabled !== undefined ? { is_enabled: body.is_enabled } : {}),
                    ...(body.prompt !== undefined ? { prompt: body.prompt } : {}),
                    cooldown: body.is_global_cooldown_enabled ? body.global_cooldown_seconds : null,
                });
                return this.json(200, { data: [{ id: r.id }] });
            }
            if (method === "DELETE") {
                this.rewards.delete(r.id);
                return new Response(null, { status: 204 });
            }
        }
        if (path === "/helix/channel_points/custom_rewards/redemptions" && method === "PATCH") {
            if (this.redemptionGate) await this.redemptionGate;
            if (this.failRedemptions) return this.json(500, { message: "boom" });
            this.redemptions.push({ reward_id: url.searchParams.get("reward_id")!, id: url.searchParams.get("id")!, status: body.status });
            return this.json(200, { data: [{}] });
        }
        if (path === "/helix/eventsub/subscriptions") {
            if (!isApp) return this.json(401, { message: "needs an app token" });
            if (method === "POST") {
                if (this.failSubscriptions) return this.json(500, { message: "nope" });
                const dup = this.subs.find((s) => s.broadcaster === body.condition.broadcaster_user_id && s.callback === body.transport.callback);
                if (dup) return this.json(409, { message: "subscription already exists" });
                const s = { id: `sub-${++this.n}`, broadcaster: body.condition.broadcaster_user_id, callback: body.transport.callback, secret: body.transport.secret };
                this.subs.push(s);
                return this.json(202, { data: [{ id: s.id, status: "webhook_callback_verification_pending" }] });
            }
            if (method === "GET") {
                return this.json(200, {
                    data: this.subs.map((s) => ({ id: s.id, condition: { broadcaster_user_id: s.broadcaster }, transport: { callback: s.callback } })),
                });
            }
            if (method === "DELETE") {
                this.subs = this.subs.filter((s) => s.id !== url.searchParams.get("id"));
                return new Response(null, { status: 204 });
            }
        }
        return this.json(404, { message: `unhandled ${method} ${path}` });
    };

    called(method: string, pathPart: string) {
        return this.calls.filter((c) => c.method === method && c.url.includes(pathPart));
    }
}

// ---- the world ---------------------------------------------------------------------------------------------------------

export type WorldOpts = { stage?: boolean; twitch?: boolean; search?: boolean; env?: Partial<WorkerEnv> };

export async function world(opts: WorldOpts = {}) {
    KEY_HASH ||= await hashKey(CLIENT);
    const db: FakeD1 = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    let now = T0;
    const room = new FakeRoom();
    const twitch = new FakeTwitch();
    const space = new FakeSpace();
    const pending: Promise<unknown>[] = [];
    const env: WorkerEnv = {
        API_URL: `${API}/`,
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        ...(opts.stage === false ? {} : { STAGE_BASE_URL: STAGE }),
        ...(opts.twitch === false ? {} : { TWITCH_CLIENT_ID: TWITCH_ID, TWITCH_CLIENT_SECRET: TWITCH_SECRET, TWITCH_EVENTSUB_SECRET: EVENTSUB_SECRET }),
        ...opts.env,
    };
    const container = {
        async fetch(): Promise<Response> {
            throw new Error("the container must not be reached");
        },
    };
    const deps = () => ({
        now: () => now,
        waitUntil: (p: Promise<unknown>) => void pending.push(p),
        stageRoom: room,
        twitchFetch: twitch.fetch,
        stageEmbed: opts.search ? space : null,
    });
    const handle = (req: Request, e: WorkerEnv = env) => handleRequest(req, e, container, deps());
    // the stage host (public)
    const site = (path: string, init: RequestInit = {}) => handle(new Request(`${STAGE.replace(/\/$/, "")}${path}`, init));
    // the keyed API
    const api = (path: string, init: RequestInit = {}) => handle(new Request(`${API}${path}`, { ...init, headers: { ...AUTH, ...(init.headers as Record<string, string>) } }));
    const owner = async (method: string, path: string, body?: unknown) => {
        const res = await api(path, { method, ...(body === undefined ? {} : { body: JSON.stringify(body), headers: { "content-type": "application/json" } }) });
        return { res, body: (await res.clone().json().catch(() => null)) as any, status: res.status };
    };
    const siteJson = async (path: string, init: RequestInit = {}) => {
        const res = await site(path, init);
        return { res, body: (await res.clone().json().catch(() => null)) as any, status: res.status };
    };
    const settle = async () => {
        while (pending.length > 0) await Promise.allSettled(pending.splice(0));
    };
    // ---- data ----
    let n = 0;
    const file = (over: Partial<Record<string, unknown>> = {}) => {
        n++;
        const name10 = `File${String(n).padStart(6, "0")}`;
        const isPublic = over.visibility !== "private" && over.private !== true;
        const r: Record<string, unknown> = {
            id: `Item${String(n).padStart(12, "0")}`,
            kind: isPublic ? "public" : "private",
            source: "webp",
            bucket: isPublic ? "media" : "originals",
            r2_key: isPublic ? `${name10}.${over.ext ?? "webp"}` : `originals/${name10}.mp4`,
            url: isPublic ? `${MEDIA}${name10}.${over.ext ?? "webp"}` : null,
            name: `clip ${n}.${over.ext ?? "webp"}`,
            content_type: "image/webp",
            bytes: 4096,
            width: 480,
            height: 560,
            duration: null,
            link: null,
            session_id: null,
            key_id: "k",
            created_at: T0 - 1_000_000 + n,
            deleted_at: null,
            poster: null,
            visibility: isPublic ? "public" : "private",
            public_key: null,
            public_id: null,
            post_key: null,
            role: null,
            item_index: null,
            ...over,
        };
        delete r.private;
        delete r.ext;
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key, role, item_index)
                 VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key,@role,@item_index)`,
            )
            .run(r as any);
        return r as { id: string; name: string; url: string | null; r2_key: string; created_at: number };
    };
    const video = (over: Partial<Record<string, unknown>> = {}) =>
        file({ content_type: "video/mp4", ext: "mp4", duration: 9.6, poster: `${MEDIA}Poster${String(n + 1).padStart(4, "0")}.jpg`, source: "studio", ...over });
    const set = (id: string, items: string[], over: Record<string, unknown> = {}) => {
        db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, NULL, 'k', ?, ?)").run(id, JSON.stringify(items), T0, (over.revoked_at ?? null) as number | null);
    };
    const collection = (id: string, name: string, setIds: string[]) => {
        db.raw.prepare("INSERT INTO share_collections (id, name, key_id, created_at, updated_at) VALUES (?, ?, 'k', ?, ?)").run(id, name, T0, T0);
        setIds.forEach((s, i) => db.raw.prepare("INSERT INTO share_collection_items (collection_id, set_id, added_at) VALUES (?, ?, ?)").run(id, s, T0 + (setIds.length - i)));
    };
    const group = (id: string, name: string, collectionIds: string[]) => {
        db.raw.prepare("INSERT INTO collection_groups (id, name, key_id, created_at, updated_at) VALUES (?, ?, 'k', ?, ?)").run(id, name, T0, T0);
        collectionIds.forEach((c, i) => db.raw.prepare("INSERT INTO collection_group_items (group_id, collection_id, added_at) VALUES (?, ?, ?)").run(id, c, T0 + (collectionIds.length - i)));
    };
    const title = (postKey: string, text: string) => db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, 'k', ?)").run(postKey, text, T0);
    const embedding = (postKey: string, axisIndex: number) =>
        db.raw
            .prepare("INSERT INTO media_embeddings (post_key, model, dims, vector, input_hash, embedded_at) VALUES (?, ?, ?, ?, 'h', ?)")
            .run(postKey, EMBED_MODEL, EMBED_DIMS, encodeVector(axis(axisIndex)), T0);
    const q = <T = any>(sql: string, ...p: any[]) => db.raw.prepare(sql).all(...p) as T[];
    const one = <T = any>(sql: string, ...p: any[]) => db.raw.prepare(sql).get(...p) as T | undefined;

    // ---- twitch helpers ----
    const stageRow = () => one<any>("SELECT * FROM stage_settings WHERE id = 'main'");
    const token = async () => {
        await owner("GET", "/stage");
        return stageRow().live_token as string;
    };
    const goLive = async (patch: Record<string, unknown> = {}) => (await owner("PATCH", "/stage", { on_air: true, ...patch })).body;
    // connects Twitch through the real flow (connect -> callback) and runs the background setup
    const connectTwitch = async () => {
        const c = await owner("POST", "/stage/twitch/connect");
        const state = new URL(c.body.authorize_url).searchParams.get("state")!;
        const res = await site(`/twitch/callback?code=${twitch.code}&state=${state}`);
        await settle();
        return { res, state, authorize_url: c.body.authorize_url as string };
    };
    const rewardId = (action: string) => one<any>("SELECT twitch_reward_id FROM stage_rewards WHERE action = ?", action)?.twitch_reward_id as string;

    let evN = 0;
    // a signed EventSub delivery
    const deliver = async (
        type: "notification" | "webhook_callback_verification" | "revocation",
        payload: unknown,
        o: { id?: string; ts?: number; secret?: string; signature?: string } = {},
    ) => {
        const body = JSON.stringify(payload);
        const id = o.id ?? `msg-${++evN}`;
        const ts = new Date(o.ts ?? now).toISOString();
        const sig = o.signature ?? (await signEventSub(o.secret ?? EVENTSUB_SECRET, id, ts, body));
        return site("/twitch/eventsub", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "twitch-eventsub-message-id": id,
                "twitch-eventsub-message-timestamp": ts,
                "twitch-eventsub-message-signature": sig,
                "twitch-eventsub-message-type": type,
            },
            body,
        });
    };
    const redemption = (action: string, input = "", o: { id?: string; user?: string; cost?: number } = {}) => ({
        subscription: { type: "channel.channel_points_custom_reward_redemption.add", condition: { broadcaster_user_id: "b123" } },
        event: {
            id: o.id ?? `red-${++evN}`,
            user_id: o.user ? `u-${o.user}` : "u-viewer",
            user_login: (o.user ?? "viewer").toLowerCase(),
            user_name: o.user ?? "Viewer",
            user_input: input,
            reward: { id: rewardId(action), title: action, cost: o.cost ?? 500 },
            redeemed_at: new Date(now).toISOString(),
        },
    });
    const redeem = async (action: string, input = "", o: { id?: string; user?: string; cost?: number } = {}) => {
        const res = await deliver("notification", redemption(action, input, o));
        await settle();
        return res;
    };

    return {
        db,
        env,
        room,
        twitch,
        space,
        file,
        video,
        set,
        collection,
        group,
        title,
        embedding,
        q,
        one,
        site,
        api,
        owner,
        siteJson,
        settle,
        stageRow,
        token,
        goLive,
        connectTwitch,
        rewardId,
        deliver,
        redemption,
        redeem,
        handle,
        tick: (ms: number) => (now += ms),
        now: () => now,
        pending,
    };
}

export type World = Awaited<ReturnType<typeof world>>;
