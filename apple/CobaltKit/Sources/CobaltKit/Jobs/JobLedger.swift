import Foundation

/// Jobs that have no server session yet (CONTRACT-PARALLEL.md 3.5): between `JobQueue.add` and the server's `201`,
/// an upload still copying or sending, and every waiting job when the server has no line. A JSON file in Application
/// Support (not the app group: only this process writes it). An entry is written on add, removed when the job gets its
/// session or ends; on launch what is left goes back in. Entries older than 24 hours are dropped.
///
/// The file is read off the main thread, not in the initializer: `shared()` starts the read at launch (`boot()`), so the
/// first frame never waits for it. A call that needs the entries before that read lands (a job added in the first moments)
/// reads the file itself, once, so a write never replaces entries it has not seen.
@MainActor
final class JobLedger {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        enum Input: Codable, Equatable, Sendable {
            case link(URL)
            /// The copy in the app's inbox (never the picked file: its access ended with the last launch).
            case file(path: String, name: String, bytes: Int64, contentType: String, photosAssetID: String?)
        }

        var id: UUID
        var input: Input
        var options: JobOptions
        var via: JobVia
        var addedAt: Date
    }

    static let maxAge: TimeInterval = 24 * 60 * 60

    private let fileURL: URL
    private let now: () -> Date
    /// The entries once read (nil until then).
    private var loaded: [Entry]?
    /// The read `boot()` started, while it runs.
    private var loading: Task<Void, Never>?

    /// What the ledger holds. Asked before the background read landed: read here, on the calling thread, once.
    private var entries: [Entry] {
        get {
            if let loaded { return loaded }
            let url = fileURL
            let read = EngineClock.measure("launch.jobLedger.sync") { Self.read(url) }
            loaded = read
            return read
        }
        set { loaded = newValue }
    }

    /// Whether the file has been read (tests).
    var isLoaded: Bool { loaded != nil }

    /// Cheap: nothing is read until `boot()` or the first call that needs the entries.
    init(fileURL: URL, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Reads the file off the main thread (`launch.jobLedger`). Returns at once when it is read already; a read that lands
    /// after a call already read the file for itself is dropped (the entries in memory are newer).
    func boot() async {
        if loaded != nil { return }
        if let loading { return await loading.value }
        let url = fileURL
        let task = Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .userInitiated) { JobLedger.timedRead(url) }.value
            guard let self else { return }
            if self.loaded == nil { self.loaded = read }
            self.loading = nil
        }
        loading = task
        await task.value
    }

    /// Application Support/cobalt/job-ledger.json.
    static func shared() -> JobLedger {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let ledger = JobLedger(fileURL: base.appendingPathComponent("cobalt", isDirectory: true).appendingPathComponent("job-ledger.json"))
        Task { await ledger.boot() }               // off the first frame; `restoreLedger` finds it read
        return ledger
    }

    var all: [Entry] { entries }

    func add(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        write()
    }

    func remove(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        write()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries = []
        write()
    }

    /// What a launch takes back, in the order the owner added it. Anything older than 24 hours is dropped (and logged);
    /// a file whose inbox copy is gone is dropped too, and its name returned so the tray can say so.
    func takeForRelaunch() -> (entries: [Entry], goneFiles: [String]) {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var keep: [Entry] = []
        var gone: [String] = []
        var expired = 0
        for e in entries.sorted(by: { $0.addedAt < $1.addedAt }) {
            if e.addedAt < cutoff { expired += 1; continue }
            if case .file(let path, let name, _, _, _) = e.input, !FileManager.default.fileExists(atPath: path) {
                gone.append(name)
                continue
            }
            keep.append(e)
        }
        if expired > 0 { Telemetry.log(.info, .pipeline, "ledger entries expired", data: ["count": .int(expired)]) }
        // Taken: they become jobs (which write themselves again as they go).
        entries = []
        write()
        return (keep, gone)
    }

    // MARK: -

    /// `read`, timed as `launch.jobLedger` (the background read at launch).
    nonisolated private static func timedRead(_ url: URL) -> [Entry] {
        EngineClock.measure("launch.jobLedger") { read(url) }
    }

    nonisolated private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Telemetry.log(.warn, .store, "job ledger not written", data: Telemetry.errorData(error))
        }
    }
}
