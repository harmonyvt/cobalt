import CobaltKit
import Foundation

/// Copy for gallery share links (APP-API-CONTRACT section 24; all new, lowercase): the library's `make share link` bar
/// and the links tab. Plain values only (counts, dates, CobaltKit types), since `Cobalt/Design` is compiled into the
/// extensions too.
extension Copy {
    enum Links {
        static let title = "links"

        // MARK: the library's select bar

        static let make = "make share link"
        static let making = "making link…"
        static let makeA11yHint = "makes one link for the picked files and copies it"
        /// Shown while the pick is fine: "3 files · one link".
        static func ready(_ count: Int) -> String { "\(count) files · one link" }
        static let tooFew = "pick 2 or more"
        static func tooMany(_ max: Int) -> String { "\(max) at most" }
        /// "1 is private · make these public first".
        static func notPublic(_ count: Int) -> String {
            "\(count) \(count == 1 ? "is" : "are") private · make these public first"
        }
        /// The status when the server says a picked file is private now.
        static let makeThesePublic = "make these public first"

        /// The bar's line for a verdict (the picked count is for the ready line).
        static func line(for verdict: ShareSetVerdict, count: Int) -> String {
            switch verdict {
            case .ready: return ready(count)
            case .tooFew: return tooFew
            case .tooMany(let max): return tooMany(max)
            case .notPublic(let n): return notPublic(n)
            }
        }

        // MARK: the tab

        static let loading = "loading links…"
        static let emptyTitle = "no links yet"
        static let emptyBody = "select files in the library and make a share link"
        static let failedTitle = "can't load your links"
        static let retry = "try again"
        static let refresh = "refresh"
        /// Above the list when a refresh failed but the last list is still shown.
        static let staleLine = "can't reach the server · showing the last list"

        // MARK: a row

        static func fileCount(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
        static func privateNow(_ count: Int) -> String {
            "\(count) \(count == 1 ? "file is" : "files are") private now"
        }
        static let allPrivate = "link is off until a file is public"
        static func rowA11y(title: String, files: Int, when: String) -> String {
            "\(title), \(fileCount(files)), made \(when)"
        }

        // MARK: actions

        static let copyLink = "copy link"
        static let share = "share"
        static let revoke = "revoke"
        static let revokeTitle = "revoke this link?"
        static let revokeMessage = "the link stops working at once. the files stay in your library."
        static let keep = "keep"
        static let revoked = "link revoked"
    }
}
