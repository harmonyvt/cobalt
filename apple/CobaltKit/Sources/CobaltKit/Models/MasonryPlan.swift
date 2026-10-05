import Foundation

/// The mosaic's placement (CONTRACT-LIBRARY2 decision 12): newest first, each tile into the currently
/// shortest column (ties go to the leftmost), tile height = column width × the face's aspect clamped to
/// 16:9 ... 9:16. A pure function of the aspects in order, so a new page only appends: a tile's slot
/// depends on the tiles before it and nothing after, and tiles never jump while pages load.
public struct MasonryPlan: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public let index: Int           // position in the input
        public let column: Int          // 0-based, left to right
        public let y: Double            // top, within the content (below the margin)
        public let height: Double
    }

    public let columns: Int
    public let columnWidth: Double
    public let slots: [Slot]
    /// The tallest column's bottom edge (no trailing gap, no margin).
    public let height: Double

    /// `n = max(2, floor((width - 2·margin + gap) / (minTile + gap)))`; 2 at accessibility text sizes.
    public static func columns(width: Double, minTile: Double, gap: Double, margin: Double, accessibility: Bool) -> Int {
        if accessibility { return 2 }
        let usable = width - 2 * margin + gap
        let per = minTile + gap
        guard usable.isFinite, per > 0 else { return 2 }
        return max(2, Int((usable / per).rounded(.down)))
    }

    /// `aspects` are height ÷ width of each face, newest first.
    public static func make(aspects: [Double], width: Double, columns: Int, gap: Double, margin: Double) -> MasonryPlan {
        let n = max(1, columns)
        let columnWidth = max(0, (width - 2 * margin - gap * Double(n - 1)) / Double(n))
        var bottoms = [Double](repeating: 0, count: n)        // next free y of each column (after its gap)
        var slots: [Slot] = []
        slots.reserveCapacity(aspects.count)
        for (index, raw) in aspects.enumerated() {
            let h = columnWidth * clampAspect(raw)
            var shortest = 0
            for c in 1..<max(1, n) where bottoms[c] < bottoms[shortest] - 0.001 { shortest = c }
            slots.append(Slot(index: index, column: shortest, y: bottoms[shortest], height: h))
            bottoms[shortest] += h + gap
        }
        let tallest = zip(bottoms, 0..<n).map { b, c in slots.contains { $0.column == c } ? b - gap : 0 }.max() ?? 0
        return MasonryPlan(columns: n, columnWidth: columnWidth, slots: slots, height: max(0, tallest))
    }

    /// 9/16 ... 16/9; an unusable aspect (zero, negative, not finite) is the landscape 9/16 default.
    public static func clampAspect(_ hOverW: Double) -> Double {
        guard hOverW.isFinite, hOverW > 0 else { return 9.0 / 16.0 }
        return min(16.0 / 9.0, max(9.0 / 16.0, hOverW))
    }
}
