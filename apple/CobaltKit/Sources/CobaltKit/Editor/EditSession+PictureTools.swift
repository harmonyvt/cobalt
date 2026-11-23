import Foundation

// The tools that show when a clip is picked on the picture (apple/CONTRACT-EDITOR.md 15.1, 15.3): fit to canvas, turn 90°,
// bring up, send down, reset. Opacity is `setOverlayOpacity`; delete is `remove`. Each is one undo step (a gesture of its own).
//
// Built on the session's public edits (`setClipFrame`, `moveClipLayer`, `setOverlayTrack`), because `EditSession.swift` is
// shared and was not touched.

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

    /// Back to the box its `fit` or `fill` gives it, not turned. (Not "no frame": removing a frame needs the session's own
    /// commit; the picture is the same.)
    @discardableResult
    public func resetClipFrame(id: String) -> Bool {
        guard let g = pictureGeometry(ofClip: id),
              let box = EditGeometry.fitFrame(display: g.display, crop: g.crop, fit: g.fit, canvas: timeline.canvas) else { return false }
        return setOwnStep(id: id, box)
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
