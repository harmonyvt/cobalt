import Foundation
import Synchronization

/// The Mac app installs these. `LibraryModel` calls `noteRefresh` after a library refresh so the app
/// can `signalEnumerator`. `forgetSession` calls `noteSignOut` so the app can remove the domain.
/// Previews and tests leave the hooks nil.
public enum FinderLibraryEvents {
    private static let refreshHook = Mutex<(@Sendable () -> Void)?>(nil)
    private static let signOutHook = Mutex<(@Sendable () -> Void)?>(nil)

    public static func setRefreshHook(_ hook: (@Sendable () -> Void)?) {
        refreshHook.withLock { $0 = hook }
    }

    public static func setSignOutHook(_ hook: (@Sendable () -> Void)?) {
        signOutHook.withLock { $0 = hook }
    }

    public static func noteRefresh() {
        let hook = refreshHook.withLock { $0 }
        hook?()
    }

    public static func noteSignOut() {
        let hook = signOutHook.withLock { $0 }
        hook?()
    }
}
