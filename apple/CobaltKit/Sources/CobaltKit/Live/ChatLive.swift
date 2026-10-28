import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// Live Activities for chat replies (APP-API-CONTRACT 27, apple/CONTRACT-PARALLEL.md 15.10): while the chat AI works on a
// reply sent from this device (the chat tab or the "Ask chat" Shortcuts action), the Dynamic Island and the Lock Screen show
// what it is doing: thinking, which tool it is using, writing, and the reply once it is done. The app writes it from the
// reply stream; there is no server push yet, so an activity whose app was suspended mid-reply goes stale until the app runs
// again. Kept apart from the run activities (`LiveActivityManager`) and the render ones (`EditLiveManager`).

/// What a reply's activity shows. JSON keys are the Swift property names, absent optionals are omitted, times are unix
/// seconds (the same shape a future server push would send). Kept small: ActivityKit caps a state at 4 KB.
public struct ChatLiveContentState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case thinking, working, writing, done, failed }

    public var status: Status
    /// Unix seconds the reply began (the timer counts from it).
    public var since: Double
    /// Tool calls (code steps) started so far.
    public var steps: Int
    /// ... of which failed.
    public var failedSteps: Int
    /// What the running (or last) tool call does, in words: "searching your library".
    public var tool: String?
    /// The reply so far, plain text: its last words while writing, its first ones when done.
    public var reply: String?
    /// Library files the reply shows (thumbnails and collage).
    public var shown: Int
    /// failed: the error code (`error.chat.model`, `error.chat.interrupted`, ...).
    public var code: String?

    public init(status: Status, since: Double, steps: Int = 0, failedSteps: Int = 0, tool: String? = nil,
                reply: String? = nil, shown: Int = 0, code: String? = nil) {
        self.status = status
        self.since = since
        self.steps = steps
        self.failedSteps = failedSteps
        self.tool = tool
        self.reply = reply
        self.shown = shown
        self.code = code
    }

    public var isTerminal: Bool { status == .done || status == .failed }

    /// Fixture states by name, for the widget's previews and the tests.
    public static let samples: [String: ChatLiveContentState] = [
        "thinking": ChatLiveContentState(status: .thinking, since: 1_790_000_000),
        "working": ChatLiveContentState(status: .working, since: 1_790_000_000, steps: 2, tool: "searching your library"),
        "writing": ChatLiveContentState(
            status: .writing, since: 1_790_000_000, steps: 2, tool: "picking files to show",
            reply: "…found three clips of the beach trip, the one at sunset is the longest", shown: 3),
        "done": ChatLiveContentState(
            status: .done, since: 1_790_000_000, steps: 3, tool: "picking files to show",
            reply: "found three clips of the beach trip. the sunset one is the longest (42 s)…", shown: 3),
        "failed": ChatLiveContentState(status: .failed, since: 1_790_000_000, steps: 1, code: "error.chat.model"),
    ]
}

/// Where the message came from: the chat tab or a Shortcut on this device, or another device (the Mac, a Mac Shortcut),
/// whose reply the server push-started here (APP-API-CONTRACT 27.9).
public enum ChatLiveSource: String, Codable, Hashable, Sendable { case app, shortcut, other }

/// The fixed attributes of a reply's activity; `CobaltChatActivityAttributes` (iOS only) mirrors it.
public struct ChatLiveAttributes: Codable, Hashable, Sendable {
    public var thread: String
    /// What was asked, cut to `ChatLiveCopy.promptLimit` characters.
    public var prompt: String
    public var source: ChatLiveSource

    public init(thread: String, prompt: String, source: ChatLiveSource) {
        self.thread = thread
        self.prompt = ChatLiveCopy.clip(ChatLiveCopy.plain(prompt), to: ChatLiveCopy.promptLimit)
        self.source = source
    }

    /// Opens the thread in the chat tab (`AppModel.open`).
    public var openURL: URL { Self.openURL(thread: thread) }

    public static func openURL(thread: String) -> URL {
        var c = URLComponents()
        c.scheme = "cobalt-apple"
        c.host = "chat"
        c.path = "/" + thread
        return c.url ?? URL(string: "cobalt-apple://chat")!
    }
}

/// The words of a reply's activity (lowercase, like the rest of the app). In CobaltKit so the widget, the Shortcut's progress
/// and the tests read the same ones.
public enum ChatLiveCopy {
    public static let promptLimit = 120
    public static let replyLimit = 160

    /// What a code step does, from the `cobalt.<tool>(` calls in its code (chat-tools.ts): the first one named.
    public static func tool(for code: String) -> String {
        guard let name = toolNames(in: code).first else { return "running code" }
        return toolWords(name)
    }

    /// The tool names a step's code calls, in order, once each (`cobalt.search(` → "search"; a dotted name keeps its last part).
    static func toolNames(in code: String) -> [String] {
        var out: [String] = []
        var rest = Substring(code)
        while let r = rest.range(of: "cobalt.") {
            rest = rest[r.upperBound...]
            var name = ""
            var i = rest.startIndex
            while i < rest.endIndex, rest[i].isLetter || rest[i].isNumber || rest[i] == "_" || rest[i] == "." {
                name.append(rest[i])
                i = rest.index(after: i)
            }
            while i < rest.endIndex, rest[i] == " " { i = rest.index(after: i) }
            guard i < rest.endIndex, rest[i] == "(" else { continue }
            let last = name.split(separator: ".").last.map(String.init) ?? name
            if !last.isEmpty, !out.contains(last) { out.append(last) }
        }
        return out
    }

    static func toolWords(_ name: String) -> String {
        switch name {
        case "search": return "searching your library"
        case "library": return "looking through your library"
        case "post": return "opening a post"
        case "look": return "looking at pictures"
        case "show": return "picking files to show"
        case "collage": return "making a collage"
        case "links": return "reading your links"
        case "collections": return "reading your collections"
        default:
            // a tool added later (the chat registry): its own name, split at capitals ("saveLink" → "save link")
            var words = ""
            for ch in name {
                if ch.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(ch == "_" ? " " : Character(ch.lowercased()))
            }
            return "using \(words)"
        }
    }

    /// The headline: what the AI is doing now.
    public static func headline(_ s: ChatLiveContentState, isStale: Bool = false) -> String {
        if isStale && !s.isTerminal { return "waiting for capystore…" }
        switch s.status {
        case .thinking: return "thinking…"
        case .working: return (s.tool ?? "running code") + "…"
        case .writing: return "writing…"
        case .done: return "replied"
        case .failed: return reason(s.code)
        }
    }

    /// "2 tools · 3 files": what the reply has done so far; nil before anything.
    public static func detail(_ s: ChatLiveContentState) -> String? {
        var parts: [String] = []
        if s.steps > 0 { parts.append(s.steps == 1 ? "1 tool" : "\(s.steps) tools") }
        if s.failedSteps > 0 { parts.append("\(s.failedSteps) failed") }
        if s.shown > 0 { parts.append(s.shown == 1 ? "1 file" : "\(s.shown) files") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func reason(_ code: String?) -> String {
        switch code {
        case "error.chat.interrupted": return "the reply was cut off"
        case "error.chat.busy": return "a reply is already running"
        case "error.chat.full": return "this chat is full"
        case "error.chat.off": return "chat is off on this server"
        default: return "the reply failed"
        }
    }

    /// Markdown made plain enough for one or two lines: marks dropped, whitespace folded.
    public static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line.removeFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The first `limit` characters, "…" when cut.
    public static func clip(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The last `limit` characters, "…" in front when cut.
    public static func tail(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : "…" + String(text.suffix(limit - 1)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - the tracker

/// Folds a reply's events into its activity state. Pure: the manager and the Shortcut's progress both use it, and the tests
/// feed it events.
public struct ChatLiveTracker: Sendable, Equatable {
    /// How much an event changed: `.minor` (more text) is pushed at most once a second, `.major` at once.
    public enum Change: Sendable, Equatable { case none, minor, major }

    public private(set) var state: ChatLiveContentState
    private var stepOrder: [String] = []
    private var stepStatus: [String: ChatStep.Status] = [:]
    private var shownIDs: Set<String> = []
    private var collage = 0
    private var text = ""

    public init(since: Date) {
        state = ChatLiveContentState(status: .thinking, since: floor(since.timeIntervalSince1970))
    }

    /// Events folded so far (a heartbeat for the Shortcut's progress).
    public private(set) var events = 0

    public mutating func apply(_ event: ChatEvent) -> Change {
        guard !state.isTerminal else { return .none }
        events += 1
        let before = state
        switch event {
        case .user, .assistant, .title:
            return .none
        case .text(let delta):
            text += delta
            state.reply = ChatLiveCopy.tail(ChatLiveCopy.plain(text), to: ChatLiveCopy.replyLimit)
            if !hasRunningStep { state.status = .writing }
        case .step(let step):
            if stepStatus[step.id] == nil { stepOrder.append(step.id) }
            stepStatus[step.id] = step.status
            state.steps = stepOrder.count
            state.failedSteps = stepStatus.values.filter { $0 == .error }.count
            if step.status == .running {
                state.status = .working
                state.tool = ChatLiveCopy.tool(for: step.code)
            } else if !hasRunningStep {
                state.status = text.isEmpty ? .thinking : .writing
            }
        case .posts(let ids, _):
            shownIDs.formUnion(ids)
            state.shown = shownIDs.count + collage
        case .collage(let c):
            collage = c.total
            state.shown = shownIDs.count + collage
        case .done(let message, _):
            finish(with: message)
        case .error(let code, let message):
            state.status = .failed
            state.code = code
            if let message, !message.text.isEmpty {
                state.reply = ChatLiveCopy.clip(ChatLiveCopy.plain(message.text), to: ChatLiveCopy.replyLimit)
            }
        }
        if state == before { return .none }
        return state.status == before.status && state.tool == before.tool && state.steps == before.steps
            && state.failedSteps == before.failedSteps && state.shown == before.shown ? .minor : .major
    }

    /// The reply ended without its last event reaching this tracker (a dropped stream the store followed by reading the
    /// thread, a refusal): `message` is the saved assistant message, if any; `code` is used when there is none.
    public mutating func end(with message: ChatMessage?, code: String) {
        guard !state.isTerminal else { return }
        if let message, message.role == .assistant {
            switch message.status {
            case .done:
                finish(with: message)
                return
            case .error:
                state.status = .failed
                state.code = message.error ?? code
                return
            case .running:
                break
            }
        }
        state.status = .failed
        state.code = code
    }

    private mutating func finish(with message: ChatMessage) {
        state.status = .done
        text = message.text
        let plain = ChatLiveCopy.plain(message.text)
        state.reply = plain.isEmpty ? nil : ChatLiveCopy.clip(plain, to: ChatLiveCopy.replyLimit)
        shownIDs.formUnion(message.postIDs)
        if let c = message.collage { collage = c.total }
        state.shown = shownIDs.count + collage
        if !message.steps.isEmpty {
            state.steps = max(state.steps, message.steps.count)
            state.failedSteps = message.steps.filter { $0.status == .error }.count
        }
    }

    private var hasRunningStep: Bool { stepStatus.values.contains(.running) }
}

#if os(iOS) && canImport(ActivityKit)
public struct CobaltChatActivityAttributes: ActivityAttributes, Hashable, Sendable {
    public typealias ContentState = ChatLiveContentState
    public var thread: String
    public var prompt: String
    public var source: ChatLiveSource

    public init(_ a: ChatLiveAttributes) {
        thread = a.thread
        prompt = a.prompt
        source = a.source
    }

    public var openURL: URL { ChatLiveAttributes.openURL(thread: thread) }
}
#endif

// MARK: - the seam

/// The server routes the reply activities use (APP-API-CONTRACT 27.9, `features.chat_live_push`).
public protocol ChatLiveClient: Sendable {
    /// `PUT /live/chat-start-token`
    func registerChatLiveStartToken(_ token: String, environment: LiveEnvironment) async throws
    /// `PUT /live/chats/<thread>`
    func putChatLiveToken(threadID: String, token: String, environment: LiveEnvironment) async throws
}

@MainActor
protocol ChatLiveHandle: AnyObject, Sendable {
    var thread: String { get }
    var source: ChatLiveSource { get }
    var isEnded: Bool { get }
    /// The update push token of a push-started activity, lowercase hex: the current value first, then every change.
    func pushTokens() -> AsyncStream<String>
    func update(_ state: ChatLiveContentState, staleDate: Date?) async
    /// `dismissAt` nil: `.immediate`.
    func end(_ state: ChatLiveContentState, dismissAt: Date?) async
}

@MainActor
protocol ChatLiveAdapter: AnyObject {
    var isAvailable: Bool { get }
    var activities: [any ChatLiveHandle] { get }
    func request(_ attributes: ChatLiveAttributes, state: ChatLiveContentState, staleDate: Date) throws -> any ChatLiveHandle
    /// The push-to-start token for chat activities, lowercase hex: the current value first, then every change.
    func startTokens() -> AsyncStream<String>
    /// Activities the system created (a push-to-start from the server).
    func newActivities() -> AsyncStream<any ChatLiveHandle>
}

#if os(iOS) && canImport(ActivityKit)
@MainActor
final class ActivityKitChatHandle: ChatLiveHandle {
    nonisolated(unsafe) let activity: Activity<CobaltChatActivityAttributes>
    init(_ activity: Activity<CobaltChatActivityAttributes>) { self.activity = activity }

    var thread: String { activity.attributes.thread }
    var source: ChatLiveSource { activity.attributes.source }

    func pushTokens() -> AsyncStream<String> {
        let activity = activity
        return AsyncStream { continuation in
            let task = Task {
                for await data in activity.pushTokenUpdates { continuation.yield(data.liveHex) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var isEnded: Bool {
        switch activity.activityState {
        case .ended, .dismissed: return true
        default: return false
        }
    }

    func update(_ state: ChatLiveContentState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: ChatLiveContentState, dismissAt: Date?) async {
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: dismissAt.map { .after($0) } ?? .immediate)
    }
}

@MainActor
final class ActivityKitChatAdapter: ChatLiveAdapter {
    init() {}
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activities: [any ChatLiveHandle] { Activity<CobaltChatActivityAttributes>.activities.map { ActivityKitChatHandle($0) } }
    func request(_ attributes: ChatLiveAttributes, state: ChatLiveContentState, staleDate: Date) throws -> any ChatLiveHandle {
        let activity = try Activity.request(
            attributes: CobaltChatActivityAttributes(attributes),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil)
        return ActivityKitChatHandle(activity)
    }

    func startTokens() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                if let current = Activity<CobaltChatActivityAttributes>.pushToStartToken { continuation.yield(current.liveHex) }
                for await data in Activity<CobaltChatActivityAttributes>.pushToStartTokenUpdates { continuation.yield(data.liveHex) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func newActivities() -> AsyncStream<any ChatLiveHandle> {
        AsyncStream { continuation in
            let task = Task {
                for await activity in Activity<CobaltChatActivityAttributes>.activityUpdates {
                    continuation.yield(ActivityKitChatHandle(activity))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

// MARK: - the manager

/// One activity per reply this device sent: started when the message goes out, updated from the reply's events (text at
/// most once a second, everything else at once), ended when the reply is done or failed. A reply sent from the chat tab
/// that ends while the app is in front leaves nothing behind (the owner watched it); otherwise the finished activity stays
/// on the Lock Screen for a while with the start of the reply.
@MainActor
public final class ChatLiveManager {
    /// No update for this long and iOS greys the activity out ("waiting for capystore…").
    static let staleAfter: TimeInterval = 90
    static let dismissDone: TimeInterval = 600
    static let dismissFailed: TimeInterval = 300
    /// More text is pushed at most this often.
    static let textInterval: TimeInterval = 1

    private struct Run {
        var handle: (any ChatLiveHandle)?
        var tracker: ChatLiveTracker
        var source: ChatLiveSource
        var lastPush: Date
        var dirty = false
    }

    private let adapter: any ChatLiveAdapter
    private let now: () -> Date
    private let isAppActive: () -> Bool
    private let environment: LiveEnvironment?
    private let capabilities: () -> Capabilities
    private let client: () -> (any ChatLiveClient)?
    private var runs: [String: Run] = [:]
    /// The push-to-start token as the system last gave it, and the one the server has.
    private var startToken: String?
    private var sentStartToken: String?
    private var watchers: [Task<Void, Never>] = []
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    /// Uploads sent (tests).
    private(set) var startTokensSent: [String] = []
    private(set) var tokensSent: [(thread: String, token: String)] = []
    /// Updates go out in order, one after the other.
    private var chain: Task<Void, Never>?

    init(
        adapter: any ChatLiveAdapter, now: @escaping () -> Date, isAppActive: @escaping () -> Bool,
        environment: LiveEnvironment? = nil, capabilities: @escaping () -> Capabilities = { .unknown },
        client: @escaping () -> (any ChatLiveClient)? = { nil }
    ) {
        self.adapter = adapter
        self.now = now
        self.isAppActive = isAppActive
        self.environment = environment
        self.capabilities = capabilities
        self.client = client
    }

    private var pushAvailable: Bool { environment != nil && capabilities().chatLivePush && client() != nil }

    // MARK: replies sent from another device (27.9)

    /// At launch (a push-to-start can launch the app in the background for this): follows the push-to-start token and
    /// the activities the server starts, handing each one's update token to the server.
    func start() {
        guard watchers.isEmpty else { return }
        let starts = adapter.startTokens()
        let created = adapter.newActivities()
        watchers.append(Task { [weak self] in
            for await token in starts {
                guard let self else { return }
                self.startToken = token
                await self.sendStartToken()
            }
        })
        watchers.append(Task { [weak self] in
            for await handle in created {
                guard let self else { return }
                if handle.source == .other { self.watchTokens(handle) }
            }
        })
        // activities the server started while the app was not running
        for h in adapter.activities where h.source == .other && !h.isEnded { watchTokens(h) }
    }

    /// The server or its features changed: the start token goes (again) to a server that pushes.
    func capabilitiesChanged() async {
        sentStartToken = nil
        await sendStartToken()
    }

    private func sendStartToken() async {
        guard pushAvailable, let environment, let client = client(), let token = startToken, token != sentStartToken else { return }
        startTokensSent.append(token)
        do {
            try await client.registerChatLiveStartToken(token, environment: environment)
            sentStartToken = token
        } catch {
            // the next token, launch or capabilities change tries again
        }
    }

    private func watchTokens(_ h: any ChatLiveHandle) {
        let thread = h.thread
        guard tokenTasks[thread] == nil else { return }
        let tokens = h.pushTokens()
        tokenTasks[thread] = Task { [weak self] in
            for await token in tokens {
                guard let self, self.pushAvailable, let environment = self.environment, let client = self.client() else { continue }
                self.tokensSent.append((thread, token))
                try? await client.putChatLiveToken(threadID: thread, token: token, environment: environment)
            }
            self?.tokenTasks[thread] = nil
        }
    }

    /// The state an activity shows for a thread's reply on its way (tests, and the Shortcut).
    func state(of thread: String) -> ChatLiveContentState? { runs[thread]?.tracker.state }

    /// A message went out. An older activity of the same thread (a reply that never reported its end) ends first.
    func began(thread: String, prompt: String, source: ChatLiveSource) {
        let tracker = ChatLiveTracker(since: now())
        var handle: (any ChatLiveHandle)?
        let older = adapter.activities.filter { $0.thread == thread && !$0.isEnded }
        if !older.isEmpty {
            enqueue { for h in older { await h.end(ChatLiveContentState(status: .failed, since: tracker.state.since, code: "error.chat.interrupted"), dismissAt: nil) } }
        }
        if adapter.isAvailable {
            // refused (the app is in the background and no Live Activity intent is running): the reply simply has none
            handle = try? adapter.request(
                ChatLiveAttributes(thread: thread, prompt: prompt, source: source), state: tracker.state,
                staleDate: now().addingTimeInterval(Self.staleAfter))
        }
        runs[thread] = Run(handle: handle, tracker: tracker, source: source, lastPush: now())
    }

    /// One event of the reply.
    func observe(_ event: ChatEvent, thread: String) {
        guard var run = runs[thread] else { return }
        let change = run.tracker.apply(event)
        switch change {
        case .none:
            runs[thread] = run
            return
        case .minor where now().timeIntervalSince(run.lastPush) < Self.textInterval:
            run.dirty = true
            runs[thread] = run
            return
        default:
            break
        }
        if run.tracker.state.isTerminal {
            runs[thread] = run
            finish(thread)
            return
        }
        run.dirty = false
        run.lastPush = now()
        runs[thread] = run
        push(run)
    }

    /// The send returned. `final` is the thread's last message as the store holds it now (the saved reply after a dropped
    /// stream was followed); `code` is the failure to show when it is not a finished reply.
    func ended(thread: String, final: ChatMessage?, code: String = "error.chat.interrupted") {
        guard var run = runs[thread] else { return }
        run.tracker.end(with: final, code: code)
        runs[thread] = run
        finish(thread)
    }

    private func push(_ run: Run) {
        guard let handle = run.handle else { return }
        let state = run.tracker.state
        let stale = now().addingTimeInterval(Self.staleAfter)
        enqueue { await handle.update(state, staleDate: stale) }
    }

    private func finish(_ thread: String) {
        guard let run = runs.removeValue(forKey: thread), let handle = run.handle else { return }
        let state = run.tracker.state
        let dismiss: Date?
        if run.source == .app && isAppActive() {
            dismiss = nil                                   // the owner watched it in the chat tab
        } else {
            dismiss = now().addingTimeInterval(state.status == .done ? Self.dismissDone : Self.dismissFailed)
        }
        enqueue { await handle.end(state, dismissAt: dismiss) }
    }

    private func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits for the updates sent so far (tests).
    func settle() async { await chain?.value }

    /// Another server or key: every reply activity ends now.
    func reset() {
        let open = adapter.activities.filter { !$0.isEnded }
        runs.removeAll()
        enqueue { for h in open { await h.end(ChatLiveContentState(status: .failed, since: Date().timeIntervalSince1970, code: "error.chat.interrupted"), dismissAt: nil) } }
    }
}
