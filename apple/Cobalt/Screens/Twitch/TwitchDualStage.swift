import CobaltKit
import SwiftUI

// Multi-Stream Video Stage (2, 3, and 4 simultaneous Twitch streams):
//   - N = 2: Focus-First default (hero + 16:9 interactive inset) and 1-tap 50/50 split (`TwitchDualLayout.splitAxis`),
//     with the >= 44 pt `A · Mix · B` equal-power scrubbable crossfader and 1-tap `+` to promote to 3 streams.
//   - N = 3 & N = 4:
//       * Spotlight mode (`TwitchMultiStageMode.spotlight`): Hero spotlight + side/bottom live dock (`TwitchMultiLayout.spotlightDock`).
//         1-tap any dock tile promotes it to spotlight with zero flash; tap hero toggles HUD ONLY.
//       * Grid mode (`TwitchMultiStageMode.grid`): Fold-safe 1 left + 2 stacked right on Duo vertical crease,
//         1 + 2 mosaic on flat screens for 3 streams, and 2x2 quad grid for 4 streams.
//       * Compact Audio Mixer pill opening a per-stream equal-power popover (`Follow Spotlight`, per-stream sliders, `Mix All`).
//   - Wrapped in ONE `DuoMediaOverlay` with Clear Liquid Glass HUD (`MediaGlassGroup`, `.mediaGlass*`, `MediaEdgeVignette`).
//   - Every live video surface carries `.mediaMask()`. Every interactive control meets `Metrics.hit` (>= 44 pt).

struct TwitchDualStage: View {
    let channels: [String]
    let displayNames: [String: String]
    let showsTopChrome: Bool
    let compactChrome: Bool
    var hasVerticalCrease: Bool = false
    let onMinimize: () -> Void
    let onStop: () -> Void
    let onAddStream: () -> Void
    let onSwitchSecondStream: () -> Void
    let onRemoveStream: (String) -> Void
    let onKeepOnly: (String) -> Void
    let onOpenOnTwitch: (String) -> Void

    @Environment(Pane.self) private var pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holderID = UUID()
    @State private var stageSize: CGSize = .zero
    @State private var hudVisible = true
    @State private var hudHideTask: Task<Void, Never>?
    @State private var isScrubbingAudio = false
    @State private var showingAudioMixerPopover = false

    private var host: TwitchPlayerHost { .shared }
    private var holds: Bool { host.holds(holderID) }
    private var mixer: TwitchDualAudioMixer { host.dualMixer }
    private var multiMixer: TwitchMultiAudioMixer { host.multiMixer }

    private var streamCount: Int { max(2, min(channels.count, PaneItem.maxSimultaneousStreams)) }
    private var isMulti: Bool { streamCount >= 3 }
    private var activeSlots: [TwitchStreamSlot] { TwitchStreamSlot.slots(forCount: streamCount) }
    private var canAddMoreStreams: Bool { streamCount < PaneItem.maxSimultaneousStreams }

    private var primary: String { channels.first ?? "" }
    private var secondary: String { channels.count > 1 ? channels[1] : "" }
    private var primaryDisplayName: String { displayName(for: .a) }
    private var secondaryDisplayName: String { displayName(for: .b) }

    private var primaryAccent: Color { Color(dualRGB: TwitchStreamSlot.a.darkRGB) }
    private var secondaryAccent: Color { Color(dualRGB: TwitchStreamSlot.b.darkRGB) }

    private func login(for slot: TwitchStreamSlot) -> String {
        guard slot.rawValue < channels.count else { return "" }
        return channels[slot.rawValue]
    }

    private func displayName(for slot: TwitchStreamSlot) -> String {
        let ch = login(for: slot)
        return displayNames[ch.lowercased()] ?? ch
    }

    private func displayName(for slot: TwitchDualSlot) -> String {
        displayName(for: slot.streamSlot)
    }

    private func accent(for slot: TwitchStreamSlot) -> Color {
        Color(dualRGB: slot.darkRGB)
    }

    private func accent(for slot: TwitchDualSlot) -> Color {
        accent(for: slot.streamSlot)
    }

    /// 1-letter mark per active slot, upgrading to 2 letters whenever two active display names share the same initial.
    private var resolvedMarks: [TwitchStreamSlot: String] {
        var initials: [TwitchStreamSlot: String] = [:]
        var counts: [String: Int] = [:]
        for slot in activeSlots {
            let clean = String(displayName(for: slot).filter { $0.isLetter || $0.isNumber }).uppercased()
            let first = clean.isEmpty ? slot.label : String(clean.prefix(1))
            initials[slot] = first
            counts[first, default: 0] += 1
        }
        var result: [TwitchStreamSlot: String] = [:]
        for slot in activeSlots {
            let first = initials[slot] ?? slot.label
            if (counts[first] ?? 0) > 1 {
                let clean = String(displayName(for: slot).filter { $0.isLetter || $0.isNumber }).uppercased()
                result[slot] = clean.count >= 2 ? String(clean.prefix(2)) : slot.label
            } else {
                result[slot] = first
            }
        }
        return result
    }

    private func shortMark(for slot: TwitchStreamSlot) -> String {
        resolvedMarks[slot] ?? slot.label
    }

    private func shortMark(for slot: TwitchDualSlot) -> String {
        shortMark(for: slot.streamSlot)
    }

    private var showsPauseGlyph: Bool {
        !host.userPaused && activeSlots.contains { slot in
            let st = host.slotState(for: slot)
            return st.isPlaying || st.isLoading
        }
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
            host.registerRestoreMultiHandler { chs in
                if let item = PaneItem.streams(chs) { p.open(item) }
            }
            host.claimMulti(holderID, channels: channels)
            scheduleHUDHide()
        }
        .onDisappear {
            hudHideTask?.cancel()
            hudHideTask = nil
            host.release(holderID)
        }
        .onChange(of: channels) { _, next in
            host.claimMulti(holderID, channels: next)
        }
        .onChange(of: isScrubbingAudio) { _, scrubbing in
            if scrubbing {
                hudHideTask?.cancel()
                hudVisible = true
            } else {
                scheduleHUDHide()
            }
        }
        .onChange(of: showingAudioMixerPopover) { _, open in
            if open {
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
                    title: isMulti ? Copy.Twitch.spotlightPiP : Copy.Twitch.inPiP,
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
                persistentStageCanvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct StageLayoutAnimationKey: Equatable {
        let count: Int
        let dualMode: TwitchDualStageMode
        let multiMode: TwitchMultiStageMode
        let dualFocused: TwitchDualSlot
        let spotlight: TwitchStreamSlot
        let hasVerticalCrease: Bool
        let hudVisible: Bool
    }

    private var stageLayoutAnimationKey: StageLayoutAnimationKey {
        StageLayoutAnimationKey(
            count: streamCount,
            dualMode: host.dualStageMode,
            multiMode: host.multiStageMode,
            dualFocused: mixer.focusedSlot,
            spotlight: multiMixer.spotlightSlot,
            hasVerticalCrease: hasVerticalCrease,
            hudVisible: hudVisible
        )
    }

    /// Single persistent positioned stage canvas for 2, 3, and 4 simultaneous streams.
    /// Keeping every active slot inside ONE flat `ForEach(activeSlots)` ensures toggling
    /// Spotlight <-> Grid, Focus+Inset <-> 50/50, promoting dock tiles, rotating, or adding/removing
    /// streams animates tile frames smoothly without ever destroying or reparenting
    /// `TwitchNativeSlotSurface` / `AVSampleBufferDisplayLayer` views.
    private var persistentStageCanvas: some View {
        let effectiveSize = (stageSize.width > 1 && stageSize.height > 1)
            ? stageSize
            : CGSize(width: 390, height: 390)
        let geometries = TwitchMultiLayout.stageGeometries(
            count: streamCount,
            stageSize: effectiveSize,
            dualMode: host.dualStageMode,
            multiMode: host.multiStageMode,
            dualFocused: mixer.focusedSlot,
            spotlight: multiMixer.spotlightSlot,
            hasVerticalCrease: hasVerticalCrease,
            hudVisible: hudVisible,
            compactChrome: compactChrome
        )

        return TwitchStageCanvasLayout(
            slots: activeSlots,
            count: streamCount,
            dualMode: host.dualStageMode,
            multiMode: host.multiStageMode,
            dualFocused: mixer.focusedSlot,
            spotlight: multiMixer.spotlightSlot,
            hasVerticalCrease: hasVerticalCrease,
            hudVisible: hudVisible,
            compactChrome: compactChrome
        ) {
            ForEach(activeSlots) { slot in
                let geom = geometries[slot] ?? TwitchStageTileGeometry(
                    slot: slot,
                    rect: CGRect(origin: .zero, size: effectiveSize),
                    role: .hero
                )
                persistentSlotTile(slot: slot, geometry: geom)
                    .zIndex(geom.zIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: stageLayoutAnimationKey)
    }

    /// Renders a single persistent native stream tile with its live video surface, status/error/retry overlay,
    /// corner identity badge, focus border, and role-appropriate tap target.
    private func persistentSlotTile(slot: TwitchStreamSlot, geometry: TwitchStageTileGeometry) -> some View {
        let st = host.slotState(for: slot)
        let compact = geometry.compact
        let isInset = geometry.role == .inset
        let isDock = geometry.role == .dock
        let isSplit = geometry.role == .split
        let isGrid = geometry.role == .grid
        let dualSlot: TwitchDualSlot = slot == .a ? .primary : .secondary

        let isAudible: Bool = isMulti
            ? (!host.isMuted && multiMixer.gains.gain(for: slot) > 0.05)
            : (mixer.louderSlot == dualSlot && !host.isMuted)
        let isSuspended: Bool = isMulti
            ? multiMixer.suspendedSlots.contains(slot)
            : (mixer.suspendedSlot == dualSlot)
        let isFocused: Bool = isMulti
            ? (multiMixer.spotlightSlot == slot)
            : (mixer.focusedSlot == dualSlot)

        let heroAtBottomLeading = !isMulti && host.dualStageMode == .focusInset && geometry.role == .hero
        let cornerRadius = geometry.cornerRadius
        let tileShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let borderColor: Color? = {
            if isInset { return accent(for: slot).opacity(0.85) }
            if isDock { return accent(for: slot).opacity(0.6) }
            if (isGrid || isSplit) && isFocused { return accent(for: slot).opacity(0.9) }
            return nil
        }()
        let borderWidth: CGFloat = (isGrid || isSplit) ? 2 : 1.5

        return ZStack {
            Color.black

            // Persistent native hardware-decoded video layer (never torn down across mode transitions).
            TwitchNativeSlotSurface(slot: slot, holds: holds, pipActive: host.isPiPOwningViews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mediaMask()
                .allowsHitTesting(false)

            // Role-appropriate full-tile tap catcher placed behind the Retry button and focus badge.
            tileTapSurface(slot: slot, role: geometry.role)

            // Offline / Playback Error (always shows Retry, even on compact/inset/dock tiles) / Suspended / Loading
            if st.isOffline {
                VStack(spacing: 4) {
                    Image(systemName: Symbol.Twitch.warn)
                        .font(.system(size: compact ? 13 : 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(displayName(for: slot)) · \(Copy.Twitch.offline)")
                        .font(Font.cobalt(compact ? 10 : 12, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(6)
                .allowsHitTesting(false)
            } else if st.hasPlaybackError {
                VStack(spacing: compact ? 4 : 8) {
                    Image(systemName: Symbol.Twitch.warn)
                        .font(.system(size: compact ? 13 : 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(displayName(for: slot)) · \(Copy.Twitch.streamError)")
                        .font(Font.cobalt(compact ? 10 : 12, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Button {
                        host.retrySlot(slot)
                        bumpHUD()
                    } label: {
                        Label(Copy.Twitch.retry, systemImage: Symbol.Twitch.retry)
                            .font(Font.cobalt(compact ? 10.5 : 11.5, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 10 : 12)
                            .padding(.vertical, compact ? 5 : 6)
                            .mediaGlassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Copy.Twitch.retry) \(displayName(for: slot))")
                    .accessibilityIdentifier("twitch.slot.retry.\(slot.label)")
                }
                .padding(6)
            } else if isSuspended {
                Label(Copy.Twitch.suspendedOnLock, systemImage: Symbol.Twitch.locked)
                    .font(Font.cobalt(compact ? 9.5 : 11.5, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .mediaGlassCapsule(interactive: false)
                    .allowsHitTesting(false)
            } else if st.isLoading || st.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(compact ? 0.72 : 0.95)
                    .allowsHitTesting(false)
            }

            // Corner identity badge: speaker glyph ONLY on audible stream(s); tappable in Split & Grid modes.
            VStack {
                if heroAtBottomLeading { Spacer(minLength: 0) }
                HStack(spacing: 4) {
                    persistentIdentityBadge(
                        slot: slot,
                        compact: compact,
                        isAudible: isAudible,
                        isFocused: isFocused,
                        tappable: geometry.tappableBadge
                    )
                    Spacer(minLength: 0)
                }
                if !heroAtBottomLeading { Spacer(minLength: 0) }
            }
            .padding(.horizontal, compact ? 6 : 10)
            .padding(
                .top,
                heroAtBottomLeading
                    ? 0
                    : (compact ? 6 : (showsTopChrome && (geometry.role == .hero || isSplit) ? 56 : 8))
            )
            .padding(.bottom, heroAtBottomLeading ? (hudVisible ? (compactChrome ? 62 : 74) : 14) : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hudVisible)
            .allowsHitTesting(geometry.tappableBadge)

            // Inset top-trailing swap glyph when HUD is visible
            if isInset && hudVisible {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        Image(systemName: Symbol.Twitch.swapFocus)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .mediaGlassCircle(interactive: false)
                            .padding(6)
                    }
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let borderColor {
                let strokeRadius: CGFloat = (isGrid || isSplit) ? 4 : cornerRadius
                RoundedRectangle(cornerRadius: strokeRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(tileShape)
        .shadow(color: isInset ? .black.opacity(0.45) : .clear, radius: isInset ? 10 : 0, y: isInset ? 4 : 0)
    }

    @ViewBuilder
    private func tileTapSurface(slot: TwitchStreamSlot, role: TwitchStageTileRole) -> some View {
        switch role {
        case .inset:
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    host.swapDualFocus()
                }
                bumpHUD()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(for: slot)), \(Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier("twitch.dual.inset")

        case .dock:
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    host.setSpotlight(slot)
                }
                bumpHUD()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(for: slot)), \(Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier("twitch.multi.dock.\(slot.label)")

        case .hero, .grid, .split:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleHUD()
                }
        }
    }

    @ViewBuilder
    private func persistentIdentityBadge(
        slot: TwitchStreamSlot,
        compact: Bool,
        isAudible: Bool,
        isFocused: Bool,
        tappable: Bool
    ) -> some View {
        let dualSlot: TwitchDualSlot = slot == .a ? .primary : .secondary
        let badgeBody = HStack(spacing: 5) {
            Circle()
                .fill(accent(for: slot))
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                .shadow(color: accent(for: slot).opacity(isFocused ? 0.7 : 0), radius: 3)
            Text(displayName(for: slot))
                .font(Font.cobalt(compact ? 10 : 11.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if isAudible {
                Image(systemName: Symbol.Twitch.unmuted)
                    .font(.system(size: compact ? 9 : 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(Copy.Twitch.audioMixerLabel)
            }
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3.5 : 5)
        .mediaGlassCapsule(interactive: tappable)

        if tappable {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    if isMulti {
                        host.setSpotlight(slot)
                    } else {
                        host.setDualFocus(dualSlot)
                    }
                }
                bumpHUD()
            } label: {
                badgeBody
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(for: slot)), \(isFocused ? Copy.Twitch.watchingNow : Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier(isMulti ? "twitch.multi.focus.\(slot.label)" : "twitch.dual.focus.\(dualSlot.rawValue)")
        } else {
            badgeBody
                .opacity(hudVisible || compact || isAudible ? 1 : 0)
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
        let showControls = isSeparated || hudVisible || host.isPiPActive || showingAudioMixerPopover
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
                    ForEach(Array(activeSlots.enumerated()), id: \.element.id) { index, slot in
                        if index > 0 {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Circle().fill(accent(for: slot)).frame(width: 7, height: 7)
                        if !isMulti || index < 2 {
                            Text(displayName(for: slot))
                                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    if isMulti && activeSlots.count > 2 {
                        Text("+\(activeSlots.count - 2)")
                            .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.8))
                    }
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

    /// Bottom Clear Liquid Glass control strip: Play/Pause, Audio Mixer (`A · Mix · B` for N=2; Audio Popover pill for N>=3),
    /// Focus Swap/Cycle, Layout toggle, `+` Add Stream (when < 4), PiP / Floating Window, and Stream Actions.
    private func bottomGlassHUD(isSeparated: Bool) -> some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 6) {
                // Play / Pause all streams
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

                if isMulti {
                    multiAudioMixerPill
                } else {
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
                }

                Spacer(minLength: 4)

                // Focus swap/cycle + Layout toggle + Add Stream + PiP/Floating panel in a unified glass capsule
                HStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                            if isMulti {
                                host.cycleSpotlight(forward: true)
                            } else {
                                host.swapDualFocus()
                            }
                        }
                        bumpHUD()
                    } label: {
                        Label(Copy.Twitch.swapFocus,
                              systemImage: isMulti ? Symbol.Twitch.cycleFocus : Symbol.Twitch.swapFocus)
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

                    layoutToggleButton

                    if canAddMoreStreams {
                        Button {
                            onAddStream()
                            bumpHUD()
                        } label: {
                            Label(Copy.Twitch.addStreamTitle(current: streamCount, max: PaneItem.maxSimultaneousStreams),
                                  systemImage: Symbol.Twitch.addStream)
                                .labelStyle(.iconOnly)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: Metrics.hit, height: Metrics.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Copy.Twitch.addStreamTitle(current: streamCount, max: PaneItem.maxSimultaneousStreams))
                        .accessibilityIdentifier("twitch.multi.addStream")
                        .help(Copy.Twitch.addStreamTitle(current: streamCount, max: PaneItem.maxSimultaneousStreams))
                    }

                    if host.canTogglePiP {
                        Button {
                            host.togglePiP()
                            bumpHUD()
                        } label: {
                            #if os(iOS)
                            let icon = host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.pipEnter
                            let label = host.isPiPActive ? Copy.Twitch.pipExit : (isMulti ? Copy.Twitch.spotlightPiP : Copy.Twitch.dualPiP)
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
                        .accessibilityLabel(host.isPiPActive ? Copy.Twitch.pipExit : (isMulti ? Copy.Twitch.spotlightPiP : Copy.Twitch.dualPiP))
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

    private var layoutToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                if isMulti {
                    host.toggleMultiStageMode()
                } else {
                    host.toggleDualStageMode()
                }
            }
            bumpHUD()
        } label: {
            let symbol: String
            let label: String
            if isMulti {
                if host.multiStageMode == .spotlight {
                    symbol = streamCount == 4 ? Symbol.Twitch.quadGrid : Symbol.Twitch.mosaicGrid
                    label = Copy.Twitch.gridLayout
                } else {
                    symbol = Symbol.Twitch.spotlightStrip
                    label = Copy.Twitch.spotlightLayout
                }
            } else {
                let nextIsSplit = host.dualStageMode == .focusInset
                let splitSymbol = TwitchDualLayout.splitAxis(for: stageSize) == .horizontal
                    ? Symbol.Twitch.splitLayoutHorizontal
                    : Symbol.Twitch.splitLayoutVertical
                symbol = nextIsSplit ? splitSymbol : Symbol.Twitch.focusLayout
                label = nextIsSplit ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset
            }
            return Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMulti
            ? (host.multiStageMode == .spotlight ? Copy.Twitch.gridLayout : Copy.Twitch.spotlightLayout)
            : (host.dualStageMode == .focusInset ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset))
        .accessibilityIdentifier("twitch.dual.layoutToggle")
    }

    /// Compact >= 44 pt Audio Mixer pill for 3–4 streams; taps open the per-stream equal-power mixer popover.
    private var multiAudioMixerPill: some View {
        let audibleSlots = activeSlots.filter { multiMixer.gains.gain(for: $0) > 0.05 }
        let pillText: String = {
            if host.isMuted { return Copy.Twitch.mute }
            if audibleSlots.count == streamCount { return Copy.Twitch.audioMix }
            if audibleSlots.count == 1, let only = audibleSlots.first {
                return shortMark(for: only)
            }
            return "\(audibleSlots.count)/\(streamCount)"
        }()

        return HStack(spacing: 4) {
            Button {
                showingAudioMixerPopover.toggle()
                bumpHUD()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: host.isMuted ? Symbol.Twitch.muted : Symbol.Twitch.audioMixer)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 3) {
                        ForEach(audibleSlots) { slot in
                            Circle()
                                .fill(accent(for: slot))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(pillText)
                        .font(Font.cobalt(12, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if multiMixer.isPinned {
                        Image(systemName: Symbol.Twitch.pinFill)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .mediaGlassCapsule()
            .accessibilityLabel(Copy.Twitch.audioMixerLabel)
            .accessibilityIdentifier("twitch.multi.mixer")
            .popover(isPresented: $showingAudioMixerPopover, arrowEdge: .bottom) {
                TwitchMultiAudioMixerPopover(
                    mixer: multiMixer,
                    slots: activeSlots,
                    displayNameForSlot: displayName(for:),
                    accentForSlot: accent(for:),
                    isMuted: host.isMuted,
                    onToggleMute: { host.toggleMute() }
                )
                .presentationCompactAdaptation(.popover)
            }

            if multiMixer.isPinned {
                Button {
                    multiMixer.followSpotlight()
                    bumpHUD()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Symbol.Twitch.pinFill)
                            .font(.system(size: 11, weight: .semibold))
                        Text(Copy.Twitch.audioUnpin)
                            .font(Font.cobalt(11, .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .mediaGlassCapsule()
                .accessibilityLabel("\(Copy.Twitch.audioPinned), \(Copy.Twitch.audioUnpin)")
                .accessibilityIdentifier("twitch.multi.unpinAudio")
            }
        }
    }

    private var streamManagementMenu: some View {
        Menu {
            if canAddMoreStreams {
                Button(
                    Copy.Twitch.addStreamTitle(current: streamCount, max: PaneItem.maxSimultaneousStreams),
                    systemImage: Symbol.Twitch.addStream,
                    action: onAddStream
                )
            }
            if !isMulti {
                Button(Copy.Twitch.swapSecondStream, systemImage: Symbol.Twitch.swapFocus, action: onSwitchSecondStream)
            }
            Divider()
            if isMulti {
                ForEach(activeSlots) { slot in
                    let ch = login(for: slot)
                    let name = displayName(for: slot)
                    Button(Copy.Twitch.dropStream(name), systemImage: Symbol.Twitch.dropStream) {
                        onRemoveStream(ch)
                    }
                }
                Divider()
            }
            ForEach(activeSlots) { slot in
                let ch = login(for: slot)
                let name = displayName(for: slot)
                Button(Copy.Twitch.keepOnly(name), systemImage: Symbol.Twitch.focusLayout) {
                    onKeepOnly(ch)
                }
            }
            Divider()
            ForEach(activeSlots) { slot in
                let st = host.slotState(for: slot)
                if !st.variants.isEmpty {
                    Menu("\(displayName(for: slot)) · \(Copy.Twitch.quality)") {
                        ForEach(st.variants) { variant in
                            Button {
                                host.selectVariant(variant.id, for: slot)
                            } label: {
                                if variant.id == st.selectedVariantID {
                                    Label(variant.shortLabel, systemImage: "checkmark")
                                } else {
                                    Text(variant.shortLabel)
                                }
                            }
                        }
                    }
                }
            }
            if isMulti && host.hasManualQualityOverrides {
                Button(Copy.Twitch.qualityResetAuto, systemImage: Symbol.Twitch.quality) {
                    host.resetAutoQuality()
                }
            }
            Divider()
            ForEach(activeSlots) { slot in
                let ch = login(for: slot)
                let name = displayName(for: slot)
                Button("\(Copy.Twitch.openOnTwitch) (\(name))", systemImage: Symbol.Twitch.open) {
                    onOpenOnTwitch(ch)
                }
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
            guard !Task.isCancelled, !isScrubbingAudio, !showingAudioMixerPopover, !host.userPaused else { return }
            hudVisible = false
        }
    }
}

// MARK: - Multi-Stream Equal-Power Audio Mixer Popover (N = 3 & 4)

private struct TwitchMultiAudioMixerPopover: View {
    let mixer: TwitchMultiAudioMixer
    let slots: [TwitchStreamSlot]
    let displayNameForSlot: (TwitchStreamSlot) -> String
    let accentForSlot: (TwitchStreamSlot) -> Color
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Copy.Twitch.audioMixerTitle)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                Spacer(minLength: 4)
                Button(action: onToggleMute) {
                    Image(systemName: isMuted ? Symbol.Twitch.muted : Symbol.Twitch.unmuted)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(isMuted ? Copy.Twitch.unmute : Copy.Twitch.mute)
            }

            HStack(spacing: 8) {
                let isFollowing = !mixer.isPinned
                Button {
                    mixer.followSpotlight()
                } label: {
                    Label(Copy.Twitch.audioUnpin, systemImage: isFollowing ? "checkmark" : Symbol.Twitch.spotlightStrip)
                        .font(Font.cobalt(12, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glass)
                .tint(isFollowing ? TwitchChatPalette.twitch : nil)

                let isMixAll = mixer.activeAudioSlots.count == slots.count
                Button {
                    mixer.mixAll()
                } label: {
                    Label(Copy.Twitch.mixAll, systemImage: Symbol.Twitch.audioMixer)
                        .font(Font.cobalt(12, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glass)
                .tint(isMixAll ? TwitchChatPalette.twitch : nil)
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(slots) { slot in
                    let weight = mixer.slotWeight(for: slot)
                    let isAudible = weight > 0.05
                    let accent = accentForSlot(slot)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button {
                                mixer.toggleAudio(for: slot)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(accent)
                                        .frame(width: 8, height: 8)
                                    Text(displayNameForSlot(slot))
                                        .font(Font.cobalt(13, .semibold))
                                        .foregroundStyle(isAudible ? CobaltColor.text : CobaltColor.caption)
                                        .lineLimit(1)
                                }
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 4)

                            Button {
                                mixer.solo(slot)
                            } label: {
                                Text(Copy.Twitch.solo)
                                    .font(Font.cobalt(11, .semibold))
                                    .foregroundStyle(mixer.activeAudioSlots == [slot] ? .white : CobaltColor.caption)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 28)
                                    .background(
                                        mixer.activeAudioSlots == [slot] ? accent.opacity(0.85) : CobaltColor.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Slider(
                            value: Binding(
                                get: { mixer.slotWeight(for: slot) },
                                set: { mixer.setVolume(for: slot, to: $0) }
                            ),
                            in: 0...1
                        )
                        .tint(accent)
                        .accessibilityLabel("\(displayNameForSlot(slot)) volume")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
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

// MARK: - Persistent Stage Layout

/// Positions persistent multi-stream tiles (`ForEach(activeSlots)`) using exact `TwitchMultiLayout.stageGeometries`
/// rects so mode transitions (Spotlight <-> Grid, Focus+Inset <-> 50/50, dock tap, rotation) animate frame changes
/// without ever destroying or reparenting `TwitchNativeSlotSurface` video layers.
private struct TwitchStageCanvasLayout: Layout {
    let slots: [TwitchStreamSlot]
    let count: Int
    let dualMode: TwitchDualStageMode
    let multiMode: TwitchMultiStageMode
    let dualFocused: TwitchDualSlot
    let spotlight: TwitchStreamSlot
    let hasVerticalCrease: Bool
    let hudVisible: Bool
    let compactChrome: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let geometries = TwitchMultiLayout.stageGeometries(
            count: count,
            stageSize: bounds.size,
            dualMode: dualMode,
            multiMode: multiMode,
            dualFocused: dualFocused,
            spotlight: spotlight,
            hasVerticalCrease: hasVerticalCrease,
            hudVisible: hudVisible,
            compactChrome: compactChrome
        )
        for (index, subview) in subviews.enumerated() where index < slots.count {
            let slot = slots[index]
            let rect = geometries[slot]?.rect ?? CGRect(origin: .zero, size: bounds.size)
            subview.place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: rect.width, height: rect.height)
            )
        }
    }
}

// MARK: - Accent Helper

extension Color {
    init(dualRGB rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
