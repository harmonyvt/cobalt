import Foundation
import Observation

/// What the on-device library copy is doing, in words a screen can show.
public enum SyncHealthState: Sendable, Equatable {
    /// The engine is off for this launch: `GET /sync` answered 404, the store would not open, or the
    /// re-pull after a server change fell back again. Today's `GET /library` pages are in use.
    case disabled
    /// Nothing is running. Waiting edits, if any, are in `SyncStatusSnapshot.pendingCount`.
    case idle
    /// A pass is sending the outbox or pulling changes.
    case syncing
    /// Nothing reaches the server. `pending` edits wait on the device.
    case offline(pending: Int)
    /// The last pass ended with the server refusing an edit, or not serving the pull. `code` is the
    /// server's error code where it gave one. `nextRetryAt` is nil: the engine has no pull backoff yet,
    /// so nothing schedules a retry date to show.
    case error(code: String?, pending: Int, nextRetryAt: Date?)
    /// The cursor was too old (410): the copy is dropped and pulled again from 0.
    case repulling
}

/// A read-only picture of the library sync engine at one moment. `LibraryModel.syncStatus` hands
/// the latest one out; it is nil while `sync.engine` is off. Reading it never sends, rolls back or pulls.
public struct SyncStatusSnapshot: Sendable, Equatable {
    public var state: SyncHealthState
    /// Edits in the outbox, as the engine last counted them.
    public var pendingCount: Int
    /// The server cursor the copy has applied up to (0 before the first pull and after a re-pull begins).
    public var cursorSeq: Int64
    /// When a pull last reached the server and was applied. Nil since launch if none has.
    public var lastSyncedAt: Date?

    public init(state: SyncHealthState = .idle, pendingCount: Int = 0, cursorSeq: Int64 = 0, lastSyncedAt: Date? = nil) {
        self.state = state
        self.pendingCount = pendingCount
        self.cursorSeq = cursorSeq
        self.lastSyncedAt = lastSyncedAt
    }
}

/// The facts behind a `SyncStatusSnapshot`, and how each thing the engine reports moves them. A plain
/// value with no clock and no main actor, so a test can walk it through a pass.
struct SyncStatusReducer: Sendable {
    private(set) var snapshot = SyncStatusSnapshot()

    private var routeActive = true
    /// A pass began while the route was marked missing. The engine only starts one then if it was
    /// reset for another server or account, so how this pass ends says whether the route is there now.
    private var retryingRoute = false
    private var reachable = true
    private var passRunning = false
    private var repulling = false
    /// Set by a refusal or a pull the server would not serve; cleared when the next pass begins.
    private var failure: Failure?

    private struct Failure: Sendable, Equatable {
        var code: String?
    }

    /// The server's own code for an error, where it has one. An empty string is "no code".
    static func code(of error: any Error) -> String? {
        if let error = error as? CobaltError, case .api(let code, _) = error { return code }
        return nil
    }

    mutating func passBegan() {
        passRunning = true
        if !routeActive { retryingRoute = true }
        failure = nil
        publish()
    }

    mutating func passEnded(pending: Int, cursor: Int64) {
        passRunning = false
        repulling = false
        snapshot.pendingCount = max(0, pending)
        snapshot.cursorSeq = cursor
        // The pass that was tried after a fallback ended without another 404: sync is running again
        // (a new server, or the route was deployed). The pass that fell back itself also ends here,
        // and must leave the engine disabled.
        if retryingRoute {
            retryingRoute = false
            routeActive = true
        }
        publish()
    }

    mutating func refused(pending: Int, code: String?) {
        snapshot.pendingCount = max(0, pending)
        failure = Failure(code: code.flatMap { $0.isEmpty ? nil : $0 })
        publish()
    }

    mutating func repullBegan() {
        repulling = true
        snapshot.cursorSeq = 0
        publish()
    }

    /// The pull reached the server and was applied: the server is reachable, and `cursor` is where it got to.
    mutating func pulled(cursor: Int64, at now: Date) {
        reachable = true
        snapshot.cursorSeq = cursor
        snapshot.lastSyncedAt = now
        publish()
    }

    /// The pass ended without a pull and the engine stays on. `offline`: nothing reached the server.
    mutating func pullFailed(offline: Bool, code: String?, pending: Int) {
        snapshot.pendingCount = max(0, pending)
        if offline {
            reachable = false
        } else {
            reachable = true
            failure = Failure(code: code.flatMap { $0.isEmpty ? nil : $0 })
        }
        publish()
    }

    mutating func reachability(_ up: Bool, pending: Int) {
        snapshot.pendingCount = max(0, pending)
        reachable = up
        publish()
    }

    /// `GET /sync` answered 404 (or the store would not open): the engine is off for this launch.
    mutating func routeFellBack() {
        routeActive = false
        retryingRoute = false
        passRunning = false
        repulling = false
        failure = nil
        publish()
    }

    private mutating func publish() {
        let pending = snapshot.pendingCount
        let resolved: SyncHealthState
        if !routeActive {
            resolved = .disabled
        } else if repulling, passRunning {
            resolved = .repulling
        } else if let failure {
            resolved = .error(code: failure.code, pending: pending, nextRetryAt: nil)
        } else if !reachable {
            resolved = .offline(pending: pending)
        } else if passRunning {
            resolved = .syncing
        } else {
            resolved = .idle
        }
        if resolved != snapshot.state { snapshot.state = resolved }
    }
}

/// Holds the reducer for the main actor and lets SwiftUI observe each snapshot. `LibrarySync` writes it
/// when a pass, a refusal, a 410 or a fallback happens.
@MainActor @Observable
final class SyncStatusTracker {
    private(set) var snapshot = SyncStatusSnapshot()
    @ObservationIgnored private var reducer = SyncStatusReducer()

    var pendingCount: Int { snapshot.pendingCount }

    func passBegan() { apply { $0.passBegan() } }
    func passEnded(pending: Int, cursor: Int64) { apply { $0.passEnded(pending: pending, cursor: cursor) } }
    func refused(pending: Int, code: String?) { apply { $0.refused(pending: pending, code: code) } }
    func repullBegan() { apply { $0.repullBegan() } }
    func pulled(cursor: Int64, at now: Date = Date()) { apply { $0.pulled(cursor: cursor, at: now) } }
    func pullFailed(offline: Bool, code: String?, pending: Int) { apply { $0.pullFailed(offline: offline, code: code, pending: pending) } }
    func reachability(_ up: Bool, pending: Int) { apply { $0.reachability(up, pending: pending) } }
    func routeFellBack() { apply { $0.routeFellBack() } }

    private func apply(_ change: (inout SyncStatusReducer) -> Void) {
        change(&reducer)
        if reducer.snapshot != snapshot { snapshot = reducer.snapshot }
    }
}
