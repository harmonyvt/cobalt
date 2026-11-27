import Foundation

// Pure, Sendable uniform packing for the Metal 7TV name-paint shaders (`SevenTvPaintShader.metal`).
// Kept in CobaltKit so every float layout, clamping rule, multi-layer split, and shadow bleed calculation is
// unit-tested without needing a Metal device.

/// Straight sRGB RGBA floats (`0...1`) ready for Metal uniforms.
public struct SevenTvRGBA: Sendable, Hashable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Unpacks a 7TV `0xRRGGBBAA` integer. `minAlpha` keeps partially transparent fills readable when desired.
    public static func unpack(_ rgba: UInt32, minAlpha: Float = 0) -> SevenTvRGBA {
        SevenTvRGBA(
            r: Float((rgba >> 24) & 0xFF) / 255,
            g: Float((rgba >> 16) & 0xFF) / 255,
            b: Float((rgba >> 8) & 0xFF) / 255,
            a: max(minAlpha, Float(rgba & 0xFF) / 255)
        )
    }
}

/// Packed flat float arrays matching `SevenTvPaintShader.metal`'s exact buffer strides.
public struct SevenTvPaintShaderUniforms: Sendable, Equatable {
    /// Floats per layer in `layerFloats`:
    /// `[kind, angleRad, repeats, opacity, stopOffset, stopCount, baseR, baseG, baseB, baseA, animMode, animSpeed]`
    public static let layerStride = 12
    /// Floats per stop in `stopFloats`: `[at, r, g, b, a]`
    public static let stopStride = 5
    /// Floats per shadow in `shadowFloats`: `[xOffset, yOffset, radius, r, g, b, a, reserved]`
    public static let shadowStride = 8
    /// Maximum shadows packed into a single GPU pass (matches the max seen across all 7TV paints).
    public static let maxShadows = 10
    /// Maximum stops packed per layer (7TV's richest paints have ~28 stops).
    public static let maxStopsPerLayer = 32
    /// Maximum layers packed into a single GPU fill pass.
    public static let maxLayers = 8

    /// One sequential render pass when a paint mixes procedural GPU layers with remote image layers.
    public enum RenderStep: Sendable, Equatable {
        /// One or more consecutive non-image layers evaluated in a single `sevenTvPaintFill` shader call.
        case procedural(layerFloats: [Float], stopFloats: [Float], layerCount: Int)
        /// A remote image (`URL`) texture layer rendered via `EmotePicture` (off-main `MediaPipeline` + `MotionBudget`).
        case image(url: URL, fallbackColor: UInt32?, opacity: Double, animated: Bool)
    }

    /// Encoded procedural layers for single-pass non-image paints (always non-empty for Metal buffer binding safety).
    public let layerFloats: [Float]
    /// Encoded gradient stops sorted ascending by `at` (always non-empty for Metal buffer binding safety).
    public let stopFloats: [Float]
    /// Logical count of procedural layers in `layerFloats`.
    public let layerCount: Int
    /// Encoded drop shadows (`maxShadows` cap, always non-empty for Metal buffer binding safety).
    public let shadowFloats: [Float]
    /// Logical count of shadows in `shadowFloats`.
    public let shadowCount: Int
    /// Horizontal/vertical canvas bleed (points) needed around text so shadows never clip.
    public let shadowPadX: Float
    public let shadowPadY: Float
    /// Animation intensity (`0...1`) and encoded animation mode (`0` none, `1` drift, `2` shimmer, `3` iridescent).
    public let animMode: Float
    public let animSpeed: Float
    public let animIntensity: Float
    /// Ordered render steps for paints containing image layers (empty when pure procedural).
    public let steps: [RenderStep]

    public var hasShadows: Bool { shadowCount > 0 }
    public var isPureProcedural: Bool { steps.count == 1 && { if case .procedural = steps[0] { return true }; return false }() }

    public init(paint: SevenTvPaint) {
        let animModeCode = Self.encodeAnimMode(paint.animation.mode)
        let animSpeedVal = Float(paint.animation.speed)
        let animIntensityVal = Float(paint.animation.intensity)
        self.animMode = animModeCode
        self.animSpeed = animSpeedVal
        self.animIntensity = animIntensityVal

        // Group consecutive non-image layers so pure gradient/multi-layer paints execute in 1 GPU shader call,
        // while hybrid gradient + URL image paints preserve exact bottom-to-top compositing order.
        var builtSteps: [RenderStep] = []
        var pendingProcedural: [SevenTvPaint.Layer] = []

        func flushProcedural() {
            guard !pendingProcedural.isEmpty else { return }
            let packed = Self.packProcedural(
                layers: pendingProcedural,
                animMode: animModeCode,
                animSpeed: animSpeedVal
            )
            if packed.layerCount > 0 {
                builtSteps.append(.procedural(
                    layerFloats: packed.layerFloats,
                    stopFloats: packed.stopFloats,
                    layerCount: packed.layerCount
                ))
            }
            pendingProcedural.removeAll(keepingCapacity: true)
        }

        for layer in paint.resolvedLayers.prefix(Self.maxLayers) {
            if layer.kind == .image, let url = layer.imageURL {
                flushProcedural()
                builtSteps.append(.image(
                    url: url,
                    fallbackColor: layer.color ?? paint.color,
                    opacity: layer.opacity,
                    animated: layer.animatedImage
                ))
            } else {
                pendingProcedural.append(layer)
            }
        }
        flushProcedural()
        self.steps = builtSteps

        if builtSteps.count == 1, case let .procedural(lFloats, sFloats, lCount) = builtSteps[0] {
            self.layerFloats = lFloats
            self.stopFloats = sFloats
            self.layerCount = lCount
        } else {
            self.layerFloats = [0]
            self.stopFloats = [0]
            self.layerCount = 0
        }

        // Pack up to 10 drop shadows with clamped offsets/radii and compute exact unclipped canvas padding.
        var sFloats: [Float] = []
        var sCount = 0
        var padX: Float = 0
        var padY: Float = 0
        for shadow in paint.shadows.prefix(Self.maxShadows) {
            let rgba = SevenTvRGBA.unpack(shadow.rgba)
            guard rgba.a > 0.001 else { continue }
            let xOff = Float(max(-6, min(6, shadow.xOffset)))
            let yOff = Float(max(-6, min(6, shadow.yOffset)))
            let radius = Float(max(0, min(8, shadow.radius)))
            sFloats.append(contentsOf: [xOff, yOff, radius, rgba.r, rgba.g, rgba.b, rgba.a, 0])
            sCount += 1
            let reach = radius * 1.45 + 1.0
            padX = max(padX, abs(xOff) + reach)
            padY = max(padY, abs(yOff) + reach)
        }
        self.shadowFloats = sFloats.isEmpty ? [0] : sFloats
        self.shadowCount = sCount
        self.shadowPadX = sCount > 0 ? min(12, ceil(padX)) : 0
        self.shadowPadY = sCount > 0 ? min(12, ceil(padY)) : 0
    }

    private static func packProcedural(
        layers: [SevenTvPaint.Layer],
        animMode: Float,
        animSpeed: Float
    ) -> (layerFloats: [Float], stopFloats: [Float], layerCount: Int) {
        var lFloats: [Float] = []
        var sFloats: [Float] = []
        var stopCursor = 0
        var count = 0

        for layer in layers.prefix(Self.maxLayers) {
            let sortedStops = Array(layer.stops.sorted { $0.at < $1.at }.prefix(Self.maxStopsPerLayer))
            let effectiveKind: Float
            switch layer.kind {
            case .linear where sortedStops.count >= 2:
                effectiveKind = 1
            case .radial where sortedStops.count >= 2:
                effectiveKind = layer.shape == .circle ? 2 : 3
            default:
                effectiveKind = 0
            }

            let baseRGBA: SevenTvRGBA
            if let c = layer.color {
                baseRGBA = SevenTvRGBA.unpack(c)
            } else if let first = sortedStops.first {
                baseRGBA = SevenTvRGBA.unpack(first.rgba)
            } else {
                baseRGBA = SevenTvRGBA(r: 1, g: 1, b: 1, a: 0)
            }

            let layerStopOffset = stopCursor
            let layerStopCount: Int
            if effectiveKind > 0.5 {
                for stop in sortedStops {
                    let c = SevenTvRGBA.unpack(stop.rgba)
                    let at = Float(max(0, min(1, stop.at)))
                    sFloats.append(contentsOf: [at, c.r, c.g, c.b, c.a])
                }
                layerStopCount = sortedStops.count
                stopCursor += sortedStops.count
            } else {
                layerStopCount = 0
            }

            let angleRad = Float(layer.angle * .pi / 180.0)
            let repeatsFlag: Float = layer.repeats ? 1 : 0
            let opacity = Float(max(0, min(1, layer.opacity)))
            // Drift applies to gradient layers; shimmer/iridescent apply across the final visible colour.
            let layerAnimMode: Float = (effectiveKind > 0.5 || animMode >= 1.5) ? animMode : 0

            lFloats.append(contentsOf: [
                effectiveKind,
                angleRad,
                repeatsFlag,
                opacity,
                Float(layerStopOffset),
                Float(layerStopCount),
                baseRGBA.r,
                baseRGBA.g,
                baseRGBA.b,
                baseRGBA.a,
                layerAnimMode,
                animSpeed,
            ])
            count += 1
        }

        return (
            layerFloats: lFloats.isEmpty ? [0] : lFloats,
            stopFloats: sFloats.isEmpty ? [0] : sFloats,
            layerCount: count
        )
    }

    private static func encodeAnimMode(_ mode: SevenTvPaint.Animation.Mode) -> Float {
        switch mode {
        case .none: return 0
        case .drift: return 1
        case .shimmer: return 2
        case .iridescent: return 3
        }
    }
}

// MARK: - curated real-style 7TV paint presets (for previews, tests & gallery)

extension SevenTvPaint {
    /// Representative real-world 7TV paint archetypes covering repeating 45° linear stripes, repeating radial rings,
    /// multi-stop metallic shimmer, multi-layer iridescence, crisp 10-shadow outlines, and animated URL image paints.
    public static let showcaseSamples: [SevenTvPaint] = [
        // 1. Candy Cane (repeating 45° hard-stop linear gradient + 4-way crisp outline shadows)
        SevenTvPaint(
            id: "showcase-candy-cane",
            name: "Candy Cane",
            kind: .linear,
            angle: 45,
            repeats: true,
            stops: [
                Stop(at: 0.10, rgba: 0xFF2E55FF),
                Stop(at: 0.20, rgba: 0xFF2E55FF),
                Stop(at: 0.20, rgba: 0xFFF5F7FF),
                Stop(at: 0.30, rgba: 0xFFF5F7FF),
            ],
            shadows: [
                Shadow(xOffset: -1, yOffset: 0, radius: 0.6, rgba: 0x000000A0),
                Shadow(xOffset: 1, yOffset: 0, radius: 0.6, rgba: 0x000000A0),
                Shadow(xOffset: 0, yOffset: -1, radius: 0.6, rgba: 0x000000A0),
                Shadow(xOffset: 0, yOffset: 1, radius: 0.6, rgba: 0x000000A0),
            ],
            animation: Animation(mode: .drift, speed: 0.20, intensity: 0.9)
        ),
        // 2. Bismuth Rainbow Repeat (repeating multi-stop prism + neon violet glow)
        SevenTvPaint(
            id: "showcase-bismuth",
            name: "Bismuth Prism",
            kind: .linear,
            angle: 105,
            repeats: true,
            stops: [
                Stop(at: 0.00, rgba: 0xFF4FD8FF),
                Stop(at: 0.16, rgba: 0xFFB84DFF),
                Stop(at: 0.33, rgba: 0x4DFFEAFF),
                Stop(at: 0.50, rgba: 0x7A5CFFFF),
                Stop(at: 0.66, rgba: 0xFF4FD8FF),
            ],
            shadows: [
                Shadow(xOffset: 0, yOffset: 0, radius: 1.2, rgba: 0x7A5CFFCC),
                Shadow(xOffset: 0, yOffset: 0, radius: 3.2, rgba: 0xFF4FD880),
            ],
            animation: Animation(mode: .drift, speed: 0.18, intensity: 0.9)
        ),
        // 3. Solar Flare (repeating radial ellipse with high-range stops + dual warm halo)
        SevenTvPaint(
            id: "showcase-solar-flare",
            name: "Solar Flare",
            kind: .radial,
            angle: 0,
            shape: .ellipse,
            repeats: true,
            stops: [
                Stop(at: 0.72, rgba: 0xFFD93BFF),
                Stop(at: 0.84, rgba: 0xFF7B1AFF),
                Stop(at: 0.88, rgba: 0xFF2A4BFF),
                Stop(at: 0.95, rgba: 0xFFD93BFF),
            ],
            shadows: [
                Shadow(xOffset: 0, yOffset: 0, radius: 1.0, rgba: 0xFF8C1ACC),
                Shadow(xOffset: 0, yOffset: 0, radius: 3.5, rgba: 0xFF330088),
            ],
            animation: Animation(mode: .drift, speed: 0.15, intensity: 0.85)
        ),
        // 4. Neon Cyber Shimmer (multi-stop linear gradient + specular sweep + crisp neon shadow)
        SevenTvPaint(
            id: "showcase-neon-shimmer",
            name: "Neon Shimmer",
            kind: .linear,
            angle: 90,
            repeats: false,
            stops: [
                Stop(at: 0.0, rgba: 0x00F5D4FF),
                Stop(at: 0.35, rgba: 0x38BDF8FF),
                Stop(at: 0.7, rgba: 0xA855F7FF),
                Stop(at: 1.0, rgba: 0xF43F5EFF),
            ],
            shadows: [
                Shadow(xOffset: 0, yOffset: 0, radius: 2.2, rgba: 0x38BDF8AA),
                Shadow(xOffset: 0, yOffset: 1, radius: 0.5, rgba: 0x000000CC),
            ],
            animation: Animation(mode: .shimmer, speed: 0.25, intensity: 0.45)
        ),
        // 5. Arctic Radial Circle (circular radial gradient + icy rim glow)
        SevenTvPaint(
            id: "showcase-arctic-circle",
            name: "Ice & Snow",
            kind: .radial,
            angle: 0,
            shape: .circle,
            repeats: false,
            stops: [
                Stop(at: 0.15, rgba: 0xFFFFFFFF),
                Stop(at: 0.45, rgba: 0xA5F3FCFF),
                Stop(at: 0.78, rgba: 0x38BDF8FF),
                Stop(at: 1.00, rgba: 0x1D4ED8FF),
            ],
            shadows: [
                Shadow(xOffset: -0.8, yOffset: 0, radius: 0.5, rgba: 0x0EA5E9AA),
                Shadow(xOffset: 0.8, yOffset: 0, radius: 0.5, rgba: 0x0EA5E9AA),
                Shadow(xOffset: 0, yOffset: -0.8, radius: 0.5, rgba: 0x0EA5E9AA),
                Shadow(xOffset: 0, yOffset: 0.8, radius: 0.5, rgba: 0x0EA5E9AA),
                Shadow(xOffset: 0, yOffset: 0, radius: 2.8, rgba: 0x38BDF877),
            ],
            animation: Animation(mode: .shimmer, speed: 0.20, intensity: 0.35)
        ),
        // 6. Multi-Layer Iridescent Opal (base linear + translucent radial highlight + iridescent sheen)
        SevenTvPaint(
            id: "showcase-opal-multilayer",
            name: "Opaline Multi-Layer",
            kind: .linear,
            angle: 120,
            repeats: false,
            stops: [],
            shadows: [
                Shadow(xOffset: 0, yOffset: 0, radius: 1.8, rgba: 0xE879F988),
                Shadow(xOffset: 0, yOffset: 0, radius: 3.6, rgba: 0x38BDF866),
            ],
            layers: [
                Layer(
                    kind: .linear,
                    angle: 110,
                    stops: [
                        Stop(at: 0.0, rgba: 0xC084FCFF),
                        Stop(at: 0.5, rgba: 0x67E8F9FF),
                        Stop(at: 1.0, rgba: 0xF9A8D4FF),
                    ],
                    opacity: 1.0
                ),
                Layer(
                    kind: .radial,
                    shape: .ellipse,
                    stops: [
                        Stop(at: 0.0, rgba: 0xFFFFFF99),
                        Stop(at: 0.65, rgba: 0xFFFFFF00),
                    ],
                    opacity: 0.7
                ),
            ],
            animation: Animation(mode: .iridescent, speed: 0.22, intensity: 0.75)
        ),
        // 7. Stacked Crisp Outlines (6-shadow arcade outline + inner glow)
        SevenTvPaint(
            id: "showcase-arcade-outline",
            name: "Hot Pursuit",
            kind: .linear,
            angle: 180,
            repeats: false,
            stops: [
                Stop(at: 0.0, rgba: 0xFEF08AFF),
                Stop(at: 0.45, rgba: 0xFB923CFF),
                Stop(at: 1.0, rgba: 0xEF4444FF),
            ],
            shadows: [
                Shadow(xOffset: -0.9, yOffset: 0, radius: 0, rgba: 0x18181BFF),
                Shadow(xOffset: 0.9, yOffset: 0, radius: 0, rgba: 0x18181BFF),
                Shadow(xOffset: 0, yOffset: -0.9, radius: 0, rgba: 0x18181BFF),
                Shadow(xOffset: 0, yOffset: 0.9, radius: 0, rgba: 0x18181BFF),
                Shadow(xOffset: 0, yOffset: 1.4, radius: 0.4, rgba: 0x7F1D1DFF),
                Shadow(xOffset: 0, yOffset: 0, radius: 3.0, rgba: 0xF97316AA),
            ],
            animation: Animation(mode: .shimmer, speed: 0.24, intensity: 0.35)
        ),
        // 8. Animated URL Image Paint (real 7TV CDN WebP paint + fallback + drop shadow)
        SevenTvPaint(
            id: "showcase-staff-shine",
            name: "Staff Shine",
            kind: .image,
            color: 0x38BDF8FF,
            imageURL: URL(string: "https://cdn.7tv.app/paint/01FQB6K5T0000BDD0YMN21KEXX/layer/01JAMR1DWJ14HBYADTC6Q634WR/1x.webp"),
            shadows: [
                Shadow(xOffset: 0, yOffset: 0, radius: 2.0, rgba: 0x38BDF8BB),
            ]
        ),
    ]
}
