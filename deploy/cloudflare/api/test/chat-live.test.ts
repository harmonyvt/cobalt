// Chat reply Live Activities on the owner's other devices (APP-API-CONTRACT.md section 27.9): the tracker (the app's
// ChatLiveTracker in TypeScript), the Worker-side pusher's pacing, the payloads, the routes inside the Durable Object, the
// gate, and a whole reply sent from the Mac shown on an iPhone (Apple is a script).
import { beforeAll, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import {
    CHAT_LIVE_KEEPALIVE_MS,
    CHAT_LIVE_REFRESH_MS,
    CHAT_LIVE_SILENT_MS,
    CHAT_LIVE_TEXT_MS,
    CHAT_LIVE_TEXT_PUSH_MS,
    ChatLivePusher,
    ChatLiveService,
    ChatLiveTracker,
    decideChatPush,
    handleChatLiveRoute,
    plain,
    toolWords,
    type ChatLiveState,
} from "../src/chat-live";
import { dispatch as decide } from "./dispatch";
import { KEY_ID_HEADER } from "../src/headers";
import { Apple, bad, makePem } from "./apns-fakes";
import { MemoryKV } from "./studio-fakes";

const T0 = 1_800_000_000_000;
const THREAD = "AbCdEfGh12345678";
const PHONE = "key-phone";
const MAC = "key-mac";
const START = "aa".repeat(40);
const UPDATE = "bb".repeat(40);
const INTERNAL = "internal-key";

let pem: string;
beforeAll(async () => {
    pem = await makePem();
});

const step = (id: string, status: string, code = "return await cobalt.search('cats')") => ({ step: { id, status, code } });

describe("the tracker", () => {
    it("follows thinking, a tool call, writing and done", () => {
        const t = new ChatLiveTracker(T0);
        expect(t.state).toEqual({ status: "thinking", since: T0 / 1000, steps: 0, failedSteps: 0, shown: 0 });
        expect(t.apply("user", {})).toBe("none");
        expect(t.apply("text", { delta: "" })).toBe("none");
        expect(t.apply("step", step("s1", "running"))).toBe("major");
        expect(t.state).toMatchObject({ status: "working", tool: "searching your library", steps: 1 });
        expect(t.apply("step", step("s1", "done"))).toBe("major");
        expect(t.state.status).toBe("thinking");
        expect(t.apply("text", { delta: "found **three** cats" })).toBe("major");
        expect(t.state).toMatchObject({ status: "writing", reply: "found three cats" });
        expect(t.apply("text", { delta: " in your library" })).toBe("minor");
        expect(t.apply("posts", { post_ids: ["a", "b", "a"] })).toBe("major");
        expect(t.state.shown).toBe(2);
        expect(t.apply("done", { message: { text: "found three cats.", post_ids: ["a", "b", "c"], steps: [{}, { status: "error" }] } })).toBe("major");
        expect(t.state).toEqual({ status: "done", since: T0 / 1000, steps: 2, failedSteps: 1, tool: "searching your library", reply: "found three cats.", shown: 3 });
        expect(t.apply("text", { delta: "late" })).toBe("none");
    });

    it("an error ends it with the code; a broken stream ends it cut off", () => {
        const a = new ChatLiveTracker(T0);
        a.apply("error", { code: "error.chat.model", message: { text: "" } });
        expect(a.state).toMatchObject({ status: "failed", code: "error.chat.model" });
        const b = new ChatLiveTracker(T0);
        b.apply("text", { delta: "hi" });
        b.end();
        expect(b.state).toMatchObject({ status: "failed", code: "error.chat.interrupted", reply: "hi" });
    });

    it("words the tools like the app", () => {
        expect(toolWords("const r = await cobalt.library({ limit: 5 }); await cobalt.show(r)")).toBe("looking through your library");
        expect(toolWords("await cobalt.ops.saveLink('x')")).toBe("using save link");
        expect(toolWords("return 1 + 1")).toBe("running code");
        expect(plain("# hi\n- **one** `two`\n```js\ncode\n```")).toBe("hi one two code");
    });
});

describe("the pusher (Worker side)", () => {
    function world(targets = 1) {
        let t = T0;
        const posts: { state: ChatLiveState }[] = [];
        const pusher = new ChatLivePusher({
            thread: THREAD,
            keyId: MAC,
            prompt: "find my **cats**",
            now: () => t,
            post: async (b) => {
                posts.push(b);
                return { targets };
            },
        });
        return { pusher, posts, tick: (ms: number) => (t += ms) };
    }

    it("hands status changes over at once and text at most every few seconds", async () => {
        const w = world();
        w.pusher.event("step", step("s1", "running"));
        w.pusher.event("step", step("s1", "done"));
        w.pusher.event("text", { delta: "a" });
        w.pusher.event("text", { delta: "b" });
        w.tick(CHAT_LIVE_TEXT_MS);
        w.pusher.event("text", { delta: "c" });
        w.pusher.event("done", { message: { text: "abc" } });
        await w.pusher.close();
        expect(w.posts.map((p) => p.state.status)).toEqual(["thinking", "working", "thinking", "writing", "writing", "done", "done"]);
        expect(w.posts[0]).toMatchObject({ key_id: MAC, prompt: "find my cats" });
    });

    it("stops once no device wants it", async () => {
        const w = world(0);
        w.pusher.event("step", step("s1", "running"));
        await w.pusher.close();
        expect(w.posts.length).toBe(1);
    });
});

describe("pacing in the Durable Object", () => {
    const s = (over: Partial<ChatLiveState>): ChatLiveState => ({ status: "writing", since: 1, steps: 0, failedSteps: 0, shown: 0, ...over });
    it("text waits CHAT_LIVE_TEXT_PUSH_MS, a status change and the end do not", () => {
        const sent = s({ reply: "a" });
        expect(decideChatPush({ sent, sentAt: T0 }, s({ reply: "ab" }), "q", T0 + 1000)).toBeNull();
        expect(decideChatPush({ sent, sentAt: T0 }, s({ reply: "ab" }), "q", T0 + CHAT_LIVE_TEXT_PUSH_MS)?.priority).toBe(5);
        expect(decideChatPush({ sent, sentAt: T0 }, s({ status: "working", tool: "x" }), "q", T0 + 1)?.priority).toBe(10);
        const end = decideChatPush({ sent, sentAt: T0 }, s({ status: "done", reply: "ab" }), "q", T0 + 1)!;
        expect(end.event).toBe("end");
        expect(end.payload).toMatchObject({ aps: { event: "end", alert: { title: "chat replied", body: "ab" } } });
        // the same state again only as a keep-alive, at low priority, once CHAT_LIVE_REFRESH_MS passed with nothing sent
        expect(decideChatPush({ sent, sentAt: T0 }, sent, "q", T0 + CHAT_LIVE_REFRESH_MS - 1)).toBeNull();
        const keep = decideChatPush({ sent, sentAt: T0 }, sent, "q", T0 + CHAT_LIVE_REFRESH_MS)!;
        expect(keep).toMatchObject({ event: "update", priority: 5 });
        expect((keep.payload as { aps: Record<string, unknown> }).aps["stale-date"]).toBeGreaterThan((T0 + CHAT_LIVE_REFRESH_MS) / 1000);
        // a finished state is never sent twice
        const done = s({ status: "done", reply: "a" });
        expect(decideChatPush({ sent: done, sentAt: T0 }, done, "q", T0 + 99_999_999)).toBeNull();
    });

    it("the pusher hands the same state over again on a quiet reply (the ping), at most every CHAT_LIVE_KEEPALIVE_MS", async () => {
        let t = T0;
        const posts: unknown[] = [];
        const p = new ChatLivePusher({ thread: THREAD, keyId: PHONE, prompt: "q", now: () => t, post: async (b) => (posts.push(b), { targets: 1 }) });
        p.tick();
        t += CHAT_LIVE_KEEPALIVE_MS - 1;
        p.tick();
        await Promise.resolve();
        const before = posts.length;
        t += 1;
        p.tick();
        await p.close();
        expect(before).toBe(1);
        expect(posts.length).toBe(3); // start, keep-alive, close
    });
});

function doWorld(opts: { configured?: boolean } = {}) {
    let t = T0;
    const apple = new Apple();
    const storage = new MemoryKV();
    const apns =
        opts.configured === false
            ? null
            : new ApnsClient({
                  keyP8: pem,
                  keyId: "ABC123DEFG",
                  teamId: "TEAM123456",
                  bundleId: "com.capybaraharmony.cobalt",
                  via: "worker",
                  transport: apple.transport,
                  now: () => t,
                  log: () => {},
              });
    let sweeps = 0;
    const service = new ChatLiveService({ storage, now: () => t, apns, scheduleSweep: async () => void sweeps++ });
    const route = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
        handleChatLiveRoute(
            service,
            new Request(`https://do.internal${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }),
            INTERNAL,
        );
    const keyed = (key: string) => ({ [KEY_ID_HEADER]: key });
    const internal = { "x-internal-key": INTERNAL };
    const state = (key: string, st: ChatLiveState) => route("POST", `/live/chats/${THREAD}/state`, { key_id: key, prompt: "find my cats", state: st }, internal);
    return { apple, storage, service, route, keyed, internal, state, tick: (ms: number) => (t += ms), sweeps: () => sweeps };
}

describe("a reply sent from the Mac, shown on the iPhone", () => {
    const st = (over: Partial<ChatLiveState>): ChatLiveState => ({ status: "thinking", since: T0 / 1000, steps: 0, failedSteps: 0, shown: 0, ...over });

    it("push-starts on the phone, updates once the phone hands back its token, and ends", async () => {
        const w = doWorld();
        expect((await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE))).status).toBe(200);

        const first = await (await w.state(MAC, st({}))).json();
        expect(first).toEqual({ status: "success", targets: 1 });
        const start = w.apple.pushes[0]!;
        expect(start.token).toBe(START);
        expect(start.payload.aps).toMatchObject({
            event: "start",
            "attributes-type": "CobaltChatActivityAttributes",
            attributes: { thread: THREAD, prompt: "find my cats", source: "other" },
            "content-state": { status: "thinking", steps: 0, failedSteps: 0, shown: 0 },
            "input-push-token": 1,
        });

        // no update token yet: nothing to push to
        await w.state(MAC, st({ status: "working", steps: 1, tool: "searching your library" }));
        expect(w.apple.pushes.length).toBe(1);

        // the phone hands its token back: caught up at once
        expect((await w.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w.keyed(PHONE))).status).toBe(200);
        expect(w.apple.pushes.at(-1)).toMatchObject({ token: UPDATE, payload: { aps: { event: "update", "content-state": { status: "working" } } } });

        w.tick(1000);
        await w.state(MAC, st({ status: "done", steps: 1, tool: "searching your library", reply: "three cats" }));
        expect(w.apple.pushes.at(-1)!.payload.aps).toMatchObject({ event: "end", alert: { title: "chat replied", body: "three cats" } });
        // ended everywhere: the record is gone
        expect(await w.storage.get(`live:chat:${THREAD}`)).toBeUndefined();
    });

    it("the sender's own device is never push-started; once it hands back its activity's token the server keeps it current", async () => {
        const w = doWorld();
        await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE));
        expect(await (await w.state(PHONE, st({}))).json()).toEqual({ status: "success", targets: 1 });
        expect(w.apple.calls.length).toBe(0);
        await w.state(PHONE, st({ status: "working", steps: 1, tool: "searching your library" }));
        expect(w.apple.calls.length).toBe(0);

        // the phone's own activity hands back its token: caught up at once, then updated and ended by the server
        const put = await (await w.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w.keyed(PHONE))).json();
        expect(put).toEqual({ status: "success", pushing: true });
        expect(w.apple.pushes.at(-1)).toMatchObject({ token: UPDATE, payload: { aps: { event: "update", "content-state": { status: "working" } } } });
        w.tick(1000);
        await w.state(PHONE, st({ status: "done", steps: 1, reply: "three cats" }));
        expect(w.apple.pushes.at(-1)!.payload.aps).toMatchObject({ event: "end" });
        expect(w.apple.pushes.every((p) => p.token !== START)).toBe(true);
        expect(await w.storage.get(`live:chat:${THREAD}`)).toBeUndefined();
    });

    it("the sender's token may come before the reply's first hand-over (kept, taken up when it begins), or mid-reply without a start token", async () => {
        const w = doWorld();
        // no chat start token on this phone: only its own activity's token
        const early = await (await w.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w.keyed(PHONE))).json();
        expect(early).toEqual({ status: "success", pushing: true });
        expect(await (await w.state(PHONE, st({}))).json()).toEqual({ status: "success", targets: 1 });
        expect(w.apple.pushes.at(-1)).toMatchObject({ token: UPDATE, payload: { aps: { event: "update", "content-state": { status: "thinking" } } } });
        expect(await w.storage.get(`live:chatpending:${THREAD}:${PHONE}`)).toBeUndefined();

        const w2 = doWorld();
        expect(await (await w2.state(MAC, st({}))).json()).toEqual({ status: "success", targets: 0 });
        // the Mac's reply has no record (nobody to show it to); a phone that is not the sender gets nothing for it
        await w2.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w2.keyed(PHONE));
        await w2.state(PHONE, st({ since: T0 / 1000 + 5 }));
        const late = await (await w2.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w2.keyed(MAC))).json();
        expect(late).toEqual({ status: "success", pushing: false });
    });

    it("a device without a chat start token (the Mac) is not a target: nothing is handed over for nobody", async () => {
        const w = doWorld();
        expect(await (await w.state(MAC, st({}))).json()).toEqual({ status: "success", targets: 0 });
        expect(w.apple.calls.length).toBe(0);
    });

    it("the watchdog: a reply whose Worker went silent is ended as interrupted on every device", async () => {
        const w = doWorld();
        await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE));
        await w.state(PHONE, st({ status: "working", steps: 1, tool: "searching your library" }));
        await w.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w.keyed(PHONE));
        expect(w.sweeps()).toBeGreaterThan(0);
        const pushes = w.apple.pushes.length;

        w.tick(CHAT_LIVE_SILENT_MS - 1000);
        expect((await w.service.watch()).nextInMs).toBe(1000);
        expect(w.apple.pushes.length).toBe(pushes);

        w.tick(1000);
        expect((await w.service.watch()).nextInMs).toBeNull();
        expect(w.apple.pushes.at(-1)!.payload.aps).toMatchObject({
            event: "end",
            "content-state": { status: "failed", code: "error.chat.interrupted" },
        });
        expect(await w.storage.get(`live:chat:${THREAD}`)).toBeUndefined();
        // a late hand-over from a Worker that came back starts nothing and revives nothing
        await w.state(PHONE, st({ status: "working", steps: 2 }));
        expect(w.apple.pushes.at(-1)!.payload.aps).toMatchObject({ event: "end" });
    });

    it("a dead start token is forgotten", async () => {
        const w = doWorld();
        w.apple.script = [bad(410, "Unregistered")];
        await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE));
        expect(await (await w.state(MAC, st({}))).json()).toEqual({ status: "success", targets: 0 });
        expect(await w.storage.get(`live:chatstart:${PHONE}`)).toBeUndefined();
    });

    it("without APNs nothing is stored or pushed", async () => {
        const w = doWorld({ configured: false });
        expect(await (await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE))).json()).toMatchObject({ pushing: false });
        expect(await (await w.state(MAC, st({}))).json()).toEqual({ status: "success", targets: 0 });
    });

    it("refuses what it should", async () => {
        const w = doWorld();
        expect((await w.route("POST", `/live/chats/${THREAD}/state`, { key_id: MAC, state: st({}) }, {})).status).toBe(403);
        expect((await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" })).status).toBe(403);
        expect((await w.route("PUT", "/live/chat-start-token", { token: "nope", environment: "production" }, w.keyed(PHONE))).status).toBe(400);
        expect((await w.route("PUT", `/live/chats/short`, { token: UPDATE, environment: "production" }, w.keyed(PHONE))).status).toBe(404);
        expect((await w.route("POST", `/live/chats/${THREAD}/state`, { key_id: MAC, state: { status: "dancing" } }, w.internal)).status).toBe(400);
    });
});

describe("the gate", () => {
    const req = (method: string, pathname: string) =>
        decide({ method, pathname, searchParams: new URLSearchParams(), origin: null, authorization: "Api-Key 00000000-0000-4000-8000-000000000000" }, { corsUrl: "https://x", now: T0 }) as any;
    it("lets the device routes through keyed and keeps the state route internal", () => {
        expect(req("PUT", "/live/chat-start-token")).toMatchObject({ action: "lookup", op: "live.chat_start_token.put" });
        expect(req("DELETE", "/live/chat-start-token")).toMatchObject({ action: "lookup", op: "live.chat_start_token.delete" });
        expect(req("PUT", `/live/chats/${THREAD}`)).toMatchObject({ action: "lookup", op: "live.chat", params: { thread: THREAD } });
        expect(req("POST", `/live/chats/${THREAD}/state`)).toMatchObject({ action: "reject", status: 404 });
        expect(req("GET", `/live/chats/${THREAD}`)).toMatchObject({ action: "reject", status: 404 });
    });
});

describe("job island (8.13)", () => {
    const st = (over: Partial<ChatLiveState>): ChatLiveState => ({ status: "thinking", since: T0 / 1000, steps: 0, failedSteps: 0, shown: 0, ...over });
    it("a device with a job start token is push-started the job island and kept on it", async () => {
        const w = doWorld();
        await w.storage.put(`live:jobstart:${PHONE}`, { token: START, env: "production", updatedAt: T0 });
        await w.state(MAC, st({}));
        const start = w.apple.pushes[0]!;
        expect(start.payload.aps).toMatchObject({
            event: "start",
            "attributes-type": "CobaltJobActivityAttributes",
            attributes: { id: THREAD, kind: "chat", title: "chat · find my cats", agent: false },
            "content-state": { phase: "working", steps: ["think", "tools", "write"], step: 0, headline: "thinking" },
        });
        await w.route("PUT", `/live/chats/${THREAD}`, { token: UPDATE, environment: "production" }, w.keyed(PHONE));
        w.tick(1000);
        await w.state(MAC, st({ status: "done", steps: 1, reply: "three cats" }));
        expect(w.apple.pushes.at(-1)!.payload.aps).toMatchObject({ event: "end", "content-state": { phase: "done", headline: "reply ready", detail: "three cats" } });
    });

    it("the same job start token under two keys is one phone: one card", async () => {
        const w = doWorld();
        await w.storage.put(`live:jobstart:${PHONE}`, { token: START, env: "production", updatedAt: T0 });
        await w.storage.put(`live:jobstart:old-key`, { token: START, env: "production", updatedAt: T0 });
        expect(await (await w.state(MAC, { status: "thinking", since: T0 / 1000, steps: 0, failedSteps: 0, shown: 0 })).json()).toEqual({ status: "success", targets: 1 });
        expect(w.apple.pushes).toHaveLength(1);
    });
});

