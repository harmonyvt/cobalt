import CobaltKit
import SwiftUI

// MARK: - Shared Loudness Color & Symbol Language

extension AudioZone {
    /// Unified tint across Studio Deck, Settings probe, and Library grid badges.
    var tint: Color {
        switch self {
        case .balanced: return Color(hex: 0x34d399)
        case .loud: return Color(hex: 0xf87171)
        case .quiet: return Color(hex: 0x38bdf8)
        case .silent: return Color(hex: 0x9ca3af)
        case .pending: return Color(hex: 0x9ca3af)
        }
    }

    var symbol: String {
        switch self {
        case .balanced: return "waveform"
        case .loud: return "speaker.wave.3.fill"
        case .quiet: return "speaker.wave.1.fill"
        case .silent: return "speaker.slash.fill"
        case .pending: return "waveform"
        }
    }
}

extension AudioLoudnessInfo {
    /// Color used for status badges and HUD pills representing this clip's current loudness state.
    var statusTint: Color {
        if isLeveled { return Color(hex: 0x34d399) }
        if isRendering { return Color(hex: 0xfbbf24) }
        if state == .failed { return CobaltColor.errorText }
        return zone.tint
    }
}

// MARK: - Unified LUFS Ruler

/// One LUFS ruler over `[-32, 0]` LUFS shared across Studio Deck, Settings, and the interactive rule probe.
///
/// Zones match the server classifier (`classifyLoudness` / `AudioLoudnessClassifier`):
/// - `[-32, -22)`: Too quiet (sky blue)
/// - `[-22, -12]`: Balanced (emerald)
/// - `(-12, -10.5]`: Balanced unless clipping `> -0.3 dBTP` (hatched amber)
/// - `(-10.5, 0]`: Too loud (coral red)
struct LoudnessRulerView: View {
    /// Measured integrated loudness of the original track (`nil` when unmeasured or silent).
    var measuredLufs: Double?
    /// Measured true peak of the original track (used to highlight clipping in the `-12..-10.5` band).
    var measuredTruePeak: Double? = nil
    /// Measured output loudness of the leveled copy when ready.
    var outputLufs: Double? = nil
    /// Active target loudness (`-14` or `-16` LUFS).
    var target: AudioTargetLufs = .lufs14
    /// Show the `-32 / -22 / target / -10.5 / 0` axis labels below the bar.
    var showsAxis: Bool = true
    /// Show the compact 4-zone legend below the axis.
    var showsLegend: Bool = false
    /// Compact height variant for tight spaces.
    var barHeight: CGFloat = 10

    private static let quietColor = Color(hex: 0x38bdf8)
    private static let balancedColor = Color(hex: 0x34d399)
    private static let clipColor = Color(hex: 0xfbbf24)
    private static let loudColor = Color(hex: 0xf87171)

    private var measuredZone: AudioZone? {
        guard let lufs = measuredLufs else { return nil }
        return AudioLoudnessClassifier.classify(lufs: lufs, truePeak: measuredTruePeak ?? -1.5).zone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let h = barHeight
                let cy = geo.size.height / 2

                let fQuiet = AudioRulerScale.fraction(for: AudioRulerScale.quietUpper)
                let fClip = AudioRulerScale.fraction(for: AudioRulerScale.clipLower)
                let fLoud = AudioRulerScale.fraction(for: AudioRulerScale.loudLower)
                let fTarget = AudioRulerScale.fraction(for: Double(target.rawValue))

                ZStack(alignment: .leading) {
                    // Zone segments inside rounded track
                    Canvas { ctx, size in
                        let trackRect = CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
                        let clipPath = Path(roundedRect: trackRect, cornerRadius: h / 2)
                        ctx.clip(to: clipPath)

                        let xQuiet = size.width * fQuiet
                        let xClip = size.width * fClip
                        let xLoud = size.width * fLoud

                        // Quiet [-32, -22)
                        ctx.fill(
                            Path(CGRect(x: 0, y: trackRect.minY, width: xQuiet, height: h)),
                            with: .color(Self.quietColor.opacity(0.45))
                        )
                        // Balanced [-22, -12]
                        ctx.fill(
                            Path(CGRect(x: xQuiet, y: trackRect.minY, width: max(0, xClip - xQuiet), height: h)),
                            with: .color(Self.balancedColor.opacity(0.45))
                        )
                        // Peak-clip conditional band (-12, -10.5]
                        let clipBand = CGRect(x: xClip, y: trackRect.minY, width: max(0, xLoud - xClip), height: h)
                        ctx.fill(Path(clipBand), with: .color(Self.clipColor.opacity(0.28)))
                        var hatch = Path()
                        var sx = clipBand.minX - h
                        while sx < clipBand.maxX + h {
                            hatch.move(to: CGPoint(x: sx, y: clipBand.maxY))
                            hatch.addLine(to: CGPoint(x: sx + h, y: clipBand.minY))
                            sx += 4.5
                        }
                        ctx.stroke(hatch, with: .color(Self.clipColor.opacity(0.75)), lineWidth: 1.2)

                        // Loud (-10.5, 0]
                        ctx.fill(
                            Path(CGRect(x: xLoud, y: trackRect.minY, width: max(0, size.width - xLoud), height: h)),
                            with: .color(Self.loudColor.opacity(0.5))
                        )

                        // Subtle border around track
                        ctx.stroke(clipPath, with: .color(.white.opacity(0.16)), lineWidth: 0.75)
                    }

                    // Target LUFS vertical tick
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1.5, height: h + 6)
                        .position(x: w * fTarget, y: cy)

                    // Connecting gain vector when both original & leveled output exist
                    if let m = measuredLufs, let o = outputLufs, m.isFinite, o.isFinite, m > -60 {
                        let x1 = w * AudioRulerScale.fraction(for: m)
                        let x2 = w * AudioRulerScale.fraction(for: o)
                        let left = min(x1, x2)
                        let span = abs(x2 - x1)
                        if span > 4 {
                            Capsule()
                                .fill(Self.balancedColor.opacity(0.9))
                                .frame(width: span, height: 2.5)
                                .position(x: left + span / 2, y: cy)
                        }
                    }

                    // Original measured marker
                    if let m = measuredLufs, m.isFinite, m > -60 {
                        let x = w * AudioRulerScale.fraction(for: m)
                        let dotTint = measuredZone?.tint ?? Self.balancedColor
                        let dimmed = outputLufs != nil
                        Circle()
                            .fill(dimmed ? dotTint.opacity(0.65) : dotTint)
                            .frame(width: dimmed ? 8 : 11, height: dimmed ? 8 : 11)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(dimmed ? 0.55 : 0.95), lineWidth: dimmed ? 1 : 1.5)
                            )
                            .shadow(color: dotTint.opacity(0.6), radius: dimmed ? 2 : 4)
                            .position(x: x, y: cy)
                    }

                    // Leveled output marker (crisp emerald ring)
                    if let o = outputLufs, o.isFinite, o > -60 {
                        let x = w * AudioRulerScale.fraction(for: o)
                        Circle()
                            .fill(Self.balancedColor)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2)
                            )
                            .shadow(color: Self.balancedColor.opacity(0.75), radius: 5)
                            .position(x: x, y: cy)
                    }
                }
            }
            .frame(height: max(18, barHeight + 8))

            if showsAxis {
                HStack(spacing: 0) {
                    Text("−32")
                    Spacer()
                    Text("−22")
                    Spacer()
                    Text("\(target.rawValue) target")
                        .foregroundStyle(.primary.opacity(0.85))
                        .fontWeight(.semibold)
                    Spacer()
                    Text("−10.5")
                    Spacer()
                    Text("0 LUFS")
                }
                .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if showsLegend {
                HStack(spacing: 10) {
                    legendDot(color: Self.quietColor, label: "Too quiet")
                    legendDot(color: Self.balancedColor, label: "Balanced")
                    legendDot(color: Self.clipColor, label: "Clips >−0.3")
                    legendDot(color: Self.loudColor, label: "Too loud")
                }
                .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .lineLimit(1)
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Loudness ruler, target \(target.label)"]
        if let m = measuredLufs, m > -60 {
            parts.append("original \(AudioLoudnessInfo.formatLufs(m))")
        }
        if let o = outputLufs, o > -60 {
            parts.append("leveled \(AudioLoudnessInfo.formatLufs(o))")
        }
        return parts.joined(separator: ", ")
    }
}
