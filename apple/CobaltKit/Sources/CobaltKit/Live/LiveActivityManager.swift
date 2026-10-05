import Foundation
import os
import Synchronization

/// Keeps a Live Activity per pipeline run (CONTRACT-LIVE.md 2.5). The only code that talks to
/// ActivityKit (through `LiveActivityAdapter`, so the Mac test run covers it) and the only code that
/// registers tokens and runs with the server for the app. It is the home pipeline's `LiveSink`.
///
/// One writer per step (2.1): in **push mode** (the server can push, this build has an
/// `aps-environment`, the activity has an update token, the last `PUT /live/runs/<run>` said
/// `pushing: true`) the server writes the steps it performs (fetch with a session, save, render) and
/// the app writes the device's (before a session, upload, read, ready) plus the final `end`; in
/// **local mode** the app writes every stage itself.
@MainActor
final class LiveActivityManager: LiveSink {
    // MARK: tunables (the contract's numbers)

    static let counterInterval: Double = 1
    static let staleSeconds: Double = 120
    static let readyStaleSeconds: Double = 30 * 60
    static let doneDismissSeconds: Double = 15 * 60
    static let failedDismissSeconds: Double = 5 * 60

    // MARK: state

    /// One pipeline run's activity and what the app knows about it on the server.
    final class Run {
        let id: UUID
        var attributes: LiveRunAttributes
        var handle: (any LiveActivityHandle)?
        var activityTried = false
        var built: LiveContentState?          // the latest content the pipeline produced (the merge base)
        var sent: LiveContentState?           // the last content written to the activity
        var sentAt: Double = 0
        var pending: LiveContentState?        // held back by the 1 per second rule
        var flushTask: Task<Void, Never>?
        var tokenTask: Task<Void, Never>?
        var updateToken: String?
        var session: String?
        var registerAttempted = false         // the server may know this run (a DELETE is worth sending)
        var registeredToken: String?
        var registeredSession: String?
        var pushing = false                   // the last reply
        var disabled = false                  // 429: the server will not take this run
        var ended = false                     // the run settled (terminal content written, or none to write)

        init(id: UUID, attributes: LiveRunAttributes) {
            self.id = id
            self.attributes = attributes
        }

        var idString: String { id.uuidString.lowercased() }
    }

    /// An activity the server push-started (a share-sheet run) that this process watches.
    private struct Adopted {
        var task: Task<Void, Never>
        var token: String?
        var registeredToken: String?
    }

    /// A run the owner closed with `Pipeline.detach()` while work was in flight: its activity lives
    /// on, written from the hidden pipeline that finishes the work.
    private final class DetachedRun {
        let run: Run
        weak var pipeline: Pipeline?
        init(run: Run, pipeline: Pipeline) {
            self.run = run
            self.pipeline = pipeline
        }
    }

    private let adapter: any LiveActivityAdapter
    private let environment: LiveEnvironment?
    private let grace: any BackgroundGrace
    private weak var ctx: PipelineContext?
    private weak var pipeline: Pipeline?
    private let writes = SerialQueue()          // ActivityKit calls, in order
    private let network = SerialQueue()         // registrations and run ends (a start may take 30 s: never behind a write)
    private var run: Run?
    private var detached: [ObjectIdentifier: DetachedRun] = [:]
    private var adopted: [String: Adopted] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var observers: [any NSObjectProtocol] = []
    private var latestStartToken: String?
    private var sentStartSignature: String?
    private var inBackground = false

    private static let log = Logger(subsystem: "com.capybaraharmony.cobalt", category: "live")

    init(
        context: PipelineContext, adapter: any LiveActivityAdapter, environment: LiveEnvironment?,
        grace: any BackgroundGrace = SystemBackgroundGrace()
    ) {
        self.ctx = context
        self.adapter = adapter
        self.environment = environment
        self.grace = grace
    }

    // MARK: - Launch

    /// First thing at launch: the push-to-start token observer starts before anything else (a known
    /// iOS bug loses the token when the observer starts late; starting any local activity makes the
    /// system issue it again), then the activities the server started.
    func start(observeLifecycle: Bool = true) {
        tasks.append(Task { [weak self] in
            guard let stream = self?.adapter.startTokens() else { return }
            for await token in stream {
                guard let self else { return }
                self.startTokenArrived(token)
            }
        })
        if let t = adapter.currentStartToken { startTokenArrived(t) }
        tasks.append(Task { [weak self] in
            guard let stream = self?.adapter.newActivities() else { return }
            for await handle in stream {
                guard let self else { return }
                self.adoptIfWanted(handle)
            }
        })
        if observeLifecycle {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.didEnterBackground() } })
            observers.append(center.addObserver(
                forName: Notification.Name("UIApplicationWillEnterForegroundNotification"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.foreground() } })
        }
        reconcile()
    }

    /// On every foreground: the start token as the system has it now, activities the server started,
    /// activities nobody follows.
    func foreground() {
        inBackground = false
        grace.end()
        if let t = adapter.currentStartToken { startTokenArrived(t) } else { flushStartToken() }
        reconcile()
    }

    func didEnterBackground() {
        inBackground = true
        updateGrace()
    }

    /// Capabilities were (re)read: the server may now take tokens and runs.
    func capabilitiesChanged() {
        flushStartToken()
        if let r = run {
            if r.handle == nil, let p = pipeline, p.liveRunID == r.id {
                ensureActivity(r, p)
                if let c = r.built { publish(r, c, p) }
            }
            scheduleRegister(r)
        }
        for d in detached.values {
            let r = d.run
            guard let p = d.pipeline, !r.ended else { continue }
            if r.handle == nil {
                ensureActivity(r, p)
                if let c = r.built { publish(r, c, p) }
            }
            scheduleRegister(r)
        }
        for id in adopted.keys { registerAdopted(id) }
    }

    // MARK: - Environment

    private var now: Date { ctx?.clock.now() ?? Date() }
    private var pushAvailable: Bool { environment != nil && (ctx?.capabilities.livePush ?? false) }

    private func isPushMode(_ r: Run) -> Bool { pushAvailable && r.updateToken != nil && r.pushing }

    /// The steps the server writes in push mode (2.1).
    private func serverOwns(_ c: LiveContentState, session: String?) -> Bool {
        switch c.stage {
        case .saving, .rendering: return true
        case .fetching: return session != nil
        default: return false
        }
    }

    // MARK: - Tokens

    private func startTokenArrived(_ token: String) {
        latestStartToken = token
        flushStartToken()
    }

    /// Registers the push-to-start token once per server, key and token (dropped for retry when the
    /// call failed). Needs a server that pushes, a build that can, and a key.
    private func flushStartToken() {
        guard let token = latestStartToken, pushAvailable, let ctx, let env = environment,
              let key = ctx.settings.apiKey()
        else { return }
        let client = ctx.client
        let signature = "\(client.baseURL.absoluteString)|\(key)|\(token)"
        guard signature != sentStartSignature else { return }
        sentStartSignature = signature
        network.enqueue { [weak self] in
            do { try await client.registerLiveStartToken(token, environment: env) }
            catch {
                Telemetry.log(.warn, .live, "start token not registered", data: Telemetry.errorData(error))
                if self?.sentStartSignature == signature { self?.sentStartSignature = nil }   // next foreground tries again
            }
        }
    }

    // MARK: - Pipeline events (the sink)

    func runBegan(_ p: Pipeline) {
        pipeline = p
        if let r = run { finish(r) }
    }

    func sessionChanged(_ p: Pipeline) {
        if let d = detached[ObjectIdentifier(p)] {
            guard let sid = p.sessionID else { return }
            d.run.session = sid
            scheduleRegister(d.run)
            return
        }
        pipeline = p
        guard let r = run, r.id == p.liveRunID, let sid = p.sessionID else { return }
        r.session = sid
        scheduleRegister(r)
    }

    func stateChanged(_ p: Pipeline) {
        if let d = detached[ObjectIdentifier(p)] {
            detachedStateChanged(d.run, p)
            return
        }
        pipeline = p
        let state = p.state
        if case .idle = state {
            if let r = run { finish(r) }
            return
        }
        if let r = run, r.id != p.liveRunID { finish(r) }
        if let r = run, r.ended, !state.isLiveTerminal {
            // the owner carried on past a finished run (back to the trim, a retry): the old
            // activity keeps its dismissal time, what follows is a new run
            finish(r)
            p.renewRun()
        }
        if let r = run, r.ended { return }              // a second terminal state changes nothing

        if run == nil {
            let r = Run(id: p.liveRunID, attributes: p.liveAttributes(origin: Self.origin(of: p)))
            r.session = p.sessionID
            run = r
            if case .failed = state {
                // the very first thing is a failure (no link, a file the server will not take): a
                // flash on the island would say nothing the screen does not
                r.ended = true
                return
            }
        }
        guard let r = run, let content = LiveContentState.make(from: state, p.liveSnapshot(previous: run?.built, now: now))
        else { return }
        r.built = content
        r.session = p.sessionID ?? r.session
        ensureActivity(r, p)
        publish(r, content, p)
        updateGrace()
    }

    // MARK: - Detached runs

    /// The owner closed the run on screen, work still in flight: its activity (and the server's
    /// record of it) stay with the run, which the hidden `background` pipeline now reports.
    func runDetached(from old: Pipeline, to background: Pipeline) {
        let r: Run
        if let current = run, current.id == old.liveRunID {
            run = nil
            r = current
        } else {
            r = Run(id: old.liveRunID, attributes: old.liveAttributes(origin: Self.origin(of: old)))
            r.session = old.sessionID
        }
        detached[ObjectIdentifier(background)] = DetachedRun(run: r, pipeline: background)
        if pipeline === old { pipeline = nil }
        updateGrace()
    }

    private func detachedStateChanged(_ r: Run, _ p: Pipeline) {
        if r.ended { return }                           // a second terminal state changes nothing
        guard let content = LiveContentState.make(from: p.state, p.liveSnapshot(previous: r.built, now: now)) else { return }
        r.built = content
        r.session = p.sessionID ?? r.session
        ensureActivity(r, p)
        publish(r, content, p)
    }

    /// The detached run has nothing left in flight.
    func detachedSettled(_ background: Pipeline) {
        guard let d = detached.removeValue(forKey: ObjectIdentifier(background)) else { return }
        finish(d.run)
    }

    private func isDetached(_ id: String) -> Bool {
        detached.values.contains { $0.run.idString == id }
    }

    /// The run (visible or detached) that carries activity `id`.
    private func runCarrying(_ id: String) -> Run? {
        if let r = run, r.idString == id { return r }
        return detached.values.first { $0.run.idString == id }?.run
    }

    /// An activity for a run that already has one (the server's push-start landed after the app
    /// requested its own): exactly one stays. The newcomer goes at once; ours keeps the run.
    /// True when `handle` was such a duplicate.
    private func endIfDuplicate(_ handle: any LiveActivityHandle) -> Bool {
        guard let r = runCarrying(handle.attributes.run), let mine = r.handle,
              mine.activityID != handle.activityID, !handle.isEnded
        else { return false }
        adopted[handle.attributes.run]?.task.cancel()
        adopted[handle.attributes.run] = nil
        writes.enqueue { await handle.end(handle.state, dismissAt: nil) }
        return true
    }

    // MARK: - The activity

    /// Requests the activity (or takes the one that already carries this run: a share-sheet run the
    /// owner opens in the app, or this app's own run after a relaunch).
    private func ensureActivity(_ r: Run, _ p: Pipeline) {
        guard r.handle == nil, !r.activityTried, let ctx, let content = r.built else { return }
        // Capabilities are unknown only until the run's first request has gone out (a cold launch
        // pasting at once): a moment later `capabilitiesChanged()` creates it, with the right push type.
        if ctx.capabilities.kind == .unreachable, case .fetching = p.state { return }
        r.activityTried = true
        guard adapter.isAvailable else { return }
        let id = r.idString
        if let existing = adapter.activities.first(where: { $0.attributes.run == id && !$0.isEnded }) {
            r.handle = existing
            r.attributes = existing.attributes
            r.sent = existing.state
            r.sentAt = now.timeIntervalSince1970
            adopted[id]?.task.cancel()
            adopted[id] = nil
        } else {
            do {
                let stale = now.addingTimeInterval(Self.staleWindow(for: content))
                r.handle = try adapter.request(r.attributes, state: content, staleDate: stale, push: pushAvailable)
                r.sent = content
                r.sentAt = now.timeIntervalSince1970
                Telemetry.log(.info, .live, "live activity started", data: ["run": .string(String(id.prefix(8))), "push": .bool(pushAvailable)])
            } catch {
                Telemetry.log(.error, .live, "live activity request failed", data: Telemetry.errorData(error))
                Self.log.notice("activity request failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        if let handle = r.handle {
            r.tokenTask = Task { [weak self] in
                for await token in handle.pushTokens() {
                    guard let self else { return }
                    self.tokenArrived(r, token)
                }
            }
        }
    }

    /// A share-sheet run the app took over keeps the share origin, so a tap on its activity opens that
    /// run (`cobalt-apple://job/<run>`, CONTRACT-SHARE-QUICK.md section 4); the app's own runs open cobalt.
    static func origin(of p: Pipeline) -> String {
        p.origin == .shareExtension ? "share" : "app"
    }

    private static func staleWindow(for c: LiveContentState) -> Double {
        c.stage == .ready ? readyStaleSeconds : staleSeconds
    }

    private func publish(_ r: Run, _ content: LiveContentState, _ p: Pipeline) {
        if content.isTerminal {
            end(r, content)
            return
        }
        guard r.handle != nil, !r.ended else { return }
        if isPushMode(r), serverOwns(content, session: p.sessionID) { return }
        write(r, content)
    }

    /// At most one write per second while only counters change, at once on anything else.
    private func write(_ r: Run, _ content: LiveContentState, force: Bool = false) {
        guard r.handle != nil, !r.ended else { return }
        if content == r.sent {
            r.pending = nil
            return
        }
        let t = now.timeIntervalSince1970
        if let old = r.sent, !force, Self.onlyCounters(differ: old, content), t - r.sentAt < Self.counterInterval {
            r.pending = content
            scheduleFlush(r)
            return
        }
        send(r, content)
    }

    private func send(_ r: Run, _ content: LiveContentState) {
        guard let handle = r.handle else { return }
        r.sent = content
        r.sentAt = now.timeIntervalSince1970
        r.pending = nil
        r.flushTask?.cancel()                    // it counted from an older write: a new window starts here
        r.flushTask = nil
        let stale = now.addingTimeInterval(Self.staleWindow(for: content))
        writes.enqueue { await handle.update(content, staleDate: stale) }
    }

    /// `new` is `old` with other counters (the case the 1 per second rule is about).
    static func onlyCounters(differ old: LiveContentState, _ new: LiveContentState) -> Bool {
        var probe = new
        probe.bytes = old.bytes
        probe.total = old.total
        probe.framesDone = old.framesDone
        probe.framesTotal = old.framesTotal
        return probe == old
    }

    private func scheduleFlush(_ r: Run) {
        guard r.flushTask == nil, let clock = ctx?.clock else { return }
        let wait = max(0.0, Self.counterInterval - (now.timeIntervalSince1970 - r.sentAt))
        r.flushTask = Task { [weak self, weak r] in
            try? await clock.sleep(seconds: wait)
            guard !Task.isCancelled, let self, let r else { return }
            r.flushTask = nil
            if let held = r.pending, !r.ended { self.write(r, held, force: true) }
        }
    }

    private func end(_ r: Run, _ content: LiveContentState) {
        r.ended = true
        r.flushTask?.cancel()
        r.flushTask = nil
        r.pending = nil
        updateGrace()
        guard let handle = r.handle else { return }       // never shown: nothing to end
        Telemetry.log(.info, .live, "live activity ended", data: ["run": .string(String(r.idString.prefix(8))), "stage": .string(String(describing: content.stage))])
        r.sent = content
        let dismiss = now.addingTimeInterval(content.stage == .failed ? Self.failedDismissSeconds : Self.doneDismissSeconds)
        writes.enqueue { await handle.end(content, dismissAt: dismiss) }
    }

    /// A new run began, or the pipeline went `.idle`: an unfinished activity goes at once, a
    /// finished one keeps its dismissal time; the server forgets the run either way.
    private func finish(_ r: Run) {
        r.flushTask?.cancel()
        r.tokenTask?.cancel()
        if let handle = r.handle, !r.ended, let last = r.sent ?? r.built {
            writes.enqueue { await handle.end(last, dismissAt: nil) }
        }
        r.ended = true
        if r.registerAttempted, let client = ctx?.client {
            let id = r.id
            network.enqueue { try? await client.endLiveRun(id) }
        }
        if run === r { run = nil }
        updateGrace()
    }

    // MARK: - Registering with the server

    private func tokenArrived(_ r: Run, _ token: String) {
        guard !r.ended else { return }
        r.updateToken = token
        scheduleRegister(r)
    }

    private func scheduleRegister(_ r: Run) {
        guard pushAvailable, !r.disabled, !r.ended, let token = r.updateToken, let client = ctx?.client else { return }
        if r.registeredToken == token, r.registeredSession == r.session { return }
        r.registerAttempted = true
        network.enqueue { [weak self] in await self?.register(r, client) }
    }

    private func register(_ r: Run, _ client: any CobaltClient) async {
        guard let env = environment, let token = r.updateToken, !r.disabled, !r.ended,
              let state = r.built ?? r.sent
        else { return }
        if r.registeredToken == token, r.registeredSession == r.session { return }     // an earlier call covered it
        let session = r.session
        let registration = LiveRunRegistration(
            run: r.id, environment: env, updateToken: token, session: session, start: false,
            attributes: r.attributes, state: state)
        do {
            let reply = try await client.registerLiveRun(registration)
            r.registeredToken = token
            r.registeredSession = session
            r.pushing = reply.pushing
        } catch {
            // No push for this run: it carries on in local mode, quietly. A 429 (too many runs)
            // is final for the run; anything else may be tried again by the next token or session.
            Telemetry.log(.warn, .live, "live run not registered", data: Telemetry.errorData(error))
            r.pushing = false
            if error.isTooManyLiveRuns { r.disabled = true }
        }
        if !r.pushing, !r.ended, let latest = r.built { write(r, latest, force: true) }       // local mode writes everything
    }

    // MARK: - Activities the server started, orphans

    private func adoptIfWanted(_ handle: any LiveActivityHandle) {
        let id = handle.attributes.run
        if endIfDuplicate(handle) { return }
        guard !handle.isEnded, run?.idString != id, !isDetached(id), adopted[id] == nil else { return }
        adopted[id] = Adopted(task: Task { [weak self] in
            for await token in handle.pushTokens() {
                guard let self else { return }
                self.adoptedToken(id, token)
            }
        })
    }

    private func adoptedToken(_ id: String, _ token: String) {
        adopted[id]?.token = token
        registerAdopted(id)
    }

    /// A push-started activity: its update token goes to the server so it can write the run.
    private func registerAdopted(_ id: String) {
        guard var entry = adopted[id], let token = entry.token, entry.registeredToken != token,
              pushAvailable, let ctx, let env = environment,
              let handle = adapter.activities.first(where: { $0.attributes.run == id && !$0.isEnded })
        else { return }
        let attributes = handle.attributes
        guard let runID = UUID(uuidString: attributes.run) else { return }
        entry.registeredToken = token
        adopted[id] = entry
        let session = ctx.jobs.all().first { $0.id == runID }?.sessionID
        let registration = LiveRunRegistration(
            run: runID, environment: env, updateToken: token, session: session, start: false,
            attributes: attributes, state: handle.state)
        let client = ctx.client
        network.enqueue { [weak self] in
            do { _ = try await client.registerLiveRun(registration) }
            catch { self?.adopted[id]?.registeredToken = nil }
        }
    }

    /// Foreground and launch: pick up what the server started, end what nobody follows (a run that
    /// is neither the home pipeline's nor a `SharedJob` with work left, and not being written to).
    func reconcile() {
        guard let ctx else { return }
        let t = ctx.clock.now()
        let known = Set(ctx.jobs.all().compactMap { job -> String? in
            switch job.stage {
            case .saving, .rendering, .ready: return job.id.uuidString.lowercased()
            default: return nil
            }
        })
        let live = adapter.activities
        for handle in live where !handle.isEnded {
            let id = handle.attributes.run
            if runCarrying(id) != nil {
                _ = endIfDuplicate(handle)
                continue
            }
            if known.contains(id) || handle.isFresh(at: t) {
                adoptIfWanted(handle)
            } else {
                adopted[id]?.task.cancel()
                adopted[id] = nil
                writes.enqueue { await handle.end(handle.state, dismissAt: nil) }
            }
        }
        let alive = Set(live.filter { !$0.isEnded }.map { $0.attributes.run })
        for id in adopted.keys where !alive.contains(id) {
            adopted[id]?.task.cancel()
            adopted[id] = nil
        }
    }

    // MARK: - Background time (local mode)

    /// Local mode needs the app running to write anything: while a run has work in flight and the app
    /// is in the background, ask the system for the few seconds it allows, so polling and updates
    /// carry on; after that the activity shows its stale state.
    private func updateGrace() {
        guard inBackground, let r = run, !r.ended, r.handle != nil, !isPushMode(r), let p = pipeline else {
            grace.end()
            return
        }
        switch p.state {
        case .fetching, .uploading, .saving, .reading, .rendering: grace.begin()
        default: grace.end()
        }
    }

    // MARK: - Tests

    /// Everything queued so far has run.
    func settle() async {
        await writes.drain()
        await network.drain()
        await writes.drain()
    }

    var currentRun: Run? { run }
}

// MARK: - Background grace

@MainActor
protocol BackgroundGrace: AnyObject {
    func begin()
    func end()
}

/// `ProcessInfo.performExpiringActivity`, the extension-safe cousin of `beginBackgroundTask`
/// (CobaltKit also builds into extensions, where `UIApplication.shared` does not exist).
@MainActor
final class SystemBackgroundGrace: BackgroundGrace {
    private let gate = Mutex<DispatchSemaphore?>(nil)

    func begin() {
        let semaphore = DispatchSemaphore(value: 0)
        let started = gate.withLock { slot -> Bool in
            guard slot == nil else { return false }
            slot = semaphore
            return true
        }
        guard started else { return }
        #if os(iOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "cobalt live activity") { expired in
            // The first call holds the process up until `end()` or the system's deadline (the second
            // call, `expired`).
            if expired { semaphore.signal() } else { semaphore.wait() }
        }
        #endif
    }

    func end() {
        let semaphore = gate.withLock { slot -> DispatchSemaphore? in
            defer { slot = nil }
            return slot
        }
        semaphore?.signal()
    }
}
