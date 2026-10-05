import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// Design tokens: web/src/app.css and the boards (CONTRACT section 8). Dark is the boards' default
// look; the app follows the system appearance. Everything here is a dynamic colour, so views never
// branch on the colour scheme.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity)
    }

    /// A colour that resolves per appearance.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
        })
        #endif
    }
}

enum CobaltColor {
    // Pinned by the contract.
    static let bg = Color(light: 0xffffff, dark: 0x000000)
    static let surface = Color(light: 0xf4f4f4, dark: 0x191919)
    static let elevated = Color(light: 0xe3e3e3, dark: 0x282828)
    static let text = Color(light: 0x000000, dark: 0xe1e1e1)
    static let caption = Color(light: 0x6e6e75, dark: 0x8f8f8f)
    static let border = Color(light: 0xadadb7, dark: 0x383838)
    static let sidebar = Color(light: 0xf4f4f4, dark: 0x131313)
    static let errorText = Color(light: 0xc4142a, dark: 0xff5c6c)
    static let error = Color(hex: 0xed2236)
    static let success = Color(hex: 0x30bd1b)
    static let focus = Color(hex: 0x2f8af9)

    // Derived from the boards, same two appearances.
    /// Ink on a `text`-coloured fill (primary buttons, the rail highlight, an active tab).
    static let onText = Color(light: 0xffffff, dark: 0x000000)
    /// Caption on `elevated` fills: the pinned caption is under 4.5:1 there in light.
    static let captionOnElevated = Color(light: 0x5c5c63, dark: 0x8f8f8f)
    static let railTrack = Color(light: 0xf4f4f4, dark: 0x0f0f0f)
    /// The round paste / file buttons: white on the dark boards, black on the light one.
    static let circle = Color(light: 0x000000, dark: 0xffffff)
    static let circleInk = Color(light: 0xffffff, dark: 0x000000)
    static let linkBlue = Color(light: 0x196bd4, dark: 0x2f8af9)
    static let tabBorder = Color(light: 0x000000, dark: 0xffffff).opacity(0.06)
    static let hairline = Color(light: 0x000000, dark: 0xffffff).opacity(0.06)
    /// Library file rows and their buttons sit on a card.
    static let row = Color(light: 0xffffff, dark: 0x222222)
    static let rowButton = Color(light: 0xf4f4f4, dark: 0x2e2e2e)
    static let disabledInk = Color(light: 0x646469, dark: 0x8f8f8f)
    static let scrim = Color.black.opacity(0.62)
    static let frameBase = Color(hex: 0x111111)
    /// Video frames are always dark, in either appearance.
    static let frameTop = Color(hex: 0x4a4a4f)
    static let frameBottom = Color(hex: 0x232326)
    static let frameTopAlt = Color(hex: 0x5b5b60)
    static let frameBottomAlt = Color(hex: 0x2c2c30)
    static let frameTopDeep = Color(hex: 0x3d3d42)
    static let frameBottomDeep = Color(hex: 0x1b1b1e)
    static let badgeBack = Color.black.opacity(0.65)
    static let badgeInk = Color(hex: 0xe1e1e1)
}

enum Metrics {
    static let radius: CGFloat = 11
    static let cardRadius: CGFloat = 26
    static let thumbRadius: CGFloat = 12
    static let circle: CGFloat = 72
    /// The smallest touch target on iOS (HIG).
    static let hit: CGFloat = 44
    static let inspector: CGFloat = 320
    static let gutter: CGFloat = 16
    /// The widest the home column grows before it centres (iPad, Mac).
    static let columnMax: CGFloat = 840

    static let imageCardHeight: CGFloat = 190
    static let studioCardHeight: CGFloat = 432
    static let doneCardHeight: CGFloat = 470
    static let orbitBig: CGFloat = 470
    static let orbitSmall: CGFloat = 132

    /// The trim filmstrip: 72 pt on iOS, 64 pt on the Mac (CONTRACT amendment, native-HIG pass).
    static var strip: CGFloat { Platform.isMac ? 64 : 72 }
    /// One filmstrip cell is about this wide; the count follows the available width.
    static let stripCell: CGFloat = 44
}

/// The three layout tiers, decided from the window's width (the shell measures it; a fold or a
/// split view changes width without a clean size-class change). `wide` is where the trim settings
/// move into the inspector column.
enum Tier: Equatable {
    case compact, regular, wide

    init(width: CGFloat) {
        if width < 600 { self = .compact } else if width < 1240 { self = .regular } else { self = .wide }
    }
}

extension View {
    /// cobalt's flat page on iOS (white / black); the Mac keeps its window material.
    @ViewBuilder
    func cobaltPage() -> some View {
        #if os(iOS)
        background(CobaltColor.bg.ignoresSafeArea())
        #else
        self
        #endif
    }
}

private struct HomeHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 1000 }

extension EnvironmentValues {
    /// The height the home column has (a phone on its side is under ~520 pt, the Mac's smallest
    /// window about 550 pt): previews and tiles shrink so the card's actions stay within a short
    /// scroll.
    var homeHeight: CGFloat {
        get { self[HomeHeightKey.self] }
        set { self[HomeHeightKey.self] = newValue }
    }
}

/// Where the code runs, for the few places the design differs between iOS and the Mac.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
}

/// A gradient that stands in for a video frame (the boards' grey placeholder).
enum FrameGradient {
    static func fill(_ variant: Int) -> LinearGradient {
        let pair: (Color, Color)
        switch variant {
        case 1: pair = (CobaltColor.frameTopAlt, CobaltColor.frameBottomAlt)
        case 2: pair = (CobaltColor.frameTopDeep, CobaltColor.frameBottomDeep)
        default: pair = (CobaltColor.frameTop, CobaltColor.frameBottom)
        }
        return LinearGradient(colors: [pair.0, pair.1], startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1))
    }

    /// The boards' `nth-child(3n)` / `nth-child(4n+1)` rhythm.
    static func variant(forIndex i: Int) -> Int {
        let n = i + 1
        if n % 3 == 0 { return 1 }
        if n % 4 == 1 { return 2 }
        return 0
    }
}
