import Foundation

/// Frame pacing over one stretch of interaction (a scroll, a swipe back, a tap that opens something), counted from a
/// display link's ticks. The app's `FrameMonitor` feeds it; this type only counts, so it can be tested without a screen.
///
/// A frame is a **hitch** when it arrives more than half a refresh late (at 120 Hz: a gap over 12.5 ms instead of 8.3).
/// Its hitch time is how late it was. **Hitch ratio** is hitch time per second of the stretch, Apple's measure for
/// scrolling (MetricKit's `scrollHitchTimeRatio`, Instruments' "hitch time ratio"): under 5 ms/s reads as smooth, 5–10
/// is noticeable, over 10 is bad.
public struct FrameStats: Sendable, Equatable {
    /// Frames whose gap was measured (the first tick only starts the clock).
    public private(set) var frames = 0
    /// Frames late by more than half a refresh.
    public private(set) var hitches = 0
    /// Frames that took 50 ms or more (three 60 Hz frames, six at 120): the stutter a person sees at once.
    public private(set) var severe = 0
    /// Total lateness of the hitches, in milliseconds.
    public private(set) var hitchMs = 0.0
    /// The longest gap between two frames, in milliseconds.
    public private(set) var worstMs = 0.0
    /// Wall time covered by the measured frames, in milliseconds.
    public private(set) var spanMs = 0.0
    /// The shortest refresh the display asked for, in milliseconds (8.33 at 120 Hz, 16.67 at 60).
    public private(set) var refreshMs = 0.0

    private var last: Double?

    public init() {}

    /// One display link tick. `timestamp` is the link's `timestamp` (seconds), `refresh` its frame duration in seconds
    /// (`targetTimestamp - timestamp`). Returns the gap in milliseconds when this tick closed a frame.
    @discardableResult
    public mutating func tick(timestamp: Double, refresh: Double) -> Double? {
        defer { last = timestamp }
        let budget = refresh * 1000
        guard budget > 0, budget.isFinite else { return nil }
        refreshMs = refreshMs == 0 ? budget : min(refreshMs, budget)
        guard let last, timestamp > last else { return nil }
        let gap = (timestamp - last) * 1000
        frames += 1
        spanMs += gap
        worstMs = max(worstMs, gap)
        if gap > budget * 1.5 {
            hitches += 1
            hitchMs += gap - budget
        }
        if gap >= 50 { severe += 1 }
        return gap
    }

    /// Hitch time per second, in ms/s.
    public var hitchRatio: Double { spanMs > 0 ? hitchMs / (spanMs / 1000) : 0 }

    /// The refresh rate the display ran at, rounded (120, 60...).
    public var hz: Int { refreshMs > 0 ? Int((1000 / refreshMs).rounded()) : 0 }

    /// Frames delivered per second over the stretch.
    public var fps: Double { spanMs > 0 ? Double(frames) / (spanMs / 1000) : 0 }

    /// Flat values for a log line or an analytics event.
    public var values: [String: TelemetryValue] {
        [
            "frames": .int(frames), "hitches": .int(hitches), "severe": .int(severe),
            "hitch_ms": .int(Int(hitchMs.rounded())), "hitch_ratio": .double((hitchRatio * 10).rounded() / 10),
            "worst_ms": .int(Int(worstMs.rounded())), "span_ms": .int(Int(spanMs.rounded())),
            "hz": .int(hz), "fps": .double((fps * 10).rounded() / 10),
        ]
    }
}
