import Foundation

/// The server's line, mirrored (CONTRACT-PARALLEL.md 3.3). It never decides anything: every position comes from a
/// poll answer's `queue_ahead` (the jobs before this one, the running one included, so `queue_ahead + 1` is the
/// place), and who is ahead comes from `GET /studio/line`, read every 3 s while any job of this app waits and the app
/// is active: one request for all of them. A missed read only loses the labels.
@MainActor
final class ServerLine: JobLine {
    static let pollSeconds: Double = 3

    private var ahead: [UUID: Int] = [:]
    /// The label of whoever holds position `n` when it is not this app's own work.
    private var labels: [Int: String] = [:]
    private var poller: Task<Void, Never>?
    private var pollGeneration = 0
    private let client: () -> any CobaltClient
    private let clock: any PipelineClock
    private let isActive: () -> Bool

    var onChange: LineChange?
    /// Reads of `GET /studio/line` so far (tests).
    private(set) var reads = 0

    init(client: @escaping () -> any CobaltClient, clock: any PipelineClock, isActive: @escaping () -> Bool) {
        self.client = client
        self.clock = clock
        self.isActive = isActive
    }

    /// Jobs of this app the server holds in its line right now.
    var queued: [UUID] { Array(ahead.keys) }

    // MARK: JobLine

    func enter(_ job: UUID, kind: LineKind, priority: LinePriority) async throws { try Task.checkCancellation() }

    func observe(_ job: UUID, queueAhead: Int?) {
        if let queueAhead {
            ahead[job] = max(0, queueAhead)
            publish(job)
            ensurePolling()
        } else if ahead.removeValue(forKey: job) != nil {
            onChange?(job, nil)
            stopIfIdle()
        }
    }

    func noteOnServer(_ job: UUID) {}

    func release(_ job: UUID) {
        guard ahead.removeValue(forKey: job) != nil else { return }
        onChange?(job, nil)
        stopIfIdle()
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
        poller?.cancel()
        poller = nil
        for job in jobs { onChange?(job, nil) }
    }

    // MARK: Labels

    private func publish(_ job: UUID) { onChange?(job, position(of: job)) }
    private func publishAll() { for job in ahead.keys { publish(job) } }

    private func stopIfIdle() {
        guard ahead.isEmpty else { return }
        poller?.cancel()
        poller = nil
        labels = [:]
    }

    private func ensurePolling() {
        guard poller == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        poller = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ahead.isEmpty {
                if self.isActive() { await self.read() }
                try? await self.clock.sleep(seconds: Self.pollSeconds)
            }
            // a newer poller may already have taken the slot (stopped, then a job queued again)
            if let self, self.pollGeneration == generation { self.poller = nil }
        }
    }

    private func read() async {
        reads += 1
        do {
            let snapshot = try await client().line()
            guard !ahead.isEmpty else { return }
            labels = Self.labels(from: snapshot)
        } catch {
            labels = [:]                       // positions stay, the labels go
        }
        publishAll()
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
