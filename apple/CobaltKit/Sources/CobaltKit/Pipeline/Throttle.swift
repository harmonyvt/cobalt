import Foundation
import Synchronization

/// Lets a transfer's progress through at most ~10 times a second, always including the last value
/// (the one that reaches `total`, or what `flush()` finds waiting). URLSession reports every few
/// KB; the screen only needs a figure per frame or so.
final class ProgressThrottle: Sendable {
    static let interval: Double = 0.1

    private struct State {
        var last: Double?
        var pending: TransferProgress?
    }

    private let handler: @Sendable (TransferProgress) -> Void
    private let interval: Double
    private let now: @Sendable () -> Double
    private let state = Mutex(State())

    init(
        interval: Double = ProgressThrottle.interval,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        _ handler: @escaping @Sendable (TransferProgress) -> Void
    ) {
        self.interval = interval
        self.now = now
        self.handler = handler
    }

    func send(_ p: TransferProgress) {
        let t = now()
        let isFinal = p.total.map { p.bytes >= $0 } ?? false
        let deliver = state.withLock { s -> Bool in
            if isFinal || s.last == nil || t - (s.last ?? t) >= interval {
                s.last = t
                s.pending = nil
                return true
            }
            s.pending = p
            return false
        }
        if deliver { handler(p) }
    }

    /// The transfer ended: whatever was held back goes out now.
    func flush() {
        let held = state.withLock { s -> TransferProgress? in
            defer { s.pending = nil }
            return s.pending
        }
        if let held { handler(held) }
    }
}

/// Hands values from any thread to the main actor without a `Task` per value: at most one hop is
/// outstanding, it applies the newest value, and the last value pushed is always applied.
final class MainActorRelay<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value?
        var scheduled = false
    }

    private let state = Mutex(State())
    private let apply: @MainActor @Sendable (Value) -> Void

    init(_ apply: @escaping @MainActor @Sendable (Value) -> Void) { self.apply = apply }

    func push(_ value: Value) {
        let schedule = state.withLock { s -> Bool in
            s.latest = value
            if s.scheduled { return false }
            s.scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            while true {
                let next = self.state.withLock { s -> Value? in
                    let v = s.latest
                    s.latest = nil
                    if v == nil { s.scheduled = false }
                    return v
                }
                guard let next else { return }
                self.apply(next)
            }
        }
    }
}
