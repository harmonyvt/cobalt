import CoreGraphics
import Foundation

/// Where the pane goes in a window, from facts only (apple/CONTRACT-PANE.md section 2). The only place in the app that
/// knows device sizes.
public enum PanePlacement: Equatable, Sendable {
    /// A two-screen phone open: the pane is one screen. `.vertical`: the hinge is a vertical line at x = `hinge` (the
    /// wide posture, pane on the left); `.horizontal`: a horizontal line at y = `hinge` (the tall posture, pane on top).
    case twoScreens(axis: Axis, hinge: CGFloat)
    /// A column on the leading side of a window with no hinge (iPad, Mac, a wide window).
    case column(width: CGFloat)
    /// One narrow screen: the pane is a sheet, and spanned a full-screen cover.
    case compact

    /// The direction of the line between the two screens. Nested so it never shadows SwiftUI's `Axis` in the app.
    public enum Axis: String, Equatable, Sendable {
        /// Screens side by side; the hinge is a vertical line.
        case vertical
        /// Screens one above the other; the hinge is a horizontal line.
        case horizontal
    }

    /// The kind of device, without UIKit. Nested for the same reason as `Axis`.
    public enum Idiom: String, Equatable, Sendable {
        case phone, pad, mac
    }

    /// The iPad column's width (pt).
    public static let padColumn: CGFloat = 440
    /// The Mac column's width (pt), after the sidebar.
    public static let macColumn: CGFloat = 400
    /// A phone this wide (or wider) and `phoneWideMinHeight` high is two screens side by side (until iOS reports the
    /// Duo's hinge).
    public static let phoneWideMin: CGFloat = 700
    /// ...and this high: the Duo open wide is about 951 x 669, while every one-screen iPhone in landscape is far lower
    /// (iPhone 17 Pro 874 x 402, Pro Max 956 x 440), so a rotated iPhone stays compact.
    public static let phoneWideMinHeight: CGFloat = 560
    /// A phone this wide (or wider) and taller than it is wide is two screens one above the other.
    public static let phoneTallMin: CGFloat = 600
    /// An iPad or Mac window this wide (or wider) gets the column; narrower is compact.
    public static let columnMin: CGFloat = 900

    /// Resolves the placement for a window of `size`.
    ///
    /// A reported display feature (a hinge, in the window's coordinates) wins: a feature taller than it is wide is a
    /// vertical hinge at its mid x, otherwise a horizontal one at its mid y. Without one: a phone `phoneWideMin` wide and
    /// `phoneWideMinHeight` high (a real two-screen shape, not a phone on its side) is two screens side by side (hinge
    /// at half the width); a phone `phoneTallMin` wide and taller than wide is two screens
    /// one above the other (hinge at half the height); an iPad or a Mac `columnMin` wide gets the column (440 / 400);
    /// anything else is compact.
    public static func resolve(size: CGSize, idiom: Idiom, displayFeatureFrame: CGRect?) -> PanePlacement {
        if let feature = displayFeatureFrame, !feature.isNull, !feature.isInfinite, feature.width > 0 || feature.height > 0 {
            return feature.height >= feature.width
                ? .twoScreens(axis: .vertical, hinge: feature.midX)
                : .twoScreens(axis: .horizontal, hinge: feature.midY)
        }
        switch idiom {
        case .phone:
            if size.width >= phoneWideMin, size.height >= phoneWideMinHeight { return .twoScreens(axis: .vertical, hinge: size.width / 2) }
            if size.width >= phoneTallMin, size.height > size.width { return .twoScreens(axis: .horizontal, hinge: size.height / 2) }
            return .compact
        case .pad:
            return size.width >= columnMin ? .column(width: padColumn) : .compact
        case .mac:
            return size.width >= columnMin ? .column(width: macColumn) : .compact
        }
    }

    /// A short word for analytics and breadcrumbs: `wide`, `tall`, `column`, `compact`.
    public var name: String {
        switch self {
        case .twoScreens(let axis, _): axis == .vertical ? "wide" : "tall"
        case .column: "column"
        case .compact: "compact"
        }
    }

    /// The room the tab keeps beside a pane at `screen` in a window `size` wide/high along the pane's axis; nil when
    /// the pane takes no room beside the tab (compact: a sheet).
    public func tabExtent(in size: CGSize) -> CGSize? {
        switch self {
        case .twoScreens(axis: .vertical, hinge: let hinge): CGSize(width: max(0, size.width - hinge), height: size.height)
        case .twoScreens(axis: .horizontal, hinge: let hinge): CGSize(width: size.width, height: max(0, size.height - hinge))
        case .column(let width): CGSize(width: max(0, size.width - width), height: size.height)
        case .compact: nil
        }
    }
}
