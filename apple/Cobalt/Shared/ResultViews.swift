import CobaltKit
import SwiftUI

/// "10.0 s": the clip length, rolling as the bracket moves. Red while the bracket is over the limit.
struct LengthReadout: View {
    let seconds: Double
    var over = false
    var font: Font = CobaltType.readout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(Format.seconds(seconds))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(over ? CobaltColor.errorText : CobaltColor.text)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText(value: seconds))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: seconds)
    }
}

/// A light sheen that sweeps across a thumbnail. Still under Reduce Motion.
struct Sheen: View {
    var period: Double = 2.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                PhaseAnimator([-1.0, 1.0]) { phase in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.12), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width)
                        .offset(x: phase * proxy.size.width)
                } animation: { _ in
                    .easeInOut(duration: period)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The webp tile on the done card: the bracket's span lifts into it. It shows a real frame when the
/// pipeline has one, the board's grey gradient otherwise.
struct ResultTile: View {
    let pipeline: Pipeline
    let result: WebpResult
    var maxWidth: CGFloat = 146
    var maxHeight: CGFloat = 260
    var spanNamespace: Namespace.ID?

    private var size: CGSize {
        let w = CGFloat(max(1, result.width)), h = CGFloat(max(1, result.height))
        let k = min(maxWidth / w, maxHeight / h)
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }

    var body: some View {
        let frame = pipeline.frames.indices.contains(4) ? pipeline.frames[4] : nil
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
                .fill(FrameGradient.fill(1))
            if let frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            Sheen()
            Text(Format.seconds(result.seconds))
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
        .modifier(SpanMatch(namespace: spanNamespace))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.resultA11y)
        .accessibilityValue(Format.seconds(result.seconds))
    }
}

private struct SpanMatch: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: "span", in: namespace) } else { content }
    }
}

/// "480×854 · 10.1 s · 4.5 MB"
func resultMeta(_ result: WebpResult) -> String {
    "\(Format.size(result.width, result.height)) · \(Format.seconds(result.seconds)) · \(Format.bytes(result.bytes))"
}

/// "media.capybaraharmony.com/PrEvIeW001.webp": the URL without its scheme.
func displayURL(_ url: URL) -> String {
    let text = url.absoluteString
    if let range = text.range(of: "://") { return String(text[range.upperBound...]) }
    return text
}

/// The service chip: "x · 2105435404002562056". Scales in from the right with a blur.
struct LinkChip: View {
    let service: String
    let ref: String

    var body: some View {
        HStack(spacing: 8) {
            Text(service)
                .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(ref)
                .font(Font.cobalt(13, .regular, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChipIn: ViewModifier {
    let on: Bool
    let reduced: Bool

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(on || reduced ? 1 : 1.35, anchor: .trailing)
            .blur(radius: on || reduced ? 0 : 5)
    }
}

extension AnyTransition {
    /// scale 1.35 + blur 5 to none, from the right; a crossfade under Reduce Motion.
    static func chipIn(reduced: Bool) -> AnyTransition {
        .modifier(active: ChipIn(on: false, reduced: reduced), identity: ChipIn(on: true, reduced: reduced))
    }
}
