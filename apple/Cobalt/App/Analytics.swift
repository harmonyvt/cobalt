import CobaltKit
@preconcurrency import PostHog
import Synchronization
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// PostHog in the app (APP-API-CONTRACT 58). The only file that imports PostHog: the rest of the app calls
/// `Analytics.screen(_:)` / `Analytics.event(_:values:)` and puts `.mediaMask()` on its media.
///
/// - The project comes from `GET /capabilities` (`posthog`), so the token is never in the binary and a server without it
///   never starts the SDK.
/// - On while "send logs" is on; "record sessions" turns replay off and keeps the events.
/// - Session replay on iPhone and iPad only (PostHog has none for the Mac), in screenshot mode (what SwiftUI needs), with
///   every image masked by the SDK and every media view masked by `.mediaMask()`. Text inputs are masked too.
/// - One person: `owner`, the same distinct id the Worker's events use, so a replay and its server calls sit together.
///   The SDK's session id goes on every request to the server (`AnalyticsContext`).
/// - The SDK starts after the first frame, not in it (`setup` loads its files, its flags and replay's hooks on the main
///   thread): the first `sync` that wants it schedules the start (`launch.posthog`), and the next `sync` finishes it.
/// - The main thread never waits on the SDK (8.17): PostHog's `capture` and `register` encode JSON and write a file on
///   the calling thread, so every one of them runs on `queue`, one at a time and in order. A caller only builds a small
///   flat `[String: TelemetryValue]`.
@MainActor
enum Analytics {
    private static var configured: PostHogProject?
    private static var running = false
    /// The deferred first start, while it waits for the first frame to be on screen.
    private static var starting: Task<Void, Never>?
    /// Sends the engines' timings when the app leaves (registered with AppLifecycle by `watch()`; held here, since
    /// AppLifecycle holds its subscribers weakly).
    private static var lifecycle: AnalyticsLifecycle?

    /// Whether the SDK is on and sending (the hang sampler's reports are dropped while it is not).
    static var isRunning: Bool { running }

    /// `running`, readable from any thread, so `event(_:values:)` can drop an event before it costs anything.
    nonisolated private static let live = Atomic<Bool>(false)

    /// Where every capture and super-property write happens (8.17). Serial, so events keep their order and a `screen`
    /// registered before an event is on it.
    nonisolated private static let queue = DispatchQueue(label: "com.capybaraharmony.cobalt.analytics", qos: .utility)

    /// Starts, stops or leaves the SDK as the server's answer and the settings say. Cheap; call it whenever either changes.
    static func sync(model: AppModel) {
        ensureLifecycle()
        // Where the main thread was when it stalled (`hang_stack`). Started on the first call whatever the settings, so
        // the sampler's own debug stall alarm works with analytics off; the report is sent only while it is on. A second
        // start() is ignored.
        HangSampler.shared.start { report in
            Task { @MainActor in
                if Analytics.isRunning { Analytics.hang(report) }
            }
        }
        let settings = model.settings
        let project = model.isPreview ? nil : model.capabilities.postHog
        let wanted = project != nil && settings.sendTelemetry
        if wanted {
            replayWanted = settings.recordSessions
            if configured == nil {
                // The first start waits until the first frame is on screen; the rest of this runs when it has.
                if starting == nil {
                    starting = Task { @MainActor in
                        await afterFirstFrame()
                        starting = nil
                        // what the owner and the server say now: either may have changed while it waited
                        guard configured == nil, !model.isPreview, let now = model.capabilities.postHog,
                              model.settings.sendTelemetry else { return }
                        replayWanted = model.settings.recordSessions
                        timedSetup(now, replay: replayWanted && !replayKilled)
                        configured = now
                        watchFeatureFlags()
                        sync(model: model)
                    }
                }
                return
            }
            // The SDK saves an opt-out on the phone and reads it back in setup(): an optOut() from an earlier launch
            // (the server stopped sending the project, or "send logs" was off) would otherwise keep it silent for good
            // while it still hands out session ids (8.11, 2026-11-14).
            if PostHogSDK.shared.isOptOut() {
                PostHogSDK.shared.optIn()
            }
            running = true
            live.store(true, ordering: .relaxed)
            if !screenSent { screen(currentScreen) }
            // MetricKit's daily averages (scroll hitch ratio, launch, hangs, energy), a day late at worst (`daily_metrics`)
            Telemetry.metricsDelivered = { values in Analytics.event("daily_metrics", values: values) }
            // a minute of the engines' timings in one event (`engine_ops`); the screen rides along as a super property
            EngineClock.flush = { values in Analytics.event("engine_ops", values: values) }
            applyReplay()
            // Public Mach energy slices, thermal transitions and true-session rollups (`energy_slice`, `thermal_state`,
            // `session_energy`): zero timers when idle, coalesced 5-min checkpoint only while streaming.
            let snap = AppLifecycle.shared.snapshot
            let screenNow = currentScreen
            let replayNow = replayRegistered ?? false
            EnergySampler.shared.start { w in
                w.isForeground = snap.isForeground
                w.thermal = EnergyThermal(snap.thermal)
                w.lpm = snap.isLowPowerMode
                w.screen = screenNow
                w.replay = replayNow
            }
            EnergySampler.shared.emit = { name, values in Analytics.event(name, values: values) }
            AnalyticsContext.setSessionProvider { PostHogSDK.shared.getSessionId() }
        } else if running {
            EngineClock.flush = nil
            EnergySampler.shared.emit = nil
            PostHogSDK.shared.optOut()
            running = false
            live.store(false, ordering: .relaxed)
            AnalyticsContext.setSessionProvider(nil)
        }
    }

    /// `setup`, timed as `launch.posthog`. Synchronous on purpose, so the timing wraps only the SDK's own start.
    private static func timedSetup(_ project: PostHogProject, replay: Bool) {
        EngineClock.measure("launch.posthog") { setup(project, replay: replay) }
    }

    private static func setup(_ project: PostHogProject, replay: Bool) {
        let config = PostHogConfig(apiKey: project.token, host: project.host.absoluteString)
        config.captureApplicationLifecycleEvents = true
        // SwiftUI screens are named by hand (`screen`): UIKit's automatic names are the hosting controllers'
        config.captureScreenViews = false
        // Relaxed batching (40 events / 3 min instead of default 20 / 30 s) avoids waking the cellular radio for
        // short RRC tails just to ship telemetry; background transitions flush explicitly via `flushForBackground()`.
        config.flushAt = 40
        config.flushIntervalSeconds = 180
        #if os(iOS)
        config.sessionReplay = replay
        config.sessionReplayConfig.screenshotMode = true
        // Frames are drawn on the GPU, not with drawHierarchy on the main thread: the first frame after coming back to
        // the app waited for screen updates and hung behind the sync glow's Metal view (8.9). Metal views and videos
        // show as blank boxes in the replay.
        config.sessionReplayConfig.screenshotModeGPUCapture = true
        // A snapshot every 2 s instead of every second: each one still starts on the main thread, and half as many
        // is half the cost while scrolling (8.17). A replay still shows every screen and tap.
        config.sessionReplayConfig.throttleDelay = 2
        config.sessionReplayConfig.maskAllImages = true
        config.sessionReplayConfig.maskAllTextInputs = true
        // Off: swizzling URLSession intercepts ~120 HLS prefetch segment fetches/min during multi-stream playback.
        config.sessionReplayConfig.captureNetworkTelemetry = false
        #endif
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(
            "owner",
            userProperties: ["platform": AnalyticsContext.client, "install": TelemetryInstall.id()])
    }

    /// Hands the main thread back until the first frame is on screen: the scene's first `sync` runs inside the first view
    /// update, and a task that only yielded could still run before that frame is committed.
    private static func afterFirstFrame() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Registers `AnalyticsLifecycle` once so `HangSampler` pauses in background/inactive even with analytics off.
    private static func ensureLifecycle() {
        guard lifecycle == nil else { return }
        let subscriber = AnalyticsLifecycle()
        lifecycle = subscriber
        AppLifecycle.shared.register(subscriber, order: .telemetry)
    }

    /// Feature flags (for the replay kill switch). Once per launch after PostHog setup.
    private static func watchFeatureFlags() {
        // Called on the main thread after the SDK loads its flags (cached ones at launch, then fresh); no request of our
        // own.
        PostHogSDK.shared.onFeatureFlags { _ in
            MainActor.assumeIsolated { Analytics.flagsLoaded() }
        }
    }

    // MARK: replay

    /// What the settings ask for ("record sessions").
    private static var replayWanted = false

    /// The `replay-off` feature flag: turned on in PostHog it stops replay on every install at its next flag load, a
    /// switch for a replay bug in the field (3.97.0's GPU capture crashed mid-animation, 8.17). Kept on the phone, so a
    /// replay that crashes at launch is never started before the flags arrive.
    private static var replayKilled = UserDefaults.standard.bool(forKey: replayKilledKey)
    private static let replayKilledKey = "analytics.replay-off"

    /// The `replay` super property last registered, so frames can be compared with replay on and off.
    private static var replayRegistered: Bool?

    /// True while Low Power Mode or serious/critical thermal pressure suspends GPU session replay capture.
    private static var replayPausedForPower = AppLifecycle.shared.snapshot.shouldConservePower

    private static func flagsLoaded() {
        let killed = PostHogSDK.shared.isFeatureEnabled("replay-off", sendFeatureFlagEvent: false)
        if killed != replayKilled {
            replayKilled = killed
            UserDefaults.standard.set(killed, forKey: replayKilledKey)
        }
        applyReplay()
    }

    /// Updates power/thermal suppression for GPU session replay (called by `AnalyticsLifecycle`).
    fileprivate static func setPowerConservation(_ conserve: Bool) {
        guard conserve != replayPausedForPower else { return }
        replayPausedForPower = conserve
        applyReplay()
    }

    /// Starts or stops replay to match the settings, kill switch, and power/thermal state, and registers what is really
    /// recording as the `replay` super property.
    private static func applyReplay() {
        guard running else { return }
        #if os(iOS)
        let on = replayWanted && !replayKilled && !replayPausedForPower
        if on, !PostHogSDK.shared.isSessionReplayActive() {
            PostHogSDK.shared.startSessionRecording()
        } else if !on, PostHogSDK.shared.isSessionReplayActive() {
            PostHogSDK.shared.stopSessionRecording()
        }
        let active = PostHogSDK.shared.isSessionReplayActive()
        #else
        let active = false
        #endif
        guard active != replayRegistered else { return }
        replayRegistered = active
        EnergySampler.shared.setReplay(active)
        queue.async { PostHogSDK.shared.register(["replay": active]) }
    }

    /// Drains queued events and flushes PostHog cleanly before iOS suspends the process.
    fileprivate static func flushForBackground() {
        EngineClock.drain()
        guard running else { return }
        #if os(iOS)
        let app = UIApplication.shared
        let taskID = Mutex<UIBackgroundTaskIdentifier>(.invalid)
        let id = app.beginBackgroundTask(withName: "cobalt.analytics.flush") {
            let expired = taskID.withLock { slot -> UIBackgroundTaskIdentifier in
                let prev = slot
                slot = .invalid
                return prev
            }
            if expired != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(expired) }
            }
        }
        taskID.withLock { $0 = id }
        queue.async {
            if live.load(ordering: .relaxed) {
                PostHogSDK.shared.flush()
            }
            let finished = taskID.withLock { slot -> UIBackgroundTaskIdentifier in
                let prev = slot
                slot = .invalid
                return prev
            }
            if finished != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(finished) }
            }
        }
        #else
        queue.async {
            if live.load(ordering: .relaxed) {
                PostHogSDK.shared.flush()
            }
        }
        #endif
    }

    // MARK: events

    /// The screen in front (a tab, or `library.detail`), for the frame monitor and every event's `screen` property.
    private(set) static var currentScreen = "library"

    /// A screen the owner opened (`$screen`). Also registered as the `screen` super property, so rage taps and every other
    /// event name the screen instead of the hosting controller's class.
    static func screen(_ name: String) {
        guard name != currentScreen || !screenSent else { return }
        currentScreen = name
        EnergySampler.shared.setScreen(name)
        guard running else { return }
        screenSent = true
        queue.async {
            PostHogSDK.shared.register(["screen": name])
            PostHogSDK.shared.screen(name)
        }
    }

    private static var screenSent = false

    /// A named event with flat properties, from any thread or actor. Never a link, a title or a file: hosts, counts,
    /// times and results only. The SDK's work (properties, JSON, the file) happens on `queue`.
    nonisolated static func event(_ name: String, values: [String: TelemetryValue]) {
        guard live.load(ordering: .relaxed) else { return }
        queue.async {
            guard live.load(ordering: .relaxed) else { return }
            PostHogSDK.shared.capture(name, properties: properties(values))
        }
    }

    /// A main-thread stall the sampler caught: `hang_stack` with each sample's frames, newest first, one per line. Only
    /// the screen and the breadcrumbs are read here; the joins happen on `queue`.
    static func hang(_ report: HangSampler.Report) {
        let screen = currentScreen
        let breadcrumbs = Breadcrumbs.recent()
        queue.async {
            Telemetry.log(.info, .ui, "hang stack", data: [
                "ms": .int(report.stallMs), "screen": .string(screen),
                "top": .string(String((report.samples.first?.frames.prefix(6) ?? []).joined(separator: " | ").prefix(280))),
            ])
            guard live.load(ordering: .relaxed) else { return }
            var props: [String: Any] = [
                "ms": report.stallMs, "screen": screen, "breadcrumbs": breadcrumbs, "samples": report.samples.count,
            ]
            for (i, sample) in report.samples.enumerated() {
                props["at_\(i + 1)"] = sample.atMs
                props["stack_\(i + 1)"] = sample.frames.joined(separator: "\n")
            }
            if let top = report.samples.first?.frames.prefix(12) { props["top"] = top.joined(separator: " | ") }
            PostHogSDK.shared.capture("hang_stack", properties: props)
        }
    }

    nonisolated private static func properties(_ values: [String: TelemetryValue]) -> [String: Any] {
        var props: [String: Any] = [:]
        props.reserveCapacity(values.count)
        for (key, value) in values {
            switch value {
            case .string(let s): props[key] = s
            case .int(let i): props[key] = i
            case .double(let d): props[key] = d
            case .bool(let b): props[key] = b
            }
        }
        return props
    }
}

/// Sends the engines' timings (`EngineClock.drain()`), flushes PostHog cleanly, updates `EnergySampler` thermal/LPM/
/// session state, pauses `HangSampler` whenever inactive/backgrounded, and pauses GPU session replay & ProMotion
/// frame probing when Low Power Mode or thermal throttling activates.
@MainActor
private final class AnalyticsLifecycle: LifecycleAware {
    func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        HangSampler.shared.setActive(snapshot.isActive)
        Analytics.setPowerConservation(snapshot.shouldConservePower)
        TwitchPlayerHost.shared.publishEnergyPlayback(backgrounding: !snapshot.isForeground)
        EnergySampler.shared.setLifecycle(
            isForeground: snapshot.isForeground,
            thermal: snapshot.thermal,
            lpm: snapshot.isLowPowerMode
        )
        if snapshot.isLowPowerMode { FrameMonitor.appLeft() }
        // the frame timer never measures time away from the screen
        if event == .willResignActive || event == .didEnterBackground { FrameMonitor.appLeft() }
        #if os(iOS)
        guard event == .didEnterBackground else { return }
        #else
        guard event == .willResignActive else { return }
        #endif
        Analytics.flushForBackground()
    }
}
