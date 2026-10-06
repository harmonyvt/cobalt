import Foundation
import Observation

/// Every run of the app, as a `Job` wrapping its own `Pipeline`, one of them focused (CONTRACT-PARALLEL.md 2.2, 3.2).
/// `AppModel.pipeline` is the focused job's pipeline (or an idle one), so the focus screens keep reading it unchanged.
///
/// `add` is the single entry point for every source: a paste, a drop, the circle, the review sheet, a relaunch, the
/// share sheet's saves and Shortcuts. Who may take the focus is decided here (5.1), never by the caller.
@MainActor @Observable
public final class JobQueue {
    /// Oldest first. Finished jobs stay until cleared (24 hours at most).
    public private(set) var jobs: [Job] = []
    public private(set) var focusedID: Job.ID?
    /// What `AppModel.pipeline` is while nothing is focused. Never part of `jobs` until something starts on it.
    public private(set) var idlePipeline: Pipeline
    /// Links from last time put back in line (the ledger), until the tray has said so ("3 links from last time are back
    /// in line.").
    public private(set) var restoredCount = 0
    /// Files from last time that were gone ("the file for <name> is gone"), until acknowledged.
    public private(set) var restoredGoneFiles: [String] = []
    /// The newest thing the owner should be told about a cancel or a stop; the tray shows it and clears it.
    public private(set) var notice: JobNotice?
    /// **The UI that shows jobs alongside (the tray, CONTRACT-PARALLEL.md option A) sets this to true when it is on
    /// screen.** While it is false nothing the owner cannot see is started on their behalf: a hand-off or run link over
    /// a busy home screen stays in the store as it always did, a relaunch resumes only the one run today's pickup took
    /// (into the focus), and the share sheet's saves still running on the server are left to the original's download.
    /// A job someone asked for with `add` is always visible to whoever asked, so `add` itself is not gated.
    public var trayIsShown = false

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let ledger: JobLedger?
    @ObservationIgnored let localLine: LocalLine
    @ObservationIgnored let serverLine: ServerLine
    @ObservationIgnored private var meta: [UUID: Meta] = [:]
    @ObservationIgnored private var restored = false
    /// Jobs whose cancel is in flight (a second tap on the same x is ignored: it would ask the server again and be told
    /// the first one had already worked, "couldn't cancel").
    @ObservationIgnored private var cancelling: Set<UUID> = []
    /// Finished jobs that left the queue after their time in the tray (`retireLapsed`): still counted in `summary`.
    @ObservationIgnored private var retiredFinished = 0
    @ObservationIgnored private var retireTask: Task<Void, Never>?

    /// What the pipelines wait in right now.
    var activeLine: any JobLine { lineMode == .server ? serverLine : localLine }

    /// A run no longer holds or waits for the server's one slot, whichever line it was in.
    func releaseLines(_ key: UUID) {
        serverLine.release(key)
        localLine.release(key)
    }

    private struct Meta {
        var input: JobInput?
        var options: JobOptions
        var acceptance: JobAcceptance?
        var waiters: [Int: CheckedContinuation<JobAcceptance, Never>] = [:]
        /// The wave-1 Live sink follows this run as a "detached" one (the owner unfocused it while it was live).
        var liveDetached = false
        var sawRender = false
        var settled = false
        var addedMonotonic = 0
        /// When the job started waiting in a line (for "job line" / "job busy elsewhere" telemetry).
        var waitingSince: Date?
        var loggedBusyElsewhere = false
    }

    private var waiterCounter = 0
    private var addCounter = 0

    init(context: PipelineContext, ledger: JobLedger?) {
        self.ctx = context
        self.ledger = ledger
        let idle = Pipeline(context: context)
        self.idlePipeline = idle
        self.localLine = LocalLine(clock: context.clock)
        self.serverLine = ServerLine(
            client: { [unowned context] in context.client }, clock: context.clock,
            isActive: { [unowned context] in context.background.activity.isActive })
        context.jobQueue = self
        let apply: LineChange = { [weak self] job, position in self?.setLine(job, position) }
        localLine.onChange = apply
        serverLine.onChange = apply
        attach(idle)
        context.background.queueRuns = { [weak self] in self?.unfocusedPipelines ?? [] }
        context.background.queueJobIDs = { [weak self] in self?.recordIDs ?? [] }
    }

    // MARK: - Reading

    public var focused: Job? { focusedID.flatMap { id in jobs.first { $0.id == id } } }

    public var lineMode: LineMode { ctx.capabilities.line ? .server : .device }

    /// In flight (checking … packing), queued on the server included.
    public var live: [Job] { jobs.filter(\.isLive) }

    /// The tray: live + failed + finished less than 5 seconds ago (+ a multi-item post waiting for the owner), minus the
    /// focused one. Ordered: running on the server, then network and local steps, then line order, then waiting for the
    /// owner, failed, finished.
    public var alongside: [Job] {
        let now = ctx.clock.now()
        var rows: [(job: Job, rank: Int, position: Int, order: Int)] = []
        for (order, job) in jobs.enumerated() where job.id != focusedID {
            let p = job.pipeline
            let rank: Int
            if job.isFailed {
                rank = 4
            } else if job.isLive {
                if p.line != nil { rank = 2 } else if Self.runsOnServer(p) { rank = 0 } else { rank = 1 }
            } else if job.isPicker {
                rank = 3
            } else if job.isFinished, let at = job.finishedAt, now.timeIntervalSince(at) < Self.finishedLinger {
                rank = 5
            } else {
                continue
            }
            var position = 0
            if case .inLine(let n, _)? = p.line { position = n }
            rows.append((job, rank, position, order))
        }
        return rows.sorted { ($0.rank, $0.position, $0.order) < ($1.rank, $1.position, $1.order) }.map(\.job)
    }

    /// How long a finished job stays beside the live ones.
    public static let finishedLinger: TimeInterval = 5

    public var summary: JobSummary {
        var s = JobSummary()
        for job in jobs {
            switch job.summaryCategory {
            case .running: s.live += 1
            case .waiting: s.live += 1; s.waiting += 1
            case .finished: s.finished += 1
            case .failed: s.failed += 1
            case .other: break
            }
        }
        s.finished += retiredFinished
        return s
    }

    /// The live job already working on `link` (a paste of it says "already saving that one.").
    public func liveJob(for link: URL) -> Job? {
        jobs.first { $0.isLive && Self.link(of: $0.pipeline) == link }
    }

    public func job(_ id: Job.ID) -> Job? { jobs.first { $0.id == id } }

    private static func link(of p: Pipeline) -> URL? {
        if case .link(let info)? = p.input { return info.url }
        return nil
    }

    /// The server is doing its work (downloading from the service, saving, rendering, packing): not waiting, not local.
    private static func runsOnServer(_ p: Pipeline) -> Bool {
        guard p.sessionID != nil else { return false }
        switch p.state {
        case .fetching, .saving, .rendering: return true
        default: return false
        }
    }

    // MARK: - Adding

    /// The one entry point. Returns one `Job` per input, in order; a link that is already a live job is not added
    /// twice (the live one is returned). Who may take the focus: a single link or file from `.paste`, `.drop` or
    /// `.circle` while nothing is focused and nothing is live (5.1), and a single in-flight job of a relaunch on that
    /// same quiet screen (today's pickup). A batch, a review, a share and a Shortcut never focus.
    @discardableResult
    public func add(_ inputs: [JobInput], via: JobVia, options: JobOptions = .init()) -> [Job] {
        add(inputs, via: via, options: options, allowsFocus: true)
    }

    @discardableResult
    func add(_ inputs: [JobInput], via: JobVia, options: JobOptions, allowsFocus: Bool) -> [Job] {
        guard !inputs.isEmpty else { return [] }
        pruneFinished()
        let batch = inputs.count > 1
        let quiet = focusedID == nil && live.isEmpty
        let focusing: Bool
        switch via {
        case .paste, .drop, .circle, .relaunch: focusing = allowsFocus && !batch && quiet
        case .review, .share, .shortcut: focusing = false
        }
        // A send straight into the server's line: no "checking the link" first (a batch, a drop of several, a Shortcut).
        let skipCheck = batch || via == .shortcut || via == .review || via == .relaunch
        var opts = options
        if batch { opts.title = nil }                                    // one-input adds only
        var out: [Job] = []
        var focused = false
        for input in inputs {
            if case .link(let url) = input, let existing = liveJob(for: url) ?? out.first(where: { Self.link(of: $0.pipeline) == url }) {
                out.append(existing)
                continue
            }
            if case .shared(let shared) = input, let existing = jobs.first(where: { $0.id == shared.id || ($0.pipeline.sessionID != nil && $0.pipeline.sessionID == shared.sessionID) }) {
                out.append(existing)
                continue
            }
            let job = start(input, via: via, options: opts, focus: focusing && !focused, skipCheck: skipCheck)
            if focusedID == job.id, !focused {
                Telemetry.log(.info, .pipeline, "job focus", data: tele(["job": .string(job.id.uuidString), "why": .string(via == .relaunch ? "handoff" : "auto")]))
            }
            focused = focused || focusedID == job.id
            out.append(job)
        }
        let batchSize = out.count
        Telemetry.log(.info, .pipeline, "job added", data: tele([
            "input": .string(Self.inputName(inputs[0])), "via": .string(via.rawValue), "batch": .int(batchSize),
        ]))
        changed()
        return out
    }

    private func start(_ input: JobInput, via: JobVia, options: JobOptions, focus: Bool, skipCheck: Bool) -> Job {
        var id = UUID()
        var origin: Job.Origin = .app
        switch via {
        case .shortcut: origin = .shortcut
        case .relaunch: origin = .relaunch
        case .share: origin = .share
        default: break
        }
        if case .shared(let shared) = input {
            id = shared.id
            origin = shared.origin == .shareExtension ? .share : .relaunch
        }
        let p = Pipeline(context: ctx)
        p.nextLiveRunID = id
        p.jobKey = id
        p.jobOptions = options
        p.takesPartInDeviceLine = true
        p.skipsLinkCheck = skipCheck
        p.requestsLiveActivity = via != .share                           // a share's activity is the share sheet's (CONTRACT-PARALLEL 6)
        attach(p)
        if !focus { ctx.liveRouter.mute(p) }
        addCounter += 1
        var m = Meta(input: input, options: options)
        m.addedMonotonic = addCounter
        meta[id] = m
        let job = Job(id: id, pipeline: p, origin: origin, addedAt: ctx.clock.now(), via: via)
        jobs.append(job)
        if focus { focusedID = id }

        switch input {
        case .link(let url):
            ledger?.add(JobLedger.Entry(id: id, input: .link(url), options: options, via: via, addedAt: job.addedAt))
            p.start(link: url)
        case .file(let url, let assetID):
            p.adoptPhotosAsset(assetID, forFile: url)
            p.start(file: url)
        case .shared(let shared):
            p.resume(shared)
        }
        return job
    }

    private static func inputName(_ input: JobInput) -> String {
        switch input {
        case .link: return "link"
        case .file: return "file"
        case .shared(let s): return s.origin == .shareExtension ? "share" : "relaunch"
        }
    }

    // MARK: - Focus

    /// The owner opened it (a row, a card, a planet). The job that had the focus keeps going alongside.
    public func focus(_ id: Job.ID) { focus(id, why: "owner") }

    func focus(_ id: Job.ID, why: String) {
        guard let job = job(id), focusedID != id else { return }
        if let current = focused { loseFocus(current) }
        focusedID = id
        scheduleRetire()
        ctx.liveRouter.unmute(job.pipeline)
        // A saved job that was never looked at: its filmstrip is read now, for the trim.
        let p = job.pipeline
        if case .ready = p.state, p.frames.allSatisfy({ $0 == nil }), let sid = p.sessionID {
            p.loadFramesInBackground(session: sid, known: p.media)
        }
        Telemetry.log(.info, .pipeline, "job focus", data: tele(["job": .string(id.uuidString), "why": .string(why)]))
        changed()
    }

    /// The focus is closed: a live job keeps going alongside, a saved one stays a card.
    public func unfocus() {
        guard let job = focused else { return }
        loseFocus(job)
        focusedID = nil
        scheduleRetire()
        changed()
    }

    private func loseFocus(_ job: Job) {
        let p = job.pipeline
        guard !ctx.liveRouter.hearsEveryJob, let sink = ctx.liveRouter.sink else { return }
        // The wave-1 Live sink knows one visible run and the runs `detach()` handed over: hand this one over the same
        // way, so its activity follows it alongside instead of ending with the focus.
        if job.isLive {
            if meta[job.id]?.liveDetached != true {
                sink.runDetached(from: p, to: p)
                meta[job.id]?.liveDetached = true
            }
        } else {
            sink.runBegan(idlePipeline)                                 // the finished run's activity ends
            ctx.liveRouter.mute(p)
        }
    }

    // MARK: - Cancel, retry, dismiss

    /// 3.4: what x does depends on where the job is.
    public func cancel(_ id: Job.ID) async {
        guard let job = job(id), cancelling.insert(id).inserted else { return }
        defer { cancelling.remove(id) }
        let p = job.pipeline
        let title = MediaTitle.text(p.resolvedTitle, limit: MediaTitle.notifyLength)
        let queuedOnServer = lineMode == .server && p.sessionID != nil && { if case .inLine? = p.line { return true } else { return false } }()
        var answer = "local"
        switch p.state {
        case .failed, .picker, .image, .done, .savedLocally, .ready, .idle:
            dismiss(id)
            return
        case .reading:
            // the save is done; stop reading the frames
            notice = JobNotice(kind: .stoppedReading, title: title)
            answer = "reading"
            p.detach()
        case .fetching, .uploading, .saving, .rendering:
            if queuedOnServer, let sid = p.sessionID {
                do {
                    let isRender: Bool
                    if case .rendering = p.state { isRender = true } else { isRender = false }
                    let result: QueueCancel
                    if isRender, let renderJob = p.renderJobID {
                        result = try await ctx.client.cancelQueued(session: sid, job: renderJob)
                    } else {
                        result = try await ctx.client.cancelQueued(session: sid)
                    }
                    switch result {
                    case .cancelled:
                        answer = "cancelled"
                        notice = JobNotice(kind: isRender ? .cancelledWebp : .cancelled, title: title)
                        if isRender {
                            // the save stays: the trim is back
                            p.cancel()
                            p.renderJobID = nil
                            p.releaseLine()
                            p.setState(.ready)
                            Telemetry.log(.info, .pipeline, "job cancel", data: tele(["phase": .string("render"), "onServer": true, "answer": .string(answer)]))
                            changed()
                            return
                        }
                        p.cancel()
                        p.reset()
                    case .started:
                        answer = "started"
                        notice = JobNotice(kind: .stoppedFollowing, title: title)
                        p.detach()
                    }
                } catch {
                    // offline: the job stays; the owner is told
                    Telemetry.log(.info, .pipeline, "job cancel", data: tele(["phase": .string("queued"), "onServer": true, "answer": "offline"]))
                    notice = JobNotice(kind: .couldntCancel, title: title)
                    return
                }
            } else if p.sessionID != nil {
                // running on the server: stop following; the server finishes what it started
                answer = "started"
                notice = JobNotice(kind: .stoppedFollowing, title: title)
                p.detach()
            } else {
                // checking the link, uploading, waiting in the device line: nothing was saved
                notice = JobNotice(kind: .cancelled, title: title)
                p.cancel()
                p.reset()
            }
        }
        Telemetry.log(.info, .pipeline, "job cancel", data: tele(["onServer": .bool(p.sessionID != nil), "answer": .string(answer)]))
        // `reset`/`detach` told the queue (the pipeline went idle); a pipeline that never did is dropped here
        if self.job(id) != nil { remove(id) }
        changed()
    }

    /// Failed → the same input again, at the back of the line (a new job; it takes the focus when the failed one had it).
    public func retry(_ id: Job.ID) {
        guard let job = job(id), job.isFailed else { return }
        let p = job.pipeline
        var input = meta[id]?.input
        if input == nil, case .link(let info)? = p.input { input = .link(info.url) }
        guard let input else { return }
        if case .shared(let shared) = input, let link = shared.link { retryLink(job, link) ; return }
        let options = meta[id]?.options ?? JobOptions()
        let wasFocused = focusedID == id
        let via = job.via
        remove(id)
        p.reset()
        let renewed: [Job]
        switch via {
        case .paste, .drop, .circle: renewed = add([input], via: via, options: options, allowsFocus: wasFocused || (focusedID == nil && live.isEmpty))
        default: renewed = add([input], via: via, options: options, allowsFocus: false)
        }
        if wasFocused, let first = renewed.first, focusedID != first.id { focus(first.id) }
    }

    private func retryLink(_ job: Job, _ link: URL) {
        let id = job.id
        let wasFocused = focusedID == id
        let options = meta[id]?.options ?? JobOptions()
        remove(id)
        job.pipeline.reset()
        let renewed = add([.link(link)], via: .paste, options: options, allowsFocus: wasFocused)
        if wasFocused, let first = renewed.first, focusedID != first.id { focus(first.id) }
    }

    /// Takes a finished or failed job off the tray. A job still carrying work the owner does not see (the original's
    /// download) is handed to a background run first, the way closing the focus always did.
    public func dismiss(_ id: Job.ID) {
        guard let job = job(id) else { return }
        job.pipeline.detach()
        if self.job(id) != nil { remove(id) }
        changed()
    }

    /// Takes the finished jobs (saved, webp ready) off the tray. Failed ones stay until retried or dismissed.
    public func clearFinished() {
        for job in jobs where job.isFinished && job.id != focusedID { dismiss(job.id) }
        retiredFinished = 0
    }

    // MARK: - Letting finished jobs go

    /// A finished job (saved, webp ready) is a card in the tray for `finishedLinger`, then a planet in the library: its
    /// pipeline (filmstrip, trim, crop, session state) has nothing left to say, so it leaves the queue and the memory.
    /// What the tray and Live still need is kept: `summary.finished` keeps its count, and a busy period remembers what
    /// each of its jobs did (`LiveActivityManager.updateMembers`: a job that left keeps what it had finished).
    /// Failed jobs stay until retried or dismissed; the focused job stays while it is focused.
    private func scheduleRetire() {
        guard retireTask == nil else { return }
        let now = ctx.clock.now()
        var wait: Double?
        for job in jobs where job.isFinished && job.id != focusedID {
            let remaining = job.finishedAt.map { Self.finishedLinger - now.timeIntervalSince($0) } ?? Self.finishedLinger
            wait = min(wait ?? remaining, max(remaining, 1))
        }
        guard let wait else { return }
        let clock = ctx.clock
        retireTask = Task { @MainActor [weak self] in
            try? await clock.sleep(seconds: wait)
            guard !Task.isCancelled, let self else { return }
            self.retireTask = nil
            self.retireLapsed()
        }
    }

    func retireLapsed() {
        let now = ctx.clock.now()
        var released = false
        for job in jobs where job.isFinished && job.id != focusedID {
            guard let at = job.finishedAt, now.timeIntervalSince(at) >= Self.finishedLinger else { continue }
            // The keep-original download, a host or a "save to photos" still running belongs to this pipeline: it goes
            // on, and the job is let go once they are done. The pipeline itself is not touched (no `detach`, no reset):
            // whoever still holds it (a Shortcut waiting on it, a view mid-transition) keeps reading its final state.
            let p = job.pipeline
            if p.keepRequest != nil || p.hosting == .working || p.photos == .working { continue }
            retiredFinished += 1
            remove(job.id)
            released = true
        }
        if released { changed() }
        scheduleRetire()                                                // the ones whose time has not come yet
    }

    public func clearNotice() { notice = nil }
    public func acknowledgeRestored() { restoredCount = 0; restoredGoneFiles = [] }

    // MARK: - Acceptance (Shortcuts, 15.3)

    /// Until every job has a server session (queued or started) or failed, at most `timeout` seconds.
    public func accepted(_ ids: [Job.ID], timeout: Double) async -> [Job.ID: JobAcceptance] {
        var out: [Job.ID: JobAcceptance] = [:]
        let tasks = ids.map { id in Task { @MainActor in await self.acceptance(of: id, timeout: timeout) } }
        for (id, task) in zip(ids, tasks) { out[id] = await task.value }
        return out
    }

    private func acceptance(of id: UUID, timeout: Double) async -> JobAcceptance {
        if let known = meta[id]?.acceptance { return known }
        guard meta[id] != nil else { return .stillLocal }
        waiterCounter += 1
        let token = waiterCounter
        let clock = ctx.clock
        let timer = Task { @MainActor [weak self] in
            try? await clock.sleep(seconds: timeout)
            guard !Task.isCancelled else { return }
            self?.resolveWaiter(id, token, .stillLocal)
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<JobAcceptance, Never>) in
            meta[id]?.waiters[token] = continuation
        }
        timer.cancel()
        return answer
    }

    private func resolveWaiter(_ id: UUID, _ token: Int, _ answer: JobAcceptance) {
        guard let continuation = meta[id]?.waiters.removeValue(forKey: token) else { return }
        continuation.resume(returning: answer)
    }

    private func accept(_ p: Pipeline, _ a: JobAcceptance) {
        guard let i = index(of: p) else { return }
        let id = jobs[i].id
        guard meta[id] != nil, meta[id]?.acceptance == nil else { return }
        meta[id]?.acceptance = a
        ledger?.remove(id)
        if let waiting = meta[id]?.waiters {
            meta[id]?.waiters = [:]
            for (_, continuation) in waiting { continuation.resume(returning: a) }
        }
        if case .onServer(_, _, let queued, let ahead) = a, queued {
            Telemetry.log(.info, .pipeline, "job queued", data: tele(["ahead": .int(ahead ?? 0)]))
        }
    }

    // MARK: - Pipeline events

    private func attach(_ p: Pipeline) {
        p.jobEvent = { [weak self] p, event in self?.pipelineEvent(p, event) }
    }

    private func index(of p: Pipeline) -> Int? { jobs.firstIndex { $0.pipeline === p } }

    private func pipelineEvent(_ p: Pipeline, _ event: PipelineJobEvent) {
        switch event {
        case .state:
            stateChanged(p)
        case .session, .line:
            changed()
        case .accepted(let a):
            accept(p, a)
        case .inboxCopy(let url, let name, let bytes, let type):
            guard let i = index(of: p), let m = meta[jobs[i].id], m.acceptance == nil else { return }
            let assetID: String? = { if case .file(_, let id)? = m.input { return id } else { return nil } }()
            ledger?.add(JobLedger.Entry(
                id: jobs[i].id, input: .file(path: url.path, name: name, bytes: bytes, contentType: type, photosAssetID: assetID),
                options: m.options, via: jobs[i].via, addedAt: jobs[i].addedAt))
        }
    }

    private func stateChanged(_ p: Pipeline) {
        guard let i = index(of: p) else {
            // Someone started the idle pipeline by hand (the old UI, the library's "trim a new webp"): it is the focus.
            if p === idlePipeline, p.state != .idle { adopt(p) }
            return
        }
        let id = jobs[i].id
        if case .idle = p.state {
            removeIdle(id, p)
            return
        }
        if case .rendering = p.state { meta[id]?.sawRender = true }
        if case .failed(let f) = p.state, meta[id]?.acceptance == nil { accept(p, .failed(f)) }
        let live = jobs[i].isLive
        if live {
            if jobs[i].finishedAt != nil { jobs[i].finishedAt = nil; meta[id]?.settled = false }
        } else if jobs[i].finishedAt == nil, jobs[i].isFinished || jobs[i].isFailed {
            jobs[i].finishedAt = ctx.clock.now()
            settled(jobs[i])
            if jobs[i].isFinished { scheduleRetire() }
        }
        if !live, meta[id]?.liveDetached == true, let sink = ctx.liveRouter.sink, !ctx.liveRouter.hearsEveryJob {
            sink.detachedSettled(p)
            meta[id]?.liveDetached = false
            if id != focusedID { ctx.liveRouter.mute(p) }
        }
        changed()
    }

    /// The idle pipeline left `.idle` on its own: wrap it in a job and focus it (it is on screen).
    private func adopt(_ p: Pipeline) {
        let id = p.liveRunID
        p.jobKey = id
        addCounter += 1
        var m = Meta(input: nil, options: p.jobOptions)
        m.addedMonotonic = addCounter
        m.acceptance = p.acceptance
        meta[id] = m
        let origin: Job.Origin = p.origin == .shareExtension ? .share : .app
        let job = Job(id: id, pipeline: p, origin: origin, addedAt: ctx.clock.now(), via: .circle)
        jobs.append(job)
        if focusedID == nil { focusedID = id } else { ctx.liveRouter.mute(p) }
        let fresh = Pipeline(context: ctx)
        attach(fresh)
        idlePipeline = fresh
        Telemetry.log(.info, .pipeline, "job added", data: tele(["input": "direct", "via": "circle", "batch": 1]))
        stateChanged(p)
    }

    /// A job's pipeline went back to `.idle` (reset, or detached with its work handed on): the job is gone. When it was
    /// the focus, the same object becomes the idle pipeline again, so a view holding it keeps a live reference.
    private func removeIdle(_ id: UUID, _ p: Pipeline) {
        let wasFocused = focusedID == id
        remove(id)
        if wasFocused {
            p.jobKey = nil
            p.jobOptions = JobOptions()
            p.takesPartInDeviceLine = false
            p.skipsLinkCheck = false
            p.requestsLiveActivity = true
            ctx.liveRouter.unmute(p)
            attach(p)
            idlePipeline.jobEvent = nil
            idlePipeline = p
        }
        changed()
    }

    private func remove(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        if focusedID == id { focusedID = nil }
        if let waiting = meta[id]?.waiters, !waiting.isEmpty {
            for (_, continuation) in waiting { continuation.resume(returning: .stillLocal) }
        }
        if meta[id]?.liveDetached == true, !ctx.liveRouter.hearsEveryJob { ctx.liveRouter.sink?.detachedSettled(job.pipeline) }
        meta[id] = nil
        ledger?.remove(id)
        serverLine.release(id)                                          // whichever line it was in
        localLine.release(id)
        if job.pipeline !== idlePipeline {
            job.pipeline.jobEvent = nil
            ctx.liveRouter.unmute(job.pipeline)
        }
    }

    private func settled(_ job: Job) {
        guard meta[job.id]?.settled == false || meta[job.id]?.settled == nil else { return }
        meta[job.id]?.settled = true
        let outcome: String
        switch job.pipeline.state {
        case .failed: outcome = "failed"
        case .done: outcome = "webp"
        default: outcome = "saved"
        }
        Telemetry.log(.info, .pipeline, "job settled", data: tele([
            "outcome": .string(outcome),
            "totalMs": .int(Int(ctx.clock.now().timeIntervalSince(job.addedAt) * 1000)),
        ]))
        // A webp finished while the app is not on screen: the owner is told (a detached run does the same).
        if case .done = job.pipeline.state, meta[job.id]?.sawRender == true, !ctx.background.activity.isActive,
           let notifier = ctx.notifier {
            let id = job.id
            Task { await notifier.post(.webpReady, jobID: id) }
        }
    }

    private func setLine(_ id: UUID, _ position: LinePosition?) {
        guard let job = job(id) else { return }
        // Only a waiting job reads a place; a job that is not waiting (started, finished) never gets one back.
        if position != nil, !job.isLive { return }
        let before = job.pipeline.line
        job.pipeline.line = position
        let now = ctx.clock.now()
        switch (before, position) {
        case (nil, .some): meta[id]?.waitingSince = now
        case (.some, nil):
            // its turn came: how long it waited, and where it stood last
            let waited = meta[id]?.waitingSince.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            var last = 0
            if case .inLine(let n, _)? = before { last = n }
            Telemetry.log(.info, .pipeline, "job line", data: tele(["job": .string(id.uuidString), "position": .int(last), "waitedMs": .int(waited)]))
            meta[id]?.waitingSince = nil
        default: break
        }
        if case .serverBusy(_, let label)? = position, meta[id]?.loggedBusyElsewhere != true {
            meta[id]?.loggedBusyElsewhere = true
            Telemetry.log(.info, .pipeline, "job busy elsewhere", data: tele(["job": .string(id.uuidString), "label": .string(label ?? "")]))
        }
    }

    /// Every change the outside cares about: Live, the grace, the Dock.
    private func changed() {
        ctx.background.queueBusyChanged(jobs.contains { $0.isLive && $0.id != focusedID })
        ctx.liveRouter.jobsChanged(self)
    }

    private var unfocusedPipelines: [Pipeline] { jobs.filter { $0.id != focusedID }.map(\.pipeline) }
    private var recordIDs: Set<UUID> {
        Set(jobs.flatMap { [$0.pipeline.jobRecordID, $0.id] })
    }

    private func tele(_ extra: [String: TelemetryValue]) -> [String: TelemetryValue] {
        var data = extra
        data["concurrent"] = .int(jobs.filter(\.isLive).count)
        data["line"] = .string(lineMode == .server ? "server" : "device")
        return data
    }

    // MARK: - Server change, leaving, launch

    /// A new server: every job belonged to the old one. Nothing is sent to it.
    func serverChanged() {
        let all = jobs
        focusedID = nil
        for job in all {
            job.pipeline.jobEvent = nil
            job.pipeline.cancel()
            job.pipeline.reset()
            ctx.liveRouter.unmute(job.pipeline)
            if let waiting = meta[job.id]?.waiters {
                for (_, continuation) in waiting { continuation.resume(returning: .stillLocal) }
            }
        }
        jobs = []
        meta = [:]
        retireTask?.cancel()
        retireTask = nil
        retiredFinished = 0
        cancelling = []
        ledger?.removeAll()
        serverLine.reset()
        localLine.reset()
        idlePipeline.reset()
        notice = nil
        restoredCount = 0
        restoredGoneFiles = []
        changed()
    }

    /// The app left the screen. On a server with a line and the notify bridge, one `PUT /studio/line/notify` makes
    /// the server send one message when everything left behind is done (17.8); without a line, every run with a
    /// session gets its own opt-in, as `detach()` always did.
    public func appLeft() {
        let onServer = jobs.filter { $0.isLive && $0.pipeline.sessionID != nil }
        guard !onServer.isEmpty else { return }
        if lineMode == .server {
            // One leave, one PUT: the scene resigns active first and enters the background a moment later (and a Mac
            // window closing can follow a resign), each asking. The summary covers everything the server holds, and
            // coming back takes it back (`appForegrounded`, `appBecameActive`).
            guard ctx.notify.lineSource == nil else { return }
            if ctx.queueLineNotify() != nil {
                Telemetry.log(.info, .pipeline, "line notify", data: tele(["watching": .int(onServer.count)]))
            }
            return
        }
        guard ctx.capabilities.notifyBridge else { return }
        for job in onServer {
            if let sid = job.pipeline.sessionID, let optIn = job.pipeline.notifyOptIn {
                ctx.queueNotify(session: sid, optIn, source: .background)
            }
        }
    }

    /// The app is on screen again: the summary is taken back.
    public func appForegrounded() {
        ctx.queueLineCancel()
        pruneFinished()
    }

    private func pruneFinished() {
        let cutoff = ctx.clock.now().addingTimeInterval(-24 * 60 * 60)
        for job in jobs where job.id != focusedID && (job.isFinished || job.isFailed) {
            if let at = job.finishedAt, at < cutoff { dismiss(job.id) }
        }
    }

    /// Once per launch, after the foreground pickup: what the ledger kept (links the server had not answered for) goes
    /// back in, in the order the owner added it. On a server with a line one `GET /studio/line` first, so a link whose
    /// `POST /studio` reached the server but whose answer was lost is followed instead of sent again.
    func restoreLedger() async {
        guard let ledger, !restored else { return }
        restored = true
        let (entries, gone) = ledger.takeForRelaunch()
        restoredGoneFiles = gone
        guard !entries.isEmpty else { return }
        var known: [String: String] = [:]
        if lineMode == .server, entries.contains(where: { if case .link = $0.input { return true } else { return false } }),
           let snapshot = try? await ctx.client.line() {
            for e in snapshot.entries where e.mine && e.kind == "save" {
                if let link = e.link, let sid = e.sid { known[link] = sid }
            }
        }
        var added = 0
        for entry in entries {
            switch entry.input {
            case .link(let url):
                if let sid = known[url.absoluteString] {
                    let shared = SharedJob(
                        id: entry.id, origin: .app, link: url, sessionID: sid, media: nil, trim: nil, stage: .saving,
                        wantsTrim: false, pickedUp: false, updatedAt: ctx.clock.now())
                    added += add([.shared(shared)], via: .relaunch, options: entry.options, allowsFocus: false).count
                } else {
                    added += add([.link(url)], via: .relaunch, options: entry.options, allowsFocus: false).count
                }
            case .file(let path, _, _, _, let assetID):
                added += add([.file(URL(fileURLWithPath: path), photosAssetID: assetID)], via: .relaunch, options: entry.options, allowsFocus: false).count
            }
        }
        restoredCount = added
        Telemetry.log(.info, .pipeline, "ledger restored", data: tele(["jobs": .int(added), "gone": .int(gone.count)]))
    }

    /// The share sheet's saves still running on the server (`GET /studio/recent`, queued ones included) that this app
    /// does not follow yet become `.share` jobs alongside (3.3). A finished one is left to the original's download.
    func adoptRecentShares() async {
        guard trayIsShown, let fetch = ctx.originals?.recentShares ?? ctx.recentShares else { return }
        let sessions = await fetch()
        let followed = Set(jobs.compactMap { $0.pipeline.sessionID })
        let records = Set(ctx.jobs.all().compactMap(\.sessionID))
        for s in sessions where s.status == .saving && !followed.contains(s.id) && !records.contains(s.id) {
            let link = s.link.flatMap(URL.init(string:))
            let shared = SharedJob(
                id: UUID(), origin: .shareExtension, link: link?.scheme?.hasPrefix("http") == true ? link : nil, sessionID: s.id,
                media: nil, trim: nil, stage: .saving, wantsTrim: false, pickedUp: false, updatedAt: ctx.clock.now())
            add([.shared(shared)], via: .share, options: JobOptions(), allowsFocus: false)
        }
    }
}

/// What the owner should be told about a cancel or a stop (the words are the UI's; 3.4).
public struct JobNotice: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        /// "cancelled <title>. nothing was saved."
        case cancelled
        /// "cancelled the webp."
        case cancelledWebp
        /// "stopped following <title>. the server finishes what it started, so it still shows up in your library."
        case stoppedFollowing
        /// "stopped. <title> is saved in your library."
        case stoppedReading
        /// "couldn't cancel: the server didn't answer." The job is still there.
        case couldntCancel
    }

    public let id = UUID()
    public var kind: Kind
    public var title: String
}
