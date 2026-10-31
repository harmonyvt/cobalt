import Foundation

/// Copy for sharing a chat as a web page (APP-API-CONTRACT 46; all new, lowercase): the thread menu's item and the share
/// sheet. Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum ChatSharing {
        static let menu = "share as web page…"
        static let title = "share this chat"
        static let intro = "makes a web page of this chat that anyone with the link can open. it shows the chat up to now, with its cards, and its videos and pictures play right there."
        static let make = "make a link"
        static let making = "making…"
        static let media = "videos and pictures"
        static let mediaDetail = "they play on the page, private ones too"
        static let code = "show code"
        static let codeDetail = "folded under each step"
        static let upTo = "shared up to"
        static func upToValue(_ shown: Int) -> String { shown == 1 ? "1 message" : "\(shown) messages" }
        static func behind(_ n: Int) -> String { n == 1 ? "1 newer message" : "\(n) newer messages" }
        static let update = "update"
        static let upToDate = "up to date"
        static let opened = "opened"
        static func openedValue(_ n: Int) -> String { n == 0 ? "not yet" : n == 1 ? "1 time" : "\(n) times" }
        static let copy = "copy link"
        static let copied = "copied"
        static let open = "open"
        static let rotate = "new link"
        static let stop = "stop sharing"
        static let rotateTitle = "make a new link?"
        static let rotateMessage = "the old link stops working at once."
        static let stopTitle = "stop sharing this chat?"
        static let stopMessage = "the link stops working at once and the chat is private again."
        static let note = "hidden posts and anything after \"shared up to\" stay out. private links the chat mentions show as [private link]."
        static let updated = "page updated"
        static let rotated = "new link made, the old one is off"
        static let stopped = "chat is private again"
        static let loading = "checking…"
        static let empty = "say something first, there's nothing to share yet"
        static let off = "sharing isn't on for this server"
        static let failed = "couldn't reach the server, try again"
    }
}
