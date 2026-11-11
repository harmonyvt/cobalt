#include <metal_stdlib>
using namespace metal;

// Uniform block. The order is SyncGlowUniforms.Index in SyncGlowKit: fifteen floats, no padding.
// 0 time, 1 state, 2 previous, 3 transition, 4 pending, 5 intensity, 6 density,
// 7 reduced motion, 8 display headroom, 9 low power, 10 event age, 11 width, 12 height,
// 13 atlas columns (12), 14 glyphs enabled, 15 pad. Sixteen floats, 64 bytes.
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
    float pad;
};

struct GlowVertex {
    float4 position [[position]];
};

// Glyph row, matching GlyphAtlasLayout.glyphs: . * + o ' `  - / \ | _ :
constant float kGlyphDot = 0.0;
constant float kGlyphStar = 1.0;
constant float kGlyphDash = 6.0;

// The grid was drawn for a phone in portrait: a band 393 pt wide and 152 pt tall. Same number as
// SyncGlowField.referenceAspect.
constant float kReferenceAspect = 393.0 / 152.0;

vertex GlowVertex glowVertex(uint id [[vertex_id]]) {
    float2 p = float2(float((id << 1) & 2), float(id & 2));
    GlowVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

float glowHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

/// `pow` on a negative base is NaN, which the tone map turns into black. Bases here are colours and falloff.
float safePow(float base, float exponent) {
    return pow(max(base, 0.0), exponent);
}

/// NaN and inf become 0, then the value stays in a finite non-negative range before bloom and tone map.
float3 sanitize(float3 c) {
    c = select(c, float3(0.0), isnan(c));
    c = select(c, float3(0.0), isinf(c));
    return clamp(c, float3(0.0), float3(8.0));
}

float3 toLinear(float3 srgb) {
    return float3(safePow(saturate(srgb).r, 2.2), safePow(saturate(srgb).g, 2.2), safePow(saturate(srgb).b, 2.2));
}

float3 palette(float s) {
    if (s > 5.5) return float3(0.0);
    if (s < 0.5) return toLinear(float3(0.42, 0.66, 0.95));
    if (s < 1.5) return toLinear(float3(0.55, 0.84, 1.00));
    if (s < 2.5) return toLinear(float3(0.50, 0.52, 0.58));
    if (s < 3.5) return toLinear(float3(0.95, 0.36, 0.30));
    if (s < 4.5) return toLinear(float3(0.50, 0.80, 0.94));
    return toLinear(float3(0.72, 0.86, 1.00));
}

float amplitude(float s) {
    if (s > 5.5) return 0.0;
    if (s < 0.5) return 0.40;
    if (s < 1.5) return 0.78;
    if (s < 2.5) return 0.30;
    if (s < 3.5) return 0.72;
    if (s < 4.5) return 0.66;
    return 0.62;
}

// Same choice as GlyphAtlasLayout.linkGlyph. y grows downward. `/` rises to the right.
float linkGlyphId(float2 delta, float salt) {
    float ax = abs(delta.x);
    float ay = abs(delta.y);
    if (ay < ax * 0.35 || (ax < 0.0001 && ay < 0.0001)) return salt > 0.72 ? 10.0 : 6.0;
    if (ax < ay * 0.35) return salt > 0.78 ? 11.0 : 9.0;
    return (delta.x * delta.y) < 0.0 ? 7.0 : 8.0;
}

/// How much wider than the phone band this drawable is. The band's height is fixed, so the column
/// count is multiplied by this: a wide window gets more cells, and a glyph keeps its shape.
/// Same as SyncGlowField.aspectScale.
float aspectScale(constant GlowUniforms &u) {
    float2 size = max(float2(u.width, u.height), float2(1.0));
    return max(size.x / size.y / kReferenceAspect, 0.25);
}

float glyphMask(float2 uv, float2 pos, float gid, float2 cells, texture2d<float> atlas, sampler smp) {
    float2 local = (uv - pos) * float2(cells.x * 1.15, cells.y * 1.85) + 0.5;
    if (local.x < 0.0 || local.y < 0.0 || local.x > 1.0 || local.y > 1.0) return 0.0;
    float2 inset = local;
    inset = mix(float2(0.12), float2(0.88), local);
    float2 auv = float2((inset.x + gid) / 12.0, inset.y);
    return atlas.sample(smp, auv).r;
}

struct Star {
    float2 pos;
    float exist;
    float glyph;
    float blink;
};

Star starCell(float2 gid, float2 cells, float scale, float st, float age, float reduced, float density, float pending, float time) {
    Star s;
    float stateId = floor(st + 0.5);
    float h = glowHash(gid + 17.0 * stateId);
    float h2 = glowHash(gid + 91.0);
    s.exist = step(h, 0.22 + 0.28 * density);
    s.blink = 1.0;
    if (st > 5.5) s.exist = 0.0;
    // 410: dissolve from the left, then draw back in from the left. Reduce Motion shows the finished field.
    if (abs(st - 4.0) < 0.5) {
        float p = reduced > 0.5 ? 1.0 : clamp(age / 2.2, 0.0, 1.0);
        float x = (gid.x + 0.5) / max(cells.x, 1.0);
        float mask = 1.0;
        if (p < 0.5) {
            float edge = p / 0.5;
            mask = smoothstep(edge - 0.02, edge + 0.12, x);
        } else {
            float edge = (p - 0.5) / 0.5;
            mask = 1.0 - smoothstep(edge - 0.12, edge + 0.02, x);
        }
        s.exist *= mask;
    }
    float2 jitter = float2(h, h2) - 0.5;
    // A refusal breaks the figure, then it settles back.
    if (abs(st - 3.0) < 0.5 && reduced < 0.5) {
        float rise = smoothstep(0.0, 0.35, age);
        float fall = 1.0 - smoothstep(0.35, 1.15, age);
        float shatter = rise * fall;
        jitter += (float2(glowHash(gid + 3.1), glowHash(gid + 8.7)) - 0.5) * shatter * 1.6;
        s.exist *= mix(0.45, 1.0, 1.0 - shatter);
    }
    s.pos = (gid + 0.5 + jitter * 0.46) / cells;
    s.glyph = floor(min(h2, 0.999) * 6.0);
    if (reduced < 0.5) {
        float speed = st < 0.5 ? 1.1 : 2.2;
        if (st > 1.5 && st < 2.5) speed = 1.4;
        s.blink = 0.72 + 0.28 * sin(time * speed + h * 6.283);
    }
    // Offline: dim the field and hold N stars in a blinking cluster. N is capped at 8.
    if (abs(st - 2.0) < 0.5) {
        float2 cluster = float2(0.68, 0.36);
        // Measured in the phone band's units, so a wide window holds the same few stars, not more.
        float inCluster = smoothstep(0.26, 0.06, length((s.pos - cluster) * float2(scale, 1.0)));
        float n = floor(clamp(pending, 0.0, 8.0) + 0.5);
        float idx = floor(glowHash(gid + 4.2) * 8.0);
        float held = step(idx, n - 0.5) * inCluster;
        if (reduced < 0.5) s.blink = mix(0.35, 1.0, abs(sin(time * 2.4 + idx)));
        s.exist = max(s.exist * 0.28, held);
        s.blink = mix(s.blink, max(s.blink, 0.45), held);
    }
    return s;
}

float3 constellation(float st, float2 uv, constant GlowUniforms &u, texture2d<float> atlas, sampler smp) {
    if (u.glyphsEnabled < 0.5 || st > 5.5) return float3(0.0);
    float scale = aspectScale(u);
    float2 cells = float2((7.0 + 12.0 * u.density) * scale, 3.0 + 2.2 * u.density);
    float2 gid0 = floor(uv * cells);
    float3 col = float3(0.0);
    float t = u.reduced > 0.5 ? 1.7 : u.time;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 gid = gid0 + float2(float(i), float(j));
            Star s = starCell(gid, cells, scale, st, u.eventAge, u.reduced, u.density, u.pending, t);
            float mask = glyphMask(uv, s.pos, s.glyph, cells, atlas, smp);
            col += palette(st) * mask * s.exist * s.blink;
            if (i == 0 && j == 0) {
                Star right = starCell(gid + float2(1.0, 0.0), cells, scale, st, u.eventAge, u.reduced, u.density, u.pending, t);
                Star down = starCell(gid + float2(0.0, 1.0), cells, scale, st, u.eventAge, u.reduced, u.density, u.pending, t);
                float saltH = glowHash(gid + 21.0 + floor(st + 0.5));
                float saltV = glowHash(gid + 44.0 + floor(st + 0.5));
                float linkH = step(0.62, saltH) * s.exist * right.exist;
                float linkV = step(0.70, saltV) * s.exist * down.exist;
                if (abs(st - 1.0) < 0.5 && u.reduced < 0.5) {
                    float sweep = fract(t * 0.22);
                    float boost = smoothstep(0.0, 0.15, sweep - s.pos.x + 0.1);
                    linkH *= mix(0.35, 1.35, boost);
                    linkV *= mix(0.35, 1.2, boost);
                }
                if (abs(st - 3.0) < 0.5 && u.reduced < 0.5) {
                    float rise = smoothstep(0.0, 0.35, u.eventAge);
                    float fall = 1.0 - smoothstep(0.35, 1.15, u.eventAge);
                    float keep = 1.0 - rise * fall;
                    linkH *= keep;
                    linkV *= keep;
                }
                // The slope is judged in the phone band's units too, or a wide window would read
                // every link between side-by-side stars as upright.
                float hid = linkGlyphId((right.pos - s.pos) * float2(scale, 1.0), saltH);
                float vid = linkGlyphId((down.pos - s.pos) * float2(scale, 1.0), saltV);
                for (int stepIndex = 1; stepIndex <= 4; stepIndex++) {
                    float f = float(stepIndex) / 5.0;
                    float2 hp = mix(s.pos, right.pos, f);
                    float2 vp = mix(s.pos, down.pos, f);
                    col += palette(st) * glyphMask(uv, hp, hid, cells, atlas, smp) * linkH * 0.9;
                    col += palette(st) * glyphMask(uv, vp, vid, cells, atlas, smp) * linkV * 0.75;
                }
            }
        }
    }
    if (abs(st - 5.0) < 0.5 && u.reduced < 0.5) {
        float travel = clamp(u.eventAge / 1.6, 0.0, 1.0);
        float sx = mix(-0.12, 1.08, travel);
        float sy = 0.30 + 0.02 * sin(u.eventAge * 3.0);
        col += palette(st) * glyphMask(uv, float2(sx, sy), kGlyphStar, cells, atlas, smp) * 1.6;
        // The tail follows at a fixed distance in glyphs, whatever the width.
        col += palette(st) * glyphMask(uv, float2(sx - 0.055 / scale, sy + 0.012), kGlyphDash, cells, atlas, smp) * 0.9;
        col += palette(st) * glyphMask(uv, float2(sx - 0.105 / scale, sy + 0.028), kGlyphDot, cells, atlas, smp) * 0.55;
    }
    return col;
}

fragment float4 glowStars(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    float2 uv = in.position.xy / size;
    float fade = saturate(u.transition);
    // Once the crossfade is over the outgoing field has no weight, so it is not worked out at all.
    float3 col = constellation(u.state, uv, u, atlas, smp);
    if (fade < 0.999) col = mix(constellation(u.previous, uv, u, atlas, smp), col, fade);
    col = sanitize(col);
    return float4(col, clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0));
}

fragment float4 glowBlurH(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> src [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    float2 uv = in.position.xy / size;
    float2 texel = float2(1.6 / size.x, 0.0);
    float4 c = src.sample(smp, uv) * 0.227027;
    c += src.sample(smp, uv + texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv - texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv + texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv - texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv + texel * 3.0) * 0.054054;
    c += src.sample(smp, uv - texel * 3.0) * 0.054054;
    c += src.sample(smp, uv + texel * 4.0) * 0.016216;
    c += src.sample(smp, uv - texel * 4.0) * 0.016216;
    return float4(sanitize(c.rgb), saturate(c.a));
}

fragment float4 glowBlurV(
    GlowVertex in [[stage_in]],
    constant GlowUniforms &u [[buffer(0)]],
    texture2d<float> src [[texture(0)]]
) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = max(float2(u.width, u.height), float2(1.0));
    float2 uv = in.position.xy / size;
    float2 texel = float2(0.0, 1.6 / size.y);
    float4 c = src.sample(smp, uv) * 0.227027;
    c += src.sample(smp, uv + texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv - texel * 1.0) * 0.1945946;
    c += src.sample(smp, uv + texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv - texel * 2.0) * 0.1216216;
    c += src.sample(smp, uv + texel * 3.0) * 0.054054;
    c += src.sample(smp, uv - texel * 3.0) * 0.054054;
    c += src.sample(smp, uv + texel * 4.0) * 0.016216;
    c += src.sample(smp, uv - texel * 4.0) * 0.016216;
    return float4(sanitize(c.rgb), saturate(c.a));
}

float3 tonemap(float3 linear, float headroom) {
    float3 x = max(linear, float3(0.0));
    float peak = max(headroom, 1.0);
    if (peak <= 1.05) {
        float a = 2.51;
        float b = 0.03;
        float c = 2.43;
        float d = 0.59;
        float e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }
    // 1.0 is SDR white. The shoulder lets star cores sit above it, up to the display's headroom.
    return min(x * peak / (x + peak * 0.55), float3(peak));
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
    float t = u.reduced > 0.5 ? 1.7 : u.time;
    float fall = safePow(1.0 - smoothstep(0.0, 0.98, uv.y), 1.35);
    float fade = saturate(u.transition);
    float3 base = mix(palette(u.previous), palette(u.state), fade);
    float amp = mix(amplitude(u.previous), amplitude(u.state), fade) * max(u.intensity, 0.0);
    if (u.lowPower > 0.5) amp *= 0.85;
    float3 wash = base * amp * fall * (0.45 + 0.55 * (1.0 - uv.y));
    bool sweeping = (abs(u.state - 1.0) < 0.5 || abs(u.previous - 1.0) < 0.5) && u.reduced < 0.5;
    if (sweeping) {
        // `pow(x, 2)` is NaN for x < 0. Left of the sweep that blacked out a solid region.
        float delta = (uv.x - fract(t * 0.20)) * 7.0;
        float pulse = exp(-(delta * delta));
        float amount = abs(u.state - 1.0) < 0.5 ? fade : (1.0 - fade);
        wash += base * pulse * fall * amp * 0.7 * amount;
    }
    float3 sharp = sanitize(stars.sample(smp, uv).rgb);
    float3 soft = sanitize(bloom.sample(smp, uv).rgb);
    float lift = 1.0 + max(u.headroom - 1.0, 0.0) * 0.45;
    float3 color = sanitize(wash + (sharp * lift + soft * 0.95) * (0.65 + amp) * fall);
    color = tonemap(color, max(u.headroom, 1.0));
    float grainClock = u.reduced > 0.5 ? 0.0 : t;
    float dither = (glowHash(in.position.xy + grainClock * float2(17.0, 13.0)) - 0.5) / 180.0;
    color += dither;
    float starCover = clamp(max(sharp.r, max(sharp.g, sharp.b)) * 1.4, 0.0, 1.0);
    float cover = clamp(fall * amp * 1.35 + starCover * fall, 0.0, 0.86);
    color = max(color, float3(0.0));
    return float4(color * cover, cover);
}
