import CobaltKit
import Foundation

/// Copy for what a save says while it runs and when it fails (apple 02-PHASE2 2.2.2 to 2.2.4): the part the server is on
/// (downloading from the site, storing in the library), which downloader runs it and when it switched, the copy on this
/// device, the share card's summary, and a plain sentence for every error code the server can answer (the table of
/// `extension/src/lib/progress.ts`). All lowercase. Plain values only (no model state), so it compiles into the share
/// extension and the widgets too (`Cobalt/Design` is shared).
extension Copy {
    enum Save {
        // MARK: the downloaders

        /// "cobalt" / "yt-dlp".
        static func engine(_ engine: SaveEngine) -> String {
            switch engine {
            case .cobalt: return "cobalt"
            case .ytdlp: return "yt-dlp"
            }
        }

        /// The headline while a downloader starts up: "waking yt-dlp". The server itself when it does not say which.
        static func waking(_ engine: SaveEngine?) -> String {
            guard let engine else { return Copy.waking }
            return "waking \(Self.engine(engine))"
        }

        /// "switched to yt-dlp · cobalt couldn't download it": the save changed downloaders on its own, and why.
        static func switched(from: SaveEngine, to: SaveEngine, code: String?) -> String {
            "switched to \(engine(to)) · \(engine(from)) \(reason(code))"
        }

        /// The switch without its target engine (the server said `fallback_from` only): the other downloader took over.
        static func switched(from: SaveEngine, code: String?) -> String {
            switched(from: from, to: from == .cobalt ? .ytdlp : .cobalt, code: code)
        }

        /// Why the first downloader gave up, in the words that follow its name.
        private static func reason(_ code: String?) -> String {
            guard let code else { return "couldn't download it" }
            switch FetchProblem(code: code) {
            case .empty: return "found no video"
            case .unavailable: return "couldn't find the post"
            case .isPrivate: return "was refused: the post is private"
            case .ageRestricted: return "was refused: an age limit"
            case .loginRequired: return "was asked to sign in"
            case .region: return "isn't allowed in this region"
            case .live: return "can't save a live stream"
            case .tooLong: return "found it too long"
            case .rateLimited: return "was rate limited"
            case .failed: return "couldn't download it"
            }
        }

        // MARK: the two parts of a save

        /// "storing in your library", then its percent on the right.
        static let storing = "storing in your library"
        static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

        // MARK: the copy on this device

        static var localCopying: String { "copying to this \(Copy.device)…" }
        static var localCopySaved: String { "on this \(Copy.device) too" }
        /// "in your library · device copy failed": the library copy is what counts, so it leads.
        static let inLibrary = "in your library"
        static var localCopyFailed: String { "\(Copy.Save.inLibrary) · device copy failed" }
        static let localCopyRetry = "retry"

        /// Why the copy on this device did not arrive (a code of `Pipeline.localCopyCode`).
        static func localCopyReason(_ code: String) -> String {
            switch code {
            case "error.app.disk_full": return "this \(Copy.device) is full."
            case "error.app.offline": return "no connection."
            case "error.studio.expired", "error.studio.not_found": return "the server no longer has the original."
            case "error.api.auth.key.invalid", "error.api.auth.key.missing": return "the key was refused."
            case "error.app.file_unreadable": return "couldn't read the file."
            default:
                if code.hasPrefix("http.") { return "the server answered \(code.dropFirst(5))." }
                return "something went wrong."
            }
        }

        // MARK: the share card

        /// "3 of 4 ready · 1 failed": the card's summary before the share sheet opens.
        static func sharePrepSummary(ready: Int, of total: Int, failed: Int) -> String {
            failed > 0 ? "\(ready) of \(total) ready · \(failed) failed" : "\(ready) of \(total) ready"
        }
        static let sharePrepRetry = "retry"
        static func sharePrepShareReady(_ n: Int) -> String { n == 1 ? "share the 1 that's ready" : "share the \(n) that are ready" }
        /// Under a row that failed: why, in words.
        static func sharePrepRowFailure(_ code: String) -> String {
            switch code {
            case "error.app.offline": return "no connection"
            case "error.app.disk_full": return "this \(Copy.device) is full"
            case "error.studio.expired", "error.studio.not_found": return "the server no longer has it"
            case "error.api.auth.key.invalid", "error.api.auth.key.missing": return "the key was refused"
            case "error.app.no_file": return "nothing to download"
            default: return code.hasPrefix("http.") ? "the server answered \(code.dropFirst(5))" : "couldn't download it"
            }
        }

        // MARK: failures, one sentence per code

        /// What a failed fetch says about the post.
        static func fetchFailure(_ problem: FetchProblem, code: String) -> String {
            switch problem {
            case .empty: return "capystore couldn't find a video in this post."
            case .unavailable: return "this post isn't available. it may have been removed."
            case .isPrivate: return "this post is private, so capystore can't read it."
            case .ageRestricted: return "this post needs a sign-in to watch (an age limit), so capystore can't read it."
            case .loginRequired: return "youtube asked capystore to sign in. try another link, or try again later."
            case .region: return "this video isn't available where capystore runs."
            case .live: return "live streams can't be saved."
            case .tooLong: return "this video is too long to save."
            case .rateLimited: return "the site is limiting capystore right now. try again in a bit."
            case .failed:
                // the one code the download itself answers; any other keeps the general line
                return code == "error.api.fetch.fail" ? "the download failed. try again." : "capystore couldn't fetch this link. the post may be private or removed."
            }
        }

        /// The server's own save failures that have a sentence; nil for a code that has none.
        static func serverFailure(_ code: String) -> String? {
            switch ServerProblem(code: code) {
            case .saveLost: return "capystore lost track of this save. save it again."
            case .cancelled: return "this save was cancelled."
            case .notFound: return "capystore couldn't find this save."
            case .uploadFailed: return "capystore couldn't store this file."
            case .other: return nil
            }
        }
    }
}
