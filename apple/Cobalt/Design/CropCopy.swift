import CobaltKit
import CoreGraphics
import Foundation

/// The crop editor's words and symbol (CONTRACT-ORBIT 2d). Kept out of `Copy.swift` and `Symbols.swift`
/// so the crop lane never collides with the lanes that edit those. Lowercase, like every control.
enum CropCopy {
    static let symbol = "crop"

    static let crop = "crop"
    static let cropA11yHint = "choose the part of the picture the webp keeps"
    static let done = "done"
    static let reset = "reset"
    static let shape = "shape"
    static let editorA11y = "crop area"
    static let editorHint = "drag to move, pinch to resize. use the actions to nudge it."
    static let note = "drag the corners, drag inside to move, pinch to resize."
    static let tooSmall = "keep at least 64 px on each side."
    static let tooSmallA11y = "the crop is too small. keep at least 64 pixels on each side."
    static let output = "webp size"

    static let moveLeft = "move left"
    static let moveRight = "move right"
    static let moveUp = "move up"
    static let moveDown = "move down"
    static let bigger = "bigger"
    static let smaller = "smaller"

    /// "480×480".
    static func readout(_ size: CGSize) -> String {
        Format.size(Int(size.width.rounded()), Int(size.height.rounded()))
    }

    /// What a preset says in the segmented control: "original", "1:1", ... "free".
    static func label(_ aspect: CropRect.Aspect) -> String { aspect.label }

    /// The little badge next to the trim readout: "crop 1:1" for a crop that matches a preset ratio,
    /// plain "crop" for a free shape (and for a zoom that keeps the clip's own shape).
    static func badge(_ rect: CropRect, in source: CGSize?) -> String {
        guard let source, let match = rect.matchedAspect(in: source), match.ratio != nil else { return crop }
        return "\(crop) \(match.label)"
    }

    static func badgeA11y(_ text: String) -> String { "\(text) set" }

    static func readoutA11y(_ size: CGSize) -> String {
        "\(output) \(Int(size.width.rounded())) by \(Int(size.height.rounded()))"
    }
}
