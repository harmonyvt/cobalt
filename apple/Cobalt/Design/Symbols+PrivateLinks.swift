import SwiftUI

/// Symbols for private share links (APP-API-CONTRACT 36), compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    enum PrivateLinks {
        static let off = "eye.slash"
        static let publicLink = "globe"
        static let privateLink = "key.horizontal"
        static let lock = "lock.fill"
        static let copy = "doc.on.doc"
        static let copied = "checkmark"
        static let rotate = "arrow.triangle.2.circlepath"
        static let opened = "eye"
        static let made = "calendar"
        static let privacy = "lock.shield"
        static let makePrivate = "lock"
        static let makePublic = "globe"
        static let count = "number"
        static let newLinks = "link.badge.plus"
    }
}
