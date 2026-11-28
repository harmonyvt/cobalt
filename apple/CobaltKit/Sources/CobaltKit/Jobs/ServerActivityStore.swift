import Foundation
import Observation

// Phase 3 lane (c) (apple 03-PHASE3 3.1, 3.3): the one paced poller of the server's background work: its line (this key's saves and
// renders, another device's, the share sheet's), the video editor's renders, the search index and the posters. It replaces three loops:
// `ServerLine`'s 3 s `GET /studio/line`, `UnifiedQueue`'s `GET /queue` and the editor session's own render read.
//
// One loop, ever (`loopsStarted` and `maxInFlight` are what the tests read). It reads on every screen, not only the queue tab, so the
// counts and the sheet know of other devices' work wherever the owner is.
//
// Cadence (matrix test 4; `delay(active:failures:)` is the pure function the tests pin):
//   * idle (no server work that nobody here is following)   30 s while the app is in front;
//   * active (a job running or waiting that no `?wait=1` pipeline of this app follows, a local job waiting in the line, an editor
//     render being watched)                                   3 s;
//   * the app is not in front                                  not at all (the loop ends; coming back reads at once);
//   * failures in a row (5xx, offline, a key refused)         6, 12, 24, 48, 96 s, then 120 s at most, reset by one answer.
// A mutation (an action on a row, a save created, a render sent) calls `refresh()`, which reads now and re-derives the cadence.
//
// Legacy servers (no `features.queue`, only `features.line`): the same loop reads `GET /studio/line` instead, and only while a job of
// this app waits in the line (the labels of who is ahead), as `ServerLine` did; with nobody waiting there is nothing to read.

/// What the store tells a watcher of one editor render each time it reads.
enum ServerRenderEvent {
    /// The server's copy of the render.
    case render(EditRender)
    /// The answer does not list it (an older server's `/queue`, a render that aged out): the watcher reads it itself, once.
    case missing
    /// The read failed.
    case failed(any Error)
}

/// A subscription to one editor render (`ServerActivityStore.watchRender`). Cancel it when the render ends or the session closes.
@MainActor
final class ServerRenderWatch {
    let renderID: String
    fileprivate let handler: @MainActor (ServerRenderEvent) -> Void
    fileprivate weak var store: ServerActivityStore?

    fileprivate init(renderID: String, store: ServerActivityStore, handler: @escaping @MainActor (ServerRenderEvent) -> Void) {
        self.renderID = renderID
        self.store = store
        self.handler = handler
    }

    func cancel() { store?.stopWatching(self) }
}

@MainActor @Observable
public final class ServerActivityStore {
    // MARK: Cadence

    nonisolated public static let activeSeconds: Double = 3
    nonisolated public static let idleSeconds: Double = 30
    nonisolated public static let backoffCapSeconds: Double = 120

    /// Seconds until the next read: 3 while the server has work nobody here follows, 30 when it is quiet, and after failures 6, 12,
    /// 24, 48, 96, then 120 at most (twice the active interval each time, reset by one answer).
    nonisolated public static func delay(active: Bool, failures: Int) -> Double {
        if failures > 0 { return min(backoffCapSeconds, activeSeconds * pow(2, Double(min(failures, 8)))) }
        return active ? activeSeconds : idleSeconds
    }

    // MARK: State

    /// The server's last answer (nil without `features.queue`, before the first answer, or after a server change). On a legacy
    /// server it holds only the line.
    public private(set) var snapshot: QueueSnapshot?
    /// When `snapshot` arrived (the device's clock).
    public private(set) var updatedAt: Date?
    /// The last read failed (the answer is kept and says so).
    public private(set) var serverProblem = false
    /// Reads in a row that failed; 0 after one that worked.
    public private(set) var failures = 0
    /// The app is in front (`setForeground`). Nothing is read while it is not.
    public private(set) var isForeground = true
    /// Finished jobs that left the app's queue, newest first (`UnifiedQueue.finishedHistory` reads and writes this).
    public internal(set) var finishedHistory: [FinishedWork] = []
    /// Renders of the editor the owner hid with "dismiss" (this device only).
    public internal(set) var dismissedEdits: Set<String> = []
    /// Audio leveling jobs the owner hid with "dismiss" (this device only).
    public internal(set) var dismissedAudioLevels: Set<String> = []

    @ObservationIgnored let ctx: PipelineContext
    /// The renders of each fresh snapshot (the Live Activities of renders); wired by `AppModel` (through `UnifiedQueue.onEdits`).
    @ObservationIgnored var onEdits: (@MainActor ([EditRender]) -> Void)?
    /// The audio leveling jobs of each fresh snapshot (reconciles `AudioLevelStore` and updates `AudioLevelLiveManager`).
    @ObservationIgnored var onAudioLevels: (@MainActor ([QueueSnapshot.AudioLevelJob]) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopToken = 0
    /// A read is in progress (the loop's or a caller's): the next caller waits for its answer instead of sending a second request.
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    /// Another server or the capability went: an answer in flight belongs to the old one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchers: [ServerRenderWatch] = []
    @ObservationIgnored private var retired = false
    /// Polling loops started (`evaluate` found work and no loop), re-timed (the loop's sleep restarted with a new length), reads sent,
    /// reads in flight at once at the most (tests: one loop, never two reads together).
    @ObservationIgnored private(set) var loopsStarted = 0
    @ObservationIgnored private(set) var retimes = 0
    @ObservationIgnored private(set) var polls = 0
    @ObservationIgnored private(set) var maxInFlight = 0
    @ObservationIgnored private(set) var inFlight = 0
    /// The seconds the loop is sleeping for now (nil while it reads or is not running): what the cadence tests pin.
    @ObservationIgnored private(set) var currentWait: Double?

    // MARK: The one store per context

    private struct Entry { weak var store: ServerActivityStore? }
    private static var registry: [ObjectIdentifier: Entry] = [:]

    /// The store of this context. `UnifiedQueue` and the sources are built before it (`AppModel.init`) and find it here at the time
    /// they are first read; `EditSession` finds it the same way.
    static func current(for context: PipelineContext) -> ServerActivityStore? {
        let id = ObjectIdentifier(context)
        guard let store = registry[id]?.store, !store.retired else { return nil }
        return store
    }

    init(context: PipelineContext) {
        self.ctx = context
        // a context has one: a store made earlier (a queue read before the model finished building) hands over and stops
        if let old = Self.registry[ObjectIdentifier(context)]?.store, old !== self {
            onEdits = old.onEdits
            onAudioLevels = old.onAudioLevels
            finishedHistory = old.finishedHistory
            dismissedEdits = old.dismissedEdits
            dismissedAudioLevels = old.dismissedAudioLevels
            old.retire()
        }
        Self.registry[ObjectIdentifier(context)] = Entry(store: self)
        let lifecycle = AppLifecycle.shared
        isForeground = lifecycle.snapshot.phase != .background
        lifecycle.register(self, order: .work)
        context.jobQueue?.serverLine.onWaitersChanged = { [weak self] joined in self?.lineWaitersChanged(joined: joined) }
        evaluate()
    }

    /// For tests and the model: signs up with another listener than the app's (`AppModel.observeLifecycle`).
    func observeLifecycle(_ lifecycle: AppLifecycle = .shared) {
        lifecycle.register(self, order: .work)
    }

    private func retire() {
        retired = true
        stopLoop()
        for w in watchers { w.store = nil }
        watchers = []
    }

    // MARK: Whether and how fast

    /// There is something to read and the app is in front.
    var shouldPoll: Bool {
        guard isForeground, !retired else { return false }
        if ctx.capabilities.queue { return true }
        return ctx.capabilities.line && localJobsWait
    }

    /// A job of this app waits in the server's line (its labels need the answer).
    private var localJobsWait: Bool { !(ctx.jobQueue?.serverLine.queued.isEmpty ?? true) }

    /// Server work that nobody in this app follows with its own `?wait=1` poll, a job of this app waiting in the line, or an editor
    /// render being watched: the 3 s case.
    var isBusy: Bool {
        if localJobsWait || !watchers.isEmpty { return true }
        guard ctx.capabilities.queue, let snapshot else { return false }
        return foreignWork(in: snapshot)
    }

    private func foreignWork(in snapshot: QueueSnapshot) -> Bool {
        var sessions: Set<String> = []
        var serverJobs: Set<String> = []
        for job in ctx.jobQueue?.jobs ?? [] {
            let p = job.pipeline
            if let sid = p.sessionID { sessions.insert(sid) }
            if let render = p.renderJobID { serverJobs.insert(render) }
            if let make = p.makeJobID { serverJobs.insert(make) }
        }
        func isLocal(sid: String?, job: String?) -> Bool {
            if let sid, sessions.contains(sid) { return true }
            if let job, serverJobs.contains(job) { return true }
            return false
        }
        if let line = snapshot.line {
            if let r = line.running, !isLocal(sid: r.sid, job: r.job) { return true }
            if line.entries.contains(where: { !isLocal(sid: $0.sid, job: $0.job) }) { return true }
        }
        if snapshot.edits?.contains(where: \.isActive) == true { return true }
        return snapshot.audio?.contains(where: \.isActive) == true
    }

    /// Whether the server rows of `snapshot` are news: while the app is in front and reads keep working, always; otherwise for
    /// `ServerActivitySource.serverFreshness` seconds after the answer (a backgrounded or failing app does not keep counting
    /// another device's work for ever).
    func isFresh(at now: Date) -> Bool {
        guard let updatedAt else { return false }
        if isForeground && !serverProblem { return true }
        return now.timeIntervalSince(updatedAt) <= ServerActivitySource.serverFreshness
    }

    // MARK: The loop

    /// Starts, stops or re-times the loop to match `shouldPoll` and `isBusy`. Called for every input that can change either.
    private func evaluate() {
        if shouldPoll {
            if loop == nil { startLoop(due: true, retime: false) } else { retime() }
        } else {
            stopLoop()
        }
    }

    /// `due`: the loop reads before its first sleep (a new loop, a job that needs its labels) and does not when it only re-times.
    /// The loop task holds the store only while it works (`turn`), never across its sleep, so a store nobody owns any more is freed.
    private func startLoop(due: Bool, retime isRetime: Bool) {
        loopToken += 1
        if isRetime { retimes += 1 } else { loopsStarted += 1 }
        let token = loopToken
        let clock = ctx.clock
        loop?.cancel()
        currentWait = nil
        loop = Task { @MainActor [weak self] in
            var due = due
            while !Task.isCancelled {
                guard let wait = await self?.turn(token: token, due: due) else { break }
                do { try await clock.sleep(seconds: wait) } catch { return }
                guard let self, self.loopToken == token else { return }
                self.currentWait = nil
                due = true
            }
            self?.loopEnded(token)
        }
    }

    private func loopEnded(_ token: Int) {
        guard loopToken == token else { return }
        loop = nil
        currentWait = nil
    }

    private func stopLoop() {
        loopToken += 1                      // a loop that is unwinding must not touch its successor
        loop?.cancel()
        loop = nil
        currentWait = nil
    }

    /// The server got busy or quiet (or reads started failing, or stopped): the sleep restarts with the length that fits now.
    /// Nothing happens while a read is in progress (the loop re-derives its wait when it ends) or when the length is the same.
    private func retime() {
        guard loop != nil, !reading, let current = currentWait else { return }
        if Self.delay(active: isBusy, failures: failures) != current { startLoop(due: false, retime: true) }
    }

    /// Reads now through the loop (a job joined the line, a watcher came, another server): the sleep ends early.
    private func requestPoll() {
        guard loop != nil else { evaluate(); return }
        guard !reading else { return }
        startLoop(due: true, retime: true)
    }

    /// One turn of the loop: the read when it is due, then how long to sleep. Nil ends the loop (stopped, replaced, or nothing to read).
    private func turn(token: Int, due: Bool) async -> Double? {
        guard !Task.isCancelled, loopToken == token, shouldPoll else { return nil }
        if due, ctx.background.activity.isActive {
            await refresh()
            guard !Task.isCancelled, loopToken == token, shouldPoll else { return nil }
        }
        let wait = Self.delay(active: isBusy, failures: failures)
        currentWait = wait
        return wait
    }

    // MARK: Reading

    /// One read now (pull to refresh, after an action, a job joining the line). Joins a read already in progress. False when nothing
    /// new arrived. The loop's next wait is re-derived from the answer.
    @discardableResult
    public func refresh() async -> Bool {
        guard canRead else {
            if !ctx.capabilities.queue, snapshot != nil { snapshot = nil }
            return false
        }
        if reading { return await withCheckedContinuation { waiters.append($0) } }
        reading = true
        var result = false
        var sent = generation
        repeat {
            sent = generation
            result = await fetch()
        } while sent != generation && !Task.isCancelled && canRead          // the server changed under it: the answer was dropped, ask again
        reading = false
        let joined = waiters
        waiters = []
        for waiter in joined { waiter.resume(returning: result) }
        retime()
        return result
    }

    private var canRead: Bool { !retired && (ctx.capabilities.queue || ctx.capabilities.line) }

    private func fetch() async -> Bool {
        polls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        let started = generation
        do {
            let fresh: QueueSnapshot
            if ctx.capabilities.queue {
                fresh = try await ctx.client.queue()
            } else {
                fresh = QueueSnapshot(line: try await ctx.client.line())
            }
            guard started == generation, canRead else { return false }       // another server, or the route went, while it was in flight
            accept(fresh)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, started == generation else { return false }      // stopped mid-read: not a failure
            reject(error)
            return false
        }
    }

    func accept(_ fresh: QueueSnapshot) {
        snapshot = fresh
        updatedAt = ctx.clock.now()
        serverProblem = false
        failures = 0
        ctx.jobQueue?.serverLine.apply(fresh.line)
        if let edits = fresh.edits, !edits.isEmpty { onEdits?(edits) }
        if let audio = fresh.audio, !audio.isEmpty { onAudioLevels?(audio) }
        for w in watchers {
            if let r = fresh.edits?.first(where: { $0.id == w.renderID }) { w.handler(.render(r)) } else { w.handler(.missing) }
        }
    }

    private func reject(_ error: any Error) {
        failures += 1
        serverProblem = true
        if failures == 1 {
            Telemetry.log(.info, .net, "queue poll failed", data: ["error": .string(String(describing: error).prefix(80).description)])
        }
        ctx.jobQueue?.serverLine.apply(nil)               // the positions stay, who is ahead goes
        for w in watchers { w.handler(.failed(error)) }
    }

    // MARK: Inputs

    /// The app came to the front (true) or left it (false): the lifecycle's `isActive` (the Mac: `isForeground`). Coming back
    /// reads at once (the loop's first turn); leaving ends the loop.
    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        evaluate()
    }

    /// `features.queue` or `features.line` may have come or gone (`AppModel.apply`).
    func capabilitiesChanged() {
        if !ctx.capabilities.queue, snapshot != nil {
            snapshot = nil
            updatedAt = nil
        }
        if !canRead {
            serverProblem = false
            failures = 0
            generation += 1
        }
        evaluate()
    }

    /// Another server: nothing from the old one is kept.
    func serverChanged() {
        generation += 1
        snapshot = nil
        updatedAt = nil
        serverProblem = false
        failures = 0
        finishedHistory = []
        dismissedEdits = []
        ctx.jobQueue?.serverLine.apply(nil)
        if shouldPoll { requestPoll() } else { evaluate() }                  // the new server is read at once
    }

    /// A job of this app joined or left the server's line: it needs the labels now (a read, when none is fresh), or can stop asking.
    private func lineWaitersChanged(joined: Bool) {
        guard joined else { evaluate(); return }
        let stale = updatedAt.map { ctx.clock.now().timeIntervalSince($0) >= 1 } ?? true
        if shouldPoll, loop != nil { if stale { requestPoll() } else { retime() } } else { evaluate() }
    }

    // MARK: Editor renders

    /// Follows one editor render: `handler` hears each read's answer for it. While anyone watches, the loop runs at 3 s, and the
    /// first read is now.
    func watchRender(id: String, handler: @escaping @MainActor (ServerRenderEvent) -> Void) -> ServerRenderWatch {
        let watch = ServerRenderWatch(renderID: id, store: self, handler: handler)
        watchers.append(watch)
        if shouldPoll { requestPoll() } else { evaluate() }
        return watch
    }

    fileprivate func stopWatching(_ watch: ServerRenderWatch) {
        watchers.removeAll { $0 === watch }
        watch.store = nil
        retime()
    }

    /// Renders being watched (tests).
    var watchedRenderCount: Int { watchers.count }

    // MARK: Recently finished

    /// A job left the app's queue: kept 30 minutes under "recent", with what became of its device copy.
    func remember(_ job: Job) {
        let p = job.pipeline
        let outcome: FinishedWork.Outcome
        if case .done(let result) = p.state { outcome = .webp(result) } else { outcome = .saved }
        let mediaID = p.stored?.mediaID
        // a copy still arriving would read as work for ever once the job is gone: say what is known (the stored media is on the device)
        let receipt = JobStatus.LocalCopyReceipt(p.localCopyState)
        let deviceCopy: JobStatus.LocalCopyReceipt
        switch receipt {
        case .failed, .savedOnDevice: deviceCopy = receipt
        case .notNeeded, .inProgress: deviceCopy = mediaID == nil ? .notNeeded : .savedOnDevice
        }
        let work = FinishedWork(
            id: job.id, title: MediaTitle.text(p.resolvedTitle), outcome: outcome,
            finishedAt: job.finishedAt ?? ctx.clock.now(), mediaID: mediaID, deviceCopy: deviceCopy)
        finishedHistory.removeAll { $0.id == work.id }
        finishedHistory.insert(work, at: 0)
        if finishedHistory.count > UnifiedQueue.finishedLimit {
            finishedHistory.removeLast(finishedHistory.count - UnifiedQueue.finishedLimit)
        }
    }
}

extension ServerActivityStore: LifecycleAware {
    public func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        #if os(macOS)
        // the Mac: in front unless hidden, as scenePhase was (it never left `.active` for Cmd-Tab)
        setForeground(snapshot.isForeground)
        #else
        setForeground(snapshot.isActive)
        #endif
    }
}
