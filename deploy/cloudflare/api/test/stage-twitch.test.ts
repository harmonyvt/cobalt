// Stage (APP-API-CONTRACT.md section 30.8, 30.9): the Twitch client, the EventSub signature and the token
// encryption, with fakes for the network.
import { describe, expect, it } from "vitest";
import {
    TwitchError,
    clearAppTokens,
    decryptToken,
    encryptToken,
    signEventSub,
    twitchClient,
    twitchConfigFrom,
    verifyEventSub,
} from "../src/stage-twitch";
import { EVENTSUB_SECRET, FakeTwitch, TWITCH_ID, TWITCH_SECRET } from "./stage-world";

const cfg = { clientId: TWITCH_ID, clientSecret: TWITCH_SECRET, eventsubSecret: EVENTSUB_SECRET };

describe("config", () => {
    it("needs all three secrets, non-empty", () => {
        expect(twitchConfigFrom({ TWITCH_CLIENT_ID: "a", TWITCH_CLIENT_SECRET: "b", TWITCH_EVENTSUB_SECRET: "c" })).toEqual({ clientId: "a", clientSecret: "b", eventsubSecret: "c" });
        expect(twitchConfigFrom({ TWITCH_CLIENT_ID: "a", TWITCH_CLIENT_SECRET: "b" })).toBeNull();
        expect(twitchConfigFrom({ TWITCH_CLIENT_ID: "a", TWITCH_CLIENT_SECRET: " ", TWITCH_EVENTSUB_SECRET: "c" })).toBeNull();
        expect(twitchConfigFrom({})).toBeNull();
    });
});

describe("the client", () => {
    it("builds the broadcaster authorize URL", () => {
        const url = new URL(twitchClient(cfg, new FakeTwitch().fetch).authorizeUrl("https://studio.capybaraharmony.com/twitch/callback", "STATE"));
        expect(url.origin + url.pathname).toBe("https://id.twitch.tv/oauth2/authorize");
        expect(Object.fromEntries(url.searchParams)).toEqual({
            response_type: "code",
            client_id: TWITCH_ID,
            redirect_uri: "https://studio.capybaraharmony.com/twitch/callback",
            scope: "channel:manage:redemptions",
            state: "STATE",
            force_verify: "true",
        });
        expect(url.search).toContain("scope=channel%3Amanage%3Aredemptions");
    });

    it("exchanges a code and refreshes with a form body and the client secret", async () => {
        const t = new FakeTwitch();
        const c = twitchClient(cfg, t.fetch);
        const tok = await c.exchangeCode("good-code", "https://x/cb");
        expect(tok).toEqual({ access_token: "at-1", refresh_token: "rt-1", expires_in: 14400, scope: ["channel:manage:redemptions"] });
        const call = t.calls[0]!;
        expect(call.method).toBe("POST");
        expect(call.url).toBe("https://id.twitch.tv/oauth2/token");
        expect(call.headers.get("content-type")).toBe("application/x-www-form-urlencoded");
        expect(call.body).toEqual({ client_id: TWITCH_ID, client_secret: TWITCH_SECRET, code: "good-code", grant_type: "authorization_code", redirect_uri: "https://x/cb" });
        await c.refresh("rt-1");
        expect(t.calls[1]!.body).toMatchObject({ grant_type: "refresh_token", refresh_token: "rt-1" });
        t.refreshFails = true;
        await expect(c.refresh("rt-1")).rejects.toMatchObject({ name: "TwitchError", status: 400, detail: "Invalid refresh token" });
        await expect(c.exchangeCode("bad", "https://x/cb")).rejects.toBeInstanceOf(TwitchError);
    });

    it("caches the app token until it nearly expires", async () => {
        clearAppTokens();
        const t = new FakeTwitch();
        let now = 1_000;
        const c = twitchClient(cfg, t.fetch, () => now);
        expect(await c.appToken()).toBe("app-token");
        expect(await c.appToken()).toBe("app-token");
        expect(t.calls.filter((x) => x.body?.grant_type === "client_credentials")).toHaveLength(1);
        now += 5_000_000 * 1000;
        await c.appToken();
        expect(t.calls.filter((x) => x.body?.grant_type === "client_credentials")).toHaveLength(2);
    });

    it("keeps the app token across clients (every request builds a new one), and drops it when Helix says 401", async () => {
        clearAppTokens();
        const t = new FakeTwitch();
        const grants = () => t.calls.filter((x) => x.body?.grant_type === "client_credentials").length;
        expect(await twitchClient(cfg, t.fetch).appToken()).toBe("app-token");
        expect(await twitchClient(cfg, t.fetch).appToken()).toBe("app-token");
        expect(await twitchClient(cfg, t.fetch).appToken()).toBe("app-token");
        expect(grants()).toBe(1);
        // another app's token is not this app's
        await twitchClient({ ...cfg, clientId: "other" }, t.fetch).appToken();
        expect(grants()).toBe(2);
        // Twitch no longer accepts it: the next call asks for a new one
        t.validAccess.delete("app-token");
        const c = twitchClient(cfg, async (u, i) => {
            const res = await t.fetch(u, i);
            return u.includes("/helix/") ? new Response("{}", { status: 401 }) : res;
        });
        await expect(c.deleteSubscription("app-token", "x")).rejects.toMatchObject({ status: 401 });
        await twitchClient(cfg, t.fetch).appToken();
        expect(grants()).toBe(3);
    });

    it("gives up on a call that never answers, as a TwitchError with status 0", async () => {
        const never = (_u: string, init?: RequestInit) =>
            new Promise<Response>((_res, rej) => init?.signal?.addEventListener("abort", () => rej(new DOMException("aborted", "AbortError"))));
        const hung = twitchClient(cfg, never, () => Date.now(), 20);
        const started = Date.now();
        await expect(hung.user("tok")).rejects.toMatchObject({ name: "TwitchError", status: 0, detail: "timeout" });
        await expect(hung.refresh("rt")).rejects.toMatchObject({ status: 0, detail: "timeout" });
        expect(Date.now() - started).toBeLessThan(2000);
        // a fetch that ignores the abort signal is raced all the same
        const deaf = twitchClient(cfg, () => new Promise<Response>(() => {}), () => Date.now(), 20);
        await expect(deaf.validate("tok")).rejects.toMatchObject({ status: 0, detail: "timeout" });
    });

    it("validates with 'OAuth <token>'", async () => {
        const t = new FakeTwitch();
        t.viewers.set("tok", { client_id: TWITCH_ID, login: "ann", user_id: "7" });
        const c = twitchClient(cfg, t.fetch);
        expect(await c.validate("tok")).toEqual({ client_id: TWITCH_ID, login: "ann", user_id: "7", scopes: [], expires_in: 1000 });
        expect(t.calls[0]!.headers.get("authorization")).toBe("OAuth tok");
        await expect(c.validate("nope")).rejects.toMatchObject({ status: 401 });
    });

    it("sends Client-Id and Bearer, and the documented reward fields", async () => {
        const t = new FakeTwitch();
        const c = twitchClient(cfg, t.fetch);
        expect(await c.user("at-1")).toEqual({ id: "b123", login: "harmony", display_name: "Harmony" });
        expect(t.calls[0]!.url).toBe("https://api.twitch.tv/helix/users");
        expect(t.calls[0]!.headers.get("client-id")).toBe(TWITCH_ID);
        expect(t.calls[0]!.headers.get("authorization")).toBe("Bearer at-1");
        const made = await c.createReward("at-1", "b123", {
            title: "summon",
            cost: 500,
            prompt: "p",
            is_enabled: true,
            is_user_input_required: true,
            is_global_cooldown_enabled: true,
            global_cooldown_seconds: 30,
            should_redemptions_skip_request_queue: false,
        });
        expect(made.title).toBe("summon");
        expect(t.calls[1]!.url).toBe("https://api.twitch.tv/helix/channel_points/custom_rewards?broadcaster_id=b123");
        expect(t.calls[1]!.body).toMatchObject({ title: "summon", cost: 500, is_user_input_required: true, should_redemptions_skip_request_queue: false });
        await c.updateReward("at-1", "b123", made.id, { cost: 600 });
        expect(t.calls[2]!.method).toBe("PATCH");
        expect(t.calls[2]!.url).toBe(`https://api.twitch.tv/helix/channel_points/custom_rewards?broadcaster_id=b123&id=${made.id}`);
        await c.setRedemption("at-1", "b123", made.id, "red-1", "FULFILLED");
        expect(t.calls[3]!.url).toBe(`https://api.twitch.tv/helix/channel_points/custom_rewards/redemptions?broadcaster_id=b123&reward_id=${made.id}&id=red-1`);
        expect(t.calls[3]!.body).toEqual({ status: "FULFILLED" });
        expect(await c.listManageableRewards("at-1", "b123")).toEqual([{ id: made.id, title: "summon" }]);
        expect(t.calls[4]!.url).toContain("only_manageable_rewards=true");
        await c.deleteReward("at-1", "b123", made.id);
        expect(t.calls[5]!.method).toBe("DELETE");
        expect(t.rewards.size).toBe(0);
    });

    it("subscribes with the app token, adopts an existing subscription on 409, and deletes", async () => {
        const t = new FakeTwitch();
        const c = twitchClient(cfg, t.fetch);
        const id = await c.createSubscription("app-token", "b123", "https://studio.capybaraharmony.com/twitch/eventsub");
        expect(t.calls[0]!.body).toEqual({
            type: "channel.channel_points_custom_reward_redemption.add",
            version: "1",
            condition: { broadcaster_user_id: "b123" },
            transport: { method: "webhook", callback: "https://studio.capybaraharmony.com/twitch/eventsub", secret: EVENTSUB_SECRET },
        });
        expect(await c.createSubscription("app-token", "b123", "https://studio.capybaraharmony.com/twitch/eventsub")).toBe(id);
        await c.deleteSubscription("app-token", id);
        expect(t.subs).toEqual([]);
    });

    it("turns a network failure into a TwitchError with status 0", async () => {
        const c = twitchClient(cfg, async () => {
            throw new TypeError("offline");
        });
        await expect(c.user("x")).rejects.toMatchObject({ name: "TwitchError", status: 0 });
    });
});

describe("EventSub signature (30.9)", () => {
    const body = '{"a":1}';
    it("accepts sha256= + hex HMAC of id + timestamp + body", async () => {
        const sig = await signEventSub("secret-secret-1", "id1", "2026-10-19T10:00:00Z", body);
        expect(sig).toMatch(/^sha256=[0-9a-f]{64}$/);
        expect(await verifyEventSub("secret-secret-1", "id1", "2026-10-19T10:00:00Z", body, sig)).toBe(true);
    });
    it("rejects a different secret, id, timestamp or body, and malformed headers", async () => {
        const sig = await signEventSub("secret-secret-1", "id1", "ts", body);
        expect(await verifyEventSub("secret-secret-2", "id1", "ts", body, sig)).toBe(false);
        expect(await verifyEventSub("secret-secret-1", "id2", "ts", body, sig)).toBe(false);
        expect(await verifyEventSub("secret-secret-1", "id1", "ts2", body, sig)).toBe(false);
        expect(await verifyEventSub("secret-secret-1", "id1", "ts", body + " ", sig)).toBe(false);
        for (const bad of [null, "", "sha256=", "sha256=zz", sig.slice("sha256=".length), "sha1=" + sig.slice(7), sig.slice(0, -2)]) {
            expect(await verifyEventSub("secret-secret-1", "id1", "ts", body, bad), String(bad)).toBe(false);
        }
        expect(await verifyEventSub("secret-secret-1", null, "ts", body, sig)).toBe(false);
        expect(await verifyEventSub("secret-secret-1", "id1", null, body, sig)).toBe(false);
    });
});

describe("token encryption (30.2)", () => {
    it("round-trips as base64(iv).base64(ciphertext)", async () => {
        const stored = await encryptToken("client-secret", "access-token-value");
        expect(stored).toMatch(/^[A-Za-z0-9+/]{16}={0,2}\.[A-Za-z0-9+/]+={0,2}$/);
        expect(stored).not.toContain("access-token-value");
        expect(await decryptToken("client-secret", stored)).toBe("access-token-value");
    });
    it("uses a fresh iv each time, and the key follows the client secret", async () => {
        const a = await encryptToken("client-secret", "t");
        const b = await encryptToken("client-secret", "t");
        expect(a).not.toBe(b);
        await expect(decryptToken("another-secret", a)).rejects.toThrow();
    });
    it("fails on a damaged or malformed value", async () => {
        const stored = await encryptToken("client-secret", "token");
        const [iv, ct] = stored.split(".");
        const flipped = ct!.slice(0, 2) === "AA" ? "BB" + ct!.slice(2) : "AA" + ct!.slice(2);
        await expect(decryptToken("client-secret", `${iv}.${flipped}`)).rejects.toThrow();
        await expect(decryptToken("client-secret", "nodot")).rejects.toThrow();
        await expect(decryptToken("client-secret", "")).rejects.toThrow();
    });
    it("a fixed iv gives a stable value (the format is base64 of 12 bytes)", async () => {
        const stored = await encryptToken("k", "x", new Uint8Array(12));
        expect(stored.startsWith("AAAAAAAAAAAAAAAA.")).toBe(true);
    });
});
