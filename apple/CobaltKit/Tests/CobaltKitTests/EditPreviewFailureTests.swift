import AVFoundation
import Foundation
import Testing
@testable import CobaltKit

// The line on a failed preview, and which overlay is hiding the whole picture.

struct EditPreviewFailureTests {
    @Test func aMissingSourceSaysTheFileIsMissing() {
        #expect(EditPreviewFailure.reason(EditError.other("source:abc")) == EditPreviewFailure.fileMissing)
        #expect(EditPreviewFailure.reason(EditError.other("empty")) == EditPreviewFailure.nothingToPlay)
        #expect(EditPreviewFailure.reason(EditError.offline) == "offline, so the preview couldn't update")
        let av = NSError(domain: AVFoundationErrorDomain, code: -11800)
        #expect(EditPreviewFailure.reason(av) == EditPreviewFailure.couldntRead)
        #expect(EditPreviewFailure.reason(EditError.other("nope")) == EditPreviewFailure.couldntUpdate)
    }
}

struct EditPreviewCoverTests {
    private func timeline(frame: EditFrame, opacity: Double = 1, key: EditChromaKey? = nil, display: PixelSize = PixelSize(w: 1920, h: 1080)) -> (EditTimeline, EditTiming) {
        let main = EditClip(id: "cMain0001", item: "main-item", in: 0, out: 10)
        let overlay = EditOverlay(
            id: "cOver0001", item: "over-item", at: 0, in: 0, out: 10, frame: frame, opacity: opacity, muted: true, key: key)
        let t = EditTimeline(canvas: EditCanvas(w: 1920, h: 1080, fps: 30), main: [main], overlay: [overlay])
        return (t, EditTiming(t))
    }

    private func cover(_ t: EditTimeline, _ timing: EditTiming, at frame: Int = 0, blocked: @escaping (String) -> Bool = { _ in false }) -> String? {
        EditPreviewCover.id(
            in: t, timing: timing, at: frame,
            display: { $0 == "over-item" ? PixelSize(w: 1920, h: 1080) : PixelSize(w: 960, h: 720) },
            isVideo: { $0 == "over-item" },
            blocked: blocked)
    }

    @Test func aFullFrameOpaqueVideoWithNoKeyCoversThePicture() {
        let (t, timing) = timeline(frame: EditFrame(x: 0, y: 0, w: 1))
        #expect(cover(t, timing) == "cOver0001")
    }

    @Test func aSmallOrKeyedOrFaintOverlayDoesNot() {
        let small = timeline(frame: EditFrame(x: 0.6, y: 0.05, w: 0.35))
        #expect(cover(small.0, small.1) == nil)
        let keyed = timeline(frame: EditFrame(x: 0, y: 0, w: 1), key: EditChromaKey())
        #expect(cover(keyed.0, keyed.1) == nil)
        let faint = timeline(frame: EditFrame(x: 0, y: 0, w: 1), opacity: 0.4)
        #expect(cover(faint.0, faint.1) == nil)
        let (t, timing) = timeline(frame: EditFrame(x: 0, y: 0, w: 1))
        #expect(cover(t, timing, blocked: { $0 == "cOver0001" }) == nil)
    }

    @Test func itOnlyCoversWhileTheOverlayIsUp() {
        let main = EditClip(id: "cMain0001", item: "main-item", in: 0, out: 10)
        let overlay = EditOverlay(
            id: "cOver0001", item: "over-item", at: 4, in: 0, out: 2, frame: EditFrame(x: 0, y: 0, w: 1), muted: true)
        let t = EditTimeline(canvas: EditCanvas(w: 1920, h: 1080, fps: 30), main: [main], overlay: [overlay])
        let timing = EditTiming(t)
        #expect(cover(t, timing, at: 30) == nil)          // 1 s, before it
        #expect(cover(t, timing, at: 150) == "cOver0001") // 5 s, during it
    }
}
