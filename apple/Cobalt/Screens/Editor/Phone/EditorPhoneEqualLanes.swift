#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone and iPad timeline once the project is version 2 (CONTRACT-EDITOR 15.1, 15.5). The lanes fill the slot the shell
/// gives the timeline: lane 0 and the lanes with a keyed or large clip up to 130 pt, the others at least 40 pt (the kit's
/// `TimelineLaneLayout`); past the slot the stack scrolls up and down. The playhead is fixed in the middle and one finger scrubs
/// the time under it (`TimelineScrubber`). A column on the left numbers the lanes with a small icon; a `+` under it adds a lane.
/// A long press lifts a clip: it ticks, opens its menu, and moving dismisses the menu and drags the clip across lanes and
/// through time (lane 0 included). A selected clip has edge handles that trim it where it sits.
struct EditorPhoneEqualLanes: View {
    let session: EditSession
    @Binding var scale: TimelineScale
    let scrubber: TimelineScrubber
    let openAdd: () -> Void

    @Environment(EditorHost.self) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinchBase: CGFloat?
    @State private var lift: PhoneLift?
    @State private var scroll: CGFloat = 0
    @State private var scrollBase: CGFloat?
    @State private var axis: DragAxis?
    @State private var keepGap = false
    @State private var liftTick = 0
    @State private var laneTick = 0

    private enum DragAxis { case horizontal, vertical }

    static let headerWidth: CGFloat = 30
    private static let footer: CGFloat = 34
    private static let newLaneBand: CGFloat = 20
    private static let blockInset: CGFloat = 4

    private var laneCount: Int { LaneClipCommands.laneCount(session) }

    /// Lane 0, and any lane with a keyed clip or a large one (no frame of its own, or most of the picture's width).
    private var priority: [Bool] {
        (0..<laneCount).map { lane in
            lane == 0 || session.timeline.clips.contains { $0.lane == lane && ($0.key != nil || ($0.frame?.w ?? 1) >= 0.6) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let area = max(0, geo.size.height - Self.footer)
            let layout = TimelineLaneLayout(available: Double(area), priority: priority)
            board(width: geo.size.width, area: area, layout: layout)
                .onChange(of: layout.contentHeight - Double(area)) { _, _ in
                    scroll = min(max(0, CGFloat(layout.contentHeight) - area), scroll)
                }
                .onChange(of: scrubber.seconds) { _, _ in
                    if let current = lift, current.moved { lift = refresh(current, layout: layout, area: area) }
                }
        }
        .background(EditorColor.lane)
        .overlay(alignment: .top) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .haptic(.impact(weight: .medium), trigger: liftTick)
        .haptic(.selection, trigger: laneTick)
        .haptic(.impact(weight: .light), trigger: scrubber.tick)
        .laneRefusalToast(session)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.timelineA11y)
    }

    private func board(width: CGFloat, area: CGFloat, layout: TimelineLaneLayout) -> some View {
        let maxScroll = max(0, CGFloat(layout.contentHeight) - area)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    lift = nil
                    session.selection = .none
                }
                .accessibilityHidden(true)
            laneContent(width: width, layout: layout, area: area, maxScroll: maxScroll)
                .offset(y: -scroll)
                .frame(width: width, height: area, alignment: .topLeading)
                .clipped()   // only the lanes: the hold menu may open above the board, it is taller than one or two lanes
            snapGuide(area: area, width: width)
            playhead(width: width, area: area)
            headers(layout: layout, area: area)
            if lift?.moved == true, EditLaneDrop.canInsertLane(above: laneCount - 1, occupied: session.timeline.clips.map(\.lane)) {
                newLaneBand(width: width)
            }
            if let lift, lift.showMenu, !lift.moved, let clip = clip(lift.id) { menu(lift, clip, width: width, area: area, layout: layout) }
            footer(width: width, area: area)
        }
        .frame(width: width, height: area + Self.footer, alignment: .topLeading)
        .coordinateSpace(name: "phoneLanes")
        .contentShape(Rectangle())
        .gesture(scrub(maxScroll: maxScroll))
        .simultaneousGesture(touchDown)
        .simultaneousGesture(pinch)
    }

    // MARK: lanes

    private func laneContent(width: CGFloat, layout: TimelineLaneLayout, area: CGFloat, maxScroll: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach((0..<laneCount).reversed(), id: \.self) { lane in
                laneRow(lane, width: width, layout: layout, area: area, maxScroll: maxScroll)
            }
            if let lift, lift.moved { ghost(lift, width: width, layout: layout) }
            if let lift, lift.moved, let clip = clip(lift.id) { floating(lift, clip, layout: layout) }
        }
        .frame(width: width, height: CGFloat(layout.contentHeight), alignment: .topLeading)
    }

    private func laneRow(_ lane: Int, width: CGFloat, layout: TimelineLaneLayout, area: CGFloat, maxScroll: CGFloat) -> some View {
        let hot = lift?.moved == true && lift?.target == .lane(lane)
        let height = CGFloat(layout.heights[lane])
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(hot ? EditorColor.selection.opacity(0.16) : Color.clear)
                .overlay { if hot { Rectangle().strokeBorder(EditorColor.selection.opacity(0.85), lineWidth: 1) } }
                .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            ForEach(session.timeline.clips.filter { $0.lane == lane }) { clip in
                if let span = LaneClipCommands.span(session, clip.id) {
                    phoneClip(clip, span: span, width: width, rowHeight: height, layout: layout, area: area, maxScroll: maxScroll)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(y: CGFloat(layout.tops[lane]))
    }

    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        width / 2 + scale.x(seconds - scrubber.seconds)
    }

    @ViewBuilder
    private func phoneClip(
        _ clip: EditLaneClip, span: TimelineSpan, width: CGFloat, rowHeight: CGFloat, layout: TimelineLaneLayout, area: CGFloat,
        maxScroll: CGFloat
    ) -> some View {
        let home = x(span.start, width: width)
        let block = max(2, scale.x(span.length) - 2)
        if onScreen(home, block, width) || lift?.id == clip.id {
            PhoneEqualClip(
                session: session, scrubber: scrubber, clip: clip, span: span, scale: scale, width: width, blockWidth: block,
                blockHeight: rowHeight - 2 * Self.blockInset, lift: $lift, area: area, scroll: $scroll, maxScroll: maxScroll,
                keepGap: { keepGap }, refresh: { refresh($0, layout: layout, area: area) },
                onLift: { liftTick += 1 }, onLane: { laneTick += 1 })
                .offset(x: home + 1, y: Self.blockInset)
        }
    }

    private func onScreen(_ start: CGFloat, _ length: CGFloat, _ width: CGFloat) -> Bool {
        start + length > Self.headerWidth - 48 && start < width + 48
    }

    /// Where a lifted clip would land with the finger and the timeline where they are now: its start (snapped) and its lane.
    private func refresh(_ current: PhoneLift, layout: TimelineLaneLayout, area: CGFloat) -> PhoneLift {
        var next = current
        let raw = current.start + (scrubber.seconds - current.anchorPlayhead) + scale.seconds(at: current.point.x - current.anchorX)
        next.dropAt = EditLaneDrop.snap(
            start: raw, length: current.length, points: LaneClipCommands.snapPoints(session, except: current.id),
            threshold: 6 / Double(scale.pointsPerSecond)).value
        let band = EditLaneDrop.canInsertLane(above: laneCount - 1, occupied: session.timeline.clips.map(\.lane))
        if band, current.point.y < Self.newLaneBand {
            next.target = .newLane
        } else {
            next.target = .lane(layout.lane(atY: Double(current.point.y + scroll)))
        }
        return next
    }

    // MARK: lane headers and the footer

    /// A small icon and the lane's number; the first lane carries a film strip (it sets the length), the others a stack.
    private func headers(layout: TimelineLaneLayout, area: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<laneCount, id: \.self) { lane in
                header(lane)
                    .frame(width: Self.headerWidth, height: CGFloat(layout.heights[lane]))
                    .offset(y: CGFloat(layout.tops[lane]) - scroll)
            }
        }
        .frame(width: Self.headerWidth, height: area, alignment: .topLeading)
        .clipped()
        .background(EditorColor.lane.opacity(0.94))
        .overlay(alignment: .trailing) { Rectangle().fill(EditorColor.line).frame(width: 1) }
        .zIndex(6)
    }

    private func header(_ lane: Int) -> some View {
        let hot = lift?.moved == true && lift?.target == .lane(lane)
        return VStack(spacing: 2) {
            Image(systemName: lane == 0 ? "film" : "square.stack")
                .font(.system(size: 11, weight: .medium))
            Text("\(lane + 1)")
                .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                .monospacedDigit()
        }
        .foregroundStyle(hot ? EditorColor.selection : CobaltColor.caption)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Editor.laneTitle(lane))
    }

    /// The strip under the lanes: `+` in the header column adds a lane, `+` at the right adds a clip.
    private func footer(width: CGFloat, area: CGFloat) -> some View {
        let canAddLane = EditLaneDrop.canInsertLane(above: laneCount - 1, occupied: session.timeline.clips.map(\.lane))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(EditorColor.lane)
                .overlay(alignment: .top) { Rectangle().fill(EditorColor.line).frame(height: 1) }
            Button { host.ui.open(.addLayer, page: nil) } label: {
                Image(systemName: Symbol.Editor.add)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canAddLane ? CobaltColor.text : CobaltColor.caption)
                    .frame(width: Self.headerWidth, height: Self.footer)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAddLane)
            .accessibilityLabel(Copy.Editor.addLayer)
            Button(action: openAdd) {
                Image(systemName: Symbol.Editor.add)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.onText)
                    .frame(width: 30, height: 26)
                    .background(CobaltColor.text, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: Metrics.hit, height: Self.footer)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Editor.addClip)
            .offset(x: width - Metrics.hit - 4)
            if showsGap { gapChip }
        }
        .frame(width: width, height: Self.footer)
        .offset(y: area)
        .zIndex(8)
    }

    // MARK: menu, ghost, chrome

    private func menu(_ lift: PhoneLift, _ clip: EditLaneClip, width: CGFloat, area: CGFloat, layout: TimelineLaneLayout) -> some View {
        let items = LaneClipCommands.items(session, clip)
        let height = min(200, CGFloat(items.count) * 30 + 8)
        let clipX = x(lift.start, width: width)
        let clipY = CGFloat(layout.tops[min(clip.lane, layout.tops.count - 1)]) - scroll
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
        .environment(\.colorScheme, .dark)   // the menu is always black, so its text takes the dark palette (black in light mode before)
        // above the held clip, over the transport when the board is short, never over the clip itself
        .offset(x: min(max(Self.headerWidth + 6, clipX), width - 196), y: min(area - height, clipY - height - 4))
        .zIndex(30)
    }

    private func menuTitle(_ item: LaneMenuItem, hidden: Bool) -> String {
        let name = LaneClipCommands.title(item.action, hidden: hidden)
        guard let reason = item.reason else { return name }
        return "\(name) · \(reason)"
    }

    private func ghost(_ lift: PhoneLift, width: CGFloat, layout: TimelineLaneLayout) -> some View {
        let lane = lift.target.lane
        let y = lane.map { CGFloat(layout.tops[$0]) + Self.blockInset } ?? (scroll + 3)
        let h = lane.map { CGFloat(layout.heights[$0]) - 2 * Self.blockInset } ?? 14
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

    /// While a clip is held above the top lane, a dashed strip along the top says it would open a new lane. No words.
    private func newLaneBand(width: CGFloat) -> some View {
        let hot = lift?.target == .newLane
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(hot ? EditorColor.selection : CobaltColor.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .background(hot ? EditorColor.selection.opacity(0.2) : Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: width - Self.headerWidth - 12, height: Self.newLaneBand - 4)
            .offset(x: Self.headerWidth + 6, y: 2)
            .allowsHitTesting(false)
            .zIndex(12)
    }

    private var showsGap: Bool {
        if let lift, lift.fromLane == 0 { return true }
        if case .main = session.selection { return true }
        return false
    }

    private func floating(_ lift: PhoneLift, _ clip: EditLaneClip, layout: TimelineLaneLayout) -> some View {
        let height = CGFloat(layout.heights[min(lift.fromLane, layout.heights.count - 1)]) - 2 * Self.blockInset
        return TimelineLaneClipView(
            clip: clip, source: session.source(for: clip.item), seconds: lift.length,
            width: max(2, scale.x(lift.length) - 2), height: height, isSelected: true,
            showsEffect: session.showsEffect(id: clip.id))
            .scaleEffect(reduceMotion ? 1 : 1.05)
            .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
            .position(x: lift.point.x, y: lift.point.y + scroll)
            .allowsHitTesting(false)
            .zIndex(20)
    }

    /// Whether moving or removing a lane-0 clip leaves its gap behind. It lives in the footer, beside the lane `+`, so it never
    /// covers a clip's label; it shows while lane 0's clip is selected or lifted (the only time the choice applies).
    private var gapChip: some View {
        Button { keepGap.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(Copy.Editor.keepGap)
                    .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                    .lineLimit(1)
            }
            .foregroundStyle(keepGap ? Color.black : CobaltColor.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(keepGap ? Color.white : Color.black.opacity(0.55), in: Capsule())
            .overlay { Capsule().strokeBorder(CobaltColor.border, lineWidth: keepGap ? 0 : 1) }
            .frame(minHeight: Self.footer)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Editor.keepGap)
        .accessibilityAddTraits(keepGap ? .isSelected : [])
        .offset(x: Self.headerWidth + 8)
    }

    /// The fixed playhead. It fades while a trim handle is held: the picture is on the edge, the timeline stays under the finger.
    private func playhead(width: CGFloat, area: CGFloat) -> some View {
        TimelinePlayhead(height: area, color: .white, showsHead: false)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .offset(x: width / 2 - TimelinePlayhead.headWidth / 2)
            .opacity(scrubber.trimming ? 0.3 : 1)
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

    /// Where a trimmed edge snapped to: a thin line down the lanes while the finger is on the handle.
    @ViewBuilder
    private func snapGuide(area: CGFloat, width: CGFloat) -> some View {
        if let point = scrubber.snapGuide {
            Rectangle()
                .fill(.white.opacity(0.75))
                .frame(width: 1, height: area)
                .offset(x: x(point, width: width) - 0.5)
                .allowsHitTesting(false)
                .zIndex(5)
        }
    }

    // MARK: scrub, scroll, pinch

    /// One finger: sideways scrubs the time under the playhead (and flings on release), up and down scrolls the lanes when
    /// they are taller than the slot. The first move picks the direction and it stays picked until the finger lifts.
    private func scrub(maxScroll: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard lift == nil else { return }
                if axis == nil {
                    if abs(value.translation.width) >= abs(value.translation.height) {
                        axis = .horizontal
                        scrubber.beginDrag()
                    } else if maxScroll > 0 {
                        axis = .vertical
                        scrollBase = scroll
                    } else {
                        return
                    }
                }
                switch axis {
                case .horizontal?:
                    scrubber.drag(translation: value.translation.width, pointsPerSecond: scale.pointsPerSecond)
                case .vertical?:
                    scroll = min(maxScroll, max(0, (scrollBase ?? 0) - value.translation.height))
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer {
                    axis = nil
                    scrollBase = nil
                }
                guard axis == .horizontal else { return }
                scrubber.endDrag(velocity: value.velocity.width, pointsPerSecond: scale.pointsPerSecond, fling: !reduceMotion)
            }
    }

    /// A finger landing stops a fling.
    private var touchDown: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in scrubber.touchDown() }
    }

    /// Pinch zooms about the playhead: the playhead is the middle of the timeline, so the moment under it stays put. Bounded by
    /// `TimelineScale`; the zoom lives in `EditorUI`, so it survives a fold, an unfold and a turn.
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
}

/// A long press that has not become a drag yet, or the drag in progress. `anchorPlayhead` is the timeline's time when the drag
/// began (the name is older than the scrubber), `anchorX` the finger's x then.
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
    let scrubber: TimelineScrubber
    let clip: EditLaneClip
    let span: TimelineSpan
    let scale: TimelineScale
    let width: CGFloat
    let blockWidth: CGFloat
    let blockHeight: CGFloat
    @Binding var lift: PhoneLift?
    let area: CGFloat
    @Binding var scroll: CGFloat
    let maxScroll: CGFloat
    let keepGap: () -> Bool
    /// The lift with its drop time and lane worked out for where the finger and the timeline are now.
    let refresh: (PhoneLift) -> PhoneLift
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
                clip: clip, source: source, seconds: span.length, width: blockWidth, height: blockHeight,
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
            if selected, lift?.id != clip.id {
                EditorPhoneEdgeHandles(
                    session: session, scrubber: scrubber, clip: clip, scale: scale, width: blockWidth, height: blockHeight,
                    video: source?.kind == .video)
            }
        }
        .frame(width: blockWidth, height: blockHeight, alignment: .topLeading)
        .gesture(hold)
        .highPriorityGesture(
            TapGesture().onEnded {
                LaneClipCommands.select(session, clip)
                if session.sourceFailures[clip.item] != nil { session.retrySource(clip.item) }
            })
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("phoneLanes")))
            .onChanged { value in
                switch value {
                case .second(true, nil):
                    begin()
                case .second(true, let drag?):
                    update(drag)
                default:
                    break
                }
            }
            .onEnded { _ in
                scrubber.autoscroll(speed: 0)
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
            id: clip.id, fromLane: clip.lane, start: span.start, length: span.length, anchorPlayhead: scrubber.seconds,
            anchorX: 0, anchored: false, moved: false, showMenu: true, point: .zero, target: .lane(clip.lane), dropAt: span.start)
        onLift()
    }

    private func update(_ drag: DragGesture.Value) {
        guard var current = lift, current.id == clip.id else { return }
        if !current.anchored {
            current.anchored = true
            current.anchorX = drag.startLocation.x
            current.anchorPlayhead = scrubber.seconds
        }
        let distance = hypot(drag.translation.width, drag.translation.height)
        if distance > 8 {
            if !current.moved { current.showMenu = false }
            current.moved = true
        }
        if current.moved {
            // near a side the timeline keeps scrolling even when the finger rests (a fast edge at close range)
            // (160 points a second at full push, whatever the zoom)
            let side = edgePush(position: Double(drag.location.x), viewport: Double(width), edge: 40)
            scrubber.autoscroll(speed: side * 160 / Double(scale.pointsPerSecond))
            let vertical = edgePush(position: Double(drag.location.y), viewport: Double(area), edge: 28) * 6
            if vertical != 0 { scroll = min(maxScroll, max(0, scroll + CGFloat(vertical))) }
        }
        let before = current.target
        current.point = drag.location
        current = refresh(current)
        if current.moved, current.target != before { onLane() }
        lift = current
    }
}

/// 0 in the middle of the board, rising to ±1 as a finger gets to `edge` points from a side (negative = the near side).
private func edgePush(position: Double, viewport: Double, edge: Double) -> Double {
    guard viewport > 0, edge > 0, position.isFinite, viewport.isFinite else { return 0 }
    if position < edge { return -min(1, (edge - position) / edge + 0.2) }
    if position > viewport - edge { return min(1, (position - (viewport - edge)) / edge + 0.2) }
    return 0
}
#endif
