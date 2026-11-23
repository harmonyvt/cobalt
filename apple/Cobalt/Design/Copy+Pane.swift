import CobaltKit
import Foundation

/// Copy for the screen pane (apple/CONTRACT-PANE.md): its header, bar, shelf and states. All lowercase.
extension Copy {
    enum Pane {
        /// The header's leading button: the pane takes the whole window (both screens on a Duo).
        static let span = "fill the window"
        /// The same button while spanned: back beside the tab.
        static let unspan = "back beside the tab"
        /// The header's `more` menu.
        static let more = "more"
        /// The header's xmark: hides the pane (never stops anything).
        static let close = "close"
        /// The bar's VoiceOver action and hover name: opens the running item again.
        static let reopen = "open"
        /// ⌘[ and ⌘] (and the dots' VoiceOver actions).
        static let shelfBack = "previous card"
        static let shelfNext = "next card"
        /// The shelf's dots, for VoiceOver: "card 2 of 3".
        static func shelfPosition(_ index: Int, of count: Int) -> String { "card \(index + 1) of \(count)" }
        /// The pane as a VoiceOver container: "pane, <title>".
        static func container(_ title: String) -> String { "pane, \(title)" }
        /// A deleted item: one line and a close.
        static let gone = "this isn't here any more."
        /// The placeholder a loading page shows to VoiceOver.
        static let loading = "loading"
        /// An action that needs the server while it can't be reached.
        static let needsServer = "needs the server"
        /// The placeholder page of an area that has not moved into the pane yet.
        static let notYet = "this opens here soon."

        /// The centred label in the header: which part of the app the item comes from.
        static func context(_ item: PaneItem) -> String {
            switch item {
            case .post, .peek, .selection: "library"
            case .save: "save"
            case .link: "link"
            case .collection: "collection"
            case .emote, .emoteAddToSet: "7tv"
            case .reward, .poolVideo: "studio"
            case .stream: "twitch"
            case .booruPost, .booruFilters: "booru"
            case .swarm: "swarm"
            case .name: "name"
            case .job: "queue"
            }
        }
    }
}
