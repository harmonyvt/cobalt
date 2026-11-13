#include <metal_stdlib>
using namespace metal;

// The sync glow: light concentrated along the bottom edge of the content, under the bars' glass,
// with a thin horizon line at the very edge. One pass, straight into the drawable.
//
// Uniform block. The order is SyncGlowUniforms.Index in SyncGlowKit: twenty floats, 80 bytes.
// 0 time, 1 state, 2 previous, 3 transition, 4 pending, 5 intensity, 6 reduced motion,
// 7 display headroom, 8 low power, 9 event age, 10 width (pixels), 11 height (pixels),
// 12 point scale (pixels per point), 13 dark, 14 activity (-1 none, 0...1, 2 no known length),
// 15 touch x (points, -1 none), 16 touch level, 17 scroll, 18 pad, 19 pad.
// State: 0 up to date, 1 syncing, 2 offline, 3 refused, 4 re-pull, 5 nudge, 6 off, 7 new posts.
struct GlowUniforms {
    float time;
    float state;
    float previous;
    float transition;
    float pending;
    float intensity;
    float reduced;
    float headroom;
    float lowPower;
    float eventAge;
    float width;
    float height;
    float pointScale;
    float dark;
    float activity;
    float touchX;
    float touchLevel;
    float scroll;
    float pad0;
    float pad1;
};

struct GlowVertex {
    float4 position [[position]];
};

// SyncGlowLook. Lengths in points.
constant float kPeakDark = 0.46;
constant float kPeakLight = 0.5;
constant float kFalloff = 2.0;
constant float kBarelessShare = 0.7;
constant float kFullBars = 40.0;
constant float kBandHeight = 56.0;
constant float kTotalCap = 0.6;
constant float kCoreBoost = 1.4;
constant float kHorizonY = 3.0;
constant float kHorizonWidth = 1.5;
constant float kDashPeriod = 15.0;
constant float kDashLength = 9.0;
constant float kLightSpeed = 80.0;
constant float kLightWidth = 90.0;

vertex GlowVertex glowVertex(uint id [[vertex_id]]) {
    float2 p = float2(float((id << 1) & 2), float(id & 2));
    GlowVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

float glowHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

/// `pow` on a negative base is NaN, which the compositor shows as black. Bases here are colours and falloff.
float safePow(float base, float exponent) {
    return pow(max(base, 0.0), exponent);
}

/// NaN and inf become 0, then the value stays in a finite non-negative range before the tone map.
float3 sanitize(float3 c) {
    c = select(c, float3(0.0), isnan(c));
    c = select(c, float3(0.0), isinf(c));
    return clamp(c, float3(0.0), float3(8.0));
}

float sanitize1(float a) {
    return (isnan(a) || isinf(a)) ? 0.0 : clamp(a, 0.0, 1.0);
}

float3 hexLinear(uint hex) {
    float3 srgb = float3(float((hex >> 16) & 0xff), float((hex >> 8) & 0xff), float(hex & 0xff)) / 255.0;
    return float3(safePow(srgb.r, 2.2), safePow(srgb.g, 2.2), safePow(srgb.b, 2.2));
}

// The palette, all from the app's design tokens (apple/Cobalt/Design/Tokens.swift, CobaltColor):
//   accent      linkBlue  light 0x196bd4, dark 0x2f8af9 (dark is also `focus`)
//   line dark   sharedInk 0x8ab8ff (the library's light link blue on dark), and the counted dashes
//   offline     caption   light 0x6e6e75, dark 0x8f8f8f
//   refused     errorText light 0xc4142a, dark 0xff5c6c
float3 accentColor(bool dark) { return dark ? hexLinear(0x2f8af9) : hexLinear(0x196bd4); }
float3 lineColor(bool dark) { return dark ? hexLinear(0x8ab8ff) : hexLinear(0x196bd4); }
float3 greyColor(bool dark) { return dark ? hexLinear(0x8f8f8f) : hexLinear(0x6e6e75); }
float3 redColor(bool dark) { return dark ? hexLinear(0xff5c6c) : hexLinear(0xc4142a); }

/// SyncGlowLook.amplitude.
float amplitude(float s) {
    if (s > 6.5) return 0.7;
    if (s > 5.5) return 0.0;
    if (s < 0.5) return 0.75;
    if (s < 1.5) return 0.6;
    if (s < 2.5) return 0.55;
    if (s < 3.5) return 0.9;
    if (s < 4.5) return 0.8;
    return 0.65;
}

/// SyncGlowLook.washCover: an even core at the bottom, the steepest fall just above the bars, and
/// flat to nothing at the band's top. `bars` is how many points of the band the bars cover; with
/// none, content runs down to the edge and the peak is lower (SyncGlowLook.edgePeak).
float washCover(float f, bool dark, float amp, float bars) {
    float peak = (dark ? kPeakDark : kPeakLight) * mix(kBarelessShare, 1.0, saturate(bars / kFullBars));
    float s = smoothstep(0.0, 1.0, saturate(f));
    return peak * saturate(amp) * safePow(1.0 - s, kFalloff);
}

/// SyncGlowLook.coreLift: dark mode light per unit of cover, hottest at the edge.
float coreLift(float f, float headroom) {
    float room = clamp(headroom, 1.0, 4.0);
    float core = safePow(1.0 - saturate(f), 3.0);
    return 1.0 + kCoreBoost * core * (1.0 + 0.5 * (room - 1.0));
}

/// The syncing light: a soft bright region drifting left to right along the edge, breathing slowly.
/// It leaves one side well clear before it comes in at the other, so the loop has no visible seam.
float syncLight(float x, float widthPt, float t, bool reduced) {
    float margin = kLightWidth * 2.2;
    float span = widthPt + margin * 2.0;
    float centre = reduced ? widthPt * 0.5 : fract(t * kLightSpeed / span) * span - margin;
    float g = (x - centre) / kLightWidth;
    float breath = reduced ? 1.0 : 0.8 + 0.2 * sin(t * 1.25);
    return exp(-g * g) * breath;
}

/// The nudge: one gentle pulse that travels the edge once, easing in and out of view.
float nudgeLight(float x, float widthPt, float age, bool reduced) {
    float p = reduced ? 0.5 : saturate(age / 1.6);
    float eased = p * p * (3.0 - 2.0 * p);
    float margin = kLightWidth * 1.5;
    float centre = mix(-margin, widthPt + margin, eased);
    float g = (x - centre) / (kLightWidth * 0.8);
    float envelope = reduced ? 0.7 : sin(3.14159265 * p);
    return exp(-g * g) * envelope;
}

/// New posts: two lights run in from the ends, meet in the middle and flare there once.
float arrivedLight(float x, float widthPt, float age, bool reduced) {
    float p = reduced ? 0.6 : saturate(age / 1.4);
    float run = saturate(p / 0.7);
    float eased = run * run * (3.0 - 2.0 * run);
    float margin = kLightWidth;
    float mid = widthPt * 0.5;
    float left = mix(-margin, mid, eased);
    float right = mix(widthPt + margin, mid, eased);
    float w = kLightWidth * 0.6;
    float gl = (x - left) / w;
    float gr = (x - right) / w;
    float lights = exp(-gl * gl) + exp(-gr * gr);
    // Where they meet: one wider flare that fades out.
    float meet = saturate((p - 0.6) / 0.15) * (1.0 - smoothstep(0.75, 1.0, p));
    float gm = (x - mid) / (kLightWidth * 1.4);
    float envelope = reduced ? 0.7 : 1.0 - smoothstep(0.85, 1.0, p);
    return min(lights * envelope + 1.3 * meet * exp(-gm * gm), 1.6);
}

/// One red flash, then back.
float refusedFlash(float age, bool reduced) {
    if (reduced) return 1.0;
    return smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.45, 1.1, age));
}

/// The re-pull: the line is wiped from the left, then drawn back in from the left. 1 is drawn.
float repullMask(float x01, float age, bool reduced) {
    float p = reduced ? 1.0 : clamp(age / 2.2, 0.0, 1.0);
    if (p < 0.5) {
        float edge = p / 0.5;
        return smoothstep(edge - 0.02, edge + 0.12, x01);
    }
    float edge = (p - 0.5) / 0.5;
    return 1.0 - smoothstep(edge - 0.12, edge + 0.02, x01);
}

/// SyncGlowDashes: whether `x` is on a dash (soft-edged), and in `bright` whether it is one of the
/// `n` counted dashes in the middle. The grid is lined up on that run.
float dashes(float x, float widthPt, float n, thread float &bright) {
    float s = (x - widthPt * 0.5) / kDashPeriod + n * 0.5;
    float phase = fract(s) * kDashPeriod;
    float gap = (kDashPeriod - kDashLength) * 0.5;
    float on = smoothstep(gap - 0.4, gap + 0.4, phase) * (1.0 - smoothstep(gap + kDashLength - 0.4, gap + kDashLength + 0.4, phase));
    bright = (s >= 0.0 && s < n) ? 1.0 : 0.0;
    return on;
}

/// A soft horizontal line `thickness` points thick, centred `kHorizonY` above the bottom edge.
float lineAt(float y, float thickness) {
    float d = (y - kHorizonY) / (thickness * 0.5);
    return exp(-d * d);
}

/// One state's glow at `p` (points, y up from the bottom edge). Premultiplied: rgb is light, a is cover.
float4 stateGlow(float st, float2 p, float widthPt, float band, constant GlowUniforms &u) {
    if (abs(st - 6.0) < 0.5) return float4(0.0);
    bool dark = u.dark > 0.5;
    bool reduced = u.reduced > 0.5;
    float t = reduced ? 1.7 : u.time;
    float gain = max(u.intensity, 0.0) * (u.lowPower > 0.5 ? 0.9 : 1.0);
    float f = saturate(p.y / max(band, 1.0));

    float3 tint = accentColor(dark);
    float3 ink = lineColor(dark);
    float amp = amplitude(st);
    // Dark mode: how much the core's light is scaled. Offline dims it; a travelling light brightens it.
    float lift = 1.0;
    float level = 0.55;
    float thickness = kHorizonWidth;

    if (abs(st - 1.0) < 0.5) {
        float l = syncLight(p.x, widthPt, t, reduced);
        amp += 0.55 * l;
        lift *= 1.0 + 2.0 * l;
        level = 0.4 + 1.5 * l;
    } else if (abs(st - 2.0) < 0.5) {
        tint = greyColor(dark);
        lift = 0.35;
        float bright = 0.0;
        float n = floor(clamp(u.pending, 0.0, 8.0) + 0.5);
        float on = dashes(p.x, widthPt, n, bright);
        // Grey dashes for the broken link; the waiting edits are brighter, thicker dashes in the middle.
        ink = mix(greyColor(dark), lineColor(dark), bright);
        level = on * mix(0.75, 1.6, bright);
        thickness = mix(kHorizonWidth, kHorizonWidth * 1.6, bright);
    } else if (abs(st - 3.0) < 0.5) {
        float flash = refusedFlash(u.eventAge, reduced);
        tint = mix(tint, redColor(dark), flash);
        ink = mix(ink, redColor(dark), flash);
        amp += 0.1 * flash;
        lift *= 1.0 + 0.6 * flash;
        level = 0.55 + 1.0 * flash;
    } else if (abs(st - 4.0) < 0.5) {
        float x01 = p.x / max(widthPt, 1.0);
        float m = repullMask(x01, u.eventAge, reduced);
        // A bright pen at the front of the wipe, rubbing the line out and then drawing it back in.
        float prog = reduced ? 1.0 : clamp(u.eventAge / 2.2, 0.0, 1.0);
        float edge = prog < 0.5 ? prog / 0.5 : (prog - 0.5) / 0.5;
        float g = (p.x - edge * widthPt) / 16.0;
        float pen = prog < 0.999 ? exp(-g * g) : 0.0;
        amp *= 0.7 + 0.3 * m;
        level = 0.6 * m + 1.8 * pen;
    } else if (abs(st - 5.0) < 0.5) {
        float l = nudgeLight(p.x, widthPt, u.eventAge, reduced);
        amp += 0.6 * l;
        lift *= 1.0 + 2.2 * l;
        level = 0.5 + 1.8 * l;
    } else if (abs(st - 7.0) < 0.5) {
        float l = arrivedLight(p.x, widthPt, u.eventAge, reduced);
        amp += 0.5 * l;
        lift *= 1.0 + 2.4 * l;
        level = 0.55 + 1.9 * l;
    }

    // On top of any state: the owner's own work, a finger or the pointer, and scrolling.
    if (u.activity >= 0.0) {
        float x01 = p.x / widthPt;
        if (u.activity <= 1.0) {
            // How far the saves have got: a brighter run from the left, with a hot head at its front.
            float fill = 1.0 - smoothstep(u.activity - 0.006, u.activity + 0.006, x01);
            float g = (p.x - u.activity * widthPt) / 14.0;
            float head = (u.activity > 0.001 && u.activity < 0.999) ? exp(-g * g) : 0.0;
            level += 0.5 * fill + 1.5 * head;
            lift *= 1.0 + 0.35 * fill + 1.2 * head;
        } else {
            // No known length: a short light loops along the line.
            float pos = reduced ? 0.5 : fract(t * 0.4);
            float g = (x01 - pos) * widthPt / 40.0;
            float head = exp(-g * g);
            level += 1.3 * head;
            lift *= 1.0 + 1.1 * head;
            amp += 0.12 * head;
        }
    }
    if (u.touchX >= 0.0 && u.touchLevel > 0.001) {
        float g = (p.x - u.touchX) / 70.0;
        float l = exp(-g * g) * u.touchLevel;
        amp += 0.45 * l;
        lift *= 1.0 + 2.0 * l;
        level += 1.5 * l;
    }
    if (u.scroll > 0.001) {
        amp += 0.18 * u.scroll;
        lift *= 1.0 + 0.7 * u.scroll;
        level += 0.55 * u.scroll;
    }

    // The band is SyncGlowLook.bandHeight points above the bars plus the bars themselves.
    float cover = washCover(f, dark, amp * gain, band - kBandHeight);
    float lineA = saturate(lineAt(p.y, thickness) * level * gain);
    // A little light hugs the line, so it reads as a lit edge and not a drawn rule.
    float halo = exp(-max(p.y, 0.0) / 7.0) * 0.25 * level * gain;
    float3 rgb;
    float a;
    if (dark) {
        rgb = tint * cover * coreLift(f, u.headroom) * lift + ink * (lineA * 1.3 + halo);
        a = cover + lineA * (1.0 - cover);
    } else {
        // Added light only whitens a white page, so light mode is ink: the core is a deeper,
        // more saturated tint and the line is drawn over it.
        float la = saturate(lineA + halo * 0.5);
        rgb = ink * la + tint * cover * (1.0 - la);
        a = la + cover * (1.0 - la);
    }
    return float4(rgb, min(a, kTotalCap));
}

/// 1.0 is SDR white. With headroom, light above it rolls off softly up to the display's peak.
float3 tonemap(float3 linear, float headroom) {
    float3 x = max(linear, float3(0.0));
    float peak = max(headroom, 1.0);
    // SDR: scale the whole colour down by its brightest channel. Clipping each channel on its own
    // would turn a bright blue green.
    if (peak <= 1.05) return x / max(1.0, max(x.r, max(x.g, x.b)));
    float room = peak - 1.0;
    float3 over = max(x - 1.0, float3(0.0));
    return min(x, float3(1.0)) + room * (1.0 - exp(-over / room));
}

fragment float4 glowFragment(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]]
) {
    float scale = max(u.pointScale, 1.0);
    float h = max(u.height, 1.0);
    float widthPt = max(u.width, 1.0) / scale;
    float band = h / scale;
    // Points, y measured up from the bottom edge.
    float2 p = float2(in.position.x / scale, (h - in.position.y) / scale);
    float fade = saturate(u.transition);
    // Once the crossfade is over the outgoing state has no weight, so it is not worked out at all.
    float4 c = stateGlow(u.state, p, widthPt, band, u);
    if (fade < 0.999) c = mix(stateGlow(u.previous, p, widthPt, band, u), c, fade);
    float a = sanitize1(c.a);
    float3 color = tonemap(sanitize(c.rgb), max(u.headroom, 1.0));
    float clock = u.reduced > 0.5 ? 0.0 : u.time;
    float dither = (glowHash(in.position.xy + clock * float2(17.0, 13.0)) - 0.5) / 255.0;
    color = max(color + dither * a, float3(0.0));
    return float4(color, a);
}
