import SwiftUI

/// Symbols for the screen pane (apple/CONTRACT-PANE.md). An extension of `Symbol` in its own file so this work never
/// edits `Symbols.swift`.
extension Symbol {
    enum Pane {
        static let span = "arrow.up.left.and.arrow.down.right"
        static let unspan = "arrow.down.right.and.arrow.up.left"
        static let more = "ellipsis"
        static let close = "xmark"
        static let shelfBack = "chevron.left"
        static let shelfNext = "chevron.right"
        static let gone = "questionmark.square.dashed"
        static let placeholder = "square.dashed"
    }
}
