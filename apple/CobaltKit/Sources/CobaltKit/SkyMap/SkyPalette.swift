import Foundation

/// The sky's colours that are not part of the app's own theme: the nebula hues and the fingerprint's two star colours,
/// as the web has them (`HUES`, page.html 1498; `fingerprint`, page.html 1905).
public enum SkyPalette {
    /// One hue per constellation, in order (`HUES`). The same ten colours on the night sky and on the day chart: on the
    /// night they are vivid, on the day they are a watercolour wash (see `SkyNebulae.alpha(dark:)`).
    public static let hexes = ["#7b6cff", "#2fb7c9", "#e3609d", "#f0a64b", "#57c98b",
                               "#a07cf2", "#4f90f7", "#d670e0", "#5fd4c4", "#f07c5c"]

    public static var count: Int { hexes.count }

    public typealias RGB = (r: Double, g: Double, b: Double)

    /// Hue `index` (any integer: it cycles) as red, green and blue in 0...1. `dark` is accepted for the day and night
    /// skies; the web uses one list for both.
    public static func hue(_ index: Int, dark: Bool) -> RGB {
        let i = ((index % count) + count) % count
        let v = Int(hexes[i].dropFirst(), radix: 16) ?? 0x7878ff
        return (Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> RGB { (r / 255, g / 255, b / 255) }

    /// The fingerprint's star colour for numbers above zero: cool white-blue by night, deep blue by day.
    public static func cool(dark: Bool) -> RGB {
        dark ? rgb(180, 205, 255) : rgb(37, 74, 170)
    }

    /// The fingerprint's star colour for numbers below zero: amber by night, burnt orange by day.
    public static func warm(dark: Bool) -> RGB {
        dark ? rgb(255, 196, 120) : rgb(176, 84, 20)
    }
}
