import Testing
@testable import CobaltKit

// CONTRACT-LIBRARY2.md section 9 K: `MasonryPlan` (decision 12).

struct MasonryPlanTests {
    @Test func threeColumnsAt390AndTwoAtAccessibilitySizes() {
        #expect(MasonryPlan.columns(width: 390, minTile: 108, gap: 6, margin: 12, accessibility: false) == 3)
        #expect(MasonryPlan.columns(width: 390, minTile: 108, gap: 6, margin: 12, accessibility: true) == 2)
        // never fewer than two, however narrow
        #expect(MasonryPlan.columns(width: 100, minTile: 108, gap: 6, margin: 12, accessibility: false) == 2)
        #expect(MasonryPlan.columns(width: 320, minTile: 108, gap: 6, margin: 12, accessibility: false) == 2)
        // iPad and Mac minimums
        #expect(MasonryPlan.columns(width: 1194, minTile: 150, gap: 6, margin: 12, accessibility: false) == 7)
        #expect(MasonryPlan.columns(width: 800, minTile: 160, gap: 6, margin: 12, accessibility: false) == 4)
    }

    @Test func aspectsClampAtSixteenByNineAndNineBySixteen() {
        #expect(MasonryPlan.clampAspect(2622.0 / 1206.0) == 16.0 / 9.0)         // a 1206×2622 screen recording: 9:16 portrait
        #expect(MasonryPlan.clampAspect(280.0 / 498.0) == 9.0 / 16.0)           // 498×280: wider than 16:9
        #expect(MasonryPlan.clampAspect(1) == 1)
        #expect(MasonryPlan.clampAspect(1.25) == 1.25)
        #expect(MasonryPlan.clampAspect(0) == 9.0 / 16.0)                       // unknown: landscape 16:9
        #expect(MasonryPlan.clampAspect(-3) == 9.0 / 16.0)
        #expect(MasonryPlan.clampAspect(.nan) == 9.0 / 16.0)
        #expect(MasonryPlan.clampAspect(.infinity) == 9.0 / 16.0)
        let plan = MasonryPlan.make(aspects: [5, 0.1], width: 390, columns: 3, gap: 6, margin: 12)
        #expect(plan.slots[0].height == plan.columnWidth * 16.0 / 9.0)
        #expect(plan.slots[1].height == plan.columnWidth * 9.0 / 16.0)
    }

    @Test func tilesGoIntoTheShortestColumnTiesToTheLeft() {
        let plan = MasonryPlan.make(aspects: [1, 1, 1, 1, 1], width: 390, columns: 3, gap: 6, margin: 12)
        #expect(plan.slots.map(\.column) == [0, 1, 2, 0, 1])                    // all equal: round robin, leftmost first
        #expect(plan.slots.map(\.y) == [0, 0, 0] + [plan.columnWidth + 6, plan.columnWidth + 6])
        // a tall first tile sends the next three elsewhere
        let tall = MasonryPlan.make(aspects: [16.0 / 9.0, 9.0 / 16.0, 9.0 / 16.0, 9.0 / 16.0, 9.0 / 16.0], width: 390, columns: 2, gap: 6, margin: 12)
        #expect(tall.slots.map(\.column) == [0, 1, 1, 1, 1])      // column 1 is still shorter (321.75 vs 326) for the fifth
    }

    @Test func theGeometryAddsUp() {
        let plan = MasonryPlan.make(aspects: [1, 2, 1, 1], width: 390, columns: 3, gap: 6, margin: 12)
        let cw = (390.0 - 24 - 12) / 3
        #expect(plan.columns == 3 && abs(plan.columnWidth - cw) < 1e-9)
        // column 0 holds tile 0 and tile 3; the tallest column is the 16:9 tile's (index 1: 2 clamps to 16/9)
        let tallest = cw * 16.0 / 9.0
        #expect(abs(plan.slots[1].height - tallest) < 1e-9)
        #expect(abs(plan.height - max(tallest, 2 * cw + 6)) < 1e-9)
        #expect(MasonryPlan.make(aspects: [], width: 390, columns: 3, gap: 6, margin: 12).height == 0)
    }

    /// `Library2-Mosaic.dc.html`'s thirteen posts in its order (face h ÷ w) at its 368 pt content width,
    /// and the columns the board's own `plan()` puts them in (run with node on 2026-10-05).
    @Test func theBoardsAspectsLandInTheBoardsColumns() {
        let board: [(id: String, w: Double, h: Double)] = [
            ("p2", 480, 600), ("u1", 1206, 2622), ("p1", 720, 1280), ("u2", 1080, 1920), ("u3", 720, 1280),
            ("u4", 320, 320), ("u5", 640, 360), ("u6", 360, 640), ("u7", 360, 640), ("p3", 480, 568),
            ("p4", 498, 280), ("p5", 480, 480), ("p6", 480, 270),
        ]
        let n = MasonryPlan.columns(width: 368, minTile: 108, gap: 6, margin: 12, accessibility: false)
        #expect(n == 3)
        let plan = MasonryPlan.make(aspects: board.map { $0.h / $0.w }, width: 368, columns: n, gap: 6, margin: 12)
        var columns = [[String]](repeating: [], count: n)
        for slot in plan.slots { columns[slot.column].append(board[slot.index].id) }
        #expect(columns == [["p2", "u2", "u6", "p5"], ["u1", "u3", "p3", "p4"], ["p1", "u4", "u5", "u7", "p6"]])
        #expect(abs(plan.columnWidth - 110.6666667) < 1e-6)
    }

    @Test func appendingAPageNeverMovesAnEarlierTile() {
        let aspects: [Double] = (0..<60).map { i in [1.25, 16.0 / 9.0, 1, 9.0 / 16.0, 1.18, 2.2, 0.3][i % 7] }
        let first = MasonryPlan.make(aspects: Array(aspects[..<20]), width: 390, columns: 3, gap: 6, margin: 12)
        let more = MasonryPlan.make(aspects: Array(aspects[..<40]), width: 390, columns: 3, gap: 6, margin: 12)
        let all = MasonryPlan.make(aspects: aspects, width: 390, columns: 3, gap: 6, margin: 12)
        #expect(Array(more.slots[..<20]) == first.slots)
        #expect(Array(all.slots[..<40]) == more.slots)
        #expect(all.height >= more.height && more.height >= first.height)
    }
}
