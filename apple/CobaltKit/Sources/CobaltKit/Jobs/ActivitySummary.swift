import Foundation

// The one count of "what is cobalt doing" (apple 03-PHASE3 3.2, "Unified Counting Invariant").
//
// Before: the toolbar badge (`UnifiedQueue.badgeCount`), the queue header (`UnifiedQueue.summary`), the tray's header
// (`JobTray.Counts`), the pane's seam (`PaneSeam`) and the Live Activity's busy period each counted a different subset, so the
// same moment read "1", "2" and "3" on three surfaces. After: every surface reads `AppModel.activity.activeCount` and
// `.attentionCount`, and they cannot disagree because both are derived from the one `items` list.

/// Every piece of work, once, with the two counts derived from it.
public struct ActivitySummary: Sendable, Equatable {
    /// Deduplicated, in the order the activity sheet lists them: running (this device's line order), then needs attention
    /// (newest first), then settled (newest first).
    public let items: [JobStatus]
    /// Work going on or waiting its turn, the focused job included (`JobStatus.isActive`).
    public let activeCount: Int
    /// Failed jobs, and finished ones whose copy on this device did not arrive (`JobStatus.needsAttention`).
    public let attentionCount: Int

    public static let empty = ActivitySummary(items: [])

    /// `items` is taken as it is: use `build` to merge and dedupe the owners' lists.
    public init(items: [JobStatus]) {
        self.items = items
        self.activeCount = items.filter(\.isActive).count
        self.attentionCount = items.filter(\.needsAttention).count
    }

    public var running: [JobStatus] { items.filter { $0.bucket == .running } }
    public var attention: [JobStatus] { items.filter { $0.bucket == .attention } }
    /// The sheet's "recent": finished (or waiting on the owner), newest first.
    public func recent(limit: Int = 10) -> [JobStatus] { Array(items.filter { $0.bucket == .settled }.prefix(limit)) }
    public func item(_ id: JobStatus.ID) -> JobStatus? { items.first { $0.id == id } }

    /// Nothing running, waiting or failed.
    public var isQuiet: Bool { activeCount == 0 && attentionCount == 0 }

    /// Merges what each owner of work reports.
    ///
    /// **A status is dropped when a higher-ranked source already has one with the same `sessionID` or the same `serverJobID`**,
    /// in this order of rank:
    /// `pipelines` (this device's jobs: focused, minimized, or still carried by a hidden run) beat `downloads` (a pipeline's own
    /// keep-original download is `s:<session>`) beat `server` (the line, the editor's renders) beat `recent` (jobs that
    /// finished and left the queue). Statuses of one source that share a session stay (two jobs on one post are two jobs);
    /// the same `id` is never listed twice.
    public static func build(
        pipelines: [JobStatus] = [], downloads: [JobStatus] = [], server: [JobStatus] = [], recent: [JobStatus] = []
    ) -> ActivitySummary {
        var claimed: Set<String> = []                       // sessions and server jobs a higher-ranked source has
        var seen: Set<String> = []                          // ids already listed
        var kept: [JobStatus] = []
        for tier in [pipelines, downloads, server, recent] {
            var claimedHere: Set<String> = []
            for status in tier {
                let keys = status.dedupeKeys
                if keys.contains(where: claimed.contains) { continue }
                guard seen.insert(status.id).inserted else { continue }
                claimedHere.formUnion(keys)
                kept.append(status)
            }
            claimed.formUnion(claimedHere)
        }
        return ActivitySummary(items: kept.sorted(by: order))
    }

    /// running (a running job before a waiting one, waiting ones by their place), then attention, then settled.
    static func order(_ a: JobStatus, _ b: JobStatus) -> Bool {
        let (ba, bb) = (rank(a.bucket), rank(b.bucket))
        if ba != bb { return ba < bb }
        switch a.bucket {
        case .running:
            let (wa, wb) = (a.stage.isWaiting, b.stage.isWaiting)
            if wa != wb { return !wa }
            if wa, case .queued(let x) = a.stage, case .queued(let y) = b.stage, (x ?? .max) != (y ?? .max) { return (x ?? .max) < (y ?? .max) }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        case .attention, .settled:
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        }
        return a.id < b.id
    }

    private static func rank(_ bucket: JobStatus.Bucket) -> Int {
        switch bucket {
        case .running: return 0
        case .attention: return 1
        case .settled: return 2
        }
    }
}
