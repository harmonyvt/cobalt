import Foundation

/// The identifiers of the background `URLSession`s (CONTRACT-SYNC.md section 4). Each share-sheet run
/// gets its own: only one process may use a background session at a time.
enum BackgroundSessionID {
    static let prefix = "com.capybaraharmony.cobalt.bg."
    static let app = prefix + "app"
    static func share(job: UUID) -> String { prefix + "share." + job.uuidString.lowercased() }

    /// The instant share's save request (`POST /studio`, CONTRACT-SHARE-QUICK.md section 9): one session per
    /// share, under the same prefix so the app's `.backgroundTask(.urlSession(matching:))` is woken for it.
    static let savePrefix = prefix + "save."
    static func save(job: UUID) -> String { savePrefix + job.uuidString.lowercased() }
    static func isSave(_ identifier: String) -> Bool { identifier.hasPrefix(savePrefix) }
}
