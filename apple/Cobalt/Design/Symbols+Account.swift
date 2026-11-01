import CobaltKit
import SwiftUI

/// Symbols for accounts (sign in, the pinned "sign in again", settings › account).
extension Symbol {
    enum Account {
        static let mark = "bolt.fill"
        static let signIn = "person.crop.circle"
        static let signInAgain = "person.crop.circle.badge.exclamationmark"
        static let signOut = "rectangle.portrait.and.arrow.right"
        static let access = "cloud"
        static let email = "envelope"
        static let signedOut = "icloud.slash"
        static let oldKey = "key.horizontal"
        static let tool = "wrench.and.screwdriver"
        static let oldPaste = "clock.arrow.circlepath"
        static let privateLink = "lock"
        static let library = "checkmark.circle"
        static let devices = "laptopcomputer.and.iphone"
        static let keyStays = "key"
        static let paste = "doc.on.clipboard"
        static let newKey = "plus"
        static let rename = "pencil"
        static let copy = "doc.on.doc"

        static func platform(_ p: AccountPlatform) -> String {
            switch p {
            case .ios: return "iphone"
            case .ipados: return "ipad"
            case .mac: return "desktopcomputer"
            case .web: return "globe"
            }
        }
    }
}

extension CobaltColor {
    /// Accounts' amber (the mockup's `--amber`): the pinned "sign in again" and the "old paste" tag.
    static let amber = Color(light: 0x9a5a00, dark: 0xf5ad5b)
    /// The tag's fill under `amber`.
    static let amberBack = Color(light: 0xfbefd6, dark: 0x2e2416)
}
