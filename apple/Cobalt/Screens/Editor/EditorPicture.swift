import CobaltKit
import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

// The touchable picture (apple/CONTRACT-EDITOR.md 15.3). The arithmetic (which clip a tap picks, the snaps, the corner
// resize, the knob's turn) is `EditPicturePick` in the Kit; this view maps points to canvas pixels and wires the gestures.
//
// One surface takes every touch and decides by where a drag starts (the knob, a corner, inside the box), so the handles,
// guides and readout are drawn with hit testing off and no two views compete for a touch:
// - a one-finger tap (SpatialTapGesture) picks, lets go, or plays and pauses;
// - a drag (DragGesture, 4 pt before it starts, so a tap stays a tap) turns from the knob, resizes from a corner or moves;
// - a pinch and a twist (MagnifyGesture with RotateGesture, alongside the drag) size and turn the selected clip anywhere on
//   the picture; while they run the drag lets go;
// - iOS: two- and three-finger taps (UIKit recognizers on the window, filtered to this picture, never cancelling a touch)
//   undo and redo. A tap that came with a second finger, or right after a drag or pinch moved something, is ignored.
// Every drag, pinch or twist that changes the frame is one undo step: `beginGesture` before its first edit, `endGesture`
// when the last finger lifts (or the gesture is cancelled).

/// The picture's touch layer: on top of the player, exactly the fitted canvas.
struct EditorShellCanvasLayer: View {
    let session: EditSession
    /// The canvas on screen, in points.
    let size: CGSize

    @Environment(EditorHost.self) private var host

    @State private var drag: PictureDrag?
    @State private var pinch: PicturePinch?
    /// `beginGesture` was called and `endGesture` is owed.
    @State private var gestureOpen = false
    /// The clip the last tap on the picture picked and where, for "tap the same spot again".
    @State private var lastPick: EditPicturePick.Previous?
    @State private var guides: EditPicturePick.Guides = []
    @State private var angleStop: Double?
    /// +1 on every snap or angle click (the selection haptic).
    @State private var tick = 0
    @State private var readoutShown = false
    /// When a drag or pinch last changed the frame.
    @State private var lastMotion = Date.distantPast
    /// When a second finger last came down on the picture (iOS).
    @State private var multiTouchAt = Date.distantPast
    @GestureState private var dragHeld = false
    @GestureState private var pinchHeld = false

    /// Touch targets (15.3: 44 pt), the knob's stick, and the snap and same-spot distances, in points.
    static let hit: CGFloat = 44
    static let stick: CGFloat = 18
    static let knob: CGFloat = 14
    static let dot: CGFloat = 12
    static let snap: CGFloat = 6
    static let samePlace: CGFloat = 12

    private var canvas: EditCanvas { session.timeline.canvas }
    /// Points per canvas pixel.
    private var scale: CGFloat { size.width / CGFloat(max(1, canvas.w)) }
    private var minWidth: Double { EditValidation.frameMinWidth * Double(canvas.w) }
    private var maxWidth: Double { EditValidation.frameMaxWidth * Double(canvas.w) }

    /// The selected clip, when the picture shows it at the playhead.
    private var selectedLayer: EditPicturePick.Layer? {
        guard session.tool != .crop, let id = session.pictureSelectionID else { return nil }
        return session.pictureLayers().first { $0.id == id }
    }

    var body: some View {
        let layer = selectedLayer
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(pinchGesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { tapped(at: $0.location) })
                .accessibilityHidden(true)
            guideLines
                .allowsHitTesting(false)
            if let layer {
                handles(layer)
                    .allowsHitTesting(false)
                accessibleBox(layer)
            }
            readout(layer)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        #if os(iOS)
        .background {
            EditorPictureTouches(
                onMultiTouch: { multiTouchAt = .now }, onUndo: { history(undo: true) }, onRedo: { history(undo: false) })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #endif
        .sensoryFeedback(.selection, trigger: tick)
        .onChange(of: session.selection) { _, _ in selectionChanged() }
        .onChange(of: dragHeld) { _, held in if !held { finishDrag() } }
        .onChange(of: pinchHeld) { _, held in if !held { finishPinch() } }
    }

    // MARK: - tap

    /// Picks the clip under the finger (the next one down on the same spot again), lets go on an empty spot, or plays and
    /// pauses when nothing is selected.
    private func tapped(at location: CGPoint) {
        let now = Date.now
        guard now.timeIntervalSince(lastMotion) > 0.3, now.timeIntervalSince(multiTouchAt) > 0.5 else { return }
        guard session.tool != .crop else { return }
        let point = canvasPoint(location)
        let layers = session.pictureLayers()
        let previous = lastPick.flatMap { $0.id == session.pictureSelectionID ? $0 : nil }
        if let id = EditPicturePick.pick(layers, at: point, previous: previous, samePlace: Double(Self.samePlace / scale)),
           let picked = layers.first(where: { $0.id == id }) {
            lastPick = EditPicturePick.Previous(id: id, point: point)
            session.selectFromPicture(picked)
            host.ui.pickedOnPicture = true
        } else if session.selection != .none {
            lastPick = nil
            session.selection = .none
            host.ui.pickedOnPicture = false
        } else {
            session.togglePlay()
        }
    }

    /// A selection made anywhere but here (the timeline, `done`, a delete) is not a pick on the picture.
    private func selectionChanged() {
        let id = session.pictureSelectionID
        if let open = drag?.id ?? pinch?.id, !open.isEmpty, open != id { finishAll() }
        guard lastPick?.id != id else { return }
        lastPick = nil
        if host.ui.pickedOnPicture { host.ui.pickedOnPicture = false }
    }

    // MARK: - drag: knob, corners, inside

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .updating($dragHeld) { _, held, _ in held = true }
            .onChanged { dragChanged($0) }
            .onEnded { _ in finishDrag() }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if drag == nil {
            drag = startDrag(at: value.startLocation)
            lastPick = nil
        }
        guard let d = drag else { return }
        switch d.mode {
        case .none:
            return
        case .move(let start):
            let moved = start.moved(dx: Double(value.translation.width / scale), dy: Double(value.translation.height / scale))
            let snapped = EditPicturePick.snapMove(moved, canvas: canvas, threshold: Double(Self.snap / scale))
            setGuides(snapped.guides)
            apply(snapped.box, id: d.id)
        case .resize(let corner, let start):
            let box = EditPicturePick.resize(
                start, corner: corner, to: canvasPoint(value.location), minWidth: minWidth, maxWidth: maxWidth)
            // the moving corner's box edges click to the canvas edges and centre lines, like a move
            let snapped = EditPicturePick.snapResize(
                box, corner: corner, canvas: canvas, threshold: Double(Self.snap / scale), minWidth: minWidth, maxWidth: maxWidth)
            setGuides(snapped.guides)
            apply(snapped.box, id: d.id)
        case .turn(let start, let from):
            let raw = EditPicturePick.turn(startR: start.r, center: start.center, from: from, to: canvasPoint(value.location))
            let snapped = EditPicturePick.snapAngle(raw)
            setStop(snapped.stop)
            var box = start
            box.r = snapped.r
            apply(box, id: d.id)
        }
    }

    /// What a drag starting at `location` does: the knob turns, a corner resizes, inside moves; elsewhere nothing. Inside a
    /// small box the corners reach less far, so it can still be moved.
    private func startDrag(at location: CGPoint) -> PictureDrag {
        guard pinch == nil, let layer = selectedLayer, !session.pictureLaneLocked(layer.lane) else {
            return PictureDrag(id: "", mode: .none)
        }
        let box = layer.box
        let point = canvasPoint(location)
        if distance(location, viewPoint(knobPlace(box).knob)) <= Self.hit / 2 {
            return PictureDrag(id: layer.id, mode: .turn(start: box, from: point))
        }
        let inside = box.contains(point)
        let side = CGFloat(min(box.width, box.height)) * scale
        let reach = inside ? min(Self.hit / 2, max(8, side * 0.3)) : Self.hit / 2
        let corners = box.corners.map(viewPoint).enumerated().map { ($0.offset, distance(location, $0.element)) }
        if let nearest = corners.min(by: { $0.1 < $1.1 }), nearest.1 <= reach {
            return PictureDrag(id: layer.id, mode: .resize(corner: nearest.0, start: box))
        }
        if inside || box.contains(point, slop: Double(8 / scale)) {
            return PictureDrag(id: layer.id, mode: .move(start: box))
        }
        return PictureDrag(id: layer.id, mode: .none)
    }

    private func finishDrag() {
        guard drag != nil else { return }
        drag = nil
        endIfIdle()
    }

    // MARK: - pinch and twist

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .simultaneously(with: RotateGesture(minimumAngleDelta: .degrees(1)))
            .updating($pinchHeld) { _, held, _ in held = true }
            .onChanged { value in
                pinchChanged(
                    magnification: Double(value.first?.magnification ?? 1), rotation: value.second?.rotation.degrees ?? 0)
            }
            .onEnded { _ in finishPinch() }
    }

    private func pinchChanged(magnification: Double, rotation: Double) {
        if pinch == nil {
            lastPick = nil
            if let layer = selectedLayer, !session.pictureLaneLocked(layer.lane) {
                pinch = PicturePinch(id: layer.id, start: layer.box)
            } else {
                pinch = PicturePinch(id: nil, start: nil)
            }
            // two fingers now: the one-finger drag lets go
            if let d = drag { drag = PictureDrag(id: d.id, mode: .none) }
            setGuides([])
        }
        guard let p = pinch, let id = p.id, let start = p.start else { return }
        var box = start.scaled(by: magnification, minWidth: minWidth, maxWidth: maxWidth)
        let snapped = EditPicturePick.snapAngle(start.r + rotation)
        setStop(snapped.stop)
        box.r = snapped.r
        apply(box, id: id)
    }

    private func finishPinch() {
        guard pinch != nil else { return }
        pinch = nil
        endIfIdle()
    }

    // MARK: - edits

    /// One frame edit of the gesture in flight. The first opens the undo step.
    private func apply(_ box: EditPictureBox, id: String) {
        if !gestureOpen {
            gestureOpen = true
            session.beginGesture()
        }
        lastMotion = .now
        readoutShown = true
        session.setClipFrame(id: id, box.frame(canvas: canvas))
    }

    /// The last finger is up: the undo step closes, the guides go and the readout fades.
    private func endIfIdle() {
        guard drag == nil, pinch == nil else { return }
        if gestureOpen {
            gestureOpen = false
            session.endGesture()
        }
        guides = []
        angleStop = nil
        withAnimation(.easeOut(duration: 0.35).delay(0.6)) { readoutShown = false }
    }

    private func finishAll() {
        drag = nil
        pinch = nil
        endIfIdle()
    }

    /// Two-finger tap undoes, three-finger tap redoes (iOS). Not while a pinch is still settling.
    private func history(undo: Bool) {
        guard Date.now.timeIntervalSince(lastMotion) > 0.3 else { return }
        finishAll()
        lastPick = nil
        if undo { session.undo() } else { session.redo() }
    }

    private func setGuides(_ next: EditPicturePick.Guides) {
        guard next != guides else { return }
        if !next.subtracting(guides).isEmpty { tick += 1 }
        guides = next
    }

    private func setStop(_ stop: Double?) {
        guard stop != angleStop else { return }
        if stop != nil { tick += 1 }
        angleStop = stop
    }

    // MARK: - geometry

    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
    private func canvasPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / scale, y: p.y / scale) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// The knob and the edge point its stick starts from, in canvas pixels: above the top edge; when that is off the
    /// picture (the picture is clipped), below the bottom edge; when that is too, just inside the top edge.
    private func knobPlace(_ box: EditPictureBox) -> (knob: CGPoint, edge: CGPoint) {
        let d = Double((Self.stick + Self.knob / 2) / scale)
        let h = box.height / 2
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: Self.knob, dy: Self.knob)
        let above = (box.point(local: 0, -h - d), box.point(local: 0, -h))
        if visible.contains(viewPoint(above.0)) { return above }
        let below = (box.point(local: 0, h + d), box.point(local: 0, h))
        if visible.contains(viewPoint(below.0)) { return below }
        if box.height > 3 * d { return (box.point(local: 0, -h + d), box.point(local: 0, -h)) }
        return above
    }

    // MARK: - drawing

    /// The box turned with the clip, the four corner dots and the knob on its stick. A locked lane: a dashed box only.
    @ViewBuilder
    private func handles(_ layer: EditPicturePick.Layer) -> some View {
        let corners = layer.box.corners.map(viewPoint)
        let locked = session.pictureLaneLocked(layer.lane)
        let knob = knobPlace(layer.box)
        let outline = Path { p in
            p.addLines(corners)
            p.closeSubpath()
        }
        ZStack(alignment: .topLeading) {
            outline.stroke(Color.black.opacity(0.35), lineWidth: 4)
            outline.stroke(EditorColor.selection, style: StrokeStyle(lineWidth: 2, dash: locked ? [6, 4] : []))
            if !locked {
                Path { p in
                    p.move(to: viewPoint(knob.edge))
                    p.addLine(to: viewPoint(knob.knob))
                }
                .stroke(EditorColor.selection, lineWidth: 2)
                dotView(size: Self.knob)
                    .position(viewPoint(knob.knob))
                ForEach(corners.indices, id: \.self) { i in
                    dotView(size: Self.dot)
                        .position(corners[i])
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func dotView(size: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay { Circle().strokeBorder(EditorColor.selection, lineWidth: 2) }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    /// The canvas edges and centre lines the moving box sits on.
    private var guideLines: some View {
        let w = size.width, h = size.height
        let lines = guides
        return Path { p in
            func vertical(_ x: CGFloat) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
            func horizontal(_ y: CGFloat) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
            if lines.contains(.left) { vertical(1) }
            if lines.contains(.centerX) { vertical(w / 2) }
            if lines.contains(.right) { vertical(w - 1) }
            if lines.contains(.top) { horizontal(1) }
            if lines.contains(.centerY) { horizontal(h / 2) }
            if lines.contains(.bottom) { horizontal(h - 1) }
        }
        .stroke(EditorColor.overlay, lineWidth: 1.5)
        .frame(width: w, height: h)
    }

    /// `12° · 48%` at the top of the picture while a drag, pinch or twist runs; it fades after.
    @ViewBuilder
    private func readout(_ layer: EditPicturePick.Layer?) -> some View {
        if let layer, let frame = session.frameBox(ofClip: layer.id) {
            Text(verbatim: "\(Int(frame.r.rounded()))° · \(Int((frame.w * 100).rounded()))%")
                .font(CobaltType.captionSmall)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.62), in: Capsule())
                .padding(.top, 8)
                .frame(width: size.width, alignment: .top)
                .opacity(readoutShown ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    /// VoiceOver: the selected clip's size as an adjustable value and four moves of 5 % (as the overlay handles had).
    private func accessibleBox(_ layer: EditPicturePick.Layer) -> some View {
        let bounds = layer.box.bounds
        let box = layer.box
        let step = 0.05 * Double(canvas.w)
        return Color.clear
            .frame(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            .position(viewPoint(box.center))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Copy.Editor.overlaySize)
            .accessibilityValue("\(Int((box.width / Double(max(1, canvas.w)) * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(layer) { $0.scaled(by: ($0.width + step) / max(1, $0.width), minWidth: minWidth, maxWidth: maxWidth) }
                case .decrement: nudge(layer) { $0.scaled(by: ($0.width - step) / max(1, $0.width), minWidth: minWidth, maxWidth: maxWidth) }
                @unknown default: break
                }
            }
            .accessibilityAction(named: Copy.Editor.moveLeft) { nudge(layer) { $0.moved(dx: -step, dy: 0) } }
            .accessibilityAction(named: Copy.Editor.moveRight) { nudge(layer) { $0.moved(dx: step, dy: 0) } }
            .accessibilityAction(named: Copy.Editor.moveUp) { nudge(layer) { $0.moved(dx: 0, dy: -0.05 * Double(canvas.h)) } }
            .accessibilityAction(named: Copy.Editor.moveDown) { nudge(layer) { $0.moved(dx: 0, dy: 0.05 * Double(canvas.h)) } }
    }

    /// One VoiceOver step: its own undo step.
    private func nudge(_ layer: EditPicturePick.Layer, _ change: (EditPictureBox) -> EditPictureBox) {
        guard !session.pictureLaneLocked(layer.lane) else { return }
        session.beginGesture()
        session.setClipFrame(id: layer.id, change(layer.box).frame(canvas: canvas))
        session.endGesture()
    }
}

private struct PictureDrag {
    enum Mode {
        case none
        case move(start: EditPictureBox)
        case resize(corner: Int, start: EditPictureBox)
        /// `from`: where the finger took the knob, canvas pixels.
        case turn(start: EditPictureBox, from: CGPoint)
    }

    var id: String
    var mode: Mode
}

private struct PicturePinch {
    /// Nil: nothing to size (no selection on the picture, or its lane is locked).
    var id: String?
    var start: EditPictureBox?
}

// MARK: - iOS: two- and three-finger taps

#if os(iOS)
/// SwiftUI has no multi-finger tap. Two `UITapGestureRecognizer`s (2 and 3 touches) on the window, receiving only touches
/// that land on this picture (not on a sheet over it), recognising alongside everything and cancelling nothing, so the
/// SwiftUI tap, drag and pinch on the picture still get every touch. A third, passive recognizer reports a second finger
/// coming down, so the one-finger tap of a two-finger tap is ignored.
private struct EditorPictureTouches: UIViewRepresentable {
    let onMultiTouch: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeUIView(context: Context) -> EditorPictureTouchView { EditorPictureTouchView() }

    func updateUIView(_ view: EditorPictureTouchView, context: Context) {
        view.onMultiTouch = onMultiTouch
        view.onUndo = onUndo
        view.onRedo = onRedo
    }

    static func dismantleUIView(_ view: EditorPictureTouchView, coordinator: ()) { view.detach() }
}

private final class EditorPictureTouchView: UIView, UIGestureRecognizerDelegate {
    var onMultiTouch: () -> Void = {}
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}

    private let two = UITapGestureRecognizer()
    private let three = UITapGestureRecognizer()
    private let counter = EditorTouchCounter()
    private var recognizers: [UIGestureRecognizer] { [two, three, counter] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        two.numberOfTouchesRequired = 2
        three.numberOfTouchesRequired = 3
        two.require(toFail: three)
        two.addTarget(self, action: #selector(twoFingerTap))
        three.addTarget(self, action: #selector(threeFingerTap))
        counter.onMultiTouch = { [weak self] in self?.onMultiTouch() }
        for r in recognizers {
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        for r in recognizers { window.addGestureRecognizer(r) }
    }

    func detach() {
        for r in recognizers { r.view?.removeGestureRecognizer(r) }
    }

    @objc private func twoFingerTap() { onUndo() }
    @objc private func threeFingerTap() { onRedo() }

    /// The SwiftUI hosting view this picture is drawn in. A touch on another one (a sheet over the editor) is not ours.
    /// (The hosting view's next responder is SwiftUI's key-press responder, not its controller, so this goes by the view.)
    private var hostingAncestor: UIView? {
        var view = superview
        while let current = view {
            if String(describing: type(of: current)).contains("HostingView") { return current }
            view = current.superview
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard window != nil, !isHidden, bounds.contains(touch.location(in: self)), let hit = touch.view else { return false }
        guard let host = hostingAncestor else { return isDescendant(of: hit) }
        return hit === host || hit.isDescendant(of: host)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// Never recognises: reports when a second finger is down on the picture, then fails once every finger is up.
private final class EditorTouchCounter: UIGestureRecognizer {
    var onMultiTouch: () -> Void = {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if numberOfTouches >= 2 { onMultiTouch() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        failWhenAllUp(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        failWhenAllUp(event)
    }

    private func failWhenAllUp(_ event: UIEvent) {
        let down = event.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
        if !down { state = .failed }
    }
}
#endif
