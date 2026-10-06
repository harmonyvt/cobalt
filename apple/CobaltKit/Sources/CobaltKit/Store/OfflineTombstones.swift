import Foundation
import Synchronization

/// The ids cobalt itself removed from the visible folder (`remove from this iphone`, `delete everything`,
/// `remove offline copy`), newest 500, in `<hidden root>/tombstones.json`.
///
/// A duplicate the owner made in Files carries the identity tag (decision 6), so without this the next scan
/// would take it for the original coming back and undo the removal. A tagged file whose id is tombstoned and
/// that no record points at is treated as the owner's own file: never adopted, rebuilt, moved or deleted.
/// Lifted when the id is kept again (a new file for it is about to land). The file sits beside the index
/// (so it travels with the store when the fallback root moves into the app group) and only the app process,
/// the one with a visible folder, writes it.
enum OfflineTombstones {
    static let limit = 500
    static let fileName = "tombstones.json"

    private struct Entry: Codable { var id: String; var at: Double }
    private static let lock = Mutex(())

    static func url(root: URL) -> URL { root.appendingPathComponent(fileName) }

    private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func ids(root: URL) -> Set<String> {
        lock.withLock { _ in Set(read(url(root: root)).map(\.id)) }
    }

    static func add(_ ids: [String], root: URL, now: Date = Date()) {
        guard !ids.isEmpty else { return }
        lock.withLock { _ in
            var entries = read(url(root: root))
            let have = Set(entries.map(\.id))
            for id in ids where !have.contains(id) { entries.append(Entry(id: id, at: now.timeIntervalSince1970)) }
            if entries.count > limit {
                entries = Array(entries.enumerated()
                    .sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }
                    .prefix(limit).sorted { $0.offset < $1.offset }.map(\.element))
            }
            write(entries, root: root)
        }
    }

    static func remove(_ ids: Set<String>, root: URL) {
        guard !ids.isEmpty else { return }
        lock.withLock { _ in
            let entries = read(url(root: root))
            let left = entries.filter { !ids.contains($0.id) }
            if left.count != entries.count { write(left, root: root) }
        }
    }

    private static func write(_ entries: [Entry], root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url(root: root), options: .atomic) }
    }
}
