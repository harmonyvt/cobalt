#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone and iPad timeline (apple/CONTRACT-EDITOR.md 4.4, 12, 15.5), in every layout regime: a fixed white playhead at the
/// centre and the tracks sliding under it. One finger scrubs (seeks coalesced, a fling after the release, a light tick on
/// every clip edge, all in `TimelineScrubber`); a pinch zooms about the playhead. A version 2 project is
/// `EditorPhoneEqualLanes`; this file keeps the version 1 layout (a main lane under up to three overlay layers, `+N more`
/// opens the rest) and the clip views it shares.
///
/// Nothing here scrolls: every block is placed at `centre + scale.x(its time - the scrubber's time)`, so playing, scrubbing and
/// seeking all move the same way and only the blocks on screen are built.
struct EditorPhoneTimeline: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    let openAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubber: TimelineScrubber
    @State private var pinchBase: CGFloat?
    @State private var reorder: ReorderDrag?
    @State private var showAllLayers = false

    init(session: EditSession, scale: Binding<TimelineScale>, openAdd: @escaping () -> Void) {
        self.session = session
        self._scale = scale
        self.openAdd = openAdd
        self._scrubber = State(initialValue: TimelineScrubber(session: session))
    }

    static let topY: CGFloat = 16
    static let overlayHeight: CGFloat = 28
    /// One overlay layer's lane, with its gap.
    static let laneStep: CGFloat = 32
    static let mainGap: CGFloat = 10
    static let mainHeight: CGFloat = 56
    static let bottomSpace: CGFloat = 40
    /// Layers shown before `+N more`.
    static let foldedLayers = 3
    /// Expanded stacks taller than this scroll, so a dozen layers don't push the tools off the screen.
    static let maxVisibleLanes = 8

    /// The layers in use (the highest layer with an overlay, plus one when there is room for a new one while expanded).
    private var usedLayers: Int { (session.timeline.overlay.map(\.track).max() ?? 0) + 1 }
    /// Lanes drawn: every used layer when expanded, else at most three. Any count, not a cap of 8.
    private var laneCount: Int { showAllLayers ? usedLayers : min(Self.foldedLayers, usedLayers) }
    private var visibleLanes: Int { min(laneCount, Self.maxVisibleLanes) }
    private var hiddenOverlays: Int { session.timeline.overlay.filter { $0.track >= laneCount }.count }
    private var mainY: CGFloat { Self.topY + CGFloat(visibleLanes) * Self.laneStep + Self.mainGap - 4 }
    private var height: CGFloat { mainY + Self.mainHeight + Self.bottomSpace }

    var body: some View {
        Group {
            if session.timeline.isV2 {
                EditorPhoneEqualLanes(session: session, scale: $scale, scrubber: scrubber, openAdd: openAdd)
            } else {
                legacyBody
            }
        }
        .onChange(of: session.playhead) { _, _ in scrubber.followSession() }
        .onChange(of: session.isPlaying, initial: true) { _, _ in scrubber.playbackChanged() }
        .onAppear { scrubber.followSession() }
        .onDisappear { scrubber.stop() }
    }

    /// Version 1: the main lane under the overlay lanes, a long press reorders the main clips.
    private var legacyBody: some View {
        GeometryReader { geo in
            lanes(width: geo.size.width)
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : Motion.rows, value: laneCount)
        .background(EditorColor.lane)
        .overlay(alignment: .top) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .clipped()
        .modifier(EditorPhoneTimelineHaptics(edgeTick: scrubber.tick))
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
            moreLayersChip
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrub)
        .simultaneousGesture(touchDown)
        .simultaneousGesture(pinch)
        .motion(Motion.rows, value: reorder?.target)
    }

    // MARK: where things sit

    /// The screen x of a time on the timeline.
    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        width / 2 + scale.x(seconds - scrubber.seconds)
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
                session: session, index: index, clip: clip, span: span, scale: scale, restX: restX, homeX: homeX, y: mainY,
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
        let stack = overlayStack(width: width)
            .frame(width: width, height: CGFloat(laneCount) * Self.laneStep, alignment: .topLeading)
        return Group {
            if laneCount > visibleLanes {
                ScrollView(.vertical, showsIndicators: true) { stack }
                    .frame(width: width, height: CGFloat(visibleLanes) * Self.laneStep)
                    .offset(y: Self.topY)
            } else {
                stack.offset(y: Self.topY)
            }
        }
    }

    private func overlayStack(width: CGFloat) -> some View {
        let spans = session.overlaySpans
        return ZStack(alignment: .topLeading) {
            if session.timeline.overlay.isEmpty {
                Color.clear
            } else if session.overlayTrackLimit > 1 {
                ForEach(0..<laneCount, id: \.self) { track in
                    Text(Copy.Editor.layerN(track))
                        .font(Font.cobalt(9, .medium, relativeTo: .caption2))
                        .foregroundStyle(CobaltColor.caption.opacity(0.7))
                        .padding(.leading, 4)
                        .padding(.top, layerContentY(track) + 8)
                        .accessibilityHidden(true)
                }
            }
            ForEach(Array(session.timeline.overlay.enumerated()), id: \.element.id) { index, overlay in
                if spans.indices.contains(index), overlay.track < laneCount {
                    overlayBlock(index: index, overlay: overlay, span: spans[index], width: width)
                }
            }
        }
    }

    /// Y of a layer inside the overlay stack (L1 nearest the main lane, at the bottom of the stack).
    private func layerContentY(_ track: Int) -> CGFloat { CGFloat(laneCount - 1 - track) * Self.laneStep }

    @ViewBuilder
    private func overlayBlock(index: Int, overlay: EditOverlay, span: TimelineSpan, width: CGFloat) -> some View {
        let startX = x(span.start, width: width)
        if onScreen(start: startX, length: max(2, scale.x(span.length)), width: width) {
            EditorPhoneOverlayClip(
                session: session, index: index, overlay: overlay, span: span, scale: scale, originX: startX,
                y: layerContentY(overlay.track), laneCount: laneCount)
        }
    }

    // MARK: playhead and +

    private func playhead(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimelinePlayhead(height: height, color: .white, showsHead: false)
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .offset(x: width / 2 - TimelinePlayhead.headWidth / 2)
            playheadAccessibility
                .offset(x: width / 2 - Metrics.hit / 2)
        }
    }

    /// An invisible 44 pt element on the playhead: adjustable by one second, with actions for one frame.
    private var playheadAccessibility: some View {
        Color.clear
            .frame(width: Metrics.hit, height: height)
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
        .offset(x: width - Metrics.hit - 6, y: mainY + (Self.mainHeight - Metrics.hit) / 2)
    }

    /// `+N more` while overlays sit on layers past the third; `fewer layers` folds them again.
    @ViewBuilder
    private var moreLayersChip: some View {
        if showAllLayers || hiddenOverlays > 0 {
            Button {
                withAnimation(reduceMotion ? Motion.fade : Motion.rows) { showAllLayers.toggle() }
            } label: {
                Text(showAllLayers ? Copy.Editor.fewerLayers : Copy.Editor.moreLayers(hiddenOverlays))
                    .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.text)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(CobaltColor.surface.opacity(0.9), in: Capsule())
                    .overlay { Capsule().strokeBorder(CobaltColor.border, lineWidth: 1) }
                    .frame(minHeight: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: max(0, Self.topY - 14))
        }
    }

    // MARK: scrubbing

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard reorder == nil else { return }
                if !scrubber.dragging { scrubber.beginDrag() }
                scrubber.drag(translation: value.translation.width, pointsPerSecond: scale.pointsPerSecond)
            }
            .onEnded { value in
                scrubber.endDrag(velocity: value.velocity.width, pointsPerSecond: scale.pointsPerSecond, fling: !reduceMotion)
            }
    }

    private var touchDown: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { _ in scrubber.touchDown() }
    }

    // MARK: zoom

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? scale.pointsPerSecond
                pinchBase = base
                scale = TimelineScale(pointsPerSecond: base * value.magnification)
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
    /// The main lane's top.
    let y: CGFloat
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
                failed: session.sourceFailures[clip.item] != nil, missing: session.isMissing(item: clip.item),
                problem: session.previewIssues[clip.id], actions: actions)
            if selected, !lifted {
                EditorPhoneTrimHandles(session: session, index: index, clip: clip, scale: scale, width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .scaleEffect(lifted && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
        .opacity(lifted ? 0.94 : 1)
        .offset(x: lifted ? homeX + (reorder?.translation ?? 0) : restX + 1, y: y)
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

/// One overlay on its layer's lane: tap to select, long press then drag to move it in time (and up or down a layer), and (when
/// selected) amber handles for how long it stays up (right) and, for a video, where in the video it starts (left).
struct EditorPhoneOverlayClip: View {
    let session: EditSession
    let index: Int
    let overlay: EditOverlay
    let span: TimelineSpan
    let scale: TimelineScale
    let originX: CGFloat
    /// Its lane's top.
    let y: CGFloat
    /// Lanes on screen: a drag up stops at the top one.
    let laneCount: Int

    @State private var baseFrame: Int?
    @State private var baseTrack: Int?
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
                missing: session.isMissing(item: overlay.item), showsEffect: session.showsEffect(overlay),
                problem: session.previewIssues[overlay.id], actions: actions)
            if selected {
                if source?.kind == .video { leadingHandle }
                trailingHandle
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: originX + 1, y: y)
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
                let fromTrack = baseTrack ?? overlay.track
                baseTrack = fromTrack
                let seconds = Double(start) / fps + scale.seconds(at: drag.translation.width)
                let frame = EditMath.roundHalfUp(max(0, seconds) * fps)
                // up is a higher layer: one lane per 32 pt, up to one past the lanes shown (a new layer)
                let lanes = Int((-drag.translation.height / EditorPhoneTimeline.laneStep).rounded())
                let top = min(session.overlayTrackLimit - 1, laneCount)
                let track = min(max(0, fromTrack + lanes), top)
                if track == overlay.track || !session.moveOverlay(id: overlay.id, toFrame: frame, track: track) {
                    session.moveOverlay(id: overlay.id, toFrame: frame)
                }
            }
            .onEnded { _ in
                baseFrame = nil
                baseTrack = nil
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
            trim: { session.selection = .overlay(overlay.id) },
            layerUp: overlay.track + 1 < session.overlayTrackLimit ? { _ = session.setOverlayTrack(id: overlay.id, overlay.track + 1) } : nil,
            layerDown: overlay.track > 0 ? { _ = session.setOverlayTrack(id: overlay.id, overlay.track - 1) } : nil)
    }
}
#endif
