#if DEBUG && os(iOS)
import ActivityKit
import CobaltKit
import Foundation

/// Simulator evidence for the Live Activity views (debug builds only). The widget's own previews
/// need Xcode; this starts real job activities (CONTRACT-JOBLIVE.md) from the fixture states of CONTRACT-LIVE.md 2.4, turned
/// into the job island's words by the same local builder the app uses, so the island and the Lock Screen can be
/// screenshotted with `simctl`.
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

    private static var started: [Activity<CobaltJobActivityAttributes>] = []

    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "previewLive") else { return }
        NSLog("[debuglive] enabled=%d", ActivityAuthorizationInfo().areActivitiesEnabled)
        Task {
            // Activity.request needs an active scene: wait for the first one.
            try? await Task.sleep(for: .seconds(2))
            for activity in Activity<CobaltJobActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            guard raw != "none" else { return }
            let input = defaults.string(forKey: "previewLiveInput") ?? "link"
            let origin = defaults.string(forKey: "previewLiveOrigin") ?? "app"
            let names = raw.split(separator: ",").map(String.init)
            var first: LiveRunAttributes?
            for (i, name) in names.enumerated() {
                guard let state = state(name) else { continue }
                let run = LiveRunAttributes(
                    run: UUID(),
                    input: input,
                    service: input == "file" ? "file" : (i == 0 ? "instagram" : "x"),
                    ref: input == "file" ? "IMG_0412.mov" : (i == 0 ? "Dd7P496wolG" : "2105435404002562056"),
                    origin: origin)
                if first == nil { first = run }
                let job = JobLive.job(save: state, attributes: run)
                let stale = defaults.bool(forKey: "previewLiveStale") ? Date().addingTimeInterval(4) : nil
                do {
                    let activity = try Activity.request(
                        attributes: CobaltJobActivityAttributes(job.attributes),
                        content: .init(state: job.state, staleDate: stale), pushType: nil)
                    started.append(activity)
                    NSLog("[debuglive] started %@ (%@)", name, activity.id)
                } catch {
                    NSLog("[debuglive] request failed for %@: %@", name, String(describing: error))
                }
            }
            guard defaults.bool(forKey: "previewLiveCycle") else { return }
            guard let run = first else { return }
            for name in order {
                try? await Task.sleep(for: .seconds(5))
                guard let state = state(name) else { continue }
                await Self.update(run, to: state)
            }
        }
    }

    /// Looks the activity up again by run id: ActivityKit's handle is not `Sendable`.
    private nonisolated static func update(_ run: LiveRunAttributes, to state: LiveContentState) async {
        let job = JobLive.job(save: state, attributes: run)
        for activity in Activity<CobaltJobActivityAttributes>.activities where activity.attributes.id == job.attributes.id {
            await activity.update(.init(state: job.state, staleDate: nil))
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
