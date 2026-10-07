import Foundation
import Observation

// "keep offline" (CONTRACT-OFFLINE.md decision 9): the engine that fetches renditions into the offline store.
//
// A background `URLSession` (`…cobalt.bg.offline`) does the transfer, so a download survives the app leaving the
// screen and being killed; `OfflineQueue` (`Sync/offline-queue.json`) is the ledger a fresh process reads to
// re-attach to it. Progress reaches `states` at about 4 Hz. A transfer the system interrupts keeps its resume data
// (`Sync/offline-resume/`) and restarts from it. A finished file moves into the inbox inside the delegate callback
// and is landed (`attach` to its record, or `add` a new one) on the main actor, always `keep: true`, with origin
// `.keepOffline` (the owner's "keep offline") or `.pulled` (the Mac's pull of saves made anywhere, `OfflineJob.origin`,
// CONTRACT-OFFLINE.md 13.8): the photos album never copies either (it is not a new save made here).
//
// Delegate callbacks come on the session's own queue. They go through `OfflineEventSink`, a plain `Sendable` class,
// and hop to the main actor with an explicit `Task { @MainActor … }`: nothing the system calls is inferred
// `@MainActor` (that crashed a build before).
//
// A client that cannot hand over a `URLRequest` (`PreviewClient`, test stubs) is fetched in the foreground with
// `client.download`; the same queue, states and landing apply.

@MainActor @Observable
public final class OfflineDownloads {
    /// The background session's identifier; `AppModel.handleBackgroundDownloads` routes it here.
    public static let sessionIdentifier = BackgroundSessionID.prefix + "offline"
    /// The ledger's `session` for a foreground fetch (no system task to re-attach to).
    static let foregroundSession = "foreground"
    /// Network losses, 5xx answers and landings that did not work count against this; then `failed`.
    static let maxTries = 5
    /// `showInFilesURL` is shipped only if gate G-O proves `shareddocuments://` opens Files at the folder
    /// (decision 11a). One switch to flip if it does not.
    public static var showInFilesVerified = true

    /// Downloading, waiting and failed renditions, under every key each is known by (`OfflineKey`). Renditions that
    /// are not in the queue are absent: whether one is kept or cached is the store's word.
    public private(set) var states: [String: RenditionOffline] = [:]

    private struct Track {
        var aliases: [String]
        var state: RenditionOffline
        var expected: Int64?
    }
    private var tracks: [String: Track] = [:]

    /// What the queue is doing: renditions left (downloading or waiting), the bytes so far and the bytes in all
    /// (nil while any size is unknown). Settings' "downloading" row.
    public var summary: (left: Int, bytes: Int64, total: Int64?) {
        var left = 0
        var bytes: Int64 = 0
        var total: Int64? = 0
        for track in tracks.values {
            switch track.state {
            case .waiting:
                left += 1
                total = Self.plus(total, track.expected)
            case .downloading(let p):
                left += 1
                bytes += p.bytes
                total = Self.plus(total, p.total ?? track.expected)
            default:
                break
            }
        }
        return (left, bytes, left == 0 ? nil : total)
    }

    @ObservationIgnored let store: OfflineStore
    @ObservationIgnored let queue: OfflineQueue
    @ObservationIgnored let transport: (any OfflineTransport)?
    @ObservationIgnored let clock: any PipelineClock
    @ObservationIgnored let client: @MainActor () -> any CobaltClient
    @ObservationIgnored let isPreview: Bool
    /// The photos album and the Mac folder must not copy what lands here: their keys are marked "already there"
    /// before the file lands (set by `AppModel`).
    @ObservationIgnored var markNotNew: (@MainActor ([String]) async -> Void)?
    /// Something landed (the photos sync runs).
    @ObservationIgnored var landed: (@MainActor () async -> Void)?
    /// A download ended `gone` (every place that might have the file said so): the pull writes its ledger entry `skipped`
    /// (CONTRACT-OFFLINE.md 13.8). Only called for that failure.
    @ObservationIgnored var endedGone: (@MainActor (OfflineJob) -> Void)?

    @ObservationIgnored private var sink: OfflineEventSink?
    @ObservationIgnored private var session: (any OfflineSession)?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var foreground: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var landing: Set<String> = []

    init(
        store: OfflineStore, queue: OfflineQueue, transport: (any OfflineTransport)?, clock: any PipelineClock,
        client: @escaping @MainActor () -> any CobaltClient, isPreview: Bool = false
    ) {
        self.store = store
        self.queue = queue
        self.transport = transport
        self.clock = clock
        self.client = client
        self.isPreview = isPreview
        self.sink = Self.makeSink(self, queue: queue, inboxRoot: store.root, clock: clock)
        loadStates()
    }

    /// Built outside the main actor on purpose: the closure it carries is called by the system's delegate queue.
    nonisolated private static func makeSink(
        _ engine: OfflineDownloads, queue: OfflineQueue, inboxRoot: URL, clock: any PipelineClock
    ) -> OfflineEventSink {
        OfflineEventSink(queue: queue, inboxRoot: inboxRoot, now: { clock.now() }) { @Sendable [weak engine] event in
            Task { @MainActor in engine?.handle(event) }
        }
    }

    // MARK: - States

    private func loadStates() {
        for entry in queue.all() {
            switch entry.state {
            case .failed(let f): track(entry, .failed(f))
            default: track(entry, .waiting)
            }
        }
    }

    private func track(_ entry: OfflineEntry, _ state: RenditionOffline) {
        let aliases = Array(Set(entry.job.aliases + [entry.key]))
        var t = tracks[entry.key] ?? Track(aliases: aliases, state: state, expected: entry.job.expectedBytes)
        t.state = state
        if case .downloading(let p) = state, let total = p.total { t.expected = total }
        tracks[entry.key] = t
        for alias in t.aliases { states[alias] = state }
    }

    private func forget(_ key: String) {
        guard let t = tracks.removeValue(forKey: key) else { return }
        for alias in t.aliases { states[alias] = nil }
    }

    /// The queue's entries a rendition's keys name.
    func entries(forKeys keys: [String]) -> [OfflineEntry] {
        let wanted = Set(keys)
        return queue.all().filter { wanted.contains($0.key) || !wanted.isDisjoint(with: $0.job.aliases) }
    }

    // MARK: - Asking

    /// "keep offline": queues the jobs and starts them. A rendition already going is left alone; a failed one is
    /// revived (the retry is the same action).
    func enqueue(_ jobs: [OfflineJob]) {
        let now = clock.now()
        for job in jobs {
            let (entry, isNew) = queue.enqueue(job, now: now)
            guard isNew else { continue }
            queue.clearResume(key: entry.key)
            foreground[entry.key]?.cancel()
            foreground[entry.key] = nil
            track(entry, .waiting)
            Telemetry.log(.info, .sync, "offline queued", data: [
                "kind": .string(Self.kind(of: job)), "sources": .int(job.sources.count), "bytes": .bytes(job.expectedBytes ?? 0)])
            start(entry.key)
        }
    }

    /// "stop downloading": the task is cancelled, its resume data deleted, the entry dropped. A post-only media
    /// whose download was cancelled has no local record (nothing was added).
    func cancel(keys: [String]) {
        for entry in entries(forKeys: keys) {
            // the entry goes first: the cancel's own failure event then finds nothing and is ignored
            queue.remove(entry.key)
            forget(entry.key)
            foreground[entry.key]?.cancel()
            foreground[entry.key] = nil
            switch entry.state {
            case .downloading(let sessionID, let task, _) where sessionID != Self.foregroundSession:
                openSession()?.cancel(task: task)
            case .arrived(let file):
                try? FileManager.default.removeItem(at: file)
            default:
                break
            }
            Telemetry.log(.info, .sync, "offline cancelled")
        }
    }

    /// "stop all".
    func cancelAll() {
        cancel(keys: queue.all().filter(\.isLive).map(\.key))
    }

    // MARK: - Starting

    private func openSession() -> (any OfflineSession)? {
        if let session { return session }
        guard let transport, let sink else { return nil }
        let made = transport.session(identifier: Self.sessionIdentifier, events: sink)
        session = made
        return made
    }

    private func start(_ key: String) {
        guard let entry = queue.entry(key), case .queued = entry.state else { return }
        guard entry.sourceIndex < entry.job.sources.count else {
            fail(key, .gone)
            return
        }
        let source = entry.job.sources[entry.sourceIndex]
        guard !isPreview, let requests = client() as? any RemoteFileRequests, let session = openSession() else {
            runForeground(key)
            return
        }
        let request: URLRequest
        do {
            request = try requests.urlRequest(for: source.remoteFile)
        } catch {
            fail(key, .auth)                                    // `.noAPIKey`: nothing to ask the server with
            return
        }
        let now = clock.now()
        let task: Int
        if let resume = queue.resumeData(key: key) {
            task = session.resume(resume, label: key)
            queue.clearResume(key: key)
            Telemetry.log(.info, .sync, "offline resumed", data: ["bytes": .bytes(Int64(resume.count))])
        } else {
            task = session.start(request, label: key)
        }
        queue.update(key, now: now) { $0.state = .downloading(session: Self.sessionIdentifier, task: task, since: now) }
    }

    // MARK: - Foreground fetch (no background request available)

    private func runForeground(_ key: String) {
        guard foreground[key] == nil, let entry = queue.entry(key) else { return }
        let now = clock.now()
        queue.update(key, now: now) { $0.state = .downloading(session: Self.foregroundSession, task: 0, since: now) }
        let job = entry.job
        let sources = Array(job.sources[min(entry.sourceIndex, job.sources.count)...].map(\.remoteFile))
        let client = client()
        let dest = store.inboxURL(for: job.fileName)
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.progressed(key, p) }
        foreground[key] = Task { @MainActor [weak self] in
            do {
                let file = try await Self.fetch(sources, client: client, to: dest) { relay.push($0) }
                guard let self, !Task.isCancelled, self.queue.entry(key) != nil else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                self.queue.update(key, now: self.clock.now()) { $0.state = .arrived(file: file) }
                self.foreground[key] = nil
                await self.land(key)
            } catch {
                guard let self, !(error is CancellationError) else { return }
                self.foreground[key] = nil
                self.foregroundFailed(key, error)
            }
        }
    }

    /// The first place that has it: the sources in order, moving on when one says "not here". Throws the last
    /// error when none has it.
    nonisolated static func fetch(
        _ sources: [RemoteFile], client: any CobaltClient, to destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        var last: Error = CobaltError.invalidResponse(httpStatus: 404)
        for source in sources {
            try Task.checkCancellation()
            do {
                return try await client.download(source, to: destination, progress: progress)
            } catch {
                last = error
                guard OfflineSources.isGone(error) else { throw error }
            }
        }
        throw last
    }

    private func foregroundFailed(_ key: String, _ error: Error) {
        guard queue.entry(key) != nil else { return }
        if OfflineSources.isDiskFull(error) { fail(key, .full); return }
        switch error {
        case CobaltError.noAPIKey:
            fail(key, .auth)
        case CobaltError.api(let code, let status):
            if status == 401 || status == 403 || code.hasPrefix("error.api.auth.") { fail(key, .auth) }
            else if OfflineSources.isGone(error) { fail(key, .gone) }
            else { transient(key, .other(status)) }
        case CobaltError.invalidResponse(let status):
            if status == 401 || status == 403 { fail(key, .auth) }
            else if OfflineSources.isGone(error) { fail(key, .gone) }
            else { transient(key, .other(status)) }
        case CobaltError.network(let code):
            if code == .cancelled { return }
            transient(key, .unreachable)
        case CobaltError.cancelled:
            return
        case let e as URLError:
            if e.code == .cancelled { return }
            transient(key, .unreachable)
        default:
            transient(key, .other(0))
        }
    }

    private func progressed(_ key: String, _ p: TransferProgress) {
        guard queue.entry(key) != nil else { return }
        if let entry = queue.entry(key) { track(entry, .downloading(p)) }
    }

    // MARK: - Events from the session (main actor)

    func handle(_ event: OfflineEvent) {
        switch event {
        case .progress(let key, let task, let p):
            guard let entry = queue.entry(key), case .downloading(_, let current, _) = entry.state, current == task else { return }
            track(entry, .downloading(p))
        case .arrived(let key):
            Task { await land(key) }
        case .httpFailed(let key, let task, let status):
            guard let entry = queue.entry(key), OfflineEventSink.isCurrent(entry, task: task) else { return }
            httpFailed(entry, status: status)
        case .failed(let key, let task, let domain, let code, let hadResume):
            guard let entry = queue.entry(key), OfflineEventSink.isCurrent(entry, task: task) else { return }
            taskFailed(entry, domain: domain, code: code, hadResume: hadResume)
        }
    }

    private func httpFailed(_ entry: OfflineEntry, status: Int) {
        let key = entry.key
        switch status {
        case 401, 403:
            fail(key, .auth)
        case 404, 409, 410:
            nextSource(key)
        case 412, 416:
            // the file changed under a resume: start that source over
            queue.clearResume(key: key)
            transient(key, .other(status))
        default:
            transient(key, .other(status))
        }
    }

    private func taskFailed(_ entry: OfflineEntry, domain: String, code: Int, hadResume: Bool) {
        let key = entry.key
        if OfflineSources.isDiskFull(domain: domain, code: code) { fail(key, .full); return }
        if code == NSURLErrorCancelled, domain == NSURLErrorDomain {
            // Our own cancel dropped the entry first, so an entry that is still here was cancelled by the system
            // (the owner swiped the app away): with resume data it restarts from it, without it starts over.
            transient(key, .unreachable)
            return
        }
        transient(key, domain == NSURLErrorDomain && OfflineSources.isNetworkLoss(code) ? .unreachable : .other(code))
    }

    /// 404 / 409 / 410: the next place; none left means gone.
    private func nextSource(_ key: String) {
        queue.clearResume(key: key)
        guard let updated = queue.update(key, now: clock.now(), { e in
            e.sourceIndex += 1
            e.tries = 0
            e.state = .queued
        }) else { return }
        guard updated.sourceIndex < updated.job.sources.count else {
            fail(key, .gone)
            return
        }
        track(updated, .waiting)
        start(key)
    }

    /// A try that did not work and may next time: counted, retried on the next foreground (`reconcile`), and after
    /// `maxTries` it is `failed`.
    private func transient(_ key: String, _ failure: OfflineFailure) {
        guard let updated = queue.update(key, now: clock.now(), { e in
            e.tries += 1
            e.state = e.tries >= Self.maxTries ? .failed(failure) : .queued
        }) else { return }
        if case .failed = updated.state {
            queue.clearResume(key: key)
            track(updated, .failed(failure))
            Telemetry.log(.warn, .sync, "offline failed", data: ["reason": .string("\(failure)"), "tries": .int(updated.tries)])
        } else {
            track(updated, .waiting)
        }
    }

    private func fail(_ key: String, _ failure: OfflineFailure) {
        queue.clearResume(key: key)
        guard let updated = queue.update(key, now: clock.now(), { $0.state = .failed(failure) }) else { return }
        foreground[key] = nil
        track(updated, .failed(failure))
        Telemetry.log(.warn, .sync, "offline failed", data: ["reason": .string("\(failure)")])
        if failure == .gone { endedGone?(updated.job) }
    }

    // MARK: - Landing

    /// The file is in the inbox: into the store, kept, in the visible folder when there is one.
    func land(_ key: String) async {
        guard !landing.contains(key), let entry = queue.entry(key), case .arrived(let file) = entry.state else { return }
        landing.insert(key)
        defer { landing.remove(key) }
        guard FileManager.default.fileExists(atPath: file.path) else {
            // the inbox was swept: fetch it again
            queue.update(key, now: clock.now()) { $0.state = .queued }
            track(queue.entry(key) ?? entry, .waiting)
            start(key)
            return
        }
        // before the file lands: nothing racing the album's pass sees a "new save"
        await markNotNew?(entry.job.notNewKeys(store: store))
        let origin: AddOrigin = entry.job.isPulled ? .pulled : .keepOffline
        do {
            switch entry.job.target {
            case .existing(let id):
                _ = try await store.attach(file: file, to: id, move: true, keep: true, origin: origin)
            case .new(let n):
                // a made file the pull brings replaces this device's older one of the same kind first (R8, 13.7), so the
                // new file takes the free name
                if entry.job.isPulled { await replaceOlderMade(n) }
                let video = try await store.add(
                    file: file, kind: n.kind, media: n.media, sessionID: n.sessionID, link: n.link, remoteURL: n.remoteURL,
                    move: true, publicURL: n.publicURL, mediaID: n.mediaID, clip: nil, keep: true, createdAt: n.createdAt,
                    origin: origin, role: n.role, itemIndex: n.itemIndex, madeFrom: n.madeFrom, madeSpec: n.madeSpec,
                    libraryID: n.libraryID, postItems: n.postItems)
                if let title = n.title { await store.setTitle(title, media: video.mediaID) }
            }
        } catch OfflineStoreError.notFound {
            // the record was removed while it downloaded
            try? FileManager.default.removeItem(at: file)
            queue.remove(key)
            forget(key)
            return
        } catch {
            if OfflineSources.isDiskFull(error) {
                try? FileManager.default.removeItem(at: file)
                fail(key, .full)
            } else if let updated = queue.update(key, now: clock.now(), { $0.tries += 1 }) {
                // stays `arrived`: the next foreground tries again
                if updated.tries >= Self.maxTries {
                    try? FileManager.default.removeItem(at: file)
                    fail(key, .other((error as NSError).code))
                }
            }
            return
        }
        queue.remove(key)
        forget(key)
        Telemetry.log(.info, .sync, "offline landed", data: ["kind": .string(Self.kind(of: entry.job))])
        await landed?()
    }

    /// R8 for a pulled made file (a slideshow, a gallery image, a crop): this device's records of the same kind, in the same
    /// session or media, that are another library row go first (`OfflineStore.replaceMade`: an untouched file to the Trash on
    /// the Mac, a renamed one left as the owner's). The new row's own record, if there is one, stays.
    ///
    /// Not for a crop: the server replaces exports only (`app-routes.ts`, the made route), so crops accumulate, one per photo
    /// and several per post. A crop landing here is never "the newer one" of another crop.
    private func replaceOlderMade(_ n: OfflineJob.NewRecord) async {
        guard n.role != nil, n.role != .item,
              let kind = MadeKind(role: n.role, spec: n.madeSpec.flatMap { MadeSpec(data: $0) }), kind != .crop else { return }
        let stale = store.videos.filter { old in
            old.madeKind == kind && old.libraryID != n.libraryID
                && ((n.sessionID != nil && old.sessionID == n.sessionID) || (n.mediaID != nil && old.mediaID == n.mediaID))
        }
        for old in stale { await store.replaceMade(old.id) }
    }

    // MARK: - Foreground and wakes

    /// The app is in front (after the store's scan): land what arrived, restart what waits, re-attach to what the
    /// system still holds, and restart what it lost.
    func reconcile() async {
        guard !isPreview else { return }
        let now = clock.now()
        queue.prune(now: now)
        var attaching: [OfflineEntry] = []
        for entry in queue.all() {
            // already on the device and kept (a landing finished in another process): nothing to fetch
            if case .existing(let id) = entry.job.target, store.videos.first(where: { $0.id == id })?.isOffline == true {
                queue.remove(entry.key)
                forget(entry.key)
                continue
            }
            switch entry.state {
            case .arrived: await land(entry.key)
            case .queued: start(entry.key)
            case .failed(let f): track(entry, .failed(f))
            case .downloading(let sessionID, _, _):
                if sessionID == Self.foregroundSession {
                    if foreground[entry.key] == nil {                  // the process that fetched it is gone
                        queue.update(entry.key, now: now) { $0.state = .queued }
                        start(entry.key)
                    }
                } else {
                    attaching.append(entry)
                }
            }
        }
        guard !attaching.isEmpty, let session = openSession() else { return }
        // Events queued while the app was not running arrive once the session is attached (the first time in
        // this process): a task that finished meanwhile must not look lost.
        if !attached {
            attached = true
            await session.waitForEvents(timeout: 1)
        }
        let live = await session.liveTasks()
        for entry in attaching {
            guard let fresh = queue.entry(entry.key) else { continue }
            switch fresh.state {
            case .arrived:
                await land(fresh.key)
            case .downloading(_, let task, _):
                if live[task] == nil {
                    queue.update(fresh.key, now: now) { $0.state = .queued }
                    start(fresh.key)
                } else if tracks[fresh.key]?.state == nil {
                    track(fresh, .waiting)
                }
            default:
                break
            }
        }
    }

    /// The system woke the app for the offline session's finished tasks.
    func handleWake(identifier: String) async {
        guard identifier == Self.sessionIdentifier, let session = openSession() else { return }
        attached = true
        await session.waitForEvents(timeout: 25)
        await store.scanVisibleRoot()
        for entry in queue.all() { if case .arrived = entry.state { await land(entry.key) } }
        await landed?()
    }

    // MARK: - Previews

    /// What `AppModel.preview(.offline)` shows without any transfer: entries in the queue (so "stop downloading" and
    /// the retry work on them) with a fixed state, and no task. `reconcile()` leaves a preview alone.
    func seedPreview(_ seeds: [(job: OfflineJob, state: RenditionOffline)]) {
        let now = clock.now()
        for seed in seeds {
            queue.enqueue(seed.job, now: now)
            queue.update(seed.job.key, now: now) { entry in
                switch seed.state {
                case .failed(let f): entry.state = .failed(f)
                case .downloading: entry.state = .downloading(session: Self.foregroundSession, task: 0, since: now)
                default: break
                }
            }
            if let entry = queue.entry(seed.job.key) { track(entry, seed.state) }
        }
    }

    private static func plus(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a, let b else { return nil }
        return a + b
    }

    private static func kind(of job: OfflineJob) -> String {
        switch job.target {
        case .existing: return "existing"
        case .new(let n): return n.kind.rawValue
        }
    }
}

