import Foundation
import Synchronization

// The background download of an original (CONTRACT-SYNC.md decision 6). The share sheet hands the
// download to a background `URLSession` before it closes; the task outlives the extension, and
// when it finishes iOS wakes the app (`AppModel.handleBackgroundDownloads`), which moves the file
// into the offline store. `PendingOriginals` is the ledger; this file is the engine; the seam to
// URLSession is `BackgroundTransport`, so tests drive it with a fake.

// MARK: - The seam

/// What a background session reports. Called on the session's delegate queue, not the main actor.
protocol BackgroundDownloadEvents: AnyObject, Sendable {
    /// A task finished with a response. The callee must move `file` before returning: the system
    /// deletes it right after.
    func downloadFinished(identifier: String, task: Int, label: String, status: Int, file: URL)
    /// A task ended with an error (`NSURLErrorCancelled` included).
    func downloadFailed(identifier: String, task: Int, label: String, code: Int)
    /// The system delivered every event it had queued for the session.
    func eventsFinished(identifier: String)
}

protocol BackgroundSession: Sendable {
    /// Starts a download task labelled `label` (the studio session id); returns its task identifier.
    func start(_ request: URLRequest, label: String) -> Int
    /// The tasks still running or waiting, by identifier, with their labels.
    func liveTasks() async -> [Int: String]
    /// Returns when the system has delivered its queued events for this session, or after `timeout`.
    func waitForEvents(timeout: Double) async
    func cancel(task: Int)
}

protocol BackgroundTransport: Sendable {
    /// The session with this identifier, delivering to `events`. Asking again returns the same one.
    func session(identifier: String, events: any BackgroundDownloadEvents) -> any BackgroundSession
}

// MARK: - The fetcher

/// Starts, tracks and lands the originals of `PendingOriginals`. One per process: the app uses
/// `com.capybaraharmony.cobalt.bg.app`, each share-sheet run `…bg.share.<job uuid>`.
final class OriginalFetcher: BackgroundDownloadEvents, @unchecked Sendable {
    /// The server holds a request this long when `source_wait` is on (CONTRACT-SYNC.md section 5).
    static let waitSeconds = 90
    /// Wakes may restart a task at most this often per entry: the system rate-limits them (F4).
    static let backgroundRestartLimit = 2

    let identifier: String
    let transport: any BackgroundTransport
    let pending: PendingOriginals
    let clock: any PipelineClock
    private let inboxRoot: URL
    let store: OfflineStore

    /// The app is in the foreground. Background wakes restart a task at most twice; a foreground
    /// restart is never rate-limited, so it waits for `reconcile()`.
    @MainActor var isActive: () -> Bool = { true }
    /// The server's `features.source_wait` as the app knows it now (entries record it when queued).
    @MainActor var serverHoldsRequests: () -> Bool = { false }
    /// Something landed in the store (the photos sync runs).
    @MainActor var landed: (() async -> Void)?

    private let sessions = Mutex<[String: any BackgroundSession]>([:])
    @MainActor private var ingesting: Set<String> = []

    // Instant share (CONTRACT-SHARE-QUICK.md section 9; `OriginalFetcher+Shares.swift`). Seams so tests
    // run without URLSession, a server or the app's settings.
    /// The background sessions of the extension's `POST /studio` requests, as the app re-attaches to them
    /// when the system wakes it.
    var saveTransport: any SaveTransport = URLSessionSaveTransport(mode: .background)
    /// What the extension's request answered, while the app was not running (filled off the main actor).
    let saveAnswers = SaveAnswers()
    /// Ask the server for the share-sheet saves on every foreground. iOS only: the Mac has no share
    /// extension, and must not pull the phone's videos into its own store.
    @MainActor var discoversShares: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()
    /// The server's base URL, and whether a finished save should be kept on this phone.
    @MainActor var serverURL: () -> URL = { Settings.shared().serverURL }
    @MainActor var keepsOriginals: () -> Bool = { Settings.shared().keepVideosOnDevice }
    /// `GET /studio/recent`: the sessions this key created from a share sheet. Empty without a key or a
    /// server that has the route.
    @MainActor var recentShares: () async -> [StudioSession] = { await OriginalFetcher.liveRecentShares() }
    /// `GET /studio/<sid>`: a saving session's title and size, once its video lands (nil: unknown).
    @MainActor var sessionInfo: @MainActor @Sendable (String) async -> StudioSession? = { await OriginalFetcher.liveSessionInfo($0) }
    /// An instant share's request was refused or never answered: tell the owner (a local notification).
    @MainActor var instantFailed: (_ link: URL?, _ status: Int?) async -> Void = { link, status in
        await Notifications.postInstantFailed(link: link, status: status)
    }
    /// The extension's "saving to cobalt" notifications have nothing left to say once the app is in front.
    @MainActor var clearInstantNotifications: () -> Void = { Notifications.clearInstantSaving() }
    /// Where the extension left its request bodies (`Saves`): the ones a day old are deleted.
    @MainActor var savesDirectory: () -> URL = { AppGroup.directory("Saves") }

    @MainActor
    init(
        identifier: String, transport: any BackgroundTransport, pending: PendingOriginals, store: OfflineStore,
        clock: any PipelineClock
    ) {
        self.identifier = identifier
        self.transport = transport
        self.pending = pending
        self.store = store
        self.inboxRoot = store.root
        self.clock = clock
    }

    private func session(_ id: String) -> any BackgroundSession {
        if let hit = sessions.withLock({ $0[id] }) { return hit }
        let made = transport.session(identifier: id, events: self)
        return sessions.withLock { s in
            if let existing = s[id] { return existing }
            s[id] = made
            return made
        }
    }

    // MARK: Handing one over

    /// Queues the original of `sessionID` and, when a task can usefully start now, starts it. A task
    /// can start when the server holds the request until the save is ready (`sourceWait`), or the
    /// save is already ready (`saveReady`); otherwise the entry waits for the app's next foreground.
    @MainActor
    @discardableResult
    func handOff(
        session sessionID: String, link: URL?, media: MediaInfo?, sourceURL: URL, sourceWait: Bool, saveReady: Bool
    ) -> PendingOriginal {
        let now = clock.now()
        let entry = pending.enqueue(
            PendingOriginal(
                id: sessionID, link: link, media: media, sourceURL: sourceURL, sourceWait: sourceWait,
                createdAt: now, state: .queued, updatedAt: now),
            now: now)
        if case .queued = entry.state, sourceWait || saveReady {
            start(sessionID, wait: sourceWait && !saveReady, background: false)
        }
        return pending.entry(sessionID) ?? entry
    }

    /// A task for this entry's `GET /studio/<sid>/source`, on this process's own session.
    @MainActor
    func start(_ id: String, wait: Bool, background: Bool) {
        guard let entry = pending.entry(id) else { return }
        var request = URLRequest(url: Self.sourceURL(entry.sourceURL, wait: wait))
        request.httpMethod = "GET"
        let task = session(identifier).start(request, label: id)
        pending.update(id, now: clock.now()) { e in
            e.state = .downloading(session: identifier, task: task, since: clock.now())
            if background { e.backgroundStarts += 1 }
        }
    }

    static func sourceURL(_ base: URL, wait: Bool) -> URL {
        guard wait, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = (comps.queryItems ?? []).filter { $0.name != "wait" }
        items.append(URLQueryItem(name: "wait", value: String(waitSeconds)))
        comps.queryItems = items
        return comps.url ?? base
    }

    // MARK: Events (delegate queue)

    func downloadFinished(identifier: String, task: Int, label: String, status: Int, file: URL) {
        let now = clock.now()
        if status == 200 {
            let name = (pending.entry(label)?.media?.name ?? label)
            let dest = OfflineStore.inboxURL(root: inboxRoot, name: "\(name).mp4")
            do {
                try FileManager.default.moveItem(at: file, to: dest)
            } catch {
                // a full disk is the usual reason: retried on the next foreground
                let code = (error as NSError).domain == NSPOSIXErrorDomain ? (error as NSError).code : (error as NSError).code
                markFailed(label, code: code, now: now)
                Task { @MainActor in self.afterNonSuccess(label) }
                return
            }
            pending.update(label, now: now) { $0.state = .arrived(file: dest) }
            Task { @MainActor in await self.ingest(label) }
            return
        }
        // Only a 200 is a video. The rest is a small JSON error.
        let code = Self.errorCode(inBodyAt: file)
        switch status {
        case 409:
            pending.update(label, now: now) { $0.state = .queued }                    // error.studio.not_ready
        case 404, 410, 422:
            pending.update(label, now: now) { $0.state = .gone(code: code ?? "http.\(status)") }
        default:
            markFailed(label, code: status, now: now)                                // 5xx and the unexpected
        }
        Task { @MainActor in self.afterNonSuccess(label) }
    }

    func downloadFailed(identifier: String, task: Int, label: String, code: Int) {
        if code == NSURLErrorCancelled { return }                                    // our own cancel
        markFailed(label, code: code, now: clock.now())
        Task { @MainActor in self.afterNonSuccess(label) }
    }

    func eventsFinished(identifier: String) {}

    private func markFailed(_ id: String, code: Int, now: Date) {
        pending.update(id, now: now) { e in
            var tries = 0
            if case .failed(_, let t) = e.state { tries = t }
            e.state = .failed(code: code, tries: tries + 1)
        }
    }

    static func errorCode(inBodyAt file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }
        struct Envelope: Decodable { struct Body: Decodable { var code: String? }; var error: Body? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code
    }

    /// A background wake that ended with "not ready" or a failure: at most twice more, then the
    /// foreground restarts it (the system's rate limiter slows every later task, F4).
    @MainActor
    private func afterNonSuccess(_ id: String) {
        guard !isActive(), let entry = pending.entry(id), entry.backgroundStarts < Self.backgroundRestartLimit else { return }
        switch entry.state {
        case .queued:
            start(id, wait: entry.sourceWait, background: true)
        case .failed(let code, let tries):
            guard code != 28, tries < PendingOriginals.maxTries else { return }       // a full disk does not mend itself
            start(id, wait: entry.sourceWait, background: true)
        default:
            break
        }
    }

    // MARK: Landing

    /// The file is in the inbox: into the offline store (which de-duplicates by session).
    @MainActor
    func ingest(_ id: String) async {
        guard !ingesting.contains(id), let entry = pending.entry(id), case .arrived(let file) = entry.state else { return }
        ingesting.insert(id)
        defer { ingesting.remove(id) }
        guard FileManager.default.fileExists(atPath: file.path) else {
            // the inbox was swept, or this entry was stored by the other process
            pending.update(id, now: clock.now()) { $0.state = .queued }
            return
        }
        let media = await enriched(entry.media ?? MediaInfo(name: id, duration: nil, width: nil, height: nil, bytes: nil, isImage: false), session: id)
        do {
            let video = try await store.add(
                file: file, kind: .original, media: media, sessionID: id, link: entry.link, remoteURL: nil, move: true)
            pending.update(id, now: clock.now()) { $0.state = .stored(id: video.id) }
            await landed?()
        } catch {
            // stays `arrived`: the next foreground tries again
        }
    }

    // MARK: Waking and reconciling

    /// The system woke the app for `identifier`'s finished tasks.
    @MainActor
    func handleWake(identifier id: String) async {
        if BackgroundSessionID.isSave(id) {
            await handleSaveWake(identifier: id)
            return
        }
        let s = session(id)
        await s.waitForEvents(timeout: 25)
        for entry in pending.all() { if case .arrived = entry.state { await ingest(entry.id) } }
        await landed?()
    }

    /// The app is in front: pick up what the extension (or a wake) left. An entry that has not landed
    /// and has no live task is started again from the foreground, where nothing is rate-limited.
    @MainActor
    func reconcile() async {
        let now = clock.now()
        for entry in pending.all() {
            switch entry.state {
            case .stored, .gone:
                continue
            case .arrived:
                await ingest(entry.id)
            case .queued:
                start(entry.id, wait: entry.sourceWait || serverHoldsRequests(), background: false)
            case .failed(_, let tries):
                if tries < PendingOriginals.maxTries { start(entry.id, wait: entry.sourceWait || serverHoldsRequests(), background: false) }
            case .downloading(let sessionID, let task, _):
                let s = session(sessionID)
                // another process's session: the events it queued arrive when it is attached
                if sessionID != identifier { await s.waitForEvents(timeout: 2) }
                guard let fresh = pending.entry(entry.id), case .downloading = fresh.state else {
                    if let fresh = pending.entry(entry.id), case .arrived = fresh.state { await ingest(entry.id) }
                    continue
                }
                if await s.liveTasks()[task] == nil {
                    start(entry.id, wait: entry.sourceWait || serverHoldsRequests(), background: false)
                }
            }
        }
        _ = now
        await discoverShares()
        pruneSaveFiles()
        clearInstantNotifications()
        await landed?()
    }

    /// The server (or the owner) says the entry's session is over: nothing more to do.
    func forget(session id: String) { pending.remove(id) }
}

// MARK: - URLSession

/// The real thing: `URLSessionConfiguration.background` with the app group as its shared container
/// (without it the system invalidates a session created in an extension).
struct URLSessionBackgroundTransport: BackgroundTransport {
    private static let cache = Mutex<[String: any BackgroundSession]>([:])

    func session(identifier: String, events: any BackgroundDownloadEvents) -> any BackgroundSession {
        if let hit = Self.cache.withLock({ $0[identifier] }) { return hit }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        // Only a process that really has the group: a re-signed build without it would hand the system a
        // container it cannot open and the session would be invalidated (the app then simply downloads
        // from the foreground, where nothing is rate-limited).
        if AppGroup.location.kind == .appGroup { config.sharedContainerIdentifier = AppGroup.id }
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 15 * 60
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        let delegate = BackgroundDelegate(identifier: identifier, events: events)
        let urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let made = SystemBackgroundSession(session: urlSession, delegate: delegate)
        return Self.cache.withLock { c in
            if let existing = c[identifier] { return existing }
            c[identifier] = made
            return made
        }
    }
}

private final class SystemBackgroundSession: BackgroundSession, @unchecked Sendable {
    let session: URLSession
    let delegate: BackgroundDelegate

    init(session: URLSession, delegate: BackgroundDelegate) {
        self.session = session
        self.delegate = delegate
    }

    func start(_ request: URLRequest, label: String) -> Int {
        let task = session.downloadTask(with: request)
        task.taskDescription = label
        task.resume()
        return task.taskIdentifier
    }

    func liveTasks() async -> [Int: String] {
        let (_, _, downloads) = await session.tasks
        var out: [Int: String] = [:]
        for t in downloads where t.state == .running || t.state == .suspended { out[t.taskIdentifier] = t.taskDescription ?? "" }
        return out
    }

    func waitForEvents(timeout: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.delegate.eventsSignal.wait() }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
    }

    func cancel(task id: Int) {
        Task { [session] in
            let (_, _, downloads) = await session.tasks
            downloads.first { $0.taskIdentifier == id }?.cancel()
        }
    }
}

/// Resumes its waiters once fired, or when a waiter is cancelled.
final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters = [:]
        lock.unlock()
        for c in pending.values { c.resume() }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if fired { lock.unlock(); c.resume(); return }
                waiters[id] = c
                lock.unlock()
                if Task.isCancelled {
                    lock.lock()
                    let mine = waiters.removeValue(forKey: id)
                    lock.unlock()
                    mine?.resume()
                }
            }
        } onCancel: {
            lock.lock()
            let mine = waiters.removeValue(forKey: id)
            lock.unlock()
            mine?.resume()
        }
    }
}

private final class BackgroundDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let identifier: String
    let events: any BackgroundDownloadEvents
    let eventsSignal = EventSignal()
    private let finished = Mutex<Set<Int>>([])

    init(identifier: String, events: any BackgroundDownloadEvents) {
        self.identifier = identifier
        self.events = events
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        finished.withLock { _ = $0.insert(downloadTask.taskIdentifier) }
        events.downloadFinished(
            identifier: identifier, task: downloadTask.taskIdentifier, label: downloadTask.taskDescription ?? "",
            status: status, file: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let already = finished.withLock { $0.remove(task.taskIdentifier) != nil }
        guard !already, let error else { return }
        events.downloadFailed(
            identifier: identifier, task: task.taskIdentifier, label: task.taskDescription ?? "",
            code: (error as NSError).code)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.eventsFinished(identifier: identifier)
        eventsSignal.fire()
    }
}
