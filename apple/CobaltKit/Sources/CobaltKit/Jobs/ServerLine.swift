import Foundation

/// The server's line, mirrored (CONTRACT-PARALLEL.md 3.3). It never decides anything: every position comes from a
/// poll answer's `queue_ahead` (the jobs before this one, the running one included, so `queue_ahead + 1` is the
/// place), and who is ahead comes from the line `ServerActivityStore` last read (apple 03-PHASE3 3.3: the one paced
/// poller of `GET /queue`, or `GET /studio/line` on a server without `features.queue`). This type reads nothing of its
/// own any more: the store calls `apply(_:)` with each answer, and is told when a job joins or leaves the line so
/// that it polls at once and, with nobody waiting, not at all (on a legacy server). A missed read only loses the labels.
@MainActor
final class ServerLine: JobLine {
    private var ahead: [UUID: Int] = [:]
    /// The label of whoever holds position `n` when it is not this app's own work.
    private var labels: [Int: String] = [:]

    var onChange: LineChange?
    /// The set of jobs waiting in the line changed: `joined` is true when a job came in (the store polls for its labels at
    /// once), false when one left (the store may slow down or stop). Installed by `ServerActivityStore`.
    var onWaitersChanged: (@MainActor (_ joined: Bool) -> Void)?

    /// `client`, `clock` and `isActive` are what the line read with before the store did; kept so `JobQueue`'s init is unchanged.
    init(client: @escaping () -> any CobaltClient, clock: any PipelineClock, isActive: @escaping () -> Bool) {}

    /// Jobs of this app the server holds in its line right now.
    var queued: [UUID] { Array(ahead.keys) }

    // MARK: JobLine

    func enter(_ job: UUID, kind: LineKind, priority: LinePriority) async throws { try Task.checkCancellation() }

    func observe(_ job: UUID, queueAhead: Int?) {
        if let queueAhead {
            let joined = ahead[job] == nil
            ahead[job] = max(0, queueAhead)
            publish(job)
            if joined { onWaitersChanged?(true) }
        } else if ahead.removeValue(forKey: job) != nil {
            onChange?(job, nil)
            leftLine()
        }
    }

    func noteOnServer(_ job: UUID) {}

    func release(_ job: UUID) {
        guard ahead.removeValue(forKey: job) != nil else { return }
        onChange?(job, nil)
        leftLine()
    }

    func position(of job: UUID) -> LinePosition? {
        guard let n = ahead[job] else { return nil }
        return .inLine(n + 1, behind: labels[n])
    }

    /// Everything stops (a server change, the app shutting down).
    func reset() {
        let jobs = Array(ahead.keys)
        ahead = [:]
        labels = [:]
        for job in jobs { onChange?(job, nil) }
        if !jobs.isEmpty { onWaitersChanged?(false) }
    }

    // MARK: Labels

    /// The store's latest answer: who holds each place. `nil` is a read that failed (the positions stay, the labels go).
    func apply(_ line: ServerLineSnapshot?) {
        guard !ahead.isEmpty else { labels = [:]; return }            // nobody waits: nothing to label
        let fresh = line.map(Self.labels(from:)) ?? [:]
        guard fresh != labels else { return }
        labels = fresh
        publishAll()
    }

    private func publish(_ job: UUID) { onChange?(job, position(of: job)) }
    private func publishAll() { for job in ahead.keys { publish(job) } }

    private func leftLine() {
        if ahead.isEmpty { labels = [:] }
        onWaitersChanged?(false)
    }

    /// position -> label, for the work that is not this app's own: "a share from your iphone", "a save from your mac".
    static func labels(from snapshot: ServerLineSnapshot) -> [Int: String] {
        var out: [Int: String] = [:]
        if let r = snapshot.running, !r.mine { out[1] = label(origin: r.origin, kind: r.kind, key: r.keyName) }
        for e in snapshot.entries where !e.mine { out[e.position] = label(origin: e.origin, kind: e.kind, key: e.keyName) }
        return out
    }

    static func label(origin: String?, kind: String, key: String?) -> String {
        let name = key.flatMap { $0.isEmpty ? nil : $0 }
        if origin == "share" { return name.map { "a share from your \($0)" } ?? "a share that isn't in this list" }
        if kind == "render" { return name.map { "a webp from your \($0)" } ?? "a webp that isn't in this list" }
        if kind == "save" { return name.map { "a save from your \($0)" } ?? "a save that isn't in this list" }
        return "a save that isn't in this list"
    }
}

/// Device-line extras the pipeline calls without knowing which line it is on (a server line ignores them).
extension JobLine {
    func noteBusyElsewhere(label: String?) { (self as? LocalLine)?.noteForeign(label: label) }
    func clearBusyElsewhere() { (self as? LocalLine)?.clearForeign() }
}
