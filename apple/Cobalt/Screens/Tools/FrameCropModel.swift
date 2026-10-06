import CobaltKit
import CoreGraphics
import Foundation
import Observation

/// The crop being made (apple/CONTRACT-GALLERY.md 1.23): the frame's shape (`1:1 · 4:5 · 9:16 · 3:4 · free`), how the photo
/// meets it (`cut to fit` with a movable, zoomable rectangle, or the whole photo on blurred bars), and the rectangle. The
/// geometry is the video crop's own (`CropGeometry`: the same handles, the same drag, the same pinch); the numbers are in
/// SOURCE PIXELS of the photo as the owner sees it, and `spec` is what `FrameRenderer` and the server's `made_spec` take.
@MainActor @Observable
final class FrameCropModel {
    enum Phase: Equatable {
        case editing
        /// Rendering and uploading. `fraction` is the upload's, nil while it renders.
        case saving(fraction: Double?, bytes: Int64?)
        /// The save failed: the sheet stays in crop mode and says `words`.
        case failed(words: String)

        var isSaving: Bool { if case .saving = self { return true } else { return false } }
        var failure: String? { if case .failed(let words) = self { return words } else { return nil } }
    }

    /// The photo's size in pixels, as the owner sees it.
    let source: CGSize
    private(set) var aspect: FrameSpec.Aspect
    private(set) var fill: FrameSpec.Fill
    /// The cut rectangle in source pixels (a blur ignores it).
    private(set) var rect: CGRect
    /// A finger is down on the rectangle: the rule-of-thirds grid shows.
    var isAdjusting = false
    /// Bumped when a shape snaps the rectangle: drives the haptic.
    private(set) var snaps = 0
    var phase: Phase = .editing

    /// The smallest the rectangle can be dragged to (so it cannot vanish); under `validSide` it is flagged.
    static let floorSide: CGFloat = 32
    /// A crop smaller than this is not worth keeping (the video crop's own rule).
    static let validSide: CGFloat = CGFloat(CropRect.minPixels)

    init(source: CGSize, spec: FrameSpec? = nil) {
        self.source = source
        let spec = spec ?? FrameSpec(aspect: .story, fill: .blur)
        aspect = spec.aspect
        fill = spec.effectiveFill
        rect = CGRect(origin: .zero, size: source)
        if let n = spec.rect, spec.effectiveFill == .cut {
            rect = CGRect(x: n.minX * source.width, y: n.minY * source.height, width: n.width * source.width, height: n.height * source.height)
        } else {
            rect = Self.largest(aspect: aspect, in: source)
        }
    }

    private static func largest(aspect: FrameSpec.Aspect, in source: CGSize) -> CGRect {
        FrameRenderer.cutRegion(source: source, spec: FrameSpec(aspect: aspect, fill: .cut))
    }

    var bounds: CGSize { source }

    /// What the frame is made of: the rectangle normalised for a cut, nothing for a blur.
    var spec: FrameSpec {
        guard fill == .cut || aspect == .free else { return FrameSpec(aspect: aspect, fill: .blur) }
        let n = CGRect(x: rect.minX / source.width, y: rect.minY / source.height, width: rect.width / source.width, height: rect.height / source.height)
        return FrameSpec(aspect: aspect, fill: .cut, rect: n)
    }

    /// The editor shows (and the fill control is live): a cut, or a free shape (which is always a cut).
    var cuts: Bool { aspect == .free || fill == .cut }

    /// Width over height the rectangle is locked to; nil when it is free.
    var lockedRatio: CGFloat? { aspect.ratio.map { CGFloat($0) } }

    /// The picture that would be made.
    var output: CGSize { FrameRenderer.outputSize(source: source, spec: spec) }

    /// The photo already has the frame's shape (a shape of its own needs neither a cut nor bars).
    var alreadyThatShape: Bool {
        guard let ratio = aspect.ratio, source.height > 0 else { return false }
        return abs(Double(source.width / source.height) - ratio) / ratio < 0.01
    }

    /// At least `validSide` each way: what `save crop` needs.
    var isValid: Bool {
        guard cuts else { return true }
        let region = FrameRenderer.cutRegion(source: source, spec: spec)
        return region.width >= Self.validSide && region.height >= Self.validSide
    }

    // MARK: changing it

    /// A shape: the largest rectangle of it, centred (`free` unlocks the rectangle where it is).
    func choose(_ new: FrameSpec.Aspect) {
        guard new != aspect else { return }
        aspect = new
        if new != .free { rect = Self.largest(aspect: new, in: source) }
        snaps += 1
    }

    func choose(fill new: FrameSpec.Fill) {
        guard new != fill else { return }
        fill = new
        snaps += 1
    }

    /// The whole photo again, in the shape that is chosen.
    func reset() {
        rect = aspect == .free ? CGRect(origin: .zero, size: source) : Self.largest(aspect: aspect, in: source)
        snaps += 1
    }

    /// One drag step: `part` of the rectangle as it was when the finger went down (`origin`), moved by `translation` (source
    /// pixels).
    func drag(_ part: CropGeometry.Part, from origin: CGRect, by translation: CGSize) {
        let ratio = lockedRatio
        switch part {
        case .move:
            rect = CropGeometry.move(origin, by: translation, in: bounds)
        case .corner(let corner):
            let p = CGPoint(
                x: (corner.isLeft ? origin.minX : origin.maxX) + translation.width,
                y: (corner.isTop ? origin.minY : origin.maxY) + translation.height)
            rect = CropGeometry.resize(corner: corner, of: origin, to: p, in: bounds, ratio: ratio, minSide: Self.floorSide)
        case .edge(let edge):
            let p: CGPoint
            switch edge {
            case .left: p = CGPoint(x: origin.minX + translation.width, y: origin.midY)
            case .right: p = CGPoint(x: origin.maxX + translation.width, y: origin.midY)
            case .top: p = CGPoint(x: origin.midX, y: origin.minY + translation.height)
            case .bottom: p = CGPoint(x: origin.midX, y: origin.maxY + translation.height)
            }
            rect = CropGeometry.resize(edge: edge, of: origin, to: p, in: bounds, ratio: ratio, minSide: Self.floorSide)
        }
    }

    /// A pinch: the rectangle as it was, scaled around its centre.
    func pinch(from origin: CGRect, by magnification: CGFloat) {
        rect = CropGeometry.scale(origin, by: magnification, in: bounds, minSide: Self.floorSide)
    }

    /// VoiceOver and keyboard nudges: a fraction of the photo.
    func nudge(dx: CGFloat, dy: CGFloat) {
        rect = CropGeometry.move(rect, by: CGSize(width: dx * source.width, height: dy * source.height), in: bounds)
    }

    func grow(_ factor: CGFloat) {
        rect = CropGeometry.scale(rect, by: factor, in: bounds, minSide: Self.floorSide)
    }
}
