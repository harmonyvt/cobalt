#if DEBUG && os(iOS)
import ActivityKit
import CobaltKit
import Foundation

/// Simulator evidence for the Live Activity views (debug builds only). The widget's own previews
/// need Xcode; this starts real activities from the fixture states of CONTRACT-LIVE.md 2.4 so the
/// island and the Lock Screen can be screenshotted with `simctl`.
///
///   -previewLive done                       one activity at that fixture state
///   -previewLive fetching_waking,decoding   two activities (the minimal island, two at once)
///   -previewLiveInput file                  attributes of a file run (default: link)
///   -previewLiveOrigin share                attributes of a share-sheet run
///   -previewLiveCycle 1                     step the first activity through every state, 5 s apart
///   -previewLiveStale 1                     the activity goes stale after 4 s
///   -previewLive none                       end every activity and start nothing
@MainActor
enum DebugLive {
    static let order = [
        "fetching_waking", "uploading", "saving_storing", "reading", "ready", "decoding", "packing", "done",
        "failed_render_lost", "failed_fetch",
    ]

    private static var started: [Activity<CobaltActivityAttributes>] = []

    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "previewLive") else { return }
        NSLog("[debuglive] enabled=%d", ActivityAuthorizationInfo().areActivitiesEnabled)
        Task {
            // Activity.request needs an active scene: wait for the first one.
            try? await Task.sleep(for: .seconds(2))
            for activity in Activity<CobaltActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            guard raw != "none" else { return }
            let input = defaults.string(forKey: "previewLiveInput") ?? "link"
            let origin = defaults.string(forKey: "previewLiveOrigin") ?? "app"
            let names = raw.split(separator: ",").map(String.init)
            for (i, name) in names.enumerated() {
                guard let state = state(name) else { continue }
                let attributes = CobaltActivityAttributes(LiveRunAttributes(
                    run: UUID(),
                    input: input,
                    service: input == "file" ? "file" : (i == 0 ? "instagram" : "x"),
                    ref: input == "file" ? "IMG_0412.mov" : (i == 0 ? "Dd7P496wolG" : "2105435404002562056"),
                    origin: origin))
                let stale = defaults.bool(forKey: "previewLiveStale") ? Date().addingTimeInterval(4) : nil
                do {
                    let activity = try Activity.request(
                        attributes: attributes, content: .init(state: state, staleDate: stale), pushType: nil)
                    started.append(activity)
                    NSLog("[debuglive] started %@ (%@)", name, activity.id)
                } catch {
                    NSLog("[debuglive] request failed for %@: %@", name, String(describing: error))
                }
            }
            guard defaults.bool(forKey: "previewLiveCycle") else { return }
            guard let run = started.first?.attributes.run else { return }
            for name in order {
                try? await Task.sleep(for: .seconds(5))
                guard let state = state(name) else { continue }
                await Self.update(run: run, to: state)
            }
        }
    }

    /// Looks the activity up again by run id: ActivityKit's handle is not `Sendable`.
    private nonisolated static func update(run: String, to state: LiveContentState) async {
        for activity in Activity<CobaltActivityAttributes>.activities where activity.attributes.run == run {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// A fixture state with its clock moved to a few seconds ago, so timers read seconds.
    private static func state(_ name: String) -> LiveContentState? {
        guard var s = LiveContentState.samples[name] else { return nil }
        s.since = Date().timeIntervalSince1970 - 7
        return s
    }
}
#endif
