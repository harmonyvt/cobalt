import Foundation
import Synchronization

// Instant share (CONTRACT-SHARE-QUICK.md section 9). The share extension shows nothing that waits: it
// reads the link, hands `POST /studio {url, public, origin: "share", notify}` to a URLSession upload and
// completes at once. This file is the engine and its seam to URLSession (a fake in tests).
//
// Two transports, chosen by what the build can do:
//  - background (the app group exists): a background session with `sharedContainerIdentifier`. The task
//    outlives the extension; when it finishes iOS wakes the app (`.backgroundTask(.urlSession)`), which
//    reads the answer (`OriginalFetcher.handleWake`). The extension does not wait for the server.
//  - foreground (no app group: a re-signed sideload): the system invalidates a background session
//    created in an extension without a shared container (NSURLSession.h, `sharedContainerIdentifier`), so
//    the request goes through an ephemeral session and the extension waits for the server's answer, which
//    `create` keeps short for a share (`SHARE_KICK_MS`), up to `foregroundWait`.

// MARK: - The seam

protocol SaveEvents: AnyObject, Sendable {
    /// The request got an answer: its status and the (small) body.
    func saveResponded(identifier: String, task: Int, label: String, status: Int, body: Data)
    /// The request ended with an error (`NSURLErrorCancelled` included).
    func saveFailed(identifier: String, task: Int, label: String, code: Int)
    /// The system delivered every event it had queued for the session.
    func saveEventsFinished(identifier: String)
}

protocol SaveSession: Sendable {
    /// Starts an upload of `file` as the request's body, labelled `label` (the link); returns its task id.
    func upload(_ request: URLRequest, from file: URL, label: String) -> Int
    /// Returns once the system holds the task (a round trip to the transfer daemon for a background session).
    func registered() async
    /// Returns when the system has delivered its queued events for this session, or after `timeout`.
    func waitForEvents(timeout: Double) async
}

protocol SaveTransport: Sendable {
    /// True: fire and forget, the system finishes the request without this process. False: the caller
    /// waits for the answer.
    var background: Bool { get }
    /// The session with this identifier, delivering to `events`. Asking again returns the same one.
    func session(identifier: String, events: any SaveEvents) -> any SaveSession
}

// MARK: - What the extension reports

public enum InstantShare {
    public enum Failure: Sendable, Equatable {
        /// No key this process can read (the keychain group did not survive a re-sign, or none was pasted).
        case noKey
        /// Nothing in what was shared is a link.
        case noLink
        /// The request could not even be written or handed to the system.
        case couldNotStart
        /// The server answered no (401: the key is not accepted; 5xx: the server is down).
        case rejected(status: Int)
        /// No connection to the server.
        case unreachable
    }

    public enum Result: Sendable, Equatable {
        /// The save is with the system or the server (the foreground transport saw a 2xx, or no answer
        /// inside its wait).
        case saved
        /// A file, or anything the instant path cannot do: the caller shows the full sheet.
        case needsSheet
        case failed(Failure)
    }
}

// MARK: - The engine

/// Builds the request, hands it to a session and says what happened. Never waits for the save itself.
struct InstantShareEngine: Sendable {
    var transport: any SaveTransport
    /// Where the request's body file goes (the app group's `Saves`, else the process's own folder).
    var directory: URL
    /// How long the foreground transport waits for the server's answer.
    var foregroundWait: Double = 10
    /// How long the background transport waits for the system to confirm it holds the task.
    var registerWait: Double = 0.6
    /// Settings "make new saves public": the request carries `public: true` (on by default).
    var makePublic = true

    func enqueue(link: LinkInfo, client: HTTPCobaltClient, job: UUID) async -> InstantShare.Result {
        let built: (request: URLRequest, body: Data)
        do {
            built = try client.shareSaveRequest(link: link.url, label: Self.label(for: link), public: makePublic)
        } catch CobaltError.noAPIKey {
            return .failed(.noKey)
        } catch {
            return .failed(.couldNotStart)
        }
        let file = directory.appendingPathComponent("\(job.uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try built.body.write(to: file, options: [.atomic])
        } catch {
            return .failed(.couldNotStart)
        }
        let sink = SaveSink()
        let session = transport.session(identifier: BackgroundSessionID.save(job: job), events: sink)
        _ = session.upload(built.request, from: file, label: link.url.absoluteString)

        if transport.background {
            // the system owns the request now; confirm it took it (it may not have before we are torn down)
            await Self.race(registerWait) { await session.registered() }
            return .saved
        }
        await Self.race(foregroundWait) { await sink.signal.wait() }
        try? FileManager.default.removeItem(at: file)
        switch sink.answer {
        case .none: return .saved                                   // no answer yet: the request is still on its way
        case .responded(let status, _): return (200..<300).contains(status) ? .saved : .failed(.rejected(status: status))
        case .failed(let code): return code == NSURLErrorCancelled ? .failed(.couldNotStart) : .failed(.unreachable)
        }
    }

    /// `instagram · Dc2QA4ng-US`, as the sheet's chip reads, cleaned for the server's label rule (at most 60
    /// characters, no control characters).
    static func label(for link: LinkInfo) -> String {
        func clean(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.generalCategory != .control }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let service = clean(link.service)
        let ref = clean(link.ref)
        let whole = ref.isEmpty ? service : "\(service) · \(ref)"
        return String(whole.prefix(60))
    }

    /// `work`'s answer, or nil when it takes longer than `seconds`.
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Runs `body` and returns when it ends or `seconds` pass, whichever is first.
    static func race(_ seconds: Double, _ body: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// Keeps the first answer of a request made in this process (the foreground transport).
final class SaveSink: SaveEvents, @unchecked Sendable {
    enum Answer: Sendable, Equatable { case responded(status: Int, body: Data), failed(code: Int) }
    private let state = Mutex<Answer?>(nil)
    let signal = EventSignal()

    var answer: Answer? { state.withLock { $0 } }

    func saveResponded(identifier: String, task: Int, label: String, status: Int, body: Data) {
        state.withLock { if $0 == nil { $0 = .responded(status: status, body: body) } }
        signal.fire()
    }

    func saveFailed(identifier: String, task: Int, label: String, code: Int) {
        state.withLock { if $0 == nil { $0 = .failed(code: code) } }
        signal.fire()
    }

    func saveEventsFinished(identifier: String) {}
}

// MARK: - URLSession

/// The real thing. `background` needs the app group (see the file's header); `foreground` is an ephemeral
/// session that lives as long as the process does.
struct URLSessionSaveTransport: SaveTransport {
    enum Mode: Sendable { case background, foreground }
    var mode: Mode

    private static let cache = Mutex<[String: any SaveSession]>([:])

    /// What this build can do: background with the app group, else the foreground wait.
    static var current: URLSessionSaveTransport {
        URLSessionSaveTransport(mode: AppGroup.location.kind == .appGroup ? .background : .foreground)
    }

    var background: Bool { mode == .background }

    func session(identifier: String, events: any SaveEvents) -> any SaveSession {
        if let hit = Self.cache.withLock({ $0[identifier] }) { return hit }
        let config: URLSessionConfiguration
        switch mode {
        case .background:
            config = URLSessionConfiguration.background(withIdentifier: identifier)
            if AppGroup.location.kind == .appGroup { config.sharedContainerIdentifier = AppGroup.id }
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.timeoutIntervalForResource = 10 * 60
        case .foreground:
            config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForResource = 30
        }
        config.timeoutIntervalForRequest = 60
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        let delegate = SaveDelegate(identifier: identifier, events: events)
        let urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let made = SystemSaveSession(session: urlSession, delegate: delegate)
        return Self.cache.withLock { c in
            if let existing = c[identifier] { return existing }
            c[identifier] = made
            return made
        }
    }
}

private final class SystemSaveSession: SaveSession, @unchecked Sendable {
    let session: URLSession
    let delegate: SaveDelegate

    init(session: URLSession, delegate: SaveDelegate) {
        self.session = session
        self.delegate = delegate
    }

    func upload(_ request: URLRequest, from file: URL, label: String) -> Int {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = label
        task.resume()
        return task.taskIdentifier
    }

    func registered() async {
        _ = await session.tasks
    }

    func waitForEvents(timeout: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.delegate.eventsSignal.wait() }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// An upload's answer arrives as data events on the session's delegate (background sessions too).
private final class SaveDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// A save's answer is a few hundred bytes; anything past this is not ours.
    static let maxBody = 16 * 1024

    let identifier: String
    let events: any SaveEvents
    let eventsSignal = EventSignal()
    private let bodies = Mutex<[Int: Data]>([:])

    init(identifier: String, events: any SaveEvents) {
        self.identifier = identifier
        self.events = events
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies.withLock { b in
            guard (b[dataTask.taskIdentifier]?.count ?? 0) < Self.maxBody else { return }
            b[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let body = bodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
        let label = task.taskDescription ?? ""
        if let error {
            events.saveFailed(identifier: identifier, task: task.taskIdentifier, label: label, code: (error as NSError).code)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        events.saveResponded(identifier: identifier, task: task.taskIdentifier, label: label, status: status, body: body)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.saveEventsFinished(identifier: identifier)
        eventsSignal.fire()
    }
}
