import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// Live Activities for editor renders (APP-API-CONTRACT.md section 32, apple/CONTRACT-EDITOR.md section 11): a render this
// device sees running gets its own activity on the Dynamic Island and the Lock Screen (status, a progress bar, the result
// when it is done). The app writes it while it is open; with `features.edit_live_push` the server writes it with the app
// closed, from the renderer's ticks. Kept apart from the run activities (`LiveActivityManager`): a render is not a pipeline
// run, has no rail, and is never folded into the busy period's summary.

/// What an editor render's activity shows, and what the server pushes. Like `LiveContentState`, the JSON keys are the Swift
/// property names (ActivityKit decodes a pushed `content-state` with a default `JSONDecoder`), absent optionals are omitted,
/// times are unix seconds. The server's `editLiveState` (src/edit-live.ts) builds the same object from the same render.
public struct EditLiveContentState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, preparing, rendering, finishing, done, failed, cancelled }

    public var status: Status
    public var since: Double              // unix seconds the status began (drives the timer text)
    public var title: String
    public var progress: Double?          // 0...1 (preparing 0...0.1, rendering 0.1...0.95, finishing 0.95, done 1)
    public var queueAhead: Int?           // queued: renders ahead of it (0 = next)
    public var resultSeconds: Double?     // done
    public var resultWidth: Int?
    public var resultHeight: Int?
    public var resultBytes: Int64?
    public var code: String?              // failed: the server's error code

    public init(status: Status, since: Double, title: String) {
        self.status = status
        self.since = since
        self.title = title
    }

    public var isTerminal: Bool { status == .done || status == .failed || status == .cancelled }

    /// The render as its activity shows it (the server's `editLiveState`, line for line).
    public init(_ r: EditRender) {
        let status: Status
        switch r.status {
        case .queued: status = .queued
        case .preparing: status = .preparing
        case .rendering: status = .rendering
        case .finishing: status = .finishing
        case .done: status = .done
        case .cancelled: status = .cancelled
        case .error: status = r.error == "error.edit.cancelled" ? .cancelled : .failed
        }
        let at: Date
        switch status {
        case .queued: at = r.createdAt
        case .done, .failed, .cancelled: at = r.finishedAt ?? r.createdAt
        case .preparing, .rendering, .finishing: at = r.startedAt ?? r.createdAt
        }
        self.init(status: status, since: floor(at.timeIntervalSince1970), title: r.title.isEmpty ? "untitled edit" : String(r.title.prefix(120)))
        if let p = r.progress { progress = (p * 1000).rounded() / 1000 }
        if status == .queued { queueAhead = r.queueAhead ?? 0 }
        if status == .done {
            resultSeconds = r.duration.map { ($0 * 1000).rounded() / 1000 }
            resultWidth = r.width
            resultHeight = r.height
            resultBytes = r.bytes
        }
        if status == .failed { code = r.error }
    }

    /// Fixture states by name, for the widget's previews and the tests.
    public static let samples: [String: EditLiveContentState] = {
        func make(_ status: Status, _ fill: (inout EditLiveContentState) -> Void = { _ in }) -> EditLiveContentState {
            var s = EditLiveContentState(status: status, since: 1_790_000_000, title: "beach day")
            fill(&s)
            return s
        }
        return [
            "queued": make(.queued) { $0.queueAhead = 1 },
            "preparing": make(.preparing) { $0.progress = 0.04 },
            "rendering": make(.rendering) { $0.progress = 0.52 },
            "finishing": make(.finishing) { $0.progress = 0.95 },
            "done": make(.done) {
                $0.progress = 1; $0.resultSeconds = 42.5; $0.resultWidth = 1080; $0.resultHeight = 1920; $0.resultBytes = 18_400_000
            },
            "failed": make(.failed) { $0.code = "error.edit.timeout" },
            "cancelled": make(.cancelled),
        ]
    }()
}

/// The fixed attributes of a render's activity; `CobaltEditActivityAttributes` (iOS only) mirrors it.
public struct EditLiveAttributes: Codable, Hashable, Sendable {
    public var render: String
    public var project: String

    public init(render: String, project: String) {
        self.render = render
        self.project = project
    }
}

/// The plain words for a render's failure code (the server's `plainReason` for `error.edit.*`).
public enum EditLiveCopy {
    public static func reason(_ code: String?) -> String {
        switch code {
        case "error.edit.render_failed": return "the video couldn't be made"
        case "error.edit.timeout": return "it took too long"
        case "error.edit.source_missing": return "a clip was deleted from the library"
        case "error.edit.lost": return "the server restarted"
        case "error.edit.too_large": return "the video was too big"
        case "error.edit.storage": return "the server couldn't store it"
        default: return "something went wrong"
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
public struct CobaltEditActivityAttributes: ActivityAttributes, Hashable, Sendable {
    public typealias ContentState = EditLiveContentState
    public var render: String
    public var project: String

    public init(_ a: EditLiveAttributes) {
        render = a.render
        project = a.project
    }
}
#endif

// MARK: - the seam

@MainActor
protocol EditLiveHandle: AnyObject {
    var render: String { get }
    var state: EditLiveContentState { get }
    var isEnded: Bool { get }
    /// The update push token, lowercase hex: the current value first, then every change.
    func pushTokens() -> AsyncStream<String>
    func update(_ state: EditLiveContentState, staleDate: Date?) async
    /// `dismissAt` nil: `.immediate`.
    func end(_ state: EditLiveContentState, dismissAt: Date?) async
}

@MainActor
protocol EditLiveAdapter: AnyObject {
    var isAvailable: Bool { get }
    var activities: [any EditLiveHandle] { get }
    func request(_ attributes: EditLiveAttributes, state: EditLiveContentState, staleDate: Date, push: Bool) throws -> any EditLiveHandle
}

#if os(iOS) && canImport(ActivityKit)
@MainActor
final class ActivityKitEditHandle: EditLiveHandle {
    nonisolated(unsafe) let activity: Activity<CobaltEditActivityAttributes>
    init(_ activity: Activity<CobaltEditActivityAttributes>) { self.activity = activity }

    var render: String { activity.attributes.render }
    var state: EditLiveContentState { activity.content.state }
    var isEnded: Bool {
        switch activity.activityState {
        case .ended, .dismissed: return true
        default: return false
        }
    }

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

    func update(_ state: EditLiveContentState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: EditLiveContentState, dismissAt: Date?) async {
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: dismissAt.map { .after($0) } ?? .immediate)
    }
}

@MainActor
final class ActivityKitEditAdapter: EditLiveAdapter {
    init() {}
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activities: [any EditLiveHandle] { Activity<CobaltEditActivityAttributes>.activities.map { ActivityKitEditHandle($0) } }
    func request(_ attributes: EditLiveAttributes, state: EditLiveContentState, staleDate: Date, push: Bool) throws -> any EditLiveHandle {
        let activity = try Activity.request(
            attributes: CobaltEditActivityAttributes(attributes),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: push ? .token : nil)
        return ActivityKitEditHandle(activity)
    }
}
#endif

// MARK: - the manager

/// Starts, updates and ends the activities of editor renders from every copy of a render the app sees (the editor's own
/// polls, the render list, the queue's snapshot), and hands each activity's token to the server.
@MainActor
final class EditLiveManager {
    /// No update for this long and iOS greys the activity out (the server's EDIT_LIVE_STALE_S).
    static let staleAfter: TimeInterval = 180
    static let dismissDone: TimeInterval = 900
    static let dismissFailed: TimeInterval = 300
    /// A render older than this never gets a new activity (a list of old renders is not news).
    static let freshFor: TimeInterval = 6 * 3600

    private let adapter: any EditLiveAdapter
    private let environment: LiveEnvironment?
    private let capabilities: () -> Capabilities
    private let client: () -> (any EditorClient)?
    private let now: () -> Date
    private var handles: [String: any EditLiveHandle] = [:]
    /// Renders whose activity this manager ended (or that ended while it watched): never started again.
    private var finished: Set<String> = []
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    /// Token uploads sent (tests).
    private(set) var tokensSent: [(render: String, token: String)] = []

    init(
        adapter: any EditLiveAdapter, environment: LiveEnvironment?, capabilities: @escaping () -> Capabilities,
        client: @escaping () -> (any EditorClient)?, now: @escaping () -> Date
    ) {
        self.adapter = adapter
        self.environment = environment
        self.capabilities = capabilities
        self.client = client
        self.now = now
    }

    private var pushAvailable: Bool { environment != nil && capabilities().editLivePush && client() != nil }

    /// Every copy of renders the app just read. Order does not matter; an older copy never moves an activity backwards.
    func observe(_ renders: [EditRender]) async {
        guard capabilities().editor else { return }
        for r in renders { await observe(r) }
    }

    private func handle(for render: String) -> (any EditLiveHandle)? {
        if let h = handles[render], !h.isEnded { return h }
        // after a relaunch: the activity this manager started before
        if let h = adapter.activities.first(where: { $0.render == render && !$0.isEnded }) {
            handles[render] = h
            watchTokens(h)
            return h
        }
        return nil
    }

    private func observe(_ r: EditRender) async {
        let next = EditLiveContentState(r)
        if let h = handle(for: r.id) {
            if Self.rank(next) < Self.rank(h.state) { return }          // an older copy (a stale snapshot)
            if next == h.state { return }
            if next.isTerminal {
                await finish(h, with: next)
            } else {
                await h.update(next, staleDate: now().addingTimeInterval(Self.staleAfter))
            }
            return
        }
        guard r.isActive, !finished.contains(r.id), adapter.isAvailable,
              now().timeIntervalSince(r.createdAt) < Self.freshFor
        else { return }
        // ActivityKit refuses a request while the app is in the background: it throws, and the next copy seen in front tries again
        guard let h = try? adapter.request(
            EditLiveAttributes(render: r.id, project: r.projectID), state: next,
            staleDate: now().addingTimeInterval(Self.staleAfter), push: pushAvailable)
        else { return }
        handles[r.id] = h
        watchTokens(h)
    }

    private func finish(_ h: any EditLiveHandle, with state: EditLiveContentState) async {
        let dismiss: Date? = switch state.status {
        case .done: now().addingTimeInterval(Self.dismissDone)
        case .failed: now().addingTimeInterval(Self.dismissFailed)
        default: nil
        }
        await h.end(state, dismissAt: dismiss)
        handles[h.render] = nil
        finished.insert(h.render)
        tokenTasks.removeValue(forKey: h.render)?.cancel()
    }

    private func watchTokens(_ h: any EditLiveHandle) {
        guard pushAvailable, let environment, tokenTasks[h.render] == nil else { return }
        let render = h.render
        let tokens = h.pushTokens()
        tokenTasks[render] = Task { [weak self] in
            for await token in tokens {
                guard let self, let client = self.client() else { return }
                self.tokensSent.append((render, token))
                _ = try? await client.putEditLiveToken(renderID: render, token: token, environment: environment)
            }
        }
    }

    /// In front again: activities whose render this app no longer has a copy of (the app was closed when it ended and no push
    /// reached it) are read once and brought up to date, or ended.
    func foreground() async {
        guard capabilities().editor, let client = client() else { return }
        for h in adapter.activities where !h.isEnded && handles[h.render] == nil {
            if let r = try? await client.editRender(id: h.render) {
                handles[h.render] = h
                watchTokens(h)
                await observe(r)
            } else if now().timeIntervalSince1970 - h.state.since > Self.freshFor {
                await h.end(h.state, dismissAt: nil)
            }
        }
    }

    /// The editor went away (server change, `features.editor` off): every activity ends now.
    func capabilitiesChanged() async {
        guard !capabilities().editor else { return }
        for h in adapter.activities where !h.isEnded { await h.end(h.state, dismissAt: nil) }
        handles.removeAll()
        for t in tokenTasks.values { t.cancel() }
        tokenTasks.removeAll()
    }

    /// How far along a state is, so an older copy of a render never moves its activity back.
    static func rank(_ s: EditLiveContentState) -> Double {
        switch s.status {
        case .queued: return -Double(s.queueAhead ?? 0) / 1000
        case .preparing, .rendering, .finishing: return 1 + (s.progress ?? 0)
        case .done, .failed, .cancelled: return 3
        }
    }
}
