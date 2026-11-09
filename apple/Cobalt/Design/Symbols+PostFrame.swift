import SwiftUI

/// SF Symbols for post frames (APP-API-CONTRACT 52), one name per meaning. The card icons are plain shapes (a bubble, a heart,
/// bars), never a site's logo. All exist in SF Symbols 4 (iOS 16 / macOS 13) or earlier.
extension Symbol {
    enum PostFrame {
        /// The "post frame" button, the editor's "post" tool, a framed copy's queue row.
        static let frame = "person.text.rectangle"
        static let light = "sun.max"
        static let dark = "moon"
        static let lookUpAgain = "arrow.clockwise"
        static let openInEditor = "film.stack"
        static let gone = "exclamationmark.triangle"
        // inside the cards
        static let verified = "checkmark.seal.fill"
        static let reply = "bubble.left"
        static let repost = "arrow.2.squarepath"
        static let like = "heart"
        static let views = "chart.bar"
        static let comment = "bubble.right"
        static let send = "paperplane"
        static let bookmark = "bookmark"
        static let thumbUp = "hand.thumbsup"
        static let more = "ellipsis"
        static let play = "play.fill"
        static let link = "link"
    }
}
