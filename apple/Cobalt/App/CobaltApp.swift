import CobaltKit
import SwiftUI

/// Simulator evidence and design review: `-previewScenario happy` runs the app over
/// `AppModel.preview(<scenario>)`; `-previewScript idle|input|render` then drives the pipeline,
/// and `-previewTab save|library|settings` picks the tab. Without the argument the app is live.
/// Debug builds only.
@MainActor
private enum LaunchConfig {
    static func makeModel() -> AppModel {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "previewScenario"), let scenario = PreviewScenario(rawValue: raw) {
            let model = AppModel.preview(scenario)
            Pasteboard.override = scenario.pasteText
            if let tabRaw = defaults.string(forKey: "previewTab"), let tab = AppTab(rawValue: tabRaw) {
                model.selectedTab = tab
                if tab == .library, model.library.posts.indices.contains(1) {
                    model.library.expandedPostID = model.library.posts[1].id
                }
            }
            // `-previewPhotos album:adding` (access: notAsked|album|limited|addOnly|denied; state: off|needsKeep|
            // enabled|paused|adding|outOfSpace|gaveUp) and `-previewPlacement album|library`: the photos album
            // in any state, and the "save to photos" button's two placed states
            PhotosPreviewState.applyLaunchArgument(to: model)
            switch defaults.string(forKey: "previewPlacement") {
            case "album": model.pipeline.previewPhotosPlacement(.inAlbum)
            case "library": model.pipeline.previewPhotosPlacement(.inLibrary)
            default: break
            }
            return model
        }
        #endif
        return AppModel.live()
    }

    #if DEBUG
    private static var scriptStarted = false
    private static var liveStarted = false

    /// `-previewLive` (iOS), from the scene's `.task` (`Activity.request` needs a scene), once.
    static func runDebugLiveIfRequested() {
        #if os(iOS)
        guard !liveStarted else { return }
        liveStarted = true
        DebugLive.runIfRequested()
        #endif
    }

    /// `-previewScript`, from the scene's `.task`, once however many windows the scene opens.
    static func runPreviewScriptIfRequested(_ model: AppModel) async {
        let defaults = UserDefaults.standard
        guard !scriptStarted,
              let raw = defaults.string(forKey: "previewScenario"), let scenario = PreviewScenario(rawValue: raw),
              let scriptRaw = defaults.string(forKey: "previewScript"), let script = PreviewScript(rawValue: scriptRaw)
        else { return }
        scriptStarted = true
        await runPreviewScript(script, scenario: scenario, pipeline: model.pipeline)
        // `-previewRuns 2`: after the focused planet has been up a few seconds, drop it and run the whole flow
        // again in the same process (evidence of what is a first-use cost and what is not)
        for _ in 1..<max(1, defaults.integer(forKey: "previewRuns")) {
            try? await Task.sleep(for: .seconds(3.5))
            model.pipeline.reset()
            try? await Task.sleep(for: .seconds(1.5))
            await runPreviewScript(script, scenario: scenario, pipeline: model.pipeline)
        }
    }
    #endif
}

@main
struct CobaltApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CobaltAppDelegate.self) private var delegate
    #else
    @NSApplicationDelegateAdaptor(CobaltAppDelegate.self) private var delegate
    #endif
    @State private var model: AppModel

    init() {
        #if os(macOS)
        MonochromeAccent.apply()
        #if DEBUG
        MonochromeAccent.probeIfRequested()
        #endif
        #endif
        CobaltFont.register()
        let model = LaunchConfig.makeModel()
        _model = State(initialValue: model)
        #if DEBUG
        // Before any scene exists, like a notification tap that launches the app.
        DebugHooks.runIfRequested(model)
        #endif
    }

    var body: some Scene {
        mainWindow
        #if os(macOS)
        // Settings are the system's: ⌘, opens this window, and the app menu names it.
        SwiftUI.Settings {
            SettingsScreen(model: model)
                .cobaltRoot(model: model)
                .frame(width: 560, height: 740)
        }
        #endif
    }

    /// What the scene does once its content is up (its `.task`): takes the notification taps, and
    /// runs the debug launch flags that need a live scene.
    private func sceneStarted() async {
        #if DEBUG
        DebugHooks.log("CobaltApp scene .task")
        #endif
        LinkInbox.shared.install { [model] url in handleAppLink(url, model: model) }
        #if DEBUG
        LaunchConfig.runDebugLiveIfRequested()
        await LaunchConfig.runPreviewScriptIfRequested(model)
        #endif
    }

    /// The shell; with `-previewPhotosOnly 1` (debug) just the photos section, for one-state screenshots.
    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG && os(iOS)
        if UserDefaults.standard.bool(forKey: "previewPhotosOnly") {
            PhotosSectionEvidence(model: model).cobaltRoot(model: model)
        } else {
            AppShell(model: model)
        }
        #else
        AppShell(model: model)
        #endif
    }

    private var windowContent: some View {
        rootContent
            .onOpenURL { url in
                #if DEBUG
                DebugHooks.log("onOpenURL \(url.absoluteString)")
                #endif
                handleAppLink(url, model: model)
            }
            .task { await sceneStarted() }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 600)
            #endif
    }

    #if os(iOS)
    private var mainWindow: some Scene {
        WindowGroup { windowContent }
            // A background download the share sheet started (the original, CONTRACT-SYNC.md decision 6)
            // finished while cobalt was not running: iOS launches the app and hands over the session.
            // The foreground catch-up (photos refresh, reconcile) is `pickUpSharedJobs` in AppShell.
            .backgroundTask(.urlSession(matching: AppModel.ownsBackgroundSession)) { [model] identifier in
                await model.handleBackgroundDownloads(identifier: identifier)
            }
    }
    #else
    /// One window, not a `WindowGroup`: a group opens another window for every `cobalt-apple://` link
    /// (each with its own copy of the shell over the same model), and the Mac app has one model.
    private var mainWindow: some Scene {
        Window("cobalt", id: "main") { windowContent }
            .defaultSize(width: 1280, height: 780)
            .defaultLaunchBehavior(.presented)
            .commands {
                CommandGroup(after: .pasteboard) {
                    Button(Copy.pasteA11y, systemImage: Symbol.paste) { model.pasteFromClipboard() }
                        .keyboardShortcut("v", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button(Copy.trimNewWebp, systemImage: Symbol.trim) { trimSelected(model) }
                        .keyboardShortcut("t", modifiers: .command)
                }
            }
    }
    #endif
}
