import Foundation
import Observation

// The queue tab (apple/CONTRACT.md section 12): everything cobalt is doing, in one ordered list.
//
// Nothing here runs work of its own. The list is read from the stores that own the work (the app's jobs, the
// "keep offline" downloads, the photos album) plus one server snapshot (`GET /queue`: the line, the search index's
// backlog, the posters), and every action is routed back to the owner's existing method. A server line entry that is
// one of this app's own jobs is shown once, as the job.
//
// Polling: only while the queue tab is on screen and the app is in front, and never without `features.queue`. Every
// 5 s while something on the server moves (a job running or waiting in the line, an index pass running), else every
// 30 s; errors back off (10, 20, 40, 80, then 120 s).

/// Where an item sits on the queue tab, in the tab's order.
public enum QueueSection: Int, Sendable, CaseIterable, Comparable, Hashable {
    /// Running now: this device's jobs that are working (checking, uploading, saving, reading, rendering), a post
    /// waiting for the owner to pick, and what the server runs for anyone else.
    case now
    /// Waiting in the server's line (or this device's line), in line order.
    case waiting
    /// The library search index's backlog, and posters still to make.
    case indexing
    /// "keep offline" downloads in progress or waiting for the network.
    case downloads
    /// The photos album adding saves.
    case photos
    /// Saved or webp ready, newest first (kept for `UnifiedQueue.finishedLinger`).
    case finished
    /// Jobs and downloads that ended badly, until retried or dismissed.
    case failed

    public static func < (a: QueueSection, b: QueueSection) -> Bool { a.rawValue < b.rawValue }
}

/// What an item can be asked to do. Each is routed to the store that owns the work; nothing new is asked of the server.
public enum QueueAction: Sendable, Hashable {
    /// A job: `JobQueue.cancel` (which cancels, or stops following, per CONTRACT-PARALLEL 3.4). A download: stop it.
    /// A waiting server entry of this key's: the line's existing cancel (`DELETE /studio/<sid>/line` or
    /// `…/render/<job>`).
    case cancel
    /// A failed job: `JobQueue.retry`. A failed download: queued again.
    case retry
    /// A failed or finished job: `JobQueue.dismiss`. A failed download: taken off the list. A finished line: forgotten.
    case dismiss
    /// Shows the work where it lives (`AppModel.open(_:)`): the focused job, the media, the library, Settings.
    case open
}

/// Where `open` goes (`AppModel.open(_:)` applies it).
public enum QueueDestination: Sendable, Equatable {
    /// The save tab with this job in focus.
    case job(Job.ID)
    /// The save tab with this stored media's detail open (`AppModel.requestedMediaID`).
    case media(String)
    case library
    case settings
    /// The video editor with this project open (`AppModel.open(_:)` opens it; a finished render opens its video instead).
    case edit(projectID: String)
}

/// What the server runs or holds for someone else (a share sheet, another device), or for this key when this app does
/// not follow it as a job.
public struct ServerWork: Sendable, Equatable {
    /// "save" | "render" | "webp" | "poster" (the line's own words; anything else is passed through).
    public var kind: String
    /// Running on the server now (else waiting).
    public var running: Bool
    /// The place in the line (the running job counts as 1st); nil for the running one.
    public var position: Int?
    /// This key's work.
    public var mine: Bool
    /// "share" for the share sheet.
    public var origin: String?
    /// The name of the key that sent it ("iphone", "mac"); nil for a key the server cannot name.
    public var keyName: String?
    public var sid: String?
    public var job: String?
    public var link: URL?

    public init(
        kind: String, running: Bool, position: Int? = nil, mine: Bool = false, origin: String? = nil,
        keyName: String? = nil, sid: String? = nil, job: String? = nil, link: URL? = nil
    ) {
        self.kind = kind; self.running = running; self.position = position; self.mine = mine; self.origin = origin
        self.keyName = keyName; self.sid = sid; self.job = job; self.link = link
    }

    /// A save (as opposed to a webp, a render or a poster).
    public var isSave: Bool { kind == "save" }
    /// The share sheet sent it.
    public var isShare: Bool { origin == "share" }
}

/// A job that finished and left the app's queue (after its seconds in the tray), remembered for "recently finished".
public struct FinishedWork: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case saved
        case webp(WebpResult)
    }

    public var id: UUID
    public var title: String
    public var outcome: Outcome
    public var finishedAt: Date
    /// The stored media it landed as, when it is on this device (open shows its detail).
    public var mediaID: String?

    public init(id: UUID, title: String, outcome: Outcome, finishedAt: Date, mediaID: String? = nil) {
        self.id = id; self.title = title; self.outcome = outcome; self.finishedAt = finishedAt; self.mediaID = mediaID
    }
}

/// One row of the queue tab.
@MainActor
public struct QueueItem: Identifiable {
    public enum Kind {
        /// One of this app's jobs (the same `Job` the tray shows: its card is reused as is).
        case job(Job)
        /// A server line entry no local job represents.
        case server(ServerWork)
        case download(OfflineDownloadRow)
        /// The photos album adding saves.
        case photos(PhotosSync.Progress)
        /// The library search index.
        case indexing(QueueSnapshot.Search)
        /// Posters the server still has to make.
        case posters(pending: Int)
        /// A finished job that has left the app's queue.
        case finished(FinishedWork)
        /// One render of the video editor (CONTRACT-EDITOR 6): the server's copy merged with this device's, the freshest.
        case edit(EditRender)
    }

    /// Stable across refreshes: "job:<uuid>", "server:…", "download:<key>", "photos", "indexing", "posters",
    /// "finished:<uuid>".
    public let id: String
    public let section: QueueSection
    public let kind: Kind
    /// What the row offers, in the order the UI lists them.
    public let actions: [QueueAction]

    public init(id: String, section: QueueSection, kind: Kind, actions: [QueueAction]) {
        self.id = id; self.section = section; self.kind = kind; self.actions = actions
    }

    /// The local job behind the row, if it is one.
    public var job: Job? {
        if case .job(let job) = kind { return job }
        return nil
    }

    /// Where `open` goes; nil when the row has nowhere to open.
    public var destination: QueueDestination? {
        guard actions.contains(.open) else { return nil }
        switch kind {
        case .job(let job): return .job(job.id)
        case .finished(let work): return work.mediaID.map(QueueDestination.media) ?? .library
        case .indexing, .posters: return .library
        case .photos: return .settings
        case .edit(let render):
            if render.status == .done, let item = render.itemID { return .media("post:\(item)") }
            return .edit(projectID: render.projectID)
        case .server, .download: return nil
        }
    }

    /// The editor render behind the row, if it is one.
    public var editRender: EditRender? {
        if case .edit(let render) = kind { return render }
        return nil
    }
}

/// One section of the queue tab and its rows.
@MainActor
public struct QueueGroup: Identifiable {
    public let section: QueueSection
    public let items: [QueueItem]
    public nonisolated var id: QueueSection { section }
}

/// The counts in the tab's header and its badge.
public struct QueueSummary: Sendable, Equatable {
    public var running = 0
    public var waiting = 0
    public var failed = 0
    public var finished = 0

    public init(running: Int = 0, waiting: Int = 0, failed: Int = 0, finished: Int = 0) {
        self.running = running; self.waiting = waiting; self.failed = failed; self.finished = finished
    }

    /// Nothing running, waiting or failed (finished lines and the index may still show).
    public var isQuiet: Bool { running == 0 && waiting == 0 && failed == 0 }
}

/// The queue tab's model. Owned by `AppModel` (`unifiedQueue`).
@MainActor @Observable
public final class UnifiedQueue {
    /// How long a finished job stays under "recently finished" after it left the app's queue.
    public static let finishedLinger: TimeInterval = 30 * 60
    /// At most this many finished lines are remembered.
    public static let finishedLimit = 20

    /// The server's last answer (nil without `features.queue`, before the first answer, or after a server change).
    public private(set) var snapshot: QueueSnapshot?
    /// When `snapshot` arrived (the device's clock).
    public private(set) var updatedAt: Date?
    /// The last poll failed (the list keeps the last good snapshot and says so).
    public private(set) var serverProblem = false
    /// Finished jobs that left the app's queue, newest first.
    public internal(set) var finishedHistory: [FinishedWork] = []
    /// Renders of the editor the owner hid with "dismiss" (this device only).
    public private(set) var dismissedEdits: Set<String> = []
    /// The editor's renders on this device (`EditorStore.renders`), wired by `AppModel`; nil in a queue with no editor.
    @ObservationIgnored var editRenders: (@MainActor () -> [EditRender])?
    /// The renders of each fresh snapshot (the Live Activities of renders); wired by `AppModel`.
    @ObservationIgnored var onEdits: (@MainActor ([EditRender]) -> Void)?
    /// The queue tab is on screen (`setVisible`).
    public private(set) var isVisible = false
    /// The app is in front (`setForeground`).
    public private(set) var isForeground = true

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let jobs: JobQueue
    @ObservationIgnored let offline: OfflineDownloads
    @ObservationIgnored let photos: PhotosSync
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollToken = 0
    /// Polls sent (tests and telemetry).
    @ObservationIgnored private(set) var polls = 0

    init(context: PipelineContext, jobs: JobQueue, offline: OfflineDownloads, photos: PhotosSync) {
        self.ctx = context
        self.jobs = jobs
        self.offline = offline
        self.photos = photos
        jobs.onRetireFinished = { [weak self] job in self?.remember(job) }
    }

    // MARK: - Reading

    /// Every row, grouped by section in the tab's order.
    public var items: [QueueItem] {
        Self.build(
            jobs: jobs.jobs, snapshot: ctx.capabilities.queue ? snapshot : nil,
            downloads: offline.rows, photos: photos.status, finished: finishedHistory, now: ctx.clock.now(),
            edits: mergedEdits, dismissedEdits: dismissedEdits)
    }

    /// The server's renders (`GET /queue`) and this device's, one per render id, the freshest copy of each.
    var mergedEdits: [EditRender] {
        Self.mergeEdits(server: ctx.capabilities.queue ? (snapshot?.edits ?? []) : [], local: ctx.capabilities.editor ? (editRenders?() ?? []) : [])
    }

    /// The rows of each section that has any, in the tab's order.
    public var sections: [QueueGroup] {
        let all = items
        return QueueSection.allCases.compactMap { section in
            let rows = all.filter { $0.section == section }
            return rows.isEmpty ? nil : QueueGroup(section: section, items: rows)
        }
    }

    public var summary: QueueSummary { Self.summary(of: items) }

    /// The tab's badge: work in motion on this device (its live jobs and downloads). Server entries are left out: the
    /// snapshot is only fresh while the tab is on screen, and the index's backlog is not something to badge.
    public var badgeCount: Int {
        jobs.live.count + offline.rows.filter { !$0.isFailed }.count
            + mergedEdits.filter { $0.isActive && !dismissedEdits.contains($0.id) }.count
    }

    /// Nothing to show at all: the empty state.
    public var isEmpty: Bool { items.isEmpty }

    // MARK: - Polling

    /// The queue tab appeared (true) or went away (false).
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        reschedule()
    }

    /// The app came to the front (true) or left it (false): scenePhase `.active` or not.
    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        reschedule()
    }

    /// `features.queue` may have come or gone (`AppModel.apply`).
    func capabilitiesChanged() {
        if !ctx.capabilities.queue {
            snapshot = nil
            serverProblem = false
            failures = 0
        }
        reschedule()
    }

    /// Another server: nothing from the old one is kept.
    func serverChanged() {
        snapshot = nil
        updatedAt = nil
        serverProblem = false
        failures = 0
        finishedHistory = []
        dismissedEdits = []
        reschedule()
    }

    var shouldPoll: Bool { isVisible && isForeground && ctx.capabilities.queue }

    /// One `GET /queue` now (pull to refresh, and after an action). False when nothing new arrived.
    @discardableResult
    public func refresh() async -> Bool {
        guard ctx.capabilities.queue else {
            snapshot = nil
            return false
        }
        polls += 1
        do {
            let fresh = try await ctx.client.queue()
            guard ctx.capabilities.queue else { return false }          // turned off while it was in flight
            snapshot = fresh
            if let edits = fresh.edits, !edits.isEmpty { onEdits?(edits) }
            updatedAt = ctx.clock.now()
            serverProblem = false
            failures = 0
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled else { return false }               // the tab went away mid-poll: not a failure
            failures += 1
            serverProblem = true
            if failures == 1 {
                Telemetry.log(.info, .net, "queue poll failed", data: ["error": .string(String(describing: error).prefix(80).description)])
            }
            return false
        }
    }

    /// Seconds until the next poll: 5 while the server is busy, 30 when it is quiet, and backing off after errors
    /// (10, 20, 40, 80, then 120 at most).
    nonisolated static func delay(active: Bool, failures: Int) -> Double {
        if failures > 0 { return min(120, 5 * pow(2, Double(min(failures, 6)))) }
        return active ? 5 : 30
    }

    private func reschedule() {
        if shouldPoll {
            guard pollTask == nil else { return }
            pollToken += 1
            let token = pollToken
            pollTask = Task { @MainActor [weak self] in
                await self?.pollLoop()
                guard let self, self.pollToken == token else { return }
                self.pollTask = nil
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled, shouldPoll {
            await refresh()
            guard !Task.isCancelled, shouldPoll else { return }
            let wait = Self.delay(active: snapshot?.isActive ?? false, failures: failures)
            do { try await ctx.clock.sleep(seconds: wait) } catch { return }
        }
    }

    // MARK: - Actions

    /// cancel, retry and dismiss, routed to the owner of the work. `open` is the app's (`AppModel.open(_:)`).
    public func perform(_ action: QueueAction, on item: QueueItem) async {
        guard item.actions.contains(action) else { return }
        switch (item.kind, action) {
        case (.job(let job), .cancel):
            await jobs.cancel(job.id)
        case (.job(let job), .retry):
            jobs.retry(job.id)
        case (.job(let job), .dismiss):
            // a multi-item post waiting for the owner is "cancelled" (it goes, nothing was saved); the rest are let go
            if job.isPicker { await jobs.cancel(job.id) } else { jobs.dismiss(job.id) }
        case (.server(let work), .cancel):
            guard let sid = work.sid else { return }
            do {
                if let job = work.job, !work.isSave {
                    _ = try await ctx.client.cancelQueued(session: sid, job: job)
                } else {
                    _ = try await ctx.client.cancelQueued(session: sid)
                }
            } catch {
                Telemetry.log(.info, .net, "queue cancel failed", data: ["kind": .string(work.kind)])
            }
            await refresh()
        case (.download(let row), .cancel), (.download(let row), .dismiss):
            offline.stop(key: row.id)
        case (.download(let row), .retry):
            offline.retry(key: row.id)
        case (.finished(let work), .dismiss):
            finishedHistory.removeAll { $0.id == work.id }
        case (.edit(let render), .dismiss):
            dismissedEdits.insert(render.id)
        default:
            break
        }
    }

    // MARK: - Recently finished

    func remember(_ job: Job) {
        let p = job.pipeline
        let outcome: FinishedWork.Outcome
        if case .done(let result) = p.state { outcome = .webp(result) } else { outcome = .saved }
        let work = FinishedWork(
            id: job.id, title: MediaTitle.text(p.resolvedTitle), outcome: outcome,
            finishedAt: job.finishedAt ?? ctx.clock.now(), mediaID: p.stored?.mediaID)
        finishedHistory.removeAll { $0.id == work.id }
        finishedHistory.insert(work, at: 0)
        if finishedHistory.count > Self.finishedLimit { finishedHistory.removeLast(finishedHistory.count - Self.finishedLimit) }
    }

    // MARK: - The merge (pure, for tests)

    /// Builds the ordered rows. Within a section: running jobs in the order they were added, then the server's running
    /// work; waiting work in line order (this device's jobs and the server's entries together); downloads oldest
    /// first; finished newest first; failed jobs, then failed downloads.
    static func build(
        jobs: [Job], snapshot: QueueSnapshot?, downloads: [OfflineDownloadRow],
        photos: PhotosSync.Status, finished: [FinishedWork], now: Date, edits: [EditRender] = [],
        dismissedEdits: Set<String> = []
    ) -> [QueueItem] {
        var now_: [QueueItem] = []
        var waiting: [(item: QueueItem, place: Int, order: Int)] = []
        var finishedRows: [(item: QueueItem, at: Date)] = []
        var failed: [QueueItem] = []

        // (a) this device's jobs; what they hold on the server, so the line does not show them twice
        var sessions: Set<String> = []
        var serverJobs: Set<String> = []
        for (order, job) in jobs.enumerated() {
            let p = job.pipeline
            if let sid = p.sessionID { sessions.insert(sid) }
            if let render = p.renderJobID { serverJobs.insert(render) }
            if let make = p.makeJobID { serverJobs.insert(make) }
            let id = "job:\(job.id.uuidString)"
            if job.isFailed {
                failed.append(QueueItem(id: id, section: .failed, kind: .job(job), actions: failedActions(job)))
            } else if job.isLive {
                if p.line != nil {
                    var place = Int.max
                    if case .inLine(let n, _)? = p.line { place = n }
                    waiting.append((QueueItem(id: id, section: .waiting, kind: .job(job), actions: [.cancel, .open]), place, order))
                } else {
                    now_.append(QueueItem(id: id, section: .now, kind: .job(job), actions: [.cancel, .open]))
                }
            } else if job.isPicker {
                now_.append(QueueItem(id: id, section: .now, kind: .job(job), actions: [.open, .dismiss]))
            } else if job.isFinished {
                finishedRows.append((QueueItem(id: id, section: .finished, kind: .job(job), actions: [.open, .dismiss]), job.finishedAt ?? now))
            }
        }

        // (b) the server's line, minus what this device's jobs already are
        if let line = snapshot?.line {
            func isLocal(sid: String?, job: String?) -> Bool {
                if let sid, sessions.contains(sid) { return true }
                if let job, serverJobs.contains(job) { return true }
                return false
            }
            if let r = line.running, !isLocal(sid: r.sid, job: r.job) {
                let work = ServerWork(kind: r.kind, running: true, mine: r.mine, origin: r.origin, keyName: r.keyName, sid: r.sid, job: r.job)
                now_.append(QueueItem(id: "server:running:\(r.sid ?? r.job ?? r.kind)", section: .now, kind: .server(work), actions: []))
            }
            for (i, e) in line.entries.enumerated() where !isLocal(sid: e.sid, job: e.job) {
                let work = ServerWork(
                    kind: e.kind, running: false, position: e.position, mine: e.mine, origin: e.origin, keyName: e.keyName,
                    sid: e.sid, job: e.job, link: e.link.flatMap(URL.init(string:)))
                // a waiting save or render of this key's can be taken out of the line (the line's own cancel)
                let actions: [QueueAction] = e.mine && e.sid != nil ? [.cancel] : []
                let key = e.job ?? e.sid ?? "\(e.kind):\(e.keyName ?? "-"):\(e.position)"
                waiting.append((QueueItem(id: "server:\(key)", section: .waiting, kind: .server(work), actions: actions), e.position, jobs.count + i))
            }
        }

        // (e) the library search index, and the posters
        var indexing: [QueueItem] = []
        if let search = snapshot?.search, search.hasWork {
            indexing.append(QueueItem(id: "indexing", section: .indexing, kind: .indexing(search), actions: [.open]))
        }
        if let pending = snapshot?.posters?.pending, pending > 0 {
            indexing.append(QueueItem(id: "posters", section: .indexing, kind: .posters(pending: pending), actions: [.open]))
        }

        // (c) "keep offline" downloads
        var downloadRows: [QueueItem] = []
        for row in downloads {
            switch row.state {
            case .downloading, .waiting:
                downloadRows.append(QueueItem(id: "download:\(row.id)", section: .downloads, kind: .download(row), actions: [.cancel]))
            case .failed:
                failed.append(QueueItem(id: "download:\(row.id)", section: .failed, kind: .download(row), actions: [.retry, .dismiss]))
            default:
                break
            }
        }

        // (d) the photos album, while it adds
        var photoRows: [QueueItem] = []
        if let progress = photos.progress, photos.enabled, progress.total > 0 {
            photoRows.append(QueueItem(id: "photos", section: .photos, kind: .photos(progress), actions: [.open]))
        }

        // finished jobs that left the queue, within the linger window
        let present = Set(jobs.map(\.id))
        for work in finished where !present.contains(work.id) && now.timeIntervalSince(work.finishedAt) < finishedLinger {
            finishedRows.append((QueueItem(id: "finished:\(work.id.uuidString)", section: .finished, kind: .finished(work), actions: [.open, .dismiss]), work.finishedAt))
        }

        // (f) the video editor's renders: queued wait, running work is now, ended ones linger for 30 minutes (cancelled: hidden)
        for (i, r) in edits.enumerated() where !dismissedEdits.contains(r.id) {
            let id = "edit:\(r.id)"
            switch r.status {
            case .queued:
                let actions: [QueueAction] = r.cancelRequested ? [.open] : [.cancel, .open]
                waiting.append((QueueItem(id: id, section: .waiting, kind: .edit(r), actions: actions), (r.queueAhead ?? 0) + 1, jobs.count + 1_000 + i))
            case .preparing, .rendering, .finishing:
                let actions: [QueueAction] = r.cancelRequested ? [.open] : [.cancel, .open]
                now_.append(QueueItem(id: id, section: .now, kind: .edit(r), actions: actions))
            case .done:
                if now.timeIntervalSince(r.lastMoment) < finishedLinger {
                    finishedRows.append((QueueItem(id: id, section: .finished, kind: .edit(r), actions: [.open, .dismiss]), r.lastMoment))
                }
            case .error:
                if now.timeIntervalSince(r.lastMoment) < finishedLinger {
                    failed.append(QueueItem(id: id, section: .failed, kind: .edit(r), actions: [.retry, .open, .dismiss]))
                }
            case .cancelled:
                break
            }
        }

        let waitingSorted = waiting.sorted { ($0.place, $0.order) < ($1.place, $1.order) }.map { $0.item }
        let finishedSorted = finishedRows.sorted { $0.at > $1.at }.prefix(finishedLimit).map { $0.item }
        var rows: [QueueItem] = now_
        rows.append(contentsOf: waitingSorted)
        rows.append(contentsOf: indexing)
        rows.append(contentsOf: downloadRows)
        rows.append(contentsOf: photoRows)
        rows.append(contentsOf: finishedSorted)
        rows.append(contentsOf: failed)
        return rows
    }

    /// One render per id from the server's list and this device's: the fresher copy wins, this device's on a tie; newest first.
    static func mergeEdits(server: [EditRender], local: [EditRender]) -> [EditRender] {
        var byID: [String: EditRender] = [:]
        for r in server { byID[r.id] = r }
        for r in local {
            if let theirs = byID[r.id], !r.isFresher(than: theirs) { continue }
            byID[r.id] = r
        }
        return byID.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// A failed job: "try again" when the input was fine and the run was not; "open" when the focus has more to offer
    /// (a render that failed with the trim kept, a gallery's make); always "dismiss".
    private static func failedActions(_ job: Job) -> [QueueAction] {
        let p = job.pipeline
        var actions: [QueueAction] = []
        if case .failed(let f) = p.state {
            if f.keepsTrim && p.media != nil && p.sessionID != nil { actions.append(.open) }
            if isRetryable(f) { actions.append(.retry) }
        } else {
            // a gallery: the save failed (try again), or a make failed (the focus has its own try again)
            if case .failed? = p.galleryRun?.phase { actions.append(.retry) } else { actions.append(.open) }
        }
        actions.append(.dismiss)
        return actions
    }

    /// "try again" cannot cure a failure of the input or of the key.
    static func isRetryable(_ failure: PipelineFailure) -> Bool {
        switch failure {
        case .noLink, .tooLarge, .unsupported, .linkUnreadable, .keyMissing, .keyInvalid: return false
        default: return true
        }
    }

    static func summary(of items: [QueueItem]) -> QueueSummary {
        var s = QueueSummary()
        for item in items {
            switch item.section {
            case .now, .photos: s.running += 1
            case .waiting: s.waiting += 1
            case .downloads:
                if case .download(let row) = item.kind, case .waiting = row.state { s.waiting += 1 } else { s.running += 1 }
            case .finished: s.finished += 1
            case .failed: s.failed += 1
            case .indexing: break
            }
        }
        return s
    }
}
