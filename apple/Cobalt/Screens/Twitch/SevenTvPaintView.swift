import CobaltKit
import SwiftUI

// GPU-accelerated 7TV name-paint renderer (`SevenTvPaintShader.metal`).
//
// Performance & architecture contract (apple/ARCHITECTURE.md):
// - Pure procedural paints (single or multi-layer linear/radial/repeating/plain) render in 1 `colorEffect` pass
//   plus 1 `layerEffect` pass for up to 10 shadows — no `.mask` double-draw, no Core Animation shadow stack.
// - Static paints mount zero `TimelineView`, `MotionTicket`, or scroll-visibility observers.
// - Animated GPU paints isolate their `TimelineView(.animation(minimumInterval: 1/30))` to this tiny leaf,
//   gated by `MotionBudget.shader` (Low Power Mode + visible cap), `\.accessibilityReduceMotion`,
//   `\.lifecycle` (background & thermal throttle), and `.onScrollVisibilityChange`.
// - Remote `URL` image paints stay on `EmotePicture` (off-main `MediaPipeline` + `EmoteCache` + `MotionBudget.shared`).

/// Renders a Twitch username (or any short label) with a 7TV paint powered by `SevenTvPaintShader.metal`.
struct SevenTvPaintedLabel: View {
    let text: String
    let font: Font
    let paint: SevenTvPaint
    let fallback: SevenTvRGBA

    private var uniforms: SevenTvPaintShaderUniforms {
        SevenTvPaintShaderUniforms(paint: paint)
    }

    var body: some View {
        let packed = uniforms
        if paint.hasAnimatedShader {
            AnimatedSevenTvPaintLeaf(text: text, font: font, paint: paint, uniforms: packed, fallback: fallback)
        } else {
            StaticSevenTvPaintLeaf(text: text, font: font, paint: paint, uniforms: packed, fallback: fallback)
        }
    }
}

extension View {
    /// Applies a GPU-accelerated 7TV procedural paint and drop shadows to a text label.
    func sevenTvPaint(_ paint: SevenTvPaint?, fallback: SevenTvRGBA) -> some View {
        modifier(SevenTvPaintModifier(paint: paint, fallback: fallback))
    }
}

private struct SevenTvPaintModifier: ViewModifier {
    let paint: SevenTvPaint?
    let fallback: SevenTvRGBA

    func body(content: Content) -> some View {
        if let paint {
            let uniforms = SevenTvPaintShaderUniforms(paint: paint)
            if paint.hasAnimatedShader {
                AnimatedSevenTvPaintContent { phase in
                    applyShaders(to: content, uniforms: uniforms, phase: phase)
                }
            } else {
                applyShaders(to: content, uniforms: uniforms, phase: 0)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyShaders(to content: Content, uniforms: SevenTvPaintShaderUniforms, phase: Float) -> some View {
        let underlay = paint?.color.map { SevenTvRGBA.unpack($0, minAlpha: 0.35) } ?? fallback
        let filled = content
            .foregroundStyle(.white)
            .visualEffect { view, proxy in
                view.colorEffect(
                    ShaderLibrary.sevenTvPaintFill(
                        .float2(proxy.size),
                        .float(phase),
                        .float4(underlay.r, underlay.g, underlay.b, underlay.a),
                        .float(uniforms.animIntensity),
                        .floatArray(uniforms.layerFloats),
                        .floatArray(uniforms.stopFloats)
                    )
                )
            }
        SevenTvShadowWrap(uniforms: uniforms) { filled }
    }
}

/// Zero-overhead leaf for static procedural paints and pure URL image paints (no `TimelineView` or `MotionTicket`).
private struct StaticSevenTvPaintLeaf: View {
    let text: String
    let font: Font
    let paint: SevenTvPaint
    let uniforms: SevenTvPaintShaderUniforms
    let fallback: SevenTvRGBA

    @Environment(\.lifecycle) private var lifecycle

    var body: some View {
        SevenTvPaintCanvas(
            text: text,
            font: font,
            paint: paint,
            uniforms: uniforms,
            fallback: fallback,
            phase: 0,
            allowsImageMotion: lifecycle.isForeground && !lifecycle.shouldThrottle
        )
    }
}

/// Budget-gated animated leaf for drifting repeating gradients, metallic shimmers, and iridescent paints.
private struct AnimatedSevenTvPaintLeaf: View {
    let text: String
    let font: Font
    let paint: SevenTvPaint
    let uniforms: SevenTvPaintShaderUniforms
    let fallback: SevenTvRGBA

    @Environment(\.lifecycle) private var lifecycle

    var body: some View {
        AnimatedSevenTvPaintContent { phase in
            SevenTvPaintCanvas(
                text: text,
                font: font,
                paint: paint,
                uniforms: uniforms,
                fallback: fallback,
                phase: phase,
                allowsImageMotion: lifecycle.isForeground && !lifecycle.shouldThrottle
            )
        }
    }
}

/// Shared clock gate for animated GPU paints: pauses cleanly on Reduce Motion, Low Power Mode, backgrounding,
/// thermal/memory throttling, or when scrolled off screen.
private struct AnimatedSevenTvPaintContent<Content: View>: View {
    @ViewBuilder let content: (Float) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lifecycle) private var lifecycle

    @State private var ticket = MotionTicket()
    @State private var onScreen = false

    private var wantsSlot: Bool {
        onScreen && !reduceMotion && lifecycle.isForeground && !lifecycle.shouldThrottle
    }

    private var shouldAnimate: Bool {
        wantsSlot && ticket.granted
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { context in
            // Keep phase bounded in [0, 3600) so 32-bit Float never loses sub-frame precision.
            let phase: Float = shouldAnimate
                ? Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                : 0
            content(phase)
        }
        .onAppear {
            onScreen = true
            syncBudget()
        }
        .onDisappear {
            onScreen = false
            syncBudget()
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            guard visible != onScreen else { return }
            onScreen = visible
            syncBudget()
        }
        .onChange(of: wantsSlot) { _, _ in
            syncBudget()
        }
    }

    private func syncBudget() {
        MotionBudget.shader.want(ticket, wantsSlot)
    }
}

/// Pure render body executing the Metal fill + optional hybrid image layers + single-pass Metal drop shadows.
private struct SevenTvPaintCanvas: View {
    let text: String
    let font: Font
    let paint: SevenTvPaint
    let uniforms: SevenTvPaintShaderUniforms
    let fallback: SevenTvRGBA
    let phase: Float
    let allowsImageMotion: Bool

    private var underlay: SevenTvRGBA {
        paint.color.map { SevenTvRGBA.unpack($0, minAlpha: 0.35) } ?? fallback
    }

    var body: some View {
        SevenTvShadowWrap(uniforms: uniforms) {
            if uniforms.isPureProcedural {
                pureProceduralFill
            } else {
                hybridLayeredFill
            }
        }
    }

    /// Single-pass `colorEffect` directly over rasterized white glyphs (no `.mask` double render).
    private var pureProceduralFill: some View {
        let base = underlay
        let layerFloats = uniforms.layerFloats
        let stopFloats = uniforms.stopFloats
        let intensity = uniforms.animIntensity
        let currentPhase = phase

        return Text(text)
            .font(font)
            .foregroundStyle(.white)
            .visualEffect { content, proxy in
                content.colorEffect(
                    ShaderLibrary.sevenTvPaintFill(
                        .float2(proxy.size),
                        .float(currentPhase),
                        .float4(base.r, base.g, base.b, base.a),
                        .float(intensity),
                        .floatArray(layerFloats),
                        .floatArray(stopFloats)
                    )
                )
            }
    }

    /// Bottom-to-top compositing for URL image paints and multi-layer paints that combine gradients with images.
    private var hybridLayeredFill: some View {
        let label = Text(text).font(font)
        let baseColor = Color(
            .sRGB,
            red: Double(underlay.r),
            green: Double(underlay.g),
            blue: Double(underlay.b),
            opacity: Double(underlay.a)
        )
        let animMode = uniforms.animMode
        let animSpeed = uniforms.animSpeed
        let animIntensity = uniforms.animIntensity
        let currentPhase = phase

        return label
            .foregroundStyle(.clear)
            .overlay {
                ZStack {
                    baseColor
                    ForEach(Array(uniforms.steps.enumerated()), id: \.offset) { _, step in
                        switch step {
                        case let .procedural(layerFloats, stopFloats, _):
                            Color.white.visualEffect { content, proxy in
                                content.colorEffect(
                                    ShaderLibrary.sevenTvPaintFill(
                                        .float2(proxy.size),
                                        .float(currentPhase),
                                        .float4(0, 0, 0, 0),
                                        .float(animIntensity),
                                        .floatArray(layerFloats),
                                        .floatArray(stopFloats)
                                    )
                                )
                            }
                        case let .image(url, _, opacity, animated):
                            EmotePicture(
                                url: url,
                                animated: animated && allowsImageMotion,
                                side: 64,
                                fill: true
                            )
                            .visualEffect { content, proxy in
                                content.colorEffect(
                                    ShaderLibrary.sevenTvImagePaintOverlay(
                                        .float2(proxy.size),
                                        .float(currentPhase),
                                        .float(animMode),
                                        .float(animSpeed),
                                        .float(animIntensity),
                                        .float(Float(opacity))
                                    ),
                                    isEnabled: opacity < 0.999 || (animMode >= 1.5 && currentPhase > 0)
                                )
                            }
                        }
                    }
                }
                .clipped()
            }
            .mask { label }
    }
}

/// Applies up to 10 crisp or glowing 7TV shadows in one GPU `layerEffect` pass while keeping the text's layout bounds
/// completely unchanged (symmetric positive/negative padding lets shadows bleed past tight glyph boxes unclipped).
private struct SevenTvShadowWrap<Content: View>: View {
    let uniforms: SevenTvPaintShaderUniforms
    @ViewBuilder let content: () -> Content

    var body: some View {
        if uniforms.hasShadows {
            let padX = CGFloat(uniforms.shadowPadX)
            let padY = CGFloat(uniforms.shadowPadY)
            let shadowFloats = uniforms.shadowFloats
            content()
                .padding(.horizontal, padX)
                .padding(.vertical, padY)
                .layerEffect(
                    ShaderLibrary.sevenTvDropShadows(.floatArray(shadowFloats)),
                    maxSampleOffset: CGSize(width: padX, height: padY)
                )
                .padding(.horizontal, -padX)
                .padding(.vertical, -padY)
        } else {
            content()
        }
    }
}

// MARK: - SwiftUI preview gallery

#Preview("7TV Metal Paint Gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("7TV Metal Paint Shaders")
                .font(.title3.bold())
                .foregroundStyle(.white)
            ForEach(SevenTvPaint.showcaseSamples, id: \.id) { paint in
                HStack(spacing: 10) {
                    SevenTvPaintedLabel(
                        text: "CapybaraHarmony",
                        font: .system(size: 16, weight: .bold),
                        paint: paint,
                        fallback: SevenTvRGBA(r: 0.7, g: 0.6, b: 1, a: 1)
                    )
                    Spacer(minLength: 8)
                    Text(paint.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
    }
    .background(Color(white: 0.06))
    .preferredColorScheme(.dark)
}
