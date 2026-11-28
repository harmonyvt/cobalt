import CoreGraphics
import Testing
@testable import CobaltKit

@Suite struct DuoStatusAdjacentBarLayoutTests {

    @Test func activatesOnDuoOuterPortraitWithTrailingCornerOcclusion() {
        // iPhone Duo Outer display (466 x 678), punch-hole camera orb at top-right corner
        let metrics = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 466, height: 678),
            topSafeArea: 54,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 416, y: 10, width: 34, height: 34),
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false
        )

        #expect(metrics.isActive)
        #expect(metrics.bandHeight == 66)
        #expect(metrics.leadingInset == 12)
        // 466 - 416 = 50 + 92 = 142 -> floored to 160
        #expect(metrics.trailingReserve == 160)
        #expect(metrics.availableLeadingWidth == 294)
        #expect(!metrics.isWideLeadingSlot)
    }

    @Test func expandsTrailingReserveAndHeightWhenStatusOrbExtendsFurtherLeftAndDown() {
        let metrics = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 466, height: 678),
            topSafeArea: 56,
            leadingSafeArea: 4,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 386, y: 12, width: 54, height: 52),
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false
        )

        #expect(metrics.isActive)
        // occ.maxY (64) + 8 = 72 -> clears tall battery/Wi-Fi orb vertically
        #expect(metrics.bandHeight == 72)
        #expect(metrics.leadingInset == 14)
        // 466 - 386 = 80 + 92 = 172
        #expect(metrics.trailingReserve == 172)
        #expect(metrics.availableLeadingWidth == 280)
    }

    @Test func activatesOnDuoInnerPortraitFlatAndTabletopEvenWhenOcclusionIsInactive() {
        // iPhone Duo Inner Portrait (669 x 951): under-display camera may be inactive (occlusion == nil),
        // while `anyDivision` still identifies the foldable inner screen.
        let metrics = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 669, height: 951),
            topSafeArea: 54,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: nil,
            anyDivision: CGRect(x: 0, y: 470, width: 669, height: 12),
            isAccessibilityText: false,
            isMac: false
        )

        #expect(metrics.isActive)
        #expect(metrics.bandHeight == 66)
        #expect(metrics.trailingReserve == 160)
        #expect(metrics.availableLeadingWidth == 497)
        #expect(metrics.isWideLeadingSlot)
    }

    @Test func deactivatesInDuoInnerLandscapeWithVerticalControlsRail() {
        let metrics = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 951, height: 669),
            topSafeArea: 14,
            leadingSafeArea: 0,
            trailingSafeArea: 58,
            occlusion: CGRect(x: 898, y: 20, width: 34, height: 34),
            anyDivision: CGRect(x: 470, y: 0, width: 12, height: 669),
            isAccessibilityText: false,
            isMac: false
        )

        #expect(!metrics.isActive)
        #expect(metrics == .inactive)
    }

    @Test func deactivatesOnStandardCenteredDynamicIslandIPhone() {
        // Standard iPhone 17 Pro (402 x 874) with centered Dynamic Island: 9:41 is top-left!
        let metrics = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 402, height: 874),
            topSafeArea: 59,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 138, y: 11, width: 126, height: 37),
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false
        )

        #expect(!metrics.isActive)
    }

    @Test func deactivatesWithoutDuoHardwareSignalsUnlessForceEnabled() {
        let regular = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 402, height: 874),
            topSafeArea: 59,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: nil,
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false
        )
        #expect(!regular.isActive)

        let preview = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 466, height: 678),
            topSafeArea: 0,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: nil,
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false,
            forceEnable: true
        )
        #expect(preview.isActive)
        #expect(preview.bandHeight == 66)
        #expect(preview.availableLeadingWidth == 294)
    }

    @Test func deactivatesOnMacAccessibilityTextAndNarrowMultitaskingSlice() {
        let mac = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 1200, height: 800),
            topSafeArea: 54,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 1140, y: 10, width: 34, height: 34),
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: true
        )
        #expect(!mac.isActive)

        let ax = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 466, height: 678),
            topSafeArea: 54,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 416, y: 10, width: 34, height: 34),
            anyDivision: nil,
            isAccessibilityText: true,
            isMac: false
        )
        #expect(!ax.isActive)

        let narrow = DuoStatusAdjacentBarLayout.resolve(
            containerSize: CGSize(width: 300, height: 678),
            topSafeArea: 54,
            leadingSafeArea: 0,
            trailingSafeArea: 0,
            occlusion: CGRect(x: 256, y: 10, width: 34, height: 34),
            anyDivision: nil,
            isAccessibilityText: false,
            isMac: false
        )
        #expect(!narrow.isActive)
    }
}
