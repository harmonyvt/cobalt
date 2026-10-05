import Foundation

/// The identifiers of the background `URLSession`s (CONTRACT-SYNC.md section 4). Each share-sheet run
/// gets its own: only one process may use a background session at a time.
enum BackgroundSessionID {
    static let prefix = "com.capybaraharmony.cobalt.bg."
    static let app = prefix + "app"
    static func share(job: UUID) -> String { prefix + "share." + job.uuidString.lowercased() }
}
