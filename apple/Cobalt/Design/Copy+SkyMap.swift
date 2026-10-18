import Foundation

/// Copy for the library's sky map (APP-API-CONTRACT 21, `GET /library/map`; the web library's "sky map" view is the
/// original, `deploy/cloudflare/web/src/library/page.html`). All lowercase. Plain values only (counts, words), so it
/// compiles into the share extension and the widgets too (`Cobalt/Design` is shared).
extension Copy {
    enum SkyMap {
        /// The toolbar button and the screen's title.
        static let title = "sky map"
        /// The button's hint: what the map is.
        static let hint = "your library as a sky: posts with similar meaning sit close together"

        // MARK: the header

        static func posts(_ n: Int) -> String { n == 1 ? "1 post" : "\(n) posts" }
        /// "150 posts · 6 constellations".
        static func counts(posts n: Int, constellations: Int) -> String {
            "\(posts(n)) · \(constellations == 1 ? "1 constellation" : "\(constellations) constellations")"
        }
        /// While the stars settle (a thin bar under the counts).
        static let arranging = "arranging the stars…"
        /// "3 not mapped yet": live posts the search has not indexed.
        static func unmapped(_ n: Int) -> String { "\(n) not mapped yet" }
        static let loading = "loading your sky…"

        // MARK: states

        static let emptyTitle = "nothing on the map yet"
        static let emptyDetail = "posts appear here once the search has indexed them"
        static let failedTitle = "can't load the sky map."
        static let tryAgain = "try again"

        // MARK: controls

        static let close = "close"
        static let resetView = "reset view"
        static let resetHint = "back to the whole sky"

        // MARK: a post's preview

        static let untitled = "untitled"
        /// "near: cats · printer · coffee": what the post's neighbourhood is about.
        static func near(_ words: [String]) -> String { "near: " + words.joined(separator: " · ") }
        static let open = "open"
        /// The fingerprint's caption (its 256 numbers as stars), read aloud rather than shown.
        static let fingerprintA11y = "the post's 256 embedding numbers as a 16 by 16 field of stars: bigger is stronger, blue above zero, amber below"

        /// The canvas, for VoiceOver.
        static func mapA11y(posts: Int, constellations: Int) -> String {
            "\(title). \(counts(posts: posts, constellations: constellations)). \(hint)."
        }
    }
}
