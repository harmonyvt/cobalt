import CobaltKit
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// How smooth the app really is, measured where the owner feels it (owner, 2026-11-14: "I scroll and I get frame
/// jitters... cut data on that, app wide"). While a finger is down, and for a moment after it lifts (the scroll still
/// glides), a display link times every frame (`FrameStats`). Each stretch becomes one PostHog `frames` event: which
/// screen, a scroll, swipe or tap, and its hitches, worst frame and hitch ratio. A single frame of 250 ms or more is also
/// its own `frame_hang` with the breadcrumbs. Nothing runs while the app sits untouched, so it costs no battery at rest.
///
/// The link times the main thread's frames: a stall in SwiftUI, layout, image decoding or our own code shows; a frame the
/// render server drops on its own (GPU) mostly does not. MetricKit's daily `scrollHitchTimeRatio` (`daily_metrics`)
/// covers that side.
@MainActor
enum FrameMonitor {
    /// What started a stretch: a short touch, a drag mostly up or down, or one mostly sideways (swipe back, pager).
    enum Kind: String { case tap, scroll, swipe }

    private static var stats = FrameStats()
    private static var touching = false
    /// Uptime after which, with no finger down, the stretch ends.
    private static var quietAt: TimeInterval = 0
    private static var startScreen = ""
    private static var start: CGPoint?
    private static var dx: CGFloat = 0
    private static var dy: CGFloat = 0
    private static var scrolled = false
    private static var hangs = 0

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: input

    /// A finger came down at `point` (window coordinates).
    static func touchBegan(at point: CGPoint) {
        touching = true
        if !running {
            start = point
            dx = 0; dy = 0
        }
        begin()
    }

    /// The finger moved to `point`.
    static func touchMoved(to point: CGPoint) {
        guard let start else { return }
        dx = max(dx, abs(point.x - start.x))
        dy = max(dy, abs(point.y - start.y))
    }

    /// Every finger is up: keep timing while the scroll glides to a stop.
    static func touchEnded() {
        guard touching else { return }
        touching = false
        quietAt = now + 1.6
    }

    // MARK: the stretch

    private static var running: Bool { linkRunning }

    private static func begin() {
        guard !running else { return }
        stats = FrameStats()
        startScreen = Analytics.currentScreen
        scrolled = false
        hangs = 0
        quietAt = now + 1.6
        startLink()
    }

    fileprivate static func tick(timestamp: CFTimeInterval, target: CFTimeInterval) {
        if let gap = stats.tick(timestamp: timestamp, refresh: target - timestamp), gap >= 250, hangs < 3 {
            hangs += 1
            let props: [String: TelemetryValue] = [
                "ms": .int(Int(gap.rounded())), "screen": .string(Analytics.currentScreen),
                "breadcrumbs": .string(Breadcrumbs.recent()),
            ]
            Telemetry.log(.info, .ui, "frame hang", data: props)
            Analytics.event("frame_hang", values: props)
        }
        if !touching, now >= quietAt { finish() }
    }

    private static func finish() {
        stopLink()
        guard stats.frames >= 10 else { return }
        let kind: Kind
        if scrolled { kind = .scroll }
        else if max(dx, dy) < 12 { kind = .tap }
        else { kind = dx > dy ? .swipe : .scroll }
        var data = stats.values
        data["screen"] = .string(startScreen)
        let end = Analytics.currentScreen
        if end != startScreen { data["to"] = .string(end) }
        data["kind"] = .string(kind.rawValue)
        data["move"] = .int(Int(max(dx, dy)))
        data["thermal"] = .string(thermal)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { data["low_power"] = .bool(true) }
        if stats.worstMs >= 100 { data["breadcrumbs"] = .string(Breadcrumbs.recent()) }
        Analytics.event("frames", values: data)
        // the self-hosted log keeps only the rough ones
        if stats.hitchRatio >= 10 || stats.severe > 0 { Telemetry.log(.info, .ui, "frames", data: data) }
    }

    private static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: the display link

    private static let target = LinkTarget()

    #if os(iOS)
    private static var link: CADisplayLink?
    private static var linkRunning: Bool { link != nil }

    private static func startLink() {
        let link = CADisplayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        // ask for the display's top rate, so a 120 Hz frame missed is seen as missed (Info.plist opts the iPhone in)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private static func stopLink() {
        link?.invalidate()
        link = nil
    }
    #else
    private static var link: CADisplayLink?
    private static var linkRunning: Bool { link != nil }
    private static var monitor: Any?

    /// The Mac has no touches: a scroll-wheel or trackpad scroll, or a click, opens a stretch; it ends after a short
    /// quiet spell.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { event in
            MainActor.assumeIsolated {
                let isScroll = event.type == .scrollWheel
                if !running {
                    start = .zero
                    dx = 0; dy = 0
                    begin()
                }
                if isScroll {
                    scrolled = true
                    dy += abs(event.scrollingDeltaY)
                    dx += abs(event.scrollingDeltaX)
                }
                quietAt = max(quietAt, now + (isScroll ? 0.6 : 1.6))
            }
            return event
        }
    }

    private static func startLink() {
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let link = view.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private static func stopLink() {
        link?.invalidate()
        link = nil
    }
    #endif
}

/// The display link's Objective-C target (it must be an `NSObject`); ticks arrive on the main run loop.
private final class LinkTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let target = link.targetTimestamp
        MainActor.assumeIsolated { FrameMonitor.tick(timestamp: timestamp, target: target) }
    }
}
