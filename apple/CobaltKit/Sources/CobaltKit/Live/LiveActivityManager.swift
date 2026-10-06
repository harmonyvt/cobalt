import Foundation
import os
import Synchronization

/// Keeps the Live Activity of the app's runs (CONTRACT-LIVE.md 2.5, CONTRACT-PARALLEL.md section 6). The only code that
/// talks to ActivityKit (through `LiveActivityAdapter`, so the Mac test run covers it) and the only code that
/// registers tokens and runs with the server for the app. It is the app's `LiveSink` and, since the queue exists, its
/// `JobLiveSink`: every pipeline of every job reports here.
///
/// **One live job: one activity per run**, exactly as before. One writer per step (2.1): in **push mode** (the server
/// can push, this build has an `aps-environment`, the activity has an update token, the last `PUT /live/runs/<run>`
/// said `pushing: true`) the server writes the steps it performs (fetch with a session, save, render) and the app
/// writes the device's (before a session, upload, read, ready) plus the final `end`; in **local mode** the app writes
/// every stage itself.
///
/// **Two or more live jobs: one activity for the whole busy period** (section 6). The first job's activity is kept
/// (no second `Activity.request`, so neither ActivityKit's per-app limit nor the server's 16 open runs per key are
/// touched), the app writes it locally (at most once a second), and the server's registration of that run is deleted so
/// the server never pushes one run's content into it. It stays local until nothing is live any more, then ends with
/// "3 saved · 1 webp".
@MainActor
final class LiveActivityManager: JobLiveSink {
    // MARK: tunables (the contract's numbers)

    static let counterInterval: Double = 1
    /// The busy period's activity is written at most this often, in total (section 6).
    static let summaryInterval: Double = 1
    static let staleSeconds: Double = 120
    /// A busy period with nothing new to say (every job waits in a line) is written again this often, so the card is not
    /// marked stale ("waiting for cobalt…") while the app is alive and well.
    static let summaryKeepalive: Double = 60
    static let readyStaleSeconds: Double = 30 * 60
    static let doneDismissSeconds: Double = 15 * 60
    static let failedDismissSeconds: Double = 5 * 60

    // MARK: state

    /// One pipeline run's activity and what the app knows about it on the server.
    final class Run {
        let id: UUID
        var attributes: LiveRunAttributes
        /// The pipeline that reports this run (weak: a run outlives nothing).
        weak var pipeline: Pipeline?
        /// The run `Pipeline.detach()` handed to a hidden pipeline: it settles on its own (`detachedSettled`).
        var detached = false
        /// The run belongs to a busy period: it writes no activity of its own, the summary speaks for it.
        var folded = false
        /// Its activity ended on purpose while the job lives on (a busy period ended, an unfocused job was saved): only
        /// work beginning again makes a new run of it, a title change or a second "saved" does not.
        var retired = false
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
        let order: Int                        // creation order: the oldest activity is the one a busy period keeps

        init(id: UUID, attributes: LiveRunAttributes, order: Int) {
            self.id = id
            self.attributes = attributes
            self.order = order
        }

        var idString: String { id.uuidString.lowercased() }
    }

    /// One busy period's activity: what several jobs share (section 6). Independent of any run, so the run that
    /// lent its activity can settle or be stopped without ending it.
    final class Summary {
        var handle: (any LiveActivityHandle)?
        var attributes: LiveRunAttributes?
        var activityTried = false
        var sent: LiveContentState?
        var sentAt: Double = 0
        var pending: LiveContentState?
        var flushTask: Task<Void, Never>?
        var keepaliveTask: Task<Void, Never>?
        var members: [UUID: Member] = [:]
        var loggedJobs = -1
        var loggedWaiting = -1
        var ended = false
    }

    /// What one job did in the period (counted at its end: "3 saved · 1 webp").
    struct Member {
        var live = true
        /// The save landed in this period / the webp was made / it did not finish.
        var saved = false
        var webp = false
        var failed = false
        /// It was saved before the period began (a webp from a saved job): its save is not counted again.
        var priorSave = false
    }

    /// An activity the server push-started (a share-sheet run) that this process watches.
    private struct Adopted {
        var task: Task<Void, Never>
        var token: String?
        var registeredToken: String?
    }

    private let adapter: any LiveActivityAdapter
    private let environment: LiveEnvironment?
    private let grace: any BackgroundGrace
    private weak var ctx: PipelineContext?
    private weak var queue: JobQueue?
    private let writes = SerialQueue()          // ActivityKit calls, in order
    private let network = SerialQueue()         // registrations and run ends (a start may take 30 s: never behind a write)
    /// Every pipeline that reported a run, by identity (the visible ones and the hidden `detach()` ones alike).
    private var runs: [ObjectIdentifier: Run] = [:]
    private var runCounter = 0
    private var summary: Summary?
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
        for r in Array(runs.values) where !r.ended {
            guard let p = r.pipeline else { continue }
            if !r.folded, r.handle == nil, r.detached || p.liveRunID == r.id {
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

    private func isPushMode(_ r: Run) -> Bool { pushAvailable && r.updateToken != nil && r.pushing && !r.folded }

    /// The steps the server writes in push mode (2.1).
    private func serverOwns(_ c: LiveContentState, session: String?) -> Bool {
        switch c.stage {
        case .saving, .rendering: return true
        case .fetching: return session != nil
        default: return false
        }
    }

    /// The queue to read the busy period from: the one that told us, else the context's.
    private var jobQueue: JobQueue? { queue ?? ctx?.jobQueue }

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

    // MARK: - The queue (JobLiveSink)

    /// After every add, settle, focus change, cancel and line move.
    func jobsChanged(_ queue: JobQueue) {
        self.queue = queue
        syncPeriod(queue)
    }

    /// Where the busy period begins and ends, and which per-run activities have nothing left to say. Run before every
    /// pipeline event is handled, so a second live job never asks ActivityKit for an activity of its own.
    private func syncPeriod(_ queue: JobQueue) {
        pruneRuns()
        if summary == nil, queue.live.count >= 2 { beginPeriod(queue) }
        if summary != nil {
            refreshSummary()
        } else {
            retireIdleActivities(queue)
        }
    }

    private func pruneRuns() {
        for (key, r) in runs where r.pipeline == nil {
            finish(r)
            runs[key] = nil
        }
    }

    /// Per-run mode only. A saved video waiting for its trim, or a picker, keeps the island only while the owner is on
    /// that job and nothing else is going on: a job nobody has open cannot be trimmed, and another job's progress is
    /// what the island is for.
    private func retireIdleActivities(_ queue: JobQueue) {
        let anyLive = !queue.live.isEmpty
        for job in queue.jobs {
            guard let r = runs[ObjectIdentifier(job.pipeline)], !r.ended, !r.detached, r.handle != nil else { continue }
            if job.isLive || job.pipeline.state.isLiveTerminal { continue }
            if job.id != queue.focusedID || anyLive {
                finish(r)
                r.retired = true
            }
        }
    }

    // MARK: - Pipeline events (the sink)

    func runBegan(_ p: Pipeline) {
        let key = ObjectIdentifier(p)
        guard let r = runs[key] else { return }
        finish(r)
        runs[key] = nil
    }

    func sessionChanged(_ p: Pipeline) {
        guard let r = runs[ObjectIdentifier(p)] else { return }
        if r.detached {
            guard let sid = p.sessionID else { return }
            r.session = sid
            scheduleRegister(r)
            return
        }
        guard r.id == p.liveRunID, let sid = p.sessionID else { return }
        r.session = sid
        scheduleRegister(r)
    }

    func stateChanged(_ p: Pipeline) {
        let key = ObjectIdentifier(p)
        if let r = runs[key], r.detached {
            detachedStateChanged(r, p)
            return
        }
        if let queue = jobQueue { syncPeriod(queue) }
        let state = p.state
        if case .idle = state {
            if let r = runs[key] { finish(r) }
            runs[key] = nil
            return
        }
        var existing = runs[key]
        if let r = existing, r.id != p.liveRunID {
            finish(r)
            existing = nil
        }
        if let r = existing, r.ended {
            // A run whose activity ended on purpose says nothing more until work begins again (a title change on a
            // saved job is not a new run).
            if r.retired, !state.isLiveInFlight { return }
            if !state.isLiveTerminal {
                // the owner carried on past a finished run (back to the trim, a retry): the old
                // activity keeps its dismissal time, what follows is a new run
                finish(r)
                p.renewRun()
                existing = nil
            }
        }
        if let r = existing, r.ended { return }              // a second terminal state changes nothing

        let r: Run
        if let current = existing {
            r = current
        } else {
            runCounter += 1
            r = Run(id: p.liveRunID, attributes: p.liveAttributes(origin: Self.origin(of: p)), order: runCounter)
            r.pipeline = p
            r.session = p.sessionID
            r.folded = summary != nil
            runs[key] = r
            if case .failed = state {
                // the very first thing is a failure (no link, a file the server will not take): a
                // flash on the island would say nothing the screen does not
                r.ended = true
                return
            }
        }
        guard let content = LiveContentState.make(from: state, p.liveSnapshot(previous: r.built, now: now)) else { return }
        r.built = content
        r.session = p.sessionID ?? r.session
        if r.folded {
            refreshSummary()
        } else {
            ensureActivity(r, p)
            publish(r, content, p)
        }
        updateGrace()
    }

    // MARK: - Detached runs

    /// The owner closed the run on screen, work still in flight: its activity (and the server's
    /// record of it) stay with the run, which the hidden `background` pipeline now reports.
    func runDetached(from old: Pipeline, to background: Pipeline) {
        let oldKey = ObjectIdentifier(old)
        let r: Run
        if let current = runs[oldKey], current.id == old.liveRunID {
            runs[oldKey] = nil
            r = current
        } else {
            runCounter += 1
            r = Run(id: old.liveRunID, attributes: old.liveAttributes(origin: Self.origin(of: old)), order: runCounter)
            r.session = old.sessionID
            r.folded = summary != nil
        }
        r.detached = true
        r.pipeline = background
        runs[ObjectIdentifier(background)] = r
        updateGrace()
    }

    private func detachedStateChanged(_ r: Run, _ p: Pipeline) {
        if r.ended { return }                           // a second terminal state changes nothing
        guard let content = LiveContentState.make(from: p.state, p.liveSnapshot(previous: r.built, now: now)) else { return }
        r.built = content
        r.session = p.sessionID ?? r.session
        if r.folded { return }
        ensureActivity(r, p)
        publish(r, content, p)
    }

    /// The detached run has nothing left in flight.
    func detachedSettled(_ background: Pipeline) {
        guard let r = runs.removeValue(forKey: ObjectIdentifier(background)), r.detached else { return }
        finish(r)
    }

    private func isDetached(_ id: String) -> Bool {
        runs.values.contains { $0.detached && $0.idString == id }
    }

    /// A run (visible or detached) or the busy period's activity carries activity `id`.
    private func isCarried(_ id: String) -> Bool {
        if runs.values.contains(where: { $0.idString == id }) { return true }
        return summary?.attributes?.run == id
    }

    /// The handle that carries activity `id` for us: a run's own, or the busy period's.
    private func ownHandle(forRun id: String) -> (any LiveActivityHandle)? {
        if let r = runs.values.first(where: { $0.idString == id }), let h = r.handle { return h }
        if let s = summary, s.attributes?.run == id { return s.handle }
        return nil
    }

    /// An activity for a run that already has one (the server's push-start landed after the app
    /// requested its own): exactly one stays. The newcomer goes at once; ours keeps the run.
    /// True when `handle` was such a duplicate.
    private func endIfDuplicate(_ handle: any LiveActivityHandle) -> Bool {
        guard let mine = ownHandle(forRun: handle.attributes.run),
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
        guard r.handle == nil, !r.activityTried, !r.folded, let ctx, let content = r.built else { return }
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
        guard !r.folded else { return }
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
        if r.registerAttempted, !r.disabled, let client = ctx?.client {
            let id = r.id
            network.enqueue { try? await client.endLiveRun(id) }
        }
        updateGrace()
    }

    // MARK: - The busy period (CONTRACT-PARALLEL.md section 6)

    /// Two jobs are live: from here one activity speaks for all of them, until nothing is live.
    private func beginPeriod(_ queue: JobQueue) {
        let s = Summary()
        summary = s
        // The oldest unfinished activity of a run is kept; any other one goes at once (and its server run with it).
        let holders = runs.values.filter { $0.handle != nil && !$0.ended && !$0.detached }.sorted { $0.order < $1.order }
        if let first = holders.first, let handle = first.handle {
            first.tokenTask?.cancel()
            first.flushTask?.cancel()
            first.pending = nil
            if first.registerAttempted, !first.disabled {
                // The server knows this run, and deleting a run it has a token for ends its activity (APP-API-CONTRACT 8.2):
                // that activity cannot carry the summary. It goes now, and the summary asks for its own (the one
                // `Activity.request` this period makes in push mode; local mode never gets here).
                let last = first.sent ?? first.built ?? handle.state
                writes.enqueue { await handle.end(last, dismissAt: nil) }
            } else {
                s.handle = handle
                s.attributes = first.attributes
                s.sent = first.sent
                s.sentAt = first.sentAt
                s.activityTried = true
            }
            first.handle = nil
            endServerRun(first)
        }
        for other in holders.dropFirst() {
            other.tokenTask?.cancel()
            other.flushTask?.cancel()
            other.pending = nil
            if let handle = other.handle {
                let last = other.sent ?? other.built ?? handle.state
                writes.enqueue { await handle.end(last, dismissAt: nil) }
            }
            other.handle = nil
            endServerRun(other)
        }
        for r in runs.values where !r.ended && !r.detached {
            r.folded = true
            r.flushTask?.cancel()
            r.pending = nil
        }
        for job in queue.jobs where job.isLive {
            var m = Member()
            if case .rendering = job.pipeline.state { m.priorSave = true }
            s.members[job.id] = m
        }
        if s.handle != nil { scheduleKeepalive(s) }
        Self.log.notice("busy period began")
        updateGrace()
    }

    private func endServerRun(_ r: Run) {
        guard r.registerAttempted, !r.disabled, let client = ctx?.client else { return }
        let id = r.id
        network.enqueue { try? await client.endLiveRun(id) }
    }

    /// The summary, written from what the queue says now.
    private func refreshSummary() {
        guard let s = summary, !s.ended, let queue = jobQueue else { return }
        updateMembers(s, queue)
        let live = queue.live
        if live.isEmpty {
            endPeriod(s)
            return
        }
        // lead: the job running on the server, else this device's work, else (all in line) the newest; newest first
        guard let lead = live.enumerated().min(by: { ($0.element.pipeline.liveLeadRank, -$0.offset) < ($1.element.pipeline.liveLeadRank, -$1.offset) })?.element
        else { return }
        let p = lead.pipeline
        let leadRun = runs[ObjectIdentifier(p)]
        guard let built = LiveContentState.make(from: p.state, p.liveSnapshot(previous: leadRun?.built, now: now)) else { return }
        leadRun?.built = built
        let waiting = live.filter { $0.pipeline.line != nil }.count
        let content = LiveContentState.summary(lead: built, jobs: live.count, waiting: waiting)
        ensureSummaryActivity(s, content, lead: p)
        writeSummary(s, content)
        if s.loggedJobs != content.jobs || s.loggedWaiting != content.waiting {
            s.loggedJobs = content.jobs ?? 0
            s.loggedWaiting = content.waiting ?? 0
            Telemetry.logLiveSummary(jobs: s.loggedJobs, waiting: s.loggedWaiting, line: queue.lineMode)
        }
        updateGrace()
    }

    /// Keeps the members' outcomes: a save that landed, a webp made, a failure. A job that left the queue keeps what it
    /// had finished (the owner dismissed a card) and loses what it had not (cancelled, or a failure acknowledged).
    private func updateMembers(_ s: Summary, _ queue: JobQueue) {
        let present = Set(queue.jobs.map(\.id))
        for id in Array(s.members.keys) where !present.contains(id) {
            guard var m = s.members[id] else { continue }
            if m.saved || m.webp {
                m.live = false
                m.failed = false
                s.members[id] = m
            } else {
                s.members[id] = nil
            }
        }
        for job in queue.jobs {
            let state = job.pipeline.state
            var m = s.members[job.id]
            if m == nil, job.isLive {
                var joined = Member()
                if case .rendering = state { joined.priorSave = true }
                m = joined
            }
            guard var member = m else { continue }
            member.live = job.isLive
            switch state {
            case .failed:
                member.failed = true
            case .done:
                member.webp = true
                if !member.priorSave { member.saved = true }
                member.failed = false
            case .ready, .savedLocally, .image:
                if !member.priorSave { member.saved = true }
                member.failed = false
            default:
                if job.isLive { member.failed = false }
            }
            s.members[job.id] = member
        }
    }

    /// Nothing is live: the activity says what came out of the period and the period is over.
    private func endPeriod(_ s: Summary) {
        guard !s.ended else { return }
        s.ended = true
        s.flushTask?.cancel()
        s.flushTask = nil
        s.keepaliveTask?.cancel()
        s.keepaliveTask = nil
        s.pending = nil
        let saved = s.members.values.filter(\.saved).count
        let webps = s.members.values.filter(\.webp).count
        let failed = s.members.values.filter(\.failed).count
        let final = LiveContentState.finishedSummary(
            saved: saved, webps: webps, failed: failed, jobs: s.members.count, now: now.timeIntervalSince1970)
        for r in runs.values where r.folded && !r.detached {
            r.folded = false
            r.ended = true
            r.retired = true
        }
        summary = nil
        updateGrace()
        guard let handle = s.handle else { return }
        if let final {
            s.sent = final
            let dismiss = now.addingTimeInterval(final.stage == .failed ? Self.failedDismissSeconds : Self.doneDismissSeconds)
            Telemetry.log(.info, .live, "live summary ended", data: [
                "saved": .int(saved), "webps": .int(webps), "failed": .int(failed),
            ])
            writes.enqueue { await handle.end(final, dismissAt: dismiss) }
        } else {
            // every job was cancelled: nothing to say
            writes.enqueue { await handle.end(handle.state, dismissAt: nil) }
        }
    }

    /// The period's activity: the first run's, kept, or (no run had one, or the server was about to end it) the one
    /// request this period makes.
    private func ensureSummaryActivity(_ s: Summary, _ content: LiveContentState, lead: Pipeline) {
        guard s.handle == nil, !s.activityTried else { return }
        s.activityTried = true
        guard adapter.isAvailable else { return }
        // Its own run id: the server never hears of it (a push to it would overwrite the summary).
        let origin = lead.liveAttributes(origin: "app")
        let attributes = LiveRunAttributes(run: UUID(), input: origin.input, service: origin.service, ref: origin.ref, origin: "app")
        do {
            let stale = now.addingTimeInterval(Self.staleSeconds)
            s.handle = try adapter.request(attributes, state: content, staleDate: stale, push: false)
            s.attributes = attributes
            s.sent = content
            s.sentAt = now.timeIntervalSince1970
            scheduleKeepalive(s)
            Telemetry.log(.info, .live, "live activity started", data: ["run": .string(String(attributes.run.prefix(8))), "push": false, "summary": true])
        } catch {
            Telemetry.log(.error, .live, "live activity request failed", data: Telemetry.errorData(error))
            Self.log.notice("summary activity request failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// At most one write per second in total, the latest content held back until the window passes.
    private func writeSummary(_ s: Summary, _ content: LiveContentState, force: Bool = false) {
        guard s.handle != nil, !s.ended else { return }
        if content == s.sent {
            s.pending = nil
            return
        }
        let t = now.timeIntervalSince1970
        if !force, t - s.sentAt < Self.summaryInterval {
            s.pending = content
            scheduleSummaryFlush(s)
            return
        }
        sendSummary(s, content)
    }

    private func sendSummary(_ s: Summary, _ content: LiveContentState) {
        guard let handle = s.handle else { return }
        s.sent = content
        s.sentAt = now.timeIntervalSince1970
        s.pending = nil
        s.flushTask?.cancel()
        s.flushTask = nil
        let stale = now.addingTimeInterval(Self.staleSeconds)
        writes.enqueue { await handle.update(content, staleDate: stale) }
        scheduleKeepalive(s)
    }

    /// The card says "waiting for cobalt…" once its stale date passes: while the app is alive and the period goes on, the
    /// last content is written again before that.
    private func scheduleKeepalive(_ s: Summary) {
        s.keepaliveTask?.cancel()
        guard let clock = ctx?.clock else { return }
        s.keepaliveTask = Task { [weak self, weak s] in
            try? await clock.sleep(seconds: Self.summaryKeepalive)
            guard !Task.isCancelled, let self, let s, !s.ended, let last = s.sent else { return }
            self.sendSummary(s, last)
        }
    }

    private func scheduleSummaryFlush(_ s: Summary) {
        guard s.flushTask == nil, let clock = ctx?.clock else { return }
        let wait = max(0.0, Self.summaryInterval - (now.timeIntervalSince1970 - s.sentAt))
        s.flushTask = Task { [weak self, weak s] in
            try? await clock.sleep(seconds: wait)
            guard !Task.isCancelled, let self, let s else { return }
            s.flushTask = nil
            if let held = s.pending, !s.ended { self.writeSummary(s, held, force: true) }
        }
    }

    // MARK: - Registering with the server

    private func tokenArrived(_ r: Run, _ token: String) {
        guard !r.ended else { return }
        r.updateToken = token
        scheduleRegister(r)
    }

    private func scheduleRegister(_ r: Run) {
        guard pushAvailable, !r.disabled, !r.ended, !r.folded, let token = r.updateToken, let client = ctx?.client else { return }
        if r.registeredToken == token, r.registeredSession == r.session { return }
        r.registerAttempted = true
        network.enqueue { [weak self] in await self?.register(r, client) }
    }

    private func register(_ r: Run, _ client: any CobaltClient) async {
        guard let env = environment, let token = r.updateToken, !r.disabled, !r.ended, !r.folded,
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
        if !r.pushing, !r.ended, !r.folded, let latest = r.built { write(r, latest, force: true) }       // local mode writes everything
    }

    // MARK: - Activities the server started, orphans

    private func adoptIfWanted(_ handle: any LiveActivityHandle) {
        let id = handle.attributes.run
        if endIfDuplicate(handle) { return }
        guard !handle.isEnded, !isCarried(id), adopted[id] == nil else { return }
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
            if isCarried(id) {
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
        guard inBackground else {
            grace.end()
            return
        }
        if let s = summary, !s.ended, s.handle != nil, let queue = jobQueue, !queue.live.isEmpty {
            grace.begin()
            return
        }
        let inFlight = runs.values.contains { r in
            guard !r.detached, !r.ended, r.handle != nil, !isPushMode(r), let p = r.pipeline else { return false }
            return p.state.isLiveInFlight
        }
        if inFlight { grace.begin() } else { grace.end() }
    }

    // MARK: - Tests

    /// Everything queued so far has run.
    func settle() async {
        await writes.drain()
        await network.drain()
        await writes.drain()
    }

    /// The busy period's activity right now (nil outside a busy period, or when there is none to show).
    var summaryHandle: (any LiveActivityHandle)? { summary?.handle }
    var inBusyPeriod: Bool { summary != nil }
}

extension PipelineState {
    /// Work is going on in this run (a save, an upload, frames being read, a render), not waiting for the owner.
    var isLiveInFlight: Bool {
        switch self {
        case .fetching, .uploading, .saving, .reading, .rendering: return true
        default: return false
        }
    }
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
