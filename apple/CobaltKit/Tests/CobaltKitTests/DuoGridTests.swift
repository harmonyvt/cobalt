import CoreGraphics
import Testing
@testable import CobaltKit

@Suite struct DuoGridTests {
    @Test func snapEvenAlwaysProducesEvenCounts() {
        #expect(DuoGrid.snapEven(0) == 2)
        #expect(DuoGrid.snapEven(1) == 2)
        #expect(DuoGrid.snapEven(2) == 2)
        #expect(DuoGrid.snapEven(3) == 2)
        #expect(DuoGrid.snapEven(4) == 4)
        #expect(DuoGrid.snapEven(5) == 4)
        #expect(DuoGrid.snapEven(6) == 6)
        #expect(DuoGrid.snapEven(7) == 6)
    }

    @Test func columnCountSnapsToEvenOnRegularWidth() {
        // Width where raw count would be 3 -> must snap to 2 so no tile crosses center fold.
        let threeWide = DuoGrid.columnCount(forWidth: 500, minItemWidth: 150, spacing: 10, isRegular: true)
        #expect(threeWide.isMultiple(of: 2))
        #expect(threeWide == 2)

        // Width where raw count would be 5 -> must snap to 4 on regular width.
        let fiveWide = DuoGrid.columnCount(forWidth: 820, minItemWidth: 150, spacing: 10, isRegular: true)
        #expect(fiveWide.isMultiple(of: 2))
        #expect(fiveWide == 4)

        // Compact width has no fold crease and allows odd column counts when they fit.
        let compactThree = DuoGrid.columnCount(forWidth: 360, minItemWidth: 100, spacing: 8, isRegular: false)
        #expect(compactThree == 3)
    }

    @Test func masonryDuoColumnsEnforcesEvenCountWhenRegular() {
        for width in stride(from: 600.0, through: 1600.0, by: 40.0) {
            let regular = MasonryPlan.duoColumns(
                width: width, minTile: 160, gap: 10, margin: 16, accessibility: false, isRegular: true)
            #expect(regular >= 2)
            #expect(regular.isMultiple(of: 2), "Expected even masonry columns at regular width \(width), got \(regular)")
        }
    }

    @Test func divisionSplitResolvesHorizontalAndVerticalFolds() {
        // Tabletop (horizontal crease across middle of 800x700 display) -> stacked vertical regions
        let tabletop = DuoDivisionSplit.resolve(
            containerSize: CGSize(width: 800, height: 700),
            activeDivision: CGRect(x: 0, y: 340, width: 800, height: 20))
        #expect(tabletop == .vertical(topHeight: 340, bottomHeight: 340, gap: 20))

        // Book (vertical crease down middle of 800x700 display) -> side-by-side horizontal regions
        let book = DuoDivisionSplit.resolve(
            containerSize: CGSize(width: 800, height: 700),
            activeDivision: CGRect(x: 390, y: 0, width: 20, height: 700))
        #expect(book == .horizontal(leadingWidth: 390, trailingWidth: 390, gap: 20))

        // Flat / unfolded -> unified
        #expect(DuoDivisionSplit.resolve(containerSize: CGSize(width: 800, height: 700), activeDivision: nil) == .unified)
    }

    @Test func panePlacementSizeClassOverloadMatchesDuoPoses() {
        // Compact Outer display -> compact sheet
        let outer = PanePlacement.resolve(
            size: CGSize(width: 390, height: 780), isRegular: false, isMac: false, displayFeatureFrame: nil)
        #expect(outer == .compact)

        // Regular Inner Flat (wide iPad/Duo landscape) -> column
        let innerFlat = PanePlacement.resolve(
            size: CGSize(width: 960, height: 760), isRegular: true, isMac: false, displayFeatureFrame: nil)
        #expect(innerFlat == .column(width: PanePlacement.padColumn))

        // Book fold with active vertical division -> twoScreens aligned to division midX
        let book = PanePlacement.resolve(
            size: CGSize(width: 900, height: 760),
            isRegular: true,
            isMac: false,
            displayFeatureFrame: CGRect(x: 444, y: 0, width: 12, height: 760))
        #expect(book == .twoScreens(axis: .vertical, hinge: 450))

        // Tabletop fold with active horizontal division -> twoScreens aligned to division midY
        let tabletop = PanePlacement.resolve(
            size: CGSize(width: 900, height: 760),
            isRegular: true,
            isMac: false,
            displayFeatureFrame: CGRect(x: 0, y: 374, width: 900, height: 12))
        #expect(tabletop == .twoScreens(axis: .horizontal, hinge: 380))
    }
}
