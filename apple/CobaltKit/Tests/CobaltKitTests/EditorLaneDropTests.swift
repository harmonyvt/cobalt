import Foundation
import Testing
@testable import CobaltKit

// The equal-lane drag: which row the pointer is on, where the time snaps, and when the menu dims a row.

struct EditorLaneDropTests {
    // Mac mock: 24 pt zone, 30 pt rows, four lanes. Lane 3 is the top row, lane 0 the bottom.
    private let macZone = 24.0
    private let macRow = 30.0

    @Test func theZoneAboveTheTopLaneIsANewLane() {
        #expect(EditLaneDrop.hit(y: 0, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .newLane)
        #expect(EditLaneDrop.hit(y: 23.9, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .newLane)
        #expect(EditLaneDrop.hit(y: -8, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .newLane)
        #expect(EditLaneDrop.hit(y: 10, laneCount: 0, rowHeight: macRow, zoneHeight: macZone) == .newLane)
    }

    @Test func rowsRunFromTheTopLaneDownToLaneZero() {
        #expect(EditLaneDrop.hit(y: 24, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .lane(3))
        #expect(EditLaneDrop.hit(y: 24 + 30, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .lane(2))
        #expect(EditLaneDrop.hit(y: 24 + 60, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .lane(1))
        #expect(EditLaneDrop.hit(y: 24 + 90, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .lane(0))
        // Past the last row stays on the bottom lane.
        #expect(EditLaneDrop.hit(y: 400, laneCount: 4, rowHeight: macRow, zoneHeight: macZone) == .lane(0))
    }

    @Test func oneLaneStillHasTheZoneAndTheBottomRow() {
        #expect(EditLaneDrop.hit(y: 10, laneCount: 1, rowHeight: 34, zoneHeight: 26) == .newLane)
        #expect(EditLaneDrop.hit(y: 26, laneCount: 1, rowHeight: 34, zoneHeight: 26) == .lane(0))
        #expect(EditLaneDrop.hit(y: 50, laneCount: 1, rowHeight: 34, zoneHeight: 26) == .lane(0))
    }

    @Test func snapPullsTheStartOrTheEndOntoAnEdge() {
        let points = [0.0, 8, 9, 14]
        let ontoStart = EditLaneDrop.snap(start: 8.2, length: 6, points: points, threshold: 0.4)
        #expect(ontoStart.snapped)
        #expect(abs(ontoStart.value - 8) < 0.0001)

        // The end (13.7) is closer to 14 than the start is to anything.
        let ontoEnd = EditLaneDrop.snap(start: 7.7, length: 6, points: points, threshold: 0.4)
        #expect(ontoEnd.snapped)
        #expect(abs(ontoEnd.value - 8) < 0.0001)

        let playhead = EditLaneDrop.snap(start: 3, length: 6, points: points, threshold: 0.4)
        #expect(playhead.snapped)
        #expect(abs(playhead.value - 3) < 0.0001)

        let free = EditLaneDrop.snap(start: 5, length: 2, points: points, threshold: 0.4)
        #expect(!free.snapped)
        #expect(abs(free.value - 5) < 0.0001)
    }

    @Test func snapNeverStartsBeforeZero() {
        let pulled = EditLaneDrop.snap(start: -0.2, length: 4, points: [0], threshold: 0.4)
        #expect(pulled.snapped)
        #expect(pulled.value == 0)
        let clamped = EditLaneDrop.snap(start: -1, length: 2, points: [10], threshold: 0.1)
        #expect(!clamped.snapped)
        #expect(clamped.value == 0)
    }

    @Test func aNewLaneFitsUntilLane63IsOccupied() {
        #expect(EditLaneDrop.canInsertLane(above: 2, occupied: [0, 2]))
        #expect(!EditLaneDrop.canInsertLane(above: 63, occupied: [0, 63]))
        #expect(!EditLaneDrop.canInsertLane(above: 62, occupied: [0, 63]))
        #expect(EditLaneDrop.canInsertLane(above: 62, occupied: [0, 62]))
    }

    @Test func autoscrollOnlyNudgesNearTheEdges() {
        #expect(EditLaneDrop.autoscroll(position: 10, viewport: 300, edge: 28, step: 0.25) == -0.25)
        #expect(EditLaneDrop.autoscroll(position: 280, viewport: 300, edge: 28, step: 0.25) == 0.25)
        #expect(EditLaneDrop.autoscroll(position: 150, viewport: 300, edge: 28, step: 0.25) == 0)
        #expect(EditLaneDrop.autoscroll(position: 10, viewport: 0, edge: 28, step: 0.25) == 0)
    }
}

struct EditorLaneMenuTests {
    private func input(
        savesV2: Bool = true, lane: Int = 1, fromLocked: Bool = false, upInRange: Bool = true, downInRange: Bool = true,
        upLocked: Bool = false, downLocked: Bool = false, upTaken: Bool = false, downTaken: Bool = false,
        canNewLane: Bool = true, duplicateBlocked: Bool = false, isVideo: Bool = true, isPicture: Bool = false,
        playheadInside: Bool = true
    ) -> LaneMenuInput {
        LaneMenuInput(
            savesV2: savesV2, lane: lane, fromLocked: fromLocked, upInRange: upInRange, downInRange: downInRange,
            upLocked: upLocked, downLocked: downLocked, upTaken: upTaken, downTaken: downTaken, canNewLane: canNewLane,
            duplicateBlocked: duplicateBlocked, isVideo: isVideo, isPicture: isPicture, playheadInside: playheadInside)
    }

    private func item(_ items: [LaneMenuItem], _ action: LaneMenuAction) -> LaneMenuItem {
        items.first { $0.action == action }!
    }

    @Test func aFreeVideoOffersEveryAction() {
        let items = EditLaneMenu.items(input())
        #expect(items.map(\.action) == LaneMenuAction.allCases)
        #expect(items.allSatisfy(\.enabled))
        #expect(items.allSatisfy { $0.reason == nil })
    }

    @Test func aLockedLaneDimsEveryRowWithTheLockLine() {
        let items = EditLaneMenu.items(input(fromLocked: true))
        #expect(items.allSatisfy { !$0.enabled && $0.reason == EditLanes.laneLockedMessage })
    }

    @Test func aVersion1ServerDimsLaneChangesAndALane0Hide() {
        let higher = EditLaneMenu.items(input(savesV2: false, lane: 2))
        for action in [LaneMenuAction.newLane, .layerUp, .layerDown] {
            let row = item(higher, action)
            #expect(!row.enabled)
            #expect(row.reason == EditLanes.needsServerMessage)
        }
        #expect(item(higher, .hide).enabled)
        #expect(item(higher, .effect).enabled)

        let bottom = EditLaneMenu.items(input(savesV2: false, lane: 0, downInRange: false))
        #expect(!item(bottom, .hide).enabled)
        #expect(item(bottom, .hide).reason == EditLanes.needsServerMessage)
    }

    @Test func theBottomLaneCannotMoveDownAndATakenSpotCannotMoveUp() {
        let bottom = EditLaneMenu.items(input(lane: 0, downInRange: false))
        #expect(!item(bottom, .layerDown).enabled)
        #expect(item(bottom, .layerDown).reason == EditLaneMenu.alreadyBottom)

        let taken = EditLaneMenu.items(input(upTaken: true))
        #expect(!item(taken, .layerUp).enabled)
        #expect(item(taken, .layerUp).reason == EditLanes.spotTakenMessage)

        let full = EditLaneMenu.items(input(upInRange: false, canNewLane: false))
        #expect(item(full, .layerUp).reason == EditLanes.lanesFullMessage)
        #expect(item(full, .newLane).reason == EditLanes.lanesFullMessage)
    }

    @Test func effectAndCutoutFollowTheFileAndSplitFollowsThePlayhead() {
        let photo = EditLaneMenu.items(input(isVideo: false, isPicture: true, playheadInside: false))
        #expect(!item(photo, .effect).enabled)
        #expect(item(photo, .effect).reason == EditLaneMenu.pickVideo)
        #expect(item(photo, .cutout).enabled)
        #expect(!item(photo, .split).enabled)
        #expect(item(photo, .split).reason == EditLaneMenu.playheadOutside)

        let neither = EditLaneMenu.items(input(isVideo: false, isPicture: false))
        #expect(item(neither, .cutout).reason == EditLaneMenu.pickVideoOrPicture)
    }

    @Test func moveToLaneSkipsThisLaneAndALockedOne() {
        #expect(EditLaneMenu.moveLanes(from: 1, count: 4, locked: [3], savesV2: true) == [0, 2])
        #expect(EditLaneMenu.moveLanes(from: 1, count: 4, locked: [1], savesV2: true).isEmpty)
        #expect(EditLaneMenu.moveLanes(from: 1, count: 4, locked: [], savesV2: false).isEmpty)
    }
}
