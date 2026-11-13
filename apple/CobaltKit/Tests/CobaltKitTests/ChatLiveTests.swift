import Foundation
import Testing
@testable import CobaltKit

// Chat reply Live Activities (CONTRACT-PARALLEL.md 15.10, APP-API-CONTRACT 27.9): the tracker (the server's ChatLiveTracker,
// line for line), the words, the manager against a fake ActivityKit (fed by the real ChatStore on the preview server), the
// push plumbing, and the "Ask chat" action.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func step(_ id: String, _ status: ChatStep.Status, _ code: String = "return await cobalt.search('cats')") -> ChatEvent {
    .step(ChatStep(id: id, status: status, code: code))
}

private func message(_ text: String, status: ChatMessage.Status = .done, error: String? = nil, posts: [String] = []) -> ChatMessage {
    ChatMessage(id: "9", role: .assistant, text: text, postIDs: posts, status: status, error: error, createdAt: t0)
}

struct ChatLiveTrackerTests {
    @Test func followsThinkingAToolWritingAndDone() {
        var t = ChatLiveTracker(since: t0)
        #expect(t.state == ChatLiveContentState(status: .thinking, since: 1_800_000_000))
        #expect(t.apply(.text("")) == .none)
        #expect(t.apply(step("s1", .running)) == .major)
        #expect(t.state.status == .working && t.state.tool == "searching your library" && t.state.steps == 1)
        #expect(t.apply(step("s1", .done)) == .major)
        #expect(t.state.status == .thinking)
        #expect(t.apply(.text("found **three** cats")) == .major)
        #expect(t.state.status == .writing && t.state.reply == "found three cats")
        #expect(t.apply(.text(" in your library")) == .minor)
        #expect(t.apply(.posts(ids: ["a", "b", "a"], posts: [])) == .major)
        #expect(t.state.shown == 2)
        #expect(t.apply(.done(message("found three cats.", posts: ["a", "b", "c"]), ChatThread(id: "T", title: "x", createdAt: t0, updatedAt: t0))) == .major)
        #expect(t.state.status == .done && t.state.reply == "found three cats." && t.state.shown == 3 && t.state.isTerminal)
        #expect(t.apply(.text("late")) == .none)
    }

    @Test func errorsAndBrokenStreams() {
        var a = ChatLiveTracker(since: t0)
        _ = a.apply(.error(code: "error.chat.model", message: nil))
        #expect(a.state.status == .failed && a.state.code == "error.chat.model")

        var b = ChatLiveTracker(since: t0)
        _ = b.apply(.text("hi"))
        b.end(with: nil, code: "error.chat.interrupted")
        #expect(b.state.status == .failed && b.state.code == "error.chat.interrupted" && b.state.reply == "hi")

        // the store followed a dropped stream and read the saved reply
        var c = ChatLiveTracker(since: t0)
        c.end(with: message("all done"), code: "error.chat.interrupted")
        #expect(c.state.status == .done && c.state.reply == "all done")
    }

    @Test func wordsLikeTheServer() {
        #expect(ChatLiveCopy.tool(for: "const r = await cobalt.library({ limit: 5 }); await cobalt.show(r)") == "looking through your library")
        #expect(ChatLiveCopy.tool(for: "await cobalt.ops.saveLink('x')") == "using save link")
        #expect(ChatLiveCopy.tool(for: "return 1 + 1") == "running code")
        #expect(ChatLiveCopy.plain("# hi\n- **one** `two`\n```js\ncode\n```") == "hi one two code")
        #expect(ChatLiveCopy.clip("abcdef", to: 4) == "abc…" && ChatLiveCopy.tail("abcdef", to: 4) == "…def")
        #expect(ChatLiveCopy.headline(ChatLiveContentState.samples["working"]!) == "searching your library…")
        #expect(ChatLiveCopy.headline(ChatLiveContentState.samples["thinking"]!, isStale: true) == "waiting for capystore…")
        #expect(ChatLiveCopy.detail(ChatLiveContentState.samples["writing"]!) == "2 tools · 3 files")
    }

    /// What the server pushes decodes into the same state (Swift names, absent optionals omitted).
    @Test func thePushedStateAndAttributesDecode() throws {
        let pushed = #"{"status":"done","since":1800000000,"steps":1,"failedSteps":0,"tool":"searching your library","reply":"three cats","shown":0}"#
        let s = try JSONDecoder().decode(ChatLiveContentState.self, from: Data(pushed.utf8))
        #expect(s.status == .done && s.reply == "three cats" && s.code == nil)
        let attrs = #"{"thread":"AbCdEfGh12345678","prompt":"find my cats","source":"other"}"#
        #expect(try JSONDecoder().decode(ChatLiveAttributes.self, from: Data(attrs.utf8)).source == .other)
        #expect(!String(decoding: try JSONEncoder().encode(ChatLiveContentState.samples["thinking"]!), as: UTF8.self).contains("null"))
    }

    @Test func theOpenLinkAndTheCapability() throws {
        #expect(ChatLiveAttributes.openURL(thread: "AbCdEfGh12345678").absoluteString == "cobalt-apple://chat/AbCdEfGh12345678")
        func caps(_ features: String) throws -> Capabilities {
            try #require(HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#.utf8)))
        }
        #expect(try caps(#"{"chat":true,"chat_live_push":true}"#).chatLivePush)
        #expect(try !caps(#"{"chat_live_push":true}"#).chatLivePush)
    }

    @Test func shortcutProgressCreepsAndNeverFinishesEarly() {
        #expect(ShortcutActions.chatProgress(events: 0) == 2)
        #expect(ShortcutActions.chatProgress(events: 40) > 40 && ShortcutActions.chatProgress(events: 40) < 60)
        #expect(ShortcutActions.chatProgress(events: 100_000) <= 95)
    }
}

// MARK: - the manager

@MainActor
private final class FakeChatHandle: JobActivityHandle {
    let attributes: JobLiveAttributes
    let activityID = UUID().uuidString
    var state: JobLiveState
    var isEnded = false
    var updates: [JobLiveState] = []
    var ended: (state: JobLiveState, dismissAt: Date?)?
    let tokenStream: AsyncStream<String>
    let tokenSink: AsyncStream<String>.Continuation

    init(job: JobLiveJob) {
        attributes = job.attributes
        state = job.state
        (tokenStream, tokenSink) = AsyncStream.makeStream(of: String.self)
    }

    /// A reply's activity the server push-started here (a message sent from another device).
    convenience init(thread: String) {
        self.init(job: JobLive.job(
            chat: ChatLiveContentState(status: .thinking, since: 1_790_000_000),
            attributes: ChatLiveAttributes(thread: thread, prompt: "from the mac", source: .other)))
    }

    var thread: String { attributes.id }
    func isFresh(at now: Date) -> Bool { !isEnded }
    func pushTokens() -> AsyncStream<String> { tokenStream }
    func update(_ state: JobLiveState, staleDate: Date?) async {
        self.state = state
        updates.append(state)
    }
    func end(_ state: JobLiveState?, dismissAt: Date?) async {
        isEnded = true
        ended = (state ?? self.state, dismissAt)
    }
}

@MainActor
private final class FakeChatAdapter: ChatLiveAdapter {
    var isAvailable = true
    var made: [FakeChatHandle] = []
    var madeWithPush: [Bool] = []
    var requested: [JobLiveJob] = []
    var pushed: [FakeChatHandle] = []
    var old: [FakeOldActivity] = []
    let createdStream: AsyncStream<any JobActivityHandle>
    let createdSink: AsyncStream<any JobActivityHandle>.Continuation

    init() {
        (createdStream, createdSink) = AsyncStream.makeStream(of: (any JobActivityHandle).self)
    }

    var activities: [any JobActivityHandle] { made + pushed }
    var oldActivities: [any OldLiveActivity] { old }
    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle {
        let h = FakeChatHandle(job: job)
        made.append(h)
        madeWithPush.append(push)
        requested.append(job)
        return h
    }
    func newActivities() -> AsyncStream<any JobActivityHandle> { createdStream }
}

private final class FakeChatLiveClient: ChatLiveClient, @unchecked Sendable {
    var tokens: [(String, String)] = []
    func putChatLiveToken(threadID: String, token: String, environment: LiveEnvironment) async throws { tokens.append((threadID, token)) }
}

@MainActor
struct ChatLiveManagerTests {
    private let t1 = PreviewData.chatThreadIDs[0]

    private func rig(_ scenario: PreviewScenario = .happy, active: Bool = false) -> (AppModel, FakeChatAdapter, ChatLiveManager) {
        let app = AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
        let adapter = FakeChatAdapter()
        let manager = ChatLiveManager(adapter: adapter, now: { Date() }, isAppActive: { active })
        app.chat.live = manager
        return (app, adapter, manager)
    }

    @Test func aReplyGetsOneJobActivityThatEndsDone() async throws {
        let (app, adapter, manager) = rig()
        await app.chat.load(t1)
        try await app.chat.send(text: "only the videos", in: t1, source: .shortcut)
        await manager.settle()
        #expect(adapter.made.count == 1)
        let h = try #require(adapter.made.first)
        // the job island's attributes (CONTRACT-JOBLIVE.md 2): the thread, "chat · <prompt>", a tap opens the thread
        #expect(h.thread == t1 && h.attributes.kind == "chat" && h.attributes.title == "chat · only the videos")
        #expect(h.attributes.open == ChatLiveAttributes.openURL(thread: t1).absoluteString && !h.attributes.agent)
        #expect(adapter.requested.first?.state.headline == "thinking" && adapter.requested.first?.state.steps == ["think", "tools", "write"])
        #expect(h.updates.contains { $0.headline == "using tools" && $0.step == 1 })
        let end = try #require(h.ended)
        #expect(end.state.phase == .done && end.state.headline == "reply ready" && end.state.step == 3)
        #expect(end.state.detail?.hasPrefix("found 12 posts") == true)
        #expect(end.dismissAt != nil, "a Shortcut's finished reply stays on the Lock Screen for a while")
    }

    @Test func aFinishedReplyStaysAMinuteAndAFailedOneFiveMinutes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = FakeChatAdapter()
        let manager = ChatLiveManager(adapter: adapter, now: { now }, isAppActive: { false })
        manager.began(thread: "AbCdEfGh12345678", prompt: "find my cats", source: .shortcut)
        manager.ended(thread: "AbCdEfGh12345678", final: ChatMessage(id: "m", role: .assistant, text: "three cats", createdAt: now))
        manager.began(thread: "ZyXwVuTs87654321", prompt: "and dogs", source: .shortcut)
        manager.ended(thread: "ZyXwVuTs87654321", final: nil, code: "error.chat.model")
        await manager.settle()
        #expect(adapter.made[0].ended?.dismissAt == now.addingTimeInterval(60), "done: 60 s (8.12)")
        #expect(adapter.made[1].ended?.dismissAt == now.addingTimeInterval(300), "failed: 300 s")
        #expect(adapter.made[1].ended?.state.headline == "couldn't reply")
    }

    @Test func aReplyWatchedInTheChatTabLeavesNothingBehind() async throws {
        let (app, adapter, manager) = rig(active: true)
        await app.chat.load(t1)
        try await app.chat.send(text: "only the videos", in: t1)
        await manager.settle()
        #expect(adapter.made.first?.ended?.dismissAt == nil)
    }

    @Test func aFailedReplyEndsFailed() async throws {
        let (app, adapter, manager) = rig(.chatReplyFails)
        await app.chat.load(t1)
        try await app.chat.send(text: "try", in: t1)
        await manager.settle()
        let end = try #require(adapter.made.first?.ended)
        #expect(end.state.phase == .failed && end.state.headline == "couldn't reply")
        #expect(end.state.detail == "something went wrong. open capystore to see what happened.", "error.chat.model in plain words")
    }

    @Test func aRefusalEndsTheActivityWithoutShowingTheEarlierReply() async throws {
        let (app, adapter, manager) = rig()
        await app.chat.load(t1)
        await #expect(throws: ChatError.badRequest) { try await app.chat.send(text: "   ", in: t1) }
        #expect(adapter.made.isEmpty, "an empty message never starts one")
        _ = manager
    }

    @Test func noActivityWhenLiveActivitiesAreOff() async throws {
        let (app, adapter, _) = rig()
        adapter.isAvailable = false
        await app.chat.load(t1)
        try await app.chat.send(text: "only the videos", in: t1)
        #expect(adapter.made.isEmpty)
    }

    @Test func pushedActivitiesHandTheirTokensToTheServer() async throws {
        let adapter = FakeChatAdapter()
        let client = FakeChatLiveClient()
        var caps = Capabilities.unknown
        caps.chat = true
        caps.chatLivePush = true
        let manager = ChatLiveManager(
            adapter: adapter, now: { Date() }, isAppActive: { false }, environment: .production,
            capabilities: { caps }, client: { client })
        manager.start()
        let pushed = FakeChatHandle(thread: "AbCdEfGh12345678")
        adapter.createdSink.yield(pushed)
        pushed.tokenSink.yield("cd34")
        for _ in 0..<50 where client.tokens.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.tokens.map(\.0) == ["AbCdEfGh12345678"] && client.tokens.map(\.1) == ["cd34"])
        // the app's own reply activity shows up in the system's list too: it is followed from `began`, once
        manager.began(thread: "ZZZZZZZZZZZZZZZZ", prompt: "mine", source: .app)
        let own = try #require(adapter.made.first)
        adapter.createdSink.yield(own)
        own.tokenSink.yield("ee56")
        for _ in 0..<50 where client.tokens.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(client.tokens.filter { $0.0 == "ZZZZZZZZZZZZZZZZ" }.count == 1, "one follower per activity")
    }

    @Test func oldChatActivitiesNobodyWritesAreEndedAtLaunchAndANewReplyEndsItsThreadsOldOne() async throws {
        let adapter = FakeChatAdapter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = FakeOldActivity(id: "OldOldOldOld0001", staleDate: now.addingTimeInterval(-10))
        let fresh = FakeOldActivity(id: "OldOldOldOld0002", staleDate: now.addingTimeInterval(60))
        adapter.old = [stale, fresh]
        let manager = ChatLiveManager(adapter: adapter, now: { now }, isAppActive: { false })
        manager.start()
        await manager.settle()
        #expect(stale.isEnded && !fresh.isEnded, "the server still writes the fresh one: it ends it itself")
        manager.began(thread: "OldOldOldOld0002", prompt: "again", source: .app)
        await manager.settle()
        #expect(fresh.isEnded, "one island per thread: the old type gives way to the job activity")
        #expect(adapter.made.count == 1)
    }

    @Test func aReplySentFromThisPhoneHandsItsTokenToTheServerWhenItPushes() async throws {
        let adapter = FakeChatAdapter()
        let client = FakeChatLiveClient()
        var caps = Capabilities.unknown
        caps.chat = true
        caps.chatLivePush = true
        let manager = ChatLiveManager(
            adapter: adapter, now: { Date() }, isAppActive: { false }, environment: .production,
            capabilities: { caps }, client: { client })
        manager.began(thread: "AbCdEfGh12345678", prompt: "find my cats", source: .shortcut)
        #expect(adapter.madeWithPush == [true], "asked with a push type, so the server can keep it current while locked")
        let own = try #require(adapter.made.first)
        own.tokenSink.yield("ee56")
        for _ in 0..<50 where client.tokens.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.tokens.map(\.0) == ["AbCdEfGh12345678"] && client.tokens.map(\.1) == ["ee56"])
        // the app still writes it while it runs, and still ends it itself
        manager.ended(thread: "AbCdEfGh12345678", final: nil)
        await manager.settle()
        #expect(own.ended?.state.phase == .failed && own.ended?.state.detail == "the reply was cut off.")
    }

    @Test func withoutPushTheReplyActivityIsLocalAndHandsNothingOver() async throws {
        let adapter = FakeChatAdapter()
        let client = FakeChatLiveClient()
        let manager = ChatLiveManager(adapter: adapter, now: { Date() }, isAppActive: { false }, environment: nil, client: { client })
        manager.began(thread: "AbCdEfGh12345678", prompt: "find my cats", source: .app)
        #expect(adapter.madeWithPush == [false])
        adapter.made.first?.tokenSink.yield("ee56")
        try await Task.sleep(for: .milliseconds(30))
        #expect(client.tokens.isEmpty)
    }
}

@MainActor
struct AskChatShortcutTests {
    @Test func asksAndReturnsTheReplyWithProgress() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        let actions = ShortcutActions(model: app)
        let t1 = PreviewData.chatThreadIDs[0]
        var words: [String] = []
        var last: Int64 = 0
        let reply = try await actions.askChat("only the videos", threadID: t1) { done, _, w in
            words.append(w)
            #expect(done >= last)
            last = done
        }
        #expect(reply.threadID == t1 && reply.text.hasPrefix("found **12 posts**") && reply.plain.hasPrefix("found 12 posts"))
        #expect(reply.shownPostIDs.count == 3)
        #expect(words.first == "thinking…" && words.contains("searching your library…") || words.contains { $0.hasSuffix("…") })
        #expect(words.last == "replied" && last == 100)
        #expect(app.chat.content(of: t1)?.messages.last?.status == .done, "the reply is in the chat tab too")
    }

    @Test func aNewChatWhenNoneIsGivenAndPlainErrors() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        let actions = ShortcutActions(model: app)
        let reply = try await actions.askChat("which clips have a dog in them")
        #expect(!PreviewData.chatThreadIDs.contains(reply.threadID) && reply.threadTitle == "the harbour clips")
        await #expect(throws: ChatError.badRequest) { try await actions.askChat("   ") }
        await #expect(throws: ChatError.model) {
            let failing = ShortcutActions(model: AppModel.makePreview(.chatReplyFails, timeScale: 0.01, clock: SystemClock()))
            _ = try await failing.askChat("try", threadID: PreviewData.chatThreadIDs[0])
        }
    }
}
