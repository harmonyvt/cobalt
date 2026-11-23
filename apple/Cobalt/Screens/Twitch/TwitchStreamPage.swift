import CobaltKit
import SwiftUI

// A twitch stream in the screen pane (apple/CONTRACT-PANE.md section 5; APP-API-CONTRACT 70). The player is the hero, the
// live chat is the shelf (stacked on the details screen when spanned over two screens, the right half when spanned wide).
// `keepsRunning`: the page tells the pane the stream is at work in every shape, so closing it leaves the bar, and the bar
// is the same stream playing in a small window with one play / pause button. Stopping is a button on the page.
//
// The app has one stream: the player is `TwitchPlayerHost.shared` (its web view moves between pages without a reload) and
// the chat is `model.twitch` (`TwitchStore`), so a page rebuilt for another shape (screen, span, bar) picks both up where
// they were. The page opens the channel when it appears; the lane's `PaneKeeps` lets go of the chat when the pane moved on.

struct TwitchStreamPage: View {
    let login: String
    let model: AppModel

    @Environment(Pane.self) private var pane
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight
    @Environment(\.openURL) private var openURL
    @Environment(\.lifecycle) private var lifecycle
    @State private var choosingTV = false

    private var store: TwitchStore { model.twitch }
    private var host: TwitchPlayerHost { .shared }
    private var item: PaneItem { .stream(login) }
    /// The store holds this channel (not the one before it, while a new one opens).
    private var holdsChannel: Bool { store.channel == login }

    var body: some View {
        PanePage(
            title: title, subtitle: subtitle, actions: actions
        ) {
            hero
        } controls: {
            controls
        } body: {
            clipNote
        } shelf: {
            PaneCard(Copy.Twitch.chat) {
                TwitchChatCard(model: model, delay: chatDelay)
            }
        }
        .onAppear {
            store.open(login)
            pane.setRunning(true, for: item)
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
        .paneKeeps(item) {
            if store.channel == login { store.close() }
        }
        #if os(iOS)
        // The TV (70.5): while this page is up, a mirrored screen shows capystore's own window with the stream.
        .background(TwitchTVAccessory(enabled: TwitchTV.shared.wanted).frame(width: 0, height: 0))
        .onAppear { TwitchTV.shared.watchStarted(model) }
        .onDisappear { TwitchTV.shared.watchEnded() }
        .onChange(of: login) { TwitchTV.shared.refresh() }
        .sheet(isPresented: $choosingTV) {
            TwitchTVSheet().presentationDetents([.medium, .large])
        }
        #endif
    }

    // MARK: words

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

    // MARK: actions

    /// The header's two icon buttons: where it is on twitch, and stop.
    private var actions: [PaneAction] {
        var out: [PaneAction] = []
        if let url = URL(string: "https://www.twitch.tv/\(login)") {
            out.append(PaneAction(Copy.Twitch.openOnTwitch, systemImage: Symbol.Twitch.open) { openURL(url) })
        }
        out.append(PaneAction(Copy.Twitch.stop, systemImage: "stop.fill") { stop() })
        return out
    }

    /// The big buttons: play / pause, back to live, a clip, the TV.
    private var gridActions: [PaneAction] {
        var out = [playPause]
        out.append(PaneAction(
            Copy.Twitch.jumpToLive, systemImage: Symbol.Twitch.jumpToLive, disabled: host.delay == nil || host.isCatchingUp
        ) { host.jumpToLive() })
        if store.canClip {
            out.append(PaneAction(
                Copy.Twitch.clip, systemImage: Symbol.Twitch.clip, needsServer: true, disabled: store.clipState == .making
            ) {
                Task { await store.clip { url in _ = model.queue.add([.link(url)], via: .paste) } }
            })
        }
        #if os(iOS)
        out.append(PaneAction(Copy.Twitch.watchOnTV, systemImage: Symbol.Twitch.tv) { choosingTV = true })
        #endif
        return out
    }

    private var playPause: PaneAction {
        PaneAction(
            host.isPlaying ? Copy.Twitch.pause : Copy.Twitch.play,
            systemImage: host.isPlaying ? "pause.fill" : "play.fill", id: "playpause"
        ) { host.setPaused(host.isPlaying) }
    }

    /// Ends the stream: the chat closes, the player stops, and the pane hides (no bar: nothing is running).
    private func stop() {
        store.close()
        host.stop()
        pane.setRunning(false, for: item)
        pane.close()
    }

    // MARK: slots

    @ViewBuilder private var hero: some View {
        switch shape {
        case .bar: barThumb
        case .tall:
            // the header's buttons float over a black band, so nothing sits on the picture
            VStack(spacing: 0) {
                Color.black.frame(height: headerHeight)
                playerOrTV(compact: true)
            }
            .background(Color.black)
        case .wide, .split:
            ZStack {
                Color.black
                playerOrTV(compact: false)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if shape == .bar {
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
        } else {
            PaneActionGrid(gridActions)
        }
    }

    @ViewBuilder private var clipNote: some View {
        if let note = clipText {
            Text(note)
                .font(CobaltType.caption)
                .foregroundStyle(store.clipState == .failed ? CobaltColor.errorText : CobaltColor.success)
                .padding(.horizontal, 16)
                .task(id: store.clipState) {
                    guard store.clipState == .saved || store.clipState == .failed else { return }
                    try? await Task.sleep(for: .seconds(4))
                    store.acknowledgeClip()
                }
        }
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

    /// Video-only AirPlay runs the TV behind the phone: chat waits to match (70.5).
    private var chatDelay: TimeInterval {
        #if os(iOS)
        TwitchTV.shared.activeChatDelay
        #else
        0
        #endif
    }
}

/// The chat as the shelf's card: a fixed height, since the column it sits in scrolls.
private struct TwitchChatCard: View {
    let model: AppModel
    let delay: TimeInterval

    @Environment(Pane.self) private var pane
    @Environment(\.paneShape) private var shape

    var body: some View {
        TwitchChatPane(model: model, delay: delay, showsLabel: false) { emote in
            // 7tv's add-to-set flow takes the emote's id and finds the emote in its registry (this page is replaced in the pane)
            guard let hit = emote.asHit else { return }
            SevenTvEmoteHits.remember(hit)
            pane.open(.emoteAddToSet(hit.id))
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 14))
    }

    private var height: CGFloat {
        switch shape {
        case .tall, .bar: 460
        case .wide: 520
        case .split: 600
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

#Preview("twitch · tall", traits: .fixedLayout(width: 440, height: 900)) {
    TwitchPageHost(shape: .tall)
}
#Preview("twitch · wide", traits: .fixedLayout(width: 1000, height: 560)) {
    TwitchPageHost(shape: .wide)
}
#Preview("twitch · split", traits: .fixedLayout(width: 1080, height: 800)) {
    TwitchPageHost(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540))
}
#Preview("twitch · bar", traits: .fixedLayout(width: 402, height: 64)) {
    TwitchPageHost(shape: .bar)
}
#endif
