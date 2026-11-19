#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone timeline once the project is version 2. Every lane is one row. A long press lifts the clip, ticks, and
/// opens its menu; letting go without moving leaves the menu up, and moving dismisses it and drags the clip onto
/// another lane. Near the edges the board scrolls.
struct EditorPhoneEqualLanes: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    let openAdd: () -> Void

    @Environment(EditorHost.self) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubBase: Double?
    @State private var inertia: Task<Void, Never>?
    @State private var pinchBase: CGFloat?
    @State private var lift: PhoneLift?
    @State private var scroll: CGFloat = 0
    @State private var scrollBase: CGFloat?
    @State private var keepGap = false
    @State private var edgeTick = 0
    @State private var liftTick = 0
    @State private var laneTick = 0
    @State private var lastUnder: String?

    private static let row: CGFloat = 34
    private static let zone: CGFloat = 26
    private static let maxViewport: CGFloat = 236

    private var laneCount: Int { LaneClipCommands.laneCount(session) }
    private var contentHeight: CGFloat { Self.zone + CGFloat(laneCount) * Self.row }
    private var viewport: CGFloat { min(Self.maxViewport, contentHeight) }
    private var maxScroll: CGFloat { max(0, contentHeight - viewport) }

    var body: some View {
        GeometryReader { geo in
            board(width: geo.size.width)
        }
        .frame(height: viewport)
        .background(EditorColor.lane)
        .overlay(alignment: .top) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .clipped()
        .haptic(.impact(weight: .medium), trigger: liftTick)
        .haptic(.selection, trigger: laneTick)
        .haptic(.impact(weight: .light), trigger: edgeTick)
        .laneRefusalToast(session)
        .onDisappear { inertia?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.timelineA11y)
    }

    private func board(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    lift = nil
                    session.selection = .none
                }
                .accessibilityHidden(true)
            laneContent(width: width)
                .offset(y: -scroll)
            playhead(width: width)
            if let lift, lift.showMenu, !lift.moved, let clip = clip(lift.id) { menu(lift, clip, width: width) }
            if showsGap { gapChip(width: width) }
            addButton(width: width)
        }
        .frame(width: width, height: viewport, alignment: .topLeading)
        .coordinateSpace(name: "phoneLanes")
        .contentShape(Rectangle())
        .gesture(scrub(width: width))
        .simultaneousGesture(laneScroll)
        .simultaneousGesture(pinch)
    }

    // MARK: lanes

    private func laneContent(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            newLaneZone(width: width)
            ForEach((0..<laneCount).reversed(), id: \.self) { lane in
                laneRow(lane, width: width)
            }
            if let lift, lift.moved { ghost(lift, width: width) }
            if let lift, lift.moved, let clip = clip(lift.id) { floating(lift, clip) }
        }
        .frame(width: width, height: contentHeight, alignment: .topLeading)
    }

    private func newLaneZone(width: CGFloat) -> some View {
        let hot = lift?.moved == true && lift?.target == .newLane
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(hot ? EditorColor.selection : CobaltColor.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(hot ? EditorColor.selection.opacity(0.16) : Color.clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            Text(Copy.Editor.newLaneZone)
                .font(Font.cobalt(10, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .padding(.leading, 16)
        }
        .frame(width: width, height: Self.zone)
    }

    private func laneRow(_ lane: Int, width: CGFloat) -> some View {
        let hot = lift?.moved == true && lift?.target == .lane(lane)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(hot ? EditorColor.selection.opacity(0.16) : Color.clear)
                .overlay { if hot { Rectangle().strokeBorder(EditorColor.selection.opacity(0.85), lineWidth: 1) } }
                .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            Text(lane == 0 ? "\(Copy.Editor.laneTitle(lane)) · \(Copy.Editor.laneSetsLength)" : Copy.Editor.laneTitle(lane))
                .font(Font.cobalt(9, .medium, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption.opacity(0.75))
                .lineLimit(1)
                .padding(.leading, 4)
                .padding(.top, 1)
                .accessibilityHidden(true)
            ForEach(session.timeline.clips.filter { $0.lane == lane }) { clip in
                if let span = LaneClipCommands.span(session, clip.id) {
                    phoneClip(clip, span: span, width: width)
                }
            }
        }
        .frame(width: width, height: Self.row, alignment: .topLeading)
        .offset(y: laneY(lane))
    }

    private func laneY(_ lane: Int) -> CGFloat {
        Self.zone + CGFloat(laneCount - 1 - lane) * Self.row
    }

    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        width / 2 + scale.x(seconds - session.playheadSeconds)
    }

    @ViewBuilder
    private func phoneClip(_ clip: EditLaneClip, span: TimelineSpan, width: CGFloat) -> some View {
        let home = x(span.start, width: width)
        let block = max(2, scale.x(span.length) - 2)
        if onScreen(home, block, width) || lift?.id == clip.id {
            PhoneEqualClip(
                session: session, clip: clip, span: span, scale: scale, width: width, blockWidth: block,
                lift: $lift, laneCount: laneCount, row: Self.row, zone: Self.zone, viewport: viewport,
                scroll: $scroll, maxScroll: maxScroll, keepGap: { keepGap },
                onLift: { liftTick += 1 }, onLane: { laneTick += 1 })
                .offset(x: home + 1, y: 3)
        }
    }

    private func onScreen(_ start: CGFloat, _ length: CGFloat, _ width: CGFloat) -> Bool {
        start + length > -48 && start < width + 48
    }

    // MARK: menu, ghost, chrome

    private func menu(_ lift: PhoneLift, _ clip: EditLaneClip, width: CGFloat) -> some View {
        let items = LaneClipCommands.items(session, clip)
        let height = min(200, CGFloat(items.count) * 30 + 8)
        let clipX = x(lift.start, width: width)
        let clipY = laneY(clip.lane) - scroll
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(items, id: \.action) { item in
                    Button {
                        if let reason = LaneClipCommands.run(item.action, session: session, clip: clip, keepGap: keepGap) {
                            host.show(reason, seconds: 2.4)
                        }
                        self.lift = nil
                    } label: {
                        Text(menuTitle(item, hidden: clip.hidden))
                            .font(Font.cobalt(12, .medium, relativeTo: .caption))
                            .foregroundStyle(item.action == .delete ? CobaltColor.errorText : CobaltColor.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    .opacity(item.enabled ? 1 : 0.45)
                }
            }
        }
        .frame(width: 188, height: height)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CobaltColor.border, lineWidth: 1) }
        .offset(x: min(max(6, clipX), width - 196), y: max(2, clipY - height - 4))
        .zIndex(30)
    }

    private func menuTitle(_ item: LaneMenuItem, hidden: Bool) -> String {
        let name = LaneClipCommands.title(item.action, hidden: hidden)
        guard let reason = item.reason else { return name }
        return "\(name) · \(reason)"
    }

    private func ghost(_ lift: PhoneLift, width: CGFloat) -> some View {
        let y = lift.target.lane.map { laneY($0) + 3 } ?? 4
        let h = lift.target.lane == nil ? Self.zone - 8 : Self.row - 6
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: max(2, scale.x(lift.length) - 2), height: h)
            .overlay(alignment: .topLeading) {
                Text(Copy.Editor.clockTenths(lift.dropAt))
                    .font(Font.cobalt(9.5, .semibold, relativeTo: .caption2))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .background(.white, in: Capsule())
                    .offset(y: -14)
            }
            .offset(x: x(lift.dropAt, width: width) + 1, y: y)
            .allowsHitTesting(false)
    }

    private var showsGap: Bool {
        if let lift, lift.fromLane == 0 { return true }
        if case .main = session.selection { return true }
        return false
    }

    private func floating(_ lift: PhoneLift, _ clip: EditLaneClip) -> some View {
        TimelineLaneClipView(
            clip: clip, source: session.source(for: clip.item), seconds: lift.length,
            width: max(2, scale.x(lift.length) - 2), height: Self.row - 6, isSelected: true,
            showsEffect: session.showsEffect(id: clip.id))
            .scaleEffect(reduceMotion ? 1 : 1.05)
            .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
            .position(x: lift.point.x, y: lift.point.y + scroll)
            .allowsHitTesting(false)
            .zIndex(20)
    }

    private func gapChip(width: CGFloat) -> some View {
        Button { keepGap.toggle() } label: {
            Text(Copy.Editor.keepGap)
                .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                .foregroundStyle(keepGap ? .black : CobaltColor.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(keepGap ? Color.white : Color.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .offset(x: width - 96, y: 2)
        .zIndex(24)
    }

    private func playhead(width: CGFloat) -> some View {
        TimelinePlayhead(height: viewport, color: .white, showsHead: false)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .offset(x: width / 2 - TimelinePlayhead.headWidth / 2)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Editor.a11yPlayhead)
            .accessibilityValue(Copy.Editor.a11yPlayheadValue(
                Copy.Editor.clockTenths(session.playheadSeconds), of: Copy.Editor.clockTenths(session.timing.seconds)))
    }

    private func addButton(width: CGFloat) -> some View {
        let y = min(max(0, laneY(0) - scroll), viewport - 40)
        return Button(action: openAdd) {
            Image(systemName: Symbol.Editor.add)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CobaltColor.onText)
                .frame(width: 36, height: 36)
                .background(CobaltColor.text, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Editor.addClip)
        .offset(x: width - 48, y: y)
        .zIndex(8)
    }

    // MARK: scrub and scroll

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard lift == nil, abs(value.translation.width) >= abs(value.translation.height) else { return }
                if scrubBase == nil {
                    scrubBase = session.playheadSeconds
                    lastUnder = underPlayhead()
                    inertia?.cancel()
                    if session.isPlaying { session.pause() }
                }
                let seconds = (scrubBase ?? 0) - scale.seconds(at: value.translation.width)
                session.seek(frame: session.timing.frame(at: max(0, seconds)))
                let under = underPlayhead()
                if under != lastUnder {
                    lastUnder = under
                    edgeTick += 1
                }
            }
            .onEnded { value in
                scrubBase = nil
                guard lift == nil, abs(value.velocity.width) > abs(value.velocity.height) else { return }
                glide(velocity: value.velocity.width)
            }
    }

    private var laneScroll: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard lift == nil, contentHeight > viewport, abs(value.translation.height) > abs(value.translation.width) else { return }
                if scrollBase == nil { scrollBase = scroll }
                scroll = min(maxScroll, max(0, (scrollBase ?? 0) - value.translation.height))
            }
            .onEnded { _ in scrollBase = nil }
    }

    private func glide(velocity: CGFloat) {
        guard !reduceMotion, abs(velocity) > 120 else { return }
        let initial = velocity
        let points = scale.pointsPerSecond
        inertia?.cancel()
        inertia = Task { @MainActor in
            var speed = initial
            var seconds = session.playheadSeconds
            while !Task.isCancelled, !session.isPlaying, abs(speed) > 24 {
                try? await Task.sleep(for: .milliseconds(16))
                seconds -= Double(speed / points) * 0.016
                speed *= 0.94
                session.seek(frame: session.timing.frame(at: max(0, seconds)))
            }
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? scale.pointsPerSecond
                pinchBase = base
                scale = TimelineScale(pointsPerSecond: base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func clip(_ id: String) -> EditLaneClip? {
        session.timeline.clips.first { $0.id == id }
    }

    private func underPlayhead() -> String? {
        guard session.timeline.isV2 else { return nil }
        for index in EditLanes.drawOrder(session.timeline).reversed() {
            guard index < session.timeline.clips.count, index < session.timing.laneClips.count else { continue }
            let row = session.timing.laneClips[index]
            if session.playhead >= row.start, session.playhead < row.start + row.frames { return row.id }
        }
        return nil
    }
}

/// A long press that has not become a drag yet, or the drag in progress.
struct PhoneLift: Equatable {
    var id: String
    var fromLane: Int
    var start: Double
    var length: Double
    var anchorPlayhead: Double
    var anchorX: CGFloat
    var anchored: Bool
    var moved: Bool
    var showMenu: Bool
    var point: CGPoint
    var target: LaneDropTarget
    var dropAt: Double
}

/// One clip: long press lifts it and opens the menu. Moving turns that into a lane drag.
private struct PhoneEqualClip: View {
    let session: EditSession
    let clip: EditLaneClip
    let span: TimelineSpan
    let scale: TimelineScale
    let width: CGFloat
    let blockWidth: CGFloat
    @Binding var lift: PhoneLift?
    let laneCount: Int
    let row: CGFloat
    let zone: CGFloat
    let viewport: CGFloat
    @Binding var scroll: CGFloat
    let maxScroll: CGFloat
    let keepGap: () -> Bool
    let onLift: () -> Void
    let onLane: () -> Void

    @Environment(EditorHost.self) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: Bool { LaneClipCommands.selected(session, clip.id) }
    private var raised: Bool { lift?.id == clip.id && (lift?.showMenu == true || lift?.moved == true) }
    private var source: EditSource? { session.source(for: clip.item) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineLaneClipView(
                clip: clip, source: source, seconds: span.length, width: blockWidth, height: row - 6,
                isSelected: selected, loading: session.loadingSources[clip.item],
                failed: session.sourceFailures[clip.item] != nil, missing: session.isMissing(item: clip.item),
                showsEffect: session.showsEffect(id: clip.id),
                actions: LaneClipCommands.actions(session, clip) { action in
                    if let reason = LaneClipCommands.run(action, session: session, clip: clip, keepGap: keepGap()) {
                        host.show(reason, seconds: 2.4)
                    }
                    lift = nil
                })
                .opacity(lift?.id == clip.id && lift?.moved == true ? 0.25 : 1)
                .scaleEffect(raised && lift?.moved != true ? 1.04 : 1)
                .shadow(color: .black.opacity(raised && lift?.moved != true ? 0.45 : 0), radius: 8, y: 3)
            if selected, lift?.id != clip.id { handles }
        }
        .frame(width: blockWidth, height: row - 6, alignment: .topLeading)
        .gesture(hold)
        .onTapGesture {
            LaneClipCommands.select(session, clip)
            if session.sourceFailures[clip.item] != nil { session.retrySource(clip.item) }
        }
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("phoneLanes")))
            .onChanged { value in
                switch value {
                case .first(true):
                    begin()
                case .second(true, nil):
                    begin()
                case .second(true, let drag?):
                    update(drag)
                default:
                    break
                }
            }
            .onEnded { _ in
                guard var current = lift, current.id == clip.id else { return }
                if current.moved {
                    withAnimation(reduceMotion ? Motion.fade : Motion.rows) {
                        LaneClipCommands.drop(session, id: clip.id, target: current.target, at: current.dropAt, keepGap: keepGap())
                    }
                    lift = nil
                } else {
                    current.showMenu = true
                    lift = current
                }
            }
    }

    private func begin() {
        guard lift?.id != clip.id else { return }
        if session.isPlaying { session.pause() }
        LaneClipCommands.select(session, clip)
        lift = PhoneLift(
            id: clip.id, fromLane: clip.lane, start: span.start, length: span.length, anchorPlayhead: session.playheadSeconds,
            anchorX: 0, anchored: false, moved: false, showMenu: true, point: .zero, target: .lane(clip.lane), dropAt: span.start)
        onLift()
    }

    private func update(_ drag: DragGesture.Value) {
        guard var current = lift, current.id == clip.id else { return }
        if !current.anchored {
            current.anchored = true
            current.anchorX = drag.startLocation.x
            current.anchorPlayhead = session.playheadSeconds
        }
        let distance = hypot(drag.translation.width, drag.translation.height)
        if distance > 8 {
            if !current.moved { current.showMenu = false }
            current.moved = true
        }
        if current.moved {
            let horizontal = EditLaneDrop.autoscroll(position: Double(drag.location.x), viewport: Double(width), edge: 28, step: 0.08)
            if horizontal != 0 {
                session.seek(frame: session.timing.frame(at: max(0, session.playheadSeconds + horizontal)))
            }
            let vertical = EditLaneDrop.autoscroll(position: Double(drag.location.y), viewport: Double(viewport), edge: 28, step: 6)
            if vertical != 0 { scroll = min(maxScroll, max(0, scroll + vertical)) }
        }
        let raw = span.start + (session.playheadSeconds - current.anchorPlayhead) + scale.seconds(at: drag.location.x - current.anchorX)
        let snapped = EditLaneDrop.snap(
            start: raw, length: span.length, points: LaneClipCommands.snapPoints(session, except: clip.id),
            threshold: 6 / Double(scale.pointsPerSecond))
        let target = EditLaneDrop.hit(
            y: Double(drag.location.y + scroll), laneCount: laneCount, rowHeight: Double(row), zoneHeight: Double(zone))
        if current.moved, target != current.target { onLane() }
        current.point = drag.location
        current.target = target
        current.dropAt = snapped.value
        lift = current
    }

    @ViewBuilder
    private var handles: some View {
        if clip.lane == 0, let index = session.timeline.main.firstIndex(where: { $0.id == clip.id }) {
            EditorPhoneTrimHandles(
                session: session, index: index, clip: session.timeline.main[index], scale: scale,
                width: blockWidth, height: row - 6)
        } else if let overlay = session.timeline.overlay.first(where: { $0.id == clip.id }) {
            PhoneEqualOverlayHandles(
                session: session, overlay: overlay, scale: scale, width: blockWidth, height: row - 6, video: source?.kind == .video)
        }
    }
}

/// How long a clip above lane 0 stays up, and where a video starts. The same handles the overlay sheet still edits.
private struct PhoneEqualOverlayHandles: View {
    let session: EditSession
    let overlay: EditOverlay
    let scale: TimelineScale
    let width: CGFloat
    let height: CGFloat
    let video: Bool

    @State private var baseLength: Double?
    @State private var baseIn: Double?

    private var fps: Double { Double(session.timing.fps) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if video {
                EditorPhoneHitZone(height: height, onDrag: dragIn, onEnd: { baseIn = nil; session.endGesture() })
                    .offset(x: -10)
                TimelineTrimHandle(
                    edge: .leading, height: height, valueText: Copy.Editor.clockTenths(overlay.in), color: EditorColor.selection,
                    onDrag: dragIn, onEnd: { baseIn = nil; session.endGesture() },
                    step: { n in
                        session.trimOverlay(id: overlay.id, in: overlay.in + Double(n) / fps, out: nil)
                        session.endGesture()
                    })
            }
            EditorPhoneHitZone(height: height, onDrag: dragLength, onEnd: { baseLength = nil; session.endGesture() })
                .offset(x: width - Metrics.hit + 10)
            TimelineTrimHandle(
                edge: .trailing, height: height, valueText: Copy.Editor.clockTenths(overlay.length), color: EditorColor.selection,
                onDrag: dragLength, onEnd: { baseLength = nil; session.endGesture() },
                step: { n in
                    session.setOverlayLength(id: overlay.id, seconds: overlay.length + Double(n) / fps)
                    session.endGesture()
                })
                .offset(x: width - TimelineTrimHandle.hitWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func dragLength(_ dx: CGFloat) {
        let base = baseLength ?? overlay.length
        baseLength = base
        session.setOverlayLength(id: overlay.id, seconds: base + Double(dx / scale.pointsPerSecond))
    }

    private func dragIn(_ dx: CGFloat) {
        let base = baseIn ?? overlay.in
        baseIn = base
        session.trimOverlay(id: overlay.id, in: base + Double(dx / scale.pointsPerSecond), out: nil)
    }
}
#endif
