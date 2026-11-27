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
            } else if isMulti {
                switch host.multiStageMode {
                case .spotlight:
                    multiSpotlightCanvas
                case .grid:
                    multiGridCanvas
                }
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

    // MARK: - N = 3 & N = 4 Canvases

    /// Spotlight mode for 3–4 streams: spotlight hero fills the primary zone; the remaining 2–3 streams sit in
    /// a live dock (trailing strip on wide/landscape screens, bottom strip on tall/portrait screens).
    private var multiSpotlightCanvas: some View {
        let dock = TwitchMultiLayout.spotlightDock(
            count: streamCount,
            stageSize: stageSize,
            hasVerticalCrease: hasVerticalCrease
        )
        let heroFraction = TwitchMultiLayout.spotlightHeroFraction(
            count: streamCount,
            dock: dock,
            hasVerticalCrease: hasVerticalCrease
        )
        let spotlight = multiMixer.spotlightSlot
        let dockSlots = activeSlots.filter { $0 != spotlight }
        let bottomReserve: CGFloat = (dock == .bottomRow && hudVisible) ? (compactChrome ? 58 : 68) : 0

        return GeometryReader { geo in
            if dock == .trailingColumn {
                let heroW = max(160, geo.size.width * heroFraction)
                HStack(spacing: 2) {
                    multiHeroTile(slot: spotlight)
                        .frame(width: heroW, height: geo.size.height)

                    VStack(spacing: 2) {
                        ForEach(dockSlots) { slot in
                            multiDockTile(slot: slot)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                let usableH = max(120, geo.size.height - bottomReserve)
                let heroH = max(100, usableH * heroFraction)
                VStack(spacing: 2) {
                    multiHeroTile(slot: spotlight)
                        .frame(width: geo.size.width, height: heroH)

                    HStack(spacing: 2) {
                        ForEach(dockSlots) { slot in
                            multiDockTile(slot: slot)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, bottomReserve)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Grid mode for 3–4 streams:
    /// - 3 streams + vertical Duo crease -> 50/50 fold-safe split (1 left + 2 stacked right).
    /// - 3 streams flat -> 1 + 2 mosaic (hero left/top + 2 secondary right/bottom).
    /// - 4 streams -> clean 2×2 quad grid (naturally fold-safe on both vertical and horizontal creases).
    @ViewBuilder
    private var multiGridCanvas: some View {
        let kind = TwitchMultiLayout.gridKind(
            count: streamCount,
            stageSize: stageSize,
            hasVerticalCrease: hasVerticalCrease
        )
        let spotlight = multiMixer.spotlightSlot
        let others = activeSlots.filter { $0 != spotlight }

        switch kind {
        case .duoFoldSafeThree:
            HStack(spacing: 2) {
                multiGridTile(slot: spotlight)
                VStack(spacing: 2) {
                    ForEach(others) { slot in
                        multiGridTile(slot: slot)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .mosaicThree:
            GeometryReader { geo in
                if geo.size.width >= geo.size.height {
                    let leftW = geo.size.width * 0.62
                    HStack(spacing: 2) {
                        multiGridTile(slot: spotlight)
                            .frame(width: leftW, height: geo.size.height)
                        VStack(spacing: 2) {
                            ForEach(others) { slot in
                                multiGridTile(slot: slot)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    let topH = geo.size.height * 0.56
                    VStack(spacing: 2) {
                        multiGridTile(slot: spotlight)
                            .frame(width: geo.size.width, height: topH)
                        HStack(spacing: 2) {
                            ForEach(others) { slot in
                                multiGridTile(slot: slot)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .quadGrid:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    multiGridTile(slot: .a)
                    multiGridTile(slot: .b)
                }
                HStack(spacing: 2) {
                    multiGridTile(slot: .c)
                    multiGridTile(slot: .d)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .splitHorizontal:
            HStack(spacing: 2) {
                ForEach(activeSlots) { slot in
                    multiGridTile(slot: slot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .splitVertical:
            VStack(spacing: 2) {
                ForEach(activeSlots) { slot in
                    multiGridTile(slot: slot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func multiHeroTile(slot: TwitchStreamSlot) -> some View {
        multiSlotTile(slot: slot, compact: false, tappableBadge: false)
            .contentShape(Rectangle())
            .onTapGesture {
                toggleHUD()
            }
            .clipped()
    }

    private func multiDockTile(slot: TwitchStreamSlot) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                host.setSpotlight(slot)
            }
            bumpHUD()
        } label: {
            multiSlotTile(slot: slot, compact: true, tappableBadge: false)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(accent(for: slot).opacity(0.6), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("\(displayName(for: slot)), \(Copy.Twitch.tapToFocus)")
        .accessibilityIdentifier("twitch.multi.dock.\(slot.label)")
    }

    private func multiGridTile(slot: TwitchStreamSlot) -> some View {
        let isSpotlight = multiMixer.spotlightSlot == slot
        return ZStack {
            multiSlotTile(slot: slot, compact: streamCount == 4 && stageSize.width < 600, tappableBadge: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleHUD()
                }
            if isSpotlight {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(accent(for: slot).opacity(0.9), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func multiSlotTile(slot: TwitchStreamSlot, compact: Bool, tappableBadge: Bool) -> some View {
        let st = host.slotState(for: slot)
        let isAudible = !host.isMuted && multiMixer.gains.gain(for: slot) > 0.05
        let isSuspended = multiMixer.suspendedSlots.contains(slot)
        let isSpotlight = multiMixer.spotlightSlot == slot

        return ZStack {
            Color.black
            TwitchNativeSlotSurface(slot: slot, holds: holds, pipActive: host.isPiPOwningViews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mediaMask()
                .allowsHitTesting(false)

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
            } else if isSuspended {
                Label(Copy.Twitch.suspendedOnLock, systemImage: Symbol.Twitch.locked)
                    .font(Font.cobalt(compact ? 9.5 : 11.5, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .mediaGlassCapsule(interactive: false)
            } else if st.isLoading || st.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(compact ? 0.72 : 0.95)
            }

            VStack {
                HStack(spacing: 4) {
                    multiSlotIdentityBadge(
                        slot: slot,
                        compact: compact,
                        isAudible: isAudible,
                        isSpotlight: isSpotlight,
                        tappable: tappableBadge
                    )
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 6 : (showsTopChrome && !compact && host.multiStageMode == .spotlight ? 56 : 8))
            .allowsHitTesting(tappableBadge)
        }
    }

    @ViewBuilder
    private func multiSlotIdentityBadge(
        slot: TwitchStreamSlot,
        compact: Bool,
        isAudible: Bool,
        isSpotlight: Bool,
        tappable: Bool
    ) -> some View {
        let badgeBody = HStack(spacing: 5) {
            Circle()
                .fill(accent(for: slot))
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
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
                    host.setSpotlight(slot)
                }
                bumpHUD()
            } label: {
                badgeBody
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(for: slot)), \(isSpotlight ? Copy.Twitch.watchingNow : Copy.Twitch.tapToFocus)")
            .accessibilityIdentifier("twitch.multi.focus.\(slot.label)")
        } else {
            badgeBody
                .opacity(hudVisible || compact || isAudible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hudVisible)
        }
    }

    // MARK: - N = 2 Canvases (Focus+Inset & 50/50)

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

        return ZStack {
            Color.black
            TwitchNativeSlotSurface(slot: slot, holds: holds, pipActive: host.isPiPOwningViews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mediaMask()
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
            VStack {
                HStack(spacing: 4) {
                    slotIdentityBadge(slot: slot, isInset: isInset, isLouder: isLouder, isFocused: isFocused)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(isInset ? 6 : (showsTopChrome && !isInset && host.dualStageMode == .focusInset ? 56 : 10))
            .allowsHitTesting(host.dualStageMode == .split5050 && !isInset)
        }
    }

    @ViewBuilder
    private func slotIdentityBadge(slot: TwitchDualSlot, isInset: Bool, isLouder: Bool, isFocused: Bool) -> some View {
        let badgeBody = HStack(spacing: 5) {
            Circle()
                .fill(accent(for: slot))
                .frame(width: isInset ? 6 : 7, height: isInset ? 6 : 7)
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
        let showControls = isSeparated || hudVisible || host.isPiPActive || showingAudioMixerPopover
        ZStack {
            if !isSeparated && showControls {
                VStack(spacing: 0) {
                    if showsTopChrome {
                        MediaEdgeVignette(edge: .top, height: compactChrome ? 72 : 92, intensity: 0.46)
                    }
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
                let trackW = max(controlWidth - 8, 120)
                let thumbW = max(trackW / 3.0, 40)
                let offsetX = CGFloat(mixer.balance) * (trackW - thumbW)
                Capsule()
                    .fill(thumbTint.opacity(isMuted ? 0.16 : 0.34))
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
            .frame(minWidth: 148, maxWidth: 184, minHeight: Metrics.hit)
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
                    .padding(.horizontal, 10)
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

extension Color {
    init(dualRGB rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
