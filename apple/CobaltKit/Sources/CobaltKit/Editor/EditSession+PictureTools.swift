import Foundation

// The tools that show when a clip is picked on the picture (apple/CONTRACT-EDITOR.md 15.1, 15.3): fit to canvas, turn 90°,
// bring up, send down, opacity, reset. Delete is `remove`. Each is one undo step (a gesture of its own; an opacity slider run
// is one step too).

extension EditSession {
    /// What a frame is made from: the file's display size, the clip's crop and its `fit` / `fill`.
    private func pictureGeometry(ofClip id: String) -> (display: PixelSize, crop: EditCrop?, fit: EditFit)? {
        let item: String, crop: EditCrop?, fit: EditFit
        if timeline.version >= 2 {
            guard let clip = timeline.clips.first(where: { $0.id == id }) else { return nil }
            (item, crop, fit) = (clip.item, clip.crop, clip.fit)
        } else if let overlay = timeline.overlay.first(where: { $0.id == id }) {
            (item, crop, fit) = (overlay.item, nil, .fit)
        } else if let main = timeline.main.first(where: { $0.id == id }) {
            (item, crop, fit) = (main.item, main.crop, main.fit)
        } else {
            return nil
        }
        guard let display = asset(item)?.display ?? sources[item]?.display, display.w > 0, display.h > 0 else { return nil }
        return (display, crop, fit)
    }

    /// The picture whole inside the canvas, centred, not turned.
    @discardableResult
    public func fitClipToCanvas(id: String) -> Bool {
        guard let g = pictureGeometry(ofClip: id),
              let box = EditGeometry.fitFrame(display: g.display, crop: g.crop, fit: .fit, canvas: timeline.canvas) else { return false }
        return setOwnStep(id: id, box)
    }

    /// A quarter turn clockwise about the box's centre, from the box it has now (`frameBox`), wrapped into -180...180.
    @discardableResult
    public func turnClip90(id: String) -> Bool {
        guard var box = frameBox(ofClip: id) else { return false }
        box.r += 90
        return setOwnStep(id: id, box)
    }

    /// Takes the clip's `frame` away, so its `fit` or `fill` places it again, not turned. One undo step. A clip with no frame
    /// is left as it is (true, no step). False when there is no such clip or its lane is locked.
    ///
    /// A server that saves only version 1 needs a frame inside the canvas on every layer (69.2): there the layer gets the
    /// whole picture inside the canvas instead (`fitClipToCanvas`), the nearest thing that server can keep.
    @discardableResult
    public func resetClipFrame(id: String) -> Bool {
        var next = timeline
        if next.version < 2 {
            guard case .ok(let v2) = EditLanes.v1ToV2(next) else { return fitClipToCanvas(id: id) }
            next = v2
        }
        guard let index = next.clips.firstIndex(where: { $0.id == id }) else { return false }
        if lockedLanes.contains(next.clips[index].lane) { return false }
        guard next.clips[index].frame != nil else { return true }
        next.clips[index].frame = nil
        guard allowsSave(EditJSON.rounded(next)) else { return fitClipToCanvas(id: id) }
        laneRefusal = nil
        commit(key: nil) { $0 = next }
        return true
    }

    // MARK: opacity (any lane)

    /// The clip's opacity, 0.1...1, on any lane; nil when there is no such clip. A version 1 main clip is always 1.
    public func clipOpacity(id: String) -> Double? {
        if timeline.version >= 2 { return timeline.clips.first(where: { $0.id == id })?.opacity }
        if let overlay = timeline.overlay.first(where: { $0.id == id }) { return overlay.opacity }
        return timeline.main.contains(where: { $0.id == id }) ? 1 : nil
    }

    /// Whether `setClipOpacity` can change this clip: it exists, its lane is not locked, and the server can keep an opacity
    /// there. Lane 0 can hold one only on a version 2 timeline (APP-API-CONTRACT 69.1), so a server that saves only version 1
    /// cannot (69.2 refuses a lane 0 clip with opacity).
    public func canSetClipOpacity(id: String) -> Bool {
        if case .ok = opacityChange(id: id, 0.5) { return true }
        return false
    }

    /// Sets a clip's opacity on any lane, lane 0 included (69.1: `opacity` 0.1...1 on every version 2 clip, drawn over what is
    /// under it, black at the bottom). Edits with the key `opacity:<id>` are one undo step while a slider runs (end the run
    /// with `endGesture`). A version 1 overlay goes through `setOverlayOpacity`; a version 1 main clip makes the project
    /// version 2 first (part of the same step). False when it cannot, with `laneRefusal` when the server or the project's
    /// version is why (not for a missing clip or a locked lane).
    @discardableResult
    public func setClipOpacity(id: String, _ value: Double) -> Bool {
        let v = min(1, max(0.1, value.isFinite ? value : 1))
        switch opacityChange(id: id, v) {
        case .overlayV1:
            setOverlayOpacity(id: id, v)
            return true
        case .ok(let next):
            laneRefusal = nil
            commit(key: "opacity:\(id)") { $0 = next }
            return true
        case .refused(let message):
            refuseLane(message)
            return false
        case .no:
            return false
        }
    }

    private enum OpacityChange {
        case ok(EditTimeline), overlayV1, refused(String), no
    }

    /// The timeline with the clip at opacity `v` (version 2, converted from version 1 when it has to be).
    private func opacityChange(id: String, _ v: Double) -> OpacityChange {
        var next = timeline
        if next.version < 2 {
            if let overlay = next.overlay.first(where: { $0.id == id }) {
                return lockedTracks.contains(overlay.track) ? .no : .overlayV1
            }
            guard next.main.contains(where: { $0.id == id }) else { return .no }
            guard case .ok(let v2) = EditLanes.v1ToV2(next) else { return .refused(EditLanes.staysV1Message) }
            next = v2
        }
        guard let index = next.clips.firstIndex(where: { $0.id == id }) else { return .no }
        if lockedLanes.contains(next.clips[index].lane) { return .no }
        next.clips[index].opacity = v
        return allowsSave(EditJSON.rounded(next)) ? .ok(next) : .refused(EditLanes.needsServerMessage)
    }

    private func setOwnStep(id: String, _ box: EditFrame) -> Bool {
        beginGesture()
        defer { endGesture() }
        return setClipFrame(id: id, box)
    }

    /// One lane up (`by` +1, drawn later) or down. The selection follows the clip across lane 0 (a main clip becomes a layer
    /// and back). A taken spot or a locked lane is refused and `laneRefusal` says why.
    @discardableResult
    public func moveClipLayerKeepingSelection(id: String, by delta: Int) -> Bool {
        let wasSelected = selection == .main(id) || selection == .overlay(id)
        let moved: Bool
        if timeline.version >= 2 {
            moved = moveClipLayer(id: id, by: delta)
        } else if let overlay = timeline.overlay.first(where: { $0.id == id }) {
            moved = setOverlayTrack(id: id, overlay.track + delta)
        } else {
            moved = false
        }
        if moved, wasSelected {
            if let clip = timeline.clips.first(where: { $0.id == id }) {
                selection = clip.lane == 0 ? .main(id) : .overlay(id)
            } else if timeline.overlay.contains(where: { $0.id == id }) {
                selection = .overlay(id)
            }
        }
        return moved
    }

    /// The lane the clip sits on (0 = the bottom), or nil when there is no such clip. A version 1 overlay is lane `track + 1`.
    public func laneOfClip(id: String) -> Int? {
        if timeline.version >= 2 { return timeline.clips.first(where: { $0.id == id })?.lane }
        if let overlay = timeline.overlay.first(where: { $0.id == id }) { return overlay.track + 1 }
        return timeline.main.contains(where: { $0.id == id }) ? 0 : nil
    }
}
