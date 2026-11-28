import CobaltKit
import SwiftUI

// MARK: - Ambient Cinema Post Studio (Variation B · Adaptive Crease Studio)

/// Primary single-focus Media Item studio implementing **Variation B (Adaptive Crease Studio)**:
/// - Edge-to-edge **Ambient Cinema** stage (9:16 portrait, 16:9 landscape, video, WebP, photo, gallery)
/// - Floating Clear Liquid Glass top HUD with Unified Identity Pill + live 4-state visibility popover
/// - Floating Clear Liquid Glass **Dual-URL Dock** (`Copy Share` + `Direct` + system Share)
/// - Fold-aware **Creator Studio Deck** (`Access` / `Tools` / `CC`) via `DuoMediaOverlay` (`ArrangementView(.overlay)`):
///   - Unfolded Wide (flat): full-height cinema left + docked Studio Deck right (default open, toggleable)
///   - Half-Closed Tabletop / Book Crease (`isSeparated`): cinema on one half, expanded Studio Deck on the other
///   - Folded / Compact: full-bleed cinema + floating HUD + Dual-URL Dock + toggleable Studio Deck sheet
struct AmbientCinemaPostStudio: View {
    let context: DetailContext
    let kit: PostActionKit
    let fromAlbum: Bool
    /// True in single-focus `PanePostPage` (owns its floating close button & suppresses `PaneChrome`'s opaque header).
    /// False when pushed inside a `NavigationStack` (`MediaDetail`) that keeps the system back button.
    var showsCloseButton: Bool = true
    var onOpenPost: ((LibraryPost) -> Void)? = nil

    @Environment(\.subtitles) private var subtitles
    @Environment(\.shell) private var shell
    @Environment(\.paneReservedRegions) private var reservedRegions
    @Environment(\.paneHostSize) private var hostSize
    @Environment(\.paneSafeAreaInsets) private var paneSafeAreaInsets
    @Environment(\.duoStatusAdjacentBarForcePreview) private var forceStatusBarPreview
    @Environment(\.paneOffline) private var offline
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.lifecycle) private var lifecycle
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var ambientEnabled = true
    @State private var videoSampler = AmbientVideoSampler()
    /// Variation B default: Studio Deck docked open on wide displays, collapsed to sheet button on compact.
    @State private var wideDeckOpen = true
    @State private var compactSheetOpen = false
    @State private var deckTab: AmbientDeckTab = .access
    @State private var showIdentityPopover = false
    @State private var renameDraft = ""
    @State private var renameSaving = false
    @State private var askingVisibility: AmbientVisibilityAsk?
    @State private var copiedPrivate = false
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var insightStore = StudioDeckInsightStore()
    @State private var openedNeighbour: OpenedMedia?
    @State private var canvasWidth: CGFloat = 0
    @State private var useLeveledAudio = false
    @State private var holdingOriginalAudio = false
    @State private var seededAudioKey: String?
    @FocusState private var editingTitle: Bool

    private var isWideCanvas: Bool {
        canvasWidth >= DetailWidth.wide && !typeSize.isAccessibilitySize
    }

    private var item: MediaItem { context.item }
    private var rendition: Rendition { context.rendition }
    /// The exact visible rendition on screen (active carousel slide when paging a gallery, `nil` on a missing slide,
    /// otherwise the selected rendition tab).
    private var activeRendition: Rendition? {
        if context.isGalleryLike, let page = context.page {
            return page.rendition
        }
        return context.rendition
    }
    private var activeRenditionIsVideo: Bool {
        guard let activeRendition else { return false }
        if activeRendition.isStillPicture || activeRendition.isWebp || activeRendition.isAnimatedMade || activeRendition.isGifItem {
            return false
        }
        if activeRendition.local?.fileURL?.pathExtension.lowercased() == "gif" {
            return false
        }
        if activeRendition.file?.contentType?.lowercased() == "image/gif"
            || activeRendition.hosted?.contentType?.lowercased() == "image/gif" {
            return false
        }
        return true
    }
    private var activeBackdropKey: String {
        "\(item.id)|\(activeRendition?.id ?? "missing:\(context.missingIndex ?? -1)")"
    }
    private var shouldSampleLiveVideo: Bool {
        ambientEnabled && !reduceMotion && lifecycle.isForeground && !lifecycle.shouldConservePower && activeRenditionIsVideo
    }
    private var model: AppModel { context.model }
    private var controller: DetailController { context.controller }

    private var displayTitle: String { item.titleText }

    private var livePost: LibraryPost? {
        if let post = item.post { return post }
        let ids = Set([rendition.file?.id, rendition.hosted?.id].compactMap { $0 })
        guard !ids.isEmpty else { return nil }
        let holds: (LibraryPost) -> Bool = { $0.files.contains { ids.contains($0.id) } }
        return model.library.posts.first(where: holds) ?? model.library.hiddenPosts.first(where: holds)
    }

    private var canHide: Bool {
        model.capabilities.hidden && livePost != nil
    }

    private var isHidden: Bool {
        canHide && (fromAlbum || livePost?.hidden == true || model.isHiddenPost(item))
    }

    private var usesPostVisibilitySwitch: Bool {
        let many = item.detailShape == .gallery || item.made.count > 0
        return context.isGalleryLike && many && controller.canSwitchPost(item)
    }

    private var currentFileLink: FileLink {
        if model.canChoosePrivateLink(rendition) {
            return model.fileLink(of: rendition)
        }
        return rendition.visibility == .public ? .public : .off
    }

    private var visibilityState: AmbientVisibilityState {
        if isHidden { return .hidden }
        if usesPostVisibilitySwitch {
            return controller.isPostPublic(item) ? .public : .off
        }
        switch currentFileLink {
        case .public: return .public
        case .private: return .private
        case .off: return .off
        }
    }

    private var visibilityChanging: Bool {
        if usesPostVisibilitySwitch {
            return controller.postVisibility == .working || model.library.statusInFlight
        }
        return model.isChangingVisibility(rendition) || model.library.statusInFlight
    }

    private var liveShareURL: URL? {
        guard !isHidden, context.missingIndex == nil else { return nil }
        if !usesPostVisibilitySwitch, currentFileLink == .private {
            return model.privateURL(of: rendition) ?? rendition.privateURL
        }
        return rendition.privateURL ?? rendition.hosted?.url ?? rendition.publicURL
    }

    // MARK: - Audio Loudness Leveling (v10.1)

    private var audioTargetRendition: Rendition? {
        if let active = activeRendition, active.supportsAudioLeveling { return active }
        return rendition.supportsAudioLeveling ? rendition : nil
    }

    private var activeAudioFileID: String? {
        audioTargetRendition?.file?.id
    }

    private var activeAudio: AudioLoudnessInfo? {
        audioTargetRendition?.audio
    }

    private var showAudioLevelingUI: Bool {
        model.capabilities.audioLeveling && activeAudioFileID != nil && context.missingIndex == nil
    }

    private var audioIsLeveled: Bool {
        activeAudio?.isLeveled == true
    }

    /// True when the user has Leveled selected on a leveled clip ("what you hear is what you copy" — never affected by momentary hold).
    private var usingLeveledShareLink: Bool {
        audioIsLeveled && useLeveledAudio
    }

    /// True when the video hero should actively stream the leveled audio alternate.
    private var playingLeveledAudio: Bool {
        audioIsLeveled && useLeveledAudio && !holdingOriginalAudio
    }

    /// Resolves the share or direct URL for the current Original / Leveled switch.
    private func resolvedAudioURL(_ base: URL, form: LinkForm) -> URL {
        if form == .direct {
            if usingLeveledShareLink, let alt = activeAudio?.altURL {
                return alt
            }
            return AudioShareURL.resolve(base: base, audio: activeAudio, useLeveled: usingLeveledShareLink)
        }
        let shareTarget = currentFileLink == .private ? base : model.capabilities.shareLink(for: base)
        return AudioShareURL.resolve(base: shareTarget, audio: activeAudio, useLeveled: usingLeveledShareLink)
    }

    private func seedAudioState(force: Bool = false) {
        if force || seededAudioKey != activeBackdropKey {
            seededAudioKey = activeBackdropKey
            useLeveledAudio = model.audioLeveling.prefersLeveledLink(for: activeAudio)
            holdingOriginalAudio = false
        } else if !audioIsLeveled {
            useLeveledAudio = false
            holdingOriginalAudio = false
        }
    }

    private func openAudioToolsDeck(isWide: Bool) {
        deckTab = .tools
        if isWide {
            wideDeckOpen = true
        } else {
            compactSheetOpen = true
        }
    }

    private var hasTranscript: Bool { subtitles?.available == true }

    private var captionsActive: Bool {
        guard let subtitles, subtitles.available else { return false }
        return subtitles.on || subtitles.forcedOn
    }

    private var availableTabs: [AmbientDeckTab] {
        hasTranscript ? [.access, .tools, .transcript] : [.access, .tools]
    }

    private func resolvedStatusBarMetrics(containerSize: CGSize) -> DuoStatusAdjacentBarMetrics {
        guard showsCloseButton else { return .inactive }
        let resolvedSize = hostSize.width > 0 ? hostSize : containerSize
        return DuoStatusAdjacentBarMetrics.resolve(
            hostSize: resolvedSize,
            safeArea: paneSafeAreaInsets,
            reserved: reservedRegions,
            typeSize: typeSize,
            forcePreview: forceStatusBarPreview
        )
    }

    var body: some View {
        let hostStatusBar = resolvedStatusBarMetrics(containerSize: hostSize)

        GeometryReader { geo in
            let isWide = geo.size.width >= DetailWidth.wide && !typeSize.isAccessibilitySize
            let deckWidth = min(max(geo.size.width * 0.34, 300), 344)
            let creaseHint = reservedRegions.activeDivision != nil
            let showDockedDeck = isWide && wideDeckOpen && !creaseHint
            let statusBar = resolvedStatusBarMetrics(containerSize: geo.size)
            let cinemaWidth = showDockedDeck ? max(0, geo.size.width - deckWidth) : geo.size.width

            DuoMediaOverlay(edge: .bottom, axes: [.horizontal, .vertical]) { isSeparated in
                if isSeparated {
                    separatedCreaseDeck
                } else {
                    flatOverlayHUD(
                        isWide: isWide,
                        deckWidth: deckWidth,
                        showDockedDeck: showDockedDeck,
                        cinemaWidth: cinemaWidth,
                        statusBar: statusBar
                    )
                }
            } media: {
                AmbientCinemaCanvas(
                    context: context,
                    backdropItem: context.missingIndex == nil ? item : nil,
                    activeRendition: activeRendition,
                    livePalette: activeRenditionIsVideo ? videoSampler.livePalette : nil,
                    ambientEnabled: ambientEnabled,
                    reserveRight: showDockedDeck ? deckWidth : 0
                )
                .environment(\.audioUseLeveledPlayback, playingLeveledAudio)
            }
            .environment(\.ambientVideoSampler, videoSampler)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
        .background(Color(hex: 0x070709).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .preference(key: PaneHidesChromeHeaderKey.self, value: showsCloseButton)
        #if os(iOS)
        .preference(key: PaneShowsSystemToolbarKey.self, value: showsCloseButton && !hostStatusBar.isActive)
        .toolbar {
            if !hostStatusBar.isActive {
                studioToolbar
            }
        }
        .duoToolbarCompression(.prefersToolbarItems)
        #endif
        .sheet(isPresented: $compactSheetOpen) {
            compactDeckSheet
        }
        .navigationDestination(item: $openedNeighbour) { target in
            MediaDetail(model: model, item: target.item, initial: target.initial)
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mediaGlassCapsule(interactive: false)
                    .padding(.top, hostStatusBar.isActive ? hostStatusBar.bandHeight + 8 : 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            visibilityDialogTitle(askingVisibility),
            isPresented: Binding(get: { askingVisibility != nil }, set: { if !$0 { askingVisibility = nil } }),
            titleVisibility: .visible,
            presenting: askingVisibility
        ) { ask in
            visibilityDialogButtons(ask)
        } message: { ask in
            Text(visibilityDialogMessage(ask))
        }
        .task(id: rendition.id) {
            await preloadPrivateLinks()
            if model.capabilities.audioLeveling && !model.audioLeveling.loaded {
                await model.audioLeveling.load()
                seedAudioState(force: true)
            }
        }
        .onAppear {
            videoSampler.setActive(shouldSampleLiveVideo)
            seedAudioState()
        }
        .onDisappear {
            holdingOriginalAudio = false
            videoSampler.tearDown()
        }
        .onChange(of: shouldSampleLiveVideo) { _, active in
            videoSampler.setActive(active)
        }
        .onChange(of: activeBackdropKey) { _, _ in
            videoSampler.resetForMediaChange()
            videoSampler.setActive(shouldSampleLiveVideo)
            seedAudioState(force: true)
        }
        .onChange(of: audioIsLeveled) { _, leveled in
            if leveled {
                if model.audioLeveling.settings.defaultLink == .normal {
                    useLeveledAudio = true
                }
            } else {
                useLeveledAudio = false
                holdingOriginalAudio = false
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: wideDeckOpen)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: toast)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ambientEnabled)
        .haptic(.success, trigger: controller.copiedID, enabled: haptics) { $0 != nil }
        .haptic(.success, trigger: controller.privateLinkCopied, enabled: haptics) { $0 > 0 }
    }

    // MARK: - Flat Overlay HUD (Outer Folded, Unfolded Wide, iPad, Mac)

    private func flatOverlayHUD(
        isWide: Bool,
        deckWidth: CGFloat,
        showDockedDeck: Bool,
        cinemaWidth: CGFloat,
        statusBar: DuoStatusAdjacentBarMetrics
    ) -> some View {
        HStack(spacing: 0) {
            ZStack {
                // Edge vignettes keep Clear Liquid Glass controls crisp over any bright or dark frame.
                VStack(spacing: 0) {
                    MediaEdgeVignette(edge: .top, height: 108, intensity: 0.42)
                    Spacer(minLength: 0)
                    MediaEdgeVignette(edge: .bottom, height: 184, intensity: 0.52)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    if statusBar.isActive {
                        topStatusAdjacentGlassHUD(
                            isWide: isWide,
                            showDockedDeck: showDockedDeck,
                            cinemaWidth: cinemaWidth,
                            metrics: statusBar
                        )
                    } else {
                        topGlassHUD(isWide: isWide)
                    }

                    Spacer(minLength: 0)

                    VStack(spacing: 10) {
                        if item.detailTabs.count > 1 {
                            renditionGlassStrip
                        }
                        dualURLDock
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .ignoresSafeArea(.container, edges: statusBar.isActive ? .top : [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showDockedDeck {
                dockedStudioDeck(topClearance: statusBar.isActive ? statusBar.bandHeight : 0)
                    .frame(width: deckWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Rule 15 System Toolbar (iPhone Duo Vertical Rail + Compact Nav Bar)

    #if os(iOS)
    @ToolbarContentBuilder
    private var studioToolbar: some ToolbarContent {
        if showsCloseButton {
            CobaltBackToolbarItem(title: Copy.close, accessibilityIdentifier: "pane.close") {
                context.leave()
            }
        }

        let deckActive = isWideCanvas ? wideDeckOpen : compactSheetOpen
        ToolbarItem(placement: .primaryAction) {
            DuoToolbarButton(
                title: deckActive ? "Hide Studio Deck" : "Show Studio Deck",
                systemImage: "sidebar.right"
            ) {
                if isWideCanvas {
                    wideDeckOpen.toggle()
                } else {
                    compactSheetOpen.toggle()
                }
            }
            .accessibilityIdentifier("ambient.studioDeckToggle")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .automatic) {
            DuoToolbarButton(
                title: ambientEnabled ? "Turn off ambient cinema glow" : "Turn on ambient cinema glow",
                systemImage: ambientEnabled ? "sun.max.fill" : "sun.max"
            ) {
                ambientEnabled.toggle()
            }
            .accessibilityIdentifier("ambient.glowToggle")
        }
        .duoVisibilityPriority(.automatic)

        if hasTranscript, let subtitles {
            ToolbarItem(placement: .automatic) {
                DuoToolbarButton(
                    title: captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn,
                    systemImage: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off
                ) {
                    subtitles.toggle()
                }
            }
            .duoVisibilityPriority(.automatic)
        }

        DuoOverflowToolbarMenu(Copy.Media.more) {
            moreMenuItems(includeQuickToggles: false)
        }
    }
    #endif

    // MARK: - Top Clear Liquid Glass HUD (iPhone Duo Status-Adjacent Strip)

    /// Compact Clear Liquid Glass HUD parked inside the leading top status-adjacent band beside `9:41` + status orb
    /// on iPhone Duo portrait postures, keeping the full-bleed cinema canvas unobstructed.
    private func topStatusAdjacentGlassHUD(
        isWide: Bool,
        showDockedDeck: Bool,
        cinemaWidth: CGFloat,
        metrics: DuoStatusAdjacentBarMetrics
    ) -> some View {
        let trailingReserve = showDockedDeck ? CGFloat(12) : metrics.trailingReserve
        let leadingSlotWidth = max(0, cinemaWidth - metrics.leadingInset - trailingReserve)
        let showsWideControls = leadingSlotWidth >= DuoStatusAdjacentBarLayout.wideLeadingSlotMinWidth
        let deckActive = isWide ? wideDeckOpen : compactSheetOpen
        let justCopied = controller.copiedID == rendition.id
        let copiedShare = (justCopied && controller.copiedForm != .direct) || copiedPrivate

        return DuoStatusAdjacentBar(
            surface: .clearLiquidGlass,
            metrics: metrics,
            trailingReserveOverride: showDockedDeck ? 12 : nil
        ) {
            if showsCloseButton {
                DuoStatusBarBackButton(surface: .clearLiquidGlass) {
                    context.leave()
                }
            }

            // Compact visibility dot + filename pill with live 4-state visibility / rename popover.
            Button {
                renameDraft = displayTitle
                showIdentityPopover = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(visibilityState.tint)
                        .frame(width: 7, height: 7)
                        .shadow(color: visibilityState.tint.opacity(0.65), radius: 2.5)
                    Text(displayTitle)
                        .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .mediaGlassCapsule()
                .frame(minHeight: Metrics.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 68, alignment: .leading)
            .layoutPriority(0.8)
            .accessibilityLabel("\(displayTitle), \(visibilityState.shortLabel)")
            .accessibilityIdentifier("ambient.identity")
            .popover(isPresented: $showIdentityPopover, arrowEdge: .top) {
                identityPopoverContent
                    .frame(width: 300)
                    .presentationCompactAdaptation(.popover)
            }

            Spacer(minLength: 2)

            if let url = liveShareURL {
                Button {
                    copyLink(url, form: .share)
                } label: {
                    if showsWideControls {
                        DuoStatusBarPillVisual(
                            title: copiedShare
                                ? Copy.Media.copied
                                : (currentFileLink == .private ? "Private" : "Share"),
                            systemImage: copiedShare ? Symbol.Media.copied : Symbol.Media.copyLink,
                            surface: .clearLiquidGlass,
                            tint: copiedShare ? CobaltColor.success : nil
                        )
                    } else {
                        DuoStatusBarIconVisual(
                            systemImage: copiedShare ? Symbol.Media.copied : Symbol.Media.copyLink,
                            surface: .clearLiquidGlass,
                            tint: copiedShare ? CobaltColor.success : nil
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(currentFileLink == .private ? "Copy Private Share Link" : "Copy Share Link")
                .accessibilityIdentifier("ambient.statusCopyShare")
            }

            if showsWideControls {
                if hasTranscript, let subtitles {
                    Button {
                        subtitles.toggle()
                    } label: {
                        DuoStatusBarIconVisual(
                            systemImage: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off,
                            surface: .clearLiquidGlass,
                            highlighted: captionsActive
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn)
                }

                Button {
                    ambientEnabled.toggle()
                } label: {
                    DuoStatusBarIconVisual(
                        systemImage: ambientEnabled ? "sun.max.fill" : "sun.max",
                        surface: .clearLiquidGlass,
                        foreground: ambientEnabled ? Color(hex: 0xfde68a) : .white.opacity(0.75)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ambientEnabled ? "Turn off ambient cinema glow" : "Turn on ambient cinema glow")
                .accessibilityIdentifier("ambient.glowToggle")
            }

            Button {
                if isWide {
                    wideDeckOpen.toggle()
                } else {
                    compactSheetOpen.toggle()
                }
            } label: {
                if showsWideControls {
                    DuoStatusBarPillVisual(
                        title: "Deck",
                        systemImage: "sidebar.right",
                        surface: .clearLiquidGlass,
                        emphasized: deckActive
                    )
                } else {
                    DuoStatusBarIconVisual(
                        systemImage: "sidebar.right",
                        surface: .clearLiquidGlass,
                        highlighted: deckActive
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deckActive ? "Hide Studio Deck" : "Show Studio Deck")
            .accessibilityIdentifier("ambient.studioDeckToggle")

            Menu {
                moreMenuItems(includeQuickToggles: !showsWideControls)
            } label: {
                DuoStatusBarIconVisual(systemImage: "ellipsis", surface: .clearLiquidGlass)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Media.more)
        }
    }

    // MARK: - Top Clear Liquid Glass HUD

    private func topGlassHUD(isWide: Bool) -> some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                #if os(macOS)
                if showsCloseButton {
                    Button {
                        context.leave()
                    } label: {
                        Label(Copy.close, systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .mediaGlassCircle()
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.close)
                    .accessibilityIdentifier("pane.close")
                }
                #endif

                identityVisibilityPill

                if showAudioLevelingUI, let audio = activeAudio, !audio.isSilent {
                    loudnessHUDPill(audio: audio, isWide: isWide)
                }

                Spacer(minLength: 4)

                #if os(macOS)
                rightGlassControls(isWide: isWide)
                #endif
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Floating Clear Liquid Glass loudness pill in the top HUD showing live LUFS / leveled status.
    /// Tapping opens Studio Deck › Tools directly to the Audio Loudness card.
    private func loudnessHUDPill(audio: AudioLoudnessInfo, isWide: Bool) -> some View {
        let tint: Color = holdingOriginalAudio && audio.isLeveled ? Color(hex: 0xfbbf24) : audio.statusTint
        let text: String = {
            if audio.isRendering { return "Leveling…" }
            if holdingOriginalAudio && audio.isLeveled {
                return "Orig \(AudioLoudnessInfo.formatLufs(audio.integratedLufs))"
            }
            if audio.isLeveled && useLeveledAudio {
                let target = audio.targetLufs.map(AudioTargetLufs.init(clamped:)) ?? model.audioLeveling.settings.target
                return "Leveled · \(target.shortLabel)"
            }
            if let lufs = audio.integratedLufs {
                return AudioLoudnessInfo.formatLufs(lufs)
            }
            return audio.zone.label
        }()

        return Button {
            openAudioToolsDeck(isWide: isWide)
        } label: {
            HStack(spacing: 5) {
                if audio.isRendering {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: audio.isLeveled ? "waveform" : audio.zone.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(text)
                    .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .mediaGlassCapsule()
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio loudness: \(text)")
        .accessibilityHint("Opens Audio Loudness controls in Studio Deck")
        .accessibilityIdentifier("ambient.loudnessPill")
    }

    /// Unified status dot + filename + 4-state visibility / inline rename popover.
    private var identityVisibilityPill: some View {
        Button {
            renameDraft = displayTitle
            showIdentityPopover = true
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(visibilityState.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: visibilityState.tint.opacity(0.65), radius: 3)
                Text(displayTitle)
                    .font(Font.cobalt(13.5, .medium, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 40)
            .mediaGlassCapsule()
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayTitle), \(visibilityState.shortLabel)")
        .accessibilityIdentifier("ambient.identity")
        .popover(isPresented: $showIdentityPopover, arrowEdge: .top) {
            identityPopoverContent
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func rightGlassControls(isWide: Bool) -> some View {
        let deckActive = isWide ? wideDeckOpen : compactSheetOpen
        return MediaGlassGroup(spacing: 4) {
            HStack(spacing: 2) {
                if hasTranscript, let subtitles {
                    Button {
                        subtitles.toggle()
                    } label: {
                        Image(systemName: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(captionsActive ? .black : .white)
                            .frame(width: 36, height: 36)
                            .background(captionsActive ? Color.white : .clear, in: Circle())
                            .frame(minWidth: 40, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn)
                }

                Button {
                    ambientEnabled.toggle()
                } label: {
                    Image(systemName: ambientEnabled ? "sun.max.fill" : "sun.max")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ambientEnabled ? Color(hex: 0xfde68a) : .white.opacity(0.72))
                        .frame(width: 36, height: 36)
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ambientEnabled ? "Turn off ambient cinema glow" : "Turn on ambient cinema glow")
                .accessibilityIdentifier("ambient.glowToggle")

                Button {
                    if isWide {
                        wideDeckOpen.toggle()
                    } else {
                        compactSheetOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(deckActive ? .black : .white)
                        .frame(width: 36, height: 36)
                        .background(deckActive ? Color.white : .clear, in: Circle())
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(deckActive ? "Hide Studio Deck" : "Show Studio Deck")
                .accessibilityIdentifier("ambient.studioDeckToggle")

                moreMenuButton
            }
            .padding(.horizontal, 3)
            .frame(minHeight: Metrics.hit)
            .mediaGlassCapsule(interactive: false)
        }
    }

    @ViewBuilder
    private func moreMenuItems(includeQuickToggles: Bool = false) -> some View {
        if includeQuickToggles {
            Button(
                ambientEnabled ? "Turn off ambient glow" : "Turn on ambient glow",
                systemImage: ambientEnabled ? "sun.max.fill" : "sun.max"
            ) {
                ambientEnabled.toggle()
            }
            if hasTranscript, let subtitles {
                Button(
                    captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn,
                    systemImage: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off
                ) {
                    subtitles.toggle()
                }
            }
            Divider()
        }

        if let url = liveShareURL {
            Button(
                model.capabilities.hasLinkPair(url) ? Copy.LinkPair.copyShareLink : Copy.copyLink,
                systemImage: Symbol.Media.copyLink
            ) {
                copyLink(url, form: .share)
            }
            if model.capabilities.hasLinkPair(url) && currentFileLink != .private {
                Button(Copy.LinkPair.copyDirectLink, systemImage: Symbol.LinkPair.direct) {
                    copyLink(url, form: .direct)
                }
            }
            Divider()
        }

        Button(Copy.Library2.rename, systemImage: Symbol.Library.rename) {
            renameDraft = displayTitle
            showIdentityPopover = true
        }

        if let add = kit.addToLinkAction(item) {
            Button(add.title, systemImage: add.systemImage, action: add.perform)
                .disabled(add.isDisabled || (add.needsServer && offline && !add.queuesOffline))
        }

        if let edit = kit.editAction(item) {
            Button(edit.title, systemImage: edit.systemImage, action: edit.perform)
                .disabled(edit.isDisabled || (edit.needsServer && offline && !edit.queuesOffline))
        }

        if model.capabilities.chat, item.post != nil, !isHidden {
            Button(Copy.Chat.askAbout, systemImage: Symbol.chatAsk) {
                kit.askAbout(item)
            }
            .disabled(offline)
        }

        if let openLib = kit.openInLibraryAction(item) {
            Button(openLib.title, systemImage: openLib.systemImage, action: openLib.perform)
        }

        if let hide = kit.hideAction(item) {
            Divider()
            Button(hide.title, systemImage: hide.systemImage, action: hide.perform)
                .disabled(hide.isDisabled || (hide.needsServer && offline && !hide.queuesOffline))
        }

        if let delete = kit.deleteAction(item) {
            Divider()
            Button(delete.title, systemImage: delete.systemImage, role: .destructive, action: delete.perform)
                .disabled(delete.isDisabled)
        }
    }

    private var moreMenuButton: some View {
        Menu {
            moreMenuItems(includeQuickToggles: false)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .frame(minWidth: 40, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Media.more)
    }

    // MARK: - Compact Rendition Switcher Strip

    private var renditionGlassStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.detailTabs, id: \.id) { tab in
                    let active = context.selection.wrappedValue == tab.id
                    Button {
                        context.selection.wrappedValue = tab.id
                    } label: {
                        Text(tab.name)
                            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(active ? .black : .white.opacity(0.88))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(active ? Color.white : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .mediaGlassCapsule(interactive: false)
        .frame(maxWidth: 520)
    }

    // MARK: - Floating Dual-URL Quick Share Dock

    private var dualURLDock: some View {
        let caps = model.capabilities
        let url = liveShareURL
        let hasPair = url.map { caps.hasLinkPair($0) } ?? false
        let justCopied = controller.copiedID == rendition.id
        let copiedShare = justCopied && controller.copiedForm != .direct
        let copiedDirect = justCopied && controller.copiedForm == .direct

        return VStack(spacing: 8) {
            // Audio version bar ("what you hear is what you copy"): drives player, URL chip, and copy buttons together
            if audioIsLeveled {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        dockAudioTab(title: "Original", active: !useLeveledAudio) {
                            useLeveledAudio = false
                            holdingOriginalAudio = false
                        }
                        dockAudioTab(
                            title: "Leveled",
                            active: useLeveledAudio,
                            tint: Color(hex: 0x34d399)
                        ) {
                            useLeveledAudio = true
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.08), in: Capsule())

                    Spacer(minLength: 4)

                    if useLeveledAudio {
                        dockHoldOriginalPill
                    } else if let delta = activeAudio?.gainDelta(for: model.audioLeveling.settings.target) {
                        Text(AudioLoudnessInfo.formatGain(delta))
                            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                            .foregroundStyle(.white.opacity(0.65))
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 6) {
                statusPill(visibilityState)

                if let url {
                    let shown = currentFileLink == .private
                        ? FileLinkSection.display(url)
                        : DetailMeta.linkText(caps.shareLink(for: url))
                    Text(shown)
                        .font(Font.cobalt(12, .medium, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if usingLeveledShareLink {
                        Text("?audio=normal")
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .foregroundStyle(Color(hex: 0x34d399))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2.5)
                            .background(Color(hex: 0x34d399).opacity(0.16), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(hex: 0x34d399).opacity(0.38), lineWidth: 0.75)
                            )
                            .accessibilityIdentifier("ambient.audioNormalChip")
                    }
                } else {
                    Text(isHidden ? Copy.Hidden.rowDetail : Copy.PrivateLinks.offDetail)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if visibilityChanging {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }

            HStack(spacing: 8) {
                if let url {
                    Button {
                        copyLink(url, form: .share)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: (copiedShare || copiedPrivate) ? Symbol.Media.copied : Symbol.Media.copyLink)
                                .font(.system(size: 13, weight: .semibold))
                            Text(
                                (copiedShare || copiedPrivate)
                                    ? Copy.Media.copied
                                    : (currentFileLink == .private ? "Copy Private" : "Copy Share")
                            )
                            .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                            .lineLimit(1)
                        }
                        .foregroundStyle((copiedShare || copiedPrivate) ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.hit - 2)
                        .background(
                            (copiedShare || copiedPrivate) ? CobaltColor.success : Color.white,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        usingLeveledShareLink
                            ? (currentFileLink == .private ? "Copy Leveled Private Share Link" : "Copy Leveled Share Link")
                            : (currentFileLink == .private ? "Copy Private Share Link" : "Copy Share Link")
                    )

                    if hasPair && currentFileLink != .private {
                        Button {
                            copyLink(url, form: .direct)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedDirect ? Symbol.Media.copied : Symbol.LinkPair.direct)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(copiedDirect ? Copy.Media.copied : "Direct")
                                    .font(Font.cobalt(13, .medium, relativeTo: .subheadline))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Metrics.hit - 2)
                            .background(
                                copiedDirect ? CobaltColor.success.opacity(0.85) : Color.white.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(usingLeveledShareLink ? "Copy Leveled Direct Link" : Copy.LinkPair.copyDirectLink)
                    }

                    shareSystemButton(url: url)
                } else if isHidden {
                    Button {
                        askingVisibility = .unhide
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Symbol.HiddenRules.unhide)
                            Text(Copy.Hidden.unhide)
                                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.hit - 2)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(visibilityChanging)
                } else if usesPostVisibilitySwitch || model.canChoosePrivateLink(rendition) || controller.canSwitchVisibility(rendition) {
                    Button {
                        chooseVisibility(.public)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Symbol.Media.isPublic)
                            Text("Make Public")
                                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.hit - 2)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(visibilityChanging)

                    if !usesPostVisibilitySwitch && model.canChoosePrivateLink(rendition) {
                        Button {
                            chooseVisibility(.private)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: Symbol.PrivateLinks.privateLink)
                                Text("Private")
                                    .font(Font.cobalt(13, .medium, relativeTo: .subheadline))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Metrics.hit - 2)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(visibilityChanging)
                    }

                    fileShareButton
                } else {
                    fileShareButton
                }
            }

            if offline {
                Text(Copy.Pane.offlineNote)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .padding(11)
        .mediaGlassRounded(cornerRadius: 20, interactive: false)
        .frame(maxWidth: 560)
    }

    private func dockAudioTab(title: String, active: Bool, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                .foregroundStyle(active ? .black : .white.opacity(0.76))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(active ? tint : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Compact momentary hold-to-hear-original pill inside the dock (never alters the share link).
    private var dockHoldOriginalPill: some View {
        HStack(spacing: 4) {
            Image(systemName: holdingOriginalAudio ? "ear.fill" : "ear")
                .font(.system(size: 10.5, weight: .semibold))
            Text(holdingOriginalAudio ? "Original" : "Hold orig")
                .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                .lineLimit(1)
        }
        .foregroundStyle(holdingOriginalAudio ? .black : .white.opacity(0.84))
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            holdingOriginalAudio ? Color(hex: 0xfbbf24) : Color.white.opacity(0.1),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(holdingOriginalAudio ? Color(hex: 0xfbbf24) : Color.white.opacity(0.16), lineWidth: 0.75)
        )
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !holdingOriginalAudio { holdingOriginalAudio = true }
                }
                .onEnded { _ in
                    if holdingOriginalAudio { holdingOriginalAudio = false }
                }
        )
        .accessibilityLabel("Hold to hear original audio")
        .accessibilityHint("Temporarily listens to original audio without changing the copied link.")
    }

    @ViewBuilder
    private func shareSystemButton(url: URL) -> some View {
        let targets = model.capabilities.shareTargets(for: rendition, file: rendition.isOnDevice)
        let localURL = rendition.isOnDevice ? rendition.local?.fileURL : nil
        if usingLeveledShareLink {
            let shareURL = resolvedAudioURL(url, form: .share)
            let directURL = resolvedAudioURL(url, form: .direct)
            if targets.forms.count > 1 {
                Menu {
                    ShareLink(item: shareURL) {
                        Label("Share Link (Leveled)", systemImage: Symbol.Media.copyLink)
                    }
                    if currentFileLink != .private {
                        ShareLink(item: directURL) {
                            Label("Direct Link (Leveled)", systemImage: Symbol.LinkPair.direct)
                        }
                    }
                    if let localURL {
                        ShareLink(item: localURL) {
                            Label("File", systemImage: Symbol.Media.share)
                        }
                    }
                } label: {
                    shareIconBox
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.share)
            } else {
                ShareLink(item: shareURL) {
                    shareIconBox
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.share)
            }
        } else if targets.forms.count > 1 {
            Menu {
                ShareChoiceMenuItems(targets: targets, fileURL: localURL)
            } label: {
                shareIconBox
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.share)
        } else {
            ShareLink(item: currentFileLink == .private ? url : model.capabilities.shareLink(for: url)) {
                shareIconBox
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.share)
        }
    }

    private var fileShareButton: some View {
        Button {
            kit.share([rendition])
        } label: {
            HStack(spacing: 6) {
                if controller.preparingShare {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: Symbol.Media.share)
                        .font(.system(size: 13.5, weight: .semibold))
                }
                Text(Copy.share)
                    .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.hit - 2)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.preparingShare)
        .accessibilityLabel(Copy.share)
    }

    private var shareIconBox: some View {
        Image(systemName: Symbol.Media.share)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Metrics.hit - 2, height: Metrics.hit - 2)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            )
    }

    private func statusPill(_ state: AmbientVisibilityState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.tint)
                .frame(width: 6, height: 6)
            Text(state.shortLabel.uppercased())
                .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                .tracking(0.5)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.32), lineWidth: 0.75))
    }

    // MARK: - Identity & 4-State Visibility Popover

    private var identityPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TITLE")
                    .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                HStack(spacing: 8) {
                    TextField(Copy.Library2.titleField, text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(Font.cobalt(13.5, .medium, relativeTo: .body))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .focused($editingTitle)
                        .onSubmit { commitRename() }
                        .onChange(of: renameDraft) { _, text in
                            let cut = RenameAlertText.capped(text)
                            if cut != text { renameDraft = cut }
                        }
                    Button {
                        commitRename()
                    } label: {
                        if renameSaving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(Copy.Library2.save)
                                .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameSaving || renameDraft == displayTitle)
                }
            }

            Divider()

            visibilityGridSection
        }
        .padding(14)
        .preferredColorScheme(.dark)
    }

    // MARK: - Creator Studio Deck (Docked Right on Wide / Separated Crease / Compact Sheet)

    private func dockedStudioDeck(topClearance: CGFloat = 0) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Studio Deck")
                    .font(Font.cobalt(14, .semibold, relativeTo: .headline))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    wideDeckOpen = false
                } label: {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.16), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                        }
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Studio Deck")
            }
            .padding(.horizontal, 14)
            .padding(.top, topClearance > 0 ? topClearance + 4 : 8)
            .padding(.bottom, 6)

            deckTabPicker
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                deckBody
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(.ultraThinMaterial)
        .background(Color(hex: 0x0c0c10).opacity(0.76))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.75)
        }
    }

    /// Half-Closed Tabletop / Book Crease separated deck (`DuoMediaOverlay` when `isSeparated == true`).
    private var separatedCreaseDeck: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                #if os(macOS)
                if showsCloseButton {
                    Button { context.leave() } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.close)
                    .accessibilityIdentifier("pane.close")
                }
                #endif

                HStack(spacing: 6) {
                    Circle().fill(visibilityState.tint).frame(width: 7, height: 7)
                    Text(displayTitle)
                        .font(Font.cobalt(13.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Button { ambientEnabled.toggle() } label: {
                    Image(systemName: ambientEnabled ? "sun.max.fill" : "sun.max")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(ambientEnabled ? Color(hex: 0xfde68a) : .white.opacity(0.72))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1), in: Circle())
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ambientEnabled ? "Turn off ambient cinema glow" : "Turn on ambient cinema glow")

                if hasTranscript, let subtitles {
                    Button { subtitles.toggle() } label: {
                        Image(systemName: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(captionsActive ? .black : .white)
                            .frame(width: 36, height: 36)
                            .background(captionsActive ? Color.white : Color.white.opacity(0.12), in: Circle())
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn)
                }
            }

            if item.detailTabs.count > 1 {
                renditionGlassStrip
            }

            dualURLDock

            deckTabPicker

            ScrollView {
                deckBody
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x0d0d11))
    }

    private var compactDeckSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                deckTabPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                ScrollView {
                    deckBody
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                }
            }
            .background(Color(hex: 0x0e0e12))
            .navigationTitle(displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DuoToolbarButton(title: Copy.done, systemImage: "checkmark") {
                        compactSheetOpen = false
                    }
                }
                .duoVisibilityPriority(.high)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var deckTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                let active = deckTab == tab
                Button {
                    deckTab = tab
                } label: {
                    Text(tab.title)
                        .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(active ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(active ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var deckBody: some View {
        switch deckTab {
        case .access:
            accessTabContent
        case .tools:
            toolsTabContent
        case .transcript:
            transcriptTabContent
        }
    }

    // MARK: Access Tab

    private var accessTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            visibilityGridSection

            // Private link details + copy + rotate key
            if !isHidden, !usesPostVisibilitySwitch, currentFileLink == .private, let pURL = model.privateURL(of: rendition) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label(Copy.PrivateLinks.link, systemImage: Symbol.PrivateLinks.lock)
                            .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                            .foregroundStyle(AmbientVisibilityState.private.tint)
                        Spacer(minLength: 4)
                        Button {
                            copyLink(pURL, form: .share)
                        } label: {
                            Label(
                                copiedPrivate ? Copy.Media.copied : Copy.PrivateLinks.copy,
                                systemImage: copiedPrivate ? Symbol.PrivateLinks.copied : Symbol.PrivateLinks.copy
                            )
                            .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                            .foregroundStyle(copiedPrivate ? CobaltColor.success : .white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            askingVisibility = .rotate
                        } label: {
                            Label(Copy.PrivateLinks.rotate, systemImage: Symbol.PrivateLinks.rotate)
                                .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                                .foregroundStyle(CobaltColor.errorText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(CobaltColor.errorText.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(visibilityChanging)
                    }

                    Text(FileLinkSection.display(pURL))
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.sharedInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let link = model.privateLink(of: rendition) {
                        HStack {
                            Text(Copy.PrivateLinks.openedCount(link.opened))
                            Spacer()
                            Text(FileLinkSection.when(link.createdAt))
                        }
                        .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
                .studioDeckCard(border: AmbientVisibilityState.private.tint.opacity(0.28))
            }

            // Inline filename rename card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StudioDeckSectionLabel(text: "FILENAME")
                    Spacer()
                    Text("\(renameDraft.unicodeScalars.count)/\(MediaTitle.maxLength)")
                        .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    TextField(Copy.Library2.titleField, text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(Font.cobalt(13, .medium, relativeTo: .body))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .focused($editingTitle)
                        .onSubmit { commitRename() }
                        .onAppear { renameDraft = displayTitle }
                        .onChange(of: displayTitle) { _, next in
                            if !editingTitle { renameDraft = next }
                        }
                        .onChange(of: renameDraft) { _, text in
                            let cut = RenameAlertText.capped(text)
                            if cut != text { renameDraft = cut }
                        }

                    if renameDraft != displayTitle {
                        Button {
                            commitRename()
                        } label: {
                            if renameSaving {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text(Copy.Library2.save)
                                    .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameSaving)
                    }
                }
            }
            .studioDeckCard()

            // Inline "on this device" offline card
            if model.store.canKeep, context.missingIndex == nil {
                StudioDeckOfflineCard(model: model, item: item, rendition: rendition)
            }

            // Inline "from the post" metadata & framed copies (video saved from a social post)
            if !context.isGalleryLike, rendition.kind == .video, model.canPostFrame(item) {
                StudioDeckPostFrameCard(model: model, item: item)
            }

            // Inline "what it's about" / search index / closest videos / names card
            if model.capabilities.search, let post = item.post {
                StudioDeckAboutCard(
                    model: model,
                    postKey: post.id,
                    refreshKey: item.titleText,
                    store: insightStore,
                    onOpenPost: openNeighbourPost,
                    onBeforeOpenName: { compactSheetOpen = false }
                )
            }

            // Inline booru find & linked source card
            if BooruFindSection.applies(model: model, item: item, rendition: rendition) {
                StudioDeckBooruCard(model: model, item: item, rendition: rendition)
            }
        }
    }

    /// Even 2-column visibility grid (fold-safe per Apple HIG).
    @ViewBuilder
    private var visibilityGridSection: some View {
        let postSwitch = usesPostVisibilitySwitch
        let supportsPrivate = !postSwitch && model.canChoosePrivateLink(rendition)
        let supportsBasic = !postSwitch && controller.canSwitchVisibility(rendition)
        if postSwitch || supportsPrivate || supportsBasic {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StudioDeckSectionLabel(text: "VISIBILITY & ACCESS")
                    Spacer()
                    Text(visibilityStatusHeader)
                        .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(visibilityState.tint)
                        .monospacedDigit()
                }

                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    visibilityTile(.public)
                    if supportsPrivate {
                        visibilityTile(.private)
                    }
                    visibilityTile(.off)
                    if (supportsPrivate || postSwitch) && canHide {
                        visibilityTile(.hidden)
                    }
                }
                .disabled(visibilityChanging || controller.isDeleting)

                if isHidden, let post = livePost {
                    StudioDeckHairline()
                    HStack(spacing: 8) {
                        HiddenByRow(model: model, post: post)
                            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                        Button {
                            askingVisibility = .unhide
                        } label: {
                            Label(Copy.Hidden.unhide, systemImage: Symbol.HiddenRules.unhide)
                                .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(visibilityChanging || controller.isDeleting)
                    }
                }

                if let failure = visibilityFailureMessage {
                    Text(failure)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                } else if visibilityChanging {
                    Text(Copy.PrivateLinks.working)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                } else {
                    Text(visibilityFootnote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                }
            }
            .studioDeckCard()
        }
    }

    private var visibilityStatusHeader: String {
        if usesPostVisibilitySwitch, !isHidden {
            let links = controller.publicLinks(of: item)
            return controller.isPostPublic(item) ? Copy.Gallery.publicLinks(links) : Copy.Gallery.privateNoLinks
        }
        return visibilityState.shortLabel
    }

    private var visibilityFailureMessage: String? {
        if usesPostVisibilitySwitch {
            return controller.visibilityFailed[DetailController.postKey] ?? controller.visibilityFailed[rendition.id]
        }
        return controller.visibilityFailed[rendition.id]
    }

    private func visibilityTile(_ choice: AmbientVisibilityState) -> some View {
        let active = visibilityState == choice
        return Button {
            chooseVisibility(choice)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(choice.tint)
                    .frame(width: 7, height: 7)
                Text(choice.shortLabel)
                    .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(choice.tint)
                }
            }
            .foregroundStyle(active ? .white : .white.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(minHeight: Metrics.hit - 4)
            .background(
                active ? choice.tint.opacity(0.18) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? choice.tint.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var visibilityFootnote: String {
        switch visibilityState {
        case .public: return Copy.Media.publicOn
        case .private: return Copy.PrivateLinks.footnote
        case .off:
            if usesPostVisibilitySwitch, controller.visibilityCacheNote.contains(DetailController.postKey) {
                return "\(Copy.Media.publicOff) \(Copy.Media.cacheNote)"
            }
            return Copy.Media.publicOff
        case .hidden: return Copy.Hidden.note
        }
    }

    // MARK: Tools Tab (Even 2-Column Fold-Safe Creator Action Grid + Metadata)

    private var toolsTabContent: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return VStack(alignment: .leading, spacing: 14) {
            if showAudioLevelingUI, let fileID = activeAudioFileID {
                StudioDeckAudioLoudnessCard(
                    model: model,
                    fileID: fileID,
                    audio: activeAudio,
                    useLeveled: $useLeveledAudio,
                    holdingOriginal: $holdingOriginalAudio,
                    offline: offline,
                    onToast: { showToast($0) }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                StudioDeckSectionLabel(text: "STUDIO ACTIONS")

                LazyVGrid(columns: columns, spacing: 8) {
                    if controller.canMakeWebp(item) {
                        toolTile(
                            title: item.webpCount > 0 ? "Another WebP" : "Make WebP",
                            symbol: Symbol.Media.makeWebp
                        ) {
                            compactSheetOpen = false
                            context.leave()
                            shell.makeWebp(item)
                        }
                    }

                    if item.detailShape == .gallery {
                        let availability = controller.makeAvailability(item)
                        toolTile(
                            title: DetailWords.makeFromPost,
                            symbol: Symbol.Gallery.make
                        ) {
                            compactSheetOpen = false
                            controller.showsMakeSheet = true
                        }
                        .disabled(availability != .ready || controller.isDeleting)
                    }

                    if RenditionPhotos.canSave(rendition) {
                        let state = controller.photos[rendition.id] ?? .idle
                        let placed = controller.placement(of: rendition, in: item) != .none
                        toolTile(
                            title: saveButtonTitle(state: state, placed: placed),
                            symbol: (state == .done || placed) ? Symbol.checkmark : saveButtonSymbol,
                            working: state == .working,
                            done: state == .done || placed
                        ) {
                            Task {
                                await controller.savePhotos(rendition, in: item)
                                if controller.photos[rendition.id] == .done {
                                    showToast(Copy.savedPhotos)
                                }
                            }
                        }
                        .disabled(state == .working || placed)
                    }

                    if rendition.kind == .video, let target = PostFrameTarget.item(item, model: model) {
                        toolTile(title: "Post Frame", symbol: Symbol.PostFrame.frame) {
                            compactSheetOpen = false
                            controller.postFrameTarget = target
                        }
                    }

                    if let add = kit.addToLinkAction(item) {
                        toolTile(title: add.title, symbol: add.systemImage) {
                            compactSheetOpen = false
                            add.perform()
                        }
                        .disabled(add.isDisabled || (add.needsServer && offline && !add.queuesOffline))
                    }

                    if let edit = kit.editAction(item) {
                        toolTile(title: edit.title, symbol: edit.systemImage, working: kit.state.creatingEdit) {
                            compactSheetOpen = false
                            edit.perform()
                        }
                        .disabled(edit.isDisabled || (edit.needsServer && offline && !edit.queuesOffline))
                    }

                    if model.capabilities.chat, item.post != nil, !isHidden {
                        toolTile(title: Copy.Chat.askAbout, symbol: Symbol.chatAsk) {
                            compactSheetOpen = false
                            kit.askAbout(item)
                        }
                        .disabled(offline)
                    }

                    if let openLib = kit.openInLibraryAction(item) {
                        toolTile(title: openLib.title, symbol: openLib.systemImage) {
                            compactSheetOpen = false
                            openLib.perform()
                        }
                    }

                    toolTile(title: Copy.share, symbol: Symbol.Media.share, working: controller.preparingShare) {
                        compactSheetOpen = false
                        kit.share([rendition])
                    }
                    .disabled(controller.preparingShare)
                }

                if offline {
                    Text(Copy.Pane.offlineNote)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            // Asset Info metadata card
            if let missing = context.missingIndex {
                MissingInfo(item: item, index: missing)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                let rows = DetailMeta.rows(rendition, in: item)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ASSET INFO")
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)

                        ForEach(rows, id: \.label) { row in
                            HStack {
                                Text(row.label)
                                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(row.value)
                                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if let delete = kit.deleteAction(item) {
                Button(role: .destructive) {
                    compactSheetOpen = false
                    delete.perform()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: delete.systemImage)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(delete.title)
                            .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                        Spacer()
                    }
                    .foregroundStyle(CobaltColor.errorText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.hit)
                    .background(CobaltColor.errorText.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(CobaltColor.errorText.opacity(0.24), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .disabled(delete.isDisabled)
            }
        }
    }

    private func toolTile(
        title: String, symbol: String, working: Bool = false, done: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if working {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(done ? CobaltColor.success : .white)
                    }
                }
                .frame(height: 20)

                Text(title)
                    .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .padding(11)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(done ? CobaltColor.success.opacity(0.45) : Color.white.opacity(0.1), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    private func saveButtonTitle(state: DetailController.Step, placed: Bool) -> String {
        if placed { return "In Photos" }
        #if os(macOS)
        return state == .done ? Copy.saved : "Save File…"
        #else
        return state == .done ? "Saved" : "Save Photos"
        #endif
    }

    private var saveButtonSymbol: String {
        #if os(macOS)
        return Symbol.saveAs
        #else
        return Symbol.Media.savePhotos
        #endif
    }

    // MARK: Transcript Tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if let subtitles, let transcript = subtitles.transcript {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(isOn: Binding(get: { captionsActive }, set: { _ in subtitles.toggle() })) {
                        Label("Live Captions", systemImage: Symbol.Subtitles.on)
                            .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                    }
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("TIMED TRANSCRIPT")
                        .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    SubtitleHeardList(session: subtitles, transcript: transcript)
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Actions & Visibility Transitions

    private func copyLink(_ url: URL, form: LinkForm) {
        let resolved = resolvedAudioURL(url, form: form)
        if currentFileLink == .private {
            Pasteboard.copy(resolved.absoluteString)
            controller.privateLinkCopied += 1
            copiedPrivate = true
            let token = controller.privateLinkCopied
            showToast(usingLeveledShareLink ? "Leveled private link copied" : Copy.PrivateLinks.copiedPrivate)
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                if controller.privateLinkCopied == token { copiedPrivate = false }
            }
        } else {
            controller.copyExact(resolved, for: rendition.id, form: form)
            if usingLeveledShareLink {
                showToast(form == .direct ? "Leveled direct link copied" : "Leveled share link copied")
            } else {
                showToast(form == .direct ? "Direct link copied" : "Share link copied")
            }
        }
    }

    private func commitRename() {
        guard !renameSaving else { return }
        let draft = renameDraft
        renameSaving = true
        Task {
            defer { renameSaving = false }
            do {
                try await model.rename(item, to: draft)
                editingTitle = false
                showToast("Title saved")
            } catch {
                showToast(Copy.Library2.renameFailed)
            }
        }
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            if toastToken == token { toast = nil }
        }
    }

    private func preloadPrivateLinks() async {
        guard model.capabilities.privateLinks else { return }
        let store = model.shareSets
        if store.state == .idle {
            await store.refresh()
        } else if !store.privateLoaded {
            try? await store.refreshPrivate()
        }
    }

    private func openNeighbourPost(_ post: LibraryPost) {
        compactSheetOpen = false
        if let onOpenPost {
            onOpenPost(post)
            return
        }
        #if os(iOS)
        if sizeClass == .compact {
            let media = model.mediaItem(for: post)
            openedNeighbour = OpenedMedia(item: media, initial: media.face.id)
            return
        }
        #endif
        model.revealInLibrary(postID: post.id)
    }

    private func chooseVisibility(_ choice: AmbientVisibilityState) {
        guard !visibilityChanging, choice != visibilityState else { return }

        if isHidden {
            askingVisibility = .unhide
            return
        }

        if usesPostVisibilitySwitch {
            switch choice {
            case .public:
                Task { await controller.setPostPublic(true, for: item) }
            case .off, .private:
                askingVisibility = .postMakePrivate
            case .hidden:
                let links = model.publicSets(containing: rendition).count
                askingVisibility = .hide(links: links)
            }
            return
        }

        if !model.canChoosePrivateLink(rendition) {
            if choice == .public {
                Task { await controller.setVisibility(rendition, public: true) }
            } else {
                askingVisibility = .basicMakePrivate
            }
            return
        }

        switch choice {
        case .hidden:
            let links = model.publicSets(containing: rendition).count
            askingVisibility = .hide(links: links)
        case .private:
            let links = model.publicSets(containing: rendition).map(\.id)
            askingVisibility = .turnOnPrivate(links: links)
        case .public:
            if currentFileLink == .private {
                askingVisibility = .toPublic
            } else {
                Task { await controller.setFileLink(rendition, to: .public) }
            }
        case .off:
            askingVisibility = .off
        }
    }

    private func visibilityDialogTitle(_ ask: AmbientVisibilityAsk?) -> String {
        switch ask {
        case .turnOnPrivate: return Copy.PrivateLinks.turnOnTitle
        case .rotate: return Copy.PrivateLinks.rotateTitle
        case .off: return Copy.PrivateLinks.offTitle
        case .toPublic: return Copy.PrivateLinks.toPublicTitle
        case .hide: return Copy.Hidden.hideTitle
        case .unhide: return Copy.Hidden.unhideTitle
        case .basicMakePrivate, .postMakePrivate: return Copy.Media.makePrivateTitle
        case nil: return ""
        }
    }

    private func visibilityDialogMessage(_ ask: AmbientVisibilityAsk) -> String {
        switch ask {
        case .turnOnPrivate(let links):
            return links.isEmpty ? Copy.PrivateLinks.turnOnMessage : Copy.PrivateLinks.turnOnMessage(inLinks: links.count)
        case .rotate: return Copy.PrivateLinks.rotateMessage
        case .off: return Copy.PrivateLinks.offMessage
        case .toPublic: return Copy.PrivateLinks.toPublicMessage
        case .hide(let links): return links > 0 ? Copy.Hidden.hideMessage(inLinks: links) : Copy.Hidden.hideMessage
        case .unhide: return Copy.Hidden.unhideMessage
        case .basicMakePrivate, .postMakePrivate: return Copy.Media.makePrivateMessage
        }
    }

    @ViewBuilder
    private func visibilityDialogButtons(_ ask: AmbientVisibilityAsk) -> some View {
        switch ask {
        case .turnOnPrivate(let links):
            if links.isEmpty {
                Button(Copy.PrivateLinks.turnOn) { turnOnPrivate(alsoMakePrivate: []) }
            } else {
                Button(Copy.PrivateLinks.alsoLinks) { turnOnPrivate(alsoMakePrivate: links) }
                Button(Copy.PrivateLinks.leaveOut) { turnOnPrivate(alsoMakePrivate: []) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .rotate:
            Button(Copy.PrivateLinks.rotateConfirm, role: .destructive) {
                Task {
                    if let link = await controller.rotateFileLink(rendition) {
                        Pasteboard.copy(link.url.absoluteString)
                        controller.privateLinkCopied += 1
                        showToast(Copy.PrivateLinks.copiedNewKey)
                    }
                }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .off:
            Button(Copy.PrivateLinks.offConfirm, role: .destructive) {
                Task { await controller.setFileLink(rendition, to: .off) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .toPublic:
            Button(Copy.PrivateLinks.toPublicConfirm, role: .destructive) {
                Task { await controller.setFileLink(rendition, to: .public) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .hide:
            Button(Copy.Hidden.hideConfirm, role: .destructive) {
                setPostStatus(.hidden)
            }
            Button(Copy.Hidden.cancel, role: .cancel) {}
        case .unhide:
            Button(Copy.Hidden.unhide) {
                setPostStatus(.off)
            }
            Button(Copy.Hidden.cancel, role: .cancel) {}
        case .basicMakePrivate:
            Button(Copy.Media.makePrivate, role: .destructive) {
                Task { await controller.setVisibility(rendition, public: false) }
            }
            Button(Copy.Media.keepPublic, role: .cancel) {}
        case .postMakePrivate:
            Button(Copy.Media.makePrivate, role: .destructive) {
                Task { await controller.setPostPublic(false, for: item) }
            }
            Button(Copy.Media.keepPublic, role: .cancel) {}
        }
    }

    private func turnOnPrivate(alsoMakePrivate links: [String]) {
        Task {
            if let link = await controller.setFileLink(rendition, to: .private, alsoMakePrivate: links) {
                Pasteboard.copy(link.url.absoluteString)
                controller.privateLinkCopied += 1
                showToast(Copy.PrivateLinks.copiedPrivate)
            }
        }
    }

    private func setPostStatus(_ status: PostStatus) {
        guard let post = livePost else { return }
        Task {
            let result = await controller.setPostStatus(status, post: post, key: rendition.id)
            if result.changed { showToast(result.words(for: status)) }
        }
    }
}

// MARK: - Ambient Cinema Media Canvas (Secondary in DuoMediaOverlay)

/// Secondary media slot inside `DuoMediaOverlay`. Reads `@Environment(\.duoOverlaySeparated)` and its own slot size
/// so the hero centers cleanly in flat, Book (horizontal fold), and Tabletop (vertical fold) postures while the
/// edge-to-edge `AmbientCinemaBackdrop` bleeds past all safe areas without clipping.
private struct AmbientCinemaCanvas: View {
    let context: DetailContext
    let backdropItem: MediaItem?
    let activeRendition: Rendition?
    let livePalette: AmbientPalette?
    let ambientEnabled: Bool
    let reserveRight: CGFloat

    @Environment(\.duoOverlaySeparated) private var isSeparated
    @State private var slotSize: CGSize = .zero

    private var isHorizontalSplit: Bool {
        isSeparated && slotSize.width > 0 && slotSize.height > slotSize.width * 1.05
    }

    private var isVerticalSplit: Bool {
        isSeparated && slotSize.height > 0 && slotSize.width >= slotSize.height * 1.05
    }

    var body: some View {
        let effectiveReserveRight: CGFloat = isSeparated ? 0 : reserveRight
        GeometryReader { slot in
            let topPad: CGFloat = isSeparated ? 14 : 68
            let bottomPad: CGFloat = isSeparated ? 14 : (context.item.detailTabs.count > 1 ? 156 : 112)
            let heroMaxH = max(180, slot.size.height - topPad - bottomPad)

            HStack(spacing: 0) {
                ZStack {
                    DetailHero(c: context, maxHeight: heroMaxH)
                }
                .padding(.horizontal, 12)
                .padding(.top, topPad)
                .padding(.bottom, bottomPad)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if effectiveReserveRight > 0 {
                    Color.clear
                        .frame(width: effectiveReserveRight)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { slotSize = $0 }
        .background {
            AmbientCinemaBackdrop(
                item: backdropItem,
                rendition: activeRendition,
                livePalette: livePalette,
                enabled: ambientEnabled,
                featherTrailing: effectiveReserveRight > 0 || isHorizontalSplit,
                featherBottom: isVerticalSplit
            )
        }
    }
}

// MARK: - Supporting Types

private enum AmbientDeckTab: String, Identifiable, Hashable {
    case access, tools, transcript
    var id: String { rawValue }
    var title: String {
        switch self {
        case .access: return "Access"
        case .tools: return "Tools"
        case .transcript: return "CC"
        }
    }
}

private enum AmbientVisibilityState: Equatable {
    case `public`, `private`, off, hidden

    var shortLabel: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .off: return "Off"
        case .hidden: return "Hidden"
        }
    }

    var tint: Color {
        switch self {
        case .public: return Color(hex: 0x34d399)
        case .private: return Color(hex: 0xfbbf24)
        case .off: return Color(hex: 0x9ca3af)
        case .hidden: return Color(hex: 0xc084fc)
        }
    }
}

private enum AmbientVisibilityAsk: Identifiable, Equatable {
    case turnOnPrivate(links: [String])
    case rotate
    case off
    case toPublic
    case hide(links: Int)
    case unhide
    case basicMakePrivate
    case postMakePrivate

    var id: String {
        switch self {
        case .turnOnPrivate: return "turnOnPrivate"
        case .rotate: return "rotate"
        case .off: return "off"
        case .toPublic: return "toPublic"
        case .hide: return "hide"
        case .unhide: return "unhide"
        case .basicMakePrivate: return "basicMakePrivate"
        case .postMakePrivate: return "postMakePrivate"
        }
    }
}
