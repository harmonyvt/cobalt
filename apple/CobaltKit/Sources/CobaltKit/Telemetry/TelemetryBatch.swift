import Foundation

/// One request: the events of one process, or up to ten crash records. Built to fit the server's limits
/// (500 events, 10 crashes, 256 KB), never to be bigger than `bodyBytes`.
struct TelemetryBatch: Sendable, Equatable {
    var process: TelemetryProcess
    var events: [StoredEvent]
    var crashes: [PendingCrash]

    var isEmpty: Bool { events.isEmpty && crashes.isEmpty }
}

enum TelemetryBatcher {
    struct Limits: Sendable, Equatable {
        var events = TelemetryLimits.eventsPerBatch
        var crashes = TelemetryLimits.crashesPerBatch
        var bodyBytes = TelemetryLimits.bodyBytes
    }

    /// Room kept for the `app` block, the install id and the JSON scaffolding.
    static let overhead = 1_024

    /// The next batch from the front of the queues, or nil when both are empty. Crashes go first and
    /// alone; then events, all from the process of the first one (a batch names one process).
    /// Items are not removed from the arrays: the caller drops `batch.events.count` / `batch.crashes.count`
    /// from the fronts of its queues once the server accepted the batch (see `consume`).
    static func next(events: [StoredEvent], crashes: [PendingCrash], limits: Limits = Limits()) -> TelemetryBatch? {
        if !crashes.isEmpty {
            var taken: [PendingCrash] = []
            var size = overhead
            for crash in crashes {
                let cost = bytes(of: crash)
                // always take at least one, even one that alone is over budget (the caller shrinks it)
                if !taken.isEmpty, size + cost > limits.bodyBytes { break }
                taken.append(crash)
                size += cost
                if taken.count >= limits.crashes { break }
            }
            return TelemetryBatch(process: .app, events: [], crashes: taken)
        }
        guard let first = events.first else { return nil }
        let process = first.p
        var taken: [StoredEvent] = []
        var size = overhead
        for event in events where event.p == process {
            let cost = bytes(of: event.e)
            if !taken.isEmpty, size + cost > limits.bodyBytes { break }
            taken.append(event)
            size += cost
            if taken.count >= limits.events { break }
        }
        return TelemetryBatch(process: process, events: taken, crashes: [])
    }

    /// Takes a sent batch's items out of the queues.
    static func consume(_ batch: TelemetryBatch, events: inout [StoredEvent], crashes: inout [PendingCrash]) {
        let sentEvents = Set(batch.events.map(\.i))
        events.removeAll { sentEvents.contains($0.i) }
        let sentCrashes = Set(batch.crashes.map(\.record.id))
        crashes.removeAll { sentCrashes.contains($0.record.id) }
    }

    /// Splits everything into the batches it would take, in order (what `next` + `consume` produce).
    static func split(events: [StoredEvent], crashes: [PendingCrash], limits: Limits = Limits()) -> [TelemetryBatch] {
        var events = events, crashes = crashes
        var out: [TelemetryBatch] = []
        while let batch = next(events: events, crashes: crashes, limits: limits), !batch.isEmpty {
            out.append(batch)
            consume(batch, events: &events, crashes: &crashes)
        }
        return out
    }

    static func bytes(of event: TelemetryEvent) -> Int {
        (try? JSONEncoder().encode(event).count).map { $0 + 1 } ?? 300
    }

    static func bytes(of crash: PendingCrash) -> Int {
        let meta = (try? JSONEncoder().encode(crash.record).count) ?? 500
        return meta + (crash.payload?.count ?? 4) + 16
    }
}

/// The request body. Built by hand around the MetricKit payload so that it goes out byte for byte,
/// never parsed and re-encoded (a deep call stack tree would not survive a round trip through a JSON
/// object model's depth limit).
enum TelemetryBody {
    /// `secrets` never appear in the result, wherever they came from.
    static func encode(batch: TelemetryBatch, app: TelemetryAppInfo, install: String, secrets: [String] = []) throws -> Data {
        var info = app
        info.process = batch.process
        let encoder = JSONEncoder()
        var out = Data(#"{"app":"#.utf8)
        out.append(try encoder.encode(info))
        out.append(contentsOf: Data(#","install":"#.utf8))
        out.append(try encoder.encode(install))
        out.append(contentsOf: Data(#","events":"#.utf8))
        out.append(try encoder.encode(batch.events.map(\.e)))
        out.append(contentsOf: Data(#","crashes":["#.utf8))
        for (n, crash) in batch.crashes.enumerated() {
            if n > 0 { out.append(0x2C) }
            out.append(try crashObject(crash, encoder: encoder))
        }
        out.append(contentsOf: Data("]}".utf8))
        return redact(out, secrets: secrets)
    }

    /// `{"ts":…,"kind":…,"summary":…,"events":[…],"payload":<raw JSON or null>}`
    private static func crashObject(_ crash: PendingCrash, encoder: JSONEncoder) throws -> Data {
        struct Wire: Encodable {
            var ts: Int64
            var kind: CrashKind
            var summary: String
            var events: [TelemetryEvent]
        }
        var out = try encoder.encode(Wire(ts: crash.record.ts, kind: crash.record.kind, summary: crash.record.summary, events: crash.record.events))
        out.removeLast()                                   // the closing brace
        out.append(contentsOf: Data(#","payload":"#.utf8))
        if let payload = crash.payload, DiagnosticIngest.looksLikeJSON(payload) {
            out.append(payload)
        } else {
            out.append(contentsOf: Data("null".utf8))
        }
        out.append(0x7D)
        return out
    }

    /// Replaces every occurrence of each secret. Byte-level, so it also catches one inside a payload.
    static func redact(_ body: Data, secrets: [String]) -> Data {
        var out = body
        for secret in secrets where secret.utf8.count >= 8 {
            let needle = Data(secret.utf8)
            guard out.range(of: needle) != nil else { continue }
            let text = String(decoding: out, as: UTF8.self).replacingOccurrences(of: secret, with: "[redacted]")
            out = Data(text.utf8)
        }
        return out
    }
}
