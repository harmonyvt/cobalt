import Foundation
import Synchronization

/// A title the server has not confirmed yet (CONTRACT-LIBRARY2 decision 4).
public struct PendingTitle: Sendable, Codable, Equatable {
    /// The file the post is anchored on (`PATCH /library/items/<id>/post`).
    public var itemID: String
    /// nil clears the custom title.
    public var title: String?
    public var queuedAt: Date

    public init(itemID: String, title: String?, queuedAt: Date) {
        self.itemID = itemID
        self.title = title
        self.queuedAt = queuedAt
    }
}

/// Titles whose `PATCH /library/items/<id>/post` failed (offline, a 5xx, a revoked key): one JSON file
/// in the app group, read and written under `NSFileCoordinator` so the app and the share extension never
/// tear it (the same shape as `SharedJobStore`). One entry per item: the newest title replaces the older.
///
/// `flush(client:)` runs on foreground, on `library.refresh()` and when a run begins. An entry is dropped
/// on a 200, on a 404 (the item is gone), on a 400 (the server will never take it), and after
/// `retention` (7 days); anything else keeps it for the next flush.
public final class TitleQueue: Sendable {
    private let fileURL: URL
    /// One flush at a time per process: a second call while one runs returns at once (the first is
    /// already sending what the second would).
    private let flushing = Mutex(false)

    /// Past this a title is not sent any more.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public init(fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.fileURL = fileURL
    }

    // MARK: - Reading and writing

    public func all() -> [PendingTitle] {
        var out: [PendingTitle] = []
        coordinate(writing: false) { url in out = Self.read(url) }
        return out
    }

    public func contains(itemID: String) -> Bool { all().contains { $0.itemID == itemID } }

    /// Remembers `title` for `itemID`, replacing what was queued for it.
    public func enqueue(itemID: String, title: String?, now: Date = Date()) {
        coordinate(writing: true) { url in
            var entries = Self.pruned(Self.read(url), now: now)
            entries.removeAll { $0.itemID == itemID }
            entries.append(PendingTitle(itemID: itemID, title: title, queuedAt: now))
            Self.write(entries, to: url)
        }
    }

    /// Forgets everything queued for `itemID` (a newer title reached the server directly).
    public func remove(itemID: String) {
        coordinate(writing: true) { url in
            var entries = Self.read(url)
            let before = entries.count
            entries.removeAll { $0.itemID == itemID }
            if entries.count != before { Self.write(entries, to: url) }
        }
    }

    /// Forgets `entry` only while it is still the queued one (a newer `enqueue` for the item survives).
    func remove(_ entry: PendingTitle) {
        coordinate(writing: true) { url in
            var entries = Self.read(url)
            let before = entries.count
            entries.removeAll { $0 == entry }
            if entries.count != before { Self.write(entries, to: url) }
        }
    }

    // MARK: - Sending

    /// Sends what is queued. Never throws: what cannot be sent stays for the next time.
    public func flush(client: any CobaltClient, now: Date = Date()) async {
        guard flushing.withLock({ busy in
            if busy { return false }
            busy = true
            return true
        }) else { return }
        defer { flushing.withLock { $0 = false } }

        let entries = all()
        for entry in entries {
            if now.timeIntervalSince(entry.queuedAt) >= Self.retention { remove(entry); continue }
            if Task.isCancelled { return }
            do {
                _ = try await client.setTitle(anchor: entry.itemID, entry.title)
                remove(entry)
            } catch {
                if Self.isFinal(error) { remove(entry) }
                else { Telemetry.log(.warn, .net, "title not sent", data: Telemetry.errorData(error)) }
            }
        }
    }

    /// The server's answer will not change by asking again: the item is gone (404) or the title is not
    /// one it takes (400).
    static func isFinal(_ error: Error) -> Bool {
        if let failure = error as? PipelineFailure, case .server(let code) = failure {
            return code == "error.library.not_found" || code == "error.library.bad_title"
        }
        if let e = error as? CobaltError {
            switch e {
            case .api(_, let status), .invalidResponse(let status): return status == 404 || status == 400
            default: return false
            }
        }
        return false
    }

    static func pruned(_ entries: [PendingTitle], now: Date) -> [PendingTitle] {
        entries.filter { now.timeIntervalSince($0.queuedAt) < retention }
    }

    // MARK: -

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error, byAccessor: body)
        }
    }

    private static func read(_ url: URL) -> [PendingTitle] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PendingTitle].self, from: data)) ?? []
    }

    private static func write(_ entries: [PendingTitle], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
