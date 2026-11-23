import CobaltKit
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// The Mac and iPad timeline once the project is version 2. Every lane is the same height. Lane 0 is the bottom row; the
/// header column numbers the lanes with a small icon, and a `+` at the bottom of it adds a lane. Dragging a clip lifts it; a
/// dashed strip above the top lane (shown only while a clip is lifted) opens a new lane, the lane under the pointer lights up
/// and a ghost shows where it will land. The ruler scrubs through `TimelineRulerScrub`: coalesced seeks and a tick on a clip edge.
struct EditorEqualLanes: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    let height: CGFloat

    @Environment(EditorHost.self) private var host
    @State private var scroll = ScrollPosition()
    @State private var scrollX = TimelineScrollOffset()
    @State private var visibleWidth: CGFloat = 0
    @State private var drag: LaneDrag?
    @State private var pinchBase: CGFloat?
    @State private var scrubbing = false
    @State private var laneScroll = ScrollPosition(idType: Int.self)
    @State private var keepGap = false
    @State private var rulerScrub: TimelineRulerScrub

    init(session: EditSession, scale: Binding<TimelineScale>, height: CGFloat) {
        self.session = session
        self._scale = scale
        self.height = height
        self._rulerScrub = State(initialValue: TimelineRulerScrub(session: session))
    }

    private static let headerWidth: CGFloat = 92
    private static let rulerHeight: CGFloat = 28
    private static let footer: CGFloat = 48
    private static let zoneHeight: CGFloat = 24

    private var laneCount: Int { LaneClipCommands.laneCount(session) }
    private var scrolls: Bool { laneCount > 8 }
    private var audioHeight: CGFloat { max(32, min(48, (height - Self.rulerHeight - Self.footer) * 0.16)) }
    private var rowHeight: CGFloat {
        let room = height - Self.rulerHeight - Self.footer - Self.zoneHeight - audioHeight
        if scrolls { return 28 }
        return min(44, max(26, room / CGFloat(max(1, laneCount))))
    }
    private var blockHeight: CGFloat { max(16, rowHeight - min(12, rowHeight * 0.28)) }
    private var laneViewport: CGFloat { Self.zoneHeight + rowHeight * CGFloat(min(laneCount, 8)) }
    private var contentSeconds: Double {
        max(session.timing.seconds + 8, visibleWidth > 0 ? scale.seconds(at: visibleWidth) : 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            headers
                .frame(width: Self.headerWidth)
                .background(EditorColor.lane)
            Rectangle().fill(EditorColor.line).frame(width: 1)
            scrollArea
        }
        .background(EditorColor.lane)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.timelineA11y)
        .laneRefusalToast(session)
        .haptic(.impact(weight: .light), trigger: rulerScrub.tick)
        .background { EqualLanePlayheadFollow(session: session) { followPlayhead() } }
    }

    // MARK: headers

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.rulerHeight)
            laneHeaderScroll
            audioHeader
            Spacer(minLength: 0)
            addLaneButton
            zoomRow
        }
    }

    @ViewBuilder
    private var laneHeaderScroll: some View {
        let stack = VStack(spacing: 0) {
            Color.clear.frame(height: Self.zoneHeight)
            ForEach((0..<laneCount).reversed(), id: \.self) { lane in
                laneHeader(lane: lane, height: rowHeight)
                    .id(lane)
            }
        }
        if scrolls {
            ScrollView(.vertical, showsIndicators: false) { stack }
                .scrollPosition($laneScroll)
                .frame(height: laneViewport)
        } else {
            stack
        }
    }

    /// A small icon and the lane's number: a film strip for lane 0 (it sets the length), a stack for the others.
    private func laneHeader(lane: Int, height: CGFloat) -> some View {
        HStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: lane == 0 ? "film" : "square.stack")
                    .font(.system(size: 10, weight: .medium))
                Text("\(lane + 1)")
                    .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                    .monospacedDigit()
            }
            .foregroundStyle(CobaltColor.text)
            .accessibilityLabel(Copy.Editor.laneTitle(lane))
            Spacer(minLength: 0)
            laneControls(lane)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var audioHeader: some View {
        Text(Copy.Editor.trackAudio)
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.caption)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, minHeight: audioHeight, maxHeight: audioHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .accessibilityHidden(true)
    }

    /// `+` at the bottom of the header column: a new lane (the add sheet in layer mode).
    private var addLaneButton: some View {
        let can = EditLaneDrop.canInsertLane(above: laneCount - 1, occupied: session.timeline.clips.map(\.lane))
        return Button { host.ui.open(.addLayer, page: nil) } label: {
            Image(systemName: Symbol.Editor.add)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Platform.isMac ? 28 : 44, height: Platform.isMac ? 24 : 32)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(can ? CobaltColor.text : CobaltColor.caption)
        .disabled(!can)
        .help(Copy.Editor.addLayer)
        .accessibilityLabel(Copy.Editor.addLayer)
        .padding(.bottom, 4)
    }

    private func laneControls(_ lane: Int) -> some View {
        let hidden = session.laneHidden(lane)
        let locked = session.isLaneLocked(lane)
        return HStack(spacing: 0) {
            headerButton(hidden ? Symbol.Editor.layerShow : Symbol.Editor.layerHide, hidden ? Copy.Editor.layerShow : Copy.Editor.layerHide) {
                session.setLaneHidden(lane, !hidden)
            }
            headerButton(locked ? Symbol.Editor.layerLock : Symbol.Editor.layerUnlock, locked ? Copy.Editor.layerUnlock : Copy.Editor.layerLock) {
                session.setLaneLocked(lane, !locked)
            }
        }
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.caption)
        .help(label)
        .accessibilityLabel(label)
    }

    private var zoomRow: some View {
        HStack(spacing: 6) {
            zoomButton(Symbol.Editor.zoomOut, Copy.Editor.zoomOut, disabled: scale.isAtMinimum, key: "−") { zoom(by: 0.8) }
            zoomButton(Symbol.Editor.zoomIn, Copy.Editor.zoomIn, disabled: scale.isAtMaximum, key: "=") { zoom(by: 1.25) }
        }
        .padding(.bottom, 6)
        .frame(height: Self.footer)
    }

    private func zoomButton(_ symbol: String, _ label: String, disabled: Bool, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Platform.isMac ? 28 : 44, height: Platform.isMac ? 24 : 32)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.text)
        .disabled(disabled)
        .help("\(label) · ⌘\(key)")
        .accessibilityLabel(label)
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { scale = scale.zoomed(by: factor) }
    }

    // MARK: scrolling board

    private var scrollArea: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            // pinned to the top: a horizontal scroll view centres shorter content, which slid the lanes below their headers
            board.frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            scrollX.x = x
            // kept as seconds (CONTRACT-EDITOR 15.2), so a zoom or a new layout puts the same moment at the left edge
            host.ui.timelineScrollSeconds = Double(max(0, x) / scale.pointsPerSecond)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        .onAppear {
            let x = CGFloat(host.ui.timelineScrollSeconds) * scale.pointsPerSecond
            if x > 0 { scroll.scrollTo(x: x) }
        }
        .simultaneousGesture(pinch)
    }

    private var board: some View {
        let width = scale.x(contentSeconds)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: width)
                lanes(width: width)
                audio(width: width)
            }
            EqualLanePlayhead(session: session, scale: scale, rulerHeight: Self.rulerHeight, height: Self.rulerHeight + laneViewport + audioHeight)
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func ruler(width: CGFloat) -> some View {
        TimelineRuler(scale: scale, duration: contentSeconds, height: Self.rulerHeight)
            .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
            .background(EditorColor.lane)
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        rulerScrub.move(to: scale.seconds(at: value.location.x))
                    }
                    .onEnded { value in
                        scrubbing = false
                        rulerScrub.end(at: scale.seconds(at: value.location.x))
                    })
    }

    @ViewBuilder
    private func lanes(width: CGFloat) -> some View {
        let stack = laneStack(width: width)
        if scrolls {
            ScrollView(.vertical, showsIndicators: true) { stack }
                .scrollPosition($laneScroll)
                .frame(width: width, height: laneViewport)
        } else {
            stack
        }
    }

    private func laneStack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                newLaneZone(width: width)
                ForEach((0..<laneCount).reversed(), id: \.self) { lane in
                    laneRow(lane, width: width)
                }
            }
            if let drag, drag.moved { ghost(drag) }
            if let drag, drag.moved, let clip = session.timeline.clips.first(where: { $0.id == drag.id }) { lifted(drag, clip) }
            if drag == nil { toolbar }
            if !Platform.isMac, showsKeepGap { keepGapChip }
        }
        .coordinateSpace(name: "equalLanes")
        .frame(width: width, height: Self.zoneHeight + rowHeight * CGFloat(laneCount), alignment: .topLeading)
    }

    /// The strip above the top lane: bin files can be dropped on it for a new lane, and while a clip is lifted it shows dashed
    /// (lit when the pointer is on it). No words.
    private func newLaneZone(width: CGFloat) -> some View {
        let lifted = drag?.moved == true
        let hot = lifted && drag?.target == .newLane
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(hot ? EditorColor.selection : CobaltColor.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .background(hot ? EditorColor.selection.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .opacity(lifted ? 1 : 0)
            .frame(width: width, height: Self.zoneHeight)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, location in
                dropFiles(items, lane: nil, x: location.x)
            } isTargeted: { _ in }
    }

    private func laneRow(_ lane: Int, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(hot: drag?.moved == true && drag?.target == .lane(lane))
                .onTapGesture { deselect() }
            ForEach(session.timeline.clips.filter { $0.lane == lane }) { clip in
                if let span = LaneClipCommands.span(session, clip.id) {
                    EqualLaneClipBlock(
                        session: session, clip: clip, span: span, scale: scale, laneHeight: rowHeight,
                        laneCount: laneCount, rowHeight: rowHeight, zoneHeight: Self.zoneHeight, drag: $drag,
                        keepGap: { gapKept }, run: { _ in })
                        .offset(x: scale.x(span.start) + 1, y: (rowHeight - blockHeight) / 2)
                        .zIndex(drag?.id == clip.id ? 5 : 1)
                }
            }
            if lane == 0, let mark = overflow(width: width) { mark }
        }
        .frame(width: width, height: rowHeight, alignment: .topLeading)
        .id(lane)
        .dropDestination(for: String.self) { items, location in
            dropFiles(items, lane: lane, x: location.x)
        } isTargeted: { _ in }
    }

    private func laneBackground(hot: Bool) -> some View {
        Rectangle()
            .fill(hot ? EditorColor.selection.opacity(0.16) : Color.clear)
            .overlay { if hot { Rectangle().strokeBorder(EditorColor.selection.opacity(0.8), lineWidth: 1) } }
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .contentShape(Rectangle())
    }

    private func audio(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(hot: false)
                .onTapGesture { deselect() }
            ForEach(session.timeline.clips) { clip in
                if let span = LaneClipCommands.span(session, clip.id), session.source(for: clip.item)?.kind == .video {
                    TimelineAudioBar(
                        volume: clip.volume, muted: clip.muted, width: max(2, scale.x(span.length) - 2),
                        height: max(14, audioHeight - 14))
                        .offset(x: scale.x(span.start) + 1, y: 7)
                        .opacity(clip.hidden ? 0.35 : 1)
                }
            }
        }
        .frame(width: width, height: audioHeight, alignment: .topLeading)
    }

    // MARK: drag chrome

    private func laneTop(_ lane: Int) -> CGFloat {
        Self.zoneHeight + CGFloat(laneCount - 1 - lane) * rowHeight
    }

    @ViewBuilder
    private func ghost(_ drag: LaneDrag) -> some View {
        let y = drag.target.lane.map { laneTop($0) + (rowHeight - blockHeight) / 2 } ?? 4
        let h = drag.target.lane == nil ? Self.zoneHeight - 8 : blockHeight
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Text(Copy.Editor.clockTenths(drag.drop))
                .font(Font.cobalt(9.5, .semibold, relativeTo: .caption2))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .background(.white, in: Capsule())
                .offset(y: -16)
        }
        .frame(width: max(2, scale.x(drag.length) - 2), height: h, alignment: .topLeading)
        .offset(x: scale.x(drag.drop) + 1, y: y)
        .allowsHitTesting(false)
    }

    private func lifted(_ drag: LaneDrag, _ clip: EditLaneClip) -> some View {
        TimelineLaneClipView(
            clip: clip, source: session.source(for: clip.item), seconds: drag.length,
            width: max(2, scale.x(drag.length) - 2), height: blockHeight, isSelected: true,
            showsEffect: session.showsEffect(id: clip.id))
            .scaleEffect(1.06)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 6)
            .offset(x: drag.point.x - scale.x(drag.grab), y: drag.point.y - blockHeight / 2)
            .allowsHitTesting(false)
            .zIndex(20)
    }

    @ViewBuilder
    private var toolbar: some View {
        if let clip = selectedClip, let span = LaneClipCommands.span(session, clip.id) {
            LaneClipToolbar(hidden: clip.hidden) { action in
                if let reason = LaneClipCommands.run(action, session: session, clip: clip, keepGap: gapKept) {
                    host.show(reason, seconds: 2.4)
                }
            }
            .offset(x: scale.x(span.start), y: max(0, laneTop(clip.lane) - 24))
            .zIndex(16)
        }
    }

    private var keepGapChip: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                keepGap.toggle()
            } label: {
                Text(Copy.Editor.keepGap)
                    .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                    .foregroundStyle(keepGap ? .black : CobaltColor.text)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(keepGap ? Color.white : Color.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.zoneHeight)
        .zIndex(18)
    }

    /// iPad has no ⌥ key, so a selected bottom-lane clip offers the chip before the drag.
    private var showsKeepGap: Bool {
        if drag?.fromLane == 0 { return true }
        if case .main = session.selection { return true }
        return false
    }

    private var selectedClip: EditLaneClip? {
        let id: String? = switch session.selection {
        case .main(let id), .overlay(let id): id
        case .none: nil
        }
        return id.flatMap { wanted in session.timeline.clips.first { $0.id == wanted } }
    }

    private var gapKept: Bool {
        if Platform.isMac { return optionHeld }
        return keepGap
    }

    private var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }

    private func overflow(width: CGFloat) -> AnyView? {
        guard session.problems.contains(where: { $0 == .tooLong || $0 == .tooManyClips }) else { return nil }
        let x = scale.x(session.timing.seconds)
        return AnyView(
            RoundedRectangle(cornerRadius: 2)
                .fill(EditorColor.over)
                .frame(width: 5, height: rowHeight - 10)
                .offset(x: min(width - 8, x + 2), y: 5)
                .allowsHitTesting(false)
                .accessibilityLabel(session.problemLine ?? Copy.Editor.tooLongBar))
    }

    private func deselect() {
        guard session.tool != .blade else { return }
        session.selection = .none
    }

    // MARK: bin drops

    private func dropFiles(_ items: [String], lane: Int?, x: CGFloat) -> Bool {
        guard let source = items.compactMap(EditorDragPayload.source(from:)).first else { return false }
        guard source.kind != .unsupported else {
            host.show(Copy.Editor.cantEdit)
            return false
        }
        let frame = session.timing.frame(at: scale.seconds(at: x))
        if lane == 0 {
            guard source.kind == .video else {
                host.show(Copy.Editor.leftOut(1))
                return false
            }
            let seconds = scale.seconds(at: x)
            let index = session.mainSpans.filter { $0.start + $0.length / 2 < seconds }.count
            session.add([source], at: index)
            return true
        }
        let track = lane.map { $0 - 1 } ?? ((session.timeline.overlay.map(\.track).max() ?? -1) + 1)
        guard session.addOverlay(source, atFrame: frame, track: min(max(0, track), session.overlayTrackLimit - 1))
                || session.addOverlay(source, atFrame: frame) else {
            host.show(Copy.Editor.dropIntoOverlayRefused)
            return false
        }
        return true
    }

    // MARK: zoom and follow

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? scale.pointsPerSecond
                pinchBase = base
                scale = TimelineScale(pointsPerSecond: base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func followPlayhead() {
        guard session.isPlaying, !scrubbing, visibleWidth > 0 else { return }
        let x = scale.x(session.playheadSeconds)
        if x < scrollX.x + 24 || x > scrollX.x + visibleWidth * 0.85 {
            scroll.scrollTo(x: max(0, x - 80))
        }
    }
}

/// Calls `follow` when the playhead moves, without making the lanes redraw on every frame.
private struct EqualLanePlayheadFollow: View {
    let session: EditSession
    let follow: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: session.playhead) { _, _ in follow() }
    }
}

/// The playhead over the equal lanes. Reading it here keeps playback from redrawing the clips.
private struct EqualLanePlayhead: View {
    let session: EditSession
    let scale: TimelineScale
    let rulerHeight: CGFloat
    let height: CGFloat

    var body: some View {
        let x = scale.x(session.playheadSeconds)
        ZStack(alignment: .topLeading) {
            TimelinePlayhead(height: height)
                .offset(x: x - TimelinePlayhead.headWidth / 2)
            Color.clear
                .frame(width: 44, height: rulerHeight)
                .allowsHitTesting(false)
                .offset(x: x - 22)
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
        }
    }
}
