import Foundation

// Remove green (apple/CONTRACT-EDITOR.md 15.4): one tap on a selected clip sets its `key` to the green preset and, when
// other clips sit above it in time, lifts it above them so the green hole shows what is under it straight away.
//
// Written against the session's public edits only (`applyGreenscreen`, `moveClip`), because `EditSession.swift` is shared
// and was not touched. Those are two commits, so a lift is two undo steps (the key, then the move) instead of the
// contract's one. Making `EditSession.commit(key:_:)` internal lets this body become a single
// `commit(key: nil) { $0 = next }` with both changes in it; nothing else here would change.

extension EditSession {
    /// The lane `removeGreen` lifts a clip to, or nil when it stays where it is: the lowest lane above every visible clip
    /// that overlaps it in time on a higher lane, with no clip of its own overlapping the clip's time range there, and not
    /// locked. A hidden clip is not drawn, so it does not count as "above". Nil too when no such lane is left below the
    /// 64-lane ceiling.
    static func greenLane(for clip: EditLaneClip, in timeline: EditTimeline, locked: Set<Int>) -> Int? {
        let fps = max(1, timeline.canvas.fps)
        let start = EditLanes.startFrame(clip.at, fps: fps)
        let end = start + EditLanes.outputFrames(clip, fps: fps)
        func overlaps(_ other: EditLaneClip) -> Bool {
            let otherStart = EditLanes.startFrame(other.at, fps: fps)
            let otherEnd = otherStart + EditLanes.outputFrames(other, fps: fps)
            return start < otherEnd && otherStart < end
        }
        let others = timeline.clips.filter { $0.id != clip.id && overlaps($0) }
        guard let top = others.filter({ $0.lane > clip.lane && !$0.hidden }).map(\.lane).max() else { return nil }
        let taken = Set(others.map(\.lane))
        var lane = top + 1
        while lane < EditLanes.laneLimit {
            if !taken.contains(lane), !locked.contains(lane) { return lane }
            lane += 1
        }
        return nil
    }

    /// The tool is useful: the clip is a video (or a file not known yet) that can take a key and is not on a locked lane.
    /// A main clip of a version 1 project cannot (a `key` lives on overlays there), nor one on a server that saves only that.
    public func canRemoveGreen(clipID: String) -> Bool {
        if timeline.isV2 {
            guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }) else { return false }
            let clip = timeline.clips[index]
            guard !lockedLanes.contains(clip.lane), keyable(item: clip.item) else { return false }
            // a server that saves the older timeline cannot keep a key on lane 0
            var next = timeline
            next.clips[index].key = clip.key ?? EditChromaKey()
            return allowsSave(EditJSON.rounded(next))
        }
        guard let overlay = timeline.overlay.first(where: { $0.id == clipID }) else { return false }
        return !lockedTracks.contains(overlay.track) && keyable(item: overlay.item)
    }

    private func keyable(item: String) -> Bool {
        guard let kind = sources[item]?.kind else { return true }
        return kind == .video
    }

    /// Sets the clip's `key` to `EditChromaKey()` (the green preset) and lifts it above the clips it is under (15.4). A clip
    /// that already has a key keeps it (its strength and edges are the owner's). Lane 0's hole is left open when the clip
    /// leaves it. False, and nothing changed, when the clip cannot take a key (`canRemoveGreen`). A lift that is refused
    /// (an older server that cannot save the lane) still leaves the key set.
    @discardableResult
    public func removeGreen(clipID: String) -> Bool {
        guard canRemoveGreen(clipID: clipID) else { return false }
        let wasSelected = selection == .main(clipID) || selection == .overlay(clipID)
        if timeline.isV2 {
            guard let clip = timeline.clips.first(where: { $0.id == clipID }) else { return false }
            if clip.key == nil {
                applyGreenscreen(id: clipID, key: EditChromaKey(), background: clip.background, output: timeline.output)
            }
            let current = timeline.clips.first(where: { $0.id == clipID }) ?? clip
            if let lane = Self.greenLane(for: current, in: timeline, locked: lockedLanes) {
                moveClip(id: clipID, toLane: lane, at: current.at, keepGap: true)
            }
            if wasSelected, let now = timeline.clips.first(where: { $0.id == clipID }) {
                selection = now.lane == 0 ? .main(clipID) : .overlay(clipID)
            }
            return true
        }
        guard let overlay = timeline.overlay.first(where: { $0.id == clipID }) else { return false }
        if overlay.key == nil {
            applyGreenscreen(id: clipID, key: EditChromaKey(), background: overlay.background, output: timeline.output)
        }
        return true
    }
}
