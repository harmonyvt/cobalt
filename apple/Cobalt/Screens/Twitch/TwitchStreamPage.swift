import CobaltKit
import SwiftUI

// A twitch stream (or dual-stream) in the screen pane (apple/CONTRACT-PANE.md section 5; APP-API-CONTRACT 70).
//
// Single-stream and dual-stream share one consistent watch surface across every posture:
//   1. the video / TV stage (`TwitchPlayer` or `TwitchTVCard` for single; `TwitchDualStage` for dual),
//   2. the unified stream bar (single-stream wide/stacked when not condensed) or Clear Liquid Glass HUD,
//   3. full-height edge-to-edge live chat (`TwitchChatCard` -> single chat or `TwitchCombinedChatModel` in dual mode,
//      zero nested scroll views, composer pinned at the bottom and guaranteed below the crease in Tabletop).
//
// Promotion `.stream(a)` -> `.dualStream(a, b)` and demotion `.dualStream(a, b)` -> `.stream(a)` preserve
// `TwitchPlayerHost.shared`'s live `AVSampleBufferDisplayLayer` and `TwitchStore`'s chat engine with zero black flash.

struct TwitchStreamPage: View {
    let channels: [String]
    let model: AppModel

    init(channels: [String], model: AppModel) {
        var seen = Set<String>()
        var normalized: [String] = []
        for ch in channels {
            let trimmed = ch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                normalized.append(trimmed)
                if normalized.count == PaneItem.maxSimultaneousStreams { break }
            }
        }
        self.channels = normalized.isEmpty ? [""] : normalized
        self.model = model
    }

    init(login: String, secondaryLogin: String? = nil, model: AppModel) {
        if let secondaryLogin {
            self.init(channels: [login, secondaryLogin], model: model)
        } else {
            self.init(channels: [login], model: model)
        }
    }

    private enum StreamPickerMode: Identifiable {
        case add
        case replaceSecond
        var id: Int { self == .add ? 0 : 1 }
    }

    @Environment(Pane.self) private var pane
    @Environment(\.paneItem) private var paneItem
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHinge) private var hinge
    @Environment(\.paneReservedRegions) private var reservedRegions
    @Environment(\.paneHostSize) private var hostSize
    @Environment(\.paneOffline) private var offline
    @Environment(\.openURL) private var openURL
    @Environment(\.lifecycle) private var lifecycle
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingTV = false
    @State private var streamPickerMode: StreamPickerMode?
    @State private var containerSize: CGSize = .zero

    private var store: TwitchStore { model.twitch }
    private var host: TwitchPlayerHost { .shared }
    private var login: String { channels.first ?? "" }
    private var isDualStream: Bool { channels.count >= 2 }
    private var isMultiStream: Bool { channels.count >= 3 }
    private var canAddMoreStreams: Bool { channels.count < PaneItem.maxSimultaneousStreams }

    private var item: PaneItem {
        PaneItem.streams(channels) ?? .stream(login)
    }

    private var sessionKey: String {
        channels.joined(separator: "|")
    }

    /// The store holds this primary channel (not the one before it, while a new one opens).
    private var holdsChannel: Bool { store.channel == login }
    private var isLive: Bool {
        if isDualStream {
            return holdsChannel && channels.contains { store.streamInfo(for: $0) != nil }
        }
        return holdsChannel && store.stream != nil
    }

    /// True in single-focus iOS/Duo mode when this page owns its full-bleed Clear Liquid Glass watch stage + system toolbar.
    private var ownsGlassHUD: Bool { !pane.sitsBesideTab && shape != .bar }

    /// Pure-SwiftUI keyboard detection comparing keyboard-ignored `paneHostSize` against the live container height.
    private var keyboardOpen: Bool {
        #if os(iOS)
        return hostSize.height > 0 && containerSize.height > 0 && (hostSize.height - containerSize.height) >= 120
        #else
        return false
        #endif
    }

    private var activeFoldAxis: Axis? {
        if let div = reservedRegions.activeDivision {
            return div.width > div.height ? .vertical : .horizontal
        }
        if case .split = shape, let hinge {
            return hinge.axis == .horizontal ? .vertical : .horizontal
        }
        return nil
    }

    private var showsPauseGlyph: Bool {
        if isDualStream {
            return !host.userPaused && TwitchStreamSlot.slots(forCount: channels.count).contains { slot in
                let st = host.slotState(for: slot)
                return st.isPlaying || st.isLoading
            }
        }
        return host.isPlaying
    }

    var body: some View {
        Group {
            switch shape {
            case .bar:
                bar
            case .split, .tall, .wide:
                adaptiveWatch
            }
        }
        .preference(key: PaneMoreKey.self, value: moreActions)
        .preference(key: PaneFloatingHeaderKey.self, value: false)
        .preference(key: PaneHidesChromeHeaderKey.self, value: ownsGlassHUD)
        .preference(key: PaneShowsSystemToolbarKey.self, value: ownsGlassHUD)
        .toolbar {
            if ownsGlassHUD {
                watchToolbar
            }
        }
        .duoToolbarCompression(.prefersToolbarItems)
        .onChange(of: title, initial: true) { pane.reportTitle(title, for: paneItem) }
        .onAppear {
            syncWatchSession()
        }
        .onChange(of: sessionKey) { _, _ in
            syncWatchSession()
        }
        .onChange(of: host.focusedChannel) { _, focused in
            if isDualStream, let focused {
                store.updateCombinedChatFocus(focused)
            }
        }
        .onChange(of: store.channel) { _, channel in
            // closed from somewhere else: nothing is playing any more
            if channel != login, pane.item == item {
                pane.setRunning(false, for: item)
            }
        }
        .task { if model.sevenTv.status == nil { await model.sevenTv.load() } }
        // back from studio (a reconnect) or from the background: a session that could not chat is asked again
        .onChange(of: lifecycle.phase) { _, phase in
            if phase == .active { Task { await store.load() } }
        }
        .sheet(item: $streamPickerMode) { mode in
            let sheetTitle: String = switch mode {
            case .add:
                isDualStream
                    ? Copy.Twitch.addStreamTitle(current: channels.count, max: PaneItem.maxSimultaneousStreams)
                    : Copy.Twitch.pickSecondStreamTitle
            case .replaceSecond:
                Copy.Twitch.swapSecondStream
            }
            let excluded: Set<String> = switch mode {
            case .add:
                Set(channels.map { $0.lowercased() })
            case .replaceSecond:
                Set([login.lowercased()])
            }
            TwitchAddSecondStreamSheet(
                model: model,
                excluding: excluded,
                title: sheetTitle
            ) { picked in
                switch mode {
                case .add:
                    addStream(picked)
                case .replaceSecond:
                    replaceSecondStream(with: picked)
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        #if os(iOS)
        // The TV (70.5): while this page is up (single-stream), a mirrored screen shows capystore's own window.
        .background(TwitchTVAccessory(enabled: !isDualStream && TwitchTV.shared.wanted).frame(width: 0, height: 0))
        .onChange(of: login) { TwitchTV.shared.refresh() }
        .sheet(isPresented: $choosingTV) {
            TwitchTVSheet().presentationDetents([.medium, .large])
        }
        #endif
    }

    /// Synchronizes `TwitchStore` and `PaneKeepAlive` for 1...4 streams without dropping surviving live channels.
    private func syncWatchSession() {
        if channels.count >= 2 {
            store.openMulti(
                channels: channels,
                focusedChannel: host.focusedChannel ?? login
            )
        } else {
            store.open(login)
        }
        pane.setRunning(true, for: item)
        if pane.holds(item) {
            pane.keepAlive("stream", for: item) {
                TwitchWatch(channels: channels, model: model, pane: pane)
            }.begin()
        }
    }

    // MARK: - Rule 15 System Toolbar (iPhone Duo Vertical Rail + Tabletop Top Bar)

    @ToolbarContentBuilder
    private var watchToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            DuoToolbarButton(title: Copy.close, systemImage: "chevron.backward") {
                pane.close()
            }
            .accessibilityIdentifier("pane.close")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .primaryAction) {
            DuoToolbarButton(
                title: showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play,
                systemImage: showsPauseGlyph ? "pause.fill" : "play.fill"
            ) {
                host.setPaused(showsPauseGlyph)
            }
            .accessibilityIdentifier("twitch.toolbar.playpause")
        }
        .duoVisibilityPriority(.high)

        if host.canTogglePiP {
            ToolbarItem(placement: .automatic) {
                DuoToolbarButton(
                    title: host.isPiPActive
                        ? Copy.Twitch.pipExit
                        : (isMultiStream ? Copy.Twitch.spotlightPiP : (isDualStream ? Copy.Twitch.dualPiP : Copy.Twitch.pipEnter)),
                    systemImage: host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.pipEnter
                ) {
                    host.togglePiP()
                }
                .accessibilityIdentifier("twitch.toolbar.pip")
            }
            .duoVisibilityPriority(.high)
        }

        if canAddMoreStreams {
            ToolbarItem(placement: .automatic) {
                DuoToolbarButton(
                    title: isDualStream
                        ? Copy.Twitch.addStreamTitle(current: channels.count, max: PaneItem.maxSimultaneousStreams)
                        : Copy.Twitch.addSecondStream,
                    systemImage: Symbol.Twitch.addStream
                ) {
                    streamPickerMode = .add
                }
                .accessibilityIdentifier("twitch.toolbar.addSecondStream")
            }
            .duoVisibilityPriority(.automatic)
        }

        if store.canClip {
            ToolbarItem(placement: .automatic) {
                DuoToolbarButton(title: Copy.Twitch.clip, systemImage: Symbol.Twitch.clip) {
                    makeClip()
                }
                .disabled(offline || store.clipState == .making)
                .accessibilityIdentifier("twitch.toolbar.clip")
            }
            .duoVisibilityPriority(.low)
        }

        DuoOverflowToolbarMenu(Copy.Media.more) {
            if isDualStream {
                Button(Copy.Twitch.swapFocus, systemImage: isMultiStream ? Symbol.Twitch.cycleFocus : Symbol.Twitch.swapFocus) {
                    if isMultiStream {
                        host.cycleSpotlight(forward: true)
                    } else {
                        host.swapDualFocus()
                    }
                }
                if isMultiStream {
                    Button(
                        host.multiStageMode == .spotlight ? Copy.Twitch.gridLayout : Copy.Twitch.spotlightLayout,
                        systemImage: host.multiStageMode == .spotlight
                            ? (channels.count == 4 ? Symbol.Twitch.quadGrid : Symbol.Twitch.mosaicGrid)
                            : Symbol.Twitch.spotlightStrip
                    ) {
                        host.toggleMultiStageMode()
                    }
                } else {
                    Button(
                        host.dualStageMode == .focusInset ? Copy.Twitch.dualSplit5050 : Copy.Twitch.dualFocusInset,
                        systemImage: host.dualStageMode == .focusInset ? Symbol.Twitch.splitLayoutHorizontal : Symbol.Twitch.focusLayout
                    ) {
                        host.toggleDualStageMode()
                    }
                    Button(Copy.Twitch.swapSecondStream, systemImage: Symbol.Twitch.addStream) {
                        streamPickerMode = .replaceSecond
                    }
                }
                Divider()
                if isMultiStream {
                    ForEach(channels, id: \.self) { ch in
                        Button(Copy.Twitch.dropStream(store.displayName(for: ch)), systemImage: Symbol.Twitch.dropStream) {
                            removeStream(ch)
                        }
                    }
                    Divider()
                }
                ForEach(channels, id: \.self) { ch in
                    Button(Copy.Twitch.keepOnly(store.displayName(for: ch)), systemImage: Symbol.Twitch.focusLayout) {
                        keepOnly(ch)
                    }
                }
                Divider()
                ForEach(channels, id: \.self) { ch in
                    Button("\(Copy.Twitch.openOnTwitch) (\(store.displayName(for: ch)))", systemImage: Symbol.Twitch.open) {
                        openChannelOnTwitch(ch)
                    }
                }
            } else {
                #if os(iOS)
                Button(Copy.Twitch.watchOnTV, systemImage: Symbol.Twitch.tv) {
                    choosingTV = true
                }
                #endif
                Button(
                    host.activeMode == .lowLatency ? Copy.Twitch.playerEmbed : Copy.Twitch.playerLowLatency,
                    systemImage: host.activeMode == .lowLatency ? Symbol.Twitch.embed : Symbol.Twitch.lowLatency
                ) {
                    host.setMode(host.activeMode == .lowLatency ? .embed : .lowLatency)
                }
                Button(Copy.Twitch.jumpToLive, systemImage: Symbol.Twitch.jumpToLive) {
                    host.jumpToLive()
                }
                .disabled(host.delay == nil || host.isCatchingUp)
                Button(Copy.Twitch.openOnTwitch, systemImage: Symbol.Twitch.open) {
                    openChannelOnTwitch(login)
                }
            }
            Divider()
            Button(Copy.Twitch.stop, systemImage: "stop.fill", role: .destructive) {
                stop()
            }
        }
    }

    // MARK: layouts

    /// Posture-adaptive watch canvas:
    /// - Half-Closed Tabletop (horizontal crease): video stage above the crease, chat + composer + keyboard strictly below `.division`.
    /// - Book Crease (vertical crease): video stage left of crease, live chat right of crease.
    /// - Unfolded Wide / Landscape: ~62% video stage left, ~38% full-height chat right.
    /// - Folded / Tall: stacked video + chat, condensing stage cleanly when keyboard opens.
    private var adaptiveWatch: some View {
        Group {
            if activeFoldAxis == .vertical {
                // Half-Closed Tabletop: video stage above the crease, chat + composer + keyboard strictly below the crease.
                DuoSplit(ratio: keyboardOpen ? 0.42 : 0.5, axes: .vertical) {
                    videoStage(compactControls: true, maxHeight: nil)
                } secondary: {
                    chatPanel
                }
            } else if activeFoldAxis == .horizontal {
                // Book Crease: video + controls on the leading half, full-height chat on the trailing half.
                DuoSplit(ratio: 0.5, axes: .horizontal) {
                    mediaPanel(condensed: isDualStream || (keyboardOpen && containerSize.height < 360))
                } secondary: {
                    chatPanel
                }
            } else {
                flatWatchLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: keyboardOpen)
        .task(id: store.clipState) { await clearClipStateSoon() }
    }

    @ViewBuilder
    private var flatWatchLayout: some View {
        let baseLayout = TwitchWatchLayout.resolve(
            isWideShape: shape == .wide || (!pane.sitsBesideTab && containerSize.width >= TwitchWatchLayout.sideBySideMinWidth),
            size: containerSize
        )
        let isSideBySide: Bool = {
            if case .sideBySide = baseLayout { return true }
            return false
        }()
        let chatWidth = !pane.sitsBesideTab
            ? TwitchWatchLayout.singleFocusChatWidth(for: containerSize.width)
            : TwitchWatchLayout.chatWidth(for: containerSize.width)
        let condensed = isSideBySide
            ? (isDualStream || (keyboardOpen && containerSize.height < 360))
            : (isDualStream || TwitchWatchLayout.compactOverlayStreamBar(
                isStacked: true,
                isTabletop: false,
                keyboardOpen: keyboardOpen
            ))
        let maxH = isSideBySide ? nil : stackedStageMaxHeight
        let layout = isSideBySide
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))

        // Keeping a single structural tree under `AnyLayout` preserves `TwitchDualStage`, `TwitchPlayer`,
        // and `chatPanel` identity across portrait/landscape rotations with zero black flash or chat teardown.
        layout {
            VStack(spacing: 0) {
                videoStage(compactControls: condensed, maxHeight: maxH)
                if !condensed {
                    if isSideBySide {
                        hairline(horizontal: true)
                    }
                    streamBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isSideBySide ? .infinity : nil)

            hairline(horizontal: !isSideBySide)

            chatPanel
                .frame(width: isSideBySide ? chatWidth : nil)
                .frame(maxWidth: isSideBySide ? nil : .infinity, maxHeight: .infinity)
        }
    }

    /// Stage height cap in stacked portrait: gives 50/50 dual-stream and 3–4 stream Spotlight/Grid enough room when
    /// keyboard is closed, while preserving the Keyboard-Open Guarantee (chat + composer always visible).
    private var stackedStageMaxHeight: CGFloat? {
        if isMultiStream && !keyboardOpen && containerSize.height > 0 {
            return max(260, min(containerSize.height * 0.50, 460))
        }
        if isDualStream && !keyboardOpen && host.dualStageMode == .split5050 && containerSize.height > 0 {
            return max(260, min(containerSize.height * 0.52, 460))
        }
        return TwitchWatchLayout.stackedVideoMaxHeight(for: containerSize, keyboardOpen: keyboardOpen)
    }

    /// Media half for wide side-by-side and book-crease layouts: full-area video stage with optional docked stream bar.
    private func mediaPanel(condensed: Bool) -> some View {
        VStack(spacing: 0) {
            videoStage(compactControls: condensed, maxHeight: nil)
            if !condensed {
                hairline(horizontal: true)
                streamBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var streamBar: some View {
        TwitchStreamBar(
            title: title, subtitle: subtitle, isLive: isLive,
            clipNote: clipText, clipFailed: store.clipState == .failed,
            isPlaying: host.isPlaying,
            jumpDisabled: host.delay == nil || host.isCatchingUp,
            isCatchingUp: host.isCatchingUp,
            canClip: store.canClip, clipState: store.clipState, offline: offline,
            onTV: onTV,
            onPlayPause: { host.setPaused(host.isPlaying) },
            onJumpToLive: { host.jumpToLive() },
            onAddSecondStream: { streamPickerMode = .add },
            onClip: makeClip,
            onTVTap: { choosingTV = true },
            onStop: stop)
    }

    /// Video / TV stage (single-stream `TwitchPlayer` or multi-stream `TwitchDualStage`).
    @ViewBuilder
    private func videoStage(compactControls: Bool, maxHeight: CGFloat?) -> some View {
        if isDualStream {
            let namesMap = Dictionary(uniqueKeysWithValues: channels.map { ($0.lowercased(), store.displayName(for: $0)) })
            let stageHasVerticalCrease = activeFoldAxis == nil
                && (reservedRegions.activeDivision.map { $0.height > $0.width } ?? false)
            TwitchDualStage(
                channels: channels,
                displayNames: namesMap,
                showsTopChrome: false,
                compactChrome: compactControls,
                hasVerticalCrease: stageHasVerticalCrease,
                onMinimize: { pane.close() },
                onStop: stop,
                onAddStream: { streamPickerMode = .add },
                onSwitchSecondStream: { streamPickerMode = .replaceSecond },
                onRemoveStream: removeStream,
                onKeepOnly: keepOnly,
                onOpenOnTwitch: openChannelOnTwitch
            )
            .frame(maxWidth: .infinity)
            .frame(maxHeight: maxHeight ?? .infinity)
        } else {
            ZStack {
                if onTV {
                    CobaltColor.bg
                    playerOrTV(compact: maxHeight != nil || compactControls)
                } else {
                    Color.black
                    player
                }

                if ownsGlassHUD {
                    VStack(spacing: 0) {
                        MediaEdgeVignette(edge: .top, height: compactControls ? 54 : 70, intensity: 0.36)
                        Spacer(minLength: 0)
                        if compactControls {
                            MediaEdgeVignette(edge: .bottom, height: 64, intensity: 0.48)
                        }
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        singleStreamChannelPill(compact: compactControls)
                        Spacer(minLength: 0)
                        if compactControls {
                            floatingCompactControls
                        }
                    }
                } else if compactControls {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        floatingCompactControls
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: maxHeight ?? .infinity)
            .clipped()
        }
    }

    /// Subtle non-overlapping channel identity pill below the transparent system toolbar in single-focus single-stream mode.
    private func singleStreamChannelPill(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if isLive {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .shadow(color: .red.opacity(0.7), radius: 3)
            }
            Text(title)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !compact, let subtitle {
                Text(subtitle)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, compact ? 4 : 8)
        .allowsHitTesting(false)
    }

    /// Compact Clear Liquid Glass playback controls overlaid on single-stream video in Tabletop or Keyboard-Open postures
    /// so no separate stream bar competes for vertical height with chat & keyboard.
    private var floatingCompactControls: some View {
        MediaGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                if let clipText {
                    Text(clipText)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(store.clipState == .failed ? CobaltColor.errorText : CobaltColor.success)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .mediaGlassCapsule(interactive: false)
                }

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    Button { host.setPaused(host.isPlaying) } label: {
                        Image(systemName: host.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(host.isPlaying ? Copy.Twitch.pause : Copy.Twitch.play)
                    .accessibilityIdentifier("twitch.playpause")

                    Button { streamPickerMode = .add } label: {
                        Image(systemName: Symbol.Twitch.addStream)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Twitch.addSecondStream)
                    .accessibilityIdentifier("twitch.addSecondStream")

                    Button { host.jumpToLive() } label: {
                        Image(systemName: Symbol.Twitch.jumpToLive)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle((host.delay == nil || host.isCatchingUp) ? .white.opacity(0.42) : .white)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(host.delay == nil || host.isCatchingUp)
                    .accessibilityLabel(Copy.Twitch.jumpToLive)
                    .accessibilityIdentifier("twitch.jumpToLive")

                    if store.canClip {
                        Button(action: makeClip) {
                            Image(systemName: Symbol.Twitch.clip)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle((offline || store.clipState == .making) ? .white.opacity(0.42) : .white)
                                .frame(width: Metrics.hit, height: Metrics.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(offline || store.clipState == .making)
                        .accessibilityLabel(Copy.Twitch.clip)
                        .accessibilityIdentifier("twitch.clip")
                    }

                    #if os(iOS)
                    Button { choosingTV = true } label: {
                        Image(systemName: Symbol.Twitch.tv)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(onTV ? TwitchTVPalette.tv : .white)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Twitch.watchOnTV)
                    .accessibilityIdentifier("twitch.tv")
                    #endif
                }
                .padding(.horizontal, 4)
                .mediaGlassCapsule(interactive: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var chatPanel: some View {
        TwitchChatCard(
            model: model,
            delay: isDualStream ? 0 : chatDelay,
            combined: isDualStream ? store.combinedChat : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Minimized running bar over the tabs: live mini-player thumb, channel title/subtitle, focus swap/cycle, play/pause, and explicit stop/dismiss.
    private var bar: some View {
        HStack(spacing: 10) {
            ZStack { barThumb }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isDualStream {
                        ForEach(TwitchStreamSlot.slots(forCount: channels.count)) { slot in
                            Circle()
                                .fill(Color(dualRGB: slot.darkRGB))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                    } else if isLive {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if isDualStream {
                    Button {
                        if isMultiStream {
                            host.cycleSpotlight(forward: true)
                        } else {
                            host.swapDualFocus()
                        }
                    } label: {
                        Image(systemName: isMultiStream ? Symbol.Twitch.cycleFocus : Symbol.Twitch.swapFocus)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 22, minHeight: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    #if os(iOS)
                    .controlSize(.regular)
                    #endif
                    .accessibilityLabel(Copy.Twitch.swapFocus)
                    .accessibilityIdentifier("twitch.bar.swapFocus")
                }

                Button { host.setPaused(showsPauseGlyph) } label: {
                    Image(systemName: showsPauseGlyph ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if os(iOS)
                .controlSize(.regular)
                #endif
                .accessibilityLabel(showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play)

                Button(role: .destructive, action: stop) {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if os(iOS)
                .controlSize(.regular)
                #endif
                .accessibilityLabel(Copy.Twitch.stop)
                .accessibilityIdentifier("twitch.bar.stop")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    private func hairline(horizontal: Bool) -> some View {
        Rectangle()
            .fill(CobaltColor.hairline)
            .frame(width: horizontal ? nil : 0.5, height: horizontal ? 0.5 : nil)
            .accessibilityHidden(true)
    }

    // MARK: words & actions

    private var title: String {
        if channels.count >= 3 {
            let first = store.displayName(for: channels[0])
            let second = store.displayName(for: channels[1])
            return "\(first) · \(second) \(Copy.Twitch.plusMore(channels.count - 2))"
        }
        if channels.count == 2 {
            return "\(store.displayName(for: channels[0])) · \(store.displayName(for: channels[1]))"
        }
        return (holdsChannel ? store.channelInfo?.displayName : nil) ?? login
    }

    private var subtitle: String? {
        guard holdsChannel else { return nil }
        if isDualStream {
            let focused = host.focusedChannel ?? login
            let focusedName = store.displayName(for: focused)
            if let s = store.streamInfo(for: focused) {
                return [focusedName, Copy.Twitch.watching(s.viewers), s.game].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return focusedName
        }
        if let s = store.stream {
            return [Copy.Twitch.watching(s.viewers), s.game].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return store.channelInfo != nil ? Copy.Twitch.offline : nil
    }

    /// Secondary actions handed to `PaneChrome`'s header `⋯` menu (macOS / iPad split-column).
    private var moreActions: [PaneAction] {
        var out: [PaneAction] = []
        if isDualStream {
            if canAddMoreStreams {
                out.append(PaneAction(
                    Copy.Twitch.addStreamTitle(current: channels.count, max: PaneItem.maxSimultaneousStreams),
                    systemImage: Symbol.Twitch.addStream
                ) {
                    streamPickerMode = .add
                })
            }
            if !isMultiStream {
                out.append(PaneAction(Copy.Twitch.swapSecondStream, systemImage: Symbol.Twitch.swapFocus) {
                    streamPickerMode = .replaceSecond
                })
            }
            if isMultiStream {
                for ch in channels {
                    let name = store.displayName(for: ch)
                    out.append(PaneAction(Copy.Twitch.dropStream(name), systemImage: Symbol.Twitch.dropStream) {
                        removeStream(ch)
                    })
                }
            }
            for ch in channels {
                let name = store.displayName(for: ch)
                out.append(PaneAction(Copy.Twitch.keepOnly(name), systemImage: Symbol.Twitch.focusLayout) {
                    keepOnly(ch)
                })
            }
            if host.canTogglePiP {
                out.append(PaneAction(
                    host.isPiPActive ? Copy.Twitch.closeFloatingWindow : Copy.Twitch.floatingWindow,
                    systemImage: host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.floatingPanel
                ) {
                    host.togglePiP()
                })
            }
            for ch in channels {
                let name = store.displayName(for: ch)
                if let url = URL(string: "https://www.twitch.tv/\(ch)") {
                    out.append(PaneAction("\(Copy.Twitch.openOnTwitch) (\(name))", systemImage: Symbol.Twitch.open) { openURL(url) })
                }
            }
        } else {
            out.append(PaneAction(Copy.Twitch.addSecondStream, systemImage: Symbol.Twitch.addStream) {
                streamPickerMode = .add
            })
            out.append(PaneAction(
                host.activeMode == .lowLatency ? Copy.Twitch.playerEmbed : Copy.Twitch.playerLowLatency,
                systemImage: host.activeMode == .lowLatency ? Symbol.Twitch.embed : Symbol.Twitch.lowLatency
            ) {
                host.setMode(host.activeMode == .lowLatency ? .embed : .lowLatency)
            })
            if let url = URL(string: "https://www.twitch.tv/\(login)") {
                out.append(PaneAction(Copy.Twitch.openOnTwitch, systemImage: Symbol.Twitch.open) { openURL(url) })
            }
        }
        return out
    }

    /// Zero-flash promotion appending a new channel (1->2, 2->3, 3->4).
    private func addStream(_ picked: String) {
        guard let clean = TwitchStore.login(from: picked),
              !channels.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }),
              canAddMoreStreams,
              let next = item.addingStream(clean) else { return }
        pane.open(next)
    }

    /// Zero-flash replacement of Slot B while keeping Slot A live.
    private func replaceSecondStream(with picked: String) {
        guard let clean = TwitchStore.login(from: picked),
              clean.caseInsensitiveCompare(login) != .orderedSame,
              let next = item.replacingStream(at: 1, with: clean) else { return }
        pane.open(next)
    }

    /// Zero-flash removal of one stream (4->3, 3->2, 2->1), preserving all surviving slots.
    private func removeStream(_ channel: String) {
        if let next = item.removingStream(channel) {
            pane.open(next)
        } else {
            stop()
        }
    }

    /// Zero-flash demotion keeping `channel` alive on screen.
    private func keepOnly(_ channel: String) {
        pane.open(.stream(channel))
    }

    private func openChannelOnTwitch(_ channel: String) {
        if let url = URL(string: "https://www.twitch.tv/\(channel)") {
            openURL(url)
        }
    }

    private func makeClip() {
        let targetChannel = isDualStream ? (host.focusedChannel ?? login) : login
        Task {
            await store.clip(channel: targetChannel) { url in
                _ = model.queue.add([.link(url)], via: .paste)
            }
        }
    }

    private func clearClipStateSoon() async {
        guard store.clipState == .saved || store.clipState == .failed else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        store.acknowledgeClip()
    }

    /// Ends all active streams: chat closes, player stops, and the pane hides (no bar: nothing is running).
    private func stop() {
        store.close()
        host.stop()
        pane.setRunning(false, for: item)
        pane.close()
    }

    private var clipText: String? {
        switch store.clipState {
        case .idle: nil
        case .making: Copy.Twitch.clipping
        case .saved: Copy.Twitch.clipSaved
        case .failed: Copy.Twitch.clipFailed
        }
    }

    // MARK: the player

    private var onTV: Bool {
        #if os(iOS)
        !isDualStream && TwitchTV.shared.onTV
        #else
        false
        #endif
    }

    /// The player, or while it plays on the TV, the card standing in for it.
    @ViewBuilder private func playerOrTV(compact: Bool) -> some View {
        #if os(iOS)
        if onTV {
            TwitchTVCard(model: model, compact: compact)
        } else {
            player
        }
        #else
        player
        #endif
    }

    private var player: some View {
        TwitchPlayer(channel: login)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }

    /// The bar's thumb: live focused/spotlighted stream in a 40 pt window (never demotes multi-stream to single!).
    @ViewBuilder private var barThumb: some View {
        if isDualStream {
            TwitchDualBarThumb(channels: channels)
        } else if onTV, let url = store.channelInfo?.avatar {
            StillImage(url: url)
        } else if onTV {
            ZStack { CobaltColor.surface; Image(systemName: Symbol.Twitch.tv).foregroundStyle(CobaltColor.caption) }
        } else {
            // Twitch's embed wants a real size: it is laid out at 400 x 225 and scaled down to the thumb
            TwitchPlayer(channel: login, showsDelay: false)
                .frame(width: 400, height: 225)
                .scaleEffect(40.0 / 225.0)
                .frame(width: 40, height: 40)
                .clipped()
                .allowsHitTesting(false)
        }
    }

    private var chatDelay: TimeInterval { TwitchChatCard.tvDelay }
}

// MARK: - Multi-Stream Mini-Bar Live Thumbnail

/// Holds a multi-stream claim while the pane is minimized to `.bar` so all engines stay live without demoting to single-stream.
private struct TwitchDualBarThumb: View {
    let channels: [String]

    @State private var holderID = UUID()
    private var host: TwitchPlayerHost { .shared }

    private var activeSlot: TwitchStreamSlot {
        if channels.count >= 3 {
            return host.multiMixer.spotlightSlot
        }
        return host.dualMixer.focusedSlot.streamSlot
    }

    var body: some View {
        ZStack {
            Color.black
            if host.isPiPOwningViews {
                Image(systemName: Symbol.Twitch.pipEnter)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                TwitchNativeSlotSurface(
                    slot: activeSlot,
                    holds: host.holds(holderID),
                    pipActive: host.isPiPOwningViews
                )
                .mediaMask()
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            host.claimMulti(holderID, channels: channels)
        }
        .onChange(of: channels) { _, next in
            host.claimMulti(holderID, channels: next)
        }
        .onDisappear {
            host.release(holderID)
        }
    }
}

// MARK: - Add Stream Picker Sheet

/// Reusable picker sheet to add or switch a Twitch stream alongside existing active channel(s).
struct TwitchAddSecondStreamSheet: View {
    let model: AppModel
    let excluding: Set<String>
    var title: String = Copy.Twitch.pickSecondStreamTitle
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var store: TwitchStore { model.twitch }

    private var filteredLive: [TwitchStreamInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.following.filter { s in
            let lower = s.login.lowercased()
            guard !excluding.contains(lower) else { return false }
            if q.isEmpty { return true }
            return lower.contains(q) || s.displayName.lowercased().contains(q) || s.game.lowercased().contains(q)
        }
    }

    private var filteredRecents: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let liveSet = Set(store.following.map { $0.login.lowercased() })
        return store.recents.filter { login in
            let lower = login.lowercased()
            guard !excluding.contains(lower), !liveSet.contains(lower) else { return false }
            if q.isEmpty { return true }
            return lower.contains(q)
        }
    }

    private var parsedQueryLogin: String? {
        guard let candidate = TwitchStore.login(from: query), !excluding.contains(candidate.lowercased()) else {
            return nil
        }
        return candidate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Search / direct login input
                    HStack(spacing: 8) {
                        Image(systemName: Symbol.Twitch.search)
                            .foregroundStyle(CobaltColor.caption)
                        TextField(Copy.Twitch.pickSecondStreamPrompt, text: $query)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.go)
                            #endif
                            .onSubmit(submitQuery)
                            .accessibilityIdentifier("twitch.dual.picker.search")
                        if parsedQueryLogin != nil {
                            Button(Copy.Twitch.open, action: submitQuery)
                                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .frame(minHeight: Metrics.hit)
                    .background(CobaltColor.surface, in: Capsule())

                    if !filteredLive.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Copy.Twitch.liveNow)
                                .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                                .foregroundStyle(CobaltColor.caption)
                            ForEach(filteredLive) { stream in
                                Button {
                                    pick(stream.login)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Rectangle().fill(CobaltColor.frameBase)
                                            if let thumb = stream.thumbnail {
                                                StillImage(url: thumb)
                                            }
                                        }
                                        .frame(width: 84, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Circle().fill(Color.red).frame(width: 6, height: 6)
                                                Text(stream.displayName)
                                                    .font(Font.cobalt(14.5, .semibold))
                                                    .foregroundStyle(CobaltColor.text)
                                                    .lineLimit(1)
                                            }
                                            Text(stream.game.isEmpty ? stream.title : "\(Copy.Twitch.viewers(stream.viewers)) · \(stream.game)")
                                                .font(Font.cobalt(12.5))
                                                .foregroundStyle(CobaltColor.caption)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: Symbol.Twitch.addStream)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(TwitchChatPalette.twitch)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: Metrics.hit)
                                    .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("twitch.dual.picker.live.\(stream.login)")
                            }
                        }
                    }

                    if !filteredRecents.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Copy.Twitch.recent)
                                .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                                .foregroundStyle(CobaltColor.caption)
                            TwitchFlow(spacing: 8, lineSpacing: 8) {
                                ForEach(filteredRecents, id: \.self) { recentLogin in
                                    Button {
                                        pick(recentLogin)
                                    } label: {
                                        Label(recentLogin, systemImage: Symbol.Twitch.recent)
                                            .font(Font.cobalt(13.5, .medium))
                                            .foregroundStyle(CobaltColor.text)
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: Metrics.hit)
                                            .background(CobaltColor.surface, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if filteredLive.isEmpty && filteredRecents.isEmpty {
                        Text(Copy.Twitch.pickSecondStreamEmpty)
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.caption)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .background(CobaltColor.bg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DuoToolbarButton(title: Copy.Twitch.close, systemImage: Symbol.Twitch.close) {
                        dismiss()
                    }
                }
                .duoVisibilityPriority(.high)
            }
            .task {
                if !store.followingLoaded {
                    await store.load()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func submitQuery() {
        guard let login = parsedQueryLogin else { return }
        pick(login)
    }

    private func pick(_ login: String) {
        onPick(login)
        dismiss()
    }
}

// MARK: - unified stream bar

/// The one consistent control and identity bar for watching Twitch across every posture:
/// collapses to a single row when wide (`TwitchWatchLayout.isInlineStreamBar`), or two crisp rows when compact.
private struct TwitchStreamBar: View {
    let title: String
    let subtitle: String?
    let isLive: Bool
    let clipNote: String?
    let clipFailed: Bool
    let isPlaying: Bool
    let jumpDisabled: Bool
    let isCatchingUp: Bool
    let canClip: Bool
    let clipState: TwitchStore.ClipState
    let offline: Bool
    let onTV: Bool
    let onPlayPause: () -> Void
    let onJumpToLive: () -> Void
    let onAddSecondStream: () -> Void
    let onClip: () -> Void
    let onTVTap: () -> Void
    let onStop: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0

    private var inline: Bool {
        TwitchWatchLayout.isInlineStreamBar(width: width, accessibilityText: typeSize.isAccessibilitySize)
    }

    private var clipButtonState: IconButtonState {
        switch clipState {
        case .making: .working
        case .saved: .done
        case .idle, .failed: .idle
        }
    }

    var body: some View {
        Group {
            if inline {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 0)
                    controls(spreadStop: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    identity
                    if typeSize.isAccessibilitySize {
                        ScrollView(.horizontal, showsIndicators: false) {
                            controls(spreadStop: false)
                        }
                    } else {
                        controls(spreadStop: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.bg)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isLive {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            if let clipNote {
                Text(clipNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(clipFailed ? CobaltColor.errorText : CobaltColor.success)
                    .lineLimit(1)
            } else if let subtitle {
                Text(subtitle)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
    }

    private func controls(spreadStop: Bool) -> some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                Button(action: onPlayPause) {
                    Label(isPlaying ? Copy.Twitch.pause : Copy.Twitch.play,
                          systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.cobaltIcon(.small, prominent: true))
                .accessibilityIdentifier("twitch.playpause")

                Button(action: onAddSecondStream) {
                    Label(Copy.Twitch.addSecondStream, systemImage: Symbol.Twitch.addStream)
                }
                .buttonStyle(.cobaltIcon(.small))
                .accessibilityIdentifier("twitch.addSecondStream")

                Button(action: onJumpToLive) {
                    Label(Copy.Twitch.jumpToLive, systemImage: Symbol.Twitch.jumpToLive)
                }
                .buttonStyle(.cobaltIcon(.small, state: isCatchingUp ? .working : .idle))
                .disabled(jumpDisabled)
                .accessibilityIdentifier("twitch.jumpToLive")

                if canClip {
                    Button(action: onClip) {
                        Label(Copy.Twitch.clip, systemImage: Symbol.Twitch.clip)
                    }
                    .buttonStyle(.cobaltIcon(.small, state: clipButtonState))
                    .disabled(offline || clipState == .making)
                    .accessibilityHint(offline ? Copy.Pane.needsNetwork : "")
                    .accessibilityIdentifier("twitch.clip")
                }

                #if os(iOS)
                Button(action: onTVTap) {
                    Label(Copy.Twitch.watchOnTV, systemImage: Symbol.Twitch.tv)
                }
                .buttonStyle(.cobaltIcon(.small, tint: onTV ? TwitchTVPalette.tv : nil))
                .accessibilityIdentifier("twitch.tv")
                #endif

                if spreadStop {
                    Spacer(minLength: 4)
                }

                Button(role: .destructive, action: onStop) {
                    Label(Copy.Twitch.stop, systemImage: "stop.fill")
                }
                .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
                .accessibilityIdentifier("twitch.stop")
            }
        }
    }
}

/// What a stream keeps for as long as the pane holds it, whatever shape its page is drawn in (`Pane.keepAlive`): the chat
/// connection and the TV's watch. Preserves chat/TV across 1<->2<->3<->4 stream transitions.
@MainActor
private final class TwitchWatch: PaneKeptObject {
    private let channels: [String]
    private let model: AppModel
    private weak var pane: Pane?
    private var started = false

    private var primaryLogin: String { channels.first ?? "" }

    init(channels: [String], model: AppModel, pane: Pane) {
        self.channels = channels
        self.model = model
        self.pane = pane
    }

    /// Idempotent: the first page to appear starts it.
    func begin() {
        guard !started else { return }
        started = true
        #if os(iOS)
        if channels.count == 1 {
            TwitchTV.shared.watchStarted(model)
        }
        #endif
    }

    func paneReleased() {
        // If the pane transitioned directly to another stream/multi-stream (e.g., 1->2->3->4 promotion or demotion),
        // keep the store and TV watch alive without interrupting live streams or chat.
        let stillHoldingStream = (pane?.item?.isStream == true) || (pane?.barItem?.isStream == true)
        if !stillHoldingStream, model.twitch.channel == primaryLogin {
            model.twitch.close()
        }
        guard started else { return }
        started = false
        #if os(iOS)
        if !stillHoldingStream {
            TwitchTV.shared.watchEnded()
        }
        #endif
    }
}

/// Edge-to-edge live chat inside the stream pane (single-stream or combined multi-stream), with 7TV "add to a set"
/// presented as a sheet over the pane so the stream(s) stay mounted and playing underneath.
struct TwitchChatCard: View {
    let model: AppModel
    let delay: TimeInterval
    var combined: TwitchCombinedChatModel? = nil

    /// Video-only AirPlay runs the TV behind the phone: chat waits to match (70.5).
    static var tvDelay: TimeInterval {
        #if os(iOS)
        TwitchTV.shared.activeChatDelay
        #else
        0
        #endif
    }

    @State private var addingToSet: SevenTvAddToSetModel?

    var body: some View {
        TwitchChatPane(model: model, delay: delay, showsLabel: false, combined: combined) { emote in
            guard let hit = emote.asHit else { return }
            SevenTvEmoteHits.remember(hit)
            addingToSet = model.sevenTv.addToSetPicker(emote: hit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $addingToSet) { picker in
            SevenTvAddToSetSheet(picker: picker)
        }
    }
}

#if DEBUG
private struct TwitchPageHost: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    var channels: [String] = ["ninja"]

    var body: some View {
        let item = PaneItem.streams(channels) ?? .stream(channels.first ?? "ninja")
        PreviewHost(.happy, tab: .twitch) { model in
            AreaPageHost(item: item, shape: shape, hinge: hinge) {
                TwitchStreamPage(channels: channels, model: model)
            }
        }
    }
}

#Preview("twitch · folded portrait", traits: .fixedLayout(width: 402, height: 800)) {
    TwitchPageHost(shape: .tall)
}
#Preview("twitch · dual stream", traits: .fixedLayout(width: 900, height: 700)) {
    TwitchPageHost(shape: .wide, channels: ["ninja", "shroud"])
}
#Preview("twitch · 3 streams", traits: .fixedLayout(width: 1180, height: 760)) {
    TwitchPageHost(shape: .wide, channels: ["ninja", "shroud", "summit1g"])
}
#Preview("twitch · 4 streams", traits: .fixedLayout(width: 1180, height: 760)) {
    TwitchPageHost(shape: .wide, channels: ["ninja", "shroud", "summit1g", "pokimane"])
}
#Preview("twitch · landscape phone", traits: .fixedLayout(width: 874, height: 380)) {
    TwitchPageHost(shape: .wide)
}
#Preview("twitch · mac wide", traits: .fixedLayout(width: 1180, height: 760)) {
    TwitchPageHost(shape: .wide)
}
#Preview("twitch · duo split", traits: .fixedLayout(width: 900, height: 760)) {
    TwitchPageHost(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 450))
}
#Preview("twitch · mini bar", traits: .fixedLayout(width: 402, height: 72)) {
    TwitchPageHost(shape: .bar)
}
#Preview("twitch · quad mini bar", traits: .fixedLayout(width: 402, height: 72)) {
    TwitchPageHost(shape: .bar, channels: ["ninja", "shroud", "summit1g", "pokimane"])
}
#endif
