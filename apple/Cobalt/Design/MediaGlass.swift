import SwiftUI

// Clear Liquid Glass over media, edge legibility vignettes, and unified floating media headers
// (Apple iOS 26–27 Liquid Glass over media HIG).
//
// Rules:
//   - Over video/photo/map/stream canvases, prefer Clear Liquid Glass (`.glassEffect(.clear.interactive())`)
//     paired with subtle top/bottom edge vignettes instead of opaque dark slabs.
//   - Group related floating media buttons inside `MediaGlassGroup` (`GlassEffectContainer`) so
//     adjacent pills morph and share specular highlights cohesively.
//   - Keep floating HUD controls inside system safe areas so they never collide with iPhone Duo's
//     asymmetric vertical rail or `.occlusion` camera cutout.

/// Subtle gradient scrim placed along the top or bottom edge of a media canvas behind Clear Liquid Glass
/// controls so icons and labels stay legible over bright skies and dark frames alike.
struct MediaEdgeVignette: View {
    enum Edge { case top, bottom }

    let edge: Edge
    var height: CGFloat = 104
    var intensity: Double = 0.44

    var body: some View {
        LinearGradient(
            colors: edge == .top
                ? [.black.opacity(intensity), .black.opacity(intensity * 0.25), .clear]
                : [.clear, .black.opacity(intensity * 0.25), .black.opacity(intensity)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Cohesive container for adjacent Clear Liquid Glass media controls.
struct MediaGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}

/// Compact floating glass header pill merging a status indicator, title, and optional trailing affordance
/// (e.g. inline edit/visibility popover) into one clean surface over media.
struct MediaUnifiedHeaderPill<Trailing: View>: View {
    let title: String
    var statusColor: Color? = nil
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        statusColor: Color? = nil,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.statusColor = statusColor
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(CobaltType.buttonSmall)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.hit)
        .mediaGlassCapsule(interactive: false)
    }
}

extension View {
    /// Applies Clear Liquid Glass in a capsule over media canvases (photos, videos, streams, maps).
    func mediaGlassCapsule(interactive: Bool = true, tint: Color? = nil) -> some View {
        let base: Glass = interactive ? .clear.interactive() : .clear
        let styled: Glass = tint.map { base.tint($0) } ?? base
        return self.glassEffect(styled, in: .capsule)
    }

    /// Applies Clear Liquid Glass in a circle over media canvases (44 pt+ circular HUD buttons).
    func mediaGlassCircle(interactive: Bool = true, tint: Color? = nil) -> some View {
        let base: Glass = interactive ? .clear.interactive() : .clear
        let styled: Glass = tint.map { base.tint($0) } ?? base
        return self.glassEffect(styled, in: .circle)
    }

    /// Applies Clear Liquid Glass in a continuous rounded rectangle over media canvases.
    func mediaGlassRounded(cornerRadius: CGFloat = Metrics.thumbRadius, interactive: Bool = true, tint: Color? = nil) -> some View {
        let base: Glass = interactive ? .clear.interactive() : .clear
        let styled: Glass = tint.map { base.tint($0) } ?? base
        return self.glassEffect(styled, in: .rect(cornerRadius: cornerRadius))
    }
}
