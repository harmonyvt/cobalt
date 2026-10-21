import Foundation
import Testing
@testable import CobaltKit

// The open project (apple/CONTRACT-EDITOR.md 3.6): every edit the timeline offers and what it clamps, the undo stacks, the autosave
// (debounce, retry, conflict) against `PreviewClient` on a virtual clock, and the render.

/// A session on a preview server. Its files never load (the cache has no copy and the preview download is a placeholder), so
/// these tests never wait for AVFoundation.
@MainActor
private struct Rig {
    let h: Harness
    let session: EditSession
    let sources: [String: EditSource]

    var client: PreviewClient { h.ctx.client as! PreviewClient }
    var server: PreviewEditorState { client.editorState }

    init(_ scenario: PreviewScenario = .happy, project: String = PreviewEditorIDs.beach) async throws {
        h = Harness(scenario)
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: project)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(directory: dir, client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        sources = PreviewData.editorSources()
        session = EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    func finish() { session.tearDown() }

    var main: [EditClip] { session.timeline.main }
    func clip(_ item: String) -> EditClip { session.timeline.main.first { $0.item == item }! }
    var overlayID: String { session.timeline.overlay[0].id }

    func driveUntilSaved() async {
        await h.drive(until: { self.session.saveState == .saved })
    }
}

// MARK: - the main track

@MainActor
struct EditSessionMainTrackTests {
    @Test func theSessionStartsFromTheServersProject() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.timeline == EditJSON.rounded(PreviewData.editorBeachTimeline()))
        #expect(rig.session.timing.frames == 780)
        #expect(rig.session.problems.isEmpty)
        #expect(rig.session.saveState == .saved)
        #expect(!rig.session.canUndo && !rig.session.canRedo)
        #expect(rig.session.project.revision == 4)
    }

    @Test func addingVideosAppendsWholeFilesAndSelectsTheFirst() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let surf = rig.sources[PreviewEditorIDs.surf]!
        rig.session.add([surf], at: nil)
        #expect(rig.main.count == 5)
        let added = rig.main[4]
        #expect(added.item == PreviewEditorIDs.surf && added.`in` == 0 && added.out == 10 && added.speed == 1)
        #expect(rig.session.selection == .main(added.id))
        #expect(rig.session.timing.frames == 780 + 300)
        #expect(rig.session.saveState == .unsaved)
    }

    @Test func addingAtAnIndexInsertsThereAndAGifIsRefused() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.add([rig.sources[PreviewEditorIDs.friends]!, rig.sources[PreviewEditorIDs.surf]!], at: 1)
        #expect(rig.main.map(\.item) == [
            PreviewEditorIDs.pier, PreviewEditorIDs.friends, PreviewEditorIDs.surf, PreviewEditorIDs.surf,
            PreviewEditorIDs.sunset, PreviewEditorIDs.friends,
        ])
        let before = rig.session.timeline
        rig.session.add([rig.sources[PreviewEditorIDs.dance]!, rig.sources[PreviewEditorIDs.photo]!], at: nil)
        #expect(rig.session.timeline == before)
    }

    @Test func movingAClipChangesTheOrderAndTheStarts() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let friends = rig.clip(PreviewEditorIDs.friends).id
        rig.session.move(clip: friends, to: 0)
        #expect(rig.main.first?.id == friends)
        #expect(rig.session.timing.main.map(\.start) == [0, 120, 480, 615])
        rig.session.move(clip: friends, to: 99)
        #expect(rig.main.last?.id == friends)
    }

    @Test func trimmingIsClampedToTheFile() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.trim(clip: pier, in: -5, out: 99)
        #expect(rig.clip(PreviewEditorIDs.pier).`in` == 0 && rig.clip(PreviewEditorIDs.pier).out == 12)
        rig.session.endGesture()
        rig.session.trim(clip: pier, in: 11.95, out: nil)
        #expect(rig.clip(PreviewEditorIDs.pier).`in` == 11.9)           // 0.1 s of output at least
        rig.session.endGesture()
        rig.session.trim(clip: pier, in: 1, out: 0.5)
        #expect(rig.clip(PreviewEditorIDs.pier).`in` == 1 && rig.clip(PreviewEditorIDs.pier).out == 1.1)
    }

    @Test func aFasterClipKeepsAMinimumOfSourceForTheSameOutput() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let surf = rig.clip(PreviewEditorIDs.surf).id         // 1.5x: 0.15 s of source is 0.1 s of output
        rig.session.trim(clip: surf, in: 8.7, out: nil)
        #expect(rig.clip(PreviewEditorIDs.surf).`in` == 8.6)
    }

    @Test func splittingKeepsEverySettingOnBothHalves() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let surf = rig.clip(PreviewEditorIDs.surf)
        rig.session.setVolume(0.5, clip: surf.id)
        rig.session.setMuted(true, clip: surf.id)
        rig.session.split(clip: surf.id, atFrame: 360 + 45)
        #expect(rig.main.count == 5)
        let first = rig.main[1], second = rig.main[2]
        #expect(first.id == surf.id && second.id != surf.id)
        #expect(first.`in` == 2 && first.out == 4.25 && second.`in` == 4.25 && second.out == 8.75)
        #expect(second.speed == 1.5 && second.volume == 0.5 && second.muted && first.volume == 0.5)
        #expect(rig.session.timing.main.map(\.frames) == [360, 45, 90, 165, 120])
        #expect(rig.session.timing.frames == 780)
    }

    @Test func splittingTheCroppedClipKeepsTheCropOnBoth() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let sunset = rig.clip(PreviewEditorIDs.sunset)
        #expect(sunset.crop != nil)
        rig.session.split(clip: sunset.id, atFrame: 495 + 80)
        let halves = rig.main.filter { $0.item == PreviewEditorIDs.sunset }
        #expect(halves.count == 2 && halves[0].crop == sunset.crop && halves[1].crop == sunset.crop)
    }

    @Test func splittingOnAnEdgeOrTooCloseToOneDoesNothing() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let before = rig.session.timeline
        rig.session.split(clip: rig.clip(PreviewEditorIDs.surf).id, atFrame: 360)           // the start
        rig.session.split(clip: rig.clip(PreviewEditorIDs.surf).id, atFrame: 360 + 135)     // past the end
        rig.session.split(clip: rig.clip(PreviewEditorIDs.surf).id, atFrame: 360 + 1)       // a half under 0.1 s of output
        #expect(rig.session.timeline == before)
    }

    @Test func splittingAtThePlayheadUsesTheClipUnderIt() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.seek(frame: 100)
        rig.session.splitAtPlayhead()
        #expect(rig.main.count == 5)
        #expect(rig.main[0].out == EditJSON.time(100.0 / 30) && rig.main[1].`in` == EditJSON.time(100.0 / 30))
    }

    @Test func speedSnapsToTwentiethsAndStaysInRange() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setSpeed(1.53, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).speed == 1.55)
        rig.session.endGesture()
        rig.session.setSpeed(9, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).speed == 4)
        rig.session.endGesture()
        rig.session.setSpeed(0.1, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).speed == 0.25)
    }

    @Test func aShortClipCannotBeSpedPastTenthsOfASecondOfOutput() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.trim(clip: pier, in: 0, out: 0.2)
        rig.session.endGesture()
        rig.session.setSpeed(4, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).speed == 2)             // 0.2 s of source at 2x is 0.1 s
    }

    @Test func aCropIsKeptInsideTheFrameAndAtLeastSixtyFourPixels() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setCrop(EditCrop(aspect: .free, x: 0.9, y: 0, w: 0.5, h: 2), clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).crop == EditCrop(aspect: .free, x: 0.5, y: 0, w: 0.5, h: 1))
        rig.session.endGesture()
        rig.session.setCrop(EditCrop(aspect: .free, x: 0, y: 0, w: 0.001, h: 0.001), clip: pier)
        let tiny = rig.clip(PreviewEditorIDs.pier).crop!
        #expect(tiny.w >= 64.0 / 1280 && tiny.h >= 64.0 / 720)
        #expect(rig.session.problems.isEmpty)
        rig.session.endGesture()
        rig.session.setCrop(nil, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).crop == nil)
    }

    @Test func fitVolumeAndMuteAreSetPerClip() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setFit(.fit, clip: pier)
        rig.session.setVolume(1.7, clip: pier)
        rig.session.setMuted(true, clip: pier)
        let c = rig.clip(PreviewEditorIDs.pier)
        #expect(c.fit == .fit && c.volume == 1 && c.muted)
        rig.session.endGesture()
        rig.session.setVolume(-3, clip: pier)
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 0)
    }

    @Test func removingTheSelectionDropsItAndTheProblemShows() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.remove(.main(rig.clip(PreviewEditorIDs.friends).id))
        #expect(rig.main.count == 3)
        for clip in rig.main { rig.session.remove(.main(clip.id)) }
        #expect(rig.main.isEmpty)
        #expect(rig.session.problems.contains(.empty))
        #expect(rig.session.timeline.overlay.isEmpty)               // no main track: the overlay has nothing to sit on
    }

    @Test func tooManyClipsIsAProblemNotAFailure() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.sources[PreviewEditorIDs.pier]!
        rig.session.add(Array(repeating: pier, count: 60), at: nil)
        #expect(rig.session.problems.contains(.tooManyClips))
    }
}

// MARK: - the overlay

@MainActor
struct EditSessionOverlayTests {
    @Test func anOverlayIsRefusedInsideAnotherAndCutAtTheNext() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let dance = rig.sources[PreviewEditorIDs.dance]!
        #expect(!rig.session.addOverlay(dance, atFrame: 100))           // inside the one at 90...180
        #expect(rig.session.timeline.overlay.count == 1)
        #expect(rig.session.addOverlay(dance, atFrame: 30))             // 60 frames of room before the next one
        #expect(rig.session.timeline.overlay.count == 2)
        let added = rig.session.timeline.overlay[0]
        #expect(added.at == 1 && added.out == 2 && added.item == PreviewEditorIDs.dance)
        #expect(rig.session.timeline.overlay[1].at == 3)
        #expect(rig.session.problems.isEmpty)
        #expect(rig.session.selection == .overlay(added.id))
    }

    @Test func aPhotoStaysThreeSecondsAndIsPlacedInsideTheCanvas() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.sources[PreviewEditorIDs.photo]!, atFrame: 300))
        let photo = rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.photo }!
        #expect(photo.at == 10 && photo.length == 3 && photo.muted)
        #expect(photo.frame.y + EditGeometry.overlayHeightFraction(
            display: PixelSize(w: 1600, h: 1200), frame: photo.frame, canvas: rig.session.timeline.canvas) <= 1.0001)
    }

    @Test func anOverlayCannotBeAddedWithoutRoom() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        // two frames from the end is under 0.1 s
        #expect(!rig.session.addOverlay(rig.sources[PreviewEditorIDs.dance]!, atFrame: 778))
    }

    @Test func movingStopsAtTheNeighboursAndTheEnd() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let id = rig.overlayID
        rig.session.moveOverlay(id: id, toFrame: 10_000)
        #expect(rig.session.timeline.overlay[0].at == 23)               // 780 - 90 frames = 690 = 23 s
        rig.session.endGesture()
        rig.session.moveOverlay(id: id, toFrame: -5)
        #expect(rig.session.timeline.overlay[0].at == 0)
    }

    @Test func aSecondOverlayCannotBeDraggedOverTheFirst() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.sources[PreviewEditorIDs.photo]!, atFrame: 300))
        let photo = rig.session.timeline.overlay[1].id
        rig.session.moveOverlay(id: photo, toFrame: 100)
        let timing = rig.session.timing
        #expect(timing.overlay[1].start >= timing.overlay[0].start + timing.overlay[0].frames)
        #expect(rig.session.problems.isEmpty)
    }

    @Test func lengthIsBetweenTenthsOfASecondAndTheRoom() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let id = rig.overlayID
        rig.session.setOverlayLength(id: id, seconds: 0.01)
        #expect(rig.session.timeline.overlay[0].length == 0.1)
        rig.session.endGesture()
        rig.session.setOverlayLength(id: id, seconds: 9_999)
        #expect(rig.session.timeline.overlay[0].length == 23)           // from 3 s to the end at 26 s
        #expect(rig.session.problems.isEmpty)
    }

    @Test func theFrameIsClampedInsideTheCanvas() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setOverlayFrame(id: rig.overlayID, EditFrame(x: 0.9, y: 0.99, w: 0.35))
        let f = rig.session.timeline.overlay[0].frame
        #expect(f == EditGeometry.clampInside(
            EditFrame(x: 0.9, y: 0.99, w: 0.35), display: PixelSize(w: 480, h: 360), canvas: rig.session.timeline.canvas))
        #expect(f.x + f.w <= 1.0001 && rig.session.problems.isEmpty)
    }

    @Test func opacityVolumeAndMute() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let id = rig.overlayID
        rig.session.setOverlayOpacity(id: id, 0.01)
        rig.session.setOverlayVolume(id: id, 2)
        rig.session.setOverlayMuted(id: id, false)
        let o = rig.session.timeline.overlay[0]
        #expect(o.opacity == 0.1 && o.volume == 1 && !o.muted)
    }

    @Test func aGifOverlayCannotBeTrimmedLikeAVideo() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let before = rig.session.timeline
        rig.session.trimOverlay(id: rig.overlayID, in: 0.5, out: nil)
        #expect(rig.session.timeline == before)
    }

    @Test func shrinkingTheMainTrackCutsTheOverlayAtTheEnd() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        // the overlay runs 3 s...6 s; leave the first 4 s of the track only
        for clip in rig.main.dropFirst() { rig.session.remove(.main(clip.id)) }
        rig.session.trim(clip: rig.main[0].id, in: nil, out: 4)
        #expect(rig.session.timing.frames == 120)
        let o = rig.session.timeline.overlay
        #expect(o.count == 1 && o[0].at == 3 && o[0].length == 1)
        #expect(rig.session.problems.isEmpty)
    }

    @Test func anOverlayWithNoRoomLeftIsDropped() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        for clip in rig.main.dropFirst() { rig.session.remove(.main(clip.id)) }
        rig.session.trim(clip: rig.main[0].id, in: nil, out: 3.05)       // 92 frames: two frames of room, under the three it needs
        #expect(rig.session.timeline.overlay.isEmpty)
    }
}

// MARK: - canvas, title, undo

@MainActor
struct EditSessionHistoryTests {
    @Test func theCanvasChangesTheFramesAndAnInvalidSizeIsIgnored() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setCanvas(EditCanvas(w: 1280, h: 720, fps: 60))
        #expect(rig.session.timing.fps == 60 && rig.session.timing.frames == 1_560)
        #expect(rig.session.problems.isEmpty)
        let before = rig.session.timeline
        rig.session.setCanvas(EditCanvas(w: 1000, h: 1000, fps: 30))
        rig.session.setCanvas(EditCanvas(w: 1080, h: 1920, fps: 24))
        #expect(rig.session.timeline == before)
    }

    @Test func renamingTrimsAndIgnoresAnEmptyName() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.rename("  new name \n")
        #expect(rig.session.project.title == "new name")
        #expect(rig.session.saveState == .unsaved)
        rig.session.rename("   ")
        #expect(rig.session.project.title == "new name")
    }

    @Test func undoAndRedoWalkTheEdits() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let original = rig.session.timeline
        rig.session.add([rig.sources[PreviewEditorIDs.surf]!], at: nil)
        let edited = rig.session.timeline
        #expect(rig.session.canUndo && !rig.session.canRedo)
        rig.session.undo()
        #expect(rig.session.timeline == original && rig.session.canRedo && !rig.session.canUndo)
        rig.session.redo()
        #expect(rig.session.timeline == edited && !rig.session.canRedo)
        rig.session.undo()
        rig.session.remove(.main(rig.main[0].id))                       // a new edit clears the redo stack
        #expect(!rig.session.canRedo)
    }

    @Test func aDragIsOneUndoStepUntilTheGestureEnds() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setVolume(0.5, clip: pier)
        rig.session.setVolume(0.4, clip: pier)
        rig.session.setVolume(0.3, clip: pier)
        rig.session.undo()
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 1)
        #expect(!rig.session.canUndo)
        rig.session.redo()
        rig.session.endGesture()
        rig.session.setVolume(0.2, clip: pier)
        rig.session.undo()
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 0.3)
    }

    @Test func aPauseBetweenTwoDragsMakesTwoSteps() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setVolume(0.5, clip: pier)
        rig.h.clock.jump(by: 5)
        rig.session.setVolume(0.4, clip: pier)
        rig.session.undo()
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 0.5)
    }

    @Test func theUndoStackHoldsAHundredSteps() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        var muted = false
        for _ in 0..<120 {
            muted.toggle()
            rig.session.setMuted(muted, clip: pier)
        }
        var undone = 0
        while rig.session.canUndo {
            rig.session.undo()
            undone += 1
            if undone > 200 { break }
        }
        #expect(undone == 100)
    }

    @Test func selectionFollowsTheClipThatWasRemoved() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let id = rig.clip(PreviewEditorIDs.friends).id
        rig.session.selection = .main(id)
        rig.session.remove(.main(id))
        #expect(rig.session.selection == .none)
    }

    @Test func theToolDefaultsToSelect() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.tool == .select)
        rig.session.tool = .blade
        #expect(rig.session.tool == .blade)
    }

    @Test func thePlayheadStaysInsideTheTimeline() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.seek(frame: 5_000)
        #expect(rig.session.playhead == 779)
        rig.session.seek(frame: -4)
        #expect(rig.session.playhead == 0)
        rig.session.step(frames: 3)
        #expect(rig.session.playhead == 3)
        rig.session.seek(frame: 700)
        for clip in rig.main.dropFirst(2) { rig.session.remove(.main(clip.id)) }
        #expect(rig.session.playhead == rig.session.timing.frames - 1)
    }
}

// MARK: - saving

@MainActor
struct EditSessionSaveTests {
    @Test func anEditIsSavedAfterAQuietSecond() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        #expect(rig.session.saveState == .unsaved && rig.session.saveCalls == 0)
        await rig.driveUntilSaved()
        #expect(rig.session.saveState == .saved && rig.session.saveCalls == 1)
        #expect(rig.session.project.revision == 5)
        #expect(rig.server.timeline(of: PreviewEditorIDs.beach)?.main[0].volume == 0.5)
        #expect(rig.h.clock.elapsed >= 1)
    }

    @Test func eachEditRestartsTheSecond() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setVolume(0.5, clip: pier)
        rig.h.clock.jump(by: 0.5)
        rig.session.setVolume(0.4, clip: pier)
        await rig.driveUntilSaved()
        #expect(rig.session.saveCalls == 1)
        #expect(rig.server.timeline(of: PreviewEditorIDs.beach)?.main[0].volume == 0.4)
        #expect(rig.h.clock.elapsed >= 1.5)
    }

    @Test func twoQuietEditsAreTwoSavesAndTwoRevisions() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let pier = rig.clip(PreviewEditorIDs.pier).id
        rig.session.setVolume(0.5, clip: pier)
        await rig.driveUntilSaved()
        rig.session.endGesture()
        rig.session.setVolume(0.25, clip: pier)
        await rig.driveUntilSaved()
        #expect(rig.session.saveCalls == 2 && rig.session.project.revision == 6)
    }

    @Test func aRenameIsSentWithTheNextSave() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.rename("weekend")
        await rig.driveUntilSaved()
        #expect(rig.server.project(PreviewEditorIDs.beach)?.title == "weekend")
        #expect(rig.session.project.title == "weekend")
    }

    @Test func aFailedSaveIsTriedAgainAfterTwoThenFiveSeconds() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.server.failNextSaves(2)
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        await rig.driveUntilSaved()
        #expect(rig.session.saveState == .saved && rig.session.saveCalls == 3)
        #expect(rig.h.clock.elapsed >= 8 && rig.h.clock.elapsed < 8.5)      // 1 s of quiet, then 2 s, then 5 s
        #expect(rig.session.project.revision == 5)
    }

    @Test func aRefusedSaveStaysFailedUntilTheNextChange() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        for clip in rig.main { rig.session.remove(.main(clip.id)) }
        await rig.h.drive(until: { if case .failed = rig.session.saveState { return true } else { return false } })
        #expect(rig.session.saveState == .failed(.invalid(.empty)))
        #expect(rig.session.saveCalls == 0)                              // the server would refuse it: never sent
        rig.session.undo()
        await rig.driveUntilSaved()
        #expect(rig.session.saveState == .saved)
    }

    @Test func aConflictStopsTheAutosaveAndShowsTheServersProject() async throws {
        let rig = try await Rig(.editorConflict)
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        await rig.h.drive(until: { if case .conflict = rig.session.saveState { return true } else { return false } })
        guard case .conflict(let theirs) = rig.session.saveState else {
            Issue.record("expected a conflict, got \(rig.session.saveState)")
            return
        }
        #expect(theirs.revision == 5 && theirs.title == "beach day (iphone)")
        rig.session.setVolume(0.3, clip: rig.clip(PreviewEditorIDs.pier).id)
        await rig.h.drive(until: { false }, maxVirtualSeconds: 20)
        #expect(rig.session.saveCalls == 1)
        if case .conflict = rig.session.saveState {} else { Issue.record("the conflict should stay until picked") }
    }

    @Test func keepingMineSavesOverTheServersRevisionAndTitle() async throws {
        let rig = try await Rig(.editorConflict)
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        await rig.h.drive(until: { if case .conflict = rig.session.saveState { return true } else { return false } })
        await rig.session.resolveConflict(keepMine: true)
        #expect(rig.session.saveState == .saved)
        #expect(rig.session.project.revision == 6)
        #expect(rig.server.timeline(of: PreviewEditorIDs.beach)?.main[0].volume == 0.5)
        #expect(rig.server.project(PreviewEditorIDs.beach)?.title == "beach day edit")
    }

    @Test func takingTheirsLoadsTheServersVersionAndKeepsMineOneUndoAway() async throws {
        let rig = try await Rig(.editorConflict)
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        await rig.h.drive(until: { if case .conflict = rig.session.saveState { return true } else { return false } })
        await rig.session.resolveConflict(keepMine: false)
        #expect(rig.session.saveState == .saved)
        #expect(rig.session.project.title == "beach day (iphone)" && rig.session.project.revision == 5)
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 1)
        #expect(rig.session.canUndo)
        rig.session.undo()
        #expect(rig.clip(PreviewEditorIDs.pier).volume == 0.5)
    }

    @Test func closingFlushesTheAutosave() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        let settled = await rig.session.settle()
        #expect(settled && rig.session.saveState == .saved && rig.session.saveCalls == 1)
    }

    @Test func closingWithAFailingServerReportsUnsavedChanges() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.server.failNextSaves(10)
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        let settled = await rig.session.settle()
        #expect(!settled)
        if case .failed = rig.session.saveState {} else { Issue.record("expected failed, got \(rig.session.saveState)") }
    }
}

// MARK: - rendering

@MainActor
struct EditSessionRenderTests {
    @Test func renderSavesFirstAndThenFollowsTheRenderToTheEnd() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        let r = try await rig.session.render()
        #expect(rig.server.saveCount == 1)
        #expect(r.status == .queued && r.revision == 5 && r.projectID == PreviewEditorIDs.beach)
        #expect(rig.session.activeRender?.id == r.id && rig.session.project.render?.id == r.id)
        await rig.h.drive(until: { rig.session.activeRender?.status == .done })
        let done = try #require(rig.session.activeRender)
        #expect(done.status == .done && done.itemID != nil && done.progress == 1)
        #expect(rig.h.clock.elapsed >= 20)
    }

    @Test func aRenderThatFailsEndsWithTheServersReason() async throws {
        let rig = try await Rig(.editorRenderFails)
        defer { rig.finish() }
        _ = try await rig.session.render()
        await rig.h.drive(until: { rig.session.activeRender?.status == .error })
        #expect(rig.session.activeRender?.error == "error.edit.render_failed")
        #expect(rig.session.activeRender?.progress == 0.6)
    }

    @Test func aTimelineWithAProblemIsNotSent() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        for clip in rig.main { rig.session.remove(.main(clip.id)) }
        do {
            _ = try await rig.session.render()
            Issue.record("render should have thrown")
        } catch {
            #expect(EditError.from(error) == .invalid(.empty))
        }
        #expect(rig.client.editorState.calls.contains("POST /edits/\(PreviewEditorIDs.beach)/render") == false)
    }

    @Test func renderingTheSameRevisionTwiceAnswersTheSameRender() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        let first = try await rig.session.render()
        let second = try await rig.session.render()
        #expect(first.id == second.id)
    }

    @Test func renderWaitsForASaveThatIsAlreadyOut() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        async let flushing: Void = rig.session.flush()
        let r = try await rig.session.render()
        await flushing
        #expect(r.revision == rig.session.project.revision && rig.session.saveState == .saved)
    }

    @Test func aConflictingSaveStopsTheRender() async throws {
        let rig = try await Rig(.editorConflict)
        defer { rig.finish() }
        rig.session.setVolume(0.5, clip: rig.clip(PreviewEditorIDs.pier).id)
        do {
            _ = try await rig.session.render()
            Issue.record("render should have thrown")
        } catch {
            if case .conflict(let theirs) = EditError.from(error) {
                #expect(theirs.revision == 5)
            } else {
                Issue.record("expected a conflict, got \(error)")
            }
        }
    }
}
