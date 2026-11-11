#include <metal_stdlib>
using namespace metal;

// The sync glow: a band that rises from the bottom of the content, under the bars' glass.
//
// Uniform block. The order is SyncGlowUniforms.Index in SyncGlowKit: twenty floats, 80 bytes.
// 0 time, 1 state, 2 previous, 3 transition, 4 pending, 5 intensity, 6 density,
// 7 reduced motion, 8 display headroom, 9 low power, 10 event age, 11 width, 12 height,
// 13 atlas columns (12), 14 glyphs enabled, 15 point scale (pixels per point), 16 dark,
// 17 bar inset (points), 18 pad, 19 pad.
// State: 0 up to date, 1 syncing, 2 offline, 3 refused, 4 re-pull, 5 nudge, 6 off.
struct GlowUniforms {
    float time;
    float state;
    float previous;
    float transition;
    float pending;
    float intensity;
    float density;
    float reduced;
    float headroom;
    float lowPower;
    float eventAge;
    float width;
    float height;
    float atlasColumns;
    float glyphsEnabled;
    float pointScale;
    float dark;
    float barInset;
    float pad0;
    float pad1;
};

struct GlowVertex {
    float4 position [[position]];
};

// Glyph row, matching GlyphAtlasLayout.glyphs: . * + o ' `  - / \ | _ :
constant float kGlyphDot = 0.0;
constant float kGlyphStar = 1.0;
constant float kGlyphPlus = 2.0;
constant float kGlyphTick = 4.0;

// SyncGlowLook, in points.
constant float kPeakDark = 0.38;
constant float kPeakLight = 0.3;
constant float kStarCap = 0.55;
constant float kTotalCap = 0.60;
constant float kStarCeiling = 0.6;
constant float kHorizonY = 3.0;
constant float kHorizonWidth = 1.5;
constant float kWaitingY = 12.0;
constant float kWaitingSpacing = 18.0;
constant float kNudgeHeight = 16.0;
constant float kNudgeTail = 120.0;

// SyncGlowField.far and .near: cell width, cell height, glyph box, probability; then brightness.
constant float4 kFarCell = float4(20.0, 15.0, 11.0, 0.38);
constant float kFarBright = 0.45;
constant float4 kNearCell = float4(34.0, 24.0, 15.5, 0.34);
constant float kNearBright = 1.0;

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

/// NaN and inf become 0, then the value stays in a finite non-negative range before bloom and tone map.
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
//   star dark   sharedInk 0x8ab8ff (the library's light link blue on dark)
//   star light  linkBlue light 0x196bd4 (deeper and more saturated, so stars show on white)
//   offline     caption   light 0x6e6e75, dark 0x8f8f8f
//   refused     errorText light 0xc4142a, dark 0xff5c6c
float3 accentColor(bool dark) { return dark ? hexLinear(0x2f8af9) : hexLinear(0x196bd4); }
float3 starColor(bool dark) { return dark ? hexLinear(0x8ab8ff) : hexLinear(0x196bd4); }
float3 greyColor(bool dark) { return dark ? hexLinear(0x8f8f8f) : hexLinear(0x6e6e75); }
float3 redColor(bool dark) { return dark ? hexLinear(0xff5c6c) : hexLinear(0xc4142a); }

/// The wash's colour per state. Refused keeps the accent: only its horizon flashes red.
float3 washColor(float s, bool dark) {
    if (abs(s - 2.0) < 0.5) return greyColor(dark);
    return accentColor(dark);
}

/// SyncGlowLook.amplitude.
float amplitude(float s) {
    if (s > 5.5) return 0.0;
    if (s < 0.5) return 0.62;
    if (s < 1.5) return 1.0;
    if (s < 2.5) return 0.7;
    if (s < 3.5) return 0.9;
    if (s < 4.5) return 0.85;
    return 0.8;
}

/// SyncGlowLook.washCover: strongest at the bottom edge, flat to nothing at the band's top.
float washCover(float f, bool dark, float amp) {
    float peak = dark ? kPeakDark : kPeakLight;
    return peak * saturate(amp) * safePow(1.0 - saturate(f), 1.7);
}

/// SyncGlowField.starFade: 1 low down, 0 at the star ceiling, none tucked under the horizon.
float starFade(float yb, float band) {
    float ceiling = max(band, 1.0) * kStarCeiling;
    float s = smoothstep(ceiling * 0.5, ceiling, yb);
    return yb < 6.0 ? 0.0 : 1.0 - s;
}

/// Distance from a point to a segment, in points.
float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 0.0001));
    return length(p - (a + ab * t));
}

/// One glyph from the atlas, centred on `pos`, in a `box`-point square. `p` and `pos` are in points with y up.
float glyphMask(float2 p, float2 pos, float gid, float box, bool glyphs, texture2d<float> atlas, sampler smp) {
    if (!glyphs) {
        // No atlas: a small soft dot stands in for every star.
        float r = box * 0.09;
        return 1.0 - smoothstep(r * 0.4, r, length(p - pos));
    }
    float2 local = float2((p.x - pos.x) / box + 0.5, 0.5 - (p.y - pos.y) / box);
    if (local.x < 0.0 || local.y < 0.0 || local.x > 1.0 || local.y > 1.0) return 0.0;
    float2 auv = float2((local.x + gid) / 12.0, local.y);
    return atlas.sample(smp, auv).r;
}

/// The syncing pulse's place along the horizon, in points.
float pulseX(float t, float widthPt) {
    return mix(-0.15, 1.15, fract(t * 0.22)) * widthPt;
}

/// The re-pull sweep: dissolve from the left, then draw back in from the left. 1 is drawn.
float repullMask(float x01, float age, float reduced) {
    float p = reduced > 0.5 ? 1.0 : clamp(age / 2.2, 0.0, 1.0);
    if (p < 0.5) {
        float edge = p / 0.5;
        return smoothstep(edge - 0.02, edge + 0.12, x01);
    }
    float edge = (p - 0.5) / 0.5;
    return 1.0 - smoothstep(edge - 0.12, edge + 0.02, x01);
}

/// How far a refusal has broken the figure: rises, then settles back.
float shatterAmount(float age, float reduced) {
    if (reduced > 0.5) return 0.0;
    return smoothstep(0.0, 0.35, age) * (1.0 - smoothstep(0.35, 1.15, age));
}

struct StarInfo {
    float2 pos;
    float exist;
    float glyph;
    float bright;
};

StarInfo starAt(float2 cell, float4 layer, float salt, float st, float widthPt, float band, constant GlowUniforms &u, float t) {
    StarInfo s;
    float h = glowHash(cell + salt);
    float h2 = glowHash(cell + salt + 91.0);
    float h3 = glowHash(cell + salt + 33.0);
    float prob = layer.w * (0.6 + 0.4 * saturate(u.density));
    s.exist = step(h, prob);
    float2 jitter = (float2(h2, h3) - 0.5) * 0.7;
    float shatter = abs(st - 3.0) < 0.5 ? shatterAmount(u.eventAge, u.reduced) : 0.0;
    jitter += (float2(glowHash(cell + 3.1), glowHash(cell + 8.7)) - 0.5) * shatter * 1.4;
    s.pos = (cell + 0.5 + jitter) * layer.xy;
    s.bright = 1.0;
    if (u.reduced < 0.5) s.bright = 0.72 + 0.28 * sin(t * (0.6 + h2 * 0.9) + h * 6.283);
    s.bright *= mix(1.0, 0.55, shatter);
    // Syncing: stars lift and brighten as the horizon's pulse passes under them.
    if (abs(st - 1.0) < 0.5 && u.reduced < 0.5) {
        float d = (s.pos.x - pulseX(t, widthPt)) / 46.0;
        float g = exp(-d * d);
        s.pos.y += 6.0 * g;
        s.bright *= 1.0 + 1.4 * g;
    }
    // Offline: the sky dims; the waiting row says the rest.
    if (abs(st - 2.0) < 0.5) s.bright *= 0.45;
    if (abs(st - 4.0) < 0.5) s.exist *= repullMask(s.pos.x / max(widthPt, 1.0), u.eventAge, u.reduced);
    s.exist *= starFade(s.pos.y, band);
    s.glyph = h2;
    return s;
}

/// One layer of stars, premultiplied: rgb is light, a is cover.
float4 starLayer(float2 p, float4 layer, float layerBright, float salt, bool near, float st, float widthPt, float band,
                 constant GlowUniforms &u, float t, texture2d<float> atlas, sampler smp) {
    bool dark = u.dark > 0.5;
    bool glyphs = u.glyphsEnabled > 0.5;
    float3 colour = abs(st - 2.0) < 0.5 ? greyColor(dark) : starColor(dark);
    float2 cell0 = floor(p / layer.xy);
    float cover = 0.0;
    float links = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = cell0 + float2(float(i), float(j));
            StarInfo s = starAt(cell, layer, salt, st, widthPt, band, u, t);
            if (s.exist > 0.001) {
                float gid;
                if (near) gid = s.glyph < 0.4 ? kGlyphStar : (s.glyph < 0.75 ? kGlyphPlus : kGlyphDot);
                else gid = s.glyph < 0.6 ? kGlyphDot : kGlyphTick;
                float m = glyphMask(p, s.pos, gid, layer.z, glyphs, atlas, smp);
                // Light mode inks stars a little more, so they read as deep blue rather than faded.
                cover = max(cover, m * s.exist * s.bright * layerBright * (dark ? 1.0 : 1.35));
            }
            // The constellation: now and then a near star is joined to its right-hand neighbour by a
            // hairline. A thin line, not a run of characters, so it never reads as text.
            if (near && glowHash(cell + 21.0) > 0.55 && abs(st - 2.0) > 0.5) {
                StarInfo r = starAt(cell + float2(1.0, 0.0), layer, salt, st, widthPt, band, u, t);
                float both = min(s.exist, r.exist);
                if (both > 0.001) {
                    float d = segmentDistance(p, s.pos, r.pos);
                    // Stops short of each star so the line does not run through the glyph.
                    float ends = smoothstep(4.0, 7.0, length(p - s.pos)) * smoothstep(4.0, 7.0, length(p - r.pos));
                    float keep = abs(st - 3.0) < 0.5 ? 1.0 - shatterAmount(u.eventAge, u.reduced) : 1.0;
                    links = max(links, (1.0 - smoothstep(0.25, 0.75, d)) * ends * both * keep * 0.22);
                }
            }
        }
    }
    float a = min(max(cover, links), kStarCap);
    return float4(colour * a, a);
}

/// The horizon and what rides on it, premultiplied.
float4 horizon(float2 p, float st, float widthPt, constant GlowUniforms &u, float t, texture2d<float> atlas, sampler smp) {
    bool dark = u.dark > 0.5;
    float d = (p.y - kHorizonY) / (kHorizonWidth * 0.5);
    float line = exp(-d * d);
    float halo = exp(-max(p.y, 0.0) / 9.0) * 0.28;
    float3 colour = accentColor(dark);
    // Up to date is the faint, steady baseline the other states brighten or break.
    float level = 0.4;
    float3 out = float3(0.0);
    float a = 0.0;
    if (abs(st - 1.0) < 0.5) {
        float px = u.reduced > 0.5 ? widthPt * 0.5 : pulseX(t, widthPt);
        float g = (p.x - px) / 55.0;
        float pulse = exp(-g * g);
        // A dim line with one bright, whiter bead of light running along it.
        level = 0.3 + 1.7 * pulse;
        halo *= 0.6 + 3.0 * pulse;
        colour = mix(colour, starColor(dark), pulse * 0.6);
    } else if (abs(st - 2.0) < 0.5) {
        colour = greyColor(dark);
        // Broken into dashes: 9 pt on, 6 pt off.
        float phase = fract(p.x / 15.0) * 15.0;
        float dash = smoothstep(0.0, 0.8, phase) * (1.0 - smoothstep(8.2, 9.0, phase));
        level = 0.85 * dash;
        halo *= 0.4;
        // The waiting edits: a row of stars just above the line, blinking slowly.
        float n = floor(clamp(u.pending, 0.0, 8.0) + 0.5);
        float best = 0.0;
        for (int k = 0; k < 8; k++) {
            if (float(k) >= n) break;
            float x = widthPt * 0.5 + (float(k) - (n - 1.0) * 0.5) * kWaitingSpacing;
            float blink = u.reduced > 0.5 ? 1.0 : mix(0.45, 1.0, 0.5 + 0.5 * sin(t * 1.6 + float(k) * 1.3));
            float m = glyphMask(p, float2(x, kWaitingY), kGlyphStar, 15.5, u.glyphsEnabled > 0.5, atlas, smp);
            best = max(best, m * blink);
        }
        float sa = min(best, 0.85);
        out += starColor(dark) * sa * (dark ? 1.4 : 1.0);
        a = max(a, sa);
    } else if (abs(st - 3.0) < 0.5) {
        // One red flash, then back to the accent.
        float flash = u.reduced > 0.5 ? 1.0 : smoothstep(0.0, 0.08, u.eventAge) * (1.0 - smoothstep(0.45, 1.1, u.eventAge));
        colour = mix(colour, redColor(dark), flash);
        level = 0.4 + 1.1 * flash;
        halo *= 1.0 + 2.0 * flash;
    } else if (abs(st - 4.0) < 0.5) {
        float m = repullMask(p.x / max(widthPt, 1.0), u.eventAge, u.reduced);
        // A bright pen at the front of the sweep, rubbing out and then drawing the line back in.
        float prog = u.reduced > 0.5 ? 1.0 : clamp(u.eventAge / 2.2, 0.0, 1.0);
        float edge = prog < 0.5 ? prog / 0.5 : (prog - 0.5) / 0.5;
        float g = (p.x - edge * widthPt) / 16.0;
        float pen = prog < 0.999 ? exp(-g * g) : 0.0;
        level = 0.5 * m + 1.8 * pen;
        halo *= m + 3.0 * pen;
        colour = mix(colour, starColor(dark), pen * 0.6);
    } else if (abs(st - 5.0) < 0.5) {
        // The shooting star: low, just above the bars, with a long tapering tail.
        float travel = u.reduced > 0.5 ? 0.55 : clamp(u.eventAge / 1.6, 0.0, 1.0);
        float y0 = u.barInset + kNudgeHeight;
        float2 head = float2(mix(-0.05, 1.1, travel) * widthPt, y0 + 10.0 * (1.0 - travel));
        float2 dir = normalize(float2(1.0, -0.09));
        float2 tailEnd = head - dir * kNudgeTail;
        float2 ab = head - tailEnd;
        float along = saturate(dot(p - tailEnd, ab) / dot(ab, ab));
        float dist = segmentDistance(p, tailEnd, head);
        float width = mix(0.3, 1.4, along);
        float tail = (1.0 - smoothstep(width * 0.5, width + 0.6, dist)) * along * along;
        float glow = exp(-length(p - head) / 4.0) * 0.7;
        float m = glyphMask(p, head, kGlyphStar, 17.0, u.glyphsEnabled > 0.5, atlas, smp);
        // It may cross a label for a moment, so even its head stays below full cover.
        float sa = min(max(max(tail * 0.85, m), glow), 0.75);
        out += starColor(dark) * sa * (dark ? 1.3 : 1.0);
        a = max(a, sa);
    }
    float la = saturate(line * level + halo * level * 0.6);
    out += colour * la * (dark ? 1.3 : 1.0);
    // Dark: the halo is light added around the line. Light: added light only whitens a white page,
    // so the halo is ink like the line, and the pulse or pen shows as a deeper blue bead.
    a = max(a, dark ? saturate(line * level) : min(la, 0.85));
    return float4(out, a);
}

/// Everything that emits light and gets bloom: both star layers and the horizon. Premultiplied.
float4 field(float st, float2 p, float widthPt, float band, constant GlowUniforms &u, texture2d<float> atlas, sampler smp) {
    if (st > 5.5) return float4(0.0);
    float t = u.reduced > 0.5 ? 1.7 : u.time;
    float4 far = starLayer(p, kFarCell, kFarBright, 0.0, false, st, widthPt, band, u, t * 0.5, atlas, smp);
    float4 near = starLayer(p, kNearCell, kNearBright, 57.0, true, st, widthPt, band, u, t, atlas, smp);
    float4 sky = near + far * (1.0 - near.a);
    float4 line = horizon(p, st, widthPt, u, t, atlas, smp);
    return line + sky * (1.0 - line.a);
}

/// Pixel to points, y measured up from the bottom edge.
float2 pointsOf(float2 pixel, constant GlowUniforms &u) {
    float scale = max(u.pointScale, 1.0);
    float h = max(u.height, 1.0);
    return float2(pixel.x / scale, (h - pixel.y) / scale);
}

fragment float4 glowStars(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float scale = max(u.pointScale, 1.0);
    float widthPt = max(u.width, 1.0) / scale;
    float band = max(u.height, 1.0) / scale;
    float2 p = pointsOf(in.position.xy, u);
    float fade = saturate(u.transition);
    // Once the crossfade is over the outgoing field has no weight, so it is not worked out at all.
    float4 c = field(u.state, p, widthPt, band, u, atlas, smp);
    if (fade < 0.999) c = mix(field(u.previous, p, widthPt, band, u, atlas, smp), c, fade);
    return float4(sanitize(c.rgb), sanitize1(c.a));
}

float4 blur9(texture2d<float> src, sampler smp, float2 uv, float2 texel) {
    float4 c = src.sample(smp, uv) * 0.227027;
    c += src.sample(smp, uv + texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv - texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv + texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv - texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv + texel * 3.0) * 0.054054;
    c += src.sample(smp, uv - texel * 3.0) * 0.054054;
    c += src.sample(smp, uv + texel * 4.0) * 0.016216;
    c += src.sample(smp, uv - texel * 4.0) * 0.016216;
    return float4(sanitize(c.rgb), sanitize1(c.a));
}

fragment float4 glowBlurH(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> src [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    return blur9(src, smp, in.position.xy / size, float2(1.6 / size.x, 0.0));
}

fragment float4 glowBlurV(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> src [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    return blur9(src, smp, in.position.xy / size, float2(0.0, 1.6 / size.y));
}

/// 1.0 is SDR white. With headroom, light above it rolls off softly up to the display's peak.
float3 tonemap(float3 linear, float headroom) {
    float3 x = max(linear, float3(0.0));
    float peak = max(headroom, 1.0);
    // SDR: scale the whole colour down by its brightest channel. Clipping each channel on its own
    // turned the bright blue of a star's head green.
    if (peak <= 1.05) return x / max(1.0, max(x.r, max(x.g, x.b)));
    float room = peak - 1.0;
    float3 over = max(x - 1.0, float3(0.0));
    return min(x, float3(1.0)) + room * (1.0 - exp(-over / room));
}

fragment float4 glowPresent(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> stars [[texture(0)]],
    texture2d<float> bloom [[texture(1)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    float2 uv = in.position.xy / size;
    bool dark = u.dark > 0.5;
    float scale = max(u.pointScale, 1.0);
    float band = size.y / scale;
    float2 p = pointsOf(in.position.xy, u);
    float f = saturate(p.y / max(band, 1.0));
    float fade = saturate(u.transition);
    float gain = max(u.intensity, 0.0) * (u.lowPower > 0.5 ? 0.9 : 1.0);

    // The wash: colour and cover crossfade between the two states.
    float3 tint = mix(washColor(u.previous, dark), washColor(u.state, dark), fade);
    float amp = mix(amplitude(u.previous), amplitude(u.state), fade) * gain;
    float washA = washCover(f, dark, amp);
    float t = u.reduced > 0.5 ? 1.7 : u.time;
    bool sweeping = (abs(u.state - 1.0) < 0.5 || abs(u.previous - 1.0) < 0.5) && u.reduced < 0.5;
    if (sweeping) {
        // The wash swells a little over the pulse, low down only.
        float amount = abs(u.state - 1.0) < 0.5 ? fade : (1.0 - fade);
        float g = (p.x - pulseX(t, size.x / scale)) / 90.0;
        washA += exp(-g * g) * washCover(f * 1.6, dark, 1.0) * 0.35 * amount;
    }
    washA = min(washA, dark ? kPeakDark : kPeakLight);

    float4 sharp = stars.sample(smp, uv);
    float4 soft = bloom.sample(smp, uv);
    sharp = float4(sanitize(sharp.rgb), sanitize1(sharp.a));
    soft = float4(sanitize(soft.rgb), sanitize1(soft.a));
    // Dark: star cores lift into the display's headroom and bloom. Light: no real bloom (it would
    // grey the white page), just deeper ink.
    float lift = dark ? 1.0 + max(u.headroom - 1.0, 0.0) * 0.5 : 1.0;
    float bloomGain = dark ? 0.9 : 0.12;
    float3 light = sharp.rgb * lift * gain + soft.rgb * bloomGain * gain;
    float a = saturate(sharp.a * gain + soft.a * bloomGain * 0.4);
    float3 color = light + tint * washA * (1.0 - a);
    float cover = min(a + washA * (1.0 - a), kTotalCap);
    color = tonemap(sanitize(color), max(u.headroom, 1.0));
    float grainClock = u.reduced > 0.5 ? 0.0 : t;
    float dither = (glowHash(in.position.xy + grainClock * float2(17.0, 13.0)) - 0.5) / 255.0;
    color = max(color + dither * cover, float3(0.0));
    return float4(color, cover);
}
