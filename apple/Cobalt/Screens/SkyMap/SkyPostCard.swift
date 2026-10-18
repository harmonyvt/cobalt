import CobaltKit
import SwiftUI

/// A post's embedding as a small field of stars, a port of the web's `fingerprint()` (`page.html` about line 1905): the
/// first 256 numbers as a 16 x 16 grid, bigger and brighter = a bigger number, cool above zero, warm below.
struct SkyFingerprintView: View {
    let vector: [Float]
    var side: CGFloat = 84
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = SkyTheme.of(scheme)
        let stars = SkyFingerprint.stars(for: vector)
        let cool = SkyRGB(SkyPalette.cool(dark: theme.dark)), warm = SkyRGB(SkyPalette.warm(dark: theme.dark))
        let dust = SkyDustField.make(size: CGSize(width: 208, height: 208))
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [theme.top.color(), theme.bottom.color()]), center: CGPoint(x: size.width * 0.5, y: size.height * 0.35),
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.75))
            // the sky behind it, as the web paints the same backdrop under the fingerprint
            let unit = size.width / 208
            for s in dust {
                var c = ctx
                c.opacity = s.alpha * (theme.dark ? 1 : 0.55)
                let r = s.radius * unit
                c.fill(Path(ellipseIn: CGRect(x: s.x * unit - r, y: s.y * unit - r, width: r * 2, height: r * 2)), with: .color(theme.star.color()))
            }
            for star in stars {
                let rgb = star.positive ? cool : warm
                let x = star.x * size.width, y = star.y * size.height, r = star.radius * size.width
                if theme.dark, star.strength > 0.35 {
                    let g = size.width / 16 * 2.2 * star.strength
                    if let glow = SkyBitmaps.glow(rgb) {
                        var c = ctx
                        c.opacity = star.strength
                        c.draw(c.resolve(Image(decorative: glow, scale: 1)), in: CGRect(x: x - g / 2, y: y - g / 2, width: g, height: g))
                    }
                }
                var c = ctx
                c.opacity = 0.25 + 0.75 * star.strength
                c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(rgb.color()))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color(theme.lineAlpha), lineWidth: 0.5) }
        .accessibilityElement()
        .accessibilityLabel(Copy.SkyMap.fingerprintA11y)
    }
}

/// What a long press (or, with a pointer, a moment's hover) on a star shows: the poster, the title, what its
/// neighbourhood is about, the post's star fingerprint and, when pinned, an `open` button.
struct SkyPostCard: View {
    let post: MapPost
    /// The keywords of the post and its nearest neighbours (`SkyMapModel.neighbourhoodKeywords`).
    let near: [String]
    let theme: SkyTheme
    /// False for the hover card: it only describes; a click opens.
    let showsOpen: Bool
    let open: () -> Void

    static let width: CGFloat = 232

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            poster
                .frame(width: Self.width, height: 128)
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(post.title ?? Copy.SkyMap.untitled)
                    .font(Font.cobalt(13, .medium))
                    .foregroundStyle(theme.dark ? Color.white.opacity(0.92) : Color.black.opacity(0.86))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !near.isEmpty {
                    Text(Copy.SkyMap.near(near))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(theme.label.color())
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    SkyFingerprintView(vector: post.vector, side: 72)
                    Spacer(minLength: 0)
                    if showsOpen {
                        Button(action: open) {
                            Label(Copy.SkyMap.open, systemImage: Symbol.SkyMap.open)
                                .font(CobaltType.buttonSmall)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(width: Self.width, alignment: .leading)
        }
        .frame(width: Self.width)
        .background(theme.tip.color(theme.tipAlpha))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line.color(theme.lineAlpha), lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        .environment(\.colorScheme, theme.dark ? .dark : .light)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = post.imageURL {
            // the sparkle shows through until the picture arrives (and stays if it never does)
            ZStack {
                theme.bottom.color()
                Image(systemName: Symbol.SkyMap.empty)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.label.color(0.6))
                RemoteStill(poster: RemotePoster(url: url, isVideo: false), maxPixel: 480)
            }
        } else {
            ZStack {
                theme.bottom.color()
                Image(systemName: Symbol.SkyMap.empty)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.label.color(0.6))
            }
        }
    }
}
