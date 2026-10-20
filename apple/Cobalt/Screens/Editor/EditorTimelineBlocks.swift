import CobaltKit
import SwiftUI

// The Mac and iPad timeline's blocks: the shared drawing views (Shared/TimelineClipViews.swift) with the pointer's gestures on
// them: select, blade, drag to reorder or to move in time, trim handles. The lanes (EditorTimelinePane) place them.

/// A main clip being dragged to a new place: its distance so far and the index it would take.
struct ReorderDrag: Equatable {
    var id: String
    var translation: CGFloat
    var target: Int
}

// MARK: - a main clip

struct MainClipBlock: View {
    let session: EditSession
    let index: Int
    let clip: EditClip
    let span: TimelineSpan
    let scale: TimelineScale
    let laneHeight: CGFloat
    @Binding var reorder: ReorderDrag?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapTick = 0

    private var blockHeight: CGFloat { max(20, laneHeight - 12) }
    private var width: CGFloat { max(2, scale.x(span.length) - 2) }
    private var selected: Bool { session.selection == .main(clip.id) }
    private var dragging: Bool { reorder?.id == clip.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineMainClipView(
                clip: clip, number: index + 1, source: session.source(for: clip.item), seconds: span.length,
                width: width, height: blockHeight, isSelected: selected,
                loading: session.loadingSources[clip.item],
                failed: session.sourceFailures[clip.item] != nil, missing: session.isMissing(item: clip.item),
                actions: actions)
            if selected, !dragging, session.tool != .blade {
                MainTrimHandles(session: session, index: index, clip: clip, scale: scale, width: width, height: blockHeight)
            }
        }
        .frame(width: width, height: blockHeight, alignment: .topLeading)
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 8, y: 3)
        .opacity(dragging ? 0.92 : 1)
        .offset(x: scale.x(span.start) + 1 + (dragging ? (reorder?.translation ?? 0) : 0), y: 6)
        .zIndex(dragging ? 5 : (selected ? 2 : 1))
        .gesture(tap)
        .gesture(drag)
        .haptic(.impact(weight: .light), trigger: snapTick)
    }

    // MARK: gestures

    private var tap: some Gesture {
        SpatialTapGesture().onEnded { value in
            if session.tool == .blade {
                let seconds = span.start + scale.seconds(at: value.location.x)
                let frame = EditMath.roundHalfUp(seconds * Double(session.timing.fps))
                session.split(clip: clip.id, atFrame: frame)
                snapTick += 1
            } else {
                session.selection = .main(clip.id)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                guard session.tool == .select else { return }
                if session.selection != .main(clip.id) { session.selection = .main(clip.id) }
                reorder = ReorderDrag(id: clip.id, translation: value.translation.width, target: target(for: value.translation.width))
            }
            .onEnded { value in
                guard session.tool == .select else { return }
                let to = target(for: value.translation.width)
                reorder = nil
                guard to != index else { return }
                withAnimation(reduceMotion ? Motion.fade : Motion.rows) { session.move(clip: clip.id, to: to) }
            }
    }

    /// The index the clip takes when dropped here: how many of the others lie wholly to its left, by their middles.
    private func target(for translation: CGFloat) -> Int {
        let center = scale.x(span.start) + width / 2 + translation
        return session.mainSpans.filter { $0.id != clip.id }.filter { scale.x($0.start + $0.length / 2) < center }.count
    }

    // MARK: accessibility

    private var actions: TimelineClipActions {
        TimelineClipActions(
            select: { session.selection = .main(clip.id) },
            moveEarlier: index > 0 ? { session.move(clip: clip.id, to: index - 1) } : nil,
            moveLater: index < session.timeline.main.count - 1 ? { session.move(clip: clip.id, to: index + 1) } : nil,
            split: { session.split(clip: clip.id, atFrame: session.playhead) },
            delete: { session.remove(.main(clip.id)) },
            trim: { session.selection = .main(clip.id) })
    }
}

/// The blue handles at both ends of the selected main clip. A drag changes the source `in` or `out` by the distance dragged
/// times the clip's speed; the preview shows the edge frame while it goes (the playhead sits on that edge).
struct MainTrimHandles: View {
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
            TimelineTrimHandle(
                edge: .leading, height: height, valueText: Copy.Editor.clockTenths(clip.in),
                onDrag: { dx in
                    let b = capture()
                    session.trim(clip: clip.id, in: b.inPoint + Double(dx / scale.pointsPerSecond) * speed, out: nil)
                    showEdge(atEnd: false)
                },
                onEnd: finish,
                step: { n in
                    session.trim(clip: clip.id, in: clip.in + Double(n) * speed / Double(session.timing.fps), out: nil)
                    session.endGesture()
                })
            TimelineTrimHandle(
                edge: .trailing, height: height, valueText: Copy.Editor.clockTenths(clip.out),
                onDrag: { dx in
                    let b = capture()
                    session.trim(clip: clip.id, in: nil, out: b.outPoint + Double(dx / scale.pointsPerSecond) * speed)
                    showEdge(atEnd: true)
                },
                onEnd: finish,
                step: { n in
                    session.trim(clip: clip.id, in: nil, out: clip.out + Double(n) * speed / Double(session.timing.fps))
                    session.endGesture()
                })
                .offset(x: width - TimelineTrimHandle.hitWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func capture() -> (inPoint: Double, outPoint: Double) {
        if let base { return base }
        let b = (inPoint: clip.in, outPoint: clip.out)
        base = b
        return b
    }

    private func finish() {
        base = nil
        session.endGesture()
    }

    /// The playhead on the edge being trimmed, so the preview shows that frame.
    private func showEdge(atEnd: Bool) {
        guard session.timing.main.indices.contains(index) else { return }
        let slot = session.timing.main[index]
        session.seek(frame: atEnd ? slot.start + slot.frames - 1 : slot.start)
    }
}

// MARK: - an overlay

struct OverlayClipBlock: View {
    let session: EditSession
    let index: Int
    let overlay: EditOverlay
    let span: TimelineSpan
    let scale: TimelineScale
    let laneHeight: CGFloat
    /// Moves a start (and its length) to the nearest edge or the playhead within 6 pt; reports whether it snapped.
    let snap: (_ start: Double, _ length: Double, _ id: String) -> (value: Double, snapped: Bool)

    @State private var baseFrame: Int?
    @State private var baseLength: Double?
    @State private var baseIn: Double?
    @State private var snapTick = 0
    @State private var wasSnapped = false

    private var blockHeight: CGFloat { max(20, laneHeight - 12) }
    private var width: CGFloat { max(2, scale.x(span.length) - 2) }
    private var selected: Bool { session.selection == .overlay(overlay.id) }
    private var source: EditSource? { session.source(for: overlay.item) }
    private var fps: Double { Double(session.timing.fps) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineOverlayClipView(
                overlay: overlay, source: source, seconds: span.length, width: width, height: blockHeight,
                isSelected: selected, missing: session.isMissing(item: overlay.item), actions: actions)
            if selected {
                if source?.kind == .video { leadingHandle }
                trailingHandle
            }
        }
        .frame(width: width, height: blockHeight, alignment: .topLeading)
        .offset(x: scale.x(span.start) + 1, y: 6)
        .zIndex(selected ? 2 : 1)
        .gesture(SpatialTapGesture().onEnded { _ in session.selection = .overlay(overlay.id) })
        .gesture(move)
        .haptic(.impact(weight: .light), trigger: snapTick)
    }

    // MARK: move in time

    private var move: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                guard session.tool == .select, !isHandleDrag else { return }
                if session.selection != .overlay(overlay.id) { session.selection = .overlay(overlay.id) }
                let startFrame = baseFrame ?? currentStartFrame
                baseFrame = startFrame
                let raw = Double(startFrame) / fps + Double(value.translation.width / scale.pointsPerSecond)
                let result = snap(max(0, raw), span.length, overlay.id)
                if result.snapped && !wasSnapped { snapTick += 1 }
                wasSnapped = result.snapped
                session.moveOverlay(id: overlay.id, toFrame: EditMath.roundHalfUp(result.value * fps))
            }
            .onEnded { _ in
                baseFrame = nil
                wasSnapped = false
                session.endGesture()
            }
    }

    private var isHandleDrag: Bool { baseLength != nil || baseIn != nil }

    private var currentStartFrame: Int {
        session.timing.overlay.indices.contains(index) ? session.timing.overlay[index].start : EditMath.roundHalfUp(overlay.at * fps)
    }

    // MARK: handles

    /// The right edge: how long the overlay stays up.
    private var trailingHandle: some View {
        TimelineTrimHandle(
            edge: .trailing, height: blockHeight, valueText: Copy.Editor.clockTenths(overlay.length), color: EditorColor.overlay,
            onDrag: { dx in
                let base = baseLength ?? overlay.length
                baseLength = base
                session.setOverlayLength(id: overlay.id, seconds: base + Double(dx / scale.pointsPerSecond))
            },
            onEnd: {
                baseLength = nil
                session.endGesture()
            },
            step: { n in
                session.setOverlayLength(id: overlay.id, seconds: overlay.length + Double(n) / fps)
                session.endGesture()
            })
            .offset(x: width - TimelineTrimHandle.hitWidth)
    }

    /// The left edge of a video overlay: where in the video it starts (its place on the timeline stays).
    private var leadingHandle: some View {
        TimelineTrimHandle(
            edge: .leading, height: blockHeight, valueText: Copy.Editor.clockTenths(overlay.in), color: EditorColor.overlay,
            onDrag: { dx in
                let base = baseIn ?? overlay.in
                baseIn = base
                session.trimOverlay(id: overlay.id, in: base + Double(dx / scale.pointsPerSecond), out: nil)
            },
            onEnd: {
                baseIn = nil
                session.endGesture()
            },
            step: { n in
                session.trimOverlay(id: overlay.id, in: overlay.in + Double(n) / fps, out: nil)
                session.endGesture()
            })
    }

    private var actions: TimelineClipActions {
        TimelineClipActions(
            select: { session.selection = .overlay(overlay.id) },
            delete: { session.remove(.overlay(overlay.id)) },
            trim: { session.selection = .overlay(overlay.id) })
    }
}
