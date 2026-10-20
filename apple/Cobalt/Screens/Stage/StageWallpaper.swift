#if os(macOS)
import AppKit
import CobaltKit
import Observation
import WebKit

// The studio canvas as the Mac's wallpaper (APP-API-CONTRACT 30.5, `?ambient=1`): one borderless window per display at the
// desktop level, behind the desktop icons, each showing the canvas page in its ambient mode (always silent, always playing
// even off air, no toasts, hints or captions, no letterbox bars). The windows never take a click. Nothing streams while the
// displays sleep or the session is locked or switched away. On or off is remembered ("stageWallpaper"), and the app puts it
// back at launch (`restoreAtLaunch`). Turned on and off from the links card of the studio tab and from the View menu.

@MainActor @Observable
final class StageWallpaper {
    static let shared = StageWallpaper()

    /// The wallpaper is wanted (remembered across launches). Set by `show`, `hide` and `turnOn`.
    private(set) var isOn: Bool

    /// One display's window and the page in it.
    private struct Pane {
        let window: NSWindow
        let web: WKWebView
        var frame: NSRect
        /// What the page holds now; nil while blanked.
        var loaded: URL?
    }

    private static let defaultsKey = "stageWallpaper"

    /// The ambient canvas being shown; nil while off.
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var panes: [Pane] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sessionAway = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var restored = false

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        observe()
    }

    /// The pages are blanked: the displays sleep, or the session is locked or switched away.
    private var paused: Bool { screensAsleep || sessionAway }

    // MARK: on and off

    /// Shows `url` (the stage's `ambientURL`) on every display and remembers that the wallpaper is on. The same URL again
    /// does nothing.
    func show(_ url: URL) {
        loading?.cancel()
        loading = nil
        setOn(true)
        guard url != self.url || panes.isEmpty else { return }
        self.url = url
        arrange()
    }

    /// Takes the wallpaper away: the pages are emptied (no video keeps playing in a closing window), then the windows close.
    func hide() {
        loading?.cancel()
        loading = nil
        setOn(false)
        url = nil
        for pane in panes { close(pane) }
        panes = []
    }

    /// The stage's live link changed (a rotate, another server): while on, the new ambient canvas replaces the old one.
    func update(url: URL?) {
        guard isOn, let url else { return }
        show(url)
    }

    /// On from the menu or at launch: shows the stage's canvas, reading the stage first when it is not loaded yet. A read
    /// that fails is tried again a few times (the network may not be up yet at login); a server without the studio turns
    /// the wallpaper off.
    func turnOn(_ model: AppModel) {
        if let stage = model.stage.stage {
            show(stage.ambientURL)
            return
        }
        setOn(true)
        loading?.cancel()
        loading = Task {
            for wait in [0.0, 2, 10, 30, 60, 120] {
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                guard !Task.isCancelled, isOn else { return }
                // a read already running (the studio tab's) returns at once: the next round sees what it read
                if model.stage.stage == nil { await model.stage.load() }
                guard !Task.isCancelled, isOn else { return }
                if let stage = model.stage.stage {
                    show(stage.ambientURL)
                    return
                }
                if case .failed(.off) = model.stage.state {
                    hide()
                    return
                }
            }
        }
    }

    /// At launch, once however often the scene starts: puts the wallpaper back when it was on.
    func restoreAtLaunch(_ model: AppModel) {
        guard !restored else { return }
        restored = true
        if isOn { turnOn(model) }
    }

    private func setOn(_ on: Bool) {
        guard isOn != on else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
    }

    // MARK: the windows

    /// One window per display: windows on a display that is still there (same frame) stay, the others close, new displays
    /// get one. Every page then holds the current canvas, or nothing while paused.
    private func arrange() {
        guard url != nil else { return }
        let frames = NSScreen.screens.map(\.frame)
        var kept: [Pane] = []
        for pane in panes {
            if frames.contains(pane.frame), !kept.contains(where: { $0.frame == pane.frame }) {
                kept.append(pane)
            } else {
                close(pane)
            }
        }
        for frame in frames where !kept.contains(where: { $0.frame == frame }) {
            kept.append(makePane(frame))
        }
        panes = kept
        refreshPages()
    }

    private func makePane(_ frame: NSRect) -> Pane {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.canHide = false                    // ⌘H hides the app's windows, not the desktop
        window.animationBehavior = .none
        let web = StageWebCoordinator.makeWebView()
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return Pane(window: window, web: web, frame: frame, loaded: nil)
    }

    /// Every page holds the canvas (or is blank while paused); a page that already holds it is left alone.
    private func refreshPages() {
        let target = paused ? nil : url
        for i in panes.indices where panes[i].loaded != target {
            if let target {
                panes[i].web.load(URLRequest(url: target))
            } else {
                blank(panes[i].web)
            }
            panes[i].loaded = target
        }
    }

    private func close(_ pane: Pane) {
        blank(pane.web)
        pane.window.orderOut(nil)
        pane.window.contentView = nil
        pane.window.close()
    }

    private func blank(_ web: WKWebView) {
        web.stopLoading()
        if let empty = URL(string: "about:blank") { web.load(URLRequest(url: empty)) }
    }

    // MARK: displays, sleep and the session

    private func observe() {
        let app = NotificationCenter.default
        observers.append(app.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.setScreensAsleep(true) } })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.setScreensAsleep(false) } })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.setSessionAway(true) } })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.setSessionAway(false) } })
    }

    /// Displays came, went or changed size.
    private func screensChanged() {
        guard isOn, url != nil else { return }
        arrange()
    }

    private func setScreensAsleep(_ asleep: Bool) {
        guard screensAsleep != asleep else { return }
        screensAsleep = asleep
        refreshPages()
    }

    private func setSessionAway(_ away: Bool) {
        guard sessionAway != away else { return }
        sessionAway = away
        refreshPages()
    }
}
#endif
