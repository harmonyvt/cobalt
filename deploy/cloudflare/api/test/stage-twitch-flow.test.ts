// Stage (APP-API-CONTRACT.md section 29.8-29.10): connecting Twitch, keeping the rewards and the EventSub
// subscription in step, the webhook, and what each redemption does. Fake Twitch, fake room, real SQL.
import { describe, expect, it } from "vitest";
import { encryptToken } from "../src/stage-twitch";
import { T0, STAGE, TWITCH_SECRET, world, type World } from "./stage-world";

const COLL = "Coll000000000001";
void COLL;

// a world that is on air, with Twitch connected and three public files
async function live(opts: Parameters<typeof world>[0] = {}) {
    const w = await world(opts);
    const files = [w.file({ name: "red cat.webp" }), w.file({ name: "blue dog.webp" }), w.video({ name: "green frog.mp4" })];
    await w.goLive();
    await w.connectTwitch();
    // the first read resolves the pool (and gives every file its code)
    await w.siteJson(`/live/${await w.token()}/state`);
    w.room.events.length = 0;
    return { w, files };
}
const itemCode = (w: World, id: string) => w.one("SELECT code FROM stage_codes WHERE item_id = ?", id).code as string;
const lastRow = (w: World) => w.one("SELECT * FROM stage_redemptions ORDER BY rowid DESC LIMIT 1");

describe("connecting (29.8)", () => {
    it("POST /stage/twitch/connect returns the authorize URL and keeps its state for 10 minutes", async () => {
        const w = await world();
        const r = await w.owner("POST", "/stage/twitch/connect");
        expect(r.status).toBe(200);
        const u = new URL(r.body.authorize_url);
        expect(u.origin + u.pathname).toBe("https://id.twitch.tv/oauth2/authorize");
        expect(u.searchParams.get("response_type")).toBe("code");
        expect(u.searchParams.get("client_id")).toBe("twitch-client-id");
        expect(u.searchParams.get("redirect_uri")).toBe(`${STAGE}twitch/callback`);
        expect(u.searchParams.get("scope")).toBe("channel:manage:redemptions");
        expect(u.searchParams.get("force_verify")).toBe("true");
        expect(u.searchParams.get("state")).toMatch(/^[A-Za-z0-9]{32}$/);
        expect(w.stageRow()).toMatchObject({ oauth_state: u.searchParams.get("state"), oauth_state_at: T0 });
        expect(r.res.headers.get("cache-control")).toBe("no-store");
    });

    it("without the Twitch secrets connect and disconnect are 404 error.stage.twitch_off", async () => {
        const w = await world({ twitch: false });
        for (const [m, p] of [["POST", "/stage/twitch/connect"], ["DELETE", "/stage/twitch"]] as const) {
            const r = await w.owner(m, p);
            expect(r.status).toBe(404);
            expect(r.body.error.code).toBe("error.stage.twitch_off");
        }
        const cb = await w.site("/twitch/callback?code=x&state=y");
        expect(cb.status).toBe(400);
        expect(await cb.text()).toContain("twitch=failed&reason=off");
    });

    it("the callback stores the channel with encrypted tokens, makes the four rewards and the subscription", async () => {
        const w = await world();
        const { res } = await w.connectTwitch();
        expect(res.status).toBe(200);
        const html = await res.text();
        expect(html).toContain("twitch is connected. you can close this.");
        expect(html).toContain("cobalt-apple://stage?twitch=connected");

        const row = w.one("SELECT * FROM stage_twitch");
        expect(row).toMatchObject({ broadcaster_id: "b123", login: "harmony", display_name: "Harmony", scopes: "channel:manage:redemptions", connected_at: T0 });
        expect(row.expires_at).toBe(T0 + 14400 * 1000);
        expect(row.access_token).toMatch(/^[A-Za-z0-9+/=]+\.[A-Za-z0-9+/=]+$/);
        expect(JSON.stringify(row)).not.toContain("at-1");
        expect(JSON.stringify(row)).not.toContain("rt-1");
        // the state is spent
        expect(w.stageRow().oauth_state).toBeNull();

        // one reward per action, as the rows say
        const rewards = [...w.twitch.rewards.values()];
        expect(rewards.map((r) => r.title)).toEqual(["summon", "chaos", "shuffle", "pin"]);
        expect(rewards.map((r) => [r.cost, r.cooldown, r.is_enabled, r.input])).toEqual([
            [500, 30, true, true],
            [2000, 300, true, false],
            [1000, 120, true, false],
            [300, 60, false, false],
        ]);
        const posts = w.twitch.called("POST", "/custom_rewards");
        for (const p of posts) expect(p.body.should_redemptions_skip_request_queue).toBe(false);
        expect(posts[0]!.body.prompt).toBe("a code from the store, or a few words");
        const rows = w.q("SELECT * FROM stage_rewards");
        for (const r of rows) expect(r).toMatchObject({ synced: 1 });
        expect(rows.map((r) => r.twitch_reward_id).sort()).toEqual(rewards.map((r) => r.id).sort());

        // the subscription, made with an app token
        expect(w.twitch.subs).toHaveLength(1);
        expect(w.twitch.subs[0]).toMatchObject({ broadcaster: "b123", callback: `${STAGE}twitch/eventsub`, secret: "eventsub-secret-0123456789" });
        expect(w.twitch.called("POST", "/eventsub/subscriptions")[0]!.headers.get("authorization")).toBe("Bearer app-token");
    });

    it("GET /stage then reports the channel as ok with its rewards synced", async () => {
        const w = await world();
        await w.connectTwitch();
        const r = await w.owner("GET", "/stage");
        expect(r.body.stage.twitch).toEqual({ login: "harmony", display_name: "Harmony", connected_at: T0, status: "ok", last_event_at: null });
        expect(r.body.rewards.every((x: any) => x.synced)).toBe(true);
        expect(w.one("SELECT eventsub_id FROM stage_twitch").eventsub_id).toMatch(/^sub-/);
        // nothing left to retry: no more Twitch calls
        const before = w.twitch.calls.length;
        await w.owner("GET", "/stage");
        await w.settle();
        expect(w.twitch.calls.length).toBe(before);
    });

    it("checks the state: wrong, missing, expired and replayed are refused, and the code is never exchanged", async () => {
        const w = await world();
        const c = await w.owner("POST", "/stage/twitch/connect");
        const state = new URL(c.body.authorize_url).searchParams.get("state")!;
        for (const q of [`code=good-code&state=${"x".repeat(32)}`, "code=good-code", `code=good-code&state=${state.slice(0, 31)}`, `state=${state}`]) {
            const r = await w.site(`/twitch/callback?${q}`);
            expect(r.status, q).toBe(400);
            expect(await r.text()).toContain("twitch=failed&reason=");
            // any attempt spends the state
            await w.owner("POST", "/stage/twitch/connect");
        }
        expect(w.twitch.called("POST", "/oauth2/token")).toHaveLength(0);

        // expired
        const c2 = await w.owner("POST", "/stage/twitch/connect");
        const s2 = new URL(c2.body.authorize_url).searchParams.get("state")!;
        w.tick(10 * 60_000 + 1);
        const expired = await w.site(`/twitch/callback?code=good-code&state=${s2}`);
        expect(await expired.text()).toContain("reason=state");
        expect(w.one("SELECT * FROM stage_twitch")).toBeUndefined();

        // single use
        const c3 = await w.owner("POST", "/stage/twitch/connect");
        const s3 = new URL(c3.body.authorize_url).searchParams.get("state")!;
        expect((await w.site(`/twitch/callback?code=good-code&state=${s3}`)).status).toBe(200);
        await w.settle();
        const replay = await w.site(`/twitch/callback?code=good-code&state=${s3}`);
        expect(replay.status).toBe(400);
        expect(await replay.text()).toContain("reason=state");
        expect(w.twitch.called("POST", "/oauth2/token").filter((t) => t.body.grant_type === "authorization_code")).toHaveLength(1);
        // and a callback nobody asked for
        expect((await w.site("/twitch/callback?code=good-code&state=whatever")).status).toBe(400);
    });

    it("a refusal on Twitch's side comes back as failed with a reason", async () => {
        const w = await world();
        const go = async (q: string) => {
            const c = await w.owner("POST", "/stage/twitch/connect");
            const state = new URL(c.body.authorize_url).searchParams.get("state")!;
            const r = await w.site(`/twitch/callback?${q.replace("STATE", state)}`);
            return { status: r.status, html: await r.text() };
        };
        const denied = await go("error=access_denied&state=STATE");
        expect(denied.html).toContain("reason=denied");
        w.twitch.code = "other";
        expect((await go("code=good-code&state=STATE")).html).toContain("reason=exchange");
        w.twitch.code = "good-code";
        w.twitch.scope = [];
        expect((await go("code=good-code&state=STATE")).html).toContain("reason=scope");
        expect(w.one("SELECT * FROM stage_twitch")).toBeUndefined();
    });

    it("channel points need an affiliate: Twitch's 403 is not_affiliate, and it is tried again after 10 minutes", async () => {
        const w = await world();
        w.twitch.forbidRewards = true;
        await w.connectTwitch();
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("not_affiliate");
        await w.settle();
        w.twitch.forbidRewards = false;
        const before = w.twitch.calls.length;
        w.tick(5 * 60_000);
        await w.owner("GET", "/stage");
        await w.settle();
        expect(w.twitch.calls.length).toBe(before);
        w.tick(6 * 60_000);
        await w.owner("GET", "/stage");
        await w.settle();
        const r = await w.owner("GET", "/stage");
        expect(r.body.stage.twitch.status).toBe("ok");
        expect(w.twitch.rewards.size).toBe(4);
    });

    it("a title Twitch already has (not ours) gets the 'capystore ' prefix", async () => {
        const w = await world();
        w.twitch.takenTitles.add("summon");
        w.twitch.takenTitles.add("pin");
        await w.connectTwitch();
        expect([...w.twitch.rewards.values()].map((r) => r.title).sort()).toEqual(["capystore pin", "capystore summon", "chaos", "shuffle"]);
        const r = await w.owner("GET", "/stage");
        expect(r.body.rewards.map((x: any) => x.title)).toEqual(["capystore summon", "chaos", "shuffle", "capystore pin"]);
    });

    it("rewards this app already made are adopted on a reconnect, not duplicated", async () => {
        const w = await world();
        await w.connectTwitch();
        const ids = [...w.twitch.rewards.keys()];
        // the row was lost (say, a manual cleanup), the rewards are still on the channel
        w.db.raw.exec("DELETE FROM stage_twitch; UPDATE stage_rewards SET twitch_reward_id = NULL, synced = 0");
        await w.connectTwitch();
        expect([...w.twitch.rewards.keys()].sort()).toEqual(ids.sort());
        expect(w.q("SELECT twitch_reward_id FROM stage_rewards").map((r) => r.twitch_reward_id).sort()).toEqual(ids.sort());
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("ok");
    });

    it("a step that failed leaves the connection stored and the next GET /stage retries it", async () => {
        const w = await world();
        w.twitch.failSubscriptions = true;
        await w.connectTwitch();
        const first = await w.owner("GET", "/stage");
        expect(first.body.stage.twitch.status).toBe("setting_up");
        await w.settle();
        expect(w.one("SELECT eventsub_id FROM stage_twitch").eventsub_id).toBeNull();
        w.twitch.failSubscriptions = false;
        await w.owner("GET", "/stage");
        await w.settle();
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("ok");
        expect(w.twitch.subs).toHaveLength(1);
        expect(w.twitch.rewards.size).toBe(4);
    });

    it("connecting a different channel drops the old channel's subscription and rewards", async () => {
        const w = await world();
        await w.connectTwitch();
        w.db.raw.prepare("UPDATE stage_twitch SET broadcaster_id = 'old-channel'").run();
        await w.connectTwitch();
        expect(w.one("SELECT broadcaster_id FROM stage_twitch").broadcaster_id).toBe("b123");
        expect(w.twitch.subs).toHaveLength(1);
        expect(w.twitch.rewards.size).toBe(4);
    });
});

describe("tokens (29.8)", () => {
    it("are refreshed when they expire within 5 minutes, and the new ones are stored encrypted", async () => {
        const { w, files } = await live();
        w.tick(14400 * 1000 - 4 * 60_000);
        await w.owner("PATCH", "/stage", { on_air: true });
        await w.redeem("summon", itemCode(w, files[0]!.id));
        const refresh = w.twitch.called("POST", "/oauth2/token").filter((c) => c.body.grant_type === "refresh_token");
        expect(refresh).toHaveLength(1);
        expect(refresh[0]!.body.refresh_token).toBe("rt-1");
        const fulfil = w.twitch.called("PATCH", "/redemptions")[0]!;
        expect(fulfil.headers.get("authorization")).toMatch(/^Bearer at-r/);
        const row = w.one("SELECT * FROM stage_twitch");
        expect(row.expires_at).toBe(w.now() + 14400 * 1000);
        expect(JSON.stringify(row)).not.toContain("at-r");
        expect(lastRow(w).status).toBe("done");
    });

    it("a Helix 401 refreshes once and tries again", async () => {
        const { w, files } = await live();
        w.twitch.unauthorizedOnce = 1;
        await w.redeem("summon", itemCode(w, files[1]!.id));
        expect(w.twitch.called("POST", "/oauth2/token").filter((c) => c.body.grant_type === "refresh_token")).toHaveLength(1);
        expect(w.twitch.redemptions).toHaveLength(1);
        expect(lastRow(w).status).toBe("done");
    });

    it("a failed refresh is status reconnect, and it is not retried until the owner connects again", async () => {
        const { w, files } = await live();
        w.twitch.refreshFails = true;
        w.tick(14400 * 1000);
        await w.redeem("summon", itemCode(w, files[0]!.id));
        expect(lastRow(w)).toMatchObject({ status: "failed", reason: "error" });
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("reconnect");
        await w.settle();
        const calls = w.twitch.calls.length;
        await w.owner("GET", "/stage");
        await w.settle();
        expect(w.twitch.calls.length).toBe(calls);
        // connecting again fixes it
        w.twitch.refreshFails = false;
        await w.connectTwitch();
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("ok");
    });

    it("tokens the client secret cannot open any more mean reconnect", async () => {
        const { w, files } = await live();
        w.db.raw.prepare("UPDATE stage_twitch SET access_token = ?, refresh_token = ?").run(await encryptToken("some-other-secret", "a"), await encryptToken("some-other-secret", "r"));
        await w.redeem("summon", itemCode(w, files[0]!.id));
        expect((await w.owner("GET", "/stage")).body.stage.twitch.status).toBe("reconnect");
        void TWITCH_SECRET;
    });
});

describe("disconnecting (29.8)", () => {
    it("DELETE /stage/twitch removes the subscription, the rewards and the row", async () => {
        const { w } = await live();
        const r = await w.owner("DELETE", "/stage/twitch");
        expect(r.status).toBe(200);
        expect(r.body.stage.twitch).toBeNull();
        expect(w.twitch.subs).toEqual([]);
        expect(w.twitch.rewards.size).toBe(0);
        expect(w.one("SELECT * FROM stage_twitch")).toBeUndefined();
        expect(w.q("SELECT twitch_reward_id, synced, title FROM stage_rewards").every((x) => x.twitch_reward_id === null && x.synced === 0)).toBe(true);
        // the store has no rewards again
        await w.owner("PATCH", "/stage", { store_open: true });
        expect((await w.siteJson("/store/api/rewards")).body.channel).toBeNull();
    });

    it("is best effort: Twitch refusing does not keep the row", async () => {
        const { w } = await live();
        w.twitch.refreshFails = true;
        w.db.raw.prepare("UPDATE stage_twitch SET expires_at = 0").run();
        const r = await w.owner("DELETE", "/stage/twitch");
        expect(r.status).toBe(200);
        expect(w.one("SELECT * FROM stage_twitch")).toBeUndefined();
    });
});

describe("PATCH /stage/rewards/<action> (29.10)", () => {
    it("validates", async () => {
        const w = await world();
        for (const body of [{}, { cost: 0 }, { cost: 1_000_001 }, { cost: 1.5 }, { cost: "5" }, { cooldown_seconds: -1 }, { cooldown_seconds: 604_801 }, { enabled: "yes" }]) {
            const r = await w.owner("PATCH", "/stage/rewards/summon", body);
            expect(r.status, JSON.stringify(body)).toBe(400);
        }
        expect((await w.api("/stage/rewards/summon", { method: "PATCH", body: "x" })).status).toBe(400);
        expect((await w.owner("PATCH", "/stage/rewards/bogus", { cost: 5 })).status).toBe(404);
    });

    it("saves without Twitch: synced stays false", async () => {
        const w = await world();
        const r = await w.owner("PATCH", "/stage/rewards/chaos", { cost: 1234, cooldown_seconds: 0, enabled: false });
        expect(r.status).toBe(200);
        expect(r.body.reward).toEqual({ action: "chaos", title: "chaos", cost: 1234, cooldown_seconds: 0, enabled: false, synced: false });
        const g = await w.owner("GET", "/stage");
        expect(g.body.rewards[1]).toMatchObject({ cost: 1234, cooldown_seconds: 0, enabled: false });
        // untouched fields keep their value
        const only = await w.owner("PATCH", "/stage/rewards/chaos", { enabled: true });
        expect(only.body.reward).toMatchObject({ cost: 1234, cooldown_seconds: 0, enabled: true });
    });

    it("updates the Twitch reward when connected", async () => {
        const { w } = await live();
        const id = w.rewardId("pin");
        const r = await w.owner("PATCH", "/stage/rewards/pin", { cost: 777, enabled: true, cooldown_seconds: 90 });
        expect(r.body.reward).toEqual({ action: "pin", title: "pin", cost: 777, cooldown_seconds: 90, enabled: true, synced: true });
        expect(w.twitch.rewards.get(id)).toMatchObject({ cost: 777, is_enabled: true, cooldown: 90 });
        // no cooldown: the global cooldown is switched off on Twitch
        await w.owner("PATCH", "/stage/rewards/pin", { cooldown_seconds: 0 });
        expect(w.twitch.rewards.get(id)!.cooldown).toBeNull();
    });

    it("when Twitch refuses it is saved with synced false, and the next GET /stage retries", async () => {
        const { w } = await live();
        w.twitch.failRewardUpdates = true;
        const r = await w.owner("PATCH", "/stage/rewards/shuffle", { cost: 4242 });
        expect(r.status).toBe(200);
        expect(r.body.reward).toMatchObject({ cost: 4242, synced: false });
        expect(w.twitch.rewards.get(w.rewardId("shuffle"))!.cost).toBe(1000);
        w.twitch.failRewardUpdates = false;
        const g = await w.owner("GET", "/stage");
        expect(g.body.rewards[2]).toMatchObject({ action: "shuffle", cost: 4242, synced: false });
        await w.settle();
        expect(w.twitch.rewards.get(w.rewardId("shuffle"))!.cost).toBe(4242);
        expect((await w.owner("GET", "/stage")).body.rewards[2].synced).toBe(true);
    });

    it("a reward deleted on Twitch by hand is made again", async () => {
        const { w } = await live();
        w.twitch.rewards.delete(w.rewardId("chaos"));
        const r = await w.owner("PATCH", "/stage/rewards/chaos", { cost: 2500 });
        expect(r.body.reward.synced).toBe(true);
        expect([...w.twitch.rewards.values()].find((x) => x.title === "chaos")).toMatchObject({ cost: 2500 });
        expect(w.rewardId("chaos")).toBe([...w.twitch.rewards.values()].find((x) => x.title === "chaos")!.id);
    });
});

describe("the EventSub webhook (29.9)", () => {
    it("answers the verification challenge as text/plain", async () => {
        const w = await world();
        const r = await w.deliver("webhook_callback_verification", { challenge: "pogchamp-kappa-360noscope-vohiyo", subscription: {} });
        expect(r.status).toBe(200);
        expect(r.headers.get("content-type")).toContain("text/plain");
        expect(await r.text()).toBe("pogchamp-kappa-360noscope-vohiyo");
    });

    it("refuses a bad signature, a stale or future timestamp, and missing headers with 403", async () => {
        const { w, files } = await live();
        const payload = w.redemption("summon", itemCode(w, files[0]!.id));
        expect((await w.deliver("notification", payload, { secret: "the-wrong-secret" })).status).toBe(403);
        expect((await w.deliver("notification", payload, { signature: "sha256=" + "0".repeat(64) })).status).toBe(403);
        expect((await w.deliver("notification", payload, { ts: w.now() - 10 * 60_000 - 1000 })).status).toBe(403);
        expect((await w.deliver("notification", payload, { ts: w.now() + 10 * 60_000 + 1000 })).status).toBe(403);
        expect((await w.deliver("webhook_callback_verification", { challenge: "x" }, { secret: "nope" })).status).toBe(403);
        const bare = await w.site("/twitch/eventsub", { method: "POST", body: JSON.stringify(payload) });
        expect(bare.status).toBe(403);
        await w.settle();
        expect(w.q("SELECT * FROM stage_redemptions")).toEqual([]);
        expect(w.room.events).toEqual([]);
        // a good one 9 minutes old is fine
        expect((await w.deliver("notification", payload, { ts: w.now() - 9 * 60_000 })).status).toBe(204);
        // only POST, only with Twitch configured
        expect((await w.site("/twitch/eventsub")).status).toBe(404);
        const off = await world({ twitch: false });
        expect((await off.site("/twitch/eventsub", { method: "POST", body: "{}" })).status).toBe(404);
    });

    it("a message id seen in the last 10 minutes is answered 204 and ignored", async () => {
        const { w, files } = await live();
        const payload = w.redemption("summon", itemCode(w, files[0]!.id), { id: "red-dup" });
        expect((await w.deliver("notification", payload, { id: "msg-dup" })).status).toBe(204);
        await w.settle();
        expect((await w.deliver("notification", payload, { id: "msg-dup" })).status).toBe(204);
        await w.settle();
        expect(w.q("SELECT * FROM stage_redemptions")).toHaveLength(1);
        expect(w.twitch.redemptions).toHaveLength(1);
        expect(w.room.types()).toEqual(["summon"]);
        // 10 minutes later the id is forgotten, but the redemption itself is still only done once
        w.tick(10 * 60_000 + 1);
        expect((await w.deliver("notification", payload, { id: "msg-dup" })).status).toBe(204);
        await w.settle();
        expect(w.q("SELECT * FROM stage_redemptions")).toHaveLength(1);
        expect(w.room.types()).toEqual(["summon"]);
    });

    it("a revocation clears the subscription id", async () => {
        const { w } = await live();
        expect(w.one("SELECT eventsub_id FROM stage_twitch").eventsub_id).not.toBeNull();
        expect((await w.deliver("revocation", { subscription: { status: "authorization_revoked" } })).status).toBe(204);
        expect(w.one("SELECT eventsub_id FROM stage_twitch").eventsub_id).toBeNull();
        // the next GET /stage makes a new subscription
        w.twitch.subs = [];
        await w.owner("GET", "/stage");
        await w.settle();
        expect(w.twitch.subs).toHaveLength(1);
    });

    it("a reward that is not one of ours is ignored", async () => {
        const { w } = await live();
        const payload = w.redemption("summon", "x");
        payload.event.reward.id = "someone-elses-reward";
        expect((await w.deliver("notification", payload)).status).toBe(204);
        await w.settle();
        expect(w.q("SELECT * FROM stage_redemptions")).toEqual([]);
        expect(w.twitch.redemptions).toEqual([]);
        expect(w.room.events).toEqual([]);
    });

    it("answers 204 at once and finishes in the background", async () => {
        const { w, files } = await live();
        let release!: () => void;
        w.twitch.redemptionGate = new Promise((r) => (release = r));
        const res = await w.deliver("notification", w.redemption("summon", itemCode(w, files[0]!.id)));
        expect(res.status).toBe(204);
        expect(w.pending.length).toBeGreaterThan(0);
        expect(w.twitch.redemptions).toEqual([]);
        release();
        await w.settle();
        expect(w.twitch.redemptions).toHaveLength(1);
        expect(lastRow(w).status).toBe("done");
    });

    it("records last_event_at", async () => {
        const { w, files } = await live();
        await w.redeem("summon", itemCode(w, files[0]!.id));
        expect(w.one("SELECT last_event_at FROM stage_twitch").last_event_at).toBe(T0);
        expect((await w.owner("GET", "/stage")).body.stage.twitch.last_event_at).toBe(T0);
    });
});

describe("summon (29.9)", () => {
    it("by code, in any case: the spotlight, a toast, FULFILLED, and a done row", async () => {
        const { w, files } = await live();
        const code = itemCode(w, files[1]!.id);
        const r = await w.redeem("summon", ` ${code.toLowerCase()} `, { user: "Ann", cost: 500 });
        expect(r.status).toBe(204);
        const ev = w.room.last("summon")!;
        expect(ev.spotlight).toMatchObject({ by: "Ann", action: "summon", pinned_until: null, at: T0, item: { id: files[1]!.id, code, title: "blue dog" } });
        expect(ev.toast).toEqual({ by: "Ann", action: "summon", cost: 500, detail: `"${code.toLowerCase()}" → blue dog` });
        expect(w.twitch.redemptions).toEqual([{ reward_id: w.rewardId("summon"), id: expect.any(String), status: "FULFILLED" }]);
        expect(lastRow(w)).toMatchObject({ action: "summon", user_id: "u-Ann", user_login: "ann", user_name: "Ann", input: code.toLowerCase(), item_id: files[1]!.id, status: "done", reason: null });
        // the owner's feed and the viewer's own list show it
        const feed = await w.owner("GET", "/stage/redemptions");
        expect(feed.body.redemptions[0]).toMatchObject({ user_name: "Ann", item: { id: files[1]!.id }, status: "done" });
        // and the canvas state serves it to a page that connects now
        const t = await w.token();
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toMatchObject({ by: "Ann", item: { id: files[1]!.id } });
    });

    it("by words: the meaning search over the pool, the best pool post's first file", async () => {
        const { w, files } = await live({ search: true });
        // a two-photo post: both files share a post key, the lower item_index is the first
        const g2 = w.file({ name: "second.webp", post_key: "gallery-1", item_index: 1, role: "item" });
        const g1 = w.file({ name: "first.webp", post_key: "gallery-1", item_index: 0, role: "item" });
        w.space.axes = { "an animal that croaks": 2, "the pair of photos": 3 };
        w.embedding(files[0]!.id, 0);
        w.embedding(files[2]!.id, 2);
        w.embedding("gallery-1", 3);
        w.tick(11 * 60_000); // the pool takes the new files in
        await w.redeem("summon", "an animal that croaks");
        expect(w.room.last("summon")!.spotlight.item.id).toBe(files[2]!.id);
        expect(w.room.last("summon")!.toast!.detail).toBe('"an animal that croaks" → green frog');
        expect(lastRow(w)).toMatchObject({ status: "done", input: "an animal that croaks", item_id: files[2]!.id });
        await w.redeem("summon", "the pair of photos");
        expect(w.room.last("summon")!.spotlight.item.id).toBe(g1.id);
        expect(w.room.last("summon")!.spotlight.item.id).not.toBe(g2.id);
    });

    it("by words that look like a code but are not one still search", async () => {
        const { w, files } = await live({ search: true });
        w.space.axes = { cat: 0 };
        w.embedding(files[0]!.id, 0);
        await w.redeem("summon", "cat");
        expect(w.room.last("summon")!.spotlight.item.id).toBe(files[0]!.id);
    });

    it("a post outside the pool is not summoned", async () => {
        const { w, files } = await live({ search: true });
        w.space.axes = { stuff: 5 };
        const hidden = w.file({ private: true, name: "secret" });
        w.embedding(hidden.id, 5);
        w.embedding(files[0]!.id, 6);
        await w.redeem("summon", "stuff");
        expect(w.room.last("summon")).toBeUndefined();
        expect(lastRow(w)).toMatchObject({ status: "refunded", reason: "no_match" });
    });

    it("by a piece of a title when the search is off", async () => {
        const { w, files } = await live();
        await w.redeem("summon", "frog");
        expect(w.room.last("summon")!.spotlight.item.id).toBe(files[2]!.id);
        await w.redeem("summon", "RED CAT");
        expect(w.room.last("summon")!.spotlight.item.id).toBe(files[0]!.id);
    });

    it("nothing matches: refunded (CANCELED), a toast, no spotlight", async () => {
        const { w } = await live();
        await w.redeem("summon", "zzzz nothing like it", { user: "Bob", cost: 500 });
        expect(w.room.last("summon")).toBeUndefined();
        expect(w.room.last("toast")!.toast).toMatchObject({ by: "Bob", action: "summon", refunded: true, detail: 'nothing matched "zzzz nothing like it", points refunded' });
        expect(w.twitch.redemptions.map((r) => r.status)).toEqual(["CANCELED"]);
        expect(lastRow(w)).toMatchObject({ status: "refunded", reason: "no_match", item_id: null, input: "zzzz nothing like it" });
    });

    it("an empty input is a refund too", async () => {
        const { w } = await live();
        await w.redeem("summon", "");
        expect(lastRow(w)).toMatchObject({ status: "refunded", reason: "no_match" });
    });

    it("a file made private since the pool was resolved cannot be summoned by its code", async () => {
        const { w, files } = await live();
        const code = itemCode(w, files[0]!.id);
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id = ?").run(files[0]!.id);
        await w.redeem("summon", code);
        expect(w.room.last("summon")).toBeUndefined();
        expect(lastRow(w)).toMatchObject({ status: "refunded", reason: "no_match" });
    });

    it("the input is trimmed and kept to 200 characters", async () => {
        const { w } = await live();
        await w.redeem("summon", `  ${"word ".repeat(80)}  `);
        expect((lastRow(w).input as string).length).toBeLessThanOrEqual(200);
    });
});

describe("refunds (29.9)", () => {
    it("off air: every action is refunded with off_air, nothing is pushed", async () => {
        const { w, files } = await live();
        await w.owner("PATCH", "/stage", { on_air: false });
        w.room.events.length = 0;
        for (const a of ["summon", "chaos", "shuffle", "pin"]) await w.redeem(a, itemCode(w, files[0]!.id));
        expect(w.room.events).toEqual([]);
        expect(w.twitch.redemptions.map((r) => r.status)).toEqual(["CANCELED", "CANCELED", "CANCELED", "CANCELED"]);
        expect(w.q("SELECT status, reason FROM stage_redemptions")).toEqual(Array(4).fill({ status: "refunded", reason: "off_air" }));
    });

    it("a disabled action is refunded with disabled (pin is off by default)", async () => {
        const { w } = await live();
        await w.redeem("pin");
        expect(w.room.events).toEqual([]);
        expect(lastRow(w)).toMatchObject({ action: "pin", status: "refunded", reason: "disabled" });
        expect(w.twitch.redemptions.at(-1)!.status).toBe("CANCELED");
    });

    it("a Helix failure leaves the redemption in Twitch's queue and the row failed", async () => {
        const { w, files } = await live();
        w.twitch.failRedemptions = true;
        await w.redeem("summon", itemCode(w, files[0]!.id));
        expect(lastRow(w)).toMatchObject({ status: "failed", reason: "error" });
        // what happened on stream still happened
        expect(w.room.types()).toEqual(["summon"]);
        // and a refund that fails is failed too
        await w.owner("PATCH", "/stage", { on_air: false });
        await w.redeem("chaos");
        expect(lastRow(w)).toMatchObject({ action: "chaos", status: "failed", reason: "error" });
    });
});

describe("chaos, shuffle and pin (29.9)", () => {
    it("chaos lasts 30 s; another extends it to at most 60 s from now", async () => {
        const { w } = await live();
        await w.redeem("chaos", "", { user: "Ann", cost: 2000 });
        expect(w.room.last("chaos")).toMatchObject({ until: T0 + 30_000, toast: { by: "Ann", action: "chaos", cost: 2000, detail: "100 things on screen for 30 seconds" } });
        w.tick(5_000);
        await w.redeem("chaos", "", { user: "Bob", cost: 2000 });
        expect(w.room.last("chaos")!.until).toBe(T0 + 5_000 + 55_000);
        expect(w.room.last("chaos")!.toast!.detail).toBe("100 things on screen for 55 seconds");
        w.tick(25_000);
        await w.redeem("chaos", "", { user: "Cy" });
        expect(w.room.last("chaos")!.until).toBe(w.now() + 60_000);
        expect(w.twitch.redemptions.every((r) => r.status === "FULFILLED")).toBe(true);
    });

    it("shuffle sends the event and a toast", async () => {
        const { w } = await live();
        await w.redeem("shuffle", "", { user: "Ann", cost: 1000 });
        expect(w.room.last("shuffle")).toEqual({ type: "shuffle", toast: { by: "Ann", action: "shuffle", cost: 1000, detail: "wiped the canvas and refilled it" } });
        expect(lastRow(w)).toMatchObject({ action: "shuffle", status: "done" });
    });

    it("pin keeps the current spotlight up for 120 s", async () => {
        const { w, files } = await live();
        await w.owner("PATCH", "/stage/rewards/pin", { enabled: true });
        await w.redeem("summon", itemCode(w, files[0]!.id), { user: "Ann" });
        w.tick(10_000);
        await w.redeem("pin", "", { user: "Bob", cost: 300 });
        expect(w.room.last("pin")).toEqual({ type: "pin", pinned_until: w.now() + 120_000, toast: { by: "Bob", action: "pin", cost: 300, detail: "the spotlight stays up for 2 more minutes" } });
        // a canvas that connects 90 s later still gets it
        w.tick(90_000);
        const t = await w.token();
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toMatchObject({ by: "Ann", pinned_until: T0 + 10_000 + 120_000 });
        // the owner can unpin
        await w.owner("POST", "/stage/action", { type: "unpin" });
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toBeNull();
    });
});
