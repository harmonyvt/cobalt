import AVFoundation
import CobaltKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Studio Environment Context

/// Context passed from `DetailHero` into the full-screen viewer so the Liquid Glass HUD and Studio Inspector
/// operate on the live `MediaItem`, `Rendition`, and `DetailController` without stale snapshots.
@MainActor
struct FullScreenStudioContext {
    let controller: DetailController
    let itemID: MediaItem.ID
    let fallbackItem: MediaItem
    let renditionID: Rendition.ID
    let fallbackRendition: Rendition
    let leave: () -> Void

    var model: AppModel { controller.model }

    /// Live item resolved from `AppModel` so visibility, rename, and rendition updates appear immediately.
    var liveItem: MediaItem {
        model.paneMedia(id: itemID) ?? fallbackItem
    }

    /// Live rendition for `id` (defaults to the rendition that opened full screen).
    func liveRendition(id: Rendition.ID? = nil) -> Rendition {
        let item = liveItem
        let target = id ?? renditionID
        return item.rendition(id: target) ?? item.video ?? item.face
    }
}

private struct FullScreenStudioKey: EnvironmentKey {
    static var defaultValue: FullScreenStudioContext? { nil }
}

extension EnvironmentValues {
    var fullScreenStudio: FullScreenStudioContext? {
        get { self[FullScreenStudioKey.self] }
        set { self[FullScreenStudioKey.self] = newValue }
    }
}

// MARK: - Full-Screen Media Studio Viewer

/// The evolved full-screen video studio viewer: Liquid Glass top & bottom HUD, 1-tap Share Dock,
/// inline rename + 4-state visibility controls, Video/WebP toggle, live subtitles, media tools,
/// and native iPhone Duo `ArrangementView(.overlay)` fold adaptation on iOS 27.1+.
struct FullScreenStudioVideo: View {
    let url: URL
    let name: String
    let start: CMTime
    let close: (CMTime?) -> Void

    @Environment(\.fullScreenStudio) private var studio
    @Environment(\.subtitles) private var subtitles
    @Environment(\.shell) private var shell
    @Environment(\.lifecycle) private var lifecycle
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var player = AVPlayer()
    @State private var transport = HeroTransport()
    @State private var videoSampler = AmbientVideoSampler()
    @State private var muted = false
    @State private var audioClaimID = "studio.\(UUID().uuidString)"
    @State private var audioReleased = false
    @State private var loopObserver: NSObjectProtocol?

    @State private var viewingWebp = false
    @State private var ambientEnabled = true
    @State private var isSeparated = false
    @State private var stageSize: CGSize = .zero
    @State private var inspectorOpen = false
    @State private var inspectorTab: StudioInspectorTab = .access
    @State private var showIdentityPopover = false
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var grabbingStill = false
    @State private var renameDraft = ""
    @State private var renameSaving = false
    @State private var askingVisibility: StudioVisibilityAsk?
    @State private var copiedPrivate = false
    @FocusState private var editingTitle: Bool

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        studioRoot
            .preferredColorScheme(.dark)
            .task { await startPlayback() }
            .onDisappear { teardownPlayback() }
            .onChange(of: shouldSampleLiveVideo) { _, active in
                videoSampler.setActive(active)
            }
            .onChange(of: viewingWebp) { _, isWebp in
                if isWebp { videoSampler.resetForMediaChange() }
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ambientEnabled)
            .haptic(.impact(weight: .light), trigger: transport.endHits, enabled: haptics) { $0 > 0 }
            .haptic(.success, trigger: studio?.controller.copiedID, enabled: haptics) { $0 != nil }
            .haptic(.success, trigger: studio?.controller.privateLinkCopied ?? 0, enabled: haptics) { $0 > 0 }
    }

    // MARK: - Live Derived State

    private var liveItem: MediaItem? { studio?.liveItem }

    private var activeRendition: Rendition? {
        guard let studio else { return nil }
        if viewingWebp, let webp = studio.liveItem.webps.first {
            return webp
        }
        return studio.liveRendition()
    }

    private var firstWebp: Rendition? { liveItem?.webps.first }

    private var webpSource: AnimatedImageView.Source? {
        guard let webp = firstWebp else { return nil }
        if webp.isOnDevice, let local = webp.local?.fileURL {
            return .file(local)
        }
        if let remote = webp.publicURL ?? webp.file?.url {
            return HeroSource.animated(remote)
        }
        return nil
    }

    private var displayTitle: String {
        liveItem?.titleText ?? name
    }

    private var livePost: LibraryPost? {
        guard let studio, let rendition = activeRendition else { return nil }
        if let post = studio.liveItem.post { return post }
        let ids = Set([rendition.file?.id, rendition.hosted?.id].compactMap { $0 })
        guard !ids.isEmpty else { return nil }
        let holds: (LibraryPost) -> Bool = { $0.files.contains { ids.contains($0.id) } }
        return studio.model.library.posts.first(where: holds) ?? studio.model.library.hiddenPosts.first(where: holds)
    }

    private var canHide: Bool {
        guard let studio else { return false }
        return studio.model.capabilities.hidden && livePost != nil
    }

    private var isHidden: Bool {
        canHide && livePost?.hidden == true
    }

    private var currentFileLink: FileLink {
        guard let studio, let rendition = activeRendition else { return .off }
        if studio.model.canChoosePrivateLink(rendition) {
            return studio.model.fileLink(of: rendition)
        }
        return rendition.visibility == .public ? .public : .off
    }

    private var visibilityState: StudioVisibilityState {
        if isHidden { return .hidden }
        switch currentFileLink {
        case .public: return .public
        case .private: return .private
        case .off: return .off
        }
    }

    private var visibilityChanging: Bool {
        guard let studio, let rendition = activeRendition else { return false }
        return studio.model.isChangingVisibility(rendition) || studio.model.library.statusInFlight
    }

    private var liveShareURL: URL? {
        guard let studio, let rendition = activeRendition, !isHidden else { return nil }
        if currentFileLink == .private {
            return studio.model.privateURL(of: rendition) ?? rendition.privateURL
        }
        return rendition.privateURL ?? rendition.hosted?.url ?? rendition.publicURL
    }

    private var hasTranscript: Bool { subtitles?.available == true }

    private var captionsActive: Bool {
        guard let subtitles, subtitles.available else { return false }
        return subtitles.on || subtitles.forcedOn
    }

    private var hudVisible: Bool {
        voiceOver || transport.barShown || viewingWebp || inspectorOpen || showIdentityPopover || editingTitle
    }

    private var shouldSampleLiveVideo: Bool {
        ambientEnabled && !reduceMotion && lifecycle.isForeground && !viewingWebp
    }

    private var isHorizontalSplit: Bool {
        isSeparated && stageSize.width > 0 && stageSize.height > stageSize.width * 1.05
    }

    private var isVerticalSplit: Bool {
        isSeparated && stageSize.height > 0 && stageSize.width >= stageSize.height * 1.05
    }

    // MARK: - Adaptive Root (iPhone Duo ArrangementView on 27.1+ / Fallback on 26)

    @ViewBuilder
    private var studioRoot: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= DetailWidth.wide
            if #available(iOS 27.1, macOS 27.1, *) {
                ArrangementView {
                    StudioOverlayHost(
                        isWide: isWide,
                        onSeparatedChange: { separated in
                            if isSeparated != separated {
                                isSeparated = separated
                            }
                        },
                        floatingHUD: { floatingHUD(isWide: isWide, totalWidth: geo.size.width) },
                        separatedDeck: { separatedFoldDeck }
                    )
                    .overlayArrangementEdge(.bottom)
                    .overlayArrangementEdge(.trailing)
                } secondary: {
                    mediaStage(
                        dockedInspector: isWide && inspectorOpen && !isSeparated,
                        inspectorWidth: inspectorWidth(for: geo.size.width)
                    )
                    .overlayArrangementEdge(.top)
                    .overlayArrangementEdge(.leading)
                }
                .arrangementViewStyle(.overlay)
            } else {
                ZStack {
                    mediaStage(dockedInspector: isWide && inspectorOpen, inspectorWidth: inspectorWidth(for: geo.size.width))
                    floatingHUD(isWide: isWide, totalWidth: geo.size.width)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: compactInspectorBinding) {
            compactInspectorSheet
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mediaGlassCapsule(interactive: false)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: inspectorOpen)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: toast)
        .background(keyboardShortcuts)
    }

    private func inspectorWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * 0.33, 286), 340)
    }

    private var compactInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                #if os(macOS)
                return false
                #else
                return inspectorOpen && isCompactWidth
                #endif
            },
            set: { if !$0 { inspectorOpen = false } }
        )
    }

    @State private var isCompactWidth = false

    // MARK: - Media Stage (Secondary in ArrangementView)

    private func mediaStage(dockedInspector: Bool, inspectorWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Group {
                    if viewingWebp, let source = webpSource {
                        AnimatedImageView(source: source)
                            .aspectRatio(firstWebp?.knownAspect ?? 1, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PlayerSurface(player: player, gravity: .resizeAspect)
                            .ignoresSafeArea()
                    }
                }
                .mediaMask()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !viewingWebp else { return }
                    transport.tapped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if dockedInspector {
                Color.clear
                    .frame(width: inspectorWidth)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        .background {
            AmbientCinemaBackdrop(
                item: liveItem,
                rendition: activeRendition,
                livePalette: viewingWebp ? nil : videoSampler.livePalette,
                enabled: ambientEnabled,
                featherTrailing: dockedInspector || isHorizontalSplit,
                featherBottom: isVerticalSplit
            )
        }
    }

    // MARK: - Floating Liquid Glass HUD (Layered State: Outer, Inner Flat, iPad, Mac)

    private func floatingHUD(isWide: Bool, totalWidth: CGFloat) -> some View {
        let docked = isWide && inspectorOpen && studio != nil
        let sidebarW = inspectorWidth(for: totalWidth)
        return HStack(spacing: 0) {
            ZStack {
                // Edge vignettes keep glass pills readable over bright or dark frames
                VStack(spacing: 0) {
                    MediaEdgeVignette(edge: .top, height: 112, intensity: 0.44)
                    Spacer(minLength: 0)
                    MediaEdgeVignette(edge: .bottom, height: studio != nil ? 196 : 120, intensity: 0.50)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(hudVisible ? 1 : 0)

                VStack(spacing: 0) {
                    topGlassBar
                        .opacity(hudVisible ? 1 : 0)
                        .allowsHitTesting(hudVisible)

                    Spacer(minLength: 0)

                    // Live word-highlighted subtitles float cleanly above the bottom deck
                    if !viewingWebp, captionsActive, let transcript = subtitles?.transcript {
                        SubtitleLineText(transcript: transcript, time: transport.time, onPicture: true)
                            .padding(.horizontal, 18)
                            .padding(.bottom, hudVisible ? 12 : 24)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    VStack(spacing: 10) {
                        if !viewingWebp {
                            studioTransportBar
                        }
                        if studio != nil {
                            quickShareDock
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .opacity(hudVisible ? 1 : 0)
                    .allowsHitTesting(hudVisible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hudVisible)

            if docked {
                dockedInspectorPane
                    .frame(width: sidebarW)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: isWide, initial: true) { _, wide in
            isCompactWidth = !wide
        }
    }

    // MARK: - Top Glass Bar

    private var topGlassBar: some View {
        MediaGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { finish() } label: {
                    Label(Copy.Media.exitFullScreen, systemImage: Symbol.close)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .mediaGlassCircle()
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Media.exitFullScreen)

                identityVisibilityPill

                Spacer(minLength: 6)

                rightGlassGroup
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Unified status dot + filename + quick visibility/rename popover (compact, single-line).
    private var identityVisibilityPill: some View {
        Button {
            if studio != nil {
                renameDraft = displayTitle
                showIdentityPopover = true
                transport.reveal()
            }
        } label: {
            HStack(spacing: 7) {
                if studio != nil {
                    Circle()
                        .fill(visibilityState.tint)
                        .frame(width: 8, height: 8)
                        .shadow(color: visibilityState.tint.opacity(0.65), radius: 3)
                }
                Text(displayTitle)
                    .font(Font.cobalt(13.5, .medium, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if studio != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .mediaGlassCapsule()
        }
        .buttonStyle(.plain)
        .disabled(studio == nil)
        .popover(isPresented: $showIdentityPopover, arrowEdge: .top) {
            identityPopoverContent
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var rightGlassGroup: some View {
        MediaGlassGroup(spacing: 6) {
            HStack(spacing: 4) {
                if webpSource != nil {
                    Button {
                        toggleMediaFormat()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewingWebp ? "sparkles.rectangle.stack" : "film")
                                .font(.system(size: 12, weight: .semibold))
                            Text(viewingWebp ? "WebP" : "Video")
                                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(viewingWebp ? CobaltColor.linkBlue.opacity(0.35) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewingWebp ? "Switch to video" : "Preview WebP")
                }

                if hasTranscript, let subtitles {
                    Button {
                        subtitles.toggle()
                        transport.reveal()
                    } label: {
                        Image(systemName: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(captionsActive ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(captionsActive ? Color.white : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(captionsActive ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn)
                }

                if studio != nil {
                    Button {
                        ambientEnabled.toggle()
                        transport.reveal()
                    } label: {
                        Image(systemName: ambientEnabled ? "sun.max.fill" : "sun.max")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ambientEnabled ? Color(hex: 0xfde68a) : .white.opacity(0.75))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ambientEnabled ? "Turn off ambient cinema glow" : "Turn on ambient cinema glow")

                    Button {
                        inspectorOpen.toggle()
                        transport.reveal()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(inspectorOpen ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(inspectorOpen ? Color.white : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(inspectorOpen ? "Hide Studio Inspector" : "Show Studio Inspector")
                }

                Menu {
                    if !viewingWebp {
                        Button("Grab Still Frame", systemImage: "camera.viewfinder") {
                            Task { await grabCurrentStill() }
                        }
                    }
                    if let studio, let url = liveShareURL, let r = activeRendition {
                        Button(
                            studio.model.capabilities.hasLinkPair(url) ? Copy.LinkPair.copyShareLink : Copy.copyLink,
                            systemImage: Symbol.Media.copyLink
                        ) {
                            copyLink(url, rendition: r, form: .share)
                        }
                        if studio.model.capabilities.hasLinkPair(url) {
                            Button(Copy.LinkPair.copyDirectLink, systemImage: Symbol.LinkPair.direct) {
                                copyLink(url, rendition: r, form: .direct)
                            }
                        }
                    }
                    if studio != nil {
                        Divider()
                        Button(Copy.Library2.rename, systemImage: Symbol.Library.rename) {
                            renameDraft = displayTitle
                            showIdentityPopover = true
                        }
                        Button(inspectorOpen ? "Hide Inspector" : "Open Studio Inspector", systemImage: "sidebar.right") {
                            inspectorOpen.toggle()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Media.more)
            }
            .padding(3)
            .mediaGlassCapsule(interactive: false)
        }
    }

    // MARK: - Tactile Liquid Glass Transport Bar

    private var studioTransportBar: some View {
        HStack(spacing: 8) {
            Button {
                transport.togglePlay()
            } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transport.isPlaying ? Copy.Media.pause : Copy.Media.play)

            Text(HeroClock.text(transport.time))
                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()

            StudioScrubber(transport: transport)
                .frame(minWidth: 72, maxWidth: .infinity)

            Text(HeroClock.text(transport.duration))
                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize()

            Button {
                Task { await grabCurrentStill() }
            } label: {
                Group {
                    if grabbingStill {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(grabbingStill)
            .accessibilityLabel("Grab still frame")

            Button {
                toggleMute()
            } label: {
                Image(systemName: muted ? Symbol.soundOff : Symbol.soundOn)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? Copy.soundOn : Copy.soundOff)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .mediaGlassCapsule(interactive: false)
    }

    // MARK: - 1-Tap Quick Share Dock

    @ViewBuilder
    private var quickShareDock: some View {
        if let studio, let rendition = activeRendition {
            let caps = studio.model.capabilities
            let url = liveShareURL
            let hasPair = url.map { caps.hasLinkPair($0) } ?? false
            let justCopied = studio.controller.copiedID == rendition.id
            let copiedShare = justCopied && studio.controller.copiedForm != .direct
            let copiedDirect = justCopied && studio.controller.copiedForm == .direct

            VStack(spacing: 8) {
                // Status badge + live link preview row
                HStack(spacing: 8) {
                    statusPill(visibilityState)

                    if let url {
                        let shown = currentFileLink == .private
                            ? FileLinkSection.display(url)
                            : DetailMeta.linkText(caps.shareLink(for: url))
                        Text(shown)
                            .font(Font.cobalt(12, .medium, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text(isHidden ? Copy.Hidden.rowDetail : Copy.PrivateLinks.offDetail)
                            .font(Font.cobalt(12, .regular, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if visibilityChanging {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                }

                // Action buttons row
                HStack(spacing: 8) {
                    if let url {
                        // Primary prominent CTA: Copy Share (or Copy Private)
                        Button {
                            copyLink(url, rendition: rendition, form: .share)
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
                            .frame(height: 38)
                            .background(
                                (copiedShare || copiedPrivate) ? CobaltColor.success : Color.white,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)

                        if hasPair && currentFileLink != .private {
                            Button {
                                copyLink(url, rendition: rendition, form: .direct)
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
                                .frame(height: 38)
                                .background(
                                    copiedDirect ? CobaltColor.success.opacity(0.85) : Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        shareSystemButton(studio: studio, rendition: rendition, url: url)
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
                            .frame(height: 38)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(visibilityChanging)
                    } else if studio.model.canChoosePrivateLink(rendition) || studio.controller.canSwitchVisibility(rendition) {
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
                            .frame(height: 38)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(visibilityChanging)

                        if studio.model.canChoosePrivateLink(rendition) {
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
                                .frame(height: 38)
                                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(visibilityChanging)
                        }
                    }
                }
            }
            .padding(11)
            .mediaGlassRounded(cornerRadius: 20, interactive: false)
            .frame(maxWidth: 560)
        }
    }

    @ViewBuilder
    private func shareSystemButton(studio: FullScreenStudioContext, rendition: Rendition, url: URL) -> some View {
        let targets = studio.model.capabilities.shareTargets(for: rendition, file: rendition.isOnDevice)
        let localURL = rendition.isOnDevice ? rendition.local?.fileURL : nil
        if targets.forms.count > 1 {
            Menu {
                ShareChoiceMenuItems(targets: targets, fileURL: localURL)
            } label: {
                shareButtonIcon
            }
            .buttonStyle(.plain)
        } else {
            ShareLink(item: currentFileLink == .private ? url : studio.model.capabilities.shareLink(for: url)) {
                shareButtonIcon
            }
            .buttonStyle(.plain)
        }
    }

    private var shareButtonIcon: some View {
        Image(systemName: Symbol.Media.share)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
            )
    }

    private func statusPill(_ state: StudioVisibilityState) -> some View {
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

    // MARK: - Identity & Quick Visibility Popover

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

    // MARK: - Studio Inspector (Docked Sidebar & Compact Sheet)

    private var dockedInspectorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Studio")
                    .font(Font.cobalt(14, .semibold, relativeTo: .headline))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    inspectorOpen = false
                } label: {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Inspector")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            inspectorTabPicker
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                inspectorBody
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.52))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 0.75)
        }
    }

    private var compactInspectorSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inspectorTabPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                ScrollView {
                    inspectorBody
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DuoToolbarButton(title: Copy.done, systemImage: "checkmark") { inspectorOpen = false }
                }
                .duoVisibilityPriority(.high)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - iPhone Duo Separated Fold Deck (overlayArrangementZIndex == 0)

    private var separatedFoldDeck: some View {
        VStack(spacing: 10) {
            // Compact deck header: Close + unified status/title + Format + CC
            HStack(spacing: 8) {
                Button { finish() } label: {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Media.exitFullScreen)

                HStack(spacing: 6) {
                    if studio != nil {
                        Circle().fill(visibilityState.tint).frame(width: 7, height: 7)
                    }
                    Text(displayTitle)
                        .font(Font.cobalt(13.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if webpSource != nil {
                    Button { toggleMediaFormat() } label: {
                        Text(viewingWebp ? "WebP" : "Video")
                            .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(viewingWebp ? CobaltColor.linkBlue.opacity(0.4) : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if hasTranscript, let subtitles {
                    Button { subtitles.toggle() } label: {
                        Image(systemName: captionsActive ? Symbol.Subtitles.on : Symbol.Subtitles.off)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(captionsActive ? .black : .white)
                            .frame(width: 32, height: 32)
                            .background(captionsActive ? Color.white : Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewingWebp {
                studioTransportBar
            }

            if studio != nil {
                quickShareDock

                inspectorTabPicker

                ScrollView {
                    inspectorBody
                        .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x0d0d10))
    }

    // MARK: - Inspector Tabs & Content

    private var inspectorTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                let active = inspectorTab == tab
                Button {
                    inspectorTab = tab
                } label: {
                    Text(tab.title)
                        .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(active ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(active ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var availableTabs: [StudioInspectorTab] {
        hasTranscript ? [.access, .tools, .transcript] : [.access, .tools]
    }

    @ViewBuilder
    private var inspectorBody: some View {
        switch inspectorTab {
        case .access:
            accessInspectorTab
        case .tools:
            toolsInspectorTab
        case .transcript:
            transcriptInspectorTab
        }
    }

    // MARK: Access Tab

    private var accessInspectorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            visibilityGridSection

            // Private link details card when active
            if let studio, let rendition = activeRendition, !isHidden, currentFileLink == .private,
               let pURL = studio.model.privateURL(of: rendition) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(Copy.PrivateLinks.link, systemImage: Symbol.PrivateLinks.lock)
                            .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                            .foregroundStyle(StudioVisibilityState.private.tint)
                        Spacer()
                        Button(role: .destructive) {
                            askingVisibility = .rotate
                        } label: {
                            Label(Copy.PrivateLinks.rotate, systemImage: Symbol.PrivateLinks.rotate)
                                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CobaltColor.errorText)
                        .disabled(visibilityChanging)
                    }

                    Text(FileLinkSection.display(pURL))
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.linkBlue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let link = studio.model.privateLink(of: rendition) {
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
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StudioVisibilityState.private.tint.opacity(0.24), lineWidth: 0.75)
                )
            }

            // Inline rename card
            if studio != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("FILENAME")
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
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
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// Even 2-column visibility grid (fold-safe per Apple HIG).
    @ViewBuilder
    private var visibilityGridSection: some View {
        if let studio, let rendition = activeRendition {
            let supportsPrivate = studio.model.canChoosePrivateLink(rendition)
            let supportsBasic = studio.controller.canSwitchVisibility(rendition)
            if supportsPrivate || supportsBasic {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("VISIBILITY & ACCESS")
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
                        Spacer()
                        Text(visibilityState.shortLabel)
                            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                            .foregroundStyle(visibilityState.tint)
                    }

                    let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                    LazyVGrid(columns: columns, spacing: 8) {
                        visibilityTile(.public)
                        if supportsPrivate {
                            visibilityTile(.private)
                        }
                        visibilityTile(.off)
                        if supportsPrivate && canHide {
                            visibilityTile(.hidden)
                        }
                    }
                    .disabled(visibilityChanging || studio.controller.isDeleting)

                    if let failure = studio.controller.visibilityFailed[rendition.id] {
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
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .task(id: rendition.id) {
                    await preloadPrivateLinks(studio: studio)
                }
            }
        }
    }

    private func visibilityTile(_ choice: StudioVisibilityState) -> some View {
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
            .foregroundStyle(active ? .white : .white.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: 38)
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
        case .off: return Copy.Media.publicOff
        case .hidden: return Copy.Hidden.note
        }
    }

    // MARK: Tools Tab

    private var toolsInspectorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let studio, let item = liveItem, let rendition = activeRendition {
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                VStack(alignment: .leading, spacing: 8) {
                    Text("STUDIO TOOLS")
                        .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    LazyVGrid(columns: columns, spacing: 8) {
                        if studio.controller.canMakeWebp(item) {
                            toolTile(
                                title: item.webpCount > 0 ? "Another WebP" : "Make WebP",
                                symbol: Symbol.Media.makeWebp
                            ) {
                                finish()
                                studio.leave()
                                shell.makeWebp(item)
                            }
                        }

                        if RenditionPhotos.canSave(rendition) {
                            let state = studio.controller.photos[rendition.id] ?? .idle
                            let placed = studio.controller.placement(of: rendition, in: item) != .none
                            toolTile(
                                title: saveButtonTitle(state: state, placed: placed),
                                symbol: (state == .done || placed) ? Symbol.checkmark : saveButtonSymbol,
                                working: state == .working,
                                done: state == .done || placed
                            ) {
                                Task {
                                    await studio.controller.savePhotos(rendition, in: item)
                                    if studio.controller.photos[rendition.id] == .done {
                                        showToast(Copy.savedPhotos)
                                    }
                                }
                            }
                            .disabled(state == .working || placed)
                        }

                        if !viewingWebp {
                            toolTile(
                                title: "Grab Still",
                                symbol: "camera.viewfinder",
                                working: grabbingStill
                            ) {
                                Task { await grabCurrentStill() }
                            }
                            .disabled(grabbingStill)
                        }

                        if rendition.kind == .video, let target = PostFrameTarget.item(item, model: studio.model) {
                            toolTile(title: "Post Frame", symbol: Symbol.PostFrame.frame) {
                                studio.controller.postFrameTarget = target
                                finish()
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Asset Info rows
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
    private var transcriptInspectorTab: some View {
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

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcuts: some View {
        Group {
            Button("") { finish() }
                .keyboardShortcut(.cancelAction)
            if !editingTitle {
                Button("") {
                    guard !viewingWebp else { return }
                    transport.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])

                if let url = liveShareURL, let r = activeRendition {
                    Button("") { copyLink(url, rendition: r, form: .share) }
                        .keyboardShortcut("c", modifiers: .command)
                    if let studio, studio.model.capabilities.hasLinkPair(url) {
                        Button("") { copyLink(url, rendition: r, form: .direct) }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }

                if studio != nil {
                    Button("") { inspectorOpen.toggle() }
                        .keyboardShortcut("i", modifiers: [])
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Playback Lifecycle

    private func startPlayback() async {
        AudioPolicy.playback(id: audioClaimID)
        let item = KeyedStream.item(url)
        player.replaceCurrentItem(with: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }
        await item.seek(to: start.isValid ? start : .zero)
        transport.attach(player)
        videoSampler.attach(player: player)
        videoSampler.setActive(shouldSampleLiveVideo)
        subtitles?.adopt(transport)
        PlayerPool.shared.play(player, as: .hero)
    }

    private func teardownPlayback() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        videoSampler.tearDown()
        subtitles?.release(transport)
        transport.detach()
        player.pause()
        PlayerPool.shared.forget(player)
        player.replaceCurrentItem(with: nil)
        releaseAudio()
    }

    private func finish() {
        let time = player.currentTime()
        player.pause()
        releaseAudio()
        close(time.isValid ? time : nil)
    }

    private func releaseAudio() {
        guard !audioReleased else { return }
        audioReleased = true
        AudioPolicy.release(id: audioClaimID)
    }

    private func toggleMute() {
        muted.toggle()
        player.isMuted = muted
        if muted { AudioPolicy.release(id: audioClaimID) } else { AudioPolicy.playback(id: audioClaimID) }
        transport.reveal()
    }

    private func toggleMediaFormat() {
        viewingWebp.toggle()
        if viewingWebp {
            player.pause()
        } else {
            PlayerPool.shared.play(player, as: .hero)
        }
        transport.reveal()
    }

    // MARK: - Actions (Share, Visibility, Rename, Grab Still)

    private func copyLink(_ url: URL, rendition: Rendition, form: LinkForm) {
        guard let studio else { return }
        if currentFileLink == .private {
            Pasteboard.copy(url.absoluteString)
            studio.controller.privateLinkCopied += 1
            copiedPrivate = true
            let token = studio.controller.privateLinkCopied
            showToast(Copy.PrivateLinks.copiedPrivate)
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                if studio.controller.privateLinkCopied == token { copiedPrivate = false }
            }
        } else {
            studio.controller.copy(url, for: rendition.id, form: form)
            showToast(form == .direct ? "Direct link copied" : "Share link copied")
        }
    }

    private func commitRename() {
        guard let studio, let item = liveItem, !renameSaving else { return }
        let draft = renameDraft
        renameSaving = true
        Task {
            defer { renameSaving = false }
            do {
                try await studio.model.rename(item, to: draft)
                editingTitle = false
                showToast("Title saved")
            } catch {
                showToast(Copy.Library2.renameFailed)
            }
        }
    }

    private func grabCurrentStill() async {
        guard !grabbingStill, let asset = player.currentItem?.asset else { return }
        grabbingStill = true
        defer { grabbingStill = false }
        let currentTime = player.currentTime()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: currentTime.isValid ? currentTime : .zero)
            copyStillToPasteboard(result.image)
            showToast("Still frame copied")
        } catch {
            showToast("Couldn't grab still frame")
        }
    }

    private func copyStillToPasteboard(_ cgImage: CGImage) {
        #if canImport(UIKit)
        UIPasteboard.general.image = UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #endif
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

    private func preloadPrivateLinks(studio: FullScreenStudioContext) async {
        guard studio.model.capabilities.privateLinks else { return }
        let store = studio.model.shareSets
        if store.state == .idle {
            await store.refresh()
        } else if !store.privateLoaded {
            try? await store.refreshPrivate()
        }
    }

    // MARK: - Visibility Transitions & Confirmations

    private func chooseVisibility(_ choice: StudioVisibilityState) {
        guard let studio, let rendition = activeRendition, !visibilityChanging else { return }
        guard choice != visibilityState else { return }

        if isHidden {
            askingVisibility = .unhide
            return
        }

        if !studio.model.canChoosePrivateLink(rendition) {
            if choice == .public {
                Task { await studio.controller.setVisibility(rendition, public: true) }
            } else {
                askingVisibility = .basicMakePrivate
            }
            return
        }

        switch choice {
        case .hidden:
            let links = studio.model.publicSets(containing: rendition).count
            askingVisibility = .hide(links: links)
        case .private:
            let links = studio.model.publicSets(containing: rendition).map(\.id)
            askingVisibility = .turnOnPrivate(links: links)
        case .public:
            if currentFileLink == .private {
                askingVisibility = .toPublic
            } else {
                Task { await studio.controller.setFileLink(rendition, to: .public) }
            }
        case .off:
            askingVisibility = .off
        }
    }

    private func visibilityDialogTitle(_ ask: StudioVisibilityAsk?) -> String {
        switch ask {
        case .turnOnPrivate: return Copy.PrivateLinks.turnOnTitle
        case .rotate: return Copy.PrivateLinks.rotateTitle
        case .off: return Copy.PrivateLinks.offTitle
        case .toPublic: return Copy.PrivateLinks.toPublicTitle
        case .hide: return Copy.Hidden.hideTitle
        case .unhide: return Copy.Hidden.unhideTitle
        case .basicMakePrivate: return Copy.Media.makePrivateTitle
        case nil: return ""
        }
    }

    private func visibilityDialogMessage(_ ask: StudioVisibilityAsk) -> String {
        switch ask {
        case .turnOnPrivate(let links):
            return links.isEmpty ? Copy.PrivateLinks.turnOnMessage : Copy.PrivateLinks.turnOnMessage(inLinks: links.count)
        case .rotate: return Copy.PrivateLinks.rotateMessage
        case .off: return Copy.PrivateLinks.offMessage
        case .toPublic: return Copy.PrivateLinks.toPublicMessage
        case .hide(let links): return links > 0 ? Copy.Hidden.hideMessage(inLinks: links) : Copy.Hidden.hideMessage
        case .unhide: return Copy.Hidden.unhideMessage
        case .basicMakePrivate: return Copy.Media.makePrivateMessage
        }
    }

    @ViewBuilder
    private func visibilityDialogButtons(_ ask: StudioVisibilityAsk) -> some View {
        if let studio, let rendition = activeRendition {
            switch ask {
            case .turnOnPrivate(let links):
                if links.isEmpty {
                    Button(Copy.PrivateLinks.turnOn) { turnOnPrivate(studio: studio, rendition: rendition, alsoMakePrivate: []) }
                } else {
                    Button(Copy.PrivateLinks.alsoLinks) { turnOnPrivate(studio: studio, rendition: rendition, alsoMakePrivate: links) }
                    Button(Copy.PrivateLinks.leaveOut) { turnOnPrivate(studio: studio, rendition: rendition, alsoMakePrivate: []) }
                }
                Button(Copy.PrivateLinks.cancel, role: .cancel) {}
            case .rotate:
                Button(Copy.PrivateLinks.rotateConfirm, role: .destructive) {
                    Task {
                        if let link = await studio.controller.rotateFileLink(rendition) {
                            Pasteboard.copy(link.url.absoluteString)
                            studio.controller.privateLinkCopied += 1
                            showToast(Copy.PrivateLinks.copiedNewKey)
                        }
                    }
                }
                Button(Copy.PrivateLinks.cancel, role: .cancel) {}
            case .off:
                Button(Copy.PrivateLinks.offConfirm, role: .destructive) {
                    Task { await studio.controller.setFileLink(rendition, to: .off) }
                }
                Button(Copy.PrivateLinks.cancel, role: .cancel) {}
            case .toPublic:
                Button(Copy.PrivateLinks.toPublicConfirm, role: .destructive) {
                    Task { await studio.controller.setFileLink(rendition, to: .public) }
                }
                Button(Copy.PrivateLinks.cancel, role: .cancel) {}
            case .hide:
                Button(Copy.Hidden.hideConfirm, role: .destructive) {
                    setPostStatus(.hidden, studio: studio, rendition: rendition)
                }
                Button(Copy.Hidden.cancel, role: .cancel) {}
            case .unhide:
                Button(Copy.Hidden.unhide) {
                    setPostStatus(.off, studio: studio, rendition: rendition)
                }
                Button(Copy.Hidden.cancel, role: .cancel) {}
            case .basicMakePrivate:
                Button(Copy.Media.makePrivate, role: .destructive) {
                    Task { await studio.controller.setVisibility(rendition, public: false) }
                }
                Button(Copy.Media.keepPublic, role: .cancel) {}
            }
        }
    }

    private func turnOnPrivate(studio: FullScreenStudioContext, rendition: Rendition, alsoMakePrivate links: [String]) {
        Task {
            if let link = await studio.controller.setFileLink(rendition, to: .private, alsoMakePrivate: links) {
                Pasteboard.copy(link.url.absoluteString)
                studio.controller.privateLinkCopied += 1
                showToast(Copy.PrivateLinks.copiedPrivate)
            }
        }
    }

    private func setPostStatus(_ status: PostStatus, studio: FullScreenStudioContext, rendition: Rendition) {
        guard let post = livePost else { return }
        Task {
            let result = await studio.controller.setPostStatus(status, post: post, key: rendition.id)
            if result.changed { showToast(result.words(for: status)) }
        }
    }
}

// MARK: - iPhone Duo ArrangementView Overlay Host (iOS 27.1+)

/// Nested child view inside `ArrangementView`'s `primary` closure so `@Environment(\.overlayArrangementZIndex)`
/// resolves reliably across flat (`> 0`) and folded Tabletop / Book (`== 0`) poses.
@available(iOS 27.1, macOS 27.1, *)
private struct StudioOverlayHost<Floating: View, Separated: View>: View {
    let isWide: Bool
    let onSeparatedChange: (Bool) -> Void
    @ViewBuilder let floatingHUD: () -> Floating
    @ViewBuilder let separatedDeck: () -> Separated

    @Environment(\.overlayArrangementZIndex) private var overlayZIndex

    var body: some View {
        let isSeparated = overlayZIndex == 0
        Group {
            if isSeparated {
                separatedDeck()
            } else {
                floatingHUD()
            }
        }
        .onChange(of: isSeparated, initial: true) { _, separated in
            onSeparatedChange(separated)
        }
    }
}

// MARK: - Supporting Types & Scrubber

private enum StudioInspectorTab: String, Identifiable, Hashable {
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

private enum StudioVisibilityState: Equatable {
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

private enum StudioVisibilityAsk: Identifiable, Equatable {
    case turnOnPrivate(links: [String])
    case rotate
    case off
    case toPublic
    case hide(links: Int)
    case unhide
    case basicMakePrivate

    var id: String {
        switch self {
        case .turnOnPrivate: return "turnOnPrivate"
        case .rotate: return "rotate"
        case .off: return "off"
        case .toPublic: return "toPublic"
        case .hide: return "hide"
        case .unhide: return "unhide"
        case .basicMakePrivate: return "basicMakePrivate"
        }
    }
}

/// Tactile scrubber tailored for the full-screen studio transport bar: live frame chase,
/// expanded thumb during drag, and VoiceOver 5-second adjustable steps.
private struct StudioScrubber: View {
    let transport: HeroTransport
    private let thumb: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let active = transport.isScrubbing
            let size = active ? thumb + 4 : thumb
            let travel = max(1, geo.size.width - size)
            let x = size / 2 + travel * transport.fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.26)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(0, x), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        transport.scrub(to: (value.location.x - size / 2) / travel)
                    }
                    .onEnded { _ in transport.endScrub() }
            )
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel(Copy.Media.scrubber)
        .accessibilityValue(Copy.Media.scrubberValue(HeroClock.text(transport.time), of: HeroClock.text(transport.duration)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: transport.skip(by: 5)
            case .decrement: transport.skip(by: -5)
            @unknown default: break
            }
        }
    }
}
