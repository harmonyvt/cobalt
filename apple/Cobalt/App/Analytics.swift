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
            } else if !running {
                PostHogSDK.shared.optIn()
            }
            running = true
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
            PostHogSDK.shared.startSession()
        } else if !on, PostHogSDK.shared.isSessionReplayActive() {
            PostHogSDK.shared.stopSession()
        }
        #endif
    }

    /// A screen the owner opened (`$screen`).
    static func screen(_ name: String) {
        guard running else { return }
        PostHogSDK.shared.screen(name)
    }

    /// A named event with flat properties. Never a link, a title or a file: hosts, counts, times and results only.
    static func event(_ name: String, _ properties: [String: Any] = [:]) {
        guard running else { return }
        PostHogSDK.shared.capture(name, properties: properties)
    }
}
