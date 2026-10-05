import CobaltKit
import CoreGraphics
import SwiftUI

// The crop editor (CONTRACT-ORBIT 2d): a rectangle laid over the playing preview. Corner and edge
// handles resize it, a drag inside moves it, a pinch scales it, a rule-of-thirds grid shows while it is
// being adjusted, and everything outside it is dimmed. It lives inside the hero planet (the planet's
// own picture, which is the preview: one player, never a second one) and edits a draft that "done"
// hands to the pipeline.
//
// All of the maths is in SOURCE PIXELS of the display frame (after rotation metadata), where the
// server's rules live (even sizes, at least 64 px). The view maps points to pixels by the size of the
// picture it sits on.

// MARK: - geometry (pure)

enum CropGeometry {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    enum Edge: CaseIterable { case left, right, top, bottom }

    enum Part: Equatable {
        case corner(Corner), edge(Edge), move
    }

    /// A touch target reaches this far from a handle: 44 pt across.
    static let reach: CGFloat = 22

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

    // MARK: hit test

    /// What a touch at `p` grabs on a rectangle `r` (both in points): the nearest corner within `reach`,
    /// else the nearest edge within `reach`, else the inside (move). On a small rectangle the reach
    /// shrinks to a third of its shorter side, so the middle is always left for moving it.
    static func hit(_ p: CGPoint, in r: CGRect, reach: CGFloat = reach) -> Part? {
        let c = max(1, min(reach, min(r.width, r.height) / 3))
        var best: (part: Part, distance: CGFloat)?
        func consider(_ part: Part, _ distance: CGFloat) {
            if best == nil || distance < best!.distance { best = (part, distance) }
        }
        for corner in Corner.allCases {
            let x = corner.isLeft ? r.minX : r.maxX
            let y = corner.isTop ? r.minY : r.maxY
            if abs(p.x - x) <= c, abs(p.y - y) <= c { consider(.corner(corner), hypot(p.x - x, p.y - y)) }
        }
        if let best { return best.part }
        let spanX = p.x >= r.minX - c && p.x <= r.maxX + c
        let spanY = p.y >= r.minY - c && p.y <= r.maxY + c
        if spanY, abs(p.x - r.minX) <= c { consider(.edge(.left), abs(p.x - r.minX)) }
        if spanY, abs(p.x - r.maxX) <= c { consider(.edge(.right), abs(p.x - r.maxX)) }
        if spanX, abs(p.y - r.minY) <= c { consider(.edge(.top), abs(p.y - r.minY)) }
        if spanX, abs(p.y - r.maxY) <= c { consider(.edge(.bottom), abs(p.y - r.maxY)) }
        if let best { return best.part }
        return r.contains(p) ? .move : nil
    }

    // MARK: moving and scaling

    static func move(_ r: CGRect, by d: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(
            x: clamp(r.minX + d.width, 0, bounds.width - r.width),
            y: clamp(r.minY + d.height, 0, bounds.height - r.height),
            width: r.width, height: r.height)
    }

    /// `r` scaled by `factor` around its centre, kept inside `bounds` and at least `minSide` each way.
    static func scale(_ r: CGRect, by factor: CGFloat, in bounds: CGSize, minSide: CGFloat) -> CGRect {
        guard r.width > 0, r.height > 0, factor.isFinite, factor > 0 else { return r }
        let maxF = min(bounds.width / r.width, bounds.height / r.height)
        let minF = max(minSide / r.width, minSide / r.height)
        let f = min(max(factor, minF), maxF)
        let w = r.width * f, h = r.height * f
        return CGRect(
            x: clamp(r.midX - w / 2, 0, bounds.width - w),
            y: clamp(r.midY - h / 2, 0, bounds.height - h),
            width: w, height: h)
    }

    // MARK: resizing

    /// Drag `corner` of `r` to `p` (pixels). The opposite corner stays put. With a `ratio` (width over
    /// height) the shape is locked and follows the longer of the two movements.
    static func resize(corner: Corner, of r: CGRect, to p: CGPoint, in bounds: CGSize, ratio: CGFloat?, minSide: CGFloat) -> CGRect {
        let sx: CGFloat = corner.isLeft ? -1 : 1
        let sy: CGFloat = corner.isTop ? -1 : 1
        let anchor = CGPoint(x: corner.isLeft ? r.maxX : r.minX, y: corner.isTop ? r.maxY : r.minY)
        let roomX = sx > 0 ? bounds.width - anchor.x : anchor.x
        let roomY = sy > 0 ? bounds.height - anchor.y : anchor.y
        var w = max(0, (p.x - anchor.x) * sx)
        var h = max(0, (p.y - anchor.y) * sy)
        if let ratio, ratio > 0 {
            let minW = max(minSide, minSide * ratio)
            let maxW = min(roomX, roomY * ratio)
            w = min(max(max(w, h * ratio), minW), maxW)
            h = w / ratio
        } else {
            w = min(max(w, min(minSide, roomX)), roomX)
            h = min(max(h, min(minSide, roomY)), roomY)
        }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// Drag `edge` of `r` to `p` (pixels). The opposite edge stays put; with a `ratio` the other
    /// dimension follows around the rectangle's centre.
    static func resize(edge: Edge, of r: CGRect, to p: CGPoint, in bounds: CGSize, ratio: CGFloat?, minSide: CGFloat) -> CGRect {
        switch edge {
        case .left, .right:
            let room = edge == .right ? bounds.width - r.minX : r.maxX
            var w = edge == .right ? p.x - r.minX : r.maxX - p.x
            let x: (CGFloat) -> CGFloat = { w in edge == .right ? r.minX : r.maxX - w }
            if let ratio, ratio > 0 {
                w = min(max(w, max(minSide, minSide * ratio)), min(room, bounds.height * ratio))
                let h = w / ratio
                return CGRect(x: x(w), y: clamp(r.midY - h / 2, 0, bounds.height - h), width: w, height: h)
            }
            w = min(max(w, min(minSide, room)), room)
            return CGRect(x: x(w), y: r.minY, width: w, height: r.height)
        case .top, .bottom:
            let room = edge == .bottom ? bounds.height - r.minY : r.maxY
            var h = edge == .bottom ? p.y - r.minY : r.maxY - p.y
            let y: (CGFloat) -> CGFloat = { h in edge == .bottom ? r.minY : r.maxY - h }
            if let ratio, ratio > 0 {
                h = min(max(h, max(minSide, minSide / ratio)), min(room, bounds.width / ratio))
                let w = h * ratio
                return CGRect(x: clamp(r.midX - w / 2, 0, bounds.width - w), y: y(h), width: w, height: h)
            }
            h = min(max(h, min(minSide, room)), room)
            return CGRect(x: r.minX, y: y(h), width: r.width, height: h)
        }
    }
}

// MARK: - the draft

/// The crop being edited: a rectangle in source pixels, the shape it is locked to, and what the webp
/// would be. "done" hands `committed` to the pipeline; nothing here touches it before then.
@MainActor @Observable
final class CropEditorModel {
    /// The source's size in pixels, display orientation.
    let source: CGSize
    /// The webp width setting: the output is at most this wide.
    let outputWidth: Int
    private(set) var rect: CGRect
    private(set) var aspect: CropRect.Aspect
    /// A finger is down on the rectangle: the rule-of-thirds grid shows.
    var isAdjusting = false
    /// Bumped when a preset (or reset) snaps the rectangle: drives the haptic.
    private(set) var snaps = 0

    /// The smallest the rectangle can be dragged to (so it cannot vanish); under `validSide` it is flagged.
    static let floorSide: CGFloat = 32
    /// What the server accepts (`CropRect.minPixels`).
    static let validSide: CGFloat = CGFloat(CropRect.minPixels)

    init(source: CGSize, outputWidth: Int, crop: CropRect?) {
        self.source = source
        self.outputWidth = outputWidth
        if let crop, !crop.isFull {
            rect = CGRect(x: crop.x * source.width, y: crop.y * source.height, width: crop.w * source.width, height: crop.h * source.height)
            aspect = crop.matchedAspect(in: source).flatMap { $0 == .original ? nil : $0 } ?? .free
        } else {
            rect = CGRect(origin: .zero, size: source)
            aspect = .original
        }
    }

    var bounds: CGSize { source }

    /// Width over height the rectangle is locked to; nil when it is free.
    var lockedRatio: CGFloat? {
        switch aspect {
        case .free: return nil
        case .original: return source.height > 0 ? source.width / source.height : nil
        default: return aspect.ratio.map { CGFloat($0) }
        }
    }

    // MARK: pixels

    private static func evenNearest(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }

    /// The rectangle as whole even pixels, the way the server will read it (nearest even; a locked shape
    /// keeps its ratio: the height follows the snapped width).
    var snapped: CGRect {
        let maxW = (source.width / 2).rounded(.down) * 2, maxH = (source.height / 2).rounded(.down) * 2
        var w = min(Self.evenNearest(rect.width), maxW)
        var h = min(Self.evenNearest(rect.height), maxH)
        if let ratio = lockedRatio, ratio > 0 {
            h = Self.evenNearest(w / ratio)
            if h > maxH { h = maxH; w = min(maxW, Self.evenNearest(h * ratio)) }
        }
        let x = min(max(0, Self.evenNearest(rect.minX)), max(0, ((source.width - w) / 2).rounded(.down) * 2))
        let y = min(max(0, Self.evenNearest(rect.minY)), max(0, ((source.height - h) / 2).rounded(.down) * 2))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The crop in whole source pixels.
    var pixelSize: CGSize { snapped.size }

    /// At least 64 px each way: what `done` needs.
    var isValid: Bool { pixelSize.width >= Self.validSide && pixelSize.height >= Self.validSide }

    /// The webp's size: at most `outputWidth` wide, the crop's aspect, even numbers.
    var output: CGSize {
        let s = pixelSize
        guard s.width > 0 else { return .zero }
        let w = min(CGFloat(max(2, outputWidth)), s.width)
        return CGSize(width: w, height: max(2, Self.evenNearest(s.height * w / s.width)))
    }

    /// What `done` gives the pipeline: nil for the whole frame (no crop).
    var committed: CropRect? {
        let r = snapped
        guard source.width > 0, source.height > 0 else { return nil }
        let crop = CropRect(x: r.minX / source.width, y: r.minY / source.height, w: r.width / source.width, h: r.height / source.height)
        return crop.isFull ? nil : crop
    }

    var isWholeFrame: Bool { committed == nil }

    // MARK: changing it

    /// A preset: the largest of that shape, centred; `free` unlocks the rectangle where it is.
    func choose(_ new: CropRect.Aspect) {
        aspect = new
        switch new {
        case .free:
            break
        case .original:
            rect = CGRect(origin: .zero, size: source)
        default:
            let c = CropRect.centered(new, in: source)
            rect = CGRect(x: c.x * source.width, y: c.y * source.height, width: c.w * source.width, height: c.h * source.height)
        }
        snaps += 1
    }

    /// The whole frame again, unlocked from any preset but the clip's own shape.
    func reset() {
        aspect = .original
        rect = CGRect(origin: .zero, size: source)
        snaps += 1
    }

    /// One drag step: `part` of the rectangle as it was when the finger went down (`origin`), moved by
    /// `translation` (source pixels).
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

    /// VoiceOver and keyboard nudges: a fraction of the frame.
    func nudge(dx: CGFloat, dy: CGFloat) {
        rect = CropGeometry.move(rect, by: CGSize(width: dx * source.width, height: dy * source.height), in: bounds)
    }

    func grow(_ factor: CGFloat) {
        rect = CropGeometry.scale(rect, by: factor, in: bounds, minSide: Self.floorSide)
    }
}

// MARK: - drawing

/// The dimmed picture outside the rectangle: the whole frame minus a hole that follows the rectangle.
private struct CropDim: Shape {
    var hole: CGRect
    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRect(hole)
        return p
    }
}

private struct CropOutline: Shape {
    var frame: CGRect
    var animatableData: CGRect.AnimatableData {
        get { frame.animatableData }
        set { frame.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path { Path(frame) }
}

/// Two vertical and two horizontal lines at thirds.
private struct CropThirds: Shape {
    var frame: CGRect
    var animatableData: CGRect.AnimatableData {
        get { frame.animatableData }
        set { frame.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = frame.minX + frame.width * CGFloat(i) / 3
            let y = frame.minY + frame.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
            p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        return p
    }
}

/// Four corner brackets and, when an edge is long enough, a short bar at its middle.
private struct CropHandles: Shape {
    var frame: CGRect
    var animatableData: CGRect.AnimatableData {
        get { frame.animatableData }
        set { frame.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = frame
        let arm = max(6, min(22, min(f.width, f.height) / 3))
        for corner in CropGeometry.Corner.allCases {
            let x = corner.isLeft ? f.minX : f.maxX
            let y = corner.isTop ? f.minY : f.maxY
            let dx: CGFloat = corner.isLeft ? arm : -arm
            let dy: CGFloat = corner.isTop ? arm : -arm
            p.move(to: CGPoint(x: x + dx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy))
        }
        let bar = min(22, min(f.width, f.height) / 6)
        if f.width >= 120 {
            for y in [f.minY, f.maxY] {
                p.move(to: CGPoint(x: f.midX - bar, y: y)); p.addLine(to: CGPoint(x: f.midX + bar, y: y))
            }
        }
        if f.height >= 120 {
            for x in [f.minX, f.maxX] {
                p.move(to: CGPoint(x: x, y: f.midY - bar)); p.addLine(to: CGPoint(x: x, y: f.midY + bar))
            }
        }
        return p
    }
}

// MARK: - the view

/// The editor over the picture. `picture` is the picture's rectangle in this view's own space (the
/// planet's inner frame; the picture may overhang it by a few points). It fills the planet and takes
/// every touch on it.
struct CropEditorView: View {
    let model: CropEditorModel
    let picture: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Grab {
        let part: CropGeometry.Part
        let origin: CGRect
    }

    @State private var grab: Grab?
    @State private var pinchOrigin: CGRect?
    /// A pinch ended while a finger was still down: that finger's drag is over (its origin is stale).
    @State private var dragSpent = false

    private var kx: CGFloat { model.source.width > 0 ? picture.width / model.source.width : 1 }
    private var ky: CGFloat { model.source.height > 0 ? picture.height / model.source.height : 1 }

    private func points(_ r: CGRect) -> CGRect {
        CGRect(x: picture.minX + r.minX * kx, y: picture.minY + r.minY * ky, width: r.width * kx, height: r.height * ky)
    }

    var body: some View {
        let hole = points(model.rect)
        let valid = model.isValid
        let ink: Color = valid ? .white : CobaltColor.error
        GeometryReader { geo in
            // the lines are drawn inside the planet's frame even when the crop reaches the picture's edge
            let drawn = hole.intersection(CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2))
            ZStack {
                CropDim(hole: hole)
                    .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
                CropThirds(frame: drawn)
                    .stroke(.white.opacity(0.7), lineWidth: 1)
                    .opacity(model.isAdjusting ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isAdjusting)
                CropOutline(frame: drawn)
                    .stroke(ink.opacity(0.95), lineWidth: 1.5)
                CropHandles(frame: drawn)
                    .stroke(ink, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .simultaneousGesture(pinch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CropCopy.editorA11y)
        .accessibilityValue(valid ? CropCopy.readoutA11y(model.output) : CropCopy.tooSmallA11y)
        .accessibilityHint(CropCopy.editorHint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.grow(1.1)
            case .decrement: model.grow(1 / 1.1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: CropCopy.moveLeft) { model.nudge(dx: -0.05, dy: 0) }
        .accessibilityAction(named: CropCopy.moveRight) { model.nudge(dx: 0.05, dy: 0) }
        .accessibilityAction(named: CropCopy.moveUp) { model.nudge(dx: 0, dy: -0.05) }
        .accessibilityAction(named: CropCopy.moveDown) { model.nudge(dx: 0, dy: 0.05) }
        .accessibilityAction(named: CropCopy.bigger) { model.grow(1.1) }
        .accessibilityAction(named: CropCopy.smaller) { model.grow(1 / 1.1) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pinchOrigin == nil, !dragSpent else { return }
                if grab == nil {
                    guard let part = CropGeometry.hit(value.startLocation, in: points(model.rect)) else { return }
                    grab = Grab(part: part, origin: model.rect)
                    model.isAdjusting = true
                }
                guard let grab else { return }
                model.drag(grab.part, from: grab.origin, by: CGSize(
                    width: value.translation.width / max(kx, .leastNonzeroMagnitude),
                    height: value.translation.height / max(ky, .leastNonzeroMagnitude)))
            }
            .onEnded { _ in
                grab = nil
                dragSpent = false
                model.isAdjusting = pinchOrigin != nil
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchOrigin == nil {
                    pinchOrigin = model.rect
                    model.isAdjusting = true
                }
                if let origin = pinchOrigin { model.pinch(from: origin, by: value.magnification) }
            }
            .onEnded { _ in
                pinchOrigin = nil
                dragSpent = grab != nil
                grab = nil
                model.isAdjusting = false
            }
    }
}
