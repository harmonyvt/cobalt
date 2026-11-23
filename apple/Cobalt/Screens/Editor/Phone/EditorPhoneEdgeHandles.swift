#if os(iOS)
import CobaltKit
import SwiftUI

/// The handles at both ends of a selected clip on the equal-lane timeline (CONTRACT-EDITOR 15.5). Drag one to trim the clip where
/// it sits: the timeline stays under the finger (`TimelineScrubber.beginTrim`), the picture shows the frame at that edge
/// (coalesced seeks, exact when the finger lifts), and the end of the clip snaps to the playhead as it was when the drag began,
/// to the edges of the other clips, to 0 and to the end of the edit, with a light tick and a guide line.
///
/// Lane 0: the right handle is the clip's out point, the left its in point (the clip keeps its start; the lane closes up).
/// Higher lanes: the right handle is how long it stays up and, for a video, the left is where in the video it starts.
struct EditorPhoneEdgeHandles: View {
    let session: EditSession
    let scrubber: TimelineScrubber
    let clip: EditLaneClip
    let scale: TimelineScale
    let width: CGFloat
    let height: CGFloat
    let video: Bool

    /// What the clip was when the drag began, so the finger's distance is measured from there however the clip changes.
    private struct Start {
        var inPoint: Double
        var outPoint: Double
        /// Where the clip's end sits on the output, in seconds.
        var end: Double
        var points: [Double]
    }

    @State private var start: Start?

    private var mainIndex: Int? {
        clip.lane == 0 ? session.timeline.main.firstIndex(where: { $0.id == clip.id }) : nil
    }
    private var overlay: EditOverlay? { session.timeline.overlay.first { $0.id == clip.id } }
    private var fps: Double { Double(max(1, session.timing.fps)) }
    private var leading: Bool { mainIndex != nil || video }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if leading {
                EditorPhoneHitZone(height: height, onDrag: { drag(trailing: false, $0) }, onEnd: { finish(trailing: false) })
                    .offset(x: -10)
                TimelineTrimHandle(
                    edge: .leading, height: height, valueText: Copy.Editor.clockTenths(inPoint), color: EditorColor.selection,
                    onDrag: { drag(trailing: false, $0) }, onEnd: { finish(trailing: false) },
                    step: { nudge(trailing: false, frames: $0) })
            }
            EditorPhoneHitZone(height: height, onDrag: { drag(trailing: true, $0) }, onEnd: { finish(trailing: true) })
                .offset(x: width - Metrics.hit + 10)
            TimelineTrimHandle(
                edge: .trailing, height: height, valueText: Copy.Editor.clockTenths(outPoint), color: EditorColor.selection,
                onDrag: { drag(trailing: true, $0) }, onEnd: { finish(trailing: true) },
                step: { nudge(trailing: true, frames: $0) })
                .offset(x: width - TimelineTrimHandle.hitWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    // MARK: the clip's numbers

    private var inPoint: Double {
        if let index = mainIndex { return session.timeline.main[index].in }
        return overlay?.in ?? 0
    }

    private var outPoint: Double {
        if let index = mainIndex { return session.timeline.main[index].out }
        return overlay?.out ?? 0
    }

    /// Source seconds a second of output covers.
    private var speed: Double {
        guard let index = mainIndex else { return 1 }
        return session.timing.main.indices.contains(index) ? session.timing.main[index].speed : session.timeline.main[index].speed
    }

    /// The clip's first and one-past-last output frames.
    private var slot: (start: Int, frames: Int)? {
        if let index = mainIndex, session.timing.main.indices.contains(index) {
            return (session.timing.main[index].start, session.timing.main[index].frames)
        }
        if let row = session.timing.laneClips.first(where: { $0.id == clip.id }) { return (row.start, row.frames) }
        return nil
    }

    /// The frame the picture shows for the edge being dragged: the clip's first frame, or its last.
    private func edgeFrame(trailing: Bool) -> Int {
        guard let slot else { return session.playhead }
        return trailing ? slot.start + slot.frames - 1 : slot.start
    }

    // MARK: dragging

    private func begin() -> Start {
        if let start { return start }
        scrubber.beginTrim()
        let end = slot.map { session.timing.time(ofFrame: $0.start + $0.frames) } ?? 0
        let first = Start(
            inPoint: inPoint, outPoint: outPoint, end: end, points: LaneClipCommands.snapPoints(session, except: clip.id))
        start = first
        return first
    }

    /// `dx` is how far the finger has gone since it touched the handle (positive = right).
    private func drag(trailing: Bool, _ dx: CGFloat) {
        let first = begin()
        // the clip's end moves with the right handle, and the other way with the left one (the in point goes up, the clip shortens)
        let wanted = (trailing ? 1.0 : -1.0) * Double(dx / scale.pointsPerSecond)
        let snapped = TimelineTrimSnap.snap(end: first.end, delta: wanted, points: first.points, threshold: 6 / Double(scale.pointsPerSecond))
        apply(trailing: trailing, from: first, endMoved: snapped.delta)
        scrubber.trimMoved(toFrame: edgeFrame(trailing: trailing), snap: snapped.point)
    }

    private func apply(trailing: Bool, from first: Start, endMoved: Double) {
        if mainIndex != nil {
            if trailing {
                session.trim(clip: clip.id, in: nil, out: first.outPoint + endMoved * speed)
            } else {
                session.trim(clip: clip.id, in: first.inPoint - endMoved * speed, out: nil)
            }
        } else if trailing {
            session.setOverlayLength(id: clip.id, seconds: (first.outPoint - first.inPoint) + endMoved)
        } else {
            session.trimOverlay(id: clip.id, in: first.inPoint - endMoved, out: nil)
        }
    }

    private func finish(trailing: Bool) {
        guard start != nil else { return }
        start = nil
        session.endGesture()
        scrubber.endTrim(settleAt: edgeFrame(trailing: trailing))
    }

    /// VoiceOver: one frame at a time.
    private func nudge(trailing: Bool, frames: Int) {
        let seconds = Double(frames) / fps
        if mainIndex != nil {
            if trailing { session.trim(clip: clip.id, in: nil, out: outPoint + seconds * speed) }
            else { session.trim(clip: clip.id, in: inPoint + seconds * speed, out: nil) }
        } else if trailing {
            session.setOverlayLength(id: clip.id, seconds: (outPoint - inPoint) + seconds)
        } else {
            session.trimOverlay(id: clip.id, in: inPoint + seconds, out: nil)
        }
        session.endGesture()
    }
}
#endif
