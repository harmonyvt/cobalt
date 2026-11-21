import Foundation

// What the whole app does when it comes back to the front, through the app's one listener (`AppLifecycle`, `.work`).
// This used to be AppShell's `.onChange(of: scenePhase)`: one copy per window (two Mac windows ran it twice), and a
// launch with no window yet never ran it at all. Leaving is the objects' own business (`JobQueue`, `UnifiedQueue`,
// `ContinuedProcessing`, `LiveActivityManager` register themselves); this is the coming back.

extension AppModel {
    /// Called once, by `AppModel.live()`. The stores that poll stop on their own when the app leaves the screen, so a
    /// screen kept alive behind another tab cannot keep them reading.
    func observeLifecycle(_ lifecycle: AppLifecycle = .shared) {
        let hook = AppModelLifecycle(model: self)
        lifecycleHook = hook
        queue.observeLifecycle(lifecycle)
        unifiedQueue.observeLifecycle(lifecycle)
        stage.observeLifecycle(lifecycle)
        swarms.observeLifecycle(lifecycle)
        lifecycle.register(hook, order: .work)
    }

    /// The window's launch task and every activation share this: the server check and the pickup (`foreground()`),
    /// then the preview frames that wait, and the swarms badge.
    ///
    /// Launch: AppShell's `.task` runs `foreground()` when the first window appears, and "did become active" follows a
    /// moment later. That second one must not check and reload again, so an activation only starts a new run when the
    /// app left the front (or was about to come back) since the last run began (`activationNeedsForeground`); otherwise
    /// it waits for the run in flight, if any. On iOS "left" is resign, background or will-enter-foreground, as
    /// scenePhase leaving `.active` was. On the Mac it is being hidden: scenePhase never changed for Cmd-Tab, and a
    /// root that went away while cobalt was behind is `MacFolder.observeActivation`'s.
    func activated() {
        let fresh = activationNeedsForeground
        Task { @MainActor [weak self] in
            guard let self else { return }
            if fresh {
                await self.foreground()
            } else if let running = self.foregrounding {
                await running.value
            }
            await self.store.backfillPreviewFrames()
        }
        // the "swarms" badge: what waits for the owner is known before the tab is opened (the launch task reads it too)
        if fresh, AppTab.swarms.isAvailable(with: capabilities) {
            Task { @MainActor [weak self] in await self?.swarms.loadList() }
        }
    }
}

/// AppModel's listener, kept apart so AppModel's public surface does not grow a `lifecycle(_:snapshot:)`.
@MainActor
final class AppModelLifecycle: LifecycleAware {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        guard let model else { return }
        switch event {
        case .becameActive:
            model.activated()
        #if os(macOS)
        case .hidden:
            model.activationNeedsForeground = true
        #else
        case .willResignActive, .didEnterBackground, .willEnterForeground:
            model.activationNeedsForeground = true
        #endif
        default:
            break
        }
    }
}
