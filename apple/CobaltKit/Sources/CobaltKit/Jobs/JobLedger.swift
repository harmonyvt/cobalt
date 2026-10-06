import Foundation

/// Jobs that have no server session yet (CONTRACT-PARALLEL.md 3.5): between `JobQueue.add` and the server's `201`,
/// an upload still copying or sending, and every waiting job when the server has no line. A JSON file in Application
/// Support (not the app group: only this process writes it). An entry is written on add, removed when the job gets its
/// session or ends; on launch what is left goes back in. Entries older than 24 hours are dropped.
@MainActor
final class JobLedger {
    struct Entry: Codable, Equatable, Identifiable {
        enum Input: Codable, Equatable {
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
    private var entries: [Entry]

    init(fileURL: URL, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        self.entries = Self.read(fileURL)
    }

    /// Application Support/cobalt/job-ledger.json.
    static func shared() -> JobLedger {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return JobLedger(fileURL: base.appendingPathComponent("cobalt", isDirectory: true).appendingPathComponent("job-ledger.json"))
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

    private static func read(_ url: URL) -> [Entry] {
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
