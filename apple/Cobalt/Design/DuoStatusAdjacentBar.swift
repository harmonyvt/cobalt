import CobaltKit
import SwiftUI

// MARK: - Surface & Debug Configuration

/// Visual surface treatment for `DuoStatusAdjacentBar`.
///
/// - `.bezelMatte`: Pure black (`#000000`) bezel-matching strip above 16:9 video (Twitch single & dual stream),
///   so the status-bar area merges cleanly into the top bezel and never floats over video frames.
/// - `.clearLiquidGlass`: Transparent container backed by Clear Liquid Glass pills over full-bleed
///   edge-to-edge media canvases (Ambient Cinema Post Studio).
enum DuoStatusAdjacentBarSurface: Equatable, Sendable {
    case bezelMatte
    case clearLiquidGlass
}

/// Debug toggle for exercising the iPhone Duo top status-adjacent bar in simulators or Xcode previews
/// via launch argument `-previewDuoStatusBar YES`.
enum DuoStatusAdjacentBarDebug {
    static var isForced: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "previewDuoStatusBar")
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    /// Forces `DuoStatusAdjacentBar` active in SwiftUI `#Preview` blocks on standard simulator canvases.
    @Entry var duoStatusAdjacentBarForcePreview: Bool = false
}

// MARK: - Geometry Resolution Bridge

extension DuoStatusAdjacentBarMetrics {
    /// Resolves iPhone Duo top status-adjacent bar geometry from live window safe area, host size,
    /// `ReservedRegion` snapshot, and current Dynamic Type size.
    static func resolve(
        hostSize: CGSize,
        safeArea: EdgeInsets,
        reserved: DuoReservedRegions,
        typeSize: DynamicTypeSize,
        forcePreview: Bool = false
    ) -> DuoStatusAdjacentBarMetrics {
        DuoStatusAdjacentBarLayout.resolve(
            containerSize: hostSize,
            topSafeArea: safeArea.top,
            leadingSafeArea: safeArea.leading,
            trailingSafeArea: safeArea.trailing,
            occlusion: reserved.occlusion,
            anyDivision: reserved.anyDivision,
            isAccessibilityText: typeSize.isAccessibilitySize,
            isMac: Platform.isMac,
            forceEnable: forcePreview || DuoStatusAdjacentBarDebug.isForced
        )
    }
}

// MARK: - Container

/// Compact horizontal chrome strip occupying the leading portion of the iPhone Duo top status band
/// (beside `9:41` and the trailing circular camera/signal status orb, directly above full-bleed media).
///
/// Automatically clears the leading hinge/corner radius (`metrics.leadingInset`) and reserves the
/// trailing exclusion zone (`trailingReserveOverride ?? metrics.trailingReserve`) for `9:41`,
/// `ReservedRegion(.occlusion)`, and the top-right Control Center gesture region.
struct DuoStatusAdjacentBar<Content: View>: View {
    let surface: DuoStatusAdjacentBarSurface
    let metrics: DuoStatusAdjacentBarMetrics
    /// Optional override when the enclosing canvas is already narrower than the full window on the trailing
    /// edge (e.g. Ambient Cinema with a docked Studio Deck sitting beneath `9:41` + status orb).
    var trailingReserveOverride: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let trailing = trailingReserveOverride ?? metrics.trailingReserve
        Group {
            switch surface {
            case .bezelMatte:
                barRow(trailing: trailing)
                    .background(Color.black)
            case .clearLiquidGlass:
                MediaGlassGroup(spacing: 6) {
                    barRow(trailing: trailing)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.statusAdjacentBar")
    }

    private func barRow(trailing: CGFloat) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.leading, metrics.leadingInset)
        .padding(.trailing, trailing)
        .frame(maxWidth: .infinity, minHeight: metrics.bandHeight, maxHeight: metrics.bandHeight, alignment: .leading)
    }
}

// MARK: - Compact Bar Primitives

/// Circular leading back/dismiss button sized for the ~54–58 pt status-adjacent strip with a full-height hit target.
struct DuoStatusBarBackButton: View {
    let surface: DuoStatusAdjacentBarSurface
    var accessibilityLabel: String = Copy.close
    var accessibilityID: String = "pane.close"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            backVisual
                .frame(minWidth: 36, minHeight: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private var backVisual: some View {
        let icon = Image(systemName: "chevron.backward")
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)

        switch surface {
        case .bezelMatte:
            icon
                .background(Color.white.opacity(0.11), in: Circle())
        case .clearLiquidGlass:
            icon
                .mediaGlassCircle()
        }
    }
}

/// Compact circular icon visual for status-bar actions (`⋯`, play/pause, glow, captions) with generous hit area.
struct DuoStatusBarIconVisual: View {
    let systemImage: String
    let surface: DuoStatusAdjacentBarSurface
    var foreground: Color = .white
    var highlighted: Bool = false
    var tint: Color? = nil

    var body: some View {
        iconCircle
            .frame(minWidth: 36, minHeight: Metrics.hit)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconCircle: some View {
        let usesLightSurface = surface == .bezelMatte && highlighted && tint == nil
        let symbol = Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(usesLightSurface ? .black : foreground)
            .frame(width: 32, height: 32)

        switch surface {
        case .bezelMatte:
            symbol
                .background(
                    tint ?? (highlighted ? Color.white : Color.white.opacity(0.11)),
                    in: Circle()
                )
        case .clearLiquidGlass:
            symbol
                .mediaGlassCircle(tint: tint ?? (highlighted ? CobaltColor.focus : nil))
        }
    }
}

/// Compact capsule pill visual for status-bar actions (`+ 2nd`, `Copy Share`, `Deck`, `Swap`, `50/50`).
struct DuoStatusBarPillVisual: View {
    let title: String
    var systemImage: String? = nil
    let surface: DuoStatusAdjacentBarSurface
    var emphasized: Bool = false
    var tint: Color? = nil

    var body: some View {
        pillCapsule
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var pillCapsule: some View {
        let usesLightSurface = surface == .bezelMatte && emphasized && tint == nil
        let label = HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            Text(title)
                .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                .lineLimit(1)
        }
        .foregroundStyle(usesLightSurface ? .black : .white)
        .padding(.horizontal, 10)
        .frame(height: 30)

        switch surface {
        case .bezelMatte:
            label
                .background(
                    tint ?? (emphasized ? Color.white : Color.white.opacity(0.12)),
                    in: Capsule()
                )
        case .clearLiquidGlass:
            label
                .mediaGlassCapsule(tint: tint ?? (emphasized ? CobaltColor.focus : nil))
        }
    }
}
