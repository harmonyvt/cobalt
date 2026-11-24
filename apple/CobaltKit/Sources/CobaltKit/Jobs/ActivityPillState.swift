import Foundation

// What the activity pill in the top bar says (apple 03-PHASE3 3.4.1): one pure function of the one count, the network, the
// library sync and the container wake, so every screen that mounts the pill shows the same thing and a test can walk the
// six rows of the priority table. No words here: `Copy.Activity` names each state.
//
// The six rows, in the order that decides (the first that holds wins):
//
//  1. needs attention (a failed job, a device copy that did not arrive) or the library sync hit an error / a refusal
//  2. offline (the server cannot be reached), with the edits waiting on the device
//  3. work in motion (`activeCount`), with its own percent when only one job runs
//  4. the library is syncing
//  5. a container is waking
//  6. idle and healthy: a quiet dot

public enum ActivityPillState: Sendable, Equatable {
    /// Row 1. `retries` is `ActivitySummary.attentionCount`; `sync` the library sync hit an error (shown on its own, "⚠ sync", only
    /// when no job needs attention).
    case attention(retries: Int, sync: Bool)
    /// Row 2. `pending`: library edits waiting on the device (0 = none, or the sync engine is off).
    case offline(pending: Int)
    /// Row 3. `fraction`: 0...1 of the one running job; nil when more than one runs or the job cannot say.
    case active(count: Int, fraction: Double?)
    /// Row 4. `pending`: edits the pass is sending (0 = a pull only).
    case syncing(pending: Int)
    /// Row 5.
    case waking
    /// Row 6.
    case idle

    /// Which segment of the sheet a tap opens (`ActivityAndHealthSheet`).
    public enum Segment: String, Sendable, Equatable, CaseIterable {
        case activity, system
    }

    /// 1 (decides first) to 6 (decides last): the table's row.
    public var priority: Int {
        switch self {
        case .attention: return 1
        case .offline: return 2
        case .active: return 3
        case .syncing: return 4
        case .waking: return 5
        case .idle: return 6
        }
    }

    /// A tap opens the activity segment for work, failures of work and a healthy idle; the system segment for everything about the
    /// connection (offline, syncing, waking, a sync error).
    public var segment: Segment {
        switch self {
        case .attention(let retries, _): return retries > 0 ? .activity : .system
        case .active, .idle: return .activity
        case .offline, .syncing, .waking: return .system
        }
    }

    /// Anything but the quiet dot: the pill draws a label.
    public var isLoud: Bool { self != .idle }

    /// What the pill reads, by value. Everything is a number or a flag the app already has.
    public struct Inputs: Sendable, Equatable {
        public var activeCount: Int
        public var attentionCount: Int
        /// The one running job's 0...1, when exactly one job is active. Nil otherwise.
        public var soleFraction: Double?
        /// `AppModel.capabilities.kind == .unreachable`.
        public var offline: Bool
        /// `LibraryModel.syncStatus`: nil while the sync engine is off.
        public var sync: SyncStatusSnapshot?
        /// A container is starting up and nothing else says so (`SystemHealth.isWaking`).
        public var waking: Bool

        public init(
            activeCount: Int = 0, attentionCount: Int = 0, soleFraction: Double? = nil, offline: Bool = false,
            sync: SyncStatusSnapshot? = nil, waking: Bool = false
        ) {
            self.activeCount = max(0, activeCount)
            self.attentionCount = max(0, attentionCount)
            self.soleFraction = soleFraction
            self.offline = offline
            self.sync = sync
            self.waking = waking
        }

        /// The counts of `summary`, the one count every surface reads.
        public init(summary: ActivitySummary, offline: Bool, sync: SyncStatusSnapshot?, waking: Bool) {
            let sole = summary.activeCount == 1 ? summary.items.first(where: \.isActive)?.fraction : nil
            self.init(
                activeCount: summary.activeCount, attentionCount: summary.attentionCount, soleFraction: sole, offline: offline,
                sync: sync, waking: waking)
        }
    }

    /// The table, as a function.
    public static func resolve(_ input: Inputs) -> ActivityPillState {
        let syncError: Bool = {
            if case .error? = input.sync?.state { return true }
            return false
        }()
        if input.attentionCount > 0 || syncError {
            return .attention(retries: input.attentionCount, sync: syncError)
        }
        // nothing reaches the server: the network is down, or the sync engine says so (it learned first)
        let syncOffline: Bool = {
            if case .offline? = input.sync?.state { return true }
            return false
        }()
        if input.offline || syncOffline {
            return .offline(pending: input.sync?.pendingCount ?? 0)
        }
        if input.activeCount > 0 {
            return .active(count: input.activeCount, fraction: input.activeCount == 1 ? input.soleFraction : nil)
        }
        switch input.sync?.state {
        case .syncing?, .repulling?: return .syncing(pending: input.sync?.pendingCount ?? 0)
        default: break
        }
        if input.waking { return .waking }
        return .idle
    }

    /// `resolve` from the counts of `summary`.
    public static func resolve(summary: ActivitySummary, offline: Bool, sync: SyncStatusSnapshot?, waking: Bool) -> ActivityPillState {
        resolve(Inputs(summary: summary, offline: offline, sync: sync, waking: waking))
    }
}
