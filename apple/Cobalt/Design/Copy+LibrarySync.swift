import Foundation

/// Copy for settings › "library sync" (CONTRACT-SYNC / APP-API-CONTRACT 45). All lowercase. Its own
/// file so the sync lane never edits `Copy.swift`; compiled into the app only.
extension Copy {
    enum LibrarySync {
        static let group = "library sync"
        static let toggle = "keep the library on this device"
        static var footer: String { "capystore keeps a copy of your library on this \(device), so it opens at once and your changes wait here while you are offline. the line below the switch says what it is doing. the switch takes effect right away." }

        // status line
        static let statusIdle = "up to date"
        static let statusSyncing = "syncing…"
        static let statusRepulling = "downloading your library again…"
        static let statusDisabled = "this server has no library sync. capystore loads your library the usual way."
        static func statusOffline(pending: Int) -> String {
            pending == 0 ? "offline · showing your saved copy" : "offline · \(waiting(pending))"
        }
        static func waiting(_ n: Int) -> String { n == 1 ? "1 change waiting" : "\(n) changes waiting" }

        // error
        static let errorTitle = "library sync hit a problem"
        static func errorDetail(code: String?) -> String {
            code.map { "the server said \($0)." } ?? "the server did not answer the way capystore expected."
        }
        static let retryingIn = "trying again in"
        static let retry = "retry"
        static let dismiss = "dismiss"
    }
}
