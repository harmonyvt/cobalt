import CobaltKit
import SwiftUI

// Fold-aware layout containers and ReservedRegion bridges for iPhone Duo (iOS 27.1+)
// and regular/compact SwiftUI windows (iOS 26 / macOS 26+).
//
// House rules (apple/ARCHITECTURE.md, iPhone Duo rules):
//   1. Two size classes (`.compact` vs `.regular`) — never `UIDevice.current.userInterfaceIdiom` for layout.
//   2. Use `DuoSplit` for two-pane workspaces (Inspector, Editor, Preview, Settings, Stage, 7TV).
//      On iOS 27.1+ this uses `ArrangementView` with `.arrangementViewStyle(.split)` so the system
//      splits cleanly across Tabletop and Book folds.
//   3. Use `DuoMediaOverlay` for full-screen media canvases + HUD controls (Detail, Video, Twitch, SkyMap).
//      On iOS 27.1+ this uses `ArrangementView` with `.arrangementViewStyle(.overlay)` so controls float
//      in Clear Liquid Glass when flat/outer and separate cleanly across the fold when bent (`isSeparated == true`).
//   4. NEVER place `DuoSplit` / `DuoMediaOverlay` / `ArrangementView` inside a `ScrollView` or `List`,
//      and NEVER nest `TabView` or `NavigationSplitView` inside them.

// MARK: - Overlay Separation Environment

private struct DuoOverlaySeparatedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when an enclosing `DuoMediaOverlay` has separated controls across an active iPhone Duo fold
    /// (`overlayArrangementZIndex == 0` on iOS/macOS 27.1+). False when controls float layered over media.
    var duoOverlaySeparated: Bool {
        get { self[DuoOverlaySeparatedKey.self] }
        set { self[DuoOverlaySeparatedKey.self] = newValue }
    }
}

// MARK: - Reserved Regions Snapshot

/// Snapshot of active hardware reserved regions (`ReservedRegion(.division)` and `ReservedRegion(.occlusion)`).
struct DuoReservedRegions: Equatable, Sendable {
    /// Active folding crease frame in the observing geometry proxy's local coordinate space, if currently folded.
    var activeDivision: CGRect?
    /// Inactive or active folding crease frame (when querying `.includeInactive`).
    var anyDivision: CGRect?
    /// Active camera / Dynamic Island occlusion frame in the observing proxy's local space.
    var occlusion: CGRect?

    var isFolded: Bool { activeDivision != nil }

    static let empty = DuoReservedRegions()

    @available(iOS 27.1, macOS 27.1, *)
    static func read(from proxy: GeometryProxy) -> DuoReservedRegions {
        let activeDiv = proxy.reservedRegions(kind: .division).first?.frame
        let anyDiv = activeDiv ?? proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
        let occ = proxy.reservedRegions(kind: .occlusion).first?.frame
        return DuoReservedRegions(activeDivision: activeDiv, anyDivision: anyDiv, occlusion: occ)
    }

    static func readCompat(from proxy: GeometryProxy) -> DuoReservedRegions {
        if #available(iOS 27.1, macOS 27.1, *) {
            return read(from: proxy)
        }
        return .empty
    }
}

// MARK: - DuoSplit (Fold-Aware Two-Pane Workspace)

/// A fold-aware two-pane workspace container.
///
/// - On iOS 27.1+ / macOS 27.1+: wraps SwiftUI's `ArrangementView` with `.arrangementViewStyle(.split)`
///   so primary and secondary panes align cleanly to active Tabletop (horizontal) and Book (vertical) folds.
/// - On iOS 26 / macOS 26 (or compact fallback when `collapseToPrimaryWhenCompact` is false): switches
///   between `HStack` (when `horizontalSizeClass == .regular`) and `VStack` (when `.compact`).
///
/// Keep `NavigationSplitView` and `TabView` outside `DuoSplit`, and never nest `DuoSplit` inside a
/// `ScrollView`, `List`, or `Grid`.
struct DuoSplit<Primary: View, Secondary: View>: View {
    var ratio: CGFloat? = nil
    var axes: Axis.Set = [.horizontal, .vertical]
    var spacing: CGFloat = 0
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if #available(iOS 27.1, macOS 27.1, *) {
            ArrangementView {
                primary()
                    .splitArrangementLayoutRatio(ratio)
            } secondary: {
                secondary()
            }
            .arrangementViewStyle(.split.axes(axes))
        } else {
            fallbackLayout
        }
    }

    @ViewBuilder
    private var fallbackLayout: some View {
        let preferHorizontal = axes.contains(.horizontal) && (sizeClass == .regular || !axes.contains(.vertical))
        if preferHorizontal {
            HStack(spacing: spacing) {
                primary()
                secondary()
            }
        } else {
            VStack(spacing: spacing) {
                primary()
                secondary()
            }
        }
    }
}

// MARK: - DuoMediaOverlay (Fold-Aware Media + Floating HUD / Studio Deck)

/// Preferred edge when `DuoMediaOverlay` separates controls across a fold.
enum DuoOverlayEdge: Equatable, Sendable {
    case automatic
    case bottom
    case top
    case leading
    case trailing
}

/// A fold-aware media stage with controls that float in Clear Liquid Glass when flat/outer
/// (`isSeparated == false`) and separate onto the adjacent display half when partially folded
/// into Tabletop or Book posture (`isSeparated == true`).
///
/// Keep `NavigationSplitView` and `TabView` outside `DuoMediaOverlay`, and never nest it inside
/// a `ScrollView`, `List`, or `Grid`.
struct DuoMediaOverlay<Controls: View, Media: View>: View {
    var edge: DuoOverlayEdge = .automatic
    var axes: Axis.Set = [.horizontal, .vertical]
    @ViewBuilder let controls: (_ isSeparated: Bool) -> Controls
    @ViewBuilder let media: () -> Media

    var body: some View {
        if #available(iOS 27.1, macOS 27.1, *) {
            DuoMediaOverlay27(edge: edge, axes: axes, controls: controls, media: media)
        } else {
            ZStack {
                media()
                controls(false)
                    .environment(\.duoOverlaySeparated, false)
            }
        }
    }
}

@available(iOS 27.1, macOS 27.1, *)
private struct DuoMediaOverlay27<Controls: View, Media: View>: View {
    let edge: DuoOverlayEdge
    let axes: Axis.Set
    @ViewBuilder let controls: (_ isSeparated: Bool) -> Controls
    @ViewBuilder let media: () -> Media

    @State private var isSeparated = false

    var body: some View {
        ArrangementView {
            DuoOverlayControlsBridge(controls: controls) { separated in
                if isSeparated != separated {
                    isSeparated = separated
                }
            }
            .modifier(DuoOverlayEdgeModifier(edge: edge, axes: axes, isPrimary: true))
        } secondary: {
            media()
                .environment(\.duoOverlaySeparated, isSeparated)
                .modifier(DuoOverlayEdgeModifier(edge: edge, axes: axes, isPrimary: false))
        }
        .arrangementViewStyle(.overlay.axes(axes))
    }
}

@available(iOS 27.1, macOS 27.1, *)
private struct DuoOverlayControlsBridge<Controls: View>: View {
    @Environment(\.overlayArrangementZIndex) private var overlayZIndex
    @ViewBuilder let controls: (_ isSeparated: Bool) -> Controls
    let onSeparatedChange: (Bool) -> Void

    var body: some View {
        let isSeparated = overlayZIndex == 0
        controls(isSeparated)
            .environment(\.duoOverlaySeparated, isSeparated)
            .onChange(of: isSeparated, initial: true) { _, separated in
                onSeparatedChange(separated)
            }
    }
}

/// Anchors primary controls and secondary media to opposite edges when `ArrangementView(.overlay)` separates
/// across an active iPhone Duo fold. Applying `overlayArrangementEdge(_:)` to the outer `ArrangementView` would
/// propagate the same edge into both children and stack media behind controls in Tabletop vertical splits.
@available(iOS 27.1, macOS 27.1, *)
private struct DuoOverlayEdgeModifier: ViewModifier {
    let edge: DuoOverlayEdge
    let axes: Axis.Set
    let isPrimary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch edge {
        case .automatic:
            content
        case .top:
            content.overlayArrangementEdge(isPrimary ? VerticalEdge.top : VerticalEdge.bottom)
        case .bottom:
            if axes.contains(.horizontal) {
                content
                    .overlayArrangementEdge(isPrimary ? VerticalEdge.bottom : VerticalEdge.top)
                    .overlayArrangementEdge(isPrimary ? HorizontalEdge.trailing : HorizontalEdge.leading)
            } else {
                content.overlayArrangementEdge(isPrimary ? VerticalEdge.bottom : VerticalEdge.top)
            }
        case .leading:
            content.overlayArrangementEdge(isPrimary ? HorizontalEdge.leading : HorizontalEdge.trailing)
        case .trailing:
            content.overlayArrangementEdge(isPrimary ? HorizontalEdge.trailing : HorizontalEdge.leading)
        }
    }
}

// MARK: - Fold-Safe Grid Columns Helper

extension DuoGrid {
    /// Builds `[GridItem]` using `DuoGrid.columnCount` so grids on `.regular` horizontal width
    /// always use even column counts (2, 4, 6…) and never straddle the center fold crease.
    static func gridItems(
        forWidth width: CGFloat,
        minItemWidth: CGFloat,
        spacing: CGFloat = 8,
        margin: CGFloat = 0,
        sizeClass: UserInterfaceSizeClass?,
        minColumns: Int = 2,
        maxColumns: Int? = nil
    ) -> [GridItem] {
        let isRegular = sizeClass == .regular || Platform.isMac
        let count = columnCount(
            forWidth: Double(width),
            minItemWidth: Double(minItemWidth),
            spacing: Double(spacing),
            margin: Double(margin),
            isRegular: isRegular,
            minColumns: minColumns,
            maxColumns: maxColumns)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// Fixed-count fold-safe grid items: uses `compact` columns on compact width and snaps `regular`
    /// to an even column count on regular width / Mac.
    static func fixedGridItems(
        compact: Int = 2,
        regular: Int = 4,
        spacing: CGFloat = 8,
        sizeClass: UserInterfaceSizeClass?
    ) -> [GridItem] {
        let isRegular = sizeClass == .regular || Platform.isMac
        let count = isRegular ? snapEven(regular, min: 2) : max(1, compact)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }
}

/// Drop-in replacement for `LazyVGrid(columns: [GridItem(.adaptive(...))])` that automatically enforces
/// fold-safe even column counts (2, 4, 6…) in `.regular` horizontal width so cards never straddle the
/// iPhone Duo center fold crease.
struct DuoAdaptiveGrid<Content: View>: View {
    let minItemWidth: CGFloat
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat? = nil
    var alignment: HorizontalAlignment = .center
    var minColumns: Int = 2
    var maxColumns: Int? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var measuredWidth: CGFloat = 0

    private var columns: [GridItem] {
        if measuredWidth > 0 {
            return DuoGrid.gridItems(
                forWidth: measuredWidth,
                minItemWidth: minItemWidth,
                spacing: spacing,
                sizeClass: sizeClass,
                minColumns: minColumns,
                maxColumns: maxColumns)
        }
        return DuoGrid.fixedGridItems(
            compact: minColumns,
            regular: max(minColumns, 2),
            spacing: spacing,
            sizeClass: sizeClass)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: alignment, spacing: rowSpacing ?? spacing) {
            content()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - measuredWidth) > 1 {
                measuredWidth = width
            }
        }
    }
}

