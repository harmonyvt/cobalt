import CoreGraphics
import Foundation

/// Where every part of the editor goes for a given size (apple/CONTRACT-EDITOR.md 15.1). A pure value: the app's
/// `EditorShell` builds one from its `GeometryReader` and puts each part (one instance each) into its slot. Nothing here
/// knows SwiftUI, so every screen size is a unit test.
///
/// Coordinates are local to the content rect (the editor's size after the safe area): `content` is always
/// `(0, 0, size.width, size.height)`.
///
/// - **compact** (width < 600) and **tall** (width ≥ 600, height > width): a top bar, the picture (exactly the fitted canvas,
///   at most 42 % / 50 % of the content height, centred across), the transport straight under it, the timeline with every
///   point left, and one row of tools at the bottom. The inspector is a drawer over the timeline only, at two detents.
/// - **wide** (width ≥ 900, or width ≥ 700 and wider than tall): a top bar; under it a 64 pt tool rail, the middle column
///   (picture at the top, transport under it) and the inspector column; the timeline full width at the bottom, 40 % of the
///   height and at least 230 pt. When the picture is held back by the middle column's width, the timeline takes the rest.
/// - Anything else (600 to 899 wide and not taller than wide, but not wide either, such as a near-square window) is laid out
///   as compact.
///
/// The picture never has a band above or below it: `picture.minY == topBar.maxY` and `transport.minY == picture.maxY` in
/// every regime. Bands at its sides are fine.
public struct EditorLayout: Equatable, Sendable {
    public enum Regime: String, Sendable, CaseIterable {
        case compact, tall, wide
    }

    public enum Platform: String, Sendable {
        case ios, mac
    }

    /// The compact and tall inspector drawer. `closed` keeps the inspector mounted but off screen.
    public enum DrawerDetent: String, Sendable, CaseIterable {
        case closed, low, high
    }

    // MARK: constants

    public static let topBarHeight: CGFloat = 48
    public static let transportHeight: CGFloat = 48
    /// The bottom tool row: 44 pt targets and 4 pt either side.
    public static let toolRowHeight: CGFloat = 52
    public static let toolRailWidth: CGFloat = 64
    /// The wide inspector column: 300 pt, narrowed to 26 % of the width (never under 260 pt) on smaller wide screens.
    public static let inspectorWidth: CGFloat = 300
    public static let inspectorMinWidth: CGFloat = 260
    public static let inspectorWidthFraction: CGFloat = 0.26
    public static let compactPictureCap: CGFloat = 0.42
    public static let tallPictureCap: CGFloat = 0.50
    public static let wideTimelineFraction: CGFloat = 0.40
    public static let wideTimelineMinimum: CGFloat = 230
    /// On a short wide screen (a phone turned sideways) the timeline never takes more than half of what is under the top bar,
    /// or the picture would be a sliver. Only binds under about 507 pt of height.
    public static let wideTimelineMaxFraction: CGFloat = 0.50
    /// A dragged timeline edge (`preferredTimelineHeight`) stops where the picture would be shorter than this.
    public static let widePreferredPictureMinimum: CGFloat = 120
    /// The drawer's detents: about 260 pt and 62 % of the timeline area (the smaller is `low`), never taller than the area.
    public static let drawerDetentHeight: CGFloat = 260
    public static let drawerDetentFraction: CGFloat = 0.62

    // MARK: input

    public let size: CGSize
    public let platform: Platform
    /// Canvas width / height (16:9 = 1.777…).
    public let canvasAspect: CGFloat

    // MARK: output

    public let regime: Regime
    public let content: CGRect
    public let topBar: CGRect
    /// Exactly the canvas's aspect.
    public let picture: CGRect
    public let transport: CGRect
    public let timeline: CGRect
    /// The bottom row (compact, tall) or the left rail (wide).
    public let tools: CGRect
    /// Wide only: the column right of the picture, always shown.
    public let inspector: CGRect?
    /// Compact and tall only: the drawer at each detent, bottom-aligned inside `timeline`.
    public let drawerLow: CGRect?
    public let drawerHigh: CGRect?

    /// The tools are a vertical rail (wide) rather than a bottom row.
    public var toolsAreRail: Bool { regime == .wide }

    /// The inspector's rect for a drawer detent: the wide column whatever the detent; in compact and tall the drawer, or nil
    /// when closed.
    public func inspectorRect(_ detent: DrawerDetent) -> CGRect? {
        if let inspector { return inspector }
        switch detent {
        case .closed: return nil
        case .low: return drawerLow
        case .high: return drawerHigh
        }
    }

    // MARK: regime

    public static func regime(for size: CGSize) -> Regime {
        let w = size.width, h = size.height
        if w >= 900 || (w >= 700 && w > h) { return .wide }
        if w < 600 { return .compact }
        if h > w { return .tall }
        return .compact
    }

    // MARK: building

    /// - Parameter preferredTimelineHeight: wide only (the Mac's draggable timeline edge). At least 230 pt, at most what
    ///   leaves the transport and a 120 pt picture; nil = 40 % of the height (capped at half on short screens).
    public init(size: CGSize, platform: Platform, canvasAspect: CGFloat, preferredTimelineHeight: CGFloat? = nil) {
        let w = max(0, size.width), h = max(0, size.height)
        let aspect = canvasAspect.isFinite && canvasAspect > 0 ? canvasAspect : 16.0 / 9.0
        self.size = CGSize(width: w, height: h)
        self.platform = platform
        self.canvasAspect = aspect
        let regime = Self.regime(for: self.size)
        self.regime = regime
        content = CGRect(x: 0, y: 0, width: w, height: h)

        let barHeight = min(Self.topBarHeight, h)
        topBar = CGRect(x: 0, y: 0, width: w, height: barHeight)
        let below = max(0, h - barHeight)

        switch regime {
        case .wide:
            var timelineHeight: CGFloat
            if let preferred = preferredTimelineHeight {
                // a dragged edge may go past half, but leaves the transport and some picture
                let most = max(Self.wideTimelineMinimum, below - Self.transportHeight - Self.widePreferredPictureMinimum)
                timelineHeight = min(max(Self.wideTimelineMinimum, preferred), most)
            } else {
                timelineHeight = max(Self.wideTimelineMinimum, h * Self.wideTimelineFraction)
                timelineHeight = min(timelineHeight, below * Self.wideTimelineMaxFraction)
            }
            timelineHeight = min(timelineHeight, below)
            let inspectorWidth = min(Self.inspectorWidth, max(Self.inspectorMinWidth, w * Self.inspectorWidthFraction))
            let railWidth = min(Self.toolRailWidth, w)
            let middleX = railWidth
            let middleWidth = max(0, w - railWidth - inspectorWidth)
            let rowMax = max(0, below - timelineHeight)
            let fit = Self.fit(aspect: aspect, in: CGSize(width: middleWidth, height: max(0, rowMax - Self.transportHeight)))
            // the row is as tall as the picture and its transport; the timeline takes what is left
            let rowHeight = min(rowMax, fit.height + Self.transportHeight)
            let rowY = barHeight
            picture = CGRect(x: middleX + (middleWidth - fit.width) / 2, y: rowY, width: fit.width, height: fit.height)
            transport = CGRect(x: middleX, y: picture.maxY, width: middleWidth, height: Self.transportHeight)
            tools = CGRect(x: 0, y: rowY, width: railWidth, height: rowHeight)
            inspector = CGRect(x: w - inspectorWidth, y: rowY, width: inspectorWidth, height: rowHeight)
            let timelineY = rowY + rowHeight
            timeline = CGRect(x: 0, y: timelineY, width: w, height: max(0, h - timelineY))
            drawerLow = nil
            drawerHigh = nil

        case .compact, .tall:
            let cap = h * (regime == .tall ? Self.tallPictureCap : Self.compactPictureCap)
            let fit = Self.fit(aspect: aspect, in: CGSize(width: w, height: min(cap, below)))
            picture = CGRect(x: (w - fit.width) / 2, y: barHeight, width: fit.width, height: fit.height)
            let transportHeight = min(Self.transportHeight, max(0, h - picture.maxY))
            transport = CGRect(x: 0, y: picture.maxY, width: w, height: transportHeight)
            let toolsHeight = min(Self.toolRowHeight, max(0, h - transport.maxY))
            tools = CGRect(x: 0, y: h - toolsHeight, width: w, height: toolsHeight)
            timeline = CGRect(x: 0, y: transport.maxY, width: w, height: max(0, tools.minY - transport.maxY))
            inspector = nil
            let area = timeline.height
            let a = min(area, Self.drawerDetentHeight)
            let b = min(area, area * Self.drawerDetentFraction)
            let low = min(a, b), high = max(a, b)
            drawerLow = CGRect(x: 0, y: timeline.maxY - low, width: w, height: low)
            drawerHigh = CGRect(x: 0, y: timeline.maxY - high, width: w, height: high)
        }
    }

    public init(size: CGSize, platform: Platform, canvas: EditCanvas, preferredTimelineHeight: CGFloat? = nil) {
        self.init(
            size: size, platform: platform, canvasAspect: CGFloat(canvas.w) / CGFloat(max(1, canvas.h)),
            preferredTimelineHeight: preferredTimelineHeight)
    }

    /// The largest rect of `aspect` inside `box` (not rounded: the slot is exactly the canvas's shape).
    public static func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        if box.width / box.height > aspect {
            return CGSize(width: box.height * aspect, height: box.height)
        }
        return CGSize(width: box.width, height: box.width / aspect)
    }
}
