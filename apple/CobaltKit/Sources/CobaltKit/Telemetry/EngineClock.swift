import Foundation
import os
import Synchronization

/// How long the engines' named operations take, cheap enough to wrap every one of them (8.17: "telemetry capture
/// efficiently in this new architecture"):
///
///     let snapshot = EngineClock.measure("store.reconcile") { reconcile(rows) }
///
/// Each call is an `os_signpost` interval (subsystem `com.capybaraharmony.cobalt`, category `engine`, so Instruments
/// shows it beside the frames) and one update of a per-name tally under a lock: no allocation, no string work, nothing
/// sent. About once a minute, or when the app goes to the background (`drain()`), the tallies are handed to `flush` as
/// one flat dictionary and start again, so a busy engine costs one analytics event a minute however often it runs.
///
/// Callable from any thread, actor or task. Until the app sets `flush` the tallies are kept and dropped at each drain.
public enum EngineClock {
    /// Where a minute's tallies go (the app sends them as `engine_ops`). Called on whichever thread drained; must hop by
    /// itself.
    public static var flush: (@Sendable ([String: TelemetryValue]) -> Void)? {
        get { flushSlot.withLock { $0 } }
        set { flushSlot.withLock { $0 = newValue } }
    }

    /// Times `body` under `name` (a literal, such as `"store.reconcile"`).
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval(name, id: id)
        let main = pthread_main_np() != 0
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            signposter.endInterval(name, interval)
            record(name, nanos: end &- start, main: main)
        }
        return try body()
    }

    /// The same for async work: the time from start to finish, suspensions included. `main` is where it started.
    /// `isolation` keeps the body on the caller's actor (a main-actor caller's closure never leaves the main actor).
    public static func measure<T>(
        _ name: StaticString, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval(name, id: id)
        let main = pthread_main_np() != 0
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            signposter.endInterval(name, interval)
            record(name, nanos: end &- start, main: main)
        }
        return try await body()
    }

    /// Hands what was tallied so far to `flush` now (the app going to the background), however long it has been.
    public static func drain() {
        let values = tallies.withLock { $0.drain(now: DispatchTime.now().uptimeNanoseconds) }
        if let values { flush?(values) }
    }

    // MARK: internals

    /// How often the tallies are sent while the app is in use.
    static let windowNanos: UInt64 = 60 * 1_000_000_000

    // `OSSignposter` is a thread-safe wrapper over an `OSLog` handle.
    nonisolated(unsafe) private static let signposter = OSSignposter(subsystem: "com.capybaraharmony.cobalt", category: "engine")
    private static let tallies = Mutex(EngineTallies(startedAt: DispatchTime.now().uptimeNanoseconds))
    private static let flushSlot = Mutex<(@Sendable ([String: TelemetryValue]) -> Void)?>(nil)

    static func record(_ name: StaticString, nanos: UInt64, main: Bool) {
        let due = tallies.withLock { window -> [String: TelemetryValue]? in
            window.add(name, ms: Double(nanos) / 1_000_000, main: main)
            // read the clock under the lock: a `now` read before it can be older than a window another thread just
            // started, and the wrapped difference sent a window at once with window_s 18446744074 (8.17 (120))
            let now = DispatchTime.now().uptimeNanoseconds
            return window.isDue(now: now, after: windowNanos) ? window.drain(now: now) : nil
        }
        // outside the lock: the app's closure may take its own locks or allocate
        if let due { flush?(due) }
    }
}

/// One window of tallies, keyed by name. A plain value so the lock around it stays short and tests can drive it with
/// their own clock.
struct EngineTallies: Sendable {
    struct Tally: Sendable {
        var name: StaticString
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
        /// Calls longer than a 60 Hz frame (16 ms): on the main thread each is a dropped frame.
        var over16 = 0
        /// Calls longer than 100 ms: a hitch anyone sees.
        var over100 = 0
        /// Whether any call ran on the main thread (an engine that should never be there).
        var main = false
    }

    /// The most names one window keeps; later new names fold into `other`, so a mistake cannot grow the event without
    /// bound.
    static let maxNames = 64

    private(set) var startedAt: UInt64
    /// Keyed by the literal's address: a literal's text is never copied or hashed on the hot path.
    private(set) var byAddress: [UInt: Tally] = [:]

    init(startedAt: UInt64) { self.startedAt = startedAt }

    mutating func add(_ name: StaticString, ms: Double, main: Bool) {
        var key = Self.key(name)
        var label = name
        if byAddress[key] == nil, byAddress.count >= Self.maxNames {
            label = "other"
            key = Self.key(label)
        }
        var tally = byAddress[key] ?? Tally(name: label)
        tally.count += 1
        tally.totalMs += ms
        if ms > tally.maxMs { tally.maxMs = ms }
        if ms > 16 { tally.over16 += 1 }
        if ms > 100 { tally.over100 += 1 }
        if main { tally.main = true }
        byAddress[key] = tally
    }

    /// Whether the window has run `windowNanos` by `now`; a `now` older than the window's start is not due.
    func isDue(now: UInt64, after windowNanos: UInt64) -> Bool {
        now > startedAt && now - startedAt >= windowNanos
    }

    /// The window as flat values, and a fresh window from `now`. `nil` when nothing ran (no empty events).
    mutating func drain(now: UInt64) -> [String: TelemetryValue]? {
        defer {
            byAddress.removeAll(keepingCapacity: true)
            startedAt = max(startedAt, now)
        }
        guard !byAddress.isEmpty else { return nil }
        // the same text at two addresses (two modules) is one name
        var merged: [String: Tally] = [:]
        for tally in byAddress.values {
            let name = tally.name.description
            if var into = merged[name] {
                into.count += tally.count
                into.totalMs += tally.totalMs
                into.maxMs = max(into.maxMs, tally.maxMs)
                into.over16 += tally.over16
                into.over100 += tally.over100
                into.main = into.main || tally.main
                merged[name] = into
            } else {
                merged[name] = tally
            }
        }
        var values: [String: TelemetryValue] = [
            "window_s": .int(Int((Double(now > startedAt ? now - startedAt : 0) / 1_000_000_000).rounded())),
            "ops": .int(merged.count),
        ]
        for (name, t) in merged {
            values["\(name)_n"] = .int(t.count)
            values["\(name)_ms_total"] = .double(Self.tenths(t.totalMs))
            values["\(name)_ms_max"] = .double(Self.tenths(t.maxMs))
            values["\(name)_slow"] = .int(t.over16)
            values["\(name)_slow100"] = .int(t.over100)
            values["\(name)_main"] = .bool(t.main)
        }
        return values
    }

    private static func tenths(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }

    private static func key(_ name: StaticString) -> UInt {
        // a literal of one Unicode scalar has no pointer; its scalar value is a key no address can be
        name.hasPointerRepresentation ? UInt(bitPattern: name.utf8Start) : UInt(name.unicodeScalar.value)
    }
}
