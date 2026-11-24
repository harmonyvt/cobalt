#if os(macOS)
import AppKit
import CobaltKit
import Observation

/// The Mac's Dock tile while jobs are in flight (CONTRACT-PARALLEL 2.11): the live count as the badge, and a
/// `ProcessInfo` activity held for as long as there is any, so App Nap does not stretch the polling clock of a window
/// the owner has left behind. Follows the model itself rather than a view, so it still counts with every window closed.
///
/// The count is `model.activity.activeCount` (apple 03-PHASE3 3.2, the one count the sidebar badge, the menu bar and the pill read).
/// The app's launch starts it (`CobaltApp.init`), so the tile counts before any window exists.
@MainActor
final class DockBadge {
    private static let shared = DockBadge()

    /// What the badge shows: read under observation.
    private var count: (@MainActor () -> Int)?
    private var activity: NSObjectProtocol?

    /// Starts following the one count (`model.activity.activeCount`), once (the Mac app has one model).
    static func follow(_ model: AppModel) {
        guard shared.count == nil else { return }
        shared.count = { [weak model] in model?.activity.activeCount ?? 0 }
        shared.track()
    }

    /// Reads the live count under observation: when it changes, read it again.
    private func track() {
        guard let count else { return }
        let live = withObservationTracking {
            count()
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
                    options: [.userInitiatedAllowingIdleSystemSleep], reason: "capystore is following saves on the server")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
#endif
