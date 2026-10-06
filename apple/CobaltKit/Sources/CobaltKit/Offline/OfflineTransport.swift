import Foundation
import Synchronization

// The seam between "keep offline" and `URLSession` (CONTRACT-OFFLINE.md decision 9). It is `BackgroundTransport`
// grown a progress callback and resume data; `OriginalFetcher`'s own seam is left exactly as it is. Tests drive
// the engine with a fake session; the real one is `URLSessionOfflineTransport`.

/// What a background session reports. Called on the session's delegate queue, never the main actor.
protocol OfflineDownloadEvents: AnyObject, Sendable {
    /// Bytes written so far (every few KB: the receiver throttles).
    func progress(task: Int, label: String, bytes: Int64, total: Int64?)
    /// A task finished with a response. The callee must move `file` before returning: the system deletes it right
    /// after. Any status can arrive here; only a 2xx is a file.
    func finished(task: Int, label: String, status: Int, file: URL)
    /// A task ended with an error (`NSURLErrorCancelled` included). `resumeData` is what the system could keep of
    /// the transfer, when it could.
    func failed(task: Int, label: String, domain: String, code: Int, resumeData: Data?)
    /// The system delivered every event it had queued for the session.
    func eventsFinished()
}

protocol OfflineSession: Sendable {
    /// Starts a download task labelled `label` (the rendition's key); returns its task identifier.
    func start(_ request: URLRequest, label: String) -> Int
    /// Restarts an interrupted transfer from its resume data.
    func resume(_ data: Data, label: String) -> Int
    /// The tasks still running or waiting, by identifier, with their labels.
    func liveTasks() async -> [Int: String]
    /// Returns when the system has delivered its queued events for this session, or after `timeout`.
    func waitForEvents(timeout: Double) async
    func cancel(task: Int)
}

protocol OfflineTransport: Sendable {
    /// The session with this identifier, delivering to `events`. Asking again returns the same one.
    func session(identifier: String, events: any OfflineDownloadEvents) -> any OfflineSession
}

// MARK: - URLSession

/// The real thing: `URLSessionConfiguration.background` with the app group's shared container when this process
/// has one (without it the system invalidates a session created in an extension; the app's own build without the
/// group works without it).
struct URLSessionOfflineTransport: OfflineTransport {
    private static let cache = Mutex<[String: any OfflineSession]>([:])

    /// The session's configuration; tests pass an ephemeral one to run the real delegate against a loopback server.
    var configuration: @Sendable (String) -> URLSessionConfiguration = { Self.backgroundConfiguration(identifier: $0) }

    init() {}

    init(configuration: @escaping @Sendable (String) -> URLSessionConfiguration) { self.configuration = configuration }

    static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        if AppGroup.location.kind == .appGroup { config.sharedContainerIdentifier = AppGroup.id }
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // cellular and constrained networks are allowed: the owner asked for this file
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        // the rest of a long "keep everything" queue waits its turn
        config.httpMaximumConnectionsPerHost = 2
        return config
    }

    func session(identifier: String, events: any OfflineDownloadEvents) -> any OfflineSession {
        if let hit = Self.cache.withLock({ $0[identifier] }) { return hit }
        let delegate = OfflineURLDelegate(events: events)
        let urlSession = URLSession(configuration: configuration(identifier), delegate: delegate, delegateQueue: nil)
        let made = SystemOfflineSession(session: urlSession, delegate: delegate)
        return Self.cache.withLock { c in
            if let existing = c[identifier] { return existing }
            c[identifier] = made
            return made
        }
    }
}

private final class SystemOfflineSession: OfflineSession, @unchecked Sendable {
    let session: URLSession
    let delegate: OfflineURLDelegate

    init(session: URLSession, delegate: OfflineURLDelegate) {
        self.session = session
        self.delegate = delegate
    }

    func start(_ request: URLRequest, label: String) -> Int {
        let task = session.downloadTask(with: request)
        task.taskDescription = label
        task.resume()
        return task.taskIdentifier
    }

    func resume(_ data: Data, label: String) -> Int {
        let task = session.downloadTask(withResumeData: data)
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

    /// A plain cancel: no resume data is made, and the failure it reports (`NSURLErrorCancelled`, no resume
    /// data) is how the engine tells its own cancel from the system's (which carries resume data).
    func cancel(task id: Int) {
        Task { [session] in
            let (_, _, downloads) = await session.tasks
            downloads.first { $0.taskIdentifier == id }?.cancel()
        }
    }
}

/// Plain `NSObject` delegate with no actor: the system calls it on its own queue, and the app's callbacks
/// (progress, finish, failure) must not be inferred `@MainActor`.
private final class OfflineURLDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let events: any OfflineDownloadEvents
    let eventsSignal = EventSignal()
    private let finished = Mutex<Set<Int>>([])

    init(events: any OfflineDownloadEvents) { self.events = events }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        events.progress(
            task: downloadTask.taskIdentifier, label: downloadTask.taskDescription ?? "", bytes: totalBytesWritten,
            total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        finished.withLock { _ = $0.insert(downloadTask.taskIdentifier) }
        events.finished(
            task: downloadTask.taskIdentifier, label: downloadTask.taskDescription ?? "", status: status, file: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let already = finished.withLock { $0.remove(task.taskIdentifier) != nil }
        guard !already, let error else { return }
        let ns = error as NSError
        events.failed(
            task: task.taskIdentifier, label: task.taskDescription ?? "", domain: ns.domain, code: ns.code,
            resumeData: ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
    }

    /// A redirect to another host must not carry the key along.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.eventsFinished()
        eventsSignal.fire()
    }
}

// MARK: - Receiving events

/// What the delegate queue hands to the main actor.
enum OfflineEvent: Sendable {
    case progress(key: String, task: Int, TransferProgress)
    case arrived(key: String)
    case httpFailed(key: String, task: Int, status: Int)
    case failed(key: String, task: Int, domain: String, code: Int, hadResume: Bool)
}

/// The nonisolated receiver of a session's events. It does the two things that cannot wait for the main actor
/// (moving the system's temp file, saving resume data), then hands the rest to `deliver`, which hops to the main
/// actor. A plain `Sendable` class with only `let` state: nothing here is, or may be inferred, `@MainActor`.
final class OfflineEventSink: OfflineDownloadEvents, Sendable {
    let queue: OfflineQueue
    let inboxRoot: URL
    let now: @Sendable () -> Date
    let deliver: @Sendable (OfflineEvent) -> Void
    private let throttles = Mutex<[String: ProgressThrottle]>([:])
    /// ~4 Hz per download.
    static let progressInterval: Double = 0.25

    init(
        queue: OfflineQueue, inboxRoot: URL, now: @escaping @Sendable () -> Date,
        deliver: @escaping @Sendable (OfflineEvent) -> Void
    ) {
        self.queue = queue
        self.inboxRoot = inboxRoot
        self.now = now
        self.deliver = deliver
    }

    func progress(task: Int, label: String, bytes: Int64, total: Int64?) {
        // one throttle per task, not per label: a restart under the same label must not report the old task's id
        let id = "\(label)#\(task)"
        let throttle = throttles.withLock { t -> ProgressThrottle in
            if let hit = t[id] { return hit }
            let made = ProgressThrottle(interval: Self.progressInterval) { [deliver] p in
                deliver(.progress(key: label, task: task, p))
            }
            t[id] = made
            return made
        }
        throttle.send(TransferProgress(bytes: bytes, total: total))
    }

    func finished(task: Int, label: String, status: Int, file: URL) {
        throttles.withLock { _ = $0.removeValue(forKey: "\(label)#\(task)") }
        guard (200..<300).contains(status) else {
            deliver(.httpFailed(key: label, task: task, status: status))      // a small JSON error: the system deletes it
            return
        }
        guard let entry = queue.entry(label), Self.isCurrent(entry, task: task) else {
            try? FileManager.default.removeItem(at: file)                       // cancelled, or a task this entry has moved past
            return
        }
        let dest = OfflineStore.inboxURL(root: inboxRoot, name: entry.job.fileName)
        do {
            try FileManager.default.moveItem(at: file, to: dest)
        } catch {
            // a full disk is the usual reason
            let ns = error as NSError
            deliver(.failed(key: label, task: task, domain: ns.domain, code: ns.code, hadResume: false))
            return
        }
        queue.update(label, now: now()) { $0.state = .arrived(file: dest) }
        deliver(.arrived(key: label))
    }

    func failed(task: Int, label: String, domain: String, code: Int, resumeData: Data?) {
        throttles.withLock { _ = $0.removeValue(forKey: "\(label)#\(task)") }
        // Saved before anything else: the process may be suspended right after this callback.
        if let resumeData, !resumeData.isEmpty, let entry = queue.entry(label), Self.isCurrent(entry, task: task) {
            queue.saveResume(resumeData, key: label)
        }
        deliver(.failed(key: label, task: task, domain: domain, code: code, hadResume: resumeData?.isEmpty == false))
    }

    func eventsFinished() {}

    /// The entry is waiting on exactly this task (or has not written the task's id yet: the engine starts a task and
    /// records it a moment later).
    static func isCurrent(_ entry: OfflineEntry, task: Int) -> Bool {
        switch entry.state {
        case .downloading(_, let current, _): return current == task
        case .queued: return true
        case .arrived, .failed: return false
        }
    }
}
