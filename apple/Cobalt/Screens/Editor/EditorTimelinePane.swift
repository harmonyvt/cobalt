import CobaltKit
import SwiftUI

/// The bottom of the Mac and iPad screen (apple/CONTRACT-EDITOR.md 4.3, 12): track headers (the overlay layers `L1`...,
/// `main`, `audio`) and zoom on the left; on the right a horizontally scrolling ruler and the lanes under one playhead. Each
/// overlay layer is a lane, the highest on top, plus an empty one above them for a new layer (when the server has layers).
/// Click selects, click on nothing deselects, drag a clip's body to reorder (main) or move in time (overlay, snapping within
/// 6 pt; up or down to another layer), drag a handle to trim, click with the blade to split. Files dragged from the bin land on
/// the main lane (videos) or an overlay lane (anything).
struct EditorTimelinePane: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    /// The pane's height (180...480); the lanes share what the ruler and the footer leave.
    let height: CGFloat

    @Environment(EditorHost.self) private var host
    @State private var scroll = ScrollPosition()
    @State private var scrollX: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var reorder: ReorderDrag?
    @State private var pinchBase: CGFloat?
    @State private var scrubbing = false
    @State private var bladeX: CGFloat?
    @State private var mainTargeted = false
    @State private var overlayTargeted: Int?

    private static let headerWidth: CGFloat = 92
    private static let rulerHeight: CGFloat = 28
    private static let footer: CGFloat = 34

    private var unit: CGFloat { min(80, max(34, (height - Self.rulerHeight - Self.footer) / 3.2)) }
    /// Overlay lanes: every layer up to the highest in use, plus an empty one for a new layer, within the server's limit.
    private var overlayLanes: Int {
        let used = (session.timeline.overlay.map(\.track).max() ?? -1) + 1
        return min(session.overlayTrackLimit, max(1, session.timeline.overlay.isEmpty ? 1 : used + 1))
    }
    /// One lane is as tall as before; several share about two lanes' room (at least 22 pt each).
    private var overlayHeight: CGFloat { overlayLanes == 1 ? unit : max(22, unit * 1.8 / CGFloat(overlayLanes)) }
    private var overlaysHeight: CGFloat { overlayHeight * CGFloat(overlayLanes) }
    private var mainHeight: CGFloat { unit * 1.4 }
    private var audioHeight: CGFloat { unit * 0.8 }
    private var lanesHeight: CGFloat { overlaysHeight + mainHeight + audioHeight }

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
        .onChange(of: session.playhead) { _, _ in followPlayhead() }
        .haptic(.selection, trigger: session.selection)
    }

    // MARK: headers and zoom

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.rulerHeight)
            if overlayLanes == 1 {
                header(Copy.Editor.trackOverlay, height: overlayHeight)
            } else {
                ForEach((0..<overlayLanes).reversed(), id: \.self) { track in
                    header(Copy.Editor.layerN(track), height: overlayHeight)
                }
            }
            header(Copy.Editor.trackMain, height: mainHeight)
            header(Copy.Editor.trackAudio, height: audioHeight)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                zoomButton(Symbol.Editor.zoomOut, Copy.Editor.zoomOut, disabled: scale.isAtMinimum, key: "−") { zoom(by: 0.8) }
                zoomButton(Symbol.Editor.zoomIn, Copy.Editor.zoomIn, disabled: scale.isAtMaximum, key: "=") { zoom(by: 1.25) }
            }
            .padding(.bottom, 6)
            .frame(height: Self.footer)
        }
    }

    private func header(_ title: String, height: CGFloat) -> some View {
        Text(title)
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.caption)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .accessibilityHidden(true)
    }

    private func zoomButton(_ symbol: String, _ label: String, disabled: Bool, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Platform.isMac ? 28 : 44, height: Platform.isMac ? 24 : 32)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    // MARK: the scrolling part

    private var scrollArea: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            content
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        .simultaneousGesture(pinch)
    }

    private var content: some View {
        let width = scale.x(contentSeconds)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: width)
                ForEach((0..<overlayLanes).reversed(), id: \.self) { track in
                    overlayLane(width: width, track: track)
                }
                mainLane(width: width)
                audioLane(width: width)
            }
            TimelinePlayhead(height: Self.rulerHeight + lanesHeight)
                .offset(x: scale.x(session.playheadSeconds) - TimelinePlayhead.headWidth / 2)
            playheadAccessibility
        }
        .frame(width: width, height: Self.rulerHeight + lanesHeight, alignment: .topLeading)
    }

    // MARK: ruler and seeking

    private func ruler(width: CGFloat) -> some View {
        TimelineRuler(scale: scale, duration: contentSeconds, height: Self.rulerHeight)
            .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
            .background(EditorColor.lane)
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !scrubbing {
                            scrubbing = true
                            if session.isPlaying { session.pause() }
                        }
                        session.seek(frame: session.timing.frame(at: scale.seconds(at: value.location.x)))
                    }
                    .onEnded { _ in scrubbing = false })
    }

    private var playheadAccessibility: some View {
        Color.clear
            .frame(width: 44, height: Self.rulerHeight)
            .contentShape(Rectangle())
            .allowsHitTesting(false)
            .offset(x: scale.x(session.playheadSeconds) - 22)
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

    // MARK: lanes

    /// The lane of overlay layer `track`.
    private func overlayLane(width: CGFloat, track: Int) -> some View {
        let spans = session.overlaySpans
        return ZStack(alignment: .topLeading) {
            laneBackground(height: overlayHeight, targeted: overlayTargeted == track)
                .onTapGesture { deselect() }
            ForEach(Array(session.timeline.overlay.enumerated()), id: \.element.id) { index, overlay in
                if spans.indices.contains(index), overlay.track == track {
                    OverlayClipBlock(
                        session: session, index: index, overlay: overlay, span: spans[index], scale: scale,
                        laneHeight: overlayHeight, topTrack: min(session.overlayTrackLimit - 1, overlayLanes), snap: snapped)
                }
            }
        }
        .frame(width: width, height: overlayHeight, alignment: .topLeading)
        .dropDestination(for: String.self) { items, location in
            dropOnOverlay(items, at: location, track: overlayLanes > 1 ? track : nil)
        } isTargeted: { targeted in
            if targeted { overlayTargeted = track } else if overlayTargeted == track { overlayTargeted = nil }
        }
        .motion(Motion.rows, value: session.timeline.overlay.map(\.id))
    }

    private func mainLane(width: CGFloat) -> some View {
        let spans = session.mainSpans
        return ZStack(alignment: .topLeading) {
            laneBackground(height: mainHeight, targeted: mainTargeted)
                .onTapGesture { deselect() }
            ForEach(Array(session.timeline.main.enumerated()), id: \.element.id) { index, clip in
                if spans.indices.contains(index) {
                    MainClipBlock(
                        session: session, index: index, clip: clip, span: spans[index], scale: scale,
                        laneHeight: mainHeight, reorder: $reorder)
                }
            }
            if let reorder { insertionBar(for: reorder, spans: spans) }
            if session.tool == .blade, let bladeX {
                Rectangle().fill(EditorColor.selection).frame(width: 1, height: mainHeight).offset(x: bladeX).allowsHitTesting(false)
            }
            if let over = overflow(spans: spans) { over }
        }
        .frame(width: width, height: mainHeight, alignment: .topLeading)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): bladeX = point.x
            case .ended: bladeX = nil
            }
        }
        .dropDestination(for: String.self) { items, location in
            dropOnMain(items, at: location, spans: spans)
        } isTargeted: { mainTargeted = $0 }
        .motion(Motion.rows, value: session.timeline.main.map(\.id))
    }

    private func audioLane(width: CGFloat) -> some View {
        let spans = session.mainSpans
        let overlaySpans = session.overlaySpans
        return ZStack(alignment: .topLeading) {
            laneBackground(height: audioHeight, targeted: false)
                .onTapGesture { deselect() }
            ForEach(Array(session.timeline.main.enumerated()), id: \.element.id) { index, clip in
                if spans.indices.contains(index) {
                    TimelineAudioBar(
                        volume: clip.volume, muted: clip.muted, width: max(2, scale.x(spans[index].length) - 2),
                        height: max(14, audioHeight - 14))
                        .offset(x: scale.x(spans[index].start) + 1, y: 7)
                }
            }
            ForEach(Array(session.timeline.overlay.enumerated()), id: \.element.id) { index, overlay in
                if overlaySpans.indices.contains(index), !overlay.muted, session.source(for: overlay.item)?.kind == .video {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(EditorColor.overlay.opacity(0.4 + 0.6 * overlay.volume))
                        .frame(width: max(2, scale.x(overlaySpans[index].length) - 2), height: 3)
                        .offset(x: scale.x(overlaySpans[index].start) + 1, y: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: audioHeight, alignment: .topLeading)
    }

    private func laneBackground(height: CGFloat, targeted: Bool) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            .overlay {
                if targeted {
                    Rectangle().strokeBorder(EditorColor.selection.opacity(0.7), lineWidth: 2)
                }
            }
    }

    private func deselect() {
        guard session.tool != .blade else { return }
        session.selection = .none
    }

    /// The blue bar where a dragged clip would land.
    @ViewBuilder
    private func insertionBar(for drag: ReorderDrag, spans: [TimelineSpan]) -> some View {
        let others = spans.filter { $0.id != drag.id }
        let x: CGFloat = drag.target < others.count ? scale.x(others[drag.target].start) : (others.last.map { scale.x($0.end) } ?? 0)
        Rectangle()
            .fill(EditorColor.selection)
            .frame(width: 3, height: mainHeight - 8)
            .offset(x: max(0, x - 1), y: 4)
            .allowsHitTesting(false)
            .zIndex(6)
    }

    /// `too long` / `too many clips`: a red bar at the end of the main track.
    private func overflow(spans: [TimelineSpan]) -> AnyView? {
        guard session.problems.contains(where: { $0 == .tooLong || $0 == .tooManyClips }) else { return nil }
        let x = scale.x(spans.last?.end ?? 0)
        return AnyView(
            RoundedRectangle(cornerRadius: 2)
                .fill(EditorColor.over)
                .frame(width: 5, height: mainHeight - 12)
                .offset(x: x + 2, y: 6)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.problemLine ?? Copy.Editor.tooLongBar))
    }

    // MARK: drops from the bin

    private func dropOnMain(_ items: [String], at location: CGPoint, spans: [TimelineSpan]) -> Bool {
        guard let source = items.compactMap(EditorDragPayload.source(from:)).first else { return false }
        switch source.kind {
        case .video:
            let seconds = scale.seconds(at: location.x)
            let index = spans.filter { $0.start + $0.length / 2 < seconds }.count
            withAnimation(Motion.rows) { session.add([source], at: index) }
            return true
        case .gif, .photo:
            host.show(Copy.Editor.leftOut(1))
            return false
        case .unsupported:
            host.show(Copy.Editor.cantEdit)
            return false
        }
    }

    private func dropOnOverlay(_ items: [String], at location: CGPoint, track: Int?) -> Bool {
        guard let source = items.compactMap(EditorDragPayload.source(from:)).first else { return false }
        guard source.kind != .unsupported else {
            host.show(Copy.Editor.cantEdit)
            return false
        }
        let frame = session.timing.frame(at: scale.seconds(at: location.x))
        // the lane it was dropped on, else the lowest free layer there
        guard session.addOverlay(source, atFrame: frame, track: track) || session.addOverlay(source, atFrame: frame) else {
            host.show(Copy.Editor.dropIntoOverlayRefused)
            return false
        }
        return true
    }

    // MARK: snapping

    /// An overlay's start moved to the nearest clip edge, overlay edge, the playhead, the start or the end within 6 pt.
    private func snapped(start: Double, length: Double, id: String) -> (value: Double, snapped: Bool) {
        let threshold = 6 / Double(scale.pointsPerSecond)
        var targets: [Double] = [0, session.timing.seconds, session.playheadSeconds]
        for span in session.mainSpans { targets += [span.start, span.end] }
        for span in session.overlaySpans where span.id != id { targets += [span.start, span.end] }
        var best: Double?
        for edge in [start, start + length] {
            for target in targets {
                let delta = target - edge
                if abs(delta) <= threshold, abs(delta) < abs(best ?? .infinity) { best = delta }
            }
        }
        guard let best else { return (start, false) }
        return (max(0, start + best), true)
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

    /// While playing, the visible part follows the playhead: when it reaches the right fifth, the playhead jumps to the left.
    private func followPlayhead() {
        guard session.isPlaying, !scrubbing, visibleWidth > 0 else { return }
        let x = scale.x(session.playheadSeconds)
        if x < scrollX + 24 || x > scrollX + visibleWidth * 0.85 {
            scroll.scrollTo(x: max(0, x - 80))
        }
    }
}
