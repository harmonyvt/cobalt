import Foundation
import Synchronization

/// One JSON file two processes (the app and the share extension) read and write: every access runs
/// under `NSFileCoordinator`, like `SharedJobStore`. A read returns the in-memory copy while the
/// file's modification date and size are unchanged, so a view can ask on every redraw.
final class CoordinatedFile<Value: Codable & Sendable>: Sendable {
    private struct Cache {
        var stamp: Stamp?
        var value: Value
    }
    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int64
    }

    let url: URL
    private let empty: Value
    private let cache: Mutex<Cache>

    init(url: URL, empty: Value) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        self.empty = empty
        self.cache = Mutex(Cache(stamp: nil, value: empty))
    }

    func read() -> Value {
        let stamp = Self.stamp(of: url)
        if let hit = cache.withLock({ $0.stamp == stamp && stamp != nil ? $0.value : nil }) { return hit }
        var out = empty
        coordinate(writing: false) { url in out = Self.decode(url) ?? self.empty }
        let fresh = Self.stamp(of: url)
        cache.withLock { $0 = Cache(stamp: fresh, value: out) }
        return out
    }

    /// Read-modify-write under one coordinated write; the file is re-read first, so two writers
    /// never lose each other's change. Returns what `body` returns.
    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        var result: R?
        var final = empty
        func apply(_ url: URL) {
            var value = Self.decode(url) ?? self.empty
            result = body(&value)
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
            final = value
        }
        coordinate(writing: true, apply)
        if result == nil { apply(url) }               // the coordinator refused: still do the work, uncoordinated
        let fresh = Self.stamp(of: url)
        cache.withLock { $0 = Cache(stamp: fresh, value: final) }
        return result!
    }

    // MARK: -

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: body)
        }
    }

    private static func decode(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: attrs[.modificationDate] as? Date, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
    }
}
