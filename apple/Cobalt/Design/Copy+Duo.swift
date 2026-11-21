import Foundation

/// Copy for the two-pane (spread) layouts of the Duo redesign: what the right pane says before anything is picked.
extension Copy {
    enum Duo {
        static let otherScreen = "open on the other screen"
        /// The close every right-hand panel has (`SidePanel.swift`).
        static let hidePanel = "hide this side"
    }
}

/// Symbols for the two-screen pieces.
extension Symbol {
    enum Duo {
        static let otherScreen = "rectangle.split.2x1"
        static let hidePanel = "xmark"
    }
}
