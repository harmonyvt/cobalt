import CobaltKit
import SwiftUI

// Variation A — Studio Audio Dock + Segmented Address Bar for Share Links and Library Multi-Select.
//
// Enforces the strict `?audio=normal` hard gate (`AudioShareGate`):
// - The `leveled (?audio=normal)` track segment stays locked (with lock glyph, shake feedback, and error haptic)
//   until EVERY audible video in the share link / selection has a ready leveled alternate.
// - Non-video items (images, WebPs) and silent videos (<= -60 LUFS) never block `?audio=normal`.
// - Offers a 1-tap bulk level CTA (`level N videos · -14 lufs`) and stacked loudness distribution telemetry.

// MARK: - Shared Audio Accent Palette

enum AudioDockTone {
    static let emerald = Color(hex: 0x34d399)
    static let amber = Color(hex: 0xfbbf24)
    static let coral = Color(hex: 0xf87171)
    static let sky = Color(hex: 0x38bdf8)
    static let neutral = Color(hex: 0x9ca3af)
}

// MARK: - Horizontal Shake Feedback

/// Short horizontal spring shake triggered when tapping a locked `?audio=normal` control.
struct HorizontalShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var travel: CGFloat = 6

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(shakes * .pi * 3) * travel
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Studio Audio Dock (Share Link Detail)

/// Unified Liquid Glass Share Deck & Studio Audio Dock: segmented `original audio` vs `leveled (?audio=normal)`
/// hard-gated switch, recessed live URL pill with `ShareLink`, unified primary Copy + inline Level CTA row (when
/// `primaryCopyMode` is true), stacked loudness distribution bar, and gate status.
struct LinkAudioDock: View {
    let link: ShareSet
    let gate: AudioShareGate
    let target: AudioTargetLufs
    @Binding var useNormalAudio: Bool
    let activeURL: URL
    var isSubmitting = false
    var isCopied = false
    /// When true, renders the prominent primary `copy link` / `copy ?audio=normal` CTA paired inline with
    /// the 1-tap `level N` button inside the unified glass deck (used by `LinkPanePage` and `LinkScreen`).
    var primaryCopyMode = false
    var onCopy: (() -> Void)? = nil
    let onLevelRemaining: () -> Void
    let onBlockedTap: () -> Void

    @State private var shakeTrigger: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var normalActive: Bool {
        gate.canShareNormalAudio && useNormalAudio
    }

    private var shortBase: String {
        (link.url.host ?? "") + link.url.path
    }

    private var showsInlineLevelCTA: Bool {
        primaryCopyMode && gate.audibleVideoCount > 0 && gate.status == .blocked && !gate.queueableVideoIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if gate.status != .notApplicable {
                segmentedTrackSwitch
            }

            addressBarRow

            if primaryCopyMode, let onCopy {
                primaryActionRow(onCopy: onCopy)
            }

            if gate.audibleVideoCount > 0 {
                distributionBar
                statusAndActionRow
            } else {
                notApplicableRow
            }
        }
        .padding(12)
        .glassEffect(
            .regular.tint(normalActive ? AudioDockTone.emerald.opacity(0.08) : CobaltColor.surface.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    normalActive ? AudioDockTone.emerald.opacity(0.45) : CobaltColor.hairline,
                    lineWidth: normalActive ? 1 : 0.7
                )
                .allowsHitTesting(false)
        )
        .animation(Motion.chip, value: normalActive)
        .animation(Motion.rows, value: gate)
    }

    // MARK: segmented track switch

    private var segmentedTrackSwitch: some View {
        HStack(spacing: 4) {
            segmentButton(
                title: Copy.AudioBulk.segmentOriginal,
                trailing: nil,
                symbol: nil,
                selected: !normalActive,
                locked: false,
                tint: CobaltColor.text
            ) {
                withAnimation(Motion.chip) { useNormalAudio = false }
            }

            segmentButton(
                title: Copy.AudioBulk.segmentLeveled,
                trailing: Copy.AudioBulk.queryTag,
                symbol: gate.canShareNormalAudio ? Symbol.AudioBulk.leveled : Symbol.AudioBulk.locked,
                selected: normalActive,
                locked: !gate.canShareNormalAudio,
                tint: AudioDockTone.emerald
            ) {
                if gate.canShareNormalAudio {
                    withAnimation(Motion.chip) { useNormalAudio = true }
                } else {
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.32)) { shakeTrigger += 1 }
                    }
                    onBlockedTap()
                }
            }
            .modifier(HorizontalShakeEffect(shakes: shakeTrigger))
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CobaltColor.hairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func segmentButton(
        title: String,
        trailing: String?,
        symbol: String?,
        selected: Bool,
        locked: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(Font.cobalt(11.5, selected ? .semibold : .medium, relativeTo: .caption))
                    .lineLimit(1)
                if let trailing {
                    Text(trailing)
                        .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                        .foregroundStyle(selected ? tint : (locked ? CobaltColor.caption.opacity(0.65) : tint.opacity(0.75)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(
                selected
                    ? (tint == CobaltColor.text ? CobaltColor.text : tint)
                    : (locked ? CobaltColor.caption.opacity(0.65) : CobaltColor.caption)
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.horizontal, 8)
            .background(
                selected
                    ? (tint == CobaltColor.text ? Color.primary.opacity(0.10) : tint.opacity(0.16))
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8.5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(
                        selected && tint != CobaltColor.text ? tint.opacity(0.38) : Color.clear,
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: live address bar

    private var addressBarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.copyLink)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(normalActive ? AudioDockTone.emerald : CobaltColor.caption)
                .accessibilityHidden(true)

            HStack(spacing: 0) {
                Text(shortBase)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if normalActive {
                    Text(Copy.AudioBulk.queryTag)
                        .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(AudioDockTone.emerald)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Copy.LinksPane.addressA11y)
            .accessibilityValue(activeURL.absoluteString)

            IconRow(spacing: 6, alignment: .trailing) {
                if !primaryCopyMode, let onCopy {
                    Button(action: onCopy) {
                        Label(
                            normalActive ? Copy.AudioBulk.copyLeveledLink : Copy.Links.copyLink,
                            systemImage: isCopied ? Symbol.Library.copied : Symbol.copyLink
                        )
                    }
                    .buttonStyle(.cobaltIcon(.small, prominent: true, state: isCopied ? .done : .idle))
                }
                ShareLink(item: activeURL) {
                    Label(Copy.Links.share, systemImage: Symbol.share)
                }
                .buttonStyle(.cobaltIcon(.small, tint: normalActive ? AudioDockTone.emerald : CobaltColor.linkBlue))
            }
            .fixedSize()
        }
        .padding(.leading, primaryCopyMode ? 10 : 0)
        .padding(.trailing, primaryCopyMode ? 4 : 0)
        .padding(.vertical, primaryCopyMode ? 4 : 0)
        .background(
            primaryCopyMode ? Color.primary.opacity(0.055) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(primaryCopyMode ? CobaltColor.hairline : Color.clear, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    // MARK: unified primary CTA row (copy + inline level)

    @ViewBuilder
    private func primaryActionRow(onCopy: @escaping () -> Void) -> some View {
        let copyButton = Button(action: onCopy) {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? Symbol.Library.copied : Symbol.copyLink)
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    isCopied
                        ? Copy.PrivateLinks.copied
                        : (normalActive ? Copy.AudioBulk.copyLeveledLink : Copy.Links.copyLink)
                )
                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isCopied ? .white : CobaltColor.onText)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 40)
            .padding(.horizontal, 12)
            .background(
                isCopied
                    ? CobaltColor.success
                    : (normalActive ? AudioDockTone.emerald : CobaltColor.text),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.chip, value: isCopied)

        if showsInlineLevelCTA {
            let count = gate.queueableVideoIDs.count
            let isRetryOnly = gate.failedCount > 0 && gate.failedCount == count
            let levelButton = Button(action: onLevelRemaining) {
                HStack(spacing: 5) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(CobaltColor.onText)
                    } else {
                        Image(systemName: isRetryOnly ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(
                        isSubmitting
                            ? Copy.AudioBulk.leveling
                            : (isRetryOnly ? Copy.AudioBulk.retryShort(count) : Copy.AudioBulk.levelShort(count))
                    )
                    .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                    .lineLimit(1)
                }
                .foregroundStyle(CobaltColor.onText)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .frame(minHeight: 40)
                .padding(.horizontal, 14)
                .background(AudioDockTone.emerald, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel(
                isRetryOnly ? Copy.AudioBulk.retryRemaining(count) : Copy.AudioBulk.levelRemaining(count, target: target)
            )

            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    copyButton
                    levelButton
                }
            } else {
                HStack(spacing: 8) {
                    copyButton
                    levelButton
                }
            }
        } else {
            copyButton
        }
    }

    // MARK: stacked loudness distribution bar

    private var distributionBar: some View {
        GeometryReader { geo in
            let total = max(1, gate.audibleVideoCount)
            let w = max(1, geo.size.width)
            HStack(spacing: 1.5) {
                segment(count: gate.leveledCount, total: total, width: w, color: AudioDockTone.emerald)
                segment(count: gate.renderingCount, total: total, width: w, color: AudioDockTone.amber)
                segment(count: gate.loudCount, total: total, width: w, color: AudioDockTone.coral)
                segment(count: gate.quietCount, total: total, width: w, color: AudioDockTone.sky)
                segment(count: gate.balancedUnleveledCount, total: total, width: w, color: AudioDockTone.emerald.opacity(0.45))
                segment(count: gate.unmeasuredCount, total: total, width: w, color: AudioDockTone.neutral.opacity(0.45))
                segment(count: gate.failedCount, total: total, width: w, color: CobaltColor.errorText)
            }
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(count: Int, total: Int, width: CGFloat, color: Color) -> some View {
        if count > 0 {
            Rectangle()
                .fill(color)
                .frame(width: max(4, width * (CGFloat(count) / CGFloat(total))))
        }
    }

    // MARK: gate status & 1-tap bulk CTA

    private var statusAndActionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusTint)
                Text(statusText)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(gate.canShareNormalAudio ? AudioDockTone.emerald : CobaltColor.caption)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Spacer(minLength: 6)
                Text("\(gate.leveledCount)/\(gate.audibleVideoCount)")
                    .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(gate.canShareNormalAudio ? AudioDockTone.emerald : CobaltColor.text)
                    .contentTransition(.numericText())
            }

            if gate.status == .blocked {
                if !primaryCopyMode, !gate.queueableVideoIDs.isEmpty {
                    let count = gate.queueableVideoIDs.count
                    let isRetryOnly = gate.failedCount > 0 && gate.failedCount == count
                    Button(action: onLevelRemaining) {
                        HStack(spacing: 6) {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(CobaltColor.onText)
                            } else {
                                Image(systemName: isRetryOnly ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(
                                isSubmitting
                                    ? Copy.AudioBulk.leveling
                                    : (isRetryOnly
                                        ? Copy.AudioBulk.retryRemaining(count)
                                        : Copy.AudioBulk.levelRemaining(count, target: target))
                            )
                            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                            .lineLimit(1)
                        }
                        .foregroundStyle(CobaltColor.onText)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .padding(.horizontal, 12)
                        .background(AudioDockTone.emerald, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                } else if gate.isLeveling && gate.queueableVideoIDs.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AudioDockTone.amber)
                        Text(Copy.AudioBulk.levelingProgress(done: gate.leveledCount, total: gate.audibleVideoCount))
                            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                            .foregroundStyle(AudioDockTone.amber)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var notApplicableRow: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.AudioBulk.silent)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
            Text(Copy.AudioBulk.noAudibleVideos)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
        }
    }

    private var statusSymbol: String {
        if gate.canShareNormalAudio { return Symbol.AudioBulk.leveled }
        if gate.isLeveling && gate.queueableVideoIDs.isEmpty { return Symbol.AudioBulk.waveform }
        if gate.failedCount > 0 && gate.failedCount == gate.unleveledCount { return Symbol.AudioBulk.failed }
        return Symbol.AudioBulk.locked
    }

    private var statusTint: Color {
        if gate.canShareNormalAudio { return AudioDockTone.emerald }
        if gate.isLeveling && gate.queueableVideoIDs.isEmpty { return AudioDockTone.amber }
        if gate.failedCount > 0 && gate.failedCount == gate.unleveledCount { return CobaltColor.errorText }
        return CobaltColor.caption
    }

    private var statusText: String {
        if gate.canShareNormalAudio {
            return Copy.AudioBulk.allLeveled(gate.audibleVideoCount)
        }
        return gate.blockedReason ?? Copy.AudioBulk.lockedSuffix
    }
}

/// Matching Liquid Glass Share Deck used when the server does not enable `audio_leveling`:
/// recessed live URL pill + `ShareLink` + prominent full-width `copy link` CTA.
struct LinkPlainShareDeck: View {
    let link: ShareSet
    let isCopied: Bool
    let onCopy: () -> Void

    private var shortLink: String {
        (link.url.host ?? "") + link.url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: Symbol.copyLink)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)

                Text(shortLink)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Copy.LinksPane.addressA11y)
                    .accessibilityValue(link.url.absoluteString)

                ShareLink(item: link.url) {
                    Label(Copy.Links.share, systemImage: Symbol.share)
                }
                .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(CobaltColor.hairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )

            Button(action: onCopy) {
                HStack(spacing: 6) {
                    Image(systemName: isCopied ? Symbol.Library.copied : Symbol.copyLink)
                        .font(.system(size: 13, weight: .semibold))
                    Text(isCopied ? Copy.PrivateLinks.copied : Copy.Links.copyLink)
                        .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                        .lineLimit(1)
                }
                .foregroundStyle(isCopied ? .white : CobaltColor.onText)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 40)
                .padding(.horizontal, 12)
                .background(
                    isCopied ? CobaltColor.success : CobaltColor.text,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(Motion.chip, value: isCopied)
        }
        .padding(12)
        .glassEffect(.regular.tint(CobaltColor.surface.opacity(0.55)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CobaltColor.hairline, lineWidth: 0.7)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Per-Row Loudness Badge (LinkFileRow)

/// Compact loudness telemetry pill shown on each visible video row in `files · in order`.
/// Un-leveled / failed rows optionally expose a 1-tap `onLevel` trigger without nesting buttons.
struct LinkRowAudioBadge: View {
    let audio: AudioLoudnessInfo?
    var onLevel: (() -> Void)? = nil

    private var isActionable: Bool {
        guard onLevel != nil else { return false }
        guard let audio else { return true }
        return !audio.isLeveled && !audio.isRendering && !audio.isSilent
    }

    var body: some View {
        if isActionable, let onLevel {
            Button(action: onLevel) {
                pillContent(actionable: true)
            }
            .buttonStyle(.plain)
            .help(audio?.state == .failed ? Copy.AudioBulk.retryLeveling : Copy.AudioBulk.levelAudio)
            .accessibilityLabel(accessibilityText)
        } else {
            pillContent(actionable: false)
                .accessibilityLabel(accessibilityText)
        }
    }

    private func pillContent(actionable: Bool) -> some View {
        HStack(spacing: 4) {
            if audio?.isRendering == true {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AudioDockTone.amber)
            } else if audio?.isLeveled == true {
                Image(systemName: Symbol.AudioBulk.leveled)
                    .font(.system(size: 9.5, weight: .semibold))
            } else if audio?.state == .failed {
                Image(systemName: Symbol.AudioBulk.failed)
                    .font(.system(size: 9.5, weight: .semibold))
            } else if audio?.isSilent == true {
                Image(systemName: Symbol.AudioBulk.silent)
                    .font(.system(size: 9.5, weight: .semibold))
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }

            Text(labelText)
                .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                .monospacedDigit()
                .lineLimit(1)

            if actionable {
                Image(systemName: audio?.state == .failed ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform)
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(actionable ? 0.35 : 0.2), lineWidth: 0.6)
        )
        .fixedSize()
        .contentShape(Capsule())
    }

    private var tint: Color {
        guard let audio else { return AudioDockTone.neutral }
        return audio.statusTint
    }

    private var labelText: String {
        guard let audio else { return Copy.AudioBulk.badgeUnmeasured }
        if audio.isLeveled {
            if let out = audio.outputLufs, out.isFinite {
                return String(format: "%.1f", out)
            }
            return Copy.AudioBulk.badgeLeveledFallback
        }
        if audio.isRendering { return Copy.AudioBulk.badgeLeveling }
        if audio.state == .failed { return Copy.AudioBulk.badgeFailed }
        if audio.isSilent { return Copy.AudioBulk.badgeSilent }
        if let lufs = audio.integratedLufs, lufs.isFinite {
            return String(format: "%.1f", lufs)
        }
        return Copy.AudioBulk.badgeUnmeasured
    }

    private var accessibilityText: String {
        guard let audio else { return Copy.AudioBulk.badgeUnmeasured }
        if audio.isLeveled { return "leveled \(AudioLoudnessInfo.formatLufs(audio.outputLufs))" }
        if audio.isRendering { return Copy.AudioBulk.badgeLeveling }
        if audio.state == .failed { return Copy.AudioBulk.retryLeveling }
        if audio.isSilent { return Copy.AudioBulk.badgeSilent }
        return AudioLoudnessInfo.formatLufs(audio.integratedLufs)
    }
}

// MARK: - Library Multi-Select Slim Audio Strip

/// Slim Variation A Audio Strip docked above the action grid in `LibraryPickedSheet` and `PaneSelectionPage`.
/// Shows audible video counts, 1-tap `level N` action, and strictly gated `?audio=normal` toggle for `make share link`.
struct LibraryAudioStrip: View {
    let gate: AudioShareGate
    @Binding var useNormalAudio: Bool
    var isSubmitting = false
    let onLevel: () -> Void
    let onBlockedTap: () -> Void

    @State private var shakeTrigger: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var normalActive: Bool {
        gate.canShareNormalAudio && useNormalAudio
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingStatus
            Spacer(minLength: 4)
            trailingControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            normalActive ? AudioDockTone.emerald.opacity(0.10) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    normalActive ? AudioDockTone.emerald.opacity(0.32) : CobaltColor.hairline,
                    lineWidth: 0.6
                )
        )
        .animation(Motion.chip, value: normalActive)
        .animation(Motion.rows, value: gate)
    }

    private var leadingStatus: some View {
        HStack(spacing: 6) {
            if gate.isLeveling && gate.queueableVideoIDs.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AudioDockTone.amber)
            } else if gate.canShareNormalAudio {
                Image(systemName: Symbol.AudioBulk.leveled)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AudioDockTone.emerald)
            } else {
                Circle()
                    .fill(leadingDotColor)
                    .frame(width: 7, height: 7)
            }

            Text(statusLine)
                .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                .foregroundStyle(gate.canShareNormalAudio ? AudioDockTone.emerald : CobaltColor.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if gate.canShareNormalAudio {
            Button {
                withAnimation(Motion.chip) { useNormalAudio.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: normalActive ? Symbol.AudioBulk.leveled : Symbol.AudioBulk.waveform)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(Copy.AudioBulk.queryTag)
                        .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                        .lineLimit(1)
                }
                .foregroundStyle(normalActive ? CobaltColor.onText : AudioDockTone.emerald)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    normalActive ? AudioDockTone.emerald : AudioDockTone.emerald.opacity(0.14),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(AudioDockTone.emerald.opacity(normalActive ? 0 : 0.35), lineWidth: 0.6)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(normalActive ? .isSelected : [])
        } else {
            HStack(spacing: 6) {
                Button {
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.32)) { shakeTrigger += 1 }
                    }
                    onBlockedTap()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: Symbol.AudioBulk.locked)
                            .font(.system(size: 9, weight: .semibold))
                        Text(Copy.AudioBulk.queryTag)
                            .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                            .lineLimit(1)
                    }
                    .foregroundStyle(CobaltColor.caption.opacity(0.75))
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(HorizontalShakeEffect(shakes: shakeTrigger))

                if !gate.queueableVideoIDs.isEmpty {
                    let count = gate.queueableVideoIDs.count
                    let isRetryOnly = gate.failedCount > 0 && gate.failedCount == count
                    Button(action: onLevel) {
                        HStack(spacing: 4) {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(CobaltColor.onText)
                            } else {
                                Image(systemName: isRetryOnly ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform)
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            Text(
                                isSubmitting
                                    ? Copy.AudioBulk.leveling
                                    : (isRetryOnly ? Copy.AudioBulk.retryShort(count) : Copy.AudioBulk.levelShort(count))
                            )
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .lineLimit(1)
                        }
                        .foregroundStyle(CobaltColor.onText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(AudioDockTone.emerald, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private var leadingDotColor: Color {
        if gate.failedCount > 0 && gate.failedCount == gate.unleveledCount { return CobaltColor.errorText }
        if gate.loudCount > 0 { return AudioDockTone.coral }
        if gate.quietCount > 0 { return AudioDockTone.sky }
        if gate.isLeveling { return AudioDockTone.amber }
        return AudioDockTone.neutral
    }

    private var statusLine: String {
        if gate.canShareNormalAudio {
            return Copy.AudioBulk.allLeveledCompact(gate.audibleVideoCount)
        }
        if gate.isLeveling && gate.queueableVideoIDs.isEmpty {
            return Copy.AudioBulk.levelingProgress(done: gate.leveledCount, total: gate.audibleVideoCount)
        }
        return Copy.AudioBulk.needsLevelCompact(audible: gate.audibleVideoCount, remaining: gate.unleveledCount)
    }
}
