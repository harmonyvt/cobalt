import CoreGraphics
import Foundation

// The borderless gallery image's geometry (apple/CONTRACT-GALLERY.md 6.4): ONE function, ported from the helper's
// `galleryLayout` (itself ported from CONTRACT-GALLERY.model.js `GM.layout`), so what the owner sees in the combine
// sheet is what the server draws. No gaps, no borders: the cells tile the canvas exactly.

/// The canvas of one layout and where each photo goes on it.
public struct GalleryCanvas: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        /// The photo's position in the `sizes` the layout was asked for (0-based).
        public var index: Int
        public var rect: CGRect
        /// The photo is centre-cropped to fit this cell (its shape differs from the cell's by 0.4 % or more). A strip
        /// and side by side never crop (R3).
        public var cropped: Bool
        /// The factor the photo is drawn larger than its own pixels (rounded to 0.1), when over 1.01; nil otherwise.
        /// A photo alone in a shorter row has a wider cell (R3).
        public var upscale: Double?

        public init(index: Int, rect: CGRect, cropped: Bool, upscale: Double?) {
            self.index = index
            self.rect = rect
            self.cropped = cropped
            self.upscale = upscale
        }
    }

    public var width: Int
    public var height: Int
    public var cells: [Cell]
    /// The canvas was scaled down to stay inside the caps (`GalleryGeometry.maxLongSide`, `maxPixels`).
    public var scaledToCap: Bool

    public init(width: Int, height: Int, cells: [Cell], scaledToCap: Bool) {
        self.width = width
        self.height = height
        self.cells = cells
        self.scaledToCap = scaledToCap
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    /// Indices of the photos the layout crops.
    public var croppedIndices: [Int] { cells.filter(\.cropped).map(\.index) }
    /// Indices of the photos drawn larger than their own pixels.
    public var upscaledIndices: [Int] { cells.filter { $0.upscale != nil }.map(\.index) }
}

public enum GalleryGeometry {
    public static let maxLongSide = 30_000
    public static let maxPixels = 40_000_000
    /// A photo is cropped when its shape differs from its cell's by this much or more.
    static let cropTolerance = 0.004
    /// The widest a grid's canvas is made, and the widest a strip's or the tallest a row's.
    static let gridMaxWidth = 2160
    static let stripMaxWidth = 1080

    public struct NeedsTwoPhotos: Error, Equatable, Sendable {}

    /// `sizes`: the photos in the chosen order. Throws `NeedsTwoPhotos` for fewer than 2.
    public static func layout(_ sizes: [CGSize], _ layout: GalleryLayout) throws -> GalleryCanvas {
        guard sizes.count >= 2 else { throw NeedsTwoPhotos() }
        let dims = sizes.map { (w: max(1, Int($0.width.rounded())), h: max(1, Int($0.height.rounded()))) }
        let n = dims.count
        let minW = dims.map(\.w).min() ?? 1
        let minH = dims.map(\.h).min() ?? 1
        let base: Int
        switch layout {
        case .strip: base = even(Double(min(stripMaxWidth, minW)))
        case .row: base = even(Double(min(stripMaxWidth, minH)))
        case .grid2, .grid3:
            let across = layout == .grid3 ? 3 : 2
            base = even(Double(min(gridMaxWidth, (rowCounts(n, across).first ?? across) * minW)))
        }
        var canvas = build(dims, layout, base)
        let long = max(canvas.width, canvas.height)
        let pixels = canvas.width * canvas.height
        if long > maxLongSide || pixels > maxPixels {
            let scale = min(Double(maxLongSide) / Double(long), (Double(maxPixels) / Double(pixels)).squareRoot())
            canvas = build(dims, layout, even(Double(base) * scale))
            canvas.scaledToCap = true
        }
        return canvas
    }

    /// `even(n)`: floored to an even integer, at least 2.
    static func even(_ n: Double) -> Int {
        let floored = Int(n.rounded(.down))
        return max(2, floored - (floored % 2))
    }

    /// Photos in each row of a grid `across` wide: `r = ceil(n / N)` rows, the first `n - base·r` hold one more
    /// (10 in 3 across = 3+3+2+2), so there are no gaps.
    static func rowCounts(_ n: Int, _ across: Int) -> [Int] {
        let rows = Int((Double(n) / Double(across)).rounded(.up))
        let base = n / rows
        let extra = n - base * rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// The most common `width×height`; a tie goes to the shape that reached the top count first (the reference's
    /// own rule, which the helper keeps).
    static func commonAspect(_ dims: [(w: Int, h: Int)]) -> Double {
        var seen: [String: Int] = [:]
        var best: (key: String, w: Int, h: Int)?
        for d in dims {
            let key = "\(d.w)x\(d.h)"
            seen[key, default: 0] += 1
            if best == nil || seen[key]! > seen[best!.key]! { best = (key, d.w, d.h) }
        }
        return Double(best?.w ?? 1) / Double(best?.h ?? 1)
    }

    private static func build(_ dims: [(w: Int, h: Int)], _ layout: GalleryLayout, _ scaleTo: Int) -> GalleryCanvas {
        var cells: [GalleryCanvas.Cell] = []
        var width = 0
        var height = 0
        switch layout {
        case .strip:
            width = scaleTo
            for (i, d) in dims.enumerated() {
                let h = even((Double(width) * Double(d.h) / Double(d.w)).rounded())
                cells.append(.init(index: i, rect: CGRect(x: 0, y: height, width: width, height: h), cropped: false, upscale: nil))
                height += h
            }
        case .row:
            height = scaleTo
            for (i, d) in dims.enumerated() {
                let w = even((Double(height) * Double(d.w) / Double(d.h)).rounded())
                cells.append(.init(index: i, rect: CGRect(x: width, y: 0, width: w, height: height), cropped: false, upscale: nil))
                width += w
            }
        case .grid2, .grid3:
            let across = layout == .grid3 ? 3 : 2
            let aspect = commonAspect(dims)
            width = scaleTo
            var first = 0
            for k in rowCounts(dims.count, across) {
                let cellW = even(Double(width) / Double(k))
                let lastW = width - (k - 1) * cellW
                let rowH = even((Double(cellW) / aspect).rounded())
                var x = 0
                for j in 0..<k {
                    let w = j == k - 1 ? lastW : cellW
                    let d = dims[first + j]
                    let cellAspect = Double(w) / Double(rowH)
                    let photoAspect = Double(d.w) / Double(d.h)
                    let up = max(Double(w) / Double(d.w), Double(rowH) / Double(d.h))
                    cells.append(.init(
                        index: first + j, rect: CGRect(x: x, y: height, width: w, height: rowH),
                        cropped: abs(photoAspect - cellAspect) / cellAspect >= cropTolerance,
                        upscale: up > 1.01 ? (up * 10).rounded() / 10 : nil))
                    x += w
                }
                height += rowH
                first += k
            }
        }
        return GalleryCanvas(width: width, height: height, cells: cells, scaledToCap: false)
    }
}
