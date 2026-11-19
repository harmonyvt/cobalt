import CobaltKit
import SwiftUI

// The equal-lane menu, the drop, and the VoiceOver actions. Both timelines call this so a row does the same thing
// on the Mac and on the iPhone. The geometry lives in `EditLaneDrop`; the dimmed reasons live in `EditLaneMenu`.

/// The clip whose cut-out sheet is up. `sheet(item:)` needs an `Identifiable` value.
struct CutoutRequest: Identifiable, Equatable {
    var id: String
}

struct LaneDrag: Equatable {
    var id: String
    var fromLane: Int
    var start: Double
    var length: Double
    /// Seconds from the clip's start to the pointer, so the clip stays under the finger.
    var grab: Double
    var point: CGPoint
    var target: LaneDropTarget
    var drop: Double
    var snapped: Bool
    var moved: Bool
}

enum LaneClipCommands {
    static func laneCount(_ session: EditSession) -> Int {
        max(1, (session.timeline.clips.map(\.lane).max() ?? 0) + 1)
    }

    static func span(_ session: EditSession, _ id: String) -> TimelineSpan? {
        guard let row = session.timing.laneClips.first(where: { $0.id == id }) else { return nil }
        let fps = Double(max(1, session.timing.fps))
        return TimelineSpan(id: id, start: session.timing.time(ofFrame: row.start), length: Double(row.frames) / fps)
    }

    static func select(_ session: EditSession, _ clip: EditLaneClip) {
        if clip.lane == 0 { session.selection = .main(clip.id) }
        else { session.selection = .overlay(clip.id) }
    }

    static func selected(_ session: EditSession, _ id: String) -> Bool {
        switch session.selection {
        case .main(let selected), .overlay(let selected): return selected == id
        case .none: return false
        }
    }

    /// A photo or gif the cut-out sheet can open. Nil for a video (that one uses effects).
    static func picture(_ session: EditSession, _ id: String) -> EditSource? {
        guard let item = session.timeline.clips.first(where: { $0.id == id })?.item ?? session.timeline.overlay.first(where: { $0.id == id })?.item,
              let source = session.source(for: item), source.kind == .photo || source.kind == .gif else { return nil }
        return source
    }

    /// The video the effects tool should open: the selection, else the clip under the playhead, else the first video.
    static func videoClipID(_ session: EditSession) -> String? {
        let selected: String? = switch session.selection {
        case .main(let id), .overlay(let id): id
        case .none: nil
        }
        if let selected, isVideo(session, selected) { return selected }
        if let under = videoUnderPlayhead(session) { return under }
        if session.timeline.isV2 {
            return session.timeline.clips.first { isVideo(session, $0.id) }?.id
        }
        return session.timeline.overlay.first { session.source(for: $0.item)?.kind == .video }?.id
    }

    static func containsPlayhead(_ session: EditSession, _ id: String) -> Bool {
        guard let row = row(session, id) else { return false }
        return session.playhead > row.start && session.playhead < row.start + row.frames
    }

    static func title(_ action: LaneMenuAction, hidden: Bool) -> String {
        switch action {
        case .effect: return Copy.Editor.applyEffect
        case .cutout: return Copy.Editor.cutOutOrKey
        case .split: return Copy.Editor.splitAtPlayhead
        case .duplicate: return Copy.Editor.duplicateClip
        case .hide: return hidden ? Copy.Editor.showThisClip : Copy.Editor.hideThisClip
        case .newLane: return Copy.Editor.moveToNewLane
        case .layerUp: return Copy.Editor.layerUp
        case .layerDown: return Copy.Editor.layerDown
        case .delete: return Copy.Editor.deleteClipShort
        }
    }

    static func menuInput(_ session: EditSession, _ clip: EditLaneClip) -> LaneMenuInput {
        let count = laneCount(session)
        let occupied = session.timeline.clips.map(\.lane)
        let mine = row(session, clip.id)
        return LaneMenuInput(
            savesV2: session.savesTimelineV2,
            lane: clip.lane,
            fromLocked: session.isLaneLocked(clip.lane),
            upInRange: clip.lane + 1 < EditLanes.laneLimit,
            downInRange: clip.lane > 0,
            upLocked: clip.lane + 1 < EditLanes.laneLimit && session.isLaneLocked(clip.lane + 1),
            downLocked: clip.lane > 0 && session.isLaneLocked(clip.lane - 1),
            upTaken: taken(session, lane: clip.lane + 1, mine: mine, except: clip.id),
            downTaken: clip.lane > 0 && taken(session, lane: clip.lane - 1, mine: mine, except: clip.id),
            canNewLane: EditLaneDrop.canInsertLane(above: count - 1, occupied: occupied),
            duplicateBlocked: duplicateBlocked(session, clip, mine: mine, occupied: occupied),
            isVideo: session.source(for: clip.item)?.kind == .video,
            isPicture: picture(session, clip.id) != nil,
            playheadInside: playheadSplits(session, clip))
    }

    static func items(_ session: EditSession, _ clip: EditLaneClip) -> [LaneMenuItem] {
        EditLaneMenu.items(menuInput(session, clip))
    }

    /// Nil when the action ran. A string is the reason it could not, for the toast.
    @discardableResult
    static func run(_ action: LaneMenuAction, session: EditSession, clip: EditLaneClip, keepGap: Bool) -> String? {
        let rows = items(session, clip)
        if let row = rows.first(where: { $0.action == action }), !row.enabled { return row.reason }
        switch action {
        case .effect:
            session.openEffects(clip.id)
        case .cutout:
            if session.source(for: clip.item)?.kind == .video { session.openEffects(clip.id) }
            else { session.cutoutFor = clip.id }
        case .split:
            session.split(clip: clip.id, atFrame: session.playhead)
        case .duplicate:
            session.duplicateClip(id: clip.id)
        case .hide:
            session.setClipHidden(id: clip.id, !clip.hidden)
        case .newLane:
            session.moveClipToNewLane(id: clip.id, above: laneCount(session) - 1, at: clip.at, keepGap: keepGap)
        case .layerUp:
            session.moveClipLayer(id: clip.id, by: 1)
        case .layerDown:
            session.moveClipLayer(id: clip.id, by: -1)
        case .delete:
            session.remove(clip.lane == 0 ? .main(clip.id) : .overlay(clip.id))
        }
        return nil
    }

    static func drop(_ session: EditSession, id: String, target: LaneDropTarget, at: Double, keepGap: Bool) {
        switch target {
        case .newLane:
            session.moveClipToNewLane(id: id, above: laneCount(session) - 1, at: at, keepGap: keepGap)
        case .lane(let lane):
            session.moveClip(id: id, toLane: lane, at: at, keepGap: keepGap)
        }
    }

    static func moveToLane(_ session: EditSession, _ clip: EditLaneClip, lane: Int, keepGap: Bool) {
        session.moveClip(id: clip.id, toLane: lane, at: clip.at, keepGap: keepGap)
    }

    static func actions(_ session: EditSession, _ clip: EditLaneClip, run: @escaping (LaneMenuAction) -> Void) -> TimelineClipActions {
        let rows = items(session, clip)
        func go(_ action: LaneMenuAction) -> (() -> Void)? {
            guard let row = rows.first(where: { $0.action == action }), row.enabled else { return nil }
            return { run(action) }
        }
        var extra: [(name: String, run: () -> Void)] = []
        for row in rows where !row.enabled {
            let name = [title(row.action, hidden: clip.hidden), row.reason].compactMap { $0 }.joined(separator: ", ")
            extra.append((name, { run(row.action) }))
        }
        let locked = Set((0..<laneCount(session)).filter { session.isLaneLocked($0) })
        for lane in EditLaneMenu.moveLanes(from: clip.lane, count: laneCount(session), locked: locked, savesV2: session.savesTimelineV2) {
            extra.append((Copy.Editor.moveToLane(lane), { moveToLane(session, clip, lane: lane, keepGap: false) }))
        }
        return TimelineClipActions(
            select: { select(session, clip) },
            split: go(.split),
            delete: go(.delete),
            trim: { select(session, clip) },
            effect: go(.effect),
            cutout: go(.cutout),
            duplicateClip: go(.duplicate),
            hide: go(.hide),
            hideTitle: title(.hide, hidden: clip.hidden),
            newLane: go(.newLane),
            extra: extra)
    }

    static func snapPoints(_ session: EditSession, except id: String) -> [Double] {
        var points = [0.0, session.timing.seconds, session.playheadSeconds]
        for clip in session.timeline.clips where clip.id != id {
            guard let span = span(session, clip.id) else { continue }
            points.append(span.start)
            points.append(span.end)
        }
        return points
    }

    // MARK: facts

    private static func row(_ session: EditSession, _ id: String) -> EditTiming.Clip? {
        session.timing.laneClips.first { $0.id == id }
    }

    private static func isVideo(_ session: EditSession, _ id: String) -> Bool {
        let item = session.timeline.clips.first { $0.id == id }?.item ?? session.timeline.main.first { $0.id == id }?.item
            ?? session.timeline.overlay.first { $0.id == id }?.item
        return session.source(for: item ?? "")?.kind == .video
    }

    private static func videoUnderPlayhead(_ session: EditSession) -> String? {
        guard session.timeline.isV2 else { return nil }
        for index in EditLanes.drawOrder(session.timeline).reversed() {
            guard index < session.timeline.clips.count, index < session.timing.laneClips.count else { continue }
            let clip = session.timeline.clips[index]
            let row = session.timing.laneClips[index]
            guard row.id == clip.id, session.playhead >= row.start, session.playhead < row.start + row.frames else { continue }
            if session.source(for: clip.item)?.kind == .video { return clip.id }
        }
        return nil
    }

    /// Far enough from either edge that a split leaves two clips (the op's 0.1 s).
    private static func playheadSplits(_ session: EditSession, _ clip: EditLaneClip) -> Bool {
        guard let row = row(session, clip.id) else { return false }
        let margin = max(1, Int((0.1 * max(1, clip.speed) * Double(max(1, session.timing.fps))).rounded(.up)))
        return session.playhead >= row.start + margin && session.playhead <= row.start + row.frames - margin
    }

    private static func taken(_ session: EditSession, lane: Int, mine: EditTiming.Clip?, except id: String) -> Bool {
        guard let mine else { return false }
        let end = mine.start + mine.frames
        for other in session.timeline.clips where other.lane == lane && other.id != id {
            guard let row = row(session, other.id) else { continue }
            if mine.start < row.start + row.frames && row.start < end { return true }
        }
        return false
    }

    private static func duplicateBlocked(
        _ session: EditSession, _ clip: EditLaneClip, mine: EditTiming.Clip?, occupied: [Int]
    ) -> Bool {
        guard let mine else { return false }
        let start = mine.start + mine.frames
        let end = start + mine.frames
        let overlaps = session.timeline.clips.contains { other in
            guard other.lane == clip.lane, other.id != clip.id, let row = row(session, other.id) else { return false }
            return start < row.start + row.frames && row.start < end
        }
        return overlaps && !EditLaneDrop.canInsertLane(above: clip.lane, occupied: occupied)
    }
}

/// Toasts `laneRefusal` whenever a drop or a menu action is refused, including the same line twice.
struct LaneRefusalToast: ViewModifier {
    let session: EditSession
    @Environment(EditorHost.self) private var host

    func body(content: Content) -> some View {
        content.onChange(of: session.laneRefusalNonce) { _, _ in
            if let message = session.laneRefusal { host.show(message, seconds: 2.4) }
        }
    }
}

extension View {
    func laneRefusalToast(_ session: EditSession) -> some View {
        modifier(LaneRefusalToast(session: session))
    }
}
