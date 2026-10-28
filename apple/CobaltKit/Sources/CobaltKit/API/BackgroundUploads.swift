import Foundation
import Synchronization

// Studio uploads (`PUT /studio/upload`) on a background URLSession (iOS). The system's transfer daemon owns the bytes:
// the upload carries on while the app is suspended, retries a dropped connection itself, and finishes even when iOS
// ends the app (2026-10-28: a 67.6 MB upload died with "network connection lost" two minutes after the app went to
// the background, on the ordinary session the continued-processing task was keeping alive).
//
// One session for every upload. A task is labelled with the tail of its file's path (the inbox copy, `<folder>/<name>`),
// so a run of the pipeline that picks an interrupted upload back up after a relaunch finds it again:
//  - still running: the run waits for that task instead of sending the file a second time;
//  - finished while no run was waiting (the app was gone): the answer was kept on disk and is returned at once.
// A task that failed while nobody waited leaves nothing, and the run uploads again.

public final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = BackgroundSessionID.upload

    /// The app's one instance (its answers are kept next to the store).
    public static let shared = BackgroundUploads(
        directory: AppGroup.location.base.appendingPathComponent("upload-answers", isDirectory: true))

    /// An upload's answer is a small JSON object; anything past this is not ours.
    static let maxBody = 64 * 1024
    /// Kept answers nobody came back for are removed after this long.
    static let keepAnswers: TimeInterval = 2 * 24 * 3600

    private struct Waiter {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var throttle: ProgressThrottle
    }

    private struct State {
        var session: URLSession?
        var waiters: [String: Waiter] = [:]
        var bodies: [Int: Data] = [:]
        var wake: EventSignal?
    }

    private let state = Mutex(State())
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
        prune()
    }

    private var session: URLSession {
        state.withLock { s in
            if let made = s.session { return made }
            let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 6 * 3600
            config.allowsCellularAccess = true
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            let made = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            s.session = made
            return made
        }
    }

    /// The label of an upload of `file`: the last two parts of its path (the inbox folder and the name), which stay the
    /// same when the app's container path changes between launches.
    static func label(for file: URL) -> String {
        file.standardizedFileURL.pathComponents.suffix(2).joined(separator: "/")
    }

    /// Sends `file` as the body of `request` and returns the server's answer. Cancelling the calling task cancels the
    /// upload.
    func upload(
        _ request: URLRequest, fromFile file: URL, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let label = Self.label(for: file)
        let throttle = ProgressThrottle(progress)
        defer { throttle.flush() }
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let previous = state.withLock { s in
                    let old = s.waiters[label]
                    s.waiters[label] = Waiter(continuation: continuation, throttle: throttle)
                    return old
                }
                previous?.continuation.resume(throwing: CancellationError())     // one run per file
                if let kept = takeKept(label) {
                    finish(label, with: .success(kept))
                    return
                }
                session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    if tasks.contains(where: { $0.taskDescription == label && $0.state == .running }) {
                        Telemetry.log(.info, .upload, "upload picked up", data: [:])
                        return                                                    // its events reach this waiter
                    }
                    guard self.state.withLock({ $0.waiters[label] != nil }) else { return }
                    let task = session.uploadTask(with: request, fromFile: file)
                    task.taskDescription = label
                    task.resume()
                }
            }
        } onCancel: {
            session.getAllTasks { tasks in
                for t in tasks where t.taskDescription == label { t.cancel() }
            }
            finish(label, with: .failure(CancellationError()))
        }
    }

    private func finish(_ label: String, with result: Result<(Data, HTTPURLResponse), Error>) {
        guard let waiter = state.withLock({ $0.waiters.removeValue(forKey: label) }) else { return }
        waiter.continuation.resume(with: result)
    }

    /// iOS launched (or woke) the app for this session's events: they are delivered to the delegate, and this returns
    /// once the system says it has no more, or after `timeout` seconds.
    public func handleWake(timeout: Double = 25) async {
        let signal = EventSignal()
        state.withLock { $0.wake = signal }
        _ = session
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await signal.wait() }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - URLSession delegate

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard let label = task.taskDescription else { return }
        let throttle = state.withLock { $0.waiters[label]?.throttle }
        throttle?.send(TransferProgress(bytes: totalBytesSent, total: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { s in
            guard (s.bodies[dataTask.taskIdentifier]?.count ?? 0) < Self.maxBody else { return }
            s.bodies[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let body = state.withLock { $0.bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let label = task.taskDescription else { return }
        if let error {
            let ns = error as NSError
            let mapped: Error = ns.domain == NSURLErrorDomain ? URLError(URLError.Code(rawValue: ns.code)) : error
            finish(label, with: .failure(mapped))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(label, with: .failure(URLError(.badServerResponse)))
            return
        }
        let waiting = state.withLock { $0.waiters[label] != nil }
        if waiting {
            finish(label, with: .success((body, http)))
        } else {
            keep(label, status: http.statusCode, body: body, url: http.url ?? task.originalRequest?.url)
            Telemetry.log(.info, .upload, "upload finished with no run waiting", data: ["status": .int(http.statusCode)])
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let wake = state.withLock { s -> EventSignal? in
            let w = s.wake
            s.wake = nil
            return w
        }
        wake?.fire()
    }

    // MARK: - Answers nobody waited for

    private struct Kept: Codable {
        var status: Int
        var body: Data
        var url: URL?
    }

    private func keptURL(_ label: String) -> URL {
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    private func keep(_ label: String, status: Int, body: Data, url: URL?) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Kept(status: status, body: body, url: url))
            try data.write(to: keptURL(label), options: .atomic)
        } catch {
            Telemetry.log(.error, .upload, "upload answer not kept", data: Telemetry.errorData(error))
        }
    }

    private func takeKept(_ label: String) -> (Data, HTTPURLResponse)? {
        let file = keptURL(label)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let kept = try? JSONDecoder().decode(Kept.self, from: data),
              let url = kept.url ?? URL(string: "https://invalid.local/"),
              let http = HTTPURLResponse(url: url, statusCode: kept.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return nil }
        return (kept.body, http)
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Self.keepAnswers)
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
