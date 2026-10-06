import AppIntents
import CobaltKit
import Foundation

/// What the intents read through `@Dependency` (CONTRACT-PARALLEL.md 15.2.2). The app calls `register(_:)` once, in
/// `CobaltApp.init`, right after the model is built: the model exists before any scene, so an intent that launches the
/// app in the background finds everything it needs (the key in the keychain, the store, the queue).
enum IntentDependencies {
    @MainActor
    static func register(_ model: AppModel) {
        let actions = ShortcutActions(model: model)
        AppDependencyManager.shared.add(dependency: model)
        AppDependencyManager.shared.add(dependency: actions)
    }
}
