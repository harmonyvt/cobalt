import Foundation

// The notify bridge from the app's side (APP-API-CONTRACT section 9). A build signed with a
// third-party certificate gets no APNs pushes, so when work will carry on without the screen the
// app asks the server to say so itself (through Hark) the moment a save or render finishes. The
// server finishes unpolled (`finishes_unpolled`); the opt-in only decides who gets told.

/// What the opt-ins this process made are for, so the foreground can take back the ones that only
/// covered "the app is in the background" and leave the ones that stand for a closed run.
enum NotifySource: Sendable, Equatable {
    case shareSheet      // the sheet closed with work left; the extension is gone, only the server can say
    case detached        // the owner closed a run mid-work (`Pipeline.detach()`)
    case background      // the app left the screen with a run in flight
}

/// The opt-ins this process made, kept so that the LAST intent for a session wins.
///
/// Every call is an intent recorded synchronously, at the call, and a network call queued behind
/// the session's earlier ones: `registered` says what the owner last asked for (not what the server
/// has been told yet), and calls for one session run one at a time, in the order they were made. So
/// a PUT still on the wire when the owner comes back is followed by its DELETE (never overtaken by
/// it, never missed by a lookup that ran before the PUT had answered), and a PUT queued behind a
/// newer intent is dropped unsent.
@MainActor
final class NotifyBridge {
    /// Session id to the source that registered it: the opt-ins this process holds or is sending.
    private(set) var registered: [String: NotifySource] = [:]
    /// Calls made on the wire, newest last ("PUT sid" / "DELETE sid"), kept for tests.
    private(set) var log: [String] = []

    /// How long a close may wait for the server's answer: the extension is torn down right after.
    static let closeTimeout: Double = 8

    /// The newest intent's number per session; an operation whose number is older is stale.
    private var intent: [String: Int] = [:]
    private var counter = 0
    /// The end of each session's chain of calls (the chain is what serializes them).
    private var tails: [String: (token: Int, task: Task<Void, Never>)] = [:]
    /// Sessions a PUT was sent for and no DELETE has answered since: where the server may hold an opt-in.
    private var maybeHeld: Set<String> = []
    /// Registered sessions whose last PUT got no answer (a timeout, a dropped connection, a 5xx): the
    /// server may or may not have stored it, so the intent stays (a cancel sends the DELETE, which is
    /// idempotent) but nothing counts it as told (`isRegistered`), and a later register tries again.
    /// Only a definite rejection (a 4xx answer, no key) clears the intent.
    private var uncertain: Set<String> = []

    private enum Answer: Equatable { case stored, rejected, unknown }

    /// Records the intent and queues the PUT. The Bool is false when the call failed (the caller falls
    /// back to a local notification), ran past `timeout`, or was overtaken by a `cancel`. Never throws:
    /// no caller can do anything with the reason.
    @discardableResult
    func enqueueRegister(
        session id: String, _ optIn: NotifyOptIn, source: NotifySource,
        client: any CobaltClient, clock: any PipelineClock, timeout: Double = NotifyBridge.closeTimeout
    ) -> Task<Bool, Never> {
        let mine = nextIntent(id)
        registered[id] = source
        uncertain.remove(id)
        return serialize(id) { [self] in
            // a newer register took over (it sends the PUT); a cancel took it back (nothing to send)
            guard intent[id] == mine else { return registered[id] != nil }
            log.append("PUT \(id)")
            let wasHeld = maybeHeld.contains(id)
            maybeHeld.insert(id)
            let answer = await Self.race(timeout: timeout, clock: clock) {
                do { try await client.setNotify(session: id, optIn); return .stored } catch { return Self.answer(for: error) }
            }
            switch answer {
            case .stored: break
            case .rejected:
                if !wasHeld { maybeHeld.remove(id) }          // the server said no: nothing new to take back
                if intent[id] == mine { registered[id] = nil }
            case .unknown:
                if intent[id] == mine { uncertain.insert(id) }
            }
            return answer == .stored
        }
    }

    /// `enqueueRegister`, awaited.
    @discardableResult
    func register(
        session id: String, _ optIn: NotifyOptIn, source: NotifySource,
        client: any CobaltClient, clock: any PipelineClock, timeout: Double = NotifyBridge.closeTimeout
    ) async -> Bool {
        await enqueueRegister(session: id, optIn, source: source, client: client, clock: clock, timeout: timeout).value
    }

    /// Takes the opt-in back (the owner is looking, or the app told them itself): the intent now,
    /// the DELETE behind whatever is still in flight for the session. Best effort.
    @discardableResult
    func enqueueCancel(session id: String, client: any CobaltClient) -> Task<Void, Never> {
        guard registered[id] != nil else { return Task {} }
        registered[id] = nil
        uncertain.remove(id)
        let mine = nextIntent(id)
        return serialize(id) { [self] in
            // a newer register is coming (its PUT replaces whatever is there), or no PUT ever went out
            guard intent[id] == mine, maybeHeld.contains(id) else { return }
            log.append("DELETE \(id)")
            do {
                try await client.cancelNotify(session: id)
                maybeHeld.remove(id)
            } catch {}
        }
    }

    func cancel(session id: String, client: any CobaltClient) async {
        await enqueueCancel(session: id, client: client).value
    }

    /// Everything one source registered.
    func cancelAll(source: NotifySource, client: any CobaltClient) {
        for (id, s) in registered where s == source { enqueueCancel(session: id, client: client) }
    }

    /// The server has this opt-in, or is being sent it: nothing more to register.
    func isRegistered(_ id: String) -> Bool { registered[id] != nil && !uncertain.contains(id) }

    /// The server may hold an opt-in for this session (including one whose PUT got no answer): a
    /// cancel has something to do.
    func mightHold(_ id: String) -> Bool { registered[id] != nil }

    /// Returns once every call queued so far (and any queued meanwhile) has finished.
    func settled() async {
        while let tail = tails.values.first?.task { await tail.value }
    }

    private func nextIntent(_ id: String) -> Int {
        counter += 1
        intent[id] = counter
        return counter
    }

    /// Runs `work` after everything already queued for `id`, whatever those did.
    private func serialize<T: Sendable>(_ id: String, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tails[id]?.task
        counter += 1
        let token = counter
        let task = Task { @MainActor [self] in
            await previous?.value
            let result = await work()
            if tails[id]?.token == token { tails[id] = nil; intent[id] = nil }
            return result
        }
        tails[id] = (token, Task { _ = await task.value })
        return task
    }

    /// `body`'s answer, or false when `timeout` virtual/real seconds pass first (a `URLSession`
    /// timeout inside the extension is not something to wait on).
    private static func race(
        timeout: Double, clock: any PipelineClock, _ body: @escaping @Sendable () async -> Answer
    ) async -> Answer {
        await withTaskGroup(of: Answer.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await clock.sleep(seconds: timeout)
                return .unknown
            }
            let first = await group.next() ?? .unknown
            group.cancelAll()
            return first
        }
    }

    /// Whether a failed PUT is known not to have been stored. Only an answer says so: a 4xx from the
    /// server, or no key (nothing was sent). Anything else (a timeout, a transport error, a 5xx,
    /// cancellation) leaves it open.
    private nonisolated static func answer(for error: Error) -> Answer {
        switch error as? CobaltError {
        case .api(_, let status)?, .invalidResponse(let status)?:
            return (400..<500).contains(status) ? .rejected : .unknown
        case .noAPIKey?:
            return .rejected
        default:
            return .unknown
        }
    }
}

extension PipelineContext {
    /// Registers `optIn` for `session` through the bridge. False when the server has no bridge.
    @discardableResult
    func registerNotify(
        session id: String, _ optIn: NotifyOptIn, source: NotifySource,
        timeout: Double = NotifyBridge.closeTimeout
    ) async -> Bool {
        guard capabilities.notifyBridge else { return false }
        return await notify.register(session: id, optIn, source: source, client: client, clock: clock, timeout: timeout)
    }

    func cancelNotify(session id: String) async {
        await notify.cancel(session: id, client: client)
    }

    /// The same, without waiting: the intent is recorded now, in the order of the calls, and the
    /// network call follows behind the session's earlier ones.
    @discardableResult
    func queueNotify(
        session id: String, _ optIn: NotifyOptIn, source: NotifySource, timeout: Double = NotifyBridge.closeTimeout
    ) -> Task<Bool, Never>? {
        guard capabilities.notifyBridge else { return nil }
        return notify.enqueueRegister(session: id, optIn, source: source, client: client, clock: clock, timeout: timeout)
    }

    @discardableResult
    func queueCancelNotify(session id: String) -> Task<Void, Never> {
        notify.enqueueCancel(session: id, client: client)
    }
}

extension Pipeline {
    /// What the server still has to tell the owner about this run: a render in flight says
    /// "rendered", a save in flight says "saved"; anything else (reading frames, a trim waiting, a
    /// result already in) has nothing the server could announce. "failed" always rides along.
    var pendingNotifyEvents: [NotifyEvent]? {
        guard sessionID != nil else { return nil }
        switch state {
        case .rendering: return [.rendered, .failed]
        case .fetching, .saving: return [.saved, .failed]
        default: return nil
        }
    }

    /// The name the notification calls this work.
    var notifyLabel: String {
        if let name = media?.name, !name.isEmpty { return (name as NSString).deletingPathExtension }
        if case .link(let info) = input { return info.ref }
        return "cobalt"
    }

    /// The opt-in this run would register right now, nil when the server has nothing to announce.
    var notifyOptIn: NotifyOptIn? {
        pendingNotifyEvents.map { NotifyOptIn(on: $0, label: notifyLabel) }
    }
}
