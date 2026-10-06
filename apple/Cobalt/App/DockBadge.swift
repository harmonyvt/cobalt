#if os(macOS)
import AppKit
import CobaltKit
import Observation

/// The Mac's Dock tile while jobs are in flight (CONTRACT-PARALLEL 2.11): the live count as the badge, and a
/// `ProcessInfo` activity held for as long as there is any, so App Nap does not stretch the polling clock of a window
/// the owner has left behind. Follows the queue itself rather than a view, so it still counts with every window closed.
@MainActor
final class DockBadge {
    private static let shared = DockBadge()

    private var queue: JobQueue?
    private var activity: NSObjectProtocol?

    /// Starts following `queue` (once; the Mac app has one model).
    static func follow(_ queue: JobQueue) {
        guard shared.queue == nil else { return }
        shared.queue = queue
        shared.track()
    }

    /// Reads the live count under observation: when it changes, read it again.
    private func track() {
        guard let queue else { return }
        let live = withObservationTracking {
            queue.summary.live
        } onChange: { [weak self] in
            // fires before the value lands: look again once it has
            Task { @MainActor in self?.track() }
        }
        apply(live)
    }

    private func apply(_ live: Int) {
        NSApp?.dockTile.badgeLabel = live > 0 ? "\(live)" : nil
        if live > 0 {
            if activity == nil {
                // `userInitiatedAllowingIdleSystemSleep`: App Nap stays off, the Mac may still sleep (the server keeps the line)
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep], reason: "cobalt is following saves on the server")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
#endif
