import CoreGraphics

/// Resolved geometry for placing compact app chrome inside the leading top status-adjacent band
/// on iPhone Duo (beside `9:41` and the trailing circular status / camera indicator).
public struct DuoStatusAdjacentBarMetrics: Equatable, Sendable {
    /// Whether the top status-adjacent leading strip is available and safe to occupy.
    public let isActive: Bool
    /// Total height of the top band matching the top status safe area (`0` when inactive).
    public let bandHeight: CGFloat
    /// Leading inset clearing the outer hinge edge and display corner radius.
    public let leadingInset: CGFloat
    /// Trailing clearance keeping interactive controls safely left of `9:41`, the status orb /
    /// `ReservedRegion(.occlusion)`, and the top-right Control Center swipe-down gesture zone.
    public let trailingReserve: CGFloat
    /// Usable horizontal width inside the leading slot (`containerWidth - leadingInset - trailingReserve`).
    public let availableLeadingWidth: CGFloat
    /// True when the leading slot is wide enough for an extra secondary action pill (e.g., Inner Portrait).
    public let isWideLeadingSlot: Bool

    public static let inactive = DuoStatusAdjacentBarMetrics(
        isActive: false,
        bandHeight: 0,
        leadingInset: 0,
        trailingReserve: 0,
        availableLeadingWidth: 0,
        isWideLeadingSlot: false
    )

    public init(
        isActive: Bool,
        bandHeight: CGFloat,
        leadingInset: CGFloat,
        trailingReserve: CGFloat,
        availableLeadingWidth: CGFloat,
        isWideLeadingSlot: Bool
    ) {
        self.isActive = isActive
        self.bandHeight = bandHeight
        self.leadingInset = leadingInset
        self.trailingReserve = trailingReserve
        self.availableLeadingWidth = availableLeadingWidth
        self.isWideLeadingSlot = isWideLeadingSlot
    }
}

/// Pure, platform-agnostic geometry resolver for the iPhone Duo top status-adjacent bar.
///
/// Design rules (Apple iPhone Duo HIG / iOS 27.1+):
/// - **Active** on iPhone Duo portrait postures where the top status cluster (`9:41` + status orb) sits
///   at the top-trailing corner — either detected via a top-trailing `ReservedRegion(.occlusion)`
///   (`occlusion.midX > width * 0.65`) or a foldable display in portrait (`anyDivision != nil` with
///   `topSafeArea >= 36` and no landscape vertical rail).
/// - **Inactive** on standard centered-Dynamic-Island iPhones (where `9:41` occupies top-left and
///   `.occlusion` sits centered), in Inner Landscape (where iOS 27.1 moves the clock and Vertical
///   Controls onto the trailing rail and `topSafeArea` collapses), on macOS, at accessibility
///   Dynamic Type sizes (`AX1+`), or in narrow multitasking slices (`availableLeadingWidth < 180`).
public enum DuoStatusAdjacentBarLayout {
    /// Minimum top safe-area height indicating a horizontal top status band is present.
    public static let minTopSafeArea: CGFloat = 36
    /// Visual floor and ceiling for the status-adjacent bar height.
    public static let minBandHeight: CGFloat = 54
    public static let maxBandHeight: CGFloat = 62
    /// Trailing exclusion floor clearing `9:41` + gap + circular status orb + Control Center pull buffer.
    public static let minTrailingReserve: CGFloat = 114
    /// Extra trailing clearance left of a detected top-trailing `.occlusion` camera orb for `9:41` + gap.
    public static let clockWidthBesideOcclusion: CGFloat = 60
    /// Minimum container width and usable leading width before falling back to standard chrome.
    public static let minContainerWidth: CGFloat = 320
    public static let minLeadingWidth: CGFloat = 180
    /// Leading slot width threshold for revealing secondary quick pills (Inner Portrait).
    public static let wideLeadingSlotMinWidth: CGFloat = 420
    /// Trailing safe-area threshold indicating the iOS 27.1 Vertical Controls rail is active in landscape.
    public static let verticalRailSafeAreaThreshold: CGFloat = 44

    /// Resolves whether the top status-adjacent bar should activate and its safe leading/trailing geometry.
    public static func resolve(
        containerSize: CGSize,
        topSafeArea: CGFloat,
        leadingSafeArea: CGFloat,
        trailingSafeArea: CGFloat,
        occlusion: CGRect?,
        anyDivision: CGRect?,
        isAccessibilityText: Bool,
        isMac: Bool,
        forceEnable: Bool = false
    ) -> DuoStatusAdjacentBarMetrics {
        guard !isMac, !isAccessibilityText else { return .inactive }
        guard containerSize.width >= minContainerWidth, containerSize.height > 0 else { return .inactive }

        let isLandscape = containerSize.width > containerSize.height
        let hasLandscapeVerticalRail = isLandscape && trailingSafeArea >= verticalRailSafeAreaThreshold
        if hasLandscapeVerticalRail { return .inactive }

        let effectiveTopSafeArea = forceEnable ? max(topSafeArea, minBandHeight) : topSafeArea
        guard effectiveTopSafeArea >= minTopSafeArea else { return .inactive }

        // Inspect any top-edge camera/Dynamic Island `.occlusion` to guard against centered or leading cutouts.
        var hasTrailingCornerOcclusion = false
        var occlusionTrailingReserve: CGFloat = 0

        if let occ = occlusion, !occ.isNull, !occ.isInfinite, occ.width > 0, occ.height > 0 {
            let nearTopEdge = occ.minY < max(effectiveTopSafeArea, 64) && occ.maxY <= max(effectiveTopSafeArea, 64) + 20
            if nearTopEdge {
                let relativeMidX = occ.midX / containerSize.width
                if relativeMidX > 0.65 {
                    hasTrailingCornerOcclusion = true
                    let distanceFromTrailingEdge = max(0, containerSize.width - occ.minX)
                    occlusionTrailingReserve = distanceFromTrailingEdge + clockWidthBesideOcclusion
                } else if !forceEnable {
                    // Centered Dynamic Island or leading camera cutout: never draw into the top status band.
                    return .inactive
                }
            }
        }

        let hasFoldablePortraitTopBand = anyDivision != nil && !isLandscape && effectiveTopSafeArea >= minTopSafeArea
        guard forceEnable || hasTrailingCornerOcclusion || hasFoldablePortraitTopBand else {
            return .inactive
        }

        let bandHeight = min(max(effectiveTopSafeArea, minBandHeight), maxBandHeight).rounded()
        let leadingInset = max(12, leadingSafeArea + 10).rounded()
        let trailingReserve = max(minTrailingReserve, occlusionTrailingReserve).rounded()
        let availableLeadingWidth = max(0, containerSize.width - leadingInset - trailingReserve)

        guard availableLeadingWidth >= minLeadingWidth else { return .inactive }

        return DuoStatusAdjacentBarMetrics(
            isActive: true,
            bandHeight: bandHeight,
            leadingInset: leadingInset,
            trailingReserve: trailingReserve,
            availableLeadingWidth: availableLeadingWidth,
            isWideLeadingSlot: availableLeadingWidth >= wideLeadingSlotMinWidth
        )
    }
}
