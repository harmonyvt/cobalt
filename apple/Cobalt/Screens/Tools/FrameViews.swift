import CobaltKit
import SwiftUI

// What the repost tools draw: the frame as a preview (the whole photo on blurred bars, or the part a cut keeps) and the
// crop's editor (the video crop's gestures over the photo: corner and edge handles, a drag inside moves it, a pinch scales
// it, a rule-of-thirds grid while a finger is down, everything outside dimmed). The real picture is made by `FrameRenderer`
// from the file; these are the same plan drawn with SwiftUI at the size of the screen.

// MARK: - a frame, previewed

/// The picture a frame makes, drawn small: `blur` is the whole photo, centred, on a blurred and darkened copy of itself (the
/// slideshow's fill); `cut` is the photo filling the frame from its middle (a crop's own rectangle is `FrameCropStage`).
struct FramePreview: View {
    let image: CGImage
    let aspect: FrameSpec.Aspect
    let fill: FrameSpec.Fill

    var body: some View {
        let ratio = CGFloat(aspect.ratio ?? Double(image.width) / Double(max(1, image.height)))
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        if fill == .blur, aspect != .free {
                            // the background is the photo covering the frame; scaled a little past it so the blur never shows
                            // transparent edges; the radius is 24 at 1080 px, as `FrameRenderer`'s
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .scaleEffect(1.12)
                                .blur(radius: 24 * min(geo.size.width, geo.size.height) / 1080)
                                .brightness(-0.08)
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CobaltColor.hairline.opacity(2), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - the crop's stage

/// The photo at its own shape with the crop's rectangle over it (a cut or a free shape), or the frame as it will be made (a
/// blur). Fits the room it is given.
struct FrameCropStage: View {
    let model: FrameCropModel
    let image: CGImage

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fit(CGSize(width: image.width, height: image.height), in: geo.size)
            ZStack {
                if model.cuts {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    FrameCropEditor(model: model, picture: fit)
                } else {
                    FramePreview(image: image, aspect: model.aspect, fill: .blur)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The photo, as large as fits, centred in `box`.
    static func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = min(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

// MARK: - the editor

/// The dimmed picture outside the rectangle: the whole frame minus a hole that follows the rectangle.
private struct FrameDim: Shape {
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

private struct FrameOutline: Shape {
    var frame: CGRect
    var animatableData: CGRect.AnimatableData {
        get { frame.animatableData }
        set { frame.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path { Path(frame) }
}

/// Two vertical and two horizontal lines at thirds.
private struct FrameThirds: Shape {
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
private struct FrameHandles: Shape {
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

/// The crop's rectangle over the photo, with the video crop's gestures (`CropEditorView`): `picture` is the photo's rectangle
/// in this view's own space. The rectangle is locked to the frame's shape unless it is `free`.
struct FrameCropEditor: View {
    let model: FrameCropModel
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
            // the lines are drawn inside the view even when the frame reaches the photo's edge
            let drawn = hole.intersection(CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2))
            ZStack {
                FrameDim(hole: hole)
                    .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
                    .mask { Rectangle().frame(width: picture.width, height: picture.height).position(x: picture.midX, y: picture.midY) }
                FrameThirds(frame: drawn)
                    .stroke(.white.opacity(0.7), lineWidth: 1)
                    .opacity(model.isAdjusting ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isAdjusting)
                FrameOutline(frame: drawn)
                    .stroke(ink.opacity(0.95), lineWidth: 1.5)
                FrameHandles(frame: drawn)
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
        .accessibilityValue(valid ? ToolsCopy.sizeA11y(model.output) : CropCopy.tooSmallA11y)
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
                guard pinchOrigin == nil, !dragSpent, !model.phase.isSaving else { return }
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
                guard !model.phase.isSaving else { return }
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
