import Foundation

// Kept apart from Media/MediaPipeline.swift: a `@MainActor` type makes its whole file main-thread code to
// MainThreadLintTests, and the pipeline's decoders run off main.

/// A `Purgeable` made of a closure, for caches that are not on the main actor (an NSCache behind a static, an actor's
/// memory): `AppLifecycle` holds purgeables weakly, so the hooks are kept here for the life of the process. Only for
/// process-lifetime caches: each call adds one hook for good.
@MainActor
public final class PurgeHook: Purgeable {
    private static var kept: [PurgeHook] = []
    private let action: @MainActor (PurgeLevel) -> Void

    private init(_ action: @escaping @MainActor (PurgeLevel) -> Void) { self.action = action }

    /// Runs `action` on every purge (`.background` and `.memoryWarning`) of `lifecycle`.
    @discardableResult
    public static func register(
        with lifecycle: AppLifecycle = .shared, _ action: @escaping @MainActor (PurgeLevel) -> Void
    ) -> PurgeHook {
        let hook = PurgeHook(action)
        kept.append(hook)
        lifecycle.register(purgeable: hook)
        return hook
    }

    public func purge(_ level: PurgeLevel) { action(level) }
}
