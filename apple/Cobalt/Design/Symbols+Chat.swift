import SwiftUI

/// SF Symbols for chat (APP-API-CONTRACT section 27): the tab, the composer, a code step. An extension of `Symbol` in its
/// own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    /// The chat tab and its sidebar row.
    static let chat = "bubble.left.and.text.bubble.right"
    /// The empty state.
    static let chatEmpty = "bubble.left.and.bubble.right"
    /// "new chat".
    static let chatNew = "square.and.pencil"
    /// "ask about this" in a post's menu.
    static let chatAsk = "bubble.left.and.text.bubble.right"
    /// A thread's menu.
    static let chatMenu = "ellipsis.circle"
    /// Send.
    static let chatSend = "arrow.up.circle.fill"
    /// Send, inside the composer's filled icon circle (the circle is the button, so no `.circle.fill`).
    static let chatSendArrow = "arrow.up"
    /// A box card's "show all" / "show less".
    static let chatShowAll = "chevron.down"
    static let chatShowLess = "chevron.up"
    /// A code step.
    static let chatCode = "chevron.left.forwardslash.chevron.right"
    /// A step that failed.
    static let chatCodeFailed = "exclamationmark.triangle"
    /// An open step's chevron.
    static let chatDisclosure = "chevron.right"
    /// A post the reply showed that is not in the library any more.
    static let chatRemoved = "photo.badge.exclamationmark"
    /// A video in a shown post's tile.
    static let chatPlay = "play.fill"
    /// Remove an attachment chip.
    static let chatDetach = "xmark.circle.fill"
    /// Rename a thread.
    static let chatRename = "pencil"
    /// Share a thread as a web page (46), and the share sheet's actions.
    static let chatShare = "globe"
    static let chatShareCopy = "doc.on.doc"
    static let chatShareOpen = "safari"
    static let chatShareRotate = "arrow.triangle.2.circlepath"
    static let chatShareStop = "xmark.circle"
    static let chatShareUpdate = "arrow.clockwise"
    /// Delete a thread.
    static let chatDelete = "trash"
    /// Jump to the newest message.
    static let chatLatest = "arrow.down.circle.fill"
    /// "open in library" on a collage: runs its search in the library.
    static let chatCollageLibrary = "square.grid.2x2"
    /// A confirm card: the chat asks first.
    static let chatConfirm = "hand.raised"
    /// A confirm card that was answered yes.
    static let chatConfirmDone = "checkmark.circle"
    /// A confirm card answered no, or one that timed out.
    static let chatConfirmKept = "xmark.circle"
    /// Helpers (sub-agents, APP-API-CONTRACT 43.6): the strip under a thread's header and the agents card.
    static let chatHelpers = "person.2"
    /// A helper's status dot (pulses while it works).
    static let chatHelperDot = "circle.fill"
    /// A message to a helper (or from a helper to the chat).
    static let chatHelperSent = "arrow.turn.up.right"
    /// A message received.
    static let chatHelperReceived = "arrow.turn.down.left"
    /// "make video" (APP-API-CONTRACT 45): the thread's menu, a message's menu, a chat video's queue row.
    static let chatVideo = "film"
}
