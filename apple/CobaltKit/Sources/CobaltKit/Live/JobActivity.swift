import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// The app's side of the job island (apple/CONTRACT-JOBLIVE.md 5). The three managers (`LiveActivityManager` for saves,
// uploads and makes, `EditLiveManager` for editor renders, `ChatLiveManager` for chat replies) all show one ActivityKit
// type, `CobaltJobActivityAttributes` with `JobLiveState`. This file holds what they share: the seam over one activity
// (`JobActivityHandle`), the timings, the deep links, the old types still on screen from an older build, and the one
// ActivityKit adapter behind all three managers.

// MARK: - the seam

/// One job activity, as the managers see it. The real one wraps `Activity<CobaltJobActivityAttributes>` (iOS only); tests
/// and the Mac use fakes, so the managers' logic runs under `swift test` on macOS.
@MainActor
protocol JobActivityHandle: AnyObject, Sendable {
    /// The system's id of this activity: two handles with the same `attributes.id` but different ids are two activities
    /// (a duplicate).
    var activityID: String { get }
    /// Fixed for the activity's life. `id` is the run, render or thread it shows.
    var attributes: JobLiveAttributes { get }
    /// What it shows now.
    var state: JobLiveState { get }
    /// Ended or dismissed: nothing can be written to it any more.
    var isEnded: Bool { get }
    /// Its stale date lies ahead: someone is writing it.
    func isFresh(at now: Date) -> Bool
    /// The activity's update push token, lowercase hex: the current value first, then every change.
    func pushTokens() -> AsyncStream<String>
    func update(_ state: JobLiveState, staleDate: Date?) async
    /// `state` nil: it ends showing what it shows now. `dismissAt` nil: `.immediate`.
    func end(_ state: JobLiveState?, dismissAt: Date?) async
}

/// An activity of one of the three old types (`CobaltActivityAttributes`, `CobaltEditActivityAttributes`,
/// `CobaltChatActivityAttributes`) still on screen from an older build. This build never requests one, writes one or hands
/// one's token to the server. The server keeps pushing what was registered before the update in the old shape and ends it
/// on its own timings (APP-API-CONTRACT 8.13), so the app only ends the ones nobody writes any more, and any that show a
/// job the app now shows with a job activity of its own (`endOld`).
@MainActor
protocol OldLiveActivity: AnyObject {
    /// The run, render or thread it shows.
    var id: String { get }
    var isEnded: Bool { get }
    /// Its stale date lies ahead: someone (the server) is still writing it.
    func isFresh(at now: Date) -> Bool
    /// Ends it at once, showing what it shows now.
    func endNow() async
}

enum OldLiveActivities {
    /// Ends the old activities nobody is writing any more (their stale date has passed) and, when `showing` is given, the
    /// one that shows that job (the app is about to show it with a job activity: one island per job).
    @MainActor
    static func end(_ old: [any OldLiveActivity], now: Date, showing id: String? = nil) async {
        for a in old where !a.isEnded && (a.id == id || !a.isFresh(at: now)) {
            await a.endNow()
        }
    }
}

// MARK: - timings and links

/// How long a job activity stays fresh and how long a finished one stays on the Lock Screen (APP-API-CONTRACT 8.12, 8.13).
enum JobLiveTimes {
    /// An app-written state goes stale this long after it was written (the server's JOB_STALE_S): the widget then says
    /// "still working, no news for 3 min".
    static let staleSeconds: Double = 180
    /// A finished job: 60 s, 120 s when it has a link to copy.
    static let doneSeconds: Double = 60
    static let doneWithLinkSeconds: Double = 120
    /// A failed or lost job.
    static let failedSeconds: Double = 300

    /// The dismissal of an ended save, upload, make or busy period, from what it ends with.
    static func dismissal(of state: JobLiveState) -> Double {
        switch state.phase {
        case .done: return state.link != nil ? doneWithLinkSeconds : doneSeconds
        default: return failedSeconds         // failed and lost (an end is never working or waiting)
        }
    }
}

/// Where a tap on a job activity goes (`JobLiveAttributes.open`). Nil lets the widget open capystore itself; the server
/// never sets one, so the widget handles nil anyway.
enum JobLiveLinks {
    /// The tray of jobs: the busy period's activity and editor renders.
    static let jobs = "cobalt-apple://jobs"

    /// A share-sheet run the app took over opens that run (`cobalt-apple://job/<run>`, CONTRACT-SHARE-QUICK.md section 4);
    /// the app's own runs just open capystore.
    static func run(_ a: LiveRunAttributes) -> String? {
        a.origin == "share" ? "cobalt-apple://job/\(a.run)" : nil
    }
}

/// The kinds each manager follows (`JobLiveAttributes.kind`). Every job activity arrives through the same ActivityKit type,
/// so each manager picks its own.
enum JobLiveKinds {
    static let saves: Set<String> = ["save", "upload", "make", "many"]
    static let edits: Set<String> = ["edit"]
    static let chats: Set<String> = ["chat"]
}

// MARK: - ActivityKit

#if os(iOS) && canImport(ActivityKit)

@MainActor
final class ActivityKitJobHandle: JobActivityHandle {
    /// ActivityKit's `Activity` is not `Sendable`; every use here is on the main actor.
    nonisolated(unsafe) let activity: Activity<CobaltJobActivityAttributes>

    init(_ activity: Activity<CobaltJobActivityAttributes>) { self.activity = activity }

    var activityID: String { activity.id }
    var attributes: JobLiveAttributes { activity.attributes.job }
    var state: JobLiveState { activity.content.state }

    var isEnded: Bool {
        switch activity.activityState {
        case .ended, .dismissed: return true
        default: return false
        }
    }

    func isFresh(at now: Date) -> Bool {
        guard let stale = activity.content.staleDate else { return false }
        return stale > now
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

    func update(_ state: JobLiveState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: JobLiveState?, dismissAt: Date?) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: dismissAt.map { .after($0) } ?? .immediate)
    }
}

/// An old-type activity (any of the three), for ending only.
@MainActor
final class ActivityKitOldActivity<A: ActivityAttributes>: OldLiveActivity {
    nonisolated(unsafe) let activity: Activity<A>
    let id: String

    init(_ activity: Activity<A>, id: String) {
        self.activity = activity
        self.id = id
    }

    var isEnded: Bool {
        switch activity.activityState {
        case .ended, .dismissed: return true
        default: return false
        }
    }

    func isFresh(at now: Date) -> Bool {
        guard let stale = activity.content.staleDate else { return false }
        return stale > now
    }

    func endNow() async { await activity.end(nil, dismissalPolicy: .immediate) }
}

/// The real adapter behind all three managers: `Activity<CobaltJobActivityAttributes>`, narrowed to the manager's kinds,
/// plus that manager's old type for ending.
@MainActor
final class ActivityKitJobAdapter: LiveActivityAdapter, EditLiveAdapter, ChatLiveAdapter {
    private let kinds: Set<String>
    private let old: @MainActor () -> [any OldLiveActivity]

    private init(kinds: Set<String>, old: @escaping @MainActor () -> [any OldLiveActivity]) {
        self.kinds = kinds
        self.old = old
    }

    /// Saves, uploads, makes and the busy period (`LiveActivityManager`); its old type is `CobaltActivityAttributes`.
    static func saves() -> ActivityKitJobAdapter {
        ActivityKitJobAdapter(kinds: JobLiveKinds.saves) {
            Activity<CobaltActivityAttributes>.activities.map { ActivityKitOldActivity($0, id: $0.attributes.run) }
        }
    }

    /// Editor renders (`EditLiveManager`); its old type is `CobaltEditActivityAttributes`.
    static func edits() -> ActivityKitJobAdapter {
        ActivityKitJobAdapter(kinds: JobLiveKinds.edits) {
            Activity<CobaltEditActivityAttributes>.activities.map { ActivityKitOldActivity($0, id: $0.attributes.render) }
        }
    }

    /// Chat replies (`ChatLiveManager`); its old type is `CobaltChatActivityAttributes`.
    static func chats() -> ActivityKitJobAdapter {
        ActivityKitJobAdapter(kinds: JobLiveKinds.chats) {
            Activity<CobaltChatActivityAttributes>.activities.map { ActivityKitOldActivity($0, id: $0.attributes.thread) }
        }
    }

    /// Live Activities are allowed for capystore (Settings > capystore > Live Activities).
    static var activitiesAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isAvailable: Bool { Self.activitiesAllowed }

    var activities: [any JobActivityHandle] {
        Activity<CobaltJobActivityAttributes>.activities
            .filter { kinds.contains($0.attributes.kind) }
            .map { ActivityKitJobHandle($0) }
    }

    var oldActivities: [any OldLiveActivity] { old() }

    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle {
        let activity = try Activity.request(
            attributes: CobaltJobActivityAttributes(job.attributes),
            content: ActivityContent(state: job.state, staleDate: staleDate),
            pushType: push ? .token : nil)
        return ActivityKitJobHandle(activity)
    }

    /// The job type's push-to-start token, lowercase hex: one token starts every kind (APP-API-CONTRACT 8.13).
    func startTokens() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                for await data in Activity<CobaltJobActivityAttributes>.pushToStartTokenUpdates {
                    continuation.yield(data.liveHex)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var currentStartToken: String? { Activity<CobaltJobActivityAttributes>.pushToStartToken?.liveHex }

    /// Job activities the system created (a push-to-start), of this manager's kinds.
    func newActivities() -> AsyncStream<any JobActivityHandle> {
        let kinds = kinds
        return AsyncStream { continuation in
            let task = Task {
                for await activity in Activity<CobaltJobActivityAttributes>.activityUpdates
                where kinds.contains(activity.attributes.kind) {
                    let handle: any JobActivityHandle = ActivityKitJobHandle(activity)
                    continuation.yield(handle)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
