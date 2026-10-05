import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// The part of ActivityKit the manager uses, as a seam: the real adapter is iOS only, tests (and
/// the Mac) use a fake, so the manager's logic runs under `swift test` on macOS.
@MainActor
protocol LiveActivityHandle: AnyObject, Sendable {
    var attributes: LiveRunAttributes { get }
    /// The system's id of this activity: two handles with the same run in their attributes but
    /// different ids are two activities (a duplicate).
    var activityID: String { get }
    var state: LiveContentState { get }
    /// Ended or dismissed: nothing can be written to it any more.
    var isEnded: Bool { get }
    /// Its content is fresh: its stale date lies ahead (someone is writing it).
    func isFresh(at now: Date) -> Bool
    /// The activity's update push token, lowercase hex, current value first, then every change.
    func pushTokens() -> AsyncStream<String>
    func update(_ state: LiveContentState, staleDate: Date?) async
    /// `dismissAt` nil: `.immediate`.
    func end(_ state: LiveContentState, dismissAt: Date?) async
}

@MainActor
protocol LiveActivityAdapter: AnyObject, Sendable {
    /// Live Activities are allowed (`ActivityAuthorizationInfo().areActivitiesEnabled`).
    var isAvailable: Bool { get }
    var activities: [any LiveActivityHandle] { get }
    func request(
        _ attributes: LiveRunAttributes, state: LiveContentState, staleDate: Date, push: Bool
    ) throws -> any LiveActivityHandle
    /// `pushToStartTokenUpdates`, lowercase hex.
    func startTokens() -> AsyncStream<String>
    /// `pushToStartToken` right now.
    var currentStartToken: String? { get }
    /// `activityUpdates`: activities the system (a push-to-start) created.
    func newActivities() -> AsyncStream<any LiveActivityHandle>
}

extension Data {
    var liveHex: String { map { String(format: "%02x", $0) }.joined() }
}

#if os(iOS) && canImport(ActivityKit)

@MainActor
final class ActivityKitHandle: LiveActivityHandle {
    /// ActivityKit's `Activity` is not `Sendable`; every use here is on the main actor.
    nonisolated(unsafe) let activity: Activity<CobaltActivityAttributes>

    init(_ activity: Activity<CobaltActivityAttributes>) { self.activity = activity }

    var attributes: LiveRunAttributes {
        let a = activity.attributes
        return LiveRunAttributes(
            run: UUID(uuidString: a.run) ?? UUID(), input: a.input, service: a.service, ref: a.ref, origin: a.origin)
    }

    var activityID: String { activity.id }

    var state: LiveContentState { activity.content.state }

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

    func update(_ state: LiveContentState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: LiveContentState, dismissAt: Date?) async {
        let content = ActivityContent(state: state, staleDate: nil)
        await activity.end(content, dismissalPolicy: dismissAt.map { .after($0) } ?? .immediate)
    }
}

@MainActor
final class ActivityKitAdapter: LiveActivityAdapter {
    init() {}

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var activities: [any LiveActivityHandle] {
        Activity<CobaltActivityAttributes>.activities.map { ActivityKitHandle($0) }
    }

    func request(
        _ attributes: LiveRunAttributes, state: LiveContentState, staleDate: Date, push: Bool
    ) throws -> any LiveActivityHandle {
        let activity = try Activity.request(
            attributes: CobaltActivityAttributes(attributes),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: push ? .token : nil)
        return ActivityKitHandle(activity)
    }

    func startTokens() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                for await data in Activity<CobaltActivityAttributes>.pushToStartTokenUpdates {
                    continuation.yield(data.liveHex)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var currentStartToken: String? { Activity<CobaltActivityAttributes>.pushToStartToken?.liveHex }

    func newActivities() -> AsyncStream<any LiveActivityHandle> {
        AsyncStream { continuation in
            let task = Task {
                for await activity in Activity<CobaltActivityAttributes>.activityUpdates {
                    let handle: any LiveActivityHandle = ActivityKitHandle(activity)
                    continuation.yield(handle)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
