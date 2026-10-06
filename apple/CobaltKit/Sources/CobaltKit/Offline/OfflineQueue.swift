import Foundation

// The ledger of "keep offline" downloads: `Sync/offline-queue.json`, plus `Sync/offline-resume/<key>.data` for
// the resume data of an interrupted task (CONTRACT-OFFLINE.md decision 9). Same shape as `PendingOriginals`:
// one `CoordinatedFile`, so the background session's delegate (its own queue) and the app update it safely.

struct OfflineEntry: Codable, Equatable, Sendable, Identifiable {
    enum State: Codable, Equatable, Sendable {
        /// Waiting for a task: nothing started yet, or the last try failed and the next foreground restarts it.
        case queued
        /// A task of `session` is on it (`session` is `OfflineDownloads.foregroundSession` for a foreground fetch).
        case downloading(session: String, task: Int, since: Date)
        /// The file is in the store's inbox; `store.add` / `attach` has not finished (a crash, a busy store).
        case arrived(file: URL)
        /// Ended for good until the owner retries ("keep offline" again).
        case failed(OfflineFailure)
    }

    var key: String
    var job: OfflineJob
    var state: State
    /// Which of `job.sources` the current task fetches from.
    var sourceIndex: Int = 0
    /// Failures counted against `OfflineDownloads.maxTries` (network losses, 5xx, a landing that did not work).
    var tries: Int = 0
    var queuedAt: Date
    var updatedAt: Date

    var id: String { key }

    /// Something is still going to bring the file: do not start another download for this rendition.
    var isLive: Bool {
        if case .failed = state { return false }
        return true
    }
}

struct OfflineQueueFile: Codable, Equatable, Sendable {
    var entries: [OfflineEntry] = []
}

final class OfflineQueue: Sendable {
    /// A failed entry stays this long, so the detail can say what went wrong and offer the retry.
    static let failedRetention: TimeInterval = 7 * 24 * 60 * 60

    private let file: CoordinatedFile<OfflineQueueFile>
    private let resumeDirectory: URL

    /// `directory` is `Sync/` (the app group's, else the app's own).
    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("offline-queue.json"), empty: OfflineQueueFile())
        resumeDirectory = directory.appendingPathComponent("offline-resume", isDirectory: true)
    }

    var url: URL { file.url }

    func all() -> [OfflineEntry] { file.read().entries }
    func entry(_ key: String) -> OfflineEntry? { file.read().entries.first { $0.key == key } }

    /// Adds the job unless one for the same rendition is already going; a failed entry is revived (a retry).
    /// Returns the entry and whether it is new work (a task should start).
    @discardableResult
    func enqueue(_ job: OfflineJob, now: Date) -> (entry: OfflineEntry, isNew: Bool) {
        file.mutate { f in
            let keys = Set(job.aliases + [job.key])
            if let i = f.entries.firstIndex(where: { keys.contains($0.key) || !keys.isDisjoint(with: $0.job.aliases) }) {
                if f.entries[i].isLive { return (f.entries[i], false) }
                var revived = OfflineEntry(key: job.key, job: job, state: .queued, queuedAt: now, updatedAt: now)
                revived.job = job
                f.entries[i] = revived
                return (revived, true)
            }
            let entry = OfflineEntry(key: job.key, job: job, state: .queued, queuedAt: now, updatedAt: now)
            f.entries.append(entry)
            return (entry, true)
        }
    }

    @discardableResult
    func update(_ key: String, now: Date, _ body: (inout OfflineEntry) -> Void) -> OfflineEntry? {
        file.mutate { f in
            guard let i = f.entries.firstIndex(where: { $0.key == key }) else { return nil }
            body(&f.entries[i])
            f.entries[i].updatedAt = now
            return f.entries[i]
        }
    }

    @discardableResult
    func remove(_ key: String) -> OfflineEntry? {
        let removed = file.mutate { f -> OfflineEntry? in
            guard let i = f.entries.firstIndex(where: { $0.key == key }) else { return nil }
            return f.entries.remove(at: i)
        }
        clearResume(key: key)
        return removed
    }

    /// Failed entries older than `failedRetention` go.
    func prune(now: Date) {
        let gone = file.mutate { f -> [String] in
            let stale = f.entries.filter { e in
                if case .failed = e.state { return now.timeIntervalSince(e.updatedAt) > Self.failedRetention }
                return false
            }
            f.entries.removeAll { e in stale.contains { $0.key == e.key } }
            return stale.map(\.key)
        }
        for key in gone { clearResume(key: key) }
    }

    // MARK: resume data

    private func resumeURL(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return resumeDirectory.appendingPathComponent("\(safe).data")
    }

    func saveResume(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(key), options: .atomic)
    }

    func resumeData(key: String) -> Data? {
        guard let data = try? Data(contentsOf: resumeURL(key)), !data.isEmpty else { return nil }
        return data
    }

    func hasResume(key: String) -> Bool { FileManager.default.fileExists(atPath: resumeURL(key).path) }

    func clearResume(key: String) { try? FileManager.default.removeItem(at: resumeURL(key)) }
}
