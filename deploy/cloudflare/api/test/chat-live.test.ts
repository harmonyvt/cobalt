// Chat reply Live Activities on the owner's other devices (APP-API-CONTRACT.md section 27.9): the tracker (the app's
// ChatLiveTracker in TypeScript), the Worker-side pusher's pacing, the payloads, the routes inside the Durable Object, the
// gate, and a whole reply sent from the Mac shown on an iPhone (Apple is a script).
import { beforeAll, describe, expect, it } from "vitest";
import { ApnsClient } from "../src/apns";
import {
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
import { decide } from "../src/gate";
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
        expect(decideChatPush({ sent, sentAt: T0 }, sent, "q", T0 + 99_999)).toBeNull();
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
    const service = new ChatLiveService({ storage, now: () => t, apns });
    const route = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
        handleChatLiveRoute(
            service,
            new Request(`https://do.internal${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }),
            INTERNAL,
        );
    const keyed = (key: string) => ({ [KEY_ID_HEADER]: key });
    const internal = { "x-internal-key": INTERNAL };
    const state = (key: string, st: ChatLiveState) => route("POST", `/live/chats/${THREAD}/state`, { key_id: key, prompt: "find my cats", state: st }, internal);
    return { apple, storage, route, keyed, internal, state, tick: (ms: number) => (t += ms) };
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

    it("the sender's own device is never pushed (it draws the activity itself)", async () => {
        const w = doWorld();
        await w.route("PUT", "/live/chat-start-token", { token: START, environment: "production" }, w.keyed(PHONE));
        expect(await (await w.state(PHONE, st({}))).json()).toEqual({ status: "success", targets: 0 });
        expect(w.apple.calls.length).toBe(0);
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
        expect(req("PUT", "/live/chat-start-token")).toMatchObject({ then: "live_chat" });
        expect(req("DELETE", "/live/chat-start-token")).toMatchObject({ then: "live_chat" });
        expect(req("PUT", `/live/chats/${THREAD}`)).toMatchObject({ then: "live_chat" });
        expect(req("POST", `/live/chats/${THREAD}/state`)).not.toMatchObject({ then: "live_chat" });
        expect(req("GET", `/live/chats/${THREAD}`)).not.toMatchObject({ then: "live_chat" });
    });
});
