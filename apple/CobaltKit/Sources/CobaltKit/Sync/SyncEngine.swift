import Foundation

/// What one pass did, for the library glow. The engine still sends, rolls back and pulls exactly as before.
enum SyncActivity: Sendable, Equatable {
    case passBegan
    case passEnded(pending: Int)
    case refused(pending: Int)
    case repull
    case fellBack
    /// The pull of this pass reached the server and was applied.
    case pulled
    /// The pass ended without a pull and the engine stays on. `offline`: nothing reached the server.
    case pullFailed(offline: Bool)
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
    private var onAcknowledged: (@Sendable (SyncOp, SyncReceipt) async -> Void)?
    private var onRefused: (@Sendable (SyncOp, String) async -> Void)?
    /// A pass ended without a pull and the copy on screen is not fresh. The error is the pull's own.
    private var onPullFailed: (@Sendable (any Error) async -> Void)?
    /// Reports what a pass did, for the library glow. Never changes what is sent or pulled.
    private var onActivity: (@Sendable (SyncActivity) async -> Void)?

    func setCallbacks(
        snapshot: @escaping @Sendable (SyncLibrarySnapshot) async -> Void,
        fallback: @escaping @Sendable () async -> Void,
        acknowledged: @escaping @Sendable (SyncOp, SyncReceipt) async -> Void,
        refused: @escaping @Sendable (SyncOp, String) async -> Void,
        pullFailed: (@Sendable (any Error) async -> Void)? = nil
    ) {
        onSnapshot = snapshot
        onFallback = fallback
        onAcknowledged = acknowledged
        onRefused = refused
        onPullFailed = pullFailed
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
        let drained = await OutboxDrainer.drain(store: store, sender: sender, now: clock()) { [weak self] in
            await self?.isCurrent(token) ?? false
        }
        if token != generation {
            await signal(.passEnded(pending: await pendingCount()))
            return
        }
        let pending = await pendingCount()
        for op in drained.refused {
            await onRefused?(op, drained.reasons[op.opID] ?? "")
            await signal(.refused(pending: pending))
        }
        for op in drained.settled { await onAcknowledged?(op, drained.receipts[op.opID] ?? .done) }
        await publish()
        schedule(drained.wake)
        do {
            try await pull(token: token)
        } catch SyncError.notDeployed {
            await fallBack()
        } catch SyncError.cursorTooOld {
            guard token == generation else {
                await signal(.passEnded(pending: await pendingCount()))
                return
            }
            await signal(.repull)
            try? await store.resetCursor()
            await publish()
            do {
                try await pull(token: token)
            } catch SyncError.notDeployed {
                await fallBack()
            } catch SyncError.cursorTooOld {
                // The reload from 0 was itself answered "too old". Reloading again would get the same
                // answer, so there is one reload per pass and no more: the half-filled copy is dropped
                // (it must not be shown as the library next launch) and today's pages are used instead.
                Telemetry.log(.warn, .sync, "sync restart refused", data: ["error": .string(SyncContract.cursorTooOld)])
                if token == generation {
                    try? await store.resetCursor()
                    await fallBack()
                }
            } catch {
                await pullFailed(error, token: token, restart: true)
            }
        } catch {
            await pullFailed(error, token: token, restart: false)
        }
        await signal(.passEnded(pending: await pendingCount()))
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation }

    /// `GET /sync` is not there on this server, or failed with nothing on the device to show: today's loading takes over for this launch.
    private func fallBack() async {
        fellBack = true
        await onFallback?()
        await signal(.fellBack)
    }

    /// The pass ends without a pull. Nothing schedules another one, so this must not pass silently.
    ///
    /// Offline, or a key the server will not take: today's pages would fail the same way, so the
    /// engine stays on, the library is told why (it shows the copy it has, if any, and the failure),
    /// and the next reconnect, foreground or pull-to-refresh tries again. Anything else (a 5xx, a page
    /// that does not decode) with no copy to show: today's pages are used for this launch, since they
    /// may well work where the sync route does not.
    private func pullFailed(_ error: any Error, token: Int, restart: Bool) async {
        guard token == generation else { return }
        Telemetry.log(.warn, .sync, restart ? "sync restart failed" : "sync pull failed", data: ["error": .string(String(describing: error))])
        let offline = Self.isUnreachable(error)
        if !offline, !Self.isAuth(error), !(await store.hasReadyMarker()) {
            await fallBack()
            return
        }
        await onPullFailed?(error)
        await signal(.pullFailed(offline: offline))
    }

    private static func isUnreachable(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let e = error as? CobaltError, case .network = e { return true }
        return false
    }

    private static func isAuth(_ error: any Error) -> Bool {
        guard let e = error as? CobaltError else { return false }
        switch e {
        case .noAPIKey: return true
        case .api(_, let status), .invalidResponse(let status): return status == 401 || status == 403
        default: return false
        }
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
            if !page.more || page.seq <= since { break }
            since = page.seq
        }
        await signal(.pulled)
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
    /// The ops behind `acknowledged`, in the same order, as they were sent.
    var settled: [SyncOp] = []
    /// What the server said about an acknowledged op, by op id, where it said more than "done".
    var receipts: [String: SyncReceipt] = [:]
    /// Why each refused op was refused, by op id (an error code where the server gave one).
    var reasons: [String: String] = [:]
}

/// The life of one outbox row: send it, and only a refusal puts the post back.
enum OutboxDrainer {
    static let expiredReason = "error.app.expired"

    /// The date the oldest not-ready op becomes ready, when one is waiting.
    ///
    /// `isCurrent` is asked before each send and before anything is written after one: false means
    /// the server or the account changed while this drain ran, so what is left of the list belonged
    /// to the other library and is neither sent nor put back.
    static func drain(
        store: SyncStore, sender: any SyncSender, now: Date, isCurrent: @Sendable () async -> Bool = { true }
    ) async -> OutboxDrain {
        var result = OutboxDrain()
        let ops: [SyncOp]
        do { ops = try await store.pendingOps() } catch { return result }
        let fresh = ops.filter { now.timeIntervalSince($0.createdAt) < MutationRetry.retention }
        for expired in ops where now.timeIntervalSince(expired.createdAt) >= MutationRetry.retention {
            // Given up after a week. The server never took it, so the post goes back to what it was
            // and the owner is told, exactly as for a refusal: left alone, the device would keep
            // showing an edit (or a delete) that exists nowhere else.
            _ = try? await store.rollback(expired)
            result.refused.append(expired)
            result.reasons[expired.opID] = expiredReason
            Telemetry.log(.info, .sync, "outbox dropped", data: ["op": .string(expired.opID), "kind": .string(expired.kind.rawValue)])
        }
        var blocked: Set<String> = []
        for listed in fresh {
            if blocked.contains(listed.target) { continue }
            if listed.nextAttemptAt > now {
                blocked.insert(listed.target)
                result.wake = min(result.wake ?? listed.nextAttemptAt, listed.nextAttemptAt)
                continue
            }
            guard await isCurrent() else { break }
            // The op as the store holds it now, marked as sending. An edit made since the list was
            // read may have been merged into it; from here on none is.
            guard let op = try? await store.beginSend(listed.opID) else { continue }
            do {
                let receipt = try await sender.send(op)
                guard await isCurrent() else { break }
                try await store.settle(op, post: receipt.post)
                result.acknowledged.append(op.opID)
                result.settled.append(op)
                if receipt != .done { result.receipts[op.opID] = receipt }
            } catch {
                guard await isCurrent() else { break }
                let outcome = MutationRetry.attempt(error, kind: op.kind)
                switch outcome {
                case .succeeded:
                    try? await store.removeOp(op.opID)
                    result.acknowledged.append(op.opID)
                    result.settled.append(op)
                case .refused:
                    _ = try? await store.rollback(op)
                    result.refused.append(op)
                    let reason = (error as? SyncError).flatMap { if case .refused(let why) = $0 { return why } else { return nil } } ?? String(describing: error)
                    result.reasons[op.opID] = reason
                    Telemetry.log(.warn, .sync, "outbox refused", data: ["op": .string(op.opID), "kind": .string(op.kind.rawValue), "error": .string(reason)])
                case .retry, .rekey:
                    let tries = op.tries + 1
                    let next = now.addingTimeInterval(MutationRetry.backoff(tries: tries))
                    if outcome == .rekey {
                        // the server holds another body under this key: the same wait, then a new key
                        try? await store.rekey(op, tries: tries, next: next)
                    } else {
                        try? await store.markRetry(op, tries: tries, next: next)
                    }
                    blocked.insert(op.target)
                    result.wake = min(result.wake ?? next, next)
                    Telemetry.log(.warn, .sync, "outbox waiting", data: ["op": .string(op.opID), "tries": .int(tries)])
                }
            }
        }
        return result
    }
}
