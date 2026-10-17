import SwiftUI

/// SF Symbols for gallery share links (APP-API-CONTRACT section 24): the tab, a revoke, a video's play glyph. An
/// extension of `Symbol` in its own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    /// The links tab and its sidebar row.
    static let links = "link.circle"
    /// The empty state.
    static let linksEmpty = "link.badge.plus"
    /// Revoke a link: it stops working.
    static let revokeLink = "minus.circle"
    /// A file in a link that is private now.
    static let linkFilePrivate = "lock.fill"
    /// A video in a link's strip.
    static let linkFilePlay = "play.fill"
}
