import Foundation

/// The device's line, for a server without `features.line` (CONTRACT-PARALLEL.md 3.1, "without features.line"): the
/// server's helper does one save or encode at a time, so the app takes turns on this device. First come first served;
/// the focused webp goes ahead of saves that have not started and never pre-empts the one that holds the slot.
///
/// A job holds the slot from `enter` until `release` (the save is ready, the render has its result, or either failed).
/// `noteOnServer` takes the slot for work the server already started (an upload's adopt, a run resumed after a
/// relaunch). `noteForeign` records a `429` for something that is not in this line (a save from another device): the
/// holder then reads "busy elsewhere" instead of "1st".
@MainActor
final class LocalLine: JobLine {
    private struct Waiter {
        var token: Int
        var job: UUID
        var priority: LinePriority
        var continuation: CheckedContinuation<Void, Error>
    }

    private(set) var holders: [UUID] = []
    private var waiters: [Waiter] = []
    private var token = 0
    private struct Foreign { var since: Date; var label: String? }
    private var foreign: Foreign?
    private let clock: any PipelineClock

    /// Told after every change, for every job the line knows: nil = running (not waiting).
    var onChange: LineChange?

    init(clock: any PipelineClock) { self.clock = clock }

    /// Who holds it now, and who waits (first to last): for tests.
    var waiting: [UUID] { orderedWaiters.map(\.job) }
    var isFree: Bool { holders.isEmpty && waiters.isEmpty }

    // MARK: JobLine

    func enter(_ job: UUID, kind: LineKind, priority: LinePriority) async throws {
        try Task.checkCancellation()
        if holders.contains(job) { return }
        if holders.isEmpty, waiters.isEmpty {
            holders.append(job)
            publish()
            return
        }
        token += 1
        let mine = token
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(token: mine, job: job, priority: priority, continuation: continuation))
                publish()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(mine) }
        }
    }

    func observe(_ job: UUID, queueAhead: Int?) {}

    func noteOnServer(_ job: UUID) {
        if let i = waiters.firstIndex(where: { $0.job == job }) {
            let w = waiters.remove(at: i)
            w.continuation.resume(throwing: CancellationError())
        }
        if !holders.contains(job) { holders.append(job) }
        publish()
    }

    func release(_ job: UUID) {
        if let i = holders.firstIndex(of: job) {
            holders.remove(at: i)
            if holders.isEmpty { foreign = nil }
        } else if let i = waiters.firstIndex(where: { $0.job == job }) {
            let w = waiters.remove(at: i)
            w.continuation.resume(throwing: CancellationError())
        } else {
            return
        }
        promote()
        publish()
    }

    func position(of job: UUID) -> LinePosition? {
        if let i = holders.firstIndex(of: job) {
            if i == 0, let foreign { return .serverBusy(since: foreign.since, label: foreign.label) }
            return .inLine(i + 1, behind: nil)
        }
        if let i = orderedWaiters.firstIndex(where: { $0.job == job }) { return .inLine(holders.count + i + 1, behind: nil) }
        return nil
    }

    /// A `429` for something this line does not hold: the head of the line is waiting on it.
    func noteForeign(label: String?) {
        if let current = foreign { foreign = Foreign(since: current.since, label: label ?? current.label) }
        else { foreign = Foreign(since: clock.now(), label: label) }
        publish()
    }

    func clearForeign() {
        guard foreign != nil else { return }
        foreign = nil
        publish()
    }

    /// A server change: nobody waits for the old server's slot any more.
    func reset() {
        let all = waiters
        waiters = []
        let jobs = holders + all.map(\.job)
        holders = []
        foreign = nil
        for w in all { w.continuation.resume(throwing: CancellationError()) }
        for job in jobs { onChange?(job, nil) }
    }

    // MARK: -

    /// Focused first, then first in first out (token order is arrival order).
    private var orderedWaiters: [Waiter] {
        waiters.sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.token < b.token }
    }

    private func promote() {
        while holders.isEmpty, let next = orderedWaiters.first {
            waiters.removeAll { $0.token == next.token }
            holders.append(next.job)
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ token: Int) {
        guard let i = waiters.firstIndex(where: { $0.token == token }) else { return }
        let w = waiters.remove(at: i)
        w.continuation.resume(throwing: CancellationError())
        publish()
    }

    /// Waiting jobs read their place; the holder is running, so it reads nil (or busy-elsewhere).
    private func publish() {
        guard let onChange else { return }
        for (i, job) in holders.enumerated() {
            if i == 0, let foreign { onChange(job, .serverBusy(since: foreign.since, label: foreign.label)) } else { onChange(job, nil) }
        }
        for (i, w) in orderedWaiters.enumerated() { onChange(w.job, .inLine(holders.count + i + 1, behind: nil)) }
    }
}
