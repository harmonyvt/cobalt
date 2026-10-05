import CryptoKit
import Foundation

/// A crash record together with MetricKit's JSON for it (raw bytes, or nil when there is none, as for an
/// unclean exit).
struct PendingCrash: Sendable, Equatable {
    var record: CrashRecord
    var payload: Data?
}

/// Crashes, hangs and unclean exits waiting for the next upload: one small JSON file per record, plus the
/// raw MetricKit payload beside it. The meta file is written last and atomically, so a record is either
/// whole or absent. A short tombstone list keeps a diagnostic MetricKit hands over twice from being
/// stored twice (ids are a hash of the payload).
final class CrashStore: @unchecked Sendable {
    /// Records kept at most; the oldest go first.
    static let maxRecords = 30
    private static let maxSeen = 200

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    private func payloadURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).payload") }
    private var seenURL: URL { directory.appendingPathComponent("seen.txt") }

    /// Stores a record. A record whose id is already stored, or was sent before, is ignored (false).
    @discardableResult
    func add(_ record: CrashRecord, payload: Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: metaURL(record.id).path), !seenIDs().contains(record.id) else { return false }
        var stored = record
        stored.hasPayload = payload != nil
        if let payload { try? payload.write(to: payloadURL(record.id), options: .atomic) }
        guard let meta = try? JSONEncoder().encode(stored) else {
            try? FileManager.default.removeItem(at: payloadURL(record.id))
            return false
        }
        do { try meta.write(to: metaURL(record.id), options: .atomic) } catch {
            try? FileManager.default.removeItem(at: payloadURL(record.id))
            return false
        }
        pruneLocked()
        return true
    }

    /// Oldest first.
    func pending() -> [PendingCrash] {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().map { PendingCrash(record: $0, payload: try? Data(contentsOf: payloadURL($0.id))) }
    }

    func remove(_ ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            try? FileManager.default.removeItem(at: metaURL(id))
            try? FileManager.default.removeItem(at: payloadURL(id))
        }
        rememberLocked(ids)
    }

    /// Drops one record's payload, keeping the record (a payload too big for the server).
    func dropPayload(of id: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: payloadURL(id))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().count
    }

    // MARK: - Internals (lock held)

    private func recordsLocked() -> [CrashRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(CrashRecord.self, from: $0) } }
            .sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
    }

    private func pruneLocked() {
        let all = recordsLocked()
        guard all.count > Self.maxRecords else { return }
        let drop = all.prefix(all.count - Self.maxRecords).map(\.id)
        for id in drop {
            try? FileManager.default.removeItem(at: metaURL(id))
            try? FileManager.default.removeItem(at: payloadURL(id))
        }
    }

    private func seenIDs() -> [String] {
        ((try? String(contentsOf: seenURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func rememberLocked(_ ids: [String]) {
        let all = Array((seenIDs() + ids).suffix(Self.maxSeen))
        try? all.joined(separator: "\n").write(to: seenURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - MetricKit diagnostics → records

/// Turns one MetricKit diagnostic (its JSON, untouched) into a record. The MetricKit objects themselves
/// stay in `CrashReporter`; everything here works on bytes, so a fake payload tests it.
enum DiagnosticIngest {
    /// Stores `json` as a pending record of `kind`. `at` is when it happened (the payload's end time);
    /// the record carries the last events before then. Returns false when it was a duplicate.
    @discardableResult
    static func ingest(
        _ json: Data, kind: CrashKind, at ts: Int64, into store: CrashStore, log: TelemetryLog?
    ) -> Bool {
        let digest = SHA256.hash(data: json).prefix(8).map { String(format: "%02x", $0) }.joined()
        let events = (log?.recent(limit: TelemetryLimits.crashEvents, atOrBefore: ts) ?? []).map(\.e)
        let record = CrashRecord(
            id: "mk-\(digest)", ts: ts, kind: kind, summary: summary(of: json, kind: kind), events: events, hasPayload: true)
        let added = store.add(record, payload: looksLikeJSON(json) ? json : nil)
        if added {
            log?.log(.error, .app, "diagnostic received", data: ["kind": .string(kind.rawValue), "summary": .string(record.summary)])
        }
        return added
    }

    /// One line a person can scan: what MetricKit says went wrong, from the diagnostic's own metadata.
    /// Tolerant: a payload that is not the shape expected still gets the kind's name.
    static func summary(of json: Data, kind: CrashKind) -> String {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let meta = root["diagnosticMetaData"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? {
            switch meta[key] {
            case let s as String where !s.isEmpty: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        var parts: [String] = []
        switch kind {
        case .crash:
            if let t = text("exceptionType") { parts.append("exception type \(t)") }
            if let s = text("signal") { parts.append("signal \(s)") }
            if let c = text("exceptionCode") { parts.append("code \(c)") }
            if let r = text("terminationReason") { parts.append(r) }
            if let objc = meta["objectiveCexceptionReason"] as? [String: Any], let name = objc["exceptionName"] as? String {
                parts.append(name)
            }
        case .hang: if let d = text("hangDuration") { parts.append("hung for \(d)") }
        case .cpu:
            if let t = text("totalCPUTime") { parts.append("cpu \(t)") }
            if let s = text("totalSampledTime") { parts.append("over \(s)") }
        case .disk: if let w = text("writesCaused") { parts.append("wrote \(w)") }
        case .launch: if let d = text("launchDuration") { parts.append("launch took \(d)") }
        case .uncleanExit: break
        }
        let base = parts.isEmpty ? kind.rawValue : "\(kind.rawValue): " + parts.joined(separator: ", ")
        return TelemetrySanitize.truncate(base, TelemetryLimits.summaryLength)
    }

    /// MetricKit hands over valid JSON; this only guards the splice into the request body.
    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 > 0x20 }), let last = data.last(where: { $0 > 0x20 }) else { return false }
        return (first == UInt8(ascii: "{") && last == UInt8(ascii: "}")) || (first == UInt8(ascii: "[") && last == UInt8(ascii: "]"))
    }
}

// MARK: - Unclean exit

/// The "running" marker: written when the app becomes active, cleared when it goes to the background or
/// terminates. One found at the next launch means the last session ended without either: a crash, a
/// kill, or a hang the system ended. MetricKit can take a day to say so; this says so right away.
struct RunMarker: Codable, Equatable, Sendable {
    var run: String          // the previous session's event run tag
    var startedAt: Int64
    var version: String
    var build: String
    var os: String
}

enum UncleanExit {
    static func markerURL(_ directory: URL) -> URL { directory.appendingPathComponent("running-app.json") }

    /// The previous session's marker, if it never cleared it.
    static func leftover(in directory: URL) -> RunMarker? {
        guard let data = try? Data(contentsOf: markerURL(directory)) else { return nil }
        return try? JSONDecoder().decode(RunMarker.self, from: data)
    }

    static func write(_ marker: RunMarker, in directory: URL) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: markerURL(directory), options: .atomic)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: markerURL(directory))
    }

    /// The record for a leftover marker: the last events of that session. Nil when there is no marker.
    static func record(for marker: RunMarker, current: TelemetryAppInfo, log: TelemetryLog?) -> CrashRecord {
        let events = (log?.recent(limit: TelemetryLimits.crashEvents, run: marker.run) ?? []).map(\.e)
        let ts = events.last?.ts ?? marker.startedAt
        var summary = "the app ended without going to the background (\(marker.version) \(marker.build), \(marker.os))"
        if marker.build != current.build { summary += "; now on build \(current.build)" }
        return CrashRecord(
            id: "ue-\(marker.run)-\(marker.startedAt)", ts: ts, kind: .uncleanExit,
            summary: TelemetrySanitize.truncate(summary, TelemetryLimits.summaryLength), events: events, hasPayload: false)
    }
}
