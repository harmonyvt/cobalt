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
    /// The server refused an edit, or did not serve the pull. `code` is the server's error code where
    /// it gave one. It stays until the owner dismisses it or a later pass succeeds (a refusal: a pass
    /// that pulls with nothing refused; a pull the server would not serve: the next pull that lands).
    /// `nextRetryAt` is when the engine tries the pull again by itself (5 s, 15 s, 45 s, then every
    /// 120 s); nil for a refusal, which is not retried.
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
    /// When the engine tries the pull again by itself after a failed one, offline or not. Nil when
    /// no retry is waiting (none failed, or a pass is running now).
    public var nextRetryAt: Date?

    public init(
        state: SyncHealthState = .idle, pendingCount: Int = 0, cursorSeq: Int64 = 0, lastSyncedAt: Date? = nil,
        nextRetryAt: Date? = nil
    ) {
        self.state = state
        self.pendingCount = pendingCount
        self.cursorSeq = cursorSeq
        self.lastSyncedAt = lastSyncedAt
        self.nextRetryAt = nextRetryAt
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
    /// Set by a refusal or a pull the server would not serve. It does not clear when a pass begins:
    /// it stays until `dismiss()` or a later pass succeeds (see `passEnded` and `pulled`).
    private var failure: Failure?
    /// This pass pulled, and recorded a refusal or a failed pull of its own.
    private var pulledThisPass = false
    private var failedThisPass = false
    /// When the engine tries the pull again. Cleared when that pass begins.
    private var retryAt: Date?

    private struct Failure: Sendable, Equatable {
        enum Kind: Sendable { case refusal, pull }
        var code: String?
        var kind: Kind
    }

    /// The server's own code for an error, where it has one. An empty string is "no code".
    static func code(of error: any Error) -> String? {
        if let error = error as? CobaltError, case .api(let code, _) = error { return code }
        return nil
    }

    mutating func passBegan() {
        passRunning = true
        if !routeActive { retryingRoute = true }
        pulledThisPass = false
        failedThisPass = false
        retryAt = nil
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
        // A refusal is answered by a later success: a pass that pulled and had nothing refused.
        if pulledThisPass, !failedThisPass, failure?.kind == .refusal { failure = nil }
        publish()
    }

    mutating func refused(pending: Int, code: String?) {
        snapshot.pendingCount = max(0, pending)
        failure = Failure(code: code.flatMap { $0.isEmpty ? nil : $0 }, kind: .refusal)
        failedThisPass = true
        publish()
    }

    /// The owner dismissed the error. It does not stop the engine's own retry.
    mutating func dismiss() {
        failure = nil
        publish()
    }

    /// The engine will try the pull again at `date` (nil: no retry is waiting).
    mutating func retryScheduled(at date: Date?) {
        retryAt = date
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
        pulledThisPass = true
        if failure?.kind == .pull { failure = nil }
        snapshot.cursorSeq = cursor
        snapshot.lastSyncedAt = now
        publish()
    }

    /// The pass ended without a pull and the engine stays on. `offline`: nothing reached the server.
    mutating func pullFailed(offline: Bool, code: String?, pending: Int) {
        snapshot.pendingCount = max(0, pending)
        failedThisPass = true
        if offline {
            reachable = false
            if failure?.kind == .pull { failure = nil }          // not reaching the server is the news now
        } else {
            reachable = true
            failure = Failure(code: code.flatMap { $0.isEmpty ? nil : $0 }, kind: .pull)
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
        retryAt = nil
        publish()
    }

    private mutating func publish() {
        let pending = snapshot.pendingCount
        let resolved: SyncHealthState
        if !routeActive {
            resolved = .disabled
        } else if repulling, passRunning {
            resolved = .repulling
        } else if let failure, !(passRunning && !failedThisPass) {
            // While a later pass runs and has not failed, the status says it is syncing; the error
            // is back if that pass fails too, and gone if it succeeds.
            resolved = .error(code: failure.code, pending: pending, nextRetryAt: failure.kind == .pull ? retryAt : nil)
        } else if !reachable {
            resolved = .offline(pending: pending)
        } else if passRunning {
            resolved = .syncing
        } else {
            resolved = .idle
        }
        if resolved != snapshot.state { snapshot.state = resolved }
        if retryAt != snapshot.nextRetryAt { snapshot.nextRetryAt = retryAt }
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
    func dismissed() { apply { $0.dismiss() } }
    func retryScheduled(at date: Date?) { apply { $0.retryScheduled(at: date) } }

    private func apply(_ change: (inout SyncStatusReducer) -> Void) {
        change(&reducer)
        if reducer.snapshot != snapshot { snapshot = reducer.snapshot }
    }
}
