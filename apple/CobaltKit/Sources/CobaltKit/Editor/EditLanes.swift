import Foundation

// Timeline v2 (APP-API-CONTRACT 69): the strict parse, the v1↔v2 conversion, and the lane edits. The parse matches
// `editor/helper/timeline.js` (`parseTimeline`, `timelineV1ToV2`, `timelineV2ToV1`, `coverItem`, `clipDrawOrder`). The
// shared fixtures live in `deploy/cloudflare/editor/helper/test/fixtures/timeline-v2`; the Swift tests read that directory
// by a relative path from the test file and do not copy the JSON.

/// What a strict parse or a conversion returned.
public enum EditParseResult: Equatable, Sendable {
    case ok(EditTimeline)
    case failed(code: String, path: String)
}

/// A lane edit that did or did not change the timeline. `insertedAbove` is the lane a new empty lane was opened above
/// (higher lanes shifted up), so the session can move its locks with them.
public struct EditLaneSuccess: Equatable, Sendable {
    public var timeline: EditTimeline
    public var insertedAbove: Int?
}

public enum EditLaneChange: Equatable, Sendable {
    case done(EditLaneSuccess)
    case refused(String)
}

public enum EditLanes {
    /// `lane` is 0...63, the same ceiling as overlay tracks (`EDIT_OVERLAY_TRACKS`).
    public static let laneLimit = 64
    public static let maxSeconds = 600.0
    /// Sent on edit reads and writes so a version 2 project comes back as itself.
    public static let versionHeader = "X-Cobalt-Timeline-Version"
    public static let lanesFullMessage = "all 64 lanes are in use"
    public static let laneLockedMessage = "that lane is locked"
    public static let needsServerMessage = "this server saves the older timeline. update it to move clips between lanes."
    public static let tooLongMessage = "10 minutes at most"
    public static let staysV1Message = "this edit stays on the older timeline"
    public static let spotTakenMessage = "that spot is taken"
    public static let missingClipMessage = "that clip is gone"

    /// The frame a version 2 clip with no `frame` shows as in the current overlay UI. It is not written back.
    static let placeholderFrame = EditFrame(x: 0, y: 0, w: 1)

    // MARK: - Canonical text

    /// The server's canonical JSON, or nil when it cannot be encoded.
    public static func canonical(_ timeline: EditTimeline) -> String? {
        guard let data = try? EditJSON.encode(timeline) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func clipCount(_ timeline: EditTimeline) -> Int {
        timeline.version >= 2 ? timeline.clips.count : timeline.storedMain.count + timeline.storedOverlay.count
    }

    /// Lane 0's earliest clip, or the earliest clip on the lowest lane when lane 0 is empty. Version 1 is `main[0]`.
    public static func coverItem(_ timeline: EditTimeline) -> String? {
        if timeline.version < 2 { return timeline.storedMain.first?.item }
        guard !timeline.clips.isEmpty else { return nil }
        let lane = timeline.clips.contains { $0.lane == 0 } ? 0 : timeline.clips.map(\.lane).min() ?? 0
        var best: (item: String, at: Double, index: Int)?
        for (index, clip) in timeline.clips.enumerated() where clip.lane == lane {
            if best == nil || clip.at < best!.at || (clip.at == best!.at && index < best!.index) {
                best = (clip.item, clip.at, index)
            }
        }
        return best?.item
    }

    /// Indexes in draw order: bottom lane, then `at`, then array order.
    public static func drawOrder(_ timeline: EditTimeline) -> [Int] {
        timeline.clips.indices.sorted { a, b in
            let lhs = timeline.clips[a], rhs = timeline.clips[b]
            if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return a < b
        }
    }

    /// A version 1 project becomes version 2 when the conversion succeeds (track 63 does not, and stays version 1).
    public static func materialize(_ timeline: EditTimeline) -> EditTimeline {
        let rounded = EditJSON.rounded(timeline)
        if rounded.version >= 2 {
            var out = rounded
            out.storedMain = []
            out.storedOverlay = []
            return out
        }
        if case .ok(let v2) = v1ToV2(rounded) { return v2 }
        return rounded
    }

    /// True when saving this as version 1 would drop something.
    public static func needsV2(_ timeline: EditTimeline, kinds: [String: String?] = [:]) -> Bool {
        guard timeline.version >= 2 else { return false }
        if case .failed = v2ToV1(timeline, kinds: kinds) { return true }
        return false
    }

    // MARK: - Frames

    public static func startFrame(_ at: Double, fps: Int) -> Int {
        max(0, EditMath.roundHalfUp(at * Double(max(1, fps))))
    }

    public static func outputFrames(_ clip: EditLaneClip, fps: Int) -> Int {
        let speed = clip.speed > 0 ? clip.speed : 1
        return max(1, EditMath.roundHalfUp((clip.out - clip.`in`) / speed * Double(max(1, fps))))
    }

    /// The latest clip end, in frames. Version 1 asks `EditTiming` (the packed main track).
    public static func endFrame(_ timeline: EditTimeline) -> Int {
        if timeline.version < 2 { return EditTiming(timeline).frames }
        let fps = max(1, timeline.canvas.fps)
        var end = 0
        for clip in timeline.clips {
            end = max(end, startFrame(clip.at, fps: fps) + outputFrames(clip, fps: fps))
        }
        return end
    }

    /// Where lane 0 ends, in frames. 0 when lane 0 is empty. The legacy clamp uses this as the main track's length.
    public static func lane0EndFrame(_ timeline: EditTimeline) -> Int {
        let fps = max(1, timeline.canvas.fps)
        var end = 0
        for clip in timeline.clips where clip.lane == 0 {
            end = max(end, startFrame(clip.at, fps: fps) + outputFrames(clip, fps: fps))
        }
        return end
    }

    static func tooLong(_ timeline: EditTimeline) -> Bool {
        let fps = max(1, timeline.canvas.fps)
        return endFrame(timeline) > Int(maxSeconds) * fps
    }

    // MARK: - Projection (the current timeline UI)

    static func projectMain(_ timeline: EditTimeline) -> [EditClip] {
        timeline.clips.enumerated().filter { $0.element.lane == 0 }.sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map { asMain($0.element) }
    }

    static func projectOverlay(_ timeline: EditTimeline) -> [EditOverlay] {
        timeline.clips.enumerated().filter { $0.element.lane > 0 }.sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map { asOverlay($0.element) }
    }

    static func asMain(_ clip: EditLaneClip) -> EditClip {
        EditClip(
            id: clip.id, item: clip.item, in: clip.`in`, out: clip.out, speed: clip.speed, crop: clip.crop,
            fit: clip.fit, volume: clip.volume, muted: clip.muted, pitch: clip.pitch)
    }

    static func asOverlay(_ clip: EditLaneClip) -> EditOverlay {
        EditOverlay(
            id: clip.id, item: clip.item, at: clip.at, in: clip.`in`, out: clip.out, frame: clip.frame ?? placeholderFrame,
            opacity: clip.opacity, volume: clip.volume, muted: clip.muted, pitch: clip.pitch, track: max(0, clip.lane - 1),
            hidden: clip.hidden, key: clip.key, background: clip.background)
    }

    /// A field edit of the main row (same clips, same order) keeps each clip's `at` and ripples later lane-0 clips when a
    /// length changes. A reorder, insert or removal packs lane 0 from time 0, which is what the current drag-to-reorder does.
    static func applyMain(_ newMain: [EditClip], to timeline: inout EditTimeline) {
        let fps = max(1, timeline.canvas.fps)
        let oldIDs = timeline.clips.enumerated().filter { $0.element.lane == 0 }.sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map(\.element.id)
        if oldIDs == newMain.map(\.id) {
            let byID = Dictionary(uniqueKeysWithValues: newMain.map { ($0.id, $0) })
            var shifts: [(end: Int, delta: Int)] = []
            for index in timeline.clips.indices where timeline.clips[index].lane == 0 {
                guard let fresh = byID[timeline.clips[index].id] else { continue }
                let oldFrames = outputFrames(timeline.clips[index], fps: fps)
                let end = startFrame(timeline.clips[index].at, fps: fps) + oldFrames
                var clip = timeline.clips[index]
                copyMain(fresh, onto: &clip)
                let newFrames = outputFrames(clip, fps: fps)
                if newFrames != oldFrames { shifts.append((end, newFrames - oldFrames)) }
                timeline.clips[index] = clip
            }
            guard !shifts.isEmpty else { return }
            for index in timeline.clips.indices where timeline.clips[index].lane == 0 {
                let start = startFrame(timeline.clips[index].at, fps: fps)
                let delta = shifts.reduce(0) { $0 + ($1.end <= start ? $1.delta : 0) }
                if delta != 0 {
                    timeline.clips[index].at = EditJSON.time(Double(start + delta) / Double(fps))
                }
            }
            return
        }
        let oldByID = Dictionary(uniqueKeysWithValues: timeline.clips.filter { $0.lane == 0 }.map { ($0.id, $0) })
        var packed: [EditLaneClip] = []
        var frame = 0
        for fresh in newMain {
            var clip = oldByID[fresh.id] ?? EditLaneClip(
                id: fresh.id, item: fresh.item, lane: 0, at: 0, in: fresh.`in`, out: fresh.out)
            copyMain(fresh, onto: &clip)
            clip.lane = 0
            clip.at = EditJSON.time(Double(frame) / Double(fps))
            frame += outputFrames(clip, fps: fps)
            packed.append(clip)
        }
        timeline.clips = packed + timeline.clips.filter { $0.lane != 0 }
    }

    /// Rewrites the lanes above 0 from the overlay row. Speed, crop and fit stay, because an overlay does not carry them.
    /// A placeholder frame is not stored over a clip that had none.
    static func applyOverlay(_ newOverlay: [EditOverlay], to timeline: inout EditTimeline) {
        let oldByID = Dictionary(uniqueKeysWithValues: timeline.clips.filter { $0.lane != 0 }.map { ($0.id, $0) })
        var higher: [EditLaneClip] = []
        for overlay in newOverlay {
            var clip = oldByID[overlay.id] ?? EditLaneClip(
                id: overlay.id, item: overlay.item, lane: overlay.track + 1, at: overlay.at, in: overlay.`in`, out: overlay.out,
                frame: overlay.frame)
            clip.id = overlay.id
            clip.item = overlay.item
            clip.lane = max(0, overlay.track) + 1
            clip.at = overlay.at
            clip.`in` = overlay.`in`
            clip.out = overlay.out
            clip.volume = overlay.volume
            clip.muted = overlay.muted
            clip.pitch = overlay.pitch
            clip.opacity = overlay.opacity
            clip.hidden = overlay.hidden
            clip.key = overlay.key
            clip.background = overlay.background
            if let old = oldByID[overlay.id] {
                clip.speed = old.speed
                clip.crop = old.crop
                clip.fit = old.fit
                clip.frame = (old.frame == nil && overlay.frame == placeholderFrame) ? nil : overlay.frame
            } else {
                clip.frame = overlay.frame
            }
            higher.append(clip)
        }
        timeline.clips = timeline.clips.filter { $0.lane == 0 } + higher
    }

    private static func copyMain(_ fresh: EditClip, onto clip: inout EditLaneClip) {
        clip.item = fresh.item
        clip.`in` = fresh.`in`
        clip.out = fresh.out
        clip.speed = fresh.speed
        clip.crop = fresh.crop
        clip.fit = fresh.fit
        clip.volume = fresh.volume
        clip.muted = fresh.muted
        clip.pitch = fresh.pitch
    }

    // MARK: - Lane edits

    /// Moves `id` to `toLane` at `at` (seconds, as the timeline is now). Leaving lane 0 closes the hole unless `keepGap`.
    /// A landing that overlaps another clip opens a new lane directly above `toLane` and shifts the higher lanes up.
    public static func moveClip(
        _ timeline: EditTimeline, id: String, toLane: Int, at: Double, keepGap: Bool, locked: Set<Int>
    ) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        if locked.contains(clip.lane) || locked.contains(toLane) { return .refused(laneLockedMessage) }
        guard (0..<laneLimit).contains(toLane) else { return .refused(lanesFullMessage) }
        guard at.isFinite, at >= 0 else { return .refused(tooLongMessage) }
        let fps = max(1, timeline.canvas.fps)
        let start = startFrame(clip.at, fps: fps)
        let frames = outputFrames(clip, fps: fps)
        if toLane == clip.lane && startFrame(at, fps: fps) == start {
            return .done(EditLaneSuccess(timeline: timeline, insertedAbove: nil))
        }
        var destAt = EditJSON.time(at)
        if clip.lane == 0 && toLane == 0 && !keepGap {
            let destFrame = startFrame(at, fps: fps)
            if destFrame >= start + frames {
                destAt = EditJSON.time(Double(destFrame - frames) / Double(fps))
            }
        }
        var next = timeline
        let close = clip.lane == 0 && !keepGap
        guard var placed = take(id, from: &next, closeLane0: close) else { return .refused(missingClipMessage) }
        placed.at = destAt
        placed.lane = toLane
        var inserted: Int?
        if overlaps(placed, in: next.clips, fps: fps) {
            guard canInsertLane(above: toLane, in: next) else { return .refused(lanesFullMessage) }
            shiftLanes(above: toLane, in: &next)
            placed.lane = toLane + 1
            inserted = toLane
        }
        next.clips.append(placed)
        guard !tooLong(next) else { return .refused(tooLongMessage) }
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: inserted))
    }

    /// Opens a new lane directly above `lane` and puts the clip there, even when `lane` itself was free.
    public static func moveToNewLane(
        _ timeline: EditTimeline, id: String, above lane: Int, at: Double, keepGap: Bool, locked: Set<Int>
    ) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        if locked.contains(clip.lane) || locked.contains(lane) { return .refused(laneLockedMessage) }
        guard (0..<laneLimit).contains(lane) else { return .refused(lanesFullMessage) }
        guard at.isFinite, at >= 0 else { return .refused(tooLongMessage) }
        var next = timeline
        guard var placed = take(id, from: &next, closeLane0: clip.lane == 0 && !keepGap) else {
            return .refused(missingClipMessage)
        }
        guard canInsertLane(above: lane, in: next) else { return .refused(lanesFullMessage) }
        shiftLanes(above: lane, in: &next)
        placed.lane = lane + 1
        placed.at = EditJSON.time(at)
        next.clips.append(placed)
        guard !tooLong(next) else { return .refused(tooLongMessage) }
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: lane))
    }

    /// Shifts every clip above `lane` up by one. The new lane is empty until something is put there.
    public static func insertLane(above lane: Int, in timeline: EditTimeline) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard (0..<laneLimit).contains(lane) else { return .refused(lanesFullMessage) }
        guard canInsertLane(above: lane, in: timeline) else { return .refused(lanesFullMessage) }
        var next = timeline
        shiftLanes(above: lane, in: &next)
        return .done(EditLaneSuccess(timeline: next, insertedAbove: lane))
    }

    /// Removes the clip. On lane 0 the clips after it move back to close the hole.
    public static func delete(_ timeline: EditTimeline, id: String, closeLane0: Bool, locked: Set<Int>) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        if locked.contains(clip.lane) { return .refused(laneLockedMessage) }
        var next = timeline
        guard take(id, from: &next, closeLane0: closeLane0 && clip.lane == 0) != nil else {
            return .refused(missingClipMessage)
        }
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: nil))
    }

    /// Splits at output frame `atFrame`. Nothing changes when the frame is on an edge or a half would be under 0.1 s.
    public static func split(_ timeline: EditTimeline, id: String, atFrame: Int, newID: String) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        let clip = timeline.clips[index]
        let fps = max(1, timeline.canvas.fps)
        let start = startFrame(clip.at, fps: fps)
        let frames = outputFrames(clip, fps: fps)
        let offset = atFrame - start
        guard offset > 0, offset < frames else { return .done(EditLaneSuccess(timeline: timeline, insertedAbove: nil)) }
        let effective = (clip.out - clip.`in`) * Double(fps) / Double(frames)
        let point = EditJSON.time(clip.`in` + Double(offset) / Double(fps) * effective)
        let minSpan = 0.1 * max(1, clip.speed)
        guard point - clip.`in` >= minSpan - 1e-9, clip.out - point >= minSpan - 1e-9 else {
            return .done(EditLaneSuccess(timeline: timeline, insertedAbove: nil))
        }
        var next = timeline
        next.clips[index].out = point
        var second = clip
        second.id = newID
        second.`in` = point
        second.at = EditJSON.time(Double(start + offset) / Double(fps))
        next.clips.insert(second, at: index + 1)
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: nil))
    }

    /// A copy just after the original on the same lane, or on a new lane above it when that spot is taken.
    public static func duplicate(_ timeline: EditTimeline, id: String, newID: String, locked: Set<Int>) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        if locked.contains(clip.lane) { return .refused(laneLockedMessage) }
        let fps = max(1, timeline.canvas.fps)
        var copy = clip
        copy.id = newID
        copy.at = EditJSON.time(Double(startFrame(clip.at, fps: fps) + outputFrames(clip, fps: fps)) / Double(fps))
        var next = timeline
        var inserted: Int?
        if overlaps(copy, in: next.clips, fps: fps) {
            guard canInsertLane(above: clip.lane, in: next) else { return .refused(lanesFullMessage) }
            shiftLanes(above: clip.lane, in: &next)
            copy.lane = clip.lane + 1
            inserted = clip.lane
        }
        next.clips.append(copy)
        guard !tooLong(next) else { return .refused(tooLongMessage) }
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: inserted))
    }

    public static func setHidden(_ timeline: EditTimeline, id: String, hidden: Bool) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        var next = timeline
        next.clips[index].hidden = hidden
        return .done(EditLaneSuccess(timeline: next, insertedAbove: nil))
    }

    /// `delta` +1 is one lane up (drawn later). A taken spot is refused; it does not open a lane.
    public static func moveLayer(_ timeline: EditTimeline, id: String, by delta: Int, locked: Set<Int>) -> EditLaneChange {
        guard timeline.version >= 2 else { return .refused(staysV1Message) }
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return .refused(missingClipMessage) }
        if delta == 0 { return .done(EditLaneSuccess(timeline: timeline, insertedAbove: nil)) }
        let dest = clip.lane + delta
        guard (0..<laneLimit).contains(dest) else { return .refused(lanesFullMessage) }
        if locked.contains(clip.lane) || locked.contains(dest) { return .refused(laneLockedMessage) }
        var next = timeline
        guard var placed = take(id, from: &next, closeLane0: clip.lane == 0 && dest != 0) else {
            return .refused(missingClipMessage)
        }
        placed.lane = dest
        if overlaps(placed, in: next.clips, fps: max(1, timeline.canvas.fps)) { return .refused(spotTakenMessage) }
        next.clips.append(placed)
        guard !tooLong(next) else { return .refused(tooLongMessage) }
        return .done(EditLaneSuccess(timeline: EditJSON.rounded(next), insertedAbove: nil))
    }

    /// Video clips that overlap in time need different composition tracks. Interval colouring: the lowest track whose
    /// previous clip has already ended. Returns one assignment per input, in the same order.
    public static func colorTracks(_ items: [(id: String, start: Int, end: Int)]) -> [(id: String, track: Int)] {
        var tracks = Array(repeating: 0, count: items.count)
        var ends: [Int] = []
        let order = items.indices.sorted { lhs, rhs in
            if items[lhs].start != items[rhs].start { return items[lhs].start < items[rhs].start }
            return items[lhs].id < items[rhs].id
        }
        for index in order {
            let item = items[index]
            if let track = ends.firstIndex(where: { $0 <= item.start }) {
                ends[track] = item.end
                tracks[index] = track
            } else {
                tracks[index] = ends.count
                ends.append(item.end)
            }
        }
        return zip(items, tracks).map { ($0.0.id, $0.1) }
    }

    private static func canInsertLane(above lane: Int, in timeline: EditTimeline) -> Bool {
        guard lane + 1 < laneLimit else { return false }
        return !timeline.clips.contains { $0.lane > lane && $0.lane + 1 >= laneLimit }
    }

    private static func shiftLanes(above lane: Int, in timeline: inout EditTimeline) {
        for index in timeline.clips.indices where timeline.clips[index].lane > lane {
            timeline.clips[index].lane += 1
        }
    }

    @discardableResult
    private static func take(_ id: String, from timeline: inout EditTimeline, closeLane0: Bool) -> EditLaneClip? {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = timeline.clips[index]
        let fps = max(1, timeline.canvas.fps)
        let end = startFrame(clip.at, fps: fps) + outputFrames(clip, fps: fps)
        timeline.clips.remove(at: index)
        if closeLane0 && clip.lane == 0 {
            for i in timeline.clips.indices where timeline.clips[i].lane == 0 {
                let start = startFrame(timeline.clips[i].at, fps: fps)
                if start >= end {
                    timeline.clips[i].at = EditJSON.time(Double(start - (end - startFrame(clip.at, fps: fps))) / Double(fps))
                }
            }
        }
        return clip
    }

    private static func overlaps(_ clip: EditLaneClip, in clips: [EditLaneClip], fps: Int) -> Bool {
        let start = startFrame(clip.at, fps: fps)
        let end = start + outputFrames(clip, fps: fps)
        for other in clips where other.lane == clip.lane && other.id != clip.id {
            let otherStart = startFrame(other.at, fps: fps)
            let otherEnd = otherStart + outputFrames(other, fps: fps)
            if start < otherEnd && otherStart < end { return true }
        }
        return false
    }
}
