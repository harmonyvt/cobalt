import CoreGraphics
import Foundation

/// Fold-safe grid & division layout helpers (apple/ARCHITECTURE.md, iPhone Duo rules).
///
/// On regular horizontal width (iPhone Duo inner display, iPad, Mac), multi-column grids prefer
/// even column counts (2, 4, 6…) so cards never straddle the center fold crease when the device
/// bends into Book posture.
public enum DuoGrid {
    /// Snaps `count` to an even number when `>= 2`, clamping to `[min, max]`.
    public static func snapEven(_ count: Int, min minColumns: Int = 2, max maxColumns: Int? = nil) -> Int {
        let floorEven = max(2, minColumns.isMultiple(of: 2) ? minColumns : minColumns + 1)
        var n = max(floorEven, count)
        if !n.isMultiple(of: 2) {
            // Round down to the nearest even count unless that would fall below floorEven.
            n = max(floorEven, n - 1)
        }
        if let maxColumns {
            let capEven = max(floorEven, maxColumns.isMultiple(of: 2) ? maxColumns : maxColumns - 1)
            n = min(n, capEven)
        }
        return n
    }

    /// Computes a fold-safe column count for a grid of `width`.
    ///
    /// - Parameters:
    ///   - width: Available container width (points).
    ///   - minItemWidth: Minimum ideal card/cell width (points).
    ///   - spacing: Inter-column spacing (points).
    ///   - margin: Horizontal outer margin on each side (points).
    ///   - isRegular: True when `horizontalSizeClass == .regular` (inner display / iPad / Mac).
    ///   - minColumns: Lower bound (default 2).
    ///   - maxColumns: Optional upper bound.
    public static func columnCount(
        forWidth width: Double,
        minItemWidth: Double,
        spacing: Double = 8,
        margin: Double = 0,
        isRegular: Bool,
        minColumns: Int = 2,
        maxColumns: Int? = nil
    ) -> Int {
        let usable = width - 2 * margin + spacing
        let step = minItemWidth + spacing
        guard usable.isFinite, step > 0 else { return max(1, minColumns) }
        var raw = max(minColumns, Int((usable / step).rounded(.down)))
        if let maxColumns { raw = min(raw, maxColumns) }
        if isRegular && raw >= 2 {
            return snapEven(raw, min: minColumns, max: maxColumns)
        }
        return max(1, raw)
    }

    /// Exact column width for `columns` columns within `totalWidth`.
    public static func columnWidth(totalWidth: Double, columns: Int, spacing: Double = 8, margin: Double = 0) -> Double {
        let n = max(1, columns)
        return max(0, (totalWidth - 2 * margin - spacing * Double(n - 1)) / Double(n))
    }
}

/// Pure geometry resolver for an active center fold (`ReservedRegion(.division)`).
///
/// Screens with custom canvases (e.g. orbit layout, mosaic, custom split views) pass their container
/// `size` and optional active `divisionFrame` to avoid placing focal media or controls on the crease.
public enum DuoDivisionSplit: Equatable, Sendable {
    /// Display is flat or no active division intersects the container.
    case unified
    /// Vertical crease (Book posture): two side-by-side regions separated by `gap`.
    case horizontal(leadingWidth: CGFloat, trailingWidth: CGFloat, gap: CGFloat)
    /// Horizontal crease (Tabletop posture): two stacked regions separated by `gap`.
    case vertical(topHeight: CGFloat, bottomHeight: CGFloat, gap: CGFloat)

    public static func resolve(containerSize size: CGSize, activeDivision frame: CGRect?) -> DuoDivisionSplit {
        guard let frame,
              !frame.isNull, !frame.isInfinite,
              size.width > 0, size.height > 0,
              frame.width > 0 || frame.height > 0 else {
            return .unified
        }
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = bounds.intersection(frame)
        guard !clipped.isNull, clipped.width > 0 || clipped.height > 0 else {
            return .unified
        }
        if clipped.height >= clipped.width {
            let leading = max(0, clipped.minX)
            let trailing = max(0, size.width - clipped.maxX)
            guard leading > 40, trailing > 40 else { return .unified }
            return .horizontal(leadingWidth: leading, trailingWidth: trailing, gap: clipped.width)
        } else {
            let top = max(0, clipped.minY)
            let bottom = max(0, size.height - clipped.maxY)
            guard top > 40, bottom > 40 else { return .unified }
            return .vertical(topHeight: top, bottomHeight: bottom, gap: clipped.height)
        }
    }
}
