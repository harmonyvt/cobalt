#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone timeline (apple/CONTRACT-EDITOR.md 4.4): 150 pt tall, a fixed white playhead at the centre and the tracks
/// sliding under it. Dragging scrubs (a light tick on every clip edge, a little momentum on release); a pinch zooms; a tap
/// selects a clip and a tap on nothing deselects; a long press lifts a clip to reorder it. The overlay lane sits above the main
/// lane; `+` at the right adds a clip.
///
/// Nothing here scrolls: every block is placed at `centre + scale.x(its time - the playhead's time)`, so playing, scrubbing and
/// seeking all move the same way and only the blocks on screen are built.
struct EditorPhoneTimeline: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    let openAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("editor.pinchHintSeen") private var pinchSeen = false
    @State private var scrubBase: Double?
    @State private var inertia: Task<Void, Never>?
    @State private var pinchBase: CGFloat?
    @State private var reorder: ReorderDrag?
    @State private var edgeTick = 0
    @State private var lastClipID: String?

    static let height: CGFloat = 150
    static let overlayY: CGFloat = 16
    static let overlayHeight: CGFloat = 28
    static let mainY: CGFloat = 54
    static let mainHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            lanes(width: geo.size.width)
        }
        .frame(height: Self.height)
        .background(EditorColor.lane)
        .overlay(alignment: .top) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .clipped()
        .modifier(EditorPhoneTimelineHaptics(edgeTick: edgeTick))
        .onDisappear { inertia?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.timelineA11y)
    }

    private func lanes(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.selection = .none }
                .accessibilityHidden(true)
            overlayLane(width: width)
            mainLane(width: width)
            playhead(width: width)
            addButton(width: width)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrub)
        .simultaneousGesture(pinch)
        .motion(Motion.rows, value: reorder?.target)
    }

    // MARK: where things sit

    /// The screen x of a time on the timeline.
    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        width / 2 + scale.x(seconds - session.playheadSeconds)
    }

    private func onScreen(start: CGFloat, length: CGFloat, width: CGFloat) -> Bool {
        start + length > -48 && start < width + 48
    }

    // MARK: lanes

    private func mainLane(width: CGFloat) -> some View {
        let spans = session.mainSpans
        let rest = restStarts(spans)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(session.timeline.main.enumerated()), id: \.element.id) { index, clip in
                if spans.indices.contains(index) {
                    mainBlock(index: index, clip: clip, span: spans[index], rest: rest, width: width)
                }
            }
        }
    }

    @ViewBuilder
    private func mainBlock(index: Int, clip: EditClip, span: TimelineSpan, rest: [String: Double], width: CGFloat) -> some View {
        let restX = x(rest[span.id] ?? span.start, width: width)
        let homeX = x(span.start, width: width)
        let blockWidth = max(2, scale.x(span.length) - 2)
        if reorder?.id == clip.id || onScreen(start: min(restX, homeX), length: blockWidth, width: width) {
            EditorPhoneMainClip(
                session: session, index: index, clip: clip, span: span, scale: scale, restX: restX, homeX: homeX,
                reorder: $reorder)
        }
    }

    /// Where each main clip starts (seconds) when the one being dragged is taken out and put in at its target.
    private func restStarts(_ spans: [TimelineSpan]) -> [String: Double] {
        var starts: [String: Double] = [:]
        guard let drag = reorder, let dragged = spans.first(where: { $0.id == drag.id }) else {
            for span in spans { starts[span.id] = span.start }
            return starts
        }
        var order = spans.filter { $0.id != drag.id }
        order.insert(dragged, at: min(max(0, drag.target), order.count))
        var cursor = 0.0
        for span in order {
            starts[span.id] = cursor
            cursor += span.length
        }
        return starts
    }

    private func overlayLane(width: CGFloat) -> some View {
        let spans = session.overlaySpans
        return ZStack(alignment: .topLeading) {
            if session.timeline.overlay.isEmpty {
                Text(Copy.Editor.trackOverlay)
                    .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.leading, 14)
                    .padding(.top, Self.overlayY + 7)
                    .accessibilityHidden(true)
            }
            ForEach(Array(session.timeline.overlay.enumerated()), id: \.element.id) { index, overlay in
                if spans.indices.contains(index) {
                    overlayBlock(index: index, overlay: overlay, span: spans[index], width: width)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayBlock(index: Int, overlay: EditOverlay, span: TimelineSpan, width: CGFloat) -> some View {
        let startX = x(span.start, width: width)
        if onScreen(start: startX, length: max(2, scale.x(span.length)), width: width) {
            EditorPhoneOverlayClip(
                session: session, index: index, overlay: overlay, span: span, scale: scale, originX: startX)
        }
    }

    // MARK: playhead and +

    private func playhead(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimelinePlayhead(height: Self.height, color: .white, showsHead: false)
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .offset(x: width / 2 - TimelinePlayhead.headWidth / 2)
            playheadAccessibility
                .offset(x: width / 2 - Metrics.hit / 2)
        }
    }

    /// An invisible 44 pt element on the playhead: adjustable by one second, with actions for one frame.
    private var playheadAccessibility: some View {
        Color.clear
            .frame(width: Metrics.hit, height: Self.height)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Editor.a11yPlayhead)
            .accessibilityValue(Copy.Editor.a11yPlayheadValue(
                Copy.Editor.clockTenths(session.playheadSeconds), of: Copy.Editor.clockTenths(session.timing.seconds)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: session.step(frames: session.timing.fps)
                case .decrement: session.step(frames: -session.timing.fps)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Copy.Editor.backOneFrame) { session.step(frames: -1) }
            .accessibilityAction(named: Copy.Editor.forwardOneFrame) { session.step(frames: 1) }
    }

    private func addButton(width: CGFloat) -> some View {
        Button(action: openAdd) {
            Image(systemName: Symbol.Editor.add)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CobaltColor.onText)
                .frame(width: 36, height: 36)
                .background(CobaltColor.text, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Editor.addClip)
        .offset(x: width - Metrics.hit - 6, y: Self.mainY + (Self.mainHeight - Metrics.hit) / 2)
    }

    // MARK: scrubbing and momentum

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard reorder == nil else { return }
                if scrubBase == nil {
                    scrubBase = session.playheadSeconds
                    lastClipID = session.clipUnderPlayhead?.clip.id
                    inertia?.cancel()
                    if session.isPlaying { session.pause() }
                }
                moveTo((scrubBase ?? 0) - scale.seconds(at: value.translation.width))
            }
            .onEnded { value in
                scrubBase = nil
                glide(velocity: value.velocity.width)
            }
    }

    private func moveTo(_ seconds: Double) {
        session.seek(frame: session.timing.frame(at: max(0, seconds)))
        let id = session.clipUnderPlayhead?.clip.id
        if id != lastClipID {
            lastClipID = id
            edgeTick += 1
        }
    }

    /// A little momentum after the finger lifts: the speed halves about every 0.2 s.
    private func glide(velocity: CGFloat) {
        guard !reduceMotion, abs(velocity) > 120 else { return }
        let initial = velocity
        let pointsPerSecond = scale.pointsPerSecond
        inertia?.cancel()
        inertia = Task { @MainActor in
            var v = initial
            var seconds = session.playheadSeconds
            while !Task.isCancelled, !session.isPlaying, abs(v) > 24 {
                try? await Task.sleep(for: .milliseconds(16))
                seconds -= Double(v / pointsPerSecond) * 0.016
                v *= 0.94
                moveTo(seconds)
            }
        }
    }

    // MARK: zoom

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? scale.pointsPerSecond
                pinchBase = base
                scale = TimelineScale(pointsPerSecond: base * value.magnification)
                if !pinchSeen { pinchSeen = true }
            }
            .onEnded { _ in pinchBase = nil }
    }
}

/// The light tick on a clip edge while scrubbing, in its own modifier to keep the timeline's body simple.
private struct EditorPhoneTimelineHaptics: ViewModifier {
    let edgeTick: Int

    func body(content: Content) -> some View {
        content.haptic(.impact(weight: .light), trigger: edgeTick)
    }
}

// MARK: - a main clip

/// One main clip: the shared block with a tap to select, a long press then drag to reorder, and (when selected) the blue trim
/// handles. `restX` is where the block sits now (others make room while one is lifted), `homeX` where it started.
struct EditorPhoneMainClip: View {
    let session: EditSession
    let index: Int
    let clip: EditClip
    let span: TimelineSpan
    let scale: TimelineScale
    let restX: CGFloat
    let homeX: CGFloat
    @Binding var reorder: ReorderDrag?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { max(2, scale.x(span.length) - 2) }
    private var height: CGFloat { EditorPhoneTimeline.mainHeight }
    private var selected: Bool { session.selection == .main(clip.id) }
    private var lifted: Bool { reorder?.id == clip.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineMainClipView(
                clip: clip, number: index + 1, source: session.source(for: clip.item), seconds: span.length,
                width: width, height: height, isSelected: selected, loading: session.loadingSources[clip.item],
                failed: session.sourceFailures[clip.item] != nil, missing: session.isMissing(item: clip.item), actions: actions)
            if selected, !lifted {
                EditorPhoneTrimHandles(session: session, index: index, clip: clip, scale: scale, width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .scaleEffect(lifted && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 8, y: 3)
        .opacity(lifted ? 0.94 : 1)
        .offset(x: lifted ? homeX + (reorder?.translation ?? 0) : restX + 1, y: EditorPhoneTimeline.mainY)
        .zIndex(lifted ? 5 : (selected ? 2 : 1))
        .onTapGesture { tapped() }
        .gesture(lift)
        .modifier(EditorPhoneLiftHaptic(lifted: lifted))
    }

    private func tapped() {
        session.selection = .main(clip.id)
        if session.sourceFailures[clip.item] != nil { session.retrySource(clip.item) }
    }

    /// Long press, then drag: the clip lifts and the others make room; letting go drops it at the target.
    private var lift: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if session.selection != .main(clip.id) { session.selection = .main(clip.id) }
                reorder = ReorderDrag(id: clip.id, translation: drag.translation.width, target: target(for: drag.translation.width))
            }
            .onEnded { value in
                defer { reorder = nil }
                guard case .second(true, let drag?) = value else { return }
                let to = target(for: drag.translation.width)
                guard to != index else { return }
                withAnimation(reduceMotion ? Motion.fade : Motion.rows) { session.move(clip: clip.id, to: to) }
            }
    }

    /// The place the clip takes when dropped here: how many of the others lie wholly to its left, by their middles.
    private func target(for translation: CGFloat) -> Int {
        let center = span.start + span.length / 2 + scale.seconds(at: translation)
        return session.mainSpans.filter { $0.id != clip.id }.filter { $0.start + $0.length / 2 < center }.count
    }

    private var actions: TimelineClipActions {
        TimelineClipActions(
            select: { tapped() },
            moveEarlier: index > 0 ? { session.move(clip: clip.id, to: index - 1) } : nil,
            moveLater: index < session.timeline.main.count - 1 ? { session.move(clip: clip.id, to: index + 1) } : nil,
            split: { session.split(clip: clip.id, atFrame: session.playhead) },
            delete: { session.remove(.main(clip.id)) },
            trim: { session.selection = .main(clip.id) })
    }
}

private struct EditorPhoneLiftHaptic: ViewModifier {
    let lifted: Bool

    func body(content: Content) -> some View {
        content.haptic(.impact(weight: .medium), trigger: lifted, when: { $0 })
    }
}

// MARK: - trim handles

/// A drag zone wider than the 24 pt handle it backs: 44 pt for a finger (apple/CONTRACT-EDITOR.md 4.4).
struct EditorPhoneHitZone: View {
    let height: CGFloat
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Color.clear
            .frame(width: Metrics.hit, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() })
            .accessibilityHidden(true)
    }
}

/// The blue handles at both ends of the selected main clip. A drag changes the clip's source `in` or `out` by the distance
/// times its speed, and the playhead sits on the edge so the preview shows that frame.
struct EditorPhoneTrimHandles: View {
    let session: EditSession
    let index: Int
    let clip: EditClip
    let scale: TimelineScale
    let width: CGFloat
    let height: CGFloat

    @State private var base: (inPoint: Double, outPoint: Double)?

    private var speed: Double { session.timing.main.indices.contains(index) ? session.timing.main[index].speed : clip.speed }

    var body: some View {
        ZStack(alignment: .topLeading) {
            EditorPhoneHitZone(height: height, onDrag: dragIn, onEnd: finish)
                .offset(x: -10)
            EditorPhoneHitZone(height: height, onDrag: dragOut, onEnd: finish)
                .offset(x: width - Metrics.hit + 10)
            TimelineTrimHandle(
                edge: .leading, height: height, valueText: Copy.Editor.clockTenths(clip.in),
                onDrag: dragIn, onEnd: finish,
                step: { n in nudge(inPoint: n) })
            TimelineTrimHandle(
                edge: .trailing, height: height, valueText: Copy.Editor.clockTenths(clip.out),
                onDrag: dragOut, onEnd: finish,
                step: { n in nudge(outPoint: n) })
                .offset(x: width - TimelineTrimHandle.hitWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func capture() -> (inPoint: Double, outPoint: Double) {
        if let base { return base }
        let first = (inPoint: clip.in, outPoint: clip.out)
        base = first
        return first
    }

    private func dragIn(_ dx: CGFloat) {
        let first = capture()
        session.trim(clip: clip.id, in: first.inPoint + Double(dx / scale.pointsPerSecond) * speed, out: nil)
        showEdge(atEnd: false)
    }

    private func dragOut(_ dx: CGFloat) {
        let first = capture()
        session.trim(clip: clip.id, in: nil, out: first.outPoint + Double(dx / scale.pointsPerSecond) * speed)
        showEdge(atEnd: true)
    }

    private func nudge(inPoint n: Int) {
        session.trim(clip: clip.id, in: clip.in + Double(n) * speed / Double(session.timing.fps), out: nil)
        session.endGesture()
    }

    private func nudge(outPoint n: Int) {
        session.trim(clip: clip.id, in: nil, out: clip.out + Double(n) * speed / Double(session.timing.fps))
        session.endGesture()
    }

    private func finish() {
        base = nil
        session.endGesture()
    }

    private func showEdge(atEnd: Bool) {
        guard session.timing.main.indices.contains(index) else { return }
        let slot = session.timing.main[index]
        session.seek(frame: atEnd ? slot.start + slot.frames - 1 : slot.start)
    }
}

// MARK: - an overlay

/// One overlay on the lane above: tap to select, long press then drag to move it in time, and (when selected) amber handles for
/// how long it stays up (right) and, for a video, where in the video it starts (left).
struct EditorPhoneOverlayClip: View {
    let session: EditSession
    let index: Int
    let overlay: EditOverlay
    let span: TimelineSpan
    let scale: TimelineScale
    let originX: CGFloat

    @State private var baseFrame: Int?
    @State private var baseLength: Double?
    @State private var baseIn: Double?

    private var width: CGFloat { max(2, scale.x(span.length) - 2) }
    private var height: CGFloat { EditorPhoneTimeline.overlayHeight }
    private var selected: Bool { session.selection == .overlay(overlay.id) }
    private var source: EditSource? { session.source(for: overlay.item) }
    private var fps: Double { Double(session.timing.fps) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineOverlayClipView(
                overlay: overlay, source: source, seconds: span.length, width: width, height: height, isSelected: selected,
                missing: session.isMissing(item: overlay.item), actions: actions)
            if selected {
                if source?.kind == .video { leadingHandle }
                trailingHandle
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: originX + 1, y: EditorPhoneTimeline.overlayY)
        .zIndex(selected ? 2 : 1)
        .onTapGesture { session.selection = .overlay(overlay.id) }
        .gesture(move)
    }

    private var move: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if session.selection != .overlay(overlay.id) { session.selection = .overlay(overlay.id) }
                let start = baseFrame ?? currentStartFrame
                baseFrame = start
                let seconds = Double(start) / fps + scale.seconds(at: drag.translation.width)
                session.moveOverlay(id: overlay.id, toFrame: EditMath.roundHalfUp(max(0, seconds) * fps))
            }
            .onEnded { _ in
                baseFrame = nil
                session.endGesture()
            }
    }

    private var currentStartFrame: Int {
        session.timing.overlay.indices.contains(index) ? session.timing.overlay[index].start : EditMath.roundHalfUp(overlay.at * fps)
    }

    private var trailingHandle: some View {
        ZStack(alignment: .topLeading) {
            EditorPhoneHitZone(height: height, onDrag: dragLength, onEnd: endLength)
                .offset(x: width - Metrics.hit + 10)
            TimelineTrimHandle(
                edge: .trailing, height: height, valueText: Copy.Editor.clockTenths(overlay.length), color: EditorColor.overlay,
                onDrag: dragLength, onEnd: endLength,
                step: { n in
                    session.setOverlayLength(id: overlay.id, seconds: overlay.length + Double(n) / fps)
                    session.endGesture()
                })
                .offset(x: width - TimelineTrimHandle.hitWidth)
        }
    }

    private var leadingHandle: some View {
        ZStack(alignment: .topLeading) {
            EditorPhoneHitZone(height: height, onDrag: dragIn, onEnd: endIn)
                .offset(x: -10)
            TimelineTrimHandle(
                edge: .leading, height: height, valueText: Copy.Editor.clockTenths(overlay.in), color: EditorColor.overlay,
                onDrag: dragIn, onEnd: endIn,
                step: { n in
                    session.trimOverlay(id: overlay.id, in: overlay.in + Double(n) / fps, out: nil)
                    session.endGesture()
                })
        }
    }

    private func dragLength(_ dx: CGFloat) {
        let first = baseLength ?? overlay.length
        baseLength = first
        session.setOverlayLength(id: overlay.id, seconds: first + Double(dx / scale.pointsPerSecond))
    }

    private func endLength() {
        baseLength = nil
        session.endGesture()
    }

    private func dragIn(_ dx: CGFloat) {
        let first = baseIn ?? overlay.in
        baseIn = first
        session.trimOverlay(id: overlay.id, in: first + Double(dx / scale.pointsPerSecond), out: nil)
    }

    private func endIn() {
        baseIn = nil
        session.endGesture()
    }

    private var actions: TimelineClipActions {
        TimelineClipActions(
            select: { session.selection = .overlay(overlay.id) },
            delete: { session.remove(.overlay(overlay.id)) },
            trim: { session.selection = .overlay(overlay.id) })
    }
}
#endif
