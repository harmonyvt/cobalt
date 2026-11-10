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
        // `-previewQueue busy|quiet|localOnly`: the app over `AppModel.previewQueue(<state>)` (work in motion, so the
        // toolbar button carries its badge); `-previewTab queue` then opens the queue sheet. Wins over `-previewScenario`.
        if let raw = defaults.string(forKey: "previewQueue"),
           let state: QueuePreviewState = ["busy": .busy, "quiet": .quiet, "localOnly": .localOnly, "off": .off][raw] {
            let model = AppModel.previewQueue(state)
            if let tabRaw = defaults.string(forKey: "previewTab"), let tab = AppTab(rawValue: tabRaw) { model.selectedTab = tab }
            return model
        }
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
        #if os(macOS)
        MenuBarPresence.shared.staysRunning = model.settings.menuBarExtra
        #endif
        _model = State(initialValue: model)
        #if os(macOS)
        FinderDomain.install(model)
        MenuBarFinderWiring.connect(model)
        #endif
        // Shortcuts, Siri and Spotlight run in this process, before any scene (CONTRACT-PARALLEL 15.2)
        IntentDependencies.register(model)
        #if os(macOS)
        DockBadge.follow(model.queue)
        #endif
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
                .syncGlow(model.library.syncStatus)
                .frame(width: 560, height: 740)
        }
        EditorWindow(model: model)
        menuBar
        #endif
    }

    /// What the scene does once its content is up (its `.task`): takes the notification taps, and
    /// runs the debug launch flags that need a live scene.
    private func sceneStarted() async {
        #if DEBUG
        DebugHooks.log("CobaltApp scene .task")
        #endif
        LinkInbox.shared.install { [model] url in handleAppLink(url, model: model) }
        #if os(macOS)
        // the studio wallpaper, when it was on (once, however often the window opens again)
        StageWallpaper.shared.restoreAtLaunch(model)
        #endif
        #if DEBUG
        LaunchConfig.runDebugLiveIfRequested()
        SyncGlowDebugLaunch.apply(to: model)
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
            .syncGlow(model.library.syncStatus, suppressed: windowGlowSuppressed)
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

    /// iOS full-screen presentations draw their own band. The window's band waits, so the two never stack.
    private var windowGlowSuppressed: Bool {
        #if os(iOS)
        !SyncGlowPlacement.windowShowsBand(
            queueSheet: model.queueShown,
            editorCover: model.editor.session != nil || EditorLauncher.shared.isBusy)
        #else
        false
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
            #if DEBUG
            .commands { SyncGlowDebugCommands(model: model) }
            #endif
    }
    #else
    /// One window, not a `WindowGroup`: a group opens another window for every `cobalt-apple://` link
    /// (each with its own copy of the shell over the same model), and the Mac app has one model.
    private var mainWindow: some Scene {
        // Taken here, not inside `.commands`. `Scene.commands` runs the builder from the app body's
        // update. An `@Observable` read in that builder (this used to read the wallpaper object and
        // `model.capabilities` from the menu item) marks the graph dirty before the update finishes.
        // Launch collides with a window being miniaturized or closed — the menu bar extra's window,
        // or a restored minimized window — and `updateRootHost` flushes that graph, which builds the
        // commands again, until the stack overflows.
        let model = model
        let wallpaper = StudioWallpaperMenu(
            isOn: StageWallpaper.shared.isOn, stageAvailable: model.capabilities.stage)
        return Window("capystore", id: "main") { windowContent }
            .defaultSize(width: 1280, height: 780)
            .defaultLaunchBehavior(.presented)
            // ⌘V is not a menu command here: the system's Paste reaches the window's paste destination, and a text field
            // that has the focus (the `name it` sheet's) takes it first (`AppShell.PasteAnywhere`, CONTRACT-PARALLEL 4.1)
            .commands {
                CommandGroup(after: .newItem) {
                    Button(Copy.trimNewWebp, systemImage: Symbol.trim) { trimSelected(model) }
                        .keyboardShortcut("t", modifiers: .command)
                }
                // the studio canvas behind the desktop icons; off works without opening the tab
                CommandGroup(after: .toolbar) {
                    StageWallpaperCommand(menu: wallpaper, model: model)
                }
                #if DEBUG
                SyncGlowDebugCommands(model: model)
                #endif
            }
    }

    /// The menu bar icon. `isInserted` is the settings switch (on unless the owner turns it off).
    /// `.window` is the popover, not a pull-down menu.
    private var menuBar: some Scene {
        // Read here, in the scene body, so this scene updates when the settings row changes. A
        // statement before the scene means this property has to return explicitly (it is not a
        // result builder).
        //
        // The binding is constant. `MenuBarExtra` writes `isInserted` while it creates its window
        // and again when that window is closed or miniaturized (launch does both). Writing that
        // through `settings.menuBarExtra` used to publish an observation the body had just read,
        // so the scene list and `.commands` rebuilt from inside `updateRootHost` and never settled.
        // The settings row is the only control; the extra does not get to change the switch.
        let show = model.settings.menuBarExtra
        MenuBarPresence.shared.staysRunning = show
        return MenuBarExtra(isInserted: .constant(show)) {
            MenuBarPopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
    #endif
}

#if os(macOS)
/// View ▸ "studio wallpaper": a checkmark item. On reads the stage first when the tab has not; it can be turned on only
/// while the server has the studio, and off always.
///
/// The checkmark is the snapshot the scene passed in. The menu writes that same value back while the
/// menus are built; applying it would turn the wallpaper on or off from inside `Scene.commands`.
private struct StageWallpaperCommand: View {
    let menu: StudioWallpaperMenu
    let model: AppModel

    var body: some View {
        Toggle(Copy.Stage.wallpaperMenu, isOn: Binding(
            get: { menu.isOn },
            set: { on in
                guard menu.changes(to: on) else { return }
                if on { StageWallpaper.shared.turnOn(model) } else { StageWallpaper.shared.hide() }
            }))
            .disabled(!menu.canToggle)
    }
}
#endif
