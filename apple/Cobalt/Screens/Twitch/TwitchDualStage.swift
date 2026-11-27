import CobaltKit
import SwiftUI

// Opus's Best-of-Breed Dual-Stream Video Stage:
//   - Focus-First default: focused stream fills the stage; secondary stream renders as an interactive 16:9 inset tile
//     whose 1-tap action swaps focus cleanly with zero black flash.
//   - 1-tap 50/50 toggle: uses `TwitchDualLayout.splitAxis(for:)` — side-by-side (`HStack`) ONLY when
//     `width / height > 16 / 9`, stacked vertically (`VStack`) everywhere else (Duo Wide, Duo Tall, Folded Outer).
//   - Wrapped in ONE `DuoMediaOverlay` with Clear Liquid Glass HUD (`MediaGlassGroup`, `.mediaGlass*`, `MediaEdgeVignette`).
//   - Tap main video toggles HUD visibility ONLY — never mutates layout or swaps streams.
//   - One >= 44 pt `A · Mix · B` segmented + scrubbable equal-power crossfader with follow-focus default and explicit
//     pin badge + 1-tap unpin when manually adjusted.
//   - Speaker glyph appears ONLY on the louder stream (`dualMixer.louderSlot`); never two equal speaker badges.
//   - Every interactive control meets `Metrics.hit` (>= 44 pt).

struct TwitchDualStage: View {
    let primary: String
    let secondary: String
    let primaryDisplayName: String
    let secondaryDisplayName: String
    let showsTopChrome: Bool
    let compactChrome: Bool
    let onMinimize: () -> Void
    let onStop: () -> Void
    let onSwitchSecondStream: () -> Void
    let onKeepOnly: (String) -> Void
    let onOpenOnTwitch: (String) -> Void

    @Environment(Pane.self) private var pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holderID = UUID()
    @State private var stageSize: CGSize = .zero
    @State private var hudVisible = true
    @State private var hudHideTask: Task<Void, Never>?
    @State private var isScrubbingAudio = false

    private var host: TwitchPlayerHost { .shared }
    private var holds: Bool { host.holds(holderID) }
    private var mixer: TwitchDualAudioMixer { host.dualMixer }

    private var primaryAccent: Color { Color(dualRGB: TwitchChannelAccent.primaryDarkRGB) }
    private var secondaryAccent: Color { Color(dualRGB: TwitchChannelAccent.secondaryDarkRGB) }

    private func displayName(for slot: TwitchDualSlot) -> String {
        slot == .primary ? primaryDisplayName : secondaryDisplayName
    }

    private func login(for slot: TwitchDualSlot) -> String {
        slot == .primary ? primary : secondary
    }

    private func accent(for slot: TwitchDualSlot) -> Color {
        slot == .primary ? primaryAccent : secondaryAccent
    }

    private func shortMark(for slot: TwitchDualSlot) -> String {
        let name = displayName(for: slot)
        if let first = name.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        return slot == .primary ? "A" : "B"
    }

    private var showsPauseGlyph: Bool {
        !host.userPaused && (host.isPlaying || host.secondaryIsPlaying || host.isLoading || host.secondaryIsLoading)
    }

    var body: some View {
        DuoMediaOverlay(edge: .bottom, axes: [.horizontal, .vertical]) { isSeparated in
            overlayHUD(isSeparated: isSeparated)
        } media: {
            videoCanvas
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        .onAppear {
            let p = pane
            host.restoreHandler = { ch in p.open(.stream(ch)) }
            host.restoreDualHandler = { a, b in p.open(.dualStream(primary: a, secondary: b)) }
            host.claimDual(holderID, primary: primary, secondary: secondary)
            scheduleHUDHide()
        }
        .onDisappear {
            hudHideTask?.cancel()
            hudHideTask = nil
            host.release(holderID)
        }
        .onChange(of: primary) { _, _ in
            host.claimDual(holderID, primary: primary, secondary: secondary)
        }
        .onChange(of: secondary) { _, _ in
            host.claimDual(holderID, primary: primary, secondary: secondary)
        }
        .onChange(of: isScrubbingAudio) { _, scrubbing in
            if scrubbing {
                hudHideTask?.cancel()
                hudVisible = true
            } else {
                scheduleHUDHide()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("twitch.dual.stage")
    }

    // MARK: - Video Canvas

    private var videoCanvas: some View {
        ZStack {
            #if os(iOS)
            // Mounted behind the stage so `AVPictureInPictureController.ContentSource` always has a live source view.
            TwitchDualPiPSourceAnchor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            #endif

            if host.holder != nil && !holds {
                placeholderView(symbol: Symbol.Twitch.tv, title: Copy.Twitch.playingElsewhere, buttonTitle: nil, action: nil)
            } else if host.isPiPOwningViews {
                #if os(iOS)
                placeholderView(
                    symbol: Symbol.Twitch.pipEnter,
                    title: Copy.Twitch.inPiP,
                    buttonTitle: Copy.Twitch.pipExit,
                    action: { host.togglePiP() }
                )
                #else
                placeholderView(
                    symbol: Symbol.Twitch.floatingPanel,
                    title: Copy.Twitch.floatingWindow,
                    buttonTitle: Copy.Twitch.closeFloatingWindow,
                    action: { host.togglePiP() }
                )
                #endif
            } else {
                switch host.dualStageMode {
                case .focusInset:
                    focusInsetCanvas
                case .split5050:
                    split5050Canvas
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Focus-First default: focused stream fills the stage; secondary stream sits in an interactive 16:9 inset.
    /// Tap main video toggles HUD visibility ONLY; 1-tap inset swaps focus.
    private var focusInsetCanvas: some View {
        let pair = TwitchDualLayout.heroAndInset(focused: mixer.focusedSlot)
        let insetDims = TwitchDualLayout.insetSize(for: stageSize)
        let bottomInsetPadding: CGFloat = hudVisible ? (compactChrome ? 62 : 76) : 14

        return ZStack(alignment: .bottomTrailing) {
            slotTile(slot: pair.hero, isInset: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleHUD()
                }

            // Interactive 16:9 inset tile — 1 tap swaps focus cleanly with zero flash.
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    host.swapDualFocus()
                }
                bumpHUD()
            } label: {
                slotTile(slot: pair.inset, isInset: true)
                    .frame(width: insetDims.width, height: insetDims.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if hudVisible {
                            Image(systemName: Symbol.Twitch.swapFocus)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .mediaGlassCircle(interactive: false)
                                .padding(6)
                                .transition(.opacity)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accent(for: pair.inset).opacity(0.85), lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.bottom, bottomInsetPadding)
            .accessibilityLabel("\(displayName(for: pair.inset)), \(Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier("twitch.dual.inset")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: bottomInsetPadding)
        }
    }

    /// 50/50 split: side-by-side ONLY when `width / height > 16 / 9`, stacked vertically everywhere else.
    /// Tap video toggles HUD ONLY; tap a stream's focus pill focuses that stream.
    @ViewBuilder
    private var split5050Canvas: some View {
        let axis = TwitchDualLayout.splitAxis(for: stageSize)
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 2))
            : AnyLayout(VStackLayout(spacing: 2))
        layout {
            splitTile(for: .primary)
            splitTile(for: .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitTile(for slot: TwitchDualSlot) -> some View {
        let isFocused = mixer.focusedSlot == slot
        return ZStack(alignment: .topLeading) {
            slotTile(slot: slot, isInset: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleHUD()
                }

            if isFocused {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(accent(for: slot).opacity(0.9), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Renders a single native stream slot plus its status/loading/offline state and single-speaker indicator.
    private func slotTile(slot: TwitchDualSlot, isInset: Bool) -> some View {
        let isLoading = slot == .primary ? host.isLoading : host.secondaryIsLoading
        let isBuffering = slot == .primary ? host.isBuffering : host.secondaryIsBuffering
        let isOffline = slot == .primary ? host.isOffline : host.secondaryIsOffline
        let isLouder = mixer.louderSlot == slot && !host.isMuted
        let isSuspended = mixer.suspendedSlot == slot
        let isFocused = mixer.focusedSlot == slot
        let heroAtBottomLeading = host.dualStageMode == .focusInset && !isInset

        return ZStack {
            Color.black
            TwitchNativeSlotSurface(slot: slot, holds: holds, pipActive: host.isPiPOwningViews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            if isOffline {
                VStack(spacing: 4) {
                    Image(systemName: Symbol.Twitch.warn)
                        .font(.system(size: isInset ? 14 : 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(displayName(for: slot)) · \(Copy.Twitch.offline)")
                        .font(Font.cobalt(isInset ? 10 : 12.5, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(6)
            } else if isSuspended {
                Label(Copy.Twitch.suspendedOnLock, systemImage: Symbol.Twitch.locked)
                    .font(Font.cobalt(isInset ? 10 : 12, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .mediaGlassCapsule(interactive: false)
            } else if isLoading || isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(isInset ? 0.75 : 1.0)
            }

            // Corner identity badge: speaker glyph ONLY on the louder stream (`dualMixer.louderSlot`).
            // In Focus-Inset mode, anchor the hero badge bottom-leading above the bottom glass bar so the top edge
            // stays completely clear for the compact `A · B` header pill.
            VStack {
                if heroAtBottomLeading { Spacer(minLength: 0) }
                HStack(spacing: 4) {
                    slotIdentityBadge(slot: slot, isInset: isInset, isLouder: isLouder, isFocused: isFocused)
                    Spacer(minLength: 0)
                }
                if !heroAtBottomLeading { Spacer(minLength: 0) }
            }
            .padding(.horizontal, isInset ? 6 : 10)
            .padding(.top, heroAtBottomLeading ? 0 : (isInset ? 6 : (showsTopChrome ? 56 : 10)))
            .padding(.bottom, heroAtBottomLeading ? (hudVisible ? (compactChrome ? 62 : 74) : 14) : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hudVisible)
            .allowsHitTesting(host.dualStageMode == .split5050 && !isInset)
        }
    }

    @ViewBuilder
    private func slotIdentityBadge(slot: TwitchDualSlot, isInset: Bool, isLouder: Bool, isFocused: Bool) -> some View {
        let badgeBody = HStack(spacing: 5) {
            Circle()
                .fill(accent(for: slot))
                .frame(width: isInset ? 6 : 7, height: isInset ? 6 : 7)
                .shadow(color: accent(for: slot).opacity(isFocused ? 0.7 : 0), radius: 3)
            Text(displayName(for: slot))
                .font(Font.cobalt(isInset ? 10.5 : 12, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if isLouder {
                Image(systemName: Symbol.Twitch.unmuted)
                    .font(.system(size: isInset ? 9.5 : 11, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(Copy.Twitch.audioMixerLabel)
            }
        }
        .padding(.horizontal, isInset ? 7 : 10)
        .padding(.vertical, isInset ? 4 : 6)
        .mediaGlassCapsule(interactive: host.dualStageMode == .split5050 && !isInset)

        if host.dualStageMode == .split5050 && !isInset {
            Button {
                host.setDualFocus(slot)
                bumpHUD()
            } label: {
                badgeBody
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(for: slot)), \(isFocused ? Copy.Twitch.watchingNow : Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier("twitch.dual.focus.\(slot.rawValue)")
        } else {
            badgeBody
                .opacity(hudVisible || isInset || isLouder ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hudVisible)
        }
    }

    private func placeholderView(symbol: String, title: String, buttonTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(title)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(.white.opacity(0.9))
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.glass)
                    .frame(minHeight: Metrics.hit)
            }
        }
        .padding(16)
    }

    // MARK: - Clear Liquid Glass Overlay HUD

    @ViewBuilder
    private func overlayHUD(isSeparated: Bool) -> some View {
        let showControls = isSeparated || hudVisible || host.isPiPActive
        ZStack {
            if !isSeparated && showControls {
                VStack(spacing: 0) {
                    MediaEdgeVignette(edge: .top, height: compactChrome ? 60 : 80, intensity: showsTopChrome ? 0.46 : 0.34)
                    Spacer(minLength: 0)
                    MediaEdgeVignette(edge: .bottom, height: compactChrome ? 72 : 92, intensity: 0.52)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                if showsTopChrome && (showControls || !hudVisible) {
                    topGlassHUD
                        .opacity(showControls ? 1 : 0)
                        .allowsHitTesting(showControls)
                } else if !showsTopChrome && showControls && host.dualStageMode == .focusInset {
                    compactDualStatusPill
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if showControls {
                    bottomGlassHUD(isSeparated: isSeparated)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: showControls)
    }

    /// Lightweight Clear Liquid Glass `A · B` status pill shown in single-focus dual-stream mode when the system
    /// toolbar owns Back/Stop so dual identity and thermal state remain legible without duplicating navigation buttons.
    private var compactDualStatusPill: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(primaryAccent)
                    .frame(width: 7, height: 7)
                    .opacity(mixer.focusedSlot == .primary ? 1 : 0.5)
                Text(primaryDisplayName)
                    .font(Font.cobalt(12, mixer.focusedSlot == .primary ? .semibold : .medium, relativeTo: .subheadline))
                    .foregroundStyle(mixer.focusedSlot == .primary ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.white.opacity(0.5))
                Circle()
                    .fill(secondaryAccent)
                    .frame(width: 7, height: 7)
                    .opacity(mixer.focusedSlot == .secondary ? 1 : 0.5)
                Text(secondaryDisplayName)
                    .font(Font.cobalt(12, mixer.focusedSlot == .secondary ? .semibold : .medium, relativeTo: .subheadline))
                    .foregroundStyle(mixer.focusedSlot == .secondary ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                if host.isThermalThrottled {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .accessibilityLabel(Copy.Twitch.thermalSteppedDown)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .mediaGlassCapsule(interactive: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, compactChrome ? 6 : 8)
        .allowsHitTesting(false)
    }

    /// Top Clear Liquid Glass HUD in single-focus iOS/Duo mode.
    private var topGlassHUD: some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onMinimize) {
                    Label(Copy.close, systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .mediaGlassCircle()
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.close)
                .accessibilityIdentifier("pane.close")

                HStack(spacing: 6) {
                    Circle().fill(primaryAccent).frame(width: 7, height: 7)
                    Text(primaryDisplayName)
                        .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.white.opacity(0.6))
                    Circle().fill(secondaryAccent).frame(width: 7, height: 7)
                    Text(secondaryDisplayName)
                        .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if host.isThermalThrottled {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Copy.Twitch.thermalSteppedDown)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.hit - 6)
                .mediaGlassCapsule(interactive: false)

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    streamManagementMenu
                    Button(role: .destructive, action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CobaltColor.errorText)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Twitch.stop)
                    .accessibilityIdentifier("twitch.hud.stop")
                }
                .padding(.horizontal, 2)
                .mediaGlassCapsule(interactive: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, compactChrome ? 4 : 8)
    }

    /// Bottom Clear Liquid Glass control strip: Play/Pause, `A · Mix · B` Equal-Power Crossfader, Focus ↔ 50/50 toggle,
    /// Swap Focus, PiP / Floating Window, and Stream Actions. Every interactive control is >= 44 pt (`Metrics.hit`).
    private func bottomGlassHUD(isSeparated: Bool) -> some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 6) {
                // Play / Pause both streams
                Button {
                    host.setPaused(showsPauseGlyph)
                    bumpHUD()
                } label: {
                    Label(showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play,
                          systemImage: showsPauseGlyph ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .mediaGlassCircle()
                .accessibilityLabel(showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play)
                .accessibilityIdentifier("twitch.dual.playpause")

                // One >= 44 pt A · Mix · B segmented + scrubbable equal-power crossfader
                TwitchDualAudioMixerControl(
                    mixer: mixer,
                    primaryMark: shortMark(for: .primary),
                    secondaryMark: shortMark(for: .secondary),
                    primaryName: primaryDisplayName,
                    secondaryName: secondaryDisplayName,
                    primaryAccent: primaryAccent,
                    secondaryAccent: secondaryAccent,
                    isMuted: host.isMuted,
                    isScrubbing: $isScrubbingAudio,
                    onInteract: bumpHUD
                )

                Spacer(minLength: 4)

                // Swap focus + 50/50 toggle + PiP/Floating panel in a unified glass capsule
                HStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                            host.swapDualFocus()
                        }
                        bumpHUD()
                    } label: {
                        Label(Copy.Twitch.swapFocus, systemImage: Symbol.Twitch.swapFocus)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Twitch.swapFocus)
                    .accessibilityIdentifier("twitch.dual.swapFocus")
                    .help(Copy.Twitch.swapFocus)

                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                            host.toggleDualStageMode()
                        }
                        bumpHUD()
                    } label: {
                        let nextIsSplit = host.dualStageMode == .focusInset
                        let splitSymbol = TwitchDualLayout.splitAxis(for: stageSize) == .horizontal
                            ? Symbol.Twitch.splitLayoutHorizontal
                            : Symbol.Twitch.splitLayoutVertical
                        Label(
                            nextIsSplit ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset,
                            systemImage: nextIsSplit ? splitSymbol : Symbol.Twitch.focusLayout
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(host.dualStageMode == .focusInset ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset)
                    .accessibilityIdentifier("twitch.dual.layoutToggle")
                    .help(host.dualStageMode == .focusInset ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset)

                    if host.canTogglePiP {
                        Button {
                            host.togglePiP()
                            bumpHUD()
                        } label: {
                            #if os(iOS)
                            let icon = host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.pipEnter
                            let label = host.isPiPActive ? Copy.Twitch.pipExit : Copy.Twitch.dualPiP
                            #else
                            let icon = host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.floatingPanel
                            let label = host.isPiPActive ? Copy.Twitch.closeFloatingWindow : Copy.Twitch.floatingWindow
                            #endif
                            Label(label, systemImage: icon)
                                .labelStyle(.iconOnly)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: Metrics.hit, height: Metrics.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(host.isPiPActive ? Copy.Twitch.pipExit : Copy.Twitch.dualPiP)
                        .accessibilityIdentifier("twitch.dual.pip")
                    }

                    if !showsTopChrome {
                        streamManagementMenu
                    }
                }
                .padding(.horizontal, 2)
                .mediaGlassCapsule(interactive: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, isSeparated ? 12 : (compactChrome ? 6 : 10))
    }

    private var streamManagementMenu: some View {
        Menu {
            Button(Copy.Twitch.swapSecondStream, systemImage: Symbol.Twitch.addStream, action: onSwitchSecondStream)
            Divider()
            Button(Copy.Twitch.keepOnly(primaryDisplayName), systemImage: Symbol.Twitch.dropStream) {
                onKeepOnly(primary)
            }
            Button(Copy.Twitch.keepOnly(secondaryDisplayName), systemImage: Symbol.Twitch.dropStream) {
                onKeepOnly(secondary)
            }
            Divider()
            if !host.variants.isEmpty {
                Menu("\(primaryDisplayName) · \(Copy.Twitch.quality)") {
                    ForEach(host.variants) { variant in
                        Button {
                            host.selectVariant(variant.id, for: .primary)
                        } label: {
                            if variant.id == host.selectedVariantID {
                                Label(variant.shortLabel, systemImage: "checkmark")
                            } else {
                                Text(variant.shortLabel)
                            }
                        }
                    }
                }
            }
            if !host.secondaryVariants.isEmpty {
                Menu("\(secondaryDisplayName) · \(Copy.Twitch.quality)") {
                    ForEach(host.secondaryVariants) { variant in
                        Button {
                            host.selectVariant(variant.id, for: .secondary)
                        } label: {
                            if variant.id == host.secondarySelectedVariantID {
                                Label(variant.shortLabel, systemImage: "checkmark")
                            } else {
                                Text(variant.shortLabel)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("\(Copy.Twitch.openOnTwitch) (\(primaryDisplayName))", systemImage: Symbol.Twitch.open) {
                onOpenOnTwitch(primary)
            }
            Button("\(Copy.Twitch.openOnTwitch) (\(secondaryDisplayName))", systemImage: Symbol.Twitch.open) {
                onOpenOnTwitch(secondary)
            }
            Divider()
            Button {
                host.toggleMute()
            } label: {
                Label(host.isMuted ? Copy.Twitch.unmute : Copy.Twitch.mute,
                      systemImage: host.isMuted ? Symbol.Twitch.unmuted : Symbol.Twitch.muted)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Media.more)
        .accessibilityIdentifier("twitch.dual.more")
    }

    // MARK: - HUD Auto-Hide

    private func toggleHUD() {
        hudVisible.toggle()
        if hudVisible {
            scheduleHUDHide()
        } else {
            hudHideTask?.cancel()
            hudHideTask = nil
        }
    }

    private func bumpHUD() {
        hudVisible = true
        scheduleHUDHide()
    }

    private func scheduleHUDHide() {
        hudHideTask?.cancel()
        hudHideTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, !isScrubbingAudio, !host.userPaused else { return }
            hudVisible = false
        }
    }
}

// MARK: - Equal-Power `A · Mix · B` Crossfader Control (>= 44 pt)

/// Single >= 44 pt segmented & scrubbable equal-power crossfader (`A · Mix · B`) with follow-focus default
/// and explicit pin badge + 1-tap unpin when manually adjusted.
struct TwitchDualAudioMixerControl: View {
    let mixer: TwitchDualAudioMixer
    let primaryMark: String
    let secondaryMark: String
    let primaryName: String
    let secondaryName: String
    let primaryAccent: Color
    let secondaryAccent: Color
    let isMuted: Bool
    @Binding var isScrubbing: Bool
    let onInteract: () -> Void

    @State private var controlWidth: CGFloat = 156

    private var activePreset: TwitchDualAudioPreset {
        mixer.activePreset
    }

    var body: some View {
        HStack(spacing: 4) {
            // Segmented + horizontal-scrubbable `A · Mix · B` pill
            ZStack(alignment: .leading) {
                // Continuous equal-power position indicator thumb behind the 3 labels
                let trackW = max(controlWidth - 8, 114)
                let thumbW = max(trackW / 3.0, 38)
                let offsetX = CGFloat(mixer.balance) * (trackW - thumbW)
                Capsule()
                    .fill(thumbTint.opacity(isMuted ? 0.16 : 0.36))
                    .overlay {
                        Capsule()
                            .strokeBorder(thumbTint.opacity(isMuted ? 0.25 : 0.65), lineWidth: 0.75)
                    }
                    .frame(width: thumbW, height: Metrics.hit - 8)
                    .offset(x: 4 + offsetX)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    segmentButton(
                        title: primaryMark,
                        accent: primaryAccent,
                        selected: activePreset == .primary,
                        accessibility: "\(primaryName) audio"
                    ) {
                        mixer.selectPreset(.primary)
                        onInteract()
                    }

                    segmentButton(
                        title: Copy.Twitch.audioMix,
                        accent: .white,
                        selected: activePreset == .mix,
                        accessibility: Copy.Twitch.audioMix
                    ) {
                        mixer.selectPreset(.mix)
                        onInteract()
                    }

                    segmentButton(
                        title: secondaryMark,
                        accent: secondaryAccent,
                        selected: activePreset == .secondary,
                        accessibility: "\(secondaryName) audio"
                    ) {
                        mixer.selectPreset(.secondary)
                        onInteract()
                    }
                }
            }
            .frame(minWidth: 136, maxWidth: 176, minHeight: Metrics.hit)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlWidth = $0 }
            .mediaGlassCapsule(interactive: false)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        isScrubbing = true
                        let width = max(controlWidth, 1)
                        let normalized = Double(value.location.x / width)
                        mixer.scrubBalance(to: normalized)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        onInteract()
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Twitch.audioMixerLabel)
            .accessibilityValue(accessibilityBalanceValue)
            .accessibilityIdentifier("twitch.dual.mixer")

            // Explicit pin badge + 1-tap unpin whenever the user manually adjusted audio balance.
            if mixer.isPinned {
                Button {
                    mixer.unpin()
                    onInteract()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Symbol.Twitch.pinFill)
                            .font(.system(size: 11, weight: .semibold))
                        Text(Copy.Twitch.audioUnpin)
                            .font(Font.cobalt(11, .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .mediaGlassCapsule()
                .accessibilityLabel("\(Copy.Twitch.audioPinned), \(Copy.Twitch.audioUnpin)")
                .accessibilityIdentifier("twitch.dual.unpinAudio")
                .help(Copy.Twitch.audioUnpin)
            }
        }
    }

    private var thumbTint: Color {
        switch mixer.louderSlot {
        case .primary: primaryAccent
        case .secondary: secondaryAccent
        case nil: .white
        }
    }

    private var accessibilityBalanceValue: String {
        let state = mixer.isPinned ? Copy.Twitch.audioPinned : Copy.Twitch.audioFollowsFocus
        switch activePreset {
        case .primary: return "\(primaryName), \(state)"
        case .secondary: return "\(secondaryName), \(state)"
        case .mix: return "\(Copy.Twitch.audioMix), \(state)"
        }
    }

    private func segmentButton(
        title: String,
        accent: Color,
        selected: Bool,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if accent != .white {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(Font.cobalt(12, selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1.0 : 0.78))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Accent Helper

private extension Color {
    init(dualRGB rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
