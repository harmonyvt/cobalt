import CobaltKit
import SwiftUI

// A twitch stream in the screen pane (apple/CONTRACT-PANE.md section 5; APP-API-CONTRACT 70).
//
// One consistent watch surface in every posture and state — always composed of the same three parts:
//   1. the video / TV stage (`TwitchPlayer` or `TwitchTVCard`),
//   2. the unified stream bar (channel identity, live viewers/game, and the same compact glass icon controls, always attached
//      to the stage), and
//   3. full-height edge-to-edge live chat (`TwitchChatCard`, zero nested scroll views, composer pinned at the bottom).
//
// Layout across postures (`TwitchWatchLayout`):
// - folded iPhone / Duo wide `screen` / iPad & Mac column: stacked (16:9 stage -> stream bar -> full-height chat);
// - Duo tall `screen` / landscape iPhone sheet / iPad & Mac `span`: side-by-side (stage + stream bar left, chat right);
// - Duo `span` (`.split`): across the physical hinge via `PaneHalves` (stage + stream bar on screen 1, full-height chat on
//   screen 2);
// - closed while running (`.bar`): live mini-player thumb, channel title/subtitle, and play/pause.
//
// The app has one stream: the player is `TwitchPlayerHost.shared` (its web view moves between pages without a reload) and
// the chat is `model.twitch` (`TwitchStore`), so a page rebuilt for another shape (screen, span, bar) picks both up where
// they were. The page opens the channel when it appears; the pane's `PaneKeepAlive` lets go of the chat when the pane moves on.

struct TwitchStreamPage: View {
    let login: String
    let model: AppModel

    @Environment(Pane.self) private var pane
    @Environment(\.paneItem) private var paneItem
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHinge) private var hinge
    @Environment(\.paneOffline) private var offline
    @Environment(\.openURL) private var openURL
    @Environment(\.lifecycle) private var lifecycle
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosingTV = false
    @State private var containerSize: CGSize = .zero

    private var store: TwitchStore { model.twitch }
    private var host: TwitchPlayerHost { .shared }
    private var item: PaneItem { .stream(login) }
    /// The store holds this channel (not the one before it, while a new one opens).
    private var holdsChannel: Bool { store.channel == login }
    private var isLive: Bool { holdsChannel && store.stream != nil }

    var body: some View {
        Group {
            switch shape {
            case .bar:
                bar
            case .split:
                split
            case .tall, .wide:
                singleContainer
            }
        }
        .preference(key: PaneMoreKey.self, value: moreActions)
        .preference(key: PaneFloatingHeaderKey.self, value: false)
        .onChange(of: title, initial: true) { pane.reportTitle(title, for: paneItem) }
        .onAppear {
            store.open(login)
            pane.setRunning(true, for: item)
            // the chat and the TV belong to the item, not to this shape of its page (rebuilt for every shape change)
            if pane.holds(item) { pane.keepAlive("stream", for: item) { TwitchWatch(login: login, model: model) }.begin() }
        }
        .onChange(of: store.channel) { _, channel in
            // closed from somewhere else: nothing is playing any more
            if channel != login { pane.setRunning(false, for: item) }
        }
        .task { if model.sevenTv.status == nil { await model.sevenTv.load() } }
        // back from studio (a reconnect) or from the background: a session that could not chat is asked again
        .onChange(of: lifecycle.phase) { _, phase in
            if phase == .active { Task { await store.load() } }
        }
        #if os(iOS)
        // The TV (70.5): while this page is up, a mirrored screen shows capystore's own window with the stream.
        .background(TwitchTVAccessory(enabled: TwitchTV.shared.wanted).frame(width: 0, height: 0))
        .onChange(of: login) { TwitchTV.shared.refresh() }
        .sheet(isPresented: $choosingTV) {
            TwitchTVSheet().presentationDetents([.medium, .large])
        }
        #endif
    }

    // MARK: layouts

    /// Single-pane container (`.tall` or `.wide`): switches cleanly between stacked and side-by-side based on geometry.
    private var singleContainer: some View {
        let layout = TwitchWatchLayout.resolve(isWideShape: shape == .wide, size: containerSize)
        return Group {
            switch layout {
            case .stacked(let videoMaxHeight):
                VStack(spacing: 0) {
                    stackedStage(maxHeight: videoMaxHeight)
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
                        onClip: makeClip,
                        onTVTap: { choosingTV = true },
                        onStop: stop)
                    hairline(horizontal: true)
                    chatPanel
                }
            case .sideBySide(let chatWidth):
                HStack(spacing: 0) {
                    mediaPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    hairline(horizontal: false)
                    chatPanel
                        .frame(width: chatWidth)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .task(id: store.clipState) { await clearClipStateSoon() }
    }

    /// Spanned across two physical screens (Duo wide or Duo tall): stage + stream bar on screen 1, full-height chat on screen 2.
    private var split: some View {
        PaneHalves(hinge: hinge) {
            mediaPanel
                .environment(\.paneShape, .split(.media))
            chatPanel
                .environment(\.paneShape, .split(.details))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: store.clipState) { await clearClipStateSoon() }
    }

    /// Media half for side-by-side and dual-screen split layouts: full-area video stage with the unified stream bar docked below it.
    private var mediaPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                onTV ? CobaltColor.bg : Color.black
                playerOrTV(compact: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            hairline(horizontal: true)
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
                onClip: makeClip,
                onTVTap: { choosingTV = true },
                onStop: stop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func stackedStage(maxHeight: CGFloat?) -> some View {
        if onTV {
            playerOrTV(compact: true)
                .background(CobaltColor.bg)
        } else {
            ZStack {
                Color.black
                player
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: maxHeight)
            .clipped()
        }
    }

    private var chatPanel: some View {
        TwitchChatCard(model: model, delay: chatDelay)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Minimized running bar over the tabs: live mini-player thumb, channel title/subtitle, and one play/pause button.
    private var bar: some View {
        HStack(spacing: 12) {
            ZStack { barThumb }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { host.setPaused(host.isPlaying) } label: {
                Image(systemName: host.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #if os(iOS)
            .controlSize(.large)
            #endif
            .accessibilityLabel(host.isPlaying ? Copy.Twitch.pause : Copy.Twitch.play)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
    }

    private func hairline(horizontal: Bool) -> some View {
        Rectangle()
            .fill(CobaltColor.hairline)
            .frame(width: horizontal ? nil : 0.5, height: horizontal ? 0.5 : nil)
            .accessibilityHidden(true)
    }

    // MARK: words & actions

    private var title: String {
        (holdsChannel ? store.channelInfo?.displayName : nil) ?? login
    }

    private var subtitle: String? {
        guard holdsChannel else { return nil }
        if let s = store.stream {
            return [Copy.Twitch.watching(s.viewers), s.game].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return store.channelInfo != nil ? Copy.Twitch.offline : nil
    }

    /// Secondary actions handed to `PaneChrome`'s header `⋯` menu.
    private var moreActions: [PaneAction] {
        var out: [PaneAction] = []
        if let url = URL(string: "https://www.twitch.tv/\(login)") {
            out.append(PaneAction(Copy.Twitch.openOnTwitch, systemImage: Symbol.Twitch.open) { openURL(url) })
        }
        return out
    }

    private func makeClip() {
        Task { await store.clip { url in _ = model.queue.add([.link(url)], via: .paste) } }
    }

    private func clearClipStateSoon() async {
        guard store.clipState == .saved || store.clipState == .failed else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        store.acknowledgeClip()
    }

    /// Ends the stream: the chat closes, the player stops, and the pane hides (no bar: nothing is running).
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
        TwitchTV.shared.onTV
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

    /// The bar's thumb: the stream itself, playing in a 40 pt window (the sound stays on); its still while it is on the TV.
    @ViewBuilder private var barThumb: some View {
        if onTV, let url = store.channelInfo?.avatar {
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
/// connection and the TV's watch. A page rebuilt for another shape (screen, span, bar, a peek over it) picks it up again,
/// so neither is closed and reopened (the TV window would flicker); both end when the pane lets go of the stream.
@MainActor
private final class TwitchWatch: PaneKeptObject {
    private let login: String
    private let model: AppModel
    private var started = false

    init(login: String, model: AppModel) {
        self.login = login
        self.model = model
    }

    /// Idempotent: the first page to appear starts it.
    func begin() {
        guard !started else { return }
        started = true
        #if os(iOS)
        TwitchTV.shared.watchStarted(model)
        #endif
    }

    func paneReleased() {
        // another channel may have opened since: close only this one's chat
        if model.twitch.channel == login { model.twitch.close() }
        guard started else { return }
        started = false
        #if os(iOS)
        TwitchTV.shared.watchEnded()
        #endif
    }
}

/// Edge-to-edge live chat inside the stream pane, with 7TV "add to a set" presented as a sheet over the pane so the stream
/// stays mounted and playing underneath.
struct TwitchChatCard: View {
    let model: AppModel
    let delay: TimeInterval

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
        TwitchChatPane(model: model, delay: delay, showsLabel: false) { emote in
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

    var body: some View {
        PreviewHost(.happy, tab: .twitch) { model in
            AreaPageHost(item: .stream("ninja"), shape: shape, hinge: hinge) {
                TwitchStreamPage(login: "ninja", model: model)
            }
        }
    }
}

#Preview("twitch · folded portrait", traits: .fixedLayout(width: 402, height: 800)) {
    TwitchPageHost(shape: .tall)
}
#Preview("twitch · landscape phone", traits: .fixedLayout(width: 874, height: 380)) {
    TwitchPageHost(shape: .tall)
}
#Preview("twitch · duo wide screen", traits: .fixedLayout(width: 475, height: 669)) {
    TwitchPageHost(shape: .tall)
}
#Preview("twitch · duo wide span", traits: .fixedLayout(width: 951, height: 669)) {
    TwitchPageHost(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 475))
}
#Preview("twitch · duo tall screen", traits: .fixedLayout(width: 669, height: 475)) {
    TwitchPageHost(shape: .wide)
}
#Preview("twitch · duo tall span", traits: .fixedLayout(width: 669, height: 951)) {
    TwitchPageHost(shape: .split(.media), hinge: PaneHinge(axis: .horizontal, position: 475))
}
#Preview("twitch · pad / mac span", traits: .fixedLayout(width: 1100, height: 700)) {
    TwitchPageHost(shape: .wide)
}
#Preview("twitch · bar", traits: .fixedLayout(width: 402, height: 64)) {
    TwitchPageHost(shape: .bar)
}
#endif
