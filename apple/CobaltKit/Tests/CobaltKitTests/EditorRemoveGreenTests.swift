import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// Remove green (CONTRACT-EDITOR 15.4), the picture tools of 15.1 (fit, turn 90°, reset, up and down) and the tool row's
// fit rule. A session on a version 2 timeline, as in EditorTimelineV2Tests.

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)
private let video = "AAAAAAAAAAAAAAAA"
private let picture = "BBBBBBBBBBBBBBBB"

private func lane(
    _ id: String, _ lane: Int, at: Double = 0, out: Double = 2, item: String = video, key: EditChromaKey? = nil, hidden: Bool = false,
    frame: EditFrame? = nil
) -> EditLaneClip {
    EditLaneClip(id: id, item: item, lane: lane, at: at, in: 0, out: out, frame: frame, hidden: hidden, key: key)
}

@MainActor
struct EditorRemoveGreenTests {
    private func open(_ clips: [EditLaneClip], version: Int = 2) -> EditSession {
        let h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = version
        h.ctx.capabilities.limits.editOverlayTracks = 64
        let timeline = EditTimeline(canvas: story, clips: clips)
        let project = EditProject(
            id: "AbCdEfGhIjKlMnOp", title: "green", revision: 1, timeline: timeline, canvas: story, duration: 4,
            clipCount: clips.count, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var summary = project
        summary.timeline = nil
        let cache = EditSourceCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("green-\(UUID().uuidString)"),
            client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        return EditSession(
            project: summary, timeline: timeline,
            sources: [
                video: EditSource(id: video, name: "a.mp4", kind: .video, width: 1920, height: 1080, duration: 10),
                picture: EditSource(id: picture, name: "b.png", kind: .photo, width: 1080, height: 1920),
            ],
            context: h.ctx, cache: cache, onProject: { _ in }, onRender: { _ in })
    }

    private func clip(_ session: EditSession, _ id: String) -> EditLaneClip? {
        session.timeline.clips.first { $0.id == id }
    }

    @Test func theKeyIsTheGreenPreset() {
        let session = open([lane("a", 0)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.key == EditChromaKey())
        #expect(clip(session, "a")?.key?.color == EditChromaKey.green)
        #expect(clip(session, "a")?.lane == 0)
    }

    @Test func aClipUnderNothingStaysAndOnlyLowerClipsDoNotMoveIt() {
        let session = open([lane("low", 0), lane("mid", 1), lane("a", 2), lane("later", 3, at: 5)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 2)
        #expect(clip(session, "a")?.key != nil)
        #expect(clip(session, "low")?.lane == 0 && clip(session, "mid")?.lane == 1)
    }

    @Test func aClipUnderOthersMovesAboveTheTopOneItOverlaps() {
        let session = open([lane("a", 0), lane("b", 1), lane("c", 3, at: 1, out: 2)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 4)
        #expect(clip(session, "a")?.key != nil)
        // the others stay where they were
        #expect(clip(session, "b")?.lane == 1 && clip(session, "c")?.lane == 3)
    }

    @Test func theLowestFreeLaneIsChosenWhenThereAreGaps() {
        // lanes 1 and 3 overlap in time, lane 2 is empty (below the top one, so not for this clip), lane 4 holds a clip that
        // is not there at that time (free)
        let session = open([
            lane("a", 0), lane("b", 1), lane("c", 3), lane("far", 4, at: 6), lane("also", 5, at: 7), lane("top", 6, at: 8),
        ])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 4)
        // two clips share lane 4 now, a thing the lane allows only when they do not overlap
        #expect(session.timeline.clips.filter { $0.lane == 4 }.count == 2)

        // lane 4 taken in the clip's time: the next one up
        let busy = open([lane("a", 0), lane("b", 1), lane("c", 4), lane("up", 5, at: 6)])
        defer { busy.tearDown() }
        #expect(busy.removeGreen(clipID: "a"))
        #expect(clip(busy, "a")?.lane == 5)
    }

    @Test func aHiddenClipAboveDoesNotCoverIt() {
        let session = open([lane("a", 0), lane("ghost", 1, hidden: true)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 0)
    }

    @Test func aLiftKeepsTheOtherLaneZeroClipsWhereTheyWere() {
        let session = open([lane("a", 0, at: 0, out: 2), lane("next", 0, at: 2, out: 2), lane("b", 1)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 2)
        #expect(clip(session, "next")?.at == 2)
    }

    @Test func undoPutsTheKeyAndTheLaneBack() {
        let clips = [lane("a", 0), lane("b", 1)]
        let session = open(clips)
        defer { session.tearDown() }
        let before = session.timeline
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 2 && clip(session, "a")?.key != nil)
        // the key and the lift are two edits of the session (see EditSession+RemoveGreen): two undos
        session.undo()
        session.undo()
        #expect(session.timeline == before)
        #expect(!session.canUndo)
    }

    @Test func aClipThatAlreadyHasAKeyKeepsItAndIsStillLifted() {
        let mine = EditChromaKey(color: EditChromaKey.blue, similarity: 0.35, blend: 0.1, spill: 0.2)
        let session = open([lane("a", 0, key: mine), lane("b", 1)])
        defer { session.tearDown() }
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.key == mine)
        #expect(clip(session, "a")?.lane == 2)
        session.undo()
        #expect(clip(session, "a")?.lane == 0)
        #expect(!session.canUndo)
    }

    @Test func theSelectionFollowsTheClipUpAndOffLaneZero() {
        let session = open([lane("a", 0), lane("b", 1)])
        defer { session.tearDown() }
        session.selection = .main("a")
        #expect(session.removeGreen(clipID: "a"))
        #expect(session.selection == .overlay("a"))
    }

    @Test func aPictureAMissingClipAndALockedLaneAreRefused() {
        let session = open([lane("a", 0), lane("p", 1, item: picture), lane("b", 2)])
        defer { session.tearDown() }
        let before = session.timeline
        #expect(!session.canRemoveGreen(clipID: "p"))
        #expect(!session.removeGreen(clipID: "p"))
        #expect(!session.removeGreen(clipID: "nope"))
        session.setTrackLocked(1, true)           // lane 2
        #expect(!session.removeGreen(clipID: "b"))
        #expect(session.timeline == before)
    }

    @Test func aLockedLaneIsSkippedWhenLifting() {
        let session = open([lane("a", 0), lane("b", 1)])
        defer { session.tearDown() }
        session.setTrackLocked(1, true)           // lane 2
        #expect(session.removeGreen(clipID: "a"))
        #expect(clip(session, "a")?.lane == 3)
    }
}

// MARK: - the picture tools

@MainActor
struct EditorPictureToolsTests {
    private func open(_ clips: [EditLaneClip]) -> EditSession {
        let h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = 2
        h.ctx.capabilities.limits.editOverlayTracks = 64
        let timeline = EditTimeline(canvas: story, clips: clips)
        let project = EditProject(
            id: "AbCdEfGhIjKlMnOp", title: "tools", revision: 1, timeline: timeline, canvas: story, duration: 4,
            clipCount: clips.count, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var summary = project
        summary.timeline = nil
        let cache = EditSourceCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)"),
            client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        return EditSession(
            project: summary, timeline: timeline,
            sources: [
                video: EditSource(id: video, name: "a.mp4", kind: .video, width: 1920, height: 1080, duration: 10),
                picture: EditSource(id: picture, name: "b.png", kind: .photo, width: 1080, height: 1920),
            ],
            context: h.ctx, cache: cache, onProject: { _ in }, onRender: { _ in })
    }

    private func frame(_ session: EditSession, _ id: String) -> EditFrame? {
        session.timeline.clips.first { $0.id == id }?.frame
    }

    @Test func fitPutsTheWholePictureInTheCanvasNotTurned() throws {
        let session = open([lane("a", 0), lane("c", 1, frame: EditFrame(x: -0.5, y: 0.2, w: 2, r: 40))])
        defer { session.tearDown() }
        #expect(session.fitClipToCanvas(id: "c"))
        let expected = try #require(EditGeometry.fitFrame(
            display: PixelSize(w: 1920, h: 1080), crop: nil, fit: .fit, canvas: story))
        #expect(frame(session, "c") == expected)
        #expect(frame(session, "c")?.r == 0)
        // the lane 0 clip with no frame gets the box too, one step each
        #expect(session.fitClipToCanvas(id: "a"))
        #expect(frame(session, "a") == expected)
        session.undo()
        #expect(frame(session, "a") == nil)
        session.undo()
        #expect(frame(session, "c")?.r == 40)
    }

    @Test func turn90StepsAroundAndWrapsAndEachTapIsOneStep() throws {
        let session = open([lane("a", 0), lane("c", 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))])
        defer { session.tearDown() }
        #expect(session.turnClip90(id: "c"))
        #expect(frame(session, "c")?.r == 90)
        #expect(session.turnClip90(id: "c"))
        #expect(frame(session, "c")?.r == 180)
        #expect(session.turnClip90(id: "c"))
        #expect(frame(session, "c")?.r == -90)
        #expect(session.turnClip90(id: "c"))
        #expect(frame(session, "c")?.r == 0)
        session.undo()
        #expect(frame(session, "c")?.r == -90)
        // a clip with no frame turns from the box fill gave it
        let box = try #require(session.frameBox(ofClip: "a"))
        #expect(session.turnClip90(id: "a"))
        #expect(frame(session, "a") == EditFrame(x: box.x, y: box.y, w: box.w, r: 90))
    }

    @Test func resetGoesBackToTheBoxFillGivesAndUndoesInOneStep() throws {
        let session = open([lane("a", 0), lane("c", 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3, r: 30))])
        defer { session.tearDown() }
        let fill = try #require(EditGeometry.fitFrame(display: PixelSize(w: 1920, h: 1080), crop: nil, fit: .fill, canvas: story))
        #expect(session.resetClipFrame(id: "c"))
        #expect(frame(session, "c") == fill)
        session.undo()
        #expect(frame(session, "c")?.r == 30)
    }

    @Test func broughtUpAndSentDownKeepTheSelectionOnTheClip() {
        let session = open([lane("a", 0), lane("b", 2)])
        defer { session.tearDown() }
        session.selection = .main("a")
        #expect(session.moveClipLayerKeepingSelection(id: "a", by: 1))
        #expect(session.laneOfClip(id: "a") == 1)
        #expect(session.selection == .overlay("a"))
        #expect(session.moveClipLayerKeepingSelection(id: "a", by: -1))
        #expect(session.laneOfClip(id: "a") == 0)
        #expect(session.selection == .main("a"))
    }

    @Test func aTakenSpotRefusesBringUp() {
        let session = open([lane("a", 1), lane("b", 2)])
        defer { session.tearDown() }
        session.selection = .overlay("a")
        #expect(!session.moveClipLayerKeepingSelection(id: "a", by: 1))
        #expect(session.laneRefusal == EditLanes.spotTakenMessage)
        #expect(session.selection == .overlay("a"))
        #expect(session.laneOfClip(id: "a") == 1)
    }
}

// MARK: - the tool row's fit

struct EditorToolFitTests {
    @Test func slotsAre44PointsEach() {
        #expect(EditorToolFit.slots(length: 402) == 9)
        #expect(EditorToolFit.slots(length: 375) == 8)
        #expect(EditorToolFit.slots(length: 320) == 7)
        #expect(EditorToolFit.slots(length: 44) == 0)
        #expect(EditorToolFit.slots(length: 48) == 1)
        #expect(EditorToolFit.slots(length: 0) == 0)
        #expect(EditorToolFit.slots(length: -5) == 0)
    }

    @Test func everythingShownWhenItFits() {
        // a clip: 8 tools and done, 9 slots
        #expect(EditorToolFit.split(items: 8, done: true, length: 402) == .init(shown: 8, more: false))
        // nothing selected: five tools, no done
        #expect(EditorToolFit.split(items: 5, done: false, length: 320) == .init(shown: 5, more: false))
        // picked on the picture: seven and done, 8 slots
        #expect(EditorToolFit.split(items: 7, done: true, length: 375) == .init(shown: 7, more: false))
    }

    @Test func theRestGoesBehindMoreAndDoneKeepsItsSlot() {
        // 8 tools and done in 8 slots: more and done take two, six tools stay
        #expect(EditorToolFit.split(items: 8, done: true, length: 375) == .init(shown: 6, more: true))
        // 7 slots (320 pt)
        #expect(EditorToolFit.split(items: 8, done: true, length: 320) == .init(shown: 5, more: true))
        // a short rail: 4 slots
        #expect(EditorToolFit.split(items: 8, done: true, length: 180) == .init(shown: 2, more: true))
        // no room at all: only the menu
        #expect(EditorToolFit.split(items: 8, done: true, length: 60) == .init(shown: 0, more: true))
        #expect(EditorToolFit.split(items: 5, done: false, length: 130) == .init(shown: 1, more: true))
    }
}

// MARK: - the inspector's page

struct EditorInspectorPageTests {
    @Test func nothingSelectedIsTheProjectWhateverTheStoredPage() {
        for page in EditorUI.Page.allCases where page != .library {
            #expect(page.resolved(selection: .none, effectsOpen: false) == .project)
        }
        #expect(EditorUI.Page.library.resolved(selection: .none, effectsOpen: false) == .library)
    }

    @Test func aMainClipHasTheClipPageAndALayerTheLayerPage() {
        #expect(EditorUI.Page.project.resolved(selection: .main("a"), effectsOpen: false) == .clip)
        #expect(EditorUI.Page.layer.resolved(selection: .main("a"), effectsOpen: false) == .clip)
        #expect(EditorUI.Page.project.resolved(selection: .overlay("a"), effectsOpen: false) == .layer)
        #expect(EditorUI.Page.clip.resolved(selection: .overlay("a"), effectsOpen: false) == .layer)
        // a layer has no speed or main-clip crop
        #expect(EditorUI.Page.speed.resolved(selection: .overlay("a"), effectsOpen: false) == .layer)
        #expect(EditorUI.Page.crop.resolved(selection: .overlay("a"), effectsOpen: false) == .layer)
    }

    @Test func aToolsPageStaysForTheSelectedClip() {
        for page in [EditorUI.Page.sound, .speed, .crop, .trim] {
            #expect(page.resolved(selection: .main("a"), effectsOpen: false) == page)
        }
        #expect(EditorUI.Page.sound.resolved(selection: .overlay("a"), effectsOpen: false) == .sound)
        #expect(EditorUI.Page.trim.resolved(selection: .overlay("a"), effectsOpen: false) == .trim)
    }

    @Test func anOpenEffectsMenuIsTheEffectsPage() {
        #expect(EditorUI.Page.clip.resolved(selection: .main("a"), effectsOpen: true) == .effects)
        #expect(EditorUI.Page.project.resolved(selection: .none, effectsOpen: true) == .effects)
        #expect(EditorUI.Page.library.resolved(selection: .main("a"), effectsOpen: true) == .library)
    }
}

@MainActor
struct EditorRemoveGreenOlderServerTests {
    @Test func aServerThatSavesOnlyVersionOneCannotKeepAKeyOnLaneZero() {
        let h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = 1
        let clips = [lane("a", 0), lane("b", 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))]
        let timeline = EditTimeline(canvas: story, clips: clips)
        let project = EditProject(
            id: "AbCdEfGhIjKlMnOp", title: "old", revision: 1, timeline: nil, canvas: story, duration: 4,
            clipCount: 2, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let cache = EditSourceCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString)"),
            client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        let session = EditSession(
            project: project, timeline: timeline,
            sources: [video: EditSource(id: video, name: "a.mp4", kind: .video, width: 1920, height: 1080, duration: 10)],
            context: h.ctx, cache: cache, onProject: { _ in }, onRender: { _ in })
        defer { session.tearDown() }
        let before = session.timeline
        #expect(!session.canRemoveGreen(clipID: "a"))
        #expect(!session.removeGreen(clipID: "a"))
        #expect(session.timeline == before)
    }
}
