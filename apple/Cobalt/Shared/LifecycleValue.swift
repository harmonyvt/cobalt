import CobaltKit
import SwiftUI

// The Environment entry for the app's lifecycle snapshot (apple/ARCHITECTURE.md, "Who owns what"). Who feeds it:
// `publishesLifecycle()` in Cobalt/App/LifecycleEnvironment.swift. It lives in Cobalt/Shared because the share
// extension compiles this folder (PreviewSupport sets it) but not Cobalt/App.

extension EnvironmentValues {
    /// The whole app's phase, memory pressure and thermal state (not one window's scenePhase).
    @Entry var lifecycle = LifecycleSnapshot()
}
