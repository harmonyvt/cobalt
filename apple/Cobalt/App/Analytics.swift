import CobaltKit
@preconcurrency import PostHog
import SwiftUI

/// PostHog in the app (APP-API-CONTRACT 58). The only file that imports PostHog: the rest of the app calls
/// `Analytics.screen(_:)` / `Analytics.event(_:_:)` and puts `.mediaMask()` on its media.
///
/// - The project comes from `GET /capabilities` (`posthog`), so the token is never in the binary and a server without it
///   never starts the SDK.
/// - On while "send logs" is on; "record sessions" turns replay off and keeps the events.
/// - Session replay on iPhone and iPad only (PostHog has none for the Mac), in screenshot mode (what SwiftUI needs), with
///   every image masked by the SDK and every media view masked by `.mediaMask()`. Text inputs are masked too.
/// - One person: `owner`, the same distinct id the Worker's events use, so a replay and its server calls sit together.
///   The SDK's session id goes on every request to the server (`AnalyticsContext`).
@MainActor
enum Analytics {
    private static var configured: PostHogProject?
    private static var running = false

    /// Starts, stops or leaves the SDK as the server's answer and the settings say. Cheap; call it whenever either changes.
    static func sync(model: AppModel) {
        let settings = model.settings
        let project = model.isPreview ? nil : model.capabilities.postHog
        let wanted = project != nil && settings.sendTelemetry
        if wanted, let project {
            if configured == nil {
                setup(project, replay: settings.recordSessions)
                configured = project
            }
            // The SDK saves an opt-out on the phone and reads it back in setup(): an optOut() from an earlier launch
            // (the server stopped sending the project, or "send logs" was off) would otherwise keep it silent for good
            // while it still hands out session ids (8.11, 2026-11-14).
            if PostHogSDK.shared.isOptOut() {
                PostHogSDK.shared.optIn()
            }
            running = true
            if !screenSent { screen(currentScreen) }
            // where the main thread was when it stalled (`hang_stack`)
            HangSampler.shared.start { report in
                Task { @MainActor in Analytics.hang(report) }
            }
            // MetricKit's daily averages (scroll hitch ratio, launch, hangs), a day late at worst (`daily_metrics`)
            Telemetry.metricsDelivered = { values in
                Task { @MainActor in Analytics.event("daily_metrics", values: values) }
            }
            replay(settings.recordSessions)
            AnalyticsContext.setSessionProvider { PostHogSDK.shared.getSessionId() }
        } else if running {
            PostHogSDK.shared.optOut()
            running = false
            AnalyticsContext.setSessionProvider(nil)
        }
    }

    private static func setup(_ project: PostHogProject, replay: Bool) {
        let config = PostHogConfig(apiKey: project.token, host: project.host.absoluteString)
        config.captureApplicationLifecycleEvents = true
        // SwiftUI screens are named by hand (`screen`): UIKit's automatic names are the hosting controllers'
        config.captureScreenViews = false
        #if os(iOS)
        config.sessionReplay = replay
        config.sessionReplayConfig.screenshotMode = true
        // Frames are drawn on the GPU, not with drawHierarchy on the main thread: the first frame after coming back to
        // the app waited for screen updates and hung behind the sync glow's Metal view (8.9). Metal views and videos
        // show as blank boxes in the replay.
        config.sessionReplayConfig.screenshotModeGPUCapture = true
        config.sessionReplayConfig.maskAllImages = true
        config.sessionReplayConfig.maskAllTextInputs = true
        // speeds, sizes and status codes of requests, never their bodies
        config.sessionReplayConfig.captureNetworkTelemetry = true
        #endif
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(
            "owner",
            userProperties: ["platform": AnalyticsContext.client, "install": TelemetryInstall.id()])
    }

    private static func replay(_ on: Bool) {
        #if os(iOS)
        if on, !PostHogSDK.shared.isSessionReplayActive() {
            PostHogSDK.shared.startSessionRecording()
        } else if !on, PostHogSDK.shared.isSessionReplayActive() {
            PostHogSDK.shared.stopSessionRecording()
        }
        #endif
    }

    /// The screen in front (a tab, or `library.detail`), for the frame monitor and every event's `screen` property.
    private(set) static var currentScreen = "library"

    /// A screen the owner opened (`$screen`). Also registered as the `screen` super property, so rage taps and every other
    /// event name the screen instead of the hosting controller's class.
    static func screen(_ name: String) {
        guard name != currentScreen || !screenSent else { return }
        currentScreen = name
        guard running else { return }
        screenSent = true
        PostHogSDK.shared.register(["screen": name])
        PostHogSDK.shared.screen(name)
    }

    private static var screenSent = false

    /// A named event with flat properties. Never a link, a title or a file: hosts, counts, times and results only.
    static func event(_ name: String, _ properties: [String: Any] = [:]) {
        guard running else { return }
        PostHogSDK.shared.capture(name, properties: properties)
    }

    /// A main-thread stall the sampler caught: `hang_stack` with each sample's frames, newest first, one per line.
    static func hang(_ report: HangSampler.Report) {
        var props: [String: Any] = [
            "ms": report.stallMs, "screen": currentScreen, "breadcrumbs": Breadcrumbs.recent(), "samples": report.samples.count,
        ]
        for (i, sample) in report.samples.enumerated() {
            props["at_\(i + 1)"] = sample.atMs
            props["stack_\(i + 1)"] = sample.frames.joined(separator: "\n")
        }
        if let top = report.samples.first?.frames.prefix(12) { props["top"] = top.joined(separator: " | ") }
        Telemetry.log(.info, .ui, "hang stack", data: [
            "ms": .int(report.stallMs), "screen": .string(currentScreen),
            "top": .string(String((report.samples.first?.frames.prefix(6) ?? []).joined(separator: " | ").prefix(280))),
        ])
        event("hang_stack", props)
    }

    /// The same, from a log line's flat values.
    static func event(_ name: String, values: [String: TelemetryValue]) {
        guard running else { return }
        var props: [String: Any] = [:]
        for (key, value) in values {
            switch value {
            case .string(let s): props[key] = s
            case .int(let i): props[key] = i
            case .double(let d): props[key] = d
            case .bool(let b): props[key] = b
            }
        }
        PostHogSDK.shared.capture(name, properties: props)
    }
}
