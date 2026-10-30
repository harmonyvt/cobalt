import CobaltKit
import SwiftUI

/// Copy and symbols for the hidden album and the bulk `status…` action (APP-API-CONTRACT 37.7). All lowercase. Its
/// own file so the lanes that build the screens never edit `Copy.swift`; compiled into the extensions too
/// (`Cobalt/Design` is shared).
extension Copy {
    enum HiddenAlbum {
        // the chip, last of the kind chips
        static let chipName = "hidden"
        static func chip(count: Int?) -> String { count.map { "\(chipName) \($0)" } ?? chipName }
        static let chipHint = "opens the hidden album"

        // the lock
        static let lockedTitle = "hidden is locked"
        static let lockedNote =
            "posts you hid and posts your rules hid. they are not in all, search, the sky map or photos sync, and nothing in here can be shared."
        /// The reason the system sheet shows.
        static let reason = "show your hidden posts"
        /// What the system will ask, for the button's words (`HiddenLock.method()`).
        enum LockMethod: Sendable, Equatable { case faceID, touchID, passcode }
        static func viewWith(_ method: LockMethod) -> String {
            switch method {
            case .faceID: return "view with face id"
            case .touchID: return "view with touch id"
            case .passcode: return "unlock"
            }
        }
        static let lockedA11yHint = "asks for it before showing hidden posts"
        static let lockFailed = "couldn't unlock hidden."

        // the album
        static func note(_ n: Int) -> String { "\(n) hidden · badge says who hid it" }
        static let empty = "nothing hidden"
        static let emptyNote = "posts you hide, and posts your rules hide, wait here."
        static let loadFailed = "couldn't load hidden."
        static func by(_ by: HiddenBy) -> String {
            switch by {
            case .you: return "you"
            case .rule: return "rule"
            case .chat: return "chat"
            }
        }
        static func byA11y(_ by: HiddenBy) -> String {
            switch by {
            case .you: return "hidden by you"
            case .rule: return "hidden by a rule"
            case .chat: return "hidden by the chat"
            }
        }

        // the select panel's `status…` and `unhide`
        static let status = "status…"
        static let statusHint = "changes every picked post's links at once"
        static let unhide = "unhide"
        static let unhideHint = "puts the picked posts back in the library, with no link"
        static let hide = "hide"
        static let statusHidden = "hidden"
        static let statusOff = "off"
        static let statusPublic = "public link"
        static let statusPrivate = "private link"
        static func name(_ status: PostStatus) -> String {
            switch status {
            case .hidden: return statusHidden
            case .off: return statusOff
            case .public: return statusPublic
            case .private: return statusPrivate
            }
        }

        // the confirms
        static func hideTitle(_ n: Int) -> String { n == 1 ? "hide 1 post?" : "hide \(n) posts?" }
        static func hideMessage(_ n: Int) -> String {
            n == 1
                ? "its links stop working for good, and it moves to library › hidden."
                : "their links stop working for good, and they move to library › hidden."
        }
        static let hideConfirm = "hide"
        static func publicTitle(_ n: Int) -> String { n == 1 ? "make 1 post public?" : "make \(n) posts public?" }
        static func publicMessage(_ n: Int) -> String {
            n == 1 ? "anyone with the link can open it." : "anyone with the link can open them."
        }
        static let publicConfirm = "make public"
        static let cancel = "cancel"

        // what was said afterwards (the shell's status line)
        static func done(_ status: PostStatus, count n: Int, fromAlbum: Bool) -> String {
            switch status {
            case .hidden: return "\(n) hidden"
            case .off: return fromAlbum ? "\(n) back in the library as only you" : "\(n) set to only you"
            case .public: return "\(n) public"
            case .private: return "\(n) with a private link"
            }
        }
        /// Posts the server refused.
        static func failed(_ n: Int) -> String { "\(n) couldn't change" }
        /// Posts that took the status but have files the server could not switch.
        static func filesFailed(_ n: Int) -> String { n == 1 ? "1 has a file that couldn't change" : "\(n) have files that couldn't change" }

        // the Mac context menu
        static let menuHide = "hide…"
        static let menuUnhide = "unhide"
    }
}

extension Symbol {
    enum HiddenAlbum {
        /// The `hidden` chip is text only; these are the panel's and the menus'.
        static let status = "switch.2"
        static let hidden = "eye.slash"
        static let unhide = "eye"
        static let off = "xmark.circle"
        static let publicLink = "globe"
        static let privateLink = "key.horizontal"
        static let lock = "lock.fill"
        static let empty = "eye.slash"
    }
}
