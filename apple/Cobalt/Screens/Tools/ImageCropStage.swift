import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The crop sheet's picture (apple/CONTRACT-EDITOR.md 13): the picture as it will be turned and flipped, the box over it (drag
// inside to move, drag a corner or an edge to resize, the rule-of-thirds lines while it moves, everything outside dimmed, the
// size in pixels at its corner). On the Mac the arrow keys nudge it (shift: further) and a shift-drag keeps its shape.
// VoiceOver: the box (move and size actions) and its four handles (swipe up and down).

struct ImageCropStage: View {
    let model: ImageCropModel
    /// The picture as shown (already turned and flipped), any size with the shown picture's shape.
    let image: CGImage

    var body: some View {
        GeometryReader { geo in
            let fit = FrameCropStage.fit(model.display, in: geo.size)
            ZStack {
                Checkerboard()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                ImageCropBox(model: model, picture: fit)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .modifier(ImageCropKeys(model: model))
    }
}

// MARK: - the box

private struct ImageCropDim: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRect(hole)
        return p
    }
}

private struct ImageCropThirds: Shape {
    var frame: CGRect
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

/// Four corner brackets.
private struct ImageCropCorners: Shape {
    var frame: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = frame
        let arm = max(6, min(20, min(f.width, f.height) / 3))
        for corner in CropGeometry.Corner.allCases {
            let x = corner.isLeft ? f.minX : f.maxX
            let y = corner.isTop ? f.minY : f.maxY
            let dx: CGFloat = corner.isLeft ? arm : -arm
            let dy: CGFloat = corner.isTop ? arm : -arm
            p.move(to: CGPoint(x: x + dx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy))
        }
        return p
    }
}

/// The box over the picture; `picture` is the picture's rectangle in this view's space.
private struct ImageCropBox: View {
    let model: ImageCropModel
    let picture: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Grab {
        let part: CropGeometry.Part
        let origin: CGRect
    }

    @State private var grab: Grab?

    private var k: CGFloat { model.display.width > 0 ? picture.width / model.display.width : 1 }

    private func points(_ r: CGRect) -> CGRect {
        CGRect(x: picture.minX + r.minX * k, y: picture.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }

    var body: some View {
        let hole = points(model.rect)
        let ink: Color = model.output == nil ? CobaltColor.error : .white
        ZStack {
            ImageCropDim(hole: hole)
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .mask { Rectangle().frame(width: picture.width, height: picture.height).position(x: picture.midX, y: picture.midY) }
            ImageCropThirds(frame: hole)
                .stroke(.white.opacity(0.7), lineWidth: 1)
                .opacity(model.isAdjusting ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isAdjusting)
            Rectangle()
                .path(in: hole)
                .stroke(ink.opacity(0.95), lineWidth: 1.5)
            ImageCropCorners(frame: hole)
                .stroke(ink, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.5), radius: 2)
            sizeBadge(in: hole)
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .modifier(ImageCropBoxAccessibility(model: model))
        .overlay { ImageCropHandles(model: model, hole: hole) }
    }

    @ViewBuilder
    private func sizeBadge(in hole: CGRect) -> some View {
        let text = model.output.map { Copy.Editor.cropSize($0.width, $0.height) } ?? Copy.Editor.cropSize(0, 0)
        Text(text)
            .font(Font.cobalt(10, .medium, relativeTo: .caption2).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
            .position(x: max(hole.minX + 34, hole.maxX - 34), y: max(hole.minY + 12, hole.maxY - 14))
    }

    private var shiftHeld: Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.shift)
        #else
        return false
        #endif
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grab == nil {
                    guard let part = CropGeometry.hit(value.startLocation, in: points(model.rect)) else { return }
                    grab = Grab(part: part, origin: model.rect)
                    model.isAdjusting = true
                }
                guard let grab else { return }
                let scale = max(k, .leastNonzeroMagnitude)
                model.drag(
                    grab.part, from: grab.origin,
                    by: CGSize(width: value.translation.width / scale, height: value.translation.height / scale),
                    keepShape: shiftHeld)
            }
            .onEnded { _ in
                grab = nil
                model.isAdjusting = false
            }
    }
}

/// The box as one VoiceOver element: its size, and actions to move it and change its size.
private struct ImageCropBoxAccessibility: ViewModifier {
    let model: ImageCropModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Editor.cropBoxA11y)
            .accessibilityValue(model.output.map { Copy.Editor.cropSizeA11y($0.width, $0.height) } ?? Copy.Editor.cropError(.tooSmall))
            .accessibilityHint(Copy.Editor.cropBoxHint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.grow(1.1)
                case .decrement: model.grow(1 / 1.1)
                @unknown default: break
                }
            }
            .modifier(ImageCropMoveActions(model: model))
    }
}

private struct ImageCropMoveActions: ViewModifier {
    let model: ImageCropModel

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Copy.Editor.cropMoveLeft) { model.nudge(dx: -0.05, dy: 0) }
            .accessibilityAction(named: Copy.Editor.cropMoveRight) { model.nudge(dx: 0.05, dy: 0) }
            .accessibilityAction(named: Copy.Editor.cropMoveUp) { model.nudge(dx: 0, dy: -0.05) }
            .accessibilityAction(named: Copy.Editor.cropMoveDown) { model.nudge(dx: 0, dy: 0.05) }
            .accessibilityAction(named: Copy.Editor.cropBigger) { model.grow(1.1) }
            .accessibilityAction(named: Copy.Editor.cropSmaller) { model.grow(1 / 1.1) }
    }
}

/// The four handles as VoiceOver elements only (a finger reaches them through the box's own drag).
private struct ImageCropHandles: View {
    let model: ImageCropModel
    let hole: CGRect

    var body: some View {
        ZStack {
            ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                Color.clear
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .position(x: corner.isLeft ? hole.minX : hole.maxX, y: corner.isTop ? hole.minY : hole.maxY)
                    .accessibilityElement()
                    .accessibilityLabel(Copy.Editor.cropCorner(top: corner.isTop, left: corner.isLeft))
                    .accessibilityHint(Copy.Editor.cropCornerHint)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: model.pull(corner, by: 0.03)
                        case .decrement: model.pull(corner, by: -0.03)
                        @unknown default: break
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - keys (the Mac, a hardware keyboard on the iPad)

/// The arrow keys nudge the box a hundredth of the picture (a tenth with shift).
private struct ImageCropKeys: ViewModifier {
    let model: ImageCropModel
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let step: CGFloat = press.modifiers.contains(.shift) ? 0.1 : 0.01
                switch press.key {
                case .leftArrow: model.nudge(dx: -step, dy: 0)
                case .rightArrow: model.nudge(dx: step, dy: 0)
                case .upArrow: model.nudge(dx: 0, dy: -step)
                case .downArrow: model.nudge(dx: 0, dy: step)
                default: return .ignored
                }
                return .handled
            }
    }
}
