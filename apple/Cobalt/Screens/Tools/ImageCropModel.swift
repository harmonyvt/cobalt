import CobaltKit
import CoreGraphics
import Foundation
import Observation

/// The crop being made in `ImageCropSheet` (apple/CONTRACT-EDITOR.md 13): the box over the picture AS SHOWN (turned and flipped,
/// in its pixels), the aspect it is locked to, the turn, the flip and `remove background`. `spec` turns the box back into
/// fractions of the stored picture, which is what `ImageCropper` and the route take. The drags are the video crop's
/// (`CropGeometry`).
@MainActor @Observable
final class ImageCropModel {
    enum Aspect: String, CaseIterable, Identifiable {
        case free, original, square, portrait, story, wide
        var id: String { rawValue }

        var label: String {
            switch self {
            case .free: return Copy.Editor.cropFree
            case .original: return Copy.Editor.cropOriginal
            case .square: return "1:1"
            case .portrait: return "4:5"
            case .story: return "9:16"
            case .wide: return "16:9"
            }
        }

        /// Width over height; nil for `free` and `original` (the picture's own, which depends on the turn).
        var ratio: CGFloat? {
            switch self {
            case .free, .original: return nil
            case .square: return 1
            case .portrait: return 4.0 / 5.0
            case .story: return 9.0 / 16.0
            case .wide: return 16.0 / 9.0
            }
        }
    }

    /// The picture's size in pixels as stored (before any turn).
    let source: CGSize
    private(set) var rotate = 0
    private(set) var flip: ImageCropFlip = .none
    private(set) var aspect: Aspect = .free
    /// The box in pixels of the picture as shown.
    private(set) var rect: CGRect
    var cutout = false
    /// A finger (or the pointer) is on the box: the rule-of-thirds lines show.
    var isAdjusting = false
    /// Bumped when a chip, a turn, a flip or a reset snaps the box: the selection haptic.
    private(set) var snaps = 0

    init(source: CGSize) {
        self.source = CGSize(width: max(1, source.width), height: max(1, source.height))
        rect = CGRect(origin: .zero, size: self.source)
    }

    /// The picture as shown: its sides swap with a quarter turn.
    var display: CGSize { rotate % 180 == 0 ? source : CGSize(width: source.height, height: source.width) }

    /// The smallest side a drag leaves the box (it cannot vanish under a finger).
    var floorSide: CGFloat { max(2, min(16, min(display.width, display.height) / 4)) }

    /// Width over height the box is locked to; nil when it is free.
    var lockedRatio: CGFloat? {
        if aspect == .original { return display.height > 0 ? display.width / display.height : nil }
        return aspect.ratio
    }

    /// The box in fractions of the picture as shown.
    var shownBox: ImageCropRect {
        ImageCropRect(
            x: Double(rect.minX / display.width), y: Double(rect.minY / display.height),
            w: Double(rect.width / display.width), h: Double(rect.height / display.height))
    }

    var spec: ImageCropSpec {
        ImageCropSpec(crop: ImageCropSpec.stored(shownBox, rotate: rotate, flip: flip), rotate: rotate, flip: flip, cutout: cutout)
    }

    /// The result's size in pixels (before a background removal trims it); nil when the box is under 2 x 2 px.
    var output: (width: Int, height: Int)? {
        ImageCropper.outputSize(spec, width: Int(source.width.rounded()), height: Int(source.height.rounded()))
    }

    /// Something to make: a box at least 2 x 2 px that changes the picture.
    var canMake: Bool { output != nil && spec.changesSomething }

    // MARK: changing it

    func choose(_ new: Aspect) {
        guard new != aspect else { return }
        aspect = new
        if let ratio = lockedRatio { rect = Self.fit(ratio: ratio, inside: rect, bounds: display, floor: floorSide) }
        snaps += 1
    }

    /// The whole picture, unturned, unflipped, free.
    func reset() {
        rotate = 0
        flip = .none
        aspect = .free
        rect = CGRect(origin: .zero, size: source)
        snaps += 1
    }

    /// The shown picture a quarter turn left; the box turns with it (and keeps its aspect).
    func rotateLeft() {
        let b = shownBox
        rotate = ImageCropSpec.turnedLeft(rotate: rotate, flip: flip)
        // a quarter turn left: shown (x, y) goes to (y, 1 - x)
        let turned = ImageCropRect(x: b.y, y: 1 - b.x - b.w, w: b.h, h: b.w)
        rect = pixels(turned)
        if let ratio = lockedRatio { rect = Self.fit(ratio: ratio, inside: rect, bounds: display, floor: floorSide) }
        snaps += 1
    }

    /// The shown picture mirrored left to right; the box mirrors with it.
    func toggleFlip() {
        let b = shownBox
        flip = flip == .none ? .h : .none
        rect = pixels(ImageCropRect(x: 1 - b.x - b.w, y: b.y, w: b.w, h: b.h))
        snaps += 1
    }

    /// One drag step: `part` of the box as it was when the finger went down (`origin`), moved by `translation` (pixels of
    /// the shown picture). `keepShape` (shift on the Mac) locks a free box to the shape it had.
    func drag(_ part: CropGeometry.Part, from origin: CGRect, by translation: CGSize, keepShape: Bool = false) {
        let ratio = lockedRatio ?? (keepShape && origin.height > 0 ? origin.width / origin.height : nil)
        switch part {
        case .move:
            rect = CropGeometry.move(origin, by: translation, in: display)
        case .corner(let corner):
            let p = CGPoint(
                x: (corner.isLeft ? origin.minX : origin.maxX) + translation.width,
                y: (corner.isTop ? origin.minY : origin.maxY) + translation.height)
            rect = CropGeometry.resize(corner: corner, of: origin, to: p, in: display, ratio: ratio, minSide: floorSide)
        case .edge(let edge):
            let p: CGPoint
            switch edge {
            case .left: p = CGPoint(x: origin.minX + translation.width, y: origin.midY)
            case .right: p = CGPoint(x: origin.maxX + translation.width, y: origin.midY)
            case .top: p = CGPoint(x: origin.midX, y: origin.minY + translation.height)
            case .bottom: p = CGPoint(x: origin.midX, y: origin.maxY + translation.height)
            }
            rect = CropGeometry.resize(edge: edge, of: origin, to: p, in: display, ratio: ratio, minSide: floorSide)
        }
    }

    /// Arrow keys and VoiceOver: a move by fractions of the shown picture.
    func nudge(dx: CGFloat, dy: CGFloat) {
        rect = CropGeometry.move(rect, by: CGSize(width: dx * display.width, height: dy * display.height), in: display)
    }

    func grow(_ factor: CGFloat) {
        rect = CropGeometry.scale(rect, by: factor, in: display, minSide: floorSide)
    }

    /// VoiceOver on a handle: that corner pulled out (positive) or pushed in by a fraction of the shown picture.
    func pull(_ corner: CropGeometry.Corner, by amount: CGFloat) {
        let dx = (corner.isLeft ? -amount : amount) * display.width
        let dy = (corner.isTop ? -amount : amount) * display.height
        drag(.corner(corner), from: rect, by: CGSize(width: dx, height: dy))
    }

    // MARK: helpers

    private func pixels(_ r: ImageCropRect) -> CGRect {
        let d = display
        return CGRect(x: CGFloat(r.x) * d.width, y: CGFloat(r.y) * d.height, width: CGFloat(r.w) * d.width, height: CGFloat(r.h) * d.height)
            .intersection(CGRect(origin: .zero, size: d))
    }

    /// The largest box of `ratio` inside `r`, centred on it; when that is under the floor, the largest of `ratio` around
    /// `r`'s centre that fits the picture.
    static func fit(ratio: CGFloat, inside r: CGRect, bounds: CGSize, floor: CGFloat) -> CGRect {
        guard ratio > 0, r.width > 0, r.height > 0 else { return r }
        var w = r.width, h = w / ratio
        if h > r.height { h = r.height; w = h * ratio }
        if min(w, h) < floor {
            w = min(bounds.width, bounds.height * ratio)
            h = w / ratio
        }
        let x = min(max(0, r.midX - w / 2), max(0, bounds.width - w))
        let y = min(max(0, r.midY - h / 2), max(0, bounds.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
