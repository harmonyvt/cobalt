import Foundation
import Synchronization

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

    /// What the app's own `OriginalFetcher` can do for an entry that is going (Phase 3: the activity list offers "stop" and
    /// "try again" on a row of this ledger). The task belongs to a `URLSession` only the fetcher holds, so the fetcher installs
    /// these in its `init`. Not part of the ledger file.
    struct Controls: Sendable {
        var cancel: @Sendable (_ session: String) -> Void
        var retry: @Sendable (_ session: String) -> Void
    }
    private let controls = Mutex<Controls?>(nil)
    private let observers = Mutex<[UUID: @Sendable () -> Void]>([:])

    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("originals.json"), empty: PendingOriginalsFile())
    }

    private static let sharedInstance = PendingOriginals(directory: AppGroup.directory("Sync"))
    static func shared() -> PendingOriginals { sharedInstance }

    /// Runs `body` (from any thread) after this process changes the ledger. A write by the other process (the share extension)
    /// is not announced: it shows on the next read, and `OfflineDownloads.reconcile` asks again whenever the app is in front.
    @discardableResult
    func observe(_ body: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers.withLock { $0[id] = body }
        return id
    }

    func stopObserving(_ id: UUID) { observers.withLock { _ = $0.removeValue(forKey: id) } }

    private func changed() {
        let all = observers.withLock { Array($0.values) }
        for body in all { body() }
    }

    func install(_ controls: Controls) { self.controls.withLock { $0 = controls } }

    /// "stop" on a pending original. The fetcher cancels the task and drops the entry; without one (no fetcher in this process)
    /// only an entry nothing is going to bring any more is dropped.
    func cancel(session id: String) {
        if let controls = controls.withLock({ $0 }) {
            controls.cancel(id)
        } else if let entry = entry(id), !entry.isLive {
            remove(id)
        }
    }

    /// "try again" on a pending original that gave up. Needs the fetcher (it starts the task); nothing happens without one.
    func retry(session id: String) { controls.withLock { $0 }?.retry(id) }

    func all() -> [PendingOriginal] { file.read().items }
    func entry(_ id: String) -> PendingOriginal? { file.read().items.first { $0.id == id } }
    func isLive(session id: String) -> Bool { entry(id)?.isLive ?? false }

    /// Adds the entry unless the session already has one that is still going (or done): the same
    /// session shared twice is one download. A dead entry (gone, failed for good) is replaced.
    @discardableResult
    func enqueue(_ new: PendingOriginal, now: Date) -> PendingOriginal {
        defer { changed() }
        return file.mutate { f in
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
        defer { changed() }
        return file.mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return nil }
            body(&f.items[i])
            f.items[i].updatedAt = now
            return f.items[i]
        }
    }

    func remove(_ id: String) {
        defer { changed() }
        file.mutate { f in f.items.removeAll { $0.id == id } }
    }

    static func pruned(_ items: [PendingOriginal], now: Date) -> [PendingOriginal] {
        items.filter { item in
            if case .stored = item.state { return now.timeIntervalSince(item.updatedAt) < storedRetention }
            return now.timeIntervalSince(item.createdAt) < retention
        }
    }
}
