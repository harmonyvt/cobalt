import Foundation

/// The identifiers of the background `URLSession`s (CONTRACT-SYNC.md section 4). Each share-sheet run
/// gets its own: only one process may use a background session at a time.
enum BackgroundSessionID {
    static let prefix = "com.capybaraharmony.cobalt.bg."
    static let app = prefix + "app"
    /// The app's studio uploads (`BackgroundUploads`), one session for all of them.
    static let upload = prefix + "upload"
    static func share(job: UUID) -> String { prefix + "share." + job.uuidString.lowercased() }

    /// The instant share's save request (`POST /studio`, CONTRACT-SHARE-QUICK.md section 9): one session per
    /// share, under the same prefix so the app's `.backgroundTask(.urlSession(matching:))` is woken for it.
    static let savePrefix = prefix + "save."
    static func save(job: UUID) -> String { savePrefix + job.uuidString.lowercased() }
    static func isSave(_ identifier: String) -> Bool { identifier.hasPrefix(savePrefix) }

    /// The share sheet's photo and video uploads (CONTRACT-SHARE-QUICK.md section 10): a save session (the same wake), with
    /// its own name so the session can give a large video hours instead of a link save's 10 minutes.
    static let uploadSavePrefix = savePrefix + "upload."
    static func uploadSave(job: UUID) -> String { uploadSavePrefix + job.uuidString.lowercased() }
    static func isUploadSave(_ identifier: String) -> Bool { identifier.hasPrefix(uploadSavePrefix) }
    /// The share's job id in a save session's name (the "saving" notification is keyed by it).
    static func saveJob(_ identifier: String) -> UUID? {
        guard isSave(identifier) else { return nil }
        let rest = isUploadSave(identifier) ? identifier.dropFirst(uploadSavePrefix.count) : identifier.dropFirst(savePrefix.count)
        return UUID(uuidString: String(rest))
    }
}
