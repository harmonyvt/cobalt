import CoreText
import Foundation
import SwiftUI

/// IBM Plex Mono, registered at runtime so a missing file never blocks a build or a launch: every
/// lookup falls back to the system monospaced font (CONTRACT decision 10).
enum CobaltFont {
    enum Weight: Sendable {
        case regular, medium, semibold

        var postScriptName: String {
            switch self {
            case .regular: return "IBMPlexMono"
            case .medium: return "IBMPlexMono-Medm"
            case .semibold: return "IBMPlexMono-SmBld"
            }
        }

        var system: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            }
        }
    }

    private static let files = ["IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold"]

    /// Registered once, on first use. In the share extension the fonts live in the host app's
    /// bundle (`cobalt.app/PlugIns/CobaltShare.appex`), so both bundles are searched.
    static let isAvailable: Bool = {
        var registered = 0
        for bundle in searchBundles() {
            for name in files {
                guard let url = bundle.url(forResource: name, withExtension: "ttf")
                    ?? bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                else { continue }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { registered += 1 }
                else if let cf = error?.takeRetainedValue(), CFErrorGetCode(cf) == CTFontManagerError.alreadyRegistered.rawValue {
                    registered += 1
                }
            }
            if registered >= files.count { break }
        }
        let probe = CTFontCreateWithName(Weight.regular.postScriptName as CFString, 12, nil)
        return CTFontCopyPostScriptName(probe) as String == Weight.regular.postScriptName
    }()

    /// Call at launch in both targets.
    static func register() { _ = isAvailable }

    private static func searchBundles() -> [Bundle] {
        var bundles = [Bundle.main]
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if host.pathExtension == "app", let hostBundle = Bundle(url: host) { bundles.append(hostBundle) }
        return bundles
    }

    static func font(_ size: CGFloat, _ weight: Weight, relativeTo style: Font.TextStyle) -> Font {
        if isAvailable { return .custom(weight.postScriptName, size: size, relativeTo: style) }
        return .system(size: size, weight: weight.system, design: .monospaced)
    }
}

extension Font {
    /// IBM Plex Mono at a board size, scaling with Dynamic Type.
    static func cobalt(_ size: CGFloat, _ weight: CobaltFont.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        CobaltFont.font(size, weight, relativeTo: style)
    }
}

/// The type scale from the boards: 26 title, 13.5 body, 12 caption, 11 tab labels.
enum CobaltType {
    static let title = Font.cobalt(26, .semibold, relativeTo: .title)
    static let sheetTitle = Font.cobalt(18, .semibold, relativeTo: .title3)
    static let readout = Font.cobalt(26, .medium, relativeTo: .title)
    static let readoutLarge = Font.cobalt(34, .medium, relativeTo: .largeTitle)
    static let body = Font.cobalt(13.5)
    static let bodyMedium = Font.cobalt(13.5, .medium)
    static let bodySemibold = Font.cobalt(13.5, .semibold)
    static let button = Font.cobalt(14.5, .semibold)
    static let buttonSmall = Font.cobalt(12.5)
    static let caption = Font.cobalt(12, relativeTo: .caption)
    static let captionSmall = Font.cobalt(11.5, relativeTo: .caption)
    static let tab = Font.cobalt(11, .regular, relativeTo: .caption2)
    static let pill = Font.cobalt(10.5, .medium, relativeTo: .caption2)
    static let badge = Font.cobalt(10, .regular, relativeTo: .caption2)
}
