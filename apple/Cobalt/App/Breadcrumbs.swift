import CobaltKit
import Foundation

/// The last few things the app did on screen (open a detail, close it, a video starting or failing), newest last, for
/// the tap probe and the freeze hunt (owner, 2026-11-14). Each step is also a self-hosted log line (`ui`) and a PostHog
/// event (`step`), so it sits in the replay's timeline. Short names only: never titles, text or links.
@MainActor
enum Breadcrumbs {
    private static var steps: [(at: TimeInterval, what: String)] = []

    static func add(_ what: String, _ data: [String: TelemetryValue] = [:]) {
        let now = ProcessInfo.processInfo.systemUptime
        steps.append((now, what))
        if steps.count > 12 { steps.removeFirst(steps.count - 12) }
        Telemetry.log(.info, .ui, what, data: data)
        var props: [String: Any] = ["step": what]
        for (key, value) in data {
            switch value {
            case .string(let s): props[key] = s
            case .int(let i): props[key] = i
            case .double(let d): props[key] = d
            case .bool(let b): props[key] = b
            }
        }
        Analytics.event("step", props)
    }

    /// `-4.1s detail.open | -0.3s video.ready`, newest last, short enough for one log value.
    static func recent() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        var parts: [String] = []
        for step in steps.suffix(6) {
            parts.append(String(format: "-%.1fs ", now - step.at) + step.what)
        }
        return parts.joined(separator: " | ")
    }
}
