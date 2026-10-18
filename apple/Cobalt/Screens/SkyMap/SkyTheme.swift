import CobaltKit
import CoreGraphics
import SwiftUI

// The sky's look, a port of the web library's tokens (`deploy/cloudflare/web/src/library/page.html`, the `--sky-*`
// custom properties about line 186 and `skyTheme()` about line 1591): a night sky in dark mode, a day chart (paper) in
// light mode. Plain values, so the canvas can read them without touching the environment.

/// A colour as red, green and blue in 0...1, so the painter can mix hues into star and line colours.
struct SkyRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(Double(hex >> 16 & 255) / 255, Double(hex >> 8 & 255) / 255, Double(hex & 255) / 255)
    }

    init(_ rgb: SkyPalette.RGB) { self.init(rgb.r, rgb.g, rgb.b) }

    func color(_ opacity: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: opacity) }

    /// `t` of the way from this colour to `other`.
    func mixed(with other: SkyRGB, _ t: Double) -> SkyRGB {
        SkyRGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// A stable key for caching a sprite of this colour.
    var key: UInt32 {
        UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }
}

struct SkyTheme: Equatable {
    var dark: Bool
    /// The sky's centre and its edge.
    var top: SkyRGB
    var bottom: SkyRGB
    /// A star, the dust, the chart's grid.
    var star: SkyRGB
    /// The constellation lines (`--sky-line`): a colour and how opaque.
    var line: SkyRGB
    var lineAlpha: Double
    /// The label words and the halo behind them.
    var label: SkyRGB
    var halo: SkyRGB
    var haloAlpha: Double
    /// A tapped or hovered star.
    var hit: SkyRGB
    /// The floating card and the round buttons.
    var tip: SkyRGB
    var tipAlpha: Double

    static let night = SkyTheme(
        dark: true, top: SkyRGB(hex: 0x141c44), bottom: SkyRGB(hex: 0x04050d), star: SkyRGB(hex: 0xfbf7ee),
        line: SkyRGB(176 / 255, 196 / 255, 1), lineAlpha: 0.32, label: SkyRGB(hex: 0xc3ceff),
        halo: SkyRGB(4 / 255, 5 / 255, 13 / 255), haloAlpha: 0.85, hit: SkyRGB(hex: 0xffd27a),
        tip: SkyRGB(10 / 255, 13 / 255, 32 / 255), tipAlpha: 0.92)

    static let day = SkyTheme(
        dark: false, top: SkyRGB(hex: 0xfbf7ec), bottom: SkyRGB(hex: 0xe9e0ca), star: SkyRGB(hex: 0x1c2448),
        line: SkyRGB(28 / 255, 36 / 255, 72 / 255), lineAlpha: 0.30, label: SkyRGB(hex: 0x3c4777),
        halo: SkyRGB(251 / 255, 247 / 255, 236 / 255), haloAlpha: 0.9, hit: SkyRGB(hex: 0xc2410c),
        tip: SkyRGB(253 / 255, 250 / 255, 242 / 255), tipAlpha: 0.95)

    static func of(_ scheme: ColorScheme) -> SkyTheme { scheme == .dark ? .night : .day }
}

/// One speck of the faint background star field (fixed per canvas size; it drifts a little when the map is panned).
struct SkyDust: Equatable {
    var x: Double
    var y: Double
    var radius: Double
    var alpha: Double
    var phase: Double
    var speed: Double
}

enum SkyDustField {
    /// The web's `starField`: `w * h / 2600` specks from a seeded generator, 90 % of them tiny.
    static func make(size: CGSize) -> [SkyDust] {
        var state: UInt32 = 1234
        func next() -> Double {
            state = state &+ 0x6D2B79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
        let count = max(0, min(2400, Int((size.width * size.height / 2600).rounded())))
        return (0..<count).map { _ in
            let x = next() * size.width, y = next() * size.height
            let small = next() < 0.9
            let radius = small ? 0.5 + next() * 0.5 : 1 + next() * 0.6
            let alpha = 0.15 + next() * 0.45
            return SkyDust(x: x, y: y, radius: radius, alpha: alpha, phase: next() * .pi * 2, speed: 0.6 + next() * 1.6)
        }
    }
}

/// Soft round glows and the nebulae as bitmaps, drawn once and stamped many times.
enum SkyBitmaps {
    /// A round glow of one colour: opaque-ish in the middle, nothing at the edge (the web's `glowSprite`).
    static func glow(_ rgb: SkyRGB) -> CGImage? {
        let side = 64
        guard let cx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [
            CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.9),
            CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.35),
            CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.18, 1])
        else { return nil }
        let c = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        cx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: Double(side) / 2, options: [])
        return cx.makeImage()
    }

    /// One constellation's density grid as an image in its hue (the web's `nebulaImages`): the pixel's alpha is the
    /// density times 125/255 on the night sky and 95/255 on the day chart, the colour premultiplied.
    static func nebula(_ nebula: SkyNebula, dark: Bool) -> CGImage? {
        let w = nebula.width, h = nebula.height
        guard w > 0, h > 0, nebula.values.count >= w * h else { return nil }
        let rgb = SkyPalette.hue(nebula.hue, dark: dark)
        let peak = SkyNebulae.alpha(dark: dark)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Double(max(0, min(1, nebula.values[i]))) * peak
            bytes[4 * i] = UInt8((rgb.r * a * 255).rounded())
            bytes[4 * i + 1] = UInt8((rgb.g * a * 255).rounded())
            bytes[4 * i + 2] = UInt8((rgb.b * a * 255).rounded())
            bytes[4 * i + 3] = UInt8((a * 255).rounded())
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
