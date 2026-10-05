import Foundation
import os

/// The append-only JSONL ring buffer every process of the app writes its events to (the app, the share
/// extension, the widgets). One file in the app group container, so the app can upload what an extension
/// wrote; without the container (unsigned builds, the Mac) it is the process's own Application Support.
///
/// - Process-safe without a coordinator: every event is ONE `write(2)` to a file opened `O_APPEND`, which
///   the kernel positions atomically, so lines from two processes never interleave. Rotation (rename of
///   the current segment over the previous one) happens under an `flock` on a lock file and is re-checked
///   inside the lock, so two processes that both notice a full segment rotate once.
/// - Never blocks the caller: `log` stamps the time and queues the write on a utility queue.
/// - Capped: two segments, each at most half of `Limits` (lines and bytes), so the whole buffer stays under
///   about 2000 lines / 1 MB; the oldest half goes when the newer one fills.
public final class TelemetryLog: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxLines: Int
        public var maxBytes: Int
        public init(maxLines: Int = 2000, maxBytes: Int = 1_000_000) {
            self.maxLines = maxLines
            self.maxBytes = maxBytes
        }
        var segmentLines: Int { max(1, maxLines / 2) }
        var segmentBytes: Int { max(512, maxBytes / 2) }
    }

    /// A line is never longer than this (a message and its data are trimmed until it fits).
    static let maxLineBytes = 3_000
    static let subsystem = "com.capybaraharmony.cobalt"

    let directory: URL
    public let process: TelemetryProcess
    let limits: Limits
    /// Names this instance (one per process run): the prefix of every event id.
    let runTag: String
    private let mirrorToOSLog: Bool
    private let queue = DispatchQueue(label: "com.capybaraharmony.cobalt.telemetry", qos: .utility)
    /// Marks the queue, so code already running on it can tell (and never wait on itself).
    private let queueKey = DispatchSpecificKey<Void>()
    private var onQueue: Bool { DispatchQueue.getSpecific(key: queueKey) != nil }

    // Confined to `queue`.
    private var sequence = 0
    private var currentLines: Int?
    private let encoder = JSONEncoder()

    var currentURL: URL { directory.appendingPathComponent("events.jsonl") }
    var previousURL: URL { directory.appendingPathComponent("events.1.jsonl") }
    private var lockURL: URL { directory.appendingPathComponent("events.lock") }

    public init(directory: URL, process: TelemetryProcess, limits: Limits = Limits(), mirrorToOSLog: Bool = true) {
        self.directory = directory
        self.process = process
        self.limits = limits
        self.mirrorToOSLog = mirrorToOSLog
        self.runTag = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
        queue.setSpecific(key: queueKey, value: ())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Writing

    /// Cheap and callable from anywhere: the time is taken now, the file is written later.
    public func log(_ level: TelemetryLevel, _ cat: TelemetryCategory, _ msg: String, data: [String: TelemetryValue] = [:]) {
        let ts = Self.nowMillis()
        queue.async { [self] in write(ts: ts, level, cat, msg, data) }
    }

    /// Waits until everything logged so far is on disk. For a background transition, a crash handler and
    /// tests; never for a hot path.
    public func flush() {
        if onQueue { return }                      // already on the queue (a handler that fired inside a write): nothing to wait for
        queue.sync {}
    }

    /// Writes the event before returning, for a handler that may be the last code to run. Safe from any
    /// thread, including the log's own queue (it then writes directly instead of waiting on itself).
    public func logNow(_ level: TelemetryLevel, _ cat: TelemetryCategory, _ msg: String, data: [String: TelemetryValue] = [:]) {
        let ts = Self.nowMillis()
        if onQueue { write(ts: ts, level, cat, msg, data) } else { queue.sync { write(ts: ts, level, cat, msg, data) } }
    }

    /// Runs `body` on the log's queue and waits (tests).
    func runOnQueue(_ body: () -> Void) { queue.sync(execute: body) }

    static func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    private func write(ts: Int64, _ level: TelemetryLevel, _ cat: TelemetryCategory, _ msg: String, _ data: [String: TelemetryValue]) {
        var event = TelemetryEvent(
            ts: ts, level: level, cat: cat,
            msg: TelemetrySanitize.truncate(msg, TelemetryLimits.messageLength),
            data: TelemetrySanitize.data(data))
        if mirrorToOSLog { Self.mirror(event) }
        sequence += 1
        let id = "\(runTag).\(String(sequence, radix: 36))"
        var line = try? encoder.encode(StoredEvent(i: id, p: process, e: event))
        if let l = line, l.count > Self.maxLineBytes {
            // too long for one atomic append: keep what identifies it, drop the rest
            event.data = [:]
            event.msg = TelemetrySanitize.truncate(event.msg, 120)
            line = try? encoder.encode(StoredEvent(i: id, p: process, e: event))
        }
        guard var bytes = line else { return }
        bytes.append(0x0A)
        append(bytes)
    }

    private func append(_ bytes: Data) {
        let fd = open(currentURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { return }
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        if let n = currentLines { currentLines = n + 1 } else { currentLines = Self.countLines(currentURL) }
        if size >= limits.segmentBytes || (currentLines ?? 0) >= limits.segmentLines {
            rotate()
            currentLines = nil
        }
    }

    /// Current segment → previous segment (replacing it), once, whichever process gets there first.
    private func rotate() {
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return }
        defer { flock(lock, LOCK_UN) }
        // another process may have rotated while this one waited for the lock
        let size = Self.fileSize(currentURL)
        guard size > 0, size >= limits.segmentBytes || Self.countLines(currentURL) >= limits.segmentLines else { return }
        _ = Darwin.rename(currentURL.path, previousURL.path)
    }

    private static func fileSize(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_size) : 0
    }

    static func countLines(_ url: URL) -> Int {
        // mapped, not read: an extension has ~120 MB and this runs in it too
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        return data.withUnsafeBytes { raw in raw.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
    }

    private static func mirror(_ event: TelemetryEvent) {
        let logger = Logger(subsystem: subsystem, category: event.cat.rawValue)
        switch event.level {
        case .debug: logger.debug("\(event.msg, privacy: .public)")
        case .info: logger.info("\(event.msg, privacy: .public)")
        case .warn: logger.warning("\(event.msg, privacy: .public)")
        case .error: logger.error("\(event.msg, privacy: .public)")
        }
    }

    // MARK: - Reading

    /// Everything in the buffer, oldest first (ties keep file order). Flushes this instance first.
    func readAll() -> [StoredEvent] {
        flush()
        let all = Self.read(previousURL) + Self.read(currentURL)
        return all.enumerated()
            .sorted { ($0.element.e.ts, $0.offset) < ($1.element.e.ts, $1.offset) }
            .map(\.element)
    }

    /// The last `limit` events at or before `ts`, optionally of one process run only, oldest first.
    func recent(limit: Int, atOrBefore ts: Int64? = nil, run: String? = nil) -> [StoredEvent] {
        var events = readAll()
        if let ts { events.removeAll { $0.e.ts > ts } }
        if let run { events.removeAll { $0.run != run } }
        return Array(events.suffix(limit))
    }

    private static func read(_ url: URL) -> [StoredEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { try? decoder.decode(StoredEvent.self, from: $0) }
    }

    /// Empties the buffer (tests, and "clear logs" if the UI ever wants it).
    func clear() {
        flush()
        try? FileManager.default.removeItem(at: currentURL)
        try? FileManager.default.removeItem(at: previousURL)
        queue.sync { currentLines = nil }
    }
}

/// Keeps an event inside the wire limits and out of trouble: short messages, at most 20 flat keys, and
/// nothing named like a secret.
enum TelemetrySanitize {
    static let maxKeyLength = 40
    static let maxStringValue = 200
    private static let secretFragments = [
        "apikey", "api-key", "api_key", "token", "secret", "password", "authorization", "cookie", "clipboard", "pasteboard",
    ]

    static func truncate(_ s: String, _ limit: Int) -> String {
        if s.utf8.count <= limit { return s }
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)) + "\u{2026}"
    }

    static func data(_ data: [String: TelemetryValue]) -> [String: TelemetryValue] {
        guard !data.isEmpty else { return [:] }
        var out: [String: TelemetryValue] = [:]
        for key in data.keys.sorted().prefix(TelemetryLimits.dataKeys) {
            guard let value = data[key] else { continue }
            let name = truncate(key, maxKeyLength)
            let lowered = name.lowercased()
            if secretFragments.contains(where: lowered.contains) {
                out[name] = .string("[redacted]")
            } else if case .string(let s) = value {
                out[name] = .string(truncate(s, maxStringValue))
            } else {
                out[name] = value
            }
        }
        return out
    }
}
