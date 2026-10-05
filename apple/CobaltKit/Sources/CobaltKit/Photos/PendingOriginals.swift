import Foundation

/// One original the share sheet handed to a background download (CONTRACT-SYNC.md decision 6).
struct PendingOriginal: Codable, Equatable, Sendable, Identifiable {
    enum State: Codable, Equatable, Sendable {
        /// Waiting for a task: the save was not ready and the server cannot hold the request, or a
        /// task answered "not ready".
        case queued
        case downloading(session: String, task: Int, since: Date)
        /// The file is in the store's inbox; `store.add` has not run yet (or did not finish).
        case arrived(file: URL)
        case stored(id: String)
        case failed(code: Int, tries: Int)
        /// The server will never serve it (session gone, failed, expired).
        case gone(code: String)
    }

    /// The studio session id: one original per session.
    var id: String
    var link: URL?
    var media: MediaInfo?
    /// `GET /studio/<id>/source`, without `wait`.
    var sourceURL: URL
    /// The server could hold `?wait=` when this was queued.
    var sourceWait: Bool
    var createdAt: Date
    var state: State
    /// Tasks started from a background wake for this entry (at most 2: the system rate-limits them).
    var backgroundStarts: Int = 0
    var updatedAt: Date

    /// Something is still going to bring the file: do not start another download for this session.
    var isLive: Bool {
        switch state {
        case .queued, .downloading, .arrived: return true
        case .failed(_, let tries): return tries < PendingOriginals.maxTries
        case .stored, .gone: return false
        }
    }
}

struct PendingOriginalsFile: Codable, Equatable, Sendable {
    var items: [PendingOriginal] = []
}

/// `PendingOriginals`: the app group's `Sync/originals.json`. The share extension writes entries,
/// the background session's delegate and the app update them; every access is coordinated.
final class PendingOriginals: Sendable {
    /// Entries older than this are dropped (the session lifetime; the source answers 410 after it).
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// A stored entry only needs to outlive the race with the other process.
    static let storedRetention: TimeInterval = 24 * 60 * 60
    static let maxTries = 5

    private let file: CoordinatedFile<PendingOriginalsFile>

    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("originals.json"), empty: PendingOriginalsFile())
    }

    private static let sharedInstance = PendingOriginals(directory: AppGroup.directory("Sync"))
    static func shared() -> PendingOriginals { sharedInstance }

    func all() -> [PendingOriginal] { file.read().items }
    func entry(_ id: String) -> PendingOriginal? { file.read().items.first { $0.id == id } }
    func isLive(session id: String) -> Bool { entry(id)?.isLive ?? false }

    /// Adds the entry unless the session already has one that is still going (or done): the same
    /// session shared twice is one download. A dead entry (gone, failed for good) is replaced.
    @discardableResult
    func enqueue(_ new: PendingOriginal, now: Date) -> PendingOriginal {
        file.mutate { f in
            f.items = Self.pruned(f.items, now: now)
            if let existing = f.items.first(where: { $0.id == new.id }) {
                switch existing.state {
                case .queued, .downloading, .arrived, .stored: return existing
                case .failed(_, let tries) where tries < Self.maxTries: return existing
                default: f.items.removeAll { $0.id == new.id }
                }
            }
            f.items.append(new)
            return new
        }
    }

    @discardableResult
    func update(_ id: String, now: Date, _ body: (inout PendingOriginal) -> Void) -> PendingOriginal? {
        file.mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return nil }
            body(&f.items[i])
            f.items[i].updatedAt = now
            return f.items[i]
        }
    }

    func remove(_ id: String) {
        file.mutate { f in f.items.removeAll { $0.id == id } }
    }

    static func pruned(_ items: [PendingOriginal], now: Date) -> [PendingOriginal] {
        items.filter { item in
            if case .stored = item.state { return now.timeIntervalSince(item.updatedAt) < storedRetention }
            return now.timeIntervalSince(item.createdAt) < retention
        }
    }
}
