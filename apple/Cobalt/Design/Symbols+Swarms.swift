import SwiftUI

/// SF Symbols for the swarms screens (apple/CONTRACT-SWARMS.md): the tab, the three facts, the agent grid's rows, the check
/// screen's ticks, the board. An extension of `Symbol` in its own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    enum Swarms {
        /// The tab and its row in "more" and the sidebar.
        static let tab = "circle.grid.3x3"
        /// The three facts: what happens to your data, how big, what it costs.
        static let factSafe = "checkmark.shield"
        static let factLooks = "eye"
        static let factChanges = "pencil.and.list.clipboard"
        static let factSize = "bolt"
        static let factCost = "dollarsign.circle"
        static let factSpent = "dollarsign.circle"
        static let factDuplicates = "square.on.square"
        /// "see exactly what it's told".
        static let told = "text.alignleft"
        static let more = "chevron.right"
        static let results = "square.grid.2x2"
        static let changes = "list.bullet"
        /// A row that asks, and one that failed.
        static let asking = "questionmark.bubble"
        static let failed = "exclamationmark.triangle"
        static let retry = "arrow.clockwise"
        static let stop = "stop.fill"
        /// The agent sheet's arrows, reply and close.
        static let previous = "chevron.left"
        static let next = "chevron.right"
        static let send = "arrow.up.circle.fill"
        static let close = "xmark"
        /// The check screen's tick states.
        static let ticked = "checkmark.square.fill"
        static let unticked = "square"
        static let applied = "checkmark.circle.fill"
        static let changeFailed = "xmark.circle.fill"
        static let clash = "exclamationmark.circle"
        static let edit = "pencil"
        /// The board.
        static let sort = "arrow.up.arrow.down"
        static let open = "arrow.up.right.square"
        static let link = "link"
    }
}
