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
private final class FakeChatHandle: ChatLiveHandle {
    let thread: String
    let source: ChatLiveSource
    var isEnded = false
    var updates: [ChatLiveContentState] = []
    var ended: (state: ChatLiveContentState, dismissAt: Date?)?
    let tokenStream: AsyncStream<String>
    let tokenSink: AsyncStream<String>.Continuation

    init(thread: String, source: ChatLiveSource) {
        self.thread = thread
        self.source = source
        (tokenStream, tokenSink) = AsyncStream.makeStream(of: String.self)
    }

    func pushTokens() -> AsyncStream<String> { tokenStream }
    func update(_ state: ChatLiveContentState, staleDate: Date?) async { updates.append(state) }
    func end(_ state: ChatLiveContentState, dismissAt: Date?) async {
        isEnded = true
        ended = (state, dismissAt)
    }
}

@MainActor
private final class FakeChatAdapter: ChatLiveAdapter {
    var isAvailable = true
    var made: [FakeChatHandle] = []
    var pushed: [FakeChatHandle] = []
    let startStream: AsyncStream<String>
    let startSink: AsyncStream<String>.Continuation
    let createdStream: AsyncStream<any ChatLiveHandle>
    let createdSink: AsyncStream<any ChatLiveHandle>.Continuation

    init() {
        (startStream, startSink) = AsyncStream.makeStream(of: String.self)
        (createdStream, createdSink) = AsyncStream.makeStream(of: (any ChatLiveHandle).self)
    }

    var activities: [any ChatLiveHandle] { made + pushed }
    func request(_ attributes: ChatLiveAttributes, state: ChatLiveContentState, staleDate: Date) throws -> any ChatLiveHandle {
        let h = FakeChatHandle(thread: attributes.thread, source: attributes.source)
        made.append(h)
        return h
    }
    func startTokens() -> AsyncStream<String> { startStream }
    func newActivities() -> AsyncStream<any ChatLiveHandle> { createdStream }
}

private final class FakeChatLiveClient: ChatLiveClient, @unchecked Sendable {
    var startTokens: [String] = []
    var tokens: [(String, String)] = []
    func registerChatLiveStartToken(_ token: String, environment: LiveEnvironment) async throws { startTokens.append(token) }
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

    @Test func aReplyGetsOneActivityThatEndsDone() async throws {
        let (app, adapter, manager) = rig()
        await app.chat.load(t1)
        try await app.chat.send(text: "only the videos", in: t1, source: .shortcut)
        await manager.settle()
        #expect(adapter.made.count == 1)
        let h = try #require(adapter.made.first)
        #expect(h.thread == t1 && h.source == .shortcut)
        #expect(h.updates.contains { $0.status == .working })
        let end = try #require(h.ended)
        #expect(end.state.status == .done && end.state.steps == 1 && end.state.shown == 3)
        #expect(end.state.reply?.hasPrefix("found 12 posts") == true)
        #expect(end.dismissAt != nil, "a Shortcut's finished reply stays on the Lock Screen for a while")
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
        #expect(end.state.status == .failed && end.state.code == "error.chat.model")
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
        adapter.startSink.yield("ab12")
        let pushed = FakeChatHandle(thread: "AbCdEfGh12345678", source: .other)
        adapter.createdSink.yield(pushed)
        pushed.tokenSink.yield("cd34")
        for _ in 0..<50 where client.tokens.isEmpty || client.startTokens.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.startTokens == ["ab12"])
        #expect(client.tokens.map(\.0) == ["AbCdEfGh12345678"] && client.tokens.map(\.1) == ["cd34"])
        // a local activity is never handed over (the server does not push to the sender)
        adapter.createdSink.yield(FakeChatHandle(thread: "ZZZZZZZZZZZZZZZZ", source: .app))
        try await Task.sleep(for: .milliseconds(30))
        #expect(client.tokens.count == 1)
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
