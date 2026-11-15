import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// The seam between a swarm button and the app (apple/CONTRACT-SWARMS.md 4). The App Intents themselves are in
// `Cobalt/Intents/SwarmLiveIntents.swift` (compiled into both the app and the widget extension); their `perform` is one
// call into this file. Everything that can be tested without the system lives here.
//
//   button -> intent (app process) -> `SwarmIntentHost.run` -> `SwarmActionRunner` (the device's own session)
//                                                           -> `SwarmLiveActivities.show` (the activity changes at once)
//
// The client comes from a hook the app sets at launch (`AppModel.installSwarmIntentHost()`), because the intent may be the
// reason the app was launched, in the background, with no scene: `CobaltApp.init` builds the model and sets the hook before
// anything else runs. The widget extension compiles the same intent but never runs `perform` (the system runs a
// `LiveActivityIntent` in the app process), so the hook is never set there and nothing in the extension reaches the network.

/// Why a swarm button could not even start (as opposed to the server refusing: that is a `SwarmError`).
public enum SwarmIntentHostError: Error, Sendable, Equatable {
    /// The app has not set up its session yet (never in practice: the app process does it before running an intent).
    case noSession

    /// A line in the app's voice.
    public var words: String {
        switch self {
        case .noSession: return "open capystore once, then try again"
        }
    }
}

/// What to do to an activity after a button: show the new state, and whether to end it with it.
public struct SwarmActivityUpdate: Hashable, Sendable {
    public enum Ending: Hashable, Sendable {
        /// Keep it: write the state.
        case none
        /// Declined or expired: it ends at once, as the server does.
        case immediately
        /// Done or failed: it ends showing the result and stays this many seconds (APP-API-CONTRACT 8.12).
        case after(seconds: Double)
    }

    public var state: JobLiveState
    public var ending: Ending

    /// The update for a swarm as the server has it now: the 61.5 state (`JobLiveState(swarm:now:)`), ended when the swarm has.
    public init(swarm: Swarm, now: Date) {
        state = JobLiveState(swarm: swarm, now: now)
        switch swarm.status {
        case .declined, .expired:
            ending = .immediately
        case .failed, .stopped:
            ending = .after(seconds: JobLiveTimes.failedSeconds)
        case .done where state.phase == .done:
            ending = .after(seconds: JobLiveTimes.dismissal(of: state))
        default:
            ending = .none
        }
    }
}

public enum SwarmIntentHost {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var client: (@Sendable () async -> (any CobaltClient)?)?
    }
    private static let box = Box()

    /// Set once at launch by the app: the client built from this device's own signed-in session (a client key never reaches
    /// here: `AppModel` hands out its current client, which carries the session token).
    public static func setClient(_ provider: (@Sendable () async -> (any CobaltClient)?)?) {
        box.lock.withLock { box.client = provider }
    }

    private static func provider() -> (@Sendable () async -> (any CobaltClient)?)? {
        box.lock.withLock { box.client }
    }

    /// Runs one button: approve, apply, decline or stop (`SwarmActionRunner`), then puts the answer on the swarm's activity
    /// without waiting for the server's push. Throws a `SwarmError` (the server's refusal, in `words`) or
    /// `SwarmIntentHostError`. `check` and `open` are links and throw `SwarmError.notACall`.
    @discardableResult
    public static func run(
        _ action: SwarmLiveAction, swarm id: String, hash: String?, now: @Sendable () -> Date = { Date() }
    ) async throws -> Swarm {
        guard let provider = provider(), let client = await provider() else { throw SwarmIntentHostError.noSession }
        do {
            let swarm = try await SwarmActionRunner.run(action, swarm: id, hash: hash, client: client)
            await SwarmLiveActivities.show(SwarmActivityUpdate(swarm: swarm, now: now()), swarm: id)
            return swarm
        } catch {
            let failure = SwarmError.from(error)
            // The plan moved on without this phone (answered elsewhere, changed, expired): show what is true now.
            switch failure {
            case .notAwaiting, .hashMismatch, .expired, .notReady:
                if let current = try? await client.swarm(id: id) {
                    await SwarmLiveActivities.show(SwarmActivityUpdate(swarm: current, now: now()), swarm: id)
                }
            default:
                break
            }
            throw failure
        }
    }
}

/// The swarm's job activity (run id `swarm:<id>`, kind "swarm"; APP-API-CONTRACT 61.5).
public enum SwarmLiveActivities {
    public static let kind = "swarm"

    /// The activity's run id.
    public static func runID(_ swarm: String) -> String { "swarm:\(swarm)" }

    /// Writes `update` to the swarm's activity, ending it when the update says so. No activity (the owner dismissed it, or
    /// this device was never push-started) is not an error. A no-op off iOS.
    public static func show(_ update: SwarmActivityUpdate, swarm id: String) async {
        #if os(iOS) && canImport(ActivityKit)
        let run = runID(id)
        for activity in Activity<CobaltJobActivityAttributes>.activities where activity.attributes.job.id == run {
            switch update.ending {
            case .none:
                // No stale date: a swarm waiting for its owner is not "no news" (the server pushes the changes).
                await activity.update(ActivityContent(state: update.state, staleDate: nil))
            case .immediately:
                await activity.end(ActivityContent(state: update.state, staleDate: nil), dismissalPolicy: .immediate)
            case .after(let seconds):
                await activity.end(
                    ActivityContent(state: update.state, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(seconds)))
            }
        }
        #endif
    }
}

extension AppModel {
    /// Gives the swarm buttons (Live Activity intents) this model's client. Call once at launch, before any scene.
    public func installSwarmIntentHost() {
        SwarmIntentHost.setClient { [weak self] in
            await MainActor.run { self?.ctx.client }
        }
    }
}
