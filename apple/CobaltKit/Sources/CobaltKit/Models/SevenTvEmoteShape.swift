import Foundation

/// The shape of a new 7TV emote, as the upload sheet's chips offer it (APP-API-CONTRACT 57.9, 57.10). 7TV has no "wide" flag:
/// a wide emote is a picture wider than tall, and 7TV keeps shapes up to 3:1. So a shape here is only a crop box of that
/// width:height (`centredBox`), sent as the upload's `crop`; the size chips then bring its longest side to the size.
public enum SevenTvEmoteShape: String, CaseIterable, Sendable, Equatable {
    /// The picture as it is (no box).
    case asIs
    /// 1:1.
    case square
    /// 2:1.
    case wide
    /// 3:1, the widest 7TV keeps.
    case extraWide

    /// Width over height; nil for `asIs`.
    public var ratio: Double? {
        switch self {
        case .asIs: return nil
        case .square: return 1
        case .wide: return 2
        case .extraWide: return 3
        }
    }

    /// The largest centred box of this shape in a `width` x `height` picture; see `centredBox(ratio:width:height:)`.
    public func box(width: Int, height: Int) -> ImageCropRect? {
        ratio.flatMap { Self.centredBox(ratio: $0, width: width, height: height) }
    }

    /// The largest centred box of `ratio` (width over height) inside a `width` x `height` picture, as fractions of the picture
    /// (each in 0...1, `x + w` and `y + h` at most 1).
    ///
    /// It is cut in whole px the way the server will cut it, and never wider than `ratio` (a 3:1 box a pixel too wide would be
    /// refused by 7TV's 3:1 limit): the height is kept when the picture is at least as wide as `ratio` (width = `floor(h * ratio)`),
    /// else the width is kept and the height is `ceil(w / ratio)`. The offset is the whole px below the exact middle.
    /// `round(fraction * size)` gives these px back exactly.
    ///
    /// Nil when there is no box to cut: the picture already is that shape (the box would be the whole picture, which is no
    /// crop), or the ratio or the size is not usable (zero, negative, not finite).
    public static func centredBox(ratio: Double, width: Int, height: Int) -> ImageCropRect? {
        guard ratio.isFinite, ratio > 0, width > 0, height > 0 else { return nil }
        let w = Double(width), h = Double(height)
        let boxWidth: Int, boxHeight: Int
        if w >= ratio * h - 1e-9 {
            boxHeight = height
            boxWidth = min(width, max(1, Int((h * ratio + 1e-9).rounded(.down))))
        } else {
            boxWidth = width
            boxHeight = min(height, max(1, Int((w / ratio - 1e-9).rounded(.up))))
        }
        guard boxWidth < width || boxHeight < height else { return nil }
        let x = Double((width - boxWidth) / 2) / w
        let y = Double((height - boxHeight) / 2) / h
        return ImageCropRect(x: x, y: y, w: min(Double(boxWidth) / w, 1 - x), h: min(Double(boxHeight) / h, 1 - y))
    }

    /// The shape a crop box is, to a pixel or two (a locked box in floats rounds one side at a time): `asIs` without a crop,
    /// `square`, `wide` or `extraWide` when the box's px match that ratio, nil for any other box (a custom crop). Nil too when
    /// the picture's size is unknown.
    public static func matching(width: Int?, height: Int?, crop: ImageCropRect?) -> SevenTvEmoteShape? {
        guard let crop else { return .asIs }
        guard let px = SevenTvEmoteRule.cropPixels(width: width, height: height, crop: crop) else { return nil }
        for shape in [SevenTvEmoteShape.square, .wide, .extraWide] {
            if let ratio = shape.ratio, abs(Double(px.w) - ratio * Double(px.h)) <= 2 { return shape }
        }
        return nil
    }
}
