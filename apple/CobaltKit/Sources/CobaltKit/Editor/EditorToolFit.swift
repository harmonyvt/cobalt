import CoreGraphics
import Foundation

/// How many tools fit in the tool row or rail (apple/CONTRACT-EDITOR.md 15.1): 44 pt targets side by side, a couple of points
/// at either end. What does not fit goes in a `more` menu; `done` always stays at the end. No scrolling.
public enum EditorToolFit {
    public static let slot: CGFloat = 44
    public static let spacing: CGFloat = 0
    public static let edge: CGFloat = 2

    /// How many 44 pt slots a length holds.
    public static func slots(length: CGFloat) -> Int {
        guard length.isFinite, length > 0 else { return 0 }
        let usable = length - 2 * edge + spacing + 0.001
        return max(0, Int((usable / (slot + spacing)).rounded(.down)))
    }

    /// The first `shown` of `items` go in the row; the rest (when `more`) go in the menu behind one more slot, and the `done`
    /// that follows (when `done`) keeps its own.
    public struct Split: Equatable, Sendable {
        public var shown: Int
        public var more: Bool
    }

    public static func split(items: Int, done: Bool, length: CGFloat) -> Split {
        let capacity = slots(length: length)
        let doneSlot = done ? 1 : 0
        if items + doneSlot <= capacity { return Split(shown: items, more: false) }
        return Split(shown: max(0, min(items, capacity - 1 - doneSlot)), more: true)
    }
}
