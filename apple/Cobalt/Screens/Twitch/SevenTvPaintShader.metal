#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace {

constant constexpr int kLayerStride = 12;
constant constexpr int kStopStride = 5;
constant constexpr int kShadowStride = 8;
constant constexpr int kMaxLayers = 8;
constant constexpr int kMaxStops = 32;
constant constexpr int kMaxShadows = 10;
constant constexpr float kTwoPi = 6.28318530718;

inline float readStopAt(device const float *stopData, int idx) {
    return stopData[idx * kStopStride];
}

inline float4 readStopColor(device const float *stopData, int idx) {
    int base = idx * kStopStride;
    return float4(
        stopData[base + 1],
        stopData[base + 2],
        stopData[base + 3],
        stopData[base + 4]
    );
}

/// Evaluates sorted CSS gradient stops in premultiplied sRGB (matching CSS Images Level 4),
/// preserving hard color stops when two consecutive stops share the same `at` position.
inline float4 sampleGradientStops(
    float t,
    device const float *stopData,
    int stopFloatCount,
    int stopOffset,
    int stopCount,
    float4 fallback
) {
    int maxAvailable = stopFloatCount / kStopStride;
    if (stopCount <= 0 || stopOffset < 0 || stopOffset >= maxAvailable) {
        return fallback;
    }
    int count = min(min(stopCount, kMaxStops), maxAvailable - stopOffset);
    if (count == 1) {
        return readStopColor(stopData, stopOffset);
    }

    float firstAt = readStopAt(stopData, stopOffset);
    if (t <= firstAt) {
        return readStopColor(stopData, stopOffset);
    }

    int lastIdx = stopOffset + count - 1;
    float lastAt = readStopAt(stopData, lastIdx);
    if (t >= lastAt) {
        return readStopColor(stopData, lastIdx);
    }

    for (int i = 0; i < count - 1; ++i) {
        int idx0 = stopOffset + i;
        int idx1 = idx0 + 1;
        float a0 = readStopAt(stopData, idx0);
        float a1 = readStopAt(stopData, idx1);
        if (t >= a0 && t <= a1) {
            float span = a1 - a0;
            if (span <= 1e-5) {
                continue;
            }
            float f = clamp((t - a0) / span, 0.0, 1.0);
            float4 c0 = readStopColor(stopData, idx0);
            float4 c1 = readStopColor(stopData, idx1);
            // Premultiplied sRGB interpolation prevents dark muddy fringes when blending toward transparent.
            float4 p0 = float4(c0.rgb * c0.a, c0.a);
            float4 p1 = float4(c1.rgb * c1.a, c1.a);
            float4 pm = mix(p0, p1, f);
            float3 rgb = pm.a > 1e-5 ? (pm.rgb / pm.a) : float3(0.0);
            return float4(rgb, pm.a);
        }
    }

    return readStopColor(stopData, lastIdx);
}

/// Luminance-preserving Rodrigues hue rotation around `(1, 1, 1) / sqrt(3)`.
inline float3 rotateHue(float3 rgb, float angle) {
    constexpr float3 k = float3(0.57735027, 0.57735027, 0.57735027);
    float cosA = cos(angle);
    float sinA = sin(angle);
    float3 rotated = rgb * cosA + cross(k, rgb) * sinA + k * dot(k, rgb) * (1.0 - cosA);
    return clamp(rotated, 0.0, 1.0);
}

/// Applies subtle metallic shimmer (`mode == 2`) or iridescent prism sheen (`mode == 3`).
inline float3 applySheenEffect(
    float3 rgb,
    float2 position,
    float2 size,
    float time,
    float animMode,
    float animSpeed,
    float animIntensity
) {
    if (time <= 0.0 || animIntensity <= 0.001 || animSpeed <= 0.0001) {
        return rgb;
    }

    float u = position.x / max(size.x, 1.0);
    float v = position.y / max(size.y, 1.0);

    if (animMode > 1.5 && animMode < 2.5) {
        // Mode 2: diagonal specular sheen with calm rest phase between sweeps.
        float diag = u * 0.86 + v * 0.14;
        float cycle = fract(time * animSpeed);
        float sweep = cycle * 2.6 - 0.55;
        float d = diag - sweep;
        float primary = exp(-d * d * 55.0);
        float glint = exp(-(d + 0.08) * (d + 0.08) * 180.0) * 0.45;
        float sheen = clamp((primary + glint) * animIntensity, 0.0, 0.85);
        float3 lift = min(rgb * 1.32 + float3(0.36), float3(1.0));
        return mix(rgb, lift, sheen);
    }

    if (animMode >= 2.5) {
        // Mode 3: smooth diagonal iridescent hue wave + soft crest highlight.
        float wave = sin((u * 1.8 + v * 0.45 - time * animSpeed * 2.0) * 3.14159265);
        float3 shifted = rotateHue(rgb, wave * 0.72 * animIntensity);
        float crest = pow(max(0.0, 0.5 + 0.5 * wave), 4.0) * 0.22 * animIntensity;
        return clamp(shifted + float3(crest), 0.0, 1.0);
    }

    return rgb;
}

/// Samples a blurred glyph alpha mask around `center` for CSS `filter: drop-shadow(...)`.
inline float sampleShadowAlpha(SwiftUI::Layer layer, float2 center, float radius) {
    if (radius <= 0.15) {
        return float(layer.sample(center).a);
    }

    // Center tap
    float sigma = max(0.45, radius * 0.52);
    float invTwoSigmaSq = 1.0 / (2.0 * sigma * sigma);
    float sum = float(layer.sample(center).a);
    float weightSum = 1.0;

    if (radius <= 2.2) {
        // 1-ring 9-tap Gaussian disc (1 center + 8 perimeter)
        float r1 = radius * 0.85;
        float w1 = exp(-(r1 * r1) * invTwoSigmaSq);

        for (int i = 0; i < 8; ++i) {
            float a1 = (float(i) / 8.0) * kTwoPi;
            float2 d1 = float2(cos(a1), sin(a1)) * r1;
            sum += float(layer.sample(center + d1).a) * w1;
            weightSum += w1;
        }
    } else {
        // 2-ring 13-tap Gaussian disc (1 center + 4 inner + 8 staggered outer)
        float r1 = radius * 0.50;
        float r2 = radius * 1.10;
        float w1 = exp(-(r1 * r1) * invTwoSigmaSq);
        float w2 = exp(-(r2 * r2) * invTwoSigmaSq);

        for (int i = 0; i < 4; ++i) {
            float a1 = (float(i) / 4.0) * kTwoPi;
            float2 d1 = float2(cos(a1), sin(a1)) * r1;
            sum += float(layer.sample(center + d1).a) * w1;
            weightSum += w1;
        }
        for (int i = 0; i < 8; ++i) {
            float a2 = ((float(i) + 0.5) / 8.0) * kTwoPi;
            float2 d2 = float2(cos(a2), sin(a2)) * r2;
            sum += float(layer.sample(center + d2).a) * w2;
            weightSum += w2;
        }
    }

    return clamp(sum / weightSum, 0.0, 1.0);
}

} // namespace

/// Single-pass GPU shader for 7TV procedural name paints:
/// - Exact CSS `linear-gradient` & `repeating-linear-gradient` (true pixel-aspect angle length `|W sin a| + |H cos a|`)
/// - Exact CSS `radial-gradient` & `repeating-radial-gradient` (`circle` and `ellipse` `farthest-corner`)
/// - Arbitrary sorted stops (up to 32 per layer) with hard-stop and premultiplied sRGB support
/// - Multi-layer bottom-to-top compositing (up to 8 layers) with per-layer opacity and `fallbackColor` underlay
/// - Smooth GPU animation (`drift`, `shimmer`, `iridescent`) gated externally by `time`
/// - Crisp anti-aliased glyph masking via `currentColor.a`
[[ stitchable ]] half4 sevenTvPaintFill(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float4 fallbackColor,
    float animIntensity,
    device const float *layerParams,
    int layerFloatCount,
    device const float *stopData,
    int stopFloatCount
) {
    half glyphAlpha = currentColor.a;
    if (glyphAlpha <= 0.001h) {
        return half4(0.0h);
    }

    int layerCount = min(layerFloatCount / kLayerStride, kMaxLayers);
    float w = max(size.x, 1.0);
    float h = max(size.y, 1.0);
    float2 halfSize = float2(w * 0.5, h * 0.5);
    float2 rel = position - halfSize;

    // Premultiplied underlay (`background-color` in CSS); transparent when stacking over an image layer.
    float4 accum = float4(fallbackColor.rgb * fallbackColor.a, fallbackColor.a);
    float topSheenMode = 0.0;
    float topSheenSpeed = 0.0;

    for (int l = 0; l < layerCount; ++l) {
        int base = l * kLayerStride;
        float kind = layerParams[base + 0];
        float angleRad = layerParams[base + 1];
        float repeats = layerParams[base + 2];
        float layerOpacity = clamp(layerParams[base + 3], 0.0, 1.0);
        int stopOffset = int(layerParams[base + 4] + 0.5);
        int stopCount = int(layerParams[base + 5] + 0.5);
        float4 baseColor = float4(
            layerParams[base + 6],
            layerParams[base + 7],
            layerParams[base + 8],
            layerParams[base + 9]
        );
        float animMode = layerParams[base + 10];
        float animSpeed = layerParams[base + 11];

        if (animMode >= 1.5) {
            topSheenMode = animMode;
            topSheenSpeed = animSpeed;
        }

        float4 col = baseColor;

        if (kind > 0.5 && stopCount >= 2) {
            float t = 0.0;
            if (kind < 1.5) {
                // Linear gradient: CSS 0deg = up (0, -1), 90deg = right (1, 0).
                float s = sin(angleRad);
                float c = cos(angleRad);
                float2 dir = float2(s, -c);
                float gradLen = max(abs(w * s) + abs(h * c), 1.0);
                t = dot(rel, dir) / gradLen + 0.5;
            } else if (kind < 2.5) {
                // Radial circle (`farthest-corner` at center)
                float radius = max(length(halfSize), 1.0);
                t = length(rel) / radius;
            } else {
                // Radial ellipse (`farthest-corner` at center)
                float rx = max(halfSize.x * 1.41421356, 1.0);
                float ry = max(halfSize.y * 1.41421356, 1.0);
                t = length(float2(rel.x / rx, rel.y / ry));
            }

            int maxAvailable = stopFloatCount / kStopStride;
            int clampedCount = min(min(stopCount, kMaxStops), max(0, maxAvailable - stopOffset));
            if (clampedCount >= 2) {
                float firstAt = readStopAt(stopData, stopOffset);
                float lastAt = readStopAt(stopData, stopOffset + clampedCount - 1);
                float period = lastAt - firstAt;

                if (repeats > 0.5 && period > 1e-4) {
                    if (animMode > 0.5 && animMode < 1.5 && time > 0.0 && animSpeed > 0.0 && animIntensity > 0.001) {
                        float driftSpan = max(period, 0.25);
                        t -= time * animSpeed * driftSpan * animIntensity;
                    }
                    float u = t - firstAt;
                    t = firstAt + (u - period * floor(u / period));
                } else if (animMode > 0.5 && animMode < 1.5 && time > 0.0 && animSpeed > 0.0 && animIntensity > 0.001) {
                    // Explicit drift on non-repeating gradient: smooth ping-pong wave.
                    float shift = sin(time * animSpeed * kTwoPi) * 0.12 * animIntensity;
                    t = clamp(t + shift, firstAt, lastAt);
                }

                col = sampleGradientStops(t, stopData, stopFloatCount, stopOffset, clampedCount, baseColor);
            }
        }

        // Premultiplied Porter-Duff source-over composite onto `accum`.
        float srcA = clamp(col.a * layerOpacity, 0.0, 1.0);
        float3 srcPremul = col.rgb * srcA;
        accum = float4(srcPremul + accum.rgb * (1.0 - srcA), srcA + accum.a * (1.0 - srcA));
    }

    float outAlpha = accum.a;
    if (outAlpha <= 1e-4) {
        return half4(0.0h);
    }

    float3 straightRGB = clamp(accum.rgb / outAlpha, 0.0, 1.0);
    if (topSheenMode >= 1.5) {
        straightRGB = applySheenEffect(straightRGB, position, size, time, topSheenMode, topSheenSpeed, animIntensity);
    }

    // Keep text readable when composited with an opaque fallback, while respecting translucent overlay layers.
    float finalAlpha = fallbackColor.a > 0.001 ? max(0.35, clamp(outAlpha, 0.0, 1.0)) : clamp(outAlpha, 0.0, 1.0);
    half maskedA = half(finalAlpha) * glyphAlpha;
    return half4(half3(straightRGB) * maskedA, maskedA);
}

/// Lightweight GPU sheen / opacity pass for masked URL image paints (`EmotePicture` textures).
[[ stitchable ]] half4 sevenTvImagePaintOverlay(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float animMode,
    float animSpeed,
    float animIntensity,
    float opacity
) {
    half a = currentColor.a;
    if (a <= 0.001h) {
        return half4(0.0h);
    }
    float3 straight = clamp(float3(currentColor.rgb) / float(a), 0.0, 1.0);
    if (animMode >= 1.5) {
        straight = applySheenEffect(straight, position, size, time, animMode, animSpeed, animIntensity);
    }
    half outA = a * half(clamp(opacity, 0.0, 1.0));
    return half4(half3(straight) * outA, outA);
}

/// Single-pass GPU `layerEffect` rendering up to 10 crisp or softly glowing 7TV drop shadows in CSS back-to-front order
/// with the painted foreground text composited cleanly on top.
[[ stitchable ]] half4 sevenTvDropShadows(
    float2 position,
    SwiftUI::Layer layer,
    device const float *shadowData,
    int shadowFloatCount
) {
    half4 fg = layer.sample(position);
    int shadowCount = min(shadowFloatCount / kShadowStride, min(kMaxShadows, 3));
    if (shadowCount <= 0) {
        return fg;
    }

    half4 accum = half4(0.0h);
    for (int i = shadowCount - 1; i >= 0; --i) {
        int base = i * kShadowStride;
        float2 offset = float2(shadowData[base + 0], shadowData[base + 1]);
        float radius = max(0.0, shadowData[base + 2]);
        float4 col = float4(
            shadowData[base + 3],
            shadowData[base + 4],
            shadowData[base + 5],
            shadowData[base + 6]
        );
        if (col.a <= 0.001) {
            continue;
        }

        float glyphCov = sampleShadowAlpha(layer, position - offset, radius);
        if (glyphCov <= 0.001) {
            continue;
        }

        half sa = half(clamp(glyphCov * col.a, 0.0, 1.0));
        half4 src = half4(half3(col.rgb) * sa, sa);
        accum = src + accum * (1.0h - sa);
    }

    return fg + accum * (1.0h - fg.a);
}
