import Foundation

/// What one pass did, for the library glow. The engine still sends, rolls back and pulls exactly as before.
enum SyncActivity: Sendable, Equatable {
    case passBegan
    case passEnded(pending: Int)
    case refused(pending: Int)
    case repull
    case fellBack
}

/// Sends the outbox, oldest first, then asks what changed. One pass is the body of the loop; tests
/// call `syncNow` directly. The socket nudge is `SyncTrigger.nudge` and does nothing but run a pass:
/// the socket itself is a later slice.
actor SyncEngine {
    let store: SyncStore
    private let transport: any SyncTransport
    private let sender: any SyncSender
    private var clock: @Sendable () -> Date
    private var generation = 0
    private var running = false
    private var pending = false
    private var idle: [CheckedContinuation<Void, Never>] = []
    private var wake: Task<Void, Never>?
    private(set) var fellBack = false
    /// The library publishes off this. Set from `LibrarySync` once the engine exists.
    private var onSnapshot: (@Sendable (SyncLibrarySnapshot) async -> Void)?
    private var onFallback: (@Sendable () async -> Void)?
    private var onAcknowledged: (@Sendable (String) async -> Void)?
    private var onRefused: (@Sendable (SyncOp) async -> Void)?
    /// Reports what a pass did, for the library glow. Never changes what is sent or pulled.
    private var onActivity: (@Sendable (SyncActivity) async -> Void)?

    func setCallbacks(
        snapshot: @escaping @Sendable (SyncLibrarySnapshot) async -> Void,
        fallback: @escaping @Sendable () async -> Void,
        acknowledged: @escaping @Sendable (String) async -> Void,
        refused: @escaping @Sendable (SyncOp) async -> Void
    ) {
        onSnapshot = snapshot
        onFallback = fallback
        onAcknowledged = acknowledged
        onRefused = refused
    }

    /// The glow listens here. Leaving it unset (the tests, a caller that does not care) changes nothing.
    func setActivity(_ handler: (@Sendable (SyncActivity) async -> Void)?) {
        onActivity = handler
    }

    init(store: SyncStore, transport: any SyncTransport, sender: any SyncSender, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.sender = sender
        self.clock = clock
    }

    /// Runs one pass, and another if something else was asked for while it ran (a pull that arrived
    /// mid-drain, a second nudge). Concurrent callers wait for that instead of pulling twice.
    func syncNow() async {
        pending = true
        if running {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in idle.append(cont) }
            if pending, !running { await syncNow() }
            return
        }
        running = true
        while pending && !fellBack {
            pending = false
            let token = generation
            await pass(token: token)
        }
        running = false
        let waiters = idle
        idle.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// A new server or a sign-out. An in-flight pass notices the generation and drops its page.
    func invalidate() async {
        generation += 1
        fellBack = false
        try? await store.wipeAll()
    }

    private func pass(token: Int) async {
        guard token == generation else { return }
        await signal(.passBegan)
        let drained = await OutboxDrainer.drain(store: store, sender: sender, now: clock())
        if token != generation {
            await signal(.passEnded(pending: await pendingCount()))
            return
        }
        let pending = await pendingCount()
        for op in drained.refused {
            await onRefused?(op)
            await signal(.refused(pending: pending))
        }
        for id in drained.acknowledged { await onAcknowledged?(id) }
        await publish()
        schedule(drained.wake)
        do {
            try await pull(token: token)
        } catch SyncError.notDeployed {
            fellBack = true
            await onFallback?()
            await signal(.fellBack)
        } catch SyncError.cursorTooOld {
            guard token == generation else {
                await signal(.passEnded(pending: await pendingCount()))
                return
            }
            await signal(.repull)
            try? await store.resetCursor()
            await publish()
            do { try await pull(token: token) } catch {
                Telemetry.log(.warn, .sync, "sync restart failed", data: ["error": .string(String(describing: error))])
            }
        } catch {
            Telemetry.log(.warn, .sync, "sync pull failed", data: ["error": .string(String(describing: error))])
        }
        await signal(.passEnded(pending: await pendingCount()))
    }

    private func signal(_ event: SyncActivity) async {
        await onActivity?(event)
    }

    private func pendingCount() async -> Int {
        (try? await store.pendingOps().count) ?? 0
    }

    private func pull(token: Int) async throws {
        var since = await store.cursor()
        var pages = 0
        while pages < 1_000 {
            if token != generation { return }
            let page = try await transport.pull(since: since, limit: SyncContract.pageLimit)
            if token != generation { return }
            try await store.apply(page)
            await publish()
            pages += 1
            if !page.more { return }
            if page.seq <= since { return }
            since = page.seq
        }
    }

    private func publish() async {
        guard let snapshot = try? await store.snapshot() else { return }
        await onSnapshot?(snapshot)
    }

    private func schedule(_ when: Date?) {
        wake?.cancel()
        guard let when else { return }
        let delay = when.timeIntervalSince(clock())
        guard delay > 0 else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled else { return }
            await self.syncNow()
        }
    }
}

/// What one drain did. `wake` is when the next retry is allowed.
struct OutboxDrain: Sendable {
    var wake: Date?
    var acknowledged: [String] = []
    var refused: [SyncOp] = []
}

/// The life of one outbox row: send it, and only a refusal puts the post back.
enum OutboxDrainer {
    /// The date the oldest not-ready op becomes ready, when one is waiting.
    static func drain(store: SyncStore, sender: any SyncSender, now: Date) async -> OutboxDrain {
        var result = OutboxDrain()
        let ops: [SyncOp]
        do { ops = try await store.pendingOps() } catch { return result }
        let fresh = ops.filter { now.timeIntervalSince($0.createdAt) < MutationRetry.retention }
        for expired in ops where now.timeIntervalSince(expired.createdAt) >= MutationRetry.retention {
            try? await store.removeOp(expired.opID)
            Telemetry.log(.info, .sync, "outbox dropped", data: ["op": .string(expired.opID), "kind": .string(expired.kind.rawValue)])
        }
        var blocked: Set<String> = []
        for op in fresh {
            if blocked.contains(op.target) { continue }
            if op.nextAttemptAt > now {
                blocked.insert(op.target)
                result.wake = min(result.wake ?? op.nextAttemptAt, op.nextAttemptAt)
                continue
            }
            do {
                try await sender.send(op)
                try await store.removeOp(op.opID)
                result.acknowledged.append(op.opID)
            } catch {
                switch MutationRetry.attempt(error, kind: op.kind) {
                case .succeeded:
                    try? await store.removeOp(op.opID)
                    result.acknowledged.append(op.opID)
                case .refused:
                    _ = try? await store.rollback(op)
                    result.refused.append(op)
                    let reason = (error as? SyncError).flatMap { if case .refused(let why) = $0 { return why } else { return nil } } ?? String(describing: error)
                    Telemetry.log(.warn, .sync, "outbox refused", data: ["op": .string(op.opID), "kind": .string(op.kind.rawValue), "error": .string(reason)])
                case .retry:
                    let tries = op.tries + 1
                    let next = now.addingTimeInterval(MutationRetry.backoff(tries: tries))
                    try? await store.markRetry(op, tries: tries, next: next)
                    blocked.insert(op.target)
                    result.wake = min(result.wake ?? next, next)
                    Telemetry.log(.warn, .sync, "outbox waiting", data: ["op": .string(op.opID), "tries": .int(tries)])
                }
            }
        }
        return result
    }
}
