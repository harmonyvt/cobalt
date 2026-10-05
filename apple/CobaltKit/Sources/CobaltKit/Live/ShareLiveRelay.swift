import Foundation

/// The share sheet's half of a Live Activity (CONTRACT-LIVE.md 2.5). An extension cannot start an
/// activity, so when the server can push it asks the server to push-start one for this run, then
/// relays the steps only the device performs (upload, read, ready, a device failure) while the
/// server pushes the rest. Plain `PipelineContext` and `CobaltClient` calls: no ActivityKit, so the
/// Mac test run covers all of it.
///
/// Answers it handles quietly (nothing here ever reaches the owner):
/// - `start_unconfirmed`: a start may already have gone out; it is never sent again.
/// - `start_rate_limited`: one push-to-start per key per 10 s; the start is tried again later.
/// - `429 error.live.too_many_runs`: no activity for this run; nothing retries it.
@MainActor
final class ShareLiveRelay: LiveSink {
    static let counterInterval: Double = 1
    /// Apple's window is 10 s per key; a little more.
    static let startRetryDelay: Double = 10.5
    static let maxStartRetries = 3
    static let registerBackoff: Double = 5
    /// How long closing the sheet waits for the server to hear that the run is over.
    static let closeWait: Double = 2

    private weak var ctx: PipelineContext?
    private weak var pipeline: Pipeline?
    private let environment: LiveEnvironment?
    private let queue = SerialQueue()

    private var built: LiveContentState?          // latest content from the pipeline (merge base)
    private var relayed: LiveContentState?        // the last device-owned content the server has
    private var relayedAt: Double = 0
    private var pending: LiveContentState?
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var attempted = false                 // a PUT may have reached the server
    private var registered = false                // a PUT was answered
    private var registeredSession: String?
    private var needsStart = true
    private var startNotBefore: Double = 0         // a rate-limited start waits out the key's window
    private var startRetries = 0
    private var backoffUntil: Double = 0
    private var disabled = false                  // 429: no activity for this run
    private var detached = false                  // the sheet let go (closed mid-render, handed off)

    init(context: PipelineContext, pipeline: Pipeline, environment: LiveEnvironment?) {
        self.ctx = context
        self.pipeline = pipeline
        self.environment = environment
    }

    private var now: Double { (ctx?.clock.now() ?? Date()).timeIntervalSince1970 }

    /// The server pushes, this build can receive pushes, and the extension can read the key.
    private var eligible: Bool {
        guard let ctx else { return false }
        return environment != nil && ctx.capabilities.livePush && ctx.settings.apiKey() != nil
    }

    /// The stages the device writes for a share-sheet run (2.1); the server pushes the others.
    static func deviceOwned(_ c: LiveContentState) -> Bool {
        switch c.stage {
        case .uploading, .reading, .ready, .failed: return true
        default: return false
        }
    }

    // MARK: - Sink

    func runBegan(_ p: Pipeline) {}

    func sessionChanged(_ p: Pipeline) {
        guard p === pipeline else { return }
        step()
    }

    func stateChanged(_ p: Pipeline) {
        guard p === pipeline, !detached, !disabled,
              let content = LiveContentState.make(from: p.state, p.liveSnapshot(previous: built, now: Date(timeIntervalSince1970: now)))
        else { return }
        built = content
        step()
    }

    /// Capabilities arrived (the sheet starts before it knows what the server can do).
    func kick() { step() }

    // MARK: - Registering

    private func step() {
        guard !detached, !disabled, eligible else { return }
        if !attempted {
            guard let c = built, !c.isTerminal else { return }     // no activity for a run that is already over
            scheduleRegister(force: false)
        } else {
            if registeredSession != pipeline?.sessionID, pipeline?.sessionID != nil { scheduleRegister(force: false) }
            relayIfNeeded(force: false)
        }
    }

    private func scheduleRegister(force: Bool) {
        guard !disabled, !detached, eligible, let env = environment, let client = ctx?.client else { return }
        if !force, now < backoffUntil { return }
        if !force, registered, registeredSession == pipeline?.sessionID { return }
        guard let p = pipeline else { return }
        attempted = true
        let attributes = p.liveAttributes(origin: "share")
        queue.enqueue { [weak self] in await self?.register(client, env, attributes, force: force) }
    }

    private func register(
        _ client: any CobaltClient, _ env: LiveEnvironment, _ attributes: LiveRunAttributes, force: Bool
    ) async {
        guard !disabled, !detached, let p = pipeline, let state = built else { return }
        if !force, registered, registeredSession == p.sessionID { return }
        if !registered, state.isTerminal { return }
        let session = p.sessionID
        let start = needsStart && !state.isTerminal && now >= startNotBefore
        let registration = LiveRunRegistration(
            run: p.liveRunID, environment: env, updateToken: nil, session: session, start: start,
            attributes: attributes, state: state)
        do {
            let reply = try await client.registerLiveRun(registration)
            registered = true
            registeredSession = session
            if Self.deviceOwned(state) { relayed = state; relayedAt = now }
            if start { startAnswered(reply) }
        } catch {
            // The outcome of a start is unknown after an error: never start twice (at worst this
            // run has no activity). The registration itself may be tried again, after a pause.
            needsStart = false
            if error.isTooManyLiveRuns {
                disabled = true
            } else {
                backoffUntil = now + Self.registerBackoff
            }
        }
        relayIfNeeded(force: true)
    }

    private func startAnswered(_ reply: LiveRunReply) {
        if reply.started { needsStart = false; return }
        switch reply.reason {
        case LiveReason.startRateLimited:
            // sent nothing: ask again once the key's 10 s window has passed
            guard startRetries < Self.maxStartRetries, let clock = ctx?.clock else { needsStart = false; return }
            startRetries += 1
            startNotBefore = now + Self.startRetryDelay
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await clock.sleep(seconds: Self.startRetryDelay)
                guard !Task.isCancelled, let self, !self.detached, !self.disabled,
                      let c = self.built, !c.isTerminal
                else { return }
                self.scheduleRegister(force: true)
            }
        default:
            // start_unconfirmed (never again), no_start_token, not_configured, or nothing to say
            needsStart = false
        }
    }

    // MARK: - Relaying device steps

    private func relayIfNeeded(force: Bool) {
        guard registered, !disabled, !detached, let c = built, Self.deviceOwned(c),
              let client = ctx?.client, let p = pipeline
        else { return }
        if c == relayed { pending = nil; return }
        let t = now
        if let old = relayed, !force, LiveActivityManager.onlyCounters(differ: old, c), t - relayedAt < Self.counterInterval {
            pending = c
            scheduleFlush()
            return
        }
        relayed = c
        relayedAt = t
        pending = nil
        flushTask?.cancel()                      // it counted from an older relay: a new window starts here
        flushTask = nil
        let run = p.liveRunID
        queue.enqueue { try? await client.relayLiveState(run: run, c) }   // 404/409 say nothing the owner needs
    }

    private func scheduleFlush() {
        guard flushTask == nil, let clock = ctx?.clock else { return }
        let wait = max(0.0, Self.counterInterval - (now - relayedAt))
        flushTask = Task { [weak self] in
            try? await clock.sleep(seconds: wait)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.relayIfNeeded(force: true)
        }
    }

    // MARK: - Leaving

    /// The sheet closed and nothing carries on (`.dismissed`): the server ends the run's activity.
    /// Waits briefly for the call: the extension is about to be torn down.
    func finish() async {
        stopTimers()
        detached = true
        guard attempted, !disabled, let client = ctx?.client, let run = pipeline?.liveRunID else { return }
        queue.enqueue { try? await client.endLiveRun(run) }
        await waitForQueue(timeout: Self.closeWait)
    }

    /// The run goes on without the sheet (closed mid-render, "trim in cobalt"): leave it alone.
    func detach() {
        stopTimers()
        detached = true
    }

    private func stopTimers() {
        flushTask?.cancel()
        flushTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    @MainActor
    private final class Gate {
        var done = false
        var timer: Task<Void, Never>?
    }

    private func waitForQueue(timeout seconds: Double) async {
        guard let clock = ctx?.clock else { await queue.drain(); return }
        let gate = Gate()
        let queue = queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let drained = Task { @MainActor in
                await queue.drain()
                gate.timer?.cancel()
                if !gate.done { gate.done = true; continuation.resume() }
            }
            gate.timer = Task { @MainActor in
                try? await clock.sleep(seconds: seconds)
                if !gate.done { gate.done = true; continuation.resume() }
                drained.cancel()
            }
        }
    }

    // MARK: - Tests

    func settle() async { await queue.drain() }
}
