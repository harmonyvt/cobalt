import Foundation
import Synchronization
@testable import CobaltKit

// Fakes for the photos album and the background download (CONTRACT-SYNC.md section 8): no PhotoKit,
// no URLSession.

final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {
    struct Asset: Equatable { var file: URL; var isImage: Bool }

    private let lock = NSLock()
    private var _rw: PhotosReadWrite
    private var _addOnly: PhotosAccess
    private var _assets: [String: Asset] = [:]
    private var _albums: [String: String] = [:]           // id -> title
    private var _members: [String: Set<String>] = [:]     // album id -> asset ids
    private var _log: [String] = []
    private var _errors: [any Error] = []
    private var _next = 0
    private var _nextAlbum = 0
    private var _pause: Double = 0
    private var _addCalls = 0

    /// What `requestReadWrite` answers (the owner's choice in the prompt).
    var rwAnswer: PhotosReadWrite = .authorized

    init(rw: PhotosReadWrite = .authorized, addOnly: PhotosAccess = .authorized) {
        _rw = rw
        _addOnly = addOnly
    }

    // state the tests read
    var assets: [String: Asset] { lock.withLock { _assets } }
    var albums: [String: String] { lock.withLock { _albums } }
    func members(of album: String) -> Set<String> { lock.withLock { _members[album] ?? [] } }
    var log: [String] { lock.withLock { _log } }
    func count(_ call: String) -> Int { lock.withLock { _log.filter { $0 == call }.count } }
    var addCalls: Int { lock.withLock { _addCalls } }

    // knobs
    func setAccess(rw: PhotosReadWrite, addOnly: PhotosAccess? = nil) {
        lock.withLock { _rw = rw; if let addOnly { _addOnly = addOnly } }
    }
    func failNext(_ error: any Error, times: Int = 1) { lock.withLock { for _ in 0..<times { _errors.append(error) } } }
    func slowAdds(by seconds: Double) { lock.withLock { _pause = seconds } }
    func deleteAsset(_ id: String) {
        lock.withLock {
            _assets[id] = nil
            for k in _members.keys { _members[k]?.remove(id) }
        }
    }
    func seedAsset(_ id: String, file: URL = URL(fileURLWithPath: "/seed.mp4")) { lock.withLock { _assets[id] = Asset(file: file, isImage: false) } }
    @discardableResult
    func seedAlbum(title: String) -> String {
        lock.withLock {
            _nextAlbum += 1
            let id = "ALBUM-\(_nextAlbum)"
            _albums[id] = title
            return id
        }
    }
    func renameAlbum(_ id: String, to title: String) { lock.withLock { _albums[id] = title } }
    func deleteAlbum(_ id: String) { lock.withLock { _albums[id] = nil; _members[id] = nil } }
    func removeFromAlbum(_ asset: String, album: String) { lock.withLock { _members[album]?.remove(asset) } }

    // PhotoLibrary
    func status() -> PhotosAccess { lock.withLock { _addOnly } }
    func requestAccess() async -> PhotosAccess { lock.withLock { _log.append("requestAddOnly"); return _addOnly } }
    func readWriteStatus() -> PhotosReadWrite { lock.withLock { _rw } }
    func requestReadWrite() async -> PhotosReadWrite {
        lock.withLock {
            _log.append("requestReadWrite")
            _rw = rwAnswer
            if rwAnswer == .authorized || rwAnswer == .limited { _addOnly = .authorized }
            return _rw
        }
    }

    func add(fileURL: URL, isImage: Bool) async throws -> String? {
        try await addAsset(fileURL: fileURL, isImage: isImage, albumID: nil, placeholder: { _ in })
    }

    func addAsset(
        fileURL: URL, isImage: Bool, albumID: String?, placeholder: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let pause = lock.withLock { _pause }
        if pause > 0 { try? await Task.sleep(for: .milliseconds(Int(pause * 1000))) }
        let (id, error): (String, (any Error)?) = lock.withLock {
            _addCalls += 1
            _log.append("addAsset")
            if !_errors.isEmpty { return ("", _errors.removeFirst()) }
            _next += 1
            return ("ASSET-\(_next)", nil)
        }
        if let error { throw error }
        placeholder(id)
        lock.withLock {
            _assets[id] = Asset(file: fileURL, isImage: isImage)
            if let albumID { _members[albumID, default: []].insert(id) }
            if albumID != nil { _log.append("addedToAlbum") }
        }
        return id
    }

    func existingAssets(among ids: [String]) -> Set<String> {
        lock.withLock { _log.append("existingAssets"); return Set(ids.filter { _assets[$0] != nil }) }
    }

    func findAlbum(id: String?, title: String) -> PhotosAlbum? {
        lock.withLock {
            _log.append("findAlbum")
            if let id, let t = _albums[id] { return PhotosAlbum(id: id, title: t) }
            if let hit = _albums.first(where: { $0.value == title }) { return PhotosAlbum(id: hit.key, title: hit.value) }
            return nil
        }
    }

    func createAlbum(title: String) async throws -> PhotosAlbum {
        lock.withLock {
            _log.append("createAlbum")
            _nextAlbum += 1
            let id = "ALBUM-\(_nextAlbum)"
            _albums[id] = title
            return PhotosAlbum(id: id, title: title)
        }
    }

    func addToAlbum(assetIDs: [String], albumID: String) async throws {
        lock.withLock {
            _log.append("addToAlbum")
            _members[albumID, default: []].formUnion(assetIDs.filter { _assets[$0] != nil })
        }
    }
}

// MARK: - Background transport

/// A background session you drive by hand: tasks sit until the test completes, fails or answers them.
final class FakeBackgroundTransport: BackgroundTransport, @unchecked Sendable {
    final class Session: BackgroundSession, @unchecked Sendable {
        struct Task: Equatable { var id: Int; var request: URLRequest; var label: String }
        let identifier: String
        weak var events: (any BackgroundDownloadEvents)?
        private let lock = NSLock()
        private var _tasks: [Task] = []
        private var _live: Set<Int> = []
        private var _next = 0
        private var _eventsDone = false

        init(identifier: String, events: any BackgroundDownloadEvents) {
            self.identifier = identifier
            self.events = events
        }

        var tasks: [Task] { lock.withLock { _tasks } }
        var liveIDs: Set<Int> { lock.withLock { _live } }

        func start(_ request: URLRequest, label: String) -> Int {
            lock.withLock {
                _next += 1
                _tasks.append(Task(id: _next, request: request, label: label))
                _live.insert(_next)
                return _next
            }
        }

        func liveTasks() async -> [Int: String] {
            lock.withLock {
                var out: [Int: String] = [:]
                for t in _tasks where _live.contains(t.id) { out[t.id] = t.label }
                return out
            }
        }

        func waitForEvents(timeout: Double) async {}

        func cancel(task id: Int) { lock.withLock { _ = _live.remove(id) } }

        /// The server answered: status and body. The delegate callback runs inline.
        func respond(task id: Int, status: Int, body: Data) {
            guard let task = lock.withLock({ _tasks.first { $0.id == id } }) else { return }
            lock.withLock { _ = _live.remove(id) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-bg-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("CFNetworkDownload.tmp")
            try? body.write(to: file)
            events?.downloadFinished(identifier: identifier, task: id, label: task.label, status: status, file: file)
            try? FileManager.default.removeItem(at: dir)        // the system deletes what the delegate left
        }

        func fail(task id: Int, code: Int) {
            guard let task = lock.withLock({ _tasks.first { $0.id == id } }) else { return }
            lock.withLock { _ = _live.remove(id) }
            events?.downloadFailed(identifier: identifier, task: id, label: task.label, code: code)
        }

        /// The task vanished without telling anyone (a lost session).
        func lose(task id: Int) { lock.withLock { _ = _live.remove(id) } }
    }

    private let lock = NSLock()
    private var _sessions: [String: Session] = [:]
    private var _created: [String] = []

    func session(identifier: String, events: any BackgroundDownloadEvents) -> any BackgroundSession {
        lock.withLock {
            // One process at a time uses a session: whoever asks last receives its events.
            if let hit = _sessions[identifier] { hit.events = events; return hit }
            let made = Session(identifier: identifier, events: events)
            _sessions[identifier] = made
            _created.append(identifier)
            return made
        }
    }

    func session(_ identifier: String) -> Session? { lock.withLock { _sessions[identifier] } }
    var created: [String] { lock.withLock { _created } }
    var allTasks: [(session: String, task: Session.Task)] {
        lock.withLock { _sessions.flatMap { id, s in s.tasks.map { (id, $0) } } }
    }
}
